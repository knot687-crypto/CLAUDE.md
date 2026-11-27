"""Poses the skinned character with Motor6D.Transform-style joint rotations and renders clay.
Usage: python render_pose.py <pose-json> <out-prefix> view...
pose-json: {"JointName": [rx, ry, rz, px?, py?, pz?] (deg / studs)}  (Root = LowerTorso bone)."""
import sys, os, json, math
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
import bpy
from mathutils import Quaternion, Euler, Vector, Matrix
import blender_util as bu

here = os.path.dirname(__file__)
JOINT_TO_BONE = {"Root": "LowerTorso", "Waist": "UpperTorso", "Neck": "Head"}
for s in ("Right", "Left"):
    JOINT_TO_BONE.update({s + "Shoulder": s + "UpperArm", s + "Elbow": s + "LowerArm", s + "Wrist": s + "Hand",
                          s + "Hip": s + "UpperLeg", s + "Knee": s + "LowerLeg", s + "Ankle": s + "Foot"})

C = np.array([[1, 0, 0], [0, 0, -1], [0, 1, 0]], float)


def apply_pose(arm, pose):
    for joint, vals in pose.items():
        bone = JOINT_TO_BONE.get(joint, joint)
        pb = arm.pose.bones.get(bone)
        if pb is None:
            continue
        rx, ry, rz = [math.radians(v) for v in vals[:3]]
        # Roblox CFrame.Angles(rx, ry, rz) = Rx Ry Rz, expressed in the joint frame == bone local frame
        Rx = Matrix.Rotation(rx, 3, "X")
        Ry = Matrix.Rotation(ry, 3, "Y")
        Rz = Matrix.Rotation(rz, 3, "Z")
        # bone local axes: X = Roblox X, Y = Roblox Y (bone axis), Z = Roblox Z (see rig.py)
        R = Rx @ Ry @ Rz
        pb.rotation_mode = "QUATERNION"
        pb.rotation_quaternion = R.to_quaternion()
        if len(vals) > 3:
            pb.location = Vector((vals[3], vals[4], vals[5]))


if __name__ == "__main__":
    pose = json.loads(open(sys.argv[1]).read()) if os.path.exists(sys.argv[1]) else json.loads(sys.argv[1])
    prefix = sys.argv[2]
    bpy.ops.wm.open_mainfile(filepath=os.path.join(here, "out", "character.blend"))
    arm = bpy.data.objects["Armature"]
    apply_pose(arm, pose)
    bpy.data.objects["HumanoidRootPart"].hide_render = True
    bpy.data.objects["Body_APose"].hide_render = True
    body = bpy.data.objects["Body"]
    clay = bu.clay_material()
    for i in range(len(body.data.materials)):
        body.data.materials[i] = clay
    bu.setup_render((700, 800), 32)
    bu.ground()
    bu.three_point()
    views = []
    for a in sys.argv[3:]:
        n, e, t, l = a.split(":")
        views.append((n, tuple(map(float, e.split(","))), tuple(map(float, t.split(","))), float(l)))
    print("\n".join(bu.render_views(views, os.path.join(here, "out", "renders"), prefix)))
