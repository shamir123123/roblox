--!strict
-- MenuScreenView: the full-screen menu page behind New Game and Load Game. Two frosted
-- glass panels (the HUD's own Kit.Glass) under a back chip + title: a wide left panel with
-- a pill tab bar, and a detail panel on the right with its action pinned to the foot.
-- Pill controls, the accent-gradient action and the Kit toggle are the game's language.
-- Pure builders: no state, nothing runs on require. SettingsPanel borrows `header`.

local TweenService = game:GetService("TweenService")

local playerScripts = script.Parent.Parent
local uiFolder = playerScripts:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local Glass = require(uiFolder:WaitForChild("Kit"):WaitForChild("Glass"))
local Toggle = require(uiFolder:WaitForChild("Kit"):WaitForChild("Toggle"))
local SoundFX = require(playerScripts:WaitForChild("Core"):WaitForChild("SoundFX"))

local MenuScreenView = {}

-- Montserrat has no arrow, tick or cross glyphs; Arial carries them.
local GLYPH_FONT = Font.new("rbxasset://fonts/families/Arial.json", Enum.FontWeight.Bold)
MenuScreenView.GLYPH_FONT = GLYPH_FONT

local PAD_X = 56
local HEADER_Y = 52
local HEADER_H = 46
local BODY_TOP = 122
local BODY_BOTTOM = 36
local GAP = 16
local LEFT_SHARE = 0.6
local PANEL_R = 14
local BAR_H = 64
local FOOTER_H = 88
local FADE = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HOVER = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local C = Theme.Color
local THIN = utf8.char(0x2009)

-- Roblox has no letter-spacing, so tracked caps are spelled with thin spaces.
local function tracked(s: string): string
	local out: { string } = {}
	for _, code in utf8.codes(string.upper(s)) do
		table.insert(out, utf8.char(code))
	end
	return table.concat(out, THIN)
end
MenuScreenView.tracked = tracked

local function corner(inst: GuiObject, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = inst
end
MenuScreenView.corner = corner

local function stroke(inst: GuiObject, color: Color3, transparency: number, thickness: number?): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Transparency = transparency
	s.Thickness = thickness or 1
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = inst
	return s
end
MenuScreenView.stroke = stroke

local function pad(inst: GuiObject, v: number, h: number)
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, v)
	p.PaddingBottom = UDim.new(0, v)
	p.PaddingLeft = UDim.new(0, h)
	p.PaddingRight = UDim.new(0, h)
	p.Parent = inst
end

local function label(parent: Instance, text: string, font: Font, size: number, color: Color3): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.BorderSizePixel = 0
	l.FontFace = font
	l.TextSize = size
	l.TextColor3 = color
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextTruncate = Enum.TextTruncate.AtEnd
	l.Text = text
	l.Parent = parent
	return l
end
MenuScreenView.label = label

local function list(parent: Instance, gap: number, horizontal: boolean?): UIListLayout
	local l = Instance.new("UIListLayout")
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Padding = UDim.new(0, gap)
	if horizontal then
		l.FillDirection = Enum.FillDirection.Horizontal
		l.VerticalAlignment = Enum.VerticalAlignment.Center
	end
	l.Parent = parent
	return l
end
MenuScreenView.list = list

-- Round outline chip with a caret: the way back on every menu page.
function MenuScreenView.backChip(parent: Instance, onClick: () -> ()): TextButton
	local b = Instance.new("TextButton")
	b.Name = "Back"
	b.AutoButtonColor = false
	b.BackgroundColor3 = C.Bg
	b.BackgroundTransparency = 0.4
	b.Size = UDim2.fromOffset(HEADER_H, HEADER_H)
	b.FontFace = GLYPH_FONT
	b.Text = "\u{2039}"
	b.TextSize = 30
	b.TextColor3 = C.TextPrimary
	b.Parent = parent
	corner(b, HEADER_H)
	local ring = stroke(b, C.TextPrimary, 0.5, 1.5)
	b.MouseEnter:Connect(function()
		ring.Color = C.Accent
		ring.Transparency = 0
		b.TextColor3 = C.Accent
	end)
	b.MouseLeave:Connect(function()
		ring.Color = C.TextPrimary
		ring.Transparency = 0.5
		b.TextColor3 = C.TextPrimary
	end)
	b.Activated:Connect(function()
		SoundFX.play("Click")
		onClick()
	end)
	return b
end

-- Back chip + page title with a short accent rule under it, filling `parent`'s top
-- HEADER_H px. Returns the title so a page with stages can rename itself.
function MenuScreenView.header(parent: Instance, title: string, onBack: () -> ()): TextLabel
	local head = Instance.new("Frame")
	head.Name = "Header"
	head.BackgroundTransparency = 1
	head.Size = UDim2.new(1, 0, 0, HEADER_H)
	head.Parent = parent
	MenuScreenView.backChip(head, onBack)
	local t = label(head, string.upper(title), Theme.Font.Bold, 32, C.TextPrimary)
	t.Name = "Title"
	t.AutomaticSize = Enum.AutomaticSize.X
	t.TextTruncate = Enum.TextTruncate.None
	t.Position = UDim2.fromOffset(HEADER_H + 18, 0)
	t.Size = UDim2.fromOffset(0, HEADER_H - 6)
	local rule = Instance.new("Frame")
	rule.Name = "Rule"
	rule.BackgroundColor3 = C.Accent
	rule.BorderSizePixel = 0
	rule.Position = UDim2.new(0, HEADER_H + 19, 1, -3)
	rule.Size = UDim2.fromOffset(36, 3)
	rule.Parent = head
	corner(rule, 2)
	return t
end

export type Screen = {
	gui: ScreenGui,
	title: TextLabel,
	barLabel: TextLabel,
	tabs: Frame,
	left: Frame,
	right: Frame,
	footer: Frame,
	show: () -> (),
	hide: () -> (),
}

-- The page: veil, header, left glass panel (caption + tab slot, then body) and right
-- glass panel (body + footer). Built disabled; show/hide fade it.
function MenuScreenView.screen(parent: Instance, name: string, title: string, onBack: () -> ()): Screen
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = Theme.Layer.Menu + 5
	gui.Enabled = false
	gui.Parent = parent

	-- Active so a click that misses every control dies here instead of reaching the menu.
	local veil = Instance.new("Frame")
	veil.Name = "Veil"
	veil.BackgroundColor3 = C.Scrim
	veil.BackgroundTransparency = 0.3
	veil.BorderSizePixel = 0
	veil.Size = UDim2.fromScale(1, 1)
	veil.Active = true
	veil.Parent = gui

	local page = Instance.new("CanvasGroup")
	page.Name = "Page"
	page.BackgroundTransparency = 1
	page.Size = UDim2.fromScale(1, 1)
	page.Parent = gui

	local headHolder = Instance.new("Frame")
	headHolder.BackgroundTransparency = 1
	headHolder.Position = UDim2.fromOffset(PAD_X, HEADER_Y)
	headHolder.Size = UDim2.new(1, -2 * PAD_X, 0, HEADER_H)
	headHolder.Parent = page
	local titleLabel = MenuScreenView.header(headHolder, title, onBack)

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Position = UDim2.fromOffset(PAD_X, BODY_TOP)
	body.Size = UDim2.new(1, -2 * PAD_X, 1, -(BODY_TOP + BODY_BOTTOM))
	body.Parent = page

	local leftPanel = Instance.new("Frame")
	leftPanel.Name = "LeftPanel"
	leftPanel.Active = true
	leftPanel.Size = UDim2.new(LEFT_SHARE, -GAP / 2, 1, 0)
	leftPanel.Parent = body
	Glass.apply(leftPanel, PANEL_R)

	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.BackgroundTransparency = 1
	bar.Size = UDim2.new(1, 0, 0, BAR_H)
	bar.Parent = leftPanel
	pad(bar, 0, 22)
	local barLabel = label(bar, "", Theme.Font.Bold, 12, C.TextSecondary)
	barLabel.Size = UDim2.new(0.4, 0, 1, 0)
	local tabs = Instance.new("Frame")
	tabs.Name = "Tabs"
	tabs.BackgroundTransparency = 1
	tabs.AnchorPoint = Vector2.new(1, 0.5)
	tabs.Position = UDim2.fromScale(1, 0.5)
	tabs.AutomaticSize = Enum.AutomaticSize.X
	tabs.Size = UDim2.fromOffset(0, 36)
	tabs.Parent = bar
	local rule = Instance.new("Frame")
	rule.BackgroundColor3 = C.StrokeSoft
	rule.BackgroundTransparency = 0.5
	rule.BorderSizePixel = 0
	rule.Position = UDim2.new(0, 22, 0, BAR_H)
	rule.Size = UDim2.new(1, -44, 0, 1)
	rule.Parent = leftPanel

	local left = Instance.new("Frame")
	left.Name = "Left"
	left.BackgroundTransparency = 1
	left.Position = UDim2.fromOffset(0, BAR_H + 1)
	left.Size = UDim2.new(1, 0, 1, -(BAR_H + 1))
	left.ClipsDescendants = true
	left.Parent = leftPanel

	local rightPanel = Instance.new("Frame")
	rightPanel.Name = "RightPanel"
	rightPanel.Active = true
	rightPanel.AnchorPoint = Vector2.new(1, 0)
	rightPanel.Position = UDim2.fromScale(1, 0)
	rightPanel.Size = UDim2.new(1 - LEFT_SHARE, -GAP / 2, 1, 0)
	rightPanel.ClipsDescendants = true
	rightPanel.Parent = body
	Glass.apply(rightPanel, PANEL_R)

	local right = Instance.new("Frame")
	right.Name = "Right"
	right.BackgroundTransparency = 1
	right.Size = UDim2.new(1, 0, 1, -FOOTER_H)
	right.Parent = rightPanel

	local footer = Instance.new("Frame")
	footer.Name = "Footer"
	footer.BackgroundTransparency = 1
	footer.AnchorPoint = Vector2.new(0, 1)
	footer.Position = UDim2.fromScale(0, 1)
	footer.Size = UDim2.new(1, 0, 0, FOOTER_H)
	footer.Parent = rightPanel
	pad(footer, 18, 18)
	local fl = list(footer, 10, true)
	fl.HorizontalFlex = Enum.UIFlexAlignment.Fill

	local fade: Tween? = nil
	local function show()
		if fade then fade:Cancel() end
		gui.Enabled = true
		page.GroupTransparency = 1
		local t = TweenService:Create(page, FADE, { GroupTransparency = 0 })
		fade = t
		t:Play()
	end
	local function hide()
		if fade then fade:Cancel() end
		local t = TweenService:Create(page, FADE, { GroupTransparency = 1 })
		fade = t
		t.Completed:Connect(function(state)
			if state == Enum.PlaybackState.Completed then gui.Enabled = false end
		end)
		t:Play()
	end

	return {
		gui = gui,
		title = titleLabel,
		barLabel = barLabel,
		tabs = tabs,
		left = left,
		right = right,
		footer = footer,
		show = show,
		hide = hide,
	}
end

export type Segment = {
	Instance: Frame,
	select: (number) -> (),
	setEnabled: (boolean) -> (),
}

-- Pills in a row, one lit. `boxed` sits them in a dark capsule track (tab bars);
-- unboxed they stand alone (form choices). `onSelect` fires on clicks only.
function MenuScreenView.pills(parent: Instance, labels: { string }, boxed: boolean, onSelect: (number) -> ()): Segment
	local holder = Instance.new("Frame")
	holder.Name = "Pills"
	holder.BackgroundColor3 = C.BgPress
	holder.BackgroundTransparency = if boxed then 0.25 else 1
	holder.AutomaticSize = Enum.AutomaticSize.X
	holder.Size = UDim2.fromOffset(0, 36)
	holder.Parent = parent
	corner(holder, 999)
	if boxed then
		stroke(holder, C.StrokeSoft, 0.4)
		local p = Instance.new("UIPadding")
		p.PaddingLeft = UDim.new(0, 3)
		p.PaddingRight = UDim.new(0, 3)
		p.Parent = holder
	end
	list(holder, if boxed then 2 else 8, true)

	local enabled = true
	local current = 1
	local items: { { b: TextButton, ring: UIStroke? } } = {}
	local function paint(hovered: number?)
		for i, it in items do
			local on = i == current
			it.b.BackgroundColor3 = if on then C.Accent elseif hovered == i then C.BgHover else C.Bg
			it.b.BackgroundTransparency = if on then (if enabled then 0 else 0.55)
				elseif boxed then (if hovered == i then 0.3 else 1)
				else (if hovered == i then 0.15 else 0.5)
			it.b.TextColor3 = if on then C.OnAccent elseif enabled then C.TextPrimary else C.TextDisabled
			if it.ring then it.ring.Transparency = if on then 1 else 0.25 end
		end
	end
	for i, text in labels do
		local b = Instance.new("TextButton")
		b.Name = text
		b.AutoButtonColor = false
		b.BorderSizePixel = 0
		b.AutomaticSize = Enum.AutomaticSize.X
		b.Size = UDim2.fromOffset(0, if boxed then 30 else 34)
		b.FontFace = Theme.Font.Header
		b.TextSize = if boxed then 13 else 14
		b.Text = if boxed then string.upper(text) else text
		b.LayoutOrder = i
		b.Parent = holder
		corner(b, 999)
		local p = Instance.new("UIPadding")
		p.PaddingLeft = UDim.new(0, 18)
		p.PaddingRight = UDim.new(0, 18)
		p.Parent = b
		items[i] = { b = b, ring = if boxed then nil else stroke(b, C.StrokeSoft, 0.25) }
		b.MouseEnter:Connect(function()
			if enabled then paint(i) end
		end)
		b.MouseLeave:Connect(function() paint() end)
		b.Activated:Connect(function()
			if not enabled or i == current then return end
			SoundFX.play("Click")
			current = i
			paint()
			onSelect(i)
		end)
	end
	paint()
	return {
		Instance = holder,
		select = function(i: number)
			current = i
			paint()
		end,
		setEnabled = function(on: boolean)
			enabled = on
			paint()
		end,
	}
end

export type ActionButton = { Instance: TextButton, setEnabled: (boolean) -> (), setText: (string) -> () }

-- Foot-of-panel action, stretched by the footer's flex. `primary` is the accent-gradient
-- pill; the other is a glass outline. The label is a child ABOVE the fill: a UIGradient on
-- the button itself would tint its text too.
function MenuScreenView.actionButton(parent: Instance, text: string, primary: boolean, order: number, onClick: () -> ()): ActionButton
	local b = Instance.new("TextButton")
	b.Name = text
	b.AutoButtonColor = false
	b.BorderSizePixel = 0
	b.Text = ""
	b.BackgroundColor3 = C.BgHover
	b.BackgroundTransparency = if primary then 1 else 0.35
	b.Size = UDim2.new(0, 10, 1, 0)
	b.LayoutOrder = order
	b.Parent = parent
	corner(b, 999)
	local ring = stroke(b, C.TextPrimary, if primary then 1 else 0.6)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = Color3.new(1, 1, 1)
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(1, 1)
	fill.Visible = primary
	fill.Parent = b
	corner(fill, 999)
	local g = Instance.new("UIGradient")
	g.Rotation = 90
	g.Color = Theme.AccentGradient
	g.Parent = fill

	local t = label(b, string.upper(text), Theme.Font.Bold, 18, if primary then C.OnAccent else C.TextPrimary)
	t.Name = "Label"
	t.TextXAlignment = Enum.TextXAlignment.Center
	t.Size = UDim2.fromScale(1, 1)
	t.ZIndex = 2

	local enabled = true
	b.MouseEnter:Connect(function()
		if not enabled then return end
		if primary then
			TweenService:Create(fill, HOVER, { BackgroundColor3 = Color3.fromRGB(255, 228, 208) }):Play()
		else
			ring.Transparency = 0.1
		end
	end)
	b.MouseLeave:Connect(function()
		TweenService:Create(fill, HOVER, { BackgroundColor3 = Color3.new(1, 1, 1) }):Play()
		ring.Transparency = if primary then 1 else 0.6
	end)
	b.Activated:Connect(function()
		if not enabled then return end
		SoundFX.play("Click")
		onClick()
	end)
	return {
		Instance = b,
		setEnabled = function(on: boolean)
			enabled = on
			t.TextTransparency = if on then 0 else 0.55
			fill.BackgroundTransparency = if on then 0 else 0.65
		end,
		setText = function(text2: string)
			t.Text = string.upper(text2)
		end,
	}
end

-- Section head inside a panel: small tracked caps.
function MenuScreenView.caption(parent: Instance, text: string, order: number): TextLabel
	local l = label(parent, tracked(text), Theme.Font.Bold, 11, C.TextSecondary)
	l.Size = UDim2.new(1, 0, 0, 18)
	l.LayoutOrder = order
	return l
end

-- KEY ........ value on a hairline: the detail table on the right panel.
function MenuScreenView.statRow(parent: Instance, key: string, order: number): TextLabel
	local row = Instance.new("Frame")
	row.Name = key
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 34)
	row.LayoutOrder = order
	row.Parent = parent
	local k = label(row, key, Theme.Font.Label, 15, C.TextSecondary)
	k.Size = UDim2.new(0.45, 0, 1, 0)
	local v = label(row, "", Theme.Font.Header, 15, C.TextPrimary)
	v.Name = "Value"
	v.TextXAlignment = Enum.TextXAlignment.Right
	v.AnchorPoint = Vector2.new(1, 0)
	v.Position = UDim2.fromScale(1, 0)
	v.Size = UDim2.new(0.55, 0, 1, 0)
	local rule = Instance.new("Frame")
	rule.BackgroundColor3 = C.StrokeSoft
	rule.BackgroundTransparency = 0.6
	rule.BorderSizePixel = 0
	rule.AnchorPoint = Vector2.new(0, 1)
	rule.Position = UDim2.fromScale(0, 1)
	rule.Size = UDim2.new(1, 0, 0, 1)
	rule.Parent = row
	return v
