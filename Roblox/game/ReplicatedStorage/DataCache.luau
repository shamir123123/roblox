--!strict

local RunService = game:GetService("RunService")
local isServer   = RunService:IsServer()

local _nodeById:       { [number]: Vector3 }  = {}
local _segById:        { [number]: { id:number, p0:Vector3, p1:Vector3, p2:Vector3, p3:Vector3, roadType:string } } = {}
local _interById:      { [number]: Vector3 }  = {}
local _turnById:       { [number]: any }      = {}
local _lanePathById:   { [number]: any }      = {}
local _laneGates:      { [string]: any }      = {}

local _nodesFlat:  { Vector3 }  = {}
local _segsFlat:   { any }      = {}
local _interFlat:  { Vector3 }  = {}

local _nodesDirty  = false
local _segsDirty   = false
local _interDirty  = false

local _listeners: { [string]: { (any) -> () } } = {}

local DataCache = {}

function DataCache.On(tag: string, cb: (any) -> ())
	if not _listeners[tag] then _listeners[tag] = {} end
	table.insert(_listeners[tag], cb)
end

local function emit(tag: string, payload: any)
	local cbs = _listeners[tag]
	if not cbs then return end
	for _, cb in cbs do
		task.spawn(cb, payload)
	end
end

local function rebuildNodesFlat()
	if not _nodesDirty then return end
	_nodesDirty = false
	table.clear(_nodesFlat)
	for _, v in _nodeById do table.insert(_nodesFlat, v) end
end

local function rebuildSegsFlat()
	if not _segsDirty then return end
	_segsDirty = false
	table.clear(_segsFlat)
	for _, v in _segById do table.insert(_segsFlat, v) end
end

local function rebuildInterFlat()
	if not _interDirty then return end
	_interDirty = false
	table.clear(_interFlat)
	for _, v in _interById do table.insert(_interFlat, v) end
end

function DataCache.SetNodes(list: { { id: number, position: Vector3 } })
	table.clear(_nodeById)
	for _, e in list do
		_nodeById[e.id] = e.position
	end
	_nodesDirty = true
	rebuildNodesFlat()
	emit("nodes", _nodesFlat)
end

function DataCache.ApplyNodesDelta(delta: { changed: { any }, removed: { number } })
	local changed = false
	for _, e in delta.changed do
		_nodeById[e.id] = e.position
		changed = true
	end
	for _, id in delta.removed do
		_nodeById[id] = nil
		changed = true
	end
	if changed then
		_nodesDirty = true
		rebuildNodesFlat()
		emit("nodes", _nodesFlat)
	end
end

function DataCache.SetSegments(list: { any })
	table.clear(_segById)
	for _, s in list do
		_segById[s.id] = s
	end
	_segsDirty = true
	rebuildSegsFlat()
	emit("segments", _segsFlat)
end

function DataCache.ApplySegmentsDelta(delta: { changed: { any }, removed: { number } })
	local changed = false
	for _, s in delta.changed do
		_segById[s.id] = s
		changed = true
	end
	for _, id in delta.removed do
		_segById[id] = nil
		changed = true
	end
	if changed then
		_segsDirty = true
		rebuildSegsFlat()
		emit("segments", _segsFlat)
	end
end

function DataCache.ApplyIntersections(payload: { changed: { any }, removed: { number } })
	for _, e in payload.changed do
		_interById[e.id] = e.position
	end
	for _, id in payload.removed do
		_interById[id] = nil
	end
	_interDirty = true
	rebuildInterFlat()
	emit("intersections", _interFlat)
end

function DataCache.ApplyTurnPermissions(payload: any)
	if type(payload) == "table" and payload.patch then
		for _, e in payload.entries do
			_turnById[e.nodeId] = e
		end
	else
		table.clear(_turnById)
		for _, e in payload do
			_turnById[e.nodeId] = e
		end
	end
	emit("turnPerms", _turnById)
end

function DataCache.ApplyLanePaths(payload: any)
	if type(payload) == "table" and payload.patch then
		for _, e in payload.entries do
			_lanePathById[e.nodeId] = e
		end
	else
		table.clear(_lanePathById)
		for _, e in payload do
			_lanePathById[e.nodeId] = e
		end
	end
	emit("lanePaths", _lanePathById)
end

function DataCache.ApplyLaneGates(payload: any)
	if payload.full then
		table.clear(_laneGates)
		for _, g in payload.gates do
			_laneGates[g.id] = g
		end
	else
		for _, g in (payload.changed or {}) do
			_laneGates[g.id] = g
		end
		for _, id in (payload.removed or {}) do
			_laneGates[id] = nil
		end
	end
	emit("laneGates", _laneGates)
end

function DataCache.GetNodes(): { Vector3 }
	rebuildNodesFlat()
	return _nodesFlat
end

function DataCache.GetSegments(): { any }
	rebuildSegsFlat()
	return _segsFlat
end

function DataCache.GetIntersections(): { Vector3 }
	rebuildInterFlat()
	return _interFlat
end

function DataCache.GetNodeById(id: number): Vector3?
	return _nodeById[id]
end

function DataCache.GetSegmentById(id: number): any
	return _segById[id]
end

function DataCache.GetIntersectionById(id: number): Vector3?
	return _interById[id]
end

function DataCache.GetTurnPerms(nodeId: number): any
	return _turnById[nodeId]
end

function DataCache.GetLanePath(nodeId: number): any
	return _lanePathById[nodeId]
end

function DataCache.GetLaneGates(): { [string]: any }
	return _laneGates
end

function DataCache.IsReady(): boolean
	return next(_nodeById) ~= nil or next(_segById) ~= nil
end

return DataCache
