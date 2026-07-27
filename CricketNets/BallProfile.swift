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

/// Color sampling from a BGRA `CVPixelBuffer` (the format the capture output delivers).
enum BallColor {

    /// Average RGB (0...1) over a square patch centered on a pixel.
    static func averageRGB(_ buffer: CVPixelBuffer, cx: Int, cy: Int, r: Int) -> (Double, Double, Double)? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
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
