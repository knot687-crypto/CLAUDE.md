"""
SpiderHero anatomy: an athletic, skin-tight-suit superhero sculpted from signed-distance primitives.

All primitives are authored in the R15 rest pose ("I-pose": arms straight down, palms facing the
thighs), in Roblox space (Y up, facing -Z, studs), on the same joint pivots as RigDefinition.luau.
`build(apose=True)` returns them moved into an A-pose (arms abducted 45 deg, legs 5 deg) so the
limbs stay separated for clean polygonization and skin weighting; the rig later re-poses the
skinned mesh back to the R15 rest pose.
"""
import numpy as np
from sdf import Prim, rot

SHOULDER = {"Right": np.array([0.62, 4.44, 0.03]), "Left": np.array([-0.62, 4.44, 0.03])}
HIP = {"Right": np.array([0.25, 2.88, 0.0]), "Left": np.array([-0.25, 2.88, 0.0])}
ARM_ABDUCT = 45.0
LEG_ABDUCT = 8.0

# finger layout (right hand, I-pose): base pivot z, base y, phalanx lengths, radii (base, j1, j2, tip), spread deg
FINGERS = {
    "Index": dict(z=-0.092, y=2.366, lens=(0.125, 0.08, 0.066), radii=(0.033, 0.03, 0.027, 0.0225), spread=17.0),
    "Middle": dict(z=-0.03, y=2.356, lens=(0.135, 0.088, 0.071), radii=(0.034, 0.031, 0.028, 0.0235), spread=5.0),
    "Ring": dict(z=0.031, y=2.362, lens=(0.128, 0.081, 0.066), radii=(0.032, 0.0295, 0.0265, 0.022), spread=-7.0),
    "Pinky": dict(z=0.088, y=2.38, lens=(0.102, 0.063, 0.057), radii=(0.028, 0.0255, 0.023, 0.019), spread=-19.0),
}
THUMB_BASE = np.array([0.596, 2.6, -0.108])
THUMB_DIR = np.array([-0.34, -0.58, -0.74]) / np.linalg.norm([-0.34, -0.58, -0.74])
THUMB_LENS = (0.125, 0.06, 0.055)


def E(c, r, k=0.05, bone="UpperTorso", op="union", R=None):
    return Prim("ellipsoid", op, k, bone, c=np.array(c, float), r=np.array(r, float), R=np.eye(3) if R is None else R)


def RC(a, b, r1, r2, k=0.05, bone="UpperTorso", op="union", b_bone=None):
    extra = {} if b_bone is None else {"b_bone": b_bone}
    return Prim("roundcone", op, k, bone, a=np.array(a, float), b=np.array(b, float), r1=r1, r2=r2, **extra)


def RB(c, h, rr, k=0.05, bone="UpperTorso", op="union", R=None):
    return Prim("roundbox", op, k, bone, c=np.array(c, float), h=np.array(h, float), rr=rr, R=np.eye(3) if R is None else R)


class Groove:
    """A shallow, wide valley of exact depth/width carved into the surface. The axis endpoints are
    found by ray-marching the (union) field along -n from the hint points, then a capsule of radius
    r = (w^2/4 + d^2) / (2 d) is placed so it penetrates exactly `depth`."""

    def __init__(self, a, b, n, width, depth, k=0.03, bone="UpperTorso"):
        self.a, self.b = np.array(a, float), np.array(b, float)
        self.n = np.array(n, float) / np.linalg.norm(n)
        self.width, self.depth, self.k, self.bone = width, depth, k, bone

    def resolve(self, prims):
        from sdf import evaluate
        r = (self.width ** 2 / 4 + self.depth ** 2) / (2 * self.depth)
        ends = []
        for h in (self.a, self.b):
            ts = np.linspace(0.35, -0.35, 701)
            pts = (h[None, :] + ts[:, None] * self.n[None, :]).astype(np.float32)
            d = evaluate(prims, pts)
            idx = np.where((d[:-1] > 0) & (d[1:] <= 0))[0]
            if len(idx) == 0:
                surf = h
            else:
                i = idx[0]
                f = d[i] / (d[i] - d[i + 1])
                surf = pts[i] + (pts[i + 1] - pts[i]) * f
            ends.append(surf + self.n * (r - self.depth))
        return RC(ends[0], ends[1], r, r, k=self.k, bone=self.bone, op="sub")


