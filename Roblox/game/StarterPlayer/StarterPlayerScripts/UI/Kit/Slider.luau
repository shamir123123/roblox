--!strict
-- Capsule slider: track + accent fill + round knob + percent readout.
-- Click or drag anywhere on the row to set. Values live in [min, max]
-- (default 0..1); the readout shows the value as a percent.

local UserInputService = game:GetService("UserInputService")

local Theme = require(script.Parent.Parent.Theme)

local Slider = {}

export type Slider = {
	Instance: Frame,
	Set: (self: Slider, value: number) -> (),
}

export type Props = {
	parent: Instance?,
	value: number?,
	min: number?,
	max: number?,
	width: number?,
	layoutOrder: number?,
	color: Color3?,
	onChange: ((value: number) -> ())?,
}

local READOUT_W = 40

function Slider.new(props: Props): Slider
	local min = props.min or 0
	local max = math.max(props.max or 1, min + 1e-6)
	local trackW = props.width or 170
	local value = math.clamp(props.value or min, min, max)

	local holder = Instance.new("Frame")
	holder.Name = "Slider"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromOffset(trackW + READOUT_W + Theme.Pad.MD, 26)
	holder.LayoutOrder = props.layoutOrder or 0

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0, 0.5)
	track.Position = UDim2.new(0, 0, 0.5, 0)
	track.Size = UDim2.fromOffset(trackW, 4)
	track.BackgroundColor3 = Theme.Color.BgPress
	track.BorderSizePixel = 0
	track.Parent = holder
	local tc = Instance.new("UICorner"); tc.CornerRadius = UDim.new(1, 0); tc.Parent = track

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = props.color or Theme.Color.Accent
	fill.BorderSizePixel = 0
	fill.Parent = track
	local fc = Instance.new("UICorner"); fc.CornerRadius = UDim.new(1, 0); fc.Parent = fill

	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Size = UDim2.fromOffset(12, 12)
	knob.BackgroundColor3 = Color3.fromRGB(235, 235, 235)
	knob.BorderSizePixel = 0
	knob.Parent = track
	local kc = Instance.new("UICorner"); kc.CornerRadius = UDim.new(1, 0); kc.Parent = knob

	local readout = Instance.new("TextLabel")
	readout.Name = "Value"
	readout.BackgroundTransparency = 1
	readout.AnchorPoint = Vector2.new(1, 0.5)
	readout.Position = UDim2.new(1, 0, 0.5, 0)
	readout.Size = UDim2.fromOffset(READOUT_W, 16)
	readout.TextSize = Theme.TextSize.XS
	readout.TextColor3 = Theme.Color.TextSecondary
	readout.FontFace = Theme.Font.Header
	readout.TextXAlignment = Enum.TextXAlignment.Right
	readout.Parent = holder

	local function apply()
		local frac = (value - min) / (max - min)
		fill.Size = UDim2.new(frac, 0, 1, 0)
		knob.Position = UDim2.new(frac, 0, 0.5, 0)
		readout.Text = tostring(math.floor(value * 100 + 0.5)) .. "%"
	end

	-- Full-height invisible hit area: the 4px track alone is too fiddly to click.
	local hit = Instance.new("TextButton")
	hit.Name = "Hit"
	hit.BackgroundTransparency = 1
	hit.Text = ""
	hit.Size = UDim2.new(0, trackW, 1, 0)
	hit.Parent = holder

	local dragging = false
	local function setFromX(x: number)
		local frac = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
		value = min + frac * (max - min)
		apply()
		if props.onChange then
			props.onChange(value)
		end
	end
	hit.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)

	apply()
	holder.Parent = props.parent

	local self = {}
	self.Instance = holder
	-- External sync (another surface changed the value); does not fire onChange.
	function self.Set(_: any, v: number)
		value = math.clamp(v, min, max)
		apply()
	end
	return (self :: any) :: Slider
end

return Slider