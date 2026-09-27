--!strict
-- EditorGizmos
-- The transform gizmo, plus the snap settings shared with body drags and drag-to-place.
-- This module owns HOW a drag manipulates the selection; the caller owns WHAT is selected.
--
-- Built against how the real ones work -- Roblox Studio's own dragger (stravant's liberated
-- copy), ImGuizmo, Blender and Godot -- because two hand-rolled attempts were unusable. The
-- constants below are Studio's, in units of the gizmo's on-screen scale factor.
--
-- THE THING THAT MATTERS MOST IS PICKING. The previous version hit-tested each arrow as a
-- single point with a 14px radius, so ~85% of a 95px-long arrow did nothing when clicked.
-- Every real implementation hit-tests the WHOLE shaft and uses a tolerance far LARGER than
-- the drawn handle -- Studio uses 4x the visual radius, with the comment "Handle hittests
-- bigger than it looks". Each visible handle has an invisible oversized twin, and
-- pickHandle ray-tests those itself: small grips beat rings, then the nearest hit wins.
--
-- LAYOUT (Transform): +axis arrow, a plane quad between each pair of axes, a screen-space
-- square at the centre, and a ring per axis. Resize is its own mode -- cramming a third
-- grip onto the same axes is what made the last one unreadable.
--
-- DRAG MATH, all of it recomputed every frame from the state saved at grab, never
-- accumulated into live state (Studio, ImGuizmo, Blender and Godot all do this -- it is
-- what keeps snapping idempotent and stops drift):
--   * translate: ray-plane against the plane containing the axis that most faces the
--     camera, normal = axis x (axis x viewDir). Blender's comment on why not line-line:
--     "this gave precision issues adding small values to large numbers".
--   * the grab offset cancels by intersecting the FROZEN click ray with the SAME plane
--     each frame (Godot's trick) -- so the point you grabbed stays under the cursor even
--     as the gizmo rescales with camera distance.
--   * rotate: the cursor's angle in the RING's plane, unwrapped frame to frame into an
--     unbounded total.
--   * near-degenerate views fall back to a different mapping rather than freezing.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))
-- For STUD_TO_METER only: the snap steps are quoted to the player in metres, and the world
-- is not one stud to the metre.
local RoadConstants = require(ReplicatedStorage:WaitForChild("Road"):WaitForChild("RoadConstants"))
-- The MOVE channel is the game-wide placement grid, not a copy of it: a prop nudged by the
-- handles lands on the same lines every placement tool drops things on.
local PlacementGrid = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlacementGrid"))

local EditorGizmos = {}

