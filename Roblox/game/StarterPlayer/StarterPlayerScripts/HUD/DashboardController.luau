--!strict
-- City dashboard: a slide-in side panel with Overview / Economy / Population
-- tabs. Read-only deep stats fed live by SyncCityStats + SyncEconomy. Opened
-- from the top status bar (HUDController). No server writes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local uiFolder = script.Parent.Parent:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local Format = require(uiFolder:WaitForChild("Format"))
local Icons = require(uiFolder:WaitForChild("Icons"))
local UITween = require(uiFolder:WaitForChild("UITween"))
local PanelSlots = require(uiFolder:WaitForChild("PanelSlots"))
local HudScale = require(uiFolder:WaitForChild("HudScale"))
local kit = uiFolder:WaitForChild("Kit")
local Glass = require(kit:WaitForChild("Glass"))
local Tab = require(kit:WaitForChild("Tab"))
local IconButton = require(kit:WaitForChild("IconButton"))

local DashboardController = {}

local PANEL_W = 320
local PANEL_MIN_H = 320
local PANEL_BOTTOM = 16 -- gap kept under the panel
-- 124 clears the right-edge pill stack (LaneView at y48-78, NodeTool at y84-114) which
-- sits in front of this panel. Both now ride HudScale too, so the clearance holds at
-- every viewport rather than only at the design size.
local PANEL_TOP = 124
local GREEN = Color3.fromRGB(120, 220, 140)
local RED = Color3.fromRGB(230, 110, 110)
local DEMAND_COLOR = {
	R = Color3.fromRGB(82, 196, 110),
	C = Color3.fromRGB(70, 160, 230),
	I = Color3.fromRGB(220, 185, 55),
}

local _started = false
local _panel: CanvasGroup? = nil
local _open = false
local _tabs: { [string]: Tab.Tab } = {}
local _pages: { [string]: Frame } = {}
local _activeTab = "Overview"

-- Live value setters, populated as rows are built.
local _set: { [string]: (any) -> () } = {}

-- Networker, assigned in Start() before the panel is built so the budget sliders can fire.
local Net: any = nil

local TAX_MIN, TAX_MAX = -5, 29 -- mirrors CitySimConstants.TAX_MIN/MAX_RATE
local FUND_MIN, FUND_MAX = 50, 150 -- mirrors CitySimConstants.FUNDING_MIN/MAX_PCT

local function corner(inst: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = inst
end




-- One label/value row. Returns the value TextLabel for live updates.
local function statRow(parent: Instance, order: number, labelText: string, big: boolean?): TextLabel
	local row = Instance.new("Frame")
	row.Name = labelText
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, if big then 34 else 24)
	row.LayoutOrder = order
	row.Parent = parent

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0, 0.5)
	label.Position = UDim2.fromScale(0, 0.5)
	label.Size = UDim2.new(0.55, 0, 1, 0)
	label.Text = labelText
	label.TextColor3 = Theme.Color.TextSecondary
	label.TextSize = Theme.TextSize.SM
	label.FontFace = Theme.Font.Label
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = row

	local value = Instance.new("TextLabel")
	value.Name = "Value"
	value.BackgroundTransparency = 1
	value.AnchorPoint = Vector2.new(1, 0.5)
	value.Position = UDim2.fromScale(1, 0.5)
	value.Size = UDim2.new(0.45, 0, 1, 0)
	value.Text = "\u{2014}"
	value.TextColor3 = Theme.Color.TextPrimary
	value.TextSize = if big then Theme.TextSize.LG else Theme.TextSize.SM
	value.FontFace = if big then Theme.Font.Bold else Theme.Font.Header
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.Parent = row

	return value
end

