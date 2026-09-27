--!strict
-- WaterPanelController
-- The Water & Sewage panel: what the city drinks against what the towers pump, and what it
-- flushes against what the plants can take. Twin of ElectricityPanelController in shape and
-- behaviour -- a red-to-green bar with a marker riding it, the two figures it balances
-- labelled underneath at either end -- because the two utilities should not each invent
-- their own gauge.
--
-- Read-only. Everything comes off the `water` block WaterService pushes into the existing
-- SyncCityStats broadcast, so this opens no remote of its own.
--
-- Units are the SIM's: cubic metres per WEEK, which is what CS1 counts water in and what
-- every spec figure and the build cards are written in. One number, one unit, everywhere.
--
-- Second gauge is TREATMENT, not trade: nothing buys or sells water at the map edge, and a
-- gauge pinned at 0 / 0 forever is worse than no gauge.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local uiFolder = script.Parent.Parent:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local PanelSlots = require(uiFolder:WaitForChild("PanelSlots"))
local Icons = require(uiFolder:WaitForChild("Icons"))
local UITween = require(uiFolder:WaitForChild("UITween"))
local kitFolder = uiFolder:WaitForChild("Kit")
local Glass = require(kitFolder:WaitForChild("Glass"))
local IconButton = require(kitFolder:WaitForChild("IconButton"))

local WaterPanelController = {}

local PANEL_W = 336
local PANEL_TOP = 124
local BAR_H = 10
local MARKER_LERP = 0.18

local BAR_GRADIENT = ColorSequence.new({
	ColorSequenceKeypoint.new(0.00, Theme.Color.Danger),
	ColorSequenceKeypoint.new(0.38, Theme.Color.Accent),
	ColorSequenceKeypoint.new(0.62, Color3.fromRGB(172, 196, 96)),
	ColorSequenceKeypoint.new(1.00, Theme.Color.Positive),
})

type Gauge = {
	set: (t: number, left: string, right: string) -> (),
	step: () -> (),
}

local _started = false
local _open = false
local _panel: CanvasGroup? = nil
local _availability: Gauge? = nil
local _treatment: Gauge? = nil
local _status: TextLabel? = nil

local function commas(n: number): string
	local s = tostring(math.max(0, math.floor(n + 0.5)))
	local out = ""
	while #s > 3 do
		out = "," .. s:sub(#s - 2) .. out
		s = s:sub(1, #s - 3)
	end
	return s .. out
end

local function m3(n: number): string
	return commas(math.max(0, n)) .. " m\u{00B3}/wk"
end

local function label(parent: Instance, text: string, size: number, colour: Color3, font: Font): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextColor3 = colour
	l.TextSize = size
	l.FontFace = font
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = parent
	return l
end

-- One gauge: a caption, the gradient bar with its marker, and the two figures it balances.
local function makeGauge(parent: Instance, caption: string, order: number): Gauge
	local block = Instance.new("Frame")
	block.Name = caption
	block.BackgroundColor3 = Theme.Color.BgRaised
	block.BackgroundTransparency = 0.35
	block.BorderSizePixel = 0
	block.Size = UDim2.new(1, 0, 0, 74)
	block.LayoutOrder = order
	block.Parent = parent
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, Theme.Radius.SM); c.Parent = block
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, Theme.Pad.SM)
	pad.PaddingBottom = UDim.new(0, Theme.Pad.SM)
	pad.PaddingLeft = UDim.new(0, Theme.Pad.LG)
	pad.PaddingRight = UDim.new(0, Theme.Pad.LG)
	pad.Parent = block

	local cap = label(block, caption, Theme.TextSize.XS, Theme.Color.TextPrimary, Theme.Font.Header)
	cap.Size = UDim2.new(1, 0, 0, 14)

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Position = UDim2.fromOffset(0, 26)
	track.Size = UDim2.new(1, 0, 0, BAR_H)
	track.BorderSizePixel = 0
	track.BackgroundColor3 = Color3.new(1, 1, 1)
	track.Parent = block
	local tc = Instance.new("UICorner"); tc.CornerRadius = UDim.new(0, 3); tc.Parent = track
	local grad = Instance.new("UIGradient"); grad.Color = BAR_GRADIENT; grad.Parent = track

	local marker = Instance.new("TextLabel")
	marker.Name = "Marker"
	marker.BackgroundTransparency = 1
	marker.AnchorPoint = Vector2.new(0.5, 1)
	marker.Position = UDim2.new(0, 0, 0, 27)
	marker.Size = UDim2.fromOffset(14, 14)
	marker.Text = "\u{25BC}"
	marker.TextColor3 = Theme.Color.TextPrimary
	marker.TextSize = 12
	marker.FontFace = Theme.Font.Bold
	marker.Parent = block

	local left = label(block, "", Theme.TextSize.XS, Theme.Color.TextSecondary, Theme.Font.Label)
	left.Position = UDim2.fromOffset(0, 42)
	left.Size = UDim2.new(0.5, 0, 0, 16)

	local right = label(block, "", Theme.TextSize.XS, Theme.Color.TextSecondary, Theme.Font.Label)
	right.Position = UDim2.new(0.5, 0, 0, 42)
	right.Size = UDim2.new(0.5, 0, 0, 16)
	right.TextXAlignment = Enum.TextXAlignment.Right

	local target, current = 0, 0
	return {
		set = function(t: number, l: string, r: string)
			target = math.clamp(t, 0, 1)
			left.Text = l
			right.Text = r
		end,
		-- Eased so the marker slides to a new balance instead of jumping a third of the bar
		-- every time the stats broadcast lands.
		step = function()
			local diff = target - current
			if math.abs(diff) < 0.001 then
				if current ~= target then
					current = target
					marker.Position = UDim2.new(current, 0, 0, 27)
				end
				return
			end
			current += diff * MARKER_LERP
			marker.Position = UDim2.new(current, 0, 0, 27)
		end,
	}
