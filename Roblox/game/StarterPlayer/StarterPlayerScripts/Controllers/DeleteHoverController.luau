--!strict

local Workspace = game:GetService("Workspace")

local UiScratch = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("UiScratch"))

local DeleteHoverController = {}

type SegmentInfo = {
	id: number,
	p0: Vector3,
	p1: Vector3,
	p2: Vector3,
	p3: Vector3,
	roadType: string?,
	startNode: number?,
	endNode: number?,
}

-- Hover outline for "this will be removed": only the silhouette outline is drawn,
-- no fill. Delete uses a neutral light outline (a deliberate target, no colour
-- clash); upgrade uses a positive green to read as a change for the better.
local DELETE_COLOR = Color3.fromRGB(235, 235, 238)
local UPGRADE_COLOR = Color3.fromRGB(108, 198, 118)
-- Bulldoze uses a crisp white target highlight with a faint fill.
local BULLDOZE_COLOR = Color3.fromRGB(255, 255, 255)

local _folder: Folder? = nil
local _highlight: Highlight? = nil
local _highlightOwner: string? = nil
-- One pooled Highlight per road model, adornee only. The old version reparented road models
-- under a shared container to get one seamless silhouette -- but road pieces live in
-- _City.Roads and RoadMeshView bakes each map cell from the models it finds THERE, so moving
-- one out fired ChildRemoved and the road visually vanished under the cursor (and the rebake
-- churn left stale meshes behind). Never reparent something the world renders from.
local _roadHighlights: { Highlight } = {}
local _roadModels: { Model } = {}
local _roadSig = ""
-- One Highlight per selected model, pooled. No artificial cap -- note Roblox itself only
-- renders ~31 Highlights at once, so a selection past that will delete everything but only
-- outline the first ~31. Fill tints the interior so the whole area reads as "to be removed".
local _selHighlights: { Highlight } = {}

local function ensureFolder(): Folder
	local folder = UiScratch.folder("DeleteHover")
	_folder = folder
	return folder
end

local function ensureHighlight(): Highlight
	if _highlight then
		return _highlight
	end

	local h = Instance.new("Highlight")
	h.Name = "DeleteTargetHighlight"
	h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	h.OutlineColor = DELETE_COLOR
	h.FillTransparency = 1
	h.OutlineTransparency = 0
	h.Enabled = false
	h.Parent = ensureFolder()
	_highlight = h
	return h
end

local function poolHighlight(pool: { Highlight }, i: number): Highlight
	local h = pool[i]
	if not h then
		h = Instance.new("Highlight")
		h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		h.OutlineTransparency = 0
		h.Parent = ensureFolder()
		pool[i] = h
	end
	return h
end

local function clearRoadHighlights()
	for _, h in _roadHighlights do
		h.Enabled = false
		h.Adornee = nil
	end
	table.clear(_roadModels)
end

-- A road hover covers the segment plus its dead-end / corner / junction caps, which are
-- separate sibling models -- each gets its own outline. Two adjacent outlines draw a seam
-- where they meet; that is the price of leaving the models where the renderer wants them.
local function captureModel(model: Model)
	table.insert(_roadModels, model)
end

local function applyRoadHighlight(color: Color3, fillTransparency: number)
	for i, m in _roadModels do
		local h = poolHighlight(_roadHighlights, i)
		h.Adornee = m
		h.OutlineColor = color
		h.FillColor = color
		h.FillTransparency = fillTransparency
		h.Enabled = true
	end
	for j = #_roadModels + 1, #_roadHighlights do
		_roadHighlights[j].Enabled = false
		_roadHighlights[j].Adornee = nil
	end
end

local function clearHighlight(owner: string?)
	if _highlight and (not owner or _highlightOwner == owner) then
		_highlight.Enabled = false
		_highlight.Adornee = nil
		_highlightOwner = nil
	end
end

local function findRoadModel(segmentId: number): Model?
	local city = Workspace:FindFirstChild("_City")
	local roads = city and city:FindFirstChild("Roads")
	local model = roads and roads:FindFirstChild("Segment_" .. tostring(segmentId))
	return if model and model:IsA("Model") then model else nil
end

local function findRoadNodeModel(prefix: string, nodeId: number): Model?
	local city = Workspace:FindFirstChild("_City")
	local roads = city and city:FindFirstChild("Roads")
	local model = roads and roads:FindFirstChild(prefix .. tostring(nodeId))
	return if model and model:IsA("Model") then model else nil
end

local function captureRoadNode(nodeId: number)
	-- Endpoint visuals are separate from Segment_<id>: dead-end caps and curved/
	-- intersection junction paving must follow the segment selection too.
	for _, prefix in { "DeadEnd_", "Corner_", "Junction_" } do
		local model = findRoadNodeModel(prefix, nodeId)
		if model then
			captureModel(model)
		end
	end
end

local function segmentSignature(segment: SegmentInfo, mode: string): string
	local function q(v: number): number
		return math.round(v * 10)
	end

	return table.concat({
		mode,
		tostring(segment.id),
		tostring(q(segment.p0.X)), tostring(q(segment.p0.Y)), tostring(q(segment.p0.Z)),
		tostring(q(segment.p1.X)), tostring(q(segment.p1.Y)), tostring(q(segment.p1.Z)),
		tostring(q(segment.p2.X)), tostring(q(segment.p2.Y)), tostring(q(segment.p2.Z)),
		tostring(q(segment.p3.X)), tostring(q(segment.p3.Y)), tostring(q(segment.p3.Z)),
		tostring(segment.roadType or ""),
		tostring(segment.startNode or ""),
		tostring(segment.endNode or ""),
	}, "|")
end

