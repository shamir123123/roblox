--!strict
-- 1px separator line for toolbars and panels.

local Theme = require(script.Parent.Parent.Theme)

local Divider = {}

-- Fixed pixel length: scale-sized dividers balloon AutomaticSize containers.
function Divider.new(orientation: "Vertical" | "Horizontal", parent: Instance?, lengthPx: number?): Frame
	local f = Instance.new("Frame")
	f.Name = "Divider"
	f.BorderSizePixel = 0
	f.BackgroundColor3 = Theme.Color.StrokeSoft
	local len = lengthPx or 20
	if orientation == "Vertical" then
		f.Size = UDim2.fromOffset(1, len)
	else
		f.Size = UDim2.fromOffset(len, 1)
	end
	f.Parent = parent
	return f
end

return Divider
