--!strict
--[[
	AnimController
	--------------
	The per-character animation brain. Engine-agnostic: it only produces poses (Motor6D.Transform
	values); AnimDriver writes them to the rig in Roblox, and the offline tools bake them for previews.

	Frame pipeline
	  1. the active Motion (or a one-shot clip) builds the source pose
	  2. masked overlays (e.g. a web-shot arm) are mixed in
	  3. inertialization turns any discontinuity (state change, one-shot start/end) into a smooth,
	     velocity-preserving transition
	  4. the Motion's post pass applies IK on the final pose (foot locking / terrain, hands on the web
	     line, limbs on walls) so contacts stay exact even mid-transition
	  5. head look-at, then the smoothed finger poses are written

	Context (ctx) is filled by the driver every frame; see the Context type.
]]

local Pose = require(script.Parent.Pose)
local Clip = require(script.Parent.Clip)
local ClipLibrary = require(script.Parent.ClipLibrary)
local HandPoses = require(script.Parent.HandPoses)
local Inertializer = require(script.Parent.Inertializer)
local Skeleton = require(script.Parent.Skeleton)
local Spring = require(script.Parent.Parent.Math.Spring)
local Quat = require(script.Parent.Parent.Math.Quat)

export type Context = {
	state: string, -- Ground | Air | Swing | Zip | WallCrawl | WallRun | Perch | Ledge | Dead
	rootCF: CFrame, -- HumanoidRootPart world CFrame
	velocity: Vector3, -- world velocity
	moveDir: Vector3, -- desired move direction (world, magnitude 0..1)
	lookDir: Vector3?, -- direction the character should look (camera for the local player)
	sprint: boolean?,
	groundHeight: ((Vector3) -> number?)?, -- ground Y below a world point (nil = assume flat)
	groundY: number?, -- ground Y below the root (fallback)
	anchor: Vector3?, -- swing anchor (world)
	swingHand: string?, -- "Right" | "Left"
	wallNormal: Vector3?,
	zipTarget: Vector3?,
	webHands: { string }?, -- hands holding zip lines
	trick: string?,
}

export type OneShot = {
	clip: Clip.Clip,
	t: number,
	rate: number,
	mode: string?,
	outHalflife: number,
	interrupt: ((ctx: Context, t: number) -> boolean)?,
	onEnd: (() -> ())?,
	flags: { [string]: boolean },
	loopFor: number?,
}

export type Overlay = {
	clip: Clip.Clip,
	t: number,
	rate: number,
	mask: { number },
	fadeIn: number,
	fadeOut: number,
	weight: number,
}

local AnimController = {}
AnimController.__index = AnimController

local MOTIONS = script.Parent.Motions

-- Joint masks for overlays
local function maskFor(skel: Skeleton.Skeleton, names: { string }, weight: number?): { number }
	local m = table.create(skel.count, 0)
	for _, n in names do
		local j = skel.byName[n]
		if j then
			m[j.index] = weight or 1
		end
	end
	return m
end

function AnimController.new(skel: Skeleton.Skeleton)
	local count = skel.count
	local self = setmetatable({}, AnimController)
	self.skel = skel
	self.count = count
	self.lib = ClipLibrary.get()
	self.src = Pose.new(count)
	self.out = Pose.new(count)
	self.prevOut = Pose.new(count)
	self.tmp = Pose.new(count)
	self.inert = Inertializer.new(count)
	self.pending = nil :: number?
	self.lastDt = 1 / 60
	self.time = 0
	self.mode = "Ground"
	self.oneShot = nil :: OneShot?
	self.overlays = {} :: { Overlay }
	self.events = {} :: { string }
	self.hands = { Right = HandPoses.newState("Right"), Left = HandPoses.newState("Left") }
	self.handTarget = { Right = { "Relaxed", "Relaxed", 1 }, Left = { "Relaxed", "Relaxed", 1 } }
	self.handHalflife = { Right = 0.045, Left = 0.045 }
	self.handOverride = {} :: { [string]: string }
	self.look = { yaw = 0, pitch = 0, weight = 0 }
	self.lookWeightTarget = 1
	self.parts = {} :: { [string]: CFrame }
	self.masks = {
		RightArm = maskFor(skel, { "RightShoulder", "RightElbow", "RightWrist" }),
		LeftArm = maskFor(skel, { "LeftShoulder", "LeftElbow", "LeftWrist" }),
		UpperBody = maskFor(skel, { "Waist", "Neck", "RightShoulder", "RightElbow", "RightWrist", "LeftShoulder", "LeftElbow", "LeftWrist" }),
	}
	self.motions = {} :: { [string]: any }
	for _, m in MOTIONS:GetChildren() do
		if m:IsA("ModuleScript") then
			local mod = require(m) :: any
			for _, modeName in mod.modes do
				self.motions[modeName] = mod.new(self, modeName)
			end
		end
	end
	self.motion = self.motions.Ground
	return self
