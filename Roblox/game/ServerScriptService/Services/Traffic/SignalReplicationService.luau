--!strict
-- SignalReplicationService
-- Network boundary for the traffic signal editor. Validates and rate-limits the two
-- write remotes, answers the read remote, and owns nothing else -- every decision
-- about what a plan MEANS belongs to SignalSpec (schema), SignalPlanStore (state) or
-- TrafficSignalService (behaviour). Same shape as RoadReplicationService, and the
-- same permission gate: editing signals is editing roads.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetMiddleware = require(ReplicatedStorage.NetMiddleware)
local RoadRules = require(ReplicatedStorage.Road.RoadRules)
local SignalSpec = require(ReplicatedStorage.Road.SignalSpec)
local SignalPlanStore = require(script.Parent.SignalPlanStore)
local SignalCoordinator = require(script.Parent.SignalCoordinator)

local SignalReplicationService = {}

-- Matches the road domain's connection-edit cooldown. A stepper held down fires about
-- eight times a second; this lets those through while still stopping a scripted client
-- from rebuilding every junction in the city in a tight loop.
local EDIT_COOLDOWN = 0.15

local _signals: any = nil
local _roadService: any = nil

local _setPlanRemote: RemoteEvent
local _groupEditRemote: RemoteEvent
local _dataRemote: RemoteFunction
local _toggleLightsRemote: RemoteEvent

-- How far from a junction's centre a Traffic Light click still means that junction.
local TOGGLE_PICK_RADIUS = 40

-- ---------------------------------------------------------------- helpers --

-- Signals are part of the road network, so they ride the road permission exactly.
-- Diverging here would let a player who cannot lay a road retime every junction on it.
local function canEdit(player: Player): boolean
	if workspace:GetAttribute("RoadEditOpen") == true then
		return true
	end
	return NetMiddleware.GetCachedAttribute(player, "CanEditRoads") == true
end

local function validNodeId(raw: any): number?
	if typeof(raw) ~= "number" or raw ~= raw then return nil end
	return math.floor(raw)
end

local function validGroupId(raw: any): string?
	if typeof(raw) ~= "string" or #raw == 0 or #raw > 32 then return nil end
	return raw
end

local function nodePosition(nodeId: number): Vector3?
	if not _roadService then return nil end
	local network = _roadService.getNetwork()
	if not network then return nil end
	local node = network:getNodes()[nodeId]
	return if node then node.position else nil
end

-- ------------------------------------------------------------------ write --

local function onSetPlan(player: Player, rawNodeId: any, rawPlan: any)
	if not canEdit(player) then return end
	if not NetMiddleware.CheckServerRate(_setPlanRemote, player) then return end

	local nodeId = validNodeId(rawNodeId)
	if not nodeId then return end
	if typeof(rawPlan) ~= "table" then return end

	-- The junction has to actually be signalised. Without this a client could seed
	-- plans for arbitrary node numbers and grow the store (and the save) unbounded.
	if not _signals.HasSignal(nodeId) then return end

	-- Sanitise first, THEN validate: validation reasons about a legal plan, and a
	-- payload straight off the wire is not one yet.
	local plan = SignalSpec.sanitizePlan(rawPlan)
	local ctx = _signals.BuildValidateContext(nodeId)
	if ctx then
		local issues = SignalSpec.validate(plan, ctx)
		-- Errors are the configurations that are unsafe in the real world -- a yellow
		-- trap, a protected phase with no lane to hold. The panel greys its apply button
		-- on the same check, so reaching here means a client that ignored it.
		if SignalSpec.hasError(issues) then return end
	end

	SignalPlanStore.setPlan(nodeId, plan)
end

-- The Roads panel's Traffic Light card: lights up at a junction that has none, down at one
-- that has them. Stored as the junction's control choice ("auto" when the flip lands back on
-- what the road hierarchy would pick anyway), so it is saved with the city and survives a
-- reload, and the signal service rebuilds the junction off the store's change notice.
local function onToggleLights(player: Player, rawPos: any)
	if not canEdit(player) then return end
	if not NetMiddleware.CheckServerRate(_toggleLightsRemote, player) then return end
	if typeof(rawPos) ~= "Vector3" or rawPos.X ~= rawPos.X or rawPos.Z ~= rawPos.Z then return end
	local network = _roadService and _roadService.getNetwork()
	if not network then return end

	local best: number? = nil
	local bestSq = TOGGLE_PICK_RADIUS * TOGGLE_PICK_RADIUS
	for nodeId, node in network:getNodes() do
		if not node.segments or #node.segments < 3 then continue end
		local dx, dz = node.position.X - rawPos.X, node.position.Z - rawPos.Z
		local d2 = dx * dx + dz * dz
		if d2 < bestSq then
			bestSq = d2
			best = nodeId
		end
	end
	if not best then return end

	local current = RoadRules.nodeControl(network, best)
	if current == "none" then return end -- a roundabout mouth: always give-way
	local want: SignalSpec.ControlMode = if current == "signal" then "priority" else "signal"
	local auto = RoadRules.autoNodeControl(network, best)
	SignalPlanStore.setControl(best, if want == auto then "auto" else want)
end

