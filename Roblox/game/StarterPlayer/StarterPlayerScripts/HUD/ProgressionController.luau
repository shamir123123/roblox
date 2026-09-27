--!strict
-- City Hall: the progression page, built on MenuScreenView so it reads exactly like the
-- other menu pages -- no boxed panels, content straight on the veiled city, a tan eyebrow
-- over a big light title, underlined tabs top-right, a capsule action bottom-right.
--   * Header: CITY HALL / the city's current milestone. Under it four facts -- XP to the next
--     milestone, earning pace, Development Points, map tiles -- and one thin progress bar.
--   * MILESTONES: the ladder on the left; the right column lists everything the selected
--     milestone pays and unlocks, and how far away it is at the current pace.
--   * DEVELOPMENT: every upgrade grouped by service on the left; the selected one on the
--     right, bought with the UNLOCK capsule. Selecting never spends points.
-- Renders SyncProgression (+ SyncTerritory for permits); unlocks via RequestDevUnlock. A
-- LIVE milestone crossing gets a banner + fanfare.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")

local playerScripts = script.Parent.Parent
local uiFolder = playerScripts:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local Icons = require(uiFolder:WaitForChild("Icons"))
local TopbarDock = require(uiFolder:WaitForChild("TopbarDock"))
local UITween = require(uiFolder:WaitForChild("UITween"))
local HudScale = require(uiFolder:WaitForChild("HudScale"))
local SoundFX = require(playerScripts:WaitForChild("Core"):WaitForChild("SoundFX"))
local MenuScreenView = require(playerScripts:WaitForChild("UICreation"):WaitForChild("MenuScreenView"))
local DevelopmentTree = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("DevelopmentTree"))
local MilestoneUnlocks = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("MilestoneUnlocks"))
local TerritoryGrid = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("TerritoryGrid"))

local ProgressionController = {}

local C = Theme.Color
local GLYPH = MenuScreenView.GLYPH_FONT -- Montserrat has no tick glyph
local tracked = MenuScreenView.tracked
local label = MenuScreenView.label
local ROW_H = 46
local LIST_SHARE = 0.4
local COL_GAP = 64
local FACTS_H = 64
local BANNER_SECONDS = 4
local BLUR_SIZE = 18

