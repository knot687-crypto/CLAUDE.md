--!strict
--[[
	Shapes
	------
	Geometry helpers used by the model builder:
	  * ellipsoid shells (one per sculpted body volume) with analytic ray casting
	  * decal-style projection of 2D designs onto the outermost surface of a shell
	  * polar "web" pattern generation (radials + scalloped rings) on any shell
	  * Douglas-Peucker polyline simplification so web lines use as few parts as possible
]]

export type Ellipsoid = {
	center: Vector3,
	radii: Vector3,
	rot: CFrame, -- rotation only
	color: string,
	tag: string?,
}

export type Hit = {
	position: Vector3,
	normal: Vector3,
	shape: Ellipsoid,
}

local Shapes = {}

function Shapes.ellipsoid(center: Vector3, radii: Vector3, color: string, rot: CFrame?, tag: string?): Ellipsoid
	return { center = center, radii = radii, rot = rot or CFrame.identity, color = color, tag = tag }
end

-- Ray vs single ellipsoid. Returns (t, normal) for the first intersection with t >= 0.
function Shapes.rayEllipsoid(origin: Vector3, dir: Vector3, e: Ellipsoid): (number?, Vector3?)
	local lo = e.rot:VectorToObjectSpace(origin - e.center)
	local ld = e.rot:VectorToObjectSpace(dir)
	local r = e.radii
	local o = Vector3.new(lo.X / r.X, lo.Y / r.Y, lo.Z / r.Z)
	local d = Vector3.new(ld.X / r.X, ld.Y / r.Y, ld.Z / r.Z)
	local a = d:Dot(d)
	local b = 2 * o:Dot(d)
	local c = o:Dot(o) - 1
	local disc = b * b - 4 * a * c
	if disc < 0 or a == 0 then
		return nil, nil
	end
	local sq = math.sqrt(disc)
	local t = (-b - sq) / (2 * a)
	if t < 0 then
		t = (-b + sq) / (2 * a)
		if t < 0 then
			return nil, nil
		end
	end
	local p = o + d * t
	local nLocal = Vector3.new(p.X / r.X, p.Y / r.Y, p.Z / r.Z)
	local n = e.rot:VectorToWorldSpace(nLocal).Unit
	return t, n
end

-- First hit against the union of shapes, casting from `origin` along `dir`.
function Shapes.cast(shell: { Ellipsoid }, origin: Vector3, dir: Vector3): Hit?
	local bestT = math.huge
	local best: Hit? = nil
	for _, e in shell do
		local t, n = Shapes.rayEllipsoid(origin, dir, e)
		if t and n and t < bestT then
			bestT = t
			best = { position = origin + dir * t, normal = n, shape = e }
		end
	end
	return best
end

-- Cast from outside the shell toward `center` along direction -dirOut (finds the visible surface).
function Shapes.castInward(shell: { Ellipsoid }, center: Vector3, dirOut: Vector3, reach: number?): Hit?
	local d = dirOut.Unit
	return Shapes.cast(shell, center + d * (reach or 4), -d)
end

-- Is point p inside any ellipsoid of the shell (with a small margin)?
function Shapes.inside(shell: { Ellipsoid }, p: Vector3, margin: number?): boolean
	local m = margin or 0
	for _, e in shell do
		local l = e.rot:VectorToObjectSpace(p - e.center)
		local r = e.radii
		local rx, ry, rz = r.X + m, r.Y + m, r.Z + m
		if (l.X / rx) ^ 2 + (l.Y / ry) ^ 2 + (l.Z / rz) ^ 2 < 1 then
			return true
		end
	end
	return false
end

-- Orthonormal tangent basis around a normal, using `upHint` for orientation.
function Shapes.tangentBasis(n: Vector3, upHint: Vector3): (Vector3, Vector3)
	local v = upHint - n * upHint:Dot(n)
	if v.Magnitude < 1e-6 then
		v = Vector3.new(0, 0, 1) - n * n.Z
	end
	v = v.Unit
	local u = v:Cross(n).Unit -- right-handed: u x v = n
	return u, v
end

--[[ Decal projection: maps a 2D point (x, y) in a tangent plane centered at `anchor` (with axes u, v
	 and normal n) onto the shell by casting along -n. ]]
