--!strict
-- TransitClient
-- The client's mirror of the public-transit state. Receives the SyncTransit snapshot
-- (depots / stops / routes + live line stats), renders each route as a coloured line
-- with direction arrows along the roads, and hands the snapshot to the placement tool
-- and the Transportation Overview panel. Buses themselves are smoothed for free by
-- NPCDriverView (they carry the "NPCDriver" tag), so this is lines + data only.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")

local Net = require(ReplicatedStorage:WaitForChild("Networker"))
local RoadConstants = require(ReplicatedStorage:WaitForChild("Road"):WaitForChild("RoadConstants"))
local UiScratch = require(script.Parent:WaitForChild("UiScratch"))

local uiFolder = script.Parent.Parent:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local HudScale = require(uiFolder:WaitForChild("HudScale"))
local Glass = require(uiFolder:WaitForChild("Kit"):WaitForChild("Glass"))

local TransitClient = {}

local LINE_Y_LIFT  = 0.6   -- studs above the road surface
local LINE_WIDTH   = 1.4
local ARROW_SPACING = 56
local ARROW_SPEED   = 34
local LANE_OFFSET   = 1.5  -- studs: parallel spacing so routes sharing a road don't overlap
-- Theme-driven: the champagne accent marks stops (balloon, rings, prompt chips); the
-- first stop of a line under construction reads green = "click here to close the loop".
local STOP_ICON_COLOR = Theme.Color.Accent
local STOP_ICON_STROKE = Theme.Glass.StrokeColor
local FIRST_STOP_COLOR = Theme.Color.Positive

local _snapshot: any = { depots = {}, stops = {}, routes = {}, allowance = 0, assigned = 0 }
local _listeners: { (any) -> () } = {}
local _started = false
local _activeRouteId: number? = nil
local _lineFolders: { [number]: Folder } = {}
local _lineSig: { [number]: string } = {}
-- Route lines + stop markers only show while transit mode is active (the tools are open
-- or the overview panel is open). Ref-counted so either reason keeps them visible.
local _modeRefs: { [string]: boolean } = {}
local _active = false
local _markers: { [number]: Instance } = {}
local _markerSig = "" -- what the current markers were built from; skips no-op rebuilds
local _routeStopRings: { [number]: Part } = {}
type ArrowRecord = { part: BasePart, path: { Vector3 }, cum: { number }, length: number, offset: number, color: Color3, off: number }
local _routeArrows: { [number]: { ArrowRecord } } = {}
local _routeLineTextures: { Texture } = {}
local _arrowPhase = 0
local _renderConn: RBXScriptConnection? = nil
local _hintAnchor: Part? = nil
local _hintBillboard: BillboardGui? = nil
local _hintRing: Part? = nil
local _hintStopId: number? = nil
local _hintPos: Vector3? = nil
local _hintPrimary: string? = nil
local _hintAction: string? = nil
local _hintSecondary: string? = nil
local _stopClickHandler: ((number) -> ())? = nil
local _statusGui: ScreenGui? = nil
local _statusFrame: Frame? = nil
local _statusPrimary: TextLabel? = nil
local _statusSecondary: TextLabel? = nil
local _statusStroke: UIStroke? = nil

local function lineRoot(): Folder
	return UiScratch.folder("TransitLines")
end

local function segPart(parent: Instance, a: Vector3, b: Vector3, color: Color3, active: boolean, off: number)
	local seg = b - a
	if off ~= 0 and seg.Magnitude > 1e-3 then
		local u = seg.Unit
		local perp = Vector3.new(u.Z, 0, -u.X) * off
		a = a + perp; b = b + perp
	end
	local mid = (a + b) * 0.5
	local len = (b - a).Magnitude
	if len < 0.05 then return end
	local p = Instance.new("Part")
	p.Anchored = true; p.CanCollide = false; p.CanTouch = false; p.CanQuery = false; p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.Color = color
	p.Transparency = if active then 0.05 else 0.35
	local w = if active then LINE_WIDTH * 1.5 else LINE_WIDTH
	p.Size = Vector3.new(w, 0.2, len)
	p.CFrame = CFrame.lookAt(mid, b) -- length along local Z
	p.Parent = parent

	local texture = Instance.new("Texture")
	texture.Name = "RouteArrowTexture"
	texture.Texture = RoadConstants.TRANSIT_ROUTE_ARROW_TEXTURE
	texture.Face = Enum.NormalId.Top
	texture.Color3 = color
	texture.Transparency = if active then 0.02 else 0.25
	texture.StudsPerTileU = w
	texture.StudsPerTileV = ARROW_SPACING
	texture.Parent = p
	table.insert(_routeLineTextures, texture)
