import Foundation
import CoreGraphics
import simd

/// The initial launch of the ball off the bat, in real-world terms.
struct LaunchVector {
    var speed: Double        // m/s
    var elevation: Double    // radians above the horizontal (launch angle)
    var azimuth: Double      // radians; 0 = straight down the ground, + = one side, - = the other
    var height: Double       // launch height above ground (m)

    var speedKmh: Double { speed * 3.6 }
    var elevationDeg: Double { elevation * 180 / .pi }
    var azimuthDeg: Double { azimuth * 180 / .pi }
}

/// Where the ball comes down, as a top-down field position with the batsman at the origin.
struct LandingPoint {
    var lateral: Double      // meters left(-)/right(+) of straight
    var down: Double         // meters down the ground
    var carry: Double        // straight-line ground distance from the batsman
    var maxHeight: Double    // apex height (m) — feeds "was it catchable" later
    var timeOfFlight: Double // seconds
}

/// Projectile maths. Gravity only — no air drag or swing/spin (a deliberate M2 simplification;
/// note it to users, since a real cricket ball's drag shortens carry noticeably at speed).
enum BallPhysics {
    static let g = 9.81

    // MARK: 3D path (LiDAR-informed, most accurate)

    /// Estimate the launch vector from 3D world points (meters, y up) sampled at `fps`.
    /// Uses the first two points for the initial velocity; a short linear fit could replace this
    /// for noise resistance once you see real data.
    static func launchVector(worldPoints: [simd_float3], fps: Double) -> LaunchVector? {
        guard worldPoints.count >= 2 else { return nil }
        let dt = 1.0 / fps
        let p0 = worldPoints[0], p1 = worldPoints[1]
        let v = (p1 - p0) / Float(dt)
        let vx = Double(v.x), vy = Double(v.y), vz = Double(v.z)
        let horizontal = (vx * vx + vz * vz).squareRoot()
        let speed = (vx * vx + vy * vy + vz * vz).squareRoot()
        let elevation = atan2(vy, horizontal)
        // ARKit world: -Z is "forward" (away from where the camera faced). Treat that as down-ground.
        let azimuth = atan2(vx, -vz)
        return LaunchVector(speed: speed, elevation: elevation, azimuth: azimuth, height: Double(p0.y))
    }

    // MARK: 2D path (fast tracker + calibration; azimuth is NOT observable — see below)

    /// Lift a 2D image trajectory (Vision normalized points, bottom-left origin) into a launch
    /// vector using the scene calibration.
    ///
    /// The setup this assumes is the one the README asks for: the phone side-on to the flight, so
    /// the image's horizontal axis runs down the ground and its vertical axis is height. Given that:
    ///
    /// - **Elevation** is directly observable, and reliable.
    /// - **Speed** is the flight speed *projected onto the image plane* — a lower bound on the true
    ///   speed, since a ball hit toward or away from the camera also carries depth motion we can't see.
    /// - **Azimuth is not observable at all.** A single side-on view cannot separate a straight drive
    ///   from a square cut: both trace the same path across the image, and even the sign of the
    ///   horizontal drift says which way *down the ground*, not which side of the wicket. It is
    ///   reported as 0 (straight) rather than guessed. Use `from3D` (LiDAR) for real left/right.
    ///
    /// Velocity comes from a least-squares fit across the whole trajectory rather than the first two
    /// points, so a single noisy detection no longer decides the shot.
    static func launchVector(imagePoints: [CGPoint], calibration c: SceneCalibration) -> LaunchVector? {
        guard imagePoints.count >= 2, c.fps > 0 else { return nil }

        // Mean image-plane velocity over the tracked window, in meters/second at the flight plane.
        let (slopeX, slopeY) = meanVelocityPerSecond(imagePoints, fps: c.fps)
        let vx = slopeX * c.metersPerNormalizedUnit
        var vy = slopeY * c.metersPerNormalizedUnit

        // A linear fit of y(t) returns the *mean* vertical velocity, but gravity has already been
        // pulling the ball down across the window. For y = vy₀·t − ½g·t² the mean slope over [0, T]
        // is vy₀ − g·T/2, so add that back to recover the velocity at the first tracked point.
        let window = Double(imagePoints.count - 1) / c.fps
        vy += g * window / 2

        let speed = (vx * vx + vy * vy).squareRoot()
        guard speed > 0 else { return nil }
        let elevation = atan2(vy, abs(vx))
        return LaunchVector(speed: speed, elevation: elevation, azimuth: 0, height: c.cameraHeight)
    }

    /// Least-squares slope of x(t) and y(t) across the detected points, in normalized units per
    /// second. Vision reports one point per analyzed frame, so sample i sits at t = i / fps.
    private static func meanVelocityPerSecond(_ points: [CGPoint], fps: Double) -> (Double, Double) {
        let n = Double(points.count)
        let meanT = (n - 1) / 2                    // in frames
        let meanX = points.reduce(0.0) { $0 + Double($1.x) } / n
        let meanY = points.reduce(0.0) { $0 + Double($1.y) } / n

        var stt = 0.0, stx = 0.0, sty = 0.0
        for (i, p) in points.enumerated() {
            let dt = Double(i) - meanT
            stt += dt * dt
            stx += dt * (Double(p.x) - meanX)
            sty += dt * (Double(p.y) - meanY)
        }
        guard stt > 0 else { return (0, 0) }
        // Slope is per frame; × fps converts to per second.
        return (stx / stt * fps, sty / stt * fps)
    }

    // MARK: Projection

    /// Project a launch vector to its landing point on a flat field.
    static func land(_ l: LaunchVector) -> LandingPoint {
        let v = l.speed, theta = l.elevation, h = max(l.height, 0)
        let vy = v * sin(theta)
        let vHoriz = v * cos(theta)
        // Solve h + vy·t − ½g·t² = 0 for the positive root.
        let t = (vy + (vy * vy + 2 * g * h).squareRoot()) / g
        let dist = vHoriz * t
        let maxHeight = h + (vy > 0 ? (vy * vy) / (2 * g) : 0)
        return LandingPoint(
            lateral: dist * sin(l.azimuth),
            down: dist * cos(l.azimuth),
            carry: dist,
            maxHeight: maxHeight,
            timeOfFlight: t
        )
    }
}

/// Convenience: full shot summary the UI can display, from either tracking path.
struct ShotAnalysis {
    let launch: LaunchVector
    let landing: LandingPoint

    static func from2D(imagePoints: [CGPoint], calibration: SceneCalibration) -> ShotAnalysis? {
        guard let launch = BallPhysics.launchVector(imagePoints: imagePoints, calibration: calibration) else { return nil }
        return ShotAnalysis(launch: launch, landing: BallPhysics.land(launch))
    }

    static func from3D(worldPoints: [simd_float3], fps: Double) -> ShotAnalysis? {
        guard let launch = BallPhysics.launchVector(worldPoints: worldPoints, fps: fps) else { return nil }
        return ShotAnalysis(launch: launch, landing: BallPhysics.land(launch))
    }
}
