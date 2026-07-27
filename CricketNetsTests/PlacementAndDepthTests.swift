import XCTest
import simd
@testable import CricketNets

/// Covers the two bits of the 3D setup that are pure maths: sizing the depth patch to the ball,
/// and rotating the camera's aim into a "down the ground" reference so the phone can stand
/// wherever it tracks best.
final class PlacementAndDepthTests: XCTestCase {

    // MARK: Ball sizing

    /// A representative ARKit setup: ~1500 px focal on a 1920-wide capture, 256-wide depth map.
    private let depthFocal: Float = 1500 * 256 / 1920   // = 200

    func testBallShrinksWithDistance() {
        let near = DepthTrajectoryTracker.ballRadiusPixels(distance: 2, focalLengthPx: depthFocal)
        let mid = DepthTrajectoryTracker.ballRadiusPixels(distance: 3.5, focalLengthPx: depthFocal)
        let far = DepthTrajectoryTracker.ballRadiusPixels(distance: 5, focalLengthPx: depthFocal)
        XCTAssertGreaterThan(near, mid)
        XCTAssertGreaterThan(mid, far)
    }

    func testBallRadiusMatchesThePinholeProjection() {
        // radius_px = (0.072/2) · 200 / 2 m = 3.6 → 4
        XCTAssertEqual(DepthTrajectoryTracker.ballRadiusPixels(distance: 2, focalLengthPx: depthFocal), 4)
        // at 4 m: 0.036 · 200 / 4 = 1.8 → 2
        XCTAssertEqual(DepthTrajectoryTracker.ballRadiusPixels(distance: 4, focalLengthPx: depthFocal), 2)
    }

    func testBallRadiusIsNeverZero() {
        // Way beyond LiDAR range the projection rounds to nothing; a zero-radius patch would
        // sample no pixels at all and the reading would silently vanish.
        XCTAssertGreaterThanOrEqual(
            DepthTrajectoryTracker.ballRadiusPixels(distance: 500, focalLengthPx: depthFocal), 1)
        XCTAssertGreaterThanOrEqual(
            DepthTrajectoryTracker.ballRadiusPixels(distance: 0, focalLengthPx: depthFocal), 1)
        XCTAssertGreaterThanOrEqual(
            DepthTrajectoryTracker.ballRadiusPixels(distance: 3, focalLengthPx: 0), 1)
    }

    func testBallRadiusUsesTheCorrectedBallDiameter() {
        // Guards the 10x fix: at 0.0072 m the ball would round to a 1 px radius at every distance,
        // so the patch would never grow and close-range tracking would sample almost nothing.
        XCTAssertGreaterThan(
            DepthTrajectoryTracker.ballRadiusPixels(distance: 1.5, focalLengthPx: depthFocal), 2)
    }

    // MARK: Placement rotation

    func testZeroOffsetLeavesTheAimAlone() {
        let forward = simd_float2(0, -1)
        let rotated = PhonePlacement.rotate(forward, byDegrees: 0)
        XCTAssertEqual(rotated.x, 0, accuracy: 1e-5)
        XCTAssertEqual(rotated.y, -1, accuracy: 1e-5)
    }

    func testNinetyDegreesGivesTheCameraSRight() {
        // right = (−z, x), matching the sense azimuth uses, so a +90° offset and a +90° azimuth
        // point the same way.
        let rotated = PhonePlacement.rotate(simd_float2(0, -1), byDegrees: 90)
        XCTAssertEqual(rotated.x, 1, accuracy: 1e-5)
        XCTAssertEqual(rotated.y, 0, accuracy: 1e-5)
    }

    func testOppositeOffsetsAreOpposite() {
        let left = PhonePlacement.rotate(simd_float2(0, -1), byDegrees: -90)
        let right = PhonePlacement.rotate(simd_float2(0, -1), byDegrees: 90)
        XCTAssertEqual(left.x, -right.x, accuracy: 1e-5)
        XCTAssertEqual(left.y, -right.y, accuracy: 1e-5)
    }

    func testRotationPreservesUnitLength() {
        for degrees in stride(from: -180.0, through: 180.0, by: 30) {
            let rotated = PhonePlacement.rotate(simd_float2(0.3, -0.8), byDegrees: degrees)
            XCTAssertEqual(simd_length(rotated), 1, accuracy: 1e-5, "at \(degrees)°")
        }
    }

    func testDegenerateAimFallsBackRatherThanProducingNaN() {
        // A phone pointed straight down leaves no horizontal component to normalize.
        let rotated = PhonePlacement.rotate(simd_float2(0, 0), byDegrees: 45)
        XCTAssertEqual(simd_length(rotated), 1, accuracy: 1e-5)
        XCTAssertFalse(rotated.x.isNaN || rotated.y.isNaN)
    }

    // MARK: Placement ↔ azimuth, end to end

    func testOffsetCancelsAMisplacedPhone() {
        // The scenario the offset exists for: the phone sits square of the wicket, so its forward
        // is 90° away from down the ground. A straight shot must still read as straight once the
        // offset accounts for where the phone is standing.
        let downTheGround = simd_float2(0, -1)
        let cameraForward = PhonePlacement.rotate(downTheGround, byDegrees: -90)

        // Shot travels down the ground; the reference is rebuilt from the camera's aim + offset.
        let reference = PhonePlacement.rotate(cameraForward, byDegrees: 90)
        let samples = (0..<8).map { i -> BallPhysics.WorldSample in
            let t = Double(i) / 60
            return BallPhysics.WorldSample(
                position: simd_float3(0, Float(1 + 10 * t - 0.5 * BallPhysics.g * t * t), Float(-25 * t)),
                time: t
            )
        }
        let launch = BallPhysics.launchVector(worldSamples: samples, groundDirection: reference)
        XCTAssertEqual(launch?.azimuthDeg ?? .nan, 0, accuracy: 0.5)
    }

    func testPresetsCoverBothSidesOfTheWicket() {
        XCTAssertEqual(PhonePlacement.downTheGround.defaultOffsetDegrees, 0)
        XCTAssertEqual(PhonePlacement.offSide.defaultOffsetDegrees,
                       -PhonePlacement.legSide.defaultOffsetDegrees)
    }
}
