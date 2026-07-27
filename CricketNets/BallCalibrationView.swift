import SwiftUI

/// Teach the app what the ball looks like: hold the ball inside the ring, capture its color, and
/// from then on the tracker ignores anything that isn't that color.
struct BallCalibrationView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var camera: CameraController
    @Environment(\.dismiss) private var dismiss

    @State private var captured: BallProfile?
    @State private var note: String?

    private let reticlePt: CGFloat = 130

    var body: some View {
        ZStack {
            CameraPreview(session: camera.session).ignoresSafeArea()

            // Aiming ring
            Circle()
                .strokeBorder(captured == nil ? Color.green : Color.white, lineWidth: 3)
                .frame(width: reticlePt, height: reticlePt)

            VStack {
                header
                Spacer()
                controls
            }
            .padding()
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text(captured == nil ? "Hold the ball inside the ring" : "Captured — does this look right?")
                .font(.headline)
                .foregroundStyle(.white)
            if let c = captured {
                let rgb = c.displayRGB
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color(red: rgb.0, green: rgb.1, blue: rgb.2))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().stroke(.white, lineWidth: 1))
                    Text("ball color")
                        .font(.caption).foregroundStyle(.white.opacity(0.8))
                }
            } else {
                Text(note ?? "Fill the ring, keep it lit, then Capture.")
                    .font(.caption)
                    .foregroundStyle(note == nil ? .white.opacity(0.7) : .orange)
            }
        }
        .padding()
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button("Cancel") { dismiss() }
                .buttonStyle(.bordered).tint(.white)

            if captured == nil {
                Button("Capture") {
                    if let profile = camera.sampleBallColor() {
                        captured = profile
                        note = nil
                    } else {
                        note = "No camera frame yet — hold steady and try again."
                    }
                }
                .buttonStyle(.borderedProminent).tint(.green)
            } else {
                Button("Retake") { captured = nil }
                    .buttonStyle(.bordered).tint(.white)
                Button("Use this ball") { apply() }
                    .buttonStyle(.borderedProminent).tint(.green)
            }
        }
        .padding()
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
    }

    private func apply() {
        guard let captured else { return }
        app.ballProfile = captured
        camera.ballProfile = captured
        dismiss()
    }
}
