import SwiftUI
import AVFoundation

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var camera = CameraController()
    @State private var matchRunning = false
    @State private var showCalibration = false
    @State private var showBallCalibration = false
    @State private var showTesting = false

    var body: some View {
        ZStack {
            if matchRunning {
                CameraPreview(session: camera.session).ignoresSafeArea()
                GeometryReader { geo in
                    TrajectoryPath(points: camera.trajectoryPoints, size: geo.size)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                        .shadow(color: .green.opacity(0.8), radius: 6)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            } else {
                idleBackground
            }

            VStack {
                if matchRunning {
                    HStack { speedBadge; Spacer(); trackingBadge }.padding()
                }
                Spacer()
                if matchRunning, let shot = app.lastShot {
                    resultBanner(shot)
                }
                bottomControls
            }

            if matchRunning && camera.cooldownRemaining > 0 { cooldownOverlay }

            if camera.permissionDenied { permissionOverlay }
        }
        .animation(.easeInOut(duration: 0.2), value: camera.cooldownRemaining)
        .onAppear {
            camera.onShotCompleted = { [weak app] points in app?.record(imagePoints: points) }
            camera.ballProfile = app.ballProfile
            if matchRunning { camera.start() }
        }
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

    private func resultBanner(_ shot: ScoreResult) -> some View {
        VStack(spacing: 4) {
            Text(shot.outcome.label)
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundStyle(shot.outcome.isWicket ? .red : .white)
            Text(shot.commentary)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(.black.opacity(0.5))
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring, value: shot)
    }

    private var calibrationBar: some View {
        VStack(spacing: 8) {
            statusRow(
                ok: app.isBallCalibrated,
                onText: "Tracking the ball only",
                offText: "Tracking everything — calibrate the ball",
                button: "Ball"
            ) { showBallCalibration = true }

            statusRow(
                ok: app.isCalibrated,
                onText: "Distance set (\(app.calibration.source.rawValue))",
                offText: "No distance — speeds are rough",
                button: "Depth"
            ) { camera.stop(); showCalibration = true }
        }
    }

    private func statusRow(ok: Bool, onText: String, offText: String,
                           button: String, action: @escaping () -> Void) -> some View {
        HStack {
            Circle().fill(ok ? .green : .orange).frame(width: 8, height: 8)
            Text(ok ? onText : offText)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Button(button, action: action)
                .font(.caption.bold())
                .buttonStyle(.borderedProminent)
                .tint(.green)
        }
    }

    private var speedBadge: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(Int(camera.speedKmh))")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            Text(app.isCalibrated ? "km/h" : "km/h (uncalibrated)")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }

    private var trackingBadge: some View {
        Group {
            if camera.cooldownRemaining > 0 {
                Text("NEXT BALL IN \(camera.cooldownRemaining)s")
                    .foregroundStyle(.orange)
            } else if camera.hasTrajectory {
                Text("● TRACKING").foregroundStyle(.green)
            } else {
                Text("○ READY").foregroundStyle(.white.opacity(0.6))
            }
        }
        .font(.caption.bold())
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.black.opacity(0.4), in: Capsule())
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

/// Draws the trajectory. Vision points are normalized with origin at BOTTOM-left;
/// SwiftUI's origin is TOP-left, so y is flipped here.
private struct TrajectoryPath: Shape {
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
