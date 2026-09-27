--!strict
-- RoadGhostPreviewController
-- All transient visuals for the road placement tool: the ghost road model,
-- snap indicator rings/dots, angle + zone-boundary dot trails, guide / cross /
-- connector overlays and the floating measurement label. Owns its instances
-- and pools (and the rebuild-signature caching that throttles ghost rebuilds);
-- RoadPlacementController feeds it cursor and curve state and never touches
-- the parts directly.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local RoadConstants   = require(ReplicatedStorage.Road.RoadConstants)
local SnapUtil        = require(ReplicatedStorage.Road.SnapUtil)
local SnapConstants   = require(ReplicatedStorage.Road.SnapUtil.SnapConstants)
local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)
local BezierUtil      = require(ReplicatedStorage.Road.BezierUtil)
local RoadVerticalProfile = require(ReplicatedStorage.Road.RoadVerticalProfile)
-- "Which planted props does this pavement cover?" -- the same rule, off the same curve,
-- that NaturePlaceService.clearUnderPavement clears with when the road actually lands.
local RoadProximity = require(ReplicatedStorage.Road.RoadProximity)
-- "Which zoned buildings would this pavement take?" -- the same geometry, off the same
-- sampled corridor, that BuildingService.demolishUnderPavement clears with.
local PlacementFit = require(ReplicatedStorage.Shared.PlacementFit)
-- The white "this is about to go" highlight, borrowed from the bulldoze tool: the two are
-- never up at once, and white already means exactly that everywhere else in the game.
local DeleteHoverController = require(script.Parent:WaitForChild("DeleteHoverController"))
local UiScratch = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("UiScratch"))

local function commaInt(n: number): string
	local s = tostring(math.floor(math.abs(n) + 0.5))
	local out = ""
	while #s > 3 do out = "," .. s:sub(#s - 2) .. out; s = s:sub(1, #s - 3) end
	return s .. out
end

local RoadGhostPreviewController = {}

local ZONE_LOT_SIZE  = require(ReplicatedStorage.City.ZoneGrid).LOT_SIZE
local ZONE_LOT_GAP   = require(ReplicatedStorage.City.ZoneGrid).LOT_GAP
local ZONE_LOT_ROWS  = 5
local ZONE_DOT_SPACING = 6
local ZONE_DOT_SIZE    = 1.2
local ZONE_COLOR = Color3.fromRGB(100, 220, 100)

-- Min cursor travel (studs) before the ghost road model is rebuilt while dragging. Higher =
-- fewer expensive RoadRenderer.build/clear cycles per second.
local GHOST_REBUILD_MOVE = 5

local _inited = false
local _ghostFolder: Folder
local _ghostModel: Model? = nil
local _folderIndicators: Folder? = nil
local _folderAngle: Folder? = nil
local _folderZone: Folder? = nil
local _folderGuide: Folder? = nil
local _folderConnector: Folder? = nil
local _folderProtractor: Folder? = nil
local _indicatorDisc: BasePart? = nil
local _indicatorOuterDisc: BasePart? = nil
local _indicatorDot: BasePart? = nil
local _startRing: BasePart? = nil
local _connectRing: BasePart? = nil
local _raFootprint: BasePart? = nil
local _raIsland: BasePart? = nil
local _economyConn: RBXScriptConnection? = nil

local _angleDots: { BasePart } = {}
local _startDot: BasePart? = nil
local _zoneDots: { BasePart } = {}
local _angleDotCount = 0
local _zoneDotCount = 0
local _guideDots: { BasePart } = {}
local _guideDotCount = 0
local _guideMarkParts: { BasePart } = {}
local _guideMarkCount = 0
local _roadRingParts: { BasePart } = {}
local _roadRingCount = 0
local _lastRoadRingSig = ""
local _lastGuideSig: string = ""
local _connectorDots: { BasePart } = {}
local _connectorDotCount = 0
local _lastConnectorSig: string = ""
local _protractorParts: { BasePart } = {}
local _protractorCount = 0

-- World-anchored placement readout (CS:S-style): one small tag per measurement
-- scattered along the ghost road + a dotted arc at the bend. Replaces the old 2D
-- card that followed the cursor.
local TAG_TEXT = Color3.fromRGB(248, 250, 253)
local TAG_TEXT_BAD = Color3.fromRGB(255, 120, 120)
-- Client-side treasury mirror (SyncEconomy) so the cost tag can warn, in red,
-- before the server rejects. math.huge until the first sync = assume affordable.
local _treasury = math.huge
-- Direction a road would CONTINUE straight off the existing road at the gesture start
-- (Snapper.continuationDirAt, fed through UpdateParams). Present only when the start is
-- welded to a road, and it turns the start node into a readable corner -- which is what
-- gives a STRAIGHT road the same angle readout a bend gets. Module state rather than a
-- 6th argument through bendVertices/bmArcs/updateBendArc.
local _startDir: Vector3? = nil

type MeasureTag = { anchor: BasePart, gui: BillboardGui, label: TextLabel, frame: Frame }
local _tags: { MeasureTag } = {}
local _tagCount = 0
local _folderLabels: Folder? = nil
local _arcDots: { BasePart } = {}
local _arcCount = 0
local _outlineParts: { BasePart } = {}
local _outlineCount = 0
local _dashParts: { BasePart } = {}
local _dashCount = 0
local _folderOutline: Folder? = nil
local _lastLabelSig: string? = nil

local _lastGhostBuildPos: Vector3? = nil
local _lastGhostPhase: string? = nil
local _lastGhostMode: string? = nil
local _lastGhostRoadType: string? = nil
local _lastGhostSignature: string? = nil
local _lastGhostValidErr: string? = nil

export type UpdateParams = {
	p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
	cursor: Vector3,
	phase: string,
	mode: string,
	roadType: string,
	skipValidation: boolean,
	validate: (Vector3, Vector3, Vector3, Vector3) -> string?,
	start: Vector3?,
	headingInfo: { headingDeg: number?, relative: boolean?, rawLen: number?, snapLen: number?, lenSnapped: boolean }?,
	startDir: Vector3?,
	verticalMode: string?,
	elevation: number?,
	constantSlope: boolean?,
	angleSnapActive: boolean?,
	-- Parallel mode: perpendicular offset for a twin road outline drawn alongside the primary.
	parallelTwin: Vector3?,
}

-- ------------------------------------------------------------------- parts --

local function ensureIndicator()
	if _indicatorDisc then return end
	local ring = Instance.new("Part")
	ring.Name = "PlacementRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = SnapConstants.RETICLE_MATERIAL
	ring.Color = SnapConstants.INDICATOR_COLOR
	ring.Transparency = SnapConstants.INDICATOR_RING_TRANSPARENCY
	local d = SnapConstants.INDICATOR_RING_RADIUS * 2
	ring.Size = Vector3.new(0.1, d, d)
	ring.Parent = _folderIndicators or _ghostFolder
	_indicatorDisc = ring

	local outer = Instance.new("Part")
	outer.Name = "PlacementOuterRing"
	outer.Shape = Enum.PartType.Cylinder
	outer.Anchored = true
	outer.CanCollide = false
	outer.CanQuery = false
	outer.CanTouch = false
	outer.CastShadow = false
	outer.Material = SnapConstants.RETICLE_MATERIAL
	outer.Color = ZONE_COLOR
	outer.Transparency = SnapConstants.RETICLE_ZONE_TRANSPARENCY
	outer.Size = Vector3.new(0.08, d, d)
	outer.Parent = _folderIndicators or _ghostFolder
	_indicatorOuterDisc = outer

	local dot = Instance.new("Part")
	dot.Name = "PlacementDot"
	dot.Shape = Enum.PartType.Cylinder
	dot.Anchored = true
	dot.CanCollide = false
	dot.CanQuery = false
	dot.CanTouch = false
	dot.CastShadow = false
	dot.Material = SnapConstants.RETICLE_MATERIAL
	dot.Color = SnapConstants.INDICATOR_COLOR
	dot.Transparency = 0
	local dd = SnapConstants.INDICATOR_DOT_RADIUS * 2
	dot.Size = Vector3.new(0.15, dd, dd)
	dot.Parent = _folderIndicators or _ghostFolder
	_indicatorDot = dot

	local startRing = Instance.new("Part")
	startRing.Name = "RoadStartRing"
	startRing.Shape = Enum.PartType.Cylinder
	startRing.Anchored = true
	startRing.CanCollide = false
	startRing.CanQuery = false
	startRing.CanTouch = false
	startRing.CastShadow = false
	startRing.Material = SnapConstants.RETICLE_MATERIAL
	startRing.Color = Color3.new(1, 1, 1)
	startRing.Transparency = 0.1
	local sd = SnapConstants.INDICATOR_DOT_RADIUS * 2
	startRing.Size = Vector3.new(0.2, sd, sd)
	startRing.Parent = nil
	_startRing = startRing

	local connectRing = Instance.new("Part")
	connectRing.Name = "ConnectPreviewRing"
	connectRing.Shape = Enum.PartType.Cylinder
	connectRing.Anchored = true
	connectRing.CanCollide = false
	connectRing.CanQuery = false
	connectRing.CanTouch = false
	connectRing.CastShadow = false
	connectRing.Material = SnapConstants.RETICLE_MATERIAL
	connectRing.Color = SnapConstants.INDICATOR_SNAP_SEG_COLOR
	connectRing.Transparency = 0.45
	connectRing.Parent = nil
	_connectRing = connectRing
