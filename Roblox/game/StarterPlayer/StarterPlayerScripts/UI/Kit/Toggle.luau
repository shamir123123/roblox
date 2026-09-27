--!strict
-- Capsule on/off switch: a knob that slides and turns green (on) / red (off),
-- with the state spelled out in the empty half so it reads without colour.

local Theme = require(script.Parent.Parent.Theme)
local UITween = require(script.Parent.Parent.UITween)

local Toggle = {}

local ON_COLOR = Color3.fromRGB(78, 190, 106)
local OFF_COLOR = Color3.fromRGB(228, 92, 88)
local W, H = 68, 28
local KNOB_W = 22

export type Toggle = {
	Instance: TextButton,
	Set: (self: Toggle, on: boolean) -> (),
}

export type Props = {
	parent: Instance?,
	value: boolean?,
	layoutOrder: number?,
	color: Color3?,
	onChange: ((on: boolean) -> ())?,
}

function Toggle.new(props: Props): Toggle
	local on = props.value == true

	local btn = Instance.new("TextButton")
	btn.Name = "Toggle"
	btn.AutoButtonColor = false
	btn.Text = ""
	btn.Size = UDim2.fromOffset(W, H)
	btn.BackgroundColor3 = Theme.Color.BgPress
	btn.BorderSizePixel = 0
	btn.LayoutOrder = props.layoutOrder or 0
	local bc = Instance.new("UICorner"); bc.CornerRadius = UDim.new(1, 0); bc.Parent = btn
	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Color.StrokeSoft
	stroke.Transparency = 0.5
	stroke.Thickness = Theme.StrokeWidth.Thin
	stroke.Parent = btn

	local text = Instance.new("TextLabel")
	text.Name = "State"
	text.BackgroundTransparency = 1
	text.AnchorPoint = Vector2.new(0.5, 0.5)
	text.Size = UDim2.fromOffset(W - KNOB_W - 10, H)
	text.TextSize = Theme.TextSize.XS
	text.FontFace = Theme.Font.Bold
	text.TextColor3 = Theme.Color.TextPrimary
	text.Parent = btn

	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Size = UDim2.fromOffset(KNOB_W, H - 6)
	knob.BorderSizePixel = 0
	knob.Parent = btn
	local kc = Instance.new("UICorner"); kc.CornerRadius = UDim.new(1, 0); kc.Parent = knob

	-- Knob parks on the side it switched to; the label fills the other half.
	local function apply(instant: boolean?)
		local knobPos = UDim2.fromOffset(if on then KNOB_W / 2 + 3 else W - KNOB_W / 2 - 3, H / 2)
		local textPos = UDim2.fromOffset(if on then (W + KNOB_W) / 2 else (W - KNOB_W) / 2, H / 2)
		knob.BackgroundColor3 = if on then ON_COLOR else OFF_COLOR
		text.Text = if on then "On" else "Off"
		if instant then
			knob.Position = knobPos
			text.Position = textPos
		else
			UITween.to(knob, "Hover", { Position = knobPos })
			UITween.to(text, "Hover", { Position = textPos })
		end
		stroke.Transparency = 0.5
	end

	btn.Activated:Connect(function()
		on = not on
		apply()
		if props.onChange then
			props.onChange(on)
		end
	end)

	apply(true)
	btn.Parent = props.parent

	local self = {}
	self.Instance = btn
	-- External sync; does not fire onChange.
	function self.Set(_: any, v: boolean)
		if on == v then
			return
		end
		on = v
		apply()
	end
	return (self :: any) :: Toggle
end

return Toggle