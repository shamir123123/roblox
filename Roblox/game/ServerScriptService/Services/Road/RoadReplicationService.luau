--!strict
-- RoadReplicationService
-- Network boundary for the road domain. Owns every road remote: validates and
-- rate-limits incoming requests, then hands off to RoadService's public API;
-- builds and broadcasts all outgoing payloads (full syncs, topology deltas,
-- turn permissions, lane paths, lane-change gates). No topology logic lives
-- here. Dependencies are injected at init -- this module never requires
-- RoadService, so the require direction stays RoadService -> here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local NetMiddleware = require(ReplicatedStorage.NetMiddleware)
local Types = require(ReplicatedStorage.Road.RoadTypes)

local RoadReplicationService = {}

local CONNECTION_EDIT_COOLDOWN = 0.15
local MAX_EDGE_ID_LEN = 64
local MAX_MOVEMENT_LEN = 16
-- Hard cap on one batched bulldoze request; the client chunks longer sweeps.
local MAX_BATCH_REMOVE = 256

-- Injected at init (see RoadService.Init).
local _roads: any
local _network: any
local _navGraph: any
local _getPermissions: (Types.NodeId) -> any
local _clearPermissions: (Types.NodeId) -> ()
local _armMarkingSetback: (Types.NodeId, Types.SegmentId) -> number

local _placeRemote: RemoteEvent
local _placeRoundaboutRemote: RemoteEvent
local _roundaboutPresetRemote: RemoteEvent
local _placeResultRemote: RemoteEvent
local _syncRemote: RemoteEvent
local _syncSegRemote: RemoteEvent
local _syncInterRemote: RemoteEvent
local _syncNodeDeltaRemote: RemoteEvent
local _syncSegDeltaRemote: RemoteEvent
local _turnPermRemote: RemoteEvent
local _laneTurnPermRemote: RemoteEvent
local _connectionHandleRemote: RemoteEvent
local _connectionRemote: RemoteEvent
local _resetConnectionsRemote: RemoteEvent
local _syncTurnPermRemote: RemoteEvent
local _syncLanePathRemote: RemoteEvent
local _syncLaneChangeRemote: RemoteEvent
local _laneChangeConnRemote: RemoteEvent
local _replaceSegRemote: RemoteEvent
local _removeSegRemote: RemoteEvent
local _removeSegsRemote: RemoteEvent
local _undoRemote: RemoteEvent
local _redoRemote: RemoteEvent
local _moveRemote: RemoteEvent
local _setRoadNameRemote: RemoteEvent
local _roadTrafficRemote: RemoteFunction

local _lastPlaceAt: { [Player]: number } = {}
local _lastConnEditAt: { [Player]: number } = {}
local _lastGateCount = 0
local _lastGateSnapshot: { [string]: any } = {}
local _pendingNodeDelta: { changed: { any }, removed: { number } } = { changed = {}, removed = {} }
local _pendingSegDelta: { changed: { any }, removed: { number } } = { changed = {}, removed = {} }
local _pendingBroadcastNodes: { [Types.NodeId]: boolean } = {}
local _broadcastFlushPending = false

-- ---------------------------------------------------------------- helpers --

local function canPlayerEditRoads(player: Player): boolean
	if workspace:GetAttribute("RoadEditOpen") == true then
		return true
	end
	return NetMiddleware.GetCachedAttribute(player, "CanEditRoads") == true
end

local function canProcessEditNow(player: Player): boolean
	local now = os.clock()
	local last = _lastConnEditAt[player]
	if last and now - last < CONNECTION_EDIT_COOLDOWN then
		return false
	end
	_lastConnEditAt[player] = now
	return true
end

local function placeCooldownActive(player: Player): boolean
	local now = os.clock()
	local last = _lastPlaceAt[player]
	if last and now - last < RoadConstants.PLACE_COOLDOWN then
		return true
	end
	_lastPlaceAt[player] = now
	return false
end

local function validSmallString(v: any, maxLen: number): boolean
	return typeof(v) == "string" and #v > 0 and #v <= maxLen
end

local function isFiniteVector(v: Vector3): boolean
	return v == v and v.Magnitude < math.huge
