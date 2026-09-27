--!strict
-- Unified build dock: ONE panel every build tool shares, centred above the tool
-- rail. It used to be pinned to the bottom-right corner, left over from when the
-- rail was a full-width bar and the corner was the only free space; with a
-- centred rail that read as an unrelated slab parked in the corner. Centred, it
-- opens directly above the button that summoned it.
-- Sections register pages; opening a page slides the panel in, switching
-- pages crossfades the content while the panel tweens to the new size, so
-- the whole thing reads as a single surface that morphs per tool.
--
-- Page layout (same bones everywhere):
--   [ Info    -- contextual readout, full width          ]
--   [ Rail | Content -- tools left, option cards center  ]
--   [ Tabs    -- base category tabs, full width          ]
--
-- Rail and Content are bare frames -- the caller adds its own layout
-- (grid of icon buttons, card scroller, ...).
--
-- A page whose info is just a swatch and one line should pass
-- infoHeight = Dock.INFO_SLIM and lay it out horizontally.
--
-- The player sizes the dock by dragging the grip on its top-left corner. That
-- is a SCALE, not a reflow: every page keeps its designed pixel layout and the
-- whole surface grows as one unit. The factor persists as `dockScale`.

local UserInputService = game:GetService("UserInputService")

local Theme = require(script.Parent.Parent.Theme)
local UITween = require(script.Parent.Parent.UITween)
local Glass = require(script.Parent.Glass)
local HudScale = require(script.Parent.Parent.HudScale)
local Tab = require(script.Parent.Tab)
local Icons = require(script.Parent.Parent.Icons)
local Settings = require(script.Parent.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))

-- The DEFAULT info height, for a page whose readout needs two lines and a row of
-- controls (Roads: preview, width, elevation, speed dial, options). Pages with
-- nothing but a swatch and a line of text pass infoHeight = INFO_SLIM instead --
-- on a full-bleed shelf a 54px band of mostly-empty pixels runs the whole width
-- of the screen, which is the most visible waste there is.
-- The shelf's whole vertical budget lives here. HEIGHT = HEADER_H + one card
-- row + INFO_H, and every page is that tall; change these and the shelf
-- changes everywhere rather than in five callers.
local INFO_H = 24
local INFO_SLIM = 24
local RAIL_W = 64 -- now only a has-rail flag: >0 means the page shows one
-- The dark band across the top holds EVERY control of the page in one row:
-- sub-tabs at the left, the page's tools after them, its settings at the right.
-- Cards (the sub-sub choice) sit under it, the readout column to the right.
local HEADER_H = 34
local TAB_H = 24
local SLIDE = 18
local GAP = 10  -- air between the glass islands; the world shows through
local GRIP = 16
local MARGIN = 10 -- clear of the screen edges, matching the rail's own margin

-- The readout owns a COLUMN down the right of the shelf rather than a slice of
-- the tab line. Reserved out of the content width, so cards can never reach it.
local READOUT_W = 210
local MIN_SCALE = 0.6
local MAX_SCALE = 1.6
-- Responsive shrink FLOOR. The auto-fit below used to have no lower bound, so a
-- small viewport shrank the dock until the cards were too small to hit. Past
-- this the dock stops shrinking and the card grid scrolls instead.
-- Separate from MIN_SCALE, which is the floor on the size the PLAYER chose --
-- their own drag is still allowed below this, because they asked for it.
local MIN_FIT = 0.82
-- With the floor holding the scale up the panel can exceed the old 35% slot;
-- this is the hard share of the viewport it may occupy before the clamp cuts in.
local MAX_H_FRAC = 0.46

export type TabDef = { key: string, label: string }

