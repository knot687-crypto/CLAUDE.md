--!nocheck
-- Table-based Vector3 shim that mirrors the Roblox Vector3 API subset used by SpiderHeroKit.
-- Used only by the offline harness; in Roblox the engine's native Vector3 is used.

local Vector3 = {}
local V = {}
V.__index = function(self, key)
	if key == "Magnitude" then
		return math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
	elseif key == "Unit" then
		local m = math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
		if m == 0 then
			return Vector3.new(0, 0, 0)
		end
		return Vector3.new(self.X / m, self.Y / m, self.Z / m)
	end
	local method = V[key]
	if method ~= nil and type(method) == "function" and key ~= "__index" then
		return method
	end
	error(tostring(key) .. " is not a valid member of Vector3", 2)
end

local function new(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0, __isVector3 = true }, V)
end
Vector3.new = new

function V.Dot(a, b)
	return a.X * b.X + a.Y * b.Y + a.Z * b.Z
end
function V.Cross(a, b)
	return new(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X)
end
function V.Lerp(a, b, t)
	return new(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t, a.Z + (b.Z - a.Z) * t)
end
function V.Max(a, b)
	return new(math.max(a.X, b.X), math.max(a.Y, b.Y), math.max(a.Z, b.Z))
end
function V.Min(a, b)
	return new(math.min(a.X, b.X), math.min(a.Y, b.Y), math.min(a.Z, b.Z))
end
function V.Abs(a)
	return new(math.abs(a.X), math.abs(a.Y), math.abs(a.Z))
end
function V.Floor(a)
	return new(math.floor(a.X), math.floor(a.Y), math.floor(a.Z))
end
function V.Sign(a)
	return new(math.sign(a.X), math.sign(a.Y), math.sign(a.Z))
end
function V.FuzzyEq(a, b, eps)
	eps = eps or 1e-5
	return math.abs(a.X - b.X) <= eps and math.abs(a.Y - b.Y) <= eps and math.abs(a.Z - b.Z) <= eps
end
function V.Angle(a, b, axis)
	local ma = math.sqrt(a.X * a.X + a.Y * a.Y + a.Z * a.Z)
	local mb = math.sqrt(b.X * b.X + b.Y * b.Y + b.Z * b.Z)
	if ma == 0 or mb == 0 then
		return 0
	end
	local d = math.clamp((a.X * b.X + a.Y * b.Y + a.Z * b.Z) / (ma * mb), -1, 1)
	local ang = math.acos(d)
	if axis then
		local c = V.Cross(a, b)
		if c.X * axis.X + c.Y * axis.Y + c.Z * axis.Z < 0 then
			ang = -ang
		end
	end
	return ang
end

V.__add = function(a, b)
	return new(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
V.__sub = function(a, b)
	return new(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
V.__mul = function(a, b)
	if type(a) == "number" then
		return new(a * b.X, a * b.Y, a * b.Z)
	elseif type(b) == "number" then
		return new(a.X * b, a.Y * b, a.Z * b)
	end
	return new(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
V.__div = function(a, b)
	if type(b) == "number" then
		return new(a.X / b, a.Y / b, a.Z / b)
	elseif type(a) == "number" then
		return new(a / b.X, a / b.Y, a / b.Z)
	end
	return new(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
V.__unm = function(a)
	return new(-a.X, -a.Y, -a.Z)
end
V.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
V.__tostring = function(a)
	return string.format("%g, %g, %g", a.X, a.Y, a.Z)
end

Vector3.zero = new(0, 0, 0)
Vector3.one = new(1, 1, 1)
Vector3.xAxis = new(1, 0, 0)
Vector3.yAxis = new(0, 1, 0)
Vector3.zAxis = new(0, 0, 1)
Vector3.__meta = V

return Vector3
