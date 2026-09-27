--!strict
-- EconomyPanelController
-- Full-screen, tabbed economy overlay (Budget / Taxation / Services / Loans / Production).
-- The game keeps running, blurred, behind a translucent scrim. Opened by the HUD $ button.
-- Per-subtype taxation (residential by education bracket, commercial/industrial by product)
-- is built dynamically from the SyncEconomy payload's taxBreakdown.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")

local uiFolder = script.Parent.Parent:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local Glass = require(uiFolder:WaitForChild("Kit"):WaitForChild("Glass"))

local EconomyPanelController = {}

local GREEN = Color3.fromRGB(120, 220, 140)
local RED = Color3.fromRGB(230, 110, 110)
local DIM = Color3.fromRGB(170, 178, 188)
local TAX_MIN, TAX_MAX = -5, 29 -- negative = subsidy (the city pays that zone)
local FUND_MIN, FUND_MAX = 50, 150
local RES_LABELS = { [0] = "Uneducated", [1] = "Educated", [2] = "Well Educated", [3] = "Highly Educated" }
local ZONE_DESC = {
	Residential = "Homes where your citizens live. Income tax is your steadiest money \u{2014} but push it too high and people pack up and leave.",
	Commercial = "Shops, food and venues that sell to citizens. Taxed on trade; steep rates shut businesses down.",
	Industrial = "Factories and warehouses making goods and jobs. The economy's engine \u{2014} cheap to keep, but it pollutes.",
}
local RES_DESC = {
	[0] = "Low-income earners with no schooling. They can least afford a high rate \u{2014} a subsidy keeps them in town.",
	[1] = "Workers with a basic education and modest wages.",
	[2] = "High-school graduates earning a comfortable wage.",
	[3] = "University graduates \u{2014} your highest earners. They can shoulder the most tax.",
}
local ZONE_COLOR = {
	Residential = Color3.fromRGB(82, 196, 110),
	Commercial = Color3.fromRGB(70, 160, 230),
	Industrial = Color3.fromRGB(220, 185, 55),
}

local _started = false
local _gui: ScreenGui? = nil
local _root: CanvasGroup? = nil
local _open = false
local _blur: BlurEffect? = nil
local _tabs: { [string]: { btn: TextButton, page: ScrollingFrame } } = {}
local _activeTab = "Budget"
local _set: { [string]: (any) -> () } = {}
local Net: any = nil

-- Local mirror of rates so a slider change can send the others untouched.
local _rates = { R = 9, C = 9, I = 9 }
local _funding = { Police = 100, Fire = 100, Health = 100, Education = 100 }
local _loan = { principal = 0, limit = 0 }

local function commaInt(n: number): string
	local neg = n < 0
	local s = tostring(math.abs(math.floor(n + 0.5)))
	local out = ""
	while #s > 3 do out = "," .. s:sub(#s - 2) .. out; s = s:sub(1, #s - 3) end
	return (neg and "-" or "") .. s .. out
end
local function money(n: number): string return "$" .. commaInt(n) end
local function signed(n: number): string return (n >= 0 and "+" or "-") .. "$" .. commaInt(math.abs(n)) end

local function corner(inst: Instance, r: number)
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r); c.Parent = inst
end

local function pushBudget()
	if Net and Net.RequestSetBudget then
		Net.RequestSetBudget:FireServer({ R = _rates.R, C = _rates.C, I = _rates.I, funding = _funding })
	end
end

-- A labelled stat row (label left, value right). Returns the value label.
local function statRow(parent: Instance, order: number, label: string, big: boolean?): TextLabel
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, if big then 30 else 22)
	row.LayoutOrder = order
	row.Parent = parent
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1; l.AnchorPoint = Vector2.new(0, 0.5); l.Position = UDim2.fromScale(0, 0.5)
	l.Size = UDim2.new(0.6, 0, 1, 0); l.Text = label; l.TextColor3 = DIM
	l.TextSize = if big then Theme.TextSize.MD else Theme.TextSize.SM; l.FontFace = Theme.Font.Label
	l.TextXAlignment = Enum.TextXAlignment.Left; l.Parent = row
	local v = Instance.new("TextLabel")
	v.Name = "Value"; v.BackgroundTransparency = 1; v.AnchorPoint = Vector2.new(1, 0.5); v.Position = UDim2.fromScale(1, 0.5)
	v.Size = UDim2.new(0.4, 0, 1, 0); v.Text = "\u{2014}"; v.TextColor3 = Theme.Color.TextPrimary
	v.TextSize = if big then Theme.TextSize.LG else Theme.TextSize.SM; v.FontFace = if big then Theme.Font.Bold else Theme.Font.Header
	v.TextXAlignment = Enum.TextXAlignment.Right; v.Parent = row
	return v
end

local function sectionLabel(parent: Instance, order: number, text: string)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1; l.Size = UDim2.new(1, 0, 0, 22); l.LayoutOrder = order
	l.Text = text; l.TextColor3 = Theme.Color.Brand; l.TextSize = Theme.TextSize.XS
	l.FontFace = Theme.Font.Bold; l.TextXAlignment = Enum.TextXAlignment.Left; l.Parent = parent
end

