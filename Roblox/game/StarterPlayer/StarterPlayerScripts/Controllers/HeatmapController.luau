--!strict
-- INFO VIEWS: the bottom-left column. Pick a service to paint the whole city
-- green/red by coverage (CoverageOverlay "heat" style); pick it again to clear.
--
-- Was an eye button that opened a 5-wide grid floating beside it -- two clicks
-- to reach any view, and a panel that overlapped whatever was behind it. The
-- column is permanent instead: one click per view, and it grows upward from the
-- bottom edge, so adding a ninth overlay costs no layout thought.
--
-- Anchored bottom-left with AutomaticSize.Y, which is what makes it grow up
-- rather than down. Icon-only by design: eight labels stacked vertically would
-- be a wall of text down the edge of the screen, so the names are tooltips.

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

local CoverageOverlay = require(script.Parent:WaitForChild("CoverageOverlay"))
local uiFolder = script.Parent.Parent:WaitForChild("UI")
local kitFolder = uiFolder:WaitForChild("Kit")
local Theme = require(uiFolder:WaitForChild("Theme"))
local Icons = require(uiFolder:WaitForChild("Icons"))
local HudScale = require(uiFolder:WaitForChild("HudScale"))
local Glass = require(kitFolder:WaitForChild("Glass"))
local IconButton = require(kitFolder:WaitForChild("IconButton"))
local Divider = require(kitFolder:WaitForChild("Divider"))

local HeatmapController = {}

-- Grouped by category; a divider sits between the groups. label is the tooltip.
local GROUPS: { { { kind: string, label: string, icon: Icons.Icon } } } = {
	{
		{ kind = "Police",    label = "Police coverage",    icon = Icons.ViewPolice },
		{ kind = "Fire",      label = "Fire coverage",      icon = Icons.ViewFire },
		{ kind = "Hospital",  label = "Health coverage",    icon = Icons.ViewHealth },
		{ kind = "Education", label = "Education coverage", icon = Icons.ViewEducation },
		{ kind = "Deathcare", label = "Deathcare coverage", icon = Icons.ViewDeathcare },
	},
	{
		{ kind = "Power",  label = "Power grid",    icon = Icons.ViewPower },
		{ kind = "Water",  label = "Water supply",  icon = Icons.ViewWater },
		{ kind = "Sewage", label = "Sewage",        icon = Icons.ViewSewage },
	},
}

local ICON = 38
local GAP = 4
local PAD = 6
local EDGE = 10
local REFRESH_PERIOD = 0.5

local _started = false
local _buttons: { [string]: IconButton.IconButton } = {}
local _root: Frame? = nil
local _hbConn: RBXScriptConnection? = nil
local _accum = 0

local function syncSelection()
	local active = if CoverageOverlay.activeStyle() == "heat" then CoverageOverlay.activeKind() else nil
	for kind, ib in _buttons do
		ib:SetSelected(kind == active)
	end
end

function HeatmapController.Start()
	if _started then return end
	_started = true

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = playerGui:WaitForChild("CityUI", 60)
	if not gui or not gui:IsA("ScreenGui") then
		warn("[HeatmapController] CityUI not found - aborting")
		_started = false
		return
	end
	HudScale.attach(gui)

	-- Bottom-anchored + AutomaticSize.Y: the column extends upward from the
	-- bottom edge as entries are added, so nothing has to be re-measured when
	-- the overlay list changes.
	local root = Instance.new("Frame")
	root.Name = "InfoViews"
	root.AnchorPoint = Vector2.new(0, 1)
	root.Position = UDim2.new(0, EDGE, 1, -EDGE)
	root.Size = UDim2.fromOffset(ICON + PAD * 2, 0)
	root.AutomaticSize = Enum.AutomaticSize.Y
	root.ZIndex = Theme.Z.HUD
	Glass.apply(root, Theme.Radius.XL)
	root.Parent = gui
	_root = root

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, PAD)
	pad.PaddingBottom = UDim.new(0, PAD)
	pad.PaddingLeft = UDim.new(0, PAD)
	pad.PaddingRight = UDim.new(0, PAD)
	pad.Parent = root

	local col = Instance.new("UIListLayout")
	col.FillDirection = Enum.FillDirection.Vertical
	col.HorizontalAlignment = Enum.HorizontalAlignment.Center
	col.SortOrder = Enum.SortOrder.LayoutOrder
	col.Padding = UDim.new(0, GAP)
	col.Parent = root

	local order = 0
	for gi, group in GROUPS do
		if gi > 1 then
			order += 1
			Divider.new("Horizontal", root, ICON).LayoutOrder = order
		end
		for _, def in group do
			order += 1
			local kind = def.kind
			_buttons[kind] = IconButton.new({
				icon = def.icon,
				tooltip = def.label,
				size = ICON,
				colored = true,
				layoutOrder = order,
				parent = root,
				onClick = function()
					-- Same view again clears it, so the column needs no separate
					-- "off" control.
					if CoverageOverlay.activeKind() == kind and CoverageOverlay.activeStyle() == "heat" then
						CoverageOverlay.clear()
					else
						CoverageOverlay.show(kind, "heat")
					end
					syncSelection()
				end,
			})
		end
	end

	-- Slow upkeep: rescan while a heatmap is on, and re-sync the lit state (a
	-- placement tool shares the overlay and can take it over).
	_hbConn = RunService.Heartbeat:Connect(function(dt: number)
		_accum += dt
		if _accum < REFRESH_PERIOD then return end
		_accum = 0
		if CoverageOverlay.activeStyle() == "heat" then
			CoverageOverlay.maybeRefresh()
		end
		syncSelection()
	end)
end

function HeatmapController.Cleanup()
	if _hbConn then _hbConn:Disconnect(); _hbConn = nil end
	CoverageOverlay.clear()
	for _, ib in _buttons do
		ib:Destroy()
	end
	table.clear(_buttons)
	if _root then _root:Destroy(); _root = nil end
	_started = false
end

return HeatmapController
