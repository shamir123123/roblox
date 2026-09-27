--!strict
-- GhostPlacement -- THE free-placement tool. A ghost rides the cursor, turns green where
-- its footprint fits and red where it doesn't, and a click sends it.
--
-- Schools, emergency/utility services and transit depots were three copies of this, ~120
-- near-identical lines each, and they had already drifted: different ray lengths, different
-- ignore lists, different guards. They are now specs, not implementations -- a tool says
-- what to build, how big it is, what it costs and where to send it, and this owns the rest.
--
-- Cursor picking is Core.CursorRay's job; this never raycasts by hand.
--
-- NOT everything called "placement" belongs here. Nature (four gestures, brush scatter,
-- bezier rows) and Plot (road-frontage subdivision) are different problems that happen to
-- share a word -- they use CursorRay directly. Fold a tool in only when it is genuinely
-- "one model, on the ground, where the cursor is".

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local SnapUtil = require(ReplicatedStorage.Road.SnapUtil)
local PlacementFit = require(ReplicatedStorage.Shared.PlacementFit)
local PlacementGrid = require(ReplicatedStorage.Shared.PlacementGrid)
local CursorRay = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("CursorRay"))
local UiScratch = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("UiScratch"))
local PlacementCostHud = require(script.Parent.Parent:WaitForChild("HUD"):WaitForChild("PlacementCostHud"))

local GhostPlacement = {}
GhostPlacement.__index = GhostPlacement

local OK_COLOR  = Color3.fromRGB(90, 210, 120)
local BAD_COLOR = Color3.fromRGB(220, 90, 80)

export type Spec = {
	-- Folder name under Workspace._UI that holds this tool's ghost.
	folderName: string,
	-- Build the ghost for `key`. Called only when the key changes or the ghost is gone.
	build: (key: string) -> Model?,
	-- Footprint of `key`: X/Z are the plan size, Y is the height the overlap box uses.
	footprint: (key: string) -> Vector3?,
	-- Money the HUD shows while the tool is live. Omit for a free tool.
	cost: ((key: string) -> number?)?,
	-- Send it. Only ever called with a pivot that passed the fit test.
	place: (key: string, pivot: CFrame) -> (),
	-- Skip the overlap veto. For DECORATION, which does not reserve ground the way a
	-- building does -- a statue beside a shop is fine, and nature props are allowed to
	-- overlap each other for the same reason. A tool that sets this still gets the ghost,
	-- the cursor tracking and the cost readout; it just never refuses a spot for being
	-- occupied. Buildings must NOT set this: overlap is exactly what stops two of them
	-- being built on the same ground.
	noOverlapCheck: boolean?,
	-- One extra rule this tool owns, asked after the footprint fits: return the reason the
	-- spot is refused, or nil. The generators use it for their keep-clear yards, which no
	-- footprint test can see. Kept as a hook rather than folded in here, because it is one
	-- tool's rule, not everyone's.
	veto: ((key: string, pivot: CFrame) -> string?)?,
}

export type Placer = typeof(setmetatable({} :: {
	spec: Spec,
	_key: string,
	_enabled: boolean,
	_yaw: number,
	_ghost: Model?,
	_ghostKey: string?,
	_pivot: CFrame?,
}, GhostPlacement))

function GhostPlacement.new(spec: Spec): Placer
	return setmetatable({
		spec = spec,
		_key = "",
		_enabled = false,
		_yaw = 0,
		_ghost = nil,
		_ghostKey = nil,
		_pivot = nil,
	}, GhostPlacement) :: any
end

-- ------------------------------------------------------------------ ghost --

function GhostPlacement.destroyGhost(self: Placer)
	if self._ghost then
		self._ghost:Destroy()
		self._ghost = nil
		self._ghostKey = nil
	end
end

local function tint(model: Model, color: Color3)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then d.Color = color end
	end
end

function GhostPlacement.ensureGhost(self: Placer): Model?
	if self._ghost and self._ghost.Parent and self._ghostKey == self._key then
		return self._ghost
	end
	self:destroyGhost()
	local ghost = self.spec.build(self._key)
	if not ghost then return nil end
	ghost.Parent = UiScratch.folder(self.spec.folderName)
	self._ghost = ghost
	self._ghostKey = self._key
	return ghost
end

-- ------------------------------------------------------------------ state --

function GhostPlacement.setKey(self: Placer, key: string)
	if key == self._key then return end
	self._key = key
	self:destroyGhost()
	self._pivot = nil
end

function GhostPlacement.getKey(self: Placer): string
	return self._key
end

-- ----------------------------------------------------------- right-drag rotate --
-- Hold right mouse and sweep: the thing about to be placed spins under the cursor. The
-- camera never sees the right button (middle is the whole mouse camera), so there is
-- nothing to arbitrate. Roads are not placed through here and keep their own handling.
local ROT_PER_PIXEL = 0.6 -- degrees of yaw per pixel dragged
local _active: Placer? = nil
local _rotating: Placer? = nil
local _lastX = 0
local _hooked = false

-- One set of connections for every tool, hooked when the first one opens and kept for the
-- session -- the placers themselves come and go, this does not.
local function hookRightDrag()
	if _hooked then return end
	_hooked = true
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or not _active then return end
		if input.UserInputType ~= Enum.UserInputType.MouseButton2 then return end
		_rotating = _active
		_lastX = UserInputService:GetMouseLocation().X
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then _rotating = nil end
	end)
	UserInputService.InputChanged:Connect(function(input: InputObject)
		local placer = _rotating
		if not placer or input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
		local x = UserInputService:GetMouseLocation().X
		placer:rotateBy((x - _lastX) * ROT_PER_PIXEL)
		_lastX = x
	end)
