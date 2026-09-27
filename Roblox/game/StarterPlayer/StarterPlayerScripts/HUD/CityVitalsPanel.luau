--!strict
-- CITY VITALS: treasury, citizens and R/C/I demand, top right.
--
-- ONE card instead of four scattered readouts. These numbers used to live in
-- three different places on the bottom bar -- treasury in a centre banner,
-- citizens in a pod at the far left, demand rings between them -- so "how is my
-- city doing" meant looking in three directions.
--
-- Collapsed it is a single row: balance, population, three demand ticks. Hover
-- (or click to pin) expands it to the rates behind those numbers. The detail is
-- a fixed height, so the open/close is one tween on the root rather than an
-- AutomaticSize container fighting a tween.
--
-- Read-only. Owns no city state: it renders SyncEconomy / SyncCityStats and
-- borrows CityStatsController's demand smoothing rather than lerping its own.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local playerScripts = script.Parent.Parent
local uiFolder = playerScripts:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local Icons = require(uiFolder:WaitForChild("Icons"))
local UITween = require(uiFolder:WaitForChild("UITween"))
local HudScale = require(uiFolder:WaitForChild("HudScale"))
local TopbarDock = require(uiFolder:WaitForChild("TopbarDock"))
local Format = require(uiFolder:WaitForChild("Format"))
local kit = uiFolder:WaitForChild("Kit")
local Glass = require(kit:WaitForChild("Glass"))
local Tooltip = require(kit:WaitForChild("Tooltip"))
local UIEvents = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("UIEvents"))

local CityVitalsPanel = {}

local PANEL_W = 238
local SUMMARY_H = 40
local DETAIL_H = 122
local EDGE = 10
local TICK_W = 5
local TICK_MAX = 14 -- tallest a collapsed demand tick grows

-- Semantic zone colours: content, not chrome, so they keep their own hues.
local ZONE_DEFS: { { key: string, name: string, color: Color3 } } = {
	{ key = "R", name = "Residential", color = Color3.fromRGB(82, 196, 110) },
	{ key = "C", name = "Commercial", color = Color3.fromRGB(70, 160, 230) },
	{ key = "I", name = "Industrial", color = Color3.fromRGB(220, 185, 55) },
}

local _started = false
local _root: Frame? = nil
local _detail: Frame? = nil
local _hovered = false
local _pinned = false
local _conns: { RBXScriptConnection } = {}

local _cityName: TextLabel? = nil
local _moneyValue: TextLabel? = nil
local _moneyRate: TextLabel? = nil
local _popValue: TextLabel? = nil
local _popRate: TextLabel? = nil
local _moneyScale: UIScale? = nil
local _popScale: UIScale? = nil
local _lastMoney: number? = nil
local _lastPop: number? = nil

local function track(conn: RBXScriptConnection)
	table.insert(_conns, conn)
end

