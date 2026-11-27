--!strict
--[[
	Builder
	-------
	Procedurally builds the spider-hero character: an R15-compatible rig (15 body parts + 20 finger
	segments, standard Motor6D names and rig attachments) dressed in a sculpted suit.

	Construction notes
	  * Every body volume is an ellipsoid (Part + SpecialMesh Sphere) welded to its body segment.
	  * Volumes that straddle a joint are centered on the joint pivot (deltoids, elbows, knees, hips,
	    wrists, ankles, waist), so they stay seamless when the joint rotates.
	  * Suit color regions come from overlapping volumes (red chest panel over blue ribcage, etc.);
	    the seam is the natural intersection curve.
	  * The raised web pattern, emblems and lenses are projected onto the outermost surface of each
	    segment with analytic ray casts (see Shapes), so they hug the sculpt like a printed decal.

	Usage (Studio command bar, a plugin, or a server script):
		local Builder = require(ReplicatedStorage.SpiderKit.Rig.Builder)
		local hero = Builder.build({ palette = "Classic", detail = "High" })
		hero.Parent = workspace
]]

local RigDefinition = require(script.Parent.RigDefinition)
local Shapes = require(script.Parent.Shapes)
local Palette = require(script.Parent.Palette)

type Ellipsoid = Shapes.Ellipsoid

export type BuildOptions = {
	palette: string?,
	name: string?,
	detail: string?, -- "High" | "Medium" | "Low"
}

local Builder = {}

local DEG = math.pi / 180

local function rotDeg(x: number?, y: number?, z: number?): CFrame
	return CFrame.Angles((x or 0) * DEG, (y or 0) * DEG, (z or 0) * DEG)
end

type Ctx = {
	model: Model,
	palette: Palette.Palette,
	segParts: { [string]: BasePart },
	shells: { [string]: { Ellipsoid } },
	folder: Folder,
	partCount: number,
	detail: number, -- 2 = high, 1 = medium, 0 = low
}

local MATERIAL_FOR: { [string]: Enum.Material } = {
	Shooter = Enum.Material.Metal,
	ShooterDark = Enum.Material.Metal,
}

local function colorOf(ctx: Ctx, key: string): Color3
	local c = (ctx.palette :: any)[key]
	assert(c, "palette is missing color '" .. key .. "'")
	return c
end

local function newDetailPart(ctx: Ctx, segName: string, name: string, cf: CFrame, size: Vector3, colorKey: string, castShadow: boolean): Part
	local seg = ctx.segParts[segName]
	assert(seg, "unknown segment " .. segName)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = colorOf(ctx, colorKey)
	p.Material = MATERIAL_FOR[colorKey] or Enum.Material.SmoothPlastic
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.Massless = true
	p.CastShadow = castShadow
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if colorKey == "Lens" then
		p.Reflectance = ctx.palette.LensReflectance or 0.2
	elseif colorKey == "Shooter" then
		p.Reflectance = 0.15
	end
	local weld = Instance.new("Weld")
	weld.Name = "SuitWeld"
	weld.Part0 = seg
	weld.Part1 = p
	weld.C0 = seg.CFrame:Inverse() * cf
	weld.C1 = CFrame.identity
	weld.Parent = p
	p.Parent = ctx.folder
	ctx.partCount += 1
	return p
end

-- Adds a sculpted ellipsoid volume. `shell` = include in the segment's projection surface.
local function vol(ctx: Ctx, segName: string, name: string, center: Vector3, radii: Vector3, colorKey: string, rot: CFrame?, shell: boolean?)
	local r = rot or CFrame.identity
	local p = newDetailPart(ctx, segName, name, CFrame.new(center) * r, radii * 2, colorKey, true)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = p
	if shell ~= false then
		local list = ctx.shells[segName]
		if not list then
			list = {}
			ctx.shells[segName] = list
		end
		table.insert(list, Shapes.ellipsoid(center, radii, colorKey, r, name))
	end
	return p
end

-- Cylinder between two points (Roblox cylinders run along their X axis).
local function cyl(ctx: Ctx, segName: string, name: string, a: Vector3, b: Vector3, radius: number, colorKey: string, upHint: Vector3?, castShadow: boolean?): Part
	local axis = b - a
	local len = axis.Magnitude
	local x = axis.Unit
	local hint = upHint or Vector3.yAxis
	if math.abs(x:Dot(hint)) > 0.95 then
		hint = Vector3.zAxis
	end
	local y = (hint - x * hint:Dot(x)).Unit
	local cf = CFrame.fromMatrix((a + b) / 2, x, y)
	local p = newDetailPart(ctx, segName, name, cf, Vector3.new(len, radius * 2, radius * 2), colorKey, castShadow == true)
	p.Shape = Enum.PartType.Cylinder
	return p
end

