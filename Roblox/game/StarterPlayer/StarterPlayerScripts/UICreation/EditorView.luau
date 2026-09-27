--!strict
-- EditorView: builds the Creation Editor's Roblox-Studio-style UI. Pure
-- construction, no behaviour: every interactive element takes its callback
-- from `deps` or is returned in the refs table for EditorController to wire.
--
-- Layout mirrors Studio's default workspace and every panel is a DockWindow:
-- drag a title bar to tear a panel out, drop it near a screen edge to re-dock
-- (the accent preview shows the exact slot), drop anywhere else to float and
-- resize from the corner grip. Close boxes hide panels; the ribbon's panel
-- toggles bring them back.
--   TopBar     (full width): title | storage meter | Save / My Creations / Clear / Exit
--   Ribbon     (full width): icon tool modes | Duplicate Delete | Snap | Undo Redo | panel toggles
--   TOOLBOX    docked left   (asset browser: categories + card grid + search)
--   EXPLORER   docked right, top slot
--   PROPERTIES docked right, bottom slot
-- IgnoreGuiInset stays OFF so nothing hides behind the Roblox topbar buttons.

local Theme      = require(script.Parent.Parent.UI.Theme)
local Icons      = require(script.Parent.Parent.UI.Icons)
local Button     = require(script.Parent.Parent.UI.Kit.Button)
local IconButton = require(script.Parent.Parent.UI.Kit.IconButton)
local DockWindow = require(script.Parent.Parent.UI.Kit.DockWindow)

local EditorView = {}

local SWATCHES = {
	Color3.fromRGB(220, 74, 74), Color3.fromRGB(232, 152, 56), Color3.fromRGB(240, 214, 92),
	Color3.fromRGB(126, 196, 96), Color3.fromRGB(84, 168, 220), Color3.fromRGB(126, 110, 208),
	Color3.fromRGB(238, 238, 240), Color3.fromRGB(52, 54, 58),
}

local TOPBAR_H = 44
local RIBBON_H = 42
local DOCK_TOP = TOPBAR_H + RIBBON_H + 8

export type Deps = {
	onSave: () -> (),
	onMyCreations: () -> (),
	onClearAll: () -> (),
	onExit: () -> (),
	onMode: (mode: string) -> (),
	onDuplicate: () -> (),
	onDelete: () -> (),
	onUndo: () -> (),
	onRedo: () -> (),
	onSnap: () -> (),
	onExplorer: () -> (),
	onCustomize: () -> (),
	onSearch: (text: string) -> (),
	onSnapPreset: (channel: string, preset: string) -> (),
	onSnapCustom: (channel: string, value: number) -> (),
	onSpaceToggle: () -> (),
	snapPresetsFor: (channel: string) -> { { key: string, label: string } },
	onMaterialCycle: () -> (),
	onCommitSound: () -> (),
	onSwatch: (color: Color3) -> (),
	onCommitSize: () -> (),
	onCommitScale: () -> (),
	onCommitRot: () -> (),
}

export type Refs = {
	gui: ScreenGui,
	toast: TextLabel,
	meterFill: Frame,
	meterText: TextLabel,
	modeButtons: { [string]: any },
	dupBtn: any,
	delBtn: any,
	snapBtn: any,
	explorerBtn: any,
	customizeBtn: any,
	props: {
		panel: Frame,
		nameLabel: TextLabel,
		dimLabel: TextLabel,
		sizeRow: Frame,
		sizeBoxes: { TextBox },
		scaleBox: TextBox,
		rotBox: TextBox,
		matBtn: any,
		soundRow: Frame,
		soundBox: TextBox,
		empty: Frame,
	},
	explorer: { panel: Frame, list: ScrollingFrame },
	browser: { panel: Frame, search: TextBox, cats: ScrollingFrame, grid: ScrollingFrame, count: TextLabel },
	snap: { pop: Frame, rows: { [string]: any }, spaceBtn: any },
	host: any,
	windows: { toolbox: any, explorer: any, props: any },
}

-- == small helpers ============================================================
local function chrome(frame: Frame)
	frame.BackgroundColor3 = Theme.Color.BgRaised
	frame.BackgroundTransparency = 0.05
	frame.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Theme.Radius.MD)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Color.Stroke
	stroke.Thickness = 1
	stroke.Parent = frame
