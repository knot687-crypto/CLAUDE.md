"""Texture-space data bakes for each material set (2048^2):
  sculpt normal map (high-poly A-pose -> low-poly A-pose, tangent space)
  ambient occlusion (A-pose, so arms don't occlude the torso)
  position / normal / bone label in the R15 rest pose (Roblox coords) for the suit evaluator
Outputs out/maps/<Set>_*.png / .npy"""
import sys, os, json
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
import bpy
import blender_util as bu

here = os.path.dirname(__file__)
RES = int(sys.argv[1]) if len(sys.argv) > 1 else 2048
outdir = os.path.join(here, "out", "maps")
os.makedirs(outdir, exist_ok=True)
bpy.ops.wm.open_mainfile(filepath=os.path.join(here, "out", "character.blend"))
sc = bpy.context.scene
sc.render.engine = "CYCLES"
sc.cycles.device = "CPU"
sc.cycles.samples = 1

body = bpy.data.objects["Body"]
apose = bpy.data.objects["Body_APose"]
apose.hide_render = False
d = np.load(os.path.join(here, "out", "highpoly.npz"))
high = bu.mesh_from_arrays("High", bu.rb_to_bl(d["V"]), d["F"])

# bone label per face (dominant weight) as a face attribute on both meshes
bone_names = [b.name for b in bpy.data.objects["Armature"].data.bones]
bone_index = {n: i for i, n in enumerate(bone_names)}
json.dump(bone_names, open(os.path.join(outdir, "bones.json"), "w"))
for ob in (body, apose):
    me = ob.data
    gname = {g.index: g.name for g in ob.vertex_groups}
    vw = [{gname[g.group]: g.weight for g in v.groups} for v in me.vertices]
    attr = me.attributes.get("boneid") or me.attributes.new("boneid", "FLOAT", "FACE")
    vals = []
    for p in me.polygons:
        acc = {}
        for vi in p.vertices:
            for n, w in vw[vi].items():
                acc[n] = acc.get(n, 0) + w
        vals.append(float(bone_index.get(max(acc, key=acc.get), 0)))
    attr.data.foreach_set("value", vals)

SETS = [m.name for m in body.data.materials]


def new_image(name, float_buffer=True):
    img = bpy.data.images.new(name, RES, RES, alpha=True, float_buffer=float_buffer)
    img.generated_color = (0, 0, 0, 0)
    img.colorspace_settings.name = "Non-Color"
    return img


