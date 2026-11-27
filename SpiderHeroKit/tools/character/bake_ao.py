"""Ambient occlusion bake on the A-pose low-poly alone (nothing else renderable)."""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
import bpy
here = os.path.dirname(__file__)
RES = int(sys.argv[1]) if len(sys.argv) > 1 else 2048
outdir = os.path.join(here, "out", "maps")
bpy.ops.wm.open_mainfile(filepath=os.path.join(here, "out", "character.blend"))
sc = bpy.context.scene
sc.render.engine = "CYCLES"
sc.cycles.device = "CPU"
sc.cycles.samples = 64
apose = bpy.data.objects["Body_APose"]
for ob in bpy.data.objects:
    if ob != apose:
        ob.hide_render = True
        ob.hide_set(True)
apose.hide_render = False
for ob in [o for o in bpy.data.objects if o.name == "High"]:
    bpy.data.objects.remove(ob)
mats = list(apose.data.materials)
SETS = [m.name for m in mats]
sc.world = sc.world or bpy.data.worlds.new("W")
sc.world.light_settings.distance = 0.6
for si, set_name in enumerate(SETS):
    m = bpy.data.materials.new("bake_ao_" + set_name)
    m.use_nodes = True
    tex = m.node_tree.nodes.new("ShaderNodeTexImage")
    img = bpy.data.images.new(f"{set_name}_ao2", RES, RES, alpha=False)
    img.colorspace_settings.name = "Non-Color"
    tex.image = img
    m.node_tree.nodes.active = tex
    dummy = bpy.data.materials.new("dummy")
    for i in range(len(mats)):
        apose.data.materials[i] = m if i == si else dummy
    bpy.ops.object.select_all(action="DESELECT")
    apose.select_set(True)
    bpy.context.view_layer.objects.active = apose
    sc.render.bake.use_selected_to_active = False
    sc.render.bake.margin = 8
    bpy.ops.object.bake(type="AO")
    img.filepath_raw = os.path.join(outdir, f"{set_name}_ao.png")
    img.file_format = "PNG"
    img.save()
    for i, mm in enumerate(mats):
        apose.data.materials[i] = mm
    print(set_name, "AO done")