-- A slider row: label + value% + estimate ($) + draggable track. onChange(v, final).
-- Returns (setValue, isDragging, setEstimate).
local function sliderRow(parent: Instance, order: number, label: string, color: Color3, minV: number, maxV: number, onChange: (number, boolean) -> ()): ((number) -> (), () -> boolean, (string) -> ())
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1; row.Size = UDim2.new(1, 0, 0, 40); row.LayoutOrder = order; row.Parent = parent
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1; l.Size = UDim2.new(0.5, 0, 0, 16); l.Text = label
	l.TextColor3 = Theme.Color.TextSecondary; l.TextSize = Theme.TextSize.XS; l.FontFace = Theme.Font.Label
	l.TextXAlignment = Enum.TextXAlignment.Left; l.Parent = row
	local est = Instance.new("TextLabel")
	est.Name = "Est"; est.BackgroundTransparency = 1; est.AnchorPoint = Vector2.new(1, 0); est.Position = UDim2.fromScale(1, 0)
	est.Size = UDim2.new(0.5, -34, 0, 16); est.Text = ""; est.TextColor3 = GREEN; est.TextSize = Theme.TextSize.XS
	est.FontFace = Theme.Font.Header; est.TextXAlignment = Enum.TextXAlignment.Right; est.Parent = row
	local pct = Instance.new("TextLabel")
	pct.Name = "Pct"; pct.BackgroundTransparency = 1; pct.AnchorPoint = Vector2.new(1, 0); pct.Position = UDim2.fromScale(1, 0)
	pct.Size = UDim2.new(0, 0, 0, 16); pct.AutomaticSize = Enum.AutomaticSize.X; pct.Text = "0%"
	pct.TextColor3 = Theme.Color.TextPrimary; pct.TextSize = Theme.TextSize.XS; pct.FontFace = Theme.Font.Header
	pct.Visible = false; pct.Parent = row
	local track = Instance.new("TextButton")
	track.AutoButtonColor = false; track.Text = ""; track.AnchorPoint = Vector2.new(0, 1); track.Position = UDim2.fromScale(0, 1)
	track.Size = UDim2.new(1, 0, 0, 8); track.BackgroundColor3 = Theme.Color.BgPress; track.BorderSizePixel = 0; track.Parent = row
	corner(track, 4)
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1); fill.BackgroundColor3 = color; fill.BorderSizePixel = 0; fill.Parent = track
	corner(fill, 4)
	local handle = Instance.new("Frame")
	handle.AnchorPoint = Vector2.new(0.5, 0.5); handle.Position = UDim2.fromScale(0, 0.5); handle.Size = UDim2.fromOffset(14, 14)
	handle.BackgroundColor3 = Color3.fromRGB(245, 246, 248); handle.BorderSizePixel = 0; handle.ZIndex = 2; handle.Parent = track
	corner(handle, 7)
	local current = minV
	local dragging = false
	local function render()
		local frac = if maxV > minV then (current - minV) / (maxV - minV) else 0
		fill.Size = UDim2.fromScale(frac, 1); handle.Position = UDim2.fromScale(frac, 0.5)
		l.Text = label .. "  " .. tostring(current) .. "%"
	end
	local function setFromX(px: number, final: boolean)
		local rel = math.clamp((px - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X), 0, 1)
		local v = math.floor(minV + rel * (maxV - minV) + 0.5)
		if v ~= current or final then current = v; render(); if onChange then onChange(current, final) end end
	end
	track.InputBegan:Connect(function(i: InputObject)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = true; setFromX(i.Position.X, false) end
	end)
	UserInputService.InputChanged:Connect(function(i: InputObject)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then setFromX(i.Position.X, false) end
	end)
	UserInputService.InputEnded:Connect(function(i: InputObject)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch) then dragging = false; setFromX(i.Position.X, true) end
	end)
	render()
	local function setValue(v: number)
		if dragging then return end
		current = math.clamp(math.floor((tonumber(v) or minV) + 0.5), minV, maxV); render()
	end
	local function setEstimate(text: string) est.Text = text end
	return setValue, function() return dragging end, setEstimate
end

local function makePage(name: string): ScrollingFrame
	local page = Instance.new("ScrollingFrame")
	page.Name = name; page.BackgroundTransparency = 1; page.BorderSizePixel = 0
	page.Size = UDim2.new(1, 0, 1, 0); page.Visible = false
	page.ScrollBarThickness = 5; page.ScrollingDirection = Enum.ScrollingDirection.Y
	page.CanvasSize = UDim2.new(); page.AutomaticCanvasSize = Enum.AutomaticSize.Y
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical; list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, Theme.Pad.SM); list.Parent = page
	local pad = Instance.new("UIPadding")
	pad.PaddingRight = UDim.new(0, 10); pad.Parent = page
	return page
end

-- ===== tabs =====================================================================

-- A budget line: name on the left, a dark value capsule on the right. kind picks the
-- sign + colour (rev = +green, exp = -red, net = signed). header = a bolder section row.
local function budgetRow(parent: Instance, order: number, label: string, opts: any): (number) -> ()
	opts = opts or {}
	local isHeader = opts.header == true
	local indent = opts.indent or (if isHeader then 16 else 30)
	local row = Instance.new("Frame")
	row.BorderSizePixel = 0; row.Size = UDim2.new(1, 0, 0, if isHeader then 34 else 28); row.LayoutOrder = order; row.Parent = parent
	row.BackgroundColor3 = Color3.fromRGB(255, 255, 255); row.BackgroundTransparency = if isHeader then 0.92 else 1
	local sep = Instance.new("Frame")
	sep.AnchorPoint = Vector2.new(0, 1); sep.Position = UDim2.fromScale(0, 1); sep.Size = UDim2.new(1, 0, 0, 1)
	sep.BorderSizePixel = 0; sep.BackgroundColor3 = Theme.Color.StrokeSoft; sep.BackgroundTransparency = 0.55; sep.Parent = row
	local name = Instance.new("TextLabel")
	name.BackgroundTransparency = 1; name.AnchorPoint = Vector2.new(0, 0.5); name.Position = UDim2.new(0, indent, 0.5, 0); name.Size = UDim2.new(0.6, 0, 1, 0)
	name.Text = label; name.TextColor3 = if isHeader then Theme.Color.TextPrimary else Theme.Color.TextSecondary
	name.TextSize = Theme.TextSize.SM; name.FontFace = if isHeader then Theme.Font.Bold else Theme.Font.Label
	name.TextXAlignment = Enum.TextXAlignment.Left; name.Parent = row
	local cap = Instance.new("TextLabel")
	cap.AnchorPoint = Vector2.new(1, 0.5); cap.Position = UDim2.new(1, -10, 0.5, 0); cap.Size = UDim2.fromOffset(120, if isHeader then 26 else 22)
	cap.BackgroundColor3 = Color3.fromRGB(15, 18, 23); cap.BackgroundTransparency = if isHeader then 0.1 else 0.3
	cap.Text = "$0"; cap.TextColor3 = GREEN; cap.TextSize = Theme.TextSize.SM; cap.FontFace = if isHeader then Theme.Font.Bold else Theme.Font.Header
	cap.TextXAlignment = Enum.TextXAlignment.Right; cap.Parent = row
	corner(cap, 6)
	local cpad = Instance.new("UIPadding"); cpad.PaddingLeft = UDim.new(0, 8); cpad.PaddingRight = UDim.new(0, 10); cpad.Parent = cap
	return function(n: number)
		local v = tonumber(n) or 0
		local kind = opts.kind or "rev"
		if kind == "rev" then cap.Text = "+" .. money(v); cap.TextColor3 = GREEN
		elseif kind == "exp" then cap.Text = "-" .. money(v); cap.TextColor3 = RED
		else cap.Text = signed(v); cap.TextColor3 = if v < 0 then RED else GREEN end
	end
end

