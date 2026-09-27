--!strict
-- @deprecated: use Controllers.BuildRail instead.
-- UNUSED as of 2026-09-17 -- nothing requires or syncs this module any more.
--
-- It was a column of labelled rows floating on the left edge, which put every setting two
-- surfaces away from the cards it applied to; and its title said "Nature" long after the
-- shelf had split into Nature and Build. BuildRail is the same settings as a second group of
-- buttons on the dock's OWN rail, each opening its own flyout: next to the thing it governs,
-- and costing no screen until it is pressed. It also lost the custom-step boxes with the
-- Custom preset -- see EditorGizmos.PRESETS.
--
-- PreciseBuildPanel
-- The settings surface for Precise build mode: everything the transform gizmo can be told,
-- in one place, on the left edge so it never fights the build dock.
--
-- It owns no state. Snapping, space and pivot live in EditorGizmos; colour, material and
-- collision live in NaturePlacementController (which applies them to the NEXT placement AND
-- to whatever is under the handles). This module is a view: sync() reads those back and
-- redraws, and every control calls a setter and lets sync() run again.
--
-- Visibility follows Precise mode itself -- TerrainPanelController calls sync() from its own
-- refresh, so the panel appears and disappears with the chip that turns the mode on.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local uiFolder = script.Parent.Parent:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local kit = uiFolder:WaitForChild("Kit")
local Button = require(kit:WaitForChild("Button"))
local Toggle = require(kit:WaitForChild("Toggle"))
local Dropdown = require(kit:WaitForChild("Dropdown"))

local EditorGizmos = require(script.Parent:WaitForChild("EditorGizmos"))
local NatureGizmo = require(script.Parent:WaitForChild("NatureGizmo"))
local Nature = require(script.Parent:WaitForChild("NaturePlacementController"))
local ColorPanel = require(script.Parent:WaitForChild("ColorPanel"))
local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))
local MaterialCatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MaterialCatalog"))

local PreciseBuildPanel = {}

local WIDTH = 254
local ROW_H = 28
local SV_SIZE = 150
local HUE_H = 14

local _gui: ScreenGui? = nil
local _root: Frame? = nil
local _built = false
-- Every control that has to be redrawn from state. Populated during build, read by sync.
local _snapDrop: { [string]: Dropdown.Dropdown } = {}
local _customBox: { [string]: TextBox } = {}
-- The row captions carry the ACTIVE step ("Move  1 m"), which is the number that was
-- missing: the box beside them holds the CUSTOM step and reads as the live one otherwise.
local _snapCap: { [string]: TextLabel? } = {}
local _spaceBtn: { [string]: Button.Button } = {}
local _vertToggle: Toggle.Toggle? = nil
local _collideToggle: Toggle.Toggle? = nil
local _pivotBtn: Button.Button? = nil
local _matDrop: Dropdown.Dropdown? = nil
local _swatch: Frame? = nil
local _placeBtn: Button.Button? = nil
-- Space and Pivot are HANDLE concepts and hide with the handles. Snapping does not: the
-- same steps govern the drag, the right-drag turn and the height keys when precise is off.
local _gizmoOnly: { GuiObject } = {}
-- PLACE only means something while there is a master to stamp.
local _editOnly: { GuiObject } = {}
local _title: TextLabel? = nil
-- EXIT hides the panel; it does not turn precise off. Asking for precise, or placing
-- something to edit, is asking for the panel back -- tracked here rather than pushed in,
-- because the controller this reads from must not have to know the panel exists.
local _dismissed = false
local _lastPrecise = false
local _lastEditing = false
local _caption: TextLabel? = nil


-- == Small builders ===========================================================
local function corner(inst: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = inst
end

local function heading(parent: Instance, text: string, order: number): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, 0, 0, 16)
	l.LayoutOrder = order
	l.Text = string.upper(text)
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextColor3 = Theme.Color.Brand
	l.TextSize = Theme.TextSize.XS
	l.FontFace = Theme.Font.Bold
	l.Parent = parent
	return l
end