-- == Look (Studio's dragger constants, in gizmo-scale units) ===================
-- RADII ARE STRICTLY NESTED, and that is the whole layout rule. Every previous version
-- had rings passing through arrows and plane quads buried under both, because each grip's
-- size was chosen on its own. Read down this list: each band starts where the one above it
-- ends, so no two grips can ever be drawn on top of each other at any camera angle.
--
--   centre square   0.00 - 0.44     free move
--   scale cubes     1.18 - 2.62     a cube corner-on reads as a hexagon; that is the look
--   rings           3.84 - 4.56     rotation
--   cone arrows     4.71 - 7.09     bare cones, no shaft, on BOTH ends of every axis
--
-- Those are the HIT bands, not the drawn ones, because the hitboxes are the wider of the
-- two -- a grip you can see but not click is the bug this gizmo was rebuilt to fix.
--
-- The shafts and the plane quads are GONE. A shaft is a line that says nothing the cone at
-- its end does not already say, and four of them crossing three rings is most of what made
-- the middle of this thing unreadable.
local HITTEST_MUL = 4        -- "Handle hittests bigger than it looks"
local CUBE_HIT_MUL = 1.8     -- the cube's own multiplier: 4x would reach the rings
local CONE_HIT_MUL = 1.7
local CONE_OFFSET = 5.90     -- the cone's CENTRE, well outside the rings
local TIP_LENGTH = 1.40
local TIP_RADIUS = 0.50
local RING_RADIUS = 4.20
local RING_THICK = 0.18
local RING_SEGMENTS = 28
local CUBE_SIZE = 0.80
local CUBE_OFFSET = 1.90
local CENTRE_SIZE = 0.55     -- screen-space free-move square
-- The sweep fill inside the active rotation ring: a fan of thin slices, because there is no
-- filled-arc adornment. 48 is enough that the seams do not read at any sane gizmo size.
local FAN_SEGMENTS = 48
local FAN_TRANSPARENCY = 0.55
local GHOST_TRANSPARENCY = 0.45
local HOVER_THICKEN = 1.5
local SCALE_FACTOR = 0.05    -- Studio: sin(fov) * distance * 0.05

-- The layout rule made checkable. Every grip's GRABBABLE span, in order, so the spec can
-- hold "strictly nested" rather than trusting five constants to stay in step by eye -- the
-- overlap is invisible in the numbers and obvious the moment you try to click something.
EditorGizmos.HIT_BANDS = table.freeze({
	table.freeze({ name = "centre", from = 0, to = CENTRE_SIZE * 1.6 * 0.5 }),
	table.freeze({ name = "size", from = CUBE_OFFSET - CUBE_SIZE * CUBE_HIT_MUL * 0.5,
		to = CUBE_OFFSET + CUBE_SIZE * CUBE_HIT_MUL * 0.5 }),
	table.freeze({ name = "rotate", from = RING_RADIUS - RING_THICK * HITTEST_MUL * 0.5,
		to = RING_RADIUS + RING_THICK * HITTEST_MUL * 0.5 }),
	table.freeze({ name = "move", from = CONE_OFFSET - TIP_LENGTH * CONE_HIT_MUL * 0.5,
		to = CONE_OFFSET + TIP_LENGTH * CONE_HIT_MUL * 0.5 }),
})

local AXIS_COLOR = {
	Color3.fromRGB(225, 68, 74),
	Color3.fromRGB(118, 210, 96),
	Color3.fromRGB(70, 142, 245),
}
local HOVER_COLOR = Color3.fromRGB(255, 176, 64)
local AXIS_DIR = { Vector3.xAxis, Vector3.yAxis, Vector3.zAxis }

-- Degenerate-view thresholds, from Blender (translate) and Godot (rotate).
local TRANSLATE_MIN_ANGLE = math.rad(5)
local ROTATE_MIN_DOT = math.cos(math.rad(85))
-- Fast-spin guards. The rotate drag reads a frame-to-frame signed angle, which is only
-- meaningful while consecutive frames are close together. Sweep the cursor hard and two
-- things break it: the grab point crosses NEAR THE CENTRE, where the angle is noise and can
-- swing 180 degrees in a frame, and the frame gap itself gets big enough that the sign is a
-- coin toss. So a sample too close to the centre is dropped, and a delta too large for one
-- frame is treated as that crossing rather than as real rotation.
local ROTATE_MIN_RADIUS = 0.25          -- of the ring radius

-- Resize limits. A building block is not a landmass: the floor keeps it clickable and the
-- ceiling is what stops one stray sideways drag from paving the map.
local MIN_PART_SIZE = 0.2
local MAX_PART_SIZE = 200   -- studs, so 100 m on a side
local MIN_MODEL_SCALE = 0.05
local MAX_MODEL_SCALE = 25
-- MUST MATCH NaturePlaceService's own clamp. The server refuses a stretch outside this and
-- silently gives you the clamped one back, so a client that allowed more showed a preview
-- BIGGER than the thing it was going to place -- you sized it, let go, and it shrank.
-- Cumulative, not per-drag: the server multiplies each drag into what the prop already
-- carries, so the ceiling has to be measured against that too.
local MIN_STRETCH, MAX_STRETCH = 0.05, 20

-- == Snapping model ============================================================
export type Channel = "move" | "size" | "rotate"

-- The world runs at RoadConstants.STUD_TO_METER (0.5 at the current WORLD_SCALE, so two
-- studs to the metre) and every other length the player is shown is in metres. Rotation
-- stays in degrees, which need no conversion.
--
-- MOVE is the exception: it reads PlacementGrid (1 / 5 / 10 m / Off) -- see presetsFor.
--
-- ONE STEP IS TWO METRES. Not one: a builder's unit here is a wall panel, not a floor tile,
-- and a default that took two presses to clear a block is a default nobody kept. Everything
-- below it is a division of that, so the player never types a number -- "1x, half, quarter,
-- eighth, off" is the whole model.
local STUD_PER_METRE = 1 / RoadConstants.STUD_TO_METER
local STEP_METRES = 2
local SNAP_DEFAULT: { [string]: number } = table.freeze({
	size = STEP_METRES * STUD_PER_METRE,
	-- 15, not 45: at 45 a turn jumped an eighth of a circle at a time and read as the ring
	-- being broken rather than snapped.
	rotate = 15,
})
local SNAP_DIVISOR: { [string]: number } =
	table.freeze({ Default = 1, Half = 2, Quarter = 4, Eighth = 8 })

-- Labelled as MULTIPLES of the step, not as absolute lengths: the same five rows then mean
-- the same thing on all three channels, and the row caption carries what 1x currently works
-- out to. CUSTOM IS GONE -- a free-text box next to a preset dropdown read as if the number
-- in it was the live step, and five divisions cover everything anybody reached for it for.
EditorGizmos.PRESETS = table.freeze({
	table.freeze({ key = "Default", label = "1\u{00D7}" }),
	table.freeze({ key = "Half", label = "\u{00BD}\u{00D7}" }),
	table.freeze({ key = "Quarter", label = "\u{00BC}\u{00D7}" }),
	table.freeze({ key = "Eighth", label = "\u{215B}\u{00D7}" }),
	table.freeze({ key = "None", label = "Off" }),
})
EditorGizmos.CHANNELS = table.freeze({ "move", "size", "rotate" } :: { Channel })

-- The rows a channel offers. Move's are the placement grid's sizes (keyed by metres) plus
-- Off; the other two share PRESETS.
function EditorGizmos.presetsFor(channel: Channel): { { key: string, label: string } }
	if channel ~= "move" then return EditorGizmos.PRESETS :: any end
	local list = {}
	for _, m in PlacementGrid.SIZES do table.insert(list, { key = tostring(m), label = m .. "m" }) end
	table.insert(list, { key = "None", label = "Off" })
	return list
end

local _preset: { [string]: string } = { size = "Default", rotate = "Default" }
local _space = "Relative"
-- A city is built on a grid, so a snapped move lands on WORLD coordinates rather than on
-- multiples of wherever the drag happened to start. Every general-purpose editor defaults
-- to the relative form; a builder wants its blocks to tile with their neighbours, and a
-- prop dropped at x = 3.7 must not stay off-grid forever.
local _absoluteGrid = true
-- Height is the one axis a builder often wants free: a prop seated on a kerb or a roof top
-- is at whatever Y that surface is, not a multiple of a stud. Its own toggle, on by default.
local _verticalSnap = true

local function isChannel(c: any): boolean
	return c == "move" or c == "size" or c == "rotate"
end

function EditorGizmos.getStep(channel: Channel): number
	if not isChannel(channel) then return 0 end
	local step: number
	if channel == "move" then
		step = PlacementGrid.step()
		if step <= 0 then return 0 end
	else
		local p = _preset[channel]
		if p == "None" then return 0 end
		step = SNAP_DEFAULT[channel] / (SNAP_DIVISOR[p] or 1)
	end
	-- Blender's precision modifier: holding it divides the increment by ten.
	if Settings.isActionDown("PreciseModifier") then step *= 0.1 end
	return step
end

local function snapTo(v: number, step: number): number
	if step <= 0 then return v end
	return math.round(v / step) * step
end

function EditorGizmos.snapLen(v: number): number return snapTo(v, EditorGizmos.getStep("move")) end
function EditorGizmos.snapSize(v: number): number return snapTo(v, EditorGizmos.getStep("size")) end
function EditorGizmos.snapDeg(d: number): number return snapTo(d, EditorGizmos.getStep("rotate")) end

function EditorGizmos.setSnapPreset(channel: Channel, key: string)
	if not isChannel(channel) then return end
	if channel == "move" then
		if key == "None" then PlacementGrid.setEnabled(false) else PlacementGrid.setSize(tonumber(key) or 0) end
		return
	end
	for _, p in EditorGizmos.PRESETS do
		if p.key == key then _preset[channel] = key; return end
	end
end

function EditorGizmos.getSnapPreset(channel: Channel): string
	if channel == "move" then
		return if PlacementGrid.isEnabled() then tostring(PlacementGrid.getSize()) else "None"
	end
	return if isChannel(channel) then _preset[channel] else "Default"
end

-- @deprecated: there is no custom step any more -- pick a PRESET. Kept as a no-op so an
-- older caller cannot silently put a channel into a state nothing can display.
function EditorGizmos.setCustomStep(_channel: Channel, _v: number) end
function EditorGizmos.getCustomStep(channel: Channel): number
	return EditorGizmos.getStep(channel)
end

-- Metres in, studs out. The panel and the player talk metres; everything below this line
-- talks studs, and this is the only conversion.
function EditorGizmos.toMetres(studs: number): number return studs * RoadConstants.STUD_TO_METER end
function EditorGizmos.toStuds(metres: number): number return metres * STUD_PER_METRE end

function EditorGizmos.stepLabel(channel: Channel): string
	local step = EditorGizmos.getStep(channel)
	if step <= 0 then return "free" end
	if channel == "rotate" then return string.format("%g\u{00B0}", step) end
	return string.format("%g m", EditorGizmos.toMetres(step))
end

-- What one preset works out to, as the player reads it: "2m", "50cm", "15°", "Off".
function EditorGizmos.presetLabel(channel: Channel, key: string): string
	if key == "None" or not isChannel(channel) then return "Off" end
	if channel == "move" then return key .. "m" end
	local step = SNAP_DEFAULT[channel] / (SNAP_DIVISOR[key] or 1)
	if channel == "rotate" then return string.format("%g\u{00B0}", step) end
	local m = EditorGizmos.toMetres(step)
	return if m < 1 then string.format("%gcm", m * 100) else string.format("%gm", m)
end

function EditorGizmos.setSpace(space: string)
	if space ~= "Global" and space ~= "Relative" then return end
	_space = space
end

function EditorGizmos.getSpace(): string return _space end

function EditorGizmos.setAbsoluteGrid(on: boolean) _absoluteGrid = on == true end
function EditorGizmos.isAbsoluteGrid(): boolean return _absoluteGrid end

function EditorGizmos.setVerticalSnap(on: boolean) _verticalSnap = on == true end
function EditorGizmos.isVerticalSnap(): boolean return _verticalSnap end

-- == State =====================================================================
export type Deps = {
	getSelected: () -> Instance?,
	getSelectedId: () -> number?,
	sendCmd: (payload: { [string]: any }) -> (),
	fitsPivot: (inst: Instance, newPivot: CFrame, newSize: Vector3?) -> boolean,
}

type Handle = {
	kind: string,             -- "move" | "centre" | "rotate" | "size"
	axis: number,
	-- +1 or -1. Move cones and resize cubes exist on BOTH ends of every axis, so a drag
	-- knows which face it is pulling: the +X cube grows the +X side and plants the -X one,
	-- and the -X cube does the mirror of that.
	dir: number,
	-- Invisible, oversized, catches the mouse. A LIST because a ring is hit-tested as its
	-- own chord segments -- one flat box across the circle would swallow every plane and
	-- centre handle sitting inside it.
	hit: { HandleAdornment },
	solid: { HandleAdornment },
	ghost: { HandleAdornment },
}

local _deps: Deps? = nil
local _owner: string? = nil
local _mode = "Select"

local _folder: Folder? = nil
local _handles: { Handle } = {}
-- The rotation sweep fill (see FAN_SEGMENTS). Kept apart from _handles because it is pure
-- readout: it is never hit-tested and never hovered.
local _fan: { BoxHandleAdornment } = {}
local _built = false
local _hover: Handle? = nil
-- Pivot: a FRACTION of the selection's bounding box, in the box's own space. Zero is the
-- centre. While _pivotMode is on the arrows drag this instead of the object.
local _pivotLocal = Vector3.zero
local _pivotMode = false

-- One grab's worth of state. Deliberately untyped: a drag carries a different half-dozen
-- fields per handle kind (a rotate has an accumulator, a resize has two scales, a pivot
-- drag has a box), and a union of all of them documents nothing. beginDrag is the schema.
local _drag: any = nil

-- == Shared helpers ===========================================================
-- The number the OWNER of the selection thinks in. A nature prop's template is baked at
-- some arbitrary Model.Scale (a windmill imports at 0.0175), so its catalog scale rides on
-- an attribute and that is what the server validates against -- reporting Model.Scale here
-- sent the server a number from a completely different range, which it then clamped.
function EditorGizmos.selectionScale(inst: Instance): number
	if inst:IsA("Model") then
		local ns = inst:GetAttribute("NatureScale")
		if typeof(ns) == "number" and (ns :: number) > 0 then return ns :: number end
		return (inst :: Model):GetScale()
	end
	if inst:IsA("BasePart") then
		local base = inst:GetAttribute("BaseSize")
		if typeof(base) == "Vector3" and (base :: Vector3).X > 0 then
			return (inst :: BasePart).Size.X / (base :: Vector3).X
		end
	end
	return 1
end

local function comp3(v: Vector3, i: number): number
	return if i == 1 then v.X elseif i == 2 then v.Y else v.Z
end

local function withComp3(v: Vector3, i: number, value: number): Vector3
	if i == 1 then return Vector3.new(value, v.Y, v.Z) end
	if i == 2 then return Vector3.new(v.X, value, v.Z) end
	return Vector3.new(v.X, v.Y, value)
end

-- Where a ONE-SIDED resize puts the body and the pivot: the face you are not holding stays
-- exactly where it was, Blender-style. A part always resizes about its own centre, so the
-- only way to plant a face is to move the body by half the growth toward the side pulled.
--
-- PURE, and every input is frozen at the grab -- which is the entire point. The old form
-- re-read the part's LIVE CFrame each frame to work out where the pivot sat inside it, but
-- the drag moves that part, so each frame corrected for a shift it had already applied.
-- Exported so the spec can hold both halves: the planted face, and the fact that feeding a
-- later frame's state back in changes nothing.
function EditorGizmos.resizeFrames(
	startPartCF: CFrame, startSize: Vector3, pivotRot: CFrame,
	axisIdx: number, side: number, newComp: number
): (CFrame, Vector3, CFrame)
	local newSize = withComp3(startSize, axisIdx, newComp)
	local axisDir = pivotRot:VectorToWorldSpace(withComp3(Vector3.zero, axisIdx, 1))
	local growth = newComp - comp3(startSize, axisIdx)
	local partCF = startPartCF + axisDir * (side * growth * 0.5)
	-- Re-SEATED on the part's new base, which is exactly what NaturePlaceService.applyStretch
	-- does on the round trip. Report anything else and the server plants the prop at a
	-- different height the moment you let go -- that is what launched a stretched block into
	-- the air and sank a shrunk one into the ground.
	local pivot = CFrame.new(partCF.Position - partCF.UpVector * (newSize.Y * 0.5)) * pivotRot
	return partCF, newSize, pivot
end

local function selected(): Instance?
	local d = _deps
	if not d then return nil end
	local inst = d.getSelected()
	if inst and inst.Parent then return inst end
	return nil
end

-- A shape primitive is a Model wrapping exactly ONE BasePart, and that is most of what
-- gets placed in precise mode. Resizing one is therefore a PART resize -- stretch that axis
-- and leave the opposite face where it is -- not the uniform ScaleTo a Model normally gets.
-- Only a genuinely multi-part model has to scale as a whole.
local function solePart(inst: Instance): BasePart?
	if inst:IsA("BasePart") then return inst :: BasePart end
	if not inst:IsA("Model") then return nil end
	local found: BasePart? = nil
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") then
			if found then return nil end -- more than one: not stretchable
			found = d :: BasePart
		end
	end
	return found
end

local function selectionBox(): (CFrame?, Vector3?)
	local inst = selected()
	if not inst then return nil, nil end
	if inst:IsA("Model") then return (inst :: Model):GetBoundingBox() end
	if inst:IsA("BasePart") then local part = inst :: BasePart; return part.CFrame, part.Size end
	return nil, nil
end

-- Relative carries the selection's own rotation -- which is what makes the gizmo turn with
-- the object -- Global keeps the world's axes. The pivot offset is stored in the box's OWN
-- space so it rides along when the object turns, which is the only way a moved pivot stays
-- where you put it.
local function gizmoFrame(): CFrame?
	local cf, size = selectionBox()
	if not cf then return nil end
	local box = cf :: CFrame
	local at = box * (_pivotLocal * (size or Vector3.one))
	if _space == "Global" then return CFrame.new(at) end
	return box.Rotation + at
end

-- Pivot offset is held as a FRACTION of the box, so it survives a resize: (0,0,0) is the
-- centre, (0,-0.5,0) the base. Reset and Align are those two constants.
function EditorGizmos.setPivotMode(on: boolean) _pivotMode = on == true end
function EditorGizmos.isPivotMode(): boolean return _pivotMode end
function EditorGizmos.resetPivot() _pivotLocal = Vector3.zero end
function EditorGizmos.alignPivot() _pivotLocal = Vector3.new(0, -0.5, 0) end
function EditorGizmos.getPivotLocal(): Vector3 return _pivotLocal end
function EditorGizmos.hasPivotOffset(): boolean return _pivotLocal.Magnitude > 1e-4 end

-- Studio's formula: a constant apparent size at any camera distance.
local function gizmoScale(centre: Vector3): number
	local cam = Workspace.CurrentCamera
	if not cam then return 1 end
	local dist = (cam.CFrame.Position - centre).Magnitude
	return math.clamp(math.sin(math.rad(cam.FieldOfView)) * dist * SCALE_FACTOR, 0.05, 80)
end

local function mouseRay(): Ray?
	local cam = Workspace.CurrentCamera
	if not cam then return nil end
	local m = UserInputService:GetMouseLocation()
	return cam:ViewportPointToRay(m.X, m.Y)
end

local function intersectRayPlane(origin: Vector3, dir: Vector3, pOrigin: Vector3, pNormal: Vector3): Vector3?
	local denom = dir:Dot(pNormal)
	if math.abs(denom) < 1e-6 then return nil end
	local t = (pOrigin - origin):Dot(pNormal) / denom
	if t <= 0 then return nil end
	return origin + dir * t
end

-- == Building the adornments ==================================================
-- Under PlayerGui so Roblox does the 3D hit testing for us -- adornment mouse events only
-- fire when parented to PlayerGui or CoreGui.
local function adorn(class: string, color: Color3, alwaysOnTop: boolean, transparency: number): HandleAdornment
	local a = Instance.new(class) :: HandleAdornment
	-- ZIndex defaults to -1, and at -1 AlwaysOnTop is silently ignored. Studio sets 0 on
	-- every adornment for exactly this reason.
	a.ZIndex = 0
	a.AdornCullingMode = Enum.AdornCullingMode.Never -- or the gizmo gets distance-culled
	a.AlwaysOnTop = alwaysOnTop
	a.Transparency = transparency
	a.Color3 = color
	a.Adornee = Workspace.Terrain -- a neutral, always-present anchor at the world origin
	a.Parent = _folder
	return a
end

-- `visClasses` is a LIST, one entry per drawn piece, because an arrow is a cylinder shaft
-- and a CONE tip -- two different adornment classes in one handle.
local function newHandle(kind: string, axis: number, dir: number, hitClass: string, visClasses: { string },
	color: Color3, hitCount: number): Handle
	local hit, solid, ghost = {}, {}, {}
	for _ = 1, hitCount do
		-- Fully invisible: only the SHAPE pickHandle tests. These used to catch the mouse
		-- themselves, and MouseEnter has no depth order -- whichever adornment fired last
		-- won, so a ring behind a resize cube could steal its click.
		table.insert(hit, adorn(hitClass, color, true, 1))
	end
	for _, class in visClasses do
		-- Two passes: opaque where nothing occludes it, a ghost where geometry does. Keeps
		-- the depth cue without ever losing the handle behind a building.
		table.insert(solid, adorn(class, color, false, 0))
		table.insert(ghost, adorn(class, color, true, GHOST_TRANSPARENCY))
	end
	local h: Handle = { kind = kind, axis = axis, dir = dir, hit = hit, solid = solid, ghost = ghost }
	table.insert(_handles, h)
	return h
end

-- Returns false when the adornments could not be built YET. Never a bare WaitForChild:
-- build() runs inside claim() and inside the render loop, so a wait here hangs whichever
-- tool just claimed the gizmo. "Not ready" simply means not this frame -- sync() runs again
-- on the next one.
local function build(): boolean
	if _built then return true end
	local player = Players.LocalPlayer
	local gui = player and player:FindFirstChild("PlayerGui")
	if not gui then return false end
	_built = true
	local folder = Instance.new("Folder")
	folder.Name = "TransformGizmo"
	folder.Parent = gui
	_folder = folder

	local ringClasses = table.create(RING_SEGMENTS, "CylinderHandleAdornment")
	for axis = 1, 3 do
		local c = AXIS_COLOR[axis]
		-- One hit chord per drawn chord, each 4x thicker.
		newHandle("rotate", axis, 1, "CylinderHandleAdornment", ringClasses, c, RING_SEGMENTS)
		for _, dir in { 1, -1 } do
			-- A bare cone: no shaft. The hitbox is a cylinder around it, because a cone's own
			-- shape tapers to nothing exactly where you aim.
			newHandle("move", axis, dir, "CylinderHandleAdornment", { "ConeHandleAdornment" }, c, 1)
			newHandle("size", axis, dir, "BoxHandleAdornment", { "BoxHandleAdornment" }, c, 1)
		end
	end
	newHandle("centre", 0, 1, "BoxHandleAdornment", { "BoxHandleAdornment" }, Color3.fromRGB(235, 238, 244), 1)

	-- The rotation sweep fill. Not handles -- nothing hit-tests them, they only ever show
	-- while a ring is being dragged.
	for _ = 1, FAN_SEGMENTS do
		table.insert(_fan, adorn("BoxHandleAdornment", AXIS_COLOR[1], true, FAN_TRANSPARENCY) :: BoxHandleAdornment)
	end
	return true
end

local function hideFan()
	for _, a in _fan do a.Visible = false end
end

local function hideAll()
	for _, h in _handles do
		for _, a in h.hit do a.Visible = false end
		for _, a in h.solid do a.Visible = false end
		for _, a in h.ghost do a.Visible = false end
	end
	for _, a in _fan do a.Visible = false end
end

local function shape(a: HandleAdornment, cf: CFrame, size: Vector3)
	a.CFrame = cf
	a.Visible = true
	if a:IsA("BoxHandleAdornment") then
		(a :: BoxHandleAdornment).Size = size
	elseif a:IsA("CylinderHandleAdornment") then
		local cy = a :: CylinderHandleAdornment
		cy.Radius, cy.Height = size.X, size.Z
	elseif a:IsA("ConeHandleAdornment") then
		local co = a :: ConeHandleAdornment
		co.Radius, co.Height = size.X, size.Z
	end
end

-- Place one visual pair, and optionally the hitbox that shares its index.
local function put(h: Handle, index: number, cf: CFrame, size: Vector3, hitCf: CFrame?, hitSize: Vector3?)
	local hovered = _hover == h or (_drag and _drag.handle == h)
	local thick = if hovered then HOVER_THICKEN else 1
	local vis = Vector3.new(size.X * thick, size.Y * thick, size.Z)
	shape(h.solid[index], cf, vis)
	shape(h.ghost[index], cf, vis)
	h.solid[index].Color3 = if hovered then HOVER_COLOR else AXIS_COLOR[math.max(h.axis, 1)]
	h.ghost[index].Color3 = h.solid[index].Color3
	local hit = h.hit[index]
	if hit and hitCf and hitSize then shape(hit, hitCf, hitSize) end
end

-- The sweep readout inside the ring being dragged: a fan of thin slices from the centre
-- out to the ring, covering the angle turned so far. It FLIPS past a half turn -- filling
-- the other way round rather than growing past 180 degrees -- which is how every protractor
-- handle reads, and is the only way the fill stays a legible "how far" instead of a blob.
local function layoutFan(frame: CFrame, S: number, axis: number, degrees: number, color: Color3)
	local total = math.clamp(degrees, -360, 360)
	local turns = math.abs(total) % 360
	local flipped = turns > 180
	if flipped then turns = 360 - turns end
	local sign = if (total < 0) ~= flipped then -1 else 1
	local r = RING_RADIUS * S
	local u = AXIS_DIR[axis % 3 + 1]
	local v = AXIS_DIR[(axis + 1) % 3 + 1]
	local sweep = math.rad(turns)
	local step = sweep / FAN_SEGMENTS
	-- A slice is a flat box standing on the mid-radius, so its width is the chord THERE.
	-- 1.6x that covers the outer edge's longer chord without the inner overlap showing.
	local width = if step > 0 then r * math.sin(step * 0.5) * 1.6 else 0
	for i, a in _fan do
		if i > FAN_SEGMENTS or sweep <= 1e-4 then a.Visible = false; continue end
		local t = (i - 0.5) * step * sign
		local d = (u * math.cos(t) + v * math.sin(t))
		a.CFrame = frame * CFrame.lookAt(d * (r * 0.5), d * r)
		a.Size = Vector3.new(width, RING_THICK * S * 0.4, r)
		a.Color3 = color
		a.Visible = true
	end
end

local function layout(frame: CFrame, S: number)
	local showMove = _mode == "Move" or _mode == "Transform"
	local showRot = _mode == "Rotate" or _mode == "Transform"
	-- Transform is the ALL-IN-ONE: cones, rings and cubes together. Size was gated to its
	-- own mode, so the one mode anything actually sets showed no resize grips whatsoever --
	-- which is why scaling looked like it simply did not exist.
	local showSize = _mode == "Scale" or _mode == "Transform"
	-- Moving the pivot is a move gesture with a different target: cones only, no rings, no
	-- cubes, because a pivot has no size and turning it means nothing.
	if _pivotMode then showRot, showSize = false, false end
	-- Every real gizmo hides the handles you are not using while you drag.
	local dragging = _drag ~= nil

	if dragging and _drag.handle.kind == "rotate" then
		layoutFan(frame, S, math.max(_drag.handle.axis, 1), _drag.shownDeg or 0,
			AXIS_COLOR[math.max(_drag.handle.axis, 1)])
	else
		for _, a in _fan do a.Visible = false end
	end

	for _, h in _handles do
		local on = (h.kind == "move" and showMove)
			or (h.kind == "centre" and showMove)
			or (h.kind == "rotate" and showRot)
			or (h.kind == "size" and showSize)
		if dragging and _drag and _drag.handle ~= h then on = false end
		if not on then
			for _, a in h.hit do a.Visible = false end
			for _, a in h.solid do a.Visible = false end
			for _, a in h.ghost do a.Visible = false end
			continue
		end

		-- Both ends of the axis, so `dir` picks which one. Adornments run along their own
		-- -Z, so looking down the SIGNED axis puts a cone's point outward either way.
		local dir = if h.axis > 0 then AXIS_DIR[h.axis] * h.dir else Vector3.yAxis
		local axisCF = frame * CFrame.lookAt(Vector3.zero, dir)

		if h.kind == "move" then
			-- A bare cone. The hitbox is a CYLINDER wrapping it: a cone tapers to nothing
			-- exactly where the eye says to aim, so hit-testing its own shape is useless.
			local cf = axisCF * CFrame.new(0, 0, -CONE_OFFSET * S)
			put(h, 1, cf, Vector3.new(TIP_RADIUS * S, TIP_RADIUS * S, TIP_LENGTH * S),
				cf, Vector3.new(TIP_RADIUS * CONE_HIT_MUL * S, TIP_RADIUS * CONE_HIT_MUL * S,
					TIP_LENGTH * CONE_HIT_MUL * S))

		elseif h.kind == "centre" then
			local sz = CENTRE_SIZE * S
			local cam = Workspace.CurrentCamera
			local cf = if cam then CFrame.lookAt(frame.Position, cam.CFrame.Position) else frame
			put(h, 1, cf, Vector3.new(sz, sz, sz * 0.25), cf, Vector3.new(sz * 1.6, sz * 1.6, sz * 1.6))

		elseif h.kind == "size" then
			local sz = CUBE_SIZE * S
			local cf = axisCF * CFrame.new(0, 0, -CUBE_OFFSET * S)
			local hitS = sz * CUBE_HIT_MUL
			put(h, 1, cf, Vector3.new(sz, sz, sz), cf, Vector3.new(hitS, hitS, hitS))

		else -- rotate: a ring of chords, each inset by cos(step/2) so the chord midpoints
			-- sit ON the circle rather than inside it.
			local u = AXIS_DIR[h.axis % 3 + 1]
			local v = AXIS_DIR[(h.axis + 1) % 3 + 1]
			local r = RING_RADIUS * S
			local step = math.pi * 2 / RING_SEGMENTS
			local inset = r * math.cos(step * 0.5)
			local chord = 2 * r * math.sin(step * 0.5)
			for i = 1, RING_SEGMENTS do
				local t = (i - 0.5) * step
				local pos = (u * math.cos(t) + v * math.sin(t)) * inset
				local tangent = (u * -math.sin(t) + v * math.cos(t))
				local cf = frame * CFrame.lookAt(pos, pos + tangent)
				-- Each chord carries its own hitbox at 4x the drawn thickness, so the
				-- grabbable band follows the ring instead of filling the disc inside it.
				put(h, i, cf, Vector3.new(RING_THICK * S, RING_THICK * S, chord),
					cf, Vector3.new(RING_THICK * HITTEST_MUL * S, RING_THICK * HITTEST_MUL * S, chord))
			end
		end
	end
end

-- == Picking =================================================================
-- Ray against every visible hitbox as an oriented box (a cylinder or cone hitbox is its
-- bounding box). The small grips -- cubes, cones, the centre -- beat the rings OUTRIGHT
-- whenever the ray touches both, and within a class the nearest hit wins. A ring can be
-- grabbed anywhere along it; a cube is one spot, so where they overlap the cube is what you
-- were aiming at.
local function rayBox(o: Vector3, d: Vector3, cf: CFrame, half: Vector3): number?
	local lo = cf:PointToObjectSpace(o)
	local ld = cf:VectorToObjectSpace(d)
	local tmin, tmax = -math.huge, math.huge
	for i = 1, 3 do
		local oi, di, hi = comp3(lo, i), comp3(ld, i), comp3(half, i)
		if math.abs(di) < 1e-9 then
			if math.abs(oi) > hi then return nil end
		else
			local t1, t2 = (-hi - oi) / di, (hi - oi) / di
			if t1 > t2 then t1, t2 = t2, t1 end
			tmin, tmax = math.max(tmin, t1), math.min(tmax, t2)
			if tmin > tmax then return nil end
		end
	end
	if tmax < 0 then return nil end
	return math.max(tmin, 0)
end
EditorGizmos.rayBox = rayBox

local function hitHalf(a: HandleAdornment): Vector3
	if a:IsA("BoxHandleAdornment") then return (a :: BoxHandleAdornment).Size * 0.5 end
	local r, h = 0, 0
	if a:IsA("CylinderHandleAdornment") then
		r, h = (a :: CylinderHandleAdornment).Radius, (a :: CylinderHandleAdornment).Height
	elseif a:IsA("ConeHandleAdornment") then
		r, h = (a :: ConeHandleAdornment).Radius, (a :: ConeHandleAdornment).Height
	end
	return Vector3.new(r, r, h * 0.5)
end

local function pickHandle(): Handle?
	local ray = mouseRay()
	if not ray then return nil end
	local o, d = ray.Origin, ray.Direction.Unit
	local best: Handle? = nil
	local bestRank, bestT = math.huge, math.huge
	for _, h in _handles do
		local rank = if h.kind == "rotate" then 1 else 0
		if rank > bestRank then continue end
		for _, a in h.hit do
			if not a.Visible then continue end
			local t = rayBox(o, d, a.CFrame, hitHalf(a))
			if t and (rank < bestRank or t < bestT) then
				best, bestRank, bestT = h, rank, t
			end
		end
	end
	return best
end

-- == Drag ======================================================================
-- The plane containing `axis` that most faces the camera: normal = axis x (axis x view).
-- Far better conditioned than a line-line solve, which is why every reference uses it.
local function axisPlaneNormal(axis: Vector3, centre: Vector3): Vector3?
	local cam = Workspace.CurrentCamera
	if not cam then return nil end
	local viewDir = (centre - cam.CFrame.Position).Unit
	local n = axis:Cross(axis:Cross(viewDir))
	if n.Magnitude < 1e-6 then return nil end
	return n.Unit
end

-- How much the cursor has travelled along `axis` since the grab. Intersecting the FROZEN
-- click ray with the SAME plane each frame is what cancels the grab offset -- and keeps it
-- cancelled while the gizmo rescales.
local function axisTravel(drag: any): number?
	local n = axisPlaneNormal(drag.axis, drag.centre)
	local r = mouseRay()
	if not (n and r) then return nil end
	local now = intersectRayPlane(r.Origin, r.Direction.Unit, drag.centre, n)
	local was = intersectRayPlane(drag.clickRay.Origin, drag.clickRay.Direction.Unit, drag.centre, n)
	if not (now and was) then return nil end
	return drag.axis:Dot(now - was)
end

-- Blender's fallback: when the axis is within 5 degrees of the view direction the
-- projection is worthless, so vertical screen motion drives the axis instead. Never freeze.
local function axisTravelFallback(drag: any): number
	local cam = Workspace.CurrentCamera
	if not cam then return 0 end
	local m = UserInputService:GetMouseLocation()
	local dy = (drag.startMouseY or m.Y) - m.Y
	return dy * gizmoScale(drag.centre) * 0.02
end

-- Luau has no optional tuple, so the failure case is a pair of nils.
local function planeBasisTravel(drag: any): (number?, number?)
	local r = mouseRay()
	if not r then return nil, nil end
	local n = drag.axis
	local now = intersectRayPlane(r.Origin, r.Direction.Unit, drag.centre, n)
	local was = intersectRayPlane(drag.clickRay.Origin, drag.clickRay.Direction.Unit, drag.centre, n)
	if not (now and was) then return nil, nil end
	local motion = now - was
	return drag.basisU:Dot(motion), drag.basisV:Dot(motion)
end

-- Snap a world coordinate rather than an offset, when absolute grid is on.
local function applyMoveSnap(startPos: Vector3, dir: Vector3, travel: number): number
	local step = EditorGizmos.getStep("move")
	if step <= 0 then return travel end
	-- A mostly-vertical drag answers to the vertical toggle, not the ground grid: seating a
	-- prop on a kerb or a roof means landing on that surface, not on a whole stud.
	if not _verticalSnap and math.abs(dir.Y) > 0.7 then return travel end
	if not _absoluteGrid then return snapTo(travel, step) end
	local target = startPos + dir * travel
	-- Snap the component of the RESULT along this direction, so a row of blocks lands on
	-- the same lattice however each drag began.
	local comp = target:Dot(dir)
	return travel + (snapTo(comp, step) - comp)
end

-- Godot's rotate measurement: the angle is read in the CAMERA-facing plane (which never
-- degenerates) and projected onto the ring's axis.
local function rotateVector(drag: any): Vector3?
	local cam = Workspace.CurrentCamera
	local r = mouseRay()
	if not (cam and r) then return nil end
	local n = (drag.centre - cam.CFrame.Position).Unit
	local hit = intersectRayPlane(r.Origin, r.Direction.Unit, drag.centre, n)
	if not hit then return nil end
	local v = hit - drag.centre
	-- Near the centre the direction is noise: a cursor sweeping THROUGH it flips the vector
	-- a half turn between two frames, and the accumulator swallows that as real rotation.
	-- Drop the sample instead -- the next one outside the dead zone picks up from there.
	local dead = RING_RADIUS * gizmoScale(drag.centre) * ROTATE_MIN_RADIUS
	return if v.Magnitude > math.max(dead, 1e-6) then v.Unit else nil
