--!nocheck
-- Mock Instance system for the offline harness.
-- Records class, typed properties and hierarchy so builder output can be serialized
-- to .rbxmx/.rbxlx (tools/build.mjs) and rendered in the preview viewer.
-- Unknown properties raise errors, so typos in builder code are caught offline.

local Vector3 = require("Vector3")
local CFrame = require("CFrame")
local Color3 = require("Color3")
local Enum = require("Enum")

local V3 = Vector3.new

local Classes = {}
local function class(name, super, props)
	Classes[name] = { name = name, super = super, props = props or {} }
end

class("Instance", nil, { Name = "", Archivable = true })
class("Folder", "Instance")
class("Configuration", "Instance")
class("PVInstance", "Instance")
class("Model", "PVInstance", { PrimaryPart = false })
class("WorldModel", "Model")
class("BasePart", "PVInstance", {
	Size = V3(4, 1, 2),
	CFrame = CFrame.identity,
	Color = Color3.fromRGB(163, 162, 165),
	Anchored = false,
	CanCollide = true,
	CanTouch = true,
	CanQuery = true,
	CastShadow = true,
	Massless = false,
	Material = Enum.Material.Plastic,
	Reflectance = 0,
	Transparency = 0,
	Locked = false,
	TopSurface = Enum.SurfaceType.Smooth,
	BottomSurface = Enum.SurfaceType.Smooth,
	LeftSurface = Enum.SurfaceType.Smooth,
	RightSurface = Enum.SurfaceType.Smooth,
	FrontSurface = Enum.SurfaceType.Smooth,
	BackSurface = Enum.SurfaceType.Smooth,
	RootPriority = 0,
	CollisionGroup = "Default",
	AssemblyLinearVelocity = V3(0, 0, 0),
	AssemblyAngularVelocity = V3(0, 0, 0),
})
class("Part", "BasePart", { Shape = Enum.PartType.Block })
class("SpawnLocation", "Part", { Duration = 10, Neutral = true, Enabled = true, AllowTeamChangeOnTouch = false })
class("DataModelMesh", "Instance", { Scale = V3(1, 1, 1), Offset = V3(0, 0, 0), VertexColor = V3(1, 1, 1) })
class("FileMesh", "DataModelMesh", { MeshId = "", TextureId = "" })
class("SpecialMesh", "FileMesh", { MeshType = Enum.MeshType.Head })
class("JointInstance", "Instance", { C0 = CFrame.identity, C1 = CFrame.identity, Part0 = false, Part1 = false, Enabled = true })
class("Motor", "JointInstance", { MaxVelocity = 0, DesiredAngle = 0 })
class("Motor6D", "Motor")
class("Weld", "JointInstance")
class("Attachment", "Instance", { CFrame = CFrame.identity, Visible = false, Name = "Attachment" })
class("Humanoid", "Instance", {
	RigType = Enum.HumanoidRigType.R15,
	HipHeight = 2,
	WalkSpeed = 16,
	JumpPower = 50,
	JumpHeight = 7.2,
	UseJumpPower = true,
	MaxHealth = 100,
	Health = 100,
	AutoRotate = true,
	AutoJumpEnabled = true,
	BreakJointsOnDeath = true,
	RequiresNeck = true,
	DisplayName = "",
	DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer,
	HealthDisplayType = Enum.HumanoidHealthDisplayType.DisplayWhenDamaged,
	MaxSlopeAngle = 89,
	AutomaticScalingEnabled = true,
	EvaluateStateMachine = true,
	MoveDirection = V3(0, 0, 0),
	FloorMaterial = Enum.Material.Plastic,
	Jump = false,
	Sit = false,
	CameraOffset = V3(0, 0, 0),
})
class("LuaSourceContainer", "Instance")
class("BaseScript", "LuaSourceContainer", { Disabled = false })
class("Script", "BaseScript", { Source = "" })
class("LocalScript", "Script")
class("ModuleScript", "LuaSourceContainer", { Source = "" })
class("ValueBase", "Instance")
class("StringValue", "ValueBase", { Value = "" })
class("NumberValue", "ValueBase", { Value = 0 })
class("IntValue", "ValueBase", { Value = 0 })
class("BoolValue", "ValueBase", { Value = false })
class("Vector3Value", "ValueBase", { Value = V3(0, 0, 0) })
class("Color3Value", "ValueBase", { Value = Color3.new(0, 0, 0) })
class("ObjectValue", "ValueBase", { Value = false })
class("Light", "Instance", { Brightness = 1, Color = Color3.new(1, 1, 1), Enabled = true, Shadows = false })
class("PointLight", "Light", { Range = 8 })
class("SpotLight", "Light", { Range = 16, Angle = 90, Face = Enum.NormalId.Front })
class("SurfaceLight", "Light", { Range = 16, Angle = 90, Face = Enum.NormalId.Front })
class("RemoteEvent", "Instance")
class("UnreliableRemoteEvent", "Instance")
class("BindableEvent", "Instance")
-- services (only as containers in the harness)
for _, s in { "Workspace", "ReplicatedStorage", "ServerScriptService", "ServerStorage", "StarterPlayer", "StarterPlayerScripts", "StarterCharacterScripts", "StarterGui", "Lighting", "SoundService" } do
	class(s, "Instance")
