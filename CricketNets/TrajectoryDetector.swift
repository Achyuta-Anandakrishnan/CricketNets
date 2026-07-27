import Foundation
import Vision
import CoreMedia
import CoreGraphics

struct TrajectoryResult {
    /// Detected trajectory points in Vision normalized space (origin bottom-left).
    let points: [CGPoint]
    /// Rough speed estimate in km/h. Uncalibrated until `Calibration.metersPerNormalizedUnit` is real.
    let speedKmh: Double
}

/// A detected trajectory with the verdict of why it was kept or dropped — for the Testing screen.
struct DebugTrajectory: Identifiable {
    let id = UUID()
    let points: [CGPoint]      // Vision-normalized (origin bottom-left)
    let confidence: Float
    let pathLength: Double
    let colorFraction: Double  // -1 = not evaluated
    let verdict: Verdict

    enum Verdict: String { case accepted, tooLittleMotion, wrongColor, lowConfidence }
}

/// Wraps `VNDetectTrajectoriesRequest` — Apple's built-in parabolic-path detector.
/// The request is STATEFUL: the same instance must be reused across frames, and
/// frames must carry increasing presentation timestamps (the sample buffers do).
final class TrajectoryDetector {

    /// Calibration for turning image motion into real speed, written by `AppState` on the main
    /// thread and read by the detector on its own queue — hence the lock.
    enum Calibration {
        private static let lock = NSLock()
        private static var _metersPerNormalizedUnit: Double = 3.0
        private static var _fps: Double = 120

        /// How many meters one full normalized unit (frame width) spans at the ball's plane.
        /// Default assumes the tracked plane is ~3 m wide in view; a real calibration replaces it.
        static var metersPerNormalizedUnit: Double {
            get { lock.lock(); defer { lock.unlock() }; return _metersPerNormalizedUnit }
            set { lock.lock(); _metersPerNormalizedUnit = newValue; lock.unlock() }
        }
        /// Capture frame rate; used to convert per-frame motion into per-second speed.
        static var fps: Double {
            get { lock.lock(); defer { lock.unlock() }; return _fps }
            set { lock.lock(); _fps = newValue; lock.unlock() }
        }
    }

    /// Size gate used before a ball has been calibrated: generous, so a small far ball still counts.
    private static let defaultMinRadius: Float = 0.003
    private static let defaultMaxRadius: Float = 0.20

    /// Every tuning knob below is written from the UI (main thread) and read while processing a
    /// frame (vision queue), so all of them live behind `visionQueue` and are set via `configure`.
    private var minTrajectoryMotion: Double = 0.03
    private var minConfidence: Float = 0.3
    private var colorGateEnabled = true
    private var useMotionMask = false
    private var debugMode = false
    private var ballProfile: BallProfile?

    /// Serialize Vision calls; the stateful request is not thread-safe across frames.
    private let visionQueue = DispatchQueue(label: "cricketnets.vision")

    private lazy var request: VNDetectTrajectoriesRequest = {
        // Short length so fast shots register — they're only in view for a few frames.
        let req = VNDetectTrajectoriesRequest(frameAnalysisSpacing: .zero,
                                              trajectoryLength: 5)
        req.objectMinimumNormalizedRadius = Self.defaultMinRadius
        req.objectMaximumNormalizedRadius = Self.defaultMaxRadius
        return req
    }()

    private let masker = MotionMasker()

    // MARK: Configuration (safe to call from any thread)

    /// Apply a tuning change on the vision queue. Everything the per-frame path reads goes through
    /// here, so the UI can turn knobs mid-session without racing a frame being processed.
    private func configure(_ change: @escaping (TrajectoryDetector) -> Void) {
        visionQueue.async { [weak self] in
            guard let self else { return }
            change(self)
        }
    }

    /// A real shot streaks across the frame; noise barely moves. Trajectories spanning less than
    /// this (fraction of the frame) are rejected. Kept low so real shots aren't lost.
    func setMinTrajectoryMotion(_ v: Double) { configure { $0.minTrajectoryMotion = v } }

    /// Minimum confidence Vision must report for a trajectory to be considered.
    func setMinConfidence(_ v: Float) { configure { $0.minConfidence = v } }

    /// Toggle the color gate independently of whether a ball is calibrated (for the Testing screen).
    func setColorGateEnabled(_ on: Bool) { configure { $0.colorGateEnabled = on } }

    /// EXPERIMENTAL and OFF by default: feeding a difference-image to Vision can suppress detection
    /// entirely, so we track the raw frame. Toggle on in Testing mode only to compare.
    func setUseMotionMask(_ on: Bool) { configure { $0.useMotionMask = on } }

    /// When true, `process` also reports every candidate + its verdict for the Testing overlay.
    func setDebugMode(_ on: Bool) { configure { $0.debugMode = on } }

    /// Set (via ball calibration) so trajectories whose blob isn't the ball's color are rejected.
    /// This is what stops the tracker locking onto hands, the bat, or people in the background.
    /// The profile also narrows the request's size gate to the ball's apparent radius.
    func setBallProfile(_ profile: BallProfile?) {
        configure {
            $0.ballProfile = profile
            $0.request.objectMinimumNormalizedRadius = Float(profile?.minRadius ?? Double(Self.defaultMinRadius))
            $0.request.objectMaximumNormalizedRadius = Float(profile?.maxRadius ?? Double(Self.defaultMaxRadius))
        }
    }