-- A labelled row: caption on the left, control on the right. Everything in this panel is
-- one of these, so the label column lines up down the whole thing without a grid layout.
local function row(parent: Instance, text: string, order: number): (Frame, TextLabel?)
	local f = Instance.new("Frame")
	f.BackgroundTransparency = 1
	f.Size = UDim2.new(1, 0, 0, ROW_H)
	f.LayoutOrder = order
	f.Parent = parent
	if text == "" then return f, nil end
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(0, 72, 1, 0)
	l.Text = text
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextColor3 = Theme.Color.TextSecondary
	l.TextSize = Theme.TextSize.XS
	l.FontFace = Theme.Font.Label
	l.Parent = f
	return f, l
end

-- == Build ====================================================================
local function buildSnapRow(parent: Instance, channel: string, label: string, order: number)
	local f, cap = row(parent, label, order)
	-- Wider than a normal row's caption: it carries the ACTIVE step, not just the name.
	if cap then cap.Size = UDim2.new(0, 94, 1, 0) end
	_snapCap[channel] = cap
	local options: { Dropdown.Option } = {}
	for _, p in EditorGizmos.PRESETS do
		table.insert(options, { label = p.label, value = p.key })
	end
	local drop = Dropdown.new({
		parent = f,
		options = options,
		value = EditorGizmos.getSnapPreset(channel :: any),
		width = 80,
		onChange = function(value: any)
			EditorGizmos.setSnapPreset(channel :: any, value)
			PreciseBuildPanel.sync()
		end,
	})
	-- Wider caption column: it carries the ACTIVE step now, not just the channel name.
	drop.Instance.Position = UDim2.new(0, 96, 0.5, 0)
	drop.Instance.AnchorPoint = Vector2.new(0, 0.5)
	_snapDrop[channel] = drop

	local box = Instance.new("TextBox")
	box.Size = UDim2.fromOffset(42, 24)
	box.AnchorPoint = Vector2.new(1, 0.5)
	box.Position = UDim2.new(1, 0, 0.5, 0)
	box.BackgroundColor3 = Theme.Color.BgRaised
	box.TextColor3 = Theme.Color.TextPrimary
	box.TextSize = Theme.TextSize.XS
	box.FontFace = Theme.Font.Label
	box.BorderSizePixel = 0
	box.ClearTextOnFocus = false
	box.Parent = f
	corner(box, Theme.Radius.SM)
	-- METRES for move and size, degrees for rotate. The gizmo stores studs, and the world is
	-- two studs to the metre -- typing "1" here and getting half a metre is exactly why the
	-- grid read as broken.
	box.FocusLost:Connect(function()
		local v = tonumber(box.Text)
		if v and v > 0 then
			EditorGizmos.setCustomStep(channel :: any,
				if channel == "rotate" then v else EditorGizmos.toStuds(v))
		end
		PreciseBuildPanel.sync()
	end)
	_customBox[channel] = box
end

local function buildSpaceRow(parent: Instance, order: number)
	local f = row(parent, "Space", order) :: Frame
	table.insert(_gizmoOnly, f)
	local x = 72
	for _, key in { "Relative", "Global" } do
		local b = Button.new({
			text = key,
			parent = f,
			compact = true,
			size = UDim2.fromOffset(72, 24),
			onClick = function()
				EditorGizmos.setSpace(key)
				PreciseBuildPanel.sync()
			end,
		})
		b.Instance.AnchorPoint = Vector2.new(0, 0.5)
		b.Instance.Position = UDim2.new(0, x, 0.5, 0)
		_spaceBtn[key] = b
		x += 76
	end
end

local function buildPivotRow(parent: Instance, order: number)
	local f = row(parent, "Pivot", order) :: Frame
	table.insert(_gizmoOnly, f)
	local move = Button.new({
		text = "Move",
		parent = f,
		compact = true,
		size = UDim2.fromOffset(50, 24),
		onClick = function()
			EditorGizmos.setPivotMode(not EditorGizmos.isPivotMode())
			PreciseBuildPanel.sync()
		end,
	})
	move.Instance.AnchorPoint = Vector2.new(0, 0.5)
	move.Instance.Position = UDim2.new(0, 72, 0.5, 0)
	_pivotBtn = move

	local reset = Button.new({
		text = "Reset",
		parent = f,
		compact = true,
		size = UDim2.fromOffset(50, 24),
		onClick = function()
			EditorGizmos.resetPivot()
			EditorGizmos.setPivotMode(false)
			PreciseBuildPanel.sync()
		end,
	})
	reset.Instance.AnchorPoint = Vector2.new(0, 0.5)
	reset.Instance.Position = UDim2.new(0, 126, 0.5, 0)

	-- Align drops the pivot to the BASE of the selection, which is the one that matters in
	-- a city builder: turn a thing about its footprint and it stays on the ground.
	local align = Button.new({
		text = "Base",
		parent = f,
		compact = true,
		size = UDim2.fromOffset(50, 24),
		onClick = function()
			EditorGizmos.alignPivot()
			EditorGizmos.setPivotMode(false)
			PreciseBuildPanel.sync()
		end,
	})
	align.Instance.AnchorPoint = Vector2.new(0, 0.5)
	align.Instance.Position = UDim2.new(0, 180, 0.5, 0)
