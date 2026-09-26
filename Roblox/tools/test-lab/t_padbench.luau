local process = require("@lune/process")
local Studio = require("./shim/setup")(process.args[1] or "fix7")
local V, CF = Studio.Vector3, Studio.CFrame
local R = function(p) return Studio.require(Studio.find(p)) end
local Terrain = R("ServerScriptService.Services.Terrain.TerrainDataService")
Terrain.Init()
local hm = Terrain.getHeightmap()
for gx = 824, 1224 do for gz = 824, 1224 do
	local x, z = (gx - 1024) * 4, (gz - 1024) * 4
	hm:setCorner(gx, gz, math.floor(256 + (10 + z / 10 + 3 * math.sin(x / 37)) * 4 + 0.5))
end end
local Pad = R("ServerScriptService.Services.Terrain.TerrainPadService")
local t0 = os.clock()
local n = 0
for i = 0, 19 do for j = 0, 19 do
	n += 1
	-- rows of 33x24 lots back to back, a 10-stud gap between the backyards
	local x = -330 + i * 33
	local z = -600 + j * 52 + (if j % 2 == 0 then 0 else 0)
	local look = if j % 2 == 0 then CF.lookAt(V.new(x, 12, z), V.new(x, 12, z - 10)) else CF.lookAt(V.new(x, 12, z), V.new(x, 12, z + 10))
	Pad.padFootprint("b" .. n, look, 33, 24, 12 + z / 10)
end end
local dt = os.clock() - t0
print(("%s: %d pads in %.2f s (%.1f ms each)"):format(process.args[1] or "fix7", n, dt, dt / n * 1000))
t0 = os.clock()
for k = 1, n, 2 do Pad.unpadFootprint("b" .. k) end
dt = os.clock() - t0
print(("  demolish every other one: %.2f s (%.1f ms each, neighbours redo their fills)"):format(dt, dt / (n / 2) * 1000))
