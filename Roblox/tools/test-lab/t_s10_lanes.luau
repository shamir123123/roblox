-- Scenario 10: lane discipline on a 3-lane one-way highway, 4000 studs. Drivers have their own
-- speeds (DriverProfile), so faster ones catch slower ones. Cars enter in random lanes and
-- leave from the kerbside lane at the far end (an exit is taken from the right).
-- Measures time share per lane (1 = the lane against the median, the passing lane),
-- discretionary moves by kind (yield = moved over for a faster car behind, pass = overtook a
-- car that could not move over, back = returned to its cruising lane), how often a faster
-- car sits stuck behind a slower one in the same lane ("held up"), lane changes that braked,
-- overlaps, arrivals.
-- usage: lune run t_s10_lanes.luau <mode> <seconds> <seed>
local World = require("./shim/traffic")
local Metrics = require("./shim/metrics")
local process = require("@lune/process")
local mode = process.args[1] or "cur"
local T = tonumber(process.args[2]) or 240
local seed = tonumber(process.args[3]) or 1
local w = World.new(mode)
local V = w.V
local N = 20
for i = 0, N - 1 do w:road(V.new(0, 0, i * 200), V.new(0, 0, (i + 1) * 200), "Highway3W") end
w:build()
w:camera(V.new(0, 0, 2000))
local m = Metrics.new(w)
local rng = w.Studio.Random.new(seed)
math.randomseed(seed)
local g = w.graph
local first = g:GetEdges()[1].segmentId
local lanes: { { x: number, ord: number } } = {}
for _, e in g:GetEdges() do
	if e.segmentId == first then table.insert(lanes, { x = e.points[1].X, ord = e.laneOrdinal }) end
end
local kerbX = lanes[1].x
for _, l in lanes do if l.ord == #lanes then kerbX = l.x end end

local occupancy = { 0, 0, 0 }
local heldUp, samples = 0, 0
local D = w.Drivers.__test
local t, nextSpawn, spawned = 0, 0, 0
local DT = 1 / 30
while t < T do
	if t >= nextSpawn and spawned < 400 then
		local x0 = lanes[rng:NextInteger(1, #lanes)].x
		if w.Drivers.IsPointClear(V.new(x0, 0, 3), 14) then
			w:drive(V.new(x0, 0, 3), V.new(kerbX, 0, N * 200 - 5))
			spawned += 1
		end
		nextSpawn = t + rng:NextNumber(0.5, 1.3)
	end
	w:step(DT)
	t += DT
	Metrics.tick(m)
	if math.floor(t / DT) % 6 == 0 then
		Metrics.overlaps(m)
		for _, rec in w.cars do
			local st = w:state(rec.model)
			if st and not st.connector then
				local e = g:GetEdge(st.edgeId)
				-- the middle of the road only: the first and last 400 studs are entry and exit
				if e and st.smoothCFrame and st.smoothCFrame.Position.Z > 400 and st.smoothCFrame.Position.Z < N * 200 - 400 then
					occupancy[e.laneOrdinal] += 1
					samples += 1
					local lead, gap = D.queueLeader(st)
					if lead and gap and gap < 35 and st.profile and lead.profile
						and lead.profile.speedFactor < st.profile.speedFactor * 0.95
						and (st.currentSpeed or 0) < (lead.currentSpeed or 0) + 1 then
						heldUp += 1
					end
				end
			end
		end
	end
end
local total = occupancy[1] + occupancy[2] + occupancy[3]
local moves = 0
local kinds = {}
for _, rec in w.cars do
	local st = w:state(rec.model)
	if st then
		moves += st.laneDisciplineMoves or 0
		for k, n in st.laneMoveKinds or {} do kinds[k] = (kinds[k] or 0) + n end
	end
end
-- cars that arrived are gone from the driver table; the service keeps no history, so the
-- kind counts cover the cars still driving at the end (a sample, not the total)
local kindText = ("yield %d pass %d back %d"):format(kinds.yield or 0, kinds.pass or 0, kinds.back or 0)
local s = Metrics.summary(m)
print(("S10 lanes [%s %ds seed %d] cars %d arrived %d | lane share (1=passing) %.0f%% / %.0f%% / %.0f%% | held up %.1f%% | moves (live cars) %s | lane changes %d, braked %d | overlapPairs %d | stalls %d | errors %d")
	:format(mode, T, seed, s.cars, s.arrived, occupancy[1] / total * 100, occupancy[2] / total * 100, occupancy[3] / total * 100,
		heldUp / math.max(samples, 1) * 100, kindText, s.laneChanges, s.brakedLaneChanges, s.overlapPairs, s.stallRescues, s.errors))
if #w.Studio.errors > 0 then print(w.Studio.errors[1]:sub(1, 600)) end
