--!strict
-- LaneToolsView: builds the LaneTools ScreenGui + LaneViewButton at runtime.
-- LaneConnectorView (World) owns the button's behaviour and finds it by name;
-- Bootstrap mounts this so edit-mode StarterGui stays empty.

local Icons = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("Icons"))
-- Rides the same UIScale as CityUI. Without it this pill kept its full pixel size while
-- the scaled HUD shrank around it, and the right-side panels slid up underneath it.
local HudScale = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("HudScale"))
local Theme = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("Theme"))

local LaneToolsView = {}

function LaneToolsView.build(): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = "LaneTools"
	gui.Enabled = false
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- Was left at the default 0, tied with three other guis; ties draw in undefined order.
	gui.DisplayOrder = Theme.Layer.Tool + 1
	HudScale.attach(gui)

	-- Compact pill tucked directly under the STAFF launcher (same 88x30 footprint,
	-- same right margin), instead of a big empty box floating in the open.
	local n1 = Instance.new("ImageButton")
	n1.Name = "LaneViewButton"
	n1.AnchorPoint = Vector2.new(1, 0)
	n1.Position = UDim2.new(1, -10, 0, 48)
	n1.Size = UDim2.new(0, 110, 0, 30)
	-- Theme tokens, not hand-picked greys: this pill sits directly above the node tool's,
	-- and the two have to read as one stack of HUD controls (LaneConnectorView repaints the
	-- fill and stroke on toggle -- see updateButtonAppearance -- and reads them from Theme too).
	n1.BackgroundColor3 = Theme.Color.BgRaised
	n1.BorderSizePixel = 0
	n1.Parent = gui

	local n2 = Instance.new("UICorner")
	n2.Name = "UICorner"
	n2.CornerRadius = UDim.new(1, 0)
	n2.Parent = n1

	local n3 = Instance.new("UIStroke")
	n3.Name = "UIStroke"
	n3.Color = Theme.Color.StrokeSoft
	n3.Thickness = Theme.StrokeWidth.Thin
	n3.Parent = n1

	local n5 = Instance.new("ImageLabel")
	n5.Name = "Icon"
	n5.ZIndex = 4
	n5.BackgroundTransparency = 1
	n5.AnchorPoint = Vector2.new(0, 0.5)
	n5.Position = UDim2.new(0, 10, 0.5, 0)
	n5.Size = UDim2.fromOffset(16, 16)
	n5.ScaleType = Enum.ScaleType.Fit
	n5.Image = Icons.LaneView.image
	n5.ImageColor3 = Theme.Color.TextSecondary
	n5.Parent = n1

	local n4 = Instance.new("TextLabel")
	n4.Name = "Caption"
	n4.ZIndex = 4
	n4.AnchorPoint = Vector2.new(0.5, 0.5)
	n4.Position = UDim2.new(0.5, -2, 0.5, 0)
	n4.Size = UDim2.new(1, -58, 1, 0)
	n4.BackgroundTransparency = 1
	n4.BorderSizePixel = 0
	n4.Text = "LANES"
	n4.FontFace = Theme.Font.Bold
	n4.TextColor3 = Theme.Color.TextPrimary
	n4.TextSize = Theme.TextSize.XS
	n4.Parent = n1

	-- Keycap badge on the trailing edge: the pill states its own shortcut.
	local n6 = Instance.new("Frame")
	n6.Name = "Key"
	n6.AnchorPoint = Vector2.new(1, 0.5)
	n6.Position = UDim2.new(1, -6, 0.5, 0)
	n6.Size = UDim2.fromOffset(18, 18)
	n6.BackgroundColor3 = Theme.Color.BgHover
	n6.BorderSizePixel = 0
	n6.ZIndex = 4
	n6.Parent = n1
	local n6c = Instance.new("UICorner")
	n6c.CornerRadius = UDim.new(1, 0)
	n6c.Parent = n6

	local n7 = Instance.new("TextLabel")
	n7.Name = "KeyLabel"
	n7.BackgroundTransparency = 1
	n7.Size = UDim2.fromScale(1, 1)
	n7.ZIndex = 5
	n7.Text = "L"
	n7.FontFace = Theme.Font.Bold
	n7.TextColor3 = Theme.Color.TextSecondary
	n7.TextSize = Theme.TextSize.XS
	n7.Parent = n6

	return gui
end

function LaneToolsView.mount(parent: Instance): ScreenGui
	local existing = parent:FindFirstChild("LaneTools")
	if existing and existing:IsA("ScreenGui") then return existing end
	local gui = LaneToolsView.build()
	gui.Parent = parent
	return gui
end

return LaneToolsView
