-- Zoning lab: the real RoadService + PlotService + BuildingService + TerrainPad + LotDressing
-- with the place's building templates. Zones a street, then measures how each building sits
-- on the ground and how far it stands from the road.
-- lune run zone_lab <mode> <scene> <out.json> [zone]
local process = require("@lune/process")
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local mode = process.args[1] or "orig"
local scene = process.args[2] or "street"
local outFile = process.args[3] or "render/zone.json"
local zoneName = process.args[4] or "Residential"
local D = (process.env.CITY_LAB_DATA or "/tmp/claude-0/-home-user-unity-project/18389c77-9136-5827-8847-96d9472304f9/scratchpad")
local Studio = require("./shim/setup")(mode)
Studio.echo = process.env.ECHO == "1"
local V = Studio.Vector3
local R = function(p) return Studio.require(Studio.find(p)) end
local mount = require("./shim/models")(Studio)
local ss = Studio.game.ServerStorage
local templates = ss:FindFirstChild("Templates") or Studio.Instance.new("Folder")
templates.Name = "Templates"; templates.Parent = ss
mount(D .. "/dump/ServerStorage/Templates", templates)
mount(D .. "/dump/ReplicatedStorage/Nature", Studio.game.ReplicatedStorage:FindFirstChild("Nature"))

local Terrain = R("ServerScriptService.Services.Terrain.TerrainDataService")
Terrain.Init()
local hm = Terrain.getHeightmap()
local hilly = scene:find("hill") ~= nil
for gx = 924, 1124 do
	for gz = 924, 1124 do
		local x, z = (gx - 1024) * 4, (gz - 1024) * 4
		-- flat land 10 studs up, or a slope rising 1 in 8 across the street (+ a gentle bump)
		local y = 10 + (if hilly then z / 8 + 3 * math.sin(x / 37) else 0)
		hm:setCorner(gx, gz, math.clamp(math.floor(256 + y * 4 + 0.5), 0, 65535))
	end
end
Studio.game.Workspace:SetAttribute("RoadEditOpen", true)
local Net = R("ReplicatedStorage.Networker")
local RoadService = R("ServerScriptService.Services.Road.RoadService")
RoadService.Init(); RoadService.setUnlockCheck(function() return true end); RoadService.Bind(); RoadService.Start()
Studio.expose("ServerScriptService.Services.City.PlotService", "PlotService.__place = place")
local LotDressing = R("ServerScriptService.Services.City.LotDressingService")
local BuildingService = R("ServerScriptService.Services.City.BuildingService")
local PlotService = R("ServerScriptService.Services.City.PlotService")
LotDressing.Init()
BuildingService.Init(nil, LotDressing)
PlotService.Init(RoadService, Net, BuildingService)
PlotService.Bind(); BuildingService.Bind(); LotDressing.Bind()
PlotService.Start(); BuildingService.Start()
Studio.step(0.1)

local function road(a, b, t)
	local d = b - a
	local ok, err = RoadService.placeFromRequest({ p0 = a, p1 = a + d / 3, p2 = a + d * 2 / 3, p3 = b, roadType = t or "NarrowRoad" })
	if not ok then print("road", ok, err) end
	for _ = 1, 3 do Studio.step(0.1) end
end
if scene == "street" or scene == "streethill" then
	road(V.new(-200, 0, 0), V.new(200, 0, 0))
elseif scene == "corner" or scene == "cornerhill" then
	road(V.new(-200, 0, 0), V.new(0, 0, 0))
	road(V.new(0, 0, 0), V.new(0, 0, 200))
end
do
	local segs = RoadService.getNetwork():getSegments()
	for id, sg in segs do print("SEG", id, sg.p0.Y, sg.p3.Y, "surface@p0", Terrain.getSurfaceY(sg.p0.X, sg.p0.Z)) break end
	print("surface(0,0) before zoning", Terrain.getSurfaceY(0, 30), Terrain.getHeightAt(0, 30))
