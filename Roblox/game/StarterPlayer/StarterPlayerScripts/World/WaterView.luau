--!strict
-- WaterView (client): the custom water colour + foam layer of the hybrid water system.
-- Waves are the engine's own terrain water (animated + reflective, GPU-side, free); this
-- lays a translucent overlay on top for depth colour (turquoise shallows -> navy deeps) +
-- a thin band of MOVING foam at the shoreline. Each tile's water depth is baked once (on
-- load / on edit); the moving foam is a pre-baked noise field scrolled per frame, so only
-- the shore tiles near the camera repaint, with no terrain reads and no per-frame
-- math.noise (the per-frame-noise version cost ~300ms a frame).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Constants = require(ReplicatedStorage.Terrain.TerrainConstants)
local Heightmap = require(ReplicatedStorage.Terrain.Heightmap)
local TerrainGenerator = require(ReplicatedStorage.Terrain.TerrainGenerator)
local TerrainBrush = require(ReplicatedStorage.Terrain.TerrainBrush)
local WaterField = require(ReplicatedStorage.Terrain.WaterField)
local WaterImage = require(ReplicatedStorage.City.WaterImage)

local WaterView = {}

local HALF = Constants.MAP_HALF_EXTENT
local TILE = 2048 -- part-size cap; ceil(MAP_EXTENT / TILE) tiles per axis cover the map
local TILES_AXIS = math.ceil(Constants.MAP_EXTENT / TILE)
local TILE_RES = 256 -- px per tile (~8 studs/px)
local LIFT = 0.15 -- overlay sits ON the flat water surface; any higher and a flat sheet
                 -- parallax-floats over the 3D land at angled camera views
local SEA_Y = Constants.SEA_Y
local CHUNK_TILES = Constants.CHUNK_TILES
local CHUNKS = Constants.CHUNKS_PER_AXIS
local toCorner = Constants.worldToCorner
local cornerToWorld = Constants.cornerToWorld
local rawToWorldY = Constants.rawToWorldY
local ANIM_INTERVAL = 1 / 12 -- foam repaint cadence (s)
local ANIM_DIST = TILE -- only animate shore tiles within ~1 tile of the camera
local MASK_CELL = 64 -- studs per ocean-connectivity cell (foam only on ocean-connected water)
local MASK_DIM = math.ceil(Constants.MAP_EXTENT / MASK_CELL)

type Tile = { img: EditableImage, x0: number, z0: number, depth: buffer, base: buffer, foam: buffer, foamN: number, shore: boolean }

local _params: any = nil
local _hm: Heightmap.Heightmap = Heightmap.new() -- client prediction: chunks the overlay samples
local _tiles: { Tile } = {}
local _conn: RBXScriptConnection? = nil
local _animConn: RBXScriptConnection? = nil
local _gen = 0 -- build generation; a new city cancels an in-flight tile loop
local _time = 0 -- wave animation clock
local _accum = 0
local _oceanMask: buffer? = nil -- MASK_DIM^2, 1 = water cell connected to the open sea

local function num(v: any, d: number): number
	return if type(v) == "number" then v else d
end

