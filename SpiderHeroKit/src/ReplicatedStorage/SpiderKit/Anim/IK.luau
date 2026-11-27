--!strict
--[[
	IK
	--
	Forward kinematics in HumanoidRootPart space and an analytic two-bone IK solver that works
	directly on Motor6D frames (any C0/C1, so it fits every R15 body).

	Two-bone solve (shoulder-elbow-wrist or hip-knee-ankle):
	  1. hinge angle about the middle joint's X axis is solved exactly (Rodrigues + phase shift),
	     respecting the hinge direction (elbows flex +X, knees flex -X)
	  2. the upper joint rotation aims the chain at the target, then twists about the
	     shoulder->target axis so the middle joint points toward the pole vector
	Results are blended with the animated rotations by `weight`.
]]

local Quat = require(script.Parent.Parent.Math.Quat)
local Pose = require(script.Parent.Pose)
local Skeleton = require(script.Parent.Skeleton)

type Skeleton = Skeleton.Skeleton

local IK = {}

-- Computes HRP-space CFrames of every part (HumanoidRootPart = identity).
function IK.fk(skel: Skeleton, pose: { number }, out: { [string]: CFrame }, upTo: number?): { [string]: CFrame }
	out.HumanoidRootPart = CFrame.identity
	local last = upTo or skel.count
	for i = 1, last do
		local j = skel.joints[i]
		local p0 = out[j.part0]
		if p0 then
			out[j.part1] = p0 * j.c0 * Pose.transform(pose, i) * j.c1inv
		end
	end
	return out
end

-- Joint pivot frame (before Transform) in HRP space, given parts from IK.fk.
function IK.jointFrame(skel: Skeleton, parts: { [string]: CFrame }, jointIndex: number): CFrame
	local j = skel.joints[jointIndex]
	return parts[j.part0] * j.c0
end

local function rodrigues(v: Vector3, k: Vector3, c: number, s: number): Vector3
	local par = k * v:Dot(k)
	local perp = v - par
	return par + perp * c + k:Cross(perp) * s
end

export type Chain = { upper: number, middle: number, finish: number, hinge: number } -- hinge: +1 elbow, -1 knee