end

local function destroyIndicator()
	if _indicatorDisc then _indicatorDisc:Destroy() end
	if _indicatorOuterDisc then _indicatorOuterDisc:Destroy() end
	if _indicatorDot then _indicatorDot:Destroy() end
	if _startRing then _startRing:Destroy() end
	if _connectRing then _connectRing:Destroy() end
	_indicatorDisc = nil
	_indicatorOuterDisc = nil
	_indicatorDot = nil
	_startRing = nil
	_connectRing = nil
end

local function clearAngleOverlay()
	for _, p in _angleDots do p.Parent = nil end
	_angleDotCount = 0
	if _startDot then _startDot.Parent = nil end
	for _, p in _zoneDots do p.Parent = nil end
	_zoneDotCount = 0
end

local function clearSnapDecor()
	for i = 1, _guideDotCount do _guideDots[i].Parent = nil end
	_guideDotCount = 0
	for i = 1, _guideMarkCount do _guideMarkParts[i].Parent = nil end
	_guideMarkCount = 0
	for i = 1, _roadRingCount do _roadRingParts[i].Parent = nil end
	_roadRingCount = 0
	_lastRoadRingSig = ""
	_lastGuideSig = ""
	for i = 1, _connectorDotCount do _connectorDots[i].Parent = nil end
	_connectorDotCount = 0
	_lastConnectorSig = ""
	for i = 1, _protractorCount do _protractorParts[i].Parent = nil end
	_protractorCount = 0
	if _startRing then _startRing.Parent = nil end
end

local function makeDot(pos: Vector3, color: Color3, size: number): BasePart
	local p = Instance.new("Part")
	p.Name = "SnapDot"
	p.Shape = Enum.PartType.Ball
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = Vector3.new(size, size, size)
	p.CFrame = CFrame.new(pos)
	p.Parent = _folderAngle or _ghostFolder
	return p
end

local function pooledDot(pool: { BasePart }, idx: number, pos: Vector3, color: Color3, size: number, folder: Folder?): BasePart
	local p = pool[idx]
	if not p then
		p = Instance.new("Part")
		p.Name = "SnapDot"
		p.Shape = Enum.PartType.Ball
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.Neon
		pool[idx] = p
	end
	p.Color = color
	p.Size = Vector3.new(size, size, size)
	p.CFrame = CFrame.new(pos)
	p.Parent = folder or _ghostFolder
	return p
end

-- ----------------------------------------------------------- measure tags --
-- One small world-anchored tag per measurement, scattered along the ghost road
-- (height at the ends, length/bump in the middle, cost near the cursor) plus a
-- dotted arc at the bend. Anchored in 3D, not a screen-space card.

local function newTag(): MeasureTag
	local anchor = Instance.new("Part")
	anchor.Name = "MeasureTagAnchor"
	anchor.Size = Vector3.new(0.05, 0.05, 0.05)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false

	local gui = Instance.new("BillboardGui")
	gui.Name = "MeasureTag"
	gui.Size = UDim2.fromOffset(340, 40)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 1e6
	gui.Adornee = anchor
	gui.Parent = anchor

	-- Plain text, no panel: white with a dark outline so it stays readable over both the
	-- grass and the pale ghost road.
	local frame = Instance.new("Frame")
	frame.Name = "Holder"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.AutomaticSize = Enum.AutomaticSize.X
	frame.Size = UDim2.fromOffset(0, 24)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Parent = gui

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromOffset(0, 24)
	label.BackgroundTransparency = 1
	label.RichText = true
	label.FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold)
	label.TextSize = 16
	label.TextColor3 = TAG_TEXT
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(12, 15, 20)
	stroke.Transparency = 0.05
	stroke.Parent = label

	return { anchor = anchor, gui = gui, label = label, frame = frame }
end

-- Acquire the next pooled tag, position + style it. yOff lifts the tag (world studs)
-- above its anchor so several tags near one spot don't pile on top of each other.
local function placeTag(pos: Vector3, yOff: number, text: string, textColor: Color3)
	_tagCount += 1
	local tag = _tags[_tagCount]
	if not tag then
		tag = newTag()
		_tags[_tagCount] = tag
	end
	tag.anchor.CFrame = CFrame.new(pos)
	tag.gui.StudsOffsetWorldSpace = Vector3.new(0, yOff, 0)
	tag.label.Text = text
	tag.label.TextColor3 = textColor
	tag.anchor.Parent = _folderLabels or _ghostFolder
end

local function parkTagsBeyondCount()
	for i = _tagCount + 1, #_tags do
		_tags[i].anchor.Parent = nil
	end
end

local function hideTags()
	for _, t in _tags do t.anchor.Parent = nil end
	_tagCount = 0
	for i = 1, _arcCount do _arcDots[i].Parent = nil end
	_arcCount = 0
end

local function arcDot(idx: number, pos: Vector3)
	local p = _arcDots[idx]
	if not p then
		p = Instance.new("Part")
		p.Name = "BendArcDot"
		p.Shape = Enum.PartType.Ball
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.Neon
		p.Color = Color3.fromRGB(255, 255, 255)
		p.Size = Vector3.new(1.1, 1.1, 1.1)
		_arcDots[idx] = p
	end
	p.CFrame = CFrame.new(pos)
	p.Parent = _folderProtractor or _ghostFolder
end

local function flatUnit(v: Vector3): Vector3?
	local f = Vector3.new(v.X, 0, v.Z)
	if f.Magnitude < 1e-3 then return nil end
	return f.Unit
end

-- Where the two end tangents cross: the corner the curve is rounding. That is the bend
-- the player clicked on a simple curve, and the corner an auto-fitted arc rounds off.
local function tangentCorner(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3): Vector3?
	local a, b = flatUnit(p1 - p0), flatUnit(p3 - p2)
	if not a or not b then return nil end
	local cross = a.X * b.Z - a.Z * b.X
	if math.abs(cross) < 1e-4 then return nil end
	local d = p3 - p0
	local t = (d.X * b.Z - d.Z * b.X) / cross
	if t <= 0 then return nil end
	return p0 + a * t
end

-- The bend vertices the player actually placed, with the neighbour node on each side.
-- Curved = one bend (the clicked control point, recovered from the handle); AdvancedCurve
-- = the two clicked points; everything else has no readable corner.
local function bendVertices(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, mode: string, phase: string): { { v: Vector3, a: Vector3, b: Vector3 } }
	local out: { { v: Vector3, a: Vector3, b: Vector3 } } = {}

	-- The junction the gesture STARTS at. One leg runs back down the road already there
	-- (opposite its continuation direction), the other along the new road, so a straight
	-- road joining a grid reads 90deg. A dead-straight continuation lands near 180deg and
	-- the callers' straight cutoff drops it.
	if _startDir then
		local ahead = flatUnit(p1 - p0) or flatUnit(p3 - p0)
		local back = flatUnit(_startDir :: Vector3)
		if ahead and back then
			local leg = math.clamp((p3 - p0).Magnitude * 0.5, 10, 30)
			table.insert(out, { v = p0, a = p0 - back * leg, b = p0 + ahead * leg })
		end
	end

	if mode == "AdvancedCurve" and phase == "HasCurve2" then
		table.insert(out, { v = p1, a = p0, b = p2 })
		table.insert(out, { v = p2, a = p1, b = p3 })
	elseif mode == "AdvancedCurve" then
		table.insert(out, { v = p1, a = p0, b = p3 })
	elseif mode == "Curved" then
		table.insert(out, { v = p0 + (p1 - p0) * 1.5, a = p0, b = p3 })
	elseif mode == "Freeform" then
		local v = tangentCorner(p0, p1, p2, p3)
		if v then table.insert(out, { v = v, a = p0, b = p3 }) end
	end
	return out
end

-- A dotted arc (the angle wedge) + an "Angle" label drawn exactly at each bend the
-- player made. The two legs point to the neighbouring nodes, so the arc spans the real
-- corner angle. Near-straight corners are skipped.
local function updateBendArc(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, mode: string, phase: string, textColor: Color3)
	for i = 1, _arcCount do _arcDots[i].Parent = nil end
	_arcCount = 0

	for _, nd in bendVertices(p0, p1, p2, p3, mode, phase) do
		local v = nd.v
		local legA = flatUnit(nd.a - v)
		local legB = flatUnit(nd.b - v)
		if legA and legB then
			local interior = math.deg(math.acos(math.clamp(legA:Dot(legB), -1, 1)))
			if interior < 175 then
				local R = math.clamp(math.min((nd.a - v).Magnitude, (nd.b - v).Magnitude) * 0.4, 8, 18)
				local nY = v.Y + 0.5
				local a0 = math.atan2(legA.Z, legA.X)
				local a1 = math.atan2(legB.Z, legB.X)
				local d = a1 - a0
				while d > math.pi do d -= 2 * math.pi end
				while d < -math.pi do d += 2 * math.pi end
				local n = math.clamp(math.round(math.abs(math.deg(d)) / 9), 5, 22)
				for i = 0, n do
					local ang = a0 + d * (i / n)
					_arcCount += 1
					arcDot(_arcCount, Vector3.new(v.X + math.cos(ang) * R, nY, v.Z + math.sin(ang) * R))
				end
				placeTag(v, 4, string.format("Angle: %d\u{00B0}", math.round(interior)), textColor)
			end
		end
	end
end

