import SwiftUI
import AVFoundation

/// Which tracker is driving the Nets tab. They can't run at once — ARKit's scene depth caps the
/// camera around 60fps, so the fast path gives up depth to get frames and the depth path gives up
/// frames to get depth.
enum TrackingMode: String, CaseIterable, Identifiable {
    case fast, depth
    var id: String { rawValue }
    var label: String { self == .fast ? "Fast (2D)" : "3D (LiDAR)" }
    var blurb: String {
        switch self {
        case .fast:  return "120 fps. Best speed accuracy. Can't see left/right."
        case .depth: return "~60 fps. Measures left/right for real. Needs the ball within 5 m."
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @State private var mode: TrackingMode = .fast

    var body: some View {
        switch mode {
        case .fast:  FastNetsView(mode: $mode)
        case .depth: DepthNetsView(mode: $mode)
        }
    }
}

/// The 120fps AVFoundation path: best speed reading, no azimuth.
struct FastNetsView: View {
    @EnvironmentObject var app: AppState
    @Binding var mode: TrackingMode
    @StateObject private var camera = CameraController()
    @State private var matchRunning = false
    @State private var showCalibration = false
    @State private var showBallCalibration = false
    @State private var showTesting = false

    var body: some View {
        ZStack {
            if matchRunning {
                CameraPreview(session: camera.session).ignoresSafeArea()
                BallOverlay(detection: camera.detection,
                            trail: camera.trail,
                            followed: camera.wasFollowed,
                            bufferSize: camera.frameSize)
            } else {
                idleBackground
            }

            VStack(spacing: 0) {
                if matchRunning { topHUD }
                Spacer()
                if matchRunning, let shot = app.lastShot {
                    ResultBanner(shot: shot, hand: app.hand)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                bottomControls
            }

            if matchRunning && camera.cooldownRemaining > 0 { cooldownOverlay }

            if camera.permissionDenied { permissionOverlay }
        }
        .animation(.easeInOut(duration: 0.2), value: camera.cooldownRemaining)
        .onAppear {
            camera.onShotCompleted = { [weak app] samples in app?.record(planeSamples: samples) }
            camera.ballProfile = app.ballProfile
            camera.calibration = app.calibration
            if matchRunning { camera.start() }
        }
        .onChange(of: app.calibration) { _, new in camera.calibration = new }
        .onChange(of: app.ballProfile) { _, new in camera.ballProfile = new }
        .onDisappear { camera.stop() }
        // LiDAR needs the back camera to itself, so pause capture while the Depth sheet is up.
        .sheet(isPresented: $showCalibration, onDismiss: { if matchRunning { camera.start() } }) {
            CalibrationView()
        }
        // Ball calibration needs a live frame, so run the camera while its sheet is open.
        .sheet(isPresented: $showBallCalibration, onDismiss: { if !matchRunning { camera.stop() } }) {
            BallCalibrationView(camera: camera).onAppear { camera.start() }
        }
        .fullScreenCover(isPresented: $showTesting) {
            TestingView().environmentObject(app)
        }
    }

    private var cooldownOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 8) {
                if let shot = app.lastShot {
                    Text(shot.outcome.label)
                        .font(.title2.bold())
                        .foregroundStyle(shot.outcome.isWicket ? .red : .green)
                }
                Text("\(camera.cooldownRemaining)")
                    .font(.system(size: 110, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .monospacedDigit()
                Text("get ready for the next ball")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.8))
                Button("Skip") { camera.armNow() }
                    .buttonStyle(.borderedProminent).tint(.green)
                    .padding(.top, 10)
            }
        }
        .transition(.opacity)
    }

    private func startMatch() {
        camera.ballProfile = app.ballProfile
        camera.calibration = app.calibration
        matchRunning = true
        camera.start()
    }

    private func endMatch() {
        matchRunning = false
        camera.stop()
    }

