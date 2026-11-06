import AppKit
import AVFoundation
import Combine
import os.log

let appLog = Logger(subsystem: "com.yecandir.virtualcamera", category: "app")

enum SourceMode: String {
    case camera, video
}

@MainActor
final class AppModel: ObservableObject {
    // Source (same model as the extension: mode + active video; camera is the default)
    @Published private(set) var mode: SourceMode = .camera
    @Published private(set) var activeID: String?
    @Published private(set) var library: [VideoItem] = []
    @Published private(set) var importing = false

    @Published var effects = Effects() { didSet { saveEffects() } }
    @Published private(set) var cameras: [CameraInfo] = []
    @Published var cameraID: String? { didSet { cameraChanged() } }

    // Status
    @Published private(set) var connected = false
    @Published private(set) var watchers = 0
    @Published private(set) var cameraDenied = false
    @Published private(set) var extensionStatus = ""
    @Published var errorMessage: String?

    let recorder: RecordingModel

    private let extensionManager = ExtensionManager()
    private let sink = SinkStreamer()
    private let camera = CameraSource()
    private let video = VideoSource()
    private let renderer = FrameRenderer()
    private var frameTimer: Timer?
    private var statusTimer: Timer?
    private var hotKey: HotKey?
    private var queueFullSince: Date?
    private var liveCameraActive = false
    private let defaults = UserDefaults.standard

    /// A video is the source (and it still exists).
    var playingVideo: Bool { mode == .video && activeItem != nil }
    var activeItem: VideoItem? { library.first { $0.id == activeID } }

