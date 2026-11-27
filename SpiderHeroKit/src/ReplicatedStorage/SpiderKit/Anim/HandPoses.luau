--!strict
--[[
	HandPoses
	---------
	Finger presets for the 10 finger joints of each hand. Authored for the RIGHT hand in joint space
	(degrees, Euler XYZ); the left hand is mirrored automatically.

	Right-hand conventions (palm faces -X):
	  fingers: rz < 0 curls toward the palm, rx spreads (+ toward the thumb side, - toward the pinky side)
	  thumb (own frame, see RigDefinition.ThumbFrame): rz > 0 flexes across the palm,
	         rx > 0 adducts toward the index finger, rx < 0 abducts outward
]]

local Quat = require(script.Parent.Parent.Math.Quat)
local RigDefinition = require(script.Parent.Parent.Rig.RigDefinition)

local HandPoses = {}

local FINGER_JOINTS = { "Thumb1", "Thumb2", "Index1", "Index2", "Middle1", "Middle2", "Ring1", "Ring2", "Pinky1", "Pinky2" }
HandPoses.FingerJoints = FINGER_JOINTS

HandPoses.Presets = {
	Relaxed = {
		Thumb1 = { 4, 0, 14 }, Thumb2 = { 0, 0, 16 },
		Index1 = { 3, 0, -12 }, Index2 = { 0, 0, -18 },
		Middle1 = { 0, 0, -17 }, Middle2 = { 0, 0, -22 },
		Ring1 = { -2, 0, -21 }, Ring2 = { 0, 0, -26 },
		Pinky1 = { -5, 0, -26 }, Pinky2 = { 0, 0, -30 },
	},
	Open = {
		Thumb1 = { -18, 0, -6 }, Thumb2 = { 0, 0, -4 },
		Index1 = { 7, 0, -3 }, Index2 = { 0, 0, -2 },
		Middle1 = { 2, 0, -2 }, Middle2 = { 0, 0, -2 },
		Ring1 = { -3, 0, -3 }, Ring2 = { 0, 0, -3 },
		Pinky1 = { -9, 0, -4 }, Pinky2 = { 0, 0, -4 },
	},
	Fist = {
		Thumb1 = { 22, 0, 48 }, Thumb2 = { 0, 0, 55 },
		Index1 = { 2, 0, -92 }, Index2 = { 0, 0, -105 },
		Middle1 = { 0, 0, -95 }, Middle2 = { 0, 0, -105 },
		Ring1 = { -2, 0, -96 }, Ring2 = { 0, 0, -102 },
		Pinky1 = { -4, 0, -94 }, Pinky2 = { 0, 0, -98 },
	},
	-- wrapped around a web line
	Grip = {
		Thumb1 = { 18, 0, 34 }, Thumb2 = { 0, 0, 30 },
		Index1 = { 0, 0, -72 }, Index2 = { 0, 0, -80 },
		Middle1 = { 0, 0, -76 }, Middle2 = { 0, 0, -82 },
		Ring1 = { -2, 0, -78 }, Ring2 = { 0, 0, -82 },
		Pinky1 = { -4, 0, -76 }, Pinky2 = { 0, 0, -80 },
	},
	-- the web-shooter trigger: index and pinky straight, middle and ring pressed to the palm
	Thwip = {
		Thumb1 = { -28, 0, -8 }, Thumb2 = { 0, 0, -6 },
		Index1 = { 9, 0, -2 }, Index2 = { 0, 0, 0 },
		Middle1 = { 2, 0, -98 }, Middle2 = { 0, 0, -88 },
		Ring1 = { -2, 0, -98 }, Ring2 = { 0, 0, -86 },
		Pinky1 = { -12, 0, -3 }, Pinky2 = { 0, 0, 0 },
	},
	-- clinging to a wall: spread wide, lightly curled
	Splay = {
		Thumb1 = { -30, 0, -4 }, Thumb2 = { 0, 0, -8 },
		Index1 = { 14, 0, -10 }, Index2 = { 0, 0, -14 },
		Middle1 = { 4, 0, -9 }, Middle2 = { 0, 0, -12 },
		Ring1 = { -6, 0, -10 }, Ring2 = { 0, 0, -13 },
		Pinky1 = { -16, 0, -12 }, Pinky2 = { 0, 0, -14 },
	},
	-- tensed half-curl (landings, braced poses)
	Claw = {
		Thumb1 = { -12, 0, 10 }, Thumb2 = { 0, 0, 20 },
		Index1 = { 10, 0, -30 }, Index2 = { 0, 0, -50 },
		Middle1 = { 3, 0, -32 }, Middle2 = { 0, 0, -52 },
		Ring1 = { -4, 0, -34 }, Ring2 = { 0, 0, -50 },
		Pinky1 = { -12, 0, -36 }, Pinky2 = { 0, 0, -48 },
	},
	Point = {
		Thumb1 = { 20, 0, 40 }, Thumb2 = { 0, 0, 45 },
		Index1 = { 3, 0, -2 }, Index2 = { 0, 0, 0 },
		Middle1 = { 0, 0, -95 }, Middle2 = { 0, 0, -105 },
		Ring1 = { -2, 0, -96 }, Ring2 = { 0, 0, -102 },
		Pinky1 = { -4, 0, -94 }, Pinky2 = { 0, 0, -98 },
	},
}

