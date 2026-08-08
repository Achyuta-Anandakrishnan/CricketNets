import SwiftUI

/// A diagnostic view for the fast 2D path: see what the colour detector finds, frame by frame, and
/// tune it live. No scoring, no cooldown; it just tracks.
///
/// It answers the questions in the order they can fail. Is the ball found at all? Is it being
/// *followed* between frames, or re-scanned from scratch every time? Is anything moving fast enough
/// to count as a shot? The counters are cumulative, so this is the screen to watch while someone
/// actually hits a few — a number that stops climbing names the stage that's broken.
struct TestingView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraController()

    @State private var tolerance = 1.0
    @State private var shotSpeed = 4.0

    var body: some View {
        ZStack {
            CameraPreview(session: camera.session).ignoresSafeArea()
            BallOverlay(detection: camera.detection,
                        trail: camera.trail,
                        followed: camera.wasFollowed,
                        bufferSize: camera.frameSize)

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
            // No scoring handler: this screen tracks without recording or cooling down.
            camera.ballProfile = app.ballProfile
            camera.calibration = app.calibration
            camera.colourTolerance = tolerance
            camera.minShotSpeed = shotSpeed
            camera.start()
        }
        .onDisappear { camera.stop() }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("TESTING · FAST 2D").font(.caption.bold()).tracking(1).foregroundStyle(.green)

                if let d = camera.detection {
                    Text(camera.wasFollowed ? "FOLLOWING" : (d.looksLikeABall ? "FOUND" : "TOO BROAD"))
                        .font(.title3.bold())
                        .foregroundStyle(camera.wasFollowed || d.looksLikeABall ? .green : .orange)
                    Text("\(d.pixelCount) px blob · \(Int(d.frameCoverage * 100))% of frame")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.white)
                } else {
                    Text(app.isBallCalibrated ? "NOT FOUND" : "NO BALL CALIBRATED")
                        .font(.title3.bold()).foregroundStyle(.orange)
                    Text(app.isBallCalibrated
                         ? "Nothing matches the calibrated colour."
                         : "Colour tracking has nothing to look for — calibrate the ball first.")
                        .font(.caption2).foregroundStyle(.orange.opacity(0.9))
                }

                funnelReadout
                BallSwatch(profile: app.ballProfile, showValues: true).padding(.top, 2)
            }
            .padding(10)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))

            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent).tint(.white)
        }
    }

    /// The funnel, in the order frames are lost. `% followed` is the one that matters most: low
    /// means every frame is an independent strict scan of a blurred target, which is the failure
    /// mode that starves a shot of samples.
    private var funnelReadout: some View {
        let f = camera.funnel
        return VStack(alignment: .leading, spacing: 1) {
            Text("\(f.ballSeen)/\(f.framesSeen) frames saw the ball (\(Int(f.seenShare * 100))%)")
                .foregroundStyle(.white.opacity(0.75))
            Text("\(Int(f.followedShare * 100))% followed, not re-scanned")
                .foregroundStyle(f.followedShare > 0.6 ? .green : .orange)
            if f.tooBroad > 0 {
                Text("\(f.tooBroad) too broad — colour too loose")
                    .foregroundStyle(.orange.opacity(0.9))
            }
            Text(camera.hasTrajectory
                 ? String(format: "SHOT · %.0f km/h", camera.speedKmh)
                 : String(format: "last gap: %.0f km/h", camera.speedKmh))
                .foregroundStyle(camera.hasTrajectory ? .green : .white.opacity(0.6))
        }
        .font(.system(size: 10).monospacedDigit())
    }

    private var panel: some View {
        VStack(spacing: 12) {
            TunableSlider(
                title: "How fussy about colour",
                value: $tolerance,
                range: 0.5...8,
                reading: TuningWords.colourStrictness,
                guidance: "Right = accepts more shades, so it finds the ball more easily but may grab other things too.",
                onEdit: { camera.colourTolerance = $0 }
            )
            TunableSlider(
                title: "How hard a hit counts as a shot",
                value: $shotSpeed,
                range: 0...20,
                reading: TuningWords.shotSpeed,
                guidance: "Left = records gentle pushes too, along with the ball being carried back.",
                onEdit: { camera.minShotSpeed = $0 }
            )
            Text(app.isCalibrated
                 ? "Speeds use the \(app.calibration.source.rawValue) distance calibration."
                 : "No distance calibration — speeds are rough, so the shot gate is rough too.")
                .font(.caption2).foregroundStyle(app.isCalibrated ? .white.opacity(0.65) : .orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Reset counts") { camera.resetCounters() }
                .font(.caption2).buttonStyle(.bordered).tint(.white)
        }
        .padding()
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
    }
}