end

local function bar(parent: Instance, name: string, y: number, h: number): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.Position = UDim2.fromOffset(0, y)
	f.Size = UDim2.new(1, 0, 0, h)
	f.BackgroundColor3 = Theme.Color.Bg
	f.BackgroundTransparency = 0.04
	f.BorderSizePixel = 0
	f.Parent = parent
	local edge = Instance.new("Frame")
	edge.Name = "Edge"
	edge.AnchorPoint = Vector2.new(0, 1)
	edge.Position = UDim2.fromScale(0, 1)
	edge.Size = UDim2.new(1, 0, 0, 1)
	edge.BackgroundColor3 = Theme.Color.Stroke
	edge.BorderSizePixel = 0
	edge.Parent = f
	return f
end

local function label(parent: Instance, text: string, size: UDim2, pos: UDim2, font: Font, ts: number, col: Color3): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = size
	l.Position = pos
	l.FontFace = font
	l.Text = text
	l.TextSize = ts
	l.TextColor3 = col
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = parent
	return l
end

local function textBox(parent: Instance, name: string, placeholder: string): TextBox
	local tb = Instance.new("TextBox")
	tb.Name = name
	tb.BackgroundColor3 = Theme.Color.Bg
	tb.BorderSizePixel = 0
	tb.FontFace = Theme.Font.Label
	tb.PlaceholderText = placeholder
	tb.Text = ""
	tb.TextSize = Theme.TextSize.SM
	tb.TextColor3 = Theme.Color.TextPrimary
	tb.PlaceholderColor3 = Theme.Color.TextDisabled
	tb.ClearTextOnFocus = false
	tb.Parent = parent
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, Theme.Radius.SM); c.Parent = tb
	return tb
end

local function scrollList(parent: Instance, name: string, pos: UDim2, size: UDim2, pad: number): ScrollingFrame
	local sf = Instance.new("ScrollingFrame")
	sf.Name = name
	sf.Position = pos
	sf.Size = size
	sf.BackgroundTransparency = 1
	sf.BorderSizePixel = 0
	sf.CanvasSize = UDim2.new(0, 0, 0, 0)
	sf.AutomaticCanvasSize = Enum.AutomaticSize.Y
	sf.ScrollBarThickness = 5
	sf.Parent = parent
	local ll = Instance.new("UIListLayout")
	ll.Padding = UDim.new(0, pad)
	ll.SortOrder = Enum.SortOrder.LayoutOrder
	ll.Parent = sf
	return sf
end

