"""Rigging: A-pose low-poly -> skinned R15 character in the R15 rest pose (out/character.blend).

1. deform armature in the A-pose (bones along limbs/fingers) + automatic bone-heat weights
2. weights limited to 4 influences (Roblox), normalized; per-region materials + UV unwrap
3. keep an A-pose copy (for baking the sculpt normals), re-pose arms/legs to the R15 rest pose
4. export armature: R15 bone names/hierarchy (Root > HumanoidRootNode > LowerTorso ...), joint
   frames identical to RigDefinition (world-aligned; fingers rotated by their rest spread)
"""
import sys, os, json, math
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
import bpy
import bmesh
from mathutils import Vector, Matrix
import blender_util as bu
import body

here = os.path.dirname(__file__)
rig = json.load(open(os.path.join(here, "rig.json")))
J = {j["name"]: j for j in rig["joints"]}
pivI = {n: np.array(j["pivot"], float) for n, j in J.items()}

C = np.array([[1, 0, 0], [0, 0, -1], [0, 1, 0]], float)  # Roblox -> Blender basis


def bl(p):
    return Vector(C @ np.asarray(p, float))


def apose(joint, p):
    """Moves an I-pose point by the A-pose transform of the joint's moving segment."""
    M, t = body.chain_transform(J[joint]["part1"])
    return M @ np.asarray(p, float) + t


def frame_rb(joint):
    f = J[joint]["frame"]  # CFrame components
    return np.array([[f[3], f[4], f[5]], [f[6], f[7], f[8]], [f[9], f[10], f[11]]], float)


SIDES = ("Right", "Left")
FINGERS = ("Thumb", "Index", "Middle", "Ring", "Pinky")

bu.reset()
d = np.load(os.path.join(here, "out", "lowpoly.npz"))
V, idx, offs = d["V"], d["idx"], d["offs"]
me = bpy.data.meshes.new("Body")
me.from_pydata(bu.rb_to_bl(V).tolist(), [], [idx[offs[i]:offs[i + 1]].tolist() for i in range(len(offs) - 1)])
me.update()
for p in me.polygons:
    p.use_smooth = True
body_ob = bpy.data.objects.new("Body", me)
bpy.context.scene.collection.objects.link(body_ob)

# ---------------------------------------------------------------------------------------------
# 1) deform armature (A-pose)
# ---------------------------------------------------------------------------------------------
arm_d = bpy.data.armatures.new("DeformRig")
arm_ob = bpy.data.objects.new("DeformRig", arm_d)
bpy.context.scene.collection.objects.link(arm_ob)
bpy.context.view_layer.objects.active = arm_ob
bpy.ops.object.mode_set(mode="EDIT")
eb = arm_d.edit_bones


def add_bone(name, head_rb, tail_rb, parent=None):
    b = eb.new(name)
    b.head = bl(head_rb)
    b.tail = bl(tail_rb)
    if parent:
        b.parent = eb[parent]
    return b


A = {n: apose(n, p) for n, p in pivI.items()}
add_bone("LowerTorso", A["Root"], A["Waist"])
add_bone("UpperTorso", A["Waist"], A["Neck"], "LowerTorso")
add_bone("Head", A["Neck"], np.array([0, 5.5, 0.02]), "UpperTorso")
for s in SIDES:
    add_bone(s + "UpperArm", A[s + "Shoulder"], A[s + "Elbow"], "UpperTorso")
    add_bone(s + "LowerArm", A[s + "Elbow"], A[s + "Wrist"], s + "UpperArm")
    add_bone(s + "Hand", A[s + "Wrist"], A[s + "Middle1"], s + "LowerArm")
    for f in FINGERS:
        p1, p2 = A[s + f + "1"], A[s + f + "2"]
        dvec = (p2 - p1) / np.linalg.norm(p2 - p1)
        ln2 = 0.115 if f == "Thumb" else {"Index": 0.146, "Middle": 0.159, "Ring": 0.147, "Pinky": 0.12}[f]
        add_bone(s + f + "1", p1, p2, s + "Hand")
        add_bone(s + f + "2", p2, p2 + dvec * ln2, s + f + "1")
    toe = apose(s + "Ankle", np.array([0.25 if s == "Right" else -0.25, 0.05, -0.47]))
    add_bone(s + "UpperLeg", A[s + "Hip"], A[s + "Knee"], "LowerTorso")
    add_bone(s + "LowerLeg", A[s + "Knee"], A[s + "Ankle"], s + "UpperLeg")
    add_bone(s + "Foot", A[s + "Ankle"], toe, s + "LowerLeg")
bpy.ops.object.mode_set(mode="OBJECT")

