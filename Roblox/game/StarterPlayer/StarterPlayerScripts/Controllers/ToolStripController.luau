--!strict
-- Contextual tool options strip above the bottom bar. Shows the row for the
-- active build section (Roads / Zoning); road snap toggles live in a popover.
-- Replaces RoadToolBarController, SnapToolBarController, ZoningToolBarController.

local uiFolder = script.Parent.Parent:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local UITween = require(uiFolder:WaitForChild("UITween"))
local Icons = require(uiFolder:WaitForChild("Icons"))
local kit = uiFolder:WaitForChild("Kit")
local Button = require(kit:WaitForChild("Button"))
local IconButton = require(kit:WaitForChild("IconButton"))
local Divider = require(kit:WaitForChild("Divider"))
local Popover = require(kit:WaitForChild("Popover"))
local Glass = require(kit:WaitForChild("Glass"))

export type Section = "Roads" | "Zoning"

local ToolStripController = {}

local STRIP_H = 38
local ROW_H = 26

local _road: any = nil
local _zoning: any = nil
local _strip: CanvasGroup? = nil
local _roadsRow: Frame? = nil
local _zoningRow: Frame? = nil
local _snapPopover: Popover.Popover? = nil
local _heightPopover: Popover.Popover? = nil
local _section: Section? = nil
local _isErasing = false
local _shownOffset = 0

local _roadButtons: { [string]: any } = {}
local _zoneButtons: { [string]: Button.Button } = {}
local _snapButtons: { [string]: Button.Button } = {}
local _elevationLabel: TextLabel? = nil
local _radiusLabel: TextLabel? = nil
-- Burgage plot size steppers (width / depth in metres) shown on the Zoning row.
local _zoneWidthLabel: TextLabel? = nil
local _zoneDepthLabel: TextLabel? = nil

local function makeValueLabel(parent: Instance, order: number, width: number): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.FontFace = Theme.Font.Header
	label.TextSize = Theme.TextSize.XS
	label.TextColor3 = Theme.Color.TextPrimary
	label.Size = UDim2.fromOffset(width, ROW_H)
	label.LayoutOrder = order
	label.Text = ""
	label.Parent = parent
	return label
end

local function makeRow(parent: Instance, name: string): Frame
	local row = Instance.new("Frame")
	row.Name = name
	row.BackgroundTransparency = 1
	row.AutomaticSize = Enum.AutomaticSize.X
	row.Size = UDim2.fromOffset(0, ROW_H)
	row.Visible = false
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, Theme.Pad.XS)
	list.Parent = row
	row.Parent = parent
	return row
end