end
class("DataModel", "Instance")
Classes.Workspace.props.Gravity = 196.2
Classes.Workspace.props.CurrentCamera = false

-- signals ---------------------------------------------------------------------------------------
local Signal = {}
Signal.__index = Signal
function Signal.new()
	return setmetatable({ _handlers = {} }, Signal)
end
function Signal:Connect(fn)
	local conn = { Connected = true }
	local handlers = self._handlers
	function conn.Disconnect()
		conn.Connected = false
		local i = table.find(handlers, conn)
		if i then
			table.remove(handlers, i)
		end
	end
	conn.fn = fn
	table.insert(handlers, conn)
	return conn
end
function Signal:Once(fn)
	local c
	c = self:Connect(function(...)
		c.Disconnect()
		fn(...)
	end)
	return c
end
function Signal:Fire(...)
	for _, c in table.clone(self._handlers) do
		if c.Connected then
			c.fn(...)
		end
	end
end
function Signal:Wait()
	error("Signal:Wait cannot yield in the harness", 2)
end

-- per-class extension points: methods, events (lazily created signals), computed properties
local ClassMethods, ClassEvents, ClassGetters, ClassSetters = {}, {}, {}, {}
local function classLookup(tbl, className, key)
	local c = Classes[className]
	while c do
		local t = tbl[c.name]
		if t and t[key] ~= nil then
			return t[key]
		end
		c = c.super and Classes[c.super]
	end
	return nil
end
local function extend(tbl, className, entries)
	tbl[className] = tbl[className] or {}
	for k, v in entries do
		tbl[className][k] = v
	end
end

-- runtime objects used by the client controller (simulated by tools/sim_controller.luau)
class("Constraint", "Instance", { Enabled = true, Attachment0 = false, Attachment1 = false })
class("AlignOrientation", "Constraint", {
	Mode = Enum.OrientationAlignmentMode.TwoAttachment,
	RigidityEnabled = false,
	Responsiveness = 10,
	MaxTorque = 10000,
	MaxAngularVelocity = math.huge,
	CFrame = CFrame.identity,
	PrimaryAxisOnly = false,
	ReactionTorqueEnabled = false,
})
class("VectorForce", "Constraint", {
	RelativeTo = Enum.ActuatorRelativeTo.Attachment0,
	ApplyAtCenterOfMass = false,
	Force = V3(0, 0, 0),
})
class("Beam", "Instance", {
	Attachment0 = false, Attachment1 = false, Color = {}, Width0 = 1, Width1 = 1, LightEmission = 0,
	LightInfluence = 1, FaceCamera = false, Segments = 10, Transparency = {}, CurveSize0 = 0, CurveSize1 = 0,
	Texture = "", Enabled = true,
})
class("Sound", "Instance", {
	SoundId = "", Volume = 0.5, RollOffMaxDistance = 10000, Looped = false, PlaybackSpeed = 1, TimePosition = 0,
	Playing = false,
})
class("Bone", "Attachment", { Transform = CFrame.identity })
class("Animator", "Instance")
class("Camera", "Instance", { CFrame = CFrame.identity, FieldOfView = 70 })
class("Terrain", "Instance")
class("Player", "Instance", { Character = false, UserId = 0, DisplayName = "" })
class("PlayerScripts", "Instance")
for _, svc in { "RunService", "Players", "ContextActionService", "UserInputService", "PhysicsService" } do
	class(svc, "Instance")