class Ridge(Groove):
    """A subtle raised form of exact height (e.g. clavicles): capsule axis placed so it protrudes
    `height` above the surface found by ray-marching."""

    def resolve(self, prims):
        from sdf import evaluate
        r = self.width / 2
        ends = []
        for h in (self.a, self.b):
            ts = np.linspace(0.35, -0.35, 701)
            pts = (h[None, :] + ts[:, None] * self.n[None, :]).astype(np.float32)
            d = evaluate(prims, pts)
            idx = np.where((d[:-1] > 0) & (d[1:] <= 0))[0]
            surf = h if len(idx) == 0 else pts[idx[0]] + (pts[idx[0] + 1] - pts[idx[0]]) * (d[idx[0]] / (d[idx[0]] - d[idx[0] + 1]))
            ends.append(surf - self.n * (r - self.depth))
        return RC(ends[0], ends[1], r, r, k=self.k, bone=self.bone, op="union")


def mirror_prim(p):
    """Mirror a right-side primitive to the left (x -> -x)."""
    M = np.diag([-1.0, 1.0, 1.0])
    q = dict(p.p)
    if p.kind in ("ellipsoid", "roundbox"):
        q["c"] = M @ q["c"]
        q["R"] = M @ q["R"] @ M
    elif p.kind == "roundcone":
        q["a"] = M @ q["a"]
        q["b"] = M @ q["b"]
        if "b_bone" in q and q["b_bone"].startswith("Right"):
            q["b_bone"] = q["b_bone"].replace("Right", "Left")
    bone = p.bone.replace("Right", "Left") if p.bone.startswith("Right") else p.bone
    return Prim(p.kind, p.op, p.k, bone, **q)


