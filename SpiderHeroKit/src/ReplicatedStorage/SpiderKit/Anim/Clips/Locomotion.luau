--!strict
--[[
	Locomotion clips: idle (+ idle breaks), walk, run, sprint, sprint skid-stop, perch.

	Values are Motor6D.Transform Euler XYZ in degrees (see RigDefinition for axis conventions);
	Root translation in studs. Gait cycles are authored pose-to-pose for the first half
	(right foot contact -> left foot contact) and mirrored for the second half.

	Speeds are the authored ground speeds (studs/s); the runtime syncs playback rate to the
	character's real speed so the feet plant without sliding.
]]

local ClipBuilder = require(script.Parent.Parent.ClipBuilder)
local B = ClipBuilder

local clips = {}

--------------------------------------------------------------------------------------------------
-- Idle: relaxed heroic stance with contrapposto weight on the right leg, slow breathing and a
-- gentle weight drift. 4.8 s loop so it never reads as a short repeating pulse.
--------------------------------------------------------------------------------------------------
local stand = {
	Root = { 0, 0, 1.5, 0.035, -0.01, 0 },
	Waist = { 2, -2, -2.5 },
	Neck = { -2, 3, 0.5 },
	RightHip = { 1, -6, -1.5 },
	RightKnee = { -4, 0, 0 },
	RightAnkle = { 3, 0, 0 },
	LeftHip = { 6, 9, -4 },
	LeftKnee = { -13, 0, 0 },
	LeftAnkle = { 5, 0, 1.5 },
	RightShoulder = { 3, -8, 7 },
	RightElbow = { 14, 6, 0 },
	RightWrist = { 2, 0, -6 },
	LeftShoulder = { 5, 6, -6 },
	LeftElbow = { 17, -6, 0 },
	LeftWrist = { 2, 0, 7 },
}
clips.StandPose = stand

local inhale = B.add(stand, {
	Root = { 0, 0, 0.3, 0.008, 0.012, 0 },
	Waist = { 1.6, 0.5, -0.4 },
	Neck = { -1.2, 0.8, 0 },
	RightShoulder = { 0, 0, 1.6 },
	LeftShoulder = { 0, 0, -1.6 },
	RightElbow = { 1.5, 0, 0 },
	LeftElbow = { 1.5, 0, 0 },
})
local shift = B.add(stand, {
	Root = { 0, 0.6, -0.4, -0.012, -0.012, 0 },
	Waist = { 0.4, -0.8, 0.6 },
	Neck = { 0, -2.5, -0.6 },
	RightHip = { 0.5, 0, 0.4 },
	LeftHip = { -0.8, 0, 0.6 },
	LeftKnee = { 1.5, 0, 0 },
	RightKnee = { -1.2, 0, 0 },
})
local inhale2 = B.add(shift, {
	Root = { 0, 0, 0.2, 0.004, 0.012, 0 },
	Waist = { 1.5, 0, -0.2 },
	Neck = { -1.4, -1, 0 },
	RightShoulder = { 0, 0, 1.5 },
	LeftShoulder = { 0, 0, -1.5 },
})

table.insert(clips, B.loop({
	name = "Idle",
	length = 4.8,
	keys = {
		{ 0.0, stand },
		{ 1.2, inhale },
		{ 2.4, shift },
		{ 3.6, inhale2 },
	},
	hands = { R = { { 0, "Relaxed" } }, L = { { 0, "Relaxed" } } },
}))

-- Idle break: scan the skyline (turn head and chest to the left, then right, settle)
table.insert(clips, B.clip({
	name = "IdleLook",
	length = 3.4,
	keys = {
		{ 0.0, stand, ease = "flat" },
		{ 0.55, B.add(stand, { Waist = { 1, 9, 0 }, Neck = { 4, 34, 2 }, Root = { 0, 4, 0 } }) },
		{ 1.25, B.add(stand, { Waist = { 1.5, 11, 0 }, Neck = { 6, 40, 3 }, Root = { 0, 5, 0 } }), ease = "flat" },
		{ 1.9, B.add(stand, { Waist = { 0, -8, 0 }, Neck = { -6, -30, -2 }, Root = { 0, -4, 0 } }) },
		{ 2.6, B.add(stand, { Waist = { 0, -10, 0 }, Neck = { -4, -36, -3 }, Root = { 0, -5, 0 } }), ease = "flat" },
		{ 3.4, stand, ease = "flat" },
	},
	hands = { R = { { 0, "Relaxed" } }, L = { { 0, "Relaxed" } } },
}))

