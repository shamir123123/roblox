--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local isServer          = RunService:IsServer()

local folder: Folder
if isServer then
	local existing = ReplicatedStorage:FindFirstChild("Remotes")
	if existing and existing:IsA("Folder") then
		folder = existing
	else
		if existing then existing:Destroy() end
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
	end
else
	folder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
end

local function RE(name: string): RemoteEvent
	local r = folder:FindFirstChild(name)
	if r and r:IsA("RemoteEvent") then return r :: RemoteEvent end
	assert(isServer, "[Networker] Client tried to create RemoteEvent '"..name.."'")
	if r then r:Destroy() end
	local e = Instance.new("RemoteEvent")
	e.Name = name; e.Parent = folder
	return e
end

local function URE(name: string): UnreliableRemoteEvent
	local r = folder:FindFirstChild(name)
	if r and r:IsA("UnreliableRemoteEvent") then return r :: UnreliableRemoteEvent end
	assert(isServer, "[Networker] Client tried to create UnreliableRemoteEvent '"..name.."'")
	if r then r:Destroy() end
	local e = Instance.new("UnreliableRemoteEvent")
	e.Name = name; e.Parent = folder
	return e
end

local function RF(name: string): RemoteFunction
	local r = folder:FindFirstChild(name)
	if r and r:IsA("RemoteFunction") then return r :: RemoteFunction end
	assert(isServer, "[Networker] Client tried to create RemoteFunction '"..name.."'")
	if r then r:Destroy() end
	local f = Instance.new("RemoteFunction")
	f.Name = name; f.Parent = folder
	return f
end

