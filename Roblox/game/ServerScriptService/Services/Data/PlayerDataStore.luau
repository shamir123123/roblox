--!strict

local DataStoreService = game:GetService("DataStoreService")
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")

if not RunService:IsServer() then
	error("[PlayerDataStore] Must only be required on the server")
end

-- The player's OWN store: settings, preferences, playtime, and whatever per-player
-- state gets added later. Cities live in their own store (CitySlotService).
local STORE_NAME    = "CityDistrict_Player_v2"
local SAVE_INTERVAL = 60
local MAX_RETRIES   = 3
local RETRY_DELAY   = 2
local LOCK_TTL      = 30
local CLOSE_TIMEOUT = 25

local SERVER_ID = if game.JobId ~= "" then game.JobId
	else "studio-" .. tostring(os.time()) .. "-" .. tostring(math.random(1, 1000000))

type PlayerData = { [string]: any }

local _store:   DataStore?               = nil
local _cache:   { [number]: PlayerData } = {}
local _dirty:   { [number]: boolean }    = {}
local _saving:  { [number]: boolean }    = {}
local _leaving: { [number]: boolean }    = {}
local _policy:  { [number]: string }     = {}

local PlayerDataStore = {}

-- Extension providers (e.g. terrain): they own a field in the player record but do
-- not touch DataStore. save(userId) returns the field value at write time;
-- load(userId, value) restores it after the record loads.
type Provider = { save: (number) -> any, load: (number, any) -> () }
local _providers: { [string]: Provider } = {}

local function collectProviders(userId: number, data: PlayerData)
	for name, p in _providers do
		local ok, val = pcall(p.save, userId)
		if ok then
			data[name] = val
		else
			warn("[PlayerDataStore] provider '" .. name .. "' save failed: " .. tostring(val))
		end
	end
end

local function loadProviders(userId: number, data: PlayerData)
	for name, p in _providers do
		local ok, err = pcall(p.load, userId, data[name])
		if not ok then
			warn("[PlayerDataStore] provider '" .. name .. "' load failed: " .. tostring(err))
		end
	end
end

local function defaultData(): any
	return {
		version      = 1,
		lastRoadType = "road_2l",
		cameraMode   = "freecam",
		snapEnabled  = true,
		gridEnabled  = false,
		firstJoin    = true,
		staffLauncherPos = nil, -- { x: number, y: number } offset; nil = default corner
	}
end

function PlayerDataStore.Init()
	local ok, result = pcall(function()
		_store = DataStoreService:GetDataStore(STORE_NAME)
	end)

	if not ok then
		warn("[PlayerDataStore] DataStore unavailable:", result)
	end
end

local function lockIsFresh(lock: any): boolean
	return typeof(lock) == "table" and (os.time() - (lock.ts or 0)) < LOCK_TTL
end

local function keyFor(userId: number): string
	return "player_" .. userId
end

local function parseRecord(raw: any): (PlayerData?, any)
	if type(raw) == "table" and raw.__sl then
		return raw.data, raw.lock
	end

	return raw, nil
end

local function acquireSession(userId: number): (PlayerData?, boolean)
	if not _store then return nil, false end

	local store = _store :: DataStore
	local key = keyFor(userId)

	for attempt = 1, MAX_RETRIES do
		local acquired = false
		local result: PlayerData? = nil

		local ok, err = pcall(function()
			store:UpdateAsync(key, function(raw)
				local data, lock = parseRecord(raw)

				if lock and lock.owner ~= SERVER_ID and lockIsFresh(lock) then
					return nil
				end

				data = if typeof(data) == "table" then data else defaultData()
				acquired = true
				result = data

				return { __sl = true, data = data, lock = { owner = SERVER_ID, ts = os.time() } }
			end)
		end)

		if ok and acquired then
			return result, true
		end

		if ok then
			warn(string.format("[PlayerDataStore] userId %d is locked by another session (try %d/%d)", userId, attempt, MAX_RETRIES))
		else
			warn(string.format("[PlayerDataStore] Load attempt %d/%d failed for userId %d: %s", attempt, MAX_RETRIES, userId, tostring(err)))
		end

		if attempt < MAX_RETRIES then
			task.wait(RETRY_DELAY * attempt)
		end
	end

	return nil, false
end

local function writeData(userId: number, data: PlayerData, release: boolean): boolean
	if not _store then return false end

	local store = _store :: DataStore
	local key = keyFor(userId)

	for attempt = 1, MAX_RETRIES do
		local wrote = false

		local ok, err = pcall(function()
			store:UpdateAsync(key, function(raw)
				local _, lock = parseRecord(raw)

				if lock and lock.owner ~= SERVER_ID and lockIsFresh(lock) then
					return nil
				end

				wrote = true

				local newLock = if release then nil else { owner = SERVER_ID, ts = os.time() }

				return { __sl = true, data = data, lock = newLock }
			end)
		end)

		if ok and wrote then return true end

		warn(string.format(
			"[PlayerDataStore] Save attempt %d/%d failed for userId %d: %s",
			attempt,
			MAX_RETRIES,
			userId,
			tostring(if ok then "lock lost to another server" else err)
			))

		if attempt < MAX_RETRIES then
			task.wait(RETRY_DELAY * attempt)
		end
	end

	return false