end

-- The cursor's angle IN THE RING'S OWN PLANE, from basisU toward basisV. That is what makes
-- the object follow the cursor round the ring you can see: the old reading was taken in the
-- camera-facing plane and projected, which only matched the drawn ring looking straight
-- down its axis and drifted further off the more oblique the view.
local function ringAngle(drag: any): number?
	local r = mouseRay()
	if not r then return nil end
	local hit = intersectRayPlane(r.Origin, r.Direction.Unit, drag.centre, drag.axis)
	if not hit then return nil end
	local v = hit - drag.centre
	if v.Magnitude < RING_RADIUS * gizmoScale(drag.centre) * ROTATE_MIN_RADIUS then return nil end
	return math.atan2(v:Dot(drag.basisV), v:Dot(drag.basisU))
end

local function wrapPi(a: number): number
	return (a + math.pi) % (2 * math.pi) - math.pi
end

-- == Lean ======================================================================
-- WEIGHT, expressed as a LEAN rather than as a lag. What is moving tips its leading edge UP
-- and drops its trailing edge while it is under way, and settles level the moment it stops --
-- the read of something with mass being pushed, the same way a vehicle squats under
-- acceleration.
--
-- The POSITION always lands exactly. Easing that was the old sway, and a prop trailing the
-- cursor reads as the tool failing to keep up rather than as weight -- which is what it was
-- doing. Rotation and resize never leaned and still do not: a rotation swinging past its
-- angle looks like the object came loose.
--
-- Shared with the placement tool's cursor ghosts, so what you are about to put down and what
-- you are dragging behave identically.
local LEAN_PER_STUD = 0.16  -- degrees per stud/second of travel
local LEAN_MAX = 11         -- degrees; past this it reads as a stunt, not as weight
local LEAN_SETTLE = 7       -- how fast the lean follows a change in speed, 1/s
local LEAN_MAX_DT = 1 / 20  -- a long frame is clamped rather than trusted

