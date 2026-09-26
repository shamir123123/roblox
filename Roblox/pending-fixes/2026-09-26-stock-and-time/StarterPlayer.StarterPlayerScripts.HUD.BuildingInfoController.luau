--!strict
-- Hover any building to highlight it + see a quick preview; click to open the
-- full info panel (name, address, level, residents/jobs, status). All data is
-- read instantly from replicated model attributes the server stamps
-- (Occupants/Capacity/OccupantKind/Level/Abandoned) -- no per-hover network.
-- Idle while a build tool is open so it never steals placement clicks.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AddressBook = require(ReplicatedStorage.City.AddressBook)
local DataCache = require(ReplicatedStorage.DataCache)
local ServiceTypes = require(ReplicatedStorage.City.ServiceTypes)
local CursorRay = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("CursorRay"))

local uiFolder = script.Parent.Parent:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local HudScale = require(uiFolder:WaitForChild("HudScale"))
local Icons = require(uiFolder:WaitForChild("Icons"))
local UITween = require(uiFolder:WaitForChild("UITween"))
local kit = uiFolder:WaitForChild("Kit")
local Glass = require(kit:WaitForChild("Glass"))
local IconButton = require(kit:WaitForChild("IconButton"))

local BuildingInfoController = {}

local ZONE_COLOR: { [string]: Color3 } = {
	Residential = Color3.fromRGB(82, 196, 110),
	Commercial = Color3.fromRGB(70, 160, 230),
	Industrial = Color3.fromRGB(220, 185, 55),
}
local GREEN = Color3.fromRGB(120, 220, 140)
-- A building further than this from any road has no street to be addressed on.
local ADDRESS_MAX_ROAD_DIST = 120
-- Gender shows as a tinted Venus/Mars glyph (pink = female, blue = male) so the roster
-- reads at a glance instead of bare "M"/"F" letters.
local GENDER_GLYPH: { [string]: string } = { M = "\u{2642}", F = "\u{2640}" }
local GENDER_HEX: { [string]: string } = { M = "60A5EB", F = "EB92BA" }
local NAMES: { [string]: { string } } = {
	Residential = { "Family Home", "Townhouse", "Apartment Block" },
	Commercial = { "Corner Shop", "Retail Store", "Shopping Center" },
	Industrial = { "Workshop", "Factory", "Industrial Plant" },
}
local DESC: { [string]: string } = {
	Residential = "Homes where your citizens live.",
	Commercial = "Shops that hire workers and sell goods.",
	Industrial = "Produces goods and provides industrial jobs.",
}

local _started = false
local _hudGui: ScreenGui
local _previewGui: ScreenGui
local _preview: CanvasGroup
local _chipName: TextLabel, _chipNameBadge: Frame, _chipLevel: TextLabel, _chipOcc: TextLabel, _chipOccGlyph: TextLabel
local _panel: CanvasGroup
local _accentDot: Frame, _name: TextLabel, _number: TextLabel, _level: TextLabel
local _desc: TextLabel, _occLabel: TextLabel, _occValue: TextLabel, _occFill: Frame, _status: TextLabel
local _sellRow: Frame, _sellLabel: TextLabel, _sellValue: TextLabel, _stockRow: Frame, _stockLabel: TextLabel, _stockValue: TextLabel
local _earnRow: Frame, _earnValue: TextLabel
-- Per-unit monthly tax (income/units) derived from the SyncEconomy taxBreakdown, used to
-- estimate how much a single building earns the city per month.
local _perUnit = { res = 0, comm = {}, ind = {} }
local _hoverHL: Highlight, _selectHL: Highlight
local _bottomBar: any = nil
local _hoverModel: Model? = nil
local _selectedModel: Model? = nil
local _selConn: RBXScriptConnection? = nil
local _open = false
local _net: any = nil
local _familyRow: Frame, _familyValue: TextButton
local _familyMembers: Frame
local _familyName: string? = nil
local _familyBpId: string? = nil
local _familyExpanded = false
local _familyLoaded = false
local _workersRow: Frame, _workersValue: TextButton
local _workersList: Frame
local _workersBpId: string? = nil
local _workersExpanded = false
local _workersLoaded = false
local _workersCount = 0
local _freeCam: any = nil
-- Traffic-route overlay (button-triggered, every building). Forward-declared so the panel
-- button (built earlier) can call it; assigned where the draw logic lives.
local _routeShown = false
local _routeBtn: TextButton? = nil
local _routeReq = 0
local toggleRoute: (() -> ())? = nil

-- Pick buildings with a raycast filtered to ONLY the buildings folders, the same
-- way the zoning/delete tools do -- so lots, terrain and cars can't block the hit.
-- Includes both ZonedBuildings (residential/commercial/industrial) and
-- EmergencyServices (hospital/police/fire station).
local _buildingsFolder: Folder? = nil
local _emergencyFolder: Folder? = nil
local _schoolsFolder: Folder? = nil
local _buildingRayParams = RaycastParams.new()
_buildingRayParams.FilterType = Enum.RaycastFilterType.Include
_buildingRayParams.IgnoreWater = true

local function clamp3(n: number): number
	return math.clamp(math.floor(n), 1, 3)
end

local function corner(inst: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = inst
end

local function commaInt(n: number): string
	local neg = n < 0
	local s = tostring(math.abs(math.floor(n + 0.5)))
	local out = ""
	while #s > 3 do out = "," .. s:sub(#s - 2) .. out; s = s:sub(1, #s - 3) end
	return (neg and "-" or "") .. s .. out
end

-- A faint caption that explains a roster's row-action icons. Lives at the top of an
-- expandable list (LayoutOrder 0) and survives clears -- clearWorkers/clearMembers
-- destroy only Frames, and this is a TextLabel.
local function makeLegend(parent: Instance, text: string)
	local l = Instance.new("TextLabel")
	l.Name = "Legend"
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, 0, 0, 14)
	l.LayoutOrder = 0
	l.Text = text
	l.TextColor3 = Theme.Color.TextDisabled
	l.TextSize = Theme.TextSize.XS
	l.FontFace = Theme.Font.Label
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = parent
end

-- Walk up from a hit part to find its owning Model: ZonedBuildings (BlueprintId),
-- EmergencyServices (ServiceId) or Schools (SchoolId).
local function findModelFromInstance(instance: Instance?): Model?
	local cursor = instance
	while cursor and cursor ~= Workspace do
		if cursor:IsA("Model") then
			if cursor:GetAttribute("BlueprintId") ~= nil
				or cursor:GetAttribute("ServiceId") ~= nil
				or cursor:GetAttribute("SchoolId") ~= nil then
				return cursor :: Model
			end
		end
		cursor = cursor.Parent
	end
	return nil
end

-- Takes the InputObject rather than a screen position: for MOUSE input the cursor must
-- come from CursorRay (viewport space), not input.Position (inset-relative -- feeding it
-- to ViewportPointToRay aimed the ray ~36 px above the cursor). Touch is read off the
-- InputObject inside CursorRay.position.
local function getBuildingAt(input: InputObject?): Model?
	local city = Workspace:FindFirstChild("_City")

	if not _buildingsFolder or not _buildingsFolder.Parent then
		local found = city and city:FindFirstChild("ZonedBuildings")
		_buildingsFolder = if found and found:IsA("Folder") then found else nil
	end
	if not _emergencyFolder or not _emergencyFolder.Parent then
		local found = city and city:FindFirstChild("EmergencyServices")
		_emergencyFolder = if found and found:IsA("Folder") then found else nil
	end
	if not _schoolsFolder or not _schoolsFolder.Parent then
		local found = city and city:FindFirstChild("Schools")
		_schoolsFolder = if found and found:IsA("Folder") then found else nil
	end

	local filters: { Instance } = {}
	if _buildingsFolder then table.insert(filters, _buildingsFolder) end
	if _emergencyFolder then table.insert(filters, _emergencyFolder) end
	if _schoolsFolder then table.insert(filters, _schoolsFolder) end
	if #filters == 0 then return nil end

	_buildingRayParams.FilterDescendantsInstances = filters
	local hit = CursorRay.raycast(_buildingRayParams, input)
	return if hit then findModelFromInstance(hit.Instance) else nil
