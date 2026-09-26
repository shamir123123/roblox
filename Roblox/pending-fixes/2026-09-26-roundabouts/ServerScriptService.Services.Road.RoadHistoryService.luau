--!strict
-- RoadHistoryService
-- Undo/redo history for user-initiated road edits (place / delete / replace).
-- Each entry is a full snapshot of every segment's geometry; one undo reverses
-- exactly one user action. Owns only the stacks: capturing reads segments via
-- the getter and restoring goes through the callback, both injected at init,
-- so this service knows nothing about topology internals.

local RoadHistoryService = {}

local MAX_HISTORY = 50

local _undoStack: { { any } } = {}
local _redoStack: { { any } } = {}
local _getSegments: () -> { [number]: any }
local _restore: (snapshot: { any }) -> ()

function RoadHistoryService.init(getSegments: () -> { [number]: any }, restore: (snapshot: { any }) -> ())
	assert(getSegments and restore, "[RoadHistoryService] requires getSegments + restore")
	_getSegments = getSegments
	_restore = restore
end

-- Canonical order for a snapshot: by start point, then end point, then id.
--
-- This is what makes NODE ids reproducible. Nodes are never saved -- they are rebuilt on
-- load by replaying segments through getOrCreateNodeWithin, so a node's id is just the
-- order its first segment happened to be replayed in. _getSegments() returns the network's
-- segment MAP, and Luau's iteration order over a hash part is unspecified, so that order
-- (and therefore every node id) came out different on each save. Same city, different
-- numbering -- which is what made node ids look random.
--
-- Sorting on GEOMETRY rather than on id makes the ordering a pure function of the city's
-- shape: the same roads always produce the same node ids, whatever order they were drawn
-- or replayed in. Segment ids are unaffected -- they travel in the snapshot and
-- applySnapshot honours them -- so nothing that references a segment id is disturbed.
local function beforeInOrder(a: any, b: any): boolean
	local ap, bp = a.p0, b.p0
	if ap.X ~= bp.X then return ap.X < bp.X end
	if ap.Z ~= bp.Z then return ap.Z < bp.Z end
	if ap.Y ~= bp.Y then return ap.Y < bp.Y end
	local aq, bq = a.p3, b.p3
	if aq.X ~= bq.X then return aq.X < bq.X end
	if aq.Z ~= bq.Z then return aq.Z < bq.Z end
	if aq.Y ~= bq.Y then return aq.Y < bq.Y end
	-- Ids are unique, so this is a total order -- table.sort needs one.
	return a.id < b.id
end

function RoadHistoryService.capture(): { any }
	local snap: { any } = {}
	for _, seg in _getSegments() do
		table.insert(snap, {
			id = seg.id,
			p0 = seg.p0, p1 = seg.p1, p2 = seg.p2, p3 = seg.p3,
			roadType = seg.roadType,
			name = seg.name,
			vMode = seg.vMode, constSlope = seg.constSlope,
			isRoundabout = seg.isRoundabout, roundaboutId = seg.roundaboutId,
			roundaboutCenter = seg.roundaboutCenter, roundaboutRadius = seg.roundaboutRadius,
			roundaboutPreset = seg.roundaboutPreset,
			-- Node-tool junction shaping, per end. Source data, and the ONLY copy: a city
			-- save is RoadSerializer.serialize(capture()), so anything missing here is
			-- silently dropped on save and reset by an undo that rebuilds the segment.
			startCorner = seg.startCorner, endCorner = seg.endCorner,
			startOffset = seg.startOffset, endOffset = seg.endOffset,
			startFlat = seg.startFlat, endFlat = seg.endFlat,
		})
	end
	table.sort(snap, beforeInOrder)
	return snap
end

-- Record the pre-edit state. Recorded only for user-initiated edits, never for
-- internal mutations. Any new edit invalidates the redo stack.
function RoadHistoryService.push(snapshot: { any })
	table.insert(_undoStack, snapshot)
	if #_undoStack > MAX_HISTORY then
		table.remove(_undoStack, 1)
	end
	table.clear(_redoStack)
end

-- Wipe both stacks. Called when a city is restored from a save: history entries
-- reference the pre-load network and undoing into them would resurrect it.
function RoadHistoryService.clear()
	table.clear(_undoStack)
	table.clear(_redoStack)
end

function RoadHistoryService.undo(): boolean
	if #_undoStack == 0 then
		return false
	end
	local current = RoadHistoryService.capture()
	local snap = table.remove(_undoStack) :: { any }
	table.insert(_redoStack, current)
	if #_redoStack > MAX_HISTORY then
		table.remove(_redoStack, 1)
	end
	_restore(snap)
	return true
end

function RoadHistoryService.redo(): boolean
	if #_redoStack == 0 then
		return false
	end
	local current = RoadHistoryService.capture()
	local snap = table.remove(_redoStack) :: { any }
	table.insert(_undoStack, current)
	if #_undoStack > MAX_HISTORY then
		table.remove(_undoStack, 1)
	end
	_restore(snap)
	return true
end

return RoadHistoryService