end

export type Hero = { image: EditableImage?, name: TextLabel, sub: TextLabel }

-- The picture at the top of a detail panel, its name set over a dark fade at the foot.
-- `img` is a MapPreview label the caller created.
function MenuScreenView.hero(parent: Instance, img: ImageLabel, order: number, height: number): Hero
	img.Name = "Hero"
	img.ScaleType = Enum.ScaleType.Crop
	img.Size = UDim2.new(1, 0, 0, height)
	img.LayoutOrder = order
	img.Parent = parent
	corner(img, 10)
	local shade = Instance.new("Frame")
	shade.Name = "Shade"
	shade.BackgroundColor3 = Color3.new(0, 0, 0)
	shade.BorderSizePixel = 0
	shade.AnchorPoint = Vector2.new(0, 1)
	shade.Position = UDim2.fromScale(0, 1)
	shade.Size = UDim2.new(1, 0, 0, 84)
	shade.Parent = img
	corner(shade, 10)
	local sg = Instance.new("UIGradient")
	sg.Rotation = 90
	sg.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(1, 0.2),
	})
	sg.Parent = shade
	local name = label(img, "", Theme.Font.Bold, 26, C.TextPrimary)
	name.Name = "Name"
	name.AnchorPoint = Vector2.new(0, 1)
	name.Position = UDim2.new(0, 16, 1, -30)
	name.Size = UDim2.new(1, -32, 0, 32)
	name.ZIndex = 2
	local sub = label(img, "", Theme.Font.Header, 13, C.Brand)
	sub.Name = "Sub"
	sub.AnchorPoint = Vector2.new(0, 1)
	sub.Position = UDim2.new(0, 17, 1, -12)
	sub.Size = UDim2.new(1, -32, 0, 18)
	sub.ZIndex = 2
	return { name = name, sub = sub }
