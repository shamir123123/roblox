--!strict
-- UPDATE LOGS / CREDITS: a full-screen page off the main menu. Two tabs sharing
-- one layout -- an index card on the left, a scrolling body on the right --
-- because a release and a credits section render identically once you have a
-- title, a meta line and a list of named groups. UpdateLogData supplies both.
--
-- Opened from the main menu's UPDATE LOGS and CREDITS buttons. Owns the screen
-- while open (every other ScreenGui is hidden, the menu's buttons step aside),
-- and puts everything back on Close.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local UIEvents = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("UIEvents"))

local uiFolder = script.Parent.Parent
local Theme = require(uiFolder:WaitForChild("Theme"))
local UITween = require(uiFolder:WaitForChild("UITween"))
local HudScale = require(uiFolder:WaitForChild("HudScale"))
local Glass = require(uiFolder:WaitForChild("Kit"):WaitForChild("Glass"))
local SoundFX = require(uiFolder.Parent:WaitForChild("Core"):WaitForChild("SoundFX"))
local UpdateLogData = require(script.Parent:WaitForChild("UpdateLogData"))

local UpdateLogsPanel = {}

local GUI_NAME = "UpdateLogsPage"
local MAIN_MENU_GUI = "MainMenu"
local MAIN_MENU_BUTTONS = "Container"
local MAIN_MENU_BACKDROP = "MainMenuParallaxBackground"

-- The design puts this page on softened key art. Roblox cannot blur UI, and the
-- menu's backdrop IS UI (an ImageLabel), so the card frost has nothing to bite
-- on here -- it blurs the 3D scene, which the backdrop covers. Two stand-ins,
-- the same pair SettingsPanel uses: tint the backdrop down, and blur whatever 3D
-- does show through.
local BACKDROP_DIM = Color3.fromRGB(62, 66, 60)
local BLUR_SIZE = 24

-- PAD_TOP clears the Roblox topbar: the page ignores the GUI inset, so at 28 the back
-- arrow sat underneath the platform's own buttons.
local PAD_X, PAD_TOP, PAD_BOTTOM = 64, 76, 34
local NAV_W = 294
local GUTTER = 20
local ROW_H = 52

-- Group-name tones, straight off the design. Anything not listed reads neutral,
-- which is what the credits sections (DIRECTION, ART, ...) want.
local TONE: { [string]: Color3 } = {
	ADDED   = Color3.fromRGB(142, 224, 153),
	CHANGED = Color3.fromRGB(247, 169, 120),
	FIXED   = Color3.fromRGB(121, 195, 242),
}
local TONE_NEUTRAL = Color3.fromRGB(255, 255, 255)

local TABS = { "UPDATE LOGS", "CREDITS" }

local _gui: ScreenGui? = nil
local _page: CanvasGroup? = nil
local _open = false
local _tab = "UPDATE LOGS"
local _sel = { ["UPDATE LOGS"] = 1, CREDITS = 1 }
local _navRows: { { row: TextButton, plate: Frame, bar: Frame, name: TextLabel } } = {}
local _tabBtns: { [string]: { btn: TextButton, plate: Frame, label: TextLabel } } = {}
local _navLabel: TextLabel? = nil
local _body: ScrollingFrame? = nil
local _headKicker: TextLabel? = nil
local _headTitle: TextLabel? = nil
local _headMeta: TextLabel? = nil
local _hidden: { ScreenGui } = {}
local _hiddenMenu: GuiObject? = nil
local _escConn: RBXScriptConnection? = nil
local _dimmedBackdrop: ImageLabel? = nil
local _backdropColor: Color3? = nil
local _blur: BlurEffect? = nil

-- Montserrat has no letter-spacing control in Roblox, so wide tracking is faked
-- with thin spaces -- the same trick SettingsPanel uses for its section rail.
local THIN = utf8.char(0x2009)
local function tracked(s: string): string
	local out = {}
	for _, code in utf8.codes(s) do
		table.insert(out, utf8.char(code))
	end
	return table.concat(out, THIN)
end

