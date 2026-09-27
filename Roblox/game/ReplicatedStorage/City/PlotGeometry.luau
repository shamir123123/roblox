--!strict
-- PlotGeometry
-- Pure library for Manor Lords-style burgage plots. Given a road segment + a frontage span
-- along it (t0..t1) + a backyard depth, subdivides the frontage into N variable-width plots,
-- each a road-facing quad that follows the road curve. The front edge sits past the carriageway
-- and the footway where that side has one; the back edge is `depth` studs behind it.
--
-- Pure: no state, no lifecycle, no side effects on require. Shared by the client tool/preview
-- and the server PlotService so a drawn plot round-trips to the same geometry.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RoadConstants   = require(ReplicatedStorage.Road.RoadConstants)
local BezierUtil      = require(ReplicatedStorage.Road.BezierUtil)
local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)
local IntersectionRenderer = require(ReplicatedStorage.Road.IntersectionRenderer) -- pure corner geometry (armBoundaryDistances)

local PlotGeometry = {}

export type Segment = { p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, roadType: string? }

-- Corners are ordered front-left, front-right, back-right, back-left (front = road side).
export type Plot = {
	frontA   : Vector3,
	frontB   : Vector3,
	backB    : Vector3,
	backA    : Vector3,
	center   : Vector3,
	frontage : number,
	depth    : number,
	angleDeg : number,
	t0       : number, -- t-span along the segment this plot covers
	t1       : number,
}

-- Half-size world (RoadConstants.WORLD_SCALE): every stud dimension below scales together,
-- so plots stay the same LOT COUNT but half the physical size, matching the scaled buildings.
local WORLD_SCALE        = RoadConstants.WORLD_SCALE
-- Plot sizing rides ZoneGrid.BUILDING_SCALE (see that file): plots and the buildings that
-- sit in them must share one lot unit, and buildings are no longer stamped at WORLD_SCALE.
-- The road-relative margins further down keep WORLD_SCALE -- they measure against asphalt.
local BUILDING_SCALE     = require(ReplicatedStorage.City.ZoneGrid).BUILDING_SCALE
local DEFAULT_PLOT_WIDTH = 24 * BUILDING_SCALE -- studs. ponytail: default, caller overrides
local MIN_PLOT_WIDTH     = 12 * BUILDING_SCALE
local SAMPLES            = 96 -- arc-length resolution (a COUNT, not a size)
local LOT_STUD           = 16 * BUILDING_SCALE -- studs per lot unit (matches ZoneGrid.LOT_SIZE)
local MAX_PARCEL_LOTS    = 10 -- deepest PARCEL in lots: the building sits at the front (<=5 lots), the rest is backyard toward the block interior
local MAX_PARCEL_DEPTH   = MAX_PARCEL_LOTS * LOT_STUD -- studs: parcel-depth ceiling (building + backyard)

PlotGeometry.DEFAULT_PLOT_WIDTH = DEFAULT_PLOT_WIDTH
PlotGeometry.MIN_PLOT_WIDTH     = MIN_PLOT_WIDTH
PlotGeometry.MAX_PARCEL_DEPTH   = MAX_PARCEL_DEPTH
-- Houses are real size and the narrowest is ~13 m, so a low-density residential plot is
-- at least 3 lots (16 m) wide. PlotController and PlotService both raise the width to it.
PlotGeometry.MIN_HOUSE_LOTS     = 3

-- Flat unit normal pointing toward `sideSign` (-1 / 1) from the road tangent.
local function sideNormal(tangent: Vector3, sideSign: number): Vector3
	local flat = Vector3.new(tangent.X, 0, tangent.Z)
	if flat.Magnitude < 1e-4 then return Vector3.xAxis end
	flat = flat.Unit
	return Vector3.new(-flat.Z, 0, flat.X) * sideSign
end

-- Centreline -> plot front: road half-width plus the FOOTWAY ON THAT SIDE, where that side has
-- one. A kerbless side -- an alley or highway, or a street carrying its pavement on the far kerb
-- only -- gets a shoulder instead: the flat + SIDEWALK_WIDTH this replaces stood every house a
-- pavement back from asphalt that has no pavement. sideSign nil = the deeper of the two (bounds,
-- and cap rings, which face both ways). +side is the RIGHT kerb, as RoadRenderer lays its walk.
local KERBLESS_SHOULDER = 4 * WORLD_SCALE -- must clear BLOCK_MARGIN or rectOnRoad rejects its own seats
local function frontOffset(roadType: string?, sideSign: number?): number
	local spec = RoadTypeCatalog.getOrDefault(roadType)
	local mode = spec.sidewalkMode or (if spec.noSidewalk then "none" else "both")
	local hasWalk = if sideSign == nil
		then mode ~= "none"
		else mode == "both" or mode == (if sideSign >= 0 then "right" else "left")
	return spec.width * 0.5 + (if hasWalk then RoadConstants.SIDEWALK_WIDTH else KERBLESS_SHOULDER)
end
PlotGeometry.frontOffset = frontOffset -- exposed so the client tool can derive depth from the cursor

type SpanSamples = { pts: { Vector3 }, tans: { Vector3 }, cum: { number }, total: number, t0: number, t1: number }

-- Sample points + tangents across [t0,t1] with a running flat arc-length. offset > 0 samples
-- the FRONTAGE line (centreline pushed sideways toward sideSign), so plot boundaries measure
-- true frontage studs -- even widths on curves, where the centreline arc-length lies.
-- offset == 0 samples the centreline (cursor t <-> road distance mapping).
local function sampleLine(seg: Segment, sideSign: number, offset: number, t0: number, t1: number): SpanSamples
	local pts: { Vector3 }  = {}
	local tans: { Vector3 } = {}
	local cum: { number }   = {}
	local prev: Vector3? = nil
	local total = 0
	for i = 0, SAMPLES do
		local t = t0 + (t1 - t0) * (i / SAMPLES)
		local p = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
		local tan = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, t)
		if offset ~= 0 then
			local n = sideNormal(tan, sideSign)
			p = Vector3.new(p.X + n.X * offset, p.Y, p.Z + n.Z * offset)
		end
		if prev then
			local dx, dz = p.X - prev.X, p.Z - prev.Z
			total += math.sqrt(dx * dx + dz * dz)
		end
		pts[i + 1] = p
		tans[i + 1] = tan
		cum[i + 1] = total
		prev = p
	end
	return { pts = pts, tans = tans, cum = cum, total = total, t0 = t0, t1 = t1 }
end

