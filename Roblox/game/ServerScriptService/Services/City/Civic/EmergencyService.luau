--!strict
-- EmergencyService
-- Owns the placeable service buildings: Hospitals, Police Stations, Fire Stations, and
-- the utilities (Power Plants, Water Towers, Sewage Plants). Builds + tags the models, answers "is this position covered by a hospital/police/
-- fire station?" for the sim, reports city-wide coverage fractions for happiness/demand, and
-- serialises the placed buildings so they survive a reload.
--
-- One domain: emergency service buildings. It does NOT own citizens, crime or fires --
-- CitizenService, CityStatsService and FireService ask it for coverage. Mirrors EducationService.

local CollectionService   = game:GetService("CollectionService")
local Workspace           = game:GetService("Workspace")
local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ServiceTypes         = require(ReplicatedStorage.City.ServiceTypes)
local ServiceBuildingModel = require(ReplicatedStorage.City.ServiceBuildingModel)
local Quant                = require(ReplicatedStorage.Shared.Quant)
local NetMiddleware        = require(ReplicatedStorage:WaitForChild("NetMiddleware"))
local ServicePlacement     = require(ServerScriptService.Services.City.ServicePlacement)
local TerrainPadService    = require(ServerScriptService.Services.Terrain.TerrainPadService)

local EmergencyService = {}

local PLACE_COOLDOWN = 0.15
local SHORE_MARGIN = 12 -- studs past a shore building's edge that must reach open water

-- Coverage domain -> the CollectionService tag put on the model. Hospital uses "Healthcare"
-- so CitizenService.hasHealthcare (births + sickness) lights up with no extra wiring.
local KIND_TAG: { [string]: string } = {
	Hospital = "Healthcare",
	Police   = "PoliceStation",
	Fire     = "FireStation",
	Deathcare = "Cemetery",
	Power    = "PowerPlant",
	Water    = "WaterSource",
	Sewage   = "SewagePlant",
}

type Building = {
	id: number,
	key: string,
	kind: string,
	cf: CFrame,
	entrance: Vector3,
	radius: number,
	model: Model,
}

local _net: any
local _buildingService: any
local _economyService: any
local _coverageService: any
local _isPlaceableAllowed: ((string) -> boolean)?
local _powerService: any -- PowerService (optional): answers the generator keep-out ring
local _folder: Folder
local _buildings: { [number]: Building } = {}
local _nextId = 0
local _lastPlaceAt: { [Player]: number } = {}

local function ensureFolder(): Folder
	local city = Workspace:FindFirstChild("_City")
	if not city then city = Instance.new("Folder"); city.Name = "_City"; city.Parent = Workspace end
	local f = city:FindFirstChild("EmergencyServices")
	if not f or not f:IsA("Folder") then
		if f then f:Destroy() end
		f = Instance.new("Folder"); f.Name = "EmergencyServices"; f.Parent = city
	end
	return f :: Folder
end

