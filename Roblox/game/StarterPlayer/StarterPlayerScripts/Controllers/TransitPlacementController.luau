--!strict
-- TransitPlacementController
-- The Transit build tools: Depot (free placement), Bus Stop (snaps to the kerb on
-- either side, faces the road) and Route (drop stops, connect them, add waypoints). While
-- the Transit section is open every road tints BLUE -- the route-mode affordance. Depot
-- placement reuses RequestPlaceService(kind="Transit"); stops + routes go through
-- RequestTransitCommand. Reads the live snapshot from TransitClient.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local Net = require(ReplicatedStorage:WaitForChild("Networker"))
local TransitTypes = require(ReplicatedStorage.Transit.TransitTypes)
local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local Snapper = require(script.Parent:WaitForChild("RoadPlacementSnapper"))
local PlacementCostHud = require(script.Parent.Parent:WaitForChild("HUD"):WaitForChild("PlacementCostHud"))
local TransitClient = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("TransitClient"))
local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))
local CursorRay = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("CursorRay"))
local GhostPlacement = require(script.Parent:WaitForChild("GhostPlacement"))
local UiScratch = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("UiScratch"))

local TransitPlacementController = {}

-- Valid/invalid ghost tinting lives in GhostPlacement now; the Stop ghost is tinted with
-- its own accent colour, not green/red.
local STOP_MAX_ROAD_DIST = 40

local _enabled = false
local _inited = false
local _bound = false
local _tool = "Depot" -- "Depot" | "Stop" | "Station" | "Route"
local _ghost: Model? = nil
local _ghostFolder: Folder? = nil
local _renderConn: RBXScriptConnection? = nil
local _inputConn: RBXScriptConnection? = nil
local _unsub: (() -> ())? = nil
-- stop tool: { pos = cursor hit, road = centreline point, seg = segmentId }
local _stopSend: any = nil
-- route tool
local _pendingFirstStop: number? = nil
local _maxKnownRouteId = 0

-- Cursor picking lives in Core.CursorRay; the Depot tool's whole ghost/fit/cost/place loop
-- is Controllers.GhostPlacement (see _depotPlacer below). Only the Stop and Route tools,
-- which snap to road geometry rather than free ground, are hand-written here.

local function ensureGhostFolder(): Folder
	local folder = UiScratch.folder("TransitPlacement")
	_ghostFolder = folder
	return folder
end

local function destroyGhost()
	if _ghost then _ghost:Destroy(); _ghost = nil end
end

local function tintGhost(color: Color3)
	if not _ghost then return end
	for _, d in _ghost:GetDescendants() do
		if d:IsA("BasePart") then d.Color = color end
	end
end

local function part(parent: Instance, size: Vector3, cf: CFrame, color: Color3): Part
	local p = Instance.new("Part")
	p.Size = size; p.CFrame = cf; p.Color = color; p.Material = Enum.Material.SmoothPlastic
	p.Anchored = true; p.CanCollide = false; p.CanTouch = false; p.CanQuery = false; p.Transparency = 0.35
	p.Parent = parent
	return p
end

-- The Depot tool IS the shared free-placement tool: one model, on the ground, where the
-- cursor is. It supplies a spec and nothing else.
local _depotPlacer = GhostPlacement.new({
	folderName = "TransitPlacement",
	build = function(key: string): Model?
		local spec = TransitTypes.getDepot(key)
		if not spec then return nil end
		local fp = TransitTypes.depotFootprintStuds(spec)
		local m = Instance.new("Model"); m.Name = "GhostDepot"
		local base = part(m, Vector3.new(fp.X, spec.height, fp.Z), CFrame.new(0, spec.height * 0.5, 0), spec.wall)
		part(m, Vector3.new(fp.X + 1, 1, fp.Z + 1), CFrame.new(0, spec.height + 0.5, 0), spec.roof)
		m.PrimaryPart = base
		if RoadConstants.WORLD_SCALE ~= 1 then m:ScaleTo(RoadConstants.WORLD_SCALE) end
		return m
	end,
	footprint = function(key: string): Vector3?
		local spec = TransitTypes.getDepot(key)
		if not spec then return nil end
		local fp = TransitTypes.depotFootprintStuds(spec)
		-- Y is the overlap box's height, which for a depot is the wall height, not fp.Y.
		return Vector3.new(fp.X, spec.height, fp.Z)
	end,
	cost = function(key: string): number?
		local spec = TransitTypes.getDepot(key)
		return if spec then spec.cost else nil
	end,
	place = function(_key: string, pivot: CFrame)
		Net.RequestPlaceService:FireServer("Transit", "BusDepot", pivot)
	end,
})
_depotPlacer:setKey("BusDepot")

