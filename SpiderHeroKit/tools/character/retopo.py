"""Retopology: high-poly sculpt (A-pose) -> clean quad game mesh (out/lowpoly.npz).
voxel remesh (watertight) -> decimate -> QuadriFlow quads (X-symmetric)."""
import sys, os, time
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
import bpy
import bmesh
import blender_util as bu

here = os.path.dirname(__file__)
target = int(sys.argv[1]) if len(sys.argv) > 1 else 17000
bu.reset()
d = np.load(os.path.join(here, "out", "highpoly.npz"))
ob = bu.mesh_from_arrays("Low", bu.rb_to_bl(d["V"]), d["F"])
bpy.context.view_layer.objects.active = ob
ob.select_set(True)

t = time.time()
ob.data.remesh_voxel_size = 0.007
ob.data.use_remesh_fix_poles = True
bpy.ops.object.voxel_remesh()
print("voxel remesh", len(ob.data.polygons), f"{time.time() - t:.1f}s")

t = time.time()
dec = ob.modifiers.new("dec", "DECIMATE")
dec.ratio = min(1.0, 260000 / max(1, len(ob.data.polygons)))
bpy.ops.object.modifier_apply(modifier="dec")
print("decimated", len(ob.data.polygons), f"{time.time() - t:.1f}s")

t = time.time()
res = bpy.ops.object.quadriflow_remesh(target_faces=target, use_mesh_symmetry=True, use_preserve_sharp=False,
                                       use_preserve_boundary=False, smooth_normals=True, seed=7, mode="FACES")
print("quadriflow", res, len(ob.data.polygons), f"{time.time() - t:.1f}s")

# --- dense quads resolve separate fingers; decimate only the body back down (hands protected) ---
from mathutils import Vector
t = time.time()
hand_idx = []
for v in ob.data.vertices:
    for sgn in (1, -1):
        wrist = Vector((1.8645 * sgn, -0.02, 3.1955))
        axis = Vector((0.7071 * sgn, 0.0, -0.7071))
        rel = v.co - wrist
        along = rel.dot(axis)
        if along > -0.05 and (rel - axis * along).length < 0.32:
            hand_idx.append(v.index)
            break
vg = ob.vertex_groups.new(name="Hands")
vg.add(hand_idx, 1.0, "REPLACE")
body_tris_target = int(sys.argv[2]) if len(sys.argv) > 2 else 40000
n_hand = len(hand_idx)
n_total = len(ob.data.polygons)
hand_faces = int(n_total * n_hand / max(1, len(ob.data.vertices)))
dec = ob.modifiers.new("dec2", "DECIMATE")
dec.decimate_type = "COLLAPSE"
dec.vertex_group = "Hands"
dec.invert_vertex_group = True
dec.vertex_group_factor = 1000.0
dec.use_symmetry = True
dec.symmetry_axis = "X"
# ratio applies to the whole mesh; protected hands keep their faces
body_faces_quads = n_total - hand_faces
want_tris = body_tris_target + hand_faces * 2
dec.ratio = min(1.0, want_tris / (n_total * 2))
bpy.ops.object.modifier_apply(modifier="dec2")
cnt_hand = 0
print("hands protected", n_hand, "verts; after decimate polys", len(ob.data.polygons), f"{time.time() - t:.1f}s")

me = ob.data
V = np.zeros(len(me.vertices) * 3)
me.vertices.foreach_get("co", V)
V = bu.bl_to_rb(V.reshape(-1, 3))
polys = [list(p.vertices) for p in me.polygons]
sizes = np.array([len(p) for p in polys])
print("poly sizes", np.unique(sizes, return_counts=True))
# store quads/tris as a flat list with offsets
flat = np.array([i for p in polys for i in p], np.int32)
offs = np.concatenate([[0], np.cumsum(sizes)]).astype(np.int32)
np.savez_compressed(os.path.join(here, "out", "lowpoly.npz"), V=V.astype(np.float32), idx=flat, offs=offs)
tris = int(sum(s - 2 for s in sizes))
print(f"lowpoly: {len(V)} verts, {len(polys)} polys, {tris} triangles")
