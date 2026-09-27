--!strict
-- Bordered value box that drops a pick list. The list is parented to the host
-- ScreenGui, not the button, so a row inside a ScrollingFrame can't clip it.

local Theme = require(script.Parent.Parent.Theme)
local UITween = require(script.Parent.Parent.UITween)

local Dropdown = {}

export type Option = { label: string, value: any }

export type Dropdown = {
	Instance: TextButton,
	Set: (self: Dropdown, value: any) -> (),
}

export type Props = {
	parent: Instance?,
	options: { Option },
	value: any,
	width: number?,
	color: Color3?,
	onChange: ((value: any) -> ())?,
}

local ROW_H = 30
-- The pick list parents to the host ScreenGui, so it becomes a SIBLING of whatever panel
-- the button sits in -- and a modal's scrim is Z.Modal. At Z.Popover the list drew UNDER
-- the dialog that opened it. A popover is by definition the top thing in its gui, so it is
-- ranked above every surface here rather than in the middle of them.
local MENU_Z = Theme.Z.Modal + 10

local function corner(inst: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = inst
end

function Dropdown.new(props: Props): Dropdown
	local accent = props.color or Theme.Color.Accent
	local width = props.width or 190
	local current = props.value
	local list: Frame? = nil
	local backdrop: TextButton? = nil

	local btn = Instance.new("TextButton")
	btn.Name = "Dropdown"
	btn.AutoButtonColor = false
	btn.Text = ""
	btn.Size = UDim2.fromOffset(width, ROW_H)
	btn.BackgroundColor3 = Theme.Color.BgPress
	btn.BackgroundTransparency = 0.15
	btn.BorderSizePixel = 0
	corner(btn, Theme.Radius.SM)

	local stroke = Instance.new("UIStroke")
	stroke.Color = accent
	stroke.Transparency = 0.45
	stroke.Thickness = Theme.StrokeWidth.Thin
	stroke.Parent = btn

	local valueLabel = Instance.new("TextLabel")
	valueLabel.BackgroundTransparency = 1
	valueLabel.Position = UDim2.fromOffset(10, 0)
	valueLabel.Size = UDim2.new(1, -34, 1, 0)
	valueLabel.TextXAlignment = Enum.TextXAlignment.Left
	valueLabel.TextColor3 = Theme.Color.TextPrimary
	valueLabel.TextSize = Theme.TextSize.SM
	valueLabel.FontFace = Theme.Font.Label
	valueLabel.TextTruncate = Enum.TextTruncate.AtEnd
	valueLabel.Parent = btn

	-- Drawn from two bars, not a glyph: Montserrat has no caret codepoint and
	-- renders it as a tofu box.
	local chevron = Instance.new("Frame")
	chevron.Name = "Caret"
	chevron.BackgroundTransparency = 1
	chevron.AnchorPoint = Vector2.new(1, 0.5)
	chevron.Position = UDim2.new(1, -12, 0.5, 0)
	chevron.Size = UDim2.fromOffset(12, 12)
	chevron.Parent = btn
	for _, dir in { -1, 1 } do
		local bar = Instance.new("Frame")
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.Position = UDim2.fromScale(0.5 + dir * 0.19, 0.5)
		bar.Size = UDim2.fromOffset(9, 2)
		bar.Rotation = dir * 45
		bar.BackgroundColor3 = accent
		bar.BorderSizePixel = 0
		bar.Parent = chevron
		corner(bar, 1)
	end

	local function labelFor(value: any): string
		for _, opt in props.options do
			if opt.value == value then
				return opt.label
			end
		end
		return "\u{2014}"
	end
	valueLabel.Text = labelFor(current)

	local function close()
		if list then
			list:Destroy()
			list = nil
		end
		if backdrop then
			backdrop:Destroy()
			backdrop = nil
		end
		UITween.to(chevron, "Hover", { Rotation = 0 })
	end

	local function open()
		local host = btn:FindFirstAncestorWhichIsA("ScreenGui")
		if not host then
			return
		end
		close()

		local back = Instance.new("TextButton")
		back.Name = "DropdownBackdrop"
		back.AutoButtonColor = false
		back.Text = ""
		back.BackgroundTransparency = 1
		back.Size = UDim2.fromScale(1, 1)
		back.ZIndex = MENU_Z
		back.Parent = host
		backdrop = back
		-- Deferred: the click that opened this menu is still being delivered, and a
		-- backdrop wired up now catches its own release and shuts the menu again.
		task.defer(function()
			if back.Parent then
				back.Activated:Connect(close)
			end
		end)

		local menu = Instance.new("Frame")
		menu.Name = "DropdownMenu"
		menu.BackgroundColor3 = Theme.Color.Bg
		menu.BackgroundTransparency = 0.04
		menu.BorderSizePixel = 0
		menu.ZIndex = MENU_Z + 1
		menu.Size = UDim2.fromOffset(width, #props.options * ROW_H + 8)
		-- Absolute placement: the row may live inside a scrolling page.
		local origin = host.AbsolutePosition
		local at = btn.AbsolutePosition
		menu.Position = UDim2.fromOffset(at.X - origin.X, at.Y - origin.Y + ROW_H + 4)
		menu.Parent = host
		corner(menu, Theme.Radius.SM)
		list = menu

		local ms = Instance.new("UIStroke")
		ms.Color = accent
		ms.Transparency = 0.5
		ms.Parent = menu
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0, 4)
		pad.PaddingBottom = UDim.new(0, 4)
		pad.Parent = menu
		local layout = Instance.new("UIListLayout")
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = menu

		for i, opt in props.options do
			local item = Instance.new("TextButton")
			item.AutoButtonColor = false
			item.BackgroundColor3 = accent
			item.BackgroundTransparency = if opt.value == current then 0.78 else 1
			item.BorderSizePixel = 0
			item.Size = UDim2.new(1, 0, 0, ROW_H)
			item.LayoutOrder = i
			item.Text = "   " .. opt.label
			item.TextXAlignment = Enum.TextXAlignment.Left
			item.TextColor3 = if opt.value == current then accent else Theme.Color.TextPrimary
			item.TextSize = Theme.TextSize.SM
			item.FontFace = Theme.Font.Label
			item.ZIndex = MENU_Z + 2
			item.Parent = menu
			item.MouseEnter:Connect(function()
				if opt.value ~= current then
					item.BackgroundTransparency = 0.88
				end
			end)
			item.MouseLeave:Connect(function()
				item.BackgroundTransparency = if opt.value == current then 0.78 else 1
			end)
			item.Activated:Connect(function()
				current = opt.value
				valueLabel.Text = opt.label
				close()
				if props.onChange then
					props.onChange(opt.value)
				end
			end)
		end

		UITween.to(chevron, "Hover", { Rotation = 180 })
	end

	btn.MouseEnter:Connect(function()
		UITween.to(stroke, "Hover", { Transparency = 0.1 })
	end)
	btn.MouseLeave:Connect(function()
		UITween.to(stroke, "Hover", { Transparency = 0.45 })
	end)
	btn.Activated:Connect(function()
		if list then
			close()
		else
			open()
		end
	end)

	btn.Parent = props.parent

	local self = {}
	self.Instance = btn
	-- External sync; does not fire onChange.
	function self.Set(_: any, value: any)
		current = value
		valueLabel.Text = labelFor(value)
	end
	return (self :: any) :: Dropdown
end

return Dropdown
