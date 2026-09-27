--!strict
-- EmergencyPlacementController
-- Places the service buildings (Hospital / Police / Fire + the utilities) from the
-- Civic and Utilities flyouts. The ghost rides the cursor and places FREE wherever it
-- fits (R rotates 45 degrees); the server re-validates with the same box check.
-- Coverage visuals come from the shared CoverageOverlay.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage:WaitForChild("Networker"))
local ServiceTypes = require(ReplicatedStorage.City.ServiceTypes)
local ServiceBuildingModel = require(ReplicatedStorage.City.ServiceBuildingModel)
local CoverageOverlay = require(script.Parent:WaitForChild("CoverageOverlay"))
local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))
local GhostPlacement = require(script.Parent:WaitForChild("GhostPlacement"))
local UiScratch = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("UiScratch"))

local EmergencyPlacementController = {}

local _inited = false
local _bound = false
local _renderConn: RBXScriptConnection? = nil
local _inputConn: RBXScriptConnection? = nil
local _ghostRing: BasePart? = nil
local _keepOut: { BasePart } = {}
-- Amber: this is a "you cannot build here", not a coverage reading.
local KEEP_OUT_COLOR = Color3.fromRGB(232, 168, 64)

-- Ghost lifecycle, cursor tracking, the fit test, the tint and the cost readout are all
-- GhostPlacement's. What is genuinely this tool's own is the coverage ring below.
local _placer = GhostPlacement.new({
	folderName = "EmergencyPlacement",
	build = function(key: string): Model?
		local ghost = ServiceBuildingModel.build(key, true)
		if not ghost then return nil end
		ghost.Name = "GhostEmergency_" .. key
		return ghost
	end,
	footprint = function(key: string): Vector3?
		local spec = ServiceTypes.get(key)
		return if spec then ServiceTypes.footprintStuds(spec) else nil
	end,
	cost = function(key: string): number?
		local spec = ServiceTypes.get(key)
		return if spec then spec.cost else nil
	end,
	place = function(key: string, pivot: CFrame)
		Net.RequestPlaceService:FireServer("Emergency", key, pivot)
	end,
	-- Blue on blue. Two generators may not have their YARDS overlap -- that is the ground
	-- the machine itself stands on. The amber ring below is advice about blade clearance
	-- and may overlap all it likes. Same rule as PowerService.spacingBlockedAt, so a green
	-- ghost is never refused on arrival.
	veto = function(key: string, pivot: CFrame): string?
		local spec = ServiceTypes.get(key)
		if not spec or (tonumber((spec :: any).powerOutput) or 0) <= 0 then return nil end
		if (spec :: any).yardVeto == false then return nil end
		local here = pivot.Position
		for _, m in CollectionService:GetTagged("PowerPlant") do
			if not m:IsA("Model") or not m.Parent then continue end
			local other = ServiceTypes.get(m:GetAttribute("ServiceType") or "")
			if not other or (tonumber((other :: any).powerOutput) or 0) <= 0 then continue end
			local c = m:GetPivot().Position
			local dx, dz = c.X - here.X, c.Z - here.Z
			if math.sqrt(dx * dx + dz * dz) < spec.coverageRadius + other.coverageRadius then
				return "too close to another " .. other.name
			end
		end
		return nil
	end,

})
_placer:setKey("Hospital")

local function clearRing()
	if _ghostRing then _ghostRing:Destroy(); _ghostRing = nil end
end

local function clearKeepOut()
	for _, d in _keepOut do d:Destroy() end
	table.clear(_keepOut)
end

