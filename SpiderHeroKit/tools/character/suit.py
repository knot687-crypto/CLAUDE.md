"""
Suit evaluator: turns the baked rest-pose position/normal/bone maps into PBR textures.
Every texel is computed from its 3D position on the body, so the design is continuous across UV
seams and resolution independent. Outputs per material set (out/textures/):
  <Set>_Color.png (sRGB), <Set>_Roughness.png, <Set>_Height.png (16-bit, 0.5 = surface,
  1 unit = HEIGHT_RANGE studs), <Set>_Metal.png

Design (original character): a deep-teal tactical silk-weave suit with storm-grey compression
panels on the flanks and inner limbs, and metallic gold silk-strand inlays that radiate from a
faceted gem emblem (chest and back) over the shoulders, down the limbs and over the mask. The
mask carries angular amber visor lenses in gold bezels plus two small secondary lenses, like a
jumping spider's eye cluster. Web-shooter cuffs, knee and elbow guards, grip-pad palms, tread soles.

Strands are true 3D curves: control points are ray-cast onto the baked surface and the splines
between them are projected onto it, so a line keeps its width as it wraps over a shoulder or skull.
"""
import os, sys, json
import numpy as np
from PIL import Image
from scipy.spatial import cKDTree
from scipy import ndimage

here = os.path.dirname(__file__)
mapdir = os.path.join(here, "out", "maps")
outdir = os.path.join(here, "out", "textures")
os.makedirs(outdir, exist_ok=True)
bones = json.load(open(os.path.join(mapdir, "bones.json")))
HEIGHT_RANGE = 0.03  # studs mapped to [0,1]
SETS = ["SuitHead", "SuitTorso", "SuitArms", "SuitLegs"]
AA = 0.0011  # anti-aliasing half band (studs)

SRGB = lambda *c: np.array(c, float) / 255.0
COL = dict(
    suit=SRGB(8, 44, 57),
    guard=SRGB(11, 54, 69),
    panel=SRGB(30, 35, 41),
    glove=SRGB(26, 30, 35),
    grip=SRGB(18, 21, 24),
    gold=SRGB(228, 170, 80),
    enamel=SRGB(9, 30, 38),
    groove=SRGB(6, 14, 18),
    lens_lo=SRGB(206, 98, 18),
    lens_hi=SRGB(255, 200, 96),
    sole=SRGB(22, 26, 29),
)
HEAD, TORSO, ARM, HAND, LEG, FOOT = range(6)


