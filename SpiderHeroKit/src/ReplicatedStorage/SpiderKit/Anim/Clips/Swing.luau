--!strict
--[[
	Swing poses (authored for a RIGHT-hand web; the runtime mirrors them for left-hand swings).
	The body is posed in its own frame; the Swing motion rotates it along the rope and drives the
	web arm with IK, so these poses define the silhouette: how the legs and the free arm read
	through each part of the arc. Each is a slow loop with a little life in it.
]]

local ClipBuilder = require(script.Parent.Parent.ClipBuilder)
local B = ClipBuilder

local clips = {}

-- Entering the arc (anchor ahead): long, streamlined line, legs together trailing a touch
local descend = {
	Root = { 0, 0, 0 }, Waist = { -4, 4, 2 }, Neck = { 16, -4, 0 },
	RightShoulder = { 168, 0, 12 }, RightElbow = { 8, 0, 0 },
	LeftShoulder = { -34, 18, -42 }, LeftElbow = { 26, -8, 0 }, LeftWrist = { 0, 0, -12 },
	RightHip = { -8, -4, 3 }, RightKnee = { -22, 0, 0 }, RightAnkle = { -34, 0, 0 },
	LeftHip = { 6, 4, -6 }, LeftKnee = { -38, 0, 0 }, LeftAnkle = { -32, 0, 0 },
}
-- Bottom of the arc (fastest): knees drive up, chest leans back, free arm reaches forward
local bottom = {
	Root = { 8, 0, 0 }, Waist = { -10, 6, 3 }, Neck = { 10, -6, 0 },
	RightShoulder = { 170, 0, 10 }, RightElbow = { 12, 0, 0 },
	LeftShoulder = { 46, 14, -48 }, LeftElbow = { 52, -10, 0 }, LeftWrist = { 0, 0, -8 },
	RightHip = { 74, -6, 8 }, RightKnee = { -98, 0, 0 }, RightAnkle = { -18, 0, 0 },
	LeftHip = { 54, 6, -6 }, LeftKnee = { -80, 0, 0 }, LeftAnkle = { -22, 0, 0 },
}
-- Rising toward release: legs kick forward and up, back arches, free arm flung back
local rise = {
	Root = { 4, 0, 0 }, Waist = { 12, 4, 2 }, Neck = { 6, -4, 0 },
	RightShoulder = { 172, 0, 10 }, RightElbow = { 6, 0, 0 },
	LeftShoulder = { -22, 20, -82 }, LeftElbow = { 16, -6, 0 }, LeftWrist = { 0, 0, -16 },
	RightHip = { 64, -6, 6 }, RightKnee = { -26, 0, 0 }, RightAnkle = { -38, 0, 0 },
	LeftHip = { 44, 6, -6 }, LeftKnee = { -44, 0, 0 }, LeftAnkle = { -36, 0, 0 },
}

local function breathe(pose, k)
	return B.add(pose, {
		Waist = { 1.5 * k, 0, 0 },
		LeftShoulder = { 3 * k, 0, -3 * k },
		RightHip = { 3 * k, 0, 0 },
		LeftHip = { -3 * k, 0, 0 },
		Neck = { -1 * k, 0, 0 },
	})
end

table.insert(clips, B.loop({ name = "SwingDescend", length = 1.4, keys = { { 0, descend }, { 0.7, breathe(descend, 1) } } }))
table.insert(clips, B.loop({ name = "SwingBottom", length = 1.2, keys = { { 0, bottom }, { 0.6, breathe(bottom, 1) } } }))
table.insert(clips, B.loop({ name = "SwingRise", length = 1.4, keys = { { 0, rise }, { 0.7, breathe(rise, 1) } } }))

clips.SwingBottomPose = bottom

-- Zip / point-launch pull: both arms reaching toward the target, body streamlined behind them
local zip = {
	Root = { -78, 0, 0 }, Waist = { 6, 0, 0 }, Neck = { 40, 0, 0 },
	RightShoulder = { 150, 0, 14 }, RightElbow = { 22, 0, 0 },
	LeftShoulder = { 150, 0, -14 }, LeftElbow = { 22, 0, 0 },
	RightHip = { 8, -4, 4 }, RightKnee = { -48, 0, 0 }, RightAnkle = { -36, 0, 0 },
	LeftHip = { -4, 4, -4 }, LeftKnee = { -26, 0, 0 }, LeftAnkle = { -36, 0, 0 },
}
table.insert(clips, B.loop({
	name = "ZipPull",
	length = 0.6,
	keys = { { 0, zip }, { 0.3, B.add(zip, { RightHip = { -6, 0, 0 }, LeftHip = { 6, 0, 0 }, RightKnee = { 8, 0, 0 }, LeftKnee = { -8, 0, 0 } }) } },
	hands = { R = { { 0, "Grip" } }, L = { { 0, "Grip" } } },
}))

-- Web fire overlay (right arm): snap the arm out, trigger the shooter, recoil
table.insert(clips, B.clip({
	name = "WebFireR",
	length = 0.34,
	keys = {
		{ 0.0, { RightShoulder = { 60, 0, 30 }, RightElbow = { 70, 0, 0 }, RightWrist = { 0, 0, 0 } } },
		{ 0.07, { RightShoulder = { 96, 0, 20 }, RightElbow = { 4, 0, 0 }, RightWrist = { 0, 0, 34 } } },
		{ 0.16, { RightShoulder = { 92, 0, 22 }, RightElbow = { 10, 0, 0 }, RightWrist = { 0, 0, 24 } } },
		{ 0.34, { RightShoulder = { 70, 0, 26 }, RightElbow = { 40, 0, 0 }, RightWrist = { 0, 0, 0 } } },
	},
	hands = { R = { { 0, "Open" }, { 0.05, "Trigger", 0.03 }, { 0.22, "Relaxed", 0.1 } } },
	events = { { 0.07, "WebShotR" } },
}))
table.insert(clips, B.clip({
	name = "WebFireL",
	length = 0.34,
	keys = {
		{ 0.0, B.mirror({ RightShoulder = { 60, 0, 30 }, RightElbow = { 70, 0, 0 }, RightWrist = { 0, 0, 0 } }) },
		{ 0.07, B.mirror({ RightShoulder = { 96, 0, 20 }, RightElbow = { 4, 0, 0 }, RightWrist = { 0, 0, 34 } }) },
		{ 0.16, B.mirror({ RightShoulder = { 92, 0, 22 }, RightElbow = { 10, 0, 0 }, RightWrist = { 0, 0, 24 } }) },
		{ 0.34, B.mirror({ RightShoulder = { 70, 0, 26 }, RightElbow = { 40, 0, 0 }, RightWrist = { 0, 0, 0 } }) },
	},
	hands = { L = { { 0, "Open" }, { 0.05, "Trigger", 0.03 }, { 0.22, "Relaxed", 0.1 } } },
	events = { { 0.07, "WebShotL" } },
}))

return clips
