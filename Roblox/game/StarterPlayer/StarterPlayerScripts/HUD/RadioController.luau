--!strict
-- RadioController
-- CS-style in-game radio. Menu gets its own theme; entering the city swaps to a
-- collapsed corner chip. Hover the chip -> a slim strip (track + transport) slides
-- out. Click it -> the full RADIO window (station list + now-playing program).
-- Tracks are licensed Creator Store music (APM / DistroKid), all public; swap freely.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")

local uiFolder = script.Parent.Parent:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local TopbarDock = require(uiFolder:WaitForChild("TopbarDock"))
local UITween = require(uiFolder:WaitForChild("UITween"))
local Glass = require(uiFolder:WaitForChild("Kit"):WaitForChild("Glass"))
local Icons = require(uiFolder:WaitForChild("Icons"))
local SoundFX = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("SoundFX"))
local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))

local RadioController = {}

type Track = { id: number, name: string }
type Station = { name: string, initials: string, tracks: { Track } }

local MENU_TRACK = 1839705973 -- "Heartwarming Memories": uplifting cello pop, strings only
local MENU_VOLUME = 0.2
local RADIO_MAX_VOLUME = 0.35

local STATIONS: { Station } = {
	{ name = "Cloud Lounge FM", initials = "CL", tracks = {
		{ id = 9046863253, name = "Poolside" },
		{ id = 9046864489, name = "Violet Clouds" },
		{ id = 9046863579, name = "City Lights" },
		{ id = 9046862941, name = "Sunset Chill" },
		{ id = 140195496777664, name = "Rainy Window Reflections" },
	} },
	{ name = "Golden Sky", initials = "GS", tracks = {
		{ id = 1840715344, name = "Shine On You" },
		{ id = 1844362041, name = "Acoustic Dream" },
		{ id = 140722099430139, name = "Morning" },
		{ id = 89402602954424, name = "Pastel Corner Life" },
		{ id = 1846405789, name = "Dreamers" },
	} },
	{ name = "Smooth Vibes", initials = "SV", tracks = {
		{ id = 124448435428173, name = "City at Sunset" },
		{ id = 103545970968754, name = "Smooth City Groove" },
		{ id = 98412938061498, name = "Calm City Lights" },
		{ id = 136228570470406, name = "Apartment Windows" },
		{ id = 116836963626501, name = "City Lights in Your Eyes" },
	} },
}

local _started = false
local _sound: Sound? = nil
local _stationIdx = 1
local _trackIdx = 0
local _paused = false
local _trackLabels: { TextLabel } = {}      -- strip + menu now-playing
local _stationChips: { TextLabel } = {}      -- round initials chips (corner + strip)
local _stationNames: { TextLabel } = {}      -- full station-name labels (menu program)
local _pauseButtons: { TextButton } = {}
local _stationRows: { [number]: TextButton } = {}
local _menu: Frame? = nil
local _strip: CanvasGroup? = nil
local _showToast: ((string) -> ())? = nil

local function musicLevel(): number
	return (tonumber(Settings.get("musicVolume")) or 1) * (tonumber(Settings.get("masterVolume")) or 1)
end

local function radioVolume(): number
	return musicLevel() * RADIO_MAX_VOLUME
end

local function updateNowPlaying()
	local station = STATIONS[_stationIdx]
	local track = station.tracks[math.max(_trackIdx, 1)]
	for _, l in _trackLabels do l.Text = track.name end
	for _, c in _stationChips do c.Text = station.initials end
	for _, n in _stationNames do n.Text = station.name end
	for i, row in _stationRows do
		row.BackgroundTransparency = if i == _stationIdx then 0.7 else 1
	end
end

