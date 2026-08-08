import CoreGraphics
import Foundation
import simd

/// Standard cricket dimensions (meters) — used as real-world references for calibration.
enum CricketConstants {
    /// Width across all three stumps, outside edge to outside edge.
    static let wicketWidth = 0.2286
    /// Height of the stumps above the ground.
    static let stumpHeight = 0.7112
    /// Pitch length, popping crease to popping crease.
    static let pitchLength = 20.12
    /// A regulation ball's diameter. Circumference is 22.4–22.9 cm, so ~7.2 cm across.
    static let ballDiameter = 0.072
}

/// Real-world scene geometry that turns image-space tracking into metric measurements.
/// Populated either by a manual reference (mark a known object in the frame) or by LiDAR.
struct SceneCalibration: Equatable {
    /// Meters spanned by one full normalized image-width unit, at the ball's flight plane.
    var metersPerNormalizedUnit: Double
    /// Distance (m) from camera to the ball's flight plane. From LiDAR or entered by hand.
    var planeDistance: Double
    /// Camera height above the ground (m). Sets where the launch point sits vertically.
    var cameraHeight: Double
    /// Frame rate of the tracker that produced the trajectory (120 for the M1 fast path).
    var fps: Double
    /// How the calibration was obtained — surfaced in the UI so the user knows to trust it or not.
    var source: Source

    enum Source: String, Equatable { case untuned, reference, lidar }

    /// Safe default so the app runs before any calibration. Numbers are rough guesses.
    static let untuned = SceneCalibration(
        metersPerNormalizedUnit: 3.0,
        planeDistance: 3.0,
        cameraHeight: 1.0,
        fps: 120,
        source: .untuned
    )

    /// Build from a known reference measured in the frame: two normalized points a known
    /// real distance apart, lying at (roughly) the ball's flight plane.
    /// Example: mark the two outer stumps → `realMeters = CricketConstants.wicketWidth`.
    static func fromReference(pointA: CGPoint,
                             pointB: CGPoint,
                             realMeters: Double,
                             planeDistance: Double,
                             cameraHeight: Double,
                             fps: Double) -> SceneCalibration {
        let dx = Double(pointA.x - pointB.x)
        let dy = Double(pointA.y - pointB.y)
        let normDist = max((dx * dx + dy * dy).squareRoot(), 1e-6)
        return SceneCalibration(
            metersPerNormalizedUnit: realMeters / normDist,
            planeDistance: planeDistance,
            cameraHeight: cameraHeight,
            fps: fps,
            source: .reference
        )
    }

    /// Place a ball sighting on the flight plane, in metres.
    ///
    /// The fast path sees an image and nothing else, so this is where an image position becomes a
    /// measurement: x runs along the ground, y is height above it, and z is fixed at zero because a
    /// single side-on camera cannot observe depth (see `BallPhysics.launchVector(planeSamples:)`).
    ///
    /// - Parameter p: normalized detection centre, **top-left origin**, as `BallDetector` reports it.
    /// - Parameter frameAspect: the capture buffer's height ÷ width.
    ///
    ///   This parameter is the whole reason the function exists. `metersPerNormalizedUnit` is metres
    ///   per frame *width*, but a normalized y of 1.0 spans the frame's *height* — so on a 9:16
    ///   portrait frame a given vertical movement is worth 1.78× as many metres as the same number
    ///   horizontally. Converting both axes at the same rate, as the old image-space fit did,
    ///   flattened every launch angle by exactly that ratio.
    func planeSample(at p: CGPoint, frameAspect: Double, time: TimeInterval) -> BallPhysics.WorldSample {
        let x = (Double(p.x) - 0.5) * metersPerNormalizedUnit
        // Image y grows downward and height grows upward, hence the flip. The camera looks out from
        // `cameraHeight`, so the middle of the frame is that high off the ground.
        let y = cameraHeight + (0.5 - Double(p.y)) * metersPerNormalizedUnit * frameAspect
        return BallPhysics.WorldSample(position: simd_float3(Float(x), Float(y), 0), time: time)
    }
}
