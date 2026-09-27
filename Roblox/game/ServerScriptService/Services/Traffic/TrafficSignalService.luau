--!strict
-- TrafficSignalService
-- Signal controller for every signal-controlled intersection in the nav graph.
--
-- Pipeline (rebuilt automatically on every road topology change):
--   IntersectionDetector -> per-node geometry plan (arms, directions, pole anchors)
--   SignalPhaseBuilder   -> conflict-free phase sequence per node
--   TrafficLightPlacer   -> physical poles in Workspace (server-side, PivotTo)
--   this module          -> runs the cycle and answers right-of-way queries
--
-- Cycle per phase: GREEN -> YELLOW -> ALL-RED -> next phase. Crossing roads
-- never share a green, so there are no conflicting greens by construction.
--   * Through phases serve an opposing road pair (free-form "NS" / "EW" axes).
--   * Protected-left phases are lane-aware: they exist only where an approach
--     has a dedicated left-turn lane, green exactly those lanes (both opposing
--     left lanes together), and are skipped while no car is queued on them.
--     Shared single lanes keep permissive lefts instead -- no turn phase.
--   * The pedestrian scramble phase turns every arm red on a cycle cadence.
--   * Emergency vehicles preempt: the controller cuts to the phase serving
--     their approach and holds it green until they pass (TTL + hard cap).
--   * Green durations adapt to queue size via an injected provider
--     (Bootstrap wires NPCDriverService.GetSignalQueue in) and gap-out early
--     when their queue empties.
--
-- Consumers (NPCDriverService) keep the same contract as before:
--   CanGo(edgeId, nextEdgeId?) / HasSignal / IsYellow / IsApproachYellow / GetPhase.

local RunService = game:GetService("RunService")

local ReplicatedStorage    = game:GetService("ReplicatedStorage")

local IntersectionDetector = require(script.Parent.IntersectionDetector)
local SignalPhaseBuilder   = require(script.Parent.SignalPhaseBuilder)
local TrafficLightPlacer   = require(script.Parent.TrafficLightPlacer)
local TrafficConfig        = require(script.Parent.TrafficConfig)
local SignalPlanStore      = require(script.Parent.SignalPlanStore)
local SignalCoordinator    = require(script.Parent.SignalCoordinator)
local SignalSpec           = require(ReplicatedStorage.Road.SignalSpec)
local NavCost              = require(ReplicatedStorage.Road.NavCost)
local RoadRules            = require(ReplicatedStorage.Road.RoadRules)
local RoadTypeCatalog      = require(ReplicatedStorage.Road.RoadTypeCatalog)

local TrafficSignalService = {}

type Phase = SignalPhaseBuilder.Phase

-- Every duration the cycle needs, resolved ONCE per rebuild from either the player's
-- plan or the global defaults. Resolving per tick would mean a branch on plan.custom
-- at ten different call sites, and the two would eventually disagree.
type Timings = {
	minGreen: number,
	maxGreen: number,
	leftMinGreen: number,
	leftMaxGreen: number,
	secPerCar: number,
	yellow: number,
	allRed: number,
	pedWalk: number,
	pedEveryN: number,
}

type NodeSignal = {
	nodeId: number,
	geometry: IntersectionDetector.IntersectionPlan,
	phases: { Phase },
	hasPed: boolean,
	-- Pedestrians cross on the parallel through green; no exclusive phase exists.
	pedConcurrent: boolean,
	signalPlan: SignalSpec.SignalPlan,
	timings: Timings,
	-- Set only for a junction in a coordination group: the carve-up of the common
	-- cycle, already rotated so the coordinated phase sits at cycle zero. nil means
	-- this junction free-runs on demand, which is the default and the common case.
	split: SignalCoordinator.SplitPlan?,
	coordPhaseIndex: number,
	currentPhase: number,
	state: "green" | "yellow" | "allred",
	timer: number,
	greenElapsed: number,
	gapPollAccum: number,
	pedSlotPasses: number, -- times the ped slot came up since it last ran
	preemptEdgeId: string?,
	preemptExpires: number,
	preemptHoldUntil: number,
}

local function resolveTimings(plan: SignalSpec.SignalPlan): Timings
	if not plan.custom then
		return {
			minGreen = TrafficConfig.MIN_GREEN,
			maxGreen = TrafficConfig.MAX_GREEN,
			leftMinGreen = TrafficConfig.LEFT_MIN_GREEN,
			leftMaxGreen = TrafficConfig.LEFT_MAX_GREEN,
			secPerCar = TrafficConfig.SEC_PER_QUEUED_CAR,
			yellow = TrafficConfig.YELLOW_TIME,
			allRed = TrafficConfig.ALL_RED_TIME,
			pedWalk = TrafficConfig.PED_WALK_TIME,
			pedEveryN = TrafficConfig.PED_EVERY_N_CYCLES,
		}
	end
	return {
		minGreen = plan.minGreen,
		maxGreen = plan.maxGreen,
		leftMinGreen = plan.leftMinGreen,
		leftMaxGreen = plan.leftMaxGreen,
		secPerCar = plan.secPerCar,
		yellow = plan.yellow,
		allRed = plan.allRed,
		pedWalk = plan.pedWalk,
		pedEveryN = plan.pedEveryNCycles,
	}
