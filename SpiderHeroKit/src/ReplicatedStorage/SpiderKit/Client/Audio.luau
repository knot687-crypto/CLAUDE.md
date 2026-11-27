--!strict
--[[
	Audio: wind that swells with speed, footsteps keyed to the animation's foot events, jumps,
	landings scaled by impact, and optional web-shot/zip sounds (set their ids in Config.Sounds).
]]

local Config = require(script.Parent.Parent.Config)
local Spring = require(script.Parent.Parent.Math.Spring)

local Audio = {}
Audio.__index = Audio

export type Sfx = typeof(setmetatable({} :: {
	root: BasePart,
	sounds: { [string]: Sound },
	wind: Sound?,
	windVol: number,
}, Audio))

local function smoothstep(a: number, b: number, x: number): number
	local t = math.clamp((x - a) / (b - a), 0, 1)
	return t * t * (3 - 2 * t)
end

function Audio.new(root: BasePart): Sfx
	local self = setmetatable({ root = root, sounds = {}, wind = nil, windVol = 0 }, Audio)
	for name, id in Config.Sounds :: { [string]: string } do
		if id ~= "" then
			local s = Instance.new("Sound")
			s.Name = "Spider" .. name
			s.SoundId = id
			s.Volume = 0.6
			s.RollOffMaxDistance = 220
			s.Parent = root
			self.sounds[name] = s
		end
	end
	local wind = self.sounds.Wind
	if wind then
		wind.Looped = true
		wind.Volume = 0
		wind:Play()
		self.wind = wind
	end
	return self
end

function Audio.play(self: Sfx, name: string, volume: number?, pitch: number?)
	local s = self.sounds[name]
	if not s then
		return
	end
	s.Volume = volume or 0.6
	s.PlaybackSpeed = pitch or 1
	s.TimePosition = 0
	s:Play()
end

-- speed in studs/s; airborne = true while not on the ground
function Audio.update(self: Sfx, dt: number, speed: number, airborne: boolean)
	local w = self.wind
	if w then
		local target = smoothstep(35, 150, speed) * (if airborne then 0.75 else 0.3)
		self.windVol = Spring.damp(self.windVol, target, 0.2, dt)
		w.Volume = self.windVol
		w.PlaybackSpeed = 0.75 + math.clamp(speed / 260, 0, 0.6)
	end
end

-- animation/gameplay events -> sounds
function Audio.onEvent(self: Sfx, name: string, data: any?)
	if name == "FootL" or name == "FootR" then
		self:play("Footstep", 0.35, 0.95 + math.random() * 0.12)
	elseif name == "Jump" or name == "WallJump" or name == "JumpPush" or name == "WallKick" then
		self:play("Jump", 0.5, 1.0 + math.random() * 0.08)
	elseif name == "Land" then
		local impact = if type(data) == "table" and type(data.impact) == "number" then data.impact else 40
		self:play("Land", math.clamp(impact / 140, 0.25, 1), 1.05 - math.clamp(impact / 600, 0, 0.25))
	elseif name == "WebShotR" or name == "WebShotL" or name == "SwingStart" or name == "WebFire" then
		self:play("WebShot", 0.55, 0.95 + math.random() * 0.1)
	elseif name == "Zip" then
		self:play("WebZip", 0.6, 1)
	end
end

function Audio.destroy(self: Sfx)
	for _, s in self.sounds do
		s:Destroy()
	end
	table.clear(self.sounds)
	self.wind = nil
end

return Audio
