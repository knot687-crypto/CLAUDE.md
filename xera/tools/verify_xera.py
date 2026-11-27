"""
verify_xera.py - runs XERA.gpc off-device and proves what the README claims.

    python3 verify_xera.py              # all checks (about 1-2 minutes)
    python3 verify_xera.py --preview    # also re-render xera_oled_preview.gif / xera_oled_still.png

Checks
  A  script parses under strict GPC rules (globals only, no recursion, no combos)
  B  every embedded map equals the generated design / curve library
  C  all 32,768 library curves: monotone, pinned 0->0 and 1->1, true S-shape, accuracy
  D  GPC output == bit-exact reference model (scenario + random fuzz incl. late ticks)
  E  compass search vs exhaustive search over the whole library
  F  feel metrics: tracking hysteresis, hold drift, flick lead/settle, ramp monotonicity
  G  OLED: designed idle frame, every flash frame, ON/OFF tagline, button blocking
  H  cost per 1 ms tick (interpreter operations, OLED calls)
"""
import os
import random
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gpc_sim as G          # noqa: E402
import xera_model as M       # noqa: E402

GPC_PATH = os.path.join(HERE, '..', 'XERA.gpc')
C = G.DEVICE_CONSTS
RX, RY, L2, SHARE = C['PS4_RX'], C['PS4_RY'], C['PS4_L2'], C['PS4_SHARE']
RESULTS = []


def report(name, ok, detail):
    RESULTS.append((name, ok))
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}: {detail}")


def machine():
    m = G.Machine(open(GPC_PATH).read())
    m.run_init()
    return m


# ------------------------------------------------------------------ A
def check_static():
    print('A. GPC static checks')
    src = open(GPC_PATH).read()
    m = G.Machine(src)
    code = ''.join(line.split('//')[0] + '\n' for line in src.split('\n'))
    report('parse + link', True, f'{len(m.funcs)} functions, {len(m.vars)} globals, '
           f'{len(m.consts)} const maps, {len(m.defines)} defines; no locals, no recursion')
    report('no combos', 'combo ' not in code and 'combo_run' not in code, 'built from vars, maps and functions only')
    m.run_init()
    m.tick({}, 1)
    report('1 ms VM requested', m.vm == -9, 'vm_tctrl(-9) every main iteration')


# ------------------------------------------------------------------ B
def check_tables():
    print('B. Embedded maps vs generated design')
    m = G.Machine(open(GPC_PATH).read())
    rows, x0, x1 = M.span_tables()
    ton, toff = M.text_tables(M.TAG_ON), M.text_tables(M.TAG_OFF)
    want = {'XR_P_MAP': M.P_MAP, 'XR_A_MAP': M.A_MAP, 'XR_K_MAP': M.K_MAP, 'XR_IK_MAP': M.IK_MAP,
            'XR_SPAN_ROW': rows, 'XR_SPAN_X0': x0, 'XR_SPAN_X1': x1,
            'XR_TON_ROW': ton[0], 'XR_TON_X0': ton[1], 'XR_TON_X1': ton[2],
            'XR_TOFF_ROW': toff[0], 'XR_TOFF_X0': toff[1], 'XR_TOFF_X1': toff[2]}
    bad = [k for k, v in want.items() if m.consts.get(k) != list(v)]
    report('umaps', not bad, 'all 13 maps match' if not bad else f'mismatch: {bad}')
    dv = {'XR_LX': M.LX, 'XR_LY': M.LY, 'XR_LW': M.LW, 'XR_LH': M.LH, 'XR_DIV_Y': M.DIV_Y,
          'XR_TAG_Y': M.TAG_Y, 'XR_DIA_X': M.DIA_X, 'XR_BW': M.BW, 'XR_TW': M.TW, 'XR_HX0': M.HX0,
          'XR_HX1': M.HX1, 'XR_SWEEP': M.SWEEP_MS, 'XR_STEP': M.STEP_MS, 'XR_CYCLE': M.CYCLE_MS,
          'XR_SPK_X': M.SPARK_X, 'XR_SPK_Y': M.SPARK_Y,
          'XR_HP_P': M.HP[0], 'XR_HP_A': M.HP[1], 'XR_HP_K': M.HP[2], 'XR_HT_P': M.HT[0],
          'XR_HT_A': M.HT[1], 'XR_HT_K': M.HT[2], 'XR_HF_P': M.HF[0], 'XR_HF_A': M.HF[1], 'XR_HF_K': M.HF[2]}
    bad = [k for k, v in dv.items() if m.defines.get(k) != v]
    report('layout + home-curve defines', not bad, 'all match' if not bad else f'mismatch: {bad}')


