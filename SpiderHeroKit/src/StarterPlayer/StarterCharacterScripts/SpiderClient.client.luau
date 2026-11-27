--[[
	Starts the hero controller for the local character (copied into the character on spawn).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Kit = ReplicatedStorage:WaitForChild("SpiderKit")
local SpiderController = require(Kit:WaitForChild("Client"):WaitForChild("SpiderController"))

SpiderController.new(script.Parent)
