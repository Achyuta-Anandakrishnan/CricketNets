import Foundation
import simd

/// Where the phone is set up relative to the batter.
///
/// This exists because the two things you want from a camera position fight each other. Azimuth is
/// measured from whichever direction you call "down the ground", and the obvious way to set that is
/// to point the phone down the pitch — but that's often the *worst* place to watch a ball from,
/// because a shot hit straight travels almost directly away from the lens and barely moves across
/// the frame. Side-on sees the travel far better.
///
/// So placement and reference direction are separated: put the phone wherever tracks best, then say
/// where it is, and the ground direction is derived by rotating the camera's forward by that much.
enum PhonePlacement: String, CaseIterable, Identifiable, Codable {
    case downTheGround
    case offSide
    case legSide
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .downTheGround: return "Down ground"
        case .offSide:       return "Off side"
        case .legSide:       return "Leg side"
        case .custom:        return "Custom"
        }
    }

    var blurb: String {
        switch self {
        case .downTheGround: return "Behind the stumps, looking down the pitch. Simplest, but straight shots move least across the frame."
        case .offSide:       return "Square of the wicket on the off side. Best view of ball travel."
        case .legSide:       return "Square of the wicket on the leg side."
        case .custom:        return "Set the offset by hand until a straight shot reads as straight."
        }
    }

    /// Degrees to rotate the camera's forward by to arrive at "down the ground".
    ///
    /// These are the geometric expectation, not gospel — which way the rotation needs to go depends
    /// on which side of the pitch you're standing, and it is far quicker to hit one straight ball
    /// and nudge the offset until it reads straight than to reason it out. The 3D testing screen
    /// exists for exactly that, which is why `custom` is a first-class option.
    var defaultOffsetDegrees: Double {
        switch self {
        case .downTheGround: return 0
        case .offSide:       return 90
        case .legSide:       return -90
        case .custom:        return 0
        }
    }
}

extension PhonePlacement {
    /// Rotate a horizontal direction (ARKit world x, z) by `degrees`, positive toward the camera's
    /// right — the same sense azimuth uses, so a positive offset and a positive azimuth agree.
    static func rotate(_ direction: simd_float2, byDegrees degrees: Double) -> simd_float2 {
        let normalized = simd_length(direction) > 1e-5 ? simd_normalize(direction) : simd_float2(0, -1)
        let radians = Float(degrees * .pi / 180)
        let c = cos(radians), s = sin(radians)
        // right = (−z, x), so rotating by θ is forward·cosθ + right·sinθ.
        return simd_float2(normalized.x * c - normalized.y * s,
                           normalized.y * c + normalized.x * s)
    }
}
