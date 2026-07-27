import XCTest
import simd
@testable import CricketNets

/// With per-frame detection the ball is visible constantly, including at rest, so "is this a shot?"
/// became an explicit decision instead of something the trajectory detector answered implicitly.
/// This is that decision, and it's driven by timestamps rather than timers so it can be tested flat.
final class ShotAssemblerTests: XCTestCase {

    /// A sighting `metres` along +x from the origin at `t` seconds.
    private func sighting(_ metres: Double, at t: TimeInterval) -> BallPhysics.WorldSample {
        BallPhysics.WorldSample(position: simd_float3(Float(metres), 1, 0), time: t)
    }

    /// Sightings at a steady speed, one per frame.
    private func run(_ assembler: inout ShotAssembler, speed: Double, frames: Int,
                     fps: Double = 60, from start: TimeInterval = 0) -> [ShotAssembler.Event] {
        (0..<frames).map { i in
            let t = start + Double(i) / fps
            return assembler.add(sighting(speed * (t - start), at: t))
        }
    }

    // MARK: Telling a shot from a carried ball

    func testAStationaryBallIsNotAShot() {
        var a = ShotAssembler()
        for i in 0..<10 {
            let event = a.add(sighting(0, at: Double(i) / 60))
            XCTAssertEqual(event, .idle)
        }
        XCTAssertFalse(a.isTracking)
    }

    func testWalkingWithTheBallIsNotAShot() {
        // Carrying a ball back to the crease is about 1.4 m/s, well under the gate.
        var a = ShotAssembler()
        let events = run(&a, speed: 1.4, frames: 20)
        XCTAssertTrue(events.allSatisfy { $0 == .idle })
        XCTAssertFalse(a.isTracking)
    }

    func testAStruckBallStartsAShot() {
        var a = ShotAssembler()
        let events = run(&a, speed: 25, frames: 6)
        XCTAssertEqual(events.last, .tracking)
        XCTAssertTrue(a.isTracking)
        XCTAssertGreaterThanOrEqual(a.samples.count, 5)
    }

    func testTheGateIsAdjustable() {
        var strict = ShotAssembler()
        strict.minShotSpeed = 15
        _ = run(&strict, speed: 8, frames: 6)
        XCTAssertFalse(strict.isTracking, "8 m/s is under a 15 m/s gate")

        var loose = ShotAssembler()
        loose.minShotSpeed = 3
        _ = run(&loose, speed: 8, frames: 6)
        XCTAssertTrue(loose.isTracking)
    }

    // MARK: The launch point

    func testTheShotIncludesTheSightingBeforeItGotFast() {
        // The first fast frame is already mid-flight, so seeding with its predecessor is what keeps
        // the actual launch in the fit rather than a point some way into the shot.
        var a = ShotAssembler()
        _ = a.add(sighting(0, at: 0))          // at rest
        _ = a.add(sighting(0.5, at: 1.0 / 60)) // 30 m/s
        XCTAssertEqual(a.samples.count, 2, "the pre-launch sighting should be kept")
        XCTAssertEqual(a.samples.first?.time, 0)
    }

    // MARK: Ending

    func testShotCompletesAfterItGoesQuiet() {
        var a = ShotAssembler()
        _ = run(&a, speed: 25, frames: 6)
        let end = 6.0 / 60

        XCTAssertEqual(a.checkSettled(now: end + 0.1), .tracking, "too soon to call it over")

        guard case .completed(let finished) = a.checkSettled(now: end + 0.4) else {
            return XCTFail("expected the shot to complete")
        }
        XCTAssertNotNil(finished)
        XCTAssertGreaterThanOrEqual(finished?.count ?? 0, 3)
        XCTAssertFalse(a.isTracking, "assembler should be ready for the next ball")
    }

    func testAShotTooShortToFitCompletesWithNothing() {
        var a = ShotAssembler()
        a.minSamples = 5
        _ = run(&a, speed: 25, frames: 2)   // seeds 1 + adds 2 at most

        guard case .completed(let finished) = a.checkSettled(now: 10) else {
            return XCTFail("expected completion")
        }
        XCTAssertNil(finished, "too few sightings to fit a launch vector")
    }

    func testBackToBackShotsDontRunTogether() {
        var a = ShotAssembler()
        _ = run(&a, speed: 25, frames: 6)
        guard case .completed(let first) = a.checkSettled(now: 5) else {
            return XCTFail("first shot should complete")
        }
        XCTAssertNotNil(first)

        _ = run(&a, speed: 25, frames: 6, from: 10)
        XCTAssertTrue(a.isTracking)
        XCTAssertLessThanOrEqual(a.samples.count, 7, "second shot must not inherit the first's samples")
        XCTAssertEqual(a.samples.first.map { $0.time >= 10 }, true)
    }

    func testResetAbandonsTheShotInProgress() {
        var a = ShotAssembler()
        _ = run(&a, speed: 25, frames: 6)
        a.reset()
        XCTAssertFalse(a.isTracking)
        XCTAssertTrue(a.samples.isEmpty)
    }

    // MARK: Speed

    func testSpeedBetweenSightings() {
        let a = sighting(0, at: 0)
        let b = sighting(0.5, at: 1.0 / 60)
        XCTAssertEqual(ShotAssembler.speed(from: a, to: b), 30, accuracy: 0.01)
    }

    func testDuplicateTimestampsDontDivideByZero() {
        let a = sighting(0, at: 5)
        let b = sighting(1, at: 5)
        XCTAssertEqual(ShotAssembler.speed(from: a, to: b), 0)
        XCTAssertEqual(ShotAssembler.speed(from: nil, to: b), 0)
    }
}