end

local function build()
	if _built then return end
	local gui = Instance.new("ScreenGui")
	gui.Name = "PreciseBuildPanel"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	-- Tool band: a panel flanking the HUD, under every overlay and toast.
	gui.DisplayOrder = Theme.Layer.Tool
	gui.Enabled = false
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	_gui = gui
	_built = true

	local rootFrame = Instance.new("Frame")
	rootFrame.Name = "Root"
	rootFrame.AnchorPoint = Vector2.new(0, 0.5)
	rootFrame.Position = UDim2.new(0, 16, 0.5, 0)
	rootFrame.Size = UDim2.fromOffset(WIDTH, 0)
	rootFrame.AutomaticSize = Enum.AutomaticSize.Y
	rootFrame.BackgroundColor3 = Theme.Color.Bg
	rootFrame.BackgroundTransparency = 0.08
	rootFrame.BorderSizePixel = 0
	rootFrame.Parent = gui
	corner(rootFrame, Theme.Radius.Panel)
	_root = rootFrame

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, Theme.Pad.LG)
	pad.PaddingBottom = UDim.new(0, Theme.Pad.LG)
	pad.PaddingLeft = UDim.new(0, Theme.Pad.LG)
	pad.PaddingRight = UDim.new(0, Theme.Pad.LG)
	pad.Parent = rootFrame

	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, Theme.Pad.SM)
	list.Parent = rootFrame

	-- title + exit
	local head = row(rootFrame, "", 1) :: Frame
	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -60, 1, 0)
	title.Text = "Precise Build"
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Theme.Color.TextPrimary
	title.TextSize = Theme.TextSize.MD
	title.FontFace = Theme.Font.Header
	title.Parent = head
	_title = title

	local exit = Button.new({
		text = "Exit",
		parent = head,
		compact = true,
		size = UDim2.fromOffset(54, 24),
		-- Hides the panel, nothing more. These are the TOOL's settings, so closing them must
		-- not also change how the tool behaves -- turning precise off is the dock's chip.
		onClick = function()
			_dismissed = true
			PreciseBuildPanel.sync()
		end,
	})
	exit.Instance.AnchorPoint = Vector2.new(1, 0.5)
	exit.Instance.Position = UDim2.new(1, 0, 0.5, 0)

	local cap = Instance.new("TextLabel")
	cap.BackgroundTransparency = 1
	cap.Size = UDim2.new(1, 0, 0, 26)
	cap.LayoutOrder = 2
	cap.Text = ""
	cap.TextWrapped = true
	cap.TextXAlignment = Enum.TextXAlignment.Left
	cap.TextYAlignment = Enum.TextYAlignment.Top
	cap.TextColor3 = Theme.Color.TextSecondary
	cap.TextSize = Theme.TextSize.XS
	cap.FontFace = Theme.Font.Label
	cap.Parent = rootFrame
	_caption = cap

	heading(rootFrame, "Snapping", 10)
	buildSnapRow(rootFrame, "move", "Move", 11)
	buildSnapRow(rootFrame, "rotate", "Rotate", 12)
	buildSnapRow(rootFrame, "size", "Size", 13)

	local vert = row(rootFrame, "Vertical grid", 14) :: Frame
	_vertToggle = Toggle.new({
		parent = vert,
		value = EditorGizmos.isVerticalSnap(),
		onChange = function(on: boolean)
			EditorGizmos.setVerticalSnap(on)
			PreciseBuildPanel.sync()
		end,
	})
	;(_vertToggle :: Toggle.Toggle).Instance.AnchorPoint = Vector2.new(1, 0.5)
	;(_vertToggle :: Toggle.Toggle).Instance.Position = UDim2.new(1, 0, 0.5, 0)

	table.insert(_gizmoOnly, heading(rootFrame, "Transform", 20))
	buildSpaceRow(rootFrame, 21)
	buildPivotRow(rootFrame, 22)

	heading(rootFrame, "Look", 30)
	local matRow = row(rootFrame, "Material", 31) :: Frame
	local matOptions: { Dropdown.Option } = { { label = "Default", value = 0 } }
	for i, name in MaterialCatalog.order do
		table.insert(matOptions, { label = name, value = i })
	end
	_matDrop = Dropdown.new({
		parent = matRow,
		options = matOptions,
		value = Nature.getPlaceMaterial(),
		width = 148,
		onChange = function(value: any)
			Nature.setPlaceMaterial(value)
			PreciseBuildPanel.sync()
		end,
	})
	;(_matDrop :: Dropdown.Dropdown).Instance.AnchorPoint = Vector2.new(1, 0.5)
	;(_matDrop :: Dropdown.Dropdown).Instance.Position = UDim2.new(1, 0, 0.5, 0)

	-- Colour is a SWATCH that opens the colour menu, not a picker embedded here. The menu
	-- is the first thing a player wants and should not cost a trip through these settings;
	-- and a second copy of a picker is a second thing to keep in step.
	local colRow = row(rootFrame, "Colour", 32) :: Frame
	local swBtn = Instance.new("TextButton")
	swBtn.Size = UDim2.fromOffset(28, 26)
	swBtn.AnchorPoint = Vector2.new(0, 0.5)
	swBtn.Position = UDim2.new(0, 72, 0.5, 0)
	swBtn.BackgroundTransparency = 1
	swBtn.Text = ""
	swBtn.Parent = colRow
	local sw = Instance.new("Frame")
	sw.Size = UDim2.fromOffset(24, 24)
	sw.Position = UDim2.fromOffset(2, 1)
	sw.BackgroundColor3 = ColorPanel.current()
	sw.BorderSizePixel = 0
	sw.Parent = swBtn
	local swc = Instance.new("UICorner")
	swc.CornerRadius = UDim.new(1, 0)
	swc.Parent = sw
	local sws = Instance.new("UIStroke")
	sws.Color = Theme.Color.StrokeSoft
	sws.Thickness = Theme.StrokeWidth.Thin
	sws.Parent = sw
	_swatch = sw
	swBtn.Activated:Connect(function()
		ColorPanel.toggle(function(c: Color3)
			Nature.setPlaceColor(c)
			PreciseBuildPanel.sync()
		end)
	end)

	local openBtn = Button.new({
		text = "Palette",
		parent = colRow,
		compact = true,
		size = UDim2.fromOffset(62, 24),
		onClick = function()
			ColorPanel.open(function(c: Color3)
				Nature.setPlaceColor(c)
				PreciseBuildPanel.sync()
			end)
		end,
	})
	openBtn.Instance.AnchorPoint = Vector2.new(0, 0.5)
	openBtn.Instance.Position = UDim2.new(0, 106, 0.5, 0)

	-- "Keep" is the only way back to a template's own colours: nothing else remembers what
	-- they were once a prop has been repainted.
	local keep = Button.new({
		text = "Keep",
		parent = colRow,
		compact = true,
		size = UDim2.fromOffset(44, 24),
		onClick = function()
			Nature.setPlaceColor(nil)
			PreciseBuildPanel.sync()
		end,
	})
	keep.Instance.AnchorPoint = Vector2.new(1, 0.5)
	keep.Instance.Position = UDim2.new(1, 0, 0.5, 0)


	local colRow2 = row(rootFrame, "Collisions", 34) :: Frame
	_collideToggle = Toggle.new({
		parent = colRow2,
		value = Nature.getPlaceCollide(),
		onChange = function(on: boolean)
			Nature.setPlaceCollide(on)
			PreciseBuildPanel.sync()
		end,
	})
	;(_collideToggle :: Toggle.Toggle).Instance.AnchorPoint = Vector2.new(1, 0.5)
	;(_collideToggle :: Toggle.Toggle).Instance.Position = UDim2.new(1, 0, 0.5, 0)

	-- PLACE is a STAMP: it drops a solid copy of the master and leaves the master under the
	-- handles. There is no Duplicate button because that is what placing already does.
	local placeRow = row(rootFrame, "", 40) :: Frame
	table.insert(_editOnly, placeRow)
	local place = Button.new({
		text = "PLACE  " .. Settings.bindLabel(Settings.getBind("PlaceObject")),
		parent = placeRow,
		compact = true,
		size = UDim2.new(1, 0, 0, 26),
		onClick = function()
			Nature.commitPrecise()
			PreciseBuildPanel.sync()
		end,
	})
	place.Instance.AnchorPoint = Vector2.new(0, 0.5)
	place.Instance.Position = UDim2.new(0, 0, 0.5, 0)
	_placeBtn = place


	NatureGizmo.setChangedListener(function() PreciseBuildPanel.sync() end)