end

local function inBounds(v: Vector3): boolean
	local h = RoadConstants.MAP_HALF_EXTENT
	return math.abs(v.X) <= h and math.abs(v.Z) <= h
end

-- --------------------------------------------------------------- payloads --

local function isInternalFilletNode(node: any): boolean
	if #node.segments == 0 then
		return true
	end
	if #node.segments ~= 2 then
		return false
	end
	for _, sid in node.segments do
		local seg = _network:getSegment(sid)
		if seg and seg.isArc then
			return true
		end
	end
	return false
end

local function nodePositions(): { { id: number, position: Vector3 } }
	local out: { { id: number, position: Vector3 } } = {}
	for nodeId, node in _network:getNodes() do
		if not isInternalFilletNode(node) then
			table.insert(out, { id = nodeId, position = node.position })
		end
	end
	return out
end

local function segmentData(): { { id: number, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, startNode: number, endNode: number, isRoundabout: boolean? } }
	local out: { { id: number, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, roadType: string, startNode: number, endNode: number, isRoundabout: boolean? } } = {}
	for _, seg in _network:getSegments() do
		table.insert(out, {
			id = seg.id,
			p0 = seg.p0,
			p1 = seg.p1,
			p2 = seg.p2,
			p3 = seg.p3,
			roadType = seg.roadType,
			-- Player-set street name (nil = the client derives the auto name itself).
			name = seg.name,
			startNode = seg.startNode,
			endNode = seg.endNode,
			isRoundabout = seg.isRoundabout,
			-- Client-side road rendering needs the full render-relevant shape of a segment.
			isArc = seg.isArc,
			vMode = seg.vMode,
			roundaboutId = seg.roundaboutId,
			roundaboutCenter = seg.roundaboutCenter,
			roundaboutRadius = seg.roundaboutRadius,
			-- Node-tool shaping: the tool's fields read their current value from here.
			startCorner = seg.startCorner,
			endCorner = seg.endCorner,
			startOffset = seg.startOffset,
			endOffset = seg.endOffset,
			startFlat = seg.startFlat,
			endFlat = seg.endFlat,
		})
	end
	return out
end

local function intersectionCentres(): { { id: number, position: Vector3 } }
	local out: { { id: number, position: Vector3 } } = {}
	for nodeId, node in _network:getNodes() do
		if _network:getNodeKind(nodeId) == "intersection" then
			table.insert(out, { id = nodeId, position = node.position })
		end
	end
	return out
end

local function intersectionTurnData(): { any }
	local out: { any } = {}
	for nodeId, node in _network:getNodes() do
		if _network:getNodeKind(nodeId) == "intersection" then
			local perms = _getPermissions(nodeId)
			table.insert(out, {
				nodeId = nodeId,
				position = node.position,
				left = perms.left == true,
				right = perms.right == true,
				straight = perms.straight == true,
				uturn = perms.uturn == true,
				manual = perms.manual == true,
			})
		else
			_clearPermissions(nodeId)
		end
	end
	return out
end

local function intersectionLanePathData(): { any }
	local out: { any } = {}
	if not _navGraph then
		return out
	end
	for nodeId, node in _network:getNodes() do
		if _network:getNodeKind(nodeId) == "intersection" then
			local dotSetbacks: { [Types.SegmentId]: number } = {}
			for _, sid in node.segments do
				dotSetbacks[sid] = _armMarkingSetback(nodeId, sid) + 1
			end
			local data = _navGraph:GetIntersectionLaneData(nodeId, dotSetbacks)
			data.position = node.position
			table.insert(out, data)
		end
	end
	return out
end

-- ------------------------------------------------------------- broadcasts --

function RoadReplicationService.broadcastNodes(target: Player?)
	local positions = nodePositions()
	local segs = segmentData()
	local centresPayload = { changed = intersectionCentres(), removed = {} }
	if target then
		_syncRemote:FireClient(target, positions)
		_syncSegRemote:FireClient(target, segs)
		_syncInterRemote:FireClient(target, centresPayload)
	else
		_syncRemote:FireAllClients(positions)
		_syncSegRemote:FireAllClients(segs)
		_syncInterRemote:FireAllClients(centresPayload)
	end