local function onGroupEdit(player: Player, req: any)
	if not canEdit(player) then return end
	if not NetMiddleware.CheckServerRate(_groupEditRemote, player) then return end
	if typeof(req) ~= "table" then return end

	local action = req.action
	if typeof(action) ~= "string" then return end

	if action == "create" then
		local name = if typeof(req.name) == "string" then string.sub(req.name, 1, 40) else nil
		local group = SignalPlanStore.createGroup(name)
		-- Creating a corridor around the junction the player has selected is the only
		-- thing they ever want next, so fold the first join in rather than making the
		-- client fire a second remote into its own cooldown.
		local nodeId = validNodeId(req.nodeId)
		if nodeId and _signals.HasSignal(nodeId) then
			SignalPlanStore.addToGroup(nodeId, group.id)
		end

	elseif action == "join" then
		local nodeId = validNodeId(req.nodeId)
		local groupId = validGroupId(req.groupId)
		if not nodeId or not groupId then return end
		if not _signals.HasSignal(nodeId) then return end
		SignalPlanStore.addToGroup(nodeId, groupId)

	elseif action == "leave" then
		local nodeId = validNodeId(req.nodeId)
		if not nodeId then return end
		SignalPlanStore.removeFromGroup(nodeId)

	elseif action == "settings" then
		local groupId = validGroupId(req.groupId)
		if not groupId then return end
		SignalPlanStore.setGroupSettings(groupId, req.settings)

	elseif action == "delete" then
		local groupId = validGroupId(req.groupId)
		if not groupId then return end
		SignalPlanStore.deleteGroup(groupId)

	elseif action == "autoCycle" then
		-- "Work out the cycle for me": the critical junction governs, because a cycle
		-- that fits the easy ones starves the busiest one every single time round.
		local groupId = validGroupId(req.groupId)
		if not groupId then return end
		local group = SignalPlanStore.group(groupId)
		if not group then return end
		local cycle = SignalCoordinator.criticalCycle(group, function(nodeId)
			return _signals.BuildValidateContext(nodeId)
		end)
		SignalPlanStore.setGroupSettings(groupId, { cycle = cycle })
	end
end

-- ------------------------------------------------------------------- read --

local function corridorReport(groupId: string): { [string]: any }?
	local group = SignalPlanStore.group(groupId)
	if not group then return nil end

	local solution = SignalCoordinator.solveOffsets(group, nodePosition)
	local advice, tooFar = SignalCoordinator.spacingAdvice(solution)

	local members: { any } = {}
	for _, nodeId in SignalCoordinator.orderCorridor(group, nodePosition) do
		local pos = nodePosition(nodeId)
		local plan = SignalPlanStore.planFor(nodeId)
		table.insert(members, {
			nodeId = nodeId,
			x = if pos then pos.X else 0,
			y = if pos then pos.Y else 0,
			z = if pos then pos.Z else 0,
			offset = plan.offset,
			-- What the offset WOULD be on a clean green wave. Shown next to the live
			-- value so a hand-tuned corridor can be compared against the ideal.
			suggestedOffset = math.round((solution.offsets[nodeId] or 0) * 10) / 10,
			spacing = math.round(solution.spacing[nodeId] or 0),
		})
	end

	return {
		id = group.id,
		name = group.name,
		cycle = group.cycle,
		progressionKmh = group.progressionKmh,
		autoOffsets = group.autoOffsets,
		masterNodeId = group.masterNodeId,
		members = members,
		idealSpacing = math.round(solution.idealSpacing),
		advice = advice,
		tooFar = tooFar,
	}
end

local function onData(player: Player, req: any): any
	if not canEdit(player) then return nil end
	if not NetMiddleware.CheckServerRate(_dataRemote :: any, player) then return nil end
	if typeof(req) ~= "table" then return nil end

	local reply: { [string]: any } = {}

	if req.nodes == true then
		reply.nodes = _signals.GetSignalNodes()
	end

	if req.groups == true then
		local groups: { any } = {}
		for groupId in pairs(SignalPlanStore.allGroups()) do
			local report = corridorReport(groupId)
			if report then table.insert(groups, report) end
		end
		table.sort(groups, function(a, b) return a.id < b.id end)
		reply.groups = groups
	end

	local nodeId = validNodeId(req.nodeId)
	if nodeId then
		local snapshot = _signals.GetNodeEditorSnapshot(nodeId)
		if snapshot then
			-- The panel needs the warnings the same moment it needs the plan, and the
			-- context they are judged against is server-side geometry.
			local ctx = _signals.BuildValidateContext(nodeId)
			if ctx then
				snapshot.issues = SignalSpec.validate(snapshot.plan, ctx)
			end
			local groupId = snapshot.groupId
			if groupId then
				snapshot.corridor = corridorReport(groupId)
			end
			reply.node = snapshot
		end
	end

	return reply
end

-- -------------------------------------------------------------- lifecycle --

function SignalReplicationService.Init(signalService: any, roadService: any)
	assert(signalService and roadService, "[SignalReplicationService] Init requires the signal and road services")
	_signals = signalService
	_roadService = roadService

	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	_setPlanRemote = Net.RequestSetSignalPlan
	_groupEditRemote = Net.RequestSignalGroupEdit
	_dataRemote = Net.RequestSignalData
	_toggleLightsRemote = Net.RequestToggleJunctionLights
end

function SignalReplicationService.Bind()
	NetMiddleware.RegisterServerRateLimit(_setPlanRemote, EDIT_COOLDOWN)
	NetMiddleware.RegisterServerRateLimit(_groupEditRemote, EDIT_COOLDOWN)
	NetMiddleware.RegisterServerRateLimit(_toggleLightsRemote, EDIT_COOLDOWN)
	-- RemoteFunction: the middleware keys off the instance, so the RemoteEvent type on
	-- its signature is the only thing in the way (same cast RoadReplicationService uses
	-- for its traffic query).
	NetMiddleware.RegisterServerRateLimit(_dataRemote :: any, 0.1)

	_setPlanRemote.OnServerEvent:Connect(onSetPlan)
	_groupEditRemote.OnServerEvent:Connect(onGroupEdit)
	_dataRemote.OnServerInvoke = onData
	_toggleLightsRemote.OnServerEvent:Connect(onToggleLights)
end

return SignalReplicationService
