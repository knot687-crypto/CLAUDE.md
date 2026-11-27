--!nocheck
-- Tiny assertion library for harness tests.
local T = { passed = 0, failed = 0, current = "" }

function T.section(name)
	T.current = name
end

local function fail(msg)
	T.failed += 1
	print(string.format("  FAIL [%s] %s", T.current, msg))
end

function T.ok(cond, msg)
	if cond then
		T.passed += 1
	else
		fail(msg)
	end
end

function T.near(a, b, eps, msg)
	if type(a) ~= "number" or type(b) ~= "number" or a ~= a or math.abs(a - b) > eps then
		fail(string.format("%s: %s vs %s", msg, tostring(a), tostring(b)))
	else
		T.passed += 1
	end
end

function T.vnear(a, b, eps, msg)
	if (a - b).Magnitude > eps then
		fail(string.format("%s: (%s) vs (%s)", msg, tostring(a), tostring(b)))
	else
		T.passed += 1
	end
end

function T.cfnear(a, b, eps, msg)
	local ca, cb = { a:GetComponents() }, { b:GetComponents() }
	for i = 1, 12 do
		if math.abs(ca[i] - cb[i]) > eps then
			fail(string.format("%s: component %d %g vs %g", msg, i, ca[i], cb[i]))
			return
		end
	end
	T.passed += 1
end

function T.finish()
	print(string.format("  %d passed, %d failed", T.passed, T.failed))
	local result = { passed = T.passed, failed = T.failed }
	T.passed, T.failed = 0, 0
	return result
end

return T
