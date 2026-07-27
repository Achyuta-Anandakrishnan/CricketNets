import SwiftUI
import simd

/// Shared state across tabs. Your field, ball calibration, tuning, and current session all persist
/// across launches so you don't have to set everything up again each time.
@MainActor
final class AppState: ObservableObject {

    @Published var field: Field = .standard()          { didSet { save(field, Key.field) } }
    @Published private(set) var shots: [ScoreResult] = [] { didSet { save(shots, Key.shots) } }
    @Published var lastShot: ScoreResult?

    /// The calibrated ball color. Nil = tracking anything that moves (picks up lots of noise).
    @Published var ballProfile: BallProfile?           { didSet { save(ballProfile, Key.ball) } }
    var isBallCalibrated: Bool { ballProfile != nil }

    // Field setup
    @Published var preset: Field.Preset = .standard    { didSet { UserDefaults.standard.set(preset.rawValue, forKey: Key.preset) } }
    @Published var hand: Field.Hand = .right           { didSet { UserDefaults.standard.set(hand.rawValue, forKey: Key.hand) } }

    /// Scoring "match conditions" the user can tune (outfield pace, catching difficulty).
    @Published var scoringParams = ScoringEngine.Params() { didSet { save(scoringParams, Key.params) } }

    /// Calibration flows into the detector's static config so the live speed HUD uses real numbers.
    /// Not persisted — it's tied to where the phone is physically set up, so recalibrate each session.
    @Published var calibration: SceneCalibration = .untuned {
        didSet { pushCalibrationToDetector() }
    }
    var isCalibrated: Bool { calibration.source != .untuned }

    init() { load() }

    // MARK: Field setup

    /// Rebuild the field from the current preset + hand, keeping the current boundary size.
    func applyPreset() {
        field = Field.preset(preset, hand: hand, boundaryRadius: field.boundaryRadius)
    }

    /// Change the ground size and pull any now-outside fielders back onto the rope.
    func setBoundary(_ radius: Double) {
        field.boundaryRadius = radius
        field.clampFieldersToBoundary()
    }

    // MARK: Scoring

    /// The end-to-end step for the fast 2D path: trajectory → launch vector → scored outcome.
    /// Azimuth is 0 here — a single side-on camera can't see left/right (see `BallPhysics`).
    func record(imagePoints: [CGPoint]) {
        guard let analysis = ShotAnalysis.from2D(imagePoints: imagePoints, calibration: calibration) else { return }
        record(launch: analysis.launch)
    }

    /// The LiDAR 3D path: depth-resolved world samples → launch vector → scored outcome.
    /// This is the one where azimuth is measured rather than assumed, so shots land across the
    /// wagon wheel instead of on a single line.
    func record(worldSamples: [BallPhysics.WorldSample], groundDirection: simd_float2) {
        guard let analysis = ShotAnalysis.from3D(worldSamples: worldSamples,
                                                 groundDirection: groundDirection) else { return }
        record(launch: analysis.launch)
    }

    /// Score a launch against the current field and add it to the session.
    func record(launch: LaunchVector) {
        let result = ScoringEngine.evaluate(launch: launch, field: field, params: scoringParams)
        lastShot = result
        shots.append(result)
    }

    /// Remove the most recent ball (e.g. a mis-tracked shot).
    func undoLastShot() {
        guard !shots.isEmpty else { return }
        shots.removeLast()
        lastShot = shots.last
    }

    /// Start a fresh net session.
    func resetSession() {
        shots.removeAll()
        lastShot = nil
    }

    // MARK: Persistence

    private enum Key {
        static let field = "cn.field", shots = "cn.shots", ball = "cn.ball"
        static let preset = "cn.preset", hand = "cn.hand", params = "cn.params"
    }

    private func save<T: Encodable>(_ value: T?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Restore the last session. Note these assignments DO fire the `didSet` saves — property
    /// observers are live by the time `init` calls this — so each launch harmlessly rewrites what
    /// it just read. Cheap enough to leave alone; don't add expensive work to those observers.
    private func load() {
        if let f = Self.decode(Field.self, Key.field) { field = f }
        if let sh = Self.decode([ScoreResult].self, Key.shots) { shots = sh; lastShot = sh.last }
        if let b = Self.decode(BallProfile.self, Key.ball) { ballProfile = b }
        if let p = Self.decode(ScoringEngine.Params.self, Key.params) { scoringParams = p }
        if let s = UserDefaults.standard.string(forKey: Key.preset), let p = Field.Preset(rawValue: s) { preset = p }
        if let s = UserDefaults.standard.string(forKey: Key.hand), let h = Field.Hand(rawValue: s) { hand = h }
    }

    private func pushCalibrationToDetector() {
        TrajectoryDetector.Calibration.metersPerNormalizedUnit = calibration.metersPerNormalizedUnit
        TrajectoryDetector.Calibration.fps = calibration.fps
    }
}
