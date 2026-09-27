--!strict
-- SETTINGS -- "Control Room": the full-screen options page. A numbered section
-- rail on the left, numbered groups of rows on the right, one accent red
-- marking everything active. Rows write to the shared Core.Settings store so
-- the game updates live, but the player's PROFILE is only written on APPLY --
-- Core.SettingsClient is held for as long as this page is open.
-- Opened from the main menu SETTINGS button, the pause menu, and the player hub.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")

local UIEvents = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("UIEvents"))
local CityRoles = require(ReplicatedStorage:WaitForChild("Access"):WaitForChild("CityRoles"))

local Theme = require(script.Parent:WaitForChild("Theme"))
local UITween = require(script.Parent:WaitForChild("UITween"))
local HudScale = require(script.Parent:WaitForChild("HudScale"))
local Locale = require(script.Parent:WaitForChild("Locale"))
local Glass = require(script.Parent:WaitForChild("Kit"):WaitForChild("Glass"))
local MenuScreenView = require(script.Parent.Parent:WaitForChild("UICreation"):WaitForChild("MenuScreenView"))
local coreFolder = script.Parent.Parent:WaitForChild("Core")
local Settings = require(coreFolder:WaitForChild("Settings"))
local SettingsClient = require(coreFolder:WaitForChild("SettingsClient"))
local SoundFX = require(coreFolder:WaitForChild("SoundFX"))

local SettingsPanel = {}

-- ------------------------------------------------------------ look --

-- Page-local palette. Still page-local -- the row widgets here are denser than
-- anything on the HUD and want their own surface values -- but no longer its own
-- ROOM: the accent now tracks Theme so the Control Room, the HUD and the menu
-- read as one product. Greens/greys are the design's cool-green glass.
local C = table.freeze({
	Veil        = Color3.fromRGB(10, 14, 11),
	Panel       = Color3.fromRGB(24, 30, 26),
	PanelEdge   = Color3.fromRGB(30, 38, 32),
	Raised      = Color3.fromRGB(16, 20, 17),
	RaisedHover = Color3.fromRGB(40, 48, 42),
	Line        = Color3.fromRGB(86, 92, 84),
	LineSoft    = Color3.fromRGB(52, 58, 52),
	Accent      = Theme.Color.Accent,
	AccentHover = Theme.Color.AccentHover,
	AccentPress = Theme.Color.AccentPress,
	AccentWash  = Color3.fromRGB(60, 32, 18),
	Text        = Color3.fromRGB(245, 242, 238),
	TextDim     = Color3.fromRGB(168, 166, 158),
	TextFaint   = Color3.fromRGB(120, 120, 114),
	Knob        = Color3.fromRGB(246, 246, 246),
	TrackOff    = Color3.fromRGB(70, 76, 68),
})

-- Montserrat has no arrows or geometric marks: they all fall back to the same
-- substitute glyph and render as tofu. Every non-Latin mark on this page is set
-- in a font that actually carries them.
local GLYPH_FONT = Font.new("rbxasset://fonts/families/Arial.json", Enum.FontWeight.Bold)

-- The toggle reads its state from the colour of its dot, so the two live
-- outside C: they are semantic, not surface values.
local DOT_ON = Color3.fromRGB(78, 201, 106)
local DOT_OFF = Color3.fromRGB(240, 98, 90)

local GLASS_EDGE = Color3.fromRGB(255, 255, 255)
local GLASS_EDGE_T = 0.9
local CARD_RADIUS = 14

-- The menu backdrop is a 2D image, which the camera BlurEffect cannot touch, so
-- the veil is the only thing that smooths it behind the cards.
local VEIL_TRANSPARENCY = 0.12
local BLUR_SIZE = 28

local SIDEBAR_W = 268
local HEADER_H = 46
local FOOTER_H = 74
local GUTTER = 22
local PAD_X = 56
-- The GUI ignores the inset so the veil covers the whole screen, which means
-- the page has to clear the Roblox topbar itself.
local PAD_TOP = 52
local CONTENT_PAD = 24
local ROW_H = 57
-- Controls sit in a fixed-width column at the right of the row and are aligned
-- to its LEFT edge, so a narrow dropdown and a wide preset bar start together.
local CTRL_W = 384
local DROPDOWN_W = 236
local MENU_ITEM_H = 34
local TOGGLE_W = 76
local TOGGLE_H = 30

local SECTIONS = table.freeze({ "GRAPHICS", "GAMEPLAY", "ACCESS", "AUDIO", "INTERFACE", "INPUT" })

local MAIN_MENU_GUI = "MainMenu"
local MAIN_MENU_BUTTONS = "Container"
local MAIN_MENU_BACKDROP = "MainMenuParallaxBackground"
local BACKDROP_DIM = Color3.fromRGB(62, 58, 58)

-- Right-hand modifiers are the same logical key as their left twin, matching
-- what Core.Settings does with the binds it stores.
local MODIFIER_FOLD: { [Enum.KeyCode]: Enum.KeyCode } = table.freeze({
	[Enum.KeyCode.RightControl] = Enum.KeyCode.LeftControl,
	[Enum.KeyCode.RightShift] = Enum.KeyCode.LeftShift,
	[Enum.KeyCode.RightAlt] = Enum.KeyCode.LeftAlt,
})

export type Control = {
	render: () -> (),
	nudge: (number) -> (),
	focus: (boolean) -> (),
}

-- readOnly marks an entry that is a readout, not a choice: "Custom" on the
-- quality preset row shows that the values no longer match any preset.
type Option = { label: string, value: any, readOnly: boolean? }

type PageCtx = {
	frame: ScrollingFrame,
	order: number,
	groupIndex: number,
	rowInGroup: number,
}

-- ------------------------------------------------------------ helpers --

local THIN = utf8.char(0x2009)

-- Roblox has no letter-spacing property, so tracked caps are spelled out with
-- thin spaces between the glyphs.
local function tracked(s: string): string
	local out: { string } = {}
	for _, code in utf8.codes(s) do
		table.insert(out, utf8.char(code))
	end
	return table.concat(out, THIN)
end

local function corner(inst: GuiObject, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = inst
end

local function stroke(inst: GuiObject, color: Color3, transparency: number): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Transparency = transparency
	s.Thickness = 1
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = inst
	return s
end

local function pad(inst: GuiObject, top: number, right: number, bottom: number, left: number)
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, top)
	p.PaddingRight = UDim.new(0, right)
	p.PaddingBottom = UDim.new(0, bottom)
	p.PaddingLeft = UDim.new(0, left)
	p.Parent = inst
end

local function text(parent: GuiObject, content: string, size: number, color: Color3, font: Font): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.BorderSizePixel = 0
	l.Text = content
	l.TextSize = size
	l.TextColor3 = color
	l.FontFace = font
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Center
	l.TextTruncate = Enum.TextTruncate.AtEnd
	l.Parent = parent
	return l
end

local function hairline(parent: GuiObject, color: Color3): Frame
	local line = Instance.new("Frame")
	line.Name = "Rule"
	line.BackgroundColor3 = color
	line.BorderSizePixel = 0
	line.Size = UDim2.new(1, 0, 0, 1)
	line.Parent = parent
	return line
end

-- ------------------------------------------------------------ state --

local _built = false
local _open = false
local _gui: ScreenGui? = nil
local _scrim: TextButton? = nil
local _page: CanvasGroup? = nil
local _blur: BlurEffect? = nil
local _hidden: { ScreenGui } = {}
local _hiddenMenu: GuiObject? = nil
local _dimmedBackdrop: ImageLabel? = nil

local _sectionIndex = 1
-- ACCESS is the one section that does not always exist: roles are given to a CITY, so with
-- none standing the whole page has nothing to talk about and comes OFF the rail rather than
-- sitting there refusing every row. Assigned in build(); the server decides -- see
-- refreshAccess.
local _accessAvailable = false
local setAccessVisible: (boolean) -> () = function() end
local _pages: { [string]: ScrollingFrame } = {}
local _tabs: { [string]: { frame: TextButton, bar: Frame, name: TextLabel, num: TextLabel } } = {}
local _eyebrow: TextLabel? = nil
local _unsavedChip: Frame? = nil
local _statusLabel: TextLabel? = nil
local _setApplyEnabled: ((boolean) -> ())? = nil
local _menuLayer: Frame? = nil

-- The profile as it stood when the page opened. APPLY re-snapshots it; REVERT
-- restores it. Everything between the two is live but unsaved.
local _saved: { [string]: any } = {}
local _savedBinds: { [string]: Settings.Bind } = {}
local _dirty = false

local _focus: Control? = nil
local _drag: ((number) -> ())? = nil
local _closeMenu: (() -> ())? = nil
local _capturing: string? = nil
local _captureStop: (() -> ())? = nil
local _bindRenders: { [string]: () -> () } = {}

local PRESET_KEYS = Settings.presetKeys()

-- Settings.defaults() and bindDefaults() hand back a fresh clone each call, and
-- the pending check runs on every change -- including every frame of a slider
-- drag. The key lists never change, so they are read once.
local VALUE_KEYS: { string } = {}
for key in Settings.defaults() do
	table.insert(VALUE_KEYS, key)
end
local BIND_ACTIONS: { string } = {}
for _, def in Settings.actions() do
	table.insert(BIND_ACTIONS, def.id)
end

-- ------------------------------------------------------------ pending --

local function snapshot()
	table.clear(_saved)
	table.clear(_savedBinds)
	for _, key in VALUE_KEYS do
		_saved[key] = Settings.get(key)
	end
	for _, action in BIND_ACTIONS do
		_savedBinds[action] = Settings.getBind(action)
	end
end

local function computeDirty(): boolean
	for _, key in VALUE_KEYS do
		if _saved[key] ~= Settings.get(key) then
			return true
		end
	end
	for _, action in BIND_ACTIONS do
		if not Settings.bindsEqual(_savedBinds[action], Settings.getBind(action)) then
			return true
		end
	end
	return false
end

local function refreshDirty()
	_dirty = computeDirty()
	if _unsavedChip then
		(_unsavedChip :: Frame).Visible = _dirty
	end
	if _statusLabel then
		local l = _statusLabel :: TextLabel
		l.Text = tracked(if _dirty
			then "CHANGES PENDING \u{2014} APPLY TO WRITE THEM TO YOUR PROFILE"
			else "ALL SETTINGS MATCH YOUR SAVED PROFILE")
		l.TextColor3 = if _dirty then C.Text else C.TextFaint
	end
	if _setApplyEnabled then
		(_setApplyEnabled :: (boolean) -> ())(_dirty)
	end
end

-- A hand edit to anything a quality preset owns drops the preset to Custom.
local function writeValue(key: string, value: any)
	Settings.set(key, value)
	if PRESET_KEYS[key] then
		Settings.set("graphicsPreset", "Custom")
	end
end

-- ------------------------------------------------------------ controls --

