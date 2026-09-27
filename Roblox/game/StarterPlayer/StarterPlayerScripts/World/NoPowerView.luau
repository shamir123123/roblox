--!strict
-- NoPowerView
-- The badge over anything the utilities have let down. The sim stamps an attribute each
-- pass and this is the only thing that reads it -- so the icon can never disagree with the
-- sim, and the server sends no extra traffic for it.
--
-- Five states, ONE badge slot, most important first:
--   Abandoned -- a derelict from an older save, rebuilt once power returns (cross)
--   NoPower   -- the building (or a pump) is off the grid (bolt)
--   Stranded  -- a pole or a pipe end wired to nothing at all (warning)
--   NoWater   -- the building went without water this pass (droplet)
--   NoSewage  -- its drain is backed up this pass (toilet)
-- A dark house is not also told it is thirsty: one badge, the worst news on it.
--
-- All of them PULSE -- a badge that just sits there is furniture, and a player scanning a
-- city block reads movement long before they read an icon.
--
-- Construction sites carry the same attributes (BuildingService stamps a marker per site),
-- so a street that is off the grid says so while it is still going up.
--
-- Zoomed out, badges of the same kind that crowd together on screen fold into ONE bigger
-- badge with a count, like Cities: Skylines II's notification icons: a dark suburb reads as
-- "bolt x40", not forty bolts piled on top of each other. Zoom in and they split again.
--
-- Purely cosmetic. Families leaving a home that goes without is CitizenService's call,
-- off the same flags, not anything here.

local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local uiFolder = script.Parent.Parent:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))

local NoPowerView = {}

local MAX_DISTANCE = 900 -- past this the badge is a pixel; not worth drawing
local BADGE = 26
-- The breath. A looping reversing tween, not a per-frame loop: a city block of dark houses
-- is a badge each, and the engine can grow them all without a line of Lua per frame. The
-- tween is owned by the BillboardGui, so destroying the badge ends it -- nothing to track.
local PULSE_MIN, PULSE_MAX = 0.80, 1.20
local PULSE_INFO = TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)

local ABANDONED_COLOR = Color3.fromRGB(58, 54, 50)

-- Clustering (see the header). Screen-space, so it follows the zoom by itself: the same two
-- houses are one badge from high up and two from street level.
local CLUSTER_PX = 40            -- badges of one kind closer than this on screen merge
local CLUSTER_MIN_DIST = 150     -- studs from the camera; nearer than this every badge stands alone
local CLUSTER_MAX_DISTANCE = 2400 -- a cluster still shows this far out (a lone badge stops at MAX_DISTANCE)
local CLUSTER_EVERY = 0.25       -- seconds between re-clusterings
local CLUSTER_BADGE = 34

-- The attributes, in the order they beat each other, with the badge each one draws.
local STATES = {
	{ attr = "Abandoned", color = ABANDONED_COLOR,                glyph = "\u{2715}" },
	{ attr = "NoPower",   color = nil,                            glyph = "\u{26A1}" }, -- Theme.Color.Danger
	{ attr = "Stranded",  color = Color3.fromRGB(238, 170, 58),   glyph = "\u{26A0}" },
	{ attr = "NoWater",   color = Color3.fromRGB(56, 170, 235),   glyph = "\u{1F4A7}" },
	{ attr = "NoSewage",  color = Color3.fromRGB(150, 110, 60),   glyph = "\u{1F6BD}" },
}

-- Folder names under Workspace._City whose models carry these attributes. Matched by name
-- anywhere in the tree, because every one of them is destroyed and rebuilt on a city load.
local WATCH_NAMES: { [string]: boolean } = {
	ZonedBuildings = true, -- houses and workplaces: NoPower / NoWater / Abandoned
	PowerLines = true,     -- poles wired to no generator
	EmergencyServices = true, -- pumps and treatment plants the grid did not reach
	PipeEnds = true,       -- mains that stop in the middle of nowhere
	ConstructionSites = true, -- buildings still going up: NoPower / NoWater / NoSewage
}

local _started = false
local _conns: { [Model]: { RBXScriptConnection } } = {}
local _badges: { [Model]: BillboardGui } = {}
local _folderConns: { RBXScriptConnection } = {}
local _watched: { [Instance]: boolean } = {}

