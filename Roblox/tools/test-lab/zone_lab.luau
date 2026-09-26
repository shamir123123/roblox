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
local function zoneAll()
	for id, seg in RoadService.getNetwork():getSegments() do
		for _, side in { 1, -1 } do
			PlotService.__place(player, { zone = zoneName, cells = { { seg = id, side = side, t0 = 0, t1 = 1 } }, immediate = true })
			if process.env.PLAN == "1" then
				local n = 0
				for _ in PlotService.getGroups() do n += 1 end
				print("after place seg", id, "side", side, "groups", n)
			end
			for _ = 1, 3 do Studio.step(0.6) end
		end
	end
end
zoneAll()
local waited = 0
for i = 1, 400 do
	Studio.step(0.5)
	waited = i * 0.5
	local sites = Studio.game.Workspace:FindFirstChild("_City"):FindFirstChild("ConstructionSites")
	if i >= 30 and (not sites or #sites:GetChildren() == 0) then break end
	if process.env.SITES == "1" and i % 10 == 0 then
		print("t", i * 0.5, "sites", sites and #sites:GetChildren() or 0)
	end
	if process.env.PLAN == "1" and i % 6 == 0 then
		local zb = Studio.game.Workspace:FindFirstChild("_City"):FindFirstChild("ZonedBuildings")
		print("t", i * 0.5, "models", zb and #zb:GetChildren() or -1)
	end
end

-- == measurements =================================================================
local TC = R("ReplicatedStorage.Terrain.TerrainConstants")
-- The painter surfaces each 4-stud voxel column at the mean of its tile's four corners.
local function paintedY(x: number, z: number): number
	local tx, tz = math.floor(x / 4 + 1024), math.floor(z / 4 + 1024)
	local s = hm:getCorner(tx, tz) + hm:getCorner(tx + 1, tz) + hm:getCorner(tx, tz + 1) + hm:getCorner(tx + 1, tz + 1)
	return TC.rawToWorldY(s / 4) + TC.RENDER_BULGE
end
local folder = Studio.game.Workspace:FindFirstChild("_City"):FindFirstChild("ZonedBuildings")
if process.env.PARTS == "1" then
	local m = folder:GetChildren()[1]
	local list = {}
	for _, p in m:GetDescendants() do
		if p:IsA("BasePart") then table.insert(list, p) end
	end
	table.sort(list, function(a, b) return a.CFrame.Position.Y - a.Size.Y / 2 < b.CFrame.Position.Y - b.Size.Y / 2 end)
	print("MODEL", m.Name, "LotPivot", m:GetAttribute("LotPivot"))
	for i = 1, math.min(12, #list) do
		local p = list[i]
		print(("  %-28s %-10s bottom %.2f top %.2f size %s transp %.2f parent %s"):format(p.Name, p.ClassName, p.CFrame.Position.Y - p.Size.Y / 2,
			p.CFrame.Position.Y + p.Size.Y / 2, tostring(p.Size), p.Transparency, p.Parent.Name))
	end
end
local rows = {}
local groups = PlotService.getGroups()
for _, m in folder:GetChildren() do
	local lot = m:GetAttribute("LotPivot")
	local w, d = m:GetAttribute("FootprintWidth"), m:GetAttribute("FootprintDepth")
	if Studio.typeof(lot) ~= "CFrame" then continue end
	local LOT = 8 -- ZoneGrid.LOT_SIZE (studs)
	local hw, hd = w * LOT * 0.5, d * LOT * 0.5
	-- ground along the lot outline, just inside and just outside it
	local worst, buried, outsideStep = 0, 0, 0
	for i = 0, 24 do
		local f = i / 24 - 0.5
		for _, e in { { f * 2 * hw, -hd }, { f * 2 * hw, hd }, { -hw, f * 2 * hd }, { hw, f * 2 * hd } } do
			local inner = lot * V.new(e[1] * 0.92, 0, e[2] * 0.92)
			local gy = paintedY(inner.X, inner.Z)
			worst = math.max(worst, lot.Position.Y - gy)
			buried = math.max(buried, gy - lot.Position.Y)
		end
	end
	table.insert(rows, { name = m.Name, tmpl = m:GetAttribute("TemplateName"), w = w, d = d, base = lot.Position.Y,
		float = worst, buried = buried, x = lot.Position.X, z = lot.Position.Z })
end
table.sort(rows, function(a, b) return a.x < b.x end)
local floatN, buriedN, fw, bw = 0, 0, 0, 0
for _, r in rows do
	if r.float > 0.5 then floatN += 1 end
	if r.buried > 0.5 then buriedN += 1 end
	fw = math.max(fw, r.float); bw = math.max(bw, r.buried)
end
print(("waited %.1f s for construction"):format(waited))
print(("ZONE %s %s: %d buildings; lot edge above ground >0.5: %d (worst %.2f); ground over lot >0.5: %d (worst %.2f)")
	:format(mode, scene, #rows, floatN, fw, buriedN, bw))
if process.env.ROWS == "1" then
	for _, r in rows do print(("  %-28s %dx%d at %.0f,%.0f lotY %.2f edge-above %.2f ground-over %.2f"):format(r.tmpl or "?", r.w, r.d, r.x, r.z, r.base, r.float, r.buried)) end
end
require("./render/dump")(Studio, Studio.game.Workspace, outFile)
-- terrain heights for the renderer (painted surface per 4-stud tile)
local tiles = {}
for tx = -60, 60 do for tz = -60, 60 do table.insert(tiles, { tx * 4, tz * 4, paintedY(tx * 4 + 2, tz * 4 + 2) }) end end
fs.writeFile(outFile:gsub("%.json$", ".terrain.json"), serde.encode("json", tiles))
for _, e in Studio.errors do print("ERR", e) end
if process.env.WARN == "1" then for _, w in Studio.warnings do if not w:find("model in ServerStorage") then print("WARN", w) end end end
if process.env.DIAG == "1" then
	table.sort(rows, function(a, b) return a.float > b.float end)
	local r = rows[1]
	local m
	for _, c in folder:GetChildren() do if c:GetAttribute("LotPivot") and c:GetAttribute("LotPivot").Position.X == r.x and c:GetAttribute("LotPivot").Position.Z == r.z then m = c end end
	local lot = m:GetAttribute("LotPivot")
	print(("DIAG %s at %.1f,%.1f lotY %.2f w %d d %d look %s"):format(r.tmpl, r.x, r.z, r.base, r.w, r.d, tostring(lot.LookVector)))
	local led = Terrain.getOverlayLedger()
	local hw, hd = r.w * 4, r.d * 4
	for v = -hd - 8, hd + 8, 4 do
		local line = ("v%+4d "):format(v)
		for u = -hw - 8, hw + 8, 4 do
			local p = lot * V.new(u, 0, v)
			line ..= ("%6.2f"):format(paintedY(p.X, p.Z) - r.base)
		end
		print(line)
	end
	-- owners at corners along the lot's centre line (depth)
	for v = -hd - 4, hd + 4, 4 do
		local p = lot * V.new(0, 0, v)
		local gx, gz = math.floor(p.X / 4 + 1024 + 0.5), math.floor(p.Z / 4 + 1024 + 0.5)
		local e = led._corners[gz * TC.CORNERS_PER_AXIS + gx]
		local s = ("  corner v%+d (%d,%d) Y %.2f:"):format(v, gx, gz, TC.rawToWorldY(hm:getCorner(gx, gz)) + TC.RENDER_BULGE - r.base)
		if e then
			s ..= (" nat %.2f"):format(TC.rawToWorldY(e.origRaw) + TC.RENDER_BULGE - r.base)
			for o, raw in e.targets do s ..= (" %s=%.2f/%d"):format(o, TC.rawToWorldY(raw) + TC.RENDER_BULGE - r.base, e.flags[o]) end
		end
		print(s)
	end
end
if process.env.DIAG == "1" then
	local r = rows[1]
	local led = Terrain.getOverlayLedger()
	for _, wz in { -23, -27, -31 } do
		for wx = r.x - 20, r.x + 20, 4 do
			local gx, gz = math.floor(wx / 4 + 1024 + 0.5), math.floor(wz / 4 + 1024 + 0.5)
			local e = led._corners[gz * TC.CORNERS_PER_AXIS + gx]
			local s = ("  row z%d x%d (%d,%d) Y %.2f:"):format(wz, wx, gx, gz, TC.rawToWorldY(hm:getCorner(gx, gz)) + TC.RENDER_BULGE - r.base)
			if e then
				s ..= (" nat %.2f"):format(TC.rawToWorldY(e.origRaw) + TC.RENDER_BULGE - r.base)
				for o, raw in e.targets do s ..= (" %s=%.2f/%d"):format(o, TC.rawToWorldY(raw) + TC.RENDER_BULGE - r.base, e.flags[o]) end
			end
			print(s)
		end
	end
	for _, c in folder:GetChildren() do
		local lp = c:GetAttribute("LotPivot")
		if lp and math.abs(lp.Position.X - r.x) < 60 then print("  lot", c:GetAttribute("BlueprintId"), lp.Position, c:GetAttribute("FootprintWidth"), c:GetAttribute("FootprintDepth")) end
	end
end