local function playTrack(step: number)
	local s = _sound
	if not s then return end
	local station = STATIONS[_stationIdx]
	_trackIdx = ((_trackIdx - 1 + step) % #station.tracks) + 1
	local track = station.tracks[_trackIdx]
	s.SoundId = "rbxassetid://" .. track.id
	s.Volume = radioVolume()
	if not _paused then s:Play() end
	updateNowPlaying()
	if _showToast then _showToast(track.name .. " \u{2014} " .. station.name) end
end

local function setStation(idx: number)
	if idx == _stationIdx then return end
	_stationIdx = idx
	_trackIdx = 0
	playTrack(1)
end

-- ------------------------------------------------------------------- UI --

-- Same icon-button pattern as the bottom bar's speed cluster.
local function iconButton(parent: Instance, order: number, img: string, rot: number?): (TextButton, ImageLabel)
	local b = Instance.new("TextButton")
	b.BackgroundTransparency = 1
	b.Size = UDim2.fromOffset(26, 26)
	b.Text = ""
	b.AutoButtonColor = false
	b.LayoutOrder = order
	b.Parent = parent
	local ic = Instance.new("ImageLabel")
	ic.Name = "Icon"
	ic.BackgroundTransparency = 1
	ic.AnchorPoint = Vector2.new(0.5, 0.5)
	ic.Position = UDim2.fromScale(0.5, 0.5)
	ic.Size = UDim2.fromScale(0.82, 0.82)
	ic.ScaleType = Enum.ScaleType.Fit
	ic.Image = img
	ic.ImageColor3 = Theme.Color.TextSecondary
	ic.Rotation = rot or 0
	ic.Parent = b
	return b, ic
end

local function buildPanel(parent: Instance)
	local panel = Instance.new("Frame")
	panel.Name = "RadioStations" -- positioned by buildBar's place(), under the chip
	panel.Size = UDim2.fromOffset(220, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.Visible = false
	Glass.apply(panel, Theme.Radius.MD)
	panel.Parent = parent

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 6); pad.PaddingBottom = UDim.new(0, 6)
	pad.PaddingLeft = UDim.new(0, 6); pad.PaddingRight = UDim.new(0, 6)
	pad.Parent = panel
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 2)
	list.Parent = panel

	for i, station in STATIONS do
		local row = Instance.new("TextButton")
		row.Size = UDim2.new(1, 0, 0, 32)
		row.BackgroundColor3 = Theme.Color.Accent
		row.BackgroundTransparency = if i == _stationIdx then 0.75 else 1
		row.Text = ""
		row.LayoutOrder = i
		local rc = Instance.new("UICorner"); rc.CornerRadius = UDim.new(0, 6); rc.Parent = row
		row.Parent = panel

		local chip = Instance.new("TextLabel")
		chip.BackgroundColor3 = Color3.fromRGB(18, 20, 24)
		chip.Size = UDim2.fromOffset(24, 24)
		chip.Position = UDim2.fromOffset(4, 4)
		chip.Text = station.initials
		chip.TextSize = Theme.TextSize.XS
		chip.TextColor3 = Theme.Color.TextPrimary
		chip.FontFace = Theme.Font.Label
		local cc = Instance.new("UICorner"); cc.CornerRadius = UDim.new(1, 0); cc.Parent = chip
		chip.Parent = row

		local name = Instance.new("TextLabel")
		name.BackgroundTransparency = 1
		name.Position = UDim2.fromOffset(36, 0)
		name.Size = UDim2.new(1, -40, 1, 0)
		name.Text = station.name
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextSize = Theme.TextSize.SM
		name.TextColor3 = Theme.Color.TextPrimary
		name.FontFace = Theme.Font.Label
		name.Parent = row

		_stationRows[i] = row
		row.Activated:Connect(function()
			SoundFX.play("Click")
			setStation(i)
		end)
	end
	return panel
end

