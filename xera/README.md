# XERA — Adaptive Curve Engine for Cronus Zen

![XERA on the Zen OLED](xera_oled_preview.gif)

*The Zen's 128×64 OLED while XERA runs. The script itself drew these frames in the GPC simulator.*

XERA replaces the fixed response curve on your aim stick with one that adapts every millisecond.
It reads where the stick is and how it is moving, then searches a library of
**1,073,741,824 (2^30) S-curves** for the one that fits that moment. The winning curve glides
in without a bump, and the search starts again on the next millisecond.

- **Script:** [`XERA.gpc`](XERA.gpc). Paste it into Zen Studio, compile, and program it to a slot.
- **Built from** bit-packed state variables (BVARS), unsigned `const` lookup maps (UMAPS) and functions. There are **no combos**.
- **Screen:** XERA in scanline letters with a light band that sweeps across the name. A glint rides the divider and a sparkle finishes each sweep. A scan-beam boot plays when the script loads, and the screen stays up the whole time the script runs.

## Quick start

1. Open `XERA.gpc` in Zen Studio, compile (32-bit, which is the default), and program it to a slot.
2. In game, set the stick response curve to **Linear** (or the flattest option) and the **deadzone as low as it goes**. XERA provides both.
3. That's it. XERA is **always on** from the moment the slot loads. It has no toggle, reads no buttons, and changes nothing except your aim stick.

| Setting | Default | What it does |
|---|---|---|
| `XR_DEADZONE` | 4 | Inner deadzone in stick %. Raise it only if your stick drifts. |
| `XR_ANTI_DZ` | 0 | Anti-deadzone in output %. Use it when the game forces its own deadzone. |
| `XR_OUTER` | 100 | Stick % that counts as full deflection. |
| `XR_GAIN_PREC` / `TRACK` / `FLICK` | 65 / 100 / 190 | Local gain (% of 1:1) the curve aims for while micro-aiming, tracking and flicking. |
| `XR_DITHER` | 0 | Set to 1 for stochastic rounding, which averages finer than 1% output steps. |
| `XR_PROBES` | 6 | Neighbour curves scored per ms. Lower it if Zen Studio shows a high CPU load. |
| `XR_LIMITER` | 1 | 1 = scale the search back if 1 ms ticks keep running late. 0 = bypass it: always the full search, even if ticks stretch. |
| `XR_AIM_X/Y` | RX / RY | The stick XERA drives (the right stick on both PlayStation and Xbox). |

## How it works

Everything runs in Q12 fixed point (4096 = 1.0), with no floating point and no combos.

1. **State estimation.** An α-β tracking filter (α = 0.25, β = 0.027) runs at 1 kHz on each axis. It turns the 250 Hz integer controller reports into smooth position and velocity. It also gives the stick speed and the radial velocity: whether the stick is moving outward, inward or around.
2. **Intent.** Fuzzy memberships built from smoothstep blend three regimes:
   - **Precision:** slow movement near the centre.
   - **Flick:** fast, outward movement. It has a 4 ms attack and a 6 ms release.
   - **Tracking:** everything else.
3. **The curve library.** Every candidate is a *dual-rational S-curve*, built from two Schlick bias segments joined at a knee `p` with matched slope. It is then stretched so it reaches full output at a *reach* `R`:

   ```
   f(t) = q·B(t/(pR) ; a)                   t < pR        (convex precision zone)
   f(t) = q + (1−q)·B((t/R−p)/(1−p) ; b)    pR ≤ t < R    (concave speed zone)
   f(t) = 1                                 t ≥ R         (full turn speed)
   B(u ; s) = u / ((1/s − 2)(1 − u) + 1)
   q = K·p / (A(1−p) + K·p),   A = (1−a)/a,   b = K/(1+K)
   ```

   The library has 4 axes:

   | Axis | What it shapes | Range | Levels |
   |---|---|---|---|
   | knee `p` | where the precision zone hands over to the speed zone | 0.18–0.70 | 256 |
   | depth `a` | how gentle the precision zone is | 0.18–0.40 | 256 |
   | drive `K` | how hard the speed zone pulls at the knee | 1.25–2.85 | 256 |
   | reach `R` | how far you must push to get full turn speed | 0.86–1.00 | 64 |

   256 × 256 × 256 × 64 = **1,073,741,824 distinct curves**. Each one has a 30-bit ID packed into a single BVAR. Every curve is monotone and C1-smooth up to its reach, and has a true inflection point. The knee gain is always at least **2.25×** the centre gain and **1.56×** the top gain. So no curve is linear, and none bends only one way the way an expo curve does.
4. **Cost of a curve** (lower is better). It adds three terms:
   - the error between the curve's gain at your current stick position and the gain the intent calls for;
   - during flicks, the error along the path the stick is predicted to take over the next 24 ms;
   - a small pull toward the intent's home shape, which keeps the problem well-posed.
5. **Search.** Each millisecond a compass (pattern) search scores the current best curve, 6 lattice neighbours and the intent's home curve. It moves to the best of them and halves its step (32 → 1) when nothing improves. At the finest step it also tries the 24 two-axis diagonal moves, so it can slide along valleys where, say, knee and drive must change together. When the intent shifts it widens the search again.
6. **Glide.** The winning curve's parameters pass through a two-stage, critically damped glide. It is fast during flicks (3 ms) and slow while you hold (16 ms), so the output never jumps under your thumb.
7. **Output.** The curve is applied to the stick's radial magnitude, so your aim direction is kept exactly. The deadzone is scaled, so leaving it causes no jump. The output is rounded to the nearest unit (or stochastically rounded when `XR_DITHER` is 1).

