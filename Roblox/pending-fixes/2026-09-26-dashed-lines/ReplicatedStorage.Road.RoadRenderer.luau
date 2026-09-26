--!strict

local RoadConstants = require(script.Parent.RoadConstants)
local BezierUtil = require(script.Parent.BezierUtil)
local RoadMeshBuilder = require(script.Parent.RoadMeshBuilder)

local RoadRenderer = {}

local UP = Vector3.yAxis
local FACET_ANGLE = math.rad(1)

export type RenderOptions = {
	color: Color3,
	transparency: number?,
	anchored: boolean?,
	canCollide: boolean?,
	width: number?,
	carriagewayWidth: number?,
	laneCount: number?,
	widthStart: number?,
	widthEnd: number?,
	widthTransitionLength: number?,
	widthStartHold: number?,
	widthEndHold: number?,
	surfaceStartOffset: number?,
	surfaceEndOffset: number?,

	centerOffsetStart: number?,
	centerOffsetMid: number?,
	centerOffsetEnd: number?,
	centerLineColor: Color3?,
	centerLineWidth: number?,
	centerLineDashed: boolean?,
	centerLineDouble: boolean?,
	edgeLineColor: Color3?,
	-- Optional LEFT-edge colour. US practice paints the two edges of a carriageway
	-- differently: white on the right, yellow on the left of a one-way or divided
	-- roadway (MUTCD 11th Ed. §3A.03). nil = both edges use edgeLineColor, which is
	-- correct for an ordinary two-way street where both edges are right-hand edges.
	edgeLineColorLeft: Color3?,
	-- false = no edge line on that side (+ = right). A roundabout ring's inner line is painted
	-- by the roundabout centre as one unbroken circle instead.
	edgeLinePlus: boolean?,
	edgeLineMinus: boolean?,
	edgeLineWidth: number?,

	taperSide: number?,
	laneLineColor: Color3?,
	laneLineWidth: number?,
	laneOffsets: { number }?,
	laneLineStartOffset: number?,
	laneLineEndOffset: number?,
	-- Bus lane: solid painted band filling the kerbside lane of each direction. Offsets are
	-- those lane CENTRES about the carriageway centre; busLaneWidth is the lane width.
	busLaneColor: Color3?,
	busLaneOffsets: { number }?,
	busLaneWidth: number?,
	sidewalk: boolean?,
	sidewalkColor: Color3?,
	sidewalkWidth: number?,
	sidewalkHeight: number?,
	groundSkirt: number?,
	markingStartOffset: number?,
	markingEndOffset: number?,
	sidewalkStartOffset: number?,
	sidewalkEndOffset: number?,
	-- Per-kerb minimum trim (right = +side, travel p0->p3). An arm of an OVERLAPPED
	-- shallow fork pushes only its gore-side kerb/edge line back to where the two
	-- carriageways separate, so it stops slicing across the neighbouring arm's pavement.
	sidewalkStartOffsetRight: number?,
	sidewalkStartOffsetLeft: number?,
	sidewalkEndOffsetRight: number?,
	sidewalkEndOffsetLeft: number?,
	crosswalkColor: Color3?,
	crosswalkStartRadius: number?,
	crosswalkEndRadius: number?,
	-- Zebra skew (radians) off square, so the crossing runs parallel to the crossing
	-- road at an angled junction. 0 / nil = perpendicular (the old behaviour).
	stopLineStart: Vector2?,
	stopLineEnd: Vector2?,
	-- Give-way "shark teeth" across the carriageway near an end of the road: a
	-- highway ramp merging into a through carriageway, or an arm entering a
	-- roundabout, yields to it. The optional span (lane offsets about the
	-- carriageway centre) limits the teeth to the approaching lanes so a two-way
	-- arm keeps its exit half clean; nil = full carriageway.
	giveWayEnd: boolean?,
	giveWayEndSpan: Vector2?,
	giveWayStart: boolean?,
	giveWayStartSpan: Vector2?,
	arrowColor: Color3?,
	arrowsStart: { ArrowSpec }?,
	arrowsEnd: { ArrowSpec }?,
	mergeEnd: { MergeSpec }?,

	parkingLane: boolean?,
	parkingLaneWidth: number?,
	parkingSides: number?,
	parkingSide: string?, -- "left" | "right" | "both"
	parkingColor: Color3?,
	parkingApronColor: Color3?,

	median: boolean?,
	medianWidth: number?,
	medianColor: Color3?,
	sidewalkMode: string?, -- "none" | "left" | "right" | "both"; nil = both
	vergeMode: string?,    -- "left" | "both": raised grass strip carved off the carriageway edge(s)
	vergeWidth: number?,
	medianThroughStart: boolean?, -- the narrower road past a width taper carries a median too: run on
	medianThroughEnd: boolean?,
	vergeThroughStart: boolean?,  -- ...or a verge
	vergeThroughEnd: boolean?,

	guardrail: boolean?,
	guardrailWidth: number?,
	guardrailHeight: number?,
	guardrailColor: Color3?,
	guardrailMaterial: Enum.Material?,
	maxSamples: number?,
	speedLimit: number?,
	speedNumberStart: boolean?,
	speedNumberEnd: boolean?,
	oneWay: boolean?,
	-- Railway track: draw steel rails on the ballast slab (all other marking options nil).
	isRail: boolean?,
}

export type ArrowSpec = {
	offset: number,
	left: boolean,
	through: boolean,
	right: boolean,
}

export type MergeSpec = {
	offset: number,
	left: boolean,
}

type SurfaceFacet = {
	part: Part,
	d0: number,
	d1: number,
}

local function adaptiveSamples(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, maxSamplesOverride: number?): number
	local max = maxSamplesOverride or RoadConstants.MAX_SURFACE_SAMPLES
	local PROBE = 8
	local totalAngle = 0
	local prevDir: Vector3? = nil
	for i = 0, PROBE do
		local tan = BezierUtil.tangent(p0, p1, p2, p3, i / PROBE)
		if tan.Magnitude > 1e-6 then
			local dir = tan.Unit
			if prevDir then
				totalAngle += math.acos(math.clamp(prevDir:Dot(dir), -1, 1))
			end
			prevDir = dir
		end
	end
	local byAngle = math.ceil(totalAngle / FACET_ANGLE)
	return math.clamp(math.max(byAngle, 1), 1, max)
end

