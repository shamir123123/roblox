--!strict

local RoadConstants = require(script.Parent.RoadConstants)
local BezierUtil = require(script.Parent.BezierUtil)
local RoadMeshBuilder = require(script.Parent.RoadMeshBuilder)

local IntersectionRenderer = {}

local UP     = Vector3.yAxis
local TWO_PI = math.pi * 2

export type Arm = {
	dir: Vector3,
	width: number,
	-- Node-tool shaping for this arm (see RoadTypes.Segment.startCorner/startOffset).
	-- corner: this arm's corner-fillet radius, nil = JUNCTION_CORNER_RADIUS. A corner
	-- between two arms uses the LARGER of the pair, so widening one arm's radius opens
	-- both of its corners rather than fighting its neighbour.
	-- offset: studs the arm's mouth is pushed further out of the junction (may be
	-- negative to pull it in; never inside the arm's own half-width).
	corner: number?,
	offset: number?,
	-- Flat junction (node-tool). Describes the whole plate, not this arm: the server writes
	-- it onto every arm at the node, and ANY arm carrying it flattens the junction -- so an
	-- arm drawn into a flat junction later, which arrives without the flag, doesn't unflatten
	-- it. Levels the paved plate at the node's own height; the corner rims still ramp to each
	-- arm's real mouth, so the seams with the roads stay exact.
	flat: boolean?,
	-- True for a roundabout ring arc. The corner between two ring arms gets no curb/edge
	-- line (it's the continuous circulating carriageway, not a junction corner).
	ring: boolean?,
	-- Optional anchor onto the real segment at the junction trim distance. When present,
	-- the box junction builds this arm's mouth exactly on the segment surface (position,
	-- heading, height), so curved or graded approaches join without gaps or steps.
	reach: number?,       -- arc-length from the node at which the anchor was sampled
	mouthPos: Vector3?,   -- segment centerline point at `reach`
	mouthTan: Vector3?,   -- tangent there, pointing away from the node
	profile: { number }?, -- centerline heights at uniform arc steps, node -> mouth
	-- Does this arm's road carry a sidewalk on each side, seen looking OUT along `dir`
	-- (+side = right)? nil = yes. A junction corner joins arm i's RIGHT kerb to arm j's
	-- LEFT one, and is kerbed when EITHER of those sides has a sidewalk -- the run then
	-- curves round the corner and stops flush at the sidewalk-less arm's mouth, instead
	-- of one bare approach stripping the kerbs off corners it isn't even part of.
	swRight: boolean?,
	swLeft: boolean?,
}

type MouthFrame = {
	dir: Vector3,
	side: Vector3,
	mouthC: Vector3,
	grade: number,
	reach: number,
	hw: number,
	profTop: { number }?,
	through: boolean,
	corner: number?,
}

local function meet(p1: Vector3, d1: Vector3, p2: Vector3, d2: Vector3): Vector3?
	local rxs = d1.X*d2.Z - d1.Z*d2.X
	if math.abs(rxs) < 1e-4 then return nil end
	local t = ((p2.X-p1.X)*d2.Z - (p2.Z-p1.Z)*d2.X) / rxs
	return Vector3.new(p1.X + d1.X*t, p1.Y, p1.Z + d1.Z*t)
end

local function effectiveCornerRadius(override: number?): number
	return math.max(
		override or RoadConstants.JUNCTION_CORNER_RADIUS,
		RoadConstants.SIDEWALK_WIDTH * 0.5 + RoadConstants.JUNCTION_MIN_INNER_CURB_RADIUS
	)
end

-- The radius a corner between two arms rounds at: the larger of the pair's overrides.
local function pairCornerRadius(a: number?, b: number?): number?
	if a and b then return math.max(a, b) end
	return a or b
end

-- The node-tool overrides a segment carries at the END that meets `nodeId`, ready to
-- stamp onto an Arm. Every site that builds arms for a node calls this, so the junction
-- mesh, the nav graph, the plot clearances and the NPC stop lines all trim alike.
function IntersectionRenderer.armOverrides(seg: any, nodeId: number): (number?, number?, boolean?)
	if seg.startNode == nodeId then
		return seg.startCorner, seg.startOffset, seg.startFlat
	end
	return seg.endCorner, seg.endOffset, seg.endFlat
end

-- Size the arm reach for the KERB's fillet, not the carriageway edge's. The kerb runs
-- SIDEWALK_WIDTH/2 outside the pavement, where the same corner needs both a further-out
-- edge meet AND a longer tangent to turn through the corner radius. Sizing it at the
-- pavement edge left the kerb about a quarter tighter than JUNCTION_CORNER_RADIUS asks
-- for -- a right-angle corner rounded over ~4 studs instead of 6, which reads as a sharp
-- elbow rather than a curve. Everything downstream (surface trim, crosswalk, stop line,
-- sidewalk, NPC crossing paths) keys off this one distance, so they all move together.
-- The gore of a Y: the corner BETWEEN two branches whose third arm (the stem) runs back
-- against both, with no footway on either side of it. A road splitting in two meets there in
-- a sharp painted nose (CS2), not a kerb fillet -- the round fillet read as a blunt U-shaped
-- island sitting in the middle of the carriageway.
local GORE_NOSE_RADIUS = 0.5
local GORE_STEM_DOT = -0.5
local function isGore(stemDir: Vector3, dirA: Vector3, dirB: Vector3, kerbed: boolean): boolean
	return not kerbed and stemDir:Dot(dirA) < GORE_STEM_DOT and stemDir:Dot(dirB) < GORE_STEM_DOT
end

local function cornerTangent(center: Vector3, dirA: Vector3, hwA: number, dirB: Vector3, hwB: number, signA: number, signB: number, cornerRadius: number?, sharp: boolean?): number?
	if dirA:Dot(dirB) < -0.999 then return nil end
	local kerbOut = if sharp then 0 else RoadConstants.SIDEWALK_WIDTH * 0.5
	local perpA = Vector3.new(-dirA.Z, 0, dirA.X)
	local perpB = Vector3.new(-dirB.Z, 0, dirB.X)
	local N = meet(center + perpA * ((hwA + kerbOut) * signA), dirA, center + perpB * ((hwB + kerbOut) * signB), dirB)
	if not N then return nil end
	local theta = math.acos(math.clamp(dirA:Dot(dirB), -1, 1))
	if theta < 0.05 then return nil end

	local radius = if sharp then GORE_NOSE_RADIUS else effectiveCornerRadius(cornerRadius) + kerbOut
	local fillet = radius / math.max(math.tan(theta * 0.5), 1e-3)
	fillet = math.min(fillet, radius * 2.5)
	return dirA:Dot(N - center) + fillet
