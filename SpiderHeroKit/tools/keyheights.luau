--!nocheck
-- Prints the lowest sole height at each sampled time (in place) for a clip: tune Root py from this.
local RS = game:GetService("ReplicatedStorage")
local Kit = RS.SpiderKit
local ClipLibrary = require(Kit.Anim.ClipLibrary)
local Clip = require(Kit.Anim.Clip)
local Pose = require(Kit.Anim.Pose)
local Skeleton = require(Kit.Anim.Skeleton)
local IK = require(Kit.Anim.IK)
local RigDefinition = require(Kit.Rig.RigDefinition)
local clip = ClipLibrary.clip(args[1])
local skel = Skeleton.fromDefinition()
local pose = Pose.new(skel.count)
local soles = { Vector3.new(0, -0.135, 0.36), Vector3.new(0, -0.135, -0.25), Vector3.new(0, -0.1, -0.42) }
local times = {}
for t in (args[2] or ""):gmatch("[^,]+") do table.insert(times, tonumber(t)) end
if #times == 0 then for i = 0, 12 do table.insert(times, clip.length * i / 12) end end
for _, t in times do
	Clip.sample(clip, t, pose, skel.count, true)
	local parts = IK.fk(skel, pose, {})
	local out = {}
	for _, side in { "Right", "Left" } do
		local low = math.huge
		for _, p in soles do
			low = math.min(low, (parts[side .. "Foot"] * p).Y + RigDefinition.RootPartCenter.Y)
		end
		table.insert(out, string.format("%s=%6.3f", side:sub(1,1), low))
	end
	print(string.format("t=%5.3f  %s", t, table.concat(out, "  ")))
end