-- `state` is the smoothed horizontal velocity, carried by the caller between frames. Hands
-- back the lean to apply to an ORIENTATION, and the new state.
function EditorGizmos.leanStep(state: Vector3, velocity: Vector3, dt: number): (CFrame, Vector3)
	local flat = Vector3.new(velocity.X, 0, velocity.Z)
	local smoothed = state:Lerp(flat, math.clamp(math.min(dt, LEAN_MAX_DT) * LEAN_SETTLE, 0, 1))
	local speed = smoothed.Magnitude
	if speed < 1e-3 then return CFrame.identity, smoothed end
	-- dir x up is the axis that raises the FRONT: for dir = +X that is +Z, and a positive
	-- turn about +Z lifts +X. Get the cross product the other way round and it digs in.
	local axis = smoothed.Unit:Cross(Vector3.yAxis)
	if axis.Magnitude < 1e-4 then return CFrame.identity, smoothed end
	return CFrame.fromAxisAngle(axis.Unit, math.rad(math.min(speed * LEAN_PER_STUD, LEAN_MAX))), smoothed
end

-- A one-sided resize places the BODY itself: the part is moved and re-sized, and the model's
-- pivot is then re-SEATED on the part's new base rather than used to drag it there.
--
-- PivotTo cannot express this. It moves the body BY the pivot, so a base-seated pivot that
-- must not move (a block grown upward) means a body that does not move either -- and a part
-- always resizes about its own centre, so the block grows out of BOTH faces at once. Setting
-- Model.WorldPivot relocates the pivot without moving anything, which is the other half.
local function applySizeBody(drag: any, root: PVInstance): boolean
	if not (drag.targetSize and drag.part) then return false end
	local p = drag.part :: BasePart
	p.Size = drag.targetSize :: Vector3
	if drag.targetPartCF then p.CFrame = drag.targetPartCF :: CFrame end
	if drag.targetPivot and root:IsA("Model") then
		(root :: Model).WorldPivot = drag.targetPivot :: CFrame
	end
	return true
