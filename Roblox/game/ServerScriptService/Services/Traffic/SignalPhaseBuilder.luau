--!strict
-- SignalPhaseBuilder
-- Turns an IntersectionPlan into an ordered, conflict-free phase sequence.
-- Pure library: no state, no lifecycle.
--
-- Phase layout per intersection (lane-aware):
--   * Opposing arms pair into one road group (a free-form "North/South" or
--     "East/West" axis); crossing groups never share a green.
--   * Protected lefts exist only where the lanes do: a group gets a leading
--     left phase only when an approach has a DEDICATED left-turn lane (every
--     connection from that lane is a left/U-turn, as configured in the lane
--     editor). During that phase only those lanes are green -- both opposing
--     left lanes together, like a real dual-left. Dedicated left lanes are
--     protected-only: they sit at red through the group's through phase.
--   * Shared/single lanes (left+straight+right from one lane) never get a
--     turn phase; their lefts run permissively on the through green and
--     NPCDriverService yields them to oncoming traffic with gap acceptance.
--   * A lone arm (the stem of a T) gets its own phase; its lefts are
--     unopposed, hence protected by construction.
--   * An optional pedestrian scramble phase sits at the end of the cycle:
--     every arm red, walk signal on.
--
-- PLAYER OVERRIDES. Everything above is the AUTOMATIC layout, and it is still what
-- runs at every junction the player has not touched. A SignalPlan (SignalSpec) may
-- override the left-turn treatment ARM BY ARM, move the lefts from leading to
-- lagging, and change how pedestrians are served:
--
--   permissive -- no protected phase at all. Any dedicated left lane is folded into
--                 the through phase and filters on gaps, exactly like a shared lane.
--   protected  -- as automatic: its own phase, red through its group's through phase.
--   ppLeft     -- protected phase AND green again through the through phase, on the
--                 flashing yellow arrow the side head displays. The best of both:
--                 the queue clears on the protected phase, stragglers still filter.
--   split      -- the arm takes the whole intersection to itself for one phase. What
--                 real controllers use where opposing approaches are offset or share
--                 a left-through lane and cannot safely run together.
--
-- LEADING VS LAGGING. Lagging lefts are what let a corridor progress -- the platoon
-- runs through on the through green and the lefts mop up behind it. They are also
-- how the yellow trap is created, which is why SignalSpec.validate refuses lagging
-- lefts on any arm set to plain permissive: without a separate left head there is no
-- way to end the permissive window with the OPPOSING green instead of the driver's
-- own. On ppLeft the side head is that separate head, so lagging is safe.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local IntersectionDetector = require(script.Parent.IntersectionDetector)
local TrafficConfig        = require(script.Parent.TrafficConfig)
local SignalSpec           = require(ReplicatedStorage.Road.SignalSpec)

local SignalPhaseBuilder = {}

export type Phase = {
	kind: "left" | "through" | "ped",
	label: string,
	greenEdges: { [string]: boolean },
	allowedConnections: { [string]: { [string]: boolean } }, -- "*" = any exit
	greenArms: { [number]: boolean }, -- arm indices whose MAIN head shows green
	leftArms: { [number]: boolean },  -- arm indices whose left-turn head shows green
}

export type PhasePlan = {
	phases: { Phase },
	hasPed: boolean,
	-- Pedestrians cross on the parallel through green rather than in an exclusive
	-- phase of their own. There is no ped PHASE in this case -- the walk signal simply
	-- follows the through greens -- so TrafficSignalService answers IsPedWalk from the
	-- live phase instead of from a phase kind.
	pedConcurrent: boolean,
}

type Arm = IntersectionDetector.Arm

local OPPOSING_ARM_DOT = -0.65 -- arms at least this anti-parallel pair into one road

local function newPhase(kind: "left" | "through" | "ped", label: string): Phase
	return {
		kind = kind,
		label = label,
		greenEdges = {},
		allowedConnections = {},
		greenArms = {},
		leftArms = {},
	}
end

