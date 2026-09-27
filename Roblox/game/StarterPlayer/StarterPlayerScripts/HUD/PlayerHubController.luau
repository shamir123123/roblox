--!strict
-- PLAYER HUB: the player's own panel -- profile, city vitals, economy and quick
-- actions -- behind the HUB button at the right-hand end of the tool rail (or H).
-- Replaces the two-row Info Hub popover that used to live in the old HUDController
-- (now HUD.GameMenuController, which keeps only the pause menu).
--
-- Chrome is the shared HUD chrome, unchanged: Kit.Glass panel, Theme radii and
-- type, capsule Kit buttons, circular icon chips, powder-blue accent, Brand
-- eyebrow headings. Nothing here has its own skin.
--
-- Every page assembles from the builders below (sectionCard / statRow / barRow /
-- statTile), so a future page costs almost nothing. Read-only except the
-- Settings actions; data rides the existing SyncCityStats / SyncEconomy /
-- SyncProgression feeds -- no new server traffic.
--
-- Layout: nav rail left, then TWO independent card columns. newPage hands each
-- builder a left and a right column and the cards stack in whichever they are
-- given, so a tall card on one side never drags the other side down with it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local uiFolder = script.Parent.Parent:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local Icons = require(uiFolder:WaitForChild("Icons"))
local UITween = require(uiFolder:WaitForChild("UITween"))
local Format = require(uiFolder:WaitForChild("Format"))
local HudScale = require(uiFolder:WaitForChild("HudScale"))
local kit = uiFolder:WaitForChild("Kit")
local Modal = require(kit:WaitForChild("Modal"))
local Button = require(kit:WaitForChild("Button"))
local Divider = require(kit:WaitForChild("Divider"))
local SoundFX = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("SoundFX"))
local UIEvents = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("UIEvents"))

local PlayerHubController = {}

local PANEL_W = 1040
local PANEL_H = 620
local NAV_W = 212
local COL_GAP = Theme.Pad.LG -- gutter between the two card columns

-- Semantic zone colours (content, not chrome -- same values as the HUD bars).
local ZONE_COLOR = {
	R = Color3.fromRGB(82, 196, 110),
	C = Color3.fromRGB(70, 160, 230),
	I = Color3.fromRGB(220, 185, 55),
}

local PAGES = {
	{ key = "Overview", title = "Overview", icon = Icons.Dashboard },
	{ key = "City", title = "My City", icon = Icons.Monument },
	{ key = "Economy", title = "Economy", icon = Icons.Economy },
	{ key = "Settings", title = "Settings", icon = Icons.Settings },
}

-- Dashboards the hub hands off to. These are the old Info Hub rows.
local DASHBOARDS = {
	{ key = "Stats", icon = Icons.Stats, label = "City Dashboard", desc = "deep stats \u{00B7} population \u{00B7} services" },
	{ key = "Economy", icon = Icons.Economy, label = "Economy & Taxes", desc = "budget \u{00B7} tax rates \u{00B7} upkeep" },
	{ key = "Transport", icon = Icons.Transport, label = "Transport", desc = "public transit routes" },
}

local _started = false
local _modal: any = nil
local _open = false
local _inGame = false
local _pages: { [string]: ScrollingFrame } = {}
local _nav: { [string]: (boolean) -> () } = {}
local _tierLabel: TextLabel? = nil
local _conns: { RBXScriptConnection } = {}

-- Latest sync payloads + per-widget refreshers. Widgets register a callback at
-- build time; the sync handlers just re-run the relevant list.
local _stats: any = nil
local _econ: any = nil
local _snap: any = nil
local _statsSubs: { () -> () } = {}
local _econSubs: { () -> () } = {}
local _progSubs: { () -> () } = {}
-- The player's lifetime record. Pulled on open (RequestPlayerStats), not streamed --
-- it changes on the order of minutes, so a live feed would be pure waste.
local _you: any = nil
local _youSubs: { () -> () } = {}

local Net: any = nil

