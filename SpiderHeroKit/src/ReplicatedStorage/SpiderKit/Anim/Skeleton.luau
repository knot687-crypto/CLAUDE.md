--!strict
--[[
	Skeleton
	--------
	Runtime description of the rig: canonical joint order (from RigDefinition), Motor6D C0/C1 and
	parent links. Can be built from the RigDefinition (offline/tests) or from a live character's
	Motor6Ds, so FK/IK use that avatar's real proportions (works on any R15 body).
]]

local RigDefinition = require(script.Parent.Parent.Rig.RigDefinition)

export type Joint = {
	name: string,
	index: number,
	part0: string,
	part1: string,
	c0: CFrame,
	c1: CFrame,
	c1inv: CFrame,
	parent: number?, -- joint whose part1 is our part0
	finger: boolean,
	side: string?,
	mirror: number?,
	present: boolean, -- false when the bound character lacks this joint
}

export type Skeleton = {
	joints: { Joint },
	byName: { [string]: Joint },
	count: number,
	bodyCount: number,
	scale: number, -- (hip height of bound rig) / (hip height of the authoring rig)
}

local Skeleton = {}

local function build(getC0C1: (any) -> (CFrame?, CFrame?)): Skeleton
	local joints: { Joint } = {}
	local byName: { [string]: Joint } = {}
	local byPart1: { [string]: number } = {}
	for i, def in RigDefinition.Joints do
		local c0, c1 = getC0C1(def)
		local present = c0 ~= nil
		if not c0 or not c1 then
			c0, c1 = RigDefinition.JointC0C1(def)
		end
		local j: Joint = {
			name = def.name,
			index = i,
			part0 = def.part0,
			part1 = def.part1,
			c0 = c0 :: CFrame,
			c1 = c1 :: CFrame,
			c1inv = (c1 :: CFrame):Inverse(),
			parent = nil,
			finger = def.finger == true,
			side = def.side,
			mirror = nil,
			present = present,
		}
		joints[i] = j
		byName[def.name] = j
		byPart1[def.part1] = i
	end
	for _, j in joints do
		j.parent = byPart1[j.part0]
		local def = RigDefinition.JointByName[j.name]
		if def.mirror then
			j.mirror = RigDefinition.JointIndex[def.mirror]
		end
	end
	local bodyCount = 0
	for _, j in joints do
		if not j.finger then
			bodyCount += 1
		end
	end
	return { joints = joints, byName = byName, count = #joints, bodyCount = bodyCount, scale = 1 }
end

function Skeleton.fromDefinition(): Skeleton
	return build(function(def)
		return RigDefinition.JointC0C1(def)
	end)
end

-- Reads Motor6Ds from a character (R15 or SpiderHero). Missing joints keep authoring defaults
-- but are flagged `present = false` so the driver skips them.
function Skeleton.fromCharacter(character: Model): (Skeleton, { [number]: Motor6D })
	local motors: { [number]: Motor6D } = {}
	local found: { [string]: Motor6D } = {}
	for _, d in character:GetDescendants() do
		if d:IsA("Motor6D") then
			found[d.Name] = d
		end
	end
	local skel = build(function(def)
		local m = found[def.name]
		if m and m.Part0 and m.Part1 then
			return m.C0, m.C1
		end
		return nil, nil
	end)
	for i, j in skel.joints do
		local m = found[j.name]
		if m and j.present then
			motors[i] = m
		end
	end
	-- proportional scale from leg length so root translations fit other body sizes
	local hip = skel.byName.RightHip
	local knee = skel.byName.RightKnee
	local ankle = skel.byName.RightAnkle
	if hip.present and knee.present and ankle.present then
		local thigh = (hip.c1inv * knee.c0).Position.Magnitude
		local shin = (knee.c1inv * ankle.c0).Position.Magnitude
		local refSkel = Skeleton.fromDefinition()
		local rh, rk, ra = refSkel.byName.RightHip, refSkel.byName.RightKnee, refSkel.byName.RightAnkle
		local refLen = (rh.c1inv * rk.c0).Position.Magnitude + (rk.c1inv * ra.c0).Position.Magnitude
		skel.scale = (thigh + shin) / refLen
	end
	return skel, motors
end

return Skeleton
