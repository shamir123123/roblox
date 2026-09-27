--!strict
-- BuildRail
-- The build tool's settings as ONE labelled toolbar above the shelf:
--   [Colour] [Material] [Snap] [Precise] [Local/World] [Pivot] [Collide]
-- Local/World and Pivot only exist while Precise is on (they mean nothing without handles).
--
-- 2026-09-22: this used to be nine unlabelled icons on the dock's rail PLUS a row of six
-- loose chips (Randomize, Grid, 8, Stack, Precise, Colour) doing overlapping jobs -- two
-- colour buttons, three snap buttons, a grid toggle that was really a fourth snap setting.
-- Players could not tell what was where. Every setting now has one home, with a name on it:
--   * Colour opens the colour menu, which also carries OPACITY.
--   * Material opens a grid of real 3D material previews, painted in the current colour.
--   * Snap holds move / rotate / size steps, the vertical grid and tile-to-shape-size.
-- Raise/Lower lost their buttons: the elevation keys still do it.
--
-- Owns NO state. Snapping, space and pivot live in EditorGizmos; colour, material,
-- transparency and collision in NaturePlacementController. `sync()` reads them back.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local uiFolder = script.Parent.Parent:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local Icons = require(uiFolder:WaitForChild("Icons"))
local kit = uiFolder:WaitForChild("Kit")
local Popover = require(kit:WaitForChild("Popover"))
local Button = require(kit:WaitForChild("Button"))
local Toggle = require(kit:WaitForChild("Toggle"))

local EditorGizmos = require(script.Parent:WaitForChild("EditorGizmos"))
local NatureGizmo = require(script.Parent:WaitForChild("NatureGizmo"))
local Nature = require(script.Parent:WaitForChild("NaturePlacementController"))
local ColorPanel = require(script.Parent:WaitForChild("ColorPanel"))
local MaterialCatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MaterialCatalog"))

local BuildRail = {}

local CHIP_H = 28
local ROW_H = 26
local MAT_TILE = 56
local MAT_COLS = 5
local NEUTRAL = Color3.fromRGB(200, 204, 210)

type Chip = { button: TextButton, label: TextLabel, icon: ImageLabel?, set: (on: boolean) -> () }

local _built = false
local _gui: GuiBase2d? = nil
local _host: Frame? = nil
local _bar: Frame? = nil
local _pops: { Popover.Popover } = {}
local _chips: { [string]: Chip } = {}
local _swatch: Frame? = nil
local _matChipSwatch: ViewportFrame? = nil
local _snapRows: { [string]: { [string]: Button.Button } } = {}
local _vertToggle: Toggle.Toggle? = nil
local _tileToggle: Toggle.Toggle? = nil
local _matTiles: { [number]: { frame: Frame, stroke: UIStroke, part: BasePart? } } = {}
local _matBuilt = false
local _matScroll: ScrollingFrame? = nil
local _pivotBtn: Button.Button? = nil

local sync: () -> ()

