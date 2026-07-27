import SwiftUI

/// A diagnostic view: see every trajectory the detector finds, color-coded by whether it passed the
/// filters or why it was dropped — and tune those filters live. No scoring, no cooldown; it just tracks.
struct TestingView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraController()

    @State private var minMotion = 0.03
    @State private var minConf = 0.3
    @State private var motionMask = false
    @State private var colorGate = true

    var body: some View {
        ZStack {
            CameraPreview(session: camera.session).ignoresSafeArea()

            // Every detected trajectory, colored by verdict.
            GeometryReader { geo in
                ForEach(camera.debugTrajectories) { t in
                    DebugTrajectoryShape(points: t.points, size: geo.size)
                        .stroke(color(for: t.verdict),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()

            VStack {
                header
                Spacer()
                panel
            }
            .padding()

            if camera.permissionDenied {
                Text("Camera access needed — enable it in Settings.")
                    .font(.headline).foregroundStyle(.white)
                    .padding().background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .onAppear {
            camera.ballProfile = app.ballProfile   // color gate uses the calibrated ball
            camera.setDebugMode(true)
            pushParams()
            camera.start()
        }
        .onDisappear { camera.stop() }
    }

    // MARK: Pieces

    private var header: some View {
        let total = camera.debugTrajectories.count
        let passing = camera.debugTrajectories.filter { $0.verdict == .accepted }.count
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TESTING").font(.caption.bold()).tracking(1).foregroundStyle(.green)
                Text("\(total) detected · \(passing) passing")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.white)
            }
            .padding(10)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent).tint(.white)
        }
    }

    private var panel: some View {
        VStack(spacing: 12) {
            legend
            slider("Min motion", $minMotion, 0...0.30, "%.2f") { camera.setMinMotion($0) }
            slider("Min confidence", $minConf, 0...1, "%.2f") { camera.setMinConfidence($0) }
            HStack(spacing: 20) {
                Toggle("Motion mask", isOn: $motionMask)
                    .onChange(of: motionMask) { _, v in camera.setMotionMask(v) }
                Toggle("Color gate", isOn: $colorGate)
                    .onChange(of: colorGate) { _, v in camera.setColorGate(v) }
            }
            .font(.caption).tint(.green).foregroundStyle(.white)
            Text(app.isBallCalibrated ? "Tip: green = would be scored. Loosen until real shots turn green."
                                      : "No ball calibrated — the color gate has no effect until you calibrate.")
                .font(.caption2).foregroundStyle(.white.opacity(0.65))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendDot(.green, "pass")
            legendDot(.gray, "no motion")
            legendDot(.orange, "wrong color")
            legendDot(.red, "low conf")
        }
        .font(.caption2).foregroundStyle(.white.opacity(0.85))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legendDot(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 8, height: 8); Text(t) }
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        _ fmt: String, onEdit: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.85))
                .frame(width: 120, alignment: .leading)
            Slider(value: value, in: range).tint(.green)
                .onChange(of: value.wrappedValue) { _, v in onEdit(v) }
            Text(String(format: fmt, value.wrappedValue))
                .font(.caption.monospacedDigit()).foregroundStyle(.white)
                .frame(width: 46, alignment: .trailing)
        }
    }

    private func pushParams() {
        camera.setMinMotion(minMotion)
        camera.setMinConfidence(minConf)
        camera.setMotionMask(motionMask)
        camera.setColorGate(colorGate)
    }

    private func color(for v: DebugTrajectory.Verdict) -> Color {
        switch v {
        case .accepted: return .green
        case .tooLittleMotion: return .gray
        case .wrongColor: return .orange
        case .lowConfidence: return .red
        }
    }
}

/// Draws a normalized trajectory (Vision origin bottom-left → SwiftUI top-left).
private struct DebugTrajectoryShape: Shape {
    let points: [CGPoint]
    let size: CGSize
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        let mapped = points.map { CGPoint(x: $0.x * size.width, y: (1 - $0.y) * size.height) }
        path.move(to: mapped[0])
        for p in mapped.dropFirst() { path.addLine(to: p) }
        return path
    }
}