def torso():
    """Big forms first (thorax, girdle, abdomen, pelvis, back), then moderate muscle masses with
    soft blends, then subtle grooves. Targets (athletic male, 180 cm = 5.55 studs): chest 1.05 wide
    x 0.74 deep, waist 0.86 x 0.6, hips 1.0 wide."""
    P = []
    U, L = "UpperTorso", "LowerTorso"
    P.append(E([0, 4.03, 0.0], [0.465, 0.56, 0.32], k=0.0, bone=U))  # thorax
    P.append(E([0, 4.36, 0.0], [0.545, 0.25, 0.29], k=0.14, bone=U))  # shoulder girdle
    P.append(E([0, 4.2, 0.17], [0.43, 0.38, 0.17], k=0.12, bone=U))  # broad upper back
    P.append(E([0, 3.5, 0.0], [0.42, 0.34, 0.285], k=0.15, bone=U))  # abdomen / waist
    for s in (1, -1):
        P.append(E([0.2 * s, 4.18, -0.215], [0.245, 0.162, 0.122], k=0.06, bone=U, R=rot(0, -16 * s, 14 * s)))  # pectorals
        side = "Right" if s > 0 else "Left"
        # axillary folds: stretched from the torso to the humerus insertion (arm end follows the arm)
        P.append(RC([0.3 * s, 4.23, -0.15], [0.58 * s, 4.2, -0.05], 0.085, 0.07, k=0.1, bone=U, b_bone=side + "UpperArm"))  # pectoral fold
        P.append(RC([0.36 * s, 4.06, 0.13], [0.6 * s, 4.18, 0.08], 0.09, 0.072, k=0.1, bone=U, b_bone=side + "UpperArm"))  # posterior (lat/teres) fold
        P.append(RC([0.06 * s, 4.87, 0.05], [0.43 * s, 4.6, 0.045], 0.095, 0.065, k=0.1, bone=U))  # trapezius slope
        P.append(E([0.33 * s, 4.06, 0.1], [0.2, 0.4, 0.17], k=0.1, bone=U, R=rot(0, 0, -12 * s)))  # lats
        P.append(E([0.275 * s, 3.56, -0.02], [0.13, 0.25, 0.19], k=0.09, bone=U))  # external obliques
        P.append(RC([0.075 * s, 3.35, 0.2], [0.075 * s, 3.95, 0.215], 0.07, 0.055, k=0.07, bone=U))  # erector spinae
        P.append(E([0.19 * s, 4.24, 0.225], [0.14, 0.17, 0.05], k=0.07, bone=U, R=rot(0, 15 * s, 8 * s)))  # scapulae
        P.append(E([0.34 * s, 4.2, 0.15], [0.12, 0.15, 0.1], k=0.08, bone=U))  # rotator cuff mass
        for i, y in enumerate((4.0, 3.9)):
            P.append(E([0.385 * s, y, -0.1 + 0.025 * i], [0.045, 0.03, 0.04], k=0.045, bone=U, R=rot(0, 0, -25 * s)))  # serratus
    P.append(E([0, 4.38, 0.2], [0.27, 0.32, 0.11], k=0.08, bone=U))  # mid trapezius
    P.append(E([0, 3.66, -0.21], [0.2, 0.38, 0.09], k=0.07, bone=U))  # rectus abdominis
    # lower torso
    P.append(E([0, 3.1, 0.03], [0.46, 0.3, 0.26], k=0.14, bone=L))  # pelvis
    for s in (1, -1):
        P.append(E([0.14 * s, 2.93, 0.14], [0.2, 0.22, 0.17], k=0.08, bone=L, R=rot(-8, 0, 0)))  # glutes
    P.append(E([0, 2.84, -0.02], [0.12, 0.1, 0.13], k=0.07, bone=L))  # groin
    # definition grooves: shallow valleys of exact depth/width resolved against the surface
    F = np.array([0, 0, -1.0])
    P.append(Groove([0, 4.42, -0.3], [0, 4.0, -0.3], F, 0.045, 0.007, k=0.03))  # sternum
    P.append(Groove([0, 3.96, -0.28], [0, 3.4, -0.27], F, 0.03, 0.0055, k=0.025))  # linea alba
    for y in (3.885, 3.75, 3.61):
        P.append(Groove([-0.15, y, -0.28], [0.15, y, -0.28], F, 0.032, 0.0045, k=0.025))  # six-pack
    for s_ in (1, -1):
        P.append(Groove([0.205 * s_, 3.29, -0.2], [0.07 * s_, 3.0, -0.23], np.array([0.25 * s_, 0, -1.0]), 0.04, 0.007, k=0.03, bone=L))  # V-cut
    P.append(Groove([0, 3.3, 0.25], [0, 4.5, 0.27], np.array([0, 0, 1.0]), 0.05, 0.008, k=0.035))  # spine
    P.append(Groove([0, 4.64, -0.12], [0, 4.6, -0.13], F, 0.07, 0.008, k=0.04))  # jugular notch
    for s_ in (1, -1):
        P.append(Ridge([0.06 * s_, 4.63, -0.1], [0.34 * s_, 4.645, -0.06], np.array([0.15 * s_, 0.45, -1.0]), 0.06, 0.0055, k=0.06))  # clavicles
    return P


def head():
    """Masked head: 0.74 tall, 0.5 wide, 0.62 deep. The fabric smooths everything: a soft nose
    ridge, a defined jaw and chin, shallow eye sockets for the lenses (added later as crisp
    displaced shapes), ears flattened under the mask."""
    H = "Head"
    P = []
    P.append(E([0, 5.27, 0.025], [0.252, 0.29, 0.3], k=0.06, bone=H))  # cranium
    P.append(E([0, 5.2, 0.08], [0.238, 0.25, 0.22], k=0.09, bone=H))  # occiput
    P.append(E([0, 5.1, -0.075], [0.228, 0.31, 0.24], k=0.09, bone=H))  # face mass
    P.append(E([0, 4.97, -0.08], [0.188, 0.13, 0.19], k=0.08, bone=H))  # jaw
    P.append(E([0, 4.885, -0.196], [0.072, 0.055, 0.055], k=0.06, bone=H))  # chin
    P.append(E([0, 5.075, -0.298], [0.03, 0.062, 0.032], k=0.06, bone=H, R=rot(-14, 0, 0)))  # nose ridge
    P.append(E([0, 5.03, -0.31], [0.034, 0.026, 0.026], k=0.04, bone=H))  # nose tip
    for s in (1, -1):
        P.append(E([0.15 * s, 4.99, -0.01], [0.055, 0.075, 0.075], k=0.07, bone=H))  # jaw angle
        P.append(E([0.125 * s, 5.075, -0.19], [0.065, 0.045, 0.055], k=0.09, bone=H))  # cheek planes
        P.append(E([0.242 * s, 5.14, 0.03], [0.012, 0.06, 0.045], k=0.05, bone=H))  # ears under the mask
        P.append(RC([0.15 * s, 5.03, 0.05], [0.04 * s, 4.64, -0.12], 0.045, 0.038, k=0.07, bone=H))  # sternocleidomastoid
    P.append(RC([0, 4.6, 0.02], [0, 4.98, 0.01], 0.19, 0.168, k=0.08, bone=H))  # neck
    P.append(E([0, 4.84, -0.15], [0.028, 0.036, 0.028], k=0.04, bone=H))  # larynx
    return P


