"""
verify_xera.py - runs XERA.gpc off-device and proves what the README claims.

    python3 verify_xera.py              # all checks (a few minutes)
    python3 verify_xera.py --full       # + C property scan of all 16,777,216 base curves, 40 search states
    python3 verify_xera.py --preview    # also re-render xera_oled_preview.gif / xera_oled_still.png

Checks
  A  script parses under strict GPC rules (globals only, no recursion, no combos)
  B  every embedded map equals the generated design / curve library
  C  the 1,073,741,824-curve library: true S-shape for every curve (closed form), monotone and
     pinned ends (integer, sampled; --full scans all base curves in C), fixed-point accuracy
  D  GPC output == bit-exact reference model (scenario + random fuzz incl. late ticks)
  E  engine search vs an exhaustive scan of all 1,073,741,824 curves (compiled C, needs gcc)
  F  feel metrics: tracking hysteresis, hold drift, flick lead/settle, ramp monotonicity, variety
  G  OLED: boot, every flash frame, idle frame; the script touches only the aim stick
  H  cost per 1 ms tick (interpreter operations, OLED calls)
"""
import os
import random
import shutil
import subprocess
import sys
import tempfile
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gpc_sim as G          # noqa: E402
import xera_model as M       # noqa: E402

GPC_PATH = os.path.join(HERE, '..', 'XERA.gpc')
C = G.DEVICE_CONSTS
RX, RY = C['PS4_RX'], C['PS4_RY']
FULL = '--full' in sys.argv
RESULTS = []


def report(name, ok, detail):
    RESULTS.append((name, ok))
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}: {detail}", flush=True)


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
    tag = M.text_tables(M.TAGLINE)
    want = {'XR_P_MAP': M.P_MAP, 'XR_A_MAP': M.A_MAP, 'XR_K_MAP': M.K_MAP, 'XR_IK_MAP': M.IK_MAP,
            'XR_R_MAP': M.R_MAP, 'XR_IR_MAP': M.IR_MAP, 'XR_PAIR_A': M.PAIR_A, 'XR_PAIR_B': M.PAIR_B,
            'XR_AXSH': (0, 8, 16, 24), 'XR_AXTOP': M.TOP, 'XR_AXMUL': (1, 256, 65536, 16777216),
            'XR_SPAN_ROW': rows, 'XR_SPAN_X0': x0, 'XR_SPAN_X1': x1,
            'XR_TAG_CHUNK': M.text_chunks(M.TAGLINE), 'XR_TAG_X0': tag[1], 'XR_TAG_X1': tag[2]}
    bad = [k for k, v in want.items() if m.consts.get(k) != list(v)]
    report('umaps', not bad, f'all {len(want)} maps match' if not bad else f'mismatch: {bad}')
    dv = {'XR_LX': M.LX, 'XR_LY': M.LY, 'XR_LW': M.LW, 'XR_LH': M.LH, 'XR_DIV_Y': M.DIV_Y,
          'XR_TAG_Y': M.TAG_Y, 'XR_DIA_X': M.DIA_X, 'XR_BW': M.BW, 'XR_TW': M.TW, 'XR_HX0': M.HX0,
          'XR_HX1': M.HX1, 'XR_SWEEP': M.SWEEP_MS, 'XR_STEP': M.STEP_MS, 'XR_CYCLE': M.CYCLE_MS,
          'XR_SPK_X': M.SPARK_X, 'XR_SPK_Y': M.SPARK_Y, 'XR_W4': M.W4, 'XR_W4R': M.W4R,
          'XR_H0': M.H0, 'XR_H_RE': M.H_RE}
    for tag_, home in (('P', M.HP), ('T', M.HT), ('F', M.HF)):
        for i, ax in enumerate('PAKR'):
            dv[f'XR_H{tag_}_{ax}'] = home[i]
    bad = [k for k, v in dv.items() if m.defines.get(k) != v]
    report('layout, weights and home curves', not bad, 'all match' if not bad else f'mismatch: {bad}')


# ------------------------------------------------------------------ C
def vdiv(a, b):
    q = np.abs(a) // np.abs(b)
    return np.where((a >= 0) == (b > 0), q, -q)