end

function AnimController:clip(name: string): Clip.Clip
	local c = self.lib[name]
	assert(c, "missing clip " .. name)
	return c
end

-- Request an inertialized transition this frame (shortest requested half-life wins).
function AnimController:transition(halflife: number)
	if self.pending == nil or halflife < self.pending then
		self.pending = halflife
	end
end

export type PlayOptions = {
	halflife: number?,
	outHalflife: number?,
	rate: number?,
	mode: string?, -- cancel automatically if the state leaves this mode
	interrupt: ((ctx: Context, t: number) -> boolean)?,
	onEnd: (() -> ())?,
	flags: { [string]: boolean }?,
	startAt: number?,
}

-- Plays a full-body one-shot clip, then returns to the current mode's motion.
function AnimController:play(name: string, opts: PlayOptions?)
	local o = opts or {}
	local clip = self:clip(name)
	self.oneShot = {
		clip = clip,
		t = o.startAt or 0,
		rate = o.rate or 1,
		mode = o.mode,
		outHalflife = o.outHalflife or 0.12,
		interrupt = o.interrupt,
		onEnd = o.onEnd,
		flags = o.flags or {},
	}
	self:transition(o.halflife or 0.08)
end

function AnimController:stopOneShot(halflife: number?)
	local os = self.oneShot
	if os then
		self.oneShot = nil
		self:transition(halflife or os.outHalflife)
		if os.onEnd then
			os.onEnd()
		end
	end
end

function AnimController:isPlaying(name: string?): boolean
	local os = self.oneShot
	if not os then
		return false
	end
	return name == nil or os.clip.name == name
end

-- Masked overlay (e.g. an arm firing a web while the body keeps running).
function AnimController:overlay(name: string, maskName: string, opts: { rate: number?, fadeIn: number?, fadeOut: number? }?)
	local o = opts or {}
	table.insert(self.overlays, {
		clip = self:clip(name),
		t = 0,
		rate = o.rate or 1,
		mask = self.masks[maskName],
		fadeIn = o.fadeIn or 0.05,
		fadeOut = o.fadeOut or 0.12,
		weight = 0,
	})
end

function AnimController:setHands(rightPreset: string?, leftPreset: string?)
	if rightPreset then
		self.handTarget.Right = { rightPreset, rightPreset, 1 }
	end
	if leftPreset then
		self.handTarget.Left = { leftPreset, leftPreset, 1 }
	end
end

function AnimController:handsFromClip(clip: Clip.Clip, t: number)
	for _, side in { "Right", "Left" } do
		local a, b, alpha = Clip.handAt(clip, side:sub(1, 1), t)
		if a then
			self.handTarget[side] = { a :: string, b :: string, alpha }
		end
	end
end

function AnimController:emit(name: string)
	table.insert(self.events, name)
end

-- Forwarded gameplay events (Jump, Land, SwingStart, ...): the active motions decide what to do.
function AnimController:event(name: string, data: any?)
	for _, m in self.motions do
		if m.onEvent then
			m:onEvent(name, data)
		end
	end
end

local function enterMode(self: any, mode: string, ctx: Context)
	local nextMotion = self.motions[mode] or self.motions.Ground
	if self.motion and self.motion.exit then
		self.motion:exit(ctx)
	end
	local prevMode = self.mode
	self.mode = mode
	self.motion = nextMotion
	local hl = 0.1
	if nextMotion.enter then
		hl = nextMotion:enter(ctx, prevMode) or hl
	end
	self:transition(hl)
	local os = self.oneShot
	if os and os.mode and os.mode ~= mode then
		self.oneShot = nil
	end
end

