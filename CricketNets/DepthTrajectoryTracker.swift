import ARKit
import Vision
import CoreVideo
import Combine
import simd

/// Live 3D ball tracking through LiDAR depth — the only path that can actually *measure* which
/// side of the wicket a shot went.
///
/// The fast AVFoundation tracker sees the image plane and nothing else, so a square cut and a
/// straight drive trace the same path and azimuth is simply unobservable. Here every detected
/// trajectory point is unprojected through that frame's depth map into ARKit world space, which
/// makes speed, launch angle **and** azimuth real measurements.
///
/// The trade is frame rate: ARKit caps scene depth around 60 fps (often 30 in practice) against the
/// fast path's 120, so the ball is seen fewer times per flight and short/fast shots may not clear
/// the minimum sample count. Pick the fast path for speed, this one for placement.
///
/// Threading mirrors `CameraController`: ARKit delivers frames on `arQueue`, everything the UI
/// reads is published on the main thread, and the per-frame state stays confined to `arQueue`.
///
/// **Device only** — ARKit scene depth does not exist in the Simulator.
final class DepthTrajectoryTracker: NSObject, ObservableObject {

    /// How well LiDAR is reading the ball right now — surfaced so the user can fix their setup
    /// (get closer, better light) instead of wondering why nothing scores.
    enum DepthQuality: String {
        case noReading = "no depth"
        case tooFar = "too far"
        case good = "good"
    }

    // MARK: Published state (main thread only)

    @Published private(set) var isRunning = false
    @Published private(set) var isTracking = false
    /// World-space samples collected for the shot in progress.
    @Published private(set) var samples: [BallPhysics.WorldSample] = []
    /// Distance (m) the depth map reported at the last detected ball position.
    @Published private(set) var lastBallDistance: Double = 0
    @Published private(set) var depthQuality: DepthQuality = .noReading
    /// Frames seen vs frames that produced a usable 3D point — the honest hit rate of this path.
    @Published private(set) var framesSeen = 0
    @Published private(set) var pointsResolved = 0
    /// True once the user has aimed and locked "down the ground".
    @Published private(set) var hasGroundDirection = false

    let isSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    let session = ARSession()

    /// Fires on the main thread once a shot's samples stop arriving, with the samples and the
    /// ground reference they should be measured against.
    var onShotCompleted: (([BallPhysics.WorldSample], simd_float2) -> Void)?

    /// Minimum 3D samples before a shot is worth scoring. Three is the fewest a velocity fit with
    /// a gravity correction can use.
    var minSamplesPerShot = 3

    // MARK: Main-thread state

    /// Horizontal (world x, z) direction the user aimed down the ground. Defaults to the camera's
    /// forward at session start, which is right if the phone is set up pointing down the pitch.
    private var groundDirection = simd_float2(0, -1)
    private var settleWork: DispatchWorkItem?

    // MARK: arQueue-confined state

    private let arQueue = DispatchQueue(label: "cricketnets.depth.ar")

    /// Vision's trajectory request is stateful, so one instance, touched only on `arQueue`.
    private lazy var request: VNDetectTrajectoriesRequest = {
        let req = VNDetectTrajectoriesRequest(frameAnalysisSpacing: .zero, trajectoryLength: 5)
        req.objectMinimumNormalizedRadius = Self.defaultMinRadius
        req.objectMaximumNormalizedRadius = Self.defaultMaxRadius
        return req
    }()

    private static let defaultMinRadius: Float = 0.003
    private static let defaultMaxRadius: Float = 0.20

    /// Same gates as the fast path, so both tracking modes agree on what a ball looks like.
    private var minTrajectoryMotion: Double = 0.03
    private var minConfidence: Float = 0.3
    private var ballProfile: BallProfile?

    /// LiDAR's usable envelope. Beyond ~5 m readings collapse to zero or noise.
    private static let minUsefulDepth: Float = 0.3
    private static let maxUsefulDepth: Float = 5.0

    // MARK: Configuration

    /// Forward the calibrated ball so the color gate rejects hands and the bat here too.
    func setBallProfile(_ profile: BallProfile?) {
        arQueue.async { [weak self] in
            guard let self else { return }
            ballProfile = profile
            request.objectMinimumNormalizedRadius = Float(profile?.minRadius ?? Double(Self.defaultMinRadius))
            request.objectMaximumNormalizedRadius = Float(profile?.maxRadius ?? Double(Self.defaultMaxRadius))
        }
    }

