--!strict
--[[
	Wall motions
	------------
	WallCrawl: procedural spider gait on any wall, in any direction.
	  * every limb is pinned to a world anchor on the wall plane while planted
	  * a limb steps when it drifts too far from its stance spot (relative to the body); steps lead
	    in the direction of travel and arc away from the wall
	  * diagonal pairs (right hand + left foot, left hand + right foot) step together, and a pair may
	    only lift while the other pair is planted, so the body is always supported
	  * two-bone IK reaches each anchor with elbows/knees splayed outward; palms and soles are
	    oriented flat against the wall; the hands open mid-step and splay on contact
	  * the body sways toward the planted pair and breathes; the head turns toward travel
	  The controller orients the HumanoidRootPart to face the wall (LookVector = -normal) with its
	  UpVector along the wall's "up", at WALL_DISTANCE from the surface.

	WallRun: sprint cycle on a wall (the controller sets UpVector = wall normal, LookVector = run
	direction), stride-matched to the run speed with an extra forward lean.
]]

local Pose = require(script.Parent.Parent.Pose)
local Clip = require(script.Parent.Parent.Clip)
local IK = require(script.Parent.Parent.IK)
local Quat = require(script.Parent.Parent.Parent.Math.Quat)
local Spring = require(script.Parent.Parent.Parent.Math.Spring)

local Wall = {}
Wall.__index = Wall
Wall.modes = { "WallCrawl", "WallRun" }
Wall.WALL_DISTANCE = 0.62

local function smoothstep(a: number, b: number, x: number): number
	local t = math.clamp((x - a) / (b - a), 0, 1)
	return t * t * (3 - 2 * t)
end

-- stance spots (HumanoidRootPart space; the wall is the plane z = -WALL_DISTANCE)
local STANCE = {
	RightHand = Vector3.new(0.82, 1.32, 0),
	LeftHand = Vector3.new(-0.82, 1.32, 0),
	RightFoot = Vector3.new(0.66, -1.55, 0),
	LeftFoot = Vector3.new(-0.66, -1.55, 0),
}
local CONTACT_OFFSET = { Hand = 0.075, Foot = 0.115 } -- wrist/ankle pivot distance from the surface
local PAIRS = { { "RightHand", "LeftFoot" }, { "LeftHand", "RightFoot" } }

type Limb = {
	name: string,
	anchor: Vector3, -- world
	stepping: boolean,
	t: number,
	dur: number,
	from: Vector3,
	to: Vector3,
	w: number, -- IK weight
}

function Wall.new(ac: any, mode: string)
	local self = setmetatable({}, Wall)
	self.ac = ac
	self.mode = mode
	self.t = 0
	self.phase = 0
	self.limbs = {} :: { [string]: Limb }
	self.sway, self.swayV = Vector3.zero, Vector3.zero
	self.ikW = 0
	self.compress, self.compressV = 0, 0
	self.lastPair = 2
	self.speed = 0
	local skel = ac.skel
	self.chains = {
		RightHand = { upper = skel.byName.RightShoulder.index, middle = skel.byName.RightElbow.index, finish = skel.byName.RightWrist.index, hinge = 1 },
		LeftHand = { upper = skel.byName.LeftShoulder.index, middle = skel.byName.LeftElbow.index, finish = skel.byName.LeftWrist.index, hinge = 1 },
		RightFoot = { upper = skel.byName.RightHip.index, middle = skel.byName.RightKnee.index, finish = skel.byName.RightAnkle.index, hinge = -1 },
		LeftFoot = { upper = skel.byName.LeftHip.index, middle = skel.byName.LeftKnee.index, finish = skel.byName.LeftAnkle.index, hinge = -1 },
	}
	self.a = Pose.new(ac.count)
	return self
end

local function wallPoint(rootCF: CFrame, localXY: Vector3, contact: number): Vector3
	return rootCF:PointToWorldSpace(Vector3.new(localXY.X, localXY.Y, -Wall.WALL_DISTANCE + contact))
end

function Wall:enter(ctx: any, prevMode: string): number
	self.t = 0
	self.ikW = 0
	if self.mode == "WallCrawl" then
		for name, st in STANCE do
			local kind = if name:find("Hand") then "Hand" else "Foot"
			local p = wallPoint(ctx.rootCF, st, CONTACT_OFFSET[kind])
			self.limbs[name] = { name = name, anchor = p, stepping = false, t = 0, dur = 0.2, from = p, to = p, w = 0 }
		end
		-- impact: compress toward the wall, then spring back
		self.compressV = -math.clamp(ctx.velocity.Magnitude * 0.04, 0.4, 2.2)
		return 0.09
	end
	return 0.1