function Shapes.projectPlanar(shell: { Ellipsoid }, anchor: Vector3, u: Vector3, v: Vector3, n: Vector3, x: number, y: number): Hit?
	local p = anchor + u * x + v * y
	return Shapes.cast(shell, p + n * 2, -n)
end

-- Perpendicular distance from p to segment ab
local function distToSegment(p: Vector3, a: Vector3, b: Vector3): number
	local ab = b - a
	local len2 = ab:Dot(ab)
	if len2 < 1e-12 then
		return (p - a).Magnitude
	end
	local t = math.clamp((p - a):Dot(ab) / len2, 0, 1)
	return (p - (a + ab * t)).Magnitude
end

-- Douglas-Peucker simplification on a list of points (keeps first/last).
function Shapes.simplify(points: { Vector3 }, tolerance: number): { number }
	local n = #points
	local keep = table.create(n, false)
	keep[1] = true
	keep[n] = true
	local stack = { { 1, n } }
	while #stack > 0 do
		local seg = table.remove(stack) :: { number }
		local i0, i1 = seg[1], seg[2]
		local maxD, maxI = 0, -1
		for i = i0 + 1, i1 - 1 do
			local d = distToSegment(points[i], points[i0], points[i1])
			if d > maxD then
				maxD, maxI = d, i
			end
		end
		if maxI > 0 and maxD > tolerance then
			keep[maxI] = true
			table.insert(stack, { i0, maxI })
			table.insert(stack, { maxI, i1 })
		end
	end
	local out = {}
	for i = 1, n do
		if keep[i] then
			table.insert(out, i)
		end
	end
	return out
end

export type WebSpec = {
	shell: { Ellipsoid },
	origin: Vector3, -- interior point rays are cast toward
	pole: Vector3, -- unit direction from origin to the web center
	ref: Vector3, -- direction for phi = 0 (will be orthogonalized)
	radials: number,
	phase: number?, -- angular offset for radials (radians)
	rings: { number }, -- polar angles (radians) of the concentric strands
	thetaMax: number, -- how far the radials run (radians)
	thetaMin: number?, -- radials start here (leave a small hub)
	sag: number?, -- 0..1 inward sag of strands between radials
	colors: { [string]: boolean }, -- only draw where the hit shape has one of these colors
	exclude: ((Vector3) -> boolean)?, -- optional rejection test for a surface point
	step: number?, -- sampling step (radians)
	tolerance: number?, -- simplification tolerance (studs)
	ringFilter: ((number, number) -> boolean)?, -- (ringIndex, phi) -> draw?
}

export type Polyline = { points: { Vector3 }, normals: { Vector3 } }

--[[ Generates the web pattern as a list of polylines lying on the visible surface. Radial lines run
	 from the hub outward along constant phi; strands are straight (in the azimuthal projection)
	 chords between neighbouring radials, sagging slightly toward the hub like real silk. ]]