    func setMinTrajectoryMotion(_ v: Double) { arQueue.async { [weak self] in self?.minTrajectoryMotion = v } }
    func setMinConfidence(_ v: Float) { arQueue.async { [weak self] in self?.minConfidence = v } }

    // MARK: Lifecycle

    func start() {
        guard isSupported, !isRunning else { return }
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics.insert(.sceneDepth)
        // Prefer the fastest video format ARKit offers — more frames means more 3D samples per shot.
        if let fastest = ARWorldTrackingConfiguration.supportedVideoFormats
            .max(by: { $0.framesPerSecond < $1.framesPerSecond }) {
            config.videoFormat = fastest
        }
        session.delegateQueue = arQueue   // keep Vision off the main thread
        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
        framesSeen = 0
        pointsResolved = 0
    }

    func stop() {
        session.pause()
        isRunning = false
        isTracking = false
        settleWork?.cancel()
        samples = []
    }

    /// Lock the current aim as "straight down the ground". Azimuth is measured from here, which is
    /// what makes left/right meaningful rather than relative to an arbitrary world axis.
    func captureGroundDirection() {
        guard let frame = session.currentFrame else { return }
        groundDirection = Self.horizontalForward(of: frame.camera.transform)
        hasGroundDirection = true
    }

    /// Discard the shot in progress (e.g. a mis-track) without waiting for it to settle.
    func resetShot() {
        settleWork?.cancel()
        samples = []
        isTracking = false
    }

    /// The camera's forward direction flattened onto the ground plane, as (world x, world z).
    /// ARKit cameras look down their own −Z, which is column 2 of the transform, negated.
    static func horizontalForward(of transform: simd_float4x4) -> simd_float2 {
        let forward = -transform.columns.2
        let flat = simd_float2(forward.x, forward.z)
        return simd_length(flat) > 1e-5 ? simd_normalize(flat) : simd_float2(0, -1)
    }
}

// MARK: - Per-frame processing (arQueue)

extension DepthTrajectoryTracker: ARSessionDelegate {

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Everything needed is read out of the frame synchronously; the ARFrame itself is never
        // retained past this call — ARKit's frame pool is small and stalls if frames are held.
        guard let depth = frame.sceneDepth else { return }
        let pixelBuffer = frame.capturedImage
        let timestamp = frame.timestamp
        let intrinsics = frame.camera.intrinsics
        let cameraTransform = frame.camera.transform

        guard let sample = SampleBufferFactory.make(from: pixelBuffer, timestamp: timestamp) else { return }

        // Run on the raw captured image in its native landscape orientation. Unlike the 2D path,
        // orientation doesn't matter here: every point becomes a world coordinate before it's used,
        // and world space has no notion of how the phone was held.
        let handler = VNImageRequestHandler(cmSampleBuffer: sample, orientation: .up, options: [:])
        try? handler.perform([request])

        guard
            let best = bestObservation(in: request.results ?? [], colorSource: pixelBuffer),
            let newest = best.detectedPoints.last
        else {
            publish(resolved: nil, distance: nil)
            return
        }

        // Vision reports a bottom-left origin; depth maps and camera intrinsics are top-left.
        let normalized = CGPoint(x: CGFloat(newest.x), y: 1 - CGFloat(newest.y))
        let ballDepth = Self.nearestConfidentDepth(at: normalized,
                                                   depthMap: depth.depthMap,
                                                   confidenceMap: depth.confidenceMap)

        guard let ballDepth,
              ballDepth >= Self.minUsefulDepth,
              ballDepth <= Self.maxUsefulDepth
        else {
            publish(resolved: nil, distance: ballDepth.map(Double.init))
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let imagePoint = CGPoint(x: normalized.x * CGFloat(width), y: normalized.y * CGFloat(height))
        let cameraSpace = LiDARCalibrator.cameraSpacePoint(imagePoint: imagePoint,
                                                           depth: ballDepth,
                                                           intrinsics: intrinsics)
        let world = LiDARCalibrator.worldPoint(cameraSpace: cameraSpace, cameraTransform: cameraTransform)

        publish(resolved: BallPhysics.WorldSample(position: world, time: timestamp),
                distance: Double(ballDepth))
    }

