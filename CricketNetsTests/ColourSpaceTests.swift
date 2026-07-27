import XCTest
@testable import CricketNets

/// HSV vs chroma, tested against the conditions that actually cost frames in a net: shade, glare on
/// a curved ball, and motion blur. The claim being checked is narrow — chroma should hold on to the
/// ball through brightness changes that push HSV out of tolerance, while still rejecting a
/// genuinely different colour.
final class ColourSpaceTests: XCTestCase {

    private func profile(r: Double, g: Double, b: Double,
                         space: BallProfile.ColourSpace) -> BallProfile {
        let hsv = BallColor.rgbToHSV(r, g, b)
        var p = BallProfile(hue: hsv.h, saturation: hsv.s, brightness: hsv.v)
        p.space = space
        return p
    }

    /// A blue ball, as calibrated indoors.
    private let ball = (r: 0.10, g: 0.27, b: 0.82)

    // MARK: Brightness independence

    func testChromaHoldsTheBallInShade() {
        // Same ball, half the light. Every channel scales, so HSV's brightness moves a long way
        // while the chroma direction barely shifts.
        let shaded = (r: ball.r * 0.5, g: ball.g * 0.5, b: ball.b * 0.5)

        let chroma = profile(r: ball.r, g: ball.g, b: ball.b, space: .chroma)
        let hsv = profile(r: ball.r, g: ball.g, b: ball.b, space: .hsv)

        XCTAssertTrue(chroma.matches(r: shaded.r, g: shaded.g, b: shaded.b),
                      "chroma should survive the ball moving into shade")
        XCTAssertFalse(hsv.matches(r: shaded.r, g: shaded.g, b: shaded.b),
                       "HSV's brightness tolerance is what drops this frame")
    }

    func testGlareCostsLessThanAColourChange() {
        // Honest framing: a specular highlight adds white light, which genuinely desaturates the
        // ball in ANY colour space — no representation makes glare free. What matters is that a
        // glared ball still sits far closer to itself than a different colour does, so the gate can
        // be opened enough to keep it without letting the world in.
        let reference = BallColor.rgbToChroma(ball.r, ball.g, ball.b)
        let glared = BallColor.rgbToChroma(ball.r + 0.3, ball.g + 0.3, min(1, ball.b + 0.15))
        let red = BallColor.rgbToChroma(0.82, 0.15, 0.12)

        func distance(_ a: (cb: Double, cr: Double), _ b: (cb: Double, cr: Double)) -> Double {
            hypot(a.cb - b.cb, a.cr - b.cr)
        }
        XCTAssertLessThan(distance(reference, glared), distance(reference, red) / 2,
                          "glare must stay well inside the gap to a genuinely different colour")
    }

    // MARK: Still discriminating

    func testChromaStillRejectsADifferentColour() {
        // The gain would be worthless if it just matched everything.
        let p = profile(r: ball.r, g: ball.g, b: ball.b, space: .chroma)
        XCTAssertFalse(p.matches(r: 0.82, g: 0.15, b: 0.12), "red is not the blue ball")
        XCTAssertFalse(p.matches(r: 0.15, g: 0.60, b: 0.20), "grass is not the blue ball")
    }

    func testChromaRejectsGreyDespiteSimilarBrightness() {
        // Grey has the same luma as a mid-blue but no chroma at all — exactly the confusion
        // brightness-based matching falls into.
        let p = profile(r: ball.r, g: ball.g, b: ball.b, space: .chroma)
        XCTAssertFalse(p.matches(r: 0.35, g: 0.35, b: 0.35))
    }

    func testTheBallMatchesItself() {
        for space in BallProfile.ColourSpace.allCases {
            let p = profile(r: ball.r, g: ball.g, b: ball.b, space: space)
            XCTAssertTrue(p.matches(r: ball.r, g: ball.g, b: ball.b), "\(space.label) must match itself")
        }
    }

    // MARK: The conversion

    func testGreyHasNoChroma() {
        for level in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let c = BallColor.rgbToChroma(level, level, level)
            XCTAssertEqual(c.cb, 0, accuracy: 1e-9)
            XCTAssertEqual(c.cr, 0, accuracy: 1e-9)
        }
    }

    func testChromaIsUnchangedByScalingBrightness() {
        // The property the whole switch rests on, and the one that was wrong before the luma
        // division went in: raw Cb/Cr scale with brightness, so only their *direction* survived
        // and the same ball in shade read as a different colour. Both coordinates must now match,
        // not just the angle between them.
        let full = BallColor.rgbToChroma(ball.r, ball.g, ball.b)
        for scale in [0.25, 0.5, 0.75] {
            let dim = BallColor.rgbToChroma(ball.r * scale, ball.g * scale, ball.b * scale)
            XCTAssertEqual(dim.cb, full.cb, accuracy: 1e-9, "cb moved at \(scale)x light")
            XCTAssertEqual(dim.cr, full.cr, accuracy: 1e-9, "cr moved at \(scale)x light")
        }
    }

    func testVeryDarkPixelsDontExplode() {
        // The luma division needs a floor or near-black noise produces enormous chroma and matches
        // anything. Nearly-black must stay finite and near the origin.
        let nearBlack = BallColor.rgbToChroma(0.004, 0.005, 0.006)
        XCTAssertTrue(nearBlack.cb.isFinite && nearBlack.cr.isFinite)
        XCTAssertLessThan(hypot(nearBlack.cb, nearBlack.cr), 0.2)
    }

    func testBlueAndRedSitOnOppositeSidesOfChroma() {
        let blue = BallColor.rgbToChroma(0.1, 0.2, 0.9)
        let red = BallColor.rgbToChroma(0.9, 0.2, 0.1)
        XCTAssertGreaterThan(blue.cb, 0)
        XCTAssertLessThan(red.cb, 0)
        XCTAssertGreaterThan(red.cr, 0)
    }

    // MARK: White, the coming problem

    func testWhiteIsNearlyIndistinguishableFromGreyInEitherSpace() {
        // Recorded deliberately. A white ball has almost no chroma, so no colour space separates it
        // from a sightscreen, pale netting or white clothing. When the switch to a white ball
        // happens, the answer has to come from motion and apparent size, not from colour.
        let white = profile(r: 0.92, g: 0.93, b: 0.94, space: .chroma)
        XCTAssertTrue(white.matches(r: 0.55, g: 0.55, b: 0.56),
                      "mid-grey matches a white ball's chroma — colour alone cannot separate them")

        let whiteHSV = profile(r: 0.92, g: 0.93, b: 0.94, space: .hsv)
        XCTAssertTrue(whiteHSV.matches(r: 0.88, g: 0.90, b: 0.91),
                      "and HSV is no better — hue is meaningless without saturation")
    }
}
