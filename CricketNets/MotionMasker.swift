import CoreImage
import CoreMedia
import CoreVideo
import CoreGraphics

/// Isolates moving pixels by differencing each frame against the previous one, so the trajectory
/// detector only ever sees motion (the ball) and the static background is invisible to it. This is
/// the strongest noise filter — Apple's own ball-tracking sample uses the same difference-image idea.
///
/// The output preserves the source frame's timing, which the stateful trajectory request needs.
final class MotionMasker {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var previous: CIImage?
    private var pool: CVPixelBufferPool?
    private var poolW = 0, poolH = 0

    /// Difference sharpening. Higher contrast + more negative brightness = only stronger motion
    /// survives (fainter background shimmer is pushed to black).
    var contrast: Double = 4.0
    var brightness: Double = -0.35

    /// Forget the previous frame (call when tracking restarts so a stale frame isn't differenced).
    func reset() { previous = nil }

    /// Produce a motion-mask sample buffer (moving pixels bright on black). Returns nil on the very
    /// first frame (nothing to difference against yet) or on failure — the caller skips that frame.
    func maskedSampleBuffer(from sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let current = CIImage(cvPixelBuffer: pixelBuffer)
        defer { previous = current }
        guard let previous else { return nil }

        // |current − previous|, then desaturate and hard-contrast into a bright-on-black mask.
        let diff = current.applyingFilter("CIDifferenceBlendMode",
                                          parameters: [kCIInputBackgroundImageKey: previous])
        let mask = diff.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0,
            kCIInputContrastKey: contrast,
            kCIInputBrightnessKey: brightness,
        ])

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard let output = makeBuffer(w, h) else { return nil }
        context.render(mask, to: output,
                       bounds: CGRect(x: 0, y: 0, width: w, height: h),
                       colorSpace: colorSpace)

        return SampleBufferFactory.make(from: output, timing: Self.timing(of: sample))
    }

    // MARK: Plumbing

    private static func timing(of sample: CMSampleBuffer) -> CMSampleTimingInfo {
        CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sample),
                           presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
                           decodeTimeStamp: .invalid)
    }

    private func makeBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        if pool == nil || poolW != w || poolH != h {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &created)
            pool = created; poolW = w; poolH = h
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

}
