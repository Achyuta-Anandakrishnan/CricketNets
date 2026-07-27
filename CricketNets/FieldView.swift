import SwiftUI

/// One place for outcome colors, shared by the field view and the wagon wheel.
extension ScoreResult.Outcome {
    var color: Color {
        switch self {
        case .six: return .purple
        case .four: return .blue
        case .caught: return .red
        case .runs(0): return .gray
        case .runs: return .orange
        }
    }
}

/// Top-down cricket field. Drag fielders to set your field; the last shot's landing point
/// and flight line are drawn on top. Striker sits at the centre; +y (down the ground) is up.
struct FieldView: View {
    @Binding var field: Field
    var lastResult: ScoreResult?

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let scale = (side / 2) / CGFloat(field.boundaryRadius)   // points per meter

            ZStack {
                boundaryAndPitch(center: center, side: side)

                // Shot line + landing marker
                if let r = lastResult {
                    let land = toView(r.landing, center: center, scale: scale)
                    Path { p in p.move(to: center); p.addLine(to: land) }
                        .stroke(shotColor(r).opacity(0.7), style: StrokeStyle(lineWidth: 3, dash: [6, 4]))
                    Circle()
                        .fill(shotColor(r))
                        .frame(width: 16, height: 16)
                        .position(land)
                        .shadow(color: shotColor(r), radius: 6)
                }

                // Fielders (draggable). The drag must report in the FIELD's coordinate space, not
                // the chip's local space — otherwise the fielder jumps toward the centre on every drag.
                ForEach($field.fielders) { $fielder in
                    FielderChip(fielder: fielder)
                        .position(toView(fielder.position, center: center, scale: scale))
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("field"))
                                .onChanged { value in
                                    fielder.position = clampToField(
                                        toMeters(value.location, center: center, scale: scale)
                                    )
                                }
                        )
                }

                // Striker marker
                Circle().fill(.white).frame(width: 8, height: 8).position(center)
            }
            .coordinateSpace(name: "field")
        }
    }

    /// Keep a dragged fielder just inside the boundary rope.
    private func clampToField(_ m: CGPoint) -> CGPoint {
        let dist = hypot(m.x, m.y)
        let maxR = CGFloat(field.boundaryRadius) - 1
        guard dist > maxR else { return m }
        return CGPoint(x: m.x / dist * maxR, y: m.y / dist * maxR)
    }

    // MARK: Drawing

    private func boundaryAndPitch(center: CGPoint, side: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Color.green.opacity(0.18))
                .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 2))
                .frame(width: side, height: side)
                .position(center)
            // 30-yard (~13.7 m) inner ring
            Circle()
                .stroke(.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .frame(width: side * CGFloat(13.7 / field.boundaryRadius), height: side * CGFloat(13.7 / field.boundaryRadius))
                .position(center)
            // Pitch strip
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(red: 0.82, green: 0.71, blue: 0.55))
                .frame(width: side * 0.05, height: side * CGFloat(min(20.12, field.boundaryRadius) / field.boundaryRadius))
                .position(x: center.x, y: center.y - side * CGFloat(10 / field.boundaryRadius))
        }
    }

    private func shotColor(_ r: ScoreResult) -> Color { r.outcome.color }

    // MARK: Coordinate mapping (meters ↔ view points). +y is up on screen.

    private func toView(_ m: CGPoint, center: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: center.x + m.x * scale, y: center.y - m.y * scale)
    }
    private func toMeters(_ v: CGPoint, center: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: (v.x - center.x) / scale, y: (center.y - v.y) / scale)
    }
}

private struct FielderChip: View {
    let fielder: Fielder
    var body: some View {
        VStack(spacing: 2) {
            Circle()
                .fill(fielder.isKeeper ? Color.yellow : Color.orange)
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
            Text(fielder.name)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize()
        }
    }
}

