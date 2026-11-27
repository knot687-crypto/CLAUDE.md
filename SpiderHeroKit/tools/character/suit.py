"""
Suit evaluator: turns the baked rest-pose position/normal/bone maps into PBR textures.
Every texel is computed from its 3D position on the body, so the design is continuous across UV
seams and resolution independent. Outputs per material set (out/textures/):
  <Set>_Color.png (sRGB), <Set>_Roughness.png, <Set>_Height.png (16-bit, 0.5 = surface,
  1 unit = HEIGHT_RANGE studs), <Set>_Metal.png
Design: classic crimson/navy web-slinger suit (original emblem design), raised web lines,
beveled emblems, framed domed lenses, hex rubber emboss on red, fine weave on blue.
"""
import os, sys, json
import numpy as np
from PIL import Image

here = os.path.dirname(__file__)
mapdir = os.path.join(here, "out", "maps")
outdir = os.path.join(here, "out", "textures")
os.makedirs(outdir, exist_ok=True)
bones = json.load(open(os.path.join(mapdir, "bones.json")))
HEIGHT_RANGE = 0.03  # studs mapped to [0,1]

SRGB = lambda *c: np.array(c, float) / 255.0
COL = dict(
    red=SRGB(150, 8, 20), red_dark=SRGB(105, 5, 14),
    blue=SRGB(14, 28, 86), blue_dark=SRGB(9, 18, 58),
    web=SRGB(16, 7, 9), emblem=SRGB(14, 12, 15),
    lens=SRGB(228, 233, 240), lens_edge=SRGB(150, 160, 175), frame=SRGB(10, 10, 12),
    sole=SRGB(38, 12, 15),
)


