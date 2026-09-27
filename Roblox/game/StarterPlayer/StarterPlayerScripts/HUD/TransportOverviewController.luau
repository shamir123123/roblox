--!strict
-- TransportOverviewController
-- The Transportation Overview panel: a right-docked Public Transport panel with a fleet
-- summary header (buses used/allowance, lines, riders, net $/mo) over a scroll of
-- per-line cards. Each card: line colour (click = palette), editable name, usage bar,
-- riders, the line's net $/mo, compact bus + fare steppers, an enable switch and delete.
-- Selecting a line brightens its map overlay and expands an ordered stop list (per-stop
-- boardings this month). Reads the live snapshot from TransitClient; drives changes
-- through RequestTransitCommand.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage:WaitForChild("Networker"))
local TransitTypes = require(ReplicatedStorage.Transit.TransitTypes)
local uiFolder = script.Parent.Parent:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local PanelSlots = require(uiFolder:WaitForChild("PanelSlots"))
local Glass = require(uiFolder:WaitForChild("Kit"):WaitForChild("Glass"))
local UITween = require(uiFolder:WaitForChild("UITween"))
local coreFolder = script.Parent.Parent:WaitForChild("Core")
local TransitClient = require(coreFolder:WaitForChild("TransitClient"))
local Settings = require(coreFolder:WaitForChild("Settings"))

local TransportOverviewController = {}

local _started = false
local _open = false
local _gui: ScreenGui? = nil
local _panel: Frame? = nil
local _listScroll: ScrollingFrame? = nil
local _emptyLabel: TextLabel? = nil
local _busesChip: TextLabel? = nil
local _linesChip: TextLabel? = nil
local _ridersChip: TextLabel? = nil
local _netChip: TextLabel? = nil
local _rows: { [number]: any } = {}
local _selected: number? = nil
local _editing: number? = nil
local _palette: Frame? = nil
local _paletteBackdrop: TextButton? = nil
local _paletteFor: number? = nil

local PANEL_W = 384
-- 124 clears the right-edge pill stack (LaneView y48-78, NodeTool y84-114) that draws in
-- front of this panel; at 84 the panel opened directly underneath the NodeTool pill.
local PANEL_TOP = 124

local function corner(inst: Instance, r: number)
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r); c.Parent = inst
end

local function label(parent: Instance, text: string, size: number, bold: boolean): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextColor3 = Theme.Color.TextPrimary
	l.TextSize = size
	l.FontFace = if bold then Theme.Font.Bold else Theme.Font.Label
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = parent
	return l
end

local function smallBtn(parent: Instance, text: string, w: number, onClick: () -> ()): TextButton
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(w, 20)
	b.BackgroundColor3 = Theme.Color.BgRaised
	b.BorderSizePixel = 0
	b.Text = text
	b.TextColor3 = Theme.Color.TextPrimary
	b.TextSize = Theme.TextSize.XS
	b.FontFace = Theme.Font.Bold
	b.AutoButtonColor = true
	b.Parent = parent
	corner(b, 4)
	b.Activated:Connect(onClick)
	return b
end

-- == Fleet header chips ========================================================
local function metricChip(parent: Instance, x: number, w: number, name: string): TextLabel
	local chip = Instance.new("Frame")
	chip.BackgroundColor3 = Theme.Color.BgRaised
	chip.BackgroundTransparency = 0.15
	chip.BorderSizePixel = 0
	chip.Position = UDim2.fromOffset(x, 34)
	chip.Size = UDim2.fromOffset(w, 44)
	chip.Parent = parent
	corner(chip, Theme.Radius.SM)
	local nm = label(chip, name, Theme.TextSize.XS, false)
	nm.Position = UDim2.fromOffset(8, 5)
	nm.Size = UDim2.new(1, -16, 0, 14)
	nm.TextColor3 = Theme.Color.TextSecondary
	local val = label(chip, "0", Theme.TextSize.MD, true)
	val.Position = UDim2.fromOffset(8, 20)
	val.Size = UDim2.new(1, -16, 0, 20)
	return val
end

