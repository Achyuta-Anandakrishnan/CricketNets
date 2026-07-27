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

    // MARK: 2D path (fast 240fps tracker + calibration; azimuth is approximate)

    /// Lift a 2D image trajectory (Vision normalized points, bottom-left origin) into a launch
    /// vector using the scene calibration. Speed and elevation are solid; azimuth is only a rough
    /// left/right read from horizontal image drift, because a single 2D view can't fully separate
    /// "hit square" from "hit straight." For trustworthy azimuth, use the LiDAR 3D path.
    static func launchVector(imagePoints: [CGPoint], calibration c: SceneCalibration) -> LaunchVector? {
        guard imagePoints.count >= 2 else { return nil }
        let dt = 1.0 / c.fps
        let p0 = imagePoints[0], p1 = imagePoints[1]
        let dxNorm = Double(p1.x - p0.x)
        let dyNorm = Double(p1.y - p0.y)   // +y is up in Vision space
        // Normalized units → meters at the flight plane.
        let dxM = dxNorm * c.metersPerNormalizedUnit
        let dyM = dyNorm * c.metersPerNormalizedUnit
        let vx = dxM / dt          // lateral velocity (image left/right)
        let vy = dyM / dt          // vertical velocity
        // Without depth we can't measure toward/away speed, so approximate forward speed as the
        // horizontal component we CAN see. This under-reads straight drives — a known 2D limitation.
        let vForward = abs(vx) < 1e-6 ? 0.0001 : abs(vx)
        let speed = (vx * vx + vy * vy).squareRoot()
        let elevation = atan2(vy, abs(vx))
        let azimuth = atan2(vx, vForward)   // crude; sign shows which side of the wicket
        return LaunchVector(speed: speed, elevation: elevation, azimuth: azimuth, height: c.cameraHeight)
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
