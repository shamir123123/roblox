--!strict
-- EducationService
-- Owns the Education service buildings: player-placed elementary schools, high schools and
-- universities. Builds + tags the school models, answers "nearest school for a pupil of
-- age N" for the citizen sim, and serialises the placed schools so they survive a reload.
-- One domain: school buildings. It does NOT own pupils -- CitizenService asks it where to
-- send children.

local CollectionService = game:GetService("CollectionService")
local Workspace         = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SchoolTypes = require(ReplicatedStorage.City.SchoolTypes)
local SchoolModel = require(ReplicatedStorage.City.SchoolModel)
local Quant = require(ReplicatedStorage.Shared.Quant)
local NetMiddleware = require(ReplicatedStorage:WaitForChild("NetMiddleware"))
local TerrainPadService = require(game:GetService("ServerScriptService").Services.Terrain.TerrainPadService)
local ServicePlacement = require(game:GetService("ServerScriptService").Services.City.ServicePlacement)

local EducationService = {}

local SCHOOL_TAG  = "School"
local PLACE_COOLDOWN = 0.15

type School = {
	id: number,
	key: string,
	category: string,
	cf: CFrame,
	entrance: Vector3,
	ageMin: number,
	ageMax: number,
	eduTier: number,
	capacity: number,
	enrolled: number,
	radius: number,
	model: Model,
}

local _net: any
local _buildingService: any
local _economyService: any
local _isPlaceableAllowed: ((string) -> boolean)?
local _folder: Folder
local _schools: { [number]: School } = {}
local _nextId = 0
local _lastPlaceAt: { [Player]: number } = {}
local _eligiblePupils = 0
local _assignedPupils = 0

local function ensureFolder(): Folder
	local city = Workspace:FindFirstChild("_City")
	if not city then city = Instance.new("Folder"); city.Name = "_City"; city.Parent = Workspace end
	local f = city:FindFirstChild("Schools")
	if not f or not f:IsA("Folder") then
		if f then f:Destroy() end
		f = Instance.new("Folder"); f.Name = "Schools"; f.Parent = city
	end
	return f :: Folder
end

