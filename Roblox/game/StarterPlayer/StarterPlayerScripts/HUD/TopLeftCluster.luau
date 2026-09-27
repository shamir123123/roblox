--!strict
-- TOP-LEFT CLUSTER: one glass capsule holding everything docked in the Roblox
-- topbar row -- the game-menu chip, the city-role badge, the clock and the sim
-- speed pills.
--
-- Roblox's own core chips (logo, menu, backpack) always draw above player GUIs
-- and ignore both HudScale and the GUI inset, so they cannot be moved. Rather
-- than dodge them, the capsule starts at the screen edge and runs PAST them: its
-- left padding is exactly the width of the core cluster, so those chips sit
-- inside our capsule and the whole row reads as one group. TopbarDock measures
-- the band; nothing here guesses at it.
--
-- ONE owner for the zone. Before this, HUDController sized the capsule while
-- separately positioning the role badge past its right edge -- two placements
-- that had to agree, so no fourth chip could be added without editing both.
--
-- Two OTHER modules dock chips in this same row and position themselves
-- absolutely: ProgressionController takes slot 1 (City Hall) and RadioController
-- slot 2. They are not ours to move, so the layout reserves their width with a
-- spacer and carries on at slot 3 -- the same trick the left padding plays on
-- the Roblox core chips. Claim another slot there and this spacer has to grow
-- with it, or the clock lands on top of it.
--
-- The menu chip fires UIEvents.MenuRequested instead of calling HUDController.
-- HUDController owns the menu and its open state; the chip only reports a press
-- (CLAUDE.md §5), which also keeps the two modules from requiring each other.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local playerScripts = script.Parent.Parent
local uiFolder = playerScripts:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local Icons = require(uiFolder:WaitForChild("Icons"))
local UITween = require(uiFolder:WaitForChild("UITween"))
local HudScale = require(uiFolder:WaitForChild("HudScale"))
local TopbarDock = require(uiFolder:WaitForChild("TopbarDock"))
local kit = uiFolder:WaitForChild("Kit")
local Glass = require(kit:WaitForChild("Glass"))
local Tooltip = require(kit:WaitForChild("Tooltip"))
local UIEvents = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("UIEvents"))

local TopLeftCluster = {}

local PILL_PAD = 6 -- how far the capsule rings out past the chips inside it
-- Must equal TopbarDock's own gap: the list lays our chips out on the same grid
-- slot() measures against, and 2px of drift per chip walks the clock onto the
-- radio chip by slot 3.
local GAP = TopbarDock.Gap
local EDGE = 8 -- capsule's left edge, matching the screen margin elsewhere
-- Topbar slots owned by other modules, sitting between our menu chip and clock:
-- 1 = ProgressionController (City Hall), 2 = RadioController (station).
local RESERVED_SLOTS = 2

-- City calendar: day 1 = noon on 25 May 2026, one calendar day per in-game day.
-- The bar shows HH:MM and the day number; the full date is the hover tooltip.
local MONTH_NAMES = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local WEEKDAY_NAMES = { "SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT" }
local START_DATE = DateTime.fromUniversalTime(2026, 5, 25, 12, 0, 0)

local function dayStart(day: number?): number
	local d = math.max(1, math.floor(tonumber(day) or 1))
	return START_DATE.UnixTimestampMillis + (d - 1) * 86400000
end

local function dateStringForDay(day: number?): string
	local t = DateTime.fromUnixTimestampMillis(dayStart(day)):ToUniversalTime()
	return string.format("%02d %s %d", t.Day, MONTH_NAMES[t.Month], t.Year)
end

-- 1 Jan 1970 was a Thursday, hence the +4 before the modulo.
local function weekdayForDay(day: number?): string
	local dayIndex = math.floor(dayStart(day) / 86400000)
	return WEEKDAY_NAMES[(dayIndex + 4) % 7 + 1]
end

-- Sim speed. Pause keeps an icon; the multipliers are text, which reads faster
-- at this size than three near-identical glyphs would.
local SPEED_DEFS: { { v: number, text: string?, icon: Icons.Icon?, tip: string } } = {
	{ v = 0, icon = Icons.Pause, tip = "Pause" },
	{ v = 1, text = "1\u{00D7}", tip = "Normal speed" },
	{ v = 2, text = "2\u{00D7}", tip = "Fast" },
	{ v = 3, text = "3\u{00D7}", tip = "Fastest" },
}

