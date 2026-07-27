# Tracking — what works, what doesn't, and why

An honest account of the ball-tracking pipeline as it actually stands on device, written after the
first real testing sessions. The short version: **the pipeline is correct, and the problem is that a
struck shot gives it too few frames to work with.**

---

## Verified working on device

These aren't assumptions — each was confirmed on a real iPhone 16 Pro.

| Stage | Evidence |
|---|---|
| **Per-frame ball detection** | The ball tracker locks a ring onto a blue ball and follows it |
| **Depth resolution** | LiDAR returns a distance at the ball's position |
| **World unprojection** | — |
| **Metric scale** | — |
| **Frame timing** | — |

The last three share one piece of evidence, and it's the strongest result so far: **the accuracy
check measures gravity at about 9.81 m/s².**

That single number validates a surprising amount. A falling ball accelerates at 9.81 always, so for
the measurement to come out right, detection must be finding the real ball (not the net behind it),
depth must be the ball's distance, the unprojection from pixels to metres must be correctly scaled,
and the frame timestamps must be real. Get any one wrong and the number moves. It doesn't.

**So the geometry and the physics are right.** That rules out an entire category of suspicion.

---

## What isn't working

Shots aren't tracked reliably. Detection misses frames, and a hard shot doesn't produce enough
sightings to score.

### Is it hardware or software?

**Both, but the software half is the part that's actually blocking you right now.**

The clearest evidence is the contrast between the two things we've tested. A dropped ball tracks
fine. A struck ball doesn't. The difference between them:

| | Dropped ball | Struck shot |
|---|---|---|
| Speed | ~5 m/s | 30–45 m/s |
| Time in view | ~0.5 s | ~0.08 s |
| Frames available @60fps | ~30 | **3–6** |
| Motion blur | slight | heavy |

The pipeline works when it gets ~30 frames of a clean target. It fails at 3–6 frames of a blurred
one. That's not a broken pipeline — it's a pipeline being starved.

---

## Hardware limits (real, not fixable in code)

**1. ARKit caps scene depth at 60 fps.**
The binding constraint. A 160 km/h shot crosses the view in under 0.1 s:

| Shot | at 2.5 m | 3.5 m | 4.5 m |
|---|---|---|---|
| 120 km/h | 4.3 | 6.0 | 7.8 |
| 145 km/h | 3.6 | 5.0 | 6.4 |
| 160 km/h | 3.2 | 4.5 | 5.8 |

A launch vector needs 3 sightings minimum. There is very little headroom, and none once a frame
fails to resolve. **Check the Limits screen** — if AVFoundation's `builtInLiDARDepthCamera` offers a
depth-capable format above 60 fps, moving the depth path onto it roughly doubles every number above.
ARKit is only being used for camera pose, which a tripod doesn't need.

**2. LiDAR reaches ~5 m.**
Bounds how far back the phone can stand, which bounds how wide the view is, which bounds frames.

**3. LiDAR is 256×192.**
A cricket ball at 4 m is about 2 pixels of *radius* in the depth map. That's the edge of what the
sensor can resolve, and it's why depth sampling takes the nearest confident reading in a
ball-sized patch rather than an average — averaging drags the reading toward the background.

**4. Motion blur is physical.**
At 40 m/s the ball smears across roughly its own length during exposure. No colour space fixes this;
blur genuinely desaturates. It's why matching had to move to chroma and why the tracker has to
loosen its gate when following.

---

## Software issues

### Fixed, and this one was the likely blocker

**The search window was far too small to follow a fast ball.**

The tracker predicts where the ball will be and searches near there. But on the *first* follow after
acquiring, no velocity has been measured yet — so the prediction was simply "where it was". Meanwhile:

| Shot | Moves per frame @60fps, at 3.5 m |
|---|---|
| 30 km/h | 4.1% of view |
| 60 km/h | 8.3% |
| 100 km/h | 13.8% |
| 145 km/h | 20.0% |

