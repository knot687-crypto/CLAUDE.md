--[[
	Controller
	Owns the overlay ScreenGui, tracks targets (other players' characters plus
	instances tagged with Config.Tag) and drives every Target from a single
	render-step callback bound right after the camera updates, so the overlay
	never trails the camera by a frame.

	API
	  Controller.new(config)
	  :Start() / :Stop()        create / tear down everything
	  :SetEnabled(bool)         master switch (keeps tracking, hides visuals)
	  :Apply()                  call after changing config from code
	  :GetCounts() -> (tracked, drawn)
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Target = require(script.Parent.Target)

local RENDER_STEP_NAME = "ESPOverlay"
local PRIORITY_INTERVAL = 0.25 -- seconds between chams / draw-order passes
local RECONCILE_INTERVAL = 1 -- seconds between safety re-syncs of player characters
local HIGHLIGHT_LIMIT = 31 -- engine limit for simultaneously rendered Highlights

local LocalPlayer = Players.LocalPlayer

local Controller = {}
Controller.__index = Controller

function Controller.new(config)
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.IgnoreWater = true

	local friends: { [number]: boolean } = {}
	return setmetatable({
		Config = config,
		Running = false,
		Targets = {} :: { [Instance]: any },

		_friends = friends,
		_gui = nil :: ScreenGui?,
		_connections = {} :: { RBXScriptConnection },
		_playerConnections = {} :: { [Player]: { RBXScriptConnection } },
		_scratch = {} :: { any },
		_hidden = false,
		_nextPriority = 0,
		_nextReconcile = 0,
		_filterCharacter = nil :: Model?,
		_filterCamera = nil :: Camera?,

		-- shared per-frame context handed to every Target (reused, never reallocated)
		_ctx = {
			Config = config,
			LocalPlayer = LocalPlayer,
			Friends = friends,
			RayParams = rayParams,
			Camera = nil :: Camera?,
			CameraCFrame = CFrame.identity,
			CameraPosition = Vector3.zero,
			CameraYaw = CFrame.identity,
			Viewport = Vector2.zero,
			Origin = Vector3.zero,
			TracerOrigin = Vector2.zero,
			Now = 0,
			Dt = 0,
		},
	}, Controller)
end

-- Targets ---------------------------------------------------------------------

function Controller:_addTarget(instance: Instance, player: Player?)
	local gui = self._gui
	if gui and not self.Targets[instance] then
		self.Targets[instance] = Target.new(instance, player, gui, self.Config)
	end
end

function Controller:_removeTarget(instance: Instance)
	local target = self.Targets[instance]
	if target then
		self.Targets[instance] = nil
		target:Destroy()
	end
end

function Controller:_addTagged(instance: Instance)
	if not (instance:IsA("Model") or instance:IsA("BasePart")) then
		return
	end
	if Players:GetPlayerFromCharacter(instance) then
		return -- player characters are tracked through their Player
	end
	local character = LocalPlayer.Character
	if character and (instance == character or instance:IsDescendantOf(character)) then
		return
	end
	self:_addTarget(instance, nil)
end

function Controller:_watchPlayer(player: Player)
	if player == LocalPlayer or self._playerConnections[player] then
		return
	end
	self._playerConnections[player] = {
		player.CharacterAdded:Connect(function(character)
			self:_addTarget(character, player)
		end),
		player.CharacterRemoving:Connect(function(character)
			self:_removeTarget(character)
		end),
	}
	if player.Character then
		self:_addTarget(player.Character, player)
	end

	local userId = player.UserId
	if self._friends[userId] == nil then
		self._friends[userId] = false
		task.spawn(function()
			-- IsFriendsWith is a web call: it yields and can fail
			local ok, isFriend = pcall(LocalPlayer.IsFriendsWith, LocalPlayer, userId)
			if ok then
				self._friends[userId] = isFriend == true
			end
		end)
	end
end

function Controller:_unwatchPlayer(player: Player)
	local connections = self._playerConnections[player]
	if connections then
		for _, connection in connections do
			connection:Disconnect()
		end
		self._playerConnections[player] = nil
	end
	for instance, target in self.Targets do
		if target.Player == player then
			self:_removeTarget(instance)
		end
	end
end

-- Characters can be replaced or streamed without CharacterAdded firing, so
-- every second make sure each player's current character is the one tracked.
function Controller:_reconcile()
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if player ~= LocalPlayer and character and not self.Targets[character] then
			self:_addTarget(character, player)
		end
	end
	for instance, target in self.Targets do
		local player = target.Player
		if player then
			if player.Parent == nil or player.Character ~= instance then
				self:_removeTarget(instance)
			end
		elseif instance.Parent == nil then
			self:_removeTarget(instance)
		end
	end
end

-- Closest targets get the limited Highlight slots and draw on top.
function Controller:_prioritize()
	local active = self._scratch
	table.clear(active)
	for _, target in self.Targets do
		if target.Active then
			table.insert(active, target)
		else
			target:SetChams(false)
		end
	end
	table.sort(active, function(a, b)
		return a.Distance < b.Distance
	end)

	local chams = self.Config.Chams
	local limit = if chams.Enabled then math.clamp(chams.MaxCount, 0, HIGHLIGHT_LIMIT) else 0
	local count = #active
	for i, target in active do
		target:SetChams(i <= limit)
		target:SetZIndex(count - i + 1)
	end
	table.clear(active)
end

-- Frame -----------------------------------------------------------------------

function Controller:_hideAll()
	for _, target in self.Targets do
		target:Hide()
	end
end

function Controller:_step(dt: number)
	local config = self.Config
	local camera = workspace.CurrentCamera
	if not config.Enabled or not camera then
		if not self._hidden then
			self._hidden = true
			self:_hideAll()
		end
		return
	end
	self._hidden = false

	local ctx = self._ctx
	local now = os.clock()
	local cameraCFrame = camera.CFrame
	local viewport = camera.ViewportSize
	ctx.Camera = camera
	ctx.CameraCFrame = cameraCFrame
	ctx.CameraPosition = cameraCFrame.Position
	ctx.Viewport = viewport
	ctx.Now = now
	ctx.Dt = dt

	-- yaw-only camera rotation: humanoid boxes stay upright and face the camera
	local look = cameraCFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-3 then
		local up = cameraCFrame.UpVector -- looking straight down/up
		flat = Vector3.new(up.X, 0, up.Z)
	end
	ctx.CameraYaw = if flat.Magnitude > 1e-3 then CFrame.lookAt(Vector3.zero, flat.Unit) else CFrame.identity

	-- distances are measured from your character when you have one
	local character = LocalPlayer.Character
	local localRoot = character and character:FindFirstChild("HumanoidRootPart")
	ctx.Origin = if localRoot and localRoot:IsA("BasePart") then localRoot.Position else ctx.CameraPosition

	local tracerOrigin = config.Tracer.Origin
	ctx.TracerOrigin = if tracerOrigin == "Center"
		then viewport * 0.5
		elseif tracerOrigin == "Top" then Vector2.new(viewport.X * 0.5, 0)
		elseif tracerOrigin == "Mouse" then UserInputService:GetMouseLocation()
		else Vector2.new(viewport.X * 0.5, viewport.Y)

	-- line-of-sight rays ignore your own character and anything in the camera (viewmodels)
	if self._filterCharacter ~= character or self._filterCamera ~= camera then
		self._filterCharacter, self._filterCamera = character, camera
		local filter: { Instance } = { camera }
		if character then
			table.insert(filter, character)
		end
		ctx.RayParams.FilterDescendantsInstances = filter
	end

	for instance, target in self.Targets do
		local ok, err = pcall(target.Update, target, ctx)
		if not ok then
			warn(`[ESP] stopped drawing {instance:GetFullName()}: {err}`)
			self:_removeTarget(instance)
		end
	end

	if now >= self._nextPriority then
		self._nextPriority = now + PRIORITY_INTERVAL
		self:_prioritize()
	end
	if now >= self._nextReconcile then
		self._nextReconcile = now + RECONCILE_INTERVAL
		self:_reconcile()
	end
end

-- Lifecycle -------------------------------------------------------------------

function Controller:Start()
	if self.Running then
		return
	end
	self.Running = true

	local gui = Instance.new("ScreenGui")
	gui.Name = "ESPOverlay"
	gui.IgnoreGuiInset = true -- viewport pixels == GUI pixels
	pcall(function()
		gui.ScreenInsets = Enum.ScreenInsets.None
	end)
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = self.Config.DisplayOrder
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	self._gui = gui

	local connections = self._connections
	table.insert(connections, Players.PlayerAdded:Connect(function(player)
		self:_watchPlayer(player)
	end))
	table.insert(connections, Players.PlayerRemoving:Connect(function(player)
		self:_unwatchPlayer(player)
	end))
	for _, player in Players:GetPlayers() do
		self:_watchPlayer(player)
	end

	local tag = self.Config.Tag
	table.insert(connections, CollectionService:GetInstanceAddedSignal(tag):Connect(function(instance)
		self:_addTagged(instance)
	end))
	table.insert(connections, CollectionService:GetInstanceRemovedSignal(tag):Connect(function(instance)
		self:_removeTarget(instance)
	end))
	for _, instance in CollectionService:GetTagged(tag) do
		self:_addTagged(instance)
	end

	RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Camera.Value + 1, function(dt)
		self:_step(dt)
	end)
end

function Controller:Stop()
	if not self.Running then
		return
	end
	self.Running = false
	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)

	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	for _, connections in self._playerConnections do
		for _, connection in connections do
			connection:Disconnect()
		end
	end
	table.clear(self._playerConnections)

	for _, target in self.Targets do
		target:Destroy()
	end
	table.clear(self.Targets)

	if self._gui then
		self._gui:Destroy()
		self._gui = nil
	end
	self._hidden = false
	self._filterCharacter, self._filterCamera = nil, nil
end

function Controller:SetEnabled(enabled: boolean)
	self.Config.Enabled = enabled
	self:Apply()
end

function Controller:Apply()
	self._nextPriority = 0 -- re-run the chams pass on the next frame
	if self._gui then
		self._gui.DisplayOrder = self.Config.DisplayOrder
	end
end

function Controller:GetCounts(): (number, number)
	local tracked, drawn = 0, 0
	for _, target in self.Targets do
		tracked += 1
		if target.Active then
			drawn += 1
		end
	end
	return tracked, drawn
end

return Controller