-- Builds the small folder the world tags live in (the old 2D card is gone).
local function buildLabelGui()
	_folderLabels = Instance.new("Folder")
	_folderLabels.Name = "Labels"
	_folderLabels.Parent = _ghostFolder
end

local function updateLabelGui(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, isValid: boolean, params: UpdateParams)
	local dx = p3.X - p0.X
	local dz = p3.Z - p0.Z
	if math.sqrt(dx * dx + dz * dz) < 1 then
		hideTags()
		return
	end

	-- Tags are world-anchored, so nothing needs per-frame follow: rebuild only when the
	-- curve meaningfully changed (quantised signature).
	local mode = params.mode
	local phase = params.phase
	local sig = string.format("%d:%d:%d:%d:%d:%d:%s:%s:%d:%s:%s",
		math.round(p0.X), math.round(p0.Z), math.round(p3.X), math.round(p3.Z),
		math.round(p1.X + p2.X), math.round(p1.Z + p2.Z),
		mode, params.roadType, math.round(params.elevation or 0), tostring(isValid), tostring(validErr))
	if sig == _lastLabelSig then return end
	_lastLabelSig = sig

	_tagCount = 0
	local txt = if isValid then TAG_TEXT else TAG_TEXT_BAD
	local arcLen = BezierUtil.length(p0, p1, p2, p3, RoadConstants.SAMPLES_PER_SEGMENT)

	-- Height at both ends, prefixed with the structure this offset builds (CS2-style
	-- outcome preview): Fill embankment below the bridge threshold, Bridge above it,
	-- Cut for a shallow dig, Tunnel deeper. ponytail: shows the deck offset above
	-- ground (0.0 m on the ground in any map); wire per-point terrain Y here if hill
	-- grading must read true.
	local e = params.elevation or 0
	local tier = if e >= RoadConstants.ELEVATED_PILLAR_MIN_HEIGHT then "Bridge"
		elseif e > 0 then "Fill"
		elseif e <= -(RoadConstants.TUNNEL_DEPTH * 2) then "Tunnel" -- = TerrainGradeService.TUNNEL_COVER_DEPTH
		elseif e < 0 then "Cut"
		else "Ground"
	local heightStr = string.format("%s \u{00B7} Height: %.1f m", tier, e * RoadConstants.STUD_TO_METER)
	placeTag(p0, 3, heightStr, txt)
	placeTag(p3, 3, heightStr, txt)

	-- Length at the curve middle, with the snapped readout when it differs.
	local hi = params.headingInfo
	local lenStr = RoadConstants.formatMeters(arcLen)
	if hi and hi.lenSnapped and hi.rawLen then
		local rawStr = RoadConstants.formatMeters(hi.rawLen :: number)
		if rawStr ~= lenStr then
			lenStr = string.format('%s  <font color="rgb(190,205,225)">\u{2192}%s</font>', rawStr, lenStr)
		end
	end
	placeTag(BezierUtil.point(p0, p1, p2, p3, 0.5), 6, "Length: " .. lenStr, txt)

	-- Cost between the middle and the end, near where the player is dragging.
	local costSpec = RoadTypeCatalog.getOrDefault(params.roadType)
	local roadCost = math.ceil(arcLen * RoadConstants.STUD_TO_METER * (costSpec.costPerMeter or RoadConstants.ROAD_COST_PER_METER))
	placeTag(BezierUtil.point(p0, p1, p2, p3, 0.85), 8, "$" .. commaInt(roadCost), if roadCost > _treasury then TAG_TEXT_BAD else txt)

	-- Bump = steepest grade, only when the road actually climbs.
	local grade = RoadVerticalProfile.maxAbsGrade(p0, p1, p2, p3)
	if grade >= 0.005 then
		local pct = math.min(grade, 9.99) * 100
		-- Readout only: no grade is refused any more, so it never colours as an error.
		local gradeTxt = txt
		placeTag(BezierUtil.point(p0, p1, p2, p3, 0.32), 6, string.format("Bump: %.1f%%", pct), gradeTxt)
	end

	updateBendArc(p0, p1, p2, p3, mode, phase, txt)
	parkTagsBeyondCount()
end

local function hideLabelGui()
	hideTags()
end

-- ===================================================================== beams ==
-- Beam-based placement preview (CS:S blueprint look). The road is drawn as blue
-- milk-white edge guide lines + a faint flat fill (Beams, no solid parts), a bold white dashed
-- ALIGNMENT guide through the control nodes, node circles, single-beam angle arcs,
-- and world-anchored white-text labels. All beams/attachments live under _beamAnchor
-- (lifted BM_LIFT studs so it floats above terrain; attachment CFrames are relative). Replaces the old part ghost.
local BM_EDGE       = Color3.fromRGB(245, 241, 230)
local BM_EDGE_BAD   = Color3.fromRGB(240, 90, 90)
local BM_FILL       = Color3.fromRGB(235, 238, 242)
local BM_FILL_TRANS = 0.72
local BM_DASH       = Color3.fromRGB(246, 246, 242)
local BM_ARC        = Color3.fromRGB(240, 244, 250)
local BM_ICON       = Color3.fromRGB(96, 170, 245)
local BM_TEXT       = Color3.fromRGB(250, 251, 253)
local BM_TEXT_BAD   = Color3.fromRGB(255, 150, 150)
local BM_OUTLINE    = Color3.fromRGB(8, 12, 18)
-- ponytail: uniform float so the flat ribbon + labels clear the terrain skin (voxel
-- grass renders ~2 studs above the heightmap); raise if hill bulges still clip through.
local BM_LIFT       = 3.0
local BM_EDGE_W     = 1.1
local BM_DASH_W     = 3.0
local BM_DASH_LEN   = 18
local BM_DASH_GAP   = 15
local BM_ARC_W      = 1.6
local BM_STRAIGHT_MAX = 174  -- bends flatter than this read as straight: no angle, no mid circle
local BM_FONT       = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium)
local BM_UP         = Vector3.yAxis
local BM_TAU        = math.pi * 2

local _beamAnchor: BasePart? = nil
local _beamPool: { Beam } = {}
local _attPool: { Attachment } = {}
local _beamN = 0
local _attN = 0
local _beamHigh = 0
local _hasGhost = false

type BmTag = { att: Attachment, gui: BillboardGui, frame: Frame, pad: UIPadding, icon: TextLabel, label: TextLabel }
local _bmTags: { BmTag } = {}
local _bmTagN = 0
local _bmGlow: { BillboardGui } = {}
local _bmLabelSig: string? = nil

local function bmAtt(cf: CFrame): Attachment
	_attN += 1
	local a = _attPool[_attN]
	if not a then
		a = Instance.new("Attachment")
		a.Parent = _beamAnchor
		_attPool[_attN] = a
	end
	a.CFrame = cf
	return a
end

local function bmBeam(): Beam
	_beamN += 1
	if _beamN > _beamHigh then _beamHigh = _beamN end
	local b = _beamPool[_beamN]
	if not b then
		b = Instance.new("Beam")
		b.Parent = _beamAnchor
		_beamPool[_beamN] = b
	end
	b.Enabled = true
	return b
end

local function bmBegin()
	for i = 1, _beamHigh do _beamPool[i].Enabled = false end
	_beamN = 0
	_attN = 0
end

-- bmCurved removed: bmRoadBody now tiles the fill from flat segments (no S-curve pinch).

-- A straight ribbon lying flat on the ground (width along the horizontal normal, not
-- camera-facing). Used for the edge lines and the dashed alignment guide.
local function bmFlat(A: Vector3, B: Vector3, color: Color3, width: number, trans: number, emission: number)
	local d = B - A
	local len = d.Magnitude
	if len < 1e-3 then return end
	local x = d / len
	local b = bmBeam()
	b.Attachment0 = bmAtt(CFrame.fromMatrix(A, x, x:Cross(BM_UP)))
	b.Attachment1 = bmAtt(CFrame.fromMatrix(B, x, x:Cross(BM_UP)))
	b.FaceCamera = false
	b.CurveSize0 = 0
	b.CurveSize1 = 0
	b.Segments = 1
	b.Width0 = width
	b.Width1 = width
	b.Color = ColorSequence.new(color)
	b.Transparency = NumberSequence.new(trans)
	b.LightEmission = emission
	b.Texture = ""
end

-- One fill quad of the road surface. The width spans the full road along each end's offset
-- normal (nrm0 at A, nrm1 at B), so consecutive quads share a station's exact left/right edge
-- points and the inside tiles seamlessly -- no gaps, no overlaps.
local function bmFillSeg(A: Vector3, nrm0: Vector3, B: Vector3, nrm1: Vector3, width: number)
	if (B - A).Magnitude < 1e-3 then return end
	local b = bmBeam()
	b.Attachment0 = bmAtt(CFrame.fromMatrix(A, BM_UP:Cross(nrm0).Unit, nrm0))
	b.Attachment1 = bmAtt(CFrame.fromMatrix(B, BM_UP:Cross(nrm1).Unit, nrm1))
	b.FaceCamera = false
	b.CurveSize0 = 0
	b.CurveSize1 = 0
	b.Segments = 1
	b.Width0 = width
	b.Width1 = width
	b.Color = ColorSequence.new(BM_FILL)
	b.Transparency = NumberSequence.new(BM_FILL_TRANS)
	b.LightEmission = 0
	b.Texture = ""
end

