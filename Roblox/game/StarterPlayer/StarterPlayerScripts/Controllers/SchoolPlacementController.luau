--!strict
-- SchoolPlacementController
-- Places education buildings (schools + library) from the Services flyout. The ghost rides
-- the cursor and places FREE wherever the footprint fits (R rotates 45 degrees): green =
-- fits, red = blocked. The server re-validates with the same box check.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Net = require(ReplicatedStorage:WaitForChild("Networker"))
local SchoolTypes = require(ReplicatedStorage.City.SchoolTypes)
local SchoolModel = require(ReplicatedStorage.City.SchoolModel)
local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))
local GhostPlacement = require(script.Parent:WaitForChild("GhostPlacement"))

local SchoolPlacementController = {}

local _inited = false
local _bound = false
local _renderConn: RBXScriptConnection? = nil
local _inputConn: RBXScriptConnection? = nil

-- Ghost lifecycle, cursor tracking, the fit test, the tint and the cost readout are all
-- GhostPlacement's. This file is the spec plus the tool's own keybinds.
local _placer = GhostPlacement.new({
	folderName = "ServicePlacement",
	build = function(key: string): Model?
		local ghost = SchoolModel.build(key, true)
		if not ghost then return nil end
		ghost.Name = "GhostService_" .. key
		return ghost
	end,
	footprint = function(key: string): Vector3?
		local spec = SchoolTypes.get(key)
		return if spec then SchoolTypes.footprintStuds(spec) else nil
	end,
	cost = function(key: string): number?
		local spec = SchoolTypes.get(key)
		return if spec then spec.cost else nil
	end,
	place = function(key: string, pivot: CFrame)
		Net.RequestPlaceService:FireServer("Education", key, pivot)
	end,
})
_placer:setKey("Elementary")

function SchoolPlacementController.setEnabled(enabled: boolean)
	_placer:setEnabled(enabled)
end

function SchoolPlacementController.isEnabled(): boolean
	return _placer:isEnabled()
end

function SchoolPlacementController.setSchoolType(key: string)
	if not SchoolTypes.get(key) then return end
	_placer:setKey(key)
end

function SchoolPlacementController.getSchoolType(): string
	return _placer:getKey()
end

function SchoolPlacementController.rotate(step: number)
	_placer:rotate(step)
end

function SchoolPlacementController.Init()
	if _inited then return end
	_inited = true
end

function SchoolPlacementController.Bind()
	if _bound then return end
	_bound = true
	_renderConn = RunService.RenderStepped:Connect(function()
		_placer:update()
	end)
	_inputConn = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if not _placer:isEnabled() or gameProcessed then return end
		if Settings.pressed("Back", input) then
			_placer:setEnabled(false)
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

function SchoolPlacementController.Start() end

function SchoolPlacementController.Cleanup()
	if _renderConn then _renderConn:Disconnect(); _renderConn = nil end
	if _inputConn then _inputConn:Disconnect(); _inputConn = nil end
	_placer:destroy()
	_bound = false
	_inited = false
end

return SchoolPlacementController