# automatic weights
bpy.ops.object.select_all(action="DESELECT")
body_ob.select_set(True)
arm_ob.select_set(True)
bpy.context.view_layer.objects.active = arm_ob
bpy.ops.object.parent_set(type="ARMATURE_AUTO")

# fallback for any vertex the heat solver missed: nearest bone segment
bone_segs = {b.name: (np.array(b.head_local), np.array(b.tail_local)) for b in arm_d.bones}
vg_by_name = {g.name: g for g in body_ob.vertex_groups}
missing = 0
co = np.array([v.co[:] for v in me.vertices])
for v in me.vertices:
    if sum(g.weight for g in v.groups) < 1e-4:
        missing += 1
        best, bd = None, 1e9
        p = np.array(v.co[:])
        for n, (h, t) in bone_segs.items():
            ab = t - h
            u = np.clip(np.dot(p - h, ab) / np.dot(ab, ab), 0, 1)
            dd = np.linalg.norm(p - (h + ab * u))
            if dd < bd:
                best, bd = n, dd
        vg_by_name[best].add([v.index], 1.0, "REPLACE")
print("vertices fixed by nearest-bone fallback:", missing)

bpy.context.view_layer.objects.active = body_ob
bpy.ops.object.mode_set(mode="WEIGHT_PAINT")
bpy.ops.object.vertex_group_clean(group_select_mode="ALL", limit=0.01)
bpy.ops.object.vertex_group_limit_total(group_select_mode="ALL", limit=4)
bpy.ops.object.vertex_group_normalize_all(group_select_mode="ALL", lock_active=False)
bpy.ops.object.mode_set(mode="OBJECT")

# ---------------------------------------------------------------------------------------------
# 2) regions -> materials, UV unwrap per region
# ---------------------------------------------------------------------------------------------
REGION = {"Head": 0, "UpperTorso": 1, "LowerTorso": 1}
for s in SIDES:
    for n in ("UpperArm", "LowerArm", "Hand"):
        REGION[s + n] = 2
    for f in FINGERS:
        REGION[s + f + "1"] = 2
        REGION[s + f + "2"] = 2
    for n in ("UpperLeg", "LowerLeg", "Foot"):
        REGION[s + n] = 3
MAT_NAMES = ["SuitHead", "SuitTorso", "SuitArms", "SuitLegs"]
for mn in MAT_NAMES:
    m = bpy.data.materials.new(mn)
    m.use_nodes = True
    me.materials.append(m)
gidx = {g.index: g.name for g in body_ob.vertex_groups}
vbest = np.zeros(len(me.vertices), int)
vweights = []
for v in me.vertices:
    ws = {gidx[g.group]: g.weight for g in v.groups}
    vweights.append(ws)
for poly in me.polygons:
    acc = {}
    for vi in poly.vertices:
        for n, w in vweights[vi].items():
            acc[n] = acc.get(n, 0) + w
    dom = max(acc, key=acc.get)
    poly.material_index = REGION[dom]

bpy.ops.object.mode_set(mode="EDIT")
me.uv_layers.new(name="UVMap")
for mi in range(len(MAT_NAMES)):
    bpy.ops.mesh.select_all(action="DESELECT")
    body_ob.active_material_index = mi
    bpy.ops.object.material_slot_select()
    bpy.ops.uv.smart_project(angle_limit=math.radians(62), island_margin=0.004, area_weight=0.0, correct_aspect=True, scale_to_bounds=False)
bpy.ops.mesh.select_all(action="SELECT")
bpy.ops.object.mode_set(mode="OBJECT")

# A-pose copy for baking the sculpt normal map (same topology and UVs)
apose_ob = body_ob.copy()
apose_ob.data = body_ob.data.copy()
apose_ob.name = "Body_APose"
for m in list(apose_ob.modifiers):
    apose_ob.modifiers.remove(m)
apose_ob.parent = None
bpy.context.scene.collection.objects.link(apose_ob)
apose_ob.hide_render = True

# ---------------------------------------------------------------------------------------------
# 3) re-pose to the R15 rest pose and bake it into the mesh
# ---------------------------------------------------------------------------------------------
bpy.context.view_layer.objects.active = arm_ob
bpy.ops.object.mode_set(mode="POSE")


def rot_rb_z(deg):
    a = math.radians(deg)
    return np.array([[math.cos(a), -math.sin(a), 0], [math.sin(a), math.cos(a), 0], [0, 0, 1]])


