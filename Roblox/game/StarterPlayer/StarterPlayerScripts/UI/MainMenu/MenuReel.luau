--!strict
-- The main menu's moving backdrop: the city flythroughs in CLIPS, played one after
-- another behind the menu, each cut through black. Two VideoFrames take turns so the
-- next clip is already downloaded when its cut comes (Roblox plays at most two videos
-- at once; this only ever plays one).
--
-- Nothing downloads until the menu is first shown, and playback pauses whenever the
-- menu gui is disabled, so inside a city the reel costs nothing. Until a clip has
-- loaded -- or with CLIPS empty -- the reel stays hidden and the controller's key art
-- behind it is the backdrop: a failed download degrades to the still menu, never black.

local TweenService = game:GetService("TweenService")

local MenuReel = {}

-- One entry per uploaded flythrough (Creator Dashboard > Development Items > Videos,
-- ID-verified 13+, up to 60 s each). Record 16:9 -- the reel crops to fill any screen.
-- `title` is the caption's big line (the city's name); `subtitle` is optional small print.
export type Clip = { video: string, title: string, subtitle: string? }
local CLIPS: { Clip } = table.freeze({
	-- { video = "rbxassetid://0000000000", title = "Harbour District", subtitle = "Pop 48,200" },
})

local DIP_OUT = 0.6 -- fade to black before a cut
local DIP_IN = 1.2 -- fade up from black after it
local LOAD_TIMEOUT = 12 -- a clip at start-up; the key art covers this wait
local CUT_TIMEOUT = 3 -- the next clip at a cut; the screen is black for this wait
-- Settings and Update Logs hide the menu column and sit their glass pages straight
-- on the backdrop. They tint the key art down to ~25%; this matches it on the video.
local PAGE_DIM = 0.28

local MONTSERRAT = "rbxasset://fonts/families/Montserrat.json"
local WHITE = Color3.fromRGB(255, 255, 255)
local DIM_TEXT = Color3.fromRGB(196, 198, 194)
local TITLE_Y = 16

local function spaced(s: string): string
	-- By character, not byte: a "·" or an accented display name is several bytes.
	return (s:gsub(utf8.charpattern, "%0 "):gsub(" $", ""))
end

local function ease(obj: Instance, time: number, goal: { [string]: any })
	TweenService:Create(obj, TweenInfo.new(time, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), goal):Play()
end

local function blackout(parent: Instance, name: string, z: number): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.ZIndex = z
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundColor3 = Color3.new(0, 0, 0)
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Parent = parent
	return f
end

local function makeVideo(parent: Instance, name: string): VideoFrame
	local v = Instance.new("VideoFrame")
	v.Name = name
	v.ZIndex = 1
	v.AnchorPoint = Vector2.new(0.5, 0.5)
	v.Position = UDim2.fromScale(0.5, 0.5)
	v.BackgroundTransparency = 1
	v.BorderSizePixel = 0
	v.Volume = 0
	v.Looped = false
	v.Visible = false
	v.Parent = parent
	return v
end

local function captionLine(parent: Instance, name: string, weight: Enum.FontWeight, size: number, color: Color3): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.ZIndex = 4
	t.Size = UDim2.new(1, 0, 0, size)
	t.BackgroundTransparency = 1
	t.FontFace = Font.new(MONTSERRAT, weight)
	t.TextSize = size
	t.TextColor3 = color
	t.TextTransparency = 1
	t.TextXAlignment = Enum.TextXAlignment.Right
	t.TextTruncate = Enum.TextTruncate.AtEnd
	t.Text = ""
	t.Parent = parent
	return t
end

