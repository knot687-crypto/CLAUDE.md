--!nocheck
-- Builds the spider-hero with the real Builder module and exports:
--   tools/preview/out/model_tree.json  (typed instance tree -> .rbxmx/.rbxlx writer)
--   tools/preview/out/model_view.json  (render geometry + rig for the three.js previewer)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Builder = require(ReplicatedStorage.SpiderKit.Rig.Builder)
local RigDefinition = require(ReplicatedStorage.SpiderKit.Rig.RigDefinition)

local paletteName = args[1] or "Classic"
local detail = args[2] or "High"
local outDir = Harness.root .. "/tools/preview/out/"

local t0 = os.clock()
local model = Builder.build({ palette = paletteName, detail = detail })
local buildTime = os.clock() - t0

local function cfArray(cf)
	return { cf:GetComponents() }
end

-- geometry for the viewer: every visible BasePart with its owning rig segment
local parts = {}
local segmentNames = {}
for _, s in RigDefinition.Segments do
	segmentNames[s.name] = true
end

local count = 0
for _, inst in model:GetDescendants() do
	if inst:IsA("BasePart") and inst.Transparency < 1 then
		local segName, localCF
		if segmentNames[inst.Name] and inst.Parent == model then
			segName = inst.Name
			localCF = CFrame.identity
		else
			local weld = inst:FindFirstChildOfClass("Weld")
			assert(weld, "detail part without weld: " .. inst:GetFullName())
			segName = weld.Part0.Name
			localCF = weld.C0
		end
		local mesh = inst:FindFirstChildOfClass("SpecialMesh")
		local shape
		if mesh then
			shape = if mesh.MeshType == Enum.MeshType.Sphere then "ellipsoid" else "block"
		elseif inst.Shape == Enum.PartType.Cylinder then
			shape = "cylinder"
		elseif inst.Shape == Enum.PartType.Ball then
			shape = "ball"
		else
			shape = "block"
		end
		count += 1
		table.insert(parts, {
			name = inst.Name,
			segment = segName,
			shape = shape,
			size = { inst.Size.X, inst.Size.Y, inst.Size.Z },
			color = { inst.Color.R, inst.Color.G, inst.Color.B },
			material = inst.Material.Name,
			reflectance = inst.Reflectance,
			cf = cfArray(localCF),
			shadow = inst.CastShadow,
		})
	end
end

local segments = {}
for _, s in RigDefinition.Segments do
	table.insert(segments, { name = s.name, center = { s.center.X, s.center.Y, s.center.Z } })
end
local joints = {}
for _, j in RigDefinition.Joints do
	local c0, c1 = RigDefinition.JointC0C1(j)
	table.insert(joints, { name = j.name, part0 = j.part0, part1 = j.part1, c0 = cfArray(c0), c1 = cfArray(c1) })
end

Harness.writeJson(outDir .. "model_view.json", {
	palette = paletteName,
	parts = parts,
	segments = segments,
	joints = joints,
	rootCenter = { RigDefinition.RootPartCenter.X, RigDefinition.RootPartCenter.Y, RigDefinition.RootPartCenter.Z },
}, 5)
Harness.writeJson(outDir .. "model_tree.json", Harness.serialize(model), 6)

local instCount = #model:GetDescendants() + 1
print(string.format("built %s/%s in %.0f ms: %d visible parts, %d suit details, %d instances",
	paletteName, detail, buildTime * 1000, count, model:GetAttribute("SuitPartCount"), instCount))
