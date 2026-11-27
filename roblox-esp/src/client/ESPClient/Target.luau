--[[
	Target
	All visuals for one tracked instance: a player's character, or any Model /
	BasePart tagged for the overlay. The Controller calls :Update(ctx) once per
	rendered frame.

	Tagged instances can customise themselves with attributes:
	  ESPName   (string)   label shown instead of the instance name
	  ESPColor  (Color3)   colour override
	  Health / MaxHealth (number)  shows a health bar on non-Humanoid targets
]]

local Draw = require(script.Parent.Draw)
local Rig = require(script.Parent.Rig)

local Line = Draw.Line
local Label = Draw.Label
local Bar = Draw.Bar
local round = Draw.round

local SLOW_INTERVAL = 0.5 -- seconds between part lookups / bounds / tool refreshes

local CORNERS = {
	Vector3.new(1, 1, 1),
	Vector3.new(1, 1, -1),
	Vector3.new(1, -1, 1),
	Vector3.new(1, -1, -1),
	Vector3.new(-1, 1, 1),
	Vector3.new(-1, 1, -1),
	Vector3.new(-1, -1, 1),
	Vector3.new(-1, -1, -1),
}

-- ZIndex layers inside a target's container (outlines sit one below their line)
local Z_FILL, Z_TRACER, Z_LINES, Z_BAR, Z_TEXT, Z_ARROW = 1, 2, 4, 5, 7, 9

local function findPart(parent: Instance, name: string): BasePart?
	local child = parent:FindFirstChild(name)
	return if child and child:IsA("BasePart") then child else nil
end

local function isTeammate(player: Player, localPlayer: Player): boolean
	local team = player.Team
	return team ~= nil and team == localPlayer.Team
end

local function formatDistance(studs: number, unit: string): string
	if unit == "Meters" then
		return string.format("%d m", round(studs * 0.28))
	end
	return string.format("%d studs", round(studs))
end

local function healthColor(fraction: number, colors): Color3
	if fraction > 0.5 then
		return colors.HealthMid:Lerp(colors.HealthHigh, (fraction - 0.5) * 2)
	end
	return colors.HealthLow:Lerp(colors.HealthMid, fraction * 2)
end

local Target = {}
Target.__index = Target

function Target.new(instance: Instance, player: Player?, parent: Instance, config)
	local container = Instance.new("Frame")
	container.Name = if player then player.Name else instance.Name
	container.BackgroundTransparency = 1
	container.Size = UDim2.fromScale(1, 1)
	container.Visible = false
	container.Parent = parent

	local font = config.Font
	local self = setmetatable({
		Instance = instance,
		Player = player,
		Container = container,

		Active = false, -- drawn (in range, alive, passes filters) on the last update
		Distance = math.huge,

		Root = nil :: BasePart?,
		Humanoid = nil :: Humanoid?,
		Head = nil :: BasePart?,
		BoundsOffset = CFrame.identity,
		BoundsSize = Vector3.one,
		BoneSpecs = nil :: { Rig.Bone }?,

		Fill = Line.new(container, Z_FILL, false),
		BoxLines = {} :: { any },
		Tracer = Line.new(container, Z_TRACER, true),
		HealthBar = Bar.new(container, Z_BAR),
		NameLabel = Label.new(container, Z_TEXT, font, config.Name.TextSize, Vector2.new(0.5, 1)),
		DistanceLabel = Label.new(container, Z_TEXT, font, config.Distance.TextSize, Vector2.new(0.5, 0)),
		ToolLabel = Label.new(container, Z_TEXT, font, config.Tool.TextSize, Vector2.new(0.5, 0)),
		HealthLabel = Label.new(container, Z_TEXT, font, config.HealthBar.TextSize, Vector2.new(1, 0.5)),
		BoneLines = nil :: { any }?, -- created on first use
		ArrowLines = nil :: { any }?, -- created on first use

		_boneA = {} :: { BasePart? },
		_boneB = {} :: { BasePart? },
		_name = "",
		_tool = nil :: string?,
		_shownHealth = nil :: number?,
		_occluded = false,
		_nextVisibility = 0,
		_nextSlow = 0,
		_containerShown = false,

		_chams = nil :: Highlight?,
		_chamsOn = false,
		_chamsColor = nil :: Color3?,
		_chamsFill = -1,
		_chamsOutline = -1,
		_chamsOnTop = nil :: boolean?,
	}, Target)

	for i = 1, 8 do
		self.BoxLines[i] = Line.new(container, Z_LINES, true)
	end
	return self
