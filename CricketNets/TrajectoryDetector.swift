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

    /// Calibration for turning image motion into real speed. Milestone 2 will derive this
    /// from a known reference (stump width = 0.2286 m) or LiDAR. For now it's a hand-tuned guess.
    enum Calibration {
        /// How many meters one full normalized unit (frame width) spans at the ball's plane.
        /// Placeholder: assumes the tracked plane is ~3 m wide in view. Tune against a known distance.
        static var metersPerNormalizedUnit: Double = 3.0
        /// Capture frame rate; used to convert per-frame motion into per-second speed.
        static var fps: Double = 120
    }

    /// A real shot streaks across the frame; noise barely moves. Trajectories whose points span
    /// less than this (fraction of the frame) are rejected. Kept low so real shots aren't lost.
    var minTrajectoryMotion: Double = 0.03

    /// Minimum confidence Vision must report for a trajectory to be considered.
    var minConfidence: Float = 0.3

    /// Toggle the color gate independently of whether a ball is calibrated (for the Testing screen).
    var colorGateEnabled = true

    /// EXPERIMENTAL and OFF by default: feeding a difference-image to Vision can suppress detection
    /// entirely, so we track the raw frame. Toggle on in Testing mode only to compare.
    var useMotionMask = false

    /// When true, `process` also reports every candidate + its verdict for the Testing overlay.
    var debugMode = false

    private lazy var request: VNDetectTrajectoriesRequest = {
        // Short length so fast shots register (they're only in view for a few frames); a generous
        // size range so a small, far ball still counts. These are set once — the request is stateful.
        let req = VNDetectTrajectoriesRequest(frameAnalysisSpacing: .zero,
                                              trajectoryLength: 5)
        req.objectMinimumNormalizedRadius = 0.003
        req.objectMaximumNormalizedRadius = 0.20
        return req
    }()

    /// Serialize Vision calls; the stateful request is not thread-safe across frames.
    private let visionQueue = DispatchQueue(label: "cricketnets.vision")

    /// When set (via ball calibration), trajectories whose blob isn't the ball's color are rejected.
    /// This is what stops the tracker from locking onto hands, the bat, or people in the background.
    var ballProfile: BallProfile?

    private let masker = MotionMasker()

    /// Clear the motion history when tracking (re)starts. Runs on the vision queue to avoid racing
    /// the per-frame masking.
    func resetMotion() { visionQueue.async { [weak self] in self?.masker.reset() } }

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
    private static func pathLength(_ points: [VNPoint]) -> Double {
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
    private static func colorFraction(of obs: VNTrajectoryObservation,
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