-- ===================================================================
--  small shared helpers
-- ===================================================================
local function corner(inst: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = inst
end

local function formatDate(epoch: number): string
	if epoch <= 0 then
		return "\u{2014}"
	end
	return os.date("!%d %b %Y", math.floor(epoch))
end

local function label(parent: Instance, size: UDim2, text: string, textSize: number, color: Color3, font: Font, xAlign: Enum.TextXAlignment): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = size
	l.Text = text
	l.TextSize = textSize
	l.TextColor3 = color
	l.FontFace = font
	l.TextXAlignment = xAlign
	l.TextTruncate = Enum.TextTruncate.AtEnd
	l.Parent = parent
	return l
end

-- Normalised 0..1 bar setter; accepts 0..1 or 0..100 server scales.
local function setFrac(fill: Frame, valueLabel: TextLabel, raw: any)
	local v = tonumber(raw)
	if not v then
		valueLabel.Text = "\u{2014}"
		return
	end
	if v > 1 then
		v /= 100
	end
	v = math.clamp(v, 0, 1)
	UITween.to(fill, "Flyout", { Size = UDim2.new(v, 0, 1, 0) })
	valueLabel.Text = string.format("%d%%", math.floor(v * 100 + 0.5))
end

-- Circular hairline icon chip -- the HUD's one icon container.
local function iconChip(parent: Instance, px: number, icon: Icons.Icon): Frame
	local chip = Instance.new("Frame")
	chip.Name = "Chip"
	chip.BackgroundColor3 = Theme.Color.BgPress
	chip.BackgroundTransparency = 0.35
	chip.BorderSizePixel = 0
	chip.Size = UDim2.fromOffset(px, px)
	chip.Parent = parent

	local cc = Instance.new("UICorner")
	cc.CornerRadius = UDim.new(1, 0)
	cc.Parent = chip

	local cs = Instance.new("UIStroke")
	cs.Color = Theme.Glass.StrokeColor
	cs.Transparency = 0.55
	cs.Thickness = Theme.StrokeWidth.Thin
	cs.Parent = chip

	local img = Instance.new("ImageLabel")
	img.Name = "Icon"
	img.BackgroundTransparency = 1
	img.AnchorPoint = Vector2.new(0.5, 0.5)
	img.Position = UDim2.fromScale(0.5, 0.5)
	img.Size = UDim2.fromScale(0.58, 0.58)
	img.ScaleType = Enum.ScaleType.Fit
	img.Image = icon.image
	img.ImageColor3 = Theme.Color.TextPrimary
	img.Parent = chip

	return chip
end

-- ===================================================================
--  REUSABLE PANELS: every page is assembled from these, so all hub
--  surfaces stay identical and a future page costs almost nothing.
-- ===================================================================

-- Card with a Brand eyebrow heading and a vertical list inside.
local function sectionCard(parent: Instance, order: number, eyebrow: string): Frame
	local card = Instance.new("Frame")
	card.Name = eyebrow
	card.BackgroundColor3 = Theme.Color.BgRaised
	card.BackgroundTransparency = 0.25
	card.BorderSizePixel = 0
	card.Size = UDim2.new(1, 0, 0, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.LayoutOrder = order
	card.Parent = parent
	corner(card, Theme.Radius.MD)

	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Glass.StrokeColor
	stroke.Transparency = 0.78
	stroke.Thickness = Theme.StrokeWidth.Thin
	stroke.Parent = card

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, Theme.Pad.LG)
	pad.PaddingBottom = UDim.new(0, Theme.Pad.LG)
	pad.PaddingLeft = UDim.new(0, Theme.Pad.LG)
	pad.PaddingRight = UDim.new(0, Theme.Pad.LG)
	pad.Parent = card

	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, Theme.Pad.SM)
	list.Parent = card

	local head = label(card, UDim2.new(1, 0, 0, 14), string.upper(eyebrow), Theme.TextSize.XS, Theme.Color.Brand, Theme.Font.Bold, Enum.TextXAlignment.Left)
	head.LayoutOrder = 0
	return card
end

-- One label/value row. Returns the value TextLabel for live updates.
local function statRow(parent: Instance, order: number, labelText: string, big: boolean?): TextLabel
	local row = Instance.new("Frame")
	row.Name = labelText
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, if big then 38 else 28)
	row.LayoutOrder = order
	row.Parent = parent

	local l = label(row, UDim2.new(0.55, 0, 1, 0), labelText, Theme.TextSize.SM, Theme.Color.TextSecondary, Theme.Font.Label, Enum.TextXAlignment.Left)
	l.AnchorPoint = Vector2.new(0, 0.5)
	l.Position = UDim2.fromScale(0, 0.5)

	local value = label(row, UDim2.new(0.45, 0, 1, 0), "\u{2014}", if big then Theme.TextSize.LG else Theme.TextSize.SM, Theme.Color.TextPrimary, if big then Theme.Font.Bold else Theme.Font.Header, Enum.TextXAlignment.Right)
	value.Name = "Value"
	value.AnchorPoint = Vector2.new(1, 0.5)
	value.Position = UDim2.fromScale(1, 0.5)
	return value
end

