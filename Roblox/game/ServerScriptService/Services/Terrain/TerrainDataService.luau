--!strict
-- Owns the authoritative terrain heightmap (the single source of truth for shape).
-- Exposes geometry getters for external domains (zoning/roads ask slope/height
-- here, never the buffers) and domain-internal heightmap access for the renderer,
-- generator and persistence. Knows nothing about "buildable" policy.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Terrain.TerrainConstants)
local Heightmap = require(ReplicatedStorage.Terrain.Heightmap)
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local TerrainGenerator = require(ReplicatedStorage.Terrain.TerrainGenerator)
local TerrainPersistence = require(script.Parent.TerrainPersistence)
local TerrainOverlayLedger = require(script.Parent.TerrainOverlayLedger)
local WaterField = require(ReplicatedStorage.Terrain.WaterField)

local Players = game:GetService("Players")

local TerrainDataService = {}

local _hm: Heightmap.Heightmap
local _ledger: TerrainOverlayLedger.TerrainOverlayLedger
-- How the base map is generated (seed + player-facing knobs). Streamed to clients so
-- they regenerate the identical base locally; persisted so reloads reproduce it.
local _params: TerrainGenerator.GenParams = { seed = 0 }
local _editedChunks: { [number]: boolean } = {} -- cumulative chunks that deviate from base
-- The active map's authored template terrain (the .terrain record inside the
-- MapTemplateService blob), or nil for maps without one. Slot saves store only the
-- delta vs (seed base + this), so an untouched template city saves ~nothing.
local _templateTerrain: any = nil

local function normalizeParams(p: any): TerrainGenerator.GenParams
	local t = if type(p) == "table" then p else {}
	return {
		seed = if type(t.seed) == "number" then t.seed else 0,
		heightRange = if type(t.heightRange) == "number" then t.heightRange else 1,
		oceanLevel = if type(t.oceanLevel) == "number" then t.oceanLevel else 0,
		baseHeight = if type(t.baseHeight) == "number" then t.baseHeight else 0,
		ruggedness = if type(t.ruggedness) == "number" then t.ruggedness else 0,
		shape = if type(t.shape) == "string" then t.shape else nil,
		persistence = if type(t.persistence) == "number" then t.persistence else 0.5,
		lacunarity = if type(t.lacunarity) == "number" then t.lacunarity else 2.0,
		algo = if type(t.algo) == "number" then t.algo else nil,
	}
end
local _hasCity = false
local _lastBuildReq: { [Player]: number } = {}
local Net: any = nil -- set in Bind; kept off module load so requiring this never pulls Networker
local STREAM_BATCH = 12 -- edited chunks per TerrainBuildData message
-- A city load is under way and has NOT reached its terrain step yet.
--
-- The client now fires RequestTerrainBuild as soon as it asks for the city, so that it
-- can paint the ground WHILE this server is still restoring the roads, buildings and
-- plots that stand on it -- measured serially, that was 11.6 s of restore followed by
-- 22.7 s of terrain, for no reason: CitySerializer restores terrain third, long before
-- anything expensive. Answering such a request before loadState has run would stream the
-- OUTGOING city's ground, so the request waits here instead.
local _terrainLoadPending = false
-- Never hang a client on a load that died: past this the request is answered with
-- whatever is standing, which is the behaviour it had before the overlap existed.
local LOAD_WAIT_TIMEOUT = 60

function TerrainDataService.Init()
	assert(
		Constants.MAP_HALF_EXTENT == RoadConstants.MAP_HALF_EXTENT,
		"[TerrainDataService] MAP_HALF_EXTENT (" .. Constants.MAP_HALF_EXTENT
			.. ") must match RoadConstants (" .. RoadConstants.MAP_HALF_EXTENT .. ")"
	)
	_hm = Heightmap.new()
	_ledger = TerrainOverlayLedger.new(_hm)
end

