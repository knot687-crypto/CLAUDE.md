--[[
	ESPClient (LocalScript — StarterPlayer > StarterPlayerScripts)

	Boots the overlay and its settings menu. The overlay only runs while the
	server has set the player's "ESPAllowed" attribute to true (see
	ServerScriptService > ESPPermissions), so you decide who gets it:
	admins, spectators, a gameplay ability, everyone in Studio, ...
]]

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local Config = require(script.Config)
local Controller = require(script.Controller)
local Menu = require(script.Menu)

local PERMISSION_ATTRIBUTE = "ESPAllowed"

local player = Players.LocalPlayer
local esp = Controller.new(Config)
local menu = Menu.new(Config, esp)

local function notify(text: string)
	task.spawn(function()
		-- SetCore isn't ready until the core scripts load, so retry briefly
		for _ = 1, 5 do
			local ok = pcall(StarterGui.SetCore, StarterGui, "SendNotification", {
				Title = "ESP",
				Text = text,
				Duration = 3,
			})
			if ok then
				return
			end
			task.wait(1)
		end
	end)
end

local function isAllowed(): boolean
	return player:GetAttribute(PERMISSION_ATTRIBUTE) == true
end

local wasAllowed = false
local function applyPermission()
	local allowed = isAllowed()
	if allowed == wasAllowed then
		return
	end
	wasAllowed = allowed

	if allowed then
		esp:Start()
		menu:SetAvailable(true)
		if UserInputService.KeyboardEnabled then
			notify(`Press {Config.MenuKey.Name} for settings, {Config.ToggleKey.Name} to toggle.`)
		else
			notify("Tap the ESP button for settings.")
		end
	else
		menu:SetAvailable(false)
		esp:Stop()
	end
end

player:GetAttributeChangedSignal(PERMISSION_ATTRIBUTE):Connect(applyPermission)
applyPermission()

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	-- gameProcessed is true while typing in chat or a TextBox
	if gameProcessed or not isAllowed() then
		return
	end
	if input.KeyCode == Config.MenuKey then
		menu:Toggle()
	elseif input.KeyCode == Config.ToggleKey then
		esp:SetEnabled(not Config.Enabled)
		menu:Refresh()
		notify(if Config.Enabled then "Overlay on" else "Overlay off")
	end
end)
