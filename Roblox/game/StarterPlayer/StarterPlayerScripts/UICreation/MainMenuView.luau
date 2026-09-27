--!strict
-- MainMenuView: builds the Main Menu ScreenGui tree + reusable menu panels (e.g. the
-- Content Hub overlay). Construction only, plus view-internal presentation (tab switching);
-- controller behaviour arrives through callbacks. Generated from the former static
-- StarterGui.MainMenu so edit-mode StarterGui stays empty.

local MainMenuView = {}

local playerScripts = script.Parent.Parent -- StarterPlayerScripts
local uiFolder = playerScripts:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local Button = require(uiFolder:WaitForChild("Kit"):WaitForChild("Button"))
local Glass = require(uiFolder:WaitForChild("Kit"):WaitForChild("Glass"))
local MapResources = require(game:GetService("ReplicatedStorage"):WaitForChild("City"):WaitForChild("MapResources"))
-- Rebuilds a published creation for the Browsing tab's preview. The same builder the
-- editor, the placer and the review panel use, so what a player is shown here is the
-- geometry that would actually appear in their city.
local CreationBuilder = require(game:GetService("ReplicatedStorage"):WaitForChild("Editor"):WaitForChild("CreationBuilder"))

local CONTENT_HUB_TABS: { string } = { "Browsing", "Playlist", "Creation" }
local CONTENT_HUB_BLURB: { [string]: string } = {
	Browsing = "Nothing published yet. Build something in the Creation tab and send it for review.",
	Playlist = "Assets you have saved show up here. Coming soon.",
	Creation = "Build, texture and save your own assets in an isolated workspace.",
}

-- ---- Menu look -----------------------------------------------------
-- A launcher on film. MenuReel's city flythroughs run full-bleed behind everything
-- (the key art stands in until they load); a dark wash down the left edge and along
-- the floor carries the type; the wordmark sits top-left and the nameplate top-right.
-- The actions are ONE compact cluster hanging in the bottom-left: CONTINUE as the
-- accent pill, the two ways into a city as frosted glass pills, and the shelf
-- (settings, update logs, credits) as round glass chips captioned in small caps.
-- The middle of the screen is left to the footage.
-- Deliberately not Theme's HUD palette; the menu is the only surface with this one.
local TweenService = game:GetService("TweenService")
local Icons = require(uiFolder:WaitForChild("Icons"))

local SCRIM = Color3.fromRGB(9, 12, 10)
local WHITE = Color3.fromRGB(255, 255, 255)
local DIM = Color3.fromRGB(166, 169, 164)
local ONLINE = Color3.fromRGB(78, 201, 106)
-- Idle ink is a COLOUR, never TextTransparency: MainMenuController's
-- updateGameButtonsState writes Label.TextTransparency and Icon.ImageTransparency
-- to mark Continue / Load unavailable, so this file keeps its hands off both.
local INK_IDLE = Color3.fromRGB(226, 228, 224)
local STROKE_T = 0.82

local MONTSERRAT = "rbxasset://fonts/families/Montserrat.json"
local FONT_LIGHT = Font.new(MONTSERRAT, Enum.FontWeight.Light)
local FONT_BOLD = Font.new(MONTSERRAT, Enum.FontWeight.Bold)
local FONT_META = Font.new(MONTSERRAT, Enum.FontWeight.SemiBold)

-- Everything below is DESIGN px for a 900px-tall screen; one UIScale on Main fits it
-- to the real one. The floor keeps the buttons tappable on a phone (a 390px-tall
-- landscape phone would otherwise shrink them to 0.43); the ceiling stops a 4K
-- monitor inflating them.
local DESIGN_H = 900
local SCALE_MIN = 0.7
local SCALE_MAX = 1.5

local MARGIN = 88 -- page margin, both sides: wordmark, cluster, stamp, nameplate, caption
local TOP = 96 -- wordmark / nameplate row; clears the Roblox topbar at the smallest scale
local CLUSTER_W = 380
local GAP = 12
local PRIMARY_H = 72
local SECONDARY_W = (CLUSTER_W - GAP) / 2
local SECONDARY_H = 54
local CHIP = 46
local CHIP_COL = CLUSTER_W / 3
-- The cluster hangs from the floor, so each band is placed by the distance from the
-- bottom edge to its TOP.
local PRIMARY_UP = 342
local SECONDARY_UP = PRIMARY_UP - PRIMARY_H - GAP -- 258
local CHIPS_UP = SECONDARY_UP - SECONDARY_H - 28 -- 176
local FOOT_UP = 44 -- build stamp and clip caption baseline

local HOVER = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Each time the menu comes up the page deals itself in, top to bottom: every item
-- slides the last few px in from the left while the controller's black fade lifts.
local INTRO_SHIFT = 28
local INTRO_STAGGER = 0.05
local INTRO_TIME = 0.7

-- The build stamp on the menu is whatever the newest release says it is, so it
-- can never drift from the update log. Versions are stored without a "v".
local UpdateLogData = require(uiFolder:WaitForChild("MainMenu"):WaitForChild("UpdateLogData"))
local MenuReel = require(uiFolder:WaitForChild("MainMenu"):WaitForChild("MenuReel"))
local BUILD_VERSION = (UpdateLogData.Versions[1].version:gsub("^v", ""))

local function spaced(s: string): string
	-- By character, not byte: a "·" or an accented display name is several bytes.
	return (s:gsub(utf8.charpattern, "%0 "):gsub(" $", ""))
end

local function text(parent: Instance, name: string, txt: string, font: Font, size: number, color: Color3): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.ZIndex = 6
	t.Size = UDim2.new(1, 0, 0, size)
	t.BackgroundTransparency = 1
	t.Text = txt
	t.FontFace = font
	t.TextSize = size
	t.TextColor3 = color
	t.TextXAlignment = Enum.TextXAlignment.Left
	t.TextTruncate = Enum.TextTruncate.AtEnd
	t.Parent = parent
	return t
end

