--!strict

local RunService  = game:GetService("RunService")
local isServer    = RunService:IsServer()

local _serverQueues: { [string]: { any } } = {}
local _flushPending = false

local _serverRateLimits: { [string]: number } = {}

local _serverLastFire:   { [string]: number } = {}

local _attrCache: { [number]: { [string]: any } } = {}

local NetMiddleware = {}

local function flushQueues()
	_flushPending = false
	for key, queue in _serverQueues do
		if #queue == 0 then
			_serverQueues[key] = nil
			continue
		end

		if #queue == 1 then
			local item = queue[1]
			if item.player then
				item.remote:FireClient(item.player, table.unpack(item.args))
			else
				item.remote:FireAllClients(table.unpack(item.args))
			end
		else

			local batchArgs: { any } = {}
			for _, item in queue do
				table.insert(batchArgs, item.args)
			end
			local first = queue[1]
			if first.player then
				first.remote:FireClient(first.player, { __batch = true, items = batchArgs })
			else
				first.remote:FireAllClients({ __batch = true, items = batchArgs })
			end
		end
		_serverQueues[key] = nil
	end
end

local function scheduleFlush()
	if _flushPending then return end
	_flushPending = true
	task.defer(flushQueues)
end

function NetMiddleware.FireQueued(remote: RemoteEvent, ...)
	assert(isServer, "FireQueued is server-only")
	local key = tostring(remote)
	local q = _serverQueues[key]
	if not q then q = {}; _serverQueues[key] = q end
	table.insert(q, { remote = remote, args = { ... } })
	scheduleFlush()
end

function NetMiddleware.FireQueuedClient(remote: RemoteEvent, player: Player, ...)
	assert(isServer, "FireQueuedClient is server-only")
	local key = tostring(remote) .. "|" .. player.UserId
	local q = _serverQueues[key]
	if not q then q = {}; _serverQueues[key] = q end
	table.insert(q, { remote = remote, player = player, args = { ... } })
	scheduleFlush()
end

function NetMiddleware.WrapClientReceive(
	remote: RemoteEvent,
	handler: (...any) -> ()
): RBXScriptConnection
	assert(not isServer, "WrapClientReceive is client-only")
	return remote.OnClientEvent:Connect(function(...)
		local first = select(1, ...)
		if type(first) == "table" and first.__batch then
			for _, args in first.items do
				handler(table.unpack(args))
			end
		else
			handler(...)
		end
	end)
end

local _clientCooldowns: { [string]: number } = {}

function NetMiddleware.ThrottledFireServer(
	remote: RemoteEvent,
	minInterval: number,
	...
)
	assert(not isServer, "ThrottledFireServer is client-only")
	local key   = tostring(remote)
	local now   = os.clock()
	local last  = _clientCooldowns[key]
	if last and now - last < minInterval then
		return
	end
	_clientCooldowns[key] = now
	remote:FireServer(...)
end

function NetMiddleware.RegisterServerRateLimit(remote: RemoteEvent, minInterval: number)
	assert(isServer, "RegisterServerRateLimit is server-only")
	_serverRateLimits[tostring(remote)] = minInterval
end

function NetMiddleware.CheckServerRate(remote: RemoteEvent, player: Player): boolean
	assert(isServer, "CheckServerRate is server-only")
	local remKey   = tostring(remote)
	local interval = _serverRateLimits[remKey]
	if not interval then return true end
	local ck  = remKey .. "|" .. player.UserId
	local now = os.clock()
	local last = _serverLastFire[ck]
	if last and now - last < interval then return false end
	_serverLastFire[ck] = now
	return true
end

function NetMiddleware.OnPlayerRemoving(player: Player)
	if isServer then
		local suffix = "|" .. player.UserId
		for key in _serverLastFire do
			if string.sub(key, -#suffix) == suffix then
				_serverLastFire[key] = nil
			end
		end
	end
	_attrCache[player.UserId] = nil
end

function NetMiddleware.GetCachedAttribute(player: Player, attrName: string): any
	local uid = player.UserId
	local row = _attrCache[uid]
	if not row then
		row = {}
		_attrCache[uid] = row
	end
	if row[attrName] == nil then
		local v = player:GetAttribute(attrName)
		row[attrName] = if v == nil then "__nil" else v
	end
	local cached = row[attrName]
	return if cached == "__nil" then nil else cached
end

function NetMiddleware.InvalidateCachedAttribute(player: Player, attrName: string)
	local row = _attrCache[player.UserId]
	if row then row[attrName] = nil end
end

return NetMiddleware
