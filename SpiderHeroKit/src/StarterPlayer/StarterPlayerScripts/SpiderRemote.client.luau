--[[
	Animates every other player's hero on this client (see SpiderKit.Client.RemoteAnimator).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Kit = ReplicatedStorage:WaitForChild("SpiderKit")
require(Kit:WaitForChild("Client"):WaitForChild("RemoteAnimator")).start()