-- == Compact stepper (bus count + fare): [-] value [+] =========================
local function makeStepper(parent: Instance, x: number, onMinus: () -> (), onPlus: () -> ()): TextLabel
	local frame = Instance.new("Frame")
	frame.BackgroundColor3 = Theme.Color.Bg
	frame.BorderSizePixel = 0
	frame.AnchorPoint = Vector2.new(0, 0.5)
	frame.Position = UDim2.new(0, x, 0.5, 0)
	frame.Size = UDim2.fromOffset(56, 22)
	frame.Parent = parent
	corner(frame, 6)
	local minus = Instance.new("TextButton")
	minus.BackgroundTransparency = 1
	minus.Size = UDim2.fromOffset(18, 22)
	minus.Text = "\u{2212}"
	minus.TextColor3 = Theme.Color.TextSecondary
	minus.TextSize = Theme.TextSize.XS
	minus.FontFace = Theme.Font.Bold
	minus.Parent = frame
	minus.Activated:Connect(onMinus)
	local val = Instance.new("TextLabel")
	val.BackgroundTransparency = 1
	val.Position = UDim2.fromOffset(18, 0)
	val.Size = UDim2.fromOffset(20, 22)
	val.TextColor3 = Theme.Color.TextPrimary
	val.TextSize = Theme.TextSize.XS
	val.FontFace = Theme.Font.Bold
	val.Text = "0"
	val.Parent = frame
	local plus = Instance.new("TextButton")
	plus.AnchorPoint = Vector2.new(1, 0)
	plus.Position = UDim2.new(1, 0, 0, 0)
	plus.BackgroundTransparency = 1
	plus.Size = UDim2.fromOffset(18, 22)
	plus.Text = "+"
	plus.TextColor3 = Theme.Color.TextPrimary
	plus.TextSize = Theme.TextSize.XS
	plus.FontFace = Theme.Font.Bold
	plus.Parent = frame
	plus.Activated:Connect(onPlus)
	return val
end

-- == Per-line cards ============================================================
-- Forward declarations: card button callbacks reference these before definition.
local refresh: () -> ()
local ensureRow: (number) -> any
local updateRow: (any, any, { [number]: any }) -> ()
local openPalette: (number, GuiObject) -> ()
local closePalette: () -> ()
local setSelected: (number) -> ()

closePalette = function()
	if _palette then _palette:Destroy(); _palette = nil end
	if _paletteBackdrop then _paletteBackdrop:Destroy(); _paletteBackdrop = nil end
	_paletteFor = nil
end

-- A swatch grid anchored to the left of the clicked colour bar. Picks an explicit
-- ROUTE_COLORS index -- no more blind colour cycling.
openPalette = function(routeId: number, anchor: GuiObject)
	closePalette()
	local gui = _gui
	if not gui then return end
	_paletteFor = routeId

	local backdrop = Instance.new("TextButton")
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundTransparency = 1
	backdrop.AutoButtonColor = false
	backdrop.Text = ""
	backdrop.ZIndex = Theme.Z.Popover - 1
	backdrop.Parent = gui
	backdrop.Activated:Connect(function() closePalette() end)
	_paletteBackdrop = backdrop

	local pal = Instance.new("Frame")
	pal.Name = "RoutePalette"
	pal.Size = UDim2.fromOffset(4 * 28 + 5 * 6, 2 * 28 + 3 * 6)
	pal.AnchorPoint = Vector2.new(1, 0)
	pal.ZIndex = Theme.Z.Popover
	Glass.apply(pal, Theme.Radius.MD)
	local origin = gui.AbsolutePosition
	local ap = anchor.AbsolutePosition
	pal.Position = UDim2.fromOffset(ap.X - origin.X - 8, ap.Y - origin.Y)
	pal.Parent = gui
	_palette = pal

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 6); pad.PaddingBottom = UDim.new(0, 6)
	pad.PaddingLeft = UDim.new(0, 6); pad.PaddingRight = UDim.new(0, 6)
	pad.Parent = pal
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(28, 28)
	grid.CellPadding = UDim2.fromOffset(6, 6)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = pal

	for i, col in TransitTypes.ROUTE_COLORS do
		local sw = Instance.new("TextButton")
		sw.BackgroundColor3 = col
		sw.BorderSizePixel = 0
		sw.Text = ""
		sw.LayoutOrder = i
		sw.ZIndex = Theme.Z.Popover
		sw.Parent = pal
		corner(sw, 6)
		local idx = i
		sw.Activated:Connect(function()
			Net.RequestTransitCommand:FireServer("setColor", { routeId = routeId, index = idx })
			closePalette()
		end)
	end
