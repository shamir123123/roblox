--!strict
-- RenderPressure -- one number describing how hard this client is currently struggling, read
-- by every system that can spend less when the answer is "hard".
--
-- WHY IT IS SHARED RATHER THAN PRIVATE
-- AssetLODView already measured frame time and eased a multiplier from it, and the reasoning
-- was right: the Graphics preset only helps players who open the menu, which is most of them
-- never, so a frame-time reading is the ground truth and needs nothing from the player. What
-- was wrong was the reach. That multiplier fed exactly ONE thing -- the distance bands -- while
-- the five levers that cost a weak device real money (cull threshold, proxy cache size,
-- impostor resolution, the coarse bake, street-name plate budget) stayed wired to a manual
-- dropdown. This file is that same measurement, promoted so all of them can read it.
--
-- NOTCHED, NOT CONTINUOUS -- and that is the point
-- The old multiplier eased smoothly, 0.02 per sweep. That reads as reasonable and behaves
-- badly: while it slides from 1.0 to 0.45 over ~8 seconds, EVERY model in the city drifts
-- across a band edge at some point during the slide. AssetLODView's 8% hysteresis protects
-- against distance jitter but not against the edges themselves moving, so the moment the
-- device is struggling is the moment it gets a sustained stream of retiers, each one a
-- GetDescendants walk. Stepping between a handful of fixed levels means the city crosses a
-- boundary once per step and then sits still.
--
-- ASYMMETRIC, FOR THE REASON THE OLD CODE GAVE
-- Cutting is fast and recovery is slow. An easing that rises as fast as it falls oscillates,
-- and a ladder that breathes in and out is far more noticeable than one that simply sits
-- closer. The thresholds still straddle 16.7 ms, because that IS 60fps and Roblox caps there:
-- set the recover threshold below it and a perfectly healthy client never qualifies to earn
-- detail back.
--
-- MEMORY IS A SEPARATE AXIS, AND ON A WEAK DEVICE THE MORE DANGEROUS ONE
-- Every adaptive signal in this game used to be frame time. On a 2 GB Android device the
-- failure is a crash, not a slow frame, and nothing was watching for it. Memory therefore
-- raises a FLOOR under the pressure level rather than feeding the same easing: a device that
-- is short of memory does not recover by drawing fewer frames, so it must not be allowed to
-- ease back up while it is still short.

local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")

local DeviceProfile = require(script.Parent:WaitForChild("DeviceProfile"))

local RenderPressure = {}

-- The ladder of detail multipliers, level 0 (no pressure) to level 4. The endpoints are the
-- ones AssetLODView already used and had measured: 1.0 is full detail, 0.45 is as far in as
-- the bands may ever be pulled. The steps between are even.
local DETAIL: { number } = table.freeze({ 1.0, 0.86, 0.72, 0.58, 0.45 })
local MAX_LEVEL = #DETAIL - 1

-- Frame time, smoothed. Above SLOW, start cutting; below FAST, start giving detail back.
-- 60fps = 16.7 ms has to qualify as fast or a healthy client ratchets down on its first hitch
-- and stays down for the session -- which is exactly what an earlier 15 ms threshold did.
local SLOW_MS = 24
local FAST_MS = 18

-- How long the reading must hold before a step is taken. Cutting is deliberately quicker than
-- recovering; a recovery that is too eager is what turns a stable ladder into a breathing one.
local CUT_DWELL = 1.2
local RECOVER_DWELL = 6

-- EMA weight per frame. At 60fps this settles in about a third of a second; on a device
-- running at 15fps it settles in over a second, which is the right direction -- the slower the
-- client, the more evidence a step should need.
local SMOOTH = 0.05

-- Client memory watermarks in MB, per device class.
--
-- THESE ARE CONSERVATIVE GUESSES, NOT MEASUREMENTS. Nothing in this place has profiled a real
-- out-of-memory kill, and the number that matters (the OS ceiling) is not readable from Luau.
-- They are set where a healthy session should never reach them, so a client that does is
-- genuinely in trouble. Retune against a real device before trusting them for anything but
-- degradation.
local MEM_TIGHT_HANDHELD = 900
local MEM_CRIT_HANDHELD = 1200
local MEM_TIGHT_DESKTOP = 2000
local MEM_CRIT_DESKTOP = 2800

-- Memory is sampled slowly: GetTotalMemoryUsageMb walks the engine's allocator categories and
-- is not something to call every frame, and the quantity it reports moves over seconds.
local MEM_PERIOD = 2

-- The floor memory pressure puts under the level. Tight holds the ladder at least this far in
-- and, more importantly, stops it easing back out while memory is still short.
local MEM_TIGHT_FLOOR = 2
local MEM_CRIT_FLOOR = 3

local _started = false
local _frameMs = 16.6
-- The frame-time driven level. Kept separate from the floors below so the two axes can be
-- combined differently by different consumers -- see `detail` on why the preset must not
-- reach the distance bands.
local _measured = 0
local _presetFloor = 0
local _memFloor = 0
local _memMb = 0
local _memAt = 0
local _slowFor = 0
local _fastFor = 0
local _memTight = false
local _memCritical = false
-- Counts, so a client that never moved and a client that moved and came back can be told
-- apart when reading the published attributes.
local _cuts = 0
local _recoveries = 0

local function watermarks(): (number, number)
	if DeviceProfile.get().handheld then
		return MEM_TIGHT_HANDHELD, MEM_CRIT_HANDHELD
	end
	return MEM_TIGHT_DESKTOP, MEM_CRIT_DESKTOP
end

