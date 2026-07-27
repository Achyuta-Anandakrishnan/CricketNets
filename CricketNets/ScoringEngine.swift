import CoreGraphics
import Foundation

/// The result of a shot against a set field.
struct ScoreResult: Equatable, Codable {
    enum Outcome: Equatable, Codable {
        case six
        case four
        case caught(fielder: String)
        case runs(Int)   // 0 = dot ball

        var runsScored: Int {
            switch self {
            case .six: return 6
            case .four: return 4
            case .caught: return 0
            case .runs(let r): return r
            }
        }
        var isWicket: Bool {
            if case .caught = self { return true }
            return false
        }
        var label: String {
            switch self {
            case .six: return "SIX"
            case .four: return "FOUR"
            case .caught(let f): return "OUT — caught \(f)"
            case .runs(0): return "Dot ball"
            case .runs(let r): return "\(r) run\(r == 1 ? "" : "s")"
            }
        }
    }

    var outcome: Outcome
    /// Where the ball finishes — the rope for a boundary, the fielder for a catch/stop, or where it
    /// comes to rest, in field meters.
    var landing: CGPoint
    var commentary: String
    /// Metrics of the shot that produced this result (0 if not supplied).
    var speedKmh: Double = 0
    var launchAngleDeg: Double = 0
}

/// Maps a `LaunchVector` onto a `Field` to decide what the shot is worth.
///
/// The ball lives in two phases:
///   A. **Flight** — a parabola from the bat. Clearing the rope here on the full is a six; a fielder
///      reaching it in the air is a catch.
///   B. **Ground** — after the first bounce it skids and rolls, losing speed to the outfield. A
///      fielder in its path cuts it off (runs); reaching the rope is a four; otherwise it stops for runs.
enum ScoringEngine {

    struct Params: Equatable, Codable {
        // Flight
        /// Quadratic air-drag coefficient (1/m): deceleration = airDrag · speed². Keeps lofted
        /// shots from carrying like they're in a vacuum. ~0.0076 matches a real cricket ball.
        var airDrag: Double = 0.0076

        // Catching — reach grows with hang time, so skiers are far easier to take than flat drives.
        /// Base catch radius for a flat, quick chance (m).
        var catchReach: Double = 1.8
        /// Extra catch radius gained per second the ball hangs in the air (a fielder's run speed, m/s).
        var catchRunFactor: Double = 2.6
        /// Cap on the catch radius however long the ball hangs (m).
        var catchReachMax: Double = 16
        /// Max height at which a catch can still be taken (m).
        var reachHeight: Double = 3.0
        /// Ball must be at least this high to be a catch rather than a ground ball (m).
        var catchMinHeight: Double = 0.3

        // Bouncing + rolling
        /// Vertical speed kept after each bounce (turf is dead — most energy is lost).
        var restitution: Double = 0.35
        /// Horizontal speed kept after each bounce.
        var bounceRetain: Double = 0.65
        /// Below this downward speed, the ball stops bouncing and starts rolling (m/s).
        var bounceStopThreshold: Double = 1.5
        /// Outfield rolling-friction deceleration (m/s²). Higher = slower outfield = fewer boundaries.
        var rollDecel: Double = 6.0

        // Ground fielding
        /// How close a grounded/rolling ball must pass a fielder to be cut off (m).
        var fieldReach: Double = 4.0
        /// Max height at which a fielder can still stop the ball on the ground (m).
        var fieldStopHeight: Double = 1.5
    }