    /// Clear the motion history when tracking (re)starts. Runs on the vision queue to avoid racing
    /// the per-frame masking.
    func resetMotion() { configure { $0.masker.reset() } }

    func process(_ sampleBuffer: CMSampleBuffer,
                 completion: @escaping (TrajectoryResult?, [DebugTrajectory]) -> Void) {
        visionQueue.async { [weak self] in
            guard let self else { return }

            let profile = self.ballProfile

            // Detection runs on the motion mask (moving pixels only) only if explicitly enabled;
            // by default we track the raw frame. Color is still checked against the original frame.
            let detectionBuffer: CMSampleBuffer
            if self.useMotionMask {
                guard let masked = self.masker.maskedSampleBuffer(from: sampleBuffer) else {
                    completion(nil, [])   // first frame / masking warmup — nothing to difference yet
                    return
                }
                detectionBuffer = masked
            } else {
                detectionBuffer = sampleBuffer
            }

            let handler = VNImageRequestHandler(cmSampleBuffer: detectionBuffer, orientation: .up, options: [:])
            do { try handler.perform([self.request]) } catch { completion(nil, []); return }

            guard let observations = self.request.results, !observations.isEmpty else {
                completion(nil, [])
                return
            }

            // Evaluate every candidate the same way, recording WHY it passed or failed.
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            var debug: [DebugTrajectory] = []
            var best: VNTrajectoryObservation?
            var bestPoints: [CGPoint] = []

            for obs in observations {
                let pts = obs.detectedPoints.map { CGPoint(x: $0.x, y: $0.y) }
                let len = Self.pathLength(obs.detectedPoints)
                var colorFrac = -1.0
                let verdict: DebugTrajectory.Verdict

                if len < self.minTrajectoryMotion {
                    verdict = .tooLittleMotion
                } else if self.colorGateEnabled, let profile, let pb = pixelBuffer,
                          { colorFrac = Self.colorFraction(of: obs, in: pb, profile: profile); return colorFrac < 0.7 }() {
                    verdict = .wrongColor
                } else if obs.confidence <= self.minConfidence {
                    verdict = .lowConfidence
                } else {
                    verdict = .accepted
                    if best == nil || obs.confidence > best!.confidence { best = obs; bestPoints = pts }
                }

                if self.debugMode {
                    debug.append(DebugTrajectory(points: pts, confidence: obs.confidence,
                                                 pathLength: len, colorFraction: colorFrac, verdict: verdict))
                }
            }

            if best != nil {
                completion(TrajectoryResult(points: bestPoints, speedKmh: self.estimateSpeedKmh(points: bestPoints)), debug)
            } else {
                completion(nil, debug)
            }
        }
    }

    /// Total path length of a trajectory in normalized units — how far the object actually travelled.
    /// Shared with the depth tracker, which applies the same gates to ARKit frames.
    static func pathLength(_ points: [VNPoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        var len = 0.0
        for i in 1..<points.count {
            let dx = points[i].x - points[i - 1].x
            let dy = points[i].y - points[i - 1].y
            len += (dx * dx + dy * dy).squareRoot()
        }
        return len
    }

    /// Fraction of a trajectory's points whose pixels match the ball color (0…1). Samples up to
    /// 6 points spread along the path — a real ball is its color everywhere; a stray blob isn't.
    static func colorFraction(of obs: VNTrajectoryObservation,
                              in pixelBuffer: CVPixelBuffer,
                              profile: BallProfile) -> Double {
        let pts = obs.detectedPoints
        guard !pts.isEmpty else { return 0 }
        let stride = max(1, pts.count / 6)
        var matched = 0, total = 0
        var i = 0
        while i < pts.count {
            let p = pts[i]
            if let hsv = BallColor.sampleHSV(pixelBuffer,
                                             atNormalized: CGPoint(x: p.x, y: p.y),
                                             radiusPx: 4) {
                total += 1
                if profile.matches(h: hsv.h, s: hsv.s, v: hsv.v) { matched += 1 }
            }
            i += stride
        }
        return total > 0 ? Double(matched) / Double(total) : 0
    }

    /// Rough speed: path length in normalized units → meters → per second → km/h.
    /// This is intentionally simple for Milestone 1; real accuracy comes with calibration.
    private func estimateSpeedKmh(points: [CGPoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        var pathLen: Double = 0
        for i in 1..<points.count {
            let dx = Double(points[i].x - points[i - 1].x)
            let dy = Double(points[i].y - points[i - 1].y)
            pathLen += (dx * dx + dy * dy).squareRoot()
        }
        let frames = Double(points.count - 1)
        let seconds = frames / Calibration.fps
        guard seconds > 0 else { return 0 }
        let meters = pathLen * Calibration.metersPerNormalizedUnit
        let metersPerSecond = meters / seconds
        return metersPerSecond * 3.6
    }
}