def emission_material(name, build):
    """Material whose emission outputs a data value; an image node is added for the bake target."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    em = nt.nodes.new("ShaderNodeEmission")
    nt.links.new(em.outputs["Emission"], out.inputs["Surface"])
    build(nt, em)
    tex = nt.nodes.new("ShaderNodeTexImage")
    nt.nodes.active = tex
    return m, tex


def pixels(img):
    a = np.empty(RES * RES * 4, np.float32)
    img.pixels.foreach_get(a)
    return a.reshape(RES, RES, 4)


def bake_emit(ob, set_index, build, tag):
    """Bakes an emission data pass for faces of one material set; returns RGBA float array."""
    mats = list(ob.data.materials)
    m, tex = emission_material(f"bake_{tag}", build)
    img = new_image(f"{SETS[set_index]}_{tag}")
    tex.image = img
    # only this set's faces get the bake material; others get a dummy without an active image
    dummy = bpy.data.materials.new("dummy")
    for i in range(len(mats)):
        ob.data.materials[i] = m if i == set_index else dummy
    bpy.ops.object.select_all(action="DESELECT")
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    sc.render.bake.margin = 0
    sc.render.bake.use_clear = True
    bpy.ops.object.bake(type="EMIT")
    for i, mm in enumerate(mats):
        ob.data.materials[i] = mm
    return pixels(img)


def geo_position(nt, em):
    g = nt.nodes.new("ShaderNodeNewGeometry")
    # encode position (Blender coords) into [0,1]: (p + 8) / 16
    add = nt.nodes.new("ShaderNodeVectorMath")
    add.operation = "MULTIPLY_ADD"
    add.inputs[1].default_value = (1 / 16, 1 / 16, 1 / 16)
    add.inputs[2].default_value = (0.5, 0.5, 0.5)
    nt.links.new(g.outputs["Position"], add.inputs[0])
    nt.links.new(add.outputs["Vector"], em.inputs["Color"])


def geo_normal(nt, em):
    g = nt.nodes.new("ShaderNodeNewGeometry")
    add = nt.nodes.new("ShaderNodeVectorMath")
    add.operation = "MULTIPLY_ADD"
    add.inputs[1].default_value = (0.5, 0.5, 0.5)
    add.inputs[2].default_value = (0.5, 0.5, 0.5)
    nt.links.new(g.outputs["Normal"], add.inputs[0])
    nt.links.new(add.outputs["Vector"], em.inputs["Color"])


def geo_bone(nt, em):
    a = nt.nodes.new("ShaderNodeAttribute")
    a.attribute_name = "boneid"
    a.attribute_type = "GEOMETRY"
    mul = nt.nodes.new("ShaderNodeMath")
    mul.operation = "DIVIDE"
    mul.inputs[1].default_value = 64.0
    nt.links.new(a.outputs["Fac"], mul.inputs[0])
    nt.links.new(mul.outputs["Value"], em.inputs["Color"])


C_inv = np.array([[1, 0, 0], [0, 0, 1], [0, -1, 0]], float)  # Blender -> Roblox

for si, set_name in enumerate(SETS):
    pos = bake_emit(body, si, geo_position, "pos")
    nrm = bake_emit(body, si, geo_normal, "nrm")
    bon = bake_emit(body, si, geo_bone, "bone")
    mask = pos[..., 3] > 0.5
    P = (pos[..., :3] - 0.5) * 16 @ C_inv.T
    N = (nrm[..., :3] * 2 - 1) @ C_inv.T
    B = np.rint(bon[..., 0] * 64).astype(np.int16)
    np.savez_compressed(os.path.join(outdir, f"{set_name}_data.npz"), P=P.astype(np.float32), N=N.astype(np.float32), B=B, mask=mask)
    print(set_name, "coverage", mask.mean().round(3))

# --- sculpt normals and AO on the A-pose copy (selected-to-active from the high-poly) ----------
sc.cycles.samples = 1
for si, set_name in enumerate(SETS):
    mats = list(apose.data.materials)
    m = bpy.data.materials.new("bake_nrm_" + set_name)
    m.use_nodes = True
    tex = m.node_tree.nodes.new("ShaderNodeTexImage")
    img = new_image(f"{set_name}_sculptnormal", float_buffer=False)
    tex.image = img
    m.node_tree.nodes.active = tex
    dummy = bpy.data.materials.new("dummy2")
    for i in range(len(mats)):
        apose.data.materials[i] = m if i == si else dummy
    bpy.ops.object.select_all(action="DESELECT")
    high.select_set(True)
    apose.select_set(True)
    bpy.context.view_layer.objects.active = apose
    sc.render.bake.use_selected_to_active = True
    sc.render.bake.cage_extrusion = 0.03
    sc.render.bake.max_ray_distance = 0.06
    sc.render.bake.margin = 8
    sc.render.bake.normal_space = "TANGENT"
    bpy.ops.object.bake(type="NORMAL")
    img.filepath_raw = os.path.join(outdir, f"{set_name}_sculptnormal.png")
    img.file_format = "PNG"
    img.save()
    # ambient occlusion (A-pose, low-poly only)
    sc.render.bake.use_selected_to_active = False
    sc.cycles.samples = 48
    ao = new_image(f"{set_name}_ao", float_buffer=False)
    tex.image = ao
    bpy.ops.object.select_all(action="DESELECT")
    apose.select_set(True)
    bpy.ops.object.bake(type="AO")
    ao.filepath_raw = os.path.join(outdir, f"{set_name}_ao.png")
    ao.file_format = "PNG"
    ao.save()
    sc.cycles.samples = 1
    for i, mm in enumerate(mats):
        apose.data.materials[i] = mm
    print(set_name, "sculpt normal + AO baked")

bpy.data.objects.remove(high)
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(here, "out", "character.blend"))
