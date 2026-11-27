"""Renders the low-poly (out/lowpoly.npz) smooth-shaded with a wireframe overlay."""
import sys, os
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
import bpy
import blender_util as bu

here = os.path.dirname(__file__)
bu.reset()
d = np.load(os.path.join(here, "out", "lowpoly.npz"))
V, idx, offs = d["V"], d["idx"], d["offs"]
me = bpy.data.meshes.new("Low")
me.from_pydata(bu.rb_to_bl(V).tolist(), [], [idx[offs[i]:offs[i + 1]].tolist() for i in range(len(offs) - 1)])
me.update()
for p in me.polygons:
    p.use_smooth = True
ob = bpy.data.objects.new("Low", me)
bpy.context.scene.collection.objects.link(ob)
ob.data.materials.append(bu.clay_material())
wire = ob.copy()
wire.data = ob.data.copy()
bpy.context.scene.collection.objects.link(wire)
mw = wire.modifiers.new("w", "WIREFRAME")
mw.thickness = 0.0025
mw.use_even_offset = True
wire.data.materials.clear()
wire.data.materials.append(bu.clay_material("Wire", (0.02, 0.05, 0.12, 1), 0.6))
bu.setup_render((700, 700), 24)
bu.ground()
bu.three_point()
views = []
for a in sys.argv[1:]:
    n, e, t, l = a.split(":")
    views.append((n, tuple(map(float, e.split(","))), tuple(map(float, t.split(","))), float(l)))
print("\n".join(bu.render_views(views, os.path.join(here, "out", "renders"), "low")))