-- Idle break: roll the shoulders and stretch the neck
table.insert(clips, B.clip({
	name = "IdleStretch",
	length = 3.0,
	keys = {
		{ 0.0, stand, ease = "flat" },
		{ 0.5, B.add(stand, { Neck = { 4, 0, 26 }, Waist = { 2, 0, 4 }, RightShoulder = { -4, 0, 5 }, LeftShoulder = { 3, 0, -2 } }) },
		{ 0.95, B.add(stand, { Neck = { 6, 0, 30 }, Waist = { 2, 0, 5 } }), ease = "flat" },
		{ 1.45, B.add(stand, { Neck = { 4, 0, -24 }, Waist = { 1, 0, -4 }, LeftShoulder = { -4, 0, -5 } }) },
		{ 1.9, B.add(stand, { Neck = { 6, 0, -28 }, Waist = { 1, 0, -5 } }), ease = "flat" },
		{ 2.35, B.add(stand, { Neck = { -10, 0, 0 }, RightShoulder = { 6, 0, 3 }, LeftShoulder = { 6, 0, -3 }, Waist = { 4, 0, 0 } }) },
		{ 3.0, stand, ease = "flat" },
	},
	hands = { R = { { 0, "Relaxed" } }, L = { { 0, "Relaxed" } } },
}))

-- Idle break: check the right web-shooter, test the trigger twice
local check = B.add(stand, {
	RightShoulder = { 38, -40, 18 },
	RightElbow = { 105, 40, 0 },
	RightWrist = { -6, 0, 18 },
	Neck = { -18, 18, 2 },
	Waist = { 0, 8, 0 },
})
table.insert(clips, B.clip({
	name = "IdleShooter",
	length = 3.2,
	keys = {
		{ 0.0, stand, ease = "flat" },
		{ 0.55, check },
		{ 0.95, B.add(check, { RightWrist = { 0, 0, 22 } }), ease = "flat" },
		{ 1.15, B.add(check, { RightWrist = { 0, 0, 38 } }) },
		{ 1.35, B.add(check, { RightWrist = { 0, 0, 20 } }) },
		{ 1.75, B.add(check, { RightWrist = { 0, 0, 38 } }) },
		{ 2.0, B.add(check, { RightWrist = { 0, 0, 18 } }), ease = "flat" },
		{ 2.6, B.add(stand, { RightElbow = { 10, 0, 0 } }) },
		{ 3.2, stand, ease = "flat" },
	},
	hands = {
		R = { { 0, "Relaxed" }, { 0.55, "Open", 0.2 }, { 1.05, "Thwip", 0.08 }, { 1.3, "Open", 0.1 }, { 1.65, "Thwip", 0.08 }, { 1.95, "Relaxed", 0.25 } },
		L = { { 0, "Relaxed" } },
	},
	events = { { 1.12, "ThwipR" }, { 1.72, "ThwipR" } },
}))

