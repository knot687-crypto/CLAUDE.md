--!nocheck
-- Runs the real AnimController through a scripted scenario and bakes frames for the previewer.
--   node tools/harness/run.mjs tools/bake_scenario.luau <scenario> [fps] [substeps]
-- Scenarios live in tools/scenarios.luau. The simulator is a light stand-in for the Roblox
-- Humanoid + SpiderController: it integrates velocity, gravity (196.2), landings and emits the
-- same events/context the real driver sends.
local RS = game:GetService("ReplicatedStorage")
local Kit = RS.SpiderKit
local AnimController = require(Kit.Anim.AnimController)
local Skeleton = require(Kit.Anim.Skeleton)
local Pose = require(Kit.Anim.Pose)
local IK = require(Kit.Anim.IK)

local name = args[1] or "ground"
local fps = tonumber(args[2] or "30")
local sub = tonumber(args[3] or "2")

local scenarios = __load(__readfile(Harness.root .. "/tools/scenarios.luau"), "@tools/scenarios.luau", setmetatable({}, { __index = _G }))()
local scenario = scenarios[name]
assert(scenario, "unknown scenario " .. name)

local skel = Skeleton.fromDefinition()
local ac = AnimController.new(skel)
local HIP = 3.3
local GRAVITY = 196.2

local sim = {
	t = 0,
	pos = Vector3.new(0, HIP, 0),
	vel = Vector3.zero,
	yaw = 0,
	state = "Ground",
	input = Vector3.zero,
	sprint = false,
	extras = {},
	ac = ac,
	groundY = 0,
	gravity = true,
}

function sim.facing()
	return Vector3.new(-math.sin(sim.yaw), 0, -math.cos(sim.yaw))
end
function sim.rootCF()
	return CFrame.new(sim.pos) * CFrame.Angles(0, sim.yaw, 0) * (sim.tilt or CFrame.identity)
end
function sim.event(n, d)
	ac:event(n, d)
end
function sim.jump(vy, sprint)
	sim.vel = Vector3.new(sim.vel.X, vy, sim.vel.Z)
	sim.state = "Air"
	sim.event("Jump", { sprint = sprint })
end

local frames = {}
local dt = 1 / (fps * sub)
local total = 0
for _, seg in scenario.segments do
	total += seg[1]
end
local steps = math.floor(total / dt + 0.5)
local segIndex, segStart = 1, 0
local frameEvery = sub
local evts = {}
sim.segEnter = true
for step = 0, steps do
	local t = step * dt
	while segIndex <= #scenario.segments and t >= segStart + scenario.segments[segIndex][1] do
		segStart += scenario.segments[segIndex][1]
		segIndex += 1
		sim.segEnter = true
	end
	local seg = scenario.segments[math.min(segIndex, #scenario.segments)]
	local localT = t - segStart
	if seg[2] then
		seg[2](sim, dt, localT, sim.segEnter)
	end
	sim.segEnter = false
	-- integrate
	if sim.state == "Air" and sim.gravity then
		sim.vel += Vector3.new(0, -GRAVITY * dt, 0)
	end
	sim.pos += sim.vel * dt
	if sim.state == "Air" and sim.pos.Y <= sim.groundY + HIP and sim.vel.Y < 0 then
		local impact = -sim.vel.Y
		local horizontal = Vector3.new(sim.vel.X, 0, sim.vel.Z).Magnitude
		sim.pos = Vector3.new(sim.pos.X, sim.groundY + HIP, sim.pos.Z)
		sim.vel = Vector3.new(sim.vel.X, 0, sim.vel.Z)
		sim.state = "Ground"
		sim.event("Land", { impact = impact, horizontal = horizontal })
	end
	sim.t = t
	local ctx = {
		state = sim.state,
		rootCF = sim.rootCF(),
		velocity = sim.vel,
		moveDir = sim.input,
		lookDir = sim.look,
		sprint = sim.sprint,
		hipToGround = HIP,
		groundHeight = function()
			return sim.groundY
		end,
		anchor = sim.anchor,
		swingHand = sim.swingHand,
		wallNormal = sim.wallNormal,
		zipTarget = sim.zipTarget,
		webHands = sim.webHands,
	}
	if scenario.context then
		scenario.context(sim, ctx)
	end
	local out = ac:update(dt, ctx)
	for _, e in ac.events do
		table.insert(evts, e)
	end
	if step % frameEvery == 0 then
		local joints = {}
		for i, j in skel.joints do
			joints[j.name] = { Pose.get(out, i) }
		end
		local extras = {}
		for k, v in sim.extras do
			extras[k] = v
		end
		table.insert(frames, {
			t = t,
			rootCF = { ctx.rootCF:GetComponents() },
			joints = joints,
			state = sim.state,
			mode = ac.mode,
			oneShot = ac.oneShot and ac.oneShot.clip.name or nil,
			anchor = sim.anchor and { sim.anchor.X, sim.anchor.Y, sim.anchor.Z } or nil,
			hand = sim.swingHand,
			events = if #evts > 0 then evts else nil,
			extras = extras,
		})
		evts = {}
	end
end
Harness.writeJson(Harness.root .. "/tools/preview/out/clip_scn_" .. name .. ".json", { scenario = name, fps = fps, frames = frames, scene = scenario.scene }, 5)
print(string.format("baked scenario %s: %d frames (%.1fs)", name, #frames, total))
