--!strict
-- Server-side terrain painting for INCREMENTAL edits made after a city is loaded
-- (road grades, building pads, brush strokes): drains the render-dirty chunk set each
-- Heartbeat and repaints a small budget per frame, which replicates to clients. The
-- full-map FIRST paint is NOT done here -- each client builds the base map locally from
-- the seed (TerrainBuildController), so the server never paints/replicates the whole map.
-- Voxel painting itself lives in the shared TerrainPainter (client and server share it).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Constants = require(ReplicatedStorage.Terrain.TerrainConstants)
local Heightmap = require(ReplicatedStorage.Terrain.Heightmap)
local TerrainPainter = require(ReplicatedStorage.Terrain.TerrainPainter)
local Net = require(ReplicatedStorage.Networker)

local TerrainRenderer = {}

local MESH_GROUND = Constants.MESH_GROUND
-- With a mesh ground the server no longer replicates the edited SHAPE as voxels -- it
-- ships the chunk buffers and each client rebuilds that chunk's mesh. Flushing on an
-- interval rather than per frame coalesces a drag: a brush stroke re-dirties the same
-- chunk every tick, and only the last state of it is worth sending.
-- ponytail: a chunk is 12.7 KB, so a sustained stroke costs ~250 KB/s to every client.
-- Ship a delta (changed corners only) if that ever shows up in a bandwidth profile.
local PATCH_INTERVAL = 0.2
local PATCH_PER_FLUSH = 4
local _patchAccum = 0

local _data: any
local _terrain: Terrain
local _hbConn: RBXScriptConnection?
local _queue: { number } = {}
local _queued: { [number]: boolean } = {}
-- Server painting stays OFF until a city has loaded: the load builds the base heightmap
-- (marking every chunk render-dirty), but clients paint that base themselves -- the
-- server must not paint or replicate it. Enabled after load so only LATER edits paint.
local _enabled = false

-- Normal path: water only when the ground is a mesh, the full column otherwise.
local function paintChunk(cx: number, cz: number)
	TerrainPainter.paintChunk(_terrain, _data.getHeightmap(), cx, cz, _data.isDryAt, MESH_GROUND)
end

-- Ground AND water, whatever the render mode. The admin save-copy and the edit-mode test
-- harness render server-side and want a world that looks right without a client attached.
local function paintChunkFull(cx: number, cz: number)
	TerrainPainter.paintChunk(_terrain, _data.getHeightmap(), cx, cz, _data.isDryAt)
end

local function drain()
	for _, key in _data.drainRenderDirty() do
		if not _queued[key] then
			_queued[key] = true
			table.insert(_queue, key)
		end
	end
end

-- Repaint the water and push the chunk's heights/materials to every client, which is what
-- keeps their ground mesh -- and their local getSurfaceY -- in step with the server.
local function flushPatches()
	local items = {}
	local hm = _data.getHeightmap()
	local budget = PATCH_PER_FLUSH
	while budget > 0 and #_queue > 0 do
		local key = table.remove(_queue, 1) :: number
		_queued[key] = nil
		local cx, cz = Heightmap.decodeKey(key)
		local ok, err = pcall(paintChunk, cx, cz)
		if not ok then
			warn("[TerrainRenderer] paint chunk", cx, cz, "failed:", err)
		end
		local chunk = hm:getChunk(cx, cz)
		if chunk then
			-- Flags included so the client's own TerrainBrush skips the same LOCKED corners
			-- this one does; see TerrainBuildController.adoptChunk.
			items[#items + 1] = { key = key, h = chunk.heights, m = chunk.materials, f = chunk.flags }
		end
		budget -= 1
	end
	if #items > 0 then
		Net.TerrainBuildData:FireAllClients({ kind = "patch", items = items })
	end
end

local function pump(dt: number)
	if not _enabled then return end
	drain()
	if MESH_GROUND then
		_patchAccum += dt
		if _patchAccum < PATCH_INTERVAL then return end
		_patchAccum = 0
		flushPatches()
		return
	end
	local budget = Constants.RENDER_CHUNKS_PER_FRAME
	while budget > 0 and #_queue > 0 do
		local key = table.remove(_queue, 1) :: number
		_queued[key] = nil
		local cx, cz = Heightmap.decodeKey(key)
		local ok, err = pcall(paintChunk, cx, cz)
		if not ok then
			warn("[TerrainRenderer] paint chunk", cx, cz, "failed:", err)
		end
		budget -= 1
	end
end

function TerrainRenderer.Init(dataService: any)
	assert(dataService, "[TerrainRenderer] requires TerrainDataService")
	_data = dataService
	_terrain = workspace:WaitForChild("Terrain", 10) :: Terrain
	assert(_terrain, "[TerrainRenderer] workspace.Terrain missing")
	-- Clients build their own terrain locally from the seed, so the server never needs
	-- voxels. Clear any baked into the place so they are not replicated (slow, wavy) on join.
	_terrain:Clear()
end

function TerrainRenderer.Bind()
	_hbConn = RunService.Heartbeat:Connect(pump)
end

function TerrainRenderer.Start() end

-- Enable per-frame server painting of incremental edits. Called once the city has loaded
-- and the base render-dirty has been discarded (clients own the base paint).
function TerrainRenderer.enableEditPainting()
	_enabled = true
end

-- Drop every pending render-dirty chunk WITHOUT painting. Called right after a load so the
-- base map (all chunks dirty from generation + grades) is never painted server-side.
function TerrainRenderer.discardPending()
	_data.drainRenderDirty()
	table.clear(_queue)
	table.clear(_queued)
end

-- Paint every render-dirty chunk synchronously (no frame budget). Edit-mode harness +
-- admin save-copy only (those still render server-side).
function TerrainRenderer.flushAllDirty()
	for _, key in _data.drainRenderDirty() do
		if not _queued[key] then
			_queued[key] = true
			table.insert(_queue, key)
		end
	end
	while #_queue > 0 do
		local key = table.remove(_queue, 1) :: number
		_queued[key] = nil
		local cx, cz = Heightmap.decodeKey(key)
		local ok, err = pcall(paintChunkFull, cx, cz)
		if not ok then
			warn("[TerrainRenderer] paint chunk", cx, cz, "failed:", err)
		end
	end
end

-- Paint every render-dirty chunk now, time-sliced (yield ~every 1s of work to dodge the
-- script watchdog). Server-side full paint, kept for the admin save-copy path and edit-mode
-- tests; the normal player load no longer uses it (clients build their own terrain).
function TerrainRenderer.renderAllAndWait()
	local YIELD_AFTER = 1.0
	local function refill()
		for _, key in _data.drainRenderDirty() do
			if not _queued[key] then
				_queued[key] = true
				table.insert(_queue, key)
			end
		end
	end
	refill()
	while #_queue > 0 do
		local batchStart = os.clock()
		repeat
			local key = table.remove(_queue, 1) :: number
			_queued[key] = nil
			local cx, cz = Heightmap.decodeKey(key)
			local ok, err = pcall(paintChunkFull, cx, cz)
			if not ok then
				warn("[TerrainRenderer] paint chunk", cx, cz, "failed:", err)
			end
		until #_queue == 0 or (os.clock() - batchStart) >= YIELD_AFTER
		refill()
		if #_queue > 0 then
			task.wait()
		end
	end
end

return TerrainRenderer
