--!strict
-- Move tool (CS2 "Move It" style) -- select, drag and reshape the city.
-- Roads: click a segment to select it; the two END-NODE handles plus the two
-- CURVE CONTROL points (dotted lines) appear. Drag a node handle to relocate the
-- junction (every attached segment follows), drag a control point to reshape the
-- curve: NORMAL mode bends symmetrically through the cursor (both approach
-- angles change), MANIPULATION mode (Alt, or the dock toggle) moves that ONE
-- control point alone so a single node angle can be tuned. Drag the segment body
-- to slide the whole segment rigidly. Drag on empty ground for a marquee
-- multi-select of nodes (+ nature props); the set moves as one group commit and
-- Q / E rotates it about its centre while dragging. Objects: service buildings
-- (schools, emergency, utilities) and nature props drag with a ghost clone.
-- While dragging, the live pieces DIM (LocalTransparencyModifier) so the ghost
-- preview reads on top. Dock filters gate what the tool can hover / grab.
-- The preview runs the SAME shared math the server commits with
-- (RoadMoveGeometry); only grab ids + drag targets cross the wire.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Snapper = require(script.Parent.RoadPlacementSnapper)
local Theme = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("Theme"))
local HudScale = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("HudScale"))
local Icons = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("Icons"))
local Glass = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("Kit"):WaitForChild("Glass"))
local IconButton = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("Kit"):WaitForChild("IconButton"))
local BezierUtil = require(ReplicatedStorage.Road.BezierUtil)
local RoadMoveGeometry = require(ReplicatedStorage.Road.RoadMoveGeometry)
local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local NatureCatalog = require(ReplicatedStorage.Nature.NatureCatalog)
local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))
local CursorRay = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("CursorRay"))
local UiScratch = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("UiScratch"))
-- EditorGizmos is NOT the move interaction here -- a selected prop gets no handles; you
-- drag the prop itself. It is still read for the shared snap steps, so "1 stud" on the
-- resize button means what it means everywhere else. NatureGizmo supplies the focus dim
-- (and, for the Nature tab's Precise mode only, the handles).
local EditorGizmos = require(script.Parent:WaitForChild("EditorGizmos"))
local NatureGizmo = require(script.Parent:WaitForChild("NatureGizmo"))

local RoadMoveController = {}

-- Node grab beats a segment grab within this. In SCREEN pixels, not a fixed 9 studs: a
-- stud radius is an enormous target with the camera close in and an unhittable one zoomed
-- out. The fixed value is still right for RE-selection after a round-trip (a known world
-- position, not a cursor guess), so both live here.
local NODE_PICK_PX = 18
local NODE_PICK_MIN, NODE_PICK_MAX = 2, 30
local NODE_RESELECT_R = 9    -- studs: re-finding a remembered node, not a cursor pick
local NATURE_PICK_R = 7      -- studs: click-pick radius around a nature prop's pivot (trunk base)
local HANDLE_PICK_PX = 18    -- px: screen-space pick radius for selection handles
local DRAG_START_PX = 6      -- px of mouse travel before a press becomes a drag
local MARQUEE_MIN_PX = 10    -- px before an empty-ground press becomes a marquee
local LIFT = 2.5             -- ghost floats above deck + terrain skin so it always reads
local MIN_DRAG = 2           -- studs of travel before a release commits
local DIM = 0.75             -- LocalTransparencyModifier applied to moving pieces
local ROT_STEP = math.rad(15)
local MAX_GROUP = 128        -- mirrors server MAX_GROUP_MOVES
local MAX_NATURE_BATCH = 64  -- mirrors server MAX_PER_CALL

local COLOR_HOVER = Color3.fromRGB(160, 230, 130) -- Move It green, brighter on hover
local COLOR_SEL = Color3.fromRGB(116, 200, 90)    -- Move It green: selection accents
local COLOR_MANIP = Color3.fromRGB(190, 140, 255) -- manipulation mode tint
local COLOR_BAD = Color3.fromRGB(236, 98, 100)
-- Drag ghost: the white placement-preview palette (matches RoadGhostPreviewController).
local GHOST_FILL = Color3.fromRGB(235, 238, 242)
local GHOST_EDGE = Color3.fromRGB(245, 241, 230)

-- MUST mirror RoadService.chargeMoveCost: per-segment build cost scaled by how far
-- the curve moved (largest control-point displacement vs MOVE_COST_REF_DIST).
local MOVE_COST_RATE = 0.25
local MOVE_COST_REF_DIST = 40
local MOVE_COST_MIN_FRAC = 0.1

local function moveCostOf(old: { p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3 }, n0: Vector3, n1: Vector3, n2: Vector3, n3: Vector3, roadType: string): number
	local lengthStuds = BezierUtil.length(n0, n1, n2, n3, 24)
	local spec = RoadTypeCatalog.getOrDefault(roadType)
	local perMeter = spec.costPerMeter or RoadConstants.ROAD_COST_PER_METER
	local disp = math.max(
		(n0 - old.p0).Magnitude, (n1 - old.p1).Magnitude,
		(n2 - old.p2).Magnitude, (n3 - old.p3).Magnitude)
	local frac = math.clamp(disp / MOVE_COST_REF_DIST, MOVE_COST_MIN_FRAC, 1)
	return lengthStuds * RoadConstants.STUD_TO_METER * perMeter * frac
end

-- Cursor cost tag: rides next to the mouse during a road drag, showing what the
-- release will charge. Same pill as the Nature tool's.
local _costLabel: TextLabel? = nil
local function ensureCostLabel(): TextLabel
	if _costLabel and _costLabel.Parent then return _costLabel :: TextLabel end
	local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "MoveCostTag"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = Theme.Layer.CostTag
	gui.Parent = pg
	local l = Instance.new("TextLabel")
	l.AutomaticSize = Enum.AutomaticSize.XY
	l.BackgroundColor3 = Color3.fromRGB(18, 20, 24)
	l.BackgroundTransparency = 0.25
	l.TextColor3 = Theme.Color.Danger
	l.TextSize = Theme.TextSize.SM
	l.FontFace = Theme.Font.Label
	l.Visible = false
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = l
	local p = Instance.new("UIPadding")
	p.PaddingLeft = UDim.new(0, 6); p.PaddingRight = UDim.new(0, 6)
	p.PaddingTop = UDim.new(0, 2); p.PaddingBottom = UDim.new(0, 2)
	p.Parent = l
	l.Parent = gui
	_costLabel = l
	return l
end

local function hideCostTag()
	if _costLabel then _costLabel.Visible = false end
end

local function showCostTag(total: number)
	local cost = math.ceil(total * MOVE_COST_RATE)
	if cost <= 0 then hideCostTag(); return end
	local l = ensureCostLabel()
	l.Text = ("-$%d"):format(cost)
	local m = UserInputService:GetMouseLocation()
	l.Position = UDim2.fromOffset(m.X + 16, m.Y - 10)
	l.Visible = true
end

-- What the tool may hover / select. Details / Surfaces / Net Lanes have no
-- entities in this game yet -- their rows are omitted from the panel.
local _filters = {
	Buildings = true,
	Plants = true,
	Details = false,
	Props = true,
	Surfaces = false,
	Nodes = true,
	Segments = true,
	NetLanes = false,
}
local FILTER_ORDER = { "Buildings", "Plants", "Details", "Props", "Surfaces", "Nodes", "Segments", "NetLanes" }
local FILTER_LABEL: { [string]: string } = {
	Buildings = "Buildings", Plants = "Plants", Details = "Details", Props = "Props",
	Surfaces = "Surfaces", Nodes = "Nodes", Segments = "Segments", NetLanes = "Net Lanes",
}
local FILTER_SUPPORTED: { [string]: boolean } = {
	Buildings = true, Plants = true, Details = false, Props = true,
	Surfaces = false, Nodes = true, Segments = true, NetLanes = false,
}

local _inited = false
local _bound = false
local _enabled = false
local _manipulation = false
local _renderConn: RBXScriptConnection? = nil
local _inputConn: RBXScriptConnection? = nil
local _upConn: RBXScriptConnection? = nil
local _listener: ((enabled: boolean) -> ())? = nil
local _moveRemote: RemoteEvent? = nil
local _moveServiceRemote: RemoteEvent? = nil
local _moveNatureRemote: RemoteEvent? = nil
local _undoRemote: RemoteEvent? = nil
local _redoRemote: RemoteEvent? = nil
local _panelGui: ScreenGui? = nil
local _panelConns: { RBXScriptConnection } = {}
local _manipBtn: any = nil

-- ------------------------------------------------------------------- types --
type ObjKind = "Education" | "Emergency" | "Nature"
type SelObject = { model: Model, kind: ObjKind, id: number }

type Grab =
	{ type: "node", id: number }
	| { type: "cp", index: number, segId: number? }
	| { type: "body" }
	| { type: "segsel", id: number }
	| { type: "object", obj: SelObject }
	| { type: "marquee" }

-- Selection: EITHER one segment (handle UI) OR a set of nodes/objects (marquee).
local _selSegId: number? = nil
local _selNodeIds: { number } = {}
local _selObjects: { SelObject } = {}

local _hover: Grab? = nil
local _pending: { grab: Grab, screen: Vector2 }? = nil

type Drag = {
	kind: "group" | "cp" | "object" | "marquee",
	start: Vector3?,          -- grab ground point (world drags)
	startScreen: Vector2?,    -- marquee anchor
	rot: number,              -- accumulated Q/E rotation
	groupNodes: { number },
	groupObjects: { SelObject },
	pivot: Vector3?,          -- group rotation pivot (node centroid at grab)
	cpIndex: number?,
	obj: SelObject?,
	ghost: Model?,            -- object drag clone
	ghostYaw: number,
	lastTarget: Vector3?,
	ringId: number?,          -- whole-roundabout drag: the ring moves as one object
}
local _drag: Drag? = nil
-- Segment a cp/bend drag edits. A node's own control-point grab carries its segId;
-- otherwise it falls back to the selected segment.
local _cpSegId: number? = nil

-- After a road commit the moved segments come back with NEW ids; remember where
-- to look so the selection survives the round-trip.
local _reselect: { kind: string, pos: Vector3 }? = nil

-- ------------------------------------------------------------------ raycast --
-- No RaycastParams and no filter refresh here: Core.CursorRay owns both, and resolves the
-- character on every query so a respawn cannot leave a stale ignore list behind.

-- Hover picking: hits road decks and object models too.
local function groundHit(): CursorRay.GroundHit?
	return CursorRay.groundHit()
end

-- Drag target: terrain only, so the point never jumps onto rooftops or the ghost.
local function terrainPoint(): Vector3?
	return CursorRay.terrainPoint()
end

local function worldToScreen(pos: Vector3): Vector2?
	local camera = Workspace.CurrentCamera
	if not camera then return nil end
	local v, on = camera:WorldToViewportPoint(pos)
	if not on or v.Z <= 0 then return nil end
	return Vector2.new(v.X, v.Y)
end

-- --------------------------------------------------------------- ghost pool --
local _folder: Folder? = nil
local _pool: { Part } = {}
local _used = 0

local function previewFolder(): Folder
	local f = UiScratch.folder("MoveToolPreview")
	_folder = f
	return f
end

local function acquire(): Part
	_used += 1
	local p = _pool[_used]
	if p and p.Parent then
		return p
	end
	p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Parent = previewFolder()
	_pool[_used] = p
	return p
end

-- ---------------------------------------------------------------- beam pool --
-- Ribbon fill, edge lines and ring markers are Beams: trapezoid quads share
-- exact station edges, so curves tile seamlessly. Parts always gap or overlap
-- on bends -- the radial banding in the old drag ghost.
local UP = Vector3.yAxis
local _beamAnchor: Part? = nil
local _beams: { Beam } = {}
local _atts: { Attachment } = {}
local _beamN = 0
local _attN = 0
local _beamHigh = 0

local function beamAnchor(): Part
	local a = _beamAnchor
	if a and a.Parent then return a end
	a = Instance.new("Part")
	a.Name = "MoveBeamAnchor"
	a.Anchored = true
	a.CanCollide = false
	a.CanQuery = false
	a.CanTouch = false
	a.Transparency = 1
	a.Size = Vector3.one
	a.CFrame = CFrame.identity
	a.Parent = previewFolder()
	_beamAnchor = a
	return a
end

local function nextAtt(cf: CFrame): Attachment
	_attN += 1
	local a = _atts[_attN]
	if not a or not a.Parent then
		a = Instance.new("Attachment")
		a.Parent = beamAnchor()
		_atts[_attN] = a
	end
	a.WorldCFrame = cf
	return a
end

local function nextBeam(): Beam
	_beamN += 1
	if _beamN > _beamHigh then _beamHigh = _beamN end
	local b = _beams[_beamN]
	if not b or not b.Parent then
		b = Instance.new("Beam")
		b.Parent = beamAnchor()
		_beams[_beamN] = b
	end
	b.Enabled = true
	return b
end

local function beamProps(b: Beam, color: Color3, width: number, trans: number, curve0: number?, curve1: number?, segments: number?)
	b.FaceCamera = false
	b.CurveSize0 = curve0 or 0
	b.CurveSize1 = curve1 or 0
	b.Segments = segments or 1
	b.Width0 = width
	b.Width1 = width
	b.Color = ColorSequence.new(color)
	b.Transparency = NumberSequence.new(trans)
	b.LightEmission = 0.25
	b.Texture = ""
end

-- Straight flat strip between two points (edge lines, outlines).
local function beamFlat(a: Vector3, b: Vector3, color: Color3, width: number, trans: number)
	local d = b - a
	local len = d.Magnitude
	if len < 1e-3 then return end
	local x = d / len
	local bm = nextBeam()
	bm.Attachment0 = nextAtt(CFrame.fromMatrix(a, x, x:Cross(UP)))
	bm.Attachment1 = nextAtt(CFrame.fromMatrix(b, x, x:Cross(UP)))
	beamProps(bm, color, width, trans)
end

-- One trapezoid fill quad bounded by the station normals (seamless tiling).
local function beamFill(a: Vector3, nrm0: Vector3, b: Vector3, nrm1: Vector3, width: number, color: Color3, trans: number)
	if (b - a).Magnitude < 1e-3 then return end
	local bm = nextBeam()
	bm.Attachment0 = nextAtt(CFrame.fromMatrix(a, UP:Cross(nrm0).Unit, nrm0))
	bm.Attachment1 = nextAtt(CFrame.fromMatrix(b, UP:Cross(nrm1).Unit, nrm1))
	beamProps(bm, color, width, trans)
	bm.LightEmission = 0
end

-- Circle outline as four tangent-joined cubic arcs (no glow, just a line).
local function beamRing(center: Vector3, radius: number, color: Color3, width: number, trans: number)
	local seg = math.pi * 0.5
	local k = radius * (4 / 3) * math.tan(seg / 4)
	for i = 0, 3 do
		local a0 = seg * i
		local a1 = a0 + seg
		local pA = center + Vector3.new(math.cos(a0), 0, math.sin(a0)) * radius
		local pB = center + Vector3.new(math.cos(a1), 0, math.sin(a1)) * radius
		local tA = Vector3.new(-math.sin(a0), 0, math.cos(a0))
		local tB = Vector3.new(-math.sin(a1), 0, math.cos(a1))
		local bm = nextBeam()
		bm.Attachment0 = nextAtt(CFrame.fromMatrix(pA, tA, tA:Cross(UP)))
		bm.Attachment1 = nextAtt(CFrame.fromMatrix(pB, tB, tB:Cross(UP)))
		beamProps(bm, color, width, trans, k, k, 8)
	end
end

local function beginGhost()
	_used = 0
	_beamN = 0
	_attN = 0
end

local function endGhost()
	for i = _used + 1, #_pool do
		local p = _pool[i]
		if p then p.Transparency = 1 end
	end
	for i = _beamN + 1, _beamHigh do
		local b = _beams[i]
		if b then b.Enabled = false end
	end
end

local LIFT_V = Vector3.new(0, LIFT, 0)

local function flatUnit(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-4 then f.Unit else Vector3.new(1, 0, 0)
end

-- Station count scales with how much the curve actually turns (straight = 2).
local function curveSteps(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3): number
	local turn = 0
	local a1, b1 = flatUnit(p0 - p1), flatUnit(p2 - p1)
	turn += math.pi - math.acos(math.clamp(a1:Dot(b1), -1, 1))
	local a2, b2 = flatUnit(p1 - p2), flatUnit(p3 - p2)
	turn += math.pi - math.acos(math.clamp(a2:Dot(b2), -1, 1))
	return math.clamp(math.ceil(turn / math.rad(6)) + 1, 2, 40)
end

-- Both offset edges of a curve as flat strips -- Move It's segment highlight.
local function drawSegmentOutline(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, width: number, color: Color3, trans: number)
	local n = curveSteps(p0, p1, p2, p3)
	local half = width * 0.5
	local prevL: Vector3? = nil
	local prevR: Vector3? = nil
	for i = 0, n do
		local t = i / n
		local c = BezierUtil.point(p0, p1, p2, p3, t) + LIFT_V
		local tang = flatUnit(BezierUtil.tangent(p0, p1, p2, p3, math.clamp(t, 0.001, 0.999)))
		local nrm = Vector3.new(-tang.Z, 0, tang.X)
		local l = c + nrm * half
		local r = c - nrm * half
		if prevL and prevR then
			beamFlat(prevL, l, color, 0.7, trans)
			beamFlat(prevR, r, color, 0.7, trans)
		end
		prevL, prevR = l, r
	end
end

-- Full-width drag ribbon in the placement-preview look: seamless translucent
-- fill with bright edge lines. Red when the move would be rejected.
local function drawGhostRibbon(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, width: number, bad: boolean, nrmStart: Vector3?, nrmEnd: Vector3?)
	local n = curveSteps(p0, p1, p2, p3)
	local half = width * 0.5
	local fill = if bad then COLOR_BAD else GHOST_FILL
	local edge = if bad then COLOR_BAD else GHOST_EDGE
	local prevC: Vector3? = nil
	local prevN: Vector3? = nil
	local prevL: Vector3? = nil
	local prevR: Vector3? = nil
	for i = 0, n do
		local t = i / n
		local c = BezierUtil.point(p0, p1, p2, p3, t) + LIFT_V
		local tang = flatUnit(BezierUtil.tangent(p0, p1, p2, p3, math.clamp(t, 0.001, 0.999)))
		local nrm = Vector3.new(-tang.Z, 0, tang.X)
		-- Shared bevel normal at a joined node: both adjacent ribbons meet on one edge.
		if i == 0 and nrmStart then nrm = nrmStart
		elseif i == n and nrmEnd then nrm = nrmEnd end
		local l = c + nrm * half
		local r = c - nrm * half
		if prevC and prevN and prevL and prevR then
			beamFill(prevC, prevN, c, nrm, width, fill, 0.62)
			beamFlat(prevL, l, edge, 1.0, 0)
			beamFlat(prevR, r, edge, 1.0, 0)
		end
		prevC, prevN, prevL, prevR = c, nrm, l, r
	end
end

-- Flat ring marker (Move It's node circle) -- no glow, just a thin outline.
local function drawRing(pos: Vector3, radius: number, color: Color3)
	beamRing(pos + LIFT_V, radius, color, 0.7, 0)
end

-- Dotted guide from a node to its curve control point.
local function drawDots(a: Vector3, b: Vector3, color: Color3)
	local d = (b - a).Magnitude
	if d < 1e-3 then return end
	local n = math.clamp(math.floor(d / 3), 1, 40)
	for i = 0, n do
		local p = acquire()
		p.Shape = Enum.PartType.Ball
		p.Material = Enum.Material.SmoothPlastic
		p.Size = Vector3.new(0.6, 0.6, 0.6)
		p.CFrame = CFrame.new(a:Lerp(b, i / n) + LIFT_V)
		p.Color = color
		p.Transparency = 0.1
	end
end

local function clearGhost()
	beginGhost()
	endGhost()
end

-- ------------------------------------------------------- object highlights --
local _hoverHL: Highlight? = nil
local _selHLs: { Highlight } = {}
local _selHLUsed = 0

local function hoverHighlight(target: Model?, color: Color3?)
	local hl = _hoverHL
	if not hl or not hl.Parent then
		hl = Instance.new("Highlight")
		hl.FillTransparency = 0.82
		hl.OutlineTransparency = 0
		hl.DepthMode = Enum.HighlightDepthMode.Occluded
		hl.Enabled = false
		hl.Parent = previewFolder()
		_hoverHL = hl
	end
	if target then
		hl.FillColor = color or COLOR_HOVER
		hl.OutlineColor = color or COLOR_HOVER
		hl.Adornee = target
		hl.Enabled = true
	else
		hl.Enabled = false
		hl.Adornee = nil
	end
end

local function beginSelHighlights()
	_selHLUsed = 0
end

local function selHighlight(target: Model, color: Color3)
	_selHLUsed += 1
	local hl = _selHLs[_selHLUsed]
	if not hl or not hl.Parent then
		hl = Instance.new("Highlight")
		hl.FillTransparency = 0.82
		hl.OutlineTransparency = 0
		hl.DepthMode = Enum.HighlightDepthMode.Occluded
		hl.Parent = previewFolder()
		_selHLs[_selHLUsed] = hl
	end
	hl.FillColor = color
	hl.OutlineColor = color
	hl.Adornee = target
	hl.Enabled = true
end

local function endSelHighlights()
	for i = _selHLUsed + 1, #_selHLs do
		local hl = _selHLs[i]
		if hl then hl.Enabled = false; hl.Adornee = nil end
	end
end

-- ------------------------------------------------------------------ dimming --
-- While dragging, the live pieces dim so the ghost has priority. Restore the
-- exact prior LocalTransparencyModifier: RoadMeshView holds source parts at 1
-- (hidden behind its baked mesh) and those must stay hidden afterwards.
local _dimmed: { [BasePart]: number } = {}

local function dimPart(p: BasePart)
	if _dimmed[p] == nil and p.LocalTransparencyModifier < DIM then
		_dimmed[p] = p.LocalTransparencyModifier
		p.LocalTransparencyModifier = DIM
	end
end

local function dimModel(m: Instance?)
	if not m then return end
	for _, d in (m :: Instance):GetDescendants() do
		if d:IsA("BasePart") then dimPart(d) end
	end
	if m:IsA("BasePart") then dimPart(m) end
end

-- Road pieces render twice on the client: the replicated part Model under
-- _City.Roads AND its locally baked MeshPart in _RoadMeshes. Dim both.
local function dimRoadPiece(name: string)
	local city = Workspace:FindFirstChild("_City")
	local roads = city and city:FindFirstChild("Roads")
	if roads then dimModel(roads:FindFirstChild(name)) end
	local meshes = Workspace:FindFirstChild("_RoadMeshes")
	if meshes then
		local mesh = meshes:FindFirstChild(name .. "_Mesh")
		if mesh and mesh:IsA("BasePart") then dimPart(mesh) end
	end
end

local function dimSegments(segIds: { number })
	for _, id in segIds do
		dimRoadPiece("Segment_" .. id)
	end
end

local function dimNodes(nodeIds: { number })
	for _, id in nodeIds do
		dimRoadPiece("Junction_" .. id)
		dimRoadPiece("Corner_" .. id)
		dimRoadPiece("DeadEnd_" .. id)
	end
end

local function undimAll()
	for p, orig in _dimmed do
		if p.Parent then p.LocalTransparencyModifier = orig end
	end
	table.clear(_dimmed)
end

-- ------------------------------------------------------------ object picking --
local function natureFilterAllows(model: Model): boolean
	local key = model:GetAttribute("NatureKey")
	local entry = if typeof(key) == "string" then NatureCatalog.get(key) else nil
	local isProp = entry ~= nil and (entry.kind == "Rock" or entry.kind == "Shape")
	return if isProp then _filters.Props else _filters.Plants
end

-- Walk up from a raycast hit to a movable object the filters allow.
local function objectFromInstance(inst: Instance?): SelObject?
	local cur = inst
	while cur and cur ~= Workspace do
		if cur:IsA("Model") then
			local schoolId = cur:GetAttribute("SchoolId")
			if typeof(schoolId) == "number" then
				return if _filters.Buildings then { model = cur, kind = "Education" :: ObjKind, id = schoolId } else nil
			end
			local serviceId = cur:GetAttribute("ServiceId")
			if typeof(serviceId) == "number" then
				return if _filters.Buildings then { model = cur, kind = "Emergency" :: ObjKind, id = serviceId } else nil
			end
			if CollectionService:HasTag(cur, "NatureProp") then
				return if natureFilterAllows(cur) then { model = cur, kind = "Nature" :: ObjKind, id = 0 } else nil
			end
		end
		cur = cur.Parent
	end
	return nil
end

-- Nature props are non-queryable, so the ground raycast slips through them. Pick the
-- nearest prop within NATURE_PICK_R of the ground point (same approach as Bulldoze).
-- ponytail: O(props) scan per hover frame; matches BulldozeController's accepted cost.
local function natureUnderPoint(p: Vector3): SelObject?
	local city = Workspace:FindFirstChild("_City")
	local nature = city and city:FindFirstChild("Nature")
	if not nature then return nil end
	local best: Model? = nil
	local bestD = NATURE_PICK_R
	for _, m in nature:GetChildren() do
		if m:IsA("Model") and CollectionService:HasTag(m, "NatureProp") and natureFilterAllows(m) then
			local pv = m:GetPivot().Position
			local d = Vector2.new(p.X - pv.X, p.Z - pv.Z).Magnitude
			if d <= bestD then best = m; bestD = d end
		end
	end
	return if best then { model = best, kind = "Nature" :: ObjKind, id = 0 } else nil
end

-- Generous hit test against ALREADY-SELECTED props only (few, so GetBoundingBox is
-- cheap): a click anywhere on a selected canopy counts as "on the selection".
-- ponytail: bounding-box per selected prop per hover frame; selection is small.
local function selectedNatureUnderPoint(p: Vector3): SelObject?
	for _, obj in _selObjects do
		if obj.kind == "Nature" and obj.model.Parent then
			local cf, size = obj.model:GetBoundingBox()
			local lp = cf:PointToObjectSpace(p)
			if math.abs(lp.X) <= size.X * 0.5 + 2 and math.abs(lp.Z) <= size.Z * 0.5 + 2 then
				return obj
			end
		end
	end
	return nil
end

local function modelYaw(m: Model): number
	local _, ry = m:GetPivot():ToOrientation()
	return ry
end

-- --------------------------------------------------------------- selection --
-- ------------------------------------------------------------------ focus --
-- NO handles on a selected prop. Moving one is Cities: Skylines' gesture -- grab it and
-- drag, the ghost following the cursor (see beginDrag/updateObjectGhost) -- and a cage of
-- arrows over the thing you are trying to drag fights that gesture for the same clicks.
-- Turning and resizing are the dock's buttons and Q/E. The handles still exist for the
-- Nature tab's Precise mode, which is opt-in and exists precisely to nudge by hand.
local function focusModel(): Model?
	if #_selObjects ~= 1 then return nil end
	local obj = _selObjects[1]
	if not obj or obj.kind ~= "Nature" or not obj.model.Parent then return nil end
	return obj.model
end

-- A single selected prop drops every other prop back, so the one you are about to drag is
-- the one you can see. NatureGizmo owns the dimming for both tools.
local function syncFocus()
	local sel = focusModel()
	if not (_enabled and sel) then
		NatureGizmo.detach()
		return
	end
	NatureGizmo.focus(sel)
end

local function clearSelection()
	_selSegId = nil
	table.clear(_selNodeIds)
	table.clear(_selObjects)
	NatureGizmo.detach() -- also lifts the focus dim
end

local function hasSelection(): boolean
	return _selSegId ~= nil or #_selNodeIds > 0 or #_selObjects > 0
end

local function selectionTint(): Color3
	return if _manipulation then COLOR_MANIP else COLOR_SEL
end

local function attachedSegments(nodeId: number): { any }
	local out: { any } = {}
	for _, seg in Snapper.getSegments() do
		if seg.startNode == nodeId or seg.endNode == nodeId then
			table.insert(out, seg)
		end
	end
	return out
end

-- Segments touching any node of the set (each listed once).
local function segmentsTouching(nodeIds: { number }): { any }
	local inSet: { [number]: boolean } = {}
	for _, id in nodeIds do inSet[id] = true end
	local out: { any } = {}
	for _, seg in Snapper.getSegments() do
		if (seg.startNode and inSet[seg.startNode]) or (seg.endNode and inSet[seg.endNode]) then
			table.insert(out, seg)
		end
	end
	return out
end

-- A roundabout is ONE object: grabbing any arc, or any node on the ring, takes the whole
-- ring. Returns its id and its node ids, or nil when this grab is not on a roundabout.
local function ringGrab(segId: number?, nodeId: number?): (number?, { number })
	local raId: number? = nil
	for _, seg in Snapper.getSegments() do
		if seg.isRoundabout and seg.roundaboutId
			and ((segId ~= nil and seg.id == segId)
				or (nodeId ~= nil and (seg.startNode == nodeId or seg.endNode == nodeId))) then
			raId = seg.roundaboutId
			break
		end
	end
	if not raId then return nil, {} end
	local nodes: { number } = {}
	local seen: { [number]: boolean } = {}
	for _, seg in Snapper.getSegments() do
		if seg.isRoundabout and seg.roundaboutId == raId then
			for _, nid in { seg.startNode, seg.endNode } do
				if nid and not seen[nid] then
					seen[nid] = true
					table.insert(nodes, nid)
				end
			end
		end
	end
	return raId, nodes
end

-- ------------------------------------------------------------- group math --
-- MUST mirror the server's moveNodeSet handle rules (RoadService).
local function groupTarget(pos: Vector3, pivot: Vector3, rot: number, delta: Vector3): Vector3
	return RoadMoveGeometry.rotateY(pos, pivot, rot) + delta
end

type GhostSeg = { p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, roadType: string, bad: boolean, startNode: number?, endNode: number? }

local function buildGroupGhosts(targets: { [number]: Vector3 }, rot: number, pivot: Vector3?, delta: Vector3): ({ GhostSeg }, boolean, number)
	local out: { GhostSeg } = {}
	local allOk = true
	local cost = 0
	local nodeIdList: { number } = {}
	for id in targets do table.insert(nodeIdList, id) end
	for _, seg in segmentsTouching(nodeIdList) do
		local tA = if seg.startNode then targets[seg.startNode] else nil
		local tB = if seg.endNode then targets[seg.endNode] else nil
		local n0: Vector3 = tA or seg.p0
		local n3: Vector3 = tB or seg.p3
		local n1: Vector3, n2: Vector3
		if RoadMoveGeometry.isStraight(seg.p0, seg.p1, seg.p2, seg.p3) then
			n1, n2 = n0:Lerp(n3, 1 / 3), n0:Lerp(n3, 2 / 3)
		elseif tA and tB and rot ~= 0 and pivot then
			n1 = RoadMoveGeometry.rotateY(seg.p1, pivot, rot) + delta
			n2 = RoadMoveGeometry.rotateY(seg.p2, pivot, rot) + delta
		else
			n1 = seg.p1 + (n0 - seg.p0)
			n2 = seg.p2 + (n3 - seg.p3)
		end
		-- A ring arc inside a whole-roundabout drag keeps its exact shape (both ends move by
		-- the same delta), so it is rigid, not refused, and needs no curve validation.
		local rigidRing = seg.isRoundabout == true and tA ~= nil and tB ~= nil
		local bad = not rigidRing
			and (seg.isRoundabout == true
				or RoadMoveGeometry.validate(n0, n1, n2, n3, seg.roadType) ~= nil)
		if bad then allOk = false end
		cost += moveCostOf(seg, n0, n1, n2, n3, seg.roadType)
		table.insert(out, { p0 = n0, p1 = n1, p2 = n2, p3 = n3, roadType = seg.roadType, bad = bad, startNode = seg.startNode, endNode = seg.endNode })
	end
	return out, allOk, cost
end

-- --------------------------------------------------------------- marquee UI --
local _marqueeGui: ScreenGui? = nil
local _marqueeFrame: Frame? = nil

local function marqueeFrame(): Frame
	local gui = _marqueeGui
	if not gui or not gui.Parent then
		gui = Instance.new("ScreenGui")
		gui.Name = "MoveToolMarquee"
		gui.ResetOnSpawn = false
		gui.IgnoreGuiInset = true
		gui.DisplayOrder = Theme.Layer.WorldTag + 1
		gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
		_marqueeGui = gui
	end
	local f = _marqueeFrame
	if not f or not f.Parent then
		f = Instance.new("Frame")
		f.BackgroundColor3 = COLOR_SEL
		f.BackgroundTransparency = 0.85
		f.BorderSizePixel = 0
		f.Visible = false
		f.Parent = gui
		local stroke = Instance.new("UIStroke")
		stroke.Color = COLOR_SEL
		stroke.Thickness = 2
		stroke.Parent = f
		_marqueeFrame = f
	end
	return f :: Frame
end

local function hideMarquee()
	if _marqueeFrame then _marqueeFrame.Visible = false end
end

local function marqueeRect(anchor: Vector2, now: Vector2): (Vector2, Vector2)
	local minP = Vector2.new(math.min(anchor.X, now.X), math.min(anchor.Y, now.Y))
	local maxP = Vector2.new(math.max(anchor.X, now.X), math.max(anchor.Y, now.Y))
	return minP, maxP
end

local function selectInMarquee(minP: Vector2, maxP: Vector2)
	clearSelection()
	local function inside(pos: Vector3): boolean
		local s = worldToScreen(pos)
		return s ~= nil and s.X >= minP.X and s.X <= maxP.X and s.Y >= minP.Y and s.Y <= maxP.Y
	end
	if _filters.Nodes or _filters.Segments then
		for id, pos in Snapper.getNodes() do
			if #_selNodeIds >= MAX_GROUP then break end
			if inside(pos) then table.insert(_selNodeIds, id) end
		end
	end
	-- Nature props ride along in group moves (batched remote). Buildings move
	-- one-per-request server-side, so they stay single-drag only.
	if _filters.Plants or _filters.Props then
		local city = Workspace:FindFirstChild("_City")
		local nature = city and city:FindFirstChild("Nature")
		if nature then
			for _, m in nature:GetChildren() do
				if #_selObjects >= MAX_NATURE_BATCH then break end
				if m:IsA("Model") and CollectionService:HasTag(m, "NatureProp")
					and natureFilterAllows(m) and inside(m:GetPivot().Position) then
					table.insert(_selObjects, { model = m, kind = "Nature" :: ObjKind, id = 0 })
				end
			end
		end
	end
end

-- ------------------------------------------------------------ scene drawing --
local function drawSelectedSegment(tint: Color3)
	local seg = if _selSegId then Snapper.getSegmentInfo(_selSegId) else nil
	if not seg then return end
	local width = RoadTypeCatalog.getOrDefault(seg.roadType).width
	drawSegmentOutline(seg.p0, seg.p1, seg.p2, seg.p3, width, tint, 0.05)
	-- Curve handles so you can reshape the segment: a dotted guide from each end to
	-- its control point. No end-node rings -- selecting a segment lets you bend it;
	-- it doesn't select the shared nodes or move the road.
	drawDots(seg.p0, seg.p1, tint)
	drawDots(seg.p3, seg.p2, tint)
	drawRing(seg.p1, 2.5, tint)
	drawRing(seg.p2, 2.5, tint)
end

-- A selected node shows its tangent guide(s): the dotted node->control-point line
-- for each attached segment -- one side for an edge node, both sides for a node
-- between two segments (the angle its placement can change). Guides only when a
-- single node is selected; a whole-road marquee stays plain rings to avoid clutter.
-- ponytail: O(segments) scan for the one node per idle frame, same cost as the
-- segment-touch scans already used in this file.
local function drawSelectedNodes(tint: Color3)
	local single = #_selNodeIds == 1
	for _, id in _selNodeIds do
		local pos = Snapper.getNodePos(id)
		if pos then
			drawRing(pos, 4.5, tint)
			if single then
				for _, seg in attachedSegments(id) do
					if seg.startNode == id then
						drawDots(seg.p0, seg.p1, tint)
						drawRing(seg.p1, 2.5, tint)
					elseif seg.endNode == id then
						drawDots(seg.p3, seg.p2, tint)
						drawRing(seg.p2, 2.5, tint)
					end
				end
			end
		end
	end
end

local function drawIdleScene()
	beginGhost()
	beginSelHighlights()
	local tint = selectionTint()

	drawSelectedSegment(tint)
	drawSelectedNodes(tint)
	for _, obj in _selObjects do
		if obj.model.Parent then selHighlight(obj.model, tint) end
	end

	-- Hover accents (white) on top of whatever is selected.
	local hov = _hover
	local hoverModel: Model? = nil
	if hov then
		if hov.type == "node" then
			local pos = Snapper.getNodePos(hov.id)
			if pos then drawRing(pos, 8, COLOR_HOVER) end
		elseif hov.type == "segsel" then
			local seg = Snapper.getSegmentInfo(hov.id)
			if seg then drawSegmentOutline(seg.p0, seg.p1, seg.p2, seg.p3, RoadTypeCatalog.getOrDefault(seg.roadType).width, COLOR_HOVER, 0.25) end
		elseif hov.type == "object" then
			hoverModel = hov.obj.model
		end
	end
	hoverHighlight(hoverModel)

	endGhost()
	endSelHighlights()
end

-- ------------------------------------------------------------- drag preview --
local function roadWidth(roadType: string): number
	return RoadTypeCatalog.getOrDefault(roadType).width
end

local function drawGroupPreview(drag: Drag, target: Vector3)
	local delta = target - (drag.start :: Vector3)
	delta = Vector3.new(delta.X, delta.Y, delta.Z)
	local pivot = drag.pivot
	local targets: { [number]: Vector3 } = {}
	for _, id in drag.groupNodes do
		local pos = Snapper.getNodePos(id)
		if pos and pivot then
			targets[id] = groupTarget(pos, pivot, drag.rot, delta)
		end
	end
	local ghosts, _, moveCost = buildGroupGhosts(targets, drag.rot, pivot, delta)
	showCostTag(moveCost)
	-- Bevel join: where exactly two ghost segments share a moved node, give both
	-- ribbons the same end normal (bisector of their tangents) so their end edges
	-- coincide -- no see-through corner gap, no overlap. Independent perpendicular
	-- caps are what leave the triangular sliver otherwise.
	-- ponytail: bevel, not full miter -- a small outer notch can remain on sharp
	-- corners; add the apex-fill triangle only if that ever reads as a gap.
	local jAcc: { [number]: Vector3 } = {}
	local jCnt: { [number]: number } = {}
	local function nrmOf(a: Vector3, b: Vector3): Vector3
		local tg = flatUnit(b - a)
		return Vector3.new(-tg.Z, 0, tg.X)
	end
	local function accum(node: number?, nrm: Vector3)
		if not node then return end
		local ref = jAcc[node]
		if ref and ref:Dot(nrm) < 0 then nrm = -nrm end
		jAcc[node] = (ref or Vector3.zero) + nrm
		jCnt[node] = (jCnt[node] or 0) + 1
	end
	for _, g in ghosts do
		accum(g.startNode, nrmOf(g.p0, g.p1))
		accum(g.endNode, nrmOf(g.p2, g.p3))
	end
	local function joinNrm(node: number?, natural: Vector3): Vector3?
		if not node or jCnt[node] ~= 2 then return nil end
		local v = jAcc[node]
		local flat = Vector3.new(v.X, 0, v.Z)
		if flat.Magnitude < 1e-3 then return nil end
		local u = flat.Unit
		return if u:Dot(natural) < 0 then -u else u
	end
	for _, g in ghosts do
		local sN = joinNrm(g.startNode, nrmOf(g.p0, g.p1))
		local eN = joinNrm(g.endNode, nrmOf(g.p2, g.p3))
		drawGhostRibbon(g.p0, g.p1, g.p2, g.p3, roadWidth(g.roadType), g.bad, sN, eN)
	end
	for _, pos in targets do
		drawRing(pos, 4.5, GHOST_EDGE)
	end
	-- Nature props ride along: marker rings at their new spots (no clone forest).
	if pivot then
		for _, obj in drag.groupObjects do
			if obj.model.Parent then
				local p = obj.model:GetPivot().Position
				drawRing(groupTarget(p, pivot, drag.rot, delta), 2, GHOST_EDGE)
			end
		end
	end
end

local function drawCpPreview(drag: Drag, target: Vector3)
	local seg = if _cpSegId then Snapper.getSegmentInfo(_cpSegId) else nil
	if not seg then return end
	local tint = selectionTint()
	-- One-sided when manipulating or editing a node's own handle (no segment
	-- selected); otherwise a symmetric bend through the cursor.
	local oneSided = _manipulation or _selSegId == nil
	local n0, n1, n2, n3
	if oneSided then
		-- One control point alone: only this node's approach angle changes.
		local cp = if drag.cpIndex == 1 then seg.p1 else seg.p2
		local moved = Vector3.new(target.X, cp.Y, target.Z)
		n0, n3 = seg.p0, seg.p3
		n1 = if drag.cpIndex == 1 then moved else seg.p1
		n2 = if drag.cpIndex == 2 then moved else seg.p2
	else
		-- Both angles: symmetric bend through the cursor (placement-style curve).
		n0, n1, n2, n3 = RoadMoveGeometry.bendThrough(seg.p0, seg.p3, target)
	end
	local bad = RoadMoveGeometry.validate(n0, n1, n2, n3, seg.roadType) ~= nil
	showCostTag(moveCostOf(seg, n0, n1, n2, n3, seg.roadType))
	drawGhostRibbon(n0, n1, n2, n3, roadWidth(seg.roadType), bad)
	drawRing(n0, 4.5, GHOST_EDGE)
	drawRing(n3, 4.5, GHOST_EDGE)
	drawDots(n0, n1, tint)
	drawDots(n3, n2, tint)
	drawRing(n1, 2.5, if bad then COLOR_BAD else tint)
	drawRing(n2, 2.5, if bad then COLOR_BAD else tint)
end

local function updateObjectGhost(drag: Drag, target: Vector3)
	local ghost = drag.ghost
	if not ghost then return end
	ghost:PivotTo(CFrame.new(target) * CFrame.Angles(0, drag.ghostYaw, 0))
end

local function updateDrag()
	local drag = _drag
	if not drag then return end
	if drag.kind == "marquee" then
		local anchor = drag.startScreen
		if anchor then
			local m = UserInputService:GetMouseLocation()
			local minP, maxP = marqueeRect(anchor, Vector2.new(m.X, m.Y))
			local f = marqueeFrame()
			f.Position = UDim2.fromOffset(minP.X, minP.Y)
			f.Size = UDim2.fromOffset(maxP.X - minP.X, maxP.Y - minP.Y)
			f.Visible = true
		end
		return
	end
	local target = terrainPoint()
	if not target then return end
	drag.lastTarget = target
	beginGhost()
	if drag.kind == "group" then
		drawGroupPreview(drag, target)
	elseif drag.kind == "cp" then
		drawCpPreview(drag, target)
	elseif drag.kind == "object" then
		updateObjectGhost(drag, target) -- object moves are free; no cost tag
		hideCostTag()
	end
	endGhost()
end

-- ---------------------------------------------------------------- dragging --
local function makeObjectGhost(model: Model): Model
	local clone = model:Clone()
	clone.Name = model.Name .. "_MoveGhost"
	for _, d in clone:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = false
			d.Transparency = math.clamp(0.45 + d.Transparency * 0.5, 0, 1)
		elseif d:IsA("BaseScript") or d:IsA("Sound") then
			d:Destroy()
		end
	end
	clone.Parent = previewFolder()
	return clone
end

local function isSelectedModel(model: Model): boolean
	for _, obj in _selObjects do
		if obj.model == model then return true end
	end
	return false
end

local function beginMarquee()
	local m = UserInputService:GetMouseLocation()
	_drag = {
		kind = "marquee" :: "marquee", start = nil, startScreen = Vector2.new(m.X, m.Y),
		rot = 0, groupNodes = {}, groupObjects = {}, pivot = nil,
		cpIndex = nil, obj = nil, ghost = nil, ghostYaw = 0, lastTarget = nil,
	}
	clearGhost()
	hoverHighlight(nil)
end

-- Move the current selection (nodes + nature props) as one group. Pivot is the
-- centroid so Q/E rotation turns the whole set about its middle.
local function beginSelectionMove(start: Vector3)
	local nodes = table.clone(_selNodeIds)
	local objects = table.clone(_selObjects)
	local sum = Vector3.zero
	local count = 0
	for _, id in nodes do
		local pos = Snapper.getNodePos(id)
		if pos then sum += pos; count += 1 end
	end
	for _, obj in objects do
		if obj.model.Parent then sum += obj.model:GetPivot().Position; count += 1 end
	end
	if count == 0 then return end
	_drag = {
		kind = "group" :: "group", start = start, startScreen = nil, rot = 0,
		groupNodes = nodes, groupObjects = objects, pivot = sum / count,
		cpIndex = nil, obj = nil, ghost = nil, ghostYaw = 0, lastTarget = nil,
	}
	local segIds: { number } = {}
	for _, seg in segmentsTouching(nodes) do table.insert(segIds, seg.id) end
	dimSegments(segIds)
	dimNodes(nodes)
	for _, obj in objects do dimModel(obj.model) end
	hoverHighlight(nil)
end

local function beginDrag(grab: Grab)
	local start = terrainPoint()
	if grab.type == "marquee" then
		beginMarquee()
		return
	end
	if not start then return end

	if grab.type == "cp" then
		_cpSegId = grab.segId or _selSegId
		local seg = if _cpSegId then Snapper.getSegmentInfo(_cpSegId) else nil
		if not seg then return end
		_drag = {
			kind = "cp" :: "cp", start = start, startScreen = nil, rot = 0,
			groupNodes = {}, groupObjects = {}, pivot = nil, cpIndex = grab.index,
			obj = nil, ghost = nil, ghostYaw = 0, lastTarget = nil,
		}
		dimSegments({ seg.id })
		return
	end

	-- A roundabout moves as one object: any arc, or any node on the ring, drags the whole
	-- thing (the roads feeding it stretch to follow their entry).
	if grab.type == "body" or grab.type == "segsel" or grab.type == "node" then
		local raId, ringNodes = ringGrab(
			if grab.type == "segsel" then grab.id elseif grab.type == "body" then _selSegId else nil,
			if grab.type == "node" then grab.id else nil)
		if raId and #ringNodes > 0 then
			local centroid = Vector3.zero
			local count = 0
			for _, id in ringNodes do
				local pos = Snapper.getNodePos(id)
				if pos then centroid += pos; count += 1 end
			end
			if count == 0 then return end
			_drag = {
				kind = "group" :: "group", start = start, startScreen = nil, rot = 0,
				groupNodes = ringNodes, groupObjects = {}, pivot = centroid / count,
				cpIndex = nil, obj = nil, ghost = nil, ghostYaw = 0, lastTarget = nil,
				ringId = raId,
			}
			local ringSegs: { number } = {}
			for _, seg in segmentsTouching(ringNodes) do table.insert(ringSegs, seg.id) end
			dimSegments(ringSegs)
			dimNodes(ringNodes)
			hoverHighlight(nil)
			return
		end
	end

	-- Grabbing the road body (or dragging an unselected segment) bends the curve
	-- through the cursor -- it never slides the shared end nodes. Selecting a
	-- segment is curve-editing only; moving the road needs a node selection.
	if grab.type == "body" or grab.type == "segsel" then
		if grab.type == "segsel" then
			clearSelection()
			_selSegId = grab.id
		end
		_cpSegId = _selSegId
		local seg = if _cpSegId then Snapper.getSegmentInfo(_cpSegId) else nil
		if not seg then return end
		_drag = {
			kind = "cp" :: "cp", start = start, startScreen = nil, rot = 0,
			groupNodes = {}, groupObjects = {}, pivot = nil, cpIndex = 1,
			obj = nil, ghost = nil, ghostYaw = 0, lastTarget = nil,
		}
		dimSegments({ seg.id })
		return
	end

	if grab.type == "object" then
		local obj = grab.obj
		if not obj.model.Parent then return end
		-- Service buildings move one at a time (server takes one per request).
		if obj.kind ~= "Nature" then
			local ghost = makeObjectGhost(obj.model)
			_drag = {
				kind = "object" :: "object", start = start, startScreen = nil, rot = 0,
				groupNodes = {}, groupObjects = {}, pivot = nil, cpIndex = nil,
				obj = obj, ghost = ghost, ghostYaw = modelYaw(obj.model), lastTarget = nil,
			}
			dimModel(obj.model)
			hoverHighlight(nil)
			return
		end
		-- Nature: drag a SELECTED prop to move the whole selection (no box);
		-- drag an unselected one to rubber-band a box -- select first, then move.
		if isSelectedModel(obj.model) then
			beginSelectionMove(start)
		else
			beginMarquee()
		end
		return
	end

	-- Node drags resolve to a node set: a single node, or the whole marquee group
	-- when the grabbed node is part of it.
	local nodes: { number } = {}
	local objects: { SelObject } = {}
	if grab.type == "node" then
		local inSelection = false
		for _, id in _selNodeIds do
			if id == grab.id then inSelection = true; break end
		end
		if inSelection and #_selNodeIds > 1 then
			nodes = table.clone(_selNodeIds)
			objects = table.clone(_selObjects)
		else
			nodes = { grab.id }
		end
	end
	if #nodes == 0 then return end

	local centroid = Vector3.zero
	local count = 0
	for _, id in nodes do
		local pos = Snapper.getNodePos(id)
		if pos then centroid += pos; count += 1 end
	end
	if count == 0 then return end
	centroid = centroid / count

	_drag = {
		kind = "group" :: "group", start = start, startScreen = nil, rot = 0,
		groupNodes = nodes, groupObjects = objects, pivot = centroid,
		cpIndex = nil, obj = nil, ghost = nil, ghostYaw = 0, lastTarget = nil,
	}

	local segIds: { number } = {}
	for _, seg in segmentsTouching(nodes) do table.insert(segIds, seg.id) end
	dimSegments(segIds)
	dimNodes(nodes)
	for _, obj in objects do dimModel(obj.model) end
end

local function cancelDrag()
	local drag = _drag
	_drag = nil
	_cpSegId = nil
	if drag and drag.ghost then drag.ghost:Destroy() end
	hideMarquee()
	hideCostTag()
	undimAll()
	clearGhost()
end

local function scheduleReselect(kind: string, pos: Vector3)
	_reselect = { kind = kind, pos = pos }
	task.delay(0.4, function()
		local want = _reselect
		if not want or not _enabled then return end
		_reselect = nil
		if want.kind == "segment" then
			local id = Snapper.nearestSegmentId(want.pos)
			if id then
				clearSelection()
				_selSegId = id
			end
		elseif want.kind == "node" then
			local id = Snapper.nearestNodeId(want.pos, NODE_RESELECT_R)
			if id then
				clearSelection()
				_selNodeIds = { id }
			end
		end
	end)
end

local function commitDrag(drag: Drag)
	local target = drag.lastTarget or terrainPoint()
	if not target then return end
	local start = drag.start
	if start and drag.rot == 0
		and Vector3.new(target.X - start.X, 0, target.Z - start.Z).Magnitude < MIN_DRAG then
		return
	end

	if drag.kind == "cp" then
		local seg = if _cpSegId then Snapper.getSegmentInfo(_cpSegId) else nil
		if not (seg and _moveRemote) then return end
		local oneSided = _manipulation or _selSegId == nil
		local reselectAt: Vector3
		if oneSided then
			local cp = if drag.cpIndex == 1 then seg.p1 else seg.p2
			local moved = Vector3.new(target.X, cp.Y, target.Z)
			local n1 = if drag.cpIndex == 1 then moved else seg.p1
			local n2 = if drag.cpIndex == 2 then moved else seg.p2
			_moveRemote:FireServer({ kind = "handles", id = seg.id, p1 = n1, p2 = n2 })
			reselectAt = BezierUtil.point(seg.p0, n1, n2, seg.p3, 0.5)
		else
			_moveRemote:FireServer({ kind = "segment", id = seg.id, target = target })
			reselectAt = target -- the bent curve passes through the drag point
		end
		-- Curve reshapes rebuild the segment under a NEW id server-side
		-- (modifySegment = remove + place), so re-acquire by position. A node edit
		-- keeps the node selected instead (re-acquire it -- its id may change too).
		if _selSegId then
			scheduleReselect("segment", reselectAt)
		elseif #_selNodeIds == 1 then
			local np = Snapper.getNodePos(_selNodeIds[1])
			if np then scheduleReselect("node", np) end
		end
		return
	end

	if drag.kind == "object" then
		local obj = drag.obj
		if not (obj and obj.model.Parent) then return end
		local pivot = CFrame.new(target) * CFrame.Angles(0, drag.ghostYaw, 0)
		if obj.kind == "Nature" then
			if _moveNatureRemote then
				_moveNatureRemote:FireServer({ { inst = obj.model, pos = target, yaw = drag.ghostYaw } })
			end
		elseif _moveServiceRemote then
			_moveServiceRemote:FireServer(obj.kind, obj.id, pivot)
		end
		return
	end

	if drag.kind ~= "group" then return end
	local pivot = drag.pivot
	if not (pivot and start) then return end
	local delta = target - start
	-- The ring goes as ONE object: the server translates every arc rigidly and stretches the
	-- arms, so this sends the offset rather than a node-by-node target list.
	if drag.ringId then
		if _moveRemote then
			_moveRemote:FireServer({ kind = "roundabout", id = drag.ringId,
				delta = Vector3.new(delta.X, 0, delta.Z) })
		end
		clearSelection()
		return
	end
	local moves: { any } = {}
	for _, id in drag.groupNodes do
		local pos = Snapper.getNodePos(id)
		if pos then
			table.insert(moves, { id = id, target = groupTarget(pos, pivot, drag.rot, delta) })
		end
	end
	if #moves > 0 and _moveRemote then
		if #moves == 1 then
			_moveRemote:FireServer({ kind = "node", id = moves[1].id, target = moves[1].target })
			scheduleReselect("node", moves[1].target)
		else
			_moveRemote:FireServer({
				kind = "group", moves = moves,
				rot = if drag.rot ~= 0 then drag.rot else nil,
				pivot = if drag.rot ~= 0 then pivot else nil,
			})
		end
	end
	-- Nature props ride along (one batched, validated request).
	if #drag.groupObjects > 0 and _moveNatureRemote then
		local list: { any } = {}
		for _, obj in drag.groupObjects do
			if obj.model.Parent and #list < MAX_NATURE_BATCH then
				local cf = obj.model:GetPivot()
				local _, ry = cf:ToOrientation()
				table.insert(list, {
					inst = obj.model,
					pos = groupTarget(cf.Position, pivot, drag.rot, delta),
					yaw = ry + drag.rot,
				})
			end
		end
		if #list > 0 then
			_moveNatureRemote:FireServer(list)
		end
	end
	if #moves > 1 then
		clearSelection()
	end
end

local function endDrag()
	local drag = _drag
	if not drag then return end
	if drag.kind == "marquee" then
		local anchor = drag.startScreen
		cancelDrag()
		if anchor then
			local m = UserInputService:GetMouseLocation()
			local minP, maxP = marqueeRect(anchor, Vector2.new(m.X, m.Y))
			if (maxP - minP).Magnitude >= MARQUEE_MIN_PX then
				selectInMarquee(minP, maxP)
			end
		end
		return
	end
	commitDrag(drag)
	cancelDrag()
end

-- ---------------------------------------------------------------- toolbox --
-- Node set the Toolbox acts on: the marquee selection, or the selected segment's ends.
local function toolboxNodes(): { number }
	if #_selNodeIds > 0 then return _selNodeIds end
	local seg = if _selSegId then Snapper.getSegmentInfo(_selSegId) else nil
	if seg and seg.startNode and seg.endNode then return { seg.startNode, seg.endNode } end
	return {}
end

-- Snap every selected node back onto the heightmap (server recomputes the legs).
local function toolboxTerrainHeight()
	local remote = _moveRemote
	local nodes = toolboxNodes()
	if #nodes == 0 or not remote then return end
	local moves: { any } = {}
	for _, id in nodes do
		local pos = Snapper.getNodePos(id)
		if pos then table.insert(moves, { id = id, target = pos }) end
	end
	if #moves == 0 then return end
	if #moves == 1 then
		remote:FireServer({ kind = "node", id = moves[1].id, target = moves[1].target, snapGround = true })
	else
		remote:FireServer({ kind = "group", moves = moves, snapGround = true })
	end
	-- Moved segments rebuild under new ids server-side; a stale selection is useless.
	clearSelection()
end

-- Align every selected node to the FIRST selected node's height (Move It's
-- "To Object Height": the reference is whatever you selected first). The
-- server clamps each target to ground level.
local function toolboxObjectHeight()
	local remote = _moveRemote
	local nodes = toolboxNodes()
	if #nodes == 0 or not remote then return end
	local refPos = Snapper.getNodePos(nodes[1])
	if not refPos then return end
	local moves: { any } = {}
	for _, id in nodes do
		local pos = Snapper.getNodePos(id)
		if pos then table.insert(moves, { id = id, target = Vector3.new(pos.X, refPos.Y, pos.Z) }) end
	end
	if #moves == 0 then return end
	if #moves == 1 then
		remote:FireServer({ kind = "node", id = moves[1].id, target = moves[1].target, exactY = true })
	else
		remote:FireServer({ kind = "group", moves = moves, exactY = true })
	end
	clearSelection()
end

-- Rotate the selected node set about its centroid (same math as Q/E while dragging).
local function toolboxRotateCenter(step: number)
	local remote = _moveRemote
	local nodes = toolboxNodes()
	if #nodes < 2 or not remote then return end
	local pts: { [number]: Vector3 } = {}
	local pivot = Vector3.zero
	local count = 0
	for _, id in nodes do
		local pos = Snapper.getNodePos(id)
		if pos then pts[id] = pos; pivot += pos; count += 1 end
	end
	if count < 2 then return end
	pivot = pivot / count
	local moves: { any } = {}
	for id, pos in pts do
		table.insert(moves, { id = id, target = RoadMoveGeometry.rotateY(pos, pivot, step) })
	end
	remote:FireServer({ kind = "group", moves = moves, rot = step, pivot = pivot })
	clearSelection()
end

-- Spin each selected nature prop around its own pivot. Roads have no meaningful
-- in-place spin, so this only touches objects.
local function toolboxRotateInPlace(step: number)
	local remote = _moveNatureRemote
	if #_selObjects == 0 or not remote then return end
	local list: { any } = {}
	for _, obj in _selObjects do
		if obj.kind == "Nature" and obj.model.Parent and #list < MAX_NATURE_BATCH then
			local cf = obj.model:GetPivot()
			local _, ry = cf:ToOrientation()
			table.insert(list, { inst = obj.model, pos = cf.Position, yaw = ry + step })
		end
	end
	if #list > 0 then
		remote:FireServer(list)
	end
end

-- Step a prop's size by the gizmo's SIZE snap, converted from studs into the uniform
-- scale a nature prop actually carries -- so "1 stud" on the panel grows the prop one stud.
local function toolboxResize(dir: number)
	local remote = _moveNatureRemote
	if #_selObjects == 0 or not remote then return end
	local step = EditorGizmos.getStep("size")
	if step <= 0 then step = 0.25 end
	local list: { any } = {}
	for _, obj in _selObjects do
		if obj.kind == "Nature" and obj.model.Parent and #list < MAX_NATURE_BATCH then
			local cur = tonumber(obj.model:GetAttribute("NatureScale")) or 1
			local _, bs = obj.model:GetBoundingBox()
			-- The prop's size at scale 1, so the stud step converts to a scale step.
			local unit = math.max(bs.X, bs.Y, bs.Z) / math.max(cur, 0.01)
			local cf = obj.model:GetPivot()
			local _, ry = cf:ToOrientation()
			table.insert(list, {
				inst = obj.model, pos = cf.Position, yaw = ry,
				scale = cur + dir * step / math.max(unit, 0.01),
			})
		end
	end
	if #list > 0 then remote:FireServer(list) end
end

-- ------------------------------------------------------------------ hover --
local function pickHandle(): Grab?
	local m = UserInputService:GetMouseLocation()
	local mouse = Vector2.new(m.X, m.Y)
	local function near(pos: Vector3, px: number): boolean
		local s = worldToScreen(pos)
		return s ~= nil and (s - mouse).Magnitude <= px
	end
	local seg = if _selSegId then Snapper.getSegmentInfo(_selSegId) else nil
	if seg then
		-- Control points only: they bend the curve. End nodes are NOT grabbable from
		-- a segment selection, so it can never slide the road.
		if near(seg.p1, HANDLE_PICK_PX) then return { type = "cp" :: "cp", index = 1 } end
		if near(seg.p2, HANDLE_PICK_PX) then return { type = "cp" :: "cp", index = 2 } end
	end
	-- A single selected node exposes its own tangent handles: the near control
	-- point of each attached segment, so you can swing the angle on either side.
	if #_selNodeIds == 1 then
		local nid = _selNodeIds[1]
		for _, s in attachedSegments(nid) do
			if s.startNode == nid and near(s.p1, HANDLE_PICK_PX) then
				return { type = "cp" :: "cp", index = 1, segId = s.id }
			elseif s.endNode == nid and near(s.p2, HANDLE_PICK_PX) then
				return { type = "cp" :: "cp", index = 2, segId = s.id }
			end
		end
	end
	for _, id in _selNodeIds do
		local pos = Snapper.getNodePos(id)
		if pos and near(pos, HANDLE_PICK_PX) then
			return { type = "node" :: "node", id = id }
		end
	end
	return nil
end

local function computeHover(): Grab?
	local handle = pickHandle()
	if handle then return handle end
	local hit = groundHit()
	if not hit then return nil end
	local obj = objectFromInstance(hit.Instance)
	if obj then return { type = "object" :: "object", obj = obj } end
	local p = hit.Position
	-- A click anywhere on an already-selected prop's footprint moves the selection
	-- (generous box test), so wide canopies don't fall through to a marquee.
	local sel = selectedNatureUnderPoint(p)
	if sel then return { type = "object" :: "object", obj = sel } end
	local nat = natureUnderPoint(p)
	if nat then return { type = "object" :: "object", obj = nat } end
	if _filters.Nodes then
		local nodeId = Snapper.nearestNodeId(p, CursorRay.pickRadius(p, NODE_PICK_PX, NODE_PICK_MIN, NODE_PICK_MAX))
		if nodeId then return { type = "node" :: "node", id = nodeId } end
	end
	if _filters.Segments then
		local segId = Snapper.segmentUnderPoint(p)
		if segId then
			if segId == _selSegId then return { type = "body" :: "body" } end
			return { type = "segsel" :: "segsel", id = segId }
		end
	end
	return nil
end

-- ------------------------------------------------------------------ frame --
local function updateFrame()
	if not _enabled then return end
	if _drag then
		updateDrag()
		return
	end
	if _pending then
		local m = UserInputService:GetMouseLocation()
		local moved = (Vector2.new(m.X, m.Y) - _pending.screen).Magnitude
		if moved > DRAG_START_PX then
			local grab = _pending.grab
			_pending = nil
			beginDrag(grab)
			return
		end
	end
	_hover = computeHover()
	drawIdleScene()
end

-- ------------------------------------------------------------------ input --
local function applyClick(grab: Grab)
	-- A click that grabbed a gizmo arrow is not a click on the world behind it: without this
	-- the selection would change out from under the drag that just started.
	if EditorGizmos.isHovering() then return end
	if grab.type == "segsel" then
		clearSelection()
		_selSegId = grab.id
	elseif grab.type == "node" then
		clearSelection()
		_selNodeIds = { grab.id }
	elseif grab.type == "object" then
		clearSelection()
		_selObjects = { grab.obj }
		syncFocus()
	elseif grab.type == "marquee" then
		clearSelection()
	end
end

local function setManipulation(on: boolean)
	_manipulation = on
	local btn = _manipBtn
	if btn then btn:SetSelected(on) end
end

local function onInputBegan(input: InputObject, processed: boolean)
	if not _enabled then return end
	if Settings.pressed("Cancel", input) or Settings.pressed("Back", input) then
		if _drag then
			cancelDrag()
		elseif _pending then
			_pending = nil
		elseif hasSelection() then
			clearSelection()
		elseif Settings.pressed("Back", input) then
			RoadMoveController.setEnabled(false)
		end
		return
	end
	if Settings.pressed("MoveManipulation", input) then
		setManipulation(not _manipulation)
		return
	end
	if Settings.pressed("MoveRotateLeft", input) or Settings.pressed("MoveRotateRight", input) then
		local step = if Settings.pressed("MoveRotateLeft", input) then ROT_STEP else -ROT_STEP
		local drag = _drag
		if drag then
			if drag.kind == "object" then
				drag.ghostYaw += step
			elseif drag.kind == "group" and not drag.ringId then
				-- A circle turned about its own centre is itself: a ring drag does not rotate.
				drag.rot += step
			end
			return
		end
		-- Not dragging: spin the selected props where they stand. With no rotate ring on
		-- screen this is how a placed prop is turned, so it has to work outside a drag.
		if #_selObjects > 0 then
			toolboxRotateInPlace(step)
			return
		end
	end
	if processed then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1 and not _drag then
		local grab = _hover or { type = "marquee" :: "marquee" }
		local m = UserInputService:GetMouseLocation()
		_pending = { grab = grab, screen = Vector2.new(m.X, m.Y) }
	end
end

local function onInputEnded(input: InputObject)
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
	if _drag then
		endDrag()
	elseif _pending then
		applyClick(_pending.grab)
		_pending = nil
	end
end

-- --------------------------------------------------------------- lifecycle --
function RoadMoveController.setStateListener(fn: (enabled: boolean) -> ())
	_listener = fn
end

function RoadMoveController.setEnabled(on: boolean)
	if on == _enabled then return end
	_enabled = on
	if on then
		if _panelGui then _panelGui.Enabled = true end
	else
		cancelDrag()
		_pending = nil
		_hover = nil
		clearSelection() -- also hands the gizmo back and undims the rest
		clearGhost()
		hoverHighlight(nil)
		beginSelHighlights()
		endSelHighlights()
		if _panelGui then _panelGui.Enabled = false end
	end
	if _listener then _listener(_enabled) end
end

function RoadMoveController.isEnabled(): boolean
	return _enabled
end

-- Floating "Move It" panel -- its own draggable window, NOT the shared build
-- dock (the dock param is accepted for the bootstrap contract and ignored).
-- Header (drag to move), undo / manipulation / redo toolbar, collapsible
-- Filters (checkboxes) and Toolbox (one-shot actions on the selection).
function RoadMoveController.InitDock(_dockUnused: any)
	if _panelGui then return end
	local gui = Instance.new("ScreenGui")
	gui.Name = "MoveItPanel"
	gui.ResetOnSpawn = false
	-- Layer, not Z: Z orders siblings inside one gui, DisplayOrder ranks the guis.
	gui.DisplayOrder = Theme.Layer.Overlay + 1
	gui.Enabled = false
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	-- Only the statically-positioned panel gets the scale. The cost tag and marquee guis
	-- in this module are placed from live cursor coordinates and must stay in real px.
	HudScale.attach(gui)
	_panelGui = gui

	local root = Instance.new("Frame")
	root.Name = "Panel"
	-- Centred directly above the rail, on the same baseline as the build dock, so
	-- every tool's panel appears in the same place; it grows UP as Filters /
	-- Toolbox expand. The clearance comes from ToolRail rather than a constant of
	-- our own: this used to be a hard 124 ("bar(64) + gap(8) + moveBtn(44) +
	-- gap(8)"), measured against a bottom bar and an edge capsule that no longer
	-- exist, which left the panel floating 40px off in the corner.
	local ToolRail = require(script.Parent:WaitForChild("ToolRail"))
	root.AnchorPoint = Vector2.new(0.5, 1)
	root.Position = UDim2.new(0.5, 0, 1, -ToolRail.bottomInset())
	root.Size = UDim2.fromOffset(232, 0)
	root.AutomaticSize = Enum.AutomaticSize.Y
	root.Parent = gui
	Glass.apply(root, 14)

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 8)
	pad.PaddingBottom = UDim.new(0, 10)
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = root

	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 6)
	list.Parent = root

	-- Header: brand chip + title (panel is fixed in place).
	local header = Instance.new("TextButton")
	header.Name = "Header"
	header.AutoButtonColor = false
	header.Text = ""
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 30)
	header.LayoutOrder = 1
	header.Parent = root

	local chip = Instance.new("Frame")
	chip.Size = UDim2.fromOffset(26, 26)
	chip.Position = UDim2.fromOffset(0, 2)
	chip.BackgroundColor3 = Theme.Color.Accent
	chip.BorderSizePixel = 0
	chip.Parent = header
	local chipCorner = Instance.new("UICorner")
	chipCorner.CornerRadius = UDim.new(1, 0)
	chipCorner.Parent = chip
	local chipIcon = Instance.new("ImageLabel")
	chipIcon.BackgroundTransparency = 1
	chipIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	chipIcon.Position = UDim2.fromScale(0.5, 0.5)
	chipIcon.Size = UDim2.fromScale(0.62, 0.62)
	chipIcon.ScaleType = Enum.ScaleType.Fit
	chipIcon.Image = Icons.Move.image
	chipIcon.ImageColor3 = Theme.Color.OnAccent
	chipIcon.Parent = chip

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(34, 0)
	title.Size = UDim2.new(1, -34, 1, 0)
	title.Text = "Move It"
	title.TextColor3 = Theme.Color.Brand
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextSize = Theme.TextSize.MD
	title.FontFace = Theme.Font.Header
	title.Parent = header

	-- Toolbar: Undo | Manipulation (Alt) | Redo.
	local bar = Instance.new("Frame")
	bar.BackgroundTransparency = 1
	bar.Size = UDim2.new(1, 0, 0, 34)
	bar.LayoutOrder = 2
	bar.Parent = root
	local barList = Instance.new("UIListLayout")
	barList.FillDirection = Enum.FillDirection.Horizontal
	barList.HorizontalAlignment = Enum.HorizontalAlignment.Center
	barList.VerticalAlignment = Enum.VerticalAlignment.Center
	barList.Padding = UDim.new(0, 10)
	barList.SortOrder = Enum.SortOrder.LayoutOrder
	barList.Parent = bar

	IconButton.new({
		icon = Icons.Undo, tooltip = "Undo", parent = bar, size = 30, layoutOrder = 1,
		onClick = function()
			local r = _undoRemote
			if r then r:FireServer() end
		end,
	})
	_manipBtn = IconButton.new({
		icon = Icons.RoadBezier, tooltip = "Manipulation (Alt)", parent = bar, size = 30, layoutOrder = 2,
		onClick = function()
			setManipulation(not _manipulation)
		end,
	})
	setManipulation(false)
	IconButton.new({
		icon = Icons.Redo, tooltip = "Redo", parent = bar, size = 30, layoutOrder = 3,
		onClick = function()
			local r = _redoRemote
			if r then r:FireServer() end
		end,
	})

	local function sectionRule(order: number)
		local rule = Instance.new("Frame")
		rule.BackgroundColor3 = Theme.Color.StrokeSoft
		rule.BackgroundTransparency = 0.5
		rule.BorderSizePixel = 0
		rule.Size = UDim2.new(1, 0, 0, 1)
		rule.LayoutOrder = order
		rule.Parent = root
	end

	-- Collapsible section: click the header row to open / close the body.
	local function section(labelText: string, order: number): Frame
		local head = Instance.new("TextButton")
		head.Name = labelText .. "Header"
		head.AutoButtonColor = false
		head.BackgroundTransparency = 1
		head.Text = ""
		head.Size = UDim2.new(1, 0, 0, 24)
		head.LayoutOrder = order
		head.Parent = root

		local lbl = Instance.new("TextLabel")
		lbl.BackgroundTransparency = 1
		lbl.Size = UDim2.new(1, -20, 1, 0)
		lbl.Text = labelText
		lbl.TextColor3 = Theme.Color.Brand
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.TextSize = Theme.TextSize.SM
		lbl.FontFace = Theme.Font.Header
		lbl.Parent = head

		local chev = Instance.new("TextLabel")
		chev.BackgroundTransparency = 1
		chev.AnchorPoint = Vector2.new(1, 0)
		chev.Position = UDim2.new(1, 0, 0, 0)
		chev.Size = UDim2.fromOffset(20, 24)
		chev.Text = "\u{25BE}"
		chev.TextColor3 = Theme.Color.TextSecondary
		chev.TextSize = Theme.TextSize.SM
		-- Montserrat has no U+25BE/25B4 (renders as a tofu box); SourceSans does.
		chev.FontFace = Font.fromEnum(Enum.Font.SourceSans)
		chev.Parent = head

		local body = Instance.new("Frame")
		body.Name = labelText .. "Body"
		body.BackgroundTransparency = 1
		body.Size = UDim2.new(1, 0, 0, 0)
		body.AutomaticSize = Enum.AutomaticSize.Y
		body.LayoutOrder = order + 1
		body.Visible = false
		body.Parent = root
		local bodyList = Instance.new("UIListLayout")
		bodyList.SortOrder = Enum.SortOrder.LayoutOrder
		bodyList.Padding = UDim.new(0, 2)
		bodyList.Parent = body

		head.Activated:Connect(function()
			body.Visible = not body.Visible
			chev.Text = if body.Visible then "\u{25B4}" else "\u{25BE}"
		end)
		return body
	end

	-- Filters: what the tool may hover / grab (checkbox rows, Move It style).
	-- Unsupported filters (no such entities in this game) get no row at all.
	local FILTER_ICONS: { [string]: Icons.Icon } = {
		Buildings = Icons.Buildings,
		Plants = Icons.Landscaping,
		Props = Icons.NatureFreePlace,
		Nodes = Icons.PlotSingle,
		Segments = Icons.RoadParallel,
	}
	sectionRule(3)
	local filtersBody = section("Filters", 4)
	for i, key in FILTER_ORDER do
		if FILTER_SUPPORTED[key] then
			local row = Instance.new("TextButton")
			row.AutoButtonColor = false
			row.BackgroundColor3 = Theme.Color.BgHover
			row.BackgroundTransparency = 1
			row.Text = ""
			row.Size = UDim2.new(1, 0, 0, 24)
			row.LayoutOrder = i
			row.Parent = filtersBody
			local rc = Instance.new("UICorner")
			rc.CornerRadius = UDim.new(0, 6)
			rc.Parent = row

			local box = Instance.new("Frame")
			box.Position = UDim2.fromOffset(2, 4)
			box.Size = UDim2.fromOffset(16, 16)
			box.BackgroundColor3 = Theme.Color.BgRaised
			box.BorderSizePixel = 0
			box.Parent = row
			local bc = Instance.new("UICorner")
			bc.CornerRadius = UDim.new(0, 4)
			bc.Parent = box
			local bs = Instance.new("UIStroke")
			bs.Thickness = 1
			bs.Parent = box
			local tick = Instance.new("Frame")
			tick.AnchorPoint = Vector2.new(0.5, 0.5)
			tick.Position = UDim2.fromScale(0.5, 0.5)
			tick.Size = UDim2.fromOffset(8, 8)
			tick.BackgroundColor3 = Theme.Color.Accent
			tick.BorderSizePixel = 0
			tick.Parent = box
			local tc = Instance.new("UICorner")
			tc.CornerRadius = UDim.new(0, 2)
			tc.Parent = tick

			local ic = Instance.new("ImageLabel")
			ic.BackgroundTransparency = 1
			ic.Position = UDim2.fromOffset(26, 4)
			ic.Size = UDim2.fromOffset(16, 16)
			ic.ScaleType = Enum.ScaleType.Fit
			ic.Image = (FILTER_ICONS[key] or Icons.Move).image
			ic.ImageColor3 = Theme.Color.TextSecondary
			ic.Parent = row

			local txt = Instance.new("TextLabel")
			txt.BackgroundTransparency = 1
			txt.Position = UDim2.fromOffset(48, 0)
			txt.Size = UDim2.new(1, -48, 1, 0)
			txt.Text = FILTER_LABEL[key]
			txt.TextXAlignment = Enum.TextXAlignment.Left
			txt.TextSize = Theme.TextSize.XS
			txt.FontFace = Theme.Font.Label
			txt.Parent = row

			local function refresh()
				local on = _filters[key]
				tick.Visible = on
				bs.Color = if on then Theme.Color.Accent else Theme.Color.StrokeSoft
				txt.TextColor3 = if on then Theme.Color.TextPrimary else Theme.Color.TextSecondary
			end
			refresh()
			row.MouseEnter:Connect(function() row.BackgroundTransparency = 0.7 end)
			row.MouseLeave:Connect(function() row.BackgroundTransparency = 1 end)
			row.Activated:Connect(function()
				_filters[key] = not _filters[key]
				refresh()
			end)
		end
	end

	-- Toolbox: one-shot actions on the current selection.
	sectionRule(6)
	local toolboxBody = section("Toolbox", 7)
	local function toolRow(labelText: string, ico: Icons.Icon, order: number, onClick: () -> ())
		local row = Instance.new("TextButton")
		row.AutoButtonColor = false
		row.BackgroundColor3 = Theme.Color.BgHover
		row.BackgroundTransparency = 1
		row.Text = ""
		row.Size = UDim2.new(1, 0, 0, 24)
		row.LayoutOrder = order
		row.Parent = toolboxBody
		local rc = Instance.new("UICorner")
		rc.CornerRadius = UDim.new(0, 6)
		rc.Parent = row
		local accent = Instance.new("Frame")
		accent.BackgroundColor3 = Theme.Color.Brand
		accent.BorderSizePixel = 0
		accent.Position = UDim2.fromOffset(0, 3)
		accent.Size = UDim2.fromOffset(2, 18)
		accent.Parent = row
		local ic = Instance.new("ImageLabel")
		ic.BackgroundTransparency = 1
		ic.Position = UDim2.fromOffset(8, 4)
		ic.Size = UDim2.fromOffset(16, 16)
		ic.ScaleType = Enum.ScaleType.Fit
		ic.Image = ico.image
		ic.ImageColor3 = Theme.Color.TextSecondary
		ic.Parent = row
		local txt = Instance.new("TextLabel")
		txt.BackgroundTransparency = 1
		txt.Position = UDim2.fromOffset(32, 0)
		txt.Size = UDim2.new(1, -32, 1, 0)
		txt.Text = labelText
		txt.TextColor3 = Theme.Color.TextPrimary
		txt.TextXAlignment = Enum.TextXAlignment.Left
		txt.TextSize = Theme.TextSize.XS
		txt.FontFace = Theme.Font.Label
		txt.Parent = row
		row.MouseEnter:Connect(function() row.BackgroundTransparency = 0.7 end)
		row.MouseLeave:Connect(function() row.BackgroundTransparency = 1 end)
		row.Activated:Connect(onClick)
	end
	toolRow("To Terrain Height", Icons.TerrainFlatten, 1, toolboxTerrainHeight)
	toolRow("To Object Height", Icons.Height, 2, toolboxObjectHeight)
	toolRow("Rotate at Center", Icons.RoadRoundabout, 3, function()
		toolboxRotateCenter(ROT_STEP)
	end)
	toolRow("Rotate in-Place", Icons.Undo, 4, function()
		toolboxRotateInPlace(ROT_STEP)
	end)
	toolRow("Bigger", Icons.Height, 5, function() toolboxResize(1) end)
	toolRow("Smaller", Icons.Height, 6, function() toolboxResize(-1) end)
