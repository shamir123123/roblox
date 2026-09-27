--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local RoadConstants   = require(ReplicatedStorage.Road.RoadConstants)
local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)
local TerrainConstants = require(ReplicatedStorage.Terrain.TerrainConstants)
local WaterField      = require(ReplicatedStorage.Terrain.WaterField)
local RoadVerticalProfile = require(ReplicatedStorage.Road.RoadVerticalProfile)
local BezierUtil       = require(ReplicatedStorage.Road.BezierUtil)
local RoadCrossSection = require(ReplicatedStorage.Terrain.RoadCrossSection)
local SnapUtil        = require(ReplicatedStorage.Road.SnapUtil)
local PlacementGrid   = require(ReplicatedStorage.Shared.PlacementGrid)
local Snapper         = require(script.Parent.RoadPlacementSnapper)
local GhostPreview    = require(script.Parent.RoadGhostPreviewController)
local DeleteHover     = require(script.Parent:WaitForChild("DeleteHoverController"))
local NotificationController = require(script.Parent.Parent:WaitForChild("HUD"):WaitForChild("NotificationController"))
local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))
local CursorRay = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("CursorRay"))

local RoadPlacementController = {}

export type Phase = "Disabled" | "Idle" | "HasStart" | "HasCurve" | "HasCurve2"
export type Mode  = "Straight" | "Curved" | "Freeform" | "AdvancedCurve" | "Roundabout"
export type EditMode = "None" | "UpgradeReplace" | "Delete"
-- Vertical placement mode (orthogonal to the horizontal draw Mode above). Constant
-- slope is a boolean toggle, never a mode of its own.
export type VerticalMode = "Ground" | "Elevated" | "Tunnel"

local _phase: Phase = "Disabled"
local _mode: Mode   = "Straight"
local _start: Vector3? = nil
local _curve: Vector3? = nil
local _curve2: Vector3? = nil

local _freeformTangent: Vector3? = nil

local _ghostFolder: Folder
local _placeRemote: RemoteEvent
local _placeResultRemote: RemoteEvent
local _syncRemote: RemoteEvent
local _syncSegRemote: RemoteEvent
local _syncNodeDeltaRemote: RemoteEvent
local _syncSegDeltaRemote: RemoteEvent
local _replaceSegRemote: RemoteEvent
local _removeSegRemote: RemoteEvent
local _undoRemote: RemoteEvent
local _redoRemote: RemoteEvent
local _placeRoundaboutRemote: RemoteEvent
local _roundaboutPresetRemote: RemoteEvent
local _renderConn: RBXScriptConnection? = nil
local _inputConn: RBXScriptConnection? = nil

local _remoteConns: { RBXScriptConnection } = {}
local _inited = false
local _bound = false
local _listener: ((phase: Phase, mode: Mode, tangentSnapEnabled: boolean, roadType: string, elevation: number) -> ())? = nil

local _roadType: string = RoadTypeCatalog.DEFAULT_ID
local _roadSnapEnabled:        boolean = true
local _guideEnabled:           boolean = true
local _angleSnapEnabled:       boolean = true
local _intersectionSnapEnabled:boolean = true
local _roadTypeSelected:       boolean = false
local _editMode: EditMode = "None"
local _verticalMode: VerticalMode = "Ground"
-- AUTO: let the terrain choose. Deliberately a separate flag rather than a fourth
-- VerticalMode, because _verticalMode is DERIVED from _verticalOffset (see setElevation) and
-- an "Auto" that the offset could overwrite would be a mode that silently turns itself off.
-- This only fills in the case the offset leaves open -- see resolveVMode.
local _autoVertical = false
local _constantSlope: boolean = false
-- Signed: 0 = on the ground, >0 = elevated deck, <0 = tunnel below grade.
local _verticalOffset: number = RoadConstants.MIN_ELEVATION
local _parallelMode: boolean = false
local _parallelGap: number = 0.25 -- studs: gap between the two roads' sidewalk edges (min 0.25)
local _intersectionStampMode: boolean = false

-- Center-to-center displacement for the parallel twin. The two same-type footprints
-- (carriageway + sidewalk) meet at gap 0 -- that touch distance is the per-road-type
-- minimum -- and the user's sidewalk-edge gap (>= 0.25) is added on top so they never
-- overlap.
local function parallelDisplacement(): number
	local spec = RoadTypeCatalog.getOrDefault(_roadType)
	local footSum = spec.width + 2 * (if spec.noSidewalk then 0 else RoadConstants.SIDEWALK_WIDTH)
	-- Displayed gap is an abstract 0.25-step scale: the shown "0.25" = 4 studs of real
	-- centre space, so studs = displayed * 16.
	return footSum + math.max(0.25, _parallelGap) * 16
end

local _lastSnapResult: any = nil
local _pendingPlacement: any = nil
-- A fired placement (road or roundabout) waits on PlaceRoadResult to clear the guard
-- above. If that reply never arrives (server errored mid-handler, or the packet was
-- dropped) the guard would wedge the whole road tool. _pendingSince + the watchdog in
-- updateGhost reset it after a generous timeout so the tool self-heals.
local _pendingSince: number? = nil
local PLACEMENT_RESULT_TIMEOUT = 5

-- Current gesture state packaged for RoadPlacementSnapper.controlPoints.
local function curveOpts(): Snapper.CurveOpts
	return {
		mode = _mode,
		phase = _phase,
		start = _start,
		curve = _curve,
		curve2 = _curve2,
		freeformTangent = _freeformTangent,
		angleSnapEnabled = _angleSnapEnabled,
		lastSnapType = if _lastSnapResult then _lastSnapResult.snapType else nil,
	}
end

local function notify()
	if _listener then
		_listener(_phase, _mode, false, _roadType, _verticalOffset)
	end
end

function RoadPlacementController.setStateListener(fn: (phase: Phase, mode: Mode, tangentSnapEnabled: boolean, roadType: string, elevation: number) -> ())
	_listener = fn
	notify()
end

