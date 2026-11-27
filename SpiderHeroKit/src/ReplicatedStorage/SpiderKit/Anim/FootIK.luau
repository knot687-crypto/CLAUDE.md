--!strict
--[[
	FootIK
	------
	Post-process for grounded motions:
	  * foot locking: when the animation plants a foot, the ankle's ground position (XZ) is pinned
	    to the world touchdown point until lift-off, so feet never skate even when the character's
	    speed and the cycle's authored stride differ. The vertical motion (heel roll, toe-off) still
	    comes from the animation.
	  * terrain: each foot follows the real ground height under it (stairs, slopes, ledges)
	  * no penetration: the ankle is raised whenever the animated sole would dip below the ground
	  * pelvis drop: if a foot target is out of reach the pelvis lowers so the leg can make it
	  * the animated knee direction and foot orientation are preserved
]]

local Pose = require(script.Parent.Pose)
local IK = require(script.Parent.IK)
local Spring = require(script.Parent.Parent.Math.Spring)

local SOLES = {
	Vector3.new(0, -0.135, 0.36),
	Vector3.new(0, -0.135, -0.25),
	Vector3.new(0, -0.1, -0.42),
}

type FootState = {
	lockXZ: Vector3?,
	w: number,
	ground: number,
	contact: boolean,
}

local FootIK = {}
FootIK.__index = FootIK

function FootIK.new(ac: any)
	local skel = ac.skel
	local self = setmetatable({}, FootIK)
	self.ac = ac
	self.feet = {
		Right = { lockXZ = nil, w = 0, ground = 0, contact = false } :: FootState,
		Left = { lockXZ = nil, w = 0, ground = 0, contact = false } :: FootState,
	}
	self.chains = {
		Right = { upper = skel.byName.RightHip.index, middle = skel.byName.RightKnee.index, finish = skel.byName.RightAnkle.index, hinge = -1 },
		Left = { upper = skel.byName.LeftHip.index, middle = skel.byName.LeftKnee.index, finish = skel.byName.LeftAnkle.index, hinge = -1 },
	}
	self.drop = 0
	return self
end

function FootIK:reset()
	for _, f in self.feet do
		f.lockXZ = nil
		f.w = 0
		f.contact = false
	end
end

export type Options = { lock: boolean?, weight: number?, contactHeight: number? }

function FootIK:apply(dt: number, ctx: any, out: { number }, opts: Options?)
	local o = opts or {}
	local weight = if o.weight == nil then 1 else o.weight
	if weight <= 0.001 then
		return
	end
	local ac = self.ac
	local skel = ac.skel
	local scale = skel.scale
	local rootCF: CFrame = ctx.rootCF
	local hipToGround: number = ctx.hipToGround or 3.3
	local parts = IK.fk(skel, out, ac.parts)
	local assumedGround = rootCF.Y - hipToGround
	local contactH = (o.contactHeight or 0.09) * scale

	local targets = {}
	local poles = {}
	local footRot = {}
	local needDrop = 0
	for side, f in self.feet do
		local chain = self.chains[side]
		local ankleL = IK.jointFrame(skel, parts, chain.finish).Position
		local hipL = IK.jointFrame(skel, parts, chain.upper).Position
		local kneeL = IK.jointFrame(skel, parts, chain.middle).Position
		local footCF = parts[side .. "Foot"]
		footRot[side] = footCF
		-- lowest sole point relative to the ankle, with the animated foot orientation
		local lowRel = math.huge
		for _, p in SOLES do
			lowRel = math.min(lowRel, (footCF * (p * scale)).Y - ankleL.Y)
		end
		local animSole = ankleL.Y + lowRel + hipToGround -- animated sole height above assumed ground
		local ankleW = rootCF * ankleL
		local gy = assumedGround
		if ctx.groundHeight then
			gy = ctx.groundHeight(ankleW) or assumedGround
		end
		local dy = math.clamp(gy - assumedGround, -1.6 * scale, 1.6 * scale)
		f.ground = Spring.damp(f.ground, dy, 0.04, dt)

		local contact = animSole < contactH
		if contact and o.lock ~= false then
			if not f.lockXZ then
				f.lockXZ = Vector3.new(ankleW.X, 0, ankleW.Z)
			else
				-- release if the animated foot has drifted far from the pin (turns, speed changes)
				local drift = Vector3.new(ankleW.X - f.lockXZ.X, 0, ankleW.Z - f.lockXZ.Z).Magnitude
				if drift > 0.55 * scale then
					f.lockXZ = Vector3.new(ankleW.X, 0, ankleW.Z)
				end
			end
			f.w = Spring.damp(f.w, 1, 0.02, dt)
		else
			f.w = Spring.damp(f.w, 0, 0.05, dt)
			if f.w < 0.02 then
				f.lockXZ = nil
			end
		end
		f.contact = contact

		local tx, tz = ankleW.X, ankleW.Z
		local lock = f.lockXZ
		if lock then
			tx += (lock.X - tx) * f.w
			tz += (lock.Z - tz) * f.w
		end
		local ty = ankleW.Y + f.ground
		-- keep the sole on or above the ground
		local minY = gy - lowRel
		if ty < minY then
			ty = minY
		end
		local targetL = rootCF:PointToObjectSpace(Vector3.new(tx, ty, tz))
		targets[side] = targetL
		local mid = (hipL + ankleL) / 2
		local pole = kneeL - mid
		if pole.Magnitude < 1e-3 then
			pole = Vector3.new(0, 0, -1)
		end
		poles[side] = pole
		local j1, j2, j3 = skel.joints[chain.upper], skel.joints[chain.middle], skel.joints[chain.finish]
		local reach = (j1.c1inv * j2.c0).Position.Magnitude + (j2.c1inv * j3.c0).Position.Magnitude
		needDrop = math.max(needDrop, (targetL - hipL).Magnitude - reach * 0.985)
	end

	-- pelvis drop (smoothed) so both feet can reach their targets
	self.drop = Spring.damp(self.drop, math.clamp(needDrop, 0, 1.2 * scale), 0.05, dt)
	if self.drop > 1e-4 then
		local root = skel.byName.Root.index
		out[(root - 1) * 7 + 6] -= self.drop * weight
		parts = IK.fk(skel, out, ac.parts)
	end

	for side, chain in self.chains do
		IK.solveTwoBone(skel, out, parts, chain, targets[side], poles[side], weight)
		-- keep the animated foot orientation (IK changed the shin)
		IK.orientEnd(skel, out, parts, chain.finish, footRot[side], weight)
	end
end

function FootIK:isPlanted(side: string): boolean
	return self.feet[side].contact
end

return FootIK