end

export type ToggleRow = { set: (boolean) -> (), get: () -> boolean }

-- Title + note on the left, the game's capsule switch on the right.
function MenuScreenView.toggleRow(parent: Instance, title: string, note: string, order: number, onChange: (boolean) -> ()): ToggleRow
	local row = Instance.new("Frame")
	row.Name = title
	row.BackgroundTransparency = 1
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.Size = UDim2.new(1, 0, 0, 0)
	row.LayoutOrder = order
	row.Parent = parent
	local t = label(row, title, Theme.Font.Header, 16, C.TextPrimary)
	t.Size = UDim2.new(1, -90, 0, 24)
	local n = label(row, note, Theme.Font.Label, 13, C.TextSecondary)
	n.TextWrapped = true
	n.TextTruncate = Enum.TextTruncate.None
	n.TextYAlignment = Enum.TextYAlignment.Top
	n.AutomaticSize = Enum.AutomaticSize.Y
	n.Position = UDim2.fromOffset(0, 25)
	n.Size = UDim2.new(1, -90, 0, 0)
	local value = false
	local toggle = Toggle.new({ parent = row, value = false, onChange = function(on: boolean)
		value = on
		onChange(on)
	end })
	toggle.Instance.AnchorPoint = Vector2.new(1, 0)
	toggle.Instance.Position = UDim2.fromScale(1, 0)
	return {
		set = function(on: boolean)
			value = on
			toggle:Set(on)
		end,
		get = function()
			return value
		end,
	}
