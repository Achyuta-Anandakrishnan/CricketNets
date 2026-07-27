import CoreVideo
import CoreGraphics

/// What the ball looks like, learned from a calibration sample. A detected trajectory is only
/// accepted if the pixels at the ball's position match this color — that's what rejects hands,
/// the bat, players moving in the background, etc.
struct BallProfile: Equatable, Codable {
    var hue: Double          // 0...1
    var saturation: Double   // 0...1
    var brightness: Double   // 0...1

    // Tolerances — how far a pixel can drift from the sample and still count as "the ball".
    // Deliberately tight so the tracker locks onto the ball's color and rejects everything else.
    // NOT persisted (see CodingKeys) so tuning them here applies to already-saved calibrations too.
    var hueTol: Double = 0.04
    var satTol: Double = 0.20
    var valTol: Double = 0.28

    // Apparent-size gate for the trajectory request (normalized radius). Broad by default because
    // the ball is small and far during play even though it's held close during calibration.
    var minRadius: Double = 0.005
    var maxRadius: Double = 0.06

    // Persist only the measured color + size gate; tolerances always come from the current defaults.
    enum CodingKeys: String, CodingKey {
        case hue, saturation, brightness, minRadius, maxRadius
    }

    func matches(h: Double, s: Double, v: Double) -> Bool {
        // For a near-grey/white ball, hue is unstable — match on saturation + brightness instead.
        let hueOK: Bool
        if saturation < 0.2 {
            hueOK = true
        } else {
            var dh = abs(h - hue)
            if dh > 0.5 { dh = 1 - dh }   // hue is a circle
            hueOK = dh <= hueTol
        }
        return hueOK && abs(s - saturation) <= satTol && abs(v - brightness) <= valTol
    }

    var displayRGB: (Double, Double, Double) { BallColor.hsvToRGB(hue, saturation, brightness) }
}

/// Color sampling from a `CVPixelBuffer`.
///
/// Two pixel formats reach this code and they are not interchangeable:
/// - **BGRA**, which `CameraController` explicitly requests for the fast 2D path.
/// - **Bi-planar YCbCr**, which is what ARKit hands out in `ARFrame.capturedImage` — it cannot be
///   configured, so the 3D path has no choice about it.
///
/// Treating the second as the first is not a near miss. A bi-planar buffer's `CVPixelBufferGetBaseAddress`
/// returns a non-null pointer to planar *metadata* rather than pixels, so a BGRA reader sails past the
/// nil check and then strides `x * 4` through a row that doesn't exist — reading well out of bounds and
/// returning noise. Every trajectory then fails the color gate and the 3D path silently tracks nothing.
enum BallColor {

