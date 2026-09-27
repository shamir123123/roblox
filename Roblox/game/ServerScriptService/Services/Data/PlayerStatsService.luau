--!strict
-- PlayerStatsService
-- The player's lifetime record: time played, sessions, when they started, cities founded,
-- best population reached. Stored as one "stats" field on PlayerDataStore's record via a
-- provider -- no DataStore of its own and no save path of its own, so it inherits the
-- record's session lock, backoff, save-on-leave and BindToClose for free.
--
-- Source data only. Blueprint counts are NOT stored here: they are counted from the
-- blueprint index when the client asks, because persisting a derived number only gives
-- it somewhere to drift.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

if not RunService:IsServer() then
	error("[PlayerStatsService] Must only be required on the server")
end

local FIELD = "stats"
local REQUEST_COOLDOWN = 2

export type Stats = {
	playSeconds: number,
	sessions: number,
	firstJoinAt: number,
	lastSeenAt: number,
	citiesCreated: number,
	peakPopulation: number,
}

-- Every counter a producer may touch, and how it combines: "add" accumulates, "max" only
-- ever climbs. Anything not listed is rejected, so a typo in a caller cannot quietly
-- invent a field that then persists forever.
local COUNTERS = table.freeze({
	citiesCreated = "add",
	peakPopulation = "max",
})

local PlayerStatsService = {}

local _pds: any = nil
local _bp: any = nil
local _net: any = nil
local _stats: { [number]: Stats } = {}
-- os.clock() when each player's playSeconds was last brought up to date.
local _mark: { [number]: number } = {}
local _lastRequest: { [number]: number } = {}

local function defaults(): Stats
	local now = os.time()
	return {
		playSeconds = 0,
		sessions = 0,
		firstJoinAt = now,
		lastSeenAt = now,
		citiesCreated = 0,
		peakPopulation = 0,
	}
end

-- Fold elapsed wall time into playSeconds. Safe to call as often as you like -- the mark
-- moves with it, so no interval is ever counted twice.
local function advance(userId: number)
	local stats = _stats[userId]
	if not stats then return end

	local now = os.clock()
	local last = _mark[userId]
	if last then
		stats.playSeconds += math.max(0, now - last)
	end
	_mark[userId] = now
	stats.lastSeenAt = os.time()
end

function PlayerStatsService.Init(playerDataStore: any, blueprintStore: any, net: any)
	if not playerDataStore then error("[PlayerStatsService] Init requires PlayerDataStore") end
	if not blueprintStore then error("[PlayerStatsService] Init requires BlueprintStore") end
	if not net then error("[PlayerStatsService] Init requires Networker") end
	_pds = playerDataStore
	_bp = blueprintStore
	_net = net

	_pds.RegisterProvider(FIELD,
		function(userId: number): any
			if not _stats[userId] then
				-- Never loaded (or already cleaned up): hand back what is stored rather
				-- than nil, which would erase a real record.
				return _pds.GetField(userId, FIELD)
			end
			advance(userId)
			return _stats[userId]
		end,
		function(userId: number, stored: any)
			local stats = defaults()
			if typeof(stored) == "table" then
				for key in stats do
					if typeof(stored[key]) == "number" then
						(stats :: any)[key] = stored[key]
					end
				end
			end
			stats.sessions += 1
			_stats[userId] = stats
			_mark[userId] = os.clock()
		end
	)
end

-- Move one counter. For an "add" counter `amount` defaults to 1; for a "max" counter it
-- is the candidate value and only wins if it beats what is there.
function PlayerStatsService.bump(player: Player, key: string, amount: number?)
	local mode = COUNTERS[key]
	if not mode then
		warn("[PlayerStatsService] unknown counter '" .. tostring(key) .. "'")
		return
	end

	local stats = _stats[player.UserId]
	if not stats then return end

	local n = tonumber(amount) or 1
	if n ~= n then return end -- NaN

	if mode == "max" then
		if n <= (stats :: any)[key] then return end
		(stats :: any)[key] = n
	else
		(stats :: any)[key] += n
	end

	-- Writes the field and marks the record dirty; the normal save loop flushes it.
	_pds.SetField(player.UserId, FIELD, stats)
end

-- The snapshot the client sees. Playtime is advanced first, so an open panel shows the
-- session you are in rather than the one you last saved.
function PlayerStatsService.get(userId: number): any
	local stats = _stats[userId]
	if not stats then return nil end
	advance(userId)

	return {
		playSeconds = math.floor(stats.playSeconds),
		sessions = stats.sessions,
		firstJoinAt = stats.firstJoinAt,
		lastSeenAt = stats.lastSeenAt,
		citiesCreated = stats.citiesCreated,
		peakPopulation = stats.peakPopulation,
		blueprints = #_bp.list(userId), -- derived, never stored
	}
end

function PlayerStatsService.Bind()
	_net.RequestPlayerStats.OnServerInvoke = function(player: Player): any
		local now = os.clock()
		local last = _lastRequest[player.UserId]
		if last and now - last < REQUEST_COOLDOWN then return nil end
		_lastRequest[player.UserId] = now
		return PlayerStatsService.get(player.UserId)
	end

	-- Bound after PlayerDataStore.Bind, so its PlayerRemoving handler has already run
	-- collectProviders (which happens before it yields on the write) and taken this
	-- player's stats. Clearing here first would drop the last session's playtime.
	Players.PlayerRemoving:Connect(function(player: Player)
		_stats[player.UserId] = nil
		_mark[player.UserId] = nil
		_lastRequest[player.UserId] = nil
	end)
end

return PlayerStatsService
