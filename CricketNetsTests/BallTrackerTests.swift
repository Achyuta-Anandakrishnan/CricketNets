import XCTest
import CoreVideo
@testable import CricketNets

/// Frame-to-frame continuity. The point of these is the recall case: a ball that a strict global
/// scan would drop, but a loose search in the right place still finds.
final class BallTrackerTests: XCTestCase {

    private let width = 320, height = 240

    /// A frame with a ball of the given colour at a normalized position.
    private func frame(at center: CGPoint, radius: Double,
                       ball: (UInt8, UInt8, UInt8)) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary,
                            &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let cx = center.x * Double(width), cy = center.y * Double(height)

        for y in 0..<height {
            for x in 0..<width {
                let inside = hypot(Double(x) - cx, Double(y) - cy) <= radius
                let c = inside ? ball : (30, 30, 30)
                let p = y * rowBytes + x * 4
                base[p] = c.2; base[p + 1] = c.1; base[p + 2] = c.0; base[p + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private let blue: (UInt8, UInt8, UInt8) = (25, 70, 210)

    private func blueProfile() -> BallProfile {
        let hsv = BallColor.rgbToHSV(25.0 / 255, 70.0 / 255, 210.0 / 255)
        return BallProfile(hue: hsv.h, saturation: hsv.s, brightness: hsv.v)
    }

    // MARK: Region search

    func testRegionSearchFindsTheBallInFullFrameCoordinates() throws {
        // A blob found inside a window must still report where it is in the WHOLE frame, or the
        // depth lookup and every world coordinate after it land somewhere else entirely.
        let buffer = frame(at: CGPoint(x: 0.7, y: 0.3), radius: 18, ball: blue)
        let window = CGRect(x: 0.55, y: 0.15, width: 0.3, height: 0.3)
        let found = try XCTUnwrap(BallDetector.detect(in: buffer, profile: blueProfile(),
                                                      region: window, step: 3))
        XCTAssertEqual(found.center.x, 0.7, accuracy: 0.04)
        XCTAssertEqual(found.center.y, 0.3, accuracy: 0.04)
    }

    func testRegionSearchIgnoresABallOutsideTheWindow() {
        let buffer = frame(at: CGPoint(x: 0.2, y: 0.2), radius: 18, ball: blue)
        let elsewhere = CGRect(x: 0.6, y: 0.6, width: 0.3, height: 0.3)
        XCTAssertNil(BallDetector.detect(in: buffer, profile: blueProfile(),
                                         region: elsewhere, step: 3))
    }

    func testWholeFrameAndRegionAgreeOnPosition() throws {
        let buffer = frame(at: CGPoint(x: 0.4, y: 0.6), radius: 20, ball: blue)
        let global = try XCTUnwrap(BallDetector.detect(in: buffer, profile: blueProfile()))
        let local = try XCTUnwrap(BallDetector.detect(in: buffer, profile: blueProfile(),
                                                      region: CGRect(x: 0.25, y: 0.45,
                                                                     width: 0.3, height: 0.3),
                                                      step: 3))
        XCTAssertEqual(global.center.x, local.center.x, accuracy: 0.03)
        XCTAssertEqual(global.center.y, local.center.y, accuracy: 0.03)
    }

    // MARK: Following

    func testFirstSightingIsAnAcquisition() throws {
        var tracker = BallTracker()
        let hit = try XCTUnwrap(tracker.track(in: frame(at: CGPoint(x: 0.5, y: 0.5), radius: 20, ball: blue),
                                              profile: blueProfile(), time: 0))
        XCTAssertFalse(hit.followed, "nothing to follow yet")
        XCTAssertTrue(tracker.isLocked)
    }

    func testSubsequentSightingsAreFollowed() throws {
        var tracker = BallTracker()
        _ = tracker.track(in: frame(at: CGPoint(x: 0.3, y: 0.5), radius: 20, ball: blue),
                          profile: blueProfile(), time: 0)
        let hit = try XCTUnwrap(tracker.track(in: frame(at: CGPoint(x: 0.34, y: 0.5), radius: 20, ball: blue),
                                              profile: blueProfile(), time: 1.0 / 60))
        XCTAssertTrue(hit.followed)
        XCTAssertEqual(hit.detection.center.x, 0.34, accuracy: 0.04)
    }

    func testAWashedOutBallIsStillFoundOnceLockedOn() throws {
        // The reason this class exists. A motion-blurred ball desaturates toward the background,
        // enough that a strict global scan drops it — but the loosened search in the predicted
        // window still picks it up, so the shot doesn't lose frames mid-flight.
        let profile = blueProfile()
        let faded: (UInt8, UInt8, UInt8) = (70, 100, 150)   // washed out, same hue family

        XCTAssertNil(BallDetector.detect(in: frame(at: CGPoint(x: 0.5, y: 0.5), radius: 20, ball: faded),
                                         profile: profile),
                     "a strict global scan should miss this")

        var tracker = BallTracker()
        _ = tracker.track(in: frame(at: CGPoint(x: 0.46, y: 0.5), radius: 20, ball: blue),
                          profile: profile, time: 0)
        let hit = tracker.track(in: frame(at: CGPoint(x: 0.5, y: 0.5), radius: 20, ball: faded),
                                profile: profile, time: 1.0 / 60)
        XCTAssertNotNil(hit, "following should recover the frame a global scan loses")
        XCTAssertEqual(hit?.followed, true)
    }

    func testAFastBallIsFollowedFromTheSecondSighting() throws {
        // The bug this guards. With no velocity yet, the prediction is simply "where it was" — but
        // a struck ball has already moved ~14-28% of the view. A window sized from the ball's
        // radius spans ~5%, so the follow always missed, the tracker fell back to the strict global
        // scan, and velocity was never established. It could never begin following a fast ball.
        var tracker = BallTracker()
        let profile = blueProfile()

        _ = tracker.track(in: frame(at: CGPoint(x: 0.25, y: 0.5), radius: 18, ball: blue),
                          profile: profile, time: 0)
        // 18% of the view in one frame — a hard shot at typical net distance.
        let hit = try XCTUnwrap(tracker.track(in: frame(at: CGPoint(x: 0.43, y: 0.5), radius: 18, ball: blue),
                                              profile: profile, time: 1.0 / 60))
        XCTAssertTrue(hit.followed, "a fast ball must be followed, not re-acquired every frame")
        XCTAssertEqual(hit.detection.center.x, 0.43, accuracy: 0.04)
    }

    func testAFastBallStaysFollowedOnceMoving() throws {
        // Having established velocity, the window narrows again but must still keep up.
        var tracker = BallTracker()
        var followed = 0
        for i in 0..<5 {
            let x = 0.15 + Double(i) * 0.17
            guard let hit = tracker.track(in: frame(at: CGPoint(x: x, y: 0.5), radius: 18, ball: blue),
                                          profile: blueProfile(), time: Double(i) / 60)
            else { return XCTFail("lost a fast ball at frame \(i)") }
            if hit.followed { followed += 1 }
        }
        XCTAssertGreaterThanOrEqual(followed, 3,
                                    "should track a fast ball rather than re-scanning each frame")
    }

    func testLockIsDroppedAfterCoastingTooLong() throws {
        var tracker = BallTracker()
        _ = tracker.track(in: frame(at: CGPoint(x: 0.3, y: 0.5), radius: 20, ball: blue),
                          profile: blueProfile(), time: 0)
        // A long gap makes the prediction worthless; it must re-acquire rather than search stale.
        let hit = try XCTUnwrap(tracker.track(in: frame(at: CGPoint(x: 0.8, y: 0.5), radius: 20, ball: blue),
                                              profile: blueProfile(), time: 2.0))
        XCTAssertFalse(hit.followed, "should have re-acquired, not followed a stale prediction")
        XCTAssertEqual(hit.detection.center.x, 0.8, accuracy: 0.05)
    }

    func testAnEmptyFrameClearsTheLock() {
        var tracker = BallTracker()
        _ = tracker.track(in: frame(at: CGPoint(x: 0.5, y: 0.5), radius: 20, ball: blue),
                          profile: blueProfile(), time: 0)
        XCTAssertTrue(tracker.isLocked)

        let gone = tracker.track(in: frame(at: CGPoint(x: 0.5, y: 0.5), radius: 0, ball: blue),
                                 profile: blueProfile(), time: 1.0 / 60)
        XCTAssertNil(gone)
        XCTAssertFalse(tracker.isLocked, "a stale lock would drag the next window to the wrong place")
    }

    func testFollowingTracksAcrossTheFrame() throws {
        // Walk the ball across several frames; it must stay followed the whole way rather than
        // falling back to a global scan, which is what the funnel's "% followed" reports.
        var tracker = BallTracker()
        var followedCount = 0
        for i in 0..<8 {
            let x = 0.2 + Double(i) * 0.05
            let hit = tracker.track(in: frame(at: CGPoint(x: x, y: 0.5), radius: 18, ball: blue),
                                    profile: blueProfile(), time: Double(i) / 60)
            XCTAssertNotNil(hit, "lost the ball at frame \(i)")
            if hit?.followed == true { followedCount += 1 }
        }
        XCTAssertGreaterThanOrEqual(followedCount, 6, "should follow rather than re-scan each frame")
    }

    // MARK: Choosing between blobs

    /// A frame with a small ball and a large distractor of the same colour.
    private func frameWithDistractor(ball: CGPoint, ballRadius: Double,
                                     distractor: CGPoint, distractorRadius: Double) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary,
                            &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)

        for y in 0..<height {
            for x in 0..<width {
                let onBall = hypot(Double(x) - ball.x * Double(width),
                                   Double(y) - ball.y * Double(height)) <= ballRadius
                let onDistractor = hypot(Double(x) - distractor.x * Double(width),
                                         Double(y) - distractor.y * Double(height)) <= distractorRadius
                let c = (onBall || onDistractor) ? blue : (30, 30, 30)
                let p = y * rowBytes + x * 4
                base[p] = c.2; base[p + 1] = c.1; base[p + 2] = c.0; base[p + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    func testFollowingPrefersTheNearestPlausibleBlobOverTheBiggestOne() throws {
        // The bug this guards, and the reason following kept failing on real shots. The bootstrap
        // window is deliberately wide and the colour gate deliberately loose, so it routinely
        // contains something bigger than the ball — a sleeve, a bag, a stretch of netting. Taking
        // the largest blob grabbed that, the size check then threw the whole frame away, and the
        // tracker fell back to a strict global scan on a motion-blurred target every single frame.
        var tracker = BallTracker()
        let profile = blueProfile()

        _ = tracker.track(in: frame(at: CGPoint(x: 0.30, y: 0.5), radius: 10, ball: blue),
                          profile: profile, time: 0)

        // Both sit inside the wide bootstrap window, far enough apart not to merge into one blob.
        // The distractor is three times the ball's size, so "largest" would take it.
        let cluttered = frameWithDistractor(ball: CGPoint(x: 0.42, y: 0.5), ballRadius: 10,
                                            distractor: CGPoint(x: 0.15, y: 0.5), distractorRadius: 30)
        let hit = try XCTUnwrap(tracker.track(in: cluttered, profile: profile, time: 1.0 / 60))

        XCTAssertTrue(hit.followed, "the ball is right there — this must not fall back to a scan")
        XCTAssertEqual(hit.detection.center.x, 0.42, accuracy: 0.04,
                       "should step over the bigger blob to reach the ball")
    }

    func testDetectionCanBeAskedForTheBlobNearestAPoint() throws {
        let buffer = frameWithDistractor(ball: CGPoint(x: 0.25, y: 0.5), ballRadius: 10,
                                         distractor: CGPoint(x: 0.7, y: 0.5), distractorRadius: 30)
        let largest = try XCTUnwrap(BallDetector.detect(in: buffer, profile: blueProfile(), step: 3))
        XCTAssertEqual(largest.center.x, 0.7, accuracy: 0.05, "by default, the biggest wins")

        let nearest = try XCTUnwrap(
            BallDetector.detect(in: buffer, profile: blueProfile(), step: 3,
                                preferring: .nearest(to: CGPoint(x: 0.25, y: 0.5), radii: 0...1))
        )
        XCTAssertEqual(nearest.center.x, 0.25, accuracy: 0.05)
    }

    func testASizeBandRulesOutTheWrongObjectEvenWhenItIsCloser() {
        // Position alone isn't enough: something the wrong size sitting right on the prediction is
        // not the ball, and accepting it would hand the tracker a lock it can never recover from.
        let buffer = frameWithDistractor(ball: CGPoint(x: 0.5, y: 0.5), ballRadius: 40,
                                         distractor: CGPoint(x: 0.5, y: 0.5), distractorRadius: 0)
        XCTAssertNil(BallDetector.detect(in: buffer, profile: blueProfile(), step: 3,
                                         preferring: .nearest(to: CGPoint(x: 0.5, y: 0.5),
                                                              radii: 0.01...0.05)),
                     "a blob far outside the plausible size band is not the ball")
    }

    // MARK: Profile loosening

    func testLooseningWidensToleranceWithoutMovingTheColour() {
        let p = blueProfile()
        let loose = p.loosened(by: 3)
        XCTAssertEqual(loose.hue, p.hue)
        XCTAssertEqual(loose.saturation, p.saturation)
        XCTAssertGreaterThan(loose.hueTol, p.hueTol)
        XCTAssertGreaterThan(loose.satTol, p.satTol)
    }

    func testLooseningIsClamped() {
        let wild = blueProfile().loosened(by: 100)
        XCTAssertLessThanOrEqual(wild.hueTol, 0.5)
        XCTAssertLessThanOrEqual(wild.satTol, 1.0)
        XCTAssertLessThanOrEqual(wild.valTol, 1.0)
    }
}