function RoadRenderer.build(
	p0: Vector3,
	p1: Vector3,
	p2: Vector3,
	p3: Vector3,
	parent: Instance,
	options: RenderOptions
): Model
	local model = Instance.new("Model")
	model.Name = "RoadSegment"
	-- Surface, kerbs, median, guardrail AND markings all feed this single builder and bake
	-- to server Parts (collision + queries). The client then merges the whole piece into ONE
	-- vertex-coloured MeshPart (RoadMeshVisualsController), so markings read as paint on it.
	local meshBuilder = RoadMeshBuilder.new()

	local halfWidth = (options.width or RoadConstants.ROAD_WIDTH) * 0.5
	local thickness = RoadConstants.ROAD_THICKNESS
	local markingThickness = 0.05
	local transparency = options.transparency or 0
	local anchored = if options.anchored == nil then true else options.anchored
	local canCollide = if options.canCollide == nil then true else options.canCollide
	local activeMarkingKey: string? = nil
	local surfaceFacets: { SurfaceFacet } = {}

	-- Carriageway = driving surface; apron = the dedicated parking lane carved off each
	-- active side. Surface + sidewalk span the FULL width (unchanged); lane/edge markings
	-- and the apron fill key off the carriageway so the edge "kerb" lines land at the
	-- carriageway boundary and the apron renders outside them.
	local apronPlus = 0   -- +side (right) sideband width: parking apron + verge
	local apronMinus = 0  -- -side (left) sideband width
	-- A planted verge (median left/both) carves the carriageway exactly like a parking apron,
	-- but renders as a raised grass strip instead of flat asphalt. The two STACK: the verge is
	-- the outermost band, against the kerb, and the parking apron sits inside it.
	local vergePlus = 0
	local vergeMinus = 0
	if options.parkingLane then
		local plW = options.parkingLaneWidth or 0
		local side = options.parkingSide or "both"
		if side == "left" then
			apronMinus = plW          -- -side = left
		elseif side == "right" then
			apronPlus = plW           -- +side = right
		else
			apronPlus, apronMinus = plW, plW
		end
	end
	if options.vergeMode then
		local vW = options.vergeWidth or 4
		vergeMinus = vW                                  -- "left" = -side
		vergePlus = if options.vergeMode == "both" then vW else 0
		apronMinus += vergeMinus
		apronPlus += vergePlus
	end
	local apronIsGrass = vergePlus > 0 or vergeMinus > 0
	local carriagewayHalf = (options.carriagewayWidth or options.width or RoadConstants.ROAD_WIDTH) * 0.5
	-- Carriageway centre shift from the road centre (non-zero only for a single-sided apron).
	local cwCenterOffset = (apronMinus - apronPlus) * 0.5

	local maxS = options.maxSamples or RoadConstants.MAX_SURFACE_SAMPLES
	local samples: number
	do
		-- Facets only need to be small where the surface bends. The angle term keeps its
		-- old cap, so flat (level) geometry -- straights and plan curves -- renders exactly
		-- as before. The extra budget is spent ONLY on runs with vertical relief (and width
		-- tapers): there we floor the facet LENGTH, because grade creasing catches grazing
		-- light and adaptiveSamples spreads facets uniformly in t, under-resolving crests.
		local byAngle = adaptiveSamples(p0, p1, p2, p3, RoadConstants.SAMPLES_PER_SEGMENT)
		local relief = math.max(
			math.abs(p1.Y - p0.Y),
			math.abs(p2.Y - p0.Y),
			math.abs(p3.Y - p0.Y)
		)
		local needLength = options.widthStart ~= nil or options.widthEnd ~= nil
			or relief > RoadConstants.SURFACE_GRADE_RELIEF
		if needLength then
			local approxLen = BezierUtil.length(p0, p1, p2, p3, 12)
			local byLength = math.ceil(approxLen / RoadConstants.SURFACE_FACET_LENGTH)
			samples = math.clamp(math.max(byAngle, byLength), 1, maxS)
		else
			samples = math.clamp(byAngle, 1, maxS)
		end
	end

	-- The sidewalk, parking apron, median and guardrail are swept as their OWN box runs
	-- (each step = one Part), independent of the road surface. They are chunky or thin
	-- trim, not the driving surface, so they don't need the surface's facet rate -- half
	-- as many facets (~2 stud chords on a curve) reads identically from the city-builder
	-- camera and roughly halves the part count these features add on every curved road.
	local trimSamples = math.max(1, math.ceil(samples * 0.5))

	local centers = table.create(samples + 1)
	local sides = table.create(samples + 1)
	local fwds = table.create(samples + 1)
	local cum = table.create(samples + 1)
	cum[1] = 0
	for i = 0, samples do
		local center = BezierUtil.point(p0, p1, p2, p3, i / samples)
		local tan = BezierUtil.tangent(p0, p1, p2, p3, i / samples)
		if tan.Magnitude < 1e-6 then
			tan = p3 - p0
		end
		local side = tan.Unit:Cross(UP)
		side = if side.Magnitude < 1e-6 then Vector3.xAxis else side.Unit
		centers[i + 1] = center
		sides[i + 1] = side
		fwds[i + 1] = tan.Unit
		if i > 0 then
			cum[i + 1] = cum[i] + (centers[i + 1] - centers[i]).Magnitude
		end
	end
	local totalLen = cum[samples + 1]
	-- Degenerate / zero-length input (coincident control points, e.g. a click with no
	-- drag, or a collapsed connector) makes every per-feature facet count -- which scales
	-- as covered-fraction / totalLen -- divide by ~0 and spray hundreds of zero-area
	-- parts. There is nothing to draw on a point, so bail with an empty model.
	if totalLen < 0.25 then
		model.Parent = parent
		return model
	end
	local startHalfWidth = (options.widthStart or options.width or RoadConstants.ROAD_WIDTH) * 0.5
	local endHalfWidth = (options.widthEnd or options.width or RoadConstants.ROAD_WIDTH) * 0.5
	local transitionLen = math.max(0.001, options.widthTransitionLength or RoadConstants.ROAD_WIDTH_TRANSITION_LENGTH or 32)

	local function smoothstep(t: number): number
		t = math.clamp(t, 0, 1)
		return t * t * (3 - 2 * t)
	end

	local taperSide = options.taperSide or 0

	local startHold = math.max(0, options.widthStartHold or 0)
	local endHold = math.max(0, options.widthEndHold or 0)

	local function halfWidthAtDistance(dist: number): number
		if totalLen <= 1e-3 then
			return halfWidth
		end
		local startFlareEnd = startHold + transitionLen
		local endFlareStart = totalLen - endHold - transitionLen
		if startFlareEnd > endFlareStart then

			return startHalfWidth + (endHalfWidth - startHalfWidth) * smoothstep(dist / totalLen)
		end
		if dist <= startHold then
			return startHalfWidth
		end
		if dist < startFlareEnd then
			return startHalfWidth + (halfWidth - startHalfWidth) * smoothstep((dist - startHold) / transitionLen)
		end
		if dist >= totalLen - endHold then
			return endHalfWidth
		end
		if dist > endFlareStart then
			return halfWidth + (endHalfWidth - halfWidth) * smoothstep((dist - endFlareStart) / transitionLen)
		end
		return halfWidth
	end

	local function sideHalfWidths(dist: number): (number, number)
		local hw = halfWidthAtDistance(dist)
		if taperSide == 0 then
			return hw, hw
		end

		local delta = hw - halfWidth
		if taperSide > 0 then

			return halfWidth, halfWidth + delta * 2
		else

			return halfWidth + delta * 2, halfWidth
		end
	end

	local function distanceAtT(t: number): number
		if t <= 0 then return 0 end
		if t >= 1 then return totalLen end
		local scaled = t * samples
		local i = math.floor(scaled)
		local f = scaled - i
		return cum[i + 1] + (cum[i + 2] - cum[i + 1]) * f
	end

	local function halfWidthAtT(t: number): number
		return halfWidthAtDistance(distanceAtT(t))
	end

	local centerOffsetStart = options.centerOffsetStart or 0
	local centerOffsetMid = options.centerOffsetMid or 0
	local centerOffsetEnd = options.centerOffsetEnd or 0
	local hasCenterOffset = centerOffsetStart ~= 0 or centerOffsetMid ~= 0 or centerOffsetEnd ~= 0
	local function centerOffsetAtDistance(dist: number): number
		if not hasCenterOffset then return 0 end
		if totalLen <= 1e-3 then return centerOffsetMid end
		if totalLen <= transitionLen * 2 then
			return centerOffsetStart + (centerOffsetEnd - centerOffsetStart) * smoothstep(dist / totalLen)
		end
		if dist < transitionLen then
			return centerOffsetStart + (centerOffsetMid - centerOffsetStart) * smoothstep(dist / transitionLen)
		end
		if dist > totalLen - transitionLen then
			return centerOffsetMid + (centerOffsetEnd - centerOffsetMid) * smoothstep((dist - (totalLen - transitionLen)) / transitionLen)
		end
		return centerOffsetMid
	end

	-- ponytail: was 2 WedgeParts; now feeds the segment mesh as a solid down-extruded prism
	-- (top face = the triangle). `collide` is moot -- the whole mesh shares one CanCollide.
	local function drawTriangleThick(a: Vector3, b: Vector3, c: Vector3, color: Color3, _collide: boolean, triThickness: number)
		meshBuilder:addPrismTri(a, b, c, color, triThickness)
	end

	local function drawTriangle(a: Vector3, b: Vector3, c: Vector3, color: Color3, collide: boolean)
		drawTriangleThick(a, b, c, color, collide, thickness)
	end

	local function drawMarkingTriangle(a: Vector3, b: Vector3, c: Vector3, color: Color3)
		drawTriangleThick(a, b, c, color, false, markingThickness)
	end

	-- A planar, rectangular facet -- the common case: a flat or evenly-graded constant-width
	-- road, and every thin marking strip -- renders as ONE box Part instead of two triangles
	-- (= four WedgeParts). The four corners sit on the slab TOP and the box hangs down by
	-- `thk`, exactly like the wedge prisms, so the finished surface, curbs and markings line
	-- up to the stud. If the quad is twisted (turning while grading) or tapered (a width
	-- transition makes it a trapezoid) the box reconstruction misses by > QUAD_EPS and we fall
	-- back to the original two-triangle path, so the output is never worse than before.
	-- ponytail: 0.15 (was 0.03) -- a gently twisted facet bakes as ONE box with corners off
	-- by at most this many studs, instead of falling back to 4 WedgeParts. Invisible at
	-- city-camera range; graded curves were paying 4x parts for sub-0.15 fidelity.
	local QUAD_EPS = 0.15
	local function drawQuad(l0: Vector3, r0: Vector3, l1: Vector3, r1: Vector3, color: Color3, collide: boolean, thk: number): Part?
		local m0 = (l0 + r0) * 0.5
		local m1 = (l1 + r1) * 0.5
		local chord = m1 - m0
		local chordLen = chord.Magnitude
		local sideRaw = (r0 - l0) + (r1 - l1)
		if chordLen > 1e-4 and sideRaw.Magnitude > 1e-4 then
			local fwdDir = chord / chordLen
			local rightDir = sideRaw - fwdDir * sideRaw:Dot(fwdDir)
			if rightDir.Magnitude > 1e-4 then
				rightDir = rightDir.Unit
				local upDir = rightDir:Cross(fwdDir)
				if upDir.Magnitude > 1e-4 then
					upDir = upDir.Unit
					if upDir:Dot(UP) < 0 then upDir = -upDir; rightDir = -rightDir end
					local width = ((r0 - l0).Magnitude + (r1 - l1).Magnitude) * 0.5
					local top = (m0 + m1) * 0.5
					local hw = rightDir * (width * 0.5)
					local hl = fwdDir * (chordLen * 0.5)
					if (top - hw - hl - l0).Magnitude <= QUAD_EPS
						and (top + hw - hl - r0).Magnitude <= QUAD_EPS
						and (top - hw + hl - l1).Magnitude <= QUAD_EPS
						and (top + hw + hl - r1).Magnitude <= QUAD_EPS then
						meshBuilder:addBox(
							CFrame.fromMatrix(top - upDir * (thk * 0.5), rightDir, upDir),
							Vector3.new(width, thk, chordLen),
							color
						)
						return nil
					end
					-- Planar HORIZONTAL trapezoid -- the flat plan-curve facet: every corner's
					-- deviation from the rectangle lies ALONG the chord (outer edge longer,
					-- inner shorter), so ONE box padded to the longest edge covers the facet and
					-- neighbours overlap on the short side. Tops are horizontal and share one Y,
					-- so the overlap is exactly coplanar -- invisible. 1 Part instead of the
					-- 4-WedgePart triangle fallback these facets paid before. Graded/twisted
					-- facets (tops not horizontal) still fall through to the triangles.
					if upDir:Dot(UP) > 0.9995 then
						local pad = 0
						local trapezoid = true
						for _, dv in { l0 - (top - hw - hl), r0 - (top + hw - hl), l1 - (top - hw + hl), r1 - (top + hw + hl) } do
							local lon = dv:Dot(fwdDir)
							if (dv - fwdDir * lon).Magnitude > 0.06 then
								trapezoid = false
								break
							end
							pad = math.max(pad, math.abs(lon))
						end
						if trapezoid and pad <= 1.5 then
							meshBuilder:addBox(
								CFrame.fromMatrix(top - upDir * (thk * 0.5), rightDir, upDir),
								Vector3.new(width, thk, chordLen + pad * 2),
								color
							)
							return nil
						end
					end
				end
			end
		end
		drawTriangleThick(r0, l0, r1, color, collide, thk)
		drawTriangleThick(l0, l1, r1, color, collide, thk)
		return nil
	end

	local function frameAtDistance(d: number): (Vector3, Vector3, Vector3)
		if d <= 0 then
			local tan = BezierUtil.tangent(p0, p1, p2, p3, 0)
			local fwd = if tan.Magnitude > 1e-6 then tan.Unit else (centers[2] - centers[1]).Unit
			return centers[1] + fwd * d, sides[1], fwd
		end
		if d >= totalLen then
			local tan = BezierUtil.tangent(p0, p1, p2, p3, 1)
			local fwd = if tan.Magnitude > 1e-6 then tan.Unit else (centers[samples + 1] - centers[samples]).Unit
			return centers[samples + 1] + fwd * (d - totalLen), sides[samples + 1], fwd
		end
		local lo, hi = 1, samples
		while lo < hi do
			local mid = math.floor((lo + hi) / 2)
			if cum[mid + 1] < d then lo = mid + 1 else hi = mid end
		end
		local span = cum[lo + 1] - cum[lo]
		local f = if span > 1e-6 then (d - cum[lo]) / span else 0
		local c = centers[lo]:Lerp(centers[lo + 1], f)
		local s = sides[lo]:Lerp(sides[lo + 1], f)
		s = if s.Magnitude > 1e-6 then s.Unit else sides[lo]
		local fw = fwds[lo]:Lerp(fwds[lo + 1], f)
		fw = if fw.Magnitude > 1e-6 then fw.Unit else fwds[lo]
		return c, s, fw
	end

	local function ribbon(yOffset: number, color: Color3, collide: boolean)
		-- Trim the road surface back from each end so corner fillets and junctions
		-- own the node area. A tiny overlap keeps curved endpoint frames from exposing
		-- a dark slice at dead-ends or between near-aligned segments.
		local joinOverlap = 0.35
		local startOffset = options.surfaceStartOffset or 0
		local endOffset = options.surfaceEndOffset or 0
		local dStart = startOffset > 0 and math.max(0, startOffset - joinOverlap) or -joinOverlap
		local dEnd = totalLen - (endOffset > 0 and math.max(0, endOffset - joinOverlap) or -joinOverlap)
		if dEnd - dStart <= 1e-3 then return end
		local n = math.max(1, math.ceil((dEnd - dStart) / math.max(totalLen, 1e-3) * samples))
		local left = table.create(n + 1)
		local right = table.create(n + 1)
		local ds = table.create(n + 1)
		for i = 0, n do
			local d = dStart + (dEnd - dStart) * (i / n)
			local c, s, fwd = frameAtDistance(d)
			local roadUp = s:Cross(fwd)
			roadUp = if roadUp.Magnitude > 1e-6 then roadUp.Unit else UP
			c = c + roadUp * yOffset + s * centerOffsetAtDistance(d)
			local leftHW, rightHW = sideHalfWidths(d)
			left[i + 1]  = c - s * leftHW
			right[i + 1] = c + s * rightHW
			ds[i + 1] = d
		end
		for i = 1, n do
			local l0, r0, l1, r1 = left[i], right[i], left[i + 1], right[i + 1]
			-- A quad on a turning, climbing run is twisted (non-planar): its two
			-- triangles tilt apart and the diagonal crease reads as a dark fan band.
			-- When the twist is visible, split around a point on the TRUE surface
			-- instead, which halves the crease and removes the diagonal bias. Flat
			-- and gently-curved roads keep the cheap 2-triangle quad.
			local nrm = (l0 - r0):Cross(r1 - r0)
			local twist = if nrm.Magnitude > 1e-6 then math.abs((l1 - r0):Dot(nrm.Unit)) else 0
			if twist > 0.04 then
				-- Twisted facet: the run turns while it climbs, so the full-width quad is
				-- non-planar. A road cross-section is a straight line, so lerping ACROSS the
				-- width is exact -- split the facet into narrow lateral strips and let drawQuad
				-- render each. A narrow strip is far less non-planar than the full quad, so most
				-- resolve to a single uniform-shaded box. The old path fanned 4 flat-shaded
				-- triangles from a centre point; those internal edges aligned across facets into
				-- the radial "sunburst" streaks on graded curves. Strip count scales with the
				-- twist; drawQuad falls back to 2 triangles for any strip still too warped.
				-- Strip count scales with the twist: the steeper-and-sharper the facet, the more
				-- strips it needs to keep each one near-planar (so its 2 triangles barely crease).
				-- Only twisted facets pay this; straight/flat/plan-curve roads keep the single
				-- drawQuad box. ponytail: flat-shaded parts can't smooth without more facets --
				-- true smooth normals would need EditableMesh, which is banned in this project.
				local lat = math.clamp(2 + math.floor(twist / 0.06), 2, 6)
				for k = 1, lat do
					local f0, f1 = (k - 1) / lat, k / lat
					local a0, b0 = l0:Lerp(r0, f0), l0:Lerp(r0, f1)
					local a1, b1 = l1:Lerp(r1, f0), l1:Lerp(r1, f1)
					local sp = drawQuad(a0, b0, a1, b1, color, collide, thickness)
					if sp then
						table.insert(surfaceFacets, { part = sp, d0 = ds[i], d1 = ds[i + 1] })
					end
				end
			else
				local surfacePart = drawQuad(l0, r0, l1, r1, color, collide, thickness)
				if surfacePart then
					table.insert(surfaceFacets, { part = surfacePart, d0 = ds[i], d1 = ds[i + 1] })
				end
			end
		end
	end

	-- The surface is now ONE smooth swept MeshPart: per-cross-section roadUp normals shade
	-- it continuously, so graded curves no longer show the flat-shaded facet creases the old
	-- part renderer fought with the twist-split machinery. Vertices sit at the slab TOP,
	-- lifted half a thickness, so curbs / junction caps / markings still line up to the stud.
	local function ribbonMesh(yOffset: number, color: Color3)
		local joinOverlap = 0.35
		local startOffset = options.surfaceStartOffset or 0
		local endOffset = options.surfaceEndOffset or 0
		local dStart = startOffset > 0 and math.max(0, startOffset - joinOverlap) or -joinOverlap
		local dEnd = totalLen - (endOffset > 0 and math.max(0, endOffset - joinOverlap) or -joinOverlap)
		if dEnd - dStart <= 1e-3 then return end
		local n = math.max(1, math.ceil((dEnd - dStart) / math.max(totalLen, 1e-3) * samples))
		local left = table.create(n + 1)
		local right = table.create(n + 1)
		for i = 0, n do
			local d = dStart + (dEnd - dStart) * (i / n)
			local c, s, fwd = frameAtDistance(d)
			local roadUp = s:Cross(fwd)
			roadUp = if roadUp.Magnitude > 1e-6 then roadUp.Unit else UP
			c = c + roadUp * yOffset + s * centerOffsetAtDistance(d)
			local leftHW, rightHW = sideHalfWidths(d)
			left[i + 1] = c - s * leftHW
			right[i + 1] = c + s * rightHW
		end
		-- ONE welded swept strip IS the carriageway: shared vertices + per-station roadUp normals
		-- shade the whole surface continuously (smooth on graded curves, no facet creases), and the
		-- collision body extrudes the same strip down by `thickness`. Replaces a per-facet drawQuad
		-- -- a box per flat facet that overlapped and padded itself on plan curves, two triangle
		-- prisms per twisted facet -- so a whole segment is now 2 tris/station instead of 12-16.
		meshBuilder:addSurfaceStrip(left, right, color, thickness)
	end
	ribbonMesh(thickness * 0.5, options.color)

	-- ponytail: markings sit FLUSH -- this names their TOP face, only ~0.025 above the slab,
	-- so the 0.05 band sinks INTO the surface and reads as paint on the road, not a raised
	-- tile floating on top (the old 0.085 left a visible gap + lip).
	-- Markings bake into their OWN MeshPart, so they need SOME separation or they z-fight
	-- the road mesh -- but every stud of lift is parallax at a shallow camera angle. At 0.05
	-- a stripe appeared shifted 0.57 studs when viewed 5 degrees above the road, which reads
	-- as the paint floating off the asphalt. ZFIGHT_OFFSET * 2 is the project's own safe
	-- separation and cuts that to 0.23. Proper alignment needs the paint to BE the road
	-- surface, not a plane over it -- see ROAD_OVERHAUL.md B11.
	local yOff = thickness * 0.5 + RoadConstants.ZFIGHT_OFFSET * 2

	-- A painted road symbol (turn arrow, merge, speed numeral) laid FLAT on the surface as a
	-- transparent carrier Part wearing a Top-face Decal -- the uploaded PNG mask, tinted at
	-- runtime. A Top Decal's image-up axis is local +Z, so facing the plate away from travelDir
	-- points the painted symbol WITH travel. It lives outside the baked mesh (decals need their
	-- own Part), but only a handful exist per segment -- at junction approaches.
	local function markingDecal(centerDist: number, travelDir: Vector3, offset: number, width: number, length: number, texId: string, color: Color3)
		if centerDist <= 0 or centerDist >= totalLen then return end
		local c, side, fwd = frameAtDistance(centerDist)
		local roadUp = side:Cross(fwd)
		roadUp = if roadUp.Magnitude > 1e-6 then roadUp.Unit else UP
		local travel = if travelDir.Magnitude > 1e-6 then travelDir.Unit else fwd
		local pos = c + roadUp * yOff + side * offset - roadUp * (markingThickness * 0.5)
		local plate = Instance.new("Part")
		plate.Name = "RoadMarkingSymbol"
		plate.Anchored = anchored
		plate.CanCollide = false
		plate.CanTouch = false
		plate.CanQuery = false
		plate.CastShadow = false
		plate.Transparency = 1
		plate.Size = Vector3.new(width, markingThickness, length)
		plate.CFrame = CFrame.lookAt(pos, pos - travel, roadUp)
		plate.Parent = model
		local decal = Instance.new("Decal")
		decal.Texture = texId
		decal.Face = Enum.NormalId.Top
		decal.Color3 = color
		decal.Transparency = transparency
		decal.Parent = plate
	end

	local function tAtDistance(dist: number): number
		if dist <= 0 then return 0 end
		if dist >= totalLen then return 1 end
		local lo, hi = 1, samples
		while lo < hi do
			local mid = math.floor((lo + hi) / 2)
			if cum[mid + 1] < dist then lo = mid + 1 else hi = mid end
		end
		local span = cum[lo + 1] - cum[lo]
		local f = if span > 1e-6 then (dist - cum[lo]) / span else 0
		return ((lo - 1) + f) / samples
	end

	local function frameAt(t: number): (Vector3, Vector3, Vector3, Vector3)
		local c = BezierUtil.point(p0, p1, p2, p3, t)
		local tan = BezierUtil.tangent(p0, p1, p2, p3, t)
		if tan.Magnitude < 1e-6 then tan = p3 - p0 end
		local fwd = if tan.Magnitude > 1e-6 then tan.Unit else Vector3.zAxis
		local side = fwd:Cross(UP)
		side = if side.Magnitude < 1e-6 then Vector3.xAxis else side.Unit
		local roadUp = side:Cross(fwd)
		roadUp = if roadUp.Magnitude > 1e-6 then roadUp.Unit else UP
		return c, fwd, side, roadUp
	end

	-- Markings ride the same lerped sample polyline as the slab (frameAtDistance),
	-- not the exact bezier: on vertical curves the slab facets run along chords of
	-- the true curve, and exact-curve markings ended up buried inside them.
	local function markingStrip(t0: number, t1: number, centerOffset: number, halfW: number, color: Color3, offsetAtT: ((number) -> number)?, markingKey: string?)
		if t1 - t0 <= 1e-4 then return end
		local d0, d1 = distanceAtT(t0), distanceAtT(t1)
		if d1 - d0 <= 1e-3 then return end
		local facetStep = totalLen / math.max(samples, 1)
		local n = math.max(1, math.ceil((d1 - d0) / facetStep))
		local leftPts = table.create(n + 1)
		local rightPts = table.create(n + 1)
		for i = 0, n do
			local dist = d0 + (d1 - d0) * (i / n)
			local t = tAtDistance(dist)
			local c, side, fwd = frameAtDistance(dist)
			local roadUp = side:Cross(fwd)
			roadUp = if roadUp.Magnitude > 1e-6 then roadUp.Unit else UP
			local lhw, rhw = sideHalfWidths(dist)

			local scaledOffset: number
			if offsetAtT then
				scaledOffset = offsetAtT(t)

				if taperSide ~= 0 then
					local sign = math.sign(scaledOffset)
					local frac = math.abs(scaledOffset) / halfWidth
					local edgeHW = if sign >= 0 then rhw else lhw
					scaledOffset = sign * frac * edgeHW
				end
			else
				scaledOffset = centerOffset
				if taperSide ~= 0 then
					local sign = math.sign(centerOffset)
					local frac = math.abs(centerOffset) / halfWidth
					local edgeHW = if sign >= 0 then rhw else lhw
					scaledOffset = sign * frac * edgeHW
				end
			end
			local ctr = c + roadUp * yOff + side * (scaledOffset + centerOffsetAtDistance(dist))
			local off = side * halfW
			leftPts[i + 1]  = ctr - off
			rightPts[i + 1] = ctr + off
		end
		local previousKey = activeMarkingKey
		activeMarkingKey = markingKey
		for i = 1, n do
			drawQuad(leftPts[i], rightPts[i], leftPts[i + 1], rightPts[i + 1], color, false, markingThickness)
		end
		activeMarkingKey = previousKey
	end

	-- Centre / lane / edge lines as ONE painted line baked into the piece's mesh: the client
	-- lays a thin UV ribbon along this centreline -- solid = opaque atlas region, dashed =
	-- dash region tiling via UV (no beams, no per-dash geometry, no separate mesh).
	-- A dashed line as WHOLE dashes, laid here rather than gated on the client. The dash
	-- spacing is stretched so a whole number of dashes fits the run, with each end of the
	-- run in the middle of a gap: two runs that meet end to end -- a road split in two, a
	-- bend's connector -- always show one ordinary gap across the join, never a stub of a
	-- dash or a double gap. A run too short to hold one dash gets none.
	local function addWholeDashes(line: { Vector3 }, width: number, color: Color3)
		local cum = table.create(#line, 0)
		for i = 2, #line do
			cum[i] = cum[i - 1] + (line[i] - line[i - 1]).Magnitude
		end
		local runLen = cum[#line]
		local count = math.floor(runLen / (RoadConstants.DASH_LENGTH + RoadConstants.DASH_GAP) + 0.5)
		if count < 1 then return end
		local step = runLen / count
		local dash = math.min(RoadConstants.DASH_LENGTH, step * 0.5)
		local i = 1
		for k = 0, count - 1 do
			local a = k * step + (step - dash) * 0.5
			local b = a + dash
			while i < #line - 1 and cum[i + 1] <= a do i += 1 end
			local piece = { line[i]:Lerp(line[i + 1], (a - cum[i]) / math.max(cum[i + 1] - cum[i], 1e-6)) }
			local j = i
			while j < #line - 1 and cum[j + 1] < b do
				j += 1
				table.insert(piece, line[j])
			end
			table.insert(piece, line[j]:Lerp(line[j + 1], (b - cum[j]) / math.max(cum[j + 1] - cum[j], 1e-6)))
			meshBuilder:addMarkingLine(piece, width, color, false)
		end
	end

	local function surfaceTextureStrip(
		t0: number,
		t1: number,
		centerOffset: number,
		halfW: number,
		color: Color3,
		dashed: boolean,
		offsetAtT: ((number) -> number)?,
		_markingKey: string
	)
		if t1 - t0 <= 1e-4 then return end
		local d0, d1 = distanceAtT(t0), distanceAtT(t1)
		if d1 - d0 <= 1e-3 then return end
		local facetStep = totalLen / math.max(samples, 1)
		local n = math.max(1, math.ceil((d1 - d0) / facetStep))
		local pts = table.create(n + 1)
		for i = 0, n do
			local dist = d0 + (d1 - d0) * (i / n)
			local t = tAtDistance(dist)
			local c, side, fwd = frameAtDistance(dist)
			local roadUp = side:Cross(fwd)
			roadUp = if roadUp.Magnitude > 1e-6 then roadUp.Unit else UP
			local scaledOffset = if offsetAtT then offsetAtT(t) else centerOffset
			if taperSide ~= 0 then
				local sign = math.sign(scaledOffset)
				local frac = math.abs(scaledOffset) / halfWidth
				local lhw, rhw = sideHalfWidths(dist)
				scaledOffset = sign * frac * (if sign >= 0 then rhw else lhw)
			end
			pts[i + 1] = c + roadUp * yOff + side * (scaledOffset + centerOffsetAtDistance(dist))
		end
		if dashed then
			-- Subdivide each slab-chord LINEARLY so the dashes cut from it stay exactly on the
			-- slab facet plane (re-evaluating the curve mid-facet would dip below the chord on
			-- sag bends -- the old buried-markings bug).
			local fine = { pts[1] }
			for i = 2, #pts do
				local a, b = pts[i - 1], pts[i]
				local segs = math.max(1, math.ceil((b - a).Magnitude / 1.5))
				for k = 1, segs do
					table.insert(fine, a + (b - a) * (k / segs))
				end
			end
			addWholeDashes(fine, halfW * 2, color)
			return
		end
		meshBuilder:addMarkingLine(pts, halfW * 2, color, false)
	end

	local mt0 = tAtDistance(options.markingStartOffset or 0)
	local mt1 = tAtDistance(totalLen - (options.markingEndOffset or 0))
	-- Verge and median stop where a width taper begins, not just where the markings stop: the
	-- surface narrows under them (street -> alley), so running on lays grass across the merge.
	-- A strip the narrower road ALSO carries (*Through* options) runs on instead and merges.
	local function stripRange(throughStart: boolean?, throughEnd: boolean?): (number, number)
		local t0 = if options.widthStart and not throughStart then tAtDistance(math.max(options.markingStartOffset or 0, startHold + transitionLen)) else mt0
		local t1 = if options.widthEnd and not throughEnd then tAtDistance(totalLen - math.max(options.markingEndOffset or 0, endHold + transitionLen)) else mt1
		return t0, t1
	end
	local vt0, vt1 = stripRange(options.vergeThroughStart, options.vergeThroughEnd)
	local md0, md1 = stripRange(options.medianThroughStart, options.medianThroughEnd)

	-- Kerb/edge trim ranges PER SIDE (right = +side): a gore-side override can only
	-- extend the base trim, never shorten it.
	local swStartBase = options.sidewalkStartOffset or options.markingStartOffset or 0
	local swEndBase = options.sidewalkEndOffset or options.markingEndOffset or 0
	local stR0 = tAtDistance(math.max(swStartBase, options.sidewalkStartOffsetRight or 0))
	local stR1 = tAtDistance(totalLen - math.max(swEndBase, options.sidewalkEndOffsetRight or 0))
	local stL0 = tAtDistance(math.max(swStartBase, options.sidewalkStartOffsetLeft or 0))
	local stL1 = tAtDistance(totalLen - math.max(swEndBase, options.sidewalkEndOffsetLeft or 0))

	-- Railway: two steel rails per track, tracks on the lane centres (±carriagewayHalf/2).
	-- Solid full-length strips via the same painted-line path the markings use; a rail
	-- spec sets every other marking colour nil so nothing else draws.
	if options.isRail then
		local gaugeHalf = carriagewayHalf * 0.23 -- rail pair spread; proportional so it rides WORLD_SCALE
		local railHalf = carriagewayHalf * 0.033
		local railColor = Color3.fromRGB(150, 150, 154)
		for ti, trackCenter in { -carriagewayHalf * 0.5, carriagewayHalf * 0.5 } do
			for si, side in { -1, 1 } do
				surfaceTextureStrip(mt0, mt1, trackCenter + side * gaugeHalf, railHalf, railColor, false, nil, `rail:{ti}:{si}`)
			end
		end
	end

	if options.centerLineColor then
		local lineWidth = options.centerLineWidth or 0.5
		local clHalf = lineWidth * 0.5
		local offsets = if options.centerLineDouble then { -lineWidth, lineWidth } else { 0 }
		for index, centerBase in offsets do
			local centerOffset = centerBase + cwCenterOffset
			local key = `center:{index}`
			surfaceTextureStrip(mt0, mt1, centerOffset, clHalf, options.centerLineColor, options.centerLineDashed == true, nil, key)
		end
	end

	-- Edge ("kerb") lines sit at the SURFACE edge, against the footway, on every road --
	-- a parking apron is paved carriageway and stays inside the line, not outside it.
	-- Only a grass verge breaks that, and it speaks for itself.
	if options.edgeLineColor and not options.vergeMode then
		local edgeHalf = (options.edgeLineWidth or 0.4) * 0.5
		local inset = edgeHalf + 0.05

		if options.edgeLinePlus ~= false then
			surfaceTextureStrip(stR0, stR1, halfWidth - inset, edgeHalf, options.edgeLineColor, false, function(t)
				local _, rhw = sideHalfWidths(distanceAtT(t))
				return rhw - inset
			end, "edge:plus")
		end

		if options.edgeLineMinus ~= false then
			surfaceTextureStrip(stL0, stL1, -(halfWidth - inset), edgeHalf, options.edgeLineColorLeft or options.edgeLineColor, false, function(t)
				local lhw, _ = sideHalfWidths(distanceAtT(t))
				return -(lhw - inset)
			end, "edge:minus")
		end
	end

	if options.laneLineColor and options.laneOffsets then
		local laneHalf = (options.laneLineWidth or 0.3) * 0.5
		local markStart = options.laneLineStartOffset or options.markingStartOffset or 0
		local markEnd = totalLen - (options.laneLineEndOffset or options.markingEndOffset or 0)
		local laneT0 = tAtDistance(markStart)
		local laneT1 = tAtDistance(markEnd)
		local function laneClamp(off: number): (number) -> number
			return function(t)
				-- Lane lines run straight while widening happens outside them.
				local lhw, rhw = sideHalfWidths(distanceAtT(t))
				local apron = if off >= 0 then apronPlus else apronMinus
				local edgeHW = (if off >= 0 then rhw else lhw) - apron
				local limit = math.max(0, edgeHW - laneHalf - 0.6)
				return math.sign(off) * math.min(math.abs(off), limit)
			end
		end
		for index, offBase in options.laneOffsets do
			local off = offBase + cwCenterOffset
			surfaceTextureStrip(laneT0, laneT1, off, laneHalf, options.laneLineColor, true, laneClamp(off), `lane:{index}`)
		end
	end

	-- Bus lane paint. Inset by a lane-line width each side so the band sits BETWEEN the white
	-- lines instead of coplanar with them (they'd z-fight at the same marking height).
	local busWidth = options.busLaneWidth
	if options.busLaneColor and options.busLaneOffsets and busWidth and busWidth > 0 then
		local bandHalf = math.max(0.5, busWidth * 0.5 - (options.laneLineWidth or 0.5))
		for index, offBase in options.busLaneOffsets do
			surfaceTextureStrip(mt0, mt1, offBase + cwCenterOffset, bandHalf, options.busLaneColor, false, nil, `bus:{index}`)
		end
	end

	if options.sidewalk then
		local swColor = options.sidewalkColor or RoadConstants.SIDEWALK_COLOR
		local swWidth = options.sidewalkWidth or RoadConstants.SIDEWALK_WIDTH
		local swH = options.sidewalkHeight or RoadConstants.SIDEWALK_HEIGHT
		-- Ground roads: kerb boxes keep their TOP but extend down past the slab side and
		-- the terrain clearance gap, so the road edge reads solid into the grass.
		local skirt = options.groundSkirt or 0
		-- Turn radius of the centreline at t, and which side it turns toward (+1 = toward
		-- `side`). Read off the curve rather than differencing sampled points: the sampled
		-- estimate is undefined at a run's first stations, where the kerb decision below
		-- must already be right.
		local function turnRadiusAt(t: number): (number, number)
			local d1 = BezierUtil.tangent(p0, p1, p2, p3, t)
			local d2 = BezierUtil.secondDerivative(p0, p1, p2, p3, t)
			local speedSq = d1.X * d1.X + d1.Z * d1.Z
			local cross = d1.X * d2.Z - d1.Z * d2.X
			if speedSq < 1e-8 or math.abs(cross) < 1e-9 then
				return math.huge, 0
			end
			return speedSq * math.sqrt(speedSq) / math.abs(cross), math.sign(cross)
		end
		-- Trim guard: on a short link the two junction curb setbacks overlap, so t0 lands PAST t1
		-- (inverted range). The rail sweep below would then clamp to one piece spanning t0->t1 --
		-- a sidewalk slab straight across the junction (the "sidewalks clipping through each other"
		-- bug). No valid range = no room for a sidewalk here, so draw none; the corner curbs built
		-- by IntersectionRenderer at each end still meet.
		-- Kerb as a welded LOFT (mesh-era): per roomy run, ONE shared-vertex top strip plus
		-- inner/outer wall strips -- hollow inside, smooth on curves. Replaces the parts-era
		-- overlapping boxes (their coplanar overlaps z-fought inside the baked mesh). The top
		-- strip carries the collision thickness (extruded down through the kerb body); the
		-- walls are render-only. Run ends stay uncapped -- they butt junction corner kerbs.
		local function rail(sign: number, t0: number, t1: number)
			if t1 <= t0 then return end
			local n = math.max(1, math.ceil((t1 - t0) * trimSamples))
			local innerT: { Vector3 } = {}
			local outerT: { Vector3 } = {}
			local innerB: { Vector3 } = {}
			local outerB: { Vector3 } = {}
			local function flush()
				if #innerT >= 2 then
					meshBuilder:addSurfaceStrip(innerT, outerT, swColor, swH + skirt)
					meshBuilder:addSurfaceStrip(innerB, innerT, swColor, 0.05)
					meshBuilder:addSurfaceStrip(outerT, outerB, swColor, 0.05)
				end
				innerT, outerT, innerB, outerB = {}, {}, {}, {}
			end
			for i = 0, n do
				local t = t0 + (t1 - t0) * (i / n)
				local c, _, side, roadUp = frameAt(t)
				c = c + roadUp * (thickness * 0.5) + side * centerOffsetAtDistance(distanceAtT(t))
				local hw = halfWidthAtT(t)
				-- On the INSIDE of a bend the kerb rides an offset curve of radius
				-- (turnRadius - offset) and folds through itself once the offset reaches the
				-- radius. Clamp the outer rail just inside that, so a bend too tight for a
				-- full-width kerb narrows it instead of losing it. The old guard DELETED every
				-- stretch under hw + swWidth + 1, and a 90-degree corner connector sits at
				-- hw + swWidth exactly -- the radius RoadTypeCatalog.minCornerRadius lets
				-- placement build -- so its inner kerb was never built at all.
				local outerOff = hw + swWidth
				local radius, turnSign = turnRadiusAt(t)
				if turnSign * sign > 0 then
					outerOff = math.min(outerOff, math.max(radius - 0.25, hw + 0.05))
				end
				local inn = c + side * (hw * sign)
				local out = c + side * (outerOff * sign)
				table.insert(innerT, inn + roadUp * swH)
				table.insert(outerT, out + roadUp * swH)
				table.insert(innerB, inn - roadUp * skirt)
				table.insert(outerB, out - roadUp * skirt)
			end
			flush()
		end
		local drawRail = rail
		-- Per-side sidewalk: +side is the right kerb, -side the left.
		local swMode = options.sidewalkMode
		if swMode == nil or swMode == "both" then
			drawRail(1, stR0, stR1); drawRail(-1, stL0, stL1)
		elseif swMode == "right" then
			drawRail(1, stR0, stR1)
		elseif swMode == "left" then
			drawRail(-1, stL0, stL1)
		end
	end

	if options.crosswalkColor and (options.crosswalkStartRadius or options.crosswalkEndRadius) then
		local cwColor = options.crosswalkColor
		local stopDepth = RoadConstants.STOP_LINE_DEPTH
		local cwDepth = RoadConstants.CROSSWALK_DEPTH
		local stripeW = RoadConstants.CROSSWALK_STRIPE_WIDTH
		local rimGap = RoadConstants.CROSSWALK_GAP_FROM_STOP
		local usable = halfWidth - RoadConstants.CROSSWALK_EDGE_MARGIN

		-- Stop line / zebra stripe as ONE painted line baked across the road into the piece's
		-- mesh (each zebra stripe is a separate solid call from crossing()). No beams.
		local function paintAcross(dist: number, depth: number, lo: number, hi: number)
			if dist <= 0 or dist >= totalLen then return end
			if hi - lo <= 1e-3 then return end
			local c, side, fwd = frameAtDistance(dist)
			local roadUp = side:Cross(fwd)
			roadUp = if roadUp.Magnitude > 1e-6 then roadUp.Unit else UP
			-- Same height as the lane/edge lines (yOff). The extra +0.12 sat these bands
			-- 0.17 above the slab against everyone else's 0.05, so a crossing read as a
			-- raised tile with lit side faces instead of paint.
			local base = c + roadUp * yOff
			meshBuilder:addMarkingLine({ base + side * lo, base + side * hi }, depth, cwColor, false)
		end

		-- SQUARE across the carriageway, always -- a crossing is the shortest way over the road,
		-- so it is perpendicular to the kerbs no matter how skewed the junction behind it is
		-- (look at any real one). A leaning band was tried and reads as a mistake. What DOES
		-- move with the junction is how far out the band sits: RoadSceneRenderer.crosswalkSeat.
		local function crossing(stopDist: number, zebraDist: number, stopSpan: Vector2?)
			local span = usable
			if stopSpan then
				local lo = math.max(stopSpan.X, -span)
				local hi = math.min(stopSpan.Y, span)
				if hi > lo then
					paintAcross(stopDist, stopDepth, lo, hi)
				end
			end

			if zebraDist > 0 and zebraDist < totalLen and span > 0 then
				-- One SOLID beam per stripe (not one dashed beam): the dash texture mip-blurs
				-- into a grey smear from a distance, while untextured beams stay crisp at any
				-- range. Still zero Parts, and the stripe pitch matches the old geometry.
				local pitch = stripeW + RoadConstants.CROSSWALK_GAP
				local nStripes = math.max(1, math.floor((span * 2) / pitch))
				local startLat = -((nStripes - 1) * pitch) * 0.5
				for k = 0, nStripes - 1 do
					local lat = startLat + k * pitch
					paintAcross(zebraDist, cwDepth, lat - stripeW * 0.5, lat + stripeW * 0.5)
				end
			end
		end

		-- Seat the crossing band so its INNER edge lands on the junction mouth and the whole
		-- zebra sits on this arm's own surface. It used to be CENTRED on the mouth, which put
		-- half the band (CROSSWALK_DEPTH/2) beyond surfaceStartOffset -- the arm's surface is
		-- trimmed at exactly that distance and only overlaps it by ribbon()'s 0.35-stud
		-- joinOverlap -- so the junction fill, a separate mesh, was drawn over the stripes.
		local startR = options.crosswalkStartRadius
		local endR = options.crosswalkEndRadius

		-- Two junction crossings on a short link between adjacent intersections read as a
		-- doubled zebra. When their centres fall within a crossing's depth, collapse them
		-- to one zebra centred in the gap and drop the squeezed stop lines.
		local startZebra = if startR then startR + cwDepth * 0.5 else nil
		local endZebra = if endR then totalLen - (endR + cwDepth * 0.5) else nil
		if startZebra and endZebra and (endZebra - startZebra) < cwDepth + 6 then
			crossing(-1, (startZebra + endZebra) * 0.5, nil)
		else
			local stopOffset = cwDepth * 0.5 + rimGap + stopDepth * 0.5
			if startR then
				crossing(startR + cwDepth * 0.5 + stopOffset, startR + cwDepth * 0.5, options.stopLineStart)
			end
			if endR then
				crossing(totalLen - (endR + cwDepth * 0.5 + stopOffset), totalLen - (endR + cwDepth * 0.5), options.stopLineEnd)
			end
		end
	end

	-- Give-way "shark teeth" across a merge mouth: small triangles, apex pointing back
	-- at the approaching driver, spanning the carriageway just before the junction.
	-- apexSign: -1 for an end-node approach (driver travels +fwd), +1 for a start-node
	-- approach (driver travels -fwd).
	if options.giveWayEnd or options.giveWayStart then
		local cw = options.carriagewayWidth or options.width or RoadConstants.ROAD_WIDTH
		local toothL = RoadConstants.GIVEWAY_TOOTH_LENGTH
		local toothW = RoadConstants.GIVEWAY_TOOTH_WIDTH
		local pitch = toothW + RoadConstants.GIVEWAY_TOOTH_GAP
		local toothColor = options.edgeLineColor or RoadConstants.MARKING_WHITE
		local function teethAt(dist: number, apexSign: number, span: Vector2?)
			local lo = math.max(if span then span.X else -math.huge, -cw * 0.5 + 0.8)
			local hi = math.min(if span then span.Y else math.huge, cw * 0.5 - 0.8)
			if dist <= toothL or dist >= totalLen - toothL or hi - lo <= toothW then return end
			local c, side, fwd = frameAtDistance(dist)
			local roadUp = side:Cross(fwd)
			roadUp = if roadUp.Magnitude > 1e-6 then roadUp.Unit else UP
			local base = c + roadUp * yOff + side * centerOffsetAtDistance(dist)
			local n = math.max(1, math.floor((hi - lo) / pitch))
			local startLat = (lo + hi) * 0.5 - ((n - 1) * pitch) * 0.5
			for k = 0, n - 1 do
				local lat = startLat + k * pitch
				local bl = base + side * (lat - toothW * 0.5)
				local br = base + side * (lat + toothW * 0.5)
				local apex = base + side * lat + fwd * (apexSign * toothL)
				drawTriangleThick(bl, br, apex, toothColor, false, markingThickness)
			end
		end
		if options.giveWayEnd then
			teethAt(totalLen - (options.markingEndOffset or 0) - RoadConstants.GIVEWAY_SETBACK, -1, options.giveWayEndSpan)
		end
		if options.giveWayStart then
			teethAt((options.markingStartOffset or 0) + RoadConstants.GIVEWAY_SETBACK, 1, options.giveWayStartSpan)
		end
	end

	-- Where the approach-arrow rows actually land. The speed numeral below reads this and
	-- keeps clear: arrows own the space, the numeral takes what is left or is not painted.
	local arrowStartDist: number? = nil
	local arrowEndDist: number? = nil
	local arrowHalf = 0

	if options.arrowColor and (options.arrowsStart or options.arrowsEnd or options.mergeEnd) then
		local aColor = options.arrowColor
		local halfLen = RoadConstants.ARROW_LENGTH * 0.5

		-- Approach arrows sit a little back from the junction, with a DYNAMIC setback: on a short
		-- link the two opposing rows meet near the middle, each in its OWN lane (so they don't
		-- actually collide). Drop them only when the link is too short to fit even one arrow.
		local arrowsStart = options.arrowsStart
		local arrowsEnd = options.arrowsEnd
		local aSReach = options.markingStartOffset or 0
		local aEReach = totalLen - (options.markingEndOffset or 0)
		local arrowBack = math.clamp(RoadConstants.ARROW_GAP + halfLen + 4, halfLen, math.max(halfLen, (aEReach - aSReach) * 0.5))

		-- Lane arrows / merges as their uploaded PNG masks, tinted at runtime -- one flat decal
		-- plate per movement, sized to the lane. (Previously crude in-mesh geometry chevrons.)
		local cw = options.carriagewayWidth or options.width or RoadConstants.ROAD_WIDTH
		local laneCount = math.max(1, options.laneCount or 2)
		local arrowSize = math.clamp(cw / laneCount * 0.8, 6, 11)

		-- Squeeze, don't drop. An approach with less roadway than the full setback wants still
		-- gets its arrow, pushed as far back from the junction as the piece allows -- a short
		-- dead-end stub has no neighbour to hand the row to (RoadSceneRenderer relays where it
		-- can), and a bare approach reads as a bug. Only a piece shorter than the arrow itself
		-- has nowhere to put one.
		local drawLo = arrowSize * 0.5 + 0.1
		local drawHi = totalLen - arrowSize * 0.5 - 0.1
		local arrowStartBase, arrowEndBase = 0, 0
		if drawHi <= drawLo then
			arrowsStart = nil
			arrowsEnd = nil
		else
			arrowStartBase = math.clamp(aSReach + arrowBack, drawLo, drawHi)
			arrowEndBase = math.clamp(aEReach - arrowBack, drawLo, drawHi)
			arrowHalf = arrowSize * 0.5
			if arrowsStart then arrowStartDist = arrowStartBase end
			if arrowsEnd or options.mergeEnd then arrowEndDist = arrowEndBase end
		end

		local function arrowTexture(spec: any): string
			if spec.merge then
				return if spec.merge == "left" then RoadConstants.ARROW_TEXTURE_MERGE_LEFT else RoadConstants.ARROW_TEXTURE_MERGE_RIGHT
			end
			local l, t, r = spec.left, spec.through, spec.right
			if l and t and r then return RoadConstants.ARROW_TEXTURE_ALL end
			if l and t then return RoadConstants.ARROW_TEXTURE_LEFT_THROUGH end
			if t and r then return RoadConstants.ARROW_TEXTURE_THROUGH_RIGHT end
			if l and r then return RoadConstants.ARROW_TEXTURE_LEFT_RIGHT end
			if l then return RoadConstants.ARROW_TEXTURE_LEFT end
			if r then return RoadConstants.ARROW_TEXTURE_RIGHT end
			return RoadConstants.ARROW_TEXTURE_THROUGH
		end

		local function drawArrow(centerDist: number, travelSign: number, offset: number, spec: any)
			if centerDist <= arrowSize * 0.5 or centerDist >= totalLen - arrowSize * 0.5 then return end
			local _, _, fwd = frameAtDistance(centerDist)
			markingDecal(centerDist, fwd * -travelSign, offset, arrowSize, arrowSize, arrowTexture(spec), aColor)
		end

		if arrowsStart then
			for _, spec in arrowsStart do
				drawArrow(arrowStartBase, 1, spec.offset, spec)
			end
		end
		if arrowsEnd then
			for _, spec in arrowsEnd do
				drawArrow(arrowEndBase, -1, spec.offset, spec)
			end
		end
		if options.mergeEnd then
			for _, spec in options.mergeEnd do
				-- Lane-drop merge: the painted merge chevron pointing to the surviving side.
				drawArrow(arrowEndBase, -1, spec.offset, { merge = if spec.left then "left" else "right" })
			end
		end
	end

	-- Painted speed-limit numeral, shown ONLY at an end where the limit differs from the
	-- connecting road (server sets speedNumberStart/End for the end a driver ENTERS). Placed
	-- well past the junction furniture so it never lands on a crosswalk, arrow or the box.
	if options.speedLimit and options.speedLimit > 0 and (options.speedNumberStart or options.speedNumberEnd) then
		local textures = RoadConstants.SPEED_NUMBER_TEXTURES
		local limit = math.clamp(math.round(options.speedLimit / 10) * 10, 10, 120)
		local texId = textures and textures[limit]
		if texId then
			local cw = options.carriagewayWidth or options.width or RoadConstants.ROAD_WIDTH
			local laneCount = math.max(1, options.laneCount or 2)
			local lanesPerDir = if options.oneWay then laneCount else math.max(1, math.floor(laneCount * 0.5))
			local laneWidth = cw / laneCount
			local plateL = math.min(laneWidth * 0.7, 7)
			local plateW = math.min(laneWidth * 0.5, 5)
			local sReach = options.markingStartOffset or 0
			local eReach = totalLen - (options.markingEndOffset or 0)
			local function placeNumber(centerDist: number, dirSign: number, offset: number)
				if centerDist <= plateL or centerDist >= totalLen - plateL then return end
				local c, side, fwd = frameAtDistance(centerDist)
				local roadUp = side:Cross(fwd)
				roadUp = if roadUp.Magnitude > 1e-6 then roadUp.Unit else UP
				local travelDir = fwd * dirSign
				local base = c + roadUp * yOff + side * offset
				local plateCenter = base - roadUp * (markingThickness * 0.5)
				local plate = Instance.new("Part")
				plate.Name = "SpeedNumber"
				plate.Anchored = anchored
				plate.CanCollide = false
				plate.CanTouch = false
				plate.CanQuery = false
				plate.CastShadow = false
				plate.Transparency = 1
				plate.Size = Vector3.new(plateW, markingThickness, plateL)
				plate.CFrame = CFrame.lookAt(plateCenter, plateCenter - travelDir, roadUp)
				plate.Parent = model
				local decal = Instance.new("Decal")
				decal.Name = "SpeedNumberDecal"
				decal.Texture = texId
				decal.Face = Enum.NormalId.Top
				decal.Color3 = RoadConstants.MARKING_WHITE
				decal.Transparency = transparency
				decal.Parent = plate
			end
			-- One numeral per ENTERING lane (so a multi-lane road paints both lanes). +side IS the
			-- right of travel -- the LEFT edge line is the negative-offset one above, and apronPlus
			-- is documented as the +side/right apron -- so on this right-hand-drive map a driver
			-- entering along +fwd is in the +side half. The sign used to be flipped, which painted
			-- the numeral in the oncoming lanes.
			local function laneOffset(k: number, dirSign: number): number
				if options.oneWay then
					return -cw * 0.5 + laneWidth * (k - 0.5)
				end
				return dirSign * laneWidth * (k - 0.5)
			end
			-- Lane arrows have PRIORITY, measured off where they REALLY are (arrowStartDist /
			-- arrowEndDist), not off a second guess at the setback -- the two disagreed on a short
			-- link and the numeral landed on the arrow. Window is what is left between the rows;
			-- if that is nothing, the arrow keeps it and no numeral is painted.
			local CLEAR = 6 -- clear asphalt between arrow tail and numeral
			local EXTRA = 30 -- and then push the numeral further back still
			local lo = sReach + plateL * 0.5 + 2
			local hi = eReach - plateL * 0.5 - 2
			if arrowStartDist then
				lo = math.max(lo, arrowStartDist + arrowHalf + CLEAR + plateL * 0.5)
			end
			if arrowEndDist then
				hi = math.min(hi, arrowEndDist - arrowHalf - CLEAR - plateL * 0.5)
			end
			if lo <= hi then
				if options.speedNumberStart then
					local d = math.clamp(lo + EXTRA, lo, hi)
					for k = 1, lanesPerDir do placeNumber(d, 1, laneOffset(k, 1)) end
				end
				if options.speedNumberEnd then
					local d = math.clamp(hi - EXTRA, lo, hi)
					for k = 1, lanesPerDir do placeNumber(d, -1, laneOffset(k, -1)) end
				end
			end
		end
	end

	-- Parking apron: a distinct-colour asphalt strip filling the area between the
	-- carriageway edge line and the surface/sidewalk edge on each active side. It is a
	-- thin cosmetic skin laid over the (already collidable) road surface -- cars park ON
	-- it but drive only inside the carriageway, so it needs no collision/query of its own.
	-- Swept like the median/sidewalk; skips the junction setback via st0/st1.
	-- ponytail: only the GRASS verge is drawn now. The asphalt parking apron laid a
	-- differently-coloured slab over the kerbside strip, which swallowed the edge line and read
	-- as a pad stuck on the road. Its width is still carved off the carriageway, so the nav
	-- graph and ParkingService's bays are exactly where they were -- cars just park on bare
	-- asphalt between the edge line and the kerb.
	if apronIsGrass then
		local apronColor = if apronIsGrass
			then (options.medianColor or Color3.fromRGB(80, 120, 60))
			else (options.parkingApronColor or RoadConstants.PARKING_APRON_COLOR or options.color)
		local apronH = if apronIsGrass then RoadConstants.SIDEWALK_HEIGHT else 0.12
		local function apronRail(sign: number, apronW: number)
			if apronW <= 1e-3 or vt1 <= vt0 then return end
			-- Clip to the trim range: where the lane markings stop (no bleed into junctions), cut
			-- back further to the start of a width taper.
			local n = math.max(1, math.ceil((vt1 - vt0) * trimSamples))
			local prev: Vector3? = nil
			local prevDir: Vector3? = nil
			for i = 0, n do
				local t = vt0 + (vt1 - vt0) * (i / n)
				local c, _, side, roadUp = frameAt(t)
				-- CONSTANT width, against the surface edge. The strip never tapers, but the edge it
				-- hugs does, so a verge running on into a narrower road follows the kerb in.
				local dist = distanceAtT(t)
				local lhw, rhw = sideHalfWidths(dist)
				local centreOff = sign * ((if sign > 0 then rhw else lhw) - apronW * 0.5)
				c = c + roadUp * (thickness * 0.5) + side * (centerOffsetAtDistance(dist) + centreOff)
				if prev then
					local seg = c - prev
					local len = seg.Magnitude
					if len > 1e-3 then
						local fwdDir = seg / len
						local backReach = 0
						if prevDir then
							backReach = apronW * prevDir:Cross(fwdDir).Magnitude
						end
						prevDir = fwdDir
						local midT = vt0 + (vt1 - vt0) * ((i - 0.5) / n)
						local _, _, midSide = frameAt(midT)
						local rightDir = midSide
						local upDir = rightDir:Cross(fwdDir)
						if upDir.Magnitude < 1e-6 then upDir = UP end
						upDir = upDir.Unit
						if upDir:Dot(UP) < 0 then
							upDir = -upDir
							rightDir = -rightDir
						end
						-- Asphalt apron straddles the surface top (flush band) -> asphalt mesh; a grass
						-- verge is raised to sit ON the surface like the median -> grass mesh.
						local apronBuilder = meshBuilder
						apronBuilder:addBox(
							CFrame.fromMatrix(
								(prev + c) * 0.5 - fwdDir * (backReach * 0.5) + upDir * (if apronIsGrass then apronH * 0.5 else 0),
								rightDir, upDir, -fwdDir
							),
							Vector3.new(apronW, apronH, len + 0.18 + backReach),
							apronColor,
							(if apronIsGrass then Enum.Material.Grass else nil)
						)
					end
				end
				prev = c
			end
		end
		apronRail(1, vergePlus)
		apronRail(-1, vergeMinus)
	end

	if options.median and md1 > md0 then
		local mW  = options.medianWidth or 3
		local mH  = RoadConstants.SIDEWALK_HEIGHT
		local mCol = options.medianColor or Color3.fromRGB(80, 120, 60)
		local mHalf = mW * 0.5
		local n = math.max(1, math.ceil((md1 - md0) * trimSamples))
		local prev: Vector3? = nil
		local prevDir: Vector3? = nil
		for i = 0, n do
			local t = md0 + (md1 - md0) * (i / n)
			local c, _, side, roadUp = frameAt(t)
			c = c + roadUp * (thickness * 0.5) + side * centerOffsetAtDistance(distanceAtT(t))
			if prev then
				local seg = c - prev
				local len = seg.Magnitude
				if len > 1e-3 then
					local fwdDir = seg / len
					local backReach = 0
					if prevDir then
						backReach = (mW + mH) * prevDir:Cross(fwdDir).Magnitude
					end
					prevDir = fwdDir
					local midT = md0 + (md1 - md0) * ((i - 0.5) / n)
					local _, _, midSide = frameAt(midT)
					local rightDir = midSide
					local upDir = rightDir:Cross(fwdDir)
					if upDir.Magnitude < 1e-6 then upDir = UP end
					upDir = upDir.Unit
					if upDir:Dot(UP) < 0 then
						upDir = -upDir
						rightDir = -rightDir
					end
					meshBuilder:addBox(
						CFrame.fromMatrix(
							(prev + c) * 0.5 - fwdDir * (backReach * 0.5) + upDir * (mH * 0.5),
							rightDir, upDir, -fwdDir
						),
						Vector3.new(mW, mH, len + 0.18 + backReach),
						mCol,
						Enum.Material.Grass
					)
				end
			end
			prev = c
		end

		local medianLineColor = RoadConstants.MARKING_WHITE
		local lineHalf = 0.15
		surfaceTextureStrip(md0, md1,  mHalf + lineHalf + 0.05, lineHalf, medianLineColor, false, nil, "median:plus")
		surfaceTextureStrip(md0, md1, -(mHalf + lineHalf + 0.05), lineHalf, medianLineColor, false, nil, "median:minus")
	end

	if options.guardrail then
		local railTop = options.guardrailHeight or RoadConstants.GUARDRAIL_HEIGHT
		local railCol = options.guardrailColor or RoadConstants.GUARDRAIL_COLOR
		local railMat = options.guardrailMaterial or Enum.Material.Metal
		local beamH = RoadConstants.GUARDRAIL_BEAM_HEIGHT
		local beamW = RoadConstants.GUARDRAIL_BEAM_WIDTH
		local postW = RoadConstants.GUARDRAIL_POST_WIDTH
		local postSpacing = RoadConstants.GUARDRAIL_POST_SPACING
		local swWidth = if options.sidewalk then (options.sidewalkWidth or RoadConstants.SIDEWALK_WIDTH) else 0
		local swH = if options.sidewalk then (options.sidewalkHeight or RoadConstants.SIDEWALK_HEIGHT) else 0
		-- Sit the rail at the OUTER edge of the sidewalk (on top of it) when there is one,
		-- otherwise just off the road edge.
		local railLat = if options.sidewalk then swWidth - beamW * 0.5 else beamW * 0.5 + 0.15
		-- Per-side trim range (stR*/stL*), same as the sidewalk the rail sits on. The old
		-- shared st0/st1 locals were removed in the per-side kerb-trim refactor; referencing
		-- them here read nil globals and crashed every guardrail build (ramps/elevated kept
		-- their STALE pre-junction model: uncut sidewalks, missing crosswalks).
		local function rail(sign: number, t0: number, t1: number)
			if t1 <= t0 then return end
			local n = math.max(1, math.ceil((t1 - t0) * trimSamples))
			local prev: Vector3? = nil
			local prevDir: Vector3? = nil
			local sincePost = postSpacing
			for i = 0, n do
				local t = t0 + (t1 - t0) * (i / n)
				local c, _, side, roadUp = frameAt(t)
				c = c + roadUp * (thickness * 0.5) + side * centerOffsetAtDistance(distanceAtT(t))
				local p = c + roadUp * swH + side * ((halfWidthAtT(t) + railLat) * sign)
				if prev then
					local seg = p - prev
					local len = seg.Magnitude
					if len > 1e-3 then
						local fwdDir = seg / len
						local backReach = 0
						if prevDir then
							backReach = beamW * prevDir:Cross(fwdDir).Magnitude
						end
						prevDir = fwdDir
						local midT = t0 + (t1 - t0) * ((i - 0.5) / n)
						local _, _, midSide = frameAt(midT)
						local rightDir = midSide
						local upDir = rightDir:Cross(fwdDir)
						if upDir.Magnitude < 1e-6 then upDir = UP end
						upDir = upDir.Unit
						if upDir:Dot(UP) < 0 then
							upDir = -upDir
							rightDir = -rightDir
						end
						-- W-beam rail near the top, running along the edge.
						meshBuilder:addBox(
							CFrame.fromMatrix(
								(prev + p) * 0.5 - fwdDir * (backReach * 0.5) + upDir * (railTop - beamH * 0.5),
								rightDir, upDir, -fwdDir
							),
							Vector3.new(beamW, beamH, len + 0.1 + backReach),
							railCol,
							railMat
						)

						-- Posts dropping to the deck at a fixed spacing.
						sincePost += len
						if sincePost >= postSpacing then
							sincePost -= postSpacing
							local postH = railTop - beamH
							if postH > 0.1 then
								meshBuilder:addBox(
									CFrame.fromMatrix(p + upDir * (postH * 0.5), rightDir, upDir, -fwdDir),
									Vector3.new(postW, postH, postW),
									railCol,
									railMat
								)
							end
						end
					end
				end
				prev = p
			end
		end
		rail(1, stR0, stR1)
		rail(-1, stL0, stL1)
	end

	-- One bake -> a Model of Parts for the whole segment (surface, kerbs, median, guardrail,
	-- markings). The client merges it into ONE MeshPart (RoadMeshVisualsController).
	local function bakeInto(builder: RoadMeshBuilder.Builder, name: string, material: Enum.Material, collide: boolean)
		local mesh = builder:bake({
			name = name,
			anchored = anchored,
			canCollide = collide,
			transparency = transparency,
			material = material,
		})
		if mesh then
			mesh.Parent = model
		end
	end
	bakeInto(meshBuilder, "RoadSegment", Enum.Material.SmoothPlastic, canCollide)

	model.Parent = parent
	return model
end

return RoadRenderer
