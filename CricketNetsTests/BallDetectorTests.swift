import XCTest
import CoreVideo
@testable import CricketNets

/// Per-frame ball finding, exercised against real `CVPixelBuffer`s with a ball painted into them.
/// This is the layer everything else in the 3D path stands on, so it's worth proving directly
/// rather than inferring from whether scoring happens.
final class BallDetectorTests: XCTestCase {

    private let width = 320, height = 240

    /// Paint a filled disc of one colour onto a background, as BGRA.
    private func frame(ballCenter: CGPoint, ballRadius: Double,
                       ball: (UInt8, UInt8, UInt8),
                       background: (UInt8, UInt8, UInt8) = (30, 30, 30)) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary,
                            &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let cx = ballCenter.x * Double(width), cy = ballCenter.y * Double(height)

        for y in 0..<height {
            for x in 0..<width {
                let inside = hypot(Double(x) - cx, Double(y) - cy) <= ballRadius
                let c = inside ? ball : background
                let p = y * rowBytes + x * 4
                base[p] = c.2; base[p + 1] = c.1; base[p + 2] = c.0; base[p + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func blueProfile() -> BallProfile {
        let hsv = BallColor.rgbToHSV(25.0 / 255, 70.0 / 255, 210.0 / 255)
        return BallProfile(hue: hsv.h, saturation: hsv.s, brightness: hsv.v)
    }

    private let blue: (UInt8, UInt8, UInt8) = (25, 70, 210)

    // MARK: Finding it at all

    func testFindsABlueBall() throws {
        let buffer = frame(ballCenter: CGPoint(x: 0.5, y: 0.5), ballRadius: 24, ball: blue)
        let found = try XCTUnwrap(BallDetector.detect(in: buffer, profile: blueProfile()))
        XCTAssertEqual(found.center.x, 0.5, accuracy: 0.04)
        XCTAssertEqual(found.center.y, 0.5, accuracy: 0.04)
    }

    func testLocatesAnOffCentreBall() throws {
        let buffer = frame(ballCenter: CGPoint(x: 0.25, y: 0.7), ballRadius: 20, ball: blue)
        let found = try XCTUnwrap(BallDetector.detect(in: buffer, profile: blueProfile()))
        XCTAssertEqual(found.center.x, 0.25, accuracy: 0.05)
        XCTAssertEqual(found.center.y, 0.7, accuracy: 0.05)
    }

    func testReportsRoughlyTheRightSize() throws {
        let buffer = frame(ballCenter: CGPoint(x: 0.5, y: 0.5), ballRadius: 32, ball: blue)
        let found = try XCTUnwrap(BallDetector.detect(in: buffer, profile: blueProfile()))
        // 32 px of a 320-wide frame = 0.1 normalized; the sampling stride costs some precision.
        XCTAssertEqual(found.radiusNormalized, 0.1, accuracy: 0.03)
    }

    func testFindsNothingInAnEmptyFrame() {
        let buffer = frame(ballCenter: CGPoint(x: 0.5, y: 0.5), ballRadius: 0, ball: blue)
        XCTAssertNil(BallDetector.detect(in: buffer, profile: blueProfile()))
    }

    func testIgnoresABallOfTheWrongColour() {
        let red: (UInt8, UInt8, UInt8) = (210, 40, 40)
        let buffer = frame(ballCenter: CGPoint(x: 0.5, y: 0.5), ballRadius: 24, ball: red)
        XCTAssertNil(BallDetector.detect(in: buffer, profile: blueProfile()))
    }

    // MARK: Not being fooled

    func testPicksTheLargestBlobNotTheAverageOfTwo() throws {
        // Two patches of ball colour. Averaging every matching pixel would put the centre in the
        // empty space between them; connected components must pick the bigger one.
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
                let big = hypot(Double(x) - 0.2 * Double(width), Double(y) - 0.5 * Double(height)) <= 28
                let small = hypot(Double(x) - 0.85 * Double(width), Double(y) - 0.5 * Double(height)) <= 8
                let c = (big || small) ? blue : (30, 30, 30)
                let p = y * rowBytes + x * 4
                base[p] = c.2; base[p + 1] = c.1; base[p + 2] = c.0; base[p + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let found = try XCTUnwrap(BallDetector.detect(in: buffer, profile: blueProfile()))
        XCTAssertEqual(found.center.x, 0.2, accuracy: 0.06, "should lock onto the larger blob")
        XCTAssertLessThan(found.concentration, 1.0, "the smaller patch should still count as matched")
    }

    func testCoverageFlagsAProfileThatMatchesEverything() throws {
        // A profile loose enough to match the background too swallows the whole frame in one blob.
        // Concentration reads a perfect 1.0 in that case — every match IS in the blob — so coverage
        // is the only thing that catches it.
        var loose = blueProfile()
        loose.hueTol = 1; loose.satTol = 1; loose.valTol = 1
        let buffer = frame(ballCenter: CGPoint(x: 0.5, y: 0.5), ballRadius: 10, ball: blue)
        let found = try XCTUnwrap(BallDetector.detect(in: buffer, profile: loose))

        XCTAssertEqual(found.concentration, 1.0, accuracy: 0.001, "one blob, so concentration can't help")
        XCTAssertGreaterThan(found.frameCoverage, 0.9)
        XCTAssertFalse(found.looksLikeABall)
    }

    func testARealBallCoversLittleOfTheFrame() throws {
        let buffer = frame(ballCenter: CGPoint(x: 0.5, y: 0.5), ballRadius: 20, ball: blue)
        let found = try XCTUnwrap(BallDetector.detect(in: buffer, profile: blueProfile()))
        XCTAssertLessThan(found.frameCoverage, 0.1)
        XCTAssertTrue(found.looksLikeABall)
    }

    // MARK: The format ARKit actually delivers

    func testWorksOnARKitsYCbCrFrames() throws {
        // Same scene in the format ARKit hands over. If this regresses, 3D goes blind again.
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary,
                            &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])

        func encode(_ r: Double, _ g: Double, _ b: Double) -> (UInt8, UInt8, UInt8) {
            let y = 0.299 * r + 0.587 * g + 0.114 * b
            return (UInt8(min(max(y, 0), 255)),
                    UInt8(min(max(128 + (b - y) * 0.564, 0), 255)),
                    UInt8(min(max(128 + (r - y) * 0.713, 0), 255)))
        }
        let ballY = encode(25, 70, 210), bgY = encode(30, 30, 30)

        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let cx = 0.6 * Double(width), cy = 0.4 * Double(height)

        for y in 0..<height {
            for x in 0..<width {
                let inside = hypot(Double(x) - cx, Double(y) - cy) <= 26
                luma[y * lumaRow + x] = inside ? ballY.0 : bgY.0
            }
        }
        for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
            for x in 0..<CVPixelBufferGetWidthOfPlane(buffer, 1) {
                let inside = hypot(Double(x * 2) - cx, Double(y * 2) - cy) <= 26
                chroma[y * chromaRow + x * 2] = inside ? ballY.1 : bgY.1
                chroma[y * chromaRow + x * 2 + 1] = inside ? ballY.2 : bgY.2
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let found = try XCTUnwrap(BallDetector.detect(in: buffer, profile: blueProfile()))
        XCTAssertEqual(found.center.x, 0.6, accuracy: 0.06)
        XCTAssertEqual(found.center.y, 0.4, accuracy: 0.06)
    }

    // MARK: Optical range

    func testOpticalDistanceFollowsApparentSize() throws {
        // A ball filling more of the frame must read as closer.
        let near = try XCTUnwrap(BallDetector.opticalDistance(radiusNormalized: 0.05,
                                                              frameWidthPx: 1920, focalLengthPx: 1500))
        let far = try XCTUnwrap(BallDetector.opticalDistance(radiusNormalized: 0.01,
                                                             frameWidthPx: 1920, focalLengthPx: 1500))
        XCTAssertLessThan(near, far)
        // r = 0.01 · 1920 = 19.2 px → 0.036 · 1500 / 19.2 ≈ 2.8 m
        XCTAssertEqual(far, 2.8, accuracy: 0.2)
    }

    func testOpticalDistanceRefusesASubPixelBall() {
        XCTAssertNil(BallDetector.opticalDistance(radiusNormalized: 0.0001,
                                                  frameWidthPx: 1920, focalLengthPx: 1500))
    }
}