local function buildBudget(page: ScrollingFrame)
	local rootF = Instance.new("Frame")
	rootF.BackgroundTransparency = 1; rootF.Size = UDim2.new(1, 0, 1, 0); rootF.Parent = page

	-- Right: what-is-this card.
	local info = Instance.new("Frame")
	info.BorderSizePixel = 0; info.BackgroundColor3 = Color3.fromRGB(255, 255, 255); info.BackgroundTransparency = 0.965
	info.AnchorPoint = Vector2.new(1, 0); info.Position = UDim2.fromScale(1, 0); info.Size = UDim2.new(0.33, 0, 1, -58); info.Parent = rootF
	corner(info, 10)
	local iStroke = Instance.new("UIStroke"); iStroke.Color = Theme.Color.StrokeSoft; iStroke.Transparency = 0.5; iStroke.Parent = info
	local iPad = Instance.new("UIPadding")
	iPad.PaddingTop = UDim.new(0, 16); iPad.PaddingBottom = UDim.new(0, 16); iPad.PaddingLeft = UDim.new(0, 16); iPad.PaddingRight = UDim.new(0, 16); iPad.Parent = info
	local iTitle = Instance.new("TextLabel")
	iTitle.BackgroundTransparency = 1; iTitle.Size = UDim2.new(1, 0, 0, 26); iTitle.Text = "Budget"
	iTitle.TextColor3 = Theme.Color.TextPrimary; iTitle.TextSize = Theme.TextSize.LG; iTitle.FontFace = Theme.Font.Bold
	iTitle.TextXAlignment = Enum.TextXAlignment.Left; iTitle.Parent = info
	local iDesc = Instance.new("TextLabel")
	iDesc.BackgroundTransparency = 1; iDesc.Position = UDim2.fromOffset(0, 34); iDesc.Size = UDim2.new(1, 0, 1, -40)
	iDesc.Text = "Your city's monthly cash flow.\n\nRevenue comes from taxes and the supply chain \u{2014} shops paying for goods (retail) and factories selling surplus (exports).\n\nExpenses are road and service upkeep, plus interest on any loans.\n\nKeep the balance in the black: a long run of deficits ends in bankruptcy."
	iDesc.TextColor3 = Theme.Color.TextSecondary; iDesc.TextSize = Theme.TextSize.SM; iDesc.FontFace = Theme.Font.Label
	iDesc.TextWrapped = true; iDesc.TextXAlignment = Enum.TextXAlignment.Left; iDesc.TextYAlignment = Enum.TextYAlignment.Top; iDesc.Parent = info

	-- Left: revenues + expenses table.
	local leftScroll = Instance.new("ScrollingFrame")
	leftScroll.BorderSizePixel = 0; leftScroll.BackgroundColor3 = Color3.fromRGB(255, 255, 255); leftScroll.BackgroundTransparency = 0.965
	leftScroll.Position = UDim2.fromScale(0, 0); leftScroll.Size = UDim2.new(0.65, 0, 1, -58)
	leftScroll.ScrollBarThickness = 5; leftScroll.ScrollingDirection = Enum.ScrollingDirection.Y
	leftScroll.CanvasSize = UDim2.new(); leftScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y; leftScroll.Parent = rootF
	corner(leftScroll, 10)
	local lStroke = Instance.new("UIStroke"); lStroke.Color = Theme.Color.StrokeSoft; lStroke.Transparency = 0.5; lStroke.Parent = leftScroll
	local ll = Instance.new("UIListLayout"); ll.SortOrder = Enum.SortOrder.LayoutOrder; ll.Parent = leftScroll

	local revHdr = budgetRow(leftScroll, 1, "REVENUES", { header = true, kind = "rev" })
	local rTax = budgetRow(leftScroll, 2, "Taxes", { kind = "rev" })
	local rRetail = budgetRow(leftScroll, 3, "Retail", { kind = "rev" })
	local rExport = budgetRow(leftScroll, 4, "Exports", { kind = "rev" })
	local exHdr = budgetRow(leftScroll, 10, "EXPENSES", { header = true, kind = "exp" })
	local eRoads = budgetRow(leftScroll, 11, "Roads", { kind = "exp" })
	local ePol = budgetRow(leftScroll, 12, "Police", { kind = "exp" })
	local eFire = budgetRow(leftScroll, 13, "Fire", { kind = "exp" })
	local eHea = budgetRow(leftScroll, 14, "Healthcare", { kind = "exp" })
	local eEdu = budgetRow(leftScroll, 15, "Education", { kind = "exp" })
	local eInt = budgetRow(leftScroll, 16, "Loan interest", { kind = "exp" })

	-- Bottom: monthly balance.
	local balBar = Instance.new("Frame")
	balBar.BorderSizePixel = 0; balBar.BackgroundColor3 = Color3.fromRGB(255, 255, 255); balBar.BackgroundTransparency = 0.9
	balBar.AnchorPoint = Vector2.new(0, 1); balBar.Position = UDim2.fromScale(0, 1); balBar.Size = UDim2.new(1, 0, 0, 46); balBar.Parent = rootF
	corner(balBar, 10)
	local bStroke = Instance.new("UIStroke"); bStroke.Color = Theme.Color.StrokeSoft; bStroke.Transparency = 0.55; bStroke.Parent = balBar
	local bl = Instance.new("TextLabel")
	bl.BackgroundTransparency = 1; bl.Position = UDim2.new(0, 18, 0, 0); bl.Size = UDim2.new(0.5, 0, 1, 0)
	bl.Text = "MONTHLY BALANCE"; bl.TextColor3 = Theme.Color.TextPrimary; bl.TextSize = Theme.TextSize.MD; bl.FontFace = Theme.Font.Bold
	bl.TextXAlignment = Enum.TextXAlignment.Left; bl.Parent = balBar
	local bpill = Instance.new("TextLabel")
	bpill.AnchorPoint = Vector2.new(1, 0.5); bpill.Position = UDim2.new(1, -12, 0.5, 0); bpill.Size = UDim2.fromOffset(140, 30)
	bpill.BackgroundColor3 = Color3.fromRGB(15, 18, 23); bpill.BackgroundTransparency = 0.1
	bpill.Text = "+$0"; bpill.TextColor3 = GREEN; bpill.TextSize = Theme.TextSize.LG; bpill.FontFace = Theme.Font.Bold
	bpill.TextXAlignment = Enum.TextXAlignment.Right; bpill.Parent = balBar
	corner(bpill, 6)
	local bpad = Instance.new("UIPadding"); bpad.PaddingLeft = UDim.new(0, 8); bpad.PaddingRight = UDim.new(0, 12); bpad.Parent = bpill

	_set.budget = function(p)
		local taxes = (tonumber(p.taxResidential) or 0) + (tonumber(p.taxCommercial) or 0) + (tonumber(p.taxIndustrial) or 0)
		revHdr(tonumber(p.monthlyIncome) or 0); rTax(taxes); rRetail(tonumber(p.retailIncome) or 0); rExport(tonumber(p.exportIncome) or 0)
		local expTotal = (tonumber(p.monthlyUpkeep) or 0) + (tonumber(p.loanInterest) or 0)
		exHdr(expTotal); eRoads(tonumber(p.upkeepRoads) or 0); ePol(tonumber(p.upkeepPolice) or 0); eFire(tonumber(p.upkeepFire) or 0)
		eHea(tonumber(p.upkeepHealth) or 0); eEdu(tonumber(p.upkeepEducation) or 0); eInt(tonumber(p.loanInterest) or 0)
		local nm = tonumber(p.monthlyNet) or 0
		bpill.Text = signed(nm); bpill.TextColor3 = if nm < 0 then RED else GREEN
	end