end

-- A rounded group inside a form: the dark card every set of related fields sits in.
function MenuScreenView.card(parent: Instance, order: number): Frame
	local f = Instance.new("Frame")
	f.Name = "Card"
	f.BackgroundColor3 = C.BgPress
	f.BackgroundTransparency = 0.35
	f.BorderSizePixel = 0
	f.AutomaticSize = Enum.AutomaticSize.Y
	f.Size = UDim2.new(1, 0, 0, 0)
	f.LayoutOrder = order
	f.Parent = parent
	corner(f, 12)
	stroke(f, C.StrokeSoft, 0.55)
	pad(f, 16, 18)
	list(f, 10)
	return f
end

-- Wrapped secondary copy.
function MenuScreenView.note(parent: Instance, text: string, order: number): TextLabel
	local l = label(parent, text, Theme.Font.Label, 14, C.TextSecondary)
	l.TextWrapped = true
	l.TextTruncate = Enum.TextTruncate.None
	l.TextYAlignment = Enum.TextYAlignment.Top
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.Size = UDim2.new(1, 0, 0, 0)
	l.LayoutOrder = order
	return l
end

-- Rounded dark text field that lights its edge in the accent while focused.
function MenuScreenView.textField(parent: Instance, placeholder: string, order: number): TextBox
	local box = Instance.new("TextBox")
	box.Name = "Field"
	box.BackgroundColor3 = C.Bg
	box.BackgroundTransparency = 0.2
	box.ClearTextOnFocus = false
	box.PlaceholderText = placeholder
	box.PlaceholderColor3 = C.TextDisabled
	box.Text = ""
	box.FontFace = Theme.Font.Header
	box.TextSize = 20
	box.TextColor3 = C.TextPrimary
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.Size = UDim2.new(1, 0, 0, 46)
	box.LayoutOrder = order
	box.Parent = parent
	corner(box, 10)
	local ring = stroke(box, C.StrokeSoft, 0.2)
	box.Focused:Connect(function()
		ring.Color = C.Accent
		ring.Transparency = 0
	end)
	box.FocusLost:Connect(function()
		ring.Color = C.StrokeSoft
		ring.Transparency = 0.2
	end)
	local p = Instance.new("UIPadding")
	p.PaddingLeft = UDim.new(0, 16)
	p.PaddingRight = UDim.new(0, 16)
	p.Parent = box
	return box
