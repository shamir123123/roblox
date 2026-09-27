--!strict
-- AdminService
-- Owns admin authorization and the server-side debug metrics feed. Admins are
-- the place owner (live servers), anyone in Studio, plus whoever the owner has
-- added to the staff roster. On join an admin is granted the CanDebug attribute
-- (which authorizes the existing DebugService snapshot feed) and an AdminTier
-- attribute the client reads to decide which panel tabs to build.
--
-- RequestServerDebugStats returns read-only server performance metrics. Every
-- call re-checks admin here -- the AdminTier/CanDebug attributes are a UI hint and
-- a feed gate, never the authority for this remote.

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace  = game:GetService("Workspace")
local Stats      = game:GetService("Stats") :: any
local MemoryStoreService = game:GetService("MemoryStoreService")

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local PlayerDataStore = require(ServerScriptService.Services.Data.PlayerDataStore)
-- DebugService gates its snapshot feed on a CACHED read of CanDebug; revoking someone has
-- to punch that cache or the feed outlives the permission. See grant().
local NetMiddleware = require(ReplicatedStorage:WaitForChild("NetMiddleware"))
-- The tier lists used to be two tables right here. They are a DataStore record now, so
-- the owner adds a tester from the panel's Access tab instead of editing and publishing.
local StaffRoster = require(ServerScriptService.Services.Access.StaffRoster)

local AdminService = {}

local STATS_MIN_INTERVAL = 0.4
local ROUTES_MIN_INTERVAL = 1.0
local NPC_MIN_INTERVAL = 0.3
local ADMIN_TOOL_MIN_INTERVAL = 0.4
local MAX_POLYLINES = 16000
local MAX_ADMIN_MONEY_GRANT = 1000000000
local MAX_ADMIN_TRAFFIC_SPAWN = 80
local ADMIN_TRAFFIC_DEFAULT_COUNT = 12
local ADMIN_TRAFFIC_DEFAULT_RADIUS = 260

local _statsRemote: RemoteFunction? = nil
local _routesRemote: RemoteFunction? = nil
local _npcSpeedsRemote: RemoteFunction? = nil
local _adminMoneyRemote: RemoteFunction? = nil
local _adminTrafficRemote: RemoteFunction? = nil
local _adminCityActionRemote: RemoteFunction? = nil
local _adminInspectRemote: RemoteFunction? = nil
local _saveLauncherPosRemote: RemoteEvent? = nil
local _requestLauncherPosRemote: RemoteFunction? = nil
local _roadService: any = nil
local _npcService: any = nil
local _walkingService: any = nil
local _citizenService: any = nil
local _buildingService: any = nil
local _economyService: any = nil
local _timeService: any = nil
local _lastStatsAt: { [Player]: number } = {}
local _lastRoutesAt: { [Player]: number } = {}
local _lastNpcAt: { [Player]: number } = {}
local _lastAdminToolAt: { [Player]: number } = {}
local _lastInspectAt: { [Player]: number } = {}
local _lastLauncherPosSaveAt: { [Player]: number } = {}
local _startClock = os.clock()
local LAUNCHER_POS_MIN_INTERVAL = 1.0
local LAUNCHER_POS_BOUND = 4000 -- generous pixel bound; just guards against garbage payloads

-- Two tiers:
--   ADMIN  = every debug feature (Perf, World, NPCs + speed labels, Log, Routes)
--   TESTER = diagnostics only (Perf, World, Log)
-- Studio is always admin; everyone else comes from the roster, which answers "admin"
-- for the place owner without needing a record for them.
local function tierOf(player: Player): string?
	if RunService:IsStudio() then
		return "admin"
	end
	return StaffRoster.tierOf(player.UserId)
end

AdminService.TierOf = tierOf

local function isAdmin(player: Player): boolean
	return tierOf(player) == "admin"
end