end

-- Build one taxable zone block: a master slider + a (dynamically-filled) list of subtype rows.
-- One columnar tax row: [chip + name (+arrow on headers)] | [% + rainbow slider] | [estimate].
-- Returns a handle: setRate, drag, setEst, nameBtn (clickable on headers), setArrow.
local function taxRow(parent: Instance, order: number, opts: any): any
	local color = opts.color or GREEN
	local minV, maxV = opts.min or TAX_MIN, opts.max or TAX_MAX
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 38); row.LayoutOrder = order; row.Parent = parent
	row.BorderSizePixel = 0
	row.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	row.BackgroundTransparency = if opts.header then 0.95 else 1
	local idle = row.BackgroundTransparency
	row.MouseEnter:Connect(function() row.BackgroundTransparency = 0.9 end)
	row.MouseLeave:Connect(function() row.BackgroundTransparency = idle end)
	-- Thin grid line so the rows read as a table.
	local sep = Instance.new("Frame")
	sep.AnchorPoint = Vector2.new(0, 1); sep.Position = UDim2.fromScale(0, 1); sep.Size = UDim2.new(1, 0, 0, 1)
	sep.BorderSizePixel = 0; sep.BackgroundColor3 = Theme.Color.StrokeSoft; sep.BackgroundTransparency = 0.5; sep.Parent = row

	local nameHolder: any
	if opts.header then
		nameHolder = Instance.new("TextButton"); nameHolder.AutoButtonColor = false; nameHolder.Text = ""
	else
		nameHolder = Instance.new("Frame")
	end
	nameHolder.BackgroundTransparency = 1; nameHolder.Size = UDim2.new(0.36, 0, 1, 0); nameHolder.Parent = row

	local indent = opts.indent or 0
	local chip = Instance.new("Frame")
	chip.Size = UDim2.fromOffset(9, 9); chip.AnchorPoint = Vector2.new(0, 0.5); chip.Position = UDim2.new(0, indent + 2, 0.5, 0)
	chip.BackgroundColor3 = color; chip.BorderSizePixel = 0; chip.Rotation = 45; chip.Parent = nameHolder

	local nameX = indent + 18
	local nameLabel = Instance.new("TextLabel")
	nameLabel.BackgroundTransparency = 1; nameLabel.AnchorPoint = Vector2.new(0, 0.5); nameLabel.Position = UDim2.new(0, nameX, 0.5, 0)
	nameLabel.Size = UDim2.new(1, -nameX - 20, 1, 0); nameLabel.Text = opts.name
	nameLabel.TextColor3 = if opts.header then Theme.Color.TextPrimary else Theme.Color.TextSecondary
	nameLabel.TextSize = Theme.TextSize.SM; nameLabel.FontFace = if opts.header then Theme.Font.Bold else Theme.Font.Label
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left; nameLabel.TextTruncate = Enum.TextTruncate.AtEnd; nameLabel.Parent = nameHolder

	local arrow: TextLabel? = nil
	if opts.header then
		local a = Instance.new("TextLabel")
		a.BackgroundTransparency = 1; a.AnchorPoint = Vector2.new(1, 0.5); a.Position = UDim2.new(1, -2, 0.5, 0)
		a.Size = UDim2.fromOffset(16, 16); a.Text = "\u{25BE}"; a.TextColor3 = DIM; a.TextSize = Theme.TextSize.MD
		a.FontFace = Theme.Font.Bold; a.Parent = nameHolder
		arrow = a
	end

	local pct = Instance.new("TextLabel")
	pct.BackgroundTransparency = 1; pct.Position = UDim2.fromScale(0.36, 0); pct.Size = UDim2.new(0.07, 0, 1, 0)
	pct.Text = "0%"; pct.TextColor3 = Theme.Color.TextPrimary; pct.TextSize = Theme.TextSize.SM; pct.FontFace = Theme.Font.Header
	pct.TextXAlignment = Enum.TextXAlignment.Right; pct.Parent = row

	-- Solid zone-coloured fill slider (our own look -- not the rainbow gradient).
	local track = Instance.new("TextButton")
	track.AutoButtonColor = false; track.Text = ""; track.AnchorPoint = Vector2.new(0, 0.5); track.Position = UDim2.new(0.45, 0, 0.5, 0)
	track.Size = UDim2.new(0.26, 0, 0, 6); track.BorderSizePixel = 0; track.BackgroundColor3 = Theme.Color.BgPress; track.Parent = row
	corner(track, 3)
	local fillBar = Instance.new("Frame")
	fillBar.AnchorPoint = Vector2.new(0, 0.5); fillBar.Position = UDim2.fromScale(0, 0.5); fillBar.Size = UDim2.fromScale(0, 1)
	fillBar.BackgroundColor3 = color; fillBar.BorderSizePixel = 0; fillBar.Parent = track
	corner(fillBar, 3)
	local handle = Instance.new("Frame")
	handle.AnchorPoint = Vector2.new(0.5, 0.5); handle.Position = UDim2.fromScale(0, 0.5); handle.Size = UDim2.fromOffset(13, 13)
	handle.BackgroundColor3 = Color3.fromRGB(245, 246, 248); handle.BorderSizePixel = 0; handle.ZIndex = 2; handle.Parent = track
	corner(handle, 7)

	-- Estimate in a dark capsule (table cell), right-aligned.
	local est = Instance.new("TextLabel")
	est.AnchorPoint = Vector2.new(1, 0.5); est.Position = UDim2.new(1, -10, 0.5, 0); est.Size = UDim2.fromOffset(102, 24)
	est.BackgroundColor3 = Color3.fromRGB(15, 18, 23); est.BackgroundTransparency = if opts.header then 0.1 else 0.28
	est.Text = "+$0"; est.TextColor3 = GREEN; est.TextSize = Theme.TextSize.SM; est.FontFace = if opts.header then Theme.Font.Bold else Theme.Font.Header
	est.TextXAlignment = Enum.TextXAlignment.Right; est.Parent = row
	corner(est, 6)
	local estPad = Instance.new("UIPadding"); estPad.PaddingLeft = UDim.new(0, 8); estPad.PaddingRight = UDim.new(0, 10); estPad.Parent = est

	local current = minV
	local dragging = false
	local function render()
		local frac = if maxV > minV then (current - minV) / (maxV - minV) else 0
		handle.Position = UDim2.fromScale(frac, 0.5); fillBar.Size = UDim2.fromScale(frac, 1); pct.Text = tostring(current) .. "%"
	end
	local function setFromX(px: number, final: boolean)
		local rel = math.clamp((px - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X), 0, 1)
		local v = math.floor(minV + rel * (maxV - minV) + 0.5)
		if v ~= current or final then current = v; render(); if opts.onChange then opts.onChange(current, final) end end
	end
	track.InputBegan:Connect(function(i: InputObject)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = true; setFromX(i.Position.X, false) end
	end)
	UserInputService.InputChanged:Connect(function(i: InputObject)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then setFromX(i.Position.X, false) end
	end)
	UserInputService.InputEnded:Connect(function(i: InputObject)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch) then dragging = false; setFromX(i.Position.X, true) end
	end)
	render()
	if opts.onHover then
		row.MouseEnter:Connect(function() opts.onHover(opts.name, opts.desc, current, est.Text) end)
	end
	return {
		setRate = function(v: number) if dragging then return end current = math.clamp(math.floor((tonumber(v) or minV) + 0.5), minV, maxV); render() end,
		drag = function() return dragging end,
		setEst = function(n: number)
			local v = tonumber(n) or 0
			est.Text = signed(v)
			local zeroDim = opts.dimZero and v == 0
			est.TextColor3 = if v < 0 then RED elseif zeroDim then DIM else GREEN
			nameLabel.TextColor3 = if zeroDim then DIM else (if opts.header then Theme.Color.TextPrimary else Theme.Color.TextSecondary)
			chip.BackgroundTransparency = if zeroDim then 0.55 else 0
		end,
		nameBtn = nameHolder,
		setArrow = function(open: boolean) if arrow then arrow.Text = if open then "\u{25B4}" else "\u{25BE}" end end,
	}
