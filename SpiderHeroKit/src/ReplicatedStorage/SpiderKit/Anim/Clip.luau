--!strict
--[[
	Clip
	----
	Compiles authored keyframe clips and samples them into poses.

	Interpolation: per-channel cubic Hermite through every key (Euler XYZ in radians, translation in
	studs), with "auto-clamped" tangents: smooth through in-between keys, flat at extremes and
	monotone (Fritsch-Carlson) so motion never overshoots a key. That's the default behaviour of
	the graph editor in professional animation packages, and it is what gives clips clean arcs and
	ease-in/ease-out without manual tangent work.

	Per-key overrides (key.ease): "flat" (hold-style ease in/out), "linear", "step".
]]

local Quat = require(script.Parent.Parent.Math.Quat)
local RigDefinition = require(script.Parent.Parent.Rig.RigDefinition)

local rad = math.rad

export type RawKey = { any } -- {t, rx, ry, rz, px?, py?, pz?, ease?}
export type RawClip = {
	name: string,
	length: number,
	loop: boolean?,
	tracks: { [string]: { RawKey } },
	hands: { [string]: { { any } } }?,
	events: { { any } }?,
	speed: number?,
	meta: { [string]: any }?,
}

export type Track = {
	joint: number,
	times: { number },
	vals: { number }, -- 6 per key
	tin: { number },
	tout: { number },
	step: { boolean },
	hasPos: boolean,
	n: number, -- real key count (excluding loop wrap key)
}

export type HandKey = { t: number, preset: string, blend: number }

export type Clip = {
	name: string,
	length: number,
	loop: boolean,
	tracks: { Track },
	trackByJoint: { [number]: Track },
	hands: { R: { HandKey }?, L: { HandKey }? },
	events: { { t: number, name: string, data: any? } },
	speed: number?,
	meta: { [string]: any },
}

local Clip = {}

local function computeTangents(times: { number }, vals: { number }, eases: { string? }, loop: boolean, length: number, n: number, tin: { number }, tout: { number })
	for c = 1, 6 do
		for i = 1, n do
			local v = vals[(i - 1) * 6 + c]
			local tPrev, vPrev, tNext, vNext
			if i > 1 then
				tPrev, vPrev = times[i - 1], vals[(i - 2) * 6 + c]
			elseif loop and n > 1 then
				tPrev, vPrev = times[n] - length, vals[(n - 1) * 6 + c]
			end
			if i < n then
				tNext, vNext = times[i + 1], vals[i * 6 + c]
			elseif loop and n > 1 then
				tNext, vNext = times[1] + length, vals[c]
			end
			local ease = eases[i]
			local mIn, mOut = 0, 0
			local dl = if tPrev then (v - vPrev) / math.max(times[i] - tPrev, 1e-6) else nil
			local dr = if tNext then (vNext - v) / math.max(tNext - times[i], 1e-6) else nil
			if ease == "flat" or ease == "step" then
				mIn, mOut = 0, 0
			elseif ease == "linear" then
				mIn = dl or 0
				mOut = dr or 0
			elseif dl and dr then
				if dl * dr <= 0 then
					mIn, mOut = 0, 0 -- extremum: flat tangent, no overshoot
				else
					local m = (vNext - vPrev) / math.max(tNext - tPrev, 1e-6)
					local lim = 3 * math.min(math.abs(dl), math.abs(dr))
					if math.abs(m) > lim then
						m = math.sign(m) * lim
					end
					mIn, mOut = m, m
				end
			else
				mIn, mOut = 0, 0 -- clip ends ease in/out
			end
			tin[(i - 1) * 6 + c] = mIn
			tout[(i - 1) * 6 + c] = mOut
		end
	end
end

