import Foundation

/// Guarantees that exactly one thing is using the camera at a time.
///
/// The app now has several capture owners — the fast 2D `CameraController` (AVCaptureSession), the
/// LiDAR calibrator, the depth tracker, the 3D testing screen, and the ball tracker (all ARSessions).
/// ARKit permits **one running ARSession per app**, and an ARSession and an AVCaptureSession both
/// want the back camera.
///
/// The failure mode when two overlap is the worst kind: no error, no exception, just a preview that
/// stays black while everything reports success. Presentation order between a `fullScreenCover`'s
/// `onAppear` and the presenter's `onChange` isn't guaranteed either, so "stop the old one before
/// starting the new one" can't be enforced at the call sites.
///
/// So ownership is centralised: acquiring the camera stops whoever held it, whenever that happens.
@MainActor
final class CaptureArbiter: ObservableObject {
    static let shared = CaptureArbiter()
    private init() {}

    private struct Holder {
        let id: UUID
        let name: String
        let stop: () -> Void
    }

    private var holder: Holder?

    /// Who currently holds the camera, for display while debugging.
    @Published private(set) var currentOwner: String?

    /// Take exclusive use of the camera, stopping the previous owner first.
    func acquire(id: UUID, name: String, stop: @escaping () -> Void) {
        if let existing = holder, existing.id != id {
            // Clear first so the outgoing owner's own `release` is a harmless no-op.
            holder = nil
            existing.stop()
        }
        holder = Holder(id: id, name: name, stop: stop)
        currentOwner = name
    }

    /// Give up the camera. Ignored if someone else has already taken over.
    func release(id: UUID) {
        guard holder?.id == id else { return }
        holder = nil
        currentOwner = nil
    }
}
