--!strict
-- Owns city save slots: the per-player slot index + slot blobs in DataStore,
-- session locking on the index key, migration from the legacy single-blob save,
-- autosave, and the menu remotes (RequestSlotIndex / Create / Load / Delete /
-- Rename / Save). One city at a time per server: a second load REPLACES the one
-- standing -- its owner's city is saved, then torn down -- so starting or loading
-- another city from the menu no longer needs a rejoin.

local DataStoreService  = game:GetService("DataStoreService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local TextService       = game:GetService("TextService")

if not RunService:IsServer() then
	error("[CitySlotService] Must only be required on the server")
end

local MapPresets = require(ReplicatedStorage.City.MapPresets)
local WorldThemeCatalog = require(ReplicatedStorage.World.WorldThemeCatalog)
local RoadRules = require(ReplicatedStorage.Road.RoadRules)
local NetMiddleware = require(ReplicatedStorage.NetMiddleware)
local BlobCodec = require(script.Parent.BlobCodec)
local Telemetry = require(script.Parent.Parent.Util.Telemetry)
local CityRoles = require(ReplicatedStorage.Access.CityRoles)
local PlacesConfig = require(ReplicatedStorage.Access.PlacesConfig)
local VisitorList = require(script.Parent.Parent.Access.VisitorList)

local STORE_NAME        = "CityDistrict_City_v3" -- v3 (2026-09-26): binary terrain/nature save format; v2 saves are never read
local MAX_SLOTS         = 5   -- load/index bound: any existing slot up to here still loads (never orphan an old city)
local MAX_CREATE_SLOTS  = 3   -- max NEW cities a player may create
-- Invites accepted on the create screen. Each one is a username lookup plus a record write
-- on a path the player is waiting on, so the screen offers a few, not a guest list.
local MAX_CREATE_INVITES = 4
local MAX_NAME_LENGTH   = 40
local DEFAULT_CITY_NAME = "New City"
local AUTOSAVE_INTERVAL = 300 -- s; at most five minutes of play can be lost to a crash
local MAX_RETRIES       = 3
local RETRY_DELAY       = 2
-- Lock refreshes on every autosave (180s), so TTL is two intervals + slack.
-- Published servers keep the lock to prevent two live servers writing the same
-- slot. Studio Play sessions restart with a new server id constantly, and Stop
-- can interrupt shutdown, so Studio ignores existing locks instead of poisoning
-- the next test run.
local LOCKS_ENABLED     = not RunService:IsStudio()
local LOCK_TTL          = 390
local CLOSE_TIMEOUT     = 25
local REMOTE_COOLDOWN   = 0.5
local INDEX_SCHEMA      = 1

-- Per-player DataStore budget. A city over the per-city cap is never stored; a
-- save that would push the player's combined total past the per-player cap (or
-- the 1 MB hard ceiling) is rejected, not saved -- the player is never kicked,
-- they just cannot persist more until the city shrinks. On a size reject we now
-- also toast the owner (Net.Notify) so a city can never silently stop saving.
-- 3 cities are held under the 990 KB per-player total, which binds before per-city.
-- Roblox stores at most 4 MB under a single DataStore key, so a city spills across up
-- to CHUNK_LIMIT keys -- 16 MB of capacity per city. Keys are allocated only as they
-- fill: chunk 2 is never written until chunk 1 is full.
-- Budgets are counted in STORED bytes (packed size + the binary-in-JSON overhead), which
-- is what DataStore actually charges and what the player is shown.
local STORED_OVERHEAD     = 1.25                                  -- measured: 547-byte buffer -> 677 stored
local CHUNK_STORED_BYTES  = 4 * 1024 * 1024                       -- Roblox's hard per-key ceiling
local CHUNK_LIMIT         = 4                                     -- keys one city may use
-- Packed bytes that still fit a key once the overhead is applied, less a little headroom.
local CHUNK_PAYLOAD_BYTES = math.floor(CHUNK_STORED_BYTES / STORED_OVERHEAD) - 1024

local MAX_SLOT_BYTES    = CHUNK_STORED_BYTES * CHUNK_LIMIT        -- 16 MB per city
local MAX_PLAYER_BYTES  = MAX_SLOT_BYTES * MAX_CREATE_SLOTS       -- every city a player can make
local HARD_CEILING      = MAX_SLOT_BYTES * MAX_SLOTS              -- absolute; must never be stored

-- Shown for every mutating remote when the session is non-persistent (index
-- load failed or locked by another server): the change would be in-memory only
-- and silently lost on rejoin, so reject it instead of reporting success.
local NONPERSISTENT_MSG = "Your saves are temporarily unavailable. Rejoin to try again."

local DIFFICULTIES = table.freeze({ Easy = true, Normal = true, Hard = true })

local SERVER_ID = if game.JobId ~= "" then game.JobId
	else "studio-" .. tostring(os.time()) .. "-" .. tostring(math.random(1, 1000000))

type SlotMeta = { [string]: any }
type IndexData = {
	schemaVersion: number,
	lastPlayedSlot: number?,
	migratedLegacy: boolean?,
	playerName: string?,
	aliasName: string?, -- name the current who_{userId}_{name} alias key carries
	slots: { [string]: SlotMeta },
}
type Session = {
	index: IndexData,
	persistent: boolean,
	activeSlot: number?,
	sessionStartClock: number?,
}

local _store: DataStore? = nil
local _serializer: any
local _cityStatsService: any
local _terrainDataService: any
local _terrainRenderer: any
local _adminService: any
local _timeService: any
local _outsideConnectionService: any
local _mapTemplateService: any
-- Injected MapSeedService: what a brand-new map arrives with (preset highways, trees, rocks).
-- Optional on purpose -- a missing one must never stop a city being created.
local _mapSeedService: any = nil
-- Injected TerritoryService: which map tiles the city owns. Only the fresh-city branch
-- touches it here -- a saved city gets its land back through CitySerializer.
local _territoryService: any = nil
local _playerStatsService: any = nil
-- Injected CityTeleport. Used ONLY in the lobby, where picking a slot is a teleport
-- into a reserved city server rather than a build on this machine.
local _cityTeleport: any = nil
-- Injected PlaceAccessService: owns who may be here and what they may edit. CitySlotService
-- only tells it two things -- which city loaded, and that the owner is in it.
local _placeAccess: any = nil
-- Injected PlayerDataStore. Lobby only: the friend list reads other players' stored
-- guest lists and their "friends may visit" flag, both of which live on their record.
local _pds: any = nil
local _cityEconomyService: any
local _transitService: any

local _sessions: { [number]: Session } = {}
local _saving: { [number]: boolean } = {}
local _releaseRequested: { [number]: boolean } = {}
local _lastRemoteAt: { [number]: number } = {}
local _cameraStateByUserId: { [number]: any } = {}
local _lastAutosaveClock = 0
local _saveDiag = {
	inProgress = 0,
	lastAt = 0,
	lastMs = 0,
	lastOk = true,
	lastBytes = 0,
	lastError = "",
	lastReason = "none yet",
	rejected = "",
}

-- One city per server.
local _cityLoaded = false
local _cityOwnerUserId: number? = nil
local _loadInProgress = false
-- The city-sim services (clock, economy, transit) sit idle until a slot has
-- actually loaded -- starting them at server boot fires Sync* remotes (and ticks
-- the economy/transit loops) for a city that does not exist yet, e.g. while every
-- player is still in the main menu. Guarded so a re-entrant load (idempotent
-- RequestLoadSlot retry, see onRequestLoadSlot) never starts them twice.
local _citySimStarted = false
local _adminCopy: { adminUserId: number, sourceUserId: number, sourceSlotId: number, loadedAt: number }? = nil

local _loadResultRemote: RemoteEvent
local _notifyRemote: RemoteEvent

local CitySlotService = {}

-- ---------- key helpers ----------

local function indexKey(userId: number): string
	return "slots_index_" .. tostring(userId)
end

local function slotKey(userId: number, slotId: number): string
	return "slots_" .. tostring(userId) .. "_" .. tostring(slotId)
end

local function legacyKey(userId: number): string
	return "player_" .. tostring(userId)
end

local function defaultIndex(): IndexData
	return {
		schemaVersion = INDEX_SCHEMA,
		lastPlayedSlot = nil,
		migratedLegacy = false,
		slots = {},
	}
end

local function slotCount(index: IndexData): number
	local count = 0
	for _ in index.slots do
		count += 1
	end
	return count
end

-- ---------- locked index record (same { __sl, data, lock } shape as PlayerDataStore) ----------

local function lockIsFresh(lock: any): boolean
	return LOCKS_ENABLED and typeof(lock) == "table" and (os.time() - (lock.ts or 0)) < LOCK_TTL
end

local function parseRecord(raw: any): (any, any)
	if type(raw) == "table" and raw.__sl then
		return raw.data, raw.lock
	end
	return raw, nil
end

local function acquireIndex(userId: number): (IndexData?, boolean)
	local store = _store
	if not store then return nil, false end

	for attempt = 1, MAX_RETRIES do
		local acquired = false
		local result: IndexData? = nil

		local ok, err = pcall(function()
			store:UpdateAsync(indexKey(userId), function(raw)
				local data, lock = parseRecord(raw)

				if lock and lock.owner ~= SERVER_ID and lockIsFresh(lock) then
					return nil
				end

				data = if typeof(data) == "table" and typeof(data.slots) == "table" then data else defaultIndex()
				acquired = true
				result = data

				return { __sl = true, data = data, lock = { owner = SERVER_ID, ts = os.time() } }
			end)
		end)

		if ok and acquired then
			return result, true
		end

		if ok then
			warn(string.format("[CitySlotService] slot index for %d locked by another session (try %d/%d)", userId, attempt, MAX_RETRIES))
		else
			warn(string.format("[CitySlotService] index load attempt %d/%d failed for %d: %s", attempt, MAX_RETRIES, userId, tostring(err)))
		end

		if attempt < MAX_RETRIES then
			task.wait(RETRY_DELAY * attempt)
		end
	end

	return nil, false
end

local function writeIndex(userId: number, index: IndexData, release: boolean): boolean
	local store = _store
	if not store then return false end

	for attempt = 1, MAX_RETRIES do
		local wrote = false

		local ok, err = pcall(function()
			store:UpdateAsync(indexKey(userId), function(raw)
				local _, lock = parseRecord(raw)

				if lock and lock.owner ~= SERVER_ID and lockIsFresh(lock) then
					return nil
				end

				wrote = true
				local newLock = if release then nil else { owner = SERVER_ID, ts = os.time() }
				return { __sl = true, data = index, lock = newLock }
			end)
		end)

		if ok and wrote then return true end

		warn(string.format(
			"[CitySlotService] index write attempt %d/%d failed for %d: %s",
			attempt, MAX_RETRIES, userId,
			tostring(if ok then "lock lost to another server" else err)
		))

		if attempt < MAX_RETRIES then
			task.wait(RETRY_DELAY * attempt)
		end
	end

	return false
end

-- Chunk 1 keeps the plain slot key, so every save written before chunking still loads;
-- chunk N > 1 lives at "<slot key>_cN". (LEGACY layout: read, never written any more.)
local function chunkKey(userId: number, slotId: number, index: number): string
	local base = slotKey(userId, slotId)
	return if index <= 1 then base else base .. "_c" .. tostring(index)
end

-- Legacy chunk 1 opened with a 2-byte header {0xFF, chunkCount}. 0xFF can never start a
-- pre-chunking blob: those begin with the Zstd frame magic (0x28).
local CHUNK_MAGIC = 0xFF

-- == Generations: crash-safe saves ==========================================
-- A save is written as a whole new GENERATION beside the ones already stored -- every chunk
-- under its own keys -- and only then does the slot key, now a 2-byte pointer, switch to it
-- in a single write. A crash, a shutdown or a failed write at any point before that switch
-- leaves the pointer on the last complete save. (The old layout overwrote the same chunk
-- keys in place, so a save cut off half way left the city's first chunk pointing at a mix
-- of old and new data: a large city could be lost to one bad moment.)
--   * Three generations rotate, and the one a session LOADED is never overwritten during
--     that session: whatever that session does -- a bug that empties a section, two bad
--     autosaves in a row -- the city as it was when the player joined is still stored.
--   * If the newest save ever fails to decode, loading falls back on its own to the newest
--     readable earlier generation (a sequence number in each generation's header orders
--     them) and the next save goes over the broken one.
-- Layout: slot key = { POINTER_MAGIC, gen }; generation g chunk i at "<slot>_g<g>c<i>",
-- chunk 1 opening with { GEN_HEAD_MAGIC, count, seq (u32) }.
local POINTER_MAGIC = 0xFD
local GEN_HEAD_MAGIC = 0xFC
local GEN_HEAD_BYTES = 6
local GENERATIONS = 3
-- Per "<userId>:<slotId>": the generation the pointer names, the one this session loaded
-- (-1 = a legacy-layout save), and the highest sequence number seen.
local _slotGen: { [string]: { current: number, loaded: number, seq: number } } = {}

