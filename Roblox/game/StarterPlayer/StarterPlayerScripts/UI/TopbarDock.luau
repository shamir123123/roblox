--!strict
-- The Roblox topbar band, expressed in a ScreenGui's own coordinate space.
-- Core Roblox chips ignore both HudScale and the GUI inset, so anything docked in
-- that row takes its geometry from GuiService.TopbarInset rather than guessing:
-- x0 = right edge of the core cluster, top/height = the CHIP, not the inset.
-- Library module: no lifecycle, no state.

local GuiService = game:GetService("GuiService")

local HudScale = require(script.Parent:WaitForChild("HudScale"))

local TopbarDock = {}

local GAP = 8 -- clearance from the core cluster, and between our own chips
local FALLBACK_BAND = 58 -- topbar not reported yet; never leave a chip sized 0

-- TopbarInset reserves more room than the core chips occupy: measured, a 44px
-- chip sits 12px down inside a 58px band. Fractions, so this holds at any
-- topbar scale. ponytail: measured off a screenshot; recheck if Roblox restyles
-- the topbar.
local CHIP = 44 / 58
local CHIP_TOP = 12 / 58

TopbarDock.Gap = GAP

-- Left edge of the i-th custom chip (0-based) in the row right of the core cluster.
function TopbarDock.slot(x0: number, h: number, i: number): number
	return x0 + GAP + i * (h + GAP)
end

-- fn(x0, top, height), all in the gui's own px. Runs now, and again whenever the
-- topbar inset or the HUD scale changes.
function TopbarDock.bind(gui: ScreenGui, fn: (number, number, number) -> ())
	local hs = HudScale.attach(gui)
	local function place()
		local gs = math.max(hs.Scale, 0.01)
		local inset = GuiService.TopbarInset
		local band = if inset.Height > 0 then inset.Height else FALLBACK_BAND
		local top = inset.Min.Y + band * CHIP_TOP - (if gui.IgnoreGuiInset then 0 else GuiService:GetGuiInset().Y)
		-- Rounded: UDim offsets are integers, so truncating here would cost a
		-- visible pixel once the gui scale multiplies it back up.
		fn(math.round(inset.Min.X / gs), math.round(top / gs), math.round(band * CHIP / gs))
	end
	place()
	hs:GetPropertyChangedSignal("Scale"):Connect(place)
	GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(place)
end

return TopbarDock
