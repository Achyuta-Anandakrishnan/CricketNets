# CricketNets — Roadmap

## Done
- **M1 — Live trajectory + speed.** 120 fps capture, `VNDetectTrajectoriesRequest`, on-screen path.
- **M2 — Calibration.** LiDAR/reference scene calibration; launch vector (speed, angle, azimuth).
- **M3 — Field + scoring.** Draggable field, physics scoring (drag + bounce + roll), wagon wheel, stats.
- **Live path wired end-to-end.** Camera → calibration → scoring → result banner, automatically.
- **Ball calibration.** Color-gate that rejects non-ball motion (hands, bat, background).
- **Field presets + setup.** Standard / Attacking / Defensive / Spread, left/right-hander, boundary size.
- **Tunable match conditions.** Outfield pace + catching difficulty sliders feed the scoring.
- **Per-shot metrics + list.** Each ball records speed & launch angle; ball-by-ball list + top-speed stat.
- **Undo last shot.**
- **Persistence.** Field, ball calibration, tuning, and the current session survive relaunches.
- **3D (LiDAR) tracking mode.** Depth-resolved world samples → measured azimuth. Nets tab now picks
  between fast 2D (120 fps, no left/right) and 3D (~60 fps, real left/right).
- **Live HUD.** Mini shot map, speed / launch angle / direction pills, and a depth resolve-rate
  readout so 3D mode's failure modes are visible.

## Now — Stabilization (current focus)
The app works end-to-end but is buggy on device. Priorities, in order:

1. **Calibration freeze.**
   - *Likely cause A (fixed):* LiDAR (Depth) calibration fought the Nets camera for the back camera.
     Capture is now paused while the Depth sheet is open and resumed on dismiss.
   - *Likely cause B (to confirm on device):* Ball calibration hang while sampling the frame. Needs a
     repro — which button froze, and did the preview freeze or the whole UI?
2. **Tracking noise.** Layered filters now applied — verify on device:
   - **Motion masking** (`MotionMasker`): frame differencing so the detector only sees moving pixels.
   - Longer parabolas (trajectoryLength 8), a motion/displacement gate, and a tight multi-point color gate.
   - Tuning dials if still off: `TrajectoryDetector.minTrajectoryMotion`, `minConfidence`, and
     `MotionMasker.contrast` / `brightness`.
3. **Session lifecycle.** Verify camera start/stop across tab switches, backgrounding, and sheets
   doesn't leak or double-configure.

## Next — Accuracy & trust
- **Verify the metric scale** on device against a tape measure (the LiDAR landscape ↔ tracking
  portrait reconciliation flagged in `LiDARCalibrator`).
- **Verify 3D mode on device.** The maths is unit-tested, but whether LiDAR actually resolves a
  cricket ball at net range is unproven — watch the resolve rate in the HUD.
- **Tune scoring feel** with real shots; expose a couple of `ScoringEngine.Params` in a debug panel.

## Later — Product depth
- **Save/name custom fields** (beyond the built-in presets — store a dragged field under a name).
- **Replay the tracked path** of a past shot from the ball-by-ball list.
- **Session history** across days; export/share a wagon wheel.
- **Over/innings structure** — group balls into overs, end an innings on a wicket.
- **Bowling machine mode** — score a whole simulated over.
- **Multi-batter profiles.**

## Testing
- Unit tests cover the pure logic (scoring, physics transitions, color matching, stats) — see
  `CricketNetsTests/`. Run with **⌘U** in Xcode.
- The camera/AR layers need on-device manual testing; track a manual test checklist here as it grows.

## Known issues
| Issue | Severity | Status |
|-------|----------|--------|
| Memory crash (killed for memory) during tracking | High | Fixed: frame backpressure (one frame in flight); 720p preferred over 1080p |
| Phone heats up / freezes during tracking | High | Camera runs only during a match; 120 fps; pipeline skipped during cooldown. Verify on device |
| Freeze when opening a calibration screen | High | Depth camera conflict fixed; ball calibration runs its own short-lived session |
| Tracking picks up non-ball motion | High | Motion mask + gates; **Testing mode** added to see + tune live |
| Filters too strict (real shots rejected) | High | Defaults loosened (motion 0.06, conf 0.5, len 6); tune in Testing mode |
| Azimuth (left/right) unmeasurable from one 2D camera | Medium | Fixed the fake value (was pinned to ±45°); 2D now reports 0, and **3D mode measures it for real** |
| LiDAR may not resolve a ball at net range | High | Unproven — ball-sized depth patch + a resolve-rate readout to make it visible on device |
| Colour gate rejected everything in 3D mode | High | Fixed: ARKit delivers bi-planar YCbCr, not BGRA, so the sampler was reading out of bounds and returning grey. `BallColor` now handles both formats |
| Speed uncalibrated until Depth/reference set | Medium | Working as intended; calibrate to fix |
| `xcodebuild` CLI broken in this env (Xcode components) | Low | No longer reproducing — CLI build + `test` both succeed against an iPhone 16 Pro simulator |
