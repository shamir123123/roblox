--!strict
-- Toast notifications. A self-contained stack of transient messages for city
-- events (city loaded, low funds, milestones). Any controller calls
-- NotificationController.Notify{ text = ..., kind = ..., duration = ... }.
-- No server dependency; toasts live in the cloned Notifications ScreenGui.

local Players = game:GetService("Players")

local uiFolder = script.Parent.Parent:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
-- Toasts ride the same UIScale as the rest of the HUD, so a 420px stack does not stay
-- 420px wide on a phone while everything around it shrinks.
local HudScale = require(uiFolder:WaitForChild("HudScale"))
local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))
local UITween = require(uiFolder:WaitForChild("UITween"))
local Glass = require(uiFolder:WaitForChild("Kit"):WaitForChild("Glass"))

local NotificationController = {}

export type Kind = "info" | "success" | "warning" | "danger"

local ACCENT: { [string]: Color3 } = {
	info    = Color3.fromRGB(200, 200, 196), -- neutral light: a plain informational toast (was blue)
	success = Color3.fromRGB(120, 220, 140),
	warning = Color3.fromRGB(226, 140, 84),  -- warm orange caution, distinct from danger red (was gold)
	danger  = Theme.Color.Danger,
}

local MAX_TOASTS = 4
local DEFAULT_DURATION = 4

local _started = false
local _container: Frame? = nil
local _toasts: { GuiObject } = {}
local _seq = 0

local function ensureContainer(): Frame?
	if _container and _container.Parent then
		return _container
	end

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	local gui = playerGui:FindFirstChild("Notifications")
	if not gui or not gui:IsA("ScreenGui") then
		local newGui = Instance.new("ScreenGui")
		newGui.Name = "Notifications"
		newGui.ResetOnSpawn = false
		newGui.IgnoreGuiInset = false
		newGui.DisplayOrder = Theme.Layer.Toast
		newGui.Parent = playerGui
		gui = newGui
	else
		gui.DisplayOrder = Theme.Layer.Toast
	end

	HudScale.attach(gui)

	local existing = gui:FindFirstChild("ToastStack")
	if existing and existing:IsA("Frame") then
		_container = existing
		return existing
	end

	local frame = Instance.new("Frame")
	frame.Name = "ToastStack"
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = -- 48, not 24: the tool banners (LaneConnector, NodeTool) occupy the centred band from
	-- y=14 to y=40, and toasts starting at 24 cut straight through them.
	UDim2.new(0.5, 0, 0, 48)
	frame.Size = UDim2.fromOffset(420, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.BackgroundTransparency = 1
	frame.ZIndex = Theme.Z.Tooltip
	frame.Parent = gui

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, Theme.Pad.SM)
	list.Parent = frame

	_container = frame
	return frame
end

local function dismiss(toast: GuiObject)
	local idx = table.find(_toasts, toast)
	if idx then
		table.remove(_toasts, idx)
	end
	if not toast.Parent then
		return
	end
	if toast:IsA("CanvasGroup") then
		local tween = UITween.to(toast, "Flyout", { GroupTransparency = 1 })
		tween.Completed:Once(function()
			toast:Destroy()
		end)
	else
		toast:Destroy()
	end
end

-- ponytail: all toasts disabled by request; delete this early return to re-enable.
local DISABLED = true