local function genKey(userId: number, slotId: number): string
	return tostring(userId) .. ":" .. tostring(slotId)
end

local function genChunkKey(userId: number, slotId: number, gen: number, index: number): string
	return slotKey(userId, slotId) .. "_g" .. tostring(gen) .. "c" .. tostring(index)
end

local function splitPacked(packed: buffer, seq: number): { buffer }
	local total = buffer.len(packed)
	local count = math.max(1, math.ceil(total / CHUNK_PAYLOAD_BYTES))
	local parts: { buffer } = {}
	local at = 0
	for i = 1, count do
		local size = math.min(CHUNK_PAYLOAD_BYTES, total - at)
		local head = i == 1
		local part = buffer.create(if head then size + GEN_HEAD_BYTES else size)
		if head then
			buffer.writeu8(part, 0, GEN_HEAD_MAGIC)
			buffer.writeu8(part, 1, count)
			buffer.writeu32(part, 2, seq % 4294967296)
		end
		buffer.copy(part, if head then GEN_HEAD_BYTES else 0, packed, at, size)
		parts[i] = part
		at += size
	end
	return parts
end

local function writeKey(key: string, value: any, label: string): boolean
	local store = _store
	if not store then return false end

	for attempt = 1, MAX_RETRIES do
		local ok, err = pcall(function()
			store:UpdateAsync(key, function()
				return value
			end)
		end)

		if ok then return true end

		warn(string.format("[CitySlotService] %s write attempt %d/%d failed: %s", label, attempt, MAX_RETRIES, tostring(err)))

		if attempt < MAX_RETRIES then
			task.wait(RETRY_DELAY * attempt)
		end
	end

	return false
end

local function readKey(key: string, label: string): (any, boolean)
	local store = _store
	if not store then return nil, true end

	for attempt = 1, MAX_RETRIES do
		local ok, result = pcall(function()
			return store:GetAsync(key)
		end)

		if ok then return result, true end

		warn(string.format("[CitySlotService] %s read attempt %d/%d failed: %s", label, attempt, MAX_RETRIES, tostring(result)))

		if attempt < MAX_RETRIES then
			task.wait(RETRY_DELAY * attempt)
		end
	end

	return nil, false
end

local function joinParts(parts: { buffer }): buffer
	local total = 0
	for _, p in parts do total += buffer.len(p) end
	local joined = buffer.create(total)
	local at = 0
	for _, p in parts do
		buffer.copy(joined, at, p, 0, buffer.len(p))
		at += buffer.len(p)
	end
	return joined
end

-- One generation, whole: (blob, readOk, seq). readOk false = the DataStore could not be
-- read (try again later); readOk true with a nil blob = that generation is missing or broken.
local function readGeneration(userId: number, slotId: number, gen: number): (any, boolean, number)
	local label = string.format("slot %d gen %d for %d", slotId, gen, userId)
	local head, okHead = readKey(genChunkKey(userId, slotId, gen, 1), label)
	if not okHead then return nil, false, -1 end
	if typeof(head) ~= "buffer" or buffer.len(head) < GEN_HEAD_BYTES or buffer.readu8(head, 0) ~= GEN_HEAD_MAGIC then
		return nil, true, -1
	end
	local count = math.clamp(buffer.readu8(head, 1), 1, CHUNK_LIMIT)
	local seq = buffer.readu32(head, 2)
	local parts: { buffer } = {}
	local headLen = buffer.len(head) - GEN_HEAD_BYTES
	parts[1] = buffer.create(headLen)
	buffer.copy(parts[1], 0, head, GEN_HEAD_BYTES, headLen)
	for i = 2, count do
		local part, okPart = readKey(genChunkKey(userId, slotId, gen, i), label)
		if not okPart then return nil, false, seq end
		if typeof(part) ~= "buffer" then
			warn(string.format("[CitySlotService] slot %d gen %d for %d is missing chunk %d of %d", slotId, gen, userId, i, count))
			return nil, true, seq
		end
		parts[i] = part
	end
	local okUnpack, blob = pcall(BlobCodec.unpack, joinParts(parts))
	return if okUnpack then blob else nil, true, seq
end

