import AVFoundation
import Vision
import CoreMedia
import SwiftUI

/// Owns the capture session, drives it at high frame rate, and hands each frame to the trajectory
/// detector. The session runs on its own queue; UI-facing state is published on the main thread.
final class CameraController: NSObject, ObservableObject {

    // MARK: Published state for the UI (always mutated on the main thread)
    /// The most recent trajectory, as normalized points (Vision space: origin bottom-left, 0...1).
    @Published var trajectoryPoints: [CGPoint] = []
    /// Estimated ball speed in km/h (rough until calibration is added — see `Calibration`).
    @Published var speedKmh: Double = 0
    /// True while a trajectory is actively being tracked, so the UI can flash/hold the result.
    @Published var hasTrajectory: Bool = false
    @Published var permissionDenied: Bool = false

    /// Called once, shortly after a shot's trajectory stops updating, with the completed path.
    /// Wire this to scoring. Fires on the main thread.
    var onShotCompleted: (([CGPoint]) -> Void)?

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "cricketnets.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let detector = TrajectoryDetector()

    /// Capture frame rate we aim for. 120 is plenty to catch a ball and runs far cooler than 240
    /// (which, combined with per-frame Vision, overheats the phone).
    private let targetFPS: Double = 120

    /// Configure the session only once; later start()s just resume it (e.g. after LiDAR borrowed
    /// the camera). Re-adding inputs/outputs would crash.
    private var isConfigured = false

    private var pendingShot: [CGPoint] = []
    private var settleWork: DispatchWorkItem?

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

    /// The ball's color profile. Forwarded to the detector so only ball-colored trajectories count.
    var ballProfile: BallProfile? {
        didSet { detector.setBallProfile(ballProfile) }
    }

    // MARK: Testing-mode passthroughs
    /// All candidate trajectories + verdicts from the last processed frame (only in debug mode).
    @Published var debugTrajectories: [DebugTrajectory] = []

    /// Main-thread copy of the detector's debug flag, so publishing the overlay doesn't have to
    /// reach into the detector's queue-confined state.
    private var debugModeEnabled = false

    func setDebugMode(_ on: Bool) { debugModeEnabled = on; detector.setDebugMode(on) }
    func setMinMotion(_ v: Double) { detector.setMinTrajectoryMotion(v) }
    func setMinConfidence(_ v: Double) { detector.setMinConfidence(Float(v)) }
    func setMotionMask(_ on: Bool) { detector.setUseMotionMask(on); detector.resetMotion() }
    func setColorGate(_ on: Bool) { detector.setColorGateEnabled(on) }

    /// Most recent frame, kept so the ball-calibration screen can sample the ball's color.
    private let bufferLock = NSLock()
    private var latestBuffer: CVPixelBuffer?

    /// Backpressure: only one frame is processed at a time. Without this, the capture rate outruns
    /// the detection pipeline and queued frames (each ~8 MB) pile up until the app is killed for memory.
    private let flightLock = NSLock()
    private var frameInFlight = false

    /// Sample the ball's color from the centre of the current frame (called by ball calibration).
    func sampleBallColor(centerNormalized: CGPoint = CGPoint(x: 0.5, y: 0.5),
                         radiusNormalized: CGFloat = 0.06) -> BallProfile? {
        bufferLock.lock()
        let buffer = latestBuffer
        bufferLock.unlock()
        guard let buffer else { return nil }
        return BallColor.sampleProfile(buffer, centerNormalized: centerNormalized, radiusNormalized: radiusNormalized)
    }

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
            self?.cooldownTimer?.invalidate()
            self?.cooldownTimer = nil
            self?.cooldownRemaining = 0
        }
        sessionQueue.async { [weak self] in self?.session.stopRunning() }
    }

    // MARK: Configuration

    private func configureAndRun() {
        detector.resetMotion()   // don't difference against a frame from a previous session

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
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        // Trajectory detection needs a consistent upright orientation.
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

    // MARK: Result handling (main thread)

    private func apply(_ result: TrajectoryResult?) {
        guard let result else { return }   // gaps between reports are normal mid-flight; ignore
        trajectoryPoints = result.points
        speedKmh = result.speedKmh
        hasTrajectory = true

        // A shot is "done" when the trajectory stops updating for a beat. Debounce, then score once.
        pendingShot = result.points
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Only record + cool down when a scoring handler is wired (a real match, not Testing mode).
            if self.pendingShot.count >= 3, let onShotCompleted = self.onShotCompleted {
                onShotCompleted(self.pendingShot)
                self.beginCooldown()
            }
            self.pendingShot = []
            self.hasTrajectory = false
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Re-arm immediately, skipping the rest of the cooldown.
    func armNow() {
        cooldownTimer?.invalidate()
        cooldownTimer = nil
        cooldownRemaining = 0
        isCoolingDown = false
        detector.resetMotion()
    }

    /// After a shot is recorded, ignore tracking for a few seconds so retrieving the ball / the net
    /// rebound doesn't register, then re-arm with a fresh motion background for the next ball.
    private func beginCooldown() {
        trajectoryPoints = []
        hasTrajectory = false
        cooldownRemaining = cooldownSeconds
        isCoolingDown = true
        cooldownTimer?.invalidate()
        cooldownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            cooldownRemaining -= 1
            if cooldownRemaining <= 0 {
                cooldownRemaining = 0
                isCoolingDown = false
                cooldownTimer?.invalidate()
                cooldownTimer = nil
                detector.resetMotion()   // start the next ball from a clean background
            }
        }
    }
}

// MARK: - Frame delivery

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Keep the latest frame available for ball-color calibration.
        if let image = CMSampleBufferGetImageBuffer(sampleBuffer) {
            bufferLock.lock()
            latestBuffer = image
            bufferLock.unlock()
        }

        // During the post-shot cooldown, don't track — let the ball be retrieved in peace.
        if isCoolingDown { return }

        // Drop this frame if the previous one is still being processed (bounds memory + heat).
        flightLock.lock()
        if frameInFlight { flightLock.unlock(); return }
        frameInFlight = true
        flightLock.unlock()

        detector.process(sampleBuffer) { [weak self] result, debug in
            guard let self else { return }
            flightLock.lock()
            frameInFlight = false
            flightLock.unlock()
            DispatchQueue.main.async {
                self.apply(result)
                if self.debugModeEnabled { self.debugTrajectories = debug }
            }
        }
    }
}