end

local function applySmooth(dt: number)
	local drag = _drag
	local inst = selected()
	if not (drag and inst and inst:IsA("PVInstance")) then return end
	local root = inst :: PVInstance

	-- Size and rotation land EXACTLY, every frame. Easing them reads as lag rather than as
	-- weight: a resize that trails the cursor feels broken, and a rotation that swings on
	-- past the angle looks like the object came loose. Only a MOVE leans.
	if applySizeBody(drag, root) then return end
	if drag.targetScale and root:IsA("Model") then (root :: Model):ScaleTo(drag.targetScale) end

	if not drag.targetPivot then return end
	local want = drag.targetPivot :: CFrame
	local kind = drag.handle.kind
	if kind ~= "move" and kind ~= "centre" then
		-- A resize shifts the pivot by half the growth. That shift is part of the resize,
		-- so it is exact too.
		root:PivotTo(want)
		return
	end

	-- The target lands EXACTLY -- the lean is the only thing that trails. Velocity comes from
	-- how far the target itself moved, not from how far the prop has left to go, so a snapped
	-- drag leans on each step rather than buzzing between two positions.
	local prev = drag.leanAt or want.Position
	drag.leanAt = want.Position
	local vel = if dt > 0 then (want.Position - prev) / dt else Vector3.zero
	local lean: CFrame
	lean, drag.vel = EditorGizmos.leanStep(drag.vel or Vector3.zero, vel, dt)
	root:PivotTo(CFrame.new(want.Position) * lean * want.Rotation)
