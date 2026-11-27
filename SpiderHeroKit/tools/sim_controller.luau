--!nocheck
--[[
	Offline play-through of the real client stack: SpiderController + AnimDriver + WebVisuals +
	CameraFX + Audio + InputMap + Net, with the real server relay (SpiderServer) and a
	RemoteAnimator-style reader of the replicated attributes.

	A small simulated world stands in for the engine: axis-aligned building blocks for raycasts and
	collisions, a Humanoid state machine (running / jumping / freefall / landed / physics) with
	HipHeight floating, AlignOrientation and anti-gravity VectorForce semantics, a follow camera,
	ContextActionService/UserInputService input, and RemoteEvent delivery to the server.

	  node tools/harness/run.mjs tools/sim_controller.luau [fps]

	Prints the state timeline and checks, and writes tools/preview/out/clip_scn_ctrl.json for the
	previewer (clipsheet.sh scn_ctrl ...).
]]

local RS = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local CAS = game:GetService("ContextActionService")
local UIS = game:GetService("UserInputService")
local SSS = game:GetService("ServerScriptService")

local RigDefinition = require(RS.SpiderKit.Rig.RigDefinition)
local Pose = require(RS.SpiderKit.Anim.Pose)

local FPS = tonumber(args[1] or "60")
local DT = 1 / FPS
local ext = Instance.__extend
local Signal = Instance.__Signal

-- ---------------------------------------------------------------------------------------------
-- datatypes the runtime uses
-- ---------------------------------------------------------------------------------------------
ColorSequence = { new = function(...) return { __ColorSequence = { ... } } end }
NumberSequence = { new = function(...) return { __NumberSequence = { ... } } end }
UDim2 = { new = function(...) return { __UDim2 = { ... } } end }
RaycastParams = {
	new = function()
		return { FilterType = Enum.RaycastFilterType.Exclude, FilterDescendantsInstances = {}, IgnoreWater = false }
	end,
}

-- ---------------------------------------------------------------------------------------------
-- world: static boxes
-- ---------------------------------------------------------------------------------------------
local boxes = {}
local function box(name, center, size)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = CFrame.new(center)
	p.Parent = Workspace
	table.insert(boxes, { part = p, min = center - size / 2, max = center + size / 2, center = center, size = size })
	return p
end
box("Ground", Vector3.new(0, -1, 0), Vector3.new(4000, 2, 4000))
box("ClimbBlock", Vector3.new(0, 40, -60), Vector3.new(60, 80, 40)) -- wall face at z = -40, roof at y = 80
box("TowerL", Vector3.new(-75, 130, -330), Vector3.new(50, 260, 420)) -- avenue for swinging
box("TowerR", Vector3.new(75, 130, -330), Vector3.new(50, 260, 420))
box("LowRoof", Vector3.new(0, 20, -620), Vector3.new(80, 40, 60)) -- roof at y = 40 to zip onto

local function rayBox(o, d, b)
	local tmin, tmax = 0, 1
	local nAxis, nSign = nil, 0
	for _, ax in { "X", "Y", "Z" } do
		local oo, dd = o[ax], d[ax]
		local lo, hi = b.min[ax], b.max[ax]
		if math.abs(dd) < 1e-12 then
			if oo < lo or oo > hi then
				return nil
			end
		else
			local t1, t2 = (lo - oo) / dd, (hi - oo) / dd
			local s = -1
			if t1 > t2 then
				t1, t2 = t2, t1
				s = 1
			end
			if t1 > tmin then
				tmin, nAxis, nSign = t1, ax, s
			end
			tmax = math.min(tmax, t2)
			if tmin > tmax then
				return nil
			end
		end
	end
	if not nAxis then
		return nil -- origin inside the box
	end
	local n = Vector3.new(nAxis == "X" and nSign or 0, nAxis == "Y" and nSign or 0, nAxis == "Z" and nSign or 0)
	return tmin, n
