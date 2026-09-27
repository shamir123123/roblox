--!strict
-- PowerLineController
-- Drawing power lines, the way roads are drawn: the first click does NOT place anything,
-- it only says where the line starts. Drag, and the run previews with the poles it would
-- build and what they would cost. The second click lays that run and leaves the anchor on
-- the far end, so a long line is drawn in as many pulls as it takes without re-picking the
-- start each time. Right-click drops the anchor; right-click again puts the tool away.
--
-- Both ends SNAP to a pole already standing. That snap is the ONLY way one line joins
-- another -- poles do not connect by standing near each other, so a run that does not
-- start (or end) on an existing pole is a separate grid, exactly as it looks.
--
-- Cursor picking is Core.CursorRay's job; this never raycasts by hand. It does not go
-- through GhostPlacement either: that owns "one model, on the ground, where the cursor is",
-- and a dragged run is a different gesture.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Net = require(ReplicatedStorage:WaitForChild("Networker"))
local ServiceTypes = require(ReplicatedStorage.City.ServiceTypes)
local PlacementFit = require(ReplicatedStorage.Shared.PlacementFit)
local CursorRay = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("CursorRay"))
local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))
local UiScratch = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("UiScratch"))
local CoverageOverlay = require(script.Parent:WaitForChild("CoverageOverlay"))
local PlacementCostHud = require(script.Parent.Parent:WaitForChild("HUD"):WaitForChild("PlacementCostHud"))

local PowerLineController = {}

local SPAN      = ServiceTypes.PowerSpan
local SNAP_DIST = ServiceTypes.PowerSnapDist
local MAX_SPAN  = ServiceTypes.PowerMaxSpan
local POLE_COST = (ServiceTypes.get("PowerPole") :: any).cost
local CHAIN_GRACE = 1 -- seconds a chained anchor waits for the server's pole to replicate

local OK_COLOR  = Color3.fromRGB(126, 214, 140)
local BAD_COLOR = Color3.fromRGB(232, 106, 100)
local WIRE_PREVIEW = Color3.fromRGB(64, 70, 76)

local _enabled = false
local _bound = false
local _anchor: Vector3? = nil
local _chainedAt: number? = nil -- when the anchor became the far end of a run just sent
local _renderConn: RBXScriptConnection? = nil
local _inputConn: RBXScriptConnection? = nil
local _poolPoles: { Model } = {}
local _poolWires: { BasePart } = {}

local function folder(): Instance
	return UiScratch.folder("PowerLinePlacement")
end

local function template(): Model?
	local props = ReplicatedStorage:FindFirstChild("Props")
	props = props and props:FindFirstChild("PowerPoles")
	local t = props and props:FindFirstChild("PowerPole_Cross")
	return if t and t:IsA("Model") then t :: Model else nil
end

local function clearPreview()
	for _, m in _poolPoles do m:Destroy() end
	for _, p in _poolWires do p:Destroy() end
	table.clear(_poolPoles)
	table.clear(_poolWires)
end

local function poleNear(pos: Vector3): Vector3?
	local best, bestD = nil, SNAP_DIST
	for _, m in CollectionService:GetTagged("PowerPole") do
		if not m:IsA("Model") or not m.Parent then continue end
		local p = m:GetPivot().Position
		local dx, dz = p.X - pos.X, p.Z - pos.Z
		local d = math.sqrt(dx * dx + dz * dz)
		if d <= bestD then best, bestD = p, d end
	end
	return best
end

