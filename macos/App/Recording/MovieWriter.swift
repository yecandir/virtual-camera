import AVFoundation

/// Thread-safe AVAssetWriter wrapper: one optional H.264 video track and N AAC audio tracks.
/// The file timeline starts at the first video sample (or first audio sample if audio-only).
final class MovieWriter {
    struct AudioTrack { let channels: Int }

    let url: URL
    private let writer: AVAssetWriter
    private var videoInput: AVAssetWriterInput?
    private var audioInputs: [AVAssetWriterInput] = []
    private let queue = DispatchQueue(label: "vcam.writer")
    private var started = false
    private var finished = false

    init(url: URL, fileType: AVFileType, video: (width: Int, height: Int, bitrate: Int)?, audio: [AudioTrack]) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: fileType)

        if let video {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: video.width,
                AVVideoHeightKey: video.height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: video.bitrate],
            ])
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) { writer.add(input); videoInput = input }
        }
        for track in audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: track.channels,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) { writer.add(input); audioInputs.append(input) }
        }
        guard writer.startWriting() else {
            throw writer.error ?? LibraryError(message: "Could not start writing")
        }
    }

    func appendVideo(_ sample: CMSampleBuffer) {
        queue.async { [self] in
            guard !finished, let input = videoInput else { return }
            if !started { start(at: sample) }
            if input.isReadyForMoreMediaData { input.append(sample) }
        }
    }

    func appendAudio(_ sample: CMSampleBuffer, track: Int) {
        queue.async { [self] in
            guard !finished, track < audioInputs.count else { return }
            if !started {
                // With video, wait for the first frame so the file doesn't open on black.
                guard videoInput == nil else { return }
                start(at: sample)
            }
            let input = audioInputs[track]
            if input.isReadyForMoreMediaData { input.append(sample) }
        }
    }

    /// Returns true if a playable file was written.
    func finish() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                finished = true
                guard started else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(returning: false)
                    return
                }
                videoInput?.markAsFinished()
                audioInputs.forEach { $0.markAsFinished() }
                writer.finishWriting { [writer] in
                    continuation.resume(returning: writer.status == .completed)
                }
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            finished = true
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func start(at sample: CMSampleBuffer) {
        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
        started = true
    }
}
