--!strict
-- DeveloperController
-- The Developer panel (F6) -- the deeper sibling of the F4 admin panel, for admins
-- only. Four tabs:
--   Health   pass/warn/fail checks straight off DeveloperService -- "is the game
--            broken, and what is the single worst thing right now".
--   Perf     client + server frame time, a live FPS graph, memory broken down by
--            category (what is eating power), and an on-demand scene part-count scan.
--   Traffic  live driver census + a why-stopped histogram + parking / nav health.
--   Overlays toggles for the 3D world visualisers, drawn client-local so only this
--            developer sees them:
--              - Car / Pedestrian hitboxes (bounding boxes, cars tinted by live state)
--              - Stop lines  : where cars SHOULD stop, coloured by right-of-way
--              - Lane network: where cars CAN go, coloured by live congestion
--              - Parking     : every spot, green = free, red = taken (+ lot pads)
--              - Dead-ends   : lanes with no legal exit (a broken-road-graph marker)
--
-- Everything here is a UI hint / view. Authority is the server's: every feed re-checks
-- admin tier server-side, and the overlays only read replicated state.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local UserInputService  = game:GetService("UserInputService")
local Workspace         = game:GetService("Workspace")
local LogService        = game:GetService("LogService")
local Stats             = game:GetService("Stats") :: any

-- Resolved by NAME, not by position -- see the same note in AdminController: this bundle
-- is delivered into PlayerGui at runtime, so script.Parent.Parent is not PlayerScripts.
local PlayerScripts = Players.LocalPlayer:WaitForChild("PlayerScripts")
local UI     = PlayerScripts:WaitForChild("UI")
local Kit    = UI:WaitForChild("Kit")
local Theme  = require(UI:WaitForChild("Theme"))
local Glass  = require(Kit:WaitForChild("Glass"))
local Tab    = require(Kit:WaitForChild("Tab"))
local Button = require(Kit:WaitForChild("Button"))

local Net = require(ReplicatedStorage:WaitForChild("Networker"))
local Settings = require(PlayerScripts:WaitForChild("Core"):WaitForChild("Settings"))
local LocalPlayer = Players.LocalPlayer

local DeveloperController = {}

local PANEL_GUI_NAME  = "StaffPanel"
local REPORT_POLL     = 1.2     -- server report cadence
local SPEED_POLL  = 0.5     -- hitbox-colour cadence
local PERF_TICK   = 0.25    -- local perf-label cadence
local GEO_REFRESH = 1.6     -- geometry auto-refresh (congestion / occupancy move)
local GEO_MOVE    = 60      -- camera move (studs) that forces a geometry refresh
local NEAR_RADIUS = 750
local FPS_SAMPLES   = 48
local CHART_SAMPLES = 48
local CHART_TICK    = 0.5
local REMOTE_WINDOW = 1.0
local TOP_REMOTE_ROWS = 8
local NET_SPIKE_KB_SEC = 64
local LOG_WINDOW    = 60
local GROWTH_TICK   = 5.0
local LIFT        = 0.5
local MAX_PARTS   = 16000
local CAR_TAG     = "NPCDriver"
local PED_TAG     = "NPCWalker"
local PANEL_MARGIN = 10
local PANEL_MAX_W  = 680
local PANEL_H      = 600

local WARN_C  = Color3.fromRGB(240, 200, 90)
local NEUTRAL = Color3.fromRGB(120, 200, 255)
local STATUS_COLOR: { [string]: Color3 } = {
	ok   = Theme.Color.Accent,
	warn = WARN_C,
	fail = Theme.Color.Danger,
}
local STOP_STATE_COLOR: { [string]: Color3 } = {
	go       = Color3.fromRGB(90, 230, 120),
	stop     = Color3.fromRGB(235, 70, 70),
	yield    = Color3.fromRGB(245, 180, 70),
	priority = Color3.fromRGB(95, 165, 255),
}
local REASON_COLOR: { [string]: Color3 } = {
	cruise   = Color3.fromRGB(110, 225, 130),
	slow     = Color3.fromRGB(240, 205, 90),
	follow   = Color3.fromRGB(240, 205, 90),
	carAhead = Color3.fromRGB(240, 205, 90),
	turn     = Color3.fromRGB(255, 150, 60),
	yield    = Color3.fromRGB(245, 175, 60),
	standoff = Color3.fromRGB(235, 90, 70),
	blocked  = Color3.fromRGB(235, 90, 70),
	stopped  = Color3.fromRGB(235, 70, 70),
	redLight = Color3.fromRGB(235, 70, 70),
}
local C_GREEN = Color3.fromRGB(90, 215, 110)
local C_AMBER = Color3.fromRGB(240, 200, 80)
local C_RED   = Color3.fromRGB(235, 75, 70)
local PARK_FREE = Color3.fromRGB(95, 220, 120)
local PARK_TAKEN = Color3.fromRGB(235, 80, 75)
local PAD_HOME = Color3.fromRGB(95, 165, 255)
local PAD_STALL = Color3.fromRGB(95, 210, 230)
local DEADEND_C = Color3.fromRGB(255, 60, 60)

local GEO_LAYERS = { "stopLines", "lanes", "parking", "deadEnds", "jams" }

local REMOTE_SOURCE: { [string]: string } = {
	SyncNodes = "RoadReplicationService",
	SyncSegments = "RoadReplicationService",
	SyncIntersections = "RoadReplicationService",
	SyncIntersectionTurnSettings = "RoadReplicationService",
	SyncIntersectionLanePaths = "RoadReplicationService",
	SyncLaneChangeGates = "RoadReplicationService",
	SyncNodesDelta = "RoadReplicationService",
	SyncSegmentsDelta = "RoadReplicationService",
	PlaceRoadResult = "RoadReplicationService",
	SyncPlots = "PlotService",
	SyncConstructionSites = "BuildingService",
	SyncCityStats = "CityStatsService",
	SyncEconomy = "CityEconomyService",
	SyncTime = "TimeService",
	TerrainBuildData = "TerrainDataService",
	CityLoadResult = "CitySlotService",
	DebugSnapshot = "DebugService",
	SyncTransit = "TransitService",
	Notify = "City event services",
	Bankruptcy = "CityEconomyService",
}

-- ---------------------------------------------------------------- state --

local _tier = "admin"
local _started, _built, _visible = false, false, false
local _conns: { RBXScriptConnection } = {}
local _gui: ScreenGui? = nil
local _root: Frame? = nil
local _activeTab = "Health"
local _pages: { [string]: GuiObject } = {}
local _tabs: { [string]: any } = {}
local _v: { [string]: TextLabel } = {}

local _report: any = nil
local _reportBusy = false
local _pollAccum = 0
local _speedAccum = 0
local _perfAccum = 0
local _geoAccum = 0
local _chartAccum = 0
local _remoteAccum = 0
local _growthAccum = 0

local _frameAccum, _frameCount, _fps = 0, 0, 0
local _fpsSamples: { number } = {}
local _chartSamples: { [string]: { number } } = { fps = {}, hb = {}, recv = {}, send = {}, mem = {} }
local _chartBars: { [string]: { Frame } } = {}
local _chartMax: { [string]: number } = { fps = 60, hb = 33, recv = 256, send = 256, mem = 2400 }

local _healthHolder: ScrollingFrame? = nil
local _healthBanner: TextLabel? = nil
local _reasonHolder: Frame? = nil
local _fpsBars: { Frame } = {}
local _remoteHotHolder: Frame? = nil
local _hintHolder: Frame? = nil
local _profileHolder: Frame? = nil
local _timelineHolder: Frame? = nil
local _snapshotHolder: Frame? = nil

local _overlayFolder: Folder? = nil
local _geoFolder: Folder? = nil
local _geoBusy = false
local _geoDirty = false
local _geoParts = 0
local _lastGeoCam: Vector3? = nil
local _nearOnly = true
local _nearBtn: any = nil

local _layers: { [string]: boolean } = { hitboxes = false, peds = false, stopLines = false, lanes = false, parking = false, deadEnds = false, jams = false }
local _layerBtns: { [string]: any } = {}

local _carBoxes: { [Model]: SelectionBox } = {}
local _pedBoxes: { [Model]: SelectionBox } = {}
local _carTagConns: { RBXScriptConnection } = {}
local _pedTagConns: { RBXScriptConnection } = {}
local _speedBusy = false

local _remoteStatsHooked = false
local _remoteBytes = 0
local _remoteEvents = 0
local _remoteByName: { [string]: any } = {}
local _remoteRates: { [string]: any } = {}
local _lastSpike = "none yet"
local _clientErrorTimes: { number } = {}
local _clientWarnTimes: { number } = {}
local _timeline: { any } = {}
local _timelineCooldown: { [string]: number } = {}
local _snapshots: { string } = {}
local _lastSummaryKey = ""
local _growthStats: any = {}
local _lastGrowth: any = nil

local MEM_TAGS = {
	{ tag = Enum.DeveloperMemoryTag.Instances,         key = "m_inst", label = "Instances" },
	{ tag = Enum.DeveloperMemoryTag.PhysicsParts,      key = "m_phys", label = "Physics parts" },
	{ tag = Enum.DeveloperMemoryTag.GraphicsMeshParts, key = "m_mesh", label = "Mesh parts" },
	{ tag = Enum.DeveloperMemoryTag.GraphicsTexture,   key = "m_tex",  label = "Textures" },
	{ tag = Enum.DeveloperMemoryTag.TerrainVoxels,     key = "m_terr", label = "Terrain voxels" },
	{ tag = Enum.DeveloperMemoryTag.LuaHeap,           key = "m_lua",  label = "Lua heap" },
}

-- ----------------------------------------------------------- ui helpers --

local function setv(key: string, text: string)
	local l = _v[key]
	if l then l.Text = text end
end

local function setvc(key: string, text: string, color: Color3)
	local l = _v[key]
	if l then l.Text = text; l.TextColor3 = color end
end

local function congestionColor(c: number): Color3
	c = math.clamp(c, 0, 1)
	if c < 0.5 then return C_GREEN:Lerp(C_AMBER, c * 2) end
	return C_AMBER:Lerp(C_RED, (c - 0.5) * 2)
end

local function section(parent: Instance, text: string, order: number)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, 0, 0, 18)
	l.LayoutOrder = order
	l.FontFace = Theme.Font.Header
	l.TextSize = Theme.TextSize.XS
	l.TextColor3 = Theme.Color.TextSecondary
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Text = string.upper(text)
	l.Parent = parent
end

local function statRow(parent: Instance, label: string, key: string, order: number)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 18)
	row.LayoutOrder = order
	row.Parent = parent

	local name = Instance.new("TextLabel")
	name.BackgroundTransparency = 1
	name.Size = UDim2.new(0.55, 0, 1, 0)
	name.FontFace = Theme.Font.Label
	name.TextSize = Theme.TextSize.XS
	name.TextColor3 = Theme.Color.TextSecondary
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Text = label
	name.Parent = row

	local value = Instance.new("TextLabel")
	value.BackgroundTransparency = 1
	value.AnchorPoint = Vector2.new(1, 0)
	value.Position = UDim2.fromScale(1, 0)
	value.Size = UDim2.new(0.45, 0, 1, 0)
	value.FontFace = Theme.Font.Bold
	value.TextSize = Theme.TextSize.XS
	value.TextColor3 = Theme.Color.TextPrimary
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.TextTruncate = Enum.TextTruncate.AtEnd
	value.Text = "\u{2014}"
	value.Parent = row
	_v[key] = value
