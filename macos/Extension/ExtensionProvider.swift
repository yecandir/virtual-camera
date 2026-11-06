import Foundation
import CoreMediaIO
import CoreVideo
import CoreText
import IOKit.audio
import os.log

// Shared with the host app (App/SinkStreamer.swift): the host finds the device by this UID.
let kDeviceUID = "6B8E1C2A-4F1D-4C8B-9E3A-2D7F5A1B0C01"
private let kSourceStreamID = "6B8E1C2A-4F1D-4C8B-9E3A-2D7F5A1B0C02"
private let kSinkStreamID = "6B8E1C2A-4F1D-4C8B-9E3A-2D7F5A1B0C03"

let kWidth: Int32 = 1280
let kHeight: Int32 = 720
let kFrameRate: Int32 = 30
/// Without a frame from the host app for this long, the placeholder is shown.
private let kSinkTimeoutNs: UInt64 = 1_000_000_000

/// Custom property on the sink stream: how many apps are reading the camera right now ("0", "1", …).
/// The host app reads it (selector 'vcsr') to run the real camera / frame pipeline only when needed.
let kSourceClientsProperty = CMIOExtensionProperty(rawValue: "4cc_vcsr_glob_0000")

private let log = Logger(subsystem: "com.yecandir.virtualcamera.extension", category: "device")

// MARK: - Device

final class ExtensionDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStream: ExtensionStreamSource!
    private var sinkStream: ExtensionSinkSource!

    private var videoDescription: CMFormatDescription!
    private var bufferPool: CVPixelBufferPool!
    private var placeholder: CVPixelBuffer?

    private let timerQueue = DispatchQueue(label: "vcam.timer", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var streamingCounter = 0

    /// Number of apps currently reading the virtual camera.
    var sourceClientCount: Int { timerQueue.sync { streamingCounter } }

    private let sinkQueue = DispatchQueue(label: "vcam.sink", qos: .userInteractive)
    private var sinkStarted = false
    private var loggedFirstSinkFrame = false
    private var loggedConsumeError = false

    private let lock = NSLock()
    private var latestSinkBuffer: CVPixelBuffer?
    private var latestSinkTime: UInt64 = 0

    init(localizedName: String) {
        super.init()
        device = CMIOExtensionDevice(localizedName: localizedName,
                                     deviceID: UUID(uuidString: kDeviceUID)!,
                                     legacyDeviceID: kDeviceUID,
                                     source: self)

        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       codecType: kCVPixelFormatType_32BGRA,
                                       width: kWidth, height: kHeight,
                                       extensions: nil,
                                       formatDescriptionOut: &videoDescription)

        let attrs: NSDictionary = [
            kCVPixelBufferWidthKey: kWidth,
            kCVPixelBufferHeightKey: kHeight,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs, &bufferPool)

        let frameDuration = CMTime(value: 1, timescale: kFrameRate)
        let format = CMIOExtensionStreamFormat(formatDescription: videoDescription,
                                               maxFrameDuration: frameDuration,
                                               minFrameDuration: frameDuration,
                                               validFrameDurations: nil)

        sourceStream = ExtensionStreamSource(localizedName: "Virtual Camera.Video",
                                             streamID: UUID(uuidString: kSourceStreamID)!,
                                             streamFormat: format, device: device)
        sinkStream = ExtensionSinkSource(localizedName: "Virtual Camera.Sink",
                                         streamID: UUID(uuidString: kSinkStreamID)!,
                                         streamFormat: format, device: device)
        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            fatalError("Failed to add streams: \(error.localizedDescription)")
        }

        placeholder = makePlaceholder()
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let props = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { props.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { props.model = "Virtual Camera" }
        return props
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Source stream (apps reading the camera)

    func startStreaming() {
        timerQueue.async { [self] in
            streamingCounter += 1
            log.info("source stream started (clients: \(self.streamingCounter, privacy: .public))")
            publishSourceClients(streamingCounter)
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
            t.schedule(deadline: .now(), repeating: 1.0 / Double(kFrameRate), leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.emitFrame() }
            t.resume()
            timer = t
        }
    }

    func stopStreaming() {
        timerQueue.async { [self] in
            streamingCounter = max(0, streamingCounter - 1)
            publishSourceClients(streamingCounter)
            if streamingCounter == 0 {
                timer?.cancel()
                timer = nil
            }
        }
    }

    /// CoreMediaIO caches property values on the host side; push the new count so the host
    /// app's reads of 'vcsr' stay current.
    private func publishSourceClients(_ count: Int) {
        let state = CMIOExtensionPropertyState<AnyObject>(value: "\(count)" as NSString)
        sinkStream.stream.notifyPropertiesChanged([kSourceClientsProperty: state])
    }

    private func emitFrame() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let nowNs = UInt64(now.seconds * Double(NSEC_PER_SEC))

        lock.lock()
        let fresh = latestSinkBuffer != nil && nowNs &- latestSinkTime < kSinkTimeoutNs
        let pixelBuffer = fresh ? latestSinkBuffer : placeholder
        lock.unlock()
        guard let pixelBuffer else { return }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: kFrameRate),
                                        presentationTimeStamp: now,
                                        decodeTimeStamp: .invalid)
        var sbuf: CMSampleBuffer?
        let err = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: pixelBuffer,
                                                     dataReady: true,
                                                     makeDataReadyCallback: nil,
                                                     refcon: nil,
                                                     formatDescription: videoDescription,
                                                     sampleTiming: &timing,
                                                     sampleBufferOut: &sbuf)
        guard err == noErr, let sbuf else { return }
        sourceStream.stream.send(sbuf, discontinuity: [], hostTimeInNanoseconds: nowNs)
    }

    // MARK: Sink stream (frames pushed by the host app)

    func startStreamingSink(client: CMIOExtensionClient) {
        sinkQueue.async { [self] in
            sinkStarted = true
            loggedFirstSinkFrame = false
            log.info("sink stream started")
            consumeBuffer(client)
        }
    }

    func stopStreamingSink() {
        sinkQueue.async { [self] in
            sinkStarted = false
            log.info("sink stream stopped")
            lock.lock()
            latestSinkBuffer = nil
            lock.unlock()
        }
    }

    private func consumeBuffer(_ client: CMIOExtensionClient) {
        guard sinkStarted else { return }
        sinkStream.stream.consumeSampleBuffer(from: client) { [weak self] sbuf, seq, _, hasMore, err in
            guard let self else { return }
            if let err, !self.loggedConsumeError {
                self.loggedConsumeError = true
                log.error("consumeSampleBuffer error: \(String(describing: err), privacy: .public)")
            }
            if let sbuf, let image = CMSampleBufferGetImageBuffer(sbuf) {
                let nowNs = UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC))
                self.lock.lock()
                self.latestSinkBuffer = image
                self.latestSinkTime = nowNs
                self.lock.unlock()
                if !self.loggedFirstSinkFrame {
                    self.loggedFirstSinkFrame = true
                    log.info("first sink frame received")
                }
                let output = CMIOExtensionScheduledOutput(sequenceNumber: seq, hostTimeInNanoseconds: nowNs)
                self.sinkStream.stream.notifyScheduledOutputChanged(output)
            }
            // Poll again: immediately if more is queued, otherwise shortly.
            if sbuf != nil && hasMore {
                self.sinkQueue.async { self.consumeBuffer(client) }
            } else {
                self.sinkQueue.asyncAfter(deadline: .now() + .milliseconds(5)) { self.consumeBuffer(client) }
            }
        }
    }

    // MARK: Placeholder

    private func makePlaceholder() -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, bufferPool, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                                  width: Int(kWidth), height: Int(kHeight),
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return pb }

        ctx.setFillColor(CGColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: Int(kWidth), height: Int(kHeight)))

        func drawCentered(_ text: String, size: CGFloat, y: CGFloat, alpha: CGFloat) {
            let font = CTFontCreateWithName("Helvetica Neue" as CFString, size, nil)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: alpha),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            ctx.textPosition = CGPoint(x: (CGFloat(kWidth) - width) / 2, y: y)
            CTLineDraw(line, ctx)
        }
        drawCentered("Virtual Camera", size: 56, y: CGFloat(kHeight) / 2 + 10, alpha: 0.9)
        drawCentered("Open the Virtual Camera app", size: 26, y: CGFloat(kHeight) / 2 - 50, alpha: 0.5)
        return pb
    }
}

