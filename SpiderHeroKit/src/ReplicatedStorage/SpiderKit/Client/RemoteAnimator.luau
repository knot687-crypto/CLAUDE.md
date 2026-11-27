--!nonstrict
--[[
	RemoteAnimator: animates every other player's character on this client.

	Motor6D.Transform does not replicate, so each client runs the same AnimController for the
	characters it can see. The context comes from the replicated physics plus the attributes the
	server relay sets (SpiderState, SwingAnchor, ...); one-shot moves arrive through SpiderEvent.
	Distant characters update at a reduced rate and are culled beyond Config.AnimCullDistance.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Kit = script.Parent.Parent
local Config = require(Kit.Config)
local Net = require(Kit.Net)
local AnimDriver = require(script.Parent.AnimDriver)
local WebVisuals = require(script.Parent.WebVisuals)

local RemoteAnimator = {}

local entries = {}

local function cleanup(character: Model)
	local e = entries[character]
	if not e then
		return
	end
	entries[character] = nil
	for _, c in e.conns do
		c:Disconnect()
	end
	e.webs:destroy()
	e.driver:destroy()
end

local function onEvent(e, character: Model)
	local name, arg = Net.decodeEvent(character:GetAttribute("SpiderEvent") or "")
	if not name then
		return
	end
	local d = e.driver
	if name == "Trick" then
		d:event("Trick", { name = arg })
	elseif name == "SwingStart" then
		d:event("SwingStart", { hand = arg })
	elseif name == "Jump" then
		d:event("Jump", { sprint = arg == "sprint" })
	elseif name == "WebFire" then
		local hand = if arg == "Left" then "Left" else "Right"
		d.ac:overlay(if hand == "Left" then "WebFireL" else "WebFireR", hand .. "Arm")
	else
		d:event(name, nil)
	end
end

local function attach(character: Model)
	if entries[character] then
		return
	end
	local humanoid = character:WaitForChild("Humanoid", 10)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if not humanoid or not root or not character.Parent then
		return
	end
	local driver = AnimDriver.new(character)
	if not driver then
		return
	end
	local e = { driver = driver, webs = WebVisuals.new(character), conns = {}, accum = 0, anchor = nil, zip = nil }
	entries[character] = e
	table.insert(e.conns, character:GetAttributeChangedSignal("SpiderEvent"):Connect(function()
		onEvent(e, character)
	end))
	table.insert(e.conns, character.AncestryChanged:Connect(function(_, parent)
		if not parent then
			cleanup(character)
		end
	end))
	table.insert(e.conns, humanoid.Died:Connect(function()
		cleanup(character)
	end))
end

local function syncWebs(e, character: Model)
	local anchor = character:GetAttribute("SwingAnchor")
	local hand = character:GetAttribute("SwingHand")
	if anchor ~= e.anchor then
		e.anchor = anchor
		if typeof(anchor) == "Vector3" then
			e.webs:fire(if hand == "Left" then "Left" else "Right", anchor, "swing")
		else
			e.webs:release("swing")
		end
	end
	local zip = character:GetAttribute("ZipTarget")
	if zip ~= e.zip then
		e.zip = zip
		if typeof(zip) == "Vector3" then
			e.webs:fire("Right", zip, "zipR")
			e.webs:fire("Left", zip, "zipL")
		else
			e.webs:release("zipR")
			e.webs:release("zipL")
		end
	end
end

function RemoteAnimator.start()
	local localPlayer = Players.LocalPlayer
	local function watch(player: Player)
		if player == localPlayer then
			return
		end
		if player.Character then
			task.spawn(attach, player.Character)
		end
		player.CharacterAdded:Connect(function(c)
			task.spawn(attach, c)
		end)
		player.CharacterRemoving:Connect(cleanup)
	end
	for _, p in Players:GetPlayers() do
		watch(p)
	end
	Players.PlayerAdded:Connect(watch)

	RunService.PreSimulation:Connect(function(dt)
		local cam = Workspace.CurrentCamera
		local camPos = if cam then cam.CFrame.Position else Vector3.zero
		for character, e in entries do
			local root = e.driver.root
			if not root.Parent then
				cleanup(character)
				continue
			end
			syncWebs(e, character)
			local dist = (root.Position - camPos).Magnitude
			if dist > Config.AnimCullDistance then
				e.accum = 0
				continue
			end
			e.accum += dt
			local interval = if dist > Config.AnimFullRateDistance then 1 / 30 else 0
			if e.accum >= interval then
				e.driver:step(e.accum, e.driver:remoteContext())
				e.accum = 0
			end
		end
	end)
end

return RemoteAnimator
