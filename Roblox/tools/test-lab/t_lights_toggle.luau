-- The Traffic Light card, server side: a one-way street joining an avenue gets no lights by
-- default; a click puts them up, the choice survives a save + load, and a second click takes
-- them down again. Also checks the automatic rule on a few junction shapes.
-- usage: lune run t_lights_toggle.luau
local Studio = require("./shim/setup")("cur")
local V = Studio.Vector3
local Vector3 = V
local R = function(p) return Studio.require(Studio.find(p)) end
local Terrain = R("ServerScriptService.Services.Terrain.TerrainDataService")
Terrain.Init()
local hm = Terrain.getHeightmap()
for gx = 900, 1150 do for gz = 900, 1150 do hm:setCorner(gx, gz, 256 + 40) end end
local RoadService = R("ServerScriptService.Services.Road.RoadService")
RoadService.Init()
RoadService.setUnlockCheck(function() return true end)
RoadService.Bind()
RoadService.Start()
local Signals = R("ServerScriptService.Services.Traffic.TrafficSignalService")
local Replication = R("ServerScriptService.Services.Traffic.SignalReplicationService")
local Store = R("ServerScriptService.Services.Traffic.SignalPlanStore")
local RoadRules = R("ReplicatedStorage.Road.RoadRules")
Signals.Init(RoadService)
Replication.Init(Signals, RoadService)
Signals.Bind()
Replication.Bind()
Signals.Start()
Studio.step(0.2)

local function road(a, b, t)
	local d = b - a
	local ok, err = RoadService.placeFromRequest({ p0 = a, p1 = a + d / 3, p2 = a + d * 2 / 3, p3 = b, roadType = t })
	assert(ok, tostring(err))
	Studio.step(0.3)
end
local function settle() for _ = 1, 30 do Studio.step(0.1) end end
local function junctionAt(pos)
	local net = RoadService.getNetwork()
	for id, node in net:getNodes() do
		if #node.segments >= 3 and Vector3.new(node.position.X - pos.X, 0, node.position.Z - pos.Z).Magnitude < 2 then return id end
	end
	return nil
end
local failures = 0
local function check(what, got, want)
	local ok = got == want
	if not ok then failures += 1 end
	print((if ok then "PASS " else "FAIL ") .. what .. ": " .. tostring(got) .. (if ok then "" else " (want " .. tostring(want) .. ")"))
end

-- A: avenue through, one-way joining from the south
road(V.new(-300, 0, 0), V.new(300, 0, 0), "CollectorRoad")
road(V.new(0, 0, 240), V.new(0, 0, 0), "OneWay")
-- B: avenue crossing avenue
road(V.new(-300, 0, 600), V.new(300, 0, 600), "CollectorRoad")
road(V.new(0, 0, 360), V.new(0, 0, 840), "CollectorRoad")
-- C: two small streets crossing
road(V.new(700, 0, -300), V.new(700, 0, 300), "NarrowRoad")
road(V.new(400, 0, 0), V.new(1000, 0, 0), "NarrowRoad")
settle()
local net = RoadService.getNetwork()
local a, b, c = junctionAt(V.new(0, 0, 0)), junctionAt(V.new(0, 0, 600)), junctionAt(V.new(700, 0, 0))
check("A one-way joins avenue: control", RoadRules.nodeControl(net, a), "priority")
check("B avenue crosses avenue: control", RoadRules.nodeControl(net, b), "signal")
check("C two small streets: control", RoadRules.nodeControl(net, c), "priority")
check("A has lights before any click", Signals.HasSignal(a), false)
check("B has lights", Signals.HasSignal(b), true)

local player = Studio.addPlayer("Mayor", 1)
Studio.game.Workspace:SetAttribute("RoadEditOpen", true)
local Net = R("ReplicatedStorage.Networker")
local function click(pos)
	Net.RequestToggleJunctionLights.OnServerEvent:Fire(player, pos)
	for _ = 1, 20 do Studio.step(0.1) end
end

click(V.new(6, 0, -4))
check("A after one click: lights", Signals.HasSignal(a), true)
check("A stored control", Store.rawPlan(a) and Store.rawPlan(a).control, "signal")

-- save, wipe, load
local blob = Store.serialize()
Store.restore(nil)
settle()
check("A after wiping the store: lights", Signals.HasSignal(a), false)
Store.restore(blob)
settle()
check("A after save + load: lights", Signals.HasSignal(a), true)

click(V.new(-5, 0, 3))
check("A after a second click: lights", Signals.HasSignal(a), false)
check("A back on auto (no plan kept)", Store.rawPlan(a) == nil, true)

click(V.new(2, 0, 598))
check("B after a click: lights", Signals.HasSignal(b), false)
check("B stored control", Store.rawPlan(b) and Store.rawPlan(b).control, "priority")
click(V.new(900, 0, 900))
check("a click away from any junction changes nothing", Signals.HasSignal(b), false)

for _, e in Studio.errors do print("ERR", e:sub(1, 400)) end
print(if failures == 0 and #Studio.errors == 0 then "ALL PASS" else ("FAILURES " .. failures .. ", errors " .. #Studio.errors))
