-- Placement latency: server wall time from a road request to its deltas going out (the
-- request itself plus the deferred work flushed the same frame), on a growing grid.
-- usage: lune run t_placebench.luau
local Studio = require("./shim/setup")("cur")
local process = require("@lune/process")
local FP = if process.env.FP == "1" then require("./shim/fnprof")(Studio, {
	"ServerScriptService.Services.Road.RoadService", "ReplicatedStorage.Road.RoadSceneRenderer",
	"ServerScriptService.Services.Terrain.TerrainGradeService", "ServerScriptService.Services.Road.RoadReplicationService",
	"ReplicatedStorage.Road.RoadNavigationGraph", "ReplicatedStorage.Road.IntersectionRenderer",
	"ReplicatedStorage.Road.RoadRenderer", "ReplicatedStorage.Road.RoadMeshBuilder", "ReplicatedStorage.Road.RoadNetwork",
	"ReplicatedStorage.Road.TrafficSignPlanner", "ServerScriptService.Services.Terrain.TerrainDataService",
}) else nil
local V = Studio.Vector3
local R = function(p) return Studio.require(Studio.find(p)) end
local Terrain = R("ServerScriptService.Services.Terrain.TerrainDataService")
Terrain.Init()
local RoadService = R("ServerScriptService.Services.Road.RoadService")
RoadService.Init(); RoadService.setUnlockCheck(function() return true end); RoadService.Bind(); RoadService.Start()
Studio.step(0.2)
if FP then FP.attach() end
local function road(a, b, t)
	local d = b - a
	local t0 = os.clock()
	local ok = RoadService.placeFromRequest({ p0 = a, p1 = a + d / 3, p2 = a + d * 2 / 3, p3 = b, roadType = t or "NarrowRoad" })
	local t1 = os.clock()
	Studio.flush()
	local t2 = os.clock()
	Studio.step(1 / 60)
	return ok, (t1 - t0) * 1000, (t2 - t1) * 1000, (os.clock() - t2) * 1000
end
local rows = {}
local N = tonumber(process.args[1]) or 8
for i = 0, N do
	local ok, a, b, c = road(V.new(-N * 60, 0, i * 120 - N * 60), V.new(N * 60, 0, i * 120 - N * 60))
	table.insert(rows, ("EW %2d ok=%s request %.1f ms  deferred %.1f ms  next frame %.1f ms"):format(i, tostring(ok), a, b, c))
end
for i = 0, N do
	local ok, a, b, c = road(V.new(i * 120 - N * 60, 0, -N * 60), V.new(i * 120 - N * 60, 0, N * 60))
	table.insert(rows, ("NS %2d ok=%s request %.1f ms  deferred %.1f ms  next frame %.1f ms"):format(i, tostring(ok), a, b, c))
end
for _, r in rows do print(r) end
if FP then FP.report(45) end
-- Digest of everything the renderer built, to prove an optimisation changed no output.
do
	local parts = {}
	for _, d in Studio.allDescendants() do
		if d.ClassName == "StringValue" and d.Name == "RoadMeshSpecs" then
			table.insert(parts, d.Parent.Name .. "=" .. d.Value)
		elseif d.ClassName == "Part" or d.ClassName == "WedgePart" or d.ClassName == "MeshPart" then
			local p = d.Position
			table.insert(parts, ("%s %s %.2f %.2f %.2f"):format(d.Name, d.ClassName, p.X, p.Y, p.Z))
		end
	end
	table.sort(parts)
	local h = 0
	for _, s in parts do for i = 1, #s do h = (h * 31 + string.byte(s, i)) % 4294967296 end end
	print(("DIGEST %d items hash %d"):format(#parts, h))
end
print("errors", #Studio.errors)
for i = 1, math.min(3, #Studio.errors) do print(Studio.errors[i]:sub(1, 300)) end
