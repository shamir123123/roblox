--!strict
-- BUILD SECTIONS + THE BUILD DOCK.
--
-- What is LEFT of the old bottom bar. This file used to own the whole HUD: a
-- full-width glass shelf carrying the clock, sim speed, demand rings, treasury,
-- population, a city-name banner, a news ticker and every tool button, plus the
-- dock pages behind them -- 2,537 lines and Luau's 200-local ceiling. Each of
-- those readouts now lives in the module that owns its screen zone:
--
--   HUD.TopLeftCluster   menu chip, role badge, clock, sim speed
--   HUD.CityVitalsPanel  treasury, citizens, R/C/I demand
--   Controllers.ToolRail the bottom-centre tool buttons (presentation only)
--   Controllers.HeatmapController  the bottom-left info-view column
--
-- This file keeps the part that is genuinely one domain: which build section is
-- open, and what cards the shared dock shows for it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local uiFolder = script.Parent.Parent:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local Icons = require(uiFolder:WaitForChild("Icons"))
local UITween = require(uiFolder:WaitForChild("UITween"))
local HudScale = require(uiFolder:WaitForChild("HudScale"))
local Format = require(uiFolder:WaitForChild("Format"))
local kit = uiFolder:WaitForChild("Kit")
local IconButton = require(kit:WaitForChild("IconButton"))
local Divider = require(kit:WaitForChild("Divider"))
local Glass = require(kit:WaitForChild("Glass"))
local BuildCard = require(kit:WaitForChild("BuildCard"))
local Popover = require(kit:WaitForChild("Popover"))
local Dock = require(kit:WaitForChild("Dock"))
local Tooltip = require(kit:WaitForChild("Tooltip"))

local ToolRail = require(script.Parent:WaitForChild("ToolRail"))
local ToolStripController = require(script.Parent:WaitForChild("ToolStripController"))
local SchoolTypes = require(ReplicatedStorage.City.SchoolTypes)
local ServiceTypes = require(ReplicatedStorage.City.ServiceTypes)
local UIEvents = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("UIEvents"))
local DevelopmentTree = require(ReplicatedStorage.City.DevelopmentTree)

local BottomBarController = {}

-- Every page is Dock.SHELF_H tall; the number is decided in Kit.Dock beside
-- the geometry that produces it.
local SHELF_H = Dock.SHELF_H

local ZONE_DEFS = {
	{ name = "Residential", color = Color3.fromRGB(82, 196, 110) },
	{ name = "Commercial", color = Color3.fromRGB(70, 160, 230) },
	{ name = "Industrial", color = Color3.fromRGB(220, 185, 55) },
}

local CATEGORY_DEFS = {
	{ key = "Roads",     icon = Icons.Roads,          label = "Roads" },
	{ key = "Zoning",    icon = Icons.Zoning,         label = "Zoning" },
	-- CIVIC OFF: Civic (police / fire / hospital / education) is still not
	-- offered. Its dock page builds below but nothing opens it. Re-enable by
	-- restoring the entry.
	-- Utilities is BACK ON: electricity is live, so the Wind Turbine and the
	-- Power Line have to be reachable (water and sewage ride the same page).
	{ key = "Utilities", icon = Icons.Infrastructure, label = "Utilities" },
	-- BUSES OFF: Transit (depot / stop / route, and the Transport overview it
	-- opens) is not offered for playtest. Its dock page still builds below but
	-- nothing opens it.
	-- { key = "Transit", icon = Icons.Transport, label = "Transit" },
}

local TRANSIT_TOOLS = {
	{ key = "Depot",   name = "Bus Depot",     color = Color3.fromRGB(46, 84, 140),  glyph = "\u{1F3D7}" },
	{ key = "Stop",    name = "Bus Stop",      color = Color3.fromRGB(74, 122, 178), glyph = "\u{1F68F}" },
	-- TRAINS OFF: the Train Station card is not offered. Restore this entry (and
	-- its TRANSIT_PLACEABLE mapping) to bring rail back.
	{ key = "Route",   name = "Route",         color = Color3.fromRGB(84, 148, 150), glyph = "\u{1F68C}" },
}

