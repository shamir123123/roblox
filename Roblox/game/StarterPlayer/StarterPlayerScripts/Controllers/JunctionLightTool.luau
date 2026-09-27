--!strict
-- JunctionLightTool -- the Roads panel's Traffic Light card. While it is armed, the junction
-- under the cursor is ringed on the ground (green: a click puts lights up, red: a click takes
-- them down) and a click sends that ground point to the server, which flips the junction and
-- saves the choice with the city (SignalReplicationService.onToggleLights).
--
-- Client-only and decides nothing: which junction a click means, and what it does, is the
-- server's answer. The ring only mirrors the signalised list the signal editor already reads.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local DataCache = require(ReplicatedStorage.DataCache)
local CursorRay = require(script.Parent.Parent.Core.CursorRay)

local JunctionLightTool = {}

local PICK_RADIUS = 40        -- studs; matches the server's TOGGLE_PICK_RADIUS
local RING_RADIUS = 22
local LIT_REFRESH = 2         -- s between refreshes of which junctions have lights
local AFTER_CLICK_REFRESH = 0.6
local COL_ADD = Color3.fromRGB(90, 220, 120)
local COL_REMOVE = Color3.fromRGB(235, 80, 70)

local _enabled = false
local _conns: { RBXScriptConnection } = {}
local _ring: Part? = nil
local _hover: Vector3? = nil
local _lit: { Vector3 } = {}
local _nextRefresh = 0
local _net: any = nil

local function net(): any
	if not _net then _net = require(ReplicatedStorage:WaitForChild("Networker")) end
	return _net
end

local function refreshLit()
	task.spawn(function()
		local ok, reply = pcall(function()
			return net().RequestSignalData:InvokeServer({ nodes = true })
		end)
		if not ok or typeof(reply) ~= "table" or typeof(reply.nodes) ~= "table" then return end
		local lit: { Vector3 } = {}
		for _, n in reply.nodes do
			if typeof(n.x) == "number" and typeof(n.z) == "number" then
				table.insert(lit, Vector3.new(n.x, n.y or 0, n.z))
			end
		end
		_lit = lit
	end)
end

local function isLit(pos: Vector3): boolean
	for _, p in _lit do
		local dx, dz = p.X - pos.X, p.Z - pos.Z
		if dx * dx + dz * dz < 4 then return true end
	end
	return false
end

local function nearestJunction(at: Vector3): Vector3?
	local best: Vector3? = nil
	local bestSq = PICK_RADIUS * PICK_RADIUS
	for _, p in DataCache.GetIntersections() do
		local dx, dz = p.X - at.X, p.Z - at.Z
		local d2 = dx * dx + dz * dz
		if d2 < bestSq then
			bestSq = d2
			best = p
		end
	end
	return best
end

local function ring(): Part
	local r = _ring
	if r and r.Parent then return r end
	local p = Instance.new("Part")
	p.Name = "JunctionLightRing"
	p.Shape = Enum.PartType.Cylinder
	p.Size = Vector3.new(0.3, RING_RADIUS * 2, RING_RADIUS * 2)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Transparency = 0.55
	p.Parent = Workspace.CurrentCamera
	_ring = p
	return p
end

local function step()
	local now = os.clock()
	if now >= _nextRefresh then
		_nextRefresh = now + LIT_REFRESH
		refreshLit()
	end
	local ground = CursorRay.ground()
	local junction = if ground then nearestJunction(ground) else nil
	_hover = junction
	local r = ring()
	if not junction then
		r.Transparency = 1
		return
	end
	r.Transparency = 0.55
	r.Color = if isLit(junction) then COL_REMOVE else COL_ADD
	-- A cylinder's axis is its X: stand it on end so it lies flat on the junction.
	r.CFrame = CFrame.new(junction + Vector3.new(0, 0.6, 0)) * CFrame.Angles(0, 0, math.rad(90))
end

local function onInput(input: InputObject, gameProcessed: boolean)
	if gameProcessed or not _enabled then return end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end
	local target = _hover
	if not target then return end
	net().RequestToggleJunctionLights:FireServer(target)
	-- Show the result as soon as the server has had a moment to rebuild the junction.
	_nextRefresh = os.clock() + AFTER_CLICK_REFRESH
end

function JunctionLightTool.setEnabled(on: boolean)
	if on == _enabled then return end
	_enabled = on
	for _, c in _conns do c:Disconnect() end
	table.clear(_conns)
	if on then
		_nextRefresh = 0
		table.insert(_conns, RunService.RenderStepped:Connect(step))
		table.insert(_conns, UserInputService.InputBegan:Connect(onInput))
	else
		_hover = nil
		local r = _ring
		if r then
			r:Destroy()
			_ring = nil
		end
	end
end

function JunctionLightTool.isEnabled(): boolean
	return _enabled
end

return JunctionLightTool