    private var idleBackground: some View {
        LinearGradient(colors: [Color(red: 0.04, green: 0.1, blue: 0.07), .black],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .overlay(
                VStack(spacing: 10) {
                    Image(systemName: "figure.cricket").font(.system(size: 48))
                        .foregroundStyle(.green.opacity(0.85))
                    Text("Ready for the nets").font(.title3.bold()).foregroundStyle(.white)
                    Text("Calibrate the ball, then start a match.")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.6))
                    VersionBadge().padding(.top, 6)
                }
            )
    }

    private var bottomControls: some View {
        VStack(spacing: 12) {
            if matchRunning {
                Button(action: endMatch) {
                    Label("End match", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
            } else {
                ModePicker(mode: $mode)
                calibrationBar
                Button(action: startMatch) {
                    Label("Start match", systemImage: "play.fill")
                        .frame(maxWidth: .infinity).font(.headline)
                }
                .buttonStyle(.borderedProminent).tint(.green).controlSize(.large)
                .disabled(camera.permissionDenied)

                Button { showTesting = true } label: {
                    Label("Testing mode", systemImage: "scope").font(.caption)
                }
                .tint(.white)
            }
        }
        .padding()
        .background(.black.opacity(0.45))
    }

    /// Live speed + the shot map, side by side. The mini field is the reason to keep your eyes here
    /// rather than switching to the Stats tab between balls.
    private var topHUD: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 12) {
                MetricPill(value: "\(Int(camera.speedKmh))",
                           label: "km/h",
                           accent: .white,
                           caveat: app.isCalibrated ? nil : "uncalibrated")
                if let shot = app.lastShot {
                    MetricPill(value: "\(Int(shot.launchAngleDeg))°", label: "launch", accent: .green)
                }
            }
            .padding(12)
            .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                TrackingBadge(state: badgeState)
                MiniField(field: app.field, lastShot: app.lastShot, liveAzimuth: nil)
                    .frame(width: 108, height: 108)
                    .background(.black.opacity(0.35), in: Circle())
                // Fast mode can't see left/right, so say so next to the map that implies it can.
                Text("2D — direction not measured")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange.opacity(0.85))
            }
        }
        .padding()
    }

    private var badgeState: TrackingBadge.State {
        if camera.cooldownRemaining > 0 { return .cooldown(camera.cooldownRemaining) }
        return camera.hasTrajectory ? .tracking : .ready
    }

    private var calibrationBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                BallSwatch(profile: app.ballProfile, size: 16)
                StatusRow(ok: app.isBallCalibrated,
                          text: app.isBallCalibrated ? "Tracking the ball's colour"
                                                     : "No ball colour — nothing will be tracked",
                          button: "Ball") { showBallCalibration = true }
            }

            StatusRow(ok: app.isCalibrated,
                      text: app.isCalibrated ? "Distance set (\(app.calibration.source.rawValue))"
                                             : "No distance — speeds are rough",
                      button: "Depth") { camera.stop(); showCalibration = true }
        }
    }

    private var permissionOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill").font(.largeTitle)
            Text("Camera access needed")
                .font(.headline)
            Text("Enable it in Settings › CricketNets to track the ball.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(40)
    }
}

/// Maps a normalized capture-buffer point (top-left origin) onto the preview.
///
/// The preview draws with `resizeAspectFill`, which scales the buffer to cover the view and crops
/// the overflow. Multiplying a normalized point by the view's size ignores that crop, so an overlay
/// drifts further from the thing it's tracking the nearer the edge it gets — most visible exactly
/// where a shot leaves the frame.
struct PreviewMapping {
    let bufferSize: CGSize
    let viewSize: CGSize

    private var scale: CGFloat {
        guard bufferSize.width > 0, bufferSize.height > 0 else { return 1 }
        return max(viewSize.width / bufferSize.width, viewSize.height / bufferSize.height)
    }

    func point(_ p: CGPoint) -> CGPoint {
        let filled = CGSize(width: bufferSize.width * scale, height: bufferSize.height * scale)
        return CGPoint(x: (viewSize.width - filled.width) / 2 + p.x * filled.width,
                       y: (viewSize.height - filled.height) / 2 + p.y * filled.height)
    }

    /// A length given as a fraction of the buffer's WIDTH (the units `radiusNormalized` uses).
    func length(_ fractionOfWidth: Double) -> CGFloat {
        fractionOfWidth * bufferSize.width * scale
    }
}

/// A ring where the ball was found, trailing the sightings that led to it.
///
/// The trail replaces the parabola the Vision path used to draw. It's the honest version of the same
/// picture: these are the frames the ball was actually seen in, so gaps in it are gaps in the data.
struct BallOverlay: View {
    let detection: BallDetector.Detection?
    let trail: [CGPoint]
    let followed: Bool
    let bufferSize: CGSize

    var body: some View {
        GeometryReader { geo in
            let map = PreviewMapping(bufferSize: bufferSize, viewSize: geo.size)
            ZStack {
                if trail.count > 1 {
                    Path { path in
                        let points = trail.map(map.point)
                        path.move(to: points[0])
                        for p in points.dropFirst() { path.addLine(to: p) }
                    }
                    .stroke(Color.green.opacity(0.8),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .shadow(color: .green.opacity(0.7), radius: 6)
                }
                if let detection {
                    let radius = max(14, map.length(detection.radiusNormalized))
                    Circle()
                        .stroke(followed ? Color.green : Color.cyan, lineWidth: 3)
                        .frame(width: radius * 2, height: radius * 2)
                        .position(map.point(detection.center))
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// Bridges AVCaptureVideoPreviewLayer into SwiftUI.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