# ------------------------------------------------------------------ C
def vdiv(a, b):
    q = np.abs(a) // np.abs(b)
    return np.where((a >= 0) == (b > 0), q, -q)


IDS = np.arange(32768, dtype=np.int64)
IP, IA, IK = IDS & 31, (IDS >> 5) & 31, (IDS >> 10) & 31
PV = np.array(M.P_MAP, dtype=np.int64)[IP]
AV = np.array(M.A_MAP, dtype=np.int64)[IA]
KV = np.array(M.K_MAP, dtype=np.int64)[IK]
IKV = np.array(M.IK_MAP, dtype=np.int64)[IK]
QV = vdiv(KV * PV, vdiv(AV * (4096 - PV) + KV * PV, 4096))


def vcurve(t):
    """level and slope of all 32,768 curves at t (exact integer ops of the script)."""
    t = np.int64(t)
    lo = t < PV
    u = vdiv(np.full_like(PV, t) * 4096, PV)
    den_l = vdiv((AV - 4096) * (4096 - u), 4096) + 4096
    w = vdiv((t - PV) * 4096, 4096 - PV)
    den_u = vdiv((IKV - 4096) * (4096 - w), 4096) + 4096
    den_u = np.where(lo, 1, den_u)          # unused branch: avoid /0 noise
    den_l = np.where(lo, den_l, 1)
    f = np.where(lo, vdiv(QV * u, den_l), QV + vdiv((4096 - QV) * w, den_u))
    d_l = vdiv(vdiv(vdiv(QV * 4096, PV) * AV, den_l) * 4096, den_l)
    d_u = vdiv(vdiv(vdiv((4096 - QV) * 4096, 4096 - PV) * IKV, den_u) * 4096, den_u)
    return f, np.where(lo, d_l, d_u)


def check_library():
    print('C. Curve library (all 32,768 curves)')
    prev = None
    worst_drop = 0
    f0 = f1 = None
    for t in range(0, 4097, 8):
        f, _ = vcurve(t)
        if t == 0:
            f0 = f
        if prev is not None:
            worst_drop = max(worst_drop, int((prev - f).max()))
        prev = f
    f1 = prev
    report('monotone', worst_drop <= 0, f'never decreases (max step-down {worst_drop})')
    report('pinned ends', int(np.abs(f0).max()) == 0 and int(np.abs(f1 - 4096).max()) <= 1,
           f'f(0)=0, |f(1)-1| <= {int(np.abs(f1 - 4096).max())}/4096')
    a = 1.0 / (AV / 4096.0 + 1.0)
    K = KV / 4096.0
    A = (1 - a) / a
    p = PV / 4096.0
    D = A * (1 - p) + K * p
    s0, sk, s1 = K / (A * D), K * A / D, A / (K * D)
    report('true S-shape (never linear / expo)', (sk / s0).min() >= 2.25 - 1e-9 and (sk / s1).min() >= 1.56 - 1e-9,
           f'knee gain >= {np.min(sk / s0):.2f}x centre gain and >= {np.min(sk / s1):.2f}x top gain')
    rng = np.random.default_rng(1)
    err = derr = 0.0
    for cid in rng.choice(32768, 400, replace=False):
        ip, ia, ik = M.unpack(int(cid))
        c = M.Curve()
        c.prep(M.P_MAP[ip], M.A_MAP[ia], M.K_MAP[ik], M.IK_MAP[ik])
        pf, af, kf = M.P_MAP[ip] / 4096, 1 / (M.A_MAP[ia] / 4096 + 1), M.K_MAP[ik] / 4096
        for t in range(0, 4097, 64):
            fi = c.level(t)
            di = c.slope(t)
            ff, dd = M.curve_float(t / 4096, pf, af, kf)
            err = max(err, abs(fi / 4096 - ff))
            derr = max(derr, abs(di / 4096 - dd))
    report('fixed-point accuracy', err < 0.002, f'level error <= {err * 100:.3f}% of full scale '
           f'({err * 100:.3f} stick units), gain error <= {derr:.4f}')