end

-- == State =====================================================================
local _roadService: any = nil
local _initialized = false
local _bound = false
local _heartbeat: RBXScriptConnection? = nil
local _topologyDisconnect: (() -> ())? = nil
local _planDisconnect: (() -> ())? = nil
local _discoverPending = false
local _discoverForce = false
local _lastGraphVersion = -1
-- Re-detection is O(intersections); a burst of edits coalesces behind this debounce
-- so signals rebuild ONCE after editing settles instead of once per placement.
local _lastDiscoverAt = 0
local DISCOVER_DEBOUNCE = 0.35
local SIGNAL_TICK = 0.1 -- phase logic and queue sampling do not need render-frame frequency
local DELAY_REFRESH = 4 -- seconds between republishing Webster approach delays to the router

local _groups: { [number]: NodeSignal } = {}
local _edgeSignalNode: { [string]: number } = {} -- edgeId -> controlling node

-- The corridor master clock: simulation seconds since the service started, advanced by
-- the SAME game-speed-scaled dt the cycles run on. os.clock() would not do -- pausing
-- or fast-forwarding the city would slide every coordinated junction off its offset,
-- because their cycles would slow down while the reference they measure against did
-- not. Every group in a coordination group reads its position from this one number.
local _simClock = 0

-- Injected by Bootstrap: (edgeIds) -> (queuedTotal, queuedForLeft). Optional --
-- without it greens use a fixed midpoint duration and left phases never run.
local _queueProvider: (({ string }) -> (number, number))? = nil

-- == Queue helpers =============================================================
local function phaseQueue(phase: Phase): (number, number)
	local provider = _queueProvider
	if not provider then return 0, 0 end
	local ids: { string } = {}
	for edgeId in pairs(phase.greenEdges) do
		table.insert(ids, edgeId)
	end
	if #ids == 0 then return 0, 0 end
	return provider(ids)
end

local function minGreenFor(group: NodeSignal, phase: Phase): number
	local t = group.timings
	return if phase.kind == "left" then t.leftMinGreen else t.minGreen
end

-- The slot this phase occupies in a coordinated cycle, or nil when free-running.
local function slotFor(group: NodeSignal, phaseIndex: number): SignalCoordinator.Slot?
	local split = group.split
	if not split then return nil end
	for _, slot in split.slots do
		if slot.phaseIndex == phaseIndex then return slot end
	end
	return nil
end

local function greenTimeFor(group: NodeSignal, phaseIndex: number): number
	local phase = group.phases[phaseIndex]
	local t = group.timings

	-- Coordinated: the split plan owns every duration. A junction cannot hold a fixed
	-- relationship to its neighbours and still end its green when its own queue runs
	-- dry -- that trade is what coordination IS.
	local slot = slotFor(group, phaseIndex)
	if slot then
		return slot.green
	end

	if phase.kind == "ped" then
		return t.pedWalk
	end
	if not _queueProvider then
		return (t.minGreen + t.maxGreen) * 0.5
	end
	local total = phaseQueue(phase)
	if phase.kind == "left" then
		-- A left phase greens only dedicated left lanes, so every queued car on
		-- its edges is a left-mover: scale on the plain count.
		return math.clamp(
			t.leftMinGreen + total * t.secPerCar,
			t.leftMinGreen,
			t.leftMaxGreen
		)
	end
	return math.clamp(
		t.minGreen + total * t.secPerCar,
		t.minGreen,
		t.maxGreen
	)
end

-- == Routing cost: expected wait per approach ==================================
-- Cars route on TIME, so a junction has to tell the router how long it typically
-- holds a driver. That is Webster's uniform delay: given the full cycle length C and
-- the green g this approach gets, the average wait is C(1-g/C)^2 / 2(1-x*g/C).
--
-- The point is that junctions stop being interchangeable. A lane that gets a long
-- green on a short cycle is nearly free to route through; a lane that gets a brief
-- green on a long multi-phase cycle (a minor arm off a big signalised crossroads)
-- is expensive -- and traffic will correctly prefer a slower road with easy
-- junctions over a fast road that stops at every one.
--
-- Uses NOMINAL greens, not the live adaptive timer: routing wants the character of
-- the junction, not which lamp happens to be lit this second. Live queue state
-- already reaches the router through the congestion snapshot.
local function nominalGreen(group: NodeSignal, phaseIndex: number): number
	-- A coordinated junction's greens are not a range to average -- the split plan
	-- states them exactly, and that IS the junction's character for routing purposes.
	local slot = slotFor(group, phaseIndex)
	if slot then return slot.green end

	local phase = group.phases[phaseIndex]
	local t = group.timings
	if phase.kind == "ped" then
		return t.pedWalk
	end
	if phase.kind == "left" then
		return (t.leftMinGreen + t.leftMaxGreen) * 0.5
	end
	return (t.minGreen + t.maxGreen) * 0.5