-- A labelled progress bar (0..1). Returns (fill, value) for live updates.
local function barRow(parent: Instance, order: number, labelText: string, color: Color3): (Frame, TextLabel)
	local row = Instance.new("Frame")
	row.Name = labelText
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 32)
	row.LayoutOrder = order
	row.Parent = parent

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 0, 16)
	label.Text = labelText
	label.TextColor3 = Theme.Color.TextSecondary
	label.TextSize = Theme.TextSize.XS
	label.FontFace = Theme.Font.Label
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = row

	local value = Instance.new("TextLabel")
	value.Name = "Value"
	value.BackgroundTransparency = 1
	value.Size = UDim2.new(1, 0, 0, 16)
	value.Text = "0%"
	value.TextColor3 = Theme.Color.TextPrimary
	value.TextSize = Theme.TextSize.XS
	value.FontFace = Theme.Font.Header
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.Parent = row

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0, 1)
	track.Position = UDim2.fromScale(0, 1)
	track.Size = UDim2.new(1, 0, 0, 6)
	track.BackgroundColor3 = Theme.Color.BgPress
	track.BorderSizePixel = 0
	track.ClipsDescendants = true
	track.Parent = row
	corner(track, 3)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.Parent = track
	corner(fill, 3)

	return fill, value
end

-- A labelled integer slider (min..max, percent). onChange(value, final) fires while
-- dragging (final=false) and once on release (final=true). Returns (setValue, isDragging):
-- setValue reflects the server's authoritative rate; it no-ops while the user drags so
-- the 1 Hz echo never yanks the handle out from under them.
local function sliderRow(parent: Instance, order: number, labelText: string, color: Color3, minV: number, maxV: number, onChange: (number, boolean) -> ()): ((number) -> (), () -> boolean)
	local row = Instance.new("Frame")
	row.Name = labelText
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 40)
	row.LayoutOrder = order
	row.Parent = parent

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(0.7, 0, 0, 16)
	label.Text = labelText
	label.TextColor3 = Theme.Color.TextSecondary
	label.TextSize = Theme.TextSize.XS
	label.FontFace = Theme.Font.Label
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = row

	local value = Instance.new("TextLabel")
	value.Name = "Value"
	value.BackgroundTransparency = 1
	value.AnchorPoint = Vector2.new(1, 0)
	value.Position = UDim2.fromScale(1, 0)
	value.Size = UDim2.new(0.3, 0, 0, 16)
	value.Text = "0%"
	value.TextColor3 = Theme.Color.TextPrimary
	value.TextSize = Theme.TextSize.XS
	value.FontFace = Theme.Font.Header
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.Parent = row

	local track = Instance.new("TextButton")
	track.Name = "Track"
	track.AutoButtonColor = false
	track.Text = ""
	track.AnchorPoint = Vector2.new(0, 1)
	track.Position = UDim2.fromScale(0, 1)
	track.Size = UDim2.new(1, 0, 0, 8)
	track.BackgroundColor3 = Theme.Color.BgPress
	track.BorderSizePixel = 0
	track.Parent = row
	corner(track, 4)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.Parent = track
	corner(fill, 4)

	local handle = Instance.new("Frame")
	handle.Name = "Handle"
	handle.AnchorPoint = Vector2.new(0.5, 0.5)
	handle.Position = UDim2.fromScale(0, 0.5)
	handle.Size = UDim2.fromOffset(14, 14)
	handle.BackgroundColor3 = Color3.fromRGB(245, 246, 248)
	handle.BorderSizePixel = 0
	handle.ZIndex = 2
	handle.Parent = track
	corner(handle, 7)

	local current = minV
	local dragging = false
	local releaseTime = -math.huge   -- os.clock() when the user last released

	local function render()
		local frac = if maxV > minV then (current - minV) / (maxV - minV) else 0
		fill.Size = UDim2.fromScale(frac, 1)
		handle.Position = UDim2.fromScale(frac, 0.5)
		value.Text = tostring(current) .. "%"
	end

	local function setFromX(px: number, final: boolean)
		local rel = math.clamp((px - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X), 0, 1)
		local v = math.floor(minV + rel * (maxV - minV) + 0.5)
		if v ~= current or final then
			current = v
			render()
			if onChange then onChange(current, final) end
		end
	end

	track.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			setFromX(input.Position.X, false)
		end
	end)
	UserInputService.InputChanged:Connect(function(input: InputObject)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			setFromX(input.Position.X, false)
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
			dragging = false
			setFromX(input.Position.X, true)
		end
	end)

	render()

	local function setValue(v: number)
		if dragging then return end
		current = math.clamp(math.floor((tonumber(v) or minV) + 0.5), minV, maxV)
		render()
	end
	return setValue, function() return dragging end
