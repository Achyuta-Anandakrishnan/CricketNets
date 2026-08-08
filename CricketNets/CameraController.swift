import AVFoundation
import CoreMedia
import CoreVideo
import SwiftUI

/// Owns the fast AVFoundation capture session and finds the ball in every frame **by colour**.
///
/// This used to wrap `VNDetectTrajectoriesRequest`, and the reason it doesn't any more is the same
/// reason the 3D path stopped using it: that request only ever reports objects *already flying on a
/// parabola* in front of a still camera. It says nothing about a ball being held, thrown, or struck
/// until several frames of arc have accumulated — and when it says nothing there is no way to tell
/// "I can't see the ball" from "the ball isn't flying yet". A net session is mostly the first case.
///
/// Colour detection answers a smaller question honestly: where is the ball in *this* frame. Both
/// tracking paths now run the same three pieces — `BallDetector` finds it, `BallTracker` follows it
/// between frames, `ShotAssembler` decides which sightings were a shot — so tuning or fixing one
/// path fixes both, and the Ball Tracker screen is a true diagnostic for what happens in a match.
///
/// The trade against the 3D path is unchanged: this runs at 120 fps and cannot see depth, so speed
/// is the best available but left/right is not measured at all.
final class CameraController: NSObject, ObservableObject {

    // MARK: Published state for the UI (always mutated on the main thread)

    /// Where the ball was last seen, normalized to the capture buffer with a **top-left** origin.
    /// Nil means it wasn't found this frame; the overlay should clear rather than hold a stale mark.
    @Published var detection: BallDetector.Detection?
    /// True when the last sighting came from following the ball rather than a fresh full-frame scan.
    @Published var wasFollowed = false
    /// Recent sightings, oldest first — drawn as the shot's tail.
    @Published var trail: [CGPoint] = []
    /// Speed between the last two sightings, in km/h. This is the image-plane speed, so it is a
    /// lower bound on the true speed of anything hit toward or away from the camera.
    @Published var speedKmh: Double = 0
    /// True while a shot is being assembled, so the UI can flash/hold the result.
    @Published var hasTrajectory: Bool = false
    @Published var permissionDenied: Bool = false
    /// Dimensions of the frames actually being delivered, so an overlay can undo the preview's
    /// aspect-fill crop instead of assuming the buffer and the screen share a shape.
    @Published var frameSize = CGSize(width: 1080, height: 1920)
    /// Where frames are lost, in the order they can fail — the fast path's equivalent of the depth
    /// tracker's funnel, and the quickest way to see which stage is the one rejecting everything.
    @Published var funnel = Funnel()

    struct Funnel: Equatable {
        /// Frames handed to the detector.
        var framesSeen = 0
        /// Frames ball-coloured pixels were found in.
        var ballSeen = 0
        /// Of those, how many came from following the prediction rather than a full scan. A high
        /// share is what keeps a blurred ball in flight from dropping out.
        var followed = 0
        /// Found, but covering too much of the frame to be a ball — the colour gate is too loose.
        var tooBroad = 0

        /// The single most diagnostic number on this path: low means every frame is an independent
        /// strict scan of a motion-blurred target, which is the one thing that reliably fails.
        var followedShare: Double { ballSeen > 0 ? Double(followed) / Double(ballSeen) : 0 }
        var seenShare: Double { framesSeen > 0 ? Double(ballSeen) / Double(framesSeen) : 0 }
    }