-- Both tiers get CanDebug (the shared snapshot feed powers the World tab); the
-- AdminTier attribute is the client's UI hint for which tabs to build. Every
-- remote re-checks tier server-side, so these attributes are never the authority.
-- Also runs on every roster change, so it has to CLEAR as well as set: a stale AdminTier
-- left on someone the owner just removed would keep their panel drawn and keep the debug
-- feed flowing to them.
local function grant(player: Player)
	local tier = tierOf(player)
	if not tier then
		player:SetAttribute("IsPlaceOwner", nil)
		player:SetAttribute("CanDebug", nil)
		player:SetAttribute("AdminTier", nil)
	else
		-- IsPlaceOwner draws the owner-only Access tab. A hint like the others: StaffRoster
		-- re-checks the owner on every roster remote, so setting it grants nothing by
		-- itself. Set BEFORE AdminTier: the client builds its panel the moment AdminTier
		-- lands, and would decide there was no Access tab if this had not arrived yet.
		player:SetAttribute("IsPlaceOwner", StaffRoster.isOwner(player.UserId) or nil)
		player:SetAttribute("CanDebug", true)
		player:SetAttribute("AdminTier", tier)
	end

	-- DebugService asks NetMiddleware for CanDebug, and that cache is filled on first read
	-- and never refreshed. Without this line a revoked staff member keeps the snapshot feed
	-- for the rest of their session -- the attribute would say no and the cache would still
	-- say yes.
	NetMiddleware.InvalidateCachedAttribute(player, "CanDebug")
end

-- ----------------------------------------------- universe player count --
-- "Players in the game", not "players on this server": every server writes its own
-- headcount under its JobId with a short expiry, and the total is the sum of the live
-- entries. A server that dies simply stops writing and ages out. Roblox's own games API
-- is unreachable from HttpService, so this is the in-engine equivalent.
-- ponytail: one GetRangeAsync page, so the total is right up to MAX_SERVERS live servers
-- -- page through the cursor if the game ever runs more than that.
local UNIVERSE_MAP = "StaffPlayerCount"
local UNIVERSE_TTL = 90 -- an entry survives two missed beats before it ages out
local UNIVERSE_BEAT = 30
local UNIVERSE_MAX_SERVERS = 200

local _universePlayers: number? = nil
local _universeServers: number? = nil

