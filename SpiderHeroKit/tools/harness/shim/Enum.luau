--!nocheck
-- Enum shim with the enum types (and exact engine values) used by SpiderHeroKit.
local defs = {
	Material = {
		Plastic = 256, SmoothPlastic = 272, Neon = 288, Wood = 512, WoodPlanks = 528, Marble = 784,
		Basalt = 788, Slate = 800, CrackedLava = 804, Concrete = 816, Limestone = 820, Granite = 832,
		Pavement = 836, Brick = 848, Pebble = 864, Cobblestone = 880, Rock = 896, Sandstone = 912,
		CorrodedMetal = 1040, DiamondPlate = 1056, Foil = 1072, Metal = 1088, Grass = 1280,
		LeafyGrass = 1284, Sand = 1296, Fabric = 1312, Snow = 1328, Mud = 1344, Ground = 1360,
		Asphalt = 1376, Salt = 1392, Ice = 1536, Glacier = 1552, Glass = 1568, ForceField = 1584,
	},
	PartType = { Ball = 0, Block = 1, Cylinder = 2, Wedge = 3, CornerWedge = 4 },
	MeshType = {
		Head = 0, Torso = 1, Wedge = 2, Sphere = 3, Cylinder = 4, FileMesh = 5, Brick = 6, Prism = 7,
		Pyramid = 8, ParallelRamp = 9, RightAngleRamp = 10, CornerWedge = 11,
	},
	SurfaceType = { Smooth = 0, Glue = 1, Weld = 2, Studs = 3, Inlet = 4, Universal = 5, Hinge = 6, Motor = 7, SteppingMotor = 8, SmoothNoOutlines = 10 },
	HumanoidRigType = { R6 = 0, R15 = 1 },
	HumanoidDisplayDistanceType = { Viewer = 0, Subject = 1, None = 2 },
	HumanoidHealthDisplayType = { DisplayWhenDamaged = 0, AlwaysOn = 1, AlwaysOff = 2 },
	NameOcclusion = { NoOcclusion = 0, EnemyOcclusion = 1, OccludeAll = 2 },
	Technology = { Legacy = 0, Voxel = 1, Compatibility = 2, ShadowMap = 3, Future = 4 },
	RunContext = { Legacy = 0, Server = 1, Client = 2, Plugin = 3 },
	HumanoidStateType = {
		FallingDown = 0, Ragdoll = 1, GettingUp = 2, Jumping = 3, Swimming = 4, Freefall = 5, Flying = 6,
		Landed = 7, Running = 8, RunningNoPhysics = 10, StrafingNoPhysics = 11, Climbing = 12, Seated = 13,
		PlatformStanding = 14, Dead = 15, Physics = 16, None = 18,
	},
	NormalId = { Right = 0, Top = 1, Back = 2, Left = 3, Bottom = 4, Front = 5 },
}

local Enum = {}
for typeName, items in defs do
	local enumType = { __name = typeName }
	local list = {}
	for itemName, value in items do
		local item = { Name = itemName, Value = value, EnumType = enumType, __isEnumItem = true }
		setmetatable(item, {
			__tostring = function()
				return "Enum." .. typeName .. "." .. itemName
			end,
		})
		enumType[itemName] = item
		table.insert(list, item)
	end
	table.sort(list, function(a, b)
		return a.Value < b.Value
	end)
	setmetatable(enumType, {
		__index = function(_, k)
			if k == "GetEnumItems" then
				return function()
					return table.clone(list)
				end
			end
			error(tostring(k) .. " is not a valid EnumItem of Enum." .. typeName, 2)
		end,
		__tostring = function()
			return typeName
		end,
	})
	Enum[typeName] = enumType
end

return setmetatable(Enum, {
	__index = function(_, k)
		error("Enum." .. tostring(k) .. " is not supported by the harness shim", 2)
	end,
})