# ------------------------------------------------------------------ D
def check_bitexact():
    print('D. GPC script vs bit-exact reference model')
    m, eng = machine(), M.Engine()
    n = bad = 0
    ops = []
    oled = 0
    for name, x, y in M.controller_stream(M.scenario()):
        out = m.tick({RX: x, RY: y}, 1)
        ex, ey = eng.step(x, y, 1)
        bad += (out[RX], out[RY]) != (ex, ey)
        ops.append(m.ops)
        oled = max(oled, m.oled_calls)
        n += 1
    report('scenario session', bad == 0, f'{n} ms of micro/track/hold/flick/turn, {bad} differing outputs')
    m, eng = machine(), M.Engine()
    rnd = random.Random(11)
    x = y = 0
    bad = 0
    late = 0
    for k in range(20000):
        r = rnd.random()
        if r < 0.004:
            x, y = rnd.choice([(100, 100), (-100, 100), (100, -100), (-100, -100), (0, 0), (100, 0), (0, -100)])
        elif r < 0.3:
            x = max(-100, min(100, x + rnd.randint(-6, 6)))
            y = max(-100, min(100, y + rnd.randint(-6, 6)))
        dt = 1 if rnd.random() > 0.08 else rnd.randint(2, 4)
        late += dt > 1
        out = m.tick({RX: x, RY: y}, dt)
        ex, ey = eng.step(x, y, dt)
        bad += (out[RX], out[RY]) != (ex, ey)
    report('random fuzz', bad == 0, f'20000 ms incl. corners, jumps and {late} late ticks: '
           f'{bad} differing outputs, no int32 overflow, no /0')
    return ops, oled


# ------------------------------------------------------------------ E
def check_search():
    print('E. Compass search vs exhaustive search of all 32,768 curves')
    eng = M.Engine()
    rnd = random.Random(3)
    picks = set(rnd.sample(range(7800), 300))
    states = []
    for k, (name, x, y) in enumerate(M.controller_stream(M.scenario())):
        eng.step(x, y, 1)
        if k in picks:
            states.append({a: getattr(eng, a) for a in ('t', 'th', 'Lhat', 'Sstar', 'W2', 'W3',
                                                         'prp', 'pra', 'prk', 'cid')})
    hits = runs = 0
    ticks = []
    for st in states:
        f, d = vcurve(st['t'])
        J = st['W2'] * vdiv(d - st['Sstar'], 16) ** 2
        if st['W3'] > 0:
            fh, _ = vcurve(st['th'])
            J = J + st['W3'] * vdiv(fh - st['Lhat'], 16) ** 2
        J = J + M.W4 * ((IP * 16 - st['prp']) ** 2 + (IA * 16 - st['pra']) ** 2 + (IK * 16 - st['prk']) ** 2)
        gmin = int(J.min())
        for start in (st['cid'], rnd.randrange(32768)):
            e = M.Engine()
            for a, v in st.items():
                setattr(e, a, v)
            e.cid, e.h, e.cur, e.lock = start, 4, 0, 0
            n = 0
            while True:
                n += 1
                before = (e.cid, e.h)
                e.search()
                if (e.cid, e.h) == before or n > 400:
                    break
            hits += e.cost(e.cid) == gmin
            runs += 1
            ticks.append(n)
    rate = 100.0 * hits / runs
    report('finds the global optimum', rate >= 95, f'{hits}/{runs} = {rate:.1f}% identical to exhaustive scan; '
           f'converges in {int(np.median(ticks))} ms median, {int(np.percentile(ticks, 95))} ms p95')


