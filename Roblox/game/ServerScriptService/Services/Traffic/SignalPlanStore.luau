--!strict
-- SignalPlanStore
-- Owns every player-authored signal setting: one SignalPlan per signalised node, and
-- the coordination groups those nodes belong to. Authoritative -- nothing else writes
-- these tables, and everything that enters passes SignalSpec.sanitizePlan first.
--
-- PERSISTENCE, and why it is by POSITION and not by id. Node ids are regenerated on
-- every city load (see RoadService.restoreRoads), so a plan keyed on node 47 would
-- come back attached to whichever junction happened to be numbered 47 that session --
-- which is how the intersection turn permissions already behave, and why they quietly
-- reset. A plan is therefore saved against the junction's WORLD POSITION and
-- re-anchored to the nearest intersection on load. Positions are stable across a save
-- because the roads themselves restore to bit-identical endpoints.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SignalSpec = require(ReplicatedStorage.Road.SignalSpec)
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)

local SignalPlanStore = {}

type SignalPlan = SignalSpec.SignalPlan
type SignalGroup = SignalSpec.SignalGroup

-- == State ===================================================================
local _roadService: any = nil
local _plans: { [number]: SignalPlan } = {}
local _groups: { [string]: SignalGroup } = {}
local _listeners: { (nodeId: number?) -> () } = {}
local _nextGroupSuffix = 1

-- A restored city hands its plans over before the nav graph has finished rebuilding,
-- so they wait here until there are intersections to anchor them to.
local _pendingAnchors: { { pos: Vector3, plan: SignalPlan } } = {}

-- How far a saved plan may sit from a junction and still be considered the same one.
-- Generous on purpose: a junction's node can shift slightly when a neighbouring road
-- is re-welded on load, and losing a corridor's timings to a two-stud drift would be
-- worse than occasionally anchoring to a junction the player rebuilt in place.
local ANCHOR_TOLERANCE_STUDS = 12 * RoadConstants.WORLD_SCALE

-- == Change notification =====================================================
-- TrafficSignalService rebuilds its groups off this. nodeId is nil for a change that
-- could touch any node (a group edit, a bulk restore).
function SignalPlanStore.onChanged(fn: (nodeId: number?) -> ()): () -> ()
	table.insert(_listeners, fn)
	return function()
		local i = table.find(_listeners, fn)
		if i then table.remove(_listeners, i) end
	end
end

local function notify(nodeId: number?)
	for _, fn in _listeners do
		-- Isolated: one listener erroring must not stop the others being told, or the
		-- controller and the replicator can end up disagreeing about the live plan.
		local ok, err = pcall(fn, nodeId)
		if not ok then
			warn("[SignalPlanStore] listener errored: " .. tostring(err))
		end
	end
end

-- == Plans ===================================================================

-- The stored plan, or nil when this junction has never been customised. Callers that
-- want a usable plan either way should use planFor.
function SignalPlanStore.rawPlan(nodeId: number): SignalPlan?
	return _plans[nodeId]
end

-- Always a plan. An uncustomised junction gets the defaults with custom = false, which
-- every consumer reads as "behave exactly as you did before any of this existed".
function SignalPlanStore.planFor(nodeId: number): SignalPlan
	return _plans[nodeId] or SignalSpec.defaultPlan()
end

function SignalPlanStore.setPlan(nodeId: number, raw: any): SignalPlan
	local plan = SignalSpec.sanitizePlan(raw)

	-- A plan that is back on auto with no group membership carries no information;
	-- dropping it keeps the save small and the store honest about what is customised.
	if not plan.custom and not plan.groupId then
		if _plans[nodeId] then
			_plans[nodeId] = nil
			notify(nodeId)
		end
		return plan
	end

	-- Group membership is owned by the GROUP's node list, not by the plan's own field:
	-- two sources of truth for the same relationship is how a node ends up in a group
	-- that does not list it. Joining happens through addToGroup.
	local existing = _plans[nodeId]
	plan.groupId = if existing then existing.groupId else nil

	_plans[nodeId] = plan
	notify(nodeId)
	return plan
end

function SignalPlanStore.clearPlan(nodeId: number)
	if not _plans[nodeId] then return end
	SignalPlanStore.removeFromGroup(nodeId)
	_plans[nodeId] = nil
	notify(nodeId)
end

-- Called when a junction's shape changes under it. The timings stay -- they are the
-- player's -- but the per-arm left-turn modes are keyed by arm index, and an arm
-- index means nothing once the arm count has changed.
function SignalPlanStore.invalidateArms(nodeId: number)
	local plan = _plans[nodeId]
	if not plan or next(plan.arms) == nil then return end
	plan.arms = {}
	notify(nodeId)
