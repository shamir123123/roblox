--!strict

local PlayerScripts = script.Parent.Parent
local core        = PlayerScripts:WaitForChild("Core")
local hud         = PlayerScripts:WaitForChild("HUD")
local world       = PlayerScripts:WaitForChild("World")
local UITheme = require(PlayerScripts:WaitForChild("UI"):WaitForChild("Theme"))
local PlacesConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("Access"):WaitForChild("PlacesConfig"))

-- The staff panels (F4 admin/tester, F6 developer) are NOT started here any more. They
-- live in ServerStorage and the server clones them into PlayerScripts only for a player
-- it has confirmed is staff, so on an ordinary client there is nothing to require. The
-- bundle brings itself up -- see ServerStorage.StaffUI.StaffTools.StaffBoot.

-- Every Start() below runs through this. Bootstrap is one serial script, so before this
-- an error in any unprotected step silently deleted every controller after it -- which is
-- how a client could end up with a bottom bar and no HUD, panels or world views at all,
-- with nothing in the log to say why.
local function protect(label: string, fn: () -> ()): boolean
	local ok, err = pcall(fn)
	if not ok then
		warn("[Bootstrap] " .. label .. " failed to start: " .. tostring(err))
	end
	return ok
end

local CacheSync = require(core:WaitForChild("CacheSync"))
protect("CacheSync", function() CacheSync.Start() end)

-- Settings: engine appliers + per-player persistence (pull saved settings,
-- push on change). Before FreeCam/UI so persisted values apply from the start.
local SettingsClient = require(core:WaitForChild("SettingsClient"))
protect("SettingsClient", function() SettingsClient.Start() end)

-- City autosave (Settings > Gameplay): saves on a timer while a city is loaded.
local AutoSave = require(core:WaitForChild("AutoSave"))
protect("AutoSave", function() AutoSave.Start() end)

local FreeCamController = require(core:WaitForChild("FreeCamController"))
protect("FreeCamController", function() FreeCamController.Start() end)

-- Client UI is built entirely in code; edit-mode StarterGui is empty. Create the
-- shared HUD ScreenGui and mount the standalone UIs before any controller looks for
-- them, then bring up the main menu.
local Players = game:GetService("Players")
local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

if not playerGui:FindFirstChild("CityUI") then
	local cityUI = Instance.new("ScreenGui")
	cityUI.Name = "CityUI"
	cityUI.ResetOnSpawn = false
	cityUI.DisplayOrder = UITheme.Layer.HUD
	cityUI.IgnoreGuiInset = false
	cityUI.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	cityUI.Parent = playerGui
end

local uiFolder = PlayerScripts:WaitForChild("UI")
local uiCreation = PlayerScripts:WaitForChild("UICreation")

-- Warm every UI icon before the first controller builds a button. Icons are otherwise
-- fetched lazily as each ImageLabel mounts, and on a cold cache that burst loses the race
-- and leaves blank chips. Instances, not id strings: PreloadAsync reports Failure for raw
-- rbxassetid strings even when the asset is perfectly fine.
task.spawn(function()
	local ContentProvider = game:GetService("ContentProvider")
	local ok, err = pcall(function()
		local probes = {}
		for _, id in require(uiFolder:WaitForChild("Icons")).allImageIds() do
			local probe = Instance.new("ImageLabel")
			probe.Image = id
			table.insert(probes, probe)
		end
		ContentProvider:PreloadAsync(probes)
		for _, probe in probes do
			probe:Destroy()
		end
	end)
	if not ok then
		warn("[Bootstrap] icon preload failed: " .. tostring(err))
	end
end)

--[[ ponytail: JUNCTION TOOLS OFF -- lane view button + LaneTools gui. Uncomment with the
LaneConnectorView / NodeToolView / SignalToolView blocks below to restore.
protect("LaneToolsView", function()
	require(uiCreation:WaitForChild("LaneToolsView")).mount(playerGui)
end)
]]

local okMenu = pcall(function()
	require(uiFolder:WaitForChild("MainMenu"):WaitForChild("MainMenuController")).Start()
end)
if not okMenu then
	warn("[Bootstrap] MainMenuController failed to start")
	-- The join loading screen waits on the menu's first slot fetch. If the menu never got
	-- that far, release the step here rather than leaving the player on a black screen
	-- until the gate times out.
	local ReplicatedStorageSvc = game:GetService("ReplicatedStorage")
	require(ReplicatedStorageSvc:WaitForChild("Shared"):WaitForChild("ClientBootGate")).markDone("menu")