function ToolStripController.Refresh()
	if _road and _section == "Roads" then
		local mode = _road.getMode()
		local editMode = if _road.getEditMode then _road.getEditMode() else "None"
		local isUpgrade = editMode == "UpgradeReplace"
		local isDelete = editMode == "Delete"
		local isEdit = isUpgrade or isDelete

		local modeSelected = {
			Straight = not isEdit and mode == "Straight",
			Curved = not isEdit and mode == "Curved",
			Freeform = not isEdit and mode == "Freeform",
			AdvancedCurve = not isEdit and mode == "AdvancedCurve",
			Roundabout = not isEdit and mode == "Roundabout",
			Upgrade = isUpgrade,
			Delete = isDelete,
			Parallel = _road.isParallelModeEnabled(),
		}
		for key, btn in _roadButtons do
			local sel = modeSelected[key]
			if sel ~= nil then
				btn:SetSelected(sel)
			end
		end

		if _roadButtons.RoundaboutSize then
			local inst = _roadButtons.RoundaboutSize.Instance
			inst.Visible = modeSelected.Roundabout == true
			if _road.getRoundaboutSize then
				inst.Text = "Size: " .. string.sub(_road.getRoundaboutSize(), 1, 1)
			end
		end

		local vmode = if _road.getVerticalMode then _road.getVerticalMode() else "Ground"
		-- Auto and the three manual modes are one choice, so exactly one of the four lights up.
		-- While Auto is on the manual buttons show unselected even though getVerticalMode still
		-- reports Ground: what the road will be BUILT as is not decided until it is placed.
		local auto = if _road.isAutoVertical then _road.isAutoVertical() else false
		if _roadButtons.Auto then _roadButtons.Auto:SetSelected(auto) end
		if _roadButtons.Ground then _roadButtons.Ground:SetSelected(not auto and vmode == "Ground") end
		if _roadButtons.Elevated then _roadButtons.Elevated:SetSelected(not auto and vmode == "Elevated") end
		if _roadButtons.Tunnel then _roadButtons.Tunnel:SetSelected(not auto and vmode == "Tunnel") end
		if _roadButtons.Slope then _roadButtons.Slope:SetSelected(_road.isConstantSlope ~= nil and _road.isConstantSlope() == true) end

		if _elevationLabel then
			local elevation = math.round(if _road.getElevation then _road.getElevation() else 0)
			_elevationLabel.Text = if elevation > 0 then "+" .. tostring(elevation)
				elseif elevation < 0 then tostring(elevation)
				else "0"
		end

		_snapButtons.Road:SetSelected(_road.isRoadSnapEnabled())
		_snapButtons.Guide:SetSelected(_road.isGuideEnabled())
		_snapButtons.Grid:SetSelected(_road.isGridEnabled())
		_snapButtons.Angle:SetSelected(_road.isAngleSnapEnabled())
	end

	if _zoning and _section == "Zoning" then
		local mode = if _zoning.getMode then _zoning.getMode() else "Line"
		if _zoneButtons.Line then _zoneButtons.Line:SetSelected(not _isErasing and mode == "Line") end
		if _zoneButtons.Area then _zoneButtons.Area:SetSelected(not _isErasing and mode == "Area") end
		if _zoneButtons.Single then _zoneButtons.Single:SetSelected(not _isErasing and mode == "Single") end
		if _zoneWidthLabel and _zoning.getWidthBlocks then
			_zoneWidthLabel.Text = tostring(_zoning.getWidthBlocks())
		end
		if _zoneDepthLabel and _zoning.getDepthBlocks then
			_zoneDepthLabel.Text = tostring(_zoning.getDepthBlocks())
		end
		if _zoneButtons.SizeMode and _zoning.getSizeMode then
			_zoneButtons.SizeMode.Instance.Text = if _zoning.getSizeMode() == "Uniform" then "Sizes: Exact W" else "Sizes: Mixed"
		end
		if _zoneButtons.Mirror and _zoning.getMirror then
			_zoneButtons.Mirror:SetSelected(_zoning.getMirror())
		end
		if _zoneButtons.Erase then _zoneButtons.Erase:SetSelected(_isErasing) end
	end
end

function ToolStripController.SetErasing(erasing: boolean)
	if _isErasing == erasing then
		return
	end
	_isErasing = erasing
	if _zoning then
		if erasing then
			_zoning.setActiveZone("None")
		else
			_zoning.setActiveZone(if _zoning.getLastZone then _zoning.getLastZone() else "Residential")
		end
	end
	ToolStripController.Refresh()
end

function ToolStripController.IsErasing(): boolean
	return _isErasing
end