    /// Called once, shortly after a shot's sightings stop arriving, with the samples worth scoring.
    /// Wire this to scoring. Fires on the main thread.
    var onShotCompleted: (([BallPhysics.WorldSample]) -> Void)?

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "cricketnets.session")
    private let videoOutput = AVCaptureVideoDataOutput()

    /// Capture frame rate we aim for. 120 is plenty to catch a ball and runs far cooler than 240
    /// (which, combined with per-frame detection, overheats the phone).
    private let targetFPS: Double = 120

    /// Configure the session only once; later start()s just resume it (e.g. after LiDAR borrowed
    /// the camera). Re-adding inputs/outputs would crash.
    private var isConfigured = false

    // MARK: Main-thread state

    private var assembler = ShotAssembler()
    private var settleWork: DispatchWorkItem?

    /// Speed above which movement counts as a struck shot rather than a carried ball.
    var minShotSpeed: Double {
        get { assembler.minShotSpeed }
        set { assembler.minShotSpeed = newValue }
    }

    /// How many recent sightings the drawn tail keeps.
    private let trailLength = 12

    /// Seconds until the tracker re-arms after a recorded shot. 0 = ready. Drives a countdown in the UI.
    @Published var cooldownRemaining = 0
    private let cooldownSeconds = 10
    private var cooldownTimer: Timer?

    /// Cooldown state as seen by the capture queue. `cooldownRemaining` is `@Published` and so may
    /// only be touched on the main thread; `captureOutput` runs on the session queue and needs the
    /// same answer, so it reads this lock-guarded mirror instead.
    private let cooldownLock = NSLock()
    private var _isCoolingDown = false
    private var isCoolingDown: Bool {
        get { cooldownLock.lock(); defer { cooldownLock.unlock() }; return _isCoolingDown }
        set { cooldownLock.lock(); _isCoolingDown = newValue; cooldownLock.unlock() }
    }

    // MARK: Detection configuration

    /// The calibrated ball, kept on the main thread so tolerance changes can be re-applied to it.
    private var baseProfile: BallProfile?

    /// What the tracker matches against, tolerances already scaled. Session-queue only.
    private var trackingProfile: BallProfile?
    /// Frame-to-frame continuity, so a blurred ball mid-flight isn't lost. Session-queue only.
    private var tracker = BallTracker()

    /// The ball's colour profile. Set from ball calibration.
    var ballProfile: BallProfile? {
        didSet { baseProfile = ballProfile; pushProfile() }
    }

    /// Multiplier on the calibrated tolerances — the same control the Ball Tracker screen exposes.
    var colourTolerance: Double = 1.0 { didSet { pushProfile() } }

    private func pushProfile() {
        // `loosened` is the single place tolerance scaling lives, so it stays correct whichever
        // colour space the profile is using. Scaling the HSV fields by hand here would silently do
        // nothing at all in chroma mode, which is the default.
        let scaled = baseProfile?.loosened(by: colourTolerance)
        sessionQueue.async { [weak self] in self?.trackingProfile = scaled }
    }

    /// Scene geometry for turning image positions into metres. Written from the main thread, read
    /// on the capture queue, hence the lock.
    private let calibrationLock = NSLock()
    private var _calibration: SceneCalibration = .untuned
    var calibration: SceneCalibration {
        get { calibrationLock.lock(); defer { calibrationLock.unlock() }; return _calibration }
        set { calibrationLock.lock(); _calibration = newValue; calibrationLock.unlock() }
    }

    /// Most recent frame, kept so the ball-calibration screen can sample the ball's colour.
    private let bufferLock = NSLock()
    private var latestBuffer: CVPixelBuffer?

    /// Sample the ball's colour from the centre of the current frame (called by ball calibration).
    func sampleBallColor(centerNormalized: CGPoint = CGPoint(x: 0.5, y: 0.5),
                         radiusNormalized: CGFloat = 0.06) -> BallProfile? {
        bufferLock.lock()
        let buffer = latestBuffer
        bufferLock.unlock()
        guard let buffer else { return nil }
        return BallColor.sampleProfile(buffer, centerNormalized: centerNormalized, radiusNormalized: radiusNormalized)
    }

    func resetCounters() { funnel = Funnel() }

    // MARK: Lifecycle

    private let captureID = UUID()

    func start() {
        // An ARSession elsewhere in the app would otherwise hold the back camera and this session
        // would come up black with no error.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            CaptureArbiter.shared.acquire(id: captureID, name: "Fast 2D tracking") { [weak self] in
                self?.stop()
            }
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async { self.permissionDenied = true }
                return
            }
            self.sessionQueue.async { self.configureAndRun() }
        }
    }

    func stop() {
        isCoolingDown = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            cooldownTimer?.invalidate()
            cooldownTimer = nil
            cooldownRemaining = 0
            settleWork?.cancel()
            assembler.reset()
            hasTrajectory = false
            detection = nil
            trail = []
        }
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
            self?.tracker.reset()
        }
    }

    // MARK: Configuration

    private func configureAndRun() {
        tracker.reset()   // don't follow a prediction left over from a previous session

        // Already set up? Just resume — this happens when returning from LiDAR calibration.
        if isConfigured {
            if !session.isRunning { session.startRunning() }
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .high

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        configureHighFrameRate(on: device)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        // Detection runs synchronously on this queue, so a frame that arrives while the previous
        // one is still being scanned is simply dropped. That is the backpressure — without it the
        // capture rate outruns detection and queued frames (each ~8 MB) pile up until the app dies.
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        // Rotate the delivered buffers upright, so image x runs across the preview and image y down
        // it. Everything downstream — the overlay, and the metric conversion in `planeSample` —
        // assumes that correspondence.
        if let connection = videoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90 // portrait
        }

        session.commitConfiguration()
        isConfigured = true
        session.startRunning()
    }

    /// Pick the fastest format the device supports at ~1080p and lock the frame duration to it.
    private func configureHighFrameRate(on device: AVCaptureDevice) {
        var best: AVCaptureDevice.Format?
        var bestFPS = 0.0
        var bestWidth = Int32.max
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width >= 1280, dims.width <= 1920 else { continue }
            for range in format.videoSupportedFrameRateRanges {
                let fps = range.maxFrameRate
                // Highest frame rate wins; at equal fps prefer the smaller frame (720p) to save
                // memory and heat.
                if fps > bestFPS || (fps == bestFPS && dims.width < bestWidth) {
                    bestFPS = fps; best = format; bestWidth = dims.width
                }
            }
        }
        guard let format = best else { return }
        let fps = min(targetFPS, bestFPS)
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            // Non-fatal: we just run at the default frame rate.
        }
    }

    /// Re-arm immediately, skipping the rest of the cooldown.
    func armNow() {
        cooldownTimer?.invalidate()
        cooldownTimer = nil
        cooldownRemaining = 0
        isCoolingDown = false
        sessionQueue.async { [weak self] in self?.tracker.reset() }
    }

    /// After a shot is recorded, ignore tracking for a few seconds so retrieving the ball / the net
    /// rebound doesn't register, then re-arm for the next ball.
    private func beginCooldown() {
        detection = nil
        trail = []
        hasTrajectory = false
        cooldownRemaining = cooldownSeconds
        isCoolingDown = true
        sessionQueue.async { [weak self] in self?.tracker.reset() }
        cooldownTimer?.invalidate()
        cooldownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            cooldownRemaining -= 1
            if cooldownRemaining <= 0 {
                cooldownRemaining = 0
                isCoolingDown = false
                cooldownTimer?.invalidate()
                cooldownTimer = nil
            }
        }
    }
}

