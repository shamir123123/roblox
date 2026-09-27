-- Render lab: the real RoadService + RoadSceneRenderer under the Studio stand-in. Builds a
-- scene, then dumps every part for render/top.py.
-- lune run render_lab <mode> <scene> <out.json>
local process = require("@lune/process")
local mode = process.args[1] or "orig"
local scene = process.args[2] or "roundabout"
local outFile = process.args[3] or "render/out.json"
local Studio = require("./shim/setup")(mode)
Studio.echo = process.args[4] == "echo"
local V = Studio.Vector3
local R = function(p) return Studio.require(Studio.find(p)) end
local Terrain = R("ServerScriptService.Services.Terrain.TerrainDataService")
Terrain.Init()
-- Flat ground unless the scene asks for relief (heightmap stays at its default otherwise).
if scene:find("hilly") then
	Terrain.generateNewCity({ seed = 7, heightRange = 1, ruggedness = 0.5 })
else
	-- flat dry land 10 studs above the sea (raw 0 is ocean floor: everything would be "water")
	local hm = Terrain.getHeightmap()
	for gx = 924, 1124 do for gz = 924, 1124 do hm:setCorner(gx, gz, 256 + 40) end end
end
local RoadService = R("ServerScriptService.Services.Road.RoadService")
RoadService.Init()
RoadService.setUnlockCheck(function() return true end)
RoadService.Bind()
RoadService.Start()
Studio.step(0.1)

local function road(a, b, t)
	local d = b - a
	local ok, err = RoadService.placeFromRequest({ p0 = a, p1 = a + d / 3, p2 = a + d * 2 / 3, p3 = b, roadType = t or "NarrowRoad" })
	print("road", ok, err)
	Studio.step(0.2)
end

if scene == "roundabout" or scene == "roundabout1" or scene == "roundabout3" then
	road(V.new(-260, 0, 0), V.new(260, 0, 0))
	road(V.new(0, 0, -260), V.new(0, 0, 260))
	local rt = if scene == "roundabout1" then "Roundabout1" elseif scene == "roundabout3" then "Roundabout3" else "Roundabout"
	local RC = R("ReplicatedStorage.Road.RoadConstants")
	local radius = if scene == "roundabout1" then RC.ROUNDABOUT_RADIUS_SMALL elseif scene == "roundabout3" then RC.ROUNDABOUT_RADIUS_LARGE else RC.ROUNDABOUT_RADIUS_MEDIUM
	require("./render/nature")(Studio, { "OakTree", "FlowerBush", "FlowerBushPink", "FlowerBushYellow", "CherryTree", "HedgeSphere", "CoconutPalm", "FloridaPalm", "BushRound" })
	local ok, err = RoadService.placeRoundaboutFromRequest({ center = V.new(0, 0, 0), radius = radius, roadType = rt, preset = process.args[7] })
	print("roundabout", ok, err)
	-- optional node-tool shaping of every arm at a ring node: args 5 = offset, 6 = corner
	local off, cor = tonumber(process.args[5]), tonumber(process.args[6])
	if off or cor then
		for _ = 1, 10 do Studio.step(0.1) end
		local net = RoadService.getNetwork()
		for nid, node in net:getNodes() do
			if net:isRoundaboutNode(nid) then
				for _, sid in node.segments do
					local sg = net:getSegment(sid)
					if sg and not sg.isRoundabout then
						print("shape", nid, sid, RoadService.shapeJunction({ node = nid, seg = sid, offset = off, corner = cor }))
					end
				end
			end
		end
		RoadService.rebuildNavigationGraph()
	end
