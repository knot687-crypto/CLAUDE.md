--!strict
--[[
	WebVisuals: web lines drawn as Beams from a character's hand to a world point.
	  * a shot travels from the hand to the target in a few frames before the line goes taut
	  * a slack line sags (CurveSize) while the hero closes in on the anchor
	  * releasing fades the line out instead of popping it
	Used for the local hero (driven by SpiderController) and for other players (driven by the
	replicated attributes in RemoteAnimator).
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(script.Parent.Parent.Config)

local WebVisuals = {}
WebVisuals.__index = WebVisuals

-- where the line leaves the hand, in the hand part's frame (under the wrist, palm side)
local HAND_OFFSET = {
	Right = Vector3.new(-0.07, -0.14, -0.005),
	Left = Vector3.new(0.07, -0.14, -0.005),
}
local SHOT_SPEED = 900 -- studs/s the web tip travels

type Line = {
	beam: Beam,
	tip: Attachment,
	from: Attachment,
	target: Vector3,
	shot: number, -- 0..1 travel progress
	fade: number?, -- seconds left while fading out
	length: number?, -- rope length (for sag)
}

export type Webs = typeof(setmetatable({} :: {
	character: Model,
	hands: { [string]: Attachment },
	lines: { [string]: Line },
	conn: RBXScriptConnection?,
}, WebVisuals))

local function makeBeam(a0: Attachment, a1: Attachment): Beam
	local b = Instance.new("Beam")
	b.Name = "SpiderWeb"
	b.Attachment0 = a0
	b.Attachment1 = a1
	b.Color = ColorSequence.new(Config.WebColor)
	b.Width0 = Config.WebWidth
	b.Width1 = Config.WebWidth * 0.75
	b.LightEmission = 0.25
	b.LightInfluence = 0.6
	b.FaceCamera = true
	b.Segments = 14
	b.Transparency = NumberSequence.new(0.04)
	b.Parent = a0
	return b
end

function WebVisuals.new(character: Model): Webs
	local self = setmetatable({
		character = character,
		hands = {},
		lines = {},
		conn = nil,
	}, WebVisuals)
	for side, off in HAND_OFFSET do
		local hand = character:FindFirstChild(side .. "Hand")
		if hand and hand:IsA("BasePart") then
			local a = Instance.new("Attachment")
			a.Name = "WebAttach"
			a.Position = off
			a.Parent = hand
			self.hands[side] = a
		end
	end
	self.conn = RunService.RenderStepped:Connect(function(dt)
		self:_update(dt)
	end)
	return self
end

-- Shoots a line from `hand` ("Right"/"Left") to `target`. `key` names the line so a zip can
-- hold two at once; it defaults to the hand.
function WebVisuals.fire(self: Webs, hand: string, target: Vector3, key: string?, ropeLength: number?)
	local from = self.hands[hand]
	if not from then
		return
	end
	local k = key or hand
	self:release(k, true)
	local tip = Instance.new("Attachment")
	tip.Name = "WebTip"
	tip.WorldPosition = from.WorldPosition
	tip.Parent = Workspace.Terrain
	self.lines[k] = {
		beam = makeBeam(from, tip),
		tip = tip,
		from = from,
		target = target,
		shot = 0,
		fade = nil,
		length = ropeLength,
	}
end

function WebVisuals.retarget(self: Webs, key: string, target: Vector3)
	local l = self.lines[key]
	if l then
		l.target = target
	end
end

function WebVisuals.setLength(self: Webs, key: string, length: number?)
	local l = self.lines[key]
	if l then
		l.length = length
	end
end

function WebVisuals.release(self: Webs, key: string, instant: boolean?)
	local l = self.lines[key]
	if not l then
		return
	end
	if instant then
		l.beam:Destroy()
		l.tip:Destroy()
		self.lines[key] = nil
	elseif not l.fade then
		l.fade = 0.14
	end
end

function WebVisuals.releaseAll(self: Webs)
	for k in self.lines do
		self:release(k)
	end
end

function WebVisuals.has(self: Webs, key: string): boolean
	local l = self.lines[key]
	return l ~= nil and l.fade == nil
end

function WebVisuals._update(self: Webs, dt: number)
	for k, l in self.lines do
		if not l.from.Parent then
			self:release(k, true)
			continue
		end
		local p0 = l.from.WorldPosition
		local dist = (l.target - p0).Magnitude
		if l.shot < 1 then
			l.shot = math.min(1, l.shot + SHOT_SPEED * dt / math.max(dist, 1))
			-- the tip flies out along a slight arc
			local s = l.shot
			l.tip.WorldPosition = p0:Lerp(l.target, s) + Vector3.new(0, math.sin(s * math.pi) * dist * 0.03, 0)
			l.beam.CurveSize0 = 0
			l.beam.CurveSize1 = 0
		else
			l.tip.WorldPosition = l.target
			-- slack line: sag proportional to how much shorter the span is than the rope
			local sag = 0
			if l.length and dist < l.length then
				sag = math.min((l.length - dist) * 0.35, 12)
			end
			l.beam.CurveSize0 = -sag * 0.5
			l.beam.CurveSize1 = -sag * 0.5
		end
		if l.fade then
			l.fade -= dt
			local a = math.clamp(1 - l.fade / 0.14, 0, 1)
			l.beam.Transparency = NumberSequence.new(0.04 + 0.96 * a)
			if l.fade <= 0 then
				self:release(k, true)
			end
		end
	end
end

function WebVisuals.destroy(self: Webs)
	for k in self.lines do
		self:release(k, true)
	end
	for _, a in self.hands do
		a:Destroy()
	end
	if self.conn then
		self.conn:Disconnect()
		self.conn = nil
	end
end

return WebVisuals