end

-- Accumulate topology deltas produced by RoadService.applyChanges until the
-- next broadcastTopologyDeltas flush.
function RoadReplicationService.queueNodeDelta(changed: { any }, removed: { number })
	for _, entry in changed do table.insert(_pendingNodeDelta.changed, entry) end
	for _, id in removed do table.insert(_pendingNodeDelta.removed, id) end
end

function RoadReplicationService.queueSegDelta(changed: { any }, removed: { number })
	for _, entry in changed do table.insert(_pendingSegDelta.changed, entry) end
	for _, id in removed do table.insert(_pendingSegDelta.removed, id) end
end

-- Segment ids queued as changed and not yet flushed. RoadService uses this to
-- pick up split pieces for the incremental nav rebuild.
function RoadReplicationService.pendingChangedSegmentIds(): { number }
	local out: { number } = {}
	for _, entry in _pendingSegDelta.changed do
		table.insert(out, entry.id)
	end
	return out
end

-- Node ids queued as changed and not yet flushed. RoadService uses this to
-- find intersections affected by a placement's crossing resolution.
function RoadReplicationService.pendingChangedNodeIds(): { number }
	local out: { number } = {}
	for _, entry in _pendingNodeDelta.changed do
		table.insert(out, entry.id)
	end
	return out
end

function RoadReplicationService.broadcastTopologyDeltas()
	local nodesDirty = #_pendingNodeDelta.changed > 0 or #_pendingNodeDelta.removed > 0
	local segsDirty  = #_pendingSegDelta.changed  > 0 or #_pendingSegDelta.removed  > 0
	if nodesDirty then
		_syncNodeDeltaRemote:FireAllClients(_pendingNodeDelta)
	end
	if segsDirty then
		_syncSegDeltaRemote:FireAllClients(_pendingSegDelta)
	end

	if nodesDirty then
		local interDelta: { changed: { any }, removed: { number } } = { changed = {}, removed = {} }
		for _, entry in _pendingNodeDelta.changed do
			if _network:getNodeKind(entry.id) == "intersection" then
				table.insert(interDelta.changed, { id = entry.id, position = entry.position })
			else
				-- A node that DOWNGRADED to a corner/dead-end (e.g. one road of an X-crossing was
				-- deleted, dropping it from degree-4 to degree-2) is "changed", not "removed", and is
				-- no longer an intersection. Without this it matched neither branch, so the client
				-- kept its stale snap centre -- you could still snap to an intersection that was gone.
				table.insert(interDelta.removed, entry.id)
			end
		end
		for _, id in _pendingNodeDelta.removed do
			table.insert(interDelta.removed, id)
		end
		_syncInterRemote:FireAllClients(interDelta)
	end
	_pendingNodeDelta = { changed = {}, removed = {} }
	_pendingSegDelta  = { changed = {}, removed = {} }
end

function RoadReplicationService.broadcastTurnPermissions(target: Player?, nodeId: Types.NodeId?)
	if nodeId then
		local node = _network:getNodes()[nodeId]
		if not node or _network:getNodeKind(nodeId) ~= "intersection" then return end
		local perms = _getPermissions(nodeId)
		local payload = { patch = true, entries = { {
			nodeId   = nodeId,
			position = node.position,
			left     = perms.left     == true,
			right    = perms.right    == true,
			straight = perms.straight == true,
			uturn   = perms.uturn    == true,
			manual   = perms.manual   == true,
		} } }
		if target then
			_syncTurnPermRemote:FireClient(target, payload)
		else
			_syncTurnPermRemote:FireAllClients(payload)
		end
	else
		local payload = intersectionTurnData()
		if target then
			_syncTurnPermRemote:FireClient(target, payload)
		else
			_syncTurnPermRemote:FireAllClients(payload)
		end
	end
end