end

function GhostPlacement.setEnabled(self: Placer, on: boolean)
	if on == self._enabled then return end
	self._enabled = on
	if on then
		hookRightDrag()
		_active = self
	else
		self:destroyGhost()
		self._pivot = nil
		PlacementCostHud.hide()
		_rotating = nil
		if _active == self then _active = nil end
	end
end

function GhostPlacement.isEnabled(self: Placer): boolean
	return self._enabled
end

function GhostPlacement.rotate(self: Placer, degrees: number)
	self:rotateBy(if degrees ~= 0 then degrees else 45)
end

-- Raw yaw nudge, for the right-drag: rotate() reads 0 as "use the default step", this does not.
function GhostPlacement.rotateBy(self: Placer, degrees: number)
	self._yaw = (self._yaw + math.rad(degrees)) % (2 * math.pi)
end

-- ------------------------------------------------------------------ frame --

-- Does the footprint at `pivot` touch anything already in the city, or a road? PlacementFit
-- owns both answers -- the same tests the server re-runs in ServicePlacement, so a green
-- ghost is never refused on arrival. Returns the reason so the HUD can say which rule it hit.
function GhostPlacement.fits(self: Placer, pivot: CFrame, fp: Vector3): (boolean, string?)
	if not PlacementFit.boxFree(pivot, fp) then
		return false, "something is already here"
	end
	if PlacementFit.onRoad(pivot, fp) then
		return false, "can't build on a road"
	end
	return true, nil
end

-- Call once per frame while the tool is live. Parks the ghost off-screen (Parent = nil)
-- rather than destroying it when the cursor leaves the ground, so it is not rebuilt every
-- time the cursor crosses the skyline.
function GhostPlacement.update(self: Placer)
	if not self._enabled then return end
	self._pivot = nil

	local fp = self.spec.footprint(self._key)
	local ghost = self:ensureGhost()
	if not fp or not ghost then
		if ghost then ghost.Parent = nil end
		return
	end

	local hit = CursorRay.groundHit({ ignoreWater = true })
	if not hit then
		if ghost.Parent then ghost.Parent = nil end
		return
	end
	if not ghost.Parent then ghost.Parent = UiScratch.folder(self.spec.folderName) end

	-- Snapped BEFORE the fit test and before the ghost moves, so what is tested, what is
	-- drawn and what is sent are the same position. The server re-grounds Y regardless.
	local pos = hit.Position
	local yaw = self._yaw
	-- Road snap, through the SAME snap model the road tool draws with. A building never
	-- NEEDS a road: with nothing within BUILDING_SNAP_DIST this returns nil and the cursor
	-- position stands. fp.Z is the front-to-back size, so half of it is pivot -> the
	-- road-access side, which is what the setback is measured off.
	-- ponytail: every tool that places through here is a building that wants frontage, so
	-- there is no opt-out flag. Add one when something that does not belongs here.
	local roadPos, roadYaw = SnapUtil.snapBuilding(pos, fp.Z * 0.5)
	if roadPos and roadYaw then
		pos = roadPos
		-- Snapped, the ROAD decides which way is front, and R turns off that rather than off
		-- the world -- rotating a snapped building otherwise just breaks its own snap.
		yaw = roadYaw + self._yaw
	else
		-- The game-wide grid, only off-road: road snap is asked with the RAW cursor and
		-- always wins, so a coarse grid can never drag a building off its frontage.
		pos = PlacementGrid.snap(pos)
	end
	local pivot = CFrame.new(pos) * CFrame.Angles(0, yaw, 0)
	ghost:PivotTo(pivot)

	-- One place decides red-or-green AND what to tell the player. Silently refusing and
	-- letting them guess which rule they hit is the bug this closes.
	local blocked: string? = nil
	if self.spec.noOverlapCheck ~= true then
		local _ok, why = self:fits(pivot, fp)
		blocked = why
	end
	local veto = self.spec.veto
	if not blocked and veto then blocked = veto(self._key, pivot) end
	tint(ghost, if blocked then BAD_COLOR else OK_COLOR)
	self._pivot = if blocked then nil else pivot

	local costFn = self.spec.cost
	PlacementCostHud.showCost(if costFn then costFn(self._key) else nil, blocked)
end

-- The live ghost, but only while it is actually on screen. For tools that hang extra
-- visuals off it (the services' coverage ring); nil means "draw nothing this frame".
function GhostPlacement.visibleGhost(self: Placer): Model?
	local g = self._ghost
	return if g and g.Parent then g else nil
end

-- The pivot the ghost is showing, or nil when it does not fit. Tools that need to place
-- through their own path (a differently-shaped remote) can read this instead of tryPlace.
function GhostPlacement.validPivot(self: Placer): CFrame?
	return self._pivot
end

-- Click handler. Returns whether anything was sent.
function GhostPlacement.tryPlace(self: Placer): boolean
	local pivot = self._pivot
	if not self._enabled or not pivot then return false end
	self.spec.place(self._key, pivot)
	return true
end

function GhostPlacement.destroy(self: Placer)
	self:destroyGhost()
	self._enabled = false
	self._pivot = nil
	if _active == self then
		_active = nil
		_rotating = nil
	end
end

return GhostPlacement