end
Classes.UserInputService.props.TouchEnabled = false
Classes.Players.props.LocalPlayer = false

local function lookupProp(className, key)
	local c = Classes[className]
	while c do
		local v = c.props[key]
		if v ~= nil then
			return true, v
		end
		c = c.super and Classes[c.super]
	end
	return false, nil
end

local function isA(className, target)
	local c = Classes[className]
	while c do
		if c.name == target then
			return true
		end
		c = c.super and Classes[c.super]
	end
	return false
end

local Instance = {}
local Methods = {}
local Meta = {}

local nextDebugId = 0

local function getChildren(self)
	return rawget(self, "_children")
end

Meta.__index = function(self, key)
	local props = rawget(self, "_props")
	local v = props[key]
	if v ~= nil then
		if v == false and rawget(self, "_refProps")[key] then
			return nil
		end
		return v
	end
	local className = rawget(self, "ClassName")
	if key == "Parent" then
		return rawget(self, "_parent")
	elseif key == "ClassName" then
		return className
	elseif key == "Position" and isA(className, "BasePart") then
		return self.CFrame.Position
	elseif key == "Health" and className == "Humanoid" then
		return props.Health or 100
	end
	local getter = classLookup(ClassGetters, className, key)
	if getter then
		return getter(self)
	end
	if classLookup(ClassEvents, className, key) then
		local ev = rawget(self, "_events")
		local sig = ev[key]
		if not sig then
			sig = Signal.new()
			ev[key] = sig
		end
		return sig
	end
	local cm = classLookup(ClassMethods, className, key)
	if cm then
		return cm
	end
	local m = Methods[key]
	if m then
		return m
	end
	local has, default = lookupProp(className, key)
	if has then
		if default == false and rawget(self, "_refProps")[key] then
			return nil
		end
		return default
	end
	for _, child in getChildren(self) do
		if child.Name == key then
			return child
		end
	end
	error(tostring(key) .. " is not a valid member of " .. className .. ' "' .. tostring(props.Name) .. '"', 2)
end

local function setParent(self, parent)
	local old = rawget(self, "_parent")
	if old == parent then
		return
	end
	if old then
		local list = getChildren(old)
		local idx = table.find(list, self)
		if idx then
			table.remove(list, idx)
		end
	end
	rawset(self, "_parent", parent)
	if parent then
		table.insert(getChildren(parent), self)
	end
	local ev = rawget(self, "_events")
	if ev and ev.AncestryChanged then
		ev.AncestryChanged:Fire(self, parent)
	end
end

Meta.__newindex = function(self, key, value)
	local className = rawget(self, "ClassName")
	if key == "Parent" then
		setParent(self, value)
		return
	end
	if key == "Position" and isA(className, "BasePart") then
		local cf = self.CFrame
		self.CFrame = cf.Rotation + value
		return
	end
	local setter = classLookup(ClassSetters, className, key)
	if setter then
		setter(self, value)
		return
	end
	local has, default = lookupProp(className, key)
	if not has then
		error(tostring(key) .. " is not a valid (settable) member of " .. className, 2)
	end
	-- light type check
	if default == false and rawget(self, "_refProps")[key] then
		if value ~= nil and (type(value) ~= "table" or rawget(value, "_isInstance") ~= true) then
			error("Property " .. className .. "." .. key .. " expects an Instance", 2)
		end
		if value == nil then
			value = false
		end
	elseif type(default) == "number" and type(value) ~= "number" then
		error("Property " .. className .. "." .. key .. " expects a number, got " .. type(value), 2)
	elseif type(default) == "boolean" and type(value) ~= "boolean" then
		error("Property " .. className .. "." .. key .. " expects a boolean, got " .. type(value), 2)
	elseif type(default) == "string" and type(value) ~= "string" then
		error("Property " .. className .. "." .. key .. " expects a string, got " .. type(value), 2)
	elseif type(default) == "table" and type(value) == "table" then
		local dIsEnum, vIsEnum = rawget(default, "__isEnumItem"), rawget(value, "__isEnumItem")
		if dIsEnum and (not vIsEnum or value.EnumType ~= default.EnumType) then
			error("Property " .. className .. "." .. key .. " expects Enum." .. tostring(default.EnumType), 2)
		end
		if rawget(default, "__isVector3") and not rawget(value, "__isVector3") then
			error("Property " .. className .. "." .. key .. " expects Vector3", 2)
		end
		if rawget(default, "__isCFrame") and not rawget(value, "__isCFrame") then
			error("Property " .. className .. "." .. key .. " expects CFrame", 2)
		end
		if rawget(default, "__isColor3") and not rawget(value, "__isColor3") then
			error("Property " .. className .. "." .. key .. " expects Color3", 2)
		end
	end
	if className == "Part" and key == "Size" and rawget(self, "_props").Shape == Enum.PartType.Ball then
		local m = math.min(value.X, value.Y, value.Z)
		value = V3(m, m, m)
	end
	local props = rawget(self, "_props")
	if props[key] == nil then
		table.insert(rawget(self, "_order"), key)
	end
	props[key] = value
