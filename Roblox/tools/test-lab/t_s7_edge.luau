-- Scenario 7: through traffic at the map edge. An avenue (two lanes each way, dashed lane
-- lines) runs the whole map, south edge to north edge, with the game's real
-- OutsideConnectionService + ThroughTrafficService feeding it. Measures how the two
-- outbound lanes are used over the last stretch before the exit: lane changes made there,
-- cars standing waiting for a gap to merge, and how many leave per lane.
-- usage: lune run t_s7_edge.luau <mode> <seconds> <seed> [camera near|far]
local World = require("./shim/traffic")
local process = require("@lune/process")
local mode = process.args[1] or "cur"
local T = tonumber(process.args[2]) or 300
local seed = tonumber(process.args[3]) or 1
local camFar = process.args[4] == "far"

local w = World.new(mode)
local V = w.V
local Studio = w.Studio
local HALF = w.RoadConstants.MAP_HALF_EXTENT
local PIECE = 512
local z = -HALF
while z < HALF do
	local z1 = math.min(HALF, z + PIECE)
	w:road(V.new(0, 0, z), V.new(0, 0, z1), "CollectorRoad")
	z = z1
end
w:build()
-- The camera sits over the north exit (or far off the road, to put every car on the far tier).
w:camera(if camFar then V.new(3000, 0, 3000) else V.new(0, 0, HALF - 300))
math.randomseed(seed)

local R = function(p) return Studio.require(Studio.find(p)) end
local Conns = R("ServerScriptService.Services.City.OutsideConnectionService")
local Through = R("ServerScriptService.Services.City.Simulation.ThroughTrafficService")
Conns.Init(w.roadService, {})
Conns.Bind()
Conns.rescan()
Through.Init(w.roadService, Conns, nil)
w.Drivers.SetOutsideConnService(Conns)
Through.Start()

-- The last stretch before each exit, per outbound lane.
local WATCH = 700
local g = w.graph
local exitLanes = {} -- edgeId -> "north"/"south" lane ordinal label
for _, e in g:GetEdges() do
	local last = e.points[#e.points]
	if #e.out == 0 and math.abs(math.abs(last.Z) - HALF) < 40 then
		exitLanes[e.id] = (if last.Z > 0 then "N" else "S") .. e.laneOrdinal
	end
end

local stats = { changes = 0, mergeWaitSeconds = 0, maxMergeQueue = 0, exits = {}, stuckSamples = 0, samples = 0 }
local lastEdge: { [any]: string } = {}
local lastPos: { [any]: Vector3 } = {}
local DT = 1 / 30
local t = 0
while t < T do
	w:step(DT)
	t += DT
	local drivers = w.Drivers.__test.drivers
	local waiting = 0
	for model, st in drivers do
		if not model.Parent or not st.smoothCFrame then continue end
		local p = st.smoothCFrame.Position
		-- near the edge it is driving TOWARD (not the one it just came in at)
		local nearExit = HALF - math.abs(p.Z) < WATCH and st.smoothCFrame.LookVector.Z * p.Z > 0
		if nearExit and st.stopReason == "laneChange" then
			waiting += 1
			stats.mergeWaitSeconds += DT
		end
		local lc = st.laneChange
		if lc and st.connector == lc.pts and lastEdge[model] ~= "lc" and nearExit then
			stats.changes += 1
		end
		lastEdge[model] = if lc and st.connector == lc.pts then "lc" else st.edgeId
		if exitLanes[st.edgeId] then lastPos[model] = p end
	end
	stats.maxMergeQueue = math.max(stats.maxMergeQueue, waiting)
	-- which lane each car left by: it was last seen on an exit lane and is now gone
	for model, p in lastPos do
		if not model.Parent or not drivers[model] then
			local lane = exitLanes[lastEdge[model]]
			if lane then stats.exits[lane] = (stats.exits[lane] or 0) + 1 end
			lastPos[model] = nil
		end
	end
	if math.floor(t / DT) % 30 == 0 then
		stats.samples += 1
		for model, st in drivers do
			if model.Parent and (st.currentSpeed or 0) < 0.5 and (st.stuckTime or 0) + (st.noProgressTime or 0) > 20 then
				stats.stuckSamples += 1
			end
		end
	end
end

if process.env.DEBUG_LANES then
	local pairs_ = {}
	for model, st in w.Drivers.__test.drivers do
		if model.Parent and st.route and #st.route > 0 then
			local a, b = g:GetEdge(st.route[1]), g:GetEdge(st.route[#st.route])
			local changes = 0
			for i = 2, #st.route do
				local x, y = g:GetEdge(st.route[i - 1]), g:GetEdge(st.route[i])
				if x and y and x.segmentId == y.segmentId then changes += 1 end
			end
			local k = (a and a.laneOrdinal or 0) .. "->" .. (b and b.laneOrdinal or 0) .. " lc" .. changes
			pairs_[k] = (pairs_[k] or 0) + 1
		end
	end
	for k, n in pairs_ do print("   route", k, n) end
	if process.env.PROBE_COST then
		local shown = 0
		for model, st in w.Drivers.__test.drivers do
			if shown >= 3 or not (model.Parent and st.route and #st.route > 1) then continue end
			local a, b = g:GetEdge(st.route[1]), g:GetEdge(st.route[#st.route])
			if not (a and b and a.laneOrdinal ~= b.laneOrdinal) then continue end
			shown += 1
			local alt = {}
			for i, id in st.route do
				local e = g:GetEdge(id)
				if i > 1 and e.segmentId == g:GetEdge(st.route[i - 1]).segmentId then continue end
				for _, l in g:GetEdgesForSegment(e.segmentId) do
					if l.forward == e.forward and l.laneOrdinal == a.laneOrdinal then table.insert(alt, l.id) end
				end
			end
			print("   car", model.Name, "planned", g:EstimatePathCost(st.route, 1, st.profile), "stay-in-lane", g:EstimatePathCost(alt, 1, st.profile), "objective", g:EstimatePathCost(st.route, 1, nil), g:EstimatePathCost(alt, 1, nil))
			local c1, c2 = 0, 0
			for _, id in st.route do c1 += g:GetEdgeCongestion(id) end
			for _, id in alt do c2 += g:GetEdgeCongestion(id) end
			print("     congestion sum planned", c1, "alt", c2, "#route", #st.route, "#alt", #alt)
		end
	end
end
local live = 0
local stopped = 0
local reasons = {}
for model, st in w.Drivers.__test.drivers do
	if model.Parent then
		live += 1
		if (st.currentSpeed or 0) < 0.5 then stopped += 1 end
		local r = tostring(st.stopReason)
		reasons[r] = (reasons[r] or 0) + 1
	end
end
local exitList = {}
for lane, n in stats.exits do table.insert(exitList, lane .. "=" .. n) end
table.sort(exitList)
local reasonList = {}
for r, n in reasons do table.insert(reasonList, r .. "=" .. n) end
table.sort(reasonList)
print(("S7 map edge [%s, %ds, seed %d, camera %s] live %d (stopped %d) | lane changes in last %d studs: %d | merge-wait %.0f car-s, worst queue %d | stuck>20s samples %d | exits by lane: %s | errors %d")
	:format(mode, T, seed, if camFar then "far" else "near", live, stopped, WATCH, stats.changes,
		stats.mergeWaitSeconds, stats.maxMergeQueue, stats.stuckSamples, table.concat(exitList, " "), #Studio.errors))
print("   reasons: " .. table.concat(reasonList, " "))
if #Studio.errors > 0 then print(Studio.errors[1]:sub(1, 600)) end