end

local function beginDrag(h: Handle)
	local inst = selected()
	local frame = gizmoFrame()
	local boxCF, boxSize = selectionBox()
	if not (inst and inst:IsA("PVInstance") and frame and boxCF) then return end
	local root = inst :: PVInstance
	local f = frame :: CFrame
	local axisIdx = math.max(h.axis, 1)
	local axis = f:VectorToWorldSpace(AXIS_DIR[axisIdx]).Unit
	local u = f:VectorToWorldSpace(AXIS_DIR[axisIdx % 3 + 1]).Unit
	local v = f:VectorToWorldSpace(AXIS_DIR[(axisIdx + 1) % 3 + 1]).Unit
	local ray = mouseRay()
	if not ray then return end
	local m = UserInputService:GetMouseLocation()

	local drag: any = {
		handle = h,
		centre = f.Position,
		axis = axis,
		basisU = u,
		basisV = v,
		startPivot = root:GetPivot(),
		part = solePart(root),
		startSize = (if solePart(root) then (solePart(root) :: BasePart).Size else Vector3.one),
		-- FROZEN at the grab. A resize moves this very part, so reading its CFrame again on a
		-- later frame measures the shift the drag has already applied -- see updateDrag.
		startPartCF = (if solePart(root) then (solePart(root) :: BasePart).CFrame else nil),
		-- Two scales, deliberately: the one the OWNER talks in (catalog scale, validated by
		-- the server) and the one the INSTANCE is actually at. They are different numbers
		-- for any imported mesh, and conflating them is what clamped every resize to nothing.
		startScale = EditorGizmos.selectionScale(root),
		startModelScale = if root:IsA("Model") then (root :: Model):GetScale() else 1,
		clickRay = ray,
		accum = 0,
		startMouseY = m.Y,
		vel = Vector3.zero,
		shownDeg = 0,
		-- The gizmo rides THIS from here on, moved by exactly the delta the drag applies.
		-- Re-deriving it from the selection's bounding box every frame is what made the
		-- handles wander off during a rotate: a model's box changes shape as it turns.
		startFrame = f,
		liveFrame = f,
		boxRot = (boxCF :: CFrame).Rotation,
		boxSize = boxSize or Vector3.one,
		startPivotLocal = _pivotLocal,
		targetPivot = nil,
		targetSize = nil,
		targetScale = nil,
		liveScale = nil,
	}
	if h.kind == "centre" then
		-- Free move rides the camera-facing plane.
		local cam = Workspace.CurrentCamera
		drag.axis = if cam then (drag.centre - cam.CFrame.Position).Unit else Vector3.yAxis
		drag.basisU = if cam then cam.CFrame.RightVector else Vector3.xAxis
		drag.basisV = if cam then cam.CFrame.UpVector else Vector3.zAxis
	elseif h.kind == "rotate" then
		drag.prevVec = rotateVector(drag)
		drag.prevAngle = ringAngle(drag)
	end
	_drag = drag