end

local SERVICE_COLOR: { [string]: Color3 } = {
	Hospital = Color3.fromRGB(206, 70, 66),
	Police   = Color3.fromRGB(86, 140, 210),
	Fire     = Color3.fromRGB(244, 206, 96),
}
local SERVICE_DESC: { [string]: string } = {
	Hospital = "Keeps citizens healthy. Without one, people fall ill and die.",
	Police   = "Cuts crime nearby. Without one, robberies rise and happiness falls.",
	Fire     = "Puts out fires in range. Without one, fires spread house to house.",
}
local SERVICE_PROVIDES: { [string]: string } = {
	Hospital = "Healthcare coverage",
	Police   = "Crime reduction",
	Fire     = "Fire response",
}

local EDU_COLOR: { [string]: Color3 } = {
	School  = Color3.fromRGB(120, 170, 210),
	Library = Color3.fromRGB(190, 150, 95),
}
local EDU_DESC: { [string]: string } = {
	Elementary = "Teaches young children. Grants an Educated diploma.",
	HighSchool = "Teaches teenagers. Grants a Well-educated diploma.",
	University = "Teaches young adults. Grants a Highly-educated degree.",
	Library    = "Boosts education and land value nearby. Takes no pupils.",
}

local function readInfo(model: Model): { [string]: any }?
	-- Emergency service building path
	local serviceKind = model:GetAttribute("ServiceKind")
	if typeof(serviceKind) == "string" then
		local serviceName = tostring(model:GetAttribute("ServiceName") or serviceKind)
		local coverage = tonumber(model:GetAttribute("CoverageRadius")) or 0
		return {
			zone = "Service",
			serviceKind = serviceKind,
			serviceType = tostring(model:GetAttribute("ServiceType") or ""),
			serviceName = serviceName,
			coverage = coverage,
			level = 1,
			kind = "coverage",
			occupants = 0,
			capacity = 0,
			abandoned = false,
		}
	end
	-- Education service building path (schools + library)
	local schoolKind = model:GetAttribute("SchoolType")
	if typeof(schoolKind) == "string" then
		return {
			zone = "School",
			schoolKind = schoolKind,
			category = tostring(model:GetAttribute("Category") or "School"),
			serviceName = tostring(model:GetAttribute("ServiceName") or schoolKind),
			ageMin = math.floor(tonumber(model:GetAttribute("AgeMin")) or 0),
			ageMax = math.floor(tonumber(model:GetAttribute("AgeMax")) or 0),
			coverage = tonumber(model:GetAttribute("CoverageRadius")) or 0,
			occupants = math.floor(tonumber(model:GetAttribute("Occupants")) or 0),
			capacity = math.floor(tonumber(model:GetAttribute("Capacity")) or 0),
			level = 1,
			kind = "pupils",
			abandoned = false,
		}
	end
	-- Standard zoned building path
	local zone = model:GetAttribute("ZoneType")
	if typeof(zone) ~= "string" then return nil end
	local level = clamp3(tonumber(model:GetAttribute("Level")) or 1)
	local kind = model:GetAttribute("OccupantKind")
	if typeof(kind) ~= "string" then
		kind = if zone == "Residential" then "residents" else "jobs"
	end
	local occupants = tonumber(model:GetAttribute("Occupants")) or tonumber(model:GetAttribute("Residents")) or 0
	local capacity = tonumber(model:GetAttribute("Capacity")) or 0
	return {
		zone = zone,
		level = level,
		kind = kind,
		occupants = math.floor(occupants),
		capacity = math.floor(capacity),
		-- Homes let by HOUSEHOLD: how many families live here, out of how many fit.
		households = math.floor(tonumber(model:GetAttribute("Households")) or 0),
		householdCap = math.floor(tonumber(model:GetAttribute("HouseholdCap")) or 0),
		abandoned = model:GetAttribute("Abandoned") == true,
	}
end

local function nameFor(zone: string, level: number, info: { [string]: any }?): string
	if (zone == "Service" or zone == "School") and info then
		return tostring(info.serviceName)
	end
	local t = NAMES[zone]
	return if t then t[clamp3(level)] else zone
end

-- Accent colour for a building: zone tint, service-kind tint, or school/library tint.
local function accentColor(info: { [string]: any }): Color3
	if info.zone == "Service" then return SERVICE_COLOR[info.serviceKind] or Theme.Color.Accent end
	if info.zone == "School" then return EDU_COLOR[info.category] or EDU_COLOR.School end
	return ZONE_COLOR[info.zone] or Theme.Color.Accent
end

local function numberFor(bpId: string): number
	local n = tonumber(string.match(bpId, "%d+")) or 1
	return (n * 2) % 996 + 1
end

local function statusOf(info: { [string]: any }): (string, Color3)
	if info.abandoned then return "Abandoned", Theme.Color.Danger end
	if info.capacity > 0 and info.occupants >= info.capacity then
		return (if info.kind == "jobs" then "Fully staffed" else "At capacity"), GREEN
	end
	if info.occupants > 0 then return "Occupied", GREEN end
	return (if info.kind == "jobs" then "Hiring" else "Vacant"), Theme.Color.TextSecondary
end

-- ---------------------------------------------------------------- build --
-- One hover chip: a small glass pill with a colored icon badge + label.
local function makeChip(parent: Instance, order: number, badgeColor: Color3, glyph: string): (Frame, TextLabel, TextLabel)
	local chip = Instance.new("Frame")
	chip.Name = "Chip"
	chip.AutomaticSize = Enum.AutomaticSize.X
	chip.Size = UDim2.fromOffset(0, 26)
	chip.LayoutOrder = order
	Glass.apply(chip, Theme.Radius.MD)
	chip.Parent = parent

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 4)
	pad.PaddingRight = UDim.new(0, Theme.Pad.MD)
	pad.Parent = chip

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, Theme.Pad.SM)
	list.Parent = chip

	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.Size = UDim2.fromOffset(18, 18)
	badge.BackgroundColor3 = badgeColor
	badge.BorderSizePixel = 0
	badge.LayoutOrder = 1
	badge.Parent = chip
	corner(badge, 5)

	local g = Instance.new("TextLabel")
	g.Name = "Glyph"
	g.BackgroundTransparency = 1
	g.Size = UDim2.fromScale(1, 1)
	g.Text = glyph
	g.TextColor3 = Theme.Color.OnAccent
	g.TextSize = 11
	g.FontFace = Theme.Font.Bold
	g.Parent = badge

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromOffset(0, 18)
	label.BackgroundTransparency = 1
	label.Text = ""
	label.TextColor3 = Theme.Color.TextPrimary
	label.TextSize = Theme.TextSize.SM
	label.FontFace = Theme.Font.Header
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.LayoutOrder = 2
	label.Parent = chip

	return badge, label, g
end