def right_arm():
    """Upper arm 0.32 wide x 0.34 deep, forearm 0.29 at the top tapering to a 0.19 x 0.12 wrist,
    palm 0.27 broad x 0.1 thick (palm faces -X in the rest pose)."""
    UA, LA, HA = "RightUpperArm", "RightLowerArm", "RightHand"
    P = []
    P.append(E([0.665, 4.33, 0.02], [0.175, 0.27, 0.195], k=0.1, bone=UA, R=rot(0, 0, 12)))  # deltoid
    P.append(E([0.6, 4.36, -0.08], [0.12, 0.2, 0.1], k=0.09, bone=UA, R=rot(-8, 0, 12)))  # anterior deltoid
    P.append(E([0.62, 4.36, 0.12], [0.12, 0.19, 0.09], k=0.06, bone=UA, R=rot(8, 0, 12)))  # posterior deltoid
    P.append(RC([0.62, 4.32, 0.035], [0.62, 3.6, 0.045], 0.145, 0.115, k=0.07, bone=UA))  # upper arm
    P.append(E([0.6, 3.94, -0.065], [0.12, 0.24, 0.115], k=0.06, bone=UA))  # biceps
    P.append(E([0.62, 4.03, 0.11], [0.12, 0.27, 0.11], k=0.06, bone=UA))  # triceps long head
    P.append(E([0.69, 4.07, 0.06], [0.08, 0.2, 0.09], k=0.05, bone=UA))  # triceps lateral head
    P.append(E([0.69, 3.73, -0.01], [0.06, 0.13, 0.07], k=0.05, bone=UA))  # brachialis
    P.append(E([0.62, 3.5, 0.05], [0.1, 0.1, 0.1], k=0.06, bone=LA))  # elbow
    P.append(E([0.62, 3.49, 0.135], [0.045, 0.05, 0.035], k=0.03, bone=LA))  # olecranon
    P.append(RC([0.62, 3.45, 0.035], [0.62, 2.76, 0.02], 0.12, 0.07, k=0.06, bone=LA))  # forearm
    P.append(E([0.655, 3.28, -0.04], [0.09, 0.22, 0.09], k=0.05, bone=LA))  # extensors / brachioradialis
    P.append(E([0.58, 3.27, 0.02], [0.085, 0.22, 0.09], k=0.05, bone=LA))  # flexors
    P.append(RB([0.62, 2.725, 0.02], [0.037, 0.03, 0.057], 0.02, k=0.05, bone=LA))  # wrist
    # hand: palm faces -X, thumb toward -Z. Built like the skeleton: carpal block, a fan of
    # metacarpals to the knuckles, palm pads, then jointed fingers.
    P.append(E([0.62, 2.668, 0.015], [0.048, 0.062, 0.08], k=0.04, bone=HA))  # carpals
    for name, f in FINGERS.items():
        P.append(RC([0.624, 2.64, f["z"] * 0.42 + 0.01], [0.628, 2.39, f["z"]], 0.027, 0.03, k=0.028, bone=HA))  # metacarpal
        P.append(E([0.637, 2.386, f["z"]], [0.029, 0.03, 0.029], k=0.022, bone=HA))  # knuckle head
    P.append(E([0.598, 2.51, 0.0], [0.04, 0.12, 0.105], k=0.035, bone=HA))  # palm pad
    P.append(E([0.644, 2.515, 0.005], [0.022, 0.115, 0.1], k=0.035, bone=HA))  # dorsal arch
    P.append(E([0.587, 2.585, -0.08], [0.046, 0.088, 0.052], k=0.04, bone=HA, R=rot(25, 0, 0)))  # thenar
    P.append(E([0.598, 2.53, 0.098], [0.032, 0.1, 0.032], k=0.035, bone=HA))  # hypothenar
    for name, f in FINGERS.items():
        bone1 = "Right" + name + "1"
        bone2 = "Right" + name + "2"
        base = np.array([0.624, f["y"], f["z"]])
        d = rot(f["spread"], 0, 0) @ np.array([0.0, -1.0, 0.0])
        j1 = base + d * f["lens"][0]
        j2 = j1 + d * f["lens"][1]
        tip = j2 + d * f["lens"][2]
        r = f["radii"]
        P.append(RC(base, j1, r[0], r[1], k=0.014, bone=bone1))
        P.append(E(j1, [r[1] * 1.1, r[1] * 1.05, r[1] * 1.08], k=0.01, bone=bone2))  # PIP joint
        P.append(RC(j1, j2, r[1], r[2], k=0.008, bone=bone2))
        P.append(E(j2, [r[2] * 1.08, r[2] * 1.04, r[2] * 1.06], k=0.008, bone=bone2))  # DIP joint
        P.append(RC(j2, tip, r[2], r[3], k=0.008, bone=bone2))
    P.append(RC([0.61, 2.665, -0.045], THUMB_BASE, 0.043, 0.039, k=0.035, bone=HA))  # thumb metacarpal
    t1 = THUMB_BASE + THUMB_DIR * THUMB_LENS[0]
    t2 = t1 + THUMB_DIR * THUMB_LENS[1]
    tip = t2 + THUMB_DIR * THUMB_LENS[2]
    P.append(RC(THUMB_BASE, t1, 0.039, 0.033, k=0.016, bone="RightThumb1"))
    P.append(E(t1, [0.036, 0.036, 0.036], k=0.01, bone="RightThumb2"))
    P.append(RC(t1, t2, 0.033, 0.029, k=0.008, bone="RightThumb2"))
    P.append(RC(t2, tip, 0.029, 0.024, k=0.008, bone="RightThumb2"))
    return P


