--!strict
-- DeveloperService
-- Server half of the Developer panel (the deeper sibling of the F4 admin panel).
-- Exposes two admin-only, rate-limited feeds:
--
--   RequestDevReport()                  -> health/diagnostics dashboard. A list of
--                                          pass / warn / fail checks plus the raw
--                                          numbers behind them (perf, traffic, nav,
--                                          buildings, citizens, economy, parking,
--                                          server log counts). "Is the game broken,
--                                          and what is the worst thing right now."
--   RequestDevGeometry(camPos, r, layers) -> camera-radius-filtered overlay geometry,
--                                          layer-gated: stop lines (where cars SHOULD
--                                          stop + right-of-way state), the drivable
--                                          lane network with live congestion, on-street
--                                          + lot parking, and nav dead-ends.
--
-- This service OWNS no state. It reads each domain through that domain's public
-- getters (added alongside this panel) and never reaches into another service's
-- internals. Authority is re-checked here on every call via AdminService.TierOf --
-- the client's AdminTier attribute is only a UI hint.

local Players    = game:GetService("Players")
local RunService  = game:GetService("RunService")
local Workspace  = game:GetService("Workspace")
local LogService = game:GetService("LogService")
local Stats      = game:GetService("Stats") :: any

local DeveloperService = {}

local REPORT_MIN_INTERVAL   = 0.5
local GEOMETRY_MIN_INTERVAL = 0.4
local LOG_WINDOW            = 60      -- rolling error/warn window (seconds)
local MAX_BUILDING_PADS     = 1600
local GEOMETRY_MAX_RADIUS   = 4000
local GEOMETRY_MIN_RADIUS   = 50
local GEOMETRY_DEF_RADIUS   = 700

local _reportRemote: RemoteFunction? = nil
local _geometryRemote: RemoteFunction? = nil
local _ocRemote: RemoteFunction? = nil

local _adminService: any = nil
local _roadService: any = nil
local _npcService: any = nil
local _parkingService: any = nil
local _buildingService: any = nil
local _citizenService: any = nil
local _agentService: any = nil   -- CitizenAgentService (Tier 2); optional, set late
local _cityStatsService: any = nil
local _economyService: any = nil
local _outsideConnService: any = nil
local _citySlotService: any = nil

local _lastReportAt: { [Player]: number } = {}
local _lastGeometryAt: { [Player]: number } = {}
local _lastOcAt: { [Player]: number } = {}
local _startClock = os.clock()

-- Rolling server-side log census so the report can say "errors are spamming" -- the
-- single clearest "the game is broken" signal. Just timestamps; pruned on read.
local _errorTimes: { number } = {}
local _warnTimes: { number } = {}
local _logConn: RBXScriptConnection? = nil

local function isAdmin(player: Player): boolean
	return _adminService ~= nil and _adminService.TierOf ~= nil and _adminService.TierOf(player) == "admin"
end

local function safeCall<T>(fallback: T, fn: () -> T): T
	local ok, res = pcall(fn)
	if ok then return res :: T end
	return fallback
end

local function finiteVector(pos: any): boolean
	return typeof(pos) == "Vector3" and pos == pos and pos.Magnitude < math.huge
end

local function pruneLog()
	local cutoff = os.clock() - LOG_WINDOW
	while _errorTimes[1] and _errorTimes[1] < cutoff do table.remove(_errorTimes, 1) end
	while _warnTimes[1] and _warnTimes[1] < cutoff do table.remove(_warnTimes, 1) end
end

-- ----------------------------------------------------------------- report --

type Check = { id: string, label: string, status: string, value: string, detail: string }

local function navCounts(): (number, number, number)
	local g = _roadService and _roadService.getNavigationGraph and _roadService.getNavigationGraph()
	if not g or not g:HasEdges() then return 0, 0, 0 end
	local edges = g:GetEdges()
	local nodes: { [number]: boolean } = {}
	local deadEnds = 0
	for _, edge in edges do
		nodes[edge.fromNode] = true
		nodes[edge.toNode] = true
		local hasExit = false
		for _, toId in edge.out do
			if edge.outMovement[toId] ~= "uturn" then hasExit = true break end
		end
		if not hasExit then deadEnds += 1 end
	end
	local nodeCount = 0
	for _ in nodes do nodeCount += 1 end
	return #edges, nodeCount, deadEnds