end

local function listScroller(parent: Instance): ScrollingFrame
	local sf = Instance.new("ScrollingFrame")
	sf.BackgroundTransparency = 1
	sf.BorderSizePixel = 0
	sf.Size = UDim2.fromScale(1, 1)
	sf.CanvasSize = UDim2.new()
	sf.AutomaticCanvasSize = Enum.AutomaticSize.Y
	sf.ScrollBarThickness = 4
	sf.ScrollBarImageColor3 = Theme.Color.Stroke
	sf.ScrollingDirection = Enum.ScrollingDirection.Y
	sf.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar
	sf.Parent = parent
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 4)
	list.Parent = sf
	return sf
end

local function remoteSource(name: string): string
	return REMOTE_SOURCE[name] or "source unknown"
end

local function sizeOf(v: any, depth: number): number
	local t = typeof(v)
	if t == "number" then return 8
	elseif t == "boolean" then return 1
	elseif t == "string" then return #v
	elseif t == "Vector3" then return 12
	elseif t == "Vector2" then return 8
	elseif t == "CFrame" then return 48
	elseif t == "Color3" then return 12
	elseif t == "Instance" then return 8
	elseif t == "table" then
		if depth > 4 then return 8 end
		local sum = 0
		local count = 0
		for k, vv in v do
			count += 1
			if count > 200 then break end
			sum += sizeOf(k, depth + 1) + sizeOf(vv, depth + 1)
		end
		return sum
	end
	return 4
end

local function estimateArgs(...): number
	local total = 0
	for i = 1, select("#", ...) do
		total += sizeOf(select(i, ...), 0)
	end
	return total
end

local function compactKb(kb: number): string
	if kb >= 1024 then return string.format("%.1f MB/s", kb / 1024) end
	if kb >= 10 then return string.format("%.0f KB/s", kb) end
	return string.format("%.1f KB/s", kb)
end

local function pruneTimes(times: { number })
	local cutoff = os.clock() - LOG_WINDOW
	while times[1] and times[1] < cutoff do
		table.remove(times, 1)
	end
end

local function chartDisplay(key: string, value: number): string
	if key == "fps" then return string.format("%.0f fps", value) end
	if key == "hb" then return string.format("%.1f ms", value) end
	if key == "mem" then return string.format("%.0f MB", value) end
	return string.format("%.0f kbps", value)
end

local function chartColor(key: string, value: number): Color3
	if key == "fps" then
		return if value >= 50 then Theme.Color.Accent elseif value >= 30 then WARN_C else Theme.Color.Danger
	elseif key == "hb" then
		return if value <= 16.7 then Theme.Color.Accent elseif value <= 28 then WARN_C else Theme.Color.Danger
	elseif key == "mem" then
		return if value < 1800 then Theme.Color.Accent elseif value < 2800 then WARN_C else Theme.Color.Danger
	end
	return if value < 600 then Theme.Color.Accent elseif value < 1200 then WARN_C else Theme.Color.Danger
end

local function makeMiniChart(parent: Instance, key: string, title: string, order: number, maxValue: number)
	_chartMax[key] = maxValue
	local card = Instance.new("Frame")
	card.Name = title:gsub("%W", "")
	card.BackgroundColor3 = Theme.Color.BgRaised
	card.BackgroundTransparency = 0.38
	card.BorderSizePixel = 0
	card.Size = UDim2.new(1, -4, 0, 78)
	card.LayoutOrder = order
	card.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Theme.Radius.SM)
	corner.Parent = card

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromOffset(8, 4)
	label.Size = UDim2.new(1, -128, 0, 18)
	label.FontFace = Theme.Font.Bold
	label.TextSize = Theme.TextSize.XS
	label.TextColor3 = Theme.Color.TextSecondary
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = title
	label.Parent = card

	local value = Instance.new("TextLabel")
	value.BackgroundTransparency = 1
	value.AnchorPoint = Vector2.new(1, 0)
	value.Position = UDim2.new(1, -8, 0, 4)
	value.Size = UDim2.fromOffset(112, 18)
	value.FontFace = Theme.Font.Bold
	value.TextSize = Theme.TextSize.XS
	value.TextColor3 = Theme.Color.TextPrimary
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.Text = "\u{2014}"
	value.Parent = card
	_v["chart_" .. key] = value

	local graph = Instance.new("Frame")
	graph.BackgroundTransparency = 1
	graph.Position = UDim2.fromOffset(8, 26)
	graph.Size = UDim2.new(1, -16, 0, 44)
	graph.Parent = card
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.HorizontalAlignment = Enum.HorizontalAlignment.Right
	list.VerticalAlignment = Enum.VerticalAlignment.Bottom
	list.Padding = UDim.new(0, 1)
	list.Parent = graph

	local bars: { Frame } = {}
	for i = 1, CHART_SAMPLES do
		local bar = Instance.new("Frame")
		bar.BorderSizePixel = 0
		bar.BackgroundColor3 = Theme.Color.StrokeSoft
		bar.Size = UDim2.new(1 / CHART_SAMPLES, -1, 0.02, 0)
		bar.LayoutOrder = i
		bar.Parent = graph
		bars[i] = bar
	end
	_chartBars[key] = bars
end

local function pushChartSample(key: string, value: number)
	local samples = _chartSamples[key]
	if not samples then return end
	table.insert(samples, value)
	if #samples > CHART_SAMPLES then table.remove(samples, 1) end
	local maxValue = _chartMax[key] or 1
	if value > maxValue then
		_chartMax[key] = math.max(value, maxValue * 1.25, 1)
	end
end

local function paintChart(key: string)
	local bars = _chartBars[key]
	local samples = _chartSamples[key]
	if not bars or not samples then return end
	local maxValue = math.max(_chartMax[key] or 1, 1)
	local n = #samples
	for i = 1, CHART_SAMPLES do
		local bar = bars[i]
		local sample = samples[n - CHART_SAMPLES + i]
		if sample then
			local frac = math.clamp(sample / maxValue, 0.02, 1)
			bar.Size = UDim2.new(1 / CHART_SAMPLES, -1, frac, 0)
			bar.BackgroundColor3 = chartColor(key, sample)
		else
			bar.Size = UDim2.new(1 / CHART_SAMPLES, -1, 0.02, 0)
			bar.BackgroundColor3 = Theme.Color.StrokeSoft
		end
	end
	setv("chart_" .. key, chartDisplay(key, samples[n] or 0))
end

local function remoteHotRow(parent: Instance, name: string, kb: number, ev: number, maxKb: number, order: number)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 34)
	row.LayoutOrder = order
	row.Parent = parent

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, -126, 0, 16)
	label.FontFace = Theme.Font.Bold
	label.TextSize = Theme.TextSize.XS
	label.TextColor3 = Theme.Color.TextPrimary
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Text = string.format("%s  \u{00B7}  %s", name, remoteSource(name))
	label.Parent = row

	local value = Instance.new("TextLabel")
	value.BackgroundTransparency = 1
	value.AnchorPoint = Vector2.new(1, 0)
	value.Position = UDim2.fromScale(1, 0)
	value.Size = UDim2.fromOffset(120, 16)
	value.FontFace = Theme.Font.Bold
	value.TextSize = Theme.TextSize.XS
	value.TextColor3 = chartColor("recv", kb * 8)
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.Text = string.format("%s  %.0f/s", compactKb(kb), ev)
	value.Parent = row

	local track = Instance.new("Frame")
	track.BackgroundColor3 = Theme.Color.Bg
	track.BackgroundTransparency = 0.35
	track.BorderSizePixel = 0
	track.Position = UDim2.new(0, 0, 0, 21)
	track.Size = UDim2.new(1, 0, 0, 7)
	track.Parent = row
	local tc = Instance.new("UICorner")
	tc.CornerRadius = UDim.new(1, 0)
	tc.Parent = track
	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = value.TextColor3
	fill.BorderSizePixel = 0
	fill.Size = UDim2.new(if maxKb > 0 then math.clamp(kb / maxKb, 0, 1) else 0, 0, 1, 0)
	fill.Parent = track
	local fc = Instance.new("UICorner")
	fc.CornerRadius = UDim.new(1, 0)
	fc.Parent = fill
end

local function updateRemoteHotList()
	local holder = _remoteHotHolder
	if not holder then return end
	for _, c in holder:GetChildren() do
		if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
	end
	local rows: { any } = {}
	local maxKb = 0
	for name, rate in _remoteRates do
		local kb = tonumber(rate.kb) or 0
		local ev = tonumber(rate.ev) or 0
		if kb > 0 or ev > 0 then
			table.insert(rows, { name = name, kb = kb, ev = ev })
			if kb > maxKb then maxKb = kb end
		end
	end
	table.sort(rows, function(a, b) return a.kb > b.kb end)
	if #rows == 0 then
		local empty = Instance.new("TextLabel")
		empty.BackgroundTransparency = 1
		empty.Size = UDim2.new(1, -4, 0, 18)
		empty.FontFace = Theme.Font.Label
		empty.TextSize = Theme.TextSize.XS
		empty.TextColor3 = Theme.Color.TextSecondary
		empty.TextXAlignment = Enum.TextXAlignment.Left
		empty.Text = "No inbound RemoteEvents in the last second."
		empty.Parent = holder
		return
	end
	for i = 1, math.min(TOP_REMOTE_ROWS, #rows) do
		local row = rows[i]
		remoteHotRow(holder, row.name, row.kb, row.ev, maxKb, i)
	end
end

local function hintLine(parent: Instance, text: string, color: Color3, order: number)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, -4, 0, 0)
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.LayoutOrder = order
	l.FontFace = Theme.Font.Label
	l.TextSize = Theme.TextSize.XS
	l.TextColor3 = color
	l.TextWrapped = true
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Top
	l.Text = text
	l.Parent = parent
end

local function renderTimeline()
	local holder = _timelineHolder
	if not holder then return end
	for _, c in holder:GetChildren() do
		if c:IsA("TextLabel") then c:Destroy() end
	end
	if #_timeline == 0 then
		hintLine(holder, "No events yet. Leave this open while building, saving, spawning traffic, or loading terrain.", Theme.Color.TextSecondary, 1)
		return
	end
	for i, entry in _timeline do
		hintLine(holder, string.format("%s  %s", tostring(entry.time or "--:--:--"), tostring(entry.text or "event")), entry.color or Theme.Color.TextSecondary, i)
	end
end

local function addTimeline(key: string, text: string, color: Color3, cooldown: number?)
	local now = os.clock()
	if cooldown and key ~= "" then
		local last = _timelineCooldown[key]
		if last and now - last < cooldown then return end
		_timelineCooldown[key] = now
	end
	table.insert(_timeline, 1, { time = os.date("%H:%M:%S"), text = text, color = color })
	while #_timeline > 40 do table.remove(_timeline) end
	renderTimeline()