end

Meta.__tostring = function(self)
	return rawget(self, "_props").Name
end

function Instance.new(className, parent)
	if not Classes[className] then
		error("Instance.new: class '" .. tostring(className) .. "' is not supported by the harness", 2)
	end
	nextDebugId += 1
	local refProps = {}
	local c = Classes[className]
	while c do
		for k, v in c.props do
			if v == false and (k == "PrimaryPart" or k == "Part0" or k == "Part1" or k == "Attachment0" or k == "Attachment1"
				or k == "Character" or k == "CurrentCamera" or k == "LocalPlayer" or (k == "Value" and className == "ObjectValue")) then
				refProps[k] = true
			end
		end
		c = c.super and Classes[c.super]
	end
	local self = setmetatable({
		ClassName = className,
		_isInstance = true,
		_props = { Name = className },
		_order = { "Name" },
		_children = {},
		_parent = nil,
		_attributes = {},
		_refProps = refProps,
		_debugId = nextDebugId,
		_events = {},
		_attrSignals = {},
	}, Meta)
	if parent then
		self.Parent = parent
	end
	return self
end

function Methods.IsA(self, target)
	return isA(rawget(self, "ClassName"), target)
end
function Methods.GetChildren(self)
	return table.clone(getChildren(self))
end
function Methods.GetDescendants(self)
	local out = {}
	local function walk(inst)
		for _, ch in getChildren(inst) do
			table.insert(out, ch)
			walk(ch)
		end
	end
	walk(self)
	return out
end
function Methods.FindFirstChild(self, name, recursive)
	for _, ch in getChildren(self) do
		if ch.Name == name then
			return ch
		end
	end
	if recursive then
		for _, ch in getChildren(self) do
			local f = Methods.FindFirstChild(ch, name, true)
			if f then
				return f
			end
		end
	end
	return nil
end
function Methods.WaitForChild(self, name)
	local c = Methods.FindFirstChild(self, name)
	if not c then
		error("WaitForChild: '" .. name .. "' not found under " .. self.Name .. " (harness cannot yield)", 2)
	end
	return c
end
function Methods.FindFirstChildOfClass(self, className)
	for _, ch in getChildren(self) do
		if rawget(ch, "ClassName") == className then
			return ch
		end
	end
	return nil
end
function Methods.FindFirstChildWhichIsA(self, className, recursive)
	for _, ch in getChildren(self) do
		if ch:IsA(className) then
			return ch
		end
	end
	if recursive then
		for _, ch in getChildren(self) do
			local f = Methods.FindFirstChildWhichIsA(ch, className, true)
			if f then
				return f
			end
		end
	end
	return nil
end
function Methods.FindFirstAncestorWhichIsA(self, className)
	local p = rawget(self, "_parent")
	while p do
		if p:IsA(className) then
			return p
		end
		p = rawget(p, "_parent")
	end
	return nil
end
function Methods.IsDescendantOf(self, other)
	local p = rawget(self, "_parent")
	while p do
		if p == other then
			return true
		end
		p = rawget(p, "_parent")
	end
	return false
end
function Methods.GetFullName(self)
	local names = {}
	local p = self
	while p and rawget(p, "ClassName") ~= "DataModel" do
		table.insert(names, 1, p.Name)
		p = rawget(p, "_parent")
	end
	return table.concat(names, ".")
end
function Methods.SetAttribute(self, name, value)
	local attrs = rawget(self, "_attributes")
	local old = attrs[name]
	attrs[name] = value
	if old ~= value then
		local sig = rawget(self, "_attrSignals")[name]
		if sig then
			sig:Fire()
		end
	end