-- Cities-Skylines-style hover stack: name / level / residents-or-jobs / click hint.
local function buildPreview(gui: ScreenGui)
	local p = Instance.new("CanvasGroup")
	p.Name = "Preview"
	p.AutomaticSize = Enum.AutomaticSize.XY
	p.Size = UDim2.fromOffset(0, 0)
	p.BackgroundTransparency = 1
	p.GroupTransparency = 1
	p.Visible = false
	p.ZIndex = Theme.Z.Tooltip
	p.Parent = gui
	_preview = p

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.HorizontalAlignment = Enum.HorizontalAlignment.Left
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 4)
	list.Parent = p

	local nameBadge, nameLabel = makeChip(p, 1, ZONE_COLOR.Residential, "\u{25C6}")
	nameLabel.FontFace = Theme.Font.Bold
	_chipName = nameLabel
	_chipNameBadge = nameBadge

	local _, levelLabel = makeChip(p, 2, Theme.Color.Brand, "\u{25B2}")
	_chipLevel = levelLabel

	local _, occLabel, occGlyph = makeChip(p, 3, Color3.fromRGB(82, 196, 110), "\u{25CF}")
	_chipOcc = occLabel
	_chipOccGlyph = occGlyph

	local _, infoLabel, infoGlyph = makeChip(p, 4, Theme.Color.BgHover, "\u{203A}")
	infoLabel.Text = "Info Panel"
	infoLabel.TextColor3 = Theme.Color.TextSecondary
	infoLabel.FontFace = Theme.Font.Label
	infoGlyph.TextColor3 = Theme.Color.TextSecondary
end

local function infoRow(parent: Instance, order: number, labelText: string): TextLabel
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 18)
	row.LayoutOrder = order
	row.Parent = parent
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(0.5, 0, 1, 0)
	l.Text = labelText
	l.TextColor3 = Theme.Color.TextSecondary
	l.TextSize = Theme.TextSize.SM
	l.FontFace = Theme.Font.Label
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = row
	local v = Instance.new("TextLabel")
	v.Name = "Value"
	v.BackgroundTransparency = 1
	v.AnchorPoint = Vector2.new(1, 0)
	v.Position = UDim2.fromScale(1, 0)
	v.Size = UDim2.new(0.5, 0, 1, 0)
	v.Text = ""
	v.TextColor3 = Theme.Color.TextPrimary
	v.TextSize = Theme.TextSize.SM
	v.FontFace = Theme.Font.Header
	v.TextXAlignment = Enum.TextXAlignment.Right
	v.Parent = row
	return v
end

-- Like infoRow but also returns the row + left label, for rows whose label text or
-- visibility we toggle at runtime (the supply-chain rows).
local function infoRow2(parent: Instance, order: number, labelText: string): (Frame, TextLabel, TextLabel)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 18)
	row.LayoutOrder = order
	row.Parent = parent
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(0.5, 0, 1, 0)
	l.Text = labelText
	l.TextColor3 = Theme.Color.TextSecondary
	l.TextSize = Theme.TextSize.SM
	l.FontFace = Theme.Font.Label
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = row
	local v = Instance.new("TextLabel")
	v.Name = "Value"
	v.BackgroundTransparency = 1
	v.AnchorPoint = Vector2.new(1, 0)
	v.Position = UDim2.fromScale(1, 0)
	v.Size = UDim2.new(0.5, 0, 1, 0)
	v.Text = ""
	v.TextColor3 = Theme.Color.TextPrimary
	v.TextSize = Theme.TextSize.SM
	v.FontFace = Theme.Font.Header
	v.TextXAlignment = Enum.TextXAlignment.Right
	v.Parent = row
	return row, l, v
end

-- Locate a citizen by their stable person id, fetched live. A MOVING citizen (driving /
-- walking) is FOLLOWED continuously; a settled one (at work / at home / a child) gets a
-- one-time fly-over. Shared by the family + worker rosters' "locate" dot.
local function flyToCitizenNow(pid: number?)
	if not _net or typeof(pid) ~= "number" then return end
	task.spawn(function()
		local ok, info = pcall(function() return _net.RequestCitizenPos:InvokeServer(pid) end)
		if not ok or typeof(info) ~= "table" or not _freeCam then return end
		if typeof(info.follow) == "Instance" and info.follow:IsA("BasePart") and _freeCam.followPart then
			_freeCam.followPart(info.follow)
		elseif typeof(info.pos) == "Vector3" and _freeCam.focusOn then
			_freeCam.focusOn(info.pos)
		end
	end)
end

-- ---------------------------------------------------------------- family --
local function clearMembers()
	for _, c in _familyMembers:GetChildren() do
		if c:IsA("Frame") then c:Destroy() end
	end
end

local function memberRow(order: number, m: { [string]: any })
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 17)
	row.LayoutOrder = order
	row.Parent = _familyMembers

	local nameL = Instance.new("TextLabel")
	nameL.BackgroundTransparency = 1
	nameL.Size = UDim2.new(0.34, 0, 1, 0)
	nameL.Text = "  " .. tostring(m.name)
	nameL.TextColor3 = Theme.Color.TextPrimary
	nameL.TextSize = Theme.TextSize.XS
	nameL.FontFace = Theme.Font.Header
	nameL.TextXAlignment = Enum.TextXAlignment.Left
	nameL.TextTruncate = Enum.TextTruncate.AtEnd
	nameL.Parent = row

	local key = if tostring(m.gender) == "M" then "M" else "F"
	local role = if tostring(m.role) == "Child" then "Child" elseif m.employed == true then "Working adult" else "Adult"
	local detail = Instance.new("TextLabel")
	detail.AnchorPoint = Vector2.new(1, 0)
	detail.Position = UDim2.new(1, -22, 0, 0)
	detail.BackgroundTransparency = 1
	detail.Size = UDim2.new(0.66, -22, 1, 0)
	detail.RichText = true
	detail.Text = string.format('%d yo  \u{00B7}  <font color="#%s">%s</font>  \u{00B7}  %s', math.floor(tonumber(m.age) or 0), GENDER_HEX[key], GENDER_GLYPH[key], role)
	detail.TextColor3 = Theme.Color.TextSecondary
	detail.TextSize = Theme.TextSize.XS
	detail.FontFace = Theme.Font.Label
	detail.TextXAlignment = Enum.TextXAlignment.Right
	detail.TextTruncate = Enum.TextTruncate.AtEnd
	detail.Parent = row

	-- "Where are they now" locate dot -> follows / flies to this member's live position.
	local pid = tonumber(m.pid)
	local now = Instance.new("TextButton")
	now.Name = "WhereNow"
	now.AnchorPoint = Vector2.new(1, 0.5)
	now.Position = UDim2.new(1, 0, 0.5, 0)
	now.Size = UDim2.fromOffset(18, 16)
	now.BackgroundTransparency = 1
	now.AutoButtonColor = false
	now.Text = "\u{25CF}"
	now.TextColor3 = Theme.Color.Brand
	now.TextSize = Theme.TextSize.SM
	now.FontFace = Theme.Font.Bold
	now.Parent = row
	now.Activated:Connect(function()
		flyToCitizenNow(pid)
	end)
end

local function renderFamily(bpId: string)
	if not _net then return end
	local ok, info = pcall(function()
		return _net.RequestFamilyInfo:InvokeServer(bpId)
	end)
	-- The selection or collapsed state may have changed while the request was in flight.
	if _familyBpId ~= bpId or not _familyExpanded then return end
	clearMembers()
	if ok and typeof(info) == "table" and typeof(info.members) == "table" then
		for i, m in info.members do memberRow(i, m) end
	end
end

local function toggleFamily()
	if not _familyBpId then return end
	_familyExpanded = not _familyExpanded
	_familyValue.Text = (if _familyExpanded then "\u{25BE}  " else "\u{25B8}  ") .. tostring(_familyName)
	_familyMembers.Visible = _familyExpanded
	if _familyExpanded and not _familyLoaded then
		_familyLoaded = true
		local bpId = _familyBpId
		task.spawn(function() renderFamily(bpId) end)
	end
