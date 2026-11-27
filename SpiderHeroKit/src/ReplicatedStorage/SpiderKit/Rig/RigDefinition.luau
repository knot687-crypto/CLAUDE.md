--!strict
--[[
	RigDefinition
	-------------
	Single source of truth for the spider-hero skeleton.

	* R15-compatible: the 15 standard body parts and Motor6D names/axes are used, so every clip in
	  SpiderKit also plays on a regular R15 avatar, and standard R15 animations play on this rig.
	* Adds 10 finger joints per hand (thumb, index, middle, ring, pinky x 2 segments) that the
	  runtime drives with hand-pose presets (Relaxed, Fist, Trigger, Grip, Splay...).
	* Rest pose: character faces -Z, feet on y = 0, arms hanging straight down, palms facing inward.
	  All positions below are in "rest world space" (studs).

	Joint rotation conventions (Motor6D.Transform, CFrame.Angles(x, y, z) = Rx * Ry * Rz):
		+X on shoulders/hips  = swing limb forward     +X on elbows = flex     -X on knees = flex
		+X on waist/neck/root = lean back              +Y = turn left          +Z = lean/roll left
		Right arm abduction (raise sideways) = +Z, left arm abduction = -Z.
		Mirroring a pose left<->right: (x, y, z) -> (x, -y, -z), translation x -> -x.
]]

export type SegmentDef = {
	name: string,
	center: Vector3, -- rest world center
	size: Vector3, -- physical box size
	canCollide: boolean,
	finger: boolean?,
}

export type JointDef = {
	name: string,
	part0: string,
	part1: string,
	pivot: Vector3, -- rest world pivot
	frame: CFrame?, -- optional joint frame rotation (fingers/thumbs); identity otherwise
	side: string?, -- "Left" | "Right" | nil
	mirror: string?, -- name of the mirrored joint
	finger: boolean?,
	rigAttachment: string?, -- R15 rig attachment name (without side prefix handled already)
}

local RigDefinition = {}

RigDefinition.RootPartSize = Vector3.new(2, 2, 1)
RigDefinition.RootPartCenter = Vector3.new(0, 3.3, 0)
RigDefinition.HipHeight = 2.3 -- HRP bottom above ground (R15 formula: center = HipHeight + Size.Y/2)
RigDefinition.Height = 5.55

local SHOULDER_X = 0.62
local HIP_X = 0.25

local segments: { SegmentDef } = {
	{ name = "HumanoidRootPart", center = RigDefinition.RootPartCenter, size = RigDefinition.RootPartSize, canCollide = true },
	{ name = "LowerTorso", center = Vector3.new(0, 3.05, 0), size = Vector3.new(1.0, 0.62, 0.6), canCollide = false },
	{ name = "UpperTorso", center = Vector3.new(0, 4.0, 0), size = Vector3.new(1.36, 1.3, 0.74), canCollide = false },
	{ name = "Head", center = Vector3.new(0, 5.17, -0.03), size = Vector3.new(0.64, 0.8, 0.74), canCollide = false },
}

local function addSide(side: string, sx: number)
	local function v(x: number, y: number, z: number): Vector3
		return Vector3.new(x * sx, y, z)
	end
	table.insert(segments, { name = side .. "UpperArm", center = v(SHOULDER_X, 3.97, 0.03), size = Vector3.new(0.34, 1.02, 0.34), canCollide = false })
	table.insert(segments, { name = side .. "LowerArm", center = v(SHOULDER_X, 3.09, 0.03), size = Vector3.new(0.27, 0.86, 0.27), canCollide = false })
	table.insert(segments, { name = side .. "Hand", center = v(SHOULDER_X, 2.52, 0.02), size = Vector3.new(0.11, 0.32, 0.24), canCollide = false })
	table.insert(segments, { name = side .. "UpperLeg", center = v(HIP_X, 2.21, 0), size = Vector3.new(0.44, 1.38, 0.46), canCollide = false })
	table.insert(segments, { name = side .. "LowerLeg", center = v(HIP_X, 0.905, 0), size = Vector3.new(0.32, 1.3, 0.34), canCollide = false })
	table.insert(segments, { name = side .. "Foot", center = v(HIP_X, 0.135, -0.18), size = Vector3.new(0.3, 0.27, 0.86), canCollide = false })