--[[ Raised line along a polyline that lies on a segment surface. Each straight piece is a thin
	 cylinder lifted by the chord sagitta so its middle doesn't sink into the curved surface. ]]
local function line(ctx: Ctx, segName: string, poly: Shapes.Polyline, radius: number, colorKey: string)
	local shell = ctx.shells[segName]
	for i = 1, #poly.points - 1 do
		local a, b = poly.points[i], poly.points[i + 1]
		local na, nb = poly.normals[i], poly.normals[i + 1]
		local n = (na + nb).Unit
		local mid = (a + b) / 2
		local hit = Shapes.cast(shell, mid + n * 0.5, -n)
		local sag = 0
		if hit then
			sag = math.max(0, (hit.position - mid):Dot(n))
		end
		local lift = n * (sag * 0.65 + radius * 0.3)
		local dir = (b - a)
		local len = dir.Magnitude
		if len > 1e-4 then
			local ext = dir.Unit * (radius * 0.9)
			cyl(ctx, segName, "Web", a - ext + lift, b + ext + lift, radius, colorKey, n, false)
		end
	end
end

--[[ Places a flattened ellipsoid "patch" on the surface at point p with normal n.
	 a, b: semi-axes in the tangent plane; majorDir: world direction of the major axis (projected
	 onto the tangent plane). bulge: how far the patch rises above the surface at its center. ]]
local function patch(ctx: Ctx, segName: string, name: string, p: Vector3, n: Vector3, a: number, b: number, majorDir: Vector3, bulge: number, colorKey: string)
	local shell = ctx.shells[segName]
	local major = majorDir - n * majorDir:Dot(n)
	if major.Magnitude < 1e-6 then
		major = Shapes.tangentBasis(n, Vector3.yAxis)
	end
	major = major.Unit
	local minor = n:Cross(major).Unit
	-- measure how far the surface drops away at the patch extremes
	local drop = 0
	for _, off in { major * a, -major * a, minor * b, -minor * b, (major * a + minor * b) * 0.7071, (major * a - minor * b) * 0.7071, (-major * a + minor * b) * 0.7071, (-major * a - minor * b) * 0.7071 } do
		local probe = p + off
		local hit = Shapes.cast(shell, probe + n * 0.5, -n)
		if hit then
			drop = math.max(drop, (probe - hit.position):Dot(n))
		end
	end
	local sink = drop + 0.004
	local thick = sink + bulge
	local center = p - n * sink
	-- frame: X = major, Y = normal, Z = minor (right-handed: X x Y = Z)
	local zAxis = major:Cross(n).Unit
	local cf = CFrame.fromMatrix(center, major, n, zAxis)
	local part = newDetailPart(ctx, segName, name, cf, Vector3.new(a * 2, thick * 2, b * 2), colorKey, false)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = part
	return part
end

-- Projects a 2D design point (x, y) from a tangent plane onto the segment surface.
local function project(ctx: Ctx, segName: string, anchor: Vector3, u: Vector3, v: Vector3, n: Vector3, x: number, y: number): Shapes.Hit
	local hit = Shapes.projectPlanar(ctx.shells[segName], anchor, u, v, n, x, y)
	assert(hit, "projection missed the " .. segName .. " surface")
	return hit
end

--------------------------------------------------------------------------------------------------
-- Sculpt
--------------------------------------------------------------------------------------------------

local function v3(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

local function sculptTorso(ctx: Ctx)
	local U, L = "UpperTorso", "LowerTorso"
	-- Base body (accent color): ribcage, lats flaring into a V-taper, obliques down to the pelvis.
	vol(ctx, U, "Ribcage", v3(0, 4.02, 0.03), v3(0.5, 0.6, 0.31), "Accent")
	vol(ctx, U, "LatR", v3(0.3, 4.06, 0.08), v3(0.25, 0.44, 0.235), "Accent", rotDeg(0, 0, -15))
	vol(ctx, U, "LatL", v3(-0.3, 4.06, 0.08), v3(0.25, 0.44, 0.235), "Accent", rotDeg(0, 0, 15))
	vol(ctx, U, "ObliqueR", v3(0.27, 3.62, 0.01), v3(0.19, 0.31, 0.24), "Accent", rotDeg(0, 0, -5))
	vol(ctx, U, "ObliqueL", v3(-0.27, 3.62, 0.01), v3(0.19, 0.31, 0.24), "Accent", rotDeg(0, 0, 5))
	-- Suit panels: each clearly proud of the base so the seams are crisp
	vol(ctx, U, "FrontPanel", v3(0, 4.1, -0.075), v3(0.4, 0.6, 0.315), "Suit")
	vol(ctx, U, "PecR", v3(0.2, 4.2, -0.215), v3(0.24, 0.16, 0.16), "Suit", rotDeg(0, -10, 12))
	vol(ctx, U, "PecL", v3(-0.2, 4.2, -0.215), v3(0.24, 0.16, 0.16), "Suit", rotDeg(0, 10, -12))
	vol(ctx, U, "Abdomen", v3(0, 3.7, -0.06), v3(0.29, 0.37, 0.26), "Suit")
	vol(ctx, U, "BackPanel", v3(0, 4.2, 0.1), v3(0.37, 0.47, 0.3), "Suit")
	vol(ctx, U, "ScapulaR", v3(0.2, 4.26, 0.19), v3(0.19, 0.21, 0.14), "Suit", rotDeg(0, 14, 10))
	vol(ctx, U, "ScapulaL", v3(-0.2, 4.26, 0.19), v3(0.19, 0.21, 0.14), "Suit", rotDeg(0, -14, -10))
	vol(ctx, U, "GirdleR", v3(0.38, 4.43, 0.02), v3(0.3, 0.165, 0.235), "Suit", rotDeg(0, 0, -10))
	vol(ctx, U, "GirdleL", v3(-0.38, 4.43, 0.02), v3(0.3, 0.165, 0.235), "Suit", rotDeg(0, 0, 10))
	vol(ctx, U, "Traps", v3(0, 4.52, 0.09), v3(0.3, 0.17, 0.2), "Suit")
	vol(ctx, U, "NeckBase", v3(0, 4.64, 0.03), v3(0.2, 0.12, 0.19), "Suit")

	-- Lower torso: pelvis, waist filler centered on the waist pivot, flush belt band, glutes
	vol(ctx, L, "Pelvis", v3(0, 3.06, 0.02), v3(0.42, 0.29, 0.27), "Accent")
	vol(ctx, L, "WaistCore", v3(0, 3.36, 0.015), v3(0.36, 0.2, 0.235), "Accent")
	vol(ctx, L, "Belt", v3(0, 3.28, 0.02), v3(0.37, 0.07, 0.262), "Suit")
	vol(ctx, L, "GluteR", v3(0.14, 2.96, 0.115), v3(0.215, 0.2, 0.165), "Accent", rotDeg(0, 0, -6))
	vol(ctx, L, "GluteL", v3(-0.14, 2.96, 0.115), v3(0.215, 0.2, 0.165), "Accent", rotDeg(0, 0, 6))
	vol(ctx, L, "Groin", v3(0, 2.83, -0.02), v3(0.14, 0.12, 0.17), "Accent")
end

local function sculptHead(ctx: Ctx)
	local H = "Head"
	vol(ctx, H, "Cranium", v3(0, 5.24, 0.015), v3(0.29, 0.33, 0.34), "Suit")
	vol(ctx, H, "Face", v3(0, 5.13, -0.06), v3(0.265, 0.34, 0.285), "Suit")
	vol(ctx, H, "Jaw", v3(0, 4.96, -0.1), v3(0.185, 0.14, 0.18), "Suit")
	vol(ctx, H, "Neck", v3(0, 4.8, 0.02), v3(0.175, 0.2, 0.17), "Suit")
	vol(ctx, H, "NeckBack", v3(0, 4.78, 0.08), v3(0.16, 0.17, 0.14), "Suit")
end

local function sculptArm(ctx: Ctx, side: string, sx: number)
	local function p(x: number, y: number, z: number): Vector3
		return Vector3.new(x * sx, y, z)
	end
	local function r(x: number?, y: number?, z: number?): CFrame
		return rotDeg(x, (y or 0) * sx, (z or 0) * sx)
	end
	local UA, LA, HA = side .. "UpperArm", side .. "LowerArm", side .. "Hand"
	-- deltoid wraps the shoulder joint (centered near the pivot so it stays seamless when raised)
	vol(ctx, UA, "Deltoid", p(0.655, 4.34, 0.02), v3(0.185, 0.25, 0.205), "Suit", r(0, 0, 14))
	vol(ctx, UA, "UpperArm", p(0.625, 3.98, 0.035), v3(0.158, 0.46, 0.163), "Accent")
	vol(ctx, UA, "Biceps", p(0.615, 3.99, -0.045), v3(0.13, 0.27, 0.125), "Accent")
	vol(ctx, UA, "Triceps", p(0.64, 4.06, 0.1), v3(0.13, 0.3, 0.12), "Accent")

	vol(ctx, LA, "Elbow", p(0.62, 3.5, 0.04), v3(0.118, 0.125, 0.12), "Accent")
	vol(ctx, LA, "Forearm", p(0.62, 3.13, 0.03), v3(0.135, 0.41, 0.13), "Accent")
	vol(ctx, LA, "Brachioradialis", p(0.615, 3.32, -0.02), v3(0.122, 0.22, 0.117), "Accent")
	vol(ctx, LA, "Glove", p(0.62, 2.9, 0.025), v3(0.12, 0.245, 0.113), "Suit")

	-- web shooter: slim dark band with metal rims and a nozzle on the palm side
	local bandY = 2.745
	cyl(ctx, LA, "ShooterBand", p(0.62, bandY - 0.022, 0.024), p(0.62, bandY + 0.022, 0.024), 0.104, "ShooterDark", nil, true)
	cyl(ctx, LA, "ShooterRim", p(0.62, bandY - 0.027, 0.024), p(0.62, bandY - 0.019, 0.024), 0.107, "Shooter", nil, false)
	cyl(ctx, LA, "ShooterRim", p(0.62, bandY + 0.019, 0.024), p(0.62, bandY + 0.027, 0.024), 0.107, "Shooter", nil, false)
	cyl(ctx, LA, "ShooterBody", p(0.62 - 0.08, bandY, 0.022), p(0.62 - 0.128, bandY, 0.022), 0.028, "Shooter", nil, false)
	cyl(ctx, LA, "ShooterNozzle", p(0.62 - 0.128, bandY, 0.022), p(0.62 - 0.142, bandY, 0.022), 0.015, "ShooterDark", nil, false)

	vol(ctx, HA, "Wrist", p(0.62, 2.665, 0.02), v3(0.072, 0.07, 0.085), "Suit")
	vol(ctx, HA, "Palm", p(0.62, 2.505, 0.02), v3(0.058, 0.155, 0.115), "Suit")
	vol(ctx, HA, "HandBack", p(0.632, 2.52, 0.015), v3(0.05, 0.14, 0.108), "Suit")
	vol(ctx, HA, "Knuckles", p(0.625, 2.375, 0.0), v3(0.056, 0.042, 0.12), "Suit")
	vol(ctx, HA, "Thenar", p(0.6, 2.555, -0.075), v3(0.045, 0.085, 0.05), "Suit")
end

local function sculptLeg(ctx: Ctx, side: string, sx: number)
	local function p(x: number, y: number, z: number): Vector3
		return Vector3.new(x * sx, y, z)
	end
	local function r(x: number?, y: number?, z: number?): CFrame
		return rotDeg(x, (y or 0) * sx, (z or 0) * sx)
	end
	local UL, LL, FT = side .. "UpperLeg", side .. "LowerLeg", side .. "Foot"
	vol(ctx, UL, "HipBall", p(0.245, 2.87, 0.0), v3(0.205, 0.21, 0.205), "Accent")
	vol(ctx, UL, "Thigh", p(0.25, 2.22, 0.0), v3(0.215, 0.68, 0.23), "Accent", r(0, 0, 3))
	vol(ctx, UL, "Quads", p(0.262, 2.2, -0.07), v3(0.185, 0.52, 0.17), "Accent", r(0, 0, 3))
	vol(ctx, UL, "VastusMedialis", p(0.2, 1.82, -0.06), v3(0.115, 0.2, 0.125), "Accent")
	vol(ctx, UL, "Hamstring", p(0.25, 2.3, 0.08), v3(0.175, 0.52, 0.165), "Accent")
	vol(ctx, UL, "Adductor", p(0.165, 2.56, 0.0), v3(0.12, 0.3, 0.17), "Accent")
	vol(ctx, UL, "LowerThigh", p(0.25, 1.72, -0.01), v3(0.155, 0.22, 0.16), "Accent")

	vol(ctx, LL, "Knee", p(0.25, 1.54, -0.025), v3(0.135, 0.15, 0.135), "Accent")
	vol(ctx, LL, "Shin", p(0.25, 0.97, 0.02), v3(0.148, 0.62, 0.15), "Accent")
	vol(ctx, LL, "Calf", p(0.26, 1.17, 0.075), v3(0.145, 0.36, 0.145), "Accent")
	vol(ctx, LL, "Boot", p(0.25, 0.68, 0.02), v3(0.158, 0.47, 0.163), "Suit")

	vol(ctx, FT, "Ankle", p(0.25, 0.27, 0.04), v3(0.1, 0.1, 0.11), "Suit")
	vol(ctx, FT, "FootMain", p(0.25, 0.125, -0.15), v3(0.13, 0.125, 0.4), "Suit")
	vol(ctx, FT, "Heel", p(0.25, 0.115, 0.14), v3(0.11, 0.115, 0.12), "Suit")
	vol(ctx, FT, "Toe", p(0.25, 0.08, -0.44), v3(0.118, 0.08, 0.155), "Suit")
	vol(ctx, FT, "Sole", p(0.25, 0.035, -0.16), v3(0.124, 0.035, 0.405), "Sole")
end

--------------------------------------------------------------------------------------------------
-- Details: lenses, emblems, abs, web pattern
--------------------------------------------------------------------------------------------------

local function lenses(ctx: Ctx)
	local H = "Head"
	local anchor = v3(0, 5.18, -0.2)
	local n0 = v3(0, 0, -1)
	local u0, v0 = Vector3.xAxis, Vector3.yAxis
	-- {x, y, a, b, tiltDeg, bulge, color}: a main almond plus a swept outer corner, frame then lens
	local design = {
		{ 0.122, 0.0, 0.112, 0.072, 20, 0.014, "LensFrame" },
		{ 0.19, 0.034, 0.06, 0.044, 31, 0.014, "LensFrame" },
		{ 0.126, 0.004, 0.092, 0.053, 20, 0.021, "Lens" },
		{ 0.184, 0.032, 0.046, 0.03, 31, 0.021, "Lens" },
	}
	for _, sx in { 1, -1 } do
		for _, d in design do
			local hit = project(ctx, H, anchor, u0, v0, n0, d[1] * sx, d[2])
			-- outer corner of each lens tilts upward (mirror the tilt for the left eye)
			local tilt = d[5] * DEG
			local majorDir = Vector3.new(math.cos(tilt) * sx, math.sin(tilt), 0)
			patch(ctx, H, if d[7] == "Lens" then "Lens" else "LensFrame", hit.position, hit.normal, d[3], d[4], majorDir, d[6], d[7])
		end
	end
end

-- Original spider emblem design (studs, x right / y up in the emblem plane)
local EMBLEM_BODY = {
	-- x, y, half-width, half-height
	{ 0, 0.078, 0.022, 0.026 },
	{ 0, 0.036, 0.04, 0.05 },
	{ 0, -0.058, 0.05, 0.085 },
	{ 0, -0.135, 0.026, 0.042 },
}
local EMBLEM_LEGS = {
	{ { 0.03, 0.058 }, { 0.088, 0.135 }, { 0.098, 0.29 } },
	{ { 0.036, 0.045 }, { 0.135, 0.09 }, { 0.232, 0.205 } },
	{ { 0.036, 0.022 }, { 0.135, -0.008 }, { 0.232, -0.15 } },
	{ { 0.03, 0.006 }, { 0.088, -0.075 }, { 0.092, -0.245 } },
}

local function emblem(ctx: Ctx, segName: string, anchor: Vector3, n: Vector3, scale: number, colorKey: string)
	local u, v = Shapes.tangentBasis(n, Vector3.yAxis)
	for _, b in EMBLEM_BODY do
		local hit = project(ctx, segName, anchor, u, v, n, b[1] * scale, b[2] * scale)
		-- body ellipses are elongated vertically: b = vertical semi-axis
		patch(ctx, segName, "Emblem", hit.position, hit.normal, b[4] * scale, b[3] * scale, Vector3.yAxis, 0.013, colorKey)
	end
	for _, sx in { 1, -1 } do
		for _, leg in EMBLEM_LEGS do
			for i = 1, #leg - 1 do
				local a2, b2 = leg[i], leg[i + 1]
				local ha = project(ctx, segName, anchor, u, v, n, a2[1] * sx * scale, a2[2] * scale)
				local hb = project(ctx, segName, anchor, u, v, n, b2[1] * sx * scale, b2[2] * scale)
				local mid = (ha.position + hb.position) / 2
				local nn = (ha.normal + hb.normal).Unit
				local seg = hb.position - ha.position
				local len = seg.Magnitude
				local width = (if i == 1 then 0.03 else 0.02) * scale
				-- patch whose major axis follows the leg segment
				local hit = Shapes.cast(ctx.shells[segName], mid + nn * 0.5, -nn)
				local pos = if hit then hit.position else mid
				patch(ctx, segName, "Emblem", pos, nn, len / 2 + width * 0.45, width / 2, seg, 0.011, colorKey)
			end
		end
	end
end

local function abs(ctx: Ctx)
	local U = "UpperTorso"
	for _, row in { 3.88, 3.745, 3.61 } do
		for _, sx in { 1, -1 } do
			local hit = Shapes.cast(ctx.shells[U], v3(0.072 * sx, row, -1), v3(0, 0, 1))
			if hit then
				patch(ctx, U, "Abs", hit.position, hit.normal, 0.07, 0.052, Vector3.xAxis, 0.009, "Suit")
			end
		end
	end
end

--[[ Rim line: a thin flattened disc on the plane, sized a hair larger than the plane's section
	 of the ellipsoid, so only a fine raised rim shows on the surface (one part per line loop). ]]
local function rimDisc(ctx: Ctx, segName: string, e: Ellipsoid, point: Vector3, normal: Vector3, width: number, minVisible: number?)
	local sec = Shapes.planeSection(e, point, normal)
	if not sec or sec.b < 0.025 then
		return
	end
	local k = 0.028
	local ea = math.max(sec.a * k, 0.0065)
	local eb = math.max(sec.b * k, 0.0065)
	local vis = Shapes.rimVisibility(ctx.shells[segName], e, sec, 0.004)
	if vis < (minVisible or 0.05) then
		return
	end
	-- disc half-thickness such that the exposed rim is ~`width` wide
	local rhoS = sec.a / (sec.a + ea)
	local half = (width / 2) / math.sqrt(1 - rhoS * rhoS)
	local zAxis = sec.major:Cross(sec.normal).Unit
	local cf = CFrame.fromMatrix(sec.center, sec.major, sec.normal, zAxis)
	local part = newDetailPart(ctx, segName, "WebRim", cf, Vector3.new(2 * (sec.a + ea), 2 * half, 2 * (sec.b + eb)), "Web", false)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = part
end

-- Rim discs for a family of planes, on every ellipsoid of the given colors in a segment shell.
local function rimFamily(ctx: Ctx, segName: string, planes: { { Vector3 } }, colors: { [string]: boolean }, width: number)
	for _, pl in planes do
		for _, e in ctx.shells[segName] do
			if colors[e.color] then
				rimDisc(ctx, segName, e, pl[1], pl[2], width)
			end
		end
	end
end

--[[ Polar web: radials are rim discs on planes through the pole axis; the concentric strands are
	 straight raised threads between neighbouring radials (polygonal, like real silk). ]]
type PolarSpec = {
	segment: string,
	origin: Vector3,
	pole: Vector3,
	ref: Vector3,
	radials: number,
	phase: number?,
	rings: { number },
	colors: { [string]: boolean },
	width: number,
	strandRadius: number,
	skipRadials: boolean?,
}

local function polarWeb(ctx: Ctx, spec: PolarSpec)
	local shell = ctx.shells[spec.segment]
	local pole = spec.pole.Unit
	local ref = (spec.ref - pole * spec.ref:Dot(pole)).Unit
	local ref2 = pole:Cross(ref).Unit
	local phase = spec.phase or 0
	local dphi = 2 * math.pi / spec.radials

	if not spec.skipRadials then
		local planes = {}
		for k = 0, spec.radials / 2 - 1 do
			local phi = phase + k * dphi
			local side = ref * math.cos(phi) + ref2 * math.sin(phi)
			table.insert(planes, { spec.origin, pole:Cross(side).Unit })
		end
		rimFamily(ctx, spec.segment, planes, spec.colors, spec.width)
	end

	local function hitAt(theta: number, phi: number): Shapes.Hit?
		local side = ref * math.cos(phi) + ref2 * math.sin(phi)
		local dir = (pole * math.cos(theta) + side * math.sin(theta)).Unit
		local hit = Shapes.castInward(shell, spec.origin, dir)
		if hit and spec.colors[hit.shape.color] then
			return hit
		end
		return nil
	end

	-- emits a strand between two surface hits, splitting it where a straight chord would float
	-- off (concave areas such as under the jaw) or cut into the surface
	local function strand(a: Shapes.Hit, b: Shapes.Hit, depth: number)
		local mid = (a.position + b.position) / 2
		local n = (a.normal + b.normal).Unit
		local hit = Shapes.cast(shell, mid + n * 0.6, -n)
		if not hit or not spec.colors[hit.shape.color] then
			return
		end
		local gap = (mid - hit.position):Dot(n) -- > 0: chord floats above the surface
		if depth < 3 and (gap > 0.006 or gap < -0.02) then
			strand(a, hit, depth + 1)
			strand(hit, b, depth + 1)
			return
		end
		line(ctx, spec.segment, { points = { a.position, b.position }, normals = { a.normal, b.normal } }, spec.strandRadius, "Web")
	end

	for _, theta in spec.rings do
		local pts: { Shapes.Hit? } = {}
		for k = 0, spec.radials - 1 do
			pts[k + 1] = hitAt(theta, phase + k * dphi)
		end
		for k = 1, spec.radials do
			local a = pts[k]
			local b = pts[(k % spec.radials) + 1]
			if a and b then
				-- the strand midpoint must also be on an allowed color, else it would cross a seam
				local mid = hitAt(theta * math.cos(dphi / 2), phase + (k - 0.5) * dphi)
				if mid then
					strand(a, b, 0)
				end
			end
		end
	end
end

-- Longitudinal rim lines + rings around a limb axis (gloves, boots, deltoids, hands, feet).
local function limbWeb(ctx: Ctx, segName: string, axisFrame: CFrame, lines: number, phase: number, rings: { number }, width: number)
	local axis = axisFrame.UpVector
	local origin = axisFrame.Position
	local planes = {}
	for k = 0, lines / 2 - 1 do
		local phi = phase + k * (2 * math.pi / lines)
		local side = axisFrame:VectorToWorldSpace(Vector3.new(math.cos(phi), 0, math.sin(phi)))
		table.insert(planes, { origin, axis:Cross(side).Unit })
	end
	for _, y in rings do
		table.insert(planes, { origin + axis * y, axis })
	end
	rimFamily(ctx, segName, planes, { Suit = true }, width)
end

local function webPatterns(ctx: Ctx)
	if ctx.detail <= 0 then
		return
	end
	local high = ctx.detail >= 2
	local R = math.rad
	local suitOnly = { Suit = true }

	-- Head: 12 radials from the center of the face converge again at the back of the head
	polarWeb(ctx, {
		segment = "Head",
		origin = v3(0, 5.14, 0.0),
		pole = (v3(0, 5.2, -0.4) - v3(0, 5.14, 0.0)),
		ref = Vector3.yAxis,
		radials = 12,
		rings = if high then { R(16), R(32), R(50), R(70), R(93), R(119), R(147) } else { R(20), R(44), R(72), R(104), R(138) },
		colors = suitOnly,
		width = 0.013,
		strandRadius = 0.0068,
	})

	-- Torso: one axis through the chest and back emblems, so radials run emblem to emblem over the
	-- shoulders; each side gets its own concentric strands.
	local torsoOrigin = v3(0, 4.22, 0.0)
	local frontPole = v3(0, 0.015, -1)
	polarWeb(ctx, {
		segment = "UpperTorso",
		origin = torsoOrigin,
		pole = frontPole,
		ref = Vector3.yAxis,
		radials = 12,
		phase = math.pi / 12,
		rings = if high then { R(18), R(34), R(51), R(69), R(88) } else { R(24), R(50), R(78) },
		colors = suitOnly,
		width = 0.0145,
		strandRadius = 0.0075,
	})
	polarWeb(ctx, {
		segment = "UpperTorso",
		origin = torsoOrigin,
		pole = -frontPole,
		ref = Vector3.yAxis,
		radials = 12,
		phase = math.pi / 12,
		rings = if high then { R(18), R(34), R(51), R(69) } else { R(26), R(56) },
		colors = suitOnly,
		width = 0.0145,
		strandRadius = 0.0075,
		skipRadials = true, -- shared with the front system
	})

	for _, side in { "Right", "Left" } do
		local sx = if side == "Right" then 1 else -1
		limbWeb(ctx, side .. "UpperArm", CFrame.new(0.65 * sx, 4.34, 0.02) * CFrame.Angles(0, 0, math.rad(14 * sx)), 8, math.pi / 8, { -0.1, 0.05 }, 0.013)
		limbWeb(ctx, side .. "LowerArm", CFrame.new(0.62 * sx, 2.9, 0.025), 8, math.pi / 8, { -0.13, -0.02, 0.09 }, 0.012)
		limbWeb(ctx, side .. "LowerLeg", CFrame.new(0.25 * sx, 0.7, 0.02), 10, math.pi / 10, { -0.3, -0.15, 0.0, 0.14 }, 0.013)
		if high then
			limbWeb(ctx, side .. "Hand", CFrame.new(0.625 * sx, 2.5, 0.015), 8, math.pi / 8, { 0.04 }, 0.011)
			limbWeb(ctx, side .. "Foot", CFrame.fromMatrix(v3(0.25 * sx, 0.14, -0.1), Vector3.xAxis, v3(0, 0, -1)), 8, math.pi / 8, { 0.12, 0.3 }, 0.012)
		end
	end
end

local function fingers(ctx: Ctx)
	-- finger segments are visible rig parts: ellipsoids slightly longer than the bone so joints overlap
	for _, seg in RigDefinition.Segments do
		if seg.finger then
			local part = ctx.segParts[seg.name] :: Part
			local len = seg.size.Y
			local t = seg.size.X
			part.Size = Vector3.new(t, len + t * 0.6, t * 0.95)
			part.Transparency = 0
			part.Color = colorOf(ctx, "Suit")
			part.Material = Enum.Material.SmoothPlastic
			local mesh = Instance.new("SpecialMesh")
			mesh.MeshType = Enum.MeshType.Sphere
			mesh.Parent = part
		end
	end
	-- knuckle balls on every finger joint pivot keep curled fingers continuous
	for _, j in RigDefinition.Joints do
		if j.finger then
			local seg = RigDefinition.SegmentByName[j.part1]
			local t = seg.size.X * 0.98
			local ball = newDetailPart(ctx, j.part1, "Knuckle", CFrame.new(j.pivot), Vector3.new(t, t, t), "Suit", false)
			local mesh = Instance.new("SpecialMesh")
			mesh.MeshType = Enum.MeshType.Sphere
			mesh.Parent = ball
		end
	end
end

--------------------------------------------------------------------------------------------------
-- Rig
--------------------------------------------------------------------------------------------------

local ACCESSORY_ATTACHMENTS: { { string } } = {
	-- part, name, x, y, z (rest world) [, rotX, rotY, rotZ deg]
	{ "Head", "HatAttachment", "0", "5.56", "0.0" },
	{ "Head", "HairAttachment", "0", "5.5", "0.0" },
	{ "Head", "FaceFrontAttachment", "0", "5.18", "-0.36" },
	{ "Head", "FaceCenterAttachment", "0", "5.17", "-0.03" },
	{ "UpperTorso", "NeckAttachment", "0", "4.66", "0.03" },
	{ "UpperTorso", "BodyFrontAttachment", "0", "4.05", "-0.37" },
	{ "UpperTorso", "BodyBackAttachment", "0", "4.05", "0.37" },
	{ "UpperTorso", "LeftCollarAttachment", "-0.4", "4.55", "0.0" },
	{ "UpperTorso", "RightCollarAttachment", "0.4", "4.55", "0.0" },
	{ "LowerTorso", "WaistCenterAttachment", "0", "3.3", "0.0" },
	{ "LowerTorso", "WaistFrontAttachment", "0", "3.3", "-0.3" },
	{ "LowerTorso", "WaistBackAttachment", "0", "3.3", "0.3" },
	{ "LeftUpperArm", "LeftShoulderAttachment", "-0.64", "4.6", "0.02" },
	{ "RightUpperArm", "RightShoulderAttachment", "0.64", "4.6", "0.02" },
	{ "LeftFoot", "LeftFootAttachment", "-0.25", "0.0", "-0.15" },
	{ "RightFoot", "RightFootAttachment", "0.25", "0.0", "-0.15" },
}

local function buildRig(ctx: Ctx)
	local model = ctx.model
	for _, seg in RigDefinition.Segments do
		local p = Instance.new("Part")
		p.Name = seg.name
		p.Size = seg.size
		p.CFrame = CFrame.new(seg.center)
		p.Transparency = 1
		p.CanCollide = seg.canCollide
		p.CanTouch = true
		p.CanQuery = not seg.finger
		p.Massless = seg.finger == true
		p.Color = ctx.palette.Suit
		p.Material = Enum.Material.SmoothPlastic
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.CastShadow = false
		if seg.name == "HumanoidRootPart" then
			p.RootPriority = 127
		end
		p.Parent = model
		ctx.segParts[seg.name] = p
	end

	for _, j in RigDefinition.Joints do
		local c0, c1 = RigDefinition.JointC0C1(j)
		local m = Instance.new("Motor6D")
		m.Name = j.name
		m.Part0 = ctx.segParts[j.part0]
		m.Part1 = ctx.segParts[j.part1]
		m.C0 = c0
		m.C1 = c1
		m.MaxVelocity = 0.1
		m.Parent = ctx.segParts[j.part1]
		if j.rigAttachment then
			-- R15 rig attachments (used by BuildRigFromAttachments / layered clothing)
			local a0 = Instance.new("Attachment")
			a0.Name = j.rigAttachment
			a0.CFrame = c0
			a0.Parent = ctx.segParts[j.part0]
			local a1 = Instance.new("Attachment")
			a1.Name = j.rigAttachment
			a1.CFrame = c1
			a1.Parent = ctx.segParts[j.part1]
		end
	end

	for _, a in ACCESSORY_ATTACHMENTS do
		local part = ctx.segParts[a[1]]
		local att = Instance.new("Attachment")
		att.Name = a[2]
		att.CFrame = part.CFrame:Inverse() * CFrame.new(tonumber(a[3]) :: number, tonumber(a[4]) :: number, tonumber(a[5]) :: number)
		att.Parent = part
	end
	-- tool grips (standard R15 orientation)
	for _, side in { "Right", "Left" } do
		local att = Instance.new("Attachment")
		att.Name = side .. "GripAttachment"
		att.CFrame = CFrame.new(0, -0.2, 0) * CFrame.Angles(-math.pi / 2, 0, 0)
		att.Parent = ctx.segParts[side .. "Hand"]
	end
	-- web attach points used by the swing VFX (palm center, slightly toward the fingers)
	for _, side in { "Right", "Left" } do
		local sx = if side == "Right" then 1 else -1
		local att = Instance.new("Attachment")
		att.Name = "WebAttachment"
		att.CFrame = CFrame.new(-0.07 * sx, -0.14, -0.005)
		att.Parent = ctx.segParts[side .. "Hand"]
	end

	local hum = Instance.new("Humanoid")
	hum.RigType = Enum.HumanoidRigType.R15
	hum.HipHeight = RigDefinition.HipHeight
	hum.AutomaticScalingEnabled = false
	hum.WalkSpeed = 22
	hum.UseJumpPower = true
	hum.JumpPower = 62
	hum.MaxSlopeAngle = 60
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	hum.Parent = model

	local marker = Instance.new("StringValue")
	marker.Name = "SpiderRig"
	marker.Value = "SpiderHeroKit/1"
	marker.Parent = model

	model.PrimaryPart = ctx.segParts.HumanoidRootPart
end

function Builder.build(opts: BuildOptions?): Model
	local o = opts or {}
	local paletteName = o.palette or "Classic"
	local palette = Palette[paletteName]
	assert(palette, "unknown palette " .. paletteName)
	local detailName = o.detail or "High"
	local detail = if detailName == "High" then 2 elseif detailName == "Medium" then 1 else 0

	local model = Instance.new("Model")
	model.Name = o.name or "SpiderHero"
	local folder = Instance.new("Folder")
	folder.Name = "Suit"
	folder.Parent = model

	local ctx: Ctx = {
		model = model,
		palette = palette,
		segParts = {},
		shells = {},
		folder = folder,
		partCount = 0,
		detail = detail,
	}

	buildRig(ctx)
	sculptTorso(ctx)
	sculptHead(ctx)
	sculptArm(ctx, "Right", 1)
	sculptArm(ctx, "Left", -1)
	sculptLeg(ctx, "Right", 1)
	sculptLeg(ctx, "Left", -1)
	fingers(ctx)
	lenses(ctx)
	abs(ctx)
	-- chest and back emblems
	local chestHit = Shapes.cast(ctx.shells.UpperTorso, v3(0, 4.24, -2), v3(0, 0, 1))
	assert(chestHit, "chest emblem projection failed")
	emblem(ctx, "UpperTorso", chestHit.position, chestHit.normal, 1.0, "Emblem")
	local backHit = Shapes.cast(ctx.shells.UpperTorso, v3(0, 4.22, 2), v3(0, 0, -1))
	assert(backHit, "back emblem projection failed")
	emblem(ctx, "UpperTorso", backHit.position, backHit.normal, 0.82, "Emblem")
	webPatterns(ctx)

	model:SetAttribute("SuitPartCount", ctx.partCount)
	return model
end

return Builder
