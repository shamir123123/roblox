--!strict
-- TrafficJamView
-- The badge over a traffic jam. Twin of NoPowerView in shape: a pulsing billboard, purely
-- cosmetic, no server traffic.
--
-- ponytail: the jam is DETECTED CLIENT-SIDE from the cars themselves rather than pushed from
-- NPCDriverService's congestion snapshot -- a stalled car is already replicated, so a badge
-- that reads the world needs no remote, no rate limit and no attribute plumbing. Ceiling:
-- it knows nothing the sim knows (which edge, how long). If the badge ever needs to say
-- "blocked 40 s" or open the road panel, move it onto a congestion push instead.

local CollectionService = game:GetService("CollectionService")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")

local uiFolder = script.Parent.Parent:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))

local TrafficJamView = {}

local TAG = "NPCDriver"
local SCAN_PERIOD = 1.0   -- s between sweeps; a jam is not a per-frame event
local STALL_DIST = 3      -- studs moved between sweeps and under, the car is stopped
local CELL = 45           -- studs; jam grouping grid (roughly one block face)
local MIN_CARS = 6        -- stalled cars in one cell before the cell counts as jammed
-- A red light stops a queue for one light phase. A JAM is a queue that is still there after
-- the phase ended, so a cell must come up jammed this many sweeps RUNNING before it earns a
-- badge -- and must come up clear this many before it loses one, so the icon does not
-- flicker on the one car that creeps forward.
local HOLD_ON = 12        -- sweeps (~12 s) jammed before the badge appears
local HOLD_OFF = 4        -- sweeps clear before it goes away
local BADGE = 34
local MAX_DISTANCE = 1200
local HEIGHT = 14         -- studs above the cars
local PULSE_MIN, PULSE_MAX = 0.85, 1.15
local PULSE_INFO = TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)

local _started = false
local _acc = 0
local _lastPos: { [Model]: Vector3 } = {}
local _badges: { [string]: { gui: BillboardGui, part: BasePart, seen: boolean } } = {}
local _streak: { [string]: number } = {} -- cell key -> consecutive jammed sweeps (negative = clear sweeps)
local _conn: RBXScriptConnection? = nil

local function makeBadge(pos: Vector3)
	local part = Instance.new("Part")
	part.Name = "TrafficJamAnchor"
	part.Size = Vector3.one
	part.Transparency = 1
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Anchored = true
	part.Position = pos
	part.Parent = workspace

	local gui = Instance.new("BillboardGui")
	gui.Name = "TrafficJamBadge"
	gui.Adornee = part
	gui.AlwaysOnTop = true
	gui.Size = UDim2.fromOffset(BADGE * PULSE_MIN, BADGE * PULSE_MIN)
	gui.MaxDistance = MAX_DISTANCE
	gui.ResetOnSpawn = false
	gui.Parent = part

	local disc = Instance.new("Frame")
	disc.Size = UDim2.fromScale(1, 1)
	disc.BackgroundColor3 = Theme.Color.Danger
	disc.BorderSizePixel = 0
	disc.Parent = gui
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(1, 0)
	round.Parent = disc
	local edge = Instance.new("UIStroke")
	edge.Color = Color3.fromRGB(24, 24, 26)
	edge.Thickness = 1.5
	edge.Transparency = 0.25
	edge.Parent = disc

	local glyph = Instance.new("TextLabel")
	glyph.BackgroundTransparency = 1
	glyph.Size = UDim2.fromScale(1, 1)
	glyph.Text = "\u{1F6A6}"
	glyph.TextColor3 = Color3.fromRGB(255, 250, 240)
	glyph.TextScaled = true
	glyph.FontFace = Theme.Font.Bold
	glyph.Parent = disc

	TweenService:Create(gui, PULSE_INFO, {
		Size = UDim2.fromOffset(BADGE * PULSE_MAX, BADGE * PULSE_MAX),
	}):Play()
	return { gui = gui, part = part, seen = true }
end

local function rootOf(car: Instance): BasePart?
	if not car:IsA("Model") then return nil end
	return car.PrimaryPart or car:FindFirstChildWhichIsA("BasePart")
end

-- One sweep: which grid cells hold enough stopped cars to be a jam.
local function scan()
	local count: { [string]: number } = {}
	local sum: { [string]: Vector3 } = {}
	local live: { [Model]: boolean } = {}

	for _, car in CollectionService:GetTagged(TAG) do
		local root = rootOf(car)
		if not root then continue end
		local model = car :: Model
		live[model] = true
		local pos = root.Position
		local prev = _lastPos[model]
		_lastPos[model] = pos
		if not prev or (pos - prev).Magnitude > STALL_DIST then continue end
		local key = string.format("%d_%d", pos.X // CELL, pos.Z // CELL)
		count[key] = (count[key] or 0) + 1
		sum[key] = (sum[key] or Vector3.zero) + pos
	end
	for model in _lastPos do
		if not live[model] then _lastPos[model] = nil end
	end

	-- Age every cell we have an opinion about: the ones jammed this sweep, plus the ones we
	-- were already counting (so a queue that clears actually decays instead of lingering).
	for key in _streak do
		if not count[key] then count[key] = 0 end
	end

	for _, b in _badges do b.seen = false end
	for key, n in count do
		local jammed = n >= MIN_CARS
		local s = _streak[key] or 0
		if jammed then
			s = math.min(if s < 0 then 1 else s + 1, HOLD_ON)
		else
			s = if s > 0 then -1 else math.max(s - 1, -HOLD_OFF)
		end
		_streak[key] = s

		local b = _badges[key]
		if s >= HOLD_ON then
			local centre = sum[key] / n + Vector3.new(0, HEIGHT, 0)
			if b then
				b.part.Position = centre
				b.seen = true
			else
				_badges[key] = makeBadge(centre)
			end
		elseif b and s > -HOLD_OFF then
			b.seen = true -- jam eased for a moment; hold the badge through the wobble
		elseif s <= -HOLD_OFF then
			_streak[key] = nil
		end
	end
	for key, b in _badges do
		if not b.seen then
			b.part:Destroy()
			_badges[key] = nil
		end
	end
end

function TrafficJamView.Start()
	if _started then return end
	_started = true
	_conn = RunService.Heartbeat:Connect(function(dt)
		_acc += dt
		if _acc < SCAN_PERIOD then return end
		_acc = 0
		local ok, err = pcall(scan)
		if not ok then warn("[TrafficJamView] scan failed: " .. tostring(err)) end
	end)
end

function TrafficJamView.Stop()
	if _conn then _conn:Disconnect(); _conn = nil end
	for key, b in _badges do
		b.part:Destroy()
		_badges[key] = nil
	end
	table.clear(_lastPos)
	_started = false
end

return TrafficJamView
