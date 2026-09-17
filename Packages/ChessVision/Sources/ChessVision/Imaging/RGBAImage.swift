import CoreGraphics
import Foundation

/// An 8-bit RGBA pixel buffer in sRGB with a top-left origin. Transparent pixels are black; when
/// `hasTransparency` is true the fourth byte of each pixel is its alpha and pixels with alpha
/// below `opaqueAlpha` count as outside the image.
@_spi(Testing)
public struct RGBAImage: Sendable {
    public let width: Int
    public let height: Int
    /// `width * height * 4` bytes, RGBA per pixel, row-major from the top-left.
    public let data: [UInt8]
    /// Some pixels are transparent (alpha below `opaqueAlpha` in the fourth byte). False for
    /// buffers built from bytes, whose fourth byte is ignored.
    public let hasTransparency: Bool

    /// Alpha from which a pixel counts as part of the image.
    public static let opaqueAlpha: UInt8 = 128
    /// Longest side analyzed: larger images are drawn smaller (`bounded(cgImage:maximumSide:)`).
    /// Board cells stay above 100 px for any realistic screenshot, and memory stays bounded.
    public static let maximumAnalyzedSide = 4096

    public init(width: Int, height: Int, data: [UInt8]) {
        self.init(width: width, height: height, data: data, hasTransparency: false)
    }

    init(width: Int, height: Int, data: [UInt8], hasTransparency: Bool) {
        precondition(data.count == width * height * 4)
        self.width = width
        self.height = height
        self.data = data
        self.hasTransparency = hasTransparency
    }

    /// Draws `cgImage` into an sRGB buffer. Screenshots tagged Display P3 are converted, so the
    /// values match the sRGB colors the app drew. Transparent areas come out black.
    public init?(cgImage: CGImage) {
        self.init(cgImage: cgImage, width: cgImage.width, height: cgImage.height)
    }

    /// Draws `cgImage` scaled down (high-quality interpolation) so that its longer side is at most
    /// `maximumSide`; `scale` is the factor from source to buffer pixels (1 when not scaled).
    public static func bounded(cgImage: CGImage, maximumSide: Int = maximumAnalyzedSide) -> (image: RGBAImage, scale: Double)? {
        let longSide = max(cgImage.width, cgImage.height)
        guard longSide > maximumSide else {
            return RGBAImage(cgImage: cgImage).map { ($0, 1) }
        }
        let scale = Double(maximumSide) / Double(longSide)
        let w = max(1, Int((Double(cgImage.width) * scale).rounded()))
        let h = max(1, Int((Double(cgImage.height) * scale).rounded()))
        return RGBAImage(cgImage: cgImage, width: w, height: h).map { ($0, scale) }
    }

    private init?(cgImage: CGImage, width w: Int, height h: Int) {
        guard w > 0, h > 0, w <= 16_384, h <= 16_384,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let alphaInfo = cgImage.alphaInfo
        let mayHaveAlpha = !(alphaInfo == .none || alphaInfo == .noneSkipLast || alphaInfo == .noneSkipFirst)
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            // Premultiplied RGB equals the image drawn over black, as an opaque buffer gives, and
            // the fourth byte keeps the alpha.
            guard let context = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = (w == cgImage.width && h == cgImage.height) ? .none : .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var transparent = false
        if mayHaveAlpha {
            buffer.withUnsafeBufferPointer { b in
                var p = 3
                while p < b.count {
                    if b[p] < Self.opaqueAlpha { transparent = true; break }
                    p += 4
                }
            }
        }
        self.init(width: w, height: h, data: buffer, hasTransparency: transparent)
    }

    /// Whether the pixel at byte offset `p` (a multiple of 4 inside the buffer) counts as part of
    /// the image.
    @inline(__always)
    func isOpaque(offset p: Int) -> Bool {
        !hasTransparency || data[p + 3] >= Self.opaqueAlpha
    }

