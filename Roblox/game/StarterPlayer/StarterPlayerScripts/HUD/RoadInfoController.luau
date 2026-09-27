--!strict
-- RoadInfoController
-- Click any road to open the street: what it's called, what kind of road it is,
-- how far it runs, and how much traffic is on it right now -- and rename it from
-- the same panel.
--
-- The name and the street's extent are derived locally by AddressBook from the
-- segments the client already has, so opening the panel costs no network at all.
-- Only live congestion is asked of the server, and only while the panel is open.
-- Idle while a build tool owns the cursor, so it never steals a placement click.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local AddressBook     = require(ReplicatedStorage.City.AddressBook)
local BezierUtil      = require(ReplicatedStorage.Road.BezierUtil)
local DataCache       = require(ReplicatedStorage.DataCache)
local RoadConstants   = require(ReplicatedStorage.Road.RoadConstants)
local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)

local CursorRay = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("CursorRay"))

local uiFolder = script.Parent.Parent:WaitForChild("UI")
local Theme   = require(uiFolder:WaitForChild("Theme"))
local UITween = require(uiFolder:WaitForChild("UITween"))
local Glass   = require(uiFolder:WaitForChild("Kit"):WaitForChild("Glass"))

local RoadInfoController = {}

local TRAFFIC_POLL = 2
local MAX_NAME_LEN = 40
-- How far off a road's centreline a click still counts as hitting it. Covers the
-- sidewalk, junction paving and dead-end caps, which are their own models. This is a
-- GEOMETRIC floor -- the road's own footprint -- and holds at any zoom.
local CLICK_SLOP = 18 * RoadConstants.WORLD_SCALE
-- On top of the floor, a screen-space allowance so the click stays as forgiving zoomed
-- out as it is up close (one pixel covers ~0.12 studs close in and ~6 studs at 2500).
local CLICK_SLOP_PX = 14
local CLICK_SLOP_MAX = 60
local FREE = Color3.fromRGB(108, 198, 118)
local BUSY = Color3.fromRGB(230, 190, 80)
local JAMMED = Color3.fromRGB(226, 96, 88)

local _started = false
local _open = false
local _segId: number? = nil
local _pollToken = 0
local _net: any = nil
local _bottomBar: any = nil
local _hudGui: ScreenGui
local _panel: CanvasGroup
local _nameBox: TextBox
local _subtitle: TextLabel
local _speed: TextLabel
local _trafficValue: TextLabel
local _trafficFill: Frame
local _trafficNote: TextLabel
local _highlight: Highlight
local _rayParams = RaycastParams.new()
-- DeleteHoverController.FindBuildingFromInstance: the shared "is this hit a
-- building?" test, so a click on a house beside the road opens the building panel
-- and not this one.
local _hover: any = nil
local _buildingInfo: any = nil

-- Idle while ANY build tool owns the cursor: an open build section, or the
-- top-level bulldoze tool (whose click deletes -- this panel must not also open).
local function sectionActive(): boolean
	if _bottomBar == nil then return false end
	if _bottomBar.GetActiveSection and _bottomBar.GetActiveSection() ~= nil then return true end
	if _bottomBar.IsBulldozeActive and _bottomBar.IsBulldozeActive() then return true end
	return false
end

local function corner(inst: GuiObject, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = inst
end

local function label(parent: Instance, order: number, text: string, size: number, color: Color3): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, 0, 0, size + 4)
	l.LayoutOrder = order
	l.Text = text
	l.TextColor3 = color
	l.TextSize = size
	l.FontFace = Theme.Font.Label
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextTruncate = Enum.TextTruncate.AtEnd
	l.Parent = parent
	return l
end