local function buildBar()
	local player = Players.LocalPlayer
	local pg = player:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "RadioBar"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = Theme.Layer.WorldTag + 2
	gui.Parent = pg

	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	-- Chip 2 of the custom topbar row, right of the Settings/City Hall chips.
	bar.Size = UDim2.fromOffset(0, 44)
	bar.AutomaticSize = Enum.AutomaticSize.X
	-- Flat on the shared top-left cluster pill: no chip of its own.
	bar.BackgroundTransparency = 1
	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(0, 22)
	barCorner.Parent = bar
	bar.Parent = gui

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 4); pad.PaddingRight = UDim.new(0, 4)
	pad.Parent = bar
	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.VerticalAlignment = Enum.VerticalAlignment.Center
	row.SortOrder = Enum.SortOrder.LayoutOrder
	row.Padding = UDim.new(0, 8)
	row.Parent = bar

	-- Station chip: opens/closes the station list.
	local chipBtn = Instance.new("TextButton")
	chipBtn.BackgroundColor3 = Theme.Color.Accent
	chipBtn.Text = ""
	chipBtn.LayoutOrder = 1
	local cc = Instance.new("UICorner"); cc.CornerRadius = UDim.new(1, 0); cc.Parent = chipBtn
	chipBtn.Parent = bar
	local chip = Instance.new("TextLabel")
	chip.BackgroundTransparency = 1
	chip.Size = UDim2.fromScale(1, 1)
	chip.Text = STATIONS[_stationIdx].initials
	chip.TextSize = Theme.TextSize.XS
	chip.TextColor3 = Color3.fromRGB(18, 20, 24)
	chip.FontFace = Theme.Font.Label
	chip.Parent = chipBtn
	table.insert(_stationChips, chip)

	-- Strip: hidden until the bar is hovered. It hangs BELOW the chip rather than
	-- living inside the bar: the bar is AutomaticSize.X in the topbar row, so a
	-- strip parented to it grew the bar sideways straight through the city-role
	-- badge and the clock every time the cursor passed over the radio. Downward is
	-- the only free direction up there.
	local strip = Instance.new("CanvasGroup")
	strip.Name = "Strip"
	strip.GroupTransparency = 1
	strip.Size = UDim2.fromOffset(0, 38)
	strip.AutomaticSize = Enum.AutomaticSize.X
	strip.Visible = false
	strip.ZIndex = Theme.Z.Popover
	Glass.apply(strip, Theme.Radius.MD)
	strip.Parent = gui
	_strip = strip
	local stripPad = Instance.new("UIPadding")
	stripPad.PaddingLeft = UDim.new(0, 8)
	stripPad.PaddingRight = UDim.new(0, 8)
	stripPad.Parent = strip
	local stripRow = Instance.new("UIListLayout")
	stripRow.FillDirection = Enum.FillDirection.Horizontal
	stripRow.VerticalAlignment = Enum.VerticalAlignment.Center
	stripRow.SortOrder = Enum.SortOrder.LayoutOrder
	stripRow.Padding = UDim.new(0, 8)
	stripRow.Parent = strip

	local track = Instance.new("TextLabel")
	track.BackgroundTransparency = 1
	track.AutomaticSize = Enum.AutomaticSize.X
	track.Size = UDim2.fromOffset(0, 26)
	track.Text = ""
	track.TextSize = Theme.TextSize.SM
	track.TextColor3 = Theme.Color.TextPrimary
	track.FontFace = Theme.Font.Label
	track.LayoutOrder = 1
	track.Parent = strip
	table.insert(_trackLabels, track)

	-- Volume slider: click/drag sets the shared music volume setting.
	local vol0 = tonumber(Settings.get("musicVolume")) or 1
	local slider = Instance.new("Frame")
	slider.Name = "Volume"
	slider.BackgroundColor3 = Color3.fromRGB(70, 74, 80)
	slider.Size = UDim2.fromOffset(90, 4)
	slider.LayoutOrder = 2
	local sc = Instance.new("UICorner"); sc.CornerRadius = UDim.new(1, 0); sc.Parent = slider
	slider.Parent = strip
	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = Theme.Color.Accent
	fill.Size = UDim2.new(vol0, 0, 1, 0)
	fill.BorderSizePixel = 0
	local fc = Instance.new("UICorner"); fc.CornerRadius = UDim.new(1, 0); fc.Parent = fill
	fill.Parent = slider
	local knob = Instance.new("Frame")
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.new(vol0, 0, 0.5, 0)
	knob.Size = UDim2.fromOffset(12, 12)
	knob.BackgroundColor3 = Color3.fromRGB(235, 235, 235)
	local kc = Instance.new("UICorner"); kc.CornerRadius = UDim.new(1, 0); kc.Parent = knob
	knob.Parent = slider

	local dragging = false
	local function setFromX(x: number)
		local rel = math.clamp((x - slider.AbsolutePosition.X) / slider.AbsoluteSize.X, 0, 1)
		Settings.set("musicVolume", rel)
	end
	Settings.onChanged("musicVolume", function(v)
		local rel = tonumber(v) or 0
		fill.Size = UDim2.new(rel, 0, 1, 0)
		knob.Position = UDim2.new(rel, 0, 0.5, 0)
	end)
	slider.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)

	-- Transport: prev / pause / next.
	local prev = iconButton(strip, 3, Icons.Speed2.image, 180) -- mirrored fast-forward = rewind
	local pause, pauseIcon = iconButton(strip, 4, Icons.Pause.image)
	local nxt = iconButton(strip, 5, Icons.Speed2.image)
	prev.Activated:Connect(function()
		SoundFX.play("Click")
		playTrack(-1)
	end)
	nxt.Activated:Connect(function()
		SoundFX.play("Click")
		playTrack(1)
	end)
	pause.Activated:Connect(function()
		SoundFX.play("Click")
		_paused = not _paused
		pauseIcon.Image = if _paused then Icons.Speed1.image else Icons.Pause.image
		local s = _sound
		if s then
			if _paused then s:Pause() else s:Resume() end
		end
	end)

	local panel = buildPanel(gui)
	_menu = panel

	-- Chip only when idle; hover fades the strip out; click opens the full tab.
	-- The strip and the station list now share the same slot under the chip, so
	-- exactly one of them is ever up.
	local function showStrip()
		if panel.Visible then
			return
		end
		strip.Visible = true
		UITween.to(strip, "Popover", { GroupTransparency = 0 })
	end
	local function hideStrip()
		local tw = UITween.to(strip, "Popover", { GroupTransparency = 1 })
		tw.Completed:Once(function()
			if strip.GroupTransparency > 0.95 then strip.Visible = false end
		end)
	end
	bar.MouseEnter:Connect(showStrip)
	bar.MouseLeave:Connect(function()
		if not panel.Visible then hideStrip() end
	end)
	chipBtn.Activated:Connect(function()
		SoundFX.play("Click")
		panel.Visible = not panel.Visible
		-- Either way the strip goes: opening the list would draw it underneath, and
		-- closing it leaves the cursor somewhere that no longer counts as a hover.
		hideStrip()
	end)

	-- Now-playing toast: a small pill under the chip that fades in for a moment
	-- whenever the track changes, so the radio feels alive without opening the strip.
	local toast = Instance.new("TextLabel")
	toast.Name = "NowPlaying"
	toast.AutomaticSize = Enum.AutomaticSize.XY
	toast.BackgroundColor3 = Color3.fromRGB(18, 20, 24)
	toast.BackgroundTransparency = 1
	toast.TextColor3 = Theme.Color.TextPrimary
	toast.TextTransparency = 1
	toast.TextSize = Theme.TextSize.SM
	toast.FontFace = Theme.Font.Label
	toast.Visible = false
	local tc = Instance.new("UICorner"); tc.CornerRadius = UDim.new(0, 6); tc.Parent = toast
	local tp = Instance.new("UIPadding")
	tp.PaddingLeft = UDim.new(0, 8); tp.PaddingRight = UDim.new(0, 8)
	tp.PaddingTop = UDim.new(0, 3); tp.PaddingBottom = UDim.new(0, 3)
	tp.Parent = toast
	toast.Parent = gui

	local toastToken = 0
	_showToast = function(text: string)
		if strip.Visible then return end -- strip already shows the track
		toastToken += 1
		local tok = toastToken
		toast.Text = "\u{266A} " .. text
		toast.Visible = true
		UITween.to(toast, "Tooltip", { TextTransparency = 0, BackgroundTransparency = 0.25 })
		task.delay(3, function()
			if tok ~= toastToken then return end
			local tw = UITween.to(toast, "Tooltip", { TextTransparency = 1, BackgroundTransparency = 1 })
			tw.Completed:Once(function()
				if tok == toastToken then toast.Visible = false end
			end)
		end)
	end

	TopbarDock.bind(gui, function(x0, top, h)
		local x = TopbarDock.slot(x0, h, 2)
		bar.Position = UDim2.fromOffset(x - 4, top) -- -4: the bar's own left padding
		bar.Size = UDim2.fromOffset(0, h)
		chipBtn.Size = UDim2.fromOffset(h, h)
		-- Strip, station list and toast all hang from the same point under the chip.
		strip.Position = UDim2.fromOffset(x, top + h + 6)
		panel.Position = UDim2.fromOffset(x, top + h + 6)
		toast.Position = UDim2.fromOffset(x, top + h + 8)
	end)

end

-- ------------------------------------------------------------- lifecycle --

function RadioController.Start()
	if _started then return end
	_started = true

	local s = Instance.new("Sound")
	s.Name = "Radio"
	s.SoundId = "rbxassetid://" .. MENU_TRACK
	s.Volume = MENU_VOLUME * musicLevel()
	s.Looped = true
	s.Parent = SoundService
	s:Play()
	_sound = s

	-- Settings page / radio strip both write these; keep the live sound honest.
	local function applyVolume()
		s.Volume = if s.Looped then MENU_VOLUME * musicLevel() else radioVolume()
	end
	Settings.onChanged("musicVolume", applyVolume)
	Settings.onChanged("masterVolume", applyVolume)

	-- Next track when one ends (radio mode only; the menu theme loops).
	s.Ended:Connect(function()
		if not s.Looped then task.wait(2); playTrack(1) end
	end)

	local UIEvents = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("UIEvents"))
	UIEvents.GameEntered.Event:Connect(function()
		if not s.Looped then return end -- already in radio mode
		s.Looped = false
		s:Stop()
		buildBar()
		playTrack(1)
	end)
end

return RadioController
