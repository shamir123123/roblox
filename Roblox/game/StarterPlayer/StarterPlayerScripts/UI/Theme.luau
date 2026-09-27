--!strict
-- Single source of truth for UI colors, typography, spacing, and motion.
-- Frozen: runtime mutation is a bug.

local function deepFreeze(t: { [any]: any }): { [any]: any }
	for _, v in t do
		if typeof(v) == "table" and not table.isfrozen(v) then
			deepFreeze(v)
		end
	end
	return table.freeze(t)
end

local MONTSERRAT = "rbxasset://fonts/families/Montserrat.json"
local MERRIWEATHER = "rbxasset://fonts/families/Merriweather.json"

local Theme = {
	-- "Modern & Clean" glass. Deep smoked panels behind bright white hairline
	-- strokes, thin geometric type (Montserrat), capsule buttons and circular
	-- icon chips. ONE cool powder-blue accent marks everything active,
	-- selected or branded. Semantic colours (money green, danger red, zone
	-- R/C/I, map overlays) are content, not chrome, and keep their own hues.
	Color = {
		-- Cool blue-grey, not neutral black: Cities: Skylines tints its whole
		-- chrome toward navy, which is what stops a dark HUD reading as a hole
		-- punched in the screen.
		Bg            = Color3.fromRGB(22, 23, 20),
		BgRaised      = Color3.fromRGB(38, 40, 34),
		BgHover       = Color3.fromRGB(54, 57, 48),
		BgPress       = Color3.fromRGB(15, 16, 14),
		-- Hairlines: bright near-white on hover/active, soft grey at rest.
		Stroke        = Color3.fromRGB(206, 200, 188),
		StrokeSoft    = Color3.fromRGB(104, 100, 92),
		-- Muted powder blue = primary / active / selected. Kept LOW-saturation on
		-- purpose: several toggles sit selected at once, and a vivid blue there
		-- reads as a wall of colour. Dark OnAccent text/icon on top.
		Accent        = Color3.fromRGB(240, 122, 47),
		AccentHover   = Color3.fromRGB(247, 145, 85),
		AccentPress   = Color3.fromRGB(232, 97, 31),
		OnAccent      = Color3.fromRGB(255, 246, 238),
		TextPrimary   = Color3.fromRGB(240, 234, 222),
		TextSecondary = Color3.fromRGB(163, 160, 150),
		TextDisabled  = Color3.fromRGB(104, 102, 95),
		Danger        = Color3.fromRGB(236, 98, 100),
		Positive      = Color3.fromRGB(108, 198, 118),
		-- Soft sky-blue brand mark / tab underline / section headings. A touch more
		-- chroma than Accent (it's thin lines and small caps, never a filled pill).
		Brand         = Color3.fromRGB(208, 160, 108),
		BrandDim      = Color3.fromRGB(150, 116, 80),
		Scrim         = Color3.fromRGB(6, 6, 5),
	},

	-- The accent as a vertical gradient, for the surfaces that read as a single
	-- lit control rather than a flat tint: the play/pause disc, a selected draw
	-- tool, the profile chip, the primary button on a dialog. Apply with a
	-- UIGradient at Rotation 90. Flat Color.Accent stays the default -- this is
	-- for the few elements the design treats as raised.
	AccentGradient = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(247, 145, 85)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(232, 97, 31)),
	}),

	Font = {
		Label   = Font.new(MONTSERRAT, Enum.FontWeight.Medium),
		Header  = Font.new(MONTSERRAT, Enum.FontWeight.SemiBold),
		Bold    = Font.new(MONTSERRAT, Enum.FontWeight.Bold),
		-- Big elegant display type (city name, panel titles).
		Display = Font.new(MONTSERRAT, Enum.FontWeight.Light),
		-- Warm serif for the one piece of display copy on the HUD: the city name.
		Serif   = Font.new(MERRIWEATHER, Enum.FontWeight.Bold),
	},

	TextSize = { XS = 12, SM = 14, MD = 16, LG = 20 },

	-- Tighter than before: CS2 corners are barely rounded. Capsules still ask
	-- for 999 explicitly.
	Radius = { SM = 6, MD = 10, LG = 16, Panel = 18, XL = 20 },

	StrokeWidth = { Thin = 1, Thick = 2 },

	Pad = { XS = 4, SM = 6, MD = 8, LG = 12, XL = 16 },

	
	Motion = {
		Hover   = { time = 0.10, style = Enum.EasingStyle.Quad,  direction = Enum.EasingDirection.Out },
		Press   = { time = 0.06, style = Enum.EasingStyle.Quad,  direction = Enum.EasingDirection.Out },
		Flyout  = { time = 0.22, style = Enum.EasingStyle.Quint, direction = Enum.EasingDirection.Out },
		Popover = { time = 0.14, style = Enum.EasingStyle.Quint, direction = Enum.EasingDirection.Out },
		Tooltip = { time = 0.12, style = Enum.EasingStyle.Quad,  direction = Enum.EasingDirection.Out },
		-- Modals settle with a soft Back overshoot (~280ms): the researched sweet
		-- spot for hero transitions -- deliberate, never sluggish.
		Modal   = { time = 0.28, style = Enum.EasingStyle.Back, direction = Enum.EasingDirection.Out },
	},

	TooltipDelay   = 0.4,
	ModalScaleFrom = 0.95,
	ScrimOpacity   = 0.45,

	-- Panel fill. Roblox can't blur UI, so a panel has exactly one job: be solid
	-- enough to read against anything behind it. CS2 panels are effectively
	-- opaque -- the world shows only as a hint at the edges.
	Glass = {
		-- The bright white hairline (the old signature) is gone: CS2 panels have
		-- no visible border, just a fill a shade lighter than the bar behind it.
		-- A white 1px edge on every surface is what read as "Roblox UI".
		-- Cities: Skylines panel: a FLAT dark slate surface, near-opaque, with the
		-- world barely reading through. What sells it is uniformity -- no texture,
		-- no scatter, no halo. The faint top sheen is the only modelling.
		-- Cooler and greener than before, and a good deal more see-through: the
		-- design's panels sit at 42-60% alpha over a blurred backdrop, and Kit.Frost
		-- supplies the blur. The UI-transparency setting adds up to 0.5 on top of
		-- this via Glass.setUserTransparency.
		Color = Color3.fromRGB(18, 24, 20),
		Transparency = 0.45,
		StrokeColor = Color3.fromRGB(86, 88, 78),
		StrokeTransparency = 0.7,
		SheenColor = Color3.fromRGB(30, 38, 32),
	},

	-- ZIndex, ordering siblings INSIDE a single ScreenGui.
	Z = { HUD = 10, Flyout = 20, Popover = 30, Tooltip = 40, Modal = 50 },

	-- DisplayOrder, ordering the ScreenGuis THEMSELVES. A different axis from Z above --
	-- two guis that share a DisplayOrder have undefined draw order, so which one wins can
	-- differ per client. Every gui therefore gets its own number inside a named band.
	-- Bands leave room to insert without renumbering.
	Layer = {
		Tool = 100, -- tool pills/panels flanking the HUD
		HUD = 200, -- CityUI
		Screen = 250, -- full-screen modes (main menu): above the HUD, below every overlay.
		-- Deliberately NOT up with Menu: the menu is a backdrop that other surfaces open on
		-- top of (update logs, credits, settings, the creation editor, the radio bar), and
		-- putting it in the 700s buried all of them.
		Overlay = 300, -- creation editor, move-it panel
		WorldTag = 400, -- hover cards, marquee, radio bar
		Toast = 500, -- notifications, terrain tool HUD
		CostTag = 600, -- cursor-following cost tags, veils, transit status
		Menu = 700, -- full-screen menus
		Modal = 800, -- blocking dialogs: above toasts, which they must not be buried by
		Tooltip = 900, -- above modals, so a dialog's own controls can still hint
		Fade = 950, -- transition fades: cover everything except dev tooling
		Dev = 1000, -- staff + developer overlays
	},
}

export type MotionSpec = { time: number, style: Enum.EasingStyle, direction: Enum.EasingDirection }
export type MotionKey = "Hover" | "Press" | "Flyout" | "Popover" | "Tooltip" | "Modal"

deepFreeze(Theme)

return Theme
