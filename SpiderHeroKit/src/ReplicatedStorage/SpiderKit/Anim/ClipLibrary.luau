--!strict
--[[
	ClipLibrary
	-----------
	Loads and compiles every clip module under Anim/Clips once, and exposes them by name.
	Clip modules return an array of raw clips; extra named entries (e.g. StandPose) are shared
	pose tables available through ClipLibrary.poses.
]]

local Clip = require(script.Parent.Clip)

local ClipLibrary = {}

local cache: { [string]: Clip.Clip }? = nil
local poses: { [string]: any } = {}

function ClipLibrary.get(): { [string]: Clip.Clip }
	if cache then
		return cache
	end
	local lib: { [string]: Clip.Clip } = {}
	local folder = script.Parent.Clips
	local mods = folder:GetChildren()
	table.sort(mods, function(a, b)
		return a.Name < b.Name
	end)
	for _, m in mods do
		if m:IsA("ModuleScript") then
			local list = require(m) :: any
			for key, value in list do
				if type(key) == "number" then
					local compiled = Clip.compile(value)
					assert(lib[compiled.name] == nil, "duplicate clip name " .. compiled.name)
					lib[compiled.name] = compiled
				else
					poses[key] = value
				end
			end
		end
	end
	cache = lib
	return lib
end

function ClipLibrary.clip(name: string): Clip.Clip
	local lib = ClipLibrary.get()
	local c = lib[name]
	assert(c, "unknown clip " .. name)
	return c
end

function ClipLibrary.poses(): { [string]: any }
	ClipLibrary.get()
	return poses
end

return ClipLibrary