local function sampleMemory(now: number)
	if now - _memAt < MEM_PERIOD then
		return
	end
	_memAt = now
	local ok, mb = pcall(function()
		return Stats:GetTotalMemoryUsageMb()
	end)
	if not ok or typeof(mb) ~= "number" or mb ~= mb then
		return
	end
	_memMb = mb
	local tight, crit = watermarks()
	_memCritical = mb >= crit
	_memTight = mb >= tight
	_memFloor = if _memCritical then MEM_CRIT_FLOOR elseif _memTight then MEM_TIGHT_FLOOR else 0
end

local function step(dt: number)
	-- Smoothed rather than raw: a single stalled frame -- a bake, an asset load, the player
	-- alt-tabbing -- must not yank the whole city down a level.
	_frameMs += (dt * 1000 - _frameMs) * SMOOTH

	local now = os.clock()
	sampleMemory(now)

	-- Only MEMORY floors the measured level. A device that is short of memory does not recover
	-- by drawing fewer frames, so it must not be allowed to ease back out while it is still
	-- short. The preset floor is applied in `level` instead, on top of this.
	local floor = _memFloor

	if _frameMs > SLOW_MS then
		_fastFor = 0
		_slowFor += dt
		if _slowFor >= CUT_DWELL and _measured < MAX_LEVEL then
			_measured += 1
			_cuts += 1
			_slowFor = 0
		end
	elseif _frameMs < FAST_MS then
		_slowFor = 0
		_fastFor += dt
		if _fastFor >= RECOVER_DWELL and _measured > floor then
			_measured -= 1
			_recoveries += 1
			_fastFor = 0
		end
	else
		-- Between the thresholds is a deliberate dead band: neither timer runs, so a client
		-- sitting at 20 ms holds its level instead of drifting on whichever side it grazes.
		_slowFor = 0
		_fastFor = 0
	end

	if _measured < floor then
		-- Memory going tight takes effect immediately. Floors only ever remove detail, so
		-- there is nothing to ease.
		_measured = floor
	end
end

-- The player's Graphics preset as a floor under the QUALITY levers. Someone on Low has told
-- us their device is struggling, which is evidence rather than a request to be second-guessed.
--
-- Low pins the quality levers at the bottom, which is exactly what they were set to before
-- this file existed: a player on Low got a 9px cull, a 140-kind cache, 64px impostors and no
-- coarse bake, flat. Keeping Low at MAX_LEVEL preserves that behaviour to the digit, and
-- gives Medium the middle setting it never had.
local PRESET_FLOOR: { [string]: number } = table.freeze({
	Low = MAX_LEVEL,
	Medium = 2,
	High = 0,
	Ultra = 0,
})

function RenderPressure.setPreset(name: string?)
	_presetFloor = PRESET_FLOOR[tostring(name)] or 0
end

-- 0 = nothing wrong, 4 = as degraded as this system goes. What the QUALITY levers read.
function RenderPressure.level(): number
	return math.max(_measured, _presetFloor, _memFloor)
end

-- 1.0 at rest down to 0.45 under full pressure. This is the multiplier that pulls DISTANCE
-- bands in; it divides scale elsewhere, so smaller means "draw less".
--
-- It deliberately ignores the preset floor, and that is not an oversight. Every preset already
-- sets `renderDistance` -- Low ships 0.6 -- and the ladder multiplies the two together, so
-- letting the preset drive this as well would apply the player's distance choice twice: a Low
-- player would land at 0.6 x 0.45 = 0.27 without anything having measured a slow frame. The
-- preset says how far to draw; this says how much worse than that the machine is coping.
function RenderPressure.detail(): number
	return DETAIL[math.max(_measured, _memFloor) + 1] or 1
end

-- The one helper every other lever should use: hands back `full` at rest and `pressed` at
-- maximum pressure, interpolated across the levels between. Works in either direction, so a
-- lever that GROWS under pressure (a cull threshold in pixels) reads exactly like one that
-- shrinks (a cache size).
function RenderPressure.lerp(full: number, pressed: number): number
	if MAX_LEVEL <= 0 then
		return full
	end
	return full + (pressed - full) * (RenderPressure.level() / MAX_LEVEL)
end

-- Same, rounded to an integer -- for counts and pixel sizes, which every caller of `lerp`
-- currently wants.
function RenderPressure.lerpInt(full: number, pressed: number): number
	return math.round(RenderPressure.lerp(full, pressed))
end

function RenderPressure.frameMs(): number
	return _frameMs
end

function RenderPressure.memoryMb(): number
	return _memMb
end

function RenderPressure.memoryTight(): boolean
	return _memTight
end

function RenderPressure.memoryCritical(): boolean
	return _memCritical
end

function RenderPressure.stats(): { [string]: any }
	return {
		level = RenderPressure.level(),
		measured = _measured,
		detail = RenderPressure.detail(),
		frameMs = math.round(_frameMs * 10) / 10,
		memoryMb = math.round(_memMb),
		memoryTight = _memTight,
		memoryCritical = _memCritical,
		presetFloor = _presetFloor,
		memFloor = _memFloor,
		cuts = _cuts,
		recoveries = _recoveries,
	}
end

-- Idempotent, and armed on require as well as by Bootstrap, for the reason AssetLODView
-- documents: a system that silently never starts is far worse than one that starts twice,
-- and every consumer of this reads a number that would simply sit at "no pressure" forever.
function RenderPressure.Start()
	if _started then
		return
	end
	_started = true
	RunService.Heartbeat:Connect(function(dt: number)
		local ok, err = pcall(step, dt)
		if not ok then
			warn("[RenderPressure] step failed: " .. tostring(err))
		end
	end)
end

task.defer(function()
	local ok, err = pcall(RenderPressure.Start)
	if not ok then
		warn("[RenderPressure] self-start failed: " .. tostring(err))
	end
end)

return RenderPressure
