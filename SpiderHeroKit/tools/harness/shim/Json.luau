--!nocheck
-- Minimal deterministic JSON encoder (sorted object keys) for harness exports.
local Json = {}

local function encodeString(s)
	s = s:gsub('[%c"\\]', function(c)
		if c == '"' then
			return '\\"'
		elseif c == "\\" then
			return "\\\\"
		elseif c == "\n" then
			return "\\n"
		elseif c == "\r" then
			return "\\r"
		elseif c == "\t" then
			return "\\t"
		end
		return string.format("\\u%04x", string.byte(c))
	end)
	return '"' .. s .. '"'
end

local function fmtNumber(n, precision)
	if n ~= n then
		error("JSON: NaN encountered")
	end
	if n == math.huge or n == -math.huge then
		error("JSON: infinity encountered")
	end
	if n == math.floor(n) and math.abs(n) < 1e15 then
		return string.format("%d", n)
	end
	local s = string.format("%." .. (precision or 6) .. "f", n)
	s = s:gsub("0+$", ""):gsub("%.$", "")
	if s == "-0" then
		s = "0"
	end
	return s
end

local function isArray(t)
	local n = #t
	if n == 0 then
		return next(t) == nil
	end
	local count = 0
	for _ in t do
		count += 1
	end
	return count == n
end

local function encode(v, out, precision)
	local tv = type(v)
	if tv == "nil" then
		table.insert(out, "null")
	elseif tv == "boolean" then
		table.insert(out, if v then "true" else "false")
	elseif tv == "number" then
		table.insert(out, fmtNumber(v, precision))
	elseif tv == "string" then
		table.insert(out, encodeString(v))
	elseif tv == "table" then
		if v == Json.null then
			table.insert(out, "null")
		elseif isArray(v) then
			table.insert(out, "[")
			for i, x in ipairs(v) do
				if i > 1 then
					table.insert(out, ",")
				end
				encode(x, out, precision)
			end
			table.insert(out, "]")
		else
			local keys = {}
			for k in v do
				table.insert(keys, tostring(k))
			end
			table.sort(keys)
			table.insert(out, "{")
			for i, k in ipairs(keys) do
				if i > 1 then
					table.insert(out, ",")
				end
				table.insert(out, encodeString(k))
				table.insert(out, ":")
				local val = v[k]
				if val == nil then
					val = v[tonumber(k)]
				end
				encode(val, out, precision)
			end
			table.insert(out, "}")
		end
	else
		error("JSON: cannot encode " .. tv)
	end
end

Json.null = setmetatable({}, { __tostring = function()
	return "null"
end })

function Json.encode(v, precision)
	local out = {}
	encode(v, out, precision)
	return table.concat(out)
end

return Json