local function buildPanel(gui: ScreenGui)
	local panel = Instance.new("CanvasGroup")
	panel.Name = "RoadInfo"
	panel.Position = UDim2.new(0, 12, 0, 64)
	panel.Size = UDim2.fromOffset(272, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.GroupTransparency = 1
	panel.Visible = false
	panel.ZIndex = Theme.Z.Flyout
	Glass.apply(panel, Theme.Radius.LG)
	panel.Parent = gui
	_panel = panel

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, Theme.Pad.LG)
	pad.PaddingBottom = UDim.new(0, Theme.Pad.LG)
	pad.PaddingLeft = UDim.new(0, Theme.Pad.LG)
	pad.PaddingRight = UDim.new(0, Theme.Pad.LG)
	pad.Parent = panel

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, Theme.Pad.SM)
	list.Parent = panel

	-- The title IS the rename field: no edit mode, no pencil icon, just type.
	local box = Instance.new("TextBox")
	box.Name = "StreetName"
	box.BackgroundTransparency = 1
	box.Size = UDim2.new(1, -28, 0, 26)
	box.LayoutOrder = 1
	box.Text = "Street"
	box.PlaceholderText = "Street name"
	box.TextColor3 = Theme.Color.TextPrimary
	box.PlaceholderColor3 = Theme.Color.TextDisabled
	box.TextSize = Theme.TextSize.LG
	box.FontFace = Theme.Font.Header
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.ClearTextOnFocus = false
	box.TextTruncate = Enum.TextTruncate.AtEnd
	box.Parent = panel
	_nameBox = box

	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, -Theme.Pad.LG, 0, Theme.Pad.LG)
	close.Size = UDim2.fromOffset(22, 22)
	close.BackgroundColor3 = Theme.Color.BgRaised
	close.BackgroundTransparency = 0.35
	close.Text = "\u{00D7}"
	close.TextColor3 = Theme.Color.TextSecondary
	close.TextSize = Theme.TextSize.MD
	close.FontFace = Theme.Font.Bold
	close.ZIndex = 5
	close.Parent = panel
	corner(close, 11)
	close.Activated:Connect(function()
		RoadInfoController.Close()
	end)

	_subtitle = label(panel, 2, "", Theme.TextSize.SM, Theme.Color.TextSecondary)
	_speed = label(panel, 3, "", Theme.TextSize.SM, Theme.Color.TextSecondary)

	local trafficRow = Instance.new("Frame")
	trafficRow.BackgroundTransparency = 1
	trafficRow.Size = UDim2.new(1, 0, 0, 20)
	trafficRow.LayoutOrder = 4
	trafficRow.Parent = panel

	local trafficLabel = Instance.new("TextLabel")
	trafficLabel.BackgroundTransparency = 1
	trafficLabel.Size = UDim2.new(0.5, 0, 1, 0)
	trafficLabel.Text = "Traffic"
	trafficLabel.TextColor3 = Theme.Color.TextSecondary
	trafficLabel.TextSize = Theme.TextSize.SM
	trafficLabel.FontFace = Theme.Font.Label
	trafficLabel.TextXAlignment = Enum.TextXAlignment.Left
	trafficLabel.Parent = trafficRow

	local value = Instance.new("TextLabel")
	value.BackgroundTransparency = 1
	value.Size = UDim2.new(0.5, 0, 1, 0)
	value.Position = UDim2.fromScale(0.5, 0)
	value.Text = "--"
	value.TextColor3 = Theme.Color.TextPrimary
	value.TextSize = Theme.TextSize.SM
	value.FontFace = Theme.Font.Bold
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.Parent = trafficRow
	_trafficValue = value

	local track = Instance.new("Frame")
	track.Size = UDim2.new(1, 0, 0, 6)
	track.LayoutOrder = 5
	track.BackgroundColor3 = Theme.Color.BgPress
	track.BorderSizePixel = 0
	track.Parent = panel
	corner(track, 3)

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = FREE
	fill.BorderSizePixel = 0
	fill.Parent = track
	corner(fill, 3)
	_trafficFill = fill

	_trafficNote = label(panel, 6, "", Theme.TextSize.XS, Theme.Color.TextDisabled)
end

-- ------------------------------------------------------------------ picking --

-- Slop for resolving a hit point to a road: never tighter than the road's own footprint,
-- widened to a constant on-screen allowance when the camera is far out.
local function clickSlop(at: Vector3): number
	return math.max(CLICK_SLOP, CursorRay.pickRadius(at, CLICK_SLOP_PX, 0, CLICK_SLOP_MAX))
end