local function flatDist(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- Development Tree gate (ProgressionService.isPlaceableAllowed), injected by Bootstrap.
-- The client hiding a locked card is presentation; THIS is the rule. No check injected
-- (tests, tooling) means nothing is gated.
function EmergencyService.setUnlockCheck(fn: ((string) -> boolean)?)
	_isPlaceableAllowed = fn
end

-- PowerService owns the keep-out ring around a generator. Injected rather than required:
-- it boots after this service, and only some specs carry a `minSpacing` at all.
function EmergencyService.setPowerService(svc: any)
	_powerService = svc
end

local function isUnlocked(key: string): boolean
	local check = _isPlaceableAllowed
	return check == nil or check(key) == true
end

-- Territory gate (TerritoryService.isBoxAllowed), injected by Bootstrap. The unlock check
-- above answers "is this building available"; this answers "is this GROUND yours". Asked of
-- the whole FOOTPRINT, not the pivot: half a building over the border is not a building you
-- are allowed to put up. No check injected (tests, tooling) means nothing is gated.
local _territoryCheck: ((Vector3, number, number) -> boolean)? = nil

local function isOnOwnedLand(pos: Vector3, hx: number, hz: number): boolean
	local check = _territoryCheck
	return check == nil or check(pos, hx, hz) == true
end
function EmergencyService.setTerritoryCheck(fn: ((Vector3, number, number) -> boolean)?)
	_territoryCheck = fn
end

-- Build + register one building. Internal: trusts its inputs (validation is in `place`).
local function spawn(id: number, key: string, pivot: CFrame, entrance: Vector3): Building?
	local spec = ServiceTypes.get(key)
	if not spec then return nil end
	local model = ServiceBuildingModel.build(key, false)
	if not model then return nil end
	model:PivotTo(pivot)
	model:SetAttribute("ServiceId", id)
	model:SetAttribute("ServiceType", key)
	model:SetAttribute("ServiceKind", spec.kind)
	model:SetAttribute("ServiceName", spec.name)
	model:SetAttribute("CoverageRadius", spec.coverageRadius)
	local tag = KIND_TAG[spec.kind]
	if tag then CollectionService:AddTag(model, tag) end
	model.Parent = _folder

	-- Flatten the terrain under the building footprint.
	local fp = ServiceTypes.footprintStuds(spec)
	pcall(TerrainPadService.padFootprint, "svc:" .. id, pivot, fp.X, fp.Z, pivot.Position.Y)

	-- Dirty utilities (power/sewage) are pollution point sources like industry.
	if _coverageService and spec.pollution and spec.pollution > 0 then
		_coverageService.setSource("svc:" .. id, pivot.Position, spec.pollution, 0, spec.pollutionRadius or 48, 0)
	end

	local building: Building = {
		id = id, key = key, kind = spec.kind, cf = pivot, entrance = entrance,
		radius = spec.coverageRadius, model = model,
	}
	_buildings[id] = building
	return building
end

-- == Public ====================================================================
-- Placement: anywhere on the map. The client sends a pivot; the server keeps only its
-- X/Z + yaw, re-grounds Y on the authoritative terrain, and rejects overlaps with
-- anything already standing in the city.
-- `actor` only decides who gets the cost tag and the build sound back; the building is city
-- state and replicates to everyone either way.
function EmergencyService.placeFree(key: string, pivotIn: CFrame, actor: Player?): (boolean, string?)
	local spec = ServiceTypes.get(key)
	if not spec then return false, "unknown building" end
	if not isUnlocked(key) then return false, spec.name .. " is not unlocked yet" end

	local fp = ServiceTypes.footprintStuds(spec)
	local pivot, reason = ServicePlacement.prepareFree(fp, pivotIn)
	if not pivot then return false, reason end

	-- After prepareFree, so the land test sees where the building actually lands.
	if not isOnOwnedLand(pivot.Position, fp.X * 0.5, fp.Z * 0.5) then
		return false, "you do not own this land"
	end
	if spec.shore and not ServicePlacement.touchesWater(pivot, fp, SHORE_MARGIN) then
		return false, "it has to stand on the shore, touching water"
	end

	-- Generators keep a ring clear of one another. The footprint test cannot see this:
	-- a turbine's tower is slim, and it is the blades -- hanging well outside the
	-- footprint -- that would end up overlapping.
	if _powerService and _powerService.spacingBlockedAt(key, pivot.Position) then
		return false, "too close to another " .. spec.name
	end

	if _economyService and _economyService.trySpend then
		if not _economyService.trySpend(spec.cost) then return false, "can't afford" end
	end

	local entrance = (pivot * CFrame.new(0, 0, fp.Z * 0.5 + 4)).Position

	_nextId += 1
	if not spawn(_nextId, key, pivot, entrance) then
		if _economyService and _economyService.credit then _economyService.credit(spec.cost) end
		return false, "build failed"
	end
	if _net and _economyService and actor then _net.PlacementCharged:FireClient(actor, pivot.Position, spec.cost, "Building") end
	return true
end

local function releaseBuilding(b: Building)
	pcall(TerrainPadService.unpadFootprint, "svc:" .. b.id)
	if _coverageService then _coverageService.removeSource("svc:" .. b.id) end
	if b.model and b.model.Parent then b.model:Destroy() end
end

function EmergencyService.remove(id: number)
	local b = _buildings[id]
	if not b then return end
	releaseBuilding(b)
	_buildings[id] = nil
end

-- Move tool: relocate an already-placed building. Same sanitising + overlap rules
-- as placeFree (X/Z + yaw kept, Y re-grounded), but free of charge and keeping the
-- id, kind and occupants. The old pad / pollution source releases, the new one is claimed.
function EmergencyService.move(id: number, pivotIn: CFrame): (boolean, string?)
	local b = _buildings[id]
	if not b then return false, "no such building" end
	local spec = ServiceTypes.get(b.key)
	if not spec then return false, "unknown building" end

	local fp = ServiceTypes.footprintStuds(spec)
	-- Same rules as placeFree (now including the water check the old move lacked),
	-- ignoring the building's own model in the overlap test.
	local pivot, reason = ServicePlacement.prepareFree(fp, pivotIn, b.model)
	if not pivot then return false, reason end
	if spec.shore and not ServicePlacement.touchesWater(pivot, fp, SHORE_MARGIN) then
		return false, "it has to stand on the shore, touching water"
	end
	if _powerService and _powerService.spacingBlockedAt(b.key, pivot.Position, b.id) then
		return false, "too close to another " .. spec.name
	end

	-- Release the old footprint, claim the new one.
	pcall(TerrainPadService.unpadFootprint, "svc:" .. b.id)

	b.model:PivotTo(pivot)
	b.cf = pivot
	b.entrance = (pivot * CFrame.new(0, 0, fp.Z * 0.5 + 4)).Position
	pcall(TerrainPadService.padFootprint, "svc:" .. b.id, pivot, fp.X, fp.Z, pivot.Position.Y)
	if _coverageService and spec.pollution and spec.pollution > 0 then
		_coverageService.setSource("svc:" .. b.id, pivot.Position, spec.pollution, 0, spec.pollutionRadius or 48, 0)
	end
	return true
end

function EmergencyService.clear()
	for id, b in _buildings do
		releaseBuilding(b)
		_buildings[id] = nil
	end
	_nextId = 0
end

function EmergencyService.list(): { Building }
	local out: { Building } = {}
	for _, b in _buildings do table.insert(out, b) end
	return out
end

-- Coverage domain -> funding category. Higher funding for that category widens the radius.
local FUND_CATEGORY: { [string]: string } = {
	Hospital = "Health", Police = "Police", Fire = "Fire",
	Power = "Power", Water = "Water", Sewage = "Sewage", -- no funding sliders yet -> default 1
}
local function fundingMult(kind: string): number
	if _economyService and _economyService.getFunding then
		return _economyService.getFunding(FUND_CATEGORY[kind] or kind)
	end
	return 1
end

-- True if any building of coverage domain `kind` ("Hospital"|"Police"|"Fire") covers `pos`
-- (its centre within its coverage radius of pos). The effective radius scales with the
-- category's funding level.
function EmergencyService.coversAt(pos: Vector3, kind: string): boolean
	local reach = fundingMult(kind)
	for _, b in _buildings do
		if b.kind == kind and b.model.Parent ~= nil and flatDist(b.cf.Position, pos) <= b.radius * reach then
			return true
		end
	end
	return false
end

-- True once at least one building of coverage domain `kind` stands. Lets coverage consumers
-- tell "this service does not exist in the city yet" from "this spot lies outside it".
function EmergencyService.hasKind(kind: string): boolean
	for _, b in _buildings do
		if b.kind == kind and b.model.Parent ~= nil then return true end
	end
	return false
end

-- City-wide coverage as a fraction (0..1) of POPULATED residential buildings within reach of
-- each service. Returns 1 for an empty city so nothing is penalised before anyone moves in.
-- Mirrors EducationService.getStats().coverage. Read by CityStatsService for happiness/demand.
function EmergencyService.getStats(): { [string]: number }
	local homes = 0
	local covered = { Hospital = 0, Police = 0, Fire = 0, Power = 0, Water = 0, Sewage = 0 }
	if _buildingService and _buildingService.listBuildings then
		for _, view in _buildingService.listBuildings() do
			if view.zone ~= "Residential" then continue end
			local residents = tonumber(view.residents) or 0
			if residents <= 0 then continue end
			local pos = view.position or (_buildingService.getBuildingPosition and _buildingService.getBuildingPosition(view.bpId))
			if typeof(pos) ~= "Vector3" then continue end
			homes += 1
			for kind in covered do
				if EmergencyService.coversAt(pos, kind) then covered[kind] += 1 end
			end
		end
	end
	if homes <= 0 then
		return { health = 1, police = 1, fire = 1, power = 1, water = 1, sewage = 1, homes = 0 }
	end
	return {
		health = covered.Hospital / homes,
		police = covered.Police / homes,
		fire   = covered.Fire / homes,
		power  = covered.Power / homes,
		water  = covered.Water / homes,
		sewage = covered.Sewage / homes,
		homes  = homes,
	}
end

-- Sum of build costs of all placed emergency buildings. CityEconomyService applies
-- the upkeep fraction; kept here so EmergencyService owns its own asset accounting.
function EmergencyService.getServiceCostTotal(): number
	local total = 0
	for _, b in _buildings do
		local spec = ServiceTypes.get(b.key)
		if spec then total += spec.cost end
	end
	return total
end

-- Build-cost basis split by coverage kind (Hospital/Police/Fire) so CityEconomyService
-- can apply the upkeep fraction + per-category funding.
-- Service buildings that employ staff, shaped like a BuildingService view so
-- CitizenService can treat them as workplaces beside the zoned ones. They are not plot
-- buildings and have no kerb record, so each carries its own entrance as `kerb`.
function EmergencyService.getWorkplaceViews(): { any }
	local out: { any } = {}
	for id, b in _buildings do
		local spec = ServiceTypes.get(b.key)
		local jobs = spec and tonumber((spec :: any).jobs) or nil
		if jobs and jobs > 0 then
			table.insert(out, {
				bpId = "svc:" .. tostring(id),
				zone = "Service",
				level = 1,
				jobs = jobs,
				abandoned = false,
				powered = true,
				fill = 0,
				kerb = b.entrance,
				position = b.cf.Position,
			})
		end
	end
	return out
end

function EmergencyService.getServiceCostByKind(): { [string]: number }
	local out = { Hospital = 0, Police = 0, Fire = 0 }
	for _, b in _buildings do
		local spec = ServiceTypes.get(b.key)
		if spec then out[b.kind] = (out[b.kind] or 0) + spec.cost end
	end
	return out
end

function EmergencyService.serialize(): { [string]: any }
	local out: { any } = {}
	for _, b in _buildings do
		table.insert(out, {
			id = b.id, key = b.key,
			pivot = Quant.packPivot(b.cf),
			ent = { b.entrance.X, b.entrance.Y, b.entrance.Z },
		})
	end
	return { version = 1, nextId = _nextId, buildings = out }
end

function EmergencyService.restore(data: any)
	EmergencyService.clear()
	if typeof(data) ~= "table" then return end
	local rows = if typeof(data.buildings) == "table" then data.buildings else data
	_nextId = math.max(0, math.floor(tonumber(data.nextId) or 0))
	local usedIds: { [number]: boolean } = {}

	for _, row in rows do
		if typeof(row) ~= "table" or typeof(row.key) ~= "string" or not ServiceTypes.get(row.key) then continue end

		local pivot = Quant.unpackPivot(row.pivot)
		if not pivot then continue end

		local e = row.ent
		local entrance = if typeof(e) == "table" and #e == 3
			then Vector3.new(tonumber(e[1]) or 0, tonumber(e[2]) or 0, tonumber(e[3]) or 0)
			else pivot.Position

		local id = math.floor(tonumber(row.id) or 0)
		if id <= 0 or usedIds[id] then _nextId += 1; id = _nextId end
		usedIds[id] = true
		_nextId = math.max(_nextId, id)
		spawn(id, row.key, pivot, entrance)
	end
end

-- == Lifecycle =================================================================
local function canEdit(player: Player): boolean
	if Workspace:GetAttribute("RoadEditOpen") == true then return true end
	return NetMiddleware.GetCachedAttribute(player, "CanEditRoads") == true
end

function EmergencyService.Init(net: any, buildingService: any, economyService: any, coverageService: any?)
	assert(net, "[EmergencyService] missing net")
	assert(buildingService, "[EmergencyService] missing buildingService")
	_net = net
	_buildingService = buildingService
	_economyService = economyService
	_coverageService = coverageService
	_folder = ensureFolder()
end

function EmergencyService.Bind()
	_net.RequestPlaceService.OnServerEvent:Connect(function(player: Player, kind: any, key: any, payload: any)
		if kind ~= "Emergency" and kind ~= "EmergencyFree" then return end
		if not canEdit(player) then return end
		local now = os.clock()
		if now - (_lastPlaceAt[player] or 0) < PLACE_COOLDOWN then return end
		_lastPlaceAt[player] = now
		if typeof(key) ~= "string" then return end
		-- Power poles share this card and this remote, but PowerService owns them.
		local requested = ServiceTypes.get(key)
		if requested and requested.kind == "PowerLine" then return end
		if typeof(payload) ~= "CFrame" then return end
		local ok, reason = EmergencyService.placeFree(key, payload, player)
		if not ok and reason then
			_net.Notify:FireClient(player, { text = "Can't place: " .. reason, kind = "danger", duration = 3 })
		end
	end)
	_net.RequestRemoveService.OnServerEvent:Connect(function(player: Player, kind: any, id: any)
		if kind ~= "Emergency" then return end
		if not canEdit(player) then return end
		if typeof(id) ~= "number" then return end
		EmergencyService.remove(id)
	end)
	_net.RequestMoveService.OnServerEvent:Connect(function(player: Player, kind: any, id: any, pivot: any)
		if kind ~= "Emergency" then return end
		if not canEdit(player) then return end
		local now = os.clock()
		if now - (_lastPlaceAt[player] or 0) < PLACE_COOLDOWN then return end
		_lastPlaceAt[player] = now
		if typeof(id) ~= "number" or typeof(pivot) ~= "CFrame" then return end
		EmergencyService.move(id, pivot)
	end)
	Players.PlayerRemoving:Connect(function(p) _lastPlaceAt[p] = nil end)
end

function EmergencyService.Start() end

return EmergencyService
