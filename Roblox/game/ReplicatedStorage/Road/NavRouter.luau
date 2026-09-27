--!strict
-- NavRouter
-- Route search over a built RoadNavigationGraph: nearest-edge biasing toward a goal,
-- congestion-weighted A* path search, and route-cost estimation. Operates ON a graph
-- passed in as the first arg -- it never requires RoadNavigationGraph, so the dependency
-- direction is RoadNavigationGraph -> NavRouter. The graph keeps thin FindPath/
-- EstimatePathCost/NearestEdgeToward methods that delegate here, so every caller
-- (g:FindPath(...)) is unchanged. Reads the graph's edges / spatial index / congestion;
-- the graph still owns building waypoint geometry (_buildWaypoints/_buildCyclicWaypoints)
-- and NearestEdge. flatUnit/distanceAtIndex are tiny pure geometry utils kept as local
-- copies (also live in the graph for its own geometry) rather than coupling through a
-- shared module for ~15 lines.

local RoadConstants = require(script.Parent.RoadConstants)
local DriverProfile = require(script.Parent.DriverProfile)
local NavCost = require(script.Parent.NavCost)

local NavRouter = {}

export type Profile = DriverProfile.Profile

local DEFAULT_CELL_SIZE = 128
-- studs of extra distance worth 1.0 of heading alignment (start-lane pick toward goal)
local LANE_PICK_DIST_SCALE = 30

type HeapItem = { id: string, priority: number }

-- Moving over one lane mid-block: signal, mirror, drift across. Charged on top of the new
-- lane's own price: an empty lane beside a queue is genuinely quicker, which is how traffic
-- spreads over a wide road, but nobody hops lanes for less than the move itself costs.
local LANE_CHANGE_SECONDS = 3
-- Turning across the oncoming lanes into a building on the far side of the street, or out of
-- one: a left turn plus the gap you wait for. US law allows it across dashed and double
-- yellow centre lines alike (CVC 21460(b)); never across a median.
local CROSS_CENTRE_SECONDS = 10
-- Free-flow times a lane's congestion above its road's mean adds: a lane fully queued (1.0)
-- beside empty ones crawls at about a third of the limit (NAV_CONGESTION_JAM_SPEED_RATIO).
local LANE_QUEUE_WEIGHT = 2

local function flatUnit(v: Vector3): Vector3?
	local flat = Vector3.new(v.X, 0, v.Z)
	if flat.Magnitude < 1e-6 then
		return nil
	end
	return flat.Unit
end