end
if process.env.PLAN == "1" then
	local PG = R("ReplicatedStorage.City.PlotGeometry")
	local PF = R("ReplicatedStorage.Shared.PlacementFit")
	local idx = PG.buildRoadIndex(RoadService.getNetwork():getSegments(), PF.seatOccupied)
	for id, seg in RoadService.getNetwork():getSegments() do
		local pls = PG.planSpan(idx, seg, 1, 0, 1, 40, 24, false)
		local blocked = 0
		for _, pl in pls do if pl.blocked then blocked += 1 end end
		print("PLAN seg", id, "placements", #pls, "blocked", blocked)
		if pls[1] then
			local pl = pls[1]
			print("  first corners", pl.corners[1], pl.corners[3], "onRoad", PG.rectOnRoad and PG.rectOnRoad(idx, pl.corners, id), "occupied", PF.seatOccupied and PF.seatOccupied(pl.corners))
		end
	end
end
local player = Studio.addPlayer("Zoner", 7)
local led = Terrain.getOverlayLedger()
local function snap()
	local t = {}
	for gx = 940, 1110 do for gz = 940, 1110 do t[gz * 4096 + gx] = hm:getCorner(gx, gz) end end
	return t
end
local function diff(a, b)
	local n, worst = 0, 0
	for k, v in a do
		local d = math.abs(v - b[k])
		if d > 0 then n += 1; worst = math.max(worst, d) end
	end
	return n, worst
end
local function padOwners()
	local n = 0
	for o in led._owners do if o:sub(1, 4) == "pad:" then n += 1 end end
	return n
end
local before = snap()
for id, seg in RoadService.getNetwork():getSegments() do
	for _, side in { 1, -1 } do
		PlotService.__place(player, { zone = "Residential", cells = { { seg = id, side = side, t0 = 0, t1 = 1 } }, immediate = true })
		for _ = 1, 3 do Studio.step(0.6) end
	end
end
for _ = 1, 120 do Studio.step(0.5) end
local zb = Studio.game.Workspace:FindFirstChild("_City"):FindFirstChild("ZonedBuildings")
print("buildings", #zb:GetChildren(), "pad owners", padOwners())
-- bulldoze every other house first (neighbours must redo their fills), then the rest
local ids = {}
for _, m in zb:GetChildren() do table.insert(ids, m:GetAttribute("BlueprintId")) end
table.sort(ids)
for i, id in ids do if i % 2 == 0 then BuildingService.demolish(id) end end
Studio.step(0.5)
print("after half demolished: pad owners", padOwners())
for i, id in ids do if i % 2 == 1 then BuildingService.demolish(id) end end
Studio.step(0.5)
local n, worst = diff(before, snap())
print(("all demolished: pad owners %d, corners changed vs before zoning %d (worst %d raw)"):format(padOwners(), n, worst))
-- a site cancelled in the middle of its earthworks
local segId
for id in RoadService.getNetwork():getSegments() do segId = id break end
PlotService.__place(player, { zone = "Residential", cells = { { seg = segId, side = 1, t0 = 0, t1 = 1 } }, immediate = true })
Studio.step(0.3)
Studio.step(1.0)
local sites = Studio.game.Workspace:FindFirstChild("_City"):FindFirstChild("ConstructionSites")
local cancelIds = {}
for _, m in sites:GetChildren() do table.insert(cancelIds, m:GetAttribute("BlueprintId")) end
print("sites mid-earthworks", #cancelIds, "pad owners", padOwners())
for _, id in cancelIds do BuildingService.demolish(id) end
for _ = 1, 10 do Studio.step(0.5) end
n, worst = diff(before, snap())
print(("after cancelling mid-earthworks: sites %d, pad owners %d, corners changed %d (worst %d)"):format(#sites:GetChildren(), padOwners(), n, worst))
for _, e in Studio.errors do print("ERR", e) end