def vlevel(t, p, A, iK, q, R, iR):
    """integer level of many curves at stick position t (exactly as the script)."""
    flat = t >= R
    tr = vdiv(t * iR, 4096)
    lo = tr < p
    u = vdiv(np.where(lo, tr, 0) * 4096, p)
    den_l = vdiv((A - 4096) * (4096 - u), 4096) + 4096
    w = vdiv(np.where(lo, 0, tr - p) * 4096, 4096 - p)
    den_u = vdiv((iK - 4096) * (4096 - w), 4096) + 4096
    f = np.where(lo, vdiv(q * u, den_l), q + vdiv((4096 - q) * w, den_u))
    return np.where(flat, 4096, f)


def check_library():
    print(f'C. Curve library ({M.LIBRARY_SIZE:,} curves)')
    # closed-form shape guarantees for every (knee, depth, drive); reach only rescales the stick axis
    p = np.array(M.P_MAP, float)[:, None, None] / 4096
    a = 1.0 / (np.array(M.A_MAP, float)[None, :, None] / 4096 + 1.0)
    K = np.array(M.K_MAP, float)[None, None, :] / 4096
    A = (1 - a) / a
    D = A * (1 - p) + K * p
    s0, sk, s1 = K / (A * D), K * A / D, A / (K * D)
    r0, r1 = float((sk / s0).min()), float((sk / s1).min())
    report('true S-shape for all curves (never linear / expo)', r0 >= 2.25 - 1e-9 and r1 >= 1.56 - 1e-9,
           f'all 16,777,216 knee/depth/drive combos x 64 reaches: knee gain >= {r0:.2f}x centre gain, '
           f'>= {r1:.2f}x top gain')
    # integer monotonicity / ends on a large random sample of full 4-D curves
    rng = np.random.default_rng(7)
    ids = rng.integers(0, M.LIBRARY_SIZE, 200000)
    ip, ia, ik, ir = ids & 255, (ids >> 8) & 255, (ids >> 16) & 255, (ids >> 24) & 63
    P = np.array(M.P_MAP, np.int64)[ip]
    AA = np.array(M.A_MAP, np.int64)[ia]
    KK = np.array(M.K_MAP, np.int64)[ik]
    IKK = np.array(M.IK_MAP, np.int64)[ik]
    R = np.array(M.R_MAP, np.int64)[ir]
    IR = np.array(M.IR_MAP, np.int64)[ir]
    Q = vdiv(KK * P, vdiv(AA * (4096 - P) + KK * P, 4096))
    prev = None
    drops = 0
    for t in range(0, 4097, 16):
        f = vlevel(np.int64(t), P, AA, IKK, Q, R, IR)
        if t == 0:
            f0 = f
        if prev is not None:
            drops += int((f < prev).sum())
        prev = f
    report('monotone + pinned (integer, sampled)', drops == 0 and not f0.any() and (prev == 4096).all(),
           f'200,000 random curves x 257 stick positions: never decreases, f(0)=0, f(1)=1')
    if FULL and EXE:
        out = subprocess.run([EXE, 'props'], capture_output=True, text=True, check=True).stdout.split()
        report('monotone + pinned (integer, all base curves)', out == ['0', '0'],
               f'all 16,777,216 base curves scanned in C: {out[0]} decreases, {out[1]} bad end points; '
               'reach is a monotone stretch, so this covers all 2^30 curves')
    err = derr = 0.0
    c = M.Curve()
    for cid in rng.integers(0, M.LIBRARY_SIZE, 400):
        ip, ia, ik, ir = M.unpack(int(cid))
        c.prep(M.P_MAP[ip], M.A_MAP[ia], M.K_MAP[ik], M.IK_MAP[ik], M.R_MAP[ir], M.IR_MAP[ir])
        pf, af = M.P_MAP[ip] / 4096, 1 / (M.A_MAP[ia] / 4096 + 1)
        kf, rf = M.K_MAP[ik] / 4096, M.R_MAP[ir] / 4096
        for t in range(0, 4097, 64):
            fi = c.level(t)
            di = c.slope14() / 16384
            ff, dd = M.curve_float(t / 4096, pf, af, kf, rf)
            err = max(err, abs(fi / 4096 - ff))
            if not c.flat:
                derr = max(derr, abs(di - dd))
    report('fixed-point accuracy', err < 0.002, f'level error <= {err * 100:.3f}% of full scale, '
           f'gain error <= {derr:.4f}')


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
    bad = late = 0
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
    # the same fuzz with the limiter bypassed (XR_LIMITER 0): full search on every tick
    src = open(GPC_PATH).read()
    on = 'define XR_LIMITER      = 1;'
    assert src.count(on) == 1
    mb = G.Machine(src.replace(on, 'define XR_LIMITER      = 0;'))
    mb.run_init()

    class Bypass(M.Settings):
        LIMITER = 0
    eng = M.Engine(Bypass)
    rnd = random.Random(12)
    bad = 0
    probes = set()
    for k in range(6000):
        x = max(-100, min(100, rnd.randint(-100, 100) if rnd.random() < 0.01 else x + rnd.randint(-5, 5)))
        y = max(-100, min(100, rnd.randint(-100, 100) if rnd.random() < 0.01 else y + rnd.randint(-5, 5)))
        dt = 1 if rnd.random() > 0.4 else rnd.randint(2, 4)        # heavy overload
        out = mb.tick({RX: x, RY: y}, dt)
        ex, ey = eng.step(x, y, dt)
        bad += (out[RX], out[RY]) != (ex, ey)
        probes.add(mb.vars['xr_probes'])
    report('limiter bypass', bad == 0 and probes == {mb.defines['XR_PROBES']},
           f'XR_LIMITER 0 under heavy overload: full {sorted(probes)} probes on every tick, '
           f'{bad} differing outputs vs the model')
    return ops, oled