end

-- Lookups ---------------------------------------------------------------------

function Target:_displayName(config): string
	local player = self.Player
	if player then
		local mode = config.Name.Mode
		if mode == "Username" then
			return player.Name
		elseif mode == "Both" and player.DisplayName ~= player.Name then
			return player.DisplayName .. " (@" .. player.Name .. ")"
		end
		return player.DisplayName
	end
	local custom = self.Instance:GetAttribute("ESPName")
	return if type(custom) == "string" then custom else self.Instance.Name
end

-- Finds the parts we draw from and recomputes the bounds. Returns false if the
-- target currently has nothing to draw (e.g. its parts are streamed out).
function Target:_refresh(config): boolean
	local instance = self.Instance
	local humanoid: Humanoid? = nil
	local root: BasePart? = nil
	local head: BasePart? = nil

	if instance:IsA("BasePart") then
		root = instance
	else
		humanoid = instance:FindFirstChildOfClass("Humanoid")
		root = if humanoid then humanoid.RootPart else nil
		if not root then
			root = findPart(instance, "HumanoidRootPart")
				or (if instance:IsA("Model") then instance.PrimaryPart else nil)
				or instance:FindFirstChildWhichIsA("BasePart", true)
		end
		head = findPart(instance, "Head")
	end

	self.Root, self.Humanoid, self.Head = root, humanoid, head
	if not root then
		return false
	end

	self.BoundsOffset, self.BoundsSize = Rig.computeBounds(instance, humanoid, root, head)

	if humanoid then
		local specs = Rig.getBones(humanoid)
		self.BoneSpecs = specs
		for i = 1, Rig.MaxBones do
			local spec = specs[i]
			self._boneA[i] = if spec then findPart(instance, spec.A) else nil
			self._boneB[i] = if spec then findPart(instance, spec.B) else nil
		end
	else
		self.BoneSpecs = nil
	end

	self._name = self:_displayName(config)
	local tool = instance:FindFirstChildOfClass("Tool")
	self._tool = if tool then tool.Name else nil
	return true
end

function Target:_health(): (number?, number?)
	local humanoid = self.Humanoid
	if humanoid then
		return humanoid.Health, humanoid.MaxHealth
	end
	local health = self.Instance:GetAttribute("Health")
	if type(health) == "number" then
		local maxHealth = self.Instance:GetAttribute("MaxHealth")
		return health, if type(maxHealth) == "number" then maxHealth else 100
	end
	return nil, nil
end

function Target:_color(ctx): Color3
	local colors = ctx.Config.Colors
	local player = self.Player
	if not player then
		local custom = self.Instance:GetAttribute("ESPColor")
		return if typeof(custom) == "Color3" then custom else colors.Tagged
	end
	if ctx.Friends[player.UserId] then
		return colors.Friend
	end
	if ctx.Config.UseTeamColors and player.Team then
		return player.TeamColor.Color
	end
	return if isTeammate(player, ctx.LocalPlayer) then colors.Ally else colors.Enemy
end

function Target:_isOccluded(ctx, root: BasePart): boolean
	local aim = (self.Head or root).Position
	local origin = ctx.CameraPosition
	local result = workspace:Raycast(origin, aim - origin, ctx.RayParams)
	if not result then
		return false
	end
	local hit = result.Instance
	return hit ~= self.Instance and not hit:IsDescendantOf(self.Instance)
end

-- Chams -----------------------------------------------------------------------