end

local function raycast(origin, dir)
	local best, bt, bn = nil, math.huge, nil
	for _, b in boxes do
		local t, n = rayBox(origin, dir, b)
		if t and t < bt then
			best, bt, bn = b, t, n
		end
	end
	if not best then
		return nil
	end
	return {
		Position = origin + dir * bt,
		Normal = bn,
		Instance = best.part,
		Distance = dir.Magnitude * bt,
		Material = Enum.Material.Concrete,
	}
end
ext("methods", "Workspace", {
	Raycast = function(_, origin, dir, _params)
		return raycast(origin, dir)
	end,
})
local terrain = Instance.new("Terrain")
terrain.Name = "Terrain"
terrain.Parent = Workspace
ext("getters", "Workspace", { Terrain = function() return terrain end })
local camera = Instance.new("Camera")
camera.Name = "Camera"
camera.Parent = Workspace
Workspace.CurrentCamera = camera

-- ---------------------------------------------------------------------------------------------
-- services
-- ---------------------------------------------------------------------------------------------
ext("events", "RunService", { PreSimulation = true, PostSimulation = true, RenderStepped = true, Heartbeat = true, Stepped = true })
local renderBinds = {}
ext("methods", "RunService", {
	BindToRenderStep = function(_, name, prio, fn)
		renderBinds[name] = { prio = prio, fn = fn }
	end,
	UnbindFromRenderStep = function(_, name)
		renderBinds[name] = nil
	end,
	IsClient = function() return true end,
	IsServer = function() return true end,
})
local actions = {}
ext("methods", "ContextActionService", {
	BindActionAtPriority = function(_, name, fn, _touch, _prio, ...)
		actions[name] = { fn = fn, inputs = { ... } }
	end,
	BindAction = function(_, name, fn, _touch, ...)
		actions[name] = { fn = fn, inputs = { ... } }
	end,
	SetTitle = function() end,
	SetPosition = function() end,
	SetImage = function() end,
	UnbindAction = function(_, name)
		actions[name] = nil
	end,
})
ext("events", "UserInputService", { JumpRequest = true, InputBegan = true, InputEnded = true })
ext("events", "Players", { PlayerAdded = true, PlayerRemoving = true })
ext("events", "Player", { CharacterAdded = true, CharacterRemoving = true })
ext("events", "Humanoid", { StateChanged = true, Died = true, Running = true, Jumping = true })
ext("events", "Instance", { AncestryChanged = true, Changed = true })
ext("methods", "Animator", { GetPlayingAnimationTracks = function() return {} end })
ext("methods", "Sound", {
	Play = function(self) self.Playing = true end,
	Stop = function(self) self.Playing = false end,
})
ext("getters", "BasePart", { AssemblyMass = function() return 15.5 end })

-- attachments: Position <-> CFrame, world-space accessors
local function partCF(att)
	local p = att.Parent
	if p and p:IsA("BasePart") then
		return p.CFrame
	end
	return CFrame.identity
end
ext("getters", "Attachment", {
	Position = function(self) return self.CFrame.Position end,
	WorldPosition = function(self) return (partCF(self) * self.CFrame).Position end,
	WorldCFrame = function(self) return partCF(self) * self.CFrame end,
})
ext("setters", "Attachment", {
	Position = function(self, v) rawget(self, "_props").CFrame = self.CFrame.Rotation + v end,
	WorldPosition = function(self, v)
		local local_ = partCF(self):PointToObjectSpace(v)
		rawget(self, "_props").CFrame = self.CFrame.Rotation + local_
	end,
})

-- remotes: client FireServer -> server OnServerEvent (same process)
ext("events", "RemoteEvent", { OnServerEvent = true, OnClientEvent = true })
local localPlayer
local netLog = { sent = 0 }
ext("methods", "RemoteEvent", {
	FireServer = function(self, ...)
		netLog.sent += 1
		self.OnServerEvent:Fire(localPlayer, ...)
	end,
	FireAllClients = function(self, ...)
		self.OnClientEvent:Fire(...)
	end,
})