-- Transit tool key -> the DevelopmentTree placeable it maps to (Route isn't gated).
local TRANSIT_PLACEABLE: { [string]: string } = {
	Depot = "BusDepot", Stop = "BusStop",
}

local _started = false
local _road: any = nil
local _roadDock: any = nil -- Controllers.RoadDockPanel (the Roads dock page)
local _zoning: any = nil
-- Zoning tool state in ONE table (this file sits at Luau's 200-local scope limit).
local _zoneTools = { density = "Low" } :: any
local _education: any = nil
local _emergency: any = nil
local _gui: ScreenGui? = nil
-- Civic + Utilities live in the bottom-right dock (same as Roads/Zoning). Each
-- dock page registers a show() here that the section opener calls to sync its
-- tab + info + tool.
local _svcPages: { [string]: () -> () } = {}
local _activeSection: string? = nil
local _dock: Dock.Dock? = nil  -- the ONE shared build panel (Roads / Zoning / Terrain pages)
-- Bulldoze + Move tool controllers bundled in ONE table: this file sits at
-- Luau's 200-local scope limit, same trick as _zoneTools. The BUTTONS are no
-- longer here -- ToolRail owns those and is driven through setSelected.
local _tools = { bulldoze = nil, move = nil } :: any
-- The pipe tool's rail buttons, so the tool can push a mode change back into them.
local _pipeRail: any = nil
local _terrain: any = nil
local _zoneCardStrokes: { [string]: UIStroke } = {}
-- Zoning page state (lives on the shared dock).
local _zoneRefreshers: { () -> () } = {}
local _zoneEraseBtn: IconButton.IconButton? = nil
local _zoneErasing = false
local _zoneActive = "Residential"  -- last real zone picked (survives Erase toggles)
local _zoneDensityIcons: { [string]: ImageLabel } = {}
-- The zoning readout IS Dock's standard info line now; we keep the page only
-- so refreshZoneDock can call SetInfo on it.
local _zonePage: Dock.Page? = nil
local _serviceCardStrokes: { [string]: UIStroke } = {}
local _transit: any = nil
local _overview: any = nil
local _transitCardStrokes: { [string]: UIStroke } = {}

local function corner(parent: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = parent
end

-- =====================================================================
--  SELECTION HELPERS
-- =====================================================================
local function refreshZoneDock()
	for _, fn in _zoneRefreshers do
		fn()
	end
end
local function setSelectedZone(zoneName: string?)
	if zoneName then
		_zoneActive = zoneName
	end
	refreshZoneDock()
end
local function setSelectedService(key: string?)
	for name, stroke in _serviceCardStrokes do
		stroke.Color = if name == key then Theme.Color.Accent else Theme.Color.StrokeSoft
		stroke.Thickness = if name == key then Theme.StrokeWidth.Thick else Theme.StrokeWidth.Thin
	end
end
local function setSelectedTransit(key: string?)
	for name, stroke in _transitCardStrokes do
		stroke.Color = if name == key then Theme.Color.Accent else Theme.Color.StrokeSoft
		stroke.Thickness = if name == key then Theme.StrokeWidth.Thick else Theme.StrokeWidth.Thin
	end
end

-- =====================================================================
--  ZONING DOCK (shared Dock frame; bottom-right side panel)
--  Info: active zone + density readout. Rail: Box / Fill / Paint + Erase.
--  Center: density cards (ponytail: visual only until density ships).
--  Tabs: Residential / Commercial / Industrial.
-- =====================================================================
local ZONE_COLOR: { [string]: Color3 } = {}
for _, def in ZONE_DEFS do
	ZONE_COLOR[def.name] = def.color
end

local DENSITY_DEFS = {
	{ key = "Low", icon = Icons.DensityLow },
	{ key = "Medium", icon = Icons.DensityMedium },
	{ key = "High", icon = Icons.DensityHigh },
	{ key = "Mixed", icon = Icons.DensityMixed },
}

-- =====================================================================
--  SINGLE-BUILDING PICKER (zoning dock): a popover listing every placeable
--  catalog building. Pick one -> the Zoning tool plops THAT model (Single mode).
-- =====================================================================
local _bpick = { popover = nil :: any, scroll = nil :: ScrollingFrame?, loaded = false, selRow = nil :: TextButton? }

local function buildBuildingPicker(anchorBtn: any)
	if not _gui then return end
	local ZONE_ORDER: { [string]: number } = { Residential = 1, Commercial = 2, Industrial = 3 }
	local ROW = 24

	local function prettify(n: string): string
		return (n:gsub("^USA_", ""):gsub("_", " "))
	end

	local function populate(entries: { any })
		local scroll = _bpick.scroll
		if not scroll then return end
		for _, ch in scroll:GetChildren() do
			if ch:IsA("GuiObject") then ch:Destroy() end
		end
		table.sort(entries, function(a, b)
			local za, zb = ZONE_ORDER[a.zone] or 9, ZONE_ORDER[b.zone] or 9
			if za ~= zb then return za < zb end
			if a.w ~= b.w then return a.w < b.w end
			if a.d ~= b.d then return a.d < b.d end
			return a.name < b.name
		end)
		local order = 0
		local function header(text: string)
			order += 1
			local lbl = Instance.new("TextLabel")
			lbl.BackgroundTransparency = 1
			lbl.Size = UDim2.new(1, 0, 0, ROW)
			lbl.LayoutOrder = order
			lbl.FontFace = Theme.Font.Bold
			lbl.TextSize = Theme.TextSize.XS
			lbl.TextColor3 = Theme.Color.TextSecondary
			lbl.TextXAlignment = Enum.TextXAlignment.Left
			lbl.Text = text
			lbl.Parent = scroll
		end
		local function selectRow(r: TextButton)
			if _bpick.selRow and _bpick.selRow.Parent then
				_bpick.selRow.BackgroundColor3 = Theme.Color.BgRaised
				_bpick.selRow.TextColor3 = Theme.Color.TextPrimary
			end
			_bpick.selRow = r
			r.BackgroundColor3 = Theme.Color.Accent
			r.TextColor3 = Theme.Color.OnAccent
		end
		local function row(text: string, indent: number, onClick: () -> ()): TextButton
			order += 1
			local btn = Instance.new("TextButton")
			btn.AutoButtonColor = false
			btn.BorderSizePixel = 0
			btn.BackgroundColor3 = Theme.Color.BgRaised
			btn.Size = UDim2.new(1, 0, 0, ROW)
			btn.LayoutOrder = order
			btn.FontFace = Theme.Font.Label
			btn.TextSize = Theme.TextSize.XS
			btn.TextColor3 = Theme.Color.TextPrimary
			btn.TextXAlignment = Enum.TextXAlignment.Left
			btn.Text = text
			local uc = Instance.new("UICorner"); uc.CornerRadius = UDim.new(0, Theme.Radius.SM); uc.Parent = btn
			local pad = Instance.new("UIPadding"); pad.PaddingLeft = UDim.new(0, indent); pad.PaddingRight = UDim.new(0, Theme.Pad.SM); pad.Parent = btn
			btn.MouseEnter:Connect(function() if btn ~= _bpick.selRow then btn.BackgroundColor3 = Theme.Color.BgHover end end)
			btn.MouseLeave:Connect(function() if btn ~= _bpick.selRow then btn.BackgroundColor3 = Theme.Color.BgRaised end end)
			btn.Activated:Connect(onClick)
			btn.Parent = scroll
			return btn
		end
		local autoRow: TextButton
		autoRow = row("Auto (random)", Theme.Pad.SM, function()
			if _zoning then _zoning.setSelectedBuilding(nil) end
			selectRow(autoRow)
			refreshZoneDock()
		end)
		local lastZone: any, lastSize: any = nil, nil
		for _, c in entries do
			if c.zone ~= lastZone then lastZone = c.zone; lastSize = nil; header(tostring(c.zone)) end
			local size = tostring(c.w) .. "x" .. tostring(c.d)
			if size ~= lastSize then lastSize = size; header("  " .. size) end
			local entry = c
			local r: TextButton
			r = row(prettify(tostring(entry.name)), Theme.Pad.LG, function()
				if _zoning then
					_zoning.setSelectedBuilding({ zone = entry.zone, w = entry.w, d = entry.d, name = entry.name })
					if _zoning.setMode then _zoning.setMode("Single") end
					_zoning.setActiveZone(entry.zone)
				end
				_zoneErasing = false
				setSelectedZone(entry.zone)
				selectRow(r)
			end)
		end
	end

	local popover = Popover.new({
		anchor = anchorBtn.Instance,
		parent = _gui,
		size = UDim2.fromOffset(240, 320),
		name = "BuildingPicker",
		onOpenChanged = function(open: boolean)
			anchorBtn:SetSelected(open)
			if open and not _bpick.loaded then
				_bpick.loaded = true
				task.spawn(function()
					local Net = require(ReplicatedStorage:WaitForChild("Networker"))
					local ok, res = pcall(function()
						return Net.RequestBuildingCatalog:InvokeServer()
					end)
					if ok and typeof(res) == "table" then
						populate(res)
					else
						_bpick.loaded = false
					end
				end)
			end
		end,
	})
	_bpick.popover = popover

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "List"
	scroll.Size = UDim2.fromScale(1, 1)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 4
	scroll.ScrollBarImageColor3 = Theme.Color.Stroke
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, Theme.Pad.XS)
	list.Parent = scroll
	scroll.Parent = popover.Frame
	_bpick.scroll = scroll
end

local function buildZonePage(dockObj: Dock.Dock)
	local tabDefs: { Dock.TabDef } = {}
	for _, def in ZONE_DEFS do
		table.insert(tabDefs, { key = def.name, label = def.name })
	end
	local page = dockObj:AddPage({
		key = "Zoning",
		-- width is ignored: the shelf is full-bleed. Height is the slim header + ONE
		-- card row + the tab strip, since the cards scroll sideways now.
		height = SHELF_H,
		infoHeight = Dock.INFO_SLIM,
		standardInfo = true,
		tabs = tabDefs,
		onTab = function(zoneName: string)
			_zoneErasing = false
			_zoning.setActiveZone(zoneName)
			setSelectedZone(zoneName)
		end,
	})
	_zonePage = page


	-- Building picker: top-right of the info bar (like the road dock's gear). Opens a list of
	-- every placeable building; pick one and the tool plops that exact model on the next click.
	local pickBtn = IconButton.new({
		icon = Icons.Buildings, name = "PickBuilding", tooltip = "Pick a building to place", parent = page.Info, size = 30,
	})
	pickBtn.Instance.AnchorPoint = Vector2.new(1, 0.5)
	pickBtn.Instance.Position = UDim2.new(1, -10, 0.5, 0)
	buildBuildingPicker(pickBtn)
	pickBtn.Instance.Activated:Connect(function()
		if _bpick.popover then _bpick.popover:Toggle() end
	end)

	-- Rail: how-you-paint tools (2x2 icon grid, matching the road rail).
	local rail = page.Rail
	local rpad = Instance.new("UIPadding")
	rpad.PaddingTop = UDim.new(0, Theme.Pad.XS)
	rpad.PaddingLeft = UDim.new(0, Theme.Pad.XS)
	rpad.Parent = rail
	local rgrid = Instance.new("UIGridLayout")
	rgrid.CellSize = UDim2.fromOffset(26, 26)
	rgrid.CellPadding = UDim2.fromOffset(4, 4)
	rgrid.SortOrder = Enum.SortOrder.LayoutOrder
	rgrid.Parent = rail
	_zoneEraseBtn = IconButton.new({
		icon = Icons.ZoneErase, name = "Erase", tooltip = "Erase zoning", danger = true, parent = rail, size = 26, layoutOrder = 10,
		onClick = function()
			_zoneErasing = not _zoneErasing
			_zoning.setActiveZone(if _zoneErasing then "None" else _zoneActive)
			refreshZoneDock()
		end,
	})

	-- Center: density cards, tinted by the active zone.
	local cardsRow = BuildCard.grid(page.Content)
	for i, def in DENSITY_DEFS do
		local card, preview, stroke = BuildCard.shell("Density_" .. def.key, i)
		local ic = Instance.new("ImageLabel")
		ic.BackgroundTransparency = 1
		ic.AnchorPoint = Vector2.new(0.5, 0.5)
		ic.Position = UDim2.new(0.5, 0, 0.5, -8)
		ic.Size = UDim2.fromOffset(30, 30)
		ic.ScaleType = Enum.ScaleType.Fit
		ic.Image = def.icon.image
		ic.Parent = preview
		local btn = BuildCard.footer(card, def.key)
		card.Parent = cardsRow
		-- Denser housing is a milestone reward; Low is open from the first minute.
		local MilestoneUnlocks = require(ReplicatedStorage.City.MilestoneUnlocks)
		local grantAt = MilestoneUnlocks.zoneMilestone(def.key)
		BuildCard.gateMilestone(card, grantAt, if grantAt then MilestoneUnlocks.Ladder[grantAt].name else nil)
		_zoneCardStrokes[def.key] = stroke
		_zoneDensityIcons[def.key] = ic
		local key = def.key
		btn.Activated:Connect(function()
			_zoneTools.density = key
			if _zoning then _zoning.setDensity(key) end
			refreshZoneDock()
		end)
	end

	_zoneRefreshers[#_zoneRefreshers + 1] = function()
		if _zoneEraseBtn then _zoneEraseBtn:SetSelected(_zoneErasing) end
		page:SetTab(if _zoneErasing then "" else _zoneActive)
		local zcol = ZONE_COLOR[_zoneActive] or Theme.Color.Accent
		for k, stroke in _zoneCardStrokes do
			stroke.Color = if k == _zoneTools.density then Theme.Color.Accent else Theme.Color.StrokeSoft
			stroke.Thickness = if k == _zoneTools.density then Theme.StrokeWidth.Thick else Theme.StrokeWidth.Thin
		end
		for k, ic in _zoneDensityIcons do
			ic.ImageColor3 = if k == _zoneTools.density then Theme.Color.Accent else zcol
		end
		local zp = _zonePage
		if zp then
			-- Name and, when one is picked, WHICH building -- no how-to line. The
			-- readout says what is selected, not how to use the mouse.
			local sel = _zoning and _zoning.getSelectedBuilding and _zoning.getSelectedBuilding()
			zp:SetInfo(
				if _zoneErasing then "Erase zoning" else _zoneActive,
				if sel and not _zoneErasing then (tostring(sel.name):gsub("^USA_", ""):gsub("_", " ")) else "",
				if _zoneErasing then Theme.Color.Danger else zcol
			)
		end
	end
end

local function showZoneDock(visible: boolean)
	local dock = _dock
	if not dock then return end
	if visible then
		dock:ShowPage("Zoning")
		refreshZoneDock()
	else
		dock:Hide("Zoning")
	end
end

-- =====================================================================
--  FLYOUT SIZE HELPERS
-- =====================================================================
-- =====================================================================
--  FLYOUT CONTENT BUILDERS (roads, zoning, services, transit)
-- =====================================================================
local function buildSchoolPreview(container: Frame, spec: any)
	local body = Instance.new("Frame")
	body.AnchorPoint = Vector2.new(0.5, 0.5)
	body.Position = UDim2.fromScale(0.5, 0.54)
	body.Size = UDim2.fromScale(0.62, 0.46)
	body.BackgroundColor3 = spec.wall
	body.BackgroundTransparency = 0.08
	body.BorderSizePixel = 0
	body.Parent = container
	corner(body, 4)
	local roof = Instance.new("Frame")
	roof.AnchorPoint = Vector2.new(0.5, 1)
	roof.Position = UDim2.new(0.5, 0, 0.32, 0)
	roof.Size = UDim2.fromScale(0.72, 0.16)
	roof.BackgroundColor3 = spec.roof
	roof.BorderSizePixel = 0
	roof.Parent = container
	corner(roof, 4)
	local door = Instance.new("Frame")
	door.AnchorPoint = Vector2.new(0.5, 1)
	door.Position = UDim2.new(0.5, 0, 0.77, 0)
	door.Size = UDim2.fromScale(0.16, 0.22)
	door.BackgroundColor3 = spec.accent
	door.BorderSizePixel = 0
	door.Parent = container
	corner(door, 2)
	for i = 1, 3 do
		local win = Instance.new("Frame")
		win.AnchorPoint = Vector2.new(0.5, 0.5)
		win.Position = UDim2.fromScale(0.24 + i * 0.13, 0.52)
		win.Size = UDim2.fromScale(0.08, 0.09)
		win.BackgroundColor3 = spec.accent
		win.BackgroundTransparency = 0.2
		win.BorderSizePixel = 0
		win.Parent = container
		corner(win, 2)
	end
end

-- Fallback sketch, for a key with neither a template nor a procedural builder.
local function drawFlatServicePreview(container: Frame, spec: ServiceTypes.Spec)
	local body = Instance.new("Frame")
	body.AnchorPoint = Vector2.new(0.5, 0.5)
	body.Position = UDim2.fromScale(0.5, 0.54)
	body.Size = UDim2.fromScale(0.62, 0.44)
	body.BackgroundColor3 = spec.wall
	body.BackgroundTransparency = 0.08
	body.BorderSizePixel = 0
	body.Parent = container
	corner(body, 4)
	local roof = Instance.new("Frame")
	roof.AnchorPoint = Vector2.new(0.5, 1)
	roof.Position = UDim2.new(0.5, 0, 0.32, 0)
	roof.Size = UDim2.fromScale(0.72, 0.14)
	roof.BackgroundColor3 = spec.roof
	roof.BorderSizePixel = 0
	roof.Parent = container
	corner(roof, 4)
	local accent = Instance.new("Frame")
	accent.AnchorPoint = Vector2.new(0.5, 1)
	accent.Position = UDim2.new(0.5, 0, 0.78, 0)
	accent.Size = UDim2.fromScale(0.18, 0.22)
	accent.BackgroundColor3 = spec.accent
	accent.BorderSizePixel = 0
	accent.Parent = container
	corner(accent, 2)
end

-- Pipe cards have no model to frame: two stubs of pipe drawn on the card face, blue for
-- water, tan for sewage, both when one trench carries both -- exactly what goes in the
-- ground, so the card and the world agree.
local function buildPipePreview(container: Frame, spec: ServiceTypes.Spec)
	local function tube(y: number, col: Color3)
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromScale(0.5, y)
		f.Size = UDim2.fromScale(0.74, 0.20)
		f.BackgroundColor3 = col
		f.BorderSizePixel = 0
		f.Parent = container
		corner(f, 20)
		local hi = Instance.new("Frame")
		hi.AnchorPoint = Vector2.new(0.5, 0)
		hi.Position = UDim2.fromScale(0.5, 0.16)
		hi.Size = UDim2.fromScale(0.62, 0.22)
		hi.BackgroundColor3 = Color3.new(1, 1, 1)
		hi.BackgroundTransparency = 0.62
		hi.BorderSizePixel = 0
		hi.Parent = f
		corner(hi, 20)
	end
	local water = spec.key ~= "SewagePipe"
	local sewage = spec.key ~= "WaterPipe"
	if water and sewage then
		tube(0.38, Color3.fromRGB(64, 176, 212))
		tube(0.66, Color3.fromRGB(206, 170, 104))
	else
		tube(0.5, if water then Color3.fromRGB(64, 176, 212) else Color3.fromRGB(206, 170, 104))
	end
end

-- The card shows the ACTUAL building, not a sketch of one: a ViewportFrame holding the
-- same model ServiceBuildingModel would place, framed to fill the card. Built once when the
-- dock is built. ServiceBuildingModel is required here rather than at the top of the file
-- because this one sits at Luau's 200-local scope limit.
local function buildServiceBuildingPreview(container: Frame, spec: ServiceTypes.Spec)
	local built = require(ReplicatedStorage.City.ServiceBuildingModel) :: any
	local ok, model = pcall(built.build, spec.key, false)
	if not ok or not model then
		drawFlatServicePreview(container, spec)
		return
	end

	local vp = Instance.new("ViewportFrame")
	vp.Size = UDim2.fromScale(1, 1)
	vp.BackgroundTransparency = 1
	vp.Ambient = Color3.fromRGB(158, 162, 168)
	vp.LightColor = Color3.fromRGB(255, 252, 246)
	vp.LightDirection = Vector3.new(-0.45, -1, -0.35)
	vp.Parent = container

	model.Parent = vp
	local cam = Instance.new("Camera")
	cam.Parent = vp
	vp.CurrentCamera = cam

	-- Pull back far enough that the whole bounding sphere fits, whatever shape it is: a
	-- turbine is tall and thin, a sewage plant is wide and flat.
	local centre, size = model:GetBoundingBox()
	local radius = math.max(size.Magnitude * 0.5, 1)
	local dist = radius / math.tan(math.rad(cam.FieldOfView * 0.5)) * 1.06
	cam.CFrame = CFrame.lookAt(centre.Position + Vector3.new(0.8, 0.55, 1).Unit * dist, centre.Position)
end

local function buildTransitPreview(container: Frame, key: string, color: Color3)
	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = color
	bg.BackgroundTransparency = 0.42
	bg.BorderSizePixel = 0
	bg.Parent = container
	corner(bg, Theme.Radius.MD)
	local ink = Color3.fromRGB(245, 248, 252)
	local function box(px, py, sx, sy, round, anchorY, col)
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0.5, anchorY)
		f.Position = UDim2.fromScale(px, py)
		f.Size = UDim2.fromScale(sx, sy)
		f.BackgroundColor3 = col
		f.BorderSizePixel = 0
		f.Parent = bg
		if round > 0 then corner(f, round) end
		return f
	end
	if key == "Depot" then
		box(0.5,0.66,0.60,0.34,2,1,ink); box(0.5,0.36,0.72,0.10,2,1,ink)
		box(0.38,0.66,0.15,0.22,1,1,color); box(0.62,0.66,0.15,0.22,1,1,color)
	elseif key == "Stop" then
		box(0.5,0.70,0.06,0.46,0,1,ink); box(0.5,0.30,0.40,0.22,3,0.5,ink)
		box(0.5,0.30,0.26,0.08,1,0.5,color)
	elseif key == "Station" then
		-- platform slab over two rails
		box(0.5,0.42,0.64,0.18,2,0.5,ink)
		box(0.5,0.62,0.7,0.045,0,0.5,ink); box(0.5,0.72,0.7,0.045,0,0.5,ink)
		box(0.5,0.30,0.30,0.08,1,0.5,color)
	elseif key == "Route" then
		box(0.5,0.46,0.64,0.06,3,0.5,ink)
		box(0.22,0.46,0.17,0.17,20,0.5,ink); box(0.5,0.46,0.17,0.17,20,0.5,ink); box(0.78,0.46,0.17,0.17,20,0.5,ink)
	else
		for i = 0, 2 do
			local y = 0.30 + i * 0.18
			box(0.28,y,0.12,0.10,2,0.5,ink); box(0.62,y,0.44,0.08,2,0.5,ink)
		end
	end
end

-- Build the Civic + Utilities + Transit dock pages (same bottom-right dock Roads/Zoning use).
-- Civic has two tabs (Emergency / Education); Utilities is a single card row. Each
-- page registers a show() in _svcPages that syncs its tab, info bar, selection and
-- the active placement tool when the section opens.
local function buildServiceDocks(dockObj: Dock.Dock)
	-- Split the ServiceTypes catalog into emergency vs utility keys.
	local emergencyKeys: { string } = {}
	local utilityKeys: { string } = {}
	for _, key in ServiceTypes.Order do
		local spec = ServiceTypes.get(key)
		if not spec then continue end
		if spec.category == "Utilities" then table.insert(utilityKeys, key) else table.insert(emergencyKeys, key) end
	end

	-- Info bar (swatch + name + description/cost) built into a page's Info island.
	-- Returns update(name, desc, cost, color).
	-- Civic / Utilities / Transit all want the same swatch + name + description
	-- line, which is exactly Dock's standard info. This only formats the cost in.
	local function makeInfo(page: Dock.Page): (string, string, number, Color3) -> ()
		return function(name: string, desc: string, cost: number, col: Color3)
			page:SetInfo(name, desc .. "   \u{00B7}   $" .. Format.int(cost), col)
		end
	end

	-- One card row (list layout) inside a page's Content.
	local function makeRow(content: Frame): ScrollingFrame
		return BuildCard.grid(content)
	end

	-- ---- CIVIC PAGE (Emergency / Education tabs) ----
	local civicTab = "Emergency"
	local setCivicInfo: (string, string, number, Color3) -> ()
	local showCivicTab: (string, boolean) -> ()
	local civicPage = dockObj:AddPage({
		key = "Civic", standardInfo = true, height = SHELF_H, railWidth = 0, infoHeight = Dock.INFO_SLIM,
		tabs = { { key = "Emergency", label = "Emergency" }, { key = "Education", label = "Education" } },
		onTab = function(t: string) showCivicTab(t, true) end,
	})
	setCivicInfo = makeInfo(civicPage)
	-- Free-placed buildings snap to the game-wide grid, so its picker sits top-right on
	-- every page that places one. Road snap still wins beside a road.
	local GridPicker = require(script.Parent:WaitForChild("GridPicker"))
	local GRID_PICKER_SIZE = UDim2.fromOffset(200, 26)
	GridPicker.new(civicPage.RailAux, GRID_PICKER_SIZE)
	local emRow = makeRow(civicPage.Content)
	local edRow = makeRow(civicPage.Content)
	edRow.Visible = false

	for i, key in emergencyKeys do
		local spec = ServiceTypes.get(key) :: any
		local card, preview, stroke = BuildCard.shell("Civic_" .. key, i)
		buildServiceBuildingPreview(preview, spec)
		local btn = BuildCard.footer(card, spec.name)
		card.Parent = emRow
		_serviceCardStrokes[key] = stroke
		BuildCard.gate(card, DevelopmentTree.PlaceableNode[key])
		btn.Activated:Connect(function()
			if _education then _education.setEnabled(false) end
			_emergency.setServiceType(key)
			_emergency.setEnabled(true)
			setSelectedService(key)
			setCivicInfo(spec.name, spec.desc, spec.cost, spec.accent)
		end)
	end
	for i, key in SchoolTypes.Order do
		local spec = SchoolTypes.get(key)
		if not spec then continue end
		local card, preview, stroke = BuildCard.shell("Edu_" .. key, i)
		buildSchoolPreview(preview, spec)
		local btn = BuildCard.footer(card, spec.name)
		card.Parent = edRow
		_serviceCardStrokes[key] = stroke
		BuildCard.gate(card, DevelopmentTree.PlaceableNode[key])
		btn.Activated:Connect(function()
			if _emergency then _emergency.setEnabled(false) end
			_education.setSchoolType(key)
			_education.setEnabled(true)
			setSelectedService(key)
			setCivicInfo(spec.name, spec.desc, spec.cost, spec.accent)
		end)
	end

	showCivicTab = function(t: string, activate: boolean)
		civicTab = t
		emRow.Visible = t == "Emergency"
		edRow.Visible = t == "Education"
		civicPage:SetTab(t)
		if not activate then return end
		-- Selecting a tab activates that tab's first building (like Zoning's tabs
		-- pick the active zone).
		if t == "Emergency" then
			local key = emergencyKeys[1]
			local spec = ServiceTypes.get(key) :: any
			if _education then _education.setEnabled(false) end
			_emergency.setServiceType(key)
			_emergency.setEnabled(true)
			setSelectedService(key)
			setCivicInfo(spec.name, spec.desc, spec.cost, spec.accent)
		else
			local key = SchoolTypes.Order[1]
			local spec = SchoolTypes.get(key) :: any
			if _emergency then _emergency.setEnabled(false) end
			_education.setSchoolType(key)
			_education.setEnabled(true)
			setSelectedService(key)
			setCivicInfo(spec.name, spec.desc, spec.cost, spec.accent)
		end
	end
	_svcPages.Civic = function() showCivicTab(civicTab, true) end

	-- ---- UTILITIES PAGE (Electricity / Water tabs) ----
	-- Two utilities, two tabs. They shared one row until water grew a draw tool of its own:
	-- a row mixing turbines with buried mains reads as one system, and they are not one.
	-- The pipe tool's draw modes sit in the page's left RAIL, the same place and the same
	-- 2-wide grid the road dock puts them in -- a player who can draw a road can draw a main.
	local elecKeys: { string } = {}
	local waterKeys: { string } = {}
	for _, key in utilityKeys do
		local spec = ServiceTypes.get(key) :: any
		if spec.kind == "Power" or spec.kind == "PowerLine" then
			table.insert(elecKeys, key)
		else
			table.insert(waterKeys, key)
		end
	end

	-- With no water card in ServiceTypes.Order the Water tab would open an empty row, so the
	-- page drops to NO tabs at all (Dock hides the row when the list is empty).
	local utilTabs: { { key: string, label: string } } = {}
	if #waterKeys > 0 then
		utilTabs = { { key = "Electricity", label = "Electricity" }, { key = "Water", label = "Water" } }
	end
	local utilTab = "Electricity"
	local utilSel = elecKeys[1]
	local selectUtility: (string) -> ()
	local showUtilTab: (string, boolean) -> ()
	local utilPage = dockObj:AddPage({
		key = "Utilities", standardInfo = true, height = SHELF_H, railWidth = 62, infoHeight = Dock.INFO_SLIM,
		tabs = utilTabs,
		onTab = function(t: string) showUtilTab(t, true) end,
	})
	local setUtilInfo = makeInfo(utilPage)
	GridPicker.new(utilPage.RailAux, GRID_PICKER_SIZE)
	local elecRow = makeRow(utilPage.Content)
	local waterRow = makeRow(utilPage.Content)
	waterRow.Visible = false

	-- The pipe rail. Shown only while a pipe card is selected -- a wind turbine has no draw
	-- mode, so leaving the buttons up would be four dead controls.
	local pipeRailBtns: { [string]: any } = {}
	do
		local rail = utilPage.Rail
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0, Theme.Pad.XS)
		pad.PaddingLeft = UDim.new(0, Theme.Pad.XS)
		pad.Parent = rail
		local grid = Instance.new("UIGridLayout")
		grid.CellSize = UDim2.fromOffset(26, 26)
		grid.CellPadding = UDim2.fromOffset(4, 4)
		grid.SortOrder = Enum.SortOrder.LayoutOrder
		grid.Parent = rail
		local function refreshRail()
			local pipe = _tools.waterPipe
			if not pipe then return end
			local mode = pipe.getMode()
			for key, btn in pipeRailBtns do
				if key == "Angle" then
					btn:SetSelected(pipe.isAngleSnapEnabled())
				else
					btn:SetSelected(key == mode)
				end
			end
		end
		local function modeBtn(o: number, label: string, icon: any, modeKey: string)
			pipeRailBtns[modeKey] = IconButton.new({
				icon = icon, name = label, tooltip = label, parent = rail, size = 26, layoutOrder = o,
				onClick = function()
					if _tools.waterPipe then _tools.waterPipe.setMode(modeKey) end
					refreshRail()
				end,
			})
		end
		modeBtn(1, "Line", Icons.RoadStraight, "Straight")
		modeBtn(2, "Curve", Icons.RoadCurved, "Curved")
		modeBtn(3, "Freeform", Icons.RoadFreeform, "Freeform")
		modeBtn(4, "Bezier", Icons.RoadBezier, "AdvancedCurve")
		pipeRailBtns.Angle = IconButton.new({
			icon = Icons.Snap, name = "Angle Snap", tooltip = "Angle snap (15\u{00B0})",
			parent = rail, size = 26, layoutOrder = 5,
			onClick = function()
				local pipe = _tools.waterPipe
				if pipe then pipe.setAngleSnapEnabled(not pipe.isAngleSnapEnabled()) end
				refreshRail()
			end,
		})
		_pipeRail = { buttons = pipeRailBtns, refresh = refreshRail }
	end
	local function showPipeRail(on: boolean)
		for _, btn in pipeRailBtns do btn.Instance.Visible = on end
		if on and _pipeRail then _pipeRail.refresh() end
	end
	showPipeRail(false)

	local function addUtilCard(key: string, i: number, row: ScrollingFrame)
		local spec = ServiceTypes.get(key) :: any
		local card, preview, stroke = BuildCard.shell("Util_" .. key, i)
		-- A pipe has no building to frame in a viewport, so it gets a drawn card.
		if spec.kind == "Pipe" then
			buildPipePreview(preview, spec)
		else
			buildServiceBuildingPreview(preview, spec)
		end
		local btn = BuildCard.footer(card, spec.name)
		card.Parent = row
		_serviceCardStrokes[key] = stroke
		BuildCard.gate(card, DevelopmentTree.PlaceableNode[key])
		btn.Activated:Connect(function() selectUtility(key) end)
	end
	for i, key in elecKeys do addUtilCard(key, i, elecRow) end
	for i, key in waterKeys do addUtilCard(key, i, waterRow) end

	-- Exactly ONE of three tools is live: the power-line drag, the pipe drag, or the ghost
	-- placer that stamps a building where the cursor is.
	selectUtility = function(key: string)
		local spec = ServiceTypes.get(key) :: any
		if not spec then return end
		utilSel = key
		local isLine = spec.kind == "PowerLine"
		local isPipe = spec.kind == "Pipe"
		if _education then _education.setEnabled(false) end
		if isLine or isPipe then
			_emergency.setEnabled(false)
		else
			_emergency.setServiceType(key)
			_emergency.setEnabled(true)
		end
		if _tools.powerLine then _tools.powerLine.setEnabled(isLine) end
		if _tools.waterPipe then
			-- Kind BEFORE enable: the first preview frame reads it, and switching between
			-- two pipe cards never toggles enabled, so setEnabled alone would not carry it.
			if isPipe then _tools.waterPipe.setPipeKind(key) end
			_tools.waterPipe.setEnabled(isPipe)
		end
		showPipeRail(isPipe)
		setSelectedService(key)
		setUtilInfo(spec.name, spec.desc, spec.cost, spec.accent)
	end

	-- The electricity balance belongs to the Electricity tab and the water balance to the
	-- Water tab, so each opens and closes with its own tab rather than with the section.
	local function sidePanel(name: string): any?
		local ok, panel = pcall(function()
			return require(script.Parent.Parent:WaitForChild("HUD"):WaitForChild(name)) :: any
		end)
		return if ok then panel else nil
	end

	showUtilTab = function(t: string, activate: boolean)
		utilTab = t
		elecRow.Visible = t == "Electricity"
		waterRow.Visible = t == "Water"
		utilPage:SetTab(t)
		local elec = sidePanel("ElectricityPanelController")
		local water = sidePanel("WaterPanelController")
		if elec then if t == "Electricity" then elec.Open() else elec.Close() end end
		if water then if t == "Water" then water.Open() else water.Close() end end
		if not activate then return end
		local keys = if t == "Electricity" then elecKeys else waterKeys
		local key = if table.find(keys, utilSel) then utilSel else keys[1]
		if key then selectUtility(key) end
	end
	_svcPages.Utilities = function() showUtilTab(utilTab, true) end

	-- ---- TRANSIT PAGE (Depot / Stop / Route tools + Overview, single card row) ----
	local TransitTypes = require(ReplicatedStorage:WaitForChild("Transit"):WaitForChild("TransitTypes")) :: any
	local transitPage = dockObj:AddPage({
		key = "Transit", standardInfo = true, height = SHELF_H, railWidth = 0, infoHeight = Dock.INFO_SLIM,
		tabs = {},
		onTab = function() end,
	})
	local setTransitInfo = makeInfo(transitPage)
	GridPicker.new(transitPage.RailAux, GRID_PICKER_SIZE)
	local tRow = makeRow(transitPage.Content)
	local transitInfoFor: { [string]: () -> () } = {}
	for i, def in TRANSIT_TOOLS do
		local card, preview, stroke = BuildCard.shell("Transit_" .. def.key, i)
		buildTransitPreview(preview, def.key, def.color)
		local btn = BuildCard.footer(card, def.name)
		card.Parent = tRow
		_transitCardStrokes[def.key] = stroke
		BuildCard.gate(card, DevelopmentTree.PlaceableNode[TRANSIT_PLACEABLE[def.key]])
		local toolKey = def.key
		local spec: any = if toolKey == "Depot" then TransitTypes.getDepot("BusDepot")
			elseif toolKey == "Stop" then TransitTypes.getStop("BusStop")
			elseif toolKey == "Station" then TransitTypes.getStop("TrainStation")
			else nil
		local desc = if spec then spec.desc else "Click stops in order to draw a loop; click the first stop again to close it."
		local cost = if spec then spec.cost else 0
		local toolColor = def.color
		transitInfoFor[toolKey] = function()
			setTransitInfo(def.name, desc, cost, toolColor)
		end
		btn.Activated:Connect(function()
			if _education then _education.setEnabled(false) end
			if _emergency then _emergency.setEnabled(false) end
			_transit.setTool(toolKey)
			_transit.setEnabled(true)
			setSelectedTransit(toolKey)
			transitInfoFor[toolKey]()
		end)
	end
	local ovCard, ovPreview = BuildCard.shell("Transit_Overview", #TRANSIT_TOOLS + 1)
	buildTransitPreview(ovPreview, "Overview", Color3.fromRGB(55, 75, 110))
	local ovBtn = BuildCard.footer(ovCard, "Overview")
	ovCard.Parent = tRow
	ovBtn.Activated:Connect(function() if _overview then _overview.Toggle() end end)
	_svcPages.Transit = function()
		if _education then _education.setEnabled(false) end
		if _emergency then _emergency.setEnabled(false) end
		local tool = _transit.getTool()
		_transit.setEnabled(true)
		setSelectedTransit(tool)
		local showInfo = transitInfoFor[tool]
		if showInfo then showInfo() end
	end
end

-- =====================================================================
--  FLYOUT SHOW / HIDE
-- =====================================================================
local function showFlyout(section: string)
	local dock = _dock
	_roadDock.Show(section == "Roads")
	showZoneDock(section == "Zoning")
	-- Civic / Utilities / Transit are dock pages (bottom-right), same as Roads/Zoning.
	-- Each page's show() syncs its info bar, selection and the active placement tool.
	if not dock then return end
	if section == "Civic" or section == "Utilities" or section == "Transit" then
		dock:ShowPage(section)
		local show = _svcPages[section]
		if show then show() end
	else
		dock:Hide("Civic")
		dock:Hide("Utilities")
		dock:Hide("Transit")
	end
end

local function hideFlyout()
	_roadDock.Show(false)
	showZoneDock(false)
	if _dock then
		_dock:Hide("Civic")
		_dock:Hide("Utilities")
		_dock:Hide("Transit")
	end
end

-- The dock and the options strip are both centred above the rail now, so they
-- have to stack rather than share a slot: the strip rides above whatever height
-- the dock is currently at, and drops back down to the rail when it closes.
local function syncStripOffset()
	local height = if _dock then (_dock :: any):Height() else 0
	local clearance = if height > 0 then height + 8 else 0
	ToolStripController.SetBottomOffset(-(ToolRail.bottomInset() + clearance))
end
-- =====================================================================
--  SECTION LIFECYCLE
-- =====================================================================
local function deactivateSection(section: string?)
	if section == "Roads" then
		_road.setEnabled(false); _road.cancel()
		_roadDock.Deactivate()
	elseif section == "Zoning" then
		_zoning.setEnabled(false)
	elseif section == "Civic" or section == "Utilities" then
		if _tools.powerLine then _tools.powerLine.setEnabled(false) end
		if _tools.waterPipe then _tools.waterPipe.setEnabled(false) end
		if section == "Utilities" then
			for _, name in { "ElectricityPanelController", "WaterPanelController" } do
				local ok, panel = pcall(function()
					return require(script.Parent.Parent:WaitForChild("HUD"):WaitForChild(name)) :: any
				end)
				if ok and panel then panel.Close() end
			end
		end
		if _education then _education.setEnabled(false) end
		if _emergency then _emergency.setEnabled(false) end
	elseif section == "Transit" then
		if _transit then _transit.setEnabled(false) end
	end
end

local function activateSection(section: string)
	if section == "Roads" then
		_road.setEnabled(true)
		_roadDock.Activate()
	elseif section == "Zoning" then _zoning.setEnabled(true)
	-- Utilities opens the electricity balance from its ELECTRICITY tab (showUtilTab), not
	-- from here: the water tab has nothing to do with megawatts.
	-- Civic / Transit enable their placement tool from the dock's show()
	-- (buildServiceDocks / _svcPages), so activateSection has nothing to do for them.
	end
end
function BottomBarController.CloseSection()
	-- Painter/Picker are not sections, but every tool that opens goes through here first.
	if _tools.paint then _tools.paint.setMode(nil) end
	-- The tile view sinks world clicks, so it goes away before any other tool opens.
	if _tools.land then _tools.land.setEnabled(false) end
	if not _activeSection then return end
	deactivateSection(_activeSection)
	_activeSection = nil
	for _, def in CATEGORY_DEFS do
		ToolRail.setSelected(def.key, false)
	end
	hideFlyout()
	syncStripOffset()
	ToolStripController.SetSection(nil)
end

function BottomBarController.OpenSection(section: string)
	if _tools.land then _tools.land.setEnabled(false) end
	if _activeSection == section then return end
	if _tools.bulldoze and _tools.bulldoze.isEnabled() then _tools.bulldoze.setEnabled(false) end
	if _tools.move and _tools.move.isEnabled() then _tools.move.setEnabled(false) end
	if _terrain and _terrain.IsOpen() then _terrain.Close() end
	if _tools.paint then _tools.paint.setMode(nil) end
	deactivateSection(_activeSection)
	_activeSection = section
	for _, def in CATEGORY_DEFS do
		ToolRail.setSelected(def.key, def.key == section)
	end
	showFlyout(section)
	syncStripOffset()
	-- Roads keeps its tools inside the shared dock; Zoning shows the ToolStrip,
	-- which carries the plot SIZE steppers (W/D), the placement modes and the
	-- Mirror toggle -- none of which have a home in the zone dock.
	ToolStripController.SetSection(if section == "Zoning" then "Zoning" else nil)
	activateSection(section)
end

function BottomBarController.GetActiveSection(): string?
	return _activeSection
end

function BottomBarController.IsBulldozeActive(): boolean
	return _tools.bulldoze ~= nil and _tools.bulldoze.isEnabled()
end

-- Painter or Picker owns the click: selection must stand down, exactly as for the bulldozer.
function BottomBarController.IsPaintActive(): boolean
	return _tools.paint ~= nil and _tools.paint.getMode() ~= nil
end

-- =====================================================================
--  START
-- =====================================================================
function BottomBarController.Start()
	if _started then return end
	_started = true

	local controllers = script.Parent
	_road      = require(controllers:WaitForChild("RoadPlacementController")) :: any
	_roadDock  = require(controllers:WaitForChild("RoadDockPanel")) :: any
	-- Manor Lords burgage plot tool (drag a road = zone a strip that grows; click
	-- = stamp one plot built at once). The only zoning tool.
	_zoning    = require(controllers:WaitForChild("PlotController")) :: any
	_education = require(controllers:WaitForChild("SchoolPlacementController")) :: any
	_emergency = require(controllers:WaitForChild("EmergencyPlacementController")) :: any
	_tools.bulldoze  = require(controllers:WaitForChild("BulldozeController")) :: any
	_tools.move = require(controllers:WaitForChild("RoadMoveController")) :: any
	-- The Power Line is DRAWN, not stamped, so it is its own tool rather than
	-- another card on the ghost placer.
	_tools.powerLine = require(controllers:WaitForChild("PowerLineController")) :: any
	_tools.waterPipe = require(controllers:WaitForChild("WaterPipeController")) :: any
	_terrain   = require(controllers:WaitForChild("TerrainPanelController")) :: any
	-- The LAND view: the tile grid the map is bought with. Its own tool rather than a
	-- dock page, for the same reason Bulldoze is one -- it has no catalogue to show.
	_tools.land = require(controllers:WaitForChild("TerritoryController")) :: any
	_tools.paint = require(controllers:WaitForChild("PropPaintTool")) :: any
	_transit   = require(controllers:WaitForChild("TransitPlacementController")) :: any
	_overview  = require(script.Parent.Parent:WaitForChild("HUD"):WaitForChild("TransportOverviewController")) :: any

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local gui = playerGui:WaitForChild("CityUI", 60)
	if not gui or not gui:IsA("ScreenGui") then
		warn("[BottomBarController] CityUI ScreenGui not found - aborting")
		_started = false
		return
	end
	_gui = gui
	HudScale.attach(gui)

	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	local hudFolder = script.Parent.Parent:WaitForChild("HUD")
	local DashboardController = require(hudFolder:WaitForChild("DashboardController")) :: any
	local PlayerHubController = require(hudFolder:WaitForChild("PlayerHubController")) :: any

	if _tools.land then
		_tools.land.Init(gui)
		_tools.land.Bind()
	end

	-- ------------------------------------------------------------------
	--  THE RAIL. Groups read left to right: place, edit, inspect.
	-- ------------------------------------------------------------------
	local entries: { ToolRail.Entry } = {}

	-- The resting tool, and the rail's leftmost button. Nothing is "the select
	-- tool" in this game -- a bare cursor already inspects roads and buildings --
	-- so this puts every tool away and then lights itself, which is what makes the
	-- rail read as having a current state rather than going blank between tools.
	-- ToolRail derives its lit state, so no other path has to remember it.
	table.insert(entries, {
		key = "Select", icon = Icons.EditorSelect, label = "Select", group = 0, isDefault = true,
		tooltip = "Put tools away \u{00B7} click roads & buildings to inspect",
		onClick = function()
			BottomBarController.CloseSection()
			if _terrain then _terrain.Close() end
			if _tools.bulldoze then _tools.bulldoze.setEnabled(false) end
			if _tools.move then _tools.move.setEnabled(false) end
		end,
	})

	for _, def in CATEGORY_DEFS do
		local key = def.key
		table.insert(entries, {
			key = key,
			icon = def.icon,
			label = def.label,
			group = 1,
			onClick = function()
				if _activeSection == key then
					BottomBarController.CloseSection()
				else
					BottomBarController.OpenSection(key)
				end
			end,
		})
	end

	table.insert(entries, {
		key = "Terrain", icon = Icons.Terrain, label = "Terrain", group = 1,
		tooltip = "Sculpt, trails & props",
		onClick = function()
			if not _terrain then return end
			-- Open on the BUILD half means this button is not the one that is lit,
			-- so pressing it switches to Terrain rather than closing the dock out
			-- from under Build.
			if _terrain.IsOpen() and not _terrain.IsBuildOpen() then
				_terrain.Close()
			else
				BottomBarController.CloseSection()
				if _tools.bulldoze then _tools.bulldoze.setEnabled(false) end
				if _tools.move then _tools.move.setEnabled(false) end
				_terrain.Open()
			end
		end,
	})

	-- Shapes and the player's own saved creations: a different job from dressing
	-- a map with trees, so a top-level tool rather than a tab inside Terrain.
	table.insert(entries, {
		key = "Build", icon = Icons.Monument, label = "Build", group = 1,
		tooltip = "Shapes & creations",
		onClick = function()
			if not _terrain then return end
			if _terrain.IsBuildOpen() then
				_terrain.Close()
			else
				BottomBarController.CloseSection()
				if _tools.bulldoze then _tools.bulldoze.setEnabled(false) end
				if _tools.move then _tools.move.setEnabled(false) end
				_terrain.OpenBuild()
			end
		end,
	})

	table.insert(entries, {
		key = "Move", icon = Icons.Move, label = "Move", group = 2,
		tooltip = "Drag intersections & road segments",
		onClick = function()
			local move = _tools.move
			if not move then return end
			if move.isEnabled() then
				move.setEnabled(false)
			else
				BottomBarController.CloseSection()
				if _terrain then _terrain.Close() end
				if _tools.bulldoze then _tools.bulldoze.setEnabled(false) end
				move.setEnabled(true)
			end
		end,
	})

	table.insert(entries, {
		key = "Land", icon = Icons.PlotArea, label = "Land", group = 2,
		tooltip = "Buy map tiles",
		onClick = function()
			local land = _tools.land
			if not land then return end
			if land.isEnabled() then
				land.setEnabled(false)
			else
				BottomBarController.CloseSection()
				if _terrain then _terrain.Close() end
				if _tools.bulldoze then _tools.bulldoze.setEnabled(false) end
				if _tools.move then _tools.move.setEnabled(false) end
				land.setEnabled(true)
			end
		end,
	})

	table.insert(entries, {
		key = "Bulldoze", icon = Icons.Bulldoze, label = "Bulldoze", group = 2, danger = true,
		tooltip = "Delete roads, buildings & stops",
		onClick = function()
			if not _tools.bulldoze then return end
			if _tools.bulldoze.isEnabled() then
				_tools.bulldoze.setEnabled(false)
			else
				BottomBarController.CloseSection()
				if _terrain then _terrain.Close() end
				if _tools.move then _tools.move.setEnabled(false) end
				_tools.bulldoze.setEnabled(true)
			end
		end,
	})

	-- Painter and Picker act on props already standing in the city (PropPaintTool).
	-- Each is a toggle; opening either puts every other tool away first.
	local function paintEntry(key: string, tip: string, icon: any)
		table.insert(entries, {
			key = key, icon = icon, label = key, group = 2, tooltip = tip,
			onClick = function()
				local paint = _tools.paint
				if not paint then return end
				if paint.getMode() == key then paint.setMode(nil); return end
				BottomBarController.CloseSection()
				if _terrain then _terrain.Close() end
				if _tools.bulldoze then _tools.bulldoze.setEnabled(false) end
				if _tools.move then _tools.move.setEnabled(false) end
				local root = ToolRail.getRoot()
				local btn = root and root:FindFirstChild(key, true)
				paint.setMode(key, if btn and btn:IsA("GuiObject") then btn else nil)
			end,
		})
	end
	paintEntry("Painter", "Painter \u{2014} click props to paint them, right-click to sample", Icons.BuildColour)
	paintEntry("Picker", "Picker \u{2014} click a prop to place another just like it", Icons.ClassPart)

	table.insert(entries, {
		key = "Hub", icon = Icons.Info, label = "Hub", group = 3,
		tooltip = "Player hub (H)",
		onClick = function() PlayerHubController.Toggle() end,
	})
	table.insert(entries, {
		key = "Stats", icon = Icons.Stats, label = "Stats", group = 3,
		tooltip = "City dashboard",
		onClick = function() DashboardController.Toggle("Overview") end,
	})

	local rail = ToolRail.build(gui, entries)
	rail.Visible = false

	-- Everything that opens above the rail measures from ToolRail.bottomInset(),
	-- so the dock, the options strip and the Move It panel share one baseline
	-- instead of each re-deriving it from a bar that no longer exists.
	local inset = ToolRail.bottomInset()
	local stripOffset = -inset

	-- Centred above the rail, not pinned to the corner: the panel belongs to the
	-- button that opened it.
	local dockObj = Dock.new({
		parent = gui,
		position = UDim2.new(0.5, 0, 1, -inset),
		-- A page's close button hides the shelf AND puts the tool away: the dock can
		-- only do the first, and a lit rail button over a shut shelf reads as a bug.
		onClose = function(key: string)
			if key == "Terrain" then
				if _terrain then _terrain.Close() end
			else
				BottomBarController.CloseSection()
			end
		end,
	})
	_dock = dockObj
	_roadDock.Init({ dock = dockObj, gui = gui, road = _road })
	buildZonePage(dockObj)
	buildServiceDocks(dockObj)
	_terrain.InitDock(dockObj)
	-- Bulldoze is a TOOL, not a build category: it gets a small options panel
	-- above the rail instead of a page on the shelf.
	_tools.bulldoze.InitPanel(gui)
	_tools.move.InitDock(dockObj)
	setSelectedZone("Residential")
	setSelectedService(_education.getSchoolType())

	ToolStripController.Init({ parent = gui, road = _road, zoning = _zoning, bottomOffset = stripOffset })
	_road.setStateListener(function() ToolStripController.Refresh(); _roadDock.Refresh() end)

	UIEvents.GameEntered.Event:Connect(function()
		-- A city always opens with no tool selected. Returning to the main menu
		-- leaves the active section alone (nothing here listens for it), so
		-- whatever was open last time was still on screen when the next city
		-- loaded.
		BottomBarController.CloseSection()
		ToolRail.reveal()
	end)

	-- Development-tree unlocks: grey out + lock cards for nodes not yet bought.
	Net.SyncProgression.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" or typeof(payload.unlocked) ~= "table" then return end
		BuildCard.setUnlocked(payload.unlocked)
		if typeof(payload.tier) == "number" then
			BuildCard.setTier(payload.tier)
			-- A density this city has not reached (a different city loaded) falls back to Low.
			local grantAt = require(ReplicatedStorage.City.MilestoneUnlocks).zoneMilestone(_zoneTools.density)
			if grantAt and grantAt > payload.tier and not workspace:GetAttribute("Sandbox") then
				_zoneTools.density = "Low"
				if _zoning then _zoning.setDensity("Low") end
				refreshZoneDock()
			end
		end
	end)

	local charRemovingConn: RBXScriptConnection
	charRemovingConn = player.CharacterRemoving:Connect(function()
		_road.Cleanup(); _zoning.Cleanup(); _education.Cleanup()
		if _emergency then _emergency.Cleanup() end
		if _transit then _transit.Cleanup() end
		_tools.bulldoze.Cleanup()
		if _tools.move then _tools.move.Cleanup() end
		_tools.paint.Cleanup()
		charRemovingConn:Disconnect()
	end)

	_road.Init(); _road.Bind(); _road.Start()
	_zoning.Init(); _zoning.Bind()
	_education.Init(); _education.Bind(); _education.Start()
	_emergency.Init(); _emergency.Bind(); _emergency.Start()
	_transit.Init(); _transit.Bind(); _transit.Start()
	_tools.bulldoze.Init(); _tools.bulldoze.Bind()
	_tools.bulldoze.setStateListener(function(active: boolean)
		ToolRail.setSelected("Bulldoze", active)
	end)
	_tools.move.Init(); _tools.move.Bind()
	_tools.powerLine.Init(); _tools.powerLine.Bind()
	_tools.waterPipe.Init(); _tools.waterPipe.Bind()
	_tools.waterPipe.setStateListener(function()
		if _pipeRail then _pipeRail.refresh() end
	end)
	_tools.move.setStateListener(function(active: boolean)
		ToolRail.setSelected("Move", active)
	end)
	_tools.paint.setStateListener(function(mode: string?)
		ToolRail.setSelected("Painter", mode == "Painter")
		ToolRail.setSelected("Picker", mode == "Picker")
	end)
	_terrain.Start()
	_terrain.setStateListener(function(open: boolean)
		-- One page, two buttons: exactly one is lit, decided by which opened it.
		local build = open and _terrain.IsBuildOpen()
		ToolRail.setSelected("Terrain", open and not build)
		ToolRail.setSelected("Build", build)
	end)
end

return BottomBarController