function RoadReplicationService.broadcastLanePaths(target: Player?, nodeId: Types.NodeId?)
	if nodeId and _navGraph then
		local node = _network:getNodes()[nodeId]
		if not node or _network:getNodeKind(nodeId) ~= "intersection" then return end
		local dotSetbacks: { [Types.SegmentId]: number } = {}
		for _, sid in node.segments do
			dotSetbacks[sid] = _armMarkingSetback(nodeId, sid) + 1
		end
		local data = _navGraph:GetIntersectionLaneData(nodeId, dotSetbacks)
		data.position = node.position
		local payload = { patch = true, entries = { data } }
		if target then
			_syncLanePathRemote:FireClient(target, payload)
		else
			_syncLanePathRemote:FireAllClients(payload)
		end
	else
		local payload = intersectionLanePathData()
		if target then
			_syncLanePathRemote:FireClient(target, payload)
		else
			_syncLanePathRemote:FireAllClients(payload)
		end
	end
end

-- The "-$X" tag at a charged placement -- and, on the client, a build sound and a flash of
-- the money readout. That is the ACTOR's own feedback, not city state: broadcast, every
-- player in a shared city got a cost tag and a chime wherever a teammate happened to be
-- working. The road itself still replicates to everyone; only the feedback is theirs.
--
-- No actor means no one to tell (an automated or restored charge), so it stays silent
-- rather than telling everybody.
function RoadReplicationService.broadcastPlacementCharged(pos: Vector3, amount: number, actor: Player?)
	if not actor then return end
	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	Net.PlacementCharged:FireClient(actor, pos, amount, "Road")
end

function RoadReplicationService.broadcastLaneChanges(target: Player?)
	local payload = if _navGraph then _navGraph:GetLaneChangeGateData() else {}
	local currentCount = #payload

	if target then
		_syncLaneChangeRemote:FireClient(target, { full = true, gates = payload })
		return
	end

	if currentCount == _lastGateCount then
		local anyChange = false
		for _, gate in payload do
			if not _lastGateSnapshot[gate.id] then
				anyChange = true
				break
			end
		end
		if not anyChange then
			return
		end
	end
	_lastGateCount = currentCount

	local newSnapshot: { [string]: any } = {}
	for _, gate in payload do
		newSnapshot[gate.id] = gate
	end

	local changed: { any } = {}
	for _, gate in payload do
		if not _lastGateSnapshot[gate.id] then
			table.insert(changed, gate)
		end
	end

	local removed: { string } = {}
	for id in _lastGateSnapshot do
		if not newSnapshot[id] then
			table.insert(removed, id)
		end
	end

	_lastGateSnapshot = newSnapshot

	if #changed == 0 and #removed == 0 then
		return
	end

	_syncLaneChangeRemote:FireAllClients({ full = false, changed = changed, removed = removed })
end

local function flushPendingBroadcasts()
	_broadcastFlushPending = false
	local nodes = _pendingBroadcastNodes
	_pendingBroadcastNodes = {}
	for nodeId in nodes do
		if _network:getNodes()[nodeId] and _network:getNodeKind(nodeId) == "intersection" then
			RoadReplicationService.broadcastTurnPermissions(nil, nodeId)
			RoadReplicationService.broadcastLanePaths(nil, nodeId)
		end
	end
end

function RoadReplicationService.queueIntersectionBroadcast(nodeId: Types.NodeId)
	_pendingBroadcastNodes[nodeId] = true
	if _broadcastFlushPending then return end
	_broadcastFlushPending = true
	task.defer(flushPendingBroadcasts)
end

-- ---------------------------------------------------- incoming handlers --

local function sendPlaceResult(player: Player, ok: boolean, reason: string?)
	_placeResultRemote:FireClient(player, ok, reason)
end