end

function SignalPlanStore.allPlans(): { [number]: SignalPlan }
	return _plans
end

-- == Groups ==================================================================

function SignalPlanStore.group(groupId: string): SignalGroup?
	return _groups[groupId]
end

function SignalPlanStore.allGroups(): { [string]: SignalGroup }
	return _groups
end

function SignalPlanStore.groupOf(nodeId: number): SignalGroup?
	local plan = _plans[nodeId]
	local id = plan and plan.groupId
	return if id then _groups[id] else nil
end

local function newGroupId(): string
	-- Not os.clock or a GUID: the id goes in the save and is read back by a human when
	-- a corridor misbehaves. Sequential and short, with a uniqueness loop behind it.
	while _groups["corridor" .. _nextGroupSuffix] do
		_nextGroupSuffix += 1
	end
	return "corridor" .. _nextGroupSuffix
end

function SignalPlanStore.createGroup(name: string?): SignalGroup
	local id = newGroupId()
	local label = if typeof(name) == "string" and #name > 0 then string.sub(name, 1, 40) else "Corridor " .. _nextGroupSuffix
	local group = SignalSpec.defaultGroup(id, label)
	_groups[id] = group
	_nextGroupSuffix += 1
	notify(nil)
	return group
end

function SignalPlanStore.setGroupSettings(groupId: string, raw: any): SignalGroup?
	local group = _groups[groupId]
	if not group then return nil end

	-- Only the settings a player can dial. The node list is not taken from the wire:
	-- membership moves one node at a time through add/remove so a malformed payload
	-- cannot silently rewrite which junctions a corridor owns.
	--
	-- Each field falls back to the CURRENT value, not to the schema default, so a
	-- partial payload is a partial update. The panel sends one field at a time as the
	-- player edits it, and treating an absent field as "reset this" meant that nudging
	-- the cycle also silently renamed the corridor back to its id.
	local function pick(key: string, current: any): any
		if typeof(raw) ~= "table" then return current end
		local value = (raw :: any)[key]
		if value == nil then return current end
		return value
	end

	local incoming = SignalSpec.sanitizeGroup({
		id = group.id,
		name = pick("name", group.name),
		cycle = pick("cycle", group.cycle),
		progressionKmh = pick("progressionKmh", group.progressionKmh),
		autoOffsets = pick("autoOffsets", group.autoOffsets),
		masterNodeId = pick("masterNodeId", group.masterNodeId),
	})
	if not incoming then return group end

	group.name = incoming.name
	group.cycle = incoming.cycle
	group.progressionKmh = incoming.progressionKmh
	group.autoOffsets = incoming.autoOffsets

	-- A master outside the group is not a master. Fall back to the first member so a
	-- corridor always has a reference point to measure its offsets from.
	if incoming.masterNodeId and table.find(group.nodeIds, incoming.masterNodeId) then
		group.masterNodeId = incoming.masterNodeId
	elseif not group.masterNodeId or not table.find(group.nodeIds, group.masterNodeId) then
		group.masterNodeId = group.nodeIds[1]
	end

	notify(nil)
	return group
end

function SignalPlanStore.addToGroup(nodeId: number, groupId: string): boolean
	local group = _groups[groupId]
	if not group then return false end
	if table.find(group.nodeIds, nodeId) then return true end
	if #group.nodeIds >= 32 then return false end

	-- A node belongs to at most one corridor: leaving the old one first is what keeps
	-- the two group node lists from both claiming it.
	SignalPlanStore.removeFromGroup(nodeId)

	local plan = _plans[nodeId]
	if not plan then
		plan = SignalSpec.defaultPlan()
		_plans[nodeId] = plan
	end
	-- Coordination IS a customisation: a coordinated junction runs a fixed cycle, not
	-- the free-running adaptive one, so joining a corridor turns custom on.
	plan.custom = true
	plan.groupId = groupId
	table.insert(group.nodeIds, nodeId)
	if not group.masterNodeId then
		group.masterNodeId = nodeId
	end

	notify(nil)
	return true
end

function SignalPlanStore.removeFromGroup(nodeId: number)
	local plan = _plans[nodeId]
	local groupId = plan and plan.groupId
	if not groupId then return end
	plan.groupId = nil

	local group = _groups[groupId]
	if group then
		local i = table.find(group.nodeIds, nodeId)
		if i then table.remove(group.nodeIds, i) end
		if group.masterNodeId == nodeId then
			group.masterNodeId = group.nodeIds[1]
		end
		-- An empty corridor is litter: it would keep appearing in the group picker with
		-- nothing in it.
		if #group.nodeIds == 0 then
			_groups[groupId] = nil
		end
	end

	notify(nil)
