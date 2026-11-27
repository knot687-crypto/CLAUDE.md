--!strict
--[[
	Zip, Perch and Ledge motions.

	Zip: point-launch / web-zip. Both arms reach along the web lines toward the target with IK,
	the body streams behind them, aligned with the pull direction.

	Perch: the classic low crouch on a ledge (Perch clip) with foot IK keeping the feet planted.

	Ledge: plays the LedgeVault clip while the controller carries the root up and over an edge.
]]

local Pose = require(script.Parent.Parent.Pose)
local Clip = require(script.Parent.Parent.Clip)
local IK = require(script.Parent.Parent.IK)
local FootIK = require(script.Parent.Parent.FootIK)
local Quat = require(script.Parent.Parent.Parent.Math.Quat)
local Spring = require(script.Parent.Parent.Parent.Math.Spring)

local Misc = {}
Misc.__index = Misc
Misc.modes = { "Zip", "Perch", "Ledge" }

function Misc.new(ac: any, mode: string)
	local self = setmetatable({}, Misc)
	self.ac = ac
	self.mode = mode
	self.t = 0
	self.ikW = 0
	self.footIK = FootIK.new(ac)
	local skel = ac.skel
	self.arms = {
		Right = { upper = skel.byName.RightShoulder.index, middle = skel.byName.RightElbow.index, finish = skel.byName.RightWrist.index, hinge = 1 },
		Left = { upper = skel.byName.LeftShoulder.index, middle = skel.byName.LeftElbow.index, finish = skel.byName.LeftWrist.index, hinge = 1 },
	}
	return self
end

function Misc:enter(ctx: any, prevMode: string): number
	self.t = 0
	self.ikW = 0
	self.footIK:reset()
	if self.mode == "Ledge" then
		self.ac:play("LedgeVault", { mode = "Ledge", halflife = 0.06, outHalflife = 0.18 })
		return 0.06
	end
	if self.mode == "Perch" then
		return 0.16
	end
	return 0.08
end

function Misc:update(dt: number, ctx: any, out: { number })
	local ac = self.ac
	local lib = ac.lib
	self.t += dt
	if self.mode == "Zip" then
		Clip.sample(lib.ZipPull, self.t, out, ac.count, true, ac.skel.scale)
		ac:handsFromClip(lib.ZipPull, self.t)
		-- align the body with the pull direction (head leading toward the target)
		if ctx.zipTarget then
			local d = ctx.rootCF:VectorToObjectSpace((ctx.zipTarget - ctx.rootCF.Position).Unit)
			-- the ZipPull pose already pitches the body forward 78 deg; tilt that line toward d
			local pitch = math.atan2(d.Y, -d.Z)
			local qx, qy, qz, qw = Quat.fromEulerXYZ(math.clamp(pitch, -1.2, 1.2) * 0.85, 0, 0)
			Pose.preRotate(out, ac.skel.byName.Root.index, qx, qy, qz, qw)
		end
	elseif self.mode == "Perch" then
		Clip.sample(lib.Perch, self.t, out, ac.count, true, ac.skel.scale)
		ac:handsFromClip(lib.Perch, self.t)
	else
		-- Ledge: the vault one-shot drives the pose; hold the last frame if it ended early
		Clip.sample(lib.LedgeVault, lib.LedgeVault.length, out, ac.count, true, ac.skel.scale)
	end
end

function Misc:post(dt: number, ctx: any, out: { number })
	local ac = self.ac
	if self.mode == "Perch" then
		self.footIK:apply(dt, ctx, out, { lock = true })
		return
	end
	if self.mode == "Zip" and ctx.zipTarget then
		self.ikW = Spring.damp(self.ikW, 1, 0.05, dt)
		local skel = ac.skel
		local parts = IK.fk(skel, out, ac.parts)
		local targetL = ctx.rootCF:PointToObjectSpace(ctx.zipTarget)
		for side, chain in self.arms do
			local sh = IK.jointFrame(skel, parts, chain.upper).Position
			local j1, j2, j3 = skel.joints[chain.upper], skel.joints[chain.middle], skel.joints[chain.finish]
			local reach = (j1.c1inv * j2.c0).Position.Magnitude + (j2.c1inv * j3.c0).Position.Magnitude
			local dir = (targetL - sh).Unit
			local sx = if side == "Right" then 1 else -1
			IK.solveTwoBone(skel, out, parts, chain, sh + dir * reach * 0.93, Vector3.new(sx, -0.5, 0.4), self.ikW)
		end
	end
end

return Misc
