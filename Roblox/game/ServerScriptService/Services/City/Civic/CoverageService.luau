--!strict

-- Owns the spatial rasters: pollution, noise, and utility service coverage.
-- 16-stud grid. Pollution + industrial noise come from point sources pushed in
-- by other services (industrial buildings via BuildingService, dirty utilities
-- via EmergencyService). Traffic noise is measured from the vehicles actually on the
-- road (heavy trucks loud, buses less) and kept as a running average per cell. Utility coverage is delegated: power to PowerService's grid,
-- water and sewage to WaterService's pools; the radius model below is the fallback.
-- Phase A note: source layers are recomputed in full (batched per-frame) on
-- change rather than per-cell dirty-rect. Source counts are small so the result
-- is identical; per-cell dirty-rect is a later optimization if needed.

local RunService = game:GetService("RunService")
local Workspace  = game:GetService("Workspace")

local Const            = require(script.Parent.Parent.CitySimConstants)
local NPCDriverService = require(game:GetService("ServerScriptService").Services.NPC.NPCDriverService)

local CoverageService = {}

local CELL = Const.CELL_SIZE

type Source = {
	pos             : Vector3,
	pollution       : number,
	noise           : number,
	pollutionRadius : number,
	noiseRadius     : number,
}

local _roadService      : any
local _serviceBuildings : any -- EmergencyService: owns the placed utility buildings
local _sources          : { [string]: Source } = {}
local _powerService     : any -- PowerService (optional): owns the electricity grid
local _waterService     : any -- WaterService (optional): owns the water and sewage pools

-- Cell rasters (sparse, keyed by "cx|cz"). Values already capped 0..1.
local _pollutionCell : { [string]: number } = {}
local _srcNoiseCell  : { [string]: number } = {}
local _trafficNoiseCell : { [string]: number } = {}

local _version      = 0
local _flushQueued  = false

local function cellKey(cx: number, cz: number): string
	return tostring(cx) .. "|" .. tostring(cz)
end

local function cellOf(pos: Vector3): string
	return cellKey(math.floor(pos.X / CELL), math.floor(pos.Z / CELL))
end

local function cellCenterWorld(cx: number, cz: number): (number, number)
	return (cx + 0.5) * CELL, (cz + 0.5) * CELL
end

-- Stamp a point source into a target raster with linear falloff, additive then
-- capped. Used for both pollution and source/road noise layers.
local function stamp(raster: { [string]: number }, pos: Vector3, strength: number, radius: number, cap: number)
	if strength <= 0 or radius <= 0 then return end

	local minCx = math.floor((pos.X - radius) / CELL)
	local maxCx = math.floor((pos.X + radius) / CELL)
	local minCz = math.floor((pos.Z - radius) / CELL)
	local maxCz = math.floor((pos.Z + radius) / CELL)

	for cx = minCx, maxCx do
		for cz = minCz, maxCz do
			local wx, wz = cellCenterWorld(cx, cz)
			local dx, dz = wx - pos.X, wz - pos.Z
			local dist = math.sqrt(dx * dx + dz * dz)

			if dist <= radius then
				local contrib = strength * (1 - dist / radius)
				local key = cellKey(cx, cz)
				raster[key] = math.min(cap, (raster[key] or 0) + contrib)
			end
		end
	end
end

local function rebuildSourceLayers()
	_pollutionCell = {}
	_srcNoiseCell  = {}

	for _, src in _sources do
		stamp(_pollutionCell, src.pos, src.pollution, src.pollutionRadius, Const.POLLUTION_CAP)
		stamp(_srcNoiseCell,  src.pos, src.noise,     src.noiseRadius,     Const.NOISE_CAP)
	end
end

local function scheduleFlush()
	if _flushQueued then return end
	_flushQueued = true

	task.defer(function()
		_flushQueued = false
		rebuildSourceLayers()
		_version += 1
	end)
end

-- Public ------------------------------------------------------------------

function CoverageService.setSource(
	id: string,
	pos: Vector3,
	pollution: number,
	noise: number,
	pollutionRadius: number,
	noiseRadius: number
)
	_sources[id] = {
		pos             = pos,
		pollution       = pollution,
		noise           = noise,
		pollutionRadius = pollutionRadius,
		noiseRadius     = noiseRadius,
	}
	scheduleFlush()
