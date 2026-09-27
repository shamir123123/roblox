--!strict
-- BankruptcyController
-- Hard game-over screen. When the server declares the city bankrupt (Net.Bankruptcy)
-- this drops a full-screen overlay that blocks interaction and offers a restart. The
-- simulation is already frozen server-side (GameSpeed 0); this is purely the UI.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService   = game:GetService("TeleportService")

local uiFolder = script.Parent.Parent:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local Format = require(uiFolder:WaitForChild("Format"))
local Glass = require(uiFolder:WaitForChild("Kit"):WaitForChild("Glass"))

local BankruptcyController = {}

local RED = Color3.fromRGB(230, 96, 96)
local _started = false
local _overlay: Instance? = nil


local function statLine(parent: Instance, order: number, label: string, value: string)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 22)
	row.LayoutOrder = order
	row.ZIndex = 5002
	row.Parent = parent

	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.AnchorPoint = Vector2.new(0, 0.5)
	l.Position = UDim2.fromScale(0, 0.5)
	l.Size = UDim2.new(0.6, 0, 1, 0)
	l.Text = label
	l.TextColor3 = Theme.Color.TextSecondary
	l.TextSize = Theme.TextSize.SM
	l.FontFace = Theme.Font.Label
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.ZIndex = 5002
	l.Parent = row

	local v = Instance.new("TextLabel")
	v.BackgroundTransparency = 1
	v.AnchorPoint = Vector2.new(1, 0.5)
	v.Position = UDim2.fromScale(1, 0.5)
	v.Size = UDim2.new(0.4, 0, 1, 0)
	v.Text = value
	v.TextColor3 = Theme.Color.TextPrimary
	v.TextSize = Theme.TextSize.SM
	v.FontFace = Theme.Font.Bold
	v.TextXAlignment = Enum.TextXAlignment.Right
	v.ZIndex = 5002
	v.Parent = row
end

local function show(gui: ScreenGui, data: any)
	if _overlay then return end -- one game-over screen only

	local backdrop = Instance.new("TextButton")
	backdrop.Name = "BankruptcyOverlay"
	backdrop.Text = ""
	backdrop.AutoButtonColor = false
	backdrop.Modal = true -- swallow input under the overlay
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Color3.fromRGB(8, 8, 10)
	backdrop.BackgroundTransparency = 0.2
	backdrop.BorderSizePixel = 0
	backdrop.ZIndex = 5000
	backdrop.Parent = gui
	_overlay = backdrop

	local card = Instance.new("Frame")
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromOffset(400, 286)
	card.BackgroundColor3 = Color3.fromRGB(24, 26, 30)
	card.BorderSizePixel = 0
	card.ZIndex = 5001
	card.Parent = backdrop
	pcall(Glass.apply, card, Theme.Radius.LG)

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 24); pad.PaddingBottom = UDim.new(0, 24)
	pad.PaddingLeft = UDim.new(0, 28); pad.PaddingRight = UDim.new(0, 28)
	pad.Parent = card

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 10)
	list.Parent = card

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0, 40)
	title.LayoutOrder = 1
	title.Text = "BANKRUPT"
	title.TextColor3 = RED
	title.TextSize = 34
	title.FontFace = Theme.Font.Bold
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 5002
	title.Parent = card

	local sub = Instance.new("TextLabel")
	sub.BackgroundTransparency = 1
	sub.Size = UDim2.new(1, 0, 0, 40)
	sub.LayoutOrder = 2
	sub.Text = "Your city ran out of money and could no longer pay its bills."
	sub.TextWrapped = true
	sub.TextColor3 = Theme.Color.TextSecondary
	sub.TextSize = Theme.TextSize.SM
	sub.FontFace = Theme.Font.Label
	sub.TextXAlignment = Enum.TextXAlignment.Left
	sub.ZIndex = 5002
	sub.Parent = card

	local div = Instance.new("Frame")
	div.BackgroundColor3 = Theme.Color.StrokeSoft
	div.BorderSizePixel = 0
	div.Size = UDim2.new(1, 0, 0, 1)
	div.LayoutOrder = 3
	div.ZIndex = 5002
	div.Parent = card

	local money = if typeof(data) == "table" then tonumber(data.money) or 0 else 0
	local pop = if typeof(data) == "table" then tonumber(data.population) or 0 else 0
	statLine(card, 4, "Final balance", "-$" .. Format.int(math.abs(money)))
	statLine(card, 5, "Population at end", Format.int(pop))

	local btn = Instance.new("TextButton")
	btn.AutoButtonColor = true
	btn.Size = UDim2.new(1, 0, 0, 44)
	btn.LayoutOrder = 6
	btn.Text = "Return to Menu"
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.TextSize = Theme.TextSize.MD
	btn.FontFace = Theme.Font.Bold
	btn.BackgroundColor3 = RED
	btn.BorderSizePixel = 0
	btn.ZIndex = 5002
	btn.Parent = card
	local bc = Instance.new("UICorner"); bc.CornerRadius = UDim.new(0, 8); bc.Parent = btn

	btn.Activated:Connect(function()
		btn.Text = "Restarting..."
		local ok = pcall(function()
			TeleportService:Teleport(game.PlaceId, Players.LocalPlayer)
		end)
		if not ok then
			-- Studio / teleport unavailable: a rejoin reloads the slot with a fresh-start grant.
			btn.Text = "Rejoin the game to start over"
		end
	end)
end

function BankruptcyController.Start()
	if _started then return end
	_started = true

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local gui = playerGui:WaitForChild("CityUI", 60)
	if not gui or not gui:IsA("ScreenGui") then
		warn("[BankruptcyController] CityUI not found")
		_started = false
		return
	end

	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	Net.Bankruptcy.OnClientEvent:Connect(function(data: any)
		show(gui, data)
	end)
end

return BankruptcyController