end

local function endDrag()
	local drag = _drag
	local d = _deps
	_drag = nil
	if not (drag and d) then return end
	local inst = selected()
	if not (inst and inst:IsA("PVInstance")) then return end
	local root = inst :: PVInstance
	-- Land exactly on the target the last frame computed: the ease is a VISUAL, and a drag
	-- that finishes 0.02 studs short of the snap grid is not snapped.
	if not applySizeBody(drag, root) then
		if drag.targetScale and root:IsA("Model") then (root :: Model):ScaleTo(drag.targetScale) end
		if drag.targetPivot then root:PivotTo(drag.targetPivot) end
	end

	if drag.handle.kind == "size" then
		if drag.liveStretch then
			-- A one-sided stretch. Per-axis factors RELATIVE to the size at grab, so the
			-- server multiplies them into whatever the prop already carries.
			d.sendCmd({
				action = "setSize",
				id = d.getSelectedId(),
				size = (drag.part :: BasePart).Size,
				stretch = drag.liveStretch,
				cf = root:GetPivot(),
			})
		else
			local scale = drag.liveScale or EditorGizmos.selectionScale(root)
			if root:IsA("Model") then (root :: Model):SetAttribute("NatureScale", scale) end
			d.sendCmd({ action = "setScale", id = d.getSelectedId(), scale = scale })
		end
	elseif drag.targetPivot then
		-- No target means the drag moved the PIVOT, not the object: nothing to tell the
		-- server about, because the pivot is a client-side handle on an unchanged prop.
		d.sendCmd({ action = "transform", id = d.getSelectedId(), cf = root:GetPivot() })
	end
end

-- Drag the pivot instead of the object. Held as a FRACTION of the box so it survives a
-- resize, and snapped on the same move grid as everything else.
local function movePivot(drag: any, offset: Vector3)
	local sz = drag.boxSize :: Vector3
	local localOff = (drag.boxRot :: CFrame):VectorToObjectSpace(offset)
	local frac = Vector3.new(
		localOff.X / math.max(sz.X, 1e-3),
		localOff.Y / math.max(sz.Y, 1e-3),
		localOff.Z / math.max(sz.Z, 1e-3)
	)
	local p = (drag.startPivotLocal :: Vector3) + frac
	_pivotLocal = Vector3.new(
		math.clamp(p.X, -2, 2), math.clamp(p.Y, -2, 2), math.clamp(p.Z, -2, 2)
	)
	drag.liveFrame = (drag.startFrame :: CFrame) + offset
end