end

function RoadMoveController.Init()
	if _inited then return end
	_inited = true
	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	_moveRemote = Net.RequestMoveRoad
	_moveServiceRemote = Net.RequestMoveService
	_moveNatureRemote = Net.RequestMoveNature
	_undoRemote = Net.RequestUndoRoad
	_redoRemote = Net.RequestRedoRoad
end

function RoadMoveController.Bind()
	if _bound then return end
	_bound = true
	_renderConn = RunService.RenderStepped:Connect(updateFrame)
	_inputConn = UserInputService.InputBegan:Connect(onInputBegan)
	_upConn = UserInputService.InputEnded:Connect(onInputEnded)
end

function RoadMoveController.Unbind()
	if _renderConn then _renderConn:Disconnect() _renderConn = nil end
	if _inputConn then _inputConn:Disconnect() _inputConn = nil end
	if _upConn then _upConn:Disconnect() _upConn = nil end
	_bound = false
end

function RoadMoveController.Cleanup()
	RoadMoveController.setEnabled(false)
	RoadMoveController.Unbind()
	for _, c in _panelConns do c:Disconnect() end
	table.clear(_panelConns)
	if _panelGui then _panelGui:Destroy(); _panelGui = nil end
	_manipBtn = nil
	if _marqueeGui then _marqueeGui:Destroy(); _marqueeGui = nil; _marqueeFrame = nil end
	if _folder then _folder:Destroy(); _folder = nil end
	table.clear(_pool)
	_beamAnchor = nil
	table.clear(_beams)
	table.clear(_atts)
	_beamN = 0
	_attN = 0
	_beamHigh = 0
	_hoverHL = nil
	table.clear(_selHLs)
	_inited = false
end

return RoadMoveController
