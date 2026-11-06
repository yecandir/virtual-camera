import CoreImage
import CoreVideo

/// Same effects as the Chrome extension (canvas filters there, Core Image here).
struct Effects: Codable, Equatable {
    var mirror = false
    /// Multiplies RGB, like CSS `brightness()`. 0.5 … 1.5
    var brightness: Double = 1
    /// Gaussian blur standard deviation in pixels at 1280x720, like CSS `blur()`. 0 … 10
    var blur: Double = 0

    static let defaults = Effects()
}

/// Turns any source frame into a 1280x720 BGRA frame for the virtual camera: cover-fit + effects.
final class FrameRenderer {
    static let width = 1280
    static let height = 720

    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    init() {
        let attrs: NSDictionary = [
            kCVPixelBufferWidthKey: Self.width,
            kCVPixelBufferHeightKey: Self.height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs, &pool)
    }

    func render(_ source: CVPixelBuffer, effects: Effects) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out)
        guard let out else { return nil }

        let w = CGFloat(Self.width), h = CGFloat(Self.height)
        let frame = CGRect(x: 0, y: 0, width: w, height: h)

        // Cover-fit (center crop).
        var image = CIImage(cvPixelBuffer: source)
        let scale = max(w / image.extent.width, h / image.extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        image = image.transformed(by: CGAffineTransform(
            translationX: (w - image.extent.width) / 2 - image.extent.minX,
            y: (h - image.extent.height) / 2 - image.extent.minY))

        if effects.mirror {
            image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0))
        }
        if effects.brightness != 1 {
            let b = CGFloat(effects.brightness)
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: b, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: b, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
            ])
        }
        if effects.blur > 0 {
            image = image.clampedToExtent().applyingGaussianBlur(sigma: effects.blur)
        }

        context.render(image.cropped(to: frame), to: out, bounds: frame, colorSpace: colorSpace)
        return out
    }

    /// Small preview image for the UI.
    func cgImage(_ buffer: CVPixelBuffer, maxWidth: CGFloat = 640) -> CGImage? {
        var image = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, maxWidth / image.extent.width)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(image, from: image.extent)
    }
}