local function toggleControl(mount: Frame, key: string): Control
	local root = Instance.new("Frame")
	root.Name = "Toggle"
	root.BackgroundTransparency = 1
	root.AnchorPoint = Vector2.new(1, 0.5)
	root.Position = UDim2.new(1, 0, 0.5, 0)
	root.Size = UDim2.fromOffset(TOGGLE_W, TOGGLE_H)
	root.Parent = mount
	local ring = stroke(root, C.Accent, 1)

	local track = Instance.new("TextButton")
	track.Name = "Track"
	track.AutoButtonColor = false
	track.Text = ""
	track.BackgroundColor3 = C.Raised
	track.BackgroundTransparency = 0.28
	track.BorderSizePixel = 0
	track.Size = UDim2.fromScale(1, 1)
	track.Parent = root
	corner(track, TOGGLE_H)
	local edge = stroke(track, GLASS_EDGE, 0.88)

	-- The dot leads on ON and trails on OFF, so the eye reads state from which
	-- side it sits as much as from the colour.
	local KNOB = TOGGLE_H - 8
	local INSET = 4 + KNOB / 2

	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.BackgroundColor3 = DOT_ON
	knob.BorderSizePixel = 0
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.new(0, INSET, 0.5, 0)
	knob.Size = UDim2.fromOffset(KNOB, KNOB)
	knob.ZIndex = 2
	knob.Parent = track
	corner(knob, KNOB)

	local state = text(track, "", 11, C.Text, Theme.Font.Bold)
	state.TextXAlignment = Enum.TextXAlignment.Center
	state.Size = UDim2.new(1, -(KNOB + 14), 1, 0)

	local function render()
		local on = Settings.get(key) == true
		knob.BackgroundColor3 = if on then DOT_ON else DOT_OFF
		UITween.to(knob, "Hover", { Position = UDim2.new(if on then 0 else 1, if on then INSET else -INSET, 0.5, 0) })
		state.Text = if on then "On" else "Off"
		state.Position = UDim2.fromOffset(if on then KNOB + 8 else 6, 0)
		edge.Transparency = 0.88
	end

	local function setTo(on: boolean)
		if (Settings.get(key) == true) == on then
			return
		end
		writeValue(key, on)
		SoundFX.play("Click")
	end

	track.Activated:Connect(function()
		setTo(Settings.get(key) ~= true)
	end)
	Settings.onChanged(key, render)
	render()

	return {
		render = render,
		nudge = function(dir: number)
			setTo(dir > 0)
		end,
		focus = function(on: boolean)
			ring.Transparency = if on then 0 else 1
		end,
	}
end