end

function SignalPlanStore.deleteGroup(groupId: string)
	local group = _groups[groupId]
	if not group then return end
	-- Copied before iterating: removeFromGroup mutates the very list being walked.
	for _, nodeId in table.clone(group.nodeIds) do
		local plan = _plans[nodeId]
		if plan then plan.groupId = nil end
	end
	_groups[groupId] = nil
	notify(nil)
end

-- == Topology upkeep =========================================================

-- Drops plans for junctions that no longer exist and re-anchors anything still
-- waiting from a load. Cheap enough to run after every topology settle.
function SignalPlanStore.reconcile()
	if not _roadService then return end
	local network = _roadService.getNetwork()
	if not network then return end

	local nodes = network:getNodes()
	local dropped = false
	for nodeId in pairs(_plans) do
		if not nodes[nodeId] then
			SignalPlanStore.removeFromGroup(nodeId)
			_plans[nodeId] = nil
			dropped = true
		end
	end

	local anchored = SignalPlanStore.flushPendingAnchors()
	if dropped or anchored then
		notify(nil)
	end
end

-- == Persistence =============================================================

-- Saved shape, deliberately flat and short -- this rides in the city blob:
--   { v = 1,
--     plans = { { x, z, <plan fields> }, ... },
--     groups = { { id, name, cycle, speed, auto, masterX, masterZ }, ... } }
-- Group membership is NOT stored as a node list; each plan carries its own group id
-- and the lists rebuild from that on load, so a plan that fails to anchor cannot
-- leave a group holding a reference to a junction that is not there.
local SAVE_VERSION = 1

local function nodePosition(nodeId: number): Vector3?
	if not _roadService then return nil end
	local network = _roadService.getNetwork()
	if not network then return nil end
	local node = network:getNodes()[nodeId]
	return if node then node.position else nil
end

function SignalPlanStore.serialize(): { [string]: any }?
	local plans: { any } = {}
	for nodeId, plan in pairs(_plans) do
		local pos = nodePosition(nodeId)
		if not pos then continue end
		table.insert(plans, {
			x = math.round(pos.X * 10) / 10,
			z = math.round(pos.Z * 10) / 10,
			custom = plan.custom,
			cycleMode = plan.cycleMode,
			cycle = plan.cycle,
			minGreen = plan.minGreen,
			maxGreen = plan.maxGreen,
			leftMinGreen = plan.leftMinGreen,
			leftMaxGreen = plan.leftMaxGreen,
			secPerCar = plan.secPerCar,
			yellow = plan.yellow,
			allRed = plan.allRed,
			pedMode = plan.pedMode,
			pedWalk = plan.pedWalk,
			pedEveryNCycles = plan.pedEveryNCycles,
			leadingLefts = plan.leadingLefts,
			arms = plan.arms,
			groupId = plan.groupId,
			offset = plan.offset,
			coordPhase = plan.coordPhase,
		})
	end

	local groups: { any } = {}
	for _, group in pairs(_groups) do
		local masterPos = if group.masterNodeId then nodePosition(group.masterNodeId) else nil
		table.insert(groups, {
			id = group.id,
			name = group.name,
			cycle = group.cycle,
			progressionKmh = group.progressionKmh,
			autoOffsets = group.autoOffsets,
			masterX = if masterPos then math.round(masterPos.X * 10) / 10 else nil,
			masterZ = if masterPos then math.round(masterPos.Z * 10) / 10 else nil,
		})
	end

	if #plans == 0 and #groups == 0 then return nil end
	return { v = SAVE_VERSION, plans = plans, groups = groups }
end

-- Group ids and master positions parked between restore() and the moment the road
-- graph is back, so masters can be re-anchored alongside the plans.
local _pendingMasters: { [string]: Vector3 } = {}