-- Where a drag end wants to land. A standing pole wins; failing that, a generator pulls
-- the pole into its own yard -- a yard is only ~20 studs across, so without that the player
-- has to drop a pole almost exactly on the tower to hook it up. Both tags are stamped by
-- the server, and the same rule runs there, so the preview lands where the run will.
local function snapTo(pos: Vector3): Vector3?
	local pole = poleNear(pos)
	if pole then return pole end

	for _, m in CollectionService:GetTagged("PowerPlant") do
		if not m:IsA("Model") or not m.Parent then continue end
		local spec = ServiceTypes.get(m:GetAttribute("ServiceType") or "")
		local yard = spec and tonumber((spec :: any).powerOutput) and spec.coverageRadius or 0
		if yard <= 0 then continue end
		local c = m:GetPivot().Position
		local dx, dz = pos.X - c.X, pos.Z - c.Z
		if math.sqrt(dx * dx + dz * dz) <= yard + SNAP_DIST then
			local away = Vector3.new(dx, 0, dz)
			local dir = if away.Magnitude > 0.01 then away.Unit else Vector3.new(1, 0, 0)
			return c + dir * (yard * 0.5)
		end
	end
	return nil
end

local function isPoleAt(pos: Vector3): boolean
	return snapTo(pos) ~= nil
end