end

local function buildFamilySection(panel: Instance)
	local row = Instance.new("Frame")
	row.Name = "FamilyRow"
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 18)
	row.LayoutOrder = 6
	row.Visible = false
	row.Parent = panel
	_familyRow = row

	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(0.35, 0, 1, 0)
	l.Text = "Family"
	l.TextColor3 = Theme.Color.TextSecondary
	l.TextSize = Theme.TextSize.SM
	l.FontFace = Theme.Font.Label
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = row

	local btn = Instance.new("TextButton")
	btn.Name = "FamilyValue"
	btn.AnchorPoint = Vector2.new(1, 0)
	btn.Position = UDim2.fromScale(1, 0)
	btn.Size = UDim2.new(0.65, 0, 1, 0)
	btn.BackgroundTransparency = 1
	btn.AutoButtonColor = false
	btn.Text = ""
	btn.TextColor3 = ZONE_COLOR.Residential
	btn.TextSize = Theme.TextSize.SM
	btn.FontFace = Theme.Font.Bold
	btn.TextXAlignment = Enum.TextXAlignment.Right
	btn.TextTruncate = Enum.TextTruncate.AtEnd
	btn.Parent = row
	_familyValue = btn
	btn.Activated:Connect(toggleFamily)

	local members = Instance.new("Frame")
	members.Name = "FamilyMembers"
	members.BackgroundTransparency = 1
	members.AutomaticSize = Enum.AutomaticSize.Y
	members.Size = UDim2.new(1, 0, 0, 0)
	members.LayoutOrder = 7
	members.Visible = false
	members.Parent = panel
	_familyMembers = members

	local ml = Instance.new("UIListLayout")
	ml.FillDirection = Enum.FillDirection.Vertical
	ml.SortOrder = Enum.SortOrder.LayoutOrder
	ml.Padding = UDim.new(0, 1)
	ml.Parent = members
	makeLegend(members, "\u{25CF} where they are now")
end

-- ---------------------------------------------------------------- workers --
local function clearWorkers()
	for _, c in _workersList:GetChildren() do
		if c:IsA("Frame") then c:Destroy() end
	end
end

local function workerRow(order: number, w: { [string]: any })
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 18)
	row.LayoutOrder = order
	row.Parent = _workersList

	-- House button (right edge): fly the camera to where this worker LIVES (static).
	local homePos = w.homePos
	local hasHome = typeof(homePos) == "Vector3"
	local go = Instance.new("TextButton")
	go.Name = "GoHome"
	go.AnchorPoint = Vector2.new(1, 0.5)
	go.Position = UDim2.new(1, 0, 0.5, 0)
	go.Size = UDim2.fromOffset(18, 16)
	go.BackgroundTransparency = 1
	go.AutoButtonColor = false
	go.Text = "\u{2302}"
	go.TextColor3 = if hasHome then GREEN else Theme.Color.TextDisabled
	go.TextSize = Theme.TextSize.MD
	go.FontFace = Theme.Font.Bold
	go.Active = hasHome
	go.Parent = row
	if hasHome then
		go.Activated:Connect(function()
			if _freeCam and _freeCam.focusOn then _freeCam.focusOn(homePos) end
		end)
	end

	local nameL = Instance.new("TextLabel")
	nameL.BackgroundTransparency = 1
	nameL.Size = UDim2.new(0.50, 0, 1, 0)
	nameL.Text = "  " .. tostring(w.name) .. " " .. tostring(w.familyName)
	nameL.TextColor3 = Theme.Color.TextPrimary
	nameL.TextSize = Theme.TextSize.XS
	nameL.FontFace = Theme.Font.Header
	nameL.TextXAlignment = Enum.TextXAlignment.Left
	nameL.TextTruncate = Enum.TextTruncate.AtEnd
	nameL.Parent = row

	local key = if tostring(w.gender) == "M" then "M" else "F"
	local detail = Instance.new("TextLabel")
	detail.AnchorPoint = Vector2.new(1, 0)
	detail.Position = UDim2.new(1, -42, 0, 0)
	detail.BackgroundTransparency = 1
	detail.Size = UDim2.new(0.50, -42, 1, 0)
	detail.RichText = true
	detail.Text = string.format('%d yo  \u{00B7}  <font color="#%s">%s</font>', math.floor(tonumber(w.age) or 0), GENDER_HEX[key], GENDER_GLYPH[key])
	detail.TextColor3 = Theme.Color.TextSecondary
	detail.TextSize = Theme.TextSize.XS
	detail.FontFace = Theme.Font.Label
	detail.TextXAlignment = Enum.TextXAlignment.Right
	detail.Parent = row

	-- "Where are they now" locate dot (left of the green home arrow).
	local now = Instance.new("TextButton")
	now.Name = "WhereNow"
	now.AnchorPoint = Vector2.new(1, 0.5)
	now.Position = UDim2.new(1, -20, 0.5, 0)
	now.Size = UDim2.fromOffset(18, 16)
	now.BackgroundTransparency = 1
	now.AutoButtonColor = false
	now.Text = "\u{25CF}"
	now.TextColor3 = Theme.Color.Brand
	now.TextSize = Theme.TextSize.SM
	now.FontFace = Theme.Font.Bold
	now.Parent = row
	now.Activated:Connect(function()
		flyToCitizenNow(tonumber(w.pid))
	end)
end

local function renderWorkers(bpId: string)
	if not _net then return end
	local ok, info = pcall(function()
		return _net.RequestWorkforceInfo:InvokeServer(bpId)
	end)
	if _workersBpId ~= bpId or not _workersExpanded then return end
	clearWorkers()
	if ok and typeof(info) == "table" and typeof(info.workers) == "table" then
		for i, w in info.workers do workerRow(i, w) end
	end
end

local function toggleWorkers()
	if not _workersBpId then return end
	_workersExpanded = not _workersExpanded
	_workersValue.Text = (if _workersExpanded then "\u{25BE}  " else "\u{25B8}  ") .. tostring(_workersCount) .. " working here"
	_workersList.Visible = _workersExpanded
	if _workersExpanded and not _workersLoaded then
		_workersLoaded = true
		local bpId = _workersBpId
		task.spawn(function() renderWorkers(bpId) end)
	end
end

-- A "show traffic route" button shown on EVERY building panel.
local function buildRouteSection(panel: Instance)
	local btn = Instance.new("TextButton")
	btn.Name = "RouteButton"
	btn.Size = UDim2.new(1, 0, 0, 26)
	btn.LayoutOrder = 12
	btn.BackgroundColor3 = Color3.fromRGB(46, 52, 50)
	btn.BackgroundTransparency = 0.25
	btn.AutoButtonColor = true
	btn.Text = "\u{25B8} Show traffic route"
	btn.TextColor3 = Color3.fromRGB(90, 220, 140)
	btn.TextSize = Theme.TextSize.SM
	btn.FontFace = Theme.Font.Bold
	btn.Parent = panel
	local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 6); corner.Parent = btn
	_routeBtn = btn
	btn.Activated:Connect(function() if toggleRoute then toggleRoute() end end)
end