function Target:SetChams(on: boolean)
	if on == self._chamsOn then
		return
	end
	self._chamsOn = on
	if on then
		local highlight = self._chams
		if not highlight or highlight.Parent ~= self.Instance then
			if highlight then
				highlight:Destroy()
			end
			highlight = Instance.new("Highlight")
			highlight.Name = "ESPHighlight"
			-- invisible until _styleChams runs next frame (avoids a flash of the default red)
			highlight.FillTransparency = 1
			highlight.OutlineTransparency = 1
			highlight.Adornee = self.Instance
			highlight.Parent = self.Instance
			self._chams = highlight
			self._chamsColor, self._chamsFill, self._chamsOutline, self._chamsOnTop = nil, -1, -1, nil
		end
		highlight.Enabled = true
	elseif self._chams then
		self._chams.Enabled = false
	end
end

function Target:_styleChams(chamsConfig, color: Color3)
	local highlight = self._chams
	if not highlight then
		return
	end
	if self._chamsColor ~= color then
		self._chamsColor = color
		highlight.FillColor = color
		highlight.OutlineColor = color
	end
	if self._chamsFill ~= chamsConfig.FillTransparency then
		self._chamsFill = chamsConfig.FillTransparency
		highlight.FillTransparency = chamsConfig.FillTransparency
	end
	if self._chamsOutline ~= chamsConfig.OutlineTransparency then
		self._chamsOutline = chamsConfig.OutlineTransparency
		highlight.OutlineTransparency = chamsConfig.OutlineTransparency
	end
	if self._chamsOnTop ~= chamsConfig.AlwaysOnTop then
		self._chamsOnTop = chamsConfig.AlwaysOnTop
		highlight.DepthMode = if chamsConfig.AlwaysOnTop
			then Enum.HighlightDepthMode.AlwaysOnTop
			else Enum.HighlightDepthMode.Occluded
	end
end

-- Visibility helpers ----------------------------------------------------------

function Target:Hide()
	self.Active = false
	if self._containerShown then
		self._containerShown = false
		self.Container.Visible = false
	end
	if self._chamsOn then
		self:SetChams(false)
	end
end

function Target:_hideLines(lines: { any }?, from: number?)
	if lines then
		for i = from or 1, #lines do
			lines[i]:Hide()
		end
	end
end

function Target:_hideOnScreen()
	self:_hideLines(self.BoxLines)
	self:_hideLines(self.BoneLines)
	self.Fill:Hide()
	self.Tracer:Hide()
	self.HealthBar:Hide()
	self.NameLabel:Hide()
	self.DistanceLabel:Hide()
	self.ToolLabel:Hide()
	self.HealthLabel:Hide()
end

-- Drawing ---------------------------------------------------------------------

function Target:_drawBox(x: number, y: number, w: number, h: number, color: Color3, transparency: number, box)
	local lines = self.BoxLines
	local t = box.Thickness
	if box.Style == "Full" then
		lines[1]:Rect(x, y, w, t, color, transparency)
		lines[2]:Rect(x, y + h - t, w, t, color, transparency)
		lines[3]:Rect(x, y, t, h, color, transparency)
		lines[4]:Rect(x + w - t, y, t, h, color, transparency)
		self:_hideLines(lines, 5)
	else
		local len = math.max(round(math.min(w, h) * box.CornerFraction), t + 2)
		lines[1]:Rect(x, y, len, t, color, transparency)
		lines[2]:Rect(x, y, t, len, color, transparency)
		lines[3]:Rect(x + w - len, y, len, t, color, transparency)
		lines[4]:Rect(x + w - t, y, t, len, color, transparency)
		lines[5]:Rect(x, y + h - t, len, t, color, transparency)
		lines[6]:Rect(x, y + h - len, t, len, color, transparency)
		lines[7]:Rect(x + w - len, y + h - t, len, t, color, transparency)
		lines[8]:Rect(x + w - t, y + h - len, t, len, color, transparency)
	end

	if box.Filled then
		self.Fill:Rect(x, y, w, h, color, 1 - (1 - transparency) * (1 - box.FillTransparency))
	else
		self.Fill:Hide()
	end
end