-- Point, tangent and global segment-t at arc-length `dist` along the sampled line.
local function lineAt(s: SpanSamples, dist: number): (Vector3, Vector3, number)
	dist = math.clamp(dist, 0, s.cum[#s.cum])
	local i = 1
	while i < #s.cum and s.cum[i + 1] < dist do i += 1 end
	local segLen = s.cum[i + 1] - s.cum[i]
	local f = if segLen > 1e-6 then (dist - s.cum[i]) / segLen else 0
	local p = s.pts[i]:Lerp(s.pts[i + 1], f)
	local tan = s.tans[i]:Lerp(s.tans[i + 1], f)
	local t = s.t0 + (s.t1 - s.t0) * (((i - 1) + f) / SAMPLES)
	return p, tan, t
end

-- Arc-length at global segment-t over the sampled line.
local function distAtT(s: SpanSamples, t: number): number
	local span = s.t1 - s.t0
	local x = if math.abs(span) > 1e-9 then math.clamp((t - s.t0) / span, 0, 1) * SAMPLES else 0
	local i = math.floor(x)
	local f = x - i
	local a = s.cum[i + 1] or s.cum[#s.cum]
	local b = s.cum[i + 2] or a
	return a + (b - a) * f
end

-- Partition L whole lots into building widths, preferring `target` (2..5 lots each).
-- uniform: ONLY exact target-width plots; the remainder frontage stays unzoned.
-- mixed (default): fill gap-free with mixed sizes, never narrower than min(target, 3) --
-- 2 and 3 compose every integer >= 2, and 3/4/5 every integer >= 3, so no stranded remainder
-- (a 3-lot house row must not get 2-lot fillers: no real-size house fits one).
local function packLots(L: number, target: number, uniform: boolean): { number }
	local parts: { number } = {}
	if uniform then
		for _ = 1, L // target do parts[#parts + 1] = target end
		return parts
	end
	local minW = math.min(target, 3)
	while L >= minW do
		local w = math.min(target, L)
		local r = L - w
		if r > 0 and r < minW then -- would strand an unbuildable remainder: absorb it into this plot
			w = if w + r <= 5 then w + r else w - (minW - r)
		end
		parts[#parts + 1] = w
		L -= w
	end
	return parts
end

-- Walk [t0,t1] on the offset frontage line, cutting lot-multiple plots. depthOf(frontMid,
-- inward) gives each plot's parcel depth (nil = skip that plot -- e.g. outside a polygon).
-- A plot that folds on a tight inner curve (back edge collapsing or flipping) is dropped --
-- it cannot hold its building; the walk continues past it.
local function cutPlots(front: SpanSamples, sideSign: number, targetWidth: number?, uniform: boolean?, depthOf: (Vector3, Vector3, Vector3, Vector3) -> number?): { Plot }
	local L = math.floor(front.total / LOT_STUD + 1e-3)
	if L < 2 then return {} end
	local target = math.clamp(math.round((targetWidth or DEFAULT_PLOT_WIDTH) / LOT_STUD), 2, 5)
	local widths = packLots(L, target, uniform == true)
	-- Whole lots never divide a frontage exactly, so a plain lot-multiple walk strands up to
	-- one lot at the far end. A long road is auto-split every MAX_PLACE_SEGMENT_LENGTH studs
	-- and each piece packs from its own t=0, so that leftover showed up as a notch of bare
	-- grass at EVERY join. Spread it across the run instead: every plot's frontage stretches
	-- by the same fraction, so the run reaches the segment end and meets the next one.
	-- Capped at 9%, which cannot round a plot up into the next template size (fitLots rounds,
	-- and the widest plot is 5 lots -- 5 * 1.09 still rounds to 5). Uniform mode opts out:
	-- there "exactly W wide" is the promise, and the remainder is meant to stay unzoned.
	local stretch = if uniform == true then 1
		else math.min(front.total / math.max(L * LOT_STUD, 1e-3), 1.09)
	local plots: { Plot } = {}
	local dist = 0
	local prevFront, prevTan, prevT = lineAt(front, 0)
	for _, w in widths do
		dist += w * LOT_STUD * stretch
		local fPt, tan, tHere = lineAt(front, dist)
		local nA = sideNormal(prevTan, sideSign)
		local nB = sideNormal(tan, sideSign)
		local frontEdge = fPt - prevFront
		local inward = nA + nB
		inward = if inward.Magnitude < 1e-4 then nB else inward.Unit
		local want = depthOf((prevFront + fPt) * 0.5, inward, prevFront, fPt)
		if want then
			-- Deepest whole-lot parcel that still holds a quad on THIS frontage: straights take the
			-- full depth (long backyard toward the interior); a tight inner curve steps down to a
			-- depth that doesn't fold instead of being dropped. Building depth caps at 5 lots
			-- downstream (fitDepthLots), so anything past that is backyard, not a bigger house.
			local wantLots = math.clamp(math.floor(want / LOT_STUD + 1e-3), 2, MAX_PARCEL_LOTS)
			local flat = Vector3.new(tan.X, 0, tan.Z)
			for dl = wantLots, 2, -1 do
				local depth = dl * LOT_STUD
				local backA = prevFront + nA * depth
				local backB = fPt + nB * depth
				local backEdge = backB - backA
				if frontEdge:Dot(backEdge) > 0 and backEdge.Magnitude > frontEdge.Magnitude * 0.25 then
					table.insert(plots, {
						frontA = prevFront, frontB = fPt, backB = backB, backA = backA,
						center = (prevFront + fPt + backB + backA) / 4,
						frontage = frontEdge.Magnitude, depth = depth,
						angleDeg = math.deg(math.atan2(flat.X, flat.Z)),
						t0 = prevT, t1 = tHere,
					})
					break
				end
			end
		end
		prevFront, prevTan, prevT = fPt, tan, tHere
	end
	return plots
end

local function packRun(seg: Segment, sideSign: number, t0: number, t1: number, targetWidth: number?, uniform: boolean?, depthOf: (Vector3, Vector3, Vector3, Vector3) -> number?): { Plot }
	if t1 < t0 then t0, t1 = t1, t0 end
	return cutPlots(sampleLine(seg, sideSign, frontOffset(seg.roadType, sideSign), t0, t1), sideSign, targetWidth, uniform, depthOf)
end

-- Constant-depth packing (Line / Single mode, erase highlight, group rebuild).
function PlotGeometry.packPlots(seg: Segment, sideSign: number, t0: number, t1: number, depth: number, targetWidth: number?, uniform: boolean?): { Plot }
	return packRun(seg, sideSign, t0, t1, targetWidth, uniform, function()
		return depth
	end)
end

-- The t-range bracketing `tCenter` whose flat arc-length is `width` -- for placing ONE plot
-- of a chosen width centred under the cursor (clamped against the segment ends).
function PlotGeometry.spanForWidth(seg: Segment, tCenter: number, width: number): (number, number)
	local s = sampleLine(seg, 1, 0, 0, 1)
	if s.total <= 1e-3 then return tCenter, tCenter end
	width = math.max(MIN_PLOT_WIDTH, width)
	local c = distAtT(s, tCenter)
	-- Slide (not truncate) the window at segment ends so a full-width house can sit
	-- flush against a road end instead of shrinking or disappearing there.
	local lo = math.clamp(c - width * 0.5, 0, math.max(0, s.total - width))
	local hi = math.min(s.total, lo + width)
	local _, _, tLo = lineAt(s, lo)
	local _, _, tHi = lineAt(s, hi)
	return tLo, tHi
end

-- Template lot-unit fits (templates exist for 2..5 per axis). Shared by the server placer and
-- the client preview so the preview shows EXACTLY the building that will be placed.
-- Width ROUNDS (plot frontages are lot multiples; the chord on a curve reads a hair short).
-- Depth FLOORS so the building never pokes out the back of its plot.
function PlotGeometry.fitLots(studs: number): number
	return math.clamp(math.round(studs / LOT_STUD), 2, 5)
end

function PlotGeometry.fitDepthLots(studs: number): number
	return math.clamp(math.floor(studs / LOT_STUD + 1e-3), 2, 5)
end

-- Footprint corners of a SEATED building from its pivot alone (all a save stores): the rect
-- buildingRect produces, so a stored seat can be re-tested against today's roads.
function PlotGeometry.seatCorners(pivot: CFrame, wLots: number, dLots: number): { Vector3 }
	local right = pivot.RightVector
	local inward = -pivot.LookVector
	local hw, d = wLots * LOT_STUD * 0.5, dLots * LOT_STUD
	local frontMid = pivot.Position - inward * (d * 0.5)
	local fA = frontMid - right * hw
	local fB = frontMid + right * hw
	return { fA, fB, fB + inward * d, fA + inward * d }
end

-- Building pivot + footprint corners for a plot: seated centred on the frontage line, extending
-- dLots into the plot, looking TOWARD the road (+Z away -- the BuildingService convention).
function PlotGeometry.buildingRect(plot: Plot, wLots: number, dLots: number): (CFrame, { Vector3 })
	local frontMid = (plot.frontA + plot.frontB) * 0.5
	local inward = (plot.backA - plot.frontA) + (plot.backB - plot.frontB)
	inward = Vector3.new(inward.X, 0, inward.Z)
	inward = if inward.Magnitude < 1e-4 then Vector3.zAxis else inward.Unit
	local d = dLots * LOT_STUD
	local center = frontMid + inward * (d * 0.5)
	center = Vector3.new(center.X, frontMid.Y, center.Z)
	local pivot = CFrame.lookAt(center, center - inward, Vector3.yAxis)
	return pivot, PlotGeometry.seatCorners(pivot, wLots, dLots)
end

-- ---- road index: where zoning is allowed --------------------------------------
-- Built from the plain segment list (client DataCache or the server road network -- both carry
-- id + p0..p3 + roadType). Node context is derived by clustering segment endpoints, so ONE
-- code path serves both sides.

export type RoadIndex = {
	-- block: reach from the centreline a building on THIS road must stay outside (the asphalt
	-- plus a hair, so a house on a curve may sit in its own sidewalk). strict: the reach for
	-- a building on ANOTHER road -- sidewalk included, so a corner house never pokes past the
	-- cross street's kerb.
	bands: { { seg: any, block: number, strict: number, minX: number, maxX: number, minZ: number, maxZ: number } },
	-- Slabs no segment band covers. segId/atEnd are set on dead-end caps only, so the
	-- client can find the bulb the cursor points past (cap-ring placement).
	discs: { { x: number, z: number, r: number, segId: number?, atEnd: boolean? } },
	-- segId -> per end ([1] = start, [2] = end), per side (s1 = side +1, s2 = side -1):
	-- frontage kept clear of the node, in arc studs. 0 = zonable right up to the node.
	clip: { [number]: { { s1: number, s2: number } } },
	-- "Is this seat's ground already taken?", injected by whoever built the index. This module
	-- stays pure geometry -- it never looks at the world itself -- but a seat that would sit
	-- on top of a hospital, a car park or a creation must be blocked, and buildingBlocked is the
	-- one place both the client preview and the server placer ask. nil = nothing to consult
	-- (the specs, which have no world).
	occupied: ((corners: { Vector3 }) -> boolean)?,
}

local BLOCK_MARGIN = 0.5 * WORLD_SCALE -- how deep into a road slab a plot may reach before it's blocked
                         -- (sidewalk overlap is tolerated -- houses sit at the back of it)
local CLEAR_MARGIN = 1 * WORLD_SCALE   -- extra frontage kept clear past a cap / junction mouth (small: parcels reach closer to corners)
local CROSS_TOL    = 2 * WORLD_SCALE   -- studs a building may reach into ANOTHER road's sidewalk (kerb-side clearance, never the asphalt)

function PlotGeometry.buildRoadIndex(segments: { [any]: any }, occupied: ((corners: { Vector3 }) -> boolean)?): RoadIndex
	local bands = {}
	local discs = {}
	local clip: { [number]: { number } } = {}
	local clusters: { [string]: { arms: { any }, pos: Vector3 } } = {}

	local function addArm(seg: any, spec: any, atEnd: boolean)
		local pos = if atEnd then seg.p3 else seg.p0
		local key = tostring(math.floor(pos.X * 0.5 + 0.5)) .. "|" .. tostring(math.floor(pos.Z * 0.5 + 0.5))
		local cl = clusters[key]
		if not cl then
			cl = { arms = {}, pos = pos }
			clusters[key] = cl
		end
		local tan = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, if atEnd then 1 else 0)
		local dir = Vector3.new(tan.X, 0, tan.Z)
		if dir.Magnitude < 1e-4 then
			dir = Vector3.new(seg.p3.X - seg.p0.X, 0, seg.p3.Z - seg.p0.Z)
		end
		dir = if dir.Magnitude < 1e-4 then Vector3.xAxis else dir.Unit
		if atEnd then dir = -dir end
		-- Node-tool shaping at THIS end, so the frontage clearance below matches the
		-- junction the player actually shaped (clusters are keyed by position, not by
		-- node id, so the fields are read off the segment end directly).
		table.insert(cl.arms, {
			segId = seg.id, atEnd = atEnd, dir = dir, width = spec.width,
			corner = if atEnd then seg.endCorner else seg.startCorner,
			offset = if atEnd then seg.endOffset else seg.startOffset,
		})
	end

	for _, seg in segments do
		local spec = RoadTypeCatalog.getOrDefault(seg.roadType)
		local block = spec.width * 0.5 + BLOCK_MARGIN
		local strict = math.max(block, spec.width * 0.5 + RoadConstants.SIDEWALK_WIDTH - CROSS_TOL)
		table.insert(bands, {
			seg = seg, block = block, strict = strict,
			minX = math.min(seg.p0.X, seg.p1.X, seg.p2.X, seg.p3.X) - strict,
			maxX = math.max(seg.p0.X, seg.p1.X, seg.p2.X, seg.p3.X) + strict,
			minZ = math.min(seg.p0.Z, seg.p1.Z, seg.p2.Z, seg.p3.Z) - strict,
			maxZ = math.max(seg.p0.Z, seg.p1.Z, seg.p2.Z, seg.p3.Z) + strict,
		})
		clip[seg.id] = { { s1 = 0, s2 = 0 }, { s1 = 0, s2 = 0 } }
		addArm(seg, spec, false)
		addArm(seg, spec, true)
	end

	for _, cl in clusters do
		if #cl.arms == 1 then
			-- Dead end: cap disc only (no frontage clip) -- houses hug the bulb sides and,
			-- via planCapRing, ring the ground beyond the tip. segId/atEnd let the client
			-- find which bulb the cursor points past.
			local a = cl.arms[1]
			table.insert(discs, { x = cl.pos.X, z = cl.pos.Z, r = a.width * 0.5 + 2, segId = a.segId, atEnd = a.atEnd })
		else
			-- Per-SIDE junction clearance: an arm's side is clipped only when another arm
			-- actually opens onto it, so the outer side of a corner and the side of a road
			-- opposite a T-mouth stay zonable straight across the node.
			local armList = table.create(#cl.arms)
			for i, a in cl.arms do armList[i] = { dir = a.dir, width = a.width, corner = a.corner, offset = a.offset } end
			local dists = IntersectionRenderer.armBoundaryDistances(cl.pos, armList :: any)
			local maxWidth, bent = 0, false
			for i, a in cl.arms do
				maxWidth = math.max(maxWidth, a.width)
				local nx, nz = -a.dir.Z, a.dir.X -- arm-space left normal
				local d = (dists[i] or a.width * 0.5) + CLEAR_MARGIN
				local clearL, clearR = 0, 0
				for j, b in cl.arms do
					if j ~= i then
						local s = nx * b.dir.X + nz * b.dir.Z
						if s > 0.2 then clearL = math.max(clearL, d) end
						if s < -0.2 then clearR = math.max(clearR, d) end
						if a.dir:Dot(b.dir) > -0.866 then bent = true end
					end
				end
				local entry = clip[a.segId]
				if entry then
					-- Arm-space left/right are segment sides +1/-1 at the start node and
					-- flip at the end node (the tangent reverses).
					local slot = entry[if a.atEnd then 2 else 1]
					local sPlus = if a.atEnd then clearR else clearL
					local sMinus = if a.atEnd then clearL else clearR
					slot.s1 = math.max(slot.s1, sPlus)
					slot.s2 = math.max(slot.s2, sMinus)
				end
			end
			-- A bent 2-arm corner renders a filler slab at the node that no segment band
			-- covers; a disc keeps buildings off it (the outer side stays zonable past it).
			if #cl.arms == 2 and bent then
				table.insert(discs, { x = cl.pos.X, z = cl.pos.Z, r = maxWidth * 0.5 + 2 })
			end
		end
	end

	return { bands = bands, discs = discs, clip = clip, occupied = occupied }
end

-- Studs two welded segments' shared endpoint may differ by. They are written from the same
-- node, so this is slop, not a search radius.
local JOIN_EPS = 2

-- Push a drag's per-segment t-spans out to every endpoint two DRAGGED segments share.
-- A drag samples the cursor once a frame, so the moment it crosses from one road piece to
-- the next it records neither piece's shared end -- leaving an unzoned notch at the join,
-- as wide as the mouse was fast. If both pieces are in the drag the player went straight
-- past that node, so the whole join is inside the drag by definition.
-- `entries` is keyed however the caller likes; each value needs seg / tMin / tMax. Mutates.
function PlotGeometry.bridgeJoins(entries: { [any]: any })
	local n = 0
	for _ in entries do n += 1 end
	if n < 2 then return end
	local function shares(p: Vector3, q: Vector3): boolean
		local dx, dz = p.X - q.X, p.Z - q.Z
		return dx * dx + dz * dz < JOIN_EPS * JOIN_EPS
	end
	for ka, a in entries do
		for kb, b in entries do
			if ka ~= kb then
				for _, e in { b.seg.p0, b.seg.p3 } do
					if shares(a.seg.p0, e) then a.tMin = 0 end
					if shares(a.seg.p3, e) then a.tMax = 1 end
				end
			end
		end
	end
end

-- Shrink [t0,t1] so the frontage stays clear of junction mouths at the segment's ends.
-- `side` picks that side's clearances; nil = the worst of both (for side-less callers).
-- Returns nil when nothing zonable remains.
function PlotGeometry.clampSpan(index: RoadIndex, seg: any, t0: number, t1: number, side: number?): (number?, number?)
	if t1 < t0 then t0, t1 = t1, t0 end
	local c = index.clip[seg.id]
	if not c then return t0, t1 end
	local function pick(slot: { s1: number, s2: number }): number
		if side == 1 then return slot.s1 end
		if side == -1 then return slot.s2 end
		return math.max(slot.s1, slot.s2)
	end
	local c1, c2 = pick(c[1]), pick(c[2])
	if c1 <= 0 and c2 <= 0 then return t0, t1 end
	local s = sampleLine(seg, 1, 0, 0, 1)
	if s.total <= c1 + c2 then return nil, nil end
	local _, _, loT = lineAt(s, c1)
	local _, _, hiT = lineAt(s, s.total - c2)
	t0 = math.max(t0, loT)
	t1 = math.min(t1, hiT)
	if t1 - t0 < 1e-3 then return nil, nil end
	return t0, t1
end

-- True when any of these POINTS sits ON a road (a footprint asks rectOnRoad below instead):
-- inside a segment's slab band (flat distance to the
-- centreline under its half-width) or inside a dead-end cap disc. Given `ownSegId`, every
-- OTHER road counts its sidewalk too (band.strict): a building fronts its own road's sidewalk
-- by design, but must stay off a cross street's. Elevation is ignored --
-- ponytail: ground-level test only; add Y-banding if elevated roads over plots ever matter.
function PlotGeometry.rectBlocked(index: RoadIndex, pts: { Vector3 }, ownSegId: number?): boolean
	for _, pt in pts do
		for _, disc in index.discs do
			local dx, dz = pt.X - disc.x, pt.Z - disc.z
			local r = disc.r - 1
			if dx * dx + dz * dz < r * r then return true end
		end
		for _, b in index.bands do
			if pt.X > b.minX and pt.X < b.maxX and pt.Z > b.minZ and pt.Z < b.maxZ then
				local seg = b.seg
				local reach = if ownSegId ~= nil and seg.id ~= ownSegId then b.strict else b.block
				local q = BezierUtil.closestPoint(seg.p0, seg.p1, seg.p2, seg.p3, pt, 16)
				local dx, dz = q.X - pt.X, q.Z - pt.Z
				if dx * dx + dz * dz < reach * reach then return true end
			end
		end
	end
	return false
end

-- Flat distance from (x, z) to a rect given as 4 ordered corners; 0 when inside it.
local function distToRect(c: { Vector3 }, x: number, z: number): number
	local ex = Vector3.new(c[2].X - c[1].X, 0, c[2].Z - c[1].Z)
	local ez = Vector3.new(c[4].X - c[1].X, 0, c[4].Z - c[1].Z)
	local lx, lz = ex.Magnitude, ez.Magnitude
	if lx < 1e-4 or lz < 1e-4 then return math.huge end
	local px, pz = x - c[1].X, z - c[1].Z
	local a = (px * ex.X + pz * ex.Z) / lx
	local b = (px * ez.X + pz * ez.Z) / lz
	local dx = math.max(0, -a, a - lx)
	local dz = math.max(0, -b, b - lz)
	return math.sqrt(dx * dx + dz * dz)
end

local ROAD_STEP = 3 -- studs between centreline samples in the footprint test below

-- Does a road's pavement reach into this footprint (4 ordered corners)? Walks each nearby
-- road's CENTRELINE and measures to the rect, rather than measuring from points ON the rect.
-- The old nine-point sample (corners, edge midpoints, centre) sits half a footprint apart, so
-- a street could pass diagonally BETWEEN the samples and a big seat was planted across it --
-- which is how a 5x5 shop ended up straddling a road. Sampling the road instead is exact for
-- any footprint size and costs less than the nine closest-point searches it replaces.
function PlotGeometry.rectOnRoad(index: RoadIndex, corners: { Vector3 }, ownSegId: number?): boolean
	local c1, c2, c3, c4 = corners[1], corners[2], corners[3], corners[4]
	if not (c1 and c2 and c3 and c4) then return false end
	local minX, maxX = math.min(c1.X, c2.X, c3.X, c4.X), math.max(c1.X, c2.X, c3.X, c4.X)
	local minZ, maxZ = math.min(c1.Z, c2.Z, c3.Z, c4.Z), math.max(c1.Z, c2.Z, c3.Z, c4.Z)
	for _, disc in index.discs do
		if distToRect(corners, disc.x, disc.z) < disc.r - 1 then return true end
	end
	for _, b in index.bands do
		if maxX > b.minX and minX < b.maxX and maxZ > b.minZ and minZ < b.maxZ then
			local seg = b.seg
			local reach = if ownSegId ~= nil and seg.id ~= ownSegId then b.strict else b.block
			local len = BezierUtil.length(seg.p0, seg.p1, seg.p2, seg.p3, 8)
			local n = math.clamp(math.ceil(len / ROAD_STEP), 8, 128)
			for i = 0, n do
				local q = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, i / n)
				if distToRect(corners, q.X, q.Z) < reach then return true end
			end
		end
	end
	return false
end

-- Can a building stand on this rect (4 ordered corners)? Two questions: the road test above,
-- and -- when the index carries one -- whether something is already standing there. Every
-- zoned seat goes through here, preview and placement alike.
function PlotGeometry.buildingBlocked(index: RoadIndex, corners: { Vector3 }, ownSegId: number?): boolean
	if index.occupied and index.occupied(corners) then
		return true
	end
	return PlotGeometry.rectOnRoad(index, corners, ownSegId)
end

-- ---- the plan pipeline: spans / polygons -> placements ------------------------
-- ONE shared tail for the client preview and the server placer, so what the player
-- sees subdivided is exactly what gets built.

export type Placement = {
	plot: Plot,
	segId: number,
	side: number,
	parcelLots: number, -- packed parcel width in lots
	w: number,          -- building width in lots (trimmed below parcelLots on tight inner curves)
	d: number,          -- building depth in lots
	pivot: CFrame,
	corners: { Vector3 },
	blocked: boolean,   -- would overlap a road / cap / neighbour: drawn red, never built
}

local function project(corners: { Vector3 }, ax: Vector3): (number, number)
	local lo, hi = math.huge, -math.huge
	for _, c in corners do
		local v = c.X * ax.X + c.Z * ax.Z
		if v < lo then lo = v end
		if v > hi then hi = v end
	end
	return lo, hi
end

-- SAT penetration depth of two XZ rects given as 4 ordered corners (0 = separated).
local function rectPenetration(A: { Vector3 }, B: { Vector3 }): number
	local minPen = math.huge
	for _, e in { A[2] - A[1], A[4] - A[1], B[2] - B[1], B[4] - B[1] } do
		local flat = Vector3.new(e.X, 0, e.Z)
		if flat.Magnitude >= 1e-4 then
			local ax = flat.Unit
			local aLo, aHi = project(A, ax)
			local bLo, bHi = project(B, ax)
			local pen = math.min(aHi, bHi) - math.max(aLo, bLo)
			if pen <= 0 then return 0 end
			if pen < minPen then minPen = pen end
		end
	end
	return minPen
end

-- Studs two neighbouring building rects may interpenetrate. On an inner curve the rects
-- converge at the back; every template's house body sits >= ~3.5 studs inside its lot line
-- and well forward of the back corner, so this much only crosses fence lines, never walls.
local NEIGHBOR_TOL = 8

-- Set a placement's parcel + building depth to `dLots`: pull the back edge straight in along
-- each corner's own inward direction and rebuild the footprint, so the green quad and the white
-- building shrink together (the persisted group reads plot.depth, so this survives a reload).
local function setParcelDepth(pl: Placement, dLots: number, keepBuilding: boolean?)
	local plot = pl.plot
	local newDepth = dLots * LOT_STUD
	local function inwardOf(front: Vector3, back: Vector3): Vector3
		local v = Vector3.new(back.X - front.X, 0, back.Z - front.Z)
		return if v.Magnitude < 1e-4 then Vector3.zAxis else v.Unit
	end
	plot.backA = plot.frontA + inwardOf(plot.frontA, plot.backA) * newDepth
	plot.backB = plot.frontB + inwardOf(plot.frontB, plot.backB) * newDepth
	plot.depth = newDepth
	plot.center = (plot.frontA + plot.frontB + plot.backB + plot.backA) / 4
	if keepBuilding then return end -- fill pass: backyard grows, the fitted house stays put
	pl.d = math.clamp(dLots, 2, 5) -- parcel may be deeper than the building; the house caps at 5 lots
	pl.pivot, pl.corners = PlotGeometry.buildingRect(plot, pl.w, pl.d)
end

local function parcelCorners(pl: Placement): { Vector3 }
	local p = pl.plot
	return { p.frontA, p.frontB, p.backB, p.backA }
end

local function parcelDepthLots(pl: Placement): number
	return math.floor(pl.plot.depth / LOT_STUD + 0.5)
end

-- Give up `lots` of frontage from side A (the previous neighbour's side) or side B: front and
-- back edges shorten together and the plot's t-span follows, so the freed frontage is unclaimed.
local function trimParcelSide(plot: Plot, fromA: boolean, lots: number)
	local f = math.min(1, lots * LOT_STUD / math.max(plot.frontage, 1e-3))
	if fromA then
		plot.frontA = plot.frontA:Lerp(plot.frontB, f)
		plot.backA = plot.backA:Lerp(plot.backB, f)
		plot.t0 += (plot.t1 - plot.t0) * f
	else
		plot.frontB = plot.frontB:Lerp(plot.frontA, f)
		plot.backB = plot.backB:Lerp(plot.backA, f)
		plot.t1 -= (plot.t1 - plot.t0) * f
	end
	plot.frontage = (plot.frontB - plot.frontA).Magnitude
	plot.center = (plot.frontA + plot.frontB + plot.backB + plot.backA) / 4
end

-- A building rect on a road (a corner lot poking into the cross street, a road behind the
-- parcel): shrink the PARCEL -- depth, then frontage from either side -- by the fewest whole
-- lots that leave the fitted building clear of every road. False when no 2x2 fits.
-- ponytail: exhaustive over a few dozen trims; only runs for the rare blocked plot.
local function fitOffRoad(index: RoadIndex, pl: Placement): boolean
	local P, D = pl.parcelLots, parcelDepthLots(pl)
	for total = 1, (P - 2) + (D - 2) do
		for dTrim = math.min(total, D - 2), 0, -1 do
			local wTrim = total - dTrim
			if wTrim <= P - 2 then
				for aTrim = wTrim, 0, -1 do
					local trial = table.clone(pl)
					trial.plot = table.clone(pl.plot)
					if dTrim > 0 then setParcelDepth(trial, D - dTrim) end
					if aTrim > 0 then trimParcelSide(trial.plot, true, aTrim) end
					if wTrim > aTrim then trimParcelSide(trial.plot, false, wTrim - aTrim) end
					trial.parcelLots = PlotGeometry.fitLots(trial.plot.frontage)
					trial.w = trial.parcelLots
					trial.pivot, trial.corners = PlotGeometry.buildingRect(trial.plot, trial.w, trial.d)
					if not PlotGeometry.buildingBlocked(index, trial.corners, trial.segId) then
						pl.plot, pl.parcelLots, pl.w, pl.d = trial.plot, trial.parcelLots, trial.w, trial.d
						pl.pivot, pl.corners = trial.pivot, trial.corners
						return true
					end
				end
			end
		end
	end
	return false
end

-- Fit buildings onto packed plots: fitted template sizes; a rect on a road shrinks its parcel
-- until it clears (fitOffRoad); a rect into its neighbour on an inner curve gives up depth,
-- then width -- a house as wide as its parcel keeps the fence line continuous (no gaps), a
-- shallower one on a tight bend reads as a terrace. Only a 2x2 that still collides blocks.
local function finishPlacements(index: RoadIndex, segId: number, side: number, plots: { Plot }): { Placement }
	local out: { Placement } = {}
	local prevCorners: { Vector3 }? = nil
	for _, plot in plots do
		local parcelLots = PlotGeometry.fitLots(plot.frontage)
		local d = PlotGeometry.fitDepthLots(plot.depth)
		local pivot, corners = PlotGeometry.buildingRect(plot, parcelLots, d)
		local pl: Placement = {
			plot = plot, segId = segId, side = side, parcelLots = parcelLots,
			w = parcelLots, d = d, pivot = pivot, corners = corners, blocked = false,
		}
		-- Road first (it moves the parcel), neighbour second: shrinking a centred rect keeps
		-- it inside the one that already cleared the road.
		if PlotGeometry.buildingBlocked(index, corners, segId) and not fitOffRoad(index, pl) then
			pl.blocked = true
		end
		while not pl.blocked and prevCorners and rectPenetration(prevCorners, pl.corners) > NEIGHBOR_TOL do
			if pl.d > 2 then
				pl.d -= 1
			elseif pl.w > 2 then
				pl.w -= 1
			else
				pl.blocked = true
				break
			end
			pl.pivot, pl.corners = PlotGeometry.buildingRect(pl.plot, pl.w, pl.d)
		end
		if not pl.blocked then prevCorners = pl.corners end
		table.insert(out, pl)
	end
	return out
end

-- Plan a constant-depth frontage span (Line / Single mode / group rebuild).
function PlotGeometry.planSpan(index: RoadIndex, seg: any, side: number, t0: number, t1: number, depth: number, targetWidth: number?, uniform: boolean?): { Placement }
	local a, b = PlotGeometry.clampSpan(index, seg, t0, t1, side)
	if not (a and b) then return {} end
	local plots = packRun(seg, side, a, b, targetWidth, uniform, function()
		return depth
	end)
	return finishPlacements(index, seg.id, side, plots)
end

-- The cap's local frame + ring radius: node position, flat outward direction, its left
-- normal (phi = 0 anchor), and the ring radius -- pushed outward until a building's flat
-- front (a chord of the ring) clears the bulb slab.
local function capFrame(seg: any, atEnd: boolean, targetWidth: number?): (Vector3, Vector3, Vector3, number)
	local N = if atEnd then seg.p3 else seg.p0
	local tan = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, if atEnd then 1 else 0)
	local D = Vector3.new(tan.X, 0, tan.Z)
	D = if D.Magnitude < 1e-4 then Vector3.xAxis else D.Unit
	if not atEnd then D = -D end
	local n1 = Vector3.new(-D.Z, 0, D.X)
	local spec = RoadTypeCatalog.getOrDefault(seg.roadType)
	local discR = spec.width * 0.5 + 2
	local targetLots = math.clamp(math.round((targetWidth or DEFAULT_PLOT_WIDTH) / LOT_STUD), 2, 5)
	local chord = math.min(5, targetLots + 1) * LOT_STUD -- mixed packing can widen one plot a lot
	local R = frontOffset(seg.roadType)
	while R * math.cos(math.min(1.4, chord * 0.5 / R)) < discR + 1 and R < discR + 64 do
		R += 2
	end
	return N, D, n1, R
end

-- Ring radius only (the client sizes its cap pick range from this).
function PlotGeometry.capRingRadius(seg: any, targetWidth: number?): number
	local _, _, _, R = capFrame(seg, true, targetWidth)
	return R
end

-- Arc-fraction window for ONE plot of `width` centred where the cursor points around the
-- cap, slid to stay inside [0,1] -- the ring version of spanForWidth, so the player picks
-- WHERE on the turnaround the house goes.
function PlotGeometry.capSpanForWidth(seg: any, atEnd: boolean, P: Vector3, width: number): (number, number)
	local N, D, n1, R = capFrame(seg, atEnd, width)
	local vx, vz = P.X - N.X, P.Z - N.Z
	local phi = math.atan2(vx * D.X + vz * D.Z, vx * n1.X + vz * n1.Z) -- 0 at n1, pi/2 at the tip
	local frac = math.clamp(phi / math.pi, 0, 1)
	local half = math.min(0.5, math.max(MIN_PLOT_WIDTH, width) * 0.5 / (math.pi * R))
	local a0 = math.clamp(frac - half, 0, math.max(0, 1 - 2 * half))
	return a0, math.min(1, a0 + 2 * half)
end

-- Houses ringing a dead-end bulb: the frontage is a half-circle beyond the cap, from
-- beside one kerb around the tip to the other. a0/a1 in [0,1] select an arc range (the
-- cap's own occupancy lane). Plots pack along the arc facing the turnaround. Persisted
-- with side 2 (cap at the end node) / -2 (at the start node).
function PlotGeometry.planCapRing(index: RoadIndex, seg: any, atEnd: boolean, a0: number, a1: number, depth: number, targetWidth: number?, uniform: boolean?): { Placement }
	if a1 < a0 then a0, a1 = a1, a0 end
	a0 = math.max(a0, 0)
	a1 = math.min(a1, 1)
	if a1 - a0 < 1e-3 then return {} end
	local N, D, n1, R = capFrame(seg, atEnd, targetWidth)
	local pts: { Vector3 } = {}
	local tans: { Vector3 } = {}
	local cum: { number } = {}
	local total = 0
	for i = 0, SAMPLES do
		local phi = (a0 + (a1 - a0) * (i / SAMPLES)) * math.pi
		local dir = n1 * math.cos(phi) + D * math.sin(phi)
		pts[i + 1] = Vector3.new(N.X + dir.X * R, N.Y, N.Z + dir.Z * R)
		tans[i + 1] = -n1 * math.sin(phi) + D * math.cos(phi) -- arc tangent; +90 deg = radially outward
		if i > 0 then
			total += (pts[i + 1] - pts[i]).Magnitude
		end
		cum[i + 1] = total
	end
	local front: SpanSamples = { pts = pts, tans = tans, cum = cum, total = total, t0 = a0, t1 = a1 }
	local plots = cutPlots(front, 1, targetWidth, uniform, function()
		return depth
	end)
	return finishPlacements(index, seg.id, if atEnd then 2 else -2, plots)
end

-- ---- area zoning: a polygon selection -> rows of parcels ----------------------
-- Rows are planned LONGEST FRONTAGE FIRST and each one claims the ground it covers, so a
-- block fills the way a planner would draw it: the long sides get full rows that meet in the
-- middle, a short end whose ground the long rows already took gets nothing, and the corner
-- wedges those rows cannot reach are exactly what is left for the ends. A final pass deepens
-- every parcel into ground nobody claimed, so the selection comes out covered instead of
-- ringed with stranded grass.

local MIN_PARCEL_DEPTH = 2 * LOT_STUD -- the smallest (2-lot) building must fit
-- A frontage line this far OUTSIDE the drawn shape still counts: players draw the area over
-- the ground they want built on, not along the kerb, so the offset front line lands short of
-- their edge. Without it a shape drawn inside the block zones nothing at all.
local POLY_TOL   = 2 * LOT_STUD
-- Fill ceiling: a leftover strip thinner than a parcel can never be a row of its own, so the
-- parcel in front of it swallows it (backyard -- the house caps at 5 lots either way).
local FILL_DEPTH = MAX_PARCEL_DEPTH + MIN_PARCEL_DEPTH

-- A parcel this plan has already placed. Ground under a claim is spoken for.
type Claim = { pts: { Vector3 }, minX: number, maxX: number, minZ: number, maxZ: number }

-- Point-in-polygon on XZ (even-odd rule).
local function pointInPoly(poly: { Vector3 }, x: number, z: number): boolean
	local inside = false
	local n = #poly
	local j = n
	for i = 1, n do
		local a, b = poly[i], poly[j]
		if (a.Z > z) ~= (b.Z > z) then
			local t = (z - a.Z) / (b.Z - a.Z)
			if x < a.X + (b.X - a.X) * t then inside = not inside end
		end
		j = i
	end
	return inside
end

-- Flat distance from (x, z) to the nearest polygon edge.
local function distToPoly(poly: { Vector3 }, x: number, z: number): number
	local best = math.huge
	local n = #poly
	local j = n
	for i = 1, n do
		local a, b = poly[i], poly[j]
		local eX, eZ = b.X - a.X, b.Z - a.Z
		local len2 = eX * eX + eZ * eZ
		local u = if len2 > 1e-9 then math.clamp(((x - a.X) * eX + (z - a.Z) * eZ) / len2, 0, 1) else 0
		local dx, dz = x - (a.X + eX * u), z - (a.Z + eZ * u)
		local d = math.sqrt(dx * dx + dz * dz)
		if d < best then best = d end
		j = i
	end
	return best
end

local function inSelection(poly: { Vector3 }, p: Vector3): boolean
	return pointInPoly(poly, p.X, p.Z) or distToPoly(poly, p.X, p.Z) <= POLY_TOL
end

-- Distance along flat unit `dir` from `origin` to the segment a->b (nil = not ahead of it).
local function rayEdgeHit(origin: Vector3, dir: Vector3, a: Vector3, b: Vector3): number?
	local eX, eZ = b.X - a.X, b.Z - a.Z
	local den = dir.X * eZ - dir.Z * eX
	if math.abs(den) < 1e-6 then return nil end
	local wX, wZ = a.X - origin.X, a.Z - origin.Z
	local t = (wX * eZ - wZ * eX) / den
	local s = (wX * dir.Z - wZ * dir.X) / den
	if t > 1e-4 and s >= 0 and s <= 1 then return t end
	return nil
end

-- How far inward the selection reaches from `origin`: the end of the polygon interval this
-- frontage sits in. From a front line just outside the shape (within POLY_TOL) the gap in
-- front of the player's edge counts too, so the parcel covers the ground they drew over.
local function polyRun(poly: { Vector3 }, origin: Vector3, dir: Vector3): number?
	local hits: { number } = {}
	local n = #poly
	local j = n
	for i = 1, n do
		local t = rayEdgeHit(origin, dir, poly[i], poly[j])
		if t then hits[#hits + 1] = t end
		j = i
	end
	if #hits == 0 then return nil end
	table.sort(hits)
	if pointInPoly(poly, origin.X, origin.Z) then return hits[1] end
	if hits[1] > POLY_TOL then return nil end -- the shape is not in front of this frontage
	return hits[2]
end

local function refreshClaim(c: Claim, plot: Plot): Claim
	c.pts = { plot.frontA, plot.frontB, plot.backB, plot.backA }
	c.minX, c.maxX, c.minZ, c.maxZ = math.huge, -math.huge, math.huge, -math.huge
	for _, p in c.pts do
		c.minX = math.min(c.minX, p.X); c.maxX = math.max(c.maxX, p.X)
		c.minZ = math.min(c.minZ, p.Z); c.maxZ = math.max(c.maxZ, p.Z)
	end
	return c
end

local function claimOf(plot: Plot): Claim
	return refreshClaim({ pts = {}, minX = 0, maxX = 0, minZ = 0, maxZ = 0 }, plot)
end

-- Distance from `origin` along `dir` to the nearest parcel an earlier row already claimed
-- (`skip` = the claim this parcel owns). math.huge when the ground ahead is free.
local function claimDist(claims: { Claim }, origin: Vector3, dir: Vector3, reach: number, skip: Claim?): number
	local eX, eZ = origin.X + dir.X * reach, origin.Z + dir.Z * reach
	local rMinX, rMaxX = math.min(origin.X, eX), math.max(origin.X, eX)
	local rMinZ, rMaxZ = math.min(origin.Z, eZ), math.max(origin.Z, eZ)
	local best = math.huge
	for _, q in claims do
		if q ~= skip and q.minX <= rMaxX and rMinX <= q.maxX and q.minZ <= rMaxZ and rMinZ <= q.maxZ then
			local a = q.pts[4]
			for i = 1, 4 do
				local b = q.pts[i]
				local t = rayEdgeHit(origin, dir, a, b)
				if t and t < best then best = t end
				a = b
			end
		end
	end
	return best
end

-- Claim rays run from the middle of a frontage and from just inside each end -- a claim the
-- centre ray misses still owns the ground under a corner of the parcel. Insets, not the
-- corners themselves: a parcel that merely TOUCHES a perpendicular row at one corner is not
-- blocked by it.
local function frontProbes(a: Vector3, b: Vector3): (Vector3, Vector3, Vector3)
	return (a + b) * 0.5, a:Lerp(b, 0.15), a:Lerp(b, 0.85)
end

-- Last-resort pass: rows claim ground with rays, so a parcel can still end up a few studs
-- into a neighbour on a bend. Shrink the DEEPER parcel a lot at a time until they clear;
-- if even 2-lot rows still collide, drop the narrower one.
-- ponytail: O(n^2) with an AABB prefilter -- fine for one polygon's plan (dozens of parcels);
-- spatial-hash if an area ever spans hundreds.
local function resolveParcelOverlaps(out: { Placement })
	local n = #out
	if n < 2 then return end
	local box: { { number } } = table.create(n)
	local function refresh(i: number)
		local p = out[i].plot
		box[i] = {
			math.min(p.frontA.X, p.frontB.X, p.backA.X, p.backB.X),
			math.max(p.frontA.X, p.frontB.X, p.backA.X, p.backB.X),
			math.min(p.frontA.Z, p.frontB.Z, p.backA.Z, p.backB.Z),
			math.max(p.frontA.Z, p.frontB.Z, p.backA.Z, p.backB.Z),
		}
	end
	for i = 1, n do refresh(i) end
	-- Depth only ever decreases (or a parcel is blocked), so state strictly shrinks and the loop
	-- converges; the pass cap is a hard stop, not the expected exit.
	for _ = 1, 32 do
		local changed = false
		for i = 1, n do
			local A = out[i]
			if not A.blocked then
				local ba = box[i]
				for j = i + 1, n do
					local B = out[j]
					local bb = box[j]
					if not B.blocked
						and ba[1] <= bb[2] and bb[1] <= ba[2] and ba[3] <= bb[4] and bb[3] <= ba[4]
						and rectPenetration(parcelCorners(A), parcelCorners(B)) > NEIGHBOR_TOL then
						local ad, bd = parcelDepthLots(A), parcelDepthLots(B)
						local deep, deepI, deepD = A, i, ad
						if bd > ad then deep, deepI, deepD = B, j, bd end
						if deepD <= 2 then -- deeper one is already minimal: shrink the other instead
							if deep == A then deep, deepI, deepD = B, j, bd else deep, deepI, deepD = A, i, ad end
						end
						if deepD > 2 then
							setParcelDepth(deep, deepD - 1)
							refresh(deepI)
						elseif A.parcelLots <= B.parcelLots then
							A.blocked = true
						else
							B.blocked = true
						end
						changed = true
					end
				end
			end
		end
		if not changed then break end
	end
end

type AreaRun = { seg: any, side: number, tA: number, tB: number, len: number }

-- Manor Lords area zoning: the plots a node-polygon generates.
function PlotGeometry.planPolygon(segments: { [any]: any }, index: RoadIndex, poly: { Vector3 }, targetWidth: number?, uniform: boolean?): { Placement }
	local out: { Placement } = {}
	if #poly < 3 then return out end
	local pMinX, pMaxX, pMinZ, pMaxZ = math.huge, -math.huge, math.huge, -math.huge
	for _, p in poly do
		pMinX = math.min(pMinX, p.X); pMaxX = math.max(pMaxX, p.X)
		pMinZ = math.min(pMinZ, p.Z); pMaxZ = math.max(pMaxZ, p.Z)
	end

	-- Clear ground ahead of `origin` before the first road slab: a backyard must never pave
	-- across the street on the far side of the block.
	local function roadDist(origin: Vector3, inward: Vector3, cap: number): number
		local d = LOT_STUD
		while d <= cap do
			if PlotGeometry.rectBlocked(index, { Vector3.new(origin.X + inward.X * d, origin.Y, origin.Z + inward.Z * d) }) then
				return d - LOT_STUD
			end
			d += LOT_STUD
		end
		return cap
	end

	-- Every frontage run the selection covers, longest first: the long side of a block is
	-- planned before anything else is allowed to claim the same ground.
	local runs: { AreaRun } = {}
	for _, seg in segments do
		local reach = frontOffset(seg.roadType) + MAX_PARCEL_DEPTH
		if math.max(seg.p0.X, seg.p1.X, seg.p2.X, seg.p3.X) + reach < pMinX
			or math.min(seg.p0.X, seg.p1.X, seg.p2.X, seg.p3.X) - reach > pMaxX
			or math.max(seg.p0.Z, seg.p1.Z, seg.p2.Z, seg.p3.Z) + reach < pMinZ
			or math.min(seg.p0.Z, seg.p1.Z, seg.p2.Z, seg.p3.Z) - reach > pMaxZ then
			continue
		end
		for _, side in { 1, -1 } do
			local a, b = PlotGeometry.clampSpan(index, seg, 0, 1, side)
			if not (a and b) then continue end
			local front = sampleLine(seg, side, frontOffset(seg.roadType, side), a, b)
			local runStart: number? = nil
			for i = 1, #front.pts do
				local hit = inSelection(poly, front.pts[i])
				if hit and not runStart and i < #front.pts then
					runStart = front.cum[i]
				elseif runStart and (not hit or i == #front.pts) then
					local runEnd = front.cum[i]
					if runEnd - runStart >= MIN_PARCEL_DEPTH then
						local _, _, tA = lineAt(front, runStart)
						local _, _, tB = lineAt(front, runEnd)
						table.insert(runs, { seg = seg, side = side, tA = tA, tB = tB, len = runEnd - runStart })
					end
					runStart = nil
				end
			end
		end
	end
	table.sort(runs, function(x, y) return x.len > y.len end)

	local claims: { Claim } = {}
	local own: { [number]: Claim } = {} -- index in `out` -> the claim that parcel owns

	-- Half the OPEN ground, all of the ground that ends at a row already placed. Two
	-- frontages facing each other across a block therefore meet in the middle instead of the
	-- first one taking the lot, and a frontage whose ground is already claimed comes back nil
	-- -- which is how a short end drops out once the long sides have covered it. Whatever no
	-- second row wanted is handed back by the fill pass below.
	local function depthFor(mid: Vector3, inward: Vector3, fA: Vector3, fB: Vector3): number?
		local avail = polyRun(poly, mid, inward)
		if not avail then return nil end
		local space = math.min(avail, MAX_PARCEL_DEPTH)
		local pMid, pA, pB = frontProbes(fA, fB)
		local claimed = math.min(
			claimDist(claims, pMid, inward, space),
			claimDist(claims, pA, inward, space),
			claimDist(claims, pB, inward, space))
		space = math.min(space, claimed, roadDist(mid, inward, space))
		if claimed == math.huge then
			space = math.max(space * 0.5, math.min(space, MIN_PARCEL_DEPTH))
		end
		if space < MIN_PARCEL_DEPTH then return nil end
		return space
	end

	for _, run in runs do
		local plots = packRun(run.seg, run.side, run.tA, run.tB, targetWidth, uniform, depthFor)
		for _, pl in finishPlacements(index, run.seg.id, run.side, plots) do
			table.insert(out, pl)
			if not pl.blocked then
				local c = claimOf(pl.plot)
				own[#out] = c
				table.insert(claims, c)
			end
		end
	end

	-- Fill: give every parcel the free ground behind it. Rows planned early only took half a
	-- block in case a facing row wanted the rest -- this is where the ones nobody answered
	-- get it back, and where a block interior no second row reached stops being bare grass.
	for i, pl in out do
		local c = own[i]
		if not c then continue end
		local plot = pl.plot
		local inward = (plot.backA - plot.frontA) + (plot.backB - plot.frontB)
		inward = Vector3.new(inward.X, 0, inward.Z)
		if inward.Magnitude < 1e-4 then continue end
		inward = inward.Unit
		local pMid, pA, pB = frontProbes(plot.frontA, plot.frontB)
		local avail = polyRun(poly, pMid, inward)
		if not avail then continue end
		local cap = if avail <= FILL_DEPTH then avail else MAX_PARCEL_DEPTH
		local room = math.min(cap,
			claimDist(claims, pMid, inward, cap, c),
			claimDist(claims, pA, inward, cap, c),
			claimDist(claims, pB, inward, cap, c),
			roadDist(pMid, inward, cap))
		local lots = math.floor(room / LOT_STUD + 1e-3)
		if lots * LOT_STUD > plot.depth + 1e-3 then
			setParcelDepth(pl, lots, true)
			refreshClaim(c, plot)
		end
	end

	resolveParcelOverlaps(out)
	return out
end
return PlotGeometry
