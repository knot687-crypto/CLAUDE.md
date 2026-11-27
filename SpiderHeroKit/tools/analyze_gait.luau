--!nocheck
-- Gait QA: foot planting and ground penetration for a locomotion clip moving at its authored speed.
--   node tools/harness/run.mjs tools/analyze_gait.luau <ClipName> [speedOverride]
local RS = game:GetService("ReplicatedStorage")
local Kit = RS.SpiderKit
local ClipLibrary = require(Kit.Anim.ClipLibrary)
local Clip = require(Kit.Anim.Clip)
local Pose = require(Kit.Anim.Pose)
local Skeleton = require(Kit.Anim.Skeleton)
local IK = require(Kit.Anim.IK)
local RigDefinition = require(Kit.Rig.RigDefinition)

local clip = ClipLibrary.clip(args[1])
local speed = tonumber(args[2] or "") or clip.speed or 0
local skel = Skeleton.fromDefinition()
local pose = Pose.new(skel.count)
local soles = {
	heel = Vector3.new(0, -0.135, 0.36),
	ball = Vector3.new(0, -0.135, -0.25),
	toe = Vector3.new(0, -0.1, -0.42),
}
local N = 120
local dt = clip.length / N
local prev = {}
local lines = {}
local slideSum, slideCount, maxSlide = 0, 0, 0
local minY = math.huge
local contactFrames = { Right = 0, Left = 0 }
-- stride-matched speed: backward sweep of the planted sole relative to the root (in place)
local sweepSum, sweepCount = 0, 0
local prevLocal = {}
for f = 0, N do
	local t = f * dt
	Clip.sample(clip, t, pose, skel.count, true)
	local parts = IK.fk(skel, pose, {})
	local root = CFrame.new(RigDefinition.RootPartCenter + Vector3.new(0, 0, -speed * t))
	local row = { string.format("%5.3f", t) }
	for _, side in { "Right", "Left" } do
		local footCF = root * parts[side .. "Foot"]
		local low, lowName = math.huge, ""
		local pts = {}
		for nm, p in soles do
			local w = footCF * p
			pts[nm] = w
			if w.Y < low then
				low, lowName = w.Y, nm
			end
		end
		minY = math.min(minY, low)
		local key = side .. lowName
		local vel = 0
		if prev[key] and f > 0 then
			local d = pts[lowName] - prev[key]
			vel = Vector3.new(d.X, 0, d.Z).Magnitude / dt
		end
		for nm, p in pts do
			prev[side .. nm] = p
		end
		local localPt = (parts[side .. "Foot"] * soles[lowName])
		local lk = side .. lowName
		local contact = low < 0.06
		if contact and prevLocal[lk] then
			sweepSum += (localPt.Z - prevLocal[lk].Z) / dt
			sweepCount += 1
		end
		for nm, p in soles do
			prevLocal[side .. nm] = parts[side .. "Foot"] * p
		end
		if contact and f > 0 then
			contactFrames[side] += 1
			slideSum += vel
			slideCount += 1
			maxSlide = math.max(maxSlide, vel)
		end
		table.insert(row, string.format("%s %s y=%6.3f slide=%5.2f%s", side:sub(1, 1), lowName, low, vel, if contact then " *" else ""))
	end
	if f % 6 == 0 then
		table.insert(lines, table.concat(row, "  "))
	end
end
print(table.concat(lines, "\n"))
print(string.format("stride-matched speed: %.2f studs/s", sweepCount > 0 and sweepSum / sweepCount or 0))
print(string.format("clip %s speed %.1f: min sole height %.3f, contact frames R=%d L=%d, mean slide %.2f studs/s, max %.2f",
	clip.name, speed, minY, contactFrames.Right, contactFrames.Left, slideCount > 0 and slideSum / slideCount or 0, maxSlide))
