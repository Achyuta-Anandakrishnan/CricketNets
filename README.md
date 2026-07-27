# CricketNets — Milestone 1

Live ball-trajectory tracking for net practice on iPhone 16 Pro.
Point the phone at the net, hit a ball, and the app draws the ball's path and shows a (rough) speed.

This milestone proves the hard part works before we build the field + scoring on top.

## What's here

| File | Role |
|------|------|
| `CricketNetsApp.swift` | App entry point |
| `CameraController.swift` | AVFoundation capture at 120fps, feeds frames to the detector |
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
5. **Run on device** — the camera and high-frame-rate capture do **not** work in the Simulator, so plug in the iPhone 16 Pro and run there.

> **Frame rate:** the code targets **120 fps**, not 240 (`CameraController.targetFPS`). 240 combined with
> per-frame Vision overheated the phone and got the app killed for memory; 120 is still plenty to catch a
> ball. The device picks the fastest format it supports up to that.

## How to test it

- Put the phone on a **tripod**, side-on to the net (trajectory detection needs a stable camera).
- Good, even lighting — a fast dark ball in dim light is the enemy.
- Hit or throw a ball across the frame. The green path should snap onto it and `TRACKING` lights up.

## Known limits (by design at this stage)

- **Speed is uncalibrated.** It uses a placeholder scale (`Calibration.metersPerNormalizedUnit`). Real speed comes in Milestone 2 from a known reference (stump width = 0.2286 m) or LiDAR depth.
- **2D only.** We're tracking the ball in the image plane. Left/right field direction (azimuth) and true 3D come next, using the 16 Pro's LiDAR at net range.
- No field, no scoring yet — that's Milestone 3.

## Tuning knobs if detection is flaky

In `TrajectoryDetector.swift` (current defaults in brackets):
- `defaultMinRadius` / `defaultMaxRadius` [0.003 / 0.20] — the size gate used before a ball is calibrated. Widen if the ball isn't picked up, narrow if it locks onto the wrong thing. Once you calibrate a ball, `BallProfile.minRadius` / `maxRadius` [0.005 / 0.06] replace these.
- `trajectoryLength` [5] — raise for steadier (but slower-to-appear) paths.
- `minTrajectoryMotion` [0.03] — how far a path must span, as a fraction of the frame, to count as a shot.
- `minConfidence` [0.3] — lower to catch more, raise to reject noise.

The last two are also live sliders in **Testing mode**, which is the faster way to tune them.

## Milestone 2 — Calibration + LiDAR (added)

Turns the green line into real numbers: **speed, launch angle, and left/right azimuth**, plus a projected **landing point** on a full field.

| File | Role |
|------|------|
| `Calibration.swift` | `SceneCalibration` (metric scale + geometry), `CricketConstants`, `CalibrationStore` |
| `LiDARCalibrator.swift` | ARKit scene-depth session — measures plane distance + scale from LiDAR |
| `BallPhysics.swift` | 2D and 3D launch-vector estimation + projectile projection to a landing point |

### The key architecture decision

**High-frame-rate capture and LiDAR can't run together** — ARKit scene depth caps at 60fps. So on the fast path LiDAR is used as a short **calibration step**, not for live tracking:

1. Aim the phone down the net, tap **Depth** → `LiDARCalibrator` reads the distance to the ball's flight plane and derives meters-per-frame-width.
2. That `SceneCalibration` is held by `AppState`, which pushes it into `TrajectoryDetector.Calibration` so the fast **120fps 2D tracker** from M1 reports real speed.
3. Every tracked shot now reports real speed + elevation, and `BallPhysics` projects a landing point.

Two ways to calibrate:
- **LiDAR (auto):** `LiDARCalibrator.makeCalibration(...)` — point and tap.
- **Reference (manual):** `SceneCalibration.fromReference(...)` — mark two stumps in the frame (`CricketConstants.wicketWidth`). Works on non-LiDAR phones too.

### Honest limits at this stage
- **Azimuth is not measured on the 2D fast path — it is reported as 0 (straight).** A single side-on view genuinely cannot separate a square hit from a straight one: both trace the same path across the image, and the sign of the horizontal drift tells you which way *down the ground*, not which side of the wicket. The code no longer guesses. Real left/right needs the **LiDAR 3D path** — see "3D tracking" below, which is now built.
- **Speed from the 2D path is a lower bound** — it's the flight speed projected onto the image plane, so a ball hit toward or away from the camera reads slow. Elevation is directly observable and reliable.
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

## 3D tracking — azimuth becomes a measurement (added)

The Nets tab now has two modes, picked before you start:

| Mode | Frame rate | Speed | Left/right |
|------|-----------|-------|-----------|
| **Fast (2D)** | 120 fps | Best | **Not measured** — reported as straight |
| **3D (LiDAR)** | ~60 fps | Good | **Measured** |

They can't run together: ARKit's scene depth caps the camera around 60 fps, so the fast path trades
depth for frames and the depth path trades frames for depth.

| File | Role |
|------|------|
| `DepthTrajectoryTracker.swift` | ARKit session + Vision, unprojecting each trajectory point through the depth map into world space |
| `ShotHUD.swift` | Shared live readouts — mini field, metric pills, tracking badge, result banner |
| `DepthNetsView.swift` | The 3D mode screen |

### How it works
1. ARKit delivers a frame with `sceneDepth`. `VNDetectTrajectoriesRequest` runs on the captured image.
2. The newest point of the winning trajectory is looked up in **that same frame's** depth map, so
   every 3D point is unprojected with its own depth — no stale-depth mismatch.
3. Depth → camera space → ARKit world space. The samples are **timestamped**, because frames where
   the ball wasn't detected (or where LiDAR wasn't confident) are simply missing.
4. When points stop arriving, a least-squares fit across the samples gives velocity, with a gravity
   correction on the vertical axis, and azimuth is projected onto the direction you aimed.

### Set direction — don't skip it
Azimuth is measured **from wherever you tell the app "down the ground" is**. Point the phone down the
pitch and tap **Set direction** once per session. Without it, left/right is relative to an arbitrary
ARKit world axis and the wagon wheel will be rotated.

### Honest limits
- **LiDAR reaches ~5 m.** Beyond that, readings collapse and shots stop resolving. Stand the phone close.
- **A cricket ball is a few pixels in a 256×192 depth map.** Depth smoothing bleeds the background in,
  so the tracker takes the *nearest confident* reading in a small patch rather than the mean — the ball
  is always in front of what's behind it. This is the biggest accuracy risk in the mode.
- **Fewer frames means fewer samples.** A fast flat shot may not produce the 3 samples a fit needs.
  The HUD shows the resolve rate (`points/frames`) so this is visible rather than mysterious.
- **Not testable in the Simulator.** ARKit scene depth needs the device; the mode shows a clear
  "LiDAR unavailable" state elsewhere. The pure maths is covered by `DepthPathTests`.

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
