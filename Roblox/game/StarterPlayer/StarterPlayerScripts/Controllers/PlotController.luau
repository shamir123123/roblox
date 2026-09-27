--!strict
-- PlotController
-- Manor Lords burgage zoning tool. Pick a zone, then:
--   Line   drag along the road; the stretch fills with parcels + houses (mixed or exact sizes).
--   Area   drop NODES outlining an area (click to add; click-drag a node to move it; Enter or
--          click the FIRST node to confirm; Backspace/RMB removes the last node, Esc cancels).
--          Road frontage inside the polygon auto-subdivides into parcels whose depth follows
--          the polygon boundary, capped at the deepest building -- Manor Lords style.
--   Single one house per click at the cursor, snapped to the nearest road.
-- The preview IS the placement: parcels (green), fitted buildings (white), blocked (red).
-- Erase (or press E) + click a parcel to remove it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")

local DataCache    = require(ReplicatedStorage:WaitForChild("DataCache"))
local Networker    = require(ReplicatedStorage:WaitForChild("Networker"))
local PlotGeometry = require(ReplicatedStorage.City.PlotGeometry)
local ZoneTypes    = require(ReplicatedStorage.City.ZoneTypes)
local ZoneGrid     = require(ReplicatedStorage.City.ZoneGrid)
local BezierUtil   = require(ReplicatedStorage.Road.BezierUtil)
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local PlacementFit = require(ReplicatedStorage.Shared.PlacementFit)
local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))
local CursorRay = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("CursorRay"))
local UiScratch = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("UiScratch"))

local PlotController = {}

type Plot = PlotGeometry.Plot

-- Plot size is picked in BLOCKS (1 block = 1 lot), not metres: the player asks for 2x3 or
-- 5x5 and gets exactly that. The lot unit follows the buildings that sit on it
-- (ZoneGrid.BUILDING_SCALE), not the road.
local LOT_SIZE    = ZoneGrid.LOT_SIZE
-- Buildable range: 2..5 blocks wide (the building axis), 2..6 deep (building at the front,
-- the rest backyard).
local MIN_WIDTH_B, MAX_WIDTH_B = 2, 5
local MIN_DEPTH_B, MAX_DEPTH_B = 2, 6
local MAX_FLOORS  = 12
local TIERS       = { "Low", "Medium", "High" }
local PICK_MAX_DIST = 90
local THICK       = 0.25
local LIFT        = 0.6
local PREVIEW_COLOR = Color3.fromRGB(120, 205, 140)  -- free frontage (will build)
local BUILDING_COLOR = Color3.fromRGB(228, 242, 232)  -- fitted building footprint inside a plot
local TAKEN_COLOR   = Color3.fromRGB(220, 90, 80)   -- occupied / blocked / erase highlight

local _inited = false
local _bound = false
local _enabled = false
local _activeZone = "Residential"
local _lastNonNoneZone = "Residential"
-- Zoning mode: "Line" paints along the road (spans segments, depth from the D stepper); "Area"
-- drags a box out from the road so the pull-away distance sets plot DEPTH (Manor Lords style);
-- "Single" plops one building per click at the cursor, snapped to the nearest road.
local _mode = "Line"
-- Config-panel params. Width defaults to the NARROWEST parcel (2 lots); houses are real
-- size and floor at PlotGeometry.MIN_HOUSE_LOTS (see snapWidth). Depth stays at 4 --
-- that is backyard, not spacing.
local _widthLots = 2
local _depthLots = 4
-- "Mixed": pack whatever 2..5-lot buildings fit. "Uniform": ONLY exact-W buildings (remainder unzoned).
local _sizeMode = "Mixed"
-- Mirror: every Line drag / Single stamp also lands on the opposite side of the road.
local _mirror = false
local _density = "Low" -- the zone dock's density card; the server gates and validates it
local _maxFloors = 2
local _tier = "Low"
local _coverage = 0.55 -- kept for the drop-in API; unused now buildings are real
local _parking = 0.4
-- A specific catalog building chosen in the picker (zone + footprint + template name). When set,
-- Single mode places THIS building (its own zone/size) instead of a random variant of the active zone.
type BuildingChoice = { zone: string, w: number, d: number, name: string }
local _selectedBuilding: BuildingChoice? = nil

-- Line drag: a continuous painted t-range per road segment.
local _drag: any = nil
-- Area mode: the node polygon being authored (world points on the ground).
local _poly: { Vector3 } = {}
local _dragNode: number? = nil -- polygon node index being dragged
-- Cursor-to-node grab distance, in SCREEN pixels rather than a fixed 6 studs: a stud
-- radius is a huge target up close and an unhittable one zoomed out.
local NODE_PICK_PX = 18
local NODE_PICK_MIN, NODE_PICK_MAX = 2, 30
local MAX_POLY_POINTS = 10