-- WHO YOU ARE IN THIS CITY. A guest arrives with rights they did not pick and
-- cannot otherwise see; this badge is the one place the game says so.
--
-- It is a LABEL. Every real permission is answered on the server, so a client
-- that forged the attribute would only be lying to itself.
local ROLE_LABEL: { [string]: string } = {
	owner = "OWNER",
	staff = "STAFF",
	admin = "ADMIN",
	builder = "BUILDER",
	visitor = "VISITOR",
}
local ROLE_DOT: { [string]: Color3 } = {
	owner = Theme.Color.Accent,
	staff = Theme.Color.Accent,
	admin = Color3.fromRGB(226, 166, 74),
	builder = Color3.fromRGB(78, 201, 106),
	visitor = Color3.fromRGB(150, 156, 148),
}

local _started = false
local _clockValue: TextLabel? = nil
local _clockCaption: TextLabel? = nil
local _clockDay = 1
local _speedButtons: { [number]: TextButton } = {}
local _conns: { RBXScriptConnection } = {}

local function track(conn: RBXScriptConnection)
	table.insert(_conns, conn)
end

-- A role only means something when there is somebody else to have a different
-- one. Alone in your own city the badge is a permanent label stating the
-- obvious, and it was the widest thing in the row.
local function isMultiplayer(): boolean
	return #Players:GetPlayers() > 1
end

local function label(parent: Instance, text: string, size: number, color: Color3, font: Font): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.AutomaticSize = Enum.AutomaticSize.X
	l.Size = UDim2.fromOffset(0, size + 4)
	l.Text = text
	l.TextSize = size
	l.TextColor3 = color
	l.FontFace = font
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = parent
	return l
end

-- Circular icon chip, the same read as a Roblox core chip beside it.
local function buildMenuChip(parent: Instance): TextButton
	local btn = Instance.new("TextButton")
	btn.Name = "MenuChip"
	btn.AutoButtonColor = false
	btn.Text = ""
	btn.BackgroundColor3 = Theme.Color.BgPress
	btn.BackgroundTransparency = 0.1
	btn.BorderSizePixel = 0
	btn.LayoutOrder = 1
	btn.Parent = parent

	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(1, 0)
	c.Parent = btn

	local ic = Instance.new("ImageLabel")
	ic.Name = "Icon"
	ic.BackgroundTransparency = 1
	ic.AnchorPoint = Vector2.new(0.5, 0.5)
	ic.Position = UDim2.fromScale(0.5, 0.5)
	ic.Size = UDim2.fromScale(0.58, 0.58)
	ic.ScaleType = Enum.ScaleType.Fit
	ic.Image = Icons.Menu.image
	ic.ImageColor3 = Theme.Color.TextPrimary
	ic.Parent = btn

	track(btn.MouseEnter:Connect(function()
		UITween.to(btn, "Hover", { BackgroundTransparency = 0 })
		UITween.to(ic, "Hover", { ImageColor3 = Color3.new(1, 1, 1) })
	end))
	track(btn.MouseLeave:Connect(function()
		UITween.to(btn, "Hover", { BackgroundTransparency = 0.1 })
		UITween.to(ic, "Hover", { ImageColor3 = Theme.Color.TextPrimary })
	end))
	track(btn.Activated:Connect(function()
		UIEvents.MenuRequested:Fire()
	end))

	Tooltip.attach(btn, "Menu")
	return btn
end

local function buildRoleBadge(parent: Instance): Frame
	local player = Players.LocalPlayer

	local chip = Instance.new("Frame")
	chip.Name = "CityRole"
	chip.BackgroundColor3 = Theme.Color.BgPress
	chip.BackgroundTransparency = 0.25
	chip.BorderSizePixel = 0
	chip.AutomaticSize = Enum.AutomaticSize.X
	chip.Size = UDim2.fromOffset(0, 24)
	chip.Visible = false
	chip.LayoutOrder = 3
	chip.Parent = parent

	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(1, 0)
	c.Parent = chip

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 12)
	pad.Parent = chip

	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.VerticalAlignment = Enum.VerticalAlignment.Center
	row.SortOrder = Enum.SortOrder.LayoutOrder
	row.Padding = UDim.new(0, 6)
	row.Parent = chip

	local dot = Instance.new("Frame")
	dot.Name = "Dot"
	dot.BorderSizePixel = 0
	dot.Size = UDim2.fromOffset(7, 7)
	dot.LayoutOrder = 1
	dot.Parent = chip
	local dc = Instance.new("UICorner")
	dc.CornerRadius = UDim.new(1, 0)
	dc.Parent = dot

	local text = label(chip, "", Theme.TextSize.XS, Theme.Color.TextPrimary, Theme.Font.Header)
	text.Name = "Label"
	text.LayoutOrder = 2

	local function render()
		local role = player:GetAttribute("CityRole")
		local name = if typeof(role) == "string" then ROLE_LABEL[role] else nil
		-- No attribute means this server never gated anyone (Studio, a public
		-- server): there is no role to report, so nothing is claimed. And solo,
		-- there is nobody to distinguish yourself from.
		chip.Visible = name ~= nil and isMultiplayer()
		if not name then
			return
		end
		text.Text = name
		dot.BackgroundColor3 = ROLE_DOT[role :: string] or Theme.Color.TextSecondary
	end

	track(player:GetAttributeChangedSignal("CityRole"):Connect(render))
	-- The badge appears the moment a second player arrives and goes when the city
	-- empties again, so a session that starts solo and fills up still shows it.
	track(Players.PlayerAdded:Connect(render))
	track(Players.PlayerRemoving:Connect(function()
		-- PlayerRemoving fires BEFORE the player leaves the list, so re-read on the
		-- next step or we still count the one on their way out.
		task.defer(render)
	end))
	render()
	return chip