local function distanceAtIndex(points: { Vector3 }, index: number): number
	if #points == 0 then
		return 0
	end
	local clamped = math.clamp(index, 1, #points)
	local dist = 0
	for i = 2, clamped do
		dist += (points[i] - points[i - 1]).Magnitude
	end
	return dist
end

local function flatDistSq(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return dx * dx + dz * dz
end

local function laneTravelDir(edge: any, index: number): Vector3?
	local pts = edge.points
	local i = math.clamp(index, 1, math.max(1, #pts - 1))
	return flatUnit(pts[math.min(i + 1, #pts)] - pts[i])
end

local function pushHeap(heap: { HeapItem }, item: HeapItem)
	table.insert(heap, item)
	local i = #heap
	while i > 1 do
		local parent = math.floor(i / 2)
		if heap[parent].priority <= item.priority then
			break
		end
		heap[i] = heap[parent]
		i = parent
	end
	heap[i] = item
end

local function popHeap(heap: { HeapItem }): HeapItem?
	local root = heap[1]
	if not root then
		return nil
	end
	local last = table.remove(heap)
	if #heap > 0 and last then
		local i = 1
		while true do
			local left = i * 2
			local right = left + 1
			if left > #heap then
				break
			end
			local child = left
			if right <= #heap and heap[right].priority < heap[left].priority then
				child = right
			end
			if heap[child].priority >= last.priority then
				break
			end
			heap[i] = heap[child]
			i = child
		end
		heap[i] = last
	end
	return root
end

-- The bias is a driver's opinion of a STREET, so every lane of one carriageway shares it.
-- Keyed per lane, a driver could like the next lane over by more than LANE_CHANGE_SECONDS
-- on a long highway piece and change lanes for nothing. Cached per edge table: the key is
-- asked for on every edge the search prices.
local _roadKeyOf: { [any]: string } = setmetatable({}, { __mode = "k" }) :: any
local function roadKey(edge: any): string
	local key = _roadKeyOf[edge]
	if not key then
		key = `{edge.segmentId}{if edge.forward then "+" else "-"}`
		_roadKeyOf[edge] = key
	end
	return key
end

-- What one edge costs THIS driver, in SECONDS. Built the way a real routing engine
-- builds it (see NavCost for the sources), then coloured by who is driving:
--
--   free-flow time -- length / speed limit. A wide fast road is CHEAPER than a
--                     short slow one, which is the whole "big road vs small road"
--                     question, and is why this is time and not distance.
--   BPR            -- the standard volume-delay curve. Nearly free until the road
--                     approaches capacity, then very steep -- so traffic tips onto
--                     alternatives sharply rather than drifting.
--   demand         -- what is measurably crawling now (congestion) PLUS what other
--                     drivers have already committed to (bookings). The second term
--                     is the nav-app effect: the road is priced as busy before the
--                     queue physically exists.
--   class          -- Valhalla-style preference for/against motorways, and a flat
--                     service penalty for cutting through alleys.
--   bias           -- this driver's own stable misreading of this particular street.
--
-- Persona scales the parts that are matters of taste (jam aversion, foresight,
-- motorway appetite, bias) and leaves the physics (free-flow time, BPR shape) alone.
-- Passing no profile gives the objective fastest route.
local function edgeRouteCost(graph: any, edge: any, distance: number?, profile: Profile?): number
	local length = distance or edge.length
	local seconds = NavCost.freeFlowSeconds(edge, distance)
	local jamAversion = if profile then profile.jamAversion else 1

	-- Observed congestion, scaled by how much this driver cares about traffic. The ROAD's
	-- (the mean over its lanes) goes through BPR with the bookings; this lane's own queue is
	-- priced separately below. Through BPR per lane, bookings put the road on the steep part
	-- of the curve and a 0.02 difference between two lanes came out at several seconds --
	-- more than a lane change -- so through cars weaved from lane to lane the length of every
	-- long road, each move a car stopped waiting for a gap.
	local laneCongestion = graph:GetEdgeCongestion(edge.id)
	local roadCongestion = if graph.GetRoadCongestion then graph:GetRoadCongestion(edge.id) else laneCongestion
	local laneExcess = laneCongestion - roadCongestion
	local demand = roadCongestion * jamAversion

	-- Intent already committed by OTHER drivers, scaled by how far ahead this one reads.
	local booked = graph:GetEdgeBookingPressure(edge.id, if profile then profile.token else nil)
	if booked > 0 then
		demand += booked * (RoadConstants.NAV_BOOKING_WEIGHT or 1.6)
			* (if profile then profile.foresight else 1)
	end

	local slowdown = 1
	if demand > 0 then
		slowdown = NavCost.bprFactor(demand)
		seconds *= slowdown
	end
	-- A queue in THIS lane (a turn lane backed up past the others): the time it adds over
	-- the lanes beside it, roughly its share of the road crawling at jam speed. Negative for
	-- the emptier lane, never below free flow.
	if laneExcess ~= 0 then
		seconds = math.max(NavCost.freeFlowSeconds(edge, distance),
			seconds + laneExcess * LANE_QUEUE_WEIGHT * jamAversion * NavCost.freeFlowSeconds(edge, distance))
	end

	-- FUEL. Priced at the speed actually ACHIEVED (posted limit divided by the BPR
	-- slowdown), not the sign on the pole -- so a jammed motorway is costed at its
	-- stop-go consumption, and sitting in traffic hurts the wallet as well as the
	-- clock. Converted to seconds through the value of time so one search weighs both.
	-- This is what keeps a motorway honest: it is quicker, but it drinks more per km,
	-- so a driver only detours onto it when the time saved is worth the fuel.
	if length > 0 then
		local effectiveSpeed = (edge.speedLimit or 56) / slowdown
		local fuel = NavCost.fuelSeconds(length, effectiveSpeed)
		seconds += fuel * (if profile then profile.fuelSensitivity else 1)
	end

	-- Wait at the signal this lane feeds into. A short green on a long cycle is
	-- genuinely expensive; an uncontrolled junction publishes nothing and costs nothing
	-- here (its cost is the turn penalty). Charged in full only on the last slice of a
	-- partially-travelled edge, since you pay a junction once, not per stud.
	if not distance then
		seconds += graph:GetEdgeControlDelay(edge.id)
	end

	seconds *= NavCost.classFactor(edge.roadClass, if profile then profile.useHighways else nil)
	seconds += NavCost.classPenaltySeconds(edge.roadClass)

	return seconds * DriverProfile.edgeBias(profile, roadKey(edge))
end

-- Turn costs are already seconds (OSRM sigmoid + Valhalla manoeuvre penalty, baked
-- at graph build). Persona only decides how much this driver MINDS turning.
local function turnRouteCost(edge: any, nextId: string, profile: Profile?): number
	local cost = edge.turnCost[nextId] or 0
	if cost == 0 or not profile then
		return cost
	end
	return cost * profile.turnAversion
end

-- Cost of an existing route under the current congestion snapshot. The optional
-- index lets a directed driver compare only the untravelled tail of its route.
-- Pass the driver's own profile so it compares candidate routes with the same mind
-- it planned them with -- scoring the old route objectively and the new one
-- subjectively would make every driver think a reroute was an improvement.
function NavRouter.estimatePathCost(graph: any, edgeIds: { string }, startIndex: number?, profile: Profile?): number
	local first = math.clamp(startIndex or 1, 1, math.max(1, #edgeIds))
	local total = 0
	local prev: any = nil
	for i = first, #edgeIds do
		local edge = graph._edges[edgeIds[i]]
		if not edge then
			return math.huge
		end
		local cost = edgeRouteCost(graph, edge, nil, profile)
		if prev and prev.segmentId == edge.segmentId and prev.forward == edge.forward then
			-- A mid-block lane change pays for the road once, at the new lane's price, as
			-- findPath does.
			total += LANE_CHANGE_SECONDS + cost - edgeRouteCost(graph, prev, nil, profile)
		else
			total += cost
			if prev then
				total += turnRouteCost(prev, edge.id, profile)
			end
		end
		prev = edge
	end
	return total
end

-- Lane picking for a trip START out of a building / driveway: head out on the lane that
-- points toward the destination (crossing the dotted centre of a two-way road when that's
-- the way) instead of being locked to the geometrically nearest lane. Same-segment lanes
-- only, so it never hops roads; one-way roads are unaffected.
function NavRouter.nearestEdgeToward(graph: any, pos: Vector3, goalPos: Vector3, allows: ((any) -> boolean)?): any
	local nearest = graph:NearestEdge(pos, allows)
	if not nearest then return nil end
	local toGoal = flatUnit(goalPos - pos)
	if not toGoal then return nearest end
	local toGoalU = toGoal :: Vector3

	local function score(edge: any, index: number, distSq: number): number
		local td = laneTravelDir(edge, index)
		local align = if td then td:Dot(toGoalU) else -1
		return align - math.sqrt(distSq) / LANE_PICK_DIST_SCALE
	end

	local bestEdge, bestIndex = nearest.edge, nearest.index
	local bestScore = score(nearest.edge, nearest.index, flatDistSq(nearest.edge.points[nearest.index], pos))

	local cell = RoadConstants.NAV_SPATIAL_CELL_SIZE or DEFAULT_CELL_SIZE
	local cx, cz = math.floor(pos.X / cell), math.floor(pos.Z / cell)
	local seen: { [string]: boolean } = { [nearest.edge.id] = true }
	for x = cx - 1, cx + 1 do
		for z = cz - 1, cz + 1 do
			local bucket = graph._spatial[`{x},{z}`]
			if bucket then
				for _, item in bucket do
					local edge = graph._edges[item.edgeId]
					if edge and not seen[edge.id] and edge.segmentId == nearest.edge.segmentId
						and (not allows or allows(edge)) then
						seen[edge.id] = true
						local bi, bd = 1, math.huge
						for index, point in edge.points do
							local d = flatDistSq(point, pos)
							if d < bd then bd = d; bi = index end
						end
						local s = score(edge, bi, bd)
						if s > bestScore then
							bestScore, bestEdge, bestIndex = s, edge, bi
						end
					end
				end
			end
		end
	end
	return { edge = bestEdge, index = bestIndex, distance = math.sqrt(flatDistSq(bestEdge.points[bestIndex], pos)) }
end

type Endpoint = { edge: any, index: number, dist: number, extra: number }

local function nearestIndex(edge: any, pos: Vector3): number
	local bi, bd = 1, math.huge
	for index, point in edge.points do
		local d = flatDistSq(point, pos)
		if d < bd then
			bd = d
			bi = index
		end
	end
	return bi
end

-- Where a trip may join or leave the road beside `nearest`: that lane, plus -- when the
-- caller allows crossing and there is no median -- the far side's centre lane, which is the
-- lane a left turn into (or out of) a driveway is made from.
local function endpointsNear(graph: any, nearest: any, pos: Vector3, allowCrossing: boolean, allows: (any) -> boolean): { Endpoint }
	local list: { Endpoint } = {
		{ edge = nearest.edge, index = nearest.index, dist = distanceAtIndex(nearest.edge.points, nearest.index), extra = 0 },
	}
	if not allowCrossing or nearest.edge.divided then
		return list
	end
	for _, id in graph._edgesBySegment[nearest.edge.segmentId] or {} do
		local edge = graph._edges[id]
		if edge and edge.forward ~= nearest.edge.forward and edge.laneOrdinal == 1 and allows(edge) then
			local index = nearestIndex(edge, pos)
			table.insert(list, { edge = edge, index = index, dist = distanceAtIndex(edge.points, index), extra = CROSS_CENTRE_SECONDS })
		end
	end
	return list
end

-- A trip that ends where a road runs off the map is LEAVING the city, and may leave by any
-- lane of that carriageway. Tied to the one lane nearest the connection's centre point, every
-- car in the other lanes had to merge into it just before the edge, so a wide exit carried
-- all its traffic down one lane. Only when the goal sits on the last stretch of the lane: a
-- building on a road that happens to lead off the map still gets its kerbside lane.
local MAP_EXIT_GOAL_RANGE = 80

local function addMapExitLanes(graph: any, goals: { [string]: Endpoint }, nearest: any, pos: Vector3, allows: (any) -> boolean)
	local edge = nearest.edge
	if not graph.LeavesMap or not graph:LeavesMap(edge) then
		return
	end
	if edge.length - distanceAtIndex(edge.points, nearest.index) > MAP_EXIT_GOAL_RANGE then
		return
	end
	for _, id in graph._edgesBySegment[edge.segmentId] or {} do
		local lane = graph._edges[id]
		if lane and not goals[id] and lane.forward == edge.forward and allows(lane) then
			local index = nearestIndex(lane, pos)
			goals[id] = { edge = lane, index = index, dist = distanceAtIndex(lane.points, index), extra = 0 }
		end
	end
end

-- Cost from `fromDist` along an edge to its far end, including the junction wait there.
local function tailCost(graph: any, edge: any, fromDist: number, profile: Profile?): number
	if fromDist <= 0 then
		return edgeRouteCost(graph, edge, nil, profile)
	end
	return edgeRouteCost(graph, edge, math.max(0, edge.length - fromDist), profile) + graph:GetEdgeControlDelay(edge.id)
end

-- Route search. Nodes are lane edges; gScore[e] is the cost to reach the END of e, and
-- joinDist[e] is how far along e the route joined it (0 via a junction). The trip may START
-- on any lane `endpointsNear` offers and END on any of the goal's, and in between it may
-- cross junctions (edge.out) or move over a lane mid-block (dashed lines,
-- GetLaneChangeTargets). Before this the route was locked to the one nearest lane at both
-- ends and lanes only changed AT junctions, one per junction -- so a car that needed the far
-- lane, or a building across the street, drove round the block to get there.
--
-- `allowCrossing` (the old preferTowardGoal slot) lets the trip start or end across the
-- centre line. `vehicleClass` (default Car) gates which lanes the search may use; `profile`
-- (DriverProfile) is the driver's own mind -- buses/trains/emergency pass none.
function NavRouter.findPath(graph: any, startPos: Vector3, goalPos: Vector3, allowCrossing: boolean?, vehicleClass: string?, profile: Profile?): ({ Vector3 }?, { string }?)
	local class = vehicleClass or "Car"
	local function allows(edge: any): boolean
		local set = edge.allowedVehicles
		return set == nil or set[class] == true
	end
	local startNearest = graph:NearestEdge(startPos, allows)
	local goalNearest = graph:NearestEdge(goalPos, allows)
	if not startNearest or not goalNearest then
		return nil, nil
	end
	local starts = endpointsNear(graph, startNearest, startPos, allowCrossing == true, allows)
	local goals: { [string]: Endpoint } = {}
	for _, goal in endpointsNear(graph, goalNearest, goalPos, allowCrossing == true, allows) do
		goals[goal.edge.id] = goal
	end
	addMapExitLanes(graph, goals, goalNearest, goalPos, allows)
	local goalAnchor = goalNearest.edge.points[goalNearest.index]
	local laneChangeLength = graph.LANE_CHANGE_MIN_LENGTH or 14
	-- Heap priority: a lower bound on any finish through `edge`. That is the cost at the point
	-- the route JOINED it (a lane change can leave long before the end) plus the straight-line
	-- time from there, which the triangle inequality bounds by the end point's.
	local function priority(edge: any, costToEnd: number, join: number): number
		local ahead = NavCost.heuristicSeconds((edge.points[#edge.points] - goalAnchor).Magnitude)
			- NavCost.heuristicSeconds(math.max(0, edge.length - join))
		return costToEnd - tailCost(graph, edge, join, profile) + math.max(0, ahead)
	end

	local open: { HeapItem } = {}
	local cameFrom: { [string]: string } = {}
	local gScore: { [string]: number } = {}
	local joinDist: { [string]: number } = {}
	local closed: { [string]: boolean } = {}
	local startOf: { [string]: Endpoint } = {}
	-- Best finish found so far: its cost, the goal lane, and the step before it.
	local bestGoal = math.huge
	local goalEdge: string? = nil
	local goalPrev: string? = nil

	-- `costToEnd` reached the end of `edgeId` having joined it at `join`; finishing swaps
	-- that tail for the slice from `join` to the goal point.
	local function offerGoal(edgeId: string, prevId: string?, costToEnd: number, join: number)
		local goal = goals[edgeId]
		if not goal or goal.dist < join then
			return
		end
		local finish = costToEnd - tailCost(graph, goal.edge, join, profile) + goal.extra
			+ edgeRouteCost(graph, goal.edge, goal.dist - join, profile)
		if finish < bestGoal then
			bestGoal = finish
			goalEdge = edgeId
			goalPrev = prevId
		end
	end

	-- A start lane keeps its own score and has no predecessor, so reaching it again only
	-- matters as a finish -- the loop back to a goal behind the start.
	local function push(fromId: string, nextEdge: any, tentative: number, join: number)
		local nextId = nextEdge.id
		if startOf[nextId] or tentative >= (gScore[nextId] or math.huge) then
			return
		end
		cameFrom[nextId] = fromId
		gScore[nextId] = tentative
		joinDist[nextId] = join
		pushHeap(open, { id = nextId, priority = priority(nextEdge, tentative, join) })
	end

	for _, start in starts do
		local edge = start.edge
		local id = edge.id
		local cost = start.extra + tailCost(graph, edge, start.dist, profile)
		startOf[id] = start
		gScore[id] = cost
		joinDist[id] = start.dist
		pushHeap(open, { id = id, priority = priority(edge, cost, start.dist) })
		offerGoal(id, nil, cost, start.dist)
	end

	while #open > 0 do
		local item = popHeap(open)
		if not item then
			break
		end
		-- Every open item costs at least its priority, so nothing left can finish cheaper.
		if item.priority >= bestGoal then
			break
		end
		local currentId = item.id
		if closed[currentId] then
			continue
		end
		closed[currentId] = true
		local edge = graph._edges[currentId]
		if not edge then
			continue
		end
		local currentScore = gScore[currentId] or math.huge
		for _, nextId in edge.out do
			local nextEdge = graph._edges[nextId]
			if nextEdge and allows(nextEdge) then
				local tentative = currentScore + tailCost(graph, nextEdge, 0, profile) + turnRouteCost(edge, nextId, profile)
				offerGoal(nextId, currentId, tentative, 0)
				push(currentId, nextEdge, tentative, 0)
			end
		end
		-- Mid-block lane change: the road up to the move at this lane's price, the rest at the
		-- new lane's, and the move starts no earlier than the dashed line allows.
		local join = joinDist[currentId] or 0
		for _, nextId in graph:GetLaneChangeTargets(currentId) do
			local nextEdge = graph._edges[nextId]
			local earliest, latest = graph:GetLaneChangeWindow(currentId, nextId)
			if nextEdge and earliest and latest and allows(nextEdge) and join <= latest then
				local at = math.max(join, earliest)
				local tentative = currentScore - tailCost(graph, edge, at, profile)
					+ LANE_CHANGE_SECONDS + tailCost(graph, nextEdge, at, profile)
				local landed = at + laneChangeLength
				offerGoal(nextId, currentId, tentative, landed)
				push(currentId, nextEdge, tentative, landed)
			end
		end
	end

	if not goalEdge then
		return nil, nil
	end
	local reversePath: { string } = { goalEdge :: string }
	local cursor = goalPrev
	for _ = 1, #graph._edgeList + 1 do
		if not cursor then
			break
		end
		table.insert(reversePath, cursor)
		if startOf[cursor] then
			break
		end
		cursor = cameFrom[cursor]
	end
	local n = #reversePath
	local path: { string } = table.create(n)
	for i = 1, n do
		path[i] = reversePath[n - i + 1]
	end
	local first = startOf[path[1]]
	if not first then
		return nil, nil
	end
	local goalIndex = goals[path[n]].index
	local waypoints = if n > 1 and path[1] == path[n]
		then graph:_buildCyclicWaypoints(path, first.index, goalIndex)
		else graph:_buildWaypoints(path, first.index, goalIndex)
	return waypoints, path
end

return NavRouter
