import SwiftUI
import ARKit
import CoreVideo

/// Runs `BallDetector` on every ARKit frame and draws what it finds. Nothing else.
///
/// No trajectory, no parabola, no shots, no scoring, no cooldown. Just: hold the ball up, and see
/// whether the app can find it and how far away it thinks it is. Everything else in the 3D path is
/// built on this working, so it is the first thing worth proving.
@MainActor
final class BallTrackerModel: NSObject, ObservableObject, ARSessionDelegate {

    @Published var detection: BallDetector.Detection?
    @Published var lidarDistance: Double = 0
    @Published var opticalDistance: Double = 0
    @Published var framesSeen = 0
    @Published var framesWithBall = 0
    @Published var isRunning = false
    @Published var lastError: String?

    /// Loosen the calibrated tolerances live — a profile that's too tight is the likeliest reason
    /// a ball that's plainly in frame isn't found.
    @Published var tolerance: Double = 1.0 { didSet { rebuildProfile() } }

    let isSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    let session = ARSession()

    private var baseProfile: BallProfile?
    private var activeProfile: BallProfile?
    private let queue = DispatchQueue(label: "cricketnets.balltracker")
    private var busy = false

    func setProfile(_ profile: BallProfile?) {
        baseProfile = profile
        rebuildProfile()
    }

    /// Scale the profile's tolerances by the slider. 1.0 is exactly what was calibrated.
    private func rebuildProfile() {
        guard var p = baseProfile else { activeProfile = nil; return }
        p.hueTol = min(0.5, p.hueTol * tolerance)
        p.satTol = min(1.0, p.satTol * tolerance)
        p.valTol = min(1.0, p.valTol * tolerance)
        activeProfile = p
    }

    func start() {
        guard isSupported, !isRunning else {
            if !isSupported { lastError = "This device has no scene-depth sensor." }
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics.insert(.sceneDepth)
        if let fastest = ARWorldTrackingConfiguration.supportedVideoFormats
            .max(by: { $0.framesPerSecond < $1.framesPerSecond }) {
            config.videoFormat = fastest
        }
        session.delegateQueue = queue
        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
        framesSeen = 0
        framesWithBall = 0
    }

    func stop() {
        session.pause()
        isRunning = false
    }

    func resetCounts() {
        framesSeen = 0
        framesWithBall = 0
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let pixelBuffer = frame.capturedImage
        let intrinsics = frame.camera.intrinsics
        let depthMap = frame.sceneDepth?.depthMap
        let confidenceMap = frame.sceneDepth?.confidenceMap

        // Snapshot the profile without hopping actors per frame.
        let profile = MainActor.assumeIsolated { self.activeProfile }
        guard let profile else {
            Task { @MainActor in
                self.framesSeen += 1
                self.detection = nil
                self.lastError = "No ball calibrated — calibrate a ball first."
            }
            return
        }

        let found = BallDetector.detect(in: pixelBuffer, profile: profile)

        let width = Double(CVPixelBufferGetWidth(pixelBuffer))
        var optical = 0.0
        var lidar = 0.0

        if let found {
            optical = BallDetector.opticalDistance(radiusNormalized: found.radiusNormalized,
                                                   frameWidthPx: width,
                                                   focalLengthPx: Double(intrinsics.columns.0.x)) ?? 0
            if let depthMap {
                let depthWidth = CVPixelBufferGetWidth(depthMap)
                let depthFocal = intrinsics.columns.0.x * Float(depthWidth) / Float(max(width, 1))
                if let reading = DepthTrajectoryTracker.ballDepth(at: found.center,
                                                                 depthMap: depthMap,
                                                                 confidenceMap: confidenceMap,
                                                                 depthFocalLengthPx: depthFocal) {
                    lidar = Double(reading.distance)
                }
            }
        }

        Task { @MainActor in
            self.framesSeen += 1
            self.detection = found
            self.lastError = nil
            if found != nil {
                self.framesWithBall += 1
                self.opticalDistance = optical
                self.lidarDistance = lidar
            }
        }
    }
}

struct BallTrackerView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = BallTrackerModel()

