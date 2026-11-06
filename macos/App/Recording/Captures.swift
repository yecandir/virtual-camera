import AVFoundation
import ScreenCaptureKit

/// A display + all computer sound, via ScreenCaptureKit (needs Screen Recording permission).
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onVideo: ((CMSampleBuffer) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?
    var onStop: ((Error) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "vcam.screen", qos: .userInitiated)
    private(set) var videoSize: (width: Int, height: Int) = (0, 0)

    static func displays() async throws -> [SCDisplay] {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).displays
    }

    /// `video: false` records sound only (ScreenCaptureKit still needs a tiny video stream).
    func start(displayID: CGDirectDisplayID?, video: Bool) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw LibraryError(message: String(localized: "No display found."))
        }
        // Keep our own windows (the recorder) out of the recording.
        let ownApp = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])

        let config = SCStreamConfiguration()
        if video {
            // Native resolution, capped at 1920 px wide; even dimensions for H.264.
            let scale = CGFloat(filter.pointPixelScale)
            var width = CGFloat(display.width) * scale
            var height = CGFloat(display.height) * scale
            if width > 1920 { height = height * 1920 / width; width = 1920 }
            config.width = Int(width) & ~1
            config.height = Int(height) & ~1
            config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.showsCursor = true
        } else {
            config.width = 64
            config.height = 64
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        }
        config.queueDepth = 6
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        videoSize = (config.width, config.height)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sample.isValid else { return }
        switch type {
        case .screen:
            // Only complete frames carry pixels (idle/blank frames are status updates).
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete else { return }
            onVideo?(sample)
        case .audio:
            onAudio?(sample)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}

/// The default microphone, retimed onto the host clock so it lines up with ScreenCaptureKit.
final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    var onAudio: ((CMSampleBuffer) -> Void)?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "vcam.mic", qos: .userInitiated)

    /// Returns false if there is no usable microphone.
    func start() -> Bool {
        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.beginConfiguration()
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { session.commitConfiguration(); return false }
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
        return true
    }

    func stop() {
        session.stopRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let clock = session.synchronizationClock else { onAudio?(sample); return }
        let hostPTS = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sample),
                                        from: clock, to: CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sample),
                                        presentationTimeStamp: hostPTS, decodeTimeStamp: .invalid)
        var retimed: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                                              sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                              sampleBufferOut: &retimed)
        onAudio?(retimed ?? sample)
    }
}