local function buildWorkersSection(panel: Instance)
	local row = Instance.new("Frame")
	row.Name = "WorkersRow"
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 18)
	row.LayoutOrder = 9
	row.Visible = false
	row.Parent = panel
	_workersRow = row

	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(0.35, 0, 1, 0)
	l.Text = "Workers"
	l.TextColor3 = Theme.Color.TextSecondary
	l.TextSize = Theme.TextSize.SM
	l.FontFace = Theme.Font.Label
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = row

	local btn = Instance.new("TextButton")
	btn.Name = "WorkersValue"
	btn.AnchorPoint = Vector2.new(1, 0)
	btn.Position = UDim2.fromScale(1, 0)
	btn.Size = UDim2.new(0.65, 0, 1, 0)
	btn.BackgroundTransparency = 1
	btn.AutoButtonColor = false
	btn.Text = ""
	btn.TextColor3 = ZONE_COLOR.Commercial
	btn.TextSize = Theme.TextSize.SM
	btn.FontFace = Theme.Font.Bold
	btn.TextXAlignment = Enum.TextXAlignment.Right
	btn.TextTruncate = Enum.TextTruncate.AtEnd
	btn.Parent = row
	_workersValue = btn
	btn.Activated:Connect(toggleWorkers)

	local list = Instance.new("Frame")
	list.Name = "WorkersList"
	list.BackgroundTransparency = 1
	list.AutomaticSize = Enum.AutomaticSize.Y
	list.Size = UDim2.new(1, 0, 0, 0)
	list.LayoutOrder = 10
	list.Visible = false
	list.Parent = panel

	local ml = Instance.new("UIListLayout")
	ml.FillDirection = Enum.FillDirection.Vertical
	ml.SortOrder = Enum.SortOrder.LayoutOrder
	ml.Padding = UDim.new(0, 1)
	ml.Parent = list
	makeLegend(list, "\u{2302} home   \u{25CF} where now")
	_workersList = list
end

local function buildPanel(gui: ScreenGui)
	local panel = Instance.new("CanvasGroup")
	panel.Name = "BuildingInfo"
	panel.AnchorPoint = Vector2.new(0, 0)
	panel.Position = UDim2.new(0, 12, 0, 64)
	panel.Size = UDim2.fromOffset(266, 0)
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

	-- Header
	local header = Instance.new("Frame")
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 40)
	header.LayoutOrder = 1
	header.Parent = panel

	local dot = Instance.new("Frame")
	dot.Size = UDim2.fromOffset(10, 10)
	dot.Position = UDim2.fromOffset(0, 5)
	dot.BackgroundColor3 = ZONE_COLOR.Residential
	dot.BorderSizePixel = 0
	dot.Parent = header
	corner(dot, 5)
	_accentDot = dot

	local nameLbl = Instance.new("TextLabel")
	nameLbl.BackgroundTransparency = 1
	nameLbl.Position = UDim2.fromOffset(18, 0)
	nameLbl.Size = UDim2.new(1, -64, 0, 20)
	nameLbl.Text = "Building"
	nameLbl.TextColor3 = Theme.Color.TextPrimary
	nameLbl.TextSize = Theme.TextSize.MD
	nameLbl.FontFace = Theme.Font.Bold
	nameLbl.TextXAlignment = Enum.TextXAlignment.Left
	nameLbl.Parent = header
	_name = nameLbl

	local numberLbl = Instance.new("TextLabel")
	numberLbl.BackgroundTransparency = 1
	numberLbl.Position = UDim2.fromOffset(18, 20)
	numberLbl.Size = UDim2.new(1, -64, 0, 16)
	numberLbl.Text = ""
	numberLbl.TextColor3 = Theme.Color.TextSecondary
	numberLbl.TextSize = Theme.TextSize.XS
	numberLbl.FontFace = Theme.Font.Label
	numberLbl.TextXAlignment = Enum.TextXAlignment.Left
	numberLbl.Parent = header
	_number = numberLbl

	local levelLbl = Instance.new("TextLabel")
	levelLbl.AnchorPoint = Vector2.new(1, 1)
	levelLbl.Position = UDim2.new(1, 0, 1, 0)
	levelLbl.Size = UDim2.fromOffset(44, 18)
	levelLbl.BackgroundColor3 = Theme.Color.BgRaised
	levelLbl.Text = "Lv 1"
	levelLbl.TextColor3 = Theme.Color.TextSecondary
	levelLbl.TextSize = Theme.TextSize.XS
	levelLbl.FontFace = Theme.Font.Bold
	levelLbl.Parent = header
	corner(levelLbl, 4)
	_level = levelLbl

	local closeBtn = IconButton.new({
		icon = Icons.Close,
		name = "Close",
		size = 22,
		parent = header,
		onClick = function() BuildingInfoController.Close() end,
	})
	closeBtn.Instance.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Instance.Position = UDim2.fromScale(1, 0)

	local desc = Instance.new("TextLabel")
	desc.BackgroundTransparency = 1
	desc.Size = UDim2.new(1, 0, 0, 30)
	desc.LayoutOrder = 2
	desc.Text = ""
	desc.TextColor3 = Theme.Color.TextSecondary
	desc.TextSize = Theme.TextSize.XS
	desc.FontFace = Theme.Font.Label
	desc.TextWrapped = true
	desc.TextXAlignment = Enum.TextXAlignment.Left
	desc.TextYAlignment = Enum.TextYAlignment.Top
	desc.Parent = panel
	_desc = desc

	local div = Instance.new("Frame")
	div.BackgroundColor3 = Theme.Color.StrokeSoft
	div.BorderSizePixel = 0
	div.Size = UDim2.new(1, 0, 0, 1)
	div.LayoutOrder = 3
	div.Parent = panel

	local occRow = Instance.new("Frame")
	occRow.BackgroundTransparency = 1
	occRow.Size = UDim2.new(1, 0, 0, 18)
	occRow.LayoutOrder = 4
	occRow.Parent = panel
	local occLabel = Instance.new("TextLabel")
	occLabel.BackgroundTransparency = 1
	occLabel.Size = UDim2.new(0.5, 0, 1, 0)
	occLabel.Text = "Residents"
	occLabel.TextColor3 = Theme.Color.TextSecondary
	occLabel.TextSize = Theme.TextSize.SM
	occLabel.FontFace = Theme.Font.Label
	occLabel.TextXAlignment = Enum.TextXAlignment.Left
	occLabel.Parent = occRow
	_occLabel = occLabel
	local occValue = Instance.new("TextLabel")
	occValue.AnchorPoint = Vector2.new(1, 0)
	occValue.Position = UDim2.fromScale(1, 0)
	occValue.BackgroundTransparency = 1
	occValue.Size = UDim2.new(0.5, 0, 1, 0)
	occValue.Text = "0 / 0"
	occValue.TextColor3 = Theme.Color.TextPrimary
	occValue.TextSize = Theme.TextSize.SM
	occValue.FontFace = Theme.Font.Header
	occValue.TextXAlignment = Enum.TextXAlignment.Right
	occValue.Parent = occRow
	_occValue = occValue

	local track = Instance.new("Frame")
	track.Size = UDim2.new(1, 0, 0, 6)
	track.BackgroundColor3 = Theme.Color.BgPress
	track.BorderSizePixel = 0
	track.ClipsDescendants = true
	track.LayoutOrder = 5
	track.Parent = panel
	corner(track, 3)
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = ZONE_COLOR.Residential
	fill.BorderSizePixel = 0
	fill.Parent = track
	corner(fill, 3)
	_occFill = fill

	local sellRow, sellLabel, sellValue = infoRow2(panel, 6, "Sells")
	_sellRow, _sellLabel, _sellValue = sellRow, sellLabel, sellValue
	sellRow.Visible = false

	local stockRow, stockLabel, stockValue = infoRow2(panel, 7, "Stock")
	_stockRow, _stockLabel, _stockValue = stockRow, stockLabel, stockValue
	stockRow.Visible = false

	local earnRow, _, earnValue = infoRow2(panel, 8, "Earns / mo")
	_earnRow, _earnValue = earnRow, earnValue
	earnRow.Visible = false

	_status = infoRow(panel, 9, "Status")
	_status.FontFace = Theme.Font.Bold

	buildFamilySection(panel)
	buildWorkersSection(panel)
	buildRouteSection(panel)
