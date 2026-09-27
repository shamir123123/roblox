--!strict
-- Square icon button. Icon is a child ImageLabel tinted via ImageColor3 so
-- one white PNG set covers every state. Text fallback until icons upload.

local Theme = require(script.Parent.Parent.Theme)
local Icons = require(script.Parent.Parent.Icons)
local UITween = require(script.Parent.Parent.UITween)
local Tooltip = require(script.Parent.Tooltip)
local SoundFX = require(script.Parent.Parent.Parent.Core.SoundFX)

export type IconButtonProps = {
	icon: Icons.Icon?,     -- preferred: a registry entry (image + glyph fallback)
	image: string?,        -- asset id; overrides icon.image when set
	fallbackText: string?, -- glyph; overrides icon.glyph when set
	parent: Instance?,
	size: number?,         -- square px, default 36
	tooltip: string?,
	name: string?,
	layoutOrder: number?,
	danger: boolean?,       -- destructive tool: red tint at rest, red fill when selected
	outlined: boolean?,     -- bare icon that KEEPS its hairline chip at rest
	colored: boolean?,      -- keep a coloured PNG at full colour (no tint); select = lighter bg
	onClick: (() -> ())?,
}

export type IconButton = {
	Instance: ImageButton,
	SetSelected: (self: IconButton, selected: boolean) -> (),
	SetEnabled: (self: IconButton, enabled: boolean) -> (),
	IsSelected: (self: IconButton) -> boolean,
	SetImage: (self: IconButton, image: string) -> (),
	Destroy: (self: IconButton) -> (),
}

local IconButton = {}