-- `column` is the menu's Container: Settings and Update Logs hide it, and the reel
-- dims while it is gone. `caption` is an empty frame the view has placed; the reel
-- fills it with the clip's name and one progress segment per clip.
function MenuReel.mount(gui: ScreenGui, column: GuiObject, caption: GuiObject)
	caption.Visible = false
	if #CLIPS == 0 then
		return
	end

	local reel = Instance.new("Frame")
	reel.Name = "Reel"
	reel.ZIndex = 1 -- over the controller's key-art layer (0), under Container (2)
	reel.BackgroundTransparency = 1
	reel.BorderSizePixel = 0
	reel.Visible = false
	reel.Parent = gui

	local frames = { makeVideo(reel, "ClipA"), makeVideo(reel, "ClipB") }
	local dip = blackout(reel, "Dip", 2)
	local dim = blackout(reel, "Dim", 3)

	local info = captionLine(caption, "Info", Enum.FontWeight.SemiBold, 11, DIM_TEXT)
	local title = captionLine(caption, "Title", Enum.FontWeight.Light, 26, WHITE)
	title.Position = UDim2.fromOffset(0, TITLE_Y)

	local fills: { Frame } = {}
	if #CLIPS > 1 then
		local track = Instance.new("Frame")
		track.Name = "Segments"
		track.AnchorPoint = Vector2.new(0, 1)
		track.Position = UDim2.fromScale(0, 1)
		track.Size = UDim2.new(1, 0, 0, 2)
		track.BackgroundTransparency = 1
		track.Parent = caption
		local row = Instance.new("UIListLayout")
		row.FillDirection = Enum.FillDirection.Horizontal
		row.HorizontalAlignment = Enum.HorizontalAlignment.Right
		row.SortOrder = Enum.SortOrder.LayoutOrder
		row.Padding = UDim.new(0, 6)
		row.Parent = track
		for i = 1, #CLIPS do
			local seg = Instance.new("Frame")
			seg.LayoutOrder = i
			seg.ZIndex = 4
			seg.Size = UDim2.fromOffset(30, 2)
			seg.BackgroundColor3 = WHITE
			seg.BackgroundTransparency = 0.72
			seg.BorderSizePixel = 0
			seg.ClipsDescendants = true
			seg.Parent = track
			local fill = Instance.new("Frame")
			fill.ZIndex = 5
			fill.Size = UDim2.fromScale(0, 1)
			fill.BackgroundColor3 = WHITE
			fill.BorderSizePixel = 0
			fill.Parent = seg
			fills[i] = fill
		end
	end

	-- The reel spans the whole SCREEN, not the gui: DeviceSafeInsets pulls the gui in
	-- off a phone's notch, and the video should still run edge to edge. Each clip is
	-- cropped to cover it, the way the key art's ScaleType.Crop is.
	local function fit()
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end
		local view = camera.ViewportSize
		local origin = gui.AbsolutePosition
		reel.Position = UDim2.fromOffset(-origin.X, -origin.Y)
		reel.Size = UDim2.fromOffset(view.X, view.Y)
		for _, v in frames do
			local res = v.Resolution
			local aspect = if res.Y > 0 then res.X / res.Y else 16 / 9
			local w = math.max(view.X, view.Y * aspect)
			v.Size = UDim2.fromOffset(w, w / aspect)
		end
	end

	local current = 0 -- CLIPS index on screen; 0 until the first clip has loaded
	local queued = 0 -- CLIPS index loading into the back frame
	local front = 1 -- index into `frames` of the visible one
	local busy = false -- a load or a cut is running; settle() catches up when it ends
	local started = false
	local cutThread: thread? = nil
	local fillTween: Tween? = nil

	local function nextIndex(i: number): number
		return i % #CLIPS + 1
	end

	local function preload(v: VideoFrame, index: number)
		v.Playing = false
		v.Video = CLIPS[index].video
	end

	local function waitLoaded(v: VideoFrame, timeout: number): boolean
		local deadline = os.clock() + timeout
		while not v.IsLoaded and os.clock() < deadline do
			task.wait(0.1)
		end
		return v.IsLoaded
	end

	local function showCaption(index: number)
		local clip = CLIPS[index]
		local count = string.format("%02d / %02d", index, #CLIPS)
		info.Text = spaced(if clip.subtitle then count .. "  ·  " .. string.upper(clip.subtitle) else count)
		title.Text = clip.title
		for i, fill in fills do
			fill.Size = UDim2.fromScale(if i < index then 1 else 0, 1)
		end
		title.Position = UDim2.fromOffset(0, TITLE_Y + 8)
		ease(title, 0.9, { TextTransparency = 0, Position = UDim2.fromOffset(0, TITLE_Y) })
		ease(info, 0.9, { TextTransparency = 0 })
	end

	local function stop()
		frames[front].Playing = false
		if cutThread then
			task.cancel(cutThread)
			cutThread = nil
		end
		if fillTween then
			fillTween:Cancel()
			fillTween = nil
		end
	end

	local advance: () -> ()

	-- Plays the front clip from where it is and books its cut DIP_OUT before the end.
	local function play()
		stop()
		local v = frames[front]
		v:Play()
		local remaining = math.max(v.TimeLength - v.TimePosition, 0)
		local fill = fills[current]
		if fill then
			local t = TweenService:Create(fill, TweenInfo.new(remaining, Enum.EasingStyle.Linear), { Size = UDim2.fromScale(1, 1) })
			t:Play()
			fillTween = t
		end
		cutThread = task.delay(math.max(remaining - DIP_OUT, 0), advance)
	end

	-- A load or a cut ends here, and picks up whatever the menu did meanwhile.
	local function settle()
		busy = false
		if not gui.Parent then
			return
		end
		if gui.Enabled then
			play()
		else
			stop()
		end
	end

	advance = function()
		cutThread = nil
		busy = true
		ease(title, DIP_OUT, { TextTransparency = 1 })
		ease(info, DIP_OUT, { TextTransparency = 1 })
		ease(dip, DIP_OUT, { BackgroundTransparency = 0 })
		task.wait(DIP_OUT)

		local outgoing = frames[front]
		local incoming = frames[3 - front]
		outgoing.Playing = false
		local arrived = waitLoaded(incoming, CUT_TIMEOUT)
		if arrived then
			outgoing.Visible = false
			incoming.TimePosition = 0
			incoming.Visible = true
			front = 3 - front
			current = queued
		else
			-- Moderated, deleted or just slow: replay what is on screen rather than hold
			-- the screen black, and skip the missing clip when queueing the next one.
			warn(string.format("[MenuReel] cut: clip %d (%s) did not load within %ds; replaying clip %d",
				queued, CLIPS[queued].video, CUT_TIMEOUT, current))
			outgoing.TimePosition = 0
		end

		fit()
		showCaption(current)
		ease(dip, DIP_IN, { BackgroundTransparency = 1 })
		queued = nextIndex(if arrived then current else queued)
		preload(frames[3 - front], queued)
		settle()
	end

	local function start()
		busy = true
		local first = frames[1]
		for i = 1, #CLIPS do
			preload(first, i)
			if waitLoaded(first, LOAD_TIMEOUT) then
				current = i
				break
			end
			warn(string.format("[MenuReel] start: clip %d (%s) did not load within %ds; skipping it",
				i, CLIPS[i].video, LOAD_TIMEOUT))
		end
		if current == 0 then
			busy = false -- nothing loaded: the key art stays for the session
			return
		end

		first.Visible = true
		fit()
		caption.Visible = true
		showCaption(current)
		dip.BackgroundTransparency = 0
		reel.Visible = true
		ease(dip, DIP_IN, { BackgroundTransparency = 1 })
		queued = nextIndex(current)
		preload(frames[2], queued)
		settle()
	end

	local function onEnabled()
		if busy then
			return
		end
		if not gui.Enabled then
			stop()
		elseif not started then
			started = true
			task.spawn(start) -- yields on the download
		elseif current > 0 then
			play()
		end
	end

	gui:GetPropertyChangedSignal("Enabled"):Connect(onEnabled)
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	column:GetPropertyChangedSignal("Visible"):Connect(function()
		ease(dim, 0.35, { BackgroundTransparency = if column.Visible then 1 else PAGE_DIM })
	end)
	gui.Destroying:Connect(stop)
	onEnabled()
end

return MenuReel
