-- Scenario 9: junctions along a divided highway. A Highway4 runs west-east with, all on its
-- south side, an on-ramp joining at x=-400, a street T-ing in at x=0 and an off-ramp leaving
-- at x=400. Traffic both ways on the highway plus trips on and off it. Measures:
--   far-side stops  -- samples of a car on the carriageway ACROSS the median from the side
--                      road standing still near one of these junctions (should be 0: nothing
--                      there concerns it)
--   median turns    -- routes that turn between the side road and the far carriageway
--   stuck           -- cars that have not moved for 60 s
-- usage: lune run t_s9_hwyjunction.luau <mode> <seconds> <seed>
local World = require("./shim/traffic")
local Metrics = require("./shim/metrics")
local process = require("@lune/process")
local mode = process.args[1] or "cur"
local T = tonumber(process.args[2]) or 300
local seed = tonumber(process.args[3]) or 1

local w = World.new(mode)
local V = w.V
local net = w.net
local function seg(a: Vector3, b: Vector3, rt: string, p1: Vector3?, p2: Vector3?)
	local d = b - a
	return net:addSegment(a, p1 or (a + d / 3), p2 or (a + d * 2 / 3), b, rt)
end
local xs = { -1400, -400, 0, 400, 1400 }
for i = 1, #xs - 1 do seg(V.new(xs[i], 0, 0), V.new(xs[i + 1], 0, 0), "Highway4") end
local RR = w.Studio.require(w.Studio.find("ReplicatedStorage.Road.RoadRules"))
-- The carriageway on the south side (+Z) runs east when lanes sit right of travel.
local nearDir = if V.new(1, 0, 0):Cross(V.new(0, 1, 0)).Z * RR.getLaneSideSign() > 0 then 1 else -1
-- On-ramp: joins at x=-400 heading with the near carriageway, 32 degrees off it.
local a = math.rad(32)
local function rampInto(x: number)
	local p3 = V.new(x, 0, 0)
	local hd = V.new(nearDir, 0, 0)
	local endDir = (hd * math.cos(a) + V.new(0, 0, -1) * math.sin(a)).Unit
	local p0 = p3 - hd * 300 + V.new(0, 0, 130)
	seg(p0, p3, "Highway1W", p0 + hd * 100, p3 - endDir * 64)
	return p0
end
local function rampOutOf(x: number)
	local p0 = V.new(x, 0, 0)
	local hd = V.new(nearDir, 0, 0)
	local startDir = (hd * math.cos(a) + V.new(0, 0, 1) * math.sin(a)).Unit
	local p3 = p0 + hd * 300 + V.new(0, 0, 130)
	seg(p0, p3, "Highway1W", p0 + startDir * 64, p3 - hd * 100)
	return p3
end
local onStart = rampInto(if nearDir > 0 then -400 else 400)
local offEnd = rampOutOf(if nearDir > 0 then 400 else -400)
seg(V.new(0, 0, 0), V.new(0, 0, 500), "CollectorRoad")
w:build(false)
w:camera(V.new(0, 0, 0))
local g = w.graph

local W, E = V.new(-1390, 0, 0), V.new(1390, 0, 0)
local streetEnd = V.new(0, 0, 490)
local function laneStart(pos: Vector3, heading: number)
	-- a point on the carriageway that runs `heading` (+1 east / -1 west)
	local off = if heading == nearDir then 12 else -12
	return pos + V.new(0, 0, off)
end
local trips = {
	{ from = laneStart(W, 1), to = laneStart(E, 1), rate = 1 / 1.6 },   -- eastbound through
	{ from = laneStart(E, -1), to = laneStart(W, -1), rate = 1 / 1.6 }, -- westbound through
	{ from = onStart, to = laneStart(if nearDir > 0 then E else W, nearDir), rate = 1 / 6 },
	{ from = laneStart(if nearDir > 0 then W else E, nearDir), to = offEnd, rate = 1 / 6 },
	{ from = streetEnd, to = laneStart(if nearDir > 0 then E else W, nearDir), rate = 1 / 10 },
	{ from = laneStart(if nearDir > 0 then W else E, nearDir), to = streetEnd, rate = 1 / 10 },
}
local rng = w.Studio.Random.new(seed)
for _, tr in trips do tr.nextAt = rng:NextNumber(0, 2); tr.spawned = 0; tr.failed = 0 end
local m = Metrics.new(w)

local nodes = {} -- junction node ids along the highway
for id, node in net:getNodes() do
	if #node.segments >= 3 then table.insert(nodes, { id = id, pos = node.position }) end
end
local farStops, farSamples, medianTurns = 0, 0, 0
for _, e in g:GetEdges() do
	for _, o in e.out do
		local oe = g:GetEdge(o)
		local mv = e.outMovement[o]
		if oe and mv == RR.getCrossingTurn() and (e.roadClass == "highway" or oe.roadClass == "highway") and e.segmentId ~= oe.segmentId then
			medianTurns += 1
		end
	end
end
local lastMove = {}
local DT = 1 / 30
local t = 0
while t < T do
	for _, tr in trips do
		if t >= tr.nextAt and w.Drivers.IsPointClear(tr.from, 14) then
			if w:drive(tr.from, tr.to) then tr.spawned += 1 else tr.failed += 1 end
			tr.nextAt = t + (1 / tr.rate) * rng:NextNumber(0.6, 1.4)
		end
	end
	w:step(DT)
	t += DT
	Metrics.tick(m)
	if math.floor(t / DT) % 10 == 0 then
		Metrics.overlaps(m)
		for _, rec in w.cars do
			local st = w:state(rec.model)
			if not st or not st.smoothCFrame then continue end
			local p = st.smoothCFrame.Position
			if not lastMove[rec] or (p - lastMove[rec].p).Magnitude > 0.5 then lastMove[rec] = { p = p, t = t } end
			local e = g:GetEdge(st.edgeId)
			-- on the far carriageway: heading against the near one
			if e and e.roadClass == "highway" and not st.connector and math.sign(e.toDir.X) == -nearDir then
				for _, n in nodes do
					if math.abs(p.X - n.pos.X) < 60 then
						farSamples += 1
						if (st.currentSpeed or 0) < 1 then farStops += 1 end
					end
				end
			end
		end
	end
end
local stuck = 0
for _, rec in w.cars do
	if w:state(rec.model) and lastMove[rec] and t - lastMove[rec].t > 60 then stuck += 1 end
end
local s = Metrics.summary(m)
local tripsTxt = {}
for i, tr in trips do table.insert(tripsTxt, ("%d:%d%s"):format(i, tr.spawned, if tr.failed > 0 then "(!" .. tr.failed .. " no route)" else "")) end
print(("S9 highway junctions [%s %ds seed %d] cars %d arrived %d | far-side stops %d/%d samples | median-crossing turns in graph %d | stuck %d | overlapPairs %d | stalls %d | errors %d | trips %s")
	:format(mode, T, seed, s.cars, s.arrived, farStops, farSamples, medianTurns, stuck, s.overlapPairs, s.stallRescues, s.errors, table.concat(tripsTxt, " ")))
if #w.Studio.errors > 0 then print(w.Studio.errors[1]:sub(1, 600)) end