-- A labelled progress bar (0..1). Returns (fill, value label).
local function barRow(parent: Instance, order: number, labelText: string, color: Color3): (Frame, TextLabel)
	local row = Instance.new("Frame")
	row.Name = labelText
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 32)
	row.LayoutOrder = order
	row.Parent = parent

	label(row, UDim2.new(1, 0, 0, 16), labelText, Theme.TextSize.XS, Theme.Color.TextSecondary, Theme.Font.Label, Enum.TextXAlignment.Left)
	local value = label(row, UDim2.new(1, 0, 0, 16), "\u{2014}", Theme.TextSize.XS, Theme.Color.TextPrimary, Theme.Font.Header, Enum.TextXAlignment.Right)
	value.Name = "Value"

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0, 1)
	track.Position = UDim2.fromScale(0, 1)
	track.Size = UDim2.new(1, 0, 0, 6)
	track.BackgroundColor3 = Theme.Color.BgPress
	track.BorderSizePixel = 0
	track.ClipsDescendants = true
	track.Parent = row
	corner(track, 3)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.Parent = track
	corner(fill, 3)

	return fill, value
end

-- Grid tile: caption on top, big value below. Returns the value label.
local function statTile(parent: Instance, order: number, caption: string): TextLabel
	local tile = Instance.new("Frame")
	tile.Name = caption
	tile.BackgroundColor3 = Theme.Color.Bg
	tile.BackgroundTransparency = 0.2
	tile.BorderSizePixel = 0
	tile.LayoutOrder = order
	tile.Parent = parent
	corner(tile, Theme.Radius.SM)

	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Glass.StrokeColor
	stroke.Transparency = 0.85
	stroke.Thickness = Theme.StrokeWidth.Thin
	stroke.Parent = tile

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, Theme.Pad.MD)
	pad.PaddingBottom = UDim.new(0, Theme.Pad.MD)
	pad.PaddingLeft = UDim.new(0, Theme.Pad.LG)
	pad.PaddingRight = UDim.new(0, Theme.Pad.LG)
	pad.Parent = tile

	label(tile, UDim2.new(1, 0, 0, 12), caption, Theme.TextSize.XS, Theme.Color.TextSecondary, Theme.Font.Label, Enum.TextXAlignment.Left)
	local value = label(tile, UDim2.new(1, 0, 0, 22), "\u{2014}", Theme.TextSize.LG, Theme.Color.TextPrimary, Theme.Font.Bold, Enum.TextXAlignment.Left)
	value.AnchorPoint = Vector2.new(0, 1)
	value.Position = UDim2.new(0, 0, 1, 0)
	return value
end

-- Milestone summary. Progress is XP against the next milestone's XP gate --
-- the same ladder ProgressionService replicates, not a population guess.
local function milestoneBlock(parent: Instance, order: number)
	local card = sectionCard(parent, order, "Milestone")

	local tierName = label(card, UDim2.new(1, 0, 0, 24), "\u{2014}", Theme.TextSize.LG, Theme.Color.TextPrimary, Theme.Font.Bold, Enum.TextXAlignment.Left)
	tierName.LayoutOrder = 1

	local track = Instance.new("Frame")
	track.BackgroundColor3 = Theme.Color.BgPress
	track.BorderSizePixel = 0
	track.Size = UDim2.new(1, 0, 0, 8)
	track.LayoutOrder = 2
	track.ClipsDescendants = true
	track.Parent = card
	corner(track, 4)

	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = Theme.Color.Brand
	fill.BorderSizePixel = 0
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.Parent = track
	corner(fill, 4)

	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 14)
	row.LayoutOrder = 3
	row.Parent = card
	local xpL = label(row, UDim2.new(0.5, 0, 1, 0), "", Theme.TextSize.XS, Theme.Color.TextSecondary, Theme.Font.Label, Enum.TextXAlignment.Left)
	local nextL = label(row, UDim2.new(0.5, 0, 1, 0), "", Theme.TextSize.XS, Theme.Color.TextSecondary, Theme.Font.Label, Enum.TextXAlignment.Right)
	nextL.Position = UDim2.new(0.5, 0, 0, 0)
	xpL.Name = "Xp"

	table.insert(_progSubs, function()
		if typeof(_snap) ~= "table" or typeof(_snap.milestones) ~= "table" then
			return
		end
		local ms = _snap.milestones
		local tier = math.max(1, math.floor(tonumber(_snap.tier) or 1))
		local cur = ms[tier]
		local nxt = ms[tier + 1]
		if typeof(cur) ~= "table" then
			return
		end
		local xp = tonumber(_snap.xp) or 0
		tierName.Text = tostring(cur.name)
		if _tierLabel then
			(_tierLabel :: TextLabel).Text = string.upper(tostring(cur.name))
		end
		if typeof(nxt) == "table" then
			local curXp = tonumber(cur.xp) or 0
			local span = math.max(1, (tonumber(nxt.xp) or 1) - curXp)
			local frac = math.clamp((xp - curXp) / span, 0, 1)
			UITween.to(fill, "Flyout", { Size = UDim2.new(frac, 0, 1, 0) })
			xpL.Text = Format.int(xp) .. " / " .. Format.int(tonumber(nxt.xp) or 0) .. " XP"
			nextL.Text = Format.money(tonumber(nxt.money) or 0) .. " at " .. tostring(nxt.name)
		else
			fill.Size = UDim2.new(1, 0, 1, 0)
			xpL.Text = Format.int(xp) .. " XP"
			nextL.Text = "Top milestone reached"
		end
	end)