def smooth(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def cover(sd, aa=AA):
    """Coverage of a signed-distance shape (negative inside)."""
    return 1 - smooth(-aa, aa, sd)


# ---------------------------------------------------------------------------------------------
# data
# ---------------------------------------------------------------------------------------------
def _bone_groups():
    g = np.full(len(bones), TORSO, np.int8)
    for i, b in enumerate(bones):
        if b == "Head":
            g[i] = HEAD
        elif "Arm" in b:
            g[i] = ARM
        elif "Hand" in b or any(f in b for f in ("Thumb", "Index", "Middle", "Ring", "Pinky")):
            g[i] = HAND
        elif "Leg" in b:
            g[i] = LEG
        elif "Foot" in b:
            g[i] = FOOT
    return g


BONE_GROUP = _bone_groups()


def groups_of(P, B):
    g = BONE_GROUP[np.clip(B, 0, len(bones) - 1)].copy()
    g[(g == LEG) & (P[:, 1] > 3.02)] = TORSO  # the hips belong to the torso design (belt/trunks)
    return g


def load_set(name):
    dd = np.load(os.path.join(mapdir, f"{name}_data.npz"))
    mask = dd["mask"]
    P = dd["P"][mask].astype(np.float64)
    N = dd["N"][mask].astype(np.float64)
    B = dd["B"][mask]
    return P, N, B, mask


# surface cloud for snapping design curves onto the body
_cp, _cn, _cg = [], [], []
for _s in SETS:
    _P, _N, _B, _m = load_set(_s)
    _g = groups_of(_P, _B)
    _cp.append(_P[::4]), _cn.append(_N[::4]), _cg.append(_g[::4])
CP, CN, CG = np.concatenate(_cp), np.concatenate(_cn), np.concatenate(_cg)
del _cp, _cn, _cg, _P, _N, _B, _m, _g
GP = {g: CP[CG == g] for g in range(6)}
GN = {g: CN[CG == g] for g in range(6)}
TREES = {g: cKDTree(GP[g]) for g in range(6)}


def ray_hit(o, d, groups, mode="first", r=0.007):
    o = np.asarray(o, float)
    d = np.asarray(d, float)
    d = d / np.linalg.norm(d)
    P = np.concatenate([GP[g] for g in groups])
    v = P - o
    t = v @ d
    perp2 = np.einsum("ij,ij->i", v, v) - t * t
    ok = (perp2 < r * r) & (t > 0)
    if not ok.any():
        raise ValueError(f"design ray missed the body: o={o} d={d}")
    tt = t[ok]
    i = np.argmin(tt) if mode == "first" else np.argmax(tt)
    return P[ok][i]


# control-point helpers (s = +1 right side / -1 left side; the character faces -Z)
def F(x, y, g=(TORSO,)):
    return ray_hit((x, y, -5), (0, 0, 1), g)


def BK(x, y, g=(TORSO,)):
    return ray_hit((x, y, 5), (0, 0, -1), g)


def TOP(x, z, g=(TORSO,)):
    return ray_hit((x, 9, z), (0, -1, 0), g)


def ARMP(s, y, th, g=(ARM,)):
    """Point on the arm at height y, angle th around the arm axis (0 = outward, +90 = back)."""
    t = np.radians(th)
    return ray_hit((0.62 * s, y, 0.03), (np.cos(t) * s, 0, np.sin(t)), g, "last")


def LEGP(s, y, ph, g=(LEG,)):
    """Point on the leg at height y, angle ph around the leg axis (0 = outward, -90 = front)."""
    t = np.radians(ph)
    return ray_hit((0.25 * s, y, 0.0), (np.cos(t) * s, 0, np.sin(t)), g, "last")


def HEADP(s, az, y, g=(HEAD,)):
    """Point on the head at height y, azimuth az (0 = face, 90 = side, 180 = back)."""
    a = np.radians(az)
    return ray_hit((0, y, 0.02), (np.sin(a) * s, 0, -np.cos(a)), g, "last")


# ---------------------------------------------------------------------------------------------
# curves
# ---------------------------------------------------------------------------------------------
def snap(S, groups, iters=2):
    """Projects points onto the tangent plane of the nearest surface sample (smooth, no jitter)."""
    for _ in range(iters):
        best = np.full(len(S), np.inf)
        q = np.zeros_like(S)
        n = np.zeros_like(S)
        for g in groups:
            d, i = TREES[g].query(S)
            b = d < best
            best[b] = d[b]
            q[b] = GP[g][i[b]]
            n[b] = GN[g][i[b]]
        S = S - n * np.einsum("ij,ij->i", S - q, n)[:, None]
    return S


def _cr(p0, p1, p2, p3, n, alpha=0.5):
    """Centripetal Catmull-Rom segment p1 -> p2 (Barry-Goldman)."""
    def tj(ti, a, b):
        return ti + max(np.linalg.norm(b - a), 1e-6) ** alpha

    t0 = 0.0
    t1 = tj(t0, p0, p1)
    t2 = tj(t1, p1, p2)
    t3 = tj(t2, p2, p3)
    t = np.linspace(t1, t2, n)[:, None]
    A1 = (t1 - t) / (t1 - t0) * p0 + (t - t0) / (t1 - t0) * p1
    A2 = (t2 - t) / (t2 - t1) * p1 + (t - t1) / (t2 - t1) * p2
    A3 = (t3 - t) / (t3 - t2) * p2 + (t - t2) / (t3 - t2) * p3
    B1 = (t2 - t) / (t2 - t0) * A1 + (t - t0) / (t2 - t0) * A2
    B2 = (t3 - t) / (t3 - t1) * A2 + (t - t1) / (t3 - t1) * A3
    return (t2 - t) / (t2 - t1) * B1 + (t - t1) / (t2 - t1) * B2


def _run(P, W, step):
    """Samples one smooth run of control points (spline through all of them)."""
    pts, ws = [], []
    n = len(P)
    for i in range(n - 1):
        p0 = P[i - 1] if i > 0 else 2 * P[0] - P[1]
        p3 = P[i + 2] if i + 2 < n else 2 * P[-1] - P[-2]
        k = max(2, int(np.linalg.norm(P[i + 1] - P[i]) / step) + 2)
        seg = _cr(p0, P[i], P[i + 1], p3, k) if n > 2 else np.linspace(P[i], P[i + 1], k)
        w = np.linspace(W[i], W[i + 1], k)
        if i > 0:
            seg, w = seg[1:], w[1:]
        pts.append(seg)
        ws.append(w)
    return np.concatenate(pts), np.concatenate(ws)


CURVES = []  # (samples, halfwidths, group mask)


def strand(ctrl, groups, step=0.0025):
    """ctrl: list of (point, halfwidth) or (point, halfwidth, 'sharp'); a sharp point is a corner."""
    P = [np.asarray(c[0], float) for c in ctrl]
    W = [float(c[1]) for c in ctrl]
    sharp = [len(c) > 2 and c[2] == "sharp" for c in ctrl]
    runs, start = [], 0
    for k in range(1, len(P)):
        if sharp[k] or k == len(P) - 1:
            runs.append((start, k))
            start = k
    S, Wd = [], []
    for a, b in runs:
        sp, sw = _run(np.array(P[a:b + 1]), np.array(W[a:b + 1]), step * 0.5)
        if S:
            sp, sw = sp[1:], sw[1:]
        S.append(sp)
        Wd.append(sw)
    S, Wd = np.concatenate(S), np.concatenate(Wd)
    S = snap(S, groups)
    # uniform arc-length resampling, then a final projection
    seg = np.linalg.norm(np.diff(S, axis=0), axis=1)
    acc = np.concatenate([[0], np.cumsum(seg)])
    m = max(2, int(np.ceil(acc[-1] / step)) + 1)
    u = np.linspace(0, acc[-1], m)
    S = np.stack([np.interp(u, acc, S[:, k]) for k in range(3)], 1)
    Wd = np.interp(u, acc, Wd)
    S = snap(S, groups)
    CURVES.append((S, Wd, sum(1 << g for g in groups)))
    return S


NODES = []  # (center, radius, group mask)


def node(p, r, groups):
    NODES.append((np.asarray(p, float), r, sum(1 << g for g in groups)))


# ---------------------------------------------------------------------------------------------
# 2D shapes
# ---------------------------------------------------------------------------------------------
def poly_sd(u, v, verts):
    """Signed distance to a simple polygon (negative inside)."""
    V = np.asarray(verts, float)
    d = (u - V[0, 0]) ** 2 + (v - V[0, 1]) ** 2
    sg = np.ones_like(u)
    j = len(V) - 1
    for i in range(len(V)):
        ex, ey = V[j, 0] - V[i, 0], V[j, 1] - V[i, 1]
        wx, wy = u - V[i, 0], v - V[i, 1]
        h = np.clip((wx * ex + wy * ey) / (ex * ex + ey * ey), 0, 1)
        bx, by = wx - ex * h, wy - ey * h
        d = np.minimum(d, bx * bx + by * by)
        c1 = v >= V[i, 1]
        c2 = v < V[j, 1]
        c3 = ex * wy > ey * wx
        flip = (c1 & c2 & c3) | (~c1 & ~c2 & ~c3)
        sg = np.where(flip, -sg, sg)
        j = i
    return sg * np.sqrt(d)


def scaled(verts, k, dy=0.0):
    return [(x * k, y * k + dy) for x, y in verts]


# emblem: a faceted gem spider. Cephalothorax carries all eight legs; the abdomen is a gold bezel
# around dark enamel with a gold keel. Coordinates relative to the emblem center (front view).
CEPH = [(0, 0.118), (0.052, 0.078), (0.052, 0.022), (0, -0.016), (-0.052, 0.022), (-0.052, 0.078)]
ABDO = [(0, -0.036), (0.062, -0.092), (0.05, -0.185), (0, -0.258), (-0.05, -0.185), (-0.062, -0.092)]
FRONT_Y0, FRONT_K, BACK_Y0, BACK_K = 4.185, 1.2, 4.13, 1.45

# visor lens (right eye, |x| and y); outer corner swept up into a blade
LENS = [(0.038, 5.168), (0.075, 5.222), (0.13, 5.246), (0.214, 5.284), (0.19, 5.214), (0.14, 5.16), (0.075, 5.14)]
BUCKLE = [(0, 3.338), (0.048, 3.278), (0, 3.218), (-0.048, 3.278)]


def hex_pattern(uv, size):
    """1 at hex cell centers, 0 at the cell edges."""
    q = uv / size
    r = np.array([1.0, np.sqrt(3)])
    h = r * 0.5
    a = np.mod(q, r) - h
    b = np.mod(q - h, r) - h
    g = np.where((a * a).sum(-1, keepdims=True) < (b * b).sum(-1, keepdims=True), a, b)
    gx, gy = np.abs(g[..., 0]), np.abs(g[..., 1])
    hexd = np.maximum(gx * 0.866025 + gy * 0.5, gy)
    return np.clip(1 - hexd / 0.5, 0, 1)


def triplanar_coords(P, N):
    ax = np.argmax(np.abs(N), axis=1)
    return np.stack([np.where(ax == 0, P[:, 2], P[:, 0]), np.where(ax == 1, P[:, 2], P[:, 1])], -1)


# ---------------------------------------------------------------------------------------------
# the strand network
# ---------------------------------------------------------------------------------------------
def build_design():
    T, A, H, L = (TORSO,), (ARM,), (HEAD,), (LEG,)
    W = 0.0078  # standard strand half width
    for s in (1, -1):
        TA = (TORSO, ARM)
        # outer arm line: over the deltoid, behind the elbow, down to the web-shooter cuff
        arm_path = [(ARMP(s, 4.47, -4, TA), W), (ARMP(s, 4.25, 0), W), (ARMP(s, 3.95, 6), W), (ARMP(s, 3.7, 13), W),
                    (ARMP(s, 3.5, 19), W), (ARMP(s, 3.28, 12), W), (ARMP(s, 3.04, 4), W), (ARMP(s, 2.83, 0), W)]
        # ---- front emblem legs (sharp knees), the outer pair continuing as long strands
        y0, k = FRONT_Y0, FRONT_K
        f = lambda x, y, g=T: F(x * s * k, y0 + y * k, g)
        strand([(f(0.046, 0.088), 0.0105), (f(0.105, 0.148), 0.0095, "sharp"), (f(0.126, 0.235), 0.0082, "sharp"),
                (f(0.165, 0.33), 0.0072), (F(0.27 * s, 4.61), W), (TOP(0.45 * s, -0.06, TA), W),
                (TOP(0.62 * s, -0.02, TA), W)] + arm_path, TA)
        strand([(f(0.05, 0.062), 0.0105), (f(0.142, 0.092), 0.0088, "sharp"), (f(0.205, 0.165), 0.0018)], T)
        strand([(f(0.05, 0.036), 0.0105), (f(0.146, 0.022), 0.0088, "sharp"), (f(0.212, -0.055), 0.0018)], T)
        strand([(f(0.045, 0.012), 0.0105), (f(0.11, -0.042), 0.0095, "sharp"), (f(0.134, -0.15), 0.0082, "sharp"),
                (F(0.19 * s, 3.83), 0.0074), (F(0.205 * s, 3.62), W), (F(0.165 * s, 3.45), W), (F(0.075 * s, 3.36), W),
                (F(0.036 * s, 3.33), W)], T)
        # ---- back emblem legs
        y0, k = BACK_Y0, BACK_K
        b = lambda x, y, g=T: BK(x * s * k, y0 + y * k, g)
        strand([(b(0.046, 0.088), 0.0118), (b(0.105, 0.148), 0.0105, "sharp"), (b(0.126, 0.235), 0.009, "sharp"),
                (BK(0.22 * s, 4.52), 0.0075), (BK(0.31 * s, 4.63), W), (TOP(0.47 * s, 0.12, TA), W),
                (TOP(0.63 * s, 0.09, TA), W), (ARMP(s, 4.5, 14, TA), W), (ARMP(s, 4.39, -2, TA), W)], TA)
        strand([(b(0.05, 0.062), 0.0118), (b(0.142, 0.092), 0.0098, "sharp"), (b(0.205, 0.165), 0.002)], T)
        strand([(b(0.05, 0.036), 0.0118), (b(0.146, 0.022), 0.0098, "sharp"), (b(0.212, -0.055), 0.002)], T)
        strand([(b(0.045, 0.012), 0.0118), (b(0.11, -0.042), 0.0105, "sharp"), (b(0.134, -0.15), 0.009, "sharp"),
                (BK(0.215 * s, 3.74), 0.0075), (BK(0.19 * s, 3.52), W), (BK(0.07 * s, 3.39), W), (BK(0.0, 3.365), W)], T)
        # ---- leg: hip hub below the belt, spiralling forward past the knee guard to the boot
        hip = LEGP(s, 3.185, 0, (TORSO, LEG))
        boot = LEGP(s, 1.072, -90)
        node(boot, 0.011, L)
        strand([(hip, W), (LEGP(s, 2.9, -3, (TORSO, LEG)), W), (LEGP(s, 2.5, -10), W), (LEGP(s, 2.12, -22), W),
                (LEGP(s, 1.84, -38), W), (LEGP(s, 1.6, -54), W), (LEGP(s, 1.4, -70), W), (LEGP(s, 1.2, -84), W),
                (boot, W)], (TORSO, LEG))
        # ---- boot heel accent
        strand([(BK(0.25 * s, 0.3, (FOOT,)), 0.0035), (BK(0.25 * s, 0.2, (FOOT,)), W * 0.9),
                (BK(0.25 * s, 0.085, (FOOT,)), W * 0.9)], (FOOT,))
        # ---- mask: temple strands from the visor tips back to the occiput hub
        tip = F(0.214 * s, 5.284, H)
        strand([(tip, 0.0045), (HEADP(s, 62, 5.305), 0.0058), (HEADP(s, 100, 5.295), 0.0062),
                (HEADP(s, 138, 5.225), 0.0062), (HEADP(s, 162, 5.125), 0.0062), (BK(0.0, 5.075, H), 0.0062)], H)
    # ---- crest over the skull, between the secondary lenses, to the occiput hub; spine down to the back emblem
    hub = BK(0.0, 5.075, (HEAD,))
    node(hub, 0.0155, (HEAD,))
    strand([(F(0.0, 5.236, H), 0.0035), (F(0.0, 5.27, H), 0.0062), (F(0.0, 5.36, H), 0.0066), (TOP(0.0, -0.17, H), 0.0068),
            (TOP(0.0, 0.0, H), 0.0068), (TOP(0.0, 0.16, H), 0.0068), (BK(0.0, 5.32, H), 0.0068), (BK(0.0, 5.18, H), 0.0066),
            (hub, 0.0066)], H)
    strand([(hub, 0.0066), (BK(0.0, 4.98, H), 0.0066), (BK(0.0, 4.86, (HEAD, TORSO)), 0.0068), (BK(0.0, 4.7), 0.0072),
            (BK(0.0, 4.52), 0.0078), (BK(0.0, BACK_Y0 + 0.118 * BACK_K), 0.0085)], (HEAD, TORSO))
    node(BK(0.0, 3.365), 0.0135, (TORSO,))


build_design()
_S = np.concatenate([c[0] for c in CURVES])
_W = np.concatenate([c[1] for c in CURVES])
_CID = np.concatenate([np.full(len(c[0]), i) for i, c in enumerate(CURVES)])
_CMASK = np.array([c[2] for c in CURVES])
STREE = cKDTree(_S)
print(f"design: {len(CURVES)} strands, {len(_S)} samples, {len(NODES)} hubs")


def strand_field(P, G):
    """Distance to the strand network and the local strand half width (inf where far)."""
    n = len(P)
    dist = np.full(n, np.inf)
    wid = np.full(n, 0.007)
    d, i = STREE.query(P, distance_upper_bound=0.04)
    hit = np.isfinite(d)
    idx = np.nonzero(hit)[0]
    ii = i[hit]
    p = P[idx]
    best = d[hit]
    bw = _W[ii]
    M = len(_S)
    for off in (-1, 1):
        j = np.clip(ii + off, 0, M - 1)
        ok = (ii + off >= 0) & (ii + off < M) & (_CID[j] == _CID[ii])
        a, b = _S[ii], _S[j]
        ab = b - a
        L2 = np.maximum(np.einsum("ij,ij->i", ab, ab), 1e-12)
        u = np.clip(np.einsum("ij,ij->i", p - a, ab) / L2, 0, 1)
        dd = np.linalg.norm(p - (a + ab * u[:, None]), axis=1)
        better = ok & (dd < best)
        best = np.where(better, dd, best)
        bw = np.where(better, _W[ii] + (_W[j] - _W[ii]) * u, bw)
    allowed = ((_CMASK[_CID[ii]] >> G[idx]) & 1) == 1
    dist[idx[allowed]] = best[allowed]
    wid[idx[allowed]] = bw[allowed]
    for c, r, gm in NODES:
        dn = np.linalg.norm(P - c, axis=1)
        ok = ((gm >> G) & 1) == 1
        # hubs read as slightly larger, domed silk knots
        sel = ok & (dn - r < dist - wid)
        dist = np.where(sel, dn, dist)
        wid = np.where(sel, r, wid)
    return dist, wid


# ---------------------------------------------------------------------------------------------
def evaluate(P, N, B):
    n = len(P)
    x, y, z = P[:, 0], P[:, 1], P[:, 2]
    G = groups_of(P, B)
    is_head, is_torso, is_arm = G == HEAD, G == TORSO, G == ARM
    is_hand, is_leg, is_foot = G == HAND, G == LEG, G == FOOT
    side = np.where(x >= 0, 1.0, -1.0)

    # limb frames
    ax_ = 0.62 * side
    r_arm = np.hypot(x - ax_, z - 0.03)
    th_arm = np.degrees(np.arctan2(z - 0.03, (x - ax_) * side))  # 0 outward, +90 back, +-180 inward
    lx = 0.25 * side
    r_leg = np.hypot(x - lx, z)
    ph_leg = np.degrees(np.arctan2(z, (x - lx) * side))  # 0 outward, -90 front, +90 back
    r_tor = np.hypot(x, z)
    al_tor = np.degrees(np.arctan2(np.abs(x), -z))  # 0 front centre, 90 side, 180 back centre

    # ---- regions: + inside a storm-grey panel ------------------------------------------------
    pan = np.full(n, -1.0)
    # torso flank panels, following the obliques and lats up into the armpit
    ys = [3.352, 3.55, 3.8, 4.05, 4.25, 4.43]
    af = np.interp(y, ys, [63, 57, 55, 61, 71, 90])
    ab = np.interp(y, ys, [117, 124, 128, 124, 112, 90])
    tor = np.minimum(np.minimum(al_tor - af, ab - al_tor) * np.pi / 180 * r_tor, (4.43 - y) * 0.6)
    belt = np.minimum(y - 3.205, 3.352 - y)
    tor = np.where((y > 3.205) & (y < 3.352), belt, np.where(y >= 3.352, tor, -1.0))
    pan[is_torso] = tor[is_torso]
    arm_p = np.minimum(np.minimum((np.abs(th_arm) - 132) * np.pi / 180 * r_arm, y - 2.835), 4.28 - y)
    pan[is_arm] = arm_p[is_arm]
    boot_top = 0.99 + 0.075 * np.maximum(np.cos(np.radians(ph_leg + 90)), 0) ** 3
    leg_p = np.minimum((np.abs(ph_leg) - 141) * np.pi / 180 * r_leg, y - (boot_top + 0.035))
    pan[is_leg] = leg_p[is_leg]
    panel = smooth(-AA, AA, pan) * (~is_head)
    # web-shooter cuffs
    cuff_sd = np.maximum(np.abs(y - 2.775) - 0.06, -1) * is_arm + (~is_arm) * 1.0
    cuff = cover(cuff_sd)
    # boots (below boot_top): same suit colour, glossier, with a piped edge
    boot_sd = np.where(is_leg | is_foot, y - boot_top, 1.0)
    boot = cover(boot_sd)
    seam_sd = np.where(is_head | is_hand | is_foot, 1.0, np.minimum(np.abs(pan), np.abs(boot_sd)))
    seam_sd = np.minimum(seam_sd, np.where(is_arm, np.abs(cuff_sd), 1.0))
    seam = np.exp(-(seam_sd / 0.0016) ** 2)
    piping = np.exp(-((seam_sd - 0.0042) / 0.0018) ** 2)

    # knee and elbow guards (raised suit-colour plates with a piped outline)
    knee_sd = np.sqrt(((np.radians(ph_leg + 90) * r_leg) / 0.088) ** 2 + ((y - 1.6) / 0.118) ** 2) - 1
    knee_sd = np.where(is_leg, knee_sd * 0.088, 1.0)
    elb_sd = np.sqrt(((np.radians(th_arm - 90) * r_arm) / 0.064) ** 2 + ((y - 3.5) / 0.088) ** 2) - 1
    elb_sd = np.where(is_arm, elb_sd * 0.064, 1.0)
    guard_sd = np.minimum(knee_sd, elb_sd)
    guard = cover(guard_sd)
    guard_edge = np.exp(-(guard_sd / 0.0016) ** 2)

    # web-shooter: gold ring at the top of the cuff, spinneret plate on the inner wrist
    ring = cover(np.abs(y - 2.823) - 0.0042) * is_arm
    arc_in = (180 - np.abs(th_arm)) * np.pi / 180 * r_arm
    qx, qy = arc_in - 0.024, np.abs(y - 2.772) - 0.03
    noz_sd = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - 0.006
    noz_sd = np.where(is_arm, noz_sd, 1.0)
    nozzle = cover(noz_sd)
    noz_dot = cover(np.where(is_arm, np.hypot(arc_in, y - 2.772) - 0.0085, 1.0))
    # boots: toe cap and sole welt
    lxf = x - 0.25 * side
    toe_sd = np.where(is_foot, (z + 0.385 - 0.07 * (lxf / 0.12) ** 2) * -1, 1.0)
    toe = cover(-toe_sd) * is_foot
    toe_seam = np.exp(-(toe_sd / 0.0016) ** 2) * is_foot
    welt = (is_foot & (y < 0.058) & (N[:, 1] > -0.5)).astype(float)

    # palms and finger pads: hex grip
    palm = is_hand & ((-N[:, 0] * side) > 0.3)
    palm_w = palm * smooth(0.3, 0.45, -N[:, 0] * side)

    # ---- emblems (2D, front and back), buckle ---------------------------------------------
    ceph_sd = np.full(n, 1.0)
    abdo_sd = np.full(n, 1.0)
    fr = is_torso & (z < 0) & (N[:, 2] < -0.2)
    bk = is_torso & (z > 0) & (N[:, 2] > 0.2)
    if fr.any():
        ceph_sd[fr] = poly_sd(x[fr], y[fr] - FRONT_Y0, scaled(CEPH, FRONT_K))
        abdo_sd[fr] = poly_sd(x[fr], y[fr] - FRONT_Y0, scaled(ABDO, FRONT_K))
    if bk.any():
        ceph_sd[bk] = poly_sd(x[bk], y[bk] - BACK_Y0, scaled(CEPH, BACK_K))
        abdo_sd[bk] = poly_sd(x[bk], y[bk] - BACK_Y0, scaled(ABDO, BACK_K))
    buckle_sd = np.full(n, 1.0)
    if fr.any():
        buckle_sd[fr] = poly_sd(x[fr], y[fr], BUCKLE)
    gem_sd = np.minimum(ceph_sd, buckle_sd)
    ceph = cover(ceph_sd)
    abdo = cover(abdo_sd)
    abdo_rim = abdo * smooth(-0.0125 - AA, -0.0125 + AA, abdo_sd)  # bezel ring
    keel = abdo * cover(np.abs(x) - 0.0045 * np.clip(-abdo_sd / 0.02, 0.4, 1))
    enamel = abdo * (1 - abdo_rim) * (1 - keel)
    buckle = cover(buckle_sd)
    buckle_enamel = cover(buckle_sd + 0.011)

    # ---- strands ------------------------------------------------------------------------------
    dist, wid = strand_field(P, G)
    strand_cov = cover(dist - wid)
    channel = np.exp(-((dist - wid - 0.0019) / 0.0011) ** 2) * (dist > wid)

    # ---- visor ----------------------------------------------------------------------------------
    lens = np.zeros(n)
    rim = np.zeros(n)
    lens_h = np.zeros(n)
    lens_g = np.zeros(n)
    lens_in = np.zeros(n)
    face = is_head & (z < -0.05) & (N[:, 2] < -0.1)
    if face.any():
        ax_f, yf = np.abs(x[face]), y[face]
        dl = poly_sd(ax_f, yf, LENS)
        RW = 0.0085  # bezel width
        lens[face] = cover(dl)
        rim[face] = cover(dl - RW) * (1 - lens[face])
        inside = np.clip(-dl / 0.035, 0, 1)
        lens_in[face] = inside
        dome = 0.0075 + 0.0055 * np.sqrt(inside)
        bezel = 0.0105 * smooth(RW + 0.003, RW - 0.004, dl)
        lens_h[face] = np.where(dl < 0, dome, bezel)
        lens_g[face] = np.clip((yf - 5.14) / 0.15 + (ax_f - 0.04) / 0.4, 0, 1)
        dist[face] = np.where(dl < RW + 0.004, np.inf, dist[face])  # no strands under the visor
        strand_cov[face] = np.where(dl < RW + 0.004, 0.0, strand_cov[face])
        channel[face] = np.where(dl < RW + 0.004, 0.0, channel[face])

    # ---- micro surface -------------------------------------------------------------------------
    uv = triplanar_coords(P, N)
    hexv = hex_pattern(uv, 0.026)
    twill = np.sin((uv[:, 0] * 0.7 + uv[:, 1]) * 2 * np.pi / 0.006)
    ribs = np.sin(y * 2 * np.pi / 0.0115)
    grip = hex_pattern(uv, 0.0125)
    lens_hex = hex_pattern(np.stack([x, y], -1), 0.0105)
    sole = (is_foot & (y < 0.05) & (N[:, 1] < -0.5)).astype(float)
    tread = np.abs(np.sin(z * 2 * np.pi / 0.03))

    # ---- compose --------------------------------------------------------------------------------
    gold_m = np.clip(np.maximum.reduce([strand_cov, ceph, abdo_rim, keel, buckle * (1 - buckle_enamel), rim, ring, noz_dot]), 0, 1)
    base = np.tile(COL["suit"], (n, 1))
    base *= (0.95 + 0.05 * hexv)[:, None]
    base = base * (1 - guard[:, None]) + COL["guard"] * guard[:, None]
    pcol = COL["panel"] * (0.95 + 0.05 * (ribs * 0.5 + 0.5))[:, None]
    base = base * (1 - panel[:, None]) + pcol * panel[:, None]
    base = base * (1 - cuff[:, None]) + COL["panel"] * 0.9 * cuff[:, None]
    glove = (is_hand | (is_arm & (y < 2.715))).astype(float)
    base = base * (1 - glove[:, None]) + COL["glove"] * (0.96 + 0.04 * hexv)[:, None] * glove[:, None]
    base = base * (1 - boot[:, None]) + COL["glove"] * (0.96 + 0.04 * hexv)[:, None] * boot[:, None]
    base = base * (1 - toe[:, None] * 0.18)
    base = base * (1 - nozzle[:, None]) + COL["panel"] * 1.25 * nozzle[:, None]
    base = base * (1 - welt[:, None]) + COL["panel"] * 1.5 * welt[:, None]
    gcol = COL["grip"] * (0.85 + 0.15 * grip)[:, None]
    base = base * (1 - palm_w[:, None]) + gcol * palm_w[:, None]
    base = base * (1 - sole[:, None]) + COL["sole"] * (0.85 + 0.15 * tread)[:, None] * sole[:, None]
    dark = np.clip(0.55 * seam + 0.35 * guard_edge + 0.55 * channel + 0.5 * toe_seam, 0, 0.8)
    base = base * (1 - dark[:, None])
    base = base * (1 - enamel[:, None]) + COL["enamel"] * enamel[:, None]
    base = base * (1 - buckle_enamel[:, None]) + COL["enamel"] * buckle_enamel[:, None]
    # gold: brushed variation along the strand, slightly darker at the strand edges
    gold_shade = np.clip(1 - 0.25 * (dist / np.maximum(wid, 1e-4)) ** 2, 0.7, 1)
    gold_shade = np.where(strand_cov > 0.5, gold_shade, 1.0)
    base = base * (1 - gold_m[:, None]) + COL["gold"] * gold_shade[:, None] * gold_m[:, None]
    lcol = COL["lens_lo"] + (COL["lens_hi"] - COL["lens_lo"]) * lens_g[:, None]
    lcol = lcol * (0.72 + 0.28 * np.clip(lens_in * 1.8, 0, 1))[:, None] * (0.9 + 0.1 * lens_hex)[:, None]
    base = base * (1 - lens[:, None]) + lcol * lens[:, None]

    metal = gold_m * (1 - lens)
    rough = np.full(n, 0.6)
    rough = rough * (1 - panel) + 0.74 * panel
    rough = rough * (1 - guard) + 0.46 * guard
    rough = rough * (1 - boot) + 0.42 * boot
    rough = rough * (1 - glove) + 0.5 * glove
    rough = rough * (1 - cuff) + 0.5 * cuff
    rough = rough * (1 - palm_w) + 0.82 * palm_w
    rough = rough * (1 - toe) + 0.34 * toe
    rough = rough * (1 - welt) + 0.8 * welt
    rough = rough * (1 - nozzle) + 0.38 * nozzle
    rough = rough * (1 - sole) + 0.86 * sole
    rough = rough * (1 - gold_m) + 0.27 * gold_m
    rough = rough * (1 - lens) + 0.05 * lens

    h = 0.00035 * hexv * (1 - panel) + 0.00012 * twill * (1 - panel)
    h += 0.0005 * ribs * panel
    h += 0.0007 * grip * palm_w
    h -= 0.0009 * tread * sole
    h -= 0.0012 * seam
    h += 0.0008 * piping * (pan < 0)
    h += 0.0026 * guard * smooth(0.0, -0.006, guard_sd)
    h -= 0.0009 * guard_edge
    h += 0.0045 * cuff * smooth(0.0, -0.005, cuff_sd)
    h += 0.003 * nozzle * smooth(0.0, -0.004, noz_sd) + 0.0015 * noz_dot
    h += 0.0012 * toe - 0.0010 * toe_seam
    # strands: rounded inlay beads sunk in a fine channel
    bead = np.sqrt(np.clip(1 - (dist / np.maximum(wid, 1e-4)) ** 2, 0, 1))
    h += 0.0022 * bead
    h -= 0.0008 * channel
    # gems: faceted pyramids (the cephalothorax and buckle rise to a ridge)
    gem = np.clip(-gem_sd / 0.028, 0, 1)
    h = np.maximum(h, np.where(gem_sd < 0.0015, 0.0032 + 0.0042 * gem, h))
    h = np.maximum(h, np.where(abdo_sd < 0.0015, 0.003 * abdo_rim + 0.0012 * enamel + 0.0042 * keel, h))
    h = np.where(lens + rim > 0.01, np.maximum(h, lens_h), h)
    return base, rough, h, metal


def despeckle_ao(ao, mask, thresh=0.16):
    med = ndimage.median_filter(ao, size=11)
    bad = mask & (ao < med - thresh)
    bad = ndimage.binary_dilation(bad, iterations=3) & mask
    out = ao.copy()
    out[bad] = med[bad]
    return out, int(bad.sum())


def despeckle_normals(nrm, mask, max_deg=22):
    med = np.stack([ndimage.median_filter(nrm[..., c], size=11) for c in range(3)], -1)
    a = nrm * 2 - 1
    b = med * 2 - 1
    cosang = (a * b).sum(-1) / np.maximum(np.linalg.norm(a, axis=-1) * np.linalg.norm(b, axis=-1), 1e-6)
    bad = mask & (cosang < np.cos(np.radians(max_deg)))
    bad = ndimage.binary_dilation(bad, iterations=3) & mask
    out = nrm.copy()
    bn = b[bad] / np.maximum(np.linalg.norm(b[bad], axis=-1, keepdims=True), 1e-6)
    out[bad] = bn * 0.5 + 0.5
    return out, int(bad.sum())


# known high-poly bake streaks (left neck base, where the sculpt mesh had a pinched fold): the
# surface there is smooth, so the sculpt normal fades to flat and the AO to its local mean
REPAIR = [((-0.338, 4.755, -0.027), 0.045), ((-0.30, 4.774, 0.124), 0.04)]


def repair_zones(P2d, mask, sn, ao):
    w = np.zeros(mask.shape)
    for c, r in REPAIR:
        d = np.linalg.norm(P2d - np.asarray(c), axis=-1)
        w = np.maximum(w, smooth(r, r * 0.55, d))
    w *= mask
    if not w.any():
        return sn, ao, 0
    flat = np.array([0.5, 0.5, 1.0])
    sn = sn * (1 - w[..., None]) + flat * w[..., None]
    mf = mask.astype(float)
    mean = ndimage.uniform_filter(ao * mf, 41) / np.maximum(ndimage.uniform_filter(mf, 41), 1e-6)
    ao = ao * (1 - w) + mean * w
    return sn, ao, int((w > 0.01).sum())


def dilate(img, mask, iters=12):
    """Pushes island colors outward so mip-mapping and seams don't bleed background."""
    img = img.copy()
    m = mask.copy()
    for _ in range(iters):
        acc = np.zeros_like(img)
        cnt = np.zeros(m.shape, float)
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (1, -1), (-1, 1)):
            sh = np.roll(np.roll(img, dy, 0), dx, 1)
            sm = np.roll(np.roll(m, dy, 0), dx, 1)
            acc += sh * sm[..., None]
            cnt += sm
        grow = (~m) & (cnt > 0)
        img[grow] = acc[grow] / cnt[grow][..., None]
        m = m | grow
    return img, m


