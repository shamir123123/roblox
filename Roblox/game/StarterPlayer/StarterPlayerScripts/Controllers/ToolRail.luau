--!strict
-- TOOL RAIL: the bottom-centre capsule of build tools.
--
-- Every tool is an icon BESIDE its name. The rail used to be 38px icon-only
-- buttons at the right-hand end of a full-width bar, where the only way to learn
-- what one did was to hover it and wait for a tooltip; the label went in, and
-- then went beside the icon rather than under it, because the rail is bottom
-- chrome and horizontal pixels are the ones this game has spare. Stacked, each
-- button was a 54px-tall cube; side by side it is 38 and merely wider.
--
-- PRESENTATION ONLY. It knows nothing about roads, terrain or bulldozing: the
-- caller hands it entries with an onClick each, and drives the lit state through
-- setSelected. That is what keeps the tool logic in the controllers that own it
-- rather than accumulating here, which is how the old bottom bar reached 2,500
-- lines.

local uiFolder = script.Parent.Parent:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local Icons = require(uiFolder:WaitForChild("Icons"))
local UITween = require(uiFolder:WaitForChild("UITween"))
local HudScale = require(uiFolder:WaitForChild("HudScale"))
local kit = uiFolder:WaitForChild("Kit")
local Glass = require(kit:WaitForChild("Glass"))
local Tooltip = require(kit:WaitForChild("Tooltip"))
local SoundFX = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("SoundFX"))
local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))

local ToolRail = {}

export type Entry = {
	key: string,
	icon: Icons.Icon,
	label: string,
	tooltip: string?,
	danger: boolean?, -- destructive: red at rest, red fill when lit
	-- Entries whose group differs from the previous one get a divider before them.
	group: number?,
	-- The resting tool. It lights itself whenever NOTHING else is lit, so the rail
	-- always shows a current state instead of going blank between tools. At most
	-- one entry may set this; its lit state is derived and setSelected ignores it.
	isDefault: boolean?,
	onClick: () -> (),
}

local BUTTON_H = 38
local ICON = 20
local MIN_W = 0 -- AutomaticSize.X does the sizing; the label sets the width
local RAIL_PAD = 6
local BOTTOM = 10
local CLEARANCE = 8 -- air between the rail and whatever parks above it

local _root: Frame? = nil
local _buttons: { [string]: (boolean) -> () } = {}
local _selected: { [string]: boolean } = {}
local _defaultKey: string? = nil
-- Re-style hooks, one per button: the rail's ink flips with the glass.
local _restyle: { () -> () } = {}
local _darkInk = false
-- Past this much extra see-through the panel stops being a dark backing and the
-- world reads through it -- white-on-grass is unreadable, so the ink inverts.
local DARK_INK_AT = 0.2
local INK_DARK = Color3.fromRGB(18, 20, 16)
local INK_DARK_DIM = Color3.fromRGB(64, 68, 58)
local _conns: { RBXScriptConnection } = {}

-- The default entry is lit exactly when no other entry is. Derived here, in one
-- place, because the alternative is every caller remembering to re-light it on
-- each of the half-dozen paths a tool can exit by.
local function syncDefault()
	local key = _defaultKey
	if not key then
		return
	end
	local apply = _buttons[key]
	if not apply then
		return
	end
	for other, on in _selected do
		if on and other ~= key then
			apply(false)
			return
		end
	end
	apply(true)
end

local function track(conn: RBXScriptConnection)
	table.insert(_conns, conn)
end

