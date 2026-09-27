--!strict
-- TimeService
-- The city clock. One full day/night cycle = DAY_SECONDS real seconds at GameSpeed 1
-- (GameSpeed-scaled, so faster sim = faster days). Drives Lighting.ClockTime through a
-- non-linear remap that stretches daylight and compresses the night (short nights),
-- exposes the time-of-day phase (commute windows) the life-sim schedules against on the
-- raw linear fraction, and broadcasts day + fraction to clients for the HUD clock.

local Lighting          = game:GetService("Lighting")
local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Const = require(script.Parent.CitySimConstants)

local TimeService = {}

local DAY_SECONDS = Const.DAY_SECONDS -- real seconds per full day/night cycle at GameSpeed 1 (24 min: a month is 12 h)

-- Night (18:00-06:00) is squeezed into NIGHT_SHARE of the cycle so days feel long and
-- nights pass quickly. frac 0 = midnight (night midpoint), 0.5 = noon. The life-sim
-- still runs on the raw linear fraction below; only the displayed clock is warped.
local NIGHT_SHARE = 0.30
local SUNRISE_HOUR = 6
local SUNSET_HOUR = 18

local function clockTimeFor(frac: number): number
	local halfNight = NIGHT_SHARE * 0.5
	local dayShare = 1 - NIGHT_SHARE
	if frac < halfNight then
		return (frac / halfNight) * SUNRISE_HOUR
	elseif frac < halfNight + dayShare then
		return SUNRISE_HOUR + ((frac - halfNight) / dayShare) * (SUNSET_HOUR - SUNRISE_HOUR)
	end
	return SUNSET_HOUR + ((frac - halfNight - dayShare) / halfNight) * (24 - SUNSET_HOUR)
end

-- Inverse of clockTimeFor. Admin/debug time changes must update the simulation's
-- linear day fraction, not only Lighting.ClockTime, or schedules and saved time drift
-- away from what the player sees.
local function fractionForClockTime(hour: number): number
	local halfNight = NIGHT_SHARE * 0.5
	local dayShare = 1 - NIGHT_SHARE
	if hour < SUNRISE_HOUR then
		return (hour / SUNRISE_HOUR) * halfNight
	elseif hour < SUNSET_HOUR then
		return halfNight + ((hour - SUNRISE_HOUR) / (SUNSET_HOUR - SUNRISE_HOUR)) * dayShare
	end
	return halfNight + dayShare + ((hour - SUNSET_HOUR) / (24 - SUNSET_HOUR)) * halfNight
end

-- Day fractions (0=midnight, 0.25=6am, 0.5=noon, 0.75=6pm).
local WORKBOUND_START, WORKBOUND_END = 0.27, 0.40 -- citizens leave for work
local HOMEBOUND_START, HOMEBOUND_END = 0.66, 0.82 -- citizens head home

local _dayFraction = 0.5 -- 0.5 = noon; every new city starts at midday
local _day = 1
local _running = false
local _heartbeat: RBXScriptConnection?
local _syncRemote: RemoteEvent
local _broadcastAccum = 0

-- 0 = paused, otherwise the time multiplier (1x/2x/3x).
local function gameSpeed(): number
	return math.clamp(tonumber(workspace:GetAttribute("GameSpeed")) or 1, 0, 3)
end

function TimeService.getDayFraction(): number
	return _dayFraction
end

function TimeService.getDay(): number
	return _day
end

-- ---- Persistence ----
-- The clock/calendar are saved with the city so they resume where the player
-- left off. Day 1 at noon is the fixed start for every brand-new city.
local function applyClock()
	Lighting.ClockTime = clockTimeFor(_dayFraction)
	workspace:SetAttribute("CityDay", _day)
end

function TimeService.setClockTime(hour: number): (number, number)
	if hour ~= hour or hour == math.huge or hour == -math.huge then
		error("[TimeService] invalid clock time")
	end
	local normalized = hour % 24
	_dayFraction = fractionForClockTime(normalized)
	applyClock()
	_broadcastAccum = 0
	_syncRemote:FireAllClients({ day = _day, frac = _dayFraction })
	return Lighting.ClockTime, _dayFraction
end

function TimeService.serialize(): { day: number, frac: number }
	return { day = _day, frac = _dayFraction }
end

function TimeService.reset()
	_day = 1
	_dayFraction = 0.5
	applyClock()
end

function TimeService.restore(blob: { [string]: any }?)
	if typeof(blob) == "table" then
		local day = tonumber(blob.day)
		local frac = tonumber(blob.frac)
		if day and day >= 1 and frac and frac >= 0 and frac < 1 then
			_day = math.floor(day)
			_dayFraction = frac
			applyClock()
			return
		end
	end
	-- Missing/old/corrupt save: fall back to the fixed start date.
	TimeService.reset()
end

function TimeService.getPhase(): string
	local f = _dayFraction
	if f >= WORKBOUND_START and f < WORKBOUND_END then return "WorkCommute"
	elseif f >= WORKBOUND_END and f < HOMEBOUND_START then return "Work"
	elseif f >= HOMEBOUND_START and f < HOMEBOUND_END then return "HomeCommute"
	else return "Night" end
end

function TimeService.isWorkboundWindow(): boolean
	return _dayFraction >= WORKBOUND_START and _dayFraction < WORKBOUND_END
end

function TimeService.isHomeboundWindow(): boolean
	return _dayFraction >= HOMEBOUND_START and _dayFraction < HOMEBOUND_END
end

local function step(dt: number)
	_dayFraction += dt * gameSpeed() / DAY_SECONDS
	while _dayFraction >= 1 do
		_dayFraction -= 1
		_day += 1
		workspace:SetAttribute("CityDay", _day)
	end

	Lighting.ClockTime = clockTimeFor(_dayFraction)

	_broadcastAccum += dt
	if _broadcastAccum >= 1.0 then
		_broadcastAccum = 0
		_syncRemote:FireAllClients({ day = _day, frac = _dayFraction })
	end
end

function TimeService.Init()
	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	_syncRemote = Net.SyncTime
end

function TimeService.Bind()
	Players.PlayerAdded:Connect(function(player: Player)
		-- No city loaded yet (main menu) -> _running is false, nothing to sync.
		if not _running then return end
		_syncRemote:FireClient(player, { day = _day, frac = _dayFraction })
	end)
end

function TimeService.Start()
	if _running then return end
	_running = true
	_heartbeat = RunService.Heartbeat:Connect(function(dt: number)
		step(math.min(dt, 0.1))
	end)
end

return TimeService