    /// A CGImage of this buffer (used for debug overlays and tests).
    public func makeCGImage() -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// Box-filter downscale by an integer factor into a packed RGB (3 bytes per pixel) plane.
    func downscaledRGB(factor: Int) -> RGBPlane {
        let f = max(1, factor)
        let ow = width / f, oh = height / f
        var out = [UInt8](repeating: 0, count: ow * oh * 3)
        let area = f * f
        data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                parallelRows(oh) { oy in
                    for ox in 0..<ow {
                        var r = 0, g = 0, b = 0
                        for yy in 0..<f {
                            var p = ((oy * f + yy) * width + ox * f) * 4
                            for _ in 0..<f {
                                r += Int(src[p]); g += Int(src[p + 1]); b += Int(src[p + 2])
                                p += 4
                            }
                        }
                        let o = (oy * ow + ox) * 3
                        dst[o] = UInt8(r / area); dst[o + 1] = UInt8(g / area); dst[o + 2] = UInt8(b / area)
                    }
                }
            }
        }
        return RGBPlane(width: ow, height: oh, data: out)
    }
}

/// Packed 8-bit RGB, 3 bytes per pixel.
struct RGBPlane: Sendable {
    let width: Int
    let height: Int
    let data: [UInt8]
}

/// An RGB color with Double components in 0...255.
@_spi(Testing)
public struct RGB: Sendable, Hashable, CustomStringConvertible {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    public init(hex: UInt32) {
        self.init(Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF))
    }

    /// Sum of absolute channel differences (0...765).
    public func distance(to other: RGB) -> Double {
        abs(r - other.r) + abs(g - other.g) + abs(b - other.b)
    }

    public var luminance: Double { 0.299 * r + 0.587 * g + 0.114 * b }

    public static func + (a: RGB, b: RGB) -> RGB { RGB(a.r + b.r, a.g + b.g, a.b + b.b) }
    public static func - (a: RGB, b: RGB) -> RGB { RGB(a.r - b.r, a.g - b.g, a.b - b.b) }
    public static func * (a: RGB, k: Double) -> RGB { RGB(a.r * k, a.g * k, a.b * k) }

    public func dot(_ o: RGB) -> Double { r * o.r + g * o.g + b * o.b }

    public var description: String {
        String(format: "#%02X%02X%02X", Int(max(0, min(255, r)).rounded()), Int(max(0, min(255, g)).rounded()),
               Int(max(0, min(255, b)).rounded()))
    }

    /// Per-channel median of `colors` (nil when empty).
    public static func median(_ colors: [RGB]) -> RGB? {
        guard !colors.isEmpty else { return nil }
        func med(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            let n = sorted.count
            return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
        }
        return RGB(med(colors.map(\.r)), med(colors.map(\.g)), med(colors.map(\.b)))
    }
}

// MARK: - Parallel helpers

/// A fixed-size buffer that parallel workers write to at distinct indices.
final class ParallelBuffer<Element>: @unchecked Sendable {
    let pointer: UnsafeMutableBufferPointer<Element>

    init(repeating value: Element, count: Int) {
        pointer = .allocate(capacity: count)
        pointer.initialize(repeating: value)
    }

    deinit {
        pointer.deinitialize()
        pointer.deallocate()
    }

    subscript(index: Int) -> Element {
        get { pointer[index] }
        set { pointer[index] = newValue }
    }

    var array: [Element] { Array(pointer) }
}

/// Runs `body` for each row index, splitting rows into chunks across cores.
func parallelRows(_ count: Int, minimumRowsPerChunk: Int = 16, _ body: (Int) -> Void) {
    guard count > 0 else { return }
    let cores = ProcessInfo.processInfo.activeProcessorCount
    let chunks = max(1, min(cores * 2, count / max(1, minimumRowsPerChunk)))
    if chunks == 1 {
        for i in 0..<count { body(i) }
        return
    }
    withoutActuallyEscaping(body) { escapable in
        let box = UncheckedSendableBox(escapable)
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            let start = count * chunk / chunks
            let end = count * (chunk + 1) / chunks
            for i in start..<end { box.value(i) }
        }
    }
}

/// Maps `0..<count` in parallel.
func parallelMap<T>(_ count: Int, _ transform: (Int) -> T) -> [T] {
    guard count > 0 else { return [] }
    var results = [T?](repeating: nil, count: count)
    results.withUnsafeMutableBufferPointer { buffer in
        let out = UncheckedSendableBox(buffer)
        withoutActuallyEscaping(transform) { escapable in
            let box = UncheckedSendableBox(escapable)
            DispatchQueue.concurrentPerform(iterations: count) { i in
                out.value[i] = box.value(i)
            }
        }
    }
    return results.map { $0! }
}

struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
