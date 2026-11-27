"""
Signed-distance sculpting engine for the SpiderHero character.

Primitives (ellipsoid, round cone, round box, plane) are combined in order with smooth union,
smooth subtraction and smooth intersection (polynomial smooth-min). The field is polygonized with
sparse, block-wise marching cubes: only blocks near the surface are evaluated, so the whole body
can be meshed at 0.005-stud resolution (fine enough to resolve separated fingers).

Coordinates are Roblox space: Y up, character faces -Z, studs.
"""
import numpy as np
from skimage.measure import marching_cubes


def _rot(rx=0.0, ry=0.0, rz=0.0):
    """Rotation matrix R = Rx * Ry * Rz (same convention as CFrame.Angles), degrees."""
    rx, ry, rz = np.radians([rx, ry, rz])
    cx, sx, cy, sy, cz, sz = np.cos(rx), np.sin(rx), np.cos(ry), np.sin(ry), np.cos(rz), np.sin(rz)
    Rx = np.array([[1, 0, 0], [0, cx, -sx], [0, sx, cx]])
    Ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    Rz = np.array([[cz, -sz, 0], [sz, cz, 0], [0, 0, 1]])
    return Rx @ Ry @ Rz


def rot(rx=0.0, ry=0.0, rz=0.0):
    return _rot(rx, ry, rz)


class Prim:
    """A primitive with an operation. `bone` tags which rig segment owns it (used for posing)."""

    def __init__(self, kind, op="union", k=0.05, bone="UpperTorso", **p):
        self.kind, self.op, self.k, self.bone, self.p = kind, op, float(k), bone, p

    # ---- transforms -------------------------------------------------------------------------
    def transformed(self, M, t):
        """Returns a copy moved by the rigid transform x -> M @ x + t."""
        q = dict(self.p)
        if self.kind == "ellipsoid" or self.kind == "roundbox":
            q["c"] = M @ np.asarray(q["c"], float) + t
            q["R"] = M @ np.asarray(q.get("R", np.eye(3)), float)
        elif self.kind == "roundcone":
            q["a"] = M @ np.asarray(q["a"], float) + t
            q["b"] = M @ np.asarray(q["b"], float) + t
        elif self.kind == "plane":
            n = M @ np.asarray(q["n"], float)
            q["n"] = n
            q["d"] = q["d"] + float(np.dot(n, t))
        return Prim(self.kind, self.op, self.k, self.bone, **q)

    # ---- bounds -----------------------------------------------------------------------------
    def aabb(self):
        p, k = self.p, self.k
        if self.kind == "ellipsoid":
            R = np.asarray(p.get("R", np.eye(3)), float)
            r = np.asarray(p["r"], float)
            ext = np.abs(R) @ r
            c = np.asarray(p["c"], float)
            return c - ext - k, c + ext + k
        if self.kind == "roundcone":
            a, b = np.asarray(p["a"], float), np.asarray(p["b"], float)
            r = max(p["r1"], p["r2"])
            return np.minimum(a, b) - r - k, np.maximum(a, b) + r + k
        if self.kind == "roundbox":
            R = np.asarray(p.get("R", np.eye(3)), float)
            h = np.asarray(p["h"], float) + p.get("rr", 0.0)
            ext = np.abs(R) @ h
            c = np.asarray(p["c"], float)
            return c - ext - k, c + ext + k
        if self.kind == "plane":
            lo = np.asarray(p.get("lo", [-1e9] * 3), float)
            hi = np.asarray(p.get("hi", [1e9] * 3), float)
            return lo, hi
        raise ValueError(self.kind)

    # ---- distance ---------------------------------------------------------------------------
    def dist(self, P):
        p = self.p
        if self.kind == "ellipsoid":
            R = np.asarray(p.get("R", np.eye(3)), np.float32)
            r = np.asarray(p["r"], np.float32)
            q = (P - np.asarray(p["c"], np.float32)) @ R
            k0 = np.linalg.norm(q / r, axis=1)
            k1 = np.linalg.norm(q / (r * r), axis=1)
            return np.where(k1 > 1e-9, k0 * (k0 - 1.0) / np.maximum(k1, 1e-9), -float(r.min()))
        if self.kind == "roundcone":
            a = np.asarray(p["a"], np.float32)
            b = np.asarray(p["b"], np.float32)
            r1, r2 = float(p["r1"]), float(p["r2"])
            ba = b - a
            l2 = float(ba @ ba)
            rr = r1 - r2
            a2 = l2 - rr * rr
            il2 = 1.0 / l2
            pa = P - a
            y = pa @ ba
            z = y - l2
            v = pa * l2 - np.outer(y, ba)
            x2 = np.einsum("ij,ij->i", v, v)
            y2 = y * y * l2
            z2 = z * z * l2
            kk = np.sign(rr) * rr * rr * x2
            d3 = (np.sqrt(np.maximum(x2 * a2 * il2, 0)) + y * rr) * il2 - r1
            d1 = np.sqrt(x2 + z2) * il2 - r2
            d2 = np.sqrt(x2 + y2) * il2 - r1
            out = np.where(np.sign(z) * a2 * z2 > kk, d1, np.where(np.sign(y) * a2 * y2 < kk, d2, d3))
            return out.astype(np.float32)
        if self.kind == "roundbox":
            R = np.asarray(p.get("R", np.eye(3)), np.float32)
            h = np.asarray(p["h"], np.float32)
            rr = float(p.get("rr", 0.0))
            q = np.abs((P - np.asarray(p["c"], np.float32)) @ R) - h
            outside = np.linalg.norm(np.maximum(q, 0), axis=1)
            inside = np.minimum(q.max(axis=1), 0)
            return outside + inside - rr
        if self.kind == "plane":
            n = np.asarray(p["n"], np.float32)
            return P @ n - float(p["d"])
        raise ValueError(self.kind)


