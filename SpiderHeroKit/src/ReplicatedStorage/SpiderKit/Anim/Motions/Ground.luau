--!strict
--[[
	Ground motion: idle / walk / run / sprint with
	  * phase-synchronized blending (all gait cycles start at right-foot contact) and stride
	    matching, so the cadence follows the real ground speed
	  * turn banking and acceleration lean (critically damped springs)
	  * spring-driven landing dip layered on top of locomotion (no stop-and-go landing)
	  * idle breaks after standing still, sprint skid-stop, foot IK post pass
]]

local Pose = require(script.Parent.Parent.Pose)
local Clip = require(script.Parent.Parent.Clip)
local FootIK = require(script.Parent.Parent.FootIK)
local Quat = require(script.Parent.Parent.Parent.Math.Quat)
local Spring = require(script.Parent.Parent.Parent.Math.Spring)

local Ground = {}
Ground.__index = Ground
Ground.modes = { "Ground" }

local BREAKS = { "IdleLook", "IdleStretch", "IdleShooter" }

local function smoothstep(a: number, b: number, x: number): number
	local t = math.clamp((x - a) / (b - a), 0, 1)
	return t * t * (3 - 2 * t)
end

function Ground.new(ac: any, _mode: string)
	local self = setmetatable({}, Ground)
	self.ac = ac
	self.phase = 0
	self.speed = 0
	self.idleClock = 0
	self.stillTime = 0
	self.nextBreak = 9
	self.breakIndex = 0
	self.roll, self.rollV = 0, 0
	self.pitch, self.pitchV = 0, 0
	self.prevVel = Vector3.zero
	self.prevYaw = nil :: number?
	self.dip, self.dipV = 0, 0
	self.prevInput = 0
	self.footIK = FootIK.new(ac)
	self.a = Pose.new(ac.count)
	self.b = Pose.new(ac.count)
	self.w = { Walk = 0, Run = 0, Sprint = 0 }
	return self
end

function Ground:enter(ctx: any, prevMode: string): number
	self.footIK:reset()
	self.prevYaw = nil
	self.stillTime = 0
	self.speed = Vector3.new(ctx.velocity.X, 0, ctx.velocity.Z).Magnitude
	if prevMode == "Air" or prevMode == "Swing" or prevMode == "Zip" then
		return 0.07
	end
	return 0.12
end

function Ground:onEvent(name: string, data: any?)
	local ac = self.ac
	if name == "Land" then
		local d = data or {}
		local impact: number = d.impact or 0
		local horizontal: number = d.horizontal or 0
		if impact > 120 and horizontal < 26 then
			ac:play("LandHero", {
				mode = "Ground",
				halflife = 0.03,
				outHalflife = 0.22,
				interrupt = function(ctx, t)
					return t > 0.55 and ctx.moveDir.Magnitude > 0.2
				end,
			})
		elseif impact > 85 and horizontal >= 26 then
			ac:play("LandRoll", { mode = "Ground", halflife = 0.04, outHalflife = 0.12 })
		elseif impact > 60 and horizontal < 12 then
			ac:play("LandCrouch", {
				mode = "Ground",
				halflife = 0.03,
				outHalflife = 0.16,
				interrupt = function(ctx, t)
					return t > 0.22 and ctx.moveDir.Magnitude > 0.2
				end,
			})
		else
			-- additive dip: impulse on the dip spring (scaled by impact)
			self.dipV = -math.clamp(impact * 0.045, 0.4, 3.2)
		end
	elseif name == "Jump" then
		-- handled by the Air motion
	end
end