function RoadPlacementController.getPhase(): Phase return _phase end
function RoadPlacementController.getMode(): Mode  return _mode  end
function RoadPlacementController.getRoadType(): string return _roadType end
function RoadPlacementController.isRoadTypeSelected(): boolean return _roadTypeSelected end

function RoadPlacementController.setRoadType(id: string)
	if RoadTypeCatalog.get(id) then
		_roadType = id
		_roadTypeSelected = true
		SnapUtil.setActiveRoadType(id)
		notify()
	end
end

function RoadPlacementController.clearRoadTypeSelection()
	-- Neutral road mode: nothing to place. Drop any in-progress draw so a left-click does
	-- nothing (right-click still flips a one-way road).
	_roadTypeSelected = false
	_start = nil
	_curve = nil
	_curve2 = nil
	_freeformTangent = nil
	if _phase ~= "Disabled" then _phase = "Idle" end
	GhostPreview.clear()
	notify()
end


-- What the ROAD ground-pick skips on top of the shared exclusions (character + _UI, which
-- Core.CursorRay handles for every tool). Rebuilt per call; the folders are looked up live
-- so a recreated folder can never leave a dead instance in the filter.
--   Roads: a road must never snap onto another road's surface.
--   ZonedBuildings: building bodies are CanQuery=true so the info panel and delete tool can
--     pick them, but a road drawn across one would otherwise climb onto the roof.
-- Zone tiles are client-rendered under _UI, so they are already covered.
local _roadIgnore: { Instance } = {}
local function roadIgnore(): { Instance }
	table.clear(_roadIgnore)
	if _ghostFolder then table.insert(_roadIgnore, _ghostFolder) end
	local cityRoot = Workspace:FindFirstChild("_City")
	if cityRoot then
		local roadsFolder = cityRoot:FindFirstChild("Roads")
		if roadsFolder then table.insert(_roadIgnore, roadsFolder) end
		local buildingsFolder = cityRoot:FindFirstChild("ZonedBuildings")
		if buildingsFolder then table.insert(_roadIgnore, buildingsFolder) end
	end
	return _roadIgnore
end

local MAP_HALF = RoadConstants.MAP_HALF_EXTENT
-- Open water reads as ground at shoreline height for road drawing (matches the
-- server's ground-road water clamp): the ghost bridges water instead of diving
-- down the seabed. Player-drained dry pits still count as ground.
local WATERLINE_Y = TerrainConstants.SEA_Y + TerrainConstants.RENDER_BULGE
local function clampWater(x: number, z: number, y: number): number
	if y < WATERLINE_Y and not WaterField.isDryAt(x, z) then
		return WATERLINE_Y
	end
	return y
end
-- Terrain surface Y at a point (ray straight down, ignoring roads / ghost / buildings).
local function groundSurfaceYAt(x: number, z: number): number
	local y = CursorRay.surfaceYAt(x, z, roadIgnore())
	return clampWater(x, z, y or RoadConstants.getGroundY())
end
-- What this span should actually be BUILT as: Ground, Elevated or Tunnel.
--
-- An explicit elevation is the player saying what they want, so it always wins -- Auto only
-- decides when they have not said. That keeps setElevation's invariant intact (offset is the
-- single source of truth for _verticalMode) instead of competing with it.
--
-- The decision itself is RoadCrossSection.verticalModeFor, shared with the server and specced
-- there: a road standing well above the ground gets held up, ground standing well above the
-- road gets bored through, everything else sits down. Which is how Cities: Skylines does it --
-- there is no separate bridge tool, only a road and the land it crosses.
--
-- ponytail: 13 samples per span. Enough to catch a hill a segment crosses without walking the
-- curve at grading resolution; raise it if a narrow ridge is ever missed.
local AUTO_ALLOW = { elevated = true, tunnel = true }
local function resolveVMode(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3): VerticalMode
	if not _autoVertical or _verticalOffset ~= 0 then return _verticalMode end
	local pts = table.create(13)
	for i = 0, 12 do
		pts[i + 1] = BezierUtil.point(p0, p1, p2, p3, i / 12)
	end
	return RoadCrossSection.verticalModeFor(pts, groundSurfaceYAt, AUTO_ALLOW) :: VerticalMode
end
-- Keep placement on the map: clamp the ground pick's X/Z to the boundary so neither the
-- preview reticle nor a placed endpoint can run off the edge into the void. When the pick
-- was off-map, reseat Y onto the ground at the clamped edge so the road sits ON the
-- boundary instead of diving below the terrain (which read as a steep, invalid grade).
local function clampToMap(p: Vector3): Vector3
	local cx = math.clamp(p.X, -MAP_HALF, MAP_HALF)
	local cz = math.clamp(p.Z, -MAP_HALF, MAP_HALF)
	if cx == p.X and cz == p.Z then return p end
	return Vector3.new(cx, groundSurfaceYAt(cx, cz), cz)
end

-- Magnetic edge snap: an endpoint hugging a boundary is pulled EXACTLY onto it, so a road
-- run to the edge meets the void with no leftover terrain gap (it becomes an outside
-- connection). Applied after SnapUtil so it wins over length / angle / grid snapping,
-- which otherwise leave the road a few studs short of the edge.
local EDGE_SNAP_DIST = 48
local function snapToMapEdge(p: Vector3): Vector3
	local x, z = p.X, p.Z
	if MAP_HALF - math.abs(x) <= EDGE_SNAP_DIST then
		x = if x >= 0 then MAP_HALF else -MAP_HALF
	end
	if MAP_HALF - math.abs(z) <= EDGE_SNAP_DIST then
		z = if z >= 0 then MAP_HALF else -MAP_HALF
	end
	if x == p.X and z == p.Z then return p end
	return Vector3.new(x, groundSurfaceYAt(x, z), z)
end