end

-- ---------- THE LOBBY CUT ----------
-- See the server Bootstrap for the other half. ABOVE: settings, free cam, the CityUI
-- ScreenGui and the main menu -- everything the lobby is. BELOW: every gameplay
-- controller and world view, none of which has a city to attach to in a menu place.
--
-- AutoSave above is deliberately left running: it only fires while a city is loaded, so
-- in the lobby it is already inert and a branch would cost more than it saves.
if PlacesConfig.isLobby() then
	return
end

local BottomBarController = require(PlayerScripts:WaitForChild("Controllers"):WaitForChild("BottomBarController"))
protect("BottomBarController", function() BottomBarController.Start() end)

local CityStatsController = require(hud:WaitForChild("CityStatsController"))
protect("CityStatsController", function() CityStatsController.Start() end)

-- On-screen HUD zones + on-demand dashboards + toast notifications. Each screen
-- zone is its own module and owns exactly one region: TopLeftCluster (menu chip,
-- role badge, clock, sim speed), CityVitalsPanel (treasury/citizens/demand, top
-- right), ToolRail (the build tools, bottom centre). GameMenuController owns only
-- the pause menu those chips open.
-- Each is isolated: a UI fault must never halt the gameplay controllers below it.
local function startUI(name: string)
	local ok, err = pcall(function()
		require(hud:WaitForChild(name)).Start()
	end)
	if not ok then
		warn("[Bootstrap] UI controller " .. name .. " failed to start: " .. tostring(err))
	end
end

startUI("NotificationController")
startUI("FloatingCostEffect")
startUI("RadioController")
startUI("DashboardController")
startUI("GameMenuController")
startUI("TopLeftCluster")
startUI("CityVitalsPanel")
startUI("PlayerHubController")
startUI("ProgressionController")
startUI("BuildingInfoController")
startUI("ElectricityPanelController")
startUI("WaterPanelController")
-- ponytail: ROAD CLICK OFF -- uncomment to restore the street panel (name, length,
-- speed limit, live traffic, rename).
-- startUI("RoadInfoController")
startUI("BankruptcyController")
startUI("EconomyPanelController")
startUI("TransportOverviewController")

local ConstructionViewController = require(world:WaitForChild("ConstructionViewController"))
protect("ConstructionViewController", function() ConstructionViewController.Start() end)

--[[ ponytail: JUNCTION TOOLS OFF -- lanes, nodes (N) and signals (G). Uncomment all three
with the LaneToolsView mount above to restore.
local LaneConnectorView = require(world:WaitForChild("LaneConnectorView"))
protect("LaneConnectorView", function() LaneConnectorView.Start() end)

-- Node tool (N): junction corner radius, per-arm offset and arrival angle. Isolated so
-- a tool fault can't halt the gameplay views below it.
local okNodeTool = pcall(function() require(world:WaitForChild("NodeToolView")).Start() end)
if not okNodeTool then warn("[Bootstrap] NodeToolView failed to start") end

-- Signal controller (G): per-junction signal timing, per-arm turn treatment, and the
-- corridor groups that run a green wave across several junctions. Third pill in the
-- junction-tool stack; isolated for the same reason as the two above it.
local okSignalTool = pcall(function() require(world:WaitForChild("SignalToolView")).Start() end)
if not okSignalTool then warn("[Bootstrap] SignalToolView failed to start") end
]]

-- Street names painted along the carriageway. Isolated: a labelling fault must
-- never halt the gameplay views below it.
local okStreetNames = pcall(function() require(world:WaitForChild("StreetNameView")).Start() end)
if not okStreetNames then warn("[Bootstrap] StreetNameView failed to start") end

local NPCDriverView = require(world:WaitForChild("NPCDriverView"))
protect("NPCDriverView", function() NPCDriverView.Start() end)

-- The other players: a line from each one's camera to the ground point they are aiming at,
-- with their name on it. Inert in a solo city -- the server does not broadcast to a server
-- of one. Isolated so a view fault can't halt the gameplay controllers.
local okPresence = pcall(function() require(world:WaitForChild("PlayerPresenceView")).Start() end)
if not okPresence then warn("[Bootstrap] PlayerPresenceView failed to start") end