local function corner(inst: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = inst
end

local function label(parent: Instance, text: string, size: number, color: Color3, font: Font, align: Enum.TextXAlignment): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextSize = size
	l.TextColor3 = color
	l.FontFace = font
	l.TextXAlignment = align
	l.TextTruncate = Enum.TextTruncate.AtEnd
	l.Parent = parent
	return l
end

-- Sandbox pins the treasury server-side to a huge number; a nine-digit readout
-- is noise, so the HUD says what it actually means instead.
local function isSandbox(): boolean
	return workspace:GetAttribute("Sandbox") == true
end

-- "Value changed" pulse: the number swells a touch and settles back.
local function bump(scale: UIScale?)
	if not scale then
		return
	end
	scale.Scale = 1.07
	UITween.to(scale, "Popover", { Scale = 1 })
end

local function setExpanded(open: boolean)
	local root, detail = _root, _detail
	if not root or not detail then
		return
	end
	detail.Visible = true
	UITween.to(root, "Flyout", {
		Size = UDim2.fromOffset(PANEL_W, if open then SUMMARY_H + DETAIL_H else SUMMARY_H),
	})
end

local function refreshExpanded()
	setExpanded(_hovered or _pinned)
end

-- ===================================================================
--  summary row: balance | citizens | demand ticks
-- ===================================================================
local function buildSummary(parent: Instance): { [string]: (number) -> () }
	local row = Instance.new("Frame")
	row.Name = "Summary"
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, SUMMARY_H)
	row.Parent = parent

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 10)
	list.Parent = row

	local moneyHold = Instance.new("Frame")
	moneyHold.Name = "Money"
	moneyHold.BackgroundTransparency = 1
	moneyHold.AutomaticSize = Enum.AutomaticSize.X
	moneyHold.Size = UDim2.fromOffset(0, 20)
	moneyHold.LayoutOrder = 1
	moneyHold.Parent = row
	local ms = Instance.new("UIScale")
	ms.Parent = moneyHold
	_moneyScale = ms

	local money = label(moneyHold, "\u{2014}", Theme.TextSize.SM, Theme.Color.Positive, Theme.Font.Bold, Enum.TextXAlignment.Left)
	money.AutomaticSize = Enum.AutomaticSize.X
	money.Size = UDim2.fromOffset(0, 20)
	_moneyValue = money

	local rule1 = Instance.new("Frame")
	rule1.BackgroundColor3 = Theme.Glass.StrokeColor
	rule1.BackgroundTransparency = 0.5
	rule1.BorderSizePixel = 0
	rule1.Size = UDim2.fromOffset(1, 14)
	rule1.LayoutOrder = 2
	rule1.Parent = row

	local popHold = Instance.new("Frame")
	popHold.Name = "Citizens"
	popHold.BackgroundTransparency = 1
	popHold.AutomaticSize = Enum.AutomaticSize.X
	popHold.Size = UDim2.fromOffset(0, 20)
	popHold.LayoutOrder = 3
	popHold.Parent = row
	local ps = Instance.new("UIScale")
	ps.Parent = popHold
	_popScale = ps

	local pop = label(popHold, "\u{2014}", Theme.TextSize.SM, Theme.Color.TextPrimary, Theme.Font.Bold, Enum.TextXAlignment.Left)
	pop.AutomaticSize = Enum.AutomaticSize.X
	pop.Size = UDim2.fromOffset(0, 20)
	_popValue = pop

	local rule2 = rule1:Clone()
	rule2.LayoutOrder = 4
	rule2.Parent = row

	-- Three ticks that grow with demand. At a glance this is a shape, not a
	-- number: the player reads "housing is starving" without parsing a percentage.
	local ticks = Instance.new("Frame")
	ticks.Name = "DemandTicks"
	ticks.BackgroundTransparency = 1
	ticks.Size = UDim2.fromOffset(TICK_W * 3 + 8, TICK_MAX + 2)
	ticks.LayoutOrder = 5
	ticks.Parent = row

	local tl = Instance.new("UIListLayout")
	tl.FillDirection = Enum.FillDirection.Horizontal
	tl.VerticalAlignment = Enum.VerticalAlignment.Bottom
	tl.SortOrder = Enum.SortOrder.LayoutOrder
	tl.Padding = UDim.new(0, 4)
	tl.Parent = ticks

	local setters: { [string]: (number) -> () } = {}
	for i, def in ZONE_DEFS do
		local tick = Instance.new("Frame")
		tick.Name = "Tick" .. def.key
		tick.BackgroundColor3 = def.color
		tick.BorderSizePixel = 0
		tick.Size = UDim2.fromOffset(TICK_W, 3)
		tick.LayoutOrder = i
		tick.Parent = ticks
		corner(tick, 2)
		setters[def.key] = function(frac: number)
			tick.Size = UDim2.fromOffset(TICK_W, 3 + math.clamp(frac, 0, 1) * (TICK_MAX - 3))
		end
	end

	Tooltip.attach(ticks, "Zone demand \u{00B7} hover the panel for detail")
	return setters
end

-- ===================================================================
--  detail: the rates behind the summary numbers
-- ===================================================================
local function detailRow(parent: Instance, order: number, caption: string): TextLabel
	local row = Instance.new("Frame")
	row.Name = caption
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 16)
	row.LayoutOrder = order
	row.Parent = parent

	local l = label(row, caption, Theme.TextSize.XS, Theme.Color.TextSecondary, Theme.Font.Label, Enum.TextXAlignment.Left)
	l.Size = UDim2.new(0.5, 0, 1, 0)

	local v = label(row, "\u{2014}", Theme.TextSize.XS, Theme.Color.TextPrimary, Theme.Font.Header, Enum.TextXAlignment.Right)
	v.Name = "Value"
	v.AnchorPoint = Vector2.new(1, 0)
	v.Position = UDim2.fromScale(1, 0)
	v.Size = UDim2.new(0.5, 0, 1, 0)
	return v
end