export type PageProps = {
	key: string,
	-- Kept for source compatibility and IGNORED: the shelf is full-bleed, so its
	-- width is the viewport's, not the page's.
	width: number?,
	height: number,
	railWidth: number?,
	infoHeight: number?,
	tabs: { TabDef },
	-- Shown top-left on the shelf. Defaults to the page key.
	title: string?,
	-- Reserve the right-hand readout column. OFF by default: only Roads has a
	-- readout worth a column, and on every other page it was 210px of empty
	-- shelf the cards could have used.
	readout: boolean?,
	-- Build the shared swatch + title + caption line into Info and hand back
	-- SetInfo. A page with a bespoke readout (Roads) leaves this off.
	standardInfo: boolean?,
	onTab: (key: string) -> (),
}

export type Page = {
	Key: string,
	Root: CanvasGroup,
	Info: Frame,
	Rail: Frame,
	-- Top-right cluster: secondary tools, options, the gear.
	RailAux: Frame,
	-- The page's slice of the floating tool strip above the shelf.
	Tools: Frame,
	-- The shelf's top-left row, for a page title. The READOUT lives in Info,
	-- which is a full-height column down the right edge.
	Header: Frame,
	Content: Frame,
	Tabs: { [string]: Tab.Tab },
	SetTab: (self: Page, key: string) -> (),
	SetTitle: (self: Page, name: string) -> (),
	-- Only does anything when the page asked for standardInfo.
	SetInfo: (self: Page, name: string, caption: string, colour: Color3?) -> (),
}

export type DockProps = {
	parent: Instance,
	position: UDim2,
	-- Fired by a page's close button with that page's key. The dock only knows how
	-- to hide itself; whoever owns the tools has to un-light the rail too.
	onClose: ((key: string) -> ())?,
}

export type Dock = {
	Panel: CanvasGroup,
	AddPage: (self: Dock, props: PageProps) -> Page,
	ShowPage: (self: Dock, key: string) -> (),
	Hide: (self: Dock, key: string?) -> (),
	Current: (self: Dock) -> string?,
	Scale: (self: Dock) -> number, -- current responsive scale (satellite popovers sync to it)
	-- Rendered height in the PARENT's design px (0 when hidden), so whatever
	-- stacks above the dock can measure it instead of guessing.
	Height: (self: Dock) -> number,
	-- Current panel width in the DOCK's own design px, for pages that lay out
	-- against it (the shelf is full-bleed, so this is viewport-derived).
	Width: (self: Dock) -> number,
}

local Dock = {}

-- Exposed so a page can ask for the slim header without copying the number.
Dock.INFO_SLIM = INFO_SLIM

-- THE shelf height, and the only place it is decided:
--   4 (pad) + HEADER_H 34 + 4 (gap) + ONE card row 84 (BuildCard 76 + 2x
--   BLEED 4) + 4 (pad) = 130. The tab row that used to sit under the cards
--   lives in the header now.
-- Every page passes this, so the shelf is one silhouette and a change here
-- moves all of them at once instead of five callers drifting apart.
Dock.SHELF_H = 130