def smin(a, b, k):
    if k <= 0:
        return np.minimum(a, b)
    h = np.maximum(k - np.abs(a - b), 0.0) / k
    return np.minimum(a, b) - h * h * k * 0.25


def smax(a, b, k):
    return -smin(-a, -b, k)


def apply(field, prim, P):
    d = prim.dist(P)
    if prim.op == "union":
        return smin(field, d, prim.k)
    if prim.op == "sub":
        return smax(field, -d, prim.k)
    if prim.op == "inter":
        return smax(field, d, prim.k)
    raise ValueError(prim.op)


def evaluate(prims, P, boxes=None):
    """Evaluates the full field at points P (N,3)."""
    field = np.full(len(P), 1.0, np.float32)
    lo = P.min(axis=0)
    hi = P.max(axis=0)
    for i, pr in enumerate(prims):
        a, b = boxes[i] if boxes is not None else pr.aabb()
        if np.any(a > hi) or np.any(b < lo):
            continue
        field = apply(field, pr, P)
    return field


CULL_MARGIN = 0.12


def polygonize(prims, lo, hi, h=0.005, block=48, verbose=True):
    """Sparse block marching cubes. Returns (verts, faces) with outward winding."""
    lo = np.asarray(lo, float)
    hi = np.asarray(hi, float)
    dims = np.ceil((hi - lo) / h).astype(int)
    nb = np.ceil(dims / block).astype(int)
    boxes = [pr.aabb() for pr in prims]
    # coarse pass: block centers
    bs = block * h
    centers = np.stack(np.meshgrid(*[lo[i] + (np.arange(nb[i]) + 0.5) * bs for i in range(3)], indexing="ij"), -1).reshape(-1, 3)
    dc = evaluate(prims, centers.astype(np.float32), boxes)
    half_diag = 0.5 * bs * np.sqrt(3)
    cand = np.where(np.abs(dc) < half_diag * 1.6 + 0.02)[0]
    if verbose:
        print(f"grid {dims.tolist()} blocks {nb.tolist()} candidates {len(cand)}")
    all_v, all_f = [], []
    nv = 0
    from collections import deque
    queue = deque(np.unravel_index(ci, nb) for ci in cand)
    queued = set(tuple(int(x) for x in q) for q in queue)
    processed = 0
    while queue:
        bi = queue.popleft()
        bi = tuple(int(x) for x in bi)
        processed += 1
        o = lo + np.array(bi) * bs
        n = block + 1
        ax = [o[i] + np.arange(n) * h for i in range(3)]
        G = np.stack(np.meshgrid(*ax, indexing="ij"), -1).reshape(-1, 3).astype(np.float32)
        # cull with a generous margin so neighbouring blocks always evaluate the same primitive set
        # near their shared faces (approximate ellipsoid distances can under-estimate)
        a0, b0 = G.min(axis=0) - CULL_MARGIN, G.max(axis=0) + CULL_MARGIN
        field = np.full(len(G), 1.0, np.float32)
        for i, pr in enumerate(prims):
            a, b = boxes[i]
            if np.any(a > b0) or np.any(b < a0):
                continue
            field = apply(field, pr, G)
        vol = field.reshape(n, n, n)
        if vol.min() > 0 or vol.max() < 0:
            continue
        # flood fill: any face with a sign change means the surface continues into that neighbor
        faces = {
            (-1, 0, 0): vol[0, :, :], (1, 0, 0): vol[-1, :, :],
            (0, -1, 0): vol[:, 0, :], (0, 1, 0): vol[:, -1, :],
            (0, 0, -1): vol[:, :, 0], (0, 0, 1): vol[:, :, -1],
        }
        for dlt, face in faces.items():
            if face.min() <= 0 <= face.max():
                nbk = (bi[0] + dlt[0], bi[1] + dlt[1], bi[2] + dlt[2])
                if all(0 <= nbk[i] < nb[i] for i in range(3)) and nbk not in queued:
                    queued.add(nbk)
                    queue.append(nbk)
        v, f, _, _ = marching_cubes(vol, level=0.0, spacing=(h, h, h), gradient_direction="ascent")
        all_v.append(v + o)
        all_f.append(f + nv)
        nv += len(v)
    if verbose:
        print(f"processed {processed} blocks")
    V = np.concatenate(all_v)
    F = np.concatenate(all_f)
    # weld duplicated boundary vertices between blocks (tolerance-based, robust to float rounding)
    from scipy.spatial import cKDTree
    pairs = cKDTree(V).query_pairs(r=h * 0.01, output_type="ndarray")
    parent = np.arange(len(V))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for a, b in pairs:
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[max(ra, rb)] = min(ra, rb)
    roots = np.array([find(i) for i in range(len(V))])
    uniq, inv = np.unique(roots, return_inverse=True)
    V = V[uniq]
    F = inv[F]
    # drop degenerate faces
    good = (F[:, 0] != F[:, 1]) & (F[:, 1] != F[:, 2]) & (F[:, 0] != F[:, 2])
    F = F[good]
    # ensure outward winding (positive signed volume)
    vol = np.einsum("ij,ij->i", V[F[:, 0]], np.cross(V[F[:, 1]], V[F[:, 2]])).sum() / 6
    if vol < 0:
        F = F[:, ::-1]
    if verbose:
        print(f"mesh {len(V)} verts {len(F)} faces volume {abs(vol):.3f}")
    return V.astype(np.float32), F.astype(np.int32)


def gradient(prims, P, eps=0.002):
    boxes = [pr.aabb() for pr in prims]
    g = np.zeros_like(P)
    for i in range(3):
        d = np.zeros(3, np.float32)
        d[i] = eps
        g[:, i] = evaluate(prims, P + d, boxes) - evaluate(prims, P - d, boxes)
    n = np.linalg.norm(g, axis=1, keepdims=True)
    return g / np.maximum(n, 1e-9)