-- ---------------------------------------------------------------------------------------------
-- player + R15 character
-- ---------------------------------------------------------------------------------------------
localPlayer = Instance.new("Player")
localPlayer.Name = "Tester"
localPlayer.Parent = Players
Players.LocalPlayer = localPlayer
local playerScripts = Instance.new("PlayerScripts")
playerScripts.Name = "PlayerScripts"
playerScripts.Parent = localPlayer
local playerModule = Instance.new("ModuleScript")
playerModule.Name = "PlayerModule"
playerModule.Parent = playerScripts
ext("methods", "Players", {
	GetPlayerFromCharacter = function(_, ch)
		return if localPlayer.Character == ch then localPlayer else nil
	end,
	GetPlayers = function() return { localPlayer } end,
})

local INPUT = { move = Vector3.zero }
local mockControls = { GetMoveVector = function() return INPUT.move end }
local mockPlayerModule = { GetControls = function() return mockControls end }
local baseRequire = require
require = function(m)
	if m == playerModule then
		return mockPlayerModule
	end
	return baseRequire(m)
end

local character = Instance.new("Model")
character.Name = "Hero"
local parts = {}
for _, seg in RigDefinition.Segments do
	local p = Instance.new("Part")
	p.Name = seg.name
	p.Size = seg.size
	p.CFrame = CFrame.new(seg.center)
	p.CanCollide = seg.name == "HumanoidRootPart" or seg.name == "UpperTorso" or seg.name == "LowerTorso" or seg.name == "Head"
	p.Parent = character
	parts[seg.name] = p
end
for _, jn in RigDefinition.BodyJoints do
	local j = RigDefinition.JointByName[jn]
	local m = Instance.new("Motor6D")
	m.Name = jn
	m.Part0 = parts[j.part0]
	m.Part1 = parts[j.part1]
	local c0, c1 = RigDefinition.JointC0C1(j)
	m.C0, m.C1 = c0, c1
	m.Parent = parts[j.part1]
end
ext("methods", "Motor6D", {})
Instance.__classes.Motor6D.props.Transform = CFrame.identity
local humanoid = Instance.new("Humanoid")
humanoid.HipHeight = RigDefinition.HipHeight
humanoid.Parent = character
local animator = Instance.new("Animator")
animator.Parent = humanoid
character.PrimaryPart = parts.HumanoidRootPart
character.Parent = Workspace
localPlayer.Character = character
local root = parts.HumanoidRootPart

-- ---------------------------------------------------------------------------------------------
-- humanoid + physics simulation
-- ---------------------------------------------------------------------------------------------
local HST = Enum.HumanoidStateType
local humState = HST.Running
local function setHum(new)
	if new ~= humState then
		local old = humState
		humState = new
		humanoid.StateChanged:Fire(old, new)
	end
end
ext("methods", "Humanoid", {
	GetState = function() return humState end,
	ChangeState = function(_, s) setHum(s) end,
	Move = function() end,
	SetStateEnabled = function() end,
})
local jumpQueued = false
UIS.JumpRequest:Connect(function()
	jumpQueued = true
end)