end

local function buildZoneTax(parent: Instance, baseOrder: number, zoneKey: string, masterField: string, subField: string, labelFn: (any) -> string, descFn: (any) -> string, onHover: any)
	local color = ZONE_COLOR[zoneKey] or GREEN
	-- Zone header row: chip + name + arrow, with the zone's master slider + total estimate.
	-- The master sends only its own field; the server snaps every subtype to it (set-all).
	local hdr = taxRow(parent, baseOrder, { name = zoneKey, color = color, header = true, desc = ZONE_DESC[zoneKey], onHover = onHover, min = TAX_MIN, max = TAX_MAX,
		onChange = function(v) _rates[masterField] = v; if Net and Net.RequestSetBudget then Net.RequestSetBudget:FireServer({ [masterField] = v }) end end })

	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1; holder.Size = UDim2.new(1, 0, 0, 0); holder.ClipsDescendants = true
	holder.LayoutOrder = baseOrder + 1; holder.Visible = false; holder.Parent = parent
	local hl = Instance.new("UIListLayout"); hl.SortOrder = Enum.SortOrder.LayoutOrder; hl.Parent = holder
	local expanded = false
	local function animate(toOpen: boolean)
		if toOpen then
			holder.Visible = true; holder.Size = UDim2.new(1, 0, 0, 0)
			TweenService:Create(holder, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Size = UDim2.new(1, 0, 0, hl.AbsoluteContentSize.Y) }):Play()
		else
			local tw = TweenService:Create(holder, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Size = UDim2.new(1, 0, 0, 0) })
			tw.Completed:Once(function() if not expanded then holder.Visible = false end end)
			tw:Play()
		end
	end
	hdr.nameBtn.Activated:Connect(function()
		expanded = not expanded; hdr.setArrow(expanded); animate(expanded)
	end)

	local rows: { [string]: any } = {}
	local built = false
	_set["tax_" .. zoneKey] = function(master: number, breakdown: any)
		if not hdr.drag() then hdr.setRate(master) end
		if typeof(breakdown) ~= "table" then return end
		if not built then
			local i = 0
			for _, entry in breakdown do
				i += 1
				local k = entry.key
				rows[tostring(k)] = taxRow(holder, i, { name = labelFn(k), color = color, indent = 16, dimZero = true, desc = descFn(k), onHover = onHover, min = TAX_MIN, max = TAX_MAX,
					onChange = function(v)
						local patch = {}; patch[k] = v
						if Net and Net.RequestSetBudget then Net.RequestSetBudget:FireServer({ [subField] = patch }) end
					end })
			end
			built = true
			if expanded then task.defer(function() if expanded then holder.Size = UDim2.new(1, 0, 0, hl.AbsoluteContentSize.Y) end end) end
		end
		local total = 0
		for _, entry in breakdown do
			total += tonumber(entry.income) or 0
			local r = rows[tostring(entry.key)]
			if r then
				if not r.drag() then r.setRate(tonumber(entry.rate) or 9) end
				r.setEst(tonumber(entry.income) or 0)
			end
		end
		hdr.setEst(total)
	end
end

