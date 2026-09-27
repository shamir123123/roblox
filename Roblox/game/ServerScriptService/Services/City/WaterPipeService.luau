--!strict
-- WaterPipeService
-- Owns the city's mains: the ones under every road, the ones the player draws by hand, and
-- which of them are actually fed.
--
-- The rules:
--   * EVERY ROAD CARRIES BOTH MAINS. Laying a street lays water and sewage under it, the
--     way it already lays lighting and drainage. The player never plumbs a suburb pipe by
--     pipe -- they run ONE main from the tower to any road and the whole network is on.
--   * A hand-drawn run exists for what roads cannot do: reaching a tower standing in a
--     field, or crossing open ground between two streets.
--   * Mains join by TOUCHING. Anything within PipeSnapDist of anything else is one network,
--     roads included -- no node, no junction, no snapping ritual.
--   * A network is LIVE for a kind once it touches a TAP of that kind: the standpipe under
--     a WaterTower for "Water", under a SewagePlant for "Sewage". A network with no tap is
--     STRANDED, and the loose ends of hand-drawn runs carry the badge that says so.
--   * A main carries the service PipeReach studs either side of itself. The pipe is the
--     delivery; a tower with nothing plugged into it serves nobody.
--
-- Road mains are NOT built as instances here. They are geometry the client already has, so
-- the client draws them (WaterPipeController) only while the water view is open and this
-- service only reasons about them -- otherwise a city of streets would replicate thousands
-- of cylinders nobody can see.
--
-- A hand-drawn run is a cubic Bezier, the same four control points the road tool draws
-- with, so straight/curved/advanced/freeform all land here as one shape.

local Players             = game:GetService("Players")
local Workspace           = game:GetService("Workspace")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ServiceTypes     = require(ReplicatedStorage.City.ServiceTypes)
local RoadConstants    = require(ReplicatedStorage.Road.RoadConstants)
local PipeArt          = require(ReplicatedStorage.City.PipeArt)
local BezierUtil       = require(ReplicatedStorage.Road.BezierUtil)
local PlacementFit     = require(ReplicatedStorage.Shared.PlacementFit)
local NetMiddleware    = require(ReplicatedStorage:WaitForChild("NetMiddleware"))
local TerrainDataService = require(ServerScriptService.Services.Terrain.TerrainDataService)

local WaterPipeService = {}

local CELL      = 16   -- served raster cell, studs (matches CoverageService and WaterService)
local REACH     = ServiceTypes.PipeReach
local SNAP      = ServiceTypes.PipeSnapDist
local SRC_REACH = ServiceTypes.PipeSourceReach
local SPAN      = ServiceTypes.PipeSpan
local MAX_RUN   = ServiceTypes.PipeMaxRun
local PLACE_COOLDOWN = 0.15

-- Sampling. Everything downstream -- joining, stamping, geometry -- works off a polyline, so
-- a curve and a straight are the same problem below this line. The step must stay under
-- SNAP or two mains could cross between samples and not notice each other.
local SAMPLE_STEP = 12
local SAMPLE_MAX  = 64

-- Geometry of a HAND-DRAWN run. BURIED: every main lies PipeDepth under the surface, and
-- the pipe tool turns the ground see-through to show them.
local THICK    = 2.4
local DEPTH    = ServiceTypes.PipeDepth
local ROAD_SINK = 3.0 -- studs deeper where it runs under a carriageway, so it never pokes through
local LATERAL  = 1.7  -- how far apart the two mains sit when one trench carries both
local CAP_H    = 5.5
local TAP_H    = 4.5

local WATER_COLOR  = PipeArt.WATER
local SEWAGE_COLOR = PipeArt.SEWAGE

type Seg = {
	id: number,
	p: { Vector3 },   -- four control points, flattened to y = 0
	pts: { Vector3 }, -- the sampled polyline, cached: a laid run never moves
	water: boolean,
	sewage: boolean,
}

-- One entry per main in the network pass: a hand-drawn run or a road.
type Main = { pts: { Vector3 }, water: boolean, sewage: boolean, seg: number? }

