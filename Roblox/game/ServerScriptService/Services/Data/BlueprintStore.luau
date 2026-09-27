--!strict
-- BlueprintStore
-- Player-authored designs: editor creations today, intersections and map designs when
-- something exists to capture them. Each blueprint is one key in its own DataStore, so a
-- design gets the whole 4 MB value limit to itself instead of sharing the player record's.
--
-- Keys are "bp_<ownerId>_<time>_<rand>" and deliberately do NOT contain the owner's name:
-- Roblox usernames change, and a key that moves loses the record. Owner id AND name are
-- stamped inside the value instead -- that is what makes a key identifiable when browsing
-- the store, without tying storage to a name that can change under it.
--
-- The player record holds only the INDEX: one small row per blueprint (id, name, size,
-- date, plus whatever the producer puts in meta). That is enough to list what a player
-- owns without reading a single blob; blobs are read one at a time, on open.

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local BlobCodec = require(script.Parent.BlobCodec)

if not RunService:IsServer() then
	error("[BlueprintStore] Must only be required on the server")
end

local STORE_NAME  = "CityDistrict_Blueprints_v2"
local KEY_PREFIX  = "bp_"
local FIELD_INDEX = "blueprints"
local MAX_RETRIES = 3
local RETRY_DELAY = 2
-- A DataStore value caps at 4 MB; leave headroom for the record wrapped around the blob.
local MAX_BYTES   = 3900000
local MAX_NAME    = 60

local KINDS = table.freeze({ creation = true, building = true, intersection = true, map = true })

export type Blueprint = {
	id: string,
	kind: string,
	name: string,
	ownerId: number,
	ownerName: string,
	created: number,
	blob: any,
}

export type IndexEntry = {
	id: string,
	kind: string,
	name: string,
	ts: number,
	bytes: number,
	meta: any,
}

local BlueprintStore = {}

local _store: DataStore? = nil
local _playerDataStore: any = nil

local function keyFor(id: string): string
	return KEY_PREFIX .. id
end

-- Owner id leads so a store browse groups one player's blueprints together; the random
-- tail is what makes it unique. save() proves uniqueness on write rather than trusting it.
local function newId(userId: number): string
	return string.format("%d_%d_%04d", userId, os.time(), math.random(0, 9999))
end

local function readIndex(userId: number): { any }
	local list = _playerDataStore.GetField(userId, FIELD_INDEX)
	return if typeof(list) == "table" then list else {}
end

function BlueprintStore.Init(playerDataStore: any)
	if not playerDataStore then
		error("[BlueprintStore] Init requires PlayerDataStore")
	end
	_playerDataStore = playerDataStore

	local ok, err = pcall(function()
		_store = DataStoreService:GetDataStore(STORE_NAME)
	end)
	if not ok then
		warn("[BlueprintStore] DataStore unavailable: " .. tostring(err))
	end
end

-- Writes a new blueprint and adds its row to the owner's index. Yields.
-- `meta` is producer-owned and rides the index row, so a listing never reads a blob.
-- Returns the new id, or nil plus a player-facing reason.
function BlueprintStore.save(owner: Player, kind: string, name: string, blob: any, meta: any?): (string?, string?)
	local store = _store
	if not store then return nil, "Blueprints are unavailable right now." end
	if not KINDS[kind] then return nil, "Unknown blueprint kind." end
	if typeof(name) ~= "string" or name:gsub("%s", "") == "" then return nil, "Blueprint needs a name." end
	if typeof(blob) ~= "table" then return nil, "Blueprint is empty." end

	local record: Blueprint = {
		id = "",
		kind = kind,
		name = name:sub(1, MAX_NAME),
		ownerId = owner.UserId,
		ownerName = owner.Name,
		created = os.time(),
		blob = blob,
	}

	for attempt = 1, MAX_RETRIES do
		local id = newId(owner.UserId)
		record.id = id

		-- Repacking per attempt is wasted work only on an id collision or a failed write,
		-- and both are rare enough not to justify splitting this into two loops.
		local packed = BlobCodec.pack(record)
		local bytes = buffer.len(packed)
		if bytes > MAX_BYTES then
			return nil, "That design is too large to save."
		end

		local taken = false
		local ok, err = pcall(function()
			store:UpdateAsync(keyFor(id), function(old)
				if old ~= nil then
					taken = true
					return nil -- abort: never overwrite an existing blueprint
				end
				return packed
			end)
		end)

		if ok and not taken then
			local list = readIndex(owner.UserId)
			table.insert(list, {
				id = id, kind = kind, name = record.name,
				ts = record.created, bytes = bytes, meta = meta,
			})
			_playerDataStore.SetField(owner.UserId, FIELD_INDEX, list)
			return id, nil
		end

		if not ok then
			warn(string.format("[BlueprintStore] save attempt %d/%d failed for %q: %s", attempt, MAX_RETRIES, id, tostring(err)))
			if attempt < MAX_RETRIES then task.wait(RETRY_DELAY * attempt) end
		end
	end

	return nil, "Could not save that design."
end

-- Reads one blueprint. Yields. Returns nil if it does not exist or the store is down.
-- ponytail: uncached -- one GetAsync per open. Add an LRU here if a browse UI ever reads
-- the same ids in a loop.
function BlueprintStore.get(id: string): Blueprint?
	local store = _store
	if not store then return nil end
	if typeof(id) ~= "string" or id == "" then return nil end

	for attempt = 1, MAX_RETRIES do
		local ok, result = pcall(function()
			return store:GetAsync(keyFor(id))
		end)

		if ok then
			local record = BlobCodec.unpack(result)
			return if typeof(record) == "table" then record else nil
		end

		warn(string.format("[BlueprintStore] read attempt %d/%d failed for %q: %s", attempt, MAX_RETRIES, id, tostring(result)))
		if attempt < MAX_RETRIES then task.wait(RETRY_DELAY * attempt) end
	end

	return nil
end

-- The player's own index rows. Cheap: no DataStore traffic, the record is already loaded.
function BlueprintStore.list(userId: number): { any }
	return readIndex(userId)
end

function BlueprintStore.owns(userId: number, id: string): boolean
	for _, entry in readIndex(userId) do
		if typeof(entry) == "table" and entry.id == id then return true end
	end
	return false
end

-- Deletes one of the player's own blueprints. The index row goes first: an orphaned key
-- is invisible and harmless, while a row pointing at a deleted key is a broken entry in
-- the player's list. Only what is in the caller's own index can be removed. Yields.
function BlueprintStore.remove(owner: Player, id: string): boolean
	if typeof(id) ~= "string" or id == "" then return false end

	local list = readIndex(owner.UserId)
	local at: number? = nil
	for i, entry in list do
		if typeof(entry) == "table" and entry.id == id then
			at = i
			break
		end
	end
	if not at then return false end

	table.remove(list, at)
	_playerDataStore.SetField(owner.UserId, FIELD_INDEX, list)

	local store = _store
	if store then
		local ok, err = pcall(function()
			store:RemoveAsync(keyFor(id))
		end)
		if not ok then
			-- The player's list is already correct; the key just leaks.
			warn(string.format("[BlueprintStore] remove failed for %q: %s", id, tostring(err)))
		end
	end

	return true
end

return BlueprintStore