local function buildTaxation(page: ScrollingFrame)
	-- Custom layout: scrolling table on the left, an info/description card on the right,
	-- and the estimated total pinned to the bottom -- so the whole tab is used.
	local rootF = Instance.new("Frame")
	rootF.BackgroundTransparency = 1; rootF.Size = UDim2.new(1, 0, 1, 0); rootF.Parent = page

	-- Right: info / description card.
	local info = Instance.new("Frame")
	info.BorderSizePixel = 0; info.BackgroundColor3 = Color3.fromRGB(255, 255, 255); info.BackgroundTransparency = 0.965
	info.AnchorPoint = Vector2.new(1, 0); info.Position = UDim2.fromScale(1, 0); info.Size = UDim2.new(0.33, 0, 1, -58); info.Parent = rootF
	corner(info, 10)
	local infoStroke = Instance.new("UIStroke"); infoStroke.Color = Theme.Color.StrokeSoft; infoStroke.Transparency = 0.5; infoStroke.Parent = info
	local infoPad = Instance.new("UIPadding")
	infoPad.PaddingTop = UDim.new(0, 16); infoPad.PaddingBottom = UDim.new(0, 16); infoPad.PaddingLeft = UDim.new(0, 16); infoPad.PaddingRight = UDim.new(0, 16); infoPad.Parent = info
	local infoTitle = Instance.new("TextLabel")
	infoTitle.BackgroundTransparency = 1; infoTitle.Size = UDim2.new(1, 0, 0, 26); infoTitle.Text = "Taxation"
	infoTitle.TextColor3 = Theme.Color.TextPrimary; infoTitle.TextSize = Theme.TextSize.LG; infoTitle.FontFace = Theme.Font.Bold
	infoTitle.TextXAlignment = Enum.TextXAlignment.Left; infoTitle.Parent = info
	local infoDesc = Instance.new("TextLabel")
	infoDesc.BackgroundTransparency = 1; infoDesc.Position = UDim2.fromOffset(0, 34); infoDesc.Size = UDim2.new(1, 0, 1, -90)
	infoDesc.Text = ""; infoDesc.TextColor3 = DIM; infoDesc.TextSize = Theme.TextSize.SM; infoDesc.FontFace = Theme.Font.Label
	infoDesc.TextWrapped = true; infoDesc.TextXAlignment = Enum.TextXAlignment.Left; infoDesc.TextYAlignment = Enum.TextYAlignment.Top; infoDesc.Parent = info
	local infoStat = Instance.new("TextLabel")
	infoStat.BackgroundTransparency = 1; infoStat.AnchorPoint = Vector2.new(0, 1); infoStat.Position = UDim2.fromScale(0, 1); infoStat.Size = UDim2.new(1, 0, 0, 22)
	infoStat.Text = ""; infoStat.TextColor3 = GREEN; infoStat.TextSize = Theme.TextSize.SM; infoStat.FontFace = Theme.Font.Header
	infoStat.TextXAlignment = Enum.TextXAlignment.Left; infoStat.Parent = info
	local DEFAULT_DESC = "Hover a row to see what it is. Drag a zone's slider to tax the whole zone, or expand it (the arrow) to fine-tune each income bracket or product type. Rates can go negative -- a subsidy you pay out to keep that zone alive."
	local function showInfo(name: string?, desc: string?, pct: number?, estTxt: string?)
		infoTitle.Text = name or "Taxation"
		infoDesc.Text = desc or DEFAULT_DESC
		if pct then
			infoStat.Text = "Rate " .. tostring(pct) .. "%      " .. (estTxt or "")
			infoStat.TextColor3 = if (estTxt and estTxt:sub(1, 1) == "-") then RED else GREEN
		else
			infoStat.Text = ""
		end
	end
	showInfo()

	-- Left: scrolling table card.
	local leftScroll = Instance.new("ScrollingFrame")
	leftScroll.BorderSizePixel = 0; leftScroll.BackgroundColor3 = Color3.fromRGB(255, 255, 255); leftScroll.BackgroundTransparency = 0.965
	leftScroll.Position = UDim2.fromScale(0, 0); leftScroll.Size = UDim2.new(0.65, 0, 1, -58)
	leftScroll.ScrollBarThickness = 5; leftScroll.ScrollingDirection = Enum.ScrollingDirection.Y
	leftScroll.CanvasSize = UDim2.new(); leftScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y; leftScroll.Parent = rootF
	corner(leftScroll, 10)
	local lStroke = Instance.new("UIStroke"); lStroke.Color = Theme.Color.StrokeSoft; lStroke.Transparency = 0.5; lStroke.Parent = leftScroll
	local ll = Instance.new("UIListLayout"); ll.SortOrder = Enum.SortOrder.LayoutOrder; ll.Parent = leftScroll

	-- Header bar.
	local head = Instance.new("Frame")
	head.BorderSizePixel = 0; head.BackgroundColor3 = Color3.fromRGB(255, 255, 255); head.BackgroundTransparency = 0.88
	head.Size = UDim2.new(1, 0, 0, 26); head.LayoutOrder = 0; head.Parent = leftScroll
	local function title(text: string, position: UDim2, size: UDim2, align: Enum.TextXAlignment)
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1; l.Position = position; l.Size = size; l.Text = text
		l.TextColor3 = DIM; l.TextSize = Theme.TextSize.XS; l.FontFace = Theme.Font.Bold; l.TextXAlignment = align; l.Parent = head
	end
	title("TYPE", UDim2.new(0, 22, 0, 0), UDim2.new(0.34, 0, 1, 0), Enum.TextXAlignment.Left)
	title("TAX RATE", UDim2.fromScale(0.45, 0), UDim2.new(0.30, 0, 1, 0), Enum.TextXAlignment.Left)
	title("ESTIMATE", UDim2.new(0.74, 0, 0, 0), UDim2.new(0.26, -12, 1, 0), Enum.TextXAlignment.Right)

	local function commDesc(k) return "Shops and venues selling " .. tostring(k) .. ". Set the sales tax on this trade." end
	local function indDesc(k) return "Factories producing " .. tostring(k) .. ". Set the tax on this industry." end
	buildZoneTax(leftScroll, 1, "Residential", "R", "res", function(k) return RES_LABELS[tonumber(k)] or ("Level " .. tostring(k)) end, function(k) return RES_DESC[tonumber(k)] or "" end, showInfo)
	buildZoneTax(leftScroll, 20, "Commercial", "C", "comm", function(k) return tostring(k) end, commDesc, showInfo)
	buildZoneTax(leftScroll, 40, "Industrial", "I", "ind", function(k) return tostring(k) end, indDesc, showInfo)

	-- Bottom: estimated grand total, pinned to the bottom of the tab.
	local totalBar = Instance.new("Frame")
	totalBar.BorderSizePixel = 0; totalBar.BackgroundColor3 = Color3.fromRGB(255, 255, 255); totalBar.BackgroundTransparency = 0.9
	totalBar.AnchorPoint = Vector2.new(0, 1); totalBar.Position = UDim2.fromScale(0, 1); totalBar.Size = UDim2.new(1, 0, 0, 46); totalBar.Parent = rootF
	corner(totalBar, 10)
	local tStroke = Instance.new("UIStroke"); tStroke.Color = Theme.Color.StrokeSoft; tStroke.Transparency = 0.55; tStroke.Parent = totalBar
	local fl = Instance.new("TextLabel")
	fl.BackgroundTransparency = 1; fl.Position = UDim2.new(0, 18, 0, 0); fl.Size = UDim2.new(0.5, 0, 1, 0)
	fl.Text = "ESTIMATED TOTAL"; fl.TextColor3 = Theme.Color.TextPrimary; fl.TextSize = Theme.TextSize.MD; fl.FontFace = Theme.Font.Bold
	fl.TextXAlignment = Enum.TextXAlignment.Left; fl.Parent = totalBar
	local fpill = Instance.new("TextLabel")
	fpill.AnchorPoint = Vector2.new(1, 0.5); fpill.Position = UDim2.new(1, -12, 0.5, 0); fpill.Size = UDim2.fromOffset(140, 30)
	fpill.BackgroundColor3 = Color3.fromRGB(15, 18, 23); fpill.BackgroundTransparency = 0.1
	fpill.Text = "+$0"; fpill.TextColor3 = GREEN; fpill.TextSize = Theme.TextSize.LG; fpill.FontFace = Theme.Font.Bold
	fpill.TextXAlignment = Enum.TextXAlignment.Right; fpill.Parent = totalBar
	corner(fpill, 6)
	local fpad = Instance.new("UIPadding"); fpad.PaddingLeft = UDim.new(0, 8); fpad.PaddingRight = UDim.new(0, 12); fpad.Parent = fpill
	_set.taxTotal = function(n: number)
		local v = tonumber(n) or 0
		fpill.Text = signed(v); fpill.TextColor3 = if v < 0 then RED else GREEN
	end
end

