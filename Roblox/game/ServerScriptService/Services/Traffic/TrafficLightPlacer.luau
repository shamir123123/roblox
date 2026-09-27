--!strict
-- TrafficLightPlacer
-- Owns the physical traffic light models in Workspace._City.TrafficLights.
-- Clones the ServerStorage pole template once per signalized approach and
-- places it with PivotTo using only the intersection's own geometry: the pole
-- stands on the approaching driver's own kerb just past the junction mouth, the
-- mast arm reaches across the road, and the signal heads face the oncoming
-- traffic. Works for any road rotation because every offset is in the arm's
-- local frame (dir / right vectors from the road bezier), and the kerb it picks
-- flips with the driving side -- IntersectionDetector hands both over as
-- arm.polePos / arm.armDir.
--
-- Server-side by design: poles and lens colours replicate to clients for free,
-- so there is no client renderer and no state folder to sync.

local ServerStorage = game:GetService("ServerStorage")
local Workspace     = game:GetService("Workspace")

local IntersectionDetector = require(script.Parent.IntersectionDetector)
local TrafficConfig        = require(script.Parent.TrafficConfig)

local TrafficLightPlacer = {}

TrafficLightPlacer.COLOR_RED    = 0
TrafficLightPlacer.COLOR_YELLOW = 1
TrafficLightPlacer.COLOR_GREEN  = 2

type PoleHandle = {
	model: Model,
	red: BasePart?,
	yellow: BasePart?,
	green: BasePart?,
	sideRed: BasePart?,
	sideGreen: BasePart?,
	lastCol: number,
	lastLeftCol: number?,
	placeKey: string,
}

type NodePoles = {
	poles: { [number]: PoleHandle }, -- armIndex -> pole
	armCount: number,
}

local _template: Model? = nil
local _folder: Folder? = nil
local _nodes: { [number]: NodePoles } = {}
local _warnedMissingTemplate = false

-- == Setup =====================================================================
local function resolveTemplate(): Model?
	if _template and _template.Parent then return _template end
	local found = ServerStorage:FindFirstChild("TrafficSignalPole", true)
	if found and found:IsA("Model") then
		_template = found
		return found
	end
	if not _warnedMissingTemplate then
		_warnedMissingTemplate = true
		warn("[TrafficLightPlacer] No TrafficSignalPole model found anywhere in ServerStorage")
	end
	return nil
end

local function lightsFolder(): Folder
	if _folder and _folder.Parent then return _folder end
	local city = Workspace:FindFirstChild("_City")
	if not city then
		city = Instance.new("Folder")
		city.Name = "_City"
		city.Parent = Workspace
	end
	local f = city:FindFirstChild("TrafficLights")
	if not f or not f:IsA("Folder") then
		if f then f:Destroy() end
		f = Instance.new("Folder")
		f.Name = "TrafficLights"
		f.Parent = city
	end
	_folder = f :: Folder
	return _folder :: Folder
end

-- == Geometry ==================================================================
local function cframeWithLocalX(position: Vector3, localXDirection: Vector3): CFrame
	local x = Vector3.new(localXDirection.X, 0, localXDirection.Z)
	x = if x.Magnitude < 1e-4 then Vector3.xAxis else x.Unit
	local z = x:Cross(Vector3.yAxis)
	z = if z.Magnitude < 1e-4 then Vector3.zAxis else z.Unit
	local y = z:Cross(x).Unit
	return CFrame.fromMatrix(position, x, y, z)
end

-- Aims one signal-head sub-model at the approaching traffic without disturbing
-- the mast arm it hangs from.
local function faceSignalHead(model: Model, headName: string, faceDirection: Vector3)
	local head = model:FindFirstChild(headName)
	if head and head:IsA("Model") then
		head:PivotTo(
			cframeWithLocalX(head:GetPivot().Position, faceDirection)
				* CFrame.Angles(0, TrafficConfig.SIGNAL_HEAD_YAW, 0)
		)
	end
end

local function prepareClone(model: Model)
	for _, inst in ipairs(model:GetDescendants()) do
		if inst:IsA("BasePart") then
			inst.Anchored = true
			inst.CanCollide = false
			inst.CanTouch = false
			inst.CanQuery = false
		end
	end
end

local function childPart(parent: Instance, headName: string, lensName: string): BasePart?
	local head = parent:FindFirstChild(headName)
	local lens = head and head:FindFirstChild(lensName)
	return if lens and lens:IsA("BasePart") then lens else nil
end

local function placeKeyFor(arm: IntersectionDetector.Arm): string
	local p, d = arm.polePos, arm.dir
	return string.format("%.1f,%.1f,%.1f|%.2f,%.2f", p.X, p.Y, p.Z, d.X, d.Z)
end