local function corner(inst: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = inst
end

-- == Chip =====================================================================
-- A capsule with an icon (or a live swatch) and a NAME. The name is the fix: the old rail
-- was nine glyph-sized squares nobody could tell apart.
local function chip(key: string, text: string, icon: Icons.Icon?, order: number, onClick: () -> ()): Chip
	local b = Instance.new("TextButton")
	b.Name = key
	b.Text = ""
	b.AutoButtonColor = false
	b.BorderSizePixel = 0
	b.BackgroundColor3 = Theme.Color.BgRaised
	b.BackgroundTransparency = 0.15
	b.AutomaticSize = Enum.AutomaticSize.X
	b.Size = UDim2.fromOffset(0, CHIP_H)
	b.LayoutOrder = order
	b.Parent = _bar
	corner(b, CHIP_H // 2)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 12)
	pad.Parent = b
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 6)
	list.Parent = b

	local img: ImageLabel? = nil
	if icon then
		local i = Instance.new("ImageLabel")
		i.Name = "Icon"
		i.BackgroundTransparency = 1
		i.Size = UDim2.fromOffset(16, 16)
		i.Image = icon.image
		i.ImageColor3 = Theme.Color.TextPrimary
		i.LayoutOrder = 1
		i.Parent = b
		img = i
	end
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.AutomaticSize = Enum.AutomaticSize.X
	l.Size = UDim2.fromOffset(0, CHIP_H)
	l.Text = text
	l.TextColor3 = Theme.Color.TextPrimary
	l.TextSize = Theme.TextSize.XS
	l.FontFace = Theme.Font.Bold
	l.LayoutOrder = 2
	l.Parent = b

	b.MouseEnter:Connect(function()
		if b.BackgroundColor3 ~= Theme.Color.Accent then b.BackgroundColor3 = Theme.Color.BgHover end
	end)
	b.MouseLeave:Connect(function() sync() end)
	b.Activated:Connect(function()
		onClick()
		sync()
	end)

	local c: Chip = {
		button = b, label = l, icon = img,
		set = function(on: boolean)
			b.BackgroundColor3 = if on then Theme.Color.Accent else Theme.Color.BgRaised
			b.BackgroundTransparency = if on then 0 else 0.15
			l.TextColor3 = if on then Theme.Color.OnAccent else Theme.Color.TextPrimary
			if img then img.ImageColor3 = l.TextColor3 end
		end,
	}
	_chips[key] = c
	return c
end

local function popover(anchor: GuiObject, name: string, w: number, h: number, onOpen: ((boolean) -> ())?): Popover.Popover
	local pop = Popover.new({
		anchor = anchor,
		parent = _gui :: GuiBase2d,
		size = UDim2.fromOffset(w, h),
		name = name,
		onOpenChanged = function(open: boolean)
			if open then
				-- One flyout at a time, and never on top of the colour menu.
				for _, p in _pops do if p.Frame.Name ~= name then p:Hide() end end
				ColorPanel.close()
			end
			if onOpen then onOpen(open) end
			sync()
		end,
	})
	table.insert(_pops, pop)
	return pop
end

local function heading(parent: Instance, text: string, order: number): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, 0, 0, 16)
	l.LayoutOrder = order
	l.Text = string.upper(text)
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextColor3 = Theme.Color.TextSecondary
	l.TextSize = Theme.TextSize.XS
	l.FontFace = Theme.Font.Bold
	l.Parent = parent
	return l
end

local function listed(frame: Instance, gap: number)
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, gap)
	list.Parent = frame
end

local function toggleRow(parent: Instance, text: string, order: number, get: () -> boolean,
	set: (on: boolean) -> ()): Toggle.Toggle
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, ROW_H)
	row.LayoutOrder = order
	row.Parent = parent
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, -50, 1, 0)
	l.Text = text
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextColor3 = Theme.Color.TextPrimary
	l.TextSize = Theme.TextSize.XS
	l.FontFace = Theme.Font.Label
	l.Parent = row
	local t = Toggle.new({ parent = row, value = get(), onChange = function(on: boolean) set(on); sync() end })
	t.Instance.AnchorPoint = Vector2.new(1, 0.5)
	t.Instance.Position = UDim2.new(1, 0, 0.5, 0)
	return t
end

-- == Material previews ========================================================
-- A lit 3D cube per material, rendered in the colour you are about to paint with, so the
-- tile shows what you will actually get -- not a name and a guess. Built the first time the
-- flyout opens: forty live viewports are not free, and most sessions never open it.
local function previewCube(vp: ViewportFrame, mat: Enum.Material?): BasePart
	local p = Instance.new("Part")
	p.Anchored = true
	p.Size = Vector3.new(4, 4, 4)
	p.Material = mat or Enum.Material.SmoothPlastic
	p.Color = Nature.getPlaceColor() or NEUTRAL
	p.CFrame = CFrame.Angles(0, math.rad(35), 0)
	p.Parent = vp
	local cam = Instance.new("Camera")
	cam.FieldOfView = 30
	cam.CFrame = CFrame.lookAt(Vector3.new(7.5, 6.5, 9.5), Vector3.zero)
	cam.Parent = vp
	vp.CurrentCamera = cam
	vp.Ambient = Color3.fromRGB(150, 150, 155)
	vp.LightColor = Color3.fromRGB(255, 250, 240)
	vp.LightDirection = Vector3.new(-0.6, -1, -0.4)
	return p
