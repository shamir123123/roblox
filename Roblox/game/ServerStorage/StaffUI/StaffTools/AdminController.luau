--!strict
-- AdminController
-- Builds the themed admin / debug panel, for admins only. It observes server
-- metrics (RequestServerDebugStats), the DebugService snapshot feed
-- (DebugSnapshot / ToggleDebugMode), client perf, and a live LogService tail.
-- Tier comes from the server-set AdminTier attribute (a UI hint); the server
-- re-checks authority on every request, so nothing here is trusted for state.
--
-- F4 toggles the panel. Hidden = the snapshot feed is turned off to save
-- bandwidth. The panel is draggable by its header.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local UserInputService  = game:GetService("UserInputService")
local LogService        = game:GetService("LogService")
local Workspace         = game:GetService("Workspace")
local Lighting          = game:GetService("Lighting")
local Stats             = game:GetService("Stats") :: any

-- Resolved by NAME, not by position. This bundle ships from ServerStorage and is handed
-- to a staff member at runtime through PlayerGui (the server cannot write to
-- PlayerScripts), so script.Parent.Parent is no longer the scripts container.
local PlayerScripts = Players.LocalPlayer:WaitForChild("PlayerScripts")
local UI      = PlayerScripts:WaitForChild("UI")
local Kit     = UI:WaitForChild("Kit")
local Theme      = require(UI:WaitForChild("Theme"))
local Icons      = require(UI:WaitForChild("Icons"))
local Button     = require(Kit:WaitForChild("Button"))
local IconButton = require(Kit:WaitForChild("IconButton"))
local Settings = require(PlayerScripts:WaitForChild("Core"):WaitForChild("Settings"))
local CursorRay = require(PlayerScripts:WaitForChild("Core"):WaitForChild("CursorRay"))
local Tab        = require(Kit:WaitForChild("Tab"))
local Glass      = require(Kit:WaitForChild("Glass"))
local UIEvents   = require(ReplicatedStorage.City.UIEvents)
-- Rebuilds a submitted creation from its blob so a reviewer can LOOK at the thing before
-- deciding on it. The same builder the editor and the placer use, so the preview is the
-- geometry that would actually go live -- not an approximation of it.
local CreationBuilder = require(ReplicatedStorage:WaitForChild("Editor"):WaitForChild("CreationBuilder"))
local BadAppleShow = require(script.Parent:WaitForChild("BadAppleShow"))

local PANEL_GUI_NAME = "StaffPanel"
local POLL_INTERVAL  = 1.0   -- server stats RF
local UI_TICK       = 0.25  -- text refresh cadence
local FPS_WINDOW    = 0.5
local NPC_LIST_CAP  = 40
local LOG_CAP       = 150
local ROUTE_LIFT    = 0.5
local MAX_PARTS     = 18000
local PANEL_MARGIN  = 10
local PANEL_MAX_W   = 560
local PANEL_H       = 560
local LAUNCHER_W    = 88   -- matches the launcher's fixed Size below
local LAUNCHER_H    = 30
local DRAG_CLICK_THRESHOLD = 4 -- px; below this, a press+release still counts as a click
local ROW_VALUE_W   = 178
local ROW_GAP       = 8
local ROW_GUTTER    = 8
local LANE_COLOR    = Color3.fromRGB(90, 200, 255)
local PARKING_COLOR = Color3.fromRGB(255, 216, 92)
local MOVE_COLOR: { [string]: Color3 } = {
	left     = Color3.fromRGB(80, 230, 122),
	right    = Color3.fromRGB(255, 148, 51),
	straight = Color3.fromRGB(90, 160, 255),
	uturn    = Color3.fromRGB(235, 70, 70),
}
local TAB_ORDER     = { "Debug", "Review", "Tools", "Saves", "Cities", "Perf", "World", "Net", "NPCs", "Log", "Routes", "Access" }
local ROUTE_NEAR_RADIUS  = 600
local ROUTE_REFRESH_MOVE = 120
local ROUTE_DEBOUNCE     = 0.4
local SPEED_POLL         = 0.5
local SPEED_COLOR: { [string]: Color3 } = {
	cruise   = Color3.fromRGB(120, 230, 130),
	slow     = Color3.fromRGB(240, 210, 90),
	carAhead = Color3.fromRGB(240, 210, 90),
	turn     = Color3.fromRGB(255, 148, 51),
	yield    = Color3.fromRGB(245, 170, 60),
	blocked  = Color3.fromRGB(235, 90, 70),
	follow   = Color3.fromRGB(240, 210, 90),
	standoff = Color3.fromRGB(235, 90, 70),
	redLight = Color3.fromRGB(235, 70, 70),
	stopped  = Color3.fromRGB(235, 70, 70),
}
local SPEED_LABEL: { [string]: string } = {
	cruise = "cruise", slow = "slow", carAhead = "car ahead", follow = "following", turn = "turn",
	yield = "yield", blocked = "blocked", standoff = "standoff", redLight = "red light", stopped = "stopped",
}
local TAB_TIER: { [string]: string } = {
	Debug = "tester", Perf = "tester", World = "tester", Net = "tester", Log = "tester",
	Tools = "admin", Saves = "admin", Cities = "admin", NPCs = "admin", Routes = "admin", Access = "admin",
	-- The one curator-gated tab. Testers must NOT see it, which is why curator ranks
	-- above tester rather than level with it -- see TIER_RANK.
	Review = "curator",
}
local ADMIN_DEV_DUPES: { [string]: boolean } = { Perf = true, Routes = true }
-- Above the tier ladder entirely: being the place owner is not a rank you can be granted,
-- so it is not a tier. Only the owner may edit who is staff, and the server enforces that
-- on the remote -- hiding the tab is presentation, not protection.
local OWNER_ONLY_TABS: { [string]: boolean } = { Access = true }
-- Governs which F4 TABS a tier may see, and nothing else -- every gate that grants real
-- power asks StaffRoster for tier == "admin" exactly, so nothing here can widen one.
--
-- A STRICT ladder, tester < curator < admin. Curator sits above tester rather than level
-- with it so a curator-gated tab (the creation review queue) is hidden from testers while
-- still being visible to admins and the owner -- with both at rank 1 that tab would be
-- unexpressible, because "curator or better" and "tester or better" become the same test.
-- Ranking curator above tester grants it nothing extra: admin-gated tabs stay out of reach.
local TIER_RANK: { [string]: number } = { tester = 1, curator = 2, admin = 3 }

local LocalPlayer = Players.LocalPlayer

local AdminController = {}

local _tier = "admin" -- set from the AdminTier attribute in Start; gates tabs
local _isOwner = false -- set from the IsPlaceOwner attribute in Start; gates the Access tab
-- Per-tab "the user just opened this" hooks. Only Access uses one (it re-reads the staff
-- list from the server); the table stays empty for every other tab.
local _tabOpened: { [string]: () -> () } = {}
local _started = false
local _built   = false
local _visible = false
local _conns: { RBXScriptConnection } = {}
-- Tears down the Review tab's 3D preview. Module-level because the preview is built deep
-- inside the Review tab's own scope, but the two things that must stop it -- hiding the
-- panel and Cleanup -- live out here. Its orbit is a RenderStepped connection that is
-- REASSIGNED per preview, so it cannot just be pushed into _conns and forgotten.
local _clearReviewPreview: (() -> ())? = nil
local _net: any = nil
local _gui: ScreenGui? = nil
local _root: Frame? = nil
local _title: TextLabel? = nil -- header line; carries the live player count
local _launcherWasDragged: () -> boolean = function() return false end

local _serverStats: { [string]: any } = {}
local _statsInflight = false
local _snapshot: any = nil

local _frameAccum = 0
local _frameCount = 0
local _fps = 0
local _uiAccum = 0
local _pollAccum = 0

local _activeTab = "Debug"
local _pages: { [string]: GuiObject } = {}
local _tabs: { [string]: any } = {}
local _v: { [string]: TextLabel } = {}

local _npcHolder: ScrollingFrame? = nil
local _logHolder: ScrollingFrame? = nil
local _logEntries: { { text: string, color: Color3 } } = {}
local _logLabels: { TextLabel } = {}
local _logSeq = 0

local _routesShowBtn: any = nil
local _routesOn = false
local _routesBusy = false
local _routesFolder: Folder? = nil
local _routeParts = 0
local _routesNearOnly = false
local _routesNearBtn: any = nil
local _routesDirty = false
local _routesDirtyAt = 0
local _lastDrawCamPos: Vector3? = nil

local _speedsOn = false
local _speedsBtn: any = nil
local _speedsBusy = false
local _speedsAccum = 0
local _speedBillboards: { [string]: BillboardGui } = {}
local _speedData: { [string]: { speed: number, reason: string, limit: any } } = {}

local _inspectorOn = false
local _inspectorBusy = false
local _inspectorBtn: any = nil
local _inspectorInfo: TextLabel? = nil
local _inspectorFolder: Folder? = nil
local _inspectorHighlight: Highlight? = nil

local INSPECT_ROUTE_COLOR = Color3.fromRGB(255, 92, 214)
local INSPECT_TARGET_COLOR = Color3.fromRGB(255, 220, 82)

local _saveQuery: TextBox? = nil
local _saveStatus: TextLabel? = nil
local _saveHolder: ScrollingFrame? = nil
local _saveBusy = false
local _saveLastQuery: any = ""
local _saveStatusPermanent = ""   -- restored after hover overrides it
local _saveStatusDanger = false

-- networking tab: inbound RemoteEvent counters (1s rolling window)
local _netByName: { [string]: number } = {}
local _netRateByName: { [string]: number } = {}
local _netBytes = 0
local _netWindow = 0
local _netEvSec = 0
local _netKbSec = 0
local _netRemoteCount = 0
local _netHolder: ScrollingFrame? = nil

-- ------------------------------------------------------------- ui helpers --

local function setv(key: string, text: string)
	local l = _v[key]
	if l then
		l.TextScaled = true
		l.Text = text
	end
end

local function tierAllows(req: string): boolean
	return (TIER_RANK[_tier] or 0) >= (TIER_RANK[req] or 99)
end

local function tabVisible(name: string): boolean
	if OWNER_ONLY_TABS[name] and not _isOwner then return false end
	if not tierAllows(TAB_TIER[name] or "admin") then return false end
	return not (_tier == "admin" and ADMIN_DEV_DUPES[name] == true)
end

local function ival(v: any): string
	return if typeof(v) == "number" then string.format("%.0f", v) else "\u{2014}"
end

local function addRow(parent: Instance, label: string, key: string, order: number)
	local row = Instance.new("Frame")
	row.Name = key
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, -ROW_GUTTER, 0, 18)
	row.LayoutOrder = order
	row.Parent = parent

	local name = Instance.new("TextLabel")
	name.BackgroundTransparency = 1
	name.Size = UDim2.new(1, -(ROW_VALUE_W + ROW_GAP), 1, 0)
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
	value.Size = UDim2.new(0, ROW_VALUE_W, 1, 0)
	value.FontFace = Theme.Font.Bold
	value.TextSize = Theme.TextSize.XS
	value.TextColor3 = Theme.Color.TextPrimary
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.TextScaled = true
	value.TextWrapped = false
	value.TextTruncate = Enum.TextTruncate.None
	value.Text = "\u{2014}"
	local textLimit = Instance.new("UITextSizeConstraint")
	textLimit.MinTextSize = 8
	textLimit.MaxTextSize = Theme.TextSize.XS
	textLimit.Parent = value
	value.Parent = row
	value.TextScaled = true

	_v[key] = value
end

local function sectionLabel(parent: Instance, text: string, order: number)
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

local function listPage(name: string): ScrollingFrame
	local page = Instance.new("ScrollingFrame")
	page.Name = name
	page.BackgroundTransparency = 1
	page.BorderSizePixel = 0
	page.Size = UDim2.fromScale(1, 1)
	page.Visible = false
	page.CanvasSize = UDim2.new()
	page.AutomaticCanvasSize = Enum.AutomaticSize.Y
	page.ScrollBarThickness = 4
	page.ScrollBarImageColor3 = Theme.Color.Stroke
	page.ScrollingDirection = Enum.ScrollingDirection.Y
	page.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 3)
	list.Parent = page
	return page
end

local function scroller(parent: Instance, posY: number): ScrollingFrame
	local sf = Instance.new("ScrollingFrame")
	sf.BackgroundTransparency = 1
	sf.BorderSizePixel = 0
	sf.Position = UDim2.new(0, 0, 0, posY)
	sf.Size = UDim2.new(1, 0, 1, -posY)
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
	list.Padding = UDim.new(0, 2)
	list.Parent = sf
	return sf
end

-- ------------------------------------------------------------------ data --

local function pollServer()
	if _statsInflight or not _net then return end
	_statsInflight = true
	task.spawn(function()
		local ok, res = pcall(function()
			return _net.RequestServerDebugStats:InvokeServer()
		end)
		if ok and type(res) == "table" then
			_serverStats = res
		end
		_statsInflight = false
	end)
end

local function countOf(root: Instance?, class: string): number
	if not root then return 0 end
	local n = 0
	for _, d in root:GetDescendants() do
		if d:IsA(class) then n += 1 end
	end
	return n
end

local function netOwnerLabel(): string
	local city = Workspace:FindFirstChild("_City")
	local folder = city and city:FindFirstChild("NPCDrivers")
	if not folder then return "\u{2014}" end
	local m = folder:FindFirstChildWhichIsA("Model")
	if not m then return "\u{2014}" end
	local part = (m :: any).PrimaryPart or m:FindFirstChildWhichIsA("BasePart")
	if not part then return "\u{2014}" end
	local ok, owned = pcall(function() return (part :: any):IsNetworkOwner() end)
	if not ok then return "server" end
	return if owned then "client" else "server"
end

-- Rough payload byte estimate for inbound remote args (bounded recursion).
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
		local c = 0
		for k, vv in v do
			c += 1
			if c > 200 then break end
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

