--!strict
-- Centered modal dialog over a dimmed scrim. Fade + slight scale-in per
-- Theme.Motion.Modal. Click on the scrim (outside the panel) closes it.

local Players = game:GetService("Players")

local Theme = require(script.Parent.Parent.Theme)
local HudScale = require(script.Parent.Parent.HudScale)
local UITween = require(script.Parent.Parent.UITween)
local Glass = require(script.Parent.Glass)
local Icons = require(script.Parent.Parent.Icons)
local SoundFX = require(script.Parent.Parent.Parent.Core.SoundFX)

export type ModalProps = {
	size: UDim2,
	title: string?,
	parent: Instance?, -- defaults to a lazily created overlay ScreenGui
	name: string?,
	onClose: (() -> ())?,
	-- Opaque panel instead of glass. For dialogs that open over an already busy
	-- surface (the settings page), where see-through reads as broken rather than deep.
	solid: boolean?,
}

export type Modal = {
	Root: Frame,
	Content: Frame,
	Show: (self: Modal) -> (),
	Hide: (self: Modal) -> (),
	IsOpen: (self: Modal) -> boolean,
	Destroy: (self: Modal) -> (),
}

local Modal = {}

local function ensureOverlay(): ScreenGui
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = playerGui:FindFirstChild("UIModalOverlay")
	if gui and gui:IsA("ScreenGui") then
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		return gui
	end
	local created = Instance.new("ScreenGui")
	created.Name = "UIModalOverlay"
	created.ResetOnSpawn = false
	-- Layer, not Z: Z ranks siblings inside one gui, DisplayOrder ranks the guis. At
	-- Theme.Z.Modal (50) this tied with the toast gui, so a dialog could be drawn under
	-- notifications depending on which was created first.
	created.DisplayOrder = Theme.Layer.Modal
	created.IgnoreGuiInset = true
	created.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	created.Parent = playerGui
	-- Safe to scale: the only absolute-pixel maths here is the outside-click hit test,
	-- which compares AbsolutePosition against the input position -- both real px, so the
	-- comparison stays correct at any scale.
	HudScale.attach(created)
	return created
end