local function buildRoadsRow(strip: CanvasGroup, parentGui: GuiBase2d)
	local row = makeRow(strip, "RoadsRow")
	_roadsRow = row

	local function modeButton(order: number, label: string, modeKey: string, icon: any)
		_roadButtons[modeKey] = IconButton.new({
			icon = icon,
			name = label,
			tooltip = label,
			parent = row,
			size = ROW_H,
			layoutOrder = order,
			onClick = function()
				_road.setMode(modeKey)
				_road.setEditMode("None")
				ToolStripController.Refresh()
			end,
		})
	end

	modeButton(1, "Line", "Straight", Icons.RoadStraight)
	modeButton(2, "Curve", "Curved", Icons.RoadCurved)
	modeButton(3, "Freeform", "Freeform", Icons.RoadFreeform)
	modeButton(4, "Bezier", "AdvancedCurve", Icons.RoadBezier)
	modeButton(5, "Roundabout", "Roundabout", Icons.RoadRoundabout)

	-- Roundabout size preset (Small/Medium/Large). Shown only while the roundabout
	-- tool is active; cycles on click, label kept current in Refresh(). Shares
	-- layoutOrder 5 with the Roundabout button: the Name tie-break slots it after.
	_roadButtons.RoundaboutSize = Button.new({
		text = "Size: M",
		parent = row,
		size = UDim2.fromOffset(72, ROW_H),
		layoutOrder = 5,
		onClick = function()
			_road.cycleRoundaboutSize()
			ToolStripController.Refresh()
		end,
	})
	_roadButtons.RoundaboutSize.Instance.Name = "RoundaboutSize"
	_roadButtons.RoundaboutSize.Instance.Visible = false

	Divider.new("Vertical", row).LayoutOrder = 6

	_roadButtons.Upgrade = IconButton.new({
		icon = Icons.RoadUpgrade,
		name = "Upgrade",
		tooltip = "Upgrade",
		parent = row,
		size = ROW_H,
		layoutOrder = 7,
		onClick = function()
			local editMode = if _road.getEditMode then _road.getEditMode() else "None"
			_road.setEditMode(if editMode == "UpgradeReplace" then "None" else "UpgradeReplace")
			ToolStripController.Refresh()
		end,
	})

	-- Road deletion moved to the top-level Bulldoze tool (BulldozeController), which
	-- also reaches buildings. Upgrade stays here as a road-only edit.

	Divider.new("Vertical", row).LayoutOrder = 9

	_roadButtons.Parallel = IconButton.new({
		icon = Icons.RoadParallel,
		name = "Parallel",
		tooltip = "Parallel roads",
		parent = row,
		size = ROW_H,
		layoutOrder = 10,
		onClick = function()
			_road.setParallelModeEnabled(not _road.isParallelModeEnabled())
			ToolStripController.Refresh()
		end,
	})
	-- Parallel mode: toggled here, offsets each drawn curve off the nearest road (Snapper.maybeParallelize).

	Divider.new("Vertical", row).LayoutOrder = 11

	_roadButtons.Undo = IconButton.new({
		icon = Icons.Undo,
		name = "Undo",
		tooltip = "Undo",
		parent = row,
		size = ROW_H,
		layoutOrder = 12,
		onClick = function()
			_road.undo()
		end,
	})
	_roadButtons.Redo = IconButton.new({
		icon = Icons.Redo,
		name = "Redo",
		tooltip = "Redo",
		parent = row,
		size = ROW_H,
		layoutOrder = 13,
		onClick = function()
			_road.redo()
		end,
	})

	Divider.new("Vertical", row).LayoutOrder = 14

	-- Height: vertical mode (Ground/Elevated/Tunnel), constant-slope toggle and the
	-- elevation stepper all live in a popover, so the strip stays short.
	local heightBtn = IconButton.new({
		icon = Icons.Height,
		name = "HeightMenu",
		tooltip = "Height",
		parent = row,
		size = ROW_H,
		layoutOrder = 15,
	})
	_roadButtons.HeightMenu = heightBtn

	local heightPopover = Popover.new({
		anchor = heightBtn.Instance,
		parent = parentGui,
		size = UDim2.fromOffset(150, 6 * 26 + 5 * Theme.Pad.SM + 2 * Theme.Pad.MD),
		name = "HeightPopover",
		onOpenChanged = function(open: boolean)
			heightBtn:SetSelected(open)
		end,
	})
	_heightPopover = heightPopover

	local heightList = Instance.new("UIListLayout")
	heightList.FillDirection = Enum.FillDirection.Vertical
	heightList.HorizontalAlignment = Enum.HorizontalAlignment.Center
	heightList.SortOrder = Enum.SortOrder.LayoutOrder
	heightList.Padding = UDim.new(0, Theme.Pad.SM)
	heightList.Parent = heightPopover.Frame

	-- AUTO first, because it is the one that should usually be on: the road decides for
	-- itself whether a span sits on the ground, is held up over a dip or bores through a rise,
	-- from the terrain it actually crosses. The three below are the manual override.
	_roadButtons.Auto = Button.new({
		text = "Auto",
		parent = heightPopover.Frame,
		size = UDim2.new(1, 0, 0, 26),
		layoutOrder = 1,
		onClick = function()
			if _road.setAutoVertical then _road.setAutoVertical(true) end
			ToolStripController.Refresh()
		end,
	})

	local function vModeButton(order: number, label: string, modeKey: string)
		_roadButtons[modeKey] = Button.new({
			text = label,
			parent = heightPopover.Frame,
			size = UDim2.new(1, 0, 0, 26),
			layoutOrder = order,
			onClick = function()
				-- Picking a mode by hand is the player overriding Auto, so it has to go off --
				-- left on, it would keep deciding and the button would look stuck.
				if _road.setAutoVertical then _road.setAutoVertical(false) end
				_road.setVerticalMode(modeKey)
				ToolStripController.Refresh()
			end,
		})
	end
	vModeButton(2, "Ground", "Ground")
	vModeButton(3, "Elevated", "Elevated")
	vModeButton(4, "Tunnel", "Tunnel")

	_roadButtons.Slope = Button.new({
		text = "Constant Slope",
		parent = heightPopover.Frame,
		size = UDim2.new(1, 0, 0, 26),
		layoutOrder = 5,
		onClick = function()
			_road.setConstantSlope(not _road.isConstantSlope())
			ToolStripController.Refresh()
		end,
	})

	-- Elevation stepper row inside the popover: [-] value [+].
	local stepRow = Instance.new("Frame")
	stepRow.Name = "ElevStep"
	stepRow.BackgroundTransparency = 1
	stepRow.Size = UDim2.new(1, 0, 0, 26)
	stepRow.LayoutOrder = 6
	stepRow.Parent = heightPopover.Frame
	local stepList = Instance.new("UIListLayout")
	stepList.FillDirection = Enum.FillDirection.Horizontal
	stepList.HorizontalAlignment = Enum.HorizontalAlignment.Center
	stepList.VerticalAlignment = Enum.VerticalAlignment.Center
	stepList.SortOrder = Enum.SortOrder.LayoutOrder
	stepList.Padding = UDim.new(0, Theme.Pad.SM)
	stepList.Parent = stepRow

	Button.new({
		text = "\u{2212}",
		name = "ElevDown",
		parent = stepRow,
		size = UDim2.fromOffset(28, 26),
		layoutOrder = 1,
		onClick = function()
			_road.adjustElevation(-1)
			ToolStripController.Refresh()
		end,
	})
	local elevLabel = makeValueLabel(stepRow, 2, 40)
	elevLabel.Name = "ElevationValue"
	elevLabel.TextXAlignment = Enum.TextXAlignment.Center
	_elevationLabel = elevLabel
	Button.new({
		text = "+",
		name = "ElevUp",
		parent = stepRow,
		size = UDim2.fromOffset(28, 26),
		layoutOrder = 3,
		onClick = function()
			_road.adjustElevation(1)
			ToolStripController.Refresh()
		end,
	})

	heightBtn.Instance.Activated:Connect(function()
		heightPopover:Toggle()
	end)

	Divider.new("Vertical", row).LayoutOrder = 23

	local snapBtn = IconButton.new({
		icon = Icons.Snap,
		name = "SnapMenu",
		tooltip = "Snap options",
		parent = row,
		size = ROW_H,
		layoutOrder = 24,
	})
	_roadButtons.SnapMenu = snapBtn

	local popover = Popover.new({
		anchor = snapBtn.Instance,
		parent = parentGui,
		size = UDim2.fromOffset(140, 4 * 26 + 3 * Theme.Pad.SM + 2 * Theme.Pad.MD),
		name = "SnapPopover",
		onOpenChanged = function(open: boolean)
			snapBtn:SetSelected(open)
		end,
	})
	_snapPopover = popover

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, Theme.Pad.SM)
	list.Parent = popover.Frame

	local function snapToggle(order: number, label: string, key: string, isOn: () -> boolean, setOn: (boolean) -> ())
		_snapButtons[key] = Button.new({
			text = label,
			parent = popover.Frame,
			size = UDim2.new(1, 0, 0, 26),
			layoutOrder = order,
			onClick = function()
				setOn(not isOn())
				ToolStripController.Refresh()
			end,
		})
	end

	snapToggle(1, "Road Snap", "Road", function()
		return _road.isRoadSnapEnabled()
	end, function(on)
		_road.setRoadSnapEnabled(on)
	end)
	snapToggle(2, "Guide", "Guide", function()
		return _road.isGuideEnabled()
	end, function(on)
		_road.setGuideEnabled(on)
	end)
	snapToggle(3, "Grid", "Grid", function()
		return _road.isGridEnabled()
	end, function(on)
		_road.setGridEnabled(on)
	end)
	snapToggle(4, "Angle", "Angle", function()
		return _road.isAngleSnapEnabled()
	end, function(on)
		_road.setAngleSnapEnabled(on)
	end)

	snapBtn.Instance.Activated:Connect(function()
		popover:Toggle()
	end)