end

-- Fill the panel for a service building (emergency station or school / library). These
-- share a layout: a headline metric + bar, two detail rows (reusing the supply-chain
-- rows) and a status line. No family / workers / supply sections.
local function populateServicePanel(info: { [string]: any })
	_familyRow.Visible = false
	_workersRow.Visible = false
	_familyMembers.Visible = false
	_workersList.Visible = false
	if _earnRow then _earnRow.Visible = false end
	-- Emergency stations and utilities are not trip destinations -- no commuter route to draw.
	if _routeBtn then _routeBtn.Visible = info.zone ~= "Service" end

	if info.zone == "School" then
		local kind = tostring(info.schoolKind)
		local isLibrary = info.category == "Library" or info.capacity <= 0
		_number.Text = "Education  \u{00B7}  " .. (if info.category == "Library" then "Library" else "School")
		_level.Text = ""
		_desc.Text = EDU_DESC[kind] or ""
		if isLibrary then
			_occLabel.Text = "Service"
			_occValue.Text = "Education boost"
			_occFill.Size = UDim2.fromScale(1, 1)
			_sellRow.Visible = true
			_sellLabel.Text = "Coverage"
			_sellValue.Text = tostring(math.floor(info.coverage)) .. " studs"
			_stockRow.Visible = false
			_status.Text = "Operating"
			_status.TextColor3 = GREEN
		else
			_occLabel.Text = "Pupils"
			_occValue.Text = tostring(info.occupants) .. " / " .. tostring(info.capacity)
			_occFill.Size = UDim2.fromScale(math.clamp(info.occupants / info.capacity, 0, 1), 1)
			_sellRow.Visible = true
			_sellLabel.Text = "Ages"
			_sellValue.Text = tostring(info.ageMin) .. "\u{2013}" .. tostring(info.ageMax)
			_stockRow.Visible = true
			_stockLabel.Text = "Coverage"
			_stockValue.Text = tostring(math.floor(info.coverage)) .. " studs"
			if info.occupants >= info.capacity then
				_status.Text = "Full"; _status.TextColor3 = Theme.Color.Danger
			elseif info.occupants <= 0 then
				_status.Text = "No pupils yet"; _status.TextColor3 = Theme.Color.TextSecondary
			else
				_status.Text = "Space available"; _status.TextColor3 = GREEN
			end
		end
		return
	end

	-- Utilities (generators) read as output, not coverage.
	local spec = ServiceTypes.get(info.serviceType) :: any
	local output = spec and tonumber(spec.powerOutput) or 0
	if output > 0 then
		_number.Text = "Utility  \u{00B7}  Power"
		_level.Text = ""
		_desc.Text = tostring(spec.desc or "")
		_occLabel.Text = if spec.solar then "Output (noon peak)" else "Output"
		_occValue.Text = string.format("%.1f MW", output / 1000)
		_occFill.Size = UDim2.fromScale(1, 1)
		_sellRow.Visible = true
		_sellLabel.Text = "Yard radius"
		_sellValue.Text = tostring(math.floor(info.coverage)) .. " studs"
		_stockRow.Visible = false
		_status.Text = if spec.solar then "Follows the sun" else "Generating"
		_status.TextColor3 = GREEN
		return
	end

	-- Emergency service.
	_number.Text = "Emergency Service  \u{00B7}  " .. tostring(info.serviceKind)
	_level.Text = ""
	_desc.Text = SERVICE_DESC[info.serviceKind] or ""
	_occLabel.Text = "Coverage radius"
	_occValue.Text = tostring(math.floor(info.coverage)) .. " studs"
	_occFill.Size = UDim2.fromScale(1, 1)
	_sellRow.Visible = true
	_sellLabel.Text = "Provides"
	_sellValue.Text = SERVICE_PROVIDES[info.serviceKind] or "Coverage"
	_stockRow.Visible = false
	_status.Text = "Operating"
	_status.TextColor3 = GREEN
end

