--[[
	Config
	Default settings for the ESP overlay. Every value here can be changed at
	runtime (the in-game menu writes straight into this table) and the overlay
	picks the change up on the next frame.
]]

local Config = {
	Enabled = true,

	-- Keybinds (keyboard). Touch devices get a floating button instead.
	-- (Avoid Shift keys: Roblox binds both Shifts to Shift Lock by default.)
	MenuKey = Enum.KeyCode.RightControl,
	ToggleKey = Enum.KeyCode.F4,

	-- Targeting
	MaxDistance = 1500, -- studs; anything farther is not drawn
	TeamCheck = false, -- true = hide players on your own team
	UseTeamColors = true, -- colour players by their Team colour when they have one
	HideDead = true,
	ShowPlayers = true,
	ShowTagged = true, -- models/parts tagged with `Tag` via CollectionService
	Tag = "ESPTarget",

	Font = Enum.Font.GothamMedium,
	DisplayOrder = 5,

	Box = {
		Enabled = true,
		Style = "Corner", -- "Corner" | "Full"
		Thickness = 1,
		CornerFraction = 0.28, -- length of a corner bracket relative to the box's short side
		Filled = false,
		FillTransparency = 0.82,
	},

	Name = {
		Enabled = true,
		Mode = "DisplayName", -- "DisplayName" | "Username" | "Both"
		TextSize = 13,
	},

	Distance = {
		Enabled = true,
		Unit = "Studs", -- "Studs" | "Meters" (1 stud = 0.28 m)
		TextSize = 12,
	},

	Tool = {
		Enabled = true, -- name of the Tool the target is holding
		TextSize = 12,
	},

	HealthBar = {
		Enabled = true,
		Width = 2,
		Gap = 4, -- pixels between the bar and the box
		ShowText = true, -- numeric health next to the bar while not at full health
		TextSize = 11,
		Smoothing = 12, -- higher = snappier bar animation
	},

	Tracer = {
		Enabled = false,
		Origin = "Bottom", -- "Bottom" | "Center" | "Top" | "Mouse"
		Thickness = 1,
	},

	Skeleton = {
		Enabled = false,
		Thickness = 1,
	},

	Chams = {
		Enabled = true, -- Roblox Highlight instances
		AlwaysOnTop = true,
		FillTransparency = 0.65,
		OutlineTransparency = 0,
		MaxCount = 31, -- Roblox renders at most 31 Highlights; the closest targets win
	},

	Arrows = {
		Enabled = true, -- arrows around the crosshair for targets that are off-screen
		Radius = 0.22, -- fraction of the shorter screen side
		Size = 12,
		Thickness = 2,
	},

	Visibility = {
		Enabled = true, -- raycast line-of-sight check
		Interval = 0.12, -- seconds between checks per target
		OccludedOpacity = 0.55, -- opacity multiplier for targets behind walls
	},

	Fade = {
		Enabled = true, -- fade visuals out toward MaxDistance
		Start = 0.55, -- fraction of MaxDistance where fading begins
		MinOpacity = 0.3,
	},

	Colors = {
		Enemy = Color3.fromRGB(255, 72, 96),
		Ally = Color3.fromRGB(72, 190, 255),
		Friend = Color3.fromRGB(110, 255, 150),
		Tagged = Color3.fromRGB(255, 196, 64),
		Text = Color3.fromRGB(240, 242, 250),
		SubText = Color3.fromRGB(190, 195, 210),
		Outline = Color3.fromRGB(0, 0, 0),
		HealthHigh = Color3.fromRGB(96, 255, 128),
		HealthMid = Color3.fromRGB(255, 214, 64),
		HealthLow = Color3.fromRGB(255, 64, 64),
	},
}

return Config
