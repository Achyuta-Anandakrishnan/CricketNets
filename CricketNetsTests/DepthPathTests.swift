import XCTest
import simd
@testable import CricketNets

/// The LiDAR 3D path is device-only end to end, but the maths that turns depth-resolved world
/// points into a launch vector is pure — and it's the part that makes azimuth a real measurement,
/// so it's worth pinning down properly.
final class DepthPathTests: XCTestCase {

    private let g = BallPhysics.g

    /// Build the world path of a ball launched at `speed`/`elevationDeg`/`azimuthDeg`, measured
    /// against `ground`. `times` lets a test simulate dropped frames by spacing samples unevenly.
    private func samples(speed: Double,
                         elevationDeg: Double,
                         azimuthDeg: Double,
                         ground: simd_float2 = simd_float2(0, -1),
                         times: [Double] = (0..<8).map { Double($0) / 60 },
                         origin: simd_float3 = simd_float3(0, 1, 0)) -> [BallPhysics.WorldSample] {
        let elevation = elevationDeg * .pi / 180
        let azimuth = azimuthDeg * .pi / 180

        let forward = simd_normalize(ground)
        let right = simd_float2(-forward.y, forward.x)

        let horizontal = speed * cos(elevation)
        let vy = speed * sin(elevation)
        let horizVelocity = forward * Float(horizontal * cos(azimuth))
                          + right * Float(horizontal * sin(azimuth))

        return times.map { t in
            let position = simd_float3(
                origin.x + horizVelocity.x * Float(t),
                origin.y + Float(vy * t - 0.5 * g * t * t),
                origin.z + horizVelocity.y * Float(t)
            )
            return BallPhysics.WorldSample(position: position, time: 1000 + t)
        }
    }

    private func launch(_ s: [BallPhysics.WorldSample],
                        ground: simd_float2 = simd_float2(0, -1)) -> LaunchVector? {
        BallPhysics.launchVector(worldSamples: s, groundDirection: ground)
    }

    // MARK: The whole point of this path

    func testAzimuthIsActuallyMeasured() {
        // The 2D path reports 0 for everything. Here each direction must come back distinctly.
        for expected in [-60.0, -25.0, 0.0, 25.0, 60.0] {
            let l = launch(samples(speed: 28, elevationDeg: 20, azimuthDeg: expected))
            XCTAssertEqual(l?.azimuthDeg ?? .nan, expected, accuracy: 0.5,
                           "azimuth \(expected)° should survive the round trip")
        }
    }

    func testAzimuthIsRelativeToTheAimedGroundDirection() {
        // Rotating BOTH the aim and the shot by the same amount must leave azimuth unchanged —
        // that's what makes "down the ground" a user-set reference rather than a world axis.
        let rotatedGround = simd_normalize(simd_float2(0.7, 0.7))
        let l = launch(samples(speed: 28, elevationDeg: 20, azimuthDeg: 30, ground: rotatedGround),
                       ground: rotatedGround)
        XCTAssertEqual(l?.azimuthDeg ?? .nan, 30, accuracy: 0.5)
    }

    func testMisalignedGroundDirectionShiftsAzimuthByThatMuch() {
        // Aim 20° off from where the shot was generated and the reported azimuth should shift 20°.
        let shotGround = simd_float2(0, -1)
        let aimedGround = simd_float2(Float(sin(20 * Double.pi / 180)), Float(-cos(20 * Double.pi / 180)))
        let l = launch(samples(speed: 28, elevationDeg: 20, azimuthDeg: 0, ground: shotGround),
                       ground: aimedGround)
        XCTAssertEqual(l?.azimuthDeg ?? .nan, -20, accuracy: 0.5)
    }

    // MARK: Speed + elevation

    func testRecoversSpeedAndElevation() {
        let l = launch(samples(speed: 32, elevationDeg: 28, azimuthDeg: 15))
        XCTAssertEqual(l?.speed ?? 0, 32, accuracy: 0.3)
        XCTAssertEqual(l?.elevationDeg ?? 0, 28, accuracy: 0.5)
        XCTAssertEqual(l?.height ?? 0, 1, accuracy: 0.01)
    }