local function updateText()
	-- client perf
	setv("c_fps", string.format("%.0f", _fps))
	setv("c_frame", string.format("%.1f ms", if _fps > 0 then 1000 / _fps else 0))
	setv("c_ping", string.format("%.0f ms", LocalPlayer:GetNetworkPing() * 1000))
	setv("c_mem", string.format("%.0f MB", Stats:GetTotalMemoryUsageMb()))
	setv("c_micro", "Ctrl+F6")
	local pg = LocalPlayer:FindFirstChild("PlayerGui")
	setv("c_ui", tostring(countOf(pg, "GuiObject")))
	setv("c_scripts", tostring(countOf(PlayerScripts, "LocalScript") + countOf(pg, "LocalScript")))
	local cam = Workspace.CurrentCamera
	if cam then
		local p = cam.CFrame.Position
		setv("c_cam", string.format("%.0f, %.0f, %.0f", p.X, p.Y, p.Z))
	else
		setv("c_cam", "\u{2014}")
	end
	setv("c_input", UserInputService:GetLastInputType().Name)

	-- server perf
	local s = _serverStats
	local function sv(field: string, fmt: string): string
		local v = s[field]
		return if typeof(v) == "number" then string.format(fmt, v) else "\u{2014}"
	end
	setv("s_fps", sv("serverFps", "%.0f"))
	setv("s_hb", sv("serverHeartbeatMs", "%.1f ms"))
	setv("s_phys", sv("serverPhysicsMs", "%.1f ms"))
	setv("s_pfps", sv("physicsFps", "%.0f"))
	setv("s_mem", sv("memoryMb", "%.0f MB"))
	setv("s_inst", sv("instanceCount", "%.0f"))
	setv("s_send", sv("sendKbps", "%.0f kbps"))
	setv("s_recv", sv("receiveKbps", "%.0f kbps"))
	setv("s_players", sv("playerCount", "%.0f"))
	local up = s.uptimeSec
	if typeof(up) == "number" then
		setv("s_up", string.format("%d:%02d", math.floor(up / 60), math.floor(up % 60)))
	else
		setv("s_up", "\u{2014}")
	end
	setv("s_job", tostring(s.jobId or "\u{2014}"))
	setv("s_place", tostring(game.PlaceId))
	setv("s_region", "n/a")

	-- world
	local snap = _snapshot
	if typeof(snap) == "table" then
		local r = snap.roads or {}
		setv("w_players", ival(snap.playerCount))
		setv("w_npc", ival(snap.npcCount))
		setv("w_nodes", ival(r.nodeCount))
		setv("w_segs", ival(r.segCount))
		setv("w_edges", ival(r.edgeCount))
		setv("w_inter", ival(r.intersections))
		setv("w_dead", ival(r.deadEnds))
	end
	setv("w_feed", if _visible then "live (0.5s)" else "off")
	setv("w_ws", tostring(#Workspace:GetChildren()))
	setv("w_stream", if Workspace.StreamingEnabled then "on" else "off")

	-- networking
	setv("net_recv", string.format("%.0f kbps", Stats.DataReceiveKbps))
	setv("net_send", string.format("%.0f kbps", Stats.DataSendKbps))
	setv("net_ping", string.format("%.0f ms", LocalPlayer:GetNetworkPing() * 1000))
	setv("net_ev", string.format("%.0f /s", _netEvSec))
	setv("net_kb", string.format("%.1f KB/s", _netKbSec))
	setv("net_remotes", tostring(_netRemoteCount))
	setv("net_stream", if Workspace.StreamingEnabled then "on" else "off")
	setv("net_owner", netOwnerLabel())

	-- Header player count: players in the GAME, summed across every live server by
	-- AdminService and carried in the stats feed (refreshed ~30s). Falls back to this
	-- server's own roster, labelled "here", whenever that number is unavailable.
	local t = _title
	if t then
		local inGame = tonumber(s.universePlayers)
		local n = inGame or #Players:GetPlayers()
		t.Text = string.format("STAFF \u{00B7} %s \u{00B7} %d %s", string.upper(_tier), n, if inGame then "in game" else "here")
	end
end

local function rebuildNpcList()
	local holder = _npcHolder
	if not holder then return end
	for _, c in holder:GetChildren() do
		if c:IsA("TextLabel") then c:Destroy() end
	end

	local snap = _snapshot
	if not (typeof(snap) == "table" and typeof(snap.npcs) == "table") then
		setv("n_total", "0")
		setv("n_stopped", "0")
		return
	end

	local npcs = snap.npcs
	local stopped = 0
	for _, n in npcs do
		if (tonumber(n.speed) or 0) < 0.5 then stopped += 1 end
	end
	setv("n_total", tostring(#npcs))
	setv("n_stopped", tostring(stopped))

	local shown = 0
	for i, n in npcs do
		if shown >= NPC_LIST_CAP then break end
		shown += 1
		local v = tonumber(n.speed) or 0
		local row = Instance.new("TextLabel")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, 15)
		row.LayoutOrder = i
		row.FontFace = Theme.Font.Label
		row.TextSize = Theme.TextSize.XS
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.TextTruncate = Enum.TextTruncate.AtEnd
		row.TextColor3 = if v < 0.5 and tostring(n.kind) ~= "walker" then Theme.Color.Danger else Theme.Color.TextSecondary
		local route = ""
		if tonumber(n.routeIndex) and tonumber(n.routeLength) then
			route = string.format("   %d/%d", tonumber(n.routeIndex), tonumber(n.routeLength))
		end
		row.Text = string.format("%s   %s   v=%.0f   %s%s", tostring(n.kind or "npc"), tostring(n.name), v, tostring(n.status), route)
		row.Parent = holder
	end
end

local function rebuildNetList()
	local holder = _netHolder
	if not holder then return end
	for _, c in holder:GetChildren() do
		if c:IsA("TextLabel") then c:Destroy() end
	end
	local arr: { { nm: string, rate: number } } = {}
	for nm, rate in _netRateByName do
		table.insert(arr, { nm = nm, rate = rate })
	end
	table.sort(arr, function(a, b) return a.rate > b.rate end)
	for i = 1, math.min(12, #arr) do
		local e = arr[i]
		local row = Instance.new("TextLabel")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, 15)
		row.LayoutOrder = i
		row.FontFace = Theme.Font.Label
		row.TextSize = Theme.TextSize.XS
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.TextTruncate = Enum.TextTruncate.AtEnd
		row.TextColor3 = Theme.Color.TextSecondary
		row.Text = string.format("%s   %.0f/s", e.nm, e.rate)
		row.Parent = holder
	end
end

-- -------------------------------------------------------------------- log --

local function appendLogLabel(text: string, color: Color3)
	local holder = _logHolder
	if not holder then return end
	_logSeq += 1
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.Size = UDim2.new(1, 0, 0, 0)
	l.LayoutOrder = _logSeq
	l.FontFace = Theme.Font.Label
	l.TextSize = Theme.TextSize.XS
	l.TextWrapped = true
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Top
	l.TextColor3 = color
	l.Text = text
	l.Parent = holder
	table.insert(_logLabels, l)
	if #_logLabels > LOG_CAP then
		local old = table.remove(_logLabels, 1)
		if old then old:Destroy() end
	end
	holder.CanvasPosition = Vector2.new(0, 1e6)
end

local function rebuildLog()
	for _, l in _logLabels do l:Destroy() end
	table.clear(_logLabels)
	for _, e in _logEntries do
		appendLogLabel(e.text, e.color)
	end
end

local function pushLog(text: string, kind: Enum.MessageType)
	local color = if kind == Enum.MessageType.MessageError then Theme.Color.Danger
		elseif kind == Enum.MessageType.MessageWarning then Color3.fromRGB(230, 180, 90)
		else Theme.Color.TextSecondary
	table.insert(_logEntries, { text = text, color = color })
	if #_logEntries > LOG_CAP then
		table.remove(_logEntries, 1)
	end
	if _visible and _activeTab == "Log" then
		appendLogLabel(text, color)
	end
end

local function clearLog()
	for _, l in _logLabels do l:Destroy() end
	table.clear(_logLabels)
	table.clear(_logEntries)
end

-- ---------------------------------------------------------------- routes --
-- Draws the exact polylines NPCs follow: lane centrelines (GetEdges().points)
-- plus the intersection connector curves (GetConnectionPoints), colour-coded by
-- movement. Server-serialised on demand; drawn into a client-local folder so
-- only this admin sees them.

local function drawLine(folder: Folder, a: Vector3, b: Vector3, color: Color3, thickness: number)
	local len = (b - a).Magnitude
	if len < 0.05 then return end
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Size = Vector3.new(thickness, thickness, len)
	part.CFrame = CFrame.lookAt(a:Lerp(b, 0.5), b)
	part.Parent = folder
end

local function drawPolyline(folder: Folder, pts: { Vector3 }, color: Color3, thickness: number)
	for i = 1, #pts - 1 do
		if _routeParts >= MAX_PARTS then return end
		local a = pts[i] + Vector3.new(0, ROUTE_LIFT, 0)
		local b = pts[i + 1] + Vector3.new(0, ROUTE_LIFT, 0)
		drawLine(folder, a, b, color, thickness)
		_routeParts += 1
	end
end

local function clearRoutes()
	if _routesFolder then
		_routesFolder:Destroy()
		_routesFolder = nil
	end
	_routeParts = 0
	setv("r_lanes", "0")
	setv("r_turns", "0")
	setv("r_parking", "0")
	setv("r_parts", "0")
end

local function drawRoutes()
	if _routesBusy or not _net then return end
	_routesBusy = true
	task.spawn(function()
		local camPos: Vector3? = nil
		local radius: number? = nil
		if _routesNearOnly then
			local cam = Workspace.CurrentCamera
			if cam then
				camPos = cam.CFrame.Position
				radius = ROUTE_NEAR_RADIUS
			end
		end
		_lastDrawCamPos = camPos
		local ok, data = pcall(function()
			return _net.RequestNavRoutes:InvokeServer(camPos, radius)
		end)
		if _routesFolder then
			_routesFolder:Destroy()
			_routesFolder = nil
		end
		_routeParts = 0

		if not (ok and type(data) == "table") then
			_routesBusy = false
			return
		end

		local folder = Instance.new("Folder")
		folder.Name = "_AdminNavRoutes"
		folder.Parent = Workspace
		_routesFolder = folder

		local laneN, turnN, parkingN, built = 0, 0, 0, 0
		for _, line in (data.lanes or {}) do
			if not _routesOn or _routesFolder ~= folder then
				folder:Destroy()
				_routesBusy = false
				return
			end
			if _routeParts >= MAX_PARTS then break end
			drawPolyline(folder, line, LANE_COLOR, 0.15)
			laneN += 1
			built += 1
			if built % 400 == 0 then task.wait() end
		end
		for _, t in (data.turns or {}) do
			if not _routesOn or _routesFolder ~= folder then
				folder:Destroy()
				_routesBusy = false
				return
			end
			if _routeParts >= MAX_PARTS then break end
			drawPolyline(folder, t.p, MOVE_COLOR[t.m] or MOVE_COLOR.straight, 0.28)
			turnN += 1
			built += 1
			if built % 400 == 0 then task.wait() end
		end
		for _, p in (data.parking or {}) do
			if not _routesOn or _routesFolder ~= folder then
				folder:Destroy()
				_routesBusy = false
				return
			end
			if _routeParts >= MAX_PARTS then break end
			drawPolyline(folder, p, PARKING_COLOR, 0.2)
			parkingN += 1
			built += 1
			if built % 400 == 0 then task.wait() end
		end

		setv("r_lanes", tostring(laneN))
		setv("r_turns", tostring(turnN))
		setv("r_parking", tostring(parkingN))
		setv("r_parts", tostring(_routeParts) .. (if data.truncated then " (capped)" else ""))
		_routesBusy = false
	end)
end

local function toggleRoutes()
	_routesOn = not _routesOn
	if _routesShowBtn then _routesShowBtn:SetSelected(_routesOn) end
	if _routesOn then
		drawRoutes()
	else
		clearRoutes()
	end
end

local function markRoutesDirty()
	if _routesOn then
		_routesDirty = true
		_routesDirtyAt = os.clock()
	end
end

local function toggleNearOnly()
	_routesNearOnly = not _routesNearOnly
	if _routesNearBtn then _routesNearBtn:SetSelected(_routesNearOnly) end
	if _routesOn then drawRoutes() end
end

-- ----------------------------------------------------------- npc speeds --
-- A billboard over each in-range car: current speed + why it's at that speed
-- (cruise / slow / follow / turn / yield / stopped / standoff), from the
-- server's read-only NPCDriverService.GetSpeedDebug feed.

local function npcFolder(): Instance?
	local city = Workspace:FindFirstChild("_City")
	return city and city:FindFirstChild("NPCDrivers")
end

local function ensureBillboard(model: Model, key: string): BillboardGui?
	local existing = _speedBillboards[key]
	if existing and existing.Adornee and existing.Adornee:IsDescendantOf(model) then
		return existing
	end
	if existing then existing:Destroy() end

	local part = model.PrimaryPart or model:FindFirstChild("Hitbox") or model:FindFirstChildWhichIsA("BasePart")
	if not part then return nil end

	local bb = Instance.new("BillboardGui")
	bb.Name = "_AdminSpeed"
	bb.Adornee = part
	bb.Size = UDim2.fromOffset(96, 38)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 4.8, 0)
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0 -- stay readable regardless of time-of-day lighting
	bb.MaxDistance = 220  -- cut far-away clutter; only nearby cars show labels

	-- Dark rounded plate so text reads over neon routes / bright terrain.
	local bg = Instance.new("Frame")
	bg.Name = "BG"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(14, 14, 17)
	bg.BackgroundTransparency = 0.18
	bg.BorderSizePixel = 0
	bg.Parent = bb
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = bg
	local bgStroke = Instance.new("UIStroke")
	bgStroke.Color = Theme.Color.Stroke
	bgStroke.Thickness = 1
	bgStroke.Transparency = 0.2
	bgStroke.Parent = bg

	local s = Instance.new("TextLabel")
	s.Name = "S"
	s.BackgroundTransparency = 1
	s.Position = UDim2.fromScale(0, 0.04)
	s.Size = UDim2.new(1, 0, 0.56, 0)
	s.FontFace = Theme.Font.Bold
	s.TextSize = Theme.TextSize.MD
	s.TextColor3 = Theme.Color.TextPrimary
	s.Text = "0"
	s.Parent = bg

	local r = Instance.new("TextLabel")
	r.Name = "R"
	r.BackgroundTransparency = 1
	r.Position = UDim2.fromScale(0, 0.58)
	r.Size = UDim2.new(1, 0, 0.42, 0)
	r.FontFace = Theme.Font.Bold
	r.TextSize = Theme.TextSize.SM
	r.TextColor3 = Theme.Color.TextSecondary
	r.Text = ""
	r.Parent = bg

	bb.Parent = part
	_speedBillboards[key] = bb
	return bb
end

local function findSpeedModel(d: any): Model?
	local model = d.model
	if typeof(model) == "Instance" and model:IsA("Model") and model.Parent then
		return model
	end
	for _, inst in CollectionService:GetTagged("NPCDriver") do
		if inst:IsA("Model") then
			local debugId = inst:GetAttribute("NPCDebugId")
			if debugId == d.id or inst.Name == d.name then
				return inst
			end
		end
	end
	local folder = npcFolder()
	local fallback = folder and folder:FindFirstChild(tostring(d.name or d.id or ""))
	return if fallback and fallback:IsA("Model") then fallback else nil
end

local function syncSpeedBillboards()
	if not _speedsOn then return end

	for key, bb in _speedBillboards do
		local d = _speedData[key]
		local model = d and findSpeedModel(d)
		if not model then
			bb:Destroy()
			_speedBillboards[key] = nil
		end
	end

	for key, d in _speedData do
		local model = findSpeedModel(d)
		if model then
			local bb = ensureBillboard(model, key)
			if bb then
				local s = bb:FindFirstChild("S", true) :: TextLabel?
				local r = bb:FindFirstChild("R", true) :: TextLabel?
				if s then s.Text = tostring(d.speed) end
				if r then
					if d.reason == "cruise" then
						r.Text = ""
					else
						r.Text = SPEED_LABEL[d.reason] or d.reason
						r.TextColor3 = SPEED_COLOR[d.reason] or Theme.Color.TextSecondary
					end
				end
			end
		end
	end
end

local function clearSpeedLabels()
	for _, bb in _speedBillboards do bb:Destroy() end
	table.clear(_speedBillboards)
	table.clear(_speedData)
end

local function pollNpcSpeeds()
	if _speedsBusy or not _net then return end
	_speedsBusy = true
	task.spawn(function()
		local ok, data = pcall(function()
			return _net.RequestNpcSpeeds:InvokeServer()
		end)
		_speedsBusy = false
		if not (ok and type(data) == "table") then return end
		table.clear(_speedData)
		for _, e in data do
			if type(e) == "table" and (e.id or e.name) then
				local key = tostring(e.id or e.name)
				_speedData[key] = { id = key, model = e.model, name = e.name, speed = e.speed, reason = e.reason, limit = e.limit }
			end
		end
		syncSpeedBillboards()
	end)
end

local function toggleSpeeds()
	_speedsOn = not _speedsOn
	if _speedsBtn then _speedsBtn:SetSelected(_speedsOn) end
	if _speedsOn then
		pollNpcSpeeds()
	else
		clearSpeedLabels()
	end
end

local function setInspectorInfo(text: string, danger: boolean?)
	if _inspectorInfo then
		_inspectorInfo.Text = text
		_inspectorInfo.TextColor3 = if danger then Theme.Color.Danger else Theme.Color.TextSecondary
	end
end

local function clearInspectorVisuals()
	if _inspectorFolder then _inspectorFolder:Destroy(); _inspectorFolder = nil end
	if _inspectorHighlight then _inspectorHighlight:Destroy(); _inspectorHighlight = nil end
end

local function drawInspectorRoute(data: any)
	if _inspectorFolder then _inspectorFolder:Destroy() end
	local folder = Instance.new("Folder")
	folder.Name = "_AdminSelectedRoute"
	folder.Parent = Workspace
	_inspectorFolder = folder
	local route = if typeof(data) == "table" and typeof(data.routeDebug) == "table"
		then data.routeDebug else data
	local points = route and route.polyline
	if typeof(points) == "table" then
		for i = 1, math.min(#points - 1, 599) do
			local a, b = points[i], points[i + 1]
			if typeof(a) == "Vector3" and typeof(b) == "Vector3" then
				drawLine(folder, a + Vector3.new(0, 0.8, 0), b + Vector3.new(0, 0.8, 0), INSPECT_ROUTE_COLOR, 0.32)
			end
		end
	end
	local destination = data.destinationPos or (route and route.destination)
	if typeof(destination) == "Vector3" then
		local marker = Instance.new("Part")
		marker.Name = "Destination"
		marker.Shape = Enum.PartType.Ball
		marker.Size = Vector3.new(2.4, 2.4, 2.4)
		marker.Position = destination + Vector3.new(0, 1.5, 0)
		marker.Anchored = true
		marker.CanCollide = false
		marker.CanQuery = false
		marker.CanTouch = false
		marker.Material = Enum.Material.Neon
		marker.Color = INSPECT_TARGET_COLOR
		marker.Parent = folder
	end
end

local function inspectorText(data: any): string
	if data.kind == "adult" or data.kind == "kid" then
		local mode = data.modeDecision or {}
		local route = data.routeDebug or {}
		local scoreParts: { string } = {}
		if tonumber(mode.walkScore) then table.insert(scoreParts, string.format("walk %.1f", mode.walkScore)) end
		if tonumber(mode.driveScore) then table.insert(scoreParts, string.format("drive %.1f", mode.driveScore)) end
		if tonumber(mode.transitScore) then table.insert(scoreParts, string.format("transit %.1f", mode.transitScore)) end
		local scores = if #scoreParts > 0 then "\nScores: " .. table.concat(scoreParts, "  ") else ""
		local routeState = if route.status then "\nRoute: " .. tostring(route.status) else ""
		return string.format("%s  |  age %s  |  %s\nPurpose: %s\nMode: %s%s%s\nWhy mode: %s",
			tostring(data.name or "Citizen"), tostring(data.age or "?"), tostring(data.stage or "?"),
			tostring(data.purpose or "No active destination"),
			tostring(mode.chosen or "settled"), scores, routeState,
			tostring(mode.reason or route.reason or "No active trip."))
	end
	local owner = if data.ownerName then "  |  " .. tostring(data.ownerName) else ""
	local purpose = if data.purpose then "\nPurpose: " .. tostring(data.purpose) else ""
	local modeWhy = if data.modeDecision and data.modeDecision.reason then "\nWhy mode: " .. tostring(data.modeDecision.reason) else ""
	return string.format("%s  |  %s%s%s\nSpeed %.1f  |  %s  |  congestion %.0f%%\nRoute %s/%s  |  reroutes %s\nWhy route: %s%s",
		tostring(data.name or "Vehicle"), tostring(data.kind or "vehicle"), owner, purpose,
		tonumber(data.speed) or 0, tostring(data.stopReason or "moving"),
		(tonumber(data.congestion) or 0) * 100,
		tostring(data.routeIndex or "-"), tostring(data.routeLength or "-"),
		tostring(data.trafficReroutes or 0), tostring(data.reason or "No route explanation."), modeWhy)
end

local function closestInspectable(screenPos: Vector2): (Model?, string?)
	local camera = Workspace.CurrentCamera
	if not camera then return nil, nil end
	local bestModel, bestKind, bestDist = nil, nil, 42
	local function consider(inst: Instance, kind: string)
		if not inst:IsA("Model") or not inst.Parent then return end
		local root = inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart")
		if not root then return end
		local projected, visible = camera:WorldToViewportPoint(root.Position)
		if not visible or projected.Z <= 0 then return end
		local distance = (Vector2.new(projected.X, projected.Y) - screenPos).Magnitude
		if distance < bestDist then
			bestDist, bestModel, bestKind = distance, inst, kind
		end
	end
	for _, inst in CollectionService:GetTagged("NPCDriver") do consider(inst, "vehicle") end
	for _, inst in CollectionService:GetTagged("AdminCitizen") do consider(inst, "citizen") end
	return bestModel, bestKind
end

local function inspectAt(screenPos: Vector2)
	if not _inspectorOn or _inspectorBusy or not _net then return end
	local model, kind = closestInspectable(screenPos)
	if not model or not kind then
		setInspectorInfo("No vehicle or visible citizen under the cursor.", true)
		return
	end
	local payload: any
	if kind == "vehicle" then
		payload = { kind = "vehicle", model = model }
	else
		local pid = model:GetAttribute("CitizenPid")
		if typeof(pid) ~= "number" then
			setInspectorInfo("Citizen has no debug identity.", true)
			return
		end
		payload = { kind = "citizen", pid = pid }
	end

	clearInspectorVisuals()
	local highlight = Instance.new("Highlight")
	highlight.Name = "_AdminSelected"
	highlight.Adornee = model
	highlight.FillColor = INSPECT_ROUTE_COLOR
	highlight.FillTransparency = 0.75
	highlight.OutlineColor = Color3.new(1, 1, 1)
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Parent = model
	_inspectorHighlight = highlight
	setInspectorInfo("Inspecting " .. model.Name .. "...", false)
	_inspectorBusy = true
	task.spawn(function()
		local ok, data = pcall(function() return _net.RequestAdminInspect:InvokeServer(payload) end)
		_inspectorBusy = false
		if not _inspectorOn then return end
		if not ok or typeof(data) ~= "table" or data.ok == false then
			local err = if typeof(data) == "table" then data.error else data
			setInspectorInfo(tostring(err or "Inspection failed."), true)
			return
		end
		drawInspectorRoute(data)
		setInspectorInfo(inspectorText(data), false)
	end)
end

local function toggleInspector()
	_inspectorOn = not _inspectorOn
	if _inspectorBtn then _inspectorBtn:SetSelected(_inspectorOn) end
	if _inspectorOn then
		setInspectorInfo("Click a visible vehicle or citizen to inspect its destination, route, and decision.", false)
	else
		clearInspectorVisuals()
		setInspectorInfo("Route inspector is off.", false)
	end
end

-- --------------------------------------------------------- admin saves --

local function setSaveStatus(text: string, danger: boolean?)
	_saveStatusPermanent = text
	_saveStatusDanger = danger == true
	local label = _saveStatus
	if not label then return end
	label.Text = text
	label.TextColor3 = if danger then Theme.Color.Danger else Theme.Color.TextSecondary
end

local function clearSaveRows()
	local holder = _saveHolder
	if not holder then return end
	for _, child in holder:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local function saveDate(ts: any): string
	if typeof(ts) ~= "number" or ts <= 0 then return "never" end
	local ok, text = pcall(function()
		return os.date("%m/%d %H:%M", ts)
	end)
	return if ok and typeof(text) == "string" then text else "saved"
end

local function playerButtonText(row: any): string
	local saves = if typeof(row.saveCount) == "number" then tostring(row.saveCount) else "?"
	return string.format("%s  |  %s saves", tostring(row.name or row.userId), saves)
end

local function slotButtonText(slot: any): string
	local name = tostring(slot.cityName or ("Slot " .. tostring(slot.slotId or "?")))
	local pop = if typeof(slot.population) == "number" then tostring(slot.population) else "0"
	return string.format("Slot %s  |  %s  |  pop %s  |  %s", tostring(slot.slotId or "?"), name, pop, saveDate(slot.lastPlayedTimestamp))
end

local function addSaveButton(text: string, order: number, onClick: () -> ()): any
	local holder = _saveHolder
	if not holder then return nil end
	local btn = Button.new({
		text = text,
		compact = true,
		size = UDim2.new(1, -6, 0, 28),
		parent = holder,
		layoutOrder = order,
		onClick = onClick,
	})
	btn.Instance.TextXAlignment = Enum.TextXAlignment.Left
	btn.Instance.TextTruncate = Enum.TextTruncate.AtEnd
	return btn
end

local function loadAdminCopy(sourceQuery: any, slotId: number)
	if _saveBusy or not _net then return end
	_saveBusy = true
	setSaveStatus("Loading read-only copy...", false)
	UIEvents.AdminCityLoadStarted:Fire({ sourceQuery = sourceQuery, slotId = slotId })
	task.spawn(function()
		local ok, res = pcall(function()
			return _net.RequestAdminLoadSaveCopy:InvokeServer(sourceQuery, slotId)
		end)
		_saveBusy = false
		if ok and typeof(res) == "table" and res.ok == true then
			if res.accepted == true then
				setSaveStatus("Loading copy: " .. tostring(res.cityName or "city") .. "...", false)
			else
				setSaveStatus("Loaded copy: " .. tostring(res.cityName or "city") .. " (read-only until copied to your saves)", false)
			end
		else
			local err = if ok and typeof(res) == "table" then res.error else res
			local message = tostring(err or "Load failed.")
			setSaveStatus(message, true)
			UIEvents.AdminCityLoadFailed:Fire(message)
		end
	end)
end

local requestAdminSaves: (any?) -> () = function() end

local function allSaveButtonText(row: any): string
	local name = tostring(row.name or row.userId)
	local cityName = tostring(row.cityName or ("Slot " .. tostring(row.slotId or "?")))
	local pop = if typeof(row.population) == "number" then tostring(row.population) else "0"
	local onlineMark = if row.online == true then " ●" else ""
	return string.format("%s%s  |  Slot %s  |  %s  |  pop %s  |  %s",
		name, onlineMark, tostring(row.slotId or "?"), cityName, pop, saveDate(row.lastPlayedTimestamp))
end

-- ---------------------------------------------------------------- cities --
-- Reach any player's city to moderate it. Who is online right now across EVERY server (the
-- shared directory PlayerDirectoryService keeps), split into friends and everyone else, plus
-- a name box for anyone who is not online at all.
--
-- VISIT arrives able to look; BUILD arrives able to build. Neither is a permission: the
-- server re-checks that the caller is staff before it sends anybody anywhere, and the mode
-- can only ever take rights AWAY from someone already confirmed.

local _citiesHolder: ScrollingFrame? = nil
local _citiesStatus: TextLabel? = nil
local _citiesQuery: TextBox? = nil
local _citiesBusy = false
-- The viewer's own friends, fetched once from the client. Used only to decide which half of
-- the list a row belongs in, so a failed fetch costs a grouping rather than the feature.
local _friendIds: { [number]: boolean }? = nil

local function setCitiesStatus(text: string, danger: boolean?)
	local label = _citiesStatus
	if not label then return end
	label.Text = text
	label.TextColor3 = if danger then Theme.Color.Danger else Theme.Color.TextSecondary
end

local function friendIds(): { [number]: boolean }
	local cached = _friendIds
	if cached then return cached end
	local ids: { [number]: boolean } = {}
	local ok, pages = pcall(function()
		return Players:GetFriendsAsync(LocalPlayer.UserId)
	end)
	if ok and pages then
		for _ = 1, 2 do
			for _, entry in pages:GetCurrentPage() do
				local id = tonumber(entry.Id)
				if id then ids[id] = true end
			end
			if pages.IsFinished then break end
			if not pcall(function() pages:AdvanceToNextPageAsync() end) then break end
		end
	end
	_friendIds = ids
	return ids
end

local function clearCityRows()
	local holder = _citiesHolder
	if not holder then return end
	for _, child in holder:GetChildren() do
		if child:IsA("GuiObject") then child:Destroy() end
	end
end

local function joinCity(ownerId: number, slotId: number, mode: string)
	if _citiesBusy or not _net then return end
	_citiesBusy = true
	setCitiesStatus("Joining as " .. mode .. "...", false)
	-- The same remote a player uses to open their own city: the server decides whether this
	-- caller may go where they asked. The panel only asks.
	_net.RequestLoadSlot:FireServer(slotId, ownerId, mode)
	-- Released on a timer rather than on a reply: a successful join is a teleport, and the
	-- reply never arrives because this client is already gone.
	task.delay(6, function() _citiesBusy = false end)
end

local function addCityRow(order: number, title: string, subtitle: string, ownerId: number?, slotId: number?)
	local holder = _citiesHolder
	if not holder then return end

	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, -6, 0, 30)
	row.LayoutOrder = order
	row.Parent = holder

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, -140, 1, 0)
	label.FontFace = Theme.Font.Label
	label.TextSize = Theme.TextSize.SM
	label.TextColor3 = Theme.Color.TextPrimary
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Text = title .. "   " .. subtitle
	label.Parent = row

	-- Nothing to join: the row still earns its place by saying where they are.
	if not ownerId or not slotId then return end

	local strip = Instance.new("Frame")
	strip.BackgroundTransparency = 1
	strip.AnchorPoint = Vector2.new(1, 0.5)
	strip.Position = UDim2.new(1, 0, 0.5, 0)
	strip.Size = UDim2.fromOffset(134, 26)
	strip.Parent = row
	local strut = Instance.new("UIListLayout")
	strut.FillDirection = Enum.FillDirection.Horizontal
	strut.HorizontalAlignment = Enum.HorizontalAlignment.Right
	strut.VerticalAlignment = Enum.VerticalAlignment.Center
	strut.Padding = UDim.new(0, 4)
	strut.Parent = strip

	Button.new({
		text = "VISIT", compact = true, size = UDim2.fromOffset(62, 24),
		parent = strip, layoutOrder = 1,
		onClick = function() joinCity(ownerId, slotId, "visitor") end,
	})
	Button.new({
		text = "BUILD", compact = true, size = UDim2.fromOffset(62, 24),
		parent = strip, layoutOrder = 2,
		onClick = function() joinCity(ownerId, slotId, "builder") end,
	})