end

local function buildZoningRow(strip: CanvasGroup)
	local row = makeRow(strip, "ZoningRow")
	_zoningRow = row

	-- Burgage plot size in BLOCKS (2\u{00D7}2 .. 5\u{00D7}6) the plot tool stamps / zones with.
	local function stepper(order: number, tag: string, get: () -> number, set: (number) -> ()): TextLabel
		local wrap = Instance.new("Frame")
		wrap.BackgroundTransparency = 1
		wrap.AutomaticSize = Enum.AutomaticSize.X
		wrap.Size = UDim2.fromOffset(0, ROW_H)
		wrap.LayoutOrder = order
		local l = Instance.new("UIListLayout")
		l.FillDirection = Enum.FillDirection.Horizontal
		l.VerticalAlignment = Enum.VerticalAlignment.Center
		l.SortOrder = Enum.SortOrder.LayoutOrder
		l.Padding = UDim.new(0, Theme.Pad.XS)
		l.Parent = wrap
		local cap = makeValueLabel(wrap, 1, 16)
		cap.Text = tag
		cap.TextColor3 = Theme.Color.TextSecondary
		Button.new({ text = "\u{2212}", parent = wrap, size = UDim2.fromOffset(24, ROW_H), layoutOrder = 2,
			onClick = function() set(get() - 1); ToolStripController.Refresh() end })
		local val = makeValueLabel(wrap, 3, 34)
		val.TextXAlignment = Enum.TextXAlignment.Center
		Button.new({ text = "+", parent = wrap, size = UDim2.fromOffset(24, ROW_H), layoutOrder = 4,
			onClick = function() set(get() + 1); ToolStripController.Refresh() end })
		wrap.Parent = row
		return val
	end

	-- Line = drag plots along the road frontage; Area = drag a box out from the road to set depth.
	local function modeBtn(order: number, label: string, key: string)
		_zoneButtons[key] = Button.new({
			text = label, parent = row, compact = true, layoutOrder = order,
			onClick = function() if _zoning.setMode then _zoning.setMode(key) end; ToolStripController.Refresh() end,
		})
	end
	modeBtn(0, "Line", "Line")
	modeBtn(1, "Area", "Area")
	modeBtn(2, "Single", "Single")
	Divider.new("Vertical", row).LayoutOrder = 3

	_zoneWidthLabel = stepper(4, "W", function() return _zoning.getWidthBlocks() end, function(v) _zoning.setWidthBlocks(v) end)
	_zoneDepthLabel = stepper(5, "D", function() return _zoning.getDepthBlocks() end, function(v) _zoning.setDepthBlocks(v) end)

	-- Building-size choice: Mixed = whatever 2..5-lot buildings fit; Exact = only exactly-W buildings.
	_zoneButtons.SizeMode = Button.new({
		text = "Sizes: Mixed", parent = row, compact = true, layoutOrder = 6,
		onClick = function()
			if _zoning.setSizeMode and _zoning.getSizeMode then
				_zoning.setSizeMode(if _zoning.getSizeMode() == "Uniform" then "Mixed" else "Uniform")
			end
			ToolStripController.Refresh()
		end,
	})

	-- Mirror: the same plots land on BOTH sides of the road in one drag / click.
	_zoneButtons.Mirror = Button.new({
		text = "Mirror", parent = row, compact = true, layoutOrder = 7,
		onClick = function()
			if _zoning.setMirror and _zoning.getMirror then
				_zoning.setMirror(not _zoning.getMirror())
			end
			ToolStripController.Refresh()
		end,
	})

	Divider.new("Vertical", row).LayoutOrder = 8

	_zoneButtons.Erase = Button.new({
		text = "Erase",
		parent = row,
		variant = "Danger",
		compact = true,
		layoutOrder = 9,
		onClick = function()
			ToolStripController.SetErasing(not _isErasing)
		end,
	})