end

local function renderSnapshots()
	local holder = _snapshotHolder
	if not holder then return end
	for _, c in holder:GetChildren() do
		if c:IsA("TextLabel") then c:Destroy() end
	end
	if #_snapshots == 0 then
		hintLine(holder, "No snapshots yet. Hit the button the moment the game hitches.", Theme.Color.TextSecondary, 1)
		return
	end
	for i, text in _snapshots do
		hintLine(holder, text, Theme.Color.TextSecondary, i)
	end
end

local function captureSnapshot()
	local perf = if type(_report) == "table" then (_report.perf or {}) else {}
	local save = if type(_report) == "table" then (_report.save or {}) else {}
	local bestName = "none"
	local bestKb = 0
	for name, rate in _remoteRates do
		local kb = tonumber(rate.kb) or 0
		if kb > bestKb then
			bestKb = kb
			bestName = name
		end
	end
	local topRemote = if bestName ~= "none" then string.format("%s %s", bestName, compactKb(bestKb)) else "none"
	local line = string.format("%s  FPS %d | server %.1fms | recv %.0fkbps | mem %.0fMB | overlays %d | remote %s | save %.0fms",
		os.date("%H:%M:%S"), _fps, tonumber(perf.heartbeatMs) or 0, tonumber(Stats.DataReceiveKbps) or 0,
		tonumber(perf.memoryMb) or 0, _geoParts, topRemote, tonumber(save.lastMs) or 0)
	table.insert(_snapshots, 1, line)
	while #_snapshots > 14 do table.remove(_snapshots) end
	addTimeline("snapshot_" .. tostring(os.clock()), "Lag snapshot captured", Theme.Color.Accent, nil)
	renderSnapshots()
end

local function handleReportTimeline(data: any)
	if type(data) ~= "table" then return end
	local s = data.summary or {}
	local fail = tonumber(s.fail) or 0
	local warn = tonumber(s.warn) or 0
	local key = string.format("%d/%d", fail, warn)
	if key ~= _lastSummaryKey then
		_lastSummaryKey = key
		local color = if fail > 0 then Theme.Color.Danger elseif warn > 0 then WARN_C else Theme.Color.Accent
		addTimeline("health", string.format("Health changed: %d failing, %d warning", fail, warn), color, 1)
	end
	local perf = data.perf or {}
	local hb = tonumber(perf.heartbeatMs) or 0
	if hb > 28 then addTimeline("server_hb", string.format("Server heartbeat spike %.1f ms", hb), Theme.Color.Danger, 8) end
	local traffic = data.traffic or {}
	if (tonumber(traffic.stuck) or 0) > 0 then addTimeline("stuck_cars", string.format("%d stuck vehicles", traffic.stuck or 0), Theme.Color.Danger, 8) end
	local save = data.save or {}
	if save.lastOk == false then addTimeline("save_fail", "City save failed: " .. tostring(save.lastError or "unknown error"), Theme.Color.Danger, 10) end
	local log = data.log or {}
	if (tonumber(log.errors) or 0) > 0 then addTimeline("server_errors", string.format("%d server errors in the last minute", log.errors or 0), Theme.Color.Danger, 10) end
end

local function profileRow(parent: Instance, name: string, ms: number, total: number, ok: boolean, order: number)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 22)
	row.LayoutOrder = order
	row.Parent = parent

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(0.58, 0, 0, 14)
	label.FontFace = Theme.Font.Label
	label.TextSize = Theme.TextSize.XS
	label.TextColor3 = if ok then Theme.Color.TextSecondary else Theme.Color.Danger
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Text = name
	label.Parent = row

	local value = Instance.new("TextLabel")
	value.BackgroundTransparency = 1
	value.AnchorPoint = Vector2.new(1, 0)
	value.Position = UDim2.fromScale(1, 0)
	value.Size = UDim2.new(0.32, 0, 0, 14)
	value.FontFace = Theme.Font.Bold
	value.TextSize = Theme.TextSize.XS
	value.TextColor3 = if ms < 2 then Theme.Color.Accent elseif ms < 8 then WARN_C else Theme.Color.Danger
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.Text = string.format("%.2f ms", ms)
	value.Parent = row

	local track = Instance.new("Frame")
	track.BackgroundColor3 = Theme.Color.Bg
	track.BackgroundTransparency = 0.4
	track.BorderSizePixel = 0
	track.Position = UDim2.new(0, 0, 0, 16)
	track.Size = UDim2.new(1, 0, 0, 5)
	track.Parent = row
	local tc = Instance.new("UICorner"); tc.CornerRadius = UDim.new(1, 0); tc.Parent = track
	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = value.TextColor3
	fill.BorderSizePixel = 0
	fill.Size = UDim2.new(if total > 0 then math.clamp(ms / total, 0.02, 1) else 0.02, 0, 1, 0)
	fill.Parent = track
	local fc = Instance.new("UICorner"); fc.CornerRadius = UDim.new(1, 0); fc.Parent = fill
end

local function updateHintList()
	local holder = _hintHolder
	if not holder then return end
	for _, c in holder:GetChildren() do
		if c:IsA("TextLabel") then c:Destroy() end
	end
	pruneTimes(_clientErrorTimes)
	pruneTimes(_clientWarnTimes)
	local perf = if type(_report) == "table" then (_report.perf or {}) else {}
	local log = if type(_report) == "table" then (_report.log or {}) else {}
	local order = 0
	local function add(text: string, color: Color3)
		order += 1
		hintLine(holder, text, color, order)
	end
	if _fps > 0 and _fps < 30 then add("Client FPS is below 30. Check visible parts, UI count, active overlays, and expensive RenderStepped work.", Theme.Color.Danger) end
	if (perf.heartbeatMs or 0) > 28 then add("Server heartbeat is high. Look at physics-heavy systems, NPC loops, and save/terrain bursts.", Theme.Color.Danger) end
	if (Stats.DataReceiveKbps or 0) > 1200 then add("Roblox receive bandwidth is very high. The hot remotes list shows the likely subsystem.", WARN_C) end
	if _lastSpike ~= "none yet" then add("Last network spike: " .. _lastSpike, WARN_C) end
	if #_clientErrorTimes > 0 then add(string.format("Client errors in last minute: %d. Open Output and fix these first.", #_clientErrorTimes), Theme.Color.Danger) end
	if (log.errors or 0) > 0 then add(string.format("Server errors in last minute: %d. Health tab should show the failing check.", log.errors), Theme.Color.Danger) end
	if _geoParts > 8000 then add("Developer overlays have thousands of parts. Disable overlays before judging normal gameplay performance.", WARN_C) end
	if order == 0 then add("No obvious spikes yet. Leave this tab open while building roads, zoning, loading terrain, or spawning traffic.", Theme.Color.Accent) end
end

local function sampleCharts()
	pushChartSample("fps", _fps)
	pushChartSample("recv", tonumber(Stats.DataReceiveKbps) or 0)
	pushChartSample("send", tonumber(Stats.DataSendKbps) or 0)
	local ok, mem = pcall(function() return Stats:GetTotalMemoryUsageMb() end)
	pushChartSample("mem", if ok and typeof(mem) == "number" then mem else 0)
	local perf = if type(_report) == "table" then _report.perf else nil
	local hb = if type(perf) == "table" then (tonumber(perf.heartbeatMs) or 0) else 0
	pushChartSample("hb", hb)
end