local function roundOff(obj: GuiObject, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = obj
end

-- Kit.Glass is the one place a panel fill is decided: it paints from Theme.Glass,
-- registers the pane so the UI-transparency slider repaints it, and attaches
-- Kit.Frost (which the frostedGlass setting switches off).
local function glassify(obj: GuiObject, strokeColor: Color3, strokeT: number, radius: number): UIStroke
	local edge = Glass.apply(obj, radius)
	edge.Color = strokeColor
	edge.Transparency = strokeT
	return edge
end

local function icon(parent: Instance, image: string, size: number): ImageLabel
	local i = Instance.new("ImageLabel")
	i.Name = "Icon"
	i.ZIndex = 6
	i.AnchorPoint = Vector2.new(0.5, 0.5)
	i.Size = UDim2.fromOffset(size, size)
	i.BackgroundTransparency = 1
	i.Image = image
	i.ScaleType = Enum.ScaleType.Fit
	i.Parent = parent
	return i
end

-- The hover light: a white film over a button's face that hover fades up. It sits ON
-- the glass rather than changing it, so the fill stays what Kit.Glass (and the
-- player's transparency slider) made it.
local function shine(parent: GuiObject): Frame
	local f = Instance.new("Frame")
	f.Name = "Shine"
	f.ZIndex = 4
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundColor3 = WHITE
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Parent = parent
	roundOff(f, 999)
	return f
end

-- Every action is an ImageButton straight on Main -- MainMenuController looks all
-- eight up there by name -- with its face drawn inside it. Centre-anchored so the
-- hover lift (a UIScale) grows it about its middle.
local function actionButton(main: Frame, name: string, x: number, up: number, w: number, h: number): ImageButton
	local b = Instance.new("ImageButton")
	b.Name = name
	b.ZIndex = 3
	b.AnchorPoint = Vector2.new(0.5, 0.5)
	b.Position = UDim2.new(0, x + w / 2, 1, -up + h / 2)
	b.Size = UDim2.fromOffset(w, h)
	b.BackgroundTransparency = 1
	b.BorderSizePixel = 0
	b.ImageTransparency = 1
	b.AutoButtonColor = false
	b.Parent = main
	return b
end

-- Idle / hover / press for one action: `face` lifts, `glow` lights, `edge` brightens
-- and `ink` goes white. Gamepad selection counts as hover, and the stock selection
-- box is swapped for nothing because the hover state already says which is picked.
local function wireHover(btn: ImageButton, face: GuiObject, glow: Frame, edge: UIStroke?, ink: TextLabel?, lift: number)
	local scale = Instance.new("UIScale")
	scale.Parent = face
	local restEdge = if edge then edge.Transparency else 1
	local restInk = if ink then ink.TextColor3 else WHITE
	local over = false

	local function show(state: "idle" | "hover" | "press")
		local lit = state ~= "idle"
		local info = if state == "press" then PRESS else HOVER
		TweenService:Create(scale, info, { Scale = if state == "press" then 0.97 elseif lit then lift else 1 }):Play()
		TweenService:Create(glow, info, { BackgroundTransparency = if lit then 0.88 else 1 }):Play()
		if edge then
			TweenService:Create(edge, info, { Transparency = if lit then 0.35 else restEdge }):Play()
		end
		if ink then
			TweenService:Create(ink, info, { TextColor3 = if lit then WHITE else restInk }):Play()
		end
	end

	local none = Instance.new("Frame")
	none.BackgroundTransparency = 1
	btn.SelectionImageObject = none
	btn.MouseEnter:Connect(function()
		over = true
		show("hover")
	end)
	btn.MouseLeave:Connect(function()
		over = false
		show("idle")
	end)
	btn.SelectionGained:Connect(function()
		show("hover")
	end)
	btn.SelectionLost:Connect(function()
		show("idle")
	end)
	btn.MouseButton1Down:Connect(function()
		show("press")
	end)
	btn.MouseButton1Up:Connect(function()
		show(if over then "hover" else "idle")
	end)
end

-- A button with a second line (the resumable city, the save count) stacks its word
-- over it; when the controller blanks that line the word drops to the middle.
local function seat(lbl: TextLabel, meta: TextLabel, h: number)
	local function place()
		local two = meta.Text ~= ""
		meta.Visible = two
		local block = if two then lbl.TextSize + 5 + meta.TextSize else lbl.TextSize
		local top = math.floor((h - block) / 2)
		lbl.Position = UDim2.new(lbl.Position.X.Scale, lbl.Position.X.Offset, 0, top)
		meta.Position = UDim2.new(meta.Position.X.Scale, meta.Position.X.Offset, 0, top + lbl.TextSize + 5)
	end
	meta:GetPropertyChangedSignal("Text"):Connect(place)
	place()
end

-- CONTINUE: the accent pill with a white play disc, the word, and under it the city
-- it would resume. The controller writes both lines, and for a player with no city
-- yet it turns the pill into START A CITY.
local function makePrimary(main: Frame): ImageButton
	local b = actionButton(main, "ContinueButton", MARGIN, PRIMARY_UP, CLUSTER_W, PRIMARY_H)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.ZIndex = 3
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = WHITE
	fill.BorderSizePixel = 0
	fill.Parent = b
	roundOff(fill, 999)
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Color = Theme.AccentGradient
	grad.Parent = fill
	local glow = shine(b)

	local disc = Instance.new("Frame")
	disc.Name = "Disc"
	disc.ZIndex = 5
	disc.AnchorPoint = Vector2.new(0.5, 0.5)
	disc.Position = UDim2.new(0, 38, 0.5, 0)
	disc.Size = UDim2.fromOffset(46, 46)
	disc.BackgroundColor3 = WHITE
	disc.BorderSizePixel = 0
	disc.Parent = b
	roundOff(disc, 999)
	local play = icon(b, Icons.Speed1.image, 32)
	play.Position = UDim2.new(0, 40, 0.5, 0) -- a hair right of centre: a triangle's mass sits left
	play.ImageColor3 = Theme.Color.AccentPress

	local lbl = text(b, "Label", "CONTINUE", FONT_BOLD, 21, Theme.Color.OnAccent)
	lbl.Position = UDim2.fromOffset(78, 0)
	lbl.Size = UDim2.new(1, -96, 0, 21)
	local meta = text(b, "Meta", "", FONT_META, 12, Theme.Color.OnAccent)
	meta.Position = UDim2.fromOffset(78, 0)
	meta.Size = UDim2.new(1, -96, 0, 12)
	meta.TextTransparency = 0.15
	seat(lbl, meta, PRIMARY_H)


	wireHover(b, b, glow, nil, nil, 1.02)
	return b
end

-- NEW CITY / LOAD CITY: frosted glass pills, icon then word, save count under it.
local function makeSecondary(main: Frame, name: string, word: string, image: string, x: number): ImageButton
	local b = actionButton(main, name, x, SECONDARY_UP, SECONDARY_W, SECONDARY_H)
	local edge = glassify(b, WHITE, STROKE_T, 999)
	local glow = shine(b)

	local ic = icon(b, image, 24)
	ic.Position = UDim2.new(0, 31, 0.5, 0)
	local lbl = text(b, "Label", word, FONT_BOLD, 15, INK_IDLE)
	lbl.Position = UDim2.fromOffset(52, 0)
	lbl.Size = UDim2.new(1, -62, 0, 15)
	local meta = text(b, "Meta", "", FONT_META, 11, DIM)
	meta.Position = UDim2.fromOffset(52, 0)
	meta.Size = UDim2.new(1, -62, 0, 11)
	seat(lbl, meta, SECONDARY_H)

	wireHover(b, b, glow, edge, lbl, 1.03)
	return b
end

-- The shelf: a round glass chip per page, its caption in small caps underneath. The
-- hit area is the chip AND its caption, one third of the cluster wide.
local function makeChip(main: Frame, name: string, caption: string, image: string, column: number): ImageButton
	local b = actionButton(main, name, MARGIN + (column - 1) * CHIP_COL, CHIPS_UP, CHIP_COL, CHIP + 8 + 12)

	local chip = Instance.new("Frame")
	chip.Name = "Chip"
	chip.ZIndex = 3
	chip.AnchorPoint = Vector2.new(0.5, 0)
	chip.Position = UDim2.fromScale(0.5, 0)
	chip.Size = UDim2.fromOffset(CHIP, CHIP)
	chip.Parent = b
	local edge = glassify(chip, WHITE, STROKE_T, 999)
	local glow = shine(chip)
	local ic = icon(chip, image, 24)
	ic.Position = UDim2.fromScale(0.5, 0.5)

	local cap = text(b, "Label", spaced(caption), FONT_META, 10, DIM)
	cap.TextXAlignment = Enum.TextXAlignment.Center
	cap.Position = UDim2.fromOffset(0, CHIP + 8)
	cap.Size = UDim2.new(1, 0, 0, 12)

	wireHover(b, chip, glow, edge, cap, 1.07)
	return b
end

-- One UIScale on Main fits the DESIGN_H canvas to the screen. Main is sized 1/scale
-- so that, once scaled, it still covers the screen exactly: the full-bleed layers
-- inside it stay full-bleed, and bottom/right anchors land on the real edges.
local function fitCanvas(root: ScreenGui, main: Frame)
	local fit = Instance.new("UIScale")
	fit.Name = "MenuFit"
	fit.Parent = main
	local function refit()
		local h = root.AbsoluteSize.Y
		if h <= 0 then
			return
		end
		local s = math.clamp(h / DESIGN_H, SCALE_MIN, SCALE_MAX)
		fit.Scale = s
		main.Size = UDim2.fromScale(1 / s, 1 / s)
	end
	root:GetPropertyChangedSignal("AbsoluteSize"):Connect(refit)
	refit()
end

local function makeIntro(root: ScreenGui, reshown: { GuiObject }, items: { GuiObject })
	local home: { [GuiObject]: UDim2 } = {}
	for _, item in items do
		home[item] = item.Position
	end

	local function play()
		for i, item in items do
			local p = home[item]
			item.Position = p + UDim2.fromOffset(-INTRO_SHIFT, 0)
			TweenService:Create(
				item,
				TweenInfo.new(INTRO_TIME, Enum.EasingStyle.Quint, Enum.EasingDirection.Out, 0, false, (i - 1) * INTRO_STAGGER),
				{ Position = p }
			):Play()
		end
	end

	root:GetPropertyChangedSignal("Enabled"):Connect(function()
		if root.Enabled then
			play()
		end
	end)
	-- Coming back from New City / Load City (Main) or Settings / Update Logs
	-- (Container) deals the page in again, the same as opening the menu.
	for _, frame in reshown do
		frame:GetPropertyChangedSignal("Visible"):Connect(function()
			if frame.Visible and root.Enabled then
				play()
			end
		end)
	end
end

-- Top-left wordmark: an accent tile and the name on one line. A skyline of three bars
-- is the one silhouette that still reads as this game at 36px, and it needs no
-- uploaded art. Two weights, one line -- the light/heavy brand pairing.
local function makeWordmark(parent: Instance): Frame
	local logo = Instance.new("Frame")
	logo.Name = "Logo"
	logo.ZIndex = 5
	logo.Position = UDim2.fromOffset(MARGIN, TOP)
	logo.Size = UDim2.fromOffset(0, 36)
	logo.AutomaticSize = Enum.AutomaticSize.X
	logo.BackgroundTransparency = 1
	logo.BorderSizePixel = 0
	logo.Parent = parent

	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.VerticalAlignment = Enum.VerticalAlignment.Center
	row.SortOrder = Enum.SortOrder.LayoutOrder
	row.Padding = UDim.new(0, 12)
	row.Parent = logo

	local mark = Instance.new("Frame")
	mark.Name = "Mark"
	mark.LayoutOrder = 1
	mark.ZIndex = 5
	mark.Size = UDim2.fromOffset(36, 36)
	mark.BackgroundColor3 = WHITE
	mark.BorderSizePixel = 0
	mark.Parent = logo
	roundOff(mark, 8)
	local markGrad = Instance.new("UIGradient")
	markGrad.Rotation = 90
	markGrad.Color = Theme.AccentGradient
	markGrad.Parent = mark

	for index, bar in { { x = 8, w = 5, h = 11 }, { x = 16, w = 5, h = 19 }, { x = 24, w = 5, h = 8 } } do
		local block = Instance.new("Frame")
		block.Name = "Block" .. index
		block.ZIndex = 6
		block.AnchorPoint = Vector2.new(0, 1)
		block.Position = UDim2.new(0, bar.x, 1, -8)
		block.Size = UDim2.fromOffset(bar.w, bar.h)
		block.BackgroundColor3 = WHITE
		block.BorderSizePixel = 0
		block.Parent = mark
	end

	-- One label, the second word set heavy through rich text. Fixed TextSize, not
	-- TextScaled: AutomaticSize has nothing to measure if the text scales.
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.LayoutOrder = 2
	title.ZIndex = 5
	title.Size = UDim2.fromOffset(0, 30)
	title.AutomaticSize = Enum.AutomaticSize.X
	title.BackgroundTransparency = 1
	title.RichText = true
	title.Text = 'CITY <font weight="heavy">DISTRICT</font>'
	title.FontFace = FONT_LIGHT
	title.TextSize = 28
	title.TextColor3 = WHITE
	title.Parent = logo
	return logo
end

-- Top-right identity tile, mirroring the wordmark across the page. Purely a
-- nameplate -- nothing clicks it.
local function makeAccountPill(parent: Instance)
	local player = game:GetService("Players").LocalPlayer
	local displayName = if player then player.DisplayName else "Mayor"
	local initials = displayName:sub(1, 2):upper()

	local tile = Instance.new("Frame")
	tile.Name = "AccountPill"
	tile.ZIndex = 5
	tile.AnchorPoint = Vector2.new(1, 0)
	tile.Position = UDim2.new(1, -MARGIN, 0, TOP - 2)
	tile.Size = UDim2.fromOffset(40, 40)
	tile.BorderSizePixel = 0
	tile.Parent = parent
	glassify(tile, WHITE, STROKE_T, 999)

	local ini = text(tile, "Initials", initials, FONT_BOLD, 14, WHITE)
	ini.AnchorPoint = Vector2.new(0.5, 0.5)
	ini.Position = UDim2.fromScale(0.5, 0.5)
	ini.Size = UDim2.fromOffset(40, 14)
	ini.TextXAlignment = Enum.TextXAlignment.Center

	-- The name reads back toward the tile, so it stays out of the footage on the right
	-- edge instead of running into it.
	local name = text(parent, "AccountName", spaced("MAYOR " .. displayName:upper()), FONT_META, 11, DIM)
	name.ZIndex = 5
	name.AnchorPoint = Vector2.new(1, 0.5)
	name.Position = UDim2.new(1, -MARGIN - 54, 0, TOP + 18)
	name.Size = UDim2.fromOffset(320, 11)
	name.TextXAlignment = Enum.TextXAlignment.Right
	name.TextTransparency = 0.25
end

-- A full-screen wash from SCRIM, transparency running along `rotation`.
local function wash(parent: Instance, name: string, rotation: number, keys: { NumberSequenceKeypoint })
	local f = Instance.new("Frame")
	f.Name = name
	f.ZIndex = 1
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundColor3 = SCRIM
	f.BorderSizePixel = 0
	f.Parent = parent
	local g = Instance.new("UIGradient")
	g.Rotation = rotation
	g.Transparency = NumberSequence.new(keys)
	g.Parent = f
end

function MainMenuView.build(): ScreenGui
	local root = Instance.new("ScreenGui")
	root.Name = "MainMenu"
	-- Was left at the default 0, i.e. UNDER CityUI (200). It only ever looked right because
	-- the load gate disables the gameplay guis; if that ever failed the HUD drew on top of
	-- the menu. Screen (250) clears the HUD and nothing else -- everything the menu LAUNCHES
	-- (update logs, credits, settings, creation editor) has to stay above it.
	root.DisplayOrder = Theme.Layer.Screen
	root.Enabled = false
	root.IgnoreGuiInset = true
	root.ResetOnSpawn = false
	root.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	root.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets

	local container = Instance.new("Frame")
	container.Name = "Container"
	-- 2: above MenuReel's video (1) and the controller's key-art layer (0), both of
	-- which live on the root so they stay up while dialogs hide this.
	container.ZIndex = 2
	container.AnchorPoint = Vector2.new(0.5, 0.5)
	container.Position = UDim2.fromScale(0.5, 0.5)
	container.Size = UDim2.fromScale(1, 1)
	container.BackgroundTransparency = 1
	container.BorderSizePixel = 0
	container.Parent = root

	local main = Instance.new("Frame")
	main.Name = "Main"
	main.Size = UDim2.fromScale(1, 1)
	main.BackgroundTransparency = 1
	main.BorderSizePixel = 0
	main.Parent = container
	fitCanvas(root, main)

	-- The controller clones BG into a full-screen parallax layer and hides this
	-- one, so it stays full-bleed. It is the backdrop until MenuReel's first clip
	-- loads, and for good if none does.
	local bg = Instance.new("ImageLabel")
	bg.Name = "BG"
	bg.AnchorPoint = Vector2.new(0.5, 0.5)
	bg.Position = UDim2.fromScale(0.5, 0.5)
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundTransparency = 1
	bg.BorderSizePixel = 0
	bg.Image = "rbxassetid://96264041905572"
	bg.ImageColor3 = Color3.fromRGB(212, 212, 212)
	bg.ScaleType = Enum.ScaleType.Crop
	bg.Parent = main

	-- The wash runs LEFT TO RIGHT and clears completely by the right edge -- the
	-- footage is the point of the screen. The crown and floor give the wordmark,
	-- nameplate, cluster, stamp and clip caption something even to sit on.
	wash(main, "Scrim", 0, {
		NumberSequenceKeypoint.new(0, 0.18),
		NumberSequenceKeypoint.new(0.3, 0.42),
		NumberSequenceKeypoint.new(0.58, 0.85),
		NumberSequenceKeypoint.new(1, 1),
	})
	wash(main, "Crown", 90, {
		NumberSequenceKeypoint.new(0, 0.45),
		NumberSequenceKeypoint.new(0.22, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	wash(main, "Floor", 90, {
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 1),
		NumberSequenceKeypoint.new(1, 0.3),
	})

	local logo = makeWordmark(main)
	makeAccountPill(main)

	local subtitle = text(main, "Subtitle", spaced("SANDBOX CITY BUILDER"), FONT_META, 11, DIM)
	subtitle.ZIndex = 5
	subtitle.Position = UDim2.fromOffset(MARGIN + 1, TOP + 50)
	subtitle.Size = UDim2.fromOffset(320, 11)
	subtitle.TextTransparency = 0.3

	-- The cluster. Every name is load-bearing: MainMenuController looks all eight up
	-- on Main by name.
	local continueBtn = makePrimary(main)
	local newBtn = makeSecondary(main, "NewGameButton", "NEW CITY", Icons.Buildings.image, MARGIN)
	local loadBtn = makeSecondary(main, "LoadGameButton", "LOAD CITY", Icons.ClassFolder.image, MARGIN + SECONDARY_W + GAP)
	local settingsBtn = makeChip(main, "SettingsButton", "SETTINGS", Icons.Settings.image, 1)
	local logsBtn = makeChip(main, "UpdateLogsButton", "UPDATES", Icons.Info.image, 2)
	local creditsBtn = makeChip(main, "CreditsButton", "CREDITS", Icons.Citizens.image, 3)
	-- ponytail: CONTENT HUB + CREATOR HUB are off for playtest. The buttons still exist --
	-- MainMenuController looks both up on Main by name -- but hidden, so they take no
	-- input. Turning one on means giving it a column in the shelf.
	makeChip(main, "ContentHubButton", "CONTENT", Icons.EditorToolbox.image, 4).Visible = false
	makeChip(main, "EditorButton", "CREATE", Icons.ClassModel.image, 5).Visible = false

	-- Bottom-left, under the cluster's left edge.
	local stamp = Instance.new("Frame")
	stamp.Name = "BuildStamp"
	stamp.ZIndex = 3
	stamp.AnchorPoint = Vector2.new(0, 1)
	stamp.Position = UDim2.new(0, MARGIN, 1, -FOOT_UP)
	stamp.Size = UDim2.fromOffset(260, 14)
	stamp.BackgroundTransparency = 1
	stamp.BorderSizePixel = 0
	stamp.Parent = main

	local dot = Instance.new("Frame")
	dot.Name = "Dot"
	dot.ZIndex = 4
	dot.AnchorPoint = Vector2.new(0, 0.5)
	dot.Position = UDim2.new(0, 0, 0.5, 0)
	dot.Size = UDim2.fromOffset(6, 6)
	dot.BackgroundColor3 = ONLINE
	dot.BorderSizePixel = 0
	dot.Parent = stamp
	roundOff(dot, 3)

	local stampText = text(stamp, "Label", spaced("BUILD " .. BUILD_VERSION), FONT_META, 11, DIM)
	stampText.AnchorPoint = Vector2.new(0, 0.5)
	stampText.Position = UDim2.new(0, 15, 0.5, 0)
	stampText.Size = UDim2.new(1, -15, 0, 11)
	stampText.TextTransparency = 0.3

	-- Mirror of the stamp on the right edge: the playing clip's name, its place in the
	-- reel and one progress segment per clip. MenuReel fills it, and keeps it hidden
	-- while there is no footage to caption.
	local caption = Instance.new("Frame")
	caption.Name = "ReelCaption"
	caption.ZIndex = 3
	caption.AnchorPoint = Vector2.new(1, 1)
	caption.Position = UDim2.new(1, -MARGIN, 1, -FOOT_UP + 4)
	caption.Size = UDim2.fromOffset(460, 58)
	caption.BackgroundTransparency = 1
	caption.BorderSizePixel = 0
	caption.Parent = main

	makeIntro(root, { main, container }, { logo, subtitle, continueBtn, newBtn, loadBtn, settingsBtn, logsBtn, creditsBtn, stamp })
	MenuReel.mount(root, container, caption)

	return root
end


-- Full-screen Content Hub overlay (Browse / Playlist / Creation). Construction plus
-- view-internal tab switching; the controller supplies onBack / onOpenEditor.
-- The client cannot see ServerStorage, so a creation's prop references resolve by leaf
-- name into ReplicatedStorage.Props; anything that misses becomes CreationBuilder's
-- placeholder rather than a hole, which keeps the silhouette honest.
local function browseResolve(key: string): Model?
	local leaf = string.match(key, "([^%.]+)$")
	if not leaf then return nil end
	local props = game:GetService("ReplicatedStorage"):FindFirstChild("Props")
	local model = props and props:FindFirstChild(leaf)
	return if model and model:IsA("Model") then model :: Model else nil
end

-- The Browsing tab: the approved-creation catalogue. Cards on the left, a rotating
-- preview on the right. Construction only -- the two round trips (the listing, and one
-- blob per preview) arrive as callbacks, so this file stays free of remotes like the rest
-- of the view.
local function buildBrowsePane(body: Frame, blurb: TextLabel, deps: any)
	local RunService = game:GetService("RunService")
	local PAD = 28
	-- Set at the end of this function; the take-down button needs to re-list after a
	-- successful removal, and reload() is defined below it.
	local browseReloadRef: (() -> ())? = nil

	local header = Instance.new("Frame")
	header.Name = "BrowseHeader"
	header.BackgroundTransparency = 1
	header.Position = UDim2.fromOffset(PAD, 16)
	header.Size = UDim2.new(1, -PAD * 2, 0, 34)
	header.ZIndex = 503
	header.Parent = body

	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.BackgroundTransparency = 1
	status.Size = UDim2.new(1, -140, 1, 0)
	status.FontFace = Theme.Font.Label
	status.Text = "Loading the catalogue..."
	status.TextSize = Theme.TextSize.SM
	status.TextColor3 = Theme.Color.TextSecondary
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.ZIndex = 504
	status.Parent = header

	local grid = Instance.new("ScrollingFrame")
	grid.Name = "Grid"
	grid.BackgroundTransparency = 1
	grid.BorderSizePixel = 0
	grid.Position = UDim2.fromOffset(PAD, 58)
	grid.Size = UDim2.new(0.56, -PAD, 1, -58 - PAD)
	grid.CanvasSize = UDim2.new()
	grid.AutomaticCanvasSize = Enum.AutomaticSize.Y
	grid.ScrollBarThickness = 5
	grid.ScrollBarImageColor3 = Theme.Color.Stroke
	grid.ScrollingDirection = Enum.ScrollingDirection.Y
	grid.ZIndex = 503
	grid.Parent = body
	local gl = Instance.new("UIGridLayout")
	gl.CellSize = UDim2.fromOffset(168, 92)
	gl.CellPadding = UDim2.fromOffset(10, 10)
	gl.SortOrder = Enum.SortOrder.LayoutOrder
	gl.Parent = grid

	-- Detail pane: what you are actually looking at before you commit to using it.
	local detail = Instance.new("Frame")
	detail.Name = "Detail"
	detail.BackgroundColor3 = Theme.Color.BgRaised
	detail.BackgroundTransparency = 0.25
	detail.BorderSizePixel = 0
	detail.Position = UDim2.new(0.58, 0, 0, 58)
	detail.Size = UDim2.new(0.42, -PAD, 1, -58 - PAD)
	detail.ZIndex = 503
	detail.Parent = body
	local dc = Instance.new("UICorner")
	dc.CornerRadius = UDim.new(0, Theme.Radius.MD)
	dc.Parent = detail

	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Preview"
	viewport.Active = true -- required for the scroll wheel to reach InputChanged
	viewport.BackgroundTransparency = 1
	viewport.Position = UDim2.fromOffset(0, 0)
	viewport.Size = UDim2.new(1, 0, 1, -104)
	viewport.Ambient = Color3.fromRGB(150, 150, 150)
	viewport.LightColor = Color3.fromRGB(255, 255, 255)
	viewport.LightDirection = Vector3.new(-0.4, -1, -0.6)
	viewport.ZIndex = 504
	viewport.Parent = detail
	local cam = Instance.new("Camera")
	cam.FieldOfView = 40
	cam.Parent = viewport
	viewport.CurrentCamera = cam

	local function detailLabel(name: string, y: number, font: Font, size: number, colour: Color3): TextLabel
		local l = Instance.new("TextLabel")
		l.Name = name
		l.BackgroundTransparency = 1
		l.AnchorPoint = Vector2.new(0, 1)
		l.Position = UDim2.new(0, 16, 1, -y)
		l.Size = UDim2.new(1, -32, 0, 22)
		l.FontFace = font
		l.Text = ""
		l.TextSize = size
		l.TextColor3 = colour
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.TextTruncate = Enum.TextTruncate.AtEnd
		l.ZIndex = 504
		l.Parent = detail
		return l
	end

	local dTitle = detailLabel("Title", 74, Theme.Font.Bold, Theme.TextSize.MD, Theme.Color.TextPrimary)
	local dMeta  = detailLabel("Meta", 52, Theme.Font.Label, Theme.TextSize.XS, Theme.Color.TextSecondary)
	local dHint  = detailLabel("Hint", 18, Theme.Font.Label, Theme.TextSize.XS, Theme.Color.TextSecondary)
	dHint.Size = UDim2.new(1, -32, 0, 30)
	dHint.TextWrapped = true
	dTitle.Text = "Pick a creation"
	dHint.Text = "Scroll to zoom. Approved creations are placeable in your city from Terrain \u{203A} Nature \u{203A} Creations."

	local previewModel: Model? = nil
	local spin: RBXScriptConnection? = nil
	local busy = false
	local current: any = nil

	-- Camera distance lives out here so the scroll wheel can move it while the orbit keeps
	-- running. `base` is the framing distance the model was fitted at, so the zoom limits
	-- scale with the thing being looked at: a fountain and a tower bottom out sensibly.
	local dist, baseDist = 0, 0
	local focus = Vector3.zero
	local ZOOM_MIN, ZOOM_MAX, ZOOM_STEP = 0.35, 2.5, 0.12

	local function clearPreview()
		if spin then spin:Disconnect(); spin = nil end
		if previewModel then previewModel:Destroy(); previewModel = nil end
	end

	viewport.InputChanged:Connect(function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseWheel then return end
		if baseDist <= 0 then return end
		-- Multiplicative, not additive: a fixed stud step crawls when zoomed out and
		-- overshoots through the model when zoomed in.
		local factor = 1 - (input.Position.Z * ZOOM_STEP)
		dist = math.clamp(dist * factor, baseDist * ZOOM_MIN, baseDist * ZOOM_MAX)
	end)

	local refreshTakeDown: () -> ()

	local function showItem(entry: any)
		if busy or not deps.onLoadPreview then return end
		busy = true
		current = entry
		refreshTakeDown()
		dTitle.Text = tostring(entry.name)
		dMeta.Text = "loading..."
		task.spawn(function()
			local res = deps.onLoadPreview(tostring(entry.bpId))
			if typeof(res) ~= "table" or typeof(res.blob) ~= "table" then
				busy = false
				dMeta.Text = "couldn't load this one"
				return
			end
			local model, count = CreationBuilder.build(res.blob, browseResolve)
			clearPreview()
			-- Released only now that the old preview is gone and the new one is built. It is
			-- safe today either way because CreationBuilder.build cannot yield, but releasing
			-- before the swap means the day it CAN yield, two of these interleave and orphan
			-- both a model and a live RenderStepped connection.
			busy = false
			if not model then
				dMeta.Text = "this creation is empty"
				return
			end
			model.Parent = viewport
			previewModel = model

			local cf, size = model:GetBoundingBox()
			local radius = math.max(size.X, size.Y, size.Z) * 0.5
			if radius <= 0 then radius = 4 end
			baseDist = (radius / math.tan(math.rad(cam.FieldOfView * 0.5))) * 1.5
			dist = baseDist -- every new pick starts framed, not at the last one's zoom
			focus = cf.Position
			local angle = 0
			spin = RunService.RenderStepped:Connect(function(dt)
				angle += dt * 0.35
				local offset = Vector3.new(math.cos(angle), 0.55, math.sin(angle)).Unit * dist
				cam.CFrame = CFrame.lookAt(focus + offset, focus)
			end)

			dMeta.Text = string.format("by %s  \u{00B7}  %s  \u{00B7}  %d parts",
				tostring(entry.ownerName ~= "" and entry.ownerName or "unknown"),
				string.upper(tostring(entry.cat or "")),
				count)
		end)
	end

	local function card(entry: any, order: number)
		local f = Instance.new("TextButton")
		f.Name = "Item_" .. tostring(entry.bpId)
		f.LayoutOrder = order
		f.BackgroundColor3 = Theme.Color.BgRaised
		f.BackgroundTransparency = 0.25
		f.BorderSizePixel = 0
		f.AutoButtonColor = true
		f.Text = ""
		f.ZIndex = 504
		f.Parent = grid
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, Theme.Radius.MD)
		c.Parent = f

		local n = Instance.new("TextLabel")
		n.BackgroundTransparency = 1
		n.Position = UDim2.fromOffset(12, 12)
		n.Size = UDim2.new(1, -24, 0, 20)
		n.FontFace = Theme.Font.Bold
		n.Text = tostring(entry.name)
		n.TextSize = Theme.TextSize.SM
		n.TextColor3 = Theme.Color.TextPrimary
		n.TextXAlignment = Enum.TextXAlignment.Left
		n.TextTruncate = Enum.TextTruncate.AtEnd
		n.ZIndex = 505
		n.Parent = f

		local who = Instance.new("TextLabel")
		who.BackgroundTransparency = 1
		who.Position = UDim2.fromOffset(12, 34)
		who.Size = UDim2.new(1, -24, 0, 16)
		who.FontFace = Theme.Font.Label
		who.Text = "by " .. tostring(entry.ownerName ~= "" and entry.ownerName or "unknown")
		who.TextSize = Theme.TextSize.XS
		who.TextColor3 = Theme.Color.TextSecondary
		who.TextXAlignment = Enum.TextXAlignment.Left
		who.TextTruncate = Enum.TextTruncate.AtEnd
		who.ZIndex = 505
		who.Parent = f

		local tag = Instance.new("TextLabel")
		tag.BackgroundTransparency = 1
		tag.AnchorPoint = Vector2.new(0, 1)
		tag.Position = UDim2.new(0, 12, 1, -10)
		tag.Size = UDim2.new(1, -24, 0, 16)
		tag.FontFace = Theme.Font.Label
		tag.Text = string.upper(tostring(entry.cat or ""))
		tag.TextSize = Theme.TextSize.XS
		tag.TextColor3 = Theme.Color.Accent
		tag.TextXAlignment = Enum.TextXAlignment.Left
		tag.ZIndex = 505
		tag.Parent = f

		f.Activated:Connect(function() showItem(entry) end)
	end

	-- Taking something out of the catalogue. Shown to whoever is actually allowed to do it:
	-- the creation's AUTHOR, who is entitled to stop sharing their own work, or a curator /
	-- admin dealing with something that should not have got through. This is presentation
	-- only -- ReviewQueue.unpublish re-decides on the server for every call.
	local takeDown = Button.new({
		text = "Take down",
		name = "TakeDown",
		parent = detail,
		variant = "Danger",
		compact = true,
		size = UDim2.fromOffset(112, 28),
		onClick = function()
			local entry = current
			if not entry or not deps.onTakeDown then return end
			dMeta.Text = "taking it down..."
			task.spawn(function()
				local ok, message = deps.onTakeDown(tostring(entry.bpId))
				dMeta.Text = tostring(message or (if ok then "Taken down." else "That didn't work."))
				if ok then
					clearPreview()
					current = nil
					dTitle.Text = "Pick a creation"
					refreshTakeDown()
					if browseReloadRef then browseReloadRef() end
				end
			end)
		end,
	})
	takeDown.Instance.AnchorPoint = Vector2.new(1, 1)
	takeDown.Instance.Position = UDim2.new(1, -16, 1, -52)
	takeDown.Instance.ZIndex = 505
	takeDown.Instance.Visible = false

	refreshTakeDown = function()
		local entry = current
		if not entry or not deps.onTakeDown then
			takeDown.Instance.Visible = false
			return
		end
		local me = game:GetService("Players").LocalPlayer
		local mine = me ~= nil and tonumber(entry.ownerId) == me.UserId
		local moderator = deps.canModerate ~= nil and deps.canModerate() == true
		takeDown.Instance.Visible = mine or moderator
		takeDown.Instance.Text = if mine and not moderator then "Withdraw" else "Take down"
	end

	local reloading = false
	local function reload()
		if reloading or not deps.onBrowse then return end
		reloading = true
		status.Text = "Loading the catalogue..."
		task.spawn(function()
			local rows = deps.onBrowse()
			reloading = false
			for _, ch in grid:GetChildren() do
				if ch:IsA("GuiObject") then ch:Destroy() end
			end
			if typeof(rows) ~= "table" or #rows == 0 then
				status.Text = "Nothing published yet."
				blurb.Visible = true
				return
			end
			blurb.Visible = false
			for i, e in rows do card(e, i) end
			status.Text = string.format("%d creation%s published by the community.",
				#rows, if #rows == 1 then "" else "s")
		end)
	end

	local refresh = Button.new({
		text = "Refresh",
		name = "RefreshBrowse",
		parent = header,
		size = UDim2.fromOffset(120, 32),
		onClick = reload,
	})
	refresh.Instance.AnchorPoint = Vector2.new(1, 0.5)
	refresh.Instance.Position = UDim2.new(1, 0, 0.5, 0)
	refresh.Instance.ZIndex = 505
	browseReloadRef = reload

	-- Stop orbiting the moment this pane stops being looked at. Without it the spin
	-- connection outlives the Content Hub: the overlay is cached and hidden, never
	-- destroyed, so a RenderStepped handler goes on posing a camera inside an invisible
	-- ViewportFrame for the rest of the session, and the previewed model stays parented to
	-- it. Watching Visible covers both leaving the tab and closing the hub.
	body:GetPropertyChangedSignal("Visible"):Connect(function()
		if not body.Visible then clearPreview() end
	end)

	-- The blurb doubles as the empty state, so it starts hidden and reload() decides.
	blurb.Visible = false
	blurb.Position = UDim2.fromScale(0.5, 0.5)
	return reload, clearPreview
end

function MainMenuView.buildContentHub(deps: {
	parent: Instance,
	onBack: () -> (),
	onOpenEditor: () -> (),
	-- Both yield. onBrowse returns the published rows; onLoadPreview returns one row's
	-- geometry. Optional so the hub still builds if the controller has not wired them.
	onBrowse: (() -> { any })?,
	onLoadPreview: ((string) -> any)?,
	-- Removing something already approved. Yields. The author may withdraw their own; a
	-- curator or admin may take down anyone's. The server decides -- canModerate only
	-- decides whether the button is drawn.
	onTakeDown: ((string) -> (boolean, string?))?,
	canModerate: (() -> boolean)?,
}): Frame
	local overlay = Instance.new("Frame")
	overlay.Name = "ContentHub"
	overlay.Active = true
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = Theme.Color.Bg
	overlay.BackgroundTransparency = 1
	overlay.BorderSizePixel = 0
	overlay.Visible = false
	overlay.ZIndex = 500
	overlay.Parent = deps.parent

	local topBar = Instance.new("Frame")
	topBar.Name = "TopBar"
	topBar.Size = UDim2.new(1, 0, 0, 64)
	topBar.BackgroundColor3 = Theme.Color.BgRaised
	topBar.BorderSizePixel = 0
	topBar.ZIndex = 501
	topBar.Parent = overlay

	local hairline = Instance.new("Frame")
	hairline.Name = "Hairline"
	hairline.AnchorPoint = Vector2.new(0, 1)
	hairline.Position = UDim2.fromScale(0, 1)
	hairline.Size = UDim2.new(1, 0, 0, 1)
	hairline.BackgroundColor3 = Theme.Color.Stroke
	hairline.BorderSizePixel = 0
	hairline.ZIndex = 502
	hairline.Parent = topBar

	local back = Instance.new("TextButton")
	back.Name = "Back"
	back.AnchorPoint = Vector2.new(0, 0.5)
	back.Position = UDim2.new(0, 20, 0.5, 0)
	back.Size = UDim2.fromOffset(96, 34)
	back.BackgroundColor3 = Theme.Color.BgHover
	back.AutoButtonColor = true
	back.BorderSizePixel = 0
	back.FontFace = Theme.Font.Bold
	back.Text = "< Back"
	back.TextSize = Theme.TextSize.SM
	back.TextColor3 = Theme.Color.TextPrimary
	back.ZIndex = 503
	back.Parent = topBar
	local backCorner = Instance.new("UICorner")
	backCorner.CornerRadius = UDim.new(0, Theme.Radius.MD)
	backCorner.Parent = back
	back.Activated:Connect(function()
		deps.onBack()
	end)

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.AnchorPoint = Vector2.new(0, 0.5)
	title.Position = UDim2.new(0, 132, 0.5, 0)
	title.Size = UDim2.fromOffset(260, 34)
	title.FontFace = Theme.Font.Bold
	title.Text = "CONTENT HUB"
	title.TextSize = Theme.TextSize.LG
	title.TextColor3 = Theme.Color.TextPrimary
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 503
	title.Parent = topBar

	local tabHolder = Instance.new("Frame")
	tabHolder.Name = "Tabs"
	tabHolder.BackgroundTransparency = 1
	tabHolder.AnchorPoint = Vector2.new(0.5, 0.5)
	tabHolder.Position = UDim2.fromScale(0.5, 0.5)
	tabHolder.Size = UDim2.fromOffset(380, 64)
	tabHolder.ZIndex = 503
	tabHolder.Parent = topBar
	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	tabLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	tabLayout.Padding = UDim.new(0, 8)
	tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tabLayout.Parent = tabHolder

	local bodyHolder = Instance.new("Frame")
	bodyHolder.Name = "Body"
	bodyHolder.BackgroundTransparency = 1
	bodyHolder.Position = UDim2.fromOffset(0, 64)
	bodyHolder.Size = UDim2.new(1, 0, 1, -64)
	bodyHolder.ZIndex = 501
	bodyHolder.Parent = overlay

	local tabButtons: { [string]: TextButton } = {}
	local tabBodies: { [string]: Frame } = {}
	local browseReload: (() -> ())? = nil
	local browseStop: (() -> ())? = nil

	local function selectTab(active: string)
		for _, name in CONTENT_HUB_TABS do
			local isActive = name == active
			tabButtons[name].TextColor3 = if isActive then Theme.Color.Accent else Theme.Color.TextSecondary
			tabBodies[name].Visible = isActive
		end
		if active == "Browsing" and browseReload then browseReload() end
	end

	for i, name in CONTENT_HUB_TABS do
		local tab = Instance.new("TextButton")
		tab.Name = name
		tab.LayoutOrder = i
		tab.BackgroundTransparency = 1
		tab.AutoButtonColor = false
		tab.Size = UDim2.fromOffset(112, 40)
		tab.FontFace = Theme.Font.Header
		tab.Text = name
		tab.TextSize = Theme.TextSize.MD
		tab.TextColor3 = Theme.Color.TextSecondary
		tab.ZIndex = 503
		tab.Parent = tabHolder

		local body = Instance.new("Frame")
		body.Name = name .. "Body"
		body.BackgroundTransparency = 1
		body.Size = UDim2.fromScale(1, 1)
		body.Visible = false
		body.ZIndex = 501
		body.Parent = bodyHolder

		local blurb = Instance.new("TextLabel")
		blurb.BackgroundTransparency = 1
		blurb.AnchorPoint = Vector2.new(0.5, 0.5)
		blurb.Position = UDim2.fromScale(0.5, 0.5)
		blurb.Size = UDim2.fromOffset(560, 60)
		blurb.FontFace = Theme.Font.Label
		blurb.Text = CONTENT_HUB_BLURB[name]
		blurb.TextSize = Theme.TextSize.MD
		blurb.TextColor3 = Theme.Color.TextSecondary
		blurb.TextWrapped = true
		blurb.ZIndex = 502
		blurb.Parent = body

		if name == "Browsing" then
			-- Loaded when the tab is first shown rather than at build time: the hub is built
			-- on first open and the catalogue can change while the menu sits there.
			browseReload, browseStop = buildBrowsePane(body, blurb, deps)
		elseif name == "Creation" then
			blurb.Position = UDim2.fromScale(0.5, 0.42)
			local open = Button.new({
				text = "Open Editor",
				name = "OpenEditor",
				parent = body,
				size = UDim2.fromOffset(220, 46),
				textSize = Theme.TextSize.MD,
				onClick = deps.onOpenEditor,
			})
			open.Instance.AnchorPoint = Vector2.new(0.5, 0.5)
			open.Instance.Position = UDim2.fromScale(0.5, 0.56)
			open.Instance.ZIndex = 503
		end

		tabButtons[name] = tab
		tabBodies[name] = body
		tab.Activated:Connect(function()
			selectTab(name)
		end)
	end

	-- Belt and braces alongside the per-body watcher: hiding the whole overlay must also
	-- stop the orbit, and the overlay is hidden rather than destroyed when the hub closes.
	overlay:GetPropertyChangedSignal("Visible"):Connect(function()
		if not overlay.Visible and browseStop then browseStop() end
	end)

	selectTab(CONTENT_HUB_TABS[1])
	return overlay
end


-- ── Menu construction primitives (moved out of MainMenuController) ───
-- Palette-agnostic builders shared by the menu's modal views. Pure construction.
local UserInputService = game:GetService("UserInputService")

local function makeLabel(parent: Instance, text: string, order: number, secondary: boolean, palette: any?): TextLabel
	local C = palette or Theme.Color
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.FontFace = if secondary then Theme.Font.Label else Theme.Font.Header
	label.TextSize = if secondary then Theme.TextSize.XS else Theme.TextSize.SM
	label.TextColor3 = if secondary then C.TextSecondary else C.TextPrimary
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = text
	label.Size = UDim2.new(1, 0, 0, if secondary then 16 else 18)
	label.LayoutOrder = order
	label.Parent = parent
	return label
end

local function makeTextBox(parent: Instance, placeholder: string, order: number, palette: any?): TextBox
	local C = palette or Theme.Color
	local box = Instance.new("TextBox")
	box.BackgroundColor3 = C.BgRaised
	box.BorderSizePixel = 0
	box.ClearTextOnFocus = false
	box.FontFace = Theme.Font.Label
	box.PlaceholderText = placeholder
	box.PlaceholderColor3 = C.TextDisabled
	box.Text = ""
	box.TextColor3 = C.TextPrimary
	box.TextSize = Theme.TextSize.SM
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.Size = UDim2.new(1, 0, 0, 34)
	box.LayoutOrder = order
	box.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Theme.Radius.SM)
	corner.Parent = box

	local stroke = Instance.new("UIStroke")
	stroke.Color = C.StrokeSoft
	stroke.Thickness = Theme.StrokeWidth.Thin
	stroke.Parent = box

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, Theme.Pad.MD)
	pad.PaddingRight = UDim.new(0, Theme.Pad.MD)
	pad.Parent = box

	return box
end

local function makeRow(parent: Instance, order: number, height: number): (Frame, UIListLayout)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, height)
	row.LayoutOrder = order
	row.Parent = parent

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.Padding = UDim.new(0, Theme.Pad.SM)
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = row

	return row, list
end

local function setupContent(content: Frame)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, Theme.Pad.MD)
	pad.PaddingBottom = UDim.new(0, Theme.Pad.MD)
	pad.PaddingLeft = UDim.new(0, Theme.Pad.LG)
	pad.PaddingRight = UDim.new(0, Theme.Pad.LG)
	pad.Parent = content

	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, Theme.Pad.MD)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = content
