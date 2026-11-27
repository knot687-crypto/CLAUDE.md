--!nocheck
-- Samples one clip into preview frames.
--   node tools/harness/run.mjs tools/bake_clip.luau <ClipName> [fps] [duration] [move]
-- move: "move" translates the root at the clip's authored speed (to judge foot planting)
local RS = game:GetService("ReplicatedStorage")
local Kit = RS.SpiderKit
local ClipLibrary = require(Kit.Anim.ClipLibrary)
local Clip = require(Kit.Anim.Clip)
local Pose = require(Kit.Anim.Pose)
local HandPoses = require(Kit.Anim.HandPoses)
local Skeleton = require(Kit.Anim.Skeleton)
local RigDefinition = require(Kit.Rig.RigDefinition)

local name = args[1]
local fps = tonumber(args[2] or "30")
local clip = ClipLibrary.clip(name)
local duration = tonumber(args[3] or "0")
if duration <= 0 then
	duration = clip.length
end
local move = args[4] == "move"
local skel = Skeleton.fromDefinition()
local pose = Pose.new(skel.count)

local frames = {}
local n = math.floor(duration * fps + 0.5)
for f = 0, n do
	local t = f / fps
	Clip.sample(clip, t, pose, skel.count, true)
	for _, side in { "Right", "Left" } do
		local a, b, alpha = Clip.handAt(clip, side:sub(1, 1), t)
		if a then
			HandPoses.writePreset(pose, side, a, b, alpha)
		else
			HandPoses.writePreset(pose, side, "Relaxed")
		end
	end
	local z = if move and clip.speed then -clip.speed * t else 0
	local root = CFrame.new(RigDefinition.RootPartCenter + Vector3.new(0, 0, z))
	local joints = {}
	for i, j in skel.joints do
		joints[j.name] = { Pose.get(pose, i) }
	end
	table.insert(frames, { t = t, rootCF = { root:GetComponents() }, joints = joints })
end
Harness.writeJson(Harness.root .. "/tools/preview/out/clip_" .. name .. ".json", { clip = name, fps = fps, frames = frames }, 5)
print(string.format("baked %s: %d frames", name, #frames))
