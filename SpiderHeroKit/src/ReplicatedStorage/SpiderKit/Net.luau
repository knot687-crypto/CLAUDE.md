--!strict
--[[
	Net: the wire format between the local SpiderController, the server relay and the remote
	animators on other clients.

	Client -> server (RemoteEvent "SpiderKitRemote"):
	  { k = "s", state = "Swing", anchor = Vector3?, hand = "Right"?, zip = Vector3?, normal = Vector3?, sprint = boolean? }
	  { k = "e", name = "Trick", arg = "FrontFlip"? }
	Server -> everyone (character attributes, replicated by the engine):
	  SpiderState, SwingAnchor, SwingHand, ZipTarget, WallNormal, Sprint
	  SpiderEvent = "<name>|<arg>|<sequence>"   one-shot events (jumps, tricks, web shots...)
]]

local Net = {}

Net.REMOTE_NAME = "SpiderKitRemote"

Net.States = {
	Ground = true,
	Air = true,
	Swing = true,
	Zip = true,
	WallCrawl = true,
	WallRun = true,
	Perch = true,
	Ledge = true,
}

-- one-shot events other clients need to see (landings are derived locally from physics)
Net.Events = {
	Jump = true,
	SprintJump = true,
	SwingStart = true,
	SwingRelease = true,
	Trick = true,
	WallJump = true,
	LedgeVault = true,
	WebFire = true,
}

Net.Tricks = {
	FrontFlip = true,
	Backflip = true,
	Corkscrew = true,
	Cartwheel = true,
	Swan = true,
}

Net.Hands = { Right = true, Left = true }

-- Furthest a replicated anchor/target may be from the character (anti-garbage, not anti-cheat).
Net.MAX_REACH = 700

-- Client: waits for the relay the server creates. Server: creates it.
function Net.remote(create: boolean?): RemoteEvent
	local rs = game:GetService("ReplicatedStorage")
	if create then
		local existing = rs:FindFirstChild(Net.REMOTE_NAME)
		if existing and existing:IsA("RemoteEvent") then
			return existing
		end
		local r = Instance.new("RemoteEvent")
		r.Name = Net.REMOTE_NAME
		r.Parent = rs
		return r
	end
	return rs:WaitForChild(Net.REMOTE_NAME) :: RemoteEvent
end

function Net.encodeEvent(name: string, arg: string?, seq: number): string
	return string.format("%s|%s|%d", name, arg or "", seq)
end

function Net.decodeEvent(s: string): (string?, string?)
	local name, arg = string.match(s, "^([^|]*)|([^|]*)|")
	if not name or name == "" then
		return nil, nil
	end
	return name, if arg == "" then nil else arg
end

local function finiteVector(v: any): boolean
	if typeof(v) ~= "Vector3" then
		return false
	end
	local x, y, z = v.X, v.Y, v.Z
	return x == x and y == y and z == z and math.abs(x) < 1e6 and math.abs(y) < 1e6 and math.abs(z) < 1e6
end
Net.finiteVector = finiteVector

-- Validates a client payload; returns a sanitized copy or nil.
function Net.sanitize(payload: any, rootPos: Vector3): any
	if type(payload) ~= "table" then
		return nil
	end
	if payload.k == "s" then
		if type(payload.state) ~= "string" or not Net.States[payload.state] then
			return nil
		end
		local out: any = { k = "s", state = payload.state, sprint = payload.sprint == true }
		for _, key in { "anchor", "zip" } do
			local v = payload[key]
			if v ~= nil then
				if not finiteVector(v) or (v - rootPos).Magnitude > Net.MAX_REACH then
					return nil
				end
				out[key] = v
			end
		end
		if payload.normal ~= nil then
			local n = payload.normal
			if not finiteVector(n) or n.Magnitude < 0.5 or n.Magnitude > 1.5 then
				return nil
			end
			out.normal = n.Unit
		end
		if payload.hand ~= nil then
			if type(payload.hand) ~= "string" or not Net.Hands[payload.hand] then
				return nil
			end
			out.hand = payload.hand
		end
		return out
	elseif payload.k == "e" then
		if type(payload.name) ~= "string" or not Net.Events[payload.name] then
			return nil
		end
		local arg = payload.arg
		if arg ~= nil then
			if type(arg) ~= "string" or #arg > 16 then
				return nil
			end
			if payload.name == "Trick" and not Net.Tricks[arg] then
				return nil
			end
			if (payload.name == "SwingStart" or payload.name == "WebFire") and not Net.Hands[arg] then
				return nil
			end
		end
		return { k = "e", name = payload.name, arg = arg }
	end
	return nil
end

return Net
