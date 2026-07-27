import Foundation
import simd

/// Turns a stream of per-frame ball sightings into completed shots.
///
/// `VNDetectTrajectoriesRequest` answered "is this a shot?" implicitly — it only ever reported
/// objects already flying on a parabola, so anything it emitted was by definition a shot. That
/// implicitness is exactly why it was impossible to debug: when it said nothing, there was no way
/// to tell "I can't see the ball" from "the ball isn't moving".
///
/// A per-frame detector sees the ball all the time, including sitting on the ground, so the
/// question has to be asked out loud. The answer is speed between consecutive sightings: a hand
/// carrying a ball moves at walking pace, a struck ball does not.
///
/// Deliberately a plain value type driven by timestamps rather than timers, so the whole
/// start/extend/complete cycle can be unit tested without a device or a clock.
struct ShotAssembler {

    /// Speed (m/s) between sightings that counts as "struck" rather than carried. Walking is about
    /// 1.4 m/s and a gentle throw 8-10, so this sits deliberately low — better to record a soft
    /// push and let scoring call it a dot than to miss the shot entirely.
    var minShotSpeed: Double = 4.0

    /// Quiet time after the last fast sighting before the shot is considered over.
    var settleSeconds: Double = 0.35

    /// Fewest sightings worth fitting a launch vector to.
    var minSamples: Int = 3

    private(set) var samples: [BallPhysics.WorldSample] = []
    private(set) var lastSpeed: Double = 0
    private(set) var isTracking = false

    private var previous: BallPhysics.WorldSample?
    private var lastFastTime: TimeInterval?

    enum Event: Equatable {
        /// Nothing of interest — the ball is visible but not moving like a shot.
        case idle
        /// A shot is underway and this sighting was added to it.
        case tracking
        /// The shot settled. Carries the samples worth scoring, or nil if too few to fit.
        case completed([BallPhysics.WorldSample]?)
    }

    /// Feed one sighting. Returns what it did.
    mutating func add(_ sample: BallPhysics.WorldSample) -> Event {
        defer { previous = sample }

        let speed = Self.speed(from: previous, to: sample)
        lastSpeed = speed

        guard speed >= minShotSpeed else {
            // Still slow. If a shot was running, let `checkSettled` end it on its own clock.
            return isTracking ? .tracking : .idle
        }

        if !isTracking {
            isTracking = true
            // Seed with the previous sighting so the launch itself is in the fit, not just what
            // came after it — the first fast frame is already mid-flight.
            samples = previous.map { [$0] } ?? []
        }
        samples.append(sample)
        lastFastTime = sample.time
        return .tracking
    }

    /// Call periodically with the current time. Ends the shot once it has been quiet long enough.
    mutating func checkSettled(now: TimeInterval) -> Event {
        guard isTracking, let lastFastTime, now - lastFastTime >= settleSeconds else {
            return isTracking ? .tracking : .idle
        }
        let finished = samples
        reset()
        return .completed(finished.count >= minSamples ? finished : nil)
    }

    /// Abandon whatever is in progress.
    mutating func reset() {
        samples = []
        previous = nil
        lastFastTime = nil
        lastSpeed = 0
        isTracking = false
    }

    /// Straight-line speed between two sightings. Zero when they share a timestamp, which happens
    /// if the same frame is somehow delivered twice.
    static func speed(from a: BallPhysics.WorldSample?, to b: BallPhysics.WorldSample) -> Double {
        guard let a else { return 0 }
        let dt = b.time - a.time
        guard dt > 0 else { return 0 }
        return Double(simd_distance(a.position, b.position)) / dt
    }
}
