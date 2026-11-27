--!strict
--[[
	Air motion: rise / fall / dive blended by vertical velocity and time in the air, plus
	air-steering lean and a procedural wind flutter on the limbs at speed.
	Jumps and tricks play as one-shots (see onEvent) and hand back to this motion when they end.
]]

local Pose = require(script.Parent.Parent.Pose)
local Clip = require(script.Parent.Parent.Clip)
local Quat = require(script.Parent.Parent.Parent.Math.Quat)
local Spring = require(script.Parent.Parent.Parent.Math.Spring)

local Air = {}
Air.__index = Air
Air.modes = { "Air" }

local function smoothstep(a: number, b: number, x: number): number
	local t = math.clamp((x - a) / (b - a), 0, 1)
	return t * t * (3 - 2 * t)
end

function Air.new(ac: any, _mode: string)
	local self = setmetatable({}, Air)
	self.ac = ac
	self.t = 0
	self.vy = 0
	self.wRise, self.wDive = 0, 0
	self.roll, self.rollV = 0, 0
	self.pitch, self.pitchV = 0, 0
	self.a = Pose.new(ac.count)
	self.b = Pose.new(ac.count)
	return self
end

function Air:enter(ctx: any, prevMode: string): number
	self.t = 0
	self.vy = ctx.velocity.Y
	self.wRise = smoothstep(-8, 14, self.vy)
	self.wDive = 0
	if prevMode == "Swing" or prevMode == "Zip" then
		return 0.14
	end
	return 0.1
end

function Air:onEvent(name: string, data: any?)
	local ac = self.ac
	local d = data or {}
	if name == "Jump" then
		ac:play(if d.sprint then "SprintJump" else "Jump", { mode = "Air", halflife = 0.045, outHalflife = 0.16 })
	elseif name == "Trick" then
		ac:play(d.name or "FrontFlip", { mode = "Air", halflife = 0.07, outHalflife = 0.18, rate = d.rate })
	elseif name == "WallJump" then
		ac:play("WallJump", { mode = "Air", halflife = 0.05, outHalflife = 0.2 })
	end
end

function Air:update(dt: number, ctx: any, out: { number })
	local ac = self.ac
	local count = ac.count
	local lib = ac.lib
	self.t += dt
	self.vy = Spring.damp(self.vy, ctx.velocity.Y, 0.06, dt)
	local vy = self.vy
	local hv = Vector3.new(ctx.velocity.X, 0, ctx.velocity.Z).Magnitude

	local rise = smoothstep(-10, 14, vy)
	local dive = smoothstep(-55, -100, vy) * smoothstep(0.45, 0.9, self.t)
	self.wRise = Spring.damp(self.wRise, rise, 0.08, dt)
	self.wDive = Spring.damp(self.wDive, dive, 0.12, dt)

	Clip.sample(lib.AirFall, self.t, out, count, true, ac.skel.scale)
	if self.wRise > 0.001 then
		Clip.sample(lib.AirRise, self.t, self.a, count, true, ac.skel.scale)
		Pose.blendInto(out, self.a, self.wRise, count)
	end
	if self.wDive > 0.001 then
		Clip.sample(lib.Dive, self.t, self.a, count, true, ac.skel.scale)
		Pose.blendInto(out, self.a, self.wDive, count)
	end
	if self.wDive > 0.5 then
		ac:handsFromClip(lib.Dive, self.t)
	elseif self.wRise > 0.5 then
		ac:handsFromClip(lib.AirRise, self.t)
	else
		ac:handsFromClip(lib.AirFall, self.t)
	end

	-- dive: pitch the (straight) dive body along the velocity: head-first when dropping
	-- vertically, flattening toward belly-down as horizontal speed dominates
	if self.wDive > 0.001 then
		local lv = ctx.rootCF:VectorToObjectSpace(ctx.velocity)
		local fwd = math.max(0, -lv.Z)
		local down = math.max(1, -lv.Y)
		local pitchDive = -math.pi + math.atan2(fwd, down) * 0.85
		local root = ac.skel.byName.Root.index
		local dx, dy, dz, dw = Quat.fromEulerXYZ(pitchDive * self.wDive, 0, 0)
		Pose.preRotate(out, root, dx, dy, dz, dw)
	end

	-- steering lean (toward the input, relative to the facing)
	local md = ctx.rootCF:VectorToObjectSpace(ctx.moveDir)
	local rollT = math.clamp(-md.X * 0.35, -0.35, 0.35) * (1 - self.wDive)
	local pitchT = math.clamp(md.Z * 0.22, -0.25, 0.25) * (1 - self.wDive)
	self.roll, self.rollV = Spring.critical(self.roll, self.rollV, rollT, 0.14, dt)
	self.pitch, self.pitchV = Spring.critical(self.pitch, self.pitchV, pitchT, 0.16, dt)
	local root = ac.skel.byName.Root.index
	local qx, qy, qz, qw = Quat.fromEulerXYZ(self.pitch, 0, self.roll)
	Pose.preRotate(out, root, qx, qy, qz, qw)

	-- wind flutter on the limbs at speed
	local speed = math.sqrt(hv * hv + vy * vy)
	local f = math.clamp((speed - 40) / 80, 0, 1) * 0.05
	if f > 0.001 then
		local tt = self.t
		for _, jn in { "RightElbow", "LeftElbow", "RightKnee", "LeftKnee", "RightShoulder", "LeftShoulder" } do
			local j = ac.skel.byName[jn].index
			local n = math.sin(tt * 23 + j * 1.7) * 0.6 + math.sin(tt * 37 + j * 2.3) * 0.4
			local x, y, z, w = Quat.fromEulerXYZ(n * f, 0, n * f * 0.5)
			Pose.postRotate(out, j, x, y, z, w)
		end
	end
end

return Air
