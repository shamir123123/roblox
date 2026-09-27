--!strict
-- Frame-rate readout, driven by the "showFps" setting.
--   Off      -- nothing
--   Simple   -- the FPS number
--   Advanced -- FPS, frame time, and client memory
--
-- ponytail: no CPU-main / GPU-render split. Luau has no GPU timing API, so a
-- "precise" mode would have to invent two of its three numbers. Frame time is
-- the real measurement; use Studio's MicroProfiler for a stage breakdown.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Stats = game:GetService("Stats")

local Theme = require(script.Parent:WaitForChild("Theme"))
local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))

local PerfOverlay = {}

local SAMPLE_WINDOW = 0.5 -- seconds averaged per repaint

local _started = false
local _label: TextLabel? = nil
local _conn: RBXScriptConnection? = nil

local function memoryMb(): number
	local ok, mb = pcall(function()
		return Stats:GetTotalMemoryUsageMb()
	end)
	return if ok and typeof(mb) == "number" then mb else 0
end

local function setMode(mode: any)
	local label = _label
	if not label then
		return
	end
	local on = mode == "Simple" or mode == "Advanced"
	label.Visible = on

	if _conn then
		_conn:Disconnect()
		_conn = nil
	end
	if not on then
		return
	end

	local frames, elapsed = 0, 0
	_conn = RunService.RenderStepped:Connect(function(dt: number)
		frames += 1
		elapsed += dt
		if elapsed < SAMPLE_WINDOW then
			return
		end
		local fps = frames / elapsed
		local frameMs = elapsed / frames * 1000
		frames, elapsed = 0, 0
		label.Text = if mode == "Advanced"
			then string.format("%d FPS   %.1f ms   %d MB", fps + 0.5, frameMs, memoryMb() + 0.5)
			else string.format("%d FPS", fps + 0.5)
	end)
end

function PerfOverlay.Start()
	if _started then
		return
	end
	_started = true

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "PerfOverlay"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = Theme.Layer.Dev -- above panels, below the staff overlay
	gui.Parent = playerGui

	local label = Instance.new("TextLabel")
	label.Name = "Readout"
	label.AnchorPoint = Vector2.new(1, 0)
	label.Position = UDim2.new(1, -10, 0, 6)
	label.Size = UDim2.fromOffset(260, 18)
	label.BackgroundTransparency = 1
	label.Text = ""
	label.TextColor3 = Theme.Color.Positive
	label.TextSize = Theme.TextSize.XS
	label.FontFace = Theme.Font.Bold
	label.TextXAlignment = Enum.TextXAlignment.Right
	label.Visible = false
	label.Parent = gui
	_label = label

	Settings.onChanged("showFps", setMode)
	setMode(Settings.get("showFps"))
end

return PerfOverlay