local function segmentControl(mount: Frame, options: { Option }, get: () -> any, set: (any) -> ()): Control
	local root = Instance.new("Frame")
	root.Name = "Segment"
	root.BackgroundTransparency = 1
	root.AnchorPoint = Vector2.new(1, 0.5)
	root.Position = UDim2.new(1, 0, 0.5, 0)
	root.AutomaticSize = Enum.AutomaticSize.X
	root.Size = UDim2.fromOffset(0, 30)
	root.Parent = mount
	local ring = stroke(root, C.Accent, 1)

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.Padding = UDim.new(0, 6)
	list.Parent = root

	local cells: { TextButton } = {}
	for i, opt in options do
		local b = Instance.new("TextButton")
		b.Name = opt.label
		b.AutoButtonColor = false
		b.Text = tracked(string.upper(opt.label))
		b.TextSize = 11
		b.FontFace = Theme.Font.Bold
		b.BackgroundColor3 = C.Raised
		b.BorderSizePixel = 0
		b.AutomaticSize = Enum.AutomaticSize.X
		b.Size = UDim2.fromOffset(0, 30)
		b.LayoutOrder = i
		b.Parent = root
		pad(b, 0, 15, 0, 15)
		corner(b, 8)
		cells[i] = b
	end

	local function render()
		local current = get()
		for i, opt in options do
			local active = opt.value == current
			cells[i].BackgroundColor3 = if active then C.Accent else C.Raised
			cells[i].TextColor3 = if active then C.Knob else C.TextDim
		end
	end

	for i, opt in options do
		local b = cells[i]
		b.Activated:Connect(function()
			-- "Custom" is a readout, not a preset you can pick.
			if opt.value == get() or opt.readOnly then
				return
			end
			SoundFX.play("Click")
			set(opt.value)
		end)
		b.MouseEnter:Connect(function()
			if opt.value ~= get() and not opt.readOnly then
				b.BackgroundColor3 = C.RaisedHover
			end
		end)
		b.MouseLeave:Connect(render)
	end

	render()

	return {
		render = render,
		nudge = function(dir: number)
			local current = get()
			local index = 1
			for i, opt in options do
				if opt.value == current then
					index = i
					break
				end
			end
			-- Step past any readout-only entry rather than landing on it.
			for _ = 1, #options do
				index = ((index - 1 + dir) % #options) + 1
				if not options[index].readOnly then
					break
				end
			end
			if options[index].value ~= current and not options[index].readOnly then
				SoundFX.play("Click")
				set(options[index].value)
			end
		end,
		focus = function(on: boolean)
			ring.Transparency = if on then 0 else 1
		end,
	}
end

local function closeOpenMenu()
	if _closeMenu then
		local fn = _closeMenu
		_closeMenu = nil
		fn()
	end
end

-- The choice list itself, shared by the Dropdown control and by the role chip on the access
-- page. The rows scroll inside a clipping frame, so the list is drawn on a page-level layer
-- and positioned from the anchor's absolute rectangle. `width` is the anchor's DESIGN width:
-- HudScale puts a UIScale over the whole GUI, so absolute pixels are converted back through
-- it rather than assumed to be 1:1.
local function openChoiceMenu(
	anchor: GuiObject,
	width: number,
	options: { Option },
	get: () -> any,
	set: (any) -> (),
	onClose: (() -> ())?
)
	closeOpenMenu()
	local layer = _menuLayer
	if not layer then
		return
	end
	local scale = anchor.AbsoluteSize.X / width
	if scale <= 0 then
		return
	end
	local origin = layer.AbsolutePosition

	local catcher = Instance.new("TextButton")
	catcher.Name = "Catcher"
	catcher.AutoButtonColor = false
	catcher.Text = ""
	catcher.BackgroundTransparency = 1
	catcher.Size = UDim2.fromScale(1, 1)
	catcher.ZIndex = 1
	catcher.Parent = layer

	local list = Instance.new("Frame")
	list.Name = "Menu"
	list.BackgroundColor3 = C.PanelEdge
	list.BorderSizePixel = 0
	list.ZIndex = 2
	list.Size = UDim2.fromOffset(width, #options * MENU_ITEM_H + 2)
	list.Position = UDim2.fromOffset(
		(anchor.AbsolutePosition.X - origin.X) / scale,
		(anchor.AbsolutePosition.Y - origin.Y + anchor.AbsoluteSize.Y) / scale + 3
	)
	list.Parent = layer
	corner(list, 3)
	stroke(list, C.Line, 0.25)

	for i, opt in options do
		local selected = opt.value == get()
		local item = Instance.new("TextButton")
		item.Name = opt.label
		item.AutoButtonColor = false
		item.Text = ""
		item.BackgroundColor3 = if selected then C.AccentWash else C.Raised
		item.BackgroundTransparency = if selected then 0 else 1
		item.BorderSizePixel = 0
		item.ZIndex = 3
		item.Size = UDim2.new(1, -2, 0, MENU_ITEM_H)
		item.Position = UDim2.fromOffset(1, 1 + (i - 1) * MENU_ITEM_H)
		item.Parent = list

		local lab = text(item, opt.label, 13, if selected then C.Text else C.TextDim, Theme.Font.Label)
		lab.Position = UDim2.fromOffset(11, 0)
		lab.Size = UDim2.new(1, -58, 1, 0)
		lab.ZIndex = 3

		if selected then
			local tag = text(item, tracked("Set"), 10, C.Accent, Theme.Font.Bold)
			tag.AnchorPoint = Vector2.new(1, 0.5)
			tag.Position = UDim2.new(1, -11, 0.5, 0)
			tag.Size = UDim2.fromOffset(40, 12)
			tag.TextXAlignment = Enum.TextXAlignment.Right
			tag.ZIndex = 3
		else
			item.MouseEnter:Connect(function()
				item.BackgroundTransparency = 0
				lab.TextColor3 = C.Text
			end)
			item.MouseLeave:Connect(function()
				item.BackgroundTransparency = 1
				lab.TextColor3 = C.TextDim
			end)
		end

		item.Activated:Connect(function()
			closeOpenMenu()
			if opt.value ~= get() then
				SoundFX.play("Click")
				set(opt.value)
			end
		end)
	end

	_closeMenu = function()
		catcher:Destroy()
		list:Destroy()
		if onClose then onClose() end
	end
	catcher.Activated:Connect(closeOpenMenu)
end

local function dropdownControl(mount: Frame, options: { Option }, get: () -> any, set: (any) -> ()): Control
	local root = Instance.new("TextButton")
	root.Name = "Dropdown"
	root.AutoButtonColor = false
	root.Text = ""
	root.BackgroundColor3 = C.Raised
	root.BorderSizePixel = 0
	root.BackgroundTransparency = 0.28
	root.AnchorPoint = Vector2.new(1, 0.5)
	root.Position = UDim2.new(1, 0, 0.5, 0)
	root.Size = UDim2.fromOffset(DROPDOWN_W, 38)
	root.Parent = mount
	corner(root, 8)
	-- This control's border doubles as its focus ring: two UIStrokes on one
	-- object do not both draw.
	local ring = stroke(root, GLASS_EDGE, 0.9)

	local current = text(root, "", 13, C.Text, Theme.Font.Label)
	current.Position = UDim2.fromOffset(12, 0)
	current.Size = UDim2.new(1, -40, 1, 0)

	-- Drawn, not typed: the mark here is a thin stroked chevron, which no glyph
	-- gives (U+25BE is a filled triangle, and Montserrat does not have it).
	local chevron = Instance.new("Frame")
	chevron.Name = "Chevron"
	chevron.BackgroundTransparency = 1
	chevron.AnchorPoint = Vector2.new(1, 0.5)
	chevron.Position = UDim2.new(1, -12, 0.5, 0)
	chevron.Size = UDim2.fromOffset(14, 14)
	chevron.Parent = root

	for _, dir in { -1, 1 } do
		local arm = Instance.new("Frame")
		arm.Name = "Arm"
		arm.BackgroundColor3 = C.TextDim
		arm.BorderSizePixel = 0
		arm.AnchorPoint = Vector2.new(0.5, 0.5)
		arm.Position = UDim2.new(0.5, dir * 3, 0.5, -1)
		arm.Size = UDim2.fromOffset(9, 2)
		arm.Rotation = -dir * 42
		arm.Parent = chevron
	end

	local function labelFor(value: any): string
		for _, opt in options do
			if opt.value == value then
				return opt.label
			end
		end
		return tostring(value)
	end

	local function render()
		current.Text = labelFor(get())
	end

	local function openMenu()
		openChoiceMenu(root, DROPDOWN_W, options, get, set, function()
			root.BackgroundColor3 = C.Raised
		end)
		root.BackgroundColor3 = C.RaisedHover
	end

	root.Activated:Connect(function()
		if _closeMenu then
			closeOpenMenu()
		else
			SoundFX.play("Click")
			openMenu()
		end
	end)
	render()

	return {
		render = render,
		nudge = function(dir: number)
			closeOpenMenu()
			local currentValue = get()
			local index = 1
			for i, opt in options do
				if opt.value == currentValue then
					index = i
					break
				end
			end
			index = ((index - 1 + dir) % #options) + 1
			if options[index].value ~= currentValue then
				SoundFX.play("Click")
				set(options[index].value)
			end
		end,
		focus = function(on: boolean)
			ring.Color = if on then C.Accent else C.Line
			ring.Transparency = if on then 0 else 0.35
		end,
	}
end

local function sliderControl(mount: Frame, key: string, min: number, max: number, asPercent: boolean): Control
	local root = Instance.new("Frame")
	root.Name = "Slider"
	root.BackgroundTransparency = 1
	root.AnchorPoint = Vector2.new(0, 0.5)
	root.Position = UDim2.new(0, 0, 0.5, 0)
	root.Size = UDim2.fromOffset(CTRL_W, 32)
	root.Parent = mount
	local ring = stroke(root, C.Accent, 1)

	local readout = text(root, "", 12, C.Text, Theme.Font.Bold)
	readout.AnchorPoint = Vector2.new(1, 0.5)
	readout.Position = UDim2.new(1, 0, 0.5, 0)
	readout.Size = UDim2.fromOffset(64, 14)
	readout.TextXAlignment = Enum.TextXAlignment.Right

	-- A 4px rail is far too thin to grab, so the whole strip is the hit target.
	local hit = Instance.new("TextButton")
	hit.Name = "Hit"
	hit.AutoButtonColor = false
	hit.Text = ""
	hit.BackgroundTransparency = 1
	hit.AnchorPoint = Vector2.new(0, 0.5)
	hit.Position = UDim2.new(0, 0, 0.5, 0)
	hit.Size = UDim2.new(1, -92, 0, 26)
	hit.Parent = root

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.BackgroundColor3 = C.TrackOff
	track.BorderSizePixel = 0
	track.AnchorPoint = Vector2.new(0, 0.5)
	track.Position = UDim2.new(0, 0, 0.5, 0)
	track.Size = UDim2.new(1, 0, 0, 3)
	track.Parent = hit
	corner(track, 2)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = C.Accent
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(0, 1)
	fill.Parent = track
	corner(fill, 2)

	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.BackgroundColor3 = C.Knob
	knob.BorderSizePixel = 0
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.new(0, 0, 0.5, 0)
	knob.Size = UDim2.fromOffset(13, 13)
	knob.ZIndex = 2
	knob.Parent = track
	corner(knob, 13)

	local function render()
		local v = math.clamp(tonumber(Settings.get(key)) or min, min, max)
		local alpha = (v - min) / (max - min)
		fill.Size = UDim2.fromScale(alpha, 1)
		knob.Position = UDim2.new(alpha, 0, 0.5, 0)
		readout.Text = if asPercent
			then string.format("%d%%", math.round(v * 100))
			else string.format("%.2f", v)
	end

	local function setFromX(x: number)
		local width = track.AbsoluteSize.X
		if width <= 0 then
			return
		end
		local alpha = math.clamp((x - track.AbsolutePosition.X) / width, 0, 1)
		writeValue(key, min + alpha * (max - min))
	end

	hit.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			_drag = setFromX
			setFromX(input.Position.X)
		end
	end)

	Settings.onChanged(key, render)
	render()

	return {
		render = render,
		nudge = function(dir: number)
			local v = math.clamp(tonumber(Settings.get(key)) or min, min, max)
			writeValue(key, math.clamp(v + dir * (max - min) / 20, min, max))
		end,
		focus = function(on: boolean)
			ring.Transparency = if on then 0 else 1
		end,
	}
end

-- ------------------------------------------------------------ rows --

local function newPage(parent: Frame, name: string): PageCtx
	local sf = Instance.new("ScrollingFrame")
	sf.Name = name
	sf.Active = true
	sf.BackgroundTransparency = 1
	sf.BorderSizePixel = 0
	sf.Size = UDim2.fromScale(1, 1)
	sf.CanvasSize = UDim2.new()
	sf.AutomaticCanvasSize = Enum.AutomaticSize.Y
	sf.ScrollBarThickness = 2
	sf.ScrollBarImageColor3 = C.Line
	sf.ScrollBarImageTransparency = 0.45
	sf.Visible = false
	sf.Parent = parent
	pad(sf, 10, CONTENT_PAD, 28, CONTENT_PAD)

	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 0)
	list.Parent = sf

	_pages[name] = sf
	return { frame = sf, order = 0, groupIndex = 0, rowInGroup = 0 }
end

-- Returns the heading holder, so a section that only applies sometimes can be hidden
-- along with its rows (see STORAGE on the Gameplay page).
local function group(p: PageCtx, name: string): Frame
	p.groupIndex += 1
	p.rowInGroup = 0
	p.order += 1

	local holder = Instance.new("Frame")
	holder.Name = "Group"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(1, 0, 0, 46)
	holder.LayoutOrder = p.order
	holder.Parent = p.frame

	-- Heading reads LABEL ————— : the title, then a hairline running out to the
	-- right margin. The rule is re-fitted from the title's measured width, which
	-- is only known once the label has laid out.
	local title = text(holder, tracked(name), 10, C.TextDim, Theme.Font.Bold)
	title.Position = UDim2.fromOffset(0, 24)
	title.Size = UDim2.fromOffset(400, 14)
	title.AutomaticSize = Enum.AutomaticSize.X

	local rule = hairline(holder, GLASS_EDGE)
	rule.BackgroundTransparency = 0.88
	rule.AnchorPoint = Vector2.new(1, 0)
	rule.Position = UDim2.new(1, 0, 0, 31)
	local function fitRule()
		rule.Size = UDim2.new(1, -(title.TextBounds.X + 14), 0, 1)
	end
	fitRule()
	title:GetPropertyChangedSignal("TextBounds"):Connect(fitRule)
	return holder
end

-- Every row is the same shape: one label on the left, one control on the right.
-- The second line is a note slot, empty unless a caller writes to it (bindRow
-- puts key conflicts there) -- the row re-centres its title around it.
-- ponytail: callers still pass a description string that is no longer drawn.
-- Strip those arguments next time these pages are edited.
local function row(p: PageCtx, title: string, _desc: string): (Frame, Frame, TextLabel)
	p.order += 1
	p.rowInGroup += 1

	local holder = Instance.new("Frame")
	holder.Name = "Row"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(1, 0, 0, ROW_H)
	holder.LayoutOrder = p.order
	holder.Parent = p.frame

	local t = text(holder, title, 15, C.Text, Theme.Font.Label)
	t.Size = UDim2.new(1, -CTRL_W - 24, 0, 20)

	local d = text(holder, "", 12, C.TextDim, Theme.Font.Label)
	d.Position = UDim2.fromOffset(0, 31)
	d.Size = UDim2.new(1, -CTRL_W - 24, 0, 15)

	local function layout()
		local note = d.Text ~= ""
		d.Visible = note
		t.Position = UDim2.fromOffset(0, if note then 10 else math.round((ROW_H - 20) / 2))
	end
	layout()
	d:GetPropertyChangedSignal("Text"):Connect(layout)

	local mount = Instance.new("Frame")
	mount.Name = "Control"
	mount.BackgroundTransparency = 1
	mount.AnchorPoint = Vector2.new(1, 0.5)
	mount.Position = UDim2.new(1, 0, 0.5, 0)
	mount.Size = UDim2.fromOffset(CTRL_W, 44)
	mount.Parent = holder

	return holder, mount, d
end

-- Hovering a row arms it for the arrow keys, and rings the control so the
-- player can see which one the keys will move.
--
-- MouseEnter/MouseLeave only track the TOPMOST object under the cursor, so
-- moving from the row onto the button inside it fires the row's MouseLeave.
-- Every button in the row is therefore wired to the same pair, and a leave only
-- takes effect if nothing else in the row was entered in the same frame.
local function attachFocus(holder: Frame, control: Control)
	local token = 0

	local function enter()
		token += 1
		if _focus and _focus ~= control then
			(_focus :: Control).focus(false)
		end
		_focus = control
		control.focus(true)
	end

	local function leave()
		token += 1
		local mine = token
		task.defer(function()
			if mine ~= token then
				return -- re-entered a child of the same row
			end
			if _focus == control then
				_focus = nil
			end
			control.focus(false)
		end)
	end

	holder.MouseEnter:Connect(enter)
	holder.MouseLeave:Connect(leave)
	for _, d in holder:GetDescendants() do
		if d:IsA("GuiButton") then
			d.MouseEnter:Connect(enter)
			d.MouseLeave:Connect(leave)
		end
	end
end

-- The storage meter's number comes from the server (the last SAVED size), so it is
-- fetched rather than read from Settings like every other row on this page.
-- Forward-declared so Open() can pull a fresh access list each time the panel comes up:
-- roles change from other players' actions, so the page goes stale with nobody touching
-- it. Assigned further down, with the rest of the access page.
local refreshAccess: () -> ()

local _setMemoryMeter: ((used: number, cap: number) -> ())? = nil
local _memoryUsed, _memoryCap = 0, 0

-- Cloud storage is a property of a CITY. In the menu there is none to measure, so the whole
-- section is out rather than reading "0 B" of a budget belonging to nothing. The answer
-- comes off the same server round-trip the access page already makes -- see refreshAccess.
local _storageRows: { GuiObject } = {}
local function setStorageVisible(on: boolean)
	for _, inst in _storageRows do
		inst.Visible = on
	end
end

local function refreshMemoryMeter()
	local apply = _setMemoryMeter
	if not apply then return end
	apply(_memoryUsed, _memoryCap)
	task.spawn(function()
		local ok, info = pcall(function()
			return require(ReplicatedStorage:WaitForChild("Networker")).RequestCityMemory:InvokeServer()
		end)
		if not ok or typeof(info) ~= "table" then return end
		_memoryUsed = math.max(0, tonumber(info.used) or 0)
		_memoryCap = math.max(1, tonumber(info.cap) or 1)
		if _setMemoryMeter then _setMemoryMeter(_memoryUsed, _memoryCap) end
	end)
end

local function formatBytes(n: number): string
	if n >= 1024 * 1024 then return string.format("%.1f MB", n / 1024 / 1024) end
	if n >= 1024 then return string.format("%d KB", n // 1024) end
	return tostring(n) .. " B"
end

-- Read-only meter: a value on the right and a filled track under the label. Returns the
-- setter so whoever owns the number can push it in, plus the row itself for a caller that
-- has to hide it; the row knows nothing about where the number comes from.
local METER_ROW_H = ROW_H + 18
local function meterRow(p: PageCtx, title: string, desc: string): ((used: number, cap: number) -> (), Frame)
	local holder, mount, note = row(p, title, desc)
	note.Text = desc
	-- The note line runs to y=46 inside a standard row and the track sits on the bottom
	-- edge, so at ROW_H the bar was drawn THROUGH the description. The row is taller here
	-- to give the track its own line.
	holder.Size = UDim2.new(1, 0, 0, METER_ROW_H)

	local readout = text(mount, "", 15, C.Text, Theme.Font.Bold)
	readout.AnchorPoint = Vector2.new(1, 0)
	readout.Position = UDim2.new(1, 0, 0, 8)
	readout.Size = UDim2.fromOffset(CTRL_W, 18)
	readout.TextXAlignment = Enum.TextXAlignment.Right

	local sub = text(mount, "", 12, C.TextDim, Theme.Font.Label)
	sub.AnchorPoint = Vector2.new(1, 0)
	sub.Position = UDim2.new(1, 0, 0, 30)
	sub.Size = UDim2.fromOffset(CTRL_W, 15)
	sub.TextXAlignment = Enum.TextXAlignment.Right

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.BackgroundColor3 = C.TrackOff
	-- An opaque empty track reads as a FULL bar at a glance, which is exactly the wrong
	-- thing for a city using 700 bytes of 16MB. It is a groove, so it is drawn like one.
	track.BackgroundTransparency = 0.55
	track.BorderSizePixel = 0
	track.ClipsDescendants = true
	track.AnchorPoint = Vector2.new(0, 1)
	track.Position = UDim2.new(0, 0, 1, -10)
	track.Size = UDim2.new(1, -CTRL_W - 24, 0, 5)
	track.Parent = holder
	Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = C.Accent
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(0, 1)
	fill.Parent = track
	Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

	local function apply(used: number, cap: number)
		local frac = if cap > 0 then math.clamp(used / cap, 0, 1) else 0
		readout.Text = formatBytes(used) .. " / " .. formatBytes(cap)
		-- Never round a non-empty city down to "0%" -- it reads as "nothing saved".
		local pct = if frac > 0 and frac < 0.01 then 1 else math.floor(frac * 100 + 0.5)
		sub.Text = "Storage Used " .. tostring(pct) .. "%"
		-- A fraction this small is a sub-pixel bar, i.e. nothing at all. The minimum is a
		-- visible nub so "a little" and "none" do not look the same; the track clips, so
		-- the nub cannot push a full bar past its end.
		fill.Size = UDim2.new(frac, if used > 0 then 6 else 0, 1, 0)
		-- The bar turns as it fills: this is a hard cap, and a player who blows past it
		-- stops being able to save at all.
		fill.BackgroundColor3 = if frac >= 0.9 then Color3.fromRGB(214, 92, 76)
			elseif frac >= 0.7 then Color3.fromRGB(224, 168, 72)
			else C.Accent
	end

	return apply, holder
end

local function toggleRow(p: PageCtx, title: string, desc: string, key: string)
	local holder, mount = row(p, title, desc)
	attachFocus(holder, toggleControl(mount, key))
end

local function sliderRow(p: PageCtx, title: string, desc: string, key: string, min: number, max: number, asPercent: boolean?)
	local holder, mount = row(p, title, desc)
	attachFocus(holder, sliderControl(mount, key, min, max, asPercent ~= false))
end

local function dropdownRow(p: PageCtx, title: string, desc: string, key: string, options: { Option })
	local holder, mount = row(p, title, desc)
	local control = dropdownControl(mount, options, function()
		return Settings.get(key)
	end, function(value)
		writeValue(key, value)
	end)
	Settings.onChanged(key, control.render)
	attachFocus(holder, control)
end

local function actionRow(p: PageCtx, title: string, desc: string, buttonLabel: string, fn: () -> ())
	local _, mount = row(p, title, desc)

	local b = Instance.new("TextButton")
	b.Name = "Action"
	b.AutoButtonColor = false
	b.Text = tracked(buttonLabel)
	b.TextSize = 11
	b.FontFace = Theme.Font.Bold
	b.TextColor3 = C.TextDim
	b.BackgroundTransparency = 1
	b.BorderSizePixel = 0
	b.AnchorPoint = Vector2.new(1, 0.5)
	b.Position = UDim2.new(1, 0, 0.5, 0)
	b.AutomaticSize = Enum.AutomaticSize.X
	b.Size = UDim2.fromOffset(0, 32)
	b.Parent = mount
	pad(b, 0, 16, 0, 16)
	corner(b, 3)
	local ring = stroke(b, C.Line, 0.35)

	b.MouseEnter:Connect(function()
		ring.Color = C.Accent
		ring.Transparency = 0
		b.TextColor3 = C.Text
	end)
	b.MouseLeave:Connect(function()
		ring.Color = C.Line
		ring.Transparency = 0.35
		b.TextColor3 = C.TextDim
	end)
	b.Activated:Connect(function()
		SoundFX.play("Click")
		fn()
	end)
end

-- ------------------------------------------------------------ binds --

local function stopCapture()
	if _captureStop then
		local stop = _captureStop
		_captureStop = nil
		_capturing = nil
		stop()
	end
end

local function beginCapture(action: string, redraw: () -> ())
	stopCapture()
	_capturing = action

	local wantsMouse = Settings.actionTab(action) == "Mouse"
	local held: Settings.Bind = {}
	local conns: { RBXScriptConnection } = {}

	local function finish(commit: boolean)
		for _, c in conns do
			c:Disconnect()
		end
		table.clear(conns)
		_capturing = nil
		_captureStop = nil
		if commit and #held > 0 then
			Settings.setBind(action, held)
		end
		redraw()
	end

	_captureStop = function()
		finish(false)
	end

	table.insert(conns, UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape then
			finish(false)
			return
		end
		local hit: Settings.BindInput? = nil
		if wantsMouse then
			if Settings.isBindableMouse(input.UserInputType) then
				hit = input.UserInputType
			end
		elseif input.UserInputType == Enum.UserInputType.Keyboard
			and input.KeyCode ~= Enum.KeyCode.Unknown then
			hit = MODIFIER_FOLD[input.KeyCode] or input.KeyCode
		end
		if not hit then
			return
		end
		for _, existing in held do
			if existing == hit then
				return
			end
		end
		if #held < 3 then
			table.insert(held, hit)
			redraw()
		end
	end))

	-- Releasing anything commits the chord that was held. The click that opened
	-- capture cannot commit it: nothing is in `held` yet.
	table.insert(conns, UserInputService.InputEnded:Connect(function()
		if #held > 0 then
			finish(true)
		end
	end))

	redraw()
end

local function bindRow(p: PageCtx, def: Settings.ActionDef)
	local required = Settings.isRequired(def.id)
	local holder, mount, desc = row(p, def.label, if required then "Cannot be left unbound." else "")

	local capture = Instance.new("TextButton")
	capture.Name = "Capture"
	capture.AutoButtonColor = false
	capture.Text = ""
	capture.BackgroundTransparency = 1
	capture.Position = UDim2.fromOffset(0, 0)
	capture.Size = UDim2.new(1, -72, 1, 0)
	capture.Parent = mount

	local caps = Instance.new("Frame")
	caps.Name = "Caps"
	caps.BackgroundTransparency = 1
	caps.Size = UDim2.fromScale(1, 1)
	caps.Parent = capture

	local capsList = Instance.new("UIListLayout")
	capsList.FillDirection = Enum.FillDirection.Horizontal
	capsList.HorizontalAlignment = Enum.HorizontalAlignment.Right
	capsList.VerticalAlignment = Enum.VerticalAlignment.Center
	capsList.SortOrder = Enum.SortOrder.LayoutOrder
	capsList.Padding = UDim.new(0, 5)
	capsList.Parent = caps

	local function smallButton(glyph: string, x: number, tip: string): TextButton
		local b = Instance.new("TextButton")
		b.Name = tip
		b.AutoButtonColor = false
		b.Text = glyph
		b.TextSize = 13
		b.FontFace = GLYPH_FONT
		b.TextColor3 = C.TextFaint
		b.BackgroundTransparency = 1
		b.BorderSizePixel = 0
		b.AnchorPoint = Vector2.new(1, 0.5)
		b.Position = UDim2.new(1, x, 0.5, 0)
		b.Size = UDim2.fromOffset(28, 28)
		b.Visible = false
		b.Parent = mount
		corner(b, 3)
		local ring = stroke(b, C.Line, 0.4)
		b.MouseEnter:Connect(function()
			ring.Color = C.Accent
			b.TextColor3 = C.Accent
		end)
		b.MouseLeave:Connect(function()
			ring.Color = C.Line
			b.TextColor3 = C.TextFaint
		end)
		return b
	end

	local revert = smallButton("\u{21BA}", -34, "Revert")
	local clear = smallButton("\u{2715}", 0, "Clear")

	local function render()
		for _, child in caps:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end

		if _capturing == def.id then
			local waiting = text(caps, tracked("PRESS KEYS"), 11, C.Accent, Theme.Font.Bold)
			waiting.Size = UDim2.fromOffset(130, 24)
			waiting.TextXAlignment = Enum.TextXAlignment.Right
			revert.Visible = false
			clear.Visible = false
		else
			local list = Settings.bindCaps(Settings.getBind(def.id))
			if #list == 0 then
				local none = text(caps, tracked("NOT SET"), 11, C.TextFaint, Theme.Font.Bold)
				none.Size = UDim2.fromOffset(100, 24)
				none.TextXAlignment = Enum.TextXAlignment.Right
			end
			for i, cap in list do
				local chip = text(caps, cap, 11, C.Text, Theme.Font.Bold)
				chip.BackgroundTransparency = 0
				chip.BackgroundColor3 = C.Raised
				chip.AutomaticSize = Enum.AutomaticSize.X
				chip.Size = UDim2.fromOffset(0, 26)
				chip.TextXAlignment = Enum.TextXAlignment.Center
				chip.TextTruncate = Enum.TextTruncate.None
				chip.LayoutOrder = i
				pad(chip, 0, 9, 0, 9)
				corner(chip, 3)
				stroke(chip, C.Line, 0.35)
			end
			revert.Visible = Settings.hasPrevious(def.id)
			clear.Visible = not required and #list > 0
		end

		local hits = Settings.bindConflicts(def.id)
		if #hits > 0 then
			desc.Text = "Shares this key with "
				.. tostring(#hits)
				.. (if #hits == 1 then " other action" else " other actions")
				.. " in this group."
			desc.TextColor3 = C.Accent
		else
			desc.Text = if required then "Cannot be left unbound." else ""
			desc.TextColor3 = C.TextDim
		end
	end

	capture.Activated:Connect(function()
		SoundFX.play("Click")
		beginCapture(def.id, render)
	end)
	revert.Activated:Connect(function()
		SoundFX.play("Click")
		Settings.revertBind(def.id)
	end)
	clear.Activated:Connect(function()
		SoundFX.play("Click")
		Settings.clearBind(def.id)
	end)

	_bindRenders[def.id] = render
	render()
end

-- ------------------------------------------------------------ pages --

local function buildGraphics(content: Frame)
	local p = newPage(content, "GRAPHICS")

	local presetOptions: { Option } = {}
	for i, name in Settings.presetNames() do
		presetOptions[i] = { label = name, value = name }
	end
	table.insert(presetOptions, { label = "Custom", value = "Custom", readOnly = true })

	local holder, mount = row(p, "Quality preset", "Applies a matched set of detail and effect values.")
	local preset = segmentControl(mount, presetOptions, function()
		return Settings.get("graphicsPreset")
	end, function(value)
		Settings.applyPreset(tostring(value))
	end)
	Settings.onChanged("graphicsPreset", preset.render)
	attachFocus(holder, preset)

	group(p, "DETAIL")
	dropdownRow(p, "Shadow quality", "Resolution and softness of cast shadows.", "shadowQuality", {
		{ label = "Off", value = "Off" },
		{ label = "Hard", value = "Hard" },
		{ label = "Soft", value = "Soft" },
	})
	sliderRow(p, "Draw distance", "How far world geometry stays at full detail.", "renderDistance", 0.4, 2)

	group(p, "EFFECTS")
	toggleRow(p, "Bloom", "Light bleed around bright surfaces.", "bloom")
	toggleRow(p, "Sun rays", "Volumetric shafts through gaps and haze.", "sunRays")
	toggleRow(p, "Depth of field", "Blurs the far distance behind the camera focus.", "depthOfField")
	toggleRow(p, "Atmosphere haze", "Distance fog over the skyline.", "haze")

	group(p, "WATER")
	toggleRow(p, "Water waves", "Animated surface on rivers, lakes and sea.", "waterWaves")
	sliderRow(p, "Water reflections", "How much of the sky the surface mirrors.", "waterReflections", 0, 1)
	sliderRow(p, "Water clarity", "How far down through the surface you can see.", "waterTransparency", 0, 1)

	group(p, "EFFECT STRENGTH")
	sliderRow(p, "Bloom intensity", "Strength of the light bleed.", "bloomIntensity", 0, 4, false)
	sliderRow(p, "Sun ray intensity", "Strength of the volumetric shafts.", "sunRayIntensity", 0, 1)
	sliderRow(p, "Haze density", "Thickness of the distance fog.", "hazeDensity", 0, 1)

	group(p, "COLOUR GRADING")
	toggleRow(p, "Colour grading", "Master switch for the graded look.", "colorGrade")
	sliderRow(p, "Saturation", "Colour intensity across the whole image.", "ccSaturation", -1, 1)
	sliderRow(p, "Contrast", "Separation between the darks and the lights.", "ccContrast", -1, 1)
	sliderRow(p, "Brightness", "Lifts or crushes the whole image.", "ccBrightness", -1, 1)
	sliderRow(p, "Exposure", "Overall light level, in stops.", "exposure", -2, 2, false)

	group(p, "CHANNEL TINT")
	sliderRow(p, "Red", "Red channel weight in the grade.", "tintR", 0, 1)
	sliderRow(p, "Green", "Green channel weight in the grade.", "tintG", 0, 1)
	sliderRow(p, "Blue", "Blue channel weight in the grade.", "tintB", 0, 1)
end

local function buildGameplay(content: Frame)
	local p = newPage(content, "GAMEPLAY")

	group(p, "SIMULATION")
	toggleRow(p, "Day / night cycle", "Time of day advances while you build.", "dayNight")
	toggleRow(p, "Start paused", "Enter a city with the simulation halted.", "startPaused")

	group(p, "VISITORS")
	toggleRow(p, "Open house",
		"The people you have invited can open your cities when you are not in them. Off, they can only join a city you are already playing.",
		"friendsOffline")

	group(p, "AUTOSAVE")
	toggleRow(p, "Autosave", "Writes your city to the cloud on a timer.", "autosave")
	dropdownRow(p, "Autosave interval", "How long the game waits between saves.", "autosaveInterval", {
		{ label = "Every minute", value = 1 },
		{ label = "Every 2 minutes", value = 2 },
		{ label = "Every 5 minutes", value = 5 },
		{ label = "Every 10 minutes", value = 10 },
		{ label = "Every 15 minutes", value = 15 },
		{ label = "Every 30 minutes", value = 30 },
		{ label = "Every hour", value = 60 },
	})

	local storageHead = group(p, "STORAGE")
	local setMeter, storageRow = meterRow(p, "Memory Budget",
		"Cloud storage used by this city. Roads, buildings and every prop or nature item you place add to it.")
	_setMemoryMeter = setMeter
	_storageRows = { storageHead, storageRow }
	-- Hidden until the server confirms a city is standing; refreshAccess flips it.
	setStorageVisible(false)
	refreshMemoryMeter()

	group(p, "DIAGNOSTICS")
	dropdownRow(p, "Performance overlay", "On-screen frame rate and timing readout.", "showFps", {
		{ label = "Off", value = "Off" },
		{ label = "Simple", value = "Simple" },
		{ label = "Advanced", value = "Advanced" },
	})
end

-- ------------------------------------------------------- city access --

-- Who may be in this city and what they may do. Every answer on this page comes from the
-- server (RequestCityAccess); nothing here is trusted, and the page is empty for anyone
-- the server will not show it to -- a player with no business here simply sees the notice.
local _accessList: Frame? = nil
local _accessNotice: TextLabel? = nil
local _accessName: TextBox? = nil
local _accessRows: { Instance } = {}
-- Solo / shared for the city standing in this server. Server-owned like everything else
-- on this page: this is only the last answer it gave, never the source of truth.
local _citySharing = false
local _sharingRender: (() -> ())? = nil
local _sharingDesc: TextLabel? = nil

-- Friend picker for the invite box. Typing a Roblox username exactly right, from memory,
-- is the reason nobody ever invites anybody -- so the names are offered rather than
-- demanded. They come from the CLIENT's own friends list, which costs no remote and
-- grants nothing: picking one only fills the box in, and the server still resolves and
-- checks whatever name it is finally sent.
local FRIEND_SUGGESTIONS = 5
-- The role chip in WHO HAS ACCESS doubles as the picker for that row. Its DESIGN width is
-- what openChoiceMenu measures the GUI scale against, so it is fixed rather than automatic.
local ROLE_CHIP_W = 104
local ROLE_OPTIONS: { Option } = {}
for i, role in CityRoles.Order do
	ROLE_OPTIONS[i] = { label = CityRoles.Label[role], value = role }
end
local _friendNames: { string } = {}
local _friendsFetched = false
local _renderSuggestions: (() -> ())? = nil

-- Yields, so it is only ever called from refreshAccess's own thread. Two pages is 100
-- names: enough to type against, and bounded so a player with a thousand friends does
-- not stall the page open. A failed fetch is not remembered, so the next open retries.
local function fetchFriendNames()
	if _friendsFetched then return end
	local ok, pages = pcall(function()
		return Players:GetFriendsAsync(Players.LocalPlayer.UserId)
	end)
	if not ok or not pages then return end
	for _ = 1, 2 do
		for _, entry in pages:GetCurrentPage() do
			table.insert(_friendNames, tostring(entry.Username))
		end
		if pages.IsFinished then break end
		if not pcall(function() pages:AdvanceToNextPageAsync() end) then break end
	end
	table.sort(_friendNames, function(a, b) return a:lower() < b:lower() end)
	_friendsFetched = true
	if _renderSuggestions then _renderSuggestions() end
end

local function smallButton(parent: GuiObject, label: string, fn: () -> ()): TextButton
	local b = Instance.new("TextButton")
	b.AutoButtonColor = false
	b.Text = tracked(label)
	b.TextSize = 11
	b.FontFace = Theme.Font.Bold
	b.TextColor3 = C.TextDim
	b.BackgroundTransparency = 1
	b.BorderSizePixel = 0
	b.AutomaticSize = Enum.AutomaticSize.X
	b.Size = UDim2.fromOffset(0, 28)
	b.Parent = parent
	pad(b, 0, 14, 0, 14)
	corner(b, 3)
	local ring = stroke(b, C.Line, 0.35)
	b.MouseEnter:Connect(function()
		ring.Color = C.Accent; ring.Transparency = 0; b.TextColor3 = C.Text
	end)
	b.MouseLeave:Connect(function()
		ring.Color = C.Line; ring.Transparency = 0.35; b.TextColor3 = C.TextDim
	end)
	b.Activated:Connect(function()
		SoundFX.play("Click")
		fn()
	end)
	return b
end

local function accessCall(payload: any): any
	local ok, res = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Networker")).RequestCityAccess:InvokeServer(payload)
	end)
	if not ok or typeof(res) ~= "table" then
		return { ok = false, error = "Could not reach the server." }
	end
	return res
end

-- A separate remote from the access list on purpose: the guest list is the OWNER's
-- record (PlaceAccessService), and solo/shared is a field on the city SLOT
-- (CitySlotService). One page, but each write still lands on the service that owns it.
local function sharingCall(on: boolean?): any
	local ok, res = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Networker")).RequestCitySharing:InvokeServer(on)
	end)
	if not ok or typeof(res) ~= "table" then
		return { ok = false, error = "Could not reach the server." }
	end
	return res
end

local function renderAccess(res: any)
	local list = _accessList
	local notice = _accessNotice
	if not list or not notice then return end

	for _, inst in _accessRows do inst:Destroy() end
	table.clear(_accessRows)

	if not res.ok then
		notice.Text = tostring(res.error or "Not available here.")
		notice.Visible = true
		return
	end

	local entries = if typeof(res.entries) == "table" then res.entries else {}
	if #entries == 0 then
		notice.Text = "Nobody else has access to this city yet."
		notice.Visible = true
		return
	end
	notice.Visible = false

	for i, entry in entries do
		local holder = Instance.new("Frame")
		holder.BackgroundTransparency = 1
		holder.Size = UDim2.new(1, 0, 0, 34)
		holder.LayoutOrder = i
		holder.Parent = list
		table.insert(_accessRows, holder)

		local who = text(holder, tostring(entry.name), 13, C.Text, Theme.Font.Label)
		who.Position = UDim2.fromOffset(0, 8)
		who.Size = UDim2.new(0.5, 0, 0, 18)

		-- The role IS the control, not a caption beside one: clicking it opens the same
		-- three-item list the rest of the page uses, and picking one re-grants. Changing
		-- somebody's role was otherwise remove-then-retype-their-name.
		local what = Instance.new("TextButton")
		what.Name = "Role"
		what.AutoButtonColor = false
		what.Text = string.upper(tostring(entry.role))
		what.TextSize = 11
		what.FontFace = Theme.Font.Bold
		what.TextColor3 = C.TextDim
		what.BackgroundColor3 = C.Raised
		what.BackgroundTransparency = 0.35
		what.BorderSizePixel = 0
		what.AnchorPoint = Vector2.new(0, 0.5)
		what.Position = UDim2.new(0.5, 0, 0.5, 0)
		what.Size = UDim2.fromOffset(ROLE_CHIP_W, 24)
		what.Parent = holder
		corner(what, 3)
		local ring = stroke(what, C.Line, 0.45)
		what.MouseEnter:Connect(function()
			ring.Color = C.Accent; what.TextColor3 = C.Text
		end)
		what.MouseLeave:Connect(function()
			ring.Color = C.Line; what.TextColor3 = C.TextDim
		end)
		what.Activated:Connect(function()
			SoundFX.play("Click")
			openChoiceMenu(what, ROLE_CHIP_W, ROLE_OPTIONS, function()
				return entry.role
			end, function(value)
				-- A role change is a re-grant: same remote, same server-side checks as
				-- handing it out the first time. A refusal lands in the notice line.
				renderAccess(accessCall({ action = "grant", name = entry.name, role = value }))
			end)
		end)

		local remove = smallButton(holder, "Remove", function()
			renderAccess(accessCall({ action = "revoke", name = entry.name }))
		end)
		remove.AnchorPoint = Vector2.new(1, 0.5)
		remove.Position = UDim2.new(1, 0, 0.5, 0)
	end
end

function refreshAccess()
	task.spawn(function()
		fetchFriendNames()
		local sharing = sharingCall(nil)
		_citySharing = sharing.ok == true and sharing.multiplayer == true
		-- Rows on this panel carry no description until something goes wrong, so the note
		-- line doubles as where the server's refusal is said.
		if _sharingDesc then
			_sharingDesc.Text = if sharing.ok then "" else tostring(sharing.error or "")
		end
		if _sharingRender then _sharingRender() end
		-- sharingCall answers ok only when a city is standing in THIS server and the caller
		-- owns it, which is exactly when there is a storage budget worth showing.
		setStorageVisible(sharing.ok == true)
		if sharing.ok then refreshMemoryMeter() end
		-- The ACCESS section exists only where there is a city to give access TO. The server
		-- answers that for an owner OR a managing admin standing in one, and refuses it
		-- everywhere else -- which is also why this is decided HERE and nowhere else: a
		-- later grant that fails must not take the page away mid-edit.
		local listed = accessCall({ action = "list" })
		setAccessVisible(listed.ok == true)
		renderAccess(listed)
	end)
end

local function buildAccess(content: Frame)
	local p = newPage(content, "ACCESS")

	-- Solo or shared, the switch the whole page hangs off: with it on Solo nobody but the
	-- owner may be here at all, whatever roles the list below hands out.
	group(p, "THIS CITY")
	local shareHolder, shareMount, shareDesc = row(p, "Who can join", "")
	_sharingDesc = shareDesc
	local sharing = segmentControl(shareMount, {
		{ label = "Solo", value = false },
		{ label = "Shared", value = true },
	}, function()
		return _citySharing
	end, function(value)
		-- The control is optimistic about nothing: the button does not move until the
		-- server has written the flag and said so.
		task.spawn(function()
			local res = sharingCall(value == true)
			if res.ok then
				_citySharing = res.multiplayer == true
				shareDesc.Text = ""
			else
				shareDesc.Text = tostring(res.error or "Could not change that.")
			end
			if _sharingRender then _sharingRender() end
		end)
	end)
	_sharingRender = sharing.render
	attachFocus(shareHolder, sharing)

	-- The same setting as Gameplay > Visitors, surfaced here because this is the page you
	-- are on when the question comes up. It is a PLAYER setting, not a per-city one (it
	-- rides the settings blob PlayerSettingsService already persists), so it answers "can
	-- the people I trust open my city when I am not in it" for all of them at once.
	toggleRow(p, "Open house",
		"On, the people below can open your city when you are not in it. Off, they can only join one you are already playing.",
		"friendsOffline")

	group(p, "INVITE A PLAYER")

	local holder, mount = row(p, "Player name", "")
	local box = Instance.new("TextBox")
	box.BackgroundColor3 = C.Raised
	box.BorderSizePixel = 0
	box.ClearTextOnFocus = false
	box.PlaceholderText = "Roblox username"
	box.Text = ""
	box.TextSize = 13
	box.FontFace = Theme.Font.Label
	box.TextColor3 = C.Text
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.AnchorPoint = Vector2.new(1, 0.5)
	box.Position = UDim2.new(1, 0, 0.5, 0)
	box.Size = UDim2.fromOffset(DROPDOWN_W, 30)
	box.Parent = mount
	pad(box, 0, 10, 0, 10)
	corner(box, 3)
	stroke(box, C.Line, 0.35)
	_accessName = box
	local _ = holder

	local suggest = Instance.new("Frame")
	suggest.Name = "FriendSuggestions"
	suggest.BackgroundTransparency = 1
	suggest.AutomaticSize = Enum.AutomaticSize.Y
	suggest.Size = UDim2.new(1, 0, 0, 0)
	p.order += 1
	suggest.LayoutOrder = p.order
	suggest.Parent = p.frame

	local suggestLayout = Instance.new("UIListLayout")
	suggestLayout.FillDirection = Enum.FillDirection.Horizontal
	suggestLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	suggestLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	suggestLayout.SortOrder = Enum.SortOrder.LayoutOrder
	suggestLayout.Padding = UDim.new(0, 6)
	suggestLayout.Parent = suggest

	local function renderSuggestions()
		for _, c in suggest:GetChildren() do
			if c:IsA("GuiObject") then c:Destroy() end
		end
		local typed = string.lower(box.Text)
		local shown = 0
		for _, name in _friendNames do
			if shown >= FRIEND_SUGGESTIONS then break end
			if typed == "" or string.find(string.lower(name), typed, 1, true) then
				shown += 1
				local chip = smallButton(suggest, name, function()
					box.Text = name
				end)
				-- Plain, not tracked(): letterspacing a username makes it harder to read,
				-- and it has to match what the player would have typed.
				chip.Text = name
				chip.LayoutOrder = shown
			end
		end
	end
	_renderSuggestions = renderSuggestions
	box:GetPropertyChangedSignal("Text"):Connect(renderSuggestions)
	renderSuggestions()

	-- Three buttons instead of a role dropdown: there are exactly three roles, and a
	-- picker plus an Add button is two interactions to say one thing.
	local _, addMount = row(p, "Give them access as", "Visitors can look. Builders can build. Admins can also invite.")
	local strip = Instance.new("Frame")
	strip.BackgroundTransparency = 1
	strip.AnchorPoint = Vector2.new(1, 0.5)
	strip.Position = UDim2.new(1, 0, 0.5, 0)
	strip.Size = UDim2.fromOffset(CTRL_W, 30)
	strip.Parent = addMount
	local strut = Instance.new("UIListLayout")
	strut.FillDirection = Enum.FillDirection.Horizontal
	strut.HorizontalAlignment = Enum.HorizontalAlignment.Right
	strut.VerticalAlignment = Enum.VerticalAlignment.Center
	strut.Padding = UDim.new(0, 8)
	strut.Parent = strip

	for _, role in { "visitor", "builder", "admin" } do
		smallButton(strip, string.upper(role), function()
			local name = if _accessName then _accessName.Text else ""
			if #name == 0 then return end
			renderAccess(accessCall({ action = "grant", name = name, role = role }))
			if _accessName then _accessName.Text = "" end
		end)
	end

	group(p, "WHO HAS ACCESS")

	local listHolder = Instance.new("Frame")
	listHolder.BackgroundTransparency = 1
	listHolder.AutomaticSize = Enum.AutomaticSize.Y
	listHolder.Size = UDim2.new(1, 0, 0, 0)
	p.order += 1
	listHolder.LayoutOrder = p.order
	listHolder.Parent = p.frame

	local listLayout = Instance.new("UIListLayout")
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, 2)
	listLayout.Parent = listHolder
	_accessList = listHolder

	local notice = text(listHolder, "", 12, C.TextDim, Theme.Font.Label)
	notice.Size = UDim2.new(1, 0, 0, 28)
	notice.LayoutOrder = 0
	notice.Visible = false
	_accessNotice = notice
