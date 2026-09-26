--!strict
-- The Roads page of the shared build dock (bottom-right). Owns everything about
-- drawing a road: the draw-mode rail, the live cross-section + width / elevation
-- / speed readouts, the style tray (sidewalk / parking / median / colour), the
-- category tabs and the road-type cards.
--
-- Split out of BottomBarController, which was at Luau's 200-register ceiling.
-- BottomBarController is the only caller: it injects the dock, the host ScreenGui
-- and RoadPlacementController through Init, then drives Show / Activate /
-- Deactivate / Refresh from the section lifecycle.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local uiFolder = script.Parent.Parent:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local Icons = require(uiFolder:WaitForChild("Icons"))
local UITween = require(uiFolder:WaitForChild("UITween"))
local HudScale = require(uiFolder:WaitForChild("HudScale"))
local kit = uiFolder:WaitForChild("Kit")
local IconButton = require(kit:WaitForChild("IconButton"))
local Tooltip = require(kit:WaitForChild("Tooltip"))
local Button = require(kit:WaitForChild("Button"))
local Popover = require(kit:WaitForChild("Popover"))
local Dock = require(kit:WaitForChild("Dock"))
local Tab = require(kit:WaitForChild("Tab"))
local BuildCard = require(kit:WaitForChild("BuildCard"))

local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local DevelopmentTree = require(ReplicatedStorage.City.DevelopmentTree)
-- Car parks are catalogue props: the Parking tab picks one and hands the cursor to the
-- same placement tool the Nature tab uses, so placement, cost, ghosting, persistence and
-- bulldozing are the ones that already work rather than a second copy of all of it.
local NatureCatalog = require(ReplicatedStorage.Nature.NatureCatalog)
local Nature = require(script.Parent:WaitForChild("NaturePlacementController"))

local RoadDockPanel = {}

-- Injected by Init.
local _road: any = nil
local _dock: Dock.Dock? = nil

local _roadsScroll: ScrollingFrame? = nil
local _tabs: { [string]: Tab.Tab } = {}
-- Road config state. _cfg holds only the player's overrides; nil fields fall back to
-- the base road type's defaults. The encoded id is rebuilt from (_cfgBaseId, _cfg) on change.
local _cfgBaseId: string = RoadTypeCatalog.DEFAULT_ID
local _cfg: RoadTypeCatalog.RoadConfig = {}
-- Whether a road type is currently selected for drawing. Click the active card again to
-- deselect (neutral road mode -- left-click draws nothing, right-click flips one-way roads).
local _roadSelected = false
local _cfgPreviewHolder: Frame? = nil
local _cfgWidthLabel: TextLabel? = nil
local _cfgSpeedLabel: TextLabel? = nil
local _cfgRefreshers: { () -> () } = {}
local _roadCardStrokes: { [string]: UIStroke } = {}
local _roadCards: { [string]: CanvasGroup } = {}

-- Parking tab state. The lot keys come off the catalog rather than a second hand-kept
-- list -- adding a fourth size to NatureCatalog is then the only edit.
local LOT_KEYS: { string } = {}
for _, k in NatureCatalog.order do
	local e = NatureCatalog.byKey[k]
	if e and e.kind == "Lot" then table.insert(LOT_KEYS, k) end
end
local LOT_ASPHALT = Color3.fromRGB(74, 74, 78)
local LOT_PAINT = Color3.fromRGB(238, 238, 232)
local _parkScroll: ScrollingFrame? = nil
local _parkStrokes: { [string]: UIStroke } = {}
local _parkTitle: TextLabel? = nil
local _parkCap: TextLabel? = nil
local _parkInfo: Frame? = nil
local _roadInfo: Frame? = nil
local _rail: Frame? = nil
local _parkKey: string? = nil
local _parkActive = false

