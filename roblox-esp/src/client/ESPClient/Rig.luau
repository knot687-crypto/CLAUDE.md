--[[
	Rig
	Skeleton definitions for R6/R15 rigs and bounding-box helpers.

	Bone endpoints are given as a part name plus an offset expressed as a
	fraction of that part's size (Vector3.new(0, 0.5, 0) = centre of the top
	face), so the skeleton follows scaled characters automatically.
]]

local Rig = {}

export type Bone = {
	A: string,
	OffsetA: Vector3,
	B: string,
	OffsetB: Vector3,
}

local CENTER = Vector3.zero
local TOP = Vector3.new(0, 0.5, 0)
local BOTTOM = Vector3.new(0, -0.5, 0)

local function bone(a: string, offsetA: Vector3, b: string, offsetB: Vector3): Bone
	return { A = a, OffsetA = offsetA, B = b, OffsetB = offsetB }
end

local function centers(a: string, b: string): Bone
	return bone(a, CENTER, b, CENTER)
end

Rig.R15 = {
	centers("Head", "UpperTorso"),
	centers("UpperTorso", "LowerTorso"),
	centers("UpperTorso", "LeftUpperArm"),
	centers("LeftUpperArm", "LeftLowerArm"),
	centers("LeftLowerArm", "LeftHand"),
	centers("UpperTorso", "RightUpperArm"),
	centers("RightUpperArm", "RightLowerArm"),
	centers("RightLowerArm", "RightHand"),
	centers("LowerTorso", "LeftUpperLeg"),
	centers("LeftUpperLeg", "LeftLowerLeg"),
	centers("LeftLowerLeg", "LeftFoot"),
	centers("LowerTorso", "RightUpperLeg"),
	centers("RightUpperLeg", "RightLowerLeg"),
	centers("RightLowerLeg", "RightFoot"),
} :: { Bone }

Rig.R6 = {
	bone("Head", CENTER, "Torso", TOP),
	bone("Torso", TOP, "Torso", BOTTOM),
	bone("Torso", TOP, "Left Arm", TOP),
	bone("Left Arm", TOP, "Left Arm", BOTTOM),
	bone("Torso", TOP, "Right Arm", TOP),
	bone("Right Arm", TOP, "Right Arm", BOTTOM),
	bone("Torso", BOTTOM, "Left Leg", TOP),
	bone("Left Leg", TOP, "Left Leg", BOTTOM),
	bone("Torso", BOTTOM, "Right Leg", TOP),
	bone("Right Leg", TOP, "Right Leg", BOTTOM),
} :: { Bone }

Rig.MaxBones = math.max(#Rig.R15, #Rig.R6)

function Rig.getBones(humanoid: Humanoid): { Bone }
	return if humanoid.RigType == Enum.HumanoidRigType.R6 then Rig.R6 else Rig.R15
end

-- World-space position of a bone endpoint.
function Rig.point(part: BasePart, offset: Vector3): Vector3
	if offset == CENTER then
		return part.Position
	end
	return part.CFrame:PointToWorldSpace(part.Size * offset)
end

--[[
	Returns (offset, size): a box relative to `root` that wraps the target.

	Humanoid characters get a body-only box (head top to feet, arms included)
	so hats, wings and other large accessories don't inflate it. Other models
	use their real bounding box; a bare BasePart uses its own size.
]]
function Rig.computeBounds(instance: Instance, humanoid: Humanoid?, root: BasePart, head: BasePart?): (CFrame, Vector3)
	if humanoid then
		local rootSize = root.Size
		local legs = if humanoid.RigType == Enum.HumanoidRigType.R6 then 2 else humanoid.HipHeight
		local bottom = -(rootSize.Y * 0.5 + legs)

		local top = rootSize.Y * 0.5 + 1.6
		if head then
			top = root.CFrame:PointToObjectSpace(head.Position).Y + head.Size.Y * 0.5
		end
		if top <= bottom then
			top = bottom + 5
		end

		local size = Vector3.new(math.max(rootSize.X * 2, 1), top - bottom, math.max(rootSize.Z, 1))
		return CFrame.new(0, (top + bottom) * 0.5, 0), size
	end

	if instance:IsA("Model") then
		local boxCFrame, boxSize = instance:GetBoundingBox()
		return root.CFrame:ToObjectSpace(boxCFrame), boxSize
	end

	return CFrame.identity, root.Size
end

return Rig
