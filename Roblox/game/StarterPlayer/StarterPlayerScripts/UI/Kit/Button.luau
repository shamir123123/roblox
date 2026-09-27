--!strict
-- Factory for every standard text button. Visual states (hover, press,
-- selected, disabled) are owned here so buttons stay identical everywhere.

local Theme = require(script.Parent.Parent.Theme)
local UITween = require(script.Parent.Parent.UITween)

export type ButtonVariant = "Default" | "Danger"

-- Optional per-button color override. Same keys as Theme.Color; defaults to it.
-- Used to drop a button onto a non-HUD surface (e.g. the light create-city flow).
export type ButtonPalette = {
	Bg: Color3,
	BgRaised: Color3,
	BgHover: Color3,
	BgPress: Color3,
	Stroke: Color3,
	StrokeSoft: Color3,
	Accent: Color3,
	OnAccent: Color3,
	TextPrimary: Color3,
	TextDisabled: Color3,
	Danger: Color3,
}

export type ButtonProps = {
	text: string,
	parent: Instance?,
	size: UDim2?,
	variant: ButtonVariant?,
	textSize: number?,
	name: string?,
	layoutOrder: number?,
	compact: boolean?, -- 26px tall, tighter padding, XS text
	palette: ButtonPalette?,
	onClick: (() -> ())?,
}

export type Button = {
	Instance: TextButton,
	SetSelected: (self: Button, selected: boolean) -> (),
	SetEnabled: (self: Button, enabled: boolean) -> (),
	IsSelected: (self: Button) -> boolean,
	Destroy: (self: Button) -> (),
}

local Button = {}

function Button.new(props: ButtonProps): Button
	local variant: ButtonVariant = props.variant or "Default"
	local C = props.palette or Theme.Color

	local btn = Instance.new("TextButton")
	btn.Name = props.name or props.text
	btn.AutoButtonColor = false
	btn.BorderSizePixel = 0
	btn.BackgroundColor3 = C.BgRaised
	btn.FontFace = Theme.Font.Label
	btn.TextSize = props.textSize or (if props.compact then Theme.TextSize.XS else Theme.TextSize.SM)
	-- Modern & Clean: button labels read as thin uppercase caps on a capsule.
	btn.Text = string.upper(props.text)
	btn.LayoutOrder = props.layoutOrder or 0
	if props.size then
		btn.Size = props.size
	else
		btn.Size = UDim2.fromOffset(0, if props.compact then 26 else 32)
		btn.AutomaticSize = Enum.AutomaticSize.X
	end

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0) -- capsule
	corner.Parent = btn

	local stroke = Instance.new("UIStroke")
	stroke.Color = C.StrokeSoft
	stroke.Thickness = Theme.StrokeWidth.Thin
	stroke.Parent = btn

	local padding = Instance.new("UIPadding")
	-- Capsules need more side air than rounded rects.
	local hPad = if props.compact then Theme.Pad.MD else Theme.Pad.XL
	padding.PaddingLeft = UDim.new(0, hPad)
	padding.PaddingRight = UDim.new(0, hPad)
	padding.Parent = btn

	local selected = false
	local enabled = true
	local hovered = false
	local pressed = false
	local conns: { RBXScriptConnection } = {}

	local accentFill = if variant == "Danger" then C.Danger else C.Accent
	local idleText = if variant == "Danger" then C.Danger else C.TextPrimary

	-- Initialize text color explicitly: TextButton defaults to dark navy, and
	-- the tween path only runs on the first state change.
	btn.TextColor3 = idleText

	local function targetColors(): (Color3, Color3, Color3)
		if not enabled then
			return C.Bg, C.TextDisabled, C.StrokeSoft
		end
		if selected then
			-- Lighter accent ring around the fill. Custom palettes have no
			-- AccentHover, so they keep the flat fill-coloured edge.
			return accentFill, C.OnAccent, (if variant == "Danger" then C.Danger else ((C :: any).AccentHover or C.Accent))
		end
		if pressed then
			return C.BgPress, idleText, C.Stroke
		end
		if hovered then
			return C.BgHover, idleText, C.Stroke
		end
		return C.BgRaised, idleText, C.StrokeSoft
	end

	local function apply(motion: Theme.MotionKey)
		local bg, text, strokeColor = targetColors()
		UITween.to(btn, motion, { BackgroundColor3 = bg, TextColor3 = text })
		UITween.to(stroke, motion, {
			Color = strokeColor,
			Thickness = if selected then Theme.StrokeWidth.Thick else Theme.StrokeWidth.Thin,
		})
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
				require(script.Parent.Parent.Parent.Core.SoundFX).play("Click")
				onClick()
			end
		end))
	end

	btn.Parent = props.parent

	local handle: Button = {
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
		Destroy = function(_)
			for _, c in conns do
				c:Disconnect()
			end
			table.clear(conns)
			UITween.cancelAll(btn)
			UITween.cancelAll(stroke)
			btn:Destroy()
		end,
	}
	return handle
end

return Button