end

-- Selecting a line brightens its map overlay (TransitClient) and expands its stop list.
setSelected = function(routeId: number)
	if _selected == routeId then
		_selected = nil
		TransitClient.setActiveRoute(nil)
	else
		_selected = routeId
		TransitClient.setActiveRoute(routeId)
	end
	refresh()
end

-- Builds a card's widgets once; updateRow mutates them each snapshot (no churn).
ensureRow = function(routeId: number): any
	local rec: any = { id = routeId, busCount = 0, fare = 0, enabled = true }
	local scroll = _listScroll :: ScrollingFrame

	local card = Instance.new("Frame")
	card.Name = "Line_" .. routeId
	card.BackgroundColor3 = Theme.Color.BgRaised
	card.BackgroundTransparency = 0.15
	card.BorderSizePixel = 0
	card.Size = UDim2.new(1, -4, 0, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.Parent = scroll
	corner(card, Theme.Radius.MD)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Color.StrokeSoft
	stroke.Thickness = Theme.StrokeWidth.Thin
	stroke.Parent = card
	rec.card = card
	rec.stroke = stroke
	local cpad = Instance.new("UIPadding")
	cpad.PaddingTop = UDim.new(0, 8); cpad.PaddingBottom = UDim.new(0, 8)
	cpad.PaddingLeft = UDim.new(0, 10); cpad.PaddingRight = UDim.new(0, 10)
	cpad.Parent = card
	local clist = Instance.new("UIListLayout")
	clist.FillDirection = Enum.FillDirection.Vertical
	clist.SortOrder = Enum.SortOrder.LayoutOrder
	clist.Padding = UDim.new(0, 6)
	clist.Parent = card

	-- Row A: colour bar | name + sub | net + riders
	local rowA = Instance.new("Frame")
	rowA.BackgroundTransparency = 1
	rowA.Size = UDim2.new(1, 0, 0, 34)
	rowA.LayoutOrder = 1
	rowA.Parent = card

	local colorBar = Instance.new("TextButton")
	colorBar.Position = UDim2.fromOffset(0, 1)
	colorBar.Size = UDim2.fromOffset(6, 32)
	colorBar.BorderSizePixel = 0
	colorBar.AutoButtonColor = false
	colorBar.Text = ""
	colorBar.Parent = rowA
	corner(colorBar, 3)
	colorBar.Activated:Connect(function() openPalette(routeId, colorBar) end)
	rec.colorBar = colorBar

	local textCol = Instance.new("Frame")
	textCol.BackgroundTransparency = 1
	textCol.Position = UDim2.fromOffset(14, 1)
	textCol.Size = UDim2.new(1, -106, 0, 32)
	textCol.Parent = rowA

	local nameBtn = Instance.new("TextButton")
	nameBtn.BackgroundTransparency = 1
	nameBtn.Size = UDim2.new(1, -20, 0, 18)
	nameBtn.Text = "Bus Line"
	nameBtn.TextColor3 = Theme.Color.TextPrimary
	nameBtn.TextSize = Theme.TextSize.SM
	nameBtn.FontFace = Theme.Font.Bold
	nameBtn.TextXAlignment = Enum.TextXAlignment.Left
	nameBtn.TextTruncate = Enum.TextTruncate.AtEnd
	nameBtn.Parent = textCol
	nameBtn.Activated:Connect(function() setSelected(routeId) end)
	rec.nameBtn = nameBtn

	local nameBox = Instance.new("TextBox")
	nameBox.BackgroundColor3 = Theme.Color.Bg
	nameBox.BorderSizePixel = 0
	nameBox.Size = UDim2.new(1, -2, 0, 18)
	nameBox.TextColor3 = Theme.Color.TextPrimary
	nameBox.TextSize = Theme.TextSize.SM
	nameBox.FontFace = Theme.Font.Bold
	nameBox.TextXAlignment = Enum.TextXAlignment.Left
	nameBox.ClearTextOnFocus = false
	nameBox.Visible = false
	nameBox.Text = ""
	nameBox.Parent = textCol
	corner(nameBox, 4)
	rec.nameBox = nameBox

	local pencil = Instance.new("TextButton")
	pencil.AnchorPoint = Vector2.new(1, 0)
	pencil.Position = UDim2.new(1, 0, 0, 0)
	pencil.Size = UDim2.fromOffset(18, 18)
	pencil.BackgroundTransparency = 1
	pencil.Text = "\u{270E}"
	pencil.TextColor3 = Theme.Color.TextSecondary
	pencil.TextSize = Theme.TextSize.XS
	pencil.FontFace = Theme.Font.Bold
	pencil.Parent = textCol

	local subLabel = label(textCol, "", Theme.TextSize.XS, false)
	subLabel.Position = UDim2.fromOffset(0, 19)
	subLabel.Size = UDim2.new(1, 0, 0, 12)
	subLabel.TextColor3 = Theme.Color.TextSecondary
	rec.subLabel = subLabel

	local function commitRename()
		if not nameBox.Visible then return end
		nameBox.Visible = false
		nameBtn.Visible = true
		_editing = nil
		local t = nameBox.Text
		if #t > 0 then
			Net.RequestTransitCommand:FireServer("rename", { routeId = routeId, name = t })
		end
	end
	pencil.Activated:Connect(function()
		_editing = routeId
		nameBox.Text = nameBtn.Text
		nameBtn.Visible = false
		nameBox.Visible = true
		nameBox:CaptureFocus()
	end)
	nameBox.FocusLost:Connect(function() commitRename() end)

	local statCol = Instance.new("Frame")
	statCol.BackgroundTransparency = 1
	statCol.AnchorPoint = Vector2.new(1, 0)
	statCol.Position = UDim2.new(1, 0, 0, 1)
	statCol.Size = UDim2.fromOffset(86, 32)
	statCol.Parent = rowA
	local netLabel = label(statCol, "", Theme.TextSize.SM, true)
	netLabel.Size = UDim2.new(1, 0, 0, 18)
	netLabel.TextXAlignment = Enum.TextXAlignment.Right
	rec.netLabel = netLabel
	local ridersLabel = label(statCol, "", Theme.TextSize.XS, false)
	ridersLabel.Position = UDim2.fromOffset(0, 19)
	ridersLabel.Size = UDim2.new(1, 0, 0, 12)
	ridersLabel.TextXAlignment = Enum.TextXAlignment.Right
	ridersLabel.TextColor3 = Theme.Color.TextSecondary
	rec.ridersLabel = ridersLabel

	-- Row B: usage bar | % | buses | fare | on | delete
	local rowB = Instance.new("Frame")
	rowB.BackgroundTransparency = 1
	rowB.Size = UDim2.new(1, 0, 0, 24)
	rowB.LayoutOrder = 2
	rowB.Parent = card

	local barBg = Instance.new("Frame")
	barBg.AnchorPoint = Vector2.new(0, 0.5)
	barBg.Position = UDim2.new(0, 0, 0.5, 0)
	barBg.Size = UDim2.fromOffset(92, 6)
	barBg.BackgroundColor3 = Theme.Color.Bg
	barBg.BorderSizePixel = 0
	barBg.Parent = rowB
	corner(barBg, 3)
	local barFill = Instance.new("Frame")
	barFill.Size = UDim2.new(0, 0, 1, 0)
	barFill.BackgroundColor3 = Theme.Color.Accent
	barFill.BorderSizePixel = 0
	barFill.Parent = barBg
	corner(barFill, 3)
	rec.barFill = barFill
	local pctLabel = label(rowB, "0%", Theme.TextSize.XS, false)
	pctLabel.AnchorPoint = Vector2.new(0, 0.5)
	pctLabel.Position = UDim2.new(0, 98, 0.5, 0)
	pctLabel.Size = UDim2.fromOffset(30, 16)
	pctLabel.TextColor3 = Theme.Color.TextSecondary
	rec.pctLabel = pctLabel

	rec.busLabel = makeStepper(rowB, 134,
		function() Net.RequestTransitCommand:FireServer("setBuses", { routeId = routeId, n = rec.busCount - 1 }) end,
		function() Net.RequestTransitCommand:FireServer("setBuses", { routeId = routeId, n = rec.busCount + 1 }) end)
	rec.fareLabel = makeStepper(rowB, 196,
		function() Net.RequestTransitCommand:FireServer("setFare", { routeId = routeId, fare = rec.fare - 1 }) end,
		function() Net.RequestTransitCommand:FireServer("setFare", { routeId = routeId, fare = rec.fare + 1 }) end)

	local onBtn = Instance.new("TextButton")
	onBtn.AnchorPoint = Vector2.new(0, 0.5)
	onBtn.Position = UDim2.new(0, 260, 0.5, 0)
	onBtn.Size = UDim2.fromOffset(24, 22)
	onBtn.BackgroundTransparency = 1
	onBtn.Text = "\u{25CF}"
	onBtn.TextSize = Theme.TextSize.MD
	onBtn.FontFace = Theme.Font.Bold
	onBtn.Parent = rowB
	onBtn.Activated:Connect(function()
		Net.RequestTransitCommand:FireServer("toggle", { routeId = routeId, enabled = not rec.enabled })
	end)
	rec.onBtn = onBtn

	local delBtn = Instance.new("TextButton")
	delBtn.AnchorPoint = Vector2.new(1, 0.5)
	delBtn.Position = UDim2.new(1, 0, 0.5, 0)
	delBtn.Size = UDim2.fromOffset(22, 22)
	delBtn.BackgroundTransparency = 1
	delBtn.Text = "\u{1F5D1}"
	delBtn.TextColor3 = Theme.Color.Danger
	delBtn.TextSize = Theme.TextSize.SM
	delBtn.FontFace = Theme.Font.Bold
	delBtn.Parent = rowB
	delBtn.Activated:Connect(function()
		Net.RequestTransitCommand:FireServer("delete", { routeId = routeId })
	end)

	-- Row C (shown when selected): ordered stop list with per-stop boardings
	local stopsWrap = Instance.new("Frame")
	stopsWrap.BackgroundTransparency = 1
	stopsWrap.Size = UDim2.new(1, 0, 0, 0)
	stopsWrap.AutomaticSize = Enum.AutomaticSize.Y
	stopsWrap.LayoutOrder = 3
	stopsWrap.Visible = false
	stopsWrap.Parent = card
	local swList = Instance.new("UIListLayout")
	swList.FillDirection = Enum.FillDirection.Vertical
	swList.SortOrder = Enum.SortOrder.LayoutOrder
	swList.Padding = UDim.new(0, 4)
	swList.Parent = stopsWrap
	local swHeader = label(stopsWrap, "Stops \u{00B7} boardings/mo \u{00B7} right-click a stop in-world to remove", Theme.TextSize.XS, false)
	swHeader.Size = UDim2.new(1, 0, 0, 14)
	swHeader.LayoutOrder = 1
	swHeader.TextColor3 = Theme.Color.TextSecondary
	local chips = Instance.new("Frame")
	chips.BackgroundTransparency = 1
	chips.Size = UDim2.new(1, 0, 0, 0)
	chips.AutomaticSize = Enum.AutomaticSize.Y
	chips.LayoutOrder = 2
	chips.Parent = stopsWrap
	local chipList = Instance.new("UIListLayout")
	chipList.FillDirection = Enum.FillDirection.Horizontal
	chipList.Wraps = true
	chipList.SortOrder = Enum.SortOrder.LayoutOrder
	chipList.Padding = UDim.new(0, 4)
	chipList.Parent = chips
	rec.stopsWrap = stopsWrap
	rec.chips = chips

	return rec
end

updateRow = function(rec: any, route: any, stopById: { [number]: any })
	rec.busCount = route.busCount or 0
	rec.fare = route.fare or 0
	rec.enabled = route.enabled ~= false

	local rc = route.color or Color3.fromRGB(80, 170, 200)
	rec.colorBar.BackgroundColor3 = rc
	if _editing ~= route.id then
		rec.nameBtn.Text = route.name or ("Bus Line " .. route.id)
	end
	-- 4000 studs to the kilometre; Imperial converts off the same number.
	local km = (route.length or 0) / 4000
	local unit = Settings.get("units")
	local dist = if unit == "Imperial" then string.format("%.1f mi", km * 0.621371)
		elseif unit == "Studs" then string.format("%d studs", route.length or 0)
		else string.format("%.1f km", km)
	rec.subLabel.Text = string.format("%s \u{00B7} %d stops", dist, #(route.stops or {}))

	local net = math.floor((route.revenue or 0) - rec.busCount * TransitTypes.BUS_UPKEEP + 0.5)
	rec.netLabel.Text = (if net >= 0 then "+$" else "-$") .. tostring(math.abs(net))
	rec.netLabel.TextColor3 = if net > 0 then Theme.Color.Positive elseif net < 0 then Theme.Color.Danger else Theme.Color.TextSecondary
	rec.ridersLabel.Text = tostring(route.passengers or 0) .. " riders"

	local usage = math.clamp(route.usage or 0, 0, 100)
	rec.barFill.Size = UDim2.new(usage / 100, 0, 1, 0)
	rec.barFill.BackgroundColor3 = if usage >= 95 then Theme.Color.Danger else rc
	rec.pctLabel.Text = string.format("%d%%", math.floor(usage + 0.5))

	rec.busLabel.Text = tostring(rec.busCount)
	rec.fareLabel.Text = "\u{00A2}" .. tostring(rec.fare)

	rec.onBtn.Text = if rec.enabled then "\u{25CF}" else "\u{25CB}"
	rec.onBtn.TextColor3 = if rec.enabled then Theme.Color.Accent else Theme.Color.TextDisabled

	local selected = _selected == route.id
	rec.stroke.Color = if selected then rc else Theme.Color.StrokeSoft
	rec.stroke.Thickness = if selected then Theme.StrokeWidth.Thick else Theme.StrokeWidth.Thin

	rec.stopsWrap.Visible = selected
	if selected then
		for _, c in rec.chips:GetChildren() do
			if c:IsA("Frame") then c:Destroy() end
		end
		for i, sid in (route.stops or {}) do
			local stop = stopById[sid]
			local chip = Instance.new("Frame")
			chip.BackgroundColor3 = Theme.Color.Bg
			chip.BorderSizePixel = 0
			chip.AutomaticSize = Enum.AutomaticSize.X
			chip.Size = UDim2.fromOffset(0, 18)
			chip.LayoutOrder = i
			chip.Parent = rec.chips
			corner(chip, 5)
			local cp = Instance.new("UIPadding")
			cp.PaddingLeft = UDim.new(0, 6); cp.PaddingRight = UDim.new(0, 6)
			cp.Parent = chip
			local txt = label(chip, "", Theme.TextSize.XS, false)
			txt.AutomaticSize = Enum.AutomaticSize.X
			txt.Size = UDim2.fromOffset(0, 18)
			local nm = if stop then tostring(stop.name) else "Stop " .. tostring(sid)
			local b = if stop then (stop.boardings or 0) else 0
			txt.Text = nm .. "  " .. tostring(b)
		end
	end
end

refresh = function()
	if not _open then return end
	local scroll = _listScroll
	if not scroll then return end
	local snap = TransitClient.getSnapshot()

	local routes = {}
	for _, r in (snap.routes or {}) do table.insert(routes, r) end
	table.sort(routes, function(a, b) return a.id < b.id end)

	local stopById: { [number]: any } = {}
	for _, s in (snap.stops or {}) do stopById[s.id] = s end

	local allowance = snap.allowance or 0
	local assigned = snap.assigned or 0
	local riders = 0
	for _, r in routes do riders += (r.passengers or 0) end
	local net = math.floor((snap.revenue or 0) - (snap.upkeep or 0) + 0.5)
	if _busesChip then
		_busesChip.Text = string.format("%d/%d", assigned, allowance)
		_busesChip.TextColor3 = if allowance > 0 and assigned >= allowance then Theme.Color.Danger else Theme.Color.TextPrimary
	end
	if _linesChip then _linesChip.Text = tostring(#routes) end
	if _ridersChip then _ridersChip.Text = tostring(riders) end
	if _netChip then
		_netChip.Text = (if net >= 0 then "+$" else "-$") .. tostring(math.abs(net))
		_netChip.TextColor3 = if net > 0 then Theme.Color.Positive elseif net < 0 then Theme.Color.Danger else Theme.Color.TextPrimary
	end

	local seen: { [number]: boolean } = {}
	for i, route in routes do
		seen[route.id] = true
		local rec = _rows[route.id]
		if not rec then rec = ensureRow(route.id); _rows[route.id] = rec end
		rec.card.LayoutOrder = i
		updateRow(rec, route, stopById)
	end
	for id, rec in _rows do
		if not seen[id] then rec.card:Destroy(); _rows[id] = nil end
	end
	if _emptyLabel then _emptyLabel.Visible = #routes == 0 end
end

local function build()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local gui = playerGui:WaitForChild("CityUI", 60)
	if not gui or not gui:IsA("ScreenGui") then
		warn("[TransportOverviewController] CityUI not found")
		return
	end
	_gui = gui

	local panel = Instance.new("Frame")
	panel.Name = "TransportOverview"
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1, PANEL_W + 24, 0, PANEL_TOP)
	-- Height budget, all in design px (HudScale multiplies them together): the panel starts
	-- at PANEL_TOP and must stop clear of the floating bottom bar, which occupies the last
	-- 82 (BAR_H 72 + BAR_BOTTOM 10). PANEL_TOP + 82 + 14 clearance = 220.
	panel.Size = UDim2.new(0, PANEL_W, 1, -(PANEL_TOP + 96))
	panel.ZIndex = Theme.Z.Flyout
	panel.Visible = false
	Glass.apply(panel, Theme.Radius.LG)
	panel.Parent = gui
	_panel = panel

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, Theme.Pad.LG); pad.PaddingBottom = UDim.new(0, Theme.Pad.LG)
	pad.PaddingLeft = UDim.new(0, Theme.Pad.LG); pad.PaddingRight = UDim.new(0, Theme.Pad.LG)
	pad.Parent = panel

	local title = label(panel, "PUBLIC TRANSPORT", Theme.TextSize.MD, true)
	title.Size = UDim2.new(1, -30, 0, 24)
	title.TextColor3 = Theme.Color.Accent

	local closeBtn = smallBtn(panel, "\u{2715}", 26, function() TransportOverviewController.Close() end)
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Position = UDim2.new(1, 0, 0, 0)

	_busesChip  = metricChip(panel, 0, 84, "Buses")
	_linesChip  = metricChip(panel, 92, 84, "Lines")
	_ridersChip = metricChip(panel, 184, 84, "Riders")
	_netChip    = metricChip(panel, 276, 84, "Net /mo")

	local scroll = Instance.new("ScrollingFrame")
	scroll.Position = UDim2.fromOffset(0, 88)
	scroll.Size = UDim2.new(1, 0, 1, -88)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 5
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.Parent = panel
	_listScroll = scroll

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 8)
	list.Parent = scroll

	local empty = label(scroll, "No bus lines yet. Open the Transit tools to place a depot, drop stops and draw a route.", Theme.TextSize.SM, false)
	empty.Size = UDim2.new(1, -10, 0, 60)
	empty.TextXAlignment = Enum.TextXAlignment.Center
	empty.TextWrapped = true
	empty.TextColor3 = Theme.Color.TextSecondary
	empty.LayoutOrder = 9999
	_emptyLabel = empty