end
addSide("Right", 1)
addSide("Left", -1)

local joints: { JointDef } = {
	{ name = "Root", part0 = "HumanoidRootPart", part1 = "LowerTorso", pivot = Vector3.new(0, 3.05, 0), rigAttachment = "RootRigAttachment" },
	{ name = "Waist", part0 = "LowerTorso", part1 = "UpperTorso", pivot = Vector3.new(0, 3.36, 0.04), rigAttachment = "WaistRigAttachment" },
	{ name = "Neck", part0 = "UpperTorso", part1 = "Head", pivot = Vector3.new(0, 4.68, 0.04), rigAttachment = "NeckRigAttachment" },
}

local function addLimbJoints(side: string, sx: number, other: string)
	local function v(x: number, y: number, z: number): Vector3
		return Vector3.new(x * sx, y, z)
	end
	local list = {
		{ "Shoulder", "UpperTorso", "UpperArm", v(SHOULDER_X, 4.44, 0.03) },
		{ "Elbow", "UpperArm", "LowerArm", v(SHOULDER_X, 3.5, 0.04) },
		{ "Wrist", "LowerArm", "Hand", v(SHOULDER_X, 2.68, 0.02) },
		{ "Hip", "LowerTorso", "UpperLeg", v(HIP_X, 2.88, 0) },
		{ "Knee", "UpperLeg", "LowerLeg", v(HIP_X, 1.54, -0.02) },
		{ "Ankle", "LowerLeg", "Foot", v(HIP_X, 0.27, 0.04) },
	}
	for _, j in list do
		local p0 = if j[2] == "UpperTorso" or j[2] == "LowerTorso" then j[2] else side .. j[2]
		table.insert(joints, {
			name = side .. j[1],
			part0 = p0,
			part1 = side .. j[3],
			pivot = j[4],
			side = side,
			mirror = other .. j[1],
			rigAttachment = side .. j[1] .. "RigAttachment",
		})
	end
end
addLimbJoints("Right", 1, "Left")
addLimbJoints("Left", -1, "Right")

--[[ Fingers. Right hand palm faces -X (toward the body); fingers hang down -Y at rest.
	 Finger curl toward the palm: right hand = -Z rotation, left hand = +Z (mirrored).
	 Spread (fan in the palm plane) = rotation about X. ]]
RigDefinition.Fingers = { "Thumb", "Index", "Middle", "Ring", "Pinky" }

local FINGER_DATA = {
	-- knuckle pivot (right hand rest world), segment lengths, thickness, rest spread (deg about X)
	-- (kept in sync with tools/character/body.py, which sculpts the hand on these bones)
	Index = { base = Vector3.new(0.624, 2.366, -0.092), len = { 0.125, 0.146 }, thick = 0.066, spread = 17 },
	Middle = { base = Vector3.new(0.624, 2.356, -0.03), len = { 0.135, 0.159 }, thick = 0.068, spread = 5 },
	Ring = { base = Vector3.new(0.624, 2.362, 0.031), len = { 0.128, 0.147 }, thick = 0.064, spread = -7 },
	Pinky = { base = Vector3.new(0.624, 2.38, 0.088), len = { 0.102, 0.12 }, thick = 0.056, spread = -19 },
	-- thumb: rotated frame; local -Y runs along the thumb
	Thumb = { base = Vector3.new(0.596, 2.6, -0.108), len = { 0.125, 0.115 }, thick = 0.072, spread = 0 },
}
RigDefinition.FingerData = FINGER_DATA