local _started = false
local _net: any = nil
local _launcher: Frame? = nil
local _screen: MenuScreenView.Screen? = nil
local _open = false
local _blur: BlurEffect? = nil
local _hidden: { ScreenGui } = {} -- the HUD and friends, put away while the page is up
local _tab = 1 -- 1 Milestones, 2 Development
local _tabs: MenuScreenView.Segment? = nil
local _unlockBtn: MenuScreenView.ActionButton? = nil
local _cols = {} :: { list: Frame?, detail: Frame? }
local _facts = {} :: { xp: TextLabel?, pace: TextLabel?, dp: TextLabel?, tiles: TextLabel?, fill: Frame? }
local _snap: any = nil
local _territory = { owned = 0, allowance = TerritoryGrid.START_TILES }
local _inGame = false
local _msSel: number? = nil -- selected milestone; nil = the next one
local _nodeSel: string? = nil
local _pageKey = ""
-- The next milestone's status line and bar, when it is the one on screen: XP moves them in
-- place instead of rebuilding the page (which would also reset the list's scroll).
local _live = {} :: { status: TextLabel?, fill: Frame? }
local _unlockCount = -1 -- -1 = no snapshot yet; first sync must not chime

-- == Helpers ===================================================================

local function formatInt(n: number): string
	local s = tostring(math.floor(math.max(0, n)))
	while true do
		local replaced: number
		s, replaced = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
		if replaced == 0 then break end
	end
	return s
end

-- "AdvancedWindTurbine" -> "Advanced Wind Turbine"
local function pretty(key: string): string
	return (key:gsub("(%l)(%u)", "%1 %2"))
end

local function ladder(): { any }
	return if _snap and typeof(_snap.milestones) == "table" then _snap.milestones else MilestoneUnlocks.Ladder
end

local function tier(): number
	return if _snap then tonumber(_snap.tier) or 1 else 1
end

local function xp(): number
	return if _snap then tonumber(_snap.xp) or 0 else 0
end

local function rate(): number
	return if _snap then tonumber(_snap.rate) or 0 else 0
end

local function dpAvailable(): number
	return if _snap and typeof(_snap.dp) == "table" then tonumber(_snap.dp.available) or 0 else 0
end

local function eta(target: number): string
	local left = target - xp()
	if left <= 0 then return "any moment now" end
	if rate() < 1 then return "grow the city to start earning" end
	local mins = left / rate()
	if mins < 90 then return ("about %d min at the current pace"):format(math.max(1, math.ceil(mins))) end
	return ("about %.1f h at the current pace"):format(mins / 60)
end

local function frame(parent: Instance, order: number?, h: number?): Frame
	local f = Instance.new("Frame")
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Size = UDim2.new(1, 0, 0, h or 0)
	if order then f.LayoutOrder = order end
	f.Parent = parent
	return f
end

local function progressBar(parent: Instance, frac: number, order: number?): Frame
	local track = frame(parent, order, 2)
	track.BackgroundColor3 = C.Stroke
	track.BackgroundTransparency = 0.8
	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = C.Accent
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(math.clamp(frac, 0, 1), 1)
	fill.Parent = track
	return fill
end

-- A section head in the detail column: tan eyebrow with breathing room above it.
local function section(parent: Instance, text: string, order: number)
	local holder = frame(parent, order, 44)
	local e = MenuScreenView.eyebrow(holder, text)
	e.Position = UDim2.fromOffset(0, 22)
end

-- Two-to-a-row facts (tracked key over a light value).
local function facts(parent: Instance, order: number, pairs_: { { string } })
	local grid = MenuScreenView.factGrid(parent, order)
	for i, p in pairs_ do
		MenuScreenView.fact(grid, p[1], i).Text = p[2]
	end
end

-- A line in a list: hover lifts it, the selected one gets a tan bar and full-white text.
local function listRow(parent: Instance, order: number, selected: boolean, onClick: () -> ()): TextButton
	local b = Instance.new("TextButton")
	b.AutoButtonColor = false
	b.Text = ""
	b.BackgroundColor3 = Color3.new(1, 1, 1)
	b.BackgroundTransparency = if selected then 0.93 else 1
	b.BorderSizePixel = 0
	b.Size = UDim2.new(1, 0, 0, ROW_H)
	b.LayoutOrder = order
	b.Parent = parent
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 4)
	c.Parent = b
	if selected then
		local bar = Instance.new("Frame")
		bar.BackgroundColor3 = C.Brand
		bar.BorderSizePixel = 0
		bar.Position = UDim2.fromOffset(0, 12)
		bar.Size = UDim2.new(0, 2, 1, -24)
		bar.Parent = b
	end
	b.MouseEnter:Connect(function() if not selected then b.BackgroundTransparency = 0.96 end end)
	b.MouseLeave:Connect(function() if not selected then b.BackgroundTransparency = 1 end end)
	b.Activated:Connect(function()
		SoundFX.play("Click")
		onClick()
	end)
	return b
end

local function trailing(row: Instance, text: string, font: Font, size: number, color: Color3, right: number, width: number?): TextLabel
	local l = label(row, text, font, size, color)
	l.TextXAlignment = Enum.TextXAlignment.Right
	l.AnchorPoint = Vector2.new(1, 0)
	l.Position = UDim2.new(1, -right, 0, 0)
	l.Size = UDim2.new(0, width or 160, 1, 0)
	return l
end

local function clear(parent: Instance)
	for _, child in parent:GetChildren() do
		if child:IsA("GuiObject") then child:Destroy() end
	end
end

-- == Header + facts =============================================================

