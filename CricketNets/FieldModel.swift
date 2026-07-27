import CoreGraphics
import Foundation

/// A fielder on the ground. Position is in field meters: origin at the striker,
/// +x = off side (for a right-hander), +y = straight down the ground toward the bowler.
struct Fielder: Identifiable, Equatable, Codable {
    var id = UUID()
    var name: String
    var position: CGPoint   // meters
    var isKeeper: Bool = false
}

/// The ground: a circular boundary plus the fielders standing inside it.
struct Field: Equatable, Codable {
    /// Boundary radius in meters (rope distance from the striker). ~65 m is a typical ground.
    var boundaryRadius: Double = 65
    var fielders: [Fielder]
    var battingHand: Hand = .right

    enum Hand: String, CaseIterable, Codable { case right, left }

    /// Named field templates. Positions are (angle°, radius m): angle 0 = straight down the ground,
    /// positive = off side, ±180 = behind the keeper.
    enum Preset: String, CaseIterable, Identifiable, Codable {
        case standard, attacking, defensive, spread
        var id: String { rawValue }
        var label: String { rawValue.capitalized }

        var ring: [(String, Double, Double, Bool)] {
            switch self {
            case .standard:
                return [("Keeper", 180, 3, true), ("Slip", 158, 6, false), ("Gully", 128, 13, false),
                        ("Point", 92, 26, false), ("Cover", 58, 30, false), ("Mid-off", 24, 28, false),
                        ("Mid-on", -24, 28, false), ("Mid-wkt", -58, 30, false), ("Sq leg", -92, 26, false),
                        ("Fine leg", -156, 46, false)]
            case .attacking:   // catchers in close, gaps in the deep
                return [("Keeper", 180, 3, true), ("Slip", 158, 6, false), ("2nd Slip", 168, 6, false),
                        ("Gully", 130, 10, false), ("Silly pt", 100, 6, false), ("Short leg", -162, 5, false),
                        ("Cover", 55, 24, false), ("Mid-off", 20, 22, false), ("Mid-on", -20, 22, false),
                        ("Mid-wkt", -55, 24, false)]
            case .defensive:   // protect the rope, sweepers everywhere
                return [("Keeper", 180, 3, true), ("Third man", 150, 58, false), ("Deep pt", 92, 56, false),
                        ("Deep cover", 55, 58, false), ("Long-off", 15, 60, false), ("Long-on", -15, 60, false),
                        ("Deep mid-wkt", -55, 58, false), ("Deep sq", -92, 56, false), ("Fine leg", -150, 58, false),
                        ("Mid-on", -25, 30, false)]
            case .spread:      // one-day ring, evenly balanced
                return [("Keeper", 180, 3, true), ("Point", 92, 30, false), ("Cover", 55, 32, false),
                        ("Mid-off", 20, 30, false), ("Long-on", -12, 55, false), ("Mid-wkt", -55, 32, false),
                        ("Sq leg", -92, 30, false), ("Fine leg", -150, 45, false), ("Third man", 150, 45, false),
                        ("Deep cover", 60, 55, false)]
            }
        }
    }

    static func preset(_ preset: Preset = .standard, hand: Hand = .right, boundaryRadius: Double = 65) -> Field {
        let mirror = (hand == .left) ? -1.0 : 1.0
        let fielders = preset.ring.map { (name, angleDeg, radius, keeper) -> Fielder in
            let a = angleDeg * .pi / 180
            let r = min(radius, boundaryRadius - 2)   // keep everyone inside the rope
            return Fielder(name: name,
                           position: CGPoint(x: r * sin(a) * mirror, y: r * cos(a)),
                           isKeeper: keeper)
        }
        return Field(boundaryRadius: boundaryRadius, fielders: fielders, battingHand: hand)
    }

    static func standard(hand: Hand = .right) -> Field { preset(.standard, hand: hand) }

    /// Pull any fielders that ended up outside a (possibly shrunk) boundary back onto the rope.
    mutating func clampFieldersToBoundary() {
        let maxR = boundaryRadius - 1
        fielders = fielders.map { f in
            let d = hypot(f.position.x, f.position.y)
            guard d > maxR else { return f }
            var f = f
            f.position = CGPoint(x: f.position.x / d * maxR, y: f.position.y / d * maxR)
            return f
        }
    }
}