--------------------------------------------------------------------------------------------------
-- Walk: 0.92 s cycle at 7 studs/s. Heel strike -> loading -> passing -> heel-off.
--------------------------------------------------------------------------------------------------
local W = 0.92
table.insert(clips, B.cycle({
	name = "Walk",
	length = W,
	speed = 4.6,
	half = {
		{ 0.0, {
			Root = { -3, 5, 0, 0, -0.06, 0 }, Waist = { 1.5, -7, 0 }, Neck = { 1.5, 2, 0 },
			RightHip = { 26, -3, 0 }, RightKnee = { -2, 0, 0 }, RightAnkle = { 13, 0, 0 },
			LeftHip = { -14, 3, 0 }, LeftKnee = { -27, 0, 0 }, LeftAnkle = { -12, 0, 0 },
			RightShoulder = { -17, -4, 7 }, RightElbow = { 16, 4, 0 }, RightWrist = { 0, 0, -4 },
			LeftShoulder = { 20, 4, -5 }, LeftElbow = { 30, -4, 0 }, LeftWrist = { 0, 0, 4 },
		} },
		{ 0.1, {
			Root = { -4, 3, 2, 0.01, -0.06, 0 }, Waist = { 2, -5, -2 }, Neck = { 2.5, 1.5, 0.5 },
			RightHip = { 18, -3, 0 }, RightKnee = { -17, 0, 0 }, RightAnkle = { 3, 0, 0 },
			LeftHip = { -7, 3, 0 }, LeftKnee = { -44, 0, 0 }, LeftAnkle = { -16, 0, 0 },
			RightShoulder = { -12, -4, 7 }, RightElbow = { 17, 4, 0 },
			LeftShoulder = { 15, 4, -5 }, LeftElbow = { 29, -4, 0 },
		} },
		{ 0.23, {
			Root = { -3, 0, 3, 0.02, -0.02, 0 }, Waist = { 1.5, 0, -2.5 }, Neck = { 1.5, 0, 0.5 },
			RightHip = { 2, -2, 0 }, RightKnee = { -8, 0, 0 }, RightAnkle = { 6, 0, 0 },
			LeftHip = { 17, 2, 0 }, LeftKnee = { -60, 0, 0 }, LeftAnkle = { -5, 0, 0 },
			RightShoulder = { 0, -4, 7 }, RightElbow = { 16, 4, 0 },
			LeftShoulder = { 0, 4, -6 }, LeftElbow = { 22, -4, 0 },
		} },
		{ 0.34, {
			Root = { -3, -3, 1, 0.01, 0.07, 0 }, Waist = { 1.5, 4, -1 }, Neck = { 1.5, -1, 0 },
			RightHip = { -10, -3, 0 }, RightKnee = { -7, 0, 0 }, RightAnkle = { -5, 0, 0 },
			LeftHip = { 28, 3, 0 }, LeftKnee = { -27, 0, 0 }, LeftAnkle = { 5, 0, 0 },
			RightShoulder = { 12, -4, 7 }, RightElbow = { 24, 4, 0 },
			LeftShoulder = { -12, 4, -6 }, LeftElbow = { 17, -4, 0 },
		} },
	},
	hands = { R = { { 0, "Relaxed" } }, L = { { 0, "Relaxed" } } },
	events = { { 0.0, "FootR" }, { W / 2, "FootL" } },
}))

--------------------------------------------------------------------------------------------------
-- Run: athletic, low and springy. 0.66 s cycle at 20 studs/s.
-- contact -> down (max compression) -> push-off -> flight (peak)
--------------------------------------------------------------------------------------------------
local R = 0.66
table.insert(clips, B.cycle({
	name = "Run",
	length = R,
	speed = 20,
	half = {
		{ 0.0, {
			Root = { -10, 6, 0, 0, -0.12, 0 }, Waist = { 2, -10, -1 }, Neck = { 8, 4, 0 },
			RightHip = { 38, -3, 2 }, RightKnee = { -16, 0, 0 }, RightAnkle = { 8, 0, 0 },
			LeftHip = { -30, 3, -2 }, LeftKnee = { -62, 0, 0 }, LeftAnkle = { -26, 0, 0 },
			RightShoulder = { -36, -6, 9 }, RightElbow = { 78, 10, 0 }, RightWrist = { 0, 0, -6 },
			LeftShoulder = { 46, 10, -6 }, LeftElbow = { 104, -10, 0 }, LeftWrist = { 0, 0, 6 },
		} },
		{ 0.075, {
			Root = { -11, 3, 3, 0, -0.155, 0 }, Waist = { 3, -6, -3 }, Neck = { 9, 2, 0.5 },
			RightHip = { 19, -3, 1 }, RightKnee = { -40, 0, 0 }, RightAnkle = { 18, 0, 0 },
			LeftHip = { -6, 3, -1 }, LeftKnee = { -98, 0, 0 }, LeftAnkle = { -16, 0, 0 },
			RightShoulder = { -17, -6, 9 }, RightElbow = { 84, 10, 0 },
			LeftShoulder = { 26, 8, -6 }, LeftElbow = { 100, -10, 0 },
		} },
		{ 0.115, {
			Root = { -10.5, 0.5, 2, 0, -0.17, 0 }, Waist = { 2.5, -3, -2 }, Neck = { 8.5, 1, 0 },
			RightHip = { 1, -3, 0.5 }, RightKnee = { -34, 0, 0 }, RightAnkle = { 8, 0, 0 },
			LeftHip = { 20, 3, -0.5 }, LeftKnee = { -106, 0, 0 }, LeftAnkle = { -11, 0, 0 },
			RightShoulder = { 0, -7, 8.5 }, RightElbow = { 90, 10, 0 },
			LeftShoulder = { 7, 7, -6.5 }, LeftElbow = { 92, -10, 0 },
		} },
		{ 0.155, {
			Root = { -10, -2, 1, 0, -0.14, 0 }, Waist = { 2, 0, -1 }, Neck = { 8, 0, 0 },
			RightHip = { -21, -3, 0 }, RightKnee = { -12, 0, 0 }, RightAnkle = { -30, 0, 0 },
			LeftHip = { 42, 3, 0 }, LeftKnee = { -102, 0, 0 }, LeftAnkle = { -6, 0, 0 },
			RightShoulder = { 16, -8, 8 }, RightElbow = { 96, 10, 0 },
			LeftShoulder = { -12, 6, -7 }, LeftElbow = { 84, -10, 0 },
		} },
		{ 0.235, {
			Root = { -9, -5, 0, 0, 0.09, 0 }, Waist = { 2, 7, 0 }, Neck = { 8, -2, 0 },
			RightHip = { -29, -3, -1 }, RightKnee = { -48, 0, 0 }, RightAnkle = { -31, 0, 0 },
			LeftHip = { 51, 3, 1 }, LeftKnee = { -80, 0, 0 }, LeftAnkle = { 1, 0, 0 },
			RightShoulder = { 41, -10, 7 }, RightElbow = { 104, 10, 0 },
			LeftShoulder = { -33, 6, -8 }, LeftElbow = { 76, -10, 0 },
		} },
	},
	hands = { R = { { 0, "Fist" } }, L = { { 0, "Fist" } } },
	events = { { 0.0, "FootR" }, { R / 2, "FootL" } },
}))