--[[ The rig's fingers rest spread apart (see RigDefinition.FingerData.spread). Each preset says how
	 much of that rest spread to close: -1 brings the fingers together, 0 keeps the rest spread. The
	 preset's own rx values above are added on top. ]]
local GATHER = {
	Relaxed = -0.75, Open = -0.35, Fist = -1.0, Grip = -1.0, Thwip = -0.55, Splay = 0.0, Claw = -0.4, Point = -0.9,
}
local REST_SPREAD = {}
for _, fname in RigDefinition.Fingers do
	REST_SPREAD[fname] = (RigDefinition.FingerData :: any)[fname].spread or 0
end

-- compiled[side][preset] = flat quats (4 per finger joint, FINGER_JOINTS order)
local compiled: { [string]: { [string]: { number } } } = { Right = {}, Left = {} }
local jointIdx: { [string]: { number } } = { Right = {}, Left = {} }

for _, side in { "Right", "Left" } do
	local mirror = side == "Left"
	for i, fj in FINGER_JOINTS do
		jointIdx[side][i] = RigDefinition.JointIndex[side .. fj]
	end
	for name, preset in HandPoses.Presets do
		local q = table.create(#FINGER_JOINTS * 4, 0)
		for i, fj in FINGER_JOINTS do
			local v = (preset :: any)[fj] or { 0, 0, 0 }
			local rxDeg = v[1]
			local fname = fj:sub(1, #fj - 1)
			if fj:sub(-1) == "1" and fname ~= "Thumb" then
				rxDeg = (GATHER[name] or -0.75) * REST_SPREAD[fname] + v[1] * 0.5
			end
			local rx, ry, rz = math.rad(rxDeg), math.rad(v[2]), math.rad(v[3])
			if mirror then
				ry, rz = -ry, -rz
			end
			local x, y, z, w = Quat.fromEulerXYZ(rx, ry, rz)
			q[(i - 1) * 4 + 1], q[(i - 1) * 4 + 2], q[(i - 1) * 4 + 3], q[(i - 1) * 4 + 4] = x, y, z, w
		end
		compiled[side][name] = q
	end
end

export type HandState = { q: { number }, target: string }

function HandPoses.newState(side: string, preset: string?): HandState
	local p = preset or "Relaxed"
	return { q = table.clone(compiled[side][p]), target = p }
end

-- Moves the hand state toward `target` (optionally a blend of two presets) with smoothing.
function HandPoses.step(state: HandState, side: string, fromPreset: string, toPreset: string?, alpha: number?, halflife: number, dt: number)
	local a = compiled[side][fromPreset] or compiled[side].Relaxed
	local b = if toPreset then (compiled[side][toPreset] or a) else a
	local t = alpha or 1
	local k = if halflife <= 0 then 1 else 1 - math.exp(-0.69314718 * dt / halflife)
	local q = state.q
	for i = 0, #FINGER_JOINTS - 1 do
		local o = i * 4
		local tx, ty, tz, tw = a[o + 1], a[o + 2], a[o + 3], a[o + 4]
		if t > 0 and b ~= a then
			tx, ty, tz, tw = Quat.slerp(tx, ty, tz, tw, b[o + 1], b[o + 2], b[o + 3], b[o + 4], t)
		end
		q[o + 1], q[o + 2], q[o + 3], q[o + 4] = Quat.slerp(q[o + 1], q[o + 2], q[o + 3], q[o + 4], tx, ty, tz, tw, k)
	end
	state.target = toPreset or fromPreset
end

function HandPoses.write(pose: { number }, side: string, state: HandState)
	local idx = jointIdx[side]
	local q = state.q
	for i = 1, #FINGER_JOINTS do
		local j = idx[i]
		local o = (j - 1) * 7
		local s = (i - 1) * 4
		pose[o + 1], pose[o + 2], pose[o + 3], pose[o + 4] = q[s + 1], q[s + 2], q[s + 3], q[s + 4]
		pose[o + 5], pose[o + 6], pose[o + 7] = 0, 0, 0
	end
end

-- Writes a preset (or blend of two) directly into a pose without smoothing.
function HandPoses.writePreset(pose: { number }, side: string, presetA: string, presetB: string?, alpha: number?)
	local st: HandState = { q = table.clone(compiled[side][presetA]), target = presetA }
	if presetB and alpha and alpha > 0 then
		HandPoses.step(st, side, presetA, presetB, alpha, 0, 0)
	end
	HandPoses.write(pose, side, st)
end

function HandPoses.has(name: string): boolean
	return compiled.Right[name] ~= nil
end

return HandPoses
