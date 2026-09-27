--!strict
-- GridPicker
-- The placement grid's control: "Grid  1m 5m 10m Off". Mounted wherever something gets
-- placed (the service pages, the road snap menu); the Build rail's Snap flyout shows the
-- same four through EditorGizmos.presetsFor. Every copy lights from PlacementGrid, so a
-- size picked on one page shows on all of them.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlacementGrid = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlacementGrid"))
local uiFolder = script.Parent.Parent:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local Button = require(uiFolder:WaitForChild("Kit"):WaitForChild("Button"))

local GridPicker = {}

local CAPTION_W = 30
local GAP = 3

function GridPicker.new(parent: Instance, size: UDim2, layoutOrder: number?): Frame
	local row = Instance.new("Frame")
	row.Name = "GridPicker"
	row.BackgroundTransparency = 1
	row.Size = size
	row.LayoutOrder = layoutOrder or 0
	row.Parent = parent

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, GAP)
	list.Parent = row

	local caption = Instance.new("TextLabel")
	caption.BackgroundTransparency = 1
	caption.Size = UDim2.new(0, CAPTION_W, 1, 0)
	caption.Text = "Grid"
	caption.TextColor3 = Theme.Color.TextSecondary
	caption.TextSize = Theme.TextSize.XS
	caption.FontFace = Theme.Font.Label
	caption.TextXAlignment = Enum.TextXAlignment.Left
	caption.Parent = row

	-- The sizes, then Off (0), in the order the Build rail's row shows them.
	local options = table.clone(PlacementGrid.SIZES) :: { number }
	table.insert(options, 0)
	local each = (CAPTION_W + GAP * #options) / #options
	local btns: { [number]: Button.Button } = {}
	for i, m in options do
		btns[m] = Button.new({
			text = if m > 0 then m .. "m" else "Off",
			name = "Grid" .. m,
			parent = row,
			compact = true,
			layoutOrder = i,
			size = UDim2.new(1 / #options, -each, 1, 0),
			onClick = function()
				if m > 0 then PlacementGrid.setSize(m) else PlacementGrid.setEnabled(false) end
			end,
		})
	end

	local function refresh()
		local on = if PlacementGrid.isEnabled() then PlacementGrid.getSize() else 0
		for m, b in btns do b:SetSelected(m == on) end
	end
	-- ponytail: never disconnected -- dock pages are built once and live for the session.
	-- Keep the returned disconnect if a picker ever gets torn down.
	PlacementGrid.onChanged(refresh)
	refresh()
	return row
end

return GridPicker