local function cursorWorldPoint(): Vector3?
	local ray = CursorRay.ray()
	if not ray then return nil end

	local hit = CursorRay.groundHit({ ignore = roadIgnore() })
	if hit then
		local p = hit.Position
		return clampToMap(Vector3.new(p.X, clampWater(p.X, p.Z, p.Y), p.Z))
	end

	if math.abs(ray.Direction.Y) < 1e-5 then return nil end

	local surfaceY = RoadConstants.getGroundY()

	local t = (surfaceY - ray.Origin.Y) / ray.Direction.Y
	if t < 0 then return nil end
	local p = ray.Origin + ray.Direction * t
	return clampToMap(Vector3.new(p.X, surfaceY, p.Z))
end

-- Cursor ground speed, smoothed, for the guideline system: guides are for placing, not
-- for panning, so they hide while the cursor is being thrown across the map and come back
-- when it settles. A single frame's delta is far too jumpy to gate on.
local _lastCursorPos: Vector3? = nil
local _lastCursorAt = 0
local _cursorSpeed = 0
local function trackCursorSpeed(raw: Vector3)
	local now = os.clock()
	local dt = now - _lastCursorAt
	_lastCursorAt = now
	local prev = _lastCursorPos
	_lastCursorPos = raw
	-- No previous sample, or a gap long enough that the tool was not even running.
	if not prev or dt <= 1e-3 or dt > 0.5 then return end
	local p = prev :: Vector3
	local dx, dz = raw.X - p.X, raw.Z - p.Z
	-- Heavily smoothed (0.12, was 0.35). Zoomed out, a small mouse flick is thousands of
	-- studs/second of world travel, and a twitchy speed reading makes everything that fades
	-- on it strobe.
	_cursorSpeed += (math.sqrt(dx * dx + dz * dz) / dt - _cursorSpeed) * 0.12
	SnapUtil.setCursorSpeed(_cursorSpeed)
end

-- Road-access sides of the buildings near the cursor, handed to SnapUtil so a road can
-- snap to a building's frontage -- the mirror of a building snapping to a road. A model's
-- pivot LookVector IS its access side's outward normal (GhostPlacement points it at the
-- road when it snaps), so nothing extra has to be stored on the building.
-- Throttled and reach-limited: this walks folders, and it only has to be right to within
-- a frame or two.
local BUILDING_FOLDERS = { "Schools", "EmergencyServices", "Transit", "ZonedBuildings" }
local FRONT_REFRESH_INTERVAL = 0.4
local FRONT_MAX = 24
local _frontsRefreshedAt = 0
local function refreshBuildingFronts(cursor: Vector3)
	local now = os.clock()
	if now - _frontsRefreshedAt < FRONT_REFRESH_INTERVAL then return end
	_frontsRefreshedAt = now
	local city = Workspace:FindFirstChild("_City")
	if not city then return end
	local reach = SnapUtil.Constants.GUIDE_SOURCE_RADIUS
	local out: { any } = {}
	for _, folderName in BUILDING_FOLDERS do
		local folder = city:FindFirstChild(folderName)
		if not folder then continue end
		for _, m in folder:GetChildren() do
			if #out >= FRONT_MAX then break end
			if not m:IsA("Model") then continue end
			local pivot = m:GetPivot()
			local dx, dz = pivot.X - cursor.X, pivot.Z - cursor.Z
			if dx * dx + dz * dz > reach * reach then continue end
			local look = pivot.LookVector
			local flat = Vector3.new(look.X, 0, look.Z)
			if flat.Magnitude < 1e-3 then continue end
			local _, size = m:GetBoundingBox()
			out[#out + 1] = {
				pos = pivot.Position,
				dir = flat.Unit,
				halfDepth = size.Z * 0.5,
				halfWidth = size.X * 0.5,
			}
		end
	end
	SnapUtil.setBuildingFronts(out)
end

local function elevatedPlacementPoint(raw: Vector3): Vector3
	return Vector3.new(raw.X, raw.Y + _verticalOffset, raw.Z)
end

local function roadSurfaceYAt(x: number, z: number): number?
	return groundSurfaceYAt(x, z) + RoadConstants.GROUND_ROAD_TOP_LIFT - RoadConstants.ROAD_THICKNESS * 0.5
end

local function applyVerticalProfile(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3): (Vector3, Vector3)
	if _constantSlope then
		return RoadVerticalProfile.conditionLinear(p0, p1, p2, p3)
	end
	-- A deliberately raised or sunken road ramps STRAIGHT from node to node. It used to take
	-- the smoothstep, which lands flat at both ends and bulges in between -- so a road placed
	-- at a set depth did not hold that depth along its length, which is not what asking for a
	-- depth means. conditionLinear is the same profile Constant Slope already uses.
	--
	-- ponytail: this costs the smoothstep's level landing at junctions, which existed to keep
	-- intersections near-planar. A sunken road meeting a junction now arrives on its grade
	-- rather than flattening into it. Worth revisiting IF junctions start to look kinked --
	-- the fix would be to keep the smoothstep only when an endpoint is welded to an existing
	-- road, which is the only case that landing protects.
	if _verticalMode == "Elevated" or _verticalMode == "Tunnel" then
		return RoadVerticalProfile.conditionLinear(p0, p1, p2, p3)
	end
	return RoadVerticalProfile.conditionToSurface(p0, p1, p2, p3, roadSurfaceYAt)
end

-- Drop-in roundabout: the centre snaps onto the nearest road so the ring sits ON
-- the road (the server cuts the road at the ring and reconnects the arms). A single
-- click drops a ring at the selected size preset -- no centre-then-drag. Green ghost
-- = snapped to a road; neutral = would land on open ground.
export type RoundaboutSize = "Small" | "Medium" | "Large"
local _roundaboutSize: RoundaboutSize = "Medium"

local function roundaboutRadius(): number
	return if _roundaboutSize == "Small" then RoadConstants.ROUNDABOUT_RADIUS_SMALL
		elseif _roundaboutSize == "Large" then RoadConstants.ROUNDABOUT_RADIUS_LARGE
		else RoadConstants.ROUNDABOUT_RADIUS_MEDIUM
end

