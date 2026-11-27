--!strict
--[[
	Air clips: jumps, the rise/fall/dive loops and aerial tricks.
	Flips rotate the Root through a full turn; the spline interpolates the unwrapped Euler values,
	so a 0 -> -360 key run spins smoothly with natural acceleration out of the tuck.
]]

local ClipBuilder = require(script.Parent.Parent.ClipBuilder)
local B = ClipBuilder

local clips = {}

-- Shared air poses ---------------------------------------------------------------------------
local riseA = {
	Root = { -4, 0, 0 }, Waist = { -3, 0, 0 }, Neck = { 5, 0, 0 },
	RightHip = { 58, -6, 10 }, RightKnee = { -82, 0, 0 }, RightAnkle = { -16, 0, 0 },
	LeftHip = { 36, 6, -8 }, LeftKnee = { -64, 0, 0 }, LeftAnkle = { -22, 0, 0 },
	RightShoulder = { 56, -10, 46 }, RightElbow = { 48, 10, 0 }, RightWrist = { 0, 0, 8 },
	LeftShoulder = { 60, 10, -42 }, LeftElbow = { 52, -10, 0 }, LeftWrist = { 0, 0, -8 },
}
local riseB = B.add(riseA, {
	RightHip = { -8, 0, 0 }, LeftHip = { 7, 0, 0 }, RightKnee = { 6, 0, 0 }, LeftKnee = { -6, 0, 0 },
	RightShoulder = { -4, 0, 4 }, LeftShoulder = { 3, 0, -5 }, Waist = { 1.5, 0, 0 },
})
clips.RisePose = riseA

local fallA = {
	Root = { 5, 0, 0 }, Waist = { 8, 0, 0 }, Neck = { -14, 0, 0 },
	RightHip = { 34, -6, 14 }, RightKnee = { -58, 0, 0 }, RightAnkle = { -12, 0, 0 },
	LeftHip = { -4, 8, -14 }, LeftKnee = { -46, 0, 0 }, LeftAnkle = { -26, 0, 0 },
	RightShoulder = { 20, -20, 76 }, RightElbow = { 34, 6, 0 }, RightWrist = { 0, 0, 14 },
	LeftShoulder = { 16, 20, -72 }, LeftElbow = { 30, -6, 0 }, LeftWrist = { 0, 0, -14 },
}
local fallB = B.add(fallA, {
	RightHip = { -14, 0, 0 }, LeftHip = { 16, 0, 0 }, RightKnee = { 6, 0, 0 }, LeftKnee = { -8, 0, 0 },
	RightShoulder = { 4, 0, -7 }, LeftShoulder = { -3, 0, 8 }, Waist = { -2, 0, 0 }, Neck = { 3, 0, 0 },
	Root = { 0, 2, 1 },
})
clips.FallPose = fallA

-- Dive body is authored straight; the Air motion pitches it along the velocity.
local diveA = {
	Root = { 0, 0, 0 }, Waist = { 7, 0, 0 }, Neck = { 46, 0, 0 },
	RightHip = { -5, -4, -3 }, RightKnee = { -16, 0, 0 }, RightAnkle = { -42, 0, 0 },
	LeftHip = { -3, 4, 3 }, LeftKnee = { -22, 0, 0 }, LeftAnkle = { -40, 0, 0 },
	RightShoulder = { -26, 0, 20 }, RightElbow = { 16, 0, 0 }, RightWrist = { 0, 0, 12 },
	LeftShoulder = { -24, 0, -20 }, LeftElbow = { 18, 0, 0 }, LeftWrist = { 0, 0, -12 },
}
local diveB = B.add(diveA, {
	RightHip = { 4, 0, 1 }, LeftHip = { -4, 0, -1 }, RightKnee = { -6, 0, 0 }, LeftKnee = { 6, 0, 0 },
	RightShoulder = { 3, 0, 2 }, LeftShoulder = { -2, 0, -2 },
})