end

function ToolStripController.Init(deps: { parent: GuiBase2d, road: any, zoning: any, bottomOffset: number })
	_road = deps.road
	_zoning = deps.zoning
	_shownOffset = deps.bottomOffset

	local strip = Instance.new("CanvasGroup")
	strip.Name = "ToolStrip"
	strip.AnchorPoint = Vector2.new(0.5, 1)
	strip.Position = UDim2.new(0.5, 0, 1, _shownOffset)
	strip.AutomaticSize = Enum.AutomaticSize.X
	strip.Size = UDim2.fromOffset(0, STRIP_H)
	strip.GroupTransparency = 1
	strip.Visible = false
	strip.ZIndex = Theme.Z.HUD
	Glass.apply(strip)

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, Theme.Pad.SM)
	padding.PaddingBottom = UDim.new(0, Theme.Pad.SM)
	padding.PaddingLeft = UDim.new(0, Theme.Pad.SM)
	padding.PaddingRight = UDim.new(0, Theme.Pad.SM)
	padding.Parent = strip

	strip.Parent = deps.parent
	_strip = strip

	buildRoadsRow(strip, deps.parent)
	buildZoningRow(strip)
end

-- The strip and the build dock are both centred above the rail, so whichever
-- sits lower has to be measured rather than assumed. The caller pushes a new
-- offset whenever the dock opens, closes or changes page.
function ToolStripController.SetBottomOffset(offset: number)
	if _shownOffset == offset then
		return
	end
	_shownOffset = offset
	local strip = _strip
	if strip and strip.Visible and _section then
		UITween.to(strip, "Flyout", { Position = UDim2.new(0.5, 0, 1, _shownOffset) })
	end
