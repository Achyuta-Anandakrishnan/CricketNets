import XCTest
import CoreGraphics
@testable import CricketNets

final class ScoringEngineTests: XCTestCase {

    private func launch(_ kmh: Double, _ elevDeg: Double, _ azDeg: Double) -> LaunchVector {
        LaunchVector(speed: kmh / 3.6,
                     elevation: elevDeg * .pi / 180,
                     azimuth: azDeg * .pi / 180,
                     height: 1.0)
    }

    private let emptyField = Field(boundaryRadius: 65, fielders: [], battingHand: .right)

    func testBigLoftedStraightHitIsSix() {
        let r = ScoringEngine.evaluate(launch: launch(130, 38, 0), field: emptyField)
        XCTAssertEqual(r.outcome, .six)
        XCTAssertEqual(r.outcome.runsScored, 6)
    }

    func testSoftPushIsNeitherBoundaryNorWicket() {
        let r = ScoringEngine.evaluate(launch: launch(30, 10, 0), field: emptyField)
        XCTAssertFalse(r.outcome.isWicket)
        XCTAssertLessThanOrEqual(r.outcome.runsScored, 3)
    }

    func testFielderInTheLineTakesTheCatch() {
        // A lofted straight ball (verified to land ~54 m); a fielder on the line at 40 m catches it.
        let field = Field(boundaryRadius: 65,
                          fielders: [Fielder(name: "Mid-on", position: CGPoint(x: 0, y: 40))],
                          battingHand: .right)
        let r = ScoringEngine.evaluate(launch: launch(85, 40, 0), field: field)
        XCTAssertTrue(r.outcome.isWicket)
    }

    func testFieldPlacementChangesTheOutcome() {
        // The product promise: same shot, different field, different result.
        let shot = launch(85, 40, 0)
        let openResult = ScoringEngine.evaluate(launch: shot, field: emptyField)
        let coveredField = Field(boundaryRadius: 65,
                                 fielders: [Fielder(name: "Mid-on", position: CGPoint(x: 0, y: 40))],
                                 battingHand: .right)
        let coveredResult = ScoringEngine.evaluate(launch: shot, field: coveredField)

        XCTAssertFalse(openResult.outcome.isWicket, "no fielder → not out")
        XCTAssertTrue(coveredResult.outcome.isWicket, "fielder on the line → out")
        XCTAssertNotEqual(openResult.outcome, coveredResult.outcome)
    }

    func testBallFieldedAfterBounceIsRunsNotCatch() {
        // A driven ball that bounces before reaching a deep fielder is fielded for runs, not caught.
        let field = Field(boundaryRadius: 65,
                          fielders: [Fielder(name: "Long-on", position: CGPoint(x: 0, y: 45))],
                          battingHand: .right)
        let r = ScoringEngine.evaluate(launch: launch(120, 3, 0), field: field)
        XCTAssertFalse(r.outcome.isWicket)
        if case .runs = r.outcome {} else { XCTFail("expected runs, got \(r.outcome.label)") }
    }

    func testEngineIsDeterministic() {
        let shot = launch(95, 22, 40)
        let a = ScoringEngine.evaluate(launch: shot, field: Field.standard())
        let b = ScoringEngine.evaluate(launch: shot, field: Field.standard())
        XCTAssertEqual(a, b)
    }
}
