"""Final materials: bakes the combined tangent-space normal map (sculpt normals + height detail)
and builds the PBR materials used for export and beauty renders (out/character_final.blend)."""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
import bpy

here = os.path.dirname(__file__)
tex = os.path.join(here, "out", "textures")
maps = os.path.join(here, "out", "maps")
RES = int(sys.argv[1]) if len(sys.argv) > 1 else 2048
HEIGHT_RANGE = 0.03
bpy.ops.wm.open_mainfile(filepath=os.path.join(here, "out", "character.blend"))
sc = bpy.context.scene
sc.render.engine = "CYCLES"
sc.cycles.device = "CPU"
sc.cycles.samples = 1
body = bpy.data.objects["Body"]


def img(path, noncolor):
    im = bpy.data.images.load(path, check_existing=True)
    im.colorspace_settings.name = "Non-Color" if noncolor else "sRGB"
    return im


def build(mat, set_name, final_normal=None):
    nt = mat.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    col = nt.nodes.new("ShaderNodeTexImage")
    col.image = img(os.path.join(tex, f"{set_name}_Color.png"), False)
    nt.links.new(col.outputs["Color"], bsdf.inputs["Base Color"])
    rough = nt.nodes.new("ShaderNodeTexImage")
    rough.image = img(os.path.join(tex, f"{set_name}_Roughness.png"), True)
    nt.links.new(rough.outputs["Color"], bsdf.inputs["Roughness"])
    bsdf.inputs["Specular IOR Level"].default_value = 0.35
    nm = nt.nodes.new("ShaderNodeNormalMap")
    nm.space = "TANGENT"
    nimg = nt.nodes.new("ShaderNodeTexImage")
    if final_normal:
        nimg.image = img(final_normal, True)
        nt.links.new(nimg.outputs["Color"], nm.inputs["Color"])
        nt.links.new(nm.outputs["Normal"], bsdf.inputs["Normal"])
        return None
    nimg.image = img(os.path.join(maps, f"{set_name}_sculptnormal.png"), True)
    nt.links.new(nimg.outputs["Color"], nm.inputs["Color"])
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 1.0
    bump.inputs["Distance"].default_value = HEIGHT_RANGE
    himg = nt.nodes.new("ShaderNodeTexImage")
    himg.image = img(os.path.join(tex, f"{set_name}_Height.png"), True)
    himg.interpolation = "Cubic"
    nt.links.new(himg.outputs["Color"], bump.inputs["Height"])
    nt.links.new(nm.outputs["Normal"], bump.inputs["Normal"])
    nt.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    target = nt.nodes.new("ShaderNodeTexImage")
    nimg_out = bpy.data.images.new(f"{set_name}_Normal", RES, RES, alpha=False)
    nimg_out.colorspace_settings.name = "Non-Color"
    target.image = nimg_out
    nt.nodes.active = target
    return nimg_out


mats = list(body.data.materials)
for si, mat in enumerate(mats):
    out_img = build(mat, mat.name)
    # bake only this set (others get a dummy material without an active image target)
    dummy = bpy.data.materials.new("dummy")
    for i in range(len(mats)):
        body.data.materials[i] = mat if i == si else dummy
    bpy.ops.object.select_all(action="DESELECT")
    body.select_set(True)
    bpy.context.view_layer.objects.active = body
    sc.render.bake.use_selected_to_active = False
    sc.render.bake.margin = 12
    sc.render.bake.normal_space = "TANGENT"
    bpy.ops.object.bake(type="NORMAL")
    p = os.path.join(tex, f"{mat.name}_Normal.png")
    out_img.filepath_raw = p
    out_img.file_format = "PNG"
    out_img.save()
    for i, mm in enumerate(mats):
        body.data.materials[i] = mm
    build(mat, mat.name, final_normal=p)
    print(mat.name, "final normal baked")

for n in ("High", "HighRef"):
    if n in bpy.data.objects:
        bpy.data.objects.remove(bpy.data.objects[n])
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(here, "out", "character_final.blend"))