end

local function buildingTotals(): { [string]: number }
	local t = { total = 0, abandoned = 0, residential = 0, commercial = 0, industrial = 0 }
	if not (_buildingService and _buildingService.listBuildings) then return t end
	for _, b in _buildingService.listBuildings() do
		t.total += 1
		if b.abandoned then t.abandoned += 1 end
		if b.zone == "Residential" then t.residential += 1
		elseif b.zone == "Commercial" then t.commercial += 1
		elseif b.zone == "Industrial" then t.industrial += 1 end
	end
	return t
end

local function buildReport(): { [string]: any }
	pruneLog()

	local profileRows: { any } = {}
	local function timed(name: string, fallback: any, fn: () -> any): any
		local started = os.clock()
		local ok, res = pcall(fn)
		local ms = (os.clock() - started) * 1000
		table.insert(profileRows, { name = name, ms = ms, ok = ok })
		if ok then return res end
		return fallback
	end

	local hb = Stats.HeartbeatTimeMs
	local perf = {
		serverFps   = if typeof(hb) == "number" and hb > 0 then math.min(60, 1000 / hb) else 0,
		heartbeatMs = hb,
		physicsMs   = Stats.PhysicsStepTimeMs,
		physicsFps  = Workspace:GetRealPhysicsFPS(),
		memoryMb    = Stats:GetTotalMemoryUsageMb(),
		instances   = Stats.InstanceCount,
		sendKbps    = Stats.DataSendKbps,
		receiveKbps = Stats.DataReceiveKbps,
		uptime      = os.clock() - _startClock,
		players     = #Players:GetPlayers(),
	}

	local traffic = timed("NPC traffic stats", {}, function()
		return if _npcService and _npcService.GetTrafficStats then _npcService.GetTrafficStats() else {}
	end)

	local navData = timed("Road/nav graph", { edges = 0, nodes = 0, deadEnds = 0 }, function()
		local e, n, d = navCounts()
		return { edges = e, nodes = n, deadEnds = d }
	end)
	local edges, nodes, deadEnds = navData.edges or 0, navData.nodes or 0, navData.deadEnds or 0
	local nav = { edges = edges, nodes = nodes, deadEnds = deadEnds }

	local buildings = timed("Building census", { total = 0, abandoned = 0, residential = 0, commercial = 0, industrial = 0, occupiedHomes = 0, emptyHomes = 0 }, function()
		local data = buildingTotals()
		data.occupiedHomes = if _buildingService and _buildingService.getOccupiedHomeCount then _buildingService.getOccupiedHomeCount() else 0
		data.emptyHomes = if _buildingService and _buildingService.getEmptyHomes then #_buildingService.getEmptyHomes() else 0
		return data
	end)

	local citizenData = timed("Citizen census", { stats = {}, snap = {} }, function()
		return {
			stats = if _citizenService and _citizenService.getStats then _citizenService.getStats() else {},
			snap = if _citizenService and _citizenService.debugSnapshot then _citizenService.debugSnapshot() else {},
		}
	end)
	local stats = citizenData.stats or {}
	local snap = citizenData.snap or {}
	local citizens = {
		population   = stats.population or 0,
		households   = stats.households or 0,
		adults       = stats.adults or 0,
		employed     = stats.employed or 0,
		cars         = stats.cars or 0,
		driving      = stats.driving or 0,
		withCar      = snap.withCar or 0,
		navEdges     = snap.navEdges == true,
		sidewalkBuilt = snap.sidewalkBuilt == true,
		-- Scheduler health. sweepSteps is how many sim steps the last full activity sweep
		-- took; as it climbs toward CitizenService.ACTIVITY_SWEEP_WARN the population has
		-- outgrown the per-step budget (CitizenService LOD.SWEEP_WARN) and adults start
		-- missing their shift windows.
		sweepSteps   = snap.sweepSteps or 0,
		sweepPending = snap.sweepPending or 0,
	}

	-- Tier 2: bodiless agents mid-walk. `active` is the population currently walking with a
	-- real position but no body; `promoted` counts how many got a body when a player came
	-- close; `overflowed` is agents refused at MAX_AGENTS, which fall back to teleporting --
	-- a non-zero and rising overflow means the tier is saturated.
	local agentData = timed("Citizen agents (tier 2)", {}, function()
		return if _agentService and _agentService.debugSnapshot then _agentService.debugSnapshot() else {}
	end)
	local agents = {
		active     = agentData.active or 0,
		capacity   = agentData.capacity or 0,
		staleGraph = agentData.staleGraph or 0,
		adopted    = agentData.adopted or 0,
		arrived    = agentData.arrived or 0,
		promoted   = agentData.promoted or 0,
		overflowed = agentData.overflowed or 0,
	}

	local economy = timed("Economy stats", {}, function()
		local e = {}
		if _economyService then
			if _economyService.getTreasury then e.treasury = _economyService.getTreasury() end
			if _economyService.getSupplyRatio then e.supplyRatio = _economyService.getSupplyRatio() end
			if _economyService.getTaxRates then
				local r = _economyService.getTaxRates()
				e.taxR, e.taxC, e.taxI = r.R, r.C, r.I
			end
		end
		return e
	end)

	local parking = timed("Parking stats", {}, function()
		return if _parkingService and _parkingService.GetParkingStats then _parkingService.GetParkingStats() else {}
	end)

	local save = timed("City save diagnostics", {}, function()
		return if _citySlotService and _citySlotService.DebugSaveStats then _citySlotService.DebugSaveStats() else {}
	end)

	local log = { errors = #_errorTimes, warns = #_warnTimes }

	-- Build the pass/warn/fail checks the dashboard renders. Server owns the thresholds.
	local checks: { Check } = {}
	local function add(id: string, label: string, status: string, value: string, detail: string)
		table.insert(checks, { id = id, label = label, status = status, value = value, detail = detail })
	end
	local function band(v: number, warnAt: number, failAt: number, higherIsWorse: boolean): string
		if higherIsWorse then
			if v >= failAt then return "fail" elseif v >= warnAt then return "warn" end
		else
			if v <= failAt then return "fail" elseif v <= warnAt then return "warn" end
		end
		return "ok"
	end

	local pop = citizens.population

	add("server_fps", "Server frame rate", band(perf.serverFps, 45, 28, false),
		string.format("%d fps", perf.serverFps),
		string.format("heartbeat %.1f ms", perf.heartbeatMs or 0))

	add("physics", "Physics step", band(perf.physicsMs or 0, 8, 14, true),
		string.format("%.1f ms", perf.physicsMs or 0),
		string.format("%d physics fps", perf.physicsFps or 0))

	add("memory", "Server memory", band(perf.memoryMb or 0, 2400, 3600, true),
		string.format("%d MB", perf.memoryMb or 0),
		string.format("%d instances", perf.instances or 0))

	add("roads", "Road network", if edges > 0 then "ok" else "fail",
		string.format("%d lanes", edges),
		if edges > 0 then string.format("%d nodes", nodes) else "No drivable roads are loaded")

	add("dead_ends", "Nav dead-ends", if deadEnds == 0 then "ok" elseif deadEnds <= 4 then "warn" else "warn",
		tostring(deadEnds),
		if deadEnds == 0 then "Every lane has a legal exit" else "Lanes with no exit but a U-turn")

	local sidewalkStatus = if citizens.sidewalkBuilt or pop == 0 then "ok" else "fail"
	add("sidewalks", "Sidewalk graph", sidewalkStatus,
		if citizens.sidewalkBuilt then "built" else "missing",
		if sidewalkStatus == "fail" then "Pedestrians cannot path with population present" else "Walk network ready")

	add("stuck", "Stuck vehicles", band(traffic.stuck or 0, 1, 4, true),
		tostring(traffic.stuck or 0),
		string.format("%d active, %d stopped", traffic.active or 0, traffic.stopped or 0))

	local abandonedFrac = if buildings.total > 0 then buildings.abandoned / buildings.total else 0
	add("abandoned", "Abandoned buildings", if abandonedFrac >= 0.25 then "fail" elseif buildings.abandoned > 0 then "warn" else "ok",
		string.format("%d / %d", buildings.abandoned, buildings.total),
		string.format("%.0f%% of the city", abandonedFrac * 100))

	if citizens.adults > 0 then
		local unemployed = citizens.adults - citizens.employed
		local frac = unemployed / citizens.adults
		add("jobs", "Unemployment", if frac >= 0.4 then "fail" elseif frac >= 0.2 then "warn" else "ok",
			string.format("%.0f%%", frac * 100),
			string.format("%d of %d adults without a job", unemployed, citizens.adults))
	end

	if economy.treasury ~= nil then
		add("treasury", "Treasury", band(economy.treasury, 1000, 0, false),
			string.format("$%d", economy.treasury),
			if economy.supplyRatio ~= nil then string.format("supply %.0f%%", economy.supplyRatio * 100) else "")
	end

	add("errors", "Server errors / min", band(#_errorTimes, 1, 6, true),
		tostring(#_errorTimes),
		string.format("%d warnings", #_warnTimes))

	if save.lastAt ~= nil and (save.lastAt or 0) > 0 then
		local saveStatus = if save.lastOk == false then "fail" elseif (save.lastMs or 0) > 2000 then "warn" else "ok"
		add("save", "Last city save", saveStatus,
			string.format("%.0f ms", save.lastMs or 0),
			string.format("%s, %.1f KB, next %.0fs", tostring(save.lastReason or "save"), (save.lastBytes or 0) / 1024, save.nextAutosaveIn or 0))
	end

	do
		local usageKB = tonumber(save.playerUsageKB) or 0
		local capKB = tonumber(save.playerCapKB) or 950
		local rejected = tostring(save.rejected or "")
		if usageKB > 0 or rejected ~= "" then
			local frac = if capKB > 0 then usageKB / capKB else 0
			local status = if rejected ~= "" then "fail" elseif frac >= 0.8 then "warn" else "ok"
			add("data_budget", "Save data budget", status,
				string.format("%d / %d KB", usageKB, capKB),
				if rejected ~= "" then "SAVE BLOCKED: " .. rejected
				else string.format("%d KB per-city cap, 1 MB hard ceiling", tonumber(save.slotCapKB) or 150))
		end
	end

	local summary = { ok = 0, warn = 0, fail = 0 }
	for _, c in checks do summary[c.status] = (summary[c.status] or 0) + 1 end

	local profileTotal = 0
	for _, row in profileRows do
		profileTotal += tonumber(row.ms) or 0
	end
	table.sort(profileRows, function(a, b)
		return (tonumber(a.ms) or 0) > (tonumber(b.ms) or 0)
	end)
	local profile = { rows = profileRows, totalMs = profileTotal }

	return {
		checks = checks, summary = summary,
		perf = perf, traffic = traffic, nav = nav, buildings = buildings,
		citizens = citizens, agents = agents, economy = economy, parking = parking, log = log,
		save = save, profile = profile,
	}
end

-- --------------------------------------------------------------- geometry --

local function buildingParking(camPos: Vector3?, radius: number): { any }
	local pads: { any } = {}
	if not (_buildingService and _buildingService.listBuildings and _buildingService.getParkSpots) then
		return pads
	end
	local radiusSq = radius * radius
	local function near(p: Vector3): boolean
		if not camPos then return true end
		local dx, dz = p.X - camPos.X, p.Z - camPos.Z
		return (dx * dx + dz * dz) <= radiusSq
	end
	for _, b in _buildingService.listBuildings() do
		if #pads >= MAX_BUILDING_PADS then break end
		if b.position and not near(b.position) then continue end
		local spots = _buildingService.getParkSpots(b.bpId)
		if not spots then continue end
		if spots.home then
			table.insert(pads, { pos = spots.home.Position, kind = "home" })
		end
		for _, stall in spots.stalls or {} do
			if #pads >= MAX_BUILDING_PADS then break end
			table.insert(pads, { pos = stall.cf.Position, kind = "stall" })
		end
	end
	return pads
end

local function buildGeometry(camPos: Vector3?, radius: number, layers: { [string]: any }): { [string]: any }
	local out: { [string]: any } = {}

	if layers.stopLines and _npcService and _npcService.GetTrafficDebug then
		local data = safeCall({ stopLines = {} }, function()
			return _npcService.GetTrafficDebug(camPos, radius)
		end)
		out.stopLines = data.stopLines
	end

	if (layers.lanes or layers.deadEnds) and _npcService and _npcService.GetLaneDebug then
		local data = safeCall({ lanes = {}, deadEnds = {} }, function()
			return _npcService.GetLaneDebug(camPos, radius)
		end)
		if layers.lanes then out.lanes = data.lanes end
		if layers.deadEnds then out.deadEnds = data.deadEnds end
	end

	if layers.jams and _npcService and _npcService.GetJamDebug then
		out.jams = safeCall({}, function()
			return _npcService.GetJamDebug(camPos, radius)
		end)
	end

	if layers.parking then
		out.parking = {
			street = safeCall({}, function()
				return if _parkingService and _parkingService.GetParkingDebug then _parkingService.GetParkingDebug(camPos, radius) else {}
			end),
			pads = safeCall({}, function() return buildingParking(camPos, radius) end),
		}
	end

	return out
end

-- Server-side accessors for the two feeds, exposed so they can be exercised in a
-- test harness without a live client. The remotes (below) wrap these with the admin
-- check + rate limit -- these raw builders perform NO authorisation, so they must
-- never be reachable from the client (this is a server-only module).
function DeveloperService.BuildReport(): { [string]: any }
	return buildReport()
end

function DeveloperService.BuildGeometry(camPos: Vector3?, radius: number?, layers: { [string]: any }?): { [string]: any }
	local r = if typeof(radius) == "number" and radius == radius
		then math.clamp(radius, GEOMETRY_MIN_RADIUS, GEOMETRY_MAX_RADIUS)
		else GEOMETRY_DEF_RADIUS
	local cp: Vector3? = if finiteVector(camPos) then camPos else nil
	local ls = if typeof(layers) == "table" then layers else { stopLines = true, lanes = true, parking = true, deadEnds = true, jams = true }
	return buildGeometry(cp, r, ls)
end

-- --------------------------------------------------- outside connections --
-- Admin-only F6 "Map" tab. "list" returns the auto-detected edge connections (roads a
-- player has dragged to the map boundary) for a readout; "saveMapDefault" bakes the
-- whole loaded city as that map's default for every new player (via CitySlotService).
-- One action-dispatched RemoteFunction.

local OC_MIN_INTERVAL = 0.25

local function ocList(): { any }
	local out: { any } = {}
	if not _outsideConnService then return out end
	for _, c in _outsideConnService.list() do
		table.insert(out, { id = c.id, side = c.side, dir = c.dir, x = c.outer.X, z = c.outer.Z, rt = c.roadType })
	end
	return out
end

local function onOutsideConn(player: Player, action: any, payload: any): { [string]: any }
	if not isAdmin(player) then
		warn("[DeveloperService] Unauthorised outside-connection request from", player.Name)
		return { ok = false, error = "Admin only." }
	end
	local now = os.clock()
	local last = _lastOcAt[player]
	if last and now - last < OC_MIN_INTERVAL then return { ok = false, error = "Too fast." } end
	_lastOcAt[player] = now

	if action == "list" then
		-- Auto-detected edge connections (roads dragged to the boundary). Read-only readout.
		return { ok = true, conns = ocList() }
	elseif action == "saveMapDefault" then
		-- Bake the player's whole loaded city as the DEFAULT for its map: every new player
		-- who starts a city on this map begins from this layout. Yields (DataStore write).
		if not _citySlotService or not _citySlotService.saveLoadedCityAsTemplate then
			return { ok = false, error = "Map templates are unavailable." }
		end
		local ok, msg = _citySlotService.saveLoadedCityAsTemplate(player)
		return { ok = ok, message = msg, conns = ocList() }
	end
	return { ok = false, error = "unknown action" }
end

-- ------------------------------------------------------------- lifecycle --

-- Tier-2 citizen agents. Injected late (like SetOutsideConnService) because
-- CitizenAgentService is constructed after the panel and is optional -- with it unset the
-- agents block simply reports zeroes.
function DeveloperService.SetAgentService(svc: any)
	_agentService = svc
end

function DeveloperService.Init(
	reportRemote: RemoteFunction,
	geometryRemote: RemoteFunction,
	adminService: any,
	roadService: any,
	npcService: any,
	parkingService: any,
	buildingService: any,
	citizenService: any,
	cityStatsService: any,
	economyService: any,
	ocRemote: RemoteFunction?,
	outsideConnService: any?
)
	assert(reportRemote and geometryRemote, "[DeveloperService] remotes required")
	assert(adminService and adminService.TierOf, "[DeveloperService] AdminService (TierOf) required")
	assert(roadService, "[DeveloperService] RoadService required")
	_reportRemote = reportRemote
	_geometryRemote = geometryRemote
	_adminService = adminService
	_roadService = roadService
	_npcService = npcService
	_parkingService = parkingService
	_buildingService = buildingService
	_citizenService = citizenService
	_cityStatsService = cityStatsService
	_economyService = economyService
	_ocRemote = ocRemote
	_outsideConnService = outsideConnService
end

-- OutsideConnectionService is created after this service in the boot order (it needs
-- terrain), so it is injected here once available. The remote is wired at Init; the
-- handler reads this ref at call time, long after boot.
function DeveloperService.SetOutsideConnService(svc: any)
	_outsideConnService = svc
end

-- CitySlotService is created after this service in the boot order; injected here so the
-- F6 "saveMapDefault" action can bake the loaded city as the map default.
function DeveloperService.SetCitySlotService(svc: any)
	_citySlotService = svc
end

function DeveloperService.Bind()
	local report = _reportRemote
	local geometry = _geometryRemote
	if not report or not geometry then
		error("[DeveloperService] Init must run before Bind")
	end

	if _logConn then _logConn:Disconnect() end
	_logConn = LogService.MessageOut:Connect(function(_: string, messageType: Enum.MessageType)
		if messageType == Enum.MessageType.MessageError then
			table.insert(_errorTimes, os.clock())
		elseif messageType == Enum.MessageType.MessageWarning then
			table.insert(_warnTimes, os.clock())
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		_lastReportAt[player] = nil
		_lastGeometryAt[player] = nil
		_lastOcAt[player] = nil
	end)

	report.OnServerInvoke = function(player: Player): { [string]: any }?
		if not isAdmin(player) then
			warn("[DeveloperService] Unauthorised report request from", player.Name)
			return nil
		end
		local now = os.clock()
		local last = _lastReportAt[player]
		if last and now - last < REPORT_MIN_INTERVAL then return nil end
		_lastReportAt[player] = now
		return safeCall(nil, buildReport)
	end

	geometry.OnServerInvoke = function(player: Player, camPos: any, radius: any, layers: any): { [string]: any }?
		if not isAdmin(player) then
			warn("[DeveloperService] Unauthorised geometry request from", player.Name)
			return nil
		end
		local now = os.clock()
		local last = _lastGeometryAt[player]
		if last and now - last < GEOMETRY_MIN_INTERVAL then return nil end
		_lastGeometryAt[player] = now

		return safeCall(nil, function() return DeveloperService.BuildGeometry(camPos, radius, layers) end)
	end

	if _ocRemote then
		_ocRemote.OnServerInvoke = onOutsideConn
	end
end

function DeveloperService.Start()
end

return DeveloperService
