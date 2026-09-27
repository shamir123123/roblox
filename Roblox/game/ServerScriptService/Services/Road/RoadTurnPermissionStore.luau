--!strict
-- RoadTurnPermissionStore
-- Single source of truth for per-intersection turn/connection permissions and the
-- lane-change gate rules. Owns the two permission tables AND the editing API: each
-- edit validates against the live network + nav graph, mutates the stored config,
-- then triggers a nav rebuild + turn-permission broadcast. Collaborators (network,
-- nav graph, the rebuild scheduler, the broadcast fn) are injected by RoadService at
-- init, so this module never requires RoadService -- require direction stays
-- RoadService -> here, matching RoadReplicationService.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Road.RoadTypes)

local RoadTurnPermissionStore = {}

local TURN_KEYS = {
	left = true,
	right = true,
	straight = true,
	uturn = true,
}

-- Injected at init (see RoadService.Init). Never required directly.
local _network: any = nil
local _navGraph: any = nil
local _scheduleNavRebuild: any = nil
local _broadcastTurnPermissions: any = nil

-- The owned tables -- the single source of truth for intersection config.
local _turnPermissions: { [Types.NodeId]: any } = {}
local _laneChangeRules: { [string]: boolean } = {}

export type Deps = {
	network: any,
	navGraph: any,
	scheduleNavRebuild: (Types.NodeId?, boolean?, boolean?) -> (),
	broadcastTurnPermissions: (any?, Types.NodeId?) -> (),
}

function RoadTurnPermissionStore.init(deps: Deps)
	_network = deps.network
	_navGraph = deps.navGraph
	_scheduleNavRebuild = deps.scheduleNavRebuild
	_broadcastTurnPermissions = deps.broadcastTurnPermissions
end

local function defaultTurnPermissions(): any
	return {
		left = true,
		right = true,
		straight = true,
		uturn = false,
		laneRules = {},
		customConnections = {},
	}
end

-- ---- Accessors used by RoadService's topology + nav-rebuild machinery ---------

-- The node's permissions, creating defaults on first access.
function RoadTurnPermissionStore.getOrInit(nodeId: Types.NodeId): any
	local perms = _turnPermissions[nodeId]
	if not perms then
		perms = defaultTurnPermissions()
		_turnPermissions[nodeId] = perms
	end
	return perms
end

-- Drop a node's stored permissions (its arm count / topology changed).
function RoadTurnPermissionStore.invalidate(nodeId: Types.NodeId)
	_turnPermissions[nodeId] = nil
end

-- Whole tables, handed to the nav graph on (re)build.
function RoadTurnPermissionStore.permissions(): { [Types.NodeId]: any }
	return _turnPermissions
end

function RoadTurnPermissionStore.laneChangeRules(): { [string]: boolean }
	return _laneChangeRules
end