--[[ Solves the chain toward `target` (HRP space) with the middle joint bending toward `pole`
	 (HRP space direction). Writes rotations into `pose`. `parts` must hold FK results at least
	 for the upper joint's parent. Returns the reach ratio (|target| / max reach). ]]
function IK.solveTwoBone(skel: Skeleton, pose: { number }, parts: { [string]: CFrame }, chain: Chain, target: Vector3, pole: Vector3, weight: number, maxStretch: number?): number
	if weight <= 0 then
		return 0
	end
	local up = skel.joints[chain.upper]
	local mid = skel.joints[chain.middle]
	local fin = skel.joints[chain.finish]
	local frameUp = parts[up.part0] * up.c0

	local midRel = up.c1inv * mid.c0 -- middle joint frame in upper joint frame (T = I)
	local a = midRel.Position
	local finRel = mid.c1inv * fin.c0 -- end joint frame in middle joint frame
	local b = finRel.Position
	local kAxis = midRel:VectorToWorldSpace(Vector3.xAxis)
	local bPrime = midRel:VectorToWorldSpace(b)

	local t = frameUp:PointToObjectSpace(target)
	local la, lb = a.Magnitude, b.Magnitude
	local reach = la + lb
	local d = t.Magnitude
	local ratio = d / reach
	d = math.clamp(d, math.abs(la - lb) + 1e-3, reach * (maxStretch or 0.9995))

	-- hinge angle
	local bPar = kAxis * bPrime:Dot(kAxis)
	local bPerp = bPrime - bPar
	local C = a:Dot(bPar)
	local P = a:Dot(bPerp)
	local Q = a:Dot(kAxis:Cross(bPerp))
	local D = (d * d - la * la - lb * lb) / 2
	local R = math.sqrt(P * P + Q * Q)
	local theta = 0
	if R > 1e-9 then
		local phi = math.atan2(Q, P)
		local acosArg = math.clamp((D - C) / R, -1, 1)
		local delta = math.acos(acosArg)
		local r1, r2 = phi + delta, phi - delta
		local natural = chain.hinge * math.acos(math.clamp((d * d - la * la - lb * lb) / (2 * la * lb), -1, 1))
		theta = if math.abs(r1 - natural) < math.abs(r2 - natural) then r1 else r2
	end

	-- upper rotation: aim, then twist toward the pole
	local c, s = math.cos(theta), math.sin(theta)
	local w = a + rodrigues(bPrime, kAxis, c, s)
	local tHat = t.Unit
	local q1x, q1y, q1z, q1w = Quat.fromTo(w.Unit.X, w.Unit.Y, w.Unit.Z, tHat.X, tHat.Y, tHat.Z)
	local ex, ey, ez = Quat.rotate(q1x, q1y, q1z, q1w, a.X, a.Y, a.Z)
	local e1 = Vector3.new(ex, ey, ez)
	local poleLocal = frameUp:VectorToObjectSpace(pole)
	local e1p = e1 - tHat * e1:Dot(tHat)
	local pp = poleLocal - tHat * poleLocal:Dot(tHat)
	local qx, qy, qz, qw = q1x, q1y, q1z, q1w
	if e1p.Magnitude > 1e-6 and pp.Magnitude > 1e-6 then
		local u, v = e1p.Unit, pp.Unit
		local ang = math.atan2(u:Cross(v):Dot(tHat), u:Dot(v))
		local tx, ty, tz, tw = Quat.fromAxisAngle(tHat.X, tHat.Y, tHat.Z, ang)
		qx, qy, qz, qw = Quat.mul(tx, ty, tz, tw, q1x, q1y, q1z, q1w)
	end

	-- write (blend with the animated rotation)
	local o = (chain.upper - 1) * 7
	if weight < 1 then
		qx, qy, qz, qw = Quat.slerp(pose[o + 1], pose[o + 2], pose[o + 3], pose[o + 4], qx, qy, qz, qw, weight)
	end
	pose[o + 1], pose[o + 2], pose[o + 3], pose[o + 4] = qx, qy, qz, qw
	local hx, hy, hz, hw = Quat.fromAxisAngle(1, 0, 0, theta)
	local om = (chain.middle - 1) * 7
	if weight < 1 then
		hx, hy, hz, hw = Quat.slerp(pose[om + 1], pose[om + 2], pose[om + 3], pose[om + 4], hx, hy, hz, hw, weight)
	end
	pose[om + 1], pose[om + 2], pose[om + 3], pose[om + 4] = hx, hy, hz, hw
	-- refresh FK for the chain parts
	parts[up.part1] = parts[up.part0] * up.c0 * Pose.transform(pose, chain.upper) * up.c1inv
	parts[mid.part1] = parts[mid.part0] * mid.c0 * Pose.transform(pose, chain.middle) * mid.c1inv
	parts[fin.part1] = parts[fin.part0] * fin.c0 * Pose.transform(pose, chain.finish) * fin.c1inv
	return ratio
end

--[[ Sets the end joint rotation so the end part reaches `targetRot` (HRP-space rotation),
	 blended by weight. ]]
function IK.orientEnd(skel: Skeleton, pose: { number }, parts: { [string]: CFrame }, jointIndex: number, targetRot: CFrame, weight: number)
	if weight <= 0 then
		return
	end
	local j = skel.joints[jointIndex]
	local frame = parts[j.part0] * j.c0
	-- part = frame * T * c1inv  =>  T = frame^-1 * part * c1  (rotation only)
	local want = (frame.Rotation:Inverse() * targetRot.Rotation * j.c1.Rotation)
	local tx, ty, tz, tw = Quat.fromCFrame(want)
	local o = (jointIndex - 1) * 7
	if weight < 1 then
		tx, ty, tz, tw = Quat.slerp(pose[o + 1], pose[o + 2], pose[o + 3], pose[o + 4], tx, ty, tz, tw, weight)
	end
	pose[o + 1], pose[o + 2], pose[o + 3], pose[o + 4] = tx, ty, tz, tw
	parts[j.part1] = parts[j.part0] * j.c0 * Pose.transform(pose, jointIndex) * j.c1inv
end

return IK
