--!strict
-- Outside Connections: map-edge road links where the city meets the outside world.
-- A connection is DERIVED, not placed: any road whose endpoint a player drags to the
-- map boundary becomes one. This service scans the live road graph for degree-1 nodes
-- sitting near the edge, registers each, and writes an invisible replicated marker the
-- client view turns into an outward arrow. It re-scans whenever the road
-- topology changes (RoadService.onTopologyChanged) and on city load (CitySerializer
-- calls restore() after roads are back).
--
-- Connections are NOT persisted: they fall out of the road geometry every load, so a
-- map's baked default carries them for free inside its saved roads. Traffic / economy
-- (later phases) enumerate connections here and map them to live road nodes by id.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local TerrainConstants = require(ReplicatedStorage.Terrain.TerrainConstants)
local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)
local Constants = require(ReplicatedStorage.City.OutsideConnectionConstants)
local Types = require(ReplicatedStorage.City.OutsideConnectionTypes)

type Connection = Types.Connection

local OutsideConnectionService = {}

local _roadService: any = nil
local _conns: { [string]: Connection } = {}
local _folder: Folder? = nil
local _topoDisconnect: (() -> ())? = nil
local _rescanScheduled = false

local HALF = TerrainConstants.MAP_HALF_EXTENT
-- A node within this many studs of a boundary counts as touching the edge.
local EDGE_TOLERANCE = 24

-- ---------------------------------------------------------------- geometry ----

-- Outward unit normal (flat) for a map side.
local function sideNormal(side: string): Vector3
	if side == Constants.Side.EAST then return Vector3.new(1, 0, 0)
	elseif side == Constants.Side.WEST then return Vector3.new(-1, 0, 0)
	elseif side == Constants.Side.NORTH then return Vector3.new(0, 0, -1)
	end
	return Vector3.new(0, 0, 1) -- SOUTH
end

-- Which boundary (if any) a node position sits on. Returns the side + outward normal
-- when the node is within EDGE_TOLERANCE of the nearest edge, else nil.
local function edgeSideOf(pos: any): (string?, Vector3?)
	local dEast = HALF - pos.X
	local dWest = pos.X + HALF
	local dNorth = pos.Z + HALF
	local dSouth = HALF - pos.Z
	local m = math.min(dEast, dWest, dNorth, dSouth)
	if m > EDGE_TOLERANCE then return nil, nil end
	local side: string
	if m == dEast then side = Constants.Side.EAST
	elseif m == dWest then side = Constants.Side.WEST
	elseif m == dNorth then side = Constants.Side.NORTH
	else side = Constants.Side.SOUTH end
	return side, sideNormal(side)
end

-- A stable id for a connection at a given edge point: side + the rounded free coord
-- along that edge. Stable across loads (the road stays put even as node ids change),
-- so traffic / economy can key off it. Rounded to 4 studs to absorb re-anchor drift.
local function connId(side: string, pos: any): string
	local free = if side == Constants.Side.EAST or side == Constants.Side.WEST then pos.Z else pos.X
	local q = math.floor(free / 4 + 0.5) * 4
	return string.format("%s%s_%d", Constants.ID_PREFIX, side, q)
end

-- ------------------------------------------------------------- replication ----

local function ensureFolder(): Folder
	if _folder and _folder.Parent then return _folder end
	local f = Workspace:FindFirstChild(Constants.FOLDER_NAME)
	if not (f and f:IsA("Folder")) then
		if f then f:Destroy() end
		f = Instance.new("Folder")
		f.Name = Constants.FOLDER_NAME
		f.Parent = Workspace
	end
	_folder = f :: Folder
	return _folder
end

-- One invisible anchored marker per connection. Replicates automatically (incl. late
-- joiners); the client view renders the arrow from its attributes.
local function writeMarker(c: Connection)
	local f = ensureFolder()
	local existing = f:FindFirstChild(c.id)
	local part: Part
	if existing and existing:IsA("Part") then
		part = existing :: Part
	else
		if existing then existing:Destroy() end
		part = Instance.new("Part")
		part.Name = c.id
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Transparency = 1
		part.Size = Vector3.one
	end
	part.CFrame = CFrame.new(c.outer)
	part:SetAttribute("Side", c.side)
	part:SetAttribute("Dir", c.dir)
	part:SetAttribute("NX", c.normal.X)
	part:SetAttribute("NZ", c.normal.Z)
	part:SetAttribute("RoadType", c.roadType)
	part.Parent = f
end

local function clearMarker(id: string)
	if not _folder then return end
	local m = _folder:FindFirstChild(id)
	if m then m:Destroy() end
end

-- ----------------------------------------------------------------- scan ----

-- Degree of a node = how many segments touch it. A road dragged to the edge ends in a
-- degree-1 node there; only those terminal edge nodes are connections (so a road that
-- merely runs parallel to the edge is not flagged at every joint).
local function segmentCount(node: any): number
	local segs = node.segments
	if typeof(segs) ~= "table" then return 0 end
	return #segs