end

local function buildAudio(content: Frame)
	local p = newPage(content, "AUDIO")

	group(p, "LEVELS")
	sliderRow(p, "Master volume", "Overall level for every sound in the game.", "masterVolume", 0, 1)
	sliderRow(p, "Music", "Radio stations and menu score.", "musicVolume", 0, 1)
	sliderRow(p, "Sound effects", "Tools, traffic and interface clicks.", "sfxVolume", 0, 1)
	sliderRow(p, "Ambience", "Weather, water and city background noise.", "ambienceVolume", 0, 1)
end

local function buildInterface(content: Frame)
	local p = newPage(content, "INTERFACE")

	-- Language leads: a player who cannot read the current UI language needs it
	-- to be the first row on the page, not buried under Units.
	group(p, "LANGUAGE")
	dropdownRow(p, "Language", "Language used across the whole interface.", "language", Locale.options())

	group(p, "LAYOUT")
	sliderRow(p, "HUD scale", "Size of every on-screen panel and button.", "uiScale", 0.85, 1.15)
	sliderRow(p, "UI transparency", "Extra see-through on glass panels.", "uiTransparency", 0, 0.5)
	toggleRow(p, "Frosted glass", "Blur pane behind panels. Costs frames on weak GPUs.", "frostedGlass")

	group(p, "PROMPTS")
	toggleRow(p, "Tooltips", "Hover hints on buttons and tools.", "tooltips")
	toggleRow(p, "Notifications", "Corner popups for city events.", "notifications")

	group(p, "UNITS")
	dropdownRow(p, "Clock format", "How the time of day is written in the HUD.", "timeFormat", {
		{ label = "12 hour", value = 12 },
		{ label = "24 hour", value = 24 },
	})
	dropdownRow(p, "Distance", "Units used for lengths and areas.", "units", {
		{ label = "Metric (km)", value = "Metric" },
		{ label = "Imperial (mi)", value = "Imperial" },
		{ label = "Studs", value = "Studs" },
	})
