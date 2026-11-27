--!strict
--[[
	Landing clips, chosen by impact speed and horizontal speed (see Motions/Ground):
	  LandCrouch  medium drop: absorb low, spring back up
	  LandHero    big drop, little momentum: the three-point superhero landing
	  LandRoll    big drop with momentum: shoulder roll that carries speed back into a run
]]

local ClipBuilder = require(script.Parent.Parent.ClipBuilder)
local Locomotion = require(script.Parent.Locomotion)
local B = ClipBuilder

local stand = Locomotion.StandPose
local clips = {}

local crouch = {
	Root = { -16, 0, 0, 0, -0.78, 0.04 }, Waist = { -12, 0, 0 }, Neck = { 16, 0, 0 },
	RightHip = { 72, -6, 12 }, RightKnee = { -104, 0, 0 }, RightAnkle = { 24, 0, 0 },
	LeftHip = { 70, 6, -12 }, LeftKnee = { -102, 0, 0 }, LeftAnkle = { 24, 0, 0 },
	RightShoulder = { 34, -10, 18 }, RightElbow = { 34, 10, 0 }, RightWrist = { 0, 0, 10 },
	LeftShoulder = { 32, 10, -18 }, LeftElbow = { 36, -10, 0 }, LeftWrist = { 0, 0, -10 },
}
table.insert(clips, B.clip({
	name = "LandCrouch",
	length = 0.62,
	keys = {
		{ 0.0, B.add(crouch, { Root = { 6, 0, 0, 0, 0.3, 0 } }), ease = "linear" },
		{ 0.08, B.add(crouch, { Root = { -3, 0, 0, 0, -0.1, 0 }, RightKnee = { -8, 0, 0 }, LeftKnee = { -8, 0, 0 } }) },
		{ 0.24, crouch },
		{ 0.62, stand, ease = "flat" },
	},
	hands = { R = { { 0, "Claw" }, { 0.35, "Relaxed", 0.2 } }, L = { { 0, "Claw" }, { 0.35, "Relaxed", 0.2 } } },
	events = { { 0.0, "LandHeavy" } },
}))

-- Superhero landing: right foot forward, left knee down, right fist planted, left arm out behind.
local hero = {
	Root = { -24, 10, 0, 0.06, -1.6, 0.16 },
	Waist = { -14, -8, 5 },
	Neck = { -24, 6, 0 },
	RightHip = { 94, -6, 22 }, RightKnee = { -114, 0, 0 }, RightAnkle = { 22, 0, 0 },
	LeftHip = { -4, 8, -12 }, LeftKnee = { -126, 0, 0 }, LeftAnkle = { -46, 0, 0 },
	RightShoulder = { 66, -12, 6 }, RightElbow = { 14, 0, 0 }, RightWrist = { 8, 0, 22 },
	LeftShoulder = { -26, 22, -70 }, LeftElbow = { 10, 0, 0 }, LeftWrist = { 0, 0, -14 },
}
local heroLook = B.add(hero, { Neck = { 40, -6, 0 }, Waist = { 6, 0, 0 }, Root = { 3, 0, 0, 0, 0.04, 0 } })
local heroRise = {
	Root = { -14, 4, 0, 0.03, -0.7, 0.06 }, Waist = { -6, -4, 2 }, Neck = { 10, 2, 0 },
	RightHip = { 70, -6, 14 }, RightKnee = { -86, 0, 0 }, RightAnkle = { 14, 0, 0 },
	LeftHip = { 20, 8, -10 }, LeftKnee = { -84, 0, 0 }, LeftAnkle = { -10, 0, 0 },
	RightShoulder = { 20, -6, 12 }, RightElbow = { 30, 0, 0 },
	LeftShoulder = { 4, 10, -26 }, LeftElbow = { 24, 0, 0 },
}
table.insert(clips, B.clip({
	name = "LandHero",
	length = 1.55,
	keys = {
		{ 0.0, B.add(hero, { Root = { 8, 0, 0, 0, 0.38, 0 }, RightShoulder = { -20, 0, 0 }, Neck = { 10, 0, 0 } }), ease = "linear" },
		{ 0.07, B.add(hero, { Root = { -4, 0, 0, 0, -0.08, 0 }, Waist = { -4, 0, 0 } }) },
		{ 0.22, hero },
		{ 0.55, B.add(hero, { Neck = { 6, 0, 0 } }), ease = "flat" },
		{ 0.85, heroLook, ease = "flat" },
		{ 1.12, heroRise },
		{ 1.55, stand, ease = "flat" },
	},
	hands = {
		R = { { 0, "Claw" }, { 0.06, "Fist", 0.06 }, { 1.0, "Relaxed", 0.3 } },
		L = { { 0, "Open" }, { 1.0, "Relaxed", 0.3 } },
	},
	events = { { 0.0, "LandHero" } },
}))

-- Shoulder roll (no foot IK; the body tumbles over the right shoulder and comes up running)
local tuckRoll = {
	Waist = { -40, 0, 0 }, Neck = { -42, 10, 0 },
	RightHip = { 118, -8, 10 }, RightKnee = { -140, 0, 0 }, RightAnkle = { -10, 0, 0 },
	LeftHip = { 112, 8, -12 }, LeftKnee = { -138, 0, 0 }, LeftAnkle = { -10, 0, 0 },
	RightShoulder = { 80, -30, 26 }, RightElbow = { 96, 10, 0 },
	LeftShoulder = { 70, 30, -18 }, LeftElbow = { 100, -10, 0 },
}
table.insert(clips, B.clip({
	name = "LandRoll",
	length = 0.8,
	keys = {
		{ 0.0, B.merge(crouch, { Root = { -34, 0, 0, 0, -1.0, 0 } }), ease = "linear" },
		{ 0.14, B.merge(tuckRoll, { Root = { -112, 8, -12, 0, -1.72, -0.28 } }) },
		{ 0.32, B.merge(tuckRoll, { Root = { -205, 10, -14, 0, -1.98, -0.5 } }) },
		{ 0.5, B.merge(B.lerp(tuckRoll, crouch, 0.35), { Root = { -292, 6, -8, 0, -1.78, -0.42 } }) },
		{ 0.65, B.merge(crouch, { Root = { -348, 2, 0, 0, -1.05, -0.18 } }) },
		{ 0.8, B.merge(B.lerp(crouch, stand, 0.6), { Root = { -364, 0, 0, 0, -0.28, 0 } }) },
	},
	hands = { R = { { 0, "Claw" }, { 0.1, "Fist", 0.08 }, { 0.6, "Relaxed", 0.15 } }, L = { { 0, "Claw" }, { 0.1, "Fist", 0.08 }, { 0.6, "Relaxed", 0.15 } } },
	events = { { 0.0, "LandRoll" } },
	meta = { noFootIK = true },
}))

return clips
