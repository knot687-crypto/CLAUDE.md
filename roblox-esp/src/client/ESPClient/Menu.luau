--[[
	Menu
	In-game settings panel: draggable, scrollable, animated, mouse and touch
	friendly. Each control is bound to a path inside Config and writes to it
	directly, so changes show up on the very next frame.

	API
	  Menu.new(config, controller)
	  :Open() / :Close() / :Toggle()
	  :SetAvailable(bool)   hides the menu (and the touch button) when false
	  :Refresh()            re-sync every control from Config
	  :Destroy()
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local THEME = {
	Background = Color3.fromRGB(15, 16, 21),
	Surface = Color3.fromRGB(23, 25, 32),
	Hover = Color3.fromRGB(31, 34, 44),
	Border = Color3.fromRGB(46, 49, 62),
	Text = Color3.fromRGB(236, 238, 245),
	SubText = Color3.fromRGB(128, 134, 155),
	Accent = Color3.fromRGB(124, 98, 255),
	Off = Color3.fromRGB(52, 55, 70),
	Knob = Color3.fromRGB(245, 246, 250),
}
local FONT = Enum.Font.GothamMedium
local FONT_BOLD = Enum.Font.GothamBold
local FAST = TweenInfo.new(0.15, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local POP = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local PANEL_SIZE = Vector2.new(300, 440)
local HEADER_HEIGHT = 50
local FOOTER_HEIGHT = 30

local function studs(value: number): string
	return string.format("%d studs", value)
end

local function percent(value: number): string
	return string.format("%d%%", math.round(value * 100))
end

local LAYOUT = {
	{ Section = "General" },
	{ Toggle = "ESP enabled", Path = { "Enabled" } },
	{ Toggle = "Players", Path = { "ShowPlayers" } },
	{ Toggle = "Tagged objects", Path = { "ShowTagged" } },
	{ Toggle = "Hide teammates", Path = { "TeamCheck" } },
	{ Toggle = "Team colors", Path = { "UseTeamColors" } },
	{ Slider = "Max distance", Path = { "MaxDistance" }, Min = 100, Max = 5000, Step = 50, Format = studs },

	{ Section = "Overlay" },
	{ Toggle = "Boxes", Path = { "Box", "Enabled" } },
	{ Choice = "Box style", Path = { "Box", "Style" }, Options = { "Corner", "Full" } },
	{ Toggle = "Box fill", Path = { "Box", "Filled" } },
	{ Toggle = "Names", Path = { "Name", "Enabled" } },
	{ Choice = "Name format", Path = { "Name", "Mode" }, Options = { "DisplayName", "Username", "Both" } },
	{ Toggle = "Distance", Path = { "Distance", "Enabled" } },
	{ Choice = "Distance unit", Path = { "Distance", "Unit" }, Options = { "Studs", "Meters" } },
	{ Toggle = "Held tool", Path = { "Tool", "Enabled" } },
	{ Toggle = "Health bar", Path = { "HealthBar", "Enabled" } },
	{ Toggle = "Skeleton", Path = { "Skeleton", "Enabled" } },
	{ Toggle = "Tracers", Path = { "Tracer", "Enabled" } },
	{ Choice = "Tracer origin", Path = { "Tracer", "Origin" }, Options = { "Bottom", "Center", "Top", "Mouse" } },

	{ Section = "World" },
	{ Toggle = "Chams", Path = { "Chams", "Enabled" } },
	{ Toggle = "Chams through walls", Path = { "Chams", "AlwaysOnTop" } },
	{ Slider = "Chams transparency", Path = { "Chams", "FillTransparency" }, Min = 0, Max = 1, Step = 0.05, Format = percent },
	{ Toggle = "Off-screen arrows", Path = { "Arrows", "Enabled" } },
	{ Toggle = "Dim targets behind walls", Path = { "Visibility", "Enabled" } },
	{ Toggle = "Distance fade", Path = { "Fade", "Enabled" } },
}

-- Helpers ---------------------------------------------------------------------

local function create(className: string, props: { [string]: any }, children: { Instance }?): any
	local instance = Instance.new(className)
	for key, value in props do
		if key ~= "Parent" then
			(instance :: any)[key] = value
		end
	end
	if children then
		for _, child in children do
			child.Parent = instance
		end
	end
	if props.Parent then
		instance.Parent = props.Parent
	end
	return instance
end

local function corner(radius: number): UICorner
	return create("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function stroke(color: Color3): UIStroke
	return create("UIStroke", { Color = color, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
end

local function getPath(root: any, path: { string }): any
	local node = root
	for _, key in path do
		node = node[key]
	end
	return node
end

local function setPath(root: any, path: { string }, value: any)
	local node = root
	for i = 1, #path - 1 do
		node = node[path[i]]
	end
	node[path[#path]] = value
end

local function isPress(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

local function tween(instance: Instance, goal: { [string]: any }, info: TweenInfo?)
	TweenService:Create(instance, info or FAST, goal):Play()
end

-- Menu ------------------------------------------------------------------------

local Menu = {}
Menu.__index = Menu

function Menu:_connect(connection: RBXScriptConnection)
	table.insert(self._connections, connection)
end

function Menu:_changed()
	self.Controller:Apply()
end

function Menu:_row(height: number, order: number): TextButton
	local row = create("TextButton", {
		Name = "Row",
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = THEME.Surface,
		Size = UDim2.new(1, 0, 0, height),
		LayoutOrder = order,
		Parent = self._content,
	}, { corner(6) })
	row.MouseEnter:Connect(function()
		tween(row, { BackgroundColor3 = THEME.Hover })
	end)
	row.MouseLeave:Connect(function()
		tween(row, { BackgroundColor3 = THEME.Surface })
	end)
	return row
end

function Menu:_label(row: Instance, text: string)
	create("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -130, 0, 30),
		Font = FONT,
		Text = text,
		TextColor3 = THEME.Text,
		TextSize = 13,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = row,
	})
end

function Menu:_section(item, order: number)
	create("TextLabel", {
		Name = "Section",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 26),
		Font = FONT_BOLD,
		Text = string.upper(item.Section),
		TextColor3 = THEME.SubText,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Bottom,
		LayoutOrder = order,
		Parent = self._content,
	}, { create("UIPadding", { PaddingLeft = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4) }) })
end

function Menu:_toggle(item, order: number)
	local row = self:_row(30, order)
	self:_label(row, item.Toggle)
	local track = create("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(34, 18),
		BackgroundColor3 = THEME.Off,
		Parent = row,
	}, { corner(9) })
	local knob = create("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 2, 0.5, 0),
		Size = UDim2.fromOffset(14, 14),
		BackgroundColor3 = THEME.Knob,
		Parent = track,
	}, { corner(7) })

	local function sync(instant: boolean?)
		local on = getPath(self.Config, item.Path) == true
		local trackGoal = { BackgroundColor3 = if on then THEME.Accent else THEME.Off }
		local knobGoal = { Position = if on then UDim2.new(1, -16, 0.5, 0) else UDim2.new(0, 2, 0.5, 0) }
		if instant then
			track.BackgroundColor3 = trackGoal.BackgroundColor3
			knob.Position = knobGoal.Position
		else
			tween(track, trackGoal)
			tween(knob, knobGoal)
		end
	end

	row.Activated:Connect(function()
		setPath(self.Config, item.Path, getPath(self.Config, item.Path) ~= true)
		sync(false)
		self:_changed()
	end)
	sync(true)
	table.insert(self._controls, sync)
end

function Menu:_choice(item, order: number)
	local row = self:_row(30, order)
	self:_label(row, item.Choice)
	local value = create("TextLabel", {
		AnchorPoint = Vector2.new(1, 0.5),
		BackgroundTransparency = 1,
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(120, 20),
		Font = FONT_BOLD,
		TextColor3 = THEME.Accent,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = row,
	})

	local function sync()
		value.Text = tostring(getPath(self.Config, item.Path)) .. "  ›"
	end

	row.Activated:Connect(function()
		local options = item.Options
		local index = table.find(options, getPath(self.Config, item.Path)) or 0
		setPath(self.Config, item.Path, options[index % #options + 1])
		sync()
		self:_changed()
	end)
	sync()
	table.insert(self._controls, sync)
end

function Menu:_slider(item, order: number)
	local row = self:_row(50, order)
	self:_label(row, item.Slider)
	local value = create("TextLabel", {
		AnchorPoint = Vector2.new(1, 0),
		BackgroundTransparency = 1,
		Position = UDim2.new(1, -12, 0, 0),
		Size = UDim2.fromOffset(110, 30),
		Font = FONT_BOLD,
		TextColor3 = THEME.Accent,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = row,
	})
	local bar = create("Frame", {
		Position = UDim2.new(0, 12, 1, -15),
		Size = UDim2.new(1, -24, 0, 4),
		BackgroundColor3 = THEME.Off,
		Parent = row,
	}, { corner(2) })
	local fill = create("Frame", {
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = THEME.Accent,
		Parent = bar,
	}, { corner(2) })
	local knob = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromOffset(12, 12),
		BackgroundColor3 = THEME.Knob,
		Parent = bar,
	}, { corner(6) })

	local function sync()
		local current = getPath(self.Config, item.Path)
		local alpha = math.clamp((current - item.Min) / (item.Max - item.Min), 0, 1)
		fill.Size = UDim2.fromScale(alpha, 1)
		knob.Position = UDim2.fromScale(alpha, 0.5)
		value.Text = item.Format(current)
	end

	local function setFromX(x: number)
		local alpha = math.clamp((x - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1), 0, 1)
		local raw = item.Min + (item.Max - item.Min) * alpha
		local snapped = math.clamp(math.round(raw / item.Step) * item.Step, item.Min, item.Max)
		if snapped ~= getPath(self.Config, item.Path) then
			setPath(self.Config, item.Path, snapped)
			sync()
			self:_changed()
		end
	end

	local dragging = false
	row.InputBegan:Connect(function(input)
		if isPress(input) then
			dragging = true
			self._content.ScrollingEnabled = false -- don't scroll the list while dragging on touch
			setFromX(input.Position.X)
		end
	end)
	self:_connect(UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			setFromX(input.Position.X)
		end
	end))
	self:_connect(UserInputService.InputEnded:Connect(function(input)
		if dragging and isPress(input) then
			dragging = false
			self._content.ScrollingEnabled = true
		end
	end))
	sync()
	table.insert(self._controls, sync)
end

function Menu:_makeDraggable(handle: GuiObject, panel: GuiObject)
	local dragStart: Vector3? = nil
	local startPosition = panel.Position
	local dragInput: InputObject? = nil

	handle.InputBegan:Connect(function(input)
		if isPress(input) then
			dragStart, startPosition, dragInput = input.Position, panel.Position, input
		end
	end)
	self:_connect(UserInputService.InputChanged:Connect(function(input)
		if not dragStart then
			return
		end
		local isMouse = input.UserInputType == Enum.UserInputType.MouseMovement
		if isMouse or input == dragInput then
			local delta = input.Position - dragStart
			panel.Position = UDim2.new(
				startPosition.X.Scale,
				startPosition.X.Offset + delta.X,
				startPosition.Y.Scale,
				startPosition.Y.Offset + delta.Y
			)
		end
	end))
	self:_connect(UserInputService.InputEnded:Connect(function(input)
		if isPress(input) then
			dragStart, dragInput = nil, nil
		end
	end))
end

function Menu:_build()
	local config = self.Config
	local gui = create("ScreenGui", {
		Name = "ESPMenu",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = config.DisplayOrder + 1,
		Parent = LocalPlayer:WaitForChild("PlayerGui"),
	})

	local panel = create("Frame", {
		Name = "Panel",
		Active = true,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 24, 0.5, 0),
		Size = UDim2.fromOffset(PANEL_SIZE.X, PANEL_SIZE.Y),
		BackgroundColor3 = THEME.Background,
		Visible = false,
		Parent = gui,
	}, { corner(10), stroke(THEME.Border) })
	local scale = create("UIScale", { Scale = 0.94, Parent = panel })

	-- shrink to fit small (phone) screens
	local sizeConstraint = create("UISizeConstraint", { MaxSize = PANEL_SIZE, Parent = panel })
	local function fitToScreen()
		local camera = workspace.CurrentCamera
		local viewport = if camera then camera.ViewportSize else Vector2.new(1920, 1080)
		sizeConstraint.MaxSize = Vector2.new(PANEL_SIZE.X, math.max(220, math.min(PANEL_SIZE.Y, viewport.Y - 80)))
	end
	fitToScreen()
	if workspace.CurrentCamera then
		self:_connect(workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fitToScreen))
	end

	-- header (also the drag handle)
	local header = create("Frame", {
		Name = "Header",
		Active = true,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
		Parent = panel,
	})
	create("Frame", {
		Name = "Accent",
		BackgroundColor3 = THEME.Accent,
		Position = UDim2.fromOffset(14, 15),
		Size = UDim2.fromOffset(4, 20),
		Parent = header,
	}, { corner(2) })
	create("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(26, 9),
		Size = UDim2.new(1, -80, 0, 18),
		Font = FONT_BOLD,
		Text = "ESP",
		TextColor3 = THEME.Text,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = header,
	})
	create("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(26, 27),
		Size = UDim2.new(1, -80, 0, 14),
		Font = FONT,
		Text = "Visual settings",
		TextColor3 = THEME.SubText,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = header,
	})
	local close = create("TextButton", {
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0.5),
		AutoButtonColor = false,
		BackgroundColor3 = THEME.Surface,
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(26, 26),
		Font = FONT_BOLD,
		Text = "×",
		TextColor3 = THEME.SubText,
		TextSize = 18,
		Parent = header,
	}, { corner(6) })
	close.Activated:Connect(function()
		self:Close()
	end)
	create("Frame", {
		Name = "Divider",
		BackgroundColor3 = THEME.Border,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0, HEADER_HEIGHT - 1),
		Size = UDim2.new(1, 0, 0, 1),
		Parent = panel,
	})
	self:_makeDraggable(header, panel)

	-- scrolling list of controls
	local content = create("ScrollingFrame", {
		Name = "Content",
		Active = true,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, HEADER_HEIGHT),
		Size = UDim2.new(1, 0, 1, -(HEADER_HEIGHT + FOOTER_HEIGHT)),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = THEME.Border,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = panel,
	}, {
		create("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
		create("UIPadding", {
			PaddingLeft = UDim.new(0, 10),
			PaddingRight = UDim.new(0, 14),
			PaddingTop = UDim.new(0, 2),
			PaddingBottom = UDim.new(0, 10),
		}),
	})
	self._content = content

	for order, item in LAYOUT do
		if item.Section then
			self:_section(item, order)
		elseif item.Toggle then
			self:_toggle(item, order)
		elseif item.Choice then
			self:_choice(item, order)
		elseif item.Slider then
			self:_slider(item, order)
		end
	end

	-- footer: live counts + keybind hint
	local footer = create("Frame", {
		Name = "Footer",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 12, 1, -FOOTER_HEIGHT),
		Size = UDim2.new(1, -24, 0, FOOTER_HEIGHT),
		Parent = panel,
	})
	local function footerLabel(alignment: Enum.TextXAlignment): TextLabel
		return create("TextLabel", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Font = FONT,
			Text = "",
			TextColor3 = THEME.SubText,
			TextSize = 11,
			TextXAlignment = alignment,
			Parent = footer,
		})
	end
	self._counts = footerLabel(Enum.TextXAlignment.Left)
	local hint = footerLabel(Enum.TextXAlignment.Right)
	hint.Text = if UserInputService.KeyboardEnabled
		then `{config.MenuKey.Name} menu · {config.ToggleKey.Name} toggle`
		else "tap ESP to close"

	-- floating button for touch devices (they have no keybinds)
	if UserInputService.TouchEnabled then
		local button = create("TextButton", {
			Name = "TouchToggle",
			AnchorPoint = Vector2.new(0, 0.5),
			AutoButtonColor = false,
			BackgroundColor3 = THEME.Background,
			Position = UDim2.new(0, 12, 0.3, 0),
			Size = UDim2.fromOffset(54, 30),
			Font = FONT_BOLD,
			Text = "ESP",
			TextColor3 = THEME.Text,
			TextSize = 13,
			Visible = false,
			Parent = gui,
		}, { corner(8), stroke(THEME.Accent) })
		button.Activated:Connect(function()
			self:Toggle()
		end)
		self._touchButton = button
	end

	self._gui, self._panel, self._scale = gui, panel, scale
