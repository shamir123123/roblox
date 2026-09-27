--!strict
-- Tab for switching content within a panel.
--
-- A filled CHIP, not bare text. Tinted text alone was near-invisible on the
-- full-bleed shelf: a row of grey words along the bottom edge read as a caption
-- rather than as controls, and the active one was a colour change you had to
-- look for. The chip gives the row a shape at rest and the active tab a solid
-- accent fill.

local Theme = require(script.Parent.Parent.Theme)
local UITween = require(script.Parent.Parent.UITween)

export type TabProps = {
	text: string,
	parent: Instance?,
	textSize: number?,
	name: string?,
	layoutOrder: number?,
	onClick: (() -> ())?,
}

export type Tab = {
	Instance: TextButton,
	SetSelected: (self: Tab, selected: boolean) -> (),
	IsSelected: (self: Tab) -> boolean,
	Destroy: (self: Tab) -> (),
}

local Tab = {}

function Tab.new(props: TabProps): Tab
	local btn = Instance.new("TextButton")
	btn.Name = props.name or props.text
	btn.AutoButtonColor = false
	btn.BackgroundColor3 = Theme.Color.BgRaised
	btn.BackgroundTransparency = 0.7
	btn.BorderSizePixel = 0
	btn.FontFace = Theme.Font.Label
	btn.TextSize = props.textSize or Theme.TextSize.SM
	btn.TextColor3 = Theme.Color.TextSecondary
	btn.Text = string.upper(props.text)
	btn.Size = UDim2.fromOffset(0, 22)
	btn.AutomaticSize = Enum.AutomaticSize.X
	btn.LayoutOrder = props.layoutOrder or 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Theme.Radius.SM)
	corner.Parent = btn

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, Theme.Pad.MD)
	padding.PaddingRight = UDim.new(0, Theme.Pad.MD)
	padding.Parent = btn

	local selected = false
	local hovered = false
	local conns: { RBXScriptConnection } = {}

	local function apply(motion: Theme.MotionKey)
		local text = if selected then Theme.Color.OnAccent
			elseif hovered then Theme.Color.TextPrimary
			else Theme.Color.TextSecondary
		UITween.to(btn, motion, {
			TextColor3 = text,
			BackgroundColor3 = if selected then Theme.Color.Accent else Theme.Color.BgRaised,
			BackgroundTransparency = if selected then 0 elseif hovered then 0.35 else 0.7,
		})
	end

	table.insert(conns, btn.MouseEnter:Connect(function()
		hovered = true
		apply("Hover")
	end))
	table.insert(conns, btn.MouseLeave:Connect(function()
		hovered = false
		apply("Hover")
	end))

	local onClick = props.onClick
	if onClick then
		table.insert(conns, btn.Activated:Connect(function()
			require(script.Parent.Parent.Parent.Core.SoundFX).play("Tab")
			onClick()
		end))
	end

	btn.Parent = props.parent

	local handle: Tab = {
		Instance = btn,
		SetSelected = function(_, value: boolean)
			if selected == value then
				return
			end
			selected = value
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
			btn:Destroy()
		end,
	}
	return handle
end

return Tab
