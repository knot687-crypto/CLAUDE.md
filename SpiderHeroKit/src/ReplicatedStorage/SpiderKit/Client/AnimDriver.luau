--!strict
--[[
	AnimDriver
	----------
	Binds an AnimController to one character and writes its poses to the rig every frame.
	  * works on the SpiderHero skinned rig (R15 Motor6Ds + finger Bones) and on any R15 avatar
	    (missing joints are skipped; proportions are read from the avatar's own Motor6Ds)
	  * Motor6D.Transform / Bone.Transform are written in RunService.PreSimulation, after the
	    engine's Animator, so this fully owns the pose (call :step from a PreSimulation handler)
	  * the context for the local player comes from SpiderController; for other players it is
	    rebuilt from replicated attributes and physics (see :remoteContext)
]]

local Workspace = game:GetService("Workspace")

local Kit = script.Parent.Parent
local AnimController = require(Kit.Anim.AnimController)
local Skeleton = require(Kit.Anim.Skeleton)
local Pose = require(Kit.Anim.Pose)

local AnimDriver = {}
AnimDriver.__index = AnimDriver

export type Driver = typeof(setmetatable({} :: {
	character: Model,
	humanoid: Humanoid,
	root: BasePart,
	ac: any,
	motors: { [number]: Motor6D },
	bones: { [number]: Bone },
	ctx: any,
	rayParams: RaycastParams,
	hipToGround: number,
	lastState: string?,
	lastAnchorKey: string?,
	airVelocity: Vector3,
}, AnimDriver))

function AnimDriver.new(character: Model): Driver?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not root or humanoid.RigType ~= Enum.HumanoidRigType.R15 then
		return nil
	end
	local skel, motors = Skeleton.fromCharacter(character)
	local bones: { [number]: Bone } = {}
	for i, j in skel.joints do
		if not motors[i] then
			local b = character:FindFirstChild(j.name, true)
			if b and b:IsA("Bone") then
				bones[i] = b
				j.present = true
			end
		end
	end
	-- stop any engine-driven tracks so they can't fight the pose
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then
		for _, track in animator:GetPlayingAnimationTracks() do
			track:Stop(0)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.IgnoreWater = true
	local self = setmetatable({
		character = character,
		humanoid = humanoid,
		root = root,
		ac = AnimController.new(skel),
		motors = motors,
		bones = bones,
		ctx = nil,
		rayParams = params,
		hipToGround = humanoid.HipHeight + root.Size.Y / 2,
		lastState = nil,
		lastAnchorKey = nil,
		airVelocity = Vector3.zero,
	}, AnimDriver)
	local ground = function(p: Vector3): number?
		local hit = Workspace:Raycast(p + Vector3.new(0, 1.5, 0), Vector3.new(0, -4.5, 0), params)
		return hit and hit.Position.Y or nil
	end
	self.ctx = {
		state = "Ground",
		rootCF = root.CFrame,
		velocity = Vector3.zero,
		moveDir = Vector3.zero,
		lookDir = nil,
		sprint = false,
		groundHeight = ground,
		hipToGround = self.hipToGround,
	}
	return self
end

-- Forward a gameplay event (Jump, Land, SwingStart, SwingRelease, Trick, WallJump, ...)
function AnimDriver.event(self: Driver, name: string, data: any?)
	self.ac:event(name, data)
end

--[[ Rebuilds the context of a character simulated on another client from replicated state:
	 attributes set by the server relay + the physics state of the root. ]]
function AnimDriver.remoteContext(self: Driver): any
	local ch = self.character
	local ctx = self.ctx
	ctx.rootCF = self.root.CFrame
	ctx.velocity = self.root.AssemblyLinearVelocity
	ctx.moveDir = self.humanoid.MoveDirection
	local state = ch:GetAttribute("SpiderState")
	if type(state) ~= "string" then
		-- plain R15 avatar without the controller: derive from the Humanoid
		local hs = self.humanoid:GetState()
		state = if hs == Enum.HumanoidStateType.Freefall or hs == Enum.HumanoidStateType.Jumping then "Air" else "Ground"
	end
	-- landing event for remote characters (impact from the last airborne velocity)
	if (self.lastState == "Air" or self.lastState == "Swing") and state == "Ground" then
		local v = self.airVelocity
		self.ac:event("Land", { impact = -v.Y, horizontal = Vector3.new(v.X, 0, v.Z).Magnitude })
	end
	if state == "Air" or state == "Swing" then
		self.airVelocity = ctx.velocity
	end
	self.lastState = state
	ctx.state = state
	ctx.anchor = ch:GetAttribute("SwingAnchor")
	ctx.swingHand = ch:GetAttribute("SwingHand")
	ctx.zipTarget = ch:GetAttribute("ZipTarget")
	ctx.wallNormal = ch:GetAttribute("WallNormal")
	ctx.sprint = ch:GetAttribute("Sprint") == true
	ctx.lookDir = ctx.velocity.Magnitude > 2 and ctx.velocity.Unit or nil
	return ctx
end

-- Advances the animation and writes the pose to the rig.
function AnimDriver.step(self: Driver, dt: number, ctx: any?)
	local c = ctx or self.ctx
	c.hipToGround = self.hipToGround
	if not c.groundHeight then
		c.groundHeight = self.ctx.groundHeight
	end
	local out = self.ac:update(dt, c)
	for i, m in self.motors do
		m.Transform = Pose.transform(out, i)
	end
	for i, b in self.bones do
		b.Transform = Pose.transform(out, i)
	end
end

-- Events emitted by the last update (footsteps, grabs, web shots...) for sound/VFX hooks.
function AnimDriver.events(self: Driver): { string }
	return self.ac.events
end

function AnimDriver.destroy(self: Driver)
	for _, m in self.motors do
		if m.Parent then
			m.Transform = CFrame.identity
		end
	end
	for _, b in self.bones do
		if b.Parent then
			b.Transform = CFrame.identity
		end
	end
end

return AnimDriver