end

function Menu:_runCounter()
	if self._counterRunning then
		return
	end
	self._counterRunning = true
	task.spawn(function()
		while self.IsOpen and not self._destroyed do
			local tracked, drawn = self.Controller:GetCounts()
			self._counts.Text = `{drawn} drawn · {tracked} tracked`
			task.wait(0.5)
		end
		self._counterRunning = false
	end)
end

function Menu.new(config, controller)
	local self = setmetatable({
		Config = config,
		Controller = controller,
		IsOpen = false,
		Available = false,
		_controls = {} :: { (boolean?) -> () },
		_connections = {} :: { RBXScriptConnection },
		_destroyed = false,
		_counterRunning = false,
	}, Menu)
	self:_build()
	return self
end

function Menu:Refresh()
	for _, sync in self._controls do
		sync(true)
	end
end

function Menu:Open()
	if self.IsOpen or not self.Available or self._destroyed then
		return
	end
	self.IsOpen = true
	self:Refresh()
	self._scale.Scale = 0.94
	self._panel.Visible = true
	tween(self._scale, { Scale = 1 }, POP)
	self:_runCounter()
end

function Menu:Close()
	if not self.IsOpen then
		return
	end
	self.IsOpen = false
	local closing = TweenService:Create(self._scale, FAST, { Scale = 0.94 })
	closing.Completed:Once(function()
		if not self.IsOpen then
			self._panel.Visible = false
		end
	end)
	closing:Play()
end

function Menu:Toggle()
	if self.IsOpen then
		self:Close()
	else
		self:Open()
	end
end

function Menu:SetAvailable(available: boolean)
	self.Available = available
	if self._touchButton then
		self._touchButton.Visible = available
	end
	if not available then
		self:Close()
	end
end

function Menu:Destroy()
	self._destroyed = true
	self.IsOpen = false
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	self._gui:Destroy()
end

return Menu