end

local function arrowPart(parent: Instance, at: Vector3, dir: Vector3, color: Color3, active: boolean): WedgePart
	local p = Instance.new("WedgePart")
	p.Name = "DirectionArrow"
	p.Anchored = true; p.CanCollide = false; p.CanTouch = false; p.CanQuery = false; p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.Color = color
	p.Transparency = if active then 0.02 else 0.2
	p.Size = if active then Vector3.new(3.2, 0.35, 3.6) else Vector3.new(2.4, 0.3, 2.8)
	p.CFrame = CFrame.lookAt(at, at + dir) * CFrame.Angles(math.rad(-90), 0, 0)
	p.Parent = parent
	return p
end

local function pathCum(path: { Vector3 }): ({ number }, number)
	local cum: { number } = table.create(#path, 0)
	cum[1] = 0
	local total = 0
	for i = 2, #path do
		total += (path[i] - path[i - 1]).Magnitude
		cum[i] = total
	end
	return cum, total
end

local function pointAlongPath(path: { Vector3 }, cum: { number }, dist: number): (Vector3, Vector3)
	if #path < 2 then
		return path[1] or Vector3.zero, Vector3.zAxis
	end
	local total = cum[#cum] or 0
	if total <= 0 then
		local dir = path[#path] - path[1]
		return path[1], if dir.Magnitude > 0.1 then dir.Unit else Vector3.zAxis
	end
	dist = dist % total
	for i = 2, #path do
		local segStart = cum[i - 1] or 0
		local segEnd = cum[i] or segStart
		if dist <= segEnd then
			local a = path[i - 1]
			local b = path[i]
			local span = math.max(0.001, segEnd - segStart)
			local alpha = math.clamp((dist - segStart) / span, 0, 1)
			local dir = b - a
			return a:Lerp(b, alpha), if dir.Magnitude > 0.1 then dir.Unit else Vector3.zAxis
		end
	end
	local fallback = path[#path] - path[#path - 1]
	return path[#path], if fallback.Magnitude > 0.1 then fallback.Unit else Vector3.zAxis
end

local function clearRouteArrows(routeId: number)
	local list = _routeArrows[routeId]
	if list then
		for _, rec in list do
			if rec.part.Parent then rec.part:Destroy() end
		end
	end
	_routeArrows[routeId] = nil
end

local function buildRouteArrows(routeId: number, folder: Instance, path: { Vector3 }, color: Color3, active: boolean, off: number)
	clearRouteArrows(routeId)
	-- Direction arrows now live as animated textures on the route line parts.
	-- This avoids creating and moving up to 80 WedgeParts per route every frame.
end

local function animateRouteArrows(dt: number)
	if not _active then return end
	_arrowPhase = (_arrowPhase + dt * ARROW_SPEED) % 100000
	for i = #_routeLineTextures, 1, -1 do
		local texture = _routeLineTextures[i]
		if texture.Parent then
			texture.OffsetStudsV = -_arrowPhase
		else
			table.remove(_routeLineTextures, i)
		end
	end
end

local function routeSig(route: any, lane: number): string
	local path = route.path or {}
	local first = path[1]
	local last = path[#path]
	local color = route.color or Color3.fromRGB(60, 170, 200)
	return string.format("%d|%d|%s|%s|%d|%d|%d,%d,%d", #path,
		math.floor((route.length or 0) + 0.5),
		if first then string.format("%.0f,%.0f", first.X, first.Z) else "-",
		if last then string.format("%.0f,%.0f", last.X, last.Z) else "-",
		lane,
		if _activeRouteId == route.id then 1 else 0,
		math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5))
end

local function buildRouteLine(route: any, lane: number)
	local folder = _lineFolders[route.id]
	if folder then
		folder:ClearAllChildren()
		clearRouteArrows(route.id)
	else
		folder = Instance.new("Folder"); folder.Name = "Route_" .. route.id; folder.Parent = lineRoot()
		_lineFolders[route.id] = folder
	end
	local path = route.path or {}
	if #path < 2 then return end
	local color: Color3 = route.color or Color3.fromRGB(60, 170, 200)
	local active = _activeRouteId == route.id
	local off = lane * LANE_OFFSET
	local lift = Vector3.new(0, LINE_Y_LIFT, 0)
	for i = 1, #path - 1 do
		local a = path[i] + lift
		local b = path[i + 1] + lift
		segPart(folder, a, b, color, active, off)
	end
	buildRouteArrows(route.id, folder, path, color, active, off)
end

local function rebuildLines()
	-- Stable per-route lane index so routes sharing a road run parallel, not overlapping.
	local ids: { number } = {}
	for _, route in _snapshot.routes do table.insert(ids, route.id) end
	table.sort(ids)
	local lane: { [number]: number } = {}
	for i, id in ids do lane[id] = i - 1 end

	local seen: { [number]: boolean } = {}
	for _, route in _snapshot.routes do
		seen[route.id] = true
		local sig = routeSig(route, lane[route.id])
		if _lineSig[route.id] ~= sig then
			_lineSig[route.id] = sig
			buildRouteLine(route, lane[route.id])
		end
	end
	for id, folder in _lineFolders do
		if not seen[id] then
			clearRouteArrows(id)
			folder:Destroy(); _lineFolders[id] = nil; _lineSig[id] = nil
		end
	end
end

-- == Stop markers (C:S-style billboards) ======================================
local function ensureStatusGui(): Frame?
	local player = Players.LocalPlayer
	local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return nil end
	if _statusFrame and _statusFrame.Parent then return _statusFrame end

	local gui = playerGui:FindFirstChild("TransitRouteStatus")
	if not gui or not gui:IsA("ScreenGui") then
		if gui then gui:Destroy() end
		gui = Instance.new("ScreenGui")
		gui.Name = "TransitRouteStatus"
		gui.ResetOnSpawn = false
		gui.IgnoreGuiInset = true
		gui.DisplayOrder = Theme.Layer.CostTag + 4
		gui.Parent = playerGui
	end
	HudScale.attach(gui)
	_statusGui = gui

	local frame = Instance.new("Frame")
	frame.Name = "Status"
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = UDim2.new(0.5, 0, 0, 68)
	frame.Size = UDim2.fromOffset(340, 44)
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = gui
	local stroke = Glass.apply(frame, Theme.Radius.MD)
	stroke.Color = Theme.Color.StrokeSoft
	stroke.Transparency = Theme.Glass.StrokeTransparency
	stroke.Thickness = Theme.StrokeWidth.Thin

	local primary = Instance.new("TextLabel")
	primary.BackgroundTransparency = 1
	primary.Position = UDim2.fromOffset(14, 6)
	primary.Size = UDim2.new(1, -28, 0, 18)
	primary.TextColor3 = Theme.Color.TextPrimary
	primary.TextSize = Theme.TextSize.SM
	primary.TextXAlignment = Enum.TextXAlignment.Left
	primary.TextTruncate = Enum.TextTruncate.AtEnd
	primary.FontFace = Theme.Font.Bold
	primary.Parent = frame

	local secondary = Instance.new("TextLabel")
	secondary.BackgroundTransparency = 1
	secondary.Position = UDim2.fromOffset(14, 24)
	secondary.Size = UDim2.new(1, -28, 0, 14)
	secondary.TextColor3 = Theme.Color.TextSecondary
	secondary.TextSize = Theme.TextSize.XS
	secondary.TextXAlignment = Enum.TextXAlignment.Left
	secondary.TextTruncate = Enum.TextTruncate.AtEnd
	secondary.FontFace = Theme.Font.Label
	secondary.Parent = frame

	_statusFrame = frame
	_statusPrimary = primary
	_statusSecondary = secondary
	_statusStroke = stroke
	return frame
end

local function hideStatusGui()
	if _statusFrame then _statusFrame.Visible = false end
end

local function markerRoot(): Folder
	return UiScratch.folder("TransitStopMarkers")
end

local function makeMarker(stop: any): Instance
	local anchor = Instance.new("Part")
	anchor.Name = "StopMarkerAnchor_" .. tostring(stop.id)
	anchor.Anchored = true; anchor.CanCollide = false; anchor.CanQuery = false; anchor.CanTouch = false
	anchor.Transparency = 1; anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(stop.pos + Vector3.new(0, 8.8, 0))
	anchor.Parent = markerRoot()

	local bb = Instance.new("BillboardGui")
	bb.Adornee = anchor
	bb.Size = UDim2.fromOffset(150, 94)
	bb.AlwaysOnTop = true
	bb.Active = true
	bb.MaxDistance = 850
	bb.Parent = anchor

	local root = Instance.new("Frame")
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = bb

	local icon = Instance.new("Frame")
	icon.AnchorPoint = Vector2.new(0.5, 0)
	icon.Position = UDim2.new(0.5, 0, 0, 0)
	icon.Size = UDim2.fromOffset(56, 56)
	icon.BackgroundColor3 = Theme.Color.Accent
	icon.BorderSizePixel = 0
	icon.Parent = root
	local iconCorner = Instance.new("UICorner")
	iconCorner.CornerRadius = UDim.new(1, 0)
	iconCorner.Parent = icon
	local iconStroke = Instance.new("UIStroke")
	iconStroke.Color = STOP_ICON_STROKE
	iconStroke.Transparency = 0.05
	iconStroke.Thickness = 1.5
	iconStroke.Parent = icon

	local bus = Instance.new("Frame")
	bus.AnchorPoint = Vector2.new(0.5, 0.5)
	bus.Position = UDim2.fromScale(0.5, 0.47)
	bus.Size = UDim2.fromOffset(28, 30)
	bus.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	bus.BorderSizePixel = 0
	bus.Parent = icon
	local busCorner = Instance.new("UICorner")
	busCorner.CornerRadius = UDim.new(0, 4)
	busCorner.Parent = bus

	local window = Instance.new("Frame")
	window.Position = UDim2.fromOffset(4, 5)
	window.Size = UDim2.fromOffset(20, 11)
	window.BackgroundColor3 = Theme.Color.OnAccent
	window.BorderSizePixel = 0
	window.Parent = bus
	local windowCorner = Instance.new("UICorner")
	windowCorner.CornerRadius = UDim.new(0, 2)
	windowCorner.Parent = window

	for _, x in { 6, 20 } do
		local wheel = Instance.new("Frame")
		wheel.AnchorPoint = Vector2.new(0.5, 0.5)
		wheel.Position = UDim2.new(0, x, 1, -4)
		wheel.Size = UDim2.fromOffset(5, 5)
		wheel.BackgroundColor3 = Theme.Color.OnAccent
		wheel.BorderSizePixel = 0
		wheel.Parent = bus
		local wheelCorner = Instance.new("UICorner")
		wheelCorner.CornerRadius = UDim.new(1, 0)
		wheelCorner.Parent = wheel
	end

	local tail = Instance.new("Frame")
	tail.AnchorPoint = Vector2.new(0.5, 0)
	tail.Position = UDim2.new(0.5, 0, 0, 52)
	tail.Size = UDim2.fromOffset(16, 16)
	tail.Rotation = 45
	tail.BackgroundColor3 = STOP_ICON_COLOR
	tail.BorderSizePixel = 0
	tail.Parent = root

	local name = Instance.new("TextLabel")
	name.AnchorPoint = Vector2.new(0.5, 0)
	name.BackgroundTransparency = 1
	name.Position = UDim2.new(0.5, 0, 0, 66)
	name.Size = UDim2.new(1, 0, 0, 22)
	name.Text = stop.name or "Bus Stop"
	name.TextColor3 = Theme.Color.TextPrimary
	name.TextSize = 14
	name.TextXAlignment = Enum.TextXAlignment.Center
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.FontFace = Theme.Font.Bold
	name.Parent = root

	local click = Instance.new("TextButton")
	click.Name = "StopMarkerClickTarget"
	click.BackgroundTransparency = 1
	click.BorderSizePixel = 0
	click.Text = ""
	click.AutoButtonColor = false
	click.Active = true
	click.Size = UDim2.fromScale(1, 1)
	click.ZIndex = 50
	click.Parent = root
	click.Activated:Connect(function()
		if _stopClickHandler then
			_stopClickHandler(stop.id)
		end
	end)

	return anchor
end

local function clearMarkers()
	UiScratch.clear("TransitStopMarkers")
	table.clear(_markers)
	_markerSig = ""
end

-- Markers only actually change when a stop is added/removed/renamed, but snapshots
-- arrive every ~1.5s while routes exist. Rebuilding billboards on every snapshot made
-- them churn constantly; skip when nothing marker-visible changed.
local function rebuildMarkers()
	local parts = table.create(#_snapshot.stops)
	for _, stop in _snapshot.stops do
		parts[#parts + 1] = string.format("%d:%s:%.0f,%.0f", stop.id, tostring(stop.name or ""), stop.pos.X, stop.pos.Z)
	end
	local sig = table.concat(parts, "|")
	if sig == _markerSig then return end
	clearMarkers()
	_markerSig = sig
	for _, stop in _snapshot.stops do
		_markers[stop.id] = makeMarker(stop)
	end
end

local function hintRoot(): Folder
	return UiScratch.folder("TransitRouteHints")
end

local function stopById(id: number?): any?
	if not id then return nil end
	for _, stop in _snapshot.stops do
		if stop.id == id then return stop end
	end
	return nil
end

local function activeRoute(): any?
	if not _activeRouteId then return nil end
	for _, route in _snapshot.routes do
		if route.id == _activeRouteId then return route end
	end
	return nil
end

local function clearRouteStopRings()
	for id, ring in _routeStopRings do
		if ring.Parent then ring:Destroy() end
		_routeStopRings[id] = nil
	end
end

local function makeRouteStopRing(stop: any, isFirst: boolean): Part
	local ring = Instance.new("Part")
	ring.Name = "SelectedRouteStop_" .. tostring(stop.id)
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanTouch = false
	ring.CanQuery = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = if isFirst then FIRST_STOP_COLOR else STOP_ICON_COLOR
	ring.Transparency = if isFirst then 0.16 else 0.28
	ring.Size = if isFirst then Vector3.new(0.14, 9.3, 9.3) else Vector3.new(0.12, 8.2, 8.2)
	ring.CFrame = CFrame.new(stop.pos.X, stop.pos.Y + 0.22, stop.pos.Z) * CFrame.Angles(0, 0, math.pi / 2)
	ring.Parent = hintRoot()
	return ring
end

local function rebuildRouteStopRings()
	clearRouteStopRings()
	if not _active or _modeRefs.tools ~= true then return end
	local route = activeRoute()
	if not route or typeof(route.stops) ~= "table" then return end
	local seen: { [number]: boolean } = {}
	for i, stopId in route.stops do
		if typeof(stopId) == "number" and not seen[stopId] then
			local stop = stopById(stopId)
			if stop then
				_routeStopRings[stopId] = makeRouteStopRing(stop, i == 1)
				seen[stopId] = true
			end
		end
	end
end

local function ensureHintRing(): Part
	if _hintRing and _hintRing.Parent then return _hintRing end
	local ring = Instance.new("Part")
	ring.Name = "RouteStopHighlight"
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanTouch = false
	ring.CanQuery = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = STOP_ICON_COLOR
	ring.Transparency = 0.35
	ring.Size = Vector3.new(0.12, 7.5, 7.5)
	ring.Parent = hintRoot()
	_hintRing = ring
	return ring
end

local function clearHint()
	if _hintAnchor then _hintAnchor:Destroy(); _hintAnchor = nil end
	_hintBillboard = nil
	if _hintRing then _hintRing:Destroy(); _hintRing = nil end
end

local function makePromptCard(parent: Instance, order: number, iconText: string, text: string, width: number)
	local card = Instance.new("Frame")
	card.Size = UDim2.fromOffset(width, 26)
	card.LayoutOrder = order
	card.Parent = parent
	local stroke = Glass.apply(card, Theme.Radius.SM)
	stroke.Color = Theme.Color.StrokeSoft
	stroke.Transparency = Theme.Glass.StrokeTransparency
	stroke.Thickness = Theme.StrokeWidth.Thin
	local icon = Instance.new("TextLabel")
	icon.BackgroundColor3 = STOP_ICON_COLOR
	icon.BorderSizePixel = 0
	icon.Position = UDim2.fromOffset(4, 4)
	icon.Size = UDim2.fromOffset(18, 18)
	icon.Text = iconText
	icon.TextColor3 = Theme.Color.OnAccent
	icon.TextSize = Theme.TextSize.XS
	icon.FontFace = Theme.Font.Bold
	icon.Parent = card
	local iconCorner = Instance.new("UICorner")
	iconCorner.CornerRadius = UDim.new(1, 0)
	iconCorner.Parent = icon
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromOffset(28, 0)
	label.Size = UDim2.new(1, -34, 1, 0)
	label.Text = text
	label.TextColor3 = Theme.Color.TextPrimary
	label.TextSize = Theme.TextSize.XS
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.FontFace = Theme.Font.Bold
	label.Parent = card
end

local function rebuildRouteHint()
	clearHint()
	if not _active or (not _hintStopId and not _hintPos) then return end
	local stop = stopById(_hintStopId)
	local pos = if stop then stop.pos else _hintPos
	if not pos then return end
	local primary = _hintPrimary
	if not primary then
		primary = if stop then tostring(stop.name or "Bus Stop") else "Route waypoint"
	end
	local action = _hintAction
	local secondary = _hintSecondary

	local ring = ensureHintRing()
	ring.CFrame = CFrame.new(pos.X, pos.Y + 0.18, pos.Z) * CFrame.Angles(0, 0, math.pi / 2)

	local anchor = Instance.new("Part")
	anchor.Name = "RouteHintAnchor"
	anchor.Anchored = true; anchor.CanCollide = false; anchor.CanTouch = false; anchor.CanQuery = false
	anchor.Transparency = 1; anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(pos + Vector3.new(0, 8.2, 0))
	anchor.Parent = hintRoot()
	_hintAnchor = anchor

	local rows = 1
	if action then rows += 1 end
	if secondary then rows += 1 end
	local bb = Instance.new("BillboardGui")
	bb.Adornee = anchor
	bb.Size = UDim2.fromOffset(230, rows * 30)
	bb.StudsOffsetWorldSpace = Vector3.new(0, -1.6, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = 850
	bb.Parent = anchor
	_hintBillboard = bb

	local stack = Instance.new("Frame")
	stack.BackgroundTransparency = 1
	stack.Size = UDim2.fromScale(1, 1)
	stack.Parent = bb
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 4)
	list.Parent = stack

	makePromptCard(stack, 1, "\u{25A3}", primary, 206)
	if action then makePromptCard(stack, 2, "\u{25CF}", action, 142) end
	if secondary then makePromptCard(stack, 3, "\u{21B6}", secondary, 96) end
end

local function clearLines()
	for id, folder in _lineFolders do
		clearRouteArrows(id)
		folder:Destroy(); _lineFolders[id] = nil; _lineSig[id] = nil
	end
end

local function shouldShowLines(): boolean
	return _modeRefs.tools == true or _modeRefs.overview == true
end

local function refreshVisibility()
	if _active then
		if shouldShowLines() then
			rebuildLines()
		else
			clearLines()
		end
		rebuildMarkers()
		rebuildRouteStopRings()
		if _modeRefs.tools == true then
			rebuildRouteHint()
		else
			clearHint()
		end
	else
		clearLines()
		clearMarkers()
		clearRouteStopRings()
		clearHint()
		hideStatusGui()
	end
end

local function routeStatusColor(tone: string?): Color3
	if tone == "danger" then
		return Theme.Color.Danger
	elseif tone == "attention" then
		return Theme.Color.Brand
	end
	return Theme.Color.StrokeSoft
end

-- == Public ====================================================================
function TransitClient.getSnapshot(): any
	return _snapshot
end

function TransitClient.getActiveRouteData(): any?
	return activeRoute()
end

function TransitClient.setRouteStatus(primary: string?, secondary: string?, tone: string?)
	if not primary then
		hideStatusGui()
		return
	end
	local frame = ensureStatusGui()
	if not frame then return end
	frame.Visible = true
	if _statusPrimary then _statusPrimary.Text = primary end
	if _statusSecondary then _statusSecondary.Text = secondary or "" end
	if _statusStroke then _statusStroke.Color = routeStatusColor(tone) end
end

function TransitClient.onChanged(fn: (any) -> ()): () -> ()
	table.insert(_listeners, fn)
	return function()
		local i = table.find(_listeners, fn)
		if i then table.remove(_listeners, i) end
	end
end

-- The route currently being built / selected: its line draws brighter + thicker.
function TransitClient.setActiveRoute(id: number?)
	if _activeRouteId == id then return end
	_activeRouteId = id
	if _active then refreshVisibility() end
end

-- Turn route overlays/stop markers on/off. Ref-counted: "tools" and "overview"
-- show full route lines; "bulldoze" shows markers only so stops can be targeted.
function TransitClient.setMode(reason: string, on: boolean)
	if on then _modeRefs[reason] = true else _modeRefs[reason] = nil end
	local active = next(_modeRefs) ~= nil
	if active ~= _active then
		_active = active
		refreshVisibility()
	elseif _active then
		refreshVisibility()
	end
end

function TransitClient.setStopClickHandler(fn: ((number) -> ())?)
	_stopClickHandler = fn
end

function TransitClient.setRouteHint(stopId: number?, roadPos: Vector3?, primaryText: string?, actionText: string?, secondaryText: string?)
	_hintStopId = stopId
	_hintPos = roadPos
	_hintPrimary = primaryText
	_hintAction = actionText
	_hintSecondary = secondaryText
	if _active and _modeRefs.tools == true then
		rebuildRouteHint()
	else
		clearHint()
	end
end

function TransitClient.getActiveRoute(): number?
	return _activeRouteId
end

-- Find the stop nearest to a world position (for the route tool's click test fallback).
function TransitClient.nearestStopId(pos: Vector3, maxDist: number): number?
	local best, bestD = nil, maxDist
	for _, s in _snapshot.stops do
		local d = (s.pos - pos).Magnitude
		if d < bestD then bestD = d; best = s.id end
	end
	return best
end

function TransitClient.stopIdAtScreen(screenPos: Vector2, maxPixels: number?): number?
	local cam = Workspace.CurrentCamera
	if not cam then return nil end
	local limit = maxPixels or 72
	local best, bestD = nil, limit
	for _, s in _snapshot.stops do
		local vp, visible = cam:WorldToViewportPoint(s.pos + Vector3.new(0, 8.8, 0))
		if visible and vp.Z > 0 then
			local dx = math.abs(vp.X - screenPos.X)
			local dy = math.abs(vp.Y - screenPos.Y)
			if dx <= 78 and dy <= 62 then
				local d = math.sqrt(dx * dx + dy * dy)
				if d < bestD then bestD = d; best = s.id end
			end
		end
	end
	return best
end

function TransitClient.Start()
	if _started then return end
	_started = true
	_renderConn = RunService.RenderStepped:Connect(animateRouteArrows)
	Net.SyncTransit.OnClientEvent:Connect(function(snap: any)
		if typeof(snap) ~= "table" then return end
		_snapshot = snap
		if _active then pcall(refreshVisibility) end
		for _, fn in _listeners do task.spawn(fn, snap) end
	end)
end

return TransitClient
