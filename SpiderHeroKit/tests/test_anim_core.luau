--!nocheck
local T = require("TestUtil")
local RS = game:GetService("ReplicatedStorage")
local Kit = RS.SpiderKit
local Quat = require(Kit.Math.Quat)
local Pose = require(Kit.Anim.Pose)
local Clip = require(Kit.Anim.Clip)
local ClipBuilder = require(Kit.Anim.ClipBuilder)
local Skeleton = require(Kit.Anim.Skeleton)
local IK = require(Kit.Anim.IK)
local Inertializer = require(Kit.Anim.Inertializer)
local RigDefinition = require(Kit.Rig.RigDefinition)
local HandPoses = require(Kit.Anim.HandPoses)

T.section("Quat vs CFrame.Angles")
for _, a in { { 0.3, -0.7, 1.1 }, { -2.1, 0.4, 0.05 }, { 1.5, 1.4, -1.3 } } do
	local qx, qy, qz, qw = Quat.fromEulerXYZ(a[1], a[2], a[3])
	T.cfnear(CFrame.new(0, 0, 0, qx, qy, qz, qw), CFrame.Angles(a[1], a[2], a[3]), 1e-9, "euler xyz")
	local ex, ey, ez = Quat.toEulerXYZ(qx, qy, qz, qw)
	T.near(ex, a[1], 1e-9, "toEuler x")
	T.near(ey, a[2], 1e-9, "toEuler y")
end
local ax, ay, az, aw = Quat.fromEulerXYZ(0.2, 0.3, 0.4)
local bx, by, bz, bw = Quat.fromEulerXYZ(-0.5, 0.1, 0.9)
local mx, my, mz, mw = Quat.mul(ax, ay, az, aw, bx, by, bz, bw)
T.cfnear(CFrame.new(0, 0, 0, mx, my, mz, mw), CFrame.Angles(0.2, 0.3, 0.4) * CFrame.Angles(-0.5, 0.1, 0.9), 1e-9, "mul")
local vx, vy, vz = Quat.rotate(ax, ay, az, aw, 1, 2, 3)
T.vnear(Vector3.new(vx, vy, vz), CFrame.Angles(0.2, 0.3, 0.4) * Vector3.new(1, 2, 3), 1e-9, "rotate")
local lx, ly, lz = Quat.log(ax, ay, az, aw)
local rx, ry, rz, rw = Quat.exp(lx, ly, lz)
T.near(Quat.angleBetween(ax, ay, az, aw, rx, ry, rz, rw), 0, 1e-7, "exp(log)")
local fx, fy, fz, fw = Quat.fromTo(0, 1, 0, 1, 0, 0)
local tx, ty, tz = Quat.rotate(fx, fy, fz, fw, 0, 1, 0)
T.vnear(Vector3.new(tx, ty, tz), Vector3.new(1, 0, 0), 1e-9, "fromTo")

T.section("Clip sampling")
local raw = ClipBuilder.clip({
	name = "T",
	length = 1,
	keys = {
		{ 0, { RightShoulder = { 0, 0, 0 }, Root = { 0, 0, 0, 0, 0, 0 } } },
		{ 0.5, { RightShoulder = { 90, 0, 0 }, Root = { 0, 0, 0, 0, -0.5, 0 } } },
		{ 1, { RightShoulder = { 0, 0, 0 }, Root = { 0, 0, 0, 0, 0, 0 } } },
	},
})
local c = Clip.compile(raw)
local skel = Skeleton.fromDefinition()
local pose = Pose.new(skel.count)
Clip.sample(c, 0.5, pose, skel.count, true)
local sh = RigDefinition.JointIndex.RightShoulder
local qx, qy, qz, qw = Pose.get(pose, sh)
local ex = Quat.toEulerXYZ(qx, qy, qz, qw)
T.near(math.deg(ex), 90, 1e-6, "key hit exactly")
local _, _, _, _, _, py = Pose.get(pose, 1)
T.near(py, -0.5, 1e-9, "root translation key")
-- extremum keys have flat tangents: no overshoot past 90 degrees anywhere
local maxDeg = 0
for i = 0, 100 do
	Clip.sample(c, i / 100, pose, skel.count, true)
	local a = Quat.toEulerXYZ(Pose.get(pose, sh))
	maxDeg = math.max(maxDeg, math.deg(a))
end
T.near(maxDeg, 90, 1e-6, "no overshoot")

