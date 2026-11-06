import AVFoundation

/// Must match `kDeviceUID` in Extension/ExtensionProvider.swift.
let kVirtualCameraUID = "6B8E1C2A-4F1D-4C8B-9E3A-2D7F5A1B0C01"

struct CameraInfo: Identifiable, Hashable {
    let id: String
    let name: String
}

/// The real (physical) camera. Shared by the live virtual-camera feed and the recorder;
/// the capture session only runs while at least one of them has acquired it.
final class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "vcam.camera", qos: .userInteractive)

    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var handlers: [String: (CMSampleBuffer) -> Void] = [:]
    private var users = Set<String>()
    private var currentDeviceID: String?

    static func availableCameras() -> [CameraInfo] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices
            .filter { $0.uniqueID != kVirtualCameraUID }
            .map { CameraInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    override init() {
        super.init()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
    }

    /// Picks the camera to use (nil = first available).
    func setDevice(_ uniqueID: String?) {
        queue.async { [self] in
            let id = uniqueID ?? Self.availableCameras().first?.id
            guard id != currentDeviceID else { return }
            setDeviceSync(id)
            lock.withLock { latest = nil }
        }
    }

    func acquire(_ user: String) {
        queue.async { [self] in
            guard users.insert(user).inserted, users.count == 1 else { return }
            if currentDeviceID == nil { setDeviceSync(nil) }
            session.startRunning()
        }
    }

    func release(_ user: String) {
        queue.async { [self] in
            guard users.remove(user) != nil, users.isEmpty else { return }
            session.stopRunning()
            lock.withLock { latest = nil }
        }
    }

    var latestFrame: CVPixelBuffer? { lock.withLock { latest } }

    func addHandler(_ key: String, _ handler: @escaping (CMSampleBuffer) -> Void) {
        lock.withLock { handlers[key] = handler }
    }

    func removeHandler(_ key: String) {
        lock.withLock { _ = handlers.removeValue(forKey: key) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let pixels = CMSampleBufferGetImageBuffer(sampleBuffer)
        let current = lock.withLock { () -> [(CMSampleBuffer) -> Void] in
            latest = pixels
            return Array(handlers.values)
        }
        current.forEach { $0(sampleBuffer) }
    }

    private func setDeviceSync(_ uniqueID: String?) {
        guard let id = uniqueID ?? Self.availableCameras().first?.id,
              let device = AVCaptureDevice(uniqueID: id),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        if session.canAddInput(input) { session.addInput(input); currentDeviceID = id }
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        session.commitConfiguration()
    }
}