end

function Wall:onEvent(name: string, data: any?)
	if name == "LedgeVault" then
		self.ac:play("LedgeVault", { halflife = 0.06, outHalflife = 0.16 })
	end
end

-- Begins a synchronized step for a diagonal pair toward stance spots led by the travel velocity.
function Wall:stepPair(pair: { string }, rootCF: CFrame, velLocal: Vector3, speed: number)
	local lead = Vector3.new(velLocal.X, velLocal.Y, 0) * 0.16
	local dur = math.clamp(0.24 - speed * 0.007, 0.14, 0.24)
	for _, name in pair do
		local limb = self.limbs[name]
		local kind = if name:find("Hand") then "Hand" else "Foot"
		limb.stepping = true
		limb.t = 0
		limb.dur = dur
		limb.from = limb.anchor
		limb.to = wallPoint(rootCF, STANCE[name] + lead, CONTACT_OFFSET[kind])
	end
end

function Wall:update(dt: number, ctx: any, out: { number })
	local ac = self.ac
	local count = ac.count
	local lib = ac.lib
	self.t += dt
	if self.mode == "WallRun" then
		-- stride-matched sprint along the wall
		local lv = ctx.rootCF:VectorToObjectSpace(ctx.velocity)
		local spd = math.max(0, -lv.Z)
		self.speed = Spring.damp(self.speed, spd, 0.06, dt)
		local clip = lib.Sprint
		local cycle = (clip.speed * clip.length) / math.max(self.speed, clip.speed * 0.6)
		local p0 = self.phase
		self.phase = (self.phase + dt / cycle) % 1
		Clip.sample(clip, self.phase * clip.length, out, count, true, ac.skel.scale)
		Clip.eventsBetween(clip, p0 * clip.length, p0 * clip.length + dt / cycle * clip.length, ac.events)
		local qx, qy, qz, qw = Quat.fromEulerXYZ(-0.18, 0, 0)
		Pose.preRotate(out, ac.skel.byName.Root.index, qx, qy, qz, qw)
		ac:handsFromClip(clip, self.phase * clip.length)
		return
	end

	-- crawl: body from the WallIdle clip, limbs placed by the gait in post()
	Clip.sample(lib.WallIdle, self.t, out, count, true, ac.skel.scale)
	local rootCF: CFrame = ctx.rootCF
	local velLocal = rootCF:VectorToObjectSpace(ctx.velocity)
	local speed = Vector3.new(velLocal.X, velLocal.Y, 0).Magnitude
	self.speed = Spring.damp(self.speed, speed, 0.08, dt)

	-- advance steps
	local anyStepping = { false, false }
	for pi, pair in PAIRS do
		for _, name in pair do
			local limb = self.limbs[name]
			if limb and limb.stepping then
				limb.t += dt / limb.dur
				if limb.t >= 1 then
					limb.stepping = false
					limb.anchor = limb.to
					ac:emit(if name:find("Hand") then "WallGrabHand" else "WallGrabFoot")
				else
					anyStepping[pi] = true
				end
			end
		end
	end
	-- decide next step: the pair whose limbs drifted most from their stance spots
	if not anyStepping[1] and not anyStepping[2] then
		local worst, worstPair = 0, 0
		local threshold = if self.speed > 0.5 then 0.24 else 0.12
		for pi, pair in PAIRS do
			local drift = 0
			for _, name in pair do
				local limb = self.limbs[name]
				local kind = if name:find("Hand") then "Hand" else "Foot"
				local want = wallPoint(rootCF, STANCE[name] + Vector3.new(velLocal.X, velLocal.Y, 0) * 0.16, CONTACT_OFFSET[kind])
				drift = math.max(drift, (limb.anchor - want).Magnitude)
			end
			-- alternate pairs when both drifted similarly
			if pi ~= self.lastPair then
				drift *= 1.15
			end
			if drift > worst then
				worst, worstPair = drift, pi
			end
		end
		if worstPair > 0 and worst > threshold then
			self:stepPair(PAIRS[worstPair], rootCF, velLocal, self.speed)
			self.lastPair = worstPair
		end
	end

	-- body sway toward the planted pair + bob with each step
	local swayT = Vector3.zero
	for pi, pair in PAIRS do
		local stepping = self.limbs[pair[1]].stepping
		if stepping then
			local planted = PAIRS[3 - pi]
			local c = (STANCE[planted[1]] + STANCE[planted[2]]) * 0.5
			local t = self.limbs[pair[1]].t
			swayT = Vector3.new(c.X * 0.07, c.Y * 0.03, 0.05 * math.sin(math.pi * t))
		end
	end
	self.sway = Spring.stepV({ x = self.sway, v = self.swayV, halflife = 0.08 } :: any, swayT, dt)
	local root = ac.skel.byName.Root.index
	local o = (root - 1) * 7
	out[o + 5] += self.sway.X
	out[o + 6] += self.sway.Y
	out[o + 7] += self.sway.Z
	local rx, ry, rz, rw = Quat.fromEulerXYZ(0, -self.sway.X * 0.6, self.sway.X * 0.9)
	Pose.preRotate(out, root, rx, ry, rz, rw)
	-- impact compression on attach
	self.compress, self.compressV = Spring.underdamped(self.compress, self.compressV, 0, 2.2, 0.55, dt)
	out[o + 7] += self.compress * -0.12
	-- hands: open while stepping, splayed on the wall
	for _, side in { "Right", "Left" } do
		local limb = self.limbs[side .. "Hand"]
		local preset = if limb and limb.stepping and limb.t < 0.75 then "Open" else "Splay"
		ac.handTarget[side] = { preset, preset, 1 }
	end