local function corner(parent: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = parent
end

local TAB_DEFS = {
	{ label = "Local", key = "Local" },
	{ label = "Urban", key = "Urban" },
	{ label = "One-Way", key = "One-Way" },
	{ label = "Transit", key = "Transit" },
	{ label = "Highway", key = "Highway" },
	-- A car park is road infrastructure, not scenery, so it lives on the Roads page.
	{ label = "Parking", key = "Parking" },
}

local CARD_TABS: { [string]: { [string]: boolean } } = {
	OneWay = { ["One-Way"] = true },
	OneWay2Lane = { ["One-Way"] = true },
	OneWay3Lane = { ["One-Way"] = true },
	OneWay3LaneBus = { Urban = true, ["One-Way"] = true, Transit = true },
	NarrowRoad = { Local = true },
	Alley = { Local = true },
	AlleyOneWay = { Local = true, ["One-Way"] = true },
	CollectorRoad = { Urban = true },
	-- Bus roads and rail share the Transit tab; the bus lanes also live with the
	-- avenues they're built from. Every road type must map to at least one tab --
	-- there is no "All" fallback.
	CollectorRoadBus = { Urban = true, Transit = true },
	BuswayTwoWay = { Transit = true },
	BuswayOneWay = { Transit = true, ["One-Way"] = true },
	Rail = { Transit = true },
	Highway2 = { Highway = true },
	Highway4 = { Highway = true },
	Highway1W = { Highway = true, ["One-Way"] = true },
	Highway2W = { Highway = true, ["One-Way"] = true },
	Highway3W = { Highway = true, ["One-Way"] = true },
	Highway4W = { Highway = true, ["One-Way"] = true },
	Highway5W = { Highway = true, ["One-Way"] = true },
}

-- Accurate top-down cross-section of a (resolved) road spec, drawn VERTICALLY (the road runs
-- top->bottom, like the CS2 cards). Shows the real footprint: sidewalks, parking/verge on the
-- correct side(s), the carriageway split into laneCount lanes with matching markings, and a
-- centre median. Shared by the road-type cards and the dock's live preview, so what you see is
-- exactly what gets built.
local CS_GREEN = Color3.fromRGB(80, 120, 60)
local function buildRoadCrossSection(container: Frame, spec: RoadTypeCatalog.RoadTypeSpec)
	for _, ch in container:GetChildren() do
		if ch:IsA("GuiObject") then ch:Destroy() end
	end
	local SW = RoadConstants.SIDEWALK_WIDTH
	local swMode = spec.sidewalkMode or (if spec.noSidewalk then "none" else "both")
	local hasL = swMode == "both" or swMode == "left"
	local hasR = swMode == "both" or swMode == "right"
	local surfW = spec.width
	local total = surfW + (if hasL then SW else 0) + (if hasR then SW else 0)
	local function frac(studs: number): number return studs / math.max(total, 1) end
	local function band(x0: number, x1: number, col: Color3, zi: number): Frame?
		if x1 - x0 <= 0 then return nil end
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0, 0)
		f.Position = UDim2.new(frac(x0), 0, 0, 0)
		f.Size = UDim2.new(frac(x1 - x0), 0, 1, 0)
		f.BackgroundColor3 = col
		f.BorderSizePixel = 0
		f.ZIndex = zi
		f.Parent = container
		return f
	end
	local function lineAt(xStud: number, hwStud: number, col: Color3, dashed: boolean, zi: number)
		local f = band(xStud - hwStud, xStud + hwStud, col, zi)
		if dashed and f then
			for i = 0, 5 do
				local g = Instance.new("Frame")
				g.AnchorPoint = Vector2.new(0.5, 0)
				g.Position = UDim2.fromScale(0.5, i / 6 + 0.015)
				g.Size = UDim2.fromScale(2, 0.085)
				g.BackgroundColor3 = spec.surfaceColor
				g.BorderSizePixel = 0
				g.ZIndex = zi + 1
				g.Parent = f
			end
		end
	end
	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = CS_GREEN
	bg.BackgroundTransparency = 0.25
	bg.BorderSizePixel = 0
	bg.ZIndex = 1
	bg.Parent = container
	local x = 0
	if hasL then band(x, x + SW, RoadConstants.SIDEWALK_COLOR, 4); x += SW end
	local s0 = x
	band(s0, s0 + surfW, spec.surfaceColor, 2)
	if hasR then band(s0 + surfW, s0 + surfW + SW, RoadConstants.SIDEWALK_COLOR, 4) end
	local apronMinus, apronPlus = 0, 0
	local vergeMinus, vergePlus = 0, 0
	local plW = spec.parkingLaneWidth or 0
	if spec.parkingLane then
		local side = spec.parkingSide or "both"
		if side == "left" then apronMinus = plW elseif side == "right" then apronPlus = plW else apronMinus, apronPlus = plW, plW end
	end
	if spec.vergeMode then
		local vW = spec.vergeWidth or 4
		vergeMinus = vW
		vergePlus = if spec.vergeMode == "both" then vW else 0
		apronMinus += vergeMinus
		apronPlus += vergePlus
		-- Verge outermost, parking apron inside it -- the stacking the renderer builds.
		if vergeMinus > 0 then band(s0, s0 + vergeMinus, CS_GREEN, 3) end
		if vergePlus > 0 then band(s0 + surfW - vergePlus, s0 + surfW, CS_GREEN, 3) end
	end
	local cw0 = s0 + apronMinus
	local cw1 = s0 + surfW - apronPlus
	local cwW = math.max(cw1 - cw0, 1)
	local lanes = math.max(1, spec.laneCount or 2)
	local lhw = math.max(total * 0.006, 0.25)
	local laneCol = spec.laneLineColor or RoadConstants.MARKING_WHITE
	local mid = (cw0 + cw1) / 2
	if spec.median then
		local mW = spec.medianWidth or 4
		band(mid - mW / 2, mid + mW / 2, CS_GREEN, 5)
	end
	for i = 1, lanes - 1 do
		local lx = cw0 + cwW * (i / lanes)
		local isCenter = i == lanes / 2
		if isCenter then
			if not spec.median and spec.centerLineColor then
				lineAt(lx, lhw * 1.3, spec.centerLineColor, spec.centerLineDashed == true, 6)
			end
		else
			lineAt(lx, lhw, laneCol, spec.laneLineDashed ~= false, 6)
		end
	end
	if spec.edgeLineColor and not spec.vergeMode then
		-- Against the footway, outside any parking apron -- where the renderer paints it.
		lineAt(s0 + lhw, lhw, spec.edgeLineColor, false, 6)
		lineAt(s0 + surfW - lhw, lhw, spec.edgeLineColor, false, 6)
	end
end

local function build2DPreview(container: Frame, spec: RoadTypeCatalog.RoadTypeSpec)
	buildRoadCrossSection(container, spec)
	local badge = Instance.new("TextLabel")
	badge.AnchorPoint = Vector2.new(1, 0)
	badge.Position = UDim2.new(1, -4, 0, 4)
	badge.Size = UDim2.fromOffset(22, 15)
	badge.BackgroundColor3 = Theme.Color.Scrim
	badge.BackgroundTransparency = 0.35
	badge.Text = tostring(spec.laneCount or 2) .. "L"
	badge.TextColor3 = Theme.Color.TextPrimary
	badge.TextSize = 9
	badge.FontFace = Theme.Font.Bold
	badge.BorderSizePixel = 0
	badge.ZIndex = 8
	badge.Parent = container
	corner(badge, 4)
end

-- Bays in a baked lot, counted off the template's stall markers -- the same attachments
-- ParkingService turns into real spots, so the number on the card is the number of cars
-- that can actually park there.
local function lotBays(key: string): number
	local t = ReplicatedStorage.Nature:FindFirstChild(key)
	if not t then return 0 end
	local n = 0
	for _, d in t:GetDescendants() do
		if d:IsA("Attachment") and d.Name == "Stall" then n += 1 end
	end
	return n
end

-- Card art: a top-down asphalt pad drawn at this lot's width relative to the biggest one,
-- with bay ticks. Enough to tell the three apart; the real plan is the ghost on the cursor.
local function buildLotPreview(container: Frame, frac: number)
	for _, ch in container:GetChildren() do
		if ch:IsA("GuiObject") then ch:Destroy() end
	end
	local pad = Instance.new("Frame")
	pad.AnchorPoint = Vector2.new(0.5, 0)
	pad.Position = UDim2.new(0.5, 0, 0, 5)
	pad.Size = UDim2.new(frac, -10, 1, -32)
	pad.BackgroundColor3 = LOT_ASPHALT
	pad.BorderSizePixel = 0
	pad.Parent = container
	corner(pad, 3)
	for r = 1, 2 do
		for i = 1, 5 do
			local tick = Instance.new("Frame")
			tick.AnchorPoint = Vector2.new(0.5, 0.5)
			tick.Position = UDim2.fromScale(i / 6, if r == 1 then 0.28 else 0.72)
			tick.Size = UDim2.new(0, 1, 0.32, 0)
			tick.BackgroundColor3 = LOT_PAINT
			tick.BackgroundTransparency = 0.15
			tick.BorderSizePixel = 0
			tick.Parent = pad
		end
	end
end

local function setSelectedRoad(roadId: string?)
	for id, stroke in _roadCardStrokes do
		stroke.Color = if id == roadId then Theme.Color.Accent else Theme.Color.StrokeSoft
		stroke.Thickness = if id == roadId then Theme.StrokeWidth.Thick else Theme.StrokeWidth.Thin
	end
end