end

-- INPUT is the one section with a second axis: the registry already tags every
-- action with a device (Keyboard / Mouse / Misc), so the page splits on that
-- rather than running one list long enough to lose the Mouse binds at the
-- bottom. Each device is its own scroller; the header switches between them.
local INPUT_TABS = table.freeze({ "Keyboard", "Mouse", "Misc" })
local INPUT_HEADER_H = 56

local function buildInput(content: Frame)
	-- Container stands in for a page: selectSection only ever sets .Visible, so
	-- it does not care that this one is a Frame holding three scrollers.
	local container = Instance.new("Frame")
	container.Name = "INPUT"
	container.BackgroundTransparency = 1
	container.Size = UDim2.fromScale(1, 1)
	container.Visible = false
	container.Parent = content
	_pages["INPUT"] = container

	local header = Instance.new("Frame")
	header.Name = "DeviceTabs"
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, INPUT_HEADER_H)
	header.Parent = container
	pad(header, 0, CONTENT_PAD, 0, CONTENT_PAD)

	local rule = hairline(header, C.LineSoft)
	rule.AnchorPoint = Vector2.new(0, 1)
	rule.Position = UDim2.fromScale(0, 1)

	local tabRow = Instance.new("Frame")
	tabRow.BackgroundTransparency = 1
	tabRow.Size = UDim2.new(1, -220, 1, 0)
	tabRow.Parent = header
	local tabList = Instance.new("UIListLayout")
	tabList.FillDirection = Enum.FillDirection.Horizontal
	tabList.VerticalAlignment = Enum.VerticalAlignment.Center
	tabList.SortOrder = Enum.SortOrder.LayoutOrder
	tabList.Padding = UDim.new(0, 4)
	tabList.Parent = tabRow

	local panes: { [string]: ScrollingFrame } = {}
	local chips: { [string]: { btn: TextButton, plate: Frame, label: TextLabel } } = {}

	local function selectDevice(which: string)
		for name, sf in panes do
			sf.Visible = name == which
		end
		for name, chip in chips do
			local active = name == which
			chip.plate.Visible = active
			chip.label.TextColor3 = if active then C.Text else C.TextDim
		end
	end

	for i, name in INPUT_TABS do
		local b = Instance.new("TextButton")
		b.Name = name
		b.AutoButtonColor = false
		b.Text = ""
		b.BackgroundTransparency = 1
		b.Size = UDim2.fromOffset(128, 34)
		b.LayoutOrder = i
		b.Parent = tabRow

		local plate = Instance.new("Frame")
		plate.Size = UDim2.fromScale(1, 1)
		plate.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		plate.BackgroundTransparency = 0.86
		plate.BorderSizePixel = 0
		plate.Visible = false
		plate.Parent = b
		corner(plate, 8)
		stroke(plate, C.Line, 0.55)

		local lbl = text(b, tracked(string.upper(name)), 12, C.TextDim, Theme.Font.Bold)
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.TextXAlignment = Enum.TextXAlignment.Center
		lbl.ZIndex = 2

		local key = name
		b.Activated:Connect(function()
			SoundFX.play("Tab")
			selectDevice(key)
		end)
		chips[name] = { btn = b, plate = plate, label = lbl }
	end

	-- Built inline rather than via chromeButton: that helper is declared further
	-- down the file, so a call from here would resolve to a nil global.
	local reset = Instance.new("TextButton")
	reset.Name = "ResetInput"
	reset.AutoButtonColor = false
	reset.AnchorPoint = Vector2.new(1, 0.5)
	reset.Position = UDim2.new(1, 0, 0.5, 0)
	reset.Size = UDim2.fromOffset(0, 34)
	reset.AutomaticSize = Enum.AutomaticSize.X
	reset.Text = tracked("RESET INPUT SETTINGS")
	reset.TextSize = 11
	reset.FontFace = Theme.Font.Bold
	reset.TextColor3 = C.Text
	reset.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	reset.BackgroundTransparency = 0.92
	reset.BorderSizePixel = 0
	reset.Parent = header
	pad(reset, 0, 18, 0, 18)
	corner(reset, 8)
	local resetRing = stroke(reset, C.Line, 0.55)
	reset.MouseEnter:Connect(function()
		reset.BackgroundColor3 = C.Accent
		reset.BackgroundTransparency = 0.78
		resetRing.Color = C.Accent
		resetRing.Transparency = 0.4
	end)
	reset.MouseLeave:Connect(function()
		reset.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		reset.BackgroundTransparency = 0.92
		resetRing.Color = C.Line
		resetRing.Transparency = 0.55
	end)
	reset.Activated:Connect(function()
		SoundFX.play("Click")
		Settings.resetBinds()
	end)

	-- Same bones as newPage, but parented under the header and not registered as
	-- a section of its own.
	local function devicePane(name: string): PageCtx
		local sf = Instance.new("ScrollingFrame")
		sf.Name = name
		sf.Active = true
		sf.BackgroundTransparency = 1
		sf.BorderSizePixel = 0
		sf.Position = UDim2.fromOffset(0, INPUT_HEADER_H)
		sf.Size = UDim2.new(1, 0, 1, -INPUT_HEADER_H)
		sf.CanvasSize = UDim2.new()
		sf.AutomaticCanvasSize = Enum.AutomaticSize.Y
		sf.ScrollBarThickness = 2
		sf.ScrollBarImageColor3 = C.Line
		sf.ScrollBarImageTransparency = 0.45
		sf.Visible = false
		sf.Parent = container
		pad(sf, 2, CONTENT_PAD, 28, CONTENT_PAD)

		local list = Instance.new("UIListLayout")
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.Padding = UDim.new(0, 0)
		list.Parent = sf

		panes[name] = sf
		return { frame = sf, order = 0, groupIndex = 0, rowInGroup = 0 }
	end

	local ctx: { [string]: PageCtx } = {}
	local lastGroup: { [string]: string } = {}
	for _, name in INPUT_TABS do
		ctx[name] = devicePane(name)
	end

	for _, def in Settings.actions() do
		local p = ctx[def.tab]
		if not p then continue end
		local name = string.upper(def.section)
		if name ~= lastGroup[def.tab] then
			lastGroup[def.tab] = name
			group(p, name)
		end
		bindRow(p, def)
	end

	-- Edge scrolling is a mouse behaviour, not a binding, so it rides with Misc
	-- where the design puts it.
	group(ctx.Misc, "OPTIONS")
	toggleRow(ctx.Misc, "Edge scrolling", "Push the mouse to a screen edge to pan.", "edgeScroll")

	selectDevice("Keyboard")