function Shapes.webPattern(spec: WebSpec): { Polyline }
	local pole = spec.pole.Unit
	local ref = (spec.ref - pole * spec.ref:Dot(pole)).Unit
	local ref2 = pole:Cross(ref).Unit
	local step = spec.step or math.rad(1.5)
	local tol = spec.tolerance or 0.004
	local phase = spec.phase or 0
	local out: { Polyline } = {}

	local function dirAt(theta: number, phi: number): Vector3
		local side = ref * math.cos(phi) + ref2 * math.sin(phi)
		return (pole * math.cos(theta) + side * math.sin(theta)).Unit
	end

	local function sample(theta: number, phi: number): Hit?
		local hit = Shapes.castInward(spec.shell, spec.origin, dirAt(theta, phi))
		if not hit then
			return nil
		end
		if not spec.colors[hit.shape.color] then
			return nil
		end
		if spec.exclude and spec.exclude(hit.position) then
			return nil
		end
		return hit
	end

	-- emit runs of consecutive valid samples as simplified polylines
	local function emitRuns(samples: { Hit | false })
		local run: { Hit } = {}
		local function flush()
			if #run >= 2 then
				local pts = {}
				for i, h in run do
					pts[i] = h.position
				end
				local idx = Shapes.simplify(pts, tol)
				local poly: Polyline = { points = {}, normals = {} }
				for _, i in idx do
					table.insert(poly.points, run[i].position)
					table.insert(poly.normals, run[i].normal)
				end
				table.insert(out, poly)
			end
			run = {}
		end
		for _, s in samples do
			if s then
				table.insert(run, s)
			else
				flush()
			end
		end
		flush()
	end

	local thetaMin = spec.thetaMin or 0
	-- radials
	for k = 0, spec.radials - 1 do
		local phi = phase + k * (2 * math.pi / spec.radials)
		local samples: { Hit | false } = {}
		local theta = thetaMin
		while theta <= spec.thetaMax + 1e-9 do
			table.insert(samples, sample(theta, phi) or false)
			theta += step
		end
		emitRuns(samples)
	end

	-- strands (rings): straight chords in the azimuthal-equidistant projection, with sag
	local dphi = 2 * math.pi / spec.radials
	local sag = spec.sag or 0.06
	for ri, ringTheta in spec.rings do
		for k = 0, spec.radials - 1 do
			local phiA = phase + k * dphi
			local phiMid = phiA + dphi / 2
			local samples: { Hit | false } = {}
			local nSteps = math.max(4, math.ceil((dphi * math.sin(math.min(ringTheta, math.pi / 2))) / step))
			for s = 0, nSteps do
				local phi = phiA + dphi * s / nSteps
				local t = (phi - phiMid) / (dphi / 2) -- -1..1
				local chord = ringTheta * math.cos(dphi / 2) / math.cos(phi - phiMid)
				local theta = chord * (1 - sag * (1 - t * t))
				local ok = (spec.ringFilter == nil) or spec.ringFilter(ri, phi)
				table.insert(samples, if ok then (sample(theta, phi) or false) else false)
			end
			emitRuns(samples)
		end
	end
	return out
end

--[[ Plane section of an ellipsoid. A plane always cuts an ellipsoid in an ellipse; returns its
	 center, unit major/minor axis directions and semi-axes, or nil when the plane misses.
	 Used for "rim lines": a thin disc slightly larger than the section leaves only a fine raised
	 rim on the surface, which follows the curvature exactly and costs a single part. ]]
export type Section = { center: Vector3, major: Vector3, minor: Vector3, a: number, b: number, normal: Vector3 }

function Shapes.planeSection(e: Ellipsoid, point: Vector3, normal: Vector3): Section?
	local m = normal.Unit
	local r = e.radii
	-- plane in unit-sphere space: (S R^T m) . x = m . (point - c)
	local ml = e.rot:VectorToObjectSpace(m)
	local nPrime = Vector3.new(ml.X * r.X, ml.Y * r.Y, ml.Z * r.Z)
	local len = nPrime.Magnitude
	local nHat = nPrime / len
	local d = m:Dot(point - e.center) / len
	if math.abs(d) >= 0.999 then
		return nil
	end
	local rho = math.sqrt(1 - d * d)
	-- orthonormal basis of the plane in unit-sphere space
	local f1 = nHat:Cross(if math.abs(nHat.X) < 0.9 then Vector3.xAxis else Vector3.yAxis).Unit
	local f2 = nHat:Cross(f1).Unit
	local s1 = Vector3.new(f1.X * r.X, f1.Y * r.Y, f1.Z * r.Z)
	local s2 = Vector3.new(f2.X * r.X, f2.Y * r.Y, f2.Z * r.Z)
	-- 2x2 symmetric matrix of the quadratic form; eigen-decompose
	local g11, g12, g22 = s1:Dot(s1), s1:Dot(s2), s2:Dot(s2)
	local tr = g11 + g22
	local det = g11 * g22 - g12 * g12
	local disc = math.sqrt(math.max(0, tr * tr / 4 - det))
	local l1, l2 = tr / 2 + disc, tr / 2 - disc
	local e1x, e1y
	if math.abs(g12) > 1e-12 then
		e1x, e1y = l1 - g22, g12
	elseif g11 >= g22 then
		e1x, e1y = 1, 0
	else
		e1x, e1y = 0, 1
	end
	local en = math.sqrt(e1x * e1x + e1y * e1y)
	e1x, e1y = e1x / en, e1y / en
	local u1 = f1 * e1x + f2 * e1y
	local u2 = f1 * -e1y + f2 * e1x
	local function toWorld(x: Vector3): Vector3
		return e.rot:VectorToWorldSpace(Vector3.new(x.X * r.X, x.Y * r.Y, x.Z * r.Z))
	end
	local center = e.center + toWorld(nHat * d)
	local majorV = toWorld(u1)
	local minorV = toWorld(u2)
	return {
		center = center,
		major = majorV.Unit,
		minor = minorV.Unit,
		a = rho * math.sqrt(l1),
		b = rho * math.sqrt(math.max(l2, 0)),
		normal = m,
	}
