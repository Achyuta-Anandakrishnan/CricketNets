import CoreVideo
import CoreGraphics
import Foundation

/// Adds frame-to-frame continuity on top of per-frame detection.
///
/// A single global scan is caught between two requirements. It must be strict enough not to lock
/// onto the wrong thing anywhere in the frame — and a ball in flight is motion-blurred, partly lit,
/// and small, so a strict threshold drops frames. Loosening it globally just means grabbing the
/// wrong object instead.
///
/// Once the ball has been found, that tension disappears. Its next position is roughly known, so
/// the search can be **narrow, finely sampled and forgiving** all at once: a washed-out smear in
/// exactly the right place is the ball, whereas the same smear across the net is not. Recall goes
/// up without recall's usual cost.
///
/// Gaps are still fine — `ShotAssembler` works from timestamps, so a missed frame just means one
/// fewer sample rather than a broken shot. This is about needing far fewer of them.
struct BallTracker {

    /// How far around the predicted position to search, as a multiple of the ball's radius.
    var searchRadiusMultiple: Double = 5

    /// Smallest search window, as a fraction of frame width — a tiny ball still needs somewhere
    /// to be found.
    var minSearchHalfWidth: Double = 0.04

    /// Window used on the first follow after acquiring, before any velocity is known.
    ///
    /// This has to be large, and getting it wrong stops the tracker working on exactly the shots
    /// that matter. With no velocity the prediction is simply "where it was", but a struck ball has
    /// already moved a long way: at 3.5 m a 100 km/h shot travels ~14% of the view between frames,
    /// and a 145 km/h one ~20%. A window sized from the ball's radius alone spans ~5%, so the
    /// follow always missed, the tracker fell back to the strict global scan, and velocity was
    /// never established — meaning it could never begin following a fast ball at all.
    var bootstrapHalfWidth: Double = 0.30

    /// Extra margin added around the predicted point once velocity IS known, as a fraction of the
    /// distance the ball is expected to travel this frame. Covers acceleration and jitter in the
    /// estimate without reopening the window to the whole frame.
    var predictionMargin: Double = 0.6

    /// How much to relax the colour tolerances inside the predicted window. Safe to be generous:
    /// position is doing the discriminating that colour normally has to.
    var trackingTolerance: Double = 2.5

    /// Give up the lock if nothing has been seen for this long; the prediction goes stale fast.
    var maxCoastSeconds: TimeInterval = 0.15

    /// Sampling stride inside the window. Finer than the global scan because the area is small.
    var trackingStep = 3
    var acquireStep = 8

    struct Result {
        let detection: BallDetector.Detection
        /// True when found by following the prediction rather than by a full-frame scan.
        let followed: Bool
    }

    private var last: BallDetector.Detection?
    private var lastTime: TimeInterval?
    /// Normalized units per second.
    private var velocity: CGVector = .zero
    /// False until two sightings have been paired up; until then `velocity` is a guess of zero.
    private var hasVelocity = false

    var isLocked: Bool { last != nil }

    /// Find the ball, preferring to follow it from where it was.
    mutating func track(in buffer: CVPixelBuffer,
                        profile: BallProfile,
                        time: TimeInterval) -> Result? {
        if let followed = follow(in: buffer, profile: profile, time: time) {
            return followed
        }
        return acquire(in: buffer, profile: profile, time: time)
    }

    mutating func reset() {
        last = nil
        lastTime = nil
        velocity = .zero
        hasVelocity = false
    }

    // MARK: Following