local Networker = {
	_folder = folder,

	SyncNodes                    = RE("SyncNodes"),
	SyncSegments                 = RE("SyncSegments"),
	SyncIntersections            = RE("SyncIntersections"),
	SyncIntersectionTurnSettings = RE("SyncIntersectionTurnSettings"),
	SyncIntersectionLanePaths    = RE("SyncIntersectionLanePaths"),
	SyncLaneChangeGates          = RE("SyncLaneChangeGates"),
	SyncNodesDelta               = RE("SyncNodesDelta"),
	SyncSegmentsDelta            = RE("SyncSegmentsDelta"),
	PlaceRoadResult              = RE("PlaceRoadResult"),
	-- Server -> all clients after any successful charged placement: (worldPos, amount).
	-- Purely cosmetic (floating "-$X" tag); the treasury itself syncs via SyncEconomy.
	PlacementCharged             = RE("PlacementCharged"),

	RequestPlaceRoad                    = RE("RequestPlaceRoad"),
	RequestPlaceRoundabout              = RE("RequestPlaceRoundabout"),
	-- Roundabout tool: set the centre preset of the roundabout at a point.
	-- { center: Vector3 (any point inside the ring), preset: string }.
	RequestSetRoundaboutPreset          = RE("RequestSetRoundaboutPreset"),
	RequestReplaceRoadSegment           = RE("RequestReplaceRoadSegment"),
	RequestRemoveRoadSegment            = RE("RequestRemoveRoadSegment"),
	RequestRemoveRoadSegments           = RE("RequestRemoveRoadSegments"),
	-- Move tool: relocate a node (intersection / road end) or bend one segment
	-- through a dragged point. { kind: "node"|"segment", id: number, target: Vector3 }.
	RequestMoveRoad                     = RE("RequestMoveRoad"),
	-- Street naming. Rename applies to the whole street the segment belongs to
	-- (client -> server, validated + rate-limited); an empty name clears the
	-- override and the street reverts to its auto-generated name.
	RequestSetRoadName                  = RE("RequestSetRoadName"),
	-- Client -> server (RF): live traffic for the street a segment is on, for the
	-- road info panel. Read-only, polled only while that panel is open.
	RequestRoadTraffic                  = RF("RequestRoadTraffic"),

	RequestUndoRoad                     = RE("RequestUndoRoad"),
	RequestRedoRoad                     = RE("RequestRedoRoad"),

	RequestSetIntersectionTurn          = RE("RequestSetIntersectionTurn"),
	RequestSetIntersectionLaneTurn      = RE("RequestSetIntersectionLaneTurn"),
	RequestSetIntersectionConnection    = RE("RequestSetIntersectionConnection"),
	RequestSetIntersectionConnectionHandle = RE("RequestSetIntersectionConnectionHandle"),
	RequestResetIntersectionConnections = RE("RequestResetIntersectionConnections"),
	RequestSetLaneChangeConnection      = RE("RequestSetLaneChangeConnection"),

	-- Traffic signal editor. The plan for one junction (timings, per-arm left-turn
	-- treatment, pedestrian mode) and the corridor groups that tie several junctions
	-- to one cycle. Everything is sanitised server-side through Road.SignalSpec, so
	-- these carry raw tables rather than a fixed argument list.
	RequestSetSignalPlan                = RE("RequestSetSignalPlan"),
	-- { action = "create"|"join"|"leave"|"settings"|"delete"|"autoCycle", ... }
	RequestSignalGroupEdit              = RE("RequestSignalGroupEdit"),
	-- Client -> server (RF): the signal editor's read side -- the pickable junction
	-- list, the corridor list, and the full snapshot of one junction. Read-only and
	-- polled only while the panel is open, exactly like RequestRoadTraffic.
	RequestSignalData                   = RF("RequestSignalData"),
	-- Client -> server: the Roads panel's Traffic Light card. Carries the clicked ground
	-- point; the server finds the junction under it and turns its lights on or off.
	RequestToggleJunctionLights         = RE("RequestToggleJunctionLights"),

	ReportZoningActive           = RE("ReportZoningActive"),
	-- Server -> client zone paint state: full snapshot on join, { id, zone } deltas on
	-- paint. The client renders the lot grid locally (computed from the road network),
	-- so only the painted-zone state needs to cross the wire, not the tiles themselves.
	RequestDemolishBuilding      = RE("RequestDemolishBuilding"),

	-- Manor Lords burgage plots. Client draws a frontage span on a road; the server
	-- validates + stores the plot group and replicates it (full on join, delta on place).
	-- Clients subdivide each group into plots via PlotGeometry for rendering.
	RequestPlacePlots            = RE("RequestPlacePlots"),
	SyncPlots                    = RE("SyncPlots"),
	-- Client -> server (RF): the placeable-building catalog { zone, w, d, name } for the
	-- single-building picker. Static data; the client fetches once and caches it.
	RequestBuildingCatalog       = RF("RequestBuildingCatalog"),

	RequestTerrainEdit           = RE("RequestTerrainEdit"),
	SyncConstructionSites        = RE("SyncConstructionSites"),

	SyncCityStats                = RE("SyncCityStats"),
	SyncEconomy                  = RE("SyncEconomy"),
	-- Client -> server: set the R/C/I tax rates (percent). Validated + rate-limited.
	RequestSetBudget             = RE("RequestSetBudget"),
	-- Server -> client: the city has gone bankrupt (hard game-over). Carries final stats.
	Bankruptcy                   = RE("Bankruptcy"),
	-- Server -> client transient toast feed: { text = string, kind = "info"|"success"|
	-- "warning"|"danger", duration = number? }. NotificationController renders it.
	Notify                       = RE("Notify"),
	-- Server -> client progression snapshot: XP, milestones and Development Tree state
	-- (ProgressionService). Sent on join, on city load and whenever a milestone is
	-- reached or a node is unlocked; ProgressionController renders it.
	SyncProgression              = RE("SyncProgression"),
	-- Client -> server: spend Development Points on one Development Tree node
	-- (nodeId string). Validated + rate-limited in ProgressionService; the updated
	-- tree state rides the next SyncProgression snapshot.
	RequestDevUnlock             = RE("RequestDevUnlock"),
	-- Server -> client: which map TILES the city owns, how many it may own at this
	-- milestone, and what the next one costs (TerritoryService). Pushed on join, on city
	-- load, on every purchase and whenever a milestone raises the allowance -- never
	-- polled, because the allowance changes on the server.
	SyncTerritory                = RE("SyncTerritory"),
	SyncTime                     = RE("SyncTime"),
	RequestGameSpeed             = RE("RequestGameSpeed"),

	-- Client -> server (RF): how much DataStore room the loaded city is using, for the
	-- storage readout in the settings panel. Read-only; CitySlotService answers it.
	-- Client -> server (RF): buy one map tile by id. Answers (false, reason) with the
	-- refusal in words, so the panel can say WHY rather than just greying out. Every gate
	-- -- edit rights, adjacency, milestone allowance, price -- is re-checked server-side.
	RequestBuyTile               = RF("RequestBuyTile"),
	RequestCityMemory            = RF("RequestCityMemory"),
	RequestSlotIndex             = RF("RequestSlotIndex"),
	RequestCreateSlot            = RF("RequestCreateSlot"),
	RequestDeleteSlot            = RF("RequestDeleteSlot"),
	RequestRenameSlot            = RF("RequestRenameSlot"),
	RequestSaveCity              = RF("RequestSaveCity"),
	-- Client -> server (RF): who may be in MY city and as what. One action remote in the
	-- RequestEditorData style -- { action = "list" | "grant" | "revoke", ... }. Only the
	-- resolved owner of the reserved server it arrives on may change anything; the role
	-- string is normalized or refused, never defaulted. PlaceAccessService answers it.
	RequestCityAccess            = RF("RequestCityAccess"),
	-- Client -> server (RF): solo or shared, for the city standing in this server. nil
	-- reads, a boolean writes. Owner only -- an admin guest hands out roles, but whether
	-- the city is open at all is the owner's call. CitySlotService answers it (it owns the
	-- slot the flag is stored on); the live join gate is updated in the same breath.
	RequestCitySharing           = RF("RequestCitySharing"),
	-- Client -> server, then server -> every client: where each player's camera is and what
	-- ground point their cursor is over, so the others can be drawn on the map. UNRELIABLE
	-- on both legs on purpose -- a dropped frame of presence is a marker a tenth of a second
	-- stale, and resending it late is worse than skipping it. Never read back as state.
	-- Client -> server (RF): everyone playing right now, across every server, for the F4
	-- Cities tab. Admin only; PlayerDirectoryService answers it off a shared MemoryStore map.
	RequestOnlinePlayers         = RF("RequestOnlinePlayers"),
	ReportPresence               = URE("ReportPresence"),
	SyncPresence                 = URE("SyncPresence"),
	-- Client -> server (RF): the cities of a friend who has let friends visit, so the
	-- lobby can offer them. Read-only, rate-limited, friend-checked server-side.
	RequestFriendCities          = RF("RequestFriendCities"),
	RequestReseatBuildings       = RF("RequestReseatBuildings"),
	RequestLoadSlot              = RE("RequestLoadSlot"),

	CityLoadResult               = RE("CityLoadResult"),
	-- Each client builds its own terrain locally from the seed + edited chunks (no
	-- full-map voxel replication). Client asks; server streams seed + edited-chunk buffers.
	RequestTerrainBuild          = RE("RequestTerrainBuild"),
	TerrainBuildData             = RE("TerrainBuildData"),

	RequestNavPath               = RF("RequestNavPath"),

	-- Server -> clients, unreliable/unordered: the batched NPC pose stream (cars +
	-- walkers near any player). Each packet is a buffer: f64 timestamp header, then
	-- <=45 entries of (id u32, x/y/z f32, yaw u16, pitch i8) = 19 bytes per pose.
	-- Property CFrames only carry the spawn pose and the far keepalive; the client
	-- views (NPCDriverView / PedestrianView) drive the models from this stream.
	-- There is deliberately NO client->server counterpart: clients cannot report
	-- NPC positions back, so this opens zero exploit surface.
	SyncNpcPoses                 = URE("SyncNpcPoses"),

	RequestServerDebugStats      = RF("RequestServerDebugStats"),
	RequestNavRoutes             = RF("RequestNavRoutes"),
	RequestNpcSpeeds             = RF("RequestNpcSpeeds"),
	RequestAdminAddMoney         = RF("RequestAdminAddMoney"),
	RequestAdminSpawnTraffic     = RF("RequestAdminSpawnTraffic"),
	RequestAdminCityAction       = RF("RequestAdminCityAction"),
	RequestAdminInspect          = RF("RequestAdminInspect"),
	RequestAdminPlayerSaves      = RF("RequestAdminPlayerSaves"),
	RequestAdminLoadSaveCopy     = RF("RequestAdminLoadSaveCopy"),

	-- Staff roster, OWNER ONLY. Action-dispatched: { action = "list"|"grant"|"revoke",
	-- userId = number?, tier = "tester"|"curator"|"admin"? }. Who is staff is a DataStore record
	-- rather than a table in a script, and this is how the owner edits it from the panel's
	-- Access tab. StaffRoster re-checks that the caller IS the place owner on every call --
	-- the client's IsPlaceOwner attribute only decides whether the tab is drawn.
	RequestStaffRoster           = RF("RequestStaffRoster"),

	-- Creation review. Action-dispatched: { action = "submit"|"mine"|"list"|"approve"
	-- |"reject"|"unpublish", id = string?, reason = string? }. "submit" and "mine" are an
	-- author acting on their OWN work and need no tier; everything else is a review action
	-- and ReviewQueue re-asks StaffRoster.canApprove on every call, so the client's
	-- AdminTier attribute only decides whether the Review tab is drawn.
	RequestReviewQueue           = RF("RequestReviewQueue"),

	-- A ROW of creations from one gesture (line / curve / brush), as (bpId, { CFrame }).
	-- One blueprint many times, not a mixed palette -- which is why this is far simpler than
	-- RequestPlaceNature's per-item payload. Batched because the alternative is one remote
	-- per placement racing the per-player cooldown, and half a line silently not appearing.
	RequestPlaceCreations        = RE("RequestPlaceCreations"),

	-- Developer panel (F6, admin tier only). Report = the health/diagnostics dashboard
	-- (numbers + pass/warn/fail checks). Geometry = camera-radius-filtered overlay data
	-- (stop lines, lane network + congestion, parking occupancy, nav dead-ends), layer-
	-- gated so the client only pays for the overlays it has switched on.
	RequestDevReport             = RF("RequestDevReport"),
	RequestDevGeometry           = RF("RequestDevGeometry"),
	-- Outside-connection authoring (F6 dev tool, admin-only). Action-dispatched:
	-- list / place / remove / bake. See DeveloperService.
	RequestDevOutsideConn        = RF("RequestDevOutsideConn"),

	RequestWalkPath              = RF("RequestWalkPath"),

	SpawnTestWalker              = RE("SpawnTestWalker"),

	DebugSnapshot                = RE("DebugSnapshot"),
	ToggleDebugMode              = RE("ToggleDebugMode"),

	-- Staff launcher pill (the "STAFF F4" button shown when the admin/dev panels are
	-- closed) remembers where each staff member dragged it to. Save is fire-and-forget
	-- on drag-end; the get is a one-shot fetch when the panel is built.
	SaveStaffLauncherPos         = RE("SaveStaffLauncherPos"),
	RequestStaffLauncherPos      = RF("RequestStaffLauncherPos"),

	-- Per-player game settings (the client Core.Settings store). Client pulls once
	-- at boot (nil until the player first saves anything); pushes a debounced full
	-- payload on any change. Stored as one field in PlayerDataStore's record
	-- (PlayerSettingsService validates before the field is written).
	RequestPlayerSettings        = RF("RequestPlayerSettings"),
	RequestSaveSettings          = RE("RequestSaveSettings"),

	-- Client -> server (RF): the player's lifetime record for the Player Hub
	-- (time played, sessions, cities founded, best population, blueprint count).
	-- Rate-limited server-side; pulled when the hub opens, not streamed.
	RequestPlayerStats           = RF("RequestPlayerStats"),

	ReportCameraPos              = RE("ReportCameraPos"),
	RequestFamilyInfo            = RF("RequestFamilyInfo"),
	RequestWorkforceInfo         = RF("RequestWorkforceInfo"),
	RequestCitizenPos            = RF("RequestCitizenPos"),
	RequestPresenceNear          = RF("RequestPresenceNear"),
	RequestPlaceService          = RE("RequestPlaceService"),
	RequestRemoveService         = RE("RequestRemoveService"),
	-- Move tool: reposition an already-placed service building. Same kind-dispatch
	-- as RequestRemoveService: (kind: "Emergency"|"Education", id: number, pivot: CFrame).
	-- The owning service validates, re-grounds Y and keeps id/occupants/coverage.
	RequestMoveService           = RE("RequestMoveService"),

	-- Nature tab: client -> server batch of decorative props to plant (trees / bushes /
	-- rocks). Payload = { { key, pos, yaw, scale }, ... }. Validated + rate-limited +
	-- ground-snapped server-side (NaturePlaceService). Cosmetic: not persisted with the city.
	RequestPlaceNature           = RE("RequestPlaceNature"),
	-- Nature tab / bulldozer: client -> server list of planted NatureProp models to remove.
	-- Server validates each is in _City.Nature and tagged before destroying.
	RequestRemoveNature          = RE("RequestRemoveNature"),
	-- Move tool: reposition / re-yaw planted props. { { model, pos, yaw }, ... }.
	-- Same validation as placement (bounds, road/building exclusion, ground snap).
	RequestMoveNature            = RE("RequestMoveNature"),

	-- Public transit (buses). One command remote (action-dispatched, validated +
	-- rate-limited server-side) covers bus-stop placement and every route edit;
	-- SyncTransit streams depots / stops / routes + live line stats to the client for
	-- the route overlay and the Transportation Overview panel. The Bus Depot is an
	-- ordinary lot-grid service building, so it reuses RequestPlaceService /
	-- RequestRemoveService with kind = "Transit".
	RequestTransitCommand        = RE("RequestTransitCommand"),
	SyncTransit                  = RE("SyncTransit"),

	-- Creation Editor: client asks to open / close its isolated in-world edit session
	-- (EditorService). Validated + rate-limited server-side.
	RequestEnterEditor           = RE("RequestEnterEditor"),
	RequestExitEditor            = RE("RequestExitEditor"),
	-- Editor mutations (action-dispatched): spawn / primitive / transform / scale /
	-- appearance / delete / duplicate / clear / load. Validated + throttled per-action.
	RequestEditorCommand         = RE("RequestEditorCommand"),
	-- Editor reads + saves that need a reply (action-dispatched): catalog / save / list /
	-- deleteCreation. The asset catalog is static; the client fetches once and caches it.
	RequestEditorData            = RF("RequestEditorData"),
}

function Networker:WaitForRemote(name: string, timeout: number?): RemoteEvent | RemoteFunction
	local t = timeout or 30
	if self[name] then return self[name] :: any end
	local inst = folder:WaitForChild(name, t)
	if not inst then
		error("[Networker] Remote '"..name.."' not found after "..t.."s")
	end
	return inst :: any
end

return Networker