end

-- The edge node's road type + flow direction. A two-way road is "both"; a one-way road
-- is "in" when traffic ENTERS the city here (the road starts at this edge node) or
-- "out" when it leaves. Drives the client arrow (double-headed vs single).
local function roadInfo(net: any, node: any, nodeId: number): (string, string)
	local segs = node.segments
	local seg = if typeof(segs) == "table" then segs[1] else nil
	local segId = if typeof(seg) == "table" then seg.id else seg
	local segment = segId and net.getSegment and net:getSegment(segId)
	local rt = (segment and typeof(segment.roadType) == "string" and segment.roadType) or Constants.DEFAULT_ROAD_TYPE
	local spec = RoadTypeCatalog.get(rt)
	if spec and spec.oneWay and segment then
		if segment.startNode == nodeId then return rt, Constants.Direction.IN end
		return rt, Constants.Direction.OUT
	end
	return rt, Constants.Direction.BOTH
end

-- Rebuild the connection set from the current road graph. Adds markers for new edge
-- connections, refreshes moved ones, drops gone ones. Idempotent + cheap (O(nodes)).
function OutsideConnectionService.rescan()
	if not _roadService or not _roadService.getNetwork then return end
	local net = _roadService.getNetwork()
	if not net or not net.getNodes then return end

	local seen: { [string]: boolean } = {}
	for nodeId, node in net:getNodes() do
		if node.position and segmentCount(node) == 1 then
			local pos = node.position
			local side, normal = edgeSideOf(pos)
			if side and normal then
				local id = connId(side, pos)
				if not seen[id] then
					seen[id] = true
					local outer = if typeof(pos) == "Vector3" then pos else Vector3.new(pos.X, pos.Y, pos.Z)
					local rt, dir = roadInfo(net, node, nodeId)
					local c = _conns[id]
					if c then
						c.side = side; c.normal = normal; c.outer = outer; c.nodeId = nodeId
						c.roadType = rt; c.dir = dir; c.inner = outer - normal * Constants.STUB_LENGTH
					else
						c = {
							id = id, side = side, normal = normal, dir = dir,
							roadType = rt, outer = outer, nodeId = nodeId,
							inner = outer - normal * Constants.STUB_LENGTH,
						}
						_conns[id] = c
					end
					writeMarker(c)
				end
			end
		end
	end

	-- Drop connections whose road no longer reaches the edge.
	for id in _conns do
		if not seen[id] then
			clearMarker(id)
			_conns[id] = nil
		end
	end
end

-- Coalesce bursts of topology changes (a multi-piece road placement fires many) into
-- one rescan on the next frame.
local function scheduleRescan()
	if _rescanScheduled then return end
	_rescanScheduled = true
	task.defer(function()
		_rescanScheduled = false
		local ok, err = pcall(OutsideConnectionService.rescan)
		if not ok then warn("[OutsideConnectionService] rescan failed: " .. tostring(err)) end
	end)
end

-- ----------------------------------------------------------------- public ----

function OutsideConnectionService.Init(roadService: any, terrainDataService: any)
	assert(roadService, "[OutsideConnectionService] requires RoadService")
	assert(terrainDataService, "[OutsideConnectionService] requires TerrainDataService")
	_roadService = roadService
end

function OutsideConnectionService.Bind()
	if _topoDisconnect then _topoDisconnect() end
	if _roadService and _roadService.onTopologyChanged then
		_topoDisconnect = _roadService.onTopologyChanged(scheduleRescan)
	end
end

function OutsideConnectionService.Start()
	scheduleRescan()
end

function OutsideConnectionService.get(id: string): Connection?
	return _conns[id]
end

function OutsideConnectionService.list(): { Connection }
	local out: { Connection } = {}
	for _, c in _conns do table.insert(out, c) end
	return out
end

-- Stable id owning a given live road node, or nil. For traffic spawn / despawn (Phase 4).
function OutsideConnectionService.idForNode(nodeId: number): string?
	for id, c in _conns do
		if c.nodeId == nodeId then return id end
	end
	return nil
end

-- Drop every connection + marker (city unload).
function OutsideConnectionService.clearAll()
	_conns = {}
	if _folder then _folder:ClearAllChildren() end
end

-- Connections are derived from road geometry, not stored. seedDefaults (fresh city) and
-- restore (loaded / templated city) both just re-scan the road graph; CitySerializer
-- calls restore() AFTER roads are back, so the edge roads exist by then.
function OutsideConnectionService.seedDefaults(_mapId: string?): number
	OutsideConnectionService.rescan()
	local n = 0
	for _ in _conns do n += 1 end
	return n
end

function OutsideConnectionService.serialize(): { any }?
	return nil
end

function OutsideConnectionService.restore(_blob: any)
	OutsideConnectionService.clearAll()
	OutsideConnectionService.rescan()
end

return OutsideConnectionService