elseif scene == "mixed" or scene == "mixedhilly" then
	-- a 4-lane arm, a two-lane arm, a diagonal one-way arm, and no arm to the east
	road(V.new(-260, 0, 0), V.new(0, 0, 0))
	road(V.new(0, 0, -260), V.new(0, 0, 0), "CollectorRoad")
	road(V.new(0, 0, 260), V.new(0, 0, 0))
	road(V.new(180, 0, 180), V.new(0, 0, 0), "OneWay2Lane")
	local RC = R("ReplicatedStorage.Road.RoadConstants")
	require("./render/nature")(Studio, { "OakTree", "FlowerBush", "FlowerBushPink", "FlowerBushYellow", "CherryTree", "HedgeSphere", "CoconutPalm", "FloridaPalm", "BushRound" })
	print("roundabout", RoadService.placeRoundaboutFromRequest({ center = V.new(0, 0, 0), radius = RC.ROUNDABOUT_RADIUS_MEDIUM, roadType = "Roundabout", preset = "Garden" }))
elseif scene == "hwyT" then
	-- a street ending at a divided highway from one side
	road(V.new(-400, 0, 0), V.new(0, 0, 0), "Highway4")
	road(V.new(0, 0, 0), V.new(400, 0, 0), "Highway4")
	road(V.new(0, 0, 260), V.new(0, 0, 0), "CollectorRoad")
elseif scene == "hwycross" then
	-- a street drawn right across a divided highway
	road(V.new(-400, 0, 0), V.new(400, 0, 0), "Highway4")
	road(V.new(0, 0, 260), V.new(0, 0, -260), "CollectorRoad")
elseif scene == "hwyramp" then
	-- a divided highway with a shallow on-ramp joining it from one side
	road(V.new(-400, 0, 0), V.new(400, 0, 0), "Highway4")
	-- as the ramp tool lands it: end tangent 32 degrees off the carriageway it merges into
	local RR = R("ReplicatedStorage.Road.RoadRules")
	local hd = V.new(1, 0, 0)
	if hd:Cross(V.new(0, 1, 0)).Z * RR.getLaneSideSign() < 0 then hd = -hd end -- the ramp comes from +Z
	local a = math.rad(32)
	local endDir = (hd * math.cos(a) + V.new(0, 0, -1) * math.sin(a)).Unit
	local p3 = V.new(0, 0, 0)
	local p0 = p3 - hd * 260 + V.new(0, 0, 110)
	local ok, err = RoadService.placeFromRequest({ p0 = p0, p1 = p0 + hd * 90, p2 = p3 - endDir * 64, p3 = p3, roadType = "Highway1W" })
	print("ramp", ok, err)
	Studio.step(0.2)
elseif scene == "signs" then
	-- an avenue with a one-way arriving (A) and one leaving (D), small streets crossing (C)
	road(V.new(-300, 0, 0), V.new(300, 0, 0), "CollectorRoad")
	road(V.new(-120, 0, 200), V.new(-120, 0, 0), "OneWay")
	road(V.new(120, 0, 0), V.new(120, 0, -200), "OneWay")
	road(V.new(120, 0, 200), V.new(120, 0, 0), "NarrowRoad")
	road(V.new(-300, 0, -160), V.new(300, 0, -160), "NarrowRoad")
elseif scene == "walls" then
	-- retaining walls: a road raised one step (+4, below bridge height) with a street joining
	-- it, a tunnel ramping down from the ground, and a road lowered one step (-4)
	local TDS = R("ServerScriptService.Services.Terrain.TerrainDataService")
	local RC = R("ReplicatedStorage.Road.RoadConstants")
	local function centreY(x, z) return TDS.getSurfaceY(x, z) + RC.GROUND_ROAD_TOP_LIFT - RC.ROAD_THICKNESS * 0.5 end
	local function place(a, b, t, vMode)
		local d = b - a
		local ok, err = RoadService.placeFromRequest({ p0 = a, p1 = a + d / 3, p2 = a + d * 2 / 3, p3 = b, roadType = t or "CollectorRoad", vMode = vMode })
		print("road", vMode, ok, err)
		Studio.step(0.2)
	end
	local g = centreY(0, 0)
	place(V.new(-300, g + 4, 0), V.new(300, g + 4, 0), "CollectorRoad", "Elevated")
	road(V.new(60, 0, 220), V.new(60, g + 4, 0), "NarrowRoad")
	place(V.new(-300, g, -260), V.new(300, g - 24, -260), "CollectorRoad", "Tunnel")
	place(V.new(-300, g - 4, 260), V.new(300, g - 4, 260), "NarrowRoad", "Tunnel")