function NotificationController.Notify(opts: { text: string, kind: Kind?, duration: number? })
	if DISABLED or Settings.get("notifications") == false then return end
	local container = ensureContainer()
	if not container then
		return
	end
	if typeof(opts) ~= "table" or typeof(opts.text) ~= "string" then
		return
	end

	local kind: string = opts.kind or "info"
	local accent = ACCENT[kind] or ACCENT.info

	_seq -= 1 -- newest toast gets the smallest LayoutOrder so it sits on top

	-- Danger reads as an objective-style banner: dark plate, small red caps header,
	-- big white body. The pill toast below stays for info/success/warning.
	if kind == "danger" then
		-- Plain Frame, no CanvasGroup: group fade tinted the text unreadable.
		local banner = Instance.new("Frame")
		banner.Name = "Toast"
		banner.Size = UDim2.fromOffset(380, 0)
		banner.AutomaticSize = Enum.AutomaticSize.Y
		banner.LayoutOrder = _seq
		banner.ZIndex = Theme.Z.Tooltip
		banner.BackgroundColor3 = Color3.fromRGB(14, 15, 20)
		banner.BackgroundTransparency = 0
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, Theme.Radius.MD)
		corner.Parent = banner
		local ring = Instance.new("UIStroke")
		ring.Color = accent
		ring.Thickness = 1
		ring.Transparency = 0.35
		ring.Parent = banner

		local vpad = Instance.new("UIPadding")
		vpad.PaddingTop = UDim.new(0, 10)
		vpad.PaddingBottom = UDim.new(0, 12)
		vpad.PaddingLeft = UDim.new(0, Theme.Pad.LG)
		vpad.PaddingRight = UDim.new(0, Theme.Pad.LG)
		vpad.Parent = banner

		local col = Instance.new("UIListLayout")
		col.FillDirection = Enum.FillDirection.Vertical
		col.HorizontalAlignment = Enum.HorizontalAlignment.Center
		col.SortOrder = Enum.SortOrder.LayoutOrder
		col.Padding = UDim.new(0, 4)
		col.Parent = banner

		local header = Instance.new("TextLabel")
		header.Name = "Header"
		header.BackgroundTransparency = 1
		header.Size = UDim2.new(1, 0, 0, 16)
		header.Text = "\u{26A0}  C A N ' T   B U I L D"
		header.TextColor3 = accent
		header.TextSize = Theme.TextSize.XS
		header.FontFace = Theme.Font.Label
		header.LayoutOrder = 1
		header.Parent = banner

		local body = Instance.new("TextLabel")
		body.Name = "Text"
		body.BackgroundTransparency = 1
		body.Size = UDim2.new(1, 0, 0, 0)
		body.AutomaticSize = Enum.AutomaticSize.Y
		local msg = (opts.text:gsub("^Can't place: ", ""))
		body.Text = msg:sub(1, 1):upper() .. msg:sub(2)
		body.TextColor3 = Color3.fromRGB(240, 240, 240)
		body.TextSize = Theme.TextSize.LG
		body.FontFace = Theme.Font.Label
		body.TextWrapped = true
		body.LayoutOrder = 2
		body.Parent = banner

		banner.Parent = container
		table.insert(_toasts, banner)
		while #_toasts > MAX_TOASTS do
			dismiss(_toasts[1])
		end
		local dur = if typeof(opts.duration) == "number" then opts.duration else DEFAULT_DURATION
		task.delay(dur, function()
			dismiss(banner)
		end)
		return
	end

	local toast = Instance.new("CanvasGroup")
	toast.Name = "Toast"
	toast.Size = UDim2.fromOffset(0, 34)
	toast.AutomaticSize = Enum.AutomaticSize.X
	toast.GroupTransparency = 1
	toast.LayoutOrder = _seq
	toast.ZIndex = Theme.Z.Tooltip
	Glass.apply(toast, Theme.Radius.MD)
	toast.Parent = container

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, Theme.Pad.MD)
	pad.PaddingRight = UDim.new(0, Theme.Pad.LG)
	pad.Parent = toast

	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.VerticalAlignment = Enum.VerticalAlignment.Center
	row.SortOrder = Enum.SortOrder.LayoutOrder
	row.Padding = UDim.new(0, Theme.Pad.SM)
	row.Parent = toast

	local accentBar = Instance.new("Frame")
	accentBar.Name = "Accent"
	accentBar.Size = UDim2.fromOffset(4, 18)
	accentBar.BackgroundColor3 = accent
	accentBar.BorderSizePixel = 0
	accentBar.LayoutOrder = 1
	local aCorner = Instance.new("UICorner")
	aCorner.CornerRadius = UDim.new(0, 2)
	aCorner.Parent = accentBar
	accentBar.Parent = toast

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromOffset(0, 34)
	label.Text = opts.text
	label.TextColor3 = Theme.Color.TextPrimary
	label.TextSize = Theme.TextSize.SM
	label.FontFace = Theme.Font.Label
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.LayoutOrder = 2
	label.Parent = toast

	table.insert(_toasts, toast)
	while #_toasts > MAX_TOASTS do
		dismiss(_toasts[1])
	end

	UITween.to(toast, "Flyout", { GroupTransparency = 0 })

	local duration = if typeof(opts.duration) == "number" then opts.duration else DEFAULT_DURATION
	task.delay(duration, function()
		dismiss(toast)
	end)
end

function NotificationController.Start()
	if _started then
		return
	end
	_started = true

	local UIEvents = require(game:GetService("ReplicatedStorage"):WaitForChild("City"):WaitForChild("UIEvents"))
	UIEvents.GameEntered.Event:Connect(function()
		task.wait(0.6)
		NotificationController.Notify({ text = "Welcome back to your city", kind = "success" })
	end)

	-- Server-fired toasts (crime/sickness/fire events, economy warnings, progression
	-- rewards). Server kinds outside the local palette ("crime", "sickness") read as
	-- warnings rather than being dropped.
	local Net = require(game:GetService("ReplicatedStorage"):WaitForChild("Networker"))
	Net.Notify.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" or typeof(payload.text) ~= "string" then return end
		local kind: Kind = if ACCENT[payload.kind] ~= nil then payload.kind :: Kind else "warning"
		local duration = if typeof(payload.duration) == "number" then payload.duration else nil
		NotificationController.Notify({ text = payload.text, kind = kind, duration = duration })
	end)
end

return NotificationController