end

-- Menu dialogs use the same minimal UIKit surface as the in-game tools.
local MENU_PANEL_COLOR = Theme.Color.Bg
local MENU_SCRIM_COLOR = Theme.Color.Scrim
local MENU_PANEL_TRANSPARENCY = 0.04
local MENU_CORNER_RADIUS = Theme.Radius.LG

local function glassifyModal(modal: any, _accent: boolean?)
	local scrim = modal.Root
	if scrim:IsA("Frame") then
		scrim.BackgroundColor3 = MENU_SCRIM_COLOR
		local oldAccent = scrim:FindFirstChild("GlassAccent")
		if oldAccent then
			oldAccent:Destroy()
		end
	end

	local panel = scrim:FindFirstChild("Panel")
	if not panel or not panel:IsA("CanvasGroup") then
		return
	end

	panel.BackgroundColor3 = MENU_PANEL_COLOR
	panel.BackgroundTransparency = MENU_PANEL_TRANSPARENCY

	local oldSheen = panel:FindFirstChild("GlassSheen")
	if oldSheen then
		oldSheen:Destroy()
	end

	local corner = panel:FindFirstChildOfClass("UICorner")
	if corner then
		corner.CornerRadius = UDim.new(0, MENU_CORNER_RADIUS)
	end

	local stroke = panel:FindFirstChildOfClass("UIStroke")
	if not stroke then
		stroke = Instance.new("UIStroke")
		stroke.Parent = panel
	end
	stroke.Color = Theme.Color.Stroke
	stroke.Thickness = Theme.StrokeWidth.Thin
	stroke.Transparency = 0

	local strokeGradient = stroke:FindFirstChildOfClass("UIGradient")
	if strokeGradient then
		strokeGradient:Destroy()
	end