end

-- edgeId -> expected seconds of wait, rebuilt whenever the signal layout changes.
local _approachDelay: { [string]: number } = {}

local function rebuildApproachDelays(graph: any)
	table.clear(_approachDelay)

	for _, group in pairs(_groups) do
		local cycle = 0
		local greenByEdge: { [string]: number } = {}

		for phaseIndex, phase in ipairs(group.phases) do
			local green = nominalGreen(group, phaseIndex)
			-- The clearance interval belongs to the cycle: a driver waits through the
			-- yellow and all-red of every other phase too.
			local yellow = if phase.kind == "ped" then 0 else group.timings.yellow
			cycle += green + yellow + group.timings.allRed
			if phase.kind ~= "ped" then
				for edgeId in pairs(phase.greenEdges) do
					greenByEdge[edgeId] = (greenByEdge[edgeId] or 0) + green
				end
			end
		end

		if cycle > 0 then
			for edgeId, green in greenByEdge do
				-- Saturation from live congestion: a busy approach waits longer than a
				-- quiet one on the same timings, exactly as Webster's x term intends.
				local saturation = if graph then graph:GetEdgeCongestion(edgeId) else 0
				local delay = NavCost.websterDelay(cycle, green, saturation)
				if delay > 0.05 then
					_approachDelay[edgeId] = delay
				end
			end
		end
	end

	if graph then
		graph:SetControlDelaySnapshot(_approachDelay)
	end
end

-- == Colours ===================================================================
local function stateColor(isOn: boolean, state: string): number
	if not isOn then return TrafficLightPlacer.COLOR_RED end
	if state == "green" then return TrafficLightPlacer.COLOR_GREEN end
	if state == "yellow" then return TrafficLightPlacer.COLOR_YELLOW end
	return TrafficLightPlacer.COLOR_RED
end

local function applyColors(group: NodeSignal)
	local phase = group.phases[group.currentPhase]
	for armIndex, arm in ipairs(group.geometry.arms) do
		local main = stateColor(phase ~= nil and phase.greenArms[armIndex] == true, group.state)
		-- Arms with a dedicated left lane drive the side head as a protected-left
		-- indicator; arms without one leave it mirroring the main head (nil).
		local left: number? = nil
		if #arm.dedicatedLeftEdges > 0 then
			left = stateColor(phase ~= nil and phase.leftArms[armIndex] == true, group.state)
		end
		TrafficLightPlacer.SetArmColor(group.nodeId, armIndex, main, left)
	end
end

-- == Phase sequencing ==========================================================
local function phaseServesEdge(phase: Phase, edgeId: string): boolean
	return phase.greenEdges[edgeId] == true
end

-- Picks the phase an active emergency preemption should land on: prefer the
-- through phase covering the approach (most capacity), else any phase that does.
local function preemptPhaseIndex(group: NodeSignal, edgeId: string): number?
	local fallback: number? = nil
	for i, phase in ipairs(group.phases) do
		if phaseServesEdge(phase, edgeId) then
			if phase.kind == "through" then return i end
			fallback = fallback or i
		end
	end
	return fallback
end

-- Next phase to serve after all-red. Walks the ring, skipping left phases with
-- no left queue and running the ped slot only on its cadence.
local function advancePhase(group: NodeSignal): number
	if group.preemptEdgeId then
		local idx = preemptPhaseIndex(group, group.preemptEdgeId)
		if idx then return idx end
	end

	local n = #group.phases
	local idx = group.currentPhase

	-- Coordinated: run the ring straight through, skipping nothing. Every phase has
	-- been allocated a slice of the common cycle, so dropping one does not shorten the
	-- cycle -- it just leaves a hole, and after a few of those the junction has drifted
	-- off its offset and the corridor no longer progresses.
	if group.split then
		return (idx % n) + 1
	end

	for _ = 1, n do
		idx = (idx % n) + 1
		local phase = group.phases[idx]
		if phase.kind == "ped" then
			group.pedSlotPasses += 1
			if group.pedSlotPasses >= group.timings.pedEveryN then
				group.pedSlotPasses = 0
				return idx
			end
		elseif phase.kind == "left" then
			-- Dedicated left lanes are protected-only: without queue data the phase
			-- must run every cycle or those lanes would never be served.
			if not _queueProvider then return idx end
			local total = phaseQueue(phase)
			if total > 0 then return idx end
		else
			return idx
		end
	end

	-- Defensive: every group always contains a through phase.
	for i, phase in ipairs(group.phases) do
		if phase.kind == "through" then return i end
	end
	return 1