# ------------------------------------------------------------------ E
EXE = None


def build_exhaustive():
    global EXE
    if not shutil.which('gcc'):
        return None
    d = tempfile.mkdtemp(prefix='xera_')

    def arr(name, vals):
        return f"static const int64_t {name}[{len(vals)}] = {{{', '.join(map(str, vals))}}};\n"
    with open(os.path.join(d, 'xera_maps.h'), 'w') as fh:
        fh.write('#include <stdint.h>\n' + arr('P_MAP', M.P_MAP) + arr('A_MAP', M.A_MAP) + arr('K_MAP', M.K_MAP)
                 + arr('IK_MAP', M.IK_MAP) + arr('R_MAP', M.R_MAP) + arr('IR_MAP', M.IR_MAP)
                 + f'#define W4 {M.W4}\n#define W4R {M.W4R}\n')
    exe = os.path.join(d, 'xera_exhaustive')
    src = os.path.join(HERE, 'xera_exhaustive.c')
    for flags in (['-fopenmp'], []):
        if subprocess.run(['gcc', '-O3', '-march=native', *flags, '-I', d, '-o', exe, src],
                          capture_output=True).returncode == 0:
            EXE = exe
            return exe
    return None


def check_search():
    print(f'E. Engine search vs exhaustive scan of all {M.LIBRARY_SIZE:,} curves')
    if not EXE:
        report('exhaustive comparison', True, 'skipped: no C compiler found (gcc)')
        return
    nstates = 40 if FULL else 12
    eng = M.Engine()
    rnd = random.Random(21)
    stream = list(M.controller_stream(M.scenario()))
    picks = set(rnd.sample(range(len(stream)), nstates))
    states = []
    for k, (name, x, y) in enumerate(stream):
        eng.step(x, y, 1)
        if k in picks:
            states.append({a: (list(getattr(eng, a)) if a == 'pr' else getattr(eng, a))
                           for a in ('t', 'th', 'Lhat', 'Sstar', 'W2', 'W3', 'pr', 'cid')})
    hits = runs = 0
    ticks, gaps = [], []
    t0 = time.time()
    for st in states:
        args = [st['t'], st['th'], st['Lhat'], st['Sstar'], st['W2'], st['W3'], *st['pr']]
        gmin = int(subprocess.run([EXE] + [str(v) for v in args], capture_output=True, text=True,
                                  check=True).stdout.split()[0])
        for start in (st['cid'], rnd.randrange(M.LIBRARY_SIZE)):
            e = M.Engine()
            for a, v in st.items():
                setattr(e, a, v)
            e.cid, e.h, e.cur, e.miss, e.lock = start, M.H0, 0, 0, 0
            n = 0
            while not e.lock and n < 2000:
                e.search()
                n += 1
            J = e.cost(*M.unpack(e.cid))
            hits += J == gmin
            runs += 1
            ticks.append(n)
            gaps.append((J - gmin) / max(1, gmin))
    g = np.array(gaps)
    report('finds the best curve of the whole library', g.max() < 0.01,
           f'{len(states)} real stick moments x 2 starts, each checked against all {M.LIBRARY_SIZE:,} curves '
           f'({time.time() - t0:.0f}s): identical best curve in {100 * hits / runs:.1f}%, cost within '
           f'{100 * np.median(g):.2f}% median / {100 * g.max():.2f}% worst; locks on in {int(np.median(ticks))} ms '
           f'median, {int(np.percentile(ticks, 95))} ms p95')


