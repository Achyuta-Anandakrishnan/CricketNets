import SwiftUI

/// Aggregate numbers for a net session, derived from the scored shots.
struct SessionStats {
    var balls = 0
    var runs = 0
    var fours = 0
    var sixes = 0
    var dots = 0
    var wickets = 0
    var fastestKmh = 0.0

    var strikeRate: Double { balls == 0 ? 0 : Double(runs) / Double(balls) * 100 }
    var boundaryPercent: Double { balls == 0 ? 0 : Double(fours + sixes) / Double(balls) * 100 }

    init(shots: [ScoreResult]) {
        for s in shots {
            balls += 1
            runs += s.outcome.runsScored
            fastestKmh = max(fastestKmh, s.speedKmh)
            switch s.outcome {
            case .four: fours += 1
            case .six: sixes += 1
            case .caught: wickets += 1
            case .runs(0): dots += 1
            case .runs: break
            }
        }
    }
}

struct StatsView: View {
    @EnvironmentObject var app: AppState

    private var stats: SessionStats { SessionStats(shots: app.shots) }

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header

                WagonWheel(shots: app.shots, boundaryRadius: app.field.boundaryRadius)
                    .aspectRatio(1, contentMode: .fit)
                    .padding(.horizontal)

                legend

                LazyVGrid(columns: columns, spacing: 12) {
                    tile("Runs", "\(stats.runs)", .white)
                    tile("Balls", "\(stats.balls)", .white)
                    tile("Strike rate", String(format: "%.0f", stats.strikeRate), .green)
                    tile("Fours", "\(stats.fours)", .blue)
                    tile("Sixes", "\(stats.sixes)", .purple)
                    tile("Wickets", "\(stats.wickets)", .red)
                    tile("Dots", "\(stats.dots)", .gray)
                    tile("Boundary %", String(format: "%.0f", stats.boundaryPercent), .orange)
                    tile("Top speed", stats.fastestKmh > 0 ? String(format: "%.0f", stats.fastestKmh) : "—", .green)
                }
                .padding(.horizontal)

                if !app.shots.isEmpty {
                    shotList
                }
            }
            .padding(.vertical)
        }
        .background(Color.black.ignoresSafeArea())
    }

    /// Every ball this session, newest first.
    private var shotList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("BALL BY BALL")
                .font(.caption2.weight(.semibold)).tracking(0.8)
                .foregroundStyle(.secondary)
                .padding(.horizontal).padding(.bottom, 6)

            ForEach(Array(app.shots.enumerated().reversed()), id: \.offset) { index, shot in
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 28, alignment: .trailing)
                    Circle().fill(shot.outcome.color).frame(width: 9, height: 9)
                    Text(shot.outcome.label)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                    if shot.speedKmh > 0 {
                        Text("\(Int(shot.speedKmh)) km/h")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer()
                    Text(shot.outcome.runsScored > 0 ? "+\(shot.outcome.runsScored)" : (shot.outcome.isWicket ? "W" : "•"))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(shot.outcome.isWicket ? .red : .white.opacity(0.8))
                        .frame(width: 30, alignment: .trailing)
                }
                .padding(.vertical, 8).padding(.horizontal)
                .background(index % 2 == 0 ? Color.white.opacity(0.03) : .clear)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("This session")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Spacer()
            Button { app.undoLastShot() } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .font(.caption.bold())
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .disabled(app.shots.isEmpty)

            Button(role: .destructive) { app.resetSession() } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .font(.caption.bold())
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(app.shots.isEmpty)
        }
        .padding(.horizontal)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendDot(.purple, "6")
            legendDot(.blue, "4")
            legendDot(.orange, "runs")
            legendDot(.gray, "dot")
            legendDot(.red, "out")
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.7))
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }

    private func tile(_ label: String, _ value: String, _ accent: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// A shot map: lines radiating from the striker to each shot's landing point, colored by outcome.
struct WagonWheel: View {
    let shots: [ScoreResult]
    let boundaryRadius: Double

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let scale = (side / 2) / CGFloat(boundaryRadius)

            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.12))
                    .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 2))
                    .frame(width: side, height: side)
                    .position(center)
                Circle()
                    .stroke(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(width: side * CGFloat(13.7 / boundaryRadius), height: side * CGFloat(13.7 / boundaryRadius))
                    .position(center)

                Canvas { ctx, _ in
                    for shot in shots {
                        let end = CGPoint(x: center.x + shot.landing.x * scale,
                                          y: center.y - shot.landing.y * scale)
                        var line = Path()
                        line.move(to: center)
                        line.addLine(to: end)
                        let color = shot.outcome.color
                        ctx.stroke(line, with: .color(color.opacity(0.8)), lineWidth: 2)
                        ctx.fill(Path(ellipseIn: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6)),
                                 with: .color(color))
                    }
                }

                Circle().fill(.white).frame(width: 8, height: 8).position(center)

                if shots.isEmpty {
                    Text("No shots yet")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.5))
                        .position(center)
                }
            }
        }
    }
}

#Preview {
    let app = AppState()
    return StatsView().environmentObject(app).preferredColorScheme(.dark)
}