-- Head look-at: distributes yaw/pitch between waist and neck, with limits and smoothing.
local function applyLook(self: any, dt: number, ctx: Context, out: { number })
	local target = 0
	local yawT, pitchT = 0, 0
	if ctx.lookDir and ctx.lookDir.Magnitude > 0.1 then
		local l = ctx.rootCF:VectorToObjectSpace(ctx.lookDir.Unit)
		yawT = math.atan2(-l.X, -l.Z)
		pitchT = math.asin(math.clamp(l.Y, -1, 1))
		target = self.lookWeightTarget
		-- looking behind: don't snap the head around, fade out instead
		if math.abs(yawT) > math.rad(115) then
			target *= math.max(0, 1 - (math.abs(yawT) - math.rad(115)) / math.rad(40))
		end
	end
	yawT = math.clamp(yawT, -math.rad(75), math.rad(75))
	pitchT = math.clamp(pitchT, -math.rad(45), math.rad(40))
	self.look.yaw = Spring.damp(self.look.yaw, yawT, 0.09, dt)
	self.look.pitch = Spring.damp(self.look.pitch, pitchT, 0.09, dt)
	self.look.weight = Spring.damp(self.look.weight, target, 0.15, dt)
	local w = self.look.weight
	if w < 0.01 then
		return
	end
	local yaw, pitch = self.look.yaw * w, self.look.pitch * w
	local waist = self.skel.byName.Waist.index
	local neck = self.skel.byName.Neck.index
	-- pre-multiply (parent frame) so the look composes on top of the animated pose
	local qx, qy, qz, qw = Quat.fromEulerXYZ(pitch * 0.25, yaw * 0.3, 0)
	Pose.preRotate(out, waist, qx, qy, qz, qw)
	qx, qy, qz, qw = Quat.fromEulerXYZ(pitch * 0.75, yaw * 0.7, 0)
	Pose.preRotate(out, neck, qx, qy, qz, qw)
end

function AnimController:update(dt: number, ctx: Context): { number }
	dt = math.clamp(dt, 0, 1 / 15)
	self.time += dt
	table.clear(self.events)

	if ctx.state ~= self.mode then
		enterMode(self, ctx.state, ctx)
	end

	-- 1) source pose
	local os = self.oneShot
	if os then
		if (os.mode and os.mode ~= ctx.state) or (os.interrupt and os.interrupt(ctx, os.t)) then
			self:stopOneShot(0.12)
			os = nil
		end
	end
	if os then
		local t0 = os.t
		os.t += dt * os.rate
		Clip.eventsBetween(os.clip, t0, os.t, self.events)
		if os.t >= os.clip.length and not os.clip.loop then
			self.oneShot = nil
			self:transition(os.outHalflife)
			if os.onEnd then
				os.onEnd()
			end
			os = nil
		else
			Clip.sample(os.clip, os.t, self.src, self.count, true, self.skel.scale)
			self:handsFromClip(os.clip, os.t)
			if self.motion.oneShotAdjust then
				self.motion:oneShotAdjust(dt, ctx, self.src, os)
			end
		end
	end
	if not self.oneShot then
		self.motion:update(dt, ctx, self.src)
	end

	-- 2) overlays
	for i = #self.overlays, 1, -1 do
		local ov = self.overlays[i]
		ov.t += dt * ov.rate
		local len = ov.clip.length
		local w = math.min(1, ov.t / math.max(ov.fadeIn, 1e-3))
		if ov.t > len - ov.fadeOut then
			w = math.min(w, math.max(0, (len - ov.t) / ov.fadeOut))
		end
		if ov.t >= len then
			table.remove(self.overlays, i)
		else
			Clip.sample(ov.clip, ov.t, self.tmp, self.count, true, self.skel.scale)
			w = w * w * (3 - 2 * w)
			Pose.blendInto(self.src, self.tmp, w, self.count, ov.mask)
		end
	end

	-- 3) inertialization
	if self.pending then
		self.inert:transition(self.out, self.prevOut, self.lastDt, self.src, self.pending)
		self.pending = nil
	end
	Pose.copy(self.prevOut, self.out, self.count)
	self.inert:apply(dt, self.src, self.out)
	self.lastDt = dt

	-- 4) IK post pass on the final pose
	if self.motion.post then
		self.motion:post(dt, ctx, self.out)
	end

	-- 5) look-at and hands
	applyLook(self, dt, ctx, self.out)
	for _, side in { "Right", "Left" } do
		local ov = self.handOverride[side]
		local tgt = self.handTarget[side]
		if ov then
			HandPoses.step(self.hands[side], side, ov, nil, 1, self.handHalflife[side], dt)
		else
			HandPoses.step(self.hands[side], side, tgt[1], tgt[2], tgt[3], self.handHalflife[side], dt)
		end
		HandPoses.write(self.out, side, self.hands[side])
	end
	return self.out
end

return AnimController