-- Greens the given lane edges and allows every exit each lane is permitted.
local function addEdges(phase: Phase, edgeIds: { string }, graph: any)
	for _, edgeId in ipairs(edgeIds) do
		local edge = graph:GetEdge(edgeId)
		if not edge then continue end
		phase.greenEdges[edgeId] = true
		local allowed = phase.allowedConnections[edgeId]
		if not allowed then
			allowed = {}
			phase.allowedConnections[edgeId] = allowed
		end
		for _, outId in ipairs(edge.out) do
			allowed[outId] = true
		end
		if #edge.out == 0 then
			allowed["*"] = true -- dead-end approach: any/no exit is fine
		end
	end
end

-- Pairs opposing arms into road groups; leftovers stand alone.
local function groupArms(arms: { Arm }): { { number } }
	local used: { boolean } = table.create(#arms, false)
	local groups: { { number } } = {}
	for i = 1, #arms do
		if used[i] then continue end
		local bestJ: number? = nil
		local bestDot = OPPOSING_ARM_DOT
		for j = 1, #arms do
			if i == j or used[j] then continue end
			local dot = arms[i].dir:Dot(arms[j].dir)
			if dot < bestDot then
				bestDot = dot
				bestJ = j
			end
		end
		used[i] = true
		if bestJ then
			used[bestJ] = true
			table.insert(groups, { i, bestJ })
		else
			table.insert(groups, { i })
		end
	end
	-- North/South axis first, then East/West, for a deterministic cycle order.
	table.sort(groups, function(a, b)
		local axisA = arms[a[1]].axis
		local axisB = arms[b[1]].axis
		if axisA ~= axisB then return axisA == "NS" end
		return arms[a[1]].segmentId < arms[b[1]].segmentId
	end)
	return groups
end

-- The treatment an arm's crossing turn actually gets, once the player's choice has
-- been reconciled with what the lanes can physically support. "auto" resolves here
-- and nowhere else, so the rest of the builder only ever sees a concrete answer.
local function resolveLeftMode(arm: Arm, signalPlan: SignalSpec.SignalPlan?): string
	local requested = if signalPlan and signalPlan.custom
		then SignalSpec.armPlan(signalPlan, arm.index).leftMode
		else "auto"

	local hasDedicated = #arm.dedicatedLeftEdges > 0

	-- A protected phase greens one lane group while everything else is held. With no
	-- dedicated lane there is no lane group to hold -- the through cars queued behind
	-- the turner would be released into a red. SignalSpec.validate raises this as an
	-- error in the panel; here we simply fall back to something that runs, because the
	-- controller must never be left with a phase it cannot serve.
	if (requested == "protected" or requested == "ppLeft") and not hasDedicated then
		return "permissive"
	end

	if requested ~= "auto" then
		return requested
	end

	-- Automatic: dedicated lane gets a protected phase, everything else filters.
	return if hasDedicated then "protected" else "permissive"
end

function SignalPhaseBuilder.build(geometry: IntersectionDetector.IntersectionPlan, graph: any, signalPlan: SignalSpec.SignalPlan?): PhasePlan
	local arms = geometry.arms
	local phases: { Phase } = {}
	local custom = signalPlan ~= nil and signalPlan.custom
	local leading = if custom then (signalPlan :: SignalSpec.SignalPlan).leadingLefts else true

	-- Arm index is how a player's per-arm choice finds its arm again, and the builder
	-- is handed arms in a table whose order it does not own. Stamping the index on
	-- makes every helper below index-aware without threading it through by hand.
	for i, arm in ipairs(arms) do
		(arm :: any).index = i
	end

	local mode: { [number]: string } = {}
	for i, arm in ipairs(arms) do
		mode[i] = resolveLeftMode(arm, signalPlan)
	end

	-- Split-phased arms are pulled out BEFORE the opposing pairs are formed: the whole
	-- point of split phasing is that this approach does not share a green with its
	-- opposite number, so leaving it in the pairing would defeat it.
	local splitArms: { number } = {}
	local pairable: { Arm } = {}
	for i, arm in ipairs(arms) do
		if mode[i] == "split" then
			table.insert(splitArms, i)
		else
			table.insert(pairable, arm)
		end
	end

	for _, group in ipairs(groupArms(pairable)) do
		-- groupArms indexes into `pairable`; map back to real arm indices.
		local armIndices: { number } = {}
		for _, localIndex in ipairs(group) do
			table.insert(armIndices, (pairable[localIndex] :: any).index)
		end
		local axis = arms[armIndices[1]].axis

		local leftPhase = newPhase("left", axis .. "-Left")
		local through = newPhase("through", axis)

		for _, armIndex in ipairs(armIndices) do
			local arm = arms[armIndex]
			local armMode = mode[armIndex]

			addEdges(through, arm.throughEdges, graph)
			if #arm.throughEdges > 0 then
				through.greenArms[armIndex] = true
			end

			if armMode == "permissive" then
				-- No protected phase. A dedicated left lane still has to be served, so
				-- it joins the through green and filters on gaps like a shared lane --
				-- otherwise choosing "permissive" on an arm that HAS a left lane would
				-- strand that lane at red for the whole cycle.
				addEdges(through, arm.dedicatedLeftEdges, graph)
				if #arm.dedicatedLeftEdges > 0 then
					through.greenArms[armIndex] = true
					through.leftArms[armIndex] = true
				end
			else
				addEdges(leftPhase, arm.dedicatedLeftEdges, graph)
				if #arm.dedicatedLeftEdges > 0 then
					leftPhase.leftArms[armIndex] = true
					if #arm.throughEdges == 0 then
						-- Every lane on this arm is a left: its main head follows the
						-- left phase, since that is the only movement it ever serves.
						leftPhase.greenArms[armIndex] = true
					end
				end

				if armMode == "ppLeft" then
					-- Protected-permissive: the same lanes are green AGAIN during the
					-- through phase, shown on the side head as a flashing yellow arrow.
					-- leftArms drives that head, so setting it on the through phase is
					-- what makes the permissive window visible to the player.
					addEdges(through, arm.dedicatedLeftEdges, graph)
					if #arm.dedicatedLeftEdges > 0 then
						through.leftArms[armIndex] = true
					end
				end
			end
		end

		local hasLeft = next(leftPhase.greenEdges) ~= nil
		local hasThrough = next(through.greenEdges) ~= nil

		-- Lead or lag is purely the order these two go into the ring.
		if leading and hasLeft then table.insert(phases, leftPhase) end
		if hasThrough then table.insert(phases, through) end
		if not leading and hasLeft then table.insert(phases, leftPhase) end
	end

	-- Split arms last, one exclusive phase each: every movement this approach is
	-- allowed to make runs at once, and nothing else in the junction moves.
	for _, armIndex in ipairs(splitArms) do
		local arm = arms[armIndex]
		local phase = newPhase("through", string.format("Split %d", armIndex))
		addEdges(phase, arm.throughEdges, graph)
		addEdges(phase, arm.dedicatedLeftEdges, graph)
		if next(phase.greenEdges) ~= nil then
			phase.greenArms[armIndex] = true
			if #arm.dedicatedLeftEdges > 0 then
				phase.leftArms[armIndex] = true
			end
			table.insert(phases, phase)
		end
	end

	-- Pedestrians. "concurrent" is the US default and costs the cycle nothing: people
	-- cross beside the parallel through movement. "scramble" buys them an exclusive
	-- all-red phase -- safer where turning volumes are heavy, but every vehicle in the
	-- junction pays for it every time it runs.
	local pedMode = if custom then (signalPlan :: SignalSpec.SignalPlan).pedMode else nil
	local hasPed = false
	local pedConcurrent = false

	if #phases > 0 then
		if pedMode == nil then
			-- Uncustomised junctions keep the pre-existing global behaviour exactly.
			if TrafficConfig.PED_ENABLED then
				hasPed = true
				table.insert(phases, newPhase("ped", "Ped"))
			end
		elseif pedMode == "scramble" then
			hasPed = true
			table.insert(phases, newPhase("ped", "Ped"))
		elseif pedMode == "concurrent" then
			pedConcurrent = true
		end
	end

	return { phases = phases, hasPed = hasPed, pedConcurrent = pedConcurrent }
end

return SignalPhaseBuilder
