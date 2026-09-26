-- Scenario 5: right of way at junctions WITHOUT signals. Steady traffic from every arm;
-- measures per-arm throughput, delay at the junction and starvation.
-- lune run t_s5_giveway <mode> <cross|cross-heavy|tee> [seed] [seconds]
local World = require("./shim/traffic")
local Metrics = require("./shim/metrics")
local process = require("@lune/process")
local mode = process.args[1] or "fix4"
local kind = process.args[2] or "cross"
local seed = tonumber(process.args[3]) or 1
local T = tonumber(process.args[4]) or 360
local w = World.new(mode, { debugJunction = process.args[5] == "dbg" })
local V = w.V
local L = 300
local arms = {}
if kind == "tee" then
	arms = { { name = "main W", dir = V.new(-1, 0, 0), rate = 1 / 4 }, { name = "main E", dir = V.new(1, 0, 0), rate = 1 / 4 },
		{ name = "side S", dir = V.new(0, 0, 1), rate = 1 / 12 } }
else
	arms = { { name = "N", dir = V.new(0, 0, -1), rate = 1 / 9 }, { name = "E", dir = V.new(1, 0, 0), rate = 1 / 9 },
		{ name = "S", dir = V.new(0, 0, 1), rate = 1 / 9 }, { name = "W", dir = V.new(-1, 0, 0), rate = 1 / 9 } }
	if kind == "cross-heavy" then arms[1].rate = 1 / 3.5 end
end
local centre = V.new(0, 0, 0)
for _, a in arms do w:road(centre, a.dir * L, "NarrowRoad") end
w:build(false)
w:camera(centre)
local rng = w.Studio.Random.new(seed)
for _, a in arms do
	a.nextAt = rng:NextNumber(0, 3); a.through = 0; a.delays = {}; a.backlog = 0; a.pending = 0
	a.lastEntry = 0; a.headWaitingSince = nil; a.worstStarve = 0
	-- inbound lane start and outbound lane end, offset to the kerb side by probing the graph
	a.spawn = a.dir * (L - 6); a.goal = a.dir * (L - 6)
