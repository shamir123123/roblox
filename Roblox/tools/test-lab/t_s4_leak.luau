-- Scenario 4: leak check. Thousands of trips come and go; some cars are destroyed mid-trip
-- (a household leaving). Afterwards every per-car table must be empty again.
local World = require("./shim/traffic")
local process = require("@lune/process")
local mode = process.args[1] or "patched"
local TRIPS = tonumber(process.args[2]) or 1500
local w = World.new(mode)
local V = w.V
local N, S = 3, 200
for i = 0, N - 1 do
	for j = 0, N - 1 do
		local p = V.new(i * S, 0, j * S)
		if i < N - 1 then w:road(p, V.new((i + 1) * S, 0, j * S), "CollectorRoad") end
		if j < N - 1 then w:road(p, V.new(i * S, 0, (j + 1) * S), "CollectorRoad") end
	end
end
w:build(false)
w:camera(V.new(200, 0, 200))
local rng = w.Studio.Random.new(7)
local function randomRoadPoint()
	local i, j = rng:NextInteger(0, N - 1), rng:NextInteger(0, N - 2)
	local along = rng:NextNumber(0.25, 0.75) * S
	if rng:NextNumber() < 0.5 then return V.new(i * S, 0, j * S + along) end
	return V.new(j * S + along, 0, i * S)
end
local function count(t) local n = 0 for _ in t do n += 1 end return n end
local function nested(t) local n = 0 for _, c in t do for _, b in c do n += count(b) end end return n end
local function gc() for _ = 1, 6 do local junk = {} for i = 1, 300000 do junk[i] = { i } end end end
gc()
local mem0 = collectgarbage("count")
local done, killed, t = 0, 0, 0
local live = {}
while done + killed < TRIPS or next(live) do
	if done + killed + count(live) < TRIPS and count(live) < 60 then
		local a, b = randomRoadPoint(), randomRoadPoint()
		if (a - b).Magnitude > 150 and w.Drivers.IsPointClear(a, 14) then
			local rec = w:drive(a, b)
			if rec then
				table.remove(w.cars) -- the harness must not keep the car alive
				live[rec] = true
				rec.killAt = if rng:NextNumber() < 0.15 then t + rng:NextNumber(2, 15) else nil
			end
		end
	end
	w:step(1 / 20)
	t += 1 / 20
	for rec in live do
		if rec.arrived or rec.aborted then
			live[rec] = nil; done += 1
			rec.model:Destroy()   -- parked car later removed with its household
		elseif rec.killAt and t >= rec.killAt then
			live[rec] = nil; killed += 1
			rec.model:Destroy()   -- household leaves mid-trip
		end
	end
	if t > 3000 then print("TIMEOUT with", count(live), "live") break end
end
-- let the service notice destroyed models, prune timers run (PathFollower prunes every 30 s)
for _ = 1, 40 * 20 do w:step(1 / 20) end
table.clear(live)
gc(); gc()
local D, P = w.Drivers.__test, w.PathFollower.__test
local g = w.graph
print(("S4 leak [%s]: %d trips (%d arrived, %d destroyed mid-trip) in %.0f game-s"):format(mode, done + killed, done, killed, t))
print(("   drivers %d | edgeIndex %d laneChangeIndex %d connIndex %d"):format(count(D.drivers), count(D.edgeIndex), count(D.laneChangeIndex), count(D.connIndex)))
print(("   PathFollower: registry %d spatial %d poseOf %d movedAt %d npcIds %d modelOfId %d inRange %d prox %d carHalf %d lastSentTo[player] %d")
	:format(count(P.registry), nested(P.spatial), count(P.poseOf), count(P.movedAt), count(P.npcIds), count(P.modelOfId),
		count(P.inRange), count(P.prox), count(P.carHalf), (function() local n = 0 for _, s in P.lastSentTo do n += count(s) end return n end)()))
print(("   graph bookings: routes %d, edges booked %d"):format(count(g._bookingRoutes), count(g._edgeBookingCount)))
print(("   Lua memory %.0f KB -> %.0f KB (%+.0f KB)"):format(mem0, collectgarbage("count"), collectgarbage("count") - mem0))
print(("   errors %d, stall warnings %d"):format(#w.Studio.errors, (function() local n = 0 for _, x in w.Studio.warnings do if x:find("stalled") then n += 1 end end return n end)()))
for i = 1, math.min(3, #w.Studio.errors) do print("   ERR", w.Studio.errors[i]:sub(1, 300)) end
