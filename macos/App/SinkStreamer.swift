import Foundation
import CoreMediaIO
import CoreMedia
import CoreVideo

/// Must match `kDeviceUID` in Extension/ExtensionProvider.swift.
private let kDeviceUID = "6B8E1C2A-4F1D-4C8B-9E3A-2D7F5A1B0C01"

/// Pushes frames into the camera extension's sink stream through the CoreMediaIO C API.
final class SinkStreamer {
    private var deviceID: CMIOObjectID = 0
    private var streamID: CMIOStreamID = 0
    private var queue: CMSimpleQueue?
    private var formatDescription: CMFormatDescription?

    private var lastFailure = ""

    var isConnected: Bool { queue != nil }

    /// Call once at launch, before any other CoreMediaIO use. By default CoreMediaIO delivers
    /// its notifications on a run loop it doesn't reliably service in an app like ours, and the
    /// in-process device list then never notices the extension being replaced (stale device).
    static func configureCoreMediaIO() {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(0x726E_6C70), // 'rnlp' = kCMIOHardwarePropertyRunLoop
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var runLoop: CFRunLoop? = nil
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil,
                                  UInt32(MemoryLayout<CFRunLoop?>.size), &runLoop)
    }

    /// Calls `handler` on the main queue whenever cameras appear or disappear.
    func observeDevices(_ handler: @escaping () -> Void) {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &addr, .main) { _, _ in handler() }
    }

    /// True if the device we're connected to is still in the system's device list.
    var deviceStillPresent: Bool {
        guard isConnected else { return false }
        return findDevice() == deviceID
    }

    var isQueueFull: Bool {
        guard let queue else { return false }
        return CMSimpleQueueGetCount(queue) >= CMSimpleQueueGetCapacity(queue)
    }

    /// Logs a failure once (connect() is retried every 2 s).
    private func fail(_ message: String) -> Bool {
        if message != lastFailure {
            appLog.error("sink: \(message, privacy: .public)")
            lastFailure = message
        }
        return false
    }

    /// Finds the virtual camera and starts its sink stream. Safe to call repeatedly.
    @discardableResult
    func connect() -> Bool {
        if isConnected { return true }
        guard let device = findDevice() else { return fail("virtual camera device not found") }
        guard let sink = sinkStream(of: device) else { return fail("sink stream not found") }

        var unmanagedQueue: Unmanaged<CMSimpleQueue>?
        let status = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &unmanagedQueue)
        guard status == noErr, let q = unmanagedQueue?.takeRetainedValue() else {
            return fail("CMIOStreamCopyBufferQueue failed: \(status)")
        }
        let startStatus = CMIODeviceStartStream(device, sink)
        guard startStatus == noErr else {
            return fail("CMIODeviceStartStream failed: \(startStatus)")
        }
        deviceID = device
        streamID = sink
        queue = q
        lastFailure = ""
        appLog.info("sink: connected")
        return true
    }

    func disconnect() {
        guard isConnected else { return }
        CMIODeviceStopStream(deviceID, streamID)
        queue = nil
        deviceID = 0
        streamID = 0
    }

    /// Sends one 32BGRA pixel buffer (must match the extension's 1280x720 format).
    private var lastSendError = ""
    var debugSummary: String {
        guard let queue else { return "queue=nil" }
        return "queue=\(CMSimpleQueueGetCount(queue))/\(CMSimpleQueueGetCapacity(queue)) lastError=\(lastSendError)"
    }

    @discardableResult
    func send(_ pixelBuffer: CVPixelBuffer) -> Bool {
        guard let queue else { return false }
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { lastSendError = "queue full"; return false }

        if formatDescription == nil || !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: pixelBuffer) {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                         imageBuffer: pixelBuffer,
                                                         formatDescriptionOut: &formatDescription)
        }
        guard let formatDescription else { lastSendError = "no format"; return false }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sbuf: CMSampleBuffer?
        let err = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                           imageBuffer: pixelBuffer,
                                                           formatDescription: formatDescription,
                                                           sampleTiming: &timing,
                                                           sampleBufferOut: &sbuf)
        guard err == noErr, let sbuf else { lastSendError = "sbuf \(err)"; return false }
        let enqueueStatus = CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sbuf).toOpaque())
        if enqueueStatus != noErr {
            Unmanaged.passUnretained(sbuf).release()
            lastSendError = "enqueue \(enqueueStatus)"
            return false
        }
        return true
    }

    // MARK: - CoreMediaIO lookup

    private func findDevice() -> CMIOObjectID? {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let devices: [CMIOObjectID] = readArray(CMIOObjectID(kCMIOObjectSystemObject), &addr)

        for device in devices {
            var uidAddr = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var uid: Unmanaged<CFString>?
            var used: UInt32 = 0
            let status = CMIOObjectGetPropertyData(device, &uidAddr, 0, nil,
                                                   UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, &uid)
            if status == noErr, let value = uid?.takeRetainedValue() as String?, value == kDeviceUID {
                return device
            }
        }
        return nil
    }

    /// How many apps are reading the virtual camera, from the extension's custom sink-stream
    /// property 'vcsr'. nil if unknown (not connected, or an older extension without it).
    func sourceClientCount() -> Int? {
        guard isConnected else { return nil }
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(0x7663_7372), // 'vcsr'
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        guard CMIOObjectHasProperty(streamID, &addr) else { return nil }
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(streamID, &addr, 0, nil,
                                               UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, &value)
        guard status == noErr, let string = value?.takeRetainedValue() as String? else { return nil }
        return Int(string)
    }

    private func sinkStream(of device: CMIOObjectID) -> CMIOStreamID? {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let streams: [CMIOStreamID] = readArray(device, &addr)
        // The extension adds the source stream first and the sink stream second.
        return streams.count >= 2 ? streams[1] : nil
    }

    private func readArray<T: FixedWidthInteger>(_ object: CMIOObjectID, _ addr: inout CMIOObjectPropertyAddress) -> [T] {
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var items = [T](repeating: 0, count: Int(size) / MemoryLayout<T>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &items) == noErr else { return [] }
        return items
    }
}
