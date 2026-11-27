"""Blender helpers shared by the character pipeline (bpy)."""
import bpy
import numpy as np
import math


def rb_to_bl(V):
    """Roblox (x, y, z) -> Blender (x, -z, y). FBX/glTF export maps it back exactly."""
    V = np.asarray(V, np.float64)
    return np.stack([V[:, 0], -V[:, 2], V[:, 1]], 1)


def bl_to_rb(V):
    V = np.asarray(V, np.float64)
    return np.stack([V[:, 0], V[:, 2], -V[:, 1]], 1)


def rb_vec(x, y, z):
    return (x, -z, y)


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def mesh_from_arrays(name, V_bl, F, smooth=True):
    me = bpy.data.meshes.new(name)
    me.vertices.add(len(V_bl))
    me.vertices.foreach_set("co", np.asarray(V_bl, np.float32).ravel())
    me.loops.add(len(F) * 3)
    me.loops.foreach_set("vertex_index", np.asarray(F, np.int32).ravel())
    me.polygons.add(len(F))
    me.polygons.foreach_set("loop_start", np.arange(0, len(F) * 3, 3, dtype=np.int32))
    me.polygons.foreach_set("use_smooth", np.full(len(F), smooth))
    me.update(calc_edges=True)
    me.validate()
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def clay_material(name="Clay", color=(0.62, 0.6, 0.58, 1), rough=0.48):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = color
    b.inputs["Roughness"].default_value = rough
    return m


def setup_render(res=(720, 960), samples=40):
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.device = "CPU"
    sc.cycles.samples = samples
    sc.cycles.use_denoising = True
    sc.cycles.max_bounces = 6
    sc.render.resolution_x, sc.render.resolution_y = res
    sc.render.film_transparent = False
    sc.view_settings.view_transform = "AgX"
    sc.view_settings.look = "AgX - Punchy" if "AgX - Punchy" in [l for l in dir()] else "None"
    w = bpy.data.worlds.new("World")
    sc.world = w
    w.use_nodes = True
    bg = w.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = (0.055, 0.06, 0.075, 1)
    bg.inputs["Strength"].default_value = 1.0


def add_light(kind, loc, energy, size=2.0, color=(1, 1, 1), target=(0, 0, 1.4)):
    ld = bpy.data.lights.new("L", kind)
    ld.energy = energy
    ld.color = color
    if kind == "AREA":
        ld.size = size
    ob = bpy.data.objects.new("L", ld)
    ob.location = loc
    bpy.context.scene.collection.objects.link(ob)
    look_at(ob, target)
    return ob


def look_at(ob, target):
    from mathutils import Vector
    d = Vector(target) - ob.location
    ob.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()


def three_point(center_bl=(0, 0, 2.8)):
    cx, cy, cz = center_bl
    add_light("AREA", (cx - 4.5, cy + 6.0, cz + 4.5), 1400, 4.0, (1.0, 0.95, 0.88), center_bl)  # key (front-left)
    add_light("AREA", (cx + 6.0, cy + 3.0, cz + 1.0), 420, 5.0, (0.75, 0.83, 1.0), center_bl)  # fill
    add_light("AREA", (cx + 1.5, cy - 6.0, cz + 5.0), 1600, 3.0, (1.0, 1.0, 1.0), center_bl)  # rim (behind)
    add_light("AREA", (cx - 4.0, cy - 5.0, cz + 2.0), 700, 3.0, (0.8, 0.88, 1.0), center_bl)  # second rim


def camera(name, loc, target, lens=50):
    cd = bpy.data.cameras.new(name)
    cd.lens = lens
    ob = bpy.data.objects.new(name, cd)
    ob.location = loc
    bpy.context.scene.collection.objects.link(ob)
    look_at(ob, target)
    return ob


def render_views(views, outdir, prefix):
    """views: list of (name, loc_rb, target_rb, lens). Coordinates given in Roblox space."""
    import os
    paths = []
    sc = bpy.context.scene
    for name, loc, tgt, lens in views:
        cam = camera(name, rb_vec(*loc), rb_vec(*tgt), lens)
        sc.camera = cam
        p = os.path.join(outdir, f"{prefix}_{name}.png")
        sc.render.filepath = p
        bpy.ops.render.render(write_still=True)
        paths.append(p)
    return paths


def ground(z=0.0, color=(0.09, 0.095, 0.11, 1)):
    bpy.ops.mesh.primitive_plane_add(size=60, location=(0, 0, z))
    g = bpy.context.active_object
    m = clay_material("Ground", color, 0.85)
    g.data.materials.append(m)
    return g
