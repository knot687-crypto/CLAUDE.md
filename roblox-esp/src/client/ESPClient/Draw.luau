--[[
	Draw
	Lightweight GUI primitives positioned in viewport pixels (the ScreenGui that
	owns them must have IgnoreGuiInset = true). Every primitive is created once
	and then only has its properties updated, and every setter skips writes
	whose value has not changed, so per-frame updates stay cheap.
]]

local Draw = {}

local BLACK = Color3.new(0, 0, 0)

local function round(n: number): number
	return math.floor(n + 0.5)
end
Draw.round = round

-- Line ------------------------------------------------------------------------
-- A Frame used either as an axis-aligned rectangle (Rect) or as a rotated
-- segment between two points (Segment).
--
-- The optional outline is a separate black frame one ZIndex *below* the
-- coloured one (rather than a UIStroke). With every outline underneath every
-- coloured frame, lines that touch or overlap (box corners, skeleton joints)
-- join cleanly instead of an outline cutting a notch into a neighbour.

local Line = {}
Line.__index = Line

local function newFrame(parent: Instance, zIndex: number): Frame
	local frame = Instance.new("Frame")
	frame.Name = "Line"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.BorderSizePixel = 0
	frame.ZIndex = zIndex
	frame.Visible = false
	frame.Parent = parent
	return frame
end

-- `zIndex` is the coloured frame's ZIndex; an outline sits at zIndex - 1.
function Line.new(parent: Instance, zIndex: number, outlined: boolean)
	local outline: Frame? = nil
	if outlined then
		outline = newFrame(parent, zIndex - 1)
		outline.BackgroundColor3 = BLACK
	end
	return setmetatable({
		Frame = newFrame(parent, zIndex),
		Outline = outline,
		Shown = false,
		_color = nil :: Color3?,
		_transparency = -1,
	}, Line)
end

function Line:_style(color: Color3, transparency: number)
	local frame = self.Frame
	if self._color ~= color then
		self._color = color
		frame.BackgroundColor3 = color
	end
	if self._transparency ~= transparency then
		self._transparency = transparency
		frame.BackgroundTransparency = transparency
		if self.Outline then
			-- the outline fades a little faster so faded lines don't look heavy
			self.Outline.BackgroundTransparency = math.min(1, 0.15 + transparency * 1.1)
		end
	end
	if not self.Shown then
		self.Shown = true
		frame.Visible = true
		if self.Outline then
			self.Outline.Visible = true
		end
	end
end

-- Axis-aligned rectangle with its top-left corner at (x, y).
function Line:Rect(x: number, y: number, w: number, h: number, color: Color3, transparency: number)
	local cx, cy = x + w * 0.5, y + h * 0.5
	self.Frame.Position = UDim2.fromOffset(cx, cy)
	self.Frame.Size = UDim2.fromOffset(w, h)
	local outline = self.Outline
	if outline then
		outline.Position = UDim2.fromOffset(cx, cy)
		outline.Size = UDim2.fromOffset(w + 2, h + 2)
	end
	self:_style(color, transparency)
end

-- Rotated segment from a to b.
function Line:Segment(a: Vector2, b: Vector2, thickness: number, color: Color3, transparency: number)
	local delta = b - a
	local length = delta.Magnitude
	local position = UDim2.fromOffset((a.X + b.X) * 0.5, (a.Y + b.Y) * 0.5)
	local rotation = math.deg(math.atan2(delta.Y, delta.X))

	local frame = self.Frame
	frame.Position = position
	frame.Size = UDim2.fromOffset(length + 1, thickness)
	frame.Rotation = rotation

	local outline = self.Outline
	if outline then
		outline.Position = position
		outline.Size = UDim2.fromOffset(length + 3, thickness + 2)
		outline.Rotation = rotation
	end
	self:_style(color, transparency)
end

