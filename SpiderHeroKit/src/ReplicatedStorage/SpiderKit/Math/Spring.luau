--!strict
--[[
	Spring
	------
	Frame-rate independent damping helpers (exact solutions, stable at any dt).
	Parameterized by half-life: the time for the remaining distance to halve.
]]

local Spring = {}

local LN2 = 0.69314718056
local exp = math.exp

local function fastNegExp(x: number): number
	return exp(-x)
end

-- Exponential smoothing toward a target (no velocity).
function Spring.damp(current: number, target: number, halflife: number, dt: number): number
	if halflife <= 0 then
		return target
	end
	return target + (current - target) * fastNegExp(LN2 * dt / halflife)
end

function Spring.dampVector(current: Vector3, target: Vector3, halflife: number, dt: number): Vector3
	if halflife <= 0 then
		return target
	end
	return target + (current - target) * fastNegExp(LN2 * dt / halflife)
end

function Spring.dampAngle(current: number, target: number, halflife: number, dt: number): number
	local d = (target - current + math.pi) % (2 * math.pi) - math.pi
	return Spring.damp(current, current + d, halflife, dt)
end

-- Damping factor from half-life (critical damping: damping = 4 ln2 / halflife).
function Spring.halflifeToDamping(halflife: number): number
	return (4 * LN2) / (halflife + 1e-5)
end

--[[ Critically damped spring toward a target. Returns (x, v). Good for secondary motion that
	 should overshoot-free follow a target while carrying velocity. ]]
function Spring.critical(x: number, v: number, target: number, halflife: number, dt: number): (number, number)
	local y = Spring.halflifeToDamping(halflife) / 2
	local j0 = x - target
	local j1 = v + j0 * y
	local eydt = fastNegExp(y * dt)
	return eydt * (j0 + j1 * dt) + target, eydt * (v - j1 * y * dt)
end

-- Same as critical, but decaying toward zero (used for inertialization offsets).
function Spring.decay(x: number, v: number, halflife: number, dt: number): (number, number)
	local y = Spring.halflifeToDamping(halflife) / 2
	local j1 = v + x * y
	local eydt = fastNegExp(y * dt)
	return eydt * (x + j1 * dt), eydt * (v - j1 * y * dt)
end

--[[ Under-damped spring (with overshoot), parameterized by frequency (Hz) and damping ratio.
	 Used for bouncy secondary motion such as a limb settling after an impact. ]]
function Spring.underdamped(x: number, v: number, target: number, frequency: number, ratio: number, dt: number): (number, number)
	-- semi-implicit integration with substeps for stability
	local omega = 2 * math.pi * frequency
	local steps = math.max(1, math.ceil(dt / (1 / 240)))
	local h = dt / steps
	for _ = 1, steps do
		local a = -omega * omega * (x - target) - 2 * ratio * omega * v
		v += a * h
		x += v * h
	end
	return x, v
end

--[[ Stateful critically damped Vector3 spring. ]]
export type VSpring = { x: Vector3, v: Vector3, halflife: number }

function Spring.newV(x: Vector3?, halflife: number?): VSpring
	return { x = x or Vector3.zero, v = Vector3.zero, halflife = halflife or 0.1 }
end

function Spring.stepV(s: VSpring, target: Vector3, dt: number): Vector3
	local y = Spring.halflifeToDamping(s.halflife) / 2
	local j0 = s.x - target
	local j1 = s.v + j0 * y
	local eydt = fastNegExp(y * dt)
	s.x = (j0 + j1 * dt) * eydt + target
	s.v = (s.v - j1 * (y * dt)) * eydt
	return s.x
end

return Spring