-- `input` is passed through so touch reads its own finger position; for mouse input the
-- cursor comes from CursorRay, NOT input.Position (which is inset-relative and aimed the
-- ray ~36 px above the click).
local function segmentIdAt(index: AddressBook.Index, input: InputObject?): number?
	local city = Workspace:FindFirstChild("_City")
	local roads = city and city:FindFirstChild("Roads")
	if roads then
		_rayParams.FilterType = Enum.RaycastFilterType.Include
		_rayParams.FilterDescendantsInstances = { roads }
		local hit = CursorRay.raycast(_rayParams, input)
		if hit then
			local cursor: Instance? = hit.Instance
			while cursor and cursor ~= roads do
				if cursor:IsA("Model") then
					local id = string.match(cursor.Name, "^Segment_(%d+)$")
					if id then return tonumber(id) end
				end
				cursor = cursor.Parent
			end
			-- Junction / dead-end caps are their own models: resolve them by position.
			return AddressBook.nearestSegmentId(index, hit.Position, clickSlop(hit.Position))
		end
	end

	-- Road pieces baked into a merged mesh may not be queryable. Fall back to an
	-- unfiltered hit and accept it only if it landed on a carriageway.
	_rayParams.FilterType = Enum.RaycastFilterType.Exclude
	_rayParams.FilterDescendantsInstances = {}
	local hit = CursorRay.raycast(_rayParams, input)
	if not hit then return nil end
	-- Houses sit within a road's width of the kerb, so without this a click on one
	-- would open the street it fronts as well as the building panel.
	if _hover and _hover.FindBuildingFromInstance and _hover.FindBuildingFromInstance(hit.Instance) then
		return nil
	end
	return AddressBook.nearestSegmentId(index, hit.Position, clickSlop(hit.Position))
end

-- ---------------------------------------------------------------- populate --

local function trafficColor(c: number): Color3
	if c < 0.35 then return FREE end
	if c < 0.7 then return BUSY end
	return JAMMED
end

local function trafficWord(c: number): string
	if c < 0.15 then return "Free flowing" end
	if c < 0.35 then return "Light" end
	if c < 0.7 then return "Busy" end
	return "Congested"
end

local function applyTraffic(data: any)
	local c = math.clamp(tonumber(data.congestion) or 0, 0, 1)
	_trafficValue.Text = string.format("%d%%", math.round(c * 100))
	_trafficValue.TextColor3 = trafficColor(c)
	_trafficFill.BackgroundColor3 = trafficColor(c)
	UITween.to(_trafficFill, "Hover", { Size = UDim2.fromScale(c, 1) })
	local peak = math.clamp(tonumber(data.peakCongestion) or 0, 0, 1)
	_trafficNote.Text = trafficWord(c) .. string.format("  \u{00B7}  busiest lane %d%%", math.round(peak * 100))
end

-- Street length + road type from the local index; no server needed for either.
local function populate(index: AddressBook.Index, segId: number)
	local name = AddressBook.nameOf(index, segId) or "Unnamed road"
	if not _nameBox:IsFocused() then
		_nameBox.Text = name
	end

	local chain = AddressBook.chainOf(index, segId)
	local length = 0
	for _, id in chain do
		local s = index.segs[id]
		if s then
			length += BezierUtil.length(s.p0, s.p1, s.p2, s.p3, 12)
		end
	end

	local seg = index.segs[segId]
	local spec = RoadTypeCatalog.getOrDefault(if seg then seg.roadType else "")
	_subtitle.Text = spec.name .. "  \u{00B7}  " .. RoadConstants.formatMeters(length)
	_speed.Text = "Speed limit  " .. tostring(spec.speedLimit) .. " km/h"
end

local function pollTraffic(segId: number)
	_pollToken += 1
	local token = _pollToken
	if not _net or not _net.RequestRoadTraffic then return end
	task.spawn(function()
		while _open and token == _pollToken do
			local ok, data = pcall(function()
				return _net.RequestRoadTraffic:InvokeServer(segId)
			end)
			if not _open or token ~= _pollToken then break end
			if ok and typeof(data) == "table" then
				applyTraffic(data)
			end
			task.wait(TRAFFIC_POLL)
		end
	end)
end