-- == build ====================================================================
function EditorView.build(playerGui: PlayerGui, deps: Deps): Refs
	local gui = Instance.new("ScreenGui")
	gui.Name = "EditorUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false -- respect the Roblox topbar; nothing may hide behind it
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = Theme.Layer.Overlay
	gui.Enabled = false
	gui.Parent = playerGui
	require(script.Parent.Parent.UI.HudScale).attach(gui)

	-- == Top bar ==============================================================
	local top = bar(gui, "TopBar", 0, TOPBAR_H)
	top.ZIndex = 50
	local title = label(top, "CREATION EDITOR", UDim2.fromOffset(220, TOPBAR_H), UDim2.fromOffset(14, 0), Theme.Font.Bold, Theme.TextSize.MD, Theme.Color.TextPrimary)
	title.Name = "Title"
	title.ZIndex = 50

	-- storage meter, centered
	local meter = Instance.new("Frame")
	meter.Name = "Storage"
	meter.AnchorPoint = Vector2.new(0.5, 0.5)
	meter.Position = UDim2.new(0.5, 0, 0.5, 0)
	meter.Size = UDim2.fromOffset(300, 28)
	meter.BackgroundTransparency = 1
	meter.ZIndex = 50
	meter.Parent = top
	label(meter, "STORAGE", UDim2.fromOffset(58, 28), UDim2.fromOffset(0, 0), Theme.Font.Label, Theme.TextSize.XS, Theme.Color.TextSecondary)
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0, 0.5)
	track.Position = UDim2.new(0, 62, 0.5, 0)
	track.Size = UDim2.fromOffset(140, 8)
	track.BackgroundColor3 = Theme.Color.BgPress
	track.BorderSizePixel = 0
	track.Parent = meter
	local trc = Instance.new("UICorner"); trc.CornerRadius = UDim.new(1, 0); trc.Parent = track
	local meterFill = Instance.new("Frame")
	meterFill.Name = "Fill"
	meterFill.Size = UDim2.new(0, 0, 1, 0)
	meterFill.BackgroundColor3 = Color3.fromRGB(126, 196, 96)
	meterFill.BorderSizePixel = 0
	meterFill.Parent = track
	local fc = Instance.new("UICorner"); fc.CornerRadius = UDim.new(1, 0); fc.Parent = meterFill
	local meterText = label(meter, "-- KB free", UDim2.fromOffset(90, 28), UDim2.fromOffset(210, 0), Theme.Font.Label, Theme.TextSize.XS, Theme.Color.TextPrimary)
	meterText.Name = "FreeText"

	-- right-aligned actions
	local actions = Instance.new("Frame")
	actions.Name = "Actions"
	actions.AnchorPoint = Vector2.new(1, 0)
	actions.Position = UDim2.new(1, -10, 0, 0)
	actions.Size = UDim2.new(0, 480, 1, 0)
	actions.BackgroundTransparency = 1
	actions.ZIndex = 50
	actions.Parent = top
	local al = Instance.new("UIListLayout")
	al.FillDirection = Enum.FillDirection.Horizontal
	al.HorizontalAlignment = Enum.HorizontalAlignment.Right
	al.VerticalAlignment = Enum.VerticalAlignment.Center
	al.Padding = UDim.new(0, 6)
	al.Parent = actions
	Button.new({ text = "Save...", name = "Save", parent = actions, layoutOrder = 1, onClick = deps.onSave })
	Button.new({ text = "My Creations", name = "MyCreations", parent = actions, layoutOrder = 2, onClick = deps.onMyCreations })
	Button.new({ text = "Clear All", name = "ClearAll", parent = actions, layoutOrder = 3, onClick = deps.onClearAll })
	Button.new({ text = "Exit", name = "Exit", variant = "Danger", parent = actions, layoutOrder = 4, onClick = deps.onExit })

	-- == Tool ribbon (Studio toolbar: icon chips with tooltips) ===============
	local ribbon = bar(gui, "Ribbon", TOPBAR_H, RIBBON_H)
	ribbon.ZIndex = 50
	local row = Instance.new("Frame")
	row.Name = "Row"
	row.BackgroundTransparency = 1
	row.Position = UDim2.fromOffset(12, 0)
	row.Size = UDim2.new(1, -24, 1, 0)
	row.ZIndex = 50
	row.Parent = ribbon
	local rl = Instance.new("UIListLayout")
	rl.FillDirection = Enum.FillDirection.Horizontal
	rl.VerticalAlignment = Enum.VerticalAlignment.Center
	rl.Padding = UDim.new(0, 6)
	rl.SortOrder = Enum.SortOrder.LayoutOrder
	rl.Parent = row

	local order = 0
	local function sep()
		order += 1
		local s = Instance.new("Frame")
		s.Name = "Sep"
		s.BackgroundColor3 = Theme.Color.StrokeSoft
		s.BackgroundTransparency = 0.35
		s.BorderSizePixel = 0
		s.Size = UDim2.fromOffset(1, 22)
		s.LayoutOrder = order
		s.Parent = row
		local g = Instance.new("Frame")
		g.Name = "Gap"
		g.BackgroundTransparency = 1
		g.Size = UDim2.fromOffset(4, 1)
		order += 1
		g.LayoutOrder = order
		g.Parent = row
	end
	local function toolBtn(iconName: string, tip: string, onClick: () -> (), danger: boolean?): any
		order += 1
		return IconButton.new({
			icon = Icons.get(iconName), tooltip = tip, name = iconName, parent = row,
			size = 30, layoutOrder = order, danger = danger, onClick = onClick,
		})
	end

	local modeButtons: { [string]: any } = {}
	local MODE_DEFS = {
		{ "Select", "EditorSelect", "Select" },
		{ "Move", "EditorMove", "Move" },
		{ "Scale", "EditorScale", "Scale" },
		{ "Rotate", "EditorRotate", "Rotate" },
		{ "Transform", "EditorTransform", "Transform (all handles)" },
	}
	for _, def in MODE_DEFS do
		local mode = def[1]
		modeButtons[mode] = toolBtn(def[2], def[3], function() deps.onMode(mode) end)
	end
	sep()
	local dupBtn = toolBtn("EditorDuplicate", "Duplicate", deps.onDuplicate)
	local delBtn = toolBtn("EditorDelete", "Delete", deps.onDelete, true)
	sep()
	order += 1
	local snapBtn = Button.new({ text = "Snap: On", name = "Snap", parent = row, compact = true, layoutOrder = order, onClick = deps.onSnap })
	sep()
	local undoBtn = toolBtn("Undo", "Undo (Ctrl+Z)", deps.onUndo)
	local redoBtn = toolBtn("Redo", "Redo (Ctrl+Y)", deps.onRedo)
	local _ = undoBtn; local _ = redoBtn

	-- right side of the ribbon: Studio "View"-tab panel toggles
	local viewRow = Instance.new("Frame")
	viewRow.Name = "ViewRow"
	viewRow.AnchorPoint = Vector2.new(1, 0)
	viewRow.Position = UDim2.new(1, -12, 0, 0)
	viewRow.Size = UDim2.new(0, 520, 1, 0)
	viewRow.BackgroundTransparency = 1
	viewRow.ZIndex = 50
	viewRow.Parent = ribbon
	local vl = Instance.new("UIListLayout")
	vl.FillDirection = Enum.FillDirection.Horizontal
	vl.HorizontalAlignment = Enum.HorizontalAlignment.Right
	vl.VerticalAlignment = Enum.VerticalAlignment.Center
	vl.Padding = UDim.new(0, 6)
	vl.SortOrder = Enum.SortOrder.LayoutOrder
	vl.Parent = viewRow

	-- == Dock host + windows (Studio default workspace) =======================
	local host = DockWindow.newHost({ gui = gui, topOffset = DOCK_TOP, margin = 8 })

	local toolboxWin = host:CreateWindow({
		name = "Toolbox", title = "Toolbox", icon = Icons.get("EditorToolbox"),
		zone = "Left", floatSize = Vector2.new(540, 340), minSize = Vector2.new(320, 220),
	})
	local explorerWin = host:CreateWindow({
		name = "Explorer", title = "Explorer", icon = Icons.get("EditorExplorer"),
		zone = "Right", floatSize = Vector2.new(300, 400), minSize = Vector2.new(230, 160),
	})
	local propsWin = host:CreateWindow({
		name = "Properties", title = "Properties", icon = Icons.get("EditorProps"),
		zone = "Right", floatSize = Vector2.new(300, 420), minSize = Vector2.new(240, 220),
	})

	-- panel toggle buttons (right ribbon). Explorer goes through the controller
	-- so it can refresh the tree when re-shown; the others are pure visibility.
	Button.new({ text = "Toolbox", name = "ToolboxToggle", parent = viewRow, compact = true, layoutOrder = 1, onClick = function()
		toolboxWin.Frame.Visible = not toolboxWin.Frame.Visible
	end })
	local explorerBtn = Button.new({ text = "Explorer", name = "Explorer", parent = viewRow, compact = true, layoutOrder = 2, onClick = deps.onExplorer })
	Button.new({ text = "Properties", name = "PropsToggle", parent = viewRow, compact = true, layoutOrder = 3, onClick = function()
		propsWin.Frame.Visible = not propsWin.Frame.Visible
	end })
	local customizeBtn = Button.new({ text = "Customize", name = "Customize", parent = viewRow, compact = true, layoutOrder = 4, onClick = deps.onCustomize })

	-- Snap popover, anchored under the ribbon. Three channels, one preset list each, plus
	-- the space toggle -- the four things a transform gizmo needs and nothing else.
	local pop = Instance.new("Frame")
	pop.Name = "SnapPopover"
	pop.AnchorPoint = Vector2.new(0.5, 0)
	pop.Position = UDim2.new(0.5, 0, 0, TOPBAR_H + RIBBON_H + 4)
	pop.Size = UDim2.fromOffset(330, 182)
	pop.Visible = false
	pop.ZIndex = 55
	-- The dropdown lists open past the bottom edge on purpose.
	pop.ClipsDescendants = false
	chrome(pop)
	pop.Parent = gui
	label(pop, "SNAP", UDim2.fromOffset(300, 18), UDim2.fromOffset(12, 8), Theme.Font.Bold, Theme.TextSize.SM, Theme.Color.TextPrimary)

	local snapRows: { [string]: any } = {}
	local openList: Frame? = nil

	-- One channel: caption, the current preset, the list it opens, and the box that only
	-- matters once Custom is picked.
	local function snapRow(channel: string, caption: string, y: number)
		label(pop, caption, UDim2.fromOffset(80, 26), UDim2.fromOffset(12, y), Theme.Font.Label, Theme.TextSize.XS, Theme.Color.TextSecondary)
		local valueBtn = Button.new({ text = "Default snapping", name = channel .. "Preset", parent = pop, size = UDim2.fromOffset(160, 26) })
		valueBtn.Instance.Position = UDim2.fromOffset(94, y)

		local box = textBox(pop, channel .. "Custom", "step")
		box.Position = UDim2.fromOffset(262, y)
		box.Size = UDim2.fromOffset(56, 26)
		box.Visible = false
		box.FocusLost:Connect(function()
			local v = tonumber(box.Text)
			if v then deps.onSnapCustom(channel, v) end
		end)

		local list = Instance.new("Frame")
		list.Name = channel .. "List"
		list.Position = UDim2.fromOffset(94, y + 28)
		local presets = deps.snapPresetsFor(channel)
		list.Size = UDim2.fromOffset(160, #presets * 26 + 8)
		list.Visible = false
		list.ZIndex = 70
		chrome(list)
		list.Parent = pop
		for i, preset in presets do
			local key, text = preset.key, preset.label
			local opt = Button.new({ text = text, name = key, parent = list, size = UDim2.fromOffset(144, 24), onClick = function()
				list.Visible = false
				openList = nil
				deps.onSnapPreset(channel, key)
			end })
			opt.Instance.Position = UDim2.fromOffset(8, 4 + (i - 1) * 26)
			opt.Instance.ZIndex = 71
		end

		valueBtn.Instance.Activated:Connect(function()
			-- One list at a time, or two overlap and the lower one is unclickable.
			if openList and openList ~= list then openList.Visible = false end
			list.Visible = not list.Visible
			openList = if list.Visible then list else nil
		end)

		snapRows[channel] = { btn = valueBtn, list = list, box = box }
	end

	snapRow("move", "Move", 32)
	snapRow("size", "Size", 64)
	snapRow("rotate", "Rotate", 96)

	label(pop, "Space", UDim2.fromOffset(80, 26), UDim2.fromOffset(12, 136), Theme.Font.Label, Theme.TextSize.XS, Theme.Color.TextSecondary)
	local spaceBtn = Button.new({ text = "Relative", name = "Space", parent = pop, size = UDim2.fromOffset(160, 26), onClick = deps.onSpaceToggle })
	spaceBtn.Instance.Position = UDim2.fromOffset(94, 136)

	-- == TOOLBOX content (asset browser) ======================================
	local tb = toolboxWin.Content
	local search = textBox(tb, "Search", "Search assets...")
	search.Position = UDim2.fromOffset(8, 6)
	search.Size = UDim2.new(1, -16, 0, 26)
	search:GetPropertyChangedSignal("Text"):Connect(function() deps.onSearch(search.Text) end)

	local cats = scrollList(tb, "Cats", UDim2.fromOffset(8, 40), UDim2.new(0, 110, 1, -66), 2)
	cats.BackgroundTransparency = 0.6
	cats.BackgroundColor3 = Theme.Color.Bg
	local cc = Instance.new("UICorner"); cc.CornerRadius = UDim.new(0, Theme.Radius.SM); cc.Parent = cats

	local grid = Instance.new("ScrollingFrame")
	grid.Name = "Assets"
	grid.Position = UDim2.fromOffset(126, 40)
	grid.Size = UDim2.new(1, -134, 1, -66)
	grid.BackgroundTransparency = 1
	grid.BorderSizePixel = 0
	grid.CanvasSize = UDim2.new(0, 0, 0, 0)
	grid.AutomaticCanvasSize = Enum.AutomaticSize.Y
	grid.ScrollBarThickness = 6
	grid.Parent = tb
	local gl = Instance.new("UIGridLayout")
	gl.CellSize = UDim2.fromOffset(96, 108)
	gl.CellPadding = UDim2.fromOffset(8, 8)
	gl.SortOrder = Enum.SortOrder.LayoutOrder
	gl.Parent = grid

	local count = label(tb, "0 elements", UDim2.fromOffset(150, 18), UDim2.new(1, -158, 1, -22), Theme.Font.Label, Theme.TextSize.XS, Theme.Color.TextSecondary)
	count.Name = "Count"
	count.TextXAlignment = Enum.TextXAlignment.Right

	-- == EXPLORER content =====================================================
	local exList = scrollList(explorerWin.Content, "List", UDim2.fromOffset(8, 6), UDim2.new(1, -16, 1, -12), 3)

	-- == PROPERTIES content ===================================================
	local pbody = Instance.new("Frame")
	pbody.Name = "Body"
	pbody.BackgroundTransparency = 1
	pbody.Position = UDim2.fromOffset(12, 6)
	pbody.Size = UDim2.new(1, -24, 1, -12)
	pbody.Parent = propsWin.Content

	label(pbody, "Name", UDim2.new(1, 0, 0, 14), UDim2.fromOffset(0, 0), Theme.Font.Label, Theme.TextSize.XS, Theme.Color.TextSecondary)
	local nameLabel = label(pbody, "-", UDim2.new(1, 0, 0, 18), UDim2.fromOffset(0, 16), Theme.Font.Header, Theme.TextSize.SM, Theme.Color.TextPrimary)
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd

	local dimLabel = label(pbody, "Size (studs)", UDim2.new(1, 0, 0, 14), UDim2.fromOffset(0, 44), Theme.Font.Label, Theme.TextSize.XS, Theme.Color.TextSecondary)
	local sizeRow = Instance.new("Frame")
	sizeRow.Name = "SizeRow"
	sizeRow.BackgroundTransparency = 1
	sizeRow.Position = UDim2.fromOffset(0, 62)
	sizeRow.Size = UDim2.new(1, 0, 0, 26)
	sizeRow.Parent = pbody
	local sizeBoxes: { TextBox } = {}
	for i = 1, 3 do
		local tbx = textBox(sizeRow, "S" .. i, "0")
		tbx.Size = UDim2.new(1 / 3, -4, 1, 0)
		tbx.Position = UDim2.new((i - 1) / 3, if i == 1 then 0 else 2, 0, 0)
		tbx.FocusLost:Connect(function() deps.onCommitSize() end)
		sizeBoxes[i] = tbx
	end
	local scaleBox = textBox(pbody, "Scale", "1")
	scaleBox.Size = UDim2.new(1, 0, 0, 26)
	scaleBox.Position = UDim2.fromOffset(0, 62)
	scaleBox.Visible = false
	scaleBox.FocusLost:Connect(function() deps.onCommitScale() end)

	label(pbody, "Rotate (Y\u{00B0})", UDim2.new(1, 0, 0, 14), UDim2.fromOffset(0, 96), Theme.Font.Label, Theme.TextSize.XS, Theme.Color.TextSecondary)
	local rotBox = textBox(pbody, "Rot", "0")
	rotBox.Size = UDim2.new(1, 0, 0, 26)
	rotBox.Position = UDim2.fromOffset(0, 114)
	rotBox.FocusLost:Connect(function() deps.onCommitRot() end)

	label(pbody, "Material", UDim2.new(1, 0, 0, 14), UDim2.fromOffset(0, 148), Theme.Font.Label, Theme.TextSize.XS, Theme.Color.TextSecondary)
	local matBtn = Button.new({ text = "Material: Plastic", name = "MatBtn", parent = pbody, size = UDim2.new(1, 0, 0, 28), onClick = deps.onMaterialCycle })
	matBtn.Instance.Position = UDim2.fromOffset(0, 166)

	label(pbody, "Color", UDim2.new(1, 0, 0, 14), UDim2.fromOffset(0, 202), Theme.Font.Label, Theme.TextSize.XS, Theme.Color.TextSecondary)
	local swRow = Instance.new("Frame")
	swRow.Name = "Swatches"
	swRow.BackgroundTransparency = 1
	swRow.Position = UDim2.fromOffset(0, 220)
	swRow.Size = UDim2.new(1, 0, 0, 22)
	swRow.Parent = pbody
	local swLayout = Instance.new("UIListLayout")
	swLayout.FillDirection = Enum.FillDirection.Horizontal
	swLayout.Padding = UDim.new(0, 5)
	swLayout.Parent = swRow
	for _, col in SWATCHES do
		local c = col
		local sw = Instance.new("TextButton")
		sw.Size = UDim2.fromOffset(22, 22)
		sw.Text = ""
		sw.BackgroundColor3 = c
		sw.BorderSizePixel = 0
		sw.AutoButtonColor = true
		sw.Parent = swRow
		local swc = Instance.new("UICorner"); swc.CornerRadius = UDim.new(0, 4); swc.Parent = sw
		sw.Activated:Connect(function() deps.onSwatch(c) end)
	end

	-- Sound: paste an asset id to attach a looped sound to the selected shape.
	local soundRow = Instance.new("Frame")
	soundRow.Name = "SoundRow"
	soundRow.BackgroundTransparency = 1
	soundRow.Position = UDim2.fromOffset(0, 250)
	soundRow.Size = UDim2.new(1, 0, 0, 44)
	soundRow.Parent = pbody
	label(soundRow, "Sound ID (loops)", UDim2.new(1, 0, 0, 14), UDim2.fromOffset(0, 0), Theme.Font.Label, Theme.TextSize.XS, Theme.Color.TextSecondary)
	local soundBox = textBox(soundRow, "Sound", "Paste sound id (blank = none)")
	soundBox.Size = UDim2.new(1, 0, 0, 26)
	soundBox.Position = UDim2.fromOffset(0, 18)
	soundBox.FocusLost:Connect(function() deps.onCommitSound() end)

	-- empty state overlay: covers the fields when nothing editable is selected
	local empty = Instance.new("Frame")
	empty.Name = "Empty"
	empty.Position = UDim2.fromOffset(0, 0)
	empty.Size = UDim2.fromScale(1, 1)
	empty.BackgroundColor3 = Theme.Color.BgRaised
	empty.BorderSizePixel = 0
	empty.ZIndex = 5
	empty.Parent = propsWin.Content
	local el = label(empty, "No object selected", UDim2.new(1, 0, 0, 18), UDim2.fromOffset(0, 24), Theme.Font.Label, Theme.TextSize.SM, Theme.Color.TextSecondary)
	el.TextXAlignment = Enum.TextXAlignment.Center
	el.ZIndex = 5

	-- == Toast ================================================================
	local toast = Instance.new("TextLabel")
	toast.Name = "Toast"
	toast.AnchorPoint = Vector2.new(0.5, 1)
	toast.Position = UDim2.new(0.5, 0, 1, -14)
	toast.Size = UDim2.fromOffset(340, 34)
	toast.BackgroundColor3 = Theme.Color.BgPress
	toast.BackgroundTransparency = 0.1
	toast.FontFace = Theme.Font.Header
	toast.Text = ""
	toast.TextSize = Theme.TextSize.SM
	toast.TextColor3 = Theme.Color.TextPrimary
	toast.Visible = false
	toast.ZIndex = 56
	toast.Parent = gui
	local tc = Instance.new("UICorner"); tc.CornerRadius = UDim.new(0, Theme.Radius.MD); tc.Parent = toast

	return {
		gui = gui,
		toast = toast,
		meterFill = meterFill,
		meterText = meterText,
		modeButtons = modeButtons,
		dupBtn = dupBtn,
		delBtn = delBtn,
		snapBtn = snapBtn,
		explorerBtn = explorerBtn,
		customizeBtn = customizeBtn,
		props = {
			panel = propsWin.Frame,
			nameLabel = nameLabel,
			dimLabel = dimLabel,
			sizeRow = sizeRow,
			sizeBoxes = sizeBoxes,
			scaleBox = scaleBox,
			rotBox = rotBox,
			matBtn = matBtn,
			soundRow = soundRow,
			soundBox = soundBox,
			empty = empty,
		},
		explorer = { panel = explorerWin.Frame, list = exList },
		browser = { panel = toolboxWin.Frame, search = search, cats = cats, grid = grid, count = count },
		snap = { pop = pop, rows = snapRows, spaceBtn = spaceBtn },
		host = host,
		windows = { toolbox = toolboxWin, explorer = explorerWin, props = propsWin },
	}
end

return EditorView