local function flatDist(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- Development Tree gate (ProgressionService.isPlaceableAllowed), injected by Bootstrap.
-- The client hiding a locked card is presentation; THIS is the rule.
function EducationService.setUnlockCheck(fn: ((string) -> boolean)?)
	_isPlaceableAllowed = fn
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
function EducationService.setTerritoryCheck(fn: ((Vector3, number, number) -> boolean)?)
	_territoryCheck = fn
end

local function refreshModelStats(s: School)
	if not s.model or not s.model.Parent then return end
	s.model:SetAttribute("Occupants", s.enrolled)
	s.model:SetAttribute("Capacity", s.capacity)
	s.model:SetAttribute("OccupantKind", "pupils")
end

-- Build + register one building. Internal: trusts its inputs (validation is in `place`).
local function spawn(id: number, key: string, pivot: CFrame, entrance: Vector3): School?
	local spec = SchoolTypes.get(key)
	if not spec then return nil end
	local model = SchoolModel.build(key, false)
	if not model then return nil end
	model:PivotTo(pivot)
	model:SetAttribute("SchoolId", id)
	model:SetAttribute("SchoolType", key)
	model:SetAttribute("Category", spec.category)
	model:SetAttribute("AgeMin", spec.ageMin)
	model:SetAttribute("AgeMax", spec.ageMax)
	model:SetAttribute("ServiceName", spec.name)
	model:SetAttribute("Capacity", spec.capacity)
	model:SetAttribute("CoverageRadius", spec.coverageRadius)
	model:SetAttribute("Occupants", 0)
	model:SetAttribute("OccupantKind", "pupils")
	CollectionService:AddTag(model, SCHOOL_TAG)
	model.Parent = _folder

	-- Flatten the terrain under the building footprint.
	local fp = SchoolTypes.footprintStuds(spec)
	pcall(TerrainPadService.padFootprint, "edu:" .. id, pivot, fp.X, fp.Z, pivot.Position.Y)

	local school: School = {
		id = id, key = key, category = spec.category, cf = pivot, entrance = entrance,
		ageMin = spec.ageMin, ageMax = spec.ageMax, eduTier = spec.eduTier,
		capacity = spec.capacity, enrolled = 0, radius = spec.coverageRadius,
		model = model,
	}
	_schools[id] = school
	refreshModelStats(school)
	return school
end

-- == Public ====================================================================
-- Placement: anywhere on the map. The client sends a pivot; the server keeps only its
-- X/Z + yaw, re-grounds Y on the authoritative terrain, and rejects overlaps with
-- anything already standing in the city. Mirrors EmergencyService.placeFree.
-- `actor` only decides who gets the cost tag and the build sound back -- see
-- RoadReplicationService.broadcastPlacementCharged. The building itself is city state and
-- replicates to everyone regardless.
function EducationService.placeFree(key: string, pivotIn: CFrame, actor: Player?): (boolean, string?)
	local spec = SchoolTypes.get(key)
	if not spec then return false, "unknown building" end
	if not isUnlocked(key) then return false, spec.name .. " is not unlocked yet" end

	local fp = SchoolTypes.footprintStuds(spec)
	local pivot, reason = ServicePlacement.prepareFree(fp, pivotIn)
	if not pivot then return false, reason end

	-- After prepareFree, so the land test sees where the building actually lands.
	if not isOnOwnedLand(pivot.Position, fp.X * 0.5, fp.Z * 0.5) then
		return false, "you do not own this land"
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

-- Sum of build costs of all placed schools. CityEconomyService applies the upkeep
-- fraction; kept here so EducationService owns its own asset accounting.
function EducationService.getServiceCostTotal(): number
	local total = 0
	for _, s in _schools do
		local spec = SchoolTypes.get(s.key)
		if spec then total += spec.cost end
	end
	return total
end

local function releaseSchool(s: School)
	pcall(TerrainPadService.unpadFootprint, "edu:" .. s.id)
	if s.model and s.model.Parent then s.model:Destroy() end
end

function EducationService.remove(id: number)
	local s = _schools[id]
	if not s then return end
	releaseSchool(s)
	_schools[id] = nil
end

function EducationService.clear()
	for id, s in _schools do
		releaseSchool(s)
		_schools[id] = nil
	end
	_nextId = 0
end

function EducationService.list(): { School }
	local out: { School } = {}
	for _, s in _schools do table.insert(out, s) end
	return out
end

local function schoolServes(s: School?, age: number): boolean
	return s ~= nil and s.model.Parent ~= nil and age >= s.ageMin and age <= s.ageMax
end

-- Education funding scales effective seat count (more funding -> more capacity).
local function effCapacity(s: School): number
	local mult = if _economyService and _economyService.getFunding then _economyService.getFunding("Education") else 1
	return math.floor(s.capacity * mult + 0.5)
end

-- Nearest school that serves a pupil of `age`, as its entrance point. nil = none yet.
-- `currentId` preserves a child's assigned school while it still serves their age band.
function EducationService.getNearestSchool(pos: Vector3, age: number, currentId: number?): (Vector3?, number?)
	local current = if currentId then _schools[currentId] else nil
	if schoolServes(current, age) then
		return (current :: School).entrance, currentId
	end

	-- Hybrid eligibility: the pupil's home must lie within the school's coverage radius to be
	-- served at all. Of the schools in range with a free seat, pick the nearest.
	local bestPos: Vector3? = nil
	local bestId: number? = nil
	local bestD = math.huge
	for id, s in _schools do
		if schoolServes(s, age) and s.enrolled < effCapacity(s) and flatDist(s.cf.Position, pos) <= s.radius then
			local d = flatDist(s.entrance, pos)
			if d < bestD then bestD = d; bestPos = s.entrance; bestId = id end
		end
	end
	return bestPos, bestId
end

function EducationService.hasSchool(id: number?, age: number?): boolean
	if not id then return false end
	local s = _schools[id]
	if not s or not s.model.Parent then return false end
	return age == nil or (age >= s.ageMin and age <= s.ageMax)
end

-- The education tier a school grants (1 Educated / 2 Well / 3 Highly; 0 = Library, none).
function EducationService.getSchoolTier(id: number?): number
	local s = if id then _schools[id] else nil
	return if s then s.eduTier else 0
end

-- True if any school of exactly `tier` covers `pos` (its centre within its radius). The
-- citizen sim uses this to grant a university (tier 3) diploma to a high-school graduate.
function EducationService.coversTier(pos: Vector3, tier: number): boolean
	for _, s in _schools do
		if s.eduTier == tier and flatDist(s.cf.Position, pos) <= s.radius then
			return true
		end
	end
	return false
end

function EducationService.enterSchool(id: number?)
	if not id then return end
	local s = _schools[id]
	if not s or not s.model.Parent then return end
	s.enrolled = math.clamp(s.enrolled + 1, 0, effCapacity(s))
	refreshModelStats(s)
end

function EducationService.leaveSchool(id: number?)
	if not id then return end
	local s = _schools[id]
	if not s or not s.model.Parent then return end
	s.enrolled = math.max(0, s.enrolled - 1)
	refreshModelStats(s)
end

function EducationService.setPupilDemand(eligible: number, assigned: number)
	_eligiblePupils = math.max(0, math.floor(tonumber(eligible) or 0))
	_assignedPupils = math.clamp(math.floor(tonumber(assigned) or 0), 0, _eligiblePupils)
end

function EducationService.getStats(): { [string]: number }
	local capacity = 0
	local attending = 0
	for _, s in _schools do
		capacity += effCapacity(s)
		attending += s.enrolled
	end
	local coverage = if _eligiblePupils > 0 then _assignedPupils / _eligiblePupils else 1
	local utilization = if capacity > 0 then attending / capacity else 0
	return {
		eligible = _eligiblePupils,
		assigned = _assignedPupils,
		attending = attending,
		capacity = capacity,
		coverage = math.clamp(coverage, 0, 1),
		utilization = math.clamp(utilization, 0, 1),
	}
end

function EducationService.serialize(): { [string]: any }
	local out: { any } = {}
	for _, s in _schools do
		table.insert(out, {
			id = s.id, key = s.key,
			pivot = Quant.packPivot(s.cf),
			ent = { s.entrance.X, s.entrance.Y, s.entrance.Z },
		})
	end
	return { version = 2, nextId = _nextId, schools = out }
end

function EducationService.restore(data: any)
	EducationService.clear()
	if typeof(data) ~= "table" then return end
	local rows = if typeof(data.schools) == "table" then data.schools else data
	_nextId = math.max(0, math.floor(tonumber(data.nextId) or 0))
	local usedIds: { [number]: boolean } = {}

	for _, row in rows do
		if typeof(row) ~= "table" or typeof(row.key) ~= "string" or not SchoolTypes.get(row.key) then continue end

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

function EducationService.Init(net: any, buildingService: any, economyService: any?)
	assert(net, "[EducationService] missing net")
	assert(buildingService, "[EducationService] missing buildingService")
	_net = net
	_buildingService = buildingService
	_economyService = economyService
	_folder = ensureFolder()
end

-- Move tool: relocate an already-placed school. X/Z + yaw kept, Y re-grounded,
-- free of charge, id/enrolment kept. The old terrain pad releases, the new one is
-- claimed. Mirrors EmergencyService.move.
function EducationService.move(id: number, pivotIn: CFrame): (boolean, string?)
	local s = _schools[id]
	if not s then return false, "no such school" end
	local spec = SchoolTypes.get(s.key)
	if not spec then return false, "unknown school" end

	local fp = SchoolTypes.footprintStuds(spec)
	local pivot, reason = ServicePlacement.prepareFree(fp, pivotIn, s.model)
	if not pivot then return false, reason end

	pcall(TerrainPadService.unpadFootprint, "edu:" .. s.id)

	s.model:PivotTo(pivot)
	s.cf = pivot
	s.entrance = (pivot * CFrame.new(0, 0, fp.Z * 0.5 + 4)).Position
	pcall(TerrainPadService.padFootprint, "edu:" .. s.id, pivot, fp.X, fp.Z, pivot.Position.Y)
	return true
end

function EducationService.Bind()
	_net.RequestPlaceService.OnServerEvent:Connect(function(player: Player, kind: any, key: any, pivot: any)
		if kind ~= "Education" then return end
		if not canEdit(player) then return end
		local now = os.clock()
		if now - (_lastPlaceAt[player] or 0) < PLACE_COOLDOWN then return end
		_lastPlaceAt[player] = now
		if typeof(key) ~= "string" or typeof(pivot) ~= "CFrame" then return end
		local ok, reason = EducationService.placeFree(key, pivot, player)
		if not ok and reason then
			_net.Notify:FireClient(player, { text = "Can't place: " .. reason, kind = "danger", duration = 3 })
		end
	end)
	_net.RequestRemoveService.OnServerEvent:Connect(function(player: Player, kind: any, id: any)
		if kind ~= "Education" then return end
		if not canEdit(player) then return end
		if typeof(id) ~= "number" then return end
		EducationService.remove(id)
	end)
	_net.RequestMoveService.OnServerEvent:Connect(function(player: Player, kind: any, id: any, pivot: any)
		if kind ~= "Education" then return end
		if not canEdit(player) then return end
		local now = os.clock()
		if now - (_lastPlaceAt[player] or 0) < PLACE_COOLDOWN then return end
		_lastPlaceAt[player] = now
		if typeof(id) ~= "number" or typeof(pivot) ~= "CFrame" then return end
		EducationService.move(id, pivot)
	end)
	game:GetService("Players").PlayerRemoving:Connect(function(p) _lastPlaceAt[p] = nil end)
end

function EducationService.Start() end

return EducationService