end

local function buildMaterialTiles()
	if _matBuilt or not _matScroll then return end
	_matBuilt = true
	local rows = { { idx = 0, label = "Default" } }
	for i, name in MaterialCatalog.order do
		table.insert(rows, { idx = i, label = name })
	end
	for order, row in rows do
		local idx = row.idx
		local tile = Instance.new("Frame")
		tile.Name = row.label
		tile.BackgroundColor3 = Theme.Color.BgRaised
		tile.BackgroundTransparency = 0.2
		tile.LayoutOrder = order
		tile.Parent = _matScroll
		corner(tile, Theme.Radius.SM)
		local st = Instance.new("UIStroke")
		st.Color = Theme.Color.Accent
		st.Thickness = 2
		st.Transparency = 1
		st.Parent = tile
		local vp = Instance.new("ViewportFrame")
		vp.BackgroundTransparency = 1
		vp.Size = UDim2.new(1, 0, 1, -14)
		vp.Parent = tile
		local part = previewCube(vp, if idx > 0 then MaterialCatalog.get(idx) else nil)
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.AnchorPoint = Vector2.new(0, 1)
		l.Position = UDim2.fromScale(0, 1)
		l.Size = UDim2.new(1, 0, 0, 14)
		l.Text = row.label
		l.TextColor3 = Theme.Color.TextSecondary
		l.TextSize = 10
		l.FontFace = Theme.Font.Label
		l.TextTruncate = Enum.TextTruncate.AtEnd
		l.Parent = tile
		local btn = Instance.new("TextButton")
		btn.Text = ""
		btn.BackgroundTransparency = 1
		btn.Size = UDim2.fromScale(1, 1)
		btn.ZIndex = 3
		btn.Parent = tile
		btn.Activated:Connect(function()
			Nature.setPlaceMaterial(idx)
			sync()
		end)
		_matTiles[idx] = { frame = tile, stroke = st, part = part }
	end
end