-- Chunks that differ from the seed base (brush edits + road/building grades). The client
-- regenerates the base from the seed and overwrites just these.
function TerrainDataService.getClientEditedKeys(): { number }
	local set: { [number]: boolean } = {}
	for key in _editedChunks do set[key] = true end
	for _, key in _hm:dirtyKeys() do set[key] = true end
	local keys = {}
	for key in set do keys[#keys + 1] = key end
	return keys
end

-- Stream what a client needs to build the current map locally: seed/relief to regenerate
-- the base, then the edited chunks' heights+materials in batches. Yields between batches
-- so the send never stalls a frame.
local function streamTerrainTo(player: Player)
	if not _hasCity or not _hm then
		Net.TerrainBuildData:FireClient(player, { kind = "none" })
		return
	end
	local keys = TerrainDataService.getClientEditedKeys()
	Net.TerrainBuildData:FireClient(player, {
		kind = "begin",
		seed = _params.seed,
		relief = _params.heightRange,
		oceanLevel = _params.oceanLevel,
		baseHeight = _params.baseHeight,
		ruggedness = _params.ruggedness,
		shape = _params.shape,
		persistence = _params.persistence,
		lacunarity = _params.lacunarity,
		algo = _params.algo,
		total = #keys,
	})
	local batch = {}
	for _, key in keys do
		local cx, cz = Heightmap.decodeKey(key)
		local chunk = _hm:getChunk(cx, cz)
		if chunk then
			local h = buffer.create(buffer.len(chunk.heights))
			buffer.copy(h, 0, chunk.heights)
			local m = buffer.create(buffer.len(chunk.materials))
			buffer.copy(m, 0, chunk.materials)
			-- Flags travel too: the client predicts brush strokes through the same TerrainBrush
			-- this server runs, and TerrainBrush skips LOCKED corners. Without them the client
			-- would predict edits to a road bed the server refuses, and snap back on correction.
			local f = buffer.create(buffer.len(chunk.flags))
			buffer.copy(f, 0, chunk.flags)
			batch[#batch + 1] = { key = key, h = h, m = m, f = f }
			if #batch >= STREAM_BATCH then
				if not player.Parent then return end
				Net.TerrainBuildData:FireClient(player, { kind = "chunks", items = batch })
				batch = {}
				task.wait()
			end
		end
	end
	if #batch > 0 and player.Parent then
		Net.TerrainBuildData:FireClient(player, { kind = "chunks", items = batch })
	end
	if player.Parent then
		-- the dry-pit set (isolated dug below-sea cells): the client gates its overlay +
		-- base paint on this so those pits show no water. Raw key array (no client decode).
		Net.TerrainBuildData:FireClient(player, { kind = "dry", keys = WaterField.getDryKeys() })
	end
	if player.Parent then
		Net.TerrainBuildData:FireClient(player, { kind = "done" })
	end
end

-- A city load has started. Called BEFORE the restore, so a terrain request arriving in the
-- meantime waits for this city's heightmap instead of being answered off the last one.
function TerrainDataService.beginCityLoad()
	_terrainLoadPending = true
end

-- The terrain step is done (or the load died). Either way, release anyone waiting.
function TerrainDataService.endCityLoad()
	_terrainLoadPending = false
end

function TerrainDataService.Bind()
	Net = require(ReplicatedStorage:WaitForChild("Networker"))
	Net.RequestTerrainBuild.OnServerEvent:Connect(function(player: Player)
		local now = os.clock()
		if now - (_lastBuildReq[player] or 0) < 1 then return end
		_lastBuildReq[player] = now
		task.spawn(function()
			local deadline = os.clock() + LOAD_WAIT_TIMEOUT
			while _terrainLoadPending and os.clock() < deadline and player.Parent do
				task.wait(0.05)
			end
			if not player.Parent then return end
			if _terrainLoadPending then
				warn("[TerrainDataService] streaming terrain before the city load reached it -- the map may be the outgoing city's")
			end
			streamTerrainTo(player)
		end)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		_lastBuildReq[player] = nil
	end)
end

function TerrainDataService.Start() end -- generation/load is driven by the persistence provider on player load

-- Domain-internal: renderer / generator / persistence need chunk-level access.
function TerrainDataService.getHeightmap(): Heightmap.Heightmap
	return _hm
end

-- Domain-internal: grade/pad services share one overlay ledger so their claims
-- on the same corners merge instead of clobbering each other.
function TerrainDataService.getOverlayLedger(): TerrainOverlayLedger.TerrainOverlayLedger
	return _ledger
end

-- Water-field: which below-sea ground actually holds water. Isolated dug pits read dry;
-- the renderer feeds isDryAt to the painter so those columns paint air, not water.
function TerrainDataService.isDryAt(worldX: number, worldZ: number): boolean
	return WaterField.isDryAt(worldX, worldZ)
end

-- Called by the edit boundary after a brush stroke applies, to re-classify the dug cells.
function TerrainDataService.classifyWaterEdit(centerX: number, centerZ: number, radius: number)
	WaterField.classify(function(gx, gz)
		return _hm:getCorner(gx, gz) < Constants.SEA_RAW
	end, centerX, centerZ, radius)
end

-- Called by the road-grade layer when a tunnel cut digs land corners below sea
-- level: the trench is sealed concrete, never open water. Merges into the dry set
-- and re-streams it so every client copy (cursor water clamp, zone checks, water
-- overlay) stays in step.
function TerrainDataService.markDryCornerKeys(keys: { number })
	if #keys == 0 then return end
	WaterField.markDryKeys(keys)
	if Net then
		Net.TerrainBuildData:FireAllClients({ kind = "dry", keys = WaterField.getDryKeys() })
	end
end

-- Public geometry getters (external domains use these only).
-- getHeightAt is the RAW heightmap value (the authoritative shape). Most callers that
-- place something "on the ground" want getSurfaceY instead -- see below.
function TerrainDataService.getHeightAt(worldX: number, worldZ: number): number
	return _hm:getHeightAt(worldX, worldZ)
end

-- The VISIBLE ground surface: where a raycast and the player's eye land. Roblox's voxel
-- renderer draws the surface a constant Constants.RENDER_BULGE studs above the heightmap
-- (see TerrainConstants). Roads, lots and buildings must sit on THIS, not the raw
-- heightmap, or they end up buried under the grass and the grade/pad services have to
-- carve a pit to reveal them.
function TerrainDataService.getSurfaceY(worldX: number, worldZ: number): number
	return _hm:getHeightAt(worldX, worldZ) + Constants.RENDER_BULGE
end

-- The visible surface the ground WOULD have with no roads or building pads on it: the
-- overlay ledger's original heights, bilinear like getHeightAt. Retaining walls measure the
-- step between a road and the land beside it from this, not from the graded ground (which
-- the road itself has already cut or filled).
function TerrainDataService.getNaturalSurfaceY(worldX: number, worldZ: number): number
	if not _ledger then return TerrainDataService.getSurfaceY(worldX, worldZ) end
	local maxCorner = Constants.CORNERS_PER_AXIS - 1
	local fx = math.clamp(Constants.worldToCorner(worldX), 0, maxCorner)
	local fz = math.clamp(Constants.worldToCorner(worldZ), 0, maxCorner)
	local tx = math.min(math.floor(fx), maxCorner - 1)
	local tz = math.min(math.floor(fz), maxCorner - 1)
	local sx, sz = fx - tx, fz - tz
	local toY = Constants.rawToWorldY
	local h00 = toY(_ledger:naturalRaw(tx, tz))
	local h10 = toY(_ledger:naturalRaw(tx + 1, tz))
	local h01 = toY(_ledger:naturalRaw(tx, tz + 1))
	local h11 = toY(_ledger:naturalRaw(tx + 1, tz + 1))
	local top = h00 + (h10 - h00) * sx
	local bot = h01 + (h11 - h01) * sx
	return top + (bot - top) * sz + Constants.RENDER_BULGE
end

function TerrainDataService.getSlopeAt(worldX: number, worldZ: number): number
	return _hm:getSlopeAt(worldX, worldZ)
end

function TerrainDataService.getTileSlope(tx: number, tz: number): number
	return _hm:getTileSlope(tx, tz)
end

function TerrainDataService.getCorner(gx: number, gz: number): number
	return _hm:getCorner(gx, gz)
end

-- Corner mutation used by the edit layer (write-through + dirty tracking).
function TerrainDataService.setCorner(gx: number, gz: number, raw: number)
	_hm:setCorner(gx, gz, raw)
end

function TerrainDataService.isLocked(gx: number, gz: number): boolean
	return _hm:isLocked(gx, gz)
end

-- Renderer drains this each frame; independent of the save-dirty set.
function TerrainDataService.drainRenderDirty(): { number }
	return _hm:drainRenderDirty()
end

-- Persistence drains this on autosave / leave.
function TerrainDataService.drainSaveDirty(): { number }
	return _hm:drainDirty()
end

-- Generate a fresh procedural city into the heightmap. Base is render-dirty only
-- and reproducible from the params, so the edited-chunk set resets.
function TerrainDataService.generateNewCity(params: TerrainGenerator.GenParams)
	_params = normalizeParams(params)
	table.clear(_editedChunks)
	WaterField.reset() -- dug-pit dry set belongs to the old city
	if _ledger then
		_ledger:clear() -- snapshots reference the old ground; roads re-grade after load
	end
	TerrainGenerator.generate(_hm, _params)
	_hasCity = true
end

function TerrainDataService.newSeed(): number
	-- Flattest seed found in the buildable center (std ~14, range ~96).
	return 5.5
end

-- Set by CitySlotService when a city session starts (and after an F6 template
-- re-bake). Not cleared by generateNewCity: the template belongs to the map,
-- not the city, and loadState regenerates AFTER the caller sets it.
function TerrainDataService.setTemplateTerrain(record: any?)
	_templateTerrain = if type(record) == "table" then record else nil
end

-- Fold any pending brush edits into the cumulative edited-chunk set and return a
-- DataStore-safe record. Called by the persistence provider at save time.
-- Slot saves diff vs the map template (when set) so template terrain is stored once
-- per map, not in every player slot. forTemplate = an F6 template BAKE: that must
-- stay absolute vs the seed base -- diffing a template against itself would bake an
-- empty one.
function TerrainDataService.serializeState(forTemplate: boolean?): { [string]: any }
	local function buildRecord(): { [string]: any }
		for _, key in _hm:drainDirty() do
			_editedChunks[key] = true
		end
		local template = if forTemplate then nil else _templateTerrain
		local record = TerrainPersistence.serialize(_hm, _params, _editedChunks, template)
		record.relief = _params.heightRange -- legacy field: pre-params loaders read amplitude here
		record.params = {
			heightRange = _params.heightRange,
			oceanLevel = _params.oceanLevel,
			baseHeight = _params.baseHeight,
			ruggedness = _params.ruggedness,
			shape = _params.shape,
			persistence = _params.persistence,
			lacunarity = _params.lacunarity,
			algo = _params.algo,
		}
		record.dry = TerrainPersistence.packDryKeys(WaterField.getDryKeys()) -- isolated dug pits
		return record
	end

	if _ledger then
		return _ledger:withNaturalHeightmap(buildRecord)
	end
	return buildRecord()
end

-- Generate the base from the record's seed (or a fresh seed), then restore edits.
-- Called by the persistence provider on player load. record may be nil (first join).
function TerrainDataService.loadState(record: any, fallbackRelief: number?)
	local rec = if type(record) == "table" then record else {}
	local params = normalizeParams(rec.params)
	params.seed = if type(rec.seed) == "number" then rec.seed else TerrainDataService.newSeed()
	if type(rec.params) ~= "table" then
		-- pre-params save: amplitude lived in record.relief, else the caller's preset relief
		params.heightRange = if type(rec.relief) == "number" then rec.relief
			elseif type(fallbackRelief) == "number" then fallbackRelief
			else 1
	end
	TerrainDataService.generateNewCity(params)

	-- A tpl-marked save stored only the player's delta vs the map template; lay the
	-- template terrain down first or those chunks restore onto the wrong base. The
	-- template's chunks differ from the seed base, so they join _editedChunks -- the
	-- client stream rebuilds from the seed and needs them too.
	if type(record) == "table" and record.tpl == true then
		if TerrainPersistence.usableTemplate(_templateTerrain, params) then
			local okTpl, tplInfo = TerrainPersistence.deserialize(_hm, _templateTerrain, function(cx: number, cz: number)
				_hm:markRenderDirty(cx, cz)
				_editedChunks[Heightmap.chunkKey(cx, cz)] = true
			end)
			if not okTpl then
				warn("[TerrainDataService] template base failed to apply; terrain will miss the map's sculpting:", tplInfo)
			end
		else
			warn("[TerrainDataService] save expects a map template that is missing or mismatched; terrain will miss the map's sculpting")
		end
	end

	-- A record with a seed but no chunks -- the empty blob a city switch tears the old
	-- city down through -- has nothing to restore: the base generate above IS the terrain.
	if type(record) == "table" and record.seed and type(record.keys) == "table" then
		local ok, info = TerrainPersistence.deserialize(_hm, record, function(cx: number, cz: number)
			_hm:markRenderDirty(cx, cz)
			_editedChunks[Heightmap.chunkKey(cx, cz)] = true
		end)
		if not ok then
			warn("[TerrainDataService] terrain load failed, using base only:", info)
		end
	end

	if type(record) == "table" and typeof(record.dry) == "buffer" then
		WaterField.setDryKeys(TerrainPersistence.unpackDryKeys(record.dry))
	end

	-- The heightmap is this city's now. Anyone who asked for terrain while the rest of the
	-- city was still restoring can have it.
	_terrainLoadPending = false
end

return TerrainDataService