def right_leg():
    """Thigh 0.52 wide at the top / 0.46 mid, knee 0.31, calf 0.35 x 0.37, ankle 0.22, foot 0.85
    long x 0.31 at the ball with a narrow heel and a real arch."""
    UL, LL, FT = "RightUpperLeg", "RightLowerLeg", "RightFoot"
    P = []
    P.append(E([0.27, 2.86, 0.0], [0.21, 0.21, 0.22], k=0.1, bone=UL))  # hip / trochanter mass
    P.append(RC([0.25, 2.82, 0.0], [0.25, 1.68, -0.01], 0.23, 0.14, k=0.08, bone=UL))  # thigh
    P.append(E([0.255, 2.25, -0.11], [0.12, 0.42, 0.11], k=0.07, bone=UL))  # rectus femoris
    P.append(E([0.355, 2.15, -0.02], [0.1, 0.4, 0.15], k=0.07, bone=UL))  # vastus lateralis
    P.append(E([0.175, 1.82, -0.075], [0.1, 0.17, 0.1], k=0.06, bone=UL))  # vastus medialis
    P.append(E([0.25, 2.3, 0.11], [0.17, 0.44, 0.11], k=0.07, bone=UL))  # hamstrings
    P.append(E([0.15, 2.5, 0.0], [0.1, 0.3, 0.15], k=0.08, bone=UL))  # adductors
    P.append(E([0.25, 1.56, -0.03], [0.13, 0.13, 0.13], k=0.06, bone=LL))  # knee
    P.append(E([0.25, 1.575, -0.135], [0.06, 0.07, 0.035], k=0.035, bone=LL))  # patella
    P.append(RC([0.25, 1.48, -0.112], [0.25, 1.37, -0.095], 0.032, 0.028, k=0.035, bone=LL))  # patellar tendon
    P.append(RC([0.25, 1.48, -0.02], [0.25, 0.36, 0.035], 0.125, 0.085, k=0.06, bone=LL))  # shin
    P.append(E([0.28, 1.2, -0.075], [0.06, 0.26, 0.06], k=0.05, bone=LL))  # tibialis anterior
    P.append(E([0.205, 1.2, 0.08], [0.09, 0.27, 0.1], k=0.06, bone=LL))  # gastrocnemius medial
    P.append(E([0.29, 1.23, 0.075], [0.08, 0.24, 0.09], k=0.06, bone=LL))  # gastrocnemius lateral
    P.append(E([0.25, 0.92, 0.07], [0.11, 0.26, 0.08], k=0.06, bone=LL))  # soleus
    P.append(RC([0.25, 0.72, 0.095], [0.25, 0.32, 0.125], 0.05, 0.04, k=0.05, bone=LL))  # achilles
    P.append(E([0.25, 0.3, 0.04], [0.085, 0.08, 0.09], k=0.06, bone=FT))  # ankle
    P.append(E([0.32, 0.305, 0.045], [0.03, 0.03, 0.03], k=0.025, bone=FT))  # lateral malleolus
    P.append(E([0.185, 0.33, 0.045], [0.03, 0.03, 0.03], k=0.025, bone=FT))  # medial malleolus
    P.append(E([0.25, 0.11, 0.14], [0.095, 0.11, 0.1], k=0.06, bone=FT))  # heel
    P.append(RC([0.305, 0.07, 0.12], [0.33, 0.048, -0.38], 0.052, 0.044, k=0.06, bone=FT))  # lateral column
    P.append(RC([0.2, 0.1, 0.1], [0.198, 0.058, -0.38], 0.058, 0.05, k=0.06, bone=FT))  # medial column
    P.append(E([0.255, 0.145, -0.1], [0.105, 0.075, 0.24], k=0.07, bone=FT, R=rot(-13, 0, 0)))  # dorsum / instep
    P.append(E([0.255, 0.052, -0.37], [0.135, 0.052, 0.085], k=0.05, bone=FT))  # ball of the foot
    P.append(E([0.262, 0.038, -0.5], [0.118, 0.036, 0.088], k=0.05, bone=FT, R=rot(0, 9, 0)))  # toes
    P.append(E([0.2, 0.044, -0.528], [0.047, 0.041, 0.064], k=0.04, bone=FT))  # big toe
    P.append(E([0.19, -0.004, -0.13], [0.055, 0.046, 0.13], k=0.05, bone=FT, op="sub"))  # arch
    return P


