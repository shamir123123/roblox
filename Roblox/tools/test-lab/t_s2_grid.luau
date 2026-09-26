-- Scenario 2: a 4x4-node street grid (200-stud blocks), flooded with random trips until it
-- jams. Measures ghosting (overlaps), red-light running, rescues, and whether anything moves.
local World = require("./shim/traffic")
local Metrics = require("./shim/metrics")
local process = require("@lune/process")
local mode = process.args[1] or "patched"
local signals = process.args[2] == "signals"
local total = tonumber(process.args[3]) or 220
local seed = tonumber(process.args[4]) or 1
local w = World.new(mode)
local V = w.V
local N, S = 4, 200
for i = 0, N - 1 do
	for j = 0, N - 1 do
		local p = V.new(i * S, 0, j * S)
		if i < N - 1 then w:road(p, V.new((i + 1) * S, 0, j * S), "CollectorRoad") end
		if j < N - 1 then w:road(p, V.new(i * S, 0, (j + 1) * S), "CollectorRoad") end
	end
end
w:build(signals)
w:camera(V.new(300, 0, 300))
local m = Metrics.new(w)
m.log = process.args[6] == "log"
local rng = w.Studio.Random.new(seed)
local function randomRoadPoint()
	-- a point on a random block edge (mid-block), so trips start and end on the street
	local i, j = rng:NextInteger(0, N - 1), rng:NextInteger(0, N - 2)
	local along = rng:NextNumber(0.25, 0.75) * S
	if rng:NextNumber() < 0.5 then return V.new(i * S, 0, j * S + along) end
	return V.new(j * S + along, 0, i * S)
end
local violations, entered = 0, 0
snaps = 0
local prevConn = {}
local t, spawned = 0, 0
local T = tonumber(process.args[5]) or 360
local lastMoveAt = {}
while t < T do
	if spawned < total and math.floor(t * 30) % 3 == 0 then
		local a, b = randomRoadPoint(), randomRoadPoint()
		if (a - b).Magnitude > 300 and w.Drivers.IsPointClear(a, 14) then
			if w:drive(a, b) then spawned += 1 end
		end
	end
	w:step(1 / 30)
	Metrics.tick(m)
	for _, rec in w.cars do
		local st = w:state(rec.model)
		if not st then continue end
		local conn = st.connector ~= nil and not (st.laneChange and st.connector == st.laneChange.pts)
		-- how long the light has been against this car's pending move (while approaching)
		if not st.connector then
			local nextId = st.pendingNextEdgeId
			if nextId and not w.Signals.CanGo(st.edgeId, nextId) and not w.Signals.IsApproachYellow(st.edgeId) then
				rec._redFor = (rec._redFor or 0) + 1 / 30
			else
				rec._redFor = 0
			end
		end
		if conn and not prevConn[rec] then
			local e = w.graph:GetEdge(st.edgeId)
			if e and w.Signals.HasSignal and w.Signals.HasSignal(e.toNode) then
				entered += 1
				-- red for over a second before the car entered: it crossed the stop line on red
				if (rec._redFor or 0) > 1.0 and not st.rescueFrom then
					violations += 1
					if m.log then print(("   RED RUN t=%.1f %s edge=%s next=%s redFor=%.1fs reason=%s redTime=%s stuck=%.0f blocked=%.0f")
						:format(t, rec.model.Name, st.edgeId, tostring(st.nextEdgeId), rec._redFor, tostring(st.stopReason),
							tostring(st.redTime), st.stuckTime or 0, st.blockedTime or 0)) end
				end
			end
		end
		prevConn[rec] = conn
		if rec._prevEdge and st.edgeId ~= rec._prevEdge and not st.connector and not rec._prevConn2 then
			local a, b = w.graph:GetEdge(rec._prevEdge), w.graph:GetEdge(st.edgeId)
			if a and b and a.segmentId == b.segmentId and a.forward == b.forward then
				snaps = (snaps or 0) + 1
				if m.log then print(("   SIDEWAYS SNAP t=%.1f %s %s -> %s"):format(t, rec.model.Name, rec._prevEdge, st.edgeId)) end
			end
		end
		rec._prevEdge = st.edgeId
		rec._prevConn2 = st.connector ~= nil
		local p = st.smoothCFrame and st.smoothCFrame.Position
		if p then
			local last = rec._lastP
			if not last or (p - last).Magnitude > 0.5 then rec._lastP = p; lastMoveAt[rec] = t end
		end
	end
	if math.floor(t * 30) % 10 == 0 then Metrics.overlaps(m) end
	t += 1 / 30
end
local s = Metrics.summary(m)
Metrics.print(("S2 grid %s [%s, %d cars, seed %d]"):format(signals and "signals" or "no-signal", mode, total, seed), s)
local frozen, moving, reasons = 0, 0, {}
for _, rec in w.cars do
	local st = w:state(rec.model)
	if st then
		if t - (lastMoveAt[rec] or 0) > 60 then
			frozen += 1
			local k = tostring(st.stopReason) .. (if st.connector then "+inBox" else "")
			reasons[k] = (reasons[k] or 0) + 1
		else moving += 1 end
	end
end
local rk = {}
for k, v in reasons do table.insert(rk, k .. "=" .. v) end
print(("   sideways snaps (lane jumps without a lane change) %d"):format(snaps))
print(("   signal entries %d, red-light runs %d | still on road: %d moving, %d not moved for 60s (%s)")
	:format(entered, violations, moving, frozen, table.concat(rk, " ")))
for i = 1, math.min(3, #w.Studio.errors) do print("   ERR", w.Studio.errors[i]:sub(1, 300)) end
if process.args[7] == "trace" then
	local D = w.Drivers.__test
	for _, rec in w.cars do
		local st = w:state(rec.model)
		if st and t - (lastMoveAt[rec] or 0) > 60 then
			local lead, gap = D.queueLeader(st)
			local p = st.smoothCFrame.Position
			print(("   FROZEN %s at %d,%d reason=%s box=%s edge=%s next=%s blockedBy=%s queueLead=%s gap=%s rescue=%s")
				:format(rec.model.Name, p.X, p.Z, tostring(st.stopReason), tostring(st.connector ~= nil), st.edgeId, tostring(st.nextEdgeId),
					st.blockedBy and st.blockedBy.Name or "-", lead and lead.model.Name or "-", gap and ("%.1f"):format(gap) or "-", tostring(st.rescueFrom ~= nil)))
		end
	end
end
if process.args[8] then
	local D = w.Drivers.__test
	for _, rec in w.cars do
		local st = w:state(rec.model)
		if not st or t - (lastMoveAt[rec] or 0) <= 60 or st.blockedBy then continue end
		local lead = D.queueLeader(st)
		if lead then continue end
		local keys = {}
		for k, v in st do
			local tv = type(v)
			if tv == "number" or tv == "boolean" or tv == "string" then table.insert(keys, k .. "=" .. (if tv == "number" then ("%.2f"):format(v) else tostring(v))) end
		end
		table.sort(keys)
		print("   HEAD STATE " .. rec.model.Name .. ": " .. table.concat(keys, " "))
		print("   connector points:", st.connector and #st.connector, "connCum total:", st.connCum and st.connCum[#st.connCum], "laneChange:", st.laneChange ~= nil)
		local sp, fc, bd, bl = w.PathFollower.getMotionLimits(rec.model, st.smoothCFrame.Position, st.smoothCFrame.LookVector)
		print("   motion limits now: speedFactor", sp, "forwardClearance", fc, "blockerDot", bd, "blocker", bl and bl.Name)
	end
end