-- =====================================================================
--  ROAD CONFIG PANEL (sidewalk / median / colour / speed)
--  Per-road options set before drawing. Each control rewrites the encoded roadType id
--  (RoadTypeCatalog.encodeConfig) and re-selects it, so the ghost preview, placement and
--  the placed segment all carry the configuration. New roads only -- see the encoded-id
--  resolver in RoadTypeCatalog for why this needs no per-segment plumbing.
-- =====================================================================
local COLOR_SWATCHES: { { name: string, color: Color3? } } = {
	{ name = "Default",  color = nil },
	{ name = "Red",      color = Color3.fromRGB(196, 54, 54) },
	{ name = "Charcoal", color = Color3.fromRGB(56, 58, 62) },
	{ name = "White",    color = Color3.fromRGB(206, 206, 200) },
	{ name = "Sand",     color = Color3.fromRGB(178, 156, 116) },
	{ name = "Blue",     color = Color3.fromRGB(56, 92, 150) },
}
local SIDEWALK_OPTS = { { k = "none", t = "None" }, { k = "left", t = "Left" }, { k = "both", t = "Both" }, { k = "right", t = "Right" } }
local MEDIAN_OPTS   = { { k = "none", t = "None" }, { k = "center", t = "Center" }, { k = "left", t = "Left" }, { k = "both", t = "Both" } }
local PARKING_OPTS  = { { k = "none", t = "None" }, { k = "left", t = "Left" }, { k = "right", t = "Right" }, { k = "both", t = "Both" } }
-- Street trees, planted on both kerbs. The key is a ReplicatedStorage.Nature model name
-- (a NatureCatalog Tree entry); it rides in the encoded road id as "tr=OakTree".
local TREE_OPTS = {
	{ k = "none", t = "None" }, { k = "OakTree", t = "Oak" }, { k = "ChestnutTree", t = "Chestnut" },
	{ k = "BirchTree", t = "Birch" }, { k = "PoplarTree", t = "Poplar" }, { k = "PineTree", t = "Pine" },
	{ k = "SpruceTree", t = "Spruce" }, { k = "PalmMedium", t = "Palm" },
}

local applyConfig: () -> ()
local refreshConfigPanel: () -> ()
local setTabActive: (key: string) -> ()

local function activeSidewalk(spec: RoadTypeCatalog.RoadTypeSpec): string
	return _cfg.sidewalk or (if spec.noSidewalk then "none" else "both")
end
local function activeMedian(): string
	return _cfg.median or "none"
end
local function activeTrees(): string
	return _cfg.trees or "none"
end
local function activeParking(spec: RoadTypeCatalog.RoadTypeSpec): string
	return _cfg.parking or (if spec.parkingLane then (spec.parkingSide or "both") else "none")
end