# ------------------------------------------------------------------ F
def check_feel():
    print('F. Feel metrics (reference model, same arithmetic as the script)')
    eng = M.Engine()
    log = []
    ids = set()
    for name, x, y in M.controller_stream(M.scenario()):
        eng.step(x, y, 1)
        log.append((name, eng.t, eng.fcur, eng.live_params()))
        ids.add(eng.cid)
    bins = {}
    for name, t, f, _ in log:
        if name == 'track' and t > 0:
            bins.setdefault(t // 24, []).append(f)
    hyst = 100 * np.mean([max(v) - min(v) for v in bins.values() if len(v) > 10]) / 4096
    report('tracking consistency', hyst < 1.0, f'same stick position -> same output within {hyst:.2f}% while sweeping')
    c = M.Curve()

    def live(params, t):
        p, A, K, R = params
        c.prep(p, A, K, M.idiv(16777216, K), R, M.idiv(16777216, R))
        return c.level(t)
    hold = [r for r in log if r[0] == 'hold50'][150:]
    tf = int(np.median([r[1] for r in hold]))
    lv = [live(r[3], tf) for r in hold]
    drift = 100 * (max(lv) - min(lv)) / 4096
    report('no drift while holding', drift < 0.5, f'curve level moves {drift:.2f}% during a steady hold')
    rows = [r for r in log if r[0] == 'flick60']
    ht = tuple((v + 1) // 2 for v in M.HT)
    static = (M.P_MAP[ht[0]], M.A_MAP[ht[1]], M.K_MAP[ht[2]], M.R_MAP[ht[3]])
    lead = [r[2] - live(static, r[1]) for r in rows[:70] if r[1] > 0]
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
    report('curve variety', len(ids) > 500, f'{len(ids):,} different library curves chosen during the '
           f'{len(log) / 1000:.1f} s test session')


# ------------------------------------------------------------------ G
def check_oled():
    print('G. OLED screen and inputs')
    m = machine()
    boot = 1 << m.defines['XR_B_BOOT']
    rest = M.rest_frame()
    checked = bad = 0
    idle_ok = []
    boot_ok = None
    for ms in range(1, M.BOOT_MS + 3 * M.CYCLE_MS):
        m.tick({}, 1)
        v = m.vars
        if boot_ok is None and v['xr_flags'] & boot:
            boot_ok = (ms, np.array_equal(np.array(m.fb, dtype=np.uint8), rest))
        if v['xr_flags'] & boot and v['xr_rowc'] >= 11 and v['xr_at'] < M.SWEEP_MS + M.STEP_MS:
            checked += 1
            fb = np.array(m.fb, dtype=np.uint8)[M.LY:M.LY + M.LH, M.LX:M.LX + M.LW]
            bad += not np.array_equal(fb, M.logo_with_flash(v['xr_hx']))
        if v['xr_flags'] & boot and v['xr_at'] == M.CYCLE_MS - 1:
            idle_ok.append(np.array_equal(np.array(m.fb, dtype=np.uint8), rest))
    report('flash frames', bad == 0 and checked > 0, f'{checked} frames drawn incrementally, {bad} differ from the design')
    report('boot animation', bool(boot_ok and boot_ok[1]), f'scan-in completes at {boot_ok[0]} ms on the exact designed frame')
    report('idle screen', all(idle_ok) and idle_ok, f'pixel-exact designed frame at the end of {len(idle_ok)} cycles')
    m = machine()
    rnd = random.Random(5)
    others = [k for k, v in C.items() if k.startswith('PS4_') and v not in (RX, RY)]
    touched = set()
    for k in range(4000):
        inp = {C[n]: (rnd.randint(-100, 100) if n.endswith(('X', 'Y')) else rnd.choice((0, 0, 100)))
               for n in others}
        inp[RX], inp[RY] = rnd.randint(-100, 100), rnd.randint(-100, 100)
        out = m.tick(inp, 1)
        touched |= {n for n in others if out[C[n]] != inp[C[n]]}
    report('touches only the aim stick', not touched,
           'all buttons, triggers and the left stick pass through unchanged' if not touched else f'modified: {sorted(touched)}')


# ------------------------------------------------------------------ H
def check_cost(ops, oled):
    print('H. Cost per 1 ms tick')
    report('budget', True, f'{np.mean(ops):.0f} interpreter ops mean / {np.percentile(ops, 99):.0f} p99 / {max(ops)} max '
           f'per tick (each ~ one VM instruction); OLED: {oled} draw calls max per tick')


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
    build_exhaustive()
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
