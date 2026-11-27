--[[
	ESPPermissions (Script — ServerScriptService)

	Decides who may use the ESP overlay by setting the "ESPAllowed" attribute
	on each Player. The client overlay starts/stops as the attribute changes,
	so other server code can grant or revoke it at any time, e.g.:

	    player:SetAttribute("ESPAllowed", true)   -- became a spectator / used a scan ability
	    player:SetAttribute("ESPAllowed", false)  -- back in the round

	Note: this is a UX gate, not anti-cheat. Positions of replicated characters
	are already on every client; this only controls who gets the overlay UI.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local PERMISSION_ATTRIBUTE = "ESPAllowed"

local SETTINGS = {
	AllowEveryone = false, -- true = every player gets the overlay
	AllowInStudio = true, -- everyone gets it during Studio playtests
	AllowOwner = true, -- the experience's owner (user, or group owner via Group below)

	-- Specific accounts
	UserIds = {
		-- 123456789,
	},

	-- Group ranks. Id = 0 uses the owning group when the experience is group-owned.
	Group = {
		Enabled = true,
		Id = 0,
		MinRank = 254,
	},
}

local function groupId(): number
	if SETTINGS.Group.Id ~= 0 then
		return SETTINGS.Group.Id
	end
	return if game.CreatorType == Enum.CreatorType.Group then game.CreatorId else 0
end

local function isAllowed(player: Player): boolean
	if SETTINGS.AllowEveryone then
		return true
	end
	if SETTINGS.AllowInStudio and RunService:IsStudio() then
		return true
	end
	if table.find(SETTINGS.UserIds, player.UserId) then
		return true
	end
	if SETTINGS.AllowOwner and game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId then
		return true
	end

	local id = groupId()
	if SETTINGS.Group.Enabled and id > 0 then
		-- GetRankInGroup is a web call: it yields and can fail
		local ok, rank = pcall(player.GetRankInGroup, player, id)
		if ok and rank >= SETTINGS.Group.MinRank then
			return true
		end
	end
	return false
end

local function onPlayerAdded(player: Player)
	-- don't overwrite a grant that other code made while we were checking
	local allowed = isAllowed(player)
	if player.Parent and player:GetAttribute(PERMISSION_ATTRIBUTE) == nil then
		player:SetAttribute(PERMISSION_ATTRIBUTE, allowed)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end