local _placeRemote: RemoteEvent
local _groups: { [number]: any } = {}

local _folder: Folder? = nil
local _preview: { Instance } = {}

local _renderConn: RBXScriptConnection? = nil
local _beganConn: RBXScriptConnection? = nil
local _endedConn: RBXScriptConnection? = nil

-- Terrain surface Y at (x, z), cached in coarse buckets. Plot corners carry the ROAD-edge Y,
-- so previews drawn at that height bury into rising hillsides; draping them over the visible
-- terrain keeps them readable. Cache cleared on tool-open and whenever roads change.
local _terrainYCache: { [string]: number } = {}
local _terrainYCount = 0
local function terrainYAt(x: number, z: number, fallback: number): number
	local key = tostring(math.floor(x * 0.25)) .. ":" .. tostring(math.floor(z * 0.25))
	local cached = _terrainYCache[key]
	if cached then return cached end
	local y = CursorRay.terrainY(x, z) or fallback
	if _terrainYCount > 4096 then
		table.clear(_terrainYCache)
		_terrainYCount = 0
	end
	_terrainYCache[key] = y
	_terrainYCount += 1
	return y
end

-- Height a plot's preview should draw at: the road-edge Y or the highest terrain under the
-- parcel, whichever is higher -- uphill parcels lift over the slope instead of sinking into it.
local function plotDrawY(plot: Plot): number
	local y = math.max(plot.frontA.Y, plot.frontB.Y)
	y = math.max(y, terrainYAt(plot.backA.X, plot.backA.Z, y))
	y = math.max(y, terrainYAt(plot.backB.X, plot.backB.Z, y))
	y = math.max(y, terrainYAt(plot.center.X, plot.center.Z, y))
	return y
end

-- Road index for zoning validity (junction mouths, dead-end caps, road overlap) plus the
-- shared "is this ground taken?" test, so a seat sitting on a hospital, a car park or another
-- building is flagged blocked -- and drawPlacement draws nothing for a blocked seat, which is
-- why one never previews. The server injects the same predicate into its own index.
-- Rebuilt lazily whenever the road network replicates a change.
local _roadIndex: PlotGeometry.RoadIndex? = nil
local function roadIndex(): PlotGeometry.RoadIndex
	local idx = _roadIndex
	if not idx then
		idx = PlotGeometry.buildRoadIndex(DataCache.GetSegments(), PlacementFit.seatOccupied)
		_roadIndex = idx
	end
	return idx
end

local function uniformOn(): boolean
	return _sizeMode == "Uniform"
end

-- Plot width in studs. Blocks in, whole lots out, so the packer's target is a clean lot count.
local function snapWidth(): number
	-- Real-size houses need 3 lots; PlotService applies the same floor.
	local houses = _activeZone == "Residential" and _density ~= "Medium"
	return (if houses then math.max(_widthLots, PlotGeometry.MIN_HOUSE_LOTS) else _widthLots) * LOT_SIZE
end

-- Footprint the tool will place: a picked building's own size in Single mode, else the W/D steppers.
local function activeWidthStuds(): number
	if _mode == "Single" and _selectedBuilding then return _selectedBuilding.w * LOT_SIZE end
	return snapWidth()
end
local function activeDepthStuds(): number
	if _mode == "Single" and _selectedBuilding then return _selectedBuilding.d * LOT_SIZE end
	return _depthLots * LOT_SIZE
end

local function ensureFolder(): Folder
	if _folder and _folder.Parent then return _folder end
	local f = UiScratch.folder("Plots")
	_folder = f
	return f
end

local function roadFilter(): { Instance }
	local roads = CursorRay.cityFolder("Roads")
	return if roads then { roads } else {}
end

-- Zoning picks against ground and road surfaces only, so a building or prop under the cursor
-- never captures the pick. The ground is a collisionless mesh shell, so it cannot be raycast:
-- roads are raycast, the bare ground is marched on the heightmap, nearest wins.
local function groundPoint(): Vector3?
	local r = CursorRay.ray()
	if not r then return nil end
	local hit = CursorRay.hitIn(roadFilter())
	local ground = CursorRay.terrainRay(r.Origin, r.Direction, if hit then hit.Distance else CursorRay.REACH)
	return ground or (if hit then hit.Position else nil)
end

-- Cursor -> road parameter, and the flat distance there. A plain 24-sample scan quantised t
-- to 1/24 of a segment (~8 studs on an auto-split piece), so a drag's ends always landed
-- short of where the player pointed; closestParam refines the same scan with two Newton
-- steps. Distance stays flat XZ -- the cursor is on the ground, the road is not.
local function nearestT(seg: any, P: Vector3): (number, number)
	local t = BezierUtil.closestParam(seg.p0, seg.p1, seg.p2, seg.p3, P, 24)
	local p = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
	local dx, dz = p.X - P.X, p.Z - P.Z
	return t, dx * dx + dz * dz
