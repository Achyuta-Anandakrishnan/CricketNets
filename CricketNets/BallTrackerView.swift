import SwiftUI
import ARKit
import CoreVideo

/// Runs `BallDetector` on every ARKit frame and draws what it finds. Nothing else.
///
/// No trajectory, no parabola, no shots, no scoring, no cooldown. Just: hold the ball up, and see
/// whether the app can find it and how far away it thinks it is. Everything else in the 3D path is
/// built on this working, so it is the first thing worth proving.
/// Threading follows `DepthTrajectoryTracker`: ARKit delivers frames on `queue`, the detection
/// profile stays confined to that queue, and everything the UI reads is published on the main
/// thread. It must NOT be `@MainActor` — the delegate callback is genuinely off the main actor, and
/// reaching for main-actor state from inside it (via `assumeIsolated`) traps on the first frame.
final class BallTrackerModel: NSObject, ObservableObject, ARSessionDelegate {

    @Published private(set) var detection: BallDetector.Detection?
    @Published private(set) var lidarDistance: Double = 0
    @Published private(set) var opticalDistance: Double = 0
    @Published private(set) var framesSeen = 0
    @Published private(set) var framesWithBall = 0
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    /// True when the last sighting came from following the ball rather than a full-frame scan.
    @Published private(set) var wasFollowed = false
    /// The profile actually being matched against, tolerances included — shown so the swatch on
    /// screen is what the detector is really looking for, not just what was calibrated.
    @Published private(set) var activeProfileForDisplay: BallProfile?

    /// Loosen the calibrated tolerances live — a profile that's too tight is the likeliest reason
    /// a ball that's plainly in frame isn't found.
    @Published var tolerance: Double = 1.0 {
        didSet { rebuildProfile() }
    }

    let isSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    let session = ARSession()

    /// Maps captured-image normalized coordinates onto the preview.
    ///
    /// ARKit's `capturedImage` is camera-native landscape while the preview is rendered portrait,
    /// so image x and y do not correspond to view x and y — drawing an overlay straight from image
    /// coordinates makes it travel across the screen at right angles to the thing it's tracking.
    /// `ARFrame.displayTransform` fixes the rotation *and* the aspect-fill crop, which a hardcoded
    /// 90° rotation would leave offset.
    ///
    /// Only the overlay needs this. The detection and depth lookups all work in captured-image
    /// space against intrinsics and a depth map in that same space, so they stay self-consistent.
    @Published private(set) var displayTransform: CGAffineTransform = .identity

    private let captureID = UUID()
    private let queue = DispatchQueue(label: "cricketnets.balltracker")

    /// Written by the view, read on the frame queue.
    private let viewportLock = NSLock()
    private var _viewport = CGSize(width: 390, height: 844)
    var viewport: CGSize {
        get { viewportLock.lock(); defer { viewportLock.unlock() }; return _viewport }
        set { viewportLock.lock(); _viewport = newValue; viewportLock.unlock() }
    }

    /// Main-thread copy; `queueProfile` is the one the delegate reads.
    private var baseProfile: BallProfile?
    private var queueProfile: BallProfile?
    /// Frame-to-frame continuity. Queue-confined alongside the profile.
    private var tracker = BallTracker()

    func setProfile(_ profile: BallProfile?) {
        baseProfile = profile
        rebuildProfile()
    }

    /// Scale the calibrated tolerances by the slider. 1.0 is exactly what was calibrated.
    private func rebuildProfile() {
        guard var p = baseProfile else {
            activeProfileForDisplay = nil
            queue.async { [weak self] in self?.queueProfile = nil }
            return
        }
        p.hueTol = min(0.5, p.hueTol * tolerance)
        p.satTol = min(1.0, p.satTol * tolerance)
        p.valTol = min(1.0, p.valTol * tolerance)
        activeProfileForDisplay = p
        queue.async { [weak self] in self?.queueProfile = p }
    }

    @MainActor
    func start() {
        guard isSupported else {
            lastError = "This device has no scene-depth sensor."
            return
        }
        guard !isRunning else { return }

        // Take the camera off whoever else had it; two live sessions means a black preview.
        CaptureArbiter.shared.acquire(id: captureID, name: "Ball tracker") { [weak self] in
            self?.stop()
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
        lastError = nil
    }

    @MainActor
    func stop() {
        session.pause()
        isRunning = false
        CaptureArbiter.shared.release(id: captureID)
    }

    @MainActor
    func resetCounts() {
        framesSeen = 0
        framesWithBall = 0
    }

    // MARK: Frame handling (queue)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let pixelBuffer = frame.capturedImage
        let intrinsics = frame.camera.intrinsics
        let depthMap = frame.sceneDepth?.depthMap
        let confidenceMap = frame.sceneDepth?.confidenceMap

        let transform = frame.displayTransform(for: .portrait, viewportSize: viewport)

        guard let profile = queueProfile else {
            publish(nil, optical: 0, lidar: 0, transform: transform, followed: false,
                    error: "No ball calibrated — calibrate a ball first.")
            return
        }

        let hit = tracker.track(in: pixelBuffer, profile: profile, time: frame.timestamp)
        let found = hit?.detection
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

        publish(found, optical: optical, lidar: lidar, transform: transform,
                followed: hit?.followed ?? false, error: nil)
    }

    private func publish(_ found: BallDetector.Detection?,
                         optical: Double, lidar: Double,
                         transform: CGAffineTransform, followed: Bool, error: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            framesSeen += 1
            detection = found
            displayTransform = transform
            lastError = error
            wasFollowed = followed
            if found != nil {
                framesWithBall += 1
                opticalDistance = optical
                lidarDistance = lidar
            }
        }
    }
}

struct BallTrackerView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = BallTrackerModel()

    var body: some View {
        GeometryReader { root in
            content
                // The display transform depends on the viewport's aspect, so keep it current.
                .onAppear { model.viewport = root.size }
                .onChange(of: root.size) { _, size in model.viewport = size }
        }
    }

    private var content: some View {
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
    ///
    /// Both the centre and the radius go through the display transform: the rotation turns a
    /// horizontal offset in the image into a vertical one on screen, so measuring the radius after
    /// transforming is the only way to get it right under aspect-fill scaling.
    private var overlay: some View {
        GeometryReader { geo in
            if let d = model.detection {
                let t = model.displayTransform
                let c = d.center.applying(t)
                let edge = CGPoint(x: d.center.x + d.radiusNormalized, y: d.center.y).applying(t)

                let center = CGPoint(x: c.x * geo.size.width, y: c.y * geo.size.height)
                let edgePoint = CGPoint(x: edge.x * geo.size.width, y: edge.y * geo.size.height)
                let radius = max(12, hypot(edgePoint.x - center.x, edgePoint.y - center.y))

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
                    Text(model.wasFollowed ? "FOLLOWING" : (d.looksLikeABall ? "FOUND" : "TOO BROAD"))
                        .font(.title3.bold())
                        .foregroundStyle(model.wasFollowed || d.looksLikeABall ? .green : .orange)
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
                BallSwatch(profile: model.activeProfileForDisplay, showValues: true)
                    .padding(.top, 2)
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
            TunableSlider(
                title: "How fussy about colour",
                value: $model.tolerance,
                range: 0.5...8,
                reading: TuningWords.colourStrictness,
                guidance: "Right = accepts more shades, so it finds the ball more easily but may grab other things too."
            )
            Text("Drag right until the ring locks onto the ball. If it never does at any setting, the saved colour is wrong for this light — recalibrate the ball here.")
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