end

--[[ Fraction of a section's rim that is actually visible (on the outer surface of the shell and
	 of an allowed color). Lets the builder skip discs whose rim would be entirely buried. ]]
function Shapes.rimVisibility(shell: { Ellipsoid }, owner: Ellipsoid, sec: Section, lift: number, samples: number?, filter: ((Vector3, Vector3) -> boolean)?): number
	local n = samples or 48
	local visible = 0
	for i = 0, n - 1 do
		local t = (i / n) * 2 * math.pi
		local dir = sec.major * (sec.a * math.cos(t)) + sec.minor * (sec.b * math.sin(t))
		local p = sec.center + dir
		local outward = dir.Unit
		local probe = p + outward * lift
		local ok = true
		for _, other in shell do
			if other ~= owner then
				local l = other.rot:VectorToObjectSpace(probe - other.center)
				local rr = other.radii
				if (l.X / rr.X) ^ 2 + (l.Y / rr.Y) ^ 2 + (l.Z / rr.Z) ^ 2 < 1 then
					ok = false
					break
				end
			end
		end
		if ok and filter and not filter(p, outward) then
			ok = false
		end
		if ok then
			visible += 1
		end
	end
	return visible / n
end

--[[ Lines running along a limb (longitudinal) plus rings around it, for gloves and boots.
	 axisFrame: CFrame whose Y axis runs along the limb; lines sample between yMin..yMax (local). ]]
export type LimbWebSpec = {
	shell: { Ellipsoid },
	axisFrame: CFrame,
	yMin: number,
	yMax: number,
	lines: number,
	phase: number?,
	rings: { number }, -- local y of each ring
	colors: { [string]: boolean },
	step: number?,
	tolerance: number?,
	sag: number?,
}

function Shapes.limbPattern(spec: LimbWebSpec): { Polyline }
	local out: { Polyline } = {}
	local step = spec.step or 0.02
	local tol = spec.tolerance or 0.004
	local phase = spec.phase or 0
	local frame = spec.axisFrame

	local function sample(y: number, phi: number): Hit?
		local center = frame:PointToWorldSpace(Vector3.new(0, y, 0))
		local dir = frame:VectorToWorldSpace(Vector3.new(math.cos(phi), 0, math.sin(phi)))
		local hit = Shapes.castInward(spec.shell, center, dir, 2)
		if hit and spec.colors[hit.shape.color] then
			return hit
		end
		return nil
	end

	local function emit(samples: { Hit | false })
		local run: { Hit } = {}
		local function flush()
			if #run >= 2 then
				local pts = {}
				for i, h in run do
					pts[i] = h.position
				end
				local idx = Shapes.simplify(pts, tol)
				local poly: Polyline = { points = {}, normals = {} }
				for _, i in idx do
					table.insert(poly.points, run[i].position)
					table.insert(poly.normals, run[i].normal)
				end
				table.insert(out, poly)
			end
			run = {}
		end
		for _, s in samples do
			if s then
				table.insert(run, s)
			else
				flush()
			end
		end
		flush()
	end

	for k = 0, spec.lines - 1 do
		local phi = phase + k * 2 * math.pi / spec.lines
		local samples: { Hit | false } = {}
		local y = spec.yMin
		while y <= spec.yMax + 1e-9 do
			table.insert(samples, sample(y, phi) or false)
			y += step
		end
		emit(samples)
	end

	local dphi = 2 * math.pi / spec.lines
	local sag = spec.sag or 0.0
	for _, ry in spec.rings do
		for k = 0, spec.lines - 1 do
			local phiA = phase + k * dphi
			local samples: { Hit | false } = {}
			local n = 8
			for s = 0, n do
				local t = s / n
				local yy = ry - sag * math.sin(t * math.pi)
				table.insert(samples, sample(yy, phiA + dphi * t) or false)
			end
			emit(samples)
		end
	end
	return out
end

return Shapes
