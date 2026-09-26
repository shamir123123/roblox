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
elseif scene == "cross" then
	road(V.new(-260, 0, 0), V.new(260, 0, 0))
	road(V.new(0, 0, -260), V.new(0, 0, 260))
end
for _ = 1, 20 do Studio.step(0.1) end
local n = require("./render/dump")(Studio, Studio.game.Workspace, outFile)
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
for _, e in Studio.errors do print("ERR", e) end
local wn = 0
for _, w in Studio.warnings do wn += 1 if wn <= 10 then print("WARN", w) end end