end

-- ===================================================================
--  navigation
-- ===================================================================
local function selectPage(key: string)
	for k, setSelected in _nav do
		setSelected(k == key)
	end
	for k, page in _pages do
		page.Visible = k == key
	end
end

-- Sidebar row: accent text/icon + a 3px accent bar when active.
local function navRow(parent: Instance, order: number, key: string, icon: Icons.Icon, text: string)
	local row = Instance.new("TextButton")
	row.Name = key
	row.AutoButtonColor = false
	row.Text = ""
	row.BackgroundColor3 = Theme.Color.BgRaised
	row.BackgroundTransparency = 1
	row.BorderSizePixel = 0
	row.Size = UDim2.new(1, 0, 0, 44)
	row.LayoutOrder = order
	row.Parent = parent
	corner(row, Theme.Radius.MD)

	local bar = Instance.new("Frame")
	bar.Name = "Active"
	bar.AnchorPoint = Vector2.new(0, 0.5)
	bar.Position = UDim2.new(0, 5, 0.5, 0)
	bar.Size = UDim2.fromOffset(3, 0)
	bar.BackgroundColor3 = Theme.Color.Accent
	bar.BorderSizePixel = 0
	bar.Parent = row
	corner(bar, 2)

	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency = 1
	img.AnchorPoint = Vector2.new(0, 0.5)
	img.Position = UDim2.new(0, 18, 0.5, 0)
	img.Size = UDim2.fromOffset(18, 18)
	img.ScaleType = Enum.ScaleType.Fit
	img.Image = icon.image
	img.ImageColor3 = Theme.Color.TextSecondary
	img.Parent = row

	local lbl = label(row, UDim2.new(1, -52, 1, 0), string.upper(text), Theme.TextSize.SM, Theme.Color.TextSecondary, Theme.Font.Header, Enum.TextXAlignment.Left)
	lbl.Position = UDim2.fromOffset(46, 0)

	local selected = false
	local hovered = false
	local function apply()
		local textColor = if selected then Theme.Color.Accent
			elseif hovered then Theme.Color.TextPrimary
			else Theme.Color.TextSecondary
		UITween.to(lbl, "Hover", { TextColor3 = textColor })
		UITween.to(img, "Hover", { ImageColor3 = textColor })
		UITween.to(row, "Hover", {
			BackgroundTransparency = if selected then 0.25 elseif hovered then 0.5 else 1,
			BackgroundColor3 = if hovered and not selected then Theme.Color.BgHover else Theme.Color.BgRaised,
		})
		UITween.to(bar, "Hover", { Size = UDim2.fromOffset(3, if selected then 20 else 0) })
	end

	table.insert(_conns, row.MouseEnter:Connect(function()
		hovered = true
		apply()
	end))
	table.insert(_conns, row.MouseLeave:Connect(function()
		hovered = false
		apply()
	end))
	table.insert(_conns, row.Activated:Connect(function()
		SoundFX.play("Tab")
		selectPage(key)
	end))

	_nav[key] = function(value: boolean)
		if selected == value then
			return
		end
		selected = value
		apply()
	end
end

-- ===================================================================
--  pages (each one is just cards + rows from the builders above)
-- ===================================================================
-- One scroller holding two half-width columns. Returns both: the caller decides
-- which side each card goes on.
local function newPage(parent: Instance, key: string): (Frame, Frame)
	local page = Instance.new("ScrollingFrame")
	page.Name = key
	page.BackgroundTransparency = 1
	page.BorderSizePixel = 0
	page.Size = UDim2.fromScale(1, 1)
	page.ScrollBarThickness = 4
	page.ScrollBarImageColor3 = Theme.Color.Accent
	page.ScrollingDirection = Enum.ScrollingDirection.Y
	page.CanvasSize = UDim2.new()
	page.AutomaticCanvasSize = Enum.AutomaticSize.Y
	page.Visible = false
	page.Parent = parent

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.VerticalAlignment = Enum.VerticalAlignment.Top
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, COL_GAP)
	list.Parent = page

	local pad = Instance.new("UIPadding")
	pad.PaddingRight = UDim.new(0, Theme.Pad.MD) -- air for the scrollbar
	pad.PaddingBottom = UDim.new(0, Theme.Pad.MD)
	pad.Parent = page

	local function column(order: number): Frame
		local col = Instance.new("Frame")
		col.Name = "Column" .. order
		col.BackgroundTransparency = 1
		col.Size = UDim2.new(0.5, -COL_GAP / 2, 0, 0)
		col.AutomaticSize = Enum.AutomaticSize.Y
		col.LayoutOrder = order
		col.Parent = page

		local colList = Instance.new("UIListLayout")
		colList.SortOrder = Enum.SortOrder.LayoutOrder
		colList.Padding = UDim.new(0, Theme.Pad.LG)
		colList.Parent = col
		return col
	end

	_pages[key] = page
	return column(1), column(2)