-- Which card lays what. The key rides the placement remote, so this is also the whitelist.
local CARD: { [string]: { water: boolean, sewage: boolean } } = table.freeze({
	WaterPipe   = table.freeze({ water = true,  sewage = false }),
	SewagePipe  = table.freeze({ water = false, sewage = true  }),
	UtilityPipe = table.freeze({ water = true,  sewage = true  }),
})

local _serviceBuildings : any -- EmergencyService: owns the towers and plants
local _economyService   : any
local _roadService      : any
local _folder           : Folder
local _caps             : Folder
local _taps             : Folder

local _segs   : { [number]: Seg } = {}
local _nextId = 0
local _lastPlaceAt : { [Player]: number } = {}
local _capByKey : { [string]: Model } = {}
local _servedCell : { [string]: { [string]: boolean } } = { Water = {}, Sewage = {} }
-- The served set only changes when the GEOMETRY does -- a run laid, a road drawn, a tower
-- placed. Rationing is WaterService's job and does not move a pipe, so a rebuild that would
-- produce the same answer is skipped outright. Without this the road mains re-stamp a
-- city's worth of cells twice a second for nothing.
local _dirty = true
-- Where every tap stands, as one string. Compared rather than the COUNT: a tower moved, or
-- one demolished and another placed between two passes, left the count alone and the whole
-- network fed from a tap that was no longer there.
local _tapSig = ""

