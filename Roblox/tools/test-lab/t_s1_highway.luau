-- Scenario 1: busy 3-lane one-way highway, 10 pieces (2000 studs). Cars enter in random
-- lanes and leave in random lanes (some must change lanes, most need not).
local World = require("./shim/traffic")
local Metrics = require("./shim/metrics")
local process = require("@lune/process")
local mode = process.args[1] or "patched"
local seed = tonumber(process.args[2]) or 1
local w = World.new(mode)
local V = w.V
for i = 0, 9 do w:road(V.new(0, 0, i * 200), V.new(0, 0, (i + 1) * 200), "Highway3W") end
w:build()
w:camera(V.new(0, 0, 1000))
local m = Metrics.new(w)
local rng = w.Studio.Random.new(seed)
-- lane centres: offsets across the carriageway (3 lanes); pick by x offset
local lanes = {}
for _, e in w.graph:GetEdges() do if e.segmentId == w.graph:GetEdges()[1].segmentId then table.insert(lanes, e.points[1].X) end end
local t, nextSpawn, spawned = 0, 0, 0
local lastArrived, lastArrivalAt = -1, 0
while t < 150 do
	if t >= nextSpawn and spawned < 140 then
		local x0 = lanes[rng:NextInteger(1, #lanes)]
		local x1 = if rng:NextNumber() < 0.7 then x0 else lanes[rng:NextInteger(1, #lanes)]
		-- like the game's spawn gates: only onto a clear bit of road
		if w.Drivers.IsPointClear(V.new(x0, 0, 3), 14) then
			w:drive(V.new(x0, 0, 3), V.new(x1, 0, 1995))
			spawned += 1
		end
		nextSpawn = t + rng:NextNumber(0.3, 0.9)
	end
	w:step(1 / 30)
	Metrics.tick(m)
	-- jam watch (verbose runs): no arrival for 30 s once traffic is flowing -> dump and stop
	if process.args[3] == "v" and math.floor(t * 30) % 30 == 0 then
		local a = Metrics.summary(m).arrived
		if a ~= lastArrived then lastArrived = a; lastArrivalAt = t end
		if t > 40 and t - lastArrivalAt > 30 then
			print(("JAM at t=%.0f (no arrival since %.0f)"):format(t, lastArrivalAt))
			for _, rec in w.cars do
				local st = w:state(rec.model)
				if st then
					local p = st.smoothCFrame and st.smoothCFrame.Position
					local lc = st.laneChange
					print(("  %s at %s spd %.1f edge %s@%.1f conn %s next %s pend %s reason %s blockedBy %s merge %s holdAt %s lc %s")
						:format(rec.model.Name, p and ("%.0f,%.0f"):format(p.X, p.Z) or "?", st.currentSpeed or 0, tostring(st.edgeId), st.edgeDist or 0,
							tostring(st.connector ~= nil), tostring(st.nextEdgeId), tostring(st.pendingNextEdgeId), tostring(st.stopReason),
							st.blockedBy and st.blockedBy.Name or "-", tostring(st.mergeInto), tostring(st.mergeHoldAt),
							lc and ("%s->%s %.0f..%.0f"):format(tostring(lc.from), tostring(lc.to), lc.d0 or -1, lc.d1 or -1) or "-"))
				end
			end
			break
		end
	end
	if math.floor(t * 30) % 6 == 0 then Metrics.overlaps(m) end
	t += 1 / 30
end
Metrics.print(("S1 highway [%s seed %d]"):format(mode, seed), Metrics.summary(m))
if os.getenv and false then end
local reasons = {}
for _, rec in w.cars do
	local st = w:state(rec.model)
	if st then
		local p = st.smoothCFrame and st.smoothCFrame.Position
		local key = tostring(st.stopReason) .. (if st.laneChange then "+lc" else "") .. (if st.connector then "+conn" else "")
		reasons[key] = (reasons[key] or 0) + 1
		if process.args[3] == "v" then print("  still driving", rec.model.Name, key, p and math.floor(p.X) .. "," .. math.floor(p.Z), "speed", math.floor(st.currentSpeed or 0), "edge", st.edgeId, "@", math.floor(st.edgeDist), "route", st.routeIndex, "/", #st.route, st.route[st.routeIndex + 1]) end
	end
end
for k, v in reasons do print("  unfinished:", k, v) end
if #w.Studio.errors > 0 then print(w.Studio.errors[1]:sub(1, 500)) end