end

-- Hand-off to a full dashboard. Kept out of the row builder so the hub never
-- holds a hard reference to panels it only launches.
local function openDashboard(key: string)
	local core = script.Parent
	local name = if key == "Stats" then "DashboardController"
		elseif key == "Economy" then "EconomyPanelController"
		else "TransportOverviewController"
	local ok, m = pcall(function()
		return require(core:WaitForChild(name, 5))
	end)
	if not ok or not m then
		warn("[PlayerHub] dashboard " .. name .. " unavailable")
		return
	end
	if key == "Stats" then
		(m :: any).Toggle("Overview")
	elseif key == "Economy" then
		(m :: any).Toggle("Budget")
	else
		(m :: any).Toggle()
	end
end

local function dashboardRow(parent: Instance, order: number, entry: { key: string, icon: Icons.Icon, label: string, desc: string })
	local row = Instance.new("TextButton")
	row.Name = entry.key
	row.AutoButtonColor = false
	row.Text = ""
	row.BackgroundColor3 = Theme.Color.Bg
	row.BackgroundTransparency = 0.2
	row.BorderSizePixel = 0
	row.Size = UDim2.new(1, 0, 0, 48)
	row.LayoutOrder = order
	row.Parent = parent
	corner(row, Theme.Radius.SM)

	local chip = iconChip(row, 34, entry.icon)
	chip.AnchorPoint = Vector2.new(0, 0.5)
	chip.Position = UDim2.new(0, 6, 0.5, 0)

	local lbl = label(row, UDim2.new(1, -58, 0, 18), entry.label, Theme.TextSize.SM, Theme.Color.TextPrimary, Theme.Font.Bold, Enum.TextXAlignment.Left)
	lbl.AnchorPoint = Vector2.new(0, 0.5)
	lbl.Position = UDim2.new(0, 48, 0.5, -8)

	local sub = label(row, UDim2.new(1, -58, 0, 14), entry.desc, Theme.TextSize.XS, Theme.Color.TextSecondary, Theme.Font.Label, Enum.TextXAlignment.Left)
	sub.AnchorPoint = Vector2.new(0, 0.5)
	sub.Position = UDim2.new(0, 48, 0.5, 9)

	local key = entry.key
	table.insert(_conns, row.MouseEnter:Connect(function()
		UITween.to(row, "Hover", { BackgroundColor3 = Theme.Color.BgHover })
	end))
	table.insert(_conns, row.MouseLeave:Connect(function()
		UITween.to(row, "Hover", { BackgroundColor3 = Theme.Color.Bg })
	end))
	table.insert(_conns, row.Activated:Connect(function()
		SoundFX.play("Click")
		PlayerHubController.Close()
		openDashboard(key)
	end))
end

-- The player's own numbers, as opposed to the city's. Everything here is lifetime and
-- cross-city: it survives deleting a save.
local function buildYourRecord(parent: Instance, order: number)
	local card = sectionCard(parent, order, "Your record")
	local timeV = statRow(card, 1, "Time played", true)
	local sinceV = statRow(card, 2, "Playing since")
	local sessionsV = statRow(card, 3, "Sessions")
	local citiesV = statRow(card, 4, "Cities founded")
	local peakV = statRow(card, 5, "Best population")
	local bpV = statRow(card, 6, "Blueprints saved")

	table.insert(_youSubs, function()
		if typeof(_you) ~= "table" then
			return
		end
		timeV.Text = Format.duration(tonumber(_you.playSeconds) or 0)
		sinceV.Text = formatDate(tonumber(_you.firstJoinAt) or 0)
		sessionsV.Text = Format.int(tonumber(_you.sessions) or 0)
		citiesV.Text = Format.int(tonumber(_you.citiesCreated) or 0)
		peakV.Text = Format.int(tonumber(_you.peakPopulation) or 0)
		bpV.Text = Format.int(tonumber(_you.blueprints) or 0)
	end)
end