end

function ToolStripController.SetSection(section: Section?)
	local strip = _strip
	if not strip then
		return
	end

	_section = section

	if _snapPopover then
		_snapPopover:Hide()
	end
	if _heightPopover then
		_heightPopover:Hide()
	end

	if section then
		if _roadsRow then
			_roadsRow.Visible = section == "Roads"
		end
		if _zoningRow then
			_zoningRow.Visible = section == "Zoning"
		end
		ToolStripController.Refresh()
		strip.Visible = true
		strip.Position = UDim2.new(0.5, 0, 1, _shownOffset + 16)
		UITween.to(strip, "Flyout", {
			GroupTransparency = 0,
			Position = UDim2.new(0.5, 0, 1, _shownOffset),
		})
	else
		local tween = UITween.to(strip, "Flyout", {
			GroupTransparency = 1,
			Position = UDim2.new(0.5, 0, 1, _shownOffset + 16),
		})
		tween.Completed:Once(function()
			if not _section then
				strip.Visible = false
			end
		end)
	end
end

function ToolStripController.GetSection(): Section?
	return _section
end

function ToolStripController.Cleanup()
	for _, btn in _roadButtons do
		btn:Destroy()
	end
	for _, btn in _zoneButtons do
		btn:Destroy()
	end
	for _, btn in _snapButtons do
		btn:Destroy()
	end
	table.clear(_roadButtons)
	table.clear(_zoneButtons)
	table.clear(_snapButtons)
	if _snapPopover then
		_snapPopover:Destroy()
		_snapPopover = nil
	end
	if _heightPopover then
		_heightPopover:Destroy()
		_heightPopover = nil
	end
	if _strip then
		_strip:Destroy()
		_strip = nil
	end
	_section = nil
end

return ToolStripController