function Clip.compile(raw: RawClip): Clip
	assert(raw.name and raw.length and raw.tracks, "clip needs name, length and tracks")
	local loop = raw.loop == true
	local tracks: { Track } = {}
	local byJoint: { [number]: Track } = {}
	for jointName, keys in raw.tracks do
		local index = RigDefinition.JointIndex[jointName]
		assert(index, "clip '" .. raw.name .. "' references unknown joint '" .. tostring(jointName) .. "'")
		table.sort(keys, function(a, b)
			return a[1] < b[1]
		end)
		local times, vals, eases, step = {}, {}, {}, {}
		local hasPos = false
		local n = 0
		for _, k in keys do
			local t = k[1]
			if loop then
				if t >= raw.length - 1e-6 then
					continue -- a key at the loop end duplicates the key at 0
				end
				t = t % raw.length
			end
			-- merge keys at identical times (last wins)
			if n > 0 and math.abs(times[n] - t) < 1e-6 then
				n -= 1
			end
			n += 1
			times[n] = t
			local o = (n - 1) * 6
			vals[o + 1] = rad(k[2] or 0)
			vals[o + 2] = rad(k[3] or 0)
			vals[o + 3] = rad(k[4] or 0)
			vals[o + 4] = k[5] or 0
			vals[o + 5] = k[6] or 0
			vals[o + 6] = k[7] or 0
			if k[5] or k[6] or k[7] then
				hasPos = true
			end
			eases[n] = k[8]
			step[n] = k[8] == "step"
		end
		if loop then
			-- re-sort after wrapping times into [0, length)
			local order = {}
			for i = 1, n do
				order[i] = i
			end
			table.sort(order, function(a, b)
				return times[a] < times[b]
			end)
			local t2, v2, e2, s2 = {}, {}, {}, {}
			for i, src in order do
				t2[i] = times[src]
				for c = 1, 6 do
					v2[(i - 1) * 6 + c] = vals[(src - 1) * 6 + c]
				end
				e2[i] = eases[src]
				s2[i] = step[src]
			end
			times, vals, eases, step = t2, v2, e2, s2
		end
		local tin, tout = {}, {}
		computeTangents(times, vals, eases, loop, raw.length, n, tin, tout)
		if loop then
			-- wrap key
			times[n + 1] = times[1] + raw.length
			for c = 1, 6 do
				vals[n * 6 + c] = vals[c]
				tin[n * 6 + c] = tin[c]
				tout[n * 6 + c] = tout[c]
			end
			step[n + 1] = step[1]
		end
		local track: Track = { joint = index, times = times, vals = vals, tin = tin, tout = tout, step = step, hasPos = hasPos, n = n }
		table.insert(tracks, track)
		byJoint[index] = track
	end
	table.sort(tracks, function(a, b)
		return a.joint < b.joint
	end)

	local hands: { [string]: { HandKey } } = {}
	if raw.hands then
		for side, keys in raw.hands do
			local list: { HandKey } = {}
			for _, k in keys do
				table.insert(list, { t = k[1], preset = k[2], blend = k[3] or 0.1 })
			end
			table.sort(list, function(a, b)
				return a.t < b.t
			end)
			hands[side] = list
		end
	end
	local events = {}
	if raw.events then
		for _, e in raw.events do
			table.insert(events, { t = e[1], name = e[2], data = e[3] })
		end
		table.sort(events, function(a, b)
			return a.t < b.t
		end)
	end
	return {
		name = raw.name,
		length = raw.length,
		loop = loop,
		tracks = tracks,
		trackByJoint = byJoint,
		hands = hands :: any,
		events = events,
		speed = raw.speed,
		meta = raw.meta or {},
	}
end

