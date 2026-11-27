--!nocheck
-- Table-based CFrame shim matching Roblox semantics (right-handed, Y up, LookVector = -Z column).
-- Internal layout: m = {x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22} (row-major rotation).

local Vector3 = require("Vector3")
local V3 = Vector3.new

local CFrame = {}
local C = {}

local function make(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
	return setmetatable({ m = { x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 }, __isCFrame = true }, C)
end

local function quatToMatrix(qx, qy, qz, qw)
	local n = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
	if n == 0 then
		return 1, 0, 0, 0, 1, 0, 0, 0, 1
	end
	qx, qy, qz, qw = qx / n, qy / n, qz / n, qw / n
	return 1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qz * qw), 2 * (qx * qz + qy * qw),
		2 * (qx * qy + qz * qw), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qx * qw),
		2 * (qx * qz - qy * qw), 2 * (qy * qz + qx * qw), 1 - 2 * (qx * qx + qy * qy)
end

local function matrixToQuat(r00, r01, r02, r10, r11, r12, r20, r21, r22)
	local trace = r00 + r11 + r22
	local qx, qy, qz, qw
	if trace > 0 then
		local s = math.sqrt(trace + 1) * 2
		qw = 0.25 * s
		qx = (r21 - r12) / s
		qy = (r02 - r20) / s
		qz = (r10 - r01) / s
	elseif r00 > r11 and r00 > r22 then
		local s = math.sqrt(1 + r00 - r11 - r22) * 2
		qw = (r21 - r12) / s
		qx = 0.25 * s
		qy = (r01 + r10) / s
		qz = (r02 + r20) / s
	elseif r11 > r22 then
		local s = math.sqrt(1 + r11 - r00 - r22) * 2
		qw = (r02 - r20) / s
		qx = (r01 + r10) / s
		qy = 0.25 * s
		qz = (r12 + r21) / s
	else
		local s = math.sqrt(1 + r22 - r00 - r11) * 2
		qw = (r10 - r01) / s
		qx = (r02 + r20) / s
		qy = (r12 + r21) / s
		qz = 0.25 * s
	end
	return qx, qy, qz, qw
end
CFrame.__matrixToQuat = matrixToQuat
CFrame.__quatToMatrix = quatToMatrix

local function matmul3(a00, a01, a02, a10, a11, a12, a20, a21, a22, b00, b01, b02, b10, b11, b12, b20, b21, b22)
	return a00 * b00 + a01 * b10 + a02 * b20, a00 * b01 + a01 * b11 + a02 * b21, a00 * b02 + a01 * b12 + a02 * b22,
		a10 * b00 + a11 * b10 + a12 * b20, a10 * b01 + a11 * b11 + a12 * b21, a10 * b02 + a11 * b12 + a12 * b22,
		a20 * b00 + a21 * b10 + a22 * b20, a20 * b01 + a21 * b11 + a22 * b21, a20 * b02 + a21 * b12 + a22 * b22
end

local function rotX(a)
	local c, s = math.cos(a), math.sin(a)
	return 1, 0, 0, 0, c, -s, 0, s, c
end
local function rotY(a)
	local c, s = math.cos(a), math.sin(a)
	return c, 0, s, 0, 1, 0, -s, 0, c
end
local function rotZ(a)
	local c, s = math.cos(a), math.sin(a)
	return c, -s, 0, s, c, 0, 0, 0, 1
end

local function isV3(v)
	return type(v) == "table" and rawget(v, "__isVector3") == true
end

function CFrame.new(...)
	local n = select("#", ...)
	local a = { ... }
	if n == 0 then
		return make(0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1)
	elseif n == 1 then
		local p = a[1]
		return make(p.X, p.Y, p.Z, 1, 0, 0, 0, 1, 0, 0, 0, 1)
	elseif n == 2 and isV3(a[1]) then
		return CFrame.lookAt(a[1], a[2])
	elseif n == 3 then
		return make(a[1], a[2], a[3], 1, 0, 0, 0, 1, 0, 0, 0, 1)
	elseif n == 7 then
		local r00, r01, r02, r10, r11, r12, r20, r21, r22 = quatToMatrix(a[4], a[5], a[6], a[7])
		return make(a[1], a[2], a[3], r00, r01, r02, r10, r11, r12, r20, r21, r22)
	elseif n == 12 then
		return make(a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12])
	end
	error("CFrame.new: unsupported argument count " .. n, 2)
end

function CFrame.lookAt(at, target, up)
	up = up or Vector3.yAxis
	local f = (target - at)
	if f.Magnitude < 1e-9 then
		return make(at.X, at.Y, at.Z, 1, 0, 0, 0, 1, 0, 0, 0, 1)
	end
	f = f.Unit
	local r = f:Cross(up)
	if r.Magnitude < 1e-6 then
		-- forward parallel to up; pick an arbitrary perpendicular axis like Roblox does
		r = f:Cross(Vector3.zAxis)
		if r.Magnitude < 1e-6 then
			r = f:Cross(Vector3.xAxis)
		end
	end
	r = r.Unit
	local u = r:Cross(f)
	return make(at.X, at.Y, at.Z, r.X, u.X, -f.X, r.Y, u.Y, -f.Y, r.Z, u.Z, -f.Z)
