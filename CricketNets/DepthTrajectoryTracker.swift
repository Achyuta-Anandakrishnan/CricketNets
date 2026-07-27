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

    /// Running tally of what the gates did to the candidate trajectories Vision offered.
    struct GateCounts: Equatable {
        var candidates = 0
        var tooLittleMotion = 0
        var lowConfidence = 0
        var wrongColor = 0
        var accepted = 0

        mutating func add(_ other: GateCounts) {
            candidates += other.candidates
            tooLittleMotion += other.tooLittleMotion
            lowConfidence += other.lowConfidence
            wrongColor += other.wrongColor
            accepted += other.accepted
        }
    }

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
    /// Where the ball was last seen, Vision-normalized with a top-left origin. Drives the testing
    /// overlay so you can see whether the depth patch is actually landing on the ball.
    @Published private(set) var lastBallPoint: CGPoint?
    /// The full depth lookup behind the last frame — patch size, confident pixel count, distance.
    @Published private(set) var lastReading: BallDepthReading?
    /// Azimuth of the shot in progress, recomputed as samples arrive. Lets the testing screen give
    /// immediate feedback while the phone placement is being adjusted, without waiting for a shot
    /// to finish and score.
    @Published private(set) var liveAzimuthDeg: Double?
    /// Cumulative gate tally since tracking started — the fastest way to see which filter is the
    /// one rejecting everything.
    @Published private(set) var gates = GateCounts()
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
    /// The raw camera forward captured when aiming, kept so the offset can be re-applied without
    /// making the user aim again.
    private var aimedForward = simd_float2(0, -1)
    private var groundOffsetDegrees: Double = 0
    private var settleWork: DispatchWorkItem?

    // MARK: arQueue-confined state

    /// Maps captured-image normalized coordinates onto the preview. See `BallTrackerModel` — the
    /// captured image is landscape while the preview is portrait, so overlays need this or they
    /// travel at right angles to what they're tracking.
    @Published private(set) var displayTransform: CGAffineTransform = .identity

    private let arQueue = DispatchQueue(label: "cricketnets.depth.ar")
    private let captureID = UUID()

    /// Written by the view, read on the frame queue.
    private let viewportLock = NSLock()
    private var _viewport = CGSize(width: 390, height: 844)
    var viewport: CGSize {
        get { viewportLock.lock(); defer { viewportLock.unlock() }; return _viewport }
        set { viewportLock.lock(); _viewport = newValue; viewportLock.unlock() }
    }
    /// Distinguishes the live tracker from the testing screen's own instance in the arbiter.
    var ownerName = "3D tracking"

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
    private var colorGateEnabled = true

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

    /// Turn the color gate off to isolate it — if detections appear the moment it's disabled, the
    /// ball profile is the problem, not the detector.
    func setColorGateEnabled(_ on: Bool) { arQueue.async { [weak self] in self?.colorGateEnabled = on } }

    func resetCounters() {
        gates = GateCounts()
        framesSeen = 0
        pointsResolved = 0
    }

    // MARK: Lifecycle

    @MainActor
    func start() {
        guard isSupported, !isRunning else { return }
        // One camera owner at a time; overlapping sessions give a black preview and no error.
        CaptureArbiter.shared.acquire(id: captureID, name: ownerName) { [weak self] in self?.stop() }
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

    @MainActor
    func stop() {
        session.pause()
        isRunning = false
        isTracking = false
        settleWork?.cancel()
        samples = []
        CaptureArbiter.shared.release(id: captureID)
    }

    /// Lock the current aim as the reference for azimuth, rotated by where the phone is standing.
    ///
    /// With `offsetDegrees` 0 this means "the phone is pointing down the ground". Set it to ±90 and
    /// the phone can sit square of the wicket — a much better view of ball travel — while azimuth
    /// still reads relative to the pitch.
    func captureGroundDirection(offsetDegrees: Double = 0) {
        guard let frame = session.currentFrame else { return }
        aimedForward = Self.horizontalForward(of: frame.camera.transform)
        groundOffsetDegrees = offsetDegrees
        groundDirection = PhonePlacement.rotate(aimedForward, byDegrees: offsetDegrees)
        hasGroundDirection = true
    }

    /// Re-derive the reference from the aim already captured. Lets the offset be tuned live — hit a
    /// straight ball, nudge until it reads straight — without re-aiming the phone each time.
    func setGroundOffset(_ degrees: Double) {
        groundOffsetDegrees = degrees
        guard hasGroundDirection else { return }
        groundDirection = PhonePlacement.rotate(aimedForward, byDegrees: degrees)
        recomputeLiveAzimuth()
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

        let transform = frame.displayTransform(for: .portrait, viewportSize: viewport)
        DispatchQueue.main.async { [weak self] in self?.displayTransform = transform }

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
            // No ball this frame — clear the overlay rather than leaving a stale marker on screen.
            publish(resolved: nil, reading: nil, ballPoint: nil)
            return
        }

        // Vision reports a bottom-left origin; depth maps and camera intrinsics are top-left.
        let normalized = CGPoint(x: CGFloat(newest.x), y: 1 - CGFloat(newest.y))

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // The depth map is lower-resolution than the captured image but covers the same field of
        // view, so the focal length scales with the width ratio.
        let depthWidth = CVPixelBufferGetWidth(depth.depthMap)
        let depthFocal = intrinsics.columns.0.x * Float(depthWidth) / Float(max(width, 1))

        let reading = Self.ballDepth(at: normalized,
                                     depthMap: depth.depthMap,
                                     confidenceMap: depth.confidenceMap,
                                     depthFocalLengthPx: depthFocal)

        guard let reading,
              reading.distance >= Self.minUsefulDepth,
              reading.distance <= Self.maxUsefulDepth
        else {
            publish(resolved: nil, reading: reading, ballPoint: normalized)
            return
        }

        let imagePoint = CGPoint(x: normalized.x * CGFloat(width), y: normalized.y * CGFloat(height))
        let cameraSpace = LiDARCalibrator.cameraSpacePoint(imagePoint: imagePoint,
                                                           depth: reading.distance,
                                                           intrinsics: intrinsics)
        let world = LiDARCalibrator.worldPoint(cameraSpace: cameraSpace, cameraTransform: cameraTransform)

        publish(resolved: BallPhysics.WorldSample(position: world, time: timestamp),
                reading: reading,
                ballPoint: normalized)
    }

    /// The highest-confidence trajectory clearing the motion, confidence and color gates — the same
    /// three the fast path applies. Tallies why each candidate was dropped, so a gate that is
    /// silently eating every detection shows up as a number rather than as "nothing happens".
    private func bestObservation(in observations: [VNTrajectoryObservation],
                                 colorSource: CVPixelBuffer) -> VNTrajectoryObservation? {
        var best: VNTrajectoryObservation?
        var counts = GateCounts()
        for obs in observations {
            counts.candidates += 1
            guard TrajectoryDetector.pathLength(obs.detectedPoints) >= minTrajectoryMotion else {
                counts.tooLittleMotion += 1; continue
            }
            guard obs.confidence > minConfidence else {
                counts.lowConfidence += 1; continue
            }
            if colorGateEnabled, let ballProfile,
               TrajectoryDetector.colorFraction(of: obs, in: colorSource, profile: ballProfile) < 0.7 {
                counts.wrongColor += 1; continue
            }
            counts.accepted += 1
            if best == nil || obs.confidence > best!.confidence { best = obs }
        }
        let tally = counts
        DispatchQueue.main.async { [weak self] in self?.gates.add(tally) }
        return best
    }

    /// What a depth lookup for the ball actually found — reported in full so the 3D testing screen
    /// can show whether the patch is landing on the ball or on the net behind it.
    struct BallDepthReading: Equatable {
        let distance: Float      // metres, nearest confident reading in the patch
        let radiusPx: Int        // patch radius actually used
        let confidentPixels: Int // readings that passed the confidence gate
        let sampledPixels: Int   // pixels inspected

        /// Share of the patch that came back confident. A low value next to a plausible distance
        /// usually means the ball is being missed and the reading is the background.
        var confidence: Double {
            sampledPixels > 0 ? Double(confidentPixels) / Double(sampledPixels) : 0
        }
    }

    /// Apparent radius of a cricket ball in depth-map pixels at a given distance.
    ///
    /// A pinhole projection of a known real object: radius_px = (diameter/2) · focal / distance.
    /// This is what lets the sampler cover the *whole ball* rather than a fixed guess — at 2 m the
    /// ball spans several pixels, at 5 m barely one.
    static func ballRadiusPixels(distance: Float, focalLengthPx: Float) -> Int {
        guard distance > 0, focalLengthPx > 0 else { return 1 }
        let radius = Float(CricketConstants.ballDiameter / 2) * focalLengthPx / distance
        return max(1, Int(radius.rounded()))
    }

    /// Size the patch to the ball and read its distance.
    ///
    /// Two passes, because sizing the patch needs the distance and the distance needs a patch:
    /// a small probe gets an approximate range, that sets the ball's apparent radius, and the real
    /// read covers **the ball plus one pixel of margin** so a slightly-off centre still lands on it.
    ///
    /// Both passes take the **minimum** confident depth rather than the mean, on purpose: the ball
    /// is always in front of whatever is behind it, and LiDAR's low resolution bleeds background
    /// depth into the handful of pixels a ball covers. Averaging would drag the reading back toward
    /// the net; the nearest confident reading is the one most likely to be the ball itself.
    static func ballDepth(at p: CGPoint,
                          depthMap: CVPixelBuffer,
                          confidenceMap: CVPixelBuffer?,
                          depthFocalLengthPx: Float) -> BallDepthReading? {
        // Pass 1 — a tight probe just to get within range.
        guard let probe = nearestConfidentDepth(at: p, depthMap: depthMap,
                                                confidenceMap: confidenceMap, radius: 2),
              probe.distance > 0
        else { return nil }

        // Pass 2 — the whole ball, plus one block of margin around it.
        let radius = min(12, ballRadiusPixels(distance: probe.distance,
                                              focalLengthPx: depthFocalLengthPx) + 1)
        return nearestConfidentDepth(at: p, depthMap: depthMap,
                                     confidenceMap: confidenceMap, radius: radius)
    }

    /// Nearest confident depth in a square patch around a normalized (top-left origin) point.
    static func nearestConfidentDepth(at p: CGPoint,
                                      depthMap: CVPixelBuffer,
                                      confidenceMap: CVPixelBuffer?,
                                      radius: Int) -> BallDepthReading? {
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
        var confident = 0, sampled = 0
        for y in max(0, cy - radius)...min(h - 1, cy + radius) {
            for x in max(0, cx - radius)...min(w - 1, cx + radius) {
                sampled += 1
                if let confidence {
                    let level = confidence.0.advanced(by: y * confidence.1)
                        .assumingMemoryBound(to: UInt8.self)[x]
                    // Reject low confidence; medium and high are worth using.
                    guard level >= ARConfidenceLevel.medium.rawValue else { continue }
                }
                let value = depthBase.advanced(by: y * depthRowBytes)
                    .assumingMemoryBound(to: Float32.self)[x]
                guard value > 0, value.isFinite else { continue }
                confident += 1
                if nearest == nil || value < nearest! { nearest = value }
            }
        }
        guard let nearest else { return nil }
        return BallDepthReading(distance: nearest, radiusPx: radius,
                                confidentPixels: confident, sampledPixels: sampled)
    }

    /// Hop a frame's outcome to the main thread, where the published state and shot assembly live.
    private func publish(resolved: BallPhysics.WorldSample?,
                         reading: BallDepthReading?,
                         ballPoint: CGPoint?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            framesSeen += 1
            lastBallPoint = ballPoint
            lastReading = reading
            if let reading { lastBallDistance = Double(reading.distance) }
            depthQuality = {
                guard let reading, reading.distance > 0 else { return .noReading }
                return reading.distance > Self.maxUsefulDepth ? .tooFar : .good
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
        recomputeLiveAzimuth()

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

    /// Direction of the shot so far, so placement can be tuned without waiting for a full shot.
    func recomputeLiveAzimuth() {
        guard samples.count >= minSamplesPerShot,
              let launch = BallPhysics.launchVector(worldSamples: samples,
                                                    groundDirection: groundDirection)
        else { return }
        liveAzimuthDeg = launch.azimuthDeg
    }
}