function Ground:update(dt: number, ctx: any, out: { number })
	local ac = self.ac
	local count = ac.count
	local lib = ac.lib
	local rootCF: CFrame = ctx.rootCF
	local vel: Vector3 = ctx.velocity
	local lv = rootCF:VectorToObjectSpace(vel)
	local hs = math.sqrt(lv.X * lv.X + lv.Z * lv.Z)
	self.speed = Spring.damp(self.speed, hs, 0.05, dt)
	local s = self.speed
	local input = ctx.moveDir.Magnitude

	local walk, run, sprint = lib.Walk, lib.Run, lib.Sprint
	local vW, vR, vS = walk.speed, run.speed, sprint.speed

	-- speed-space weights
	local wW, wR, wS = 1, 0, 0
	if s > vS then
		wW, wR, wS = 0, 0, 1
	elseif s > vR then
		local t = smoothstep(vR, vS, s)
		wW, wR, wS = 0, 1 - t, t
	elseif s > vW then
		local t = smoothstep(vW, vR, s)
		wW, wR, wS = 1 - t, t, 0
	end
	local wMove = smoothstep(0.35, 2.4, s)
	local wIdle = 1 - wMove

	-- stride-matched cycle duration
	local stride = wW * vW * walk.length + wR * vR * run.length + wS * vS * sprint.length
	local effSpeed = math.max(s, vW * 0.55)
	local cycle = stride / effSpeed
	local p0 = self.phase
	if wMove > 0.001 then
		if self.w.Walk + self.w.Run + self.w.Sprint < 0.01 then
			self.phase = 0.02 -- start moving from a right-foot contact
			p0 = self.phase
		end
		self.phase = (self.phase + dt / cycle) % 1
	end
	self.w.Walk, self.w.Run, self.w.Sprint = wW * wMove, wR * wMove, wS * wMove

	-- locomotion blend (normalized running weights so any number of clips blend evenly)
	local dominant: Clip.Clip = walk
	local domW = -1
	local acc = 0
	for _, entry in { { walk, wW }, { run, wR }, { sprint, wS } } do
		local clip, w = entry[1], entry[2]
		if w > 0.001 then
			Clip.sample(clip, self.phase * clip.length, self.a, count, true, ac.skel.scale)
			if acc == 0 then
				Pose.copy(self.b, self.a, count)
			else
				Pose.blendInto(self.b, self.a, w / (acc + w), count)
			end
			acc += w
			if w > domW then
				dominant, domW = clip, w
			end
		end
	end

	-- idle
	if wIdle > 0.001 then
		self.idleClock += dt
		local idle = lib.Idle
		Clip.sample(idle, self.idleClock, out, count, true, ac.skel.scale)
		if wMove > 0.001 then
			Pose.blendInto(out, self.b, wMove, count)
		end
	else
		Pose.copy(out, self.b, count)
	end

	-- footstep events from the dominant gait
	if wMove > 0.3 then
		local t0 = p0 * dominant.length
		local t1 = t0 + (dt / cycle) * dominant.length
		Clip.eventsBetween(dominant, t0, t1, ac.events)
	end

	-- hands
	if wIdle > 0.6 then
		ac:handsFromClip(lib.Idle, self.idleClock)
	else
		ac:handsFromClip(dominant, self.phase * dominant.length)
	end

	-- lean: bank into turns, pitch with acceleration
	local look = rootCF.LookVector
	local yaw = math.atan2(-look.X, -look.Z)
	local yawRate = 0
	if self.prevYaw then
		local d = (yaw - self.prevYaw + math.pi) % (2 * math.pi) - math.pi
		yawRate = d / math.max(dt, 1e-4)
	end
	self.prevYaw = yaw
	local accel = (vel - self.prevVel) / math.max(dt, 1e-4)
	self.prevVel = vel
	local la = rootCF:VectorToObjectSpace(accel)
	local rollT = math.clamp(yawRate * s * 0.011, -0.36, 0.36) * wMove
	local pitchT = math.clamp(la.Z * 0.0035, -0.16, 0.2) * wMove -- accelerating forward (-Z) leans forward (-X)
	self.roll, self.rollV = Spring.critical(self.roll, self.rollV, rollT, 0.09, dt)
	self.pitch, self.pitchV = Spring.critical(self.pitch, self.pitchV, pitchT, 0.12, dt)

	-- landing dip (under-damped for a little rebound)
	self.dip, self.dipV = Spring.underdamped(self.dip, self.dipV, 0, 2.4, 0.62, dt)

	local root = ac.skel.byName.Root.index
	local qx, qy, qz, qw = Quat.fromEulerXYZ(self.pitch + self.dip * 0.12, 0, self.roll)
	Pose.preRotate(out, root, qx, qy, qz, qw)
	local o = (root - 1) * 7
	out[o + 6] += self.dip * 0.42 * ac.skel.scale
	if math.abs(self.dip) > 0.01 then
		-- arms come forward a touch to balance the impact
		local d = math.clamp(-self.dip, 0, 1.5)
		local ax, ay, az, aw = Quat.fromEulerXYZ(d * 0.22, 0, d * 0.12)
		Pose.postRotate(out, ac.skel.byName.RightShoulder.index, ax, ay, az, aw)
		ax, ay, az, aw = Quat.fromEulerXYZ(d * 0.22, 0, -d * 0.12)
		Pose.postRotate(out, ac.skel.byName.LeftShoulder.index, ax, ay, az, aw)
		ax, ay, az, aw = Quat.fromEulerXYZ(-d * 0.14, 0, 0)
		Pose.postRotate(out, ac.skel.byName.Waist.index, ax, ay, az, aw)
	end

	-- skid stop: input released while sprinting
	if input < 0.05 and self.prevInput > 0.3 and s > 25 and not ac:isPlaying() then
		ac:play("SprintStop", {
			mode = "Ground",
			halflife = 0.07,
			outHalflife = 0.2,
			interrupt = function(c, t)
				return t > 0.3 and c.moveDir.Magnitude > 0.2
			end,
		})
	end
	self.prevInput = input

	-- idle breaks
	if s < 0.4 and input < 0.05 then
		self.stillTime += dt
		if self.stillTime > self.nextBreak and not ac:isPlaying() then
			self.breakIndex = (self.breakIndex % #BREAKS) + 1
			self.stillTime = 0
			self.nextBreak = 10 + ((self.breakIndex * 3.7) % 6)
			ac:play(BREAKS[self.breakIndex], {
				mode = "Ground",
				halflife = 0.3,
				outHalflife = 0.35,
				interrupt = function(c)
					return c.moveDir.Magnitude > 0.1
				end,
			})
		end
	else
		self.stillTime = 0
	end
end

function Ground:oneShotAdjust(dt: number, ctx: any, out: { number }, os: any)
	-- keep the landing dip spring settling under one-shots too
	self.dip, self.dipV = Spring.underdamped(self.dip, self.dipV, 0, 2.4, 0.62, dt)
end

function Ground:post(dt: number, ctx: any, out: { number })
	local ac = self.ac
	local os = ac.oneShot
	if os and (os.flags.noFootIK or os.clip.meta.noFootIK) then
		self.footIK:reset()
		return
	end
	self.footIK:apply(dt, ctx, out, { lock = true })
end

return Ground
