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

// MARK: - Tuning controls

/// A slider that says what it does and what its current setting means.
///
/// The tuning knobs are internal thresholds — a normalized path length, a Vision confidence, a
/// tolerance multiplier — and their raw values ("0.03") say nothing about what will happen if you
/// drag them. This shows a plain-language reading of the current value plus which way to go when
/// something is wrong, so the screen can be used without knowing the implementation.
struct TunableSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Human-readable version of the current value, e.g. "Normal" or "crosses 3% of the frame".
    let reading: (Double) -> String
    /// One line on which way to drag, and what the cost is.
    let guidance: String
    var step: Double = 0
    var onEdit: (Double) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text(reading(value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.cyan)
            }
            slider
            Text(guidance)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    @ViewBuilder
    private var slider: some View {
        if step > 0 {
            Slider(value: $value, in: range, step: step).tint(.cyan)
                .onChange(of: value) { _, v in onEdit(v) }
        } else {
            Slider(value: $value, in: range).tint(.cyan)
                .onChange(of: value) { _, v in onEdit(v) }
        }
    }
}

/// Plain-language readings for the tuning values, kept together so the wording stays consistent
/// wherever a knob appears.
enum TuningWords {

    /// Colour tolerance multiplier: 1.0 is exactly what was calibrated.
    static func colourStrictness(_ multiplier: Double) -> String {
        switch multiplier {
        case ..<0.9:  return "Very strict"
        case ..<1.6:  return "As calibrated"
        case ..<3:    return "Relaxed"
        case ..<5:    return "Loose"
        default:      return "Almost anything"
        }
    }

    /// Minimum path length, as a fraction of the frame.
    static func travel(_ fraction: Double) -> String {
        fraction < 0.005 ? "any movement" : "crosses \(Int(fraction * 100))% of view"
    }

    /// Vision's confidence threshold.
    static func certainty(_ value: Double) -> String {
        switch value {
        case ..<0.2:  return "\(Int(value * 100))% — accept almost all"
        case ..<0.5:  return "\(Int(value * 100))% — balanced"
        default:      return "\(Int(value * 100))% — only sure ones"
        }
    }

    /// Speed above which movement counts as a struck shot.
    static func shotSpeed(_ mps: Double) -> String {
        switch mps {
        case ..<2:  return "any movement"
        case ..<6:  return "a firm push (\(Int(mps * 3.6)) km/h)"
        case ..<12: return "a proper shot (\(Int(mps * 3.6)) km/h)"
        default:    return "only hard hits (\(Int(mps * 3.6)) km/h)"
        }
    }

    /// Rotation from the phone's aim to "down the ground".
    static func groundOffset(_ degrees: Double) -> String {
        if abs(degrees) < 3 { return "aimed down the ground" }
        let side = degrees > 0 ? "right" : "left"
        return "\(Int(abs(degrees)))° to the \(side)"
    }
}

// MARK: - Ball colour

/// The colour the tracker is actually matching against.
///
/// Worth showing anywhere calibration matters: a swatch that plainly isn't your ball explains a
/// failure instantly, where a "not found" message just leaves you guessing whether the problem is
/// the colour, the light, or the detector.
struct BallSwatch: View {
    let profile: BallProfile?
    var showValues = false
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: 8) {
            if let profile {
                let rgb = profile.displayRGB
                Circle()
                    .fill(Color(red: rgb.0, green: rgb.1, blue: rgb.2))
                    .frame(width: size, height: size)
                    .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1))
                if showValues {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("ball colour")
                            .font(.system(size: 9)).foregroundStyle(.white.opacity(0.6))
                        Text(String(format: "H%.2f S%.2f V%.2f",
                                    profile.hue, profile.saturation, profile.brightness))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                        Text(String(format: "±%.2f ±%.2f ±%.2f",
                                    profile.hueTol, profile.satTol, profile.valTol))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.cyan.opacity(0.8))
                    }
                }
            } else {
                Circle()
                    .strokeBorder(.white.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(width: size, height: size)
                if showValues {
                    Text("no ball calibrated")
                        .font(.system(size: 9)).foregroundStyle(.orange)
                }
            }
        }
    }
}

// MARK: - Version

/// What's actually installed, read from the built bundle.
///
/// Exists so a fresh install can be told apart from a stale one at a glance — on device the app
/// icon and launch screen look identical between builds, and "did that change deploy?" is otherwise
/// guesswork. `version` is the release; `build` moves per build of the same release.
enum AppVersion {
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    static let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    static var display: String { "v\(version) (\(build))" }
}

/// Small, unobtrusive build stamp for the idle screens.
struct VersionBadge: View {
    var body: some View {
        Text(AppVersion.display)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.white.opacity(0.07), in: Capsule())
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
