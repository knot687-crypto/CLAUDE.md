"""Clay QA renders of out/highpoly.npz (A-pose sculpt)."""
import sys, os
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
import bpy
import blender_util as bu

here = os.path.dirname(__file__)
outdir = os.path.join(here, "out", "renders")
os.makedirs(outdir, exist_ok=True)
which = sys.argv[1] if len(sys.argv) > 1 else "body"
src = os.path.join(here, "out", "highpoly.npz")

bu.reset()
d = np.load(src)
ob = bu.mesh_from_arrays("Body", bu.rb_to_bl(d["V"]), d["F"])
ob.data.materials.append(bu.clay_material())
bu.setup_render((640, 900) if which == "body" else (700, 700), 36)
bu.ground()
bu.three_point()

if which == "body":
    views = [
        ("front", (0, 3.0, -11.5), (0, 2.85, 0), 50),
        ("threeq", (-7.5, 3.6, -8.5), (0, 2.85, 0), 50),
        ("side", (-11.5, 3.0, 0), (0, 2.85, 0), 50),
        ("back", (2.5, 3.6, 11.0), (0, 2.85, 0), 50),
    ]
elif which == "head":
    views = [
        ("head_front", (0, 5.2, -2.6), (0, 5.05, 0), 60),
        ("head_34", (-1.9, 5.3, -1.9), (0, 5.05, 0), 60),
        ("torso_front", (0, 4.2, -4.2), (0, 3.9, 0), 50),
        ("torso_34", (-3.0, 4.4, -3.0), (0, 3.9, 0), 50),
    ]
else:
    views = [
        ("hand", (2.6, 2.95, -1.6), (2.05, 2.95, -0.02), 60),
        ("hand_back", (2.75, 3.3, 0.9), (2.05, 2.95, -0.02), 60),
        ("feet", (-1.3, 0.9, -2.4), (0.0, 0.2, -0.2), 50),
        ("legs_back", (1.2, 2.2, 4.8), (0, 1.6, 0), 50),
    ]
paths = bu.render_views(views, outdir, "clay")
print("\n".join(paths))