end

local function enterGreen(group: NodeSignal, phaseIndex: number)
	group.currentPhase = phaseIndex
	group.state = "green"
	local green = greenTimeFor(group, phaseIndex)

	-- COORDINATION CORRECTION. The coordinated phase absorbs the whole cycle's slack:
	-- if the junction is running late its green is shortened, if early it is stretched,
	-- so the NEXT cycle starts back on the offset. Real controllers do exactly this,
	-- and it is why the correction lands on the main street's through movement rather
	-- than on a side phase or on the all-red -- the through movement is the one with
	-- the slack to give, and stretching an all-red would just stop everybody.
	--
	-- Correcting here rather than by snapping the phase from the clock is what keeps
	-- every transition legal: the junction always walks green -> yellow -> all-red ->
	-- green, so it can never jump from one phase's green straight into another's.
	local split = group.split
	if split and phaseIndex == group.coordPhaseIndex and not group.preemptEdgeId then
		local err = SignalCoordinator.offsetError(_simClock, group.signalPlan.offset, split.cycle)
		green = math.max(green - err, minGreenFor(group, group.phases[phaseIndex]))
	end

	group.timer = green
	group.greenElapsed = 0
	group.gapPollAccum = 0
	applyColors(group)
end

-- == Tick ======================================================================
local function tickGroup(group: NodeSignal, now: number, dt: number)
	if #group.phases == 0 then return end

	-- Emergency preemption lapses when not refreshed, or at the hard cap.
	if group.preemptEdgeId and (now > group.preemptExpires or now > group.preemptHoldUntil) then
		group.preemptEdgeId = nil
	end

	local phase = group.phases[group.currentPhase]

	if group.state == "green" then
		group.timer -= dt
		group.greenElapsed += dt

		local preemptEdge = group.preemptEdgeId
		if preemptEdge then
			if phaseServesEdge(phase, preemptEdge) and phase.kind ~= "ped" then
				group.timer = math.max(group.timer, 1) -- hold green for the emergency vehicle
			else
				group.timer = 0 -- cut to yellow now; advancePhase will route to its approach
			end
		elseif _queueProvider and not group.split and phase.kind ~= "ped" and group.timer > 0
			and group.greenElapsed >= minGreenFor(group, phase) then
			-- Gap-out: once the minimum green is served, end early if nobody is left.
			-- Never for a coordinated junction -- ending a green early there shortens the
			-- cycle, and a cycle that is not the corridor's cycle is not coordinated.
			group.gapPollAccum += dt
			if group.gapPollAccum >= TrafficConfig.GAP_OUT_POLL then
				group.gapPollAccum = 0
				local total = phaseQueue(phase)
				if total == 0 then group.timer = 0 end
			end
		end

		if group.timer <= 0 then
			if phase.kind == "ped" then
				-- No yellow after a walk window; clear straight through all-red.
				group.state = "allred"
				group.timer = group.timings.allRed
			else
				group.state = "yellow"
				group.timer = group.timings.yellow
			end
			applyColors(group)
		end
	elseif group.state == "yellow" then
		group.timer -= dt
		if group.timer <= 0 then
			group.state = "allred"
			group.timer = group.timings.allRed
			applyColors(group)
		end
	else -- allred
		group.timer -= dt
		if group.timer <= 0 then
			enterGreen(group, advancePhase(group))
		end
	end
end

-- == Discovery =================================================================
local function clearAllSignals()
	table.clear(_groups)
	table.clear(_edgeSignalNode)
	table.clear(_approachDelay)
	TrafficLightPlacer.Clear()
end

local function networkHasSegments(network: any): boolean
	for _ in pairs(network:getSegments()) do
		return true
	end
	return false
end

local function firstThroughIndex(phases: { Phase }): number
	for i, phase in ipairs(phases) do
		if phase.kind == "through" then return i end
	end
	return 1
end

local function nodePosition(nodeId: number): Vector3?
	if not _roadService then return nil end
	local network = _roadService.getNetwork()
	if not network then return nil end
	local node = network:getNodes()[nodeId]
	return if node then node.position else nil
end