local function corner(inst: GuiObject, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = inst
end

local function stroke(inst: GuiObject, color: Color3, transparency: number): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Transparency = transparency
	s.Thickness = 1
	s.Parent = inst
	return s
end

local function label(parent: GuiObject, txt: string, size: number, color: Color3, font: Font): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Text = txt
	l.TextSize = size
	l.TextColor3 = color
	l.FontFace = font
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Top
	l.Parent = parent
	return l
end

-- ---------------------------------------------------------------- content --

local function currentList(): { any }
	return if _tab == "UPDATE LOGS" then UpdateLogData.Versions else UpdateLogData.Credits
end

local function clear(inst: Instance)
	for _, c in inst:GetChildren() do
		if c:IsA("GuiObject") then c:Destroy() end
	end
end

-- One release / credits section rendered into the body: a run of named groups,
-- each a tone-coloured heading over diamond-bulleted lines.
local function renderBody()
	local body = _body
	if not body then return end
	clear(body)

	local entry = currentList()[_sel[_tab]]
	if not entry then
		-- Empty tab (credits, while the list is blank): clear the header too, or it keeps
		-- whatever the other tab last showed.
		local kicker, title, meta = _headKicker :: TextLabel, _headTitle :: TextLabel, _headMeta :: TextLabel
		kicker.Text = tracked(_tab)
		title.Text = "Nothing here yet"
		meta.Text = ""
		return
	end

	;(_headKicker :: TextLabel).Text =
		if _tab == "UPDATE LOGS" then tracked("VERSION " .. entry.version) else tracked("CREDITS")
	;(_headTitle :: TextLabel).Text = entry.title
	;(_headMeta :: TextLabel).Text =
		tracked(if _tab == "UPDATE LOGS" then entry.date else entry.meta)

	local order = 0
	for _, group in entry.groups do
		order += 1
		local head = Instance.new("Frame")
		head.BackgroundTransparency = 1
		head.Size = UDim2.new(1, 0, 0, 40)
		head.LayoutOrder = order
		head.Parent = body

		local name = label(head, tracked(group.name), 10, TONE[group.name] or TONE_NEUTRAL, Theme.Font.Bold)
		name.AnchorPoint = Vector2.new(0, 1)
		name.Position = UDim2.new(0, 0, 1, -8)
		name.Size = UDim2.fromOffset(220, 12)
		name.TextYAlignment = Enum.TextYAlignment.Center
		name.AutomaticSize = Enum.AutomaticSize.X

		local rule = Instance.new("Frame")
		rule.AnchorPoint = Vector2.new(1, 1)
		rule.Position = UDim2.new(1, 0, 1, -13)
		rule.Size = UDim2.new(1, -(name.TextBounds.X + 14), 0, 1)
		rule.BackgroundColor3 = Theme.Color.StrokeSoft
		rule.BackgroundTransparency = 0.55
		rule.BorderSizePixel = 0
		rule.Parent = head
		-- TextBounds is only valid once the label has laid out; re-fit next frame.
		name:GetPropertyChangedSignal("TextBounds"):Connect(function()
			rule.Size = UDim2.new(1, -(name.TextBounds.X + 14), 0, 1)
		end)

		for _, item in group.items do
			order += 1
			local rowFrame = Instance.new("Frame")
			rowFrame.BackgroundTransparency = 1
			rowFrame.Size = UDim2.new(1, 0, 0, 0)
			rowFrame.AutomaticSize = Enum.AutomaticSize.Y
			rowFrame.LayoutOrder = order
			rowFrame.Parent = body

			local rpad = Instance.new("UIPadding")
			rpad.PaddingTop = UDim.new(0, 9)
			rpad.PaddingBottom = UDim.new(0, 9)
			rpad.Parent = rowFrame

			-- The diamond bullet: a 5px square turned 45 degrees.
			local dot = Instance.new("Frame")
			dot.Size = UDim2.fromOffset(5, 5)
			dot.Position = UDim2.fromOffset(2, 7)
			dot.Rotation = 45
			dot.BackgroundColor3 = Theme.Color.Accent
			dot.BorderSizePixel = 0
			dot.Parent = rowFrame

			local hasTag = typeof(item.tag) == "string" and item.tag ~= ""
			local tagW = if hasTag then 86 else 0
			local txt = label(rowFrame, item.text, 14, Theme.Color.TextPrimary, Theme.Font.Label)
			txt.Position = UDim2.fromOffset(21, 0)
			txt.Size = UDim2.new(1, -(21 + tagW), 0, 0)
			txt.AutomaticSize = Enum.AutomaticSize.Y
			txt.TextWrapped = true
			txt.LineHeight = 1.5

			if hasTag then
				local chip = Instance.new("TextLabel")
				chip.AnchorPoint = Vector2.new(1, 0)
				chip.Position = UDim2.new(1, 0, 0, 1)
				chip.Size = UDim2.fromOffset(0, 18)
				chip.AutomaticSize = Enum.AutomaticSize.X
				chip.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
				chip.BackgroundTransparency = 0.9
				chip.Text = "  " .. tracked(item.tag :: string) .. "  "
				chip.TextSize = 9
				chip.TextColor3 = Theme.Color.TextSecondary
				chip.FontFace = Theme.Font.Header
				chip.BorderSizePixel = 0
				chip.Parent = rowFrame
				corner(chip, 4)
			end
		end
	end

	body.CanvasPosition = Vector2.zero
end

local function refreshNav()
	local list = currentList()
	;(_navLabel :: TextLabel).Text =
		tracked(if _tab == "UPDATE LOGS" then "VERSIONS" else "SECTIONS")

	for i, r in _navRows do
		local entry = list[i]
		r.row.Visible = entry ~= nil
		if not entry then continue end
		local active = i == _sel[_tab]
		r.plate.Visible = active
		r.bar.Visible = active
		r.name.Text = tracked(if _tab == "UPDATE LOGS" then entry.version else entry.name)
		r.name.TextColor3 = if active then Theme.Color.TextPrimary else Theme.Color.TextSecondary
		local meta = r.row:FindFirstChild("Meta") :: TextLabel?
		if meta then meta.Text = tracked(if _tab == "UPDATE LOGS" then entry.date else entry.meta) end
		local badge = r.row:FindFirstChild("Latest") :: GuiObject?
		if badge then badge.Visible = _tab == "UPDATE LOGS" and entry.latest == true end
	end
end

local function setTab(name: string)
	_tab = name
	for key, t in _tabBtns do
		local active = key == name
		t.plate.Visible = active
		t.label.TextColor3 = if active then Color3.fromRGB(245, 226, 212) else Theme.Color.TextSecondary
	end
	refreshNav()
	renderBody()
end

-- ------------------------------------------------------------------ build --

local function buildNav(parent: GuiObject)
	local nav = Instance.new("Frame")
	nav.Name = "Index"
	nav.Size = UDim2.new(0, NAV_W, 1, 0)
	nav.Parent = parent
	Glass.apply(nav, 14)

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 14)
	pad.PaddingBottom = UDim.new(0, 14)
	pad.PaddingLeft = UDim.new(0, 14)
	pad.PaddingRight = UDim.new(0, 14)
	pad.Parent = nav

	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 4)
	list.Parent = nav

	local cap = label(nav, "", 9, Theme.Color.TextSecondary, Theme.Font.Header)
	cap.Size = UDim2.new(1, 0, 0, 30)
	cap.LayoutOrder = 0
	local cpad = Instance.new("UIPadding")
	cpad.PaddingTop = UDim.new(0, 6)
	cpad.PaddingLeft = UDim.new(0, 12)
	cpad.Parent = cap
	_navLabel = cap

	-- One row per index slot, reused across both tabs -- the longer list (the
	-- release history) sets how many exist; credits just hides the surplus.
	local slots = math.max(#UpdateLogData.Versions, #UpdateLogData.Credits)
	for i = 1, slots do
		local row = Instance.new("TextButton")
		row.Name = "Row" .. i
		row.AutoButtonColor = false
		row.Text = ""
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, ROW_H)
		row.LayoutOrder = i
		row.Parent = nav

		local plate = Instance.new("Frame")
		plate.Size = UDim2.fromScale(1, 1)
		plate.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		plate.BackgroundTransparency = 0.89
		plate.BorderSizePixel = 0
		plate.Visible = false
		plate.Parent = row
		corner(plate, 9)
		stroke(plate, Color3.fromRGB(255, 255, 255), 0.9)

		local bar = Instance.new("Frame")
		bar.Position = UDim2.fromOffset(0, 12)
		bar.Size = UDim2.new(0, 2, 1, -24)
		bar.BackgroundColor3 = Theme.Color.Accent
		bar.BorderSizePixel = 0
		bar.Visible = false
		bar.ZIndex = 2
		bar.Parent = row
		corner(bar, 1)

		local name = label(row, "", 14, Theme.Color.TextSecondary, Theme.Font.Header)
		name.Position = UDim2.fromOffset(16, 10)
		name.Size = UDim2.new(1, -100, 0, 17)
		name.ZIndex = 2

		local meta = label(row, "", 10, Theme.Color.TextDisabled, Theme.Font.Label)
		meta.Name = "Meta"
		meta.Position = UDim2.fromOffset(16, 28)
		meta.Size = UDim2.new(1, -100, 0, 13)
		meta.ZIndex = 2

		local badge = Instance.new("TextLabel")
		badge.Name = "Latest"
		badge.AnchorPoint = Vector2.new(1, 0.5)
		badge.Position = UDim2.new(1, -14, 0.5, 0)
		badge.Size = UDim2.fromOffset(0, 17)
		badge.AutomaticSize = Enum.AutomaticSize.X
		badge.BackgroundColor3 = Theme.Color.Accent
		badge.BackgroundTransparency = 0.76
		badge.Text = "  " .. tracked("LATEST") .. "  "
		badge.TextSize = 8
		badge.TextColor3 = Color3.fromRGB(247, 169, 120)
		badge.FontFace = Theme.Font.Bold
		badge.BorderSizePixel = 0
		badge.Visible = false
		badge.ZIndex = 2
		badge.Parent = row
		corner(badge, 4)

		local idx = i
		row.MouseEnter:Connect(function()
			if _sel[_tab] ~= idx then name.TextColor3 = Theme.Color.TextPrimary end
		end)
		row.MouseLeave:Connect(function()
			if _sel[_tab] ~= idx then name.TextColor3 = Theme.Color.TextSecondary end
		end)
		row.Activated:Connect(function()
			if _sel[_tab] == idx then return end
			SoundFX.play("Click")
			_sel[_tab] = idx
			refreshNav()
			renderBody()
		end)

		table.insert(_navRows, { row = row, plate = plate, bar = bar, name = name })
	end
