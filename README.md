# CricketNets — Milestone 1

Live ball-trajectory tracking for net practice on iPhone 16 Pro.
Point the phone at the net, hit a ball, and the app draws the ball's path and shows a (rough) speed.

This milestone proves the hard part works before we build the field + scoring on top.

## What's here

| File | Role |
|------|------|
| `CricketNetsApp.swift` | App entry point |
| `CameraController.swift` | AVFoundation capture at 240fps, feeds frames to the detector |
| `TrajectoryDetector.swift` | Wraps `VNDetectTrajectoriesRequest` (Apple's parabolic-path detector) |
| `ContentView.swift` | Camera preview + live trajectory overlay + speed HUD |

## Setup in Xcode (10 min)

1. **Create the project**: Xcode → New → Project → **iOS App**.
   - Product Name: `CricketNets`
   - Interface: **SwiftUI**, Language: **Swift**
2. **Add the files**: delete the auto-generated `ContentView.swift` / `App` file, then drag the four `.swift` files from `CricketNets/` into the project (check "Copy items if needed").
3. **Camera permission** (required or the app crashes on launch): in the target's **Info** tab add
   - Key: `Privacy - Camera Usage Description` (`NSCameraUsageDescription`)
   - Value: `Track the ball during net practice.`
4. **Signing**: Signing & Capabilities → select your Team.
5. **Run on device** — the camera and 240fps do **not** work in the Simulator, so plug in the iPhone 16 Pro and run there.

## How to test it

- Put the phone on a **tripod**, side-on to the net (trajectory detection needs a stable camera).
- Good, even lighting — a fast dark ball in dim light is the enemy.
- Hit or throw a ball across the frame. The green path should snap onto it and `TRACKING` lights up.

## Known limits (by design at this stage)

- **Speed is uncalibrated.** It uses a placeholder scale (`Calibration.metersPerNormalizedUnit`). Real speed comes in Milestone 2 from a known reference (stump width = 0.2286 m) or LiDAR depth.
- **2D only.** We're tracking the ball in the image plane. Left/right field direction (azimuth) and true 3D come next, using the 16 Pro's LiDAR at net range.
- No field, no scoring yet — that's Milestone 3.

## Tuning knobs if detection is flaky

In `TrajectoryDetector.swift`:
- `objectMinimumNormalizedRadius` / `objectMaximumNormalizedRadius` — widen if the ball isn't picked up, narrow if it locks onto the wrong thing.
- `trajectoryLength` — raise for steadier (but slower-to-appear) paths.
- confidence threshold (`> 0.5`) — lower to catch more, raise to reject noise.

## Milestone 2 — Calibration + LiDAR (added)

Turns the green line into real numbers: **speed, launch angle, and left/right azimuth**, plus a projected **landing point** on a full field.

| File | Role |
|------|------|
| `Calibration.swift` | `SceneCalibration` (metric scale + geometry), `CricketConstants`, `CalibrationStore` |
| `LiDARCalibrator.swift` | ARKit scene-depth session — measures plane distance + scale from LiDAR |
| `BallPhysics.swift` | 2D and 3D launch-vector estimation + projectile projection to a landing point |

### The key architecture decision

**240fps and LiDAR can't run together** — ARKit scene depth caps at 60fps. So LiDAR is used as a short **calibration step**, not for live tracking:

1. Aim the phone down the net, tap **Calibrate** → `LiDARCalibrator` reads the distance to the ball's flight plane and derives meters-per-frame-width.
2. That `SceneCalibration` flows into `CalibrationStore`, which feeds the fast **240fps 2D tracker** from M1.
3. Every tracked shot now reports real speed + elevation, and `BallPhysics` projects a landing point.

Two ways to calibrate:
- **LiDAR (auto):** `LiDARCalibrator.makeCalibration(...)` — point and tap.
- **Reference (manual):** `SceneCalibration.fromReference(...)` — mark two stumps in the frame (`CricketConstants.wicketWidth`). Works on non-LiDAR phones too.

### Honest limits at this stage
- **Azimuth from the 2D fast path is approximate** — a single 2D view can't fully separate a square hit from a straight one. Trustworthy left/right needs the **LiDAR 3D path** (`ShotAnalysis.from3D`). The 2D sign is still useful for "which side of the wicket."
- **Physics ignores air drag/swing** — real carry is a bit shorter at high speed. Fine for scoring zones; note it to users.
- **Verify the metric scale against a tape measure once** — the orientation reconciliation between the ARKit calibration pass (landscape) and the tracking pass (portrait) is the one number worth sanity-checking on device. Flagged in `LiDARCalibrator.makeCalibration`.

### Wiring it in
`CalibrationStore` writes the calibrated scale into the M1 detector's static config, so the existing speed HUD "just works" once calibrated. To show launch angle + landing, call `ShotAnalysis.from2D(imagePoints:calibration:)` with the detector's `trajectoryPoints` and display `launch.elevationDeg` / `landing.carry`.

## Milestone 3 — Field setup + scoring (added)

Set your field by dragging fielders, then every shot is scored against it.

| File | Role |
|------|------|
| `FieldModel.swift` | `Field` + `Fielder`, with a standard 10-position preset (right/left-hander) |
| `ScoringEngine.swift` | Steps the ball through its flight → `six / four / caught / runs` |
| `FieldView.swift` | Draggable top-down field + a Simulator-testable demo screen with sliders |

The app now has **two tabs**: **Nets** (live camera, M1/M2) and **Field** (setup + scoring).

### Try it right now — no device needed
The **Field** tab (`ScoringDemoView`) runs in the **Simulator**. Drag fielders around the ground, set speed / launch angle / azimuth with the sliders, tap **Hit the shot**, and watch the outcome + flight line update. This is how you tune the scoring before the camera is even involved.

### How scoring works
`ScoringEngine.evaluate(launch:field:)` simulates the ball in two phases:
- **Flight (parabola):** clearing the rope here on the full is a **six**; a fielder reaching it in the air is **caught**.
- **Ground (bounce + roll):** after the first bounce the ball skids and rolls, losing speed to the outfield (`bounceRetain`, `rollDecel`). A fielder in its path cuts it off for **runs**; reaching the rope is a **four**; otherwise it stops for **runs (0–3)** based on the gap and how deep it went.

This two-phase model is what lets boundaries score correctly — most 4s are hit along the ground and *roll* to the rope, not cleared on the full. All thresholds live in `ScoringEngine.Params` — tune them to taste (a lower `rollDecel` = faster outfield = more boundaries).

### The full pipeline is now connected
`camera → VNDetectTrajectories → SceneCalibration → BallPhysics.launchVector → ScoringEngine → ScoreResult`.
To go fully live, feed the detector's `trajectoryPoints` + the current `SceneCalibration` into `BallPhysics.launchVector(imagePoints:calibration:)`, then hand that `LaunchVector` to `ScoringEngine.evaluate` — same call the demo slider already makes.

## Live path connected (end-to-end)

The camera now scores real shots automatically against the field you set.

| File | Role |
|------|------|
| `AppState.swift` | Shared state across tabs: one `field`, one `calibration`, shot history |
| `CalibrationView.swift` | LiDAR aim-and-capture screen (the M2 calibration step, as UI) |

**How it flows:**
1. `CameraController` debounces the trajectory — when a shot's path stops updating for 0.4 s, it fires `onShotCompleted` once.
2. `AppState.record` runs `ShotAnalysis.from2D → ScoringEngine.evaluate` and publishes the result.
3. The **Nets** tab shows the outcome banner (SIX / OUT / runs) over the live view.

The **field you drag in the Field tab is the field the camera scores against** — they share `AppState.field`. Tap **Calibrate** on the Nets tab to run the LiDAR step; the status dot turns green and speeds become real.

> Note: the **Calibrate** screen uses ARKit, so it only works on the device (not the Simulator). The **Field** tab still works fully in the Simulator for tuning scoring.

## Ball calibration (rejecting non-ball motion)

`VNDetectTrajectoriesRequest` tracks *any* parabolic motion of roughly the right size — hands, the bat, people in the background. To lock onto the actual ball, tap **Ball** on the Nets tab and hold the ball in the ring:

- `BallProfile` / `BallColor` (`BallProfile.swift`) sample the ball's HSV color from the frame centre.
- `TrajectoryDetector` then **color-gates** every detection: it reads the pixels at each candidate trajectory's position and drops anything that isn't the ball's color (`profile.matches`). White balls fall back to brightness matching since their hue is unstable.
- Status shows on the Nets tab: **"Tracking the ball only"** (green) vs **"Tracking everything"** (orange).

Tune `hueTol` / `satTol` / `valTol` in `BallProfile` if it's too strict (misses the ball) or too loose (still catches noise).

## Roadmap

- **M1:** live trajectory + rough speed ✅
- **M2:** calibration (reference/LiDAR) → speed, launch angle, azimuth, landing point ✅
- **M3:** field setup UI + scoring engine (landing point → 4/6/caught/runs) ✅
- **Live path:** camera → calibration → scoring, wired end-to-end ✅
- **Stats + wagon wheel:** session totals + a shot map, both live and Simulator-testable ✅
- **Next:** save/name custom field presets; true-3D azimuth via the LiDAR tracking path; per-shot list & export

## Stats + wagon wheel (added)

A third **Stats** tab (`StatsView.swift`):
- **Wagon wheel** — lines radiate from the striker to each shot's landing point, colored by outcome (6 / 4 / runs / dot / out).
- **Tiles** — runs, balls, strike rate, 4s, 6s, wickets, dots, boundary %.
- **Reset** clears the session.

Every scored shot (camera *or* the Field tab's **Record shot** button) flows through `AppState.record(launch:)`, so you can populate the wagon wheel in the **Simulator** — set a shot with the sliders, tap Record, switch to Stats and watch it appear.
