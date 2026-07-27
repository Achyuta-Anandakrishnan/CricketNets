import XCTest
import simd
@testable import CricketNets

/// Measuring gravity is the only end-to-end accuracy check available without instrumenting the net,
/// so the fit behind it needs to be right — and, just as importantly, needs to refuse rather than
/// invent a number when the data can't support one.
final class AccuracyTests: XCTestCase {

    /// A ball dropped from `height`, sampled at `fps`, optionally with position noise.
    private func drop(height: Double = 1.5, fps: Double = 60, frames: Int = 12,
                      noise: Double = 0, seed: UInt64 = 1) -> [BallPhysics.WorldSample] {
        var rng = SeededRandom(seed: seed)
        return (0..<frames).map { i in
            let t = Double(i) / fps
            let y = height - 0.5 * BallPhysics.g * t * t
            let jitter = noise > 0 ? rng.next(in: -noise...noise) : 0
            return BallPhysics.WorldSample(position: simd_float3(0, Float(y + jitter), 0), time: t)
        }
    }

    // MARK: The measurement

    func testACleanDropMeasuresGravity() throws {
        let g = try XCTUnwrap(BallPhysics.measuredGravity(worldSamples: drop()))
        XCTAssertEqual(g, 9.81, accuracy: 0.05)
    }

    func testMeasurementSurvivesRealisticDepthNoise() throws {
        // A real drop from about chest height falls for ~0.55 s, which is 33 frames at 60 fps.
        // LiDAR at close range is good to a few centimetres; over a fall that long the fit still
        // lands near 9.81.
        let g = try XCTUnwrap(BallPhysics.measuredGravity(worldSamples: drop(frames: 33, noise: 0.02)))
        XCTAssertEqual(g, 9.81, accuracy: 1.0)
    }

    func testAShortFallIsTooNoisyToTrust() throws {
        // Acceleration is a second derivative, so position noise is amplified by roughly 1/T².
        // Over a 0.2 s window the same 2 cm of LiDAR noise throws the reading out by ~20%, which is
        // why the accuracy screen insists on a decent fall before it records an attempt. Documented
        // as a test so the constraint doesn't get quietly relaxed later.
        let short = try XCTUnwrap(BallPhysics.measuredGravity(worldSamples: drop(frames: 12, noise: 0.02)))
        let long = try XCTUnwrap(BallPhysics.measuredGravity(worldSamples: drop(frames: 33, noise: 0.02)))
        XCTAssertGreaterThan(abs(short - 9.81), abs(long - 9.81),
                             "a short fall must be measurably worse, not accidentally fine")
    }

    func testAHalfScaledPipelineReadsHalfGravity() throws {
        // The failure this test exists to catch: if depth is scaled wrong, every world coordinate
        // shrinks and gravity comes out proportionally small. That's the signature the screen
        // reports as "scale is off by roughly Nx".
        let squashed = drop().map {
            BallPhysics.WorldSample(position: $0.position * 0.5, time: $0.time)
        }
        let g = try XCTUnwrap(BallPhysics.measuredGravity(worldSamples: squashed))
        XCTAssertEqual(g, 9.81 / 2, accuracy: 0.1)
    }

    func testAStaticBallMeasuresNoGravity() throws {
        // Depth locked to the background rather than the ball looks like this.
        let still = (0..<12).map {
            BallPhysics.WorldSample(position: simd_float3(0, 1.5, 0), time: Double($0) / 60)
        }
        let g = try XCTUnwrap(BallPhysics.measuredGravity(worldSamples: still))
        XCTAssertEqual(g, 0, accuracy: 0.01)
    }

    func testARisingBallReadsNegative() throws {
        // A throw upward should not be reported as gravity; the screen rejects anything below 1.
        let thrown = (0..<12).map { i -> BallPhysics.WorldSample in
            let t = Double(i) / 60
            return BallPhysics.WorldSample(position: simd_float3(0, Float(0.5 + 4 * t), 0), time: t)
        }
        let g = try XCTUnwrap(BallPhysics.measuredGravity(worldSamples: thrown))
        XCTAssertLessThan(g, 1)
    }

    // MARK: Refusing rather than guessing

    func testTooFewSamplesRefuses() {
        XCTAssertNil(BallPhysics.measuredGravity(worldSamples: drop(frames: 3)))
        XCTAssertNil(BallPhysics.measuredGravity(worldSamples: []))
    }

    func testSimultaneousSamplesRefuse() {
        let frozen = (0..<6).map {
            BallPhysics.WorldSample(position: simd_float3(0, Float($0), 0), time: 100)
        }
        XCTAssertNil(BallPhysics.measuredGravity(worldSamples: frozen),
                     "a zero time span can't yield an acceleration")
    }

    // MARK: The fit itself

    func testQuadraticFitRecoversRateAndAcceleration() throws {
        // y = 5 + 3t - ½·8·t²
        let times = (0..<10).map { Double($0) / 30 }
        let values = times.map { 5 + 3 * $0 - 0.5 * 8 * $0 * $0 }
        let fit = try XCTUnwrap(BallPhysics.quadraticFit(times: times, values: values))
        XCTAssertEqual(fit.rate, 3, accuracy: 0.01)
        XCTAssertEqual(fit.acceleration, -8, accuracy: 0.01)
    }

    func testQuadraticFitHandlesZeroAcceleration() throws {
        let times = (0..<10).map { Double($0) / 30 }
        let values = times.map { 2 + 4 * $0 }
        let fit = try XCTUnwrap(BallPhysics.quadraticFit(times: times, values: values))
        XCTAssertEqual(fit.rate, 4, accuracy: 0.01)
        XCTAssertEqual(fit.acceleration, 0, accuracy: 0.01)
    }

    func testQuadraticFitRefusesADegenerateSystem() {
        // All samples at one instant makes the normal equations singular. Without the guard this
        // returns an enormous meaningless acceleration rather than nothing.
        XCTAssertNil(BallPhysics.quadraticFit(times: [1, 1, 1], values: [1, 2, 3]))
        XCTAssertNil(BallPhysics.quadraticFit(times: [0, 1], values: [1, 2]))
    }
}

/// Deterministic noise, so a flaky fit can't produce a flaky test.
private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let unit = Double(state >> 11) / Double(UInt64.max >> 11)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
