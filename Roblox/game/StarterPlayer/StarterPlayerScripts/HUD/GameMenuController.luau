--!strict
-- THE IN-GAME MENU: save, settings, resume, quit to main menu.
--
-- Was HUDController, a name it had outgrown. That module was documented as "the
-- top status bar" but every readout it once owned -- money, population, clock,
-- speed, demand -- had already moved out, leaving ~400 lines of builders that
-- nothing called (buildRCI, buildSpeed, stackBlock, revealCluster, the demand
-- tooltip) around one menu. The dead half is gone and the name now says what is
-- left. Nothing outside referenced it but Bootstrap's startUI string.
--
-- Opened by TopLeftCluster's menu chip via UIEvents.MenuRequested, so the chip
-- and the menu do not require each other.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local playerScripts = script.Parent.Parent
local uiFolder = playerScripts:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local UITween = require(uiFolder:WaitForChild("UITween"))
local HudScale = require(uiFolder:WaitForChild("HudScale"))
local kit = uiFolder:WaitForChild("Kit")
local Glass = require(kit:WaitForChild("Glass"))
local Button = require(kit:WaitForChild("Button"))
local UIEvents = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("UIEvents"))

local GameMenuController = {}

local PANEL_W = 272
local ROW_H = 38

local _started = false
local _scrim: TextButton? = nil
local _panel: Frame? = nil
local _open = false
local _conns: { RBXScriptConnection } = {}

local function track(conn: RBXScriptConnection)
	table.insert(_conns, conn)
end

local function buildMenu(gui: ScreenGui)
	local scrim = Instance.new("TextButton")
	scrim.Name = "MenuScrim"
	scrim.AutoButtonColor = false
	scrim.Text = ""
	-- ponytail: CityUI has IgnoreGuiInset = false, so fromScale(1,1) leaves the
	-- topbar strip undimmed. Overshoot past it.
	scrim.Position = UDim2.fromOffset(0, -100)
	scrim.Size = UDim2.new(1, 0, 1, 100)
	scrim.BackgroundColor3 = Theme.Color.Scrim
	scrim.BackgroundTransparency = 1
	scrim.BorderSizePixel = 0
	scrim.Visible = false
	scrim.ZIndex = Theme.Z.Modal
	scrim.Parent = gui
	_scrim = scrim

	local panel = Instance.new("Frame")
	panel.Name = "GameMenu"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(PANEL_W, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.ZIndex = Theme.Z.Modal
	Glass.apply(panel, Theme.Radius.Panel)
	panel.Parent = scrim
	_panel = panel

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, Theme.Pad.XL)
	pad.PaddingBottom = UDim.new(0, Theme.Pad.XL)
	pad.PaddingLeft = UDim.new(0, Theme.Pad.XL)
	pad.PaddingRight = UDim.new(0, Theme.Pad.XL)
	pad.Parent = panel

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, Theme.Pad.MD)
	list.Parent = panel

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0, 20)
	title.Text = "MENU"
	title.TextColor3 = Theme.Color.Brand
	title.TextSize = Theme.TextSize.XS
	title.FontFace = Theme.Font.Bold
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.LayoutOrder = 0
	title.Parent = panel

	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	local NotificationController = require(script.Parent:WaitForChild("NotificationController"))
	local saving = false

	local saveBtn = Button.new({
		text = "Save City",
		parent = panel,
		size = UDim2.new(1, 0, 0, ROW_H),
		layoutOrder = 1,
	})
	saveBtn:SetSelected(true) -- primary action: filled accent capsule
	track(saveBtn.Instance.Activated:Connect(function()
		if saving then
			return
		end
		saving = true
		saveBtn.Instance.Text = "SAVING\u{2026}"
		task.spawn(function()
			local ok, success, info = pcall(function()
				return Net.RequestSaveCity:InvokeServer()
			end)
			saving = false
			saveBtn.Instance.Text = "SAVE CITY"
			if ok and success then
				NotificationController.Notify({ text = "City saved", kind = "success" })
			else
				NotificationController.Notify({
					text = (typeof(info) == "string" and info) or "Save failed",
					kind = "danger",
				})
			end
		end)
	end))

	Button.new({
		text = "Settings",
		parent = panel,
		size = UDim2.new(1, 0, 0, ROW_H),
		layoutOrder = 2,
		onClick = function()
			GameMenuController.Close()
			require(uiFolder:WaitForChild("SettingsPanel")).Open()
		end,
	})

	Button.new({
		text = "Resume",
		parent = panel,
		size = UDim2.new(1, 0, 0, ROW_H),
		layoutOrder = 3,
		onClick = function()
			GameMenuController.Close()
		end,
	})

	Button.new({
		text = "Main Menu",
		parent = panel,
		size = UDim2.new(1, 0, 0, ROW_H),
		layoutOrder = 4,
		variant = "Danger",
		onClick = function()
			GameMenuController.Close()
			UIEvents.ReturnToMainMenu:Fire()
		end,
	})

	track(scrim.Activated:Connect(function()
		GameMenuController.Close()
	end))
end

function GameMenuController.IsOpen(): boolean
	return _open
end

function GameMenuController.Open()
	local scrim, panel = _scrim, _panel
	if _open or not scrim or not panel then
		return
	end
	_open = true
	scrim.Visible = true
	panel.Size = UDim2.fromOffset(PANEL_W, 0)
	UITween.to(scrim, "Modal", { BackgroundTransparency = Theme.ScrimOpacity })
end

function GameMenuController.Close()
	local scrim = _scrim
	if not _open or not scrim then
		return
	end
	_open = false
	local tween = UITween.to(scrim, "Modal", { BackgroundTransparency = 1 })
	tween.Completed:Once(function()
		-- Guard the token: a reopen during the fade must not be hidden by the
		-- close that started before it.
		if not _open and scrim then
			scrim.Visible = false
		end
	end)
end

function GameMenuController.Toggle()
	if _open then
		GameMenuController.Close()
	else
		GameMenuController.Open()
	end
end

function GameMenuController.Start()
	if _started then
		return
	end
	_started = true

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = playerGui:WaitForChild("CityUI", 60)
	if not gui or not gui:IsA("ScreenGui") then
		warn("[GameMenuController] CityUI not found - aborting")
		_started = false
		return
	end

	HudScale.attach(gui)
	buildMenu(gui)

	track(UIEvents.MenuRequested.Event:Connect(function()
		GameMenuController.Toggle()
	end))
	track(UIEvents.SettingsOpened.Event:Connect(function()
		GameMenuController.Close()
	end))
end

function GameMenuController.Cleanup()
	for _, c in _conns do
		c:Disconnect()
	end
	table.clear(_conns)
	_started = false
end

return GameMenuController