local function buildServices(page: ScrollingFrame)
	sectionLabel(page, 1, "SERVICE FUNDING")
	local function svc(order, key, name, color)
		local setV, dragV, setE = sliderRow(page, order, name, color, FUND_MIN, FUND_MAX, function(v)
			_funding[key] = v; if Net and Net.RequestSetBudget then Net.RequestSetBudget:FireServer({ funding = _funding }) end
		end)
		return { set = setV, drag = dragV, est = setE }
	end
	local pol = svc(2, "Police", "Police", Color3.fromRGB(86, 140, 210))
	local fire = svc(3, "Fire", "Fire", Color3.fromRGB(220, 120, 90))
	local hea = svc(4, "Health", "Healthcare", Color3.fromRGB(206, 90, 96))
	local edu = svc(5, "Education", "Education", Color3.fromRGB(150, 190, 120))
	_set.services = function(f, p)
		if typeof(f) ~= "table" then return end
		if not pol.drag() then pol.set(tonumber(f.Police) or 100) end
		if not fire.drag() then fire.set(tonumber(f.Fire) or 100) end
		if not hea.drag() then hea.set(tonumber(f.Health) or 100) end
		if not edu.drag() then edu.set(tonumber(f.Education) or 100) end
		pol.est("-" .. money(tonumber(p.upkeepPolice) or 0))
		fire.est("-" .. money(tonumber(p.upkeepFire) or 0))
		hea.est("-" .. money(tonumber(p.upkeepHealth) or 0))
		edu.est("-" .. money(tonumber(p.upkeepEducation) or 0))
	end
end

local function buildLoans(page: ScrollingFrame)
	sectionLabel(page, 1, "LOANS")
	local bal = statRow(page, 2, "Balance", true)
	local lim = statRow(page, 3, "Borrow limit")
	local rate = statRow(page, 4, "Interest rate")
	local cost = statRow(page, 5, "Monthly interest")
	local annual = 0.08

	-- Loan amount slider (0-100% of the borrow limit). The right-hand estimate shows the
	-- chosen amount live; releasing commits it. Forward-declared so the drag closure can
	-- call the slider's own setEstimate.
	local setPct: (number) -> ()
	local dragPct: () -> boolean
	local setEst: (string) -> ()
	local function onSlide(pct: number, final: boolean)
		local target = math.floor((pct / 100) * _loan.limit + 0.5)
		if setEst then setEst(money(target) .. "  (\u{2212}" .. money(target * annual / 12) .. "/mo)") end
		if final and Net and Net.RequestSetBudget then Net.RequestSetBudget:FireServer({ loan = target }) end
	end
	setPct, dragPct, setEst = sliderRow(page, 6, "Loan amount", Color3.fromRGB(90, 170, 120), 0, 100, onSlide)

	local btnRow = Instance.new("Frame")
	btnRow.BackgroundTransparency = 1; btnRow.Size = UDim2.new(1, 0, 0, 38); btnRow.LayoutOrder = 7; btnRow.Parent = page
	local bl = Instance.new("UIListLayout"); bl.FillDirection = Enum.FillDirection.Horizontal; bl.HorizontalAlignment = Enum.HorizontalAlignment.Center
	bl.VerticalAlignment = Enum.VerticalAlignment.Center; bl.Padding = UDim.new(0, Theme.Pad.SM); bl.Parent = btnRow
	local function mkBtn(text, order, color, fn)
		local b = Instance.new("TextButton"); b.AutoButtonColor = true; b.Size = UDim2.new(0, 150, 1, 0); b.LayoutOrder = order
		b.Text = text; b.TextColor3 = Color3.fromRGB(245, 246, 248); b.TextSize = Theme.TextSize.SM; b.FontFace = Theme.Font.Bold
		b.BackgroundColor3 = color; b.BorderSizePixel = 0; b.Parent = btnRow; corner(b, 6); b.Activated:Connect(fn)
	end
	mkBtn("Borrow $25k", 1, Color3.fromRGB(70, 150, 90), function()
		if Net and Net.RequestSetBudget then Net.RequestSetBudget:FireServer({ loan = math.min(_loan.principal + 25000, _loan.limit) }) end
	end)
	mkBtn("Repay $25k", 2, Color3.fromRGB(170, 90, 90), function()
		if Net and Net.RequestSetBudget then Net.RequestSetBudget:FireServer({ loan = math.max(_loan.principal - 25000, 0) }) end
	end)
	_set.loans = function(p)
		_loan.principal = tonumber(p.loanPrincipal) or 0
		_loan.limit = tonumber(p.loanLimit) or 0
		annual = tonumber(p.loanAnnualRate) or 0.08
		bal.Text = money(_loan.principal)
		lim.Text = money(_loan.limit)
		rate.Text = tostring(math.floor(annual * 100 + 0.5)) .. "%"
		cost.Text = "-" .. money(tonumber(p.loanInterest) or 0); cost.TextColor3 = RED
		if not dragPct() then
			local pct = if _loan.limit > 0 then math.clamp(_loan.principal / _loan.limit * 100, 0, 100) else 0
			setPct(pct)
			setEst(money(_loan.principal) .. "  (\u{2212}" .. money(_loan.principal * annual / 12) .. "/mo)")
		end
	end
end

local function buildProduction(page: ScrollingFrame)
	sectionLabel(page, 1, "GOODS")
	local output = statRow(page, 2, "Industry output")
	local need = statRow(page, 3, "Commerce need")
	local supplied = statRow(page, 4, "Locally supplied")
	_set.production = function(p)
		output.Text = commaInt(tonumber(p.output) or 0)
		need.Text = commaInt(tonumber(p.need) or 0)
		supplied.Text = tostring(math.floor(math.clamp(tonumber(p.supplyRatio) or 0, 0, 1) * 100 + 0.5)) .. "%"
	end
end

local function selectTab(key: string)
	_activeTab = key
	for k, t in _tabs do
		t.page.Visible = (k == key)
		t.btn.BackgroundTransparency = if k == key then 0 else 1
		t.btn.TextColor3 = if k == key then Theme.Color.TextPrimary else DIM
	end
end