-- Ring carriageway per size preset: lane count scales with the circle (CS2-style).
local function roundaboutRoadType(): string
	return if _roundaboutSize == "Small" then "Roundabout1"
		elseif _roundaboutSize == "Large" then "Roundabout3"
		else "Roundabout"
end

function RoadPlacementController.getRoundaboutSize(): RoundaboutSize
	return _roundaboutSize
end

function RoadPlacementController.cycleRoundaboutSize()
	_roundaboutSize = if _roundaboutSize == "Small" then "Medium"
		elseif _roundaboutSize == "Medium" then "Large"
		else "Small"
end

-- What goes in the middle (RoadConstants.ROUNDABOUT_CENTRE_PRESETS). New roundabouts get it,
-- and clicking an existing one with the tool gives it that centre instead of dropping a ring.
local _roundaboutPreset: string = "Empty"

function RoadPlacementController.getRoundaboutPreset(): string
	return _roundaboutPreset
end

function RoadPlacementController.cycleRoundaboutPreset()
	local list = RoadConstants.ROUNDABOUT_CENTRE_PRESETS
	local i = table.find(list, _roundaboutPreset) or 0
	_roundaboutPreset = list[(i % #list) + 1]
end

-- The existing roundabout whose ring encloses this point, if any.
local function roundaboutUnder(p: Vector3): Vector3?
	for _, s in Snapper.getSegments() do
		local c, r = s.roundaboutCenter, s.roundaboutRadius
		if s.isRoundabout and c and r and Vector3.new(p.X - c.X, 0, p.Z - c.Z).Magnitude < r then
			return c
		end
	end
	return nil
end

local function roundaboutCenter(): (Vector3?, boolean)
	local raw = cursorWorldPoint()
	if not raw then return nil, false end
	local snapped = Snapper.nearestRoadPoint(raw)
	return elevatedPlacementPoint(snapped or raw), snapped ~= nil
end

local function updateRoundaboutGhost()
	GhostPreview.clearCurveVisuals()
	GhostPreview.hideIndicator()
	local center, onRoad = roundaboutCenter()
	if not center then
		GhostPreview.hideRoundabout()
		return
	end
	GhostPreview.showRoundabout(center, roundaboutRadius(), onRoad, roundaboutRoadType())
end

local function requestRoundabout(center: Vector3, radius: number)
	if _pendingPlacement or not _placeRoundaboutRemote then return end
	-- Reuse the place-result pending guard: success resets to Idle (clears the
	-- centre), a rejection keeps the centre so the player can retry.
	_pendingPlacement = { start = nil, curve = nil, curve2 = nil, freeformTangent = nil, phase = "Idle" }
	_pendingSince = os.clock()
	_placeRoundaboutRemote:FireServer({ center = center, radius = radius, roadType = roundaboutRoadType(), preset = _roundaboutPreset })
end

local function targetPoint(): Vector3?
	local raw = cursorWorldPoint()
	if not raw then
		_lastSnapResult = nil
		return nil
	end

	_lastSnapResult = SnapUtil.resolve(elevatedPlacementPoint(raw))
	return snapToMapEdge(_lastSnapResult.position)
end

local function updateGhost()
	-- Watchdog: self-heal the placement guard if a PlaceRoadResult never came back, so a
	-- failed roundabout/road request can't leave the tool permanently unresponsive.
	if _pendingPlacement and _pendingSince and os.clock() - _pendingSince > PLACEMENT_RESULT_TIMEOUT then
		_pendingPlacement = nil
		_pendingSince = nil
		warn("[RoadPlacementController] placement result timed out -- resetting tool")
	end

	if _phase == "Disabled" then
		GhostPreview.hideAll()
		return
	end

	-- Hold Alt for a free (un-snapped) angle + length.
	SnapUtil.setAngleFreeOverride(
		Settings.isActionDown("FreeAngle")
	)

	-- The node this draw is anchored to gets no guideline and no ring. Nil when idle.
	SnapUtil.setGuideExclusion(_start)

	-- The roundabout tool brings its own ring road type: its ghost shows even with
	-- no road type selected, so it must run BEFORE the neutral-mode guard below.
	if _mode == "Roundabout" and _editMode == "None" then
		DeleteHover.ClearRoad()
		updateRoundaboutGhost()
		return
	end

	-- Neutral mode: a road type is deselected. Show no placement ghost (you can still
	-- right-click to flip a one-way road); edit-mode hover is handled further below.
	if not _roadTypeSelected and _editMode == "None" then
		GhostPreview.hideAll()
		DeleteHover.ClearRoad()
		return
	end

	local raw = cursorWorldPoint()
	local cursor: Vector3? = nil
	local snapResult: any = nil
	if raw then
		trackCursorSpeed(raw)
		refreshBuildingFronts(raw)
		if _editMode == "UpgradeReplace" or _editMode == "Delete" then
			cursor = raw
			snapResult = SnapUtil.resolve(raw)
		else
			snapResult = SnapUtil.resolve(elevatedPlacementPoint(raw))
			_lastSnapResult = snapResult
			cursor = snapToMapEdge(snapResult.position)
		end
	else
		_lastSnapResult = nil
		-- Cursor left the ground (off-map, over the skyline). Nothing will redraw the guide
		-- dots this frame, so drop them -- otherwise the last guide is stranded on the map.
		GhostPreview.hideIndicator()
	end
	local gestureActive = _phase == "HasStart" or _phase == "HasCurve" or _phase == "HasCurve2"
	if _editMode == "Delete" or _editMode == "UpgradeReplace" then
		GhostPreview.hidePlacementVisuals()
		local segmentId = if raw then Snapper.segmentUnderPoint(raw) else nil
		local segment = if segmentId then Snapper.getSegmentInfo(segmentId) else nil
		DeleteHover.ShowRoadSegment(segment, if _editMode == "UpgradeReplace" then "Upgrade" else "Delete")
		return
	end

	DeleteHover.ClearRoad()
	if not gestureActive then
		if cursor then
			GhostPreview.positionIndicator(cursor, snapResult, nil, _roadType)
		end
		GhostPreview.clearCurveVisuals()
		return
	end
	if not cursor then
		GhostPreview.hideIndicator()
		return
	end
	local p0, p1, p2, p3 = Snapper.controlPoints(curveOpts(), cursor)
	if not p0 then
		GhostPreview.positionIndicator(cursor, snapResult, _start, _roadType)
		return
	end
	-- Same vertical conditioning the server applies, so the ghost previews the
	-- real profile and the steepness pre-check runs on the real curve.
	p1, p2 = applyVerticalProfile(p0 :: Vector3, p1 :: Vector3, p2 :: Vector3, p3 :: Vector3)

	-- Parallel mode: preview the twin road's outline offset perpendicular from the primary.
	local twinOff: Vector3? = nil
	if _parallelMode then
		twinOff = Snapper.parallelOffsetVector(p0 :: Vector3, p3 :: Vector3, parallelDisplacement())
	end

	-- Indicator follows the gesture's actual (snapped) endpoint so the ring and the ghost agree.
	-- Guides are NOT hidden just because the angle locked: the conflict was only ever the start
	-- node's own guideline, and SnapUtil.setGuideExclusion drops that one at the source.
	GhostPreview.positionIndicator(p3 :: Vector3, snapResult, _start, _roadType)

	local skipValidation = (_mode == "Curved" and _phase == "HasStart")
		or (_mode == "Freeform" and _phase == "HasStart" and not _freeformTangent)
		or (_mode == "AdvancedCurve" and (_phase == "HasStart" or _phase == "HasCurve"))

	GhostPreview.update({
		p0 = p0 :: Vector3, p1 = p1 :: Vector3, p2 = p2 :: Vector3, p3 = p3 :: Vector3,
		cursor = cursor,
		phase = _phase,
		mode = _mode,
		roadType = _roadType,
		skipValidation = skipValidation,
		validate = Snapper.validate,
		start = _start,
		headingInfo = Snapper.getHeadingInfo(),
		-- Existing road at the start node, so the preview can show the junction angle on a
		-- STRAIGHT road too (bends already had one). nil when the start is on open ground.
		startDir = Snapper.continuationDirAt(p0 :: Vector3),
		verticalMode = _verticalMode,
		elevation = _verticalOffset,
		constantSlope = _constantSlope,
		angleSnapActive = _angleSnapEnabled and not SnapUtil.isAngleFreeOverride(),
		parallelTwin = twinOff,
	})
end

local function cancel()
	_start = nil
	_curve = nil
	_curve2 = nil
	_freeformTangent = nil
	_lastSnapResult = nil
	_pendingPlacement = nil
	_pendingSince = nil
	if _phase ~= "Disabled" then _phase = "Idle" end
	GhostPreview.clear()
	DeleteHover.ClearRoad()
	notify()
end

function RoadPlacementController.cancel()
	cancel()
end

-- Parallel mode: attach a twin road (offset perpendicular from the primary) to the SAME
-- request, so the server places both under one rate-limit/cooldown. Firing a second
-- request instead trips the server's "placing roads too quickly" guard. The twin is
-- client-pre-validated; the server re-validates authoritatively and drops an illegal
-- twin without failing the primary.
local function attachParallelTwin(req: any)
	if not _parallelMode then return end
	local off = Snapper.parallelOffsetVector(req.p0, req.p3, parallelDisplacement())
	if not off then return end
	local q0, q1, q2, q3 = req.p0 + off, req.p1 + off, req.p2 + off, req.p3 + off
	q1, q2 = applyVerticalProfile(q0, q1, q2, q3)
	if Snapper.validate(q0, q1, q2, q3) then return end
	req.twin = { p0 = q0, p1 = q1, p2 = q2, p3 = q3 }
end

local function requestPlacement(req: any, nextState: any)
	if _pendingPlacement then return end
	attachParallelTwin(req)
	_pendingPlacement = nextState
	_pendingSince = os.clock()
	_placeRemote:FireServer(req)
end

local function onPlaceResult(ok: any, reason: any)
	local pending = _pendingPlacement
	_pendingPlacement = nil
	_pendingSince = nil
	if not pending then return end
	if ok == true then
		_start = pending.start
		_curve = pending.curve
		_curve2 = pending.curve2
		_freeformTangent = pending.freeformTangent
		_phase = pending.phase
	elseif typeof(reason) == "string" then
		warn("[RoadPlacementController] placement rejected: " .. reason)
		NotificationController.Notify({ text = "Can't place: " .. reason, kind = "danger", duration = 3 })
	end
	notify()
end

local function onClick()
	if _pendingPlacement then return end
	local rawCursor = cursorWorldPoint()
	if not rawCursor then return end

	if _editMode == "Delete" then
		local segmentId = Snapper.segmentUnderPoint(rawCursor)
		if segmentId and _removeSegRemote then
			_removeSegRemote:FireServer(segmentId, rawCursor)
		end
		return
	end

	if _editMode == "UpgradeReplace" then
		local segmentId = Snapper.segmentUnderPoint(rawCursor)
		if segmentId and _replaceSegRemote then
			local info = Snapper.getSegmentInfo(segmentId)
			-- A roundabout upgrades as ONE object, to the ring size selected on the roundabout
			-- tool: an ordinary road type would break the ring's one-way circulation (the server
			-- refuses it), and re-typing a single arc is what used to tear the ring apart.
			local requestedRoadType = if info and info.isRoundabout then roundaboutRoadType()
				elseif _roadTypeSelected then _roadType
				else ""
			_replaceSegRemote:FireServer(segmentId, requestedRoadType, rawCursor)
		end
		return
	end

	-- The roundabout tool brings its own ring road type, so it works with no road
	-- type selected -- it must run BEFORE the neutral-mode guard below.
	if _mode == "Roundabout" then
		-- Clicking inside an existing ring gives it the selected centre.
		local raw = cursorWorldPoint()
		local existing = if raw then roundaboutUnder(raw) else nil
		if existing then
			if _roundaboutPresetRemote then
				_roundaboutPresetRemote:FireServer({ center = existing, preset = _roundaboutPreset })
			end
			return
		end
		-- One click drops a ring at the selected size, snapped onto the road under the cursor.
		local center = roundaboutCenter()
		if center then
			requestRoundabout(center, roundaboutRadius())
		end
		return
	end

	-- No road type selected: left-click places nothing (neutral mode). Edit modes are
	-- handled above; right-click flipping is handled in onInputBegan.
	if not _roadTypeSelected then return end

	local cursor = targetPoint()
	if not cursor then return end

	if _mode == "Straight" then
		if _phase == "Idle" then
			_start = cursor
			_phase = "HasStart"
		elseif _phase == "HasStart" and _start then
			local p0, p1, p2, p3 = Snapper.controlPoints(curveOpts(), cursor)
			if p0 then
				local pp0, pp1, pp2, pp3 = Snapper.maybeParallelize(p0 :: Vector3, p1 :: Vector3, p2 :: Vector3, p3 :: Vector3, cursor, _parallelMode, _roadType)
				pp1, pp2 = applyVerticalProfile(pp0, pp1, pp2, pp3)
				local err = Snapper.validate(pp0, pp1, pp2, pp3)
				if not err then
					requestPlacement(
						{ roadType = _roadType, p0 = pp0, p1 = pp1, p2 = pp2, p3 = pp3, vMode = resolveVMode(pp0, pp1, pp2, pp3), constSlope = _constantSlope },
						{ start = pp3, curve = nil, freeformTangent = nil, phase = "HasStart" }
					)
				end
			end
		end

	elseif _mode == "Curved" then
		if _phase == "Idle" then
			_start = cursor
			_phase = "HasStart"
		elseif _phase == "HasStart" then
			_curve = cursor
			_phase = "HasCurve"
		elseif _phase == "HasCurve" and _start and _curve then
			local p0, p1, p2, p3 = Snapper.controlPoints(curveOpts(), cursor)
			if p0 then
				local pp0, pp1, pp2, pp3 = Snapper.maybeParallelize(p0 :: Vector3, p1 :: Vector3, p2 :: Vector3, p3 :: Vector3, cursor, _parallelMode, _roadType)
				pp1, pp2 = applyVerticalProfile(pp0, pp1, pp2, pp3)
				local err = Snapper.validate(pp0, pp1, pp2, pp3)
				if not err then
					requestPlacement(
						{ roadType = _roadType, p0 = pp0, p1 = pp1, p2 = pp2, p3 = pp3, vMode = resolveVMode(pp0, pp1, pp2, pp3), constSlope = _constantSlope },
						{ start = pp3, curve = nil, freeformTangent = nil, phase = "HasStart" }
					)
				end
			end
		end

	elseif _mode == "Freeform" then
		if _phase == "Idle" then
			_start = cursor
			_freeformTangent = nil
			_phase = "HasStart"
		elseif _phase == "HasStart" and not _freeformTangent then
			-- No heading yet, so this click is the first segment's bend. Once the road has
			-- a heading every later click places a whole segment on its own.
			_curve = cursor
			_phase = "HasCurve"
		elseif _start then
			local p0, p1, p2, p3 = Snapper.controlPoints(curveOpts(), cursor)
			if p0 then
				local pp0, pp1, pp2, pp3 = Snapper.maybeParallelize(p0 :: Vector3, p1 :: Vector3, p2 :: Vector3, p3 :: Vector3, cursor, _parallelMode, _roadType)
				pp1, pp2 = applyVerticalProfile(pp0, pp1, pp2, pp3)
				local err = Snapper.validate(pp0, pp1, pp2, pp3)
				if not err then
					requestPlacement(
						{ roadType = _roadType, p0 = pp0, p1 = pp1, p2 = pp2, p3 = pp3, vMode = resolveVMode(pp0, pp1, pp2, pp3), constSlope = _constantSlope },
						{ start = pp3, curve = nil, curve2 = nil, freeformTangent = Snapper.exitTangent(pp2, pp3), phase = "HasStart" }
					)
				end
			end

		end

	elseif _mode == "AdvancedCurve" then
		if _phase == "Idle" then

			_start = cursor
			_phase = "HasStart"
		elseif _phase == "HasStart" then

			_curve = cursor
			_phase = "HasCurve"
		elseif _phase == "HasCurve" then

			_curve2 = cursor
			_phase = "HasCurve2"
		elseif _phase == "HasCurve2" and _start and _curve and _curve2 then

			local p0 = _start :: Vector3
			local p1 = _curve :: Vector3
			local p2 = _curve2 :: Vector3
			local p3 = cursor
			local pp0, pp1, pp2, pp3 = Snapper.maybeParallelize(p0, p1, p2, p3, cursor, _parallelMode, _roadType)
			pp1, pp2 = applyVerticalProfile(pp0, pp1, pp2, pp3)
			local err = Snapper.validate(pp0, pp1, pp2, pp3)
			if not err then
				requestPlacement(
					{ roadType = _roadType, p0 = pp0, p1 = pp1, p2 = pp2, p3 = pp3, vMode = resolveVMode(pp0, pp1, pp2, pp3), constSlope = _constantSlope },
					{ start = pp3, curve = nil, curve2 = nil, freeformTangent = Snapper.exitTangent(pp2, pp3), phase = "HasStart" }
				)
			end
		end
	end
	notify()
end

local function toggleMode()
	if _phase == "Disabled" then return end
	if _mode == "Straight" then
		_mode = "Curved"
	elseif _mode == "Curved" then
		_mode = "AdvancedCurve"
	elseif _mode == "AdvancedCurve" then
		_mode = "Freeform"
	else
		_mode = "Straight"
	end
	_start = nil
	_curve = nil
	_curve2 = nil
	_freeformTangent = nil
	_lastSnapResult = nil
	_phase = "Idle"
	GhostPreview.clear()
	notify()
end

function RoadPlacementController.setRoadSnapEnabled(on: boolean)
	_roadSnapEnabled = on
	SnapUtil.setRoadSnapEnabled(on)
	notify()
end
function RoadPlacementController.isRoadSnapEnabled(): boolean return _roadSnapEnabled end

function RoadPlacementController.setGuideEnabled(on: boolean)
	_guideEnabled = on
	SnapUtil.setGuideEnabled(on)
	notify()
end
function RoadPlacementController.isGuideEnabled(): boolean return _guideEnabled end

-- The road grid IS the game-wide placement grid: on/off here flips it for every tool.
function RoadPlacementController.setGridEnabled(on: boolean)
	PlacementGrid.setEnabled(on)
	notify()
end
function RoadPlacementController.isGridEnabled(): boolean return PlacementGrid.isEnabled() end

function RoadPlacementController.setIntersectionSnapEnabled(on: boolean)
	_intersectionSnapEnabled = on
	SnapUtil.setIntersectionSnapEnabled(on)
	notify()
end
function RoadPlacementController.isIntersectionSnapEnabled(): boolean return _intersectionSnapEnabled end

function RoadPlacementController.setAngleSnapEnabled(on: boolean)
	_angleSnapEnabled = on
	SnapUtil.setAngleSnapEnabled(on)
	notify()
end
function RoadPlacementController.isAngleSnapEnabled(): boolean return _angleSnapEnabled end

function RoadPlacementController.setEditMode(mode: EditMode)
	if mode ~= "None" and mode ~= "UpgradeReplace" and mode ~= "Delete" then
		return
	end
	_editMode = mode
	if mode ~= "None" then
		cancel()
	end
	notify()
end

function RoadPlacementController.getEditMode(): EditMode
	return _editMode
end

function RoadPlacementController.undo()
	if _undoRemote then
		_undoRemote:FireServer()
	end
end

function RoadPlacementController.redo()
	if _redoRemote then
		_redoRemote:FireServer()
	end
end

function RoadPlacementController.setParallelModeEnabled(enabled: boolean)
	_parallelMode = enabled
	GhostPreview.clear()
	notify()
end

function RoadPlacementController.isParallelModeEnabled(): boolean
	return _parallelMode
end

-- Gap between the two roads' sidewalk edges, in studs (min 0.25 so they never overlap).
function RoadPlacementController.getParallelGap(): number
	return math.max(0.25, _parallelGap)
end

function RoadPlacementController.setParallelGap(studs: number)
	_parallelGap = math.max(0.25, studs)
	GhostPreview.clear()
	notify()
end

-- 0.25-stud steps from the 0.25 floor: 0.25 -> 0.5 -> 0.75 -> ...
function RoadPlacementController.adjustParallelGap(delta: number)
	RoadPlacementController.setParallelGap(_parallelGap + delta * 0.25)
end

function RoadPlacementController.setIntersectionStampModeEnabled(enabled: boolean)
	_intersectionStampMode = enabled
	notify()
end

function RoadPlacementController.isIntersectionStampModeEnabled(): boolean
	return _intersectionStampMode
end

function RoadPlacementController.getElevation(): number
	return _verticalOffset
end

function RoadPlacementController.setElevation(height: number)
	local step = math.max(1, RoadConstants.ELEVATION_STEP)
	local snapped = math.round(height / step) * step
	local clamped = math.clamp(snapped, -RoadConstants.TUNNEL_MAX_DEPTH, RoadConstants.MAX_ELEVATION)
	if clamped == _verticalOffset then return end

	_verticalOffset = clamped
	-- The signed offset is the single source of truth and the mode is derived from
	-- it, so the two can never disagree. (A stray "Elevated" flag on a ground-height
	-- road strands it on its own network layer, unable to weld to ground roads.)
	_verticalMode = if clamped > 0 then "Elevated" elseif clamped < 0 then "Tunnel" else "Ground"
	_lastSnapResult = nil
	GhostPreview.clear()
	Snapper.invalidateCaches()
	notify()
end

function RoadPlacementController.adjustElevation(deltaSteps: number)
	RoadPlacementController.setElevation(_verticalOffset + deltaSteps * RoadConstants.ELEVATION_STEP)
end

function RoadPlacementController.isAutoVertical(): boolean
	return _autoVertical
end

-- Turning Auto on parks the elevation at ground, because an offset would override it; that
-- is the same rule setVerticalMode already follows for the explicit modes.
function RoadPlacementController.setAutoVertical(on: boolean)
	_autoVertical = on == true
	if _autoVertical then
		RoadPlacementController.setElevation(0)
	end
	notify()
end

function RoadPlacementController.getVerticalMode(): VerticalMode
	return _verticalMode
end

function RoadPlacementController.setVerticalMode(mode: VerticalMode)
	-- Mode is derived state: seeding an offset through setElevation is the only
	-- way to change it, so mode and offset can never diverge.
	if mode == "Elevated" then
		RoadPlacementController.setElevation(math.max(_verticalOffset, RoadConstants.ELEVATED_DEFAULT_HEIGHT))
	elseif mode == "Tunnel" then
		RoadPlacementController.setElevation(-RoadConstants.TUNNEL_DEPTH)
	elseif mode == "Ground" then
		RoadPlacementController.setElevation(0)
	end
end

function RoadPlacementController.isConstantSlope(): boolean
	return _constantSlope
end

function RoadPlacementController.setConstantSlope(on: boolean)
	if _constantSlope == on then return end
	_constantSlope = on
	notify()
end

function RoadPlacementController.setEnabled(enabled: boolean)
	if enabled and _phase == "Disabled" then
		_phase = "Idle"
		notify()
	elseif not enabled then
		_phase = "Disabled"
		cancel()
	end
	-- Publish road-mode state for the outside-connection arrows (they show only in road mode).
	Players.LocalPlayer:SetAttribute("RoadToolActive", _phase ~= "Disabled")
end

function RoadPlacementController.isEnabled(): boolean
	return _phase ~= "Disabled"
end

function RoadPlacementController.setPlacementMode(mode: Mode)
	RoadPlacementController.setMode(mode)
end

function RoadPlacementController.setMode(mode: Mode)
	if _phase == "Disabled" then return end
	_editMode = "None"
	_mode = mode
	_start = nil
	_curve = nil
	_curve2 = nil
	_freeformTangent = nil
	_lastSnapResult = nil
	_phase = "Idle"
	GhostPreview.clear()
	notify()
end

local function onInputBegan(input: InputObject, processed: boolean)

	if Settings.pressed("Back", input) then
		if _phase ~= "Disabled" then cancel() end
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		if _phase == "Disabled" then return end
		-- Right-click a one-way road to flip its direction. Mid-gesture it still cancels the
		-- current draw (muscle memory). Fires on press like the cancel always has; the flip is
		-- server-authoritative and undoable (Ctrl+Z), so an accidental flip is cheap.
		local gestureActive = _phase == "HasStart" or _phase == "HasCurve" or _phase == "HasCurve2"
		if not gestureActive then
			local raw = cursorWorldPoint()
			if raw then
				local segId = Snapper.segmentUnderPoint(raw)
				local info = if segId then Snapper.getSegmentInfo(segId) else nil
				local spec = if info then RoadTypeCatalog.get(info.roadType) else nil
				if segId and info and not info.isRoundabout and spec and spec.oneWay and _replaceSegRemote then
					-- Empty roadType = "reverse this one-way segment" on the server.
					_replaceSegRemote:FireServer(segId, "", raw)
					return
				end
			end
		end
		cancel()
		return
	end
	if processed then return end
	-- Undo/redo are global, not road-tool-only: closing the road dock is not a reason for
	-- Ctrl+Z to do nothing. The creation editor keeps the keys while open -- it runs its own
	-- history, and firing the city's road undo from in there would be an invisible edit.
	-- ponytail: the history is still roads-only server-side (RoadHistoryService). Buildings,
	-- nature and zoning need their own stacks before Ctrl+Z can cover them.
	if not Players.LocalPlayer:GetAttribute("CreationEditorOpen") then
		if Settings.pressed("Undo", input) then
			RoadPlacementController.undo()
			return
		end
		if Settings.pressed("Redo", input) then
			RoadPlacementController.redo()
			return
		end
	end
	if _phase == "Disabled" then return end
	if Settings.pressed("RoadDeleteMode", input) then
		RoadPlacementController.setEditMode(if _editMode == "Delete" then "None" else "Delete")
		return
	end
	if Settings.pressed("RoadRaise", input) then
		RoadPlacementController.adjustElevation(1)
		return
	elseif Settings.pressed("RoadLower", input) then
		RoadPlacementController.adjustElevation(-1)
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		onClick()
	end
end

function RoadPlacementController.Init()
	if _inited then return end
	_inited = true
	SnapUtil.setActiveRoadType(_roadType)
	SnapUtil.setRoadSnapEnabled(_roadSnapEnabled)
	SnapUtil.setGuideEnabled(_guideEnabled)
	SnapUtil.setIntersectionSnapEnabled(_intersectionSnapEnabled)
	SnapUtil.setAngleSnapEnabled(_angleSnapEnabled)
	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	_placeRemote = Net.RequestPlaceRoad
	_placeResultRemote = Net.PlaceRoadResult
	table.insert(_remoteConns, _placeResultRemote.OnClientEvent:Connect(onPlaceResult))
	_replaceSegRemote = Net.RequestReplaceRoadSegment
	_removeSegRemote = Net.RequestRemoveRoadSegment
	_undoRemote = Net.RequestUndoRoad
	_redoRemote = Net.RequestRedoRoad
	_placeRoundaboutRemote = Net.RequestPlaceRoundabout
	_roundaboutPresetRemote = Net.RequestSetRoundaboutPreset
	_syncRemote = Net.SyncNodes
	table.insert(_remoteConns, _syncRemote.OnClientEvent:Connect(function(rows: { any })
		if typeof(rows) ~= "table" then return end
		Snapper.setNodesFull(rows)
	end))
	_syncSegRemote = Net.SyncSegments
	table.insert(_remoteConns, _syncSegRemote.OnClientEvent:Connect(function(segs: { any })
		if typeof(segs) ~= "table" then return end
		Snapper.setSegmentsFull(segs)
	end))

	_syncNodeDeltaRemote = Net.SyncNodesDelta
	table.insert(_remoteConns, _syncNodeDeltaRemote.OnClientEvent:Connect(function(delta: any)
		Snapper.applyNodeDelta(delta)
	end))

	_syncSegDeltaRemote = Net.SyncSegmentsDelta
	table.insert(_remoteConns, _syncSegDeltaRemote.OnClientEvent:Connect(function(delta: any)
		Snapper.applySegmentDelta(delta)
	end))

	table.insert(_remoteConns, Net.SyncIntersections.OnClientEvent:Connect(function(payload: any)
		Snapper.applyIntersectionsPayload(payload)
	end))

	GhostPreview.Init()
	_ghostFolder = GhostPreview.getFolder()
	-- No RaycastParams and no CharacterAdded staleness flag: Core.CursorRay owns the filter
	-- and resolves the character on every query, so a respawn cannot leave a stale one behind.
end

function RoadPlacementController.Bind()
	if _bound then return end
	_bound = true
	_inputConn = UserInputService.InputBegan:Connect(onInputBegan)
	_renderConn = RunService.RenderStepped:Connect(updateGhost)
end

function RoadPlacementController.Unbind()
	if _renderConn then
		_renderConn:Disconnect()
		_renderConn = nil
	end
	if _inputConn then
		_inputConn:Disconnect()
		_inputConn = nil
	end
	_bound = false
end

function RoadPlacementController.Cleanup()
	RoadPlacementController.Unbind()
	for _, conn in _remoteConns do
		conn:Disconnect()
	end
	table.clear(_remoteConns)
	_inited = false
	cancel()
	DeleteHover.ClearRoad()
	GhostPreview.Cleanup()
	_ghostFolder = nil :: any
end

function RoadPlacementController.Start() end

return RoadPlacementController
