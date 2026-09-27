--!strict
-- SignalSpec
-- The signal-timing SCHEMA, shared by the client panel and the server controller.
--
-- One module owns it because both sides must agree exactly: the panel offers a range,
-- the server clamps to a range, and if those two ever drift the player types a number
-- that silently becomes a different number. Everything here is pure -- no state, no
-- lifecycle, no side effects on require -- so the client can require it to build a
-- panel and the server can require it to sanitise a remote payload.
--
-- The numbers are not invented. Where a value has a legal or engineering source it is
-- cited inline (MUTCD 11th Ed., the ITE kinematic equation, Webster 1958, the FHWA
-- Signal Timing Manual). Where a bound is a game-design choice it says so.

local RoadConstants = require(script.Parent.RoadConstants)

local SignalSpec = {}

-- == Unit bridges ============================================================
-- Distances cross the wire in STUDS (the network's unit) and reach the player in
-- METRES. STUD_TO_METER already rides WORLD_SCALE, so both conversions below are
-- correct at any world scale without a second knob.
local STUD_TO_METER = RoadConstants.STUD_TO_METER
local STUDS_PER_KMH = (1 / 3.6) / STUD_TO_METER
local FEET_TO_METERS = 0.3048

-- MUTCD 11th Ed. Section 4I.06: pedestrian clearance is timed at 3.5 ft/s.
local PED_WALK_SPEED_STUDS = (3.5 * FEET_TO_METERS) / STUD_TO_METER
-- Design vehicle length for the red-clearance equation, R = (W + L) / v. 20 ft is
-- the value US practice uses for L.
local DESIGN_VEHICLE_STUDS = (20 * FEET_TO_METERS) / STUD_TO_METER

-- == Enumerations ============================================================

-- How an approach's crossing turn (US left) is served.
--   auto       -- what the geometry implies, the pre-existing behaviour
--   permissive -- filters through gaps on the through green; no separate head
--   protected  -- its own phase, opposing traffic held; needs a dedicated lane
--   ppLeft     -- protected phase THEN a permissive window on a flashing yellow arrow
--   split      -- this approach gets the whole intersection to itself
export type LeftMode = "auto" | "permissive" | "protected" | "ppLeft" | "split"

-- none       -- no walk phase at all
-- concurrent -- pedestrians cross alongside the parallel through green (US default)
-- scramble   -- an exclusive all-red phase, every crosswalk open at once
export type PedMode = "none" | "concurrent" | "scramble"

export type CycleMode = "adaptive" | "fixed"
-- Whether the junction has lights at all. "auto" follows the road hierarchy
-- (RoadRules.nodeControl); "signal" puts lights up where the rules would not; "priority"
-- takes them down and runs the junction on give-way.
export type ControlMode = "auto" | "signal" | "priority"

SignalSpec.LEFT_MODES = table.freeze({ "auto", "permissive", "protected", "ppLeft", "split" })
SignalSpec.PED_MODES = table.freeze({ "none", "concurrent", "scramble" })
SignalSpec.CYCLE_MODES = table.freeze({ "adaptive", "fixed" })
SignalSpec.CONTROL_MODES = table.freeze({ "auto", "signal", "priority" })

-- Two label sets, because five options have to fit a 240px chip row. LABELS is what
-- goes on the chips; NAMES is the readable form for hints and list rows. Both live
-- here so the client and any future surface never disagree about what "ppLeft" is
-- called in front of the player.
SignalSpec.LEFT_MODE_LABELS = table.freeze({
	auto = "Auto",
	permissive = "Perm",
	protected = "Prot",
	ppLeft = "P+P",
	split = "Split",
})

SignalSpec.LEFT_MODE_NAMES = table.freeze({
	auto = "Automatic",
	permissive = "Permissive",
	protected = "Protected",
	ppLeft = "Protected + permissive",
	split = "Split phase",
})

-- One line each, for the panel's hint under the chips. A player picking between five
-- turn treatments needs to know what they DO, not just what they are called.
SignalSpec.LEFT_MODE_HINTS = table.freeze({
	auto = "Protected where a dedicated turn lane exists, permissive everywhere else.",
	permissive = "Turns filter through gaps in oncoming traffic. No separate phase, so the cycle stays short.",
	protected = "Its own phase with oncoming traffic held. Safest, but costs the cycle a phase.",
	ppLeft = "A protected phase clears the queue, then a flashing yellow arrow lets stragglers filter.",
	split = "This approach gets the whole junction to itself. For offset approaches that cannot run together.",
})

SignalSpec.PED_MODE_LABELS = table.freeze({
	none = "None",
	concurrent = "Concurrent",
	scramble = "Scramble",
})

-- == Bounds ==================================================================
-- LEGAL bounds carry a citation and are enforced on the server no matter what the
-- client sends. PLAY bounds are game-design limits: wide enough to be expressive,
-- narrow enough that a slipped keystroke cannot produce a five-minute red.
SignalSpec.Bounds = table.freeze({
	-- Green intervals. A through movement's floor in US practice is 4-10 s; the
	-- ceiling on an urban arterial runs 30-60 s.
	minGreen = { min = 3, max = 20, default = 6, step = 1 },
	maxGreen = { min = 8, max = 90, default = 16, step = 1 },
	leftMinGreen = { min = 3, max = 15, default = 4, step = 1 },
	leftMaxGreen = { min = 4, max = 40, default = 9, step = 1 },
	-- Adaptive stretch: seconds of extra green bought by each car in the queue.
	secPerCar = { min = 0, max = 4, default = 1.2, step = 0.1 },

	-- MUTCD 11th Ed. Section 4F.17: the yellow change interval is a Standard, 3-6 s.
	-- Neither end is a preference -- a yellow outside this range is not legal on a
	-- real approach, so the server clamps here and the panel cannot offer more.
	yellow = { min = 3.0, max = 6.0, default = 3.2, step = 0.1 },
	-- Red clearance. No fixed legal floor, but 6 s is the practical ceiling; 1-2 s
	-- on a local street, 2-3 s across an arterial box.
	allRed = { min = 0.5, max = 6.0, default = 1.5, step = 0.1 },

	-- MUTCD 11th Ed. Section 4I.06: the WALK interval should be at least 7 s, and may
	-- be shortened to 4 s only where pedestrian volumes do not need the full 7.
	pedWalk = { min = 4, max = 30, default = 7, step = 1 },
	pedEveryNCycles = { min = 1, max = 6, default = 2, step = 1 },

	-- Cycle length for fixed-time and coordinated operation. 60-90 s suits a simple
	-- two-phase junction, 90-120 s a multi-phase one, and past ~150 s the delay saved
	-- is swamped by the wait imposed on everyone else.
	cycle = { min = 30, max = 180, default = 90, step = 5 },
	-- Offset into the group cycle. Bounded by the cycle itself at validation time;
	-- this is only the hard ceiling.
	offset = { min = 0, max = 180, default = 0, step = 1 },
	-- Progression speed for a green wave, in km/h -- the speed the wave travels at,
	-- normally at or just under the corridor's speed limit.
	progressionKmh = { min = 10, max = 120, default = 50, step = 5 },
})

-- == Timing formulas =========================================================

-- ITE kinematic equation for the yellow change interval:
--   Y = t + v / (2a + 2Gg)
-- with perception-reaction t = 1.0 s, deceleration a = 10 ft/s^2 and level grade
-- (G = 0), which reduces to Y = 1.0 + 1.47V/20 for V in mph. Clamped into the
-- MUTCD 3-6 s Standard, which is why a 25 mph approach reads 3.0 rather than 2.8.
function SignalSpec.yellowForSpeedKmh(kmh: number): number
	local mph = kmh / 1.609344
	local raw = 1.0 + (1.47 * mph) / 20
	local b = SignalSpec.Bounds.yellow
	return math.clamp(math.round(raw * 10) / 10, b.min, b.max)
end

-- Red clearance R = (W + L) / v: long enough for a vehicle entering on the last of
-- the yellow to clear the far side of the conflict. W is the width the vehicle must
-- cross (the junction box), L the design vehicle, v the approach speed.
function SignalSpec.redClearance(crossWidthStuds: number, speedKmh: number): number
	local speedStuds = math.max(speedKmh * STUDS_PER_KMH, 1e-3)
	local raw = (crossWidthStuds + DESIGN_VEHICLE_STUDS) / speedStuds
	local b = SignalSpec.Bounds.allRed
	return math.clamp(math.round(raw * 10) / 10, b.min, b.max)
end

-- Pedestrian clearance (the flashing DON'T WALK) at the MUTCD's 3.5 ft/s. This is
-- the time to cross, NOT counting the WALK interval that precedes it.
function SignalSpec.pedClearance(crossWidthStuds: number): number
	return math.round((crossWidthStuds / PED_WALK_SPEED_STUDS) * 10) / 10
end

-- Webster's optimum cycle (1958), the classic delay-minimising length:
--   C = (1.5L + 5) / (1 - sum(Y))
-- L is the lost time per cycle (the change intervals plus start-up loss) and each Y
-- is a phase's critical flow ratio. It blows up as the flow ratio approaches 1, so
-- the result is clamped -- an oversaturated junction has no optimum, only triage.
function SignalSpec.websterCycle(lostTime: number, sumFlowRatio: number): number
	local b = SignalSpec.Bounds.cycle
	local denom = 1 - math.clamp(sumFlowRatio, 0, 0.95)
	if denom <= 0.05 then return b.max end
	local raw = (1.5 * lostTime + 5) / denom
	-- Cycles are conventionally rounded to the nearest 5 s.
	return math.clamp(math.round(raw / 5) * 5, b.min, b.max)
end

-- Offset for a green wave: the time the platoon needs to travel between two stop
-- lines, so the downstream green opens exactly as the platoon reaches it.
function SignalSpec.travelOffset(distanceStuds: number, progressionKmh: number): number
	local speedStuds = math.max(progressionKmh * STUDS_PER_KMH, 1e-3)
	return distanceStuds / speedStuds
end

-- The spacing at which PERFECT two-way progression exists: half a cycle of travel.
-- Two-way progression is only free at this spacing (and its multiples) -- anywhere
-- else, bandwidth in one direction is bought from the other. Reported to the player
-- so an unavoidable compromise reads as geometry rather than as a bug.
function SignalSpec.idealSpacingStuds(progressionKmh: number, cycle: number): number
	return progressionKmh * STUDS_PER_KMH * cycle * 0.5
end

-- Bandwidth efficiency: the share of the cycle a platoon can ride through without
-- stopping. Above ~0.35 is generally considered good progression.
function SignalSpec.bandwidthEfficiency(bandwidth: number, cycle: number): number
	if cycle <= 0 then return 0 end
	return math.clamp(bandwidth / cycle, 0, 1)
end

-- Beyond roughly half a mile a platoon has dispersed into ordinary random arrivals
-- and there is nothing left to progress -- coordinating that far apart buys nothing
-- and still taxes the side streets. 800 m, in studs.
SignalSpec.COORDINATION_MAX_SPACING_STUDS = 800 / STUD_TO_METER

-- == Plans ===================================================================

export type ArmPlan = {
	leftMode: LeftMode,
}

export type SignalPlan = {
	-- false = the junction runs on the global defaults exactly as it always has.
	-- Every field below is ignored until the player switches it on.
	custom: boolean,

	cycleMode: CycleMode,
	cycle: number,

	minGreen: number,
	maxGreen: number,
	leftMinGreen: number,
	leftMaxGreen: number,
	secPerCar: number,
	yellow: number,
	allRed: number,

	pedMode: PedMode,
	pedWalk: number,
	pedEveryNCycles: number,

	-- Lefts run BEFORE their through phase (leading) or after it (lagging). Lagging
	-- is what makes a corridor progress, and is also what creates the yellow trap --
	-- see SignalSpec.validate.
	leadingLefts: boolean,

	-- Per-arm overrides, keyed by the arm's stable index within the intersection.
	arms: { [number]: ArmPlan },

	-- Coordination. groupId is nil for a free-running junction.
	groupId: string?,
	offset: number,
	-- Which phase index the offset is measured against -- the coordinated phase,
	-- conventionally the main street's through movement.
	coordPhase: number,

	-- Lights on, off, or as the road hierarchy decides. Applies whether or not `custom` is
	-- set: it is about whether there ARE lights, not how they are timed.
	control: ControlMode,
}

function SignalSpec.defaultPlan(): SignalPlan
	local B = SignalSpec.Bounds
	return {
		custom = false,
		cycleMode = "adaptive",
		cycle = B.cycle.default,
		minGreen = B.minGreen.default,
		maxGreen = B.maxGreen.default,
		leftMinGreen = B.leftMinGreen.default,
		leftMaxGreen = B.leftMaxGreen.default,
		secPerCar = B.secPerCar.default,
		yellow = B.yellow.default,
		allRed = B.allRed.default,
		pedMode = "scramble",
		pedWalk = B.pedWalk.default,
		pedEveryNCycles = B.pedEveryNCycles.default,
		leadingLefts = true,
		arms = {},
		groupId = nil,
		offset = 0,
		coordPhase = 1,
		control = "auto",
	}
end

local function clampField(raw: any, key: string): number
	local b = SignalSpec.Bounds[key]
	local n = tonumber(raw)
	if not n or n ~= n then return b.default end -- rejects nil, non-numbers and NaN
	return math.clamp(n, b.min, b.max)
end

local function oneOf(raw: any, allowed: { string }, fallback: string): string
	if typeof(raw) == "string" then
		for _, v in allowed do
			if v == raw then return raw end
		end
	end
	return fallback
end

-- Turns anything at all into a legal plan. This is the ONLY way a plan is allowed to
-- enter the server: the remote handler hands the raw payload straight here, so a
-- forged or malformed table becomes a valid plan rather than a rejected one, and no
-- field downstream ever has to re-check its own range.
function SignalSpec.sanitizePlan(raw: any): SignalPlan
	local plan = SignalSpec.defaultPlan()
	if typeof(raw) ~= "table" then return plan end

	plan.custom = raw.custom == true
	plan.cycleMode = oneOf(raw.cycleMode, SignalSpec.CYCLE_MODES, "adaptive") :: CycleMode
	plan.pedMode = oneOf(raw.pedMode, SignalSpec.PED_MODES, "scramble") :: PedMode
	plan.leadingLefts = raw.leadingLefts ~= false
	plan.control = oneOf(raw.control, SignalSpec.CONTROL_MODES, "auto") :: ControlMode

	for _, key in { "cycle", "minGreen", "maxGreen", "leftMinGreen", "leftMaxGreen",
		"secPerCar", "yellow", "allRed", "pedWalk", "pedEveryNCycles", "offset" } do
		(plan :: any)[key] = clampField((raw :: any)[key], key)
	end

	-- A max below its min is not a rejection, it is a misordered pair: lift the max.
	-- Rejecting would leave the player with a field that refuses to take a value and
	-- never says why.
	plan.maxGreen = math.max(plan.maxGreen, plan.minGreen)
	plan.leftMaxGreen = math.max(plan.leftMaxGreen, plan.leftMinGreen)

	local coordPhase = tonumber(raw.coordPhase)
	plan.coordPhase = if coordPhase and coordPhase == coordPhase then math.clamp(math.floor(coordPhase), 1, 12) else 1

	if typeof(raw.groupId) == "string" and #raw.groupId > 0 and #raw.groupId <= 32 then
		plan.groupId = raw.groupId
	end

	if typeof(raw.arms) == "table" then
		-- Capped at 12: no junction in this game has more arms than that, and an
		-- unbounded loop here is a table the client could grow without limit.
		for key, value in pairs(raw.arms) do
			local index = tonumber(key)
			if index and index == index and index >= 1 and index <= 12 and typeof(value) == "table" then
				plan.arms[math.floor(index)] = {
					leftMode = oneOf(value.leftMode, SignalSpec.LEFT_MODES, "auto") :: LeftMode,
				}
			end
		end
	end

	return plan
end

function SignalSpec.armPlan(plan: SignalPlan, armIndex: number): ArmPlan
	return plan.arms[armIndex] or { leftMode = "auto" }
end

-- == Coordination groups =====================================================

export type SignalGroup = {
	id: string,
	name: string,
	nodeIds: { number },
	-- Every signal in a group runs the SAME cycle length. Without that the offsets
	-- drift apart within minutes and the wave dissolves -- it is the one
	-- non-negotiable rule of coordination, so it lives on the group, not the node.
	cycle: number,
	progressionKmh: number,
	-- true  -- offsets recomputed from real spacing whenever the corridor changes
	-- false -- the player has dialled each offset by hand and owns them
	autoOffsets: boolean,
	-- The node the wave starts from. Offsets are measured from this one.
	masterNodeId: number?,
}

function SignalSpec.defaultGroup(id: string, name: string): SignalGroup
	return {
		id = id,
		name = name,
		nodeIds = {},
		cycle = SignalSpec.Bounds.cycle.default,
		progressionKmh = SignalSpec.Bounds.progressionKmh.default,
		autoOffsets = true,
		masterNodeId = nil,
	}
end

local MAX_GROUP_NODES = 32

function SignalSpec.sanitizeGroup(raw: any): SignalGroup?
	if typeof(raw) ~= "table" then return nil end
	if typeof(raw.id) ~= "string" or #raw.id == 0 or #raw.id > 32 then return nil end

	local name = if typeof(raw.name) == "string" and #raw.name > 0 then string.sub(raw.name, 1, 40) else raw.id
	local group = SignalSpec.defaultGroup(raw.id, name)

	group.cycle = clampField(raw.cycle, "cycle")
	group.progressionKmh = clampField(raw.progressionKmh, "progressionKmh")
	group.autoOffsets = raw.autoOffsets ~= false

	local master = tonumber(raw.masterNodeId)
	if master and master == master then
		group.masterNodeId = math.floor(master)
	end

	if typeof(raw.nodeIds) == "table" then
		local seen: { [number]: boolean } = {}
		for _, value in ipairs(raw.nodeIds) do
			local id = tonumber(value)
			if id and id == id then
				id = math.floor(id)
				if not seen[id] then
					seen[id] = true
					table.insert(group.nodeIds, id)
					if #group.nodeIds >= MAX_GROUP_NODES then break end
				end
			end
		end
	end

	return group
end

-- == Validation ==============================================================
-- Two severities, and the difference matters. An "error" is a configuration that is
-- unsafe in the real world -- the server refuses it and the panel shows it in the
-- danger colour. A "warn" is merely a poor choice, and the player is allowed to make
-- poor choices: it renders, it does not block.

export type Issue = {
	severity: "error" | "warn",
	field: string,
	text: string,
}

export type ValidateContext = {
	armCount: number,
	-- Per arm: whether it has a lane that can only turn across (a dedicated left),
	-- how many through lanes the OPPOSING arm has, and the approach speed limit.
	armHasDedicatedLeft: { [number]: boolean },
	armOpposingThroughLanes: { [number]: number },
	armSpeedKmh: { [number]: number },
	-- Group context, when the node belongs to one.
	groupCycle: number?,
}

-- THE YELLOW TRAP, and why there is no check for it here.
--
-- The trap: a permissive left filters through gaps on a circular green, and the
-- driver judges the oncoming signal by watching the oncoming cars. If their own
-- through green ends BEFORE the oncoming one, a driver waiting in the box sees
-- yellow, assumes oncoming traffic is stopping too, and turns into traffic that
-- still has green. It is one of the classic fatal signal-design errors, and it is
-- what flashing yellow arrows and lead-lag restrictions exist to prevent.
--
-- It cannot happen here, and that is a property of SignalPhaseBuilder rather than a
-- rule enforced after the fact. The builder only ever puts a pair of opposing arms in
-- the SAME through phase, so their greens begin and end together; and `leadingLefts`
-- is one flag for the whole junction, so there is no way to lead one direction's left
-- and lag the other's -- the actual lead-lag arrangement that springs the trap. Where
-- an arm is split-phased, its opposite is red throughout, so a permissive left there
-- has no oncoming traffic to be trapped by.
--
-- An earlier version of this module raised an error on "lagging lefts + permissive",
-- which sounds right and is wrong: it blocked a configuration that is both legal and
-- common, because it reasoned about the plan instead of the phases the plan produces.
--
-- IF PER-ARM LEAD/LAG IS EVER ADDED, the trap becomes reachable and this check has to
-- come back -- and it must read the built phase list, not the plan, so it can ask the
-- only question that matters: do two opposing arms end their through greens at
-- different times while either one is running a permissive left?

function SignalSpec.validate(plan: SignalPlan, ctx: ValidateContext): { Issue }
	local issues: { Issue } = {}
	if not plan.custom then return issues end

	for armIndex = 1, ctx.armCount do
		local mode = SignalSpec.armPlan(plan, armIndex).leftMode
		local hasLane = ctx.armHasDedicatedLeft[armIndex] == true
		local opposingLanes = ctx.armOpposingThroughLanes[armIndex] or 0
		local speed = ctx.armSpeedKmh[armIndex] or 50

		-- A protected phase holds ONE lane group at green while everything else is red.
		-- With no dedicated lane there is nothing to hold: the through cars behind the
		-- turner would be released into a red they cannot legally cross.
		if (mode == "protected" or mode == "ppLeft") and not hasLane then
			table.insert(issues, {
				severity = "error",
				field = "arm" .. armIndex,
				text = string.format(
					"Arm %d has no dedicated left lane, so it cannot hold a protected phase. Give it one in the lane connector, or use Permissive or Split.",
					armIndex
				),
			})
		end

		-- Selection guidance, drawn from the standard protected-left warrants: three or
		-- more opposing through lanes, or a high-speed approach, is where permissive
		-- gap acceptance stops being safe. Advice, not law -- hence a warning.
		if mode == "permissive" and opposingLanes >= 3 then
			table.insert(issues, {
				severity = "warn",
				field = "arm" .. armIndex,
				text = string.format(
					"Arm %d turns across %d lanes on a permissive left. Three or more opposing lanes normally warrants a protected phase.",
					armIndex, opposingLanes
				),
			})
		elseif mode == "permissive" and speed >= 70 then
			table.insert(issues, {
				severity = "warn",
				field = "arm" .. armIndex,
				text = string.format(
					"Arm %d is a %d km/h approach. Permissive lefts are not normally used above 70 km/h -- gaps are too hard to judge.",
					armIndex, math.round(speed)
				),
			})
		end
	end

	-- Split phasing gives each approach the whole junction in turn. On a four-arm
	-- crossroads that is four phases where two would do, and every driver waits
	-- through all of them.
	local splitCount = 0
	for armIndex = 1, ctx.armCount do
		if SignalSpec.armPlan(plan, armIndex).leftMode == "split" then
			splitCount += 1
		end
	end
	if splitCount >= 3 then
		table.insert(issues, {
			severity = "warn",
			field = "arms",
			text = string.format(
				"%d arms are split-phased. Each one adds a full phase to the cycle -- expect long waits on every approach.",
				splitCount
			),
		})
	end

	-- A fixed cycle has to be long enough to actually contain its phases, or the
	-- controller silently truncates the last one to nothing.
	if plan.cycleMode == "fixed" or plan.groupId then
		local cycle = ctx.groupCycle or plan.cycle
		local phaseFloor = SignalSpec.minimumCycle(plan, ctx)
		if cycle < phaseFloor then
			table.insert(issues, {
				severity = "error",
				field = "cycle",
				text = string.format(
					"A %ds cycle cannot fit this junction's phases -- it needs at least %ds.",
					math.round(cycle), math.ceil(phaseFloor)
				),
			})
		end
		if plan.offset >= cycle then
			table.insert(issues, {
				severity = "error",
				field = "offset",
				text = string.format("Offset must be less than the %ds cycle.", math.round(cycle)),
			})
		end
	end

	if plan.pedMode == "scramble" and plan.pedWalk >= 12 and plan.cycleMode == "adaptive" then
		table.insert(issues, {
			severity = "warn",
			field = "pedWalk",
			text = "A long exclusive walk phase stops all traffic. Concurrent pedestrians cross on the parallel green instead and cost nothing.",
		})
	end

	return issues
end

-- The shortest cycle that can still serve every phase this plan implies: each phase
-- needs its minimum green plus a change interval, and the walk phase needs its full
-- WALK time. Used both by validation above and by the auto-cycle button.
function SignalSpec.minimumCycle(plan: SignalPlan, ctx: ValidateContext): number
	local change = plan.yellow + plan.allRed
	local total = 0

	-- Opposing arms share one through phase, so a plain crossroads is two -- except
	-- where an arm is split-phased, which takes a phase entirely to itself.
	local splitArms = 0
	local leftPhases = 0
	for armIndex = 1, ctx.armCount do
		local mode = SignalSpec.armPlan(plan, armIndex).leftMode
		if mode == "split" then
			splitArms += 1
		elseif mode == "protected" or mode == "ppLeft" then
			leftPhases += 1
		end
	end

	local throughArms = ctx.armCount - splitArms
	local throughPhases = math.max(1, math.ceil(throughArms / 2))

	total += throughPhases * (plan.minGreen + change)
	total += splitArms * (plan.minGreen + change)
	-- Opposing protected lefts run together as a dual-left, so the phase count is
	-- halved -- the same pairing the phase builder does.
	total += math.ceil(leftPhases / 2) * (plan.leftMinGreen + change)

	if plan.pedMode == "scramble" then
		total += plan.pedWalk + plan.allRed
	end

	return total
end

-- True when the plan has at least one error. The server refuses to store a plan that
-- fails this; the client greys its apply button on the same answer.
function SignalSpec.hasError(issues: { Issue }): boolean
	for _, issue in issues do
		if issue.severity == "error" then return true end
	end
	return false
end

return SignalSpec