table.insert(clips, B.loop({
	name = "AirRise",
	length = 1.6,
	keys = { { 0, riseA }, { 0.8, riseB } },
	hands = { R = { { 0, "Relaxed" } }, L = { { 0, "Relaxed" } } },
}))
table.insert(clips, B.loop({
	name = "AirFall",
	length = 1.5,
	keys = { { 0, fallA }, { 0.75, fallB } },
	hands = { R = { { 0, "Open" } }, L = { { 0, "Open" } } },
}))
table.insert(clips, B.loop({
	name = "Dive",
	length = 0.9,
	keys = { { 0, diveA }, { 0.45, diveB } },
	hands = { R = { { 0, "Open" } }, L = { { 0, "Open" } } },
}))

-- Jump: snap from a loaded crouch to full extension, then tuck into the rise pose -------------
table.insert(clips, B.clip({
	name = "Jump",
	length = 0.36,
	keys = {
		{ 0.0, {
			Root = { -12, 0, 0, 0, -0.42, 0 }, Waist = { -10, 0, 0 }, Neck = { 14, 0, 0 },
			RightHip = { 50, -4, 4 }, RightKnee = { -76, 0, 0 }, RightAnkle = { 18, 0, 0 },
			LeftHip = { 48, 4, -4 }, LeftKnee = { -74, 0, 0 }, LeftAnkle = { 18, 0, 0 },
			RightShoulder = { -40, 0, 12 }, RightElbow = { 24, 0, 0 },
			LeftShoulder = { -40, 0, -12 }, LeftElbow = { 24, 0, 0 },
		}, ease = "linear" },
		{ 0.075, {
			Root = { -5, 0, 0, 0, 0.14, 0 }, Waist = { 5, 0, 0 }, Neck = { 6, 0, 0 },
			RightHip = { -4, -2, 3 }, RightKnee = { -6, 0, 0 }, RightAnkle = { -40, 0, 0 },
			LeftHip = { -2, 2, -3 }, LeftKnee = { -8, 0, 0 }, LeftAnkle = { -38, 0, 0 },
			RightShoulder = { 118, 0, 16 }, RightElbow = { 16, 0, 0 },
			LeftShoulder = { 112, 0, -16 }, LeftElbow = { 18, 0, 0 },
		} },
		{ 0.2, {
			Root = { -5, 0, 0, 0, 0.05, 0 }, Waist = { -5, 0, 0 }, Neck = { 3, 0, 0 },
			RightHip = { 64, -6, 9 }, RightKnee = { -92, 0, 0 }, RightAnkle = { -12, 0, 0 },
			LeftHip = { 40, 6, -8 }, LeftKnee = { -72, 0, 0 }, LeftAnkle = { -20, 0, 0 },
			RightShoulder = { 74, -6, 38 }, RightElbow = { 44, 8, 0 },
			LeftShoulder = { 76, 6, -36 }, LeftElbow = { 48, -8, 0 },
		} },
		{ 0.36, riseA },
	},
	hands = { R = { { 0, "Claw" }, { 0.06, "Open", 0.06 }, { 0.22, "Relaxed", 0.12 } }, L = { { 0, "Claw" }, { 0.06, "Open", 0.06 }, { 0.22, "Relaxed", 0.12 } } },
	events = { { 0.0, "JumpPush" } },
}))

