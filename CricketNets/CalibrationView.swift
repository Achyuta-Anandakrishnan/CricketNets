import SwiftUI
import ARKit

/// LiDAR calibration step. Aim the reticle down the net at the ball's flight plane, then capture.
/// Produces a `SceneCalibration` that the fast tracker reuses for real speed + scoring.
struct CalibrationView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var lidar = LiDARCalibrator()
    @State private var cameraHeight: Double = 1.0

    var body: some View {
        ZStack {
            if lidar.isSupported {
                ARPreview(session: lidar.session).ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            // Reticle
            Image(systemName: "plus")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.green)

            VStack {
                header
                Spacer()
                controls
            }
            .padding()
        }
        .onAppear { lidar.start() }
        .onDisappear { lidar.stop() }
    }

    private var header: some View {
        VStack(spacing: 6) {
            if lidar.isSupported {
                Text(String(format: "%.2f m", lidar.centerDistance))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("distance to flight plane")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
            } else {
                Text("LiDAR unavailable — use manual reference instead")
                    .font(.callout).foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .padding().background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }

    private var controls: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Camera height").font(.caption).foregroundStyle(.white.opacity(0.8))
                Slider(value: $cameraHeight, in: 0.3...2.0)
                Text(String(format: "%.1fm", cameraHeight)).font(.caption.monospacedDigit()).foregroundStyle(.white)
            }
            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered).tint(.white)
                Button("Calibrate") { capture() }
                    .buttonStyle(.borderedProminent).tint(.green)
                    .disabled(!lidar.isSupported || lidar.centerDistance <= 0)
            }
        }
        .padding().background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }

    private func capture() {
        if let cal = lidar.makeCalibration(cameraHeight: cameraHeight, fps: 120) {
            app.calibration = cal
        }
        dismiss()
    }
}

/// Renders an ARSession so the user can aim. Shared with the 3D tracking screen.
struct ARPreview: UIViewRepresentable {
    let session: ARSession
    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        view.automaticallyUpdatesLighting = true
        return view
    }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
