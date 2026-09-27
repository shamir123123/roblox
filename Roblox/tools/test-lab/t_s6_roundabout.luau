-- Scenario 6: traffic through a roundabout built by the REAL RoadService (ring, arms,
-- centre, splitter islands). Four two-way arms, steady demand from each.
-- lune run t_s6_roundabout <mode> <small|medium|large> [seed] [seconds] [rate per arm per min]
local World = require("./shim/traffic")
local Metrics = require("./shim/metrics")
local process = require("@lune/process")
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local mode = process.args[1] or "fix5"
local size = process.args[2] or "medium"
local seed = tonumber(process.args[3]) or 1
local T = tonumber(process.args[4]) or 300
local rate = (tonumber(process.args[5]) or 8) / 60
local w = World.new(mode)
local Studio, V = w.Studio, w.V
local R = function(p) return Studio.require(Studio.find(p)) end
local Terrain = R("ServerScriptService.Services.Terrain.TerrainDataService")
Terrain.Init()
do local hm = Terrain.getHeightmap(); for gx = 924, 1124 do for gz = 924, 1124 do hm:setCorner(gx, gz, 256 + 40) end end end
local RC = R("ReplicatedStorage.Road.RoadConstants")
local RoadService = R("ServerScriptService.Services.Road.RoadService")
RoadService.Init(); RoadService.setUnlockCheck(function() return true end); RoadService.Bind(); RoadService.Start()
Studio.step(0.1)
local L = 260
local function road(a, b)
	local d = b - a
	assert(RoadService.placeFromRequest({ p0 = a, p1 = a + d / 3, p2 = a + d * 2 / 3, p3 = b, roadType = "NarrowRoad" }))
	Studio.step(0.2)
end
road(V.new(-L, 0, 0), V.new(L, 0, 0))
road(V.new(0, 0, -L), V.new(0, 0, L))
local radius = if size == "small" then RC.ROUNDABOUT_RADIUS_SMALL elseif size == "large" then RC.ROUNDABOUT_RADIUS_LARGE else RC.ROUNDABOUT_RADIUS_MEDIUM
local rt = if size == "small" then "Roundabout1" elseif size == "large" then "Roundabout3" else "Roundabout"
assert(RoadService.placeRoundaboutFromRequest({ center = V.new(0, 0, 0), radius = radius, roadType = rt }))
for _ = 1, 20 do Studio.step(0.1) end
w.net = RoadService.getNetwork()
w.graph = RoadService.getNavigationGraph()
w.Drivers.Init(RoadService)
w.Drivers.Bind()
w.Drivers.Start()
Studio.step(0.05)
w:camera(V.new(0, 0, 0))

local arms = { { name = "W", dir = V.new(-1, 0, 0) }, { name = "E", dir = V.new(1, 0, 0) }, { name = "N", dir = V.new(0, 0, -1) }, { name = "S", dir = V.new(0, 0, 1) } }
local rng = Studio.Random.new(seed)
local roadY = 0
for _, node in w.net:getNodes() do if #node.segments == 1 then roadY = node.position.Y + RC.ROAD_THICKNESS * 0.5 break end end
for _, a in arms do
	a.nextAt = rng:NextNumber(0, 4); a.pending = 0; a.through = 0
	a.spawn = a.dir * (L - 8) + V.new(0, roadY, 0); a.goal = a.spawn
end
local mt = Metrics.new(w)
mt.log = process.args[7] == "log"
local tracks = {}
local t = 0
while t < T do
	for ai, a in arms do
		if t >= a.nextAt then a.pending += 1; a.nextAt = t + (1 / rate) * rng:NextNumber(0.6, 1.4) end
		if a.pending > 0 and w.Drivers.IsPointClear(a.spawn, 14) then
			local bi
			repeat bi = rng:NextInteger(1, #arms) until bi ~= ai
			local rec = w:drive(a.spawn, arms[bi].goal)
			if rec then a.pending -= 1; a.through += 1 end
		end
	end
	w:step(1 / 30)
	t += 1 / 30
	if math.floor(t * 30) % 6 == 0 then
		Metrics.overlaps(mt)
		for _, rec in w.cars do
			local st = w:state(rec.model)
			if st and st.smoothCFrame and (st.smoothCFrame.Position).Magnitude < radius + 40 then
				local cf = st.smoothCFrame
				local hx, hz = 1.9, (st.halfLength or 4.5)
				for _, c in { { hx, hz }, { -hx, hz }, { hx, -hz }, { -hx, -hz }, { 0, 0 } } do
					local p = cf * V.new(c[1], 0, c[2])
					table.insert(tracks, { p.X, p.Z, rec.model.Name })
				end
			end
		end
	end
end
local arrived, stuck = 0, 0
for _, rec in w.cars do
	if rec.arrived then arrived += 1 end
	local st = w:state(rec.model)
	if st and (st.stuckTime or 0) > 30 then stuck += 1 end
end
if process.args[8] == "stuck" then
	local D = w.Drivers.__test
	if D.ringOf then
		local seen = {}
		for _, e in w.graph:GetEdges() do
			if e.isRoundabout then
				local ring = D.ringOf(w.graph, e)
				if not seen[ring] then
					seen[ring] = true
					local len, onRing = 0, 0
					for _, id in ring.edges do
						len += w.graph:GetEdge(id).length
						for _, o in D.edgeIndex[id] or {} do if o.edgeId == id then onRing += 1 end end
					end
					print(("RING lanes %d length %.0f capacity %d on ring %d room %s"):format(#ring.edges, len, ring.capacity, onRing, tostring(D.ringHasRoom(w.graph, e))))
				end
			end
		end
	end
	for _, rec in w.cars do
		local st = w:state(rec.model)
		if st and (st.stuckTime or 0) + (st.connBlockedTime or 0) > 5 or (st and (st.currentSpeed or 0) < 0.5 and not rec.arrived) then
			local lead, gap = D.queueLeader(st)
			local p = st.smoothCFrame and st.smoothCFrame.Position
			print(("STUCK %s at %s edge=%s next=%s pend=%s conn=%s connDist=%.1f edgeDist=%.1f reason=%s blockedBy=%s leader=%s gap=%s stuck=%.0f")
				:format(rec.model.Name, p and ("%d,%d"):format(p.X, p.Z) or "?", tostring(st.edgeId), tostring(st.nextEdgeId), tostring(st.pendingNextEdgeId),
					tostring(st.connector ~= nil), st.connDist or 0, st.edgeDist or 0, tostring(st.stopReason), st.blockedBy and st.blockedBy.Name or "-",
					lead and lead.model.Name or "-", gap and ("%.1f"):format(gap) or "-", st.stuckTime or 0))
		end
	end
end
local sm = Metrics.summary(mt)
local stalls = 0
for _, x in Studio.warnings do if x:find("stalled") then stalls += 1 end end
print(("S6 roundabout %-6s [%s seed %d, %ds, %.0f/min/arm] spawned %d arrived %d still-stuck %d overlapPairs %d stalls %d errors %d")
	:format(size, mode, seed, T, rate * 60, #w.cars, arrived, stuck, sm.overlapPairs, stalls, #Studio.errors))
for _, e in Studio.errors do print("ERR", e) end
for _, a in arms do print(("   arm %s spawned %d, still waiting to spawn %d"):format(a.name, a.through, a.pending)) end
local out = process.args[6]
if out then
	fs.writeFile(out .. ".tracks.json", serde.encode("json", tracks))
	require("./render/dump")(Studio, Studio.game.Workspace, out .. ".json")
	print("dumped", out)
end
