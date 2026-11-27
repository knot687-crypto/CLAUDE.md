--!strict
--[[
	CameraFX: speed-driven field of view, a roll that leans into swings, and short shakes on
	heavy landings. Runs after the default camera so it composes with any camera mode.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(script.Parent.Parent.Config)
local Spring = require(script.Parent.Parent.Math.Spring)

local CameraFX = {}
CameraFX.__index = CameraFX

export type FX = typeof(setmetatable({} :: {
	fov: number,
	roll: number,
	rollTarget: number,
	speed: number,
	shake: number,
	shakeT: number,
	bound: boolean,
}, CameraFX))

local BIND = "SpiderKitCameraFX"

local function smoothstep(a: number, b: number, x: number): number
	local t = math.clamp((x - a) / (b - a), 0, 1)
	return t * t * (3 - 2 * t)
end

function CameraFX.new(): FX
	local self = setmetatable({
		fov = Config.BaseFov,
		roll = 0,
		rollTarget = 0,
		speed = 0,
		shake = 0,
		shakeT = 0,
		bound = true,
	}, CameraFX)
	RunService:BindToRenderStep(BIND, Enum.RenderPriority.Camera.Value + 1, function(dt)
		self:_apply(dt)
	end)
	return self
end

-- Called by the controller every frame.
function CameraFX.set(self: FX, speed: number, rollDegrees: number)
	self.speed = speed
	self.rollTarget = math.rad(rollDegrees)
end

-- Landing/impact shake; strength ~0..1
function CameraFX.kick(self: FX, strength: number)
	self.shake = math.max(self.shake, math.clamp(strength, 0, 1))
end

function CameraFX._apply(self: FX, dt: number)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local target = Config.BaseFov + (Config.MaxFov - Config.BaseFov) * smoothstep(Config.FovSpeedStart, Config.FovSpeedFull, self.speed)
	self.fov = Spring.damp(self.fov, target, 0.25, dt)
	cam.FieldOfView = self.fov
	self.roll = Spring.damp(self.roll, self.rollTarget, 0.18, dt)
	local cf = cam.CFrame
	if math.abs(self.roll) > 1e-4 then
		cf *= CFrame.Angles(0, 0, self.roll)
	end
	if self.shake > 0.001 then
		self.shakeT += dt
		local s = self.shake * self.shake
		local t = self.shakeT * 38
		cf *= CFrame.new(math.sin(t * 1.3) * 0.12 * s, math.sin(t * 1.9 + 1.7) * 0.18 * s, 0)
			* CFrame.Angles(math.sin(t * 1.1 + 0.6) * 0.012 * s, 0, math.sin(t * 0.9) * 0.01 * s)
		self.shake = Spring.damp(self.shake, 0, 0.09, dt)
	end
	cam.CFrame = cf
end

function CameraFX.destroy(self: FX)
	if self.bound then
		RunService:UnbindFromRenderStep(BIND)
		self.bound = false
	end
	local cam = Workspace.CurrentCamera
	if cam then
		cam.FieldOfView = Config.BaseFov
	end
end

return CameraFX
