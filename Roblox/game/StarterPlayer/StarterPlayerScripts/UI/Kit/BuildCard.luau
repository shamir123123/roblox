--!strict
-- Build cards: the option tiles every build dock shows -- a road type, a zone
-- density, a service building, a transit tool. One grid, one card shell, one
-- footer, one Development-tree lock, shared by every page so the docks stay
-- visually identical and a gating change lands everywhere at once.
--
-- The unlocked-node mirror and the city's milestone tier live here too: whoever owns
-- the SyncProgression feed calls setUnlocked() / setTier(), and every gated card on
-- screen repaints.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent.Parent.Theme)
local Icons = require(script.Parent.Parent.Icons)
local UITween = require(script.Parent.Parent.UITween)
local Tooltip = require(script.Parent.Tooltip)
local SoundFX = require(script.Parent.Parent.Parent.Core.SoundFX)
local DevelopmentTree = require(ReplicatedStorage.City.DevelopmentTree)

local BuildCard = {}

local function corner(parent: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = parent
end

-- Development-tree lock state: the client's unlocked-node mirror plus each
-- gated card's refresh closure.
local _dev = { unlocked = {} :: { [string]: boolean }, tier = 1, refreshers = {} :: { () -> () } }

-- Wider since the shelf went full-bleed: four density cards at 80 left most of
-- a 1900px strip empty. Height is still governed by the 120 shelf budget.
local CARD_W = 116
local CARD_H = 76
local CARD_GAP = 6
local CARD_BLEED = 4 -- room at the canvas edge for the selection stroke + hover pop

-- Every dock page lays its cards out the same way: ONE row that scrolls sideways,
-- whose wheel flips a screenful at a time rather than free-scrolling. It was a
-- TWO-row grid, which was the right shape for a narrow bottom-right box; the
-- shelf is full-bleed above the rail now, so a single row reads straight across
-- and nothing is buried on a second row.

-- The card layout every dock page uses. The current page rides on the frame's "Page"
-- attribute, so a tab filter can flip it back to the top without a callback.
local function buildCardGrid(parent: Instance): ScrollingFrame
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Cards"
	scroll.Size = UDim2.fromScale(1, 1)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	-- A VISIBLE bar, because an invisible one says nothing about there being more
	-- cards below. Roblox hides it by itself while the canvas fits, so it appears
	-- exactly when the grid has overflowed -- which is the cue that was missing
	-- when the dock ran out of room. Thin enough to ride in the CARD_BLEED gutter
	-- rather than stealing a column's width.
	scroll.ScrollBarThickness = 3
	scroll.ScrollBarImageColor3 = Theme.Color.Accent
	scroll.ScrollBarImageTransparency = 0.25
	scroll.ScrollingDirection = Enum.ScrollingDirection.X
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.X
	scroll.ClipsDescendants = true
	scroll.Parent = parent
	-- Cards overflow their cell: a Border stroke draws OUTSIDE the card and hover
	-- pops it to 1.05. Flush against the scroller the clip ate that edge, so the top
	-- row and the first column read as cut off. CARD_BLEED is the gutter, on all four
	-- sides -- dock pages add 2x it to their width and height to keep the same grid.
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, CARD_BLEED)
	pad.PaddingBottom = UDim.new(0, CARD_BLEED)
	pad.PaddingLeft = UDim.new(0, CARD_BLEED)
	pad.PaddingRight = UDim.new(0, CARD_BLEED)
	pad.Parent = scroll
	-- TWO rows, filled LEFT TO RIGHT. A vertical grid capped at 2 cells lays the
	-- first card top-left, the second under it, then steps right -- which is a
	-- 2-row strip that grows sideways, rather than UIGridLayout's usual wrap
	-- (which keys off the frame's width and cannot work against an X-auto canvas).
	-- Reading order stays left-to-right across the pair.
	--
	-- Left-aligned on purpose: centring was tried and reads wrong the moment the
	-- strip is full, which is most of the time.
	local row = Instance.new("UIGridLayout")
	row.FillDirection = Enum.FillDirection.Vertical
	-- ONE row. Two was tried; with three or four cards it reads as a stunted
	-- grid, and the shelf is 60px cheaper this way.
	row.FillDirectionMaxCells = 1
	row.CellSize = UDim2.fromOffset(CARD_W, CARD_H)
	row.CellPadding = UDim2.fromOffset(CARD_GAP, CARD_GAP)
	row.HorizontalAlignment = Enum.HorizontalAlignment.Left
	row.VerticalAlignment = Enum.VerticalAlignment.Top
	row.SortOrder = Enum.SortOrder.LayoutOrder
	row.Parent = scroll

	scroll:SetAttribute("Page", 0)
	scroll.InputChanged:Connect(function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseWheel then return end
		-- Wheel down (Position.Z = -1) is the NEXT page. A page is a SCREENFUL now
		-- rather than a fixed two rows, so a wider shelf steps further per notch.
		local pageW = math.max(scroll.AbsoluteSize.X, CARD_W + CARD_GAP)
		local lastPage = math.max(0, math.ceil(scroll.AbsoluteCanvasSize.X / pageW) - 1)
		local page = math.clamp((scroll:GetAttribute("Page") :: number) - input.Position.Z, 0, lastPage)
		scroll:SetAttribute("Page", page)
		UITween.to(scroll, "Popover", { CanvasPosition = Vector2.new(page * pageW, 0) })
	end)

	return scroll
end

local function buildCardShell(name: string, order: number): (CanvasGroup, Frame, UIStroke)
	local card = Instance.new("CanvasGroup")
	card.Name = name
	card.Size = UDim2.fromOffset(CARD_W, CARD_H)
	card.BackgroundColor3 = Theme.Color.BgRaised
	card.BackgroundTransparency = 0.2
	card.LayoutOrder = order
	card.ClipsDescendants = true
	card.BorderSizePixel = 0
	corner(card, Theme.Radius.MD)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Color.StrokeSoft
	stroke.Thickness = Theme.StrokeWidth.Thin
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = card
	-- Hover / press feedback: a small scale pop so the cards feel alive.
	local scale = Instance.new("UIScale")
	scale.Parent = card
	card.MouseEnter:Connect(function()
		UITween.to(scale, "Hover", { Scale = 1.05 })
	end)
	card.MouseLeave:Connect(function()
		UITween.to(scale, "Hover", { Scale = 1 })
	end)
	card.InputBegan:Connect(function(io)
		if io.UserInputType == Enum.UserInputType.MouseButton1 then
			SoundFX.play("Click")
			UITween.to(scale, "Press", { Scale = 0.96 })
		end
	end)
	card.InputEnded:Connect(function(io)
		if io.UserInputType == Enum.UserInputType.MouseButton1 then
			UITween.to(scale, "Hover", { Scale = 1.05 })
		end
	end)
	local preview = Instance.new("Frame")
	preview.Name = "Preview"
	preview.Size = UDim2.fromScale(1, 1)
	preview.BackgroundTransparency = 1
	preview.BorderSizePixel = 0
	preview.ClipsDescendants = true
	preview.Parent = card
	return card, preview, stroke
end

local LOCK_GRAY = Color3.fromRGB(120, 120, 125)

-- Sandbox cities have the WHOLE tree open (ProgressionService.isRoadAllowed /
-- isPlaceableAllowed short-circuit on the same flag), so nothing is ever gated here.
-- Read straight off the replicated flag rather than trusting a SyncProgression
-- snapshot to land after the city load sets it -- one missed broadcast and every
-- advanced road stays greyed out in a mode that is supposed to have no locks.
local function isSandbox(): boolean
	return workspace:GetAttribute("Sandbox") == true
end

local function refreshAll()
	for _, fn in _dev.refreshers do fn() end
end

-- Connected on the first gated card, not at require time: the flag flips when a city
-- loads, which is long after the docks are built.
local _sandboxWatch: RBXScriptConnection? = nil

-- A locked card greys out, shows a lock badge and swallows clicks so it can't be
-- selected/built. SyncProgression drives refresh() via _dev.refreshers.
local function addLock(card: CanvasGroup, isLocked: () -> boolean, tip: () -> string)
	local badge = Instance.new("ImageLabel")
	badge.AnchorPoint = Vector2.new(1, 0)
	badge.Position = UDim2.new(1, -4, 0, 4)
	badge.Size = UDim2.fromOffset(14, 14)
	badge.BackgroundTransparency = 1
	badge.Image = Icons.Lock.image
	badge.ImageColor3 = Theme.Color.TextPrimary
	badge.ScaleType = Enum.ScaleType.Fit
	badge.ZIndex = 12
	badge.Parent = card
	local block = Instance.new("TextButton")
	block.Name = "LockBlock"
	block.Size = UDim2.fromScale(1, 1)
	block.BackgroundTransparency = 1
	block.AutoButtonColor = false
	block.Text = ""
	block.ZIndex = 11
	block.Parent = card
	Tooltip.attach(block, tip)
	local function refresh()
		local locked = not isSandbox() and isLocked()
		badge.Visible = locked
		block.Visible = locked
		block.Active = locked
		card.GroupColor3 = if locked then LOCK_GRAY else Color3.new(1, 1, 1)
	end
	table.insert(_dev.refreshers, refresh)
	if not _sandboxWatch then
		_sandboxWatch = workspace:GetAttributeChangedSignal("Sandbox"):Connect(refreshAll)
	end
	refresh()
end

-- Gates a build card behind a DevelopmentTree node. No node id (or a cost-0 base
-- node) = never gated.
local function gateCard(card: CanvasGroup, nodeId: string?)
	if not nodeId then return end
	local node = DevelopmentTree.ById[nodeId]
	if node and node.cost == 0 then return end
	addLock(card, function() return not _dev.unlocked[nodeId] end, function()
		return "Locked \u{2014} unlock \"" .. (if node then node.name else "this") .. "\" in City Hall"
	end)
end

-- Gates a build card behind a milestone (MilestoneUnlocks). nil or 1 = never gated.
local function gateMilestone(card: CanvasGroup, milestone: number?, milestoneName: string?)
	if not milestone or milestone <= 1 then return end
	addLock(card, function() return _dev.tier < milestone end, function()
		return ("Locked \u{2014} reach milestone %d%s"):format(milestone, if milestoneName then " (" .. milestoneName .. ")" else "")
	end)
end

local function addCardFooter(card: CanvasGroup, text: string): TextButton
	local nameLbl = Instance.new("TextLabel")
	nameLbl.AnchorPoint = Vector2.new(0, 1)
	nameLbl.Position = UDim2.fromScale(0, 1)
	nameLbl.Size = UDim2.new(1, 0, 0, 22)
	nameLbl.BackgroundColor3 = Theme.Color.Scrim
	nameLbl.BackgroundTransparency = 0.35
	nameLbl.BorderSizePixel = 0
	nameLbl.Text = text
	nameLbl.TextColor3 = Theme.Color.TextPrimary
	nameLbl.TextSize = Theme.TextSize.XS
	nameLbl.FontFace = Theme.Font.Label
	nameLbl.TextXAlignment = Enum.TextXAlignment.Left
	nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
	nameLbl.ZIndex = 6
	nameLbl.Parent = card
	local namePad = Instance.new("UIPadding")
	namePad.PaddingLeft = UDim.new(0, Theme.Pad.SM)
	namePad.PaddingRight = UDim.new(0, Theme.Pad.SM)
	namePad.Parent = nameLbl
	local btn = Instance.new("TextButton")
	btn.Name = "Btn"
	btn.Size = UDim2.fromScale(1, 1)
	btn.BackgroundTransparency = 1
	btn.Text = ""
	btn.TextTransparency = 1
	btn.ZIndex = 10
	btn.Parent = card
	return btn
end

BuildCard.W = CARD_W
BuildCard.H = CARD_H
BuildCard.GAP = CARD_GAP
BuildCard.BLEED = CARD_BLEED -- dock pages add 2x this to width AND height to keep the same grid
BuildCard.grid = buildCardGrid
BuildCard.shell = buildCardShell
BuildCard.footer = addCardFooter
BuildCard.gate = gateCard
BuildCard.gateMilestone = gateMilestone

function BuildCard.setTier(t: number)
	if t == _dev.tier then return end
	_dev.tier = t
	refreshAll()
end

function BuildCard.getTier(): number
	return _dev.tier
end

-- Replace the unlocked-node mirror and repaint every gated card on screen.
function BuildCard.setUnlocked(ids: { string })
	table.clear(_dev.unlocked)
	for _, id in ids do
		if typeof(id) == "string" then _dev.unlocked[id] = true end
	end
	refreshAll()
end

return BuildCard