end

-- A compact labelled slider for the map generator. onChange(value) fires live while
-- dragging; the returned setter pushes a value in without firing onChange.
local function makeSlider(parent: Instance, order: number, labelText: string, minV: number, maxV: number, default: number, onChange: (number) -> (), palette: any?): (number) -> ()
	local C = palette or Theme.Color
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 28)
	row.LayoutOrder = order
	row.Parent = parent

	local name = Instance.new("TextLabel")
	name.BackgroundTransparency = 1
	name.FontFace = Theme.Font.Label
	name.TextSize = Theme.TextSize.SM
	name.TextColor3 = C.TextSecondary
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.Text = labelText
	name.Size = UDim2.new(0, 118, 1, 0)
	name.Parent = row

	local valueLabel = Instance.new("TextLabel")
	valueLabel.BackgroundTransparency = 1
	valueLabel.FontFace = Theme.Font.Label
	valueLabel.TextSize = Theme.TextSize.SM
	valueLabel.TextColor3 = C.TextPrimary
	valueLabel.TextXAlignment = Enum.TextXAlignment.Right
	valueLabel.AnchorPoint = Vector2.new(1, 0)
	valueLabel.Position = UDim2.fromScale(1, 0)
	valueLabel.Size = UDim2.new(0, 40, 1, 0)
	valueLabel.Parent = row

	local track = Instance.new("Frame")
	track.BackgroundColor3 = C.Stroke
	track.BorderSizePixel = 0
	track.AnchorPoint = Vector2.new(0, 0.5)
	track.Position = UDim2.new(0, 126, 0.5, 0)
	track.Size = UDim2.new(1, -174, 0, 6)
	track.Parent = row
	local tc = Instance.new("UICorner"); tc.CornerRadius = UDim.new(1, 0); tc.Parent = track

	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = C.Accent
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(0, 1)
	fill.Parent = track
	local fc = Instance.new("UICorner"); fc.CornerRadius = UDim.new(1, 0); fc.Parent = fill

	local knob = Instance.new("Frame")
	knob.BackgroundColor3 = C.AccentHover
	knob.BorderSizePixel = 0
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.fromScale(0, 0.5)
	knob.Size = UDim2.fromOffset(12, 12)
	knob.ZIndex = 2
	knob.Parent = track
	local kc = Instance.new("UICorner"); kc.CornerRadius = UDim.new(1, 0); kc.Parent = knob

	local function apply(v: number, fire: boolean)
		local value = math.clamp(v, minV, maxV)
		local frac = if maxV > minV then (value - minV) / (maxV - minV) else 0
		fill.Size = UDim2.fromScale(frac, 1)
		knob.Position = UDim2.fromScale(frac, 0.5)
		valueLabel.Text = tostring(math.round(value))
		if fire then onChange(value) end
	end

	local hit = Instance.new("TextButton")
	hit.BackgroundTransparency = 1
	hit.Text = ""
	hit.AnchorPoint = Vector2.new(0.5, 0.5)
	hit.Position = UDim2.fromScale(0.5, 0.5)
	hit.Size = UDim2.new(1, 0, 4, 0)
	hit.ZIndex = 3
	hit.Parent = track

	local function setFromX(px: number)
		local absX = track.AbsolutePosition.X
		local w = math.max(track.AbsoluteSize.X, 1)
		apply(minV + (maxV - minV) * math.clamp((px - absX) / w, 0, 1), true)
	end

	local dragging = false
	hit.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			setFromX(input.Position.X)
		end
	end)
	hit.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
	-- ponytail: one InputChanged connection per slider, lives for the session (the menu
	-- modal is built once and never destroyed). Fine for a handful of sliders.
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			setFromX(input.Position.X)
		end
	end)

	apply(default, false)
	return function(v: number) apply(v, false) end