end

local function buildClock(parent: Instance): Frame
	local holder = Instance.new("Frame")
	holder.Name = "Clock"
	holder.BackgroundTransparency = 1
	holder.AutomaticSize = Enum.AutomaticSize.X
	holder.Size = UDim2.fromOffset(0, 34)
	holder.LayoutOrder = 5
	holder.Parent = parent

	local col = Instance.new("UIListLayout")
	col.FillDirection = Enum.FillDirection.Vertical
	col.VerticalAlignment = Enum.VerticalAlignment.Center
	col.HorizontalAlignment = Enum.HorizontalAlignment.Left
	col.SortOrder = Enum.SortOrder.LayoutOrder
	col.Parent = holder

	local value = label(holder, "12:00", Theme.TextSize.MD, Theme.Color.TextPrimary, Theme.Font.Bold)
	value.Name = "Value"
	value.LayoutOrder = 1

	local caption = label(holder, "DAY 1", 11, Theme.Color.TextSecondary, Theme.Font.Label)
	caption.Name = "Caption"
	caption.LayoutOrder = 2

	_clockValue, _clockCaption = value, caption
	Tooltip.attach(holder, function()
		return string.format("%s \u{00B7} %s", weekdayForDay(_clockDay), dateStringForDay(_clockDay))
	end)
	return holder
end

local function refreshSpeed()
	local cur = math.clamp(tonumber(workspace:GetAttribute("GameSpeed")) or 1, 0, 3)
	for v, btn in _speedButtons do
		local active = v == cur
		UITween.to(btn, "Hover", {
			BackgroundColor3 = if active then Theme.Color.Accent else Theme.Color.BgRaised,
			TextColor3 = if active then Theme.Color.OnAccent else Theme.Color.TextSecondary,
		})
		local ic = btn:FindFirstChild("Icon")
		if ic and ic:IsA("ImageLabel") then
			UITween.to(ic, "Hover", {
				ImageColor3 = if active then Theme.Color.OnAccent else Theme.Color.TextSecondary,
			})
		end
	end
end

local function buildSpeed(parent: Instance): Frame
	local Net = require(ReplicatedStorage:WaitForChild("Networker"))

	local holder = Instance.new("Frame")
	holder.Name = "Speed"
	holder.BackgroundTransparency = 1
	holder.AutomaticSize = Enum.AutomaticSize.X
	holder.Size = UDim2.fromOffset(0, 32)
	holder.LayoutOrder = 6
	holder.Parent = parent

	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.VerticalAlignment = Enum.VerticalAlignment.Center
	row.SortOrder = Enum.SortOrder.LayoutOrder
	row.Padding = UDim.new(0, 2)
	row.Parent = holder

	for i, def in SPEED_DEFS do
		local b = Instance.new("TextButton")
		b.Name = "Speed" .. def.v
		b.AutoButtonColor = false
		b.Size = UDim2.fromOffset(34, 30)
		b.Text = def.text or ""
		b.FontFace = Theme.Font.Bold
		b.TextSize = Theme.TextSize.SM
		b.BackgroundColor3 = Theme.Color.BgRaised
		b.TextColor3 = Theme.Color.TextSecondary
		b.BorderSizePixel = 0
		b.LayoutOrder = i
		b.Parent = holder
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(1, 0) -- capsule; UICorner clamps to half-height
		c.Parent = b

		if def.icon then
			local ic = Instance.new("ImageLabel")
			ic.Name = "Icon"
			ic.BackgroundTransparency = 1
			ic.AnchorPoint = Vector2.new(0.5, 0.5)
			ic.Position = UDim2.fromScale(0.5, 0.5)
			ic.Size = UDim2.fromScale(0.46, 0.46)
			ic.ScaleType = Enum.ScaleType.Fit
			ic.Image = def.icon.image
			ic.ImageColor3 = Theme.Color.TextSecondary
			ic.Parent = b
		end

		local v = def.v
		track(b.Activated:Connect(function()
			Net.RequestGameSpeed:FireServer(v)
		end))
		Tooltip.attach(b, def.tip)
		_speedButtons[v] = b
	end

	refreshSpeed()
	track(workspace:GetAttributeChangedSignal("GameSpeed"):Connect(refreshSpeed))
	return holder
