import AVFoundation
import AppKit
import ScreenCaptureKit

enum RecordingSource: String, CaseIterable, Identifiable {
    case camera, screen, audio
    var id: String { rawValue }
}

struct DisplayInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
}

@MainActor
final class RecordingModel: ObservableObject {
    enum Phase: Equatable { case idle, countdown(Int), recording, saving, done }
    enum MessageKind { case normal, error, ok }

    @Published var source: RecordingSource = .camera { didSet { if source != oldValue { sourceChanged() } } }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var message = ""
    @Published private(set) var messageKind: MessageKind = .normal
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var preview: CGImage?
    @Published private(set) var displays: [DisplayInfo] = []
    @Published var displayID: CGDirectDisplayID?
    @Published var name = ""
    @Published private(set) var savedURL: URL?
    @Published private(set) var needsScreenPermission = false

    var isBusy: Bool { phase != .idle && phase != .done }

    private let camera: CameraSource
    private let onSavedToLibrary: (URL, String) -> Void
    private let renderer = FrameRenderer()

    /// Written on the main actor, read from capture queues.
    private nonisolated let writer = Locked<MovieWriter?>(nil)
    private nonisolated let latestScreenFrame = Locked<CVPixelBuffer?>(nil)
    private var screen: ScreenCapture?
    private var mic: MicCapture?
    private var previewTimer: Timer?
    private var ticker: Timer?
    private var startDate = Date()
    private var cancelled = false
    private var visible = false

    init(camera: CameraSource, onSavedToLibrary: @escaping (URL, String) -> Void) {
        self.camera = camera
        self.onSavedToLibrary = onSavedToLibrary
    }

    // MARK: Window lifecycle

    func windowAppeared() {
        visible = true
        reset()
    }

    /// Closing the window cancels a recording in progress (like closing the extension's tab).
    func windowClosed() {
        visible = false
        cancelled = true
        Task { await teardownCaptures() }
        writer.value?.cancel()
        writer.value = nil
        stopTimers()
        camera.release("recorder")
        phase = .idle
    }

    func reset() {
        cancelled = false
        savedURL = nil
        elapsed = 0
        name = ""
        phase = .idle
        sourceChanged()
    }

    private func sourceChanged() {
        guard !isBusy else { return }
        preview = nil
        needsScreenPermission = false
        if source == .camera && visible {
            camera.acquire("recorder")
            say(String(localized: "Ready. Name your recording if you like, then start."))
        } else {
            camera.release("recorder")
            say(String(localized: "Ready."))
        }
        if source != .camera { loadDisplays() }
        startPreviewTimer()
    }

    private func loadDisplays() {
        Task {
            do {
                let list = try await ScreenCapture.displays()
                displays = list.enumerated().map { index, d in
                    DisplayInfo(id: d.displayID, name: Self.displayName(d.displayID) ?? String(localized: "Display \(index + 1)"))
                }
                if displayID == nil || !displays.contains(where: { $0.id == displayID }) {
                    displayID = CGMainDisplayID()
                }
            } catch {
                needsScreenPermission = true
                say(String(localized: "Allow Screen Recording for Virtual Camera in System Settings, then reopen the app."), .error)
            }
        }
    }

