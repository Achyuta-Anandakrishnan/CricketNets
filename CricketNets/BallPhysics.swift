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

    /// Measure gravity from a tracked ball, as an end-to-end accuracy check.
    ///
    /// This is the only ground truth available without instrumenting the net: a falling ball
    /// accelerates downward at 9.81 m/s², always, and every stage of the pipeline has to be right
    /// for that number to come out. Detection has to find the real ball, depth has to be the ball's
    /// distance and not the background, the unprojection has to be correctly scaled, and the frame
    /// timestamps have to be real. Get any of those wrong and this reads something other than 9.81 —
    /// and *how* wrong is diagnostic:
    ///
    /// - roughly half or double → a scale error, usually depth
    /// - near zero → the ball isn't really being tracked, or depth is pinned to a static background
    /// - wildly noisy between drops → detection is jumping between objects
    ///
    /// Returns the downward acceleration in m/s² (positive = falling), or nil if the samples can't
    /// support a fit.
    static func measuredGravity(worldSamples samples: [WorldSample]) -> Double? {
        guard samples.count >= 4 else { return nil }
        let t0 = samples[0].time
        let times = samples.map { $0.time - t0 }
        guard let last = times.last, last > 0 else { return nil }
        guard let fit = quadraticFit(times: times, values: samples.map { Double($0.position.y) })
        else { return nil }
        return -fit.acceleration   // world y is up, so falling is negative acceleration
    }

    /// Least-squares fit of `y = a + b·t + ½c·t²`, returning the initial rate `b` and acceleration `c`.
    ///
    /// The linear fit elsewhere assumes gravity's value; this one measures it, which is the whole
    /// point when the question is whether the pipeline is trustworthy.
    static func quadraticFit(times: [Double], values: [Double]) -> (rate: Double, acceleration: Double)? {
        let n = Double(times.count)
        guard times.count >= 3, times.count == values.count else { return nil }

        var s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0
        var sy = 0.0, sty = 0.0, st2y = 0.0
        for (t, y) in zip(times, values) {
            let t2 = t * t
            s1 += t; s2 += t2; s3 += t2 * t; s4 += t2 * t2
            sy += y; sty += t * y; st2y += t2 * y
        }

        // Normal equations for [a, b, c'] where the model is a + b·t + c'·t², so acceleration = 2c'.
        let m = [[n, s1, s2],
                 [s1, s2, s3],
                 [s2, s3, s4]]
        let rhs = [sy, sty, st2y]

        guard let solution = solve3x3(m, rhs) else { return nil }
        return (rate: solution[1], acceleration: 2 * solution[2])
    }

    /// Cramer's rule. Fine at this size, and avoids pulling in a linear-algebra dependency.
    private static func solve3x3(_ m: [[Double]], _ rhs: [Double]) -> [Double]? {
        func det(_ a: [[Double]]) -> Double {
            a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1])
          - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
          + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        }
        let d = det(m)
        // Samples spread over too little time make the system near-singular; refuse rather than
        // return an enormous meaningless acceleration.
        guard abs(d) > 1e-12 else { return nil }

        return (0..<3).map { col in
            var c = m
            for row in 0..<3 { c[row][col] = rhs[row] }
            return det(c) / d
        }
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

    /// Estimate the launch from sightings confined to the **image plane**: metric x running along
    /// the ground, y measured up from it, and z unused. `SceneCalibration.planeSample` builds them.
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
    /// Samples carry their own timestamps rather than being assumed one frame apart, which matters
    /// because the colour tracker drops any frame it can't find the ball in — the same reason the 3D
    /// path is timestamped. A dropped frame now costs one sample instead of skewing the whole fit.
    static func launchVector(planeSamples samples: [WorldSample]) -> LaunchVector? {
        guard samples.count >= 2 else { return nil }
        let t0 = samples[0].time
        let times = samples.map { $0.time - t0 }
        guard let last = times.last, last > 0 else { return nil }

        guard
            let fitX = linearFit(times: times, values: samples.map { Double($0.position.x) }),
            let fitY = linearFit(times: times, values: samples.map { Double($0.position.y) })
        else { return nil }

        let vx = fitX.slope
        // A linear fit of y(t) returns the mean vertical velocity, but gravity has been pulling the
        // ball down across the window. `accelWeight` recovers the velocity at the first sighting.
        let vy = fitY.slope + g * fitY.accelWeight / 2

        let speed = (vx * vx + vy * vy).squareRoot()
        guard speed > 0 else { return nil }
        return LaunchVector(speed: speed,
                            elevation: atan2(vy, abs(vx)),
                            azimuth: 0,
                            height: max(0, Double(samples[0].position.y)))
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

    static func from2D(planeSamples: [BallPhysics.WorldSample]) -> ShotAnalysis? {
        guard let launch = BallPhysics.launchVector(planeSamples: planeSamples) else { return nil }
        return ShotAnalysis(launch: launch, landing: BallPhysics.land(launch))
    }

    static func from3D(worldSamples: [BallPhysics.WorldSample],
                       groundDirection: simd_float2) -> ShotAnalysis? {
        guard let launch = BallPhysics.launchVector(worldSamples: worldSamples,
                                                    groundDirection: groundDirection) else { return nil }
        return ShotAnalysis(launch: launch, landing: BallPhysics.land(launch))
    }
}