    func testGravityCorrectionHoldsOverALongWindow() {
        // Across half a second the mean vertical velocity is ~2.5 m/s below the launch value, which
        // is several degrees of launch angle. Without the correction this test fails.
        let long = (0..<31).map { Double($0) / 60 }   // 0.5 s
        let l = launch(samples(speed: 30, elevationDeg: 30, azimuthDeg: 0, times: long))
        XCTAssertEqual(l?.elevationDeg ?? 0, 30, accuracy: 0.5)
    }

    // MARK: Dropped frames

    func testUnevenSampleSpacingStillFits() {
        // The tracker skips any frame where the ball wasn't detected or LiDAR had no confident
        // reading, so gaps are the normal case, not the exception.
        let gappy = [0.0, 1, 2, 5, 6, 9, 13, 14].map { $0 / 60 }
        let l = launch(samples(speed: 30, elevationDeg: 25, azimuthDeg: -35, times: gappy))
        XCTAssertEqual(l?.speed ?? 0, 30, accuracy: 0.5)
        XCTAssertEqual(l?.elevationDeg ?? 0, 25, accuracy: 1.0)
        XCTAssertEqual(l?.azimuthDeg ?? .nan, -35, accuracy: 1.0)
    }

    func testEvenAndUnevenSamplingAgree() {
        let even = launch(samples(speed: 30, elevationDeg: 25, azimuthDeg: 20,
                                  times: (0..<10).map { Double($0) / 60 }))
        let uneven = launch(samples(speed: 30, elevationDeg: 25, azimuthDeg: 20,
                                    times: [0.0, 2, 3, 7, 8, 9].map { $0 / 60 }))
        XCTAssertEqual(even?.speed ?? 0, uneven?.speed ?? -1, accuracy: 0.2)
        XCTAssertEqual(even?.azimuthDeg ?? 0, uneven?.azimuthDeg ?? -1, accuracy: 0.2)
    }

    // MARK: Guards

    func testTooFewSamplesYieldsNoLaunch() {
        let two = samples(speed: 30, elevationDeg: 20, azimuthDeg: 0, times: [0, 1.0 / 60])
        XCTAssertNil(launch(two))
        XCTAssertNil(launch([]))
    }

    func testZeroDurationYieldsNoLaunch() {
        // Several samples all stamped at the same instant can't produce a velocity.
        let simultaneous = samples(speed: 30, elevationDeg: 20, azimuthDeg: 0, times: [0, 0, 0])
        XCTAssertNil(launch(simultaneous))
    }

    // MARK: Ground direction from the camera

    func testHorizontalForwardOfAnIdentityTransformIsMinusZ() {
        let forward = DepthTrajectoryTracker.horizontalForward(of: matrix_identity_float4x4)
        XCTAssertEqual(forward.x, 0, accuracy: 1e-6)
        XCTAssertEqual(forward.y, -1, accuracy: 1e-6)
    }

    func testHorizontalForwardFollowsAYawRotation() {
        // Yaw 90° about the world up axis; the camera's forward swings to −X.
        let yaw = simd_float4x4(simd_quatf(angle: .pi / 2, axis: simd_float3(0, 1, 0)))
        let forward = DepthTrajectoryTracker.horizontalForward(of: yaw)
        XCTAssertEqual(forward.x, -1, accuracy: 1e-5)
        XCTAssertEqual(forward.y, 0, accuracy: 1e-5)
    }

    func testHorizontalForwardIsAlwaysAUnitVector() {
        // A phone pointed steeply down leaves almost no horizontal component; it still has to
        // normalize rather than return a near-zero vector that would wreck the azimuth projection.
        let pitchedDown = simd_float4x4(simd_quatf(angle: -1.4, axis: simd_float3(1, 0, 0)))
        let forward = DepthTrajectoryTracker.horizontalForward(of: pitchedDown)
        XCTAssertEqual(simd_length(forward), 1, accuracy: 1e-5)
    }
}
