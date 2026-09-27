-- Server cost of the traffic AI at city scale: an NxN grid of avenues with signals, filled
-- to `cars` random trips and kept topped up, camera over the middle. Reports wall-clock
-- milliseconds per driver tick (the Heartbeat handler's work) and the same stats as S2.
-- usage: lune run t_perf.luau <mode> <cars> <seconds> [grid N] [far]
local World = require("./shim/traffic")
local Metrics = require("./shim/metrics")
local process = require("@lune/process")
local mode = process.args[1] or "cur"
local CARS = tonumber(process.args[2]) or 1000
local T = tonumber(process.args[3]) or 120
local N = tonumber(process.args[4]) or 6
local far = process.args[5] == "far"
local S = 300

local w = World.new(mode)
local V = w.V
-- the real clock, for an instrumented tree (the modules' own os.clock is the lab's virtual one)
w.Studio.env(w.Studio.find("ServerScriptService.Services.NPC.NPCDriverService")).shared.CLOCK = os.clock
for i = 0, N - 1 do
	for j = 0, N - 1 do
		local p = V.new(i * S, 0, j * S)
		if i < N - 1 then w:road(p, V.new((i + 1) * S, 0, j * S), "CollectorRoad") end
		if j < N - 1 then w:road(p, V.new(i * S, 0, (j + 1) * S), "CollectorRoad") end
	end
end
w:build(true)
local mid = (N - 1) * S / 2
w:camera(if far then V.new(mid + 8000, 0, mid) else V.new(mid, 0, mid))
local m = Metrics.new(w)
local rng = w.Studio.Random.new(1)
local function randomRoadPoint()
	local i, j = rng:NextInteger(0, N - 1), rng:NextInteger(0, N - 2)
	local along = rng:NextNumber(0.2, 0.8) * S
	if rng:NextNumber() < 0.5 then return V.new(i * S, 0, j * S + along) end
	return V.new(j * S + along, 0, i * S)
end

-- Time the driver Heartbeat handler only: wrap every Heartbeat connection.
local RunService = w.Studio.game:GetService("RunService")
local busy, ticks = 0, 0
local sig = RunService.Heartbeat
for _, c in sig._conns do
	local fn = c._fn
	c._fn = function(dt)
		local t0 = os.clock()
		fn(dt)
		busy += os.clock() - t0
		ticks += 1
	end
end

local DT = 1 / 30
local t = 0
local live = 0
local warm = math.min(40, T / 3)
local busyAtWarm, ticksAtWarm = 0, 0
while t < T do
	live = 0
	for _, rec in w.cars do
		if not rec.arrived and not rec.aborted then live += 1 end
	end
	-- keep the city topped up, a few spawns per frame
	for _ = 1, 6 do
		if live >= CARS then break end
		local a, b = randomRoadPoint(), randomRoadPoint()
		if (a - b).Magnitude > 400 and w.Drivers.IsPointClear(a, 12) then
			if w:drive(a, b) then live += 1 end
		end
	end
	w:step(DT)
	t += DT
	if math.abs(t - warm) < DT / 2 then busyAtWarm, ticksAtWarm = busy, ticks end
	if math.floor(t / DT) % 15 == 0 then Metrics.overlaps(m) end
end
-- Who is standing still, and why (the traffic AI's own reason for its speed).
local still, why = 0, {}
for _, rec in w.cars do
	local st = w:state(rec.model)
	if st and (st.currentSpeed or 0) < 0.5 then
		still += 1
		local k = tostring(st.stopReason) .. (if st.connector then "+box" else "") .. (if st.blockedBy then "+blockedBy" else "")
		why[k] = (why[k] or 0) + 1
	end
end
local whyList = {}
for k, n in why do table.insert(whyList, k .. "=" .. n) end
table.sort(whyList)
local ms = (busy - busyAtWarm) / math.max(1, ticks - ticksAtWarm) * 1000
local s = Metrics.summary(m)
print(("PERF [%s, target %d cars, grid %dx%d, %ds, camera %s] live %d | %.2f ms per heartbeat (%d ticks after warm-up) | arrived %d | overlapPairs %d | stalls %d | errors %d")
	:format(mode, CARS, N, N, T, if far then "far" else "near", live, ms, ticks - ticksAtWarm, s.arrived, s.overlapPairs, s.stallRescues, s.errors))
print(("   standing still %d: %s"):format(still, table.concat(whyList, " ")))
if process.env.DUMP_BLOCKED then
	local shown = 0
	local drivers = w.Drivers.__test.drivers
	local function desc(st)
		local p = st.smoothCFrame.Position
		local lc = st.laneChange and st.connector == st.laneChange.pts
		return ("%s@(%d,%d) %s edge=%s d=%.0f next=%s pend=%s spd=%.1f why=%s stillFor=%.0f"):format(st.model.Name, p.X, p.Z,
			if lc then "LANECHG" elseif st.connector then "BOX" else "lane", st.edgeId, st.edgeDist, tostring(st.nextEdgeId), tostring(st.pendingNextEdgeId),
			st.currentSpeed or 0, tostring(st.stopReason), st.noProgressTime or 0)
	end
	for _, rec in w.cars do
		local st = w:state(rec.model)
		if shown < 12 and st and (st.currentSpeed or 0) < 0.5 and st.stopReason == "blocked" and st.blockedBy then
			shown += 1
			local b = drivers[st.blockedBy]
			print("   BLOCKED " .. desc(st))
			print("        by " .. (if b then desc(b) else tostring(st.blockedBy) .. " (not driving)") ..
				(if b and b.blockedBy == st.model then "  MUTUAL" else "") ..
				(if b and b.blockedBy and drivers[b.blockedBy] then "  -> which is blocked by " .. b.blockedBy.Name else ""))
		end
	end
end
if #w.Studio.errors > 0 then print(w.Studio.errors[1]:sub(1, 600)) end
-- An instrumented tree (see README) leaves inclusive seconds per function in shared.PROF.
local env = w.Studio.env(w.Studio.find("ServerScriptService.Services.NPC.NPCDriverService"))
local prof = env.shared and env.shared.PROF
if prof then
	local rows = {}
	for k, v in prof do table.insert(rows, { k, v }) end
	table.sort(rows, function(a, b) return a[2] > b[2] end)
	for _, r in rows do print(("   %-28s %8.1f ms/tick"):format(r[1], r[2] / math.max(1, ticks) * 1000)) end
end