end

local function buildBody(parent: GuiObject)
	local section = Instance.new("Frame")
	section.Name = "Body"
	section.Position = UDim2.fromOffset(NAV_W + GUTTER, 0)
	section.Size = UDim2.new(1, -(NAV_W + GUTTER), 1, 0)
	section.ClipsDescendants = true
	section.Parent = parent
	Glass.apply(section, 14)

	local head = Instance.new("Frame")
	head.BackgroundTransparency = 1
	head.Size = UDim2.new(1, 0, 0, 88)
	head.Parent = section

	local kicker = label(head, "", 9, Theme.Color.TextSecondary, Theme.Font.Header)
	kicker.Position = UDim2.fromOffset(26, 22)
	kicker.Size = UDim2.new(0.6, 0, 0, 12)
	_headKicker = kicker

	local title = label(head, "", 26, Theme.Color.TextPrimary, Theme.Font.Header)
	title.Position = UDim2.fromOffset(26, 38)
	title.Size = UDim2.new(1, -220, 0, 32)
	title.TextTruncate = Enum.TextTruncate.AtEnd
	_headTitle = title

	local meta = label(head, "", 11, Theme.Color.TextSecondary, Theme.Font.Header)
	meta.AnchorPoint = Vector2.new(1, 0)
	meta.Position = UDim2.new(1, -26, 0, 56)
	meta.Size = UDim2.fromOffset(190, 14)
	meta.TextXAlignment = Enum.TextXAlignment.Right
	_headMeta = meta

	local rule = Instance.new("Frame")
	rule.AnchorPoint = Vector2.new(0, 1)
	rule.Position = UDim2.fromScale(0, 1)
	rule.Size = UDim2.new(1, 0, 0, 1)
	rule.BackgroundColor3 = Theme.Color.StrokeSoft
	rule.BackgroundTransparency = 0.6
	rule.BorderSizePixel = 0
	rule.Parent = head

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Scroll"
	scroll.Position = UDim2.fromOffset(0, 88)
	scroll.Size = UDim2.new(1, 0, 1, -88)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollBarThickness = 4
	scroll.ScrollBarImageColor3 = Color3.fromRGB(255, 255, 255)
	scroll.ScrollBarImageTransparency = 0.78
	scroll.Parent = section

	local spad = Instance.new("UIPadding")
	spad.PaddingTop = UDim.new(0, 4)
	spad.PaddingBottom = UDim.new(0, 24)
	spad.PaddingLeft = UDim.new(0, 26)
	spad.PaddingRight = UDim.new(0, 26)
	spad.Parent = scroll

	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = scroll

	_body = scroll
