-- Traffic sign plan on a few real junction shapes (placed through RoadService, so the same
-- network the game builds). Checks which signs each junction gets, that every sign stands off
-- the carriageway, and that it faces the traffic it is for.
-- usage: lune run t_signs.luau
local Studio = require("./shim/setup")("cur")
local V = Studio.Vector3
local Vector3 = V
local R = function(p) return Studio.require(Studio.find(p)) end
local Terrain = R("ServerScriptService.Services.Terrain.TerrainDataService")
Terrain.Init()
local RoadService = R("ServerScriptService.Services.Road.RoadService")
RoadService.Init()
RoadService.setUnlockCheck(function() return true end)
RoadService.Bind()
RoadService.Start()
local RoadRules = R("ReplicatedStorage.Road.RoadRules")
local RoadTypeCatalog = R("ReplicatedStorage.Road.RoadTypeCatalog")
local BezierUtil = R("ReplicatedStorage.Road.BezierUtil")
local Planner = R("ReplicatedStorage.Road.TrafficSignPlanner")
Studio.step(0.2)

local function road(a, b, t)
	local d = b - a
	local ok, err = RoadService.placeFromRequest({ p0 = a, p1 = a + d / 3, p2 = a + d * 2 / 3, p3 = b, roadType = t })
	if not ok then print("  (placement refused: " .. t .. " " .. tostring(err) .. ")") end
	Studio.step(0.3)
	return ok
end
local failures = 0
local function check(what, ok, detail)
	if not ok then failures += 1 end
	print((if ok then "PASS " else "FAIL ") .. what .. (if detail then ": " .. detail else ""))
end

-- A: avenue, a one-way arriving from the south      B: avenue crossing avenue (lights)
-- C: two small streets crossing                     D: a one-way leaving the avenue north
-- E: a street running on into a highway
road(V.new(-300, 0, 0), V.new(300, 0, 0), "CollectorRoad")
road(V.new(0, 0, 240), V.new(0, 0, 0), "OneWay")
road(V.new(-300, 0, 600), V.new(300, 0, 600), "CollectorRoad")
road(V.new(0, 0, 360), V.new(0, 0, 840), "CollectorRoad")
road(V.new(700, 0, -300), V.new(700, 0, 300), "NarrowRoad")
road(V.new(400, 0, 0), V.new(1000, 0, 0), "NarrowRoad")
road(V.new(1400, 0, 0), V.new(2000, 0, 0), "CollectorRoad")
road(V.new(1700, 0, 0), V.new(1700, 0, -240), "OneWay")
road(V.new(2600, 0, 0), V.new(3000, 0, 0), "NarrowRoad")
road(V.new(3000, 0, 0), V.new(3800, 0, 0), "Highway3W")
road(V.new(3000, 0, 0), V.new(3000, 0, 300), "NarrowRoad")
for _ = 1, 30 do Studio.step(0.1) end

local net = RoadService.getNetwork()
local segs = net:getSegments()
local nodes = net:getNodes()
local function nodeNear(x, z): number?
	for id, n in nodes do
		if math.abs(n.position.X - x) < 2 and math.abs(n.position.Z - z) < 2 then return id end
	end
	return nil
end
local function run(system: string)
	local opts = {
		signSystem = system, speedUnit = if system == "mutcd" then "mph" else "kmh",
		laneSideSign = RoadRules.getLaneSideSign(),
		isSignalised = function(id) return RoadRules.nodeControl(net, id) == "signal" end,
	}
	local list = {}
	for _, s in segs do table.insert(list, s) end
	return Planner.plan(list, function(id) local n = nodes[id]; return n and n.position end, opts)
end

local function kinds(signs, nodeId): { [string]: number }
	local out = {}
	for _, s in signs do
		if s.nodeId == nodeId then out[s.kind] = (out[s.kind] or 0) + 1 end
	end
	return out
end
local function fmt(k)
	local parts = {}
	for kind, n in k do table.insert(parts, kind .. "x" .. n) end
	table.sort(parts)
	return table.concat(parts, " ")