end

-- One terrain-type tile: the uploaded satellite icon for that macro shape + a caption, clickable.
local function makeShapeTile(parent: Instance, order: number, shape: any, onClick: () -> (), palette: any?): { setSelected: (boolean) -> () }
	local C = palette or Theme.Color
	local btn = Instance.new("TextButton")
	btn.AutoButtonColor = false
	btn.BackgroundColor3 = C.BgRaised
	btn.BorderSizePixel = 0
	btn.Text = ""
	btn.Size = UDim2.fromOffset(86, 90)
	btn.LayoutOrder = order
	btn.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Theme.Radius.MD)
	corner.Parent = btn

	local stroke = Instance.new("UIStroke")
	stroke.Color = C.Stroke
	stroke.Thickness = 1
	stroke.Parent = btn

	local img = Instance.new("ImageLabel")
	img.BackgroundColor3 = C.BgHover
	img.BorderSizePixel = 0
	img.Image = shape.icon
	img.ScaleType = Enum.ScaleType.Crop
	img.AnchorPoint = Vector2.new(0.5, 0)
	img.Position = UDim2.new(0.5, 0, 0, 5)
	img.Size = UDim2.new(1, -10, 0, 56)
	img.Parent = btn
	local ic = Instance.new("UICorner")
	ic.CornerRadius = UDim.new(0, Theme.Radius.SM)
	ic.Parent = img

	local cap = Instance.new("TextLabel")
	cap.BackgroundTransparency = 1
	cap.FontFace = Theme.Font.Label
	cap.TextSize = Theme.TextSize.XS
	cap.TextColor3 = C.TextSecondary
	cap.TextTruncate = Enum.TextTruncate.AtEnd
	cap.Text = shape.name
	cap.Position = UDim2.fromOffset(4, 64)
	cap.Size = UDim2.new(1, -8, 0, 20)
	cap.Parent = btn

	btn.Activated:Connect(onClick)

	local function setSelected(sel: boolean)
		stroke.Color = if sel then C.Accent else C.Stroke
		stroke.Thickness = if sel then 2 else 1
		cap.TextColor3 = if sel then C.TextPrimary else C.TextSecondary
	end

	return { setSelected = setSelected }