function Target:_drawHealth(ctx, x: number, y: number, h: number, transparency: number)
	local config = ctx.Config
	local barConfig = config.HealthBar
	local health, maxHealth = self:_health()
	if not (barConfig.Enabled and health and maxHealth and maxHealth > 0) then
		self.HealthBar:Hide()
		self.HealthLabel:Hide()
		return
	end

	-- ease the displayed value toward the real one so hits read as a drain
	local fraction = math.clamp(health / maxHealth, 0, 1)
	local shown = self._shownHealth or fraction
	shown += (fraction - shown) * math.min(1, ctx.Dt * barConfig.Smoothing)
	if math.abs(fraction - shown) < 0.002 then
		shown = fraction
	end
	self._shownHealth = shown

	local barX = x - barConfig.Gap - barConfig.Width
	self.HealthBar:Set(barX, y, barConfig.Width, h, shown, healthColor(shown, config.Colors), transparency)

	if barConfig.ShowText and fraction < 0.999 then
		local labelY = math.clamp(y + h - round(h * shown), y + 5, y + h - 5)
		self.HealthLabel:Set(tostring(math.ceil(health)), barX - 3, labelY, config.Colors.Text, transparency)
	else
		self.HealthLabel:Hide()
	end
end

function Target:_drawSkeleton(ctx, color: Color3, transparency: number)
	local specs = self.BoneSpecs
	if not specs then
		self:_hideLines(self.BoneLines)
		return
	end

	local lines = self.BoneLines
	if not lines then
		lines = {}
		for i = 1, Rig.MaxBones do
			lines[i] = Line.new(self.Container, Z_LINES, true)
		end
		self.BoneLines = lines
	end

	local camera = ctx.Camera
	local thickness = ctx.Config.Skeleton.Thickness
	for i, line in lines do
		local spec = specs[i]
		local a, b = self._boneA[i], self._boneB[i]
		if spec and a and b and a.Parent and b.Parent then
			local pa = camera:WorldToViewportPoint(Rig.point(a, spec.OffsetA))
			local pb = camera:WorldToViewportPoint(Rig.point(b, spec.OffsetB))
			if pa.Z > 0 and pb.Z > 0 then
				line:Segment(Vector2.new(pa.X, pa.Y), Vector2.new(pb.X, pb.Y), thickness, color, transparency)
				continue
			end
		end
		line:Hide()
	end
end

-- Arrow on a ring around the screen centre, pointing the way you would turn
-- (top-down: up = in front of the camera, down = behind it).
function Target:_drawArrow(ctx, position: Vector3, color: Color3, transparency: number)
	local arrows = ctx.Config.Arrows
	local lines = self.ArrowLines
	if not lines then
		lines = {
			Line.new(self.Container, Z_ARROW, true),
			Line.new(self.Container, Z_ARROW, true),
			Line.new(self.Container, Z_ARROW, true),
		}
		self.ArrowLines = lines
	end

	local relative = ctx.CameraCFrame:PointToObjectSpace(position)
	local direction = Vector2.new(relative.X, relative.Z)
	direction = if direction.Magnitude > 1e-3 then direction.Unit else Vector2.new(0, 1)

	local viewport = ctx.Viewport
	local radius = math.min(viewport.X, viewport.Y) * arrows.Radius
	local base = viewport * 0.5 + direction * radius
	local tip = base + direction * arrows.Size
	local side = Vector2.new(-direction.Y, direction.X) * (arrows.Size * 0.65)

	lines[1]:Segment(base + side, tip, arrows.Thickness, color, transparency)
	lines[2]:Segment(base - side, tip, arrows.Thickness, color, transparency)
	lines[3]:Segment(base + side, base - side, arrows.Thickness, color, transparency)
end

-- Per-frame update --------------------------------------------------------------

