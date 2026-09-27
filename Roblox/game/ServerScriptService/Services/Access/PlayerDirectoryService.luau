--!strict
-- PlayerDirectoryService
-- Who is playing right now, across the WHOLE experience. Roblox gives a server no way to
-- see past its own walls, so every server writes ITS players into one shared MemoryStore
-- map on a heartbeat and reads the union back out.
--
-- Entries carry a TTL rather than being cleaned up: a server that crashes stops advertising
-- its players within one interval on its own. A cleanup pass would have to know which
-- server owned which row, and be running, and be right -- an expiry is none of those.
--
-- Read by exactly one thing: the F4 Cities tab, which is how an admin reaches a player's
-- city to moderate it. Nothing in the game is gated on this, nothing else reads it, and the
-- remote is admin-only. A MemoryStore that is unavailable degrades to an empty list, which
-- is a staff tool showing nothing rather than a game that stops working.

local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerDirectoryService = {}

local MAP_NAME = "CityDistrict_Online_v1"
local PUBLISH_INTERVAL = 20
-- Comfortably more than three publishes. One slow frame or one dropped write must not
-- blink a player off every admin's list and back on again.
local ENTRY_TTL = 75
local MAX_LISTED = 200
local READ_COOLDOWN = 2

local _map: any = nil
local _mapFailed = false
local _net: any = nil
local _admin: any = nil
local _cityContext: (() -> any)? = nil
local _bound = false
local _publishing = false
-- Starts full so the first heartbeat publishes, rather than leaving this server invisible
-- for the first twenty seconds after it boots.
local _accum = PUBLISH_INTERVAL
local _lastReadAt: { [number]: number } = {}

local function map(): any
	if _map then return _map end
	if _mapFailed then return nil end
	local ok, m = pcall(function()
		return MemoryStoreService:GetSortedMap(MAP_NAME)
	end)
	if not ok then
		-- Asked for once. Retrying every heartbeat in a place where MemoryStore is off
		-- (Studio without API access) is a warning per frame and nothing gained.
		_mapFailed = true
		warn("[PlayerDirectoryService] MemoryStore unavailable: " .. tostring(m))
		return nil
	end
	_map = m
	return m
end

-- What this server is showing, if anything, so a row can say "in Riverside" rather than
-- just naming a player. Supplied by CitySlotService, which owns the loaded city; nil in a
-- lobby, where the honest answer is that they are in the menu.
function PlayerDirectoryService.SetCityContext(fn: () -> any)
	_cityContext = fn
end

local function publish()
	local m = map()
	if not m then return end

	local city: any = nil
	if _cityContext then
		local ok, result = pcall(_cityContext)
		city = if ok then result else nil
	end

	for _, player in Players:GetPlayers() do
		local entry: { [string]: any } = {
			name = player.Name,
			display = player.DisplayName,
			at = os.time(),
		}
		if typeof(city) == "table" then
			entry.ownerId = city.ownerId
			entry.slotId = city.slotId
			entry.cityName = city.cityName
			entry.pop = city.pop
		end

		-- SetAsync overwrites, so there is nothing to read first and nothing to merge --
		-- this server is the only writer for its own players.
		local ok, err = pcall(function()
			m:SetAsync(tostring(player.UserId), entry, ENTRY_TTL)
		end)
		if not ok then
			warn("[PlayerDirectoryService] publish failed for " .. player.Name .. ": " .. tostring(err))
			-- Out of budget or the service is unhappy: stop for this tick rather than
			-- spending the rest of it failing once per player.
			return
		end
	end
end

function PlayerDirectoryService.online(): { any }
	local m = map()
	if not m then return {} end

	local ok, items = pcall(function()
		return m:GetRangeAsync(Enum.SortDirection.Ascending, MAX_LISTED)
	end)
	if not ok or typeof(items) ~= "table" then
		warn("[PlayerDirectoryService] online read failed: " .. tostring(items))
		return {}
	end

	local rows = {}
	for _, item in items do
		local userId = tonumber(item.key)
		local v = item.value
		if userId and typeof(v) == "table" then
			table.insert(rows, {
				userId = userId,
				name = tostring(v.name),
				display = tostring(v.display or v.name),
				ownerId = v.ownerId,
				slotId = v.slotId,
				cityName = v.cityName,
				pop = v.pop,
			})
		end
	end
	table.sort(rows, function(a, b) return a.display:lower() < b.display:lower() end)
	return rows
end

local function isAdmin(player: Player): boolean
	return _admin ~= nil and _admin.TierOf ~= nil and _admin.TierOf(player) == "admin"
end

local function onRequestOnlinePlayers(player: Player): any
	if not isAdmin(player) then return { ok = false, error = "Admin only." } end

	local now = os.clock()
	local last = _lastReadAt[player.UserId]
	if last and now - last < READ_COOLDOWN then return { ok = false, error = "Too fast. Try again." } end
	_lastReadAt[player.UserId] = now

	return { ok = true, rows = PlayerDirectoryService.online() }
end

-- Init may not yield: capture the dependencies and stop.
function PlayerDirectoryService.Init(adminService: any)
	if not adminService then
		error("[PlayerDirectoryService] Init requires AdminService -- the list is admin-only and cannot gate itself")
	end
	_admin = adminService
	_net = require(ReplicatedStorage:WaitForChild("Networker"))
end

function PlayerDirectoryService.Bind()
	if _bound then return end
	_bound = true
	if not _net then
		error("[PlayerDirectoryService] Bind before Init")
	end

	_net.RequestOnlinePlayers.OnServerInvoke = onRequestOnlinePlayers

	Players.PlayerRemoving:Connect(function(player)
		_lastReadAt[player.UserId] = nil
		local m = map()
		if not m then return end
		-- Dropped immediately rather than left to expire: a player who left seconds ago is
		-- the one an admin is most likely to chase, and chasing a ghost wastes their time.
		task.spawn(function()
			pcall(function() m:RemoveAsync(tostring(player.UserId)) end)
		end)
	end)

	RunService.Heartbeat:Connect(function(dt: number)
		_accum += dt
		if _accum < PUBLISH_INTERVAL or _publishing then return end
		_accum = 0
		_publishing = true
		-- Spawned because every SetAsync yields, and a heartbeat handler must not.
		task.spawn(function()
			local ok, err = pcall(publish)
			if not ok then
				warn("[PlayerDirectoryService] publish errored: " .. tostring(err))
			end
			_publishing = false
		end)
	end)
end

return PlayerDirectoryService
