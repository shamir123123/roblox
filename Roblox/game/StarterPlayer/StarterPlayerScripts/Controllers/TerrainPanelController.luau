--!strict
-- Terrain tools on the shared build dock (bottom-right), same bones as the
-- Roads / Zoning pages: info = title + brush size, rail = sculpt tools,
-- center = material cards, tabs = Sculpt / Trails / Props.
-- Drives TerrainEditController through its public API. BottomBarController
-- owns the dock and hands it over via InitDock; Open/Close/IsOpen stay so
-- existing consumers (bottom bar, FreeCam) keep working.

local uiFolder = script.Parent.Parent:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local UITween = require(uiFolder:WaitForChild("UITween"))
local Icons = require(uiFolder:WaitForChild("Icons"))
local kit = uiFolder:WaitForChild("Kit")
local Dock = require(kit:WaitForChild("Dock"))
local IconButton = require(kit:WaitForChild("IconButton"))

local Terrain = require(script.Parent:WaitForChild("TerrainEditController"))

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local NatureCatalog = require(ReplicatedStorage:WaitForChild("Nature"):WaitForChild("NatureCatalog"))
local Nature = require(script.Parent:WaitForChild("NaturePlacementController"))
-- Precise mode's own settings surface (snapping, space, pivot, colour, material,
-- collisions). It builds itself the first time Precise goes on and lives on the left edge,
-- clear of this dock.
-- The shape builder's settings, as a second group of buttons on this dock's own RAIL --
-- colour, the three snap channels, precise, elevation, collisions and materials. It replaced
-- a left-edge panel (PreciseBuildPanel, now unused): every setting on that panel was two
-- surfaces away from the cards it applied to, and its title said "Nature" long after the
-- shelf had stopped being only that.
local BuildRail = require(script.Parent:WaitForChild("BuildRail"))
-- The colour menu: the palette, a Custom mode and five saved slots. Shared with the
-- Precise panel's swatch, so there is one picker in the game and not two.
local ColorPanel = require(script.Parent:WaitForChild("ColorPanel"))
-- Player-made creations shelve alongside the built-in scenery, so they share this tab.
local Creations = require(script.Parent:WaitForChild("CreationPlacementController"))
-- Free Placement's independent on/off state -- NOT one of Nature's four gestures. Read
-- directly here (rather than through Nature) since the rail toggle for it sits alongside,
-- not inside, the mode-exclusive button set below.
local FreePlacement = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("FreePlacement"))
-- The free-placement engine owns the placement grid. The setting is module-level there and
-- shared by every tool that places through it (creations here, service buildings from the
-- build flyouts), so this row is a view onto ONE setting, not the Nature tab's own.
local GhostPlacement = require(script.Parent:WaitForChild("GhostPlacement"))

local TerrainPanelController = {}

local RADIUS_STEP = 4
local CARD_W = 80
local CARD_H = 60
local CARD_GAP = 6

local OP_DEFS = {
	{ key = "Raise", label = "Raise", icon = Icons.TerrainRaise },
	{ key = "Lower", label = "Lower", icon = Icons.TerrainLower },
	{ key = "Flatten", label = "Flatten", icon = Icons.TerrainFlatten },
	{ key = "Smooth", label = "Smooth", icon = Icons.TerrainSmooth },
	{ key = "Level", label = "Level", icon = Icons.TerrainLevel },
	{ key = "SetMaterial", label = "Paint", icon = Icons.TerrainPaint },
}

-- Card swatch colours per material name (visual only).
local MAT_COLORS: { [string]: Color3 } = {
	Grass = Color3.fromRGB(106, 158, 80),
	Sand = Color3.fromRGB(216, 196, 150),
	Rock = Color3.fromRGB(130, 132, 136),
	Snow = Color3.fromRGB(235, 240, 244),
	Ground = Color3.fromRGB(150, 116, 84),
	Mud = Color3.fromRGB(110, 86, 66),
}

local _started = false
local _dock: Dock.Dock? = nil
local _page: Dock.Page? = nil
local _open = false
local _activeTab = "Sculpt"
local _opButtons: { [string]: IconButton.IconButton } = {}
local _matStrokes: { [number]: UIStroke } = {}
local _radiusLabel: TextLabel? = nil
local _infoCap: TextLabel? = nil
-- The page's own heading. It reads "Terrain" on Sculpt and takes the shelf's name on the two
-- card tabs, which is the only thing telling Nature and Build apart once the strip is up.
local _infoTitle: TextLabel? = nil
local _matsRow: GuiObject? = nil
local _placeholder: TextLabel? = nil
local _listener: ((open: boolean) -> ())? = nil
local _naturePanel: Frame? = nil
local _brushFrame: Frame? = nil
-- The game-wide grid picker: Nature and Build place things, so it takes the brush's slot there.
local _gridFrame: Frame? = nil
local _refreshNature: (() -> ())? = nil
local _natureModeButtons: { [string]: IconButton.IconButton } = {}
-- Independent toggle, NOT part of the mode-exclusive set above -- its own SetSelected
-- state, driven off FreePlacement.isEnabled() rather than off Nature.getMode().
local _freePlaceButton: IconButton.IconButton? = nil

-- Every key but the last is a NatureCatalog `kind` value, so the chips filter the built-in
-- cards directly. "Creation" matches no catalog entry on purpose: that alone hides every
-- nature card when the shelf is up, with no extra branch in the filter.
-- No "Lot" chip: car parks are working infrastructure, not scenery, and live on the Roads
-- dock's Parking tab (RoadDockPanel). They still place through this tool -- the tab there
-- just drives it -- so their cards simply never match a category here.
-- Split across TWO tabs since 2026-09-17. NATURE dresses a map -- trees, bushes, rocks --
-- and BUILD is the custom half: the primitives you assemble a building out of, and the
-- player's own saved creations. Same shelf, same placement tool, same cards; the tab only
-- decides which chips are on it. They were one strip of five chips, and a player building a
-- house had to scroll past the shrubbery to reach a cube.
local NATURE_CATEGORIES = {
	{ key = "Tree", label = "Trees", tab = "Nature" },
	{ key = "Bush", label = "Bushes", tab = "Nature" },
	{ key = "Rock", label = "Rocks", tab = "Nature" },
	-- The shapes shelf is split by FORM, the way a building kit is sorted: sixty blocks in
	-- one strip was a wall of grey you had to scroll to search.
	{ key = "ShapeBlocks", label = "Blocks", tab = "Build" },
	{ key = "ShapeRound", label = "Round", tab = "Build" },
	{ key = "ShapeBuilding", label = "Building", tab = "Build" },
	{ key = "ShapeDetails", label = "Details", tab = "Build" },
	{ key = "ShapeNumbers", label = "Numbers", tab = "Build" },
	{ key = "Creation", label = "Creations", tab = "Build" },
}
local ShapeCatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ShapeCatalog"))
-- The shelf category a catalog card files under: its kind, or a shape's form group.
local function cardCategory(key: string, kind: string): string
	return if kind == "Shape" then "Shape" .. ShapeCatalog.groupOf(key) else kind