-- "Stop" places a BusStop on a road; "Station" places a TrainStation on rail.
local function stopKeyForTool(): string
	return if _tool == "Station" then "TrainStation" else "BusStop"
end

local function buildStopGhost(): Model
	local spec = TransitTypes.getStop(stopKeyForTool()) :: TransitTypes.StopSpec
	local m = Instance.new("Model"); m.Name = "GhostStop"
	local pole = part(m, Vector3.new(0.5, spec.poleHeight, 0.5), CFrame.new(0, spec.poleHeight * 0.5, 0), Color3.fromRGB(60, 64, 70))
	part(m, Vector3.new(2.6, 1.4, 0.2), CFrame.new(0, spec.poleHeight - 0.6, 0.15), spec.accent)
	local sh = spec.shelterSize
	part(m, Vector3.new(sh.X, 0.3, sh.Z), CFrame.new(0, sh.Y, -sh.Z * 0.5 - 0.4), Color3.fromRGB(120, 170, 190))
	m.PrimaryPart = pole
	if RoadConstants.WORLD_SCALE ~= 1 then m:ScaleTo(RoadConstants.WORLD_SCALE) end
	m.Parent = ensureGhostFolder()
	return m
end

-- == Cursor raycast ===========================================================
-- The ghost folder lives under _UI, which CursorRay already excludes for every tool.
local function mouseRay(): (Vector3?, Instance?)
	local hit = CursorRay.groundHit({ ignoreWater = true })
	if hit then return hit.Position, hit.Instance end
	return nil, nil
end

local function stopIdFromInstance(inst: Instance?): number?
	local node = inst
	while node and node ~= Workspace do
		if node:GetAttribute("StopId") ~= nil then return node:GetAttribute("StopId") :: number end
		node = node.Parent
	end
	return nil
end

