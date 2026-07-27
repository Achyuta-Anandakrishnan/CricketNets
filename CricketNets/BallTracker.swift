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
    /// Wide enough to absorb a bad velocity estimate, narrow enough to stay unambiguous.
    var searchRadiusMultiple: Double = 5

    /// Smallest search window, as a fraction of frame width — a tiny ball still needs somewhere
    /// to be found.
    var minSearchHalfWidth: Double = 0.04

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
        let half = max(minSearchHalfWidth, last.radiusNormalized * searchRadiusMultiple)
        let window = CGRect(x: predicted.x - half, y: predicted.y - half,
                            width: half * 2, height: half * 2)

        guard let found = BallDetector.detect(in: buffer,
                                              profile: profile.loosened(by: trackingTolerance),
                                              region: window,
                                              step: trackingStep,
                                              minPixels: 3)
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

    /// Record a sighting and re-estimate velocity.
    private mutating func update(_ found: BallDetector.Detection, at time: TimeInterval) {
        if let last, let lastTime, time > lastTime {
            let dt = time - lastTime
            let measured = CGVector(dx: (found.center.x - last.center.x) / dt,
                                    dy: (found.center.y - last.center.y) / dt)
            // Light smoothing: enough to survive one jittery centre, not so much that it lags a
            // ball that is genuinely accelerating off the bat.
            velocity = CGVector(dx: velocity.dx * 0.3 + measured.dx * 0.7,
                                dy: velocity.dy * 0.3 + measured.dy * 0.7)
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