local function buildDetail(parent: Instance): { [string]: (number) -> () }
	local detail = Instance.new("Frame")
	detail.Name = "Detail"
	detail.BackgroundTransparency = 1
	detail.Position = UDim2.fromOffset(0, SUMMARY_H)
	detail.Size = UDim2.new(1, 0, 0, DETAIL_H)
	detail.Parent = parent
	_detail = detail

	local col = Instance.new("UIListLayout")
	col.FillDirection = Enum.FillDirection.Vertical
	col.SortOrder = Enum.SortOrder.LayoutOrder
	col.Padding = UDim.new(0, 3)
	col.Parent = detail

	local rule = Instance.new("Frame")
	rule.BackgroundColor3 = Theme.Glass.StrokeColor
	rule.BackgroundTransparency = 0.6
	rule.BorderSizePixel = 0
	rule.Size = UDim2.new(1, 0, 0, 1)
	rule.LayoutOrder = 0
	rule.Parent = detail

	-- The city's name, which used to head the centre banner on the old bottom
	-- bar. Warm serif: it is the one piece of display copy on the whole HUD, and
	-- the only line here that is a name rather than a number.
	local name = label(detail, "\u{2014}", 18, Theme.Color.TextPrimary, Theme.Font.Serif, Enum.TextXAlignment.Left)
	name.Name = "CityName"
	name.Size = UDim2.new(1, 0, 0, 22)
	name.LayoutOrder = 1
	_cityName = name

	_moneyRate = detailRow(detail, 2, "treasury / hr")
	_popRate = detailRow(detail, 3, "citizens")

	local spacer = Instance.new("Frame")
	spacer.BackgroundTransparency = 1
	spacer.Size = UDim2.new(1, 0, 0, 4)
	spacer.LayoutOrder = 4
	spacer.Parent = detail

	local setters: { [string]: (number) -> () } = {}
	for i, def in ZONE_DEFS do
		local row = Instance.new("Frame")
		row.Name = def.name
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, 14)
		row.LayoutOrder = 4 + i
		row.Parent = detail

		local key = label(row, def.key, Theme.TextSize.XS, def.color, Theme.Font.Bold, Enum.TextXAlignment.Left)
		key.Size = UDim2.fromOffset(12, 14)

		local track_ = Instance.new("Frame")
		track_.Name = "Track"
		track_.AnchorPoint = Vector2.new(0, 0.5)
		track_.Position = UDim2.new(0, 16, 0.5, 0)
		track_.Size = UDim2.new(1, -58, 0, 5)
		track_.BackgroundColor3 = Theme.Color.BgPress
		track_.BorderSizePixel = 0
		track_.ClipsDescendants = true
		track_.Parent = row
		corner(track_, 3)

		local fill = Instance.new("Frame")
		fill.Name = "Fill"
		fill.Size = UDim2.new(0, 0, 1, 0)
		fill.BackgroundColor3 = def.color
		fill.BorderSizePixel = 0
		fill.Parent = track_
		corner(fill, 3)

		local pct = label(row, "\u{2014}", Theme.TextSize.XS, def.color, Theme.Font.Header, Enum.TextXAlignment.Right)
		pct.AnchorPoint = Vector2.new(1, 0)
		pct.Position = UDim2.fromScale(1, 0)
		pct.Size = UDim2.fromOffset(38, 14)

		Tooltip.attach(row, def.name .. " demand")
		setters[def.key] = function(frac: number)
			local f = math.clamp(frac, 0, 1)
			fill.Size = UDim2.new(f, 0, 1, 0)
			pct.Text = string.format("%d%%", math.floor(f * 100 + 0.5))
		end
	end

	return setters
end

-- Roll the treasury toward the new value instead of jumping, so a purchase
-- visibly counts down. Token-guarded: a newer sync retargets the same roll
-- rather than stacking loops.
local _moneyShown: number? = nil
local _rollToken = 0
local function rollMoneyTo(target: number)
	local value = _moneyValue
	if not value then
		return
	end
	if isSandbox() then
		_rollToken += 1 -- cancel any roll still in flight
		_moneyShown = target
		value.Text = "UNLIMITED"
		return
	end
	local from = _moneyShown or target
	_moneyShown = target
	if from == target then
		value.Text = Format.money(target)
		return
	end
	_rollToken += 1
	local token = _rollToken
	task.spawn(function()
		local DUR = 0.5
		local t0 = os.clock()
		while token == _rollToken and value.Parent do
			local a = math.min((os.clock() - t0) / DUR, 1)
			value.Text = Format.money(math.floor(from + (target - from) * (1 - (1 - a) * (1 - a)) + 0.5))
			if a >= 1 then
				break
			end
			task.wait()
		end
	end)
end