// MARK: - Frame delivery (session queue)

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Keep the latest frame available for ball-colour calibration.
        bufferLock.lock()
        latestBuffer = pixelBuffer
        bufferLock.unlock()

        // During the post-shot cooldown, don't track — let the ball be retrieved in peace.
        if isCoolingDown { return }

        // The capture clock, not a frame counter: dropped frames are normal (the detector loses the
        // ball, or a frame arrives while this one is still being scanned) and a fixed 1/fps step
        // would quietly skew every velocity fit built on top.
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard time.isFinite else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let size = CGSize(width: width, height: height)

        guard let profile = trackingProfile else {
            // Nothing calibrated: there is no colour to look for, so say so rather than tracking
            // whatever moves — the old behaviour, which mostly found nets and clothing.
            publish(nil, followed: false, sample: nil, frameSize: size)
            return
        }

        // Follow the ball from where it was when possible; a full-frame scan is the fallback. This
        // is what keeps a motion-blurred ball from dropping out mid-flight.
        guard let hit = tracker.track(in: pixelBuffer, profile: profile, time: time) else {
            publish(nil, followed: false, sample: nil, frameSize: size)
            return
        }

        // A followed hit is already trusted — it was found where the ball was predicted to be, and
        // at a plausible size — so the frame-coverage check that guards a global scan doesn't apply.
        guard hit.followed || hit.detection.looksLikeABall else {
            publish(hit.detection, followed: false, sample: nil, frameSize: size, tooBroad: true)
            return
        }

        let aspect = height > 0 && width > 0 ? Double(height) / Double(width) : 1
        let sample = calibration.planeSample(at: hit.detection.center, frameAspect: aspect, time: time)
        publish(hit.detection, followed: hit.followed, sample: sample, frameSize: size)
    }

    /// Hop a frame's outcome to the main thread, where the published state and shot assembly live.
    private func publish(_ found: BallDetector.Detection?,
                         followed: Bool,
                         sample: BallPhysics.WorldSample?,
                         frameSize size: CGSize,
                         tooBroad: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            funnel.framesSeen += 1
            if found != nil {
                funnel.ballSeen += 1
                if followed { funnel.followed += 1 }
                if tooBroad { funnel.tooBroad += 1 }
            }
            detection = found
            wasFollowed = followed
            if frameSize != size { frameSize = size }

            if let found {
                trail.append(found.center)
                if trail.count > trailLength { trail.removeFirst(trail.count - trailLength) }
            } else {
                trail.removeAll(keepingCapacity: true)
            }

            guard let sample else { return }
            append(sample)
        }
    }
}

// MARK: - Shot assembly (main thread)

private extension CameraController {

    /// Feed a sighting to the assembler, which decides whether it's part of a shot.
    func append(_ sample: BallPhysics.WorldSample) {
        _ = assembler.add(sample)
        hasTrajectory = assembler.isTracking
        speedKmh = assembler.lastSpeed * 3.6
        scheduleSettleCheck(after: sample.time)
    }

    /// The ball going quiet produces no further sightings, so the end of a shot has to be noticed on
    /// a timer rather than on arrival of the next one.
    func scheduleSettleCheck(after sampleTime: TimeInterval) {
        settleWork?.cancel()
        guard assembler.isTracking else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // The assembler works in the sighting clock, so ask it as if that much time had passed.
            guard case .completed(let finished) = assembler.checkSettled(now: sampleTime + assembler.settleSeconds)
            else { return }
            hasTrajectory = false
            // Only record + cool down when a scoring handler is wired (a real match, not Testing).
            if let finished, let onShotCompleted {
                onShotCompleted(finished)
                beginCooldown()
            }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + assembler.settleSeconds, execute: work)
    }
}