end
local CATEGORY_TAB: { [string]: string } = {}
local TAB_FIRST_CATEGORY: { [string]: string } = {}
for _, cat in NATURE_CATEGORIES do
	CATEGORY_TAB[cat.key] = cat.tab
	if not TAB_FIRST_CATEGORY[cat.tab] then TAB_FIRST_CATEGORY[cat.tab] = cat.key end
end
-- Both shelf tabs drive ONE placement tool, so everything below asks "is a shelf up?"
-- rather than naming a tab -- otherwise every Nature check here becomes a pair.
local function isShelfTab(key: string): boolean
	return TAB_FIRST_CATEGORY[key] ~= nil
end
local _natureCategory = "Tree"

-- BUILD IS ITS OWN TOOL, with its own button on the bottom bar beside Terrain -- not a tab
-- buried under it. It shares this dock PAGE (the card strip, the 3D previews and the
-- placement tool are the same machinery and a second copy of them would drift), but never
-- the same tab strip: opening from Terrain shows Sculpt / Nature / Trails, opening from
-- Build shows Build alone. Which entry point opened it is the only thing `_pageMode` says.
local TAB_MODE: { [string]: string } = {
	Sculpt = "Terrain", Nature = "Terrain", Trails = "Terrain", Build = "Build",
}
local MODE_HOME: { [string]: string } = { Terrain = "Sculpt", Build = "Build" }
local _pageMode = "Terrain"


-- Horizontal card strip: scrolls only on X, so the mouse wheel moves the row (the frame
-- sinks the wheel, so the camera never zooms while the pointer is over the dock).
-- AutomaticCanvasSize keeps the canvas exactly as wide as the visible cards.
local function hScroller(padding: number): ScrollingFrame
	local sf = Instance.new("ScrollingFrame")
	sf.BackgroundTransparency = 1
	sf.BorderSizePixel = 0
	sf.Active = true
	sf.ScrollingDirection = Enum.ScrollingDirection.X
	sf.AutomaticCanvasSize = Enum.AutomaticSize.X
	sf.CanvasSize = UDim2.new()
	sf.ScrollBarThickness = 4
	sf.ScrollBarImageColor3 = Theme.Color.Accent
	sf.ScrollBarImageTransparency = 0.25
	sf.ElasticBehavior = Enum.ElasticBehavior.Never
	local l = Instance.new("UIListLayout")
	l.FillDirection = Enum.FillDirection.Horizontal
	l.VerticalAlignment = Enum.VerticalAlignment.Center
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Padding = UDim.new(0, padding)
	l.Parent = sf
	return sf
end

