import SwiftUI
import ARKit

/// Checks whether the tracking pipeline is actually measuring reality.
///
/// Every other screen can only tell you the app is *doing* something. None of them can tell you the
/// numbers are right, because there's no ground truth in a net — "94 km/h" is unfalsifiable without
/// a radar gun.
///
/// Gravity is the exception. A dropped ball accelerates at 9.81 m/s², always, and every stage of the
/// pipeline has to be correct for that to come out: detection must find the real ball, depth must be
/// the ball's distance rather than the background, the unprojection must be scaled right, and the
/// frame timestamps must be real. So: drop the ball a few times and read the number.
struct AccuracyTestView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var tracker = DepthTrajectoryTracker()

    struct Attempt: Identifiable {
        let id = UUID()
        let gravity: Double
        let samples: Int
        let seconds: Double

        /// How far off 9.81 this reading is, as a fraction.
        var error: Double { abs(gravity - BallPhysics.g) / BallPhysics.g }
        var isGood: Bool { error < 0.20 }
    }

    @State private var attempts: [Attempt] = []
    @State private var rejected = 0

    private var median: Double? {
        guard !attempts.isEmpty else { return nil }
        let sorted = attempts.map(\.gravity).sorted()
        return sorted[sorted.count / 2]
    }

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
            } else {
                Color.black.ignoresSafeArea()
            }

            VStack {
                header
                Spacer()
                verdictPanel
            }
            .padding()
        }
        .onAppear {
            tracker.setBallProfile(app.ballProfile)
            // A drop reaches only a few m/s, well under the threshold a struck shot needs.
            tracker.minShotSpeed = 1.5
            tracker.onShotCompleted = { samples, _ in record(samples) }
            tracker.start()
        }
        .onDisappear { tracker.stop() }
    }

    /// A fall has to last long enough to measure. Acceleration is a second derivative, so depth
    /// noise is amplified by roughly 1/T² — over a 0.2 s window a couple of centimetres of LiDAR
    /// noise throws the reading out by ~20%, while over half a second it's negligible. Rejecting
    /// short falls is what stops the screen reporting confident nonsense.
    private static let minFallSeconds = 0.35

    @State private var lastRejection: String?

    private func record(_ samples: [BallPhysics.WorldSample]) {
        guard let first = samples.first, let last = samples.last else {
            reject("no samples"); return
        }
        let duration = last.time - first.time
        guard duration >= Self.minFallSeconds else {
            reject("too short a fall — drop from higher"); return
        }
        guard let g = BallPhysics.measuredGravity(worldSamples: samples) else {
            reject("couldn't fit the fall"); return
        }
        // A drop that reads as rising, or as impossibly heavy, isn't a drop — most likely the ball
        // was carried back up or detection jumped to something else.
        guard g > 1, g < 40 else {
            reject("not a clean fall"); return
        }
        lastRejection = nil
        attempts.append(Attempt(gravity: g, samples: samples.count, seconds: duration))
    }

    private func reject(_ why: String) {
        rejected += 1
        lastRejection = why
    }

    // MARK: UI

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ACCURACY CHECK").font(.caption.bold()).tracking(1).foregroundStyle(.cyan)
            Text("Hold the ball up as high as you can and drop it. Repeat 5 times.")
                .font(.subheadline).foregroundStyle(.white)
            Text("A correct pipeline measures gravity at 9.81 m/s². Drop from high — a short fall is too noisy to measure, so the app will refuse it.")
                .font(.caption2).foregroundStyle(.white.opacity(0.65))
            HStack(spacing: 10) {
                Text(tracker.isTracking ? "● FALLING" : "○ ready")
                    .font(.caption.bold())
                    .foregroundStyle(tracker.isTracking ? .green : .white.opacity(0.6))
                Text("\(tracker.funnel.resolved) 3D points")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                if rejected > 0 {
                    Text("\(rejected) unusable")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.orange)
                }
            }
            if let lastRejection {
                Text("last attempt: \(lastRejection)")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }

    private var verdictPanel: some View {
        VStack(spacing: 12) {
            if let median {
                verdict(median)
            } else {
                Text("No drops recorded yet.")
                    .font(.callout).foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !attempts.isEmpty {
                dropList
            }

            HStack {
                Button("Clear") { attempts = []; rejected = 0 }
                    .font(.caption).buttonStyle(.bordered).tint(.white)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent).tint(.white)
            }
        }
        .padding()
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
    }

    /// The headline number, and what it means — the error size points at the stage to blame.
    private func verdict(_ g: Double) -> some View {
        let error = abs(g - BallPhysics.g) / BallPhysics.g
        let good = error < 0.20

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%.1f", g))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(good ? .green : .orange)
                    .monospacedDigit()
                Text("m/s²  vs 9.81 expected")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            Text(String(format: "%.0f%% off · median of %d drops", error * 100, attempts.count))
                .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
            Text(diagnosis(g: g, error: error))
                .font(.caption)
                .foregroundStyle(good ? .green : .orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func diagnosis(g: Double, error: Double) -> String {
        if error < 0.10 { return "Trustworthy — speeds and angles should be about right." }
        if error < 0.20 { return "Close enough to use, but expect some error in speeds." }
        if g < BallPhysics.g * 0.6 || g > BallPhysics.g * 1.6 {
            return "Scale is off by roughly \(String(format: "%.1f", g / BallPhysics.g))×. Most likely depth — check LiDAR vs ball-size distance in the ball tracker."
        }
        if g < 2 { return "Barely moving. Depth is probably locked to the background, not the ball." }
        return "Too noisy to trust. Detection is likely jumping between objects — tighten the colour tolerance."
    }

    private var dropList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(attempts.suffix(5).reversed()) { a in
                HStack(spacing: 10) {
                    Circle().fill(a.isGood ? .green : .orange).frame(width: 6, height: 6)
                    Text(String(format: "%.1f m/s²", a.gravity))
                        .font(.caption.monospacedDigit()).foregroundStyle(.white)
                    Text(String(format: "%d pts · %.2f s", a.samples, a.seconds))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
