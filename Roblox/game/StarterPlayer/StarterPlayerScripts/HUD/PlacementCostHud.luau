--!strict
-- PlacementCostHud
-- The tag that follows the cursor while placing a building or drawing a road: what it
-- costs, and -- when the spot is refused -- WHY, in red, beside the price. The road tool
-- has said why since it got world tags; buildings just went red and left the player
-- guessing, so both now answer the same question the same way.
-- showCost(amount, blockedReason) / hide(). Pure UI, no game state.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local PlacementCostHud = {}

local GREEN = Color3.fromRGB(120, 220, 140)
local RED = Color3.fromRGB(230, 110, 110)

local _gui: ScreenGui? = nil
local _label: TextLabel? = nil
local _conn: RBXScriptConnection? = nil

local function commaInt(n: number): string
	local neg = n < 0
	local s = tostring(math.abs(math.floor(n + 0.5)))
	local out = ""
	while #s > 3 do
		out = "," .. s:sub(#s - 2) .. out
		s = s:sub(1, #s - 3)
	end
	return (neg and "-" or "") .. s .. out
end

local function ensure()
	if _gui and _gui.Parent then return end
	local player = Players.LocalPlayer
	local pg = player:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "PlacementCostHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("Theme")).Layer.CostTag + 2
	gui.Enabled = false
	gui.Parent = pg

	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0, 0.5)
	label.Size = UDim2.fromOffset(0, 26)
	label.AutomaticSize = Enum.AutomaticSize.X
	label.BackgroundColor3 = Color3.fromRGB(18, 20, 24)
	label.BackgroundTransparency = 0.1
	label.TextColor3 = GREEN
	label.Font = Enum.Font.GothamBold
	label.TextSize = 15
	label.Text = ""
	label.Parent = gui
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8); pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = label
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = label
	local stroke = Instance.new("UIStroke"); stroke.Color = Color3.fromRGB(0, 0, 0); stroke.Transparency = 0.55; stroke.Parent = label

	_gui = gui
	_label = label
end

-- Show a money amount (e.g. 8000 -> "$8,000"), an optional neutral note beside it (the
-- length of the run being drawn, say) and/or the reason the spot is refused.
-- All nil hides the tag.
function PlacementCostHud.showCost(amount: number?, blocked: string?, note: string?)
	if not amount and not blocked and not note then
		PlacementCostHud.hide()
		return
	end
	ensure()
	local gui = _gui :: ScreenGui
	local label = _label :: TextLabel
	local price = if amount then "$" .. commaInt(amount) else ""
	if note then price = if amount then price .. "   \u{00B7}   " .. note else note end
	label.Text = if blocked
		then (if price ~= "" then price .. "   " else "") .. "\u{26A0} " .. blocked
		else price
	label.TextColor3 = if blocked then RED else GREEN
	gui.Enabled = true
	if not _conn then
		_conn = RunService.RenderStepped:Connect(function()
			if not _label then return end
			local m = UserInputService:GetMouseLocation()
			_label.Position = UDim2.fromOffset(m.X + 18, m.Y + 4)
		end)
	end
end

function PlacementCostHud.hide()
	if _gui then _gui.Enabled = false end
	if _conn then _conn:Disconnect(); _conn = nil end
end

return PlacementCostHud