for s, sgn in (("Right", 1), ("Left", -1)):
    for bone, pv, ang in ((s + "UpperArm", body.SHOULDER[s], -body.ARM_ABDUCT * sgn), (s + "UpperLeg", body.HIP[s], -body.LEG_ABDUCT * sgn)):
        R = C @ rot_rb_z(ang) @ C.T
        Rm = Matrix(R.tolist()).to_4x4()
        h = bl(pv)
        pb = arm_ob.pose.bones[bone]
        pb.matrix = Matrix.Translation(h) @ Rm @ Matrix.Translation(-h) @ arm_ob.data.bones[bone].matrix_local
        bpy.context.view_layer.update()
bpy.ops.object.mode_set(mode="OBJECT")
bpy.context.view_layer.objects.active = body_ob
bpy.ops.object.modifier_apply(modifier="Armature")
bpy.context.view_layer.objects.active = arm_ob
bpy.ops.object.mode_set(mode="POSE")
bpy.ops.pose.select_all(action="SELECT")
bpy.ops.pose.armature_apply(selected=False)
bpy.ops.object.mode_set(mode="OBJECT")

# ---------------------------------------------------------------------------------------------
# 4) export armature: R15 names and hierarchy, joint frames identical to RigDefinition
# ---------------------------------------------------------------------------------------------
bpy.data.objects.remove(arm_ob)
xd = bpy.data.armatures.new("Armature")
xo = bpy.data.objects.new("Armature", xd)
bpy.context.scene.collection.objects.link(xo)
bpy.context.view_layer.objects.active = xo
bpy.ops.object.mode_set(mode="EDIT")
eb = xd.edit_bones
STUB = 0.12


def add_frame_bone(name, head_rb, frame_rb, parent=None, length=STUB):
    b = eb.new(name)
    yax = frame_rb @ np.array([0, 1.0, 0])
    zax = frame_rb @ np.array([0, 0, 1.0])
    b.head = bl(head_rb)
    b.tail = bl(np.asarray(head_rb) + yax * length)
    b.align_roll(bl(zax))
    if parent:
        b.parent = eb[parent]
    return b


I3 = np.eye(3)
add_frame_bone("Root", np.array([0, 0.0, 0]), I3, None, 0.3)
add_frame_bone("HumanoidRootNode", np.array(rig["rootCenter"]), I3, "Root")
add_frame_bone("LowerTorso", pivI["Root"], I3, "HumanoidRootNode")
add_frame_bone("UpperTorso", pivI["Waist"], I3, "LowerTorso")
add_frame_bone("Head", pivI["Neck"], I3, "UpperTorso")
for s in SIDES:
    add_frame_bone(s + "UpperArm", pivI[s + "Shoulder"], I3, "UpperTorso")
    add_frame_bone(s + "LowerArm", pivI[s + "Elbow"], I3, s + "UpperArm")
    add_frame_bone(s + "Hand", pivI[s + "Wrist"], I3, s + "LowerArm")
    for f in FINGERS:
        add_frame_bone(s + f + "1", pivI[s + f + "1"], frame_rb(s + f + "1"), s + "Hand", 0.05)
        add_frame_bone(s + f + "2", pivI[s + f + "2"], frame_rb(s + f + "2"), s + f + "1", 0.05)
    add_frame_bone(s + "UpperLeg", pivI[s + "Hip"], I3, "LowerTorso")
    add_frame_bone(s + "LowerLeg", pivI[s + "Knee"], I3, s + "UpperLeg")
    add_frame_bone(s + "Foot", pivI[s + "Ankle"], I3, s + "LowerLeg")
bpy.ops.object.mode_set(mode="OBJECT")

body_ob.parent = xo
mod = body_ob.modifiers.new("Armature", "ARMATURE")
mod.object = xo
apose_ob.parent = None

# HumanoidRootPart: invisible 2x2x1 collision box skinned to HumanoidRootNode
hrp_c = np.array(rig["rootCenter"])
bpy.ops.mesh.primitive_cube_add(size=1.0, location=bl(hrp_c))
hrp = bpy.context.active_object
hrp.name = "HumanoidRootPart"
hrp.scale = (2.0, 1.0, 2.0)  # Blender (x, y=depth, z=height) = Roblox (2, 2, 1)
bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
hrp.parent = xo
g = hrp.vertex_groups.new(name="HumanoidRootNode")
g.add(list(range(len(hrp.data.vertices))), 1.0, "REPLACE")
m2 = hrp.modifiers.new("Armature", "ARMATURE")
m2.object = xo

out = os.path.join(here, "out", "character.blend")
bpy.ops.wm.save_as_mainfile(filepath=out)
nv = len(me.vertices)
print(f"rigged: {nv} verts, {len(me.polygons)} polys, {len(xd.bones)} bones -> {out}")
