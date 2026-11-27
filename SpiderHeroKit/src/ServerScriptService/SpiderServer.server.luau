--!strict
--[[
	SpiderServer: relays each hero's movement state to everyone.
	Clients simulate their own character (they own its physics); this script validates what they
	report and publishes it as character attributes, which the engine replicates to all clients'
	RemoteAnimators. A token bucket caps each player's message rate.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage:WaitForChild("SpiderKit"):WaitForChild("Net"))

local remote = Net.remote(true)

local RATE = 40 -- messages per second
local BURST = 60

type Bucket = { tokens: number, t: number }
local buckets: { [Player]: Bucket } = {}
local sequence: { [Player]: number } = {}

local function allow(player: Player): boolean
	local now = os.clock()
	local b = buckets[player]
	if not b then
		b = { tokens = BURST, t = now }
		buckets[player] = b
	end
	b.tokens = math.min(BURST, b.tokens + (now - b.t) * RATE)
	b.t = now
	if b.tokens < 1 then
		return false
	end
	b.tokens -= 1
	return true
end

remote.OnServerEvent:Connect(function(player: Player, payload: any)
	if not allow(player) then
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not root or not root:IsA("BasePart") then
		return
	end
	local p = Net.sanitize(payload, root.Position)
	if not p then
		return
	end
	if p.k == "s" then
		character:SetAttribute("SpiderState", p.state)
		character:SetAttribute("SwingAnchor", p.anchor)
		character:SetAttribute("SwingHand", p.hand)
		character:SetAttribute("ZipTarget", p.zip)
		character:SetAttribute("WallNormal", p.normal)
		character:SetAttribute("Sprint", p.sprint)
	else
		local n = (sequence[player] or 0) + 1
		sequence[player] = n
		character:SetAttribute("SpiderEvent", Net.encodeEvent(p.name, p.arg, n))
	end
end)

Players.PlayerRemoving:Connect(function(player)
	buckets[player] = nil
	sequence[player] = nil
end)
