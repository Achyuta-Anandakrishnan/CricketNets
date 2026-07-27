# CricketNets — Product Description

## What it is
CricketNets turns solo or small-group **net practice** into scored practice. You set a field
(where your fielders stand), the phone's camera tracks the ball off the bat, and every shot is
scored against that field — **6, 4, caught, or runs** — with a running wagon wheel and session stats.

It's a batting-feedback tool: instead of hitting balls into a net with no consequence, you find out
what each shot *would have done* against a real field. Move a fielder into the gap you keep hitting,
and watch those boundaries turn into catches.

## Who it's for
- **Batters** practicing alone or in nets who want feedback, not just reps.
- **Coaches** who want a shot map and simple metrics (strike rate, boundary %, dismissals) from a session.
- **Casual players** who want a fun, competitive layer on net sessions.

Target device: **iPhone 16 Pro** (240 fps slow-motion capture + LiDAR). Other recent iPhones work
with reduced accuracy; LiDAR features degrade gracefully.

## The core idea
The magic is in one question: *given where the ball left the bat, what happens against your field?*
Nets only show ~1–2 m of ball flight, so the app measures the launch (speed, angle, direction) and
**simulates the rest** — flight with air drag, bounce, and roll — then scores it.

This means results are a good **estimate**, not Hawk-Eye. That's the honest, deliberate scope: useful
and motivating for practice, not a broadcast officiating tool.

## How it works (pipeline)
```
Camera (240fps)
  → VNDetectTrajectories        detect the ball's parabolic path in the image
  → Ball color gate             reject anything that isn't the calibrated ball (hands, bat, people)
  → Calibration (LiDAR/ref)     convert image motion into real speed + geometry
  → BallPhysics                 launch vector: speed, launch angle, azimuth
  → ScoringEngine               simulate flight + bounce + roll vs your field → outcome
  → Wagon wheel + stats         plot the shot, update the session
```

## Features today
| Area | What you get |
|------|--------------|
| **Nets tab** | Live camera, trajectory overlay, speed readout, auto-scored shots, ball + depth calibration |
| **Field tab** | Drag 10 fielders + keeper anywhere; standard preset (right/left-hander); slider "test shot" |
| **Stats tab** | Wagon wheel (shots colored by outcome), runs, balls, strike rate, 4s/6s, wickets, dots, boundary % |

The Field and Stats tabs are fully usable **without the camera** (great in the Simulator); the Nets
tab and calibration need the physical device.

## What makes it credible
- The **scoring engine is a real physics simulation** (drag, multi-bounce, rolling friction), not a
  lookup table — verified to produce sensible cricket outcomes.
- **Field placement genuinely changes the score** — the same shot is a catch or a four depending on
  where you put fielders. That's the product promise, and it's real.

## Known limitations (by design or pending)
- Left/right **azimuth from a single 2D camera is approximate**; true 3D needs the LiDAR path.
- Scoring is an **estimate** extrapolated from a short net trajectory.
- **Ball tracking accuracy is the biggest open risk** and the thing most in need of real-device testing.
- See `ROADMAP.md` for the current stability issues and plan.
