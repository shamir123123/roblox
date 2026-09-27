--!strict
-- Panel chrome: flat dark translucent bg, hairline stroke, soft top sheen, and
-- a Kit.Frost pane that blurs the world behind the panel's screen rect. Every
-- glass surface in the game frosts through this one entry.
--
-- The panel fill stands on its own -- frost is a player setting and plenty of
-- machines can't render it -- so the fill must never depend on the blur.

local Theme = require(script.Parent.Parent.Theme)
local Frost = require(script.Parent.Frost)

local Glass = {}

-- Every applied pane, so the UI-transparency setting can repaint them all. Weak
-- keys: a destroyed panel drops out on its own, no cleanup call to forget.
local _panes: { [GuiObject]: true } = setmetatable({}, { __mode = "k" }) :: any
local _extra = 0 -- 0 = the designed look; higher = more see-through

local function paint(frame: GuiObject)
	frame.BackgroundTransparency = math.clamp(Theme.Glass.Transparency + _extra, 0, 1)
end

-- 0..0.5 of extra transparency on top of the theme value.
function Glass.setUserTransparency(extra: number)
	_extra = math.clamp(tonumber(extra) or 0, 0, 0.5)
	for frame in _panes do
		if frame.Parent then
			paint(frame)
		end
	end
end

function Glass.apply(frame: GuiObject, radius: number?): UIStroke
	local r = radius or Theme.Radius.MD
	frame.BackgroundColor3 = Theme.Glass.Color
	_panes[frame] = true
	paint(frame)
	frame.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, r)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Glass.StrokeColor
	stroke.Thickness = Theme.StrokeWidth.Thin
	stroke.Transparency = Theme.Glass.StrokeTransparency
	stroke.Parent = frame

	-- A UIGradient on a CanvasGroup multiplies the whole composited content
	-- (children go black), so the sheen only goes on plain frames.
	if not frame:IsA("CanvasGroup") then
		local grad = Instance.new("UIGradient")
		grad.Rotation = 90
		grad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Theme.Glass.SheenColor),
			ColorSequenceKeypoint.new(0.3, Theme.Glass.Color),
			ColorSequenceKeypoint.new(1, Theme.Glass.Color),
		})
		grad.Parent = frame
	end

	Frost.attach(frame, r)

	return stroke
end

return Glass
