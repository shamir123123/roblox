--!strict

local RS  = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")
local Players    = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local RunService = game:GetService("RunService")

-- Open road/zone editing to everyone only in Studio. In a live server editing is
-- gated per-player via the CanEditRoads attribute (see canPlayerEditRoads / canEdit).
workspace:SetAttribute("RoadEditOpen", RunService:IsStudio())
workspace:SetAttribute("GameSpeed", 1) -- 0 = paused, 1/2/3 = time multiplier (player-controlled)
-- The household sim now supplies all on-road life (commuting citizen cars + delivery
-- trucks), so the old ambient random cruisers/pedestrians are off by default. Set
-- RandomTrafficEnabled=true / AmbientWalkerCount>0 to bring background traffic back.
workspace:SetAttribute("RandomTrafficEnabled", false)
workspace:SetAttribute("AmbientWalkerCount", 0)

local Net = require(RS:WaitForChild("Networker"))
local PlacesConfig = require(RS:WaitForChild("Access"):WaitForChild("PlacesConfig"))

local servicesFolder = SSS:WaitForChild("Services")
local accessFolder   = servicesFolder:WaitForChild("Access")

-- Staff permissions FIRST, because everything below asks it who someone is. Who counts as
-- a tester and who counts as an admin is a DataStore record (the owner edits it from the
-- staff panel's Access tab), not a table in a script -- so the read has to be in flight
-- before the join gate can answer. Start() launches it immediately; the gate holds a
-- joiner for a moment rather than guessing.
local StaffRoster = require(accessFolder:WaitForChild("StaffRoster"))
StaffRoster.Init(Net)
StaffRoster.Bind()
StaffRoster.Start()

-- Closed-test access gate: a non-tester is kicked on join before any data
-- loads or GUI clones. Bypassed in Studio so the developer can always test.
local TesterService = require(accessFolder:WaitForChild("TesterService"))
TesterService.Init()
TesterService.Bind()
-- Roblox badges: "joined the game" for everyone, "closed tester" for the roster.
-- Ids live in BadgeService; a badge with id 0 is skipped, so this is inert until the
-- badges are created on the Creator Dashboard.
local BadgeService = require(accessFolder:WaitForChild("BadgeService"))
BadgeService.Init(TesterService)
BadgeService.Bind()

local PlayerDataStore = require(servicesFolder:WaitForChild("Data"):WaitForChild("PlayerDataStore"))
PlayerDataStore.Init()
PlayerDataStore.Bind()

-- Join gate: holds the joining player on the loading screen until their profile record
-- and city slot index are both in, reporting progress through Player attributes. Bound
-- HERE, straight after the record load it watches, so the very first joiner is tracked
-- from the moment they arrive rather than from the end of this boot script.
local PlayerLoadService = require(servicesFolder:WaitForChild("Data"):WaitForChild("PlayerLoadService"))
PlayerLoadService.Init(PlayerDataStore)
PlayerLoadService.Bind()

-- Per-player game settings (graphics / audio / keybinds): validated field
-- writes on top of PlayerDataStore; the client's Core.SettingsClient pulls
-- once at boot and pushes debounced payloads.
local PlayerSettingsService = require(servicesFolder:WaitForChild("Data"):WaitForChild("PlayerSettingsService"))
PlayerSettingsService.Init(Net, PlayerDataStore)
PlayerSettingsService.Bind()

-- Per-player CITY access gate. On a reserved city server, kick anyone who is not
-- the owner, an invited visitor, or staff. No-op in Studio and on public servers,
-- so the ordinary menu / single-server flow is untouched until the hub exists.
local AdminService = require(servicesFolder:WaitForChild("Debug"):WaitForChild("AdminService"))
-- One server per player: on a public server every joiner is sent straight on to their
-- own reserved city server. Required before the gate, which reroutes uninvited joiners
-- into their own city through it rather than kicking them.
local CityTeleport = require(servicesFolder.Access:WaitForChild("CityTeleport"))
CityTeleport.Bind()

local PlaceAccessService = require(servicesFolder.Access:WaitForChild("PlaceAccessService"))
PlaceAccessService.Init(AdminService, PlayerDataStore, CityTeleport)
PlaceAccessService.Bind()
PlaceAccessService.Start()

-- Who is online across every server, for the F4 Cities tab. ABOVE the lobby cut on purpose:
-- a player sitting in the menu is still online, and an admin looking for them should see
-- them there rather than only once they are inside a city.
local PlayerDirectoryService = require(servicesFolder.Access:WaitForChild("PlayerDirectoryService"))
PlayerDirectoryService.Init(AdminService)
PlayerDirectoryService.Bind()

Players.CharacterAutoLoads = false

local function cloneGuiToPlayer(player: Player)
	local playerGui = player:WaitForChild("PlayerGui", 30)
	if not playerGui then
		warn("[Bootstrap] PlayerGui missing for", player.Name)
		return
	end

	for _, gui in StarterGui:GetChildren() do
		local existing = playerGui:FindFirstChild(gui.Name)
		if existing then existing:Destroy() end
		gui:Clone().Parent = playerGui
	end
end

-- Per-player streaming focus parts. With no character, StreamingEnabled has no default
-- replication centre, so the free-cam world would not stream in. Each player gets an
-- anchored focus part the ReportCameraPos handler moves to their camera's ground look-at.
-- All of this is inert when StreamingEnabled is off (ReplicationFocus is then ignored).
local _streamFocusFolder = Instance.new("Folder")
_streamFocusFolder.Name = "_StreamFocus"
_streamFocusFolder.Parent = workspace
local _focusParts: { [Player]: BasePart } = {}

local function bindPlayer(player: Player)
	task.spawn(cloneGuiToPlayer, player)

	local focusPart = Instance.new("Part")
	focusPart.Name = "StreamFocus_" .. tostring(player.UserId)
	focusPart.Anchored = true
	focusPart.CanCollide = false
	focusPart.CanQuery = false
	focusPart.CanTouch = false
	focusPart.Transparency = 1
	focusPart.Size = Vector3.one
	focusPart.CFrame = CFrame.new(0, 0, 0)
	focusPart.Parent = _streamFocusFolder
	_focusParts[player] = focusPart
	player.ReplicationFocus = focusPart

	player.CharacterAdded:Connect(function(char: Model)
		task.defer(function()
			if char and char.Parent then char:Destroy() end
		end)
	end)

	if player.Character then
		task.defer(function()
			if player.Character then player.Character:Destroy() end
		end)
	end
end

Players.PlayerAdded:Connect(bindPlayer)

for _, p in Players:GetPlayers() do
	bindPlayer(p)
end

-- ---------- THE LOBBY CUT ----------
-- Everything ABOVE is core and runs in both places: staff roster, tester gate, player
-- record, settings, the access gate, and the no-character camera rig. Everything BELOW
-- is the city itself -- roads, plots, the sim, traffic, economy, ~300 modules that a
-- main menu has no use for and never requires.
--
-- The SAME file is published to BOTH places; which half runs is decided by game.PlaceId
-- in PlacesConfig, so there is no second copy of anything to keep in sync. While
-- CITY_PLACE_ID is still 0 this is never true and the whole place boots as it always did.
if PlacesConfig.isLobby() then
	-- The lobby's entire server. The player record, settings and access gate are already
	-- up; the menu needs three more things -- the city slot INDEX, blueprints, and the
	-- lifetime stats card -- and none of the city itself.
	local BlueprintStore = require(servicesFolder:WaitForChild("Data"):WaitForChild("BlueprintStore"))
	BlueprintStore.Init(PlayerDataStore)

	local PlayerStatsService = require(servicesFolder:WaitForChild("Data"):WaitForChild("PlayerStatsService"))
	PlayerStatsService.Init(PlayerDataStore, BlueprintStore, Net)
	PlayerStatsService.Bind()

	-- InitLobby, not Init: the index half only, and no Start() -- see CitySlotService.
	local CitySlotService = require(servicesFolder:WaitForChild("Data"):WaitForChild("CitySlotService"))
	CitySlotService.InitLobby(AdminService)
	CitySlotService.SetPlayerStatsService(PlayerStatsService)
	CitySlotService.SetCityTeleport(CityTeleport)
	-- The friends-cities list reads other players' stored guest lists and door flags.
	CitySlotService.SetPlayerDataStore(PlayerDataStore)
	-- ...and the invite index that says WHOSE lists to read. Harmless here beyond that: a
	-- lobby never resolves an owner, so getOwnerId() stays 0 and nobody is a guest of it.
	CitySlotService.SetPlaceAccessService(PlaceAccessService)
	CitySlotService.Bind()
	-- A lobby never holds a city, so the directory rows from here say "in the menu".
	PlayerDirectoryService.SetCityContext(CitySlotService.standingCity)

	-- The join gate holds the loading screen until the player record AND the slot index
	-- are both in. It is the same gate in both places.
	PlayerLoadService.SetCitySlotService(CitySlotService)
	return
end

-- Where everyone else is looking, pooled and pushed back out ~10x a second for the client's
-- PlayerPresenceView. Below the lobby cut: a menu has no map to put anybody on. Depends on
-- nothing but the Networker, so it is brought up first and never blocks anything after it.
local PlayerPresenceService = require(servicesFolder.Access:WaitForChild("PlayerPresenceService"))
PlayerPresenceService.Init()
PlayerPresenceService.Bind()

local services             = SSS:WaitForChild("Services")
local roadFolder           = services:WaitForChild("Road")
local cityFolder           = services:WaitForChild("City")
local cityCivicFolder      = cityFolder:WaitForChild("Civic")
local citySimulationFolder = cityFolder:WaitForChild("Simulation")
local cityEconomyFolder    = cityFolder:WaitForChild("Economy")
local npcFolder            = services:WaitForChild("NPC")
local trafficFolder        = services:WaitForChild("Traffic")
local RoadService          = require(roadFolder:WaitForChild("RoadService"))
local PlotService          = require(cityFolder:WaitForChild("PlotService"))
local BuildingService      = require(cityFolder:WaitForChild("BuildingService"))
local CityStatsService     = require(cityFolder:WaitForChild("CityStatsService"))
local CoverageService      = require(cityCivicFolder:WaitForChild("CoverageService"))
local LandValueService     = require(cityFolder:WaitForChild("LandValueService"))
local ZoneSimService       = require(citySimulationFolder:WaitForChild("ZoneSimService"))
local LotDressingService   = require(cityFolder:WaitForChild("LotDressingService"))
local CityEconomyService   = require(cityEconomyFolder:WaitForChild("CityEconomyService"))
local TimeService          = require(cityFolder:WaitForChild("TimeService"))
local CitizenService       = require(citySimulationFolder:WaitForChild("CitizenService"))
local FireService          = require(citySimulationFolder:WaitForChild("FireService"))
local ParkingService       = require(cityFolder:WaitForChild("ParkingService"))
local SupplyService        = require(cityEconomyFolder:WaitForChild("SupplyService"))
local EducationService     = require(cityCivicFolder:WaitForChild("EducationService"))
local EmergencyService     = require(cityCivicFolder:WaitForChild("EmergencyService"))
local CrimeService         = require(cityCivicFolder:WaitForChild("CrimeService"))
local SicknessService      = require(cityCivicFolder:WaitForChild("SicknessService"))
local DeathcareService     = require(cityCivicFolder:WaitForChild("DeathcareService"))
local EmergencyDispatch    = require(cityCivicFolder:WaitForChild("EmergencyDispatch"))
local npcDriverModule      = npcFolder:WaitForChild("NPCDriverService")
local NPCDriverService     = require(npcDriverModule)
-- Tier 2 of the citizen population: agents with a real route and an honest travel time but
-- no body. Takes the walkers that NPCWalkingService cannot give a body to (MAX_WALKERS),
-- which used to teleport instead.
local CitizenAgentService  = require(npcFolder:WaitForChild("CitizenAgentService"))
local NPCWalkingService    = require(npcFolder:WaitForChild("NPCWalkingService"))
local TrafficSignalService = require(trafficFolder:WaitForChild("TrafficSignalService"))
-- Player-authored signal timings: the store persists them, the replication service is
-- the network boundary for the in-game signal editor.
local SignalPlanStore      = require(trafficFolder:WaitForChild("SignalPlanStore"))
local SignalReplication    = require(trafficFolder:WaitForChild("SignalReplicationService"))
local transitFolder        = services:WaitForChild("Transit")
local TransitService       = require(transitFolder:WaitForChild("TransitService"))
local BusDispatchService   = require(transitFolder:WaitForChild("BusDispatchService"))
local TrainDispatchService = require(transitFolder:WaitForChild("TrainDispatchService"))
local ProgressionService   = require(cityFolder:WaitForChild("ProgressionService"))


-- Init

RoadService.Init()
ParkingService.Init(RoadService)
-- Burgage plots: server-authoritative plot groups, and the ONLY zoning system now (the
-- lot/tile grid is gone). Reads roads through RoadService for segment lookup and
-- replicates groups to the client PlotController.
PlotService.Init(RoadService, Net, BuildingService)
-- EmergencyService also owns the utility buildings; CoverageService answers utility
-- queries, handing power and water/sewage to PowerService and WaterService below.
CoverageService.Init(RoadService, EmergencyService)
LotDressingService.Init()
BuildingService.Init(CoverageService, LotDressingService)
LandValueService.Init(CoverageService, EducationService)
-- SupplyService.Init runs a few lines later -- safe: the ref is only read inside tick().
CityStatsService.Init(BuildingService, EducationService, SupplyService, CoverageService)
-- Demand-gated construction: a claimed lot holds as a nest until the city wants the zone
-- built (BuildingService reads RCI demand from here before running the crane build).
BuildingService.SetCityStats(CityStatsService)
SupplyService.Init(BuildingService, RoadService)
-- Economy reads road length (upkeep), and service-building asset costs (upkeep), so
-- it takes RoadService + Emergency/Education in addition to its core deps.
CityEconomyService.Init(BuildingService, CityStatsService, SupplyService, RoadService, EmergencyService, EducationService, CitizenService)
-- Interactive road placement is charged to the treasury (by the metre).
RoadService.setEconomyService(CityEconomyService)
-- Interactive road/roundabout placement clears buildings the new pavement is laid over.
RoadService.setBuildingClearance(BuildingService.demolishUnderPavement)
TimeService.Init()
-- CitizenService drives the full citizen commute: it spawns pedestrians via
-- NPCWalkingService for the house<->car and car<->workplace walk legs.
EducationService.Init(Net, BuildingService, CityEconomyService)
CitizenService.Init(RoadService, BuildingService, CityStatsService, TimeService, ParkingService, NPCWalkingService, CityEconomyService, SupplyService, EducationService)
EmergencyService.Init(Net, BuildingService, CityEconomyService, CoverageService)
-- Electricity. PowerService owns the poles the player lays and the grid they form; the
-- turbines themselves stay EmergencyService's (it places every service building), so this
-- reads them back through that reference rather than owning two kinds of thing.
local PowerService = require(cityFolder:WaitForChild("PowerService"))
PowerService.Init(Net, BuildingService, EmergencyService, CityEconomyService, CityStatsService, RoadService)
-- Every road carries power, so a street drawn or bulldozed re-wires the grid.
RoadService.onTopologyChanged(PowerService.markRoadsDirty)
-- Power stops being a coverage radius and becomes a grid: whether a plot has electricity
-- is now "is it wired to a generator that is keeping up", which is what land value and
-- building levels have always asked CoverageService.
CoverageService.setPowerService(PowerService)
-- Two turbines whose rotors would overlap is not something a footprint test can catch.
EmergencyService.setPowerService(PowerService)
-- Electricity bought at the map edge is a running cost; surplus sold there is income.
CityEconomyService.setPowerService(PowerService)
-- Water and sewage: one pooled network fed by the towers and drained by the sewage plants
-- EmergencyService places. Land value and happiness ask it who is actually served.
-- The mains. EVERY ROAD CARRIES ONE, so this reads the road graph as well as the runs the
-- player draws by hand; a tower is only a SOURCE now, and reaching a house is the pipe's
-- job. Init before WaterService, which asks it who is reached.
local WaterPipeService = require(cityFolder:WaitForChild("WaterPipeService"))
WaterPipeService.Init(Net, EmergencyService, CityEconomyService, RoadService)
-- A street drawn or bulldozed is a main laid or lifted with it.
RoadService.onTopologyChanged(WaterPipeService.markDirty)
local WaterService = require(cityFolder:WaitForChild("WaterService"))
-- Pumps and treatment plants run on electricity, so it asks PowerService who got some.
WaterService.Init(Net, BuildingService, EmergencyService, WaterPipeService, CityStatsService, PowerService)
CoverageService.setWaterService(WaterService)
-- Public transit: TransitService owns depots/stops/routes; BusDispatchService runs the
-- visible fleet on the same nav graph + DriveDirected AI the citizen cars use.
TransitService.Init(Net, RoadService, BuildingService, CityEconomyService)
BusDispatchService.Init(TransitService, RoadService)
-- Trains loop rail-only routes on their own mover (no depots, no car traffic AI).
TrainDispatchService.Init(TransitService)
-- The service fleet: police cars, fire engines, ambulances and hearses. Owns the
-- drive from station to scene so the four civic sims below do not each carry their
-- own copy of it. Needs the road network to route on.
EmergencyDispatch.Init(RoadService)
CrimeService.Init(BuildingService, EmergencyService, CityStatsService, CityEconomyService, EmergencyDispatch)
SicknessService.Init(BuildingService, EmergencyService, CityStatsService, EmergencyDispatch, CityEconomyService)
-- Deaths: bodies at homes, hearse pickup by Cemeteries (EmergencyService kind
-- "Deathcare"); sick households die faster, unburied bodies dent happiness.
DeathcareService.Init(BuildingService, EmergencyService, SicknessService, CityStatsService, EmergencyDispatch)
-- Fires: buildings ignite over time; a Fire Station in range sends an engine and the
-- fire burns until it arrives; an uncovered fire spreads. Standalone sim, cleared on
-- city load (see CitySerializer).
FireService.Init(BuildingService, EmergencyService, EmergencyDispatch, CityEconomyService)
-- Each active delivery truck occupies one industrial job slot; CitizenService owns
-- occupancy, so the fleet (SupplyService) reserves/releases through it.
SupplyService.SetCitizenService(CitizenService)
-- Citizens weigh the bus against the car each commute; TransitService answers the estimate.
CitizenService.SetTransitService(TransitService)
-- Staffed service buildings are workplaces too: a solar farm's `jobs` are filled by real
-- citizens who commute to it. EmergencyService owns every placed service building, so
-- CitizenService asks it for the workplace views. Injected late, like the two above --
-- it only has to exist before the first adult goes looking for work.
CitizenService.SetEmergencyService(EmergencyService)
-- Bus fares feed income; depot + bus upkeep feed the monthly running costs.
CityEconomyService.SetTransitService(TransitService)
-- Clearing the transit domain (city unload) also wipes the live bus + train fleets.
TransitService.setFleetClearer(function()
	BusDispatchService.clear()
	TrainDispatchService.clear()
	-- Tier-2 agents are plans, not instances, so the Workspace._City sweep cannot see them;
	-- drop them here or a reloaded city inherits the last city's commuters.
	CitizenAgentService.clear()
end)
ZoneSimService.Init(CityStatsService, LandValueService, BuildingService)
-- Progression: XP milestones + the DP Development Tree. Read-only over the domain
-- getters; credits rewards through the economy and replicates the City Hall snapshot.
ProgressionService.Init(Net, CityStatsService, CityEconomyService, RoadService, EducationService, EmergencyService, TransitService)
-- Development Tree placement gating, SERVER-SIDE. Without these four lines the tree is
-- decorative: the client hides a locked card, but the remote behind it still builds.
RoadService.setUnlockCheck(ProgressionService.isRoadAllowed)
EmergencyService.setUnlockCheck(ProgressionService.isPlaceableAllowed)
-- Sewage is needed from the milestone that unlocks a way to deal with it.
WaterService.setUnlockCheck(ProgressionService.isPlaceableAllowed)
EducationService.setUnlockCheck(ProgressionService.isPlaceableAllowed)
TransitService.setUnlockCheck(ProgressionService.isPlaceableAllowed)
PlotService.setUnlockCheck(ProgressionService.isDensityAllowed)

-- Territory: which map TILES the city owns. The other, POSITIONAL half of placement
-- gating -- the unlock checks above answer "is this thing available", this answers "is this
-- ground yours". A 6x6 grid; a new city owns the one tile its starting interchange stands
-- on and buys the rest outward, gated on a milestone allowance AND money (see
-- TerritoryService). Boots here because it needs the economy and progression and because
-- every placement service below has to be handed its check.
local TerritoryService = require(cityFolder:WaitForChild("TerritoryService"))
TerritoryService.Init(CityEconomyService, ProgressionService)
TerritoryService.Bind()
TerritoryService.Start()
-- Same shape as the unlock gates: the owning service keeps no reference to Territory, it is
-- handed a predicate. Without these the tile grid is decorative in exactly the way the
-- Development Tree was before its four lines above.
RoadService.setTerritoryCheck(TerritoryService.isSpanAllowed)
EmergencyService.setTerritoryCheck(TerritoryService.isBoxAllowed)
EducationService.setTerritoryCheck(TerritoryService.isBoxAllowed)
TransitService.setTerritoryCheck(TerritoryService.isBoxAllowed)
-- A milestone is what raises the allowance, so the panel has to hear about it when one
-- lands rather than on the next unrelated change.
ProgressionService.setTerritoryService(TerritoryService)
CityEconomyService.setLandUpkeep(TerritoryService.getMonthlyUpkeep)
-- No building may stand in the road. A road carries no queryable geometry, so the overlap
-- box in ServicePlacement cannot see one: PlacementFit answers it off the segment list
-- instead, and needs handing the network here and after every edit to it.
local PlacementFit = require(RS:WaitForChild("Shared"):WaitForChild("PlacementFit"))
local function syncPlacementRoads()
	PlacementFit.setRoadSegments(RoadService.getNetwork():getSegments())
end
syncPlacementRoads()
RoadService.onTopologyChanged(syncPlacementRoads)
-- Development Tree EXTRAS: DP-bought upgrades widen service coverage, fleet sizes and
-- class sizes by multiplying what a funding level DOES (never what it costs).
CityEconomyService.setFundingBoost(ProgressionService.getFundingBoost)
NPCDriverService.Init(RoadService)
-- Also calls SignalPlanStore.Init: the store is the signal service's own state, not a
-- peer service, so it is not wired separately here.
TrafficSignalService.Init(RoadService)
SignalReplication.Init(TrafficSignalService, RoadService)
-- Adaptive signal timing reads NPC queue sizes; injected here to avoid a
-- require cycle (NPCDriverService already requires TrafficSignalService).
TrafficSignalService.SetQueueProvider(NPCDriverService.GetSignalQueue)
NPCWalkingService.SetRoadService(RoadService)
NPCWalkingService.Init(nil, Net)
-- Simulation LOD. CitizenAgentService requires nothing from NPCWalkingService at load time
-- (it is handed the reference), and NPCWalkingService calls back into it on walker-cap
-- overflow -- injected both ways here to avoid a require cycle.
CitizenAgentService.Init(NPCWalkingService)
NPCWalkingService.SetAgentService(CitizenAgentService)

-- Bind

RoadService.Bind()
ParkingService.Bind()
CoverageService.Bind()
PlotService.Bind()
BuildingService.Bind()
LotDressingService.Bind()
LandValueService.Bind()
CityStatsService.Bind()
CityEconomyService.Bind()
TimeService.Bind()
CitizenService.Bind()
SupplyService.Bind()
EducationService.Bind()
EmergencyService.Bind()
PowerService.Bind()
WaterPipeService.Bind()
TransitService.Bind()
EmergencyDispatch.Bind()
CrimeService.Bind()
SicknessService.Bind()
DeathcareService.Bind()
FireService.Bind()
ZoneSimService.Bind()
ProgressionService.Bind()
NPCDriverService.Bind()
TrafficSignalService.Bind()
SignalReplication.Bind()
NPCWalkingService.Bind()
CitizenAgentService.Bind()

-- Start

RoadService.Start()
ParkingService.Start()
CoverageService.Start()
PlotService.Start()
BuildingService.Start()
LandValueService.Start()
CityStatsService.Start()
CitizenService.Start()
SupplyService.Start()
EducationService.Start()
EmergencyService.Start()
PowerService.Start()
WaterService.Start()
-- CIVIC OFF: the four "you need a station" pressure sims are not started, so the city
-- never burns, gets robbed, gets sick or piles up bodies while Civic/Utilities placement
-- is hidden from the bottom bar. Init/Bind still run so every injected ref stays valid and
-- their getters answer 0. Re-enable by restoring these four Start() calls.
-- EmergencyDispatch.Start()
-- CrimeService.Start()
-- SicknessService.Start()
-- DeathcareService.Start()
-- FireService.Start()
ZoneSimService.Start()
ProgressionService.Start()
NPCDriverService.Start()
TrafficSignalService.Start()
BusDispatchService.Start()
-- TRAINS OFF: the rail fleet never runs. Init/Bind still happen and clear() stays wired
-- into the transit fleet clearer, so a saved city with train lines loads without spawning
-- anything. Re-enable by restoring this Start() call.
-- TrainDispatchService.Start()
-- TimeService.Start(), CityEconomyService.Start() and TransitService.Start() are
-- intentionally NOT called here. Starting them at server boot would tick/broadcast
-- (SyncTime/SyncEconomy/SyncTransit) for a city that does not exist yet -- e.g. while
-- every player is still in the main menu, before any save slot has loaded. CitySlotService
-- starts all three exactly once, right after a city actually finishes loading.
NPCWalkingService.Start()
CitizenAgentService.Start()

local function getNav()
	local nav = RoadService.getNavigationGraph()
	return (nav and nav:HasEdges()) and nav or nil
end

local RoadConstants = require(RS:WaitForChild("Road"):WaitForChild("RoadConstants"))
local NAV_REQUEST_COOLDOWN = 0.1
local _lastNavRequestAt: { [Player]: number } = {}
local GAME_SPEED_COOLDOWN = 0.1
local _lastGameSpeedAt: { [Player]: number } = {}

local function validNavPosition(pos: any): boolean
	if typeof(pos) ~= "Vector3" or pos ~= pos or pos.Magnitude >= math.huge then
		return false
	end

	local h = RoadConstants.MAP_HALF_EXTENT
	return math.abs(pos.X) <= h and math.abs(pos.Z) <= h
end

Players.PlayerRemoving:Connect(function(player: Player)
	_lastNavRequestAt[player] = nil
	_lastGameSpeedAt[player] = nil
	local fp = _focusParts[player]
	if fp then fp:Destroy(); _focusParts[player] = nil end
end)

-- Streaming focus: move each player's focus part to where their camera looks at the
-- ground, reconstructed from the throttled ReportCameraPos {pos,yaw,pitch}. Gated on the
-- city having content so the initial load streams/settles around the city centre (origin)
-- before the focus starts tracking. Additive listener -- NPCDriverService also listens.
Net.ReportCameraPos.OnServerEvent:Connect(function(player: Player, payload: any)
	if not workspace.StreamingEnabled then return end -- focus only matters under streaming
	local part = _focusParts[player]
	if not part or typeof(payload) ~= "table" then return end
	local pos = payload.pos
	local yaw = tonumber(payload.yaw)
	local pitch = tonumber(payload.pitch)
	if typeof(pos) ~= "Vector3" or not yaw or not pitch then return end
	local city = workspace:FindFirstChild("_City")
	if not city then return end
	local roads = city:FindFirstChild("Roads")
	local blds = city:FindFirstChild("ZonedBuildings")
	if (not roads or #roads:GetChildren() == 0) and (not blds or #blds:GetChildren() == 0) then
		return -- no city yet: leave focus at origin
	end
	local yawR, pitchR = math.rad(yaw), math.rad(pitch)
	local cosP = math.cos(pitchR)
	local dir = Vector3.new(-math.sin(yawR) * cosP, math.sin(pitchR), -math.cos(yawR) * cosP)
	local groundY = RoadConstants.getGroundY()
	local focus: Vector3
	if dir.Y < -0.05 then
		focus = pos + dir * ((groundY - pos.Y) / dir.Y)
	else
		focus = Vector3.new(pos.X, groundY, pos.Z)
	end
	if focus ~= focus or focus.Magnitude >= math.huge then return end
	local h = RoadConstants.MAP_HALF_EXTENT
	part.Position = Vector3.new(math.clamp(focus.X, -h, h), groundY, math.clamp(focus.Z, -h, h))
end)

-- Player-controlled simulation speed (pause / 1x / 2x / 3x). Rate-limited, NaN-
-- guarded and change-gated: without this a client could spam SetAttribute (one
-- GameSpeed replication to every client per call) or poison every sim loop's
-- task.wait(TICK / math.max(1, speed)) with a NaN speed.
Net.RequestGameSpeed.OnServerEvent:Connect(function(player: Player, speed: any)
	if typeof(speed) ~= "number" or speed ~= speed then return end
	local now = os.clock()
	local last = _lastGameSpeedAt[player]
	if last and now - last < GAME_SPEED_COOLDOWN then return end
	_lastGameSpeedAt[player] = now
	local clamped = math.clamp(math.floor(speed), 0, 3)
	if workspace:GetAttribute("GameSpeed") ~= clamped then
		workspace:SetAttribute("GameSpeed", clamped)
	end
end)

Net.RequestNavPath.OnServerInvoke = function(
	player: Player,
	startPos: Vector3,
	goalPos: Vector3
): (boolean, {Vector3}?)
	local now = os.clock()
	local last = _lastNavRequestAt[player]

	if last and now - last < NAV_REQUEST_COOLDOWN then
		return false, nil
	end

	_lastNavRequestAt[player] = now

	if not validNavPosition(startPos) or not validNavPosition(goalPos) then
		return false, nil
	end

	local nav = getNav()
	if not nav then return false, nil end

	local ok, waypoints = pcall(function()
		return nav:FindPath(startPos, goalPos)
	end)

	if not ok or not waypoints or #waypoints == 0 then return false, nil end

	return true, waypoints
end

local DebugService = require(services:WaitForChild("Debug"):WaitForChild("DebugService"))
DebugService.Init(RoadService, Net.DebugSnapshot, Net.ToggleDebugMode)
DebugService.Bind()
DebugService.Start()

AdminService.Init(
	Net.RequestServerDebugStats,
	Net.RequestNavRoutes,
	Net.RequestNpcSpeeds,
	Net.RequestAdminAddMoney,
	Net.RequestAdminSpawnTraffic,
	Net.RequestAdminCityAction,
	Net.RequestAdminInspect,
	RoadService,
	NPCDriverService,
	NPCWalkingService,
	CitizenService,
	BuildingService,
	CityEconomyService,
	TimeService,
	Net.SaveStaffLauncherPos,
	Net.RequestStaffLauncherPos
)
AdminService.Bind()
AdminService.Start()

-- Staff UI delivery. The F4 admin/tester panel and the F6 developer panel are no longer
-- in StarterPlayerScripts (which replicates to EVERY client): they sit in ServerStorage
-- and are cloned into a player's PlayerGui only once StaffRoster confirms they are staff.
-- Bound AFTER AdminService so the AdminTier / IsPlaceOwner attributes are already stamped
-- by the time a panel arrives and reads them to decide which tabs to draw.
local StaffUIService = require(accessFolder:WaitForChild("StaffUIService"))
StaffUIService.Init(StaffRoster)
StaffUIService.Bind()
StaffUIService.Start()

-- Developer panel (F6): the deeper diagnostics sibling of the admin panel. Reads every
-- domain through its public getters and re-checks admin tier (via AdminService) on each
-- call. Health report + camera-filtered overlay geometry (stop lines, lane network +
-- congestion, parking, nav dead-ends).
local DeveloperService = require(services:WaitForChild("Debug"):WaitForChild("DeveloperService"))
DeveloperService.Init(
	Net.RequestDevReport,
	Net.RequestDevGeometry,
	AdminService,
	RoadService,
	NPCDriverService,
	ParkingService,
	BuildingService,
	CitizenService,
	CityStatsService,
	CityEconomyService,
	Net.RequestDevOutsideConn
)
-- Tier-2 agent counts in the F6 report. Set late (like SetOutsideConnService) so the panel
-- stays optional -- unset, the agents block just reports zeroes.
DeveloperService.SetAgentService(CitizenAgentService)
DeveloperService.Bind()
DeveloperService.Start()

-- Terrain
local terrainFolder = services:WaitForChild("Terrain")
local TerrainDataService = require(terrainFolder:WaitForChild("TerrainDataService"))
local TerrainRenderer = require(terrainFolder:WaitForChild("TerrainRenderer"))
local TerrainEditService = require(terrainFolder:WaitForChild("TerrainEditService"))

TerrainDataService.Init()
TerrainRenderer.Init(TerrainDataService)
TerrainEditService.Init(TerrainDataService)

TerrainDataService.Bind()
TerrainRenderer.Bind()
TerrainEditService.Bind()

TerrainDataService.Start()
TerrainRenderer.Start()
TerrainEditService.Start()

-- Nature tab: decorative tree / bush / rock placement (line + brush). Ground-snaps to
-- the authoritative terrain height. Reads RoadService (read-only, injected) to keep props
-- off paved roads; buildings and other props it asks the world about through the shared
-- PlacementFit, so it needs no building dependency at all. Slots in after Terrain, Road
-- and Building.
local NaturePlaceService = require(cityFolder:WaitForChild("NaturePlaceService"))
NaturePlaceService.Init(RoadService, CityEconomyService)
NaturePlaceService.Bind()
NaturePlaceService.Start()
-- The other half of "a road wins": planting a tree on a carriageway is refused, and laying
-- a carriageway over one removes it. Wired here rather than beside setBuildingClearance
-- above because NaturePlaceService does not exist yet at that point in the boot.
RoadService.setNatureClearance(NaturePlaceService.clearUnderPavement)

-- What a brand-new map ARRIVES with: the preset highways chosen on the create screen, plus
-- the trees and rocks on land nobody has built on. Runs once per city CREATION (the fresh
-- branch of CitySlotService), never on a load -- roads and props are both persisted by the
-- services that own them, so a saved city already carries whatever this laid down.
local MapSeedService = require(cityFolder:WaitForChild("MapSeedService"))
MapSeedService.Init(RoadService, NaturePlaceService)
-- Planting obeys the tile grid too, so a player cannot decorate land they have not bought.
-- The map's own trees are exempt (they carry `wild`), which is why this can be absolute.
NaturePlaceService.setTerritoryCheck(TerritoryService.isPointAllowed)

-- Creation Editor: owns each player's isolated in-world edit session (its own Workspace
-- folder, never the live _City). Standalone -- no gameplay service depends on it, so it
-- slots in with no wiring.
-- Player-authored designs get their own DataStore: one key per blueprint, 4 MB to
-- itself. The player record carries only the index row per creation, so listing "My
-- Creations" costs no reads and a design is fetched on open.
local BlueprintStore = require(servicesFolder:WaitForChild("Data"):WaitForChild("BlueprintStore"))
BlueprintStore.Init(PlayerDataStore)

local EditorService = require(services:WaitForChild("Editor"):WaitForChild("EditorService"))
EditorService.Init(PlayerDataStore, BlueprintStore)

-- Placing a saved creation into the live city: the way OUT of the editor. Decorative
-- only (no coverage, no upkeep, no sim role), so like NaturePlaceService nothing else
-- depends on it. Takes the editor's spawnable catalog as an injected resolver rather
-- than requiring EditorService, so it does not care which of the two booted first.
local CreationPlaceService = require(cityFolder:WaitForChild("CreationPlaceService"))
CreationPlaceService.Init(Net, CityEconomyService, BlueprintStore)
CreationPlaceService.setAssetResolver(EditorService.resolveAsset)

-- The gate between "a player built something" and "everyone can see it". A creation stays
-- private until its author submits it and a curator or admin approves it, so nothing
-- reaches another player without a human having looked at it. Authority is StaffRoster's
-- canApprove -- injected, never a tier string compared here.
local ReviewQueue = require(accessFolder:WaitForChild("ReviewQueue"))
ReviewQueue.Init(Net, BlueprintStore, StaffRoster)
ReviewQueue.Bind()
ReviewQueue.Start()
-- Approved work is placeable by everyone, not just its author. Injected rather than
-- required because the review queue boots after the placement service; unset, only your
-- own creations are placeable, which is the safe direction to fail.
CreationPlaceService.setReviewQueue(ReviewQueue)
-- And the other direction: a moderator takedown has to reach copies already standing in
-- this server's city, not just the catalogue. ReviewQueue calls this after its own
-- takedown and after every refresh, so a verdict from another server lands here too.
ReviewQueue.setRevocationSweeper(CreationPlaceService.sweepRevoked)

-- The player's lifetime record (time played, sessions, cities founded, best population).
-- Rides PlayerDataStore's record as one "stats" field; counts blueprints off the index
-- rather than storing the number.
local PlayerStatsService = require(servicesFolder:WaitForChild("Data"):WaitForChild("PlayerStatsService"))
PlayerStatsService.Init(PlayerDataStore, BlueprintStore, Net)
PlayerStatsService.Bind()
EditorService.Bind()
EditorService.Start()
CreationPlaceService.Bind()
CreationPlaceService.Start()

-- Outside Connections: map-edge road links (the city's tie to the outside world).
-- DERIVED, not placed -- it scans the road graph for roads a player dragged to the map
-- edge and shows an outward arrow at each. Needs RoadService (terrain kept for height).
-- Re-scans on every road edit (RoadService.onTopologyChanged) and on load (CitySerializer).
local OutsideConnectionService = require(cityFolder:WaitForChild("OutsideConnectionService"))
OutsideConnectionService.Init(RoadService, TerrainDataService)
OutsideConnectionService.Bind()
OutsideConnectionService.Start()
-- The F6 dev panel reads the detected connections through this service (injected: it is
-- created after DeveloperService in the boot order).
DeveloperService.SetOutsideConnService(OutsideConnectionService)
-- Arrivals + cosmetic move-ins spawn at real outside connections (not random dead-ends).
CitizenService.SetOutsideConnService(OutsideConnectionService)
-- Cars that drive out through an outside connection despawn at the edge (they left the city).
NPCDriverService.SetOutsideConnService(OutsideConnectionService)
-- Imports drive in and exports drive out through the same connections.
SupplyService.SetOutsideConnService(OutsideConnectionService)
-- Inter-city through traffic: background cars entering at one connection, crossing on
-- the traffic AI, despawning at another. Needs the connections, so it boots here.
local ThroughTrafficService = require(citySimulationFolder:WaitForChild("ThroughTrafficService"))
-- TimeService drives the demand curve: how much through traffic the entrances admit is
-- a function of the hour, so the background flow peaks with the household commute
-- instead of running flat all night.
ThroughTrafficService.Init(RoadService, OutsideConnectionService, TimeService)
ThroughTrafficService.Start()

-- City persistence: slots own terrain/roads/zones/buildings (PlayerDataStore
-- keeps only per-player prefs). Nothing city-side loads at join; the world
-- builds when the player picks a slot (RequestLoadSlot -> CityLoadResult).
local CitySerializer  = require(servicesFolder:WaitForChild("Data"):WaitForChild("CitySerializer"))
local CitySlotService = require(servicesFolder:WaitForChild("Data"):WaitForChild("CitySlotService"))
-- Per-map DEFAULT city templates (own DataStore). The F6 dev panel bakes the loaded
-- city here; a NEW city started on a map that has a template restores it instead of
-- generating empty procedural terrain.
local MapTemplateService = require(servicesFolder:WaitForChild("Data"):WaitForChild("MapTemplateService"))
MapTemplateService.Init()
CitySerializer.Init(RoadService, BuildingService, TerrainDataService, CityEconomyService, CitizenService, EducationService, EmergencyService, FireService, TransitService, TimeService, OutsideConnectionService, PlotService, NaturePlaceService, ProgressionService, SignalPlanStore, CreationPlaceService, ThroughTrafficService, SupplyService, PowerService, WaterPipeService)
CitySlotService.Init(CitySerializer, CityStatsService, TerrainDataService, TerrainRenderer, AdminService, TimeService, OutsideConnectionService, MapTemplateService, CityEconomyService, TransitService)
-- The F6 dev panel's "save as map default" routes through CitySlotService (it owns the
-- loaded city + the serializer). Injected here, after CitySlotService exists.
DeveloperService.SetCitySlotService(CitySlotService)
-- Founding and saving a city are the two counters CitySlotService can see.
CitySlotService.SetPlayerStatsService(PlayerStatsService)
-- Lobby only: picking a slot there teleports instead of building. Inert in a city server.
CitySlotService.SetCityTeleport(CityTeleport)
-- A city carries its own solo/multiplayer choice; the join gate only learns it on load.
CitySlotService.SetPlaceAccessService(PlaceAccessService)
-- Lets the online directory name the city this server is showing, so an admin's list reads
-- "Riverside, pop 400" instead of just a player name.
PlayerDirectoryService.SetCityContext(CitySlotService.standingCity)
CitySlotService.SetPlayerDataStore(PlayerDataStore)
-- Dressing a fresh map needs roads and props, so MapSeedService boots after both and is
-- injected here rather than taken by CitySlotService.Init.
CitySlotService.SetMapSeedService(MapSeedService)
-- Land: the serializer saves and restores it, and a FRESH city is granted its first tile
-- here rather than in the serializer, because there is no blob to restore one from.
CitySerializer.SetTerritoryService(TerritoryService)
CitySerializer.SetBusDispatchService(BusDispatchService)
CitySlotService.SetTerritoryService(TerritoryService)
-- The join gate's second half: slot sessions start loading on join, but this service is
-- only built here, so it is injected rather than required up front (see PlayerLoadService).
PlayerLoadService.SetCitySlotService(CitySlotService)
CitySlotService.Bind()
CitySlotService.Start()