end

function CFrame.fromMatrix(pos, vX, vY, vZ)
	if vZ == nil then
		vZ = vX:Cross(vY).Unit
	end
	return make(pos.X, pos.Y, pos.Z, vX.X, vY.X, vZ.X, vX.Y, vY.Y, vZ.Y, vX.Z, vY.Z, vZ.Z)
end

function CFrame.Angles(rx, ry, rz)
	-- Roblox: CFrame.Angles(rx, ry, rz) == Rx * Ry * Rz
	local x00, x01, x02, x10, x11, x12, x20, x21, x22 = rotX(rx)
	local y00, y01, y02, y10, y11, y12, y20, y21, y22 = rotY(ry)
	local z00, z01, z02, z10, z11, z12, z20, z21, z22 = rotZ(rz)
	local a00, a01, a02, a10, a11, a12, a20, a21, a22 =
		matmul3(x00, x01, x02, x10, x11, x12, x20, x21, x22, y00, y01, y02, y10, y11, y12, y20, y21, y22)
	local r00, r01, r02, r10, r11, r12, r20, r21, r22 =
		matmul3(a00, a01, a02, a10, a11, a12, a20, a21, a22, z00, z01, z02, z10, z11, z12, z20, z21, z22)
	return make(0, 0, 0, r00, r01, r02, r10, r11, r12, r20, r21, r22)
end
CFrame.fromEulerAnglesXYZ = CFrame.Angles

function CFrame.fromEulerAnglesYXZ(rx, ry, rz)
	return CFrame.Angles(0, ry, 0) * CFrame.Angles(rx, 0, 0) * CFrame.Angles(0, 0, rz)
end
CFrame.fromOrientation = CFrame.fromEulerAnglesYXZ

function CFrame.fromAxisAngle(axis, angle)
	local u = axis.Unit
	local s = math.sin(angle / 2)
	local r00, r01, r02, r10, r11, r12, r20, r21, r22 = quatToMatrix(u.X * s, u.Y * s, u.Z * s, math.cos(angle / 2))
	return make(0, 0, 0, r00, r01, r02, r10, r11, r12, r20, r21, r22)
end

C.__index = function(self, key)
	local m = rawget(self, "m")
	if key == "Position" or key == "p" then
		return V3(m[1], m[2], m[3])
	elseif key == "X" then
		return m[1]
	elseif key == "Y" then
		return m[2]
	elseif key == "Z" then
		return m[3]
	elseif key == "LookVector" or key == "lookVector" then
		return V3(-m[6], -m[9], -m[12])
	elseif key == "RightVector" or key == "XVector" then
		return V3(m[4], m[7], m[10])
	elseif key == "UpVector" or key == "YVector" then
		return V3(m[5], m[8], m[11])
	elseif key == "ZVector" then
		return V3(m[6], m[9], m[12])
	elseif key == "Rotation" then
		return make(0, 0, 0, m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m[12])
	end
	local f = C[key]
	if f ~= nil and type(f) == "function" and key:sub(1, 2) ~= "__" then
		return f
	end
	error(tostring(key) .. " is not a valid member of CFrame", 2)
end

local function mulCF(a, b)
	local A, B = a.m, b.m
	local r00, r01, r02, r10, r11, r12, r20, r21, r22 =
		matmul3(A[4], A[5], A[6], A[7], A[8], A[9], A[10], A[11], A[12], B[4], B[5], B[6], B[7], B[8], B[9], B[10], B[11], B[12])
	return make(
		A[4] * B[1] + A[5] * B[2] + A[6] * B[3] + A[1],
		A[7] * B[1] + A[8] * B[2] + A[9] * B[3] + A[2],
		A[10] * B[1] + A[11] * B[2] + A[12] * B[3] + A[3],
		r00, r01, r02, r10, r11, r12, r20, r21, r22
	)
end

C.__mul = function(a, b)
	if isV3(b) then
		local A = a.m
		return V3(
			A[4] * b.X + A[5] * b.Y + A[6] * b.Z + A[1],
			A[7] * b.X + A[8] * b.Y + A[9] * b.Z + A[2],
			A[10] * b.X + A[11] * b.Y + A[12] * b.Z + A[3]
		)
	end
	return mulCF(a, b)
end
C.__add = function(a, v)
	local A = a.m
	return make(A[1] + v.X, A[2] + v.Y, A[3] + v.Z, A[4], A[5], A[6], A[7], A[8], A[9], A[10], A[11], A[12])
end
C.__sub = function(a, v)
	local A = a.m
	return make(A[1] - v.X, A[2] - v.Y, A[3] - v.Z, A[4], A[5], A[6], A[7], A[8], A[9], A[10], A[11], A[12])