    /// One time-stepped simulation covering flight (with drag), bouncing, and rolling.
    static func evaluate(launch l: LaunchVector, field: Field, params p: Params = Params()) -> ScoreResult {
        let g = 9.81
        let dt = 0.005
        let az = l.azimuth
        func point(_ s: Double) -> CGPoint { CGPoint(x: s * sin(az), y: s * cos(az)) }

        // Stamp every result with the shot's metrics so the list + stats can show them.
        let speedKmh = l.speedKmh
        let angleDeg = l.elevationDeg
        func mk(_ o: ScoreResult.Outcome, _ landing: CGPoint, _ c: String) -> ScoreResult {
            ScoreResult(outcome: o, landing: landing, commentary: c, speedKmh: speedKmh, launchAngleDeg: angleDeg)
        }

        var s = 0.0                          // horizontal distance travelled along the shot's line
        var z = max(l.height, 0)             // height above ground
        var vs = l.speed * cos(l.elevation)  // horizontal speed
        var vz = l.speed * sin(l.elevation)  // vertical speed
        var t = 0.0
        var bounces = 0

        while t < 15 {
            let airborne = z > 0.001 || vz > 0
            if airborne {
                let speed = (vs * vs + vz * vz).squareRoot()
                let drag = p.airDrag * speed
                vs += -drag * vs * dt
                vz += (-g - drag * vz) * dt
            } else {
                vs = max(0, vs - p.rollDecel * dt)   // rolling friction
                vz = 0
            }
            s += vs * dt
            z += vz * dt
            t += dt

            // Bounce: reflect and shed energy, or settle into a roll.
            if z < 0 && vz < 0 {
                z = 0
                if -vz > p.bounceStopThreshold {
                    vz = -vz * p.restitution
                    vs *= p.bounceRetain
                    bounces += 1
                } else {
                    vz = 0
                }
            }

            // Boundary: cleared before any bounce = six; anything else = four.
            if s >= field.boundaryRadius {
                if bounces == 0 {
                    return mk(.six, point(field.boundaryRadius), "Cleared the rope on the full!")
                }
                return mk(.four, point(field.boundaryRadius), "Races away to the boundary.")
            }

            // Catch — only on the full (before a bounce). Reach widens the longer the ball hangs.
            if bounces == 0 && z >= p.catchMinHeight && z <= p.reachHeight {
                let reach = min(p.catchReachMax, p.catchReach + p.catchRunFactor * t)
                let ball = point(s)
                for f in field.fielders where hypot(f.position.x - ball.x, f.position.y - ball.y) <= reach {
                    let how = t > 2.0 ? "Skied it — \(f.name) settles under it." : "In the air — taken by \(f.name)."
                    return mk(.caught(fielder: f.name), ball, how)
                }
            }

            // Ground fielding — a fielder cuts off a low/rolling ball after it has bounced.
            if bounces >= 1 && z <= p.fieldStopHeight {
                let ball = point(s)
                for f in field.fielders where hypot(f.position.x - ball.x, f.position.y - ball.y) <= p.fieldReach {
                    return scoreRuns(stopPoint: ball, carry: s, fieldedBy: f.name, field: field, mk: mk)
                }
            }

            // Come to rest inside the field.
            if vs <= 0.02 && z <= 0.05 {
                return scoreRuns(stopPoint: point(s), carry: s, fieldedBy: nil, field: field, mk: mk)
            }
        }
        return scoreRuns(stopPoint: point(s), carry: s, fieldedBy: nil, field: field, mk: mk)
    }

    /// Heuristic run estimate from where the ball ends up: bigger gap to the nearest fielder and a
    /// deeper stop = more runs. Deliberately simple and tunable.
    private static func scoreRuns(stopPoint: CGPoint, carry: Double, fieldedBy: String?, field: Field,
                                  mk: (ScoreResult.Outcome, CGPoint, String) -> ScoreResult) -> ScoreResult {
        let nearest = field.fielders.min {
            hypot($0.position.x - stopPoint.x, $0.position.y - stopPoint.y) <
            hypot($1.position.x - stopPoint.x, $1.position.y - stopPoint.y)
        }
        let gap = nearest.map { hypot($0.position.x - stopPoint.x, $0.position.y - stopPoint.y) } ?? 99

        let runs: Int
        switch gap {
        case ..<4:   runs = carry > 45 ? 1 : 0
        case ..<12:  runs = carry > 45 ? 2 : 1
        default:     runs = carry > 55 ? 3 : (carry > 30 ? 2 : 1)
        }

        let who = fieldedBy ?? nearest?.name ?? "the gap"
        let commentary = runs == 0 ? "Straight to \(who), no run."
                                   : "\(runs) — into the gap near \(who)."
        return mk(.runs(runs), stopPoint, commentary)
    }
}