local function corner(inst: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = inst
end

local function refreshSculpt()
	local op = Terrain.getOp()
	for key, btn in _opButtons do
		btn:SetSelected(key == op)
	end
	local mat = Terrain.getMaterialIndex()
	for i, stroke in _matStrokes do
		stroke.Color = if i == mat then Theme.Color.Accent else Theme.Color.StrokeSoft
		stroke.Thickness = if i == mat then Theme.StrokeWidth.Thick else Theme.StrokeWidth.Thin
	end
	if _radiusLabel then
		_radiusLabel.Text = tostring(Terrain.getRadius())
	end
	if _infoCap then
		local label = op
		for _, def in OP_DEFS do
			if def.key == op then
				label = def.label
			end
		end
		_infoCap.Text = label .. " tool  \u{00B7}  hold LMB and drag to sculpt"
	end
end

local function selectTab(key: string)
	local shelf = isShelfTab(key)
	-- Each shelf tab owns its own chips, so entering one lands on a category it actually
	-- SHOWS. Without this, Build opens on Trees and the strip is empty.
	if shelf and CATEGORY_TAB[_natureCategory] ~= key then
		_natureCategory = TAB_FIRST_CATEGORY[key]
		-- Each shelf keeps its own picks, exactly as the chips themselves do.
		Nature.clearSelection()
	end
	_activeTab = key
	local page = _page
	if page then
		page:SetTab(key)
	end
	-- The rail shows the active tab's own tools: sculpt ops on Sculpt, Line/Brush on a shelf.
	local isSculpt = key == "Sculpt"
	for _, btn in _opButtons do btn.Instance.Visible = isSculpt end
	-- Build stamps ONE item per click, so the Line/Curve/Freeform gestures are
	-- Nature-only; on Build there is nothing for them to change.
	local gestures = shelf and key ~= "Build"
	for _, btn in _natureModeButtons do btn.Instance.Visible = gestures end
	if _freePlaceButton then _freePlaceButton.Instance.Visible = gestures end
	if _matsRow then
		_matsRow.Visible = key == "Sculpt"
	end
	if _naturePanel then
		_naturePanel.Visible = shelf
	end
	if _infoTitle then
		(_infoTitle :: TextLabel).Text = if key == "Build" then "Build" elseif shelf then "Nature" else "Terrain"
	end
	-- The Info-bar brush stepper only tunes the terrain brush; hide it off the Sculpt tab.
	if _brushFrame then
		_brushFrame.Visible = key == "Sculpt"
	end
	if _gridFrame then
		_gridFrame.Visible = shelf
	end
	if _placeholder then
		_placeholder.Visible = key == "Trails"
		_placeholder.Text = if key == "Trails"
			then "Trails (dirt roads & paths) \u{2014} coming soon."
			else ""
	end
	-- Sculpt drives the terrain brush; Nature drives its own placement tool; the rest are idle.
	Terrain.setEnabled(_open and key == "Sculpt")
	-- Leaving the tab leaves Precise: the handles, the settings panel and the ghost all
	-- belong to a tab that is no longer on screen, and a preview left riding the cursor is
	-- a placement waiting to happen somewhere the player is not looking. setEnabled(false)
	-- clears the preview and drops the gizmo; this is what stops the mode itself surviving.
	if not shelf then Nature.setPrecise(false); ColorPanel.close() end
	Nature.setEnabled(_open and shelf)
	-- Creations lives on the Build shelf and is chosen by its own chip, so park it on every
	-- tab change and let refresh() below decide whether it takes the cursor back.
	Creations.setEnabled(false)
	if key == "Sculpt" then
		refreshSculpt()
	elseif shelf and _refreshNature then
		_refreshNature()
	elseif _infoCap then
		_infoCap.Text = ""
	end
end

-- Tall enough for a real 3D preview above the name. A colour dot told you nothing about a
-- shape -- sixty grey dots labelled "Half Pipe" is a list, not a palette.
local NATURE_CARD_W = 88
-- Matches the shelf's card row (BuildCard CARD_H).
local NATURE_CARD_H = 76
local NATURE_LABEL_H = 22
-- Fill a card's viewport when it comes within this much of the visible strip, so scrolling
-- never shows an empty box.
local PREVIEW_MARGIN = 120

-- The Nature tab's content: a Randomize toggle, a spacing/brush stepper, and the asset
-- palette. Line/Brush are rail tools now (see InitDock). Selected chips FLIP to the near-
-- white accent fill (matching the sculpt tools), not a border. Drives NaturePlacementController.
local function buildNaturePanel(page: Dock.Page)
	local content = page.Content
	local toolsHost = page.Tools
	local panel = Instance.new("Frame")
	panel.Name = "NaturePanel"
	panel.BackgroundTransparency = 1
	panel.Size = UDim2.fromScale(1, 1)
	panel.Visible = false
	panel.Parent = content
	_naturePanel = panel

	local assetCards: { [string]: { frame: Frame, label: TextLabel, kind: string, key: string, viewport: ViewportFrame, filled: boolean } } = {}
	-- Assigned once the card strip exists; refresh() calls it before then.
	local updatePreviews: () -> () = function() end
	local categoryButtons: { [string]: TextButton } = {}
	-- Creations are FETCHED per player rather than catalogued, so these cards are built on
	-- demand and thrown away on every refetch -- unlike the nature cards, which are built
	-- once and only toggled. Single-select: a creation is one model riding the cursor, not
	-- a brush mix, so this is one id and not a set.
	local creationCards: { [string]: { frame: Frame, label: TextLabel } } = {}
	local selectedCreation: string? = nil
	local creationsBusy = false
	local stepLabel: TextLabel? = nil
	local stepCap: TextLabel? = nil
	local randBtn: TextButton? = nil
	local stepperFrame: Frame? = nil


	-- Line and Curve both stamp a row at a stud interval, so they share the "spacing"
	-- stepper; Brush uses the same stepper for its radius; Single has neither (one click,
	-- one plant -- there's nothing to step).
	local function usesSpacing(mode: string): boolean
		return mode == "Line" or mode == "Curve"
	end

	-- Flip a chip between the dark "off" look and the near-white accent "on" look.
	local function flip(bg: GuiObject, label: TextLabel, on: boolean)
		bg.BackgroundColor3 = if on then Theme.Color.Accent else Theme.Color.BgRaised
		bg.BackgroundTransparency = if on then 0 else 0.2
		label.TextColor3 = if on then Theme.Color.OnAccent else Theme.Color.TextPrimary
	end

	local function refresh()
		-- Before the `not _open` bail below: the settings panel has to be able to HIDE when
		-- the dock closes, and a refresh that returns early would leave it on screen over a
		-- tool that is no longer running.
		BuildRail.sync()
		local mode = Nature.getMode()
		-- The Creations shelf shares this tab. While its chip is up the Nature gesture
		-- controls are inert, so they hide and its own tool takes the cursor instead.
		local placingCreation = _natureCategory == "Creation"
		for key, btn in _natureModeButtons do btn:SetSelected(key == mode) end
		if _freePlaceButton then _freePlaceButton:SetSelected(FreePlacement.isEnabled()) end
		local showStepper = mode ~= "Single" and not placingCreation
		if stepperFrame then stepperFrame.Visible = showStepper end
		if stepLabel then
			stepLabel.Text = if usesSpacing(mode) then tostring(Nature.getSpacing()) else tostring(Nature.getBrushRadius())
		end
		if stepCap then stepCap.Text = if usesSpacing(mode) then "spacing" else "brush" end
		if randBtn then
			flip(randBtn, randBtn :: any, Nature.getRandomize())
			-- Randomize rolls a tree's size and angle. A building block is placed exactly as
			-- asked, so on the Build shelf the chip would be a switch that does nothing.
			randBtn.Visible = CATEGORY_TAB[_natureCategory] == "Nature"
		end
		local shapeShelf = string.sub(_natureCategory, 1, 5) == "Shape"
		-- The card strip FILLS the content area; it is not re-placed here. This used
		-- to pin it to y=58 at NATURE_CARD_H + 6 tall, which was written for a 320px
		-- page. Against the 120 shelf it put a 118px strip 58px down inside a 60px
		-- clipping frame -- so every card rendered below the visible band and the
		-- Build shelf looked empty.
		for key, ref in assetCards do
			ref.frame.Visible = ref.kind == _natureCategory
			flip(ref.frame, ref.label, Nature.isAssetSelected(key))
		end
		updatePreviews()
		for id, ref in creationCards do
			ref.frame.Visible = placingCreation
			flip(ref.frame, ref.label, id == selectedCreation)
		end
		-- Nature and Creations are both cursor placement tools, and exactly one may ever be
		-- live -- two at once is a click landing in two places. selectTab parks Creations on
		-- every tab change; this decides which of the two owns the cursor on the Nature tab.
		-- Only while THIS panel is open. Nature's state listener is global, so a card click on
		-- the Roads dock's Parking tab lands here too -- and unguarded, this line would switch
		-- the placement tool off underneath the tab that had just armed it.
		local natureTabLive = _open and isShelfTab(_activeTab)
		if not _open then return end
		Nature.setEnabled(natureTabLive and not placingCreation)
		-- ...and a creation tool with nothing selected is not live. Without that last term,
		-- clicking the lit card to DESELECT cleared the highlight but left the placer armed
		-- with its old key: the ghost kept riding the cursor and the next click still placed
		-- -- and charged for -- the creation the player had just unticked.
		Creations.setEnabled(natureTabLive and placingCreation and selectedCreation ~= nil)
		for catKey, cbtn in categoryButtons do
			-- A chip belongs to one shelf tab and is only on screen there.
			cbtn.Visible = CATEGORY_TAB[catKey] == _activeTab
			flip(cbtn, cbtn :: any, catKey == _natureCategory)
		end
		if _infoCap then
			-- Free Placement is an independent toggle now, not one of the 4 mode-exclusive
			-- captions below, so it's appended as a suffix on top of whichever gesture's
			-- caption is showing rather than replacing it (mode can never equal "FreePlace"
			-- anymore -- Nature.getMode() only returns one of the 4 gestures).
			local captions: { [string]: string } = {
				Line = "Nature  \u{00B7}  Line \u{2014} click a start, then an end",
				Curve = "Nature  \u{00B7}  Curve \u{2014} click a start, a bend, then an end",
				Single = "Nature  \u{00B7}  Single \u{2014} click to plant one",
				Brush = "Nature  \u{00B7}  Brush \u{2014} hold LMB and sweep to scatter",
			}
			local base = captions[mode] or ""
			if shapeShelf then
				-- Kept short: the info card is one line and the gesture caption is already on it.
				base = "Build  \u{00B7}  click to place  \u{00B7}  right-drag to turn  \u{00B7}  lands on top of what it touches"
			end
			if Nature.isParked() then
				base = "Precise  \u{00B7}  drag the handles to place it exactly  \u{00B7}  click anywhere else to plant another"
			elseif Nature.isPrecise() then
				base = base .. "  \u{00B7}  Precise: the gizmo lands on what you place"
			end
			_infoCap.Text = if FreePlacement.isEnabled()
				then base .. "  \u{00B7}  Free Placement is on"
				else base
			if placingCreation then
				_infoCap.Text = "Creations  \u{00B7}  pick one below, then click to place  \u{00B7}  R rotates"
			end
			-- A cut or copy of SEVERAL props arms a stamp, which is not a catalog asset and so
			-- lights no card. Without this the strip just sits there dark and nothing on screen
			-- says why, or what the cursor is actually carrying.
			local stamp = Nature.stampSize()
			if stamp > 1 then
				_infoCap.Text = ("Holding %d objects  \u{00B7}  click to place them together  \u{00B7}  pick a card to drop them")
					:format(stamp)
			end
		end
	end
	_refreshNature = refresh

	-- The Creations tool can disarm ITSELF (the Back key). Drop the selection and re-derive
	-- when it does, or the chip stays lit over a tool nobody is driving and clicking appears
	-- to do nothing until the player happens to touch another Nature control.
	-- Registered here, not in InitDock: `selectedCreation` and `refresh` are locals of this
	-- function, and assigning them from there would have quietly written a global instead.
	-- Guarded against re-entry because refresh() calls setEnabled, which is what fires this.
	local creationListenerBusy = false
	Creations.setStateListener(function(on: boolean)
		if on or creationListenerBusy then return end
		creationListenerBusy = true
		selectedCreation = nil
		refresh()
		creationListenerBusy = false
	end)

	-- Row 0: Randomize toggle (left) + spacing/brush stepper (right). Free Placement now
	-- lives as its own standalone rail icon (see InitDock, next to NATURE_MODES) --
	-- an independent on/off toggle layered on top of whichever of the 4 gestures is
	-- selected, not a mode of its own and not a row-0 control here.
	-- Row 0 rides in the FLOATING tool strip above the shelf, centred between the
	-- rail on the left and the brush stepper on the right. It used to be the top
	-- 26px of a page that had 320 to spend; the shelf gives its content about 60,
	-- so a fixed row there left the card strip a sliver -- which is what made the
	-- Build shelf read as a pile of rows.
	local controls = Instance.new("Frame")
	controls.Name = "NatureOptions"
	controls.BackgroundTransparency = 1
	controls.AnchorPoint = Vector2.new(0.5, 0.5)
	controls.Position = UDim2.new(0.5, 0, 0.5, 0)
	controls.AutomaticSize = Enum.AutomaticSize.X
	controls.Size = UDim2.fromOffset(0, 28)
	controls.Parent = toolsHost
	-- One row, left to right: Randomize and the spacing stepper (Nature only), then the build
	-- toolbar (BuildRail). A list, not hand-placed offsets -- the offsets are how five chips
	-- ended up overlapping the stepper whenever a label changed width.
	local controlsList = Instance.new("UIListLayout")
	controlsList.FillDirection = Enum.FillDirection.Horizontal
	controlsList.VerticalAlignment = Enum.VerticalAlignment.Center
	controlsList.SortOrder = Enum.SortOrder.LayoutOrder
	controlsList.Padding = UDim.new(0, 10)
	controlsList.Parent = controls

	local rnd = Instance.new("TextButton")
	-- Five chips left of the right-anchored stepper, which starts at content width - 150.
	-- Keep the last one ending before that or they overlap.
	rnd.Size = UDim2.fromOffset(88, 28)
	rnd.LayoutOrder = 1
	rnd.BackgroundColor3 = Theme.Color.BgRaised
	rnd.BackgroundTransparency = 0.2
	rnd.Text = "Randomize"
	rnd.TextColor3 = Theme.Color.TextPrimary
	rnd.TextSize = Theme.TextSize.XS
	rnd.FontFace = Theme.Font.Bold
	rnd.BorderSizePixel = 0
	rnd.AutoButtonColor = true
	rnd.Parent = controls
	corner(rnd, 6)
	randBtn = rnd
	rnd.Activated:Connect(function()
		Nature.setRandomize(not Nature.getRandomize())
		refresh()
	end)

	local stepper = Instance.new("Frame")
	stepper.LayoutOrder = 2
	stepper.Size = UDim2.fromOffset(150, 26)
	stepper.BackgroundTransparency = 1
	stepper.Parent = controls
	stepperFrame = stepper
	local sl = Instance.new("UIListLayout")
	sl.FillDirection = Enum.FillDirection.Horizontal
	sl.HorizontalAlignment = Enum.HorizontalAlignment.Right
	sl.VerticalAlignment = Enum.VerticalAlignment.Center
	sl.SortOrder = Enum.SortOrder.LayoutOrder
	sl.Padding = UDim.new(0, 4)
	sl.Parent = stepper
	local cap = Instance.new("TextLabel")
	cap.BackgroundTransparency = 1
	cap.Size = UDim2.fromOffset(46, 24)
	cap.Text = "spacing"
	cap.TextColor3 = Theme.Color.TextSecondary
	cap.TextSize = Theme.TextSize.XS
	cap.FontFace = Theme.Font.Label
	cap.LayoutOrder = 1
	cap.Parent = stepper
	stepCap = cap
	local function stepBtn(txt: string, order: number, delta: number)
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(24, 24)
		b.BackgroundColor3 = Theme.Color.BgRaised
		b.BackgroundTransparency = 0.2
		b.Text = txt
		b.TextColor3 = Theme.Color.TextPrimary
		b.TextSize = 16
		b.FontFace = Theme.Font.Bold
		b.AutoButtonColor = true
		b.BorderSizePixel = 0
		b.LayoutOrder = order
		b.Parent = stepper
		corner(b, 6)
		b.Activated:Connect(function()
			if usesSpacing(Nature.getMode()) then
				Nature.setSpacing(Nature.getSpacing() + delta)
			else
				Nature.setBrushRadius(Nature.getBrushRadius() + delta)
			end
			refresh()
		end)
	end
	stepBtn("\u{2212}", 2, -4)
	local val = Instance.new("TextLabel")
	val.BackgroundTransparency = 1
	val.Size = UDim2.fromOffset(30, 24)
	val.Text = "16"
	val.TextColor3 = Theme.Color.TextPrimary
	val.TextSize = Theme.TextSize.SM
	val.FontFace = Theme.Font.Bold
	val.LayoutOrder = 3
	val.Parent = stepper
	stepLabel = val
	stepBtn("+", 4, 4)

	BuildRail.Mount(controls, toolsHost:FindFirstAncestorWhichIsA("ScreenGui") :: any)

	-- Category sub-tabs (Trees / Bushes / Rocks), Cities-Skylines style. The strip below is
	-- filtered to the active category; palette selection stays cross-category, so ticking a
	-- tree, switching to Bushes and ticking one keeps both in the brush mix.
	-- ...as is the size stepper. Two controls for one setting is one too many.

	-- Sub-tabs (Shapes / Creations, or the nature categories) ride in the HEADER
	-- beside the page title. Inside the content they were a 20px band at y=32 on
	-- top of a 60px card row -- which is why the nature cards were clipped on
	-- three sides. Style is unchanged; only the address is.
	local catRow = Instance.new("Frame")
	catRow.Name = "Categories"
	catRow.BackgroundTransparency = 1
	catRow.AnchorPoint = Vector2.new(0, 0.5)
	-- Hard left. The 76 was clearing the header title, which is no longer drawn.
	catRow.Position = UDim2.new(0, 0, 0.5, 0)
	catRow.AutomaticSize = Enum.AutomaticSize.X
	catRow.Size = UDim2.fromOffset(0, 22)
	catRow.Parent = page.Header
	local catLayout = Instance.new("UIListLayout")
	catLayout.FillDirection = Enum.FillDirection.Horizontal
	catLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	catLayout.SortOrder = Enum.SortOrder.LayoutOrder
	catLayout.Padding = UDim.new(0, 6)
	catLayout.Parent = catRow

	-- The colour swatches used to sit here. They are in the Precise Build panel now:

	local scroller = hScroller(6)
	scroller.Name = "Cards"
	scroller.Size = UDim2.fromScale(1, 1)
	scroller.Position = UDim2.fromOffset(0, 0)
	scroller.Parent = panel

	-- Stand the real model up inside a card. Done on demand, because a ViewportFrame renders
	-- whether or not it is scrolled into view and a hundred live ones is a frame-rate cliff.
	local function fillPreview(ref: any)
		if ref.filled then return end
		local template = ReplicatedStorage.Nature:FindFirstChild(ref.key)
		if not (template and template:IsA("Model")) then return end
		ref.filled = true
		local model = (template :: Model):Clone()
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				d.Anchored = true; d.CanCollide = false; d.CanQuery = false; d.CanTouch = false
			end
		end
		model.Parent = ref.viewport
		local cf, size = model:GetBoundingBox()
		local cam = Instance.new("Camera")
		cam.FieldOfView = 40
		-- Frame the whole bounding sphere from three-quarters, so a 25-stud oak and a 1-stud
		-- ring both fill the card instead of one overflowing and the other vanishing.
		local dist = size.Magnitude / (2 * math.tan(math.rad(cam.FieldOfView * 0.5))) * 1.15
		cam.CFrame = CFrame.lookAt(cf.Position + Vector3.new(0.8, 0.5, 1).Unit * math.max(dist, 1), cf.Position)
		cam.Parent = ref.viewport
		ref.viewport.CurrentCamera = cam
	end

	local function emptyPreview(ref: any)
		if not ref.filled then return end
		ref.filled = false
		ref.viewport:ClearAllChildren()
	end

	-- Only cards near the visible window keep a live scene. Measured off AbsolutePosition
	-- rather than layout order: the strip is filtered per chip, so a card's index in the
	-- catalog says nothing about where it ended up.
	updatePreviews = function()
		local left = scroller.AbsolutePosition.X - PREVIEW_MARGIN
		local right = scroller.AbsolutePosition.X + scroller.AbsoluteSize.X + PREVIEW_MARGIN
		for _, ref in assetCards do
			if not ref.frame.Visible then
				emptyPreview(ref)
			else
				local x0 = ref.frame.AbsolutePosition.X
				local x1 = x0 + ref.frame.AbsoluteSize.X
				if x1 >= left and x0 <= right then fillPreview(ref) else emptyPreview(ref) end
			end
		end
	end
	scroller:GetPropertyChangedSignal("CanvasPosition"):Connect(updatePreviews)

	for i, key in NatureCatalog.order do
		local e = NatureCatalog.byKey[key]
		local card = Instance.new("Frame")
		card.Name = "Asset_" .. key
		card.Size = UDim2.fromOffset(NATURE_CARD_W, NATURE_CARD_H)
		card.BackgroundColor3 = Theme.Color.BgRaised
		card.BackgroundTransparency = 0.2
		card.BorderSizePixel = 0
		local cat = cardCategory(key, e.kind)
		card.LayoutOrder = if e.kind == "Shape" then ShapeCatalog.rankOf(key) else i
		card.Visible = cat == _natureCategory
		corner(card, Theme.Radius.MD)
		local vp = Instance.new("ViewportFrame")
		vp.Name = "Preview"
		vp.Position = UDim2.fromOffset(4, 4)
		vp.Size = UDim2.new(1, -8, 1, -(NATURE_LABEL_H + 6))
		vp.BackgroundColor3 = Theme.Color.Bg
		vp.BackgroundTransparency = 0.3
		vp.BorderSizePixel = 0
		-- Lit from the front-left so a flat face and a curve read differently; the catalog
		-- tint warms the fill so a card is still colour-coded at a glance.
		vp.Ambient = e.tint:Lerp(Color3.fromRGB(190, 195, 205), 0.7)
		vp.LightColor = Color3.fromRGB(255, 252, 244)
		vp.LightDirection = Vector3.new(-0.5, -1, -0.7)
		corner(vp, 6)
		vp.Parent = card
		local lbl = Instance.new("TextLabel")
		lbl.AnchorPoint = Vector2.new(0, 1)
		lbl.Position = UDim2.new(0, 6, 1, -4)
		lbl.Size = UDim2.new(1, -12, 0, NATURE_LABEL_H)
		lbl.BackgroundTransparency = 1
		lbl.Text = e.name
		lbl.TextColor3 = Theme.Color.TextPrimary
		lbl.TextXAlignment = Enum.TextXAlignment.Center
		lbl.TextSize = Theme.TextSize.XS
		lbl.FontFace = Theme.Font.Label
		lbl.TextTruncate = Enum.TextTruncate.AtEnd
		lbl.Parent = card
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.fromScale(1, 1)
		btn.BackgroundTransparency = 1
		btn.Text = ""
		btn.Parent = card
		btn.Activated:Connect(function()
			Nature.setAssetSelected(key, not Nature.isAssetSelected(key))
			refresh()
		end)
		card.Parent = scroller
		assetCards[key] = { frame = card, label = lbl, kind = cat, key = key, viewport = vp, filled = false }
	end
	-- Deferred: AbsolutePosition is still zero for every card until the layout pass runs, and
	-- a window test against zeroes would light up all hundred at once.
	task.defer(updatePreviews)

	local function clearCreationCards()
		for _, ref in creationCards do ref.frame:Destroy() end
		table.clear(creationCards)
	end

	local function creationCard(entry: any, order: number)
		local id = tostring(entry.id)
		local card = Instance.new("Frame")
		card.Name = "Creation_" .. id
		card.Size = UDim2.fromOffset(NATURE_CARD_W, NATURE_CARD_H)
		card.BackgroundColor3 = Theme.Color.BgRaised
		card.BackgroundTransparency = 0.2
		card.BorderSizePixel = 0
		-- Offset past the nature cards so the two sets can never interleave in the layout.
		card.LayoutOrder = 1000 + order
		card.Visible = _natureCategory == "Creation"
		corner(card, Theme.Radius.MD)

		local lbl = Instance.new("TextLabel")
		lbl.Position = UDim2.fromOffset(8, 6)
		lbl.Size = UDim2.new(1, -12, 0, 16)
		lbl.BackgroundTransparency = 1
		lbl.Text = tostring(entry.name)
		lbl.TextColor3 = Theme.Color.TextPrimary
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.TextSize = Theme.TextSize.XS
		lbl.FontFace = Theme.Font.Bold
		lbl.TextTruncate = Enum.TextTruncate.AtEnd
		lbl.Parent = card

		local price = tonumber(entry.price) or 0
		local sub = Instance.new("TextLabel")
		sub.AnchorPoint = Vector2.new(0, 1)
		sub.Position = UDim2.new(0, 8, 1, -6)
		sub.Size = UDim2.new(1, -12, 0, 14)
		sub.BackgroundTransparency = 1
		-- Whose it is matters more than what it costs once the shelf carries other people's
		-- work, so the author wins the line when there is one.
		sub.Text = if typeof(entry.ownerName) == "string" and entry.ownerName ~= ""
			then "by " .. entry.ownerName
			elseif price > 0 then tostring(price)
			else "free"
		sub.TextColor3 = Theme.Color.TextSecondary
		sub.TextXAlignment = Enum.TextXAlignment.Left
		sub.TextSize = Theme.TextSize.XS
		sub.FontFace = Theme.Font.Label
		sub.TextTruncate = Enum.TextTruncate.AtEnd
		sub.Parent = card

		local btn = Instance.new("TextButton")
		btn.Size = UDim2.fromScale(1, 1)
		btn.BackgroundTransparency = 1
		btn.Text = ""
		btn.Parent = card
		btn.Activated:Connect(function()
			-- Single-select, and clicking the live one clears it: a creation is one model on
			-- the cursor, not a brush mix like the nature palette above.
			selectedCreation = if selectedCreation == id then nil else id
			if selectedCreation then Creations.setCreation(selectedCreation) end
			-- refresh() disarms the placer when selectedCreation is nil; see the note there.
			refresh()
		end)

		card.Parent = scroller
		creationCards[id] = { frame = card, label = lbl }
	end

	local function emptyCreationCard(text: string)
		local card = Instance.new("Frame")
		card.Name = "Creation_Empty"
		card.Size = UDim2.fromOffset(NATURE_CARD_W * 2 + 6, NATURE_CARD_H)
		card.BackgroundTransparency = 1
		card.LayoutOrder = 1000
		card.Visible = _natureCategory == "Creation"
		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.BackgroundTransparency = 1
		lbl.Text = text
		lbl.TextColor3 = Theme.Color.TextSecondary
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.TextSize = Theme.TextSize.XS
		lbl.FontFace = Theme.Font.Label
		lbl.TextWrapped = true
		lbl.Parent = card
		card.Parent = scroller
		-- Registered so refresh() hides it with the rest; the id cannot collide with a
		-- blueprint id, which is always "<userId>_<time>_<rand>".
		creationCards["\0empty"] = { frame = card, label = lbl }
	end

	-- Refetched on every chip click rather than cached: the player may have saved something
	-- since, or a curator may have approved someone else's work into the store.
	local function rebuildCreations()
		if creationsBusy then return end
		creationsBusy = true
		task.spawn(function()
			local ok, list = pcall(Creations.fetchList)
			creationsBusy = false
			if not ok or typeof(list) ~= "table" then list = {} end
			clearCreationCards()
			if #list == 0 then
				emptyCreationCard("Nothing here yet \u{2014} build something in the Creation Editor, or wait for approved designs.")
			else
				for i, entry in list do creationCard(entry, i) end
			end
			-- The selected creation may have just been deleted or taken down.
			if selectedCreation and not creationCards[selectedCreation] then selectedCreation = nil end
			refresh()
		end)
	end

	for i, cat in NATURE_CATEGORIES do
		local b = Instance.new("TextButton")
		b.Name = "Cat_" .. cat.key
		b.Size = UDim2.fromOffset(76, 20)
		b.BackgroundColor3 = Theme.Color.BgRaised
		b.BackgroundTransparency = 0.2
		b.Text = cat.label
		b.TextColor3 = Theme.Color.TextPrimary
		b.TextSize = Theme.TextSize.XS
		b.FontFace = Theme.Font.Bold
		b.BorderSizePixel = 0
		b.AutoButtonColor = true
		b.LayoutOrder = i
		b.Parent = catRow
		corner(b, 6)
		categoryButtons[cat.key] = b
		b.Activated:Connect(function()
			_natureCategory = cat.key
			-- Each shelf keeps its own picks: what was ticked on Trees is not on screen here.
			Nature.clearSelection()
			selectedCreation = nil
			scroller.CanvasPosition = Vector2.zero
			if cat.key == "Creation" then rebuildCreations() end
			refresh()
		end)
	end

end

function TerrainPanelController.InitDock(dock: Dock.Dock)
	_dock = dock
	local page = dock:AddPage({
		key = "Terrain",
		-- Sized for the Nature shelf, the tallest thing this page holds: five chips,
		-- a paint row and a strip of 3D cards. Width is ignored (full-bleed shelf).
		-- 2026-09-18: 320 -> 240. The card strip became ONE sideways-scrolling row,
		-- so the old two-row allowance was left on screen as an empty band under the
		-- cards, running the whole width of a full-bleed shelf.
		height = Dock.SHELF_H,
		tabs = {
			{ key = "Sculpt", label = "Sculpt" },
			{ key = "Nature", label = "Nature" },
			{ key = "Build", label = "Build" },
			{ key = "Trails", label = "Trails" },
		},
		onTab = selectTab,
	})
	_page = page

	-- Info bar: title + tool caption, brush-size stepper on the right.
	-- TEMPLATE: the name sits top-RIGHT in the header, out of the tab row. It used
	-- to be at the info row's left edge, directly on top of SCULPT / NATURE /
	-- TRAILS. Its how-to caption is gone with every other one.
	-- Adopt the shelf's OWN title label (top-left, built by Kit.Dock) instead of
	-- adding a second one to the same row. Every existing `_infoTitle.Text = ...`
	-- writer then drives the shelf title, so the Terrain/Build switch still
	-- renames the header with no call sites changed.
	_infoTitle = page.Header:FindFirstChild("Title") :: TextLabel
	-- Kept as an off-screen sink so the writers that still set it are harmless.
	local cap = Instance.new("TextLabel")
	cap.Name = "UnusedCaption"
	cap.Visible = false
	cap.Parent = page.Header
	_infoCap = cap

	-- Brush size joins the floating tool strip above the shelf, with the tools.
	local brush = Instance.new("Frame")
	brush.AnchorPoint = Vector2.new(1, 0.5)
	brush.Position = UDim2.new(1, 0, 0.5, 0)
	brush.Size = UDim2.fromOffset(150, 26)
	brush.BackgroundTransparency = 1
	brush.Parent = page.RailAux
	local bl = Instance.new("UIListLayout")
	bl.FillDirection = Enum.FillDirection.Horizontal
	bl.HorizontalAlignment = Enum.HorizontalAlignment.Right
	bl.VerticalAlignment = Enum.VerticalAlignment.Center
	bl.SortOrder = Enum.SortOrder.LayoutOrder
	bl.Padding = UDim.new(0, 4)
	bl.Parent = brush
	local bCap = Instance.new("TextLabel")
	bCap.BackgroundTransparency = 1
	bCap.Size = UDim2.fromOffset(38, 24)
	bCap.Text = "brush"
	bCap.TextColor3 = Theme.Color.TextSecondary
	bCap.TextSize = Theme.TextSize.XS
	bCap.FontFace = Theme.Font.Label
	bCap.LayoutOrder = 1
	bCap.Parent = brush
	local function stepBtn(txt: string, o: number, d: number)
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(24, 24)
		b.BackgroundColor3 = Theme.Color.BgRaised
		b.BackgroundTransparency = 0.2
		b.Text = txt
		b.TextColor3 = Theme.Color.TextPrimary
		b.TextSize = 16
		b.FontFace = Theme.Font.Bold
		b.AutoButtonColor = true
		b.BorderSizePixel = 0
		b.LayoutOrder = o
		b.Parent = brush
		corner(b, 6)
		b.Activated:Connect(function()
			Terrain.setRadius(Terrain.getRadius() + d)
			refreshSculpt()
		end)
	end
	stepBtn("\u{2212}", 2, -RADIUS_STEP)
	local val = Instance.new("TextLabel")
	val.BackgroundTransparency = 1
	val.Size = UDim2.fromOffset(36, 24)
	val.Text = "-"
	val.TextColor3 = Theme.Color.TextPrimary
	val.TextSize = Theme.TextSize.SM
	val.FontFace = Theme.Font.Bold
	val.LayoutOrder = 3
	val.Parent = brush
	_radiusLabel = val
	stepBtn("+", 4, RADIUS_STEP)

	-- Rail: sculpt tools (2-wide icon grid, matching the other pages).
	local rail = page.Rail
	local rpad = Instance.new("UIPadding")
	rpad.PaddingTop = UDim.new(0, Theme.Pad.XS)
	rpad.PaddingLeft = UDim.new(0, Theme.Pad.XS)
	rpad.Parent = rail
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(26, 26)
	grid.CellPadding = UDim2.fromOffset(4, 4)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = rail
	for i, def in OP_DEFS do
		local key = def.key
		_opButtons[key] = IconButton.new({
			icon = def.icon, name = def.label, tooltip = def.label, parent = rail, size = 26, layoutOrder = i,
			onClick = function()
				Terrain.setOp(key :: any)
				refreshSculpt()
			end,
		})
	end

	-- Nature's tools share this rail; they show only on the Nature tab (selectTab toggles
	-- which set is visible), so the rail always reflects the active tab -- no stale sculpt
	-- icons hanging around on Nature. Line reuses the road-straight glyph; Curve reuses the
	-- road-curved icon set's arc glyph on purpose -- same gesture, same visual language.
	-- Rail order is Single, Line, Curve, Brush, then Free Placement; layoutOrder below is
	-- derived purely from this array's position (10 + i), so reordering the array is the
	-- only change needed -- nothing else keys off array position.
	--
	-- FOUR entries, not five. Free Placement is NOT a gesture and must not live in here: it
	-- is an independent on/off that layers on top of whichever gesture is active (see
	-- ReplicatedStorage.Shared.FreePlacement). It used to sit in this array, which built its
	-- button in the loop below and wired it to `Nature.setMode("FreePlace")` -- a mode
	-- NaturePlacementController.setMode rejects outright, since it only accepts the four
	-- gestures. The result was a rail icon that did nothing at all: nothing ever called
	-- FreePlacement.setEnabled, so the flag every consumer polls was permanently false.
	local NATURE_MODES = {
		{ key = "Single",    icon = Icons.NatureSingle,    tip = "Single \u{2014} one click, one plant" },
		{ key = "Line",      icon = Icons.RoadStraight,    tip = "Line \u{2014} click start, click end" },
		{ key = "Curve",     icon = Icons.NatureCurve,     tip = "Curve \u{2014} click start, bend, end" },
		{ key = "Brush",     icon = Icons.TerrainPaint,    tip = "Brush \u{2014} hold & scatter" },
	}
	for i, def in NATURE_MODES do
		local key = def.key
		local b = IconButton.new({
			icon = def.icon, name = key, tooltip = def.tip, parent = rail, size = 26, layoutOrder = 10 + i,
			onClick = function()
				Nature.setMode(key :: any)
				if _refreshNature then _refreshNature() end
			end,
		})
		b.Instance.Visible = false
		_natureModeButtons[key] = b
	end

	-- Free Placement: its own toggle, sitting after the gestures on the same rail. Kept out
	-- of _natureModeButtons deliberately -- that table is the mode-exclusive set, and
	-- refresh() lights exactly one of it. This one is lit from FreePlacement.isEnabled()
	-- instead, so it can be on underneath any gesture.
	--
	-- Turning it on tells the ghost to stop refusing ground near roads and buildings
	-- (NaturePlacementController's blocker returns false outright when this is set). The
	-- SERVER still enforces its own exclusion rules regardless -- see NaturePlaceService --
	-- so this widens the preview and what the client bothers sending, never the actual rule.
	_freePlaceButton = IconButton.new({
		icon = Icons.NatureFreePlace, name = "FreePlace", tooltip = "Free Placement",
		parent = rail, size = 26, layoutOrder = 10 + #NATURE_MODES + 1,
		onClick = function()
			FreePlacement.setEnabled(not FreePlacement.isEnabled())
			if _refreshNature then _refreshNature() end
		end,
	})
	;(_freePlaceButton :: IconButton.IconButton).Instance.Visible = false


	-- Center: material cards (click = pick material + switch to Paint).
	local mats = hScroller(CARD_GAP)
	mats.Name = "Materials"
	mats.Size = UDim2.fromScale(1, 1)
	mats.Parent = page.Content
	_matsRow = mats
	for i, name in Terrain.getMaterialNames() do
		local card = Instance.new("CanvasGroup")
		card.Name = "Mat_" .. name
		card.Size = UDim2.fromOffset(CARD_W, CARD_H)
		card.BackgroundColor3 = Theme.Color.BgRaised
		card.BackgroundTransparency = 0.2
		card.LayoutOrder = i
		card.ClipsDescendants = true
		card.BorderSizePixel = 0
		corner(card, Theme.Radius.MD)
		local stroke = Instance.new("UIStroke")
		stroke.Color = Theme.Color.StrokeSoft
		stroke.Thickness = Theme.StrokeWidth.Thin
		stroke.Parent = card
		local scale = Instance.new("UIScale")
		scale.Parent = card
		card.MouseEnter:Connect(function()
			UITween.to(scale, "Hover", { Scale = 1.05 })
		end)
		card.MouseLeave:Connect(function()
			UITween.to(scale, "Hover", { Scale = 1 })
		end)
		local swatch = Instance.new("Frame")
		swatch.Size = UDim2.fromScale(1, 1)
		swatch.BackgroundColor3 = MAT_COLORS[name] or Theme.Color.BgRaised
		swatch.BackgroundTransparency = 0.15
		swatch.BorderSizePixel = 0
		swatch.Parent = card
		local lbl = Instance.new("TextLabel")
		lbl.AnchorPoint = Vector2.new(0, 1)
		lbl.Position = UDim2.fromScale(0, 1)
		lbl.Size = UDim2.new(1, 0, 0, 22)
		lbl.BackgroundColor3 = Theme.Color.Scrim
		lbl.BackgroundTransparency = 0.35
		lbl.BorderSizePixel = 0
		lbl.Text = name
		lbl.TextColor3 = Theme.Color.TextPrimary
		lbl.TextSize = Theme.TextSize.XS
		lbl.FontFace = Theme.Font.Label
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.ZIndex = 6
		lbl.Parent = card
		local lpad = Instance.new("UIPadding")
		lpad.PaddingLeft = UDim.new(0, Theme.Pad.SM)
		lpad.Parent = lbl
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.fromScale(1, 1)
		btn.BackgroundTransparency = 1
		btn.Text = ""
		btn.ZIndex = 10
		btn.Parent = card
		card.Parent = mats
		_matStrokes[i] = stroke
		local idx = i
		btn.Activated:Connect(function()
			Terrain.setMaterialIndex(idx)
			Terrain.setOp("SetMaterial")
			refreshSculpt()
		end)
	end

	local ph = Instance.new("TextLabel")
	ph.Name = "Placeholder"
	ph.BackgroundTransparency = 1
	ph.Size = UDim2.fromScale(1, 1)
	ph.Visible = false
	ph.Text = ""
	ph.TextColor3 = Theme.Color.TextSecondary
	ph.TextSize = Theme.TextSize.SM
	ph.FontFace = Theme.Font.Label
	ph.TextWrapped = true
	ph.Parent = page.Content
	_placeholder = ph

	_brushFrame = brush
	local grid = require(script.Parent:WaitForChild("GridPicker")).new(page.RailAux, UDim2.fromOffset(200, 26))
	grid.AnchorPoint = Vector2.new(1, 0.5)
	grid.Position = UDim2.new(1, 0, 0.5, 0)
	grid.Visible = false
	_gridFrame = grid
	buildNaturePanel(page)
	Nature.Init()
	Nature.Bind()
	-- The Creations shelf shares this tab and is a placement tool in its own right, so it
	-- needs the same lifecycle as Nature. Without Bind() it has no RenderStepped and no
	-- InputBegan: the ghost never follows the cursor and a click never reaches tryPlace,
	-- so picking a creation appears to do nothing at all.
	Creations.Init()
	Creations.Bind()
	Creations.Start()
	-- pickKey()'s auto-select (0 assets ticked -> first catalog asset) mutates Nature's
	-- selection from inside its own RenderStepped/InputBegan handlers, off the UI call
	-- stack entirely, so nothing here would otherwise know to re-run refresh() and light
	-- up the card. This is the only path that needs an actual push notification --
	-- everywhere else (Randomize button, stepper, cards, mode rail) already calls
	-- refresh() itself right after the Nature.set* call that changed state.
	Nature.setStateListener(function()
		if _refreshNature then _refreshNature() end
	end)

	selectTab("Sculpt")
end

function TerrainPanelController.setStateListener(fn: (open: boolean) -> ())
	_listener = fn
end

-- Only the tabs belonging to the entry point that opened the page. A tab strip offering
-- Sculpt next to Build would make Build look like part of the terrain tool again.
local function applyPageMode()
	local page = _page
	if not page or not page.Tabs then return end
	local shown = 0
	local row: GuiObject? = nil
	for key, tab in page.Tabs do
		local on = TAB_MODE[key] == _pageMode
		tab.Instance.Visible = on
		if on then
			shown += 1
		end
		row = row or (tab.Instance.Parent :: GuiObject)
	end
	-- Entering from Build leaves exactly ONE tab on the row, which then just
	-- repeats the header title -- that is the stranded "BUILD" at the bottom-left.
	-- Kit.Dock hides a row that was BUILT with one tab; this page builds four and
	-- filters per mode, so it has to make the same call itself.
	if row then
		row.Visible = shown > 1
	end
end

-- The one open path. `mode` is the entry point; `tab` is where to land, defaulting to
-- whatever that mode was last on.
local function openAs(mode: string, tab: string?)
	local want = tab or (if TAB_MODE[_activeTab] == mode then _activeTab else MODE_HOME[mode])
	_pageMode = mode
	_activeTab = want
	applyPageMode()
	if _open then
		selectTab(want)
		-- Fires even though the dock was already open: switching entry points is what decides
		-- which button on the bar reads as lit, and nothing else tells the bar it changed.
		if _listener then _listener(true) end
		return
	end
	if not _page then return end
	_open = true
	local dock = _dock
	if dock then dock:ShowPage("Terrain") end
	selectTab(want)
	if _listener then _listener(true) end
end

function TerrainPanelController.IsOpen(): boolean
	return _open
end

-- Which button on the bar should read as lit. The two share a page, so "is the dock open"
-- is not enough to answer it.
function TerrainPanelController.IsBuildOpen(): boolean
	return _open and _pageMode == "Build"
end

function TerrainPanelController.OpenBuild()
	openAs("Build")
end

function TerrainPanelController.ToggleBuild()
	if TerrainPanelController.IsBuildOpen() then
		TerrainPanelController.Close()
	else
		TerrainPanelController.OpenBuild()
	end
end

-- "Put this exact asset back on the cursor." CUT and COPY on a placed prop call it: the dock
-- comes up on whichever shelf owns that asset with its chip lit, and NaturePlacementController
-- ticks the card and wears the prop's look. That pair IS "you are back where you placed it
-- from" -- which is the whole of what a cut and a copy are here, and why there is no paste.
function TerrainPanelController.ShowNatureAsset(key: string)
	local entry = NatureCatalog.get(key)
	if not entry then return end
	local cat = cardCategory(key, entry.kind)
	local tab = CATEGORY_TAB[cat]
	if not tab then return end -- a car park: placed from the Roads dock, not from here
	-- BOTH set before anything else runs. selectTab's own guard would otherwise bounce the
	-- category to the tab's first chip; and Open() re-runs selectTab on whatever tab was last
	-- active, so landing on a non-shelf tab would switch the placement tool off -- which
	-- clears the very card the caller is about to tick.
	_natureCategory = cat
	openAs(TAB_MODE[tab] or "Terrain", tab)
end

function TerrainPanelController.Open()
	openAs("Terrain")
end

function TerrainPanelController.Close()
	if not _open then
		return
	end
	_open = false
	Terrain.setEnabled(false)
	-- Same rule as a tab change: the mode goes with the panel that turned it on, or its
	-- settings surface is left floating over a closed dock.
	Nature.setPrecise(false)
	ColorPanel.close()
	Nature.setEnabled(false) -- closing the panel drops the Nature tool + its preview too
	BuildRail.closeFlyouts()
	BuildRail.sync()
	Creations.setEnabled(false)
	local dock = _dock
	if dock then
		dock:Hide("Terrain")
	end
	if _listener then
		_listener(false)
	end
end

function TerrainPanelController.Toggle()
	if _open and _pageMode == "Terrain" then
		TerrainPanelController.Close()
	else
		TerrainPanelController.Open()
	end
end

function TerrainPanelController.Start()
	if _started then
		return
	end
	_started = true
	-- The dock page is the tool's UI now; suppress the legacy on-screen HUD.
	Terrain.setHudEnabled(false)
	require(ReplicatedStorage:WaitForChild("City"):WaitForChild("UIEvents")).SettingsOpened.Event:Connect(function()
		TerrainPanelController.Close()
	end)
end

return TerrainPanelController