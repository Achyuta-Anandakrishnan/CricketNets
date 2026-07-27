import XCTest
import CoreGraphics
@testable import CricketNets

/// Covers the 2D image-trajectory → launch-vector step, which is where a tracked shot becomes
/// numbers the scoring engine can use.
final class BallPhysicsTests: XCTestCase {

    private let fps = 120.0
    private let metersPerUnit = 3.0

    private var calibration: SceneCalibration {
        SceneCalibration(metersPerNormalizedUnit: metersPerUnit,
                         planeDistance: 3,
                         cameraHeight: 1,
                         fps: fps,
                         source: .reference)
    }

    /// Synthesise the image path of a ball launched at `speed` m/s and `elevationDeg`, as the
    /// tracker would see it: normalized units, origin bottom-left, one point per frame, with
    /// gravity curving the path. `direction` flips which way across the frame it travels.
    private func trajectory(speed: Double, elevationDeg: Double, direction: Double = 1,
                            points n: Int = 6, from start: CGPoint = CGPoint(x: 0.2, y: 0.4)) -> [CGPoint] {
        let theta = elevationDeg * .pi / 180
        let vx = speed * cos(theta) / metersPerUnit * direction
        let vy = speed * sin(theta) / metersPerUnit
        let gNorm = BallPhysics.g / metersPerUnit
        return (0..<n).map { i in
            let t = Double(i) / fps
            return CGPoint(x: start.x + vx * t,
                           y: start.y + vy * t - 0.5 * gNorm * t * t)
        }
    }

    // MARK: Speed + elevation

    func testRecoversSpeedAndElevationFromASyntheticPath() throws {
        let launch = try XCTUnwrap(
            BallPhysics.launchVector(imagePoints: trajectory(speed: 30, elevationDeg: 25),
                                     calibration: calibration)
        )
        XCTAssertEqual(launch.speed, 30, accuracy: 0.5)
        XCTAssertEqual(launch.elevationDeg, 25, accuracy: 1.0)
    }

    func testGravityCorrectionKeepsElevationFromSaggingOverTheWindow() {
        // A linear fit alone returns the MEAN vertical velocity, which under-reads launch angle.
        // A long window makes that error large, so this is where the correction has to hold up.
        let launch = BallPhysics.launchVector(imagePoints: trajectory(speed: 25, elevationDeg: 35, points: 12),
                                              calibration: calibration)
        XCTAssertEqual(launch?.elevationDeg ?? 0, 35, accuracy: 1.0)
    }

    // MARK: Azimuth

    func testAzimuthIsReportedAsStraightRatherThanGuessed() {
        // A single side-on view cannot see left/right, so azimuth must be 0 — not the ±45° the
        // old atan2(vx, |vx|) always produced, which collapsed every shot onto two lines.
        for direction in [1.0, -1.0] {
            let launch = BallPhysics.launchVector(imagePoints: trajectory(speed: 30, elevationDeg: 20,
                                                                         direction: direction),
                                                  calibration: calibration)
            XCTAssertEqual(launch?.azimuth ?? .nan, 0, accuracy: 1e-9,
                           "direction \(direction) should not invent an azimuth")
        }
    }

    func testDirectionAcrossTheFrameDoesNotChangeSpeedOrElevation() {
        let right = BallPhysics.launchVector(imagePoints: trajectory(speed: 28, elevationDeg: 18, direction: 1),
                                             calibration: calibration)
        let left = BallPhysics.launchVector(imagePoints: trajectory(speed: 28, elevationDeg: 18, direction: -1),
                                            calibration: calibration)
        XCTAssertEqual(right?.speed ?? 0, left?.speed ?? -1, accuracy: 1e-9)
        XCTAssertEqual(right?.elevation ?? 0, left?.elevation ?? -1, accuracy: 1e-9)
    }

    // MARK: Noise resistance

    func testOneBadDetectionNoLongerDecidesTheShot() {
        // The old code read velocity straight off points[0]→[1], so corrupting the second point
        // corrupted the whole shot. A least-squares fit should mostly shrug it off.
        var noisy = trajectory(speed: 30, elevationDeg: 25, points: 8)
        noisy[1] = CGPoint(x: noisy[1].x + 0.12, y: noisy[1].y - 0.10)   // a large, plausible glitch

        let clean = BallPhysics.launchVector(imagePoints: trajectory(speed: 30, elevationDeg: 25, points: 8),
                                             calibration: calibration)
        let dirty = BallPhysics.launchVector(imagePoints: noisy, calibration: calibration)

        let cleanSpeed = clean?.speed ?? 0
        let dirtySpeed = dirty?.speed ?? 0
        XCTAssertEqual(dirtySpeed, cleanSpeed, accuracy: cleanSpeed * 0.25,
                       "one outlier should move the speed by well under a quarter")
    }

    // MARK: Guards

    func testTooFewPointsYieldsNoLaunch() {
        XCTAssertNil(BallPhysics.launchVector(imagePoints: [CGPoint(x: 0.5, y: 0.5)], calibration: calibration))
        XCTAssertNil(BallPhysics.launchVector(imagePoints: [], calibration: calibration))
    }

    func testStationaryPointsYieldNoLaunch() {
        // A blob that never moves has no launch to report; without a guard the elevation would be
        // whatever atan2(0, 0) happens to give.
        let still = Array(repeating: CGPoint(x: 0.5, y: 0.5), count: 6)
        let launch = BallPhysics.launchVector(imagePoints: still, calibration: calibration)
        // Gravity correction alone leaves a tiny upward velocity, so accept a near-zero speed.
        XCTAssertLessThan(launch?.speed ?? 0, 0.5)
    }

    // MARK: Constants

    func testCricketBallDiameterIsRealistic() {
        // Regulation circumference is 22.4–22.9 cm, so ~7.2 cm across.
        XCTAssertEqual(CricketConstants.ballDiameter, 0.072, accuracy: 0.002)
    }
}