-- Outside connections: outward arrows + pylons at every map-edge road link (roads the
-- player dragged to the boundary). Isolated so a view fault can't halt gameplay views.
local okOC = pcall(function() require(world:WaitForChild("OutsideConnectionView")).Start() end)
if not okOC then warn("[Bootstrap] OutsideConnectionView failed to start") end

-- One-way direction arrows: a centered arrow on every one-way road, shown only while the
-- road tool is open. Right-click a road to flip it. Isolated so a view fault can't halt gameplay.
local okOW = pcall(function() require(world:WaitForChild("OneWayDirectionView")).Start() end)
if not okOW then warn("[Bootstrap] OneWayDirectionView failed to start") end

-- Custom water overlay (depth colour + foam) over the engine's terrain water.
-- DISABLED: its EditableImages consumed nearly the whole shared EditableMesh/EditableImage
-- device budget, leaving ~8 slots for the per-piece road meshes (RoadMeshView). Re-enable
-- only once the overlay fits alongside the road budget. Engine terrain water still renders.
-- local okWater = pcall(function() require(world:WaitForChild("WaterView")).Start() end)
-- if not okWater then warn("[Bootstrap] WaterView failed to start") end

-- Public transit: render route lines from SyncTransit + feed the placement tools and
-- overview panel. Buses themselves ride NPCDriverView (they carry the NPCDriver tag).
local TransitClient = require(core:WaitForChild("TransitClient"))
protect("TransitClient", function() TransitClient.Start() end)

-- Pedestrians: smooth the 12 Hz walker updates, and render the idle people standing at
-- homes/workplaces. Isolated so a view fault can't halt the gameplay controllers.
local okPed = pcall(function() require(world:WaitForChild("PedestrianView")).Start() end)
if not okPed then warn("[Bootstrap] PedestrianView failed to start") end
local okPres = pcall(function() require(world:WaitForChild("CitizenPresenceView")).Start() end)
if not okPres then warn("[Bootstrap] CitizenPresenceView failed to start") end

-- Ambient audio (roads/forest/houses/beach beds + music). Isolated: sound must
-- never halt gameplay controllers.
local okAmb = pcall(function() require(world:WaitForChild("AmbienceController")).Start() end)
if not okAmb then warn("[Bootstrap] AmbienceController failed to start") end

-- Building fires: render flame/smoke FX on any model the server tags "OnFire".
-- Isolated so a view fault can't halt the gameplay controllers.
local okFire = pcall(function() require(world:WaitForChild("FireView")).Start() end)
if not okFire then warn("[Bootstrap] FireView failed to start") end

-- Night windows: some building windows glow after dusk, each on its own random
-- schedule. Isolated so a view fault can't halt the gameplay controllers.
local okWin = pcall(function() require(world:WaitForChild("WindowLightsView")).Start() end)
if not okWin then warn("[Bootstrap] WindowLightsView failed to start") end

-- Wind turbines: spin every tagged rotor. Isolated so a view fault can't halt
-- the gameplay controllers.
local okTurbine = pcall(function() require(world:WaitForChild("WindTurbineView")).Start() end)
if not okTurbine then warn("[Bootstrap] WindTurbineView failed to start") end
-- The no-power badge over a building PowerService has marked as off the grid.
local okNoPower = pcall(function() require(world:WaitForChild("NoPowerView")).Start() end)
if not okNoPower then warn("[Bootstrap] NoPowerView failed to start") end

local okJam = pcall(function() require(world:WaitForChild("TrafficJamView")).Start() end)
if not okJam then warn("[Bootstrap] TrafficJamView failed to start") end

-- One mesh block per road piece (RoadMeshView EditableMesh merge). On bake failure the
-- piece's parts stay visible, so a budget miss degrades the look, never breaks a road.
local okRoadMesh, errRoadMesh = pcall(function()
	require(world:WaitForChild("RoadMeshView")).Start()
end)
if not okRoadMesh then warn("[Bootstrap] RoadMeshView failed to start: " .. tostring(errRoadMesh)) end

-- Distance LOD for every static city asset (buildings, nature, schools, emergency,
-- transit -- and any future _City folder), stretched by the Draw distance setting.
-- Isolated so a view fault can't halt the gameplay controllers.
--
-- Starting it here only ARMS it. The ladder itself sits idle until a city is actually loaded
-- and the player is in it (UIEvents.GameEntered .. ReturnToMainMenu), so nothing is tiered or
-- baked behind the main menu or during the server build -- see AssetLODView.setCityLoaded.
local okAssetLod, errAssetLod = pcall(function()
	require(world:WaitForChild("AssetLODView")).Start()
end)
if not okAssetLod then warn("[Bootstrap] AssetLODView failed to start: " .. tostring(errAssetLod)) end