local function updateCharts()
	paintChart("fps")
	paintChart("hb")
	paintChart("recv")
	paintChart("send")
	paintChart("mem")
	setv("chart_spike", _lastSpike)
	setv("chart_clientlog", string.format("%d errors / %d warnings", #_clientErrorTimes, #_clientWarnTimes))
	updateRemoteHotList()
	updateHintList()
end

local function flushRemoteWindow(window: number)
	local safeWindow = math.max(window, 0.001)
	local totalKb = (_remoteBytes / safeWindow) / 1024
	local totalEv = _remoteEvents / safeWindow
	local bestName = ""
	local bestKb = 0
	table.clear(_remoteRates)
	for name, row in _remoteByName do
		local bytes = tonumber(row.bytes) or 0
		local count = tonumber(row.count) or 0
		local kb = (bytes / safeWindow) / 1024
		local ev = count / safeWindow
		_remoteRates[name] = { kb = kb, ev = ev }
		if kb > bestKb then
			bestKb = kb
			bestName = name
		end
	end
	if totalKb >= NET_SPIKE_KB_SEC and bestName ~= "" then
		_lastSpike = string.format("%s total, top %s at %s (%s)", compactKb(totalKb), bestName, compactKb(bestKb), remoteSource(bestName))
		addTimeline("net_spike", "Network spike: " .. _lastSpike, WARN_C, 5)
	elseif totalEv >= 80 and bestName ~= "" then
		_lastSpike = string.format("%.0f RemoteEvents/s, top %s (%s)", totalEv, bestName, remoteSource(bestName))
		addTimeline("remote_spam", "RemoteEvent burst: " .. _lastSpike, WARN_C, 5)
	end
	table.clear(_remoteByName)
	_remoteBytes = 0
	_remoteEvents = 0
end

local function hookDiagnostics()
	if _remoteStatsHooked then return end
	_remoteStatsHooked = true
	local function hookRemote(inst: Instance)
		if not inst:IsA("RemoteEvent") then return end
		local remote = inst :: RemoteEvent
		local name = remote.Name
		table.insert(_conns, remote.OnClientEvent:Connect(function(...)
			local bytes = estimateArgs(...)
			_remoteBytes += bytes
			_remoteEvents += 1
			local row = _remoteByName[name]
			if not row then
				row = { bytes = 0, count = 0 }
				_remoteByName[name] = row
			end
			row.bytes += bytes
			row.count += 1
		end))
	end
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if remotes then
		for _, inst in remotes:GetChildren() do hookRemote(inst) end
		table.insert(_conns, remotes.ChildAdded:Connect(hookRemote))
	end
	table.insert(_conns, LogService.MessageOut:Connect(function(_: string, messageType: Enum.MessageType)
		local now = os.clock()
		if messageType == Enum.MessageType.MessageError then
			table.insert(_clientErrorTimes, now)
			addTimeline("client_error", "Client error logged", Theme.Color.Danger, 3)
		elseif messageType == Enum.MessageType.MessageWarning then
			table.insert(_clientWarnTimes, now)
			addTimeline("client_warn", "Client warning logged", WARN_C, 5)
		end
	end))
end

-- ----------------------------------------------------------- overlays 3d --

local function ensureOverlayFolder(): Folder
	if _overlayFolder and _overlayFolder.Parent then return _overlayFolder end
	local f = Instance.new("Folder")
	f.Name = "_DevOverlays"
	f.Parent = Workspace
	_overlayFolder = f
	return f
end

local function drawBox(folder: Folder, cf: CFrame, size: Vector3, color: Color3): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = size
	p.CFrame = cf
	p.Parent = folder
	_geoParts += 1
	return p
end

local function drawLine(folder: Folder, a: Vector3, b: Vector3, color: Color3, thickness: number)
	local len = (b - a).Magnitude
	if len < 0.05 then return end
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = Vector3.new(thickness, thickness, len)
	p.CFrame = CFrame.lookAt(a:Lerp(b, 0.5), b)
	p.Parent = folder
	_geoParts += 1
end

local function drawPolyline(folder: Folder, pts: { Vector3 }, color: Color3, thickness: number)
	for i = 1, #pts - 1 do
		if _geoParts >= MAX_PARTS then return end
		drawLine(folder, pts[i] + Vector3.new(0, LIFT, 0), pts[i + 1] + Vector3.new(0, LIFT, 0), color, thickness)
	end
end

-- Why a car is standing still, printed over its jam pillar ("#8 queued behind #207 (stopped) · 12s").
local function drawLabel(pillar: BasePart, height: number, text: string)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(280, 18)
	gui.StudsOffset = Vector3.new(0, height * 0.5 + 1.5, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 700
	gui.LightInfluence = 0
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.25
	label.FontFace = Theme.Font.Label
	label.TextSize = 13
	label.Text = text
	label.Parent = gui
	gui.Parent = pillar
end

local function clearGeo()
	if _geoFolder then
		_geoFolder:Destroy()
		_geoFolder = nil
	end
	_geoParts = 0
	setv("o_parts", "0")
	setv("o_jams", "0")
end

local function drawGeometry(data: any)
	clearGeo()
	local anyGeo = _layers.stopLines or _layers.lanes or _layers.parking or _layers.deadEnds or _layers.jams
	if not anyGeo then return end

	local folder = Instance.new("Folder")
	folder.Name = "_DevGeometry"
	folder.Parent = ensureOverlayFolder()
	_geoFolder = folder
	_geoParts = 0

	local drawn = 0
	local function breathe(): boolean
		drawn += 1
		if drawn % 400 == 0 then
			task.wait()
			if _geoFolder ~= folder then return false end
		end
		return _geoParts < MAX_PARTS
	end

	if _layers.lanes and type(data.lanes) == "table" then
		for _, lane in data.lanes do
			if not breathe() then break end
			if type(lane.p) == "table" then
				drawPolyline(folder, lane.p, congestionColor(tonumber(lane.c) or 0), 0.18)
			end
		end
	end

	if _geoFolder == folder and _layers.stopLines and type(data.stopLines) == "table" then
		for _, sl in data.stopLines do
			if not breathe() then break end
			if typeof(sl.pos) == "Vector3" and typeof(sl.dir) == "Vector3" then
				local color = STOP_STATE_COLOR[sl.state] or STOP_STATE_COLOR.priority
				local pos = sl.pos + Vector3.new(0, LIFT + 0.05, 0)
				drawBox(folder, CFrame.lookAt(pos, pos + sl.dir), Vector3.new(tonumber(sl.w) or 7, 0.4, 0.7), color)
			end
		end
	end

	if _geoFolder == folder and _layers.parking and type(data.parking) == "table" then
		for _, sp in data.parking.street or {} do
			if not breathe() then break end
			if typeof(sp.pos) == "Vector3" then
				drawBox(folder, CFrame.new(sp.pos + Vector3.new(0, LIFT, 0)), Vector3.new(4.4, 0.25, 2.2), if sp.occ then PARK_TAKEN else PARK_FREE)
			end
		end
		for _, pad in data.parking.pads or {} do
			if not breathe() then break end
			if typeof(pad.pos) == "Vector3" then
				drawBox(folder, CFrame.new(pad.pos + Vector3.new(0, LIFT, 0)), Vector3.new(2.6, 0.2, 2.6), if pad.kind == "home" then PAD_HOME else PAD_STALL)
			end
		end
	end

	if _geoFolder == folder and _layers.deadEnds and type(data.deadEnds) == "table" then
		for _, pos in data.deadEnds do
			if not breathe() then break end
			if typeof(pos) == "Vector3" then
				drawBox(folder, CFrame.new(pos + Vector3.new(0, 4, 0)), Vector3.new(1.2, 8, 1.2), DEADEND_C)
			end
		end
	end

	local jamCount = 0
	if _geoFolder == folder and _layers.jams and type(data.jams) == "table" then
		for _, jam in data.jams do
			if not breathe() then break end
			if type(jam) == "table" and typeof(jam.pos) == "Vector3" then
				jamCount += 1
				local seconds = tonumber(jam.seconds) or 0
				local congestion = tonumber(jam.congestion) or 0
				local heat = math.clamp(math.max(congestion, seconds / 8), 0, 1)
				local height = math.clamp(2 + heat * 10, 2, 12)
				local width = 2.4 + heat * 3.2
				local pillar = drawBox(folder, CFrame.new(jam.pos + Vector3.new(0, LIFT + height / 2, 0)), Vector3.new(width, height, width), congestionColor(heat))
				if type(jam.why) == "string" then
					local still = tonumber(jam.still) or 0
					drawLabel(pillar, height, string.format("#%s %s%s", tostring(jam.id or "?"), jam.why,
						if still >= 1 then string.format(" · %ds", math.floor(still)) else ""))
				end
			end
		end
	end
	setv("o_jams", tostring(jamCount))
	setv("o_parts", tostring(_geoParts))
end

local function requestGeometry()
	if _geoBusy then _geoDirty = true; return end
	local anyGeo = _layers.stopLines or _layers.lanes or _layers.parking or _layers.deadEnds or _layers.jams
	if not anyGeo then clearGeo(); return end
	_geoBusy = true
	task.spawn(function()
		local camPos: Vector3? = nil
		local radius: number? = nil
		if _nearOnly then
			local cam = Workspace.CurrentCamera
			if cam then camPos = cam.CFrame.Position; radius = NEAR_RADIUS end
		end
		_lastGeoCam = camPos
		local layers = { stopLines = _layers.stopLines, lanes = _layers.lanes, parking = _layers.parking, deadEnds = _layers.deadEnds, jams = _layers.jams }
		local ok, data = pcall(function()
			return Net.RequestDevGeometry:InvokeServer(camPos, radius, layers)
		end)
		if ok and type(data) == "table" then
			drawGeometry(data)
		end
		_geoBusy = false
		if _geoDirty then _geoDirty = false; requestGeometry() end
	end)
end

-- ---------------------------------------------------------- hitboxes 3d --

local function ensureBox(store: { [Model]: SelectionBox }, model: Model, color: Color3)
	local existing = store[model]
	if existing and existing.Parent then return end
	local box = Instance.new("SelectionBox")
	box.Adornee = model
	box.LineThickness = 0.04
	box.Color3 = color
	box.SurfaceTransparency = 1
	box.Parent = ensureOverlayFolder()
	store[model] = box
end

local function clearStore(store: { [Model]: SelectionBox })
	for _, box in store do box:Destroy() end
	table.clear(store)
end

local function setCarLayer(on: boolean)
	if on then
		for _, m in CollectionService:GetTagged(CAR_TAG) do
			if m:IsA("Model") then ensureBox(_carBoxes, m, NEUTRAL) end
		end
		table.insert(_carTagConns, CollectionService:GetInstanceAddedSignal(CAR_TAG):Connect(function(inst)
			if inst:IsA("Model") then ensureBox(_carBoxes, inst :: Model, NEUTRAL) end
		end))
		table.insert(_carTagConns, CollectionService:GetInstanceRemovedSignal(CAR_TAG):Connect(function(inst)
			local box = _carBoxes[inst :: Model]
			if box then box:Destroy(); _carBoxes[inst :: Model] = nil end
		end))
	else
		for _, c in _carTagConns do c:Disconnect() end
		table.clear(_carTagConns)
		clearStore(_carBoxes)
	end
end

local function setPedLayer(on: boolean)
	if on then
		for _, m in CollectionService:GetTagged(PED_TAG) do
			if m:IsA("Model") then ensureBox(_pedBoxes, m, PAD_STALL) end
		end
		table.insert(_pedTagConns, CollectionService:GetInstanceAddedSignal(PED_TAG):Connect(function(inst)
			if inst:IsA("Model") then ensureBox(_pedBoxes, inst :: Model, PAD_STALL) end
		end))
		table.insert(_pedTagConns, CollectionService:GetInstanceRemovedSignal(PED_TAG):Connect(function(inst)
			local box = _pedBoxes[inst :: Model]
			if box then box:Destroy(); _pedBoxes[inst :: Model] = nil end
		end))
	else
		for _, c in _pedTagConns do c:Disconnect() end
		table.clear(_pedTagConns)
		clearStore(_pedBoxes)
	end
end

-- Tint each car box by its live driving state (cruise green .. stopped red), from the
-- server's read-only speed feed. Cars out of feed range fade back to neutral.
local function refreshCarColors()
	if _speedBusy or not _layers.hitboxes then return end
	_speedBusy = true
	task.spawn(function()
		local ok, data = pcall(function() return Net.RequestNpcSpeeds:InvokeServer() end)
		_speedBusy = false
		if not (ok and type(data) == "table") then return end
		for model, box in _carBoxes do
			if box.Parent then box.Color3 = NEUTRAL end
		end
		for _, entry in data do
			local model = entry.model
			if typeof(model) == "Instance" then
				local box = _carBoxes[model :: Model]
				if box then box.Color3 = REASON_COLOR[entry.reason] or NEUTRAL end
			end
		end
	end)
end

local function clearAllOverlays()
	setCarLayer(false)
	setPedLayer(false)
	clearGeo()
	if _overlayFolder then _overlayFolder:Destroy(); _overlayFolder = nil end
end

-- ----------------------------------------------------------- tab: health --

local function buildHealth(page: Instance)
	local banner = Instance.new("TextLabel")
	banner.Name = "Banner"
	banner.Size = UDim2.new(1, 0, 0, 34)
	banner.BackgroundColor3 = Theme.Color.BgRaised
	banner.BackgroundTransparency = 0.2
	banner.BorderSizePixel = 0
	banner.FontFace = Theme.Font.Bold
	banner.TextSize = Theme.TextSize.SM
	banner.TextColor3 = Theme.Color.TextPrimary
	banner.Text = "Checking\u{2026}"
	banner.Parent = page
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Theme.Radius.SM)
	corner.Parent = banner
	_healthBanner = banner

	local holderWrap = Instance.new("Frame")
	holderWrap.BackgroundTransparency = 1
	holderWrap.Position = UDim2.new(0, 0, 0, 40)
	holderWrap.Size = UDim2.new(1, 0, 1, -40)
	holderWrap.Parent = page
	_healthHolder = listScroller(holderWrap)
end

local function checkRow(parent: Instance, check: any, order: number)
	local row = Instance.new("Frame")
	row.BackgroundColor3 = Theme.Color.BgRaised
	row.BackgroundTransparency = 0.45
	row.BorderSizePixel = 0
	row.Size = UDim2.new(1, -4, 0, 40)
	row.LayoutOrder = order
	row.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Theme.Radius.SM)
	corner.Parent = row

	local dot = Instance.new("Frame")
	dot.Size = UDim2.fromOffset(8, 8)
	dot.Position = UDim2.new(0, 10, 0, 8)
	dot.BorderSizePixel = 0
	dot.BackgroundColor3 = STATUS_COLOR[check.status] or Theme.Color.TextSecondary
	dot.Parent = row
	local dc = Instance.new("UICorner")
	dc.CornerRadius = UDim.new(1, 0)
	dc.Parent = dot

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Position = UDim2.new(0, 26, 0, 4)
	label.Size = UDim2.new(1, -110, 0, 16)
	label.FontFace = Theme.Font.Bold
	label.TextSize = Theme.TextSize.XS
	label.TextColor3 = Theme.Color.TextPrimary
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Text = check.label
	label.Parent = row

	local detail = Instance.new("TextLabel")
	detail.BackgroundTransparency = 1
	detail.Position = UDim2.new(0, 26, 0, 20)
	detail.Size = UDim2.new(1, -36, 0, 14)
	detail.FontFace = Theme.Font.Label
	detail.TextSize = Theme.TextSize.XS
	detail.TextColor3 = Theme.Color.TextSecondary
	detail.TextXAlignment = Enum.TextXAlignment.Left
	detail.TextTruncate = Enum.TextTruncate.AtEnd
	detail.Text = check.detail or ""
	detail.Parent = row

	local value = Instance.new("TextLabel")
	value.BackgroundTransparency = 1
	value.AnchorPoint = Vector2.new(1, 0)
	value.Position = UDim2.new(1, -10, 0, 4)
	value.Size = UDim2.new(0, 90, 0, 16)
	value.FontFace = Theme.Font.Bold
	value.TextSize = Theme.TextSize.SM
	value.TextColor3 = STATUS_COLOR[check.status] or Theme.Color.TextPrimary
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.TextTruncate = Enum.TextTruncate.AtEnd
	value.Text = check.value or ""
	value.Parent = row
end

local function updateHealth()
	local holder = _healthHolder
	if not holder or not _report then return end
	for _, c in holder:GetChildren() do
		if c:IsA("Frame") then c:Destroy() end
	end
	local checks = _report.checks or {}
	local order = 0
	-- worst first: fail, then warn, then ok
	local rank = { fail = 1, warn = 2, ok = 3 }
	local sorted = table.clone(checks)
	table.sort(sorted, function(a, b)
		return (rank[a.status] or 9) < (rank[b.status] or 9)
	end)
	for _, check in sorted do
		order += 1
		checkRow(holder, check, order)
	end

	local s = _report.summary or {}
	local banner = _healthBanner
	if banner then
		if (s.fail or 0) > 0 then
			banner.Text = string.format("%d FAILING  \u{00B7}  %d warnings", s.fail, s.warn or 0)
			banner.TextColor3 = Theme.Color.Danger
		elseif (s.warn or 0) > 0 then
			banner.Text = string.format("%d warnings  \u{00B7}  no failures", s.warn)
			banner.TextColor3 = WARN_C
		else
			banner.Text = "ALL CLEAR  \u{00B7}  " .. tostring(s.ok or 0) .. " checks pass"
			banner.TextColor3 = Theme.Color.Accent
		end
	end
end

-- ------------------------------------------------------------- tab: perf --

local function buildPerf(page: Instance)
	local sf = listScroller(page)

	-- live FPS graph
	local graph = Instance.new("Frame")
	graph.Name = "FpsGraph"
	graph.BackgroundColor3 = Theme.Color.BgRaised
	graph.BackgroundTransparency = 0.4
	graph.BorderSizePixel = 0
	graph.Size = UDim2.new(1, -4, 0, 56)
	graph.LayoutOrder = 1
	graph.Parent = sf
	local gc = Instance.new("UICorner"); gc.CornerRadius = UDim.new(0, Theme.Radius.SM); gc.Parent = graph
	local gpad = Instance.new("UIPadding")
	gpad.PaddingLeft = UDim.new(0, 4); gpad.PaddingRight = UDim.new(0, 4)
	gpad.PaddingTop = UDim.new(0, 4); gpad.PaddingBottom = UDim.new(0, 4)
	gpad.Parent = graph
	local glist = Instance.new("UIListLayout")
	glist.FillDirection = Enum.FillDirection.Horizontal
	glist.HorizontalAlignment = Enum.HorizontalAlignment.Right
	glist.VerticalAlignment = Enum.VerticalAlignment.Bottom
	glist.Padding = UDim.new(0, 1)
	glist.Parent = graph
	table.clear(_fpsBars)
	for i = 1, FPS_SAMPLES do
		local bar = Instance.new("Frame")
		bar.BorderSizePixel = 0
		bar.BackgroundColor3 = Theme.Color.Accent
		bar.Size = UDim2.new(1 / FPS_SAMPLES, -1, 0, 1)
		bar.LayoutOrder = i
		bar.Parent = graph
		_fpsBars[i] = bar
	end

	section(sf, "Client", 2)
	statRow(sf, "Client FPS", "p_cfps", 3)
	statRow(sf, "1% low FPS", "p_clow", 4)
	statRow(sf, "Frame time", "p_cms", 5)
	section(sf, "Server", 10)
	statRow(sf, "Server FPS", "p_sfps", 11)
	statRow(sf, "Heartbeat", "p_hb", 12)
	statRow(sf, "Physics step", "p_phys", 13)
	statRow(sf, "Instances", "p_inst", 14)
	statRow(sf, "Net out / in", "p_net", 15)
	section(sf, "Memory (MB)", 20)
	statRow(sf, "Total", "m_total", 21)
	for i, m in MEM_TAGS do
		statRow(sf, m.label, m.key, 21 + i)
	end
	section(sf, "Scene part counts", 40)
	statRow(sf, "Roads", "s_roads", 41)
	statRow(sf, "Buildings", "s_blds", 42)
	statRow(sf, "NPC cars", "s_cars", 43)
	statRow(sf, "Workspace total", "s_total", 44)
	statRow(sf, "Overlay parts", "p_ovl", 45)
	local scan = Button.new({
		text = "Scan scene", parent = sf, compact = true, layoutOrder = 46,
		onClick = function() DeveloperController._scanScene() end,
	})
	scan.Instance.Size = UDim2.new(1, -4, 0, 26)
end

function DeveloperController._scanScene()
	local function countParts(inst: Instance?): number
		if not inst then return 0 end
		local n = 0
		for _, d in inst:GetDescendants() do
			if d:IsA("BasePart") then n += 1 end
		end
		return n
	end
	local city = Workspace:FindFirstChild("_City")
	setv("s_roads", tostring(countParts(city and city:FindFirstChild("Roads"))))
	setv("s_blds", tostring(countParts(city and city:FindFirstChild("ZonedBuildings"))))
	setv("s_cars", tostring(countParts(city and city:FindFirstChild("NPCDrivers"))))
	setv("s_total", tostring(#Workspace:GetDescendants()))
end

local function updatePerf()
	local r = _report
	-- client (local, always fresh)
	local lowFps = _fps
	if #_fpsSamples > 0 then
		local sorted = table.clone(_fpsSamples)
		table.sort(sorted)
		lowFps = sorted[math.max(1, math.floor(#sorted * 0.01))]
	end
	setvc("p_cfps", string.format("%d", _fps), if _fps >= 50 then Theme.Color.Accent elseif _fps >= 30 then WARN_C else Theme.Color.Danger)
	setv("p_clow", string.format("%d", lowFps))
	setv("p_cms", string.format("%.1f ms", if _fps > 0 then 1000 / _fps else 0))
	if not r then return end
	local perf = r.perf or {}
	setvc("p_sfps", string.format("%d", perf.serverFps or 0), if (perf.serverFps or 0) >= 45 then Theme.Color.Accent elseif (perf.serverFps or 0) >= 28 then WARN_C else Theme.Color.Danger)
	setv("p_hb", string.format("%.1f ms", perf.heartbeatMs or 0))
	setv("p_phys", string.format("%.1f ms", perf.physicsMs or 0))
	setv("p_inst", string.format("%d", perf.instances or 0))
	setv("p_net", string.format("%.0f / %.0f kbps", perf.sendKbps or 0, perf.receiveKbps or 0))
	setv("m_total", string.format("%d", perf.memoryMb or 0))
	for _, m in MEM_TAGS do
		local ok, mb = pcall(function() return Stats:GetMemoryUsageMbForTag(m.tag) end)
		setv(m.key, if ok then string.format("%d", mb) else "\u{2014}")
	end
	setv("p_ovl", tostring(_geoParts))
end

local function updateFpsGraph()
	if #_fpsBars == 0 then return end
	local n = #_fpsSamples
	for i = 1, FPS_SAMPLES do
		local bar = _fpsBars[i]
		local sample = _fpsSamples[n - FPS_SAMPLES + i]
		if sample then
			local frac = math.clamp(sample / 60, 0.02, 1)
			bar.Size = UDim2.new(1 / FPS_SAMPLES, -1, frac, 0)
			bar.BackgroundColor3 = if sample >= 50 then Theme.Color.Accent elseif sample >= 30 then WARN_C else Theme.Color.Danger
		else
			bar.Size = UDim2.new(1 / FPS_SAMPLES, -1, 0.02, 0)
			bar.BackgroundColor3 = Theme.Color.StrokeSoft
		end
	end
end

-- ---------------------------------------------------------- tab: traffic --

local function buildTraffic(page: Instance)
	local sf = listScroller(page)
	section(sf, "Vehicles", 1)
	statRow(sf, "Active", "t_active", 2)
	statRow(sf, "Moving", "t_moving", 3)
	statRow(sf, "Stopped", "t_stopped", 4)
	statRow(sf, "Stuck", "t_stuck", 5)
	statRow(sf, "Directed / ambient", "t_kind", 6)
	statRow(sf, "Avg speed", "t_avg", 7)
	statRow(sf, "Reroutes (total)", "t_rr", 8)
	section(sf, "Why they are at that speed", 10)
	local reasons = Instance.new("Frame")
	reasons.Name = "Reasons"
	reasons.BackgroundTransparency = 1
	reasons.Size = UDim2.new(1, 0, 0, 0)
	reasons.AutomaticSize = Enum.AutomaticSize.Y
	reasons.LayoutOrder = 11
	reasons.Parent = sf
	local rl = Instance.new("UIListLayout")
	rl.SortOrder = Enum.SortOrder.LayoutOrder
	rl.Padding = UDim.new(0, 3)
	rl.Parent = reasons
	_reasonHolder = reasons
	section(sf, "Network & parking", 30)
	statRow(sf, "Lanes / nodes", "t_lanes", 31)
	statRow(sf, "Dead-end lanes", "t_dead", 32)
	statRow(sf, "Parking free / total", "t_park", 33)
end

local function reasonBar(parent: Instance, label: string, count: number, maxCount: number, color: Color3, order: number)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 16)
	row.LayoutOrder = order
	row.Parent = parent

	local name = Instance.new("TextLabel")
	name.BackgroundTransparency = 1
	name.Size = UDim2.new(0, 78, 1, 0)
	name.FontFace = Theme.Font.Label
	name.TextSize = Theme.TextSize.XS
	name.TextColor3 = Theme.Color.TextSecondary
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.Text = label
	name.Parent = row

	local track = Instance.new("Frame")
	track.BackgroundColor3 = Theme.Color.Bg
	track.BackgroundTransparency = 0.4
	track.BorderSizePixel = 0
	track.Position = UDim2.new(0, 82, 0.5, -4)
	track.Size = UDim2.new(1, -118, 0, 8)
	track.Parent = row
	local tc = Instance.new("UICorner"); tc.CornerRadius = UDim.new(1, 0); tc.Parent = track

	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.Size = UDim2.new(if maxCount > 0 then count / maxCount else 0, 0, 1, 0)
	fill.Parent = track
	local fc = Instance.new("UICorner"); fc.CornerRadius = UDim.new(1, 0); fc.Parent = fill

	local num = Instance.new("TextLabel")
	num.BackgroundTransparency = 1
	num.AnchorPoint = Vector2.new(1, 0)
	num.Position = UDim2.fromScale(1, 0)
	num.Size = UDim2.new(0, 32, 1, 0)
	num.FontFace = Theme.Font.Bold
	num.TextSize = Theme.TextSize.XS
	num.TextColor3 = Theme.Color.TextPrimary
	num.TextXAlignment = Enum.TextXAlignment.Right
	num.Text = tostring(count)
	num.Parent = row
end

local function updateTraffic()
	local r = _report
	if not r then return end
	local t = r.traffic or {}
	setv("t_active", tostring(t.active or 0))
	setv("t_moving", tostring(t.moving or 0))
	setvc("t_stopped", tostring(t.stopped or 0), if (t.stopped or 0) > 0 then WARN_C else Theme.Color.TextPrimary)
	setvc("t_stuck", tostring(t.stuck or 0), if (t.stuck or 0) > 0 then Theme.Color.Danger else Theme.Color.Accent)
	setv("t_kind", string.format("%d / %d", t.directed or 0, t.ambient or 0))
	setv("t_avg", string.format("%.0f", t.avgSpeed or 0))
	setv("t_rr", tostring(t.reroutes or 0))

	local nav = r.nav or {}
	setv("t_lanes", string.format("%d / %d", nav.edges or 0, nav.nodes or 0))
	setvc("t_dead", tostring(nav.deadEnds or 0), if (nav.deadEnds or 0) > 0 then WARN_C else Theme.Color.Accent)
	local park = r.parking or {}
	setv("t_park", string.format("%d / %d", park.free or 0, park.total or 0))

	local holder = _reasonHolder
	if holder then
		for _, c in holder:GetChildren() do
			if c:IsA("Frame") then c:Destroy() end
		end
		local reasons = t.reasons or {}
		local keys: { string } = {}
		local maxCount = 1
		for k, v in reasons do
			table.insert(keys, k)
			if v > maxCount then maxCount = v end
		end
		table.sort(keys, function(a, b) return (reasons[a] or 0) > (reasons[b] or 0) end)
		local order = 0
		for _, k in keys do
			order += 1
			reasonBar(holder, k, reasons[k] or 0, maxCount, REASON_COLOR[k] or NEUTRAL, order)
		end
	end
end

-- ---------------------------------------------------------- tab: charts --

local function buildCharts(page: Instance)
	local sf = listScroller(page)
	section(sf, "Live charts", 1)
	makeMiniChart(sf, "fps", "Client FPS", 2, 60)
	makeMiniChart(sf, "hb", "Server heartbeat", 3, 33)
	makeMiniChart(sf, "recv", "Network receive", 4, 256)
	makeMiniChart(sf, "send", "Network send", 5, 256)
	makeMiniChart(sf, "mem", "Total memory", 6, 2400)

	section(sf, "Spike details", 20)
	statRow(sf, "Last network spike", "chart_spike", 21)
	statRow(sf, "Client log", "chart_clientlog", 22)

	section(sf, "Top inbound RemoteEvents", 30)
	local remotes = Instance.new("Frame")
	remotes.Name = "HotRemotes"
	remotes.BackgroundTransparency = 1
	remotes.Size = UDim2.new(1, 0, 0, 0)
	remotes.AutomaticSize = Enum.AutomaticSize.Y
	remotes.LayoutOrder = 31
	remotes.Parent = sf
	local rl = Instance.new("UIListLayout")
	rl.SortOrder = Enum.SortOrder.LayoutOrder
	rl.Padding = UDim.new(0, 3)
	rl.Parent = remotes
	_remoteHotHolder = remotes

	section(sf, "Optimization hints", 40)
	local hints = Instance.new("Frame")
	hints.Name = "Hints"
	hints.BackgroundTransparency = 1
	hints.Size = UDim2.new(1, 0, 0, 0)
	hints.AutomaticSize = Enum.AutomaticSize.Y
	hints.LayoutOrder = 41
	hints.Parent = sf
	local hl = Instance.new("UIListLayout")
	hl.SortOrder = Enum.SortOrder.LayoutOrder
	hl.Padding = UDim.new(0, 3)
	hl.Parent = hints
	_hintHolder = hints
end

-- -------------------------------------------------------- tab: profiler --

local function buildProfiler(page: Instance)
	local sf = listScroller(page)
	section(sf, "Server script profiler", 1)
	statRow(sf, "Report service cost", "prof_total", 2)
	local rows = Instance.new("Frame")
	rows.Name = "ProfilerRows"
	rows.BackgroundTransparency = 1
	rows.Size = UDim2.new(1, 0, 0, 0)
	rows.AutomaticSize = Enum.AutomaticSize.Y
	rows.LayoutOrder = 3
	rows.Parent = sf
	local rl = Instance.new("UIListLayout")
	rl.SortOrder = Enum.SortOrder.LayoutOrder
	rl.Padding = UDim.new(0, 3)
	rl.Parent = rows
	_profileHolder = rows

	section(sf, "DataStore / city save", 20)
	statRow(sf, "Save state", "save_state", 21)
	statRow(sf, "Last save", "save_last", 22)
	statRow(sf, "Payload size", "save_size", 23)
	statRow(sf, "Autosave", "save_next", 24)
	statRow(sf, "Sessions", "save_sessions", 25)

	section(sf, "Instance growth detector", 40)
	statRow(sf, "Workspace descendants", "g_workspace", 41)
	statRow(sf, "PlayerGui descendants", "g_gui", 42)
	statRow(sf, "NPC cars / peds", "g_npcs", 43)
	statRow(sf, "Overlay parts", "g_overlay", 44)
	statRow(sf, "Lua heap", "g_lua", 45)
end

local function updateProfiler()
	local r = _report
	if r then
		local profile = r.profile or {}
		local total = tonumber(profile.totalMs) or 0
		setvc("prof_total", string.format("%.2f ms", total), if total < 4 then Theme.Color.Accent elseif total < 12 then WARN_C else Theme.Color.Danger)
		local holder = _profileHolder
		if holder then
			for _, c in holder:GetChildren() do
				if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
			end
			local rows = profile.rows or {}
			if #rows == 0 then
				hintLine(holder, "No profiler rows yet. Waiting for the next server report.", Theme.Color.TextSecondary, 1)
			else
				for i = 1, math.min(10, #rows) do
					local row = rows[i]
					profileRow(holder, tostring(row.name or "service"), tonumber(row.ms) or 0, math.max(total, 0.001), row.ok ~= false, i)
				end
			end
		end

		local save = r.save or {}
		local inProgress = tonumber(save.inProgress) or tonumber(save.saving) or 0
		if save.lastOk == false then
			setvc("save_state", "FAILED", Theme.Color.Danger)
		elseif inProgress > 0 then
			setvc("save_state", "saving...", WARN_C)
		elseif save.cityLoaded == false then
			setvc("save_state", "no city loaded", WARN_C)
		else
			setvc("save_state", "ready", Theme.Color.Accent)
		end
		local lastAt = tonumber(save.lastAt) or 0
		local lastText = if lastAt > 0 then string.format("%s / %.0f ms", os.date("%H:%M:%S", lastAt), tonumber(save.lastMs) or 0) else "none yet"
		setv("save_last", lastText)
		setv("save_size", string.format("%.1f KB", (tonumber(save.lastBytes) or 0) / 1024))
		setv("save_next", string.format("%.0fs / every %.0fs", tonumber(save.nextAutosaveIn) or 0, tonumber(save.autosaveInterval) or 0))
		setv("save_sessions", string.format("%d active / %d persistent", tonumber(save.activeSessions) or 0, tonumber(save.persistentSessions) or 0))
	end

	local g = _growthStats or {}
	local function fmt(key: string): string
		return string.format("%d (%+d)", tonumber(g[key]) or 0, tonumber(g[key .. "Delta"]) or 0)
	end
	setv("g_workspace", fmt("workspace"))
	setv("g_gui", fmt("gui"))
	setv("g_npcs", string.format("%d / %d (%+d / %+d)", tonumber(g.cars) or 0, tonumber(g.peds) or 0, tonumber(g.carsDelta) or 0, tonumber(g.pedsDelta) or 0))
	setv("g_overlay", fmt("overlays"))
	setv("g_lua", string.format("%.0f MB (%+.0f)", tonumber(g.luaMb) or 0, tonumber(g.luaMbDelta) or 0))
end

local function sampleGrowth()
	local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
	local okLua, luaMb = pcall(function() return Stats:GetMemoryUsageMbForTag(Enum.DeveloperMemoryTag.LuaHeap) end)
	local current: any = {
		workspace = #Workspace:GetDescendants(),
		gui = if playerGui then #playerGui:GetDescendants() else 0,
		cars = #CollectionService:GetTagged(CAR_TAG),
		peds = #CollectionService:GetTagged(PED_TAG),
		overlays = _geoParts,
		luaMb = if okLua and typeof(luaMb) == "number" then luaMb else 0,
	}
	if _lastGrowth then
		for _, key in { "workspace", "gui", "cars", "peds", "overlays", "luaMb" } do
			local value = current[key]
			local old = tonumber(_lastGrowth[key]) or tonumber(value) or 0
			current[key .. "Delta"] = (tonumber(value) or 0) - old
		end
		local function note(key: string, label: string, threshold: number)
			local delta = tonumber(current[key .. "Delta"]) or 0
			if delta >= threshold then
				addTimeline("growth_" .. key, string.format("%s grew %+d in %.0fs", label, delta, GROWTH_TICK), WARN_C, 15)
			end
		end
		note("workspace", "Workspace descendants", 1000)
		note("gui", "PlayerGui descendants", 250)
		note("cars", "NPC cars", 50)
		note("peds", "Pedestrians", 75)
		note("overlays", "Dev overlay parts", 1000)
		if (tonumber(current.luaMbDelta) or 0) >= 80 then
			addTimeline("growth_lua", string.format("Lua heap grew %.0f MB in %.0fs", current.luaMbDelta, GROWTH_TICK), WARN_C, 15)
		end
	else
		current.workspaceDelta = 0
		current.guiDelta = 0
		current.carsDelta = 0
		current.pedsDelta = 0
		current.overlaysDelta = 0
		current.luaMbDelta = 0
	end
	_growthStats = current
	_lastGrowth = table.clone(current)
	if _visible and _activeTab == "Profiler" then updateProfiler() end
end

-- --------------------------------------------------------- tab: timeline --

local function buildTimeline(page: Instance)
	local sf = listScroller(page)
	section(sf, "Bug timeline", 1)
	hintLine(sf, "Auto-records health changes, server/client errors, network spikes, save failures, stuck traffic, and sudden instance growth.", Theme.Color.TextSecondary, 2)
	local timeline = Instance.new("Frame")
	timeline.Name = "TimelineRows"
	timeline.BackgroundTransparency = 1
	timeline.Size = UDim2.new(1, 0, 0, 0)
	timeline.AutomaticSize = Enum.AutomaticSize.Y
	timeline.LayoutOrder = 3
	timeline.Parent = sf
	local tl = Instance.new("UIListLayout")
	tl.SortOrder = Enum.SortOrder.LayoutOrder
	tl.Padding = UDim.new(0, 3)
	tl.Parent = timeline
	_timelineHolder = timeline

	section(sf, "Lag snapshots", 30)
	local snap = Button.new({
		text = "Capture lag snapshot", parent = sf, compact = true, layoutOrder = 31,
		onClick = captureSnapshot,
	})
	snap.Instance.Size = UDim2.new(1, -4, 0, 30)
	local snapshots = Instance.new("Frame")
	snapshots.Name = "SnapshotRows"
	snapshots.BackgroundTransparency = 1
	snapshots.Size = UDim2.new(1, 0, 0, 0)
	snapshots.AutomaticSize = Enum.AutomaticSize.Y
	snapshots.LayoutOrder = 32
	snapshots.Parent = sf
	local sl = Instance.new("UIListLayout")
	sl.SortOrder = Enum.SortOrder.LayoutOrder
	sl.Padding = UDim.new(0, 3)
	sl.Parent = snapshots
	_snapshotHolder = snapshots
	renderTimeline()
	renderSnapshots()
end

-- --------------------------------------------------------- tab: overlays --

local function setLayer(name: string, on: boolean)
	_layers[name] = on
	local btn = _layerBtns[name]
	if btn then btn:SetSelected(on) end
	if name == "hitboxes" then
		setCarLayer(on)
		if on then refreshCarColors() end
	elseif name == "peds" then
		setPedLayer(on)
	else
		requestGeometry()
	end
end

local function disableAllLayers()
	for name in _layers do
		_layers[name] = false
		local btn = _layerBtns[name]
		if btn then btn:SetSelected(false) end
	end
	clearAllOverlays()
	_geoParts = 0
	setv("o_parts", "0")
end

local function layerToggle(parent: Instance, name: string, text: string, order: number)
	local btn = Button.new({
		text = text, parent = parent, compact = true, layoutOrder = order,
		onClick = function() setLayer(name, not _layers[name]) end,
	})
	btn.Instance.Size = UDim2.new(1, -4, 0, 30)
	_layerBtns[name] = btn
end

local function legendRow(parent: Instance, color: Color3, text: string, order: number)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 15)
	row.LayoutOrder = order
	row.Parent = parent
	local sw = Instance.new("Frame")
	sw.Size = UDim2.fromOffset(10, 10)
	sw.Position = UDim2.new(0, 2, 0.5, -5)
	sw.BorderSizePixel = 0
	sw.BackgroundColor3 = color
	sw.Parent = row
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Position = UDim2.new(0, 18, 0, 0)
	lbl.Size = UDim2.new(1, -18, 1, 0)
	lbl.FontFace = Theme.Font.Label
	lbl.TextSize = Theme.TextSize.XS
	lbl.TextColor3 = Theme.Color.TextSecondary
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Text = text
	lbl.Parent = row
end

local function buildOverlays(page: Instance)
	local sf = listScroller(page)
	section(sf, "Vehicles", 1)
	layerToggle(sf, "hitboxes", "Car hitboxes (tinted by state)", 2)
	layerToggle(sf, "peds", "Pedestrian hitboxes", 3)
	local disable = Button.new({
		text = "Disable all overlays", parent = sf, compact = true, layoutOrder = 4,
		onClick = disableAllLayers,
	})
	disable.Instance.Size = UDim2.new(1, -4, 0, 28)
	section(sf, "Roads", 10)
	layerToggle(sf, "lanes", "Lane network (congestion)", 11)
	layerToggle(sf, "stopLines", "Stop lines (where cars should stop)", 12)
	layerToggle(sf, "deadEnds", "Dead-ends (broken lanes)", 13)
	layerToggle(sf, "jams", "Traffic jam heatmap", 14)
	section(sf, "Parking", 20)
	layerToggle(sf, "parking", "Parking spots (free / taken)", 21)

	section(sf, "Scope", 30)
	local near = Button.new({
		text = "Near camera only", parent = sf, compact = true, layoutOrder = 31,
		onClick = function()
			_nearOnly = not _nearOnly
			if _nearBtn then _nearBtn:SetSelected(_nearOnly) end
			requestGeometry()
		end,
	})
	near.Instance.Size = UDim2.new(1, -4, 0, 28)
	near:SetSelected(_nearOnly)
	_nearBtn = near
	statRow(sf, "Overlay parts drawn", "o_parts", 32)
	statRow(sf, "Jam markers", "o_jams", 33)

	section(sf, "Legend", 40)
	legendRow(sf, STOP_STATE_COLOR.go, "Stop line: signal go", 41)
	legendRow(sf, STOP_STATE_COLOR.stop, "Stop line: signal stop", 42)
	legendRow(sf, STOP_STATE_COLOR.yield, "Stop line: yield", 43)
	legendRow(sf, STOP_STATE_COLOR.priority, "Stop line: priority road", 44)
	legendRow(sf, C_GREEN, "Lane clear  \u{2192}  red = jammed", 45)
	legendRow(sf, C_RED, "Jam heatmap pillar", 46)
	legendRow(sf, PARK_FREE, "Parking free", 47)
	legendRow(sf, PARK_TAKEN, "Parking taken", 48)
	legendRow(sf, DEADEND_C, "Dead-end lane", 49)
end

-- ------------------------------------------------------------- tab: map --
-- Author the map's DEFAULT city. "Save" bakes the whole loaded city (terrain, roads,
-- zones, buildings) as this map's template via the server; new players who start a
-- city on this map begin from it. The readout lists the auto-detected edge connections
-- (roads dragged to the boundary) that travel with the saved map.

local _mapStatus: TextLabel? = nil
local _mapConnHolder: Frame? = nil
local _mapBusy = false
local _mapListBusy = false

local function mapParagraph(parent: Instance, text: string, order: number)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, -4, 0, 0)
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.LayoutOrder = order
	l.FontFace = Theme.Font.Label
	l.TextSize = Theme.TextSize.XS
	l.TextColor3 = Theme.Color.TextSecondary
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Top
	l.TextWrapped = true
	l.Text = text
	l.Parent = parent
end

local function refreshMapConns()
	local holder = _mapConnHolder
	if not holder or _mapListBusy then return end
	_mapListBusy = true
	task.spawn(function()
		local ok, res = pcall(function() return Net.RequestDevOutsideConn:InvokeServer("list") end)
		_mapListBusy = false
		if not (ok and type(res) == "table" and type(res.conns) == "table") then return end
		for _, c in holder:GetChildren() do
			if c:IsA("TextLabel") then c:Destroy() end
		end
		local conns = res.conns
		setv("map_conncount", tostring(#conns))
		table.sort(conns, function(a, b) return tostring(a.id) < tostring(b.id) end)
		for order, conn in conns do
			local row = Instance.new("TextLabel")
			row.BackgroundTransparency = 1
			row.Size = UDim2.new(1, 0, 0, 15)
			row.LayoutOrder = order
			row.FontFace = Theme.Font.Label
			row.TextSize = Theme.TextSize.XS
			row.TextColor3 = Theme.Color.TextSecondary
			row.TextXAlignment = Enum.TextXAlignment.Left
			row.Text = string.format("\u{2022}  %s  (%s)", tostring(conn.id), tostring(conn.side))
			row.Parent = holder
		end
	end)
end

local function saveMapDefault()
	if _mapBusy then return end
	_mapBusy = true
	if _mapStatus then _mapStatus.Text = "Saving\u{2026}"; _mapStatus.TextColor3 = Theme.Color.TextSecondary end
	task.spawn(function()
		local ok, res = pcall(function() return Net.RequestDevOutsideConn:InvokeServer("saveMapDefault") end)
		_mapBusy = false
		local status = _mapStatus
		if not status then return end
		if ok and type(res) == "table" and res.ok then
			status.Text = tostring(res.message or "Saved as the map default.")
			status.TextColor3 = Theme.Color.Accent
		else
			local msg = (type(res) == "table" and res.error) or "Save failed."
			status.Text = tostring(msg)
			status.TextColor3 = Theme.Color.Danger
		end
		refreshMapConns()
	end)
end

local function buildMap(page: Instance)
	local sf = listScroller(page)
	section(sf, "Map default", 1)
	mapParagraph(sf, "Bake the city you are in now as the DEFAULT for its map. Terrain, roads, zones and every building are saved; each new player who starts a city on this map begins from this layout (their money, clock and population start fresh).", 2)
	local saveBtn = Button.new({
		text = "Save this city as the map default", parent = sf, compact = true, layoutOrder = 3,
		onClick = saveMapDefault,
	})
	saveBtn.Instance.Size = UDim2.new(1, -4, 0, 32)

	local status = Instance.new("TextLabel")
	status.Name = "MapStatus"
	status.BackgroundTransparency = 1
	status.Size = UDim2.new(1, -4, 0, 0)
	status.AutomaticSize = Enum.AutomaticSize.Y
	status.LayoutOrder = 4
	status.FontFace = Theme.Font.Bold
	status.TextSize = Theme.TextSize.XS
	status.TextColor3 = Theme.Color.TextSecondary
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.TextWrapped = true
	status.Text = ""
	status.Parent = sf
	_mapStatus = status

	section(sf, "Detected edge connections", 10)
	mapParagraph(sf, "Drag any road to the map edge and it becomes an outside connection -- an outward arrow appears, and it is saved with the map.", 11)
	statRow(sf, "Connections", "map_conncount", 12)
	local refresh = Button.new({
		text = "Refresh", parent = sf, compact = true, layoutOrder = 13,
		onClick = refreshMapConns,
	})
	refresh.Instance.Size = UDim2.new(1, -4, 0, 26)

	local holder = Instance.new("Frame")
	holder.Name = "ConnList"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(1, 0, 0, 0)
	holder.AutomaticSize = Enum.AutomaticSize.Y
	holder.LayoutOrder = 14
	holder.Parent = sf
	local hl = Instance.new("UIListLayout")
	hl.SortOrder = Enum.SortOrder.LayoutOrder
	hl.Padding = UDim.new(0, 2)
	hl.Parent = holder
	_mapConnHolder = holder
end

-- --------------------------------------------------------------- report --

local function updateActiveTab()
	if _activeTab == "Health" then updateHealth()
	elseif _activeTab == "Perf" then updatePerf()
	elseif _activeTab == "Charts" then updateCharts()
	elseif _activeTab == "Profiler" then updateProfiler()
	elseif _activeTab == "Timeline" then renderTimeline(); renderSnapshots()
	elseif _activeTab == "Traffic" then updateTraffic()
	elseif _activeTab == "Map" then refreshMapConns() end
end

local function requestReport()
	if _reportBusy then return end
	_reportBusy = true
	task.spawn(function()
		local ok, data = pcall(function() return Net.RequestDevReport:InvokeServer() end)
		_reportBusy = false
		if ok and type(data) == "table" then
			_report = data
			handleReportTimeline(data)
			if _visible then updateActiveTab() end
		end
	end)
end

-- ----------------------------------------------------------- panel build --

local function selectTab(name: string)
	_activeTab = name
	for tabName, page in _pages do
		page.Visible = tabName == name
	end
	for tabName, tab in _tabs do
		tab:SetSelected(tabName == name)
	end
	updateActiveTab()
end

local function makeDraggable(handle: GuiObject, frame: Frame)
	local dragging = false
	local dragStart = Vector3.zero
	local startPos = frame.Position
	table.insert(_conns, handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = frame.Position
		end
	end))
	table.insert(_conns, UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end))
	table.insert(_conns, UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))
end

local function buildPanel()
	if _built then return end
	_built = true

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	local found = playerGui:FindFirstChild(PANEL_GUI_NAME)
	local gui: ScreenGui
	if found and found:IsA("ScreenGui") then
		gui = found
	else
		if found then found:Destroy() end
		gui = Instance.new("ScreenGui")
		gui.Name = PANEL_GUI_NAME
		gui.ResetOnSpawn = false
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.DisplayOrder = Theme.Layer.Dev + 3
		gui.Enabled = false
		gui.Parent = playerGui
	end
	_gui = gui

	local root = Instance.new("Frame")
	root.Name = "DeveloperRoot"
	root.Visible = false
	root.AnchorPoint = Vector2.new(1, 0)
	root.Position = UDim2.new(1, -PANEL_MARGIN, 0, PANEL_MARGIN)
	root.Size = UDim2.new(1, -(PANEL_MARGIN * 2), 0, PANEL_H)
	local rootLimit = Instance.new("UISizeConstraint")
	rootLimit.MaxSize = Vector2.new(PANEL_MAX_W, PANEL_H)
	rootLimit.Parent = root
	root.Parent = gui
	Glass.apply(root, Theme.Radius.LG)
	-- Near-opaque: the world bleeding through the glass makes small text look outlined.
	root.BackgroundTransparency = 0.04
	_root = root

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, Theme.Pad.LG)
	pad.PaddingBottom = UDim.new(0, Theme.Pad.LG)
	pad.PaddingLeft = UDim.new(0, Theme.Pad.LG)
	pad.PaddingRight = UDim.new(0, Theme.Pad.LG)
	pad.Parent = root

	-- header
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 24)
	header.Parent = root
	makeDraggable(header, root)

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -116, 1, 0)
	title.FontFace = Theme.Font.Bold
	title.TextSize = Theme.TextSize.MD
	title.TextColor3 = Theme.Color.TextPrimary
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "STAFF \u{00B7} DEV"
	title.Parent = header

	local staffMode = Button.new({
		text = "ADMIN",
		compact = true,
		parent = header,
		onClick = function()
			local admin = require(script.Parent:WaitForChild("AdminController"))
			DeveloperController.SetVisible(false)
			admin.SetVisible(true)
		end,
	})
	staffMode.Instance.AnchorPoint = Vector2.new(1, 0.5)
	staffMode.Instance.Position = UDim2.new(1, -30, 0.5, 0)
	staffMode.Instance.Size = UDim2.fromOffset(76, 22)

	local close = Instance.new("TextButton")
	close.AnchorPoint = Vector2.new(1, 0.5)
	close.Position = UDim2.new(1, 0, 0.5, 0)
	close.Size = UDim2.fromOffset(22, 22)
	close.BackgroundColor3 = Theme.Color.BgRaised
	close.BackgroundTransparency = 0.2
	close.AutoButtonColor = true
	close.FontFace = Theme.Font.Bold
	close.TextSize = Theme.TextSize.SM
	close.TextColor3 = Theme.Color.TextSecondary
	close.Text = "\u{00D7}"
	close.Parent = header
	local cc = Instance.new("UICorner"); cc.CornerRadius = UDim.new(0, Theme.Radius.SM); cc.Parent = close
	table.insert(_conns, close.Activated:Connect(function() DeveloperController.SetVisible(false) end))

	-- tab strip
	local strip = Instance.new("Frame")
	strip.Name = "Tabs"
	strip.BackgroundTransparency = 1
	strip.Position = UDim2.new(0, 0, 0, 30)
	strip.Size = UDim2.new(1, 0, 0, 24)
	strip.Parent = root
	local slist = Instance.new("UIListLayout")
	slist.FillDirection = Enum.FillDirection.Horizontal
	slist.SortOrder = Enum.SortOrder.LayoutOrder
	slist.Padding = UDim.new(0, 2)
	slist.Parent = strip

	-- content
	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Position = UDim2.new(0, 0, 0, 60)
	content.Size = UDim2.new(1, 0, 1, -60)
	content.Parent = root

	local builders: { [string]: (Instance) -> () } = {
		Health = buildHealth, Perf = buildPerf, Charts = buildCharts, Profiler = buildProfiler, Timeline = buildTimeline,
		Traffic = buildTraffic, Overlays = buildOverlays, Map = buildMap,
	}
	for order, name in { "Health", "Perf", "Charts", "Profiler", "Timeline", "Traffic", "Overlays", "Map" } do
		local page = Instance.new("Frame")
		page.Name = name
		page.BackgroundTransparency = 1
		page.Size = UDim2.fromScale(1, 1)
		page.Visible = false
		page.Parent = content
		_pages[name] = page
		builders[name](page)

		local tab = Tab.new({
			text = name, parent = strip, layoutOrder = order,
			onClick = function() selectTab(name) end,
		})
		_tabs[name] = tab
	end

	selectTab("Health")