end

function TransportOverviewController.Open()
	local panel = _panel
	if not panel then return end
	_open = true
	-- Shares the right-edge slot with the Dashboard; claiming it closes whichever of the
	-- two was already there rather than letting them stack.
	PanelSlots.claim("rightPanel", "Transport", TransportOverviewController.Close)
	TransitClient.setMode("overview", true)
	refresh()
	panel.Visible = true
	panel.Position = UDim2.new(1, PANEL_W + 24, 0, PANEL_TOP)
	UITween.to(panel, "Flyout", { Position = UDim2.new(1, -12, 0, PANEL_TOP) })
end

function TransportOverviewController.Close()
	local panel = _panel
	if not panel then return end
	_open = false
	PanelSlots.release("rightPanel", "Transport")
	closePalette()
	TransitClient.setMode("overview", false)
	local tween = UITween.to(panel, "Flyout", { Position = UDim2.new(1, PANEL_W + 24, 0, PANEL_TOP) })
	tween.Completed:Once(function()
		if not _open then panel.Visible = false end
	end)
end

function TransportOverviewController.Toggle()
	if _open then TransportOverviewController.Close() else TransportOverviewController.Open() end
end

function TransportOverviewController.IsOpen(): boolean
	return _open
end

function TransportOverviewController.Start()
	if _started then return end
	_started = true
	build()
	require(ReplicatedStorage:WaitForChild("City"):WaitForChild("UIEvents")).SettingsOpened.Event:Connect(function()
		TransportOverviewController.Close()
	end)
	TransitClient.onChanged(function()
		if _open then refresh() end
	end)
end

return TransportOverviewController
