--!strict
-- Player Hub identity: an azure skin layered over the shared Theme.
-- The HUD chrome stays champagne; the hub alone reads BLUE (primary accent:
-- selection, actions, live values) with a warm CORAL secondary (progress
-- fills, eyebrow headings, rewards), so the hub feels like the player's own
-- space. Structure is still the shared Kit chrome -- this module only
-- re-tints it, it never re-builds it.

local Theme = require(script.Parent.Theme)
local Glass = require(script.Parent.Kit.Glass)

local HubTheme = {
	Color = {
		-- Primary accent: azure.
		Accent      = Color3.fromRGB(96, 156, 255),
		AccentHover = Color3.fromRGB(132, 180, 255),
		AccentPress = Color3.fromRGB(70, 122, 212),
		OnAccent    = Color3.fromRGB(9, 17, 32),
		AccentDim   = Color3.fromRGB(88, 116, 168),
		-- Secondary: warm coral. Complements the azure without touching the
		-- semantic money-green / danger-red or the HUD's champagne.
		Secondary    = Color3.fromRGB(255, 149, 100),
		SecondaryDim = Color3.fromRGB(186, 114, 82),
		-- Cool navy-tinted surfaces (the shared Theme greys lean warm).
		Bg       = Color3.fromRGB(11, 14, 22),
		BgRaised = Color3.fromRGB(24, 30, 44),
		BgHover  = Color3.fromRGB(36, 45, 64),
		BgPress  = Color3.fromRGB(8, 10, 16),
		-- Hub hairline: an icy blue-white instead of the neutral white.
		StrokeTint = Color3.fromRGB(168, 198, 245),
		SheenTint  = Color3.fromRGB(26, 36, 56),
	},
}

-- Drop-in palette for Kit Button: same capsule, azure accent states.
HubTheme.ButtonPalette = {
	Bg = HubTheme.Color.Bg,
	BgRaised = HubTheme.Color.BgRaised,
	BgHover = HubTheme.Color.BgHover,
	BgPress = HubTheme.Color.BgPress,
	Stroke = Theme.Color.Stroke,
	StrokeSoft = Theme.Color.StrokeSoft,
	Accent = HubTheme.Color.Accent,
	OnAccent = HubTheme.Color.OnAccent,
	TextPrimary = Theme.Color.TextPrimary,
	TextDisabled = Theme.Color.TextDisabled,
	Danger = Theme.Color.Danger,
}

-- Shared Glass chrome, re-tinted cool. Same stroke + sheen structure.
function HubTheme.glass(frame: GuiObject, radius: number?): UIStroke
	local stroke = Glass.apply(frame, radius)
	frame.BackgroundColor3 = HubTheme.Color.Bg
	stroke.Color = HubTheme.Color.StrokeTint
	local grad = frame:FindFirstChildOfClass("UIGradient")
	if grad then
		grad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, HubTheme.Color.SheenTint),
			ColorSequenceKeypoint.new(0.3, HubTheme.Color.Bg),
			ColorSequenceKeypoint.new(1, HubTheme.Color.Bg),
		})
	end
	return stroke
end

table.freeze(HubTheme.Color)
table.freeze(HubTheme.ButtonPalette)

return HubTheme
