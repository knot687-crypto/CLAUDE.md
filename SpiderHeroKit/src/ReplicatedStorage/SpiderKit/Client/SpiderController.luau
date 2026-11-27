--!nonstrict
--[[
	SpiderController (client)
	-------------------------
	Owns the local hero's movement: a state machine on top of the Humanoid.

	  Ground     Humanoid walking/running/sprinting and jumping; perches on roof edges when idle;
	             running into a wall starts a climb, sprinting into one starts a wall run
	  Air        ballistic flight with air control and dives (Humanoid freefall for small hops,
	             custom physics for fast flights so swing momentum is never braked)
	  Swing      web swing: anchors are found by ray fans around an ideal point ahead and above,
	             the pendulum is SwingPhysics; release (or auto-release) converts it into a launch
	  Zip        point launch: pull toward the aimed point, then stick to a wall or launch with a flip
	  WallCrawl  cling to any steep surface and crawl in any direction; wraps inner and outer
	             corners, vaults over the top edge, drops to the floor at the bottom
	  WallRun    sprint straight up a wall, vault the top or flip off
	  Ledge      scripted vault over an edge onto the roof
	  Perch      crouch on a roof edge

	Custom states put the Humanoid in its Physics state, cancel world gravity with a VectorForce
	where the motion supplies its own, set the root's velocity every physics step (so the engine
	still resolves collisions) and hold the orientation with a rigid AlignOrientation.
	Every step the animation context is built from this state and handed to the AnimDriver.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Kit = script.Parent.Parent
local Config = require(Kit.Config)
local Net = require(Kit.Net)
local SwingPhysics = require(Kit.Motion.SwingPhysics)
local Spring = require(Kit.Math.Spring)
local AnimDriver = require(script.Parent.AnimDriver)
local WebVisuals = require(script.Parent.WebVisuals)
local CameraFX = require(script.Parent.CameraFX)
local Audio = require(script.Parent.Audio)
local InputMap = require(script.Parent.InputMap)

local WALL_DISTANCE = 0.62 -- root centre to wall while crawling (matches the Wall motion)
local LEDGE_TIME = 0.66

local SpiderController = {}
SpiderController.__index = SpiderController

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function unitOr(v: Vector3, fallback: Vector3): Vector3
	if v.Magnitude > 1e-4 then
		return v.Unit
	end
	return fallback
end

local function ease(u: number): number
	u = math.clamp(u, 0, 1)
	return u * u * (3 - 2 * u)
end

local function isWall(n: Vector3): boolean
	return math.abs(n.Y) < Config.WallMaxNormalY
end

local function yawCF(dir: Vector3): CFrame
	local d = unitOr(flat(dir), Vector3.new(0, 0, -1))
	return CFrame.lookAt(Vector3.zero, d)
end

-- frame facing the wall (LookVector = -normal), up along the wall
local function wallFrame(pos: Vector3, n: Vector3, upHint: Vector3): CFrame
	local up = upHint - n * upHint:Dot(n)
	if up.Magnitude < 0.2 then
		up = Vector3.yAxis - n * n.Y
	end
	up = unitOr(up, Vector3.yAxis)
	local right = up:Cross(n).Unit
	return CFrame.fromMatrix(pos, right, n:Cross(right), n)
end

-- frame for running up a wall (LookVector = run direction, UpVector = wall normal)
local function wallRunFrame(pos: Vector3, n: Vector3, runDir: Vector3): CFrame
	local back = -runDir
	local right = n:Cross(back).Unit
	return CFrame.fromMatrix(pos, right, n, right:Cross(n))
end

function SpiderController.new(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local root = character:WaitForChild("HumanoidRootPart") :: BasePart
	local player = Players:GetPlayerFromCharacter(character)
	local self = setmetatable({}, SpiderController)
	self.character = character
	self.humanoid = humanoid
	self.root = root
	self.player = player
	self.state = "Ground"
	self.stateTime = 0
	self.driver = AnimDriver.new(character)
	self.webs = WebVisuals.new(character)
	self.fx = CameraFX.new()
	self.audio = Audio.new(root)
	self.input = InputMap.new()
	self.remote = nil :: RemoteEvent?
	task.spawn(function()
		self.remote = Net.remote(false)
	end)
	self.lastSent = {}
	self.nextHand = "Right"
	self.lastTrick = 0
	self.airPhysics = false
	self.airVel = Vector3.zero
	self.perchTimer = 0
	self.wallPush = 0
	self.yaw = yawCF(root.CFrame.LookVector)
	self.moveWorld = Vector3.zero
	self.moveRaw = Vector3.zero
	self.ghostParts = {}
	self.pendingZip = nil
	self.conns = {}

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.IgnoreWater = true
	self.params = params

	-- physics helpers on the root
	local att = Instance.new("Attachment")
	att.Name = "SpiderKitRoot"
	att.Parent = root
	local align = Instance.new("AlignOrientation")
	align.Name = "SpiderKitAlign"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = att
	align.RigidityEnabled = true
	align.Enabled = false
	align.Parent = root
	local antigrav = Instance.new("VectorForce")
	antigrav.Name = "SpiderKitAntiGravity"
	antigrav.Attachment0 = att
	antigrav.RelativeTo = Enum.ActuatorRelativeTo.World
	antigrav.ApplyAtCenterOfMass = true
	antigrav.Force = Vector3.zero
	antigrav.Enabled = false
	antigrav.Parent = root
	self.att, self.align, self.antigrav = att, align, antigrav

	humanoid.WalkSpeed = Config.RunSpeed
	humanoid.UseJumpPower = true
	humanoid.JumpPower = Config.JumpPower

	-- player input from the control module (works in every Humanoid state)
	self.controls = nil
	if player then
		task.spawn(function()
			local ok, pm = pcall(function()
				return require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule") :: ModuleScript)
			end)
			if ok and pm then
				self.controls = pm:GetControls()
			end
		end)
	end

	table.insert(self.conns, humanoid.StateChanged:Connect(function(_, new)
		self:_onHumanoidState(new)
	end))
	table.insert(self.conns, humanoid.Died:Connect(function()
		self:destroy()
	end))
	table.insert(self.conns, RunService.PreSimulation:Connect(function(dt)
		self:_step(dt)
	end))
	return self
end

-- ---------------------------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------------------------
function SpiderController:_cast(origin: Vector3, dir: Vector3): RaycastResult?
	return Workspace:Raycast(origin, dir, self.params)
end

function SpiderController:_hipToGround(): number
	return self.humanoid.HipHeight + self.root.Size.Y / 2
end

function SpiderController:_physics(on: boolean, antigravity: boolean?)
	local h = self.humanoid
	if on then
		if h:GetState() ~= Enum.HumanoidStateType.Physics then
			h:ChangeState(Enum.HumanoidStateType.Physics)
		end
		h.AutoRotate = false
		self.align.Enabled = true
	else
		self.align.Enabled = false
		h.AutoRotate = true
	end
	if antigravity then
		self.antigrav.Force = Vector3.new(0, self.root.AssemblyMass * Workspace.Gravity, 0)
		self.antigrav.Enabled = true
	else
		self.antigrav.Enabled = false
	end
end

-- non-colliding while glued to a wall or vaulting (raycasts keep the distance instead)
function SpiderController:_ghost(on: boolean)
	if on then
		if next(self.ghostParts) then
			return
		end
		for _, p in self.character:GetDescendants() do
			if p:IsA("BasePart") and p.CanCollide then
				self.ghostParts[p] = true
				p.CanCollide = false
			end
		end
	else
		for p in self.ghostParts do
			if p.Parent then
				p.CanCollide = true
			end
		end
		table.clear(self.ghostParts)
	end
end

function SpiderController:_send(payload)
	if self.remote then
		self.remote:FireServer(payload)
	end
end

function SpiderController:_event(name: string, data: any?, netArg: string?)
	self.driver:event(name, data)
	self.audio:onEvent(name, data)
	if Net.Events[name] then
		self:_send({ k = "e", name = name, arg = netArg })
	end
end

function SpiderController:_syncState()
	local s = {
		k = "s",
		state = self.state,
		anchor = if self.state == "Swing" and self.swing then self.swing.anchor else nil,
		hand = if self.state == "Swing" then self.swingHand else nil,
		zip = if self.state == "Zip" then self.zipTarget else nil,
		normal = if self.state == "WallCrawl" or self.state == "WallRun" then self.wallN else nil,
		sprint = self.sprinting,
	}
	local l = self.lastSent
	local changed = s.state ~= l.state or s.anchor ~= l.anchor or s.hand ~= l.hand or s.zip ~= l.zip or s.sprint ~= l.sprint
	if not changed and s.normal and l.normal then
		changed = s.normal:Dot(l.normal) < 0.985
	elseif not changed then
		changed = (s.normal == nil) ~= (l.normal == nil)
	end
	if changed then
		self.lastSent = s
		self:_send(s)
	end
end

function SpiderController:_setState(name: string)
	if self.state == name then
		return
	end
	local prev = self.state
	if prev == "WallCrawl" or prev == "WallRun" or prev == "Ledge" then
		self:_ghost(false)
	end
	if prev == "Swing" then
		self.webs:release("swing")
		self.swing = nil
	elseif prev == "Zip" then
		self.webs:release("zipR")
		self.webs:release("zipL")
		self.zipTarget = nil
	end
	self.state = name
	self.stateTime = 0
	self:_syncState()
end

-- camera-relative input on the ground plane
function SpiderController:_readInput()
	local mv = Vector3.zero
	if self.controls then
		local ok, v = pcall(function()
			return self.controls:GetMoveVector()
		end)
		if ok and v then
			mv = v
		end
	end
	local cam = Workspace.CurrentCamera
	if mv.Magnitude < 0.01 then
		self.moveRaw = Vector3.zero
		self.moveWorld = self.humanoid.MoveDirection
		return
	end
	self.moveRaw = mv
	if cam then
		local look = unitOr(flat(cam.CFrame.LookVector), Vector3.new(0, 0, -1))
		local right = unitOr(flat(cam.CFrame.RightVector), Vector3.new(1, 0, 0))
		local w = right * mv.X + look * -mv.Z
		self.moveWorld = if w.Magnitude > 1 then w.Unit else w
	else
		self.moveWorld = mv
	end
end

-- ---------------------------------------------------------------------------------------------
-- humanoid-driven transitions
-- ---------------------------------------------------------------------------------------------
function SpiderController:_onHumanoidState(new: Enum.HumanoidStateType)
	if new == Enum.HumanoidStateType.Jumping and (self.state == "Ground" or self.state == "Perch") then
		local sprint = self.sprinting
		if sprint then
			local v = self.root.AssemblyLinearVelocity
			self.root.AssemblyLinearVelocity = Vector3.new(v.X, Config.JumpPower * Config.SprintJumpBoost, v.Z)
		end
		if self.state == "Perch" then
			-- leap off the perch toward where the camera faces
			local cam = Workspace.CurrentCamera
			local fwd = if cam then unitOr(flat(cam.CFrame.LookVector), self.root.CFrame.LookVector) else self.root.CFrame.LookVector
			local v = self.root.AssemblyLinearVelocity
			self.root.AssemblyLinearVelocity = Vector3.new(0, v.Y, 0) + fwd * 30
		end
		self.airPhysics = false
		self:_setState("Air")
		self:_event("Jump", { sprint = sprint }, if sprint then "sprint" else nil)
	elseif new == Enum.HumanoidStateType.Freefall and (self.state == "Ground" or self.state == "Perch") then
		self.airPhysics = false
		self:_setState("Air")
	elseif (new == Enum.HumanoidStateType.Landed or new == Enum.HumanoidStateType.Running) and self.state == "Air" and not self.airPhysics then
		self:_land()
	end
end

function SpiderController:_land()
	local v = self.airVel
	local impact = math.max(0, -v.Y)
	local horizontal = flat(v).Magnitude
	self:_physics(false, false)
	if self.humanoid:GetState() == Enum.HumanoidStateType.Physics then
		self.humanoid:ChangeState(Enum.HumanoidStateType.Landed)
	end
	self:_setState("Ground")
	self:_event("Land", { impact = impact, horizontal = horizontal }, nil)
	if impact > Config.HeroLandingMinImpact then
		self.fx:kick(0.85)
	elseif impact > 85 then
		self.fx:kick(0.45)
	end
end

-- enters custom-physics flight with velocity v
function SpiderController:_toAir(v: Vector3)
	self:_physics(true, false)
	self.root.AssemblyLinearVelocity = v
	self.airPhysics = true
	self:_setState("Air")
end

-- ---------------------------------------------------------------------------------------------
-- swing
-- ---------------------------------------------------------------------------------------------
function SpiderController:_findAnchor(pos: Vector3, vel: Vector3): (Vector3?, string)
	local cam = Workspace.CurrentCamera
	local h = flat(vel)
	local fwd = if h.Magnitude > 12 then h.Unit elseif cam then unitOr(flat(cam.CFrame.LookVector), self.root.CFrame.LookVector) else self.root.CFrame.LookVector
	local right = fwd:Cross(Vector3.yAxis).Unit
	local hand = self.nextHand
	local sideSign = if hand == "Right" then 1 else -1
	local ideal = pos + fwd * Config.SwingIdealAhead + Vector3.yAxis * Config.SwingIdealUp + right * (Config.SwingIdealSide * sideSign)
	local base = (ideal - pos).Unit
	local best, bestScore = nil, math.huge
	for _, yaw in { 0, 14, -14, 28, -28, 44, -44 } do
		for _, pitch in { 0, 12, -10, 26 } do
			local d = CFrame.fromAxisAngle(Vector3.yAxis, math.rad(yaw * sideSign)) * CFrame.fromAxisAngle(right, math.rad(pitch))
			local dir = d:VectorToWorldSpace(base)
			local hit = self:_cast(pos, dir * Config.SwingRange)
			if hit and hit.Position.Y > pos.Y + Config.SwingMinHeight then
				local dist = (hit.Position - pos).Magnitude
				if dist > 22 then
					local score = (hit.Position - ideal).Magnitude + math.abs(yaw) * 0.4
					if score < bestScore then
						best, bestScore = hit.Position, score
					end
				end
			end
		end
	end
	if not best and Config.AllowSkySwing then
		-- nothing to hit: a virtual anchor keeps the flow going (only with room under the arc)
		local below = self:_cast(pos, Vector3.new(0, -Config.SwingIdealUp * 0.9, 0))
		if not below then
			best = ideal
		end
	end
	if best then
		-- the web hand is the one on the anchor's side
		local side = (best - pos):Dot(self.root.CFrame.RightVector)
		hand = if side >= 0 then "Right" else "Left"
	end
	return best, hand
end

function SpiderController:_startSwing(): boolean
	local pos = self.root.Position
	local vel = self.root.AssemblyLinearVelocity
	local anchor, hand = self:_findAnchor(pos, vel)
	if not anchor then
		return false
	end
	if self.state == "Ground" or self.state == "Perch" then
		vel += Vector3.new(0, 52, 0) -- hop into the swing
		self.root.AssemblyLinearVelocity = vel
	end
	self:_physics(true, true)
	self.swing = SwingPhysics.attach(anchor, pos)
	self.swingHand = hand
	self.nextHand = if hand == "Right" then "Left" else "Right"
	self.airPhysics = true
	self:_setState("Swing")
	self.webs:fire(hand, anchor, "swing", self.swing.length)
	self:_event("SwingStart", { hand = hand }, hand)
	return true
end

function SpiderController:_releaseSwing(extraUp: number?)
	local s = self.swing
	if not s then
		return
	end
	local pos = self.root.Position
	local v = SwingPhysics.releaseVelocity(s, pos, self.root.AssemblyLinearVelocity) + Vector3.new(0, extraUp or 0, 0)
	self:_toAir(v)
	self:_event("SwingRelease", nil, nil)
	local now = os.clock()
	if v.Magnitude > Config.SwingTrickSpeed and v.Y > 10 and now - self.lastTrick > 1.4 then
		self.lastTrick = now
		local name = Config.Tricks[math.random(1, #Config.Tricks)]
		self:_event("Trick", { name = name }, name)
	end
end

function SpiderController:_updateSwing(dt: number)
	local s = self.swing
	local pos = self.root.Position
	local v = self.root.AssemblyLinearVelocity
	if not self.input.swingHeld then
		self:_releaseSwing(0)
		return
	end
	if self.input.jumpPressed then
		self:_releaseSwing(22)
		return
	end
	if self.stateTime > 0.35 and SwingPhysics.phase(s, pos, v) < -math.rad(Config.SwingAutoReleaseAngle) then
		self:_releaseSwing(0)
		return
	end
	-- the line must stay clear of buildings
	local toAnchor = s.anchor - pos
	local block = self:_cast(pos, toAnchor * 0.97)
	if block and self.stateTime > 0.2 then
		self:_releaseSwing(0)
		return
	end
	v = SwingPhysics.step(s, pos, v, self.moveWorld, dt)
	-- ground and walls end the swing
	local down = self:_cast(pos, Vector3.new(0, -(self:_hipToGround() + 0.4), 0))
	if down and v.Y <= 0 then
		self.airVel = v
		self:_land()
		return
	end
	local hv = flat(v)
	if hv.Magnitude > 1 then
		local wall = self:_cast(pos, hv.Unit * (2.6 + hv.Magnitude * dt))
		if wall and isWall(wall.Normal) then
			self:_attachWall(wall)
			return
		end
	end
	self.root.AssemblyLinearVelocity = v
	self.webs:setLength("swing", s.length)
	self.yaw = yawCF(if hv.Magnitude > 4 then hv else self.yaw.LookVector)
	self.align.CFrame = self.yaw
end

-- ---------------------------------------------------------------------------------------------
-- zip / point launch
-- ---------------------------------------------------------------------------------------------
function SpiderController:_aimZip(): RaycastResult?
	local cam = Workspace.CurrentCamera
	if not cam then
		return nil
	end
	local origin = cam.CFrame.Position
	local reach = Config.ZipRange + (origin - self.root.Position).Magnitude
	return self:_cast(origin, cam.CFrame.LookVector * reach)
end

function SpiderController:_fireZip()
	local hit = self:_aimZip()
	if not hit then
		return
	end
	local target = hit.Position + hit.Normal * 2.4
	if (target - self.root.Position).Magnitude < 8 then
		return
	end
	-- wind-up: the arm snaps out (overlay) a beat before the pull starts
	self.driver.ac:overlay("WebFireR", "RightArm")
	self:_event("WebFire", nil, "Right")
	self.audio:onEvent("Zip")
	self.webs:fire("Right", hit.Position, "zipR")
	self.webs:fire("Left", hit.Position + hit.Normal * 0.4, "zipL")
	self.pendingZip = { target = target, normal = hit.Normal, t = 0.09 }
end

function SpiderController:_startZip(z)
	self:_physics(true, true)
	self.zipTarget = z.target
	self.zipNormal = z.normal
	self.zipStuck = 0
	self.airPhysics = true
	self:_setState("Zip")
	-- _setState released the lines of a previous zip; keep the new ones
	self.webs:fire("Right", z.target - z.normal * 2.4, "zipR")
	self.webs:fire("Left", z.target - z.normal * 2.0, "zipL")
end

function SpiderController:_updateZip(dt: number)
	local pos = self.root.Position
	local d = self.zipTarget - pos
	local dist = d.Magnitude
	local dir = d.Unit
	local speed = Config.ZipSpeed * math.min(1, 0.25 + self.stateTime / 0.16)
	local v = self.root.AssemblyLinearVelocity
	if self.stateTime > 0.12 and v:Dot(dir) < speed * 0.25 then
		self.zipStuck += dt
	else
		self.zipStuck = 0
	end
	if dist < 3.5 or self.zipStuck > 0.15 or self.stateTime > 2.6 then
		local n = self.zipNormal
		if n and isWall(n) and dist < 6 then
			local hit = self:_cast(pos, -n * (dist + 4.5))
			if hit then
				self:_attachWall(hit)
				return
			end
		end
		-- launch: up and onward with a flip
		local h = unitOr(flat(dir), self.root.CFrame.LookVector)
		self:_toAir(h * 48 + Config.ZipLaunchBoost)
		local name = if math.random() < 0.5 then "FrontFlip" else "Corkscrew"
		self.lastTrick = os.clock()
		self:_event("Trick", { name = name }, name)
		return
	end
	self.root.AssemblyLinearVelocity = dir * speed
	self.yaw = yawCF(if flat(dir).Magnitude > 0.2 then dir else self.yaw.LookVector)
	self.align.CFrame = self.yaw
end

-- ---------------------------------------------------------------------------------------------
-- walls
-- ---------------------------------------------------------------------------------------------
function SpiderController:_attachWall(hit: RaycastResult)
	local n = hit.Normal
	self:_physics(true, true)
	self:_ghost(true)
	self.wallN = n
	self.wallUp = unitOr(Vector3.yAxis - n * n.Y, Vector3.yAxis)
	self.airPhysics = true
	self:_setState("WallCrawl")
	local pos = hit.Position + n * WALL_DISTANCE
	self.root.CFrame = wallFrame(pos, n, self.wallUp)
	self.root.AssemblyLinearVelocity = Vector3.zero
	self.align.CFrame = wallFrame(Vector3.zero, n, self.wallUp)
	self.audio:onEvent("Land", { impact = 30 })
end

function SpiderController:_wallJump()
	local n = self.wallN or self.root.CFrame.LookVector * -1
	local cam = Workspace.CurrentCamera
	local aim = if cam then flat(cam.CFrame.LookVector) else Vector3.zero
	if aim:Dot(n) < 0 then
		aim -= n * aim:Dot(n) -- never aim back into the wall
	end
	local v = n * Config.WallJumpOut + Config.WallJumpVelocity + aim * 14
	self:_toAir(v)
	self.yaw = yawCF(n)
	self.align.CFrame = self.yaw
	self:_event("WallJump", nil, nil)
end

function SpiderController:_startLedge(top: Vector3, n: Vector3)
	self:_physics(true, true)
	self:_ghost(true)
	self.ledge = {
		from = self.root.CFrame,
		to = CFrame.lookAt(top, top - flat(n)),
		t = 0,
	}
	self:_setState("Ledge")
	self:_event("LedgeVault", nil, nil)
end

-- looks for a roof just past the top of the current wall; returns the standing root position
function SpiderController:_findRoof(pos: Vector3, n: Vector3, up: Vector3): Vector3?
	local probe = pos + up * 2.6 - n * 1.6
	local hit = self:_cast(probe + Vector3.yAxis * 2, Vector3.new(0, -5.5, 0))
	if hit and hit.Normal.Y > 0.7 then
		local clear = self:_cast(hit.Position + Vector3.yAxis * 0.2, Vector3.yAxis * 4.5)
		if not clear then
			return hit.Position + Vector3.yAxis * self:_hipToGround()
		end
	end
	return nil
end

function SpiderController:_updateWallCrawl(dt: number)
	local root = self.root
	local pos = root.Position
	local n: Vector3 = self.wallN
	local inp = self.input
	if inp.jumpPressed then
		self:_wallJump()
		return
	end
	if inp.dropPressed then
		self:_toAir(n * 8)
		return
	end
	if inp.zipPressed then
		self:_fireZip()
	end
	if inp.swingPressed and self:_startSwing() then
		return
	end

	-- wall-plane axes: stick forward = up the wall, sideways = the camera's right on the wall
	local cam = Workspace.CurrentCamera
	local up = unitOr(self.wallUp - n * self.wallUp:Dot(n), Vector3.yAxis)
	local r = if cam then cam.CFrame.RightVector else root.CFrame.RightVector
	r -= n * r:Dot(n)
	r = if r.Magnitude > 0.2 then r.Unit else up:Cross(n).Unit
	local upIn = n:Cross(r)
	if upIn:Dot(up) < 0 then
		upIn = -upIn
	end
	local mv = self.moveRaw
	local speed = Config.WallCrawlSpeed * (if self.sprinting then 1.6 else 1)
	local desired = (upIn * -mv.Z + r * mv.X)
	if desired.Magnitude > 1 then
		desired = desired.Unit
	end
	desired *= speed

	-- sprinting up a wall turns into a wall run
	if self.sprinting and -mv.Z > 0.6 and math.abs(n.Y) < 0.2 then
		self:_startWallRun(n)
		return
	end

	-- surface tracking
	local hit = self:_cast(pos, -n * 3)
	if hit and isWall(hit.Normal) then
		n = hit.Normal
	elseif hit and hit.Normal.Y > 0.7 then
		-- crawled onto a floor-like surface
		self:_physics(false, false)
		self.humanoid:ChangeState(Enum.HumanoidStateType.Landed)
		self:_setState("Ground")
		return
	end
	local moveDir = if desired.Magnitude > 0.1 then desired.Unit else nil
	if moveDir then
		-- inner corner: another wall right ahead in the travel direction
		local ahead = self:_cast(pos, moveDir * 1.5)
		if ahead and isWall(ahead.Normal) and ahead.Normal:Dot(n) < 0.8 then
			n = ahead.Normal
			hit = ahead
		elseif not hit then
			-- outer corner: wrap around the edge in the travel direction
			local around = self:_cast(pos + moveDir * 1.1 - n * 1.6, -moveDir * 2.2)
			if around and isWall(around.Normal) then
				n = around.Normal
				hit = around
			elseif moveDir:Dot(up) > 0.5 then
				local roof = self:_findRoof(pos, n, up)
				if roof then
					self:_startLedge(roof, n)
					return
				end
			end
		end
		-- top edge while climbing: vault
		if moveDir:Dot(up) > 0.5 then
			local above = self:_cast(pos + up * 1.8, -n * 3)
			if not above then
				local roof = self:_findRoof(pos, n, up)
				if roof then
					self:_startLedge(roof, n)
					return
				end
			end
		end
		-- reached the floor while climbing down
		if moveDir:Dot(up) < -0.5 then
			local floor = self:_cast(pos, -up * (self:_hipToGround() * 0.8))
			if floor and floor.Normal.Y > 0.7 then
				self:_physics(false, false)
				self.humanoid:ChangeState(Enum.HumanoidStateType.Landed)
				self:_setState("Ground")
				return
			end
		end
	end
	if not hit then
		-- lost the wall entirely
		self:_toAir(Vector3.zero)
		return
	end
	if n ~= self.wallN then
		self.wallN = n
		self.wallUp = unitOr(Vector3.yAxis - n * n.Y, self.wallUp)
		up = self.wallUp
	end
	local dist = (pos - hit.Position):Dot(n)
	local correct = n * ((WALL_DISTANCE - dist) * 14)
	local onPlane = desired - n * desired:Dot(n)
	root.AssemblyLinearVelocity = onPlane + correct
	self.align.CFrame = wallFrame(Vector3.zero, n, up)
	self.crawlDir = onPlane
end

function SpiderController:_startWallRun(n: Vector3)
	self:_physics(true, true)
	self:_ghost(true)
	self.wallN = n
	self.wallUp = unitOr(Vector3.yAxis - n * n.Y, Vector3.yAxis)
	-- pivot about the feet at the wall: the root swings from standing to lying along the wall
	local feet = self.root.Position - Vector3.yAxis * self:_hipToGround()
	local hit = self:_cast(self.root.Position, -n * 4)
	local wallPoint = if hit then hit.Position else feet - n * 0.5
	self.wallRun = { pivot = Vector3.new(wallPoint.X, feet.Y, wallPoint.Z), from = self.root.CFrame, t = 0 }
	self.airPhysics = true
	self:_setState("WallRun")
end

function SpiderController:_updateWallRun(dt: number)
	local root = self.root
	local n: Vector3 = self.wallN
	local wr = self.wallRun
	local up = self.wallUp
	local hip = self:_hipToGround()
	if self.input.jumpPressed then
		self:_wallJump()
		return
	end
	wr.t += dt
	if wr.t < 0.16 then
		-- pivot into the run
		local a = ease(wr.t / 0.16)
		local target = wallRunFrame(wr.pivot + n * hip, n, up)
		local pivotUp = (Vector3.yAxis):Lerp(n, a).Unit
		local cf = wr.from:Lerp(target, a)
		root.CFrame = cf.Rotation + (wr.pivot + pivotUp * hip)
		root.AssemblyLinearVelocity = up * Config.WallRunSpeed * a
		self.align.CFrame = cf.Rotation
		return
	end
	local pos = root.Position
	local hit = self:_cast(pos, -n * (hip + 1.5))
	if not hit then
		-- ran off the top: vault onto the roof, or flip off into the air
		local roof = self:_findRoof(pos - n * (hip - WALL_DISTANCE), n, up)
		if roof then
			self:_startLedge(roof, n)
		else
			self:_toAir(up * 40 + n * 12)
			self:_event("Trick", { name = "Backflip" }, "Backflip")
		end
		return
	end
	if not self.sprinting or wr.t > 2.6 or self.moveRaw.Z > -0.3 then
		-- out of steam: cling to the wall
		self:_attachWall(hit)
		return
	end
	local dist = (pos - hit.Position):Dot(n)
	root.AssemblyLinearVelocity = up * Config.WallRunSpeed + n * ((hip - dist) * 12)
	self.align.CFrame = wallRunFrame(Vector3.zero, n, up)
end

function SpiderController:_updateLedge(dt: number)
	local l = self.ledge
	l.t += dt
	local u = math.clamp(l.t / LEDGE_TIME, 0, 1)
	-- rise over the lip first, then move in over the roof, rotating upright on the way
	local a, b = l.from.Position, l.to.Position
	local y = a.Y + (b.Y - a.Y) * ease(u / 0.55)
	local xz = flat(a):Lerp(flat(b), ease((u - 0.25) / 0.75))
	local rot = l.from.Rotation:Lerp(l.to.Rotation, ease(u / 0.45))
	self.root.CFrame = rot + Vector3.new(xz.X, y, xz.Z)
	self.root.AssemblyLinearVelocity = Vector3.zero
	self.align.CFrame = rot
	if u >= 1 then
		self:_physics(false, false)
		self.humanoid:ChangeState(Enum.HumanoidStateType.Landed)
		self.yaw = yawCF(l.to.LookVector)
		self:_setState("Ground")
	end
end

-- ---------------------------------------------------------------------------------------------
-- ground / air
-- ---------------------------------------------------------------------------------------------
function SpiderController:_updateGround(dt: number)
	local root = self.root
	local inp = self.input
	local moving = self.moveWorld.Magnitude > 0.1
	self.humanoid.WalkSpeed = if self.sprinting and moving then Config.SprintSpeed else Config.RunSpeed
	if inp.swingPressed and self:_startSwing() then
		return
	end
	if inp.zipPressed then
		self:_fireZip()
	end
	-- walls: sprint into one to run up it, push into one (or jump at it) to climb
	if moving then
		local fwd = self.moveWorld.Unit
		local hit = self:_cast(root.Position, fwd * 2.4)
		if hit and isWall(hit.Normal) and fwd:Dot(-hit.Normal) > 0.6 then
			if self.sprinting and flat(root.AssemblyLinearVelocity).Magnitude > Config.RunSpeed * 0.8 then
				self:_startWallRun(hit.Normal)
				return
			end
			self.wallPush += dt
			if self.wallPush > 0.28 or inp.jumpPressed then
				self.wallPush = 0
				self:_attachWall(hit)
				return
			end
		else
			self.wallPush = 0
		end
	else
		self.wallPush = 0
	end
	-- perch: idle with a drop right in front
	if not moving and self.state == "Ground" then
		local look = flat(root.CFrame.LookVector).Unit
		local edge = self:_cast(root.Position + look * 1.9, Vector3.new(0, -(self:_hipToGround() + 8), 0))
		if not edge then
			self.perchTimer += dt
			if self.perchTimer > 0.45 then
				self.perchTimer = 0
				self:_setState("Perch")
			end
		else
			self.perchTimer = 0
		end
	elseif self.state == "Perch" and moving then
		self:_setState("Ground")
	end
end

function SpiderController:_updateAir(dt: number)
	local root = self.root
	local inp = self.input
	local v = root.AssemblyLinearVelocity
	self.airVel = v
	if inp.swingPressed and self:_startSwing() then
		return
	end
	if inp.zipPressed then
		self:_fireZip()
	end
	-- walls in the way while moving toward them
	local hv = flat(v)
	local probe = if hv.Magnitude > 2 then hv.Unit else self.moveWorld
	if probe.Magnitude > 0.1 then
		local hit = self:_cast(root.Position, probe.Unit * (2.4 + hv.Magnitude * dt))
		if hit and isWall(hit.Normal) and (hv:Dot(-hit.Normal) > 4 or self.moveWorld:Dot(-hit.Normal) > 0.5) then
			self:_attachWall(hit)
			return
		end
	end
	if not self.airPhysics then
		return -- Humanoid freefall: the engine steers, StateChanged reports the landing
	end
	-- landing
	local hip = self:_hipToGround()
	local down = self:_cast(root.Position, Vector3.new(0, -(hip + 0.35 + math.max(0, -v.Y) * dt), 0))
	if down and v.Y <= 0 and down.Normal.Y > 0.55 then
		self:_land()
		return
	end
	-- air control: steer toward the input, add speed only up to run speed
	local mw = self.moveWorld
	if mw.Magnitude > 0.1 then
		local hs = hv.Magnitude
		local add = mw * Config.AirControl * dt
		local nh = hv + add
		if nh.Magnitude > math.max(hs, Config.RunSpeed) then
			nh = nh.Unit * math.max(hs, Config.RunSpeed)
		end
		v = Vector3.new(nh.X, v.Y, nh.Z)
		-- dive: falling fast with the stick held forward
		if v.Y < -40 and mw:Dot(unitOr(hv, mw)) > 0.5 then
			v += Vector3.new(0, -Config.DiveAccel * dt, 0)
		end
	end
	root.AssemblyLinearVelocity = v
	local face = if flat(v).Magnitude > 6 then flat(v) elseif mw.Magnitude > 0.1 then mw else self.yaw.LookVector
	self.yaw = self.yaw:Lerp(yawCF(face), math.min(1, dt * 8))
	self.align.CFrame = self.yaw
end

-- ---------------------------------------------------------------------------------------------
-- main step
-- ---------------------------------------------------------------------------------------------
function SpiderController:_step(dt: number)
	if not self.root.Parent or self.humanoid.Health <= 0 then
		return
	end
	self.stateTime += dt
	self:_readInput()
	self.sprinting = self.input:sprinting()

	if self.pendingZip then
		self.pendingZip.t -= dt
		if self.pendingZip.t <= 0 then
			local z = self.pendingZip
			self.pendingZip = nil
			self:_startZip(z)
		end
	end

	local st = self.state
	if st == "Ground" or st == "Perch" then
		self:_updateGround(dt)
	elseif st == "Air" then
		self:_updateAir(dt)
	elseif st == "Swing" then
		self:_updateSwing(dt)
	elseif st == "Zip" then
		self:_updateZip(dt)
	elseif st == "WallCrawl" then
		self:_updateWallCrawl(dt)
	elseif st == "WallRun" then
		self:_updateWallRun(dt)
	elseif st == "Ledge" then
		self:_updateLedge(dt)
	end

	-- animation context
	local root = self.root
	local vel = root.AssemblyLinearVelocity
	local ctx = self.driver.ctx
	ctx.state = self.state
	ctx.rootCF = root.CFrame
	ctx.velocity = vel
	ctx.sprint = self.sprinting
	ctx.anchor = if self.state == "Swing" and self.swing then self.swing.anchor else nil
	ctx.swingHand = self.swingHand
	ctx.zipTarget = self.zipTarget
	ctx.wallNormal = if self.state == "WallCrawl" or self.state == "WallRun" then self.wallN else nil
	if self.state == "WallCrawl" then
		ctx.moveDir = self.crawlDir or Vector3.zero
	else
		ctx.moveDir = self.moveWorld
	end
	-- the head follows the camera while idle and the travel direction in flight
	local cam = Workspace.CurrentCamera
	if self.state == "Ground" and flat(vel).Magnitude < 3 and cam then
		ctx.lookDir = cam.CFrame.LookVector
	elseif self.state == "Air" or self.state == "Swing" then
		ctx.lookDir = if vel.Magnitude > 8 then vel.Unit else nil
	else
		ctx.lookDir = nil
	end
	self.driver:step(dt, ctx)
	for _, e in self.driver:events() do
		self.audio:onEvent(e)
	end

	-- camera and audio
	local speed = vel.Magnitude
	local roll = 0
	if self.state == "Swing" and self.swing then
		local side = (self.swing.anchor - root.Position):Dot(root.CFrame.RightVector)
		roll = -math.clamp(side / 40, -1, 1) * Config.SwingRoll
	end
	self.fx:set(speed, roll)
	self.audio:update(dt, speed, self.state ~= "Ground" and self.state ~= "Perch")
	self:_syncState()
	self.input:consume()
end

function SpiderController:destroy()
	if self.destroyed then
		return
	end
	self.destroyed = true
	for _, c in self.conns do
		c:Disconnect()
	end
	table.clear(self.conns)
	self:_ghost(false)
	self.webs:destroy()
	self.fx:destroy()
	self.audio:destroy()
	self.input:destroy()
	self.driver:destroy()
	self.align:Destroy()
	self.antigrav:Destroy()
	self.att:Destroy()
end

return SpiderController