    /// Average RGB (0...1) over a square patch centered on a pixel, whatever the buffer's format.
    static func averageRGB(_ buffer: CVPixelBuffer, cx: Int, cy: Int, r: Int) -> (Double, Double, Double)? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_32BGRA:
            return averageBGRA(buffer, cx: cx, cy: cy, r: r)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return averageYCbCr(buffer, cx: cx, cy: cy, r: r, videoRange: false)
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return averageYCbCr(buffer, cx: cx, cy: cy, r: r, videoRange: true)
        default:
            return nil   // better no reading than a confidently wrong one
        }
    }

    /// Packed 8-bit BGRA, one plane.
    private static func averageBGRA(_ buffer: CVPixelBuffer, cx: Int, cy: Int, r: Int) -> (Double, Double, Double)? {
        guard !CVPixelBufferIsPlanar(buffer), let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        let x0 = max(0, cx - r), x1 = min(w - 1, cx + r)
        let y0 = max(0, cy - r), y1 = min(h - 1, cy + r)
        guard x0 <= x1, y0 <= y1 else { return nil }

        var rs = 0.0, gs = 0.0, bs = 0.0, n = 0.0
        var y = y0
        while y <= y1 {
            let row = y * rowBytes
            var x = x0
            while x <= x1 {
                let p = row + x * 4          // BGRA
                bs += Double(ptr[p]); gs += Double(ptr[p + 1]); rs += Double(ptr[p + 2])
                n += 1; x += 1
            }
            y += 1
        }
        guard n > 0 else { return nil }
        return (rs / n / 255, gs / n / 255, bs / n / 255)
    }

    /// Bi-planar YCbCr 4:2:0 — plane 0 is full-resolution luma, plane 1 is half-resolution
    /// interleaved chroma, so each 2x2 block of luma shares one Cb/Cr pair.
    private static func averageYCbCr(_ buffer: CVPixelBuffer, cx: Int, cy: Int, r: Int,
                                     videoRange: Bool) -> (Double, Double, Double)? {
        guard CVPixelBufferGetPlaneCount(buffer) >= 2,
              let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
        else { return nil }

        let w = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaW = CVPixelBufferGetWidthOfPlane(buffer, 1)
        let chromaH = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)

        let luma = lumaBase.assumingMemoryBound(to: UInt8.self)
        let chroma = chromaBase.assumingMemoryBound(to: UInt8.self)

        let x0 = max(0, cx - r), x1 = min(w - 1, cx + r)
        let y0 = max(0, cy - r), y1 = min(h - 1, cy + r)
        guard x0 <= x1, y0 <= y1 else { return nil }

        var rs = 0.0, gs = 0.0, bs = 0.0, n = 0.0
        var y = y0
        while y <= y1 {
            let cRow = min(y / 2, chromaH - 1) * chromaRow
            var x = x0
            while x <= x1 {
                var yy = Double(luma[y * lumaRow + x])
                let cIndex = cRow + min(x / 2, chromaW - 1) * 2
                var cb = Double(chroma[cIndex]) - 128
                var cr = Double(chroma[cIndex + 1]) - 128

                // Video-range packs luma into 16...235 and chroma into 16...240; stretch to full.
                if videoRange {
                    yy = (yy - 16) * 255 / 219
                    cb *= 255 / 224
                    cr *= 255 / 224
                }

                // BT.601, the matrix these 4:2:0 camera formats are encoded with.
                rs += yy + 1.402 * cr
                gs += yy - 0.344136 * cb - 0.714136 * cr
                bs += yy + 1.772 * cb
                n += 1; x += 1
            }
            y += 1
        }
        guard n > 0 else { return nil }
        func clamp(_ v: Double) -> Double { min(max(v / n / 255, 0), 1) }
        return (clamp(rs), clamp(gs), clamp(bs))
    }

    /// Sample HSV at a Vision-normalized point (origin bottom-left) — used to color-check a detection.
    static func sampleHSV(_ buffer: CVPixelBuffer, atNormalized p: CGPoint, radiusPx: Int) -> (h: Double, s: Double, v: Double)? {
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let cx = Int(p.x * CGFloat(w))
        let cy = Int((1 - p.y) * CGFloat(h))     // bottom-left (Vision) → top-left (buffer)
        guard let rgb = averageRGB(buffer, cx: cx, cy: cy, r: radiusPx) else { return nil }
        return rgbToHSV(rgb.0, rgb.1, rgb.2)
    }

    /// Build a profile from a patch centered in the buffer (used by the calibration reticle).
    static func sampleProfile(_ buffer: CVPixelBuffer, centerNormalized c: CGPoint, radiusNormalized rn: CGFloat) -> BallProfile? {
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let cx = Int(c.x * CGFloat(w)), cy = Int(c.y * CGFloat(h))
        let r = max(2, Int(rn * CGFloat(min(w, h))))
        guard let rgb = averageRGB(buffer, cx: cx, cy: cy, r: r) else { return nil }
        let hsv = rgbToHSV(rgb.0, rgb.1, rgb.2)
        return BallProfile(hue: hsv.h, saturation: hsv.s, brightness: hsv.v)
    }

    // MARK: Bulk scanning

    /// Reads single pixels as RGB without re-locking the buffer. Only valid inside
    /// `withPixelReader`, which owns the lock.
    struct PixelReader {
        let width: Int
        let height: Int
        fileprivate let kind: Kind

        fileprivate enum Kind {
            case bgra(ptr: UnsafePointer<UInt8>, rowBytes: Int)
            case ycbcr(luma: UnsafePointer<UInt8>, lumaRow: Int,
                       chroma: UnsafePointer<UInt8>, chromaRow: Int,
                       chromaW: Int, chromaH: Int, videoRange: Bool)
        }

        func rgb(x: Int, y: Int) -> (Double, Double, Double) {
            switch kind {
            case let .bgra(ptr, rowBytes):
                let p = y * rowBytes + x * 4
                return (Double(ptr[p + 2]) / 255, Double(ptr[p + 1]) / 255, Double(ptr[p]) / 255)

            case let .ycbcr(luma, lumaRow, chroma, chromaRow, chromaW, chromaH, videoRange):
                var yy = Double(luma[y * lumaRow + x])
                let ci = min(y / 2, chromaH - 1) * chromaRow + min(x / 2, chromaW - 1) * 2
                var cb = Double(chroma[ci]) - 128
                var cr = Double(chroma[ci + 1]) - 128
                if videoRange {
                    yy = (yy - 16) * 255 / 219
                    cb *= 255 / 224
                    cr *= 255 / 224
                }
                func clamp(_ v: Double) -> Double { min(max(v / 255, 0), 1) }
                return (clamp(yy + 1.402 * cr),
                        clamp(yy - 0.344136 * cb - 0.714136 * cr),
                        clamp(yy + 1.772 * cb))
            }
        }
    }

    /// Lock the buffer once and scan many pixels inside `body`.
    ///
    /// Sampling a whole frame through `averageRGB` would lock and unlock per pixel, which at tens of
    /// thousands of pixels a frame is far too slow to run live.
    static func withPixelReader<T>(_ buffer: CVPixelBuffer, _ body: (PixelReader) -> T) -> T? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_32BGRA:
            guard !CVPixelBufferIsPlanar(buffer), let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let reader = PixelReader(
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer),
                kind: .bgra(ptr: UnsafePointer(base.assumingMemoryBound(to: UInt8.self)),
                            rowBytes: CVPixelBufferGetBytesPerRow(buffer)))
            return body(reader)

        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard CVPixelBufferGetPlaneCount(buffer) >= 2,
                  let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                  let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
            else { return nil }
            let videoRange = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            let reader = PixelReader(
                width: CVPixelBufferGetWidthOfPlane(buffer, 0),
                height: CVPixelBufferGetHeightOfPlane(buffer, 0),
                kind: .ycbcr(luma: UnsafePointer(lumaBase.assumingMemoryBound(to: UInt8.self)),
                             lumaRow: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
                             chroma: UnsafePointer(chromaBase.assumingMemoryBound(to: UInt8.self)),
                             chromaRow: CVPixelBufferGetBytesPerRowOfPlane(buffer, 1),
                             chromaW: CVPixelBufferGetWidthOfPlane(buffer, 1),
                             chromaH: CVPixelBufferGetHeightOfPlane(buffer, 1),
                             videoRange: videoRange))
            return body(reader)

        default:
            return nil
        }
    }

    static func rgbToHSV(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d != 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        let s = mx == 0 ? 0 : d / mx
        return (h, s, mx)
    }

    static func hsvToRGB(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        if s == 0 { return (v, v, v) }
        let sextant = h * 6
        let i = Int(sextant) % 6
        let f = sextant - Double(Int(sextant))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}