local function buildButton(parent: Instance, order: number, entry: Entry)
	-- Recomputed on every restyle rather than captured once: the player can move
	-- the UI-transparency slider at any time.
	local function palette(): (Color3, Color3)
		if entry.danger then
			return Theme.Color.Danger, Theme.Color.Danger
		end
		if _darkInk then
			return INK_DARK, INK_DARK_DIM
		end
		return Theme.Color.TextPrimary, Theme.Color.TextSecondary
	end
	local litFill = if entry.danger then Theme.Color.Danger else Theme.Color.Accent

	local btn = Instance.new("TextButton")
	btn.Name = entry.key
	btn.AutoButtonColor = false
	btn.Text = ""
	btn.BackgroundColor3 = Theme.Color.BgRaised
	btn.BackgroundTransparency = 1
	btn.BorderSizePixel = 0
	btn.AutomaticSize = Enum.AutomaticSize.X
	btn.Size = UDim2.fromOffset(MIN_W, BUTTON_H)
	btn.LayoutOrder = order
	btn.Parent = parent

	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, Theme.Radius.MD)
	c.Parent = btn

	-- Padding plus AutomaticSize.X is what lets "Bulldoze" and "Build" share a row
	-- without either being clipped or the short one looking stranded.
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 12)
	pad.Parent = btn

	local col = Instance.new("UIListLayout")
	col.FillDirection = Enum.FillDirection.Horizontal
	col.HorizontalAlignment = Enum.HorizontalAlignment.Center
	col.VerticalAlignment = Enum.VerticalAlignment.Center
	col.SortOrder = Enum.SortOrder.LayoutOrder
	col.Padding = UDim.new(0, 7)
	col.Parent = btn

	local img = Instance.new("ImageLabel")
	img.Name = "Icon"
	img.BackgroundTransparency = 1
	img.Size = UDim2.fromOffset(ICON, ICON)
	img.ScaleType = Enum.ScaleType.Fit
	img.Image = entry.icon.image
	img.ImageColor3 = Theme.Color.TextPrimary
	img.LayoutOrder = 1
	img.Parent = btn

	local text = Instance.new("TextLabel")
	text.Name = "Label"
	text.BackgroundTransparency = 1
	text.AutomaticSize = Enum.AutomaticSize.X
	text.Size = UDim2.fromOffset(0, 16)
	text.Text = entry.label
	text.TextSize = Theme.TextSize.XS
	text.TextColor3 = Theme.Color.TextSecondary
	text.FontFace = Theme.Font.Header
	text.LayoutOrder = 2
	text.Parent = btn

	local hovered = false
	local selected = false
	local function apply()
		local restInk, restLabel = palette()
		UITween.to(btn, "Hover", {
			BackgroundColor3 = if selected then litFill else Theme.Color.BgHover,
			BackgroundTransparency = if selected then 0 elseif hovered then 0.35 else 1,
		})
		UITween.to(img, "Hover", {
			ImageColor3 = if selected then Theme.Color.OnAccent else restInk,
		})
		UITween.to(text, "Hover", {
			TextColor3 = if selected then Theme.Color.OnAccent
				elseif hovered then restInk
				else restLabel,
		})
	end
	table.insert(_restyle, apply)

	track(btn.MouseEnter:Connect(function()
		hovered = true
		apply()
	end))
	track(btn.MouseLeave:Connect(function()
		hovered = false
		apply()
	end))
	track(btn.Activated:Connect(function()
		SoundFX.play("Click")
		entry.onClick()
	end))

	if entry.tooltip then
		Tooltip.attach(btn, entry.tooltip)
	end

	_buttons[entry.key] = function(value: boolean)
		if selected == value then
			return
		end
		selected = value
		apply()
	end
end

