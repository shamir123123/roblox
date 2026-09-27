--!strict
-- The one tween helper. All UI animation goes through here so timings stay
-- in Theme and two tweens never fight over the same property.

local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)

export type MotionKey = Theme.MotionKey

local UITween = {}

-- inst -> propName -> running tween. Weak keys so destroyed instances drop out.
local _active: { [Instance]: { [string]: Tween } } = setmetatable({}, { __mode = "k" }) :: any

function UITween.to(inst: Instance, motionKey: MotionKey, props: { [string]: any }): Tween
	local spec = Theme.Motion[motionKey]
	local info = TweenInfo.new(spec.time, spec.style, spec.direction)

	local byProp = _active[inst]
	if not byProp then
		byProp = {}
		_active[inst] = byProp
	end

	for name in props do
		local prior = byProp[name]
		if prior then
			prior:Cancel()
		end
	end

	local tween = TweenService:Create(inst, info, props)
	for name in props do
		byProp[name] = tween
	end

	tween.Completed:Once(function()
		local current = _active[inst]
		if not current then
			return
		end
		for name in props do
			if current[name] == tween then
				current[name] = nil
			end
		end
	end)

	tween:Play()
	return tween
end

function UITween.cancelAll(inst: Instance)
	local byProp = _active[inst]
	if not byProp then
		return
	end
	for _, tween in byProp do
		tween:Cancel()
	end
	_active[inst] = nil
end

return UITween