end

local function build()
	if _gui then return end

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	-- Menu band, not CostTag: this carries the update logs AND the credits, both opened
	-- from the main menu, so it has to draw above it.
	gui.DisplayOrder = Theme.Layer.Menu + 5
	gui.Enabled = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui
	_gui = gui
	HudScale.attach(gui)

	local veil = Instance.new("Frame")
	veil.Name = "Veil"
	veil.Size = UDim2.fromScale(1, 1)
	veil.BackgroundColor3 = Color3.fromRGB(10, 14, 11)
	veil.BackgroundTransparency = 0.38
	veil.BorderSizePixel = 0
	veil.Parent = gui

	-- Slightly heavier toward the bottom, so the page settles onto the art
	-- instead of floating in an even wash.
	local veilGrad = Instance.new("UIGradient")
	veilGrad.Rotation = 90
	veilGrad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.38),
		NumberSequenceKeypoint.new(1, 0.26),
	})
	veilGrad.Parent = veil

	local page = Instance.new("CanvasGroup")
	page.Name = "Page"
	page.Size = UDim2.fromScale(1, 1)
	page.BackgroundTransparency = 1
	page.Parent = gui
	_page = page

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, PAD_TOP)
	pad.PaddingBottom = UDim.new(0, PAD_BOTTOM)
	pad.PaddingLeft = UDim.new(0, PAD_X)
	pad.PaddingRight = UDim.new(0, PAD_X)
	pad.Parent = page

	-- Header: back arrow, then the two tabs.
	local header = Instance.new("Frame")
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 60)
	header.Parent = page

	local back = Instance.new("TextButton")
	back.Name = "Back"
	back.AutoButtonColor = false
	back.BackgroundTransparency = 1
	back.Position = UDim2.fromOffset(12, 8)
	back.Size = UDim2.fromOffset(26, 26)
	back.Text = "\u{25C0}"
	back.TextSize = 12
	back.TextColor3 = Color3.fromRGB(243, 222, 208)
	back.FontFace = Font.new("rbxasset://fonts/families/Arial.json", Enum.FontWeight.Bold)
	back.Parent = header
	back.MouseEnter:Connect(function() back.TextColor3 = Theme.Color.AccentHover end)
	back.MouseLeave:Connect(function() back.TextColor3 = Color3.fromRGB(243, 222, 208) end)
	back.Activated:Connect(function() UpdateLogsPanel.Close() end)

	local tabRow = Instance.new("Frame")
	tabRow.BackgroundTransparency = 1
	tabRow.Position = UDim2.fromOffset(64, 0)
	tabRow.Size = UDim2.new(1, -64, 0, 44)
	tabRow.Parent = header

	local tl = Instance.new("UIListLayout")
	tl.FillDirection = Enum.FillDirection.Horizontal
	tl.VerticalAlignment = Enum.VerticalAlignment.Center
	tl.SortOrder = Enum.SortOrder.LayoutOrder
	tl.Padding = UDim.new(0, 6)
	tl.Parent = tabRow

	for i, name in TABS do
		local btn = Instance.new("TextButton")
		btn.AutoButtonColor = false
		btn.Text = ""
		btn.BackgroundTransparency = 1
		btn.Size = UDim2.fromOffset(if i == 1 then 258 else 176, 44)
		btn.LayoutOrder = i
		btn.Parent = tabRow

		local plate = Instance.new("Frame")
		plate.Size = UDim2.fromScale(1, 1)
		plate.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		plate.BackgroundTransparency = 0.91
		plate.BorderSizePixel = 0
		plate.Visible = false
		plate.Parent = btn
		corner(plate, 9)
		stroke(plate, Color3.fromRGB(255, 255, 255), 0.9)

		local lbl = label(btn, tracked(name), 19, Theme.Color.TextSecondary, Theme.Font.Display)
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.TextXAlignment = Enum.TextXAlignment.Center
		lbl.TextYAlignment = Enum.TextYAlignment.Center
		lbl.ZIndex = 2

		local key = name
		btn.Activated:Connect(function()
			if _tab == key then return end
			SoundFX.play("Tab")
			setTab(key)
		end)

		_tabBtns[name] = { btn = btn, plate = plate, label = lbl }
	end

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Position = UDim2.fromOffset(0, 60)
	content.Size = UDim2.new(1, 0, 1, -60)
	content.Parent = page

	buildNav(content)
	buildBody(content)
	setTab(_tab)

	-- Settings takes the screen the same way this page does; whoever opens
	-- second would otherwise leave the first one's hidden GUIs stranded.
	UIEvents.SettingsOpened.Event:Connect(function()
		UpdateLogsPanel.Close()
	end)