end

-- ----------------------------------------------------------- visibility --

function DeveloperController.SetVisible(visible: boolean)
	if not _built then buildPanel() end
	if visible then
		local ok, admin = pcall(function()
			return require(script.Parent:WaitForChild("AdminController"))
		end)
		if ok and admin and admin.SetVisible then
			admin.SetVisible(false)
		end
	end
	_visible = visible
	if _root then _root.Visible = visible end
	if _gui then
		local adminRoot = _gui:FindFirstChild("AdminRoot")
		local adminVisible = adminRoot ~= nil and (adminRoot :: GuiObject).Visible
		local launcher = _gui:FindFirstChild("Launcher")
		_gui.Enabled = true
		if launcher and launcher:IsA("GuiObject") then
			launcher.Visible = not visible and not adminVisible
		end
	end
	if visible then
		requestReport()
		if _layers.hitboxes then refreshCarColors() end
		if _layers.stopLines or _layers.lanes or _layers.parking or _layers.deadEnds or _layers.jams then requestGeometry() end
	end
end

local function toggle()
	DeveloperController.SetVisible(not _visible)
end

-- --------------------------------------------------------------- update --

local function onHeartbeat(dt: number)
	_frameAccum += dt
	_frameCount += 1
	if _frameAccum >= 0.25 then
		_fps = math.floor(_frameCount / _frameAccum + 0.5)
		_frameAccum = 0
		_frameCount = 0
		table.insert(_fpsSamples, _fps)
		if #_fpsSamples > 240 then table.remove(_fpsSamples, 1) end
	end

	_remoteAccum += dt
	if _remoteAccum >= REMOTE_WINDOW then
		flushRemoteWindow(_remoteAccum)
		_remoteAccum = 0
		if _visible and _activeTab == "Charts" then updateCharts() end
	end

	_chartAccum += dt
	if _chartAccum >= CHART_TICK then
		_chartAccum = 0
		sampleCharts()
		if _visible and _activeTab == "Charts" then updateCharts() end
	end

	_growthAccum += dt
	if _growthAccum >= GROWTH_TICK then
		_growthAccum = 0
		sampleGrowth()
	end

	-- overlays run whether or not the panel is open (a dev may hide the panel and watch).
	if _layers.hitboxes then
		_speedAccum += dt
		if _speedAccum >= SPEED_POLL then
			_speedAccum = 0
			refreshCarColors()
		end
	end

	local anyGeo = _layers.stopLines or _layers.lanes or _layers.parking or _layers.deadEnds or _layers.jams
	if anyGeo then
		_geoAccum += dt
		local forceMove = false
		if _nearOnly then
			local cam = Workspace.CurrentCamera
			if cam and (not _lastGeoCam or (cam.CFrame.Position - _lastGeoCam).Magnitude > GEO_MOVE) then
				forceMove = true
			end
		end
		if (_geoAccum >= GEO_REFRESH or forceMove) and not _geoBusy then
			_geoAccum = 0
			requestGeometry()
		end
	end

	if not _visible then return end

	_pollAccum += dt
	if _pollAccum >= REPORT_POLL then
		_pollAccum = 0
		requestReport()
	end

	_perfAccum += dt
	if _perfAccum >= PERF_TICK then
		_perfAccum = 0
		if _activeTab == "Perf" then
			updatePerf()
			updateFpsGraph()
		elseif _activeTab == "Profiler" then
			updateProfiler()
		end
	end
