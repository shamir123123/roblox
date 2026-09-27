--!strict
-- MapTemplateService
-- Owns the per-map DEFAULT city templates: a full PHYSICAL city blob (terrain, roads,
-- zones, buildings, service buildings, transit -- see CitySerializer.serializePhysical)
-- stored once per mapId. When a player starts a NEW city on a map that has a template,
-- CitySlotService restores the template instead of generating empty procedural terrain,
-- so the player begins on a pre-built city (its economy / clock / population start fresh).
--
-- Authored live: an admin builds a city, then the F6 dev panel saves it here. Stored in
-- its own DataStore (not the player slot store), keyed by mapId. Cached in memory so the
-- common new-city read costs nothing after the first hit. Templates are READ on every
-- server; WRITTEN only by the admin action.

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local BlobCodec = require(script.Parent.BlobCodec)

if not RunService:IsServer() then
	error("[MapTemplateService] Must only be required on the server")
end

local STORE_NAME = "CityDistrict_MapTemplates_v2"
local KEY_PREFIX = "template_"
local MAX_RETRIES = 3
local RETRY_DELAY = 2

local MapTemplateService = {}

local _store: DataStore? = nil
-- Cache: mapId -> blob (table) when present, or false when looked up and absent.
-- nil = not yet looked up. Keeps the common new-city read free after the first hit.
local _cache: { [string]: any } = {}

local function keyFor(mapId: string): string
	return KEY_PREFIX .. mapId
end

function MapTemplateService.Init()
	local ok, err = pcall(function()
		_store = DataStoreService:GetDataStore(STORE_NAME)
	end)
	if not ok then
		warn("[MapTemplateService] DataStore unavailable: " .. tostring(err))
	end
end

-- Read a map's template (cached). Returns the blob, or nil if the map has none / the
-- store is unreachable. Yields on the first lookup per mapId.
function MapTemplateService.get(mapId: string?): any
	if typeof(mapId) ~= "string" or mapId == "" then return nil end
	local cached = _cache[mapId]
	if cached ~= nil then
		return if cached == false then nil else cached
	end
	local store = _store
	if not store then return nil end
	for attempt = 1, MAX_RETRIES do
		local ok, result = pcall(function()
			return store:GetAsync(keyFor(mapId))
		end)
		if ok then
			-- Packed buffer (new bakes) or plain table (old bakes); cache the table.
			result = BlobCodec.unpack(result)
			if typeof(result) == "table" then
				_cache[mapId] = result
				return result
			end
			_cache[mapId] = false
			return nil
		end
		warn(string.format("[MapTemplateService] template read attempt %d/%d failed for %q: %s", attempt, MAX_RETRIES, mapId, tostring(result)))
		if attempt < MAX_RETRIES then task.wait(RETRY_DELAY * attempt) end
	end
	return nil
end

-- Write a map's template blob. Overwrites any existing one (re-baking is the point).
-- Updates the cache on success. Yields. Returns ok.
function MapTemplateService.save(mapId: string?, blob: any): boolean
	if typeof(mapId) ~= "string" or mapId == "" then return false end
	if typeof(blob) ~= "table" then return false end
	local store = _store
	if not store then return false end
	for attempt = 1, MAX_RETRIES do
		local ok, err = pcall(function()
			local packed = BlobCodec.pack(blob)
			store:UpdateAsync(keyFor(mapId), function()
				return packed
			end)
		end)
		if ok then
			_cache[mapId] = blob
			return true
		end
		warn(string.format("[MapTemplateService] template write attempt %d/%d failed for %q: %s", attempt, MAX_RETRIES, mapId, tostring(err)))
		if attempt < MAX_RETRIES then task.wait(RETRY_DELAY * attempt) end
	end
	return false
end

return MapTemplateService
