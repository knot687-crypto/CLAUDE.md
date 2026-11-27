"""Polygonizes the SpiderHero sculpt into a high-resolution A-pose mesh (out/highpoly.npz)."""
import sys, os, time
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
import body
from sdf import polygonize

out = os.path.join(os.path.dirname(__file__), "out")
os.makedirs(out, exist_ok=True)
h = float(sys.argv[1]) if len(sys.argv) > 1 else 0.005
t = time.time()
prims = body.build(apose=True)
print(f"{len(prims)} primitives")
V, F = polygonize(prims, *body.BOUNDS_APOSE, h=h, block=48)
np.savez_compressed(os.path.join(out, "highpoly.npz"), V=V, F=F)
print(f"done in {time.time() - t:.1f}s")