    var body: some View {
        ZStack {
            if model.isSupported {
                ARPreview(session: model.session).ignoresSafeArea()
                overlay
            } else {
                Color.black.ignoresSafeArea()
            }

            VStack {
                header
                Spacer()
                panel
            }
            .padding()
        }
        .onAppear {
            model.setProfile(app.ballProfile)
            model.start()
        }
        .onDisappear { model.stop() }
    }

    /// A ring drawn where the ball was found, at the size it was found.
    private var overlay: some View {
        GeometryReader { geo in
            if let d = model.detection {
                let center = CGPoint(x: d.center.x * geo.size.width, y: d.center.y * geo.size.height)
                let radius = max(12, d.radiusNormalized * geo.size.width)
                ZStack {
                    Circle()
                        .stroke(d.looksLikeABall ? Color.green : Color.orange, lineWidth: 3)
                        .frame(width: radius * 2, height: radius * 2)
                    Circle().fill(.white).frame(width: 5, height: 5)
                }
                .position(center)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("BALL TRACKER").font(.caption.bold()).tracking(1).foregroundStyle(.cyan)
                if let d = model.detection {
                    Text(d.looksLikeABall ? "FOUND" : "TOO BROAD")
                        .font(.title3.bold())
                        .foregroundStyle(d.looksLikeABall ? .green : .orange)
                    Text("\(d.pixelCount) px blob · \(Int(d.frameCoverage * 100))% of frame")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.white)
                    Text("\(d.totalMatched) px match this colour · \(Int(d.concentration * 100))% in the blob")
                        .font(.system(size: 9).monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                    if !d.looksLikeABall {
                        Text(d.frameCoverage >= 0.25
                             ? "matching most of the frame — tolerance too high"
                             : "colour is scattered — recalibrate the ball")
                            .font(.system(size: 9)).foregroundStyle(.orange)
                    }
                } else {
                    Text("NOT FOUND").font(.title3.bold()).foregroundStyle(.orange)
                    Text(model.lastError ?? "Nothing matches the calibrated colour.")
                        .font(.caption2).foregroundStyle(.orange.opacity(0.9))
                }
                Text("\(model.framesWithBall)/\(model.framesSeen) frames")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
            }
            .padding(10)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))

            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent).tint(.white)
        }
    }

    private var panel: some View {
        VStack(spacing: 12) {
            distances
            HStack {
                Text("Tolerance").font(.caption).foregroundStyle(.white.opacity(0.85))
                    .frame(width: 78, alignment: .leading)
                Slider(value: $model.tolerance, in: 0.5...8).tint(.cyan)
                Text(String(format: "%.1f×", model.tolerance))
                    .font(.caption.monospacedDigit()).foregroundStyle(.white)
                    .frame(width: 40, alignment: .trailing)
            }
            Text("Drag Tolerance up until the ring locks onto the ball. If it never does, the calibrated colour is wrong — recalibrate under the light you're actually playing in.")
                .font(.caption2).foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Reset counts") { model.resetCounts() }
                .font(.caption2).buttonStyle(.bordered).tint(.white)
        }
        .padding()
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
    }

    /// Two independent distance estimates. They should roughly agree; when they don't, the one to
    /// distrust is LiDAR, because the optical estimate only depends on finding the ball at all.
    private var distances: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.lidarDistance > 0 ? String(format: "%.2f m", model.lidarDistance) : "—")
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(model.lidarDistance > 0 ? .green : .orange)
                Text("LiDAR").font(.caption2).foregroundStyle(.white.opacity(0.6))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.opticalDistance > 0 ? String(format: "%.2f m", model.opticalDistance) : "—")
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(.cyan)
                Text("from ball size").font(.caption2).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            if model.lidarDistance > 0 && model.opticalDistance > 0 {
                let gap = abs(model.lidarDistance - model.opticalDistance)
                Text(gap < 0.5 ? "agree" : String(format: "%.1f m apart", gap))
                    .font(.caption.bold())
                    .foregroundStyle(gap < 0.5 ? .green : .orange)
            }
        }
    }
}