-- The amber rings: how much room a generator WANTS, drawn around every one already
-- standing and under the ghost. This is advice about blade clearance, not a veto -- two
-- may overlap. What is actually refused is yard on yard (the blue circles), which the
-- `veto` above owns.
local function updateKeepOut()
	local spec = ServiceTypes.get(_placer:getKey())
	local spacing = spec and (spec :: any).minSpacing
	if not spacing or spacing <= 0 then
		if #_keepOut > 0 then clearKeepOut() end
		return
	end

	local at: { Vector3 } = {}
	for _, m in CollectionService:GetTagged("PowerPlant") do
		if m:IsA("Model") and m:GetAttribute("ServiceType") == _placer:getKey() then
			at[#at + 1] = m:GetPivot().Position
		end
	end
	local ghost = _placer:visibleGhost()
	if ghost then at[#at + 1] = ghost:GetPivot().Position end

	-- Reuse the discs already made; the pool only changes when a turbine goes up or down.
	while #_keepOut > #at do
		_keepOut[#_keepOut]:Destroy()
		_keepOut[#_keepOut] = nil
	end
	while #_keepOut < #at do
		local d = CoverageOverlay.makeDisc(spacing, KEEP_OUT_COLOR)
		d.Transparency = 0.82
		d.Parent = UiScratch.folder("EmergencyPlacement")
		_keepOut[#_keepOut + 1] = d
	end
	for i, pos in at do CoverageOverlay.discTo(_keepOut[i], pos) end
end

-- Reach preview under the placement ghost, so the player sees what the new
-- building would cover before clicking. Discs come from the shared CoverageOverlay.
local function updateGhostRing()
	local spec = ServiceTypes.get(_placer:getKey())
	local ghost = _placer:visibleGhost()
	if not spec or not ghost then
		if _ghostRing then _ghostRing.Parent = nil end
		return
	end
	local ring = _ghostRing
	if not ring or ring.Size.Y ~= spec.coverageRadius * 2 then
		if ring then ring:Destroy() end
		ring = CoverageOverlay.makeDisc(spec.coverageRadius, CoverageOverlay.ringColor(spec.kind))
		ring.Transparency = 0.7
		_ghostRing = ring
	end
	if not ring.Parent then ring.Parent = UiScratch.folder("EmergencyPlacement") end
	CoverageOverlay.discTo(ring, ghost:GetPivot().Position)
end

local function showOverlayForSelection()
	local spec = ServiceTypes.get(_placer:getKey())
	if spec then CoverageOverlay.show(spec.kind, "grey") end
end

function EmergencyPlacementController.setEnabled(enabled: boolean)
	if enabled == _placer:isEnabled() then return end
	_placer:setEnabled(enabled)
	if enabled then
		showOverlayForSelection()
	else
		CoverageOverlay.clear()
		clearRing()
		clearKeepOut()
	end
end

function EmergencyPlacementController.isEnabled(): boolean
	return _placer:isEnabled()
end

function EmergencyPlacementController.setServiceType(key: string)
	if not ServiceTypes.get(key) then return end
	_placer:setKey(key)
	clearRing() -- radius is per service kind, so the disc is rebuilt with the ghost
	clearKeepOut()
	if _placer:isEnabled() then showOverlayForSelection() end
end

function EmergencyPlacementController.getServiceType(): string
	return _placer:getKey()
end

function EmergencyPlacementController.Init()
	if _inited then return end
	_inited = true
end

function EmergencyPlacementController.Bind()
	if _bound then return end
	_bound = true
	_renderConn = RunService.RenderStepped:Connect(function()
		if not _placer:isEnabled() then return end
		_placer:update()
		updateGhostRing()
		updateKeepOut()
		CoverageOverlay.maybeRefresh()
	end)
	_inputConn = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if not _placer:isEnabled() or gameProcessed then return end
		if Settings.pressed("Back", input) then
			EmergencyPlacementController.setEnabled(false)
			return
		end
		if Settings.pressed("RotateObject", input) then
			_placer:rotate(45)
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		_placer:tryPlace()
	end)
end

function EmergencyPlacementController.Start() end

function EmergencyPlacementController.Cleanup()
	if _renderConn then _renderConn:Disconnect(); _renderConn = nil end
	if _inputConn then _inputConn:Disconnect(); _inputConn = nil end
	_placer:destroy()
	CoverageOverlay.clear()
	clearRing()
	clearKeepOut()
	_bound = false
	_inited = false
end

return EmergencyPlacementController