end

local us = run("mutcd")
local eu = run("vienna")
print(("%d signs (USA), %d signs (Europe)"):format(#us, #eu))

local A, B, C, D, E = nodeNear(0, 0), nodeNear(0, 600), nodeNear(700, 0), nodeNear(1700, 0), nodeNear(3000, 0)
local kA, kB, kC, kD, kE = kinds(us, A), kinds(us, B), kinds(us, C), kinds(us, D), kinds(us, E)
print("A " .. fmt(kA)); print("B " .. fmt(kB)); print("C " .. fmt(kC)); print("D " .. fmt(kD)); print("E " .. fmt(kE))
check("A: the one-way stops for the avenue", kA.stop == 1, fmt(kA))
check("A: do-not-enter at the one-way's end", kA.noentry == 1)
check("A: no stop on the avenue itself", (kA.allway or 0) == 0)
check("B: lights, so no stop signs", (kB.stop or 0) + (kB.allway or 0) == 0, fmt(kB))
check("B: same limit on short blocks, no speed signs", (kB.speed or 0) == 0, fmt(kB))
check("C: all-way stop, 4 arms (USA)", kC.allway == 4, fmt(kC))
check("D: one-way signs (both corners) where it leaves", kD.oneway == 2, fmt(kD))
check("D: no do-not-enter where it starts", (kD.noentry or 0) == 0)
check("E: highway entrance sign", (kE.highway or 0) == 1, fmt(kE))
local highwaySpeed = false
for _, s in us do
	if s.nodeId == E and s.kind == "speed" and s.pos.X > 3000 then highwaySpeed = true end
end
check("E: speed sign onto the highway", highwaySpeed)
local euA, euC = kinds(eu, A), kinds(eu, C)
check("Europe A: give way, not stop", euA.yield == 1 and (euA.stop or 0) == 0, fmt(euA))
check("Europe C: equal streets carry no sign", (euC.allway or 0) + (euC.stop or 0) + (euC.yield or 0) == 0, fmt(euC))

-- Every sign off every carriageway, and facing its traffic.
local onRoad, badFace, dupKeys = 0, 0, 0
local seen = {}
for _, s in us do
	if seen[s.key] then dupKeys += 1 end
	seen[s.key] = true
	for _, seg in segs do
		local spec = RoadTypeCatalog.getOrDefault(seg.roadType)
		for i = 0, 40 do
			local p = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, i / 40)
			local d = Vector3.new(p.X - s.pos.X, 0, p.Z - s.pos.Z).Magnitude
			if d < spec.width * 0.5 - 0.5 then
				onRoad += 1
				print(("  on the road: %s at (%.0f, %.0f) inside %s"):format(s.key, s.pos.X, s.pos.Z, seg.roadType))
				break
			end
		end
	end
	local n = nodes[s.nodeId]
	if n and (s.kind == "stop" or s.kind == "allway" or s.kind == "yield" or s.kind == "speed" or s.kind == "highway") then
		-- these face traffic coming TOWARD the node (stop) or leaving it (speed/highway): the face
		-- points at the viewer, who is on the node side for speed/highway and far side for stop
		local away = Vector3.new(s.pos.X - n.position.X, 0, s.pos.Z - n.position.Z).Unit
		local dot = away:Dot(s.face)
		local want = if s.kind == "stop" or s.kind == "allway" or s.kind == "yield" then 1 else -1
		if dot * want < 0.5 then
			badFace += 1
			print(("  facing wrong: %s dot %.2f"):format(s.key, dot))
		end
	end
end
check("no sign on a carriageway", onRoad == 0, tostring(onRoad))
check("every sign faces its traffic", badFace == 0, tostring(badFace))
check("sign keys unique", dupKeys == 0, tostring(dupKeys))
print(if failures == 0 then "ALL PASS" else failures .. " FAILED")
if #Studio.errors > 0 then print(Studio.errors[1]:sub(1, 600)) end
