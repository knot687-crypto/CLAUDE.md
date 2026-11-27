--!strict
--[[
	Quat
	----
	Allocation-free quaternion math on plain numbers (x, y, z, w). Used by the animation runtime for
	pose sampling, blending and inertialization. Conventions match Roblox CFrames:
	  fromEulerXYZ(rx, ry, rz) == CFrame.Angles(rx, ry, rz) == Rx * Ry * Rz
]]

local Quat = {}

local sqrt, sin, cos, acos, atan2, abs = math.sqrt, math.sin, math.cos, math.acos, math.atan2, math.abs

function Quat.fromEulerXYZ(rx: number, ry: number, rz: number): (number, number, number, number)
	local hx, hy, hz = rx * 0.5, ry * 0.5, rz * 0.5
	local sx, cx = sin(hx), cos(hx)
	local sy, cy = sin(hy), cos(hy)
	local sz, cz = sin(hz), cos(hz)
	-- qx * qy * qz
	return sx * cy * cz + cx * sy * sz,
		cx * sy * cz - sx * cy * sz,
		cx * cy * sz + sx * sy * cz,
		cx * cy * cz - sx * sy * sz
end

function Quat.mul(ax: number, ay: number, az: number, aw: number, bx: number, by: number, bz: number, bw: number): (number, number, number, number)
	return aw * bx + ax * bw + ay * bz - az * by,
		aw * by - ax * bz + ay * bw + az * bx,
		aw * bz + ax * by - ay * bx + az * bw,
		aw * bw - ax * bx - ay * by - az * bz
end

function Quat.conj(x: number, y: number, z: number, w: number): (number, number, number, number)
	return -x, -y, -z, w
end

function Quat.normalize(x: number, y: number, z: number, w: number): (number, number, number, number)
	local n = sqrt(x * x + y * y + z * z + w * w)
	if n < 1e-12 then
		return 0, 0, 0, 1
	end
	return x / n, y / n, z / n, w / n
end

function Quat.dot(ax: number, ay: number, az: number, aw: number, bx: number, by: number, bz: number, bw: number): number
	return ax * bx + ay * by + az * bz + aw * bw
end

-- Rotate vector v by quaternion q.
function Quat.rotate(qx: number, qy: number, qz: number, qw: number, vx: number, vy: number, vz: number): (number, number, number)
	-- t = 2 * cross(q.xyz, v)
	local tx = 2 * (qy * vz - qz * vy)
	local ty = 2 * (qz * vx - qx * vz)
	local tz = 2 * (qx * vy - qy * vx)
	return vx + qw * tx + (qy * tz - qz * ty),
		vy + qw * ty + (qz * tx - qx * tz),
		vz + qw * tz + (qx * ty - qy * tx)
end

function Quat.fromAxisAngle(ax: number, ay: number, az: number, angle: number): (number, number, number, number)
	local n = sqrt(ax * ax + ay * ay + az * az)
	if n < 1e-12 then
		return 0, 0, 0, 1
	end
	local s = sin(angle * 0.5) / n
	return ax * s, ay * s, az * s, cos(angle * 0.5)
end

-- Rotation vector (axis * angle) -> quaternion
function Quat.exp(vx: number, vy: number, vz: number): (number, number, number, number)
	local angle = sqrt(vx * vx + vy * vy + vz * vz)
	if angle < 1e-9 then
		return vx * 0.5, vy * 0.5, vz * 0.5, 1
	end
	local s = sin(angle * 0.5) / angle
	return vx * s, vy * s, vz * s, cos(angle * 0.5)
end

-- Quaternion -> rotation vector (shortest arc)
function Quat.log(x: number, y: number, z: number, w: number): (number, number, number)
	if w < 0 then
		x, y, z, w = -x, -y, -z, -w
	end
	local s = sqrt(x * x + y * y + z * z)
	if s < 1e-9 then
		return x * 2, y * 2, z * 2
	end
	local angle = 2 * atan2(s, w)
	local k = angle / s
	return x * k, y * k, z * k
end

