--!strict
-- SignalCoordinator
-- Turns a coordination group into the two things a controller actually needs: a SPLIT
-- PLAN (how the common cycle is carved up between a junction's phases) and an OFFSET
-- (where in that cycle the junction starts). Pure library over the plan store -- no
-- lifecycle, no heartbeat, no writes to anything but the offsets it is asked to solve.
--
-- WHY A COORDINATED SIGNAL STOPS BEING ADAPTIVE. A free-running junction ends its
-- green when its queue empties, so its cycle length wanders with demand. Two junctions
-- whose cycles wander independently cannot hold a fixed relationship, and the green
-- wave they were set up to produce dissolves within a few minutes. Coordination trades
-- the adaptive gap-out away for a fixed cycle -- that trade IS coordination, and it is
-- why joining a corridor switches a junction to fixed-time operation.
--
-- The corridor still keeps ONE useful piece of adaptiveness: the split allocation is
-- weighted, so a busy arterial phase takes a larger share of the fixed cycle than the
-- side street. It just cannot change the cycle's LENGTH.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SignalSpec = require(ReplicatedStorage.Road.SignalSpec)
local SignalPlanStore = require(script.Parent.SignalPlanStore)
local TrafficConfig = require(script.Parent.TrafficConfig)

local SignalCoordinator = {}

type SignalPlan = SignalSpec.SignalPlan
type SignalGroup = SignalSpec.SignalGroup

-- One entry per phase: where its green opens and closes inside the cycle. Times are
-- seconds from the junction's own cycle zero, before the offset is applied.
export type Slot = {
	phaseIndex: number,
	start: number,   -- green begins
	green: number,   -- seconds of green
	yellow: number,
	allRed: number,
}

export type SplitPlan = {
	cycle: number,
	slots: { Slot },
}

-- == Split allocation ========================================================

-- What share of the cycle each phase deserves. A through movement carries the bulk of
-- an intersection's traffic, a protected left serves one lane group, and the walk
-- phase is a fixed duration rather than a share at all -- so they are weighted, not
-- split evenly. Even splits are what makes a coordinated corridor feel worse than no
-- coordination: the arterial gets a quarter of the cycle and queues while the empty
-- side street holds green.
local PHASE_WEIGHT = {
	through = 3.0,
	left = 1.0,
	ped = 0, -- fixed length, allocated before anything is shared out
}

-- Carves `cycle` seconds between `phases`. Change intervals are taken off the top --
-- they are not negotiable, every phase must clear before the next one starts -- and
-- whatever remains is shared by weight, subject to each phase's own minimum green.
function SignalCoordinator.buildSplitPlan(phases: { any }, plan: SignalPlan, cycle: number): SplitPlan
	local slots: { Slot } = {}
	if #phases == 0 then
		return { cycle = cycle, slots = slots }
	end

	local yellow = if plan.custom then plan.yellow else TrafficConfig.YELLOW_TIME
	local allRed = if plan.custom then plan.allRed else TrafficConfig.ALL_RED_TIME
	local pedWalk = if plan.custom then plan.pedWalk else TrafficConfig.PED_WALK_TIME

	-- Pass 1: the fixed costs. A walk phase has no yellow (it clears straight to
	-- all-red), which is the same rule the free-running controller uses.
	local fixed = 0
	local shareable = 0
	local totalWeight = 0
	for _, phase in ipairs(phases) do
		if phase.kind == "ped" then
			fixed += pedWalk + allRed
		else
			fixed += yellow + allRed
			totalWeight += PHASE_WEIGHT[phase.kind] or 1
		end
	end

	shareable = math.max(cycle - fixed, 0)

	-- Pass 2: hand each phase its minimum first, then distribute what is left by
	-- weight. Minimums come first because a phase below its minimum green is not a
	-- short phase, it is an unsafe one -- a driver cannot start, cross and clear.
	local minTotal = 0
	for _, phase in ipairs(phases) do
		if phase.kind ~= "ped" then
			minTotal += SignalCoordinator.minGreenFor(phase, plan)
		end
	end

	local surplus = math.max(shareable - minTotal, 0)
	-- When the cycle cannot even cover the minimums, everything scales down together.
	-- Validation warns the player long before this, but the controller still has to
	-- produce a runnable cycle rather than negative greens.
	local squeeze = if minTotal > 0 and shareable < minTotal then shareable / minTotal else 1

	local cursor = 0
	for index, phase in ipairs(phases) do
		local green: number
		local phaseYellow = yellow
		if phase.kind == "ped" then
			green = pedWalk
			phaseYellow = 0
		else
			local weight = PHASE_WEIGHT[phase.kind] or 1
			local bonus = if totalWeight > 0 then surplus * (weight / totalWeight) else 0
			green = SignalCoordinator.minGreenFor(phase, plan) * squeeze + bonus
		end

		table.insert(slots, {
			phaseIndex = index,
			start = cursor,
			green = green,
			yellow = phaseYellow,
			allRed = allRed,
		})
		cursor += green + phaseYellow + allRed
	end

	-- Floating-point drift over a dozen phases would leave a sliver of dead time at
	-- the cycle boundary, and a sliver repeated every cycle is a signal that slowly
	-- loses its offset. Absorb it into the last phase so the slots sum to EXACTLY the
	-- cycle.
	local last = slots[#slots]
	if last and cursor > 0 then
		last.green += cycle - cursor
		if last.green < 0.1 then last.green = 0.1 end
	end

	return { cycle = cycle, slots = slots }
end

function SignalCoordinator.minGreenFor(phase: any, plan: SignalPlan): number
	if phase.kind == "left" then
		return if plan.custom then plan.leftMinGreen else TrafficConfig.LEFT_MIN_GREEN
	end
	return if plan.custom then plan.minGreen else TrafficConfig.MIN_GREEN
end

-- Which phase is lit at `localTime` seconds into the cycle, and in what state.
-- Wraps, so the caller can hand it a raw clock reading.
function SignalCoordinator.sampleAt(split: SplitPlan, localTime: number): (number, string, number)
	local cycle = split.cycle
	if cycle <= 0 or #split.slots == 0 then return 1, "green", 0 end

	local t = localTime % cycle
	for _, slot in split.slots do
		local greenEnd = slot.start + slot.green
		local yellowEnd = greenEnd + slot.yellow
		local slotEnd = yellowEnd + slot.allRed
		if t < greenEnd then
			return slot.phaseIndex, "green", greenEnd - t
		elseif t < yellowEnd then
			return slot.phaseIndex, "yellow", yellowEnd - t
		elseif t < slotEnd then
			return slot.phaseIndex, "allred", slotEnd - t
		end
	end

	-- Past the last slot only by rounding: hold the final phase's clearance.
	local last = split.slots[#split.slots]
	return last.phaseIndex, "allred", 0
end

-- Rotates a split plan so the COORDINATED phase opens at cycle zero. The offset is
-- defined against that phase (conventionally the main street's through movement), so
-- the wave is anchored to the movement it is meant to progress, not to whichever
-- phase happens to be first in the builder's output.
function SignalCoordinator.rotateToCoordPhase(split: SplitPlan, coordPhase: number): SplitPlan
	local slots = split.slots
	if #slots == 0 then return split end

	local anchorIndex: number? = nil
	for i, slot in slots do
		if slot.phaseIndex == coordPhase then
			anchorIndex = i
			break
		end
	end
	if not anchorIndex or anchorIndex == 1 then return split end

	local rotated: { Slot } = {}
	local cursor = 0
	for step = 0, #slots - 1 do
		local slot = slots[((anchorIndex - 1 + step) % #slots) + 1]
		table.insert(rotated, {
			phaseIndex = slot.phaseIndex,
			start = cursor,
			green = slot.green,
			yellow = slot.yellow,
			allRed = slot.allRed,
		})
		cursor += slot.green + slot.yellow + slot.allRed
	end

	return { cycle = split.cycle, slots = rotated }
end

-- How far a junction's cycle has slipped against the corridor's master clock, in
-- seconds. Positive = running late, negative = early.
--
-- Only meaningful at the instant the coordinated phase is due to start, which is the
-- one point in the cycle where the junction knows exactly where it is supposed to be.
-- Past the halfway mark a junction is better described as early for the NEXT cycle
-- than as very late for this one -- without that wrap, a junction a hair behind its
-- offset would try to claw back a nearly full cycle and stall on its minimum green.
function SignalCoordinator.offsetError(simClock: number, offset: number, cycle: number): number
	if cycle <= 0 then return 0 end
	local localT = (simClock - offset) % cycle
	if localT > cycle * 0.5 then
		return localT - cycle
	end
	return localT
end

-- == Offsets =================================================================

-- Orders a group's junctions into a CORRIDOR: a chain starting at the master and
-- walking to the nearest junction not yet visited. A corridor is a line of signals,
-- and the player adds them by clicking, in whatever order they feel like -- so the
-- travel order has to be recovered from the geometry rather than trusted from the
-- click order.
function SignalCoordinator.orderCorridor(group: SignalGroup, positionOf: (number) -> Vector3?): { number }
	local remaining: { number } = {}
	for _, nodeId in group.nodeIds do
		if positionOf(nodeId) then
			table.insert(remaining, nodeId)
		end
	end
	if #remaining <= 1 then return remaining end

	local startId = group.masterNodeId
	if not startId or not table.find(remaining, startId) then
		startId = remaining[1]
	end

	local ordered: { number } = {}
	local currentId = startId :: number
	table.remove(remaining, table.find(remaining, currentId) :: number)
	table.insert(ordered, currentId)

	while #remaining > 0 do
		local from = positionOf(currentId) :: Vector3
		local bestIdx = 1
		local bestSq = math.huge
		for i, nodeId in remaining do
			local pos = positionOf(nodeId) :: Vector3
			local dx, dz = pos.X - from.X, pos.Z - from.Z
			local d2 = dx * dx + dz * dz
			if d2 < bestSq then
				bestSq = d2
				bestIdx = i
			end
		end
		currentId = remaining[bestIdx]
		table.remove(remaining, bestIdx)
		table.insert(ordered, currentId)
	end

	return ordered
end

export type OffsetSolution = {
	offsets: { [number]: number },
	-- Straight-line spacing to the previous junction in the corridor, for the panel.
	spacing: { [number]: number },
	-- The spacing at which two-way progression would be free, at this cycle and speed.
	idealSpacing: number,
	totalLength: number,
}

-- Solves the green wave: each junction's green opens exactly when the platoon that
-- left the previous one arrives.
--
--   offset(i) = offset(i-1) + distance(i-1, i) / progression speed   (mod cycle)
--
-- This gives PERFECT one-way progression along the corridor. Two-way progression is
-- only free when the junctions sit half a cycle of travel apart -- see
-- SignalSpec.idealSpacingStuds -- and anywhere else the return direction pays for the
-- outbound one. The panel reports the ideal spacing next to the real one so that
-- trade-off reads as geometry rather than as the tool getting it wrong.
function SignalCoordinator.solveOffsets(group: SignalGroup, positionOf: (number) -> Vector3?): OffsetSolution
	local ordered = SignalCoordinator.orderCorridor(group, positionOf)
	local offsets: { [number]: number } = {}
	local spacing: { [number]: number } = {}
	local cycle = math.max(group.cycle, 1)

	local cumulative = 0
	for i, nodeId in ordered do
		if i == 1 then
			offsets[nodeId] = 0
			spacing[nodeId] = 0
		else
			local prev = positionOf(ordered[i - 1]) :: Vector3
			local here = positionOf(nodeId) :: Vector3
			local dx, dz = here.X - prev.X, here.Z - prev.Z
			local dist = math.sqrt(dx * dx + dz * dz)
			spacing[nodeId] = dist
			cumulative += dist
			-- Modulo the cycle: an offset is a position within the cycle, so a corridor
			-- longer than one cycle of travel simply wraps -- the platoon meets the NEXT
			-- cycle's green, which is what a real long corridor does.
			offsets[nodeId] = SignalSpec.travelOffset(cumulative, group.progressionKmh) % cycle
		end
	end

	return {
		offsets = offsets,
		spacing = spacing,
		idealSpacing = SignalSpec.idealSpacingStuds(group.progressionKmh, cycle),
		totalLength = cumulative,
	}
end

-- Writes solved offsets back into the plans. Only for groups on autoOffsets: once the
-- player has dialled an offset by hand it is theirs, and recomputing it underneath
-- them on the next road edit would be the tool overruling a deliberate choice.
function SignalCoordinator.applyAutoOffsets(group: SignalGroup, positionOf: (number) -> Vector3?): OffsetSolution
	local solution = SignalCoordinator.solveOffsets(group, positionOf)
	if not group.autoOffsets then return solution end

	for nodeId, offset in pairs(solution.offsets) do
		local plan = SignalPlanStore.rawPlan(nodeId)
		if plan then
			plan.offset = math.round(offset * 10) / 10
		end
	end
	return solution
end

-- The cycle a corridor should run, from the junction that needs the most. A
-- coordinated group can only be as fast as its slowest member: a cycle that fits the
-- easy junctions but not the critical one starves the critical one every single
-- cycle. This is the "critical intersection governs" rule, and it is why the panel's
-- auto-cycle button reads the whole corridor rather than the selected node.
function SignalCoordinator.criticalCycle(group: SignalGroup, contextOf: (number) -> SignalSpec.ValidateContext?): number
	local needed = SignalSpec.Bounds.cycle.min
	for _, nodeId in group.nodeIds do
		local ctx = contextOf(nodeId)
		if ctx then
			local plan = SignalPlanStore.planFor(nodeId)
			needed = math.max(needed, SignalSpec.minimumCycle(plan, ctx))
		end
	end
	-- Headroom over the bare minimum, then rounded to 5 s the way cycles are quoted.
	-- A cycle sitting exactly on its floor leaves every phase at its minimum green and
	-- no room at all for the weighted split to do anything.
	local withHeadroom = needed * 1.25
	return math.clamp(
		math.round(withHeadroom / 5) * 5,
		SignalSpec.Bounds.cycle.min,
		SignalSpec.Bounds.cycle.max
	)
end

-- Advice for the panel: is this corridor worth coordinating at all? Past roughly half
-- a mile a platoon has spread into ordinary random arrivals and there is no platoon
-- left to progress -- coordinating anyway buys nothing and still taxes the side
-- streets with a fixed cycle they did not need.
function SignalCoordinator.spacingAdvice(solution: OffsetSolution): (string?, boolean)
	local worst = 0
	for _, dist in pairs(solution.spacing) do
		worst = math.max(worst, dist)
	end
	if worst > SignalSpec.COORDINATION_MAX_SPACING_STUDS then
		return "Some junctions here are over 800 m apart. Platoons disperse before they arrive, so coordination buys little and still holds the side streets to a fixed cycle.", true
	end
	return nil, false
end

return SignalCoordinator
