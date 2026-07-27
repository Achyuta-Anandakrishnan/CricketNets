import ARKit
import AVFoundation

/// What this device can actually deliver, measured rather than assumed.
///
/// The frame rate ceiling decides whether the depth path can work at all. A 160 km/h shot crosses
/// the view in about 0.08 s, so at 60 fps it is seen 3-6 times — barely enough to fit a launch
/// vector, and less than that once a frame or two fails to resolve. Doubling the rate doubles the
/// samples, so it is worth knowing exactly what is on offer instead of trusting documentation.
///
/// Two pipelines can supply depth, and they have different limits:
/// - **ARKit** (`sceneDepth`) — what the app uses now. Gives camera pose for free, but its video
///   formats are capped, in practice at 60 fps.
/// - **AVFoundation** (`builtInLiDARDepthCamera`) — video and depth as separate outputs, without
///   ARKit's format restrictions. No camera pose, which only matters if the phone is moving. On a
///   tripod it isn't moving, and azimuth is already measured against a user-set direction, so the
///   pose may cost nothing to lose.
enum CaptureCapabilities {

    struct VideoOption: Identifiable {
        let id = UUID()
        let width: Int
        let height: Int
        let fps: Double
        var label: String { "\(width)×\(height) @ \(Int(fps)) fps" }
    }

    struct Report {
        var arKitFormats: [VideoOption] = []
        var lidarCameraFormats: [VideoOption] = []
        var hasLiDARCamera = false
        var arKitSupportsSceneDepth = false

        var bestARKitFPS: Double { arKitFormats.map(\.fps).max() ?? 0 }
        var bestLiDARCameraFPS: Double { lidarCameraFormats.map(\.fps).max() ?? 0 }

        /// The headline: is there anything faster than what we already use?
        var fasterPathExists: Bool { bestLiDARCameraFPS > bestARKitFPS }
    }

    static func probe() -> Report {
        var report = Report()

        report.arKitSupportsSceneDepth =
            ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)

        // ARKit only advertises formats it can actually run; scene depth narrows that further, so
        // this list is what the current pipeline is really choosing between.
        for format in ARWorldTrackingConfiguration.supportedVideoFormats {
            report.arKitFormats.append(VideoOption(
                width: Int(format.imageResolution.width),
                height: Int(format.imageResolution.height),
                fps: Double(format.framesPerSecond)))
        }

        // The AVFoundation route. Its formats belong to the camera device rather than to ARKit, so
        // high-frame-rate modes that ARKit refuses may still be available here.
        if let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) {
            report.hasLiDARCamera = true
            for format in device.formats {
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                // Only formats that can actually carry depth are useful to us.
                guard !format.supportedDepthDataFormats.isEmpty else { continue }
                let best = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                report.lidarCameraFormats.append(VideoOption(
                    width: Int(dims.width), height: Int(dims.height), fps: best))
            }
        }

        // Fastest first, and drop duplicates so the list stays readable.
        report.arKitFormats = dedupe(report.arKitFormats)
        report.lidarCameraFormats = dedupe(report.lidarCameraFormats)
        return report
    }

    private static func dedupe(_ options: [VideoOption]) -> [VideoOption] {
        var seen = Set<String>()
        return options
            .sorted { $0.fps == $1.fps ? $0.width > $1.width : $0.fps > $1.fps }
            .filter { seen.insert($0.label).inserted }
    }

    /// How many frames a shot at `speedKmh` is visible for, given a frame rate and standoff.
    ///
    /// Field of view is the binding constraint, not LiDAR range: the ball crosses the view long
    /// before it leaves the sensor's reach. Standing further back widens the view faster than the
    /// ball crosses it, so distance buys frames — up to LiDAR's limit.
    static func expectedFrames(speedKmh: Double, distance: Double, fps: Double,
                               horizontalFOVDegrees: Double) -> Double {
        guard speedKmh > 0, distance > 0, fps > 0 else { return 0 }
        let visibleWidth = 2 * distance * tan(horizontalFOVDegrees * .pi / 180 / 2)
        return visibleWidth / (speedKmh / 3.6) * fps
    }

    /// Horizontal field of view in world terms.
    ///
    /// Which image axis spans the world horizontally depends on how the phone is held — and the app
    /// is portrait-locked, so it is the capture's *short* axis doing the work. That costs roughly a
    /// quarter of the available view compared with holding the phone landscape.
    static func horizontalFOVDegrees(focalLengthPx: Double, imageWidth: Double, imageHeight: Double,
                                     portrait: Bool) -> Double {
        let spanningAxis = portrait ? min(imageWidth, imageHeight) : max(imageWidth, imageHeight)
        return 2 * atan(spanningAxis / (2 * focalLengthPx)) * 180 / .pi
    }
}
