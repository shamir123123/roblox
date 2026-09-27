--!strict
-- Collects the whole city into one DataStore-safe blob and rebuilds it.
-- Pure orchestration: each service owns its own serialize/restore, this module
-- owns the ordering (terrain -> roads -> building state -> plots -> services).

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

if not RunService:IsServer() then
	error("[CitySerializer] Must only be required on the server")
end

-- Every position-carrying section rounds to 1 decimal on the way into the blob, and
-- service pivots pack to {x,y,z,yawDeg} (whole-degree rotation) -- see Quant
-- (placement already snaps to the same grid, so this is the safety net for values
-- computed server-side and for old full-precision saves, which self-heal on their
-- next save). Terrain (packed format), nature (already whole-stud ints) and sim
-- state (economy/time/citizens) are deliberately NOT rounded. Neither are plots:
-- their t0/t1 are 0..1 curve parameters, not studs -- rounding there would shift
-- plot edges by up to a stud on long segments and break run-adjacency (1e-3 tol).
local Quant = require(ReplicatedStorage.Shared.Quant)

local SCHEMA_VERSION = 1

local CitySerializer = {}

local _roadService: any
local _buildingService: any
local _terrainDataService: any
local _economyService: any
local _citizenService: any
local _educationService: any
local _emergencyService: any
local _fireService: any
local _transitService: any
local _timeService: any
local _outsideConnectionService: any
local _plotService: any
local _natureService: any
local _progressionService: any
local _signalPlanStore: any
local _creationPlaceService: any
local _throughTrafficService: any
local _supplyService: any
local _powerService: any
local _waterPipeService: any
local _territoryService: any

function CitySerializer.Init(roadService: any, buildingService: any, terrainDataService: any, economyService: any?, citizenService: any?, educationService: any?, emergencyService: any?, fireService: any?, transitService: any?, timeService: any?, outsideConnectionService: any?, plotService: any?, natureService: any?, progressionService: any?, signalPlanStore: any?, creationPlaceService: any?, throughTrafficService: any?, supplyService: any?, powerService: any?, waterPipeService: any?)
	assert(roadService and buildingService and terrainDataService,
		"[CitySerializer] Init requires RoadService, BuildingService and TerrainDataService")
	_roadService = roadService
	_buildingService = buildingService
	_terrainDataService = terrainDataService
	_economyService = economyService
	_citizenService = citizenService
	_educationService = educationService
	_emergencyService = emergencyService
	_fireService = fireService
	_transitService = transitService
	_timeService = timeService
	_outsideConnectionService = outsideConnectionService
	_plotService = plotService
	_natureService = natureService
	_progressionService = progressionService
	_signalPlanStore = signalPlanStore
	_creationPlaceService = creationPlaceService
	_throughTrafficService = throughTrafficService
	_supplyService = supplyService
	_powerService = powerService
	_waterPipeService = waterPipeService
end

-- Late-injected: TerritoryService boots after this module is required. Optional, and the
-- ABSENCE of its section in a save is meaningful -- see TerritoryService.restore, which
-- grandfathers a pre-territory city onto the whole map rather than locking it out of ground
-- it is already built on.
function CitySerializer.SetTerritoryService(svc: any)
	_territoryService = svc
end

-- Buses out on their routes are saved with the city and put back where they were.
local _busDispatch: any
function CitySerializer.SetBusDispatchService(svc: any)
	_busDispatch = svc
end