-- Walk up from a hit part to the owning deletable Model. Covers zoned buildings
-- (BlueprintId), emergency services (ServiceId), schools (SchoolId), and transit
-- assets (StopId / DepotId), so the bulldoze tool can target them all.
function DeleteHoverController.FindBuildingFromInstance(instance: Instance?): Model?
	local cursor = instance
	while cursor and cursor ~= Workspace do
		if cursor:IsA("Model")
			and (cursor:GetAttribute("BlueprintId") ~= nil
				or cursor:GetAttribute("ServiceId") ~= nil
				or cursor:GetAttribute("SchoolId") ~= nil
				or cursor:GetAttribute("StopId") ~= nil
				or cursor:GetAttribute("DepotId") ~= nil
				or cursor:GetAttribute("NatureKey") ~= nil) then
			return cursor :: Model
		end
		cursor = cursor.Parent
	end

	return nil
end

-- Outline + fill every model in a brush/box selection so the player sees what's inside.
function DeleteHoverController.ShowBuildingSelection(models: { Model }, mode: string?)
	local color = if mode == "Bulldoze" then BULLDOZE_COLOR else DELETE_COLOR
	local fill = if mode == "Bulldoze" then 0.6 else 1
	local i = 0
	for _, m in models do
		i += 1
		local h = poolHighlight(_selHighlights, i)
		h.Adornee = m
		h.OutlineColor = color
		h.FillColor = color
		h.FillTransparency = fill
		h.OutlineTransparency = 0
		h.Enabled = true
	end
	for j = i + 1, #_selHighlights do
		_selHighlights[j].Enabled = false
		_selHighlights[j].Adornee = nil
	end
end

function DeleteHoverController.ClearBuildingSelection()
	for _, h in _selHighlights do
		h.Enabled = false
		h.Adornee = nil
	end
end

function DeleteHoverController.ShowBuilding(model: Model?, mode: string?)
	if not model then
		DeleteHoverController.ClearBuilding()
		return
	end

	clearRoadHighlights()
	clearHighlight("Road")
	_roadSig = ""

	local h = ensureHighlight()
	h.Adornee = model
	if mode == "Bulldoze" then
		h.OutlineColor = BULLDOZE_COLOR
		h.FillColor = BULLDOZE_COLOR
		h.FillTransparency = 0.8
	else
		h.OutlineColor = DELETE_COLOR
		h.FillTransparency = 1
	end
	h.Enabled = true
	_highlightOwner = "Building"
end

function DeleteHoverController.ShowRoadSegment(segment: SegmentInfo?, mode: string?)
	if not segment then
		DeleteHoverController.ClearRoad()
		return
	end

	local hoverMode = mode or "Delete"
	local color: Color3 = DELETE_COLOR
	local fill: number = 1
	if hoverMode == "Upgrade" then
		color = UPGRADE_COLOR
	elseif hoverMode == "Bulldoze" then
		color, fill = BULLDOZE_COLOR, 0.75
	end
	clearHighlight("Building")

	local sig = segmentSignature(segment, hoverMode)
	if sig == _roadSig and #_roadModels > 0 then
		return
	end

	clearRoadHighlights()

	local model = findRoadModel(segment.id)
	if model then
		captureModel(model)
	end

	-- Endpoint caps/junction corners are separate models; capture them with the segment.
	local seen: { [number]: boolean } = {}
	for _, rawNodeId in { segment.startNode, segment.endNode } do
		if typeof(rawNodeId) == "number" then
			local nodeId = rawNodeId :: number
			if not seen[nodeId] then
				seen[nodeId] = true
				captureRoadNode(nodeId)
			end
		end
	end

	applyRoadHighlight(color, fill)
	_roadSig = sig
end

-- Persistent multi-road selection used by the bulldozer drag gesture. The caller
-- refreshes this only when a segment is toggled, so selected roads stay highlighted
-- until the mouse button is released.
function DeleteHoverController.ShowRoadSelection(segments: { SegmentInfo }, mode: string?)
	local hoverMode = mode or "Delete"
	local color: Color3 = DELETE_COLOR
	local fill: number = 1
	if hoverMode == "Upgrade" then
		color = UPGRADE_COLOR
	elseif hoverMode == "Bulldoze" then
		color, fill = BULLDOZE_COLOR, 0.75
	end

	clearHighlight("Building")
	clearRoadHighlights()
	local seenCaps: { [number]: boolean } = {}

	for _, segment in segments do
		local model = findRoadModel(segment.id)
		if model then
			captureModel(model)
		end

		for _, rawNodeId in { segment.startNode, segment.endNode } do
			if typeof(rawNodeId) == "number" then
				local nodeId = rawNodeId :: number
				if not seenCaps[nodeId] then
					seenCaps[nodeId] = true
					captureRoadNode(nodeId)
				end
			end
		end
	end

	applyRoadHighlight(color, fill)
	_roadSig = ""
end

function DeleteHoverController.ClearRoad()
	clearRoadHighlights()
	clearHighlight("Road")
	_roadSig = ""
end

function DeleteHoverController.ClearBuilding()
	clearHighlight("Building")
end

function DeleteHoverController.Clear()
	clearRoadHighlights()
	clearHighlight(nil)
	DeleteHoverController.ClearBuildingSelection()
	_roadSig = ""
end

function DeleteHoverController.Cleanup()
	DeleteHoverController.Clear()
	for _, h in _selHighlights do h:Destroy() end
	table.clear(_selHighlights)
	if _highlight then
		_highlight:Destroy()
		_highlight = nil
	end
	for _, h in _roadHighlights do h:Destroy() end
	table.clear(_roadHighlights)
	table.clear(_roadModels)
	if _folder then
		_folder:Destroy()
		_folder = nil
	end
end

return DeleteHoverController