    init() {
        let camera = self.camera
        var addToLibrary: ((URL, String) -> Void)?
        recorder = RecordingModel(camera: camera) { url, name in addToLibrary?(url, name) }
        addToLibrary = { [weak self] url, name in self?.addRecording(url: url, name: name) }

        SinkStreamer.configureCoreMediaIO()
        loadState()

        extensionManager.onStatus = { [weak self] in self?.extensionStatus = $0 }
        extensionManager.onActivated = { [weak self] in
            // Activation may have replaced the extension process; the old queue is dead.
            self?.reconnect(reason: "extension activated")
        }
        extensionManager.install()

        refreshCameras()
        NotificationCenter.default.addObserver(forName: .AVCaptureDeviceWasConnected, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCameras() }
        }
        NotificationCenter.default.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCameras() }
        }

        sink.observeDevices { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The extension was replaced/restarted: drop the old connection and reconnect.
                if self.sink.isConnected && !self.sink.deviceStillPresent {
                    self.reconnect(reason: "device list changed")
                } else if !self.sink.isConnected {
                    self.updateStatus()
                }
            }
        }

        hotKey = HotKey.optionShiftV { [weak self] in self?.toggle() }

        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatus() }
        }
        frameTimer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pumpFrame() }
        }
        RunLoop.main.add(frameTimer!, forMode: .common)

        applySource()
        requestCameraAccess()
    }

    // MARK: Source selection

    func selectCamera() {
        mode = .camera
        activeID = nil
        applySource()
    }

    /// Clicking the selected video again goes back to the camera (like the extension).
    func select(_ item: VideoItem) {
        if playingVideo && activeID == item.id {
            selectCamera()
            return
        }
        mode = .video
        activeID = item.id
        applySource()
    }

    /// ⌥⇧V: video → camera; camera → selected video, or the newest one.
    func toggle() {
        if playingVideo {
            mode = .camera
        } else if let target = activeItem ?? library.first {
            mode = .video
            activeID = target.id
        }
        applySource()
    }

    private func applySource() {
        defaults.set(mode.rawValue, forKey: "mode")
        defaults.set(activeID, forKey: "activeID")
        if playingVideo, let item = activeItem {
            video.play(url: item.url)
        } else {
            video.stop()
        }
        updateLiveCamera()
    }

    // MARK: Library

    func addVideos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        importing = true
        Task {
            var firstAdded: VideoItem?
            for url in urls {
                do {
                    let item = try await Library.importFile(url)
                    library.insert(item, at: 0)
                    firstAdded = firstAdded ?? item
                } catch {
                    errorMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
            importing = false
            Library.save(library)
            // Like the extension: a newly added video becomes the source.
            if let firstAdded { mode = .video; activeID = firstAdded.id; applySource() }
        }
    }

    func remove(_ item: VideoItem) {
        if item.owned { try? FileManager.default.removeItem(at: item.url) }
        library.removeAll { $0.id == item.id }
        Library.save(library)
        if activeID == item.id { selectCamera() }
    }

    func showInFinder(_ item: VideoItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    private func addRecording(url: URL, name: String) {
        library.insert(Library.makeItem(url: url, name: name, owned: true), at: 0)
        Library.save(library)
    }

    // MARK: Effects & camera

    func resetEffects() { effects = .defaults }

    private func saveEffects() {
        if let data = try? JSONEncoder().encode(effects) { defaults.set(data, forKey: "effects") }
    }

    private func refreshCameras() {
        cameras = CameraSource.availableCameras()
        if cameraID == nil || !cameras.contains(where: { $0.id == cameraID }) {
            cameraID = cameras.first(where: { $0.name.localizedCaseInsensitiveContains("FaceTime") || $0.name.contains("MacBook") })?.id
                ?? cameras.first?.id
        }
    }

    private func cameraChanged() {
        defaults.set(cameraID, forKey: "cameraID")
        camera.setDevice(cameraID)
    }

    // MARK: Extension & frames

    func reinstallExtension() { extensionManager.install() }

    func uninstallExtension() {
        sink.disconnect()
        connected = false
        extensionManager.uninstall()
    }

    func openCameraPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }

    /// macOS hides camera devices (including ours) from apps without camera access.
    private func requestCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            updateStatus()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor [weak self] in
                    self?.cameraDenied = !granted
                    self?.refreshCameras()
                    self?.updateStatus()
                }
            }
        default:
            cameraDenied = true
        }
    }

    /// Once a second: (re)connect to the extension and read how many apps are watching.
    private func updateStatus() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        cameraDenied = false
        if !sink.isConnected { sink.connect() }
        connected = sink.isConnected
        // Unknown (older extension) → assume someone is watching.
        let count = connected ? (sink.sourceClientCount() ?? 1) : 0
        if count != watchers {
            appLog.info("watchers: \(count, privacy: .public)")
            watchers = count
        }
        updateLiveCamera()
        video.setPaused(watchers == 0)
    }

    /// The real camera runs only while an app is watching the virtual camera in camera mode,
    /// so its light isn't on just because this app is open.
    private func updateLiveCamera() {
        let needed = connected && watchers > 0 && !playingVideo
        guard needed != liveCameraActive else { return }
        liveCameraActive = needed
        if needed { camera.acquire("live") } else { camera.release("live") }
    }

    private func pumpFrame() {
        guard connected, watchers > 0 else { return }
        let frame = playingVideo ? video.currentFrame() : camera.latestFrame
        guard let frame, let output = renderer.render(frame, effects: effects) else { return }
        if sink.send(output) {
            queueFullSince = nil
        } else if sink.isQueueFull {
            // Nobody is draining the queue: the extension process was restarted under us.
            let since = queueFullSince ?? Date()
            queueFullSince = since
            if Date().timeIntervalSince(since) > 1 { reconnect(reason: "queue stuck full") }
        }
    }

    private func reconnect(reason: String) {
        appLog.info("reconnecting sink: \(reason, privacy: .public)")
        queueFullSince = nil
        sink.disconnect()
        connected = false
        updateStatus()
    }

    // MARK: Persistence

    private func loadState() {
        library = Library.load()
        let legacy = Library.migrateLegacy(defaults)
        if !legacy.isEmpty {
            library = legacy + library
            Library.save(library)
            // First version stored the selected video as a path.
            if let path = defaults.string(forKey: "current") {
                activeID = library.first { $0.path == path }?.id
                mode = activeID == nil ? .camera : .video
                defaults.removeObject(forKey: "current")
            }
        } else {
            mode = SourceMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .camera
            activeID = defaults.string(forKey: "activeID")
        }
        if let data = defaults.data(forKey: "effects"), let saved = try? JSONDecoder().decode(Effects.self, from: data) {
            effects = saved
        }
        cameraID = defaults.string(forKey: "cameraID")
    }
}