function CityVitalsPanel.Start()
	if _started then
		return
	end
	_started = true

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = playerGui:WaitForChild("CityUI", 60)
	if not gui or not gui:IsA("ScreenGui") then
		warn("[CityVitalsPanel] CityUI not found - aborting")
		_started = false
		return
	end
	HudScale.attach(gui)

	local root = Instance.new("Frame")
	root.Name = "CityVitals"
	root.AnchorPoint = Vector2.new(1, 0)
	root.Size = UDim2.fromOffset(PANEL_W, SUMMARY_H)
	root.ClipsDescendants = true
	root.Visible = false
	root.ZIndex = Theme.Z.HUD
	Glass.apply(root, Theme.Radius.LG)
	root.Parent = gui
	_root = root

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, Theme.Pad.LG)
	pad.PaddingRight = UDim.new(0, Theme.Pad.LG)
	pad.Parent = root

	local tickSetters = buildSummary(root)
	local barSetters = buildDetail(root)

	-- Sit on the same baseline as the top-left capsule rather than guessing at
	-- the topbar height.
	TopbarDock.bind(gui, function(_x0, top, _h)
		root.Position = UDim2.new(1, -EDGE, 0, top - 6)
	end)

	-- Hover expands; click pins it open. Touch has no hover, so the click is the
	-- path that always works.
	local hit = Instance.new("TextButton")
	hit.Name = "HitArea"
	hit.AutoButtonColor = false
	hit.Text = ""
	hit.BackgroundTransparency = 1
	hit.Size = UDim2.fromScale(1, 1)
	hit.ZIndex = Theme.Z.HUD + 2
	hit.Parent = root

	track(hit.MouseEnter:Connect(function()
		_hovered = true
		refreshExpanded()
	end))
	track(hit.MouseLeave:Connect(function()
		_hovered = false
		refreshExpanded()
	end))
	track(hit.Activated:Connect(function()
		_pinned = not _pinned
		refreshExpanded()
	end))

	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	local CityStatsController = require(script.Parent:WaitForChild("CityStatsController")) :: any

	-- CityStatsController owns demand smoothing; it lerps and calls back per zone.
	-- Both the collapsed tick and the open bar render the same fraction.
	CityStatsController.SetGauges({
		R = function(f: number)
			tickSetters.R(f)
			barSetters.R(f)
		end,
		C = function(f: number)
			tickSetters.C(f)
			barSetters.C(f)
		end,
		I = function(f: number)
			tickSetters.I(f)
			barSetters.I(f)
		end,
	})

	track(Net.SyncCityStats.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" or typeof(payload.population) ~= "number" then
			return
		end
		local pop = payload.population
		local value, rate = _popValue, _popRate
		if value then
			value.Text = Format.int(pop)
		end
		if _lastPop ~= nil and pop ~= _lastPop then
			bump(_popScale)
			if rate then
				local delta = pop - _lastPop
				rate.Text = Format.signed(delta)
				rate.TextColor3 = if delta < 0 then Theme.Color.Danger else Theme.Color.Positive
			end
		end
		_lastPop = pop
	end))

	track(Net.SyncEconomy.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		if typeof(payload.money) == "number" then
			if _lastMoney ~= nil and payload.money ~= _lastMoney then
				bump(_moneyScale)
			end
			_lastMoney = payload.money
			rollMoneyTo(payload.money)
			local value = _moneyValue
			if value then
				value.TextColor3 = if payload.money < 0 then Theme.Color.Danger else Theme.Color.Positive
			end
		end
		local rate = _moneyRate
		if typeof(payload.monthlyNet) == "number" and rate then
			if isSandbox() then
				rate.Text = "SANDBOX"
				rate.TextColor3 = Theme.Color.Positive
			else
				local hourly = payload.monthlyNet / 720
				rate.Text = Format.signedMoney(hourly)
				rate.TextColor3 = if hourly < 0 then Theme.Color.Danger else Theme.Color.Positive
			end
		end
	end))

	-- Charged placement: pulse the balance red so the floating "-$X" tag and the
	-- readout visibly connect. Colour restores on the next SyncEconomy tick.
	local flashToken = 0
	track(Net.PlacementCharged.OnClientEvent:Connect(function()
		local value = _moneyValue
		if not value then
			return
		end
		flashToken += 1
		local token = flashToken
		value.TextColor3 = Theme.Color.Danger
		bump(_moneyScale)
		task.delay(0.6, function()
			local v = _moneyValue
			if token ~= flashToken or not v then
				return
			end
			v.TextColor3 = if (_lastMoney or 0) < 0 then Theme.Color.Danger else Theme.Color.Positive
		end)
	end))

	track(UIEvents.GameEntered.Event:Connect(function(slotMeta: any)
		local name = _cityName
		if name and typeof(slotMeta) == "table" and typeof(slotMeta.cityName) == "string" and slotMeta.cityName ~= "" then
			name.Text = slotMeta.cityName
		end
		root.Visible = true
		root.BackgroundTransparency = 1
		UITween.to(root, "Flyout", { BackgroundTransparency = Theme.Glass.Transparency })
	end))
	track(UIEvents.ReturnToMainMenu.Event:Connect(function()
		root.Visible = false
		_pinned = false
		_hovered = false
		root.Size = UDim2.fromOffset(PANEL_W, SUMMARY_H)
	end))
end

function CityVitalsPanel.Cleanup()
	for _, c in _conns do
		c:Disconnect()
	end
	table.clear(_conns)
	_root, _detail, _cityName = nil, nil, nil
	_moneyValue, _moneyRate, _popValue, _popRate = nil, nil, nil, nil
	_lastMoney, _lastPop, _moneyShown = nil, nil, nil
	_started = false
end

return CityVitalsPanel
