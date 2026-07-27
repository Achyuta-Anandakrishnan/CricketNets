import SwiftUI
import ARKit

/// Diagnostics for the 3D path — the counterpart to the 2D Testing screen.
///
/// The 2D screen answers "is the detector finding the ball?". This one has to answer two more,
/// because the depth path can fail in ways the fast path can't:
///
/// 1. **Is LiDAR resolving the ball, or the net behind it?** Shown as the depth patch drawn at its
///    real size over the ball, plus the confident-pixel share backing each reading.
/// 2. **Is "down the ground" pointing the right way?** Shown as a live azimuth that updates as the
///    offset is dragged, so a straight ball can be nudged until it reads straight.
///
/// No scoring and no cooldown — it just tracks, so you can wave a ball around and watch the numbers.
struct DepthTestingView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var tracker = DepthTrajectoryTracker()

    @State private var minMotion = 0.03
    @State private var minConf = 0.3
    @State private var colorGate = true

    var body: some View {
        GeometryReader { root in
            content
                .onAppear { tracker.viewport = root.size }
                .onChange(of: root.size) { _, size in tracker.viewport = size }
        }
    }

    private var content: some View {
        ZStack {
            if tracker.isSupported {
                ARPreview(session: tracker.session).ignoresSafeArea()
                ballOverlay
            } else {
                unsupported
            }

            VStack {
                header
                Spacer()
                panel
            }
            .padding()
        }
        .onAppear {
            tracker.setBallProfile(app.ballProfile)
            pushParams()
            tracker.start()
            // Aim from wherever the phone already is, so the offset can be tried immediately.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                tracker.captureGroundDirection(offsetDegrees: app.groundOffsetDeg)
            }
        }
        .onDisappear { tracker.stop() }
    }

    // MARK: Ball + patch overlay

    /// Draws where the ball was last seen and how big the depth patch around it was. If the circle
    /// isn't sitting on the ball, the distance reading is measuring something else.
    private var ballOverlay: some View {
        GeometryReader { geo in
            if let p = tracker.lastBallPoint, let reading = tracker.lastReading {
                // Image space is landscape, the preview is portrait — go through the transform or
                // the marker slides sideways when the ball moves up.
                let t = tracker.displayTransform
                let c = p.applying(t)
                let center = CGPoint(x: c.x * geo.size.width, y: c.y * geo.size.height)

                // The patch is in depth-map pixels; convert to a fraction of the image, then to view.
                let patchNormalized = CGFloat(reading.radiusPx) / 256
                let edge = CGPoint(x: p.x + patchNormalized, y: p.y).applying(t)
                let edgePoint = CGPoint(x: edge.x * geo.size.width, y: edge.y * geo.size.height)
                let radius = max(9, hypot(edgePoint.x - center.x, edgePoint.y - center.y))

                ZStack {
                    Circle()
                        .stroke(reading.confidence > 0.5 ? Color.green : Color.orange, lineWidth: 2)
                        .frame(width: radius * 2, height: radius * 2)
                    Circle()
                        .fill(.white)
                        .frame(width: 4, height: 4)
                }
                .position(center)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("3D TESTING").font(.caption.bold()).tracking(1).foregroundStyle(.cyan)
                Text("\(tracker.pointsResolved)/\(tracker.framesSeen) resolved")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.white)
                if let r = tracker.lastReading {
                    Text(String(format: "%.2f m · patch r%d · %.0f%% confident",
                                r.distance, r.radiusPx, r.confidence * 100))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(r.confidence > 0.5 ? .green : .orange)
                } else {
                    Text("no depth reading")
                        .font(.caption2).foregroundStyle(.orange)
                }
                Text("\(tracker.samples.count) samples this shot")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                gateTally
            }
            .padding(10)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))

            Spacer()

            VStack(spacing: 6) {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent).tint(.white)
                MiniField(field: app.field, lastShot: nil,
                          liveAzimuth: tracker.liveAzimuthDeg.map { $0 * .pi / 180 })
                    .frame(width: 96, height: 96)
                    .background(.black.opacity(0.4), in: Circle())
            }
        }
    }

    /// Which gate is eating the detections. If `candidates` climbs but `accepted` stays at zero,
    /// the number next to it names the culprit immediately.
    private var gateTally: some View {
        let g = tracker.gates
        return VStack(alignment: .leading, spacing: 1) {
            Text("\(g.candidates) candidates → \(g.accepted) passed")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(g.accepted > 0 ? .green : .orange)
            if g.candidates > 0 && g.accepted == 0 {
                Text("dropped: motion \(g.tooLittleMotion) · colour \(g.wrongColor) · conf \(g.lowConfidence)")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.orange.opacity(0.9))
            }
        }
    }

    // MARK: Panel

    private var panel: some View {
        VStack(spacing: 12) {
            placement
            Divider().overlay(.white.opacity(0.2))
            TunableSlider(
                title: "How far the ball must travel",
                value: $minMotion,
                range: 0...0.30,
                reading: TuningWords.travel,
                guidance: "Left = accepts smaller movements, so slow or short shots register but so does background wobble.",
                onEdit: { tracker.setMinTrajectoryMotion($0) }
            )
            TunableSlider(
                title: "How certain before counting it",
                value: $minConf,
                range: 0...1,
                reading: TuningWords.certainty,
                guidance: "Left = counts shakier detections, catching more real shots and more noise.",
                onEdit: { tracker.setMinConfidence(Float($0)) }
            )

            HStack(spacing: 16) {
                Toggle("Colour gate", isOn: $colorGate)
                    .onChange(of: colorGate) { _, v in
                        tracker.setColorGateEnabled(v)
                        tracker.resetCounters()
                    }
                    .font(.caption).tint(.green).foregroundStyle(.white)
                Button("Reset counts") { tracker.resetCounters() }
                    .font(.caption2).buttonStyle(.bordered).tint(.white)
            }

            Text(app.isBallCalibrated
                 ? "Green circle = the depth patch at the size it actually sampled. If detections only appear with the colour gate off, the ball profile is the problem."
                 : "No ball calibrated, so the colour gate is inactive — everything that moves is a candidate.")
                .font(.caption2).foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
    }

    /// Move the phone, say where it is, then fine-tune until a straight ball reads straight.
    private var placement: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PHONE POSITION").font(.caption2.bold()).tracking(0.8)
                .foregroundStyle(.white.opacity(0.6))

            Picker("Placement", selection: $app.phonePlacement) {
                ForEach(PhonePlacement.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: app.phonePlacement) { _, _ in
                tracker.setGroundOffset(app.groundOffsetDeg)
            }

            Text(app.phonePlacement.blurb)
                .font(.caption2).foregroundStyle(.white.opacity(0.6))

            TunableSlider(
                title: "Which way is down the ground",
                value: $app.groundOffsetDeg,
                range: -180...180,
                reading: TuningWords.groundOffset,
                guidance: "Turn this until a ball hit straight reads as “straight” below.",
                step: 1,
                onEdit: { v in
                    if app.phonePlacement != .custom { app.phonePlacement = .custom }
                    tracker.setGroundOffset(v)
                }
            )

            HStack(spacing: 10) {
                Button {
                    tracker.captureGroundDirection(offsetDegrees: app.groundOffsetDeg)
                } label: {
                    Label("Re-aim here", systemImage: "location.north.line.fill").font(.caption)
                }
                .buttonStyle(.bordered).tint(.white)

                Spacer()

                if let az = tracker.liveAzimuthDeg {
                    Text("reads \(AzimuthLabel.text(azimuthDeg: az, hand: app.hand))")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(abs(az) < 8 ? .green : .cyan)
                } else {
                    Text("hit a ball to read direction")
                        .font(.caption2).foregroundStyle(.white.opacity(0.5))
                }
            }

            Text("Hit one straight down the ground and drag Offset until it reads “straight”.")
                .font(.caption2).foregroundStyle(.cyan.opacity(0.85))
        }
    }

    private var unsupported: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 40))
                    .foregroundStyle(.orange)
                Text("LiDAR unavailable").font(.title3.bold()).foregroundStyle(.white)
                Text("3D testing needs a scene-depth sensor and a real device.")
                    .font(.subheadline).multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.6)).padding(.horizontal, 40)
            }
        }
    }

    private func pushParams() {
        tracker.setMinTrajectoryMotion(minMotion)
        tracker.setMinConfidence(Float(minConf))
        tracker.setColorGateEnabled(colorGate)
    }
}