function Quat.slerp(ax: number, ay: number, az: number, aw: number, bx: number, by: number, bz: number, bw: number, t: number): (number, number, number, number)
	local d = ax * bx + ay * by + az * bz + aw * bw
	if d < 0 then
		bx, by, bz, bw, d = -bx, -by, -bz, -bw, -d
	end
	if d > 0.9995 then
		return Quat.normalize(ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t, aw + (bw - aw) * t)
	end
	local th = acos(d)
	local s = sin(th)
	local wa, wb = sin((1 - t) * th) / s, sin(t * th) / s
	return ax * wa + bx * wb, ay * wa + by * wb, az * wa + bz * wb, aw * wa + bw * wb
end

function Quat.nlerp(ax: number, ay: number, az: number, aw: number, bx: number, by: number, bz: number, bw: number, t: number): (number, number, number, number)
	if ax * bx + ay * by + az * bz + aw * bw < 0 then
		bx, by, bz, bw = -bx, -by, -bz, -bw
	end
	return Quat.normalize(ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t, aw + (bw - aw) * t)
end

-- Shortest rotation taking unit vector u onto unit vector v.
function Quat.fromTo(ux: number, uy: number, uz: number, vx: number, vy: number, vz: number): (number, number, number, number)
	local d = ux * vx + uy * vy + uz * vz
	if d < -0.999999 then
		-- 180 degrees: any perpendicular axis
		local ax, ay, az = 0, -uz, uy
		if ax * ax + ay * ay + az * az < 1e-6 then
			ax, ay, az = uz, 0, -ux
		end
		return Quat.fromAxisAngle(ax, ay, az, math.pi)
	end
	local cx, cy, cz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
	return Quat.normalize(cx, cy, cz, 1 + d)
end

-- Matrix (row-major rotation) -> quaternion
function Quat.fromMatrix(r00: number, r01: number, r02: number, r10: number, r11: number, r12: number, r20: number, r21: number, r22: number): (number, number, number, number)
	local trace = r00 + r11 + r22
	if trace > 0 then
		local s = sqrt(trace + 1) * 2
		return (r21 - r12) / s, (r02 - r20) / s, (r10 - r01) / s, 0.25 * s
	elseif r00 > r11 and r00 > r22 then
		local s = sqrt(1 + r00 - r11 - r22) * 2
		return 0.25 * s, (r01 + r10) / s, (r02 + r20) / s, (r21 - r12) / s
	elseif r11 > r22 then
		local s = sqrt(1 + r11 - r00 - r22) * 2
		return (r01 + r10) / s, 0.25 * s, (r12 + r21) / s, (r02 - r20) / s
	end
	local s = sqrt(1 + r22 - r00 - r11) * 2
	return (r02 + r20) / s, (r12 + r21) / s, 0.25 * s, (r10 - r01) / s
end

function Quat.fromCFrame(cf: CFrame): (number, number, number, number)
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	return Quat.fromMatrix(r00, r01, r02, r10, r11, r12, r20, r21, r22)
end

function Quat.toCFrame(px: number, py: number, pz: number, qx: number, qy: number, qz: number, qw: number): CFrame
	return CFrame.new(px, py, pz, qx, qy, qz, qw)
end

-- Euler XYZ decomposition (inverse of fromEulerXYZ), for debugging/tests.
function Quat.toEulerXYZ(x: number, y: number, z: number, w: number): (number, number, number)
	local r00 = 1 - 2 * (y * y + z * z)
	local r01 = 2 * (x * y - z * w)
	local r02 = 2 * (x * z + y * w)
	local r12 = 2 * (y * z - x * w)
	local r22 = 1 - 2 * (x * x + y * y)
	local ry = math.asin(math.clamp(r02, -1, 1))
	return atan2(-r12, r22), ry, atan2(-r01, r00)
end

-- Angle (radians) of the rotation between two quaternions.
function Quat.angleBetween(ax: number, ay: number, az: number, aw: number, bx: number, by: number, bz: number, bw: number): number
	local d = abs(ax * bx + ay * by + az * bz + aw * bw)
	return 2 * acos(math.min(1, d))
end

return Quat