-- Writes the city as a new generation, then points the slot at it (see Generations).
local function writeSlotBlob(userId: number, slotId: number, blob: any): boolean
	-- The legacy migration path still hands over a plain table; it never needs chunking.
	if typeof(blob) ~= "buffer" then
		return writeKey(slotKey(userId, slotId), blob, string.format("slot %d for %d", slotId, userId))
	end

	local k = genKey(userId, slotId)
	local g = _slotGen[k]
	if not g then
		-- Not loaded by this server (a save straight after create): ask the pointer.
		local head, ok = readKey(slotKey(userId, slotId), string.format("slot %d pointer for %d", slotId, userId))
		if not ok then return false end
		local cur = -1
		if typeof(head) == "buffer" and buffer.len(head) >= 2 and buffer.readu8(head, 0) == POINTER_MAGIC then
			cur = buffer.readu8(head, 1)
		end
		g = { current = cur, loaded = cur, seq = 0 }
		_slotGen[k] = g
	end
	local state = g :: { current: number, loaded: number, seq: number }

	-- Never the generation the pointer names now, never the one this session loaded.
	local newGen = 0
	while newGen == state.current or newGen == state.loaded do newGen += 1 end
	if newGen >= GENERATIONS then newGen = 0 end

	-- Wall-clock ordered, so generations written by different servers still sort right.
	local seq = math.max(state.seq + 1, os.time())
	local parts = splitPacked(blob, seq)
	if #parts > CHUNK_LIMIT then
		warn(string.format("[CitySlotService] slot %d for %d needs %d chunks, cap is %d", slotId, userId, #parts, CHUNK_LIMIT))
		return false
	end

	local label = string.format("slot %d gen %d for %d", slotId, newGen, userId)
	for i = #parts, 1, -1 do
		if not writeKey(genChunkKey(userId, slotId, newGen, i), parts[i], label) then return false end
	end
	-- The switch: one small write. Until it lands, the last save is what loads.
	local pointer = buffer.create(2)
	buffer.writeu8(pointer, 0, POINTER_MAGIC)
	buffer.writeu8(pointer, 1, newGen)
	if not writeKey(slotKey(userId, slotId), pointer, string.format("slot %d pointer for %d", slotId, userId)) then
		return false
	end
	local wasLegacy = state.current < 0
	state.current = newGen
	state.seq = seq
	if wasLegacy then
		-- The legacy layout's tail chunks now belong to nothing (its chunk 1 was the slot key).
		task.spawn(function()
			local store = _store
			if not store then return end
			for i = 2, CHUNK_LIMIT do pcall(function() store:RemoveAsync(chunkKey(userId, slotId, i)) end) end
		end)
	end
	return true
end

-- Reassembles a city from however many keys it was stored across. A missing or unreadable
-- chunk of a LEGACY save is a read FAILURE, never an empty slot -- reporting ok would load a
-- fresh city and then autosave straight over the player's real one.
local function readSlotBlob(userId: number, slotId: number): (any, boolean)
	local k = genKey(userId, slotId)
	local head, okHead = readKey(slotKey(userId, slotId), string.format("slot %d for %d", slotId, userId))
	if not okHead then return nil, false end

	if typeof(head) == "buffer" and buffer.len(head) >= 2 and buffer.readu8(head, 0) == POINTER_MAGIC then
		local gen = buffer.readu8(head, 1)
		local blob, readOk, seq = readGeneration(userId, slotId, gen)
		if not readOk then return nil, false end
		if blob ~= nil then
			_slotGen[k] = { current = gen, loaded = gen, seq = math.max(seq, 0) }
			return blob, true
		end
		-- The newest save is broken: the newest readable earlier generation, then.
		local best, bestGen, bestSeq = nil, -1, -1
		for other = 0, GENERATIONS - 1 do
			if other == gen then continue end
			local b, ok2, s2 = readGeneration(userId, slotId, other)
			if not ok2 then return nil, false end
			if b ~= nil and s2 > bestSeq then best, bestGen, bestSeq = b, other, s2 end
		end
		if best == nil then
			warn(string.format("[CitySlotService] slot %d for %d: no readable generation", slotId, userId))
			return nil, false
		end
		warn(string.format("[CitySlotService] slot %d for %d: newest save (gen %d) unreadable -- recovered gen %d", slotId, userId, gen, bestGen))
		-- current = the broken one, so the next save goes over it and keeps the recovered one.
		_slotGen[k] = { current = gen, loaded = bestGen, seq = math.max(bestSeq, seq) }
		return best, true
	end

	_slotGen[k] = { current = -1, loaded = -1, seq = 0 }
	-- Plain table: a save from before compression. Nothing to reassemble.
	if typeof(head) ~= "buffer" then return head, true end

	local count, offset = 1, 0
	if buffer.len(head) >= 2 and buffer.readu8(head, 0) == CHUNK_MAGIC then
		count = math.clamp(buffer.readu8(head, 1), 1, CHUNK_LIMIT)
		offset = 2
	end

	local parts: { buffer } = {}
	local headLen = buffer.len(head) - offset
	parts[1] = buffer.create(headLen)
	buffer.copy(parts[1], 0, head, offset, headLen)

	for i = 2, count do
		local part, okPart = readKey(chunkKey(userId, slotId, i), string.format("slot %d chunk %d for %d", slotId, i, userId))
		if not okPart or typeof(part) ~= "buffer" then
			warn(string.format("[CitySlotService] slot %d for %d is missing chunk %d of %d", slotId, userId, i, count))
			return nil, false
		end
		parts[i] = part
	end

	local blob = BlobCodec.unpack(joinParts(parts))
	return blob, blob ~= nil
end

-- Every key the city could have used, not just the first: a deleted slot must not leave
-- 12 MB of orphaned tail chunks behind for a city that no longer exists.
-- How much DataStore the player's ACTIVE city occupies, for the storage meter on the
-- Settings page. Read-only and derived from the index already in memory, so it needs no
-- rate limit of its own and tells the player nothing they cannot already see.
local function onRequestCityMemory(player: Player): any
	local session = _sessions[player.UserId]
	local slotId = session and session.activeSlot
	local meta = if session and slotId then session.index.slots[tostring(slotId)] else nil
	local used = math.max(0, tonumber(meta and meta.bytes) or 0)
	return {
		used     = used,
		cap      = MAX_SLOT_BYTES,
		keyBytes = CHUNK_STORED_BYTES,
		keyLimit = CHUNK_LIMIT,
		-- Keys the city actually occupies: 1 until the first fills, then 2, and so on.
		keysUsed = if used <= 0 then 0 else math.min(CHUNK_LIMIT, math.ceil(used / CHUNK_STORED_BYTES)),
	}
end

local function removeSlotBlob(userId: number, slotId: number)
	local store = _store
	if not store then return end

	local keys: { string } = { slotKey(userId, slotId) .. "_bak" }
	for i = 1, CHUNK_LIMIT do
		table.insert(keys, chunkKey(userId, slotId, i)) -- legacy layout (i = 1 is the pointer too)
		for gen = 0, GENERATIONS - 1 do
			table.insert(keys, genChunkKey(userId, slotId, gen, i))
		end
	end
	for _, key in keys do
		local ok, err = pcall(function()
			store:RemoveAsync(key)
		end)

		if not ok then
			warn(string.format("[CitySlotService] %s remove failed for %d: %s", key, userId, tostring(err)))
		end
	end
	_slotGen[genKey(userId, slotId)] = nil
end

-- ---------- migration ----------

-- The pre-slot save was one blob under player_{userId} with the terrain record
-- embedded by the old provider. Fold it into slot 1 once; the legacy key is
-- never deleted (rollback insurance).
local function migrateLegacy(userId: number, index: IndexData)
	if index.migratedLegacy or slotCount(index) > 0 then
		index.migratedLegacy = true
		return
	end

	index.migratedLegacy = true

	local store = _store
	if not store then return end

	local ok, raw = pcall(function()
		return store:GetAsync(legacyKey(userId))
	end)

	if not ok or typeof(raw) ~= "table" then return end

	local data = parseRecord(raw)
	if typeof(data) ~= "table" or typeof(data.terrain) ~= "table" then return end

	local now = os.time()
	local blob = {
		version = 1,
		savedAt = now,
		mapId = MapPresets.DEFAULT_ID,
		difficulty = "Normal",
		terrain = data.terrain,
		roads = {},
		zones = {},
		buildings = {},
	}

	if not writeSlotBlob(userId, 1, blob) then
		warn("[CitySlotService] legacy migration: slot 1 write failed for " .. userId)
		return
	end

	index.slots["1"] = {
		slotId = 1,
		cityName = "My City",
		mapId = MapPresets.DEFAULT_ID,
		difficulty = "Normal",
		population = 0,
		money = 0,
		happiness = 0,
		playtimeSeconds = 0,
		createdTimestamp = now,
		lastPlayedTimestamp = now,
		lastVersion = 1,
	}
	index.lastPlayedSlot = 1

	print("[CitySlotService] migrated legacy save to slot 1 for userId " .. userId)
end

-- Cosmetic alias key (who_{userId}_{name}_{n}cities) so the Data Stores manager
-- key LIST shows who owns the numeric keys and how many cities they have.
-- Nothing ever reads it -- the dashboard is its only consumer -- so a rename or
-- count change can't break lookups; the stale alias is replaced.
local function updateAliasKey(player: Player, index: IndexData)
	local wanted = player.Name .. "_" .. tostring(slotCount(index)) .. "cities"
	if index.aliasName == wanted then return end

	local oldAlias = index.aliasName
	index.aliasName = wanted
	local userId = player.UserId

	task.spawn(function()
		local store = _store
		if not store then return end
		pcall(function()
			if oldAlias and oldAlias ~= "" then
				store:RemoveAsync("who_" .. userId .. "_" .. oldAlias)
			end
			store:SetAsync("who_" .. userId .. "_" .. wanted, {
				userId = userId, name = player.Name, cityCount = slotCount(index), updated = os.time(),
			})
		end)
	end)
end

-- ---------- session ----------

local function loadSession(player: Player)
	local userId = player.UserId
	if _sessions[userId] then return end

	local index, persistent = acquireIndex(userId)

	if not player.Parent then
		if persistent and index then
			writeIndex(userId, index, true)
		end
		return
	end

	if not persistent or not index then
		-- Locked or unreachable: fall back to a read-only copy of the index so
		-- the menu still shows the player's cities. Loads work; saves are skipped.
		local readonly: IndexData? = nil
		local store = _store
		if store then
			local ok, raw = pcall(function()
				return store:GetAsync(indexKey(userId))
			end)
			if ok then
				local data = parseRecord(raw)
				if typeof(data) == "table" and typeof(data.slots) == "table" then
					readonly = data
				end
			end
		end

		warn(string.format("[CitySlotService] %s (userId %d) slot session is NON-PERSISTENT (index load failed or locked)", player.Name, userId))
		_sessions[userId] = { index = readonly or defaultIndex(), persistent = false, activeSlot = nil, sessionStartClock = nil }
		return
	end

	-- Keys are userId-based on purpose (usernames change; ids never do). Stamp the
	-- current username INTO the index blob instead, so the Data Stores manager and
	-- the admin panel show whose save a key is when its value is opened.
	index.playerName = player.Name

	migrateLegacy(userId, index)
	updateAliasKey(player, index)
	writeIndex(userId, index, false)

	_sessions[userId] = { index = index, persistent = true, activeSlot = nil, sessionStartClock = nil }
end

-- Join gate (PlayerLoadService): has this player's slot index finished loading? True for a
-- read-only session as well -- the menu lists and loads cities either way, and the player
-- is warned separately when saves are unavailable.
function CitySlotService.isSessionReady(userId: number): boolean
	return _sessions[userId] ~= nil
end

-- A transient DataStore error at join leaves the whole session read-only: loads
-- work, but every save (auto, manual, stop) is silently skipped, so a city built
-- in that session is lost. Retry the index acquire so a recovered store heals the
-- session. The read-only session could not mutate the store, so adopting the
-- freshly-acquired index loses nothing; the live slot's meta table is carried
-- over so in-session stats already stamped on it (population, playtime) survive.
local function healPersistence(userId: number): boolean
	local session = _sessions[userId]
	if not session then return false end
	if session.persistent then return true end
	local fresh, acquired = acquireIndex(userId)
	if not (acquired and fresh) then return false end
	local activeSlot = session.activeSlot
	local liveMeta = if activeSlot then session.index.slots[tostring(activeSlot)] else nil
	session.index = fresh
	if activeSlot and liveMeta then
		session.index.slots[tostring(activeSlot)] = liveMeta
	end
	session.persistent = true
	warn(string.format("[CitySlotService] session for userId %d healed to persistent", userId))
	return true
end

-- This player is a GUEST in somebody else's city server: the owner is somebody, and it
-- is not them. The owner id is this server's own identity (PlaceAccessService resolved it
-- from the access store by PrivateServerId at boot) -- it is never supplied by a client,
-- so there is no request shape that can point any of this at another player's data.
-- Returns nil in the lobby, in Studio, on a public server, and for the owner themselves.
local function guestOwnerId(userId: number): number?
	if not _placeAccess then return nil end
	local ownerId = _placeAccess.getOwnerId()
	if ownerId > 0 and ownerId ~= userId then return ownerId end
	return nil
end

-- Open an ABSENT owner's slot index so their builders can start the city.
--
-- Unlike loadSession there is deliberately NO read-only fallback. That fallback exists so
-- a PRESENT player still sees their own menu when the store is unhappy; here it would
-- mean guests building for an hour into a city that can never save, or -- if the lock is
-- held because the owner is playing that city in another server right now -- a second
-- live copy of it, with whichever one closes last overwriting the other. A lock we cannot
-- take is a refusal, every time.
local function acquireOwnerSession(ownerId: number): boolean
	local existing = _sessions[ownerId]
	if existing then return existing.persistent end

	local index, persistent = acquireIndex(ownerId)
	if not persistent or not index then return false end

	migrateLegacy(ownerId, index)
	-- playerName / alias key are left alone on purpose: both are stamped from a live
	-- Player and the owner refreshes them on their own next join.
	writeIndex(ownerId, index, false)
	_sessions[ownerId] = { index = index, persistent = true, activeSlot = nil, sessionStartClock = nil }
	return true
end

local function publicSlotList(index: IndexData): { SlotMeta }
	local out: { SlotMeta } = {}
	for _, meta in index.slots do
		table.insert(out, table.clone(meta))
	end
	table.sort(out, function(a, b)
		return (a.slotId or 0) < (b.slotId or 0)
	end)
	return out
end

local function isAdmin(player: Player): boolean
	return _adminService and _adminService.TierOf and _adminService.TierOf(player) == "admin"
end

-- Staff open ANY player's city, invited or not, shared or solo, owner present or not:
-- a city you cannot enter is a city you cannot moderate. TierOf answers "admin" for the
-- place owner with no roster record of their own, and a curator or tester is deliberately
-- NOT staff here -- every admin gate in the game asks for "admin" exactly, and widening
-- this one is how a review tier quietly becomes a master key.
local function isCityStaff(player: Player): boolean
	return isAdmin(player) == true
end

local function trim(s: string): string
	s = string.gsub(s, "^%s+", "")
	return string.gsub(s, "%s+$", "")
end

local function resolveUserQuery(query: any): (number?, string?)
	if typeof(query) == "number" and query == math.floor(query) and query > 0 then
		return query, nil
	end
	if typeof(query) ~= "string" then
		return nil, "Enter a userId or username."
	end
	local q = trim(query)
	if q == "" then
		return nil, "Enter a userId or username."
	end
	local asNumber = tonumber(q)
	if asNumber and asNumber == math.floor(asNumber) and asNumber > 0 then
		return asNumber, nil
	end
	-- Fuzzy match against online players first (prefix / substring, case-insensitive)
	local ql = string.lower(q)
	for _, p in Players:GetPlayers() do
		if string.lower(p.Name):find(ql, 1, true) or string.lower(p.DisplayName):find(ql, 1, true) then
			return p.UserId, nil
		end
	end
	-- Fall back to Roblox API lookup
	local ok, result = pcall(function()
		return Players:GetUserIdFromNameAsync(q)
	end)
	if ok and typeof(result) == "number" then
		return result, nil
	end
	return nil, "Could not find that player."
end

local function readIndexReadonly(userId: number): IndexData?
	local session = _sessions[userId]
	if session then
		return session.index
	end
	local store = _store
	if not store then return nil end
	local ok, raw = pcall(function()
		return store:GetAsync(indexKey(userId))
	end)
	if not ok then
		warn(string.format("[CitySlotService] admin index read failed for %d: %s", userId, tostring(raw)))
		return nil
	end
	local data = parseRecord(raw)
	if typeof(data) == "table" and typeof(data.slots) == "table" then
		return data :: any
	end
	return defaultIndex()
end

local function publicOnlinePlayers(): { any }
	local rows = {}
	for _, p in Players:GetPlayers() do
		local session = _sessions[p.UserId]
		table.insert(rows, {
			userId = p.UserId,
			name = p.Name,
			displayName = p.DisplayName,
			saveCount = if session then slotCount(session.index) else nil,
		})
	end
	table.sort(rows, function(a, b) return tostring(a.name) < tostring(b.name) end)
	return rows
end

local function filterCityName(player: Player, raw: any): string
	if typeof(raw) ~= "string" then return DEFAULT_CITY_NAME end

	local name = string.gsub(raw, "^%s+", "")
	name = string.gsub(name, "%s+$", "")
	name = string.sub(name, 1, MAX_NAME_LENGTH)
	if #name == 0 then return DEFAULT_CITY_NAME end

	local ok, filtered = pcall(function()
		local result = TextService:FilterStringAsync(name, player.UserId)
		return result:GetNonChatStringForBroadcastAsync()
	end)

	if not ok or typeof(filtered) ~= "string" or #filtered == 0 then
		return DEFAULT_CITY_NAME
	end

	return filtered
end

local function cooldownOk(userId: number): boolean
	local now = os.clock()
	local last = _lastRemoteAt[userId]
	if last and now - last < REMOTE_COOLDOWN then
		return false
	end
	_lastRemoteAt[userId] = now
	return true
end

local function currentPopulation(): number
	-- ponytail: slot-card population comes from CityStatsService (already a dep);
	-- dropped the redundant CitizenService edge (architecture audit 2026-06-23).
	if _cityStatsService and _cityStatsService.getPopulation then
		local ok, result = pcall(_cityStatsService.getPopulation)
		if ok and typeof(result) == "number" then
			return math.max(0, math.floor(result + 0.5))
		end
	end

	return 0
end

local CAMERA_COORD_LIMIT = 100000

local function roundedCameraNumber(n: number): number
	return math.floor(n * 100 + 0.5) / 100
end

local function finiteCameraNumber(value: any): number?
	local n = tonumber(value)
	if not n or n ~= n or math.abs(n) > CAMERA_COORD_LIMIT then
		return nil
	end
	return n
end

local function cameraVector(value: any): Vector3?
	if typeof(value) == "Vector3" then
		if math.abs(value.X) > CAMERA_COORD_LIMIT or math.abs(value.Y) > CAMERA_COORD_LIMIT or math.abs(value.Z) > CAMERA_COORD_LIMIT then
			return nil
		end
		return value
	end
	if typeof(value) ~= "table" then
		return nil
	end
	local x = finiteCameraNumber(value.x or value.X or value[1])
	local y = finiteCameraNumber(value.y or value.Y or value[2])
	local z = finiteCameraNumber(value.z or value.Z or value[3])
	if not x or not y or not z then
		return nil
	end
	return Vector3.new(x, y, z)
end

local function sanitizeCameraState(payload: any): any?
	local pos: Vector3? = nil
	local yaw: number? = nil
	local pitch: number? = nil

	if typeof(payload) == "Vector3" then
		pos = cameraVector(payload)
	elseif typeof(payload) == "table" then
		pos = cameraVector(payload.pos or payload.p)
		yaw = finiteCameraNumber(payload.yaw or payload.y)
		pitch = finiteCameraNumber(payload.pitch or payload.pi)
	end

	if not pos then return nil end

	return {
		p = { roundedCameraNumber(pos.X), roundedCameraNumber(pos.Y), roundedCameraNumber(pos.Z) },
		y = if yaw then roundedCameraNumber(yaw) else nil,
		pi = if pitch then roundedCameraNumber(math.clamp(pitch, -89, 89)) else nil,
	}
end

local function onReportCameraState(player: Player, payload: any)
	local userId = player.UserId
	local session = _sessions[userId]
	if not session or not session.activeSlot or _cityOwnerUserId ~= userId then return end

	local state = sanitizeCameraState(payload)
	if state then
		_cameraStateByUserId[userId] = state
	end
end

-- ---------- saving ----------

-- Safety net for LEGACY-layout saves (a generation-layout save keeps the city as the
-- session loaded it by itself, see Generations): once per server session, copy the slot blob AS LOADED to "<slot>_bak"
-- before the first overwrite. A buggy serializer / half-wiped city can then never
-- destroy the only copy of a save. Best-effort and never blocks the save itself.
-- ponytail: recovery is manual (read the _bak key); add an admin restore if it's ever needed twice.
local _bakDone: { [string]: boolean } = {}
local function backupSlotOnce(userId: number, slotId: number)
	local store = _store
	if not store then return end
	local key = tostring(userId) .. ":" .. tostring(slotId)
	if _bakDone[key] then return end
	-- A generation-layout save already keeps the city as this session loaded it.
	local g = _slotGen[key]
	if g and g.loaded >= 0 then _bakDone[key] = true return end
	local ok = pcall(function()
		local raw = store:GetAsync(slotKey(userId, slotId))
		if raw ~= nil then
			store:UpdateAsync(slotKey(userId, slotId) .. "_bak", function() return raw end)
		end
	end)
	if ok then _bakDone[key] = true end
end

-- Returns a human message if this save must NOT be written, else nil. Guards the
-- per-city cap, the per-player total, and the absolute 1 MB ceiling.
local function budgetReject(index: IndexData, slotId: number, blobBytes: number): string?
	if blobBytes > MAX_SLOT_BYTES then
		return string.format("this city is %d KB, over the %d KB per-city limit", blobBytes // 1024, MAX_SLOT_BYTES // 1024)
	end
	local total = blobBytes
	for id, m in index.slots do
		if id ~= tostring(slotId) then
			total += math.max(0, tonumber(m.bytes) or 0)
		end
	end
	if total > HARD_CEILING then
		return string.format("1 MB hard ceiling reached (%d KB) -- refusing to save", total // 1024)
	end
	if total > MAX_PLAYER_BYTES then
		return string.format("your saves total %d KB, over the %d KB per-player limit", total // 1024, MAX_PLAYER_BYTES // 1024)
	end
	return nil
end

local function saveActiveSlot(userId: number, release: boolean): boolean
	local session = _sessions[userId]
	if not session or not session.activeSlot then return false end
	if _cityOwnerUserId ~= userId then return false end
	if _adminCopy and _adminCopy.adminUserId == userId then return false end
	if _saving[userId] then
		if release then
			_releaseRequested[userId] = true
		end
		return false
	end

	_saving[userId] = true
	_saveDiag.inProgress += 1
	_saveDiag.lastReason = if release then "release" else "save"
	local started = os.clock()
	local blobBytes = 0

	local okAll = false
	local ok, err = pcall(function()
		local slotId = session.activeSlot :: number
		local meta = session.index.slots[tostring(slotId)]
		if not meta then return end

		local now = os.time()
		meta.population = currentPopulation()

		-- Every save path runs through here (manual, autosave, leave), so the player's
		-- all-time best population keeps up with the city even if they never press Save.
		-- "max" mode means a shrinking city never lowers it.
		if _playerStatsService then
			local owner = Players:GetPlayerByUserId(userId)
			if owner then
				_playerStatsService.bump(owner, "peakPopulation", meta.population)
			end
		end
		meta.lastPlayedTimestamp = now
		meta.lastVersion = tonumber(meta.lastVersion) or 1
		if session.sessionStartClock then
			meta.playtimeSeconds = (meta.playtimeSeconds or 0) + math.floor(os.clock() - session.sessionStartClock)
			session.sessionStartClock = os.clock()
		end
		session.index.lastPlayedSlot = slotId

		-- Last-chance heal: a session that joined read-only may have a healthy store
		-- by now -- recovering here rescues the whole session's city at save time.
		if not session.persistent and not healPersistence(userId) then
			okAll = true
			return
		end

		local shouldRelease = release or _releaseRequested[userId] == true
		local blob = _serializer.serialize(meta.mapId, meta.difficulty, _cameraStateByUserId[userId])
		-- Budget against what DataStore actually stores: the packed buffer plus its
		-- ~25% binary-in-JSON storage overhead (measured: 547-byte buffer -> 677 stored).
		local packed = BlobCodec.pack(blob)
		blobBytes = math.ceil(buffer.len(packed) * STORED_OVERHEAD)

		-- Data-budget guard. Never store a city over the per-city cap, and never
		-- let a player's saves cross the per-player budget or the 1 MB ceiling.
		-- On reject we skip only the blob write: the player keeps playing, the
		-- last good save stays intact, and nobody is kicked.
		-- Suspicious shrink: warn loudly (never block -- bulldozing a city is legal) so a
		-- serializer bug that silently empties a section is noticed the day it ships.
		local prevBytes = math.max(0, tonumber(meta.bytes) or 0)
		if prevBytes > 8192 and blobBytes < prevBytes * 0.2 then
			warn(string.format("[CitySlotService] save for %d shrank %d KB -> %d KB -- the city as this session loaded it is still stored", userId, prevBytes // 1024, blobBytes // 1024))
		end

		local reject = budgetReject(session.index, slotId, blobBytes)
		_saveDiag.rejected = reject or ""
		if reject then
			warn(string.format("[CitySlotService] save REJECTED for %d: %s", userId, reject))
			-- Tell the owner their city stopped saving so it never fails silently.
			local owner = Players:GetPlayerByUserId(userId)
			if owner and _notifyRemote then
				_notifyRemote:FireClient(owner, { text = "City not saved -- " .. reject, kind = "danger", duration = 8 })
			end
			Telemetry.custom("SaveRejectedSize", blobBytes // 1024, owner)
			-- Still release the lock on a leaving player so the slot is not stranded.
			if shouldRelease then
				writeIndex(userId, session.index, true)
				_releaseRequested[userId] = nil
			end
			okAll = false
			return
		end

		-- Update meta BEFORE the index write so the persisted per-player byte totals
		-- reflect this save (the budget guard reads them), not the previous one.
		meta.lastVersion = blob.version
		meta.bytes = blobBytes
		backupSlotOnce(userId, slotId)
		local wroteIndex = writeIndex(userId, session.index, false)
		local wroteSlot = writeSlotBlob(userId, slotId, packed)
		if shouldRelease then
			wroteIndex = writeIndex(userId, session.index, true) and wroteIndex
			_releaseRequested[userId] = nil
		end
		okAll = wroteSlot and wroteIndex
	end)

	_saving[userId] = nil
	_saveDiag.inProgress = math.max(0, _saveDiag.inProgress - 1)
	_saveDiag.lastAt = os.time()
	_saveDiag.lastMs = (os.clock() - started) * 1000
	_saveDiag.lastBytes = blobBytes
	_saveDiag.lastOk = ok and okAll
	_saveDiag.lastError = if ok then (if okAll then "" else "write failed") else tostring(err)

	if not ok then
		warn("[CitySlotService] save failed for " .. userId .. ": " .. tostring(err))
		return false
	end

	return okAll
end

-- ---------- city load ----------

local function fireLoadResult(player: Player, ok: boolean, payload: { [string]: any }?)
	local body = payload or {}
	body.ok = ok
	_loadResultRemote:FireClient(player, body)
end

-- Starts the city-sim tick/broadcast loops (clock, economy, transit) the first
-- time a city is actually loaded on this server. Before this point they must
-- stay dormant -- there is no city for them to simulate yet (see header comment).
local function startCitySimIfNeeded()
	if _citySimStarted then return end
	_citySimStarted = true
	if _timeService then _timeService.Start() end
	if _cityEconomyService then _cityEconomyService.Start() end
	if _transitService then _transitService.Start() end
end

-- ownerId is set ONLY on a guest load: the city, its slot index and every save belong to
-- the owner, while the loading player is just who asked and who gets told the result.
local function performLoad(player: Player, slotId: number, ownerId: number?)
	local userId = ownerId or player.UserId
	local session = _sessions[userId] :: Session
	local tLoad0 = os.clock()
	-- The client asks for terrain the moment it asks for the city, so that it can paint the
	-- ground while this runs. Claim the gate before anything is restored, or that request
	-- is answered off the city currently standing here.
	if _terrainDataService and _terrainDataService.beginCityLoad then
		_terrainDataService.beginCityLoad()
	end

	-- Heal a read-only session BEFORE the meta lookup (the heal swaps session.index).
	-- If the store is still broken, say so loudly NOW -- never let a player build a
	-- city for an hour without knowing it cannot save.
	if not session.persistent and not healPersistence(userId) then
		if _notifyRemote then
			_notifyRemote:FireClient(player, {
				text = "Saves are unavailable this session -- your city will NOT save. Rejoin to fix.",
				kind = "danger", duration = 12,
			})
		end
	end

	local meta = session.index.slots[tostring(slotId)]

	if not meta then
		_loadInProgress = false
		if _terrainDataService and _terrainDataService.endCityLoad then _terrainDataService.endCityLoad() end
		fireLoadResult(player, false, { error = "That city does not exist." })
		return
	end

	-- Switching city without rejoining: bank the one that is standing before anything
	-- replaces it, then let go of its slot -- from here the world belongs to the incoming
	-- city, and a leave or autosave mid-build must not write it over the outgoing save.
	if _cityLoaded and session.activeSlot and session.activeSlot ~= slotId then
		-- An autosave already in flight is serializing the LIVE city into the outgoing slot.
		-- Tearing down under it would write a half-erased city over a good save, so wait for
		-- it, and refuse the switch rather than race it if it does not land.
		local deadline = os.clock() + 15
		while _saving[userId] and os.clock() < deadline do
			task.wait(0.2)
		end
		if _saving[userId] then
			_loadInProgress = false
			fireLoadResult(player, false, { error = "Still saving your city. Try again in a moment." })
			return
		end
		saveActiveSlot(userId, false)
		session.activeSlot = nil
	end

	-- One replicated flag every consumer reads -- server sims (economy, demand, unlocks)
	-- and every client HUD. Set before the city restores so nothing ticks a normal-rules
	-- frame first.
	workspace:SetAttribute("Sandbox", meta.sandbox == true)
	-- Hand the city's own identity to the join gate: WHICH city (access is per city, so
	-- this picks the guest list) and whether it is shared at all. Guests were admitted
	-- against an unknown city -- the gate runs long before this -- so anyone the city that
	-- actually loaded does not admit is turned out at this point.
	if _placeAccess then
		_placeAccess.setCityContext(slotId, meta.multiplayer == true)
	end

	-- The side this city drives on, chosen when it was created. Applied BEFORE the roads
	-- restore so the nav graph is built on the right side of the centreline first time.
	-- A city saved before the field existed loads on the default. RoadRules only fires its
	-- listeners when the value actually changes, so loading onto the same side is free.
	RoadRules.setDrivingSide(meta.drivingSide or RoadRules.DEFAULT_DRIVING_SIDE)

	local blob, readOk = readSlotBlob(userId, slotId)
	if not readOk then
		_loadInProgress = false
		if _terrainDataService and _terrainDataService.endCityLoad then _terrainDataService.endCityLoad() end
		fireLoadResult(player, false, { error = "Could not read the city save. Try again." })
		return
	end
	local tRead = os.clock()
	local cameraState = if typeof(blob) == "table" and typeof(blob.camera) == "table" then sanitizeCameraState(blob.camera) else nil

	local preset = MapPresets.getOrDefault(meta.mapId)
	-- Generated maps stored their own knobs in meta.gen; baked presets use the preset.
	local genParams: { [string]: any } = if typeof(meta.gen) == "table"
		then meta.gen
		else { seed = preset.seed, heightRange = preset.relief }
	local effRelief = tonumber(genParams.heightRange) or preset.relief

	-- The map's authored template (if any) is the terrain diff base for BOTH branches:
	-- an existing save may be tpl-marked (delta vs the template), and every save this
	-- session diffs against it. Cached in MapTemplateService after the first read.
	local template = if _mapTemplateService then _mapTemplateService.get(preset.id) else nil
	_terrainDataService.setTemplateTerrain(if typeof(template) == "table" then template.terrain else nil)

	local loadedOk = true
	local loadErr: string? = nil

	if typeof(blob) == "table" then
		-- restore yields and can throw (terrain/roads); a stray error must never
		-- strand _loadInProgress, or this server rejects all loads until restart.
		local pcallOk, ok, err = pcall(_serializer.restore, blob, effRelief)
		loadedOk = pcallOk and ok == true
		loadErr = if pcallOk then err else tostring(ok)
	else
		-- Fresh slot: no save yet. If this map has an authored DEFAULT template, start
		-- from it (a full physical city); otherwise generate the procedural base terrain.
		if typeof(template) == "table" then
			-- restore() resets the clock + economy itself (time/economy keys are absent from
			-- a physical template), so the player's money + calendar start fresh, and it
			-- re-derives the edge connections from the template's roads.
			local pcallOk, okR, errR = pcall(_serializer.restore, template, effRelief)
			loadedOk = pcallOk and okR == true
			loadErr = if pcallOk then errR else tostring(okR)
		else
			local ok, err = pcall(function()
				if _cityLoaded then
					-- A city is standing and this one has no save to restore over it. Run the
					-- normal restore path with an EMPTY blob: every service clears its own
					-- domain, exactly as it does when a saved city loads over another, and the
					-- terrain record carries this map's gen params so the ground is generated
					-- once rather than twice.
					local okR, errR = _serializer.restore({
						version = 1,
						terrain = { seed = genParams.seed, params = genParams },
					})
					if not okR then error(errR or "could not clear the loaded city") end
				else
					_terrainDataService.generateNewCity(genParams)
				end
			end)
			loadedOk = ok
			loadErr = if ok then nil else tostring(err)
			-- New city: start the clock at the fixed date (noon, 25 May 2026).
			if ok and _timeService then
				_timeService.reset()
			end
			-- A new map arrives DRESSED: the preset highways this slot was created with, and
			-- the trees and rocks that grow on land nobody has built on. Both are ordinary
			-- roads and props from here on -- they save and they bulldoze -- so this runs on
			-- the fresh branch only, never over a city that carries its own saved copy.
			local startPoint: Vector3? = nil
			if ok and _mapSeedService then
				local dressed, startAt = pcall(_mapSeedService.seed, genParams, meta.highways)
				if not dressed then
					warn("[CitySlotService] map seeding failed: " .. tostring(startAt))
				elseif typeof(startAt) == "Vector3" then
					startPoint = startAt
					-- Open the city ON its starting interchange. The seeder puts that wherever
					-- the best land is rather than at the origin, so without this a new player
					-- looks at empty ground and has to go and find the road they were given.
					-- The offsets are FreeCamController's own START_POS / YAW / PITCH, re-based
					-- onto the junction instead of onto (0,0,0).
					cameraState = sanitizeCameraState({
						pos = startAt + Vector3.new(0, 120, 80),
						yaw = 180,
						pitch = -45,
					})
				end
			end
			-- The city's FIRST tile: the one its starting interchange stands on. Granted
			-- UNCONDITIONALLY on a fresh city, including when nothing was laid (no preset
			-- highways, or nowhere worth opening on) -- a city owning no land at all could
			-- never place anything, which is not a game. It also CLEARS whatever the
			-- previous city in this server held, so land is never inherited.
			if ok and _territoryService then
				pcall(_territoryService.startAt, startPoint or Vector3.zero)
			end
			-- Edge connections are derived from road geometry: with no preset highways there
			-- is nothing to find yet, and with them the runs reach the boundary and register.
			if ok and _outsideConnectionService then
				pcall(_outsideConnectionService.seedDefaults, preset.id)
			end
		end
	end

	local tRestore = os.clock()
	-- Belt and braces: loadState clears this itself on the saved-city path, but a fresh
	-- city and a restore that threw both reach here without having gone through it.
	if _terrainDataService and _terrainDataService.endCityLoad then
		_terrainDataService.endCityLoad()
	end

	if not player.Parent then
		-- Owner gone mid-build: whatever was standing is torn down, so the server holds no
		-- city any more. Leaving the flag set would refuse every later load until restart.
		_cityLoaded = false
		_loadInProgress = false
		return
	end

	if not loadedOk then
		_cityLoaded = false -- same as above: a failed build leaves no city standing
		_loadInProgress = false
		fireLoadResult(player, false, { error = loadErr or "City load failed." })
		return
	end

	_cityLoaded = true
	_cityOwnerUserId = userId
	_adminCopy = nil
	startCitySimIfNeeded()

	-- Terrain is no longer painted or replicated by the server on load: each client builds
	-- the base map locally from the seed and overwrites the edited chunks (TerrainDataService
	-- stream + the client TerrainBuildController). Discard the base render-dirty so the
	-- per-frame pump never paints it, then enable painting so LATER live edits still render
	-- server-side and replicate.
	if _terrainRenderer then
		if _terrainRenderer.discardPending then _terrainRenderer.discardPending() end
		if _terrainRenderer.enableEditPainting then _terrainRenderer.enableEditPainting() end
	end

	_loadInProgress = false

	-- The city's owner is the only player allowed to edit it. On a published
	-- server (RoadEditOpen off) this attribute is the sole edit gate for roads,
	-- zones and terrain, so grant it on load and invalidate the middleware cache
	-- so the first edit check sees it instead of a stale "not set".
	player:SetAttribute("CanEditRoads", true)
	NetMiddleware.InvalidateCachedAttribute(player, "CanEditRoads")
	-- On a reserved city server rights are per ROLE, not "whoever loaded it" -- the loader
	-- may be a builder, and everyone else already standing here needs stamping too.
	-- applyEditRights is a no-op in Studio and on a public server, where the two lines
	-- above remain the whole story.
	if _placeAccess then
		for _, p in Players:GetPlayers() do
			_placeAccess.applyEditRights(p)
		end
	end

	session.activeSlot = slotId
	session.sessionStartClock = os.clock()
	session.index.lastPlayedSlot = slotId
	meta.lastPlayedTimestamp = os.time()
	-- Camera is per PLAYER, not per city: on a guest load userId is the owner's.
	_cameraStateByUserId[player.UserId] = cameraState

	if session.persistent then
		task.spawn(writeIndex, userId, session.index, false)
	end

	-- The server half of [CityLoad]. The client cannot see any of this -- it is simply
	-- waiting on it -- so without this a slow load can be blamed but never diagnosed.
	warn(string.format("[CitySlotLoad] %.1fs = read %.1f + restore %.1f + finish %.1f",
		os.clock() - tLoad0, tRead - tLoad0, tRestore - tRead, os.clock() - tRestore))
	Telemetry.funnelStep(1, "city_loaded", player)
	fireLoadResult(player, true, { slot = table.clone(meta), camera = cameraState })
end

-- ---------- friends' cities (lobby) ----------

-- ponytail: two DataStore peeks per friend, so this is capped and cached rather than
-- paged. 40 friends is already 80 reads; raise the cap only with a real cache in front.
local FRIEND_CACHE_SECONDS = 30
local _friendCache: { [number]: { at: number, rows: any } } = {}

-- A friend's cities, and whether this player can actually open one. Every field here is
-- read from the FRIEND's own record -- their guest list, their "friends may visit" flag --
-- so the answer is the friend's decision, never the caller's claim. The caller supplies
-- nothing at all: the friend list comes from Roblox, not from the request.
-- The cities this player has been INVITED to, for the menu's load list.
--
-- This used to walk the caller's Roblox friends list and open one record per friend looking
-- for a role. Two things were wrong with that: an invite is by USERNAME and needs no
-- friendship at all, so inviting someone who is not a Roblox friend granted them access to
-- a city they could never see; and the scan was capped at 40 entries, so a friend sitting
-- past the end of the list silently vanished too. The invite index answers it exactly, in
-- one read -- see PlaceAccessService.invitedOwners.
local function onRequestFriendCities(player: Player): any
	if not _pds or not _placeAccess then return { ok = false, error = "Not available here." } end
	if not cooldownOk(player.UserId) then return { ok = false, error = "Too fast. Try again." } end

	local cached = _friendCache[player.UserId]
	if cached and os.clock() - cached.at < FRIEND_CACHE_SECONDS then
		return { ok = true, friends = cached.rows }
	end

	local rows = {}
	for _, ownerId in _placeAccess.invitedOwners(player.UserId) do
		-- The index says who invited them; the OWNER's own record still decides what they
		-- ARE, and now in WHICH of their cities. A stale edge -- revoked while this player
		-- was away -- resolves to no role anywhere and drops out here, so the index is a
		-- hint, never an authority.
		local stored = _pds.PeekField(ownerId, "visitors")
		local index = readIndexReadonly(ownerId)
		if not index then continue end

		-- Their door: open while they are away only if they said so. Opening a city also
		-- needs build rights -- a visitor can join one, not start one.
		local settings = _pds.PeekField(ownerId, "settings")
		local doorOpen = typeof(settings) == "table"
			and typeof(settings.values) == "table"
			and settings.values.friendsOffline == true

		local me = tostring(player.UserId)
		local slots = {}
		for _, meta in publicSlotList(index) do
			local role = VisitorList.forSlot(stored, meta.slotId)[me]
			-- A SOLO city admits nobody but its owner, so it is not a city this player can
			-- open -- it never reaches their menu at all rather than refusing them at the
			-- door. Staff reach any city through the F4 tools, not through this list.
			if role and meta.multiplayer == true then
				local row = table.clone(meta) :: any
				row.role = role
				row.canOpen = doorOpen and CityRoles.canEdit(role)
				table.insert(slots, row)
			end
		end
		if #slots == 0 then continue end

		local online = Players:GetPlayerByUserId(ownerId)
		local name: string
		if online then
			name = online.Name
		else
			local okName, resolved = pcall(function()
				return Players:GetNameFromUserIdAsync(ownerId)
			end)
			name = if okName and typeof(resolved) == "string" then resolved else tostring(ownerId)
		end

		table.insert(rows, { userId = ownerId, name = name, slots = slots })
	end

	table.sort(rows, function(a, b) return a.name:lower() < b.name:lower() end)
	_friendCache[player.UserId] = { at = os.clock(), rows = rows }
	return { ok = true, friends = rows }
end

-- ---------- remote handlers ----------

-- The city STANDING in this server, if any. nil in the lobby (nothing is ever built there)
-- and nil in a city server that has not loaded one yet. It rides the slot index so an
-- arriving client can walk into what is already here -- see the arrival block at the foot
-- of MainMenuController. Read off the OWNER's session: on a guest load the slot belongs to
-- them, not to whoever asked for it.

local function standingSlotId(): number?
	if not _cityLoaded or not _cityOwnerUserId then return nil end
	local owner = _sessions[_cityOwnerUserId]
	return if owner then owner.activeSlot else nil
end

-- The city standing in THIS server, for the online directory: enough for an admin's list to
-- say "in Riverside, pop 400" rather than just naming a player. nil in a lobby and in a city
-- server that has not loaded one, where the honest answer is that they are in the menu.
function CitySlotService.standingCity(): { [string]: any }?
	local ownerId = _cityOwnerUserId
	if not _cityLoaded or not ownerId then return nil end
	local session = _sessions[ownerId]
	local slotId = session and session.activeSlot
	if not session or not slotId then return nil end
	local meta = session.index.slots[tostring(slotId)]
	return {
		ownerId = ownerId,
		slotId = slotId,
		cityName = if meta then meta.cityName else nil,
		pop = currentPopulation(),
	}
end

local function onRequestSlotIndex(player: Player): any
	local session = _sessions[player.UserId]

	-- Index load runs async on join; block briefly rather than racing it.
	local deadline = os.clock() + 10
	while not session and os.clock() < deadline and player.Parent do
		task.wait(0.1)
		session = _sessions[player.UserId]
	end

	if not session then
		return { slots = {}, lastPlayedSlot = nil, maxSlots = MAX_CREATE_SLOTS, persistent = false }
	end

	-- A guest in somebody's city gets THAT city's list, not their own. Not cosmetic: slot
	-- ids are per-player, so a menu showing the guest's own cities would have them pick
	-- "slot 2" and open the OWNER's slot 2. publicSlotList strips everything but the
	-- display fields, and readOnly tells the menu to drop New / Delete / Rename -- all
	-- three of which are refused server-side below regardless of what the client shows.
	local ownerId = guestOwnerId(player.UserId)
	if ownerId then
		local ownerIndex = _sessions[ownerId] and _sessions[ownerId].index or readIndexReadonly(ownerId)
		if not ownerIndex then
			return { slots = {}, lastPlayedSlot = nil, maxSlots = 0, persistent = false, readOnly = true }
		end
		return {
			slots = publicSlotList(ownerIndex),
			lastPlayedSlot = nil,
			maxSlots = 0,
			persistent = false,
			readOnly = true,
			standingSlot = standingSlotId(),
		}
	end

	return {
		slots = publicSlotList(session.index),
		lastPlayedSlot = session.index.lastPlayedSlot,
		maxSlots = MAX_CREATE_SLOTS,
		persistent = session.persistent,
		standingSlot = standingSlotId(),
	}
end

-- Refused for a guest, on every index-mutating remote. The client is told to hide these
-- buttons, but hiding is not a permission check -- and without this a guest pressing NEW
-- in somebody's city would silently create or delete a city in their OWN slots.
local function refuseIfGuest(player: Player): string?
	if guestOwnerId(player.UserId) then
		return "You are a guest in this city. Manage your own cities from the main menu."
	end
	return nil
end

local function onRequestCreateSlot(player: Player, payload: any): (boolean, any)
	local userId = player.UserId
	if not cooldownOk(userId) then return false, "Too fast. Try again." end
	local guestErr = refuseIfGuest(player)
	if guestErr then return false, guestErr end

	local session = _sessions[userId]
	if not session then return false, "Session not ready." end
	if not session.persistent then return false, NONPERSISTENT_MSG end
	if typeof(payload) ~= "table" then return false, "Bad request." end
	if slotCount(session.index) >= MAX_CREATE_SLOTS then return false, "You can have at most 3 cities." end

	local preset = MapPresets.get(if typeof(payload.mapId) == "string" then payload.mapId else "")
	if not preset then return false, "Unknown map." end
	if preset.generated and not MapPresets.PLAYER_MAPS_ENABLED then return false, "Custom maps are not available yet." end

	local difficulty = payload.difficulty
	if typeof(difficulty) ~= "string" or not DIFFICULTIES[difficulty] then return false, "Unknown difficulty." end

	-- Driving side. Stored on the city and applied by RoadRules when the city loads; it is
	-- a player setting and belongs to no theme, so it is validated entirely separately.
	local drivingSide = if payload.drivingSide == "Left" then "Left" else "Right"

	-- The continent theme, fixed for the city's lifetime (lane geometry and building
	-- footprints are baked from it). The client already refuses an unauthored theme, but
	-- this request arrives from the client verbatim, so re-check it here -- accepting a
	-- stub would create a city whose buildings and markings do not exist.
	if payload.theme ~= nil and not WorldThemeCatalog.isSelectable(payload.theme) then
		return false, "That region is not available yet."
	end
	local theme = if payload.theme ~= nil then payload.theme else WorldThemeCatalog.DEFAULT_ID

	-- Sandbox is a property of the CITY, fixed at creation: unlimited money, full demand,
	-- the whole development tree open. Not a runtime toggle -- a save built under those
	-- rules would be meaningless played under the normal ones.
	local sandbox = payload.sandbox == true

	-- Solo or multiplayer, chosen once at creation and stored on the CITY (the reserved
	-- server is per-owner, so this is the only place the distinction can live). Defaults
	-- solo: a city nobody asked to share stays private.
	local multiplayer = payload.multiplayer == true

	-- Preset highways: 0-4 motorways laid across the map the moment it is first generated,
	-- so a premade map is not a blank plank. NOT a terrain knob -- the ground is identical
	-- either way -- so it rides beside difficulty rather than inside `gen`, and it is read
	-- once, on the fresh-city branch. The cap matches MapSeedService.MAX_HIGHWAYS; absent
	-- (a slot created before the option existed) means none.
	local highways = math.clamp(math.floor(tonumber(payload.highways) or 0), 0, 4)

	-- Every map carries gen knobs now (premade buttons just preset them client-side);
	-- bake them into the slot so reloads reproduce the same terrain. All clamped server-side.
	local genParams: { [string]: any }
	do
		local function knob(v: any, default: number, lo: number, hi: number): number
			local n = tonumber(v)
			if not n or n ~= n then return default end
			return math.clamp(n, lo, hi)
		end
		local g = if typeof(payload.gen) == "table" then payload.gen else {}
		local seed = tonumber(g.seed)
		if not seed or seed ~= seed or math.abs(seed) > 1e6 then
			seed = preset.seed -- premade / missing seed falls back to the preset's fixed seed
		end
		genParams = {
			seed = seed,
			heightRange = knob(g.heightRange, preset.relief, 0, 3),
			oceanLevel = knob(g.oceanLevel, 0, 0, 50),
			baseHeight = knob(g.baseHeight, 0, -30, 60),
			ruggedness = knob(g.ruggedness, 0, 0, 1),
			shape = if MapPresets.isShape(g.shape) then g.shape else MapPresets.DEFAULT_SHAPE,
			persistence = knob(g.persistence, 0.5, 0, 1),
			lacunarity = knob(g.lacunarity, 2.0, 1, 4),
			-- Server-stamped, never read from the client: every new city gets the current
			-- generator (TerrainLandform). Old slots keep theirs, because their saved terrain
			-- is a diff against the generator they were made with.
			algo = 3,
		}
	end

	local slotId: number? = nil
	for candidate = 1, MAX_CREATE_SLOTS do
		if not session.index.slots[tostring(candidate)] then
			slotId = candidate
			break
		end
	end
	if not slotId then return false, "All city slots are full." end

	local cityName = filterCityName(player, payload.name)
	local now = os.time()

	session.index.slots[tostring(slotId)] = {
		slotId = slotId,
		cityName = cityName,
		mapId = preset.id,
		difficulty = difficulty,
		population = 0,
		money = 0,
		happiness = 0,
		playtimeSeconds = 0,
		createdTimestamp = now,
		lastPlayedTimestamp = now,
		lastVersion = 1,
		gen = genParams,
		highways = highways,
		drivingSide = drivingSide,
		theme = theme,
		sandbox = sandbox,
		multiplayer = multiplayer,
	}

	if session.persistent and not writeIndex(userId, session.index, false) then
		session.index.slots[tostring(slotId)] = nil
		return false, "Could not save the new city. Try again."
	end

	updateAliasKey(player, session.index)

	-- Invites picked on the create screen. The city did not exist a moment ago, so this is
	-- the earliest its roles can be written -- and founding a city with somebody is exactly
	-- when you name them. Best-effort and per city, like every other grant: a name that will
	-- not resolve loses its invite, never the city.
	if _placeAccess and typeof(payload.invites) == "table" then
		local sent = 0
		for _, entry in payload.invites do
			if sent >= MAX_CREATE_INVITES then break end
			if typeof(entry) == "table" then
				sent += 1
				_placeAccess.ownAccess(player, {
					action = "grant",
					slotId = slotId,
					name = entry.name,
					role = entry.role,
				})
			end
		end
	end

	if _playerStatsService then
		_playerStatsService.bump(player, "citiesCreated")
	end

	return true, { slotId = slotId, cityName = cityName }
end

-- ownerId is set only when the LOBBY is opening somebody else's city. It arrives from
-- the client, so it is proved here against that owner's own stored guest list before it
-- is used for anything -- and the city server re-proves it on arrival regardless.
-- `mode` is staff-only and means "let me in as a visitor rather than a builder". Ignored
-- for everyone else: a player's rights come from the owner's guest list, never from what
-- they ask for.
local function onRequestLoadSlot(player: Player, slotId: any, ownerId: any, mode: any)
	local userId = player.UserId
	local session = _sessions[userId]

	-- A player teleported in from the lobby asks for their city the moment their client
	-- boots, which routinely beats this session's DataStore read -- and the answer would
	-- be "Session not ready" on the one path where the player did nothing wrong. Block
	-- briefly rather than racing it, the same bounded wait onRequestSlotIndex uses.
	local deadline = os.clock() + 10
	while not session and os.clock() < deadline and player.Parent do
		task.wait(0.1)
		session = _sessions[userId]
	end
	if not player.Parent then return end

	if not session then
		fireLoadResult(player, false, { error = "Session not ready." })
		return
	end

	if typeof(slotId) ~= "number" or slotId ~= math.floor(slotId) or slotId < 1 or slotId > MAX_SLOTS then
		fireLoadResult(player, false, { error = "Bad slot." })
		return
	end

	-- GUEST LOAD: a builder or admin opening the owner's city, owner present or not.
	--
	-- The client contributes exactly one thing here -- an integer slot id, already range
	-- checked above and matched against the owner's real index below. Whose city this is
	-- comes from the server's own identity, and what this player may do comes from the
	-- role stored on the OWNER's record. Neither is forgeable from the client, so there is
	-- no message that opens, writes or damages a third party's data.
	local guestOwner = guestOwnerId(userId)
	if guestOwner then
		if _loadInProgress then
			fireLoadResult(player, false, { error = "A city is already loading." })
			return
		end

		-- Walking into a city that is ALREADY standing, checked before the role is: this is
		-- not starting anything, it is being in a room somebody else opened, which is
		-- exactly what a visitor role is for. Checking build rights first is what made a
		-- visitor bounce off a running city with "only a builder can open this".
		if _cityLoaded then
			local standing = _sessions[guestOwner]
			if _cityOwnerUserId == guestOwner and standing and standing.activeSlot == slotId then
				local meta = standing.index.slots[tostring(slotId)]
				fireLoadResult(player, true, { slot = if meta then table.clone(meta) else nil })
			else
				fireLoadResult(player, false, { error = "Another city is already loaded here." })
			end
			return
		end

		if not CityRoles.canEdit(_placeAccess.roleOf(userId)) then
			-- Nothing is standing, so this would START the city -- a change to the owner's
			-- save (timestamps, playtime, the slot lock) and theirs to grant.
			fireLoadResult(player, false, { error = "Only a builder or admin can open this city." })
			return
		end

		if not acquireOwnerSession(guestOwner) then
			fireLoadResult(player, false, { error = "That city is open somewhere else right now." })
			return
		end

		if not (_sessions[guestOwner] :: Session).index.slots[tostring(slotId)] then
			fireLoadResult(player, false, { error = "That city does not exist." })
			return
		end

		_loadInProgress = true
		task.spawn(performLoad, player, slotId, guestOwner)
		return
	end

	-- In the lobby a slot id may belong to a FRIEND's index, checked in that branch; the
	-- caller's own index is only the right thing to check for their own cities.
	if not PlacesConfig.isLobby() and not session.index.slots[tostring(slotId)] then
		fireLoadResult(player, false, { error = "That city does not exist." })
		return
	end

	-- In the LOBBY no city is built here -- it lives in a reserved server of the city
	-- place. Hand the slot to CityTeleport and stop: the load lock, performLoad and the
	-- sim start below all belong to the server that actually holds a city. The arriving
	-- client re-fires this same remote over there, where isLobby() is false.
	if PlacesConfig.isLobby() then
		local targetOwner = player.UserId

		-- Opening a FRIEND's city. The role is read from THEIR record, so the client's
		-- ownerId only selects whose list to check -- it cannot invent a permission. A
		-- stranger's id simply finds no role and is refused, which is also why this
		-- cannot be used to probe whether an account exists.
		local staff = isCityStaff(player)

		if typeof(ownerId) == "number" and ownerId > 0 and ownerId ~= player.UserId then
			if not _pds then
				fireLoadResult(player, false, { error = "Could not open that city." })
				return
			end
			if not staff then
				-- Per CITY: a role in their slot 1 is not a role in their slot 2.
				local stored = _pds.PeekField(ownerId, "visitors")
				local role = VisitorList.forSlot(stored, slotId)[tostring(player.UserId)]
				if not CityRoles.canEdit(role) then
					fireLoadResult(player, false, { error = "You do not have build access to that city." })
					return
				end
			end
			local theirIndex = readIndexReadonly(ownerId)
			local theirMeta = if theirIndex then theirIndex.slots[tostring(slotId)] else nil
			if not theirMeta then
				fireLoadResult(player, false, { error = "That city does not exist." })
				return
			end
			-- A solo city evicts every guest the moment it loads, so sending someone into
			-- one is a teleport straight back out. Refuse here, where it can still be said --
			-- except for staff, whom the gate lets in either way.
			if not staff and theirMeta.multiplayer ~= true then
				fireLoadResult(player, false, { error = "That city is set to solo." })
				return
			end
			targetOwner = ownerId
		elseif not session.index.slots[tostring(slotId)] then
			fireLoadResult(player, false, { error = "That city does not exist." })
			return
		end

		-- Only staff may ask to arrive as a visitor, and only in somebody else's city; for
		-- everyone else the value is dropped rather than carried into the teleport.
		local staffMode = if staff and targetOwner ~= player.UserId and mode == "visitor" then "visitor" else nil
		if not _cityTeleport or not _cityTeleport.enterCity(player, targetOwner, slotId, staffMode) then
			fireLoadResult(player, false, { error = "Could not open that city. Try again." })
		end
		return
	end

	if _loadInProgress then
		fireLoadResult(player, false, { error = "A city is already loading." })
		return
	end

	if _cityLoaded then
		-- Idempotent re-entry: the owner re-requesting the slot that is already loaded
		-- here almost always means the client timed out waiting for CityLoadResult on a
		-- big/slow load and is retrying. Re-fire success so they enter the city that is
		-- already built, instead of stranding them behind "already loaded". Gated on the
		-- build having finished (_loadInProgress false => performLoad set activeSlot in the
		-- same synchronous block, so no race here).
		if _cityOwnerUserId == userId and session.activeSlot == slotId then
			local meta = session.index.slots[tostring(slotId)]
			fireLoadResult(player, true, { slot = if meta then table.clone(meta) else nil })
			return
		end
		-- A DIFFERENT city, asked for by the owner of the one standing: swap to it in place.
		-- performLoad saves the outgoing city and the restore path tears it down, so only
		-- somebody else's city is a reason to refuse now.
		if _cityOwnerUserId ~= userId then
			fireLoadResult(player, false, { error = "Another player's city is loaded on this server." })
			return
		end
	end

	_loadInProgress = true
	task.spawn(performLoad, player, slotId)
end

local function onRequestDeleteSlot(player: Player, slotId: any): (boolean, any)
	local userId = player.UserId
	if not cooldownOk(userId) then return false, "Too fast. Try again." end
	local guestErr = refuseIfGuest(player)
	if guestErr then return false, guestErr end

	local session = _sessions[userId]
	if not session then return false, "Session not ready." end
	if not session.persistent then return false, NONPERSISTENT_MSG end
	if typeof(slotId) ~= "number" or not session.index.slots[tostring(slotId)] then return false, "That city does not exist." end
	if session.activeSlot == slotId then return false, "You cannot delete the city you are playing." end

	local removed = session.index.slots[tostring(slotId)]
	session.index.slots[tostring(slotId)] = nil
	if session.index.lastPlayedSlot == slotId then
		session.index.lastPlayedSlot = nil
	end

	if session.persistent then
		if not writeIndex(userId, session.index, false) then
			session.index.slots[tostring(slotId)] = removed
			return false, "Could not delete the city. Try again."
		end
		task.spawn(removeSlotBlob, userId, slotId)
		updateAliasKey(player, session.index)
	end

	return true, nil
end

local function onRequestRenameSlot(player: Player, slotId: any, name: any): (boolean, any)
	local userId = player.UserId
	if not cooldownOk(userId) then return false, "Too fast. Try again." end
	local guestErr = refuseIfGuest(player)
	if guestErr then return false, guestErr end

	local session = _sessions[userId]
	if not session then return false, "Session not ready." end
	if not session.persistent then return false, NONPERSISTENT_MSG end

	local meta = if typeof(slotId) == "number" then session.index.slots[tostring(slotId)] else nil
	if not meta then return false, "That city does not exist." end

	local filtered = filterCityName(player, name)
	local previous = meta.cityName
	meta.cityName = filtered

	if session.persistent and not writeIndex(userId, session.index, false) then
		meta.cityName = previous
		return false, "Could not rename the city. Try again."
	end

	return true, filtered
end

-- Solo or shared, for ONE of the caller's own cities. Chosen when the city was created and
-- editable ever since: a city made solo before anyone asked to visit would otherwise be
-- locked out of multiplayer for good, with no way back but starting a new save.
--
-- `slotId` names the city and is how Load City reaches one that is not standing anywhere.
-- Without it this is the city loaded HERE, which is what the Control Room asks about.
-- `on` nil reads without writing -- that is how both render the control.
--
-- Turning it OFF is not just a flag: setCityContext evicts the guests a solo city excludes,
-- exactly as it does when one loads -- but only for the city actually standing here.
local function onRequestCitySharing(player: Player, on: any, slotId: any): any
	local userId = player.UserId
	if not cooldownOk(userId) then return { ok = false, error = "Too fast. Try again." } end
	local guestErr = refuseIfGuest(player)
	if guestErr then return { ok = false, error = guestErr } end

	local session = _sessions[userId]
	if not session then return { ok = false, error = "Session not ready." } end

	local target: number? = nil
	if slotId ~= nil then
		if typeof(slotId) ~= "number" or slotId ~= math.floor(slotId) or slotId < 1 or slotId > MAX_SLOTS then
			return { ok = false, error = "Bad slot." }
		end
		target = slotId
	else
		-- Owner of the loaded city only. An admin guest may hand out roles (they are the
		-- owner's own record); whether the city is open at all is not theirs to answer.
		if not _cityLoaded then
			-- The menu reaches this page too, and "you are not the owner" would be a lie there.
			return { ok = false, error = "Open a city to change who can join it." }
		end
		if _cityOwnerUserId ~= userId then
			return { ok = false, error = "Only the owner of this city can change who may join." }
		end
		target = session.activeSlot
	end

	local meta = if target then session.index.slots[tostring(target)] else nil
	if not meta then return { ok = false, error = "That city does not exist." } end

	if typeof(on) ~= "boolean" then
		return { ok = true, multiplayer = meta.multiplayer == true, slotId = target }
	end
	if not session.persistent then return { ok = false, error = NONPERSISTENT_MSG } end

	local previous = meta.multiplayer
	meta.multiplayer = on
	if not writeIndex(userId, session.index, false) then
		meta.multiplayer = previous
		return { ok = false, error = "Could not save that. Try again." }
	end

	-- Only the city STANDING here has a room to empty.
	if _placeAccess and _cityLoaded and _cityOwnerUserId == userId and session.activeSlot == target then
		_placeAccess.setCityContext(target, on)
	end
	return { ok = true, multiplayer = on, slotId = target }
end

local function onRequestSaveCity(player: Player): (boolean, any)
	local userId = player.UserId
	if not cooldownOk(userId) then return false, "Too fast. Try again." end

	local session = _sessions[userId]
	if _adminCopy and _adminCopy.adminUserId == userId then return false, "Admin save copies are in-memory only." end
	if not session or not session.activeSlot then return false, "No city is loaded." end
	if not session.persistent then return false, NONPERSISTENT_MSG end

	if saveActiveSlot(userId, false) then
		return true, os.time()
	end

	return false, "Save failed. It will retry on the next autosave."
end

-- ---------- admin save copy ----------

-- Enumerate every player key in the DataStore and collect their saves.
-- Runs during the blank-query path so the admin sees all cities at once.
local function collectAllSaves(): { any }
	local store = _store
	local rows: { any } = {}
	if not store then return rows end

	-- Build a quick lookup of online sessions so we can enrich with display names.
	local onlineByUserId: { [number]: Player } = {}
	for _, p in Players:GetPlayers() do
		onlineByUserId[p.UserId] = p
	end

	local ok, pages = pcall(function()
		return store:ListKeysAsync("slots_index_")
	end)
	if not ok or not pages then
		warn("[CitySlotService] collectAllSaves: ListKeysAsync failed:", pages)
		return rows
	end

	local function processPage(page: { DataStoreKey })
		for _, keyObj in page do
			local key = keyObj.KeyName
			-- key = "slots_index_{userId}"
			local userIdStr = string.match(key, "^slots_index_(%d+)$")
			if not userIdStr then continue end
			local userId = tonumber(userIdStr)
			if not userId then continue end

			local index = readIndexReadonly(userId)
			if not index then continue end

			local online = onlineByUserId[userId]
			-- Resolve a real username even for offline players
			local resolvedName: string
			if online then
				resolvedName = online.Name
			else
				local nameOk, nameResult = pcall(function()
					return Players:GetNameFromUserIdAsync(userId)
				end)
				resolvedName = if nameOk and typeof(nameResult) == "string" then nameResult else tostring(userId)
			end
			local slots = publicSlotList(index)
			for _, slot in slots do
				table.insert(rows, {
					userId = userId,
					name = resolvedName,
					online = online ~= nil,
					slotId = slot.slotId,
					cityName = slot.cityName,
					population = slot.population,
					lastPlayedTimestamp = slot.lastPlayedTimestamp,
				})
			end
		end
	end

	local pageOk, pageErr = pcall(function()
		processPage(pages:GetCurrentPage())
		while not pages.IsFinished do
			pages:AdvanceToNextPageAsync()
			processPage(pages:GetCurrentPage())
		end
	end)
	if not pageOk then
		warn("[CitySlotService] collectAllSaves: page iteration failed:", pageErr)
	end

	table.sort(rows, function(a, b)
		return tostring(a.name) < tostring(b.name)
	end)
	return rows
end

local function onRequestAdminPlayerSaves(player: Player, query: any): { [string]: any }
	if not isAdmin(player) then
		return { ok = false, error = "Admin only." }
	end

	-- Blank query: enumerate every save in the DataStore.
	if query == nil or (typeof(query) == "string" and trim(query) == "") then
		local allSaves = collectAllSaves()
		return { ok = true, allSaves = allSaves, maxSlots = MAX_SLOTS }
	end

	local sourceUserId, resolveErr = resolveUserQuery(query)
	if not sourceUserId then
		return { ok = false, error = resolveErr or "Could not resolve player." }
	end

	local index = readIndexReadonly(sourceUserId)
	if not index then
		return { ok = false, error = "Could not read that player's saves.", userId = sourceUserId }
	end

	-- Resolve the player's display name for the client status bar.
	local playerName: string
	local onlinePlayer = Players:GetPlayerByUserId(sourceUserId)
	if onlinePlayer then
		playerName = onlinePlayer.Name
	else
		local nameOk, nameResult = pcall(function()
			return Players:GetNameFromUserIdAsync(sourceUserId)
		end)
		playerName = if nameOk and typeof(nameResult) == "string" then nameResult else tostring(sourceUserId)
	end

	return {
		ok = true,
		userId = sourceUserId,
		playerName = playerName,
		saveCount = slotCount(index),
		slots = publicSlotList(index),
		maxSlots = MAX_SLOTS,
	}
end

local function onRequestAdminLoadSaveCopy(player: Player, sourceQuery: any, slotId: any): { [string]: any }
	if not isAdmin(player) then
		return { ok = false, error = "Admin only." }
	end
	if not cooldownOk(player.UserId) then
		return { ok = false, error = "Too fast. Try again." }
	end
	if _loadInProgress then
		return { ok = false, error = "A city is already loading." }
	end

	local sourceUserId, resolveErr = resolveUserQuery(sourceQuery)
	if not sourceUserId then
		return { ok = false, error = resolveErr or "Could not resolve player." }
	end
	if typeof(slotId) ~= "number" or slotId ~= math.floor(slotId) or slotId < 1 or slotId > MAX_SLOTS then
		return { ok = false, error = "Bad slot." }
	end

	local index = readIndexReadonly(sourceUserId)
	local meta = index and index.slots[tostring(slotId)]
	if not meta then
		return { ok = false, error = "That player does not have that save slot." }
	end

	local replacingOwnCopy = _adminCopy and _adminCopy.adminUserId == player.UserId
	if _cityLoaded and not replacingOwnCopy and not RunService:IsStudio() then
		return { ok = false, error = "A live city is already loaded on this server. Use an empty admin server for save copies." }
	end

	local blob, readOk = readSlotBlob(sourceUserId, slotId)
	if not readOk then
		return { ok = false, error = "Could not read the city save." }
	end
	local cameraState = if typeof(blob) == "table" and typeof(blob.camera) == "table" then sanitizeCameraState(blob.camera) else nil

	local preset = MapPresets.getOrDefault(meta.mapId)
	_loadInProgress = true

	-- RemoteFunctions must answer promptly. The restore can legitimately take a while
	-- for a large city, so finish it on a server task and report the real outcome through
	-- CityLoadResult (the same completion channel used by normal city loading).
	task.spawn(function()
		local ok, err = pcall(function()
			local loadedOk = true
			local loadErr: string? = nil
			-- tpl-marked saves need the map template as their terrain base (see performLoad).
			local template = if _mapTemplateService then _mapTemplateService.get(preset.id) else nil
			_terrainDataService.setTemplateTerrain(if typeof(template) == "table" then template.terrain else nil)
			if typeof(blob) == "table" then
				local pcallOk, restoreOk, restoreErr = pcall(_serializer.restore, blob, preset.relief)
				loadedOk = pcallOk and restoreOk == true
				loadErr = if pcallOk then restoreErr else tostring(restoreOk)
			else
				local genOk, genErr = pcall(function()
					_terrainDataService.generateNewCity({ seed = preset.seed, heightRange = preset.relief })
				end)
				loadedOk = genOk
				loadErr = if genOk then nil else tostring(genErr)
				if genOk and _timeService then
					_timeService.reset()
				end
			end

			if not loadedOk then
				error(loadErr or "City load failed.")
			end

			if _terrainRenderer then
				local renderOk, renderErr = pcall(_terrainRenderer.renderAllAndWait)
				if not renderOk then
					warn("[CitySlotService] admin copy terrain pre-render failed:", renderErr)
				end
			end

			_cityLoaded = true
			_cityOwnerUserId = player.UserId
			_adminCopy = {
				adminUserId = player.UserId,
				sourceUserId = sourceUserId,
				sourceSlotId = slotId,
				loadedAt = os.time(),
			}
			startCitySimIfNeeded()

			local session = _sessions[player.UserId]
			if session then
				session.activeSlot = nil
				session.sessionStartClock = nil
			end

			player:SetAttribute("CanEditRoads", true)
			NetMiddleware.InvalidateCachedAttribute(player, "CanEditRoads")

			local slotMeta = table.clone(meta)
			slotMeta.adminCopy = true
			_cameraStateByUserId[player.UserId] = cameraState
			fireLoadResult(player, true, { slot = slotMeta, adminCopy = true, camera = cameraState })
		end)

		_loadInProgress = false
		if not ok then
			local message = tostring(err)
			warn("[CitySlotService] admin save copy load failed: " .. message)
			fireLoadResult(player, false, { error = message, adminCopy = true })
		end
	end)

	return {
		ok = true,
		accepted = true,
		sourceUserId = sourceUserId,
		sourceSlotId = slotId,
		cityName = meta.cityName,
		saveCount = slotCount(index :: IndexData),
	}
end

-- ---------- map default template (F6 dev authoring) ----------

-- Admin action: bake the player's CURRENTLY-LOADED city as the DEFAULT for its map.
-- Stores the physical city (no money / clock / population) via MapTemplateService, so
-- every NEW city started on that map begins from this layout. Yields (DataStore write).
function CitySlotService.saveLoadedCityAsTemplate(player: Player): (boolean, string?)
	if not isAdmin(player) then return false, "Admin only." end
	if not _mapTemplateService then return false, "Map templates are unavailable." end
	local userId = player.UserId
	if _cityOwnerUserId ~= userId then return false, "Load your own city first." end
	if _adminCopy and _adminCopy.adminUserId == userId then
		return false, "Cannot template an admin save-copy. Load your own city."
	end
	local session = _sessions[userId]
	local slotId = session and session.activeSlot
	local meta = slotId and session.index.slots[tostring(slotId)]
	if not meta then return false, "No city is loaded." end
	local mapId = meta.mapId
	if typeof(mapId) ~= "string" then return false, "This city has no map id." end
	local blob = _serializer.serializePhysical(mapId)
	if _mapTemplateService.save(mapId, blob) then
		-- Saves from here on diff against the fresh bake, so the very next autosave
		-- of this city shrinks to just its delta.
		_terrainDataService.setTemplateTerrain(blob.terrain)
		return true, ("Saved as the default for map \"%s\"."):format(mapId)
	end
	return false, "Could not write the map template. Try again."
end

-- ---------- lifecycle ----------

local function ownerUsageBytes(): number
	local userId = _cityOwnerUserId
	local session = if userId then _sessions[userId] else nil
	if not session then return 0 end
	local total = 0
	for _, m in session.index.slots do
		total += math.max(0, tonumber(m.bytes) or 0)
	end
	return total
end

function CitySlotService.DebugSaveStats(): { [string]: any }
	local activeSessions = 0
	local persistentSessions = 0
	local saving = 0
	for userId, session in _sessions do
		activeSessions += 1
		if session.persistent then persistentSessions += 1 end
		if _saving[userId] then saving += 1 end
	end
	local nextAutosaveIn = if _lastAutosaveClock > 0 then math.max(0, AUTOSAVE_INTERVAL - (os.clock() - _lastAutosaveClock)) else AUTOSAVE_INTERVAL
	return {
		activeSessions = activeSessions,
		persistentSessions = persistentSessions,
		saving = saving,
		cityLoaded = _cityLoaded,
		cityOwnerUserId = _cityOwnerUserId,
		adminCopy = _adminCopy ~= nil,
		autosaveInterval = AUTOSAVE_INTERVAL,
		nextAutosaveIn = nextAutosaveIn,
		lastAt = _saveDiag.lastAt,
		lastMs = _saveDiag.lastMs,
		lastOk = _saveDiag.lastOk,
		lastBytes = _saveDiag.lastBytes,
		lastError = _saveDiag.lastError,
		lastReason = _saveDiag.lastReason,
		inProgress = _saveDiag.inProgress,
		rejected = _saveDiag.rejected,
		playerUsageKB = ownerUsageBytes() // 1024,
		slotCapKB = MAX_SLOT_BYTES // 1024,
		playerCapKB = MAX_PLAYER_BYTES // 1024,
		hardCeilingKB = HARD_CEILING // 1024,
	}
end

function CitySlotService.Init(serializer: any, cityStatsService: any, terrainDataService: any, terrainRenderer: any, adminService: any?, timeService: any?, outsideConnectionService: any?, mapTemplateService: any?, cityEconomyService: any?, transitService: any?)
	assert(serializer and cityStatsService and terrainDataService,
		"[CitySlotService] Init requires CitySerializer, CityStatsService and TerrainDataService")
	_serializer = serializer
	_cityStatsService = cityStatsService
	_terrainDataService = terrainDataService
	_terrainRenderer = terrainRenderer
	_adminService = adminService
	_timeService = timeService
	_outsideConnectionService = outsideConnectionService
	_mapTemplateService = mapTemplateService
	_cityEconomyService = cityEconomyService
	_transitService = transitService

	local ok, err = pcall(function()
		_store = DataStoreService:GetDataStore(STORE_NAME)
	end)
	if not ok then
		warn("[CitySlotService] DataStore unavailable:", err)
	end

	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	_loadResultRemote = Net.CityLoadResult
	_notifyRemote = Net.Notify

	Net.RequestCityMemory.OnServerInvoke = onRequestCityMemory
	Net.RequestSlotIndex.OnServerInvoke = onRequestSlotIndex
	Net.RequestCreateSlot.OnServerInvoke = onRequestCreateSlot
	Net.RequestDeleteSlot.OnServerInvoke = onRequestDeleteSlot
	Net.RequestRenameSlot.OnServerInvoke = onRequestRenameSlot
	Net.RequestSaveCity.OnServerInvoke = onRequestSaveCity
	Net.RequestCitySharing.OnServerInvoke = onRequestCitySharing
	Net.RequestAdminPlayerSaves.OnServerInvoke = onRequestAdminPlayerSaves
	Net.RequestAdminLoadSaveCopy.OnServerInvoke = onRequestAdminLoadSaveCopy
	Net.RequestFriendCities.OnServerInvoke = onRequestFriendCities
	Net.RequestLoadSlot.OnServerEvent:Connect(onRequestLoadSlot)
	Net.ReportCameraPos.OnServerEvent:Connect(onReportCameraState)
end

-- The LOBBY half of this service: the slot index, and the remotes that read or edit it.
-- No serializer, no terrain, no sim -- a lobby never builds a city, it teleports into one
-- (see the isLobby branch in onRequestLoadSlot).
--
-- Deliberately a SEPARATE entry point rather than Init with nils. Init's assert is the
-- guarantee that a city server can actually build; feeding it nothing would trade a loud
-- boot failure for a city that silently fails to load hours later.
--
-- Bind() is shared and safe here: a lobby session never sets activeSlot, so the leave and
-- BindToClose paths fall through to writeIndex, which is exactly what a lobby owes a
-- player who just created or renamed a city. Start() is NOT -- it is the autosave loop
-- for a standing city, and there is never one here.
function CitySlotService.InitLobby(adminService: any?)
	_adminService = adminService

	local ok, err = pcall(function()
		_store = DataStoreService:GetDataStore(STORE_NAME)
	end)
	if not ok then
		warn("[CitySlotService] DataStore unavailable:", err)
	end

	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	_loadResultRemote = Net.CityLoadResult
	_notifyRemote = Net.Notify

	-- Index reads and edits only. RequestSaveCity, ReportCameraPos and
	-- RequestAdminLoadSaveCopy are deliberately left unwired: all three act on a city
	-- standing in this server, so in a lobby they would have nothing to act on.
	Net.RequestSlotIndex.OnServerInvoke = onRequestSlotIndex
	Net.RequestCreateSlot.OnServerInvoke = onRequestCreateSlot
	Net.RequestDeleteSlot.OnServerInvoke = onRequestDeleteSlot
	Net.RequestRenameSlot.OnServerInvoke = onRequestRenameSlot
	Net.RequestAdminPlayerSaves.OnServerInvoke = onRequestAdminPlayerSaves
	Net.RequestFriendCities.OnServerInvoke = onRequestFriendCities
	-- Bound here too although a lobby never holds a city: an unassigned OnServerInvoke
	-- yields the caller forever, and the settings page is reachable from the menu. The
	-- handler answers "No city is loaded." here, which is the truth.
	Net.RequestCitySharing.OnServerInvoke = onRequestCitySharing
	Net.RequestLoadSlot.OnServerEvent:Connect(onRequestLoadSlot)
end

-- Late-injected: PlayerStatsService boots after this service. Optional on purpose --
-- a missing stats service must never stop a city being created or saved.
function CitySlotService.SetPlayerStatsService(playerStatsService: any)
	_playerStatsService = playerStatsService
end

-- The lobby's exit. Required there and unused in a city server, so it is a setter rather
-- than an Init argument: a city has no use for it and must not be made to supply one.
function CitySlotService.SetCityTeleport(cityTeleport: any)
	_cityTeleport = cityTeleport
end

-- Late-injected: PlaceAccessService boots before this service but takes CityTeleport,
-- so the wiring is done from Bootstrap in one direction to keep the cycle out of Init.
function CitySlotService.SetPlaceAccessService(placeAccess: any)
	_placeAccess = placeAccess
end

function CitySlotService.SetPlayerDataStore(playerDataStore: any)
	_pds = playerDataStore
end

-- Late-injected: MapSeedService boots after this service. Only the fresh-city branch uses it.
function CitySlotService.SetMapSeedService(mapSeedService: any)
	_mapSeedService = mapSeedService
end

-- Late-injected: TerritoryService boots after this service.
function CitySlotService.SetTerritoryService(territoryService: any)
	_territoryService = territoryService
end

function CitySlotService.Bind()
	Players.PlayerAdded:Connect(function(player)
		task.spawn(loadSession, player)
	end)

	for _, player in Players:GetPlayers() do
		task.spawn(loadSession, player)
	end

	Players.PlayerRemoving:Connect(function(player)
		local userId = player.UserId
		local session = _sessions[userId]
		if not session then
			_lastRemoteAt[userId] = nil
			_releaseRequested[userId] = nil
			_cameraStateByUserId[userId] = nil
			return
		end

		_releaseRequested[userId] = true
		local deadline = os.clock() + 8
		while _saving[userId] and os.clock() < deadline do
			task.wait(0.1)
		end

		-- The owner leaving a city other players are still building in. Everything that
		-- saves this city -- the autosave loop, BindToClose, this very branch -- looks the
		-- city up by _sessions[ownerId], so dropping the session here silently ends all
		-- saving while the work carries on. Bank it now, then KEEP the session so the
		-- server can keep banking it. Not released: the city is still live in this server,
		-- and the slot lock is exactly what stops it being loaded in a second one.
		local cityLivesOn = session.activeSlot ~= nil
			and _cityOwnerUserId == userId
			and #Players:GetPlayers() > 1

		if cityLivesOn then
			saveActiveSlot(userId, false)
			_lastRemoteAt[userId] = nil
			_cameraStateByUserId[userId] = nil
			_releaseRequested[userId] = nil
			return
		end

		if session.activeSlot and _cityOwnerUserId == userId then
			saveActiveSlot(userId, true)
		elseif session.persistent then
			writeIndex(userId, session.index, true)
		end

		if not _saving[userId] then
			_releaseRequested[userId] = nil
		end
		_sessions[userId] = nil
		_lastRemoteAt[userId] = nil
		_cameraStateByUserId[userId] = nil
	end)

	-- The last guest leaving an ownerless city: nobody is left to change it, so bank it
	-- and let the slot lock go. Without this the lock is held until the server shuts
	-- down, and the owner cannot open their own city in the meantime.
	Players.PlayerRemoving:Connect(function(player)
		local ownerId = _cityOwnerUserId
		if not ownerId or player.UserId == ownerId then return end
		if Players:GetPlayerByUserId(ownerId) then return end
		if #Players:GetPlayers() > 1 then return end
		local session = _sessions[ownerId]
		if not session or not session.activeSlot then return end
		saveActiveSlot(ownerId, true)
		_sessions[ownerId] = nil
	end)

	game:BindToClose(function()
		local pending = 0

		for userId, session in _sessions do
			pending += 1
			task.spawn(function()
				_releaseRequested[userId] = true
				local saveDeadline = os.clock() + 8
				while _saving[userId] and os.clock() < saveDeadline do
					task.wait(0.1)
				end

				if session.activeSlot and _cityOwnerUserId == userId then
					saveActiveSlot(userId, true)
				elseif session.persistent then
					writeIndex(userId, session.index, true)
				end

				if not _saving[userId] then
					_releaseRequested[userId] = nil
				end
				pending -= 1
			end)
		end

		local deadline = os.clock() + CLOSE_TIMEOUT
		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

function CitySlotService.Start()
	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_INTERVAL)
			_lastAutosaveClock = os.clock()
			_saveDiag.lastReason = "autosave"

			local ownerId = _cityOwnerUserId
			if _cityLoaded and ownerId and _sessions[ownerId] then
				local ok, err = pcall(saveActiveSlot, ownerId, false)
				if not ok then
					warn("[CitySlotService] autosave failed: " .. tostring(err))
				end
			end
		end
	end)
end

return CitySlotService