def chain_transform(bone):
    """Rigid I-pose -> A-pose transform (M, t) for a bone's primitives."""
    for side, sgn in (("Right", 1), ("Left", -1)):
        if bone == side + "PecTail":
            M = rot(0, 0, ARM_ABDUCT * 0.5 * sgn)
            pv = SHOULDER[side]
            return M, pv - M @ pv
        if bone.startswith(side) and any(k in bone for k in ("Arm", "Hand", "Thumb", "Index", "Middle", "Ring", "Pinky")):
            M = rot(0, 0, ARM_ABDUCT * sgn)
            pv = SHOULDER[side]
            return M, pv - M @ pv
        if bone.startswith(side) and any(k in bone for k in ("Leg", "Foot")):
            M = rot(0, 0, LEG_ABDUCT * sgn)
            pv = HIP[side]
            return M, pv - M @ pv
    return np.eye(3), np.zeros(3)


def sole():
    # flatten the soles onto y = 0 (smooth intersection with the half-space y >= 0)
    return Prim("plane", "inter", 0.012, "RightFoot", n=np.array([0.0, -1.0, 0.0]), d=0.0, lo=np.array([-3, -0.2, -1.0]), hi=np.array([3, 0.06, 1.0]))


def build(apose=True):
    P = torso() + head()
    arm = right_arm()
    leg = right_leg()
    P += arm + [mirror_prim(p) if isinstance(p, Prim) else p for p in arm]
    P += leg + [mirror_prim(p) if isinstance(p, Prim) else p for p in leg]
    adds = [p for p in P if isinstance(p, Prim) and p.op == "union"]
    subs = [p for p in P if isinstance(p, Prim) and p.op != "union"]
    grooves = [g.resolve(adds) for g in P if isinstance(g, Groove)]
    P = adds + subs + grooves
    if apose:
        out = []
        for p in P:
            M, t = chain_transform(p.bone)
            q = p.transformed(M, t) if not np.allclose(M, np.eye(3)) else p
            if q.kind == "roundcone" and "b_bone" in q.p:
                Mb, tb = chain_transform(q.p["b_bone"])
                q.p["b"] = Mb @ np.asarray(p.p["b"], float) + tb
            out.append(q)
        P = out
    P.append(sole())
    return P


BOUNDS_APOSE = ([-2.5, -0.03, -0.68], [2.5, 5.63, 0.56])