function CitySerializer.serialize(mapId: string?, difficulty: string?, cameraState: any?): { [string]: any }
	return {
		version = SCHEMA_VERSION,
		savedAt = os.time(),
		mapId = mapId,
		difficulty = difficulty,
		camera = cameraState,
		terrain = _terrainDataService.serializeState(),
		roads = Quant.deep(_roadService.serializeRoads()),
		plots = if _plotService then _plotService.serialize() else nil,
		buildings = Quant.deep(_buildingService.serializeBuildings()),
		education = if _educationService and _educationService.serialize then Quant.deep(_educationService.serialize()) else nil,
		emergency = if _emergencyService and _emergencyService.serialize then Quant.deep(_emergencyService.serialize()) else nil,
		transit = if _transitService and _transitService.serialize then Quant.deep(_transitService.serialize()) else nil,
		citizens = if _citizenService and _citizenService.serialize then _citizenService.serialize() else nil,
		-- Live inter-city traffic. Not rounded by Quant for the same reason citizens are
		-- not: it carries its own 2-decimal car pose, and a queue's spacing is the thing
		-- being saved. Sized by MAX_CONCURRENT (300) x 7 numbers -- nothing against the cap.
		traffic = if _throughTrafficService and _throughTrafficService.serialize then _throughTrafficService.serialize() else nil,
		-- Deliveries in flight. The goods STOCK behind them is deliberately not saved (it
		-- rebuilds from production in a few ticks); this is the fleet on the road plus the
		-- inbound reservation each truck is holding against its destination shop.
		supply = if _supplyService and _supplyService.serialize then _supplyService.serialize() else nil,
		buses = if _busDispatch and _busDispatch.serialize then _busDispatch.serialize() else nil,
		-- Power poles. The turbines ride the `emergency` section (EmergencyService owns
		-- them); this is the wire network the player laid between them.
		power = if _powerService and _powerService.serialize then Quant.deep(_powerService.serialize()) else nil,
		-- The buried mains. Towers ride `emergency`; this is the pipe the player dug.
		pipes = if _waterPipeService and _waterPipeService.serialize then Quant.deep(_waterPipeService.serialize()) else nil,
		economy = if _economyService then _economyService.serialize() else nil,
		time = if _timeService then _timeService.serialize() else nil,
		outside = if _outsideConnectionService then _outsideConnectionService.serialize() else nil,
		nature = if _natureService and _natureService.serialize then _natureService.serialize() else nil,
		progression = if _progressionService then _progressionService.serialize() else nil,
		-- Which map tiles the city has bought. A handful of small ints.
		territory = if _territoryService then _territoryService.serialize() else nil,
		-- Player-authored signal timings and corridor groups. Anchored by junction
		-- POSITION, not by node id -- ids regenerate on restore (see restoreRoads), so
		-- an id-keyed plan would come back on whichever junction inherited its number.
		signals = if _signalPlanStore then _signalPlanStore.serialize() else nil,
		-- Player-authored creations. Prototype/instance: the geometry blobs sit in
		-- `library` keyed by blueprint id and every placement is three numbers. Blobs are
		-- INLINED rather than re-read from BlueprintStore on load, so a city never depends
		-- on a blueprint its author has since deleted.
		creations = if _creationPlaceService then _creationPlaceService.serialize() else nil,
	}
end

-- The PHYSICAL city only: terrain, roads, plots, every building (incl. service
-- buildings + transit). Excludes the live sim -- money, clock, population, citizens --
-- so a map default baked from this gives each new player a pre-built city that starts
-- its economy and calendar fresh. Edge connections are not stored; they re-derive from
-- the roads on restore. Used by MapTemplateService for the F6 "save as map default".
function CitySerializer.serializePhysical(mapId: string?): { [string]: any }
	return {
		version = SCHEMA_VERSION,
		savedAt = os.time(),
		mapId = mapId,
		-- true = template bake: absolute vs the seed base, never diffed vs a template
		terrain = _terrainDataService.serializeState(true),
		roads = Quant.deep(_roadService.serializeRoads()),
		plots = if _plotService then _plotService.serialize() else nil,
		buildings = Quant.deep(_buildingService.serializeBuildings()),
		education = if _educationService and _educationService.serialize then Quant.deep(_educationService.serialize()) else nil,
		emergency = if _emergencyService and _emergencyService.serialize then Quant.deep(_emergencyService.serialize()) else nil,
		transit = if _transitService and _transitService.serialize then Quant.deep(_transitService.serialize()) else nil,
		nature = if _natureService and _natureService.serialize then _natureService.serialize() else nil,
		power = if _powerService and _powerService.serialize then Quant.deep(_powerService.serialize()) else nil,
		pipes = if _waterPipeService and _waterPipeService.serialize then Quant.deep(_waterPipeService.serialize()) else nil,
		-- Signal timings are part of the physical city: a map template that ships a
		-- built arterial should ship the corridor timing that makes it work.
		signals = if _signalPlanStore then _signalPlanStore.serialize() else nil,
		-- Creations are physical too: a map default that ships a landmark should ship it.
		creations = if _creationPlaceService then _creationPlaceService.serialize() else nil,
		-- And so is the land: a template that ships a built city has to ship the tiles that
		-- city stands on, or every new player on that map starts unable to touch it.
		territory = if _territoryService then _territoryService.serialize() else nil,
	}