local function build(gui: ScreenGui)
	local root = Instance.new("CanvasGroup")
	root.Name = "EconomyRoot"; root.AnchorPoint = Vector2.new(0.5, 0.5); root.Position = UDim2.fromScale(0.5, 0.5)
	root.Size = UDim2.fromScale(0.62, 0.8); root.GroupTransparency = 1; root.Visible = false; root.ZIndex = Theme.Z.Flyout
	Glass.apply(root, Theme.Radius.LG); root.Parent = gui
	_root = root
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, Theme.Pad.LG); pad.PaddingBottom = UDim.new(0, Theme.Pad.LG)
	pad.PaddingLeft = UDim.new(0, Theme.Pad.LG); pad.PaddingRight = UDim.new(0, Theme.Pad.LG); pad.Parent = root

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1; title.Size = UDim2.new(1, -40, 0, 30); title.Text = "Economy"
	title.TextColor3 = Theme.Color.TextPrimary; title.TextSize = Theme.TextSize.LG; title.FontFace = Theme.Font.Bold
	title.TextXAlignment = Enum.TextXAlignment.Left; title.Parent = root

	local closeBtn = Instance.new("TextButton")
	closeBtn.AnchorPoint = Vector2.new(1, 0); closeBtn.Position = UDim2.fromScale(1, 0); closeBtn.Size = UDim2.fromOffset(30, 30)
	closeBtn.Text = "\u{2715}"; closeBtn.TextColor3 = Theme.Color.TextPrimary; closeBtn.TextSize = Theme.TextSize.MD
	closeBtn.FontFace = Theme.Font.Bold; closeBtn.BackgroundTransparency = 1; closeBtn.Parent = root
	closeBtn.Activated:Connect(function() EconomyPanelController.Close() end)

	local tabRow = Instance.new("Frame")
	tabRow.BackgroundTransparency = 1; tabRow.Position = UDim2.fromOffset(0, 38); tabRow.Size = UDim2.new(1, 0, 0, 30); tabRow.Parent = root
	local tl = Instance.new("UIListLayout"); tl.FillDirection = Enum.FillDirection.Horizontal; tl.Padding = UDim.new(0, Theme.Pad.XS); tl.Parent = tabRow

	-- Summary strip: always-visible treasury + monthly net, so no tab ever feels empty.
	local summary = Instance.new("Frame")
	summary.BackgroundColor3 = Color3.fromRGB(255, 255, 255); summary.BackgroundTransparency = 0.94
	summary.Position = UDim2.fromOffset(0, 74); summary.Size = UDim2.new(1, 0, 0, 40); summary.Parent = root
	corner(summary, 8)
	local sPad = Instance.new("UIPadding"); sPad.PaddingLeft = UDim.new(0, 12); sPad.PaddingRight = UDim.new(0, 12); sPad.Parent = summary
	local sBal = Instance.new("TextLabel")
	sBal.BackgroundTransparency = 1; sBal.AnchorPoint = Vector2.new(0, 0.5); sBal.Position = UDim2.fromScale(0, 0.5); sBal.Size = UDim2.new(0.6, 0, 1, 0)
	sBal.Text = "$0"; sBal.TextColor3 = GREEN; sBal.TextSize = Theme.TextSize.LG; sBal.FontFace = Theme.Font.Bold
	sBal.TextXAlignment = Enum.TextXAlignment.Left; sBal.Parent = summary
	local sNet = Instance.new("TextLabel")
	sNet.BackgroundTransparency = 1; sNet.AnchorPoint = Vector2.new(1, 0.5); sNet.Position = UDim2.fromScale(1, 0.5); sNet.Size = UDim2.new(0.4, 0, 1, 0)
	sNet.Text = ""; sNet.TextColor3 = DIM; sNet.TextSize = Theme.TextSize.SM; sNet.FontFace = Theme.Font.Header
	sNet.TextXAlignment = Enum.TextXAlignment.Right; sNet.Parent = summary
	_set.summary = function(p)
		sBal.Text = money(tonumber(p.money) or 0)
		local nm = tonumber(p.monthlyNet) or 0
		sNet.Text = signed(nm) .. " /mo"
		sNet.TextColor3 = if nm < 0 then RED else GREEN
	end

	local content = Instance.new("Frame")
	content.BackgroundTransparency = 1; content.Position = UDim2.fromOffset(0, 122); content.Size = UDim2.new(1, 0, 1, -122); content.Parent = root

	local order = { "Budget", "Taxation", "Services", "Loans", "Production" }
	local builders = { Budget = buildBudget, Taxation = buildTaxation, Services = buildServices, Loans = buildLoans, Production = buildProduction }
	for i, key in order do
		local page = makePage(key); page.Parent = content
		builders[key](page)
		local btn = Instance.new("TextButton")
		btn.LayoutOrder = i; btn.Size = UDim2.fromOffset(96, 28); btn.Text = key; btn.AutoButtonColor = false
		btn.BackgroundColor3 = Theme.Color.BgPress; btn.BackgroundTransparency = 1; btn.TextColor3 = DIM
		btn.TextSize = Theme.TextSize.SM; btn.FontFace = Theme.Font.Header; btn.BorderSizePixel = 0; btn.Parent = tabRow
		corner(btn, 6)
		btn.Activated:Connect(function() selectTab(key) end)
		_tabs[key] = { btn = btn, page = page }
	end
	selectTab("Budget")
end

function EconomyPanelController.Open(tab: string?)
	if not _root then return end
	if tab and _tabs[tab] then selectTab(tab) end
	_open = true
	(_root :: CanvasGroup).Visible = true
	;(_root :: CanvasGroup).GroupTransparency = 0
	if not _blur then
		local b = Instance.new("BlurEffect"); b.Size = 16; b.Name = "EconomyBlur"; b.Parent = Lighting; _blur = b
	else
		_blur.Enabled = true
	end
end

function EconomyPanelController.Close()
	_open = false
	if _root then (_root :: CanvasGroup).Visible = false end
	if _blur then _blur.Enabled = false end
end

function EconomyPanelController.Toggle(tab: string?)
	if _open then EconomyPanelController.Close() else EconomyPanelController.Open(tab) end
end

function EconomyPanelController.IsOpen(): boolean return _open end

function EconomyPanelController.Start()
	if _started then return end
	_started = true
	local player = Players.LocalPlayer
	local pg = player:WaitForChild("PlayerGui")
	local gui = pg:WaitForChild("CityUI", 60)
	if not gui or not gui:IsA("ScreenGui") then warn("[EconomyPanelController] CityUI not found"); _started = false; return end
	Net = require(ReplicatedStorage:WaitForChild("Networker"))
	build(gui)
	require(ReplicatedStorage:WaitForChild("City"):WaitForChild("UIEvents")).SettingsOpened.Event:Connect(function()
		EconomyPanelController.Close()
	end)
	Net.SyncEconomy.OnClientEvent:Connect(function(p: any)
		if typeof(p) ~= "table" then return end
		if typeof(p.taxRates) == "table" then _rates.R = tonumber(p.taxRates.R) or _rates.R; _rates.C = tonumber(p.taxRates.C) or _rates.C; _rates.I = tonumber(p.taxRates.I) or _rates.I end
		if typeof(p.funding) == "table" then for k, v in p.funding do _funding[k] = tonumber(v) or _funding[k] end end
		if _set.summary then _set.summary(p) end
		if _set.budget then _set.budget(p) end
		if _set.loans then _set.loans(p) end
		if _set.production then _set.production(p) end
		if _set.services then _set.services(p.funding, p) end
		local tb = p.taxBreakdown
		if typeof(tb) == "table" then
			if _set.tax_Residential then _set.tax_Residential(_rates.R, tb.residential) end
			if _set.tax_Commercial then _set.tax_Commercial(_rates.C, tb.commercial) end
			if _set.tax_Industrial then _set.tax_Industrial(_rates.I, tb.industrial) end
			if _set.taxTotal then
				local grand = 0
				for _, group in { tb.residential, tb.commercial, tb.industrial } do
					if typeof(group) == "table" then for _, e in group do grand += tonumber(e.income) or 0 end end
				end
				_set.taxTotal(grand)
			end
		end
	end)
end

return EconomyPanelController
