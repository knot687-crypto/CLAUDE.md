"""Beauty renders of the textured, skinned hero (out/character_final.blend) in a studio setup.
Usage: python beauty.py <pose-json or {}> <prefix> view... [--res WxH] [--samples N]"""
import sys, os, json, math
sys.path.insert(0, os.path.dirname(__file__))
import bpy
from mathutils import Vector
import blender_util as bu
from render_pose import apply_pose

here = os.path.dirname(__file__)
args = sys.argv[1:]
res = (900, 1200)
samples = 96
if "--res" in args:
    i = args.index("--res")
    res = tuple(int(v) for v in args[i + 1].split("x"))
    del args[i:i + 2]
if "--samples" in args:
    i = args.index("--samples")
    samples = int(args[i + 1])
    del args[i:i + 2]
pose_arg, prefix, views_arg = args[0], args[1], args[2:]
pose = json.loads(open(pose_arg).read()) if os.path.exists(pose_arg) else json.loads(pose_arg)

bpy.ops.wm.open_mainfile(filepath=os.path.join(here, "out", "character_final.blend"))
for n in ("HumanoidRootPart", "Body_APose", "High", "HighRef"):
    if n in bpy.data.objects:
        bpy.data.objects[n].hide_render = True
apply_pose(bpy.data.objects["Armature"], pose)

sc = bpy.context.scene
sc.render.engine = "CYCLES"
sc.cycles.device = "CPU"
sc.cycles.samples = samples
sc.cycles.use_denoising = True
sc.render.resolution_x, sc.render.resolution_y = res
sc.view_settings.view_transform = "AgX"
for look in ("AgX - Punchy", "Punchy", "AgX - Medium High Contrast"):
    try:
        sc.view_settings.look = look
        break
    except Exception:
        pass
world = bpy.data.worlds.new("Studio")
sc.world = world
world.use_nodes = True
bg = world.node_tree.nodes["Background"]
bg.inputs["Color"].default_value = (0.012, 0.014, 0.02, 1)
bg.inputs["Strength"].default_value = 1.0

# backdrop: a curved cyclorama with a soft gradient floor
bpy.ops.mesh.primitive_plane_add(size=40, location=(0, 0, 0))
floor = bpy.context.active_object
fm = bpy.data.materials.new("Floor")
fm.use_nodes = True
fb = fm.node_tree.nodes["Principled BSDF"]
fb.inputs["Base Color"].default_value = (0.03, 0.033, 0.042, 1)
fb.inputs["Roughness"].default_value = 0.42
floor.data.materials.append(fm)

c = Vector((0, 0, 2.9))
bu.add_light("AREA", (-4.0, 5.5, 6.0), 2200, 3.0, (1.0, 0.93, 0.85), c)  # warm key, front-left
bu.add_light("AREA", (5.5, 2.5, 2.5), 500, 4.0, (0.55, 0.68, 1.0), c)  # cool fill
bu.add_light("AREA", (3.0, -6.0, 5.5), 2600, 2.0, (0.75, 0.85, 1.0), c)  # rim right
bu.add_light("AREA", (-3.5, -5.5, 4.5), 2000, 2.0, (1.0, 0.55, 0.45), c)  # rim left (warm red kick)
bu.add_light("AREA", (0, 3.0, 9.0), 600, 6.0, (1, 1, 1), c)  # top

views = []
for a in views_arg:
    n, e, t, l = a.split(":")
    views.append((n, tuple(map(float, e.split(","))), tuple(map(float, t.split(","))), float(l)))
outdir = os.path.join(here, "out", "renders")
print("\n".join(bu.render_views(views, outdir, prefix)))