end

local function sectionLabel(parent: Instance, order: number, text: string)
	local label = Instance.new("TextLabel")
	label.Name = "Section_" .. text
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 0, 20)
	label.LayoutOrder = order
	label.Text = text
	label.TextColor3 = Theme.Color.Brand
	label.TextSize = Theme.TextSize.XS
	label.FontFace = Theme.Font.Bold
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = parent
end

local function makePage(content: ScrollingFrame, name: string): Frame
	local page = Instance.new("Frame")
	page.Name = name
	page.BackgroundTransparency = 1
	page.Size = UDim2.new(1, 0, 0, 0)
	page.AutomaticSize = Enum.AutomaticSize.Y
	page.Visible = false
	page.Parent = content

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, Theme.Pad.SM)
	list.Parent = page

	_pages[name] = page
	return page
end

local function setBar(fill: Frame, frac: number)
	fill.Size = UDim2.fromScale(math.clamp(frac, 0, 1), 1)
end

-- Full-width hairline separator (the Divider kit defaults to a short fixed length).
local function hdiv(parent: Instance, order: number)
	local d = Instance.new("Frame")
	d.Name = "Divider"
	d.BorderSizePixel = 0
	d.BackgroundColor3 = Theme.Color.StrokeSoft
	d.Size = UDim2.new(1, 0, 0, 1)
	d.LayoutOrder = order
	d.Parent = parent
end

local function buildOverview(content: ScrollingFrame)
	local p = makePage(content, "Overview")
	sectionLabel(p, 1, "CITY")
	local pop = statRow(p, 2, "Population")
	local jobs = statRow(p, 3, "Jobs")
	local treasury = statRow(p, 4, "Treasury")
	local net = statRow(p, 5, "Net / tick")
	hdiv(p, 6)
	sectionLabel(p, 7, "DEMAND")
	local rFill, rVal = barRow(p, 8, "Residential", DEMAND_COLOR.R)
	local cFill, cVal = barRow(p, 9, "Commercial", DEMAND_COLOR.C)
	local iFill, iVal = barRow(p, 10, "Industrial", DEMAND_COLOR.I)

	_set.ovPop = function(v) pop.Text = Format.int(v) end
	_set.ovJobs = function(v) jobs.Text = Format.int(v) end
	_set.ovTreasury = function(v) treasury.Text = Format.money(v) end
	_set.ovNet = function(v)
		net.Text = Format.signed(v)
		net.TextColor3 = if v < 0 then RED else GREEN
	end
	_set.ovDemand = function(d)
		setBar(rFill, d.R); rVal.Text = tostring(math.floor(math.clamp(d.R, 0, 1) * 100 + 0.5)) .. "%"
		setBar(cFill, d.C); cVal.Text = tostring(math.floor(math.clamp(d.C, 0, 1) * 100 + 0.5)) .. "%"
		setBar(iFill, d.I); iVal.Text = tostring(math.floor(math.clamp(d.I, 0, 1) * 100 + 0.5)) .. "%"
	end
end