local function stateDef(state: string): any
	for _, s in STATES do
		if s.attr == state then return s end
	end
	return nil
end

local function topOf(model: Model): number
	local ok, _, size = pcall(function()
		local cf, s = model:GetBoundingBox()
		return cf, s
	end)
	return if ok and size then size.Y * 0.5 + 3 else 12
end

local function hide(model: Model)
	local b = _badges[model]
	if b then b:Destroy(); _badges[model] = nil end
end

local function show(model: Model, state: string)
	local def = stateDef(state)
	if not def then return end
	local existing = _badges[model]
	if existing then
		if existing:GetAttribute("State") == state then return end
		hide(model) -- the state flipped: redraw rather than patch two children
	end
	local anchor = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if not anchor then return end

	local gui = Instance.new("BillboardGui")
	gui.Name = "NoPowerBadge"
	gui.Adornee = anchor
	gui.AlwaysOnTop = true
	gui.Size = UDim2.fromOffset(BADGE * PULSE_MIN, BADGE * PULSE_MIN)
	gui.StudsOffsetWorldSpace = Vector3.new(0, topOf(model), 0)
	gui.MaxDistance = MAX_DISTANCE
	gui.ResetOnSpawn = false
	gui:SetAttribute("State", state)

	local disc = Instance.new("Frame")
	disc.Size = UDim2.fromScale(1, 1)
	disc.BackgroundColor3 = def.color or Theme.Color.Danger
	disc.BorderSizePixel = 0
	disc.Parent = gui
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(1, 0)
	round.Parent = disc
	local edge = Instance.new("UIStroke")
	edge.Color = Color3.fromRGB(24, 24, 26)
	edge.Thickness = 1.5
	edge.Transparency = 0.25
	edge.Parent = disc

	local glyph = Instance.new("TextLabel")
	glyph.BackgroundTransparency = 1
	glyph.Size = UDim2.fromScale(1, 1)
	glyph.Text = def.glyph
	glyph.TextColor3 = Color3.fromRGB(255, 250, 240)
	glyph.TextScaled = true
	glyph.FontFace = Theme.Font.Bold
	glyph.Parent = disc

	gui.Parent = model
	_badges[model] = gui
	TweenService:Create(gui, PULSE_INFO, {
		Size = UDim2.fromOffset(BADGE * PULSE_MAX, BADGE * PULSE_MAX),
	}):Play()
end

-- First state that is set wins: once the family has gone, "no power" is no longer the news,
-- and a house with no electricity has bigger problems than the tap.
local function refresh(model: Model)
	for _, s in STATES do
		if model:GetAttribute(s.attr) == true then
			show(model, s.attr)
			return
		end
	end
	hide(model)
end

-- ---- clustering ------------------------------------------------------------------------
type ClusterSlot = { part: Part, gui: BillboardGui, disc: Frame, glyph: TextLabel, count: TextLabel }
local _clusterFolder: Folder? = nil
local _clusterPool: { ClusterSlot } = {}
local _clusterConn: RBXScriptConnection? = nil
local _hidden: { [BillboardGui]: boolean } = {} -- badges folded into a cluster right now

local function clusterFolder(): Folder
	local f = _clusterFolder
	if f and f.Parent then return f end
	local made = Instance.new("Folder")
	made.Name = "UtilityBadgeClusters"
	made.Parent = Workspace.CurrentCamera or Workspace
	_clusterFolder = made
	table.clear(_clusterPool)
	return made
end