-- Running long jump: hurdler stride, reaching arms, then gather into the rise --------------
table.insert(clips, B.clip({
	name = "SprintJump",
	length = 0.6,
	keys = {
		{ 0.0, {
			Root = { -16, 6, 0, 0, -0.2, 0 }, Waist = { 0, -8, 0 }, Neck = { 16, 3, 0 },
			RightHip = { -24, -3, 0 }, RightKnee = { -10, 0, 0 }, RightAnkle = { -40, 0, 0 },
			LeftHip = { 66, 3, 0 }, LeftKnee = { -100, 0, 0 }, LeftAnkle = { -6, 0, 0 },
			RightShoulder = { 40, -10, 10 }, RightElbow = { 90, 10, 0 },
			LeftShoulder = { -40, 8, -10 }, LeftElbow = { 70, -10, 0 },
		}, ease = "linear" },
		{ 0.16, {
			Root = { -12, 2, 0, 0, 0.12, 0 }, Waist = { 4, -4, 0 }, Neck = { 10, 2, 0 },
			RightHip = { -36, -3, -2 }, RightKnee = { -42, 0, 0 }, RightAnkle = { -36, 0, 0 },
			LeftHip = { 80, 3, 4 }, LeftKnee = { -30, 0, 0 }, LeftAnkle = { 10, 0, 0 },
			RightShoulder = { 120, -10, 20 }, RightElbow = { 20, 0, 0 },
			LeftShoulder = { 60, 10, -30 }, LeftElbow = { 30, 0, 0 },
		} },
		{ 0.36, {
			Root = { -8, 0, 0, 0, 0.08, 0 }, Waist = { -2, 0, 0 }, Neck = { 6, 0, 0 },
			RightHip = { 30, -3, 4 }, RightKnee = { -80, 0, 0 }, RightAnkle = { -20, 0, 0 },
			LeftHip = { 70, 3, -2 }, LeftKnee = { -60, 0, 0 }, LeftAnkle = { 0, 0, 0 },
			RightShoulder = { 80, -10, 40 }, RightElbow = { 40, 0, 0 },
			LeftShoulder = { 70, 10, -40 }, LeftElbow = { 46, 0, 0 },
		} },
		{ 0.6, riseA },
	},
	hands = { R = { { 0, "Fist" }, { 0.1, "Open", 0.1 }, { 0.4, "Relaxed", 0.15 } }, L = { { 0, "Fist" }, { 0.1, "Open", 0.1 }, { 0.4, "Relaxed", 0.15 } } },
}))

-- Tricks -------------------------------------------------------------------------------------
local tuck = {
	Waist = { -30, 0, 0 }, Neck = { -18, 0, 0 },
	RightHip = { 118, -8, 10 }, RightKnee = { -142, 0, 0 }, RightAnkle = { -20, 0, 0 },
	LeftHip = { 116, 8, -10 }, LeftKnee = { -140, 0, 0 }, LeftAnkle = { -20, 0, 0 },
	RightShoulder = { 66, -20, 12 }, RightElbow = { 96, 10, 0 }, RightWrist = { 0, 0, -10 },
	LeftShoulder = { 66, 20, -12 }, LeftElbow = { 96, -10, 0 }, LeftWrist = { 0, 0, 10 },
}
local function withRoot(pose, rx, ry, rz, py)
	return B.merge(pose, { Root = { rx or 0, ry or 0, rz or 0, 0, py or 0, 0 } })
end

table.insert(clips, B.clip({
	name = "FrontFlip",
	length = 0.74,
	keys = {
		{ 0.0, withRoot(B.add(fallA, { RightShoulder = { 60, 0, -30 }, LeftShoulder = { 60, 0, 30 } }), 0) , ease = "flat" },
		{ 0.13, withRoot(B.lerp(fallA, tuck, 0.75), -75, 0, 0, 0.1) },
		{ 0.3, withRoot(tuck, -205, 0, 0, 0.12) },
		{ 0.47, withRoot(B.lerp(tuck, fallA, 0.55), -305, 0, 0, 0.06) },
		{ 0.74, withRoot(fallA, -360) },
	},
	hands = { R = { { 0, "Open" }, { 0.1, "Fist", 0.08 }, { 0.42, "Open", 0.12 } }, L = { { 0, "Open" }, { 0.1, "Fist", 0.08 }, { 0.42, "Open", 0.12 } } },
	events = { { 0.05, "Whoosh" } },
}))

table.insert(clips, B.clip({
	name = "Backflip",
	length = 0.8,
	keys = {
		{ 0.0, withRoot(B.add(riseA, { Waist = { 12, 0, 0 }, Neck = { 16, 0, 0 } }), 0), ease = "flat" },
		{ 0.14, withRoot(B.lerp(riseA, tuck, 0.6), 70, 0, 0, 0.1) },
		{ 0.33, withRoot(tuck, 200, 0, 0, 0.12) },
		{ 0.52, withRoot(B.lerp(tuck, fallA, 0.6), 305, 0, 0, 0.05) },
		{ 0.8, withRoot(fallA, 360) },
	},
	hands = { R = { { 0, "Open" }, { 0.12, "Fist", 0.08 }, { 0.48, "Open", 0.12 } }, L = { { 0, "Open" }, { 0.12, "Fist", 0.08 }, { 0.48, "Open", 0.12 } } },
	events = { { 0.05, "Whoosh" } },
}))

