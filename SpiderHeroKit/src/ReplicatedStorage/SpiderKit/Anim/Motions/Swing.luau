--!strict
--[[
	Swing motion: web-swinging.

	  * phase blend: the rope's angle from vertical in the direction of travel picks between
	    SwingDescend (entering the arc), SwingBottom (knees driving through the fastest point) and
	    SwingRise (legs kicking forward toward release)
	  * body alignment: the whole body hangs along the rope toward the anchor, rolled toward the
	    web hand like a real one-armed hang
	  * web arm: two-bone IK reaches along the rope; the hand flashes the thwip trigger while the
	    web fires, then grips
	  * two-handed grip: at high speed through the bottom the free hand grabs the line too
	  * secondary motion: legs trail with the swing's angular velocity (critically damped)
	  * left-hand swings are the mirrored right-hand poses
]]

local Pose = require(script.Parent.Parent.Pose)
local Clip = require(script.Parent.Parent.Clip)
local IK = require(script.Parent.Parent.IK)
local Quat = require(script.Parent.Parent.Parent.Math.Quat)
local Spring = require(script.Parent.Parent.Parent.Math.Spring)

local Swing = {}
Swing.__index = Swing
Swing.modes = { "Swing" }

local function smoothstep(a: number, b: number, x: number): number
	local t = math.clamp((x - a) / (b - a), 0, 1)
	return t * t * (3 - 2 * t)
end

function Swing.new(ac: any, _mode: string)
	local self = setmetatable({}, Swing)
	self.ac = ac
	self.t = 0
	self.phi = 0
	self.phiPrev = nil :: number?
	self.phiRate = 0
	self.lag, self.lagV = 0, 0
	self.twoHand = 0
	self.ikW = 0
	self.alignW = 0
	self.side = "Right"
	self.a = Pose.new(ac.count)
	self.b = Pose.new(ac.count)
	self.m = Pose.new(ac.count)
	local skel = ac.skel
	self.mirrorOf = {}
	for i, j in skel.joints do
		self.mirrorOf[i] = j.mirror or i
	end
	self.chains = {
		Right = { upper = skel.byName.RightShoulder.index, middle = skel.byName.RightElbow.index, finish = skel.byName.RightWrist.index, hinge = 1 },
		Left = { upper = skel.byName.LeftShoulder.index, middle = skel.byName.LeftElbow.index, finish = skel.byName.LeftWrist.index, hinge = 1 },
	}
	return self
end

function Swing:enter(ctx: any, _prev: string): number
	self.t = 0
	self.phiPrev = nil
	self.ikW = 0
	self.alignW = 0
	self.side = ctx.swingHand or "Right"
	self.lag, self.lagV = 0, 0
	return 0.11
end

function Swing:onEvent(name: string, data: any?)
	if name == "SwingStart" then
		self.t = 0
		self.ikW = 0
		self.side = (data and data.hand) or self.side
	end
end

-- rope direction in HumanoidRootPart space, from the root toward the anchor
local function ropeLocal(ctx: any): Vector3
	local anchor: Vector3? = ctx.anchor
	if not anchor then
		return Vector3.yAxis
	end
	local d = anchor - ctx.rootCF.Position
	if d.Magnitude < 1e-3 then
		return Vector3.yAxis
	end
	return ctx.rootCF:VectorToObjectSpace(d.Unit)
end

