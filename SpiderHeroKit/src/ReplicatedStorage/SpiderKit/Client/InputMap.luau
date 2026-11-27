--!strict
--[[
	InputMap: keyboard/mouse, gamepad and touch bindings through ContextActionService.

	  action   keyboard / mouse       gamepad      touch
	  Swing    Left mouse (hold)      R2 (hold)    "Web" button (hold)
	  Zip      E                      L2           "Zip" button
	  Sprint   Left Shift (hold)      L3 (toggle)  "Run" button (toggle)
	  Drop     Left Ctrl / C          B            "Drop" button
	  Jump     Space (engine)         A            jump button (engine)

	Jumps use UserInputService.JumpRequest so every device and the touch jump button work.
]]

local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")

local InputMap = {}
InputMap.__index = InputMap

export type Input = typeof(setmetatable({} :: {
	swingHeld: boolean,
	swingPressed: boolean,
	zipPressed: boolean,
	sprintHeld: boolean,
	sprintToggle: boolean,
	dropPressed: boolean,
	jumpPressed: boolean,
	conns: { RBXScriptConnection },
}, InputMap))

local PRIORITY = Enum.ContextActionPriority.High.Value

function InputMap.new(): Input
	local self = setmetatable({
		swingHeld = false,
		swingPressed = false,
		zipPressed = false,
		sprintHeld = false,
		sprintToggle = false,
		dropPressed = false,
		jumpPressed = false,
		conns = {},
	}, InputMap)

	local function bind(name: string, title: string, fn: (Enum.UserInputState, InputObject) -> (), ...: any)
		ContextActionService:BindActionAtPriority(name, function(_, state, obj)
			fn(state, obj)
			return Enum.ContextActionResult.Pass
		end, true, PRIORITY, ...)
		ContextActionService:SetTitle(name, title)
	end

	bind("SpiderSwing", "Web", function(state)
		if state == Enum.UserInputState.Begin then
			self.swingHeld = true
			self.swingPressed = true
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			self.swingHeld = false
		end
	end, Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR2)

	bind("SpiderZip", "Zip", function(state)
		if state == Enum.UserInputState.Begin then
			self.zipPressed = true
		end
	end, Enum.KeyCode.E, Enum.KeyCode.ButtonL2)

	bind("SpiderSprint", "Run", function(state, obj)
		local toggleDevice = obj.UserInputType == Enum.UserInputType.Touch or obj.KeyCode == Enum.KeyCode.ButtonL3
		if toggleDevice then
			if state == Enum.UserInputState.Begin then
				self.sprintToggle = not self.sprintToggle
			end
		elseif state == Enum.UserInputState.Begin then
			self.sprintHeld = true
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			self.sprintHeld = false
		end
	end, Enum.KeyCode.LeftShift, Enum.KeyCode.ButtonL3)

	bind("SpiderDrop", "Drop", function(state)
		if state == Enum.UserInputState.Begin then
			self.dropPressed = true
		end
	end, Enum.KeyCode.LeftControl, Enum.KeyCode.C, Enum.KeyCode.ButtonB)

	-- touch button layout (right side, above the jump button)
	if UserInputService.TouchEnabled then
		pcall(function()
			ContextActionService:SetPosition("SpiderSwing", UDim2.new(1, -150, 1, -210))
			ContextActionService:SetPosition("SpiderZip", UDim2.new(1, -230, 1, -150))
			ContextActionService:SetPosition("SpiderSprint", UDim2.new(1, -230, 1, -230))
			ContextActionService:SetPosition("SpiderDrop", UDim2.new(1, -95, 1, -285))
		end)
	end

	table.insert(self.conns, UserInputService.JumpRequest:Connect(function()
		self.jumpPressed = true
	end))
	return self
end

function InputMap.sprinting(self: Input): boolean
	return self.sprintHeld or self.sprintToggle
end

-- Clears the edge-triggered presses; call once per frame after the controller has read them.
function InputMap.consume(self: Input)
	self.swingPressed = false
	self.zipPressed = false
	self.dropPressed = false
	self.jumpPressed = false
end

function InputMap.destroy(self: Input)
	for _, name in { "SpiderSwing", "SpiderZip", "SpiderSprint", "SpiderDrop" } do
		ContextActionService:UnbindAction(name)
	end
	for _, c in self.conns do
		c:Disconnect()
	end
	table.clear(self.conns)
end

return InputMap