end

local function saveToStore(userId: number, data: PlayerData)
	if _policy[userId] ~= "persistent" then return end
	if _saving[userId] then return end

	_saving[userId] = true

	collectProviders(userId, data)

	if writeData(userId, data, false) then
		_dirty[userId] = nil
	end

	_saving[userId] = nil
end

function PlayerDataStore.Load(player: Player)
	local userId = player.UserId

	if _cache[userId] then return end

	local data, ok = acquireSession(userId)

	if not player.Parent then
		-- Player left mid-load. If we acquired the session lock above, release it
		-- so a rejoin (or another server) isn't blocked for LOCK_TTL.
		if ok and data then
			writeData(userId, data, true)
		end
		return
	end

	if not ok or typeof(data) ~= "table" then
		_policy[userId] = "nonpersistent"
		_cache[userId]  = defaultData()

		warn(string.format("[PlayerDataStore] %s (userId %d) is NON-PERSISTENT (load failed or locked)", player.Name, userId))

		loadProviders(userId, _cache[userId])

		return
	end

	local merged = data :: PlayerData

	for k, v in defaultData() do
		if merged[k] == nil then
			merged[k] = v
		end
	end

	-- Stamp identity into the record so saves are readable by name, not just key.
	merged.userId     = userId
	merged.playerName = player.Name

	_policy[userId] = "persistent"
	_cache[userId]  = merged

	loadProviders(userId, merged)
end

function PlayerDataStore.SaveNow(player: Player)
	local userId = player.UserId
	_leaving[userId] = true

	local data = _cache[userId]

	if data and _policy[userId] == "persistent" then
		local waited = 0

		while _saving[userId] and waited < 5 do
			task.wait(0.1)
			waited += 0.1
		end

		collectProviders(userId, data)
		_saving[userId] = true
		writeData(userId, data, true)
		_saving[userId] = nil
	end

	_cache[userId]   = nil
	_dirty[userId]   = nil
	_policy[userId]  = nil
	_leaving[userId] = nil
end

-- Write a loaded player's record NOW without ending their session: the same write the
-- periodic loop does, lock held, cache kept. For callers that just changed something they
-- don't want to lose to a crash. Not SaveNow -- that one ends the session.
function PlayerDataStore.Flush(player: Player)
	local data = _cache[player.UserId]
	if not data then return end
	task.spawn(saveToStore, player.UserId, data)
end

function PlayerDataStore.Bind()
	Players.PlayerAdded:Connect(function(player)
		task.spawn(PlayerDataStore.Load, player)
	end)

	for _, player in Players:GetPlayers() do
		task.spawn(PlayerDataStore.Load, player)
	end

	Players.PlayerRemoving:Connect(PlayerDataStore.SaveNow)

	task.spawn(function()
		while true do
			task.wait(SAVE_INTERVAL)

			for userId, isDirty in _dirty do
				if isDirty and not _leaving[userId] and _policy[userId] == "persistent" then
					local data = _cache[userId]

					if data then
						task.spawn(saveToStore, userId, data)
					end
				end
			end
		end
	end)

	game:BindToClose(function()
		local pending = 0

		for userId, data in _cache do
			if _policy[userId] == "persistent" then
				pending += 1
				collectProviders(userId, data)

				task.spawn(function()
					writeData(userId, data, true)
					pending -= 1
				end)
			end
		end

		local deadline = os.clock() + CLOSE_TIMEOUT

		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

-- Generic accessors for small per-player preference values that live in the
-- already-loaded record (e.g. UI prefs). Both are no-ops if the player's record
-- isn't loaded yet. Set marks the record dirty so the normal save loop / BindToClose
-- flush picks it up -- no extra write path needed.
function PlayerDataStore.GetField(userId: number, key: string): any
	local data = _cache[userId]
	if not data then return nil end
	return data[key]
end

function PlayerDataStore.SetField(userId: number, key: string, value: any)
	local data = _cache[userId]
	if not data then return end
	data[key] = value
	if _policy[userId] == "persistent" then
		_dirty[userId] = true
	end
end

-- Read one field belonging to a player who may not be on this server -- e.g. a city
-- server resolving its owner's invite list before the owner has joined. Takes NO session
-- lock and writes nothing to the cache: this is a look at what is currently stored, not
-- a claim on it. Answers from the live record when that player IS here. Yields.
function PlayerDataStore.PeekField(userId: number, key: string): any
	local cached = _cache[userId]
	if cached then return cached[key] end

	local store = _store
	if not store then return nil end

	local ok, raw = pcall(function()
		return (store :: DataStore):GetAsync(keyFor(userId))
	end)
	if not ok then
		warn(string.format("[PlayerDataStore] peek failed for userId %d: %s", userId, tostring(raw)))
		return nil
	end

	local data = parseRecord(raw)
	if typeof(data) ~= "table" then return nil end
	return (data :: PlayerData)[key]
end

function PlayerDataStore.RegisterProvider(
	name: string,
	saveFn: (number) -> any,
	loadFn: (number, any) -> ()
)
	_providers[name] = { save = saveFn, load = loadFn }
	-- Catch up players already loaded before this provider registered.
	for userId, data in _cache do
		loadFn(userId, data[name])
	end
end

return PlayerDataStore