local function buildOverview(left: Frame, right: Frame)
	local glance = sectionCard(left, 1, "At a glance")

	local grid = Instance.new("Frame")
	grid.Name = "Tiles"
	grid.BackgroundTransparency = 1
	grid.Size = UDim2.new(1, 0, 0, 156)
	grid.LayoutOrder = 1
	grid.Parent = glance
	local gl = Instance.new("UIGridLayout")
	gl.CellSize = UDim2.new(0.5, -5, 0, 74)
	gl.CellPadding = UDim2.fromOffset(8, 8)
	gl.SortOrder = Enum.SortOrder.LayoutOrder
	gl.Parent = grid

	local popV = statTile(grid, 1, "POPULATION")
	local moneyV = statTile(grid, 2, "TREASURY")
	local netV = statTile(grid, 3, "NET / DAY")
	local happyV = statTile(grid, 4, "HAPPINESS")

	table.insert(_statsSubs, function()
		if typeof(_stats) ~= "table" then
			return
		end
		popV.Text = Format.int(tonumber(_stats.population) or 0)
		local h = tonumber(_stats.happiness)
		if h then
			if h > 1 then
				h /= 100
			end
			happyV.Text = string.format("%d%%", math.floor(math.clamp(h, 0, 1) * 100 + 0.5))
		end
	end)
	table.insert(_econSubs, function()
		if typeof(_econ) ~= "table" then
			return
		end
		moneyV.Text = Format.money(tonumber(_econ.money) or 0)
		local net = tonumber(_econ.net) or 0
		netV.Text = Format.signed(net)
		netV.TextColor3 = if net >= 0 then Theme.Color.Positive else Theme.Color.Danger
	end)

	buildYourRecord(left, 2)

	milestoneBlock(right, 1)
	local dash = sectionCard(right, 2, "Dashboards")
	for i, entry in DASHBOARDS do
		dashboardRow(dash, i, entry)
	end
end

local function buildCity(left: Frame, right: Frame)
	local popCard = sectionCard(left, 1, "Population")
	local popV = statRow(popCard, 1, "Residents", true)
	local jobsV = statRow(popCard, 2, "Jobs")
	local eduFill, eduV = barRow(popCard, 3, "Education", Theme.Color.Accent)
	local hapFill, hapV = barRow(popCard, 4, "Happiness", Theme.Color.Positive)

	local demandCard = sectionCard(right, 1, "Zone demand")
	local rFill, rV = barRow(demandCard, 1, "Residential", ZONE_COLOR.R)
	local cFill, cV = barRow(demandCard, 2, "Commercial", ZONE_COLOR.C)
	local iFill, iV = barRow(demandCard, 3, "Industrial", ZONE_COLOR.I)

	table.insert(_statsSubs, function()
		if typeof(_stats) ~= "table" then
			return
		end
		popV.Text = Format.int(tonumber(_stats.population) or 0)
		jobsV.Text = Format.int(tonumber(_stats.jobs) or 0)
		setFrac(eduFill, eduV, _stats.education)
		setFrac(hapFill, hapV, _stats.happiness)
		if typeof(_stats.demand) == "table" then
			setFrac(rFill, rV, _stats.demand.R)
			setFrac(cFill, cV, _stats.demand.C)
			setFrac(iFill, iV, _stats.demand.I)
		end
	end)
end

local function buildEconomy(left: Frame, right: Frame)
	local treasury = sectionCard(left, 1, "Treasury")
	local moneyV = statRow(treasury, 1, "Balance", true)
	local netV = statRow(treasury, 2, "Net income / day")
	local upkeepV = statRow(treasury, 3, "Monthly upkeep")

	local goods = sectionCard(right, 1, "Industry & goods")
	local outV = statRow(goods, 1, "Industrial output")
	local needV = statRow(goods, 2, "Commercial need")
	local supFill, supV = barRow(goods, 3, "Goods supply", Theme.Color.Accent)

	table.insert(_econSubs, function()
		if typeof(_econ) ~= "table" then
			return
		end
		moneyV.Text = Format.money(tonumber(_econ.money) or 0)
		local net = tonumber(_econ.net) or 0
		netV.Text = Format.signed(net)
		netV.TextColor3 = if net >= 0 then Theme.Color.Positive else Theme.Color.Danger
		upkeepV.Text = Format.money(tonumber(_econ.monthlyUpkeep) or 0)
		outV.Text = Format.int(tonumber(_econ.output) or 0)
		needV.Text = Format.int(tonumber(_econ.need) or 0)
		setFrac(supFill, supV, _econ.supplyRatio)
	end)
end

