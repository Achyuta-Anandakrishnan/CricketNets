import SwiftUI

/// Live readouts shared by both tracking modes.
///
/// The centrepiece is `MiniField`: now that the depth path measures azimuth for real, the useful
/// question during a session stops being "how fast?" and becomes "where did it go?". Showing the
/// shot on a small top-down ground answers that without leaving the camera.

// MARK: - Mini field

/// A compact top-down ground with your fielders and the last shot drawn on it.
/// Pure SwiftUI over plain values, so it renders fine in the Simulator and in previews.
struct MiniField: View {
    let field: Field
    var lastShot: ScoreResult?
    /// Draws a faint wedge showing which way the ball left the bat, before it has been scored.
    var liveAzimuth: Double?

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let scale = (side / 2) / CGFloat(field.boundaryRadius)

            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.22))
                    .overlay(Circle().stroke(.white.opacity(0.55), lineWidth: 1.5))
                    .frame(width: side, height: side)
                    .position(center)

                // 30-yard ring, for a sense of depth
                Circle()
                    .stroke(.white.opacity(0.22), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                    .frame(width: side * CGFloat(13.7 / field.boundaryRadius),
                           height: side * CGFloat(13.7 / field.boundaryRadius))
                    .position(center)

                Canvas { ctx, _ in
                    // Fielders as small dots — enough to read the gaps at a glance.
                    for f in field.fielders {
                        let p = CGPoint(x: center.x + f.position.x * scale,
                                        y: center.y - f.position.y * scale)
                        let r: CGFloat = f.isKeeper ? 2.5 : 2
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                                 with: .color(f.isKeeper ? .yellow : .orange))
                    }

                    // The direction the ball is heading, before the outcome is known.
                    if let liveAzimuth {
                        let end = CGPoint(x: center.x + sin(liveAzimuth) * side / 2,
                                          y: center.y - cos(liveAzimuth) * side / 2)
                        var ray = Path()
                        ray.move(to: center)
                        ray.addLine(to: end)
                        ctx.stroke(ray, with: .color(.white.opacity(0.5)),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }

                    // The scored shot.
                    if let lastShot {
                        let end = CGPoint(x: center.x + lastShot.landing.x * scale,
                                          y: center.y - lastShot.landing.y * scale)
                        var line = Path()
                        line.move(to: center)
                        line.addLine(to: end)
                        let color = lastShot.outcome.color
                        ctx.stroke(line, with: .color(color), lineWidth: 2)
                        ctx.fill(Path(ellipseIn: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6)),
                                 with: .color(color))
                    }
                }

                Circle().fill(.white).frame(width: 4, height: 4).position(center)
            }
        }
    }
}

// MARK: - Metrics

/// One labelled number in the HUD.
struct MetricPill: View {
    let value: String
    let label: String
    var accent: Color = .white
    var caveat: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
                .contentTransition(.numericText())
                .monospacedDigit()
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.65))
            if let caveat {
                Text(caveat)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange.opacity(0.9))
            }
        }
        .frame(minWidth: 62, alignment: .leading)
    }
}

/// Turns a measured azimuth into cricket language. Which side of the wicket "+" means flips with
/// the batting hand, because `Field.preset` mirrors its positions for a left-hander.
enum AzimuthLabel {
    static func text(azimuthDeg: Double, hand: Field.Hand) -> String {
        guard abs(azimuthDeg) >= 3 else { return "straight" }
        let isOffSide = (hand == .right) == (azimuthDeg > 0)
        return "\(Int(abs(azimuthDeg)))° \(isOffSide ? "off" : "leg")"
    }
}

// MARK: - Status

/// The armed / tracking / cooling-down state, as one glanceable capsule.
struct TrackingBadge: View {
    enum State: Equatable {
        case ready
        case tracking
        case cooldown(Int)
        case blocked(String)
    }
    let state: State

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.bold())
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.black.opacity(0.45), in: Capsule())
    }

    private var color: Color {
        switch state {
        case .ready: return .white.opacity(0.65)
        case .tracking: return .green
        case .cooldown: return .orange
        case .blocked: return .red
        }
    }

    private var text: String {
        switch state {
        case .ready: return "READY"
        case .tracking: return "TRACKING"
        case .cooldown(let s): return "NEXT IN \(s)s"
        case .blocked(let why): return why.uppercased()
        }
    }
}

/// A labelled status line with a traffic-light dot and an action — used for the calibration rows.
struct StatusRow: View {
    let ok: Bool
    let text: String
    let button: String
    let action: () -> Void

    var body: some View {
        HStack {
            Circle().fill(ok ? .green : .orange).frame(width: 8, height: 8)
            Text(text)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Button(button, action: action)
                .font(.caption.bold())
                .buttonStyle(.borderedProminent)
                .tint(.green)
        }
    }
}

// MARK: - Mode

/// Choose which tracker drives the Nets tab, with the trade-off stated rather than buried.
struct ModePicker: View {
    @Binding var mode: TrackingMode

    var body: some View {
        VStack(spacing: 6) {
            Picker("Tracking", selection: $mode) {
                ForEach(TrackingMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Text(mode.blurb)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Result

/// The outcome of the last ball, over the live view.
struct ResultBanner: View {
    let shot: ScoreResult
    let hand: Field.Hand

    var body: some View {
        VStack(spacing: 6) {
            Text(shot.outcome.label)
                .font(.system(size: 32, weight: .heavy, design: .rounded))
                .foregroundStyle(shot.outcome.isWicket ? .red : .white)
            Text(shot.commentary)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            HStack(spacing: 14) {
                if shot.speedKmh > 0 { detail("\(Int(shot.speedKmh)) km/h") }
                if shot.launchAngleDeg != 0 { detail("\(Int(shot.launchAngleDeg))° up") }
                detail(AzimuthLabel.text(azimuthDeg: azimuthDeg, hand: hand))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(.black.opacity(0.55))
    }

    /// Recover the shot's direction from where it finished, so the banner can name the side.
    private var azimuthDeg: Double {
        atan2(shot.landing.x, shot.landing.y) * 180 / .pi
    }

    private func detail(_ s: String) -> some View {
        Text(s)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
    }
}

#Preview("Mini field") {
    MiniField(
        field: .standard(),
        lastShot: ScoreResult(outcome: .four, landing: CGPoint(x: 42, y: 38),
                              commentary: "Through the covers.", speedKmh: 112, launchAngleDeg: 9),
        liveAzimuth: nil
    )
    .frame(width: 140, height: 140)
    .padding()
    .background(.black)
}