function Line:Hide()
	if self.Shown then
		self.Shown = false
		self.Frame.Visible = false
		if self.Outline then
			self.Outline.Visible = false
		end
	end
end

Draw.Line = Line

-- Label -----------------------------------------------------------------------
-- Outlined text. The anchor decides which point of the text sits at (x, y):
-- (0.5, 1) = centred above the point, (1, 0.5) = right-aligned left of it, etc.

local Label = {}
Label.__index = Label

local LABEL_WIDTH = 320

function Label.new(parent: Instance, zIndex: number, font: Enum.Font, textSize: number, anchor: Vector2)
	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.AnchorPoint = anchor
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromOffset(LABEL_WIDTH, textSize + 2)
	label.Font = font
	label.TextSize = textSize
	label.Text = ""
	label.TextXAlignment = if anchor.X < 0.25
		then Enum.TextXAlignment.Left
		elseif anchor.X > 0.75 then Enum.TextXAlignment.Right
		else Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.ZIndex = zIndex
	label.Visible = false

	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Color = BLACK
	stroke.Thickness = 1
	stroke.Parent = label

	label.Parent = parent
	return setmetatable({
		Label = label,
		Stroke = stroke,
		Shown = false,
		_text = "",
		_color = nil :: Color3?,
		_transparency = -1,
	}, Label)
end

function Label:Set(text: string, x: number, y: number, color: Color3, transparency: number)
	local label = self.Label
	if self._text ~= text then
		self._text = text
		label.Text = text
	end
	label.Position = UDim2.fromOffset(x, y)
	if self._color ~= color then
		self._color = color
		label.TextColor3 = color
	end
	if self._transparency ~= transparency then
		self._transparency = transparency
		label.TextTransparency = transparency
		self.Stroke.Transparency = math.min(1, 0.25 + transparency * 0.9)
	end
	if not self.Shown then
		self.Shown = true
		label.Visible = true
	end
end

function Label:Hide()
	if self.Shown then
		self.Shown = false
		self.Label.Visible = false
	end
end

Draw.Label = Label

-- Bar -------------------------------------------------------------------------
-- Vertical bar with a 1px dark border that fills from the bottom.

local Bar = {}
Bar.__index = Bar

function Bar.new(parent: Instance, zIndex: number)
	local back = Instance.new("Frame")
	back.Name = "Bar"
	back.BackgroundColor3 = BLACK
	back.BorderSizePixel = 0
	back.ZIndex = zIndex
	back.Visible = false

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BorderSizePixel = 0
	fill.ZIndex = zIndex + 1
	fill.Parent = back

	back.Parent = parent
	return setmetatable({
		Back = back,
		Fill = fill,
		Shown = false,
		_color = nil :: Color3?,
		_transparency = -1,
	}, Bar)
end

-- (x, y, w, h) is the inner area; fraction is clamped to [0, 1].
function Bar:Set(x: number, y: number, w: number, h: number, fraction: number, color: Color3, transparency: number)
	local fillHeight = round(h * math.clamp(fraction, 0, 1))
	self.Back.Position = UDim2.fromOffset(x - 1, y - 1)
	self.Back.Size = UDim2.fromOffset(w + 2, h + 2)
	self.Fill.Position = UDim2.fromOffset(1, 1 + h - fillHeight)
	self.Fill.Size = UDim2.fromOffset(w, fillHeight)
	if self._color ~= color then
		self._color = color
		self.Fill.BackgroundColor3 = color
	end
	if self._transparency ~= transparency then
		self._transparency = transparency
		self.Back.BackgroundTransparency = math.min(1, 0.35 + transparency * 0.65)
		self.Fill.BackgroundTransparency = transparency
	end
	if not self.Shown then
		self.Shown = true
		self.Back.Visible = true
	end
end

function Bar:Hide()
	if self.Shown then
		self.Shown = false
		self.Back.Visible = false
	end
end

Draw.Bar = Bar

return Draw