end

-- ------------------------------------------------------------- open/close --

function UpdateLogsPanel.Open(tab: string?)
	build()
	if tab == "CREDITS" or tab == "UPDATE LOGS" then
		setTab(tab :: string)
	end
	if _open then return end
	_open = true

	local gui = _gui :: ScreenGui
	local page = _page :: CanvasGroup

	-- Own the screen: hide every other ScreenGui but leave the main menu, whose
	-- key art is the backdrop this page sits on.
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

	-- Soften the backdrop: tint the key art down, and blur any 3D behind it.
	-- The controller clones BG into a full-bleed parallax layer at startup; if
	-- that never happened, dim the original BG instead.
	local backdrop = if menu then menu:FindFirstChild(MAIN_MENU_BACKDROP) else nil
	if not backdrop and menu then
		local container = menu:FindFirstChild(MAIN_MENU_BUTTONS)
		local mainFrame = if container then container:FindFirstChild("Main") else nil
		backdrop = if mainFrame then mainFrame:FindFirstChild("BG") else nil
	end
	if backdrop and backdrop:IsA("ImageLabel") then
		_dimmedBackdrop = backdrop
		_backdropColor = backdrop.ImageColor3
		UITween.to(backdrop, "Modal", { ImageColor3 = BACKDROP_DIM })
	end

	local blur = _blur
	if not blur or not blur.Parent then
		blur = Instance.new("BlurEffect")
		blur.Name = "UpdateLogsBlur"
		blur.Size = 0
		blur.Parent = game:GetService("Lighting")
		_blur = blur
	end
	UITween.to(blur :: BlurEffect, "Modal", { Size = BLUR_SIZE })

	gui.Enabled = true
	page.GroupTransparency = 1
	page.Position = UDim2.fromOffset(0, 14)
	UITween.to(page, "Flyout", { GroupTransparency = 0, Position = UDim2.fromOffset(0, 0) })
	SoundFX.play("Open")

	_escConn = UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		if input.KeyCode == Enum.KeyCode.Escape then
			UpdateLogsPanel.Close()
		end
	end)
end

function UpdateLogsPanel.Close()
	if not _open then return end
	_open = false

	if _escConn then
		_escConn:Disconnect()
		_escConn = nil
	end

	for _, child in _hidden do
		if child.Parent then child.Enabled = true end
	end
	table.clear(_hidden)

	if _hiddenMenu and _hiddenMenu.Parent then
		_hiddenMenu.Visible = true
	end
	_hiddenMenu = nil

	local backdrop = _dimmedBackdrop
	if backdrop and backdrop.Parent and _backdropColor then
		UITween.to(backdrop, "Modal", { ImageColor3 = _backdropColor })
	end
	_dimmedBackdrop = nil
	_backdropColor = nil

	if _blur and _blur.Parent then
		UITween.to(_blur :: BlurEffect, "Modal", { Size = 0 })
	end

	SoundFX.play("Close")
	local gui = _gui
	local page = _page
	if not gui or not page then return end
	UITween.to(page, "Flyout", { GroupTransparency = 1, Position = UDim2.fromOffset(0, 14) }).Completed:Once(function()
		if not _open then gui.Enabled = false end
	end)
end

function UpdateLogsPanel.IsOpen(): boolean
	return _open
end

return UpdateLogsPanel