local controllers = PlayerScripts:WaitForChild("Controllers")
local TerrainEditController = require(controllers:WaitForChild("TerrainEditController"))
protect("TerrainEditController", function()
	TerrainEditController.Init()
	TerrainEditController.Bind()
end)

-- Seasonal foliage: tints tree leaves by the in-game season (client-side, from the
-- replicated workspace.CityDay). Started after RoadMeshView so its one-time startup
-- EditableImage baking doesn't contend with the road mesh device budget. Isolated so a
-- fault here can never halt the gameplay controllers.
local okSeason = pcall(function()
	require(controllers:WaitForChild("SeasonController")).Start()
end)
if not okSeason then warn("[Bootstrap] SeasonController failed to start") end

-- Heatmap button (left edge): coverage heatmaps for city services. Isolated so a
-- view fault can't halt the gameplay controllers.
--[[ ponytail: INFO VIEWS (the eye) OFF for playtest -- every overlay reads a service
that is Init + Bind but never Start()ed, so they paint nothing real. Uncomment to restore.
local okHeat = pcall(function()
	require(controllers:WaitForChild("HeatmapController")).Start()
end)
if not okHeat then warn("[Bootstrap] HeatmapController failed to start") end
]]

-- Creation Editor (launched from the main menu's Content Hub). Isolated so a fault here
-- can never halt the gameplay controllers.
local okEditor = pcall(function()
	require(controllers:WaitForChild("EditorController")).Start()
end)
if not okEditor then warn("[Bootstrap] EditorController failed to start") end

-- Click a placed prop with no tool up and it becomes a selection: outline, action bar,
-- cut/copy/paste and groups. Isolated so a fault here can never halt the controllers above.
local okNatureSel = pcall(function()
	require(controllers:WaitForChild("NatureSelection")).Start()
end)
if not okNatureSel then warn("[Bootstrap] NatureSelection failed to start") end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")
local Net = require(ReplicatedStorage:WaitForChild("Networker"))

local CAM_REPORT_INTERVAL = 0.2
local _camReportAccum     = 0
local _lastReportedPos: Vector3? = nil
local _lastReportedYaw: number? = nil
local _lastReportedPitch: number? = nil
-- Fine thresholds: the server streams traffic by where the camera looks at the GROUND, and
-- from a high city camera a 3 degree tilt moves that point hundreds of studs -- so the server
-- was sending full-rate poses to a street off to one side of the one on screen. Still at
-- most one report per CAM_REPORT_INTERVAL.
local CAM_MOVE_THRESHOLD  = 2
local CAM_ANGLE_THRESHOLD = 0.5

local function cameraAngles(cf: CFrame): (number, number)
	local dir = cf.LookVector
	local yaw = math.deg(math.atan2(-dir.X, -dir.Z))
	local pitch = math.deg(math.asin(math.clamp(dir.Y, -1, 1)))
	return yaw, pitch
end

local function angleDelta(a: number, b: number): number
	return math.abs((a - b + 180) % 360 - 180)
end

local _heartbeatConn: RBXScriptConnection = RunService.Heartbeat:Connect(function(dt: number)
	_camReportAccum += dt

	if _camReportAccum < CAM_REPORT_INTERVAL then return end

	_camReportAccum -= CAM_REPORT_INTERVAL

	local camera = Workspace.CurrentCamera
	if not camera then return end

	local camPos = camera.CFrame.Position
	local yaw, pitch = cameraAngles(camera.CFrame)

	if _lastReportedPos and _lastReportedYaw and _lastReportedPitch then
		local moved = (camPos - _lastReportedPos).Magnitude
		local turned = angleDelta(yaw, _lastReportedYaw)
		local tilted = math.abs(pitch - _lastReportedPitch)
		if moved < CAM_MOVE_THRESHOLD and turned < CAM_ANGLE_THRESHOLD and tilted < CAM_ANGLE_THRESHOLD then
			return
		end
	end

	_lastReportedPos = camPos
	_lastReportedYaw = yaw
	_lastReportedPitch = pitch

	Net.ReportCameraPos:FireServer({ pos = camPos, yaw = yaw, pitch = pitch })
end)

Players.PlayerRemoving:Connect(function(player)
	if player == Players.LocalPlayer then
		_heartbeatConn:Disconnect()
	end
end)