import CoreGraphics
import Foundation

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
    /// Frame rate of the tracker that produced the trajectory (240 for the M1 fast path).
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
}