local HIP = humanoid.HipHeight + root.Size.Y / 2
root.CFrame = CFrame.new(0, HIP, 20)
local camYaw, camPitch = 0, -0.12 -- camera looks toward -Z by default

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function collide(pos, vel)
	if not root.CanCollide then
		return pos, vel
	end
	for _, b in boxes do
		local r = 1.0
		local lo, hi = b.min - Vector3.one * r, b.max + Vector3.one * r
		if pos.X > lo.X and pos.X < hi.X and pos.Y > lo.Y and pos.Y < hi.Y and pos.Z > lo.Z and pos.Z < hi.Z then
			-- push out along the shallowest axis
			local d = { { "X", pos.X - lo.X, -1 }, { "X", hi.X - pos.X, 1 }, { "Y", pos.Y - lo.Y, -1 }, { "Y", hi.Y - pos.Y, 1 }, { "Z", pos.Z - lo.Z, -1 }, { "Z", hi.Z - pos.Z, 1 } }
			table.sort(d, function(a, c) return a[2] < c[2] end)
			local ax, depth, s = d[1][1], d[1][2], d[1][3]
			local n = Vector3.new(ax == "X" and s or 0, ax == "Y" and s or 0, ax == "Z" and s or 0)
			pos += n * depth
			local into = vel:Dot(n)
			if into < 0 then
				vel -= n * into
			end
		end
	end
	return pos, vel
end

local function physicsStep(dt)
	local v = root.AssemblyLinearVelocity
	local pos = root.CFrame.Position
	local rot = root.CFrame.Rotation
	local g = Workspace.Gravity
	local mv = INPUT.move
	-- the engine's control module: camera-relative MoveDirection
	local cl = flat(camera.CFrame.LookVector)
	cl = if cl.Magnitude > 1e-3 then cl.Unit else Vector3.new(0, 0, -1)
	local cr = flat(camera.CFrame.RightVector)
	cr = if cr.Magnitude > 1e-3 then cr.Unit else Vector3.new(1, 0, 0)
	local md = cr * mv.X + cl * -mv.Z
	humanoid.MoveDirection = if md.Magnitude > 1 then md.Unit else md

	if humState == HST.Physics then
		local vf = root:FindFirstChild("SpiderKitAntiGravity")
		local gEff = g
		if vf and vf.Enabled then
			gEff -= vf.Force.Y / root.AssemblyMass
		end
		v += Vector3.new(0, -gEff * dt, 0)
		pos += v * dt
		pos, v = collide(pos, v)
		local al = root:FindFirstChild("SpiderKitAlign")
		if al and al.Enabled then
			rot = al.CFrame.Rotation
		end
	elseif humState == HST.Running or humState == HST.Landed or humState == HST.GettingUp or humState == HST.RunningNoPhysics then
		local ground = raycast(pos, Vector3.new(0, -(HIP + 1.2), 0))
		if not ground then
			setHum(HST.Freefall)
		else
			local target = humanoid.MoveDirection * humanoid.WalkSpeed
			local hv = flat(v):Lerp(target, math.min(1, dt * 10))
			v = Vector3.new(hv.X, 0, hv.Z)
			pos = Vector3.new(pos.X + hv.X * dt, ground.Position.Y + HIP, pos.Z + hv.Z * dt)
			pos, v = collide(pos, v)
			if humanoid.AutoRotate and humanoid.MoveDirection.Magnitude > 0.1 then
				rot = rot:Lerp(CFrame.lookAt(Vector3.zero, humanoid.MoveDirection), math.min(1, dt * 12))
			end
			if humState == HST.Landed then
				setHum(HST.Running)
			end
			if jumpQueued then
				v = Vector3.new(v.X, humanoid.JumpPower, v.Z)
				setHum(HST.Jumping)
				v = root.AssemblyLinearVelocity.Y > humanoid.JumpPower and root.AssemblyLinearVelocity or v
			end
		end
	elseif humState == HST.Jumping or humState == HST.Freefall then
		if humState == HST.Jumping then
			setHum(HST.Freefall)
		end
		v += Vector3.new(0, -g * dt, 0)
		local target = humanoid.MoveDirection * humanoid.WalkSpeed
		local hv = flat(v)
		if humanoid.MoveDirection.Magnitude > 0.1 then
			hv = hv:Lerp(target, math.min(1, dt * 4))
		end
		v = Vector3.new(hv.X, v.Y, hv.Z)
		pos += v * dt
		pos, v = collide(pos, v)
		local ground = raycast(pos + Vector3.new(0, 1, 0), Vector3.new(0, -(HIP + 1), 0))
		if ground and v.Y <= 0 and pos.Y - ground.Position.Y <= HIP + 0.05 then
			pos = Vector3.new(pos.X, ground.Position.Y + HIP, pos.Z)
			v = Vector3.new(v.X, 0, v.Z)
			setHum(HST.Landed)
		end
		if humanoid.AutoRotate and flat(v).Magnitude > 1 then
			rot = rot:Lerp(CFrame.lookAt(Vector3.zero, flat(v)), math.min(1, dt * 8))
		end
	end
	jumpQueued = false
	root.AssemblyLinearVelocity = v
	root.CFrame = rot + pos
