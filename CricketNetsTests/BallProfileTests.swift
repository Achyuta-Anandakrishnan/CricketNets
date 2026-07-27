import XCTest
@testable import CricketNets

final class BallProfileTests: XCTestCase {

    func testMatchesASimilarColor() {
        let red = BallProfile(hue: 0.0, saturation: 0.85, brightness: 0.7)
        XCTAssertTrue(red.matches(h: 0.02, s: 0.80, v: 0.65))
    }

    func testRejectsADifferentHue() {
        let red = BallProfile(hue: 0.0, saturation: 0.85, brightness: 0.7)
        XCTAssertFalse(red.matches(h: 0.33, s: 0.80, v: 0.65)) // green
    }

    func testWhiteBallMatchesByBrightnessIgnoringHue() {
        // A near-grey ball has unstable hue, so matching falls back to saturation + brightness.
        let white = BallProfile(hue: 0.1, saturation: 0.05, brightness: 0.95)
        XCTAssertTrue(white.matches(h: 0.6, s: 0.03, v: 0.90)) // different hue, still white-ish
    }

    func testWhiteBallRejectsDarkPixels() {
        let white = BallProfile(hue: 0.1, saturation: 0.05, brightness: 0.95)
        XCTAssertFalse(white.matches(h: 0.1, s: 0.05, v: 0.20))
    }

    func testHueIsCircularAcrossTheWrap() {
        // Red at hue 0.99 should still match a red profile at hue 0.01.
        let red = BallProfile(hue: 0.01, saturation: 0.85, brightness: 0.7)
        XCTAssertTrue(red.matches(h: 0.99, s: 0.85, v: 0.70))
    }

    func testRedRoundTripsThroughHSV() {
        let hsv = BallColor.rgbToHSV(1, 0, 0)
        XCTAssertEqual(hsv.h, 0, accuracy: 0.001)
        XCTAssertEqual(hsv.s, 1, accuracy: 0.001)
        XCTAssertEqual(hsv.v, 1, accuracy: 0.001)
        let rgb = BallColor.hsvToRGB(hsv.h, hsv.s, hsv.v)
        XCTAssertEqual(rgb.0, 1, accuracy: 0.001)
        XCTAssertEqual(rgb.1, 0, accuracy: 0.001)
        XCTAssertEqual(rgb.2, 0, accuracy: 0.001)
    }
}