end

function TopLeftCluster.Start()
	if _started then
		return
	end
	_started = true

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = playerGui:WaitForChild("CityUI", 60)
	if not gui or not gui:IsA("ScreenGui") then
		warn("[TopLeftCluster] CityUI not found - aborting")
		_started = false
		return
	end
	HudScale.attach(gui)

	-- The capsule IS the row: AutomaticSize.X fits it to its contents, and a left
	-- padding the width of the Roblox core cluster leaves those chips sitting
	-- inside it. One frame, so the capsule can never disagree with what it holds.
	local cluster = Instance.new("Frame")
	cluster.Name = "TopLeftCluster"
	cluster.AutomaticSize = Enum.AutomaticSize.X
	cluster.ZIndex = Theme.Z.HUD
	Glass.apply(cluster, 999) -- UICorner clamps to half-height: a true capsule
	cluster.Parent = gui

	local pad = Instance.new("UIPadding")
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = cluster

	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.VerticalAlignment = Enum.VerticalAlignment.Center
	row.SortOrder = Enum.SortOrder.LayoutOrder
	row.Padding = UDim.new(0, GAP)
	row.Parent = cluster

	local menuChip = buildMenuChip(cluster)

	-- Holds open the width of the City Hall and radio chips, which place
	-- themselves absolutely at slots 1 and 2. Transparent: they draw into it.
	local reserved = Instance.new("Frame")
	reserved.Name = "ReservedChips"
	reserved.BackgroundTransparency = 1
	reserved.LayoutOrder = 2
	reserved.Parent = cluster

	buildRoleBadge(cluster)

	local rule = Instance.new("Frame")
	rule.Name = "Rule"
	rule.BackgroundColor3 = Theme.Glass.StrokeColor
	rule.BackgroundTransparency = 0.5
	rule.BorderSizePixel = 0
	rule.Size = UDim2.fromOffset(1, 18)
	rule.LayoutOrder = 4
	rule.Parent = cluster

	buildClock(cluster)
	buildSpeed(cluster)

	TopbarDock.bind(gui, function(x0, top, h)
		cluster.Position = UDim2.fromOffset(EDGE, top - PILL_PAD)
		cluster.Size = UDim2.fromOffset(0, h + PILL_PAD * 2) -- X comes from AutomaticSize
		-- Core chips occupy everything left of x0, so that becomes our padding.
		pad.PaddingLeft = UDim.new(0, math.max(0, x0 + TopbarDock.Gap - EDGE))
		menuChip.Size = UDim2.fromOffset(h, h)
		-- N chips plus the gaps BETWEEN them; the gap that separates this spacer
		-- from its neighbours is the list's own padding, already counted.
		reserved.Size = UDim2.fromOffset(RESERVED_SLOTS * h + (RESERVED_SLOTS - 1) * TopbarDock.Gap, h)
	end)

	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	local ClientSettings = require(playerScripts:WaitForChild("Core"):WaitForChild("Settings"))
	track(Net.SyncTime.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		local value, caption = _clockValue, _clockCaption
		if not value or not caption then
			return
		end
		-- Lighting.ClockTime is the authority on the hour: the server syncs it, and
		-- reading it here keeps the readout and the sky in step.
		local totalMin = math.floor(Lighting.ClockTime * 60)
		_clockDay = tonumber(payload.day) or _clockDay
		local h24 = math.floor(totalMin / 60) % 24
		if tonumber(ClientSettings.get("timeFormat")) == 12 then
			local h12 = h24 % 12
			if h12 == 0 then
				h12 = 12
			end
			value.Text = string.format("%d:%02d %s", h12, totalMin % 60, if h24 < 12 then "AM" else "PM")
		else
			value.Text = string.format("%02d:%02d", h24, totalMin % 60)
		end
		-- Day number only. The weekday used to ride here too, which made this the
		-- widest block in the row for information nothing in the game reads; it is
		-- still on the hover tooltip with the full date.
		caption.Text = string.format("DAY %d", _clockDay)
	end))
end

function TopLeftCluster.Cleanup()
	for _, c in _conns do
		c:Disconnect()
	end
	table.clear(_conns)
	table.clear(_speedButtons)
	_clockValue, _clockCaption = nil, nil
	_started = false
end

return TopLeftCluster