local function beatUniverseCount()
	local map = MemoryStoreService:GetSortedMap(UNIVERSE_MAP)
	local key = if game.JobId ~= "" then game.JobId else "studio"
	local ok, items = pcall(function()
		map:SetAsync(key, #Players:GetPlayers(), UNIVERSE_TTL)
		return map:GetRangeAsync(Enum.SortDirection.Ascending, UNIVERSE_MAX_SERVERS)
	end)
	if not ok or typeof(items) ~= "table" then
		-- Degraded, not fatal: the panel falls back to this server's own roster.
		warn("[AdminService] universe player count unavailable: " .. tostring(items))
		_universePlayers = nil
		_universeServers = nil
		return
	end
	local total = 0
	for _, item in items do
		total += tonumber(item.value) or 0
	end
	_universePlayers = total
	_universeServers = #items
end

local function buildStats(): { [string]: any }
	local hb = Stats.HeartbeatTimeMs
	return {
		serverFps         = if typeof(hb) == "number" and hb > 0 then math.min(60, 1000 / hb) else 0,
		serverHeartbeatMs = hb,
		serverPhysicsMs   = Stats.PhysicsStepTimeMs,
		physicsFps        = Workspace:GetRealPhysicsFPS(),
		memoryMb          = Stats:GetTotalMemoryUsageMb(),
		instanceCount     = Stats.InstanceCount,
		sendKbps          = Stats.DataSendKbps,
		receiveKbps       = Stats.DataReceiveKbps,
		playerCount       = #Players:GetPlayers(),
		universePlayers   = _universePlayers, -- nil while the cross-server count is unavailable
		universeServers   = _universeServers,
		uptimeSec         = os.clock() - _startClock,
		jobId             = if game.JobId ~= "" then game.JobId else "studio",
	}
end

-- Serialises the exact polylines NPCs drive: each lane edge's centreline plus
-- every outgoing connector curve (the turn through a junction), tagged with its
-- movement (left/right/straight/uturn) for colour-coding on the client.
local function withinRadius(camPos: Vector3?, radiusSq: number, p: Vector3): boolean
	if not camPos then return true end
	local dx = p.X - camPos.X
	local dz = p.Z - camPos.Z
	return (dx * dx + dz * dz) <= radiusSq
end

local function buildRoutes(camPos: Vector3?, radius: number): { [string]: any }
	local nav = _roadService and _roadService.getNavigationGraph and _roadService.getNavigationGraph()
	if not nav or not nav:HasEdges() then
		return { lanes = {}, turns = {}, parking = {}, truncated = false }
	end

	local radiusSq = radius * radius
	local lanes: { { Vector3 } } = {}
	local turns: { { p: { Vector3 }, m: string } } = {}
	local parking: { { Vector3 } } = {}
	local count = 0
	local truncated = false

	local function canAdd(): boolean
		if count < MAX_POLYLINES then return true end
		truncated = true
		return false
	end

	for _, edge in nav:GetEdges() do
		if not canAdd() then break end
		if edge.points and #edge.points >= 2 and withinRadius(camPos, radiusSq, edge.points[1]) then
			table.insert(lanes, edge.points)
			count += 1
		end

		for _, toId in edge.out do
			if not canAdd() then break end
			local pts = nav:GetConnectionPoints(edge.id, toId)
			if pts and #pts >= 2 and withinRadius(camPos, radiusSq, pts[1]) then
				table.insert(turns, { p = pts, m = edge.outMovement[toId] or "straight" })
				count += 1
			end
		end
	end

	if _buildingService and _buildingService.listBuildings and _buildingService.getParkSpots then
		for _, building in _buildingService.listBuildings() do
			if not canAdd() then break end
			local zone = building.zone
			if zone == "Residential" or zone == "Commercial" or zone == "Industrial" then
				local bpId = building.bpId
				local spots = _buildingService.getParkSpots(bpId)
				if spots then
					local kerb = if _buildingService.getKerb then _buildingService.getKerb(bpId) else nil
					if spots.home and typeof(kerb) == "Vector3" and withinRadius(camPos, radiusSq, kerb) and canAdd() then
						table.insert(parking, { kerb, spots.home.Position })
						count += 1
					end
					local stalls = spots.stalls or {}
					for _, stall in stalls do
						if not canAdd() then break end
						local route: { Vector3 } = {}
						if stall.route then
							for _, p in stall.route do table.insert(route, p) end
						end
						if #route == 0 and typeof(kerb) == "Vector3" then table.insert(route, kerb) end
						table.insert(route, stall.cf.Position)
						if #route >= 2 and withinRadius(camPos, radiusSq, route[1]) then
							table.insert(parking, route)
							count += 1
						end
					end
				end
			end
		end
	end

	return { lanes = lanes, turns = turns, parking = parking, truncated = truncated }
end

local function validVector3(pos: any): boolean
	return typeof(pos) == "Vector3" and pos == pos and pos.Magnitude < math.huge
end

local function takeAdminToolCooldown(player: Player): boolean
	local now = os.clock()
	local last = _lastAdminToolAt[player]
	if last and now - last < ADMIN_TOOL_MIN_INTERVAL then
		return false
	end
	_lastAdminToolAt[player] = now
	return true
end

local function responseError(message: string): { [string]: any }
	return { ok = false, error = message }
end

function AdminService.Init(
	statsRemote: RemoteFunction,
	routesRemote: RemoteFunction,
	npcSpeedsRemote: RemoteFunction,
	adminMoneyRemote: RemoteFunction,
	adminTrafficRemote: RemoteFunction,
	adminCityActionRemote: RemoteFunction,
	adminInspectRemote: RemoteFunction,
	roadService: any,
	npcService: any,
	walkingService: any,
	citizenService: any,
	buildingService: any?,
	economyService: any?,
	timeService: any?,
	saveLauncherPosRemote: RemoteEvent?,
	requestLauncherPosRemote: RemoteFunction?
)
	_statsRemote = statsRemote
	_routesRemote = routesRemote
	_npcSpeedsRemote = npcSpeedsRemote
	_adminMoneyRemote = adminMoneyRemote
	_adminTrafficRemote = adminTrafficRemote
	_adminCityActionRemote = adminCityActionRemote
	_adminInspectRemote = adminInspectRemote
	_roadService = roadService
	_npcService = npcService
	_walkingService = walkingService
	_citizenService = citizenService
	_buildingService = buildingService
	_economyService = economyService
	_timeService = timeService
	_saveLauncherPosRemote = saveLauncherPosRemote
	_requestLauncherPosRemote = requestLauncherPosRemote
end

function AdminService.Bind()
	local remote = _statsRemote
	if not remote then
		error("[AdminService] Init must run before Bind: stats remote missing")
	end

	Players.PlayerAdded:Connect(grant)
	for _, p in Players:GetPlayers() do
		grant(p)
	end

	-- Re-stamp everyone whenever the roster moves (this server's own edit, another
	-- server's, or the periodic refresh) so a grant or a removal takes effect while the
	-- player is standing there, not at their next join.
	StaffRoster.onChanged(function()
		for _, p in Players:GetPlayers() do
			grant(p)
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		_lastStatsAt[player] = nil
		_lastRoutesAt[player] = nil
		_lastNpcAt[player] = nil
		_lastAdminToolAt[player] = nil
		_lastInspectAt[player] = nil
		_lastLauncherPosSaveAt[player] = nil
	end)

	remote.OnServerInvoke = function(player: Player): { [string]: any }?
		local now = os.clock()
		local last = _lastStatsAt[player]
		if last and now - last < STATS_MIN_INTERVAL then
			return nil
		end
		_lastStatsAt[player] = now

		-- Perf is available to both tiers.
		if not tierOf(player) then
			warn("[AdminService] Unauthorised stats request from", player.Name)
			return nil
		end

		return buildStats()
	end

	local routes = _routesRemote
	if not routes then
		error("[AdminService] Init must run before Bind: routes remote missing")
	end

	routes.OnServerInvoke = function(player: Player, camPos: any, radius: any): { [string]: any }?
		local now = os.clock()
		local last = _lastRoutesAt[player]
		if last and now - last < ROUTES_MIN_INTERVAL then
			return nil
		end
		_lastRoutesAt[player] = now

		if not isAdmin(player) then
			warn("[AdminService] Unauthorised routes request from", player.Name)
			return nil
		end

		-- Optional camera-radius filter (untrusted client input -- validate).
		local cp: Vector3? = nil
		local r = 600
		if typeof(camPos) == "Vector3" and camPos == camPos and camPos.Magnitude < math.huge then
			cp = camPos
			if typeof(radius) == "number" and radius == radius then
				r = math.clamp(radius, 50, 4000)
			end
		end

		return buildRoutes(cp, r)
	end

	local npcSpeeds = _npcSpeedsRemote
	if not npcSpeeds then
		error("[AdminService] Init must run before Bind: npc speeds remote missing")
	end

	npcSpeeds.OnServerInvoke = function(player: Player): { any }?
		local now = os.clock()
		local last = _lastNpcAt[player]
		if last and now - last < NPC_MIN_INTERVAL then
			return nil
		end
		_lastNpcAt[player] = now

		if not isAdmin(player) then
			warn("[AdminService] Unauthorised npc speed request from", player.Name)
			return nil
		end

		if not _npcService or not _npcService.GetSpeedDebug then
			return {}
		end

		return _npcService.GetSpeedDebug()
	end

	local addMoney = _adminMoneyRemote
	if not addMoney then
		error("[AdminService] Init must run before Bind: add money remote missing")
	end

	addMoney.OnServerInvoke = function(player: Player, amount: any): { [string]: any }?
		if not isAdmin(player) then
			warn("[AdminService] Unauthorised add money request from", player.Name)
			return nil
		end
		if not takeAdminToolCooldown(player) then
			return responseError("Slow down.")
		end
		if not _economyService or not _economyService.credit then
			return responseError("Economy service unavailable.")
		end

		local parsed = tonumber(amount)
		if not parsed or parsed ~= parsed then
			return responseError("Enter a money amount.")
		end

		local grantAmount = math.clamp(math.floor(parsed + 0.5), 1, MAX_ADMIN_MONEY_GRANT)
		_economyService.credit(grantAmount)

		local money: number? = nil
		if _economyService.getTreasury then
			local ok, treasury = pcall(function()
				return _economyService.getTreasury()
			end)
			if ok and typeof(treasury) == "number" then
				money = math.floor(treasury + 0.5)
			end
		end

		return { ok = true, amount = grantAmount, money = money }
	end

	local spawnTraffic = _adminTrafficRemote
	if not spawnTraffic then
		error("[AdminService] Init must run before Bind: spawn traffic remote missing")
	end

	spawnTraffic.OnServerInvoke = function(player: Player, payload: any): { [string]: any }?
		if not isAdmin(player) then
			warn("[AdminService] Unauthorised spawn traffic request from", player.Name)
			return nil
		end
		if not takeAdminToolCooldown(player) then
			return responseError("Slow down.")
		end
		if not _npcService or not _npcService.SpawnTestCarsNear then
			return responseError("Traffic service unavailable.")
		end

		local count = ADMIN_TRAFFIC_DEFAULT_COUNT
		local radius = ADMIN_TRAFFIC_DEFAULT_RADIUS
		local near: Vector3? = nil
		if typeof(payload) == "table" then
			count = tonumber(payload.count) or count
			radius = tonumber(payload.radius) or radius
			local candidate = payload.near
			if validVector3(candidate) then
				near = candidate :: Vector3
			end
		else
			count = tonumber(payload) or count
		end
		count = math.clamp(math.floor(count + 0.5), 1, MAX_ADMIN_TRAFFIC_SPAWN)
		radius = math.clamp(math.floor(radius + 0.5), 40, 1500)

		local ok, res = pcall(function()
			return _npcService.SpawnTestCarsNear(near, count, radius)
		end)
		if not ok then
			warn("[AdminService] spawn traffic failed:", res)
			return responseError("Spawn failed.")
		end
		if typeof(res) == "table" then
			return res
		end
		return { ok = res == true, spawned = if res == true then count else 0 }
	end

	local cityAction = _adminCityActionRemote
	if not cityAction then error("[AdminService] Init must run before Bind: city action remote missing") end
	cityAction.OnServerInvoke = function(player: Player, payload: any): { [string]: any }?
		if not isAdmin(player) then return nil end
		if not takeAdminToolCooldown(player) then return responseError("Slow down.") end
		if typeof(payload) ~= "table" then return responseError("Invalid city action.") end
		local action = payload.action
		if action == "addPopulation" then
			if not _citizenService or not _citizenService.AdminAddPopulation then
				return responseError("Citizen service unavailable.")
			end
			return _citizenService.AdminAddPopulation(math.clamp(math.floor(tonumber(payload.amount) or 0), 1, 5000))
		elseif action == "spawnWalkers" then
			if not _walkingService or not _walkingService.spawnTestWalker then
				return responseError("Walking service unavailable.")
			end
			local requested = math.clamp(math.floor(tonumber(payload.amount) or 1), 1, 80)
			local spawned = 0
			for i = 1, requested do
				if _walkingService.spawnTestWalker(i - 1) then spawned += 1 end
			end
			return { ok = spawned > 0, spawned = spawned, requested = requested }
		elseif action == "setTimeOfDay" then
			if not _timeService or not _timeService.setClockTime then
				return responseError("Time service unavailable.")
			end
			local requestedHour = tonumber(payload.hour)
			if not requestedHour or requestedHour ~= requestedHour then
				return responseError("Enter an hour from 0 to 24.")
			end
			requestedHour = math.clamp(requestedHour, 0, 23.999)
			local ok, clockTime, dayFraction = pcall(function()
				return _timeService.setClockTime(requestedHour)
			end)
			if not ok then
				warn("[AdminService] set time failed:", clockTime)
				return responseError("Time change failed.")
			end
			return {
				ok = true,
				hour = clockTime,
				fraction = dayFraction,
				day = if _timeService.getDay then _timeService.getDay() else nil,
			}
		elseif action == "setSeason" then
			local VALID_SEASONS = { Spring = true, Summer = true, Autumn = true, Fall = true, Winter = true }
			local season = payload.season
			if typeof(season) ~= "string" or not VALID_SEASONS[season] then
				return responseError("Unknown season.")
			end
			Workspace:SetAttribute("Season", season)
			return { ok = true, season = season }
		elseif action == "setWeather" then
			local VALID_WEATHER = { Clear = true, Rain = true, Snow = true }
			local weather = payload.weather
			if typeof(weather) ~= "string" or not VALID_WEATHER[weather] then
				return responseError("Unknown weather.")
			end
			Workspace:SetAttribute("Weather", weather)
			return { ok = true, weather = weather }
		end
		return responseError("Unknown city action.")
	end

	local inspect = _adminInspectRemote
	if not inspect then error("[AdminService] Init must run before Bind: inspect remote missing") end
	inspect.OnServerInvoke = function(player: Player, payload: any): { [string]: any }?
		if not isAdmin(player) or typeof(payload) ~= "table" then return nil end
		local now = os.clock()
		if now - (_lastInspectAt[player] or 0) < 0.15 then return responseError("Slow down.") end
		_lastInspectAt[player] = now

		if payload.kind == "vehicle" then
			local model = payload.model
			if typeof(model) ~= "Instance" or not model:IsA("Model") or not model:IsDescendantOf(Workspace) then
				return responseError("Vehicle is no longer available.")
			end
			local data = _npcService and _npcService.GetDriverRouteDebug and _npcService.GetDriverRouteDebug(model)
			if not data then return responseError("That vehicle has no active route.") end
			local result = table.clone(data)
			local pid = model:GetAttribute("CitizenPid")
			if typeof(pid) == "number" and _citizenService and _citizenService.getAdminPersonDebug then
				local citizen = _citizenService.getAdminPersonDebug(math.floor(pid))
				if citizen then
					result.ownerName = citizen.name
					result.purpose = citizen.purpose or model:GetAttribute("TripPurpose")
					result.modeDecision = citizen.modeDecision
				end
			end
			return result
		elseif payload.kind == "citizen" then
			local pid = math.floor(tonumber(payload.pid) or 0)
			local info = _citizenService and _citizenService.getAdminPersonDebug and _citizenService.getAdminPersonDebug(pid)
			if not info then return responseError("Citizen is no longer available.") end
			local result = table.clone(info)
			local routeDebug = nil
			if info.car and _npcService and _npcService.GetDriverRouteDebug then
				routeDebug = _npcService.GetDriverRouteDebug(info.car)
			elseif info.walkerId and _walkingService and _walkingService.GetCommuterDebug then
				routeDebug = _walkingService.GetCommuterDebug(info.walkerId)
			end
			result.car = nil
			result.routeDebug = routeDebug
			return result
		end
		return responseError("Select a vehicle or citizen.")
	end

	-- Staff launcher pill position: tester+admin can save/load (it's a UI preference,
	-- not a privileged action), but still tier-gated since the panel itself is staff-only.
	local saveLauncherPos = _saveLauncherPosRemote
	if saveLauncherPos then
		saveLauncherPos.OnServerEvent:Connect(function(player: Player, payload: any)
			if not tierOf(player) then return end

			local now = os.clock()
			local last = _lastLauncherPosSaveAt[player]
			if last and now - last < LAUNCHER_POS_MIN_INTERVAL then return end

			if typeof(payload) ~= "table" then return end
			local x = tonumber(payload.x)
			local y = tonumber(payload.y)
			if not x or not y or x ~= x or y ~= y then return end
			if math.abs(x) > LAUNCHER_POS_BOUND or math.abs(y) > LAUNCHER_POS_BOUND then return end

			_lastLauncherPosSaveAt[player] = now
			PlayerDataStore.SetField(player.UserId, "staffLauncherPos", { x = x, y = y })
		end)
	end

	local requestLauncherPos = _requestLauncherPosRemote
	if requestLauncherPos then
		requestLauncherPos.OnServerInvoke = function(player: Player): { [string]: any }?
			if not tierOf(player) then return nil end
			local pos = PlayerDataStore.GetField(player.UserId, "staffLauncherPos")
			if typeof(pos) == "table" and typeof(pos.x) == "number" and typeof(pos.y) == "number" then
				return { x = pos.x, y = pos.y }
			end
			return nil
		end
	end
end

function AdminService.Start()
	-- The only spawned loop here: MemoryStore calls yield, so they cannot sit in the stats
	-- remote's path. The count is refreshed on a cadence and every request serves the cache.
	task.spawn(function()
		while true do
			beatUniverseCount()
			task.wait(UNIVERSE_BEAT)
		end
	end)
end

return AdminService