local function populatePanel(model: Model, info: { [string]: any }, bpId: string)
	local zone = info.zone
	local color = accentColor(info)
	_accentDot.BackgroundColor3 = color
	_occFill.BackgroundColor3 = color
	_name.Text = nameFor(zone, info.level, info)

	-- Service buildings (emergency + education) use the simpler shared panel.
	if zone == "Service" or zone == "School" then
		populateServicePanel(info)
		return
	end

	-- Real street address off the road the building fronts, derived locally from the
	-- replicated road graph. Falls back to the old bare number for anything the road
	-- network can't place (a building whose street was bulldozed out from under it).
	local address: string? = nil
	local okAddr, resolved = pcall(function()
		local index = AddressBook.buildIndex(DataCache.GetSegments())
		return AddressBook.addressOfPoint(index, model:GetPivot().Position, ADDRESS_MAX_ROAD_DIST)
	end)
	if okAddr and typeof(resolved) == "string" then address = resolved end
	_number.Text = (address or ("No. " .. tostring(numberFor(bpId)))) .. "  \u{00B7}  " .. zone
	_level.Text = "Lv " .. tostring(info.level)
	_desc.Text = DESC[zone] or ""
	_occLabel.Text = if info.kind == "jobs" then "Jobs" else "Residents"
	_occValue.Text = tostring(info.occupants) .. " / " .. tostring(info.capacity)
	_occFill.Size = UDim2.fromScale(if info.capacity > 0 then math.clamp(info.occupants / info.capacity, 0, 1) else 0, 1)
	-- Supply chain: what the building sells/produces + the stock it holds (a shop's shelves,
	-- a plant's yard).
	local product = model:GetAttribute("Product")
	if typeof(product) == "string" and product ~= "" and (zone == "Commercial" or zone == "Industrial") then
		_sellRow.Visible = true
		_sellLabel.Text = if zone == "Industrial" then "Produces" else "Sells"
		_sellValue.Text = product
		local stock = math.floor(tonumber(model:GetAttribute("Stock")) or 0)
		local stockCap = math.floor(tonumber(model:GetAttribute("StockCap")) or 0)
		_stockRow.Visible = true
		_stockLabel.Text = if zone == "Industrial" then "In yard" else "Stock"
		_stockValue.Text = tostring(stock) .. " / " .. tostring(stockCap)
	else
		_sellRow.Visible = false
		_stockRow.Visible = false
	end

	-- Family (residential homes only): show "the <name> family", clickable to expand
	-- into the full roster, fetched on demand. Reset to collapsed on each (re)select.
	local familyName = model:GetAttribute("FamilyName")
	_familyExpanded = false
	_familyLoaded = false
	_familyMembers.Visible = false
	clearMembers()
	if zone == "Residential" and typeof(familyName) == "string" and familyName ~= "" then
		_familyName = if info.households > 1
			then string.format("%d of %d households", info.households, info.householdCap)
			else familyName .. " family"
		_familyBpId = bpId
		_familyRow.Visible = true
		_familyValue.Text = "\u{25B8}  " .. _familyName
		_familyValue.TextColor3 = color
	else
		_familyName = nil
		_familyBpId = nil
		_familyRow.Visible = false
	end

	-- Workers (commercial/industrial): expandable roster, each row an arrow to the home.
	_workersExpanded = false
	_workersLoaded = false
	_workersList.Visible = false
	clearWorkers()
	if (zone == "Commercial" or zone == "Industrial") and info.occupants > 0 then
		_workersBpId = bpId
		_workersCount = info.occupants
		_workersRow.Visible = true
		_workersValue.Text = "\u{25B8}  " .. tostring(info.occupants) .. " working here"
		_workersValue.TextColor3 = color
	else
		_workersBpId = nil
		_workersRow.Visible = false
	end

	-- Estimated monthly tax this building contributes to the city (residents x per-resident,
	-- or filled jobs x per-job for its product). A live "how much it's producing" readout.
	local earn = 0
	if not info.abandoned then
		if zone == "Residential" then
			earn = info.occupants * _perUnit.res
		elseif zone == "Commercial" then
			earn = info.occupants * (_perUnit.comm[product] or 0)
		elseif zone == "Industrial" then
			earn = info.occupants * (_perUnit.ind[product] or 0)
		end
	end
	_earnRow.Visible = true
	_earnValue.Text = "+$" .. commaInt(earn)
	_earnValue.TextColor3 = if earn > 0 then GREEN else Theme.Color.TextSecondary

	if _routeBtn then _routeBtn.Visible = true end

	local text, scolor = statusOf(info)
	_status.Text = text
	_status.TextColor3 = scolor
end

-- ---------------------------------------------------------------- hover --
local function hidePreview()
	if _hoverModel then
		if _hoverModel ~= _selectedModel then _hoverHL.Adornee = nil end
		_hoverModel = nil
	end
	UITween.to(_preview, "Tooltip", { GroupTransparency = 1 })
	_preview.Visible = false
end

-- Idle while ANY build tool owns the cursor: an open build section, or the
-- top-level bulldoze tool (whose click deletes -- the info panel must not also
-- open on that same click).
local function sectionActive(): boolean
	if _bottomBar == nil then
		return false
	end
	if _bottomBar.GetActiveSection and _bottomBar.GetActiveSection() ~= nil then
		return true
	end
	if _bottomBar.IsBulldozeActive and _bottomBar.IsBulldozeActive() then
		return true
	end
	return false
end

-- `input` drives the ray; its raw Position still drives the preview placement below --
-- the preview lives on an IgnoreGuiInset = false gui, which is the space input.Position
-- is already in. The two conventions differ, so do not collapse them back into one value.
-- Every Kit.Modal parks a full-screen scrim under PlayerGui.UIModalOverlay and hides
-- it again on close, so one visible child there means a window owns the screen. The
-- city behind it is not hoverable -- neither through the panel nor around it.
local function modalOpen(): boolean
	local pgui = if _hudGui then _hudGui.Parent else nil
	local overlay = if pgui then pgui:FindFirstChild("UIModalOverlay") else nil
	if not overlay then return false end
	for _, child in overlay:GetChildren() do
		if child:IsA("GuiObject") and child.Visible then return true end
	end
	return false
end
-- gameProcessed is the cheap "cursor is over UI" test: any panel, dock or bar under
-- the pointer sinks the movement, so the chip stops answering for things behind it.
local function updateHover(input: InputObject, gameProcessed: boolean?)
	if not _hudGui.Enabled or sectionActive() or gameProcessed or modalOpen() then
		hidePreview()
		return
	end

	local model = getBuildingAt(input)
	if not model then
		hidePreview()
		return
	end

	local info = readInfo(model)
	if not info then
		hidePreview()
		return
	end

	if model ~= _hoverModel then
		if _hoverModel and _hoverModel ~= _selectedModel then _hoverHL.Adornee = nil end
		_hoverModel = model
		local color = accentColor(info)
		if model ~= _selectedModel then
			_hoverHL.OutlineColor = color
			_hoverHL.Adornee = model
		end
		_chipNameBadge.BackgroundColor3 = color
		_chipName.Text = nameFor(info.zone, info.level, info)
		if info.zone == "Service" then
			_chipLevel.Text = tostring(info.serviceKind)
			_chipOcc.Text = "Coverage  " .. tostring(math.floor(info.coverage)) .. " st"
			_chipOccGlyph.Text = "\u{25CE}"
		elseif info.zone == "School" then
			_chipLevel.Text = if info.category == "Library" then "Library" else "School"
			_chipOcc.Text = if info.category == "Library" or info.capacity <= 0
				then "Education boost"
				else "Pupils  " .. tostring(info.occupants) .. "/" .. tostring(info.capacity)
			_chipOccGlyph.Text = "\u{25CE}"
		elseif info.kind == "jobs" then
			_chipLevel.Text = "Level " .. tostring(info.level)
			_chipOcc.Text = "Jobs  " .. tostring(info.occupants)
			_chipOccGlyph.Text = "\u{25A0}"
		else
			_chipLevel.Text = "Level " .. tostring(info.level)
			_chipOcc.Text = "Residents  " .. tostring(info.occupants)
				.. (if info.householdCap > 0 then "  \u{00B7}  " .. tostring(info.households) .. "/" .. tostring(info.householdCap) .. " hh" else "")
			_chipOccGlyph.Text = "\u{25CF}"
		end
		_preview.Visible = true
		UITween.to(_preview, "Tooltip", { GroupTransparency = 0 })
	end

	_preview.Position = UDim2.fromOffset(input.Position.X + 18, input.Position.Y + 14)
end

-- ---------------------------------------------------------------- select --
-- "Traffic source": while a house is selected, draw a beam from it to the outside
-- connection nearest it, so you can SEE where its residents drove in from. Client-only,
-- cleared on close. (Nearest by straight line; swap to the exact arrival connection if the
-- server starts stamping one on the building.)
local _trafficVis: { Instance } = {}
local function clearTrafficSource()
	for _, inst in _trafficVis do inst:Destroy() end
	table.clear(_trafficVis)
	_routeShown = false
	if _routeBtn then _routeBtn.Text = "\u{25B8} Show traffic route" end
end
-- Draw the ROAD route from the building back to its nearest outside connection (the path
-- its traffic actually takes), via the server nav graph. One invisible anchor part + Beams
-- (GPU-cheap) keeps it light; labels the route with the connection it comes from.
local function drawRoute(model: Model)
	clearTrafficSource()
	_routeShown = true
	if _routeBtn then _routeBtn.Text = "\u{25BE} Hide traffic route" end
	if not _net then return end
	local folder = Workspace:FindFirstChild("_OutsideConnections")
	if not folder then return end
	local hp = model:GetPivot().Position
	local best, bestSide, bestD = nil, "Outside", math.huge
	for _, m in folder:GetChildren() do
		local cp = m:GetPivot().Position
		local dx, dz = cp.X - hp.X, cp.Z - hp.Z
		local d = dx * dx + dz * dz
		if d < bestD then bestD = d; best = cp; bestSide = tostring(m:GetAttribute("Side") or "Outside") end
	end
	if not best then return end
	_routeReq += 1
	local req = _routeReq
	task.spawn(function()
		local ok, wps = pcall(function() return _net.RequestNavPath:InvokeServer(best, hp) end)
		if req ~= _routeReq or not _routeShown then return end
		if not ok or typeof(wps) ~= "table" or #wps < 2 then wps = { best, hp } end
		local COL = Color3.fromRGB(90, 220, 140)
		local container = Instance.new("Part")
		container.Anchored = true; container.CanCollide = false; container.CanQuery = false; container.CanTouch = false
		container.Transparency = 1; container.Size = Vector3.one; container.CFrame = CFrame.new(); container.Parent = Workspace
		table.insert(_trafficVis, container)
		local function att(pos: Vector3): Attachment
			local a = Instance.new("Attachment"); a.WorldPosition = pos + Vector3.new(0, 3, 0); a.Parent = container; return a
		end
		local step = math.max(1, math.floor(#wps / 50)) -- cap the beam count
		local prev: Attachment? = nil
		for i = 1, #wps, step do
			local a = att(wps[i])
			if prev then
				local beam = Instance.new("Beam")
				beam.Attachment0 = prev; beam.Attachment1 = a
				beam.Width0 = 2; beam.Width1 = 2
				beam.FaceCamera = true
				beam.Color = ColorSequence.new(COL)
				beam.LightEmission = 0.6
				beam.Transparency = NumberSequence.new(0.15)
				beam.Parent = container
				table.insert(_trafficVis, beam)
			end
			prev = a
		end
		local ball = Instance.new("Part")
		ball.Shape = Enum.PartType.Ball; ball.Size = Vector3.new(7, 7, 7)
		ball.Anchored = true; ball.CanCollide = false; ball.CanQuery = false; ball.CanTouch = false
		ball.Material = Enum.Material.Neon; ball.Color = COL; ball.Transparency = 0.35
		ball.CFrame = CFrame.new(best + Vector3.new(0, 6, 0)); ball.Parent = Workspace
		table.insert(_trafficVis, ball)
		local bb = Instance.new("BillboardGui")
		bb.Size = UDim2.fromOffset(160, 26); bb.StudsOffsetWorldSpace = Vector3.new(0, 7, 0)
		bb.AlwaysOnTop = true; bb.Parent = ball
		local txt = Instance.new("TextLabel")
		txt.BackgroundTransparency = 1; txt.Size = UDim2.fromScale(1, 1)
		txt.Font = Enum.Font.GothamBold; txt.TextSize = 15; txt.TextColor3 = COL
		txt.Text = bestSide .. " route"
		txt.Parent = bb
	end)
end

toggleRoute = function()
	if _routeShown then
		clearTrafficSource()
	elseif _selectedModel then
		drawRoute(_selectedModel)
	end
end

function BuildingInfoController.Close()
	_open = false
	_selectedModel = nil
	_selectHL.Adornee = nil
	clearTrafficSource()
	if _selConn then _selConn:Disconnect(); _selConn = nil end
	local tween = UITween.to(_panel, "Flyout", { GroupTransparency = 1 })
	tween.Completed:Once(function()
		if not _open then _panel.Visible = false end
	end)
end

local function selectBuilding(model: Model, bpId: string)
	local info = readInfo(model)
	if not info then return end
	_selectedModel = model
	local color = accentColor(info)
	_selectHL.OutlineColor = color
	_selectHL.Adornee = model
	if _hoverModel == model then _hoverHL.Adornee = nil end

	populatePanel(model, info, bpId)
	clearTrafficSource()
	_open = true
	_panel.Visible = true
	UITween.to(_panel, "Flyout", { GroupTransparency = 0 })

	-- Live-refresh the open panel as occupancy/level change.
	if _selConn then _selConn:Disconnect() end
	_selConn = model.AttributeChanged:Connect(function(attr: string)
		if attr == "Occupants" or attr == "Capacity" or attr == "Level" or attr == "Abandoned" or attr == "Stock" or attr == "Product" or attr == "StockCap" or attr == "FamilyName" or attr == "Households" or attr == "HouseholdCap" then
			local fresh = readInfo(model)
			if fresh then populatePanel(model, fresh, bpId) end
		end
	end)
end

local function onClick(input: InputObject)
	if not _hudGui.Enabled or sectionActive() or modalOpen() then return end
	local model = getBuildingAt(input)
	if model then
		-- Zoned buildings use BlueprintId; emergency use ServiceId; schools use SchoolId.
		local id = model:GetAttribute("BlueprintId") or model:GetAttribute("ServiceId") or model:GetAttribute("SchoolId")
		selectBuilding(model, tostring(id))
	elseif _open then
		BuildingInfoController.Close()
	end
end

function BuildingInfoController.Start()
	if _started then return end
	_started = true

	local okNet, net = pcall(function() return require(ReplicatedStorage:WaitForChild("Networker")) end)
	_net = if okNet then net else nil
	local okFc, fc = pcall(function() return require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("FreeCamController")) end)
	_freeCam = if okFc then fc else nil

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local gui = playerGui:WaitForChild("CityUI", 60)
	if not gui or not gui:IsA("ScreenGui") then
		warn("[BuildingInfoController] CityUI not found")
		_started = false
		return
	end
	_hudGui = gui

	local pgui = Instance.new("ScreenGui")
	pgui.Name = "BuildingHover"
	pgui.ResetOnSpawn = false
	pgui.IgnoreGuiInset = false
	pgui.DisplayOrder = Theme.Layer.WorldTag
	pgui.Parent = playerGui
	HudScale.attach(pgui)
	_previewGui = pgui

	buildPreview(pgui)
	buildPanel(gui)

	require(ReplicatedStorage:WaitForChild("City"):WaitForChild("UIEvents")).SettingsOpened.Event:Connect(function()
		BuildingInfoController.Close()
	end)

	-- Track per-unit tax (income/units) from the economy so the panel can show each
	-- building's monthly contribution without a per-building network round-trip.
	if _net and _net.SyncEconomy then
		_net.SyncEconomy.OnClientEvent:Connect(function(p: any)
			if typeof(p) ~= "table" or typeof(p.taxBreakdown) ~= "table" then return end
			local tb = p.taxBreakdown
			local rInc, rUnits = 0, 0
			if typeof(tb.residential) == "table" then
				for _, e in tb.residential do rInc += (tonumber(e.income) or 0); rUnits += (tonumber(e.units) or 0) end
			end
			_perUnit.res = if rUnits > 0 then rInc / rUnits else 0
			_perUnit.comm = {}
			if typeof(tb.commercial) == "table" then
				for _, e in tb.commercial do
					local u = tonumber(e.units) or 0
					if e.key then _perUnit.comm[e.key] = if u > 0 then (tonumber(e.income) or 0) / u else 0 end
				end
			end
			_perUnit.ind = {}
			if typeof(tb.industrial) == "table" then
				for _, e in tb.industrial do
					local u = tonumber(e.units) or 0
					if e.key then _perUnit.ind[e.key] = if u > 0 then (tonumber(e.income) or 0) / u else 0 end
				end
			end
		end)
	end

	local hoverHL = Instance.new("Highlight")
	hoverHL.Name = "BuildingHover"
	hoverHL.FillTransparency = 0.92
	hoverHL.OutlineTransparency = 0.35
	hoverHL.DepthMode = Enum.HighlightDepthMode.Occluded
	hoverHL.Adornee = nil
	hoverHL.Parent = gui
	_hoverHL = hoverHL

	local selectHL = Instance.new("Highlight")
	selectHL.Name = "BuildingSelect"
	selectHL.FillTransparency = 0.82
	selectHL.OutlineTransparency = 0
	selectHL.DepthMode = Enum.HighlightDepthMode.Occluded
	selectHL.Adornee = nil
	selectHL.Parent = gui
	_selectHL = selectHL

	local controllers = script.Parent.Parent:WaitForChild("Controllers")
	local ok, bb = pcall(function()
		return require(controllers:WaitForChild("BottomBarController"))
	end)
	_bottomBar = if ok then bb else nil

	UserInputService.InputChanged:Connect(function(input: InputObject, gameProcessed: boolean)
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			updateHover(input, gameProcessed)
		end
	end)

	-- The cursor leaves a building without moving whenever the camera pans: the world
	-- slides out from under a still mouse and InputChanged never fires, so the chip
	-- stuck over open ground. Only rays while something is actually hovered.
	local camera = Workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("CFrame"):Connect(function()
			if _hoverModel and getBuildingAt(nil) ~= _hoverModel then hidePreview() end
		end)
	end
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then hidePreview() return end
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			onClick(input)
		end
	end)
end

return BuildingInfoController