end

-- == Sync =====================================================================
function PreciseBuildPanel.sync()
	-- Shown whenever there is something to EDIT, not only in precise mode: colour, material,
	-- collisions and PLACE are the tool, and precise only adds the handles and their two
	-- settings. A player without precise on still needs somewhere to press Place.
	local precise = Nature.isPrecise()
	local editing = NatureGizmo.current() ~= nil
	-- Turning precise on, or placing something to edit, un-hides a dismissed panel: both are
	-- the player asking for exactly what is on it.
	if (precise and not _lastPrecise) or (editing and not _lastEditing) then _dismissed = false end
	_lastPrecise, _lastEditing = precise, editing
	-- Visible while the Nature tool is live. Snapping, material, colour and collisions are
	-- the TOOL's settings and were never precise-only; precise adds the handles and the two
	-- settings that mean nothing without them.
	local on = Nature.isEnabled() and not _dismissed
	if not on and not _built then return end -- never build a panel nobody has asked for
	build()
	local gui = _gui
	if not gui then return end
	gui.Enabled = on
	if not on then return end
	for _, obj in _gizmoOnly do obj.Visible = precise end
	for _, obj in _editOnly do obj.Visible = editing end
	if _title then (_title :: TextLabel).Text = if precise then "Precise Build" else "Nature" end

	for _, channel in EditorGizmos.CHANNELS do
		local drop = _snapDrop[channel]
		if drop then drop:Set(EditorGizmos.getSnapPreset(channel)) end
		local box = _customBox[channel]
		if box and not box:IsFocused() then
			local custom = EditorGizmos.getCustomStep(channel)
			box.Text = string.format("%g", if channel == "rotate" then custom else EditorGizmos.toMetres(custom))
		end
		local cap = _snapCap[channel]
		if cap then
			local name = string.upper(string.sub(channel, 1, 1)) .. string.sub(channel, 2)
			cap.Text = name .. "  " .. EditorGizmos.stepLabel(channel)
		end
	end
	local space = EditorGizmos.getSpace()
	for key, btn in _spaceBtn do btn:SetSelected(key == space) end
	if _vertToggle then (_vertToggle :: Toggle.Toggle):Set(EditorGizmos.isVerticalSnap()) end
	if _pivotBtn then (_pivotBtn :: Button.Button):SetSelected(EditorGizmos.isPivotMode()) end
	if _matDrop then (_matDrop :: Dropdown.Dropdown):Set(Nature.getPlaceMaterial()) end
	if _collideToggle then (_collideToggle :: Toggle.Toggle):Set(Nature.getPlaceCollide()) end

	if _swatch then
		local picked = Nature.getPlaceColor()
		;(_swatch :: Frame).BackgroundColor3 = picked or ColorPanel.current()
		-- Dimmed, not hidden, while "Keep" is on: it still says what it WOULD paint.
		;(_swatch :: Frame).BackgroundTransparency = if picked then 0 else 0.55
	end
	if _placeBtn then
		(_placeBtn :: Button.Button):SetEnabled(NatureGizmo.current() ~= nil)
	end

	if _caption then
		(_caption :: TextLabel).Text = if editing
			then "PLACE stamps a copy and keeps this one, so move it and place again."
			elseif precise
			then "Click the ground: the handles land on what you put down."
			else "Click to plant. Turn on Precise for handles to place things exactly."
	end
end

function PreciseBuildPanel.Bind()
	PreciseBuildPanel.sync()
end

return PreciseBuildPanel