--------------------------------------------------------------------------------------------------
-- Sprint: aggressive forward lean, big knee drive, blade hands pumping. 0.5 s cycle at 34 studs/s.
--------------------------------------------------------------------------------------------------
local S = 0.5
table.insert(clips, B.cycle({
	name = "Sprint",
	length = S,
	speed = 31,
	half = {
		{ 0.0, {
			Root = { -17, 8, 0, 0, -0.14, 0 }, Waist = { 1, -14, -1 }, Neck = { 17, 6, 0 },
			RightHip = { 44, -3, 2 }, RightKnee = { -24, 0, 0 }, RightAnkle = { 6, 0, 0 },
			LeftHip = { -36, 3, -2 }, LeftKnee = { -72, 0, 0 }, LeftAnkle = { -32, 0, 0 },
			RightShoulder = { -48, -8, 10 }, RightElbow = { 72, 12, 0 }, RightWrist = { 4, 0, 0 },
			LeftShoulder = { 64, 14, -8 }, LeftElbow = { 98, -12, 0 }, LeftWrist = { 4, 0, 0 },
		} },
		{ 0.04, {
			Root = { -18, 4, 3, 0, -0.16, 0 }, Waist = { 2, -8, -3 }, Neck = { 18, 3, 0.5 },
			RightHip = { 24, -3, 1 }, RightKnee = { -44, 0, 0 }, RightAnkle = { 17, 0, 0 },
			LeftHip = { -8, 3, -1 }, LeftKnee = { -118, 0, 0 }, LeftAnkle = { -22, 0, 0 },
			RightShoulder = { -26, -8, 10 }, RightElbow = { 80, 12, 0 },
			LeftShoulder = { 42, 12, -8 }, LeftElbow = { 104, -12, 0 },
		} },
		{ 0.068, {
			Root = { -17.5, 0.5, 2, 0, -0.2, 0 }, Waist = { 1.5, -4, -2 }, Neck = { 17.5, 1.5, 0 },
			RightHip = { 0, -3, 0.5 }, RightKnee = { -36, 0, 0 }, RightAnkle = { 9, 0, 0 },
			LeftHip = { 26, 3, -0.5 }, LeftKnee = { -116, 0, 0 }, LeftAnkle = { -15, 0, 0 },
			RightShoulder = { -2, -9, 9.5 }, RightElbow = { 90, 12, 0 },
			LeftShoulder = { 14, 10, -8.5 }, LeftElbow = { 92, -12, 0 },
		} },
		{ 0.097, {
			Root = { -17, -3, 1, 0, -0.2, 0 }, Waist = { 1, 0, -1 }, Neck = { 17, 0, 0 },
			RightHip = { -27, -3, 0 }, RightKnee = { -6, 0, 0 }, RightAnkle = { -44, 0, 0 },
			LeftHip = { 58, 3, 0 }, LeftKnee = { -112, 0, 0 }, LeftAnkle = { -8, 0, 0 },
			RightShoulder = { 22, -10, 9 }, RightElbow = { 100, 12, 0 },
			LeftShoulder = { -16, 8, -9 }, LeftElbow = { 80, -12, 0 },
		} },
		{ 0.17, {
			Root = { -16, -7, 0, 0, 0.07, 0 }, Waist = { 1, 9, 0 }, Neck = { 16, -3, 0 },
			RightHip = { -34, -3, -1 }, RightKnee = { -58, 0, 0 }, RightAnkle = { -34, 0, 0 },
			LeftHip = { 64, 3, 1 }, LeftKnee = { -88, 0, 0 }, LeftAnkle = { 2, 0, 0 },
			RightShoulder = { 58, -14, 8 }, RightElbow = { 104, 12, 0 },
			LeftShoulder = { -44, 8, -10 }, LeftElbow = { 72, -12, 0 },
		} },
	},
	hands = { R = { { 0, "Open" } }, L = { { 0, "Open" } } },
	events = { { 0.0, "FootR" }, { S / 2, "FootL" } },
}))

