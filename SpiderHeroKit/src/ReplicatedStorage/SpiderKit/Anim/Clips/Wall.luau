--!strict
--[[
	Wall clips. WallIdle is the crawl body (torso hugging the wall, head up, limbs splayed; the gait
	IK places the hands and feet). LedgeVault pulls up and over an edge. WallJump kicks off a wall
	into a back-tuck.
	Frame: the HumanoidRootPart faces the wall (wall in front, at z = -0.62), up = wall "up".
]]

local ClipBuilder = require(script.Parent.Parent.ClipBuilder)
local Locomotion = require(script.Parent.Locomotion)
local B = ClipBuilder

local stand = Locomotion.StandPose
local clips = {}

local cling = {
	Root = { -5, 0, 0, 0, 0.06, -0.05 }, Waist = { -9, 0, 0 }, Neck = { 30, 0, 0 },
	RightShoulder = { 150, -10, 34 }, RightElbow = { 70, 0, 0 }, RightWrist = { -10, 0, 20 },
	LeftShoulder = { 150, 10, -34 }, LeftElbow = { 70, 0, 0 }, LeftWrist = { -10, 0, -20 },
	RightHip = { 84, -24, 48 }, RightKnee = { -118, 0, 0 }, RightAnkle = { 12, 0, 0 },
	LeftHip = { 84, 24, -48 }, LeftKnee = { -118, 0, 0 }, LeftAnkle = { 12, 0, 0 },
}
clips.ClingPose = cling
table.insert(clips, B.loop({
	name = "WallIdle",
	length = 3.6,
	keys = {
		{ 0, cling },
		{ 0.9, B.add(cling, { Waist = { -1.8, 0, 0 }, Root = { 0, 0, 0, 0, 0.012, 0.012 }, Neck = { -2, 4, 0 } }) },
		{ 1.8, B.add(cling, { Neck = { 4, -8, 0 }, Waist = { 0, -2, 0 } }) },
		{ 2.7, B.add(cling, { Waist = { -1.8, 0, 0 }, Root = { 0, 0, 0, 0, 0.012, 0.012 }, Neck = { 2, 6, 0 } }) },
	},
	hands = { R = { { 0, "Splay" } }, L = { { 0, "Splay" } } },
}))

-- Pull-up and vault over a ledge (the controller moves the root up and forward over 0.62 s)
local hang = B.merge(cling, { RightShoulder = { 150, 0, 22 }, LeftShoulder = { 150, 0, -22 }, RightElbow = { 30, 0, 0 }, LeftElbow = { 30, 0, 0 }, Neck = { 22, 0, 0 } })
local pull = {
	Root = { -28, 0, 0, 0, -0.1, 0 }, Waist = { -20, 0, 0 }, Neck = { 24, 0, 0 },
	RightShoulder = { 30, 0, 22 }, RightElbow = { 110, 0, 0 }, LeftShoulder = { 30, 0, -22 }, LeftElbow = { 110, 0, 0 },
	RightHip = { 100, -10, 20 }, RightKnee = { -120, 0, 0 }, LeftHip = { 60, 10, -16 }, LeftKnee = { -90, 0, 0 },
}
local vault = {
	Root = { -32, 6, 0, 0, -0.55, 0 }, Waist = { -16, 4, 0 }, Neck = { 30, -4, 0 },
	RightShoulder = { -10, 0, 30 }, RightElbow = { 20, 0, 0 }, LeftShoulder = { -10, 0, -30 }, LeftElbow = { 20, 0, 0 },
	RightHip = { 110, -10, 26 }, RightKnee = { -132, 0, 0 }, RightAnkle = { 20, 0, 0 },
	LeftHip = { 96, 10, -22 }, LeftKnee = { -128, 0, 0 }, LeftAnkle = { 20, 0, 0 },
}
table.insert(clips, B.clip({
	name = "LedgeVault",
	length = 0.66,
	keys = {
		{ 0.0, hang, ease = "linear" },
		{ 0.16, pull },
		{ 0.36, vault },
		{ 0.66, B.lerp(vault, stand, 0.75) },
	},
	hands = { R = { { 0, "Grip" }, { 0.3, "Splay", 0.08 }, { 0.5, "Relaxed", 0.15 } }, L = { { 0, "Grip" }, { 0.3, "Splay", 0.08 }, { 0.5, "Relaxed", 0.15 } } },
	events = { { 0.14, "LedgePull" }, { 0.4, "LandSoft" } },
}))

-- Kick off the wall into a back-tuck (Air mode one-shot)
local tuck = {
	Waist = { -28, 0, 0 }, Neck = { -14, 0, 0 },
	RightHip = { 116, -8, 10 }, RightKnee = { -140, 0, 0 }, LeftHip = { 114, 8, -10 }, LeftKnee = { -138, 0, 0 },
	RightShoulder = { 64, -20, 14 }, RightElbow = { 94, 10, 0 }, LeftShoulder = { 64, 20, -14 }, LeftElbow = { 94, -10, 0 },
}
local airOpen = Locomotion.StandPose
table.insert(clips, B.clip({
	name = "WallJump",
	length = 0.72,
	keys = {
		{ 0.0, B.merge(cling, { Root = { -20, 0, 0 } }), ease = "linear" },
		{ 0.1, B.merge(B.lerp(cling, tuck, 0.3), { Root = { 40, 0, 0, 0, 0.1, 0 }, RightHip = { 20, 0, 10 }, LeftHip = { 20, 0, -10 }, RightKnee = { -20, 0, 0 }, LeftKnee = { -20, 0, 0 } }) },
		{ 0.3, B.merge(tuck, { Root = { 190, 0, 0, 0, 0.12, 0 } }) },
		{ 0.5, B.merge(B.lerp(tuck, airOpen, 0.5), { Root = { 300, 0, 0, 0, 0.05, 0 } }) },
		{ 0.72, B.merge(airOpen, { Root = { 360, 0, 0 } }) },
	},
	hands = { R = { { 0, "Splay" }, { 0.12, "Fist", 0.08 }, { 0.5, "Open", 0.12 } }, L = { { 0, "Splay" }, { 0.12, "Fist", 0.08 }, { 0.5, "Open", 0.12 } } },
	events = { { 0.04, "WallKick" } },
}))

return clips