function Modal.new(props: ModalProps): Modal
	local scrim = Instance.new("Frame")
	scrim.Name = props.name or "Modal"
	scrim.Visible = false
	scrim.BorderSizePixel = 0
	scrim.BackgroundColor3 = Theme.Color.Scrim
	scrim.BackgroundTransparency = 1
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.ZIndex = Theme.Z.Modal
	-- A Frame does not block input unless it is Active: without this, buttons behind
	-- the scrim still answer clicks and the dialog is not actually modal.
	scrim.Active = true

	local panel = Instance.new("CanvasGroup")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = props.size
	panel.GroupTransparency = 1
	panel.ZIndex = Theme.Z.Modal + 1
	panel.Parent = scrim
	Glass.apply(panel, Theme.Radius.LG)
	if props.solid then
		panel.BackgroundColor3 = Theme.Color.BgRaised
		panel.BackgroundTransparency = 0
	end

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, Theme.Pad.LG)
	padding.PaddingBottom = UDim.new(0, Theme.Pad.LG)
	padding.PaddingLeft = UDim.new(0, Theme.Pad.LG)
	padding.PaddingRight = UDim.new(0, Theme.Pad.LG)
	padding.Parent = panel

	local scale = Instance.new("UIScale")
	scale.Scale = Theme.ModalScaleFrom
	scale.Parent = panel

	local conns: { RBXScriptConnection } = {}
	local open = false

	local contentTop = 0
	if props.title then
		local titleLabel = Instance.new("TextLabel")
		titleLabel.Name = "Title"
		titleLabel.BackgroundTransparency = 1
		titleLabel.FontFace = Theme.Font.Header
		titleLabel.TextSize = Theme.TextSize.LG
		titleLabel.TextColor3 = Theme.Color.TextPrimary
		titleLabel.TextXAlignment = Enum.TextXAlignment.Left
		titleLabel.ZIndex = panel.ZIndex + 2
		titleLabel.Text = string.upper(props.title :: string)
		titleLabel.Size = UDim2.new(1, -32, 0, 28)
		titleLabel.Parent = panel

		-- Icon art, not a text glyph: Montserrat has no dingbat cross, so \u{2715}
		-- rendered as an empty tofu box on every modal in the game.
		local closeBtn = Instance.new("ImageButton")
		closeBtn.Name = "Close"
		closeBtn.AutoButtonColor = false
		closeBtn.BackgroundTransparency = 1
		closeBtn.Image = Icons.Close.image
		closeBtn.ImageColor3 = Theme.Color.TextSecondary
		closeBtn.ScaleType = Enum.ScaleType.Fit
		closeBtn.ZIndex = panel.ZIndex + 2
		closeBtn.AnchorPoint = Vector2.new(1, 0)
		closeBtn.Position = UDim2.fromScale(1, 0)
		closeBtn.Size = UDim2.fromOffset(22, 22)
		closeBtn.Parent = panel

		table.insert(conns, closeBtn.MouseEnter:Connect(function()
			UITween.to(closeBtn, "Hover", { ImageColor3 = Theme.Color.TextPrimary })
		end))
		table.insert(conns, closeBtn.MouseLeave:Connect(function()
			UITween.to(closeBtn, "Hover", { ImageColor3 = Theme.Color.TextSecondary })
		end))

		contentTop = 28 + Theme.Pad.MD

		table.insert(conns, closeBtn.Activated:Connect(function()
			local onClose = props.onClose
			if onClose then
				onClose()
			end
		end))
	end

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.ZIndex = panel.ZIndex + 2
	content.Position = UDim2.fromOffset(0, contentTop)
	content.Size = UDim2.new(1, 0, 1, -contentTop)
	content.Parent = panel

	scrim.Parent = props.parent or ensureOverlay()

	-- The overlay carries the global HudScale, and a UIScale multiplies scale sizes too:
	-- a fromScale(1, 1) scrim came out SMALLER than the screen on any viewport under the
	-- design canvas, leaving a live strip of HUD down the right and bottom edges -- bottom
	-- bar buttons there still lit up and answered clicks behind an open modal. Size the
	-- scrim against the scale so it always covers everything; the panel inside stays scaled.
	local hudScale = scrim.Parent and scrim.Parent:FindFirstChild("HudScale")
	if hudScale and hudScale:IsA("UIScale") then
		local function fitScrim()
			local s = math.max(hudScale.Scale, 0.01)
			scrim.Size = UDim2.fromScale(1 / s, 1 / s)
		end
		table.insert(conns, hudScale:GetPropertyChangedSignal("Scale"):Connect(fitScrim))
		fitScrim()
	end

	local function hide()
		if not open then
			return
		end
		open = false
		SoundFX.play("Close")
		UITween.to(scrim, "Modal", { BackgroundTransparency = 1 })
		UITween.to(scale, "Modal", { Scale = Theme.ModalScaleFrom })
		local tween = UITween.to(panel, "Modal", { GroupTransparency = 1 })
		tween.Completed:Once(function()
			if not open then
				scrim.Visible = false
			end
		end)
	end

	local function show()
		if open then
			return
		end
		open = true
		SoundFX.play("Open")
		scrim.Visible = true
		UITween.to(scrim, "Modal", { BackgroundTransparency = 1 - Theme.ScrimOpacity })
		UITween.to(scale, "Modal", { Scale = 1 })
		UITween.to(panel, "Modal", { GroupTransparency = 0 })
	end

	-- Scrim click closes; clicks inside the panel don't reach here because
	-- the hit test runs against the panel bounds.
	table.insert(conns, scrim.InputBegan:Connect(function(input: InputObject)
		local t = input.UserInputType
		if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then
			return
		end
		local pos = Vector2.new(input.Position.X, input.Position.Y)
		local p = panel.AbsolutePosition
		local s = panel.AbsoluteSize
		local inside = pos.X >= p.X and pos.X <= p.X + s.X and pos.Y >= p.Y and pos.Y <= p.Y + s.Y
		if not inside then
			local onClose = props.onClose
			if onClose then
				onClose()
			else
				hide()
			end
		end
	end))

	local handle: Modal = {
		Root = scrim,
		Content = content,
		Show = function(_)
			show()
		end,
		Hide = function(_)
			hide()
		end,
		IsOpen = function(_): boolean
			return open
		end,
		Destroy = function(_)
			for _, c in conns do
				c:Disconnect()
			end
			table.clear(conns)
			UITween.cancelAll(scrim)
			UITween.cancelAll(panel)
			UITween.cancelAll(scale)
			scrim:Destroy()
		end,
	}
	return handle
end

return Modal
