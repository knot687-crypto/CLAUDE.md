--!strict
--[[
	SwingPhysics
	------------
	Pure web-swing integrator shared by the controller (in game) and the offline preview simulator.

	A gamified pendulum: an inelastic rope (slack allowed when moving toward the anchor), swing
	gravity that is a little stronger than world gravity for snappy arcs, a tangential "pump" while
	falling through the arc, steering of the swing plane toward player input, a gentle reel-in that
	tightens long arcs, air drag and a speed cap.
]]

export type Params = {
	gravity: number,
	gravityScale: number,
	pump: number, -- tangential acceleration on the downswing (studs/s^2)
	inputPush: number, -- acceleration toward the input direction (studs/s^2)
	steerRate: number, -- radians/s the horizontal velocity can turn toward input
	reel: number, -- rope shortening (studs/s) while below the anchor
	minLength: number,
	drag: number, -- per-second velocity damping
	maxSpeed: number,
}

export type State = {
	anchor: Vector3,
	length: number,
	t: number,
}

local SwingPhysics = {}

SwingPhysics.Defaults = {
	gravity = 196.2,
	gravityScale = 1.18,
	pump = 70,
	inputPush = 40,
	steerRate = 1.6,
	reel = 4,
	minLength = 18,
	drag = 0.12,
	maxSpeed = 165,
} :: Params

-- Creates a swing state for a web attached at `anchor` while the character is at `pos`.
function SwingPhysics.attach(anchor: Vector3, pos: Vector3): State
	return { anchor = anchor, length = (anchor - pos).Magnitude, t = 0 }
end

--[[ Advances the swing one step. Returns the new velocity (the caller moves the body, so physics
	 collisions still apply in game). `input` is the desired horizontal direction (0..1 magnitude). ]]
function SwingPhysics.step(state: State, pos: Vector3, vel: Vector3, input: Vector3, dt: number, params: Params?): Vector3
	local p = params or SwingPhysics.Defaults
	state.t += dt
	local toBody = pos - state.anchor
	local dist = toBody.Magnitude
	local n = if dist > 1e-4 then toBody / dist else Vector3.new(0, -1, 0)

	-- gravity
	vel += Vector3.new(0, -p.gravity * p.gravityScale * dt, 0)

	-- tangential direction of travel
	local tangent = vel - n * vel:Dot(n)
	local tMag = tangent.Magnitude
	local tHat = if tMag > 1e-3 then tangent / tMag else Vector3.zero

	-- pump: extra push while falling through the arc (below the anchor, moving down)
	local below = math.clamp(-n.Y, 0, 1)
	if vel.Y < 0 and tMag > 1e-3 then
		vel += tHat * (p.pump * below * dt)
	end

	-- input: push along the input (projected onto the swing tangent plane) and steer the plane
	if input.Magnitude > 0.05 then
		local inDir = input.Unit
		local inPlane = inDir - n * inDir:Dot(n)
		if inPlane.Magnitude > 1e-3 then
			vel += inPlane.Unit * (p.inputPush * input.Magnitude * dt)
		end
		local h = Vector3.new(vel.X, 0, vel.Z)
		local hMag = h.Magnitude
		if hMag > 1 then
			local cur = math.atan2(h.X, h.Z)
			local want = math.atan2(inDir.X, inDir.Z)
			local d = (want - cur + math.pi) % (2 * math.pi) - math.pi
			local turn = math.clamp(d, -p.steerRate * dt, p.steerRate * dt)
			local nh = cur + turn
			vel = Vector3.new(math.sin(nh) * hMag, vel.Y, math.cos(nh) * hMag)
		end
	end

	-- reel in while hanging below the anchor (tightens and speeds up the arc)
	if below > 0.3 then
		state.length = math.max(p.minLength, state.length - p.reel * below * dt)
	end

	-- inelastic rope: remove outward radial velocity, and pull back any stretch
	local predicted = pos + vel * dt
	local pd = predicted - state.anchor
	if pd.Magnitude > state.length then
		local radial = vel:Dot(n)
		if radial > 0 then
			vel -= n * radial
		end
		local stretch = dist - state.length
		if stretch > 0 then
			vel -= n * (stretch / math.max(dt, 1e-3)) * 0.45
		end
	end

	-- drag and speed cap
	vel *= math.max(0, 1 - p.drag * dt)
	local sp = vel.Magnitude
	if sp > p.maxSpeed then
		vel *= p.maxSpeed / sp
	end
	return vel
end

-- Signed swing angle (radians): + while the anchor is still ahead (descending into the arc),
-- - once the body has passed under it (rising toward release).
function SwingPhysics.phase(state: State, pos: Vector3, vel: Vector3): number
	local r = state.anchor - pos
	local h = Vector3.new(vel.X, 0, vel.Z)
	if h.Magnitude < 1e-3 then
		return 0
	end
	local fwd = h.Unit
	return math.atan2(r:Dot(fwd), math.max(r.Y, 0.05))
end

-- Release boost: converts momentum into a satisfying launch (more up when released on the rise).
function SwingPhysics.releaseVelocity(state: State, pos: Vector3, vel: Vector3): Vector3
	local phase = SwingPhysics.phase(state, pos, vel)
	local rising = math.clamp(-phase / math.rad(50), 0, 1)
	local h = Vector3.new(vel.X, 0, vel.Z)
	local up = 18 + 26 * rising
	local fwd = if h.Magnitude > 1e-3 then h.Unit * (8 + 10 * rising) else Vector3.zero
	return vel + Vector3.new(0, up, 0) + fwd
end

return SwingPhysics