end

local function build(gui: ScreenGui)
	local panel = Instance.new("CanvasGroup")
	panel.Name = "WaterPanel"
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1, PANEL_W + 24, 0, PANEL_TOP)
	panel.Size = UDim2.fromOffset(PANEL_W, 236)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.GroupTransparency = 1
	panel.Visible = false
	panel.ZIndex = Theme.Z.HUD
	panel.BorderSizePixel = 0
	panel.Parent = gui
	Glass.apply(panel, Theme.Radius.Panel)

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, Theme.Pad.LG)
	pad.PaddingBottom = UDim.new(0, Theme.Pad.LG)
	pad.PaddingLeft = UDim.new(0, Theme.Pad.LG)
	pad.PaddingRight = UDim.new(0, Theme.Pad.LG)
	pad.Parent = panel

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 26)
	header.Parent = panel

	local drop = label(header, "\u{1F4A7}", Theme.TextSize.MD, Theme.Color.Accent, Theme.Font.Bold)
	drop.AnchorPoint = Vector2.new(0, 0.5)
	drop.Position = UDim2.fromScale(0, 0.5)
	drop.Size = UDim2.fromOffset(20, 20)

	local title = label(header, "WATER & SEWAGE", Theme.TextSize.SM, Theme.Color.Brand, Theme.Font.Bold)
	title.AnchorPoint = Vector2.new(0, 0.5)
	title.Position = UDim2.fromOffset(24, 13)
	title.Size = UDim2.new(1, -56, 0, 20)

	IconButton.new({
		icon = Icons.Close,
		name = "Close",
		size = 24,
		parent = header,
		onClick = function() WaterPanelController.Close() end,
	})
	local closeBtn = header:FindFirstChild("Close")
	if closeBtn and closeBtn:IsA("GuiObject") then
		closeBtn.AnchorPoint = Vector2.new(1, 0.5)
		closeBtn.Position = UDim2.fromScale(1, 0.5)
	end

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Position = UDim2.fromOffset(0, 34)
	content.Size = UDim2.new(1, 0, 0, 0)
	content.AutomaticSize = Enum.AutomaticSize.Y
	content.Parent = panel

	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, Theme.Pad.SM)
	list.Parent = content

	_availability = makeGauge(content, "WATER AVAILABILITY", 1)
	_treatment = makeGauge(content, "SEWAGE TREATMENT", 2)

	local status = label(content, "", Theme.TextSize.XS, Theme.Color.TextSecondary, Theme.Font.Label)
	status.LayoutOrder = 3
	status.Size = UDim2.new(1, 0, 0, 16)
	status.TextXAlignment = Enum.TextXAlignment.Center
	_status = status

	_panel = panel
