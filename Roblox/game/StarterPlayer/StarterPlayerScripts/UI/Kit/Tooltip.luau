--!strict
-- Shared hover tooltip. One floating label for the whole client, shown after
-- a short delay above whatever GuiObject it is attached to. Fade-in only;
-- hide is instant. Overlay gui is created lazily on first use.

local Players = game:GetService("Players")

local Theme = require(script.Parent.Parent.Theme)
local HudScale = require(script.Parent.Parent.HudScale)
local UITween = require(script.Parent.Parent.UITween)
local Settings = require(script.Parent.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))

local _label: TextLabel? = nil
local _stroke: UIStroke? = nil
local _hoverToken = 0

local function ensureLabel(): (TextLabel, UIStroke)
	if _label and _label.Parent and _stroke then
		return _label, _stroke :: UIStroke
	end

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local gui = playerGui:FindFirstChild("UITooltipOverlay")
	if not gui then
		gui = Instance.new("ScreenGui")
		gui.Name = "UITooltipOverlay"
		;(gui :: ScreenGui).ResetOnSpawn = false
		-- Hard-above every HUD gui, and above modals so a dialog's own controls can hint.
		;(gui :: ScreenGui).DisplayOrder = Theme.Layer.Tooltip
		gui.Parent = playerGui
		HudScale.attach(gui :: ScreenGui)
	end

	local label = Instance.new("TextLabel")
	label.Name = "Tooltip"
	label.Visible = false
	label.BorderSizePixel = 0
	label.BackgroundColor3 = Theme.Color.Bg
	label.FontFace = Theme.Font.Label
	label.TextSize = Theme.TextSize.SM -- XS Montserrat was too small to read
	label.TextColor3 = Theme.Color.TextPrimary
	label.RichText = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.AutomaticSize = Enum.AutomaticSize.XY
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.ZIndex = Theme.Z.Tooltip

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Theme.Radius.SM)
	corner.Parent = label

	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = Theme.Color.Stroke
	stroke.Thickness = Theme.StrokeWidth.Thin
	stroke.Parent = label

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, Theme.Pad.XS)
	padding.PaddingBottom = UDim.new(0, Theme.Pad.XS)
	padding.PaddingLeft = UDim.new(0, Theme.Pad.SM)
	padding.PaddingRight = UDim.new(0, Theme.Pad.SM)
	padding.Parent = label

	label.Parent = gui
	_label = label
	_stroke = stroke
	return label, stroke
end

local function hideNow()
	_hoverToken += 1
	if _label then
		_label.Visible = false
	end
end

local Tooltip = {}

-- Returns a detach function. Caller owns it (rule 9).
function Tooltip.attach(target: GuiObject, text: string | () -> string): () -> ()
	local conns: { RBXScriptConnection } = {}

	local function show()
		if Settings.get("tooltips") == false then
			return
		end
		local label, stroke = ensureLabel()
		label.Text = if type(text) == "function" then text() else text
		local abs = target.AbsolutePosition
		local size = target.AbsoluteSize
		-- AbsolutePosition/AbsoluteSize are REAL px, but with the overlay on HudScale a
		-- Position offset is DESIGN px -- so divide before writing, or every tooltip lands
		-- short of its target by exactly the scale factor. See HudScale's header note.
		local gs = math.max(HudScale.get(label.Parent :: any), 0.01)
		-- Just above the target's top edge; a big gap reads as detached.
		label.Position = UDim2.fromOffset(
			math.round((abs.X + size.X // 2) / gs),
			math.round((abs.Y - 4) / gs)
		)
		label.TextTransparency = 1
		label.BackgroundTransparency = 1
		stroke.Transparency = 1
		label.Visible = true
		UITween.to(label, "Tooltip", { TextTransparency = 0, BackgroundTransparency = 0 })
		UITween.to(stroke, "Tooltip", { Transparency = 0 })
	end

	table.insert(conns, target.MouseEnter:Connect(function()
		_hoverToken += 1
		local token = _hoverToken
		task.delay(Theme.TooltipDelay, function()
			if token == _hoverToken and target.Parent ~= nil then
				show()
			end
		end)
	end))
	table.insert(conns, target.MouseLeave:Connect(hideNow))
	table.insert(conns, target.Destroying:Connect(hideNow))

	return function()
		for _, c in conns do
			c:Disconnect()
		end
		table.clear(conns)
		hideNow()
	end
end

return Tooltip
