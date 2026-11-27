--!strict
--[[
	Pose
	----
	A pose is a flat number array: 7 numbers per joint (qx, qy, qz, qw, px, py, pz) in the canonical
	joint order of RigDefinition. Values are Motor6D.Transform rotations/translations.
	All operations are in-place and allocation-free.
]]

local Quat = require(script.Parent.Parent.Math.Quat)

export type Pose = { number }

local Pose = {}
Pose.STRIDE = 7

function Pose.new(count: number): Pose
	local p = table.create(count * 7, 0)
	for j = 0, count - 1 do
		p[j * 7 + 4] = 1
	end
	return p
end

function Pose.identity(p: Pose, count: number)
	for j = 0, count - 1 do
		local o = j * 7
		p[o + 1], p[o + 2], p[o + 3], p[o + 4], p[o + 5], p[o + 6], p[o + 7] = 0, 0, 0, 1, 0, 0, 0
	end
end

function Pose.copy(dst: Pose, src: Pose, count: number)
	for i = 1, count * 7 do
		dst[i] = src[i]
	end
end

function Pose.get(p: Pose, j: number): (number, number, number, number, number, number, number)
	local o = (j - 1) * 7
	return p[o + 1], p[o + 2], p[o + 3], p[o + 4], p[o + 5], p[o + 6], p[o + 7]
end

function Pose.setRot(p: Pose, j: number, x: number, y: number, z: number, w: number)
	local o = (j - 1) * 7
	p[o + 1], p[o + 2], p[o + 3], p[o + 4] = x, y, z, w
end

function Pose.setPos(p: Pose, j: number, x: number, y: number, z: number)
	local o = (j - 1) * 7
	p[o + 5], p[o + 6], p[o + 7] = x, y, z
end

-- dst = lerp(dst, src, w) per joint (rotation nlerp, translation lerp). mask: optional {weight per joint}
function Pose.blendInto(dst: Pose, src: Pose, w: number, count: number, mask: { number }?)
	if w <= 0 then
		return
	end
	for j = 0, count - 1 do
		local wj = w
		if mask then
			wj = w * (mask[j + 1] or 0)
		end
		if wj > 0 then
			local o = j * 7
			if wj >= 1 then
				for k = 1, 7 do
					dst[o + k] = src[o + k]
				end
			else
				local x, y, z, ww = Quat.nlerp(dst[o + 1], dst[o + 2], dst[o + 3], dst[o + 4], src[o + 1], src[o + 2], src[o + 3], src[o + 4], wj)
				dst[o + 1], dst[o + 2], dst[o + 3], dst[o + 4] = x, y, z, ww
				dst[o + 5] += (src[o + 5] - dst[o + 5]) * wj
				dst[o + 6] += (src[o + 6] - dst[o + 6]) * wj
				dst[o + 7] += (src[o + 7] - dst[o + 7]) * wj
			end
		end
	end
end

-- dst = dst * add^w (additive layer: add is a delta relative to identity)
function Pose.addInto(dst: Pose, add: Pose, w: number, count: number, mask: { number }?)
	if w <= 0 then
		return
	end
	for j = 0, count - 1 do
		local wj = w
		if mask then
			wj = w * (mask[j + 1] or 0)
		end
		if wj > 0 then
			local o = j * 7
			local ax, ay, az, aw = add[o + 1], add[o + 2], add[o + 3], add[o + 4]
			if wj < 1 then
				ax, ay, az, aw = Quat.slerp(0, 0, 0, 1, ax, ay, az, aw, wj)
			end
			local x, y, z, ww = Quat.mul(dst[o + 1], dst[o + 2], dst[o + 3], dst[o + 4], ax, ay, az, aw)
			dst[o + 1], dst[o + 2], dst[o + 3], dst[o + 4] = x, y, z, ww
			dst[o + 5] += add[o + 5] * wj
			dst[o + 6] += add[o + 6] * wj
			dst[o + 7] += add[o + 7] * wj
		end
	end
end

-- Pre-multiply a joint rotation by (x, y, z, w): rotation applied in the joint's parent frame.
function Pose.preRotate(p: Pose, j: number, x: number, y: number, z: number, w: number)
	local o = (j - 1) * 7
	local nx, ny, nz, nw = Quat.mul(x, y, z, w, p[o + 1], p[o + 2], p[o + 3], p[o + 4])
	p[o + 1], p[o + 2], p[o + 3], p[o + 4] = nx, ny, nz, nw
end

-- Post-multiply (rotation applied in the joint's own rotated frame).
function Pose.postRotate(p: Pose, j: number, x: number, y: number, z: number, w: number)
	local o = (j - 1) * 7
	local nx, ny, nz, nw = Quat.mul(p[o + 1], p[o + 2], p[o + 3], p[o + 4], x, y, z, w)
	p[o + 1], p[o + 2], p[o + 3], p[o + 4] = nx, ny, nz, nw
end

function Pose.rotateEuler(p: Pose, j: number, rx: number, ry: number, rz: number)
	local x, y, z, w = Quat.fromEulerXYZ(rx, ry, rz)
	Pose.postRotate(p, j, x, y, z, w)
end

function Pose.transform(p: Pose, j: number): CFrame
	local o = (j - 1) * 7
	return CFrame.new(p[o + 5], p[o + 6], p[o + 7], p[o + 1], p[o + 2], p[o + 3], p[o + 4])
end

function Pose.setTransform(p: Pose, j: number, cf: CFrame)
	local x, y, z, w = Quat.fromCFrame(cf)
	local o = (j - 1) * 7
	p[o + 1], p[o + 2], p[o + 3], p[o + 4] = x, y, z, w
	local pos = cf.Position
	p[o + 5], p[o + 6], p[o + 7] = pos.X, pos.Y, pos.Z
end

-- Mirror a pose left<->right using the skeleton's mirror table.
function Pose.mirror(dst: Pose, src: Pose, mirrorOf: { number }, count: number)
	for j = 0, count - 1 do
		local m = (mirrorOf[j + 1] or (j + 1)) - 1
		local so, dO = m * 7, j * 7
		-- reflection across the YZ plane: (x, y, z, w) -> (x, -y, -z, w); pos x -> -x
		dst[dO + 1] = src[so + 1]
		dst[dO + 2] = -src[so + 2]
		dst[dO + 3] = -src[so + 3]
		dst[dO + 4] = src[so + 4]
		dst[dO + 5] = -src[so + 5]
		dst[dO + 6] = src[so + 6]
		dst[dO + 7] = src[so + 7]
	end
end

return Pose