The window was sized from the ball's radius: **±5.4%**. So for anything above walking pace the
follow always missed, the tracker fell back to the strict global scan, and velocity was never
established — meaning it *could never begin following a fast ball at all*. Every frame was an
independent strict scan, on a blurred target, which is the one thing that reliably fails.

Now: the first follow searches a wide window (±30%), and once velocity is known the window closes to
the ball plus a margin for acceleration. Because a wide window with a loose colour gate could grab
the wrong thing, follows also require the blob to be a **plausible size** — a ball's apparent radius
can't halve or double between frames, so size continuity does the discriminating that colour can't.

### Still open, in rough order of value

**Portrait lock costs ~25% of the view.**
Portrait means the capture's *short* axis (1440 px) spans the world horizontally: 51° of field of
view against landscape's 65°. Unlocking landscape is free frames. `project.yml` pins
`UISupportedInterfaceOrientations` to portrait.

**Acquisition uses a coarse stride.**
The global scan samples every 8th pixel. At 4.5 m the ball is only 3 cells across, so about 7 mask
pixels against a minimum of 4 — marginal. The first sighting of a shot is the hardest one to get,
and it's the one using the coarsest scan.

**`minSamplesPerShot` is 3.**
It could be 2 with a velocity-only fit (dropping the gravity correction, which over 0.08 s is
negligible anyway). Worth doing if frames stay scarce.

**Depth may lag a fast ball.**
LiDAR depth is temporally smoothed. A ball crossing quickly may get depth belonging to what was
behind it a moment ago. Unverified — the ball tracker's LiDAR-vs-ball-size comparison is the way to
check: if they diverge as the ball speeds up, this is real.

---

## Diagnosing on device

Each screen isolates one stage, so a failure can be located rather than guessed at.

| Screen | Answers | Read this |
|---|---|---|
| **Ball tracker** | Can we see the ball at all? | Ring locks on; LiDAR and ball-size distances agree |
| **Accuracy** | Are the numbers real? | Gravity ≈ 9.81 from a 1.5 m+ drop |
| **3D testing** | Is the funnel healthy? | `ball seen → 3D` close together; high **% followed** |
| **Limits** | What can the hardware do? | ARKit vs AVFoundation max fps |

**The single most diagnostic number is "% followed, not re-scanned"** in 3D testing. High means
continuity is working and shots should hold together. Low means every frame is an independent strict
scan — the failure mode described above.

If `ball seen` climbs but `3D` doesn't, it's depth: move closer than 5 m.
If `ball seen` doesn't climb, it's detection: raise the colour tolerance or recalibrate in the light
you're actually playing in.

---

## Ball colour

**Blue (current):** works. Distinctive against netting and turf.

**Red:** should be fine. Hue sits near 0 and the hue-circle wraparound is handled; chroma separates
red from grass cleanly.

**White: the hard case, and no colour space will fix it.** White has almost no chroma — that's what
"white" means — so it is genuinely indistinguishable from a sightscreen, pale netting, white
clothing or an overcast sky. This is recorded as a test rather than left to be discovered.

Three things will have to carry a white ball, and two already exist:

1. **Predicted-window tracking** — globally ambiguous, locally unambiguous, which is exactly the
   white-ball situation.
2. **Motion masking** (`MotionMasker`, in the repo, currently off) — a white ball against a white
   background is invisible to colour and obvious to frame differencing.
3. **A size gate against depth** — not built. We know the real ball diameter and, from LiDAR, its
   distance, so we can compute how large it *should* appear and reject anything else. A sightscreen
   at 4 m fails that instantly.

Worth building when you actually switch, not before — which of the three it needs is an empirical
question.

---

## Honest summary

The physics, geometry and scale are **verified correct** by the gravity measurement. Detection
**works** on a slow ball. What was broken was the tracker's ability to follow a fast one, and that
was a sizing bug rather than anything fundamental.

What remains genuinely hard is the frame budget. At 60 fps a hard shot gives 3–6 chances and every
one has to land. Whether that's workable depends on a question the Limits screen answers: **is there
a depth-capable capture path faster than ARKit's 60 fps on this device?**