end
local recArm, recArrive = {}, {}
local mt = Metrics.new(w)
mt.log = process.args[5] == "log"
local t = 0
while t < T do
	for ai, a in arms do
		if t >= a.nextAt then
			a.pending += 1
			a.nextAt = t + (1 / a.rate) * rng:NextNumber(0.6, 1.4)
		end
		if a.pending > 0 and w.Drivers.IsPointClear(a.spawn, 14) then
			local bi
			repeat bi = rng:NextInteger(1, #arms) until bi ~= ai
			local rec = w:drive(a.spawn, arms[bi].goal)
			if rec then a.pending -= 1; recArm[rec] = a end
		end
	end
	w:step(1 / 30)
	t += 1 / 30
	if math.floor(t * 30) % 10 == 0 then Metrics.overlaps(mt) end

	if process.args[5] == "dbg" and not _G.__dbgDone then
		local D = w.Drivers.__test
		for _, rec in w.cars do
			local st = w:state(rec.model)
			if st and not st.connector and (st.blockedTime or 0) > (tonumber(process.args[6]) or 12) then
				_G.__dbgDone = true
				local e = w.graph:GetEdge(st.edgeId)
				local node = e.toNode
				print(("DBG t=%.1f waiter %s edge=%s next=%s blocked=%.1f distToLine=%.2f room=%s boxConflict=%s canEnter=%s")
					:format(t, rec.model.Name, st.edgeId, tostring(st.pendingNextEdgeId), st.blockedTime, D.distToStopLine(w.graph, st, e, node),
						tostring(D.exitLaneHasRoom(w.graph, st, st.pendingNextEdgeId)),
						tostring(D.boxHasConflict(w.graph, st, e, node, e.toDir, e.outMovement[st.pendingNextEdgeId])),
						tostring(D.canEnter(w.graph, st, e, st.pendingNextEdgeId))))
				print("  in-edges:", #(w.graph._edgesByToNode[node] or {})); st.__dbg = true; w.Studio.echo = true
				for _, ie in w.graph._edgesByToNode[node] or {} do
					for _, o in D.edgeIndex[ie.id] or {} do
						local nx = o.pendingNextEdgeId
						print(("   car %s edge=%s seg=%s next=%s spd=%.1f dist=%.1f blocked=%.1f owes=%s canEnter=%s")
							:format(o.model.Name, ie.id, tostring(ie.segmentId), tostring(nx), o.currentSpeed or 0, D.distToStopLine(w.graph, o, ie, node),
								o.blockedTime or 0, nx and tostring(D.owesCourtesy(w.graph, o, ie, node, ie.toDir, ie.outMovement[nx] or "straight")) or "-",
								nx and tostring(D.canEnter(w.graph, o, ie, nx)) or "-"))
					end
				end
				for _, o in D.drivers do
					if o.connector and o.nextEdgeId then
						local ne = w.graph:GetEdge(o.nextEdgeId)
						if ne and ne.fromNode == node then
							local lc = o.laneChange and o.connector == o.laneChange.pts
							print(("   BOX %s from=%s next=%s spd=%.1f connDist=%.1f/%d lc=%s reason=%s blockedBy=%s connBlocked=%.1f")
								:format(o.model.Name, o.edgeId, o.nextEdgeId, o.currentSpeed or 0, o.connDist or 0, #o.connector, tostring(lc),
									tostring(o.stopReason), o.blockedBy and o.blockedBy.Name or "-", o.connBlockedTime or 0))
						end
					end
				end
				break
			end
		end
	end
	-- per-car: arrival near the junction, entry into the box
	for _, rec in w.cars do
		local a = recArm[rec]
		if not a or rec._entered then continue end
		local st = w:state(rec.model)
		if not st or not st.smoothCFrame then continue end
		local d = (st.smoothCFrame.Position - centre).Magnitude
		if not recArrive[rec] and d < 45 then recArrive[rec] = t end
		if st.connector and not (st.laneChange and st.connector == st.laneChange.pts) and d < 40 then
			rec._entered = true
			a.through += 1
			table.insert(a.delays, t - (recArrive[rec] or t))
			a.lastEntry = t
		end
	end
	-- starvation: an arm with a car waiting at the line while nothing from it enters
	for _, a in arms do
		local waiting = false
		for _, rec in w.cars do
			if recArm[rec] == a and not rec._entered and recArrive[rec] then waiting = true break end
		end
		if waiting and not a.dumped and t - math.max(a.headWaitingSince or t, a.lastEntry) > (tonumber(process.args[6]) or 40) and process.args[5] == "trace" then
			a.dumped = true
			local D = w.Drivers.__test
			for _, rec in w.cars do
				local st = w:state(rec.model)
				if recArm[rec] == a and not rec._entered and recArrive[rec] and st then
					local e = w.graph:GetEdge(st.edgeId)
					local nxt = st.pendingNextEdgeId
					local lead = D.queueLeader(st)
					print(("   STARVED %s t=%.0f %s reason=%s spd=%.1f blocked=%.1f stuck=%.1f edgeDist=%.1f/%.0f next=%s move=%s blockedBy=%s lead=%s conn=%s")
						:format(a.name, t, rec.model.Name, tostring(st.stopReason), st.currentSpeed or 0, st.blockedTime or 0, st.stuckTime or 0,
							st.edgeDist, e and e.length or 0, tostring(nxt), e and nxt and tostring(e.outMovement[nxt]) or "-",
							st.blockedBy and st.blockedBy.Name or "-", lead and lead.model.Name or "-", tostring(st.connector ~= nil)))
				end
			end
			-- and who is in the junction box right now
			for _, rec in w.cars do
				local st = w:state(rec.model)
				if st and st.connector and (st.smoothCFrame.Position - centre).Magnitude < 40 then
					print(("     IN BOX %s from=%s next=%s spd=%.1f reason=%s blockedBy=%s"):format(rec.model.Name, st.edgeId, tostring(st.nextEdgeId),
						st.currentSpeed or 0, tostring(st.stopReason), st.blockedBy and st.blockedBy.Name or "-"))
				end
			end
		end
		if waiting then
			a.headWaitingSince = a.headWaitingSince or math.max(a.lastEntry, t)
			a.worstStarve = math.max(a.worstStarve, t - math.max(a.headWaitingSince, a.lastEntry))
		else
			a.headWaitingSince = nil
		end
	end
end
print(("S5 give-way %-11s [%s seed %d, %ds]"):format(kind, mode, seed, T))
for _, a in arms do
	local sum, worst = 0, 0
	for _, d in a.delays do sum += d; worst = math.max(worst, d) end
	local offered = a.through + a.pending
	print(("   arm %-7s demand %4.1f/min  through %3d  not yet spawned %3d  delay avg %5.1fs worst %5.1fs  longest starve %5.1fs")
		:format(a.name, a.rate * 60, a.through, a.pending, if #a.delays > 0 then sum / #a.delays else 0, worst, a.worstStarve))
end
local stalls, overl = 0, 0
for _, x in w.Studio.warnings do if x:find("stalled") then stalls += 1 end end
local sm = Metrics.summary(mt)
print(("   errors %d, stall rescues %d, overlapping pairs %d"):format(#w.Studio.errors, stalls, sm.overlapPairs))