local function onPlaceRequest(player: Player, req: any)
	if not canPlayerEditRoads(player) then
		sendPlaceResult(player, false, "road editing is locked")
		return
	end
	if not NetMiddleware.CheckServerRate(_placeRemote, player) then
		sendPlaceResult(player, false, "placing roads too quickly")
		return
	end
	if placeCooldownActive(player) then
		sendPlaceResult(player, false, "placing roads too quickly")
		return
	end
	local ok, reason = _roads.placeFromRequest(req, player)
	if ok and typeof(req.twin) == "table" then
		-- Parallel mode: a twin road carried in the same request so it shares this one
		-- rate-limit/cooldown. Best-effort -- placeFromRequest re-validates it, and a
		-- rejected twin leaves the primary placed.
		_roads.placeFromRequest({
			roadType = req.roadType,
			p0 = req.twin.p0, p1 = req.twin.p1, p2 = req.twin.p2, p3 = req.twin.p3,
			vMode = req.vMode, constSlope = req.constSlope,
		}, player)
	end
	if not ok then
		warn(`[RoadReplicationService] rejected placement from {player.Name}: {reason}`)
	end
	sendPlaceResult(player, ok, reason)
end

local function onPlaceRoundaboutRequest(player: Player, req: any)
	if not canPlayerEditRoads(player) then
		sendPlaceResult(player, false, "road editing is locked")
		return
	end
	if not NetMiddleware.CheckServerRate(_placeRoundaboutRemote, player) then
		sendPlaceResult(player, false, "placing roads too quickly")
		return
	end
	if placeCooldownActive(player) then
		sendPlaceResult(player, false, "placing roads too quickly")
		return
	end
	local ok, reason = _roads.placeRoundaboutFromRequest(req)
	if not ok then
		warn(`[RoadReplicationService] rejected roundabout from {player.Name}: {reason}`)
	end
	sendPlaceResult(player, ok, reason)
end

local function onRoundaboutPresetRequest(player: Player, req: any)
	if not canPlayerEditRoads(player) then
		sendPlaceResult(player, false, "road editing is locked")
		return
	end
	if not NetMiddleware.CheckServerRate(_roundaboutPresetRemote, player) then
		return
	end
	local ok, reason = _roads.setRoundaboutPresetFromRequest(req)
	if not ok then
		sendPlaceResult(player, false, reason)
	end
end

local function onReplaceSegmentRequest(player: Player, segmentId: any, roadType: any, worldPos: any)
	if not canPlayerEditRoads(player) then
		return
	end
	if not NetMiddleware.CheckServerRate(_replaceSegRemote, player) then
		return
	end
	if placeCooldownActive(player) then
		return
	end
	if typeof(roadType) ~= "string" then
		return
	end
	_roads.replaceSegmentFromRequest(segmentId, roadType, worldPos)
end

local function onRemoveSegmentRequest(player: Player, segmentId: any, worldPos: any)
	if not canPlayerEditRoads(player) then
		return
	end
	if not NetMiddleware.CheckServerRate(_removeSegRemote, player) then
		return
	end
	if placeCooldownActive(player) then
		return
	end
	_roads.removeSegmentFromRequest(segmentId, worldPos)
end

local function onRemoveSegmentsRequest(player: Player, entries: any)
	if not canPlayerEditRoads(player) then
		return
	end
	if not NetMiddleware.CheckServerRate(_removeSegsRemote, player) then
		return
	end
	if placeCooldownActive(player) then
		return
	end
	if typeof(entries) ~= "table" or #entries == 0 or #entries > MAX_BATCH_REMOVE then
		return
	end
	_roads.removeSegmentsFromRequest(entries)
end

local function onTurnPermissionRequest(player: Player, nodeId: any, movement: any, enabled: any)
	if not canPlayerEditRoads(player) then
		return
	end
	if not NetMiddleware.CheckServerRate(_turnPermRemote, player) then
		return
	end
	if not canProcessEditNow(player) then
		return
	end
	if typeof(nodeId) ~= "number" or not validSmallString(movement, MAX_MOVEMENT_LEN) or typeof(enabled) ~= "boolean" then
		return
	end
	_roads.setIntersectionTurnPermission(nodeId, movement, enabled)
end

local function onLaneTurnPermissionRequest(player: Player, nodeId: any, incomingEdgeId: any, movement: any, enabled: any)
	if not canPlayerEditRoads(player) then
		return
	end
	if not NetMiddleware.CheckServerRate(_laneTurnPermRemote, player) then
		return
	end
	if not canProcessEditNow(player) then
		return
	end
	if typeof(nodeId) ~= "number" or not validSmallString(incomingEdgeId, MAX_EDGE_ID_LEN) or not validSmallString(movement, MAX_MOVEMENT_LEN) or typeof(enabled) ~= "boolean" then
		return
	end
	_roads.setIntersectionLaneTurnPermission(nodeId, incomingEdgeId, movement, enabled)