function SignalPlanStore.restore(blob: any)
	table.clear(_plans)
	table.clear(_groups)
	table.clear(_pendingAnchors)
	table.clear(_pendingMasters)
	_nextGroupSuffix = 1

	if typeof(blob) ~= "table" or typeof(blob.plans) ~= "table" then
		notify(nil)
		return
	end

	if typeof(blob.groups) == "table" then
		for _, raw in ipairs(blob.groups) do
			local group = SignalSpec.sanitizeGroup(raw)
			if group then
				-- Membership rebuilds from the plans below, never from the saved list.
				group.nodeIds = {}
				group.masterNodeId = nil
				_groups[group.id] = group
				if typeof(raw.masterX) == "number" and typeof(raw.masterZ) == "number" then
					_pendingMasters[group.id] = Vector3.new(raw.masterX, 0, raw.masterZ)
				end
			end
		end
	end

	for _, raw in ipairs(blob.plans) do
		if typeof(raw) == "table" and typeof(raw.x) == "number" and typeof(raw.z) == "number" then
			local plan = SignalSpec.sanitizePlan(raw)
			-- A group id pointing at a corridor that did not survive is dropped rather
			-- than resurrecting an empty group around it.
			if plan.groupId and not _groups[plan.groupId] then
				plan.groupId = nil
			end
			table.insert(_pendingAnchors, { pos = Vector3.new(raw.x, 0, raw.z), plan = plan })
		end
	end

	SignalPlanStore.flushPendingAnchors()
	notify(nil)
end

-- Matches every waiting plan to the nearest signalisable junction. Returns true if
-- anything landed, so callers know whether to tell the listeners.
function SignalPlanStore.flushPendingAnchors(): boolean
	if #_pendingAnchors == 0 and next(_pendingMasters) == nil then return false end
	if not _roadService then return false end
	local network = _roadService.getNetwork()
	if not network then return false end

	local nodes = network:getNodes()
	-- Candidate junctions, gathered once: this runs against every pending plan and
	-- re-walking the node table per plan turns a load into an O(plans * nodes) scan.
	local candidates: { { id: number, pos: Vector3 } } = {}
	for nodeId, node in pairs(nodes) do
		if network:getNodeKind(nodeId) == "intersection" then
			table.insert(candidates, { id = nodeId, pos = node.position })
		end
	end
	if #candidates == 0 then return false end

	local tolSq = ANCHOR_TOLERANCE_STUDS * ANCHOR_TOLERANCE_STUDS
	local function nearest(target: Vector3, taken: { [number]: boolean }?): number?
		local bestId: number? = nil
		local bestSq = tolSq
		for _, cand in candidates do
			if taken and taken[cand.id] then continue end
			local dx = cand.pos.X - target.X
			local dz = cand.pos.Z - target.Z
			local d2 = dx * dx + dz * dz
			if d2 <= bestSq then
				bestSq = d2
				bestId = cand.id
			end
		end
		return bestId
	end

	local claimed: { [number]: boolean } = {}
	for nodeId in pairs(_plans) do
		claimed[nodeId] = true
	end

	local landed = false
	local stillPending: { { pos: Vector3, plan: SignalPlan } } = {}
	for _, entry in _pendingAnchors do
		-- One junction takes one plan: without the claim set, two plans saved at nearly
		-- the same spot would both anchor to the same node and one would overwrite the
		-- other silently.
		local nodeId = nearest(entry.pos, claimed)
		if nodeId then
			claimed[nodeId] = true
			_plans[nodeId] = entry.plan
			local groupId = entry.plan.groupId
			local group = if groupId then _groups[groupId] else nil
			if group and not table.find(group.nodeIds, nodeId) then
				table.insert(group.nodeIds, nodeId)
			end
			landed = true
		else
			table.insert(stillPending, entry)
		end
	end
	_pendingAnchors = stillPending

	for groupId, pos in pairs(_pendingMasters) do
		local group = _groups[groupId]
		if group then
			local nodeId = nearest(pos, nil)
			if nodeId and table.find(group.nodeIds, nodeId) then
				group.masterNodeId = nodeId
				_pendingMasters[groupId] = nil
			elseif #group.nodeIds > 0 then
				group.masterNodeId = group.nodeIds[1]
				_pendingMasters[groupId] = nil
			end
		end
	end

	-- A corridor whose members all failed to anchor is dead weight in the save.
	for groupId, group in pairs(_groups) do
		if #group.nodeIds == 0 and #_pendingAnchors == 0 then
			_groups[groupId] = nil
		end
	end

	return landed
end

-- == Lifecycle ===============================================================

function SignalPlanStore.Init(roadService: any)
	_roadService = roadService
	table.clear(_plans)
	table.clear(_groups)
	table.clear(_pendingAnchors)
	table.clear(_pendingMasters)
	_nextGroupSuffix = 1
end

function SignalPlanStore.clear()
	table.clear(_plans)
	table.clear(_groups)
	table.clear(_pendingAnchors)
	table.clear(_pendingMasters)
	_nextGroupSuffix = 1
	notify(nil)
end

return SignalPlanStore