-- Thumb rest direction (right hand): down, forward and a little toward the palm side
local THUMB_DIR_R = Vector3.new(-0.34, -0.58, -0.74).Unit

local function thumbFrame(sx: number): CFrame
	-- Right-handed frame: Y axis points back along the thumb (segment extends along -Y),
	-- X axis points toward the palm side (-X for right hand). Mirrored with X' = -M*X convention.
	local dir = Vector3.new(THUMB_DIR_R.X * sx, THUMB_DIR_R.Y, THUMB_DIR_R.Z)
	local yAxis = -dir
	local palmIn = Vector3.new(-sx, 0, 0)
	local xAxis = (palmIn - yAxis * palmIn:Dot(yAxis)).Unit
	if sx < 0 then
		xAxis = -xAxis -- keep the mirrored frame right-handed (X' = -M * X)
	end
	local zAxis = xAxis:Cross(yAxis).Unit
	return CFrame.fromMatrix(Vector3.zero, xAxis, yAxis, zAxis)
end
RigDefinition.ThumbFrame = thumbFrame

local function addFingers(side: string, sx: number, other: string)
	for _, fname in RigDefinition.Fingers do
		local d = FINGER_DATA[fname]
		local base = Vector3.new(d.base.X * sx, d.base.Y, d.base.Z)
		-- fingers rest spread in the palm plane (mirrored rotation about X is identical on both sides)
		local frame = if fname == "Thumb" then thumbFrame(sx) else CFrame.Angles(math.rad(d.spread), 0, 0)
		local down = frame:VectorToWorldSpace(Vector3.new(0, -1, 0))
		local p1 = base
		local p2 = base + down * d.len[1]
		for seg = 1, 2 do
			local segName = side .. fname .. seg
			local pivot = if seg == 1 then p1 else p2
			local len = d.len[seg]
			table.insert(segments, {
				name = segName,
				center = pivot + down * (len / 2),
				size = Vector3.new(d.thick, len, d.thick),
				canCollide = false,
				finger = true,
			})
			table.insert(joints, {
				name = segName,
				part0 = if seg == 1 then side .. "Hand" else side .. fname .. "1",
				part1 = segName,
				pivot = pivot,
				frame = frame,
				side = side,
				mirror = other .. fname .. seg,
				finger = true,
			})
		end
	end
end
addFingers("Right", 1, "Left")
addFingers("Left", -1, "Right")

RigDefinition.Segments = segments
RigDefinition.Joints = joints

local segmentByName: { [string]: SegmentDef } = {}
for _, s in segments do
	segmentByName[s.name] = s
end
RigDefinition.SegmentByName = segmentByName

local jointByName: { [string]: JointDef } = {}
local jointIndex: { [string]: number } = {}
for i, j in joints do
	jointByName[j.name] = j
	jointIndex[j.name] = i
end
RigDefinition.JointByName = jointByName
RigDefinition.JointIndex = jointIndex

-- Body (non-finger) joints in evaluation order
RigDefinition.BodyJoints = {
	"Root", "Waist", "Neck",
	"RightShoulder", "RightElbow", "RightWrist",
	"LeftShoulder", "LeftElbow", "LeftWrist",
	"RightHip", "RightKnee", "RightAnkle",
	"LeftHip", "LeftKnee", "LeftAnkle",
}

--[[ Motor6D C0/C1 for a joint. C0 lives in Part0 space, C1 in Part1 space; both include the joint
	 frame rotation so that Transform rotates about the frame's axes at the pivot. ]]
function RigDefinition.JointC0C1(j: JointDef): (CFrame, CFrame)
	local s0 = segmentByName[j.part0]
	local s1 = segmentByName[j.part1]
	local frame = j.frame or CFrame.identity
	local pivotCF = CFrame.new(j.pivot) * frame
	local c0 = CFrame.new(s0.center):Inverse() * pivotCF
	local c1 = CFrame.new(s1.center):Inverse() * pivotCF
	return c0, c1
end

return RigDefinition