def smooth(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def interp(y, xs, ys):
    return np.interp(y, xs, ys)


# ---------------------------------------------------------------------------------------------
# geometric helpers
# ---------------------------------------------------------------------------------------------
def polar_web(P, center, pole_point, n_rad, rings, sag=0.07, phase=0.0, up=(0, 1, 0)):
    """Distance (studs) to a polar web: radials around the pole + polygonal sagging strands."""
    a = np.asarray(pole_point, float) - np.asarray(center, float)
    a /= np.linalg.norm(a)
    u = np.asarray(up, float) - a * np.dot(up, a)
    u /= np.linalg.norm(u)
    w = np.cross(a, u)
    v = P - center
    R = np.linalg.norm(v, axis=1) + 1e-9
    cos_t = np.clip(v @ a / R, -1, 1)
    theta = np.arccos(cos_t)
    phi = np.arctan2(v @ w, v @ u) - phase
    dphi = 2 * np.pi / n_rad
    k = np.round(phi / dphi)
    d_rad = R * np.sin(theta) * np.abs(phi - k * dphi)
    # strands: polygonal chords between radials, sagging toward the hub
    base = np.floor(phi / dphi) * dphi
    mid = base + dphi / 2
    t = (phi - mid) / (dphi / 2)
    poly = np.cos(dphi / 2) / np.cos(phi - mid)
    d_ring = np.full(len(P), 9.0)
    for th in rings:
        tr = th * poly * (1 - sag * (1 - t * t))
        d_ring = np.minimum(d_ring, R * np.abs(theta - tr))
    return np.minimum(d_rad, d_ring), theta


def cyl_web(P, axis_pt, axis_dir, n_long, y0, spacing, sag=0.02, phase=0.0, ref=(1, 0, 0)):
    """Distance to a cylindrical web around an axis: longitudinal lines + sagging rings."""
    ad = np.asarray(axis_dir, float)
    ad /= np.linalg.norm(ad)
    r0 = np.asarray(ref, float) - ad * np.dot(ref, ad)
    r0 /= np.linalg.norm(r0)
    r1 = np.cross(ad, r0)
    v = P - axis_pt
    along = v @ ad
    radial = v - np.outer(along, ad)
    rr = np.linalg.norm(radial, axis=1) + 1e-9
    ang = np.arctan2(radial @ r1, radial @ r0) - phase
    dang = 2 * np.pi / n_long
    k = np.round(ang / dang)
    d_long = rr * np.abs(ang - k * dang)
    base = np.floor(ang / dang) * dang
    t = (ang - (base + dang / 2)) / (dang / 2)
    yy = along - y0 + sag * (1 - t * t)
    d_ring = np.abs(yy - np.round(yy / spacing) * spacing)
    return np.minimum(d_long, d_ring), ang


def ellipse_sd(u, v, cx, cy, a, b):
    q = np.sqrt(((u - cx) / a) ** 2 + ((v - cy) / b) ** 2)
    return (q - 1) * min(a, b)


def tapered_segment_sd(u, v, p0, p1, w0, w1):
    p0, p1 = np.asarray(p0, float), np.asarray(p1, float)
    d = p1 - p0
    L2 = d @ d
    tt = np.clip(((u - p0[0]) * d[0] + (v - p0[1]) * d[1]) / L2, 0, 1)
    px, py = p0[0] + d[0] * tt, p0[1] + d[1] * tt
    return np.hypot(u - px, v - py) - (w0 + (w1 - w0) * tt) / 2


# original spider emblem (right half; mirrored), in studs around its own center
EMBLEM_BODY = [(0, 0.075, 0.026, 0.03), (0, 0.028, 0.045, 0.058), (0, -0.098, 0.058, 0.1), (0, -0.205, 0.027, 0.05)]
EMBLEM_LEGS = [
    [(0.03, 0.06), (0.11, 0.16), (0.12, 0.315)],
    [(0.04, 0.035), (0.17, 0.085), (0.275, 0.175)],
    [(0.04, -0.012), (0.17, -0.045), (0.265, -0.165)],
    [(0.035, -0.045), (0.11, -0.155), (0.12, -0.31)],
]


def emblem_sd(u, v, scale):
    u, v = np.abs(u) / scale, v / scale  # symmetric
    d = np.full(u.shape, 9.0)
    for cx, cy, a, b in EMBLEM_BODY:
        d = np.minimum(d, ellipse_sd(u, v, cx, cy, a, b))
    for leg in EMBLEM_LEGS:
        d = np.minimum(d, tapered_segment_sd(u, v, leg[0], leg[1], 0.04, 0.03))
        d = np.minimum(d, tapered_segment_sd(u, v, leg[1], leg[2], 0.03, 0.012))
    return d * scale


def lens_sd(x, y, side):
    """Signed distance (studs, approx) to a lens outline: almond with an upswept outer corner."""
    cx, cy = 0.112 * side, 5.178
    tilt = np.radians(19)
    s = ((x - cx) * side) * np.cos(tilt) + (y - cy) * np.sin(tilt)
    t = -((x - cx) * side) * np.sin(tilt) + (y - cy) * np.cos(tilt)
    a = np.where(s > 0, 0.118, 0.072)
    b = 0.07
    t2 = t - 0.22 * np.maximum(s, 0) ** 2 / 0.118  # sweep the outer corner up
    bb = b * (1 - 0.35 * np.clip(s / 0.118, 0, 1) ** 1.6)  # taper toward the outer point
    n = 2.3
    f = ((np.abs(s) / a) ** n + (np.abs(t2) / bb) ** n) ** (1 / n)
    return (f - 1) * np.minimum(a, bb)


def hex_pattern(uv, size):
    """Distance to hex cell edges (0 at edges), normalized 0..1 at cell centers."""
    q = uv / size
    r = np.array([1.0, np.sqrt(3)])
    h = r * 0.5
    a = np.mod(q, r) - h
    b = np.mod(q - h, r) - h
    g = np.where((a * a).sum(-1, keepdims=True) < (b * b).sum(-1, keepdims=True), a, b)
    # hex distance from center
    gx, gy = np.abs(g[..., 0]), np.abs(g[..., 1])
    hexd = np.maximum(gx * 0.866025 + gy * 0.5, gy)
    return np.clip(1 - hexd / 0.5, 0, 1)


def triplanar_coords(P, N):
    ax = np.argmax(np.abs(N), axis=1)
    uv = np.stack([np.where(ax == 0, P[:, 2], P[:, 0]), np.where(ax == 1, P[:, 2], P[:, 1])], -1)
    return uv


# ---------------------------------------------------------------------------------------------
def evaluate(P, N, B):
    n = len(P)
    x, y, z = P[:, 0], P[:, 1], P[:, 2]
    name = np.array(bones)[np.clip(B, 0, len(bones) - 1)]
    is_head = name == "Head"
    is_torso = np.isin(name, ["UpperTorso", "LowerTorso", "HumanoidRootNode", "Root"])
    is_arm = np.array([("Arm" in s) for s in name])
    is_hand = np.array([("Hand" in s) or any(f in s for f in ("Thumb", "Index", "Middle", "Ring", "Pinky")) for s in name])
    is_leg = np.array([("Leg" in s) for s in name])
    # the hips belong to the torso design (belt/trunks), whatever bone dominates the face
    hip_zone = is_leg & (y > 3.02)
    is_torso = is_torso | hip_zone
    is_leg = is_leg & ~hip_zone
    is_foot = np.array([("Foot" in s) for s in name])
    side = np.where(x >= 0, 1.0, -1.0)

    # ---- red/blue regions (signed distance-ish, + = red) ---------------------------------------
    s = np.full(n, -1.0)
    s[is_head] = 1.0
    s[is_hand] = 1.0
    s[is_foot] = 1.0
    # torso panels + belt
    front = z < 0.02
    wF = interp(y, [3.2, 3.5, 3.75, 4.0, 4.2, 4.38, 4.52, 4.8], [0.25, 0.25, 0.27, 0.32, 0.42, 0.56, 0.72, 0.72])
    wB = interp(y, [3.2, 3.5, 3.75, 4.0, 4.2, 4.38, 4.5, 4.8], [0.22, 0.22, 0.23, 0.28, 0.38, 0.55, 0.72, 0.72])
    panel = np.where(front, wF, wB) - np.abs(x)
    belt = np.minimum(y - 3.205, 3.352 - y)
    torso_s = np.where(y > 3.205, np.maximum(panel, belt), np.minimum(belt, -0.01))
    s[is_torso] = torso_s[is_torso]
    # arms: shoulder cap, outer stripe, glove
    ax_x = 0.62 * side
    theta_arm = np.arctan2(z - 0.03, (x - ax_x) * side)  # 0 = outward
    cap = y - (4.24 - 0.08 * np.cos(theta_arm))
    stripe = (np.cos(theta_arm) - np.cos(np.radians(40))) * 0.14
    glove = (3.03 + 0.045 * np.cos(theta_arm - np.pi)) - y
    arm_s = np.maximum(np.maximum(cap, stripe), glove)
    s[is_arm] = arm_s[is_arm]
    # legs: boots with a raised front point
    lx = 0.25 * side
    theta_leg = np.arctan2(x - lx, -(z - 0.0))  # 0 = front (-Z)
    boot_top = 0.99 + 0.075 * np.maximum(np.cos(theta_leg), 0) ** 3
    leg_s = boot_top - y
    s[is_leg] = leg_s[is_leg]
    red = smooth(-0.0035, 0.0035, s)

    # ---- web lines --------------------------------------------------------------------------
    dl = np.full(n, 9.0)
    lw = np.full(n, 0.0105)  # half width
    # head web above the jaw line, torso webs below (a clean seam instead of a ragged bone-label edge)
    head_sys = (is_head | is_torso) & (y > 4.86 - 0.18 * np.clip(z + 0.05, 0, 1))
    torso_sys = (is_head | is_torso) & ~head_sys
    if head_sys.any():
        dh, th = polar_web(P[head_sys], np.array([0, 5.15, 0.0]), np.array([0, 5.185, -0.33]), 12,
                           np.radians([15, 29, 45, 62, 81, 101, 123, 146]), sag=0.075)
        dl[head_sys] = dh
        lw[head_sys] = 0.0095
    if torso_sys.any():
        # one continuous polar web whose axis runs through the chest and back emblems, so the
        # strands wrap from front to back over the shoulders without a seam
        Pt = P[torso_sys]
        c = np.array([0, 4.15, 0.0])
        dt_, _ = polar_web(Pt, c, np.array([0, 4.205, -0.38]), 14,
                           np.radians([12, 25, 39, 54, 70, 87, 104, 121, 138, 155, 168]), sag=0.08, phase=np.pi / 14)
        dl[torso_sys] = dt_
        lw[torso_sys] = 0.011
    for mask, axis_pt, axis_dir, nl, spacing, wdt in (
        (is_arm | is_hand, None, (0, 1, 0), 10, 0.105, 0.0095),
        (is_leg, None, (0, 1, 0), 12, 0.105, 0.0105),
    ):
        if not mask.any():
            continue
        Pm = P[mask]
        sx = np.where(Pm[:, 0] >= 0, 1.0, -1.0)
        out = np.full(len(Pm), 9.0)
        for sv in (1.0, -1.0):
            sel = sx == sv
            if not sel.any():
                continue
            ap = np.array([0.62 * sv, 0.0, 0.03]) if mask is not is_leg else np.array([0.25 * sv, 0.0, 0.0])
            d_, _ = cyl_web(Pm[sel], ap, axis_dir, nl, 0.0, spacing, sag=0.018, phase=np.pi / nl, ref=(sv, 0, 0))
            out[sel] = d_
        dl[mask] = out
        lw[mask] = wdt
    if is_foot.any():
        Pf = P[is_foot]
        sx = np.where(Pf[:, 0] >= 0, 1.0, -1.0)
        out = np.full(len(Pf), 9.0)
        for sv in (1.0, -1.0):
            sel = sx == sv
            if sel.any():
                d_, _ = cyl_web(Pf[sel], np.array([0.25 * sv, 0.12, 0.2]), (0, -0.25, -1.0), 10, 0.0, 0.1, sag=0.015, phase=np.pi / 10, ref=(0, 1, 0))
                out[sel] = d_
        dl[is_foot] = out
        lw[is_foot] = 0.0095
    line = 1 - smooth(lw - 0.0022, lw + 0.0022, dl)
    line *= red  # only on red

    # ---- emblems --------------------------------------------------------------------------------
    emb = np.zeros(n)
    emb_h = np.zeros(n)
    if is_torso.any():
        m = is_torso & (z < 0)
        e = emblem_sd(x[m], y[m] - 4.205, 1.28)
        emb[m] = 1 - smooth(-0.002, 0.002, e)
        emb_h[m] = 0.0042 * smooth(0.0, 0.009, -e)
        m = is_torso & (z >= 0)
        e = emblem_sd(x[m], y[m] - 4.15, 1.5)
        emb[m] = 1 - smooth(-0.002, 0.002, e)
        emb_h[m] = 0.0042 * smooth(0.0, 0.009, -e)

    # ---- lenses -----------------------------------------------------------------------------------
    lens = np.zeros(n)
    frame = np.zeros(n)
    lens_h = np.zeros(n)
    lens_shade = np.zeros(n)
    if is_head.any():
        m = is_head & (z < -0.12)
        xm, ym = x[m], y[m]
        dlens = np.minimum(lens_sd(xm, ym, 1), lens_sd(xm, ym, -1))
        FW = 0.024
        lens[m] = 1 - smooth(-0.0016, 0.0016, dlens)
        frame[m] = (1 - smooth(FW - 0.002, FW + 0.002, dlens)) * (1 - lens[m])
        inside = np.clip(-dlens / 0.06, 0, 1)
        lens_h[m] = np.where(dlens < 0, 0.0085 + 0.007 * np.sqrt(inside), 0.012 * smooth(FW + 0.004, FW - 0.006, dlens))
        # lens shading: brighter top-outer, a soft darker rim near the frame
        lens_shade[m] = 0.78 + 0.22 * np.clip(inside * 1.6, 0, 1)
        line[m] *= (1 - smooth(FW - 0.004, FW + 0.006, -dlens + FW) * 0) * (dlens > FW)  # no web under lenses

    # ---- micro surface ---------------------------------------------------------------------------
    uv = triplanar_coords(P, N)
    hexv = hex_pattern(uv, 0.024)
    weave = np.sin((uv[:, 0] + uv[:, 1]) * 2 * np.pi / 0.014) * np.sin((uv[:, 0] - uv[:, 1]) * 2 * np.pi / 0.014)
    seam = np.exp(-(s / 0.0045) ** 2) * (~is_head) * (~is_hand) * (~is_foot)

    # ---- compose ------------------------------------------------------------------------------------
    base = COL["blue"][None, :] * (1 - red[:, None]) + COL["red"][None, :] * red[:, None]
    # subtle tonal variation in the fabric
    base *= (0.94 + 0.06 * hexv)[:, None] * red[:, None] + (0.96 + 0.04 * (weave * 0.5 + 0.5))[:, None] * (1 - red[:, None])
    base = base * (1 - 0.45 * seam[:, None])
    base = base * (1 - line[:, None]) + COL["web"][None, :] * line[:, None]
    base = base * (1 - emb[:, None]) + COL["emblem"][None, :] * emb[:, None]
    sole = (is_foot & (y < 0.035) & (N[:, 1] < -0.55)).astype(float)
    base = base * (1 - sole[:, None]) + COL["sole"][None, :] * sole[:, None]
    lens_col = COL["lens_edge"][None, :] + (COL["lens"] - COL["lens_edge"])[None, :] * lens_shade[:, None]
    base = base * (1 - lens[:, None]) + lens_col * lens[:, None]
    base = base * (1 - frame[:, None]) + COL["frame"][None, :] * frame[:, None]

    rough = 0.6 * red + 0.68 * (1 - red)
    rough = rough * (1 - line) + 0.46 * line
    rough = rough * (1 - emb) + 0.48 * emb
    rough = rough * (1 - frame) + 0.26 * frame
    rough = rough * (1 - lens) + 0.05 * lens
    rough = rough * (1 - sole) + 0.75 * sole

    h = 0.0006 * hexv * red * (1 - line) + 0.0003 * weave * (1 - red)
    h += 0.0042 * np.sqrt(np.clip(1 - (dl / np.maximum(lw, 1e-4)) ** 2, 0, 1)) * red
    h -= 0.0016 * seam
    h = np.maximum(h, emb_h + 0.0005 * hexv * 0)
    h = np.where(lens + frame > 0.01, np.maximum(h, lens_h), h)
    return base, rough, h


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


def to_srgb(c):
    return c  # colors above are already sRGB-encoded design values


if __name__ == "__main__":
    sets = sys.argv[1:] or ["SuitHead", "SuitTorso", "SuitArms", "SuitLegs"]
    for set_name in sets:
        dd = np.load(os.path.join(mapdir, f"{set_name}_data.npz"))
        P, N, B, mask = dd["P"], dd["N"], dd["B"], dd["mask"]
        H, W = mask.shape
        idx = np.nonzero(mask.ravel())[0]
        base, rough, hgt = evaluate(P.reshape(-1, 3)[idx], N.reshape(-1, 3)[idx], B.ravel()[idx])
        ao = np.asarray(Image.open(os.path.join(mapdir, f"{set_name}_ao.png")).convert("L"), float) / 255.0
        ao = ao[::-1]  # Blender images are bottom-up
        aof = ao.ravel()[idx]
        base = base * (0.6 + 0.4 * aof[:, None] ** 0.8)
        color = np.zeros((H * W, 3))
        color[idx] = base
        rmap = np.full((H * W, 1), 0.55)
        rmap[idx, 0] = rough
        hmap = np.full((H * W, 1), 0.0)
        hmap[idx, 0] = hgt
        cimg, _ = dilate(color.reshape(H, W, 3), mask, 16)
        rimg, _ = dilate(rmap.reshape(H, W, 1), mask, 16)
        himg, _ = dilate(hmap.reshape(H, W, 1), mask, 16)
        flip = lambda a: a[::-1]  # back to image (top-down) order
        Image.fromarray((np.clip(flip(cimg), 0, 1) * 255 + 0.5).astype(np.uint8)).save(os.path.join(outdir, f"{set_name}_Color.png"))
        Image.fromarray((np.clip(flip(rimg[..., 0]), 0, 1) * 255 + 0.5).astype(np.uint8)).save(os.path.join(outdir, f"{set_name}_Roughness.png"))
        h16 = np.clip(flip(himg[..., 0]) / HEIGHT_RANGE + 0.5, 0, 1)
        Image.fromarray((h16 * 65535 + 0.5).astype(np.uint16)).save(os.path.join(outdir, f"{set_name}_Height.png"))
        Image.fromarray(np.zeros((H, W), np.uint8)).save(os.path.join(outdir, f"{set_name}_Metal.png"))
        print(set_name, "textures written")
