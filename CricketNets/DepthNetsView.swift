import SwiftUI
import ARKit
import simd

/// The 3D (LiDAR) tracking screen — the mode where left/right is measured rather than assumed.
///
/// It deliberately shows more than the fast mode does, because the depth path has more that can go
/// wrong: if LiDAR isn't reaching the ball you want to know *now*, not after a session of shots
/// that silently never scored. Hence the resolve rate and distance readout alongside the metrics.
struct DepthNetsView: View {
    @EnvironmentObject var app: AppState
    @Binding var mode: TrackingMode
    @StateObject private var tracker = DepthTrajectoryTracker()

    @State private var running = false
    @State private var showTesting = false

    var body: some View {
        ZStack {
            if tracker.isSupported && running {
                ARPreview(session: tracker.session).ignoresSafeArea()
            } else {
                idleBackground
            }

            VStack(spacing: 0) {
                if running { topHUD }
                Spacer()
                if running, let shot = app.lastShot {
                    ResultBanner(shot: shot, hand: app.hand)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                controls
            }
        }
        .animation(.spring(duration: 0.3), value: app.lastShot)
        .onAppear {
            tracker.setBallProfile(app.ballProfile)
            tracker.onShotCompleted = { [weak app] samples, ground in
                app?.record(worldSamples: samples, groundDirection: ground)
            }
        }
        .onDisappear { stop() }
        // The testing screen runs its own ARSession, so this one has to let go of the camera.
        .fullScreenCover(isPresented: $showTesting, onDismiss: { if running { tracker.start() } }) {
            DepthTestingView().environmentObject(app)
        }
        .onChange(of: showTesting) { _, shown in if shown { tracker.stop() } }
    }

    /// Where the phone is standing, settable before starting — the fine-tuning lives in testing mode.
    private var placementSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Placement", selection: $app.phonePlacement) {
                ForEach(PhonePlacement.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("\(app.phonePlacement.blurb) Offset \(Int(app.groundOffsetDeg))°.")
                .font(.caption2).foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Live HUD

    private var topHUD: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top) {
                metrics
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    TrackingBadge(state: badgeState)
                    MiniField(field: app.field, lastShot: app.lastShot, liveAzimuth: nil)
                        .frame(width: 108, height: 108)
                        .background(.black.opacity(0.35), in: Circle())
                }
            }
            depthStatus
        }
        .padding()
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 12) {
            MetricPill(value: app.lastShot.map { "\(Int($0.speedKmh))" } ?? "—",
                       label: "km/h",
                       accent: .white)
            HStack(spacing: 18) {
                MetricPill(value: app.lastShot.map { "\(Int($0.launchAngleDeg))°" } ?? "—",
                           label: "launch",
                           accent: .green)
                MetricPill(value: azimuthValue,
                           label: "direction",
                           accent: .cyan)
            }
        }
        .padding(12)
        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }

    private var azimuthValue: String {
        guard let shot = app.lastShot else { return "—" }
        let deg = atan2(shot.landing.x, shot.landing.y) * 180 / .pi
        return AzimuthLabel.text(azimuthDeg: deg, hand: app.hand)
    }

    /// The honest health check for this mode: is LiDAR actually seeing the ball?
    private var depthStatus: some View {
        HStack(spacing: 12) {
            Label {
                Text(tracker.depthQuality.rawValue)
            } icon: {
                Image(systemName: tracker.depthQuality == .good ? "sensor.fill" : "sensor")
            }
            .font(.caption.bold())
            .foregroundStyle(tracker.depthQuality == .good ? .green : .orange)

            if tracker.lastBallDistance > 0 {
                Text(String(format: "%.1f m", tracker.lastBallDistance))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer()

            // Resolve rate makes the mode's main weakness visible instead of mysterious.
            Text("\(tracker.pointsResolved)/\(tracker.framesSeen) frames")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.black.opacity(0.4), in: Capsule())
    }

    private var badgeState: TrackingBadge.State {
        if !tracker.hasGroundDirection { return .blocked("aim first") }
        if tracker.isTracking { return .tracking }
        return .ready
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 12) {
            if running {
                if !tracker.hasGroundDirection {
                    aimPrompt
                }
                HStack(spacing: 12) {
                    Button {
                        tracker.captureGroundDirection(offsetDegrees: app.groundOffsetDeg)
                    } label: {
                        Label(tracker.hasGroundDirection ? "Re-aim" : "Set direction",
                              systemImage: "location.north.line.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).tint(.white).controlSize(.large)

                    Button(action: stop) {
                        Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                }
            } else {
                ModePicker(mode: $mode)
                placementSummary
                Button(action: start) {
                    Label("Start 3D tracking", systemImage: "cube.transparent")
                        .frame(maxWidth: .infinity).font(.headline)
                }
                .buttonStyle(.borderedProminent).tint(.green).controlSize(.large)
                .disabled(!tracker.isSupported)

                Button { showTesting = true } label: {
                    Label("3D testing mode", systemImage: "scope").font(.caption)
                }
                .tint(.white)
                .disabled(!tracker.isSupported)
            }
        }
        .padding()
        .background(.black.opacity(0.45))
    }

    /// Azimuth is measured from wherever the user says "down the ground" is, so this step isn't
    /// optional — without it left/right is relative to an arbitrary world axis.
    private var aimPrompt: some View {
        Text("Point the phone straight down the ground and tap **Set direction** — every shot's left/right is measured from there.")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.green.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
    }

    private var idleBackground: some View {
        LinearGradient(colors: [Color(red: 0.05, green: 0.08, blue: 0.13), .black],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .overlay(
                VStack(spacing: 12) {
                    Image(systemName: tracker.isSupported ? "cube.transparent" : "exclamationmark.triangle")
                        .font(.system(size: 44))
                        .foregroundStyle(tracker.isSupported ? .cyan.opacity(0.85) : .orange)
                    Text(tracker.isSupported ? "3D tracking" : "LiDAR unavailable")
                        .font(.title3.bold()).foregroundStyle(.white)
                    Text(tracker.isSupported
                         ? "Measures left/right for real, using LiDAR depth.\nStand the phone within 5 m of the batter."
                         : "This device has no scene-depth sensor. Use the fast 2D mode instead.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 40)
                    VersionBadge().padding(.top, 6)
                }
            )
    }

    // MARK: Actions

    private func start() {
        tracker.setBallProfile(app.ballProfile)
        running = true
        tracker.start()
    }

    private func stop() {
        running = false
        tracker.stop()
    }
}