-- Which phase the offset is measured against. Coordination progresses a THROUGH
-- movement -- that is the whole point of a green wave -- so a coordinated phase that
-- is not one is quietly corrected rather than obeyed. The player's explicit choice is
-- honoured whenever it names a real through phase.
local function resolveCoordPhase(signalPlan: SignalSpec.SignalPlan, phases: { Phase }): number
	local want = signalPlan.coordPhase
	if want >= 1 and want <= #phases and phases[want].kind == "through" then
		return want
	end
	return firstThroughIndex(phases)
end

-- The fixed-time carve-up of the cycle, or nil when this junction free-runs. Two ways
-- in: joining a coordination group (which supplies the common cycle every member must
-- share) or choosing a fixed cycle on a standalone junction.
local function resolveSplit(nodeId: number, signalPlan: SignalSpec.SignalPlan, phases: { Phase }, coordPhase: number): SignalCoordinator.SplitPlan?
	local cycle: number? = nil
	local coordGroup = SignalPlanStore.groupOf(nodeId)
	if coordGroup then
		cycle = coordGroup.cycle
	elseif signalPlan.custom and signalPlan.cycleMode == "fixed" then
		cycle = signalPlan.cycle
	end
	if not cycle or #phases == 0 then return nil end

	local split = SignalCoordinator.buildSplitPlan(phases, signalPlan, cycle)
	return SignalCoordinator.rotateToCoordPhase(split, coordPhase)
end

-- Recomputes every auto-offset corridor. Runs before the per-node rebuild below so the
-- offsets the split plans are anchored to are the current ones -- a road edit that
-- moves a junction changes the spacing, and therefore the wave.
local function refreshAutoOffsets()
	for _, coordGroup in pairs(SignalPlanStore.allGroups()) do
		if coordGroup.autoOffsets and #coordGroup.nodeIds > 1 then
			SignalCoordinator.applyAutoOffsets(coordGroup, nodePosition)
		end
	end
end