local function buildSettings(left: Frame, right: Frame)
	local actions = sectionCard(left, 1, "City actions")

	-- Save is the hub's primary action: pinned selected so the Kit button
	-- renders it as a filled accent capsule.
	local saveBtn = Button.new({
		text = "Save City",
		parent = actions,
		size = UDim2.new(1, 0, 0, 34),
		layoutOrder = 1,
	})
	saveBtn:SetSelected(true)
	local saving = false
	table.insert(_conns, saveBtn.Instance.Activated:Connect(function()
		if saving then
			return
		end
		saving = true
		SoundFX.play("Click")
		saveBtn.Instance.Text = "SAVING\u{2026}"
		task.spawn(function()
			local ok, success, info = pcall(function()
				return Net.RequestSaveCity:InvokeServer()
			end)
			saving = false
			saveBtn.Instance.Text = "SAVE CITY"
			local Notification = require(script.Parent:WaitForChild("NotificationController")) :: any
			if ok and success then
				Notification.Notify({ text = "City saved", kind = "success" })
			else
				Notification.Notify({ text = (typeof(info) == "string" and info) or "Save failed", kind = "danger" })
			end
		end)
	end))

	Button.new({
		text = "Game Settings",
		parent = actions,
		size = UDim2.new(1, 0, 0, 34),
		layoutOrder = 2,
		onClick = function()
			PlayerHubController.Close()
			local SettingsPanel = require(uiFolder:WaitForChild("SettingsPanel")) :: any
			SettingsPanel.Open()
		end,
	})

	Button.new({
		text = "Return to Main Menu",
		parent = actions,
		size = UDim2.new(1, 0, 0, 34),
		layoutOrder = 3,
		variant = "Danger",
		onClick = function()
			PlayerHubController.Close()
			UIEvents.ReturnToMainMenu:Fire()
		end,
	})

	local tips = sectionCard(right, 1, "Shortcuts")
	local lines = {
		{ k = "H", v = "Open / close this hub" },
		{ k = "ESC", v = "Close the hub" },
		{ k = "CLICK OUTSIDE", v = "Close the hub" },
		{ k = "TOP-RIGHT CARD", v = "Hover for rates, click to pin it open" },
	}
	for i, t in lines do
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, 18)
		row.LayoutOrder = i
		row.Parent = tips
		label(row, UDim2.new(0, 110, 1, 0), t.k, Theme.TextSize.XS, Theme.Color.Accent, Theme.Font.Bold, Enum.TextXAlignment.Left)
		local d = label(row, UDim2.new(1, -114, 1, 0), t.v, Theme.TextSize.XS, Theme.Color.TextSecondary, Theme.Font.Label, Enum.TextXAlignment.Left)
		d.Position = UDim2.fromOffset(114, 0)
	end
end