**About "thousands of curves every millisecond":** the Zen's GPC virtual machine cannot score thousands of curves in 1 ms. Even if it could, the stick would lag. XERA scores 7–8 curves each millisecond, which is roughly 7,400 per second. Because each search starts from the previous best curve, it walks straight to the right region of the billion-curve library. Each pick was checked against a scan of all 1,073,741,824 curves. It was **the exact best curve 75% of the time and never more than 0.36% off the best** (median 0%), and it locked on within 12 ms (25 ms at the 95th percentile). The other 25% are near-ties: with a billion curves, neighbouring curves differ by less than the rounding of the math.

**No repeats:** during the 7.8-second test session the engine settled on **1,278 different curves**. The old 32,768-curve library used 220 in the same session. The live curve glides continuously between them, so in practice it is never exactly the same curve twice.

## Verification

I couldn't compile the script in Zen Studio here; that is the one step still to do on your PC. Instead,
[`tools/verify_xera.py`](tools/verify_xera.py) runs the script in a strict GPC interpreter
([`tools/gpc_sim.py`](tools/gpc_sim.py)). The interpreter enforces global-only variables, no recursion,
32-bit overflow traps and C-style division, and emulates the Zen's I/O and 128×64 OLED. It compares the
script against a bit-exact reference model ([`tools/xera_model.py`](tools/xera_model.py)). For the
search check, [`tools/xera_exhaustive.c`](tools/xera_exhaustive.c) is compiled on the spot. It scans
all 1,073,741,824 curves with the script's exact integer math in about 2 seconds per stick moment.

```
python3 tools/verify_xera.py            # 22 checks, about 2 minutes
python3 tools/verify_xera.py --full     # + scans all 16.7M base curves in C, 40 search states
python3 tools/verify_xera.py --preview  # also re-renders the GIF and PNG
```

| Check | Result |
|---|---|
| Script output vs reference model | 0 differences over 7,800 ms of realistic aiming and 20,000 ms of random fuzzing (corners, jumps, late ticks). With the limiter bypassed, 6,000 ms of heavy overload still give 0 differences, with the full search on every tick |
| Integer safety | no int32 overflow and no division by zero anywhere |
| Curve library | all 16,777,216 base curves scanned in C: monotone, with f(0)=0 and f(1)=1. Reach is a monotone stretch, so this covers all 2^30 curves. S-shape bounds hold for every curve; fixed-point error ≤ 0.14% of full scale |
| Search vs exhaustive scan | in 80 runs on 40 real stick moments: exact best of all 1,073,741,824 in 75%; never more than 0.36% off; 12 ms median to lock on |
| Curve variety | 1,278 different curves chosen in a 7.8 s session (the 32K library used 220) |
| Tracking consistency | the same stick position gives the same output within 0.65% while sweeping |
| Holding still | the curve moves 0.00% during a steady hold |
| Flicks | 11.7% average output lead during the flick (21% at peak); output settles within 2% about 29 ms after the stick stops |
| Ramps | pushing the stick further never lowers the output by more than 0.05% (less than one output unit) |
| OLED | the boot scan-in, 2,337 flash frames and the idle screen are pixel-exact against the design |
| Inputs | every button, trigger and the left stick pass through unchanged; only the aim stick is modified |
| Cost | about 3,100 interpreter operations per tick on average (4,500 at p99, 4,920 at worst); at most 16 OLED calls in a single tick |

Two things still need checking on real hardware:

- **Zen Studio compile.** If it reports anything, send me the message and I'll fix it.
- **CPU load at 1 ms.** The billion-curve search costs about 20% more per tick than the old 32K library. The per-tick work has been trimmed several ways:
  - curve scoring is inlined;
  - neighbour curves are generated directly in the packed curve ID;
  - curve math is skipped when its weight is zero;
  - while you flick, the screen draws less, so the search always has the tick to itself.

  If the load is still high, lower `XR_PROBES` to 4 or 3. The built-in limiter also steps down automatically when ticks keep running late. Every filter is frame-rate independent, so the feel stays the same at a 2 ms tick.

  **Bypassing the limiter (`XR_LIMITER = 0`):** the search then always scores the full `XR_PROBES` curves.
  - If your Zen keeps up at 1 ms, nothing changes, because the limiter never engages.
  - If it can't keep up, bypassing doesn't make it faster: ticks stretch instead. The stick then updates every ~2 ms rather than every 1 ms. That is still faster than the ~4 ms between console controller reads, but it is not zero.

## Files

| File | Purpose |
|---|---|
| `XERA.gpc` | the script |
| `xera_oled_preview.gif`, `xera_oled_still.png` | the OLED animation, rendered from the script's own drawing calls |
| `tools/gpc_sim.py` | strict GPC interpreter with OLED emulation |
| `tools/xera_model.py` | bit-exact reference engine, curve library, logo and font design |
| `tools/xera_exhaustive.c` | exhaustive scan of all 1,073,741,824 curves (built by the verifier) |
| `tools/verify_xera.py` | the verification suite above |