local function discoverIntersections(force: boolean?): boolean
	if not _roadService then return false end
	local graph = _roadService.getNavigationGraph()
	local network = _roadService.getNetwork()
	if not graph or not network then return false end

	if not graph:HasEdges() then
		clearAllSignals()
		_lastGraphVersion = -1
		-- An empty network is a valid steady state; a non-empty one means the nav
		-- rebuild is still pending and we should retry.
		return not networkHasSegments(network)
	end

	local graphVersion = graph:Version()
	if not force and graphVersion == _lastGraphVersion then return true end
	_lastGraphVersion = graphVersion

	SignalPlanStore.reconcile()
	refreshAutoOffsets()

	local geometries = IntersectionDetector.detect(_roadService)
	table.clear(_edgeSignalNode)
	local activeNodes: { [number]: boolean } = {}

	for nodeId, geometry in pairs(geometries) do
		local signalPlan = SignalPlanStore.planFor(nodeId)
		local phasePlan = SignalPhaseBuilder.build(geometry, graph, signalPlan)
		if #phasePlan.phases == 0 then continue end
		activeNodes[nodeId] = true

		local coordPhase = resolveCoordPhase(signalPlan, phasePlan.phases)
		local split = resolveSplit(nodeId, signalPlan, phasePlan.phases, coordPhase)
		local timings = resolveTimings(signalPlan)

		local existing = _groups[nodeId]
		if existing and #existing.geometry.arms == #geometry.arms and #existing.phases == #phasePlan.phases then
			-- Same structure: swap in fresh geometry/edges, keep the running cycle.
			existing.geometry = geometry
			existing.phases = phasePlan.phases
			existing.hasPed = phasePlan.hasPed
			existing.pedConcurrent = phasePlan.pedConcurrent
			existing.signalPlan = signalPlan
			existing.timings = timings
			existing.split = split
			existing.coordPhaseIndex = coordPhase
		else
			-- New or reshaped intersection: start staggered so a fresh grid does
			-- not flip every light in lockstep. A COORDINATED junction skips the
			-- stagger -- its start time is the offset, and a random head start is
			-- exactly the drift coordination exists to remove.
			local startTimer = if split then timings.minGreen else timings.minGreen + (nodeId % 7)
			local group: NodeSignal = {
				nodeId = nodeId,
				geometry = geometry,
				phases = phasePlan.phases,
				hasPed = phasePlan.hasPed,
				pedConcurrent = phasePlan.pedConcurrent,
				signalPlan = signalPlan,
				timings = timings,
				split = split,
				coordPhaseIndex = coordPhase,
				currentPhase = coordPhase,
				state = "green",
				timer = startTimer,
				greenElapsed = 0,
				gapPollAccum = 0,
				pedSlotPasses = 0,
				preemptEdgeId = nil,
				preemptExpires = 0,
				preemptHoldUntil = 0,
			}
			_groups[nodeId] = group
		end

		for _, phase in ipairs(phasePlan.phases) do
			for edgeId in pairs(phase.greenEdges) do
				_edgeSignalNode[edgeId] = nodeId
			end
		end

		TrafficLightPlacer.SyncNode(geometry)
	end

	for nodeId in pairs(_groups) do
		if not activeNodes[nodeId] then
			_groups[nodeId] = nil
			TrafficLightPlacer.RemoveNode(nodeId)
		end
	end

	for _, group in pairs(_groups) do
		group.currentPhase = math.clamp(group.currentPhase, 1, #group.phases)
		applyColors(group)
	end
	rebuildApproachDelays(graph)
	return true
end

local function queueDiscover(force: boolean?)
	_discoverForce = _discoverForce or force == true
	if _discoverPending then return end
	_discoverPending = true
	local wait = math.max(0, _lastDiscoverAt + DISCOVER_DEBOUNCE - os.clock())
	task.delay(wait, function()
		_discoverPending = false
		_lastDiscoverAt = os.clock()
		local forceNow = _discoverForce
		_discoverForce = false
		if not discoverIntersections(forceNow) then
			task.delay(0.25, function()
				queueDiscover(forceNow)
			end)
		end
	end)
end

-- == Public API: right-of-way queries (NPCDriverService contract) ==============

-- True if the incoming edge may proceed (optionally to a specific exit).
-- Yellow, all-red, and the ped phase all read as "stop".
function TrafficSignalService.CanGo(edgeId: string, nextEdgeId: string?): boolean
	if not _initialized then return true end
	local nodeId = _edgeSignalNode[edgeId]
	if not nodeId then return true end
	local group = _groups[nodeId]
	if not group then return true end
	if group.state ~= "green" then return false end

	local phase = group.phases[group.currentPhase]
	if not phase or not phase.greenEdges[edgeId] then return false end

	if nextEdgeId then
		local allowed = phase.allowedConnections[edgeId]
		if not allowed then return false end
		return allowed[nextEdgeId] == true or allowed["*"] == true
	end
	return true
end

function TrafficSignalService.HasSignal(nodeId: number): boolean
	return _groups[nodeId] ~= nil
end

function TrafficSignalService.IsYellow(nodeId: number): boolean
	local group = _groups[nodeId]
	return group ~= nil and group.state == "yellow"
end

-- True ONLY for an edge whose own approach is clearing on yellow. Red arms stay
-- false while the crossing group yellows, so they never jump the change.
function TrafficSignalService.IsApproachYellow(edgeId: string): boolean
	local nodeId = _edgeSignalNode[edgeId]
	if not nodeId then return false end
	local group = _groups[nodeId]
	if not group or group.state ~= "yellow" then return false end
	local phase = group.phases[group.currentPhase]
	return phase ~= nil and phase.greenEdges[edgeId] == true
end

function TrafficSignalService.GetPhase(nodeId: number): number?
	local group = _groups[nodeId]
	return group and group.currentPhase or nil
end

-- True while pedestrians may cross at this node.
--
-- Two ways that happens. A SCRAMBLE junction has an exclusive walk phase and the
-- answer is simply whether that phase is up. A CONCURRENT junction -- the US default,
-- and what a player picks to stop the walk phase eating the cycle -- has no ped phase
-- at all: people cross beside the parallel through movement, so any through green is
-- a walk window.
function TrafficSignalService.IsPedWalk(nodeId: number): boolean
	local group = _groups[nodeId]
	if not group or group.state ~= "green" then return false end
	local phase = group.phases[group.currentPhase]
	if not phase then return false end
	if group.pedConcurrent then
		return phase.kind == "through"
	end
	return phase.kind == "ped"
end

-- == Public API: integrations ==================================================

-- Bootstrap injects NPCDriverService.GetSignalQueue here. Provider contract:
-- (edgeIds) -> (carsQueuedTotal, carsQueuedToTurnLeft).
function TrafficSignalService.SetQueueProvider(provider: (({ string }) -> (number, number))?)
	_queueProvider = provider
end

-- Emergency vehicles call this every frame while approaching a red-able signal.
-- Requests are leases: they lapse PREEMPT_TTL after the last refresh and are
-- hard-capped at PREEMPT_MAX_HOLD so a stuck vehicle cannot own a junction.
function TrafficSignalService.RequestEmergencyPreemption(nodeId: number, edgeId: string)
	local group = _groups[nodeId]
	if not group then return end
	if _edgeSignalNode[edgeId] ~= nodeId then return end

	local now = os.clock()
	if group.preemptEdgeId and group.preemptEdgeId ~= edgeId and now <= group.preemptExpires then
		return -- first emergency keeps the junction until its lease lapses
	end
	if group.preemptEdgeId ~= edgeId then
		group.preemptEdgeId = edgeId
		group.preemptHoldUntil = now + TrafficConfig.PREEMPT_MAX_HOLD
	end
	group.preemptExpires = now + TrafficConfig.PREEMPT_TTL
end

-- == Public API: the signal editor ===========================================

-- The arm most nearly opposite this one, which is the traffic a crossing turn has to
-- cut across. Everything the left-turn warrants care about (how many lanes, how fast)
-- is a property of THAT arm, not of the one turning.
local function opposingArm(geometry: IntersectionDetector.IntersectionPlan, armIndex: number): IntersectionDetector.Arm?
	local arm = geometry.arms[armIndex]
	if not arm then return nil end
	local best: IntersectionDetector.Arm? = nil
	local bestDot = -0.65 -- same anti-parallel threshold the phase builder pairs on
	for i, other in ipairs(geometry.arms) do
		if i ~= armIndex then
			local dot = arm.dir:Dot(other.dir)
			if dot < bestDot then
				bestDot = dot
				best = other
			end
		end
	end
	return best
end

local function armSpeedKmh(arm: IntersectionDetector.Arm): number
	if not _roadService then return 50 end
	local network = _roadService.getNetwork()
	local seg = if network then network:getSegment(arm.segmentId) else nil
	if not seg then return 50 end
	return RoadRules.getSpeedLimitKmh(seg, RoadTypeCatalog.getOrDefault(seg.roadType))
end

-- Everything SignalSpec.validate needs to judge a plan for this junction. Built on the
-- server because it reads the live geometry; sent to the client so the panel can warn
-- BEFORE the player commits rather than rejecting afterwards.
function TrafficSignalService.BuildValidateContext(nodeId: number): SignalSpec.ValidateContext?
	local group = _groups[nodeId]
	if not group then return nil end
	local geometry = group.geometry

	local hasLeft: { [number]: boolean } = {}
	local opposingLanes: { [number]: number } = {}
	local speeds: { [number]: number } = {}

	for i, arm in ipairs(geometry.arms) do
		hasLeft[i] = #arm.dedicatedLeftEdges > 0
		local facing = opposingArm(geometry, i)
		-- One lane edge per lane, so the count of through edges IS the lane count the
		-- turn crosses -- which is the number the protected-left warrants are written in.
		opposingLanes[i] = if facing then #facing.throughEdges else 0
		speeds[i] = armSpeedKmh(arm)
	end

	local coordGroup = SignalPlanStore.groupOf(nodeId)
	return {
		armCount = #geometry.arms,
		armHasDedicatedLeft = hasLeft,
		armOpposingThroughLanes = opposingLanes,
		armSpeedKmh = speeds,
		groupCycle = if coordGroup then coordGroup.cycle else nil,
	}
end

-- One junction, described for the editor panel: its arms, the plan in force, the
-- corridor it belongs to, and what the lamps are doing right now.
function TrafficSignalService.GetNodeEditorSnapshot(nodeId: number): { [string]: any }?
	local group = _groups[nodeId]
	if not group then return nil end
	local geometry = group.geometry

	local arms: { any } = {}
	for i, arm in ipairs(geometry.arms) do
		local facing = opposingArm(geometry, i)
		table.insert(arms, {
			index = i,
			-- arm.dir points INTO the node; the player thinks of the road heading away,
			-- which is also the convention the node tool labels its arms with.
			bearing = math.round((math.deg(math.atan2(-arm.dir.X, -arm.dir.Z)) + 360) % 360),
			hasDedicatedLeft = #arm.dedicatedLeftEdges > 0,
			throughLanes = #arm.throughEdges,
			opposingLanes = if facing then #facing.throughEdges else 0,
			speedKmh = math.round(armSpeedKmh(arm)),
			axis = arm.axis,
		})
	end

	local phases: { any } = {}
	for i, phase in ipairs(group.phases) do
		local slot = slotFor(group, i)
		table.insert(phases, {
			index = i,
			label = phase.label,
			kind = phase.kind,
			green = if slot then math.round(slot.green * 10) / 10 else nil,
		})
	end

	local coordGroup = SignalPlanStore.groupOf(nodeId)
	local pos = geometry.pos

	return {
		nodeId = nodeId,
		x = pos.X, y = pos.Y, z = pos.Z,
		arms = arms,
		phases = phases,
		plan = SignalPlanStore.planFor(nodeId),
		groupId = if coordGroup then coordGroup.id else nil,
		coordPhase = group.coordPhaseIndex,
		coordinated = group.split ~= nil,
		cycle = if group.split then group.split.cycle else nil,
		-- Live state, so the panel's phase list can highlight what is lit right now.
		livePhase = group.currentPhase,
		liveState = group.state,
		liveTimer = math.round(group.timer * 10) / 10,
	}
end

-- Every signalised junction's position, for the tool's world-space dots. Cheap enough
-- to send whenever the tool opens; the panel needs a pickable set, not live state.
function TrafficSignalService.GetSignalNodes(): { any }
	local out: { any } = {}
	for nodeId, group in pairs(_groups) do
		local pos = group.geometry.pos
		local coordGroup = SignalPlanStore.groupOf(nodeId)
		table.insert(out, {
			nodeId = nodeId,
			x = pos.X, y = pos.Y, z = pos.Z,
			arms = #group.geometry.arms,
			custom = group.signalPlan.custom,
			groupId = if coordGroup then coordGroup.id else nil,
		})
	end
	return out
end

function TrafficSignalService.GetDebugSnapshot(): { any }
	local out: { any } = {}
	for nodeId, group in pairs(_groups) do
		local phase = group.phases[group.currentPhase]
		table.insert(out, {
			nodeId = nodeId,
			numArms = #group.geometry.arms,
			numPhases = #group.phases,
			currentPhase = group.currentPhase,
			phaseLabel = phase and phase.label or "?",
			state = group.state,
			timer = math.round(group.timer * 10) / 10,
			preempting = group.preemptEdgeId ~= nil,
		})
	end
	return out
end

-- == Lifecycle =================================================================
function TrafficSignalService.Init(roadService: any)
	_roadService = roadService
	_initialized = false
	_lastGraphVersion = -1
	_simClock = 0
	table.clear(_groups)
	table.clear(_edgeSignalNode)
	SignalPlanStore.Init(roadService)
	TrafficLightPlacer.Init()
	-- The player's lights on / off choice per junction (the Roads panel's Traffic Light card)
	-- lives in the signal plans; every "does this junction have lights" question asks it.
	RoadRules.setControlOverride(function(nodeId: number): RoadRules.NodeControl?
		local plan = SignalPlanStore.rawPlan(nodeId)
		if plan and plan.control ~= "auto" then
			return plan.control :: RoadRules.NodeControl
		end
		return nil
	end)