    private static func displayName(_ id: CGDirectDisplayID) -> String? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }?.localizedName
    }

    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    // MARK: Recording

    func start() {
        guard !isBusy else { return }
        cancelled = false
        Task { await startRecording() }
    }

    private func startRecording() async {
        var warnings: [String] = []
        if source != .camera {
            phase = .countdown(0)
            do {
                warnings = try await startScreenAndMic()
            } catch {
                await teardownCaptures()
                phase = .idle
                needsScreenPermission = true
                say(String(localized: "Couldn't start: \(error.localizedDescription)"), .error)
                return
            }
        }

        say(String(localized: "Get ready..."))
        for n in [3, 2, 1] {
            phase = .countdown(n)
            try? await Task.sleep(nanoseconds: 700_000_000)
            if cancelled { return }
        }

        do {
            try makeWriter()
        } catch {
            await teardownCaptures()
            phase = .idle
            say(String(localized: "Couldn't start: \(error.localizedDescription)"), .error)
            return
        }
        if source == .camera {
            camera.addHandler("recorder") { [weak self] sample in
                self?.writer.value?.appendVideo(sample)
            }
        }

        phase = .recording
        startDate = Date()
        elapsed = 0
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(self.startDate)
            }
        }
        if warnings.isEmpty {
            say(String(localized: "Recording..."))
        } else {
            say(String(localized: "Recording. Warning: \(warnings.joined(separator: "; "))."), .error)
        }
    }

    /// Starts ScreenCaptureKit + mic before the countdown (so permission prompts come first);
    /// samples only reach the file once the writer exists.
    private func startScreenAndMic() async throws -> [String] {
        var warnings: [String] = []
        let screen = ScreenCapture()
        screen.onVideo = { [weak self] sample in
            guard let self else { return }
            if let pixels = CMSampleBufferGetImageBuffer(sample) {
                self.latestScreenFrame.value = pixels
            }
            self.writer.value?.appendVideo(sample)
        }
        screen.onAudio = { [weak self] sample in
            guard let self else { return }
            self.writer.value?.appendAudio(sample, track: 0)
        }
        screen.onStop = { [weak self] _ in
            Task { @MainActor in if self?.phase == .recording { self?.stop() } }
        }
        try await screen.start(displayID: displayID, video: source == .screen)
        self.screen = screen

        let micAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        let mic = MicCapture()
        if micAllowed && mic.start() {
            mic.onAudio = { [weak self] sample in
                guard let self else { return }
                self.writer.value?.appendAudio(sample, track: 1)
            }
            self.mic = mic
        } else {
            warnings.append(String(localized: "no microphone permission, your voice won't be recorded"))
        }
        return warnings
    }

    private func makeWriter() throws {
        let label: String
        switch source {
        case .camera: label = String(localized: "Recording")
        case .screen: label = String(localized: "Meeting")
        case .audio: label = String(localized: "Audio")
        }
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
        let baseName = name.trimmingCharacters(in: .whitespaces).isEmpty ? "\(label) \(stamp)" : name

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let audioTracks = [MovieWriter.AudioTrack(channels: 2)] + (mic != nil ? [MovieWriter.AudioTrack(channels: 1)] : [])
        let newWriter: MovieWriter
        switch source {
        case .camera:
            // Raw camera, no audio (same as the extension's camera clip).
            let size = cameraFrameSize()
            newWriter = try MovieWriter(url: Library.newFileURL(name: baseName, ext: "mp4"), fileType: .mp4,
                                        video: (size.width, size.height, 2_500_000), audio: [])
        case .screen:
            let size = screen?.videoSize ?? (width: 1920, height: 1080)
            newWriter = try MovieWriter(url: Library.uniqueURL(in: downloads, name: baseName, ext: "mp4"), fileType: .mp4,
                                        video: (size.width, size.height, 2_500_000), audio: audioTracks)
        case .audio:
            newWriter = try MovieWriter(url: Library.uniqueURL(in: downloads, name: baseName, ext: "m4a"), fileType: .m4a,
                                        video: nil, audio: audioTracks)
        }
        writer.value = newWriter
    }

    private func cameraFrameSize() -> (width: Int, height: Int) {
        guard let frame = camera.latestFrame else { return (1280, 720) }
        return (CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame))
    }

    func stop() {
        guard phase == .recording else { return }
        phase = .saving
        say(String(localized: "Saving..."))
        stopTimers()
        camera.removeHandler("recorder")
        Task {
            await teardownCaptures()
            let current = writer.value
            writer.value = nil
            guard let current, await current.finish() else {
                phase = .idle
                say(String(localized: "Nothing was recorded."), .error)
                return
            }
            finishSaved(current.url)
        }
    }

    private func finishSaved(_ url: URL) {
        savedURL = url
        phase = .done
        let fileName = url.lastPathComponent
        if source == .camera {
            // Not selected automatically: pick it from the source list (like the extension).
            onSavedToLibrary(url, url.deletingPathExtension().lastPathComponent)
            camera.release("recorder")
            say(String(localized: "✓ \"\(fileName)\" saved to the library. Select it in the source list to use it."), .ok)
        } else {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let sizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            say(String(localized: "✓ \"\(fileName)\" saved to Downloads (\(sizeText))."), .ok)
        }
        startPreviewTimer()
    }

    func showInFinder() {
        guard let savedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([savedURL])
    }

    private func teardownCaptures() async {
        mic?.stop()
        mic = nil
        await screen?.stop()
        screen = nil
        latestScreenFrame.value = nil
    }

    // MARK: Preview

    private func startPreviewTimer() {
        previewTimer?.invalidate()
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePreview() }
        }
    }

    private func updatePreview() {
        guard visible, phase != .done else { preview = nil; return }
        let frame: CVPixelBuffer?
        switch source {
        case .camera: frame = camera.latestFrame
        case .screen: frame = latestScreenFrame.value
        case .audio: frame = nil
        }
        preview = frame.flatMap { renderer.cgImage($0) }
    }

    private func stopTimers() {
        ticker?.invalidate()
        ticker = nil
    }

    private func say(_ text: String, _ kind: MessageKind = .normal) {
        message = text
        messageKind = kind
    }
}

/// A value guarded by a lock, for state shared with capture callback queues.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