end

local function sideOf(seg: any, t: number, P: Vector3): number
	local p = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
	local tan = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, t)
	local flat = Vector3.new(tan.X, 0, tan.Z)
	flat = if flat.Magnitude < 1e-4 then Vector3.xAxis else flat.Unit
	local n1 = Vector3.new(-flat.Z, 0, flat.X)
	local toP = Vector3.new(P.X - p.X, 0, P.Z - p.Z)
	return if n1:Dot(toP) >= 0 then 1 else -1
end

local function pickRoad(): (any?, number, number)
	local P = groundPoint()
	if not P then return nil, 0, 1 end
	local segs = DataCache.GetSegments()
	local bestSeg, bestT, bestD = nil, 0, math.huge
	for _, seg in segs do
		local t, d = nearestT(seg, P)
		if d < bestD then bestD = d; bestSeg = seg; bestT = t end
	end
	if not bestSeg or bestD > PICK_MAX_DIST * PICK_MAX_DIST then return nil, 0, 1 end
	return bestSeg, bestT, sideOf(bestSeg, bestT, P)
end

-- Parts of [t0,t1] on (segId,side) not already zoned -- so painting over a gap fills just the gap.
local function freeSubSpans(segId: number, side: number, t0: number, t1: number): { { number } }
	local occ: { { number } } = {}
	for _, g in _groups do
		if g.seg == segId and g.side == side then occ[#occ + 1] = { g.t0, g.t1 } end
	end
	table.sort(occ, function(a, b) return a[1] < b[1] end)
	local free: { { number } } = {}
	local cur = t0
	for _, o in occ do
		if o[2] <= cur or o[1] >= t1 then continue end
		if o[1] > cur then free[#free + 1] = { cur, math.min(o[1], t1) } end
		cur = math.max(cur, o[2])
		if cur >= t1 then break end
	end
	if cur < t1 - 1e-4 then free[#free + 1] = { cur, t1 } end
	return free
end

local function spanOccupied(segId: number, side: number, t0: number, t1: number): boolean
	for _, g in _groups do
		if g.seg == segId and g.side == side and t0 < g.t1 - 1e-4 and t1 > g.t0 + 1e-4 then
			return true
		end
	end
	return false
end

-- Dead-end bulb the cursor points PAST (beyond the tip): the cap-ring placement target.
-- Picks only when the cursor is actually OVER the ring band (ring radius + parcel depth
-- + a hair), so a bulb can never grab the cursor from far away or hijack road hovers.
-- Returns the segment and the cap's occupancy side (2 = end node, -2 = start node).
local function pickCap(): (any?, number)
	local P = groundPoint()
	if not P then return nil, 0 end
	local best: any, bestSide, bestD = nil, 0, math.huge
	for _, disc in roadIndex().discs do
		local segId = disc.segId
		if segId then -- only dead-end caps carry segId (corner discs do not)
			local dx, dz = P.X - disc.x, P.Z - disc.z
			local d = dx * dx + dz * dz
			if d < bestD then
				local seg = DataCache.GetSegmentById(segId)
				if seg then
					local reach = PlotGeometry.capRingRadius(seg, activeWidthStuds()) + activeDepthStuds() + 12
					if d <= reach * reach then
						local atEnd = disc.atEnd == true
						local tan = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, if atEnd then 1 else 0)
						local out = Vector3.new(tan.X, 0, tan.Z)
						out = if out.Magnitude < 1e-4 then Vector3.xAxis else out.Unit
						if not atEnd then out = -out end
						if out.X * dx + out.Z * dz > 0 then -- beyond the tip, not beside the road
							best, bestSide, bestD = seg, if atEnd then 2 else -2, d
						end
					end
				end
			end
		end
	end
	return best, bestSide
end

-- Click beyond a dead end: place ONE house on the ring exactly where the cursor points
-- (the free part of that window). Returns true when the cursor was on a cap (click consumed).
local function placeCapRing(): boolean
	local capSeg, capSide = pickCap()
	if not capSeg then return false end
	if _activeZone == "None" then return true end
	local P = groundPoint()
	if not P then return true end
	local a0, a1 = PlotGeometry.capSpanForWidth(capSeg, capSide == 2, P, activeWidthStuds())
	if #freeSubSpans(capSeg.id, capSide, a0, a1) == 0 then return true end
	_placeRemote:FireServer({
		cells = { { seg = capSeg.id, side = capSide, t0 = a0, t1 = a1 } },
		depth = activeDepthStuds(), width = activeWidthStuds(),
		zone = _activeZone, immediate = true, uniform = uniformOn(), density = _density,
	})
	return true
end

-- ---- rendering ----------------------------------------------------------------

local function makeFill(): Part
	local p = Instance.new("Part")
	p.Anchored = true; p.CanCollide = false; p.CanTouch = false; p.CanQuery = false; p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.Parent = ensureFolder()
	return p
end

local function clearPool(pool: { Instance })
	for _, p in pool do p:Destroy() end
	table.clear(pool)
end

local function drawSeg(a: Vector3, b: Vector3, y: number, color: Color3, pool: { Instance })
	local dir = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	local len = dir.Magnitude
	if len < 0.05 then return end
	local mid = (a + b) * 0.5
	local e = makeFill()
	e.CFrame = CFrame.fromMatrix(Vector3.new(mid.X, y, mid.Z), dir.Unit, Vector3.yAxis)
	e.Size = Vector3.new(len, THICK, 0.7)
	e.Color = color
	e.Transparency = 0.1
	table.insert(pool, e)
end

-- One packed plot's outline (4 straight edges -- each plot is one building wide, so the road curve
-- within it is negligible). Adjacent plots share a side edge, which reads as the lot divider.
local function drawPlotQuad(plot: Plot, color: Color3, pool: { Instance })
	if (plot.frontB - plot.frontA).Magnitude < 1 then return end -- degenerate sliver (clamped past a road end)
	local y = plotDrawY(plot) + LIFT
	drawSeg(plot.frontA, plot.frontB, y, color, pool)
	drawSeg(plot.backA, plot.backB, y, color, pool)
	drawSeg(plot.frontA, plot.backA, y, color, pool)
	drawSeg(plot.frontB, plot.backB, y, color, pool)
end

-- Translucent interior tint for a plot quad, coloured by the zone being placed.
local function drawPlotFill(plot: Plot, color: Color3, pool: { Instance })
	local wV = Vector3.new(plot.frontB.X - plot.frontA.X, 0, plot.frontB.Z - plot.frontA.Z)
	local dV = Vector3.new(plot.backA.X - plot.frontA.X, 0, plot.backA.Z - plot.frontA.Z)
	if wV.Magnitude < 0.1 or dV.Magnitude < 0.1 then return end
	local mid = (plot.frontA + plot.frontB + plot.backA + plot.backB) * 0.25
	local e = makeFill()
	e.CFrame = CFrame.fromMatrix(Vector3.new(mid.X, plotDrawY(plot) + LIFT - 0.1, mid.Z), wV.Unit, Vector3.yAxis)
	e.Size = Vector3.new(wV.Magnitude, THICK, dV.Magnitude)
	e.Color = color
	e.Transparency = 0.65
	table.insert(pool, e)
end

-- Zone whose colour the fill should show (a picked catalog building carries its own zone).
local function fillZone(): string
	return if _mode == "Single" and _selectedBuilding then _selectedBuilding.zone else _activeZone
end

-- One planned placement: parcel quad (green) + fitted building rect (white), or red when
-- blocked (road / cap / neighbour overlap). The plan comes from the SAME PlotGeometry
-- pipeline the server places from, so this preview IS the placement.
local function drawPlacement(pl: PlotGeometry.Placement, pool: { Instance })
	if pl.blocked then return end -- unplaceable: show nothing rather than a red ghost
	local zc = ZoneTypes.getColor(fillZone())
	drawPlotQuad(pl.plot, zc:Lerp(Color3.new(1, 1, 1), 0.45), pool)
	drawPlotFill(pl.plot, zc, pool)
	local c = pl.corners
	local y = plotDrawY(pl.plot) + LIFT
	drawSeg(c[1], c[2], y, BUILDING_COLOR, pool)
	drawSeg(c[2], c[3], y, BUILDING_COLOR, pool)
	drawSeg(c[3], c[4], y, BUILDING_COLOR, pool)
	drawSeg(c[4], c[1], y, BUILDING_COLOR, pool)
end

-- Draw the placements that would fill the FREE parts of [t0,t1] (skips already-zoned
-- frontage; the plan pipeline clamps node ends + flags blocked plots).
local function drawFreePacked(seg: any, side: number, t0: number, t1: number, depthStuds: number, pool: { Instance })
	local idx = roadIndex()
	for _, fr in freeSubSpans(seg.id, side, t0, t1) do
		for _, pl in PlotGeometry.planSpan(idx, seg, side, fr[1], fr[2], depthStuds, snapWidth(), uniformOn()) do
			drawPlacement(pl, pool)
		end
	end
end

-- ---- Area mode: node polygon (Manor Lords) ------------------------------------

-- The area plan walks every road the selection touches, and the preview redraws every frame:
-- replanning that often is wasted work, since the plan only moves when the polygon, the size
-- mode or the roads do.
local _polyPlan: { PlotGeometry.Placement } = {}
local _polyKey  = ""
local _roadsVer = 0

local function polyPlan(): { PlotGeometry.Placement }
	local key = string.format("%d|%.1f|%s|%d", #_poly, snapWidth(), tostring(uniformOn()), _roadsVer)
	for _, p in _poly do
		key ..= string.format("|%.0f,%.0f", p.X, p.Z)
	end
	if key ~= _polyKey then
		_polyKey = key
		_polyPlan = PlotGeometry.planPolygon(DataCache.GetSegments(), roadIndex(), _poly, snapWidth(), uniformOn())
	end
	return _polyPlan
end

local function drawNode(p: Vector3, color: Color3, pool: { Instance }, big: boolean?)
	local e = Instance.new("Part")
	e.Shape = Enum.PartType.Ball
	e.Anchored = true; e.CanCollide = false; e.CanTouch = false; e.CanQuery = false; e.CastShadow = false
	e.Material = Enum.Material.Neon
	e.Size = Vector3.one * (if big then 3.5 else 2.5)
	e.Position = Vector3.new(p.X, p.Y + LIFT + 1, p.Z)
	e.Color = color
	e.Parent = ensureFolder()
	table.insert(pool, e)
end

-- Polygon node the cursor is over (XZ distance).
local function nodeAtCursor(P: Vector3): number?
	local r = CursorRay.pickRadius(P, NODE_PICK_PX, NODE_PICK_MIN, NODE_PICK_MAX)
	local best, bestD = nil, r * r
	for i, p in _poly do
		local dx, dz = p.X - P.X, p.Z - P.Z
		local d = dx * dx + dz * dz
		if d < bestD then bestD = d; best = i end
	end
	return best
end

local function clearPoly()
	table.clear(_poly)
	_dragNode = nil
	clearPool(_preview)
end

-- Confirm the polygon: the server plans the SAME subdivision and builds it.
local function confirmPoly()
	if #_poly < 3 then return end
	local poly = table.clone(_poly)
	clearPoly()
	_placeRemote:FireServer({
		poly = poly, zone = _activeZone, width = snapWidth(),
		uniform = uniformOn(), immediate = false, density = _density,
	})
end

-- Polygon preview: outline + nodes + the live subdivision inside.
local function updatePolyPreview()
	clearPool(_preview)
	local P = groundPoint()
	for i = 1, #_poly do
		local a = _poly[i]
		local b = _poly[if i == #_poly then 1 else i + 1]
		if i < #_poly or #_poly >= 3 then
			drawSeg(a, b, math.max(a.Y, b.Y) + LIFT + 0.5, BUILDING_COLOR, _preview)
		end
	end
	local hover = if P then nodeAtCursor(P) else nil
	for i, p in _poly do
		local isFirst = i == 1 and #_poly >= 3 -- clicking the first node closes + confirms
		drawNode(p, if i == hover then Color3.new(1, 1, 1) elseif isFirst then PREVIEW_COLOR else BUILDING_COLOR, _preview, i == hover or isFirst)
	end
	if #_poly >= 3 then
		for _, pl in polyPlan() do
			if not spanOccupied(pl.segId, pl.side, pl.plot.t0, pl.plot.t1) then
				drawPlacement(pl, _preview)
			end
		end
	end
end

-- ---- hover / drag -------------------------------------------------------------

local function updateHoverStamp()
	clearPool(_preview)
	if not _enabled then return end
	-- Cursor beyond a dead-end tip: preview the cap ring instead of a road-side stamp.
	local capSeg, capSide = pickCap()
	if capSeg then
		if _activeZone == "None" then
			for _, g in _groups do
				if g.seg == capSeg.id and g.side == capSide then
					for _, pl in PlotGeometry.planCapRing(roadIndex(), capSeg, capSide == 2, g.t0, g.t1, g.depth, g.width, g.uniform == true) do
						drawPlotQuad(pl.plot, TAKEN_COLOR, _preview)
					end
					break
				end
			end
			return
		end
		local P = groundPoint()
		if not P then return end
		-- One house-sized window centred on the cursor's spot around the ring.
		local a0, a1 = PlotGeometry.capSpanForWidth(capSeg, capSide == 2, P, activeWidthStuds())
		local free = freeSubSpans(capSeg.id, capSide, a0, a1)
		for _, fr in free do
			for _, pl in PlotGeometry.planCapRing(roadIndex(), capSeg, capSide == 2, fr[1], fr[2], activeDepthStuds(), activeWidthStuds(), uniformOn()) do
				drawPlacement(pl, _preview)
			end
		end
		return
	end
	local seg, tC, side = pickRoad()
	if not seg then return end
	if _activeZone == "None" then
		-- erase: outline the zone under the cursor in red
		for _, g in _groups do
			if g.seg == seg.id and g.side == side and tC >= g.t0 - 1e-3 and tC <= g.t1 + 1e-3 then
				local gseg = DataCache.GetSegmentById(g.seg)
				if gseg then
					for _, plot in PlotGeometry.packPlots(gseg, g.side, g.t0, g.t1, g.depth, g.width, g.uniform == true) do
						drawPlotQuad(plot, TAKEN_COLOR, _preview)
					end
				end
				break
			end
		end
		return
	end
	-- one house preview at the cursor (honours a picked building's size in Single mode).
	-- Only the FREE parts of the span preview -- clicking fills exactly those -- so a gap
	-- between houses shows its infill instead of flagging the whole span red.
	local w = activeWidthStuds()
	local t0, t1 = PlotGeometry.spanForWidth(seg, tC, w)
	local free = freeSubSpans(seg.id, side, t0, t1)
	for _, fr in free do
		for _, pl in PlotGeometry.planSpan(roadIndex(), seg, side, fr[1], fr[2], activeDepthStuds(), w) do
			drawPlacement(pl, _preview)
		end
	end
	if _mirror then
		for _, fr in freeSubSpans(seg.id, -side, t0, t1) do
			for _, pl in PlotGeometry.planSpan(roadIndex(), seg, -side, fr[1], fr[2], activeDepthStuds(), w) do
				drawPlacement(pl, _preview)
			end
		end
	end
end

local function updateDragPreview()
	clearPool(_preview)
	local d = _drag
	if not d then return end
	PlotGeometry.bridgeJoins(d.segMap)
	local depthStuds = _depthLots * LOT_SIZE
	for _, e in d.segMap do
		local a, b = e.tMin, e.tMax
		-- Too short to pack a plot (a click): preview the one-house span finalizeDrag will place.
		if #PlotGeometry.packPlots(e.seg, e.side, a, b, depthStuds, snapWidth(), uniformOn()) == 0 then
			a, b = PlotGeometry.spanForWidth(e.seg, e.tStart or (a + b) * 0.5, snapWidth())
		end
		drawFreePacked(e.seg, e.side, a, b, depthStuds, _preview)
		if _mirror then
			drawFreePacked(e.seg, -e.side, a, b, depthStuds, _preview)
		end
	end
end

local function finalizeDrag()
	local d = _drag
	_drag = nil
	clearPool(_preview)
	if not d or _activeZone == "None" then return end
	-- Again on release: the mouse can come up in the same frame a new segment was entered,
	-- before the preview pass ever saw it.
	PlotGeometry.bridgeJoins(d.segMap)
	local widthStuds = snapWidth()
	local depthStuds = _depthLots * LOT_SIZE

	local entries: { any } = {}
	for _, e in d.segMap do
		entries[#entries + 1] = { seg = e.seg, side = e.side, t0 = e.tMin, t1 = e.tMax, tStart = e.tStart }
	end

	local idx = roadIndex()
	local spans: { any } = {}
	local total = 0
	for _, en in entries do
		local a, b = en.t0, en.t1
		local plots = PlotGeometry.packPlots(en.seg, en.side, a, b, depthStuds, widthStuds, uniformOn())
		if #plots == 0 then
			a, b = PlotGeometry.spanForWidth(en.seg, en.tStart or (en.t0 + en.t1) * 0.5, widthStuds) -- click: one house anchored where the drag began
			total += 1
		else
			total += #plots
		end
		local ca, cb = PlotGeometry.clampSpan(idx, en.seg, a, b, en.side)
		if ca and cb then
			spans[#spans + 1] = { seg = en.seg.id, side = en.side, t0 = ca, t1 = cb }
		end
		if _mirror then
			local ma, mb = PlotGeometry.clampSpan(idx, en.seg, a, b, -en.side)
			if ma and mb then
				spans[#spans + 1] = { seg = en.seg.id, side = -en.side, t0 = ma, t1 = mb }
			end
		end
	end
	if #spans == 0 then return end

	-- A single house (a click or a tiny drag) builds at once; a real painted stretch grows on demand.
	local immediate = total <= 1
	_placeRemote:FireServer({
		cells = spans, depth = depthStuds, width = widthStuds,
		zone = _activeZone, immediate = immediate, uniform = uniformOn(), density = _density,
	})
end

-- Single mode: plop exactly one building at the cursor, snapped to the nearest road frontage.
-- Same server path as a click-stamp, but a drag never grows it into a stretch.
local function placeSingle()
	local sel = _selectedBuilding
	local zone = if sel then sel.zone else _activeZone
	if zone == "None" then return end
	local seg, tC, side = pickRoad()
	if not seg then return end
	local widthStuds = activeWidthStuds()
	local t0, t1 = PlotGeometry.spanForWidth(seg, tC, widthStuds)
	local a, b = PlotGeometry.clampSpan(roadIndex(), seg, t0, t1, side)
	if not (a and b) then return end
	if #freeSubSpans(seg.id, side, a, b) == 0 then return end -- server clips the span to the free gap
	local cells = { { seg = seg.id, side = side, t0 = a, t1 = b } }
	if _mirror then
		local ma, mb = PlotGeometry.clampSpan(roadIndex(), seg, t0, t1, -side)
		if ma and mb and #freeSubSpans(seg.id, -side, ma, mb) > 0 then
			cells[#cells + 1] = { seg = seg.id, side = -side, t0 = ma, t1 = mb }
		end
	end
	_placeRemote:FireServer({
		cells = cells,
		depth = activeDepthStuds(), width = widthStuds,
		zone = zone, immediate = true,
		building = if sel then sel.name else nil,
	})
end

local function eraseAtCursor()
	local capSeg, capSide = pickCap()
	if capSeg then
		for id, g in _groups do
			if g.seg == capSeg.id and g.side == capSide then
				_placeRemote:FireServer({ erase = id })
				break
			end
		end
		return
	end
	local seg, tC, side = pickRoad()
	if not seg then return end
	local best, bestSpan = nil, math.huge
	for id, g in _groups do
		if g.seg == seg.id and g.side == side and tC >= g.t0 - 1e-3 and tC <= g.t1 + 1e-3 then
			local span = g.t1 - g.t0
			if span < bestSpan then bestSpan = span; best = id end
		end
	end
	if best then _placeRemote:FireServer({ erase = best }) end
end

local function onSync(payload: any)
	if typeof(payload) ~= "table" then return end
	if payload.full then table.clear(_groups) end
	if typeof(payload.removed) == "table" then
		for _, id in payload.removed do
			if typeof(id) == "number" then _groups[id] = nil end
		end
	end
	if typeof(payload.groups) == "table" then
		for _, g in payload.groups do
			if typeof(g) == "table" and typeof(g.id) == "number" then
				_groups[g.id] = g
			end
		end
	end
end

-- ---------------------------------------------- public API (drop-in for old tool) ----

function PlotController.Init()
	if _inited then return end
	_inited = true
	_placeRemote = Networker.RequestPlacePlots
	Networker.SyncPlots.OnClientEvent:Connect(onSync)
	DataCache.On("segments", function()
		_roadIndex = nil -- roads changed: the validity index is stale
		_roadsVer += 1   -- ...and so is the cached area plan
		table.clear(_terrainYCache) -- regrades move the ground under cached samples
		_terrainYCount = 0
	end)
	ensureFolder()
end

function PlotController.Bind()
	if _bound then return end
	_bound = true

	-- Right mouse un-zones what it lands on, but the same button orbits the camera, so
	-- only a TAP counts -- a drag was aiming the camera, not erasing a plot.
	local RMB_TAP_PX = 6
	local rmbAt: Vector2? = nil

	_beganConn = UserInputService.InputBegan:Connect(function(input: InputObject, gp: boolean)
		if not _enabled or gp then return end
		if Settings.pressed("ToggleZoning", input) then
			if _activeZone == "None" then PlotController.setActiveZone(_lastNonNoneZone) else PlotController.setActiveZone("None") end
			return
		end
		if _mode == "Area" and _activeZone ~= "None" then
			if Settings.pressed("ConfirmArea", input) then
				confirmPoly()
				return
			elseif Settings.pressed("RemoveLastPoint", input) then
				table.remove(_poly)
				return
			elseif Settings.pressed("Back", input) then
				clearPoly()
				return
			end
		end
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			rmbAt = UserInputService:GetMouseLocation()
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			if _activeZone == "None" then
				eraseAtCursor()
			elseif _mode == "Single" then
				if not placeCapRing() then placeSingle() end
			elseif _mode == "Area" then
				local P = groundPoint()
				if P then
					local hit = nodeAtCursor(P)
					if hit == 1 and #_poly >= 3 then
						confirmPoly()
					elseif hit then
						_dragNode = hit
					elseif #_poly < MAX_POLY_POINTS then
						table.insert(_poly, P)
					end
				end
			elseif not placeCapRing() then
				local seg, tC, side = pickRoad()
				if seg then
					_drag = { segMap = { [seg.id] = { seg = seg, side = side, tMin = tC, tMax = tC, tStart = tC } } }
				end
			end
		end
	end)

	_endedConn = UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			_dragNode = nil
			if _drag then finalizeDrag() end
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			local from = rmbAt
			rmbAt = nil
			if not _enabled or not from then return end
			if (UserInputService:GetMouseLocation() - from).Magnitude > RMB_TAP_PX then return end
			if _mode == "Area" and _activeZone ~= "None" and #_poly > 0 then
				table.remove(_poly)
			else
				eraseAtCursor()
			end
		end
	end)

	_renderConn = RunService.RenderStepped:Connect(function()
		if not _enabled then return end
		if _mode == "Area" and _activeZone ~= "None" then
			local dragIdx = _dragNode
			if dragIdx then
				local P = groundPoint()
				if P and _poly[dragIdx] then _poly[dragIdx] = P end
			end
			updatePolyPreview()
			return
		end
		if _drag then
			local seg, tC, side = pickRoad()
			if seg then
				local e = _drag.segMap[seg.id]
				if e then
					e.tMin = math.min(e.tMin, tC)
					e.tMax = math.max(e.tMax, tC)
				else
					_drag.segMap[seg.id] = { seg = seg, side = side, tMin = tC, tMax = tC, tStart = tC }
				end
			end
			updateDragPreview()
		else
			updateHoverStamp()
		end
	end)
end

function PlotController.setEnabled(on: boolean)
	if on == _enabled then return end
	_enabled = on
	if on then
		-- Fresh terrain samples each open: pads/grades reshape ground between sessions.
		table.clear(_terrainYCache)
		_terrainYCount = 0
	end
	if not on then
		_drag = nil
		table.clear(_poly)
		_dragNode = nil
		clearPool(_preview)
	end
end

function PlotController.isEnabled(): boolean
	return _enabled
end

function PlotController.setActiveZone(zone: string)
	_activeZone = zone
	if zone ~= "None" then _lastNonNoneZone = zone end
	local ok, toolStrip = pcall(require, script.Parent.ToolStripController)
	if ok and toolStrip and toolStrip.SetErasing then
		toolStrip.SetErasing(_activeZone == "None")
	end
end

function PlotController.getLastZone(): string
	return _lastNonNoneZone
end

function PlotController.setWidthBlocks(b: number) _widthLots = math.clamp(math.round(b), MIN_WIDTH_B, MAX_WIDTH_B) end
function PlotController.getWidthBlocks(): number return _widthLots end
function PlotController.setDepthBlocks(b: number) _depthLots = math.clamp(math.round(b), MIN_DEPTH_B, MAX_DEPTH_B) end
function PlotController.getDepthBlocks(): number return _depthLots end
function PlotController.setMaxFloors(f: number) _maxFloors = math.clamp(math.floor(f), 1, MAX_FLOORS) end
function PlotController.getMaxFloors(): number return _maxFloors end
function PlotController.setTier(t: string)
	for _, v in TIERS do if v == t then _tier = t; break end end
end
function PlotController.getTier(): string return _tier end
function PlotController.setCoverage(c: number) _coverage = math.clamp(c, 0.2, 1) end
function PlotController.getCoverage(): number return _coverage end
function PlotController.setParking(p: number) _parking = math.clamp(p, 0, 1) end
function PlotController.getParking(): number return _parking end

function PlotController.getMode(): string return _mode end
function PlotController.setMode(mode: string)
	if mode == "Line" or mode == "Area" or mode == "Single" then
		if _mode == "Area" and mode ~= "Area" then
			table.clear(_poly)
			_dragNode = nil
			clearPool(_preview)
		end
		_mode = mode
	end
end

-- Building-size choice: "Mixed" packs whatever 2..5-lot buildings fit the stretch;
-- "Uniform" places ONLY buildings exactly W wide (the remainder stays unzoned).
function PlotController.getSizeMode(): string return _sizeMode end
function PlotController.setSizeMode(mode: string)
	if mode == "Mixed" or mode == "Uniform" then _sizeMode = mode end
end

-- Mirror toggle: Line drags and Single stamps also place on the opposite side of the road.
function PlotController.setMirror(on: boolean) _mirror = on == true end
function PlotController.setDensity(d: string) _density = d end
function PlotController.getMirror(): boolean return _mirror end

-- Picker hook: choose a specific catalog building (or nil to clear back to random variants).
-- Selecting one forces Single mode so the next click plops exactly that building.
function PlotController.setSelectedBuilding(entry: BuildingChoice?)
	_selectedBuilding = entry
	if entry then _mode = "Single" end
end
function PlotController.getSelectedBuilding(): BuildingChoice?
	return _selectedBuilding
end

function PlotController.Unbind()
	if _renderConn then _renderConn:Disconnect(); _renderConn = nil end
	if _beganConn then _beganConn:Disconnect(); _beganConn = nil end
	if _endedConn then _endedConn:Disconnect(); _endedConn = nil end
	_bound = false
end

function PlotController.Cleanup()
	PlotController.Unbind()
	clearPool(_preview)
	_drag = nil
	table.clear(_poly)
	_dragNode = nil
	_enabled = false
end

return PlotController