end

function TrafficSignalService.Bind()
	if _bound then return end
	_bound = true
	if _roadService and _roadService.onTopologyChanged then
		_topologyDisconnect = _roadService.onTopologyChanged(function(_change: any?)
			queueDiscover(true)
		end)
	end
	-- A plan edit changes the phase LAYOUT, not just its durations (a left-turn mode
	-- adds or removes a phase, a ped mode adds or removes the walk slot), so it has to
	-- go through the same rebuild a road edit does. It rides the same debounce, which
	-- is what keeps dragging a stepper from rebuilding the junction on every keypress.
	_planDisconnect = SignalPlanStore.onChanged(function(_nodeId: number?)
		queueDiscover(true)
	end)
end

function TrafficSignalService.Start()
	_initialized = false

	if _heartbeat then
		_heartbeat:Disconnect()
		_heartbeat = nil
	end

	-- Try once now, then keep retrying until the road graph catches up (a non-empty
	-- network with no graph edges means a deferred nav rebuild is still pending).
	if discoverIntersections(true) then
		_initialized = true
	else
		task.spawn(function()
			while not _initialized do
				task.wait(0.25)
				if discoverIntersections(true) then
					_initialized = true
				end
			end
		end)
	end

	local tickAccum = 0
	local delayAccum = 0
	_heartbeat = RunService.Heartbeat:Connect(function(dt: number)
		if not _initialized then return end
		tickAccum += math.min(dt, 0.25)

		-- Webster's saturation term rides live congestion, so the published delays are
		-- refreshed on a slow cadence. Far cheaper than the phase tick and routing does
		-- not need it any fresher -- a junction's character changes over minutes.
		delayAccum += math.min(dt, 0.25)
		if delayAccum >= DELAY_REFRESH then
			delayAccum = 0
			if _roadService then
				rebuildApproachDelays(_roadService.getNavigationGraph())
			end
		end

		if tickAccum < SIGNAL_TICK then return end
		local tickDt = tickAccum
		tickAccum = 0

		-- Signal phases and queue sampling run at 10 Hz. Lamps only change on phase
		-- transitions, so checking every render frame creates no additional visual detail.
		local speed = math.clamp(tonumber(workspace:GetAttribute("GameSpeed")) or 1, 0, 3)
		local scaledDt = tickDt * speed
		-- The corridor master clock advances on the same scaled dt every cycle runs on,
		-- so a paused or fast-forwarded city keeps its offsets intact.
		_simClock += scaledDt
		local now = os.clock()
		for _, group in pairs(_groups) do
			tickGroup(group, now, scaledDt)
		end
	end)
end

return TrafficSignalService