end

local function apply(water: any)
	local av, tr = _availability, _treatment
	if not av or not tr then return end

	local output   = math.max(0, tonumber(water and water.waterCapacity) or 0)
	local use      = math.max(0, tonumber(water and water.waterUse) or 0)
	local treatCap = math.max(0, tonumber(water and water.sewageCapacity) or 0)
	local sewage   = math.max(0, tonumber(water and water.sewage) or 0)
	local watered  = math.clamp(tonumber(water and water.watered) or 1, 0, 1)

	-- Marker sits at output's share of the two figures: hard left when the city pumps
	-- nothing, centre when supply exactly meets demand, right as headroom opens up.
	local total = output + use
	av.set(if total > 0 then output / total else 0, "Consumption: " .. m3(use), "Output: " .. m3(output))

	local drain = treatCap + sewage
	tr.set(if drain > 0 then treatCap / drain else 0, "Wastewater: " .. m3(sewage), "Capacity: " .. m3(treatCap))

	local status = _status
	if not status then return end
	local drained = math.clamp(tonumber(water and water.drained) or 1, 0, 1)
	local sewageNeeded = tonumber(water and water.sewageNeeded) == 1
	if output <= 0 then
		status.Text = "No water yet -- build a Water Tower next to a road."
		status.TextColor3 = Theme.Color.TextSecondary
	elseif watered < 0.999 then
		status.Text = ("%d%% of homes have no water."):format(math.floor((1 - watered) * 100 + 0.5))
		status.TextColor3 = Theme.Color.Danger
	elseif sewageNeeded and drained < 0.999 then
		status.Text = ("%d%% of homes have no drain."):format(math.floor((1 - drained) * 100 + 0.5))
		status.TextColor3 = Theme.Color.Danger
	elseif sewageNeeded then
		status.Text = "Every home has water and a drain."
		status.TextColor3 = Theme.Color.Positive
	else
		status.Text = "Every home has water. Sewage is not needed yet."
		status.TextColor3 = Theme.Color.Positive
	end
end

function WaterPanelController.Open()
	local panel = _panel
	if not panel then return end
	_open = true
	PanelSlots.claim("rightPanel", "Water", WaterPanelController.Close)
	panel.Visible = true
	UITween.to(panel, "Flyout", { GroupTransparency = 0, Position = UDim2.new(1, -12, 0, PANEL_TOP) })
end

function WaterPanelController.Close()
	local panel = _panel
	if not panel then return end
	_open = false
	PanelSlots.release("rightPanel", "Water")
	local tween = UITween.to(panel, "Flyout", {
		GroupTransparency = 1,
		Position = UDim2.new(1, PANEL_W + 24, 0, PANEL_TOP),
	})
	tween.Completed:Once(function()
		if not _open then panel.Visible = false end
	end)
end

function WaterPanelController.Toggle()
	if _open then WaterPanelController.Close() else WaterPanelController.Open() end
end

function WaterPanelController.IsOpen(): boolean
	return _open
end

function WaterPanelController.Start()
	if _started then return end
	_started = true

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = playerGui:WaitForChild("CityUI", 60)
	if not gui or not gui:IsA("ScreenGui") then
		warn("[WaterPanelController] CityUI not found")
		_started = false
		return
	end

	build(gui)
	apply(nil)

	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	Net.SyncCityStats.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" then return end
		apply(payload.water)
	end)

	game:GetService("RunService").Heartbeat:Connect(function()
		if not _open then return end -- a hidden marker does not need easing
		if _availability then _availability.step() end
		if _treatment then _treatment.step() end
	end)
end

return WaterPanelController