local function flatDist(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function cellKey(cx: number, cz: number): string
	return tostring(cx) .. "|" .. tostring(cz)
end

local function groundAt(x: number, z: number): number
	local ok, y = pcall(TerrainDataService.getSurfaceY, x, z)
	return if ok and typeof(y) == "number" then y else 0
end

-- Joints are positions, not ids: two runs drawn to the same spot on different days are one
-- joint. Rounded to SNAP so the key is stable between rebuilds.
local function jointKey(p: Vector3): string
	return tostring(math.floor(p.X / SNAP + 0.5)) .. "@" .. tostring(math.floor(p.Z / SNAP + 0.5))
end

local function sampleCurve(p: { Vector3 }): { Vector3 }
	local chord = flatDist(p[1], p[2]) + flatDist(p[2], p[3]) + flatDist(p[3], p[4])
	local steps = math.clamp(math.ceil(chord / SAMPLE_STEP), 1, SAMPLE_MAX)
	local out = table.create(steps + 1)
	for i = 0, steps do
		local q = BezierUtil.point(p[1], p[2], p[3], p[4], i / steps)
		out[i + 1] = Vector3.new(q.X, 0, q.Z)
	end
	return out
end

local function polyLength(pts: { Vector3 }): number
	local total = 0
	for i = 1, #pts - 1 do total += flatDist(pts[i], pts[i + 1]) end
	return total
end

local function ensureFolder(): Folder
	local city = Workspace:FindFirstChild("_City")
	if not city then city = Instance.new("Folder"); city.Name = "_City"; city.Parent = Workspace end
	local f = city:FindFirstChild("WaterPipes")
	if not f or not f:IsA("Folder") then
		if f then f:Destroy() end
		f = Instance.new("Folder"); f.Name = "WaterPipes"; f.Parent = city
	end
	local function sub(name: string): Folder
		local c = f:FindFirstChild(name)
		if not c or not c:IsA("Folder") then
			if c then c:Destroy() end
			c = Instance.new("Folder"); c.Name = name; c.Parent = f
		end
		return c :: Folder
	end
	-- NoPowerView watches PipeEnds BY NAME for the stranded badge; renaming it here without
	-- renaming it there silently drops every warning icon.
	_caps = sub("PipeEnds")
	_taps = sub("Taps")
	return f :: Folder
end

-- == Taps ======================================================================
-- Where a main plugs into a tower or a plant. CS puts a visible stub at the foot of the
-- building and you connect to THAT, not to the building -- without it the player is asked
-- to hit a 32-stud model dead on with nothing telling them where.

type Tap = { pos: Vector3, kind: string, skirt: number }

local function taps(): { Tap }
	local out: { Tap } = {}
	if not _serviceBuildings or not _serviceBuildings.list then return out end
	for _, b in _serviceBuildings.list() do
		local spec = ServiceTypes.get(b.key)
		if not spec then continue end
		local kind: string? = nil
		if (tonumber((spec :: any).waterOutput) or 0) > 0 then kind = "Water"
		elseif (tonumber((spec :: any).sewageCapacity) or 0) > 0 then kind = "Sewage" end
		if not kind then continue end
		local fp = ServiceTypes.footprintStuds(spec)
		local p = (b.cf * CFrame.new(0, 0, fp.Z * 0.5 + 4)).Position
		out[#out + 1] = {
			pos = Vector3.new(p.X, 0, p.Z),
			kind = kind,
			skirt = SRC_REACH + math.max(fp.X, fp.Z) * 0.5,
		}
	end
	return out
end

local function drawTaps(list: { Tap })
	_taps:ClearAllChildren()
	for _, t in list do
		local y = groundAt(t.pos.X, t.pos.Z)
		local m = Instance.new("Model")
		m.Name = "PipeTap"
		local color = if t.kind == "Water" then WATER_COLOR else SEWAGE_COLOR
		-- A valve: a flanged body down at main depth, a riser up to the surface, and a
		-- bright cap flush with the ground -- the thing a drawn main snaps onto.
		local function disc(name: string, centreY: number, height: number, across: number, c: Color3, mat: Enum.Material): Part
			local p = Instance.new("Part")
			p.Name = name
			p.Shape = Enum.PartType.Cylinder
			p.Anchored = true
			p.CanCollide = false
			p.CanTouch = false
			p.CanQuery = false
			p.CastShadow = false
			p.Material = mat
			p.Color = c
			p.Size = Vector3.new(height, across, across)
			p.CFrame = CFrame.new(t.pos.X, centreY, t.pos.Z) * CFrame.Angles(0, 0, math.rad(90))
			p.Parent = m
			return p
		end
		m.PrimaryPart = disc("Tap", y - DEPTH, TAP_H * 0.5, THICK * 1.6, color, Enum.Material.SmoothPlastic)
		disc("Flange", y - DEPTH + TAP_H * 0.25, 0.6, THICK * 2.1, PipeArt.collarColor(color), Enum.Material.Metal)
		disc("Flange", y - DEPTH - TAP_H * 0.25, 0.6, THICK * 2.1, PipeArt.collarColor(color), Enum.Material.Metal)
		disc("Riser", y - DEPTH * 0.5, DEPTH, THICK * 0.9, color, Enum.Material.SmoothPlastic)
		disc("Cap", y - 0.1, 0.4, THICK * 2.6, color, Enum.Material.Neon)
		m:SetAttribute("TapKind", t.kind)
		m:SetAttribute("TX", t.pos.X)
		m:SetAttribute("TZ", t.pos.Z)
		m.Parent = _taps
	end
end

-- == The network ===============================================================

local function find(parent: { number }, x: number): number
	while parent[x] ~= x do
		parent[x] = parent[parent[x]]
		x = parent[x]
	end
	return x
end

-- Every main in play: the hand-drawn runs, then one per road. Roads carry BOTH.
local function mains(): { Main }
	local out: { Main } = {}
	for id, s in _segs do
		out[#out + 1] = { pts = s.pts, water = s.water, sewage = s.sewage, seg = id }
	end
	local net = _roadService and _roadService.getNetwork and _roadService.getNetwork()
	if net then
		for _, seg in net:getSegments() do
			if typeof(seg.p0) ~= "Vector3" then continue end
			-- Down the middle of the road, where the tool draws and snaps them.
			out[#out + 1] = {
				pts = sampleCurve({ seg.p0, seg.p1, seg.p2, seg.p3 }),
				water = true, sewage = true, seg = nil,
			}
		end
	end
	return out
end

-- Union every main that TOUCHES another, through a hash of their sample points. Touching is
-- the whole rule -- no endpoints, no nodes, no junctions -- so connecting to the network is
-- "run your pipe until it meets a road". The hash is what keeps that O(samples) rather than
-- comparing a city of streets against itself.
local function weld(list: { Main }): { number }
	local n = #list
	local parent = table.create(n)
	for i = 1, n do parent[i] = i end
	local function union(a: number, b: number)
		local ra, rb = find(parent, a), find(parent, b)
		if ra ~= rb then parent[ra] = rb end
	end

	local buckets: { [string]: { number } } = {}
	for i, m in list do
		for _, p in m.pts do
			local k = cellKey(math.floor(p.X / SNAP), math.floor(p.Z / SNAP))
			local b = buckets[k]
			if not b then b = {}; buckets[k] = b end
			-- One entry per main per cell: a road sampled every 12 studs would otherwise
			-- put the same id in the same bucket twice.
			if b[#b] ~= i then b[#b + 1] = i end
		end
	end
	-- Samples are closer together than SNAP, so two mains that cross share a cell or sit in
	-- neighbouring ones; the 3x3 sweep catches the second case.
	for k, b in buckets do
		local cx, cz = string.match(k, "^(-?%d+)|(-?%d+)$")
		local x, z = tonumber(cx), tonumber(cz)
		if not (x and z) then continue end
		for dx = 0, 1 do
			for dz = -1, 1 do
				if dx == 0 and dz < 0 then continue end -- each pair of cells once
				local other = buckets[cellKey(x + dx, z + dz)]
				if not other then continue end
				for _, i in b do
					for _, j in other do
						if i ~= j then union(i, j) end
					end
				end
			end
		end
	end

	local root = table.create(n)
	for i = 1, n do root[i] = find(parent, i) end
	return root
end

function WaterPipeService.hasSource(kind: string): boolean
	for _, t in taps() do
		if t.kind == kind then return true end
	end
	return false
end

local function stampAlong(pts: { Vector3 }, cells: { [string]: boolean })
	for i = 1, #pts - 1 do
		local a, b = pts[i], pts[i + 1]
		-- Half the reach between samples, so consecutive discs overlap and leave no gaps.
		local steps = math.max(1, math.ceil(flatDist(a, b) / (REACH * 0.5)))
		for k = 0, steps do
			local p = a:Lerp(b, k / steps)
			local minCx, maxCx = math.floor((p.X - REACH) / CELL), math.floor((p.X + REACH) / CELL)
			local minCz, maxCz = math.floor((p.Z - REACH) / CELL), math.floor((p.Z + REACH) / CELL)
			for cx = minCx, maxCx do
				for cz = minCz, maxCz do
					local dx = (cx + 0.5) * CELL - p.X
					local dz = (cz + 0.5) * CELL - p.Z
					if dx * dx + dz * dz <= REACH * REACH then cells[cellKey(cx, cz)] = true end
				end
			end
		end
	end
end

local function rebuild()
	-- A tower placed since the last pass has no tap marker yet, and EmergencyService does not
	-- tell this service when it places one.
	local tapList = taps()
	local sig = table.create(#tapList)
	for i, t in tapList do
		sig[i] = string.format("%s%.1f,%.1f", t.kind, t.pos.X, t.pos.Z)
	end
	table.sort(sig)
	local joined = table.concat(sig, ";")
	if joined ~= _tapSig then
		_tapSig = joined
		drawTaps(tapList)
		_dirty = true
	end
	if not _dirty then return end
	_dirty = false

	local list = mains()
	local root = weld(list)

	local fedWater: { [number]: boolean } = {}
	local fedSewage: { [number]: boolean } = {}
	for _, t in tapList do
		local fed = if t.kind == "Water" then fedWater else fedSewage
		for i, m in list do
			for _, p in m.pts do
				if flatDist(p, t.pos) <= t.skirt then fed[root[i]] = true; break end
			end
		end
	end

	local water: { [string]: boolean } = {}
	local sewage: { [string]: boolean } = {}
	for i, m in list do
		if m.water and fedWater[root[i]] then stampAlong(m.pts, water) end
		if m.sewage and fedSewage[root[i]] then stampAlong(m.pts, sewage) end
	end
	_servedCell = { Water = water, Sewage = sewage }

	-- The stranded badge, on the loose ends of a hand-drawn run whose network taps nothing.
	-- A kind with no source anywhere is not in play, so it never contributes one.
	local waterLive = WaterPipeService.hasSource("Water")
	local sewageLive = WaterPipeService.hasSource("Sewage")
	local compOfSeg: { [number]: number } = {}
	for i, m in list do
		if m.seg then compOfSeg[m.seg] = root[i] end
	end
	for key, cap in _capByKey do
		if not cap.Parent then _capByKey[key] = nil; continue end
		local comp = compOfSeg[cap:GetAttribute("OwnerSeg") :: any]
		local stranded = false
		if comp then
			stranded = (cap:GetAttribute("Water") == true and waterLive and not fedWater[comp])
				or (cap:GetAttribute("Sewage") == true and sewageLive and not fedSewage[comp])
		end
		if cap:GetAttribute("Stranded") ~= stranded then cap:SetAttribute("Stranded", stranded) end
	end
end

-- == Geometry (hand-drawn runs only) ===========================================

-- One length of pipe, and (`collar`) the metal collar at its far joint. PipeArt draws both,
-- so a hand-drawn run looks exactly like the road mains the client draws.
local function pipePiece(parent: Model, a: Vector3, b: Vector3, color: Color3, offset: number, collar: boolean)
	local p = Instance.new("Part")
	p.Name = "Pipe"
	if not PipeArt.shapePipe(p, a, b, color, THICK, offset) then p:Destroy(); return end
	p.CanQuery = true -- the bulldozer has to be able to hit it
	p.Parent = parent
	if not parent.PrimaryPart then parent.PrimaryPart = p end
	if not collar then return end
	local c = Instance.new("Part")
	c.Name = "Collar"
	PipeArt.shapeCollar(c, b, b - a, color, THICK, offset)
	c.CanQuery = false
	c.Parent = parent
end

-- Height for a piece at (x, z): on the surface normally, well under it where it crosses a
-- carriageway -- a main drawn across a street used to surface through the tarmac.
local function seatY(x: number, z: number): number
	local y = groundAt(x, z) - DEPTH
	if PlacementFit.onRoad(CFrame.new(Vector3.new(x, y, z)), Vector3.new(4, 4, 4)) then
		y -= ROAD_SINK
	end
	return y
end

local function drawSeg(s: Seg)
	local m = Instance.new("Model")
	m.Name = "Pipe"
	local both = s.water and s.sewage
	local prev: Vector3? = nil
	for i, f in s.pts do
		local pt = Vector3.new(f.X, seatY(f.X, f.Z), f.Z)
		if prev then
			-- A collar every other joint: samples are 12 studs apart, a pipe length ~24.
			local collar = i % 2 == 1 or i == #s.pts
			if s.water then pipePiece(m, prev, pt, WATER_COLOR, if both then -LATERAL else 0, collar) end
			if s.sewage then pipePiece(m, prev, pt, SEWAGE_COLOR, if both then LATERAL else 0, collar) end
		end
		prev = pt
	end
	if not m.PrimaryPart then m:Destroy(); return end
	m:SetAttribute("ServiceId", s.id)
	m:SetAttribute("ServiceKind", "Pipe")
	m:SetAttribute("ServiceName", if both then "Water & Sewage" elseif s.water then "Water Pipe" else "Sewage Pipe")
	for i, c in s.p do
		m:SetAttribute("C" .. tostring(i) .. "X", c.X)
		m:SetAttribute("C" .. tostring(i) .. "Z", c.Z)
	end
	m:SetAttribute("Water", s.water); m:SetAttribute("Sewage", s.sewage)
	m.Parent = _folder
end

-- The standpipe where a hand-drawn run stops. It is what the stranded badge hangs off, so
-- it carries what the run is made of and which run it belongs to.
local function drawCap(pos: Vector3, s: Seg)
	local key = jointKey(pos)
	if _capByKey[key] then return end
	local y = groundAt(pos.X, pos.Z)
	local m = Instance.new("Model")
	m.Name = "PipeEnd"

	local stack: { { color: Color3, offset: number } } = {}
	if s.water then stack[#stack + 1] = { color = WATER_COLOR, offset = if s.sewage then -LATERAL else 0 } end
	if s.sewage then stack[#stack + 1] = { color = SEWAGE_COLOR, offset = if s.water then LATERAL else 0 } end
	for _, e in stack do
		local p = Instance.new("Part")
		p.Name = "Stand"
		p.Shape = Enum.PartType.Cylinder
		p.Anchored = true
		p.CanCollide = false
		p.CanTouch = false
		p.CanQuery = false
		p.CastShadow = false
		p.Material = Enum.Material.SmoothPlastic
		p.Color = e.color
		p.Size = Vector3.new(CAP_H, THICK * 1.35, THICK * 1.35)
		-- A riser from the buried main up to the surface: its top is flush with the ground.
		p.CFrame = CFrame.new(pos.X + e.offset, y - CAP_H * 0.5, pos.Z)
			* CFrame.Angles(0, 0, math.rad(90))
		p.Parent = m
		if not m.PrimaryPart then m.PrimaryPart = p end
	end
	if not m.PrimaryPart then m:Destroy(); return end
	m:SetAttribute("Water", s.water)
	m:SetAttribute("Sewage", s.sewage)
	m:SetAttribute("OwnerSeg", s.id)
	m:SetAttribute("Stranded", false)
	m.Parent = _caps
	_capByKey[key] = m
end

-- ponytail: every hand-drawn run redrawn on any edit. They are a handful per city (roads
-- carry the rest and are drawn client-side), so a per-segment rebuild would be bookkeeping
-- for nothing.
local function redraw()
	for _, c in _folder:GetChildren() do
		if c ~= _caps and c ~= _taps then c:Destroy() end
	end
	_caps:ClearAllChildren()
	table.clear(_capByKey)

	for _, s in _segs do drawSeg(s) end

	-- A cap goes where a run END is not touched by any other hand-drawn run. An end sitting
	-- on a road is a connection, not a dead end -- and it is not stranded either, so it gets
	-- no standpipe and no badge.
	for _, s in _segs do
		for _, p in { s.p[1], s.p[4] } do
			local touched = PlacementFit.onRoad(CFrame.new(p), Vector3.new(SNAP, 4, SNAP))
			if not touched then
				for id, o in _segs do
					if id == s.id then continue end
					for _, q in o.pts do
						if flatDist(q, p) <= SNAP then touched = true; break end
					end
					if touched then break end
				end
			end
			if not touched then drawCap(p, s) end
		end
	end
end

-- == Public ====================================================================

-- Lay one run of `key` pipe along the cubic through `cp` (four control points).
function WaterPipeService.placeRun(key: string, cp: { Vector3 }): (boolean, string?)
	local card = CARD[key]
	if not card then return false, "unknown pipe" end
	local spec = ServiceTypes.get(key)
	if not spec then return false, "unknown pipe" end
	if typeof(cp) ~= "table" or #cp ~= 4 then return false, "bad run" end
	local flat: { Vector3 } = {}
	local half = RoadConstants.MAP_HALF_EXTENT
	for i, c in cp do
		if typeof(c) ~= "Vector3" or c ~= c then return false, "bad run" end
		if math.abs(c.X) > half or math.abs(c.Z) > half then return false, "that is off the map" end
		flat[i] = Vector3.new(c.X, 0, c.Z)
	end

	local pts = sampleCurve(flat)
	local len = polyLength(pts)
	if len < 1 then return false, "that run is too short" end
	if len > MAX_RUN then return false, "that run is too long" end

	local cost = math.ceil(len / SPAN) * spec.cost
	if cost > 0 and _economyService and _economyService.trySpend then
		if not _economyService.trySpend(cost) then return false, "can't afford" end
	end

	_nextId += 1
	_segs[_nextId] = { id = _nextId, p = flat, pts = pts, water = card.water, sewage = card.sewage }
	_dirty = true
	redraw()
	rebuild()
	return true, nil
end

function WaterPipeService.removeSegment(id: number)
	if not _segs[id] then return end
	_segs[id] = nil
	_dirty = true
	redraw()
	rebuild()
end

function WaterPipeService.clear()
	table.clear(_segs)
	table.clear(_capByKey)
	_nextId = 0
	_dirty = true
	_tapSig = "!" -- never a real signature: the next pass redraws the taps for the new city
	_servedCell = { Water = {}, Sewage = {} }
	if _folder then redraw() end
end

-- The road graph changed, so the mains under it did. RoadService fires this.
function WaterPipeService.markDirty()
	_dirty = true
end

-- Rebuild the network synchronously. WaterService calls this at the head of its own pass;
-- it costs nothing on a pass where no geometry moved.
function WaterPipeService.rebuildNow()
	rebuild()
end

-- Does a FED main of this kind reach `pos`. Pure reach -- whether the pool can keep up is
-- WaterService's question, and whether the utility is in play at all is its rule.
function WaterPipeService.servedAt(pos: Vector3, kind: string): boolean
	local cells = _servedCell[kind]
	if not cells then return false end
	return cells[cellKey(math.floor(pos.X / CELL), math.floor(pos.Z / CELL))] == true
end

function WaterPipeService.serialize(): { [string]: any }
	local out: { any } = {}
	for _, s in _segs do
		-- Eight numbers and two flags: a run is a curve on the ground, and its height is
		-- re-read off the terrain on load (which is what makes it survive a re-grade).
		local row: { any } = { w = s.water, s = s.sewage }
		for i, c in s.p do
			row["x" .. tostring(i)] = c.X
			row["z" .. tostring(i)] = c.Z
		end
		table.insert(out, row)
	end
	return { version = 2, nextId = _nextId, segments = out }
end

function WaterPipeService.restore(data: any)
	WaterPipeService.clear()
	if typeof(data) ~= "table" then return end
	local rows = if typeof(data.segments) == "table" then data.segments else data
	_nextId = math.max(0, math.floor(tonumber(data.nextId) or 0))
	for _, row in rows do
		if typeof(row) ~= "table" then continue end
		local p: { Vector3 } = {}
		if row.ax then
			-- v1: a straight run, stored as two ends. Its handles go on the line.
			local ax, az = tonumber(row.ax), tonumber(row.az)
			local bx, bz = tonumber(row.bx), tonumber(row.bz)
			if not (ax and az and bx and bz) then continue end
			local a, b = Vector3.new(ax, 0, az), Vector3.new(bx, 0, bz)
			p = { a, a:Lerp(b, 1 / 3), a:Lerp(b, 2 / 3), b }
		else
			local ok = true
			for i = 1, 4 do
				local x, z = tonumber(row["x" .. tostring(i)]), tonumber(row["z" .. tostring(i)])
				if not (x and z) then ok = false break end
				p[i] = Vector3.new(x, 0, z)
			end
			if not ok then continue end
		end
		_nextId += 1
		_segs[_nextId] = { id = _nextId, p = p, pts = sampleCurve(p), water = row.w == true, sewage = row.s == true }
	end
	_dirty = true
	redraw()
	rebuild()
end

-- == Lifecycle =================================================================

local function canEdit(player: Player): boolean
	if Workspace:GetAttribute("RoadEditOpen") == true then return true end
	return NetMiddleware.GetCachedAttribute(player, "CanEditRoads") == true
end

function WaterPipeService.Init(net: any, serviceBuildings: any, economyService: any?, roadService: any?)
	assert(net, "[WaterPipeService] missing net")
	assert(serviceBuildings, "[WaterPipeService] missing serviceBuildings (EmergencyService)")
	WaterPipeService._net = net
	_serviceBuildings = serviceBuildings
	_economyService = economyService
	_roadService = roadService
	_folder = ensureFolder()
end

function WaterPipeService.Bind()
	local net = WaterPipeService._net

	net.RequestPlaceService.OnServerEvent:Connect(function(player: Player, kind: any, key: any, payload: any)
		if kind ~= "Pipe" then return end -- its own kind: this is a run, not a pivot
		if not canEdit(player) then return end
		local now = os.clock()
		if now - (_lastPlaceAt[player] or 0) < PLACE_COOLDOWN then return end
		_lastPlaceAt[player] = now
		if typeof(key) ~= "string" or typeof(payload) ~= "table" then return end
		local cp = payload.cp
		if typeof(cp) ~= "table" then return end
		local ok, reason = WaterPipeService.placeRun(key, cp)
		if not ok and reason then
			net.Notify:FireClient(player, { text = "Can't build: " .. reason, kind = "danger", duration = 3 })
		end
	end)

	net.RequestRemoveService.OnServerEvent:Connect(function(player: Player, kind: any, id: any)
		if kind ~= "Pipe" then return end
		if not canEdit(player) then return end
		if typeof(id) ~= "number" then return end
		WaterPipeService.removeSegment(id)
	end)

	Players.PlayerRemoving:Connect(function(p) _lastPlaceAt[p] = nil end)
end

return WaterPipeService
