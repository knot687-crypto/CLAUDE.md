--!nocheck
-- Scripted scenarios for baking previews. Each segment: { duration, fn(sim, dt, localT, entered) }
local S = {}

local function accelerateTo(sim, dt, speed, accel)
	local f = sim.facing()
	local cur = Vector3.new(sim.vel.X, 0, sim.vel.Z)
	local target = f * speed
	local d = target - cur
	local maxStep = accel * dt
	if d.Magnitude > maxStep then
		d = d.Unit * maxStep
	end
	local nv = cur + d
	sim.vel = Vector3.new(nv.X, sim.vel.Y, nv.Z)
	sim.input = if speed > 0.1 then f * math.clamp(speed / 22, 0.2, 1) else Vector3.zero
end

S.ground = {
	segments = {
		{ 2.2, function(sim, dt) accelerateTo(sim, dt, 0, 200) end },
		{ 1.6, function(sim, dt) accelerateTo(sim, dt, 4.6, 40) end },
		{ 1.8, function(sim, dt) accelerateTo(sim, dt, 22, 60) end },
		{ 1.8, function(sim, dt)
			sim.sprint = true
			accelerateTo(sim, dt, 36, 70)
		end },
		{ 1.4, function(sim, dt)
			sim.sprint = false
			sim.input = Vector3.zero
			local cur = Vector3.new(sim.vel.X, 0, sim.vel.Z)
			local nv = cur.Magnitude > 0 and cur.Unit * math.max(0, cur.Magnitude - 55 * dt) or cur
			sim.vel = Vector3.new(nv.X, sim.vel.Y, nv.Z)
		end },
		{ 1.0, function(sim, dt) accelerateTo(sim, dt, 0, 200) end },
		{ 0.9, function(sim, dt, t, entered)
			if entered then
				sim.jump(62, false)
			end
		end },
		{ 1.2, function(sim, dt) accelerateTo(sim, dt, 22, 60) end },
		{ 1.0, function(sim, dt, t, entered)
			accelerateTo(sim, dt, 22, 60)
			sim.yaw += dt * 1.6
		end },
		{ 1.3, function(sim, dt, t, entered)
			if entered then
				sim.jump(70, true)
			end
		end },
		{ 1.2, function(sim, dt) accelerateTo(sim, dt, 0, 120) end },
	},
}

-- Drops from increasing heights: medium (crouch), big (hero landing), big with momentum (roll)
S.landings = {
	segments = {
		{ 0.6, function(sim, dt, t, entered)
			if entered then
				sim.pos = Vector3.new(0, 3.3 + 14, 0)
				sim.state = "Air"
				sim.vel = Vector3.zero
			end
		end },
		{ 2.2, function() end },
		{ 0.4, function(sim, dt, t, entered)
			if entered then
				sim.pos = Vector3.new(sim.pos.X, 3.3 + 60, sim.pos.Z)
				sim.state = "Air"
				sim.vel = Vector3.new(0, -60, 0)
			end
		end },
		{ 2.4, function() end },
		{ 0.4, function(sim, dt, t, entered)
			if entered then
				sim.pos = Vector3.new(sim.pos.X, 3.3 + 40, sim.pos.Z)
				sim.state = "Air"
				sim.vel = sim.facing() * 34 + Vector3.new(0, -80, 0)
			end
		end },
		{ 1.6, function(sim, dt, t)
			if sim.state == "Ground" then
				accelerateTo(sim, dt, 22, 30)
			end
		end },
	},
}

-- Tricks off a high jump, then a long dive
S.tricks = {
	segments = {
		{ 0.3, function(sim, dt, t, entered)
			if entered then
				sim.pos = Vector3.new(0, 3.3, 0)
				sim.jump(95, false)
			end
		end },
		{ 0.25, function(sim, dt, t, entered)
			if entered then
				sim.event("Trick", { name = "FrontFlip" })
			end
		end },
		{ 1.0, function(sim, dt, t, entered)
			if entered then
				sim.event("Trick", { name = "Corkscrew" })
			end
		end },
		{ 0.7, function() end },
		{ 0.3, function(sim, dt, t, entered)
			if entered then
				sim.jump(95, false)
			end
		end },
		{ 0.9, function(sim, dt, t, entered)
			if entered then
				sim.event("Trick", { name = "Backflip" })
			end
		end },
		{ 1.1, function(sim, dt, t, entered)
			if entered then
				sim.event("Trick", { name = "Cartwheel" })
			end
		end },
		{ 0.6, function() end },
		{ 0.3, function(sim, dt, t, entered)
			if entered then
				sim.pos = Vector3.new(sim.pos.X, 3.3 + 200, sim.pos.Z)
				sim.state = "Air"
				sim.vel = sim.facing() * 30 + Vector3.new(0, 20, 0)
				sim.event("Trick", { name = "Swan" })
			end
		end },
		{ 2.6, function() end },
	},
}

