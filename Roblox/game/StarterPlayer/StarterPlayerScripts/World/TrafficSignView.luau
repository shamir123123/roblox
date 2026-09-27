--!strict
-- TrafficSignView -- draws the city's traffic signs, client-side and only near the camera.
--
-- WHERE the signs go is Road.TrafficSignPlanner's job, worked out from the replicated road
-- network whenever it changes. This view only draws: a pool of models per sign kind, placed
-- for the signs within the draw radius of what the camera looks at and handed back to the
-- pool when it moves on, so a city of thousands of signs costs a few dozen models.
--
-- LOD, cheapest first: past the draw radius a sign does not exist; past TEXT_DIST its face is
-- a plain coloured plate (no SurfaceGui, which is what text costs); close up it reads. The
-- radius follows the graphics preset and Core.RenderPressure, like the traffic view.
--
-- MODELS. A model at ReplicatedStorage.Props.TrafficSigns.<USA|Europe>.<Kind> is used as is
-- (pivot at the foot of the post, face looking down the model's -Z / LookVector); without
-- one, a placeholder is built here. Kinds: Stop, Yield, AllWay, OneWay, NoEntry, Highway,
-- Speed. A replacement Speed or OneWay model may carry a TextLabel named "Value" / "Arrow"
-- anywhere inside it and this view fills it in.
--
-- A sign that stands at a traffic light pole goes up on the pole, above the signal heads,
-- instead of on a post of its own beside it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local DataCache = require(ReplicatedStorage.DataCache)
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local TrafficSignPlanner = require(ReplicatedStorage.Road.TrafficSignPlanner)
local Settings = require(script.Parent.Parent.Core.Settings)
local RenderPressure = require(script.Parent.Parent.Core.RenderPressure)

local TrafficSignView = {}

local DRAW_DIST_BY_PRESET: { [string]: number } = { Low = 220, Medium = 340 }
local DRAW_DIST = 480
local TEXT_DIST = 170
local MAX_ACTIVE = 320
local SWEEP_EVERY = 0.25    -- s between visibility sweeps
local REPLAN_DELAY = 0.6    -- s after the last road / pole change before the plan is redone
local CELL = 128
local POLE_SNAP = 9         -- studs: a sign this close to a signal pole goes up on it
local POST_HEIGHT = 5.2     -- studs (2.6 m) to the bottom of the sign plate

type Active = { model: Model, kind: string, textOn: boolean }

local _started = false
local _signs: { TrafficSignPlanner.Sign } = {}
local _grid: { [string]: { TrafficSignPlanner.Sign } } = {}
local _active: { [string]: Active } = {}
local _pool: { [string]: { Model } } = {}
local _folder: Folder? = nil
local _poles: { Vector3 } = {}
local _poleTops: { number } = {}
local _signalNodes: { [number]: boolean } = {}
local _replanAt: number? = nil
local _nextSweep = 0
local _preset = "High"
local _conns: { RBXScriptConnection } = {}

local function cellKey(x: number, z: number): string
	return `{math.floor(x / CELL)},{math.floor(z / CELL)}`
end

-- == Models ====================================================================
local SYSTEM_FOLDER = { mutcd = "USA", vienna = "Europe" }
local KIND_NAME = { stop = "Stop", yield = "Yield", allway = "AllWay", oneway = "OneWay",
	noentry = "NoEntry", highway = "Highway", speed = "Speed" }

local function signSystem(): string
	return TrafficSignPlanner.defaultOptions(function() return false end).signSystem
end

type Look = { w: number, h: number, bg: Color3, fg: Color3, text: string, round: boolean?, ring: Color3?, textSize: number? }
local RED = Color3.fromRGB(196, 32, 36)
local WHITE = Color3.fromRGB(245, 245, 245)
local BLACK = Color3.fromRGB(20, 20, 22)
local GREEN = Color3.fromRGB(24, 110, 60)
local BLUE = Color3.fromRGB(28, 72, 160)
local LOOKS: { [string]: { [string]: Look } } = {
	mutcd = {
		stop = { w = 1.6, h = 1.6, bg = RED, fg = WHITE, text = "STOP" },
		yield = { w = 1.8, h = 1.6, bg = WHITE, fg = RED, text = "YIELD", ring = RED },
		allway = { w = 1.6, h = 1.6, bg = RED, fg = WHITE, text = "STOP\nALL WAY", textSize = 0.5 },
		oneway = { w = 1.9, h = 0.65, bg = BLACK, fg = WHITE, text = "ONE WAY" },
		noentry = { w = 1.6, h = 1.6, bg = RED, fg = WHITE, text = "DO NOT\nENTER", textSize = 0.45 },
		highway = { w = 2.6, h = 1.3, bg = GREEN, fg = WHITE, text = "FREEWAY\nENTRANCE", textSize = 0.45 },
		speed = { w = 1.25, h = 1.6, bg = WHITE, fg = BLACK, text = "SPEED\nLIMIT", ring = BLACK, textSize = 0.3 },
	},
	vienna = {
		stop = { w = 1.5, h = 1.5, bg = RED, fg = WHITE, text = "STOP" },
		yield = { w = 1.6, h = 1.4, bg = WHITE, fg = RED, text = "\u{25BD}", ring = RED },
		allway = { w = 1.5, h = 1.5, bg = RED, fg = WHITE, text = "STOP" },
		oneway = { w = 1.2, h = 1.2, bg = BLUE, fg = WHITE, text = "" },
		noentry = { w = 1.4, h = 1.4, bg = RED, fg = WHITE, text = "\u{2014}", round = true },
		highway = { w = 2.4, h = 1.4, bg = BLUE, fg = WHITE, text = "MOTORWAY", textSize = 0.45 },
		speed = { w = 1.4, h = 1.4, bg = WHITE, fg = BLACK, text = "", ring = RED, round = true },
	},
}

local function corner(parent: Instance, scale: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(scale, 0)
	c.Parent = parent
end

-- A placeholder: grey post, coloured plate, and the artwork as a SurfaceGui on the plate's
-- front (the view switches the gui off at distance, leaving the plate's colour).
local function buildPlaceholder(system: string, kind: string): Model
	local look = (LOOKS[system] or LOOKS.mutcd)[kind]
	local model = Instance.new("Model")
	model.Name = KIND_NAME[kind] or kind
	local post = Instance.new("Part")
	post.Name = "Post"
	post.Size = Vector3.new(0.18, POST_HEIGHT + look.h, 0.18)
	post.CFrame = CFrame.new(0, post.Size.Y * 0.5, 0.12)
	post.Color = Color3.fromRGB(150, 152, 156)
	post.Material = Enum.Material.Metal
	post.Parent = model
	local plate = Instance.new("Part")
	plate.Name = "Plate"
	plate.Size = Vector3.new(look.w, look.h, 0.08)
	plate.CFrame = CFrame.new(0, POST_HEIGHT + look.h * 0.5, 0)
	plate.Color = look.bg
	plate.Material = Enum.Material.SmoothPlastic
	plate.Parent = model
	for _, p in { post, plate } do
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
	end
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Art"
	gui.Face = Enum.NormalId.Front
	gui.PixelsPerStud = 60
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.LightInfluence = 1
	gui.Enabled = false
	gui.Parent = plate
	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = look.bg
	bg.BorderSizePixel = 0
	bg.Parent = gui
	if look.round then corner(bg, 0.5) end
	if look.ring then
		local stroke = Instance.new("UIStroke")
		stroke.Color = look.ring
		stroke.Thickness = 7
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = bg
	end
	local label = Instance.new("TextLabel")
	label.Name = "Value"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(0.9, 0.9)
	label.Position = UDim2.fromScale(0.05, 0.05)
	label.Text = look.text
	label.TextColor3 = look.fg
	label.TextScaled = true
	label.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	label.Parent = bg
	model.PrimaryPart = post
	model.WorldPivot = CFrame.new()
	return model
end

local function template(system: string, kind: string): Model
	local props = ReplicatedStorage:FindFirstChild("Props")
	local signs = props and props:FindFirstChild("TrafficSigns")
	local sys = signs and signs:FindFirstChild(SYSTEM_FOLDER[system] or "USA")
	local found = sys and sys:FindFirstChild(KIND_NAME[kind] or kind)
	if found and found:IsA("Model") then return found end
	return buildPlaceholder(system, kind)
end

local _templates: { [string]: Model } = {}
local function takeModel(kind: string): Model
	local pool = _pool[kind]
	if pool and #pool > 0 then return table.remove(pool) :: Model end
	local system = signSystem()
	local t = _templates[kind]
	if not t then
		t = template(system, kind)
		_templates[kind] = t
	end
	return t:Clone()
end

local function giveBack(kind: string, model: Model)
	model.Parent = nil
	local pool = _pool[kind]
	if not pool then
		pool = {}
		_pool[kind] = pool
	end
	table.insert(pool, model)
end

local function setText(model: Model, sign: TrafficSignPlanner.Sign, on: boolean)
	for _, d in model:GetDescendants() do
		if d:IsA("SurfaceGui") then
			d.Enabled = on
		elseif on and d:IsA("TextLabel") then
			if sign.kind == "speed" and d.Name == "Value" and sign.text then
				local us = signSystem() ~= "vienna"
				d.Text = if us then "SPEED\nLIMIT\n" .. sign.text else sign.text
			elseif sign.kind == "oneway" and (d.Name == "Value" or d.Name == "Arrow") then
				local us = signSystem() ~= "vienna"
				local arrow = if sign.arrowRight then "\u{2192}" else "\u{2190}"
				d.Text = if us then (if sign.arrowRight then "ONE WAY " .. arrow else arrow .. " ONE WAY") else arrow
			end
		end
	end
end

-- == Poles and the plan ========================================================
local function refreshPoles()
	table.clear(_poles)
	table.clear(_poleTops)
	table.clear(_signalNodes)
	local city = Workspace:FindFirstChild("_City")
	local lights = city and city:FindFirstChild("TrafficLights")
	if not lights then return end
	for _, m in lights:GetChildren() do
		if m:IsA("Model") then
			local cf, size = m:GetBoundingBox()
			table.insert(_poles, m:GetPivot().Position)
			table.insert(_poleTops, cf.Position.Y + size.Y * 0.5)
			-- TrafficLightPlacer names each pole TrafficLight_<nodeId>_<arm>.
			local nodeId = tonumber(string.match(m.Name, "^TrafficLight_(%d+)_"))
			if nodeId then _signalNodes[nodeId] = true end
		end
	end
end

local function nearestPole(pos: Vector3, within: number): number?
	local best: number? = nil
	local bestSq = within * within
	for i, p in _poles do
		local dx, dz = p.X - pos.X, p.Z - pos.Z
		local d2 = dx * dx + dz * dz
		if d2 < bestSq then
			bestSq = d2
			best = i
		end
	end
	return best
end

local function releaseAll()
	for key, a in _active do
		giveBack(a.kind, a.model)
		_active[key] = nil
	end
end

local function replan()
	refreshPoles()
	local nodePos = function(id: number): Vector3? return DataCache.GetNodeById(id) end
	local opts = TrafficSignPlanner.defaultOptions(function(nodeId: number): boolean
		return _signalNodes[nodeId] == true
	end)
	local ok, result = pcall(TrafficSignPlanner.plan, DataCache.GetSegments() :: any, nodePos, opts)
	if not ok then
		warn("[TrafficSignView] planning failed: " .. tostring(result))
		return
	end
	_signs = result :: { TrafficSignPlanner.Sign }
	table.clear(_grid)
	for _, s in _signs do
		local k = cellKey(s.pos.X, s.pos.Z)
		local bucket = _grid[k]
		if not bucket then
			bucket = {}
			_grid[k] = bucket
		end
		table.insert(bucket, s)
	end
	-- Signs keyed the same may have moved or changed: redraw from scratch.
	releaseAll()
	_nextSweep = 0
end

local function scheduleReplan()
	_replanAt = os.clock() + REPLAN_DELAY
end

-- == Placement =================================================================
local function place(model: Model, sign: TrafficSignPlanner.Sign)
	local pos = sign.pos
	local pole = nearestPole(pos, POLE_SNAP)
	local post = model:FindFirstChild("Post")
	if pole then
		-- Up on the signal pole, above the heads; the sign's own post is not drawn.
		local base = _poles[pole]
		local plateBottom = _poleTops[pole] + 0.3
		pos = Vector3.new(base.X, plateBottom - POST_HEIGHT, base.Z)
		if post and post:IsA("BasePart") then post.LocalTransparencyModifier = 1 end
	elseif post and post:IsA("BasePart") then
		post.LocalTransparencyModifier = 0
	end
	local face = Vector3.new(sign.face.X, 0, sign.face.Z)
	if face.Magnitude < 1e-3 then face = Vector3.zAxis end
	model:PivotTo(CFrame.lookAt(pos, pos + face.Unit))
end

local function focusPoint(camera: Camera): Vector3
	local cf = camera.CFrame
	local look = cf.LookVector
	if look.Y < -0.05 then
		local hit = cf.Position + look * ((RoadConstants.getGroundY() - cf.Position.Y) / look.Y)
		return hit
	end
	return cf.Position
end

local function sweep()
	local camera = Workspace.CurrentCamera
	local folder = _folder
	if not camera or not folder then return end
	local detail = RenderPressure.detail()
	local radius = (DRAW_DIST_BY_PRESET[_preset] or DRAW_DIST) * detail
	local textDist = TEXT_DIST * detail
	local centre = focusPoint(camera)
	local camPos = camera.CFrame.Position
	local wanted: { [string]: TrafficSignPlanner.Sign } = {}
	local count = 0
	local r2 = radius * radius
	local cx0, cx1 = math.floor((centre.X - radius) / CELL), math.floor((centre.X + radius) / CELL)
	local cz0, cz1 = math.floor((centre.Z - radius) / CELL), math.floor((centre.Z + radius) / CELL)
	for cx = cx0, cx1 do
		for cz = cz0, cz1 do
			for _, s in _grid[`{cx},{cz}`] or {} do
				local dx, dz = s.pos.X - centre.X, s.pos.Z - centre.Z
				if dx * dx + dz * dz < r2 and count < MAX_ACTIVE then
					wanted[s.key] = s
					count += 1
				end
			end
		end
	end
	for key, a in _active do
		if not wanted[key] then
			giveBack(a.kind, a.model)
			_active[key] = nil
		end
	end
	for key, s in wanted do
		local a = _active[key]
		if not a then
			local model = takeModel(s.kind)
			place(model, s)
			model.Parent = folder
			a = { model = model, kind = s.kind, textOn = false }
			_active[key] = a
		end
		local near = (s.pos - camPos).Magnitude < textDist
		if near ~= a.textOn then
			a.textOn = near
			setText(a.model, s, near)
		end
	end
end

local function step()
	local now = os.clock()
	if _replanAt and now >= _replanAt then
		_replanAt = nil
		replan()
	end
	if now >= _nextSweep then
		_nextSweep = now + SWEEP_EVERY
		sweep()
	end
end

function TrafficSignView.Start()
	if _started then return end
	_started = true
	local folder = Instance.new("Folder")
	folder.Name = "TrafficSigns"
	folder.Parent = Workspace
	_folder = folder
	_preset = tostring(Settings.get("graphicsPreset"))
	Settings.onChanged("graphicsPreset", function(v)
		if _started then _preset = tostring(v) end
	end)
	DataCache.On("segments", function() if _started then scheduleReplan() end end)
	DataCache.On("nodes", function() if _started then scheduleReplan() end end)
	-- A light going up or coming down changes which junctions carry stop signs.
	task.spawn(function()
		local city = Workspace:WaitForChild("_City", 60)
		local lights = city and city:WaitForChild("TrafficLights", 60)
		if not lights or not _started then return end
		table.insert(_conns, lights.ChildAdded:Connect(scheduleReplan))
		table.insert(_conns, lights.ChildRemoved:Connect(scheduleReplan))
		scheduleReplan()
	end)
	table.insert(_conns, RunService.Heartbeat:Connect(step))
	scheduleReplan()
end

function TrafficSignView.Stop()
	_started = false
	for _, c in _conns do c:Disconnect() end
	table.clear(_conns)
	releaseAll()
	if _folder then _folder:Destroy() end
	_folder = nil
end

return TrafficSignView
