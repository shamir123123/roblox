--!strict
-- Owns the per-player game-settings field ("settings") in PlayerDataStore's
-- record. The client (Core.SettingsClient) pulls once at boot via RF and
-- pushes debounced full payloads via RE; everything is validated here before
-- it touches the record. DataStore traffic itself (session lock, retries,
-- save-on-leave, BindToClose) is PlayerDataStore's job.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

if not RunService:IsServer() then
	error("[PlayerSettingsService] Must only be required on the server")
end

local SAVE_COOLDOWN = 1
local LOAD_WAIT = 15
local MAX_ENTRIES = 80
local MAX_KEY_LEN = 40
local MAX_VALUE_LEN = 24

local _net: any = nil
local _playerData: any = nil
local _lastSaveAt: { [Player]: number } = {}

local PlayerSettingsService = {}

-- Whole-payload validation: reject on any malformed entry (rule: reject and
-- log, never repair attacker input). Values are numbers in [-3, 120] (color
-- grading goes negative, autosave interval is minutes), booleans, or short
-- alphanumeric enum strings ("Soft", "Ultra", "Metric"); a bind is a list of up
-- to three valid input names ("W", "MouseButton1"), empty meaning cleared.
-- Precise per-key ranges are the client consumers' job -- the record just
-- must never hold junk.
-- A bind entry names either a keyboard KeyCode or a mouse button UserInputType.
local function isInputName(name: string): boolean
	local ok, item = pcall(function()
		return (Enum.KeyCode :: any)[name]
	end)
	if ok and typeof(item) == "EnumItem" then
		return true
	end
	ok, item = pcall(function()
		return (Enum.UserInputType :: any)[name]
	end)
	return ok and typeof(item) == "EnumItem"
end

local function sanitize(payload: any): any?
	if typeof(payload) ~= "table" then
		return nil
	end
	local values: { [string]: any } = {}
	local count = 0
	if typeof(payload.values) == "table" then
		for k, v in payload.values do
			count += 1
			if count > MAX_ENTRIES or typeof(k) ~= "string" or #k > MAX_KEY_LEN then
				return nil
			end
			if typeof(v) == "number" then
				if v ~= v or v < -3 or v > 120 then
					return nil
				end
				values[k] = v
			elseif typeof(v) == "boolean" then
				values[k] = v
			elseif typeof(v) == "string" then
				-- Enum-style picks only: no punctuation, no spaces, nothing long
				-- enough to be a payload smuggled into the record.
				if #v == 0 or #v > MAX_VALUE_LEN or not v:match("^%w+$") then
					return nil
				end
				values[k] = v
			else
				return nil
			end
		end
	end
	local binds: { [string]: { string } } = {}
	count = 0
	if typeof(payload.binds) == "table" then
		for k, v in payload.binds do
			count += 1
			if count > MAX_ENTRIES or typeof(k) ~= "string" or #k > MAX_KEY_LEN then
				return nil
			end
			-- An empty list is a bind the player cleared; up to three inputs form a chord.
			if typeof(v) ~= "table" or #v > 3 then
				return nil
			end
			local names: { string } = {}
			for _, name in v do
				if typeof(name) ~= "string" or #name == 0 or #name > MAX_KEY_LEN or not name:match("^%w+$") then
					return nil
				end
				if not isInputName(name) then
					return nil
				end
				table.insert(names, name)
			end
			if #names ~= #v then
				return nil
			end
			binds[k] = names
		end
	end
	return { values = values, binds = binds }
end

function PlayerSettingsService.Init(net: any, playerDataStore: any)
	assert(net ~= nil, "[PlayerSettingsService] Networker dependency missing")
	assert(playerDataStore ~= nil, "[PlayerSettingsService] PlayerDataStore dependency missing")
	_net = net
	_playerData = playerDataStore
end

function PlayerSettingsService.Bind()
	_net.RequestPlayerSettings.OnServerInvoke = function(player: Player): any
		-- The record loads async on join; "version" exists once it has.
		local deadline = os.clock() + LOAD_WAIT
		while os.clock() < deadline do
			if _playerData.GetField(player.UserId, "version") ~= nil then
				return _playerData.GetField(player.UserId, "settings")
			end
			if not player.Parent then
				return nil
			end
			task.wait(0.25)
		end
		return nil
	end

	_net.RequestSaveSettings.OnServerEvent:Connect(function(player: Player, payload: any)
		local now = os.clock()
		local last = _lastSaveAt[player]
		if last and now - last < SAVE_COOLDOWN then
			return
		end
		_lastSaveAt[player] = now
		local clean = sanitize(payload)
		if clean then
			_playerData.SetField(player.UserId, "settings", clean)
		else
			warn("[PlayerSettingsService] rejected malformed settings payload from " .. player.Name)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		_lastSaveAt[player] = nil
	end)
end

return PlayerSettingsService