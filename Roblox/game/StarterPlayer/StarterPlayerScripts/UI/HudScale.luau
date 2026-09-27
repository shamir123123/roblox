--!strict
-- One global UIScale for the whole in-game HUD (CityUI). The HUD is designed
-- on a 1366x768 canvas; on smaller viewports every fixed-px surface scales
-- down together so nothing overlaps. Scale-relative elements (the full-width
-- bottom bar) keep spanning the screen. Library module: no lifecycle.
--
-- NOTE for placement code: with the scale active, GuiObject Position offsets
-- are in DESIGN px while AbsolutePosition/AbsoluteSize are REAL px. Divide
-- real-px results by HudScale.get(gui) before writing them into offsets.

local HudScale = {}

local DESIGN_W = 1366
local DESIGN_H = 768

-- User multiplier (Settings > Interface > HUD scale). Module-level so every
-- attached gui re-fits together.
local _userScale = 1
local _fits: { () -> () } = {}

-- Idempotent: safe to call from every controller that touches CityUI.
function HudScale.attach(gui: ScreenGui): UIScale
	local existing = gui:FindFirstChild("HudScale")
	if existing and existing:IsA("UIScale") then
		return existing
	end
	local scale = Instance.new("UIScale")
	scale.Name = "HudScale"
	local function fit()
		local vp = gui.AbsoluteSize
		if vp.X <= 0 or vp.Y <= 0 then return end
		scale.Scale = math.min(1, vp.X / DESIGN_W, vp.Y / DESIGN_H) * _userScale
	end
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	table.insert(_fits, fit)
	fit()
	scale.Parent = gui
	return scale
end

-- Pin a CityUI element to REAL pixel size (for chips aligned with the core
-- Roblox topbar row, which ignores HudScale). Adds a compensating UIScale
-- inside `obj` and re-runs `place(gs)` whenever the global scale changes.
function HudScale.exempt(gui: ScreenGui, obj: GuiObject, place: (gs: number) -> ())
	local hs = HudScale.attach(gui)
	local comp = Instance.new("UIScale")
	comp.Name = "HudScaleExempt"
	comp.Parent = obj
	local function apply()
		local gs = math.max(hs.Scale, 0.01)
		comp.Scale = 1 / gs
		place(gs)
	end
	hs:GetPropertyChangedSignal("Scale"):Connect(apply)
	apply()
end

function HudScale.setUserScale(mult: number)
	_userScale = math.clamp(mult, 0.7, 1.3)
	for _, fit in _fits do
		fit()
	end
end

function HudScale.get(gui: GuiBase2d): number
	local s = gui:FindFirstChild("HudScale")
	return if s and s:IsA("UIScale") then s.Scale else 1
end

return HudScale