-- A pole may not stand on a road or in a building; the wire it holds may cross both. Only
-- the ENDS are tested, because a pole in the middle of a run slides along the line to clear
-- what it landed on -- the server does that silently, so previewing it red would be a lie.
local function endBlockedBy(pts: { Vector3 }): string?
	for _, p in { pts[1], pts[#pts] } do
		if not isPoleAt(p) then
			local why = PlacementFit.poleBlockedBy(p)
			if why then return why end
		end
	end
	return nil
end

-- Exactly the layout PowerService.placeRun will use, so the preview cannot promise poles
-- the server then puts somewhere else.
local function runPoints(from: Vector3, to: Vector3): { Vector3 }
	local dx, dz = to.X - from.X, to.Z - from.Z
	local len = math.sqrt(dx * dx + dz * dz)
	if len < 0.5 then return { from } end
	local steps = math.max(1, math.ceil(len / SPAN))
	local out = {}
	for i = 0, steps do out[#out + 1] = from:Lerp(to, i / steps) end
	return out
end

local function ghostPole(i: number, pos: Vector3, color: Color3)
	local m = _poolPoles[i]
	if not m then
		local t = template()
		if not t then return end
		m = t:Clone()
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") then
				d.Transparency = math.max(d.Transparency, 0.5)
				d.CanCollide = false; d.CanQuery = false; d.CastShadow = false
				d.Material = Enum.Material.SmoothPlastic
			end
		end
		m.Parent = folder()
		_poolPoles[i] = m
	end
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") and d.Transparency < 1 then d.Color = color end
	end
	m:PivotTo(CFrame.new(pos))
end

local function ghostWire(i: number, a: Vector3, b: Vector3)
	local len = (b - a).Magnitude
	if len < 0.05 then return end
	local p = _poolWires[i]
	if not p then
		p = Instance.new("Part")
		p.Anchored = true; p.CanCollide = false; p.CanQuery = false; p.CanTouch = false
		p.CastShadow = false; p.Material = Enum.Material.Neon
		p.Color = WIRE_PREVIEW
		p.Transparency = 0.35
		p.Parent = folder()
		_poolWires[i] = p
	end
	p.Size = Vector3.new(0.2, 0.2, len)
	p.CFrame = CFrame.lookAt((a + b) * 0.5, b)
end

local function trim(pool: { any }, keep: number)
	for i = #pool, keep + 1, -1 do
		pool[i]:Destroy()
		pool[i] = nil
	end
end

local function update()
	local ground = CursorRay.ground()
	if not ground then
		trim(_poolPoles, 0); trim(_poolWires, 0)
		PlacementCostHud.hide()
		return
	end
	local cursor = snapTo(ground) or ground
	local lift = Vector3.new(0, 18, 0)

	local anchor = _anchor
	local chainedAt = _chainedAt
	if anchor and chainedAt and os.clock() - chainedAt > CHAIN_GRACE then
		-- The run this anchor chains from never stood up (the server refused it and said
		-- why), so start over rather than carry on from a pole that is not there.
		_chainedAt = nil
		if not poleNear(anchor) then anchor = nil; _anchor = nil end
	end
	if not anchor then
		-- Nothing committed yet: show where the line would start.
		local why = endBlockedBy({ cursor })
		ghostPole(1, cursor, if why then BAD_COLOR else OK_COLOR)
		trim(_poolPoles, 1); trim(_poolWires, 0)
		if why then
			PlacementCostHud.showCost(nil, "a pole can't stand on " .. why)
		else
			PlacementCostHud.showCost(if isPoleAt(cursor) then 0 else POLE_COST)
		end
		return
	end

	local pts = runPoints(anchor, cursor)
	local newPoles = 0
	for i, p in pts do
		local existing = (i == 1 or i == #pts) and isPoleAt(p)
		if not existing then newPoles += 1 end
		ghostPole(i, p, OK_COLOR)
	end
	trim(_poolPoles, #pts)
	for i = 1, #pts - 1 do ghostWire(i, pts[i] + lift, pts[i + 1] + lift) end
	trim(_poolWires, math.max(0, #pts - 1))

	-- A single span longer than the wire can carry is the one thing the tool refuses.
	local over = false
	for i = 1, #pts - 1 do
		if (pts[i + 1] - pts[i]).Magnitude > MAX_SPAN + 0.5 then over = true break end
	end
	local why = if over then "that span is too long" else nil
	if not why then
		local blocked = endBlockedBy(pts)
		if blocked then why = "a pole can't stand on " .. blocked end
	end
	if why then
		for i = 1, #pts do ghostPole(i, pts[i], BAD_COLOR) end
		PlacementCostHud.showCost(nil, why)
	else
		PlacementCostHud.showCost(newPoles * POLE_COST)
	end
end

function PowerLineController.setEnabled(enabled: boolean)
	if enabled == _enabled then return end
	_enabled = enabled
	_anchor = nil
	if enabled then
		-- The blue areas: where a pole has to stand for a building to take power from it.
		CoverageOverlay.show("Power", "grey")
	else
		clearPreview()
		CoverageOverlay.clear()
		PlacementCostHud.hide()
	end
end

function PowerLineController.isEnabled(): boolean
	return _enabled
end

function PowerLineController.Init() end

function PowerLineController.Bind()
	if _bound then return end
	_bound = true

	_renderConn = RunService.RenderStepped:Connect(function()
		if not _enabled then return end
		update()
		CoverageOverlay.maybeRefresh()
	end)

	_inputConn = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if not _enabled or gameProcessed then return end

		if Settings.pressed("Back", input) or input.UserInputType == Enum.UserInputType.MouseButton2 then
			-- First press drops the run in progress, second puts the tool away -- the same
			-- two-stage cancel the road tool uses.
			if _anchor then _anchor = nil; clearPreview() else PowerLineController.setEnabled(false) end
			return
		end

		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		local ground = CursorRay.ground()
		if not ground then return end
		local point = snapTo(ground) or ground

		if not _anchor then
			_anchor = point -- first click ANCHORS; it does not build
			_chainedAt = nil
			return
		end

		local pts = runPoints(_anchor, point)
		for i = 1, #pts - 1 do
			if (pts[i + 1] - pts[i]).Magnitude > MAX_SPAN + 0.5 then return end
		end
		if endBlockedBy(pts) then return end -- the preview is already red and says why
		Net.RequestPlaceService:FireServer("PowerLine", "PowerPole", { from = _anchor, to = point })
		-- Carry on from the end just laid, so a long line is one gesture after another.
		_anchor = point
		_chainedAt = os.clock()
	end)
end

function PowerLineController.Start() end

function PowerLineController.Cleanup()
	if _renderConn then _renderConn:Disconnect(); _renderConn = nil end
	if _inputConn then _inputConn:Disconnect(); _inputConn = nil end
	clearPreview()
	CoverageOverlay.clear()
	_enabled = false
	_bound = false
end

return PowerLineController
