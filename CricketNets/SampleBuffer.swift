import CoreMedia
import CoreVideo

/// Wraps a bare `CVPixelBuffer` into a `CMSampleBuffer` carrying a presentation timestamp.
///
/// `VNDetectTrajectoriesRequest` is stateful and derives its notion of time from the sample buffer,
/// so anything feeding it frames needs real timing attached. ARKit hands out `CVPixelBuffer` +
/// a separate timestamp, and the motion mask renders into a fresh buffer, so both need this.
enum SampleBufferFactory {

    static func make(from pixelBuffer: CVPixelBuffer, timing: CMSampleTimingInfo) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: pixelBuffer,
                                                     formatDescriptionOut: &formatDesc)
        guard let formatDesc else { return nil }
        var timing = timing
        var out: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                           imageBuffer: pixelBuffer,
                                           dataReady: true,
                                           makeDataReadyCallback: nil,
                                           refcon: nil,
                                           formatDescription: formatDesc,
                                           sampleTiming: &timing,
                                           sampleBufferOut: &out)
        return out
    }

    /// Convenience for sources that only have a timestamp in seconds (ARKit).
    static func make(from pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) -> CMSampleBuffer? {
        let pts = CMTime(seconds: timestamp, preferredTimescale: 1_000_000)
        return make(from: pixelBuffer,
                    timing: CMSampleTimingInfo(duration: .invalid,
                                               presentationTimeStamp: pts,
                                               decodeTimeStamp: .invalid))
    }
}
