import AVKit
import SwiftUI

@main
struct VirtualCameraApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Virtual Camera", id: "main") {
            MainWindow(model: model)
        }
        .windowResizability(.contentSize)

        Window("Recording", id: "recorder") {
            RecordingView(model: model.recorder)
        }
        .windowResizability(.contentSize)

        // Shortcut only: on notched MacBooks a crowded menu bar can hide this icon.
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.playingVideo ? "video.fill" : "video")
        }
    }
}

/// Opens the recorder window on a given tab.
@MainActor
func openRecorder(_ source: RecordingSource, model: AppModel, openWindow: OpenWindowAction) {
    if !model.recorder.isBusy { model.recorder.source = source }
    NSApp.activate(ignoringOtherApps: true)
    openWindow(id: "recorder")
}

// MARK: - Main window (mirrors the extension popup)

private struct MainWindow: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var pendingDelete: VideoItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            notices

            Section {
                HStack {
                    Button("🖥 Screen + audio") { openRecorder(.screen, model: model, openWindow: openWindow) }
                    Button("🎙 Audio only") { openRecorder(.audio, model: model, openWindow: openWindow) }
                }
            } header: {
                SectionTitle("Meeting recording")
            }

            Section {
                sourceList
                HStack {
                    Button("⏺ Camera") { openRecorder(.camera, model: model, openWindow: openWindow) }
                    Button(model.importing ? "Loading..." : "＋ Add") { model.addVideos() }
                        .disabled(model.importing)
                        .keyboardShortcut("o")
                }
            } header: {
                SectionTitle("Source")
            }

            Section {
                effects
            } header: {
                HStack {
                    SectionTitle("Effects")
                    Spacer()
                    Button("Reset") { model.resetEffects() }
                        .controlSize(.small)
                        .disabled(model.effects == .defaults)
                }
            }

            Divider()
            HStack {
                Text("⌥⇧V").font(.callout.monospaced())
                Text("Camera/Video toggle").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Menu("Camera extension") {
                    Button("Install / update") { model.reinstallExtension() }
                    Button("Uninstall") { model.uninstallExtension() }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.callout)
            }
        }
        .padding(18)
        .frame(width: 440)
        .alert("Delete \"\(pendingDelete?.name ?? "")\"?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) { if let item = pendingDelete { model.remove(item) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
            Text("Virtual Camera").font(.title3.weight(.semibold))
            Spacer()
            StatusPill(video: model.playingVideo)
        }
    }

    @ViewBuilder private var notices: some View {
        HStack(spacing: 6) {
            Circle().fill(model.connected ? Color.green : Color.secondary).frame(width: 8, height: 8)
            if !model.connected {
                Text("Virtual camera not connected")
            } else if model.watchers > 0 {
                Text("In use by an app")
            } else {
                Text("Ready · pick “Virtual Camera (Mac)” in Slack, Zoom, Meet…")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)

        if !model.extensionStatus.isEmpty && !model.connected {
            Text(model.extensionStatus).font(.callout).foregroundStyle(.secondary)
        }
        if model.cameraDenied {
            Notice(text: Text("Camera access is off. Virtual Camera needs it to send video to its device."),
                   button: "Open Settings") { model.openCameraPrivacySettings() }
        }
        if let error = model.errorMessage {
            Notice(text: Text(verbatim: error), button: "OK") { model.errorMessage = nil }
        }
    }

    private var sourceList: some View {
        VStack(spacing: 2) {
            SourceRow(icon: "📷", title: Text("Computer camera"), meta: Text("Default · real camera"),
                      active: !model.playingVideo) {
                model.selectCamera()
            } trailing: {
                if model.cameras.count > 1 {
                    Picker("", selection: $model.cameraID) {
                        ForEach(model.cameras) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            ForEach(model.library) { item in
                SourceRow(icon: "🎞", title: Text(verbatim: item.name),
                          meta: Text(verbatim: ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
                                     + " · " + item.created.formatted(date: .numeric, time: .omitted)),
                          active: model.playingVideo && model.activeID == item.id) {
                    model.select(item)
                } trailing: {
                    Button { model.showInFinder(item) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless).help("Show in Finder")
                    Button { pendingDelete = item } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Delete")
                }
            }
        }
    }

    private var effects: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Mirror (flip left-right)", isOn: $model.effects.mirror)
                .toggleStyle(.switch)
            HStack {
                Text("Brightness").frame(width: 90, alignment: .leading)
                Slider(value: $model.effects.brightness, in: 0.5...1.5, step: 0.05)
                Text(verbatim: "\(Int((model.effects.brightness * 100).rounded()))%")
                    .monospacedDigit().frame(width: 48, alignment: .trailing)
            }
            HStack {
                Text("Blur").frame(width: 90, alignment: .leading)
                Slider(value: $model.effects.blur, in: 0...10, step: 0.5)
                Text(verbatim: "\(model.effects.blur.formatted(.number.precision(.fractionLength(0...1)))) px")
                    .monospacedDigit().frame(width: 48, alignment: .trailing)
            }
            Text("Effects apply to the virtual camera image (camera and videos).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Recording window (mirrors the extension's recording tab)

struct RecordingView: View {
    @ObservedObject var model: RecordingModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $model.source) {
                Text("📷 Camera").tag(RecordingSource.camera)
                Text("🖥 Screen + audio").tag(RecordingSource.screen)
                Text("🎙 Audio only").tag(RecordingSource.audio)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.isBusy)

            stage

            Text(model.message)
                .font(.callout)
                .foregroundStyle(messageColor)
                .fixedSize(horizontal: false, vertical: true)

            if model.source != .camera && model.phase == .idle {
                Text(model.source == .screen
                     ? LocalizedStringKey("Records the selected screen and all computer sound, mixed with your microphone. Remember to tell participants you're recording.")
                     : "Records all computer sound and your microphone, no picture. Remember to tell participants you're recording.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.source == .screen && model.displays.count > 1 {
                    Picker("Screen", selection: $model.displayID) {
                        ForEach(model.displays) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .fixedSize()
                }
                if model.needsScreenPermission {
                    Button("Open Screen Recording settings") { model.openScreenRecordingSettings() }
                }
            }

            if model.phase == .done {
                HStack {
                    Button("Show in Finder") { model.showInFinder() }
                    Button("⏺ New recording") { model.reset() }
                    Spacer()
                    Button("✓ Close") { dismissWindow(id: "recorder") }
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
            } else {
                TextField("Recording name (leave empty for date/time)", text: $model.name)
                    .disabled(model.isBusy)
                HStack {
                    if model.phase == .recording || model.phase == .saving {
                        Button("⏹ Stop and save") { model.stop() }
                            .disabled(model.phase == .saving)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("⏺ Start recording") { model.start() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.isBusy || model.needsScreenPermission)
                    }
                    Spacer()
                    Button("✕ Close") { dismissWindow(id: "recorder") }
                }
                .controlSize(.large)
            }
        }
        .padding(18)
        .frame(width: 560)
        .onAppear { model.windowAppeared() }
        .onDisappear { model.windowClosed() }
    }

    private var messageColor: Color {
        switch model.messageKind {
        case .normal: return .secondary
        case .error: return .orange
        case .ok: return .green
        }
    }

    private var stage: some View {
        ZStack {
            Rectangle().fill(Color.black)
            if model.phase == .done, let url = model.savedURL {
                PlayerView(url: url, loop: model.source == .camera)
            } else if let preview = model.preview {
                Image(decorative: preview, scale: 1).resizable().scaledToFit()
            } else {
                Text(placeholder).foregroundStyle(.white.opacity(0.6)).padding()
            }
            if case .countdown(let n) = model.phase, n > 0 {
                Text(verbatim: "\(n)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(radius: 8)
            }
            if model.phase == .recording {
                VStack {
                    HStack {
                        HStack(spacing: 6) {
                            Circle().fill(Color.red).frame(width: 9, height: 9)
                            Text(verbatim: timeText).monospacedDigit()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(10)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var placeholder: LocalizedStringKey {
        switch model.source {
        case .camera: return "Opening camera…"
        case .screen: return "The shared screen appears here once recording starts."
        case .audio: return "Only audio will be recorded."
        }
    }

    private var timeText: String {
        let s = Int(model.elapsed)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Menu bar

private struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.playingVideo ? LocalizedStringKey("▶︎ Video playing") : "📷 Camera")
        Divider()
        Button((model.playingVideo ? "    " : "✓ ") + String(localized: "Computer camera")) { model.selectCamera() }
        ForEach(model.library) { item in
            Button((model.playingVideo && model.activeID == item.id ? "✓ " : "    ") + item.name) { model.select(item) }
        }
        Button("Camera/Video toggle (⌥⇧V)") { model.toggle() }
        Divider()
        Menu("Record") {
            Button("📷 Camera") { openRecorder(.camera, model: model, openWindow: openWindow) }
            Button("🖥 Screen + audio") { openRecorder(.screen, model: model, openWindow: openWindow) }
            Button("🎙 Audio only") { openRecorder(.audio, model: model, openWindow: openWindow) }
        }
        Button("Open Virtual Camera…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

// MARK: - Pieces

private struct SectionTitle: View {
    let key: LocalizedStringKey
    init(_ key: LocalizedStringKey) { self.key = key }
    var body: some View {
        Text(key).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }
}

private struct StatusPill: View {
    let video: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(video ? Color.purple : Color.green).frame(width: 7, height: 7)
            Text(video ? LocalizedStringKey("Video playing") : "Camera")
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background((video ? Color.purple : Color.green).opacity(0.15), in: Capsule())
    }
}

private struct Notice: View {
    let text: Text
    let button: LocalizedStringKey
    let action: () -> Void
    var body: some View {
        HStack {
            text.font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(button, action: action)
        }
        .padding(10)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SourceRow<Trailing: View>: View {
    let icon: String
    let title: Text
    let meta: Text
    let active: Bool
    let action: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .strokeBorder(active ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: active ? 5 : 1.5)
                .frame(width: 14, height: 14)
            Text(icon)
            VStack(alignment: .leading, spacing: 1) {
                title.lineLimit(1)
                meta.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(active ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

/// Plays a finished recording (looping for camera clips, like the extension).
/// AppKit's AVPlayerView: SwiftUI's VideoPlayer crashes on macOS 26 (AVKit metadata abort).
private struct PlayerView: NSViewRepresentable {
    let url: URL
    let loop: Bool

    final class Coordinator {
        let player = AVQueuePlayer()
        var looper: AVPlayerLooper?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = context.coordinator.player
        load(context.coordinator)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.player.pause()
        coordinator.looper = nil
        coordinator.player.removeAllItems()
        view.player = nil
    }

    private func load(_ coordinator: Coordinator) {
        let item = AVPlayerItem(url: url)
        if loop {
            coordinator.looper = AVPlayerLooper(player: coordinator.player, templateItem: item)
        } else {
            coordinator.player.insert(item, after: nil)
        }
        coordinator.player.play()
    }
}