end

-- ----------------------------------------------------------------- start --

function DeveloperController.Start()
	if _started then return end

	local function ensure()
		local tier = LocalPlayer:GetAttribute("AdminTier")
		if RunService:IsStudio() then tier = "admin" end
		if tier ~= "admin" then return end
		if _started then return end
		_started = true
		_tier = "admin"
		hookDiagnostics()

		table.insert(_conns, UserInputService.InputBegan:Connect(function(input, gameProcessed)
			if gameProcessed then return end
			if Settings.pressed("DeveloperPanel", input) then toggle() end
		end))
		table.insert(_conns, RunService.Heartbeat:Connect(onHeartbeat))
	end

	ensure()
	if not _started then
		table.insert(_conns, LocalPlayer:GetAttributeChangedSignal("AdminTier"):Connect(ensure))
	end
end

function DeveloperController.Cleanup()
	for _, c in _conns do c:Disconnect() end
	table.clear(_conns)
	for _, c in _carTagConns do c:Disconnect() end
	for _, c in _pedTagConns do c:Disconnect() end
	table.clear(_carTagConns)
	table.clear(_pedTagConns)
	clearAllOverlays()
	if _gui then _gui:Destroy(); _gui = nil end
	_remoteStatsHooked = false
	_built = false
	_started = false
end

return DeveloperController
