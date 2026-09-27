--!strict
-- @deprecated: use NaturePlacementController's Single gesture with FreePlacement on instead.
-- UNUSED as of 2026-09-07 -- nothing requires or drives this module any more.
--
-- It was armed alongside whichever gesture was selected, so a click in free mode fired TWO
-- RequestPlaceNature calls and the server's per-player cooldown ate one of them at random --
-- which is what made Line/Curve look broken while Free Placement was on. Its click-to-plant
-- was also a strictly worse copy of Single: no colour, no size stepper, no grid snap. The
-- controller now stamps free = true on its own items instead (see fireItems there), which
-- is the half that actually makes the server accept a placement on a road.

-- Its own module, deliberately separate from NaturePlacementController's four
-- gestures (Line / Brush / Single / Curve). One click, one plant, at the exact
-- clicked point -- same shape as NaturePlacementController's Single gesture --
-- but with NO road-proximity preview check at all: this mode never tints a
-- ghost red for being near a road. That is the entire difference from Single.
--
-- Server-side note: NaturePlaceService.plantOne's road/building exclusion is
-- unconditional (see NaturePlacementController's isNearRoadPreview comment) --
-- this mode only changes what the CLIENT previews, not what the server allows.
-- A placement that looks fine here can still be silently rejected server-side.
--
-- Currently driven only from the Nature rail (see TerrainPanelController /
-- NaturePlacementController wiring), but this module has no dependency on the
-- Nature tab specifically -- another section (Roads / Zoning) could construct
-- and drive its own instance the same way, once one wants this mode too.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage:WaitForChild("Networker"))
local NatureCatalog = require(ReplicatedStorage:WaitForChild("Nature"):WaitForChild("NatureCatalog"))
local SoundFX = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("SoundFX"))
local CursorRay = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("CursorRay"))
local UiScratch = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("UiScratch"))

local NatureFreePlaceMode = {}

local _enabled = false
local _bound = false

-- Palette to plant from + how to pick a key: owned by NaturePlacementController
-- (the asset cards / Randomize toggle are shared UI, not duplicated here). This
-- module is handed a getter closure rather than reaching into that controller's
-- internals directly, so the two stay decoupled beyond this one call shape.
local _pickKey: (() -> string?)? = nil

local _folder: Folder? = nil
local _ghost: Model? = nil
local _ghostKey: string? = nil
local _renderConn: RBXScriptConnection? = nil
local _beganConn: RBXScriptConnection? = nil

local function ensureFolder(): Folder
	if _folder and _folder.Parent then return _folder end
	local f = UiScratch.folder("NatureFreePlace")
	_folder = f
	return f
end

-- Plants go on bare terrain, so this is the terrain-only pick from Core.CursorRay.
local function mouseGround(): Vector3?
	return CursorRay.terrainPoint()
end

-- Per-placement variation, identical formula to NaturePlacementController.jitter:
-- random yaw + a height (uniform scale) inside the catalog range.
local function jitter(key: string): (number, number)
	local e = NatureCatalog.get(key)
	if not e then return 1, 0 end
	local scale = e.minScale + math.random() * (e.maxScale - e.minScale)
	local yaw = math.random() * math.pi * 2
	return scale, yaw
end

-- Translucent preview clone. Deliberately never tinted red -- there is no
-- isNearRoadPreview call anywhere in this module, on purpose: Free Placement
-- doesn't warn about roads at all, rather than warn-then-suppress.
local function translucentClone(key: string): Model?
	local template = ReplicatedStorage.Nature:FindFirstChild(key)
	if not (template and template:IsA("Model")) then return nil end
	local g = template:Clone()
	for _, d in g:GetDescendants() do
		if d:IsA("BasePart") then
			d.Transparency = math.max(d.Transparency, 0.5)
			d.CanCollide = false; d.CanQuery = false; d.CanTouch = false; d.Anchored = true; d.CastShadow = false
		end
	end
	g.Parent = ensureFolder()
	return g
end

local function hideGhost()
	if _ghost then _ghost:Destroy(); _ghost = nil; _ghostKey = nil end
end

local function updateGhost(point: Vector3)
	if not _pickKey then hideGhost(); return end
	local key = _pickKey()
	if not key then hideGhost(); return end
	if _ghostKey ~= key or not (_ghost and _ghost.Parent) then
		hideGhost()
		_ghost = translucentClone(key)
		_ghostKey = if _ghost then key else nil
	end
	if _ghost then
		_ghost:PivotTo(CFrame.new(point))
	end
end

local function commitAt(point: Vector3)
	if not _pickKey then return end
	local key = _pickKey()
	if not key then return end
	local scale, yaw = jitter(key)
	Net.RequestPlaceNature:FireServer({ { key = key, pos = point, yaw = yaw, scale = scale } })
	SoundFX.play("Nature")
end

-- ---------------------------------------------------------------- public API
function NatureFreePlaceMode.setPickKey(fn: () -> string?)
	_pickKey = fn
end

function NatureFreePlaceMode.setEnabled(on: boolean)
	if on == _enabled then return end
	_enabled = on
	if not on then hideGhost() end
end

function NatureFreePlaceMode.isEnabled(): boolean return _enabled end

function NatureFreePlaceMode.Init()
	ensureFolder()
end

function NatureFreePlaceMode.Bind()
	if _bound then return end
	_bound = true

	_renderConn = RunService.RenderStepped:Connect(function()
		if not _enabled then return end
		local point = mouseGround()
		if point then updateGhost(point) else hideGhost() end
	end)

	_beganConn = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if not _enabled or gameProcessed then return end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		local point = mouseGround()
		if point then commitAt(point) end
	end)
end

return NatureFreePlaceMode
