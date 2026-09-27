--!strict
-- Floating panel anchored above a button (e.g. "Snap" options). Fades per
-- Theme.Motion.Popover; closes on any click outside itself or its anchor.

local UserInputService = game:GetService("UserInputService")

local Theme = require(script.Parent.Parent.Theme)
local UITween = require(script.Parent.Parent.UITween)
local Glass = require(script.Parent.Glass)
local SoundFX = require(script.Parent.Parent.Parent.Core.SoundFX)

export type PopoverProps = {
	anchor: GuiObject,
	parent: GuiBase2d, -- usually the ScreenGui root the anchor lives in
	size: UDim2,
	gap: number?,
	name: string?,
	pad: number?,
	anchorPoint: Vector2?, -- default (0.5, 1): centered above the anchor
	-- Custom placement in REAL screen px relative to the parent, evaluated on
	-- every open (the kit converts to the parent's scaled offset space).
	-- Overrides the default above-anchor position so a popover can dock flush
	-- against another surface (e.g. expand out of the build dock's edge).
	placeAt: (() -> UDim2)?,
	onOpenChanged: ((boolean) -> ())?,
}

export type Popover = {
	Frame: CanvasGroup,
	Show: (self: Popover) -> (),
	Hide: (self: Popover) -> (),
	Toggle: (self: Popover) -> (),
	IsOpen: (self: Popover) -> boolean,
	Destroy: (self: Popover) -> (),
}

local EDGE_MARGIN = 8

local Popover = {}

local function isInside(obj: GuiObject, pos: Vector2): boolean
	local p = obj.AbsolutePosition
	local s = obj.AbsoluteSize
	return pos.X >= p.X and pos.X <= p.X + s.X and pos.Y >= p.Y and pos.Y <= p.Y + s.Y
end

function Popover.new(props: PopoverProps): Popover
	local group = Instance.new("CanvasGroup")
	group.Name = props.name or "Popover"
	group.Size = props.size
	group.AnchorPoint = props.anchorPoint or Vector2.new(0.5, 1)
	group.GroupTransparency = 1
	group.Visible = false
	group.ZIndex = Theme.Z.Popover
	Glass.apply(group)

	local padding = Instance.new("UIPadding")
	local pad = props.pad or Theme.Pad.MD
	padding.PaddingTop = UDim.new(0, pad)
	padding.PaddingBottom = UDim.new(0, pad)
	padding.PaddingLeft = UDim.new(0, pad)
	padding.PaddingRight = UDim.new(0, pad)
	padding.Parent = group

	group.Parent = props.parent

	local open = false
	local outsideConn: RBXScriptConnection? = nil

	local function place()
		-- Real px -> the parent's offset space (a HudScale UIScale on the parent
		-- makes offsets design-px; without one this divides by 1).
		local gs = 1
		local ps = props.parent:FindFirstChild("HudScale")
		if ps and ps:IsA("UIScale") then gs = ps.Scale end
		if props.placeAt then
			local pos = props.placeAt()
			group.Position = UDim2.fromOffset(pos.X.Offset / gs, pos.Y.Offset / gs)
			return
		end
		local parentAbs = props.parent.AbsolutePosition
		local anchor = props.anchor
		local x = anchor.AbsolutePosition.X - parentAbs.X + anchor.AbsoluteSize.X / 2
		local y = anchor.AbsolutePosition.Y - parentAbs.Y - (props.gap or Theme.Pad.SM) * gs
		-- Keep it on screen: the anchor sits at the dock's right edge, so a centred
		-- popover runs off the viewport (and its tail hides under the dock).
		local ap = group.AnchorPoint
		local size = group.AbsoluteSize
		local bounds = props.parent.AbsoluteSize
		local m = EDGE_MARGIN * gs
		x = math.clamp(x, ap.X * size.X + m, bounds.X - (1 - ap.X) * size.X - m)
		y = math.clamp(y, ap.Y * size.Y + m, bounds.Y - (1 - ap.Y) * size.Y - m)
		group.Position = UDim2.fromOffset(x / gs, y / gs)
	end

	local function hide()
		if not open then
			return
		end
		open = false
		SoundFX.play("Close")
		if props.onOpenChanged then props.onOpenChanged(false) end
		if outsideConn then
			outsideConn:Disconnect()
			outsideConn = nil
		end
		local tween = UITween.to(group, "Popover", { GroupTransparency = 1 })
		tween.Completed:Once(function()
			if not open then
				group.Visible = false
			end
		end)
	end

	local function show()
		if open then
			return
		end
		open = true
		SoundFX.play("Open")
		if props.onOpenChanged then props.onOpenChanged(true) end
		place()
		group.Visible = true
		UITween.to(group, "Popover", { GroupTransparency = 0 })
		outsideConn = UserInputService.InputBegan:Connect(function(input: InputObject)
			local t = input.UserInputType
			if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then
				return
			end
			local pos = Vector2.new(input.Position.X, input.Position.Y)
			if not isInside(group, pos) and not isInside(props.anchor, pos) then
				hide()
			end
		end)
	end

	local handle: Popover = {
		Frame = group,
		Show = function(_)
			show()
		end,
		Hide = function(_)
			hide()
		end,
		Toggle = function(_)
			if open then
				hide()
			else
				show()
			end
		end,
		IsOpen = function(_): boolean
			return open
		end,
		Destroy = function(_)
			if outsideConn then
				outsideConn:Disconnect()
				outsideConn = nil
			end
			UITween.cancelAll(group)
			group:Destroy()
		end,
	}
	return handle
end

return Popover