local function highlightSegment(segId: number)
	local city = Workspace:FindFirstChild("_City")
	local roads = city and city:FindFirstChild("Roads")
	local model = roads and roads:FindFirstChild("Segment_" .. tostring(segId))
	-- ponytail: outlines the clicked piece, not the whole street. Roblox renders
	-- ~31 Highlights at once, so lighting up a long street needs the reparent-into-
	-- one-container trick DeleteHoverController uses -- add it if it's ever missed.
	_highlight.Adornee = if model and model:IsA("Model") then model else nil
	_highlight.Enabled = _highlight.Adornee ~= nil
end

local function open(index: AddressBook.Index, segId: number)
	-- One inspector at a time: both panels live in the same top-left slot.
	if _buildingInfo and _buildingInfo.Close then
		pcall(_buildingInfo.Close)
	end
	_segId = segId
	populate(index, segId)
	highlightSegment(segId)
	_trafficValue.Text = "--"
	_trafficNote.Text = "Reading traffic\u{2026}"
	_open = true
	_panel.Visible = true
	UITween.to(_panel, "Flyout", { GroupTransparency = 0 })
	pollTraffic(segId)
end

function RoadInfoController.Close()
	if not _open then return end
	_open = false
	_segId = nil
	_pollToken += 1
	_highlight.Adornee = nil
	_highlight.Enabled = false
	if _nameBox:IsFocused() then
		_nameBox:ReleaseFocus()
	end
	UITween.to(_panel, "Flyout", { GroupTransparency = 1 })
	task.delay(0.25, function()
		if not _open then _panel.Visible = false end
	end)
end

function RoadInfoController.IsOpen(): boolean
	return _open
end

local function onClick(input: InputObject)
	if not _hudGui.Enabled or sectionActive() then return end
	local index = AddressBook.buildIndex(DataCache.GetSegments())
	local segId = segmentIdAt(index, input)
	if segId then
		open(index, segId)
	elseif _open then
		RoadInfoController.Close()
	end
end

local function submitName(enterPressed: boolean)
	local segId = _segId
	if not segId or not _net then return end
	if not enterPressed then
		-- Clicked away: drop the edit and show the real name again.
		local index = AddressBook.buildIndex(DataCache.GetSegments())
		_nameBox.Text = AddressBook.nameOf(index, segId) or "Unnamed road"
		return
	end
	local text = string.sub(_nameBox.Text, 1, MAX_NAME_LEN)
	_net.RequestSetRoadName:FireServer(segId, text)
end

function RoadInfoController.Start()
	if _started then return end
	_started = true

	local okNet, net = pcall(function() return require(ReplicatedStorage:WaitForChild("Networker")) end)
	_net = if okNet then net else nil

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local gui = playerGui:WaitForChild("CityUI", 60)
	if not gui or not gui:IsA("ScreenGui") then
		warn("[RoadInfoController] CityUI not found")
		_started = false
		return
	end
	_hudGui = gui

	buildPanel(gui)

	local hl = Instance.new("Highlight")
	hl.Name = "RoadSelect"
	hl.DepthMode = Enum.HighlightDepthMode.Occluded
	hl.FillColor = Theme.Color.Accent
	hl.FillTransparency = 0.82
	hl.OutlineColor = Theme.Color.Accent
	hl.OutlineTransparency = 0.1
	hl.Enabled = false
	hl.Parent = gui
	_highlight = hl

	local controllers = script.Parent.Parent:WaitForChild("Controllers")
	local okBar, bar = pcall(function()
		return require(controllers:WaitForChild("BottomBarController"))
	end)
	_bottomBar = if okBar then bar else nil

	local okHover, hover = pcall(function()
		return require(controllers:WaitForChild("DeleteHoverController"))
	end)
	_hover = if okHover then hover else nil

	local okInfo, info = pcall(function()
		return require(script.Parent:WaitForChild("BuildingInfoController"))
	end)
	_buildingInfo = if okInfo then info else nil

	_nameBox.FocusLost:Connect(submitName)

	-- A rename (or any road edit) re-syncs segments; refresh the open panel from it
	-- rather than round-tripping to confirm the name took.
	DataCache.On("segments", function()
		local segId = _segId
		if not _open or not segId then return end
		local index = AddressBook.buildIndex(DataCache.GetSegments())
		if not index.segs[segId] then
			RoadInfoController.Close()
			return
		end
		populate(index, segId)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then return end
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			onClick(input)
		end
	end)
end

return RoadInfoController
