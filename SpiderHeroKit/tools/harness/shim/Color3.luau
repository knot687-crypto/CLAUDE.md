--!nocheck
local Color3 = {}
local M = {}
M.__index = function(self, key)
	local f = M[key]
	if f ~= nil and type(f) == "function" and key:sub(1, 2) ~= "__" then
		return f
	end
	error(tostring(key) .. " is not a valid member of Color3", 2)
end

local function new(r, g, b)
	return setmetatable({ R = r or 0, G = g or 0, B = b or 0, __isColor3 = true }, M)
end
Color3.new = new

function Color3.fromRGB(r, g, b)
	return new((r or 0) / 255, (g or 0) / 255, (b or 0) / 255)
end

function Color3.fromHSV(h, s, v)
	local i = math.floor(h * 6)
	local f = h * 6 - i
	local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
	i = i % 6
	if i == 0 then
		return new(v, t, p)
	elseif i == 1 then
		return new(q, v, p)
	elseif i == 2 then
		return new(p, v, t)
	elseif i == 3 then
		return new(p, q, v)
	elseif i == 4 then
		return new(t, p, v)
	end
	return new(v, p, q)
end

function Color3.fromHex(hex)
	hex = hex:gsub("#", "")
	return Color3.fromRGB(tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16))
end

function M.Lerp(a, b, t)
	return new(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t)
end

function M.ToHSV(c)
	local r, g, b = c.R, c.G, c.B
	local mx, mn = math.max(r, g, b), math.min(r, g, b)
	local d = mx - mn
	local h = 0
	if d > 0 then
		if mx == r then
			h = ((g - b) / d) % 6
		elseif mx == g then
			h = (b - r) / d + 2
		else
			h = (r - g) / d + 4
		end
		h /= 6
	end
	local s = if mx == 0 then 0 else d / mx
	return h, s, mx
end

function M.ToHex(c)
	return string.format("%02x%02x%02x", math.round(c.R * 255), math.round(c.G * 255), math.round(c.B * 255))
end

M.__eq = function(a, b)
	return a.R == b.R and a.G == b.G and a.B == b.B
end
M.__tostring = function(c)
	return string.format("%g, %g, %g", c.R, c.G, c.B)
end

Color3.__meta = M
return Color3