    private mutating func follow(in buffer: CVPixelBuffer,
                                 profile: BallProfile,
                                 time: TimeInterval) -> Result? {
        guard let last, let lastTime else { return nil }
        let dt = time - lastTime
        guard dt > 0, dt <= maxCoastSeconds else {
            reset()
            return nil
        }

        // Where it should be now, carrying the last known velocity forward.
        let predicted = CGPoint(x: last.center.x + velocity.dx * dt,
                                y: last.center.y + velocity.dy * dt)

        // Without a velocity estimate the prediction is just the old position, which for a struck
        // ball is nowhere near it — so search wide. Once velocity is known the prediction is good
        // and the window can close down to the ball plus a margin for acceleration.
        let half: Double
        if hasVelocity {
            let travel = hypot(velocity.dx, velocity.dy) * dt
            half = max(minSearchHalfWidth,
                       last.radiusNormalized * searchRadiusMultiple + travel * predictionMargin)
        } else {
            half = bootstrapHalfWidth
        }

        let window = CGRect(x: predicted.x - half, y: predicted.y - half,
                            width: half * 2, height: half * 2)

        // The colour gate stays loose even in the wide bootstrap window, because a fast ball is
        // blurred on every frame including that one — a strict gate there simply can't get started.
        // What keeps that safe is size: a ball's apparent radius barely changes between frames, so
        // a blob of the wrong size is rejected regardless of how well its colour matches.
        guard let found = BallDetector.detect(in: buffer,
                                              profile: profile.loosened(by: trackingTolerance),
                                              region: window,
                                              step: trackingStep,
                                              minPixels: 3),
              isPlausibleSize(found, comparedTo: last)
        else { return nil }

        update(found, at: time)
        return Result(detection: found, followed: true)
    }

    // MARK: Acquiring

    private mutating func acquire(in buffer: CVPixelBuffer,
                                  profile: BallProfile,
                                  time: TimeInterval) -> Result? {
        guard let found = BallDetector.detect(in: buffer, profile: profile, step: acquireStep),
              found.looksLikeABall
        else {
            // Nothing credible anywhere — drop the lock so a stale prediction can't drag the next
            // window somewhere the ball has long since left.
            reset()
            return nil
        }
        update(found, at: time)
        return Result(detection: found, followed: false)
    }

    /// Between two frames a ball barely changes apparent size — it would have to halve or double
    /// its distance to do so. Anything outside that band is a different object that happens to be
    /// the right colour, which is exactly what a loosened gate in a wide window risks finding.
    private func isPlausibleSize(_ found: BallDetector.Detection,
                                 comparedTo previous: BallDetector.Detection) -> Bool {
        guard previous.radiusNormalized > 0 else { return true }
        let ratio = found.radiusNormalized / previous.radiusNormalized
        return ratio > 0.4 && ratio < 2.5
    }

    /// Record a sighting and re-estimate velocity.
    private mutating func update(_ found: BallDetector.Detection, at time: TimeInterval) {
        if let last, let lastTime, time > lastTime {
            let dt = time - lastTime
            let measured = CGVector(dx: (found.center.x - last.center.x) / dt,
                                    dy: (found.center.y - last.center.y) / dt)
            if hasVelocity {
                // Light smoothing: enough to survive one jittery centre, not so much that it lags
                // a ball that is genuinely accelerating off the bat.
                velocity = CGVector(dx: velocity.dx * 0.3 + measured.dx * 0.7,
                                    dy: velocity.dy * 0.3 + measured.dy * 0.7)
            } else {
                // Take the first measurement whole. Blending it against the zero placeholder would
                // under-read the speed just when the window most needs to be pointed correctly.
                velocity = measured
                hasVelocity = true
            }
        }
        last = found
        lastTime = time
    }
}

extension BallProfile {
    /// A copy with the tolerances widened, for searching where the ball is already known to be.
    func loosened(by factor: Double) -> BallProfile {
        var copy = self
        copy.hueTol = min(0.5, hueTol * factor)
        copy.satTol = min(1.0, satTol * factor)
        copy.valTol = min(1.0, valTol * factor)
        // Normalized chroma spans roughly 0...2, so the ceiling is far above HSV's 0...1 channels.
        // For reference, grey sits ~1.17 from a blue ball, so tracking's 2.5x (0.88) stays clear of
        // it while the user slider can still be dragged to "matches almost anything".
        copy.chromaTol = min(1.5, chromaTol * factor)
        return copy
    }
}