function Dock.new(props: DockProps): Dock
	local position = props.position

	local panel = Instance.new("CanvasGroup")
	panel.Name = "BuildDock"
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.Position = position
	panel.Size = UDim2.fromOffset(400, 200)
	panel.Visible = false
	panel.ZIndex = Theme.Z.Flyout
	panel.BackgroundTransparency = 1
	panel.Parent = props.parent

	local pages: { [string]: Page } = {}
	local dims: { [string]: Vector2 } = {}
	local current: string? = nil
	-- The height the panel is heading for, not the one it is mid-tween at: a
	-- caller stacking above us needs the final number immediately.
	local targetH = 0

	-- Responsive cap: at the default size the dock takes at most 35% of the
	-- screen's height (or half its width). One UIScale, no reflow -- pages keep
	-- their designed pixel layouts and shrink as one unit on small screens.
	-- The player's own size multiplies that cap, and may exceed it: they asked.
	local userScale = math.clamp(tonumber(Settings.get("dockScale")) or 1, MIN_SCALE, MAX_SCALE)
	local scale = Instance.new("UIScale")
	scale.Parent = panel
	-- The panel's rendered size (design px) for a page, after the responsive scale
	-- and the height clamp. Shared by fit() and showPage() so a page can never be
	-- tweened to a size the clamp would have rejected.
	local function fitted(key: string?): (number, number)
		local vp = (props.parent :: GuiBase2d).AbsoluteSize
		local d = if key then dims[key] else nil
		local h = if d then d.Y else panel.Size.Y.Offset
		-- Account for a global HudScale on the parent: caps apply to REAL size.
		local gs = HudScale.get(props.parent :: GuiBase2d)
		-- Height only. The width term is gone with full-bleed: the shelf always
		-- spans the viewport, so width can never be what forces a shrink.
		local cap = math.min(1, vp.Y * 0.35 / math.max(1, h * gs))
		local s = userScale * math.max(cap, MIN_FIT)
		scale.Scale = s
		-- Whatever the floor could not shrink away comes off the HEIGHT instead: the
		-- page's card strip is a ScrollingFrame, so the cards that no longer fit
		-- scroll rather than being squeezed.
		local maxH = (vp.Y * MAX_H_FRAC) / math.max(s * gs, 0.01)
		-- Full-bleed width, expressed in the dock's OWN design px: the panel carries
		-- a UIScale, so divide the target span back out through it.
		local w = ((vp.X / math.max(gs, 0.01)) - MARGIN * 2) / math.max(s, 0.01)
		return math.floor(w), math.min(h, math.floor(maxH))
	end

	local function fit()
		local w, h = fitted(current)
		targetH = h
		if panel.Visible then
			panel.Size = UDim2.fromOffset(w, h)
		end
	end
	;(props.parent :: GuiBase2d):GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)

	-- Resize grip. The dock is anchored bottom-right, so the top-left corner is
	-- the one that moves: drag it out and the panel grows. Whichever axis the
	-- cursor pulls furthest sets the factor -- the aspect is fixed either way.
	-- SIBLING of the panel, not a child: the panel is a CanvasGroup and clips to
	-- its own bounds, so a grip parked outside the corner renders to nothing.
	-- It tracks the panel's top-left corner instead -- clear of the rail's first
	-- button, which used to swallow the clicks. Derived from AbsolutePosition,
	-- so it follows the panel at any viewport size or dock scale.
	local grip = Instance.new("TextButton")
	grip.Name = "ResizeGrip"
	grip.Text = ""
	grip.AutoButtonColor = false
	grip.BackgroundTransparency = 1
	grip.Size = UDim2.fromOffset(GRIP, GRIP)
	grip.ZIndex = Theme.Z.Flyout + 1
	grip.Visible = false
	grip.Parent = props.parent

	local function placeGrip()
		-- AbsolutePosition is REAL px; grip offsets are DESIGN px (see HudScale).
		local gs = math.max(HudScale.get(props.parent :: GuiBase2d), 0.01)
		local p = panel.AbsolutePosition - (props.parent :: GuiBase2d).AbsolutePosition
		grip.Position = UDim2.fromOffset(p.X / gs - GRIP - 4, p.Y / gs - GRIP - 4)
	end
	panel:GetPropertyChangedSignal("AbsolutePosition"):Connect(placeGrip)
	panel:GetPropertyChangedSignal("AbsoluteSize"):Connect(placeGrip)
	panel:GetPropertyChangedSignal("Visible"):Connect(function()
		grip.Visible = panel.Visible
		placeGrip()
	end)

	local function gripBar(w: number, h: number): Frame
		local bar = Instance.new("Frame")
		bar.BackgroundColor3 = Theme.Color.Stroke
		bar.BackgroundTransparency = 0.5
		bar.BorderSizePixel = 0
		bar.Size = UDim2.fromOffset(w, h)
		bar.ZIndex = 50
		bar.Parent = grip
		return bar
	end
	local gripTop = gripBar(GRIP, 2)
	local gripSide = gripBar(2, GRIP)

	local dragging = false
	local originScale = userScale
	local originPos = Vector2.zero
	local originW, originH = 1, 1

	local function gripFade(t: number)
		UITween.to(gripTop, "Hover", { BackgroundTransparency = t })
		UITween.to(gripSide, "Hover", { BackgroundTransparency = t })
	end
	grip.MouseEnter:Connect(function()
		gripFade(0.1)
	end)
	grip.MouseLeave:Connect(function()
		if not dragging then
			gripFade(0.5)
		end
	end)

	grip.InputBegan:Connect(function(input: InputObject)
		local t = input.UserInputType
		if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then
			return
		end
		dragging = true
		originScale = userScale
		originPos = Vector2.new(input.Position.X, input.Position.Y)
		-- Real px, so the ratio below is independent of HudScale and the cap.
		originW = math.max(panel.AbsoluteSize.X, 1)
		originH = math.max(panel.AbsoluteSize.Y, 1)
	end)

	UserInputService.InputChanged:Connect(function(input: InputObject)
		if not dragging then
			return
		end
		local t = input.UserInputType
		if t ~= Enum.UserInputType.MouseMovement and t ~= Enum.UserInputType.Touch then
			return
		end
		-- Left/up grow it, right/down shrink it. The axis the cursor moved FURTHEST
		-- on wins: taking max() of both would only ever grow, since the idle axis
		-- always reports a ratio of exactly 1.
		local dx = originPos.X - input.Position.X
		local dy = originPos.Y - input.Position.Y
		local ratio = if math.abs(dx) >= math.abs(dy) then (originW + dx) / originW else (originH + dy) / originH
		userScale = math.clamp(originScale * ratio, MIN_SCALE, MAX_SCALE)
		fit()
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		if not dragging then
			return
		end
		local t = input.UserInputType
		if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then
			return
		end
		dragging = false
		gripFade(0.5)
		-- Core.Settings persists per player; SettingsClient debounces the push.
		Settings.set("dockScale", userScale)
	end)

	local function showPage(key: string)
		local page = pages[key]
		local size = dims[key]
		if not page or not size then
			return
		end
		local prev = current
		if prev == key and panel.Visible then
			return
		end
		current = key
		local fw, fh = fitted(key)
		targetH = fh
		local target = UDim2.fromOffset(fw, fh)
		if not panel.Visible then
			for k, p in pages do
				p.Root.Visible = k == key
				p.Root.GroupTransparency = if k == key then 0 else 1
			end
			panel.Size = target
			panel.Visible = true
			panel.GroupTransparency = 1
			panel.Position = position + UDim2.fromOffset(0, SLIDE)
			UITween.to(panel, "Flyout", { GroupTransparency = 0, Position = position })
		else
			-- Morph the surface and crossfade the pages. Fade out every OTHER
			-- visible page, not just the last-known one: a Hide immediately
			-- followed by ShowPage (section switch) clears `current`, so the
			-- outgoing page would otherwise be left showing underneath.
			UITween.to(panel, "Flyout", { Size = target, GroupTransparency = 0, Position = position })
			for k, p in pages do
				if k ~= key and p.Root.Visible then
					local r = p.Root
					local pk = k
					UITween.to(r, "Popover", { GroupTransparency = 1 }).Completed:Once(function()
						if current ~= pk then
							r.Visible = false
						end
					end)
				end
			end
			page.Root.Visible = true
			page.Root.GroupTransparency = 1
			UITween.to(page.Root, "Popover", { GroupTransparency = 0 })
		end
	end

	local dock: Dock = {
		Panel = panel,
		AddPage = function(_, pageProps: PageProps): Page
			local hasRail = (pageProps.railWidth or RAIL_W) > 0
			local colW = if pageProps.readout then READOUT_W else 0
			local infoH = pageProps.infoHeight or INFO_H

			local root = Instance.new("CanvasGroup")
			root.Name = pageProps.key
			root.BackgroundTransparency = 1
			root.Size = UDim2.fromScale(1, 1)
			root.Visible = false
			root.Parent = panel

			-- ONE glass surface. It used to be three islands -- a tall rail column
			-- down the left, an info card, and the body under it -- separated by a
			-- GAP so the world showed through. That reads as a sculpted composition
			-- in a small corner box; across a full-bleed shelf the same gaps are
			-- empty bands cut through the entire width of the screen.
			local surface = Instance.new("Frame")
			surface.Name = "Surface"
			surface.Size = UDim2.fromScale(1, 1)
			surface.Parent = root
			Glass.apply(surface, 16)

			local spad = Instance.new("UIPadding")
			-- 4, not Pad.SM: the shelf's budget is 120 and every pixel of chrome is
			-- one the cards do not get.
			spad.PaddingTop = UDim.new(0, 4)
			spad.PaddingBottom = UDim.new(0, 4)
			spad.PaddingLeft = UDim.new(0, Theme.Pad.MD)
			spad.PaddingRight = UDim.new(0, Theme.Pad.MD)
			spad.Parent = surface

			-- HEADER: the tool rail laid out HORIZONTALLY, with the category tabs at
			-- the right end. The rail was a vertical column beside the cards, which
			-- forced the shelf to stand as tall as the column and left the tools
			-- stranded next to the content instead of sitting over it.
			local header = Instance.new("Frame")
			header.Name = "Header"
			header.BackgroundTransparency = 1
			-- Clear of the close button; the settings cluster (RailAux) overlays the
			-- right end and grows leftward from it.
			header.Size = UDim2.new(1, -32, 0, HEADER_H)
			header.Parent = surface
			-- Left to right: sub-tabs (-10), whatever the page parents here itself
			-- (Terrain's category chips, order 0), tools (10), tool options (20).
			local headerList = Instance.new("UIListLayout")
			headerList.FillDirection = Enum.FillDirection.Horizontal
			headerList.VerticalAlignment = Enum.VerticalAlignment.Center
			headerList.SortOrder = Enum.SortOrder.LayoutOrder
			headerList.Padding = UDim.new(0, 16)
			headerList.Parent = header

			-- No visible title: the rail already shows which tool is lit, so the name
			-- on the shelf only repeated it -- and that row is worth more as card
			-- height. Kept as a hidden label so SetTitle callers stay harmless.
			local titleLabel = Instance.new("TextLabel")
			titleLabel.Name = "Title"
			titleLabel.Visible = false
			titleLabel.Text = pageProps.title or pageProps.key
			titleLabel.Parent = header

			-- Close, top-right of the shelf.
			-- A darker band across the whole top of the shelf, edge to edge. Negative
			-- offsets cancel the surface's own padding so it reaches the rounded
			-- corners rather than floating inside a 12px margin.
			-- A darker band across the whole top of the shelf, edge to edge, still
			-- GLASSY -- you can see the world through it, just less.
			--
			-- Rounded on top, flat on the bottom, in ONE semi-transparent frame. The
			-- obvious trick -- a rounded frame plus a square-cornered patch over its
			-- lower half -- only works opaque: the two overlap, so any transparency
			-- compounds there and the strip reads as two stacked bands with a seam.
			-- Instead the band is drawn TALLER than its slot inside a clipping
			-- container, so its bottom rounded corners fall outside and are cut off.
			local bandClip = Instance.new("Frame")
			bandClip.Name = "HeaderBand"
			bandClip.BackgroundTransparency = 1
			bandClip.ClipsDescendants = true
			bandClip.Position = UDim2.fromOffset(-Theme.Pad.MD, -4)
			bandClip.Size = UDim2.new(1, Theme.Pad.MD * 2, 0, HEADER_H + 4)
			bandClip.ZIndex = 0
			bandClip.Parent = surface

			local band = Instance.new("Frame")
			band.Name = "Fill"
			band.BackgroundColor3 = Theme.Color.BgPress
			band.BackgroundTransparency = 0.25
			band.BorderSizePixel = 0
			band.Size = UDim2.new(1, 0, 1, 16) -- overshoot by the radius; the clip cuts it
			band.ZIndex = 0
			band.Parent = bandClip
			local bandCorner = Instance.new("UICorner")
			bandCorner.CornerRadius = UDim.new(0, 16)
			bandCorner.Parent = band

			-- Close sits on the SURFACE, not the header: on Roads the header stops
			-- where the readout column starts, so a button anchored to it landed in
			-- the middle of the shelf instead of its top-right corner.
			--
			-- An ICON, not a glyph: Montserrat has no U+2715, so the text button
			-- rendered as an empty box.
			local closeBtn = Instance.new("TextButton")
			closeBtn.Name = "Close"
			closeBtn.AutoButtonColor = false
			closeBtn.Text = ""
			closeBtn.AnchorPoint = Vector2.new(1, 0.5)
			closeBtn.Position = UDim2.new(1, -Theme.Pad.XS, 0, HEADER_H // 2)
			closeBtn.Size = UDim2.fromOffset(22, 22)
			closeBtn.BackgroundColor3 = Theme.Color.Danger
			closeBtn.BackgroundTransparency = 0.15
			closeBtn.BorderSizePixel = 0
			closeBtn.ZIndex = 20
			closeBtn.Parent = surface
			local cc = Instance.new("UICorner")
			cc.CornerRadius = UDim.new(0, Theme.Radius.SM)
			cc.Parent = closeBtn
			local cx = Instance.new("ImageLabel")
			cx.Name = "Icon"
			cx.BackgroundTransparency = 1
			cx.AnchorPoint = Vector2.new(0.5, 0.5)
			cx.Position = UDim2.fromScale(0.5, 0.5)
			cx.Size = UDim2.fromScale(0.55, 0.55)
			cx.ScaleType = Enum.ScaleType.Fit
			cx.Image = Icons.Close.image
			cx.ImageColor3 = Theme.Color.OnAccent
			cx.ZIndex = 21
			cx.Parent = closeBtn
			closeBtn.MouseEnter:Connect(function()
				closeBtn.BackgroundTransparency = 0
			end)
			closeBtn.MouseLeave:Connect(function()
				closeBtn.BackgroundTransparency = 0.15
			end)
			local pageKey = pageProps.key
			closeBtn.Activated:Connect(function()
				local onClose = props.onClose
				if onClose then
					onClose(pageKey)
				end
			end)

			local rail = Instance.new("Frame")
			rail.Name = "Rail"
			rail.BackgroundTransparency = 1
			rail.AutomaticSize = Enum.AutomaticSize.X
			rail.Size = UDim2.fromOffset(0, HEADER_H)
			rail.LayoutOrder = 10
			rail.Visible = hasRail
			rail.Parent = header

			-- Extra per-page tool options (Nature's randomize/spacing/build rail).
			local tools = Instance.new("Frame")
			tools.Name = pageProps.key .. "Tools"
			tools.BackgroundTransparency = 1
			tools.AutomaticSize = Enum.AutomaticSize.X
			tools.Size = UDim2.fromOffset(0, HEADER_H)
			tools.LayoutOrder = 20
			tools.Parent = header

			-- Top-right cluster: secondary tools, options, the gear. Auto-sizes from
			-- its own edge, so it cannot collide with the primary rail however many
			-- buttons either side holds.
			local railAux = Instance.new("Frame")
			railAux.Name = "RailAux"
			railAux.BackgroundTransparency = 1
			railAux.AnchorPoint = Vector2.new(1, 0.5)
			railAux.Position = UDim2.new(1, -36, 0, HEADER_H // 2)
			railAux.AutomaticSize = Enum.AutomaticSize.X
			railAux.Size = UDim2.fromOffset(0, HEADER_H)
			railAux.ZIndex = 5
			railAux.Parent = surface

			-- INFO sits at the BOTTOM, under the cards: it describes what is
			-- currently picked, which belongs next to the tool rail at the foot of
			-- the screen rather than heading the shelf.
			-- The readout's own COLUMN, full height down the right edge. It used to be
			-- a strip along the bottom that the tabs also lived on, so a long road
			-- name and the tab row fought over the same line -- and the cards above
			-- ran the full width straight into it.
			local info = Instance.new("Frame")
			info.Name = "Info"
			info.BackgroundTransparency = 1
			-- Starts BELOW the header band. Run full height and its centred contents
			-- reach up into the band, where the close button already sits -- measured
			-- live: close occupied y 615-637 while this column began at 612.
			info.AnchorPoint = Vector2.new(1, 0)
			info.Position = UDim2.new(1, 0, 0, HEADER_H)
			info.Size = UDim2.new(0, colW, 1, -HEADER_H)
			info.Parent = surface
			local _ = infoH

			-- STANDARD INFO LINE. Zoning, Civic, Utilities and Transit each used to
			-- hand-build the identical swatch + title + caption trio at their own
			-- coordinates; a page now asks for it and calls SetInfo with its data.
			local setInfo: ((string, string, Color3?) -> ())? = nil
			if pageProps.standardInfo then
				-- Right-hand readout: swatch, name, and a DETAIL slot for data (a
				-- cost, a size). It used to carry a how-to caption -- "drag a road
				-- to zone plots" -- a tutorial line the player reads once and then
				-- scans past forever, on every page, every session.
				local holder = Instance.new("Frame")
				holder.Name = "Readout"
				holder.BackgroundTransparency = 1
				-- Centred in the readout column, like every page's readout.
				holder.AnchorPoint = Vector2.new(0.5, 0.5)
				holder.Position = UDim2.fromScale(0.5, 0.5)
				holder.AutomaticSize = Enum.AutomaticSize.X
				holder.Size = UDim2.fromOffset(0, INFO_H)
				holder.Parent = info
				local row = Instance.new("UIListLayout")
				row.FillDirection = Enum.FillDirection.Horizontal
				row.VerticalAlignment = Enum.VerticalAlignment.Center
				row.SortOrder = Enum.SortOrder.LayoutOrder
				row.Padding = UDim.new(0, 8)
				row.Parent = holder
				local sw = Instance.new("Frame")
				sw.Name = "Swatch"
				sw.Size = UDim2.fromOffset(12, 12)
				sw.BackgroundColor3 = Theme.Color.Accent
				sw.BorderSizePixel = 0
				sw.LayoutOrder = 1
				sw.Parent = holder
				local swc = Instance.new("UICorner")
				swc.CornerRadius = UDim.new(0, 3)
				swc.Parent = sw
				local title = Instance.new("TextLabel")
				title.Name = "Title"
				title.BackgroundTransparency = 1
				title.AutomaticSize = Enum.AutomaticSize.X
				title.Size = UDim2.fromOffset(0, INFO_H)
				title.Text = ""
				title.TextColor3 = Theme.Color.TextPrimary
				title.TextSize = Theme.TextSize.SM
				title.FontFace = Theme.Font.Bold
				title.LayoutOrder = 2
				title.Parent = holder
				local detail = Instance.new("TextLabel")
				detail.Name = "Detail"
				detail.BackgroundTransparency = 1
				detail.AutomaticSize = Enum.AutomaticSize.X
				detail.Size = UDim2.fromOffset(0, INFO_H)
				detail.Text = ""
				detail.TextColor3 = Theme.Color.TextSecondary
				detail.TextSize = Theme.TextSize.XS
				detail.FontFace = Theme.Font.Label
				detail.LayoutOrder = 3
				detail.Parent = holder
				setInfo = function(name: string, det: string, colour: Color3?)
					title.Text = name
					detail.Text = det
					detail.Visible = det ~= ""
					sw.BackgroundColor3 = colour or Theme.Color.Accent
				end
			end

			-- A lone tab says nothing the header title does not already say, so the
			-- row only appears when there is a choice to make.
			local hasTabs = #pageProps.tabs > 1

			local content = Instance.new("Frame")
			content.Name = "Content"
			content.BackgroundTransparency = 1
			content.Position = UDim2.fromOffset(0, HEADER_H + 4)
			-- EXACTLY the card row (84) at SHELF_H; less and every card's bottom
			-- edge clips on every page.
			content.Size = UDim2.new(1, -colW, 1, -(HEADER_H + 4))
			content.ClipsDescendants = true
			content.Parent = surface

			local tabsRow = Instance.new("Frame")
			tabsRow.Name = "Tabs"
			tabsRow.AutomaticSize = Enum.AutomaticSize.X
			tabsRow.Size = UDim2.fromOffset(0, TAB_H)
			tabsRow.Visible = hasTabs
			tabsRow.BackgroundTransparency = 1
			tabsRow.LayoutOrder = -10
			tabsRow.Parent = header

			-- Hairline between "what kind" (tabs) and "how to draw" (tools).
			local split = Instance.new("Frame")
			split.Name = "Split"
			split.BackgroundColor3 = Theme.Color.StrokeSoft
			split.BorderSizePixel = 0
			split.Size = UDim2.fromOffset(1, 18)
			split.LayoutOrder = 5
			split.Visible = hasTabs and hasRail
			split.Parent = header
			local tabList = Instance.new("UIListLayout")
			tabList.FillDirection = Enum.FillDirection.Horizontal
			tabList.VerticalAlignment = Enum.VerticalAlignment.Center
			tabList.SortOrder = Enum.SortOrder.LayoutOrder
			tabList.Padding = UDim.new(0, Theme.Pad.XS)
			tabList.Parent = tabsRow

			local tabs: { [string]: Tab.Tab } = {}
			local function select(key: string)
				for k, tab in tabs do
					tab:SetSelected(k == key)
				end
			end
			for i, def in pageProps.tabs do
				local key = def.key
				tabs[key] = Tab.new({
					text = def.label,
					parent = tabsRow,
					layoutOrder = i,
					onClick = function()
						select(key)
						pageProps.onTab(key)
					end,
				})
			end

			local page: Page = {
				Key = pageProps.key,
				Root = root,
				Info = info,
				Rail = rail,
				RailAux = railAux,
				Content = content,
				Tabs = tabs,
				Tools = tools,
				Header = header,
				SetTab = function(_, key: string)
					select(key)
				end,
				SetTitle = function(_, name: string)
					titleLabel.Text = name
				end,
				SetInfo = function(_, name: string, caption: string, colour: Color3?)
					if setInfo then
						setInfo(name, caption, colour)
					end
				end,
			}
			pages[pageProps.key] = page
			-- X is a placeholder; fitted() overrides it with the viewport span.
			dims[pageProps.key] = Vector2.new(0, pageProps.height)
			return page
		end,
		ShowPage = function(_, key: string)
			showPage(key)
		end,
		Hide = function(_, key: string?)
			if key ~= nil and current ~= key then
				return
			end
			current = nil
			if not panel.Visible then
				return
			end
			UITween.to(panel, "Flyout", { GroupTransparency = 1, Position = position + UDim2.fromOffset(0, SLIDE) }).Completed:Once(function()
				if current == nil then
					panel.Visible = false
				end
			end)
		end,
		Current = function(_): string?
			return current
		end,
		Scale = function(_): number
			return scale.Scale
		end,
		Width = function(_): number
			return panel.Size.X.Offset
		end,
		Height = function(_): number
			if not panel.Visible then
				return 0
			end
			-- targetH is in the dock's OWN design px; the dock carries an extra
			-- UIScale on top of the parent's, so multiply it back out for a number
			-- a sibling can position against.
			return targetH * scale.Scale
		end,
	}
	return dock
end

return Dock