end

-- ------------------------------------------------------------ chrome --

local function chromeButton(parent: GuiObject, labelText: string, filled: boolean): (TextButton, UIStroke)
	local b = Instance.new("TextButton")
	b.Name = labelText
	b.AutoButtonColor = false
	b.Text = tracked(labelText)
	b.TextSize = 13
	b.FontFace = Theme.Font.Bold
	b.TextColor3 = if filled then C.Knob else C.TextDim
	b.BackgroundColor3 = if filled then C.Accent else C.Panel
	b.BackgroundTransparency = if filled then 0 else 1
	b.BorderSizePixel = 0
	b.AutomaticSize = Enum.AutomaticSize.X
	b.Size = UDim2.fromOffset(0, 46)
	b.Parent = parent
	pad(b, 0, 36, 0, 36)
	corner(b, 999)
	local ring = stroke(b, C.Line, if filled then 1 else 0.3)
	return b, ring
end

local function build()
	if _built then
		return
	end
	_built = true

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "SettingsUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = Theme.Layer.Menu + 10
	gui.Enabled = false
	gui.Parent = playerGui
	_gui = gui
	HudScale.attach(gui)

	local scrim = Instance.new("TextButton")
	scrim.Name = "Scrim"
	scrim.AutoButtonColor = false
	scrim.Text = ""
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.BackgroundColor3 = C.Veil
	scrim.BackgroundTransparency = 1
	scrim.BorderSizePixel = 0
	-- Deliberately NOT click-to-dismiss: a stray click on the backdrop used to
	-- throw away the page mid-edit. The back button and ESC are the only exits.
	scrim.Active = true
	scrim.Parent = gui
	_scrim = scrim

	local page = Instance.new("CanvasGroup")
	page.Name = "Page"
	page.Size = UDim2.fromScale(1, 1)
	page.BackgroundTransparency = 1
	page.GroupTransparency = 1
	page.Parent = gui
	_page = page
	pad(page, PAD_TOP, PAD_X, 24, PAD_X)

	-- Header ------------------------------------------------------------
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, HEADER_H)
	header.Parent = page

	-- The same back chip + title every menu page opens with (MenuScreenView).
	MenuScreenView.header(header, "Settings", function()
		SettingsPanel.Close()
	end)

	-- The section name is already the selected tab on the rail; the header is
	-- just the page title. Kept as a hidden stub so selectSection still writes it.
	local eyebrow = text(header, "", 11, C.Accent, Theme.Font.Bold)
	eyebrow.Visible = false
	eyebrow.Size = UDim2.fromOffset(0, 0)
	_eyebrow = eyebrow

	-- ESC and the caret both close the page; the design does not spell it out.
	local escBox = text(header, "", 11, C.TextDim, Theme.Font.Bold)
	escBox.Visible = false

	local unsaved = Instance.new("Frame")
	unsaved.Name = "Unsaved"
	unsaved.BackgroundTransparency = 1
	unsaved.AnchorPoint = Vector2.new(1, 0)
	unsaved.Position = UDim2.new(1, 0, 0, 6)
	unsaved.Size = UDim2.fromOffset(110, 32)
	unsaved.Visible = false
	unsaved.Parent = header
	_unsavedChip = unsaved

	local dot = Instance.new("Frame")
	dot.Name = "Dot"
	dot.BackgroundColor3 = C.Accent
	dot.BorderSizePixel = 0
	dot.AnchorPoint = Vector2.new(0, 0.5)
	dot.Position = UDim2.new(0, 0, 0.5, 0)
	dot.Size = UDim2.fromOffset(9, 9)
	dot.Parent = unsaved
	corner(dot, 1)

	local unsavedText = text(unsaved, tracked("UNSAVED"), 11, C.Accent, Theme.Font.Bold)
	unsavedText.Position = UDim2.fromOffset(17, 0)
	unsavedText.Size = UDim2.new(1, -17, 1, 0)

	-- No rule under the header: the two cards below carry the structure.

	-- Body --------------------------------------------------------------
	local body = Instance.new("Frame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Position = UDim2.fromOffset(0, HEADER_H + 24)
	body.Size = UDim2.new(1, 0, 1, -(HEADER_H + 24 + FOOTER_H))
	body.Parent = page

	local rail = Instance.new("Frame")
	rail.Name = "Rail"

	rail.BorderSizePixel = 0
	rail.Size = UDim2.new(0, SIDEBAR_W, 1, 0)
	-- Frames do not block input: without Active the scrim behind eats clicks
	-- that miss a control.
	rail.Active = true
	rail.Parent = body
	-- Both cards are ordinary game panels: Kit.Glass paints them from Theme.Glass,
	-- keeps them on the UI-transparency slider, and frosts them when the player
	-- has frostedGlass on.
	local railEdge = Glass.apply(rail, CARD_RADIUS)
	railEdge.Color = GLASS_EDGE
	railEdge.Transparency = GLASS_EDGE_T

	-- No caption over the rail: the five names are self-evident and the design
	-- starts them flush with the top of the card.
	local tabHolder = Instance.new("Frame")
	tabHolder.Name = "Tabs"
	tabHolder.BackgroundTransparency = 1
	tabHolder.Position = UDim2.fromOffset(14, 14)
	tabHolder.Size = UDim2.new(1, -28, 1, -126)
	tabHolder.Parent = rail

	local tabList = Instance.new("UIListLayout")
	tabList.SortOrder = Enum.SortOrder.LayoutOrder
	tabList.Padding = UDim.new(0, 0)
	tabList.Parent = tabHolder

	local content = Instance.new("Frame")
	content.Name = "Content"

	content.BorderSizePixel = 0
	content.Position = UDim2.fromOffset(SIDEBAR_W + GUTTER, 0)
	content.Size = UDim2.new(1, -(SIDEBAR_W + GUTTER), 1, 0)
	content.ClipsDescendants = true
	content.Active = true
	content.Parent = body
	local contentEdge = Glass.apply(content, CARD_RADIUS)
	contentEdge.Color = GLASS_EDGE
	contentEdge.Transparency = GLASS_EDGE_T

	-- Keyboard hints, pinned to the bottom of the rail.
	local hints = Instance.new("Frame")
	hints.Name = "Hints"
	hints.BackgroundTransparency = 1
	hints.AnchorPoint = Vector2.new(0, 1)
	hints.Position = UDim2.new(0, 0, 1, -18)
	hints.Size = UDim2.new(1, 0, 0, 74)
	hints.Parent = rail

	hairline(hints, C.LineSoft)

	local function hintLine(y: number, keys: string, what: string, font: Font)
		local cap = text(hints, keys, 10, C.TextDim, font)
		cap.Position = UDim2.fromOffset(20, y)
		cap.Size = UDim2.fromOffset(44, 22)
		cap.TextXAlignment = Enum.TextXAlignment.Center
		cap.BackgroundTransparency = 0
		cap.BackgroundColor3 = C.Raised
		cap.TextTruncate = Enum.TextTruncate.None
		corner(cap, 3)
		stroke(cap, C.Line, 0.4)

		local what2 = text(hints, tracked(what), 10, C.TextFaint, Theme.Font.Bold)
		what2.Position = UDim2.fromOffset(74, y)
		what2.Size = UDim2.new(1, -84, 0, 22)
	end

	hintLine(18, "Q / E", "SWITCH SECTION", Theme.Font.Bold)
	hintLine(46, "\u{2190} \u{2192}", "ADJUST VALUE", GLYPH_FONT)

	-- Dropdown lists draw here so the scrolling content cannot clip them.
	local layer = Instance.new("Frame")
	layer.Name = "MenuLayer"
	layer.BackgroundTransparency = 1
	layer.Size = UDim2.fromScale(1, 1)
	layer.ZIndex = 50
	layer.Parent = page
	_menuLayer = layer

	-- Footer ------------------------------------------------------------
	local footer = Instance.new("Frame")
	footer.Name = "Footer"
	footer.BackgroundTransparency = 1
	footer.AnchorPoint = Vector2.new(0, 1)
	footer.Position = UDim2.new(0, 0, 1, 0)
	footer.Size = UDim2.new(1, 0, 0, FOOTER_H)
	footer.Parent = page

	hairline(footer, C.Line)

	local status = text(footer, "", 11, C.TextFaint, Theme.Font.Bold)
	status.Position = UDim2.fromOffset(0, 22)
	status.Size = UDim2.new(1, -420, 0, 32)
	_statusLabel = status

	local actions = Instance.new("Frame")
	actions.Name = "Actions"
	actions.BackgroundTransparency = 1
	actions.AnchorPoint = Vector2.new(1, 0)
	actions.Position = UDim2.new(1, 0, 0, 18)
	actions.AutomaticSize = Enum.AutomaticSize.X
	actions.Size = UDim2.fromOffset(0, 38)
	actions.Parent = footer

	local actionList = Instance.new("UIListLayout")
	actionList.FillDirection = Enum.FillDirection.Horizontal
	actionList.SortOrder = Enum.SortOrder.LayoutOrder
	actionList.VerticalAlignment = Enum.VerticalAlignment.Center
	actionList.Padding = UDim.new(0, 10)
	actionList.Parent = actions

	local revertBtn, revertRing = chromeButton(actions, "REVERT CHANGES", false)
	revertBtn.LayoutOrder = 1
	local applyBtn = chromeButton(actions, "APPLY", true)
	applyBtn.LayoutOrder = 2

	-- APPLY stays accent-filled in both states, as the design has it, and is
	-- simply inert when there is nothing pending. Only REVERT dims.
	_setApplyEnabled = function(enabled: boolean)
		revertBtn.TextColor3 = if enabled then C.Text else C.TextDim
		revertRing.Transparency = if enabled then 0.15 else 0.45
	end

	applyBtn.MouseEnter:Connect(function()
		applyBtn.BackgroundColor3 = C.AccentHover
	end)
	applyBtn.MouseLeave:Connect(function()
		applyBtn.BackgroundColor3 = C.Accent
	end)
	revertBtn.MouseEnter:Connect(function()
		if _dirty then
			revertRing.Color = C.Accent
		end
	end)
	revertBtn.MouseLeave:Connect(function()
		revertRing.Color = C.Line
		revertBtn.TextColor3 = if _dirty then C.Text else C.TextDim
	end)

	applyBtn.Activated:Connect(function()
		if not _dirty then
			return
		end
		SoundFX.play("Click")
		SettingsClient.flush()
		snapshot()
		refreshDirty()
	end)

	revertBtn.Activated:Connect(function()
		if not _dirty then
			return
		end
		SoundFX.play("Click")
		-- Rows redraw off their own Settings.onChanged subscriptions, so putting
		-- the values back is the whole of the undo.
		for key, value in _saved do
			Settings.set(key, value)
		end
		Settings.loadBinds(_savedBinds)
		refreshDirty()
	end)

	-- Sections ----------------------------------------------------------
	buildGraphics(content)
	buildGameplay(content)
	buildAccess(content)
	buildAudio(content)
	buildInterface(content)
	buildInput(content)

	local function sectionAvailable(name: string): boolean
		return name ~= "ACCESS" or _accessAvailable
	end

	-- `dir` is which way the player was moving, so Q/E steps OVER a section that is not
	-- here rather than landing on a blank page. Bounded by #SECTIONS, and GRAPHICS can
	-- never be hidden, so the walk always lands somewhere.
	local function selectSection(index: number, dir: number?)
		local step = if dir and dir < 0 then -1 else 1
		index = ((index - 1) % #SECTIONS) + 1
		for _ = 1, #SECTIONS do
			if sectionAvailable(SECTIONS[index]) then break end
			index = ((index - 1 + step) % #SECTIONS) + 1
		end
		_sectionIndex = index
		closeOpenMenu()
		for i, name in SECTIONS do
			local sf = _pages[name]
			if sf then
				sf.Visible = i == index
			end
			local tab = _tabs[name]
			if tab then
				local active = i == index
				tab.frame.Visible = sectionAvailable(name)
				tab.bar.Visible = active
				tab.frame.BackgroundTransparency = if active then 0.89 else 1
				tab.name.TextColor3 = if active then C.Text else C.TextDim
				tab.num.TextColor3 = if active then C.Accent else C.TextFaint
			end
		end
		eyebrow.Text = tracked("SETTINGS \u{2014} " .. SECTIONS[index])
	end

	setAccessVisible = function(on: boolean)
		if _accessAvailable == on then
			return
		end
		_accessAvailable = on
		-- Re-runs the rail either way; if the page being taken away is the one on screen,
		-- the walk in selectSection moves off it.
		selectSection(if on then _sectionIndex else 1)
	end

	for i, name in SECTIONS do
		local b = Instance.new("TextButton")
		b.Name = name
		b.AutoButtonColor = false
		b.Text = ""
		-- Active row is a soft white plate, not an accent wash: the orange is
		-- spent on the 2px bar so only one thing on the rail is coloured.
		b.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		b.BackgroundTransparency = 1
		b.BorderSizePixel = 0
		b.Size = UDim2.new(1, 0, 0, 48)
		b.LayoutOrder = i
		b.Parent = tabHolder
		corner(b, 9)

		local bar = Instance.new("Frame")
		bar.Name = "Bar"
		bar.BackgroundColor3 = C.Accent
		bar.BorderSizePixel = 0
		bar.Position = UDim2.fromOffset(0, 12)
		bar.Size = UDim2.new(0, 2, 1, -24)
		bar.Visible = false
		bar.Parent = b
		corner(bar, 1)

		-- Unnumbered: the rail is five plain names, the active one carrying the
		-- plate and the accent bar. `num` is kept as a hidden stub so selectSection
		-- can keep colouring it without a nil check.
		local num = text(b, "", 11, C.TextFaint, Theme.Font.Bold)
		num.Visible = false
		num.Size = UDim2.fromOffset(0, 0)

		local nm = text(b, tracked(name), 14, C.TextDim, Theme.Font.Bold)
		nm.Position = UDim2.fromOffset(22, 0)
		nm.Size = UDim2.new(1, -32, 1, 0)

		b.MouseEnter:Connect(function()
			if _sectionIndex ~= i then
				b.BackgroundTransparency = 0.94
				nm.TextColor3 = C.Text
			end
		end)
		b.MouseLeave:Connect(function()
			if _sectionIndex ~= i then
				b.BackgroundTransparency = 1
				nm.TextColor3 = C.TextDim
			end
		end)
		b.Activated:Connect(function()
			SoundFX.play("Click")
			selectSection(i)
		end)

		_tabs[name] = { frame = b, bar = bar, name = nm, num = num }
	end

	selectSection(1)

	-- Input -------------------------------------------------------------
	UserInputService.InputBegan:Connect(function(input, processed)
		if not _open or processed or _capturing then
			return
		end
		local key = input.KeyCode
		if key == Enum.KeyCode.Escape then
			SettingsPanel.Close()
		elseif key == Enum.KeyCode.Q then
			SoundFX.play("Click")
			selectSection(_sectionIndex - 1, -1)
		elseif key == Enum.KeyCode.E then
			SoundFX.play("Click")
			selectSection(_sectionIndex + 1, 1)
		elseif key == Enum.KeyCode.Left and _focus then
			(_focus :: Control).nudge(-1)
		elseif key == Enum.KeyCode.Right and _focus then
			(_focus :: Control).nudge(1)
		end
	end)

	-- One drag owner for every slider on the page, rather than two global
	-- connections per row.
	UserInputService.InputChanged:Connect(function(input)
		if _drag and input.UserInputType == Enum.UserInputType.MouseMovement then
			(_drag :: (number) -> ())(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			_drag = nil
		end
	end)

	-- A bind change can create or clear a conflict on a row that was not the
	-- one edited, so every bind row redraws.
	Settings.onBindChanged(function()
		for _, fn in _bindRenders do
			fn()
		end
		refreshDirty()
	end)
	for key in Settings.defaults() do
		Settings.onChanged(key, refreshDirty)
	end
end

-- ------------------------------------------------------------ API --

function SettingsPanel.Open()
	-- Pulled fresh on every open: another admin may have changed the list meanwhile.
	task.defer(refreshAccess)
	build()
	if _open then
		return
	end
	_open = true
	UIEvents.SettingsOpened:Fire() -- overlays close; the main menu hides its buttons

	-- Re-read storage on every open: it only changes when the city saves, so polling it
	-- while the page sits closed would be pure waste.
	refreshMemoryMeter()

	-- Everything edited from here is live but unsaved until APPLY.
	snapshot()
	SettingsClient.setHold(true)
	refreshDirty()

	local gui = _gui :: ScreenGui
	local scrim = _scrim :: TextButton
	local page = _page :: CanvasGroup

	-- Hide every other ScreenGui (HUD, docks, tooltips) so Settings owns the
	-- screen. The main menu is spared so its backdrop still shows through.
	table.clear(_hidden)
	for _, child in Players.LocalPlayer:WaitForChild("PlayerGui"):GetChildren() do
		if child:IsA("ScreenGui") and child ~= gui and child.Enabled and child.Name ~= MAIN_MENU_GUI then
			child.Enabled = false
			table.insert(_hidden, child)
		end
	end

	local menu = Players.LocalPlayer.PlayerGui:FindFirstChild(MAIN_MENU_GUI)
	local buttons = if menu then menu:FindFirstChild(MAIN_MENU_BUTTONS) else nil
	if buttons and buttons:IsA("GuiObject") and buttons.Visible then
		buttons.Visible = false
		_hiddenMenu = buttons
	end
	local backdrop = if menu then menu:FindFirstChild(MAIN_MENU_BACKDROP) else nil
	if backdrop and backdrop:IsA("ImageLabel") then
		_dimmedBackdrop = backdrop
		UITween.to(backdrop, "Modal", { ImageColor3 = BACKDROP_DIM })
	end

	-- Roblox cannot blur UI, so this softens the 3D scene behind the page.
	local blur = _blur
	if not blur then
		blur = Instance.new("BlurEffect")
		blur.Name = "SettingsBlur"
		blur.Size = 0
		blur.Parent = Lighting
		_blur = blur
	end
	UITween.to(blur, "Modal", { Size = BLUR_SIZE })

	gui.Enabled = true
	scrim.BackgroundTransparency = 1
	page.GroupTransparency = 1
	UITween.to(scrim, "Modal", { BackgroundTransparency = VEIL_TRANSPARENCY })
	UITween.to(page, "Modal", { GroupTransparency = 0 })
end

function SettingsPanel.Close()
	if not _open then
		return
	end
	_open = false
	stopCapture()
	closeOpenMenu()

	-- Leaving with changes pending writes them. The page stages the profile
	-- write; it does not gamble the player's edits on them spotting APPLY.
	if _dirty then
		SettingsClient.flush()
		snapshot()
		refreshDirty()
	end
	SettingsClient.setHold(false)
	UIEvents.SettingsClosed:Fire()

	for _, sg in _hidden do
		if sg.Parent then
			sg.Enabled = true
		end
	end
	table.clear(_hidden)
	if _hiddenMenu then
		(_hiddenMenu :: GuiObject).Visible = true
		_hiddenMenu = nil
	end
	if _dimmedBackdrop then
		UITween.to(_dimmedBackdrop :: ImageLabel, "Modal", { ImageColor3 = Color3.new(1, 1, 1) })
		_dimmedBackdrop = nil
	end
	if _blur then
		UITween.to(_blur :: BlurEffect, "Modal", { Size = 0 })
	end

	local gui = _gui :: ScreenGui
	local scrim = _scrim :: TextButton
	local page = _page :: CanvasGroup
	UITween.to(scrim, "Modal", { BackgroundTransparency = 1 })
	local tween = UITween.to(page, "Modal", { GroupTransparency = 1 })
	tween.Completed:Once(function()
		if not _open then
			gui.Enabled = false
		end
	end)
end

function SettingsPanel.IsOpen(): boolean
	return _open
end

return SettingsPanel