-- Builds the rail. Safe to call once; a second call rebuilds from scratch.
function ToolRail.build(gui: ScreenGui, entries: { Entry }): Frame
	if _root then
		ToolRail.Destroy()
	end
	HudScale.attach(gui)

	local root = Instance.new("Frame")
	root.Name = "ToolRail"
	root.AnchorPoint = Vector2.new(0.5, 1)
	root.Position = UDim2.new(0.5, 0, 1, -BOTTOM)
	root.AutomaticSize = Enum.AutomaticSize.X
	root.Size = UDim2.fromOffset(0, BUTTON_H + RAIL_PAD * 2)
	root.ZIndex = Theme.Z.HUD
	Glass.apply(root, Theme.Radius.XL)
	root.Parent = gui
	_root = root

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, RAIL_PAD)
	pad.PaddingRight = UDim.new(0, RAIL_PAD)
	pad.PaddingTop = UDim.new(0, RAIL_PAD)
	pad.PaddingBottom = UDim.new(0, RAIL_PAD)
	pad.Parent = root

	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.VerticalAlignment = Enum.VerticalAlignment.Center
	row.SortOrder = Enum.SortOrder.LayoutOrder
	row.Padding = UDim.new(0, 2)
	row.Parent = root

	local order = 0
	local lastGroup: number? = nil
	for _, entry in entries do
		local group = entry.group or 1
		if lastGroup ~= nil and group ~= lastGroup then
			order += 1
			local rule = Instance.new("Frame")
			rule.Name = "Rule"
			rule.BackgroundColor3 = Theme.Glass.StrokeColor
			rule.BackgroundTransparency = 0.5
			rule.BorderSizePixel = 0
			rule.Size = UDim2.fromOffset(1, 22)
			rule.LayoutOrder = order
			rule.Parent = root
		end
		lastGroup = group
		order += 1
		buildButton(root, order, entry)
		if entry.isDefault then
			_defaultKey = entry.key
		end
	end

	-- Ink follows the glass: at high UI transparency the world shows through the
	-- rail and white-on-grass is unreadable, so text and icons go dark.
	local function applyInk()
		local want = (tonumber(Settings.get("uiTransparency")) or 0) >= DARK_INK_AT
		if want == _darkInk then
			return
		end
		_darkInk = want
		for _, fn in _restyle do
			fn()
		end
	end
	-- Settings.onChanged returns nothing to disconnect (it just appends to a
	-- subscriber list), so this is not tracked. Harmless: Settings is a session
	-- singleton and applyInk only touches buttons it can still see.
	Settings.onChanged("uiTransparency", applyInk)
	_darkInk = not ((tonumber(Settings.get("uiTransparency")) or 0) >= DARK_INK_AT)
	applyInk()

	syncDefault() -- open with the resting tool lit rather than a blank rail
	return root
end

-- Slide the rail up into its resting place. Lives here because the rest
-- position is ToolRail's own geometry -- the caller used to repeat the bottom
-- margin as a literal, which drifts the moment BOTTOM changes.
function ToolRail.reveal()
	local root = _root
	if not root then
		return
	end
	root.Visible = true
	root.Position = UDim2.new(0.5, 0, 1, BOTTOM + 56)
	UITween.to(root, "Flyout", { Position = UDim2.new(0.5, 0, 1, -BOTTOM) })
end

function ToolRail.setSelected(key: string, selected: boolean)
	-- The default's lit state is derived from every other entry, never set.
	if key == _defaultKey then
		return
	end
	_selected[key] = selected or nil
	local apply = _buttons[key]
	if apply then
		apply(selected)
	end
	syncDefault()
end

-- Drops every lit state. The caller uses this when a tool exits by a route the
-- rail never saw -- Esc, a right-click cancel, a section closing itself.
function ToolRail.clearSelection()
	for key, apply in _buttons do
		_selected[key] = nil
		apply(false)
	end
	syncDefault()
end

function ToolRail.isSelected(key: string): boolean
	return _selected[key] == true
end

function ToolRail.getRoot(): Frame?
	return _root
end

-- Height of the rail including its bottom margin, so callers can park a panel
-- directly above it without hard-coding the number.
function ToolRail.heightWithMargin(): number
	return BUTTON_H + RAIL_PAD * 2 + BOTTOM
end

-- THE baseline for anything that sits above the rail -- the build dock, the tool
-- options strip, the Move It panel. One number, read by all of them, so they
-- line up with each other and with the rail.
--
-- They each used to carry a private clearance constant derived from the old
-- 72px bottom bar (RoadMoveController's was 124: "bar(64) + gap(8) +
-- moveBtn(44) + gap(8)", describing an edge capsule that no longer exists), so
-- when the bar went they drifted to three different heights.
function ToolRail.bottomInset(): number
	return ToolRail.heightWithMargin() + CLEARANCE
end

function ToolRail.Destroy()
	for _, c in _conns do
		c:Disconnect()
	end
	table.clear(_conns)
	table.clear(_buttons)
	table.clear(_selected)
	table.clear(_restyle)
	_defaultKey = nil
	if _root then
		_root:Destroy()
		_root = nil
	end
end

return ToolRail