end
function Methods.GetAttributeChangedSignal(self, name)
	local sigs = rawget(self, "_attrSignals")
	local sig = sigs[name]
	if not sig then
		sig = Signal.new()
		sigs[name] = sig
	end
	return sig
end
function Methods.GetAttribute(self, name)
	return rawget(self, "_attributes")[name]
end
function Methods.GetAttributes(self)
	return table.clone(rawget(self, "_attributes"))
end
function Methods.Destroy(self)
	setParent(self, nil)
end
function Methods.ClearAllChildren(self)
	for _, ch in Methods.GetChildren(self) do
		setParent(ch, nil)
	end
end
function Methods.GetPivot(self)
	if self:IsA("BasePart") then
		return self.CFrame
	end
	local pp = self.PrimaryPart
	if pp then
		return pp.CFrame
	end
	return CFrame.identity
end

function Methods.Clone(self)
	local map = {}
	local function copy(inst)
		local c = Instance.new(rawget(inst, "ClassName"))
		map[inst] = c
		local props = rawget(inst, "_props")
		for _, k in rawget(inst, "_order") do
			rawget(c, "_props")[k] = props[k]
			if not table.find(rawget(c, "_order"), k) then
				table.insert(rawget(c, "_order"), k)
			end
		end
		for k, v in rawget(inst, "_attributes") do
			rawget(c, "_attributes")[k] = v
		end
		for _, ch in getChildren(inst) do
			local cc = copy(ch)
			setParent(cc, c)
		end
		return c
	end
	local root = copy(self)
	-- remap refs inside the cloned subtree
	for orig, cl in map do
		for k in rawget(cl, "_refProps") do
			local v = rawget(cl, "_props")[k]
			if v and map[v] then
				rawget(cl, "_props")[k] = map[v]
			end
		end
	end
	return root
end

-- Serialize subtree into a plain table with typed property values (for JSON export).
function Instance.__serialize(root)
	local ids = {}
	local counter = 0
	local function assign(inst)
		counter += 1
		ids[inst] = string.format("RBX%08X", counter)
		for _, ch in getChildren(inst) do
			assign(ch)
		end
	end
	assign(root)
	local function encodeValue(v)
		local tv = type(v)
		if tv == "number" then
			return { t = "number", v = v }
		elseif tv == "boolean" then
			return { t = "bool", v = v }
		elseif tv == "string" then
			return { t = "string", v = v }
		elseif tv == "table" then
			if rawget(v, "__isVector3") then
				return { t = "Vector3", v = { v.X, v.Y, v.Z } }
			elseif rawget(v, "__isCFrame") then
				return { t = "CFrame", v = { table.unpack(rawget(v, "m")) } }
			elseif rawget(v, "__isColor3") then
				return { t = "Color3", v = { v.R, v.G, v.B } }
			elseif rawget(v, "__isEnumItem") then
				return { t = "Enum", e = tostring(v.EnumType), n = v.Name, v = v.Value }
			elseif rawget(v, "_isInstance") then
				return { t = "Ref", v = ids[v] or "null" }
			end
		end
		error("cannot serialize value of type " .. tv)
	end
	local function ser(inst)
		local props = {}
		local p = rawget(inst, "_props")
		for _, k in rawget(inst, "_order") do
			local v = p[k]
			if k ~= "Name" then
				if v == false and rawget(inst, "_refProps")[k] then
					props[k] = { t = "Ref", v = "null" }
				else
					props[k] = encodeValue(v)
				end
			end
		end
		local attrs = {}
		for k, v in rawget(inst, "_attributes") do
			attrs[k] = encodeValue(v)
		end
		local children = {}
		for _, ch in getChildren(inst) do
			table.insert(children, ser(ch))
		end
		return {
			class = rawget(inst, "ClassName"),
			name = p.Name,
			id = ids[inst],
			props = props,
			attributes = attrs,
			children = children,
		}
	end
	return ser(root)
end

Instance.__isA = isA
Instance.__Signal = Signal
Instance.__extend = function(kind, className, entries)
	local tbl = ({ methods = ClassMethods, events = ClassEvents, getters = ClassGetters, setters = ClassSetters })[kind]
	assert(tbl, "unknown extension kind " .. tostring(kind))
	extend(tbl, className, entries)
end
Instance.__classes = Classes
return Instance
