--!nocheck
-- Exports RigDefinition (segments, joints, pivots, finger data) as JSON for the character pipeline.
local RS = game:GetService("ReplicatedStorage")
local RigDefinition = require(RS.SpiderKit.Rig.RigDefinition)
local function v(x) return { x.X, x.Y, x.Z } end
local joints = {}
for _, j in RigDefinition.Joints do
	local frame = j.frame or CFrame.identity
	table.insert(joints, { name = j.name, part0 = j.part0, part1 = j.part1, pivot = v(j.pivot), frame = { frame:GetComponents() }, finger = j.finger == true, side = j.side })
end
local segs = {}
for _, s in RigDefinition.Segments do
	table.insert(segs, { name = s.name, center = v(s.center), size = v(s.size), finger = s.finger == true })
end
Harness.writeJson(Harness.root .. "/tools/character/rig.json", { joints = joints, segments = segs, rootCenter = v(RigDefinition.RootPartCenter), hipHeight = RigDefinition.HipHeight }, 6)
print("rig exported")
