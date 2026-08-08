import XCTest
import CoreGraphics
import simd
@testable import CricketNets

/// Covers the 2D path from a colour detection to a launch vector: the calibration step that turns
/// an image position into metres, and the fit that turns a run of them into numbers the scoring
/// engine can use.
final class BallPhysicsTests: XCTestCase {

    private let fps = 120.0
    private let metersPerUnit = 3.0

    /// A portrait capture frame, which is what the fast path actually delivers.
    private let frameAspect = 1920.0 / 1080.0

    private var calibration: SceneCalibration {
        SceneCalibration(metersPerNormalizedUnit: metersPerUnit,
                         planeDistance: 3,
                         cameraHeight: 1,
                         fps: fps,
                         source: .reference)
    }

    /// Synthesise the image path of a ball launched at `speed` m/s and `elevationDeg`, as the
    /// colour tracker would see it: normalized units with a **top-left** origin, one sighting per
    /// frame, gravity curving the path — then run it through the same calibration the live path
    /// uses. Testing end-to-end from image coordinates is the point: the conversion and the fit
    /// have to agree about which axis is which, and a test that starts in metres can't see that.
    private func sightings(speed: Double, elevationDeg: Double, direction: Double = 1,
                           points n: Int = 6,
                           from start: CGPoint = CGPoint(x: 0.2, y: 0.6)) -> [BallPhysics.WorldSample] {
        let theta = elevationDeg * .pi / 180
        // Metres per normalized unit differs per axis: x spans the width, y spans the height.
        let vx = speed * cos(theta) / metersPerUnit * direction
        let vy = speed * sin(theta) / (metersPerUnit * frameAspect)
        let gNorm = BallPhysics.g / (metersPerUnit * frameAspect)
        return (0..<n).map { i in
            let t = Double(i) / fps
            // Image y grows downward, so a rising ball's y decreases.
            let p = CGPoint(x: start.x + vx * t,
                            y: start.y - (vy * t - 0.5 * gNorm * t * t))
            return calibration.planeSample(at: p, frameAspect: frameAspect, time: t)
        }
    }

    // MARK: Image position → metres

    func testTheVerticalAxisIsScaledByTheFrameAspect() {
        // The bug this guards. `metersPerNormalizedUnit` is metres per frame WIDTH, but normalized
        // y spans the frame's HEIGHT. Converting both at the same rate — as the old image-space fit
        // did — squashed every launch angle by the aspect ratio, ~1.78× on a portrait frame.
        let middle = calibration.planeSample(at: CGPoint(x: 0.5, y: 0.5), frameAspect: frameAspect, time: 0)
        let higher = calibration.planeSample(at: CGPoint(x: 0.5, y: 0.4), frameAspect: frameAspect, time: 0)
        let across = calibration.planeSample(at: CGPoint(x: 0.6, y: 0.5), frameAspect: frameAspect, time: 0)

        XCTAssertEqual(Double(higher.position.y - middle.position.y),
                       0.1 * metersPerUnit * frameAspect, accuracy: 1e-5)
        XCTAssertEqual(Double(across.position.x - middle.position.x),
                       0.1 * metersPerUnit, accuracy: 1e-5)
    }

    func testTheMiddleOfTheFrameSitsAtCameraHeight() {
        let middle = calibration.planeSample(at: CGPoint(x: 0.5, y: 0.5), frameAspect: frameAspect, time: 0)
        XCTAssertEqual(Double(middle.position.y), calibration.cameraHeight, accuracy: 1e-5)
        // Depth is unobservable from one side-on camera, so it must stay pinned rather than guessed.
        XCTAssertEqual(middle.position.z, 0)
    }

    func testALowerBallInFrameLaunchesFromLowerDown() {
        let high = calibration.planeSample(at: CGPoint(x: 0.5, y: 0.3), frameAspect: frameAspect, time: 0)
        let low = calibration.planeSample(at: CGPoint(x: 0.5, y: 0.7), frameAspect: frameAspect, time: 0)
        XCTAssertGreaterThan(high.position.y, low.position.y, "image y grows downward")
    }

    // MARK: Speed + elevation

    func testRecoversSpeedAndElevationFromASyntheticPath() throws {
        let launch = try XCTUnwrap(BallPhysics.launchVector(planeSamples: sightings(speed: 30, elevationDeg: 25)))
        XCTAssertEqual(launch.speed, 30, accuracy: 0.5)
        XCTAssertEqual(launch.elevationDeg, 25, accuracy: 1.0)
    }

    func testGravityCorrectionKeepsElevationFromSaggingOverTheWindow() {
        // A linear fit alone returns the MEAN vertical velocity, which under-reads launch angle.
        // A long window makes that error large, so this is where the correction has to hold up.
        let launch = BallPhysics.launchVector(planeSamples: sightings(speed: 25, elevationDeg: 35, points: 12))
        XCTAssertEqual(launch?.elevationDeg ?? 0, 35, accuracy: 1.0)
    }