end

-- A padded vertical scroller for a form, a list or a detail column.
function MenuScreenView.scroller(parent: Instance, padV: number, padH: number, gap: number): ScrollingFrame
	local s = Instance.new("ScrollingFrame")
	s.BackgroundTransparency = 1
	s.BorderSizePixel = 0
	s.Size = UDim2.fromScale(1, 1)
	s.ScrollBarThickness = 3
	s.ScrollBarImageColor3 = C.StrokeSoft
	s.AutomaticCanvasSize = Enum.AutomaticSize.Y
	s.CanvasSize = UDim2.new()
	s.ScrollingDirection = Enum.ScrollingDirection.Y
	s.Parent = parent
	pad(s, padV, padH)
	list(s, gap)
	return s
end

-- Centred two-line message for an empty list.
function MenuScreenView.emptyState(parent: Instance, title: string, hint: string): Frame
	local f = Instance.new("Frame")
	f.Name = "Empty"
	f.BackgroundTransparency = 1
	f.Size = UDim2.fromScale(1, 1)
	f.Parent = parent
	local t = label(f, title, Theme.Font.Bold, 20, C.TextPrimary)
	t.TextXAlignment = Enum.TextXAlignment.Center
	t.AnchorPoint = Vector2.new(0.5, 1)
	t.Position = UDim2.fromScale(0.5, 0.45)
	t.Size = UDim2.new(1, -80, 0, 28)
	local h = label(f, hint, Theme.Font.Label, 14, C.TextSecondary)
	h.TextXAlignment = Enum.TextXAlignment.Center
	h.TextYAlignment = Enum.TextYAlignment.Top
	h.TextWrapped = true
	h.AnchorPoint = Vector2.new(0.5, 0)
	h.Position = UDim2.new(0.5, 0, 0.45, 8)
	h.Size = UDim2.new(1, -120, 0, 60)
	return f
end

return MenuScreenView