local function buildSegRow(parent: Instance, order: number, labelText: string, opts: { { k: string, t: string } }, getActive: () -> string, onPick: (string) -> ())
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 24)
	row.LayoutOrder = order
	row.Parent = parent
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.fromOffset(58, 24)
	lbl.Text = labelText
	lbl.TextColor3 = Theme.Color.TextSecondary
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.TextSize = Theme.TextSize.XS
	lbl.FontFace = Theme.Font.Label
	lbl.Parent = row
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(1, 0.5)
	holder.Position = UDim2.new(1, 0, 0.5, 0)
	holder.Size = UDim2.new(1, -62, 1, 0)
	holder.Parent = row
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.HorizontalAlignment = Enum.HorizontalAlignment.Right
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 4)
	list.Parent = holder
	local entries: { { b: TextButton, s: UIStroke, k: string } } = {}
	for i, opt in opts do
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(52, 22)
		b.BackgroundColor3 = Theme.Color.BgRaised
		b.BackgroundTransparency = 0.45
		b.AutoButtonColor = false
		b.Text = opt.t
		b.TextColor3 = Theme.Color.TextPrimary
		b.TextSize = Theme.TextSize.XS
		b.FontFace = Theme.Font.Label
		b.BorderSizePixel = 0
		b.LayoutOrder = i
		b.Parent = holder
		corner(b, 5)
		local stroke = Instance.new("UIStroke")
		stroke.Color = Theme.Color.StrokeSoft
		stroke.Thickness = Theme.StrokeWidth.Thin
		stroke.Parent = b
		entries[#entries + 1] = { b = b, s = stroke, k = opt.k }
		local key = opt.k
		b.Activated:Connect(function() onPick(key) end)
	end
	_cfgRefreshers[#_cfgRefreshers + 1] = function()
		local active = getActive()
		for _, e in entries do
			local on = e.k == active
			-- Selected = inverted: white fill, black text. Unselected = dim raised chip.
			e.b.BackgroundColor3 = if on then Color3.new(1, 1, 1) else Theme.Color.BgRaised
			e.b.BackgroundTransparency = if on then 0 else 0.5
			e.b.TextColor3 = if on then Color3.new(0, 0, 0) else Theme.Color.TextPrimary
			e.s.Color = if on then Color3.new(1, 1, 1) else Theme.Color.StrokeSoft
			e.s.Thickness = Theme.StrokeWidth.Thin
		end
	end
end

local function buildSwatchRow(parent: Instance, order: number)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 26)
	row.LayoutOrder = order
	row.Parent = parent
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.fromOffset(58, 26)
	lbl.Text = "Colour"
	lbl.TextColor3 = Theme.Color.TextSecondary
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.TextSize = Theme.TextSize.XS
	lbl.FontFace = Theme.Font.Label
	lbl.Parent = row
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(1, 0.5)
	holder.Position = UDim2.new(1, 0, 0.5, 0)
	holder.Size = UDim2.new(1, -62, 1, 0)
	holder.Parent = row
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.HorizontalAlignment = Enum.HorizontalAlignment.Right
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 6)
	list.Parent = holder
	local entries: { { s: UIStroke, c: Color3? } } = {}
	for i, sw in COLOR_SWATCHES do
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(22, 22)
		b.Text = if sw.color == nil then "\u{2014}" else ""
		b.TextColor3 = Theme.Color.TextSecondary
		b.TextSize = Theme.TextSize.XS
		b.FontFace = Theme.Font.Label
		b.AutoButtonColor = false
		b.BackgroundColor3 = sw.color or Theme.Color.BgRaised
		b.BorderSizePixel = 0
		b.LayoutOrder = i
		b.Parent = holder
		corner(b, 11)
		local stroke = Instance.new("UIStroke")
		stroke.Color = Theme.Color.StrokeSoft
		stroke.Thickness = Theme.StrokeWidth.Thin
		stroke.Parent = b
		entries[#entries + 1] = { s = stroke, c = sw.color }
		local color = sw.color
		b.Activated:Connect(function() _cfg.color = color; applyConfig() end)
	end
	_cfgRefreshers[#_cfgRefreshers + 1] = function()
		local cur = _cfg.color
		for _, e in entries do
			local on = (e.c == nil and cur == nil) or (e.c ~= nil and cur ~= nil and e.c == cur)
			e.s.Color = if on then Theme.Color.Accent else Theme.Color.StrokeSoft
			e.s.Thickness = if on then Theme.StrokeWidth.Thick else Theme.StrokeWidth.Thin
		end
	end
end

-- Draw/elevation/snap tools, replicated from the shared ToolStrip's road row but living
-- inside the unified dock. Wired to the same RoadPlacementController API the ToolStrip uses.
local _roadCardsRegion: Frame? = nil
local _roadToolBtns: { [string]: any } = {}
local _roadSnapBtns: { [string]: any } = {}
local _roadElevLabel: TextLabel? = nil
local _roadSizeBtn: TextButton? = nil
local _roadCentreBtn: TextButton? = nil

local function refreshRoadTools()
	if not _road then return end
	local mode = if _road.getMode then _road.getMode() else "Straight"
	local editMode = if _road.getEditMode then _road.getEditMode() else "None"
	local isUpgrade = editMode == "UpgradeReplace"
	local sel: { [string]: boolean } = {
		Straight = not isUpgrade and mode == "Straight",
		Curved = not isUpgrade and mode == "Curved",
		Freeform = not isUpgrade and mode == "Freeform",
		AdvancedCurve = not isUpgrade and mode == "AdvancedCurve",
		Roundabout = not isUpgrade and mode == "Roundabout",
		Upgrade = isUpgrade,
		Parallel = _road.isParallelModeEnabled ~= nil and _road.isParallelModeEnabled(),
	}
	for key, btn in _roadToolBtns do
		if sel[key] ~= nil then btn:SetSelected(sel[key]) end
	end
	if _roadSizeBtn then
		_roadSizeBtn.Visible = sel.Roundabout == true
		if _road.getRoundaboutSize then
			_roadSizeBtn.Text = string.sub(_road.getRoundaboutSize(), 1, 1)
		end
	end
	if _roadCentreBtn then
		_roadCentreBtn.Visible = sel.Roundabout == true and _road.getRoundaboutPreset ~= nil
		if _road.getRoundaboutPreset then
			_roadCentreBtn.Text = string.sub(_road.getRoundaboutPreset(), 1, 1)
		end
	end
	if _roadElevLabel and _road.getElevation then
		local e = math.round(_road.getElevation())
		_roadElevLabel.Text = (if e > 0 then "+" else "") .. tostring(e) .. "m"
	end
	if _roadSnapBtns.Road and _road.isRoadSnapEnabled then _roadSnapBtns.Road:SetSelected(_road.isRoadSnapEnabled()) end
	if _roadSnapBtns.Guide and _road.isGuideEnabled then _roadSnapBtns.Guide:SetSelected(_road.isGuideEnabled()) end
	if _roadSnapBtns.Grid and _road.isGridEnabled then _roadSnapBtns.Grid:SetSelected(_road.isGridEnabled()) end
	if _roadSnapBtns.Angle and _road.isAngleSnapEnabled then _roadSnapBtns.Angle:SetSelected(_road.isAngleSnapEnabled()) end
	local pbar = _roadToolBtns.ParBar
	if pbar then
		pbar.Visible = sel.Parallel == true
		local off = _roadToolBtns.ParOff
		if off and _road.getParallelGap then
			off.Text = "Gap: " .. string.format("%g", _road.getParallelGap())
		end
	end
end

-- Left rail: how-you-draw tools in a 2-wide grid. Elevation + road style
-- moved to the dock's info bar; cards + tabs live on the shared Dock frame.
local function buildRoadRail(page: Dock.Page, dockObj: Dock.Dock, gui: ScreenGui)
	-- TEMPLATE, top-left: EVERY road tool together -- the four draw modes plus
	-- upgrade, parallel and snap. They were briefly split across the header's two
	-- clusters; they belong in one group, and the right-hand cluster is for the
	-- road's SETTINGS (elevation, speed, style), not more tools.
	local row = page.Rail
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, Theme.Pad.XS)
	pad.PaddingLeft = UDim.new(0, Theme.Pad.XS)
	pad.Parent = row
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(26, 26)
	grid.CellPadding = UDim2.fromOffset(4, 4)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = row
	local function modeBtn(o: number, label: string, icon: any, modeKey: string)
		_roadToolBtns[modeKey] = IconButton.new({
			icon = icon, name = label, tooltip = label, parent = row, size = 26, layoutOrder = o,
			onClick = function() _road.setMode(modeKey); _road.setEditMode("None"); refreshRoadTools() end,
		})
	end
	modeBtn(1, "Line", Icons.RoadStraight, "Straight")
	modeBtn(2, "Curve", Icons.RoadCurved, "Curved")
	modeBtn(3, "Freeform", Icons.RoadFreeform, "Freeform")
	modeBtn(4, "Bezier", Icons.RoadBezier, "AdvancedCurve")
	modeBtn(5, "Roundabout", Icons.RoadRoundabout, "Roundabout")
	-- Ring size preset chip (S/M/L): cycles on click, shown only while the
	-- roundabout tool is active.
	local sizeBtn = Instance.new("TextButton")
	sizeBtn.Name = "RoundaboutSize"
	sizeBtn.LayoutOrder = 7
	sizeBtn.BackgroundColor3 = Theme.Color.BgRaised
	sizeBtn.BackgroundTransparency = 0.45
	sizeBtn.AutoButtonColor = false
	sizeBtn.Text = "M"
	sizeBtn.TextColor3 = Theme.Color.TextPrimary
	sizeBtn.TextSize = Theme.TextSize.XS
	sizeBtn.FontFace = Theme.Font.Label
	sizeBtn.BorderSizePixel = 0
	sizeBtn.Visible = false
	sizeBtn.Parent = row
	corner(sizeBtn, 5)
	sizeBtn.Activated:Connect(function()
		if _road.cycleRoundaboutSize then _road.cycleRoundaboutSize() end
		refreshRoadTools()
	end)
	_roadSizeBtn = sizeBtn
	-- Centre preset chip (Empty / Tree / Garden / Palms / Fountain): cycles on click. New
	-- roundabouts get it; clicking inside an existing ring with the tool applies it there.
	local centreBtn = Instance.new("TextButton")
	centreBtn.Name = "RoundaboutCentre"
	centreBtn.LayoutOrder = 8
	centreBtn.BackgroundColor3 = Theme.Color.BgRaised
	centreBtn.BackgroundTransparency = 0.45
	centreBtn.AutoButtonColor = false
	centreBtn.Text = "E"
	centreBtn.TextColor3 = Theme.Color.TextPrimary
	centreBtn.TextSize = Theme.TextSize.XS
	centreBtn.FontFace = Theme.Font.Label
	centreBtn.BorderSizePixel = 0
	centreBtn.Visible = false
	centreBtn.Parent = row
	corner(centreBtn, 5)
	centreBtn.Activated:Connect(function()
		if _road.cycleRoundaboutPreset then _road.cycleRoundaboutPreset() end
		refreshRoadTools()
	end)
	Tooltip.attach(centreBtn, function()
		local preset = if _road.getRoundaboutPreset then _road.getRoundaboutPreset() else "Empty"
		return `Centre: {preset} -- click a roundabout to give it this centre`
	end)
	_roadCentreBtn = centreBtn
	_roadToolBtns.Upgrade = IconButton.new({
		icon = Icons.RoadUpgrade, name = "Upgrade", tooltip = "Upgrade road", parent = row, size = 26, layoutOrder = 6,
		onClick = function()
			local em = if _road.getEditMode then _road.getEditMode() else "None"
			_road.setEditMode(if em == "UpgradeReplace" then "None" else "UpgradeReplace")
			refreshRoadTools()
		end,
	})
	-- Undo/Redo are KEYS ONLY (Ctrl+Z / Ctrl+Y, rebindable at Settings > Keyboard >
	-- Editing). RoadPlacementController binds them globally -- deliberately not
	-- gated on the road tool -- so they keep working with this rail shut, which
	-- is what made two permanent buttons here pure height.
	_roadToolBtns.Parallel = IconButton.new({
		icon = Icons.RoadParallel, name = "Parallel", tooltip = "Parallel roads", parent = row, size = 26, layoutOrder = 10,
		onClick = function() _road.setParallelModeEnabled(not _road.isParallelModeEnabled()); refreshRoadTools() end,
	})
	local snapBtn = IconButton.new({ icon = Icons.Snap, name = "SnapMenu", tooltip = "Snap options", parent = row, size = 26, layoutOrder = 13 })
	-- Snap options open as a full-height column BETWEEN the rail and the cards:
	-- the dock widens leftward and its info/body shift right, so the column gets
	-- its own slot instead of covering the content.
	local BASE_H = Dock.SHELF_H
	local COL_W, COL_GAP = 148, 10
	-- Snap options used to open as a column carved out of the dock: the panel grew
	-- wider and the info/body slid right to make room. Neither move survives the
	-- rebuilt bones -- the shelf is full-bleed (so the dock's own fit() owns the
	-- width) and it is now ONE surface with the rail across the top, so there is
	-- no rail-to-cards gutter to carve. The popover simply floats above the shelf,
	-- which is what the space is for.
	local function setExpanded(_open: boolean) end
	local snapScale = Instance.new("UIScale")
	local snapPop = Popover.new({
		anchor = snapBtn.Instance, parent = gui,
		-- Height comes from the toggles (AutomaticSize below); a fixed height cut
		-- the last one off.
		size = UDim2.fromOffset(COL_W, 0),
		name = "DockSnapPopover",
		-- Default placement: centred over the snap button, clamped on screen. The
		-- gap clears the header band the button sits in.
		gap = 12,
		onOpenChanged = function(open: boolean)
			snapBtn:SetSelected(open)
			if open then snapScale.Scale = dockObj:Scale() end
			setExpanded(open)
		end,
	})
	snapScale.Parent = snapPop.Frame
	snapPop.Frame.AutomaticSize = Enum.AutomaticSize.Y
	local snapHead = Instance.new("TextLabel")
	snapHead.BackgroundTransparency = 1
	snapHead.Size = UDim2.new(1, 0, 0, 14)
	snapHead.LayoutOrder = 0
	snapHead.Text = "SNAP"
	snapHead.TextColor3 = Theme.Color.Brand
	snapHead.TextSize = Theme.TextSize.XS
	snapHead.FontFace = Theme.Font.Header
	snapHead.TextXAlignment = Enum.TextXAlignment.Left
	snapHead.Parent = snapPop.Frame
	local sl = Instance.new("UIListLayout")
	sl.FillDirection = Enum.FillDirection.Vertical
	sl.HorizontalAlignment = Enum.HorizontalAlignment.Center
	sl.SortOrder = Enum.SortOrder.LayoutOrder
	sl.Padding = UDim.new(0, Theme.Pad.SM)
	sl.Parent = snapPop.Frame
	local function snapToggle(o: number, label: string, key: string, isOn: () -> boolean, setOn: (boolean) -> ())
		_roadSnapBtns[key] = Button.new({
			text = label, parent = snapPop.Frame, size = UDim2.new(1, 0, 0, 26), layoutOrder = o,
			onClick = function() setOn(not isOn()); refreshRoadTools() end,
		})
	end
	snapToggle(1, "Road Snap", "Road", function() return _road.isRoadSnapEnabled() end, function(on) _road.setRoadSnapEnabled(on) end)
	snapToggle(2, "Guide", "Guide", function() return _road.isGuideEnabled() end, function(on) _road.setGuideEnabled(on) end)
	snapToggle(4, "Angle", "Angle", function() return _road.isAngleSnapEnabled() end, function(on) _road.setAngleSnapEnabled(on) end)
	snapBtn.Instance.Activated:Connect(function() snapPop:Toggle() end)

	-- Parallel-offset control: floats above the dock, shown only while parallel mode is on.
	-- Inlined (no new top-level locals; refs stashed in _roadToolBtns) -- the module sits at
	-- the 200-register chunk ceiling, so a module-level local or function would overflow it.
	local pbar = Instance.new("Frame")
	pbar.Name = "ParallelBar"
	pbar.AnchorPoint = Vector2.new(0.5, 1)
	pbar.Position = UDim2.new(0.5, 0, 1, -150)
	pbar.AutomaticSize = Enum.AutomaticSize.X
	pbar.Size = UDim2.fromOffset(0, 34)
	pbar.BackgroundColor3 = Theme.Color.BgRaised
	pbar.BackgroundTransparency = 0.15
	pbar.BorderSizePixel = 0
	pbar.Visible = false
	pbar.ZIndex = Theme.Z.HUD
	pbar.Parent = gui
	corner(pbar, 8)
	local pstroke = Instance.new("UIStroke")
	pstroke.Color = Theme.Color.StrokeSoft
	pstroke.Thickness = Theme.StrokeWidth.Thin
	pstroke.Parent = pbar
	local pl = Instance.new("UIListLayout")
	pl.FillDirection = Enum.FillDirection.Horizontal
	pl.VerticalAlignment = Enum.VerticalAlignment.Center
	pl.SortOrder = Enum.SortOrder.LayoutOrder
	pl.Padding = UDim.new(0, 6)
	pl.Parent = pbar
	local ppad = Instance.new("UIPadding")
	ppad.PaddingLeft = UDim.new(0, 10)
	ppad.PaddingRight = UDim.new(0, 10)
	ppad.Parent = pbar
	local pcap = Instance.new("TextLabel")
	pcap.BackgroundTransparency = 1
	pcap.Size = UDim2.fromOffset(56, 34)
	pcap.Text = "Parallel"
	pcap.TextColor3 = Theme.Color.TextPrimary
	pcap.TextSize = Theme.TextSize.XS
	pcap.FontFace = Theme.Font.Header
	pcap.TextXAlignment = Enum.TextXAlignment.Left
	pcap.LayoutOrder = 1
	pcap.ZIndex = pbar.ZIndex
	pcap.Parent = pbar
	local function pbtn(txt: string, o: number, d: number)
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(26, 26)
		b.BackgroundColor3 = Theme.Color.BgRaised
		b.AutoButtonColor = true
		b.Text = txt
		b.TextColor3 = Theme.Color.TextPrimary
		b.TextSize = 16
		b.FontFace = Theme.Font.Bold
		b.BorderSizePixel = 0
		b.LayoutOrder = o
		b.ZIndex = pbar.ZIndex
		b.Parent = pbar
		corner(b, 6)
		b.Activated:Connect(function() if _road.adjustParallelGap then _road.adjustParallelGap(d); refreshRoadTools() end end)
	end
	pbtn("\u{2212}", 2, -1)
	local pv = Instance.new("TextLabel")
	pv.BackgroundTransparency = 1
	pv.Size = UDim2.fromOffset(78, 34)
	pv.Text = "Offset: --"
	pv.TextColor3 = Theme.Color.TextPrimary
	pv.TextSize = Theme.TextSize.XS
	pv.FontFace = Theme.Font.Bold
	pv.TextXAlignment = Enum.TextXAlignment.Center
	pv.LayoutOrder = 3
	pv.ZIndex = pbar.ZIndex
	pv.Parent = pbar
	pbtn("+", 4, 1)
	_roadToolBtns.ParBar = pbar
	_roadToolBtns.ParOff = pv

	_cfgRefreshers[#_cfgRefreshers + 1] = refreshRoadTools
end

-- The unified bottom-right Road dock on the shared Dock frame: info bar on
-- top (preview / width / elevation / speed / style), draw tools on the left
-- rail, road-type cards in the center, category tabs along the bottom.
local function buildRoadPage(dockObj: Dock.Dock, gui: ScreenGui)
	local page = dockObj:AddPage({
		key = "Roads",
		-- The ONLY page with a readout worth a column: preview, width, lanes.
		readout = true,
		-- width is ignored: the shelf is full-bleed. Height = header + one card row
		-- + the info strip, and it is the same on every page.
		height = Dock.SHELF_H,
		tabs = TAB_DEFS,
		onTab = function(key: string)
			setTabActive(key)
		end,
	})
	_tabs = page.Tabs
	_roadCardsRegion = page.Content
	_rail = page.Rail
	-- The info bar has two faces -- the road readout and the car-park caption -- each in its
	-- own full-bleed frame, so switching tabs is one Visible flip rather than a hunt through
	-- the bar's children.
	local roadInfo = Instance.new("Frame")
	roadInfo.Name = "RoadInfo"
	roadInfo.BackgroundTransparency = 1
	roadInfo.Size = UDim2.fromScale(1, 1)
	roadInfo.Parent = page.Info
	_roadInfo = roadInfo
	local parkInfo = Instance.new("Frame")
	parkInfo.Name = "ParkInfo"
	parkInfo.BackgroundTransparency = 1
	parkInfo.Size = UDim2.fromScale(1, 1)
	parkInfo.Visible = false
	parkInfo.Parent = page.Info
	_parkInfo = parkInfo
	-- Car-park face: name only, hard right. Its "pick a size" caption is gone with
	-- every other how-to line.
	local pTitle = Instance.new("TextLabel")
	pTitle.BackgroundTransparency = 1
	pTitle.AnchorPoint = Vector2.new(1, 0.5)
	pTitle.Position = UDim2.new(1, 0, 0.5, 0)
	pTitle.AutomaticSize = Enum.AutomaticSize.X
	pTitle.Size = UDim2.fromOffset(0, 22)
	pTitle.Text = "Car park"
	pTitle.TextColor3 = Theme.Color.TextPrimary
	pTitle.TextXAlignment = Enum.TextXAlignment.Right
	pTitle.TextSize = 14
	pTitle.FontFace = Theme.Font.Bold
	pTitle.Parent = parkInfo
	_parkTitle = pTitle

	-- TEMPLATE, bottom-right: the street preview and its dimensions, hard right on
	-- the same line the tabs start from on the left. This whole cluster used to be
	-- a bespoke 54px header crammed into a 24px info row, which is what put the
	-- readout on top of the tabs and the dial on top of the cards.
	-- Fills the readout COLUMN: preview above, dimensions under it, the pair
	-- centred in the column. Laid out vertically because the column is tall and
	-- narrow -- as a horizontal line it left most of its own area empty.
	local readout = Instance.new("Frame")
	readout.Name = "Readout"
	readout.BackgroundTransparency = 1
	readout.AnchorPoint = Vector2.new(0.5, 0.5)
	readout.Position = UDim2.fromScale(0.5, 0.5)
	readout.AutomaticSize = Enum.AutomaticSize.Y
	readout.Size = UDim2.new(1, -16, 0, 0)
	readout.Parent = roadInfo
	local rl = Instance.new("UIListLayout")
	rl.FillDirection = Enum.FillDirection.Vertical
	rl.HorizontalAlignment = Enum.HorizontalAlignment.Center
	rl.VerticalAlignment = Enum.VerticalAlignment.Center
	rl.SortOrder = Enum.SortOrder.LayoutOrder
	rl.Padding = UDim.new(0, 6)
	rl.Parent = readout

	local preview = Instance.new("Frame")
	preview.Size = UDim2.new(1, 0, 0, 56)
	preview.BackgroundColor3 = Theme.Color.BgRaised
	preview.BackgroundTransparency = 0.3
	preview.BorderSizePixel = 0
	preview.ClipsDescendants = true
	preview.LayoutOrder = 1
	preview.Parent = readout
	corner(preview, 8)
	local previewStroke = Instance.new("UIStroke")
	previewStroke.Color = Theme.Color.StrokeSoft
	previewStroke.Thickness = Theme.StrokeWidth.Thin
	previewStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	previewStroke.Parent = preview
	_cfgPreviewHolder = preview

	local wLbl = Instance.new("TextLabel")
	wLbl.BackgroundTransparency = 1
	wLbl.AutomaticSize = Enum.AutomaticSize.X
	wLbl.Size = UDim2.fromOffset(0, 22)
	wLbl.Text = ""
	wLbl.TextColor3 = Theme.Color.TextPrimary
	wLbl.TextXAlignment = Enum.TextXAlignment.Center
	wLbl.TextSize = Theme.TextSize.SM
	wLbl.FontFace = Theme.Font.Bold
	wLbl.LayoutOrder = 2
	wLbl.Parent = readout
	_cfgWidthLabel = wLbl

	-- TEMPLATE, top-right: elevation, speed limit, style gear -- together, in the
	-- header's aux cluster, laid out from the right edge so they cannot reach the
	-- tool buttons on the left however many are added.
	local aux = page.RailAux
	local auxRow = Instance.new("UIListLayout")
	auxRow.FillDirection = Enum.FillDirection.Horizontal
	auxRow.VerticalAlignment = Enum.VerticalAlignment.Center
	auxRow.SortOrder = Enum.SortOrder.LayoutOrder
	auxRow.Padding = UDim.new(0, 6)
	auxRow.Parent = aux
	-- The game-wide placement grid, in plain sight and leftmost: roads snap to the same
	-- sizes as everything else (see SnapUtil.tryGrid for how a drawn road uses it).
	require(script.Parent:WaitForChild("GridPicker")).new(aux, UDim2.fromOffset(200, 24), 0)

	local function stepper(order: number, valueW: number): (TextLabel, TextButton, TextButton)
		local wrap = Instance.new("Frame")
		wrap.BackgroundTransparency = 1
		wrap.Size = UDim2.fromOffset(valueW + 50, 24)
		wrap.LayoutOrder = order
		wrap.Parent = aux
		local l = Instance.new("UIListLayout")
		l.FillDirection = Enum.FillDirection.Horizontal
		l.VerticalAlignment = Enum.VerticalAlignment.Center
		l.SortOrder = Enum.SortOrder.LayoutOrder
		l.Padding = UDim.new(0, 2)
		l.Parent = wrap
		local function mk(txt: string, o: number): TextButton
			local x = Instance.new("TextButton")
			x.Size = UDim2.fromOffset(22, 22)
			x.BackgroundColor3 = Theme.Color.BgRaised
			x.BackgroundTransparency = 0.2
			x.Text = txt
			x.TextColor3 = Theme.Color.TextPrimary
			x.TextSize = 15
			x.FontFace = Theme.Font.Bold
			x.AutoButtonColor = true
			x.BorderSizePixel = 0
			x.LayoutOrder = o
			x.Parent = wrap
			corner(x, 6)
			return x
		end
		local minusB = mk("\u{2212}", 1)
		local lbl = Instance.new("TextLabel")
		lbl.BackgroundTransparency = 1
		lbl.Size = UDim2.fromOffset(valueW, 22)
		lbl.Text = ""
		lbl.TextColor3 = Theme.Color.TextPrimary
		lbl.TextSize = Theme.TextSize.XS
		lbl.FontFace = Theme.Font.Bold
		lbl.LayoutOrder = 2
		lbl.Parent = wrap
		local plusB = mk("+", 3)
		return lbl, minusB, plusB
	end

	local el, elMinus, elPlus = stepper(1, 34)
	el.Text = "0m"
	_roadElevLabel = el
	elMinus.Activated:Connect(function()
		if _road.adjustElevation then _road.adjustElevation(-1); refreshRoadTools() end
	end)
	elPlus.Activated:Connect(function()
		if _road.adjustElevation then _road.adjustElevation(1); refreshRoadTools() end
	end)

	-- The speed limit was a 46px accent RING with the value inside it. That read
	-- well on a tall info bar and simply cannot exist on a 28px row, so it is the
	-- same stepper as elevation; the accent survives as the value's colour.
	local sVal, spMinus, spPlus = stepper(2, 52)
	sVal.Text = "50 km/h"
	sVal.TextColor3 = Theme.Color.Accent
	_cfgSpeedLabel = sVal
	local function stepSpeed(delta: number)
		local cur = _cfg.speed or RoadTypeCatalog.getOrDefault(_cfgBaseId).speedLimit
		_cfg.speed = math.clamp(math.round(cur / 10) * 10 + delta, 10, 120)
		applyConfig()
	end
	spMinus.Activated:Connect(function() stepSpeed(-10) end)
	spPlus.Activated:Connect(function() stepSpeed(10) end)

	-- Road style options (sidewalk / parking / median / colour) behind the gear.
	local optBtn = IconButton.new({
		icon = Icons.Settings, name = "Options", tooltip = "Road style",
		parent = aux, size = 24, layoutOrder = 3,
	})
	-- Style options expand upward out of the dock as a full-width tray flush
	-- with its top edge, instead of a floating detached box.
	local optScale = Instance.new("UIScale")
	local optPop = Popover.new({
		anchor = optBtn.Instance, parent = gui,
		size = UDim2.fromOffset(560, 192),
		name = "DockRoadOptions",
		-- Default placement: centred over the gear, clamped on screen (the gear is
		-- near the right edge, so in practice it sits flush right above it).
		-- The old placeAt returned design px and Popover divided by HudScale a
		-- second time, so it drifted off-screen at any scale but 1.
		gap = 12,
		onOpenChanged = function(open: boolean)
			optBtn:SetSelected(open)
			if open then optScale.Scale = dockObj:Scale() end
		end,
	})
	optScale.Parent = optPop.Frame
	local ol = Instance.new("UIListLayout")
	ol.FillDirection = Enum.FillDirection.Vertical
	ol.SortOrder = Enum.SortOrder.LayoutOrder
	ol.Padding = UDim.new(0, Theme.Pad.SM)
	ol.Parent = optPop.Frame
	buildSegRow(optPop.Frame, 1, "Sidewalk", SIDEWALK_OPTS, function() return activeSidewalk(RoadTypeCatalog.getOrDefault(_cfgBaseId)) end, function(k) _cfg.sidewalk = k; applyConfig() end)
	buildSegRow(optPop.Frame, 2, "Parking", PARKING_OPTS, function() return activeParking(RoadTypeCatalog.getOrDefault(_cfgBaseId)) end, function(k)
		_cfg.parking = k
		applyConfig()
	end)
	buildSegRow(optPop.Frame, 3, "Median", MEDIAN_OPTS, activeMedian, function(k)
		_cfg.median = k
		applyConfig()
	end)
	buildSegRow(optPop.Frame, 4, "Trees", TREE_OPTS, activeTrees, function(k) _cfg.trees = k; applyConfig() end)
	buildSwatchRow(optPop.Frame, 5)
	optBtn.Instance.Activated:Connect(function() optPop:Toggle() end)

	buildRoadRail(page, dockObj, gui)
end

applyConfig = function()
	if not _road then return end
	local id = RoadTypeCatalog.encodeConfig(_cfgBaseId, _cfg)
	_road.setRoadType(id)
	_roadSelected = true
	setSelectedRoad(_cfgBaseId)
	refreshConfigPanel()
end

refreshConfigPanel = function()
	local spec = RoadTypeCatalog.getOrDefault(RoadTypeCatalog.encodeConfig(_cfgBaseId, _cfg))
	if _cfgPreviewHolder then buildRoadCrossSection(_cfgPreviewHolder, spec) end
	if _cfgWidthLabel then
		-- Total footprint = road surface + the sidewalk on each active side (what the player sees).
		local sw = spec.sidewalkMode or (if spec.noSidewalk then "none" else "both")
		local swSides = if sw == "both" then 2 elseif sw == "none" then 0 else 1
		local totalStuds = spec.width + swSides * RoadConstants.SIDEWALK_WIDTH
		_cfgWidthLabel.Text = RoadConstants.formatMeters(totalStuds) .. "  \u{00B7}  " .. tostring(spec.laneCount) .. (if spec.laneCount == 1 then " lane" else " lanes")
	end
	if _cfgSpeedLabel then _cfgSpeedLabel.Text = tostring(math.round(spec.speedLimit)) .. " km/h" end
	for _, fn in _cfgRefreshers do fn() end
end

local function selectRoad(id: string)
	_cfgBaseId = id
	-- Kerbside parking is ON by default for the street types authored for it (parkingSides),
	-- so a newly drawn road gives citizens somewhere to park. It rides in the encoded id
	-- ("NarrowRoad|pk=b"), so only roads drawn from now on get it -- segments already placed
	-- persist their own id and never change width. Pick "None" in Options to opt out.
	-- Trees are the one option that survives picking a different road type: "plant trees
	-- as I build" is a mood, not a property of the street you happen to have selected.
	_cfg = { parking = if RoadTypeCatalog.getOrDefault(id).parkingSides then "both" else nil, trees = _cfg.trees }
	applyConfig()
end

local function deselectRoad()
	if _road and _road.clearRoadTypeSelection then _road.clearRoadTypeSelection() end
	setSelectedRoad(nil)
	_roadSelected = false
end

local function setSelectedLot(key: string?)
	_parkKey = key
	for k, stroke in _parkStrokes do
		stroke.Color = if k == key then Theme.Color.Accent else Theme.Color.StrokeSoft
		stroke.Thickness = if k == key then Theme.StrokeWidth.Thick else Theme.StrokeWidth.Thin
	end
	local entry = if key then NatureCatalog.get(key) else nil
	if _parkTitle then
		_parkTitle.Text = if entry then entry.name else "Car park"
	end
	if _parkCap then
		_parkCap.Text = if entry and key
			then string.format("%d bays  \u{00B7}  $%d  \u{00B7}  snaps square to the nearest kerb", lotBays(key), entry.cost)
			else "pick a size \u{2014} it snaps square to the nearest kerb"
	end
	if key then Nature.setAssetSelected(key, true) end
end

-- The Parking tab hands the cursor to the Nature placement tool and takes it back on the
-- way out. Road drawing and lot placement must never both own the click.
local function setParkingMode(on: boolean)
	if _parkActive == on then return end
	_parkActive = on
	if on then
		deselectRoad()
		if _road and _road.setEnabled then _road.setEnabled(false) end
		-- One click, one lot: a car park in a scattered brush stroke is nobody's intent.
		Nature.setMode("Single")
		-- The placement tool is shared with the Nature tab, which leaves its own settings
		-- behind: a random palette would mix car parks with trees, a Shapes-tab size would
		-- place the lot at 1.5x, Stack would drop it on a roof and the paint swatch would
		-- turn the tarmac pink. This tab wants exactly one lot, as baked, on the ground.
		Nature.setRandomize(false)
		Nature.setStack(false)
		Nature.setPlaceScale(1)
		Nature.setPlaceColor(nil)
		Nature.setEnabled(true)
		setSelectedLot(_parkKey or LOT_KEYS[1])
	else
		Nature.setEnabled(false)
		if _road and _road.setEnabled then _road.setEnabled(true) end
		applyConfig()
	end
end

local function showRoadDock(visible: boolean)
	local dock = _dock
	if not dock then return end
	if visible then
		dock:ShowPage("Roads")
		refreshConfigPanel()
	else
		dock:Hide("Roads")
	end
end

setTabActive = function(key: string)
	for k, tab in _tabs do tab:SetSelected(k == key) end
	-- CARD_TABS has no "Parking" entry, so every road card hides itself on that tab.
	for id, card in _roadCards do
		local mapped = CARD_TABS[id]
		card.Visible = mapped ~= nil and mapped[key] == true
	end
	local scroll = _roadsScroll
	if scroll then
		scroll:SetAttribute("Page", 0)
		scroll.CanvasPosition = Vector2.zero
	end
	local park = key == "Parking"
	-- The two card grids share the content frame, so exactly one is ever up: leaving the
	-- (empty) road grid on top would swallow the wheel that pages the parking cards.
	if scroll then scroll.Visible = not park end
	if _parkScroll then _parkScroll.Visible = park end
	if _roadInfo then _roadInfo.Visible = not park end
	if _parkInfo then _parkInfo.Visible = park end
	-- The rail is the road draw-mode column; none of it applies to dropping a car park.
	if _rail then _rail.Visible = not park end
	setParkingMode(park)
end

local function buildParkingContent(parent: Instance)
	local scroll = BuildCard.grid(parent)
	scroll.Name = "ParkingCards"
	scroll.Visible = false
	_parkScroll = scroll
	local widest = 1
	for _, key in LOT_KEYS do
		local t = ReplicatedStorage.Nature:FindFirstChild(key)
		if t and t:IsA("Model") then
			local _, size = (t :: Model):GetBoundingBox()
			widest = math.max(widest, size.X)
		end
	end
	for i, key in LOT_KEYS do
		local entry = NatureCatalog.get(key)
		if not entry then continue end
		local card, preview, stroke = BuildCard.shell(key, i)
		local frac = 1
		local t = ReplicatedStorage.Nature:FindFirstChild(key)
		if t and t:IsA("Model") then
			local _, size = (t :: Model):GetBoundingBox()
			frac = math.clamp(size.X / widest, 0.45, 1)
		end
		buildLotPreview(preview, frac)
		local btn = BuildCard.footer(card, entry.name)
		card.Parent = scroll
		_parkStrokes[key] = stroke
		-- No toggle-off: unticking would leave the placement tool armed with whatever the
		-- catalog's first entry happens to be (a palm), which is not what the tab is for.
		btn.Activated:Connect(function() setSelectedLot(key) end)
	end
end

local function buildRoadsContent(parent: Instance)
	_roadsScroll = BuildCard.grid(parent)
	local scroll = _roadsScroll :: ScrollingFrame
	for i, id in RoadTypeCatalog.Order do
		local spec = RoadTypeCatalog.get(id)
		if not spec then continue end
		local card, preview, stroke = BuildCard.shell(id, i)
		build2DPreview(preview, spec)
		local btn = BuildCard.footer(card, spec.name)
		card.Parent = scroll
		_roadCards[id] = card
		_roadCardStrokes[id] = stroke
		BuildCard.gate(card, DevelopmentTree.RoadNode[id])
		btn.Activated:Connect(function()
			if _roadSelected and _cfgBaseId == id then deselectRoad() else selectRoad(id) end
		end)
	end
end

-- ==========================================================================
--  PUBLIC INTERFACE (BottomBarController is the only caller)
-- ==========================================================================
export type InitProps = { dock: Dock.Dock, gui: ScreenGui, road: any }

function RoadDockPanel.Init(props: InitProps)
	_dock = props.dock
	_road = props.road
	buildRoadPage(props.dock, props.gui)
	buildRoadsContent(_roadCardsRegion :: Frame)
	buildParkingContent(_roadCardsRegion :: Frame)
	setTabActive(TAB_DEFS[1].key)
end

function RoadDockPanel.Show(visible: boolean)
	showRoadDock(visible)
end

-- Section opened: re-apply the current road type so the ghost preview and the
-- placement tool agree with what the dock is showing.
function RoadDockPanel.Activate()
	-- Re-opening the section on the Parking tab arms the lot tool, not the road tool --
	-- BottomBarController.activateSection turns the road tool on for every Roads open.
	if _parkActive then
		if _road and _road.setEnabled then _road.setEnabled(false) end
		deselectRoad()
		Nature.setEnabled(true)
		-- Closing the section cleared the shared palette, so re-arm the lot this tab shows.
		setSelectedLot(_parkKey or LOT_KEYS[1])
		return
	end
	applyConfig()
end

-- Section closed: the parallel-offset bar floats outside the dock, so it has to
-- be put away by hand.
function RoadDockPanel.Deactivate()
	local pbar = _roadToolBtns.ParBar
	if pbar then pbar.Visible = false end
	-- Closing the section takes the car-park tool with it. The tab itself stays put, so
	-- re-opening Roads arms it again through Activate.
	Nature.setEnabled(false)
end

-- RoadPlacementController changed state: resync the rail's selected/toggle look.
function RoadDockPanel.Refresh()
	refreshRoadTools()
end

return RoadDockPanel