-- Skid stop out of a sprint: plant, slide low with one hand trailing near the ground, rise.
local skidLow = {
	Root = { -6, 28, -6, 0.1, -0.85, 0.05 }, Waist = { -8, -10, 6 }, Neck = { 16, -14, -4 },
	RightHip = { 62, -10, 18 }, RightKnee = { -100, 0, 0 }, RightAnkle = { 22, 0, 0 },
	LeftHip = { -18, 22, -24 }, LeftKnee = { -78, 0, 0 }, LeftAnkle = { -18, 0, 0 },
	RightShoulder = { 30, 8, 30 }, RightElbow = { 30, 0, 0 }, RightWrist = { 10, 0, 10 },
	LeftShoulder = { -10, 0, -66 }, LeftElbow = { 12, 0, 0 }, LeftWrist = { 0, 0, -20 },
}
table.insert(clips, B.clip({
	name = "SprintStop",
	length = 0.95,
	keys = {
		{ 0.0, { Root = { -14, 6, 0, 0, -0.2, 0 }, Waist = { 1, -6, 0 }, Neck = { 14, 3, 0 }, RightHip = { 30, 0, 4 }, RightKnee = { -30, 0, 0 }, LeftHip = { -10, 0, -4 }, LeftKnee = { -60, 0, 0 }, RightShoulder = { 20, 0, 12 }, LeftShoulder = { -10, 0, -14 }, RightElbow = { 80, 0, 0 }, LeftElbow = { 80, 0, 0 } } },
		{ 0.12, skidLow },
		{ 0.42, B.add(skidLow, { Root = { 2, 2, 1, 0, 0.12, 0 }, Waist = { 3, 2, -1 } }), ease = "flat" },
		{ 0.95, stand, ease = "flat" },
	},
	hands = { R = { { 0, "Fist" }, { 0.1, "Claw", 0.1 }, { 0.6, "Relaxed", 0.3 } }, L = { { 0, "Fist" }, { 0.1, "Splay", 0.1 }, { 0.6, "Relaxed", 0.3 } } },
	events = { { 0.1, "Skid" } },
}))

--------------------------------------------------------------------------------------------------
-- Perch: the classic low crouch on a ledge: knees wide, one hand down between the feet,
-- the other forearm resting on a knee; slow breathing.
--------------------------------------------------------------------------------------------------
local perch = {
	Root = { -8, 0, 0, 0, -1.48, 0.05 },
	Waist = { -28, 0, 0 },
	Neck = { 34, 0, 0 },
	RightHip = { 96, 4, 30 }, RightKnee = { -136, 0, 0 }, RightAnkle = { 28, 0, -6 },
	LeftHip = { 96, -4, -30 }, LeftKnee = { -136, 0, 0 }, LeftAnkle = { 28, 0, 6 },
	RightShoulder = { 72, -10, -4 }, RightElbow = { 8, 0, 0 }, RightWrist = { 10, 0, 34 },
	LeftShoulder = { 54, 30, -10 }, LeftElbow = { 72, -30, 0 }, LeftWrist = { 0, 0, -10 },
}
clips.PerchPose = perch
table.insert(clips, B.loop({
	name = "Perch",
	length = 4.0,
	keys = {
		{ 0.0, perch },
		{ 1.0, B.add(perch, { Waist = { 1.6, 0, 0 }, Root = { 0, 0, 0, 0, 0.015, 0 }, Neck = { -1, 1.5, 0 }, LeftShoulder = { 0, 0, -1.5 } }) },
		{ 2.0, B.add(perch, { Neck = { 0, -4, 0 }, Waist = { 0, -2, 0 } }) },
		{ 3.0, B.add(perch, { Waist = { 1.6, 0, 0 }, Root = { 0, 0, 0, 0, 0.015, 0 }, Neck = { -1, -2, 0 } }) },
	},
	hands = { R = { { 0, "Splay" } }, L = { { 0, "Relaxed" } } },
}))

return clips