end

local function onConnectionHandleRequest(player: Player, nodeId: any, fromEdgeId: any, toEdgeId: any, handle: any)
	if not canPlayerEditRoads(player) then
		return
	end
	if not NetMiddleware.CheckServerRate(_connectionHandleRemote, player) then
		return
	end
	if not canProcessEditNow(player) then
		return
	end
	if typeof(nodeId) ~= "number" or not validSmallString(fromEdgeId, MAX_EDGE_ID_LEN) or not validSmallString(toEdgeId, MAX_EDGE_ID_LEN) or typeof(handle) ~= "Vector3" or not isFiniteVector(handle) or not inBounds(handle) then
		return
	end
	_roads.setIntersectionConnectionHandle(nodeId, fromEdgeId, toEdgeId, handle)
end

local function onConnectionRequest(player: Player, nodeId: any, fromEdgeId: any, toEdgeId: any, connected: any)
	if not canPlayerEditRoads(player) then
		return
	end
	if not NetMiddleware.CheckServerRate(_connectionRemote, player) then
		return
	end
	if not canProcessEditNow(player) then
		return
	end
	if typeof(nodeId) ~= "number" or not validSmallString(fromEdgeId, MAX_EDGE_ID_LEN) or not validSmallString(toEdgeId, MAX_EDGE_ID_LEN) or typeof(connected) ~= "boolean" then
		return
	end
	_roads.setIntersectionConnection(nodeId, fromEdgeId, toEdgeId, connected)
end

local function onResetConnectionsRequest(player: Player, nodeId: any)
	if not canPlayerEditRoads(player) then
		return
	end
	if not NetMiddleware.CheckServerRate(_resetConnectionsRemote, player) then
		return
	end
	if not canProcessEditNow(player) then
		return
	end
	if typeof(nodeId) ~= "number" then
		return
	end
	_roads.resetIntersectionConnections(nodeId)
end

local function onLaneChangeConnectionRequest(player: Player, gateId: any, fromEdgeId: any, toEdgeId: any, connected: any)
	if not canPlayerEditRoads(player) then
		return
	end
	if not NetMiddleware.CheckServerRate(_laneChangeConnRemote, player) then
		return
	end
	if not canProcessEditNow(player) then
		return
	end
	if not validSmallString(gateId, MAX_EDGE_ID_LEN)
		or not validSmallString(fromEdgeId, MAX_EDGE_ID_LEN)
		or not validSmallString(toEdgeId, MAX_EDGE_ID_LEN)
		or typeof(connected) ~= "boolean" then
		return
	end
	_roads.setLaneChangeConnection(gateId, fromEdgeId, toEdgeId, connected)
end

local function onMoveRoadRequest(player: Player, req: any)
	if not canPlayerEditRoads(player) then
		return
	end
	if not NetMiddleware.CheckServerRate(_moveRemote, player) then
		return
	end
	if not canProcessEditNow(player) then
		return
	end
	-- Shape/bounds validation is per-kind (node/segment/handles/group/roundabout) in
	-- RoadService.moveFromRequest; only gate the transport basics here.
	if typeof(req) ~= "table" then
		return
	end
	_roads.moveFromRequest(req, player)
end

-- Renaming a street is an edit like any other road edit: same permission gate,
-- same rate limit. The name itself is trimmed and capped in RoadService.
local MAX_NAME_LEN = 40