elseif scene == "cross" then
	road(V.new(-260, 0, 0), V.new(260, 0, 0))
	road(V.new(0, 0, -260), V.new(0, 0, 260))
end
for _ = 1, 20 do Studio.step(0.1) end
local n = require("./render/dump")(Studio, Studio.game.Workspace, outFile)
if process.env.DUMP3D then
	-- DUMP3D="cx,cz,half": terrain + road faces for render/shade3d.py
	local cx, cz, half = string.match(process.env.DUMP3D, "([^,]+),([^,]+),([^,]+)")
	print("faces3d", require("./render/dump3d")(Studio, Studio.game.Workspace, outFile:gsub("%.json$", ".3d.json"), tonumber(cx), tonumber(cz), tonumber(half)))
end
-- lane centrelines (nav graph) as a separate overlay file
do
	local fs = require("@lune/fs")
	local serde = require("@lune/serde")
	local g = RoadService.getNavigationGraph()
	local lanes = {}
	for _, e in g:GetEdges() do
		local flat = {}
		for _, p in e.points or {} do table.insert(flat, p.X); table.insert(flat, p.Z) end
		table.insert(lanes, { id = e.id, pts = flat, ring = e.isRoundabout == true })
		-- junction connectors out of this lane (what cars actually drive through the box)
		for _, outId in e.out or {} do
			local cp = g:GetConnectionPoints(e.id, outId)
			local cf = {}
			for _, p in cp do table.insert(cf, p.X); table.insert(cf, p.Z) end
			if #cf >= 4 then table.insert(lanes, { id = e.id .. ">" .. outId, pts = cf, conn = true }) end
		end
	end
	fs.writeFile(outFile:gsub("%.json$", ".lanes.json"), serde.encode("json", lanes))
	print("lanes", #lanes)
end
print("parts", n)
do
	local RoadRules = R("ReplicatedStorage.Road.RoadRules")
	local net = RoadService.getNetwork()
	for nid, node in net:getNodes() do
		if #node.segments >= 3 then print("node", nid, "arms", #node.segments, "control", RoadRules.nodeControl(net, nid)) end
	end
	local g = RoadService.getNavigationGraph()
	local moves = {}
	for _, e in g:GetEdges() do
		for _, o in e.out do
			local k = tostring(e.outMovement[o])
			moves[k] = (moves[k] or 0) + 1
		end
	end
	for k, v in moves do print("movement", k, v) end
end
do
	-- traffic signs as planned for the client, for render/top.py
	local fs = require("@lune/fs")
	local serde = require("@lune/serde")
	local RoadRules = R("ReplicatedStorage.Road.RoadRules")
	local Planner = R("ReplicatedStorage.Road.TrafficSignPlanner")
	local net = RoadService.getNetwork()
	local list = {}
	for _, sg in net:getSegments() do table.insert(list, sg) end
	local opts = Planner.defaultOptions(function(id) return RoadRules.nodeControl(net, id) == "signal" end)
	local signs = Planner.plan(list, function(id) local nd = net:getNodes()[id]; return nd and nd.position end, opts)
	local out = {}
	for _, sg in signs do table.insert(out, { kind = sg.kind, x = sg.pos.X, z = sg.pos.Z, fx = sg.face.X, fz = sg.face.Z }) end
	fs.writeFile(outFile:gsub("%.json$", ".signs.json"), serde.encode("json", out))
	print("signs", #out)
end
for _, e in Studio.errors do print("ERR", e) end
local wn = 0
for _, w in Studio.warnings do wn += 1 if wn <= 10 then print("WARN", w) end end
