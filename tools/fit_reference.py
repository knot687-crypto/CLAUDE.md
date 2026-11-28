#!/usr/bin/env python3
"""How the crosshair was cloned 1:1 from the reference screenshot.

The reference (assets/reference.png) shows four rhombus blades with a white
outline and a #FFC8D2 core, a white centre dot with a soft halo and a white
glow, on a #0C0C0C background, captured mid-spin.

1. A differentiable model of that look (blade rhombi + inner rhombi for the
   outline, a centre dot, a soft halo disc and two gaussian glow layers - one
   hugging the silhouette, one shaped like a fat diamond behind each blade) was
   fitted to every pixel with scipy least squares (`--fit`).
2. The fitted constants live in src/crosshair.cpp / src/crosshair.h.
3. This script renders the *production* C++ renderer at the reference pose and
   reports the per-pixel error (`python3 tools/fit_reference.py`).

Requires numpy, pillow (and scipy for --fit) plus a C++ compiler.
"""
import ctypes, os, subprocess, sys, tempfile
import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REF = os.path.join(ROOT, 'assets', 'reference.png')
X0, Y0, X1, Y1 = 88, 39, 170, 121          # crop around the crosshair
POSE = dict(cx=129.0753, cy=80.1311, angle=-0.3175)  # centre (px) and rotation (rad) in the screenshot
BG = 12

def load_ref():
    ref = np.array(Image.open(REF).convert('RGB')).astype(np.float64)
    return ref[Y0:Y1, X0:X1]

def production_render(H, W):
    lib_path = os.path.join(tempfile.gettempdir(), 'vortex_xh.so')
    subprocess.check_call(['g++', '-O2', '-std=c++17', '-shared', '-fPIC', '-o', lib_path,
                           os.path.join(ROOT, 'tools', 'xh_capi.cpp'), os.path.join(ROOT, 'src', 'crosshair.cpp')])
    lib = ctypes.CDLL(lib_path)
    lib.xh_render.argtypes = [ctypes.POINTER(ctypes.c_float), ctypes.c_int, ctypes.c_int, ctypes.c_float,
                              ctypes.c_float, ctypes.c_float, ctypes.c_int, ctypes.c_void_p]
    # defaults of CrosshairStyle (length, width, gap, outline, dot) + glow, glowSize, halo, scale
    p = (ctypes.c_float * 9)(24.01, 6.825, 6.122, 1.299, 1.349, 1.0, 1.0, 1.0, 1.0)
    out = np.zeros((H, W, 3), np.uint8)
    lib.xh_render(p, W, H, POSE['cx'] - X0, POSE['cy'] - Y0, POSE['angle'], BG, out.ctypes.data)
    return out.astype(np.float64)

# ---------------------------------------------------------------- model fit (documentation)
def sd_rhombus(qx, qy, a, b):
    qx = np.abs(qx); qy = np.abs(qy)
    h = np.clip(((a - 2 * qx) * a - (b - 2 * qy) * b) / (a * a + b * b), -1, 1)
    d = np.hypot(qx - 0.5 * a * (1 - h), qy - 0.5 * b * (1 + h))
    return d * np.sign(qx * b + qy * a - a * b)

def fit(R):
    from scipy.ndimage import gaussian_filter
    from scipy.optimize import least_squares
    H, W = R.shape[:2]
    ys, xs = np.mgrid[0:H, 0:W].astype(np.float64)
    px, py = xs + X0 + 0.5, ys + Y0 + 0.5

    def field(cx, cy, th, m, a, b):
        d = np.full((H, W), 1e9)
        for i in range(4):
            ang = th + i * np.pi / 2
            ux, uy = np.sin(ang), -np.cos(ang)
            qx = (px - cx) * ux + (py - cy) * uy - m
            qy = (px - cx) * -uy + (py - cy) * ux
            d = np.minimum(d, sd_rhombus(qx, qy, a, b))
        return d

    def render(p):
        cx, cy, th, r0, L, Wd, t, rd, gc, ga, gb, s, A, s2, A2, rh, ah, sh = p
        dO = field(cx, cy, th, r0 + L / 2, L / 2, Wd / 2)
        rr = np.hypot(px - cx, py - cy)
        covO = np.clip(0.5 - dO, 0, 1); covI = np.clip(0.5 - (dO + t), 0, 1); covD = np.clip(0.5 - (rr - rd), 0, 1)
        src = np.maximum(np.clip(0.5 - field(cx, cy, th, gc, ga, gb), 0, 1), covD)
        g1 = np.clip(A * gaussian_filter(src, s, mode='constant'), 0, 1)
        g2 = np.clip(A2 * gaussian_filter(np.maximum(covO, covD), s2, mode='constant'), 0, 1)
        halo = ah * np.clip(0.5 - (rr - rh) / sh, 0, 1)
        img = np.full((H, W, 3), float(BG))
        for a, col in [(1 - (1 - g1) * (1 - g2), (255, 255, 255)), (halo, (255, 255, 255)), (covO, (255, 255, 255)),
                       (covI, (255, 200, 210)), (covD, (255, 255, 255))]:
            img = img * (1 - a[..., None]) + np.array(col, float) * a[..., None]
        return img

    p0 = [129, 80, -0.3, 6.5, 23, 7, 1.4, 1.4, 18, 8, 6.7, 1.7, 0.4, 0.7, 0.7, 3, 0.3, 3.5]
    lb = [120, 70, -1, 2, 15, 3, .3, .5, 5, 4, 1, .3, 0, .3, 0, 1.5, 0, .1]
    ub = [138, 90, .5, 12, 32, 10, 3.5, 3.5, 30, 16, 12, 8, 3, 8, 3, 8, 1, 4]
    r = least_squares(lambda q: (render(q) - R).ravel(), p0, bounds=(lb, ub), x_scale='jac', diff_step=1e-3)
    names = 'cx cy theta gap length width outline dot glowCentre glowAlong glowAcross sigma1 amp1 sigma2 amp2 haloR haloAmp haloSoft'.split()
    for n, v in zip(names, r.x):
        print('%12s = %.4f' % (n, v))
    print('model RMSE %.3f / 255' % np.sqrt(((render(r.x) - R) ** 2).mean()))

def main():
    R = load_ref()
    if '--fit' in sys.argv:
        fit(R)
        return
    img = production_render(*R.shape[:2])
    err = img - R
    print('production renderer vs reference: RMSE %.2f / 255, mean abs %.2f' % (np.sqrt((err ** 2).mean()), np.abs(err).mean()))
    if '--save' in sys.argv:
        z = 6
        diff = np.clip(128 + err * 3, 0, 255)
        row = np.concatenate([R, np.full((R.shape[0], 2, 3), 60.0), img, np.full((R.shape[0], 2, 3), 60.0), diff], axis=1)
        out = Image.fromarray(row.astype(np.uint8)).resize((row.shape[1] * z, row.shape[0] * z), Image.NEAREST)
        path = os.path.join(ROOT, 'assets', 'clone-vs-reference.png')
        out.save(path)
        print('wrote', path)

if __name__ == '__main__':
    main()