-- == Build ====================================================================
local function build()
	if _built or not (_host and _gui) then return end
	_built = true

	local bar = Instance.new("Frame")
	bar.Name = "BuildToolbar"
	bar.BackgroundTransparency = 1
	bar.AutomaticSize = Enum.AutomaticSize.X
	bar.Size = UDim2.fromOffset(0, CHIP_H)
	bar.LayoutOrder = 50
	bar.Parent = _host
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 6)
	list.Parent = bar
	_bar = bar

	-- Colour: the live colour rides on the chip as a dot, so the bar says what it will paint.
	local colour: Chip
	colour = chip("Colour", "Colour", nil, 1, function()
		for _, p in _pops do p:Hide() end
		ColorPanel.toggle(function(c: Color3)
			Nature.setPlaceColor(c)
			sync()
		end, {
			anchor = colour.button,
			transparency = Nature.getPlaceTransparency(),
			onTransparency = function(t: number) Nature.setPlaceTransparency(t); sync() end,
		})
	end)
	local dot = Instance.new("Frame")
	dot.Name = "Swatch"
	dot.Size = UDim2.fromOffset(16, 16)
	dot.BorderSizePixel = 0
	dot.LayoutOrder = 1
	dot.Parent = colour.button
	corner(dot, 8)
	local ds = Instance.new("UIStroke")
	ds.Color = Theme.Color.Stroke
	ds.Transparency = 0.3
	ds.Parent = dot
	_swatch = dot

	-- Material: a tiny live cube of the current material on the chip itself.
	local material: Chip
	material = chip("Material", "Material", nil, 2, function() end)
	local mvp = Instance.new("ViewportFrame")
	mvp.BackgroundTransparency = 1
	mvp.Size = UDim2.fromOffset(18, 18)
	mvp.LayoutOrder = 1
	mvp.Parent = material.button
	previewCube(mvp, nil)
	_matChipSwatch = mvp
	local matPop = popover(material.button, "MaterialFlyout", MAT_COLS * (MAT_TILE + 6) + 30, 330,
		function(open: boolean) if open then buildMaterialTiles() end end)
	material.button.Activated:Connect(function() matPop:Toggle() end)
	heading(matPop.Frame, "Material", 1)
	local scroll = Instance.new("ScrollingFrame")
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Position = UDim2.fromOffset(0, 22)
	scroll.Size = UDim2.new(1, 0, 1, -22)
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollBarThickness = 3
	scroll.ScrollBarImageColor3 = Theme.Color.Accent
	scroll.Parent = matPop.Frame
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(MAT_TILE, MAT_TILE + 14)
	grid.CellPadding = UDim2.fromOffset(6, 6)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = scroll
	_matScroll = scroll

	-- Snap: every lattice setting in one place, labelled in the units they move by.
	local snap = chip("Snap", "Snap", Icons.Snap, 3, function() end)
	local snapPop = popover(snap.button, "SnapFlyout", 300, 200)
	snap.button.Activated:Connect(function() snapPop:Toggle() end)
	listed(snapPop.Frame, 4)
	local order = 0
	-- No move row: moving is the game-wide placement grid, whose picker sits in the dock
	-- header on this page (TerrainPanelController) -- one control, not two that disagree.
	for _, channel in { "rotate", "size" } do
		order += 1
		heading(snapPop.Frame, if channel == "rotate" then "Rotate" else "Resize", order)
		order += 1
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, ROW_H)
		row.LayoutOrder = order
		row.Parent = snapPop.Frame
		local rl = Instance.new("UIListLayout")
		rl.FillDirection = Enum.FillDirection.Horizontal
		rl.Padding = UDim.new(0, 4)
		rl.SortOrder = Enum.SortOrder.LayoutOrder
		rl.Parent = row
		local btns: { [string]: Button.Button } = {}
		local presets = EditorGizmos.presetsFor(channel :: any)
		for i, p in presets do
			local key = p.key
			btns[key] = Button.new({
				text = EditorGizmos.presetLabel(channel :: any, key),
				parent = row,
				compact = true,
				layoutOrder = i,
				size = UDim2.new(1 / #presets, -4, 1, 0),
				onClick = function() EditorGizmos.setSnapPreset(channel :: any, key); sync() end,
			})
		end
		_snapRows[channel] = btns
	end
	_vertToggle = toggleRow(snapPop.Frame, "Snap height to the grid", 20,
		EditorGizmos.isVerticalSnap, EditorGizmos.setVerticalSnap)
	_tileToggle = toggleRow(snapPop.Frame, "Tile shapes edge to edge", 21,
		Nature.isTileShapes, Nature.setTileShapes)

	chip("Precise", "Precise", Icons.BuildPrecise, 4, function()
		Nature.setPrecise(not Nature.isPrecise())
	end)
	chip("Space", "Local", nil, 5, function()
		EditorGizmos.setSpace(if EditorGizmos.getSpace() == "Global" then "Relative" else "Global")
	end)
	local pivot = chip("Pivot", "Pivot", nil, 6, function() end)
	local pivotPop = popover(pivot.button, "PivotFlyout", 190, 120)
	pivot.button.Activated:Connect(function() pivotPop:Toggle() end)
	listed(pivotPop.Frame, 4)
	heading(pivotPop.Frame, "Pivot", 1)
	local defs = {
		{ text = "Move pivot", act = function() EditorGizmos.setPivotMode(not EditorGizmos.isPivotMode()) end },
		{ text = "Centre", act = function() EditorGizmos.resetPivot(); EditorGizmos.setPivotMode(false) end },
		{ text = "Base", act = function() EditorGizmos.alignPivot(); EditorGizmos.setPivotMode(false) end },
	}
	for i, def in defs do
		local b = Button.new({
			text = def.text, parent = pivotPop.Frame, compact = true, layoutOrder = 1 + i,
			size = UDim2.new(1, 0, 0, 24),
			onClick = function() def.act(); sync() end,
		})
		if i == 1 then _pivotBtn = b end
	end

	chip("Collide", "Collide", Icons.BuildCollide, 7, function()
		Nature.setPlaceCollide(not Nature.getPlaceCollide())
	end)

	NatureGizmo.setChangedListener(function() sync() end)
end

-- == Sync =====================================================================
sync = function()
	local on = Nature.isEnabled()
	if not on and not _built then return end
	build()
	if _bar then (_bar :: Frame).Visible = on end
	if not on then
		for _, p in _pops do p:Hide() end
		return
	end

	local precise = Nature.isPrecise()
	local function lit(key: string, v: boolean) local c = _chips[key]; if c then c.set(v) end end
	local function popOpen(name: string): boolean
		for _, p in _pops do if p.Frame.Name == name then return p:IsOpen() end end
		return false
	end
	lit("Colour", ColorPanel.isOpen())
	lit("Material", popOpen("MaterialFlyout"))
	lit("Snap", popOpen("SnapFlyout"))
	lit("Precise", precise)
	lit("Pivot", popOpen("PivotFlyout") or EditorGizmos.isPivotMode())
	lit("Space", false)
	lit("Collide", Nature.getPlaceCollide())
	for _, key in { "Space", "Pivot" } do
		local c = _chips[key]
		if c then c.button.Visible = precise end
	end
	local space = _chips.Space
	if space then space.label.Text = if EditorGizmos.getSpace() == "Global" then "World" else "Local" end

	for channel, rows in _snapRows do
		local active = EditorGizmos.getSnapPreset(channel :: any)
		for key, b in rows do b:SetSelected(key == active) end
	end
	if _vertToggle then (_vertToggle :: Toggle.Toggle):Set(EditorGizmos.isVerticalSnap()) end
	if _tileToggle then (_tileToggle :: Toggle.Toggle):Set(Nature.isTileShapes()) end
	if _pivotBtn then (_pivotBtn :: Button.Button):SetSelected(EditorGizmos.isPivotMode()) end

	local picked = Nature.getPlaceColor()
	local paint = picked or NEUTRAL
	if _swatch then
		(_swatch :: Frame).BackgroundColor3 = picked or ColorPanel.current()
		-- Dimmed while the template's own colours are kept: it still says what it WOULD paint.
		;(_swatch :: Frame).BackgroundTransparency = if picked then Nature.getPlaceTransparency() else 0.6
	end
	local mat = Nature.getPlaceMaterial()
	for idx, t in _matTiles do
		t.stroke.Transparency = if idx == mat then 0 else 1
		if t.part then (t.part :: BasePart).Color = paint end
	end
	local chipVp = _matChipSwatch
	if chipVp then
		local p = chipVp:FindFirstChildWhichIsA("BasePart")
		if p then
			p.Color = paint
			p.Material = (if mat > 0 then MaterialCatalog.get(mat) else nil) or Enum.Material.SmoothPlastic
		end
	end
end

-- == Public ===================================================================
-- `host` is the Tools strip row the toolbar joins (it brings its own list layout), `gui`
-- the ScreenGui the flyouts hang in.
function BuildRail.Mount(host: Frame, gui: GuiBase2d)
	_host = host
	_gui = gui
end

function BuildRail.sync()
	sync()
end

function BuildRail.closeFlyouts()
	for _, p in _pops do p:Hide() end
end

return BuildRail