local function buildEconomy(content: ScrollingFrame)
	local p = makePage(content, "Economy")
	sectionLabel(p, 1, "TREASURY")
	local treasury = statRow(p, 2, "Balance", true)
	hdiv(p, 3)

	-- Shared budget state; any slider change sends taxes + funding together.
	local rates = { R = 9, C = 9, I = 9 }
	local funding = { Police = 100, Fire = 100, Health = 100, Education = 100 }
	local lastSent = 0
	-- Granular sends: each control fires only the field it changed, so funding never wipes
	-- tax overrides (the server snaps a zone's subtypes to its master).
	local function send(tbl: any, final: boolean)
		local now = os.clock()
		if not final and now - lastSent < 0.15 then return end
		lastSent = now
		if Net and Net.RequestSetBudget then Net.RequestSetBudget:FireServer(tbl) end
	end
	local function pushBudget(final: boolean) send({ funding = funding }, final) end

	sectionLabel(p, 4, "TAX RATES")
	local setR, dragR = sliderRow(p, 5, "Residential", DEMAND_COLOR.R, TAX_MIN, TAX_MAX, function(v, final) rates.R = v; send({ R = v }, final) end)
	local setC, dragC = sliderRow(p, 6, "Commercial", DEMAND_COLOR.C, TAX_MIN, TAX_MAX, function(v, final) rates.C = v; send({ C = v }, final) end)
	local setI, dragI = sliderRow(p, 7, "Industrial", DEMAND_COLOR.I, TAX_MIN, TAX_MAX, function(v, final) rates.I = v; send({ I = v }, final) end)

	hdiv(p, 8)
	sectionLabel(p, 9, "INCOME / MONTH")
	local incRes = statRow(p, 10, "Residential tax")
	local incComm = statRow(p, 11, "Commercial tax")
	local incInd = statRow(p, 12, "Industrial tax")
	local incRetail = statRow(p, 13, "Retail (shops)")
	local incExport = statRow(p, 14, "Exports")
	local incTotal = statRow(p, 15, "Total income")
	hdiv(p, 16)

	sectionLabel(p, 17, "SERVICE FUNDING")
	local POLICE_C = Color3.fromRGB(86, 140, 210)
	local FIRE_C = Color3.fromRGB(220, 120, 90)
	local HEALTH_C = Color3.fromRGB(206, 90, 96)
	local EDU_C = Color3.fromRGB(150, 190, 120)
	local setPol, dragPol = sliderRow(p, 18, "Police", POLICE_C, FUND_MIN, FUND_MAX, function(v, final) funding.Police = v; pushBudget(final) end)
	local setFire, dragFire = sliderRow(p, 19, "Fire", FIRE_C, FUND_MIN, FUND_MAX, function(v, final) funding.Fire = v; pushBudget(final) end)
	local setHea, dragHea = sliderRow(p, 20, "Healthcare", HEALTH_C, FUND_MIN, FUND_MAX, function(v, final) funding.Health = v; pushBudget(final) end)
	local setEdu, dragEdu = sliderRow(p, 21, "Education", EDU_C, FUND_MIN, FUND_MAX, function(v, final) funding.Education = v; pushBudget(final) end)

	hdiv(p, 22)
	sectionLabel(p, 23, "EXPENSES / MONTH")
	local expRoads = statRow(p, 24, "Roads")
	local expPolice = statRow(p, 25, "Police")
	local expFire = statRow(p, 26, "Fire")
	local expHealth = statRow(p, 27, "Healthcare")
	local expEdu = statRow(p, 28, "Education")
	local expTotal = statRow(p, 29, "Total upkeep")
	hdiv(p, 30)

	sectionLabel(p, 31, "BOTTOM LINE")
	local netM = statRow(p, 32, "Net / month", true)
	hdiv(p, 33)

	sectionLabel(p, 34, "GOODS")
	local output = statRow(p, 35, "Industry output")
	local need = statRow(p, 36, "Commerce need")
	local supplyFill, supplyVal = barRow(p, 37, "Locally supplied", GREEN)

	hdiv(p, 38)
	sectionLabel(p, 39, "LOANS")
	local loanBal = statRow(p, 40, "Balance")
	local loanLim = statRow(p, 41, "Borrow limit")
	local loanRate = statRow(p, 42, "Interest rate")
	local loanCost = statRow(p, 43, "Monthly interest")
	local loanState = { principal = 0, limit = 0 }
	local LOAN_STEP = 25000

	local btnRow = Instance.new("Frame")
	btnRow.BackgroundTransparency = 1
	btnRow.Size = UDim2.new(1, 0, 0, 34)
	btnRow.LayoutOrder = 44
	btnRow.Parent = p
	local btnLayout = Instance.new("UIListLayout")
	btnLayout.FillDirection = Enum.FillDirection.Horizontal
	btnLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	btnLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	btnLayout.Padding = UDim.new(0, Theme.Pad.SM)
	btnLayout.Parent = btnRow

	local function loanBtn(text: string, order: number, color: Color3, onClick: () -> ())
		local b = Instance.new("TextButton")
		b.AutoButtonColor = true
		b.Size = UDim2.new(0.5, -4, 1, 0)
		b.LayoutOrder = order
		b.Text = text
		b.TextColor3 = Color3.fromRGB(245, 246, 248)
		b.TextSize = Theme.TextSize.SM
		b.FontFace = Theme.Font.Bold
		b.BackgroundColor3 = color
		b.BorderSizePixel = 0
		b.Parent = btnRow
		local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = b
		b.Activated:Connect(onClick)
		return b
	end
	loanBtn("Borrow $25k", 1, Color3.fromRGB(70, 150, 90), function()
		if Net and Net.RequestSetBudget then
			Net.RequestSetBudget:FireServer({ loan = math.min(loanState.principal + LOAN_STEP, loanState.limit) })
		end
	end)
	loanBtn("Repay $25k", 2, Color3.fromRGB(170, 90, 90), function()
		if Net and Net.RequestSetBudget then
			Net.RequestSetBudget:FireServer({ loan = math.max(loanState.principal - LOAN_STEP, 0) })
		end
	end)

	local function plus(v: number) return "+" .. Format.money(v) end
	local function minus(v: number) return (if v > 0 then "-" else "") .. Format.money(v) end

	_set.ecTreasury = function(v) treasury.Text = Format.money(v) end
	_set.ecTax = function(r)
		if typeof(r) ~= "table" then return end
		if tonumber(r.R) and not dragR() then rates.R = math.floor(r.R + 0.5); setR(rates.R) end
		if tonumber(r.C) and not dragC() then rates.C = math.floor(r.C + 0.5); setC(rates.C) end
		if tonumber(r.I) and not dragI() then rates.I = math.floor(r.I + 0.5); setI(rates.I) end
	end
	_set.ecFunding = function(f)
		if typeof(f) ~= "table" then return end
		if tonumber(f.Police) and not dragPol() then funding.Police = math.floor(f.Police + 0.5); setPol(funding.Police) end
		if tonumber(f.Fire) and not dragFire() then funding.Fire = math.floor(f.Fire + 0.5); setFire(funding.Fire) end
		if tonumber(f.Health) and not dragHea() then funding.Health = math.floor(f.Health + 0.5); setHea(funding.Health) end
		if tonumber(f.Education) and not dragEdu() then funding.Education = math.floor(f.Education + 0.5); setEdu(funding.Education) end
	end
	_set.ecBreakdown = function(pl)
		incRes.Text = plus(tonumber(pl.taxResidential) or 0); incRes.TextColor3 = GREEN
		incComm.Text = plus(tonumber(pl.taxCommercial) or 0); incComm.TextColor3 = GREEN
		incInd.Text = plus(tonumber(pl.taxIndustrial) or 0); incInd.TextColor3 = GREEN
		incRetail.Text = plus(tonumber(pl.retailIncome) or 0); incRetail.TextColor3 = GREEN
		incExport.Text = plus(tonumber(pl.exportIncome) or 0); incExport.TextColor3 = GREEN
		incTotal.Text = plus(tonumber(pl.monthlyIncome) or 0); incTotal.TextColor3 = GREEN
		expRoads.Text = minus(tonumber(pl.upkeepRoads) or 0); expRoads.TextColor3 = RED
		expPolice.Text = minus(tonumber(pl.upkeepPolice) or 0); expPolice.TextColor3 = RED
		expFire.Text = minus(tonumber(pl.upkeepFire) or 0); expFire.TextColor3 = RED
		expHealth.Text = minus(tonumber(pl.upkeepHealth) or 0); expHealth.TextColor3 = RED
		expEdu.Text = minus(tonumber(pl.upkeepEducation) or 0); expEdu.TextColor3 = RED
		expTotal.Text = minus(tonumber(pl.monthlyUpkeep) or 0); expTotal.TextColor3 = RED
		local nm = tonumber(pl.monthlyNet) or 0
		netM.Text = Format.signed(nm); netM.TextColor3 = if nm < 0 then RED else GREEN
	end
	_set.ecOutput = function(v) output.Text = Format.int(v) end
	_set.ecNeed = function(v) need.Text = Format.int(v) end
	_set.ecSupply = function(v) setBar(supplyFill, v); supplyVal.Text = tostring(math.floor(math.clamp(v, 0, 1) * 100 + 0.5)) .. "%" end
	_set.ecLoan = function(pl)
		local prin = tonumber(pl.loanPrincipal) or 0
		local lim = tonumber(pl.loanLimit) or 0
		loanState.principal = prin
		loanState.limit = lim
		loanBal.Text = Format.money(prin)
		loanLim.Text = Format.money(lim)
		loanRate.Text = tostring(math.floor((tonumber(pl.loanAnnualRate) or 0) * 100 + 0.5)) .. "%"
		loanCost.Text = "-" .. Format.money(tonumber(pl.loanInterest) or 0)
		loanCost.TextColor3 = RED
	end
end

local function buildPopulation(content: ScrollingFrame)
	local p = makePage(content, "Population")
	sectionLabel(p, 1, "RESIDENTS")
	local pop = statRow(p, 2, "Population", true)
	hdiv(p, 3)
	sectionLabel(p, 4, "WORKFORCE")
	local workforce = statRow(p, 5, "Workforce")
	local jobs = statRow(p, 6, "Jobs available")
	local empFill, empVal = barRow(p, 7, "Employment", DEMAND_COLOR.C)
	hdiv(p, 8)
	sectionLabel(p, 9, "EDUCATION")
	local pupils = statRow(p, 10, "School-age pupils")
	local seats = statRow(p, 11, "School seats")
	local eduFill, eduVal = barRow(p, 12, "Education coverage", GREEN)
	local happyFill, happyVal = barRow(p, 13, "Happiness", GREEN)

	_set.popPopulation = function(v) pop.Text = Format.int(v) end
	_set.popWork = function(workforce_n, jobs_n)
		workforce.Text = Format.int(workforce_n)
		jobs.Text = Format.int(jobs_n)
		local rate = if workforce_n > 0 then math.min(jobs_n, workforce_n) / workforce_n else 0
		setBar(empFill, rate)
		empVal.Text = tostring(math.floor(rate * 100 + 0.5)) .. "%"
	end
	_set.popEducation = function(e)
		local eligible = tonumber(e and e.eligible) or 0
		local assigned = tonumber(e and e.assigned) or 0
		local capacity = tonumber(e and e.capacity) or 0
		local attending = tonumber(e and e.attending) or 0
		local coverage = tonumber(e and e.coverage) or 1
		pupils.Text = Format.int(assigned) .. " / " .. Format.int(eligible)
		seats.Text = Format.int(attending) .. " / " .. Format.int(capacity)
		setBar(eduFill, coverage)
		eduVal.Text = tostring(math.floor(math.clamp(coverage, 0, 1) * 100 + 0.5)) .. "%"
	end
	_set.popHappiness = function(v)
		v = tonumber(v) or 1
		setBar(happyFill, v)
		happyVal.Text = tostring(math.floor(math.clamp(v, 0, 1) * 100 + 0.5)) .. "%"
	end
end

local function selectTab(key: string)
	_activeTab = key
	for k, tab in _tabs do
		tab:SetSelected(k == key)
	end
	for name, page in _pages do
		page.Visible = name == key
	end
end

local function build(gui: ScreenGui)
	local panel = Instance.new("CanvasGroup")
	panel.Name = "Dashboard"
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1, PANEL_W + 24, 0, PANEL_TOP)
	panel.Size = UDim2.fromOffset(PANEL_W, PANEL_MIN_H)
	panel.GroupTransparency = 1
	panel.Visible = false
	panel.ZIndex = Theme.Z.Flyout
	Glass.apply(panel, Theme.Radius.LG)
	panel.Parent = gui
	_panel = panel

	-- Fill the viewport under the pill stack instead of a fixed 440px, which cut the
	-- longer pages off mid-row. AbsoluteSize is real px, offsets are design px.
	local hs = HudScale.attach(gui)
	local function fitHeight()
		local avail = gui.AbsoluteSize.Y / math.max(hs.Scale, 0.01) - PANEL_TOP - PANEL_BOTTOM
		panel.Size = UDim2.fromOffset(PANEL_W, math.max(avail, PANEL_MIN_H))
	end
	fitHeight()
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitHeight)
	hs:GetPropertyChangedSignal("Scale"):Connect(fitHeight)

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, Theme.Pad.LG)
	pad.PaddingBottom = UDim.new(0, Theme.Pad.LG)
	pad.PaddingLeft = UDim.new(0, Theme.Pad.LG)
	pad.PaddingRight = UDim.new(0, Theme.Pad.LG)
	pad.Parent = panel

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 28)
	header.Parent = panel

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.AnchorPoint = Vector2.new(0, 0.5)
	title.Position = UDim2.fromScale(0, 0.5)
	title.Size = UDim2.new(1, -32, 1, 0)
	title.Text = "City Dashboard"
	title.TextColor3 = Theme.Color.TextPrimary
	title.TextSize = Theme.TextSize.MD
	title.FontFace = Theme.Font.Bold
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = header

	IconButton.new({
		icon = Icons.Close,
		name = "Close",
		size = 26,
		parent = header,
		onClick = function()
			DashboardController.Close()
		end,
	}).Instance.AnchorPoint = Vector2.new(1, 0.5)
	local closeBtn = header:FindFirstChild("Close")
	if closeBtn and closeBtn:IsA("GuiObject") then
		closeBtn.Position = UDim2.fromScale(1, 0.5)
	end

	local tabRow = Instance.new("Frame")
	tabRow.Name = "Tabs"
	tabRow.BackgroundTransparency = 1
	tabRow.Size = UDim2.new(1, 0, 0, 24)
	tabRow.Position = UDim2.fromOffset(0, 34)
	tabRow.Parent = panel

	local tabList = Instance.new("UIListLayout")
	tabList.FillDirection = Enum.FillDirection.Horizontal
	tabList.VerticalAlignment = Enum.VerticalAlignment.Center
	tabList.SortOrder = Enum.SortOrder.LayoutOrder
	tabList.Padding = UDim.new(0, Theme.Pad.XS)
	tabList.Parent = tabRow

	local content = Instance.new("ScrollingFrame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.BorderSizePixel = 0
	content.Position = UDim2.fromOffset(0, 66)
	content.Size = UDim2.new(1, 0, 1, -66)
	content.ScrollBarThickness = 4
	content.ScrollingDirection = Enum.ScrollingDirection.Y
	content.CanvasSize = UDim2.new()
	content.AutomaticCanvasSize = Enum.AutomaticSize.Y
	content.Parent = panel

	buildOverview(content)
	buildEconomy(content)
	buildPopulation(content)

	for i, key in { "Overview", "Economy", "Population" } do
		_tabs[key] = Tab.new({
			text = key,
			parent = tabRow,
			layoutOrder = i,
			onClick = function()
				selectTab(key)
			end,
		})
	end
	selectTab("Overview")
end

function DashboardController.Open(tabKey: string?)
	local panel = _panel
	if not panel then
		return
	end
	if tabKey and _tabs[tabKey] then
		selectTab(tabKey)
	end
	_open = true
	-- The Transport Overview opens to the same right-edge slot at the same top; without
	-- this the two simply stacked and the lower one was unreachable.
	PanelSlots.claim("rightPanel", "Dashboard", DashboardController.Close)
	panel.Visible = true
	UITween.to(panel, "Flyout", {
		GroupTransparency = 0,
		Position = UDim2.new(1, -12, 0, PANEL_TOP),
	})
end

function DashboardController.Close()
	local panel = _panel
	if not panel then
		return
	end
	_open = false
	PanelSlots.release("rightPanel", "Dashboard")
	local tween = UITween.to(panel, "Flyout", {
		GroupTransparency = 1,
		Position = UDim2.new(1, PANEL_W + 24, 0, PANEL_TOP),
	})
	tween.Completed:Once(function()
		if not _open then
			panel.Visible = false
		end
	end)
end

function DashboardController.Toggle(tabKey: string?)
	if _open then
		if tabKey and tabKey ~= _activeTab and _tabs[tabKey] then
			selectTab(tabKey)
		else
			DashboardController.Close()
		end
	else
		DashboardController.Open(tabKey)
	end
end

function DashboardController.IsOpen(): boolean
	return _open
end

function DashboardController.Start()
	if _started then
		return
	end
	_started = true

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local gui = playerGui:WaitForChild("CityUI", 60)
	if not gui or not gui:IsA("ScreenGui") then
		warn("[DashboardController] CityUI not found")
		_started = false
		return
	end

	Net = require(ReplicatedStorage:WaitForChild("Networker"))
	build(gui)

	require(ReplicatedStorage:WaitForChild("City"):WaitForChild("UIEvents")).SettingsOpened.Event:Connect(function()
		DashboardController.Close()
	end)

	Net.SyncCityStats.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		local pop = tonumber(payload.population) or 0
		local jobs = tonumber(payload.jobs) or 0
		_set.ovPop(pop)
		_set.ovJobs(jobs)
		_set.popPopulation(pop)
		_set.popWork(pop * 0.5, jobs)
		if typeof(payload.demand) == "table" then
			_set.ovDemand({
				R = tonumber(payload.demand.R) or 0,
				C = tonumber(payload.demand.C) or 0,
				I = tonumber(payload.demand.I) or 0,
			})
		end
		if _set.popEducation then
			_set.popEducation(payload.education); if _set.popHappiness then _set.popHappiness(payload.happiness) end
		end
	end)

	Net.SyncEconomy.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		local money = tonumber(payload.money) or 0
		local net = tonumber(payload.net) or 0
		_set.ovTreasury(money)
		_set.ovNet(net)
		_set.ecTreasury(money)
		if _set.ecTax and typeof(payload.taxRates) == "table" then _set.ecTax(payload.taxRates) end
		if _set.ecFunding and typeof(payload.funding) == "table" then _set.ecFunding(payload.funding) end
		if _set.ecBreakdown then _set.ecBreakdown(payload) end
		if _set.ecLoan then _set.ecLoan(payload) end
		_set.ecOutput(tonumber(payload.output) or 0)
		_set.ecNeed(tonumber(payload.need) or 0)
		_set.ecSupply(tonumber(payload.supplyRatio) or 0)
	end)
end

return DashboardController