end

function CoverageService.removeSource(id: string)
	if _sources[id] == nil then return end
	_sources[id] = nil
	scheduleFlush()
end

-- One traffic-noise sample: every heavy vehicle stamps where it is now, and each cell's
-- level moves a little toward that (an exponential running average).
local function sampleTrafficNoise()
	local fresh: { [string]: number } = {}
	for _, src in NPCDriverService.GetNoiseSources() do
		stamp(fresh, src.pos, src.weight * Const.TRAFFIC_NOISE_UNIT, Const.TRAFFIC_NOISE_RADIUS, math.huge)
	end
	local k = Const.TRAFFIC_NOISE_SMOOTHING
	for key, v in _trafficNoiseCell do
		local nv = v + ((fresh[key] or 0) - v) * k
		_trafficNoiseCell[key] = if nv > 0.002 then nv else nil
		fresh[key] = nil
	end
	for key, f in fresh do
		_trafficNoiseCell[key] = f * k
	end
end

function CoverageService.getPollutionAt(pos: Vector3): number
	return _pollutionCell[cellOf(pos)] or 0
end

function CoverageService.getNoiseAt(pos: Vector3): number
	local key = cellOf(pos)
	local total = (_trafficNoiseCell[key] or 0) + (_srcNoiseCell[key] or 0)
	return math.min(Const.NOISE_CAP, total)
end

-- Utility coverage from placed utility buildings (radius model, matching the
-- emergency services). Unknown service types stay fully covered so nothing
-- breaks when a new consumer asks for a layer that does not exist yet.
-- ponytail: binary radius coverage; road-graph BFS is the upgrade path if
-- "reaches the pipe network" ever matters.
local UTILITY_KIND: { [string]: string } = { power = "Power", water = "Water", sewage = "Sewage" }
-- PowerService boots after this one, so it arrives by injection, not require.
function CoverageService.setPowerService(svc: any)
	_powerService = svc
end

function CoverageService.setWaterService(svc: any)
	_waterService = svc
end

function CoverageService.getCoverageAt(pos: Vector3, serviceType: string): number
	local lower = string.lower(serviceType)
	-- Electricity is a GRID, not a reach. Whether a point is fed depends on the generator,
	-- the poles carrying power on from it, and whether that grid is meeting its own demand
	-- -- all of which PowerService owns. It answers 1 for a city with no generator at all,
	-- which is the same "not in play" rule the radius model uses just below.
	if lower == "power" and _powerService then
		return if _powerService.isSuppliedAt(pos) then 1.0 else 0.0
	end
	local kind = UTILITY_KIND[lower]
	-- Water and sewage have a capacity, not just a reach: a tower that is out of water
	-- leaves homes dry inside its radius, so WaterService answers.
	if kind and lower ~= "power" and _waterService then
		return if _waterService.isServedAt(pos, kind) then 1.0 else 0.0
	end
	if not kind or not _serviceBuildings then return 1.0 end
	-- No building of this utility anywhere -> the layer is not in play, so nothing is
	-- "uncovered" by it. With utilities off the build bar, land value failed its power/
	-- water gates on every plot in the city and no building could ever level up.
	if _serviceBuildings.hasKind and not _serviceBuildings.hasKind(kind) then return 1.0 end
	return if _serviceBuildings.coversAt(pos, kind) then 1.0 else 0.0
end

function CoverageService.getVersion(): number
	return _version
end

-- Force a synchronous rebuild of source layers (tests / deterministic reads).
function CoverageService.flush()
	rebuildSourceLayers()
	_version += 1
end

function CoverageService.Init(roadService: any, serviceBuildingService: any?)
	_roadService = roadService
	_serviceBuildings = serviceBuildingService
end

function CoverageService.Bind() end

function CoverageService.Start()
	local accum = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accum += dt * math.clamp(tonumber(Workspace:GetAttribute("GameSpeed")) or 1, 0, 3)
		if accum < Const.TRAFFIC_NOISE_TICK then return end
		accum = 0
		local ok, err = pcall(sampleTrafficNoise)
		if not ok then warn("[CoverageService] traffic noise sample failed: " .. tostring(err)) end
	end)
end

return CoverageService
