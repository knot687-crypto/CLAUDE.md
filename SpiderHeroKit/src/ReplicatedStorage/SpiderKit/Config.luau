--!strict
--[[
	SpiderKit tunables. Everything gameplay-facing lives here.
]]

local Config = {
	-- ground
	RunSpeed = 24,
	SprintSpeed = 38,
	JumpPower = 66,
	SprintJumpBoost = 1.18, -- multiplier on jump power while sprinting
	AirControl = 55, -- studs/s^2 toward input while airborne
	DiveAccel = 30, -- extra downward pull while diving (falling fast with input forward)

	-- web swing
	SwingRange = 140, -- max anchor distance
	SwingIdealAhead = 58, -- where an ideal anchor sits ahead of the player
	SwingIdealUp = 62, -- ... and above
	SwingIdealSide = 12, -- ... and to the side (alternates hands)
	SwingMinHeight = 14, -- anchors must be at least this far above the player
	AllowSkySwing = true, -- if no building is found, attach to a virtual anchor
	SwingAutoReleaseAngle = 62, -- degrees past the anchor
	SwingTrickSpeed = 72, -- release faster than this on the rise to trigger a flourish
	Tricks = { "FrontFlip", "Corkscrew", "Backflip", "Cartwheel", "Swan" },

	-- web zip / point launch
	ZipRange = 230,
	ZipSpeed = 115,
	ZipLaunchBoost = Vector3.new(0, 70, 0),

	-- wall
	WallCrawlSpeed = 4.5,
	WallRunSpeed = 34,
	WallDetectDistance = 2.6,
	WallJumpVelocity = Vector3.new(0, 52, 0), -- plus the wall normal * WallJumpOut
	WallJumpOut = 46,
	WallMaxNormalY = 0.45, -- surfaces steeper than this are walls

	-- landings
	HeroLandingMinImpact = 120,

	-- camera
	BaseFov = 70,
	MaxFov = 92,
	FovSpeedStart = 40,
	FovSpeedFull = 150,
	SwingRoll = 7, -- degrees of camera roll leaning into swings

	-- animation LOD for other characters (distance in studs)
	AnimFullRateDistance = 120,
	AnimCullDistance = 500,

	-- web visuals
	WebColor = Color3.fromRGB(242, 244, 250),
	WebWidth = 0.11,

	-- optional sound asset ids (leave empty to skip). Built-in engine sounds are used for wind/jump/land.
	Sounds = {
		WebShot = "", -- e.g. "rbxassetid://<your upload>"
		WebZip = "",
		Wind = "rbxasset://sounds/action_falling.mp3",
		Jump = "rbxasset://sounds/action_jump.mp3",
		Land = "rbxasset://sounds/action_jump_land.mp3",
		Footstep = "rbxasset://sounds/action_footsteps_plastic.mp3",
	},
}

return Config
