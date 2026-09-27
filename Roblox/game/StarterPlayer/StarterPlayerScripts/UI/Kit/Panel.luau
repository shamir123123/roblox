--!strict
-- Rounded dark container. The standard chrome for every HUD surface.

local Theme = require(script.Parent.Parent.Theme)
local Glass = require(script.Parent.Glass)

export type PanelProps = {
	name: string?,
	parent: Instance?,
	size: UDim2?,
	automaticSize: Enum.AutomaticSize?,
	position: UDim2?,
	anchorPoint: Vector2?,
	layout: ("Horizontal" | "Vertical")?,
	layoutPad: number?,
	pad: number?,
	radius: number?,
	transparent: boolean?,
	zIndex: number?,
	layoutOrder: number?,
}

local Panel = {}

function Panel.new(props: PanelProps): Frame
	local frame = Instance.new("Frame")
	frame.Name = props.name or "Panel"
	frame.BorderSizePixel = 0
	if props.size then
		frame.Size = props.size
	end
	if props.automaticSize then
		frame.AutomaticSize = props.automaticSize
	end
	if props.position then
		frame.Position = props.position
	end
	if props.anchorPoint then
		frame.AnchorPoint = props.anchorPoint
	end
	if props.zIndex then
		frame.ZIndex = props.zIndex
	end
	if props.layoutOrder then
		frame.LayoutOrder = props.layoutOrder
	end

	if props.transparent then
		frame.BackgroundTransparency = 1
	else
		Glass.apply(frame, props.radius)
	end

	local pad = props.pad
	if pad and pad > 0 then
		local padding = Instance.new("UIPadding")
		padding.PaddingTop = UDim.new(0, pad)
		padding.PaddingBottom = UDim.new(0, pad)
		padding.PaddingLeft = UDim.new(0, pad)
		padding.PaddingRight = UDim.new(0, pad)
		padding.Parent = frame
	end

	if props.layout then
		local list = Instance.new("UIListLayout")
		list.FillDirection = if props.layout == "Horizontal"
			then Enum.FillDirection.Horizontal
			else Enum.FillDirection.Vertical
		list.HorizontalAlignment = Enum.HorizontalAlignment.Center
		list.VerticalAlignment = Enum.VerticalAlignment.Center
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.Padding = UDim.new(0, props.layoutPad or Theme.Pad.SM)
		list.Parent = frame
	end

	frame.Parent = props.parent
	return frame
end

return Panel
