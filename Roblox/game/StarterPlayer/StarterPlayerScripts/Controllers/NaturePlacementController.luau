--!strict
-- NaturePlacementController
-- The Nature tab's placement tool. Four gestures to plant trees / bushes / rocks:
--   Line       -- road-helper style: click a start, click an end, and a row is stamped at
--                 the chosen spacing (offset between each).
--   Brush      -- hold LMB and sweep to scatter props within a brush radius.
--   Single     -- one click, one prop, right where you clicked.
--   Curve      -- road-"Curved"-tool style: click a start, click a bend point, click an
--                 end; the three clicks become a cubic bezier (BezierUtil, shared with
--                 the road system) and props are stamped along it at the same spacing as
--                 Line.
-- Free Placement is a separate, independent on/off toggle -- NOT a 5th gesture -- that
-- layers on top of any of the four above (see ReplicatedStorage.Shared.FreePlacement).
-- While on, roads/buildings stop tinting the ghost red (isNearRoadPreview reads the shared
-- flag directly) AND every item this tool sends is stamped free = true, which is what makes
-- the server drop its road/building exclusion (see fireItems). Both halves matter: without
-- the stamp the ghost went green and the server refused the placement anyway.
-- Every placement gets its own random yaw + a small height (scale) variation, so no two
-- look identical. The palette is either one asset or a random mix of the ticked assets.
-- SHAPES are the exception: a primitive is a building block, so it goes down at the exact
-- size on the panel's stepper and at yaw 0 -- random sizes and angles are the last thing
-- you want when you are lining a wall up. Grid snap (the game-wide PlacementGrid, shared
-- with every other placement tool) and Stack sit on top of that.
-- The server (NaturePlaceService) is authoritative: it validates, ground-snaps and caps;
-- the client sends the same yaw/scale it previewed so the result matches.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage:WaitForChild("Networker"))
local NatureCatalog = require(ReplicatedStorage:WaitForChild("Nature"):WaitForChild("NatureCatalog"))
local SoundFX = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("SoundFX"))
-- The independent Free Placement toggle's own state -- shared beyond Nature (see that
-- module's header) so Roads/Zoning/Buildings can read the same flag later.
local FreePlacement = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("FreePlacement"))
local PlacementFit = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlacementFit"))
-- Shared cubic-bezier math -- the same module the road tool's Curved/Bezier modes use.
-- Pure geometry (4 control points in, point/tangent out); no road-network dependency.
local BezierUtil = require(ReplicatedStorage:WaitForChild("Road"):WaitForChild("BezierUtil"))
-- Where a row of things goes: straight rows and arc-length-even points along a bezier.
-- Shared with the Creations tool, which offers the same three gestures -- two copies of
-- this would drift, and the symptom would be a line of creations and a line of trees
-- quietly disagreeing about spacing.
local GesturePath = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GesturePath"))
-- The road-proximity rule itself, shared with the server: RoadService.isPointNearRoad and
-- the preview below are now literally the same function, so the ghost's colour cannot
-- disagree with what the server accepts.
local RoadProximity = require(ReplicatedStorage:WaitForChild("Road"):WaitForChild("RoadProximity"))
-- Car-park snapping needs the host road's width and the footway beside it, so the lot's
-- near edge lands on the back of the pavement rather than in the gutter.
local RoadTypeCatalog = require(ReplicatedStorage:WaitForChild("Road"):WaitForChild("RoadTypeCatalog"))
local RoadConstants = require(ReplicatedStorage:WaitForChild("Road"):WaitForChild("RoadConstants"))
local DataCache = require(ReplicatedStorage:WaitForChild("DataCache"))
local Theme = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("Theme"))
local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))
local CursorRay = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("CursorRay"))
-- The game-wide placement grid. Nature drives its own ghosts, so it borrows the snap.
local PlacementGrid = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlacementGrid"))
-- Precise mode: the gizmo that lands on whatever you just placed. Shared with the Move
-- tool, which puts the same handles on whatever you select.
local NatureGizmo = require(script.Parent:WaitForChild("NatureGizmo"))
local MaterialCatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MaterialCatalog"))
-- For the move snap step only: the grid a placement lands on is the SAME one the transform
-- handles use, or the first click and the first nudge disagree about where the grid is.
local EditorGizmos = require(script.Parent:WaitForChild("EditorGizmos"))
local UiScratch = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("UiScratch"))

local NaturePlacementController = {}

export type Mode = "Line" | "Brush" | "Single" | "Curve"

local MAX_ROW = 64          -- must not exceed NaturePlaceService.MAX_PER_CALL
local PAINT_INTERVAL = 0.1   -- brush scatter cadence (>= server cooldown)
local PAINT_PER_TICK = 3     -- props attempted per brush tick
local STROKE_MEMORY = 300    -- how many stroke positions we keep for min-gap tests
local ACCENT = Color3.fromRGB(120, 200, 130)
local MONEY_GREEN = Color3.fromRGB(108, 198, 118) -- same green as the treasury readout

local _enabled = false
local _inited = false
local _bound = false
local _mode: Mode = "Single"
local _spacing = 20
local _brushRadius = 24
local _randomize = false
-- The exact multiplier a Shape is placed at, and whether a placement seats on top of what
-- is already there instead of on the terrain. Both are Nature-panel controls.
local _placeScale = 1
local _stack = false
-- nil keeps each template's own colours (green trees, grey stone). A Color3 repaints the
-- whole prop, which is what the Shapes palette is for.
local _placeColor: Color3? = nil
-- 0 is "the template's own material", the same "leave it alone" default as a nil colour.
local _placeMaterial = 0
local _placeCollide = true
-- 0 is solid. Stamped on every placement like material; the server clamps it to 0..0.9.
local _placeTransparency = 0
-- Extra yaw on WHATEVER IS ON THE CURSOR, from a right-drag. Applied on top of each item's
-- own angle at draw and at commit rather than folded into the cursor plan, so a randomised
-- tree does not re-roll its jitter every frame you turn it.
local _ghostYaw = 0
-- Height on what is ABOUT to be placed, in studs above the ground it lands on. The
-- elevation buttons drive the master when there is one and this when there is not -- lifting
-- what you are holding is not a precise-only idea, and until now the only way to do it was
-- to place something first and then go and find the handles.
local _placeYOffset = 0
-- What a CUT or a COPY hands back: one placed prop's whole look, plus its place in the
-- arrangement it came from -- where it sits relative to the set's centre, which way it
-- faces, and how high it rode above the ground.
export type StampItem = {
	key: string,
	scale: number?,
	color: Color3?,
	material: number?,
	collide: boolean?,
	stretch: Vector3?,
	transparency: number?,
	dx: number,
	dz: number,
	yaw: number,
	pitch: number,
	roll: number,
	yOffset: number,
}
-- What NatureSelection.lookOf reads off a placed prop.
export type Look = {
	key: string, scale: number, color: Color3?, material: number?,
	collide: boolean?, stretch: Vector3?, transparency: number?,
}
-- Several props held as ONE placeable. Set by `armStamp`, and mutually exclusive with a
-- ticked catalog card: whichever was armed last is what the cursor carries.
local _stamp: { StampItem }? = nil

-- The transform the cursor ghost is showing. Fixed once so the preview and the placement
-- cannot disagree; cleared whenever anything that feeds it changes.
local _cursorPlan: { key: string, scale: number, yaw: number }? = nil
-- Precise mode: after a single placement, put the transform gizmo straight onto the prop
-- that just landed, so nudging it does not mean hunting for another tool first.
local _precise = false
-- Master manipulation WITHOUT the handles -- which is what precise mode turned off means.
-- Left drag slides it along the ground on the same grid a placement lands on, right drag
-- turns it on the rotate snap, and the elevation keys lift it. Precise adds the gizmo on
-- top; none of this goes away when it does.
local ROT_PER_PIXEL = 0.6 -- degrees of yaw per pixel, same feel as GhostPlacement's
local _rightDrag: { x: number, turned: boolean }? = nil
local _changedConn: RBXScriptConnection? = nil

-- The tool used to PARK after a precise placement -- no ghost, no cost tag, every click
-- swallowed -- because the next click would otherwise stamp a second prop on the first
-- one's head. That cost you the selection: to plant another you had to re-pick the card.
-- The gizmo already knows when the cursor is on one of its grips, so the tool simply asks,
-- and a click that missed the handles plants another prop with the card still lit.

-- Template footprints, keyed by shape. One GetBoundingBox per key rather than per frame:
-- the snap and the stack preview both want this every RenderStepped.
local _extentCache: { [string]: Vector2 } = {}
local function templateExtents(key: string): Vector2?
	local hit = _extentCache[key]
	if hit then return hit end
	local t = ReplicatedStorage.Nature:FindFirstChild(key)
	if not (t and t:IsA("Model")) then return nil end
	local _, size = (t :: Model):GetBoundingBox()
	local v = Vector2.new(size.X, size.Z)
	_extentCache[key] = v
	return v
end

-- How far a prop reaches UP from its base, same one-lookup-per-key deal: the road test
-- needs it every frame under a live ghost (RoadProximity.reachesLayer).
local _heightCache: { [string]: number } = {}
local function templateHeight(key: string): number?
	local hit = _heightCache[key]
	if hit then return hit end
	local t = ReplicatedStorage.Nature:FindFirstChild(key)
	if not (t and t:IsA("Model")) then return nil end
	local _, size = (t :: Model):GetBoundingBox()
	_heightCache[key] = size.Y
	return size.Y
end

-- _selected is the set (fast membership test); _selectedOrder is the same keys in the
-- order they were checked (oldest first). The order array is what "keep the first-checked
-- one" (when Randomize flips off) and "nothing ticked yet" (auto-pick) both key off of --
-- a plain unordered set can't answer either question.
local _selected: { [string]: boolean } = {}
local _selectedOrder: { string } = {}
-- Fires after ANY change to _selected/_selectedOrder, including the silent auto-pick
-- inside pickKey() -- that path has no UI code on its call stack to follow up with a
-- refresh itself (it runs from RenderStepped/InputBegan, not from a card's onClick), so
-- the controller has to announce the change on its own. Mirrors RoadPlacementController's
-- _listener/notify()/setStateListener shape.
local _listener: (() -> ())? = nil

local _lineStart: Vector3? = nil
local _painting = false
local _paintAccum = 0
local _strokePlaced: { Vector3 } = {}

-- Curve gesture: start -> bend ("curve") -> end, exactly like the road tool's Curved
-- mode. _curveStart/_curveBend mirror RoadPlacementController's _start/_curve.
local _curveStart: Vector3? = nil
local _curveBend: Vector3? = nil

local _folder: Folder? = nil
local _ghost: Model? = nil
local _ghostKey: string? = nil
local _ring: Part? = nil
-- Line/Curve preview: one translucent tree ghost per row point. _rowPlan fixes each
-- index's asset + scale + yaw so the preview is stable (it only appends as the row grows),
-- and the committed placement reuses the exact same plan -- what you see is what gets planted.
local _rowPlan: { { key: string, scale: number, yaw: number } } = {}
local _ghosts: { Model } = {}
local _ghostN = 0
-- Curve-only: small marker parts tracing the sampled bezier, plus a dot at the clicked
-- start/bend so the gesture reads clearly before the first ghost tree appears.
local _curveMarkers: { Part } = {}
local _curveMarkerN = 0
local _curveDots: { Part } = {}
local _curveDotN = 0
local _renderConn: RBXScriptConnection? = nil
local _beganConn: RBXScriptConnection? = nil
local _endedConn: RBXScriptConnection? = nil

-- Nature opens with NOTHING ticked, and stays that way until the player picks a card:
-- every tab change clears the palette, so an empty one is the normal state and a click
-- on it places nothing.

-- ---------------------------------------------------------------- helpers
local function ensureFolder(): Folder
	if _folder and _folder.Parent then return _folder end
	local f = UiScratch.folder("NaturePlacement")
	_folder = f
	return f
end

-- Plants go on bare terrain, so this is the terrain-only pick from Core.CursorRay, put
-- through the game-wide PlacementGrid -- the same world lattice the service buildings, the
-- move handles and road drawing use, so things placed by different tools line up.
-- mouseGround() feeds both the ghost and the placement, so the preview shows exactly where
-- it will land.
--
-- "Tile shapes edge to edge" swaps that for a lattice the size of the SHAPE itself: the
-- point of lining primitives up is that consecutive ones end up flush, and a 4-stud block
-- on a 10-stud grid leaves a gap between every pair. Cell CENTRES, so a part fills its
-- cell instead of straddling four.
local _tileShapes = false
local function snapPoint(p: Vector3): Vector3
	if _tileShapes then
		-- _selectedOrder[1] rather than firstSelected(): this runs above the selection helpers.
		local key = _selectedOrder[1]
		local entry = if key then NatureCatalog.get(key) else nil
		if entry and entry.kind == "Shape" and key then
			local ext = templateExtents(key)
			if ext then
				local g = math.max(ext.X, ext.Y) * math.clamp(_placeScale, entry.minScale, entry.maxScale)
				if g > 0.05 then
					return Vector3.new((math.floor(p.X / g) + 0.5) * g, p.Y, (math.floor(p.Z / g) + 0.5) * g)
				end
			end
		end
	end
	return PlacementGrid.snap(p)
end

local function mouseGround(): Vector3?
	local p = CursorRay.terrainPoint()
	return if p then snapPoint(p) else nil
end

-- ------------------------------------------------------------ selection state
-- Every mutation to _selected goes through one of these three, so _selectedOrder can
-- never drift out of sync with the set it mirrors.
local function selectAdd(key: string)
	if _selected[key] then return end -- already in, and therefore already in the order array
	_selected[key] = true
	_selectedOrder[#_selectedOrder + 1] = key
end

local function deselect(key: string)
	if not _selected[key] then return end
	_selected[key] = nil
	for i, k in _selectedOrder do
		if k == key then table.remove(_selectedOrder, i); break end
	end
end

-- Radio-button select: key becomes the ONLY selected asset. Used when Randomize is off,
-- where ticking a card swaps the palette rather than adding to it.
local function selectOnly(key: string)
	table.clear(_selected)
	table.clear(_selectedOrder)
	_selected[key] = true
	_selectedOrder[1] = key
end

-- The palette belongs to whichever tab is showing it. Switching tab or tool drops it, or a
-- click places what the cards on screen do not show (a car park from the Nature tab).
local function clearAllSelected()
	table.clear(_selected)
	table.clear(_selectedOrder)
end

-- Randomize OFF collapses a multi-selection down to just the first-checked asset
-- (oldest entry in _selectedOrder), dropping the rest. A no-op if 0 or 1 are selected.
local function collapseToFirstSelected()
	if #_selectedOrder <= 1 then return end
	selectOnly(_selectedOrder[1])
end

local function orderedSelected(): { string }
	-- _selectedOrder already IS this list (checked-order); NatureCatalog.order is not the
	-- right sort here since the player's check order is what "first selected" means.
	return table.clone(_selectedOrder)
end

local function notify()
	if _listener then _listener() end
end

local function firstSelected(): string?
	return _selectedOrder[1]
end

-- Nothing ticked means nothing to place. There used to be a fallback to the first catalog
-- asset here; with the palette cleared on every tab change that fallback planted a tree
-- from the Rocks shelf.
local function pickKey(): string?
	if #_selectedOrder == 0 then return nil end
	if _randomize then return _selectedOrder[math.random(#_selectedOrder)] end
	return _selectedOrder[1]
end

-- Per-placement variation: random yaw + a height (uniform scale) inside the catalog range.
-- A Shape takes the stepper's size verbatim and no rotation -- see the header. The clamp
-- is the server's own (NaturePlaceService.plantOne), applied here too so the ghost is the
-- size that actually lands.
local function jitter(key: string): (number, number)
	local e = NatureCatalog.get(key)
	if not e then return 1, 0 end
	-- A shape is a building block, and Randomize off means "place what I asked for": both
	-- take the stepper's size and no rotation. Only Randomize on rolls a size and an angle,
	-- which is what makes a scattered wood look like a wood rather than a stamp.
	-- A car park is a building block too: a randomly rotated, randomly sized lot is never
	-- what anyone asked for.
	if e.kind == "Shape" or e.kind == "Lot" or not _randomize then
		return math.clamp(_placeScale, e.minScale, e.maxScale), 0
	end
	local scale = e.minScale + math.random() * (e.maxScale - e.minScale)
	local yaw = math.random() * math.pi * 2
	return math.clamp(scale * _placeScale, e.minScale, e.maxScale), yaw
end

-- Even points from a to b along the ground plane at _spacing (offset). Capped at MAX_ROW.
local function sampleRow(a: Vector3, b: Vector3): { Vector3 }
	return GesturePath.row(a, b, _spacing, MAX_ROW)
end

-- ------------------------------------------------------------------ curve
-- Turn the 3 clicked points (start, bend, end) into a cubic bezier's 4 control points.
local curveControlPoints = GesturePath.controlPoints

-- Even points along the bezier's ARC LENGTH (not its parameter t, which would bunch
-- points up on the tight part of the bend) at _spacing. Capped at MAX_ROW, same contract
-- as sampleRow.
local function sampleCurve(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3): { Vector3 }
	return GesturePath.curve(p0, p1, p2, p3, _spacing, MAX_ROW)
end

-- ------------------------------------------------------- road preview check
-- The red/blocked ghost tint. This used to be a hand-maintained copy of
-- RoadService.isPointNearRoad carrying the instruction "mirrors it exactly" -- two bodies
-- that had to be edited in lockstep forever, and when they drifted the ghost went green on
-- a placement the server then silently refused. Both sides now call RoadProximity; the only
-- difference left is the segment source (the replicated mirror here, the live network there).
--
-- Roads only, on purpose: buildings and other props are blockedByOverlap's half of the
-- same tint, asked through PlacementFit. The two together are exactly what plantOne
-- refuses, so there is no longer any way to click on a green ghost and get nothing.
--
-- footprintRadius must be entry.radius * scale, matching NaturePlaceService.plantOne.
-- When the shared FreePlacement flag is on this always reports false: the player has said
-- "stop warning me," so the tint is suppressed even though the server-side rule is
-- unchanged for anything NOT flagged free -- fireItems stamps the flag on the way out, so
-- the ghost and the server now agree again.
local function isNearRoadPreview(pos: Vector3, footprintRadius: number, height: number): boolean
	if FreePlacement.isEnabled() then return false end
	return RoadProximity.isPointNearRoad(DataCache.GetSegments(), pos, footprintRadius, height)
end

-- ------------------------------------------------------------------ car parks
-- A car park is street furniture, not a shrub: dropped anywhere near a road it should sit
-- SQUARE against that kerb with its open (+Z) side -- the gap in the kerb ring the cars
-- drive in through -- facing the street. The cursor point is projected onto the nearest
-- road's centreline and the lot is pushed out past the carriageway and the footway on
-- whichever side the cursor is, so it slides along the kerb as the mouse moves instead of
-- landing at a random angle in the middle of a field.
--
-- Free Placement turns this off, same as it turns off every other rule: that toggle means
-- "stop deciding things for me".
local LOT_SNAP_RANGE = 90
local function lotSnap(point: Vector3, key: string, scale: number): (Vector3?, number?)
	if FreePlacement.isEnabled() then return nil, nil end
	local bestD2 = LOT_SNAP_RANGE * LOT_SNAP_RANGE
	local bestFoot: Vector3? = nil
	local bestTan: Vector3? = nil
	local bestSpec: any = nil
	for _, seg in DataCache.GetSegments() do
		local t = BezierUtil.closestParam(seg.p0, seg.p1, seg.p2, seg.p3, point, RoadConstants.SNAP_SEGMENT_SAMPLES)
		local foot = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
		local dx, dz = foot.X - point.X, foot.Z - point.Z
		local d2 = dx * dx + dz * dz
		if d2 < bestD2 then
			local tan = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, t)
			local flat = Vector3.new(tan.X, 0, tan.Z)
			if flat.Magnitude > 1e-4 then
				bestD2 = d2
				bestFoot = foot
				bestTan = flat.Unit
				bestSpec = RoadTypeCatalog.getOrDefault(seg.roadType)
			end
		end
	end
	local foot, tan = bestFoot, bestTan
	if not (foot and tan) then return nil, nil end
	local ext = templateExtents(key)
	local depth = (if ext then ext.Y else 32) * scale
	-- Lateral unit vector pointing from the road out to the side the cursor is on. Exactly
	-- on the centreline it falls back to the left kerb rather than dividing by zero.
	local right = Vector3.new(-tan.Z, 0, tan.X)
	local lateral = (point - foot):Dot(right)
	local outward = if lateral < 0 then -right else right
	-- Where the lot's front edge stops: against the FOOTWAY where this side of the street has
	-- one, and against the carriageway itself where it does not (an alley, or a street with
	-- its pavement only on the far kerb). Either way it butts up to something -- the old fixed
	-- sidewalk allowance left a lot parked on grass a footway short of a kerbless road.
	-- RoadRenderer builds its sidewalks off this same lateral vector and calls +side the RIGHT
	-- kerb, so the cursor side is "right" exactly when outward is +right.
	local mode = bestSpec.sidewalkMode or (if bestSpec.noSidewalk then "none" else "both")
	local onRight = lateral >= 0
	local hasWalk = mode == "both" or (mode == "right" and onRight) or (mode == "left" and not onRight)
	local edge = bestSpec.width * 0.5 + (if hasWalk then RoadConstants.SIDEWALK_WIDTH else 0)
	local pos = Vector3.new(foot.X, point.Y, foot.Z) + outward * (edge + depth * 0.5)
	-- The lot's +Z has to end up pointing back at the road, and CFrame.Angles(0, yaw, 0)
	-- sends +Z to (sin yaw, 0, cos yaw).
	local face = -outward
	return pos, math.atan2(face.X, face.Z)
end

-- Where a single placement actually lands: the cursor point and the plan's own yaw, with a
-- car park snapped to the kerb. One function, so the ghost and the click cannot disagree.
-- The third return is "this cannot go here": a car park with no road within snapping range
-- is a car park nobody can drive into, so it previews red and the click does nothing.
local function resolvePlacement(point: Vector3, plan: { key: string, scale: number, yaw: number }): (Vector3, number, boolean)
	local e = NatureCatalog.get(plan.key)
	if e and e.kind == "Lot" then
		local pos, yaw = lotSnap(point, plan.key, plan.scale)
		if pos and yaw then return pos, yaw, false end
		return point, plan.yaw, not FreePlacement.isEnabled()
	end
	return point, plan.yaw, false
end

-- ---------------------------------------------------------------- preview
-- A translucent clone of an asset at a given scale (same maths as the real placement),
-- parented into the preview folder. Shared by the row ghosts and the cursor ghost.
-- A shape primitive is a Model wrapping ONE BasePart, which is the thing a stretch acts on.
-- Same test EditorGizmos and NaturePlaceService make; a multi-part model has no single part
-- to stretch and is left alone.
local function solePart(model: Model): BasePart?
	local found: BasePart? = nil
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			if found then return nil end
			found = d :: BasePart
		end
	end
	return found
end

-- `look` overrides the tool's current colour for this one clone, and is the ONLY source of a
-- stretch. A stamp is a set of props that each brought their own, so they cannot all read the
-- module's fields -- and a stretch has no tool-wide setting at all, because the only way to
-- get a stretched prop is to have stretched one with the handles and cut it.
local function translucentClone(key: string, scaleMul: number,
	look: { color: Color3?, stretch: Vector3?, material: number?, transparency: number? }?): Model?
	local template = ReplicatedStorage.Nature:FindFirstChild(key)
	if not (template and template:IsA("Model")) then return nil end
	local color = if look then look.color else _placeColor
	local stretch = if look then look.stretch else nil
	-- The ghost wears the material and the see-through too: it IS the material preview.
	local matIdx = if look then look.material else _placeMaterial
	local mat = if matIdx and matIdx > 0 then MaterialCatalog.get(matIdx) else nil
	local fade = math.max(0.5, (if look then look.transparency else _placeTransparency) or 0)
	local g = template:Clone()
	g:ScaleTo(g:GetScale() * scaleMul)
	for _, d in g:GetDescendants() do
		if d:IsA("BasePart") then
			d.Transparency = math.max(d.Transparency, fade)
			if mat then d.Material = mat :: Enum.Material end
			d.CanCollide = false; d.CanQuery = false; d.CanTouch = false; d.Anchored = true; d.CastShadow = false
			-- Painted BEFORE setGhostBlocked ever runs, so the colour it caches as this
			-- ghost's "normal" is the one the placement will actually get.
			if color then d.Color = color :: Color3 end
		end
	end
	-- The ghost wears the stretch too, or a copied twelve-stud beam previews as a cube and
	-- lands as a beam. Re-seat the pivot on the part's new base exactly as the server's
	-- applyStretch does, or the preview floats by half of whatever it grew.
	local part = if stretch then solePart(g) else nil
	if stretch and part then
		local p = part :: BasePart
		p.Size = p.Size * (stretch :: Vector3)
		g.WorldPivot = CFrame.new(p.CFrame.Position - p.CFrame.UpVector * (p.Size.Y * 0.5))
			* g:GetPivot().Rotation
	end
	g.Parent = ensureFolder()
	return g
end

-- Blocked/normal tint for a ghost: recolors every BasePart toward Theme.Color.Danger
-- when `blocked`, or restores each part's OWN original color (cached as an attribute
-- the first time this runs on that part, since the template's real per-part colors
-- vary and we can't just hardcode one "normal" color to restore). Idempotent: calling
-- this repeatedly with the same `blocked` value is a cheap no-op after the first pass
-- other than the Color assignment itself, which Roblox already no-ops if unchanged.
local function setGhostBlocked(model: Model, blocked: boolean)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			local orig = d:GetAttribute("GOrigColor")
			if orig == nil then
				orig = d.Color
				d:SetAttribute("GOrigColor", orig)
			end
			d.Color = if blocked then Theme.Color.Danger else (orig :: Color3)
		end
	end
end

local function groundY(x: number, z: number): number?
	return CursorRay.terrainY(x, z)
end

local function natureFolder(): Instance?
	local city = Workspace:FindFirstChild("_City")
	return city and city:FindFirstChild("Nature")
end

-- Where a placement lands: the top of whatever the cursor is OVER, else the terrain.
-- Mirrors NaturePlaceService.surfaceTopY -- including its AUTO-STACK, which is why a shape
-- with collisions on climbs a block instead of sinking into it or being refused.
local STACK_EPS = 0.05
local function placeY(x: number, z: number, key: string?, scale: number?,
	collide: boolean?, stretch: Vector3?): number?
	local e = if key then NatureCatalog.get(key) else nil
	local autoStack = e ~= nil and e.kind == "Shape"
		and (if collide ~= nil then collide else _placeCollide)
		and not FreePlacement.isEnabled()
	if (_stack or autoStack) and key then
		local nature = natureFolder()
		if nature then
			-- Auto-stack asks "what would this LAND on", so it tests the whole footprint at the
			-- size it will actually be. The Stack TOGGLE asks "what am I pointing at" and stays
			-- a point probe (hx = hz = 0, strict edge). Testing only the centre is what let a
			-- block sit half inside its neighbour with collisions supposedly on.
			local hx, hz, eps = 0, 0, 0
			if autoStack then
				local ext = templateExtents(key)
				local st = stretch or Vector3.one
				local s = scale or 1
				hx = if ext then ext.X * 0.5 * s * st.X else 0
				hz = if ext then ext.Y * 0.5 * s * st.Z else 0
				eps = STACK_EPS
			end
			local best: number? = nil
			for _, m in nature:GetChildren() do
				if m:IsA("Model") then
					local cf, size = m:GetBoundingBox()
					if math.abs(cf.Position.X - x) < hx + size.X * 0.5 - eps
						and math.abs(cf.Position.Z - z) < hz + size.Z * 0.5 - eps then
						local top = cf.Position.Y + size.Y * 0.5
						if not best or top > best then best = top end
					end
				end
			end
			if best then return best end
		end
	end
	return groundY(x, z)
end

-- The ghost's red tint, and the reason a click can do nothing: a BUILDING or another PROP
-- is already standing there. Both questions are PlacementFit's, which is the module (and
-- the answer) NaturePlaceService validates with -- so the ghost cannot go green on a
-- placement the server then silently drops, which is how "no tree on that house" used to
-- read as the game ignoring your click.
-- Free Placement switches the whole test off: that toggle means "stop deciding things for
-- me", and fireItems stamps the same flag so the server drops the rule for these items too.
local OVERLAP_EPS = 0.05
local function blockedByOverlap(x: number, y: number, z: number, key: string, scale: number): boolean
	if FreePlacement.isEnabled() then return false end
	local e = NatureCatalog.get(key)
	local ext = templateExtents(key)
	if not (e and ext) then return false end
	local h = (templateHeight(key) or 4) * scale
	local pivot = CFrame.new(x, y, z)

	-- A car park is a building-sized slab, so it is judged on its real rectangle rather
	-- than on a footprint circle, and it may not sit inside ANY prop -- two of them in the
	-- same field of grass reads as a bug. Roads are exempt: isNearRoadPreview already owns
	-- that, deliberately loosely, so a lot may sit against the kerb it is served from.
	if e.kind == "Lot" then
		local hx, hz = ext.X * 0.5 * scale, ext.Y * 0.5 * scale
		if not PlacementFit.boxFree(pivot, Vector3.new(hx * 2, h, hz * 2), PlacementFit.roadsFolder()) then
			return true
		end
		local nature = natureFolder()
		if not nature then return false end
		local cy = y + h * 0.5
		for _, m in nature:GetChildren() do
			if m:IsA("Model") then
				local cf, size = m:GetBoundingBox()
				if math.abs(cf.Position.X - x) < hx + size.X * 0.5 - OVERLAP_EPS
					and math.abs(cf.Position.Z - z) < hz + size.Z * 0.5 - OVERLAP_EPS
					and math.abs(cf.Position.Y - cy) < h * 0.5 + size.Y * 0.5 - OVERLAP_EPS then
					return true
				end
			end
		end
		return false
	end

	-- Everything else is judged on its FOOTPRINT circle, the same radius the road and
	-- building rules are written in -- a tree's bounding box is its crown, and judging a
	-- wood by crowns would refuse the second tree. The Y span rides in propAt, which is
	-- what keeps a shape stacked on a shape legal: placeY has already seated it on top.
	local r = e.radius * scale
	if PlacementFit.buildingAt(pivot, Vector3.new(r * 2, h, r * 2)) then return true end
	return PlacementFit.propAt(Vector3.new(x, y, z), r, h)
end

local function clearRowGhosts()
	for i = 1, _ghostN do
		local m = _ghosts[i]
		if m then m:Destroy() end
		_ghosts[i] = nil
	end
	_ghostN = 0
end

-- Every setting that feeds a placement routes through here, so the cursor plan is dropped
-- with the row plan and the next ghost is rebuilt from the new settings.
local function clearRowPlan()
	_rowPlan = {}
	_cursorPlan = nil
	clearRowGhosts()
end

-- Fill the plan up to n points. Each new index gets a fixed asset + jitter, so ghosts
-- already on screen never change under the cursor -- the row only extends as you drag out.
local function ensureRowPlan(n: number)
	for i = 1, n do
		if _rowPlan[i] == nil then
			local key = pickKey()
			if key then
				local scale, yaw = jitter(key)
				_rowPlan[i] = { key = key, scale = scale, yaw = yaw }
			end
		end
	end
end

-- Show the real trees at the real spacing, snapped to the ground. Ghosts are pooled per
-- index: only new tail points are cloned (grow) or destroyed (shrink); the rest just move.
local function updateRowGhosts(pts: { Vector3 })
	local n = math.min(#pts, MAX_ROW)
	ensureRowPlan(n)
	for i = 1, n do
		local plan = _rowPlan[i]
		local existing = _ghosts[i]
		if plan and (not existing
			or existing:GetAttribute("GKey") ~= plan.key
			or existing:GetAttribute("GScale") ~= plan.scale
			or existing:GetAttribute("GColor") ~= _placeColor) then
			if existing then existing:Destroy() end
			local g = translucentClone(plan.key, plan.scale)
			if g then
				g:SetAttribute("GKey", plan.key)
				g:SetAttribute("GScale", plan.scale)
				g:SetAttribute("GColor", _placeColor)
			end
			_ghosts[i] = g
		end
	end
	for i = n + 1, _ghostN do
		local m = _ghosts[i]
		if m then m:Destroy() end
		_ghosts[i] = nil
	end
	_ghostN = n
	for i = 1, n do
		local m = _ghosts[i]
		local plan = _rowPlan[i]
		local p = pts[i]
		if m and plan and p then
			local y = placeY(p.X, p.Z, plan.key, plan.scale) or p.Y
			local worldPos = Vector3.new(p.X, y, p.Z)
			m:PivotTo(CFrame.new(worldPos) * CFrame.Angles(0, plan.yaw, 0))
			-- plan.scale here IS the exact scale commitLine/commitCurve will send (the row
			-- plan is fixed once and reused verbatim), so this footprint check is accurate,
			-- not an approximation -- unlike the single-cursor ghost's scaleMul=1 caveat.
			local entry = NatureCatalog.get(plan.key)
			local footprint = if entry then entry.radius * plan.scale else 0
			setGhostBlocked(m, _broke
				or isNearRoadPreview(worldPos, footprint, (templateHeight(plan.key) or 0) * plan.scale)
				or blockedByOverlap(p.X, y, p.Z, plan.key, plan.scale))
		end
	end
end

-- == Stamp =====================================================================
-- A STAMP is several props held as one thing: cut four blocks arranged into a wall and the
-- cursor carries the wall, not one block. Each item keeps its own offset from the set's
-- centre and its own look, and ONE click plants the lot -- which is what a multi-selection
-- cut has to mean. Single-gesture only: a stamp swept along a Line or a Brush is a question
-- nobody has asked, and setMode drops it rather than half-answering it.
local _stampGhost: { Model } = {}
-- The stamp table's own identity. A stamp is replaced whole (there is no way to edit one
-- item of one), so this rebuilds the ghosts exactly once per arming and never per frame.
local _stampGhostOf: { StampItem }? = nil

local function hideStampGhost()
	for _, g in _stampGhost do g:Destroy() end
	table.clear(_stampGhost)
	_stampGhostOf = nil
end

-- WEIGHT, as a lean rather than a lag. What the cursor is carrying tips its leading edge up
-- and drops its trailing edge while it is under way, and settles level when it stops. The
-- position itself always lands exactly: easing THAT is what read as the tool failing to keep
-- up rather than as weight. One state for the whole preview -- everything on the cursor
-- moves together, so they lean together.
local _leanVel = Vector3.zero
local _leanRot = CFrame.identity
local _leanAt: Vector3? = nil

-- Once per frame, from the render loop, which is the only place with a real dt.
local function updateLean(point: Vector3?, dt: number)
	if not point then
		_leanAt = nil
		_leanRot, _leanVel = EditorGizmos.leanStep(_leanVel, Vector3.zero, dt)
		return
	end
	local prev = _leanAt
	_leanAt = point
	local vel = if prev and dt > 0 then (point - prev) / dt else Vector3.zero
	_leanRot, _leanVel = EditorGizmos.leanStep(_leanVel, vel, dt)
end

-- Position lands exactly; only the ORIENTATION leans.
local function leanFrame(cf: CFrame): CFrame
	return CFrame.new(cf.Position) * _leanRot * cf.Rotation
end

local function hideGhost()
	if _ghost then _ghost:Destroy(); _ghost = nil; _ghostKey = nil end
	-- Every existing teardown path goes through here, so the stamp's ghosts ride along rather
	-- than needing a second call added at each one.
	hideStampGhost()
end

-- Single cursor ghost. The plan behind it -- key, size, angle -- is fixed ONCE and is the
-- exact thing commitSingle sends, the same contract the row plan has. The ghost used to
-- render at 1x with no rotation while the click rolled its own, so what you saw was never
-- what you got.
local function cursorPlan(): { key: string, scale: number, yaw: number }?
	local key = firstSelected()
	if not key then _cursorPlan = nil; return nil end
	local plan = _cursorPlan
	if not plan or plan.key ~= key then
		local scale, yaw = jitter(key)
		plan = { key = key, scale = scale, yaw = yaw }
		_cursorPlan = plan
	end
	return plan
end

-- The whole set, riding the cursor in the arrangement it was cut from.
local function updateStampGhost(point: Vector3)
	local stamp = _stamp
	if not stamp then hideStampGhost(); return end
	if _stampGhostOf ~= stamp then
		hideStampGhost()
		for _, s in stamp do
			local g = translucentClone(s.key, s.scale or 1, s)
			if g then table.insert(_stampGhost, g) end
		end
		_stampGhostOf = stamp
	end
	-- A right-drag turns the WHOLE arrangement, so each prop's offset swings round the set's
	-- centre with it rather than the props spinning where they stand.
	local turn = CFrame.Angles(0, _ghostYaw, 0)
	for i, g in _stampGhost do
		local s = stamp[i]
		if not s then break end
		local off = turn * Vector3.new(s.dx, 0, s.dz)
		local x, z = point.X + off.X, point.Z + off.Z
		-- Seated the way plantOne will seat it: on the ground under ITS OWN spot, plus the
		-- height it was carrying. A stamp dragged onto a slope follows the slope.
		-- Each item seats itself, on its own collide flag, exactly as the server will seat it.
		local y = (placeY(x, z, s.key, s.scale or 1, s.collide ~= false, s.stretch) or point.Y)
			+ s.yOffset + _placeYOffset
		g:PivotTo(leanFrame(CFrame.new(x, y, z) * CFrame.fromOrientation(s.pitch, s.yaw + _ghostYaw, s.roll)))
		setGhostBlocked(g, _broke)
	end
end

local function updateGhost(point: Vector3)
	-- Before cursorPlan: a stamp has no catalog card ticked, so that would come back nil and
	-- tear down the ghosts this function is here to draw.
	if _stamp then updateStampGhost(point); return end
	local plan = cursorPlan()
	if not plan then hideGhost(); return end
	local key = plan.key
	local entry = NatureCatalog.get(key)
	if _ghostKey ~= key or not (_ghost and _ghost.Parent)
		or _ghost:GetAttribute("GScale") ~= plan.scale
		or _ghost:GetAttribute("GColor") ~= _placeColor then
		hideGhost()
		_ghost = translucentClone(key, plan.scale)
		if _ghost then
			_ghost:SetAttribute("GScale", plan.scale)
			_ghost:SetAttribute("GColor", _placeColor)
		end
		_ghostKey = if _ghost then key else nil
	end
	if _ghost then
		local at, yaw, noRoad = resolvePlacement(point, plan)
		local y = (placeY(at.X, at.Z, key, plan.scale) or at.Y) + _placeYOffset
		_ghost:PivotTo(leanFrame(CFrame.new(at.X, y, at.Z) * CFrame.Angles(0, yaw + _ghostYaw, 0)))
		local footprint = if entry then entry.radius * plan.scale else 0
		setGhostBlocked(_ghost, _broke
			or noRoad
			or isNearRoadPreview(Vector3.new(at.X, y, at.Z), footprint, (templateHeight(key) or 0) * plan.scale)
			or blockedByOverlap(at.X, y, at.Z, key, plan.scale))
	end
end

local function hideRing()
	if _ring then _ring.Parent = nil end
end

local function updateRing(point: Vector3)
	if not (_ring and _ring.Parent) then
		local r = _ring or Instance.new("Part")
		r.Name = "NatureBrushRing"
		r.Shape = Enum.PartType.Cylinder
		r.Anchored = true; r.CanCollide = false; r.CanQuery = false; r.CanTouch = false
		r.Material = Enum.Material.Neon
		r.Color = ACCENT
		r.Transparency = 0.7
		r.Parent = ensureFolder()
		_ring = r
	end
	local d = _brushRadius * 2
	_ring.Size = Vector3.new(0.4, d, d)
	_ring.CFrame = CFrame.new(point + Vector3.new(0, 0.35, 0)) * CFrame.Angles(0, 0, math.rad(90))
end

local function clearCurveMarkers()
	for i = 1, _curveMarkerN do
		local m = _curveMarkers[i]
		if m then m:Destroy() end
		_curveMarkers[i] = nil
	end
	_curveMarkerN = 0
end

local function clearCurveDots()
	for i = 1, _curveDotN do
		local d = _curveDots[i]
		if d then d:Destroy() end
		_curveDots[i] = nil
	end
	_curveDotN = 0
end

-- A small flat disc marking a clicked point (start / bend) of the curve gesture, so the
-- shape reads clearly (dot -> curved line -> dot) even before any tree ghost is placed.
local function spawnCurveDot(point: Vector3): Part
	local d = Instance.new("Part")
	d.Name = "NatureCurveDot"
	d.Shape = Enum.PartType.Cylinder
	d.Anchored = true; d.CanCollide = false; d.CanQuery = false; d.CanTouch = false; d.CastShadow = false
	d.Material = Enum.Material.Neon
	d.Color = ACCENT
	d.Transparency = 0.1
	local size = 1.6
	d.Size = Vector3.new(0.3, size, size)
	local y = groundY(point.X, point.Z) or point.Y
	d.CFrame = CFrame.new(point.X, y + 0.15, point.Z) * CFrame.Angles(0, 0, math.rad(90))
	d.Parent = ensureFolder()
	return d
end

-- Thin translucent slats tracing the sampled bezier, so the curve's shape is visible even
-- where tree spacing leaves a gap. Pooled the same way row ghosts are (grow/shrink by index).
local CURVE_LINE_SAMPLES = 28
local function updateCurveLine(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3)
	local pts: { Vector3 } = table.create(CURVE_LINE_SAMPLES + 1)
	for i = 0, CURVE_LINE_SAMPLES do
		local pt = BezierUtil.point(p0, p1, p2, p3, i / CURVE_LINE_SAMPLES)
		pts[i + 1] = pt
	end
	local n = #pts - 1 -- one slat per segment between consecutive samples
	for i = 1, n do
		local a, b = pts[i], pts[i + 1]
		local ay = groundY(a.X, a.Z) or a.Y
		local by = groundY(b.X, b.Z) or b.Y
		local from = Vector3.new(a.X, ay + 0.1, a.Z)
		local to = Vector3.new(b.X, by + 0.1, b.Z)
		local mid = (from + to) / 2
		local len = (to - from).Magnitude
		local slat = _curveMarkers[i]
		if not slat then
			slat = Instance.new("Part")
			slat.Name = "NatureCurveSlat"
			slat.Anchored = true; slat.CanCollide = false; slat.CanQuery = false; slat.CanTouch = false; slat.CastShadow = false
			slat.Material = Enum.Material.Neon
			slat.Color = ACCENT
			slat.Transparency = 0.35
			slat.Parent = ensureFolder()
			_curveMarkers[i] = slat
		end
		slat.Size = Vector3.new(0.25, 0.25, math.max(len, 0.05))
		if len > 1e-4 then
			slat.CFrame = CFrame.lookAt(mid, to)
		else
			slat.CFrame = CFrame.new(mid)
		end
	end
	for i = n + 1, _curveMarkerN do
		local m = _curveMarkers[i]
		if m then m:Destroy() end
		_curveMarkers[i] = nil
	end
	_curveMarkerN = n
end

-- Cursor cost tag: a small pill that rides next to the mouse while the tool is active,
-- showing what the pending placement will charge (per-prop for Single/Brush, the summed
-- row for Line/Curve previews). Purely informational; the server does the real charging.
local _costLabel: TextLabel? = nil
local _money: number? = nil  -- last treasury sync; nil until the first SyncEconomy
local _broke = false         -- pending cost exceeds treasury -> whole preview tints red
local function ensureCostLabel(): TextLabel
	if _costLabel and _costLabel.Parent then return _costLabel :: TextLabel end
	local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "NatureCostTag"
	gui.ResetOnSpawn = false
	-- The tag is positioned from GetMouseLocation, which is full-render-surface space, so
	-- the gui must be too or the pill rides ~36 px off the cursor. Matches PlacementCostHud.
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = Theme.Layer.CostTag + 1
	gui.Parent = pg
	local l = Instance.new("TextLabel")
	l.AutomaticSize = Enum.AutomaticSize.XY
	l.BackgroundColor3 = Color3.fromRGB(18, 20, 24)
	l.BackgroundTransparency = 0.25
	l.TextColor3 = MONEY_GREEN
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

local function pendingCost(): (number, boolean)
	-- Row modes with an active gesture: sum the previewed plan (exactly what commit sends).
	if (_mode == "Line" and _lineStart) or (_mode == "Curve" and _curveStart and _curveBend) then
		local total = 0
		for i = 1, _ghostN do
			local plan = _rowPlan[i]
			local e = if plan then NatureCatalog.get(plan.key) else nil
			if e then total += e.cost end
		end
		return total, false
	end
	local key = firstSelected() or NatureCatalog.order[1]
	local e = if key then NatureCatalog.get(key) else nil
	return if e then e.cost else 0, _mode == "Brush"
end

local function updateCostTag()
	-- Only while a gesture is actually in progress -- an idle cursor ghost (Single mode,
	-- or Line/Curve before the first click) stays tag-free.
	local active = (_mode == "Line" and _lineStart ~= nil)
		or (_mode == "Curve" and _curveStart ~= nil)
		or (_mode == "Brush" and _painting)
	if not active then
		local cost = pendingCost()
		_broke = _money ~= nil and cost > (_money :: number)
		hideCostTag()
		return
	end
	local cost, perEach = pendingCost()
	_broke = _money ~= nil and cost > (_money :: number)
	if cost <= 0 then hideCostTag(); return end
	local l = ensureCostLabel()
	l.Text = if perEach then ("-$%d each"):format(cost) else ("-$%d"):format(cost)
	l.TextColor3 = if _broke then Theme.Color.Danger else MONEY_GREEN
	local m = CursorRay.position()
	l.Position = UDim2.fromOffset(m.X + 16, m.Y - 10)
	l.Visible = true
end

local function hideAllPreview()
	clearRowGhosts(); hideGhost(); hideRing(); clearCurveMarkers(); clearCurveDots(); hideCostTag()
end

-- ---------------------------------------------------------------- placement
-- Free Placement is a SERVER rule bypass (NaturePlaceService.plantOne skips the
-- road/building exclusion for a flagged item), and the server cannot see a client-local
-- toggle -- so the flag has to ride along with the items. Stamped in one place so all four
-- gestures obey the one toggle instead of Single alone.
local function fireItems(items: { any })
	if #items == 0 then return end
	local free = FreePlacement.isEnabled() or nil -- nil, not false: keeps the payload small
	-- Material and collision are stamped here for the same reason the free flag is: all
	-- four gestures obey one setting instead of Single alone. Both stay nil at their
	-- defaults, so a payload from a player who never opened the picker is unchanged.
	local mat = if _placeMaterial > 0 then _placeMaterial else nil
	local collide = if _placeCollide then nil else false
	for _, it in items do
		it.free = free
		-- An item that brought its OWN look keeps it: a duplicate copies the prop it was
		-- taken from, not whatever the picker happens to be set to.
		it.material = it.material or mat
		if it.collide == nil then it.collide = collide end
		if it.transparency == nil and _placeTransparency > 0 then it.transparency = _placeTransparency end
	end
	Net.RequestPlaceNature:FireServer(items)
end

local function commitLine(endp: Vector3)
	local startp = _lineStart
	_lineStart = nil
	if not startp then clearRowPlan(); return end
	local pts = sampleRow(startp, endp)
	local n = math.min(#pts, MAX_ROW)
	ensureRowPlan(n) -- reuse the previewed plan so the result matches what was shown
	local items = {}
	for i = 1, n do
		local plan = _rowPlan[i]
		local p = pts[i]
		if plan and p then
			items[#items + 1] = { key = plan.key, pos = p, yaw = plan.yaw, scale = plan.scale, stack = _stack, color = _placeColor }
		end
	end
	fireItems(items)
	clearRowPlan()
end

-- Precise mode's other half: the server owns the prop, so the client cannot be handed one
-- back. Watch the city's Nature folder for the model that lands near where we clicked and
-- put the gizmo on it. Gives up quietly -- a refused placement simply never arrives.
local PRECISE_WAIT = 2
local PRECISE_RADIUS = 3
local function grabPlaced(at: Vector3)
	local nature = natureFolder()
	if not nature then return end
	local conn: RBXScriptConnection? = nil
	conn = nature.ChildAdded:Connect(function(child: Instance)
		if not child:IsA("Model") then return end
		local p = child:GetPivot().Position
		if math.abs(p.X - at.X) > PRECISE_RADIUS or math.abs(p.Z - at.Z) > PRECISE_RADIUS then return end
		if conn then conn:Disconnect(); conn = nil end
		NatureGizmo.attach(child :: Model, Net.RequestMoveNature)
	end)
	-- Tracked and cut either way: a listener left hanging on a rejected placement would
	-- grab whatever the NEXT click planted.
	task.delay(PRECISE_WAIT, function()
		if conn then conn:Disconnect(); conn = nil end
	end)
end

-- Single: one click, one prop, at the exact clicked point, with the exact transform the
-- ghost was showing. Refused outright if it would land inside something -- the server would
-- reject it anyway, and firing a request the ghost already painted red is just noise.
-- One click, the whole arrangement. Every item carries its own offset, angle, height and
-- look, so nothing here reads the tool's own colour/material/stretch fields -- fireItems
-- leaves an item that brought its own alone.
local function commitStamp(point: Vector3)
	local stamp = _stamp
	if not stamp then return end
	local items = {}
	local turn = CFrame.Angles(0, _ghostYaw, 0)
	for _, s in stamp do
		local off = turn * Vector3.new(s.dx, 0, s.dz)
		items[#items + 1] = {
			key = s.key,
			pos = Vector3.new(point.X + off.X, 0, point.Z + off.Z),
			yaw = s.yaw + _ghostYaw,
			pitch = s.pitch,
			roll = s.roll,
			scale = s.scale,
			-- Height as an OFFSET, never absolute: the server owns the terrain and seats each
			-- prop on it, so a stamp put down on a hill climbs the hill.
			yOffset = s.yOffset + _placeYOffset,
			color = s.color,
			material = s.material,
			collide = s.collide,
			stretch = s.stretch,
			transparency = s.transparency,
		}
	end
	fireItems(items)
	SoundFX.play("Nature")
end

-- Put the armed stamp down at `point`. Named because CUT INTO PRECISE calls it directly to
-- drop the set straight back where it was cut from.
local function placeStampAt(point: Vector3): boolean
	local stamp = _stamp
	if not stamp then return false end
	commitStamp(point)
	-- Precise grabs a stamp of ONE, exactly as it grabs an ordinary placement. A stamp of
	-- several is placed whole and not grabbed: the handles hold one model, and there is no
	-- sensible one to pick out of a wall.
	if _precise and #stamp == 1 then
		grabPlaced(Vector3.new(point.X + stamp[1].dx, point.Y, point.Z + stamp[1].dz))
	end
	return true
end

local function commitSingle(point: Vector3)
	if _stamp then placeStampAt(point); return end
	local key = pickKey()
	if not key then return end
	local plan = _cursorPlan
	if not plan or plan.key ~= key then
		local s, y = jitter(key)
		plan = { key = key, scale = s, yaw = y }
	end
	-- Same resolve the ghost ran, so a snapped car park is placed exactly where it previewed.
	local at, yaw, noRoad = resolvePlacement(point, plan)
	if noRoad then return end
	local y = placeY(at.X, at.Z, key, plan.scale) or at.Y
	if blockedByOverlap(at.X, y, at.Z, key, plan.scale) then return end
	fireItems({ { key = key, pos = at, yaw = yaw + _ghostYaw, scale = plan.scale, stack = _stack,
		color = _placeColor, yOffset = if _placeYOffset ~= 0 then _placeYOffset else nil } })
	SoundFX.play("Nature")
	-- Next placement gets its own roll, so a scatter does not stamp the same tree twice.
	_cursorPlan = nil
	-- ONLY precise takes hold of what it just put down. Without it, placing is placing: the
	-- prop is final, the ghost comes straight back and the next click plants another. Making
	-- every placement a master meant a confirm press to put down a single tree.
	if _precise then grabPlaced(at) end
end

-- Curve: mirrors commitLine, but the row is sampled along the bezier built from the 3
-- clicked points instead of a straight chord.
local function commitCurve(endp: Vector3)
	local startp = _curveStart
	local bend = _curveBend
	_curveStart = nil
	_curveBend = nil
	if not (startp and bend) then clearRowPlan(); return end
	local p0, p1, p2, p3 = curveControlPoints(startp, bend, endp)
	local pts = sampleCurve(p0, p1, p2, p3)
	local n = math.min(#pts, MAX_ROW)
	ensureRowPlan(n) -- reuse the previewed plan so the result matches what was shown
	local items = {}
	for i = 1, n do
		local plan = _rowPlan[i]
		local p = pts[i]
		if plan and p then
			items[#items + 1] = { key = plan.key, pos = p, yaw = plan.yaw, scale = plan.scale, stack = _stack, color = _placeColor }
		end
	end
	fireItems(items)
	clearRowPlan()
end

local function paintBurst(center: Vector3)
	local items = {}
	local placed = 0
	for _ = 1, PAINT_PER_TICK * 2 do
		if placed >= PAINT_PER_TICK then break end
		local key = pickKey()
		if not key then break end
		local ang = math.random() * math.pi * 2
		local rad = math.sqrt(math.random()) * _brushRadius
		local cand = Vector3.new(center.X + math.cos(ang) * rad, 0, center.Z + math.sin(ang) * rad)
		local gap = (NatureCatalog.get(key) :: any).radius * 1.5
		local ok = true
		for _, q in _strokePlaced do
			if (Vector3.new(q.X, 0, q.Z) - cand).Magnitude < gap then ok = false; break end
		end
		if ok then
			local scale, yaw = jitter(key)
			items[#items + 1] = { key = key, pos = cand, yaw = yaw, scale = scale, stack = _stack, color = _placeColor }
			_strokePlaced[#_strokePlaced + 1] = cand
			placed += 1
		end
	end
	if #_strokePlaced > STROKE_MEMORY then _strokePlaced = {} end
	fireItems(items)
end

-- Height in whole snap steps, so a stack of blocks lines up the way a row of them does.
-- Vertical snapping off means free height, exactly as it does for the handles.
local FREE_HEIGHT_STEP = 0.5
local function nudgeMasterY(dir: number)
	local m = NatureGizmo.current()
	if not m then return end
	local step = EditorGizmos.getStep("move")
	if step <= 0 or not EditorGizmos.isVerticalSnap() then step = FREE_HEIGHT_STEP end
	local pv = m:GetPivot()
	m:PivotTo(CFrame.new(pv.Position + Vector3.new(0, step * dir, 0)) * pv.Rotation)
	NatureGizmo.pushTransform()
end

-- ---------------------------------------------------------------- public API
function NaturePlacementController.setEnabled(on: boolean)
	if on == _enabled then return end
	_enabled = on
	_lineStart = nil
	_curveStart = nil
	_curveBend = nil
	_painting = false
	clearRowPlan()
	-- Leaving the tool takes its gizmo with it: handles hanging over the city after the
	-- panel closed are handles nothing is driving.
	if not on then
		hideAllPreview(); NaturePlacementController.discardPrecise()
		_ghostYaw = 0 -- a fresh tool starts square on, not at whatever the last drag left
		_placeYOffset = 0
		clearAllSelected()
		notify() -- cards go dark with the tab that lit them
	end
end

function NaturePlacementController.isEnabled(): boolean return _enabled end

function NaturePlacementController.setMode(mode: Mode)
	if mode ~= "Line" and mode ~= "Brush" and mode ~= "Single" and mode ~= "Curve" then return end
	-- A stamp is a Single-gesture thing. Sweeping a four-block wall along a Line is a question
	-- nobody has asked, so leaving Single drops it rather than half-answering it.
	if mode ~= "Single" then _stamp = nil end
	_mode = mode
	_lineStart = nil
	_curveStart = nil
	_curveBend = nil
	_painting = false
	clearRowPlan()
	hideAllPreview()
end
function NaturePlacementController.getMode(): Mode return _mode end

function NaturePlacementController.setSpacing(n: number) _spacing = math.clamp(math.floor(n), 4, 80) end
function NaturePlacementController.getSpacing(): number return _spacing end

function NaturePlacementController.setBrushRadius(n: number) _brushRadius = math.clamp(math.floor(n), 6, 80) end
function NaturePlacementController.getBrushRadius(): number return _brushRadius end

-- Placement size. The catalog still clamps per asset, so this is a request, not an order.
function NaturePlacementController.setPlaceScale(n: number)
	_placeScale = math.clamp(n, 0.25, 6)
	clearRowPlan()
	notify()
end
function NaturePlacementController.getPlaceScale(): number return _placeScale end

function NaturePlacementController.setStack(on: boolean)
	if _stack == on then return end
	_stack = on
	clearRowPlan()
	notify()
end
function NaturePlacementController.isStacking(): boolean return _stack end

-- Precise mode. Turning it OFF drops any gizmo it left on screen, so the handles never
-- outlive the setting that put them there.
function NaturePlacementController.setPrecise(on: boolean)
	if _precise == on then return end
	_precise = on
	if not on then NaturePlacementController.discardPrecise() end
	notify()
end

-- "There is a prop under the handles right now." The panel reads it for its caption and to
-- decide whether the look controls have anything to act on.
function NaturePlacementController.isParked(): boolean return NatureGizmo.current() ~= nil end
function NaturePlacementController.isPrecise(): boolean return _precise end

-- nil means "leave the template alone". Anything else repaints the whole prop.
function NaturePlacementController.setPlaceColor(c: Color3?)
	if _placeColor == c then return end
	_placeColor = c
	if c and NatureGizmo.current() then NatureGizmo.setColor(c) end
	hideGhost()
	clearRowPlan()
	notify()
end
function NaturePlacementController.getPlaceColor(): Color3? return _placeColor end

-- The look controls do double duty: they set what the NEXT placement gets, and they repaint
-- whatever is under the handles right now. One gesture, both meanings -- which is what you
-- want when the thing under the handles is the thing you just placed.
function NaturePlacementController.setPlaceMaterial(idx: number)
	if not MaterialCatalog.order[idx] and idx ~= 0 then return end
	_placeMaterial = idx
	if NatureGizmo.current() then NatureGizmo.setMaterial(idx) end
	hideGhost()
	clearRowPlan()
	notify()
end
function NaturePlacementController.getPlaceMaterial(): number return _placeMaterial end

function NaturePlacementController.setPlaceTransparency(t: number)
	t = math.clamp(math.round(t * 20) / 20, 0, 0.9)
	if _placeTransparency == t then return end
	_placeTransparency = t
	if NatureGizmo.current() then NatureGizmo.setTransparency(t) end
	hideGhost()
	clearRowPlan()
	notify()
end
function NaturePlacementController.getPlaceTransparency(): number return _placeTransparency end

-- This is ALL that CUT and COPY do: the props you had selected come back on the cursor, in
-- the arrangement they were in, and the next click puts the whole lot down. Four blocks built
-- into a wall come back as the wall -- which is the only thing a multi-selection cut can
-- sensibly mean. There is no clipboard and no paste, because "let me place that again" was
-- the only thing anybody ever wanted from one.
--
-- ONE path for any count. A single prop could have gone through the plain card-and-look
-- route instead, but that route re-rolls the yaw and drops the height -- so a block you had
-- turned 45 degrees and lifted onto a wall came back flat on the ground at zero.
function NaturePlacementController.armStamp(items: { StampItem })
	if #items == 0 then return end
	-- The master goes for the same reason picking a card drops it.
	NaturePlacementController.discardPrecise()
	_mode = "Single"
	_stamp = items
	-- The tool's own look fields are cleared, not applied: every item brought its own, and
	-- fireItems only fills in what an item left nil.
	_placeColor = nil
	_placeMaterial = 0
	_placeTransparency = 0
	_placeCollide = true
	clearAllSelected()
	-- A stamp of ONE also lights its card: that is the menu you placed it from, and landing
	-- there with the thing itself lit is the whole point of a cut. `_stamp` still wins at the
	-- cursor, so the card is a label here, not a second source of truth.
	if #items == 1 and NatureCatalog.get(items[1].key) then selectOnly(items[1].key) end
	hideGhost()
	clearRowPlan()
	notify()
end

function NaturePlacementController.stampSize(): number
	local s = _stamp
	return if s then #s else 0
end

-- CUT INTO PRECISE puts the set straight back where it came from rather than leaving it on
-- the cursor: you asked to pick this up and keep working on it, not to carry it somewhere
-- else first. The handles land on it if it is a single prop.
function NaturePlacementController.placeStamp(point: Vector3): boolean
	return placeStampAt(point)
end

function NaturePlacementController.setPlaceCollide(on: boolean)
	_placeCollide = on == true
	if NatureGizmo.current() then NatureGizmo.setCollide(_placeCollide) end
	notify()
end
function NaturePlacementController.getPlaceCollide(): boolean return _placeCollide end

-- One elevation control for both states: the MASTER when there is one under the handles,
-- otherwise the height of whatever is riding the cursor. Same step either way, so a block
-- lifted before it is placed and the same block nudged after are moving on one grid.
function NaturePlacementController.nudgeHeight(dir: number)
	if NatureGizmo.current() then nudgeMasterY(dir); return end
	local step = EditorGizmos.getStep("move")
	if step <= 0 or not EditorGizmos.isVerticalSnap() then step = FREE_HEIGHT_STEP end
	_placeYOffset += step * dir
	hideGhost() -- rebuilt at the new height on the next frame
	notify()
end

function NaturePlacementController.getPlaceHeight(): number return _placeYOffset end

-- PLACE is a STAMP. The prop under the handles is the master -- half-transparent, because
-- it is not part of the city yet -- and every press drops a solid COPY of it exactly where
-- it stands. The master keeps the handles, so you move it, press again, and get another.
-- That is why there is no separate Duplicate: placing already leaves a copy behind.
function NaturePlacementController.commitPrecise(): boolean
	local item = NatureGizmo.editState()
	if not item then return false end
	fireItems({ item })
	SoundFX.play("Nature")
	notify()
	return true
end

-- The master was never placed, so leaving precise mode takes it with it. Every exit runs
-- through here: the setting, the tool, the tab, Back and picking another card.
function NaturePlacementController.discardPrecise()
	_rightDrag = nil
	if NatureGizmo.current() then NatureGizmo.discard(Net.RequestRemoveNature) end
end



function NaturePlacementController.setRandomize(on: boolean)
	if _randomize == on then return end
	_randomize = on
	if not on then
		-- Off collapses any multi-selection down to the first asset the player checked;
		-- turning ON never needs to expand anything -- a 1-item selection is already a
		-- valid (if trivial) "random" pool.
		collapseToFirstSelected()
	end
	clearRowPlan()
	notify()
end
function NaturePlacementController.getRandomize(): boolean return _randomize end

function NaturePlacementController.setTileShapes(on: boolean) _tileShapes = on end
function NaturePlacementController.isTileShapes(): boolean return _tileShapes end

-- setPlaceAnywhere/isPlaceAnywhere retired -- see FreePlacement (ReplicatedStorage.Shared.FreePlacement) instead.

function NaturePlacementController.setAssetSelected(key: string, on: boolean)
	if not NatureCatalog.get(key) then return end
	_stamp = nil -- reaching for a card means you want the card, not the set you were holding
	-- Reaching for the palette means you are done with the master: you asked for a
	-- different shape, so the one you were stamping goes.
	NaturePlacementController.discardPrecise()
	if on then
		if _randomize then selectAdd(key) else selectOnly(key) end
	else
		deselect(key)
	end
	clearRowPlan()
	notify()
end
-- Panels call this when their own sub-shelf changes (Trees -> Rocks), where the tool
-- stays on so setEnabled never fires.
function NaturePlacementController.clearSelection()
	local hadStamp = _stamp ~= nil
	_stamp = nil
	if #_selectedOrder == 0 and not hadStamp then return end
	clearAllSelected()
	clearRowPlan()
	notify()
end

function NaturePlacementController.isAssetSelected(key: string): boolean
	return _selected[key] == true
end

-- Registering immediately fires the callback once with current state, same contract as
-- RoadPlacementController.setStateListener -- a consumer that registers late (e.g. after
-- the panel's already built) still gets synced instead of waiting for the next change.
function NaturePlacementController.setStateListener(fn: () -> ())
	_listener = fn
	notify()
end

function NaturePlacementController.Init()
	if _inited then return end
	_inited = true
	ensureFolder()
end

function NaturePlacementController.Bind()
	if _bound then return end
	_bound = true

	Net.SyncEconomy.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) == "table" and typeof(payload.money) == "number" then
			_money = payload.money
		end
	end)

	_renderConn = RunService.RenderStepped:Connect(function(dt: number)
		if not _enabled then return end
		-- NO GHOST while a prop is under the handles. The preview reads as a second placed
		-- prop sitting beside the one you are actually working on, which is exactly what you
		-- do not want to see while judging the real one. Clicking still plants -- the ghost
		-- was never what made the click work.
		if NatureGizmo.current() then
			hideAllPreview()
			return
		end
		local point = mouseGround()
		-- Before anything is drawn: every ghost this frame leans by the same amount, because
		-- they are all riding one cursor.
		updateLean(point, dt)
		if point then updateCostTag() else hideCostTag() end
		if _mode == "Line" then
			hideRing(); clearCurveDots()
			if point then
				if _lineStart then
					hideGhost()
					-- Straight-segment slat trail from click to cursor -- same green line Curve
					-- shows pre-bend (updateCurveLine degenerates cleanly to a straight line
					-- when both control-point pairs equal their endpoint; Curve's own
					-- second-click branch already relies on this same degenerate call).
					updateCurveLine(_lineStart, _lineStart, point, point)
					updateRowGhosts(sampleRow(_lineStart, point))
				else
					clearRowGhosts(); clearCurveMarkers()
					updateGhost(point)
				end
			else
				clearRowGhosts(); hideGhost(); clearCurveMarkers()
			end

		elseif _mode == "Single" then
			hideRing(); clearCurveMarkers(); clearCurveDots(); clearRowGhosts()
			if point then updateGhost(point) else hideGhost() end

		elseif _mode == "Curve" then
			hideRing()
			if point then
				if _curveStart and _curveBend then
					-- Third click pending: full preview -- start dot, bend dot, sampled curve
					-- line, and the real tree ghosts riding along it.
					hideGhost()
					local p0, p1, p2, p3 = curveControlPoints(_curveStart, _curveBend, point)
					updateCurveLine(p0, p1, p2, p3)
					updateRowGhosts(sampleCurve(p0, p1, p2, p3))
				elseif _curveStart then
					-- Second click pending: show start -> cursor as a straight preview segment
					-- (there's no bend yet to curve around), same shape the road tool shows.
					hideGhost()
					clearRowGhosts()
					updateCurveLine(_curveStart, _curveStart, point, point)
				else
					clearRowGhosts(); clearCurveMarkers()
					updateGhost(point)
				end
			else
				clearRowGhosts(); hideGhost(); clearCurveMarkers()
			end

		else -- Brush
			clearRowGhosts(); hideGhost(); clearCurveMarkers(); clearCurveDots()
			if point then
				updateRing(point)
				if _painting then
					_paintAccum += dt
					if _paintAccum >= PAINT_INTERVAL then
						_paintAccum = 0
						paintBurst(point)
					end
				end
			else
				hideRing()
			end
		end
	end)

	local function cancelGesture()
		_lineStart = nil
		_curveStart = nil
		_curveBend = nil
		-- Back / right-click is also how you say "done": the master was never placed.
		NaturePlacementController.discardPrecise()
		clearRowPlan()
		clearCurveMarkers()
		clearCurveDots()
	end

	_beganConn = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if not _enabled or gameProcessed then return end
		-- The selection modifiers hand the click to Controllers.NatureSelection: picking,
		-- multi-select and the capture box have to work while this tool is up, and a PLAIN
		-- click must still plant. Read here rather than pushed in from there, so the two
		-- modules never have to know about each other.
		if input.UserInputType == Enum.UserInputType.MouseButton1
			and (Settings.isActionDown("SelectBox") or Settings.isActionDown("SelectAdd")) then
			return
		end
		-- Before Back, so confirming never reads as cancelling.
		if Settings.pressed("PlaceObject", input) then
			NaturePlacementController.commitPrecise()
			return
		end
		if Settings.pressed("Back", input) then cancelGesture(); return end
		-- HEIGHT is keys, never the mouse: dragging is a ground gesture, and a drag that also
		-- lifted things would make every sideways nudge a guess about what you meant.
		if NatureGizmo.current() then
			if Settings.pressed("RoadRaise", input) then nudgeMasterY(1); return end
			if Settings.pressed("RoadLower", input) then nudgeMasterY(-1); return end
		end
		-- The master moves with the HANDLES and nothing else. A left-drag that also slid it
		-- meant a click anywhere could shove the thing you were lining up. Right-drag still
		-- turns it, because turning is not moving.
		if NatureGizmo.current() and not NatureGizmo.isBusy() then
			if input.UserInputType == Enum.UserInputType.MouseButton2 then
				-- A right-click that does not MOVE is still a cancel; the sweep is what turns
				-- it into a rotate. Decided on release, by how far it travelled.
				_rightDrag = { x = UserInputService:GetMouseLocation().X, turned = false }
				return
			end
		end
		if NatureGizmo.current() then return end
		-- Right-DRAG turns what is on the cursor, on the rotate snap. A right-click that never
		-- MOVED is still a cancel -- decided on release, by how far it travelled, which is the
		-- same bargain the master's turn makes.
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			_rightDrag = { x = UserInputService:GetMouseLocation().X, turned = false }
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		if _mode == "Line" then
			if not _lineStart then
				_lineStart = mouseGround()
			else
				local endp = mouseGround()
				if endp then commitLine(endp) else _lineStart = nil end
			end

		elseif _mode == "Single" then
			local point = mouseGround()
			if point then commitSingle(point) end

		elseif _mode == "Curve" then
			if not _curveStart then
				_curveStart = mouseGround()
				if _curveStart then
					clearCurveDots()
					_curveDots[1] = spawnCurveDot(_curveStart)
					_curveDotN = 1
				end
			elseif not _curveBend then
				_curveBend = mouseGround()
				if _curveBend then
					_curveDots[2] = spawnCurveDot(_curveBend)
					_curveDotN = 2
				else
					_curveStart = nil; cancelGesture()
				end
			else
				local endp = mouseGround()
				if endp then
					commitCurve(endp)
				else
					_curveStart = nil; _curveBend = nil
				end
				clearCurveDots()
				clearCurveMarkers()
			end

		else -- Brush
			_painting = true
			_paintAccum = PAINT_INTERVAL -- fire on the next render tick
			_strokePlaced = {}
		end
	end)

	_endedConn = UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			_painting = false
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 and _rightDrag then
			local turned = (_rightDrag :: any).turned
			_rightDrag = nil
			if not turned then
				cancelGesture()
			elseif NatureGizmo.current() then
				-- A master is a real prop: its new angle has to go to the server. The cursor
				-- ghost is not placed yet, so its angle simply rides `_ghostYaw` until it is.
				NatureGizmo.pushTransform()
			end
		end
	end)

	-- Right-drag turn. Horizontal sweep only: a turn needs one axis, and reading both makes
	-- a diagonal flick spin the thing twice as far as it looks like it should.
	_changedConn = UserInputService.InputChanged:Connect(function(input: InputObject)
		if not _enabled or input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
		local drag = _rightDrag
		if not drag then return end
		local x = UserInputService:GetMouseLocation().X
		local dx = x - drag.x
		if math.abs(dx) < 2 then return end
		drag.x = x
		drag.turned = true
		local m = NatureGizmo.current()
		if m then
			local pv = m:GetPivot()
			local _, ry = pv:ToOrientation()
			local want = EditorGizmos.snapDeg(math.deg(ry) + dx * ROT_PER_PIXEL)
			m:PivotTo(CFrame.new(pv.Position) * CFrame.Angles(0, math.rad(want), 0))
		else
			-- Nothing under the handles: turn what is ON THE CURSOR. Same snap step, so the
			-- preview and the placement can never disagree about the angle.
			_ghostYaw = math.rad(EditorGizmos.snapDeg(math.deg(_ghostYaw) + dx * ROT_PER_PIXEL))
		end
	end)
end

function NaturePlacementController.Start() end

return NaturePlacementController