end

local function renderOnline(rows: { any })
	clearCityRows()
	local holder = _citiesHolder
	if not holder then return end

	local friends = friendIds()
	local mine, others = {}, {}
	for _, row in rows do
		if typeof(row) ~= "table" or row.userId == LocalPlayer.UserId then continue end
		if friends[row.userId] then
			table.insert(mine, row)
		else
			table.insert(others, row)
		end
	end

	local order = 0
	local function section(title: string, list: { any })
		order += 1
		sectionLabel(holder, title .. " (" .. tostring(#list) .. ")", order)
		for _, row in list do
			order += 1
			local where = if row.cityName
				then tostring(row.cityName) .. "  \u{00B7}  pop " .. tostring(row.pop or 0)
				else "\u{2014} in the menu \u{2014}"
			addCityRow(order, tostring(row.display), where, tonumber(row.ownerId), tonumber(row.slotId))
		end
	end

	section("Friends online", mine)
	section("Everyone online", others)
	setCitiesStatus(tostring(#mine + #others) .. " online", false)
end

local function refreshCities()
	if not _net then return end
	setCitiesStatus("Reading who is online...", false)
	task.spawn(function()
		local ok, res = pcall(function()
			return _net.RequestOnlinePlayers:InvokeServer()
		end)
		if ok and typeof(res) == "table" and res.ok == true and typeof(res.rows) == "table" then
			renderOnline(res.rows)
		else
			local err = if ok and typeof(res) == "table" then res.error else res
			setCitiesStatus(tostring(err or "Could not read the online list."), true)
		end
	end)
end

-- Anyone at all, online or not: the admin saves lookup already resolves a username to that
-- player's city list, so finding someone offline needs no second way of asking.
local function findCities(query: string)
	if not _net then return end
	if #query == 0 then
		refreshCities()
		return
	end
	setCitiesStatus("Looking up " .. query .. "...", false)
	task.spawn(function()
		local ok, res = pcall(function()
			return _net.RequestAdminPlayerSaves:InvokeServer(query)
		end)
		if not (ok and typeof(res) == "table" and res.ok == true) then
			local err = if ok and typeof(res) == "table" then res.error else res
			setCitiesStatus(tostring(err or "Could not find that player."), true)
			return
		end
		clearCityRows()
		local holder = _citiesHolder
		if not holder then return end
		local ownerId = tonumber(res.userId)
		local slots = if typeof(res.slots) == "table" then res.slots else {}
		sectionLabel(holder, tostring(res.playerName or query) .. " (" .. tostring(#slots) .. " cities)", 1)
		local order = 1
		for _, slot in slots do
			order += 1
			local pop = if typeof(slot.population) == "number" then tostring(slot.population) else "0"
			addCityRow(order,
				tostring(slot.cityName or ("Slot " .. tostring(slot.slotId))),
				"pop " .. pop .. "  \u{00B7}  " .. saveDate(slot.lastPlayedTimestamp),
				ownerId, tonumber(slot.slotId))
		end
		setCitiesStatus(if #slots == 0 then "No cities on that account." else "", false)
	end)
end

local function renderSaveResponse(data: any, query: any)
	clearSaveRows()
	if not (typeof(data) == "table" and data.ok == true) then
		local err = if typeof(data) == "table" then data.error else "Lookup failed."
		setSaveStatus(tostring(err), true)
		return
	end

	-- All-saves listing (blank query)
	if typeof(data.allSaves) == "table" then
		local all = data.allSaves
		setSaveStatus(string.format("%d save(s) across all players.", #all), false)
		for i, row in all do
			local slotId = tonumber(row.slotId)
			local userId = tonumber(row.userId)
			if slotId and userId then
				local btn = addSaveButton(allSaveButtonText(row), i, function()
					loadAdminCopy(userId, slotId)
				end)
				-- Hover shows userId; leaving restores the count label.
				if btn and btn.Instance then
					local uid = userId
					btn.Instance.MouseEnter:Connect(function()
						local label = _saveStatus
						if label then
							label.Text = "UserId: " .. tostring(uid)
							label.TextColor3 = Theme.Color.TextSecondary
						end
					end)
					btn.Instance.MouseLeave:Connect(function()
						local label = _saveStatus
						if label then
							label.Text = _saveStatusPermanent
							label.TextColor3 = if _saveStatusDanger then Theme.Color.Danger else Theme.Color.TextSecondary
						end
					end)
				end
			end
		end
		return
	end

	-- Single-player slot listing (query matched a player)
	local slots = if typeof(data.slots) == "table" then data.slots else {}
	if data.userId ~= nil then
		setSaveStatus(string.format("Player %s has %d save(s).", tostring(data.playerName or data.userId), tonumber(data.saveCount) or #slots), false)
		if #slots == 0 then return end
		for i, slot in slots do
			local slotId = tonumber(slot.slotId)
			if slotId then
				addSaveButton(slotButtonText(slot), i, function()
					loadAdminCopy(data.userId, slotId)
				end)
			end
		end
		return
	end
end

requestAdminSaves = function(query: any?)
	if _saveBusy or not _net then return end
	_saveBusy = true
	_saveLastQuery = query or ""
	setSaveStatus("Loading saves...", false)
	task.spawn(function()
		local ok, data = pcall(function()
			return _net.RequestAdminPlayerSaves:InvokeServer(_saveLastQuery)
		end)
		_saveBusy = false
		if ok then
			renderSaveResponse(data, _saveLastQuery)
		else
			clearSaveRows()
			setSaveStatus(tostring(data or "Lookup failed."), true)
		end
	end)
end

-- ------------------------------------------------------------ tabs / show --

local function selectTab(name: string)
	if not tabVisible(name) then return end
	_activeTab = name
	for key, page in _pages do
		page.Visible = (key == name)
	end
	for key, handle in _tabs do
		handle:SetSelected(key == name)
	end
	if name == "NPCs" then
		rebuildNpcList()
	elseif name == "Log" then
		rebuildLog()
	elseif name == "Net" then
		rebuildNetList()
	elseif name == "Cities" then
		refreshCities()
	elseif name == "Saves" then
		if _saveQuery then _saveQuery.Text = "" end
		requestAdminSaves("")
	end
end

local function setVisible(v: boolean)
	if _visible == v then return end
	_visible = v
	if _root then _root.Visible = v end
	-- Hiding the panel stops the Review preview orbiting. The page's own Visible does not
	-- change when the root hides, so the watcher on it never fires for this path.
	if not v and _clearReviewPreview then _clearReviewPreview() end
	if v then
		local ok, developer = pcall(function()
			return require(script.Parent:WaitForChild("DeveloperController"))
		end)
		if ok and developer and developer.SetVisible then
			developer.SetVisible(false)
		end
	end
	if _gui then
		local developerRoot = _gui:FindFirstChild("DeveloperRoot")
		local developerVisible = developerRoot ~= nil and (developerRoot :: GuiObject).Visible
		local launcher = _gui:FindFirstChild("Launcher")
		_gui.Enabled = true
		if launcher and launcher:IsA("GuiObject") then
			launcher.Visible = not v and not developerVisible
		end
	end
	if _net then
		_net.ToggleDebugMode:FireServer(v)
	end
	if v then
		pollServer()
		updateText()
	end
end

-- --------------------------------------------------------------- build ui --

-- Keeps the launcher pill's anchor point (its top-right corner, since
-- AnchorPoint = (1,0)) fully on screen given the current viewport size.
local function clampLauncherOffset(x: number, y: number): (number, number)
	local camera = Workspace.CurrentCamera
	local viewport = if camera then camera.ViewportSize else Vector2.new(1280, 720)
	local minX = LAUNCHER_W - viewport.X
	local maxY = math.max(0, viewport.Y - LAUNCHER_H)
	return math.clamp(x, minX, 0), math.clamp(y, 0, maxY)
end

-- Drag-to-move for the launcher pill itself (it has no separate header, so the
-- button is both the handle and the thing being moved). Distinguishes a real
-- drag from a click so opening the panel still works normally; calls onDragEnd
-- with the final (clamped) offset only when something actually moved.
local function attachLauncherDrag(btn: GuiObject, onDragEnd: (number, number) -> ())
	local dragging = false
	local dragged = false
	local dragStart = Vector2.zero
	local startOffset = Vector2.new(btn.Position.X.Offset, btn.Position.Y.Offset)

	table.insert(_conns, btn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragged = false
			dragStart = input.Position
			startOffset = Vector2.new(btn.Position.X.Offset, btn.Position.Y.Offset)
		end
	end))

	table.insert(_conns, UserInputService.InputChanged:Connect(function(input)
		if not dragging then return end
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			local d = input.Position - dragStart
			if not dragged and d.Magnitude > DRAG_CLICK_THRESHOLD then
				dragged = true
			end
			local x, y = clampLauncherOffset(startOffset.X + d.X, startOffset.Y + d.Y)
			btn.Position = UDim2.new(1, x, 0, y)
		end
	end))

	table.insert(_conns, UserInputService.InputEnded:Connect(function(input)
		if not dragging then return end
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
			if dragged then
				onDragEnd(btn.Position.X.Offset, btn.Position.Y.Offset)
			end
		end
	end))

	return function(): boolean
		return dragged
	end
end

local function attachDrag(handle: GuiObject, target: Frame)
	local dragging = false
	local dragStart = Vector2.zero
	local startPos = target.Position
	table.insert(_conns, handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = target.Position
		end
	end))
	table.insert(_conns, UserInputService.InputChanged:Connect(function(input)
		if not dragging then return end
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			local d = input.Position - dragStart
			target.Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + d.X,
				startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end))
	table.insert(_conns, UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
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
		gui.DisplayOrder = Theme.Layer.Dev + 2
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.Enabled = true
		gui.Parent = playerGui
	end
	_gui = gui

	local launcher = Button.new({
		text = "STAFF  F4",
		compact = true,
		parent = gui,
		onClick = function()
			if _launcherWasDragged() then return end
			setVisible(true)
		end,
	})
	launcher.Instance.Name = "Launcher"
	launcher.Instance.AnchorPoint = Vector2.new(1, 0)
	launcher.Instance.Position = UDim2.new(1, -PANEL_MARGIN, 0, PANEL_MARGIN)
	launcher.Instance.Size = UDim2.fromOffset(LAUNCHER_W, LAUNCHER_H)
	launcher.Instance.ZIndex = 20

	_launcherWasDragged = attachLauncherDrag(launcher.Instance, function(x: number, y: number)
		if _net then
			_net.SaveStaffLauncherPos:FireServer({ x = x, y = y })
		end
	end)

	-- Restore a previously-saved drag position, if any. Runs async so a slow/failed
	-- fetch never blocks panel construction; the pill just stays at its default spot.
	if _net then
		task.spawn(function()
			local ok, saved = pcall(function()
				return _net.RequestStaffLauncherPos:InvokeServer()
			end)
			if ok and typeof(saved) == "table" and typeof(saved.x) == "number" and typeof(saved.y) == "number" then
				local x, y = clampLauncherOffset(saved.x, saved.y)
				launcher.Instance.Position = UDim2.new(1, x, 0, y)
			end
		end)
	end

	local root = Instance.new("Frame")
	root.Name = "AdminRoot"
	root.Visible = false
	root.AnchorPoint = Vector2.new(1, 0)
	root.Position = UDim2.new(1, -PANEL_MARGIN, 0, PANEL_MARGIN)
	root.Size = UDim2.new(1, -(PANEL_MARGIN * 2), 0, PANEL_H)
	local rootLimit = Instance.new("UISizeConstraint")
	rootLimit.MaxSize = Vector2.new(PANEL_MAX_W, PANEL_H)
	rootLimit.Parent = root
	Glass.apply(root, Theme.Radius.LG)
	-- Near-opaque: the world bleeding through the glass makes small text look outlined.
	root.BackgroundTransparency = 0.04
	root.Parent = gui
	_root = root

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, Theme.Pad.LG)
	pad.PaddingBottom = UDim.new(0, Theme.Pad.LG)
	pad.PaddingLeft = UDim.new(0, Theme.Pad.LG)
	pad.PaddingRight = UDim.new(0, Theme.Pad.LG)
	pad.Parent = root

	-- header (drag handle)
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 26)
	header.Parent = root

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -132, 1, 0)
	title.FontFace = Theme.Font.Bold
	title.TextSize = Theme.TextSize.MD
	title.TextColor3 = Theme.Color.TextPrimary
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "STAFF \u{00B7} " .. string.upper(_tier)
	title.Parent = header
	_title = title

	if tierAllows("admin") then
		local developerMode = Button.new({
			text = "DEVELOPER",
			compact = true,
			parent = header,
			onClick = function()
				local developer = require(script.Parent:WaitForChild("DeveloperController"))
				setVisible(false)
				developer.SetVisible(true)
			end,
		})
		developerMode.Instance.AnchorPoint = Vector2.new(1, 0.5)
		developerMode.Instance.Position = UDim2.new(1, -30, 0.5, 0)
		developerMode.Instance.Size = UDim2.fromOffset(92, 22)
	end

	local close = IconButton.new({
		icon = Icons.Close,
		size = 24,
		tooltip = "Close (F4)",
		parent = header,
		onClick = function() setVisible(false) end,
	})
	close.Instance.AnchorPoint = Vector2.new(1, 0.5)
	close.Instance.Position = UDim2.fromScale(1, 0.5)

	attachDrag(header, root)

	-- tab strip
	local strip = Instance.new("Frame")
	strip.Name = "Tabs"
	strip.BackgroundTransparency = 1
	strip.Position = UDim2.new(0, 0, 0, 32)
	strip.Size = UDim2.new(1, 0, 0, 24)
	strip.Parent = root
	local stripList = Instance.new("UIListLayout")
	stripList.FillDirection = Enum.FillDirection.Horizontal
	stripList.SortOrder = Enum.SortOrder.LayoutOrder
	stripList.VerticalAlignment = Enum.VerticalAlignment.Center
	stripList.Padding = UDim.new(0, 2)
	stripList.Parent = strip

	local divider = Instance.new("Frame")
	divider.BorderSizePixel = 0
	divider.BackgroundColor3 = Theme.Color.StrokeSoft
	divider.Position = UDim2.new(0, 0, 0, 58)
	divider.Size = UDim2.new(1, 0, 0, 1)
	divider.Parent = root

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Position = UDim2.new(0, 0, 0, 64)
	content.Size = UDim2.new(1, 0, 1, -64)
	content.ClipsDescendants = true
	content.Parent = root

	for i, name in TAB_ORDER do
		if tabVisible(name) then
			local handle = Tab.new({
				text = name,
				parent = strip,
				layoutOrder = i,
				onClick = function()
					selectTab(name)
					-- Pages that hold server state refresh on open rather than polling in
					-- the background. Registered after this loop, which is fine: the table
					-- is captured by reference and only read on click.
					local opened = _tabOpened[name]
					if opened then opened() end
				end,
			})
			_tabs[name] = handle
		end
	end

	-- Debug page
	local debugPage = Instance.new("Frame")
	debugPage.Name = "Debug"
	debugPage.BackgroundTransparency = 1
	debugPage.Size = UDim2.fromScale(1, 1)
	debugPage.Visible = false
	debugPage.Parent = content
	_pages.Debug = debugPage

	local debugScroll = scroller(debugPage, 0)

	local function addDebugBtn(label: string, order: number, onClick: () -> ())
		local btn = Button.new({
			text = label,
			compact = true,
			size = UDim2.new(1, -6, 0, 28),
			parent = debugScroll,
			layoutOrder = order,
			onClick = onClick,
		})
		btn.Instance.TextXAlignment = Enum.TextXAlignment.Left
		return btn
	end

	sectionLabel(debugScroll, "Server", 1)
	addDebugBtn("Reload terrain chunks", 2, function()
		if not _net then return end
		task.spawn(function()
			local ok, res = pcall(function() return _net.RequestServerDebugAction:InvokeServer("reloadTerrain") end)
			print("[Admin:Debug] reloadTerrain", ok, res)
		end)
	end)
	addDebugBtn("Force autosave", 3, function()
		if not _net then return end
		task.spawn(function()
			local ok, res = pcall(function() return _net.RequestServerDebugAction:InvokeServer("forceAutosave") end)
			print("[Admin:Debug] forceAutosave", ok, res)
		end)
	end)
	addDebugBtn("Flush NPC pool", 4, function()
		if not _net then return end
		task.spawn(function()
			local ok, res = pcall(function() return _net.RequestServerDebugAction:InvokeServer("flushNpcPool") end)
			print("[Admin:Debug] flushNpcPool", ok, res)
		end)
	end)
	sectionLabel(debugScroll, "Client", 5)
	addDebugBtn("Dump Workspace hierarchy (console)", 6, function()
		local function dump(inst: Instance, depth: number)
			if depth > 4 then return end
			print(string.rep("  ", depth) .. inst.Name .. " [" .. inst.ClassName .. "]")
			for _, c in inst:GetChildren() do dump(c, depth + 1) end
		end
		dump(game:GetService("Workspace"), 0)
	end)
	addDebugBtn("Print terrain overlay corners (console)", 7, function()
		if not _net then return end
		task.spawn(function()
			local ok, res = pcall(function() return _net.RequestServerDebugAction:InvokeServer("terrainOverlayStats") end)
			print("[Admin:Debug] terrainOverlayStats", ok, res)
		end)
	end)
	addDebugBtn("Toggle FPS counter", 8, function()
		local statsGui = game:GetService("Players").LocalPlayer:FindFirstChild("PlayerGui")
		if not statsGui then return end
		local existing = statsGui:FindFirstChild("_AdminFPS")
		if existing then
			existing:Destroy()
			return
		end
		local sg = Instance.new("ScreenGui")
		sg.Name = "_AdminFPS"
		sg.ResetOnSpawn = false
		sg.DisplayOrder = Theme.Layer.Dev + 1
		sg.Parent = statsGui
		local lbl = Instance.new("TextLabel")
		lbl.BackgroundTransparency = 0.4
		lbl.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		lbl.Size = UDim2.fromOffset(90, 22)
		lbl.Position = UDim2.new(0, 6, 0, 6)
		lbl.FontFace = Theme.Font.Bold
		lbl.TextSize = Theme.TextSize.SM
		lbl.TextColor3 = Color3.fromRGB(80, 230, 130)
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.Text = "FPS: …"
		lbl.Parent = sg
		RunService.RenderStepped:Connect(function()
			if not lbl.Parent then return end
			lbl.Text = string.format("FPS: %.0f", 1 / RunService.RenderStepped:Wait())
		end)
	end)

	sectionLabel(debugScroll, "Fun", 9)
	-- Takes the camera to a grass field above the map and plays Bad Apple by paving it.
	-- The button owns its own label because the show can also end on its own (the video
	-- runs out, or Esc).
	local badAppleBtn
	local function badAppleLabel()
		badAppleBtn.Instance.Text = if BadAppleShow.IsPlaying()
			then "Stop Bad Apple"
			else "Play Bad Apple"
	end
	local badAppleStatus = Instance.new("TextLabel")
	badAppleStatus.Name = "BadAppleStatus"
	badAppleStatus.BackgroundTransparency = 1
	badAppleStatus.Size = UDim2.new(1, -6, 0, 30)
	badAppleStatus.LayoutOrder = 11
	badAppleStatus.FontFace = Theme.Font.Label
	badAppleStatus.TextSize = Theme.TextSize.XS
	badAppleStatus.TextColor3 = Theme.Color.TextSecondary
	badAppleStatus.TextXAlignment = Enum.TextXAlignment.Left
	badAppleStatus.TextYAlignment = Enum.TextYAlignment.Top
	badAppleStatus.TextWrapped = true
	badAppleStatus.Text = ""
	badAppleStatus.Parent = debugScroll

	badAppleBtn = addDebugBtn("Play Bad Apple", 10, function()
		BadAppleShow.Toggle(function(text: string, danger: boolean?)
			badAppleLabel()
			badAppleStatus.Text = text
			badAppleStatus.TextColor3 = if danger then Theme.Color.Danger else Theme.Color.TextSecondary
		end)
		badAppleLabel()
	end)

	-- Tools page
	local tools = listPage("Tools")
	tools.Parent = content
	_pages.Tools = tools

	local function toolRow(order: number): Frame
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, -6, 0, 30)
		row.LayoutOrder = order
		row.Parent = tools
		local list = Instance.new("UIListLayout")
		list.FillDirection = Enum.FillDirection.Horizontal
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.VerticalAlignment = Enum.VerticalAlignment.Center
		list.Padding = UDim.new(0, Theme.Pad.SM)
		list.Parent = row
		return row
	end

	local function toolInput(row: Frame, name: string, text: string, order: number): TextBox
		local box = Instance.new("TextBox")
		box.Name = name
		box.BackgroundColor3 = Theme.Color.BgRaised
		box.BorderSizePixel = 0
		box.Size = UDim2.new(1, -150, 1, 0)
		box.FontFace = Theme.Font.Label
		box.TextSize = Theme.TextSize.SM
		box.TextColor3 = Theme.Color.TextPrimary
		box.PlaceholderColor3 = Theme.Color.TextSecondary
		box.TextXAlignment = Enum.TextXAlignment.Left
		box.ClearTextOnFocus = false
		box.Text = text
		box.LayoutOrder = order
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 6)
		pad.PaddingRight = UDim.new(0, 6)
		pad.Parent = box
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 4)
		corner.Parent = box
		box.Parent = row
		return box
	end

	local toolsStatus = Instance.new("TextLabel")
	toolsStatus.Name = "Status"
	toolsStatus.BackgroundTransparency = 1
	toolsStatus.Size = UDim2.new(1, -6, 0, 34)
	toolsStatus.LayoutOrder = 100
	toolsStatus.FontFace = Theme.Font.Label
	toolsStatus.TextSize = Theme.TextSize.XS
	toolsStatus.TextColor3 = Theme.Color.TextSecondary
	toolsStatus.TextXAlignment = Enum.TextXAlignment.Left
	toolsStatus.TextYAlignment = Enum.TextYAlignment.Top
	toolsStatus.TextWrapped = true
	toolsStatus.Text = "Ready."
	toolsStatus.Parent = tools

	local function setToolsStatus(text: string, danger: boolean?)
		toolsStatus.Text = text
		toolsStatus.TextColor3 = if danger then Theme.Color.Danger else Theme.Color.TextSecondary
	end

	sectionLabel(tools, "Money", 1)
	local moneyRow = toolRow(2)
	local moneyAmount = toolInput(moneyRow, "MoneyAmount", "50000", 1)
	Button.new({
		text = "Add money",
		compact = true,
		size = UDim2.new(0, 136, 1, 0),
		parent = moneyRow,
		layoutOrder = 2,
		onClick = function()
			if not _net or not _net.RequestAdminAddMoney then
				setToolsStatus("Money remote missing.", true)
				return
			end
			local amount = tonumber(moneyAmount.Text)
			if not amount then
				setToolsStatus("Enter a money amount.", true)
				return
			end
			setToolsStatus("Adding money...", false)
			task.spawn(function()
				local ok, res = pcall(function()
					return _net.RequestAdminAddMoney:InvokeServer(amount)
				end)
				if not ok then
					setToolsStatus(tostring(res or "Add money failed."), true)
					return
				end
				if typeof(res) == "table" and res.ok == true then
					local granted = tonumber(res.amount) or amount
					local money = tonumber(res.money)
					local suffix = if money then string.format(" Treasury: %.0f.", money) else ""
					setToolsStatus(string.format("Added %.0f.%s", granted, suffix), false)
				else
					local err = if typeof(res) == "table" then res.error else nil
					setToolsStatus(tostring(err or res or "Add money failed."), true)
				end
			end)
		end,
	})

	sectionLabel(tools, "Traffic", 3)
	local countRow = toolRow(4)
	local carCount = toolInput(countRow, "CarCount", "12", 1)
	local radiusBox: TextBox? = nil
	Button.new({
		text = "Spawn near camera",
		compact = true,
		size = UDim2.new(0, 136, 1, 0),
		parent = countRow,
		layoutOrder = 2,
		onClick = function()
			if not _net or not _net.RequestAdminSpawnTraffic then
				setToolsStatus("Traffic remote missing.", true)
				return
			end
			local cam = Workspace.CurrentCamera
			local payload = {
				count = tonumber(carCount.Text) or 12,
				near = if cam then cam.CFrame.Position else nil,
				radius = if radiusBox then tonumber(radiusBox.Text) or 260 else 260,
			}
			setToolsStatus("Spawning cars...", false)
			task.spawn(function()
				local ok, res = pcall(function()
					return _net.RequestAdminSpawnTraffic:InvokeServer(payload)
				end)
				if not ok then
					setToolsStatus(tostring(res or "Spawn failed."), true)
					return
				end
				if typeof(res) == "table" and res.ok == true then
					local spawned = tonumber(res.spawned) or 0
					local requested = tonumber(res.requested) or payload.count
					local fallback = if res.fallback == true then " nearest lanes" else ""
					setToolsStatus(string.format("Spawned %.0f/%.0f car(s)%s.", spawned, requested, fallback), false)
				else
					local err = if typeof(res) == "table" then res.error else nil
					setToolsStatus(tostring(err or res or "Spawn failed."), true)
				end
			end)
		end,
	})

	local radiusRow = toolRow(5)
	radiusBox = toolInput(radiusRow, "Radius", "260", 1)
	Button.new({
		text = "Set radius",
		compact = true,
		size = UDim2.new(0, 136, 1, 0),
		parent = radiusRow,
		layoutOrder = 2,
		onClick = function()
			local radius = tonumber((radiusBox and radiusBox.Text) or "")
			if not radius then
				setToolsStatus("Enter a radius.", true)
				return
			end
			setToolsStatus(string.format("Spawn radius set to %.0f.", radius), false)
		end,
	})

	carCount.FocusLost:Connect(function()
		local v = math.clamp(math.floor((tonumber(carCount.Text) or 12) + 0.5), 1, 80)
		carCount.Text = tostring(v)
	end)
	local rb = radiusBox
	if rb then
		rb.FocusLost:Connect(function()
			local v = math.clamp(math.floor((tonumber(rb.Text) or 260) + 0.5), 40, 1500)
			rb.Text = tostring(v)
		end)
	end

	sectionLabel(tools, "Population", 6)
	local populationRow = toolRow(7)
	local populationAmount = toolInput(populationRow, "PopulationAmount", "100", 1)
	Button.new({
		text = "Add population",
		compact = true,
		size = UDim2.new(0, 136, 1, 0),
		parent = populationRow,
		layoutOrder = 2,
		onClick = function()
			local amount = math.clamp(math.floor(tonumber(populationAmount.Text) or 0), 1, 5000)
			setToolsStatus("Adding households...", false)
			task.spawn(function()
				local ok, res = pcall(function()
					return _net.RequestAdminCityAction:InvokeServer({ action = "addPopulation", amount = amount })
				end)
				if ok and typeof(res) == "table" and res.ok == true then
					setToolsStatus(string.format("Added %d citizens across %d households. Population: %d.",
						tonumber(res.added) or 0, tonumber(res.households) or 0, tonumber(res.population) or 0), false)
				else
					setToolsStatus(tostring(if typeof(res) == "table" then res.error else res or "Population action failed."), true)
				end
			end)
		end,
	})

	sectionLabel(tools, "Pedestrians", 8)
	local walkerRow = toolRow(9)
	local walkerAmount = toolInput(walkerRow, "WalkerAmount", "10", 1)
	Button.new({
		text = "Spawn walkers",
		compact = true,
		size = UDim2.new(0, 136, 1, 0),
		parent = walkerRow,
		layoutOrder = 2,
		onClick = function()
			local amount = math.clamp(math.floor(tonumber(walkerAmount.Text) or 1), 1, 80)
			setToolsStatus("Spawning pedestrians...", false)
			task.spawn(function()
				local ok, res = pcall(function()
					return _net.RequestAdminCityAction:InvokeServer({ action = "spawnWalkers", amount = amount })
				end)
				if ok and typeof(res) == "table" and res.ok == true then
					setToolsStatus(string.format("Spawned %d/%d pedestrians.", tonumber(res.spawned) or 0, tonumber(res.requested) or amount), false)
				else
					setToolsStatus(tostring(if typeof(res) == "table" then res.error else res or "Walker spawn failed."), true)
				end
			end)
		end,
	})

	sectionLabel(tools, "Time of day", 10)
	local timeRow = toolRow(11)
	local timeHour = toolInput(timeRow, "TimeHour", string.format("%.2f", Lighting.ClockTime), 1)
	Button.new({
		text = "Set time",
		compact = true,
		size = UDim2.new(0, 136, 1, 0),
		parent = timeRow,
		layoutOrder = 2,
		onClick = function()
			if not _net or not _net.RequestAdminCityAction then
				setToolsStatus("Time remote missing.", true)
				return
			end
			local hour = tonumber(timeHour.Text)
			if not hour or hour ~= hour then
				setToolsStatus("Enter an hour from 0 to 24.", true)
				return
			end
			hour = math.clamp(hour, 0, 23.999)
			setToolsStatus("Changing time...", false)
			task.spawn(function()
				local ok, res = pcall(function()
					return _net.RequestAdminCityAction:InvokeServer({ action = "setTimeOfDay", hour = hour })
				end)
				if ok and typeof(res) == "table" and res.ok == true then
					local applied = tonumber(res.hour) or hour
					timeHour.Text = string.format("%.2f", applied)
					local totalMinutes = math.floor((applied % 24) * 60 + 0.5) % (24 * 60)
					local hh = math.floor(totalMinutes / 60)
					local mm = totalMinutes % 60
					local day = tonumber(res.day)
					local suffix = if day then string.format(" on day %d", day) else ""
					setToolsStatus(string.format("Time set to %02d:%02d%s.", hh, mm, suffix), false)
				else
					local err = if typeof(res) == "table" then res.error else nil
					setToolsStatus(tostring(err or res or "Time change failed."), true)
				end
			end)
		end,
	})
	timeHour.FocusLost:Connect(function()
		local hour = tonumber(timeHour.Text)
		if not hour or hour ~= hour then
			timeHour.Text = string.format("%.2f", Lighting.ClockTime)
			return
		end
		timeHour.Text = string.format("%.2f", math.clamp(hour, 0, 23.999))
	end)

	sectionLabel(tools, "Season", 12)
	local function seasonButton(row: Frame, label: string, order: number)
		Button.new({
			text = label,
			compact = true,
			size = UDim2.new(0, 88, 1, 0),
			parent = row,
			layoutOrder = order,
			onClick = function()
				if not _net or not _net.RequestAdminCityAction then
					setToolsStatus("Season remote missing.", true)
					return
				end
				setToolsStatus("Changing season...", false)
				task.spawn(function()
					local ok, res = pcall(function()
						return _net.RequestAdminCityAction:InvokeServer({ action = "setSeason", season = label })
					end)
					if ok and typeof(res) == "table" and res.ok == true then
						setToolsStatus(string.format("Season set to %s.", tostring(res.season or label)), false)
					else
						local err = if typeof(res) == "table" then res.error else nil
						setToolsStatus(tostring(err or res or "Season change failed."), true)
					end
				end)
			end,
		})
	end
	local seasonRow1 = toolRow(13)
	seasonButton(seasonRow1, "Spring", 1)
	seasonButton(seasonRow1, "Summer", 2)
	seasonButton(seasonRow1, "Autumn", 3)
	local seasonRow2 = toolRow(14)
	seasonButton(seasonRow2, "Fall", 1)
	seasonButton(seasonRow2, "Winter", 2)

	sectionLabel(tools, "Weather", 15)
	local function weatherButton(row: Frame, label: string, order: number)
		Button.new({
			text = label,
			compact = true,
			size = UDim2.new(0, 88, 1, 0),
			parent = row,
			layoutOrder = order,
			onClick = function()
				if not _net or not _net.RequestAdminCityAction then
					setToolsStatus("Weather remote missing.", true)
					return
				end
				setToolsStatus("Changing weather...", false)
				task.spawn(function()
					local ok, res = pcall(function()
						return _net.RequestAdminCityAction:InvokeServer({ action = "setWeather", weather = label })
					end)
					if ok and typeof(res) == "table" and res.ok == true then
						setToolsStatus(string.format("Weather set to %s.", tostring(res.weather or label)), false)
					else
						local err = if typeof(res) == "table" then res.error else nil
						setToolsStatus(tostring(err or res or "Weather change failed."), true)
					end
				end)
			end,
		})
	end
	local weatherRow = toolRow(16)
	weatherButton(weatherRow, "Clear", 1)
	weatherButton(weatherRow, "Rain", 2)
	weatherButton(weatherRow, "Snow", 3)

	-- Perf page
	local perf = listPage("Perf")
	perf.Parent = content
	_pages.Perf = perf
	sectionLabel(perf, "Client", 1)
	addRow(perf, "FPS", "c_fps", 2)
	addRow(perf, "Frame time", "c_frame", 3)
	addRow(perf, "Ping", "c_ping", 4)
	addRow(perf, "Memory", "c_mem", 5)
	addRow(perf, "MicroProfiler", "c_micro", 6)
	addRow(perf, "UI objects", "c_ui", 7)
	addRow(perf, "LocalScripts", "c_scripts", 8)
	addRow(perf, "Camera", "c_cam", 9)
	addRow(perf, "Input", "c_input", 10)
	sectionLabel(perf, "Server", 11)
	addRow(perf, "FPS", "s_fps", 12)
	addRow(perf, "Heartbeat", "s_hb", 13)
	addRow(perf, "Physics step", "s_phys", 14)
	addRow(perf, "Physics FPS", "s_pfps", 15)
	addRow(perf, "Memory", "s_mem", 16)
	addRow(perf, "Instances", "s_inst", 17)
	addRow(perf, "Net send", "s_send", 18)
	addRow(perf, "Net receive", "s_recv", 19)
	addRow(perf, "Players", "s_players", 20)
	addRow(perf, "Uptime", "s_up", 21)
	addRow(perf, "JobId", "s_job", 22)
	addRow(perf, "PlaceId", "s_place", 23)
	addRow(perf, "Region", "s_region", 24)

	-- Saves page
	local savesPage = Instance.new("Frame")
	savesPage.Name = "Saves"
	savesPage.BackgroundTransparency = 1
	savesPage.Size = UDim2.fromScale(1, 1)
	savesPage.Visible = false
	savesPage.Parent = content
	_pages.Saves = savesPage

	local searchRow = Instance.new("Frame")
	searchRow.BackgroundTransparency = 1
	searchRow.Size = UDim2.new(1, 0, 0, 28)
	searchRow.Parent = savesPage
	local searchList = Instance.new("UIListLayout")
	searchList.FillDirection = Enum.FillDirection.Horizontal
	searchList.SortOrder = Enum.SortOrder.LayoutOrder
	searchList.VerticalAlignment = Enum.VerticalAlignment.Center
	searchList.Padding = UDim.new(0, Theme.Pad.SM)
	searchList.Parent = searchRow

	local queryBox = Instance.new("TextBox")
	queryBox.Name = "QueryBox"
	queryBox.BackgroundColor3 = Theme.Color.BgRaised
	queryBox.BorderSizePixel = 0
	queryBox.Size = UDim2.new(1, -70, 1, 0)
	queryBox.FontFace = Theme.Font.Label
	queryBox.TextSize = Theme.TextSize.SM
	queryBox.TextColor3 = Theme.Color.TextPrimary
	queryBox.PlaceholderText = ""
	queryBox.Text = ""
	queryBox.PlaceholderColor3 = Theme.Color.TextSecondary
	queryBox.ClearTextOnFocus = false
	queryBox.LayoutOrder = 1
	local qPad = Instance.new("UIPadding")
	qPad.PaddingLeft = UDim.new(0, 6)
	qPad.Parent = queryBox
	local qCorner = Instance.new("UICorner")
	qCorner.CornerRadius = UDim.new(0, 4)
	qCorner.Parent = queryBox
	queryBox.Parent = searchRow
	_saveQuery = queryBox

	Button.new({
		text = "Search",
		compact = true,
		size = UDim2.new(0, 60, 1, 0),
		parent = searchRow,
		layoutOrder = 2,
		onClick = function() requestAdminSaves(queryBox.Text) end,
	})

	local statusLbl = Instance.new("TextLabel")
	statusLbl.Name = "Status"
	statusLbl.BackgroundTransparency = 1
	statusLbl.Size = UDim2.new(1, 0, 0, 18)
	statusLbl.Position = UDim2.new(0, 0, 0, 32)
	statusLbl.FontFace = Theme.Font.Label
	statusLbl.TextSize = Theme.TextSize.XS
	statusLbl.TextColor3 = Theme.Color.TextSecondary
	statusLbl.TextXAlignment = Enum.TextXAlignment.Left
	statusLbl.Text = "Loading all saves…"
	statusLbl.Parent = savesPage
	_saveStatus = statusLbl

	_saveHolder = scroller(savesPage, 54)


	-- also search on Enter
	queryBox.FocusLost:Connect(function(enterPressed)
		if enterPressed then requestAdminSaves(queryBox.Text) end
	end)

	-- Cities page: who is online anywhere in the experience, and a way into any of it.
	local citiesPage = Instance.new("Frame")
	citiesPage.Name = "Cities"
	citiesPage.BackgroundTransparency = 1
	citiesPage.Size = UDim2.fromScale(1, 1)
	citiesPage.Visible = false
	citiesPage.Parent = content
	_pages.Cities = citiesPage

	local citySearchRow = Instance.new("Frame")
	citySearchRow.BackgroundTransparency = 1
	citySearchRow.Size = UDim2.new(1, 0, 0, 28)
	citySearchRow.Parent = citiesPage
	local citySearchList = Instance.new("UIListLayout")
	citySearchList.FillDirection = Enum.FillDirection.Horizontal
	citySearchList.SortOrder = Enum.SortOrder.LayoutOrder
	citySearchList.VerticalAlignment = Enum.VerticalAlignment.Center
	citySearchList.Padding = UDim.new(0, Theme.Pad.SM)
	citySearchList.Parent = citySearchRow

	local cityQuery = Instance.new("TextBox")
	cityQuery.Name = "CityQuery"
	cityQuery.BackgroundColor3 = Theme.Color.BgRaised
	cityQuery.BorderSizePixel = 0
	cityQuery.Size = UDim2.new(1, -132, 1, 0)
	cityQuery.FontFace = Theme.Font.Label
	cityQuery.TextSize = Theme.TextSize.SM
	cityQuery.TextColor3 = Theme.Color.TextPrimary
	cityQuery.PlaceholderText = "username (leave blank for who is online)"
	cityQuery.PlaceholderColor3 = Theme.Color.TextSecondary
	cityQuery.Text = ""
	cityQuery.ClearTextOnFocus = false
	cityQuery.LayoutOrder = 1
	local cqPad = Instance.new("UIPadding")
	cqPad.PaddingLeft = UDim.new(0, 6)
	cqPad.Parent = cityQuery
	local cqCorner = Instance.new("UICorner")
	cqCorner.CornerRadius = UDim.new(0, 4)
	cqCorner.Parent = cityQuery
	cityQuery.Parent = citySearchRow
	_citiesQuery = cityQuery

	Button.new({
		text = "Find", compact = true, size = UDim2.new(0, 56, 1, 0),
		parent = citySearchRow, layoutOrder = 2,
		onClick = function() findCities(cityQuery.Text) end,
	})
	Button.new({
		text = "Online", compact = true, size = UDim2.new(0, 64, 1, 0),
		parent = citySearchRow, layoutOrder = 3,
		onClick = function()
			cityQuery.Text = ""
			refreshCities()
		end,
	})

	local cityStatus = Instance.new("TextLabel")
	cityStatus.Name = "Status"
	cityStatus.BackgroundTransparency = 1
	cityStatus.Size = UDim2.new(1, 0, 0, 18)
	cityStatus.Position = UDim2.new(0, 0, 0, 32)
	cityStatus.FontFace = Theme.Font.Label
	cityStatus.TextSize = Theme.TextSize.XS
	cityStatus.TextColor3 = Theme.Color.TextSecondary
	cityStatus.TextXAlignment = Enum.TextXAlignment.Left
	cityStatus.Text = ""
	cityStatus.Parent = citiesPage
	_citiesStatus = cityStatus

	_citiesHolder = scroller(citiesPage, 54)

	cityQuery.FocusLost:Connect(function(enterPressed)
		if enterPressed then findCities(cityQuery.Text) end
	end)


	-- World page
	local world = listPage("World")
	world.Parent = content
	_pages.World = world
	sectionLabel(world, "Snapshot feed", 1)
	addRow(world, "Players", "w_players", 2)
	addRow(world, "NPC vehicles", "w_npc", 3)
	addRow(world, "Road nodes", "w_nodes", 4)
	addRow(world, "Segments", "w_segs", 5)
	addRow(world, "Nav edges", "w_edges", 6)
	addRow(world, "Intersections", "w_inter", 7)
	addRow(world, "Dead ends", "w_dead", 8)
	addRow(world, "Feed", "w_feed", 9)
	sectionLabel(world, "Instances", 10)
	addRow(world, "Workspace objects", "w_ws", 11)
	addRow(world, "StreamingEnabled", "w_stream", 12)

	-- Networking page
	local netPage = Instance.new("Frame")
	netPage.Name = "Net"
	netPage.BackgroundTransparency = 1
	netPage.Size = UDim2.fromScale(1, 1)
	netPage.Visible = false
	netPage.Parent = content
	_pages.Net = netPage
	local netRows = Instance.new("Frame")
	netRows.BackgroundTransparency = 1
	netRows.Size = UDim2.new(1, 0, 0, 210)
	netRows.Parent = netPage
	local netList = Instance.new("UIListLayout")
	netList.SortOrder = Enum.SortOrder.LayoutOrder
	netList.Padding = UDim.new(0, 3)
	netList.Parent = netRows
	sectionLabel(netRows, "Replication", 1)
	addRow(netRows, "Receive", "net_recv", 2)
	addRow(netRows, "Send", "net_send", 3)
	addRow(netRows, "Ping (RTT)", "net_ping", 4)
	addRow(netRows, "RemoteEvents/s", "net_ev", 5)
	addRow(netRows, "Inbound est", "net_kb", 6)
	addRow(netRows, "Remotes", "net_remotes", 7)
	addRow(netRows, "StreamingEnabled", "net_stream", 8)
	addRow(netRows, "Net owner (NPCs)", "net_owner", 9)
	sectionLabel(netRows, "Top inbound events", 10)
	_netHolder = scroller(netPage, 214)

	-- NPCs page
	local npcPage = Instance.new("Frame")
	npcPage.Name = "NPCs"
	npcPage.BackgroundTransparency = 1
	npcPage.Size = UDim2.fromScale(1, 1)
	npcPage.Visible = false
	npcPage.Parent = content
	_pages.NPCs = npcPage
	_speedsBtn = Button.new({
		text = "Show speed labels",
		parent = npcPage,
		onClick = toggleSpeeds,
	})
	_speedsBtn.Instance.Position = UDim2.new(0, 0, 0, 0)
	_speedsBtn.Instance.Size = UDim2.new(0.48, 0, 0, 30)
	_inspectorBtn = Button.new({
		text = "Select route",
		parent = npcPage,
		onClick = toggleInspector,
	})
	_inspectorBtn.Instance.Position = UDim2.new(0.52, 0, 0, 0)
	_inspectorBtn.Instance.Size = UDim2.new(0.48, 0, 0, 30)

	local npcSummary = Instance.new("Frame")
	npcSummary.BackgroundTransparency = 1
	npcSummary.Position = UDim2.new(0, 0, 0, 36)
	npcSummary.Size = UDim2.new(1, 0, 0, 40)
	npcSummary.Parent = npcPage
	local npcSumList = Instance.new("UIListLayout")
	npcSumList.SortOrder = Enum.SortOrder.LayoutOrder
	npcSumList.Padding = UDim.new(0, 3)
	npcSumList.Parent = npcSummary
	addRow(npcSummary, "NPCs total", "n_total", 1)
	addRow(npcSummary, "Stopped (v\u{2248}0)", "n_stopped", 2)
	local inspectPanel = Instance.new("Frame")
	inspectPanel.Name = "Inspector"
	inspectPanel.BackgroundColor3 = Theme.Color.BgRaised
	inspectPanel.BackgroundTransparency = 0.08
	inspectPanel.BorderSizePixel = 0
	inspectPanel.Position = UDim2.new(0, 0, 0, 80)
	inspectPanel.Size = UDim2.new(1, 0, 0, 96)
	inspectPanel.Parent = npcPage
	local inspectCorner = Instance.new("UICorner")
	inspectCorner.CornerRadius = UDim.new(0, Theme.Radius.SM)
	inspectCorner.Parent = inspectPanel
	local inspectPadding = Instance.new("UIPadding")
	inspectPadding.PaddingTop = UDim.new(0, 6)
	inspectPadding.PaddingBottom = UDim.new(0, 6)
	inspectPadding.PaddingLeft = UDim.new(0, 8)
	inspectPadding.PaddingRight = UDim.new(0, 8)
	inspectPadding.Parent = inspectPanel
	_inspectorInfo = Instance.new("TextLabel")
	_inspectorInfo.BackgroundTransparency = 1
	_inspectorInfo.Size = UDim2.fromScale(1, 1)
	_inspectorInfo.FontFace = Theme.Font.Label
	_inspectorInfo.TextSize = Theme.TextSize.XS
	_inspectorInfo.TextColor3 = Theme.Color.TextSecondary
	_inspectorInfo.TextWrapped = true
	_inspectorInfo.TextXAlignment = Enum.TextXAlignment.Left
	_inspectorInfo.TextYAlignment = Enum.TextYAlignment.Top
	_inspectorInfo.Text = "Turn on Select route, then click a visible vehicle or citizen."
	_inspectorInfo.Parent = inspectPanel
	_npcHolder = scroller(npcPage, 182)

	-- Log page
	local logPage = Instance.new("Frame")
	logPage.Name = "Log"
	logPage.BackgroundTransparency = 1
	logPage.Size = UDim2.fromScale(1, 1)
	logPage.Visible = false
	logPage.Parent = content
	_pages.Log = logPage
	local clearBtn = Button.new({
		text = "Clear log",
		compact = true,
		parent = logPage,
		onClick = clearLog,
	})
	clearBtn.Instance.Position = UDim2.new(0, 0, 0, 0)
	_logHolder = scroller(logPage, 32)

	-- Routes page
	local routesPage = listPage("Routes")
	routesPage.Parent = content
	_pages.Routes = routesPage

	local btnRow = Instance.new("Frame")
	btnRow.BackgroundTransparency = 1
	btnRow.Size = UDim2.new(1, 0, 0, 30)
	btnRow.LayoutOrder = 1
	btnRow.Parent = routesPage
	local btnList = Instance.new("UIListLayout")
	btnList.FillDirection = Enum.FillDirection.Horizontal
	btnList.SortOrder = Enum.SortOrder.LayoutOrder
	btnList.VerticalAlignment = Enum.VerticalAlignment.Center
	btnList.Padding = UDim.new(0, Theme.Pad.SM)
	btnList.Parent = btnRow

	_routesShowBtn = Button.new({
		text = "Show AI routes",
		parent = btnRow,
		layoutOrder = 1,
		onClick = toggleRoutes,
	})
	Button.new({
		text = "Refresh",
		compact = true,
		parent = btnRow,
		layoutOrder = 2,
		onClick = function()
			if _routesOn then drawRoutes() end
		end,
	})
	_routesNearBtn = Button.new({
		text = "Near cam",
		compact = true,
		parent = btnRow,
		layoutOrder = 3,
		onClick = toggleNearOnly,
	})

	addRow(routesPage, "Lane lines", "r_lanes", 2)
	addRow(routesPage, "Turn lines", "r_turns", 3)
	addRow(routesPage, "Parking paths", "r_parking", 4)
	addRow(routesPage, "Parts drawn", "r_parts", 5)

	sectionLabel(routesPage, "Legend", 6)
	local function legend(color: Color3, text: string, order: number)
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, 16)
		row.LayoutOrder = order
		row.Parent = routesPage
		local sw = Instance.new("Frame")
		sw.BackgroundColor3 = color
		sw.BorderSizePixel = 0
		sw.Size = UDim2.fromOffset(20, 8)
		sw.Position = UDim2.fromOffset(0, 4)
		sw.Parent = row
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 2)
		c.Parent = sw
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.Position = UDim2.fromOffset(28, 0)
		l.Size = UDim2.new(1, -28, 1, 0)
		l.FontFace = Theme.Font.Label
		l.TextSize = Theme.TextSize.XS
		l.TextColor3 = Theme.Color.TextSecondary
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.Text = text
		l.Parent = row
	end
	legend(LANE_COLOR, "Lane centreline", 7)
	legend(MOVE_COLOR.left, "Turn: left", 8)
	legend(MOVE_COLOR.right, "Turn: right", 9)
	legend(MOVE_COLOR.straight, "Turn: straight", 10)
	legend(MOVE_COLOR.uturn, "Turn: U-turn", 11)
	legend(PARKING_COLOR, "Parking / lot path", 12)

	-- Access page -- OWNER ONLY, and the only UI anywhere that edits who is staff.
	--
	-- Testers and admins are rows in a DataStore (StaffRoster on the server), not entries
	-- in a table in a script. Adding someone here reaches every running server within
	-- seconds and survives restarts; it never needs a publish.
	--
	-- None of this is the permission check. StaffRoster re-verifies that the caller IS the
	-- place owner on every single call, so this page is a convenience over an authority
	-- that lives entirely server-side -- forging the IsPlaceOwner attribute buys nothing.
	if tabVisible("Access") then
		local access = listPage("Access")
		access.Parent = content
		_pages.Access = access

		local accessStatus = Instance.new("TextLabel")
		accessStatus.Name = "Status"
		accessStatus.BackgroundTransparency = 1
		accessStatus.Size = UDim2.new(1, -6, 0, 34)
		accessStatus.LayoutOrder = 100
		accessStatus.FontFace = Theme.Font.Label
		accessStatus.TextSize = Theme.TextSize.XS
		accessStatus.TextColor3 = Theme.Color.TextSecondary
		accessStatus.TextXAlignment = Enum.TextXAlignment.Left
		accessStatus.TextYAlignment = Enum.TextYAlignment.Top
		accessStatus.TextWrapped = true
		accessStatus.Text = "Loading the staff list..."
		accessStatus.Parent = access

		local function setAccessStatus(text: string, danger: boolean?)
			accessStatus.Text = text
			accessStatus.TextColor3 = if danger then Theme.Color.Danger else Theme.Color.TextSecondary
		end

		-- Same shape as the Tools page's toolRow, but parented to this page.
		local function accessRow(order: number): Frame
			local row = Instance.new("Frame")
			row.BackgroundTransparency = 1
			row.Size = UDim2.new(1, -6, 0, 30)
			row.LayoutOrder = order
			row.Parent = access
			local list = Instance.new("UIListLayout")
			list.FillDirection = Enum.FillDirection.Horizontal
			list.SortOrder = Enum.SortOrder.LayoutOrder
			list.VerticalAlignment = Enum.VerticalAlignment.Center
			list.Padding = UDim.new(0, Theme.Pad.SM)
			list.Parent = row
			return row
		end

		sectionLabel(access, "Add staff by UserId", 1)

		local accessNote = Instance.new("TextLabel")
		accessNote.BackgroundTransparency = 1
		accessNote.Size = UDim2.new(1, -6, 0, 44)
		accessNote.LayoutOrder = 2
		accessNote.FontFace = Theme.Font.Label
		accessNote.TextSize = Theme.TextSize.XS
		accessNote.TextColor3 = Theme.Color.TextSecondary
		accessNote.TextXAlignment = Enum.TextXAlignment.Left
		accessNote.TextYAlignment = Enum.TextYAlignment.Top
		accessNote.TextWrapped = true
		accessNote.Text = "A UserId is the number in a profile link (roblox.com/users/1234567890/profile)."
			.. " Tester = the closed test plus read-only diagnostics. Curator = reviews"
			.. " player-made creations before anyone else can see them, and nothing more."
			.. " Admin = every tool. You are the owner: you always have all of it, and you"
			.. " can't be removed."
		accessNote.Parent = access

		local idRow = accessRow(3)
		local idBox = toolInput(idRow, "StaffUserId", "", 1)
		-- toolInput leaves room for one button; this row carries three.
		idBox.Size = UDim2.new(1, -336, 1, 0)
		idBox.PlaceholderText = "UserId, e.g. 1234567890"

		sectionLabel(access, "Current staff", 4)
		local refreshRow = accessRow(5)

		local staffList = Instance.new("Frame")
		staffList.Name = "StaffList"
		staffList.BackgroundTransparency = 1
		staffList.Size = UDim2.new(1, -6, 0, 0)
		staffList.AutomaticSize = Enum.AutomaticSize.Y
		staffList.LayoutOrder = 6
		staffList.Parent = access
		local staffLayout = Instance.new("UIListLayout")
		staffLayout.FillDirection = Enum.FillDirection.Vertical
		staffLayout.SortOrder = Enum.SortOrder.LayoutOrder
		staffLayout.Padding = UDim.new(0, 2)
		staffLayout.Parent = staffList

		-- renderEntries needs callRoster (its Remove buttons) and callRoster needs
		-- renderEntries (every reply carries a fresh list), so one is forward-declared.
		local renderEntries: ({ any }) -> ()
		local _accessBusy = false

		local function callRoster(payload: { [string]: any }, pending: string, onOk: (() -> ())?)
			if _accessBusy then return end
			if not _net or not _net.RequestStaffRoster then
				setAccessStatus("Staff roster remote is missing.", true)
				return
			end
			_accessBusy = true
			setAccessStatus(pending, false)

			task.spawn(function()
				local ok, res = pcall(function()
					return _net.RequestStaffRoster:InvokeServer(payload)
				end)
				_accessBusy = false

				if not ok or typeof(res) ~= "table" then
					setAccessStatus(tostring(if ok then "The server didn't answer." else res), true)
					return
				end

				-- Every reply carries the current list, so a grant, a removal and a plain
				-- refresh all leave the page showing the truth without a second round trip.
				if typeof(res.entries) == "table" then
					renderEntries(res.entries)
				end

				if res.ok ~= true then
					setAccessStatus(tostring(res.error or "That didn't work."), true)
					return
				end

				local text = if typeof(res.message) == "string" and res.message ~= ""
					then res.message
					else string.format("%d on the staff list.", #((res.entries :: any) or {}))
				if res.degraded == true then
					text ..= " Permission storage is unreachable right now, so only you count as staff until it recovers."
				end
				setAccessStatus(text, res.degraded == true)
				if onOk then onOk() end
			end)
		end

		function renderEntries(entries: { any })
			for _, child in staffList:GetChildren() do
				if child:IsA("GuiObject") then child:Destroy() end
			end

			if #entries == 0 then
				local empty = Instance.new("TextLabel")
				empty.BackgroundTransparency = 1
				empty.Size = UDim2.new(1, 0, 0, 26)
				empty.FontFace = Theme.Font.Label
				empty.TextSize = Theme.TextSize.XS
				empty.TextColor3 = Theme.Color.TextSecondary
				empty.TextXAlignment = Enum.TextXAlignment.Left
				empty.Text = "Nobody added yet \u{2014} you're the only one with access."
				empty.Parent = staffList
				return
			end

			for index, entry in entries do
				local userId = tonumber(entry.userId) or 0
				local tier = tostring(entry.tier or "tester")
				local who = if typeof(entry.name) == "string" and entry.name ~= ""
					then entry.name
					else "Unknown"

				local row = Instance.new("Frame")
				row.BackgroundTransparency = 1
				row.Size = UDim2.new(1, 0, 0, 26)
				row.LayoutOrder = index
				row.Parent = staffList
				local rowLayout = Instance.new("UIListLayout")
				rowLayout.FillDirection = Enum.FillDirection.Horizontal
				rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
				rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
				rowLayout.Padding = UDim.new(0, Theme.Pad.SM)
				rowLayout.Parent = row

				local label = Instance.new("TextLabel")
				label.BackgroundTransparency = 1
				label.Size = UDim2.new(1, -160, 1, 0)
				label.LayoutOrder = 1
				label.FontFace = Theme.Font.Label
				label.TextSize = Theme.TextSize.XS
				label.TextColor3 = Theme.Color.TextPrimary
				label.TextXAlignment = Enum.TextXAlignment.Left
				label.TextTruncate = Enum.TextTruncate.AtEnd
				label.Text = string.format("%s  \u{00B7}  %d", who, userId)
				label.Parent = row

				local tierTag = Instance.new("TextLabel")
				tierTag.BackgroundTransparency = 1
				tierTag.Size = UDim2.new(0, 72, 1, 0) -- fits "CURATOR"
				tierTag.LayoutOrder = 2
				tierTag.FontFace = Theme.Font.Label
				tierTag.TextSize = Theme.TextSize.XS
				tierTag.TextColor3 = if tier == "admin" then Theme.Color.Accent else Theme.Color.TextSecondary
				tierTag.TextXAlignment = Enum.TextXAlignment.Right
				tierTag.Text = string.upper(tier)
				tierTag.Parent = row

				Button.new({
					text = "Remove",
					compact = true,
					size = UDim2.new(0, 88, 1, 0),
					parent = row,
					layoutOrder = 3,
					onClick = function()
						callRoster({ action = "revoke", userId = userId }, "Removing " .. who .. "...")
					end,
				})
			end
		end

		local function addStaff(tier: string)
			local userId = tonumber((string.gsub(idBox.Text, "%s", "")))
			if not userId then
				setAccessStatus("Enter the player's numeric UserId, not their username.", true)
				return
			end
			callRoster({ action = "grant", userId = userId, tier = tier }, "Adding...", function()
				idBox.Text = ""
			end)
		end

		Button.new({
			text = "Add tester",
			compact = true,
			size = UDim2.new(0, 104, 1, 0),
			parent = idRow,
			layoutOrder = 2,
			onClick = function() addStaff("tester") end,
		})
		Button.new({
			text = "Add curator",
			compact = true,
			size = UDim2.new(0, 104, 1, 0),
			parent = idRow,
			layoutOrder = 3,
			onClick = function() addStaff("curator") end,
		})
		Button.new({
			text = "Add admin",
			compact = true,
			size = UDim2.new(0, 104, 1, 0),
			parent = idRow,
			layoutOrder = 4,
			onClick = function() addStaff("admin") end,
		})

		-- Opening the tab re-reads the list, so another server's edit shows up without a
		-- rejoin. Debounced: the build below already loaded it, and the server rate-limits.
		local _lastLoadAt = 0
		local function loadList(force: boolean)
			if not force and os.clock() - _lastLoadAt < 2 then return end
			_lastLoadAt = os.clock()
			callRoster({ action = "list" }, "Loading the staff list...")
		end

		Button.new({
			text = "Refresh",
			compact = true,
			size = UDim2.new(0, 136, 1, 0),
			parent = refreshRow,
			layoutOrder = 1,
			onClick = function() loadList(true) end,
		})

		_tabOpened.Access = function() loadList(false) end
		loadList(true)
	end

	-- REVIEW: creations waiting for a human to look at them before any other player can.
	-- Curator tier and up; the owner always resolves to admin, so the owner always has it.
	--
	-- None of this is the permission check. ReviewQueue re-asks StaffRoster.canApprove on
	-- every single call, so forging the AdminTier attribute buys a drawn tab and nothing
	-- else. Names arrive already filtered -- ReviewQueue refuses a submission it could not
	-- run through FilterStringAsync, so there is no unfiltered string to render here.
	if tabVisible("Review") then
		local review = listPage("Review")
		review.Parent = content
		_pages.Review = review

		local reviewStatus = Instance.new("TextLabel")
		reviewStatus.Name = "Status"
		reviewStatus.BackgroundTransparency = 1
		reviewStatus.Size = UDim2.new(1, -6, 0, 34)
		reviewStatus.LayoutOrder = 100
		reviewStatus.FontFace = Theme.Font.Label
		reviewStatus.TextSize = Theme.TextSize.XS
		reviewStatus.TextColor3 = Theme.Color.TextSecondary
		reviewStatus.TextXAlignment = Enum.TextXAlignment.Left
		reviewStatus.TextYAlignment = Enum.TextYAlignment.Top
		reviewStatus.TextWrapped = true
		reviewStatus.Text = "Loading the review queue..."
		reviewStatus.Parent = review

		local function setReviewStatus(text: string, danger: boolean?)
			reviewStatus.Text = text
			reviewStatus.TextColor3 = if danger then Theme.Color.Danger else Theme.Color.TextSecondary
		end

		local function reviewRow(order: number): Frame
			local row = Instance.new("Frame")
			row.BackgroundTransparency = 1
			row.Size = UDim2.new(1, -6, 0, 30)
			row.LayoutOrder = order
			row.Parent = review
			local list = Instance.new("UIListLayout")
			list.FillDirection = Enum.FillDirection.Horizontal
			list.SortOrder = Enum.SortOrder.LayoutOrder
			list.VerticalAlignment = Enum.VerticalAlignment.Center
			list.Padding = UDim.new(0, Theme.Pad.SM)
			list.Parent = row
			return row
		end

		local function listBox(order: number): Frame
			local box = Instance.new("Frame")
			box.BackgroundTransparency = 1
			box.Size = UDim2.new(1, -6, 0, 0)
			box.AutomaticSize = Enum.AutomaticSize.Y
			box.LayoutOrder = order
			box.Parent = review
			local layout = Instance.new("UIListLayout")
			layout.FillDirection = Enum.FillDirection.Vertical
			layout.SortOrder = Enum.SortOrder.LayoutOrder
			layout.Padding = UDim.new(0, 3)
			layout.Parent = box
			return box
		end

		local reviewNote = Instance.new("TextLabel")
		reviewNote.BackgroundTransparency = 1
		reviewNote.Size = UDim2.new(1, -6, 0, 44)
		reviewNote.LayoutOrder = 1
		reviewNote.FontFace = Theme.Font.Label
		reviewNote.TextSize = Theme.TextSize.XS
		reviewNote.TextColor3 = Theme.Color.TextSecondary
		reviewNote.TextXAlignment = Enum.TextXAlignment.Left
		reviewNote.TextYAlignment = Enum.TextYAlignment.Top
		reviewNote.TextWrapped = true
		reviewNote.Text = "A creation is private to whoever built it until they send it here."
			.. " Approve it and other players can use it; reject it and only the author keeps it."
			.. " If something slips through, take it down from the Published list below."
		reviewNote.Parent = review

		-- The preview. Nothing should be approved sight-unseen, so this sits ABOVE the queue:
		-- the reviewer hits View on a row and the real geometry appears here.
		sectionLabel(review, "Preview", 2)
		local previewFrame = Instance.new("Frame")
		previewFrame.Name = "Preview"
		previewFrame.Size = UDim2.new(1, -6, 0, 190)
		previewFrame.BackgroundColor3 = Theme.Color.Bg
		previewFrame.BorderSizePixel = 0
		previewFrame.LayoutOrder = 3
		previewFrame.Parent = review
		do
			local c = Instance.new("UICorner")
			c.CornerRadius = UDim.new(0, Theme.Radius.MD)
			c.Parent = previewFrame
		end

		local viewport = Instance.new("ViewportFrame")
		viewport.Name = "Viewport"
		viewport.Active = true -- required for the scroll wheel to reach InputChanged
		viewport.Size = UDim2.fromScale(1, 1)
		viewport.BackgroundTransparency = 1
		viewport.Ambient = Color3.fromRGB(150, 150, 150)
		viewport.LightColor = Color3.fromRGB(255, 255, 255)
		viewport.LightDirection = Vector3.new(-0.4, -1, -0.6)
		viewport.Parent = previewFrame
		local previewCam = Instance.new("Camera")
		previewCam.FieldOfView = 40
		previewCam.Parent = viewport
		viewport.CurrentCamera = previewCam

		local previewCaption = Instance.new("TextLabel")
		previewCaption.BackgroundTransparency = 1
		previewCaption.Position = UDim2.fromOffset(10, 6)
		previewCaption.Size = UDim2.new(1, -20, 0, 16)
		previewCaption.FontFace = Theme.Font.Label
		previewCaption.TextSize = Theme.TextSize.XS
		previewCaption.TextColor3 = Theme.Color.TextSecondary
		previewCaption.TextXAlignment = Enum.TextXAlignment.Left
		previewCaption.TextTruncate = Enum.TextTruncate.AtEnd
		previewCaption.Text = "Pick View on a submission to see it. Scroll to zoom."
		previewCaption.Parent = previewFrame

		local _previewModel: Model? = nil
		local _previewBusy = false
		local _previewSpin: RBXScriptConnection? = nil
		-- Camera distance lives out here so the wheel can move it while the orbit runs.
		-- `base` is the distance the model was framed at, so the limits scale with whatever
		-- is being inspected -- a bench and a tower both bottom out somewhere sensible.
		local _dist, _baseDist = 0, 0
		local _focus = Vector3.zero
		local ZOOM_MIN, ZOOM_MAX, ZOOM_STEP = 0.35, 2.5, 0.12

		local function clearPreview()
			if _previewSpin then _previewSpin:Disconnect(); _previewSpin = nil end
			if _previewModel then _previewModel:Destroy(); _previewModel = nil end
		end
		_clearReviewPreview = clearPreview

		-- Switching to another tab must stop the orbit too. Without this the spin kept posing
		-- a camera inside a hidden ViewportFrame every frame for the rest of the session --
		-- and after Cleanup destroyed the GUI, on a camera that no longer existed.
		review:GetPropertyChangedSignal("Visible"):Connect(function()
			if not review.Visible then clearPreview() end
		end)

		viewport.InputChanged:Connect(function(input: InputObject)
			if input.UserInputType ~= Enum.UserInputType.MouseWheel then return end
			if _baseDist <= 0 then return end
			-- Multiplicative: a fixed stud step crawls when zoomed out and punches through
			-- the model when zoomed in. A reviewer needs to get close to small detail.
			local factor = 1 - (input.Position.Z * ZOOM_STEP)
			_dist = math.clamp(_dist * factor, _baseDist * ZOOM_MIN, _baseDist * ZOOM_MAX)
		end)

		-- The client cannot see ServerStorage, so prop references resolve by leaf name into
		-- ReplicatedStorage.Props; whatever misses becomes CreationBuilder's placeholder box
		-- rather than a hole, which keeps the silhouette honest for the person judging it.
		local function previewResolve(key: string): Model?
			local leaf = string.match(key, "([^%.]+)$")
			if not leaf then return nil end
			local props = ReplicatedStorage:FindFirstChild("Props")
			local model = props and props:FindFirstChild(leaf)
			return if model and model:IsA("Model") then model :: Model else nil
		end

		local function showPreview(id: string, fallbackName: string)
			if _previewBusy then
				-- Say so. Returning silently made a second View click look like a dead button.
				previewCaption.Text = "Still loading the last one..."
				return
			end
			if not _net or not _net.RequestReviewQueue then return end
			_previewBusy = true
			previewCaption.Text = "Loading " .. fallbackName .. "..."
			task.spawn(function()
				local ok, res = pcall(function()
					return _net.RequestReviewQueue:InvokeServer({ action = "blob", id = id })
				end)
				if not ok or typeof(res) ~= "table" or not res.ok or typeof(res.blob) ~= "table" then
					_previewBusy = false
					previewCaption.Text = tostring((typeof(res) == "table" and res.error) or "Couldn't load that creation.")
					return
				end

				local model, count = CreationBuilder.build(res.blob, previewResolve)
				clearPreview()
				-- Released only now the old preview is gone and the new one is built. Safe
				-- either way today because CreationBuilder.build cannot yield -- but releasing
				-- before the swap means the day it CAN, two of these interleave and orphan both
				-- a model and a live RenderStepped connection.
				_previewBusy = false
				if not model then
					previewCaption.Text = "That creation is empty."
					return
				end

				model.Parent = viewport
				_previewModel = model

				local cf, size = model:GetBoundingBox()
				local radius = math.max(size.X, size.Y, size.Z) * 0.5
				if radius <= 0 then radius = 4 end
				-- Pull back far enough for the whole thing to fit the field of view, with a
				-- margin so nothing kisses the frame edge.
				_baseDist = (radius / math.tan(math.rad(previewCam.FieldOfView * 0.5))) * 1.5
				_dist = _baseDist -- every new submission starts framed, not at the last zoom
				_focus = cf.Position

				-- Slow orbit: a static three-quarter view hides whatever is behind it, and
				-- "behind it" is exactly where someone would hide something.
				local angle = 0
				_previewSpin = RunService.RenderStepped:Connect(function(dt)
					angle += dt * 0.4
					local offset = Vector3.new(math.cos(angle), 0.55, math.sin(angle)).Unit * _dist
					previewCam.CFrame = CFrame.lookAt(_focus + offset, _focus)
				end)

				previewCaption.Text = string.format("%s  \u{00B7}  by %s  \u{00B7}  %d parts  \u{00B7}  %s",
					tostring(res.name or fallbackName),
					tostring(res.ownerName ~= "" and res.ownerName or "unknown"),
					count,
					string.upper(tostring(res.status or "")))
			end)
		end

		sectionLabel(review, "Waiting for review", 4)
		local queueList = listBox(5)

		sectionLabel(review, "Reason \u{2014} sent to the author when you reject", 6)
		local reasonRow = reviewRow(7)
		local reasonBox = toolInput(reasonRow, "RejectReason", "", 1)
		reasonBox.Size = UDim2.new(1, -6, 1, 0)
		reasonBox.PlaceholderText = "Optional \u{2014} why it can't go live"

		sectionLabel(review, "Published", 8)
		local publishedList = listBox(9)

		sectionLabel(review, "Decision log \u{2014} who approved what", 10)
		local logList = listBox(11)
		local reviewRefreshRow = reviewRow(12)

		-- Same knot as the Access page: the row buttons need callReview, and every reply
		-- carries fresh lists that need rendering, so the renderers are forward-declared.
		local renderQueue: ({ any }) -> ()
		local renderPublished: ({ any }) -> ()
		local renderLog: ({ any }) -> ()
		local _reviewBusy = false

		local function callReview(payload: { [string]: any }, pending: string)
			if _reviewBusy then return end
			if not _net or not _net.RequestReviewQueue then
				setReviewStatus("Review remote is missing.", true)
				return
			end
			_reviewBusy = true
			setReviewStatus(pending, false)

			task.spawn(function()
				local ok, res = pcall(function()
					return _net.RequestReviewQueue:InvokeServer(payload)
				end)
				_reviewBusy = false

				if not ok or typeof(res) ~= "table" then
					setReviewStatus(tostring(if ok then "The server didn't answer." else res), true)
					return
				end

				-- Every reply carries both lists, so a decision and a plain refresh both
				-- leave the page showing the truth without a second round trip.
				if typeof(res.pending) == "table" then renderQueue(res.pending) end
				if typeof(res.published) == "table" then renderPublished(res.published) end
				if typeof(res.log) == "table" then renderLog(res.log) end

				if res.ok ~= true then
					setReviewStatus(tostring(res.error or "That didn't work."), true)
					return
				end

				local text = if typeof(res.message) == "string" and res.message ~= ""
					then res.message
					else string.format("%d waiting for review.", #((res.pending :: any) or {}))
				if res.degraded == true then
					text ..= " Review storage is unreachable right now, so this list may be out of date."
				end
				setReviewStatus(text, res.degraded == true)
			end)
		end

		-- One row: what it is, who made it, and the decision buttons. `actions` is a list of
		-- { label, width, run } so the pending and published rows share this shape.
		local function buildRow(parent: Instance, index: number, entry: any, actions: { any })
			local name = if typeof(entry.name) == "string" and entry.name ~= "" then entry.name else "Untitled"
			local who = if typeof(entry.ownerName) == "string" and entry.ownerName ~= ""
				then entry.ownerName
				else tostring(tonumber(entry.ownerId) or 0)

			local row = Instance.new("Frame")
			row.BackgroundTransparency = 1
			row.Size = UDim2.new(1, 0, 0, 26)
			row.LayoutOrder = index
			row.Parent = parent
			local rowLayout = Instance.new("UIListLayout")
			rowLayout.FillDirection = Enum.FillDirection.Horizontal
			rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
			rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
			rowLayout.Padding = UDim.new(0, Theme.Pad.SM)
			rowLayout.Parent = row

			local reserved = 72
			for _, a in actions do reserved += (a.width :: number) + Theme.Pad.SM end

			local label = Instance.new("TextLabel")
			label.BackgroundTransparency = 1
			label.Size = UDim2.new(1, -reserved, 1, 0)
			label.LayoutOrder = 1
			label.FontFace = Theme.Font.Label
			label.TextSize = Theme.TextSize.XS
			label.TextColor3 = Theme.Color.TextPrimary
			label.TextXAlignment = Enum.TextXAlignment.Left
			label.TextTruncate = Enum.TextTruncate.AtEnd
			label.Text = string.format("%s  \u{00B7}  by %s", name, who)
			label.Parent = row

			local catTag = Instance.new("TextLabel")
			catTag.BackgroundTransparency = 1
			catTag.Size = UDim2.new(0, 72, 1, 0)
			catTag.LayoutOrder = 2
			catTag.FontFace = Theme.Font.Label
			catTag.TextSize = Theme.TextSize.XS
			catTag.TextColor3 = Theme.Color.TextSecondary
			catTag.TextXAlignment = Enum.TextXAlignment.Right
			catTag.Text = string.upper(tostring(entry.cat or ""))
			catTag.Parent = row

			for i, a in actions do
				Button.new({
					text = a.label,
					compact = true,
					size = UDim2.new(0, a.width, 1, 0),
					parent = row,
					layoutOrder = 2 + i,
					onClick = a.run,
				})
			end
		end

		local function emptyNote(parent: Instance, text: string)
			local empty = Instance.new("TextLabel")
			empty.BackgroundTransparency = 1
			empty.Size = UDim2.new(1, 0, 0, 26)
			empty.FontFace = Theme.Font.Label
			empty.TextSize = Theme.TextSize.XS
			empty.TextColor3 = Theme.Color.TextSecondary
			empty.TextXAlignment = Enum.TextXAlignment.Left
			empty.Text = text
			empty.Parent = parent
		end

		local function clearList(parent: Instance)
			for _, child in parent:GetChildren() do
				if child:IsA("GuiObject") then child:Destroy() end
			end
		end

		-- The reason box is shared by every Reject button, and cleared once spent so the
		-- next rejection cannot silently inherit the last one's wording.
		local function takeReason(): string
			local reason = reasonBox.Text
			reasonBox.Text = ""
			return reason
		end

		function renderQueue(entries: { any })
			clearList(queueList)
			if #entries == 0 then
				emptyNote(queueList, "Nothing waiting \u{2014} everything sent in has been dealt with.")
				return
			end
			for index, entry in entries do
				local id = tostring(entry.bpId)
				local shown = if typeof(entry.name) == "string" and entry.name ~= "" then entry.name else "Untitled"
				buildRow(queueList, index, entry, {
					-- View leads on purpose: approving without looking is the one mistake this
					-- whole queue exists to prevent.
					{ label = "View", width = 64, run = function()
						showPreview(id, shown)
					end },
					{ label = "Approve", width = 88, run = function()
						callReview({ action = "approve", id = id }, "Approving...")
					end },
					{ label = "Reject", width = 80, run = function()
						callReview({ action = "reject", id = id, reason = takeReason() }, "Rejecting...")
					end },
				})
			end
		end

		function renderPublished(entries: { any })
			clearList(publishedList)
			if #entries == 0 then
				emptyNote(publishedList, "Nothing published yet.")
				return
			end
			for index, entry in entries do
				local id = tostring(entry.bpId)
				local shown = if typeof(entry.name) == "string" and entry.name ~= "" then entry.name else "Untitled"
				buildRow(publishedList, index, entry, {
					{ label = "View", width = 64, run = function()
						showPreview(id, shown)
					end },
					{ label = "Take down", width = 96, run = function()
						callReview({ action = "unpublish", id = id, reason = takeReason() }, "Taking it down...")
					end },
				})
			end
		end

		-- Who decided what, newest first. Read-only: the log is evidence, not a workspace.
		local VERB: { [string]: string } = {
			approved = "approved", rejected = "rejected", takedown = "took down",
		}
		function renderLog(entries: { any })
			clearList(logList)
			if #entries == 0 then
				emptyNote(logList, "No decisions recorded yet.")
				return
			end
			for index, entry in entries do
				local row = Instance.new("TextLabel")
				row.BackgroundTransparency = 1
				row.Size = UDim2.new(1, 0, 0, 22)
				row.LayoutOrder = index
				row.FontFace = Theme.Font.Label
				row.TextSize = Theme.TextSize.XS
				row.TextXAlignment = Enum.TextXAlignment.Left
				row.TextTruncate = Enum.TextTruncate.AtEnd
				local action = tostring(entry.action)
				row.TextColor3 = if action == "approved" then Theme.Color.TextPrimary else Theme.Color.TextSecondary
				local who = if typeof(entry.byName) == "string" and entry.byName ~= ""
					then entry.byName
					else tostring(tonumber(entry.by) or 0)
				local when = os.date("!%Y-%m-%d %H:%M", math.max(0, tonumber(entry.at) or 0))
				local why = if typeof(entry.reason) == "string" and entry.reason ~= ""
					then "  \u{2014}  " .. entry.reason
					else ""
				row.Text = string.format("%s  \u{00B7}  %s %s \u{201C}%s\u{201D} by %s%s",
					when, who, VERB[action] or action,
					tostring(entry.name or "?"), tostring(entry.ownerName or "?"), why)
				row.Parent = logList
			end
		end

		local _lastReviewLoadAt = 0
		local function loadReview(force: boolean)
			if not force and os.clock() - _lastReviewLoadAt < 2 then return end
			_lastReviewLoadAt = os.clock()
			callReview({ action = "list" }, "Loading the review queue...")
		end

		Button.new({
			text = "Refresh",
			compact = true,
			size = UDim2.new(0, 136, 1, 0),
			parent = reviewRefreshRow,
			layoutOrder = 1,
			onClick = function() loadReview(true) end,
		})

		_tabOpened.Review = function() loadReview(false) end
		loadReview(true)
	end

	-- live log capture (always on, so the buffer is warm when the tab opens)
	table.insert(_conns, LogService.MessageOut:Connect(pushLog))

	-- snapshot feed
	table.insert(_conns, _net.DebugSnapshot.OnClientEvent:Connect(function(snap)
		_snapshot = snap
		if _visible and _activeTab == "NPCs" then
			rebuildNpcList()
		end
	end))

	-- routes auto-refresh when the road network or parking/building routes change.
	table.insert(_conns, _net.SyncSegments.OnClientEvent:Connect(markRoutesDirty))
	table.insert(_conns, _net.SyncSegmentsDelta.OnClientEvent:Connect(markRoutesDirty))
	table.insert(_conns, _net.SyncNodesDelta.OnClientEvent:Connect(markRoutesDirty))
	table.insert(_conns, _net.SyncConstructionSites.OnClientEvent:Connect(markRoutesDirty))

	-- A grown building being demolished (or placed) also changes the parking paths the
	-- overlay draws, but fires none of the events above -- watch the ZonedBuildings folder
	-- so a deleted building's lot/parking lines clear on the next refresh.
	local _bldgConns: { RBXScriptConnection } = {}
	local function hookBuildings(zb: Instance)
		for _, c in _bldgConns do c:Disconnect() end
		table.clear(_bldgConns)
		_bldgConns[#_bldgConns + 1] = zb.ChildAdded:Connect(markRoutesDirty)
		_bldgConns[#_bldgConns + 1] = zb.ChildRemoved:Connect(markRoutesDirty)
	end
	local function watchCity(city: Instance)
		local zb = city:FindFirstChild("ZonedBuildings")
		if zb then hookBuildings(zb) end
		table.insert(_conns, city.ChildAdded:Connect(function(c: Instance)
			if c.Name == "ZonedBuildings" then hookBuildings(c) end
		end))
	end
	local _city = Workspace:FindFirstChild("_City")
	if _city then
		watchCity(_city)
	else
		table.insert(_conns, Workspace.ChildAdded:Connect(function(c: Instance)
			if c.Name == "_City" then watchCity(c) end
		end))
	end

	-- networking: count inbound RemoteEvent fires + estimate payload size
	local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if remotesFolder then
		for _, r in remotesFolder:GetChildren() do
			if r:IsA("RemoteEvent") then
				_netRemoteCount += 1
				local nm = r.Name
				table.insert(_conns, (r :: RemoteEvent).OnClientEvent:Connect(function(...)
					_netByName[nm] = (_netByName[nm] or 0) + 1
					_netBytes += estimateArgs(...)
				end))
			elseif r:IsA("RemoteFunction") then
				_netRemoteCount += 1
			end
		end
	end

	-- toggle hotkey
	table.insert(_conns, UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if Settings.pressed("AdminPanel", input) then
			setVisible(not _visible)
		elseif _inspectorOn and (input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch) then
			-- CursorRay.position picks GetMouseLocation for mouse and input.Position for touch:
			-- the same split this branch was doing by hand, in the one place that owns the rule.
			-- closestInspectable compares against WorldToViewportPoint, so it needs viewport space.
			inspectAt(CursorRay.position(input))
		end
	end))

	-- per-frame driver: minimal -- accumulate, then refresh text/poll on cadence
	table.insert(_conns, RunService.RenderStepped:Connect(function(dt)
		_frameAccum += dt
		_frameCount += 1
		if _frameAccum >= FPS_WINDOW then
			_fps = _frameCount / _frameAccum
			_frameAccum = 0
			_frameCount = 0
		end

		-- world overlays run regardless of panel visibility
		if _routesOn and not _routesBusy then
			if _routesDirty and (os.clock() - _routesDirtyAt) >= ROUTE_DEBOUNCE then
				_routesDirty = false
				drawRoutes()
			elseif _routesNearOnly and _lastDrawCamPos then
				local cam = Workspace.CurrentCamera
				if cam and (cam.CFrame.Position - _lastDrawCamPos).Magnitude > ROUTE_REFRESH_MOVE then
					drawRoutes()
				end
			end
		end

		if _speedsOn then
			_speedsAccum += dt
			if _speedsAccum >= SPEED_POLL then
				_speedsAccum = 0
				pollNpcSpeeds()
			end
		end

		_netWindow += dt
		if _netWindow >= 1 then
			local w = _netWindow
			_netWindow = 0
			local total = 0
			table.clear(_netRateByName)
			for nm, c in _netByName do
				total += c
				_netRateByName[nm] = c / w
			end
			_netEvSec = total / w
			_netKbSec = (_netBytes / w) / 1024
			table.clear(_netByName)
			_netBytes = 0
			if _visible and _activeTab == "Net" then rebuildNetList() end
		end

		if not _visible then return end

		_uiAccum += dt
		if _uiAccum >= UI_TICK then
			_uiAccum = 0
			updateText()
		end

		_pollAccum += dt
		if _pollAccum >= POLL_INTERVAL then
			_pollAccum = 0
			pollServer()
		end
	end))

	selectTab(if _tabs.Debug then "Debug" else "Perf")
	setVisible(false)
end

-- ------------------------------------------------------------------ start --

function AdminController.SetVisible(visible: boolean)
	if not _built then return end
	setVisible(visible)
end

function AdminController.Start()
	if _started then return end
	_started = true

	_net = require(ReplicatedStorage:WaitForChild("Networker"))

	local function ensure()
		if _built then return end
		local tier = LocalPlayer:GetAttribute("AdminTier")
		if RunService:IsStudio() then
			tier = "admin"
		end
		if TIER_RANK[tier] ~= nil then
			_tier = tier
			-- Read before building: tabVisible("Access") is evaluated during buildPanel.
			-- AdminService sets this attribute before AdminTier for exactly that reason.
			_isOwner = LocalPlayer:GetAttribute("IsPlaceOwner") == true
			buildPanel()
		end
	end

	ensure()
	if not _built then
		table.insert(_conns, LocalPlayer:GetAttributeChangedSignal("AdminTier"):Connect(ensure))
	end
end

function AdminController.Cleanup()
	for _, c in _conns do c:Disconnect() end
	table.clear(_conns)
	-- Before _gui:Destroy() below: the preview's orbit is reassigned per preview so it is
	-- not in _conns, and left connected it would keep posing a destroyed camera every frame.
	if _clearReviewPreview then _clearReviewPreview() end
	_clearReviewPreview = nil
	if _routesFolder then _routesFolder:Destroy() end
	clearInspectorVisuals()
	for _, bb in _speedBillboards do bb:Destroy() end
	table.clear(_speedBillboards)
	if _gui then _gui:Destroy() end
	_gui = nil
	_root = nil
	_title = nil
	_built = false
	_started = false
end

return AdminController