-- Evaluates a track at time t into 6 channel values.
local function evalTrack(tr: Track, t: number, loop: boolean, length: number): (number, number, number, number, number, number)
	local times = tr.times
	local n = tr.n
	local vals = tr.vals
	if n == 1 then
		return vals[1], vals[2], vals[3], vals[4], vals[5], vals[6]
	end
	local last = if loop then n + 1 else n
	if loop then
		t = t % length
		if t < times[1] then
			t += length
		end
	else
		if t <= times[1] then
			return vals[1], vals[2], vals[3], vals[4], vals[5], vals[6]
		elseif t >= times[n] then
			local o = (n - 1) * 6
			return vals[o + 1], vals[o + 2], vals[o + 3], vals[o + 4], vals[o + 5], vals[o + 6]
		end
	end
	-- find segment
	local i = 1
	while i < last - 1 and times[i + 1] <= t do
		i += 1
	end
	local t0, t1 = times[i], times[i + 1]
	local h = t1 - t0
	local o0, o1 = (i - 1) * 6, i * 6
	if tr.step[i] then
		return vals[o0 + 1], vals[o0 + 2], vals[o0 + 3], vals[o0 + 4], vals[o0 + 5], vals[o0 + 6]
	end
	local s = if h > 0 then (t - t0) / h else 0
	local s2, s3 = s * s, s * s * s
	local h00 = 2 * s3 - 3 * s2 + 1
	local h10 = (s3 - 2 * s2 + s) * h
	local h01 = -2 * s3 + 3 * s2
	local h11 = (s3 - s2) * h
	local tout, tin = tr.tout, tr.tin
	return h00 * vals[o0 + 1] + h10 * tout[o0 + 1] + h01 * vals[o1 + 1] + h11 * tin[o1 + 1],
		h00 * vals[o0 + 2] + h10 * tout[o0 + 2] + h01 * vals[o1 + 2] + h11 * tin[o1 + 2],
		h00 * vals[o0 + 3] + h10 * tout[o0 + 3] + h01 * vals[o1 + 3] + h11 * tin[o1 + 3],
		h00 * vals[o0 + 4] + h10 * tout[o0 + 4] + h01 * vals[o1 + 4] + h11 * tin[o1 + 4],
		h00 * vals[o0 + 5] + h10 * tout[o0 + 5] + h01 * vals[o1 + 5] + h11 * tin[o1 + 5],
		h00 * vals[o0 + 6] + h10 * tout[o0 + 6] + h01 * vals[o1 + 6] + h11 * tin[o1 + 6]
end
Clip.evalTrack = evalTrack

--[[ Samples the clip at time t into `out`. Joints without a track are set to identity when
	 `fill` is true (full-body clips) or left untouched otherwise. `posScale` scales translations
	 (so authored root offsets fit differently sized rigs). ]]
function Clip.sample(clip: Clip, t: number, out: { number }, count: number, fill: boolean?, posScale: number?)
	local ps = posScale or 1
	if fill then
		for j = 0, count - 1 do
			local o = j * 7
			out[o + 1], out[o + 2], out[o + 3], out[o + 4], out[o + 5], out[o + 6], out[o + 7] = 0, 0, 0, 1, 0, 0, 0
		end
	end
	for _, tr in clip.tracks do
		if tr.joint <= count then
			local rx, ry, rz, px, py, pz = evalTrack(tr, t, clip.loop, clip.length)
			local qx, qy, qz, qw = Quat.fromEulerXYZ(rx, ry, rz)
			local o = (tr.joint - 1) * 7
			out[o + 1], out[o + 2], out[o + 3], out[o + 4] = qx, qy, qz, qw
			if tr.hasPos then
				out[o + 5], out[o + 6], out[o + 7] = px * ps, py * ps, pz * ps
			else
				out[o + 5], out[o + 6], out[o + 7] = 0, 0, 0
			end
		end
	end
end

-- Hand preset at time t: returns (fromPreset, toPreset, alpha)
function Clip.handAt(clip: Clip, side: string, t: number): (string?, string?, number)
	local keys = (clip.hands :: any)[side] :: { HandKey }?
	if not keys or #keys == 0 then
		return nil, nil, 0
	end
	if clip.loop then
		t = t % clip.length
	end
	local cur = 0
	for i, k in keys do
		if k.t <= t then
			cur = i
		end
	end
	if cur == 0 then
		return keys[1].preset, keys[1].preset, 1
	end
	local k = keys[cur]
	local prev = if cur > 1 then keys[cur - 1].preset else k.preset
	local alpha = if k.blend > 0 then math.clamp((t - k.t) / k.blend, 0, 1) else 1
	alpha = alpha * alpha * (3 - 2 * alpha)
	return prev, k.preset, alpha
end

-- Events crossed when advancing from t0 to t1 (handles loop wrap).
function Clip.eventsBetween(clip: Clip, t0: number, t1: number, out: { string })
	if #clip.events == 0 or t1 <= t0 then
		return
	end
	local len = clip.length
	if clip.loop then
		local span = t1 - t0
		if span >= len then
			for _, e in clip.events do
				table.insert(out, e.name)
			end
			return
		end
		local a = t0 % len
		local b = a + span
		for _, e in clip.events do
			if (e.t > a and e.t <= b) or (e.t + len > a and e.t + len <= b) then
				table.insert(out, e.name)
			end
		end
	else
		for _, e in clip.events do
			if e.t > t0 and e.t <= t1 then
				table.insert(out, e.name)
			end
		end
	end
end

return Clip