-- == Lenses ====================================================================
local function setLens(lens: BasePart?, color: Color3, isOn: boolean)
	if not lens then return end
	lens.Color = if isOn then color else TrafficConfig.COLOR_OFF
	lens.Material = if isOn then Enum.Material.Neon else Enum.Material.SmoothPlastic
	for _, child in ipairs(lens:GetDescendants()) do
		if child:IsA("PointLight") or child:IsA("SpotLight") or child:IsA("SurfaceLight") then
			child.Color = color
			child.Enabled = isOn
		end
	end
end

-- leftCode drives the side head as a protected-left indicator. nil = the arm
-- has no dedicated left lane, so the side head simply mirrors the main head.
-- (The side head has no yellow lens; yellow reads as red = clear the turn.)
local function applyColor(pole: PoleHandle, code: number, leftCode: number?)
	if pole.lastCol == code and pole.lastLeftCol == leftCode then return end
	pole.lastCol = code
	pole.lastLeftCol = leftCode
	setLens(pole.red, TrafficConfig.COLOR_RED_ON, code == TrafficLightPlacer.COLOR_RED)
	setLens(pole.yellow, TrafficConfig.COLOR_YELLOW_ON, code == TrafficLightPlacer.COLOR_YELLOW)
	setLens(pole.green, TrafficConfig.COLOR_GREEN_ON, code == TrafficLightPlacer.COLOR_GREEN)
	local sideCode = if leftCode ~= nil then leftCode else code
	setLens(pole.sideRed, TrafficConfig.COLOR_RED_ON, sideCode ~= TrafficLightPlacer.COLOR_GREEN)
	setLens(pole.sideGreen, TrafficConfig.COLOR_GREEN_ON, sideCode == TrafficLightPlacer.COLOR_GREEN)
end

-- == Pole construction =========================================================
local function buildPole(nodeId: number, armIndex: number, arm: IntersectionDetector.Arm): PoleHandle?
	local template = resolveTemplate()
	if not template then return nil end

	local clone = template:Clone()
	clone.Name = string.format("TrafficLight_%d_%d", nodeId, armIndex)
	prepareClone(clone)
	clone:ScaleTo(TrafficConfig.POLE_SCALE)

	-- Pole at the kerb anchor; mast arm along local +X = out across the road;
	-- heads turned back toward the approaching cars (-dir).
	clone:PivotTo(cframeWithLocalX(arm.polePos, arm.armDir))
	faceSignalHead(clone, "MainSignal", -arm.dir)
	faceSignalHead(clone, "SideSignal", -arm.dir)
	clone.Parent = lightsFolder()

	return {
		model = clone,
		red = childPart(clone, "MainSignal", "Lens_1"),
		yellow = childPart(clone, "MainSignal", "Lens_2"),
		green = childPart(clone, "MainSignal", "Lens_3"),
		sideRed = childPart(clone, "SideSignal", "Lens_1"),
		sideGreen = childPart(clone, "SideSignal", "Lens_2"),
		lastCol = -1,
		lastLeftCol = -1,
		placeKey = placeKeyFor(arm),
	}
end

-- == Public API ================================================================
function TrafficLightPlacer.Init()
	resolveTemplate()
end

-- Creates/updates the poles for one intersection. Untouched arms are reused;
-- moved or removed arms are rebuilt or destroyed.
function TrafficLightPlacer.SyncNode(plan: IntersectionDetector.IntersectionPlan)
	local entry = _nodes[plan.nodeId]
	if not entry then
		entry = { poles = {}, armCount = 0 }
		_nodes[plan.nodeId] = entry
	end

	for armIndex, arm in ipairs(plan.arms) do
		local existing = entry.poles[armIndex]
		if existing and (not existing.model.Parent or existing.placeKey ~= placeKeyFor(arm)) then
			existing.model:Destroy()
			existing = nil
			entry.poles[armIndex] = nil
		end
		if not existing then
			entry.poles[armIndex] = buildPole(plan.nodeId, armIndex, arm)
		end
	end

	for armIndex = #plan.arms + 1, entry.armCount do
		local stale = entry.poles[armIndex]
		if stale then
			stale.model:Destroy()
			entry.poles[armIndex] = nil
		end
	end
	entry.armCount = #plan.arms
end

function TrafficLightPlacer.RemoveNode(nodeId: number)
	local entry = _nodes[nodeId]
	if not entry then return end
	for _, pole in pairs(entry.poles) do
		pole.model:Destroy()
	end
	_nodes[nodeId] = nil
end

function TrafficLightPlacer.SetArmColor(nodeId: number, armIndex: number, code: number, leftCode: number?)
	local entry = _nodes[nodeId]
	local pole = entry and entry.poles[armIndex]
	if pole then applyColor(pole, code, leftCode) end
end

function TrafficLightPlacer.Clear()
	for nodeId in pairs(_nodes) do
		TrafficLightPlacer.RemoveNode(nodeId)
	end
end

return TrafficLightPlacer
