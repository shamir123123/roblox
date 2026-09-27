--!strict
-- PlayerLoadService
-- The JOIN GATE. A joining player is held on the loading screen (ReplicatedFirst.
-- LoadingController) until every piece of THEIR data is in. Without it the menu opens
-- on defaults and then snaps: no saved cities behind Continue / Load, the wrong language
-- and UI scale, and a click made inside that window is answered from a record that has
-- not loaded yet (PlayerDataStore.GetField returns nil until it has).
--
-- State travels as ATTRIBUTES on the Player rather than a RemoteEvent, on purpose:
-- attributes replicate with the instance, so a client reading them late still sees the
-- current value. A remote fired before the client connected its handler is simply lost,
-- and the loading screen -- which runs in ReplicatedFirst, ahead of everything -- would
-- wait forever for a signal that already happened.
--
--   DataLoadStep     string   what is being waited on; the loading screen shows it
--   DataLoadProgress number   0..1 across the gates below
--   DataLoaded       boolean  every gate passed (or LOAD_TIMEOUT expired)
--   DataLoadTimedOut boolean  a gate never landed and the player was let through anyway
--
-- Nobody is ever stuck: a DataStore outage already resolves to a non-persistent fallback
-- session in both owning services, and LOAD_TIMEOUT covers the case where a service never
-- binds at all. A player let through on a timeout plays on defaults -- which is what they
-- would have got instantly before this service existed -- never a black screen.

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

if not RunService:IsServer() then
	error("[PlayerLoadService] Must only be required on the server")
end

local POLL_INTERVAL = 0.1
local LOAD_TIMEOUT  = 45

local ATTR_STEP     = "DataLoadStep"
local ATTR_PROGRESS = "DataLoadProgress"
local ATTR_LOADED   = "DataLoaded"
local ATTR_TIMEOUT  = "DataLoadTimedOut"

local _playerData: any = nil
local _citySlotService: any = nil
local _tracking: { [number]: boolean } = {}

local PlayerLoadService = {}

type Gate = { label: string, ready: (number) -> boolean }

-- Ordered, and deliberately short. The profile record is first because settings, stats,
-- the blueprint index and the staff launcher position are all FIELDS of it -- one gate
-- covers the lot. The city slot index is its own DataStore key, so it needs its own.
local GATES: { Gate } = {
	{
		label = "Loading your profile",
		ready = function(userId: number): boolean
			-- Every record carries "version" -- the stored one and the default used when the
			-- store is unreachable -- so it is present exactly once Load has finished, either way.
			return _playerData ~= nil and _playerData.GetField(userId, "version") ~= nil
		end,
	},
	{
		label = "Loading your cities",
		ready = function(userId: number): boolean
			-- True for a read-only session too: the menu can list and load cities either way,
			-- and CitySlotService warns the player itself when saves are unavailable.
			return _citySlotService ~= nil and _citySlotService.isSessionReady(userId) == true
		end,
	},
}

local function runGates(player: Player)
	local userId = player.UserId
	if _tracking[userId] then return end
	_tracking[userId] = true

	player:SetAttribute(ATTR_LOADED, false)
	player:SetAttribute(ATTR_TIMEOUT, false)
	player:SetAttribute(ATTR_PROGRESS, 0)
	player:SetAttribute(ATTR_STEP, GATES[1].label)

	local deadline = os.clock() + LOAD_TIMEOUT
	local total = #GATES
	local timedOut = false

	for i, gate in GATES do
		player:SetAttribute(ATTR_STEP, gate.label)

		while not gate.ready(userId) do
			if not player.Parent then
				-- Left mid-load. Each owning service releases its own session lock; there is
				-- nothing to unwind here beyond forgetting them.
				_tracking[userId] = nil
				return
			end

			if os.clock() >= deadline then
				timedOut = true
				warn(string.format(
					"[PlayerLoadService] %s (userId %d) timed out waiting for '%s' -- letting them in on defaults",
					player.Name, userId, gate.label
				))
				break
			end

			task.wait(POLL_INTERVAL)
		end

		if timedOut then break end

		player:SetAttribute(ATTR_PROGRESS, i / total)
	end

	if not player.Parent then
		_tracking[userId] = nil
		return
	end

	player:SetAttribute(ATTR_TIMEOUT, timedOut)
	player:SetAttribute(ATTR_PROGRESS, 1)
	player:SetAttribute(ATTR_STEP, if timedOut then "Some of your data is unavailable" else "Ready")
	player:SetAttribute(ATTR_LOADED, true)
end

-- Public: any server system that must not touch a half-loaded record can ask.
function PlayerLoadService.isReady(player: Player): boolean
	return player:GetAttribute(ATTR_LOADED) == true
end

function PlayerLoadService.Init(playerDataStore: any)
	assert(playerDataStore ~= nil, "[PlayerLoadService] PlayerDataStore dependency missing")
	_playerData = playerDataStore
end

-- Late-injected: CitySlotService is built at the very end of the server Bootstrap, by
-- which time a player may already be waiting. Until it arrives the "cities" gate has
-- simply not passed; the wait picks it up the moment it does.
function PlayerLoadService.SetCitySlotService(citySlotService: any)
	_citySlotService = citySlotService
end

function PlayerLoadService.Bind()
	Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(runGates, player)
	end)

	-- Anyone who joined while the server was still booting this far.
	for _, player in Players:GetPlayers() do
		task.spawn(runGates, player)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		_tracking[player.UserId] = nil
	end)
end

return PlayerLoadService
