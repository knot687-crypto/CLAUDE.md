"""Clay renders from arbitrary cameras: python render_views.py name:ex,ey,ez:tx,ty,tz:lens ..."""
import sys, os
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
import bpy
import blender_util as bu
here = os.path.dirname(__file__)
outdir = os.path.join(here, "out", "renders")
bu.reset()
d = np.load(os.path.join(here, "out", "highpoly.npz"))
ob = bu.mesh_from_arrays("Body", bu.rb_to_bl(d["V"]), d["F"])
ob.data.materials.append(bu.clay_material())
bu.setup_render((700, 700), 36)
bu.ground()
bu.three_point()
views = []
for a in sys.argv[1:]:
    n, e, t, l = a.split(":")
    views.append((n, tuple(map(float, e.split(","))), tuple(map(float, t.split(","))), float(l)))
print("\n".join(bu.render_views(views, outdir, "v")))