local function flatDist(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function stopIdAt(hit: Vector3?, inst: Instance?): number?
	local direct = stopIdFromInstance(inst)
	if direct then return direct end
	-- Already a screen-pixel radius, so it needs the cursor in viewport space.
	local screenStop = TransitClient.stopIdAtScreen(CursorRay.position(), 76)
	if screenStop then return screenStop end
	if hit then
		return TransitClient.nearestStopId(hit, 18)
	end
	return nil
end

local function roadPointAt(hit: Vector3?): Vector3?
	if not hit then return nil end
	local roadPoint = Snapper.nearestRoadPoint(hit)
	if roadPoint and flatDist(roadPoint, hit) <= STOP_MAX_ROAD_DIST then
		return roadPoint
	end
	return nil
end

local function stopName(stopId: number?): string
	if not stopId then return "Stop" end
	for _, stop in TransitClient.getSnapshot().stops do
		if stop.id == stopId then return tostring(stop.name or "Stop") end
	end
	return "Stop"
end

local function routeStopCount(route: any): number
	return if route and typeof(route.stops) == "table" then #route.stops else 0
end

local function updateRouteStatus(hoverStopId: number?)
	local route = TransitClient.getActiveRouteData()
	if not route then
		TransitClient.setRouteStatus("Create Route", "Click a stop or station marker to choose the first stop.")
		return
	end
	local count = routeStopCount(route)
	local firstStopId = route.stops and route.stops[1]
	if route.closed then
		TransitClient.setRouteStatus("Route closed", "Press Esc to finish, or press U to reopen the last loop.", "attention")
	elseif count <= 1 then
		TransitClient.setRouteStatus("Creating route", "Start: " .. stopName(firstStopId) .. ". Click another stop to extend it.")
	elseif hoverStopId and hoverStopId == firstStopId then
		TransitClient.setRouteStatus("Close route", "Click the first stop again to complete the loop.", "attention")
	else
		TransitClient.setRouteStatus("Creating route", tostring(count) .. " stops selected. Click more stops, or click the first stop to close.")
	end
end

-- == Stop recompute (curbside preview) ========================================
local function recomputeStop()
	_stopSend = nil
	if not _ghost then _ghost = buildStopGhost() end
	local ghost = _ghost
	local hit = mouseRay()
	if not hit then if ghost then ghost.Parent = nil end return end
	local center = Snapper.nearestRoadPoint(hit)
	local segId = Snapper.nearestSegmentId(hit)
	if not center or (Vector3.new(center.X, 0, center.Z) - Vector3.new(hit.X, 0, hit.Z)).Magnitude > STOP_MAX_ROAD_DIST then
		if ghost then ghost.Parent = nil end
		return
	end
	if not ghost.Parent then ghost.Parent = ensureGhostFolder() end
	-- The side is whichever side of the centreline the cursor is on; sit the stop just
	-- off the carriageway (on the sidewalk) facing the road.
	local stopSpec = TransitTypes.getStop(stopKeyForTool()) :: TransitTypes.StopSpec
	local wantRail = stopSpec.mode == "train"
	local roadWidth = 16
	local segInfo = if segId then Snapper.getSegmentInfo(segId) else nil
	if segInfo and typeof(segInfo.roadType) == "string" then
		local segSpec = RoadTypeCatalog.getOrDefault(segInfo.roadType)
		-- Stations snap only to track; bus stops only to roads.
		if (segSpec.isRail == true) ~= wantRail then
			if ghost then ghost.Parent = nil end
			return
		end
		roadWidth = segSpec.width
	end
	local outward = Vector3.new(hit.X - center.X, 0, hit.Z - center.Z)
	if outward.Magnitude < 0.5 then outward = Vector3.new(0, 0, 1) end
	-- Push the pivot (Pole centre) out to the sidewalk edge.
	local flatPos = center + outward.Unit * (roadWidth * 0.5 + stopSpec.curbOffset * RoadConstants.WORLD_SCALE)
	-- Y: the Pole is 12 studs tall; PivotTo places its centre, so lift by half (6 studs)
	-- so the pole base sits flush with the ground (road/sidewalk level = center.Y).
	local poleHalfH = stopSpec.poleHeight * 0.5 * RoadConstants.WORLD_SCALE
	local ghostPos = Vector3.new(flatPos.X, center.Y + poleHalfH, flatPos.Z)
	-- The shelter's open/sign side must face the road.
	-- CFrame.lookAt(pos, target) makes +Z point at target (the road centre).
	-- The template sign is on the +Z side, BackGlass on -Z, so the un-rotated
	-- orientation already has the sign facing the road; we rotate 180 degrees around Y
	-- to flip the shelter so its open/sign side faces the road instead of away from it.
	local baseCF = CFrame.lookAt(ghostPos, Vector3.new(center.X, ghostPos.Y, center.Z))
	ghost:PivotTo(baseCF * CFrame.Angles(0, math.pi, 0))
	tintGhost(stopSpec.accent)
	_stopSend = { pos = hit, road = center, seg = segId, key = stopSpec.key }
end

local function onRender()
	if not _enabled then return end
	if _tool == "Depot" then
		_depotPlacer:update()
	elseif _tool == "Stop" or _tool == "Station" then
		recomputeStop()
		PlacementCostHud.showCost(TransitTypes.getStop(stopKeyForTool()).cost)
	else -- Route
		PlacementCostHud.hide()
		local hit, inst = mouseRay()
		local active = TransitClient.getActiveRoute()
		local activeRoute = TransitClient.getActiveRouteData()
		local stopId = stopIdAt(hit, inst)
		updateRouteStatus(stopId)
		if stopId then
			local actionText = if active then "Add Stop" else "Create Route"
			local secondaryText = if active then "Undo" else nil
			if activeRoute and not activeRoute.closed and routeStopCount(activeRoute) >= 2 and activeRoute.stops[1] == stopId then
				actionText = "Close Route"
			end
			TransitClient.setRouteHint(stopId, nil, nil, actionText, secondaryText)
		elseif active and not (activeRoute and activeRoute.closed) then
			local roadPoint = roadPointAt(hit)
			if roadPoint then
				TransitClient.setRouteHint(nil, roadPoint, "Road waypoint", "Add Waypoint", "Undo")
			else
				TransitClient.setRouteHint(nil, nil, nil, nil, nil)
			end
		else
			TransitClient.setRouteHint(nil, nil, nil, nil, nil)
		end
	end
end

local function clearToolState()
	destroyGhost()
	-- The Depot ghost is the placer's, not _ghost: it owns its own lifecycle, so switching
	-- away from Depot has to stand it down or it keeps riding the cursor under the next tool.
	_depotPlacer:setEnabled(false)
	_stopSend = nil
	PlacementCostHud.hide()
	TransitClient.setRouteHint(nil, nil, nil, nil, nil)
	TransitClient.setRouteStatus(nil, nil, nil)
end

-- == Tool / enable ============================================================
function TransitPlacementController.setTool(tool: string)
	if tool ~= "Depot" and tool ~= "Stop" and tool ~= "Station" and tool ~= "Route" then return end
	if tool == _tool then return end
	_tool = tool
	clearToolState()
	_depotPlacer:setEnabled(_enabled and tool == "Depot")
	if tool ~= "Route" then TransitClient.setActiveRoute(nil); TransitClient.setRouteHint(nil, nil, nil, nil, nil); _pendingFirstStop = nil end
end

function TransitPlacementController.getTool(): string
	return _tool
end

function TransitPlacementController.setEnabled(enabled: boolean)
	if enabled == _enabled then return end
	_enabled = enabled
	_depotPlacer:setEnabled(enabled and _tool == "Depot")
	if enabled then
		TransitClient.setMode("tools", true)
	else
		clearToolState()
		TransitClient.setMode("tools", false)
		TransitClient.setActiveRoute(nil)
		_pendingFirstStop = nil
	end
end

function TransitPlacementController.isEnabled(): boolean
	return _enabled
end

-- == Route building ===========================================================
local function selectRouteStop(stopId: number)
	local active = TransitClient.getActiveRoute()
	local route = TransitClient.getActiveRouteData()
	if active then
		local firstStopId = route and route.stops and route.stops[1]
		if route and not route.closed and routeStopCount(route) >= 2 and stopId == firstStopId then
			TransitClient.setRouteStatus("Closing route", "Completing the loop back to " .. stopName(stopId) .. ".", "attention")
		elseif route and route.closed then
			TransitClient.setRouteStatus("Editing line", "Reopened to add " .. stopName(stopId) .. " -- click the first stop to close it again.", "attention")
		else
			TransitClient.setRouteStatus("Stop selected", "Added " .. stopName(stopId) .. " to the route.")
		end
		Net.RequestTransitCommand:FireServer("addStop", { routeId = active, stopId = stopId })
	else
		_pendingFirstStop = stopId
		TransitClient.setRouteStatus("Starting route", "Selected " .. stopName(stopId) .. ". Click the next stop.")
		Net.RequestTransitCommand:FireServer("createRoute", { stopId = stopId })
	end
end

local function onRouteClick()
	local hit, inst = mouseRay()
	if not hit then return end
	local stopId = stopIdAt(hit, inst)
	if stopId then
		selectRouteStop(stopId)
	else
		-- clicked the road, not a stop: shape the current leg with a waypoint
		local active = TransitClient.getActiveRoute()
		local route = TransitClient.getActiveRouteData()
		local roadPoint = roadPointAt(hit)
		if active and roadPoint and not (route and route.closed) then
			Net.RequestTransitCommand:FireServer("addWaypoint", { routeId = active, pos = roadPoint })
		end
	end
end

-- Adopt the freshly-created route as active once it arrives in the snapshot.
local function onSnapshot(snap: any)
	for _, route in snap.routes do
		if route.id > _maxKnownRouteId then _maxKnownRouteId = route.id end
	end
	if _pendingFirstStop then
		local want = _pendingFirstStop
		local found: number? = nil
		for _, route in snap.routes do
			if route.stops and route.stops[1] == want then
				if not found or route.id > found then found = route.id end
			end
		end
		if found then
			_pendingFirstStop = nil
			TransitClient.setActiveRoute(found)
		end
	end
end

-- == Lifecycle ================================================================
function TransitPlacementController.Init()
	if _inited then return end
	_inited = true
	ensureGhostFolder()
end

function TransitPlacementController.Bind()
	if _bound then return end
	_bound = true
	_renderConn = RunService.RenderStepped:Connect(onRender)
	_unsub = TransitClient.onChanged(onSnapshot)
	TransitClient.setStopClickHandler(function(stopId: number)
		if _enabled and _tool == "Route" then
			selectRouteStop(stopId)
		end
	end)
	_inputConn = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if not _enabled or gameProcessed then return end
		if Settings.pressed("Back", input) then
			if _tool == "Route" and TransitClient.getActiveRoute() then
				TransitClient.setActiveRoute(nil); _pendingFirstStop = nil
			else
				TransitPlacementController.setEnabled(false)
			end
			return
		end
		if _tool == "Depot" and Settings.pressed("RotateObject", input) then
			_depotPlacer:rotate(45)
			return
		end
		if _tool == "Route" and (Settings.pressed("RemoveLastStop", input) or Settings.pressed("RemoveLastPoint", input)) then
			local active = TransitClient.getActiveRoute()
			if active then Net.RequestTransitCommand:FireServer("undo", { routeId = active }) end
			return
		end
		-- Right-click a stop while a line is selected removes that stop from the line.
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			if _tool == "Route" then
				local active = TransitClient.getActiveRoute()
				if active then
					local hit, inst = mouseRay()
					local stopId = stopIdAt(hit, inst)
					if stopId then
						Net.RequestTransitCommand:FireServer("removeRouteStop", { routeId = active, stopId = stopId })
						TransitClient.setRouteStatus("Stop removed", "Removed " .. stopName(stopId) .. " from the line.", "attention")
					end
				end
			end
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		if _tool == "Depot" then
			_depotPlacer:tryPlace()
		elseif _tool == "Stop" or _tool == "Station" then
			if _stopSend then Net.RequestTransitCommand:FireServer("placeStop", _stopSend) end
		else
			onRouteClick()
		end
	end)
end

function TransitPlacementController.Start() end

function TransitPlacementController.Cleanup()
	if _renderConn then _renderConn:Disconnect(); _renderConn = nil end
	if _inputConn then _inputConn:Disconnect(); _inputConn = nil end
	if _unsub then _unsub(); _unsub = nil end
	TransitClient.setStopClickHandler(nil)
	_depotPlacer:destroy()
	clearToolState()
	TransitClient.setMode("tools", false)
	_enabled = false; _bound = false; _inited = false
end

return TransitPlacementController