    /// The highest-confidence trajectory clearing the motion, confidence and color gates — the same
    /// three the fast path applies.
    private func bestObservation(in observations: [VNTrajectoryObservation],
                                 colorSource: CVPixelBuffer) -> VNTrajectoryObservation? {
        var best: VNTrajectoryObservation?
        for obs in observations {
            guard TrajectoryDetector.pathLength(obs.detectedPoints) >= minTrajectoryMotion else { continue }
            guard obs.confidence > minConfidence else { continue }
            if let ballProfile,
               TrajectoryDetector.colorFraction(of: obs, in: colorSource, profile: ballProfile) < 0.7 { continue }
            if best == nil || obs.confidence > best!.confidence { best = obs }
        }
        return best
    }

    /// Nearest confident depth (m) in a small patch around a normalized (top-left origin) point.
    ///
    /// Takes the **minimum** rather than the mean on purpose: the ball is always in front of
    /// whatever is behind it, and LiDAR's low resolution bleeds background depth into the handful
    /// of pixels a cricket ball covers. The nearest confident reading in the patch is the one most
    /// likely to be the ball rather than the net behind it.
    static func nearestConfidentDepth(at p: CGPoint,
                                      depthMap: CVPixelBuffer,
                                      confidenceMap: CVPixelBuffer?,
                                      radius: Int = 2) -> Float? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }

        let w = CVPixelBufferGetWidth(depthMap)
        let h = CVPixelBufferGetHeight(depthMap)
        guard w > 0, h > 0 else { return nil }
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap)

        // The confidence map matches the depth map's dimensions; skip gating if it isn't offered.
        let confidence = confidenceMap.flatMap { map -> (UnsafeMutableRawPointer, Int, CVPixelBuffer)? in
            guard CVPixelBufferGetWidth(map) == w, CVPixelBufferGetHeight(map) == h else { return nil }
            CVPixelBufferLockBaseAddress(map, .readOnly)
            guard let base = CVPixelBufferGetBaseAddress(map) else {
                CVPixelBufferUnlockBaseAddress(map, .readOnly)
                return nil
            }
            return (base, CVPixelBufferGetBytesPerRow(map), map)
        }
        defer {
            if let confidence { CVPixelBufferUnlockBaseAddress(confidence.2, .readOnly) }
        }

        let cx = min(max(Int(p.x * CGFloat(w)), 0), w - 1)
        let cy = min(max(Int(p.y * CGFloat(h)), 0), h - 1)

        var nearest: Float?
        for y in max(0, cy - radius)...min(h - 1, cy + radius) {
            for x in max(0, cx - radius)...min(w - 1, cx + radius) {
                if let confidence {
                    let level = confidence.0.advanced(by: y * confidence.1)
                        .assumingMemoryBound(to: UInt8.self)[x]
                    // Reject low confidence; medium and high are worth using.
                    guard level >= ARConfidenceLevel.medium.rawValue else { continue }
                }
                let value = depthBase.advanced(by: y * depthRowBytes)
                    .assumingMemoryBound(to: Float32.self)[x]
                guard value > 0, value.isFinite else { continue }
                if nearest == nil || value < nearest! { nearest = value }
            }
        }
        return nearest
    }

    /// Hop a frame's outcome to the main thread, where the published state and shot assembly live.
    private func publish(resolved: BallPhysics.WorldSample?, distance: Double?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            framesSeen += 1
            if let distance { lastBallDistance = distance }
            depthQuality = {
                guard let distance, distance > 0 else { return .noReading }
                return distance > Double(Self.maxUsefulDepth) ? .tooFar : .good
            }()
            guard let resolved else { return }
            pointsResolved += 1
            append(resolved)
        }
    }
}

// MARK: - Shot assembly (main thread)

private extension DepthTrajectoryTracker {

    /// Collect a sample and restart the settle timer. A shot is "over" when points stop arriving.
    func append(_ sample: BallPhysics.WorldSample) {
        samples.append(sample)
        isTracking = true

        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if samples.count >= minSamplesPerShot {
                onShotCompleted?(samples, groundDirection)
            }
            samples = []
            isTracking = false
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
