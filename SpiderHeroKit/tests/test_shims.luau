--!nocheck
-- Verifies the harness CFrame/Vector3 shims against known Roblox identities.
local T = require("TestUtil")

T.section("Vector3")
local a = Vector3.new(1, 2, 3)
T.near(a.Magnitude, math.sqrt(14), 1e-12, "magnitude")
T.vnear(a:Cross(Vector3.new(0, 1, 0)), Vector3.new(-3, 0, 1), 1e-12, "cross")
T.vnear(-a + a * 2, a, 1e-12, "arith")

T.section("CFrame.Angles conventions")
-- 90 deg about +Y turns the look vector from -Z toward -X (counter-clockwise from above)
T.vnear(CFrame.Angles(0, math.rad(90), 0).LookVector, Vector3.new(-1, 0, 0), 1e-9, "yaw left")
-- 90 deg about +X tips the look vector up
T.vnear(CFrame.Angles(math.rad(90), 0, 0).LookVector, Vector3.new(0, 1, 0), 1e-9, "pitch up")
-- 90 deg about +Z rolls the up vector toward -X
T.vnear(CFrame.Angles(0, 0, math.rad(90)).UpVector, Vector3.new(-1, 0, 0), 1e-9, "roll left")
-- Angles(x,y,z) == Rx * Ry * Rz
local rx, ry, rz = 0.3, -0.7, 1.1
local composed = CFrame.Angles(rx, 0, 0) * CFrame.Angles(0, ry, 0) * CFrame.Angles(0, 0, rz)
T.cfnear(CFrame.Angles(rx, ry, rz), composed, 1e-9, "XYZ order")
local yxz = CFrame.Angles(0, ry, 0) * CFrame.Angles(rx, 0, 0) * CFrame.Angles(0, 0, rz)
T.cfnear(CFrame.fromEulerAnglesYXZ(rx, ry, rz), yxz, 1e-9, "YXZ order")
local ex, ey, ez = CFrame.Angles(rx, ry, rz):ToEulerAnglesXYZ()
T.near(ex, rx, 1e-9, "decompose x")
T.near(ey, ry, 1e-9, "decompose y")
T.near(ez, rz, 1e-9, "decompose z")
local ox, oy, oz = CFrame.fromEulerAnglesYXZ(rx, ry, rz):ToEulerAnglesYXZ()
T.near(ox, rx, 1e-9, "decompose yxz x")
T.near(oy, ry, 1e-9, "decompose yxz y")
T.near(oz, rz, 1e-9, "decompose yxz z")

T.section("CFrame ops")
local cf = CFrame.new(1, 2, 3) * CFrame.Angles(0.4, 0.2, -0.9)
T.cfnear(cf * cf:Inverse(), CFrame.identity, 1e-9, "inverse")
local p = Vector3.new(4, -2, 7)
T.vnear(cf:PointToObjectSpace(cf:PointToWorldSpace(p)), p, 1e-9, "point space roundtrip")
T.vnear(cf:VectorToWorldSpace(Vector3.new(0, 0, -1)), cf.LookVector, 1e-9, "look vector")
local la = CFrame.lookAt(Vector3.new(0, 0, 0), Vector3.new(10, 0, 0))
T.vnear(la.LookVector, Vector3.new(1, 0, 0), 1e-9, "lookAt forward")
T.vnear(la.UpVector, Vector3.new(0, 1, 0), 1e-9, "lookAt up")
T.vnear(la.RightVector, Vector3.new(0, 0, 1), 1e-9, "lookAt right")
local q = CFrame.new(0, 0, 0, 0, math.sin(0.5), 0, math.cos(0.5))
T.cfnear(q, CFrame.Angles(0, 1, 0), 1e-9, "quaternion ctor")
local l = CFrame.Angles(0, 0, 0):Lerp(CFrame.Angles(0, 1.2, 0), 0.5)
T.cfnear(l, CFrame.Angles(0, 0.6, 0), 1e-9, "slerp")
local axis, angle = CFrame.fromAxisAngle(Vector3.new(1, 1, 0), 0.8):ToAxisAngle()
T.vnear(axis, Vector3.new(1, 1, 0).Unit, 1e-9, "axis")
T.near(angle, 0.8, 1e-9, "angle")

T.section("Instance mock")
local m = Instance.new("Model")
local part = Instance.new("Part")
part.Name = "Torso"
part.Size = Vector3.new(2, 2, 1)
part.Parent = m
T.ok(m.Torso == part, "child index")
T.ok(m:FindFirstChild("Torso") == part, "FindFirstChild")
T.ok(part:IsA("BasePart"), "IsA BasePart")
local okErr = pcall(function()
	part.Sizee = Vector3.new()
end)
T.ok(not okErr, "unknown property rejected")
local mot = Instance.new("Motor6D")
mot.Part0 = part
T.ok(mot.Part0 == part, "ref prop")
T.ok(mot.Part1 == nil, "nil ref prop")
local clone = m:Clone()
T.ok(clone.Torso ~= part and clone.Torso.Size == part.Size, "clone")

return T.finish()
