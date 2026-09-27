--!strict
-- UIVisibility -- hides every piece of on-screen UI, for screenshots and recording.
--
-- Driven by the rebindable "ToggleUI" action (Alt+H by default, Settings > Keyboard >
-- Navigation) and by a small button of its own. The button lives in this script's own
-- ScreenGui and hides along with everything else, so once the UI is away the shortcut is
-- the only way back -- which is why the default bind is a chord rather than a bare key.
--
-- Restoring puts back EXACTLY what was on screen before, and nothing else: each ScreenGui's
-- Enabled value is recorded on the way down and only those go back up. Anything that turns
-- itself on behind the curtain is switched straight off again and is NOT recorded, so the
-- restore never hands the player a panel they had not opened. The Roblox core UI is left
-- alone entirely -- LoadingController switches it off for the whole session, so flipping it
-- back on here used to pop the chat and backpack onto a screen that never had them.
--
-- In-city only: in the main menu there is nothing to hide, and hiding the menu leaves a
-- blank screen with no way back except a chord the player cannot see advertised.
--
-- A LocalScript rather than a controller module: it owns no game state and nothing else
-- needs to call it, so there is nothing for a bootstrap to wire up.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local PlayerScripts = script.Parent.Parent
local UI = PlayerScripts:WaitForChild("UI")
local Theme = require(UI:WaitForChild("Theme"))
local Settings = require(PlayerScripts:WaitForChild("Core"):WaitForChild("Settings"))
local UIEvents = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("UIEvents"))

local ACTION = "ToggleUI"
local GUI_NAME = "_UIVisibility"
local BTN = 30
local MARGIN = 10

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local _hidden = false
local _inGame = false
-- Enabled state per ScreenGui at the moment we hid it. Weak-keyed so a gui destroyed while
-- hidden does not keep its instance alive here.
local _wasEnabled: { [ScreenGui]: boolean } = setmetatable({}, { __mode = "k" }) :: any
-- Live only while hidden: one Enabled watcher per gui, holding the curtain shut.
local _guards: { RBXScriptConnection } = {}
local _ownGui: ScreenGui? = nil

local function manageable(inst: Instance): ScreenGui?
	if not inst:IsA("ScreenGui") then
		return nil
	end
	-- Our own gui is hidden too, but through the same path as the rest.
	return inst :: ScreenGui
end

-- Hold one gui down for as long as the curtain is up. Re-disabling inside the handler fires
-- the signal again, which the `gui.Enabled` test then ignores.
local function guard(gui: ScreenGui)
	table.insert(_guards, gui:GetPropertyChangedSignal("Enabled"):Connect(function()
		if _hidden and gui.Enabled then
			gui.Enabled = false
		end
	end))
end

local function applyHidden()
	for _, inst in playerGui:GetChildren() do
		local gui = manageable(inst)
		if gui then
			if gui.Enabled then
				_wasEnabled[gui] = true
				gui.Enabled = false
			end
			guard(gui)
		end
	end
end

local function setHidden(hidden: boolean)
	if hidden == _hidden then
		return
	end
	_hidden = hidden

	if hidden then
		table.clear(_wasEnabled :: any)
		applyHidden()
	else
		for _, c in _guards do
			c:Disconnect()
		end
		table.clear(_guards)
		for gui, was in _wasEnabled :: any do
			if was and (gui :: ScreenGui).Parent then
				(gui :: ScreenGui).Enabled = true
			end
		end
		table.clear(_wasEnabled :: any)
	end
end

-- A gui created while hidden must not appear, and must NOT be recorded: the player never
-- had it open, so the restore has no business opening it for them.
playerGui.ChildAdded:Connect(function(inst: Instance)
	if not _hidden then
		return
	end
	local gui = manageable(inst)
	if gui then
		gui.Enabled = false
		guard(gui)
	end
end)

UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	-- `processed` is ignored: with the UI hidden there is nothing to have eaten the key,
	-- and while it is shown a chord on Alt is not something a text box wants either.
	if _inGame and Settings.pressed(ACTION, input) then
		setHidden(not _hidden)
	end
end)

-- ------------------------------------------------------------------- button --

local gui = Instance.new("ScreenGui")
gui.Name = GUI_NAME
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = Theme.Layer.Dev
-- Disabled BEFORE parenting: that is how LoadingController tells a panel that means to start
-- closed from one it switched off itself, so it never tags this and the menu never opens it.
gui.Enabled = false
gui.Parent = playerGui
_ownGui = gui

local btn = Instance.new("TextButton")
btn.Name = "HideUI"
btn.AnchorPoint = Vector2.new(1, 0)
btn.Position = UDim2.new(1, -MARGIN, 0, MARGIN + 44)
btn.Size = UDim2.fromOffset(BTN, BTN)
btn.BackgroundColor3 = Theme.Color.BgRaised
btn.BackgroundTransparency = 0.15
btn.BorderSizePixel = 0
btn.AutoButtonColor = true
btn.FontFace = Theme.Font.Bold
btn.TextSize = Theme.TextSize.SM
btn.TextColor3 = Theme.Color.TextSecondary
btn.Text = "\u{1F441}"
btn.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 6)
corner.Parent = btn

btn.Activated:Connect(function()
	setHidden(true)
end)

-- The tooltip has to name the shortcut: this button is the only hint the player gets, and
-- once it is hidden the keybind is the sole way back.
local hint = Instance.new("TextLabel")
hint.Name = "Hint"
hint.AnchorPoint = Vector2.new(1, 0.5)
hint.Position = UDim2.new(0, -6, 0.5, 0)
hint.Size = UDim2.fromOffset(120, 20)
hint.BackgroundColor3 = Theme.Color.BgRaised
hint.BackgroundTransparency = 0.15
hint.BorderSizePixel = 0
hint.FontFace = Theme.Font.Label
hint.TextSize = Theme.TextSize.XS
hint.TextColor3 = Theme.Color.TextSecondary
hint.Text = "Hide UI " .. Settings.bindLabel(Settings.getBind(ACTION))
hint.Visible = false
hint.Parent = btn

local hintCorner = Instance.new("UICorner")
hintCorner.CornerRadius = UDim.new(0, 4)
hintCorner.Parent = hint

btn.MouseEnter:Connect(function()
	hint.Visible = true
end)
btn.MouseLeave:Connect(function()
	hint.Visible = false
end)

-- Rebinding the action has to update the hint, or it advertises a key that no longer works.
Settings.onBindChanged(function(action: string)
	if action == ACTION then
		hint.Text = "Hide UI " .. Settings.bindLabel(Settings.getBind(ACTION))
	end
end)

-- ---------------------------------------------------------------- in-city --

UIEvents.GameEntered.Event:Connect(function()
	_inGame = true
	gui.Enabled = true
end)

UIEvents.ReturnToMainMenu.Event:Connect(function()
	setHidden(false) -- never leave the menu behind a curtain the shortcut no longer lifts
	_inGame = false
	gui.Enabled = false
end)
