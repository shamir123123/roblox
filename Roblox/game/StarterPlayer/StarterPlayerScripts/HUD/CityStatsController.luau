--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local CityStatsController = {}

local KEYS = { "R", "C", "I" }
local BAR_LERP = 0.12

local _conns: { RBXScriptConnection } = {}
local _gauges: { [string]: (number) -> () } = {}
local _target: { [string]: number } = { R = 0, C = 0, I = 0 }
local _factors: { [string]: { [string]: number } } = {}
local _current: { [string]: number } = { R = 0, C = 0, I = 0 }
local _started = false

local function onStats(payload: any)
	if typeof(payload) ~= "table" then return end

	-- Population is rendered by CityVitalsPanel straight off the same payload;
	-- this service owns demand smoothing and nothing else.
	if typeof(payload.demand) ~= "table" then return end

	for _, k in KEYS do
		_target[k] = math.clamp(tonumber(payload.demand[k]) or 0, 0, 1)
	end

	if typeof(payload.demandFactors) == "table" then
		_factors = payload.demandFactors
	end
end

-- Latest per-factor demand breakdown from the server (id -> signed contribution),
-- used by the demand gauge tooltips to explain WHY demand sits where it does.
function CityStatsController.GetFactors(letter: string): { [string]: number }?
	local t = _factors[letter]
	return if typeof(t) == "table" then t else nil
end

-- BottomBarController registers one apply(fraction) per R/C/I gauge; the gauge
-- decides how to render it (radial ring, bar, etc). Fraction is 0..1.
function CityStatsController.SetGauges(gauges: { [string]: (number) -> () })
	_gauges = gauges
end

function CityStatsController.Start()
	if _started then return end

	_started = true

	local Net = require(ReplicatedStorage:WaitForChild("Networker"))

	table.insert(_conns, Net.SyncCityStats.OnClientEvent:Connect(onStats))

	table.insert(_conns, RunService.Heartbeat:Connect(function()
		for k, apply in _gauges do
			local target = _target[k]
			local cur    = _current[k]
			local diff   = target - cur

			-- Settled: snap once, then stop touching the gauge. Without this every
			-- gauge re-rendered each frame forever, even when demand was not moving.
			if math.abs(diff) < 0.001 then
				if cur ~= target then
					_current[k] = target
					apply(target)
				end
				continue
			end

			cur += diff * BAR_LERP
			_current[k] = cur
			apply(cur)
		end
	end))
end

function CityStatsController.Cleanup()
	for _, c in _conns do
		c:Disconnect()
	end

	table.clear(_conns)
	table.clear(_gauges)
	_factors = {}

	_started = false
end

return CityStatsController