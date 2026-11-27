--!strict
--[[
	Inertializer
	------------
	Spring-based inertialization (the transition technique used by modern AAA animation systems).
	Instead of cross-fading two animations, a transition records the offset between the last output
	pose and the new source pose (plus the output's velocity) and then decays that offset to zero
	with a critically damped spring. The result is continuous in pose AND velocity, costs one pose
	evaluation, and never produces the "mushy" double-exposure look of long crossfades.

	Offsets are rotation vectors in each joint's parent frame: output = exp(offset) * source.
]]

local Quat = require(script.Parent.Parent.Math.Quat)
local Spring = require(script.Parent.Parent.Math.Spring)

export type Inertializer = {
	count: number,
	off: { number }, -- 3 per joint (rotation vector)
	vel: { number }, -- 3 per joint
	poff: { number }, -- 3 per joint (translation)
	pvel: { number },
	halflife: number,
	active: boolean,
}

local Inertializer = {}
Inertializer.__index = Inertializer

function Inertializer.new(count: number): Inertializer
	return setmetatable({
		count = count,
		off = table.create(count * 3, 0),
		vel = table.create(count * 3, 0),
		poff = table.create(count * 3, 0),
		pvel = table.create(count * 3, 0),
		halflife = 0.1,
		active = false,
	}, Inertializer) :: any
end

--[[ Starts (or re-targets) a transition.
	 prev:      the last output pose (what the character currently shows)
	 prevPrev:  the output pose before that (for velocity), dtPrev its time step
	 src:       the new source pose for this frame
	 velocityCarry: fraction of the output velocity to keep (0..1). ]]
function Inertializer.transition(self: Inertializer, prev: { number }, prevPrev: { number }, dtPrev: number, src: { number }, halflife: number, velocityCarry: number?)
	local carry = velocityCarry or 0.6
	local inv = if dtPrev > 1e-5 then 1 / dtPrev else 0
	for j = 0, self.count - 1 do
		local o = j * 7
		local p3 = j * 3
		-- rotation offset: prev = off * src  =>  off = prev * conj(src)
		local ox, oy, oz, ow = Quat.mul(prev[o + 1], prev[o + 2], prev[o + 3], prev[o + 4], -src[o + 1], -src[o + 2], -src[o + 3], src[o + 4])
		local rx, ry, rz = Quat.log(ox, oy, oz, ow)
		self.off[p3 + 1], self.off[p3 + 2], self.off[p3 + 3] = rx, ry, rz
		-- angular velocity of the output (parent frame): log(prev * conj(prevPrev)) / dt
		local dx, dy, dz, dw = Quat.mul(prev[o + 1], prev[o + 2], prev[o + 3], prev[o + 4], -prevPrev[o + 1], -prevPrev[o + 2], -prevPrev[o + 3], prevPrev[o + 4])
		local wx, wy, wz = Quat.log(dx, dy, dz, dw)
		self.vel[p3 + 1], self.vel[p3 + 2], self.vel[p3 + 3] = wx * inv * carry, wy * inv * carry, wz * inv * carry
		-- translation
		self.poff[p3 + 1] = prev[o + 5] - src[o + 5]
		self.poff[p3 + 2] = prev[o + 6] - src[o + 6]
		self.poff[p3 + 3] = prev[o + 7] - src[o + 7]
		self.pvel[p3 + 1] = (prev[o + 5] - prevPrev[o + 5]) * inv * carry
		self.pvel[p3 + 2] = (prev[o + 6] - prevPrev[o + 6]) * inv * carry
		self.pvel[p3 + 3] = (prev[o + 7] - prevPrev[o + 7]) * inv * carry
	end
	self.halflife = halflife
	self.active = true
end

-- Decays offsets by dt and writes out = offset * src.
function Inertializer.apply(self: Inertializer, dt: number, src: { number }, out: { number })
	if not self.active then
		for i = 1, self.count * 7 do
			out[i] = src[i]
		end
		return
	end
	local hl = self.halflife
	local maxOff = 0
	for j = 0, self.count - 1 do
		local o = j * 7
		local p3 = j * 3
		for c = 1, 3 do
			local x, v = Spring.decay(self.off[p3 + c], self.vel[p3 + c], hl, dt)
			self.off[p3 + c], self.vel[p3 + c] = x, v
			if math.abs(x) > maxOff then
				maxOff = math.abs(x)
			end
			local px, pv = Spring.decay(self.poff[p3 + c], self.pvel[p3 + c], hl, dt)
			self.poff[p3 + c], self.pvel[p3 + c] = px, pv
		end
		local qx, qy, qz, qw = Quat.exp(self.off[p3 + 1], self.off[p3 + 2], self.off[p3 + 3])
		local x, y, z, w = Quat.mul(qx, qy, qz, qw, src[o + 1], src[o + 2], src[o + 3], src[o + 4])
		out[o + 1], out[o + 2], out[o + 3], out[o + 4] = x, y, z, w
		out[o + 5] = src[o + 5] + self.poff[p3 + 1]
		out[o + 6] = src[o + 6] + self.poff[p3 + 2]
		out[o + 7] = src[o + 7] + self.poff[p3 + 3]
	end
	if maxOff < 1e-4 then
		self.active = false
	end
end

return Inertializer
