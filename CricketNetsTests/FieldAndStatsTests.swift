import XCTest
import CoreGraphics
@testable import CricketNets

final class FieldAndStatsTests: XCTestCase {

    func testStandardFieldHasTenFieldersIncludingAKeeper() {
        let field = Field.standard()
        XCTAssertEqual(field.fielders.count, 10)
        XCTAssertTrue(field.fielders.contains { $0.isKeeper })
    }

    func testLeftHanderMirrorsTheField() {
        let rh = Field.standard(hand: .right).fielders.first { $0.name == "Cover" }!
        let lh = Field.standard(hand: .left).fielders.first { $0.name == "Cover" }!
        XCTAssertEqual(rh.position.x, -lh.position.x, accuracy: 0.001)
        XCTAssertEqual(rh.position.y, lh.position.y, accuracy: 0.001)
    }

    func testSessionStatsAggregatesCorrectly() {
        let shots: [ScoreResult] = [
            ScoreResult(outcome: .six, landing: .zero, commentary: ""),
            ScoreResult(outcome: .four, landing: .zero, commentary: ""),
            ScoreResult(outcome: .runs(1), landing: .zero, commentary: ""),
            ScoreResult(outcome: .runs(0), landing: .zero, commentary: ""),
            ScoreResult(outcome: .caught(fielder: "Cover"), landing: .zero, commentary: ""),
        ]
        let stats = SessionStats(shots: shots)
        XCTAssertEqual(stats.runs, 11)
        XCTAssertEqual(stats.balls, 5)
        XCTAssertEqual(stats.fours, 1)
        XCTAssertEqual(stats.sixes, 1)
        XCTAssertEqual(stats.wickets, 1)
        XCTAssertEqual(stats.dots, 1)
        XCTAssertEqual(stats.strikeRate, 220, accuracy: 0.01)
        XCTAssertEqual(stats.boundaryPercent, 40, accuracy: 0.01)
    }

    func testEmptySessionStatsAreZero() {
        let stats = SessionStats(shots: [])
        XCTAssertEqual(stats.balls, 0)
        XCTAssertEqual(stats.strikeRate, 0)
        XCTAssertEqual(stats.boundaryPercent, 0)
    }

    func testTopSpeedStatTakesTheFastest() {
        let shots = [
            ScoreResult(outcome: .four, landing: .zero, commentary: "", speedKmh: 100, launchAngleDeg: 10),
            ScoreResult(outcome: .six, landing: .zero, commentary: "", speedKmh: 130, launchAngleDeg: 35),
        ]
        XCTAssertEqual(SessionStats(shots: shots).fastestKmh, 130, accuracy: 0.01)
    }

    func testScoreResultCarriesLaunchMetrics() {
        let shot = LaunchVector(speed: 112 / 3.6, elevation: 33 * .pi / 180, azimuth: 0, height: 1)
        let r = ScoringEngine.evaluate(launch: shot, field: Field.standard())
        XCTAssertEqual(r.speedKmh, 112, accuracy: 0.5)
        XCTAssertEqual(r.launchAngleDeg, 33, accuracy: 0.5)
    }

    func testFieldSurvivesCodableRoundTrip() {
        let field = Field.preset(.attacking, hand: .left, boundaryRadius: 72)
        let back = try! JSONDecoder().decode(Field.self, from: JSONEncoder().encode(field))
        XCTAssertEqual(back.fielders.count, field.fielders.count)
        XCTAssertEqual(back.boundaryRadius, 72)
        XCTAssertEqual(back.battingHand, .left)
    }

    func testScoreResultSurvivesCodableRoundTrip() {
        let r = ScoreResult(outcome: .caught(fielder: "Cover"), landing: .zero,
                            commentary: "x", speedKmh: 90, launchAngleDeg: 20)
        let back = try! JSONDecoder().decode(ScoreResult.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
    }
}
