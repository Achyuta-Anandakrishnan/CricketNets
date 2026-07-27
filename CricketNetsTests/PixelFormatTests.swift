import XCTest
import CoreVideo
@testable import CricketNets

/// Colour sampling has to survive two very different pixel formats: BGRA from AVFoundation on the
/// fast path, and bi-planar YCbCr from `ARFrame.capturedImage` on the depth path, which ARKit does
/// not let you configure.
///
/// These build real `CVPixelBuffer`s of each format and push a known colour through, because the
/// original bug was invisible to any test that only used BGRA — and it silently killed 3D tracking
/// for anyone who had calibrated a ball.
final class PixelFormatTests: XCTestCase {

    // MARK: Buffer builders

    private func makeBGRA(width: Int = 32, height: Int = 32,
                          r: UInt8, g: UInt8, b: UInt8) -> CVPixelBuffer {
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
                let p = y * rowBytes + x * 4
                base[p] = b; base[p + 1] = g; base[p + 2] = r; base[p + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// Fill a bi-planar 4:2:0 buffer with one flat YCbCr colour.
    private func makeYCbCr(width: Int = 32, height: Int = 32,
                           y luma: UInt8, cb: UInt8, cr: UInt8,
                           fullRange: Bool = true) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let format = fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                               : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary,
                            &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])

        let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, 0) {
            for x in 0..<CVPixelBufferGetWidthOfPlane(buffer, 0) {
                lumaBase[y * lumaRow + x] = luma
            }
        }

        let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
            for x in 0..<CVPixelBufferGetWidthOfPlane(buffer, 1) {
                chromaBase[y * chromaRow + x * 2] = cb
                chromaBase[y * chromaRow + x * 2 + 1] = cr
            }
        }

        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// BT.601 forward transform, so tests can state a colour in RGB and encode it.
    private func encode(r: Double, g: Double, b: Double) -> (UInt8, UInt8, UInt8) {
        let y = 0.299 * r + 0.587 * g + 0.114 * b
        let cb = 128 + (b - y) * 0.564
        let cr = 128 + (r - y) * 0.713
        return (UInt8(min(max(y, 0), 255)), UInt8(min(max(cb, 0), 255)), UInt8(min(max(cr, 0), 255)))
    }

    // MARK: The format the fast path uses

    func testBGRAStillSamplesCorrectly() throws {
        let buffer = makeBGRA(r: 20, g: 60, b: 200)
        let rgb = try XCTUnwrap(BallColor.averageRGB(buffer, cx: 16, cy: 16, r: 4))
        XCTAssertEqual(rgb.0, 20.0 / 255, accuracy: 0.01)
        XCTAssertEqual(rgb.1, 60.0 / 255, accuracy: 0.01)
        XCTAssertEqual(rgb.2, 200.0 / 255, accuracy: 0.01)
    }

    // MARK: The format ARKit forces on the depth path

    func testYCbCrSamplingReturnsARealColour() throws {
        // A blue ball, the case that surfaced this.
        let (y, cb, cr) = encode(r: 20, g: 60, b: 200)
        let buffer = makeYCbCr(y: y, cb: cb, cr: cr)
        let rgb = try XCTUnwrap(BallColor.averageRGB(buffer, cx: 16, cy: 16, r: 4))
        // 4:2:0 chroma subsampling and 8-bit rounding cost a little precision.
        XCTAssertEqual(rgb.0, 20.0 / 255, accuracy: 0.03)
        XCTAssertEqual(rgb.1, 60.0 / 255, accuracy: 0.03)
        XCTAssertEqual(rgb.2, 200.0 / 255, accuracy: 0.03)
    }

    func testBlueBallSurvivesTheYCbCrRoundTripAndStillMatchesItsProfile() throws {
        // The end-to-end claim: a profile calibrated from the BGRA camera must still match the same
        // ball seen through ARKit's YCbCr buffer. Before the fix this compared against garbage and
        // rejected every trajectory, so 3D mode tracked nothing at all.
        let bgra = makeBGRA(r: 25, g: 70, b: 210)
        let profile = try XCTUnwrap(BallColor.sampleProfile(bgra, centerNormalized: CGPoint(x: 0.5, y: 0.5),
                                                            radiusNormalized: 0.1))

        let (y, cb, cr) = encode(r: 25, g: 70, b: 210)
        let arkit = makeYCbCr(y: y, cb: cb, cr: cr)
        let hsv = try XCTUnwrap(BallColor.sampleHSV(arkit, atNormalized: CGPoint(x: 0.5, y: 0.5), radiusPx: 4))

        XCTAssertTrue(profile.matches(h: hsv.h, s: hsv.s, v: hsv.v),
                      "a blue ball calibrated on the fast path must still match on the depth path")
    }

    func testYCbCrDistinguishesBlueFromRed() throws {
        let (by, bcb, bcr) = encode(r: 20, g: 60, b: 200)
        let (ry, rcb, rcr) = encode(r: 200, g: 40, b: 40)
        let blue = try XCTUnwrap(BallColor.sampleHSV(makeYCbCr(y: by, cb: bcb, cr: bcr),
                                                     atNormalized: CGPoint(x: 0.5, y: 0.5), radiusPx: 4))
        let red = try XCTUnwrap(BallColor.sampleHSV(makeYCbCr(y: ry, cb: rcb, cr: rcr),
                                                    atNormalized: CGPoint(x: 0.5, y: 0.5), radiusPx: 4))

        let blueProfile = BallProfile(hue: blue.h, saturation: blue.s, brightness: blue.v)
        XCTAssertTrue(blueProfile.matches(h: blue.h, s: blue.s, v: blue.v))
        XCTAssertFalse(blueProfile.matches(h: red.h, s: red.s, v: red.v),
                       "the gate must still reject a different colour after the format fix")
    }

    func testVideoRangeIsStretchedNotTakenLiterally() throws {
        // Video-range packs luma into 16...235. Reading it as full range would darken everything
        // and drag brightness outside the profile's tolerance.
        let buffer = makeYCbCr(y: 16, cb: 128, cr: 128, fullRange: false)
        let rgb = try XCTUnwrap(BallColor.averageRGB(buffer, cx: 16, cy: 16, r: 4))
        XCTAssertEqual(rgb.0, 0, accuracy: 0.02, "video-range floor should map to black")
    }

    func testUnknownFormatReturnsNothingRatherThanNoise() {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_OneComponent8,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary,
                            &pb)
        XCTAssertNil(BallColor.averageRGB(pb!, cx: 16, cy: 16, r: 4),
                     "an unhandled format must report nothing, not a confidently wrong colour")
    }
}
