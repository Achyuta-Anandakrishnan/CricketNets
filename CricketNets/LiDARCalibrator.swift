import ARKit
import Combine
import simd

/// Uses the iPhone 16 Pro's LiDAR (ARKit scene depth) to measure the scene geometry needed
/// for calibration — the distance to the ball's flight plane and the metric scale there.
///
/// This runs as a SHORT, separate "calibrate" step, not during live 240fps tracking. Point the
/// phone where the ball will fly (down the net / at the crease), tap Calibrate, then switch back
/// to the fast 2D tracker which reuses the numbers this produced.
@MainActor
final class LiDARCalibrator: NSObject, ObservableObject, ARSessionDelegate {

    /// Live distance (m) to whatever is in the centre of frame — shown while aiming.
    @Published var centerDistance: Double = 0
    @Published var isRunning = false
    @Published var isSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)

    let session = ARSession()

    // Latest per-frame scalars we need for calibration. We copy these out each frame rather than
    // retaining the ARFrame (ARKit limits the frame pool and warns against holding frames).
    private var lastCenterDepth: Float = 0
    private var lastFocalX: Float = 0          // fx from camera intrinsics (captured-image pixels)
    private var lastImageWidth: Float = 0      // captured image width in pixels

    func start() {
        guard isSupported else { return }
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics.insert(.sceneDepth)
        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
    }

    func stop() {
        session.pause()
        isRunning = false
    }

    /// Produce a calibration from the most recent LiDAR frame.
    ///
    /// Scale derivation: at plane distance `d`, one captured-image pixel spans `d / fx` meters,
    /// so a full image width (W pixels) spans `d * W / fx` meters — that's meters-per-normalized-unit.
    ///
    /// NOTE: `fx`/`W` here are in the ARKit captured image's native (landscape) space, while the
    /// fast tracker feeds Vision portrait-rotated frames. The metric *scale* is orientation-agnostic
    /// (it's meters per full frame width), but verify on device — this is the one number worth
    /// sanity-checking against a tape measure the first time.
    func makeCalibration(cameraHeight: Double, fps: Double) -> SceneCalibration? {
        guard lastCenterDepth > 0, lastFocalX > 0, lastImageWidth > 0 else { return nil }
        let d = Double(lastCenterDepth)
        let metersPerNormalizedUnit = d * Double(lastImageWidth) / Double(lastFocalX)
        return SceneCalibration(
            metersPerNormalizedUnit: metersPerNormalizedUnit,
            planeDistance: d,
            cameraHeight: cameraHeight,
            fps: fps,
            source: .lidar
        )
    }

    // MARK: ARSessionDelegate

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let depthMap = frame.sceneDepth?.depthMap else { return }
        let centerDepth = Self.depth(atNormalized: CGPoint(x: 0.5, y: 0.5), in: depthMap)
        let fx = frame.camera.intrinsics.columns.0.x
        let imageWidth = Float(CVPixelBufferGetWidth(frame.capturedImage))

        Task { @MainActor in
            self.lastCenterDepth = centerDepth
            self.lastFocalX = fx
            self.lastImageWidth = imageWidth
            self.centerDistance = Double(centerDepth)
        }
    }

    // MARK: Depth sampling + unprojection helpers

    /// Sample depth (meters) at a normalized point (0...1, top-left origin) in a depth map.
    /// Returns 0 where LiDAR has no reading (e.g. beyond ~5 m, its useful limit).
    nonisolated static func depth(atNormalized p: CGPoint, in depthMap: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        let w = CVPixelBufferGetWidth(depthMap)
        let h = CVPixelBufferGetHeight(depthMap)
        let x = min(max(Int(p.x * CGFloat(w)), 0), w - 1)
        let y = min(max(Int(p.y * CGFloat(h)), 0), h - 1)
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return 0 }
        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        let rowPtr = base.advanced(by: y * rowBytes)
        return rowPtr.assumingMemoryBound(to: Float32.self)[x]
    }

    /// Lift an image point + depth into a 3D point in camera-local meters.
    /// `imagePoint` is in captured-image pixels; `intrinsics` are that image's fx/fy/cx/cy.
    /// ARKit's camera looks down -Z, so a point in front of the lens gets z = -depth.
    nonisolated static func cameraSpacePoint(imagePoint: CGPoint, depth: Float, intrinsics: simd_float3x3) -> simd_float3 {
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y
        let x = (Float(imagePoint.x) - cx) * depth / fx
        let y = (Float(imagePoint.y) - cy) * depth / fy
        return simd_float3(x, y, -depth)
    }

    /// Transform a camera-local point into ARKit world space (y up).
    nonisolated static func worldPoint(cameraSpace: simd_float3, cameraTransform: simd_float4x4) -> simd_float3 {
        let p = cameraTransform * simd_float4(cameraSpace, 1)
        return simd_float3(p.x, p.y, p.z)
    }
}