if __name__ == "__main__":
    sets = sys.argv[1:] or SETS
    for set_name in sets:
        P, N, B, mask = load_set(set_name)
        H, W = mask.shape
        idx = np.nonzero(mask.ravel())[0]
        base, rough, hgt, metal = evaluate(P, N, B)
        ao = np.asarray(Image.open(os.path.join(mapdir, f"{set_name}_ao.png")).convert("L"), float) / 255.0
        ao = ao[::-1]  # Blender images are bottom-up
        # only smooth bake specks on broad surfaces; hands/feet keep their crisp crevices
        broad = np.zeros(mask.shape, bool)
        gg = groups_of(P, B)
        broad.ravel()[idx] = (gg != HAND) & (gg != FOOT)
        # texels the AO bake never reached (seams) read as black: inpaint them from valid neighbours
        hole = mask & (ao < 0.03)
        if hole.any():
            filled, _ = dilate(ao[..., None], mask & ~hole, 40)
            ao = np.where(hole, filled[..., 0], ao)
        print(f"{set_name}: inpainted {int(hole.sum())} unbaked AO texels")
        ao, nfix = despeckle_ao(ao, broad)
        sn_path = os.path.join(mapdir, f"{set_name}_sculptnormal.png")
        sn = np.asarray(Image.open(sn_path).convert("RGB"), float)[::-1] / 255.0
        sn, nfix2 = despeckle_normals(sn, broad)
        P2d = np.load(os.path.join(mapdir, f"{set_name}_data.npz"))["P"]
        sn, ao, nrep = repair_zones(P2d, mask, sn, ao)
        if nrep:
            print(f"{set_name}: repaired {nrep} texels in bake-streak zones")
        Image.fromarray((np.clip(sn[::-1], 0, 1) * 255 + 0.5).astype(np.uint8)).save(
            os.path.join(mapdir, f"{set_name}_sculptnormal_clean.png"))
        print(f"{set_name}: despeckled {nfix} AO texels, {nfix2} normal texels")
        aof = ao.ravel()[idx]
        base = base * (0.62 + 0.38 * aof[:, None] ** 0.8)
        color = np.zeros((H * W, 3))
        color[idx] = base
        rmap = np.full((H * W, 1), 0.55)
        rmap[idx, 0] = rough
        hmap = np.zeros((H * W, 1))
        hmap[idx, 0] = hgt
        mmap = np.zeros((H * W, 1))
        mmap[idx, 0] = metal
        cimg, _ = dilate(color.reshape(H, W, 3), mask, 16)
        rimg, _ = dilate(rmap.reshape(H, W, 1), mask, 16)
        himg, _ = dilate(hmap.reshape(H, W, 1), mask, 16)
        mimg, _ = dilate(mmap.reshape(H, W, 1), mask, 16)
        flip = lambda a: a[::-1]  # back to image (top-down) order
        Image.fromarray((np.clip(flip(cimg), 0, 1) * 255 + 0.5).astype(np.uint8)).save(os.path.join(outdir, f"{set_name}_Color.png"))
        Image.fromarray((np.clip(flip(rimg[..., 0]), 0, 1) * 255 + 0.5).astype(np.uint8)).save(os.path.join(outdir, f"{set_name}_Roughness.png"))
        h16 = np.clip(flip(himg[..., 0]) / HEIGHT_RANGE + 0.5, 0, 1)
        Image.fromarray((h16 * 65535 + 0.5).astype(np.uint16)).save(os.path.join(outdir, f"{set_name}_Height.png"))
        Image.fromarray((np.clip(flip(mimg[..., 0]), 0, 1) * 255 + 0.5).astype(np.uint8)).save(os.path.join(outdir, f"{set_name}_Metal.png"))
        print(set_name, "textures written")