end

-- Rebuild the city from a blob. Yields (buildings spawn across frames), so callers
-- run this from a spawned task, never from Init.
function CitySerializer.restore(blob: { [string]: any }, fallbackRelief: number?): (boolean, string?)
	if typeof(blob) ~= "table" then
		return false, "save data is not a table"
	end

	if typeof(blob.version) ~= "number" or blob.version > SCHEMA_VERSION then
		return false, "save data has an unsupported version"
	end

	-- Where a load's restore time goes, one line per load. Only phases over 50 ms are named;
	-- "[CitySlotLoad] restore 4.8" alone cannot say which of fifteen services to look at.
	local laps: { string } = {}
	local tLap = os.clock()
	local function lap(name: string)
		local now = os.clock()
		if now - tLap >= 0.05 then laps[#laps + 1] = string.format("%s %.2f", name, now - tLap) end
		tLap = now
	end

	-- Restore the clock first so getDay()/getDayFraction() are correct for every
	-- downstream service (citizens record their founded-day against it).
	if _timeService then
		_timeService.restore(blob.time)
	end

	-- Fires are transient and never persisted; drop any from a previous city.
	if _fireService and _fireService.clear then
		pcall(_fireService.clear)
	end

	_terrainDataService.loadState(blob.terrain, fallbackRelief)

	lap("terrain")
	local roads = if typeof(blob.roads) == "table" then blob.roads else {}
	local okRoads, roadErr = pcall(_roadService.restoreRoads, roads)
	if not okRoads then
		return false, "road restore failed: " .. tostring(roadErr)
	end

	lap("roads")
	-- Land BEFORE anything that sits on it: every placement service asks the territory
	-- gate, so restoring a building while the city still holds the previous city's tiles
	-- would judge it against the wrong map.
	if _territoryService and _territoryService.restore then
		pcall(_territoryService.restore, blob.territory)
	end

	-- Outside connections are DERIVED from the roads, not stored: now that the road
	-- graph is back, re-scan it for edge-touching endpoints and rebuild the arrows.
	if _outsideConnectionService and _outsideConnectionService.restore then
		pcall(_outsideConnectionService.restore, blob.outside)
	end

	lap("territory+outside")
	-- Building state first: this tears the standing city down and stages the saved
	-- level/occupancy/residents by save key. It places nothing.
	local buildings = if typeof(blob.buildings) == "table" then blob.buildings else {}
	local okBuildings, bldgErr = pcall(_buildingService.restoreBuildings, buildings)
	if not okBuildings then
		warn("[CitySerializer] building state restore failed: " .. tostring(bldgErr))
	end

	lap("buildings")
	-- Plots ARE the buildings: each restored group re-subdivides against the roads that are
	-- already back and develops one building per plot (no crane on load), reclaiming the
	-- state staged above by save key.
	if _plotService and _plotService.restore then
		local okPlots, plotErr = pcall(_plotService.restore, blob.plots)
		if not okPlots then
			warn("[CitySerializer] plot restore failed: " .. tostring(plotErr))
		end
	end

	lap("plots")
	-- Schools restore before citizens so children have somewhere to be sent on first tick.
	if _educationService and _educationService.restore then
		local okEdu, eduErr = pcall(_educationService.restore, blob.education)
		if not okEdu then
			warn("[CitySerializer] education restore failed: " .. tostring(eduErr))
		end
	end

	-- Emergency service buildings (hospital/police/fire stations) restore alongside schools.
	if _emergencyService and _emergencyService.restore then
		local okEmrg, emrgErr = pcall(_emergencyService.restore, blob.emergency)
		if not okEmrg then
			warn("[CitySerializer] emergency restore failed: " .. tostring(emrgErr))
		end
	end

	lap("education+emergency")
	-- Power poles restore with the buildings they wire: the grid is recomputed from
	-- scratch on the next PowerService tick, so only the pole positions have to come back.
	if _powerService and _powerService.restore then
		local okPower, powerErr = pcall(_powerService.restore, blob.power)
		if not okPower then
			warn("[CitySerializer] power restore failed: " .. tostring(powerErr))
		end
	end

	lap("power")
	-- Pipes restore after the service buildings, so the first network pass already knows
	-- which towers a main is plugged into rather than reporting the whole city stranded.
	if _waterPipeService and _waterPipeService.restore then
		local okPipes, pipeErr = pcall(_waterPipeService.restore, blob.pipes)
		if not okPipes then
			warn("[CitySerializer] water pipe restore failed: " .. tostring(pipeErr))
		end
	end

	lap("pipes")
	-- Transit (depots/stops/routes) restores after the road graph is back so each route
	-- can re-path its legs; buses respawn from BusDispatchService on the next reconcile.
	if _transitService and _transitService.restore then
		local okTransit, transitErr = pcall(_transitService.restore, blob.transit)
		if not okTransit then
			warn("[CitySerializer] transit restore failed: " .. tostring(transitErr))
		end
	end

	if _busDispatch and _busDispatch.restore then
		local okBuses, busErr = pcall(_busDispatch.restore, blob.buses)
		if not okBuses then
			warn("[CitySerializer] bus restore failed: " .. tostring(busErr))
		end
	end

	lap("transit")
	-- Nature props (scenery) restore BEFORE citizens: a placed car park is a NatureProp, and
	-- its stalls are where ParkingService puts a household's car back. Restored after the
	-- citizens, every lot in the city was still missing when they picked a spot, so every car
	-- that had been left in a car park came back standing at the kerb outside its house.
	if _natureService and _natureService.restore then
		local okNature, natErr = pcall(_natureService.restore, blob.nature)
		if not okNature then
			warn("[CitySerializer] nature restore failed: " .. tostring(natErr))
		end
	end

	lap("nature")
	-- Delivery trucks restore BEFORE citizens, for two reasons. Their driver holds an
	-- industrial job slot, and CitizenService assigns the rest of the workforce against
	-- that count -- so the slots have to be taken first or the same jobs get handed out
	-- twice. And unlike the Citizens folder, nothing else sweeps Workspace._City.Trucks on
	-- a load, so SupplyService.restore is also what clears the outgoing city's fleet.
	if _supplyService and _supplyService.restore then
		local okSupply, supplyErr = pcall(_supplyService.restore, blob.supply)
		if not okSupply then
			warn("[CitySerializer] supply restore failed: " .. tostring(supplyErr))
		end
	end

	lap("supply")
	if _citizenService and _citizenService.restore then
		local okCitizens, citizenErr = pcall(_citizenService.restore, blob.citizens)
		if not okCitizens then
			warn("[CitySerializer] citizen restore failed: " .. tostring(citizenErr))
		end
	end

	lap("citizens")
	-- Through traffic MUST come after citizens: restoring citizens destroys every model in
	-- the Workspace._City.Citizens folder, which is the same folder the through-cars park
	-- in, so anything put there earlier is swept straight back out. By here the road graph,
	-- the buildings and the commuting household cars are all back, which is exactly the
	-- city each through-car re-plans its crossing against.
	if _throughTrafficService and _throughTrafficService.restore then
		local okTraffic, trafficErr = pcall(_throughTrafficService.restore, blob.traffic)
		if not okTraffic then
			warn("[CitySerializer] through traffic restore failed: " .. tostring(trafficErr))
		end
	end

	lap("traffic")
	-- Creations restore late: decoration that needs only the terrain (already loaded) and
	-- that no part of the sim waits on.
	if _creationPlaceService and _creationPlaceService.restore then
		local okCreations, creationErr = pcall(_creationPlaceService.restore, blob.creations)
		if not okCreations then
			warn("[CitySerializer] creation restore failed: " .. tostring(creationErr))
		end
	end

	lap("creations")
	if _economyService then
		_economyService.restore(blob.economy)
	end

	-- Progression restores unconditionally: a nil key (fresh city, template, or a
	-- pre-progression save) resets milestones and re-baselines them silently.
	if _progressionService then
		pcall(_progressionService.restore, blob.progression)
	end

	-- Signal plans last of all. They anchor to junctions by position, so they need the
	-- road network already rebuilt -- and a nil key (a save from before signals were
	-- editable) simply clears to the automatic timings every junction started with.
	if _signalPlanStore then
		local okSignals, signalErr = pcall(_signalPlanStore.restore, blob.signals)
		if not okSignals then
			warn("[CitySerializer] signal plan restore failed: " .. tostring(signalErr))
		end
	end

	lap("economy+progression+signals")
	warn("[CityRestore] " .. (if #laps > 0 then table.concat(laps, " + ") else "every phase under 50 ms"))
	return true
end

return CitySerializer