local function updateDrag()
	local drag = _drag
	local d = _deps
	local inst = selected()
	if not (drag and d and inst and inst:IsA("PVInstance")) then return end
	local root = inst :: PVInstance
	local kind = drag.handle.kind

	if kind == "move" then
		local cam = Workspace.CurrentCamera
		local travel: number?
		if cam then
			local viewDir = (drag.centre - cam.CFrame.Position).Unit
			-- Within 5 degrees of looking down the axis, the projection is meaningless.
			if math.abs(viewDir:Dot(drag.axis)) > math.cos(TRANSLATE_MIN_ANGLE) then
				travel = axisTravelFallback(drag)
			end
		end
		travel = travel or axisTravel(drag)
		if not travel then return end
		local snapped = applyMoveSnap(drag.startPivot.Position, drag.axis, travel)
		local offset = drag.axis * snapped
		if _pivotMode then movePivot(drag, offset); return end
		local newCf = drag.startPivot + offset
		if not d.fitsPivot(root, newCf, nil) then return end
		drag.targetPivot = newCf
		drag.liveFrame = (drag.startFrame :: CFrame) + offset

	elseif kind == "centre" then
		local tu, tv = planeBasisTravel(drag)
		if not (tu and tv) then return end
		local du = applyMoveSnap(drag.startPivot.Position, drag.basisU, tu)
		local dv = applyMoveSnap(drag.startPivot.Position, drag.basisV, tv)
		local offset = drag.basisU * du + drag.basisV * dv
		if _pivotMode then movePivot(drag, offset); return end
		local newCf = drag.startPivot + offset
		if not d.fitsPivot(root, newCf, nil) then return end
		drag.targetPivot = newCf
		drag.liveFrame = (drag.startFrame :: CFrame) + offset

	elseif kind == "rotate" then
		local cam = Workspace.CurrentCamera
		local viewN = if cam then (drag.centre - cam.CFrame.Position).Unit else drag.axis
		if math.abs(viewN:Dot(drag.axis)) < ROTATE_MIN_DOT then
			-- Godot: an edge-on ring is a line on screen, so it becomes a linear slide, one
			-- ring-radius = 90 degrees.
			local cur = rotateVector(drag)
			if cur and drag.prevVec then
				local slide = (cur - drag.prevVec):Dot(cam and cam.CFrame.RightVector or Vector3.xAxis)
				drag.accum += slide * (math.pi * 0.5)
			end
			if cur then drag.prevVec = cur end
			drag.prevAngle = nil
		else
			-- Unwrapped frame to frame in the ring's plane. A step wrapped into +-180 is
			-- unambiguous, so nothing is dropped for being fast -- the old 75-degree cap threw
			-- real rotation away on a quick flick and made the ring feel sticky.
			local a = ringAngle(drag)
			if a and drag.prevAngle then drag.accum += wrapPi(a - drag.prevAngle) end
			-- nil inside the dead zone: resume from the next good sample, never across the gap.
			drag.prevAngle = a
			drag.prevVec = nil
		end
		local deg = EditorGizmos.snapDeg(math.deg(drag.accum))
		drag.shownDeg = deg -- what the sweep fill inside the ring reads
		-- Turn about the gizmo's own origin, which is a FIXED world point for the whole
		-- drag. That point is invariant under the rotation, so the object spins where it
		-- stands and the gizmo cannot travel -- the two halves of "it slides while it turns".
		local c = drag.centre
		local about = CFrame.new(c) * CFrame.fromAxisAngle(drag.axis, math.rad(deg)) * CFrame.new(-c)
		local newCf = about * drag.startPivot
		if not d.fitsPivot(root, newCf, nil) then return end
		drag.targetPivot = newCf
		-- Global keeps the world's axes, so the rings do not turn at all; Relative turns
		-- with the object. Either way the ORIGIN stays put.
		drag.liveFrame = if _space == "Global" then drag.startFrame else about * (drag.startFrame :: CFrame)

	else -- size
		local cam = Workspace.CurrentCamera
		local travel: number?
		if cam then
			local viewDir = (drag.centre - cam.CFrame.Position).Unit
			-- The SAME degenerate guard translate has always had, which resize never got.
			-- Drag a cube whose axis points near the camera and the ray-plane solve explodes:
			-- that is the bug where moving sideways inflated the prop across the map inside
			-- two seconds.
			if math.abs(viewDir:Dot(drag.axis)) > math.cos(TRANSLATE_MIN_ANGLE) then
				travel = axisTravelFallback(drag)
			end
		end
		travel = travel or axisTravel(drag)
		if not travel then return end
		local side = drag.handle.dir
		local i = math.max(drag.handle.axis, 1)
		if drag.part then
			-- DIRECT, not a ratio. Pull the face out by three metres and it grows by three
			-- metres. The old ratio form multiplied a SMALL reference length (the cube's own
			-- offset), so a modest drag became a 20x prop -- the runaway resize.
			--
			-- ONE SIDE grows: the face you are not holding stays planted, so the pivot shifts
			-- by half the growth TOWARD the side you are pulling. `side` is what makes the
			-- -X cube the mirror of the +X one rather than a second copy of it.
			local base = comp3(drag.startSize, i)
			-- How much stretch this axis has left before the server's cumulative clamp bites.
			local held = root:GetAttribute("NatureStretch")
			local carried = if typeof(held) == "Vector3" then comp3(held :: Vector3, i) else 1
			local hi = math.min(MAX_PART_SIZE, base * (MAX_STRETCH / math.max(carried, 1e-3)))
			local lo = math.max(MIN_PART_SIZE, base * (MIN_STRETCH / math.max(carried, 1e-3)))
			local newComp = math.clamp(EditorGizmos.snapSize(base + travel * side), lo, math.max(lo, hi))
			local startPartCF = drag.startPartCF :: CFrame
			local newPartCF, newSize, newPivot = EditorGizmos.resizeFrames(
				startPartCF, drag.startSize, drag.startPivot.Rotation, i, side, newComp)
			local bodyShift = newPartCF.Position - startPartCF.Position
			if not d.fitsPivot(root, newPivot, newSize) then return end
			drag.targetSize = newSize
			drag.targetPartCF = newPartCF
			drag.targetPivot = newPivot
			-- Per-axis stretch, relative to the size at grab, is what the server has to store:
			-- one number could never describe a box pulled out on one side only.
			drag.liveStretch = Vector3.new(
				newSize.X / math.max(drag.startSize.X, 1e-3),
				newSize.Y / math.max(drag.startSize.Y, 1e-3),
				newSize.Z / math.max(drag.startSize.Z, 1e-3)
			)
			drag.liveFrame = (drag.startFrame :: CFrame) + bodyShift
		elseif root:IsA("Model") then
			-- Multi-part: uniform only, but measured against the model's OWN extent along the
			-- axis, so a drag of N studs still means N studs rather than N gizmo-scales.
			local m = root :: Model
			local _, bsize = m:GetBoundingBox()
			local base = math.max(comp3(bsize, i), 1e-3)
			local ratio = math.clamp((base + travel * side) / base, 0.05, 20)
			local target = math.clamp(drag.startModelScale * ratio, MIN_MODEL_SCALE, MAX_MODEL_SCALE)
			if not d.fitsPivot(root, m:GetPivot(), bsize * ratio) then return end
			drag.targetScale = target
			-- What the server is told, in ITS units. ScaleTo grows the model about its own
			-- pivot, so a base-pivoted prop grows up out of the ground and stays seated.
			drag.liveScale = drag.startScale * (target / math.max(drag.startModelScale, 1e-6))
		end
	end
end

-- == Public API ===============================================================
function EditorGizmos.claim(owner: string, deps: Deps)
	_owner = owner
	_deps = deps
	_pivotLocal = Vector3.zero
	_pivotMode = false
	EditorGizmos.sync()
end

function EditorGizmos.release(owner: string)
	if _owner ~= owner then return end
	_owner = nil
	_deps = nil
	_mode = "Select"
	_drag = nil
	_hover = nil
	_pivotMode = false
	_pivotLocal = Vector3.zero
	hideAll()
end

function EditorGizmos.getOwner(): string? return _owner end
function EditorGizmos.isHovering(): boolean return _hover ~= nil or _drag ~= nil end
function EditorGizmos.isDragging(): boolean return _drag ~= nil end

function EditorGizmos.sync()
	if not build() then return end
	if not _owner or _mode == "Select" then hideAll(); return end
	local frame = if _drag then (_drag :: any).liveFrame else gizmoFrame()
	if not frame then hideAll(); return end
	layout(frame :: CFrame, gizmoScale((frame :: CFrame).Position))
end

function EditorGizmos.setMode(mode: string)
	_mode = mode
	EditorGizmos.sync()
end

function EditorGizmos.getMode(): string return _mode end

-- Re-laid every frame: the scale tracks the camera and the frame tracks the selection, so
-- the gizmo turns with the object and re-seats itself when anything else moves it.
RunService.RenderStepped:Connect(function(dt: number)
	if not _owner or _mode == "Select" then return end
	if _drag then
		updateDrag()
		applySmooth(dt)
	end
	EditorGizmos.sync()
	-- After the layout, so the hitboxes tested are the ones on screen this frame.
	if not _drag then _hover = pickHandle() end
end)

UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
	-- The hitboxes no longer sink input, so `processed` here only ever means a GUI button.
	if processed or not _owner or _mode == "Select" then return end
	_hover = pickHandle()
	if _hover then beginDrag(_hover :: Handle) end
end)

UserInputService.InputEnded:Connect(function(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton1 and _drag then endDrag() end
end)

return EditorGizmos