local function renderHeader()
	local screen = _screen
	if not screen or not _facts.xp then return end
	local ms, t = ladder(), tier()
	local cur, nxt = ms[t], ms[t + 1]
	if not cur then return end
	screen.eyebrow.Text = tracked(("City Hall  \u{00B7}  Milestone %d of %d"):format(t, #ms))
	screen.title.Text = cur.name;
	(_facts.pace :: TextLabel).Text = ("%d XP / min"):format(rate());
	(_facts.dp :: TextLabel).Text = tostring(dpAvailable());
	(_facts.tiles :: TextLabel).Text = ("%d / %d"):format(_territory.owned, _territory.allowance)
	if nxt then
		(_facts.xp :: TextLabel).Text = ("%s / %s"):format(formatInt(xp()), formatInt(nxt.xp))
		UITween.to(_facts.fill :: Frame, "Flyout", { Size = UDim2.fromScale(math.clamp((xp() - cur.xp) / math.max(1, nxt.xp - cur.xp), 0, 1), 1) })
	else
		(_facts.xp :: TextLabel).Text = formatInt(xp());
		(_facts.fill :: Frame).Size = UDim2.fromScale(1, 1)
	end
end

-- == MILESTONES ================================================================

local function renderMilestoneList(col: Frame)
	local ms, t = ladder(), tier()
	local sel = math.clamp(_msSel or math.min(t + 1, #ms), 1, #ms)
	local scroll = MenuScreenView.scroller(col, 0)
	for i, m in ms do
		local reached = i <= t
		local isNext = i == t + 1
		local row = listRow(scroll, i, i == sel, function()
			_msSel = i
			_pageKey = ""
			ProgressionController.refresh()
		end)
		local num = label(row, string.format("%02d", i), Theme.Font.Bold, 12, if reached or isNext then C.Brand else C.TextDisabled)
		num.Position = UDim2.fromOffset(18, 0)
		num.Size = UDim2.new(0, 28, 1, 0)
		local name = label(row, m.name, if isNext or i == sel then Theme.Font.Header else Theme.Font.Label, 16,
			if reached or isNext or i == sel then C.TextPrimary else C.TextSecondary)
		name.Position = UDim2.fromOffset(56, 0)
		name.Size = UDim2.new(1, -230, 1, 0)
		trailing(row, if i == 1 then "Start" else formatInt(m.xp) .. " XP", Theme.Font.Label, 14, C.TextSecondary, 44)
		if reached then
			trailing(row, "\u{2713}", GLYPH, 15, C.Accent, 16, 20)
		elseif isNext then
			trailing(row, tracked("Next"), Theme.Font.Bold, 10, C.Accent, 8, 36)
		end
	end
	task.defer(function()
		if scroll.Parent then scroll.CanvasPosition = Vector2.new(0, math.max(0, (sel - 4) * ROW_H)) end
	end)
end

local function renderMilestoneDetail(col: Frame)
	local ms, t = ladder(), tier()
	local sel = math.clamp(_msSel or math.min(t + 1, #ms), 1, #ms)
	local m = ms[sel]
	local scroll = MenuScreenView.scroller(col, 0)
	local o = 0
	local function nextOrder(): number o += 1 return o end

	MenuScreenView.eyebrow(scroll, ("Milestone %d"):format(sel), nextOrder())
	local name = label(scroll, m.name, Theme.Font.Display, 34, C.TextPrimary)
	name.Size = UDim2.new(1, 0, 0, 44)
	name.LayoutOrder = nextOrder()

	local status = if sel <= t then "Reached."
		elseif sel == 1 then "Where every city starts."
		else ("%s XP to go \u{2014} %s."):format(formatInt(math.max(0, m.xp - xp())), eta(m.xp))
	local statusL = MenuScreenView.note(scroll, status, nextOrder())
	statusL.TextColor3 = if sel <= t then C.TextSecondary else C.TextPrimary
	if sel == t + 1 and ms[t] then
		frame(scroll, nextOrder(), 12)
		_live.status = statusL
		_live.fill = progressBar(scroll, (xp() - ms[t].xp) / math.max(1, m.xp - ms[t].xp), nextOrder())
	end

	section(scroll, "Rewards", nextOrder())
	local tiles = TerritoryGrid.allowanceFor(sel) - (if sel > 1 then TerritoryGrid.allowanceFor(sel - 1) else 0)
	facts(scroll, nextOrder(), {
		{ "Cash bonus", if m.money > 0 then "$" .. formatInt(m.money) else "\u{2014}" },
		{ "Development points", "+" .. m.dp },
		{ if sel == 1 then "Starting map tiles" else "Map tile permits", "+" .. tiles },
	})

	local grant = MilestoneUnlocks.get(sel)
	if not grant then return end
	section(scroll, "Unlocks", nextOrder())
	local function unlockLine(name: string, kind: string)
		local row = frame(scroll, nextOrder(), 34)
		local l = label(row, name, Theme.Font.Label, 16, C.TextPrimary)
		l.Size = UDim2.new(1, -170, 1, 0)
		trailing(row, kind, Theme.Font.Label, 13, C.TextSecondary, 0)
	end
	for _, z in grant.zones or {} do unlockLine(z .. " density housing", "Residential zone") end
	if grant.roads and #grant.roads > 0 then unlockLine("Streets and alleys", ("%d road types"):format(#grant.roads)) end
	for _, key in grant.placeables or {} do unlockLine(pretty(key), "Building") end
	frame(scroll, nextOrder(), 16)
	MenuScreenView.note(scroll, grant.summary, nextOrder())
end

-- == DEVELOPMENT ===============================================================

local function unlockedSet(): { [string]: boolean }
	local set: { [string]: boolean } = {}
	if _snap and typeof(_snap.unlocked) == "table" then
		for _, id in _snap.unlocked do set[id] = true end
	end
	return set
end

-- owned / ready / short (not enough DP) / locked (prerequisite missing), plus what is missing.
local function nodeState(node: any, owned: { [string]: boolean }): (string, { string })
	if owned[node.id] then return "owned", {} end
	local missing = {}
	for _, reqId in node.requires do
		if not owned[reqId] then
			local req = DevelopmentTree.ById[reqId]
			table.insert(missing, if req then req.name else reqId)
		end
	end
	if #missing > 0 then return "locked", missing end
	return if node.cost <= dpAvailable() then "ready" else "short", {}
end

local function renderDevList(col: Frame)
	local owned = unlockedSet()
	local scroll = MenuScreenView.scroller(col, 0)
	local o = 0
	for ci, cat in DevelopmentTree.Categories do
		o += 1
		local head = frame(scroll, o, if ci == 1 then 26 else 44)
		local e = MenuScreenView.eyebrow(head, cat)
		e.AnchorPoint = Vector2.new(0, 1)
		e.Position = UDim2.new(0, 18, 1, -4)
		for _, node in DevelopmentTree.Nodes do
			if node.cat ~= cat then continue end
			if not _nodeSel then _nodeSel = node.id end
			local s = nodeState(node, owned)
			o += 1
			local row = listRow(scroll, o, node.id == _nodeSel, function()
				_nodeSel = node.id
				_pageKey = ""
				ProgressionController.refresh()
			end)
			local name = label(row, node.name, if node.id == _nodeSel then Theme.Font.Header else Theme.Font.Label, 16,
				if s == "locked" then C.TextSecondary else C.TextPrimary)
			name.Position = UDim2.fromOffset(18, 0)
			name.Size = UDim2.new(1, -140, 1, 0)
			if s == "owned" then
				trailing(row, "\u{2713}", GLYPH, 15, C.Accent, 16, 20)
			else
				trailing(row, ("%d DP"):format(node.cost), Theme.Font.Header, 14,
					if s == "ready" then C.Accent else C.TextSecondary, 16)
			end
		end
	end
end

local function renderDevDetail(col: Frame)
	local owned = unlockedSet()
	local node = if _nodeSel then DevelopmentTree.ById[_nodeSel] else nil
	local btn = _unlockBtn :: MenuScreenView.ActionButton
	if not node then
		btn.setEnabled(false)
		return
	end
	local s, missing = nodeState(node, owned)
	local scroll = MenuScreenView.scroller(col, 0)
	MenuScreenView.eyebrow(scroll, ("%s  \u{00B7}  Tier %d"):format(node.cat, node.tier), 1)
	local name = label(scroll, node.name, Theme.Font.Display, 34, C.TextPrimary)
	name.Size = UDim2.new(1, 0, 0, 44)
	name.LayoutOrder = 2
	local desc = MenuScreenView.note(scroll, node.desc, 3)
	desc.TextColor3 = C.TextPrimary
	local reqNames = {}
	for _, reqId in node.requires do
		local req = DevelopmentTree.ById[reqId]
		table.insert(reqNames, if req then req.name else reqId)
	end
	section(scroll, "Details", 4)
	facts(scroll, 5, {
		{ "Cost", ("%d DP"):format(node.cost) },
		{ "Status", if s == "owned" then "Unlocked"
			elseif s == "ready" then "Available"
			elseif s == "short" then ("Needs %d more DP"):format(node.cost - dpAvailable())
			else "Locked" },
		{ "Requires", if #reqNames > 0 then table.concat(reqNames, ", ") else "\u{2014}" },
		{ "Available points", tostring(dpAvailable()) },
	})
	frame(scroll, 6, 16)
	MenuScreenView.note(scroll, if s == "locked" then ("Unlock %s first."):format(table.concat(missing, " and "))
		else "Development Points are earned at milestones. Finishing every milestone pays for the whole tree, so the choice is the order.", 7)

	btn.setText(if s == "owned" then "Unlocked" else ("Unlock  \u{2014}  %d DP"):format(node.cost))
	btn.setEnabled(s == "ready")
end

-- == Refresh ===================================================================

function ProgressionController.refresh()
	local list, detail = _cols.list, _cols.detail
	if not (_screen and _open and list and detail) then return end
	renderHeader()
	local unlocked = if _snap and typeof(_snap.unlocked) == "table" then #_snap.unlocked else 0
	local key = table.concat({ _tab, tier(), unlocked, dpAvailable(), tostring(_msSel), tostring(_nodeSel) }, "|")
	if key == _pageKey then
		local ms, t = ladder(), tier()
		local cur, nxt = ms[t], ms[t + 1]
		if _live.status and _live.fill and cur and nxt then
			_live.status.Text = ("%s XP to go \u{2014} %s."):format(formatInt(math.max(0, nxt.xp - xp())), eta(nxt.xp))
			UITween.to(_live.fill, "Flyout", { Size = UDim2.fromScale(math.clamp((xp() - cur.xp) / math.max(1, nxt.xp - cur.xp), 0, 1), 1) })
		end
		return
	end
	_pageKey = key
	_live.status, _live.fill = nil, nil
	clear(list)
	clear(detail)
	local btn = _unlockBtn :: MenuScreenView.ActionButton
	btn.Instance.Visible = _tab == 2
	if _tab == 2 then
		renderDevList(list)
		renderDevDetail(detail)
	else
		renderMilestoneList(list)
		renderMilestoneDetail(detail)
	end
end

local function setOpen(open: boolean)
	local screen = _screen
	if not screen or _open == open then return end
	_open = open
	local blur = _blur
	if not blur then
		blur = Instance.new("BlurEffect")
		blur.Name = "CityHallBlur"
		blur.Size = 0
		blur.Parent = Lighting
		_blur = blur
	end
	UITween.to(blur :: BlurEffect, "Modal", { Size = if open then BLUR_SIZE else 0 })
	-- The page owns the screen while it is up, as Settings does: every other gui steps aside.
	if open then
		table.clear(_hidden)
		for _, g in Players.LocalPlayer:WaitForChild("PlayerGui"):GetChildren() do
			if g:IsA("ScreenGui") and g ~= screen.gui and g.Enabled then
				g.Enabled = false
				table.insert(_hidden, g)
			end
		end
	else
		for _, g in _hidden do
			if g.Parent then g.Enabled = true end
		end
		table.clear(_hidden)
	end
	if open then
		SoundFX.play("Open")
		_msSel = nil
		_pageKey = ""
		if _tabs then _tabs.select(_tab) end
		screen.show()
		ProgressionController.refresh()
	else
		SoundFX.play("Close")
		screen.hide()
	end
end

-- == Celebration ===============================================================

local function celebrate(event: any)
	local cityUI = Players.LocalPlayer:WaitForChild("PlayerGui"):FindFirstChild("CityUI")
	if not cityUI then return end
	local group = Instance.new("CanvasGroup")
	group.Name = "MilestoneBanner"
	group.AnchorPoint = Vector2.new(0.5, 0.5)
	group.Position = UDim2.new(0.5, 0, 0.28, 0)
	group.Size = UDim2.fromOffset(760, 120)
	group.BackgroundTransparency = 1
	group.GroupTransparency = 1
	group.ZIndex = Theme.Z.Modal
	group.Parent = cityUI

	local cap = MenuScreenView.eyebrow(group, "Milestone reached")
	cap.TextXAlignment = Enum.TextXAlignment.Center
	local name = label(group, tostring(event.name), Theme.Font.Display, 54, C.TextPrimary)
	name.TextXAlignment = Enum.TextXAlignment.Center
	name.Position = UDim2.fromOffset(0, 22)
	name.Size = UDim2.new(1, 0, 0, 62)
	local bits = {}
	if (tonumber(event.reward) or 0) > 0 then table.insert(bits, "$" .. formatInt(tonumber(event.reward) or 0)) end
	if (tonumber(event.dp) or 0) > 0 then table.insert(bits, ("%d Development Points"):format(tonumber(event.dp) or 0)) end
	if (tonumber(event.tiles) or 0) > 0 then table.insert(bits, ("%d map tile permits"):format(tonumber(event.tiles) or 0)) end
	local sub = label(group, table.concat(bits, "   \u{00B7}   "), Theme.Font.Label, 16, C.TextSecondary)
	sub.TextXAlignment = Enum.TextXAlignment.Center
	sub.Position = UDim2.fromOffset(0, 90)
	sub.Size = UDim2.new(1, 0, 0, 20)

	UITween.to(group, "Modal", { GroupTransparency = 0 })
	task.delay(BANNER_SECONDS, function()
		if not group.Parent then return end
		UITween.to(group, "Modal", { GroupTransparency = 1 }).Completed:Once(function()
			group:Destroy()
		end)
	end)
end

-- == Build =====================================================================

local function buildLauncher(cityUI: ScreenGui)
	local holder = Instance.new("Frame")
	holder.Name = "CityHallLauncher"
	holder.BackgroundTransparency = 1
	holder.Visible = false
	holder.Parent = cityUI

	local launcher = Instance.new("TextButton")
	launcher.Name = "Chip"
	launcher.AutoButtonColor = false
	launcher.Text = ""
	launcher.AnchorPoint = Vector2.new(0.5, 0.5)
	launcher.Position = UDim2.fromScale(0.5, 0.5)
	launcher.BackgroundColor3 = C.BgPress
	launcher.BackgroundTransparency = 0.1
	local lc = Instance.new("UICorner")
	lc.CornerRadius = UDim.new(1, 0)
	lc.Parent = launcher
	launcher.Parent = holder
	local gIcon = Instance.new("ImageLabel")
	gIcon.BackgroundTransparency = 1
	gIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	gIcon.Position = UDim2.fromScale(0.5, 0.5)
	gIcon.Size = UDim2.fromScale(0.6, 0.6)
	gIcon.ScaleType = Enum.ScaleType.Fit
	gIcon.Image = Icons.Monument.image
	gIcon.ImageColor3 = C.TextPrimary
	gIcon.Parent = launcher

	TopbarDock.bind(cityUI, function(x0, top, h)
		holder.Position = UDim2.fromOffset(TopbarDock.slot(x0, h, 1), top)
		holder.Size = UDim2.fromOffset(h, h)
		launcher.Size = UDim2.fromOffset(h, h)
	end)
	launcher.MouseEnter:Connect(function()
		launcher.BackgroundTransparency = 0
		gIcon.ImageColor3 = Color3.new(1, 1, 1)
	end)
	launcher.MouseLeave:Connect(function()
		launcher.BackgroundTransparency = 0.1
		gIcon.ImageColor3 = C.TextPrimary
	end)
	launcher.MouseButton1Click:Connect(function()
		setOpen(not _open)
	end)
	_launcher = holder
end

local function buildScreen(playerGui: PlayerGui)
	local screen = MenuScreenView.screen(playerGui, "CityHall", "City Hall", "", function() setOpen(false) end)
	HudScale.attach(screen.gui)
	_screen = screen

	_tabs = MenuScreenView.tabs(screen.tabs, { "Milestones", "Development" }, function(i)
		_tab = i
		_pageKey = ""
		ProgressionController.refresh()
	end)

	-- The four figures, one progress bar under them, then the two columns.
	local top = frame(screen.body, nil, FACTS_H)
	local grid = MenuScreenView.factGrid(top, 1)
	local layout = grid:FindFirstChildOfClass("UIGridLayout") :: UIGridLayout
	layout.CellSize = UDim2.new(0.25, -12, 0, 50)
	_facts.xp = MenuScreenView.fact(grid, "Experience", 1)
	_facts.pace = MenuScreenView.fact(grid, "Earning", 2)
	_facts.dp = MenuScreenView.fact(grid, "Development points", 3)
	_facts.tiles = MenuScreenView.fact(grid, "Map tiles", 4)
	local barHolder = frame(screen.body, nil, 2)
	barHolder.Position = UDim2.fromOffset(0, FACTS_H + 4)
	_facts.fill = progressBar(barHolder, 0)
	;(_facts.fill.Parent :: Frame).Size = UDim2.fromScale(1, 1)

	local colTop = FACTS_H + 34
	local list = frame(screen.body)
	list.Position = UDim2.fromOffset(0, colTop)
	list.Size = UDim2.new(LIST_SHARE, 0, 1, -(colTop + 64))
	local detail = frame(screen.body)
	detail.Position = UDim2.new(LIST_SHARE, COL_GAP, 0, colTop)
	detail.Size = UDim2.new(1 - LIST_SHARE, -COL_GAP, 1, -(colTop + 64))
	_cols.list, _cols.detail = list, detail

	_unlockBtn = MenuScreenView.actionButton(screen.footer, "Unlock", true, 1, function()
		if _nodeSel then _net.RequestDevUnlock:FireServer(_nodeSel) end
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if _open and not processed and input.KeyCode == Enum.KeyCode.Escape then setOpen(false) end
	end)
end

-- == Wiring ====================================================================

local function onSnapshot(payload: any)
	if typeof(payload) ~= "table" or typeof(payload.tier) ~= "number" then return end
	_snap = payload
	local n = if typeof(payload.unlocked) == "table" then #payload.unlocked else 0
	if _inGame and _unlockCount >= 0 and n > _unlockCount then SoundFX.play("Success") end
	_unlockCount = n
	ProgressionController.refresh()

	local event = payload.event
	if _inGame and typeof(event) == "table" and event.type == "milestone" and typeof(event.name) == "string" then
		SoundFX.play("Milestone")
		celebrate(event)
	end
end

function ProgressionController.Start()
	if _started then return end
	_started = true

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
	buildLauncher(playerGui:WaitForChild("CityUI") :: ScreenGui)
	buildScreen(playerGui)

	_net = require(ReplicatedStorage:WaitForChild("Networker"))
	_net.SyncProgression.OnClientEvent:Connect(onSnapshot)
	_net.SyncTerritory.OnClientEvent:Connect(function(snap: any)
		if typeof(snap) ~= "table" then return end
		_territory.owned = if typeof(snap.owned) == "table" then #snap.owned else _territory.owned
		_territory.allowance = tonumber(snap.allowance) or _territory.allowance
		if _open then renderHeader() end
	end)

	local UIEvents = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("UIEvents"))
	UIEvents.GameEntered.Event:Connect(function()
		_inGame = true
		if _launcher then (_launcher :: Frame).Visible = true end
	end)
	UIEvents.SettingsOpened.Event:Connect(function()
		setOpen(false)
	end)
	UIEvents.ReturnToMainMenu.Event:Connect(function()
		_inGame = false
		if _launcher then (_launcher :: Frame).Visible = false end
		setOpen(false)
	end)
end

return ProgressionController