end
C.__eq = function(a, b)
	for i = 1, 12 do
		if a.m[i] ~= b.m[i] then
			return false
		end
	end
	return true
end
C.__tostring = function(a)
	local parts = {}
	for i = 1, 12 do
		parts[i] = string.format("%g", a.m[i])
	end
	return table.concat(parts, ", ")
end

function C.Inverse(a)
	local m = a.m
	local x, y, z = m[1], m[2], m[3]
	local r00, r01, r02, r10, r11, r12, r20, r21, r22 = m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m[12]
	return make(
		-(r00 * x + r10 * y + r20 * z),
		-(r01 * x + r11 * y + r21 * z),
		-(r02 * x + r12 * y + r22 * z),
		r00, r10, r20, r01, r11, r21, r02, r12, r22
	)
end
function C.ToWorldSpace(a, b)
	return mulCF(a, b)
end
function C.ToObjectSpace(a, b)
	return mulCF(C.Inverse(a), b)
end
function C.PointToWorldSpace(a, v)
	return a * v
end
function C.PointToObjectSpace(a, v)
	return C.Inverse(a) * v
end
function C.VectorToWorldSpace(a, v)
	local A = a.m
	return V3(A[4] * v.X + A[5] * v.Y + A[6] * v.Z, A[7] * v.X + A[8] * v.Y + A[9] * v.Z, A[10] * v.X + A[11] * v.Y + A[12] * v.Z)
end
function C.VectorToObjectSpace(a, v)
	local A = a.m
	return V3(A[4] * v.X + A[7] * v.Y + A[10] * v.Z, A[5] * v.X + A[8] * v.Y + A[11] * v.Z, A[6] * v.X + A[9] * v.Y + A[12] * v.Z)
end
function C.GetComponents(a)
	return table.unpack(a.m)
end
C.components = C.GetComponents

function C.ToQuaternion(a)
	local m = a.m
	return matrixToQuat(m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m[12])
end

function C.ToEulerAnglesXYZ(a)
	local m = a.m
	local r00, r01, r02, r12, r22 = m[4], m[5], m[6], m[9], m[12]
	local ry = math.asin(math.clamp(r02, -1, 1))
	local rx = math.atan2(-r12, r22)
	local rz = math.atan2(-r01, r00)
	return rx, ry, rz
end

function C.ToEulerAnglesYXZ(a)
	-- R = Ry * Rx * Rz
	local m = a.m
	local r02, r10, r11, r12, r22 = m[6], m[7], m[8], m[9], m[12]
	local rx = math.asin(math.clamp(-r12, -1, 1))
	local ry = math.atan2(r02, r22)
	local rz = math.atan2(r10, r11)
	return rx, ry, rz
end
C.ToOrientation = C.ToEulerAnglesYXZ

function C.ToAxisAngle(a)
	local qx, qy, qz, qw = C.ToQuaternion(a)
	if qw < 0 then
		qx, qy, qz, qw = -qx, -qy, -qz, -qw
	end
	local angle = 2 * math.acos(math.clamp(qw, -1, 1))
	local s = math.sqrt(math.max(0, 1 - qw * qw))
	if s < 1e-9 then
		return Vector3.xAxis, 0
	end
	return V3(qx / s, qy / s, qz / s), angle
end

function C.Lerp(a, b, t)
	local ax, ay, az, aw = C.ToQuaternion(a)
	local bx, by, bz, bw = C.ToQuaternion(b)
	local d = ax * bx + ay * by + az * bz + aw * bw
	if d < 0 then
		bx, by, bz, bw, d = -bx, -by, -bz, -bw, -d
	end
	local qx, qy, qz, qw
	if d > 0.9995 then
		qx, qy, qz, qw = ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t, aw + (bw - aw) * t
	else
		local th = math.acos(d)
		local s = math.sin(th)
		local wa, wb = math.sin((1 - t) * th) / s, math.sin(t * th) / s
		qx, qy, qz, qw = ax * wa + bx * wb, ay * wa + by * wb, az * wa + bz * wb, aw * wa + bw * wb
	end
	local r00, r01, r02, r10, r11, r12, r20, r21, r22 = quatToMatrix(qx, qy, qz, qw)
	local A, B = a.m, b.m
	return make(
		A[1] + (B[1] - A[1]) * t,
		A[2] + (B[2] - A[2]) * t,
		A[3] + (B[3] - A[3]) * t,
		r00, r01, r02, r10, r11, r12, r20, r21, r22
	)
end

function C.Orthonormalize(a)
	local qx, qy, qz, qw = C.ToQuaternion(a)
	local r00, r01, r02, r10, r11, r12, r20, r21, r22 = quatToMatrix(qx, qy, qz, qw)
	local A = a.m
	return make(A[1], A[2], A[3], r00, r01, r02, r10, r11, r12, r20, r21, r22)
end

CFrame.identity = make(0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1)
CFrame.__meta = C

return CFrame