end

function Wall:post(dt: number, ctx: any, out: { number })
	if self.mode ~= "WallCrawl" then
		return
	end
	local ac = self.ac
	local skel = ac.skel
	local rootCF: CFrame = ctx.rootCF
	self.ikW = Spring.damp(self.ikW, 1, 0.05, dt)
	local parts = IK.fk(skel, out, ac.parts)
	local wallNormalLocal = Vector3.new(0, 0, 1)
	for name, limb in self.limbs do
		local chain = self.chains[name]
		local pos: Vector3
		if limb.stepping then
			local t = limb.t
			local e = t * t * (3 - 2 * t)
			pos = limb.from:Lerp(limb.to, e)
			local lift = math.sin(math.pi * t) * (if name:find("Hand") then 0.2 else 0.16)
			pos += rootCF:VectorToWorldSpace(wallNormalLocal) * lift
		else
			pos = limb.anchor
		end
		local target = rootCF:PointToObjectSpace(pos)
		local isHand = name:find("Hand") ~= nil
		local sx = if name:find("Right") then 1 else -1
		local pole = if isHand then Vector3.new(sx * 1.0, -0.45, 0.35) else Vector3.new(sx * 1.0, 0.25, 0.1)
		IK.solveTwoBone(skel, out, parts, chain, target, pole, self.ikW)
		-- palm / sole flat against the wall
		local rot: CFrame
		if isHand then
			-- fingers point up and slightly outward, palm faces the wall (-Z)
			local fingers = Vector3.new(sx * 0.35, 1, 0).Unit
			local palmOut = Vector3.new(0, 0, 1) -- back of the hand away from the wall
			-- right hand rest: fingers = -Y, back of hand = +X  ->  build that frame
			local yAxis = -fingers
			local xAxis = palmOut * sx
			local zAxis = xAxis:Cross(yAxis).Unit
			xAxis = yAxis:Cross(zAxis).Unit
			rot = CFrame.fromMatrix(Vector3.zero, xAxis, yAxis, zAxis)
		else
			-- sole on the wall: foot rest sole normal is -Y, toes -Z; toes point down and outward
			local toes = Vector3.new(sx * 0.45, -1, 0).Unit
			local soleN = Vector3.new(0, 0, -1)
			local yAxis = -soleN
			local zAxis = -toes
			zAxis = (zAxis - yAxis * zAxis:Dot(yAxis)).Unit
			local xAxis = yAxis:Cross(zAxis).Unit
			rot = CFrame.fromMatrix(Vector3.zero, xAxis, yAxis, zAxis)
		end
		IK.orientEnd(skel, out, parts, chain.finish, rot, self.ikW * 0.85)
	end
end

return Wall