local function clusterSlot(i: number): ClusterSlot
	local slot = _clusterPool[i]
	if slot and slot.part.Parent then return slot end
	-- An invisible anchor per cluster, local to this client (it lives under the camera).
	local part = Instance.new("Part")
	part.Name = "ClusterAnchor"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.Parent = clusterFolder()

	local gui = Instance.new("BillboardGui")
	gui.Name = "UtilityCluster"
	gui.Adornee = part
	gui.AlwaysOnTop = true
	gui.Size = UDim2.fromOffset(CLUSTER_BADGE, CLUSTER_BADGE)
	gui.MaxDistance = CLUSTER_MAX_DISTANCE
	gui.ResetOnSpawn = false
	gui.Enabled = false

	local disc = Instance.new("Frame")
	disc.Size = UDim2.fromScale(1, 1)
	disc.BorderSizePixel = 0
	disc.Parent = gui
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(1, 0)
	round.Parent = disc
	local edge = Instance.new("UIStroke")
	edge.Color = Color3.fromRGB(24, 24, 26)
	edge.Thickness = 2
	edge.Transparency = 0.15
	edge.Parent = disc

	local glyph = Instance.new("TextLabel")
	glyph.BackgroundTransparency = 1
	glyph.Size = UDim2.fromScale(0.8, 0.8)
	glyph.Position = UDim2.fromScale(0.1, 0.1)
	glyph.TextColor3 = Color3.fromRGB(255, 250, 240)
	glyph.TextScaled = true
	glyph.FontFace = Theme.Font.Bold
	glyph.Parent = disc

	-- The count, on a dark pill at the badge's lower right.
	local count = Instance.new("TextLabel")
	count.AnchorPoint = Vector2.new(0.5, 0.5)
	count.Position = UDim2.fromScale(0.92, 0.9)
	count.Size = UDim2.fromOffset(24, 15)
	count.BackgroundColor3 = Color3.fromRGB(24, 24, 26)
	count.BackgroundTransparency = 0.05
	count.BorderSizePixel = 0
	count.TextColor3 = Color3.fromRGB(255, 250, 240)
	count.TextScaled = true
	count.FontFace = Theme.Font.Bold
	count.Parent = disc
	local pill = Instance.new("UICorner")
	pill.CornerRadius = UDim.new(1, 0)
	pill.Parent = count

	gui.Parent = part
	local made: ClusterSlot = { part = part, gui = gui, disc = disc, glyph = glyph, count = count }
	_clusterPool[i] = made
	return made
end

local function reveal(gui: BillboardGui)
	if _hidden[gui] then
		_hidden[gui] = nil
		if gui.Parent then gui.Enabled = true end
	end
end

type Item = { gui: BillboardGui, pos: Vector3, x: number, y: number }

local function recluster()
	local cam = Workspace.CurrentCamera
	if not cam then return end
	local camPos = cam.CFrame.Position
	-- Candidates per badge kind; everything else stands alone.
	local byState: { [string]: { Item } } = {}
	for _, gui in _badges do
		local anchor = gui.Adornee
		local state = gui:GetAttribute("State")
		if not (anchor and anchor:IsA("BasePart") and anchor.Parent and typeof(state) == "string") then
			reveal(gui)
			continue
		end
		local pos = (anchor :: BasePart).Position + gui.StudsOffsetWorldSpace
		local dist = (pos - camPos).Magnitude
		local sp, onScreen = cam:WorldToViewportPoint(pos)
		if not onScreen or dist < CLUSTER_MIN_DIST or dist > CLUSTER_MAX_DISTANCE then
			reveal(gui)
			continue
		end
		local list = byState[state]
		if not list then
			list = {}
			byState[state] = list
		end
		table.insert(list, { gui = gui, pos = pos, x = sp.X, y = sp.Y })
	end

	local used = 0
	local stillHidden: { [BillboardGui]: boolean } = {}
	for _, def in STATES do
		local list = byState[def.attr]
		if not list then continue end
		-- Greedy: the next unclaimed badge gathers every unclaimed one within CLUSTER_PX of
		-- it. A screen-space hash keeps that local. Sorted so the result is stable frame to
		-- frame while the camera holds still.
		table.sort(list, function(a, b) return a.x < b.x or (a.x == b.x and a.y < b.y) end)
		local grid: { [number]: { number } } = {}
		for i, it in list do
			local k = math.floor(it.x / CLUSTER_PX) * 100003 + math.floor(it.y / CLUSTER_PX)
			local cell = grid[k]
			if not cell then
				cell = {}
				grid[k] = cell
			end
			table.insert(cell, i)
		end
		local taken: { [number]: boolean } = {}
		for i, seed in list do
			if taken[i] then continue end
			taken[i] = true
			local members = { seed }
			local cx, cy = math.floor(seed.x / CLUSTER_PX), math.floor(seed.y / CLUSTER_PX)
			for gx = cx - 1, cx + 1 do
				for gy = cy - 1, cy + 1 do
					for _, j in (grid[gx * 100003 + gy] or {}) do
						if not taken[j] then
							local o = list[j]
							local dx, dy = o.x - seed.x, o.y - seed.y
							if dx * dx + dy * dy <= CLUSTER_PX * CLUSTER_PX then
								taken[j] = true
								table.insert(members, o)
							end
						end
					end
				end
			end
			if #members < 2 then
				reveal(seed.gui)
				continue
			end
			local sum = Vector3.zero
			for _, m in members do
				sum += m.pos
				stillHidden[m.gui] = true
				_hidden[m.gui] = true
				m.gui.Enabled = false
			end
			used += 1
			local slot = clusterSlot(used)
			slot.part.CFrame = CFrame.new(sum / #members)
			slot.disc.BackgroundColor3 = def.color or Theme.Color.Danger
			slot.glyph.Text = def.glyph
			slot.count.Text = if #members > 99 then "99+" else tostring(#members)
			slot.gui.Enabled = true
		end
	end
	-- Badges that were folded last pass but are not now come back on their own.
	for gui in _hidden do
		if not stillHidden[gui] then reveal(gui) end
	end
	for i = used + 1, #_clusterPool do
		_clusterPool[i].gui.Enabled = false
	end
end

local function startClustering()
	if _clusterConn then return end
	local acc = 0
	_clusterConn = RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < CLUSTER_EVERY then return end
		acc = 0
		recluster()
	end)