-- Drop lane-change rules keyed to a removed segment (keys are "<segmentId>|...").
function RoadTurnPermissionStore.clearLaneRulesForSegment(segmentId: Types.SegmentId)
	local prefix = tostring(segmentId) .. "|"
	for ruleKey in _laneChangeRules do
		if string.sub(ruleKey, 1, #prefix) == prefix then
			_laneChangeRules[ruleKey] = nil
		end
	end
end

-- ---- Editing API (moved verbatim from RoadService) ---------------------------

function RoadTurnPermissionStore.setTurnPermission(nodeId: Types.NodeId, movement: string, enabled: boolean): boolean
	if not TURN_KEYS[movement] then
		return false
	end
	local node = _network:getNodes()[nodeId]
	if not node or _network:getNodeKind(nodeId) ~= "intersection" then
		return false
	end
	local perms = RoadTurnPermissionStore.getOrInit(nodeId)
	perms[movement] = enabled
	_scheduleNavRebuild(nodeId, nil, true)
	_broadcastTurnPermissions(nil, nodeId)
	return true
end

function RoadTurnPermissionStore.setLaneTurnPermission(nodeId: Types.NodeId, incomingEdgeId: string, movement: string, enabled: boolean): boolean
	if not TURN_KEYS[movement] then
		return false
	end
	local node = _network:getNodes()[nodeId]
	if not node or _network:getNodeKind(nodeId) ~= "intersection" or not _navGraph then
		return false
	end
	local edge = _navGraph:GetEdge(incomingEdgeId)
	if not edge or edge.toNode ~= nodeId then
		return false
	end
	local perms = RoadTurnPermissionStore.getOrInit(nodeId)
	perms.laneRules = perms.laneRules or {}
	local rule = perms.laneRules[incomingEdgeId]
	if not rule then
		rule = {}
		perms.laneRules[incomingEdgeId] = rule
	end
	rule[movement] = enabled
	_scheduleNavRebuild(nodeId)
	_broadcastTurnPermissions(nil, nodeId)
	return true
end

function RoadTurnPermissionStore.setConnectionHandle(nodeId: Types.NodeId, fromEdgeId: string, toEdgeId: string, handle: Vector3): boolean
	local node = _network:getNodes()[nodeId]
	if not node or _network:getNodeKind(nodeId) ~= "intersection" or not _navGraph then
		return false
	end
	local fromEdge = _navGraph:GetEdge(fromEdgeId)
	local toEdge = _navGraph:GetEdge(toEdgeId)
	if not fromEdge or not toEdge or fromEdge.toNode ~= nodeId or toEdge.fromNode ~= nodeId then
		return false
	end
	local flatHandle = Vector3.new(handle.X, node.position.Y, handle.Z)
	local perms = RoadTurnPermissionStore.getOrInit(nodeId)
	perms.customConnections = perms.customConnections or {}
	perms.customConnections[`{fromEdgeId}>{toEdgeId}`] = { handles = { flatHandle } }
	_scheduleNavRebuild(nodeId)
	return true
end

local function ensureManual(nodeId: Types.NodeId)
	local perms = RoadTurnPermissionStore.getOrInit(nodeId)
	if perms.manual then
		return
	end
	perms.connectionRules = perms.connectionRules or {}
	if _navGraph then
		for _, conn in _navGraph:GetIntersectionConnectionData(nodeId) do
			if conn.allowed then
				perms.connectionRules[conn.key] = true
			end
		end
	end
	perms.manual = true
end

function RoadTurnPermissionStore.setConnection(nodeId: Types.NodeId, fromEdgeId: string, toEdgeId: string, connected: boolean): boolean
	local node = _network:getNodes()[nodeId]
	if not node or _network:getNodeKind(nodeId) ~= "intersection" or not _navGraph then
		return false
	end
	local fromEdge = _navGraph:GetEdge(fromEdgeId)
	local toEdge = _navGraph:GetEdge(toEdgeId)
	if not fromEdge or not toEdge or fromEdge.toNode ~= nodeId or toEdge.fromNode ~= nodeId then
		return false
	end
	ensureManual(nodeId)
	local perms = RoadTurnPermissionStore.getOrInit(nodeId)
	perms.connectionRules = perms.connectionRules or {}
	perms.connectionRules[`{fromEdgeId}>{toEdgeId}`] = if connected then true else nil
	_scheduleNavRebuild(nodeId)
	_broadcastTurnPermissions(nil, nodeId)
	return true
end

function RoadTurnPermissionStore.resetConnections(nodeId: Types.NodeId): boolean
	local node = _network:getNodes()[nodeId]
	if not node or _network:getNodeKind(nodeId) ~= "intersection" then
		return false
	end
	local perms = RoadTurnPermissionStore.getOrInit(nodeId)
	perms.manual = nil
	perms.connectionRules = {}
	perms.customConnections = {}
	_scheduleNavRebuild(nodeId)
	_broadcastTurnPermissions(nil, nodeId)
	return true
end

function RoadTurnPermissionStore.setLaneChangeConnection(gateId: string, fromEdgeId: string, toEdgeId: string, connected: boolean)
	if not _navGraph or not _navGraph:HasLaneChangeConnection(gateId, fromEdgeId, toEdgeId) then
		return
	end
	local ruleKey = _navGraph:LaneChangeRuleKey(gateId, fromEdgeId, toEdgeId)
	_laneChangeRules[ruleKey] = connected
	_scheduleNavRebuild()
end

return RoadTurnPermissionStore