// MARK: - Source stream

final class ExtensionStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let streamFormat: CMIOExtensionStreamFormat

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self.streamFormat = streamFormat
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID,
                                     direction: .source, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }
    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let props = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { props.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { props.frameDuration = CMTime(value: 1, timescale: kFrameRate) }
        return props
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let idx = streamProperties.activeFormatIndex { activeFormatIndex = idx }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        (device.source as? ExtensionDeviceSource)?.startStreaming()
    }

    func stopStream() throws {
        (device.source as? ExtensionDeviceSource)?.stopStreaming()
    }
}

// MARK: - Sink stream

final class ExtensionSinkSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let streamFormat: CMIOExtensionStreamFormat
    private var client: CMIOExtensionClient?

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self.streamFormat = streamFormat
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID,
                                     direction: .sink, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }
    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData,
         kSourceClientsProperty]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let props = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { props.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { props.frameDuration = CMTime(value: 1, timescale: kFrameRate) }
        if properties.contains(.streamSinkBufferQueueSize) { props.sinkBufferQueueSize = 1 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { props.sinkBuffersRequiredForStartup = 1 }
        if properties.contains(kSourceClientsProperty) {
            let count = (device.source as? ExtensionDeviceSource)?.sourceClientCount ?? 0
            props.setPropertyState(CMIOExtensionPropertyState(value: "\(count)" as NSString), forProperty: kSourceClientsProperty)
        }
        return props
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let idx = streamProperties.activeFormatIndex { activeFormatIndex = idx }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        guard let source = device.source as? ExtensionDeviceSource, let client else { return }
        source.startStreamingSink(client: client)
    }

    func stopStream() throws {
        (device.source as? ExtensionDeviceSource)?.stopStreamingSink()
    }
}

// MARK: - Provider

final class ExtensionProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: ExtensionDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = ExtensionDeviceSource(localizedName: "Virtual Camera (Mac)")
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let props = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { props.manufacturer = "Virtual Camera" }
        return props
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
