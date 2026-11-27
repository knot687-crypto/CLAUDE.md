"""
xera_model.py - reference model of XERA.gpc.

* Engine      : a bit-exact Python twin of the GPC stick engine (same integer
                operations, same C-style truncating division). The verifier
                runs both side by side and requires identical output.
* Library     : the 32,768-curve lattice (umaps) and the dual-rational S-curve.
* Design      : the XERA logotype, the 3x5 micro font and every display table
                the script embeds, generated from pixel art.
* Scenarios   : synthetic stick motion (micro-aim, tracking, flicks, holds)
                sampled the way a controller reports it (250 Hz, integer, noise).
"""
import math
import random

import numpy as np

# ============================================================== integer helpers
INT_MAX = 2**31 - 1


def idiv(a, b):
    """C / GPC integer division (truncates toward zero)."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b > 0) else -q


def isqrt(v):
    return math.isqrt(v) if v > 0 else 0


def chk(v):
    if not -INT_MAX - 1 <= v <= INT_MAX:
        raise OverflowError(v)
    return v


# ============================================================== curve library
N = 32
P_LO, P_HI = 0.18, 0.70        # knee position p
a_LO, a_HI = 0.18, 0.40        # lower-segment bias a  (A = (1-a)/a)
K_LO, K_HI = 1.25, 2.85        # knee drive K (upper bias b = K/(1+K))
P_MAP = [round(4096 * (P_LO + i * (P_HI - P_LO) / (N - 1))) for i in range(N)]
A_MAP = [round(4096 * (1 - a) / a) for a in (a_LO + i * (a_HI - a_LO) / (N - 1) for i in range(N))]
K_MAP = [round(4096 * (K_LO + i * (K_HI - K_LO) / (N - 1))) for i in range(N)]
IK_MAP = [round(4096 * 4096 / k) for k in K_MAP]


def curve_float(t, p, a, K):
    """Float definition of the dual-rational S-curve (for accuracy checks)."""
    A = (1 - a) / a
    D = A * (1 - p) + K * p
    q = K * p / D
    if t < p:
        u = t / p
        den = (A - 1) * (1 - u) + 1
        return q * u / den, (q / p) * A / den ** 2
    w = (t - p) / (1 - p)
    den = (1 / K - 1) * (1 - w) + 1
    return q + (1 - q) * w / den, ((1 - q) / (1 - p)) * (1 / K) / den ** 2


class Curve:
    """Integer evaluation exactly as xr_prep / xr_level / xr_slope."""

    def prep(self, p, A, K, iK):
        self.p, self.A, self.iK = p, A, iK
        self.q = idiv(K * p, idiv(A * (4096 - p) + K * p, 4096))

    def level(self, t):
        p, A, iK, q = self.p, self.A, self.iK, self.q
        if t < p:
            u = idiv(t * 4096, p)
            self.den = idiv((A - 4096) * (4096 - u), 4096) + 4096
            return idiv(q * u, self.den)
        w = idiv((t - p) * 4096, 4096 - p)
        self.den = idiv((iK - 4096) * (4096 - w), 4096) + 4096
        return q + idiv((4096 - q) * w, self.den)

    def slope(self, t):
        p, A, iK, q, den = self.p, self.A, self.iK, self.q, self.den
        if t < p:
            g = idiv(idiv(q * 4096, p) * A, den)
        else:
            g = idiv(idiv((4096 - q) * 4096, 4096 - p) * iK, den)
        return idiv(g * 4096, den)


# ============================================================== engine constants
ALPHA, BETA = 1024, 110
FAST_LO, FAST_HI = 1843, 5325
O_LO, O_HI = 614, 3072
V_LO, V_HI = 287, 901
T_LO, T_HI = 410, 1720
SM_RATE, F_ATK, F_REL, P_RATE, FENV_REL = 24, 4, 6, 16, 96
W2P, W2T, W2F = 10, 0, 8
TAU, W3_MAX, W4 = 24, 24, 2
GL_SLOW, GL_FAST = 16, 3
HP = (248, 271, 109)     # precision home (Q4 lattice coordinates)
HT = (191, 406, 62)      # tracking home
HF = (76, 361, 388)      # flick home


def home_q4(p, a, K):
    return tuple(int(round(v * 16)) for v in ((p - P_LO) / (P_HI - P_LO) * (N - 1),
                                               (a - a_LO) / (a_HI - a_LO) * (N - 1),
                                               (K - K_LO) / (K_HI - K_LO) * (N - 1)))


assert HP == home_q4(0.44, 0.30, 1.60) and HT == home_q4(0.38, 0.36, 1.45) and HF == home_q4(0.26, 0.34, 2.50)


class Settings:
    DEADZONE = 4
    ANTI_DZ = 0
    OUTER = 100
    GAIN_PREC = 65
    GAIN_TRACK = 100
    GAIN_FLICK = 190
    PROBES = 6
    VM_MS = 1


def ss(e0, e1, x):
    """Q12 smoothstep."""
    if x <= e0:
        return 0
    if x >= e1:
        return 4096
    u = idiv((x - e0) * 4096, e1 - e0)
    u2 = idiv(u * u, 4096)
    return idiv(u2 * (12288 - 2 * u), 4096)


def unpack(cid):
    return cid & 31, (cid >> 5) & 31, (cid >> 10) & 31


def pack(ip, ia, ik):
    return ip | (ia << 5) | (ik << 10)


class Engine:
    """Bit-exact twin of xr_engine() and friends."""

    def __init__(self, s=Settings):
        self.s = s
        self.gP = idiv(s.GAIN_PREC * 4096, 100)
        self.gT = idiv(s.GAIN_TRACK * 4096, 100)
        self.gF = idiv(s.GAIN_FLICK * 4096, 100)
        self.dz64 = s.DEADZONE * 64
        self.span64 = s.OUTER * 64 - self.dz64
        self.adz = idiv(s.ANTI_DZ * 4096, 100)
        self.xe = self.ye = self.vx = self.vy = self.Sm = 0
        self.iP, self.iF, self.iT, self.Fenv = 4096, 0, 0, 0
        ip, ia, ik = (HP[0] + 8) // 16, (HP[1] + 8) // 16, (HP[2] + 8) // 16
        self.cid = pack(ip, ia, ik)
        self.h, self.cur, self.lock, self.lockS = 4, 0, 0, 0
        self.g1p = self.g2p = P_MAP[ip] * 16
        self.g1a = self.g2a = A_MAP[ia] * 16
        self.g1k = self.g2k = K_MAP[ik] * 16
        self.probes, self.okt, self.late = s.PROBES, 0, 0
        self.c = Curve()
        self.evals = 0
        self.dt = 1

    def lerp(self, c, g, r):
        k = min(self.dt, r)
        return c + idiv((g - c) * k, r)

    # ---------------- search
    def cost(self, cid):
        self.evals += 1
        ip, ia, ik = unpack(cid)
        c = self.c
        c.prep(P_MAP[ip], A_MAP[ia], K_MAP[ik], IK_MAP[ik])
        c.level(self.t)
        e = idiv(c.slope(self.t) - self.Sstar, 16)
        J = self.W2 * e * e
        if self.W3 > 0:
            e = idiv(c.level(self.th) - self.Lhat, 16)
            J += self.W3 * e * e
        for idx, pr in ((ip, self.prp), (ia, self.pra), (ik, self.prk)):
            e = idx * 16 - pr
            J += W4 * e * e
        return chk(J)

    @staticmethod
    def neighbor(cid, d, h):
        ip, ia, ik = unpack(cid)
        if d == 0:
            ip = min(31, ip + h)
        elif d == 1:
            ip = max(0, ip - h)
        elif d == 2:
            ia = min(31, ia + h)
        elif d == 3:
            ia = max(0, ia - h)
        elif d == 4:
            ik = min(31, ik + h)
        else:
            ik = max(0, ik - h)
        return pack(ip, ia, ik)

    def search(self):
        Jb = self.cost(self.cid)
        best = self.cid
        for _ in range(self.probes):
            nid = self.neighbor(self.cid, self.cur, self.h)
            if nid != self.cid:
                J = self.cost(nid)
                if J < Jb:
                    Jb, best = J, nid
            self.cur = 0 if self.cur >= 5 else self.cur + 1
        nid = pack((self.prp + 8) // 16, (self.pra + 8) // 16, (self.prk + 8) // 16)
        if nid != self.cid and nid != best:
            J = self.cost(nid)
            if J < Jb:
                Jb, best = J, nid
        if best != self.cid:
            self.cid, self.lock = best, 0
        elif self.h > 1:
            self.h //= 2
        else:
            self.lock = 1
        if self.lock:
            if abs(self.Sstar - self.lockS) > 410:
                self.h, self.lock = 4, 0
        else:
            self.lockS = self.Sstar
        return Jb

    # ---------------- one millisecond
    def step(self, x, y, dt=1):
        s = self.s
        dt = max(1, min(20, dt))
        self.dt = dt
        # governor
        if dt > s.VM_MS:
            self.late += 4
        elif self.late > 0:
            self.late -= 1
        if self.late > 16:
            self.late = 0
            self.okt = 0
            if self.probes > 2:
                self.probes -= 1
        elif self.late == 0:
            self.okt += 1
            if self.okt >= 256:
                self.okt = 0
                if self.probes < s.PROBES:
                    self.probes += 1
        # 1. radial deflection
        r64 = isqrt(4096 * (x * x + y * y))
        t = 0
        if r64 > self.dz64:
            t = min(4096, idiv((r64 - self.dz64) * 4096, self.span64))
        self.t = t
        # 2. alpha-beta filter
        px = self.xe + idiv(self.vx * dt, 16)
        res = x * 256 - px
        self.xe = px + idiv(res * ALPHA, 4096)
        self.vx = max(-16384, min(16384, self.vx + idiv(res * 16 * BETA, 4096 * dt)))
        px = self.ye + idiv(self.vy * dt, 16)
        res = y * 256 - px
        self.ye = px + idiv(res * ALPHA, 4096)
        self.vy = max(-16384, min(16384, self.vy + idiv(res * 16 * BETA, 4096 * dt)))
        S = isqrt(self.vx * self.vx + self.vy * self.vy)
        self.S = S
        self.Sm = self.lerp(self.Sm, S, SM_RATE)
        vr = idiv((x * self.vx + y * self.vy) * 64, r64) if r64 > 0 else 0
        o = idiv(vr * 4096, S) if S > 64 else 0
        # 3. intent
        fast = ss(FAST_LO, FAST_HI, S)
        self.fast = fast
        Fr = idiv(fast * ss(O_LO, O_HI, o), 4096)
        Pr = idiv((4096 - ss(V_LO, V_HI, self.Sm)) * (4096 - ss(T_LO, T_HI, t)), 4096)
        Pr = idiv(Pr * (4096 - Fr), 4096)
        self.iF = self.lerp(self.iF, Fr, F_ATK if Fr > self.iF else F_REL)
        self.iP = self.lerp(self.iP, Pr, P_RATE)
        if self.iP > 4096 - self.iF:
            self.iP = 4096 - self.iF
        self.iT = 4096 - self.iP - self.iF
        iP, iT, iF = self.iP, self.iT, self.iF
        # 4. targets
        self.Sstar = idiv(iP * self.gP + iT * self.gT + iF * self.gF, 4096)
        self.W2 = idiv(iP * W2P + iT * W2T + iF * W2F, 4096)
        self.W3 = idiv(W3_MAX * iF, 4096)
        self.prp = idiv(iP * HP[0] + iT * HT[0] + iF * HF[0], 4096)
        self.pra = idiv(iP * HP[1] + iT * HT[1] + iF * HF[1], 4096)
        self.prk = idiv(iP * HP[2] + iT * HT[2] + iF * HF[2], 4096)
        self.th = max(0, min(4096, t + idiv(vr * TAU * 64, self.span64)))
        # 5. live curve -> output
        gk = self.g2k // 16
        self.c.prep(self.g2p // 16, self.g2a // 16, gk, idiv(16777216, gk))
        fcur = self.c.level(t)
        self.fcur = fcur
        self.Lhat = max(0, min(4096, fcur + idiv(self.Sstar * (self.th - t), 4096)))
        out = (0, 0)
        if t > 0:
            O = fcur
            if self.adz > 0:
                O = self.adz + idiv((4096 - self.adz) * O, 4096)
            den = 16 * r64
            half = den // 2

            def comp(v):
                num = v * O * 25
                return idiv(num + half, den) if num >= 0 else -idiv(half - num, den)
            out = (comp(x), comp(y))
        # 6. search + glide
        self.search()
        if iF > self.Fenv:
            self.Fenv = iF
        else:
            self.Fenv = self.lerp(self.Fenv, 0, FENV_REL)
        m = fast if fast > self.Fenv else self.Fenv
        gl = GL_SLOW - idiv((GL_SLOW - GL_FAST) * m, 4096)
        ip, ia, ik = unpack(self.cid)
        self.g1p = self.lerp(self.g1p, P_MAP[ip] * 16, gl)
        self.g2p = self.lerp(self.g2p, self.g1p, gl)
        self.g1a = self.lerp(self.g1a, A_MAP[ia] * 16, gl)
        self.g2a = self.lerp(self.g2a, self.g1a, gl)
        self.g1k = self.lerp(self.g1k, K_MAP[ik] * 16, gl)
        self.g2k = self.lerp(self.g2k, self.g1k, gl)
        return out

    def live_params(self):
        return self.g2p // 16, self.g2a // 16, self.g2k // 16


# ============================================================== display design
LH = 22


def _art(text):
    rows = text.strip('\n').split('\n')
    w = max(len(r) for r in rows)
    return np.array([[c == '#' for c in r.ljust(w, '.')] for r in rows], dtype=bool)


def _diag_band(W, x_top, x_bot, width):
    m = np.zeros((LH, W), dtype=bool)
    for y in range(LH):
        xl = x_top + (x_bot - x_top) * (y + 0.5) / LH
        for x in range(W):
            if xl <= x + 0.5 < xl + width:
                m[y, x] = True
    return m


def glyph_X(W=20, w=5.0):
    return _diag_band(W, 0, W - w, w) | _diag_band(W, W - w, 0, w)


def glyph_A(W=22, w=5.0, apex=6.0, bar=(13, 16)):
    m = np.zeros((LH, W), dtype=bool)
    cx = W / 2
    for y in range(LH):
        yc = y + 0.5
        xo_l = (cx - apex / 2) * (1 - yc / LH)
        xo_r = W - xo_l
        for x in range(W):
            xc = x + 0.5
            if xo_l <= xc < xo_l + w or xo_r - w <= xc < xo_r:
                m[y, x] = True
            if y < 3 and xo_l <= xc < xo_r:
                m[y, x] = True
            if bar[0] <= y < bar[1] and xo_l <= xc < xo_r:
                m[y, x] = True
    return m


GLYPH_E = _art('''
#################
#################
#################
#################
####
####
####
####
####
##############
##############
##############
##############
####
####
####
####
####
#################
#################
#################
#################
''')

GLYPH_R = _art('''
################...
#################..
##################.
###################
####...........####
####...........####
####...........####
####...........####
####...........####
###################
##################.
#################..
################...
####.....#####.....
####......#####....
####......#####....
####.......#####...
####........#####..
####........#####..
####.........#####.
####..........#####
####..........#####
''')

KERNING = (6, 8, 5)   # optical gaps X-E, E-R, R-A


def build_logo():
    glyphs = [glyph_X(), GLYPH_E, GLYPH_R, glyph_A()]
    width = sum(g.shape[1] for g in glyphs) + sum(KERNING)
    m = np.zeros((LH, width), dtype=bool)
    x = 0
    for i, g in enumerate(glyphs):
        m[:, x:x + g.shape[1]] = g
        x += g.shape[1] + (KERNING[i] if i < 3 else 0)
    return m


LOGO = build_logo()
LW = LOGO.shape[1]
LX = (128 - LW) // 2
LY = 12
DIV_Y = LY + LH + 7
TAG_Y = DIV_Y + 6
DIA_X = 63
BW, TW = 7, 6
HX0 = -((LH - 1) // 2) - 1
HX1 = LW + BW + TW - 1
SWEEP_MS, STEP_MS, CYCLE_MS = 960, 24, 3200
SPARK_X, SPARK_Y = LX + LW - 1, LY - 5
BOOT_MS = 640

FONT3 = {
    'A': ['.#.', '#.#', '###', '#.#', '#.#'], 'C': ['###', '#..', '#..', '#..', '###'],
    'D': ['##.', '#.#', '#.#', '#.#', '##.'], 'E': ['###', '#..', '##.', '#..', '###'],
    'F': ['###', '#..', '##.', '#..', '#..'], 'G': ['###', '#..', '#.#', '#.#', '###'],
    'I': ['###', '.#.', '.#.', '.#.', '###'], 'N': ['##.', '#.#', '#.#', '#.#', '#.#'],
    'O': ['###', '#.#', '#.#', '#.#', '###'], 'P': ['##.', '#.#', '##.', '#..', '#..'],
    'R': ['##.', '#.#', '##.', '#.#', '#.#'], 'T': ['###', '.#.', '.#.', '.#.', '.#.'],
    'U': ['#.#', '#.#', '#.#', '#.#', '###'], 'V': ['#.#', '#.#', '#.#', '#.#', '.#.'],
    ' ': ['...', '...', '...', '...', '...'],
}
TAGLINE = 'ADAPTIVE CURVE ENGINE'


def runs_of(row):
    out, x = [], 0
    while x < len(row):
        if row[x]:
            x0 = x
            while x < len(row) and row[x]:
                x += 1
            out.append((x0, x - 1))
        else:
            x += 1
    return out


def span_tables():
    x0s, x1s, rows = [], [], []
    for y in range(LH):
        rows.append(len(x0s))
        for a, b in runs_of(LOGO[y]):
            x0s.append(a)
            x1s.append(b)
    rows.append(len(x0s))
    return rows, x0s, x1s


def text_bitmap(s):
    w = len(s) * 4 - 1
    m = np.zeros((5, w), dtype=bool)
    for i, ch in enumerate(s):
        for r in range(5):
            for c in range(3):
                if FONT3[ch][r][c] == '#':
                    m[r, i * 4 + c] = True
    return m


def text_tables(s):
    m = text_bitmap(s)
    x0 = (128 - m.shape[1]) // 2
    a, b, rows = [], [], []
    for r in range(5):
        rows.append(len(a))
        for u, v in runs_of(m[r]):
            a.append(u + x0)
            b.append(v + x0)
    rows.append(len(a))
    return rows, a, b


def text_chunks(s):
    """Run-index boundaries of the 10 tagline chunks: (row, left half) then (row, right half)."""
    rows, a, b = text_tables(s)
    out = []
    for r in range(5):
        out.append(rows[r])
        k = rows[r]
        while k < rows[r + 1] and a[k] < 64:
            k += 1
        out.append(k)
    out.append(rows[5])
    return out


def rest_frame():
    """The designed idle screen, pixel for pixel."""
    fb = np.zeros((64, 128), dtype=np.uint8)
    for y in range(0, LH, 2):
        fb[LY + y, LX:LX + LW] = LOGO[y]
    fb[0, 0:6] = fb[63, 0:6] = fb[0, 122:128] = fb[63, 122:128] = 1
    fb[1:6, 0] = fb[1:6, 127] = fb[58:63, 0] = fb[58:63, 127] = 1
    y, x = DIV_Y, DIA_X
    fb[y, 34:x - 3] = 1
    fb[y, x + 4:94] = 1
    for xx in (28, 30, 32, 95, 97, 99):
        fb[y, xx] = 1
    fb[y - 2, x] = fb[y + 2, x] = 1
    fb[y - 1, x - 1:x + 2] = fb[y + 1, x - 1:x + 2] = 1
    fb[y, x - 2:x + 3] = 1
    rows, a, b = text_tables(TAGLINE)
    for r in range(5):
        for k in range(rows[r], rows[r + 1]):
            fb[TAG_Y + r, a[k]:b[k] + 1] = 1
    return fb


def logo_with_flash(hx):
    """Analytic logo state with the light band's leading edge at hx."""
    m = np.zeros((LH, LW), dtype=np.uint8)
    for y in range(LH):
        e = hx + (LH - 1 - y) // 2
        lo = e - (BW + TW) + 1 if y % 4 == 1 else e - BW + 1
        for x in range(LW):
            if LOGO[y, x]:
                m[y, x] = 1 if y % 2 == 0 or lo <= x <= e else 0
    return m