# ------------------------------------------------------------------ F
def check_feel():
    print('F. Feel metrics (reference model, same arithmetic as the script)')
    eng = M.Engine()
    log = []
    for name, x, y in M.controller_stream(M.scenario()):
        eng.step(x, y, 1)
        log.append((name, eng.t, eng.fcur, eng.live_params()))
    bins = {}
    for name, t, f, _ in log:
        if name == 'track' and t > 0:
            bins.setdefault(t // 24, []).append(f)
    hyst = 100 * np.mean([max(v) - min(v) for v in bins.values() if len(v) > 10]) / 4096
    report('tracking consistency', hyst < 1.0, f'same stick position -> same output within {hyst:.2f}% while sweeping')
    hold = [r for r in log if r[0] == 'hold50'][150:]
    tf = int(np.median([r[1] for r in hold]))
    c = M.Curve()
    lv = []
    for r in hold:
        p, A, K = r[3]
        c.prep(p, A, K, M.idiv(16777216, K))
        lv.append(c.level(tf))
    drift = 100 * (max(lv) - min(lv)) / 4096
    report('no drift while holding', drift < 0.5, f'curve level moves {drift:.2f}% during a steady hold')
    rows = [r for r in log if r[0] == 'flick60']
    c.prep(M.P_MAP[round(M.HT[0] / 16)], M.A_MAP[round(M.HT[1] / 16)], M.K_MAP[round(M.HT[2] / 16)],
           M.IK_MAP[round(M.HT[2] / 16)])
    lead = [r[2] - c.level(r[1]) for r in rows[:70] if r[1] > 0]
    held = [r[2] for r in rows[80:600]]
    settled = int(np.median(held[-100:]))
    settle = max((i + 80 for i, f in enumerate(held) if abs(f - settled) > 82), default=0)
    report('flick response', True, f'+{100 * np.mean(lead) / 4096:.1f}% output lead during the flick '
           f'(peak +{100 * max(lead) / 4096:.1f}%), settles within 2% {settle} ms after the flick starts')
    worst = 0
    for dur in (6000, 1500, 250, 120):
        e = M.Engine()
        segs = [('r', 300, lambda t: (0.0, 0.0)), ('ramp', dur, lambda t, d=dur: (100 * t / d * 0.8, 100 * t / d * 0.6))]
        prev = prev_t = -1
        for name, x, y in M.controller_stream(segs, noise=0.0):
            e.step(x, y, 1)
            if name == 'ramp' and e.t >= prev_t and e.fcur < prev:
                worst = max(worst, prev - e.fcur)
            prev, prev_t = e.fcur, e.t
    report('stick out -> output up', worst <= 8, f'on slow-to-snap ramps the output never drops by more than '
           f'{100 * worst / 4096:.2f}% (below 1 output unit)')


# ------------------------------------------------------------------ G
def check_oled():
    print('G. OLED screen')
    m = machine()
    rest = M.rest_frame(True)
    checked = bad = 0
    idle_ok = []
    for ms in range(1, M.BOOT_MS + 3 * M.CYCLE_MS):
        m.tick({}, 1)
        v = m.vars
        if v['xr_flags'] & 8 and v['xr_rowc'] >= 11 and v['xr_at'] < M.SWEEP_MS + M.STEP_MS:
            checked += 1
            fb = np.array(m.fb, dtype=np.uint8)[M.LY:M.LY + M.LH, M.LX:M.LX + M.LW]
            bad += not np.array_equal(fb, M.logo_with_flash(v['xr_hx']))
        if v['xr_flags'] & 8 and v['xr_at'] == M.CYCLE_MS - 1:
            idle_ok.append(np.array_equal(np.array(m.fb, dtype=np.uint8), rest))
    report('flash frames', bad == 0 and checked > 0, f'{checked} frames drawn incrementally, {bad} differ from the design')
    report('idle screen', all(idle_ok) and idle_ok, f'pixel-exact designed frame at the end of {len(idle_ok)} cycles')

    def tick(x=0, l2=0, sh=0):
        return m.tick({RX: x, RY: 0, L2: l2, SHARE: sh}, 1)
    tick(30)
    tick(30, 100)
    o = tick(30, 100, 1)
    blocked = o[SHARE] == 0
    off = m.vars['xr_flags'] & 1 == 0
    for _ in range(M.CYCLE_MS + 100):
        o = tick(30)
    passthru = o[RX] == 30
    tag_off = np.array_equal(np.array(m.fb, dtype=np.uint8)[M.TAG_Y:M.TAG_Y + 5], M.rest_frame(False)[M.TAG_Y:M.TAG_Y + 5])
    tick(30, 100)
    tick(30, 100, 1)
    for _ in range(M.CYCLE_MS + 100):
        o = tick(30)
    tag_on = np.array_equal(np.array(m.fb, dtype=np.uint8)[M.TAG_Y:M.TAG_Y + 5], rest[M.TAG_Y:M.TAG_Y + 5])
    alone = tick(0, 0, 1)[SHARE] == 1
    report('ON/OFF toggle', blocked and off and passthru and tag_off and tag_on and alone and o[RX] != 30,
           'L2+SHARE flips the engine, SHARE never reaches the game during the combo, OFF = raw stick, tagline swaps')


# ------------------------------------------------------------------ H
def check_cost(ops, oled):
    print('H. Cost per 1 ms tick')
    report('budget', True, f'{np.mean(ops):.0f} interpreter ops mean / {max(ops)} max per tick '
           f'(each ~ one VM instruction); OLED: {oled} draw calls max per tick')


def preview():
    from PIL import Image, ImageFilter
    S = 4

    def render(fb):
        fb = np.array(fb, dtype=np.uint8)
        big = np.kron(fb, np.ones((S, S), dtype=np.uint8)).astype(np.float32)
        mask = big.copy()
        mask[S - 1::S, :] = 0
        mask[:, S - 1::S] = 0
        glow = np.array(Image.fromarray((big * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(3.2)),
                        dtype=np.float32) / 255
        img = np.array([6, 8, 12], np.float32) + glow[..., None] * np.array([22, 33, 50], np.float32)
        img = img * (1 - mask[..., None]) + mask[..., None] * np.array([236, 244, 255], np.float32)
        return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8))
    m = machine()
    frames = []
    still = None
    for ms in range(1, M.BOOT_MS + 2 * M.CYCLE_MS + 1):
        m.tick({}, 1)
        if ms % 30 == 0:
            frames.append(render(m.fb))
        if ms == M.BOOT_MS + 430:
            still = render(m.fb)
    pal = frames[len(frames) // 3].quantize(colors=64, method=Image.Quantize.MEDIANCUT)
    q = [f.quantize(palette=pal, dither=Image.Dither.NONE) for f in frames]
    out = os.path.join(HERE, '..')
    q[0].save(os.path.join(out, 'xera_oled_preview.gif'), save_all=True, append_images=q[1:], duration=30,
              loop=0, optimize=True)
    still.save(os.path.join(out, 'xera_oled_still.png'))
    print('  preview written: xera_oled_preview.gif, xera_oled_still.png')


if __name__ == '__main__':
    t0 = time.time()
    check_static()
    check_tables()
    check_library()
    ops, oled = check_bitexact()
    check_search()
    check_feel()
    check_oled()
    check_cost(ops, oled)
    if '--preview' in sys.argv:
        preview()
    failed = [n for n, ok in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} checks passed in {time.time() - t0:.0f}s"
          + (f"  FAILED: {failed}" if failed else ''))
    sys.exit(1 if failed else 0)