end

local function stopClustering()
	if _clusterConn then
		_clusterConn:Disconnect()
		_clusterConn = nil
	end
	for gui in _hidden do
		if gui.Parent then gui.Enabled = true end
	end
	table.clear(_hidden)
	if _clusterFolder then _clusterFolder:Destroy() end
	_clusterFolder = nil
	table.clear(_clusterPool)
end

local function untrack(model: Model)
	local conns = _conns[model]
	if conns then
		for _, c in conns do c:Disconnect() end
		_conns[model] = nil
	end
	hide(model)
end

local function track(model: Instance)
	if not model:IsA("Model") or _conns[model] then return end
	local conns: { RBXScriptConnection } = {}
	for _, s in STATES do
		conns[#conns + 1] = model:GetAttributeChangedSignal(s.attr):Connect(function()
			refresh(model :: Model)
		end)
	end
	_conns[model] = conns
	refresh(model :: Model)
end

local function watchFolder(folder: Instance)
	if _watched[folder] then return end
	_watched[folder] = true
	for _, m in folder:GetChildren() do track(m) end
	table.insert(_folderConns, folder.ChildAdded:Connect(track))
	table.insert(_folderConns, folder.ChildRemoved:Connect(function(m)
		if m:IsA("Model") then untrack(m) end
	end))
	table.insert(_folderConns, folder.AncestryChanged:Connect(function()
		if not folder:IsDescendantOf(Workspace) then _watched[folder] = nil end
	end))
end

function NoPowerView.Start()
	if _started then return end
	_started = true
	startClustering()

	-- These folders only exist once a city is loaded, and they are destroyed and rebuilt on
	-- every load, so this matches by NAME anywhere under _City and re-attaches rather than
	-- binding once. PipeEnds sits a level deeper than the rest, which is why it is a
	-- descendant walk and not a child walk.
	local function consider(inst: Instance)
		if inst:IsA("Folder") and WATCH_NAMES[inst.Name] then watchFolder(inst) end
	end
	local function attach(city: Instance)
		for _, d in city:GetDescendants() do consider(d) end
		table.insert(_folderConns, city.DescendantAdded:Connect(consider))
	end
	local city = Workspace:FindFirstChild("_City")
	if city then attach(city) end
	Workspace.ChildAdded:Connect(function(c)
		if c.Name == "_City" then attach(c) end
	end)
end

function NoPowerView.Stop()
	stopClustering()
	for _, c in _folderConns do c:Disconnect() end
	table.clear(_folderConns)
	table.clear(_watched)
	for model in _conns do untrack(model) end
	_started = false
end

return NoPowerView