-- A circular arc as tangent-joined cubic beams (<=90 deg each: smooth + gapless).
local function bmArcLine(center: Vector3, R: number, angStart: number, sweep: number, color: Color3, width: number, emission: number)
	local n = math.max(1, math.ceil(math.abs(sweep) / (math.pi / 2)))
	local seg = sweep / n
	local k = R * (4 / 3) * math.tan(math.abs(seg) / 4)
	local sgn = if seg >= 0 then 1 else -1
	local y = center.Y
	for i = 0, n - 1 do
		local a0 = angStart + seg * i
		local a1 = a0 + seg
		local P0 = Vector3.new(center.X + math.cos(a0) * R, y, center.Z + math.sin(a0) * R)
		local P3 = Vector3.new(center.X + math.cos(a1) * R, y, center.Z + math.sin(a1) * R)
		local T0 = Vector3.new(-math.sin(a0), 0, math.cos(a0)) * sgn
		local T3 = Vector3.new(-math.sin(a1), 0, math.cos(a1)) * sgn
		local b = bmBeam()
		b.Attachment0 = bmAtt(CFrame.fromMatrix(P0, T0, T0:Cross(BM_UP)))
		b.Attachment1 = bmAtt(CFrame.fromMatrix(P3, T3, T3:Cross(BM_UP)))
		b.FaceCamera = false
		b.CurveSize0 = k
		b.CurveSize1 = k
		b.Segments = 10
		b.Width0 = width
		b.Width1 = width
		b.Color = ColorSequence.new(color)
		b.Transparency = NumberSequence.new(0)
		b.LightEmission = emission
		b.Texture = ""
	end
end