function Swing:update(dt: number, ctx: any, out: { number })
	local ac = self.ac
	local count = ac.count
	local lib = ac.lib
	self.t += dt
	local side = ctx.swingHand or self.side
	if side ~= self.side then
		-- switched hands mid-air (new web): blend through inertialization
		self.side = side
		ac:transition(0.1)
	end

	local r = ropeLocal(ctx)
	-- swing phase: rope lean in the travel plane (+ = anchor ahead, - = anchor behind)
	local phi = math.atan2(-r.Z, math.max(r.Y, 0.05))
	if self.phiPrev then
		local rate = (phi - self.phiPrev) / math.max(dt, 1e-4)
		self.phiRate = Spring.damp(self.phiRate, rate, 0.06, dt)
	end
	self.phiPrev = phi
	self.phi = Spring.damp(self.phi, phi, 0.05, dt)
	local deg = math.deg(self.phi)

	-- 1D blend over the phase
	local descend, bottom, rise = lib.SwingDescend, lib.SwingBottom, lib.SwingRise
	local wD = smoothstep(4, 34, deg)
	local wR = smoothstep(-6, -38, deg)
	Clip.sample(bottom, self.t, self.a, count, true, ac.skel.scale)
	if wD > 0.001 then
		Clip.sample(descend, self.t, self.b, count, true, ac.skel.scale)
		Pose.blendInto(self.a, self.b, wD, count)
	end
	if wR > 0.001 then
		Clip.sample(rise, self.t, self.b, count, true, ac.skel.scale)
		Pose.blendInto(self.a, self.b, wR, count)
	end
	if side == "Left" then
		Pose.mirror(out, self.a, self.mirrorOf, count)
	else
		Pose.copy(out, self.a, count)
	end

	-- secondary: legs trail against the swing's angular velocity
	local lagT = math.clamp(-self.phiRate * 0.16, -0.5, 0.5)
	self.lag, self.lagV = Spring.critical(self.lag, self.lagV, lagT, 0.12, dt)
	local skel = ac.skel
	for _, jn in { "RightHip", "LeftHip" } do
		local x, y, z, w = Quat.fromEulerXYZ(self.lag, 0, 0)
		Pose.preRotate(out, skel.byName[jn].index, x, y, z, w)
	end
	local kx, ky, kz, kw = Quat.fromEulerXYZ(-math.abs(self.lag) * 0.6, 0, 0)
	Pose.postRotate(out, skel.byName.RightKnee.index, kx, ky, kz, kw)
	Pose.postRotate(out, skel.byName.LeftKnee.index, kx, ky, kz, kw)

	-- body alignment along the rope, rolled toward the web hand
	self.alignW = Spring.damp(self.alignW, 1, 0.07, dt)
	local qx, qy, qz, qw = Quat.fromTo(0, 1, 0, r.X, r.Y, r.Z)
	qx, qy, qz, qw = Quat.slerp(0, 0, 0, 1, qx, qy, qz, qw, 0.88 * self.alignW)
	local rollSign = if side == "Right" then 1 else -1
	local rx, ry, rz, rw = Quat.fromEulerXYZ(0, 0, math.rad(13) * rollSign)
	qx, qy, qz, qw = Quat.mul(qx, qy, qz, qw, rx, ry, rz, rw)
	Pose.preRotate(out, skel.byName.Root.index, qx, qy, qz, qw)

	-- hands
	local webHand = side
	local freeHand = if side == "Right" then "Left" else "Right"
	local speed = ctx.velocity.Magnitude
	local twoT = smoothstep(55, 85, speed) * (1 - smoothstep(14, 34, math.abs(deg))) * smoothstep(0.35, 0.6, self.t)
	self.twoHand = Spring.damp(self.twoHand, twoT, 0.08, dt)
	local handTargets = ac.handTarget
	handTargets[webHand] = { if self.t < 0.13 then "Thwip" else "Grip", if self.t < 0.13 then "Thwip" else "Grip", 1 }
	handTargets[freeHand] = if self.twoHand > 0.5 then { "Grip", "Grip", 1 } else { "Open", "Open", 1 }
	ac.handHalflife[webHand] = 0.03
end

function Swing:post(dt: number, ctx: any, out: { number })
	local ac = self.ac
	local skel = ac.skel
	if not ctx.anchor then
		return
	end
	local side = self.side
	self.ikW = Spring.damp(self.ikW, if self.t > 0.03 then 1 else 0, 0.045, dt)
	local parts = IK.fk(skel, out, ac.parts)
	local chain = self.chains[side]
	local shoulder = IK.jointFrame(skel, parts, chain.upper).Position
	local anchorL = ctx.rootCF:PointToObjectSpace(ctx.anchor)
	local toAnchor = (anchorL - shoulder).Unit
	local j1, j2, j3 = skel.joints[chain.upper], skel.joints[chain.middle], skel.joints[chain.finish]
	local armLen = (j1.c1inv * j2.c0).Position.Magnitude + (j2.c1inv * j3.c0).Position.Magnitude
	local sideSign = if side == "Right" then 1 else -1
	local target = shoulder + toAnchor * armLen * 0.97
	local pole = Vector3.new(sideSign * 0.8, -0.2, 0.6)
	IK.solveTwoBone(skel, out, parts, chain, target, pole, self.ikW)
	-- wrist follows the forearm (fist wrapped around the line)
	local wrist = chain.finish
	local o = (wrist - 1) * 7
	local wx, wy, wz, ww = Quat.slerp(out[o + 1], out[o + 2], out[o + 3], out[o + 4], 0, 0, 0, 1, self.ikW)
	out[o + 1], out[o + 2], out[o + 3], out[o + 4] = wx, wy, wz, ww

	-- two-handed grip: free hand grabs the line a little below the web hand
	if self.twoHand > 0.01 then
		parts = IK.fk(skel, out, ac.parts)
		local handPos = (parts[side .. "Hand"] * CFrame.new(0, -0.14, 0)).Position
		local free = if side == "Right" then "Left" else "Right"
		local fchain = self.chains[free]
		local grab = handPos - toAnchor * 0.42
		IK.solveTwoBone(skel, out, parts, fchain, grab, Vector3.new(-sideSign * 0.9, -0.3, 0.4), self.twoHand)
	end
end

return Swing