-- worldY at one global terrain corner: the loaded heightmap value where that corner's
-- chunk is present (the player's edits), else the procedural base. Resolved per CORNER --
-- not per chunk -- so depth blends smoothly across the edge of the loaded region instead
-- of snapping to sea level there (that snap was the hard "square" steps in the colour).
local function cornerY(gx: number, gz: number): number
	local cx = math.floor(gx / CHUNK_TILES)
	local cz = math.floor(gz / CHUNK_TILES)
	if cx >= 0 and cx < CHUNKS and cz >= 0 and cz < CHUNKS and _hm:getChunk(cx, cz) then
		return rawToWorldY(_hm:getCorner(gx, gz))
	end
	return TerrainGenerator.surfaceYAt(gx, gz, _params)
end

-- Real (edited) surface worldY at a world point. Fast path: open water with no loaded
-- chunk nearby -> straight generator base (smooth, one noise eval). Near loaded chunks ->
-- bilinear over cornerY so edited terrain blends seamlessly into the surrounding base.
local function sampleY(wx: number, wz: number): number
	if not _params then return SEA_Y end
	local fx = toCorner(wx)
	local fz = toCorner(wz)
	local gx0 = math.floor(fx)
	local gz0 = math.floor(fz)
	local cx = math.floor(gx0 / CHUNK_TILES)
	local cz = math.floor(gz0 / CHUNK_TILES)
	if not (_hm:getChunk(cx, cz) or _hm:getChunk(cx + 1, cz) or _hm:getChunk(cx, cz + 1) or _hm:getChunk(cx + 1, cz + 1)) then
		return TerrainGenerator.surfaceYAt(fx, fz, _params)
	end
	local sx = fx - gx0
	local sz = fz - gz0
	local h00 = cornerY(gx0, gz0)
	local h10 = cornerY(gx0 + 1, gz0)
	local h01 = cornerY(gx0, gz0 + 1)
	local h11 = cornerY(gx0 + 1, gz0 + 1)
	local top = h00 + (h10 - h00) * sx
	local bot = h01 + (h11 - h01) * sx
	return top + (bot - top) * sz
end

-- Ocean mask: a coarse grid flood-filled from the map borders through below-sea cells, so
-- foam/waves show only on water connected to the open sea -- not inland lakes/ponds. Built
-- once per city load (a live edit won't re-link a lake to the sea until the next reload).
local function buildOceanMask()
	local dim = MASK_DIM
	local water = buffer.create(dim * dim)
	for cz = 0, dim - 1 do
		local wz = -HALF + (cz + 0.5) * MASK_CELL
		for cx = 0, dim - 1 do
			local wx = -HALF + (cx + 0.5) * MASK_CELL
			if sampleY(wx, wz) < 0 then buffer.writeu8(water, cz * dim + cx, 1) end
		end
	end
	local mask = buffer.create(dim * dim)
	local queue: { number } = {}
	local function push(cx: number, cz: number)
		if cx < 0 or cx >= dim or cz < 0 or cz >= dim then return end
		local i = cz * dim + cx
		if buffer.readu8(water, i) == 1 and buffer.readu8(mask, i) == 0 then
			buffer.writeu8(mask, i, 1)
			queue[#queue + 1] = i
		end
	end
	for c = 0, dim - 1 do push(c, 0); push(c, dim - 1); push(0, c); push(dim - 1, c) end
	local head = 1
	while head <= #queue do
		local i = queue[head]; head += 1
		local cx, cz = i % dim, i // dim
		push(cx + 1, cz); push(cx - 1, cz); push(cx, cz + 1); push(cx, cz - 1)
	end
	_oceanMask = mask
end

-- Is the water at (wx, wz) connected to the open sea? Checks the cell + its neighbours so a
-- shoreline foam pixel (whose own cell may sit on the land side) still counts as ocean.
local function isOcean(wx: number, wz: number): boolean
	local mask = _oceanMask
	if not mask then return true end -- not built yet: don't suppress foam
	local cx = math.floor((wx + HALF) / MASK_CELL)
	local cz = math.floor((wz + HALF) / MASK_CELL)
	for dz = -1, 1 do
		for dx = -1, 1 do
			local nx, nz = cx + dx, cz + dz
			if nx >= 0 and nx < MASK_DIM and nz >= 0 and nz < MASK_DIM
				and buffer.readu8(mask, nz * MASK_DIM + nx) == 1 then
				return true
			end
		end
	end
	return false
end

-- Below-sea test at a corner for the client's dry-pit prediction: uses the same sampler
-- as the overlay (loaded edits where present, generator base elsewhere) so the predicted
-- dry set tracks the player's dig until the authoritative set re-streams on reload.
local function clientBelowSea(gx: number, gz: number): boolean
	return sampleY(cornerToWorld(gx), cornerToWorld(gz)) < SEA_Y
end

-- Seed a chunk's base heights into the prediction heightmap so a brush stroke operates
-- on the real terrain shape (not a flat sea-level default) around the edit.
local function ensureChunk(cx: number, cz: number)
	if cx < 0 or cx >= CHUNKS or cz < 0 or cz >= CHUNKS then return end
	if not _hm:getChunk(cx, cz) then
		TerrainGenerator.generateChunk(_hm, cx, cz, _params)
	end
end

-- Mirror a sculpt stroke into the prediction heightmap and repaint just the overlay
-- tiles it touched, so the coastline colour + foam follow the edit. Fires at most at the
-- brush tick rate (~15/s) while dragging, and only on shore tiles -- not per frame.
local function onStroke(stroke: any)
	if not _params or type(stroke) ~= "table" then return end
	local R = num(stroke.radius, 0)
	local cxLo = math.floor((toCorner(stroke.centerX - R) - 2) / CHUNK_TILES)
	local cxHi = math.floor((toCorner(stroke.centerX + R) + 2) / CHUNK_TILES)
	local czLo = math.floor((toCorner(stroke.centerZ - R) - 2) / CHUNK_TILES)
	local czHi = math.floor((toCorner(stroke.centerZ + R) + 2) / CHUNK_TILES)
	for cz = czLo, czHi do
		for cx = cxLo, cxHi do
			ensureChunk(cx, cz)
		end
	end
	TerrainBrush.apply(_hm, stroke)
	WaterField.classify(clientBelowSea, stroke.centerX, stroke.centerZ, R) -- predict dry pits
	local minX, maxX = stroke.centerX - R, stroke.centerX + R
	local minZ, maxZ = stroke.centerZ - R, stroke.centerZ + R
	for _, t in _tiles do
		if maxX >= t.x0 and minX <= t.x0 + TILE and maxZ >= t.z0 and minZ <= t.z0 + TILE then
			-- only the brush footprint is re-sampled, not the whole tile (keeps editing cheap)
			t.foam, t.foamN = WaterImage.rebakeRect(t.depth, t.base, t.foam, t.foamN, sampleY, isOcean, WaterField.isDryAt, TILE_RES, t.x0, t.z0, TILE, minX, maxX, minZ, maxZ)
			t.shore = true
			WaterImage.compose(t.img, t.base, t.foam, t.foamN, TILE_RES, _time)
		end
	end
end

-- Per frame: scroll the foam on shoreline tiles near the camera. Throttled to
-- ANIM_INTERVAL; cheap (buffer reads + lerps, no terrain, no math.noise).
local function animStep(dt: number)
	_time += dt
	_accum += dt
	if _accum < ANIM_INTERVAL then return end
	_accum = 0
	local cam = Workspace.CurrentCamera
	local cp = cam and cam.CFrame.Position
	if not cp then return end
	for _, t in _tiles do
		if t.shore then
			local dx = (t.x0 + TILE / 2) - cp.X
			local dz = (t.z0 + TILE / 2) - cp.Z
			if dx * dx + dz * dz <= ANIM_DIST * ANIM_DIST then
				WaterImage.compose(t.img, t.base, t.foam, t.foamN, TILE_RES, _time)
			end
		end
	end
end

function WaterView.clear()
	_gen += 1
	_tiles = {}
	local f = Workspace:FindFirstChild("_Water")
	if f then f:Destroy() end
end

-- Engine terrain water, tuned to read THROUGH the overlay: some body + waves + reflection,
-- but not so opaque it fights the overlay's depth colour.
local function tuneEngineWater()
	local terrain = Workspace:FindFirstChildOfClass("Terrain")
	if not terrain then return end
	terrain.WaterColor = Color3.fromRGB(40, 92, 132)
	terrain.WaterTransparency = 0.5
	terrain.WaterReflectance = 0.5
	terrain.WaterWaveSize = 0.15 -- the visible wave motion now comes from here, not the overlay
	terrain.WaterWaveSpeed = 12
end

function WaterView.build(params: any)
	WaterView.clear()
	local myGen = _gen
	_params = params
	_time, _accum = 0, 0
	buildOceanMask()
	tuneEngineWater()
	local folder = Instance.new("Folder")
	folder.Name = "_Water"
	folder.Parent = Workspace

	-- Paint one tile per frame so a city load never hitches on the overlay.
	task.spawn(function()
		for i = 0, TILES_AXIS - 1 do
			for j = 0, TILES_AXIS - 1 do
				if myGen ~= _gen then return end
				local x0 = -HALF + i * TILE
				local z0 = -HALF + j * TILE
				local img = WaterImage.create(TILE_RES)
				local depth, base, foam, foamN, shore = WaterImage.bake(sampleY, isOcean, WaterField.isDryAt, TILE_RES, x0, z0, TILE)
				WaterImage.compose(img, base, foam, foamN, TILE_RES, 0)

				local part = Instance.new("Part")
				part.Name = "WaterTile"
				part.Anchored = true
				part.CanCollide = false
				part.CanTouch = false
				part.CanQuery = false
				part.CastShadow = false
				part.Transparency = 1
				part.Size = Vector3.new(TILE, 0.2, TILE)
				part.Position = Vector3.new(x0 + TILE / 2, SEA_Y + LIFT, z0 + TILE / 2)

				local decal = Instance.new("Decal")
				decal.Face = Enum.NormalId.Top
				;(decal :: any).TextureContent = Content.fromObject(img)
				decal.Parent = part
				part.Parent = folder
				_tiles[#_tiles + 1] = { img = img, x0 = x0, z0 = z0, depth = depth, base = base, foam = foam, foamN = foamN, shore = shore }
				RunService.Heartbeat:Wait()
			end
		end
	end)
end

function WaterView.Start()
	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	_conn = Net.TerrainBuildData.OnClientEvent:Connect(function(msg: any)
		if type(msg) ~= "table" then return end
		if msg.kind == "begin" then
			_params = {
				seed = num(msg.seed, 0),
				heightRange = num(msg.relief, 1),
				oceanLevel = num(msg.oceanLevel, 0),
				baseHeight = num(msg.baseHeight, 0),
				ruggedness = num(msg.ruggedness, 0),
				shape = if type(msg.shape) == "string" then msg.shape else nil,
				persistence = num(msg.persistence, 0.5),
				lacunarity = num(msg.lacunarity, 2),
				algo = if type(msg.algo) == "number" then msg.algo else nil,
			}
			_hm = Heightmap.new() -- fresh prediction; the streamed edited chunks fill it below
			WaterView.clear() -- tear down the old city's overlay; rebuild on "done"
		elseif msg.kind == "chunks" then
			-- The server's persisted terrain edits (brush / road grade / building pad). Load
			-- their heights so the overlay reflects the SAVED coastline on reload, not just the
			-- procedural base -- otherwise edited land sits in plain water with no shore foam.
			if type(msg.items) == "table" then
				for _, item in msg.items do
					if type(item) == "table" and type(item.key) == "number" and typeof(item.h) == "buffer" then
						local cx, cz = Heightmap.decodeKey(item.key)
						local chunk = _hm:ensureChunk(cx, cz)
						if buffer.len(item.h) == buffer.len(chunk.heights) then
							buffer.copy(chunk.heights, 0, item.h)
						end
					end
				end
			end
		elseif msg.kind == "dry" then
			-- authoritative dry-pit set (isolated dug below-sea cells) for this saved city
			WaterField.setDryKeys(if type(msg.keys) == "table" then msg.keys else {})
		elseif msg.kind == "done" then
			if _params then WaterView.build(_params) end
		elseif msg.kind == "none" then
			WaterView.clear()
		end
	end)

	-- Live edits: the sculpt tool hands us each accepted stroke so the overlay tracks it.
	local controllers = script.Parent.Parent:WaitForChild("Controllers")
	local ok, TerrainEdit = pcall(require, controllers:WaitForChild("TerrainEditController"))
	if ok and TerrainEdit.setStrokeListener then
		TerrainEdit.setStrokeListener(onStroke)
	end

	_animConn = RunService.Heartbeat:Connect(animStep)
end

function WaterView.Stop()
	if _conn then _conn:Disconnect(); _conn = nil end
	if _animConn then _animConn:Disconnect(); _animConn = nil end
	WaterView.clear()
end

return WaterView