local function onSetRoadNameRequest(player: Player, segmentId: any, name: any)
	if not canPlayerEditRoads(player) then
		return
	end
	if not NetMiddleware.CheckServerRate(_setRoadNameRemote, player) then
		return
	end
	if not canProcessEditNow(player) then
		return
	end
	if typeof(segmentId) ~= "number" or segmentId ~= segmentId then
		return
	end
	-- An empty string is the documented "clear the override" case, so only a
	-- non-string or an over-long one is a rejection.
	if name ~= nil and (typeof(name) ~= "string" or #name > MAX_NAME_LEN) then
		return
	end
	_roads.setRoadName(math.floor(segmentId), name)
end

local function onUndoRequest(player: Player)
	if not canPlayerEditRoads(player) then
		return
	end
	if not NetMiddleware.CheckServerRate(_undoRemote, player) then
		return
	end
	_roads.undo()
end

local function onRedoRequest(player: Player)
	if not canPlayerEditRoads(player) then
		return
	end
	if not NetMiddleware.CheckServerRate(_redoRemote, player) then
		return
	end
	_roads.redo()
end

-- ---------------------------------------------------------------- lifecycle --

export type Deps = {
	roads: any,
	network: any,
	navGraph: any,
	getPermissions: (Types.NodeId) -> any,
	clearPermissions: (Types.NodeId) -> (),
	armMarkingSetback: (Types.NodeId, Types.SegmentId) -> number,
}

function RoadReplicationService.init(deps: Deps)
	assert(deps and deps.roads and deps.network and deps.navGraph
		and deps.getPermissions and deps.clearPermissions and deps.armMarkingSetback,
		"[RoadReplicationService] missing dependency")
	_roads = deps.roads
	_network = deps.network
	_navGraph = deps.navGraph
	_getPermissions = deps.getPermissions
	_clearPermissions = deps.clearPermissions
	_armMarkingSetback = deps.armMarkingSetback

	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	_placeRemote            = Net.RequestPlaceRoad
	_placeRoundaboutRemote  = Net.RequestPlaceRoundabout
	_roundaboutPresetRemote = Net.RequestSetRoundaboutPreset
	_placeResultRemote      = Net.PlaceRoadResult
	_syncRemote             = Net.SyncNodes
	_syncSegRemote          = Net.SyncSegments
	_syncInterRemote        = Net.SyncIntersections
	_syncNodeDeltaRemote    = Net.SyncNodesDelta
	_syncSegDeltaRemote     = Net.SyncSegmentsDelta
	_turnPermRemote         = Net.RequestSetIntersectionTurn
	_laneTurnPermRemote     = Net.RequestSetIntersectionLaneTurn
	_connectionHandleRemote = Net.RequestSetIntersectionConnectionHandle
	_syncTurnPermRemote     = Net.SyncIntersectionTurnSettings
	_syncLanePathRemote     = Net.SyncIntersectionLanePaths
	_syncLaneChangeRemote   = Net.SyncLaneChangeGates
	_laneChangeConnRemote   = Net.RequestSetLaneChangeConnection
	_connectionRemote       = Net.RequestSetIntersectionConnection
	_resetConnectionsRemote = Net.RequestResetIntersectionConnections
	_replaceSegRemote       = Net.RequestReplaceRoadSegment
	_removeSegRemote        = Net.RequestRemoveRoadSegment
	_removeSegsRemote       = Net.RequestRemoveRoadSegments
	_undoRemote             = Net.RequestUndoRoad
	_redoRemote             = Net.RequestRedoRoad
	_moveRemote             = Net.RequestMoveRoad
	_setRoadNameRemote      = Net.RequestSetRoadName
	_roadTrafficRemote      = Net.RequestRoadTraffic
end

function RoadReplicationService.bind()
	NetMiddleware.RegisterServerRateLimit(_placeRemote,            RoadConstants.PLACE_COOLDOWN)
	NetMiddleware.RegisterServerRateLimit(_placeRoundaboutRemote,  RoadConstants.PLACE_COOLDOWN)
	NetMiddleware.RegisterServerRateLimit(_roundaboutPresetRemote, CONNECTION_EDIT_COOLDOWN)
	NetMiddleware.RegisterServerRateLimit(_replaceSegRemote,       RoadConstants.PLACE_COOLDOWN)
	NetMiddleware.RegisterServerRateLimit(_removeSegRemote,        RoadConstants.PLACE_COOLDOWN)
	NetMiddleware.RegisterServerRateLimit(_removeSegsRemote,       RoadConstants.PLACE_COOLDOWN)
	NetMiddleware.RegisterServerRateLimit(_moveRemote,             RoadConstants.PLACE_COOLDOWN)
	-- RemoteFunction: the middleware keys off the instance, so the RemoteEvent type
	-- on its signature is the only thing in the way.
	NetMiddleware.RegisterServerRateLimit(_roadTrafficRemote :: any, 0.25)
	NetMiddleware.RegisterServerRateLimit(_undoRemote,             CONNECTION_EDIT_COOLDOWN)
	NetMiddleware.RegisterServerRateLimit(_redoRemote,             CONNECTION_EDIT_COOLDOWN)
	NetMiddleware.RegisterServerRateLimit(_turnPermRemote,         CONNECTION_EDIT_COOLDOWN)
	NetMiddleware.RegisterServerRateLimit(_laneTurnPermRemote,     CONNECTION_EDIT_COOLDOWN)
	NetMiddleware.RegisterServerRateLimit(_connectionHandleRemote, CONNECTION_EDIT_COOLDOWN)
	NetMiddleware.RegisterServerRateLimit(_connectionRemote,       CONNECTION_EDIT_COOLDOWN)
	NetMiddleware.RegisterServerRateLimit(_resetConnectionsRemote, CONNECTION_EDIT_COOLDOWN)
	NetMiddleware.RegisterServerRateLimit(_laneChangeConnRemote,   CONNECTION_EDIT_COOLDOWN)
	NetMiddleware.RegisterServerRateLimit(_setRoadNameRemote,      CONNECTION_EDIT_COOLDOWN)

	_placeRemote.OnServerEvent:Connect(onPlaceRequest)
	_placeRoundaboutRemote.OnServerEvent:Connect(onPlaceRoundaboutRequest)
	_turnPermRemote.OnServerEvent:Connect(onTurnPermissionRequest)
	_laneTurnPermRemote.OnServerEvent:Connect(onLaneTurnPermissionRequest)
	_connectionHandleRemote.OnServerEvent:Connect(onConnectionHandleRequest)
	_connectionRemote.OnServerEvent:Connect(onConnectionRequest)
	_resetConnectionsRemote.OnServerEvent:Connect(onResetConnectionsRequest)
	_laneChangeConnRemote.OnServerEvent:Connect(onLaneChangeConnectionRequest)
	_replaceSegRemote.OnServerEvent:Connect(onReplaceSegmentRequest)
	_removeSegRemote.OnServerEvent:Connect(onRemoveSegmentRequest)
	_removeSegsRemote.OnServerEvent:Connect(onRemoveSegmentsRequest)
	_moveRemote.OnServerEvent:Connect(onMoveRoadRequest)
	_setRoadNameRemote.OnServerEvent:Connect(onSetRoadNameRequest)
	_roundaboutPresetRemote.OnServerEvent:Connect(onRoundaboutPresetRequest)

	-- Read-only traffic query for the road info panel. Rate-limited like any other
	-- client-driven read; a spoofed id just returns nil.
	_roadTrafficRemote.OnServerInvoke = function(player: Player, segmentId: any): any
		if not NetMiddleware.CheckServerRate(_roadTrafficRemote :: any, player) then
			return nil
		end
		if typeof(segmentId) ~= "number" or segmentId ~= segmentId then
			return nil
		end
		return _roads.getRoadTraffic(math.floor(segmentId))
	end
	_undoRemote.OnServerEvent:Connect(onUndoRequest)
	_redoRemote.OnServerEvent:Connect(onRedoRequest)

	Players.PlayerRemoving:Connect(function(player)
		_lastPlaceAt[player] = nil
		_lastConnEditAt[player] = nil
		NetMiddleware.OnPlayerRemoving(player)
	end)

	local function fullSync(player: Player)
		RoadReplicationService.broadcastNodes(player)
		RoadReplicationService.broadcastTurnPermissions(player)
		RoadReplicationService.broadcastLanePaths(player)
		RoadReplicationService.broadcastLaneChanges(player)
	end
	Players.PlayerAdded:Connect(fullSync)
	for _, player in Players:GetPlayers() do
		fullSync(player)
	end
end

return RoadReplicationService
