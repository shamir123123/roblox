--!strict
-- OneWayDirectionView (client)
-- A centered direction arrow on every one-way road, shown ONLY while the road tool is
-- active (LocalPlayer "RoadToolActive" attribute, set by RoadPlacementController) --
-- Cities-Skylines style. Reuses the painted straight-arrow marking texture and points it
-- with the one-way flow (start node -> end node). Reads the client road mirror
-- (RoadPlacementSnapper) and rebuilds when the mirror changes. Right-click-to-flip lives
-- in RoadPlacementController; this module is pure view.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RoadConstants   = require(ReplicatedStorage.Road.RoadConstants)
local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)
local BezierUtil      = require(ReplicatedStorage.Road.BezierUtil)
local Snapper = require(script.Parent.Parent:WaitForChild("Controllers"):WaitForChild("RoadPlacementSnapper"))

local OneWayDirectionView = {}

local LocalPlayer = Players.LocalPlayer
local ROAD_MODE_ATTR = "RoadToolActive"
local UP = Vector3.yAxis
-- Sit just above the painted surface so the overlay clears the road's own markings.
local LIFT = RoadConstants.ROAD_THICKNESS * 0.5 + 0.15
local OUTLINE_LIFT = LIFT - 0.04            -- black outline plate sits just under the white arrow
local OUTLINE_COLOR = Color3.new(0, 0, 0)
local OUTLINE_SCALE = 1.04                  -- slightly larger black arrow = thin outline
-- Skip short links: their centre overlaps the road's own junction arrows / stop lines.
local MIN_SEG_LEN = 64

local _folder: Folder? = nil
local _started = false
local _roadMode = false
local _rebuildQueued = false

local function isOneWay(roadType: string): boolean
	local spec = RoadTypeCatalog.get(roadType)
	return spec ~= nil and spec.oneWay == true
end

local function makePlate(mid: Vector3, fwd: Vector3, roadUp: Vector3, scale: number, color: Color3, lift: number, parent: Instance)
	local pos = mid + roadUp * lift
	local plate = Instance.new("Part")
	plate.Name = "OneWayArrow"
	plate.Anchored = true
	plate.CanCollide = false
	plate.CanQuery = false
	plate.CanTouch = false
	plate.CastShadow = false
	plate.Transparency = 1
	plate.Size = Vector3.new(RoadConstants.ARROW_TEXTURE_WIDTH * scale, RoadConstants.ROAD_THICKNESS, RoadConstants.ARROW_TEXTURE_LENGTH * scale)
	-- A Top-face Decal's image-up axis is local +Z. Look opposite travel so the painted
	-- arrow points WITH the one-way flow; roadUp tilts the plate to follow the road grade.
	plate.CFrame = CFrame.lookAt(pos, pos - fwd, roadUp)
	local decal = Instance.new("Decal")
	decal.Texture = RoadConstants.ARROW_TEXTURE_THROUGH
	decal.Face = Enum.NormalId.Top
	decal.Color3 = color
	decal.Parent = plate
	plate.Parent = parent
end

local function clear()
	if _folder then
		_folder:Destroy()
		_folder = nil
	end
end

local function rebuild()
	clear()
	if not _roadMode then return end
	local folder = Instance.new("Folder")
	folder.Name = "_OneWayArrows"
	for _, seg in Snapper.getSegments() do
		if seg.isRoundabout then continue end
		if not isOneWay(seg.roadType) then continue end
		if BezierUtil.length(seg.p0, seg.p1, seg.p2, seg.p3, RoadConstants.SAMPLES_PER_SEGMENT) < MIN_SEG_LEN then continue end
		local mid = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, 0.5)
		-- 3D tangent (keeps the slope) = travel direction start node -> end node.
		local fwd = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, 0.5)
		if fwd.Magnitude < 1e-4 then fwd = seg.p3 - seg.p0 end
		if fwd.Magnitude < 1e-4 then continue end
		fwd = fwd.Unit
		-- Road surface frame: side is horizontal-ish, roadUp is the surface normal so the
		-- plate banks with the road's grade instead of lying flat.
		local side = fwd:Cross(UP)
		if side.Magnitude < 1e-4 then continue end
		side = side.Unit
		local roadUp = side:Cross(fwd).Unit
		makePlate(mid, fwd, roadUp, OUTLINE_SCALE, OUTLINE_COLOR, OUTLINE_LIFT, folder)
		makePlate(mid, fwd, roadUp, 1.0, RoadConstants.MARKING_WHITE, LIFT, folder)
	end
	folder.Parent = Workspace
	_folder = folder
end

-- Coalesce bursts of segment deltas (e.g. a city load) into one rebuild per frame.
local function queueRebuild()
	if not _roadMode or _rebuildQueued then return end
	_rebuildQueued = true
	task.defer(function()
		_rebuildQueued = false
		if not _roadMode then return end
		local ok, err = pcall(rebuild)
		if not ok then warn("[OneWayDirectionView] rebuild failed: " .. tostring(err)) end
	end)
end

local function setRoadMode(on: boolean)
	on = on and true or false
	if on == _roadMode then return end
	_roadMode = on
	rebuild()
end

function OneWayDirectionView.Start()
	if _started then return end
	_started = true

	_roadMode = LocalPlayer:GetAttribute(ROAD_MODE_ATTR) == true
	LocalPlayer:GetAttributeChangedSignal(ROAD_MODE_ATTR):Connect(function()
		setRoadMode(LocalPlayer:GetAttribute(ROAD_MODE_ATTR) == true)
	end)

	Snapper.setChangeListener(queueRebuild)

	if _roadMode then rebuild() end
end

return OneWayDirectionView