function Target:Update(ctx)
	local config = ctx.Config
	local now = ctx.Now

	if now >= self._nextSlow then
		self._nextSlow = now + SLOW_INTERVAL
		self:_refresh(config)
	end

	local instance = self.Instance
	local root = self.Root
	local player = self.Player
	if not root or not root.Parent or not instance.Parent then
		self:Hide()
		return
	end

	-- filters
	if player then
		if not config.ShowPlayers or (config.TeamCheck and isTeammate(player, ctx.LocalPlayer)) then
			self:Hide()
			return
		end
	elseif not config.ShowTagged then
		self:Hide()
		return
	end
	if config.HideDead then
		local health, maxHealth = self:_health()
		if health and maxHealth and health <= 0 then
			self:Hide()
			return
		end
	end

	local rootCFrame = root.CFrame
	local position = rootCFrame.Position
	local distance = (position - ctx.Origin).Magnitude
	self.Distance = distance
	if distance > config.MaxDistance then
		self:Hide()
		return
	end
	self.Active = true

	-- colour and opacity
	local color = self:_color(ctx)
	local opacity = 1
	local fade = config.Fade
	if fade.Enabled then
		local start = config.MaxDistance * fade.Start
		if distance > start then
			local t = (distance - start) / math.max(config.MaxDistance - start, 1)
			opacity = 1 - math.clamp(t, 0, 1) * (1 - fade.MinOpacity)
		end
	end
	local visibility = config.Visibility
	if visibility.Enabled then
		if now >= self._nextVisibility then
			self._nextVisibility = now + visibility.Interval
			self._occluded = self:_isOccluded(ctx, root)
		end
		if self._occluded then
			opacity *= visibility.OccludedOpacity
		end
	end
	local transparency = 1 - opacity

	if self._chamsOn then
		self:_styleChams(config.Chams, color)
	end

	-- project the bounding box: humanoids get an upright box facing the camera
	-- (stable width as they turn); other targets use their oriented box
	local camera = ctx.Camera
	local boxCFrame = if self.Humanoid
		then CFrame.new(position) * ctx.CameraYaw * self.BoundsOffset
		else rootCFrame * self.BoundsOffset
	local half = self.BoundsSize * 0.5
	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
	local behind = false
	for _, corner in CORNERS do
		local point = camera:WorldToViewportPoint(boxCFrame:PointToWorldSpace(half * corner))
		if point.Z <= 0 then
			behind = true
			break
		end
		if point.X < minX then
			minX = point.X
		end
		if point.X > maxX then
			maxX = point.X
		end
		if point.Y < minY then
			minY = point.Y
		end
		if point.Y > maxY then
			maxY = point.Y
		end
	end

	local viewport = ctx.Viewport
	local onScreen = not behind and maxX > 0 and maxY > 0 and minX < viewport.X and minY < viewport.Y

	if onScreen then
		self:_hideLines(self.ArrowLines)

		local x, y = round(minX), round(minY)
		local w, h = math.max(round(maxX - minX), 3), math.max(round(maxY - minY), 3)
		local centerX = x + w * 0.5
		local colors = config.Colors

		if config.Box.Enabled then
			self:_drawBox(x, y, w, h, color, transparency, config.Box)
		else
			self:_hideLines(self.BoxLines)
			self.Fill:Hide()
		end

		if config.Name.Enabled then
			self.NameLabel:Set(self._name, centerX, y - 3, colors.Text, transparency)
		else
			self.NameLabel:Hide()
		end

		local belowY = y + h + 3
		if config.Distance.Enabled then
			self.DistanceLabel:Set(formatDistance(distance, config.Distance.Unit), centerX, belowY, colors.SubText, transparency)
			belowY += config.Distance.TextSize + 1
		else
			self.DistanceLabel:Hide()
		end

		local tool = self._tool
		if config.Tool.Enabled and tool then
			self.ToolLabel:Set(tool, centerX, belowY, color, transparency)
		else
			self.ToolLabel:Hide()
		end

		self:_drawHealth(ctx, x, y, h, transparency)

		if config.Tracer.Enabled then
			self.Tracer:Segment(ctx.TracerOrigin, Vector2.new(centerX, y + h), config.Tracer.Thickness, color, transparency)
		else
			self.Tracer:Hide()
		end

		if config.Skeleton.Enabled then
			self:_drawSkeleton(ctx, color, transparency)
		else
			self:_hideLines(self.BoneLines)
		end
	else
		self:_hideOnScreen()
		if config.Arrows.Enabled then
			self:_drawArrow(ctx, position, color, transparency)
		else
			self:_hideLines(self.ArrowLines)
		end
	end

	if not self._containerShown then
		self._containerShown = true
		self.Container.Visible = true
	end
end

function Target:SetZIndex(zIndex: number)
	if self.Container.ZIndex ~= zIndex then
		self.Container.ZIndex = zIndex
	end
end

function Target:Destroy()
	self.Container:Destroy()
	if self._chams then
		self._chams:Destroy()
		self._chams = nil
	end
end

return Target