-- Control nodes for the dashed guide, circles and per-leg lengths: start, end, and only the
-- bend vertices that form a real corner. Near-straight (~180-degree) bends are dropped so a
-- straight road reads as one clean segment: one length, no angle, no mid circle.
local function bmGuideNodes(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, mode: string, phase: string): { Vector3 }
	local out = { p0 }
	for _, nd in bendVertices(p0, p1, p2, p3, mode, phase) do
		local la = flatUnit(nd.a - nd.v)
		local lb = flatUnit(nd.b - nd.v)
		if la and lb and math.deg(math.acos(math.clamp(la:Dot(lb), -1, 1))) < BM_STRAIGHT_MAX then
			out[#out + 1] = nd.v
		end
	end
	out[#out + 1] = p3
	return out
end

local function bmRoadBody(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, width: number, isValid: boolean)
	local half = width * 0.5
	local edgeCol = if isValid then BM_EDGE else BM_EDGE_BAD
	-- Road body tiled from short flat steps sampled along the bezier: one full-width fill quad
	-- plus the two offset edge lines per step. Each fill quad is bounded by the station offset
	-- normals, so adjacent quads share exact edge points and the inside tiles seamlessly. A
	-- single wide beam pinches through an S-curve's inflection. Step count follows how much the
	-- road actually turns, so a straight road spends ~2 steps and only real curves cost beams.
	-- (Ceiling: turns tighter than the half-width still pinch the inner edge -- inherent.)
	local turn = 0
	local a1, b1 = flatUnit(p0 - p1), flatUnit(p2 - p1)
	if a1 and b1 then turn += math.pi - math.acos(math.clamp(a1:Dot(b1), -1, 1)) end
	local a2, b2 = flatUnit(p1 - p2), flatUnit(p3 - p2)
	if a2 and b2 then turn += math.pi - math.acos(math.clamp(a2:Dot(b2), -1, 1)) end
	local n = math.clamp(math.ceil(turn / math.rad(7)) + 1, 2, 32)
	local pc: Vector3? = nil
	local pn: Vector3? = nil
	local pl: Vector3? = nil
	local pr: Vector3? = nil
	for i = 0, n do
		local t = i / n
		local c = BezierUtil.point(p0, p1, p2, p3, t)
		local tg = flatUnit(BezierUtil.tangent(p0, p1, p2, p3, t)) or Vector3.new(1, 0, 0)
		local nrm = Vector3.new(-tg.Z, 0, tg.X)
		local l = c + nrm * half
		local r = c - nrm * half
		if pc and pn and pl and pr then
			bmFillSeg(pc, pn, c, nrm, width)
			bmFlat(pl, l, edgeCol, BM_EDGE_W, 0, 0.45)
			bmFlat(pr, r, edgeCol, BM_EDGE_W, 0, 0.45)
		end
		pc, pn, pl, pr = c, nrm, l, r
	end
end

local function bmDashes(nodes: { Vector3 })
	local period = BM_DASH_LEN + BM_DASH_GAP
	for i = 1, #nodes - 1 do
		local a = nodes[i]
		local b = nodes[i + 1]
		local seg = b - a
		local len = seg.Magnitude
		if len > 1e-3 then
			local dir = seg / len
			local pos = BM_DASH_GAP * 0.5
			while pos + BM_DASH_LEN <= len do
				bmFlat(a + dir * pos, a + dir * (pos + BM_DASH_LEN), BM_DASH, BM_DASH_W, 0, 0.5)
				pos += period
			end
		end
	end
end

local function bmGlowAt(pos: Vector3, idx: number)
	local g = _bmGlow[idx]
	if not g then
		local a = Instance.new("Attachment")
		a.Parent = _beamAnchor
		g = Instance.new("BillboardGui")
		g.Name = "NodeGlow"
		g.Size = UDim2.fromOffset(13, 13)
		g.AlwaysOnTop = true
		g.LightInfluence = 0
		g.Adornee = a
		g.Parent = a
		local fr = Instance.new("Frame")
		fr.Size = UDim2.fromScale(1, 1)
		fr.BackgroundColor3 = Color3.fromRGB(240, 247, 255)
		fr.BorderSizePixel = 0
		fr.Parent = g
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(1, 0)
		c.Parent = fr
		_bmGlow[idx] = g
	end
	(g.Adornee :: Attachment).CFrame = CFrame.new(pos)
	g.Enabled = true
end

local function bmCircles(nodes: { Vector3 }, width: number, isValid: boolean)
	local col = if isValid then BM_EDGE else BM_EDGE_BAD
	local half = width * 0.5
	local last = #nodes
	for i = 1, last do
		local isEnd = i == 1 or i == last
		bmArcLine(nodes[i], if isEnd then 9 else half, 0, BM_TAU, col, if isEnd then 1.3 else 1.2, 0.5)
	end
	bmGlowAt(nodes[1], 1)
	bmGlowAt(nodes[last], 2)
end

local function bmArcs(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, mode: string, phase: string, width: number, isValid: boolean)
	local half = width * 0.5
	local col = if isValid then BM_ARC else BM_EDGE_BAD
	for _, nd in bendVertices(p0, p1, p2, p3, mode, phase) do
		local la = flatUnit(nd.a - nd.v)
		local lb = flatUnit(nd.b - nd.v)
		if la and lb then
			local interior = math.acos(math.clamp(la:Dot(lb), -1, 1))
			local deg = math.deg(interior)
			if deg < BM_STRAIGHT_MAX then
				if math.round(deg) == 90 then
					-- exactly 90 degrees: a small square corner marker (straight lines), not a round arc
					local m = math.clamp(half, 3, 7)
					local pC = nd.v + (la + lb) * m
					bmFlat(nd.v + la * m, pC, col, BM_ARC_W, 0, 0.5)
					bmFlat(nd.v + lb * m, pC, col, BM_ARC_W, 0, 0.5)
				else
					-- other angles: a rounded arc sweeping from one leg to the other
					local outDir = flatUnit(-(la + lb)) or Vector3.new(-la.Z, 0, la.X)
					local baseAng = math.atan2(outDir.Z, outDir.X)
					bmArcLine(nd.v, half + 6, baseAng - interior / 2, interior, col, BM_ARC_W, 0.5)
				end
			end
		end
	end
end

local function bmNextTag(): BmTag
	_bmTagN += 1
	local existing = _bmTags[_bmTagN]
	if existing then return existing end
	local a = Instance.new("Attachment")
	a.Parent = _beamAnchor
	local gui = Instance.new("BillboardGui")
	gui.Name = "MeasureTag"
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 1e6
	gui.Size = UDim2.fromOffset(300, 34)
	gui.Adornee = a
	gui.Parent = a
	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.AutomaticSize = Enum.AutomaticSize.X
	frame.Size = UDim2.fromOffset(0, 26)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 7)
	corner.Parent = frame
	local lay = Instance.new("UIListLayout")
	lay.FillDirection = Enum.FillDirection.Horizontal
	lay.VerticalAlignment = Enum.VerticalAlignment.Center
	lay.Padding = UDim.new(0, 5)
	lay.Parent = frame
	local pad = Instance.new("UIPadding")
	pad.Parent = frame
	local icon = Instance.new("TextLabel")
	icon.LayoutOrder = 1
	icon.Size = UDim2.fromOffset(16, 26)
	icon.BackgroundTransparency = 1
	icon.FontFace = BM_FONT
	icon.TextSize = 14
	icon.TextColor3 = BM_ICON
	icon.Parent = frame
	local istroke = Instance.new("UIStroke")
	istroke.Color = BM_OUTLINE
	istroke.Thickness = 1.6
	istroke.Transparency = 0.05
	istroke.Parent = icon
	local label = Instance.new("TextLabel")
	label.LayoutOrder = 2
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromOffset(0, 26)
	label.BackgroundTransparency = 1
	label.FontFace = BM_FONT
	label.TextSize = 14
	label.TextColor3 = BM_TEXT
	label.Parent = frame
	local lstroke = Instance.new("UIStroke")
	lstroke.Color = BM_OUTLINE
	lstroke.Thickness = 1.8
	lstroke.Transparency = 0.05
	lstroke.Parent = label
	local tag: BmTag = { att = a, gui = gui, frame = frame, pad = pad, icon = icon, label = label }
	_bmTags[_bmTagN] = tag
	return tag
end

local function bmPlaceTag(pos: Vector3, yoff: number, glyph: string, text: string, textCol: Color3, big: boolean)
	local tag = bmNextTag()
	tag.att.CFrame = CFrame.new(pos)
	tag.gui.StudsOffsetWorldSpace = Vector3.new(0, yoff, 0)
	tag.icon.Text = glyph
	tag.label.Text = text
	tag.label.TextColor3 = textCol
	if big then
		tag.frame.BackgroundTransparency = 1
		tag.pad.PaddingLeft = UDim.new(0, 8)
		tag.pad.PaddingRight = UDim.new(0, 9)
	else
		tag.frame.BackgroundTransparency = 1
		tag.pad.PaddingLeft = UDim.new(0, 2)
		tag.pad.PaddingRight = UDim.new(0, 2)
	end
	tag.gui.Enabled = true
end

local function bmHideTags()
	for _, t in _bmTags do t.gui.Enabled = false end
	_bmTagN = 0
end

local function bmClear()
	for i = 1, _beamHigh do _beamPool[i].Enabled = false end
	_beamN = 0
	_attN = 0
	for _, g in _bmGlow do g.Enabled = false end
	bmHideTags()
	_bmLabelSig = nil
	_hasGhost = false
end

-- Shortest leg worth a length tag (studs). Below this the number rounds to 0 m anyway.
local BM_MIN_LEG = 4

local function bmUpdateLabels(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, isValid: boolean, params: UpdateParams, width: number, validErr: string?)
	local mode = params.mode
	local phase = params.phase
	local sig = string.format("%d:%d:%d:%d:%d:%d:%s:%s:%d:%s",
		math.round(p0.X), math.round(p0.Z), math.round(p3.X), math.round(p3.Z),
		math.round(p1.X + p2.X), math.round(p1.Z + p2.Z),
		mode, params.roadType, math.round(params.elevation or 0), tostring(isValid))
	if sig == _bmLabelSig then return end
	_bmLabelSig = sig

	_bmTagN = 0
	local txt = if isValid then BM_TEXT else BM_TEXT_BAD
	local STM = RoadConstants.STUD_TO_METER
	local nodes = bmGuideNodes(p0, p1, p2, p3, mode, phase)

	-- per-leg length along the guide (matches the straight dashed guide). Legs shorter than
	-- BM_MIN_LEG get no tag: two control nodes can sit on top of each other, and the
	-- "Length: 0 m" that produced landed stacked on the angle tag at the same corner.
	for i = 1, #nodes - 1 do
		local a = nodes[i]
		local b = nodes[i + 1]
		local len = (b - a).Magnitude
		if len < BM_MIN_LEG then continue end
		bmPlaceTag((a + b) * 0.5, 5, "\u{2194}", "Length: " .. RoadConstants.formatMeters(len), txt, false)
	end

	-- angle only at real bends (a straight road / the first placement gets none)
	for _, nd in bendVertices(p0, p1, p2, p3, mode, phase) do
		local la = flatUnit(nd.a - nd.v)
		local lb = flatUnit(nd.b - nd.v)
		if la and lb then
			local interior = math.deg(math.acos(math.clamp(la:Dot(lb), -1, 1)))
			if interior < BM_STRAIGHT_MAX then
				bmPlaceTag(nd.v, 12, "\u{2220}", string.format("Angle: %d\u{00B0}", math.round(interior)), txt, false)
			end
		end
	end

	-- endpoint direction kept for the cost tag placement (height readouts removed)
	local out3 = flatUnit(p3 - p0) or Vector3.zero

	-- ramp / grade at the curve mid
	local grade = RoadVerticalProfile.maxAbsGrade(p0, p1, p2, p3)
	local gcol = txt
	bmPlaceTag(BezierUtil.point(p0, p1, p2, p3, 0.5), -7, "\u{2197}", string.format("Ramp: %.1f%%", math.min(grade, 9.99) * 100), gcol, false)

	-- construction cost at the active endpoint (near the cursor)
	local arcLen = BezierUtil.length(p0, p1, p2, p3, RoadConstants.SAMPLES_PER_SEGMENT)
	local costSpec = RoadTypeCatalog.getOrDefault(params.roadType)
	local cost = math.ceil(arcLen * STM * (costSpec.costPerMeter or RoadConstants.ROAD_COST_PER_METER))
	bmPlaceTag(p3 + out3 * 20, 8, "\u{24C8}", "Construction Cost: " .. commaInt(cost), if cost > _treasury then TAG_TEXT_BAD else txt, true)

	-- Why the ghost is red. validate() already produced the reason -- without this the tool
	-- just silently refuses and the player has to guess which rule they hit.
	if validErr then
		bmPlaceTag(BezierUtil.point(p0, p1, p2, p3, 0.5), -20, "\u{26A0}", validErr, BM_TEXT_BAD, true)
	end

	for i = _bmTagN + 1, #_bmTags do _bmTags[i].gui.Enabled = false end
end

local function bmDraw(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, params: UpdateParams, isValid: boolean, width: number, twinOff: Vector3?)
	bmBegin()
	bmRoadBody(p0, p1, p2, p3, width, isValid)
	local nodes = bmGuideNodes(p0, p1, p2, p3, params.mode, params.phase)
	-- Dashed node-alignment guide only while shaping a curve (after the first curve
	-- click); never on straight roads or the initial start-to-cursor drag.
	if params.mode ~= "Straight" and (params.phase == "HasCurve" or params.phase == "HasCurve2") then
		bmDashes(nodes)
	end
	bmCircles(nodes, width, isValid)
	bmArcs(p0, p1, p2, p3, params.mode, params.phase, width, isValid)
	-- Parallel mode: the twin road's outline, offset perpendicular (same beam pass, no labels).
	if twinOff then
		local q0, q1, q2, q3 = p0 + twinOff, p1 + twinOff, p2 + twinOff, p3 + twinOff
		bmRoadBody(q0, q1, q2, q3, width, isValid)
		bmCircles(bmGuideNodes(q0, q1, q2, q3, params.mode, params.phase), width, isValid)
		bmArcs(q0, q1, q2, q3, params.mode, params.phase, width, isValid)
	end
	_hasGhost = true
end

-- ------------------------------------------------------------- road decor --
-- Crisp blue edge outline + bold white dashed centre line, drawn as opaque neon
-- parts. RoadRenderer's own markings inherit the ghost's transparency and read too
-- faint, so we draw these ourselves. Rebuilt with the ghost, parked by clearGhostModel.
local DECOR_DASH_LEN = 14
local DECOR_DASH_GAP = 10
local DECOR_WHITE = Color3.fromRGB(245, 245, 240)

local function decorPart(pool: { BasePart }, idx: number): BasePart
	local p = pool[idx]
	if not p then
		p = Instance.new("Part")
		p.Name = "RoadDecor"
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.Neon
		pool[idx] = p
	end
	p.Parent = _folderOutline or _ghostFolder
	return p
end

local function buildRoadDecor(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, isValid: boolean, halfW: number)
	local edgeColor = if isValid then Color3.fromRGB(64, 156, 255) else Color3.fromRGB(255, 90, 90)
	local total = BezierUtil.length(p0, p1, p2, p3, RoadConstants.SAMPLES_PER_SEGMENT)

	-- Edge outline: thin neon segments along each offset edge of the carriageway.
	local samples = math.clamp(math.round(total / 12), 8, 60)
	local prevL: Vector3? = nil
	local prevR: Vector3? = nil
	for i = 0, samples do
		local t = i / samples
		local c = BezierUtil.point(p0, p1, p2, p3, t)
		local tang = flatUnit(BezierUtil.tangent(p0, p1, p2, p3, t)) or Vector3.new(1, 0, 0)
		local nrm = Vector3.new(-tang.Z, 0, tang.X)
		local lft = c + nrm * halfW
		local rgt = c - nrm * halfW
		if prevL and prevR then
			for _, pair in { { prevL, lft }, { prevR, rgt } } do
				local a, b = pair[1], pair[2]
				local dir = b - a
				local len = dir.Magnitude
				if len > 1e-3 then
					_outlineCount += 1
					local seg = decorPart(_outlineParts, _outlineCount)
					seg.Color = edgeColor
					seg.Size = Vector3.new(len + 0.4, 0.2, 0.7)
					local ang = math.atan2(dir.Z, dir.X)
					seg.CFrame = CFrame.new((a.X + b.X) * 0.5, (a.Y + b.Y) * 0.5 + 0.45, (a.Z + b.Z) * 0.5) * CFrame.Angles(0, -ang, 0)
				end
			end
		end
		prevL, prevR = lft, rgt
	end

	-- Centre line: bold white dashes spaced by arc length (uniform-t is close enough here).
	local period = DECOR_DASH_LEN + DECOR_DASH_GAP
	local pos = DECOR_DASH_LEN * 0.5
	while pos < total do
		local t = math.clamp(pos / total, 0, 1)
		local c = BezierUtil.point(p0, p1, p2, p3, t)
		local tang = flatUnit(BezierUtil.tangent(p0, p1, p2, p3, t)) or Vector3.new(1, 0, 0)
		_dashCount += 1
		local dash = decorPart(_dashParts, _dashCount)
		dash.Color = DECOR_WHITE
		dash.Size = Vector3.new(DECOR_DASH_LEN, 0.25, 1.5)
		local ang = math.atan2(tang.Z, tang.X)
		dash.CFrame = CFrame.new(c.X, c.Y + 0.5, c.Z) * CFrame.Angles(0, -ang, 0)
		pos += period
	end
end

-- ---------------------------------------------------------------- overlays --

local function updateAngleOverlay(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, isValid: boolean, roadType: string)
	-- The translucent ghost road already shows the path, so we keep only a small start marker.
	-- The old centre-line + zone-boundary dot trails (hundreds of neon balls rebuilt every few
	-- studs of drag) were the main placement FPS sink and visual clutter -- removed.
	_angleDotCount = 0
	_zoneDotCount = 0
	for i = 1, #_angleDots do _angleDots[i].Parent = nil end
	for i = 1, #_zoneDots do _zoneDots[i].Parent = nil end

	local dx = p3.X - p0.X
	local dz = p3.Z - p0.Z
	if math.sqrt(dx * dx + dz * dz) < 1 then
		if _startDot then _startDot.Parent = nil end
		return
	end

	local dotCol = if isValid then Color3.fromRGB(245, 205, 110) else Color3.fromRGB(255, 100, 100)
	local Y = p0.Y + 0.3
	if not _startDot then
		_startDot = makeDot(Vector3.new(p0.X, Y, p0.Z), dotCol, 2.2)
		_startDot.Name = "StartDot"
	else
		_startDot.Color = dotCol
		_startDot.Size = Vector3.new(2.2, 2.2, 2.2)
		_startDot.CFrame = CFrame.new(p0.X, Y, p0.Z)
		_startDot.Parent = _folderAngle or _ghostFolder
	end
end

-- A ring on a guideline's 100 m mark. Flat, unlit and translucent: it has to read as a
-- target the cursor can click onto without washing out the ground behind it.
local function guideMarkPart(pool: { BasePart }, idx: number, pos: Vector3, color: Color3)
	local p = pool[idx]
	if not p then
		p = Instance.new("Part")
		p.Name = "GuideMark"
		p.Shape = Enum.PartType.Cylinder
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = SnapConstants.RETICLE_MATERIAL
		local d = SnapConstants.GUIDE_MARK_RADIUS * 2
		p.Size = Vector3.new(0.12, d, d)
		pool[idx] = p
	end
	p.Color = color
	p.CFrame = CFrame.new(pos.X, pos.Y + SnapConstants.GUIDE_MARK_LIFT, pos.Z) * CFrame.Angles(0, 0, math.pi / 2)
	p.Parent = _folderGuide or _ghostFolder
end

-- Snap indicator + guide/connector decor at the cursor. startPos is the
-- gesture's start point while a draw is active (shows the start ring).
function RoadGhostPreviewController.positionIndicator(cursor: Vector3, snapResult: any, startPos: Vector3?, roadType: string)
	ensureIndicator()

	if _startRing then
		if startPos then
			local s = startPos :: Vector3
			_startRing.CFrame = CFrame.new(s.X, s.Y + 0.4, s.Z) * CFrame.Angles(0, 0, math.pi / 2)
			_startRing.Parent = _folderIndicators or _ghostFolder
		else
			_startRing.Parent = nil
		end
	end
	local color  = if snapResult then snapResult.indicatorColor else SnapConstants.INDICATOR_COLOR
	local h      = if snapResult then snapResult.indicatorHeight else 0.12
	local scale  = if snapResult then snapResult.indicatorDotScale else 1
	local pulse  = 1 + math.sin(os.clock() * SnapConstants.RETICLE_PULSE_SPEED) * SnapConstants.RETICLE_PULSE_AMOUNT
	local flatCF = CFrame.Angles(0, 0, math.pi / 2)

	local surfY = cursor.Y
	local spec = RoadTypeCatalog.getOrDefault(roadType)
	local halfRoad = (spec.width or RoadConstants.ROAD_WIDTH) * 0.5
	-- Draw the road's true footprint (carriageway + sidewalk), not just the carriageway. The snap
	-- capture already reaches across the sidewalk, so a carriageway-only disc reads as "not touching"
	-- while a road still snaps -- the reticle now matches what the road actually occupies.
	local footHalf = halfRoad + (if spec.noSidewalk then 0 else RoadConstants.SIDEWALK_WIDTH)
	local centerDiameter = footHalf * 2
	if _indicatorDisc then
		_indicatorDisc.Color = color
		_indicatorDisc.Transparency = math.clamp(0.42 + (1 - pulse) * 2.5, 0.3, 0.6)
		_indicatorDisc.Size = Vector3.new(0.1, centerDiameter, centerDiameter)
		_indicatorDisc.CFrame = CFrame.new(cursor.X, surfY + h, cursor.Z) * flatCF
	end
	-- Zone-reach disc removed: a large bright neon fill that hurt fill-rate FPS and cluttered
	-- the view. Zoning reach is shown by the zone grid, not a placement overlay.
	if _indicatorOuterDisc then
		_indicatorOuterDisc.Parent = nil
	end
	if _indicatorDot then
		_indicatorDot.Color = color
		-- Sized off the road being drawn, not a fixed radius: an alley and a motorway used
		-- to get the same blob, which told the player nothing about what they were placing.
		local dd = math.max(SnapConstants.INDICATOR_DOT_MIN,
			centerDiameter * SnapConstants.INDICATOR_DOT_WIDTH_FRAC) * scale * pulse
		_indicatorDot.Size  = Vector3.new(0.15, dd, dd)
		_indicatorDot.CFrame = CFrame.new(cursor.X, surfY + h + 0.05, cursor.Z) * flatCF
	end

	-- THE live guideline(s). Normally one dotted ray with its rings; TWO when the cursor is
	-- sitting on a crossing, because a crossing is a place and a single line is only a
	-- direction. Rebuilt only when a ray or its ring window changes, so sliding along a
	-- guide costs nothing. Building frontage lines ride the same visuals with no rings.
	local guides = if snapResult and (snapResult.snapType == "guide" or snapResult.snapType == "building")
		then snapResult.guides else nil
	local guideSig = ""
	if guides then
		for _, g in guides do
			-- The first ring's POSITION, not the ring count: the window slides along the ray
			-- as the cursor advances while the count stays four, and a count-only signature
			-- would leave the rings parked where they were built.
			local m1 = if g.marks then g.marks[1] else nil
			guideSig ..= string.format("|%d:%d:%d:%d:%d:%d",
				math.round(g.anchor.X), math.round(g.anchor.Z),
				math.round(g.dir.X * 100), math.round(g.dir.Z * 100),
				if m1 then math.round(m1.X) else 0, if m1 then math.round(m1.Z) else 0)
		end
	end
	if guideSig ~= _lastGuideSig then
		_lastGuideSig = guideSig
		for i = 1, _guideDotCount do _guideDots[i].Parent = nil end
		_guideDotCount = 0
		for i = 1, _guideMarkCount do _guideMarkParts[i].Parent = nil end
		_guideMarkCount = 0
		if guides then
			local step = SnapConstants.GUIDE_DOT_SPACING
			local size = SnapConstants.GUIDE_DOT_SIZE
			local col  = SnapConstants.INDICATOR_SNAP_GUIDE_COLOR
			for _, g in guides do
				local a, d = g.anchor, g.dir
				local t = 0
				while t <= SnapConstants.GUIDE_LENGTH do
					_guideDotCount += 1
					pooledDot(_guideDots, _guideDotCount,
						Vector3.new(a.X + d.X * t, a.Y + 0.28, a.Z + d.Z * t),
						col, size, _folderGuide)
					t += step
				end
				if g.marks then
					for _, m in g.marks do
						_guideMarkCount += 1
						guideMarkPart(_guideMarkParts, _guideMarkCount, m, col)
					end
				end
			end
		end
	end
	-- Rings on the ROAD itself, at its own nodes: the 100 m grid the guides hang off, visible
	-- before any guide is in use. SnapUtil returns nothing while the cursor is moving fast,
	-- which is what takes them away again.
	local nodes = SnapUtil.nodeRings(cursor)
	-- Order-INDEPENDENT signature. The node list comes out of a spatial grid, so its order
	-- shifts as the cursor moves even when the same points are in it; keying off the first and
	-- last entries rebuilt the pool constantly, which is a blink every few frames.
	local hx, hz = 0, 0
	for _, p in nodes do
		hx += math.round(p.X)
		hz += math.round(p.Z)
	end
	local ringSig = string.format("%d:%d:%d", #nodes, hx, hz)
	if ringSig ~= _lastRoadRingSig then
		_lastRoadRingSig = ringSig
		for i = 1, _roadRingCount do _roadRingParts[i].Parent = nil end
		_roadRingCount = 0
		for _, p in nodes do
			_roadRingCount += 1
			guideMarkPart(_roadRingParts, _roadRingCount, p, SnapConstants.INDICATOR_SNAP_GUIDE_COLOR)
		end
	end

	-- Every ring fades on TWO things, per frame rather than on a rebuild signature: distance
	-- from the cursor (so the near one reads as the target instead of all of them shouting
	-- equally) and SnapUtil.ringStrength, which tweens them to invisible as the cursor speeds
	-- up rather than popping them off at a threshold. That is the RING speed limit, well above
	-- the pull's: you can see the snap points while moving fast and only get pulled onto one
	-- once you slow down to aim.
	local strength = SnapUtil.ringStrength()
	local function fadeRings(pool: { BasePart }, count: number)
		for i = 1, count do
			local p = pool[i]
			local mx, mz = p.Position.X - cursor.X, p.Position.Z - cursor.Z
			local f = math.clamp(math.sqrt(mx * mx + mz * mz) / SnapConstants.GUIDE_MARK_FADE, 0, 1)
			local base = SnapConstants.GUIDE_MARK_ALPHA_NEAR
				+ f * (SnapConstants.GUIDE_MARK_ALPHA_FAR - SnapConstants.GUIDE_MARK_ALPHA_NEAR)
			p.Transparency = 1 - strength * (1 - base)
		end
	end
	fadeRings(_guideMarkParts, _guideMarkCount)
	fadeRings(_roadRingParts, _roadRingCount)

	local connSig = ""
	if snapResult and snapResult.snapType == "center" and snapResult.hostFoot then
		local a = snapResult.hostFoot :: Vector3
		local b = snapResult.position
		connSig = string.format("%d:%d:%d:%d", math.round(a.X), math.round(a.Z), math.round(b.X), math.round(b.Z))
	end
	if connSig ~= _lastConnectorSig then
		_lastConnectorSig = connSig

		for i = 1, _connectorDotCount do _connectorDots[i].Parent = nil end
		_connectorDotCount = 0
		if connSig ~= "" and snapResult then
			local a = snapResult.hostFoot :: Vector3
			local b = snapResult.position
			local dxv, dzv = b.X - a.X, b.Z - a.Z
			local span = math.sqrt(dxv * dxv + dzv * dzv)
			local steps = math.max(1, math.floor(span / 2))
			for s = 0, steps do
				local fr = s / steps
				_connectorDotCount += 1
				pooledDot(_connectorDots, _connectorDotCount, Vector3.new(a.X + dxv * fr, b.Y + 0.3, a.Z + dzv * fr), Color3.new(1, 1, 1), 0.55, _folderConnector)
			end
		end
	end

	if _connectRing then
		if snapResult and snapResult.hostFoot and snapResult.snapType == "center" then
			local hf = snapResult.hostFoot :: Vector3
			local d = spec.width
			_connectRing.Color = snapResult.indicatorColor
			_connectRing.Size = Vector3.new(0.12, d, d)
			_connectRing.CFrame = CFrame.new(hf.X, hf.Y + 0.1, hf.Z) * CFrame.Angles(0, 0, math.pi / 2)
			_connectRing.Parent = _folderIndicators or _ghostFolder
		else
			_connectRing.Parent = nil
		end
	end
end

-- ------------------------------------------------------------------- ghost --

local function clearGhostModel()
	if _ghostModel then
		_ghostModel:Destroy()
		_ghostModel = nil
	end
	bmClear()
end

-- ----------------------------------------------------- what the road will take --
-- A tree or a zoned building standing where the new road goes is DOOMED: it lights up
-- white while the ghost is up and it is gone the moment the road lands. Both ends ask the
-- same two modules off the same corridor -- RoadProximity for the props, PlacementFit for
-- the buildings -- so what lights up is exactly what disappears.
local _doomedSig = ""

local function clearDoomed()
	if _doomedSig == "" then return end
	_doomedSig = ""
	DeleteHoverController.ClearBuildingSelection()
end

local function cityNature(): Instance?
	local city = Workspace:FindFirstChild("_City")
	return city and city:FindFirstChild("Nature")
end

-- `sig` throttles the O(props + buildings) sweep to an actual change of shape, the way the
-- ghost model's own rebuild is throttled: this runs from a live preview, not from a click.
local function showDoomed(sig: string, find: () -> { Model })
	if sig == _doomedSig then return end
	_doomedSig = sig
	DeleteHoverController.ShowBuildingSelection(find(), "Bulldoze")
end

-- The props the carriageway covers, plus the zoned buildings the wider clearance corridor
-- covers. Two reaches on purpose, and they are the two RoadService hands the server:
-- a tree goes when its own footprint touches the ASPHALT, a house goes when the paved
-- corridor (sidewalks + margin) covers its SEAT, or the bare asphalt clips its wall.
local function doomedAlong(segments: { any }, pts: { Vector3 }, halfWidth: number): { Model }
	local out: { Model } = {}
	local nature = cityNature()
	if nature then
		for _, mdl in RoadProximity.propsOnRoads(nature, segments) do out[#out + 1] = mdl end
	end
	local clearRadius = halfWidth + RoadConstants.SIDEWALK_WIDTH + RoadConstants.BUILDING_CLEAR_MARGIN
	for _, mdl in PlacementFit.zonedBuildingsUnderPavement(pts, clearRadius, halfWidth) do
		out[#out + 1] = mdl
	end
	return out
end

local function ghostSignature(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, isValid: boolean, roadType: string): string
	local function q(v: number): number
		return math.round(v * 10)
	end
	return table.concat({
		tostring(q(p0.X)), tostring(q(p0.Y)), tostring(q(p0.Z)),
		tostring(q(p1.X)), tostring(q(p1.Y)), tostring(q(p1.Z)),
		tostring(q(p2.X)), tostring(q(p2.Y)), tostring(q(p2.Z)),
		tostring(q(p3.X)), tostring(q(p3.Y)), tostring(q(p3.Z)),
		if isValid then "1" else "0",
		roadType,
	}, "|")
end

-- Footprint preview for the roundabout tool: a translucent carriageway disc
-- (green valid / red invalid) with the island disc inside it.
function RoadGhostPreviewController.showRoundabout(center: Vector3, radius: number, valid: boolean, roadType: string?)
	local spec = RoadTypeCatalog.getOrDefault(roadType or "Roundabout")
	local outerD = (radius + spec.width * 0.5) * 2
	local innerR = math.max(2.5, radius - spec.width * 0.5 - RoadConstants.SIDEWALK_WIDTH - (RoadConstants.ROUNDABOUT_ISLAND_INSET or 1.5))
	local col = if valid then RoadConstants.GHOST_COLOR_VALID else RoadConstants.GHOST_COLOR_INVALID

	if not _raFootprint then
		local p = Instance.new("Part")
		p.Name = "RoundaboutGhost"
		p.Shape = Enum.PartType.Cylinder
		p.Anchored = true; p.CanCollide = false; p.CanQuery = false; p.CanTouch = false; p.CastShadow = false
		p.Material = Enum.Material.Neon
		p.Transparency = 0.62
		_raFootprint = p
	end
	if not _raIsland then
		local p = Instance.new("Part")
		p.Name = "RoundaboutGhostIsland"
		p.Shape = Enum.PartType.Cylinder
		p.Anchored = true; p.CanCollide = false; p.CanQuery = false; p.CanTouch = false; p.CastShadow = false
		p.Material = Enum.Material.Neon
		p.Color = ZONE_COLOR
		p.Transparency = 0.5
		_raIsland = p
	end
	local f = _raFootprint :: BasePart
	f.Color = col
	f.Size = Vector3.new(0.2, outerD, outerD)
	f.CFrame = CFrame.new(center.X, center.Y + 0.15, center.Z) * CFrame.Angles(0, 0, math.pi / 2)
	f.Parent = _folderIndicators or _ghostFolder
	local isl = _raIsland :: BasePart
	isl.Size = Vector3.new(0.25, innerR * 2, innerR * 2)
	isl.CFrame = CFrame.new(center.X, center.Y + 0.2, center.Z) * CFrame.Angles(0, 0, math.pi / 2)
	isl.Parent = _folderIndicators or _ghostFolder

	-- The ring's pavement edge -- the reach RoadService hands BOTH clearances for a
	-- roundabout, whose footprint is a disc rather than a curve.
	local outer = radius + spec.width * 0.5 + RoadConstants.SIDEWALK_WIDTH
	if valid then
		showDoomed(
			("ra|%d|%d|%d|%d"):format(math.round(center.X), math.round(center.Y), math.round(center.Z), math.round(outer)),
			function()
				local out: { Model } = {}
				local nature = cityNature()
				if nature then
					for _, mdl in RoadProximity.propsInDisc(nature, center, outer) do out[#out + 1] = mdl end
				end
				for _, mdl in PlacementFit.zonedBuildingsUnderPavement(
					{ center }, outer + RoadConstants.BUILDING_CLEAR_MARGIN, outer) do
					out[#out + 1] = mdl
				end
				return out
			end
		)
	else
		clearDoomed()
	end
end

function RoadGhostPreviewController.hideRoundabout()
	if _raFootprint then _raFootprint.Parent = nil end
	if _raIsland then _raIsland.Parent = nil end
	clearDoomed()
end

-- Park the cursor/snap indicator parts (without destroying them). The roundabout
-- tool uses its own footprint preview and wants the road snap rings out of the way.
-- Takes the guide dots and rings with it: they are drawn BY positionIndicator, so any path
-- that stops calling that has to drop them too or they are left stranded on the map.
function RoadGhostPreviewController.hideIndicator()
	clearSnapDecor()
	if _indicatorDisc then _indicatorDisc.Parent = nil end
	if _indicatorOuterDisc then _indicatorOuterDisc.Parent = nil end
	if _indicatorDot then _indicatorDot.Parent = nil end
	if _connectRing then _connectRing.Parent = nil end
	if _startRing then _startRing.Parent = nil end
end

-- Reset the rebuild caches and drop the ghost model (gesture cancelled, mode
-- changed, elevation changed...).
function RoadGhostPreviewController.clear()
	RoadGhostPreviewController.hideRoundabout()
	-- Guide dots and rings go too: clear() is what a cancelled gesture, a mode change and
	-- tool shutdown all call, and every one of them used to leave the last guide on the map.
	clearSnapDecor()
	clearGhostModel()
	_lastGhostBuildPos = nil
	_lastGhostPhase = nil
	_lastGhostMode = nil
	_lastGhostRoadType = nil
	_lastGhostSignature = nil
	_lastGhostValidErr = nil
end

-- Curve visuals only (ghost + angle dots + label); the cursor indicator stays.
-- Used while the tool is enabled but no draw gesture is active.
function RoadGhostPreviewController.clearCurveVisuals()
	clearGhostModel()
	clearAngleOverlay()
	hideLabelGui()
	_lastLabelSig = nil
	for i = 1, _protractorCount do _protractorParts[i].Parent = nil end
	_protractorCount = 0
end

-- Park every normal road-placement visual while edit tools draw their own target UI.
function RoadGhostPreviewController.hidePlacementVisuals()
	RoadGhostPreviewController.hideRoundabout()
	RoadGhostPreviewController.hideIndicator()
	clearDoomed()
	clearGhostModel()
	clearAngleOverlay()
	clearSnapDecor()
	hideLabelGui()
end

-- Everything off (tool disabled).
function RoadGhostPreviewController.hideAll()
	RoadGhostPreviewController.hideRoundabout()
	clearDoomed()
	clearGhostModel()
	destroyIndicator()
	clearAngleOverlay()
	clearSnapDecor()
	hideLabelGui()
end

-- Per-frame preview for an active draw gesture. Validation runs only when the
-- ghost actually needs a rebuild (signature/state change + moved enough).
function RoadGhostPreviewController.update(params: UpdateParams)
	local p0, p1, p2, p3 = params.p0, params.p1, params.p2, params.p3
	_startDir = params.startDir
	local previewSig = ghostSignature(p0, p1, p2, p3, true, params.roadType)
	if params.parallelTwin then
		local t = params.parallelTwin
		previewSig = previewSig .. "|T" .. tostring(math.round(t.X)) .. "," .. tostring(math.round(t.Z))
	end
	local movedEnough = true
	if _lastGhostBuildPos then
		movedEnough = (params.cursor - _lastGhostBuildPos).Magnitude >= GHOST_REBUILD_MOVE
	end
	local stateChanged = not _hasGhost
		or _lastGhostPhase ~= params.phase
		or _lastGhostMode ~= params.mode
		or _lastGhostRoadType ~= params.roadType
	local needsRebuild = stateChanged
		or (movedEnough and _lastGhostSignature ~= previewSig)

	local validErr = _lastGhostValidErr
	if needsRebuild then
		validErr = if params.skipValidation then nil else params.validate(p0, p1, p2, p3)
		_lastGhostValidErr = validErr
	elseif params.skipValidation then
		validErr = nil
	end
	local isValid = not validErr

	local spec = RoadTypeCatalog.getOrDefault(params.roadType)
	-- Unaffordable reads the same as invalid: the WHOLE preview tints red, not just
	-- the cost tag (the server would reject the spend anyway).
	if isValid then
		local arcLen = BezierUtil.length(p0, p1, p2, p3, RoadConstants.SAMPLES_PER_SEGMENT)
		local cost = math.ceil(arcLen * RoadConstants.STUD_TO_METER * (spec.costPerMeter or RoadConstants.ROAD_COST_PER_METER))
		if cost > _treasury then isValid = false end
	end
	bmUpdateLabels(p0, p1, p2, p3, isValid, params, spec.width, validErr)

	if not needsRebuild then
		return
	end

	_lastGhostBuildPos = params.cursor
	_lastGhostPhase = params.phase
	_lastGhostMode = params.mode
	_lastGhostRoadType = params.roadType
	_lastGhostSignature = previewSig

	-- Preview the FULL footprint (carriageway + both sidewalks), not just the carriageway,
	-- otherwise the placed road is wider than the ghost and two parallel roads look further
	-- apart than they end up. Matches the real placed extent and the sidewalk-edge gap.
	local ghostWidth = spec.width + (if spec.noSidewalk then 0 else 2 * RoadConstants.SIDEWALK_WIDTH)
	bmDraw(p0, p1, p2, p3, params, isValid, ghostWidth, params.parallelTwin)

	-- Only the CARRIAGEWAY takes a prop with it (propsOnRoads measures to spec.width/2),
	-- which is the same reach that refuses planting one there. The sidewalk corridor the
	-- BUILDING clearance sweeps is wider on purpose and does not apply to a tree.
	-- Nothing is doomed by a road that cannot be placed, so an invalid ghost drops the
	-- highlight rather than promising a demolition that is not going to happen.
	if isValid then
		showDoomed(previewSig, function()
			return doomedAlong(
				{ { p0 = p0, p1 = p1, p2 = p2, p3 = p3, roadType = params.roadType } },
				RoadProximity.samplePavement(p0, p1, p2, p3),
				spec.width * 0.5)
		end)
	else
		clearDoomed()
	end
end

-- ---------------------------------------------------------------- lifecycle --

function RoadGhostPreviewController.getFolder(): Folder
	return _ghostFolder
end

function RoadGhostPreviewController.Init()
	if _inited then return end
	_inited = true

	local Net = require(game:GetService("ReplicatedStorage"):WaitForChild("Networker"))
	_economyConn = Net.SyncEconomy.OnClientEvent:Connect(function(p: any)
		if typeof(p) == "table" and typeof(p.money) == "number" then _treasury = p.money end
	end)

	_ghostFolder = Instance.new("Folder")
	_ghostFolder.Name = "RoadGhost"
	_ghostFolder.Parent = UiScratch.root()

	local function mkSub(name: string): Folder
		local f = Instance.new("Folder")
		f.Name = name
		f.Parent = _ghostFolder
		return f
	end
	_folderIndicators = mkSub("Indicators")
	_folderAngle      = mkSub("AngleLine")
	_folderZone       = mkSub("ZoneBoundary")
	_folderGuide      = mkSub("GuideLine")
	_folderConnector  = mkSub("SnapConnector")
	_folderProtractor = mkSub("Protractor")

	local anchor = Instance.new("Part")
	anchor.Name = "BeamAnchor"
	anchor.Size = Vector3.new(0.05, 0.05, 0.05)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.CFrame = CFrame.new(0, BM_LIFT, 0)
	anchor.Parent = _ghostFolder
	_beamAnchor = anchor
	table.clear(_beamPool)
	table.clear(_attPool)
	table.clear(_bmTags)
	table.clear(_bmGlow)
	_beamN = 0
	_attN = 0
	_beamHigh = 0
	_bmTagN = 0
	_hasGhost = false
	_bmLabelSig = nil
end

function RoadGhostPreviewController.Cleanup()
	RoadGhostPreviewController.clear()
	destroyIndicator()
	-- Init connects again, and these two live under _ghostFolder, destroyed below: a kept
	-- reference would be a locked-Parent error the next time a roundabout is previewed.
	if _economyConn then _economyConn:Disconnect(); _economyConn = nil end
	if _raFootprint then _raFootprint:Destroy(); _raFootprint = nil end
	if _raIsland then _raIsland:Destroy(); _raIsland = nil end
	for _, p in _angleDots do p:Destroy() end
	table.clear(_angleDots)
	_angleDotCount = 0
	if _startDot then _startDot:Destroy(); _startDot = nil end
	for _, p in _zoneDots do p:Destroy() end
	table.clear(_zoneDots)
	_zoneDotCount = 0
	for _, p in _guideDots do p:Destroy() end
	table.clear(_guideDots)
	_guideDotCount = 0
	for _, p in _guideMarkParts do p:Destroy() end
	table.clear(_guideMarkParts)
	_guideMarkCount = 0
	for _, p in _roadRingParts do p:Destroy() end
	table.clear(_roadRingParts)
	_roadRingCount = 0
	_lastRoadRingSig = ""
	for _, p in _connectorDots do p:Destroy() end
	table.clear(_connectorDots)
	_connectorDotCount = 0
	for _, p in _protractorParts do p:Destroy() end
	table.clear(_protractorParts)
	_protractorCount = 0
	_lastGuideSig = ""
	_lastConnectorSig = ""
	if _ghostFolder then
		_ghostFolder:Destroy()
		_ghostFolder = nil :: any
	end
	_folderIndicators = nil
	_folderAngle = nil
	_folderZone = nil
	_folderGuide = nil
	_folderConnector = nil
	_folderProtractor = nil
	for _, t in _tags do t.anchor:Destroy() end
	table.clear(_tags)
	_tagCount = 0
	for _, p in _arcDots do p:Destroy() end
	table.clear(_arcDots)
	_arcCount = 0
	for _, p in _outlineParts do p:Destroy() end
	table.clear(_outlineParts)
	_outlineCount = 0
	for _, p in _dashParts do p:Destroy() end
	table.clear(_dashParts)
	_dashCount = 0
	_folderLabels = nil
	_folderOutline = nil
	_inited = false
end

return RoadGhostPreviewController
