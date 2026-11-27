"""Export: split the skinned body into the 15 R15 MeshParts (+ HumanoidRootPart) and write
  out/export/SpiderHero_R15.fbx      Roblox 3D Importer (skinned R15 rig, embedded textures)
  out/export/SpiderHero_preview.glb  web preview (1024 JPEG textures)
  out/export/textures/*.png          1024^2 PBR maps for SurfaceAppearance (Color/Normal/Roughness/Metalness)
Custom split normals are locked from the unsplit mesh first, so the part splits never show a
shading seam."""
import sys, os, shutil
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
import bpy
import bmesh
from PIL import Image

here = os.path.dirname(__file__)
outdir = os.path.join(here, "out", "export")
texout = os.path.join(outdir, "textures")
os.makedirs(texout, exist_ok=True)
bpy.ops.wm.open_mainfile(filepath=os.path.join(here, "out", "character_final.blend"))
for n in ("Body_APose", "High", "HighRef"):
    if n in bpy.data.objects:
        bpy.data.objects.remove(bpy.data.objects[n])

arm = bpy.data.objects["Armature"]
body = bpy.data.objects["Body"]
me = body.data

# lock smooth normals as custom split normals (survive the split)
vn = np.zeros(len(me.vertices) * 3, np.float32)
me.vertex_normals.foreach_get("vector", vn)
me.normals_split_custom_set_from_vertices(vn.reshape(-1, 3).tolist())

R15 = ["LowerTorso", "UpperTorso", "Head"]
for s in ("Right", "Left"):
    R15 += [s + "UpperArm", s + "LowerArm", s + "Hand", s + "UpperLeg", s + "LowerLeg", s + "Foot"]


def part_of(bone):
    if bone in R15:
        return bone
    for s in ("Right", "Left"):
        if bone.startswith(s) and any(f in bone for f in ("Thumb", "Index", "Middle", "Ring", "Pinky")):
            return s + "Hand"
    return "LowerTorso"


gname = {g.index: g.name for g in body.vertex_groups}
vw = [{gname[g.group]: g.weight for g in v.groups} for v in me.vertices]
face_part = []
for p in me.polygons:
    acc = {}
    for vi in p.vertices:
        for n, w in vw[vi].items():
            pn = part_of(n)
            acc[pn] = acc.get(pn, 0) + w
    face_part.append(max(acc, key=acc.get))
face_part = np.array(face_part)

parts = []
for pn in R15:
    ob = body.copy()
    ob.data = body.data.copy()
    ob.name = pn
    ob.data.name = pn + "_Mesh"
    bpy.context.scene.collection.objects.link(ob)
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bm.faces.ensure_lookup_table()
    kill = [f for f in bm.faces if face_part[f.index] != pn]
    bmesh.ops.delete(bm, geom=kill, context="FACES")
    bm.to_mesh(ob.data)
    bm.free()
    # drop materials this part doesn't use
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.select_all(action="DESELECT")
    ob.select_set(True)
    bpy.ops.object.material_slot_remove_unused()
    tris = sum(len(p.vertices) - 2 for p in ob.data.polygons)
    parts.append((pn, len(ob.data.vertices), tris, [m.name for m in ob.data.materials]))
bpy.data.objects.remove(body)
for pn, nv, nt, mats in parts:
    print(f"{pn:14s} verts {nv:6d} tris {nt:6d} materials {mats}")
print("total tris", sum(p[2] for p in parts))

# Roblox textures (1024): copy/scale the four material sets
TEX = os.path.join(here, "out", "textures")
for setn in ("SuitHead", "SuitTorso", "SuitArms", "SuitLegs"):
    for kind in ("Color", "Normal", "Roughness", "Metal"):
        src = os.path.join(TEX, f"{setn}_{kind}.png")
        im = Image.open(src)
        if kind == "Metal":
            im = im.convert("L")
        im = im.resize((1024, 1024), Image.LANCZOS)
        name = f"{setn}_{'Metalness' if kind == 'Metal' else kind}.png"
        im.save(os.path.join(texout, name))

# FBX for the Roblox 3D Importer
bpy.ops.object.select_all(action="DESELECT")
arm.select_set(True)
for ob in bpy.data.objects:
    if ob.type == "MESH":
        ob.select_set(True)
bpy.context.view_layer.objects.active = arm
fbx = os.path.join(outdir, "SpiderHero_R15.fbx")
bpy.ops.export_scene.fbx(
    filepath=fbx, use_selection=True, object_types={"ARMATURE", "MESH"},
    global_scale=1.0, apply_unit_scale=True, apply_scale_options="FBX_SCALE_NONE",
    axis_forward="-Z", axis_up="Y", use_mesh_modifiers=False, mesh_smooth_type="OFF",
    use_tspace=True, add_leaf_bones=False, primary_bone_axis="Y", secondary_bone_axis="X",
    use_armature_deform_only=False, bake_anim=False, path_mode="COPY", embed_textures=True,
)
print("FBX", os.path.getsize(fbx) // 1024, "KB")

# preview GLB with lighter textures
for img in bpy.data.images:
    if img.source == "FILE" and img.filepath:
        p = bpy.path.abspath(img.filepath)
        if os.path.exists(p) and img.size[0] > 1024:
            img.scale(1024, 1024)
glb = os.path.join(outdir, "SpiderHero_preview.glb")
bpy.ops.export_scene.gltf(filepath=glb, export_format="GLB", use_selection=True, export_skins=True,
                          export_image_format="JPEG", export_jpeg_quality=88, export_apply=False,
                          export_animations=False, export_yup=True)
print("GLB", os.path.getsize(glb) // 1024, "KB")
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(outdir, "SpiderHero_R15.blend"))