/// Standalone screen to exercise the field + scoring engine WITHOUT the camera — runs in the
/// Simulator. Drag the fielders, dial in a shot, and see how it's scored.
struct ScoringDemoView: View {
    @EnvironmentObject var app: AppState
    @State private var speedKmh: Double = 90
    @State private var elevationDeg: Double = 20
    @State private var azimuthDeg: Double = 40
    @State private var result: ScoreResult?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                FieldView(field: $app.field, lastResult: result)
                    .aspectRatio(1, contentMode: .fit)

                if let r = result {
                    VStack(spacing: 2) {
                        Text(r.outcome.label).font(.title3.bold())
                            .foregroundStyle(r.outcome.isWicket ? .red : .white)
                        Text(r.commentary).font(.caption).foregroundStyle(.secondary)
                    }
                }

                fieldSetup
                conditions
                testShot
            }
            .padding()
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear(perform: preview)
        .onChange(of: [speedKmh, elevationDeg, azimuthDeg]) { _, _ in preview() }
        .onChange(of: app.field) { _, _ in preview() }
        .onChange(of: app.scoringParams) { _, _ in preview() }
    }

    // MARK: Sections

    private var fieldSetup: some View {
        card("Field setup") {
            Picker("Field", selection: $app.preset) {
                ForEach(Field.Preset.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: app.preset) { _, _ in app.applyPreset() }

            HStack {
                Picker("Hand", selection: $app.hand) {
                    Text("Right").tag(Field.Hand.right)
                    Text("Left").tag(Field.Hand.left)
                }
                .pickerStyle(.segmented)
                .onChange(of: app.hand) { _, _ in app.applyPreset() }

                Button("Reset") { app.applyPreset() }
                    .buttonStyle(.bordered).tint(.white)
            }

            slider("Boundary", boundaryBinding, 50...85, "m")
        }
    }

    private var conditions: some View {
        card("Match conditions") {
            slider("Outfield pace", paceBinding, 0...1, "", asPercent: true)
            slider("Catching", catchingBinding, 0...1, "", asPercent: true)
            Text("Faster outfield → more boundaries. Higher catching → skiers carry to hands.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var testShot: some View {
        card("Test a shot") {
            slider("Speed", $speedKmh, 20...160, "km/h")
            slider("Launch angle", $elevationDeg, 0...80, "°")
            slider("Azimuth", $azimuthDeg, -120...120, "°")
            Button("Record shot") { record() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: Helpers

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold)).tracking(0.8)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        _ unit: String, asPercent: Bool = false) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Slider(value: value, in: range)
            Text(asPercent ? "\(Int(value.wrappedValue * 100))%" : "\(Int(value.wrappedValue))\(unit)")
                .font(.caption.monospacedDigit()).foregroundStyle(.white).frame(width: 52, alignment: .trailing)
        }
    }

    // Bindings that map friendly 0…1 controls onto the physics params.
    private var boundaryBinding: Binding<Double> {
        Binding(get: { app.field.boundaryRadius }, set: { app.setBoundary($0) })
    }
    private var paceBinding: Binding<Double> {
        Binding(get: { (9 - app.scoringParams.rollDecel) / 5 },
                set: { app.scoringParams.rollDecel = 9 - $0 * 5 })
    }
    private var catchingBinding: Binding<Double> {
        Binding(get: { (app.scoringParams.catchRunFactor - 1.5) / 2 },
                set: { app.scoringParams.catchRunFactor = 1.5 + $0 * 2 })
    }

    private func makeLaunch() -> LaunchVector {
        LaunchVector(speed: speedKmh / 3.6,
                     elevation: elevationDeg * .pi / 180,
                     azimuth: azimuthDeg * .pi / 180,
                     height: 1.0)
    }

    private func preview() {
        result = ScoringEngine.evaluate(launch: makeLaunch(), field: app.field, params: app.scoringParams)
    }

    private func record() {
        app.record(launch: makeLaunch())
        result = app.lastShot
    }
}

#Preview {
    ScoringDemoView()
        .environmentObject(AppState())
        .preferredColorScheme(.dark)
}