# ============================================================== stick scenarios
def minjerk(a, b, T, t):
    if t <= 0:
        return a
    if t >= T:
        return b
    s = t / T
    return a + (b - a) * (10 * s ** 3 - 15 * s ** 4 + 6 * s ** 5)


def scenario():
    """(name, ms, fn(ms)->(x,y)) segments of a realistic aim session."""
    ang = math.radians(30)

    def micro(t):
        return (9 + 5 * math.sin(2 * math.pi * 1.7 * t / 1000) + 2 * math.sin(2 * math.pi * 4.1 * t / 1000),
                -6 + 3 * math.sin(2 * math.pi * 1.1 * t / 1000 + 1))

    def track(t):
        return 42 * math.sin(2 * math.pi * 0.9 * t / 1000), 8 * math.sin(2 * math.pi * 0.45 * t / 1000)

    def flick(t):
        r = minjerk(0, 95, 70, t) if t < 70 else 95 if t < 320 else minjerk(95, 0, 90, t - 320) if t < 410 else 0
        return r * math.cos(ang), r * math.sin(ang)

    def flick60(t):
        r = minjerk(0, 60, 60, t) if t < 60 else 60 if t < 600 else minjerk(60, 0, 80, t - 600) if t < 680 else 0
        return -r, 0.0

    return [('rest', 400, lambda t: (0.0, 0.0)), ('micro', 1500, micro), ('track', 2200, track),
            ('hold50', 1000, lambda t: (50.0, 0.0)), ('flick', 700, flick), ('flick60', 900, flick60),
            ('turn', 800, lambda t: (100.0, 0.0)), ('rest2', 300, lambda t: (0.0, 0.0))]


def controller_stream(segs, report_ms=4, noise=0.35, seed=7):
    """Yield (segment, x, y) per ms: 250 Hz sample-and-hold, integer, sensor noise."""
    rnd = random.Random(seed)
    T = 0
    hx = hy = 0
    for name, dur, fn in segs:
        for k in range(dur):
            if T % report_ms == 0:
                fx, fy = fn(k)
                hx = max(-100, min(100, int(round(fx + rnd.gauss(0, noise)))))
                hy = max(-100, min(100, int(round(fy + rnd.gauss(0, noise)))))
            yield name, hx, hy
            T += 1