function IconButton.new(props: IconButtonProps): IconButton
	local px = props.size or 36

	-- Resolve the icon: explicit image/fallbackText win, otherwise pull from the
	-- registry entry. An empty registry image ("") falls through to the glyph.
	local image: string? = props.image
	local glyph: string? = props.fallbackText
	if props.icon then
		if not image and props.icon.image ~= "" then
			image = props.icon.image
		end
		if not glyph then
			glyph = props.icon.glyph
		end
	end

	local btn = Instance.new("ImageButton")
	btn.Name = props.name or props.tooltip or "IconButton"
	btn.AutoButtonColor = false
	btn.BorderSizePixel = 0
	btn.BackgroundColor3 = Theme.Color.BgRaised
	btn.Image = ""
	btn.Size = UDim2.fromOffset(px, px)
	btn.LayoutOrder = props.layoutOrder or 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Theme.Radius.LG) -- rounded square chip
	corner.Parent = btn

	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Color.StrokeSoft
	stroke.Thickness = Theme.StrokeWidth.Thin
	stroke.Parent = btn

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	-- 0.68 scale + full-brightness tint at rest: thin-line icons at chip size
	-- were unreadable with the dimmed TextSecondary treatment.
	icon.Size = UDim2.fromScale(0.68, 0.68)
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Image = image or ""
	icon.ImageColor3 = if props.colored then Color3.new(1, 1, 1) else Theme.Color.TextPrimary
	icon.Parent = btn

	-- Glyph stands in ONLY for registry entries that have no art (Budget, DevPoints,
	-- Signals, the View* heatmap set). It is never built behind a real image: both sit on
	-- the same centre, so a button with art drew the glyph over the art.
	local fallback: TextLabel? = nil
	if glyph and not (image and image ~= "") then
		local label = Instance.new("TextLabel")
		label.Name = "Fallback"
		label.BackgroundTransparency = 1
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromScale(0.5, 0.5)
		label.Size = UDim2.fromScale(1, 1)
		label.FontFace = Theme.Font.Label
		label.TextSize = Theme.TextSize.MD
		label.TextColor3 = Theme.Color.TextPrimary
		label.Text = glyph :: string
		label.Parent = btn
		fallback = label
	end

	local danger = props.danger == true
	local colored = props.colored == true
	local outlined = props.outlined == true
	if colored then
		-- Bare icon: no background chip, bigger art; the active tool is marked by
		-- tinting the icon itself to the accent (see targetColors), no underline.
		btn.BackgroundTransparency = 1
		stroke.Transparency = if props.outlined then 0.55 else 1
		icon.Size = UDim2.fromScale(0.62, 0.62)
	end
	local selected = false
	local enabled = true
	local hovered = false
	local pressed = false
	local conns: { RBXScriptConnection } = {}
	local detachTooltip: (() -> ())? = nil

	if props.tooltip then
		detachTooltip = Tooltip.attach(btn, props.tooltip :: string)
	end

	local function targetColors(): (Color3, Color3, Color3)
		-- returns bg, icon tint, stroke
		if colored then
			-- Bare white-line icon: the icon tint IS the state -- accent when active,
			-- white otherwise. Background/stroke are invisible in this mode.
			local white = Color3.new(1, 1, 1)
			if not enabled then return Theme.Color.Bg, Theme.Color.TextDisabled, Theme.Color.StrokeSoft end
			if selected then return Theme.Color.Accent, Theme.Color.OnAccent, Theme.Color.AccentHover end -- fill + lighter ring
			if pressed then return Theme.Color.BgPress, Theme.Color.AccentPress, Theme.Color.Stroke end
			if hovered then return Theme.Color.BgHover, Theme.Color.AccentHover, Theme.Color.Stroke end
			return Theme.Color.BgRaised, white, Theme.Color.StrokeSoft
		end
		if not enabled then
			return Theme.Color.Bg, Theme.Color.TextDisabled, Theme.Color.StrokeSoft
		end
		if danger then
			if selected then
				return Theme.Color.Danger, Theme.Color.TextPrimary, Theme.Color.Danger
			end
			if pressed then
				return Theme.Color.BgPress, Theme.Color.Danger, Theme.Color.Danger
			end
			if hovered then
				return Theme.Color.BgHover, Theme.Color.Danger, Theme.Color.Danger
			end
			return Theme.Color.BgRaised, Theme.Color.Danger, Theme.Color.StrokeSoft
		end
		if selected then
			return Theme.Color.Accent, Theme.Color.OnAccent, Theme.Color.AccentHover
		end
		if pressed then
			return Theme.Color.BgPress, Theme.Color.TextPrimary, Theme.Color.Stroke
		end
		if hovered then
			return Theme.Color.BgHover, Theme.Color.TextPrimary, Theme.Color.Stroke
		end
		return Theme.Color.BgRaised, Theme.Color.TextPrimary, Theme.Color.StrokeSoft
	end

	local function apply(motion: Theme.MotionKey)
		local bg, tint, strokeColor = targetColors()
		local btnProps: { [string]: any } = { BackgroundColor3 = bg }
		local strokeProps: { [string]: any } = { Color = strokeColor }
		if colored then
			-- Bare icon at rest, filled accent chip when active: the HUD's
			-- "this is the current tool" mark.
			btnProps.BackgroundTransparency = if selected then 0 else 1
			strokeProps.Transparency = if selected then 0 elseif outlined then 0.55 else 1
		end
		-- Selected reads as accent fill ringed by a lighter accent hairline.
		strokeProps.Thickness = if selected then Theme.StrokeWidth.Thick else Theme.StrokeWidth.Thin
		UITween.to(btn, motion, btnProps)
		UITween.to(icon, motion, { ImageColor3 = tint })
		UITween.to(stroke, motion, strokeProps)
		if fallback then
			UITween.to(fallback, motion, { TextColor3 = tint })
		end
	end

	table.insert(conns, btn.MouseEnter:Connect(function()
		hovered = true
		apply("Hover")
	end))
	table.insert(conns, btn.MouseLeave:Connect(function()
		hovered = false
		pressed = false
		apply("Hover")
	end))
	table.insert(conns, btn.MouseButton1Down:Connect(function()
		pressed = true
		apply("Press")
	end))
	table.insert(conns, btn.MouseButton1Up:Connect(function()
		pressed = false
		apply("Press")
	end))

	local onClick = props.onClick
	if onClick then
		table.insert(conns, btn.Activated:Connect(function()
			if enabled then
				SoundFX.play("Click")
				onClick()
			end
		end))
	end

	btn.Parent = props.parent

	local handle: IconButton = {
		Instance = btn,
		SetSelected = function(_, value: boolean)
			if selected == value then
				return
			end
			selected = value
			apply("Hover")
		end,
		SetEnabled = function(_, value: boolean)
			if enabled == value then
				return
			end
			enabled = value
			btn.Active = value
			apply("Hover")
		end,
		IsSelected = function(_): boolean
			return selected
		end,
		SetImage = function(_, image: string)
			icon.Image = image
			if fallback then
				(fallback :: TextLabel).Visible = image == ""
			end
		end,
		Destroy = function(_)
			for _, c in conns do
				c:Disconnect()
			end
			table.clear(conns)
			if detachTooltip then
				detachTooltip()
			end
			UITween.cancelAll(btn)
			UITween.cancelAll(icon)
			UITween.cancelAll(stroke)
			btn:Destroy()
		end,
	}
	return handle
end

return IconButton
