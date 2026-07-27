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

    // MARK: 3D path (LiDAR-informed — the only path that can actually measure azimuth)

    /// One tracked 3D position and the moment it was seen.
    ///
    /// Samples are deliberately *timestamped* rather than assumed evenly spaced: the depth tracker
    /// drops any frame where the ball wasn't detected or where LiDAR had no confident reading, so
    /// gaps in the sequence are normal and a fixed `1/fps` step would quietly skew the fit.
    struct WorldSample: Equatable {
        var position: simd_float3   // ARKit world meters, y up
        var time: TimeInterval      // ARFrame timestamp (seconds)

        init(position: simd_float3, time: TimeInterval) {
            self.position = position
            self.time = time
        }
    }

    /// Estimate the launch vector from timed 3D world points.
    ///
    /// Unlike the 2D path this measures all three components for real — depth is observed, so a
    /// square cut and a straight drive are finally distinguishable.
    ///
    /// - Parameter groundDirection: the horizontal direction (ARKit world x/z) that counts as
    ///   "straight down the ground". Azimuth is measured from it, positive toward the camera's
    ///   right. Capture this when the user aims the phone rather than assuming a world axis.
    static func launchVector(worldSamples samples: [WorldSample],
                             groundDirection: simd_float2) -> LaunchVector? {
        guard samples.count >= 3 else { return nil }
        let t0 = samples[0].time
        let times = samples.map { $0.time - t0 }
        guard let last = times.last, last > 0 else { return nil }

        guard
            let fitX = linearFit(times: times, values: samples.map { Double($0.position.x) }),
            let fitY = linearFit(times: times, values: samples.map { Double($0.position.y) }),
            let fitZ = linearFit(times: times, values: samples.map { Double($0.position.z) })
        else { return nil }

        let vx = fitX.slope
        let vz = fitZ.slope
        // Only the vertical axis is accelerating, so only it needs gravity added back.
        let vy = fitY.slope + g * fitY.accelWeight / 2

        let horizontal = (vx * vx + vz * vz).squareRoot()
        let speed = (vx * vx + vy * vy + vz * vz).squareRoot()
        guard speed > 0 else { return nil }

        // Project the horizontal velocity onto the aimed "down the ground" axis and the axis square
        // to it. For a horizontal forward (x, z), the camera's right is (−z, x).
        let forward = simd_normalize(groundDirection)
        let right = simd_float2(-forward.y, forward.x)
        let horizVelocity = simd_float2(Float(vx), Float(vz))
        let along = Double(simd_dot(horizVelocity, forward))
        let across = Double(simd_dot(horizVelocity, right))

        return LaunchVector(speed: speed,
                            elevation: atan2(vy, horizontal),
                            azimuth: atan2(across, along),
                            height: Double(samples[0].position.y))
    }

    /// Least-squares linear fit of `values` against `times`.
    ///
    /// For a coordinate following p(t) = p₀ + v₀·t − ½a·t², the least-squares slope across the
    /// samples is not v₀ but `v₀ − a·C/2`, where `C = Σ(tᵢ − t̄)tᵢ² / Σ(tᵢ − t̄)²`. Returning `C` as
    /// `accelWeight` lets an accelerating axis recover its initial rate with `slope + a·accelWeight/2`;
    /// a drag-free horizontal axis just ignores it.
    ///
    /// Times must be measured from the first sample, so `accelWeight` is relative to that point.
    private static func linearFit(times: [Double], values: [Double]) -> (slope: Double, accelWeight: Double)? {
        let n = Double(times.count)
        guard n >= 2, times.count == values.count else { return nil }
        let meanT = times.reduce(0, +) / n
        let meanV = values.reduce(0, +) / n

        var stt = 0.0, stv = 0.0, stt2 = 0.0
        for (t, v) in zip(times, values) {
            let dt = t - meanT
            stt += dt * dt
            stv += dt * (v - meanV)
            stt2 += dt * t * t
        }
        guard stt > 0 else { return nil }
        return (stv / stt, stt2 / stt)
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

    static func from3D(worldSamples: [BallPhysics.WorldSample],
                       groundDirection: simd_float2) -> ShotAnalysis? {
        guard let launch = BallPhysics.launchVector(worldSamples: worldSamples,
                                                    groundDirection: groundDirection) else { return nil }
        return ShotAnalysis(launch: launch, landing: BallPhysics.land(launch))
    }
}