-- ===================================================================
--  shell
-- ===================================================================
local function buildProfile(parent: Instance)
	local block = Instance.new("Frame")
	block.Name = "Profile"
	block.BackgroundTransparency = 1
	block.Size = UDim2.new(1, 0, 0, 44)
	block.LayoutOrder = 0
	block.Parent = parent

	local avatar = Instance.new("ImageLabel")
	avatar.Name = "Avatar"
	avatar.BackgroundColor3 = Theme.Color.BgPress
	avatar.BorderSizePixel = 0
	avatar.AnchorPoint = Vector2.new(0, 0.5)
	avatar.Position = UDim2.new(0, 2, 0.5, 0)
	avatar.Size = UDim2.fromOffset(40, 40)
	avatar.Parent = block
	local ac = Instance.new("UICorner")
	ac.CornerRadius = UDim.new(1, 0)
	ac.Parent = avatar
	local as = Instance.new("UIStroke")
	as.Color = Theme.Glass.StrokeColor
	as.Transparency = 0.5
	as.Thickness = Theme.StrokeWidth.Thin
	as.Parent = avatar

	local player = Players.LocalPlayer
	local name = label(block, UDim2.new(1, -52, 0, 18), player.DisplayName, Theme.TextSize.SM, Theme.Color.TextPrimary, Theme.Font.Bold, Enum.TextXAlignment.Left)
	name.AnchorPoint = Vector2.new(0, 0.5)
	name.Position = UDim2.new(0, 50, 0.5, -9)

	local tier = label(block, UDim2.new(1, -52, 0, 14), "MAYOR", Theme.TextSize.XS, Theme.Color.Brand, Theme.Font.Label, Enum.TextXAlignment.Left)
	tier.AnchorPoint = Vector2.new(0, 0.5)
	tier.Position = UDim2.new(0, 50, 0.5, 8)
	_tierLabel = tier

	-- Thumbnail fetch yields; the chip already reads as a plain avatar disc if
	-- it never resolves.
	task.spawn(function()
		local ok, content = pcall(function()
			return Players:GetUserThumbnailAsync(player.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
		end)
		if ok and typeof(content) == "string" and avatar.Parent then
			avatar.Image = content
		end
	end)
end

local function build(gui: ScreenGui)
	-- Kit.Modal owns the shell: scrim, glass panel, title bar, close chip, the
	-- scale-in and outside-click. Parented to CityUI so it rides HudScale.
	_modal = Modal.new({
		size = UDim2.fromOffset(PANEL_W, PANEL_H),
		title = "Player Hub",
		name = "PlayerHub",
		parent = gui,
		onClose = function()
			PlayerHubController.Close()
		end,
	})
	local content = _modal.Content :: Frame

	-- Sidebar: profile, then one row per page.
	local nav = Instance.new("Frame")
	nav.Name = "Nav"
	nav.BackgroundTransparency = 1
	nav.Size = UDim2.new(0, NAV_W, 1, 0)
	nav.Parent = content

	local navList = Instance.new("UIListLayout")
	navList.SortOrder = Enum.SortOrder.LayoutOrder
	navList.Padding = UDim.new(0, Theme.Pad.SM)
	navList.Parent = nav

	buildProfile(nav)
	Divider.new("Horizontal", nav, NAV_W - 8).LayoutOrder = 1
	for i, p in PAGES do
		navRow(nav, i + 1, p.key, p.icon, p.title)
	end

	-- Full-height rule between sidebar and pages. Scale height is safe here:
	-- content is a fixed frame, not an AutomaticSize container.
	local rule = Divider.new("Vertical", content)
	rule.Size = UDim2.new(0, 1, 1, 0)
	rule.Position = UDim2.fromOffset(NAV_W + Theme.Pad.LG, 0)

	local pages = Instance.new("Frame")
	pages.Name = "Pages"
	pages.BackgroundTransparency = 1
	pages.Position = UDim2.fromOffset(NAV_W + Theme.Pad.XL + Theme.Pad.LG, 0)
	pages.Size = UDim2.new(1, -(NAV_W + Theme.Pad.XL + Theme.Pad.LG), 1, 0)
	pages.Parent = content

	buildOverview(newPage(pages, "Overview"))
	buildCity(newPage(pages, "City"))
	buildEconomy(newPage(pages, "Economy"))
	buildSettings(newPage(pages, "Settings"))
	selectPage("Overview")
end

-- One RF round-trip, fired when the hub opens. Rate-limited server-side; a nil reply
-- (too soon, or the record has not loaded) just leaves the last values on screen.
local function refreshRecord()
	if not Net then
		return
	end
	task.spawn(function()
		local ok, payload = pcall(function()
			return Net.RequestPlayerStats:InvokeServer()
		end)
		if not ok or typeof(payload) ~= "table" then
			return
		end
		_you = payload
		for _, fn in _youSubs do
			local fnOk, err = pcall(fn)
			if not fnOk then
				warn("[PlayerHubController] record refresh failed: " .. tostring(err))
			end
		end
	end)
end

-- ===================================================================
--  public interface
-- ===================================================================
function PlayerHubController.IsOpen(): boolean
	return _open
end

function PlayerHubController.Open()
	if _open or not _modal then
		return
	end
	_open = true
	refreshRecord()
	_modal:Show()
end

function PlayerHubController.Close()
	if not _open or not _modal then
		return
	end
	_open = false
	_modal:Hide()
end

function PlayerHubController.Toggle()
	if _open then
		PlayerHubController.Close()
	else
		PlayerHubController.Open()
	end
end

function PlayerHubController.Start()
	if _started then
		return
	end
	_started = true

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = playerGui:WaitForChild("CityUI", 60)
	if not gui or not gui:IsA("ScreenGui") then
		warn("[PlayerHubController] CityUI not found - aborting")
		_started = false
		return
	end

	Net = require(ReplicatedStorage:WaitForChild("Networker"))
	HudScale.attach(gui)
	build(gui)
	refreshRecord()

	local function runAll(subs: { () -> () })
		for _, fn in subs do
			local ok, err = pcall(fn)
			if not ok then
				warn("[PlayerHubController] widget refresh failed: " .. tostring(err))
			end
		end
	end

	table.insert(_conns, Net.SyncCityStats.OnClientEvent:Connect(function(payload: any)
		_stats = payload
		runAll(_statsSubs)
	end))
	table.insert(_conns, Net.SyncEconomy.OnClientEvent:Connect(function(payload: any)
		_econ = payload
		runAll(_econSubs)
	end))
	table.insert(_conns, Net.SyncProgression.OnClientEvent:Connect(function(payload: any)
		_snap = payload
		runAll(_progSubs)
	end))

	table.insert(_conns, UIEvents.GameEntered.Event:Connect(function()
		_inGame = true
	end))
	table.insert(_conns, UIEvents.ReturnToMainMenu.Event:Connect(function()
		_inGame = false
		PlayerHubController.Close()
	end))
	table.insert(_conns, UIEvents.SettingsOpened.Event:Connect(function()
		PlayerHubController.Close()
	end))

	table.insert(_conns, UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.H and _inGame then
			PlayerHubController.Toggle()
		elseif input.KeyCode == Enum.KeyCode.Escape and _open then
			PlayerHubController.Close()
		end
	end))
end

return PlayerHubController