end

export type ArmCorners = { cw: number, ccw: number }

-- Each arm's TWO corner-tangent distances -- the fillet reach on its clockwise side and on
-- its counter-clockwise side, looking out of the node (ccw is the +perp(dir) side). The arm's
-- MOUTH is the larger of the pair (armBoundaryDistances below), because the surface has to
-- clear whichever corner turns furthest out; the pair itself is what the crossing paint needs,
-- since at a skewed junction the two corners genuinely sit at different distances and the line
-- between them -- not the square mouth -- is where a real zebra goes.
function IntersectionRenderer.armCornerDistances(center: Vector3, arms: { Arm }): { ArmCorners }
	local out: { ArmCorners } = table.create(#arms)

	local list = {}
	for i, a in arms do
		local flat = Vector3.new(a.dir.X, 0, a.dir.Z)
		if flat.Magnitude < 1e-6 then continue end
		table.insert(list, { idx = i, dir = flat.Unit, hw = a.width * 0.5, angle = math.atan2(a.dir.Z, a.dir.X), corner = a.corner, offset = a.offset,
			swRight = a.swRight ~= false, swLeft = a.swLeft ~= false })
	end
	table.sort(list, function(x, y) return x.angle < y.angle end)
	local n = #list
	if n == 0 then return out end

	local maxHalf = 0
	for _, e in list do maxHalf = math.max(maxHalf, e.hw) end

	-- Shallow-angle corners send the meet() point to infinity; clamp so a fork never
	-- paves a giant delta (see JUNCTION_MAX_REACH_FACTOR).
	local reachCap = maxHalf * RoadConstants.JUNCTION_MAX_REACH_FACTOR
	-- Node-tool push applies AFTER the shallow-angle cap: the cap exists to stop the
	-- fillet maths spiking a giant delta, not to overrule a distance the player asked
	-- for. Floored at the arm's own half-width so a pull-in can never invert the mouth.
	local function seat(p: number?, hw: number, offset: number?): number
		return math.max(math.min(math.max(maxHalf, p or 0), reachCap) + (offset or 0), hw)
	end
	for i = 1, n do
		local A = list[i]
		local B = list[(i % n) + 1]
		local C = list[((i - 2) % n) + 1]
		-- With three arms, the arm opposite a corner is the one not in it.
		local goreCCW = n == 3 and isGore(C.dir, A.dir, B.dir, A.swRight or B.swLeft)
		local goreCW = n == 3 and isGore(B.dir, C.dir, A.dir, C.swRight or A.swLeft)
		local pCCW = cornerTangent(center, A.dir, A.hw, B.dir, B.hw, 1, -1, pairCornerRadius(A.corner, B.corner), goreCCW)
		local pCW  = cornerTangent(center, A.dir, A.hw, C.dir, C.hw, -1, 1, pairCornerRadius(A.corner, C.corner), goreCW)
		out[A.idx] = { cw = seat(pCW, A.hw, A.offset), ccw = seat(pCCW, A.hw, A.offset) }
	end
	return out
end

function IntersectionRenderer.armBoundaryDistances(center: Vector3, arms: { Arm }): { number }
	local out = table.create(#arms, 0)
	local corners = IntersectionRenderer.armCornerDistances(center, arms)
	for i = 1, #arms do
		local c = corners[i]
		out[i] = if c then math.max(c.cw, c.ccw) else 0
	end
	return out
end

-- Tightest radius of the corner connector RoadSceneRenderer would build between two arms
-- meeting at a degree-2 node (a bend). Mirrors that connector's geometry exactly: the
-- arm-boundary reach, then the circular-arc cubic handle. Placement validation calls this to
-- reject a weld whose bend would fold the inner curb through itself BEFORE it is built --
-- the connector path bypasses the curve-radius gate, so this is its only check. dirA/dirB are
-- unit arm directions pointing AWAY from the node; hwA/hwB are their half-widths.
function IntersectionRenderer.connectorMinRadius(dirA: Vector3, hwA: number, dirB: Vector3, hwB: number): number
	local hw = math.min(hwA, hwB) -- a 2-arm node renders at the narrower arm's width
	local arms = { { dir = dirA, width = hw * 2 }, { dir = dirB, width = hw * 2 } }
	local dists = IntersectionRenderer.armBoundaryDistances(Vector3.zero, arms)
	local p0 = dirA * dists[1]
	local p3 = dirB * dists[2]
	local angle = math.acos(math.clamp((-dirA):Dot(dirB), -1, 1))
	local chord = (p3 - p0).Magnitude
	local handle = if angle < 1e-3
		then chord / 3
		else (2 / 3) * chord * math.tan(angle * 0.25) / math.max(math.sin(angle * 0.5), 1e-3)
	local c1 = p0 - dirA * handle
	local c2 = p3 - dirB * handle
	return BezierUtil.minRadius(p0, c1, c2, p3, 20)
end

export type IntersectionOptions = {
	surfaceColor : Color3,
	markingColor : Color3?,
	anchored     : boolean?,
	canCollide   : boolean?,
	shape        : string?,
	extent       : number?,
	setback      : number?,
	edgeLineWidth: number?,
	sidewalk     : boolean?,
	sidewalkColor: Color3?,
	sidewalkHeight: number?,
	sidewalkWidth: number?,
	groundSkirt: number?,
}

function IntersectionRenderer.build(
	center  : Vector3,
	arms    : { Arm },
	parent  : Instance,
	options : IntersectionOptions
): Model

	local model     = Instance.new("Model")
	model.Name      = "Junction"
	-- ponytail: ONE junction mesh -- surface, curbs AND markings in a single builder/MeshPart.
	-- It's CanQuery (NPC connectors raycast the surface for Y); curbs being queryable too is
	-- harmless since connectors sample lane points INSIDE the kerb line, not on it.
	local surfaceBuilder = RoadMeshBuilder.new()

	local thickness  = RoadConstants.ROAD_THICKNESS
	local anchored   = if options.anchored   == nil then true else options.anchored
	local canCollide = if options.canCollide == nil then true else options.canCollide
	local markColor  = options.markingColor
	local markColorFb = markColor or Color3.new(1, 1, 1)
	local markY      = thickness * 0.5 + 0.015 -- ponytail: flush -- paint sits in the surface, not a raised tile
	local curbW      = RoadConstants.JUNCTION_EDGE_WIDTH
	local swOn       = options.sidewalk == true
	local swColor    = options.sidewalkColor  or RoadConstants.SIDEWALK_COLOR
	local swH        = options.sidewalkHeight or RoadConstants.SIDEWALK_HEIGHT
	local swWidth    = options.sidewalkWidth  or RoadConstants.SIDEWALK_WIDTH
	-- Ground junctions: kerbs keep their TOP but extend down into the graded grass (see
	-- RoadConstants.GROUND_SKIRT), hiding the terrain-clearance gap under the disc edge.
	local skirt      = options.groundSkirt or 0
	local edgeW      = options.edgeLineWidth  or 0.4
	local edgeOff    = edgeW * 0.5 + 0.05

	local maxHalf = 0
	for _, a in arms do maxHalf = math.max(maxHalf, a.width * 0.5) end
	-- Shared shallow-angle cap (see JUNCTION_MAX_REACH_FACTOR): bounds both the arm
	-- reach and the corner-fan control point so a fork never spikes a long thin delta.
	local reachCap = maxHalf * RoadConstants.JUNCTION_MAX_REACH_FACTOR

	local extent = options.extent or (maxHalf + RoadConstants.JUNCTION_MARGIN)
	local shape  = options.shape  or "corner"

	-- Node-tool flat plate. Any arm carrying the flag speaks for the node (see Arm.flat).
	-- plateY is the node's OWN surface top -- the height every arm's centreline actually
	-- passes through, since they all share this endpoint -- so levelling to it moves the
	-- plate the least it can while still being level.
	local flatNode = false
	for _, a in arms do
		if a.flat then
			flatNode = true
			break
		end
	end
	local plateY = center.Y + thickness * 0.5
	-- How hard a point on a corner rim is pulled onto the plate: 0 at both mouths, 1 across
	-- the middle half, smoothstep between. A hard flatten would step the rim by the arm's
	-- whole rise the moment it left a mouth -- a fin at every corner on a graded approach --
	-- so the plate stays genuinely level in the middle and the last quarter ramps out to the
	-- road. The kerb pass below reproduces this exactly, so surface and kerb never split.
	local function plateBlend(u: number): number
		local t = math.clamp((if u < 0.5 then u else 1 - u) / 0.25, 0, 1)
		return t * t * (3 - 2 * t)
	end

	local function wedge(color: Color3): WedgePart
		local w = Instance.new("WedgePart")
		w.Anchored = anchored; w.CanCollide = canCollide
		-- Queryable when collidable: NPC connectors raycast the junction surface to
		-- ground their Y on warped (graded) interiors. Ghost previews stay inert.
		w.CanTouch = false;    w.CanQuery   = canCollide; w.CastShadow = false
		w.Material = Enum.Material.SmoothPlastic
		w.Color = color
		w.TopSurface = Enum.SurfaceType.Smooth
		w.BottomSurface = Enum.SurfaceType.Smooth
		w.Parent = model
		return w
	end

	-- Painted junction lines bake into the piece's mesh as thin ribbons (addMarkingLine) --
	-- no beams, no separate meshes. Lift keeps the paint above the faceted surface.
	-- Matches RoadRenderer's yOff (0.05 above the slab top). The old +0.12 floated junction
	-- paint at 0.135 while segment paint sat at 0.05, so lines stepped at the seam.
	local LINE_LIFT = Vector3.new(0, RoadConstants.ZFIGHT_OFFSET * 2, 0)
	-- Corner edge line = the kerb's OWN path pulled `dist` toward the carriageway, measured
	-- with the same tangent-perpendicular curbRun takes its faces from. The two used to be
	-- built as separate offset fillets (cornerGeom at each one's lateral offset), and an
	-- offset control polygon is not an offset curve -- so the paint drifted off the kerb face
	-- mid-fillet: the gap between the white line and the sidewalk.
	-- A corner path runs from arm i's +side mouth edge round to arm j's -side one, so it
	-- leaves p0 heading back toward the node: its tangent-perpendicular points INTO the
	-- carriageway, and the paint moves along +perp. (curbRun's inner/outer are bare labels
	-- on a symmetric loft, so they are no guide to which side the road is on.)
	-- Lateral offset only -- Y is placed on the junction surface by the caller.
	local function insetPath(pts: { Vector3 }, dist: number): { Vector3 }
		local m = #pts
		local out = table.create(m)
		for i = 1, m do
			local tangent = pts[math.min(i + 1, m)] - pts[math.max(i - 1, 1)]
			local flat = Vector3.new(-tangent.Z, 0, tangent.X)
			local perp = if flat.Magnitude > 1e-4 then flat.Unit else Vector3.xAxis
			out[i] = pts[i] + perp * dist
		end
		return out
	end


	local function raisedCurb(a: Vector3, b: Vector3)
		local d = b - a; local len = d.Magnitude
		if len < 1e-3 then return end
		local fwd = d.Unit
		local up = UP - fwd * fwd:Dot(UP)
		up = if up.Magnitude > 1e-4 then up.Unit else UP
		surfaceBuilder:addBox(
			CFrame.fromMatrix((a + b) * 0.5 + Vector3.new(0, thickness * 0.5 + (swH - skirt) * 0.5, 0), fwd, up),
			Vector3.new(len + 0.3, swH + skirt, swWidth),
			swColor
		)
	end

	-- Curb laid along a 3D polyline whose points sit ON the surface top, as a welded LOFT
	-- (top + two walls, hollow) -- same cross-section as RoadRenderer's segment kerb loft,
	-- so the junction kerb IS the segment kerb: same look, height, width and shading.
	local function curbRun(pts: { Vector3 })
		local n = #pts
		if n < 2 then return end
		local hwK = swWidth * 0.5
		local innerT = table.create(n)
		local outerT = table.create(n)
		local innerB = table.create(n)
		local outerB = table.create(n)
		for i = 1, n do
			local tangent = pts[math.min(i + 1, n)] - pts[math.max(i - 1, 1)]
			local flat = Vector3.new(-tangent.Z, 0, tangent.X)
			local perp = if flat.Magnitude > 1e-4 then flat.Unit else Vector3.xAxis
			local a = pts[i] - perp * hwK
			local b = pts[i] + perp * hwK
			innerT[i] = a + UP * swH
			outerT[i] = b + UP * swH
			innerB[i] = a - UP * skirt
			outerB[i] = b - UP * skirt
		end
		surfaceBuilder:addSurfaceStrip(innerT, outerT, swColor, swH + skirt)
		surfaceBuilder:addSurfaceStrip(innerB, innerT, swColor, 0.05)
		surfaceBuilder:addSurfaceStrip(outerT, outerB, swColor, 0.05)
	end

	local list = {}
	for _, a in arms do
		local flat = Vector3.new(a.dir.X, 0, a.dir.Z)
		if flat.Magnitude < 1e-6 then continue end
		local dir  = flat.Unit
		local perp = Vector3.new(-dir.Z, 0, dir.X)
		local hw   = a.width * 0.5
		local base = center + dir * extent
		-- Sort anchored arms by where their mouth ACTUALLY sits, not by their node tangent:
		-- a sharply curved arm swings its mouth sideways, and node-tangent order can then
		-- build a self-crossing rim loop (the folded fill/curb bowtie).
		local mouthFlat = if a.mouthPos
			then Vector3.new(a.mouthPos.X - center.X, 0, a.mouthPos.Z - center.Z)
			else nil
		table.insert(list, {
			angle = if mouthFlat and mouthFlat.Magnitude > 1
				then math.atan2(mouthFlat.Z, mouthFlat.X)
				else math.atan2(dir.Z, dir.X),
			dir   = dir,
			hw    = hw,
			grade = a.dir.Y / flat.Magnitude,
			ccw   = base + perp * hw,
			cw    = base - perp * hw,
			anchorReach = a.reach,
			anchorPos = a.mouthPos,
			anchorTan = a.mouthTan,
			profile = a.profile,
			ring = a.ring,
			corner = a.corner,
			offset = a.offset,
			swRight = a.swRight ~= false,
			swLeft  = a.swLeft ~= false,
		})
	end
	table.sort(list, function(x,y) return x.angle < y.angle end)
	local n = #list
	if n == 0 then model.Parent = parent; return model end

	if shape ~= "box" then

		local radius = extent
		-- ponytail: disc = ONE Cylinder Part again (the fan existed only for the client
		-- EditableMesh vertex-paint merge, which is disabled -- roads are plain parts now).
		local discTopY = center.Y + thickness * 0.5
		local disc = Instance.new("Part")
		disc.Name = "JunctionDisc"
		disc.Shape = Enum.PartType.Cylinder
		disc.Anchored = anchored
		disc.CanCollide = canCollide
		disc.CanQuery = canCollide
		disc.CanTouch = false
		disc.CastShadow = false
		-- Same asphalt variant as the client's baked road meshes; colour boosted the same
		-- way the bake boosts vertex tints (part colour MULTIPLIES the colour map).
		disc.Material = Enum.Material.Asphalt
		disc.MaterialVariant = "RoadAsphalt"
		local sc = options.surfaceColor
		disc.Color = Color3.new(math.min(sc.R * 3.5, 1), math.min(sc.G * 3.5, 1), math.min(sc.B * 3.5, 1))
		disc.TopSurface = Enum.SurfaceType.Smooth
		disc.BottomSurface = Enum.SurfaceType.Smooth
		disc.Size = Vector3.new(thickness, radius * 2, radius * 2)
		-- Cylinder axis is local X; point it up so the flat face is the road surface.
		disc.CFrame = CFrame.fromMatrix(
			Vector3.new(center.X, discTopY - thickness * 0.5, center.Z),
			UP, Vector3.zAxis
		)
		disc.Parent = model

		local rEdge = radius - curbW * 0.5
		local rCurb = radius + swWidth * 0.5
		for i = 1, n do
			local A = list[i]
			local B = list[(i % n) + 1]
			local halfA = math.asin(math.clamp((A.ccw - A.cw).Magnitude * 0.5 / radius, 0, 1))
			local halfB = math.asin(math.clamp((B.ccw - B.cw).Magnitude * 0.5 / radius, 0, 1))
			local cover = 0.82
			local ccw = (B.angle - A.angle) % TWO_PI
			local gap = ccw - (halfA + halfB) * cover
			local drawArc = shape ~= "corner" or gap <= math.pi
			if gap > 0.05 and drawArc then
				local startA = A.angle + halfA * cover
				if shape ~= "corner" and markColor ~= nil then
					-- Edge arc baked as ONE marking ribbon along the sampled circle.
					local steps = math.max(8, math.ceil(math.deg(gap) / 6))
					local y = center.Y + markY
					local pts = table.create(steps + 1)
					for s = 0, steps do
						local ang = startA + gap * (s / steps)
						pts[s + 1] = Vector3.new(center.X + math.cos(ang) * rEdge, y, center.Z + math.sin(ang) * rEdge)
					end
					surfaceBuilder:addMarkingLine(pts, curbW, markColorFb, false)
				end
				if swOn then
					-- Ring kerb as a welded LOFT (top + two walls), replacing per-step boxes.
					local steps = math.max(2, math.ceil(gap / (math.pi / 24)))
					local innerT, outerT, innerB, outerB = {}, {}, {}, {}
					local baseY = center.Y + thickness * 0.5
					for s = 0, steps do
						local ang = startA + gap * (s / steps)
						local radial = Vector3.new(math.cos(ang), 0, math.sin(ang))
						local base = Vector3.new(center.X, baseY, center.Z)
						local inn = base + radial * (rCurb - swWidth * 0.5)
						local out = base + radial * (rCurb + swWidth * 0.5)
						table.insert(innerT, inn + UP * swH)
						table.insert(outerT, out + UP * swH)
						table.insert(innerB, inn - UP * skirt)
						table.insert(outerB, out - UP * skirt)
					end
					surfaceBuilder:addSurfaceStrip(innerT, outerT, swColor, swH + skirt)
					surfaceBuilder:addSurfaceStrip(innerB, innerT, swColor, 0.05)
					surfaceBuilder:addSurfaceStrip(outerT, outerB, swColor, 0.05)
				end
			end
		end

	else
		local sw2 = swWidth * 0.5

		local reach: { number } = table.create(n)
		for i = 1, n do
			local A = list[i]
			local B = list[(i % n) + 1]
			local C = list[((i - 2) % n) + 1]
			local d = maxHalf
			local goreCCW = n == 3 and isGore(C.dir, A.dir, B.dir, swOn and (A.swRight or B.swLeft))
			local goreCW = n == 3 and isGore(B.dir, C.dir, A.dir, swOn and (C.swRight or A.swLeft))
			local pccw = cornerTangent(center, A.dir, A.hw, B.dir, B.hw, 1, -1, pairCornerRadius(A.corner, B.corner), goreCCW)
			local pcw  = cornerTangent(center, A.dir, A.hw, C.dir, C.hw, -1, 1, pairCornerRadius(A.corner, C.corner), goreCW)
			if pccw then d = math.max(d, pccw) end
			if pcw then d = math.max(d, pcw) end
			-- Prefer the distance the anchor was sampled at, so the mouth lands exactly
			-- where the arm's surface, markings and curbs were trimmed. The bare fallback
			-- `d` (no anchor: Edit-mode / direct callers) gets the shallow-angle cap; an
			-- anchored reach is already clamped upstream and may carry a deliberate
			-- steep-arm apron extension, so it is trusted as-is.
			reach[i] = A.anchorReach or math.max(math.min(d, reachCap) + (A.offset or 0), A.hw)
		end

		-- Mouth frame per arm, matching RoadRenderer's ribbon frame exactly: horizontal
		-- side vector, road-up normal, vertices on the surface TOP. Anchored arms take
		-- the real segment point and tangent at the trim distance; unanchored arms fall
		-- back to a straight extrapolation from the node.
		local frames: { MouthFrame } = table.create(n)
		for i = 1, n do
			local A = list[i]
			local tan: Vector3 = A.anchorTan or (A.dir + UP * A.grade)
			if tan.Magnitude < 1e-6 then tan = A.dir end
			tan = tan.Unit
			local flatMag = math.sqrt(tan.X * tan.X + tan.Z * tan.Z)
			local dirFlat = if flatMag > 1e-6 then Vector3.new(tan.X / flatMag, 0, tan.Z / flatMag) else A.dir
			local side = Vector3.new(-dirFlat.Z, 0, dirFlat.X)
			local roadUp = side:Cross(tan)
			roadUp = if roadUp.Magnitude > 1e-6 then roadUp.Unit else UP
			local centerline: Vector3 = A.anchorPos or (center + A.dir * reach[i] + UP * (A.grade * reach[i]))
			local mouthC = centerline + roadUp * (thickness * 0.5)
			local profTop: { number }? = nil
			if A.profile and A.anchorPos and #A.profile >= 2 then
				local prof = table.create(#A.profile)
				for k, y in A.profile do
					prof[k] = y + thickness * 0.5
				end
				-- Pin the mouth entry to the exact lifted height so the seam is exact.
				prof[#prof] = mouthC.Y
				profTop = prof
			end
			frames[i] = {
				dir = dirFlat,
				side = side,
				mouthC = mouthC,
				grade = tan.Y / math.max(flatMag, 1e-4),
				reach = math.max(reach[i], 1e-3),
				hw = A.hw,
				profTop = profTop,
				through = false,
				corner = A.corner,
			}
		end

		-- Arms that continue nearly straight through the node form a through road. Its
		-- surface owns its corridor across the junction; side arms conform to it instead
		-- of bending it (a flat main road must stay flat when an elevated side road joins).
		for i = 1, n do
			for j = i + 1, n do
				if frames[i].dir:Dot(frames[j].dir) < -0.866 then
					frames[i].through = true
					frames[j].through = true
				end
			end
		end

		-- Two ADJACENT arms diverging at a shallow angle overlap at the mouth once the reach
		-- is clamped (JUNCTION_MAX_REACH_FACTOR): their edges cross, so a rounded fillet over
		-- the gore between them folds into a self-crossing curb/edge "bowtie". Detect the
		-- overlap exactly -- mouth centres closer than the combined half-widths -- and treat
		-- the pair as a merge: the surface loop chords straight across and no curb or edge
		-- line is drawn over the gore (the overlapping approach surfaces already cover it).
		local function isMergePair(i: number, j: number): boolean
			-- An approach<->ring corner is always a real junction corner, never a shallow-fork
			-- merge. A tangential roundabout entry reads as "parallel" on its downstream side,
			-- which would drop that corner's curb/edge and leave the sidewalk open on one side
			-- only (the killed-left / curbed-right asymmetry).
			if list[i].ring or list[j].ring then return false end
			local cosT = math.clamp(frames[i].dir:Dot(frames[j].dir), -1, 1)
			-- Only NEARLY-PARALLEL arms (a shallow fork) can fold a fillet. Arms that diverge
			-- widely make a normal convex corner even when their mouths sit close together
			-- (a tight Y at small reach), so never merge those.
			if cosT < 0.7 then return false end
			-- Separation of the REAL mouth centres: anchored arms follow their curve, and a
			-- bent arm moves the gore off the straight-ray model (which missed overlaps and
			-- drew fillets over crossing edges on curved forks).
			local mi, mj = frames[i].mouthC, frames[j].mouthC
			local sep = Vector3.new(mi.X - mj.X, 0, mi.Z - mj.Z).Magnitude
			return sep < (frames[i].hw + frames[j].hw)
		end

		-- Does this corner get a kerb? Either side it joins carries a sidewalk, and it is not
		-- the circulating ring. The fill rim asks too -- it follows the KERB's path wherever
		-- one is built, so the seam between them cannot open.
		local function cornerKerbed(i: number, j: number): boolean
			if not swOn then return false end
			if list[i].ring and list[j].ring then return false end
			return list[i].swRight or list[j].swLeft
		end

		-- The Y gore (see isGore): the corner between i and j, the third arm being the stem.
		local function goreCorner(i: number, j: number): boolean
			if n ~= 3 then return false end
			-- A roundabout entry is not a Y: its two ring arms are the circulating carriageway,
			-- and gore paint between them striped straight across the ring.
			if list[i].ring and list[j].ring then return false end
			local k = 6 - i - j
			return isGore(frames[k].dir, frames[i].dir, frames[j].dir, cornerKerbed(i, j))
		end

		-- Smooth interior height field. Each arm extends its real surface inward (via its
		-- sampled height profile when anchored), and points blend those surfaces weighted
		-- by inverse-square distance to each mouth line. On a mouth line the blend
		-- collapses to that arm alone -- height AND slope -- so graded approaches join
		-- without a step, and a road running straight through the junction keeps its true
		-- vertical curve instead of being tented over by a straight-line guess.
		local CHORD_EXT = swWidth + 1.5
		local THROUGH_BOOST = 5
		-- Max rim deviation from the best-fit plane below which the junction renders
		-- as a single fan in that plane instead of warped interior rings. The fit removes
		-- uniform tilt first, so this is true non-planarity (a vertical curve THROUGH the
		-- node), not grade. On flat terrain, arm-height blending leaves sub-stud rim wobble
		-- that is pure float noise; at 0.12 that noise tipped most junctions into the 3-6
		-- ring warped fan (~5x the WedgeParts) for no visible gain. 0.75 keeps a junction
		-- flat until it deviates from its own plane by 3/4 of a stud -- imperceptible on a
		-- flat-shaded city road, with markings and curbs over the seam -- while genuinely
		-- warped junctions (vertical curves of several studs) still get the ringed surface.
		local PLANAR_FIT_EPS = 0.75
		local function armSurfaceY(F: MouthFrame, x: number, z: number): number
			local relLon = (x - F.mouthC.X) * F.dir.X + (z - F.mouthC.Z) * F.dir.Z
			local prof = F.profTop
			if relLon >= 0 or not prof then
				return F.mouthC.Y + F.grade * relLon
			end
			local dist = F.reach + relLon
			if dist <= 0 then
				-- Behind the node: extend with the node-end gradient (clamped to one reach)
				-- so a road running straight through keeps a continuous slope mid-junction.
				local step = F.reach / (#prof - 1)
				return prof[1] + (prof[2] - prof[1]) / math.max(step, 1e-3) * math.max(dist, -F.reach)
			end
			local f = math.min(dist / F.reach, 1) * (#prof - 1)
			local k = math.min(math.floor(f), #prof - 2)
			return prof[k + 1] + (prof[k + 2] - prof[k + 1]) * (f - k)
		end
		local heightAt: (number, number) -> number
		local function blendedHeightAt(x: number, z: number): number
			local wsum, hsum = 0, 0
			for i = 1, n do
				local F = frames[i]
				local px, pz = x - F.mouthC.X, z - F.mouthC.Z
				local lon = px * F.dir.X + pz * F.dir.Z
				local latAbs = math.abs(px * F.side.X + pz * F.side.Z)
				local latOut = latAbs - (F.hw + CHORD_EXT)
				if latOut < 0 then latOut = 0 end
				local dsq = lon * lon + latOut * latOut
				if dsq < 1e-6 then
					return armSurfaceY(F, x, z)
				end
				local d = math.sqrt(dsq)
				local w = 1 / (d + 0.5)
				if F.through then
					-- Inside its own strip a through arm wins outright; the boost fades
					-- over a few studs past the road edge so side-arm throats still blend.
					local tIn = 1 - math.clamp((latAbs - (F.hw + 1)) / 4, 0, 1)
					tIn = tIn * tIn * (3 - 2 * tIn)
					w *= 1 + THROUGH_BOOST * tIn
				end
				wsum += w
				hsum += w * armSurfaceY(F, x, z)
			end
			if wsum < 1e-9 then
				return center.Y + thickness * 0.5
			end
			return hsum / wsum
		end
		-- A flat node ignores the blend entirely: one level height across the interior. The
		-- rim keeps its real mouth heights, so the fan itself forms the throat ramps.
		heightAt = if flatNode
			then function(_x: number, _z: number): number return plateY end
			else blendedHeightAt

		local function mouthPoint(i: number, sign: number, off: number): Vector3
			local F = frames[i]
			return F.mouthC + F.side * (sign * (F.hw + off))
		end

		-- Corner fan between adjacent arms: quadratic in plan, height from the blended
		-- surface, so curbs and edge lines lie on the junction surface instead of cutting
		-- a straight line through it. Endpoints pin to the exact mouth heights.
		-- Analytic corner path: two straight edge runs joined by a quadratic fillet.
		-- Sampled by cornerPts, which drives the fan rim, the kerb and the edge line.
		local function cornerGeom(i: number, j: number, off: number): (Vector3, Vector3, Vector3?, Vector3?, Vector3?, number, number, number)
			local p0 = mouthPoint(i, 1, off)
			local p2 = mouthPoint(j, -1, off)
			local q = meet(p0, frames[i].dir, p2, frames[j].dir)
			-- Two arms meeting at a shallow angle send q (the fan's quadratic control point,
			-- the meet of the two mouth edges) far from the node, spiking a long thin paved
			-- finger. Pull it back onto the reach cap so the corner stays a compact rounded
			-- fillet; the two approach surfaces overlap past it instead of being bridged.
			-- The cap must respect the REAL mouths: fork pushback legitimately anchors them
			-- past reachCap, and dragging q back inside them folds the fillet into a hairpin
			-- spiking through the junction (the curb blob/barb at shallow-crossing gores).
			if q then
				local d0x, d0z = p0.X - center.X, p0.Z - center.Z
				local d2x, d2z = p2.X - center.X, p2.Z - center.Z
				local cap = math.max(reachCap,
					math.sqrt(d0x * d0x + d0z * d0z),
					math.sqrt(d2x * d2x + d2z * d2z))
				local qx, qz = q.X - center.X, q.Z - center.Z
				local qd = math.sqrt(qx * qx + qz * qz)
				if qd > cap then
					local s = cap / qd
					q = Vector3.new(center.X + qx * s, q.Y, center.Z + qz * s)
				end
			end
			-- Fold guard: a valid fillet control point sits on the NODE side of both mouths
			-- (q = p0 - a*dirI = p2 - b*dirJ with a, b >= 0). A sharply curved arm can put
			-- the edge meet on the FAR side, which bulges the fan back across the junction
			-- (the bowtie). Chord straight instead; the approach surfaces cover the gore.
			if q and ((p0 - q):Dot(frames[i].dir) < 0 or (p2 - q):Dot(frames[j].dir) < 0) then
				q = nil
			end
			-- Hug the two arm edges and round ONLY the last `f` studs into the elbow (q).
			-- Ordinary corners sit their mouths at about the fillet distance already, so f
			-- spans the whole corner and this matches the old single quadratic. Mouths pushed
			-- far past the elbow (shallow-fork pushback, shared reaches) used to sag one huge
			-- quadratic across the corner -- a fat diagonal that read as extra road surface.
			local qa: Vector3?, qb: Vector3? = nil, nil
			local straightA, straightB, filletLen = 0, 0, 0
			if q then
				local lenA = (p0 - q).Magnitude
				local lenB = (p2 - q).Magnitude
				-- Round each leg by as much as THAT leg allows. Forcing both to the shorter one
				-- made a corner whose two arms are trimmed at very different reaches (one mouth
				-- pushed far out by its OTHER corner) round by the short leg alone: a long
				-- straight, a stub of a fillet, then the second straight -- the sharp kerb elbow.
				-- A quadratic is tangent to both legs whatever the two lengths are, so the
				-- asymmetric fillet still meets each straight run without a kink.
				local maxF = if goreCorner(i, j) then GORE_NOSE_RADIUS * 2
					else effectiveCornerRadius(pairCornerRadius(frames[i].corner, frames[j].corner)) * 2
				local fA = math.min(maxF, lenA)
				local fB = math.min(maxF, lenB)
				qa = q + (p0 - q) * (if lenA > 1e-4 then fA / lenA else 0)
				qb = q + (p2 - q) * (if lenB > 1e-4 then fB / lenB else 0)
				straightA = lenA - fA
				straightB = lenB - fB
				filletLen = fA + fB
			end
			return p0, p2, q, qa, qb, straightA, straightB, filletLen
		end

		local function cornerPts(i: number, j: number, off: number, minSteps: number?, maxSteps: number?): { Vector3 }
			local p0, p2, q, qa, qb, straightA, straightB, filletLen = cornerGeom(i, j, off)
			-- Corner-arc tessellation. Drives the surface fan loop and the curbs. 2.5-stud
			-- chords; minSteps still forces extra density on sharp curb turns.
			-- NOTE: the kerb is recomputed here at its OWN offset rather than being a lateral
			-- offset of the fill rim. That was tried and reverted: the corner fillet is concave
			-- on the outward side, so offsetting outward by the kerb half-width cuts inside its
			-- radius of curvature and cusps -- the kerb folds into a dart spiking across the
			-- junction (measured: 0 self-intersections this way, 6-7 when offset). See
			-- ROAD_OVERHAUL.md B2a before attempting that again.
			local steps = math.clamp(math.max(math.ceil((p2 - p0).Magnitude / 3.5), minSteps or 0), 4, maxSteps or 16)
			local pts = table.create(steps + 1)
			local total = straightA + filletLen + straightB
			for s = 0, steps do
				local u = s / steps
				local xz: Vector3
				if q and qa and qb and total > 1e-4 then
					local d = u * total
					if d <= straightA and straightA > 1e-4 then
						xz = p0:Lerp(qa, d / straightA)
					elseif d >= straightA + filletLen and straightB > 1e-4 then
						xz = qb:Lerp(p2, (d - straightA - filletLen) / straightB)
					else
						local v = math.clamp((d - straightA) / math.max(filletLen, 1e-4), 0, 1)
						local m = 1 - v
						xz = qa * (m * m) + q * (2 * m * v) + qb * (v * v)
					end
				else
					xz = p0:Lerp(p2, u)
				end
				-- Height climbs LINEARLY between the two mouth-pinned endpoints instead of sampling
				-- the interior blend field, whose inverse-distance mix of extrapolated arm planes went
				-- non-smooth on strongly graded arms (the folded/warped junction). Linear also matches
				-- the curb's own climb (below), so surface and curb never split at a corner.
				local y = p0.Y + (p2.Y - p0.Y) * u
				if flatNode then
					y += (plateY - y) * plateBlend(u)
				end
				pts[s + 1] = Vector3.new(xz.X, y, xz.Z)
			end
			return pts
		end

		local loop: { Vector3 } = {}
		-- Which rim points are arm MOUTH stations. Those are pinned to the segment's real
		-- surface and must stay there: the planar fit below would otherwise slide them onto
		-- its best-fit plane, up to PLANAR_FIT_EPS (0.75) away -- nearly two slab thicknesses
		-- of step exactly where the junction meets the road.
		local isMouth: { boolean } = {}
		for i = 1, n do
			-- Subdivide the mouth chord so the interior rings can resolve a steep throat
			-- ramp instead of spanning it with two giant triangles.
			local F = frames[i]
			-- A road cross-section is level, so the mouth chord is a straight, level line: any
			-- interior points on it are collinear and add only zero-area sliver fan triangles.
			-- Keep just enough for a warped throat to ring; planar junctions lose nothing.
			local chordSteps = math.max(1, math.ceil(F.hw / 6.0))
			for s = 0, chordSteps do
				loop[#loop + 1] = F.mouthC + F.side * (-F.hw + 2 * F.hw * (s / chordSteps))
				isMouth[#loop] = true
			end
			local jn = (i % n) + 1
			if not isMergePair(i, jn) then
				-- Pave out to the KERB's own path, not to the pavement edge. The two are
				-- separately derived fillets, not parallel curves: they agree at the mouths and
				-- part company mid-corner by sw2/sin(half-angle) -- 0.2 studs at a right angle,
				-- 14 at 20 degrees (measured) -- and widening the sidewalk widened the split.
				-- That split IS the gap between a road and its sidewalk. Running the rim along
				-- the kerb centreline buries the seam under the kerb at ANY sidewalk width.
				-- ponytail: costs sw2 of asphalt under each corner kerb, which nothing can see.
				-- Sampled with the KERB's own step count (below), not the rim default: the same
				-- curve tessellated coarser leaves the kerb bulging a chord-sagitta past the fill.
				local turn = math.pi - math.acos(math.clamp(frames[i].dir:Dot(frames[jn].dir), -1, 1))
				local corner = cornerPts(i, jn, if cornerKerbed(i, jn) then sw2 else 0, math.ceil(math.deg(turn) / 6), 16)
				for k = 2, #corner - 1 do
					loop[#loop + 1] = corner[k]
				end
			end
		end

		local centerTop = Vector3.new(center.X, heightAt(center.X, center.Z), center.Z)

		-- Best-fit plane through the rim. Junctions that are planar within tolerance --
		-- flat ones, and tilted ones whose arms land level (the placement vertical
		-- profile guarantees level landings for new roads) -- render as one fan in
		-- that plane: coplanar wedges shade uniformly, so no facet streaks. Edge
		-- lines and curbs drawn below also follow the plane via heightAt. Genuinely
		-- warped junctions keep the ringed fan.
		-- Never fit a plane through a flat node: the fit's whole job is to recover the tilt the
		-- arms imply, which is exactly what FLAT was asked to remove. Its rim projection would
		-- also undo the ramped corners above.
		local planar = false
		do
			local m0 = #loop
			if m0 >= 3 and not flatNode then
				local cx, cy, cz = 0, 0, 0
				for _, p in loop do
					cx += p.X; cy += p.Y; cz += p.Z
				end
				cx /= m0; cy /= m0; cz /= m0
				local sxx, sxz, szz, sxy, szy = 0, 0, 0, 0, 0
				for _, p in loop do
					local dx, dz, dy = p.X - cx, p.Z - cz, p.Y - cy
					sxx += dx * dx
					sxz += dx * dz
					szz += dz * dz
					sxy += dx * dy
					szy += dz * dy
				end
				local det = sxx * szz - sxz * sxz
				if math.abs(det) > 1e-6 then
					local a = (sxy * szz - szy * sxz) / det
					local b = (szy * sxx - sxy * sxz) / det
					local worst = 0
					for _, p in loop do
						local fit = cy + a * (p.X - cx) + b * (p.Z - cz)
						worst = math.max(worst, math.abs(p.Y - fit))
					end
					if worst <= PLANAR_FIT_EPS then
						planar = true
						heightAt = function(x: number, z: number): number
							return cy + a * (x - cx) + b * (z - cz)
						end
						centerTop = Vector3.new(center.X, heightAt(center.X, center.Z), center.Z)
					end
				end
			end
		end

		-- ONE fan spec IS the junction surface: a centre->rim triangle fan baked directly (top +
		-- bottom + skirt, 4 tris/slice) instead of a per-slice wedge prism (16 tris/slice) or the
		-- old overlapping bounding-BOX fan. Planar junctions project the rim onto the fit plane
		-- first so adjacent facets stay coplanar and float noise can't step them apart; a genuinely
		-- warped junction keeps its raw centre->rim heights.
		local m = #loop
		if planar then
			for k = 1, m do
				if not isMouth[k] then
					loop[k] = Vector3.new(loop[k].X, heightAt(loop[k].X, loop[k].Z), loop[k].Z)
				end
			end
			centerTop = Vector3.new(centerTop.X, heightAt(centerTop.X, centerTop.Z), centerTop.Z)
		end
		surfaceBuilder:addFan(centerTop, loop, thickness, options.surfaceColor)

		-- Height of the FINISHED fan at (x, z): the centre->rim triangle the point falls in.
		-- The corner paint sits an edge-line offset INSIDE the rim, and on a junction that is
		-- not flat the fan climbs from the rim toward the centre by more than the z-fight lift
		-- -- so the fill swallowed the line. Neither the rim's own height nor the interior
		-- blend predicts that climb (a triangle spanning a mouth chord sits higher than both),
		-- so sample the surface that actually got built.
		local function fanSurfaceY(x: number, z: number): number
			local rimN = #loop
			local px, pz = x - centerTop.X, z - centerTop.Z
			for k = 1, rimN do
				local A = loop[k]
				local B = loop[(k % rimN) + 1]
				local ax, az = A.X - centerTop.X, A.Z - centerTop.Z
				local bx, bz = B.X - centerTop.X, B.Z - centerTop.Z
				local det = ax * bz - az * bx
				if math.abs(det) > 1e-9 then
					local u = (px * bz - pz * bx) / det
					local v = (ax * pz - az * px) / det
					if u >= -1e-6 and v >= -1e-6 and u + v <= 1 + 1e-6 then
						return centerTop.Y + u * (A.Y - centerTop.Y) + v * (B.Y - centerTop.Y)
					end
				end
			end
			return heightAt(x, z)
		end

		for i = 1, n do
			local j = (i % n) + 1
			if isMergePair(i, j) then continue end
			-- No curb or edge line across the circulating ring: a roundabout entry's two ring
			-- arms are one continuous carriageway, so a fillet chord between them would cut a
			-- raised notch across the island side. The surface fan still fills the gore.
			if list[i].ring and list[j].ring then continue end
			-- ONE sampled corner path drives BOTH the kerb and the edge line, so the paint can
			-- never drift off the kerb face: the kerb lofts around it, the line is inset from it.
			-- ponytail: ~6 deg/facet, cap 16. A 90-degree corner kerb at 15 facets still reads
			-- round from the city camera.
			local turn = math.pi - math.acos(math.clamp(frames[i].dir:Dot(frames[j].dir), -1, 1))
			local cpts = cornerPts(i, j, sw2, math.ceil(math.deg(turn) / 6), 16)
			-- Straighten the curb's vertical path to a linear climb between its two mouth
			-- heights. cornerPts takes interior Y from heightAt sampled sw2 studs OUTSIDE
			-- the pavement, where the blended height field is poorly constrained and steps
			-- sharply between adjacent points on a graded (warped) junction. curbRun folds
			-- those Y jumps into upright fins -- the "sidewalk sticking out" at sloped
			-- intersections. The curb is thin trim, so a straight climb hugs the surface
			-- closely and never spikes; the endpoints already sit on the arm mouths.
			local last = #cpts
			if last >= 2 then
				local y0, y1 = cpts[1].Y, cpts[last].Y
				for k = 1, last do
					local u = (k - 1) / (last - 1)
					local y = y0 + (y1 - y0) * u
					-- Same pull the fill rim took (cornerPts): the two endpoints are the arm
					-- mouths in both paths, so re-deriving it here lands on the same curve.
					if flatNode then
						y += (plateY - y) * plateBlend(u)
					end
					cpts[k] = Vector3.new(cpts[k].X, y, cpts[k].Z)
				end
			end
			if markColor ~= nil then
				-- Paint centre one edge-line offset inside the kerb face -- the same place
				-- RoadRenderer puts the segment's edge line, so the two meet at the mouth.
				local paint = insetPath(cpts, sw2 + edgeOff)
				for k = 1, #paint do
					local p = paint[k]
					paint[k] = Vector3.new(p.X, fanSurfaceY(p.X, p.Z) + LINE_LIFT.Y, p.Z)
				end
				surfaceBuilder:addMarkingLine(paint, edgeW, markColorFb, false)
			end
			-- Per-corner, not per-node: kerb this corner if EITHER of the two sides it joins
			-- has a sidewalk. Against a sidewalk-less arm the run just ends at its mouth.
			if cornerKerbed(i, j) then
				curbRun(cpts)
			end
		end

		-- Y gore paint: the stem's dividing line splits at its mouth and runs out to each
		-- branch's inner edge, so the widening wedge between the branches reads as a painted
		-- gore leading to the nose instead of bare asphalt.
		for i = 1, n do
			local j = i % n + 1
			if goreCorner(i, j) then
				local stemC = frames[6 - i - j].mouthC
				for _, tip in { mouthPoint(i, 1, -edgeOff), mouthPoint(j, -1, -edgeOff) } do
					local pts = table.create(9)
					for q = 0, 8 do
						local p = stemC:Lerp(tip, q / 8)
						pts[q + 1] = Vector3.new(p.X, fanSurfaceY(p.X, p.Z) + LINE_LIFT.Y, p.Z)
					end
					surfaceBuilder:addMarkingLine(pts, edgeW, markColorFb, false)
				end
			end
		end
	end

	-- ponytail: ONE bake -> ONE MeshPart. Default fidelity + CanQuery so NPC connectors raycast
	-- the real (possibly graded) junction surface, not a bounding box (verified).
	local junctionMesh = surfaceBuilder:bake({
		name = "Junction",
		anchored = anchored,
		canCollide = canCollide,
		canQuery = canCollide,
		collisionFidelity = Enum.CollisionFidelity.Default,
	})
	if junctionMesh then junctionMesh.Parent = model end

	model.Parent = parent
	return model
end

return IntersectionRenderer