end

local function updateCamera()
	local look = CFrame.Angles(0, camYaw, 0) * CFrame.Angles(camPitch, 0, 0)
	local target = root.Position + Vector3.new(0, 2, 0)
	camera.CFrame = CFrame.new(target - look.LookVector * 14) * look
end

-- ---------------------------------------------------------------------------------------------
-- boot the real scripts: server relay, then the client controller
-- ---------------------------------------------------------------------------------------------
local function runScript(inst)
	local path = Harness.mounted[inst]
	local env = setmetatable({ script = inst }, { __index = _G, __newindex = _G })
	__load(__readfile(path), "@" .. path, env)()
end
runScript(SSS.SpiderServer)
local SpiderController = require(RS.SpiderKit.Client.SpiderController)
local ctl = SpiderController.new(character)
updateCamera()

-- ---------------------------------------------------------------------------------------------
-- input helpers and the scripted session
-- ---------------------------------------------------------------------------------------------
local function action(name, state)
	local a = actions[name]
	assert(a, "action not bound: " .. name)
	a.fn(name, state, { UserInputType = Enum.UserInputType.Keyboard, KeyCode = Enum.KeyCode.Unknown })
end
local BEGIN, END = Enum.UserInputState.Begin, Enum.UserInputState.End

local timeline = {}
local frames = {}
local errors = {}
local seen = {}
local lastState = nil
local t = 0
local events = {}
local remoteEvents = {}
character:GetAttributeChangedSignal("SpiderEvent"):Connect(function()
	table.insert(remoteEvents, character:GetAttribute("SpiderEvent"))
end)

local function step(n)
	for _ = 1, n do
		t += DT
		updateCamera()
		local ok, err = pcall(function()
			RunService.PreSimulation:Fire(DT)
		end)
		if not ok then
			table.insert(errors, string.format("t=%.2f %s", t, tostring(err)))
			if #errors > 5 then
				error("too many controller errors:\n" .. table.concat(errors, "\n"))
			end
		end
		physicsStep(DT)
		RunService.RenderStepped:Fire(DT)
		for _, b in renderBinds do
			b.fn(DT)
		end
		for _, e in ctl.driver:events() do
			table.insert(events, e)
		end
		if ctl.state ~= lastState then
			table.insert(timeline, string.format("%6.2f  %-9s pos=(%.1f, %.1f, %.1f) hum=%s", t, ctl.state, root.Position.X, root.Position.Y, root.Position.Z, humState.Name))
			lastState = ctl.state
			seen[ctl.state] = true
		end
		-- preview frame every other step
		if math.floor(t * FPS + 0.5) % 2 == 0 then
			local out = ctl.driver.ac.out
			local joints = {}
			for i, j in ctl.driver.ac.skel.joints do
				joints[j.name] = { Pose.get(out, i) }
			end
			local anchor = ctl.swing and ctl.swing.anchor or ctl.zipTarget
			table.insert(frames, {
				t = t,
				rootCF = { root.CFrame:GetComponents() },
				joints = joints,
				state = ctl.state,
				mode = ctl.driver.ac.mode,
				anchor = anchor and { anchor.X, anchor.Y, anchor.Z } or nil,
				hand = if ctl.swing then ctl.swingHand elseif ctl.zipTarget then "Right" else nil,
			})
		end
	end