end

-- The four natural-resource meters for a map (Water / Wood / Farmland / Oil). Returns
-- a setter the picker calls whenever the selected map or its generator knobs change.
local function makeResourceMeters(parent: Instance, order: number, palette: any?): (res: MapResources.Resources) -> ()
	local C = palette or Theme.Color

	local holder = Instance.new("Frame")
	holder.Name = "Resources"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(1, 0, 0, #MapResources.List * 26)
	holder.LayoutOrder = order
	holder.Parent = parent

	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 4)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = holder

	local fills: { [string]: Frame } = {}
	local values: { [string]: TextLabel } = {}

	for i, res in MapResources.List do
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, 22)
		row.LayoutOrder = i
		row.Parent = holder

		local name = Instance.new("TextLabel")
		name.BackgroundTransparency = 1
		name.FontFace = Theme.Font.Label
		name.TextSize = Theme.TextSize.XS
		name.TextColor3 = C.TextSecondary
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.Text = res.name
		name.Size = UDim2.new(0, 76, 1, 0)
		name.Parent = row

		local track = Instance.new("Frame")
		track.BackgroundColor3 = C.BgPress
		track.BorderSizePixel = 0
		track.AnchorPoint = Vector2.new(0, 0.5)
		track.Position = UDim2.new(0, 80, 0.5, 0)
		track.Size = UDim2.new(1, -172, 0, 8)
		track.Parent = row
		local tc = Instance.new("UICorner"); tc.CornerRadius = UDim.new(1, 0); tc.Parent = track

		local fill = Instance.new("Frame")
		fill.BackgroundColor3 = res.color
		fill.BorderSizePixel = 0
		fill.Size = UDim2.fromScale(0, 1)
		fill.Parent = track
		local fc = Instance.new("UICorner"); fc.CornerRadius = UDim.new(1, 0); fc.Parent = fill

		local value = Instance.new("TextLabel")
		value.BackgroundTransparency = 1
		value.FontFace = Theme.Font.Label
		value.TextSize = Theme.TextSize.XS
		value.TextColor3 = C.TextPrimary
		value.TextXAlignment = Enum.TextXAlignment.Right
		value.AnchorPoint = Vector2.new(1, 0)
		value.Position = UDim2.fromScale(1, 0)
		value.Size = UDim2.new(0, 84, 1, 0)
		value.Text = ""
		value.Parent = row

		fills[res.id] = fill
		values[res.id] = value
	end

	return function(res: MapResources.Resources)
		for _, entry in MapResources.List do
			local v = math.clamp(tonumber((res :: any)[entry.id]) or 0, 0, 100)
			fills[entry.id].Size = UDim2.fromScale(v / 100, 1)
			values[entry.id].Text = MapResources.rank(v)
		end
	end
end

MainMenuView.makeLabel = makeLabel
MainMenuView.makeTextBox = makeTextBox
MainMenuView.makeRow = makeRow
MainMenuView.setupContent = setupContent
MainMenuView.glassifyModal = glassifyModal
MainMenuView.makeSlider = makeSlider
MainMenuView.makeShapeTile = makeShapeTile
MainMenuView.makeResourceMeters = makeResourceMeters

return MainMenuView
