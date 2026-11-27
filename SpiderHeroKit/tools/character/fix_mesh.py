"""Smooths isolated spike/pit vertices left by retopology (armpits, crotch, one at the left neck
base) on the skinned body in out/character.blend. Finger and foot vertices are skipped: their
sharp creases are real detail. Vertex order, UVs and weights are untouched."""
import os
import bpy
import bmesh

here = os.path.dirname(__file__)
path = os.path.join(here, "out", "character.blend")
bpy.ops.wm.open_mainfile(filepath=path)
body = bpy.data.objects["Body"]
gname = {g.index: g.name for g in body.vertex_groups}
SKIP = ("Thumb", "Index", "Middle", "Ring", "Pinky", "Hand", "Foot")


def defects(bm):
    out = []
    for v in bm.verts:
        nb = [e.other_vert(v).co for e in v.link_edges]
        if len(nb) < 3:
            continue
        mean = sum(nb, v.co * 0) / len(nb)
        el = sum((v.co - c).length for c in nb) / len(nb)
        if abs((v.co - mean).dot(v.normal)) / max(el, 1e-6) > 0.3:
            dv = body.data.vertices[v.index]
            top = gname.get(max(dv.groups, key=lambda g: g.weight).group) if dv.groups else ""
            if not any(k in (top or "") for k in SKIP):
                out.append(v)
    return out


bm = bmesh.new()
bm.from_mesh(body.data)
bm.verts.ensure_lookup_table()
total = 0
for it in range(3):
    bad = defects(bm)
    if not bad:
        break
    region = set(bad)
    for v in bad:
        region.update(e.other_vert(v) for e in v.link_edges)
    bmesh.ops.smooth_vert(bm, verts=list(region), factor=0.6, use_axis_x=True, use_axis_y=True, use_axis_z=True)
    bm.normal_update()
    total += len(bad)
    print(f"pass {it}: smoothed {len(bad)} defects ({len(region)} verts)")
print("remaining", len(defects(bm)))
# the left neck base kept a shallow pit next to a former spike: relax that patch as a whole
from mathutils import Vector
for spot_rb in [(-0.335, 4.735, -0.03)]:
    c = Vector((spot_rb[0], -spot_rb[2], spot_rb[1]))  # Roblox -> Blender
    patch = [v for v in bm.verts if (v.co - c).length < 0.055]
    for _ in range(6):
        bmesh.ops.smooth_vert(bm, verts=patch, factor=0.5, use_axis_x=True, use_axis_y=True, use_axis_z=True)
    bm.normal_update()
    print("relaxed neck patch", len(patch), "verts")
# folded sliver faces (tiny, facing against their neighbours) shade as dark pinpricks: collapse them
def folded(bm):
    out = []
    for f in bm.faces:
        if f.calc_area() > 4e-5:
            continue
        nb = [g for e in f.edges for g in e.link_faces if g is not f]
        if not nb:
            continue
        avg = sum((g.normal for g in nb), f.normal * 0)
        if avg.length > 1e-9 and f.normal.dot(avg.normalized()) < 0.2:
            out.append(f)
    return out


# unfold them by relaxing their vertices and the surrounding ring (topology stays intact)
for it in range(8):
    bad = folded(bm)
    if not bad:
        break
    region = {v for f in bad for v in f.verts}
    region |= {e.other_vert(v) for v in list(region) for e in v.link_edges}
    bmesh.ops.smooth_vert(bm, verts=list(region), factor=0.8, use_axis_x=True, use_axis_y=True, use_axis_z=True)
    bm.normal_update()
    print(f"unfold pass {it}: {len(bad)} folded faces")
# what is left is pinched into near-zero area: dissolve those slivers outright (manifold-safe)
for it in range(3):
    bad = folded(bm)
    if not bad:
        break
    edges = list({e for f in bad for e in f.edges})
    bmesh.ops.dissolve_degenerate(bm, dist=0.006, edges=edges)
    bm.normal_update()
nm = [e for e in bm.edges if not e.is_manifold]
print("non-manifold after dissolve:", [(len(e.link_faces), e.is_wire) for e in nm])
loose_e = [e for e in bm.edges if not e.link_faces]
if loose_e:
    bmesh.ops.delete(bm, geom=loose_e, context="EDGES")
loose_v = [v for v in bm.verts if not v.link_edges]
if loose_v:
    bmesh.ops.delete(bm, geom=loose_v, context="VERTS")
print("folded remaining", len(folded(bm)), "verts", len(bm.verts),
      "boundary", sum(e.is_boundary for e in bm.edges), "non-manifold", sum(not e.is_manifold for e in bm.edges))
bm.to_mesh(body.data)
bm.free()
body.data.update()
bpy.ops.wm.save_as_mainfile(filepath=path)