end
local function secs(s)
	step(math.floor(s * FPS + 0.5))
end

-- 1) stand, walk, sprint toward the climbing block (wall face at z = -40)
secs(1.0)
INPUT.move = Vector3.new(0, 0, -1)
secs(1.0)
action("SpiderSprint", BEGIN)
secs(0.6)
action("SpiderSprint", END)
-- 2) walk into the wall -> climb, then sprint up it (wall run) -> vault onto the roof
secs(3.5)
action("SpiderSprint", BEGIN)
secs(3.0)
action("SpiderSprint", END)
INPUT.move = Vector3.zero
secs(1.2)
-- 3) walk to the roof's back edge (z = -80) and wait there -> perch
camYaw = 0
INPUT.move = Vector3.new(0, 0, -1)
local guard = 0
while root.Position.Z > -77.5 and guard < 600 do
	step(1)
	guard += 1
end
INPUT.move = Vector3.zero
secs(1.4)
-- 4) leap off toward the tower avenue and swing twice
UIS.JumpRequest:Fire()
INPUT.move = Vector3.new(0, 0, -1)
secs(0.35)
action("SpiderSwing", BEGIN)
secs(1.6)
action("SpiderSwing", END)
secs(0.5)
action("SpiderSwing", BEGIN)
secs(1.5)
action("SpiderSwing", END)
secs(2.5)
-- 5) aim at the low roof's front wall and zip to it
INPUT.move = Vector3.zero
secs(1.0)
do
	local target = Vector3.new(0, 30, -590)
	local d = target - camera.CFrame.Position
	camYaw = math.atan2(-d.X, -d.Z)
	camPitch = math.asin(d.Unit.Y)
	updateCamera()
end
action("SpiderZip", BEGIN)
secs(2.5)
-- 6) wall jump off whatever we are clinging to (or jump), then land
UIS.JumpRequest:Fire()
camPitch = -0.12
secs(3.0)

-- ---------------------------------------------------------------------------------------------
-- report
-- ---------------------------------------------------------------------------------------------
print("state timeline:")
print(table.concat(timeline, "\n"))
local evCount = {}
for _, e in events do
	evCount[e] = (evCount[e] or 0) + 1
end
local evList = {}
for k, v in evCount do
	table.insert(evList, k .. "=" .. v)
end
table.sort(evList)
print("anim events:", table.concat(evList, " "))
print("replicated one-shots:", table.concat(remoteEvents, "  "))
print("network messages sent:", netLog.sent, " attributes:", character:GetAttribute("SpiderState"), character:GetAttribute("Sprint"))

local motorsMoved = 0
for _, d in character:GetDescendants() do
	if d:IsA("Motor6D") and d.Transform ~= CFrame.identity then
		motorsMoved += 1
	end
end
print("motors driven:", motorsMoved)

local need = { "Ground", "Air", "WallCrawl", "WallRun", "Ledge", "Perch", "Swing", "Zip" }
local missing = {}
for _, s in need do
	if not seen[s] then
		table.insert(missing, s)
	end
end
if #errors > 0 then
	print("ERRORS:\n" .. table.concat(errors, "\n"))
end
print(#missing == 0 and "all states reached" or ("MISSING STATES: " .. table.concat(missing, ", ")))
Harness.writeJson(Harness.root .. "/tools/preview/out/clip_scn_ctrl.json", {
	scenario = "ctrl",
	fps = FPS / 2,
	frames = frames,
	scene = { boxes = (function()
		local out = {}
		for _, b in boxes do
			if b.part.Name ~= "Ground" then
				table.insert(out, { center = { b.center.X, b.center.Y, b.center.Z }, size = { b.size.X, b.size.Y, b.size.Z } })
			end
		end
		return out
	end)() },
}, 5)
print("frames:", #frames)