-- Web swinging through a chain of anchors with release tricks in between
do
	local RS = game:GetService("ReplicatedStorage")
	local SwingPhysics = require(RS.SpiderKit.Motion.SwingPhysics)
	local swing = nil
	local function faceVelocity(sim, dt)
		local h = Vector3.new(sim.vel.X, 0, sim.vel.Z)
		if h.Magnitude > 2 then
			local want = math.atan2(-h.X, -h.Z)
			local d = (want - sim.yaw + math.pi) % (2 * math.pi) - math.pi
			sim.yaw += d * math.min(1, dt * 10)
		end
	end
	local function attach(sim, side, ahead, up, lateral)
		local f = Vector3.new(sim.vel.X, 0, sim.vel.Z)
		f = f.Magnitude > 1 and f.Unit or sim.facing()
		local right = f:Cross(Vector3.yAxis)
		local anchor = sim.pos + f * ahead + Vector3.new(0, up, 0) + right * (lateral * (side == "Right" and 1 or -1))
		swing = SwingPhysics.attach(anchor, sim.pos)
		sim.anchor = anchor
		sim.swingHand = side
		sim.state = "Swing"
		sim.gravity = false
		sim.event("SwingStart", { hand = side })
	end
	local function swingStep(sim, dt)
		if swing then
			sim.vel = SwingPhysics.step(swing, sim.pos, sim.vel, sim.facing() * 0.6, dt)
			faceVelocity(sim, dt)
		end
	end
	local function release(sim, trick)
		if swing then
			sim.vel = SwingPhysics.releaseVelocity(swing, sim.pos, sim.vel)
		end
		swing = nil
		sim.anchor = nil
		sim.state = "Air"
		sim.gravity = true
		sim.event("SwingRelease", {})
		if trick then
			sim.event("Trick", { name = trick })
		end
	end
	local function swingSeg(side, ahead, up, lateral, duration, trick)
		local released = false
		return {
			{ duration, function(sim, dt, t, entered)
				if entered then
					attach(sim, side, ahead, up, lateral)
					released = false
				end
				if released then
					return
				end
				swingStep(sim, dt)
				-- auto-release once the swing passes ~50 deg beyond the anchor (like the controller)
				if swing and t > 0.4 and SwingPhysics.phase(swing, sim.pos, sim.vel) < -math.rad(50) then
					released = true
					release(sim, trick)
				end
			end },
			{ 0.02, function(sim, dt, t, entered)
				if entered and not released then
					release(sim, trick)
				end
			end },
		}
	end
	local segs = {
		{ 0.5, function(sim, dt, t, entered)
			if entered then
				sim.pos = Vector3.new(0, 140, 0)
				sim.vel = Vector3.new(0, -6, -46)
				sim.state = "Air"
				sim.gravity = true
				sim.yaw = 0
			end
			faceVelocity(sim, dt)
		end },
	}
	local plan = {
		{ "Right", 58, 64, 10, 1.45, "Corkscrew" },
		{ 0.75 },
		{ "Left", 62, 60, 12, 1.4, nil },
		{ 0.35 },
		{ "Right", 60, 62, 10, 1.45, "FrontFlip" },
		{ 0.9 },
		{ "Left", 64, 58, 12, 1.5, "Swan" },
		{ 1.3 },
	}
	for _, p in plan do
		if #p == 1 then
			table.insert(segs, { p[1], function(sim, dt) faceVelocity(sim, dt) end })
		else
			for _, s2 in swingSeg(p[1], p[2], p[3], p[4], p[5], p[6]) do
				table.insert(segs, s2)
			end
		end
	end
	S.swing = { segments = segs }
end

-- Wall crawl: leap onto a wall, cling, crawl up / sideways / diagonally, idle, wall-jump off
do
	local WALL_Z = -2.0
	local DIST = 0.62
	local function crawl(vx, vy)
		return function(sim, dt)
			sim.vel = Vector3.new(vx, vy, 0)
			sim.input = Vector3.new(vx, vy, 0).Magnitude > 0 and Vector3.new(vx, vy, 0).Unit or Vector3.zero
		end
	end
	S.wall = {
		scene = { boxes = { { center = { 0, 30, WALL_Z - 0.5 }, size = { 60, 60, 1 } } } },
		segments = {
			{ 0.55, function(sim, dt, t, entered)
				if entered then
					sim.pos = Vector3.new(0, 3.3, 6)
					sim.yaw = 0
					sim.jump(62, false)
					sim.vel = Vector3.new(0, 62, -14)
				end
			end },
			{ 1.2, function(sim, dt, t, entered)
				if entered then
					sim.state = "WallCrawl"
					sim.gravity = false
					sim.pos = Vector3.new(sim.pos.X, sim.pos.Y, WALL_Z + DIST)
					sim.wallNormal = Vector3.new(0, 0, 1)
				end
				sim.vel = Vector3.zero
				sim.input = Vector3.zero
			end },
			{ 2.0, crawl(0, 4.5) },
			{ 1.6, crawl(4.2, 0) },
			{ 1.3, crawl(-3.0, 3.0) },
			{ 1.4, crawl(0, 0) },
			{ 1.4, function(sim, dt, t, entered)
				if entered then
					sim.state = "Air"
					sim.gravity = true
					sim.vel = Vector3.new(0, 42, 26)
					sim.event("WallJump", {})
				end
			end },
		},
	}
end

return S