    func testDroppedFramesDoNotSkewTheFit() throws {
        // The colour tracker loses the ball on some frames, so sightings are NOT one frame apart.
        // Timestamps are what keep that from reading as a slower shot; a fixed 1/fps step would.
        let full = sightings(speed: 30, elevationDeg: 25, points: 9)
        let gappy = [full[0], full[1], full[4], full[7], full[8]]   // three gaps mid-flight

        let clean = try XCTUnwrap(BallPhysics.launchVector(planeSamples: full))
        let sparse = try XCTUnwrap(BallPhysics.launchVector(planeSamples: gappy))
        XCTAssertEqual(sparse.speed, clean.speed, accuracy: 0.5)
        XCTAssertEqual(sparse.elevationDeg, clean.elevationDeg, accuracy: 1.0)
    }

    // MARK: Azimuth

    func testAzimuthIsReportedAsStraightRatherThanGuessed() {
        // A single side-on view cannot see left/right, so azimuth must be 0 — not the ±45° the
        // old atan2(vx, |vx|) always produced, which collapsed every shot onto two lines.
        for direction in [1.0, -1.0] {
            let launch = BallPhysics.launchVector(planeSamples: sightings(speed: 30, elevationDeg: 20,
                                                                         direction: direction))
            XCTAssertEqual(launch?.azimuth ?? .nan, 0, accuracy: 1e-9,
                           "direction \(direction) should not invent an azimuth")
        }
    }

    func testDirectionAcrossTheFrameDoesNotChangeSpeedOrElevation() {
        let right = BallPhysics.launchVector(planeSamples: sightings(speed: 28, elevationDeg: 18, direction: 1))
        let left = BallPhysics.launchVector(planeSamples: sightings(speed: 28, elevationDeg: 18, direction: -1))
        // Not bit-exact: samples are stored as Float, so mirroring the path changes the rounding.
        XCTAssertEqual(right?.speed ?? 0, left?.speed ?? -1, accuracy: 1e-4)
        XCTAssertEqual(right?.elevation ?? 0, left?.elevation ?? -1, accuracy: 1e-4)
    }

    // MARK: Noise resistance

    func testOneBadDetectionNoLongerDecidesTheShot() {
        // The old code read velocity straight off points[0]→[1], so corrupting the second point
        // corrupted the whole shot. A least-squares fit should mostly shrug it off.
        var noisy = sightings(speed: 30, elevationDeg: 25, points: 8)
        noisy[1].position += simd_float3(0.36, 0.5, 0)   // a large, plausible glitch

        let clean = BallPhysics.launchVector(planeSamples: sightings(speed: 30, elevationDeg: 25, points: 8))
        let dirty = BallPhysics.launchVector(planeSamples: noisy)

        let cleanSpeed = clean?.speed ?? 0
        let dirtySpeed = dirty?.speed ?? 0
        XCTAssertEqual(dirtySpeed, cleanSpeed, accuracy: cleanSpeed * 0.25,
                       "one outlier should move the speed by well under a quarter")
    }

    // MARK: Guards

    func testTooFewSightingsYieldsNoLaunch() {
        XCTAssertNil(BallPhysics.launchVector(planeSamples: Array(sightings(speed: 30, elevationDeg: 25).prefix(1))))
        XCTAssertNil(BallPhysics.launchVector(planeSamples: []))
    }

    func testSightingsSharingOneInstantYieldNoLaunch() {
        // Two sightings at the same timestamp have no velocity to report; without the guard the fit
        // would divide by a zero time span.
        let p = CGPoint(x: 0.5, y: 0.5)
        let same = (0..<4).map { _ in calibration.planeSample(at: p, frameAspect: frameAspect, time: 7) }
        XCTAssertNil(BallPhysics.launchVector(planeSamples: same))
    }

    func testStationaryPointsYieldNoLaunch() {
        // A blob that never moves has no launch to report; without a guard the elevation would be
        // whatever atan2(0, 0) happens to give.
        let still = (0..<6).map {
            calibration.planeSample(at: CGPoint(x: 0.5, y: 0.5), frameAspect: frameAspect,
                                    time: Double($0) / fps)
        }
        let launch = BallPhysics.launchVector(planeSamples: still)
        // Gravity correction alone leaves a tiny upward velocity, so accept a near-zero speed.
        XCTAssertLessThan(launch?.speed ?? 0, 0.5)
    }

    // MARK: Constants

    func testCricketBallDiameterIsRealistic() {
        // Regulation circumference is 22.4–22.9 cm, so ~7.2 cm across.
        XCTAssertEqual(CricketConstants.ballDiameter, 0.072, accuracy: 0.002)
    }
}