-- mirrored cycle
local cyc = Clip.compile(ClipBuilder.cycle({
	name = "C",
	length = 1,
	half = { { 0, { RightHip = { 30, 5, 10 }, LeftHip = { -20, 0, 0 } } }, { 0.25, { RightHip = { 0, 0, 0 }, LeftHip = { 0, 0, 0 } } } },
}))
Clip.sample(cyc, 0.5, pose, skel.count, true)
local lx2, ly2, lz2 = Quat.toEulerXYZ(Pose.get(pose, RigDefinition.JointIndex.LeftHip))
T.near(math.deg(lx2), 30, 1e-6, "mirror x")
T.near(math.deg(ly2), -5, 1e-6, "mirror y")
T.near(math.deg(lz2), -10, 1e-6, "mirror z")

T.section("FK matches Motor6D rest")
local rest = Pose.new(skel.count)
local parts = IK.fk(skel, rest, {})
local hrp = RigDefinition.RootPartCenter
for _, seg in RigDefinition.Segments do
	if parts[seg.name] then
		T.vnear(parts[seg.name].Position + hrp, seg.center, 1e-6, "rest " .. seg.name)
	end
end

T.section("Two-bone IK")
local chainR = { upper = sh, middle = RigDefinition.JointIndex.RightElbow, finish = RigDefinition.JointIndex.RightWrist, hinge = 1 }
for _, target in { Vector3.new(0.9, 1.2, -1.0), Vector3.new(0.2, 0.4, -0.9), Vector3.new(1.5, 0.9, 0.2), Vector3.new(0.6, -0.2, -1.1) } do
	local p = Pose.new(skel.count)
	local fkp = IK.fk(skel, p, {})
	local pole = Vector3.new(1, -0.3, 0.6)
	IK.solveTwoBone(skel, p, fkp, chainR, target, pole, 1)
	local fk2 = IK.fk(skel, p, {})
	local wristPivot = IK.jointFrame(skel, fk2, chainR.finish).Position
	T.vnear(wristPivot, target, 1e-4, "reach " .. tostring(target))
	-- elbow on the pole side of the shoulder->target line
	local shoulder = IK.jointFrame(skel, fk2, chainR.upper).Position
	local elbow = IK.jointFrame(skel, fk2, chainR.middle).Position
	local axis = (target - shoulder).Unit
	local e = (elbow - shoulder)
	local ep = e - axis * e:Dot(axis)
	local pp = pole - axis * pole:Dot(axis)
	T.ok(ep:Dot(pp) > 0, "elbow toward pole")
	local hx = Quat.toEulerXYZ(Pose.get(p, chainR.middle))
	T.ok(hx >= -1e-6, "elbow flexes forward")
end
local chainL = { upper = RigDefinition.JointIndex.RightHip, middle = RigDefinition.JointIndex.RightKnee, finish = RigDefinition.JointIndex.RightAnkle, hinge = -1 }
local p2 = Pose.new(skel.count)
local fk3 = IK.fk(skel, p2, {})
local legTarget = Vector3.new(0.3, -2.5, -0.6)
IK.solveTwoBone(skel, p2, fk3, chainL, legTarget, Vector3.new(0, 0, -1), 1)
local fk4 = IK.fk(skel, p2, {})
T.vnear(IK.jointFrame(skel, fk4, chainL.finish).Position, legTarget, 1e-4, "leg reach")
local kx = Quat.toEulerXYZ(Pose.get(p2, chainL.middle))
T.ok(kx <= 1e-6, "knee flexes backward")

T.section("Inertializer continuity")
local inert = Inertializer.new(skel.count)
local a = Pose.new(skel.count)
local b = Pose.new(skel.count)
Pose.rotateEuler(a, sh, 1.0, 0, 0)
local out = Pose.new(skel.count)
inert:transition(a, a, 1 / 60, b, 0.1)
inert:apply(0, b, out)
local o1 = Quat.toEulerXYZ(Pose.get(out, sh))
T.near(o1, 1.0, 1e-6, "starts at previous pose")
for _ = 1, 120 do
	inert:apply(1 / 60, b, out)
end
local o2 = Quat.toEulerXYZ(Pose.get(out, sh))
T.near(o2, 0, 1e-3, "settles on new source")

T.section("Hand presets")
for name in HandPoses.Presets do
	local ps = Pose.new(skel.count)
	HandPoses.writePreset(ps, "Right", name)
	HandPoses.writePreset(ps, "Left", name)
	local ix = RigDefinition.JointIndex.RightIndex1
	local lix = RigDefinition.JointIndex.LeftIndex1
	local _, _, rzR = Quat.toEulerXYZ(Pose.get(ps, ix))
	local _, _, rzL = Quat.toEulerXYZ(Pose.get(ps, lix))
	T.near(rzR, -rzL, 1e-9, "mirrored " .. name)
end

return T.finish()