-- Corkscrew: a twisting barrel roll with arms pulled in to spin fast
local spinPose = {
	Waist = { 6, 0, 0 }, Neck = { 4, 0, 0 },
	RightHip = { 10, -2, -4 }, RightKnee = { -30, 0, 0 }, RightAnkle = { -36, 0, 0 },
	LeftHip = { 24, 2, 4 }, LeftKnee = { -50, 0, 0 }, LeftAnkle = { -36, 0, 0 },
	RightShoulder = { 36, -40, -16 }, RightElbow = { 120, 20, 0 },
	LeftShoulder = { 36, 40, 16 }, LeftElbow = { 120, -20, 0 },
}
table.insert(clips, B.clip({
	name = "Corkscrew",
	length = 0.9,
	keys = {
		{ 0.0, withRoot(fallA, 0, 0, 0), ease = "flat" },
		{ 0.15, withRoot(spinPose, -28, 70, 10, 0.08) },
		{ 0.45, withRoot(spinPose, -36, 230, 18, 0.1) },
		{ 0.68, withRoot(B.lerp(spinPose, fallA, 0.5), -18, 330, 8, 0.04) },
		{ 0.9, withRoot(fallA, 0, 360, 0) },
	},
	hands = { R = { { 0, "Open" }, { 0.1, "Fist", 0.08 }, { 0.65, "Open", 0.12 } }, L = { { 0, "Open" }, { 0.1, "Fist", 0.08 }, { 0.65, "Open", 0.12 } } },
	events = { { 0.05, "Whoosh" } },
}))

-- Aerial cartwheel: side flip with legs split and arms wide
local split = {
	Waist = { 0, 0, 0 }, Neck = { 0, 0, 0 },
	RightHip = { 4, -10, 62 }, RightKnee = { -12, 0, 0 }, RightAnkle = { -30, 0, 0 },
	LeftHip = { 4, 10, -62 }, LeftKnee = { -12, 0, 0 }, LeftAnkle = { -30, 0, 0 },
	RightShoulder = { 0, 0, 110 }, RightElbow = { 10, 0, 0 },
	LeftShoulder = { 0, 0, -110 }, LeftElbow = { 10, 0, 0 },
}
table.insert(clips, B.clip({
	name = "Cartwheel",
	length = 0.84,
	keys = {
		{ 0.0, withRoot(fallA, 0, 0, 0), ease = "flat" },
		{ 0.16, withRoot(split, 0, 0, 80, 0.1) },
		{ 0.42, withRoot(split, 0, 0, 205, 0.12) },
		{ 0.62, withRoot(B.lerp(split, fallA, 0.5), 0, 0, 305, 0.05) },
		{ 0.84, withRoot(fallA, 0, 0, 360) },
	},
	hands = { R = { { 0, "Open" } }, L = { { 0, "Open" } } },
	events = { { 0.05, "Whoosh" } },
}))

-- Swan: arch the back, arms and legs spread wide and hold, the signature "flying over the city" pose
local swan = {
	Root = { 18, 0, 0 }, Waist = { 22, 0, 0 }, Neck = { 22, 0, 0 },
	RightHip = { -20, -10, 24 }, RightKnee = { -28, 0, 0 }, RightAnkle = { -40, 0, 0 },
	LeftHip = { -14, 10, -30 }, LeftKnee = { -46, 0, 0 }, LeftAnkle = { -40, 0, 0 },
	RightShoulder = { 30, -30, 96 }, RightElbow = { 10, 0, 0 }, RightWrist = { 0, 0, 22 },
	LeftShoulder = { 26, 30, -96 }, LeftElbow = { 12, 0, 0 }, LeftWrist = { 0, 0, -22 },
}
table.insert(clips, B.clip({
	name = "Swan",
	length = 1.1,
	keys = {
		{ 0.0, fallA, ease = "flat" },
		{ 0.22, swan },
		{ 0.75, B.add(swan, { Waist = { 4, 0, 0 }, Root = { 4, 0, 0 } }), ease = "flat" },
		{ 1.1, fallA },
	},
	hands = { R = { { 0, "Open" } }, L = { { 0, "Open" } } },
}))

return clips
