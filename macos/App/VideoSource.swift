import AVFoundation
import QuartzCore

/// Plays a video file in a seamless, muted loop and hands out its current frame.
final class VideoSource {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var outputs: [ObjectIdentifier: AVPlayerItemVideoOutput] = [:]
    private var lastFrame: CVPixelBuffer?
    private(set) var url: URL?

    init() {
        player.isMuted = true
    }

    func play(url: URL) {
        guard url != self.url else { return }
        stop()
        self.url = url
        // AVPlayerLooper creates its copies of the template asynchronously (after the asset
        // loads), so outputs are attached lazily in output(for:).
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.play()
    }

    func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        outputs.removeAll()
        lastFrame = nil
        url = nil
    }

    /// Pauses decoding while nobody is watching the virtual camera.
    func setPaused(_ paused: Bool) {
        guard looper != nil else { return }
        if paused, player.rate != 0 { player.pause() }
        if !paused, player.rate == 0 { player.play() }
    }

    /// The frame to show now (the last one is held while the loop wraps around).
    func currentFrame() -> CVPixelBuffer? {
        guard looper != nil, let item = player.currentItem else { return lastFrame }
        let output = output(for: item)
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: itemTime),
           let frame = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
            lastFrame = frame
        }
        return lastFrame
    }

    /// Each looping copy needs its own output; one output can't be shared between items.
    private func output(for item: AVPlayerItem) -> AVPlayerItemVideoOutput {
        let key = ObjectIdentifier(item)
        if let existing = outputs[key] { return existing }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        outputs[key] = output
        return output
    }
}
