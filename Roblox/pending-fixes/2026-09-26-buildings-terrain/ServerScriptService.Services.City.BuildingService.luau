--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ZoneTypes = require(ReplicatedStorage.City.ZoneTypes)
local WorldThemeCatalog = require(ReplicatedStorage.World.WorldThemeCatalog)
local ZoneGrid = require(ReplicatedStorage.City.ZoneGrid)
local Quant = require(ReplicatedStorage.Shared.Quant)
local Const = require(script.Parent.CitySimConstants)

local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService    = game:GetService("RunService")
local TweenService  = game:GetService("TweenService")
local Workspace     = game:GetService("Workspace")
local Players       = game:GetService("Players")

local GameSpeed = require(ReplicatedStorage:WaitForChild("GameSpeed"))
local NetMiddleware = require(ReplicatedStorage:WaitForChild("NetMiddleware"))

local TerrainPadService = require(ServerScriptService.Services.Terrain.TerrainPadService)
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
-- "Is this seat under the new pavement?" -- the geometry only, so the road ghost can ask
-- the identical question of the models it can see and highlight exactly what comes down.
local PlacementFit = require(ReplicatedStorage.Shared.PlacementFit)

local BuildingService = {}

local LOT_SIZE = ZoneGrid.LOT_SIZE -- authoritative lot spacing; scales with ZoneGrid.WORLD_SCALE

local _coverageService: any
local _dressingService: any
local _cityStats: any
local _bldgFolder: Folder
local _constructionRemote: RemoteEvent?
local _demolishRemote: RemoteEvent?
local _rng = Random.new()

local DEMOLISH_COOLDOWN = 0.1
local _lastDemolishAt: { [Player]: number } = {}

local _templateFolderCache: { [string]: Folder | false } = {}

local _tweenQuadOut   = TweenInfo.new(1, Enum.EasingStyle.Quad,  Enum.EasingDirection.Out)
local _tweenBackOut   = TweenInfo.new(1, Enum.EasingStyle.Back,  Enum.EasingDirection.Out)
local _tweenSineInOut = TweenInfo.new(1, Enum.EasingStyle.Sine,  Enum.EasingDirection.InOut)
local _tweenQuadInOut = TweenInfo.new(1, Enum.EasingStyle.Quad,  Enum.EasingDirection.InOut)

local function makeTweenInfo(seconds: number, base: TweenInfo): TweenInfo
	return TweenInfo.new(
		seconds,
		base.EasingStyle,
		base.EasingDirection
	)
end

type BuildingRecord = {
	blueprintId    : string,
	model          : Model,
	zone           : string,
	width          : number,
	depth          : number,
	padWidth       : number,
	padDepth       : number,
	-- The plot's REAL frontage in studs. padWidth is max(frontage, w*LOT) for the
	-- terrain pad, which loses it -- and lot dressing needs the true one, because
	-- PlotGeometry.fitLots ROUNDS, so w*LOT can overstate the plot by half a lot.
	plotWidth      : number?,
	segmentId      : number?,
	groupFill      : number,
	level          : number,
	residents      : number,
	households     : number,
	abandoned      : boolean,
	powered        : boolean,
	watered        : boolean?, -- nil until WaterService's first pass; nil reads as served
	drained        : boolean?,
	saveKey        : string,
	plotPivot      : CFrame,
	density        : string?, -- "Medium" = mid-rise block; nil = houses
	maxHouseholds  : number?, -- a mid-rise model's own flat count (template MaxHouseholds)
}

local _buildings: { [string]: BuildingRecord } = {}
local _nextBlueprintId = 0

-- Sim state from the save blob, keyed by saveKey, consumed as PlotService.restore
-- redevelops each plot. Buildings themselves are derived from the plot groups.
type SavedState = { lv: number, f: number, r: number, a: boolean, tn: string? }
local _restoreState: { [string]: SavedState } = {}

-- Reserved plot-building footprints (oriented boxes on XZ), keyed by building id. Used so a plot
-- that would cross a plot on ANOTHER road (the inside of a junction) is skipped -- houses wrap the
-- bend without overlapping. Reserved the moment developPlot starts (before the async crane) so two
-- growing corner plots can't both claim the spot; freed on demolish / cancel.
type PlotBox = { p: Vector3, a1: Vector3, a2: Vector3, hw: number, hd: number, seg: number }
local _plotFootprints: { [string]: PlotBox } = {}

local MAX_LEVEL         = 3

-- How many FAMILIES a home fits: the lot's footprint picks the row of
-- HOUSEHOLDS_BY_LEVEL and the level picks the column, so SIZE sets the ceiling (a small
-- lot is stuck at one household however far it levels, a large one reaches five) and
-- levelling walks up to it. Levelling still buys room -- what it no longer does is swap
-- the model out from under the player (see upgradeGroup).
local function householdCapFor(rec: BuildingRecord): number
	-- A block's flats are counted in the model itself (plan area x storeys), not the house ladder.
	if rec.maxHouseholds then return rec.maxHouseholds end
	local area = (rec.width or 0) * (rec.depth or 0)
	local tier = if area >= Const.HOUSEHOLDS_LARGE_AREA then 3
		elseif area >= Const.HOUSEHOLDS_MEDIUM_AREA then 2
		else 1
	return Const.HOUSEHOLDS_BY_LEVEL[tier][math.clamp(rec.level or 1, 1, MAX_LEVEL)]
end

-- Headcount ceiling: FAMILY_MAX people per household slot.
local function residentCapFor(rec: BuildingRecord): number
	return householdCapFor(rec) * Const.FAMILY_MAX
end

local MIN_CONSTRUCTION_DURATION = 7
-- How long a building takes to go up, in GAME-seconds (it holds at pause and runs at 2x/3x).
-- It scales with the footprint the way real builds do -- a trailer goes up quicker than a
-- shop -- but stays short enough that a street zoned now is lived in within the minute.
-- It was a flat 8.4 s for everything.
local BUILD_BASE_SECS     = 18
local BUILD_SECS_PER_LOT  = 1.5 -- per lot of footprint area: a 3x3 house takes ~32 s
local BUILD_MAX_SECS      = 60
local BUILD_ZONE_FACTOR: { [string]: number } = { Residential = 1, Commercial = 1.2, Industrial = 1.3 }
local BUILD_MEDIUM_FACTOR = 1.4 -- mid-rise blocks have more storeys to put up
-- Earthworks: a claimed site is graded in steps before anything goes up, so the ground visibly
-- settles into the pad (cut on the uphill side, filled on the downhill side) instead of
-- snapping flat. Each step is a fraction of the way from the old ground to the finished pad.
local EARTHWORK_STAGES    = { 0.25, 0.5, 0.75, 1 }
local EARTHWORK_STEP_SECS = 0.9
-- Construction sites carry the same utility badges as finished buildings (NoPowerView), so a
-- player sees a street is off the grid while it is still going up, not after it moves in.
local SITE_UTILITY_POLL   = 2 -- real seconds between re-checks of every site
local PLACE_DELAY_MIN    = 4
local PLACE_DELAY_MAX    = 9

-- A claimed lot shows a nest, then waits a demand-scaled dwell before the crane build:
-- demand sets construction SPEED, it never hard-blocks (a zero-demand city still builds,
-- just slowly), so zoning can always bootstrap the demand loop.
local DEMAND_POLL_SECS       = 1.5  -- game-seconds between demand re-checks while a nest waits
local MIN_NEST_DWELL         = 2.0  -- nest is always visible at least this long before building
local NEST_DWELL_RANGE       = 20   -- extra game-seconds at demand -1; none at DEMAND_FAST (was 180: a street zoned against the bar sat as nests for minutes)
local DEMAND_FAST            = 0.25 -- demand at/above this builds right after MIN_NEST_DWELL

local _activeConstruction: { [string]: { siteId: string, cancelled: boolean, zone: string? } } = {}

local function ensureFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then return existing end
	if existing then existing:Destroy() end

	local f = Instance.new("Folder")
	f.Name, f.Parent = name, parent
	return f
end

-- Wait `gameSeconds` of GAME time, scaled by GameSpeed: frozen at pause (0), faster at
-- 2x/3x -- so construction + the placement drip stop and speed up with the rest of the
-- sim instead of running in real time. Bails early (returns false) if `shouldCancel` trips.
local function waitGameSeconds(gameSeconds: number, shouldCancel: (() -> boolean)?): boolean
	local elapsed = 0
	while elapsed < gameSeconds do
		local dt = RunService.Heartbeat:Wait()
		if shouldCancel and shouldCancel() then return false end
		elapsed += dt * GameSpeed.get()
	end
	return true
end

local function newBlueprintId(): string
	_nextBlueprintId += 1
	return "BP_" .. tostring(_nextBlueprintId)
end

local function roundedCoord(n: number): number
	return if n >= 0 then math.floor(n + 0.5) else math.ceil(n - 0.5)
end

-- Citizens reference their home/job across saves by this key, so it must be stable:
-- the plot pivot is, because PlotService re-plans each group deterministically from the
-- same road geometry.
local function saveKeyForPivot(zone: string, width: number, depth: number, pivot: CFrame): string
	return zone .. "|" .. tostring(width) .. "x" .. tostring(depth) .. "|"
		.. tostring(roundedCoord(pivot.Position.X)) .. "," .. tostring(roundedCoord(pivot.Position.Z))
end

-- The architecture pack the active world theme asks for, e.g. "NorthAmerican". Templates
-- may be organised either way:
--
--     Templates.Buildings.<Style>.<Zone>.<WxD>.<Model>   -- themed
--     Templates.Buildings.<Zone>.<WxD>.<Model>           -- un-themed (the original layout)
--
-- styleRoot() returns the themed folder when it exists and the plain Buildings folder when
-- it does not, so a theme may name a pack nobody has modelled yet and every existing
-- template keeps working untouched. This is also the seam a per-district style override
-- (Cities: Skylines' District Styles) would use -- pass the district's style instead of
-- the theme's and the rest of the lookup is unchanged.
local function styleRoot(buildings: Folder): (Instance, string)
	local styleName = WorldThemeCatalog.active().architectureStyle
	if styleName then
		local styled = buildings:FindFirstChild(styleName)
		if styled and styled:IsA("Folder") then
			return styled, styleName
		end
	end
	return buildings, ""
end

-- Houses are real size, so a plot size can have no stock of its own (nothing fits 2 lots
-- wide; a deep plot has no house that deep). Take the biggest house that fits the plot;
-- on a plot narrower than every house (2-lot plots in old saves) the one overhanging least.
local function nearestHouseFolder(zoneFolder: Instance, width: number, depth: number): Instance?
	local best: Instance?, bestScore = nil, -math.huge
	for _, f in zoneFolder:GetChildren() do
		local w, d = string.match(f.Name, "^(%d+)x(%d+)$")
		if not (w and d and f:IsA("Folder")) then continue end
		local fw, fd = tonumber(w) :: number, tonumber(d) :: number
		local score = fw * fd - 100 * (math.max(fw - width, 0) + math.max(fd - depth, 0))
		if score > bestScore then best, bestScore = f, score end
	end
	return best
end

local function getTemplateFolder(zone: string, width: number, depth: number, level: number?, density: string?): Folder?
	local lvl = level or 1
	-- The style is part of the cache key: two themes' "Residential 3x3" are different folders.
	local cacheKey = WorldThemeCatalog.ACTIVE_ID .. "|" .. zone .. "|" .. (density or "") .. "|" .. tostring(width) .. "x" .. tostring(depth) .. "|" .. tostring(lvl)
	local cached = _templateFolderCache[cacheKey]
	if cached ~= nil then
		return if cached then cached :: Folder else nil
	end

	local templates = ServerStorage:FindFirstChild("Templates")
	if not templates then _templateFolderCache[cacheKey] = false; return nil end

	local buildings = templates:FindFirstChild("Buildings")
	if not buildings then _templateFolderCache[cacheKey] = false; return nil end

	if not ZoneTypes.isValid(zone) then _templateFolderCache[cacheKey] = false; return nil end

	local templateFolderName = if density == "Medium" and zone == "Residential" then "ResidentialMedium"
		else ZoneTypes.getTemplateFolder(zone :: ZoneTypes.ZoneName)
	if not templateFolderName then _templateFolderCache[cacheKey] = false; return nil end

	local root = styleRoot(buildings)
	local zoneFolder = root:FindFirstChild(templateFolderName)
	-- A themed pack that is missing this zone falls back to the un-themed set rather than
	-- leaving the plot empty -- a half-built style still produces a city.
	if not zoneFolder and root ~= buildings then
		zoneFolder = buildings:FindFirstChild(templateFolderName)
	end
	if not zoneFolder then _templateFolderCache[cacheKey] = false; return nil end

	local sizeFolder = zoneFolder:FindFirstChild(tostring(width) .. "x" .. tostring(depth))
	if not sizeFolder and templateFolderName == "Residential" then sizeFolder = nearestHouseFolder(zoneFolder, width, depth) end
	if not sizeFolder or not sizeFolder:IsA("Folder") then _templateFolderCache[cacheKey] = false; return nil end

	local result: Folder? = nil

	if lvl > 1 then
		local levelFolder = sizeFolder:FindFirstChild("Level" .. tostring(lvl))
		if levelFolder and levelFolder:IsA("Folder") then
			for _, child in levelFolder:GetChildren() do
				if child:IsA("Model") then result = levelFolder :: Folder; break end
			end
		end
	end

	if not result then
		for _, child in sizeFolder:GetChildren() do
			if child:IsA("Model") then result = sizeFolder :: Folder; break end
		end
	end

	_templateFolderCache[cacheKey] = result or false
	return result
end

local function pickTemplate(folder: Folder): Model
	local models: { Model } = {}

	for _, child in folder:GetChildren() do
		if child:IsA("Model") then
			table.insert(models, child :: Model)
		end
	end

	return models[_rng:NextInteger(1, #models)]
end

-- Forward decls so developPlot (above both definitions) can resolve a chosen template by
-- name and re-tint a building restored in the abandoned state.
local findTemplateByName: (folder: Folder, name: any) -> Model?
local setAbandonedTint: (model: Model) -> ()

-- Every building is a burgage plot now, so its pivot is the one PlotService seated it at.
local function recordPivot(rec: BuildingRecord): CFrame?
	return rec.plotPivot
end

-- Industrial buildings are pollution + noise sources. Keep CoverageService in
-- sync with the building's current state (level, abandoned, existence).
local function refreshIndustrialSource(bpId: string)
	if not _coverageService then return end

	local rec = _buildings[bpId]
	if not rec or rec.zone ~= "Industrial" or rec.abandoned then
		_coverageService.removeSource(bpId)
		return
	end

	local pivot = recordPivot(rec)
	if not pivot then
		_coverageService.removeSource(bpId)
		return
	end

	local lvl = math.clamp(rec.level, 1, MAX_LEVEL)
	_coverageService.setSource(
		bpId,
		pivot.Position,
		Const.INDUSTRIAL_POLLUTION[lvl],
		Const.INDUSTRIAL_NOISE[lvl],
		Const.INDUSTRIAL_POLLUTION_RADIUS,
		Const.INDUSTRIAL_NOISE_RADIUS
	)
end

local finishConstructionVisual: (string) -> ()

-- Game-seconds a building of this zone and footprint (lots) takes to build.
local function constructionSeconds(zone: string, w: number, d: number, density: string?): number
	local secs = (BUILD_BASE_SECS + BUILD_SECS_PER_LOT * w * d) * (BUILD_ZONE_FACTOR[zone] or 1.2)
	if density == "Medium" then secs *= BUILD_MEDIUM_FACTOR end
	return math.clamp(secs, MIN_CONSTRUCTION_DURATION, BUILD_MAX_SECS)
end

local function playConstructionAnimation(blueprintId: string, pivot: CFrame, width: number, depth: number, onFinished: () -> (), duration: number?)
	-- Duration is in GAME-seconds (no speed division): the scaled clock below and the
	-- client animation both advance by dt*GameSpeed, so the build pauses at 0 and runs at
	-- 2x/3x, and server completion stays in lockstep with the client visual.
	local constructionDuration = math.max(MIN_CONSTRUCTION_DURATION, duration or MIN_CONSTRUCTION_DURATION)
	local active = _activeConstruction[blueprintId]
	local siteId = if active then active.siteId else blueprintId

	if _constructionRemote then
		_constructionRemote:FireAllClients({
			kind = "start",
			id = siteId,
			pivot = pivot,
			width = width,
			depth = depth,
			duration = constructionDuration,
			lotSize = LOT_SIZE,
		})
	end

	task.spawn(function()
		local finished = waitGameSeconds(constructionDuration, function()
			local cur = _activeConstruction[blueprintId]
			return not cur or cur.cancelled
		end)
		if not finished then return end
		local current = _activeConstruction[blueprintId]
		if not current or current.cancelled then
			return
		end
		_activeConstruction[blueprintId] = nil
		finishConstructionVisual(current.siteId)
		onFinished()
	end)
end

local function makeFootprint(pivot: CFrame, wStuds: number, dStuds: number, segId: number?): PlotBox
	local a1 = pivot.RightVector; a1 = Vector3.new(a1.X, 0, a1.Z)
	a1 = if a1.Magnitude < 1e-4 then Vector3.xAxis else a1.Unit
	local a2 = pivot.LookVector; a2 = Vector3.new(a2.X, 0, a2.Z)
	a2 = if a2.Magnitude < 1e-4 then Vector3.zAxis else a2.Unit
	return { p = pivot.Position, a1 = a1, a2 = a2, hw = wStuds * 0.5, hd = dStuds * 0.5, seg = segId or -1 }
end

local function placeBuilding(
	blueprintId : string,
	template    : Model,
	pivot       : CFrame,
	zone        : string,
	width       : number,
	depth       : number,
	segId       : number?,
	plotW       : number?
): Model
	local model = template:Clone()
	model.Name = zone .. "_" .. blueprintId
	model:SetAttribute("ZoneType",       zone)
	model:SetAttribute("BlueprintId",    blueprintId)
	model:SetAttribute("FootprintWidth", width)
	model:SetAttribute("FootprintDepth", depth)
	model:SetAttribute("TemplateName", template.Name)
	-- The LOT, not the model. Everything that judges this building's ground -- the road
	-- ghost's demolition highlight, the tree tool's "not on a building" -- needs the seat
	-- PlotService zoned, and the model's own pivot carries the template's internal offset
	-- plus whatever dressing gets parented under it afterwards. Kept in step by relocate().
	model:SetAttribute("LotPivot", pivot)

	-- Mid-rise, low-commercial and industrial templates ship three roof-plant layouts (and
	-- commercial three lot-fence layouts); keep one of each, fixed by the lot so a reload (or a
	-- level-up to the upgraded model) shows the same kind of roof and fence. Industrial names
	-- them Detail_Plant<i> / Detail_Fence<i>, and not every one of its three roof layouts bakes
	-- plant, so the pick is over the layouts (KitRoof); the kept index is recorded for
	-- LotDressingService, which seats the matching roof / gate kit props.
	for salt, kind in { "Plant", "Fence" } do
		local alts: { [Instance]: number } = {}
		local n = 0
		for _, c in model:GetChildren() do
			local i = tonumber(c.Name:match("^" .. kind .. "(%d)$") or c.Name:match("^Detail_" .. kind .. "(%d)$"))
			if i then
				alts[c] = i
				n = math.max(n, i)
			end
		end
		if kind == "Plant" and model:GetAttribute("KitRoof") then n = 3 end
		if n == 0 then continue end
		local keep = Random.new(math.floor(pivot.Position.X * 3.1 + pivot.Position.Z * 5.7) + salt - 1):NextInteger(1, if n > 1 then 3 else 1)
		for c, i in alts do
			if i ~= keep then c:Destroy() end
		end
		model:SetAttribute(kind .. "Layout", keep)
	end

	-- One body represents the building to selection and physics. Everything else is
	-- visual-only: decorative windows, trim, roof pieces, props, and authored details
	-- never need touch/query/collision participation on a city-sized map.
	local body = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanTouch = false
			descendant.CanQuery = descendant == body
			descendant.CanCollide = descendant == body
		end
	end

	model:PivotTo(CFrame.identity)

	-- Nothing rescales a building: a template is stored at exactly the size it is built
	-- (world studs, 2 per metre), so resizing one in Studio is what the city gets.

	local bbox = model:GetBoundingBox()
	local extents = model:GetExtentsSize()
	local lowestY = bbox.Position.Y - extents.Y * 0.5

	-- The plot pivot's +Z points AWAY from the road. My scripted templates author
	-- the front (door/storefront) on +Z, so flip 180 so the front faces the road.
	-- Hand-authored templates (no marker attribute) keep the legacy orientation.
	local isScripted = model:GetAttribute("HouseHalfWidth") ~= nil or model:GetAttribute("BuildingHalfWidth") ~= nil
	local faceFrame = if isScripted then pivot * CFrame.Angles(0, math.pi, 0) else pivot

	model:PivotTo(faceFrame * CFrame.new(-bbox.Position.X, -lowestY, -bbox.Position.Z))
	model.Parent = _bldgFolder

	-- Scripted lot dressing (colour variation, path, driveway, fence, backyard),
	-- using the same road-facing frame. Parented under the model, so
	-- destroyBuilding/rebuildModel clean it up. Legacy templates are not dressed.
	if _dressingService and isScripted then
		_dressingService.dress(model, faceFrame, zone, width, depth, plotW)
	end

	-- Snap the finished model (building + dressing move together) to the codec grid so
	-- its pivot reads 1-decimal position / whole-degree yaw, like every other placement.
	model:PivotTo(Quant.snapCF(model:GetPivot()))

	-- developPlot registers the footprint before the crane starts; a rebuild (upgrade,
	-- reseat) re-registers it here.
	if not _plotFootprints[blueprintId] then
		_plotFootprints[blueprintId] = makeFootprint(pivot, width * LOT_SIZE, depth * LOT_SIZE, segId)
	end

	return model
end

function finishConstructionVisual(siteId: string)
	if _constructionRemote then
		_constructionRemote:FireAllClients({ kind = "finish", id = siteId })
	end
end

-- Displayed demand for a zone's RCI key (~0.25 for an empty city's housing). Defaults to
-- 1 ("wants it") when CityStats isn't wired or has no key, so building never stalls.
local function demandForZone(zone: string): number
	if not _cityStats then return 1 end
	local key = ZoneTypes.getDemandKey(zone :: any)
	if not key then return 1 end
	local ok, d = pcall(_cityStats.getDemand)
	if not ok or typeof(d) ~= "table" then return 1 end
	local v = (d :: any)[key]
	return if typeof(v) == "number" then v else 1
end

-- The persistent scaffold "nest" the player sees the moment a lot is claimed. It holds
-- until demand triggers the crane build (kind="start" replaces it) or the lot is
-- cancelled / re-zoned (kind="finish" clears it).
local function showNest(siteId: string, pivot: CFrame, width: number, depth: number)
	if _constructionRemote then
		_constructionRemote:FireAllClients({
			kind = "nest",
			id = siteId,
			pivot = pivot,
			width = width,
			depth = depth,
			lotSize = LOT_SIZE,
		})
	end
end

-- ---- construction-site markers: the utility badges over a site ----------------------------
-- One invisible, non-colliding box per site, the size of the frame that rises on it, in
-- Workspace._City.ConstructionSites. NoPowerView watches that folder like ZonedBuildings, so
-- the badge logic (and its clustering) is the same for a site as for a finished building.
-- A utility is only checked once its service has reported on a finished building at least
-- once (setPowered / setWatered / setDrained), so a site never shows a badge a house on the
-- same spot would not.
local _siteFolder: Folder? = nil
local _siteMarkers: { [string]: Model } = {}
local _utilityLive = { power = false, water = false, sewage = false }

local function siteFolder(): Folder
	local f = _siteFolder
	if f and f.Parent then return f end
	local made = ensureFolder(ensureFolder(Workspace, "_City"), "ConstructionSites")
	_siteFolder = made
	return made
end

local function requireService(name: string): any
	local city = ServerScriptService:FindFirstChild("Services")
	city = city and city:FindFirstChild("City")
	local mod = city and city:FindFirstChild(name)
	if not mod then return nil end
	local ok, svc = pcall(require, mod)
	return if ok then svc else nil
end

local function setFlag(m: Model, attr: string, on: boolean)
	if m:GetAttribute(attr) ~= on then m:SetAttribute(attr, on) end
end

local function refreshSiteUtilities(bpId: string)
	local m = _siteMarkers[bpId]
	if not (m and m.Parent) then return end
	local pos = (m:GetAttribute("SitePos") :: Vector3?) or m:GetPivot().Position
	if _utilityLive.power then
		local power = requireService("PowerService")
		if power and power.isSuppliedAt then
			local ok, supplied = pcall(power.isSuppliedAt, pos)
			if ok then setFlag(m, "NoPower", not supplied) end
		end
	end
	if _utilityLive.water or _utilityLive.sewage then
		local water = requireService("WaterService")
		if water and water.isServedAt then
			if _utilityLive.water then
				local ok, served = pcall(water.isServedAt, pos, "Water")
				if ok then setFlag(m, "NoWater", not served) end
			end
			if _utilityLive.sewage then
				local ok, served = pcall(water.isServedAt, pos, "Sewage")
				if ok then setFlag(m, "NoSewage", not served) end
			end
		end
	end
end

local function addSiteMarker(bpId: string, pivot: CFrame, w: number, d: number)
	local h = math.clamp((w + d) * 1.45, 7, 14) -- the rising frame's height (ConstructionViewController)
	local m = Instance.new("Model")
	m.Name = "Site_" .. bpId
	local box = Instance.new("Part")
	box.Name = "SiteBounds"
	box.Anchored = true
	box.CanCollide = false
	box.CanQuery = false
	box.CanTouch = false
	box.CastShadow = false
	box.Transparency = 1
	box.Size = Vector3.new(w * LOT_SIZE, h, d * LOT_SIZE)
	box.CFrame = pivot * CFrame.new(0, h * 0.5, 0)
	box.Parent = m
	m.PrimaryPart = box
	m:SetAttribute("BlueprintId", bpId)
	m:SetAttribute("SitePos", pivot.Position)
	m.Parent = siteFolder()
	_siteMarkers[bpId] = m
	refreshSiteUtilities(bpId)
end

local function removeSiteMarker(bpId: string)
	local m = _siteMarkers[bpId]
	_siteMarkers[bpId] = nil
	if m then m:Destroy() end
end

-- Hold a claimed lot as a nest for a demand-scaled dwell, then build. Demand only sets
-- the speed: +1 builds right after MIN_NEST_DWELL, -1 waits NEST_DWELL_RANGE on top.
-- Demand is re-read each poll so rising demand shortens a wait already in progress.
-- Returns false if the site was cancelled / re-zoned while waiting.
local function waitForDemand(bpId: string, zone: string): boolean
	if not waitGameSeconds(MIN_NEST_DWELL, function()
		local a = _activeConstruction[bpId]
		return not a or a.cancelled
	end) then return false end
	local waited = 0
	while true do
		local active = _activeConstruction[bpId]
		if not active or active.cancelled then return false end
		local d = math.clamp(demandForZone(zone), -1, 1)
		-- Positive demand builds promptly (no extra wait above DEMAND_FAST), zero demand
		-- waits ~20% of the range, negative demand waits up to the full range.
		if waited >= math.max(0, DEMAND_FAST - d) / (1 + DEMAND_FAST) * NEST_DWELL_RANGE then return true end
		if not waitGameSeconds(DEMAND_POLL_SECS, function()
			local a = _activeConstruction[bpId]
			return not a or a.cancelled
		end) then return false end
		waited += DEMAND_POLL_SECS
	end
end

-- Declared ahead: cancelConstruction calls it, and it is defined further down. Without this
-- the call resolved to a nil global, so bulldozing a site still under construction threw
-- half-way and PlotService never heard the plot was free -- it stayed zoned for good.
local fireBuildingRemoving: (string) -> ()

local function cancelConstruction(bpId: string)
	local active = _activeConstruction[bpId]
	if not active then return end
	active.cancelled = true
	_activeConstruction[bpId] = nil
	removeSiteMarker(bpId)
	finishConstructionVisual(active.siteId)
	_plotFootprints[bpId] = nil
	pcall(TerrainPadService.unpadFootprint, bpId)
	fireBuildingRemoving(bpId)
end

-- Fires as a building goes away for ANY reason -- the bulldoze tool, a road laid over it,
-- a cancelled nest. PlotService listens so the plot it stood on stops being zoned; without
-- this the frontage stays claimed forever and nothing can be built there again.
-- Suppressed during a city teardown: that is a reload, not a demolition.
local _buildingRemovingListeners: { (string, string?) -> () } = {}
local _suppressRemoving = false
-- Why the building is going away, for the one listener that cares. "road" means a road edit
-- took it, and PlotService re-plans the plot instead of unzoning it; nil is a deliberate
-- demolition (the bulldoze tool), which gives the ground back.
local _removeReason: string? = nil

function BuildingService.onBuildingRemoving(listener: (string, string?) -> ()): () -> ()
	table.insert(_buildingRemovingListeners, listener)
	local disconnected = false
	return function()
		if disconnected then return end
		disconnected = true
		local index = table.find(_buildingRemovingListeners, listener)
		if index then
			table.remove(_buildingRemovingListeners, index)
		end
	end
end

-- One bad listener must not abort a demolition half-way.
function fireBuildingRemoving(bpId: string)
	if _suppressRemoving then return end
	for _, listener in _buildingRemovingListeners do
		local ok, err = pcall(listener, bpId, _removeReason)
		if not ok then
			warn("[BuildingService] onBuildingRemoving listener failed for " .. bpId .. ": " .. tostring(err))
		end
	end
end

local function destroyBuilding(blueprintId: string)
	local record = _buildings[blueprintId]
	if not record then return end

	if _coverageService then
		_coverageService.removeSource(blueprintId)
	end

	if record.model and record.model.Parent then
		record.model:Destroy()
	end

	_buildings[blueprintId] = nil
	_plotFootprints[blueprintId] = nil
	pcall(TerrainPadService.unpadFootprint, blueprintId)
	fireBuildingRemoving(blueprintId)
end

-- SAT overlap of two footprint boxes on XZ; returns the minimum penetration depth (0 = separated).
local function boxPenetration(A: PlotBox, B: PlotBox): number
	local d = B.p - A.p
	d = Vector3.new(d.X, 0, d.Z)
	local minPen = math.huge
	for _, ax in { A.a1, A.a2, B.a1, B.a2 } do
		local rA = A.hw * math.abs(A.a1:Dot(ax)) + A.hd * math.abs(A.a2:Dot(ax))
		local rB = B.hw * math.abs(B.a1:Dot(ax)) + B.hd * math.abs(B.a2:Dot(ax))
		local pen = (rA + rB) - math.abs(d:Dot(ax))
		if pen <= 0 then return 0 end -- separating axis => no overlap
		if pen < minPen then minPen = pen end
	end
	return minPen
end

-- True if this footprint would overlap an already-reserved footprint. Tiling neighbours
-- (same road, or near-parallel plots across chained straight segments) may touch up to
-- half a lot; anything else tolerates only OVERLAP_TOL. Deep penetration always blocks --
-- that is what stops a plot being dropped onto a grid-grown house (or vice versa).
local OVERLAP_TOL = 5    -- studs of interpenetration allowed (touching houses) before it's overlap
local FACE_COS    = 0.85 -- only skip a cross-road plot facing >~32 deg apart (a real corner). A
                         -- straight road split into several segments has near-parallel plots
                         -- (dot ~1), so its houses are NEVER skipped -- that was the gap-at-joins bug.
local function plotFootprintBlocked(pivot: CFrame, wStuds: number, dStuds: number, segId: number): boolean
	local box = makeFootprint(pivot, wStuds, dStuds, segId)
	for _, other in _plotFootprints do
		local tiling = other.seg == segId or box.a1:Dot(other.a1) >= FACE_COS
		local tol = if tiling then LOT_SIZE * 0.5 else OVERLAP_TOL
		if boxPenetration(box, other) > tol then
			return true
		end
	end
	return false
end

-- Not every house fills its plot. A deterministic minority of residential lots take a
-- template a lot narrower and/or shallower than the plot; placeBuilding centres it, so the
-- house sits back off the street with a deeper front yard and a wider side gap, and a zoned
-- row reads as individual homes instead of one continuous wall. Deterministic on the pivot
-- (the same hash the lot dressing uses) so a reload rebuilds the same house on the same plot.
-- A player-picked template is never shrunk -- that name only exists in the plot's own folder.
local function houseLots(zone: string, w: number, d: number, pivot: CFrame): (number, number)
	if zone ~= "Residential" then return w, d end
	local rng = Random.new(math.floor(pivot.Position.X * 31.7 + pivot.Position.Z * 57.1))
	if w > 2 and rng:NextNumber() < 0.35 then w -= 1 end
	if d > 2 and rng:NextNumber() < 0.5 then d -= 1 end
	return w, d
end

-- Develop ONE building on a Manor Lords burgage plot. PlotService owns the plot geometry and
-- calls this per subdivided plot; `pivot` seats the building road-facing, `w`/`d` are fitted
-- template lot-units. Mode:
--   "grow"    -> nest, hold until the city wants the zone, then crane-build (a drag-zoned strip)
--   "stamp"   -> nest briefly, then crane-build at once (a single click placement)
--   "instant" -> place finished immediately, no nest/crane (city restore)
-- Returns the building id (known synchronously so PlotService can track + demolish it) or nil
-- when there is no template for the zone/size.
function BuildingService.developPlot(pivot: CFrame, zone: string, w: number, d: number, mode: string, segId: number?, templateName: string?, padWidthStuds: number?, padDepthStuds: number?, density: string?): string?
	if not _bldgFolder then return nil end
	if density ~= "Medium" or zone ~= "Residential" then density = nil end
	-- hw/hd size the BUILDING; w/d stay the PLOT (footprint, pad, dressing, save key).
	-- A block fills its whole plot: shrinking is a house thing (side gaps, deep yards).
	local hw, hd = w, d
	if not templateName and not density then hw, hd = houseLots(zone, w, d, pivot) end
	local folder = getTemplateFolder(zone, hw, hd, 1, density)
	if not folder and (hw ~= w or hd ~= d) then
		hw, hd = w, d
		folder = getTemplateFolder(zone, w, d, 1, density)
	end
	if not folder then return nil end

	-- Skip a plot that would cross a plot on another road (junction inside) -- wrap, don't overlap.
	-- Never on a restore: these footprints already coexisted when they were placed, so
	-- re-testing them only makes the load order-dependent -- whichever plot developed
	-- first won and the rest of the street silently vanished.
	if segId and mode ~= "instant" and plotFootprintBlocked(pivot, w * LOT_SIZE, d * LOT_SIZE, segId) then
		return nil
	end

	-- Seat the building on the FOOTWAY plane, not on the terrain. The pivot arrives at the road
	-- bezier, which is the carriageway slab's CENTRE, so half the slab plus the kerb height is
	-- the pavement this lot fronts. The pad then cuts or fills the whole plot to that one level,
	-- which is what makes the front path run out onto the footway with no step. Following the
	-- terrain instead (the old rule) floated every uphill house above its own kerb.
	local frontY = pivot.Position.Y + RoadConstants.ROAD_THICKNESS * 0.5 + RoadConstants.SIDEWALK_HEIGHT
	pivot = pivot.Rotation + Vector3.new(pivot.Position.X, frontY, pivot.Position.Z)

	local bpId = newBlueprintId()
	_activeConstruction[bpId] = { siteId = bpId, cancelled = false, zone = zone }
	_plotFootprints[bpId] = makeFootprint(pivot, w * LOT_SIZE, d * LOT_SIZE, segId)

	-- Terrain pad covers the WHOLE plot (frontage x yard depth) when plot dims are given, so
	-- backyard dressing sits on flat ground too -- not just the building slab. The pad pivot
	-- shifts along +Z (away from the road) to stay centred on the plot.
	local padW = math.max(padWidthStuds or 0, w * LOT_SIZE)
	local padD = math.max(padDepthStuds or 0, d * LOT_SIZE)
	local padPivot = pivot * CFrame.new(0, 0, (padD - d * LOT_SIZE) * 0.5)
	local function pad(stage: number?)
		pcall(TerrainPadService.padFootprint, bpId, padPivot, padW, padD, pivot.Position.Y, stage)
	end
	local buildSecs = constructionSeconds(zone, hw, hd, density)

	local saveKey = saveKeyForPivot(zone, w, d, pivot)
	-- A restore develops the same plots the save was taken from, so the state that
	-- outlives a reload (level, occupancy, residents) is reclaimed here by save key.
	local saved = _restoreState[saveKey]
	_restoreState[saveKey] = nil

	local function commit()
		removeSiteMarker(bpId)
		local level = if saved then saved.lv else 1
		local lvFolder = if level > 1 then getTemplateFolder(zone, hw, hd, level, density) else folder
		local pickFrom = lvFolder or folder
		local wantName = (saved and saved.tn) or templateName
		local tmpl = (wantName and findTemplateByName(pickFrom, wantName)) or pickTemplate(pickFrom)
		local model = placeBuilding(bpId, tmpl, pivot, zone, w, d, segId, padWidthStuds)
		local abandoned = if saved then saved.a else false
		local residents = if saved then saved.r else 0
		_buildings[bpId] = {
			blueprintId = bpId, model = model, zone = zone, width = w, depth = d,
			padWidth = padW, padDepth = padD, plotWidth = padWidthStuds, segmentId = segId,
			plotPivot = pivot, groupFill = if saved then saved.f else 0, level = level,
			residents = residents, households = 0, abandoned = abandoned, powered = true, saveKey = saveKey,
			density = density, maxHouseholds = model:GetAttribute("MaxHouseholds") :: number?,
		}
		if saved then
			model:SetAttribute("Residents", residents)
			model:SetAttribute("Abandoned", abandoned)
			if abandoned then setAbandonedTint(model) end
		end
		refreshIndustrialSource(bpId)
	end

	if mode == "instant" then
		pad()
		_activeConstruction[bpId] = nil
		commit()
		return bpId
	end

	addSiteMarker(bpId, pivot, w, d)
	task.spawn(function()
		showNest(bpId, pivot, w, d)
		-- Earthworks first: the ground settles into the pad over a few steps. Checked right
		-- before every write -- a site cancelled mid-grade has already released its pad, and
		-- a late write would claim that ground again with nobody left to release it.
		local function cancelled(): boolean
			local a = _activeConstruction[bpId]
			return not a or a.cancelled
		end
		for i, stage in EARTHWORK_STAGES do
			if cancelled() then return end
			pad(stage)
			if i < #EARTHWORK_STAGES and not waitGameSeconds(EARTHWORK_STEP_SECS, cancelled) then return end
		end
		local proceed: boolean
		if mode == "grow" then
			proceed = waitForDemand(bpId, zone)
		else
			proceed = waitGameSeconds(MIN_NEST_DWELL, function()
				local a = _activeConstruction[bpId]
				return not a or a.cancelled
			end)
		end
		if not proceed then return end
		playConstructionAnimation(bpId, pivot, w, d, commit, buildSecs)
	end)

	return bpId
end

-- Placeable-building catalog for the single-building picker: every variant model in
-- Templates.Buildings under a PAINTABLE zone, as { zone, w, d, name }. Static -> cached.
local _catalogCache: { { zone: string, w: number, d: number, name: string } }? = nil
function BuildingService.getCatalog(): { { zone: string, w: number, d: number, name: string } }
	if _catalogCache then return _catalogCache end
	local out: { { zone: string, w: number, d: number, name: string } } = {}
	local templates = ServerStorage:FindFirstChild("Templates")
	local buildings = templates and templates:FindFirstChild("Buildings")
	if buildings then
		-- Catalog the ACTIVE theme's pack, so the build menu offers what the city can place.
		buildings = (styleRoot(buildings :: Folder))
		for _, zone in ZoneTypes.Paintable do
			local folderName = ZoneTypes.getTemplateFolder(zone)
			if folderName then
				local zoneFolder = buildings:FindFirstChild(folderName)
				if zoneFolder then
					for w = 2, 5 do
						for d = 2, 5 do
							local sizeFolder = zoneFolder:FindFirstChild(tostring(w) .. "x" .. tostring(d))
							if sizeFolder then
								for _, m in sizeFolder:GetChildren() do
									if m:IsA("Model") then
										table.insert(out, { zone = zone, w = w, d = d, name = m.Name })
									end
								end
							end
						end
					end
				end
			end
		end
	end
	_catalogCache = out
	return out
end

-- A fresh clone of the SAME design (TemplateName) at the record's level: a mid-rise
-- level-up lands on its own taller self, and a recovered house stays the same house.
-- The live attributes other services stamped (Residents, NoPower, FamilyName...) carry over.
local function rebuildModel(bpId: string)
	local rec = _buildings[bpId]
	if not rec then return end

	local folder = getTemplateFolder(rec.zone, rec.width, rec.depth, rec.level, rec.density)
	if not folder then return end

	local pivot = recordPivot(rec)
	if not pivot then return end

	local old = rec.model
	local tmpl = findTemplateByName(folder, old and old:GetAttribute("TemplateName")) or pickTemplate(folder)
	local model = placeBuilding(bpId, tmpl, pivot, rec.zone, rec.width, rec.depth, rec.segmentId, rec.plotWidth)
	if old then
		for k, v in old:GetAttributes() do
			if model:GetAttribute(k) == nil then model:SetAttribute(k, v) end
		end
		if old.Parent then old:Destroy() end
	end
	rec.model = model
	rec.maxHouseholds = model:GetAttribute("MaxHouseholds") :: number?
end

local function isLotDressingPart(inst: Instance, root: Instance): boolean
	local cur = inst.Parent
	while cur and cur ~= root do
		if cur.Name == "Yard" or cur.Name == "Lot" or cur.Name == "ParkMarkers" then
			return true
		end
		cur = cur.Parent
	end
	return false
end

function setAbandonedTint(model: Model)
	for _, d in model:GetDescendants() do
		-- LOD2 parts (LODTiers buildings) are Transparency 1 until the client LOD shows them.
		if d:IsA("BasePart") and (d.Transparency < 1 or d:GetAttribute("LOD2")) and not isLotDressingPart(d, model) then
			d.Color = Color3.fromRGB(74, 71, 66)
			d.Material = Enum.Material.Concrete
		end
	end
end

function BuildingService.upgradeGroup(bpId: string): boolean
	local rec = _buildings[bpId]
	if not rec or rec.abandoned or rec.level >= MAX_LEVEL then return false end

	rec.level += 1
	rec.groupFill = (rec.groupFill or 0) * 0.45
	-- A block's levels ARE its heights, and a shop's are its upgrades: swap to the same
	-- design's next level (rebuildModel keeps the design by TemplateName).
	if rec.density == "Medium" or rec.zone == "Commercial" or rec.zone == "Industrial" then rebuildModel(bpId) end
	-- ponytail: no rebuildModel here for houses. A level-up used to re-clone the template, which
	-- re-rolled the random variant and visibly turned the house into a DIFFERENT house.
	-- The level still counts (householdCapFor reads it); only the art stays put.
	refreshIndustrialSource(bpId)

	return true
end

function BuildingService.setGroupFill(bpId: string, value: number)
	local rec = _buildings[bpId]
	if not rec then return end
	rec.groupFill = math.clamp(value, 0, 1)
end

-- Stamp a building's live occupancy onto its model as replicated attributes, so
-- the client's hover preview + info panel read it instantly (no per-hover remote).
-- Occupancy IS the fill, so this keeps groupFill in sync too. Called from
-- CitizenService.syncFill every sim step with the authoritative numbers.
--
-- Homes are filled by HOUSEHOLD, jobs by head: residential fill is households over
-- householdCapFor, so a half-let block reads half full and only a genuinely full one
-- reaches UPGRADE_FILL. Measuring it per PERSON is the trap -- a family of three in a
-- ten-person block reads 30% and can never upgrade, however full the building is.
function BuildingService.setOccupancy(bpId: string, occupants: number, capacity: number, kind: string, level: number)
	local rec = _buildings[bpId]
	if not rec then return end
	local hCap = 0
	if ZoneTypes.isResidential(rec.zone) then
		-- Homes fill by HOUSEHOLD, and how many fit is the lot's business, not the
		-- caller's -- so the passed capacity is replaced with the real one here.
		hCap = householdCapFor(rec)
		capacity = residentCapFor(rec)
		rec.groupFill = math.clamp((rec.households or 0) / hCap, 0, 1)
	else
		rec.groupFill = if capacity > 0 then math.clamp(occupants / capacity, 0, 1) else 0
	end
	local model = rec.model
	if model then
		model:SetAttribute("Occupants", math.floor(occupants + 0.5))
		model:SetAttribute("Capacity", capacity)
		model:SetAttribute("OccupantKind", kind)
		model:SetAttribute("Level", level)
		if hCap > 0 then
			model:SetAttribute("Households", rec.households or 0)
			model:SetAttribute("HouseholdCap", hCap)
		end
	end
end

-- Stamp the resident family's surname onto a home as a replicated attribute so the
-- info panel can show "the <name> family" instantly. CitizenService owns the value;
-- pass nil to clear it when the family leaves.
function BuildingService.setFamilyName(bpId: string, name: string?)
	local rec = _buildings[bpId]
	if not rec or not rec.model then return end
	rec.model:SetAttribute("FamilyName", name)
end

-- Stamp supply-chain info (product type + current shop stock) onto a building's
-- model as replicated attributes for the info panel. SupplyService owns the values.
function BuildingService.setSupplyInfo(bpId: string, product: string?, stock: number?, stockCap: number?)
	local rec = _buildings[bpId]
	if not rec or not rec.model then return end
	if product ~= nil then rec.model:SetAttribute("Product", product) end
	if stock ~= nil then rec.model:SetAttribute("Stock", math.floor(stock + 0.5)) end
	if stockCap ~= nil then rec.model:SetAttribute("StockCap", math.floor(stockCap + 0.5)) end
end

function BuildingService.abandonGroup(bpId: string): boolean
	-- Abandonment system removed: buildings never go derelict anymore. Every route to
	-- abandonment (demand/land-value via ZoneSim, plus crime + sickness via
	-- flagForAbandonment) funnels through here, so this single no-op disables all of it.
	-- recoverGroup still heals any building left abandoned by an older save.
	return false
end

-- Count of populated, non-abandoned homes. SicknessService divides the sick
-- households by this for the city-wide sick fraction.
-- Whether this building is currently on a working grid. PowerService pushes it every
-- pass; the attribute is what NoPowerView hangs its icon off. Cosmetic state only -- the
-- grid itself is PowerService's, and abandonment goes through flagForAbandonment.
function BuildingService.setPowered(bpId: string, powered: boolean)
	_utilityLive.power = true
	local rec = _buildings[bpId]
	if not rec then return end
	rec.powered = powered
	if not rec.model then return end
	-- Written only on change: this runs for every building on every power tick.
	if rec.model:GetAttribute("NoPower") ~= (not powered) then
		rec.model:SetAttribute("NoPower", not powered)
	end
end

-- Same deal for water and sewage: WaterService pushes both every pass, NoPowerView hangs
-- the badges off the attributes, and CitizenService reads the flags off listBuildings to
-- move families out of a home that goes without.
function BuildingService.setWatered(bpId: string, watered: boolean)
	_utilityLive.water = true
	local rec = _buildings[bpId]
	if not rec then return end
	rec.watered = watered
	if rec.model and rec.model:GetAttribute("NoWater") ~= (not watered) then
		rec.model:SetAttribute("NoWater", not watered)
	end
end

function BuildingService.setDrained(bpId: string, drained: boolean)
	_utilityLive.sewage = true
	local rec = _buildings[bpId]
	if not rec then return end
	rec.drained = drained
	if rec.model and rec.model:GetAttribute("NoSewage") ~= (not drained) then
		rec.model:SetAttribute("NoSewage", not drained)
	end
end

function BuildingService.getOccupiedHomeCount(): number
	local n = 0
	for _, rec in _buildings do
		if ZoneTypes.isResidential(rec.zone) and not rec.abandoned and (rec.residents or 0) > 0 then
			n += 1
		end
	end
	return n
end

-- Housing stock counted in HOUSEHOLD SLOTS, not in buildings or people: how many
-- families the city has room for and how many of those slots are taken. A big or
-- high-level home offers several slots (householdCapFor), so a 5x5 with one family in
-- it correctly reads as part-empty. Anything asking "how full is the housing stock"
-- (CityStatsService's vacancy and shortage) has to use this rather than headcount --
-- residents are a family-size ceiling, not fillable slots.
function BuildingService.getHomeCensus(): { total: number, occupied: number }
	local total, occupied = 0, 0
	for _, rec in _buildings do
		if ZoneTypes.isResidential(rec.zone) and not rec.abandoned then
			total += householdCapFor(rec)
			occupied += rec.households or 0
		end
	end
	return { total = total, occupied = occupied }
end

-- Live headcount across every home. Population cannot be read back out of residential
-- fill any more -- that is per-household now (1 = a family lives here, whatever its size).
function BuildingService.getResidentCount(): number
	local n = 0
	for _, rec in _buildings do
		if ZoneTypes.isResidential(rec.zone) and not rec.abandoned then
			n += rec.residents or 0
		end
	end
	return n
end

-- CrimeService / SicknessService call this when an uncovered incident has festered
-- long enough that the building must be given up. Abandonment is the consequence;
-- CitizenService's removal loop then clears the residents/jobs. `reason` is for logs only.
function BuildingService.flagForAbandonment(bpId: string, reason: string?): boolean
	return BuildingService.abandonGroup(bpId)
end

function BuildingService.recoverGroup(bpId: string): boolean
	local rec = _buildings[bpId]
	if not rec or not rec.abandoned then return false end

	rec.abandoned = false
	rebuildModel(bpId) -- fresh template clone clears the derelict tint

	if rec.model then
		rec.model:SetAttribute("Abandoned", false)
	end

	refreshIndustrialSource(bpId)

	return true
end

-- City persistence: SIM STATE ONLY. The buildings themselves come back from PlotService,
-- which replays each group's saved seats at their exact pivots -- so all that has to survive
-- here is what cannot be recomputed, keyed by the pivot-derived save key. That key only
-- lines up because seats are quantised to the save grid BEFORE placement (PlotService.seatPivot).
function BuildingService.serializeBuildings(): { any }
	local out: { any } = {}

	for _, rec in _buildings do
		-- Defaults are omitted (restore fills them in): lv=1, f=0, r=0, a=false.
		table.insert(out, {
			sk = rec.saveKey,
			lv = if rec.level ~= 1 then rec.level else nil,
			f  = if (rec.groupFill or 0) ~= 0 then rec.groupFill else nil,
			r  = if (rec.residents or 0) ~= 0 then rec.residents else nil,
			a  = if rec.abandoned then true else nil,
			tn = if rec.model then rec.model:GetAttribute("TemplateName") else nil,
		})
	end

	return out
end

function findTemplateByName(folder: Folder, name: any): Model?
	if typeof(name) ~= "string" then return nil end
	local child = folder:FindFirstChild(name)
	return if child and child:IsA("Model") then child else nil
end

-- Tear the standing city down and stage the saved sim state. Nothing is placed here:
-- CitySerializer runs PlotService.restore straight after, and each redeveloped plot
-- reclaims its own entry by save key in developPlot.
function BuildingService.restoreBuildings(entries: { any }): number
	local existing: { string } = {}
	for bpId in _buildings do existing[#existing + 1] = bpId end
	local active: { string } = {}
	for bpId in _activeConstruction do active[#active + 1] = bpId end
	-- A teardown is not a demolition: PlotService.restore replaces the groups wholesale
	-- straight after, and letting these fire would unzone the outgoing city plot by plot.
	_suppressRemoving = true
	for _, bpId in existing do destroyBuilding(bpId) end
	for _, bpId in active do cancelConstruction(bpId) end
	_suppressRemoving = false

	_restoreState = {}
	local lost = 0

	for _, e in entries do
		if typeof(e) ~= "table" or typeof(e.sk) ~= "string" then
			lost += 1
			continue
		end
		local abandoned = e.a == true
		_restoreState[e.sk] = {
			lv = math.clamp(if typeof(e.lv) == "number" then e.lv else 1, 1, MAX_LEVEL),
			f  = if abandoned then 0 else math.clamp(tonumber(e.f) or 0, 0, 1),
			r  = if abandoned then 0 else math.max(0, math.floor(tonumber(e.r) or 0)),
			a  = abandoned,
			tn = if typeof(e.tn) == "string" then e.tn else nil,
		}
	end

	if lost > 0 then
		warn("[BuildingService] restoreBuildings: " .. lost .. " malformed state entries dropped")
	end

	return lost
end

-- Lightweight per-building fill for commercial + industrial (no pivot cost). The economy
-- buckets these by product type for per-product taxation.
function BuildingService.getCommercialIndustrialFill(): { { bpId: string, zone: string, level: number, fill: number } }
	local out = {}
	for bpId, rec in _buildings do
		if not rec.abandoned and (rec.zone == "Commercial" or rec.zone == "Industrial") then
			out[#out + 1] = { bpId = bpId, zone = rec.zone, level = rec.level, fill = rec.groupFill or 0 }
		end
	end
	return out
end

function BuildingService.listBuildings(): { any }
	local out = {}

	for bpId, rec in _buildings do
		local pivot = recordPivot(rec)
		out[#out + 1] = {
			bpId           = bpId,
			zone           = rec.zone,
			level          = rec.level,
			fill           = rec.groupFill or 0,
			abandoned      = rec.abandoned or false,
			-- PowerService stamps this every pass. Consumers treat nil/true as powered, so a
			-- building the grid has not reached yet is never wrongly read as dark.
			powered        = rec.powered ~= false,
			watered        = rec.watered ~= false,
			drained        = rec.drained ~= false,
			residents      = rec.residents,
			households     = rec.households or 0,
			householdCap   = if ZoneTypes.isResidential(rec.zone) then householdCapFor(rec) else 0,
			saveKey        = rec.saveKey,
			-- Lot units (width * depth) -- the same numbers that pick the building template.
			-- SupplyService sizes a depot's delivery truck by it, so a two-lot shed is not
			-- sending a 16-metre rig out of a door it would never fit through.
			footprint      = (rec.width or 0) * (rec.depth or 0),
			-- Static post-placement; the civic sims (crime/sickness/fire) read it so
			-- they no longer fall back to the world origin for coverage checks.
			position       = if pivot then pivot.Position else nil,
		}
	end

	return out
end

-- True if a point (with its own clearance radius) falls within `clearance` studs of any
-- standing building's actual footprint (an oriented rectangle: rec.width/rec.depth are in
-- LOT_SIZE units, matching the box getKerb/getDoor/getOutdoorPlaySpot already build from
-- the same fields). Used by NaturePlaceService so trees/rocks/bushes can't be planted
-- inside a house. Transforms the point into the building's own local space (respects
-- rotation) rather than approximating the footprint as a circle -- houses are large
-- enough relative to a tree's radius that a circle would misjudge corners badly.
function BuildingService.isPointNearBuilding(pos: Vector3, clearance: number): boolean
	for _, rec in _buildings do
		if rec.abandoned then continue end
		local pivot = recordPivot(rec)
		if not pivot then continue end
		local halfW = rec.width * LOT_SIZE * 0.5 + clearance
		local halfD = rec.depth * LOT_SIZE * 0.5 + clearance
		local local_ = pivot:PointToObjectSpace(pos)
		if math.abs(local_.X) <= halfW and math.abs(local_.Z) <= halfD then
			return true
		end
	end
	return false
end

-- True while this building is standing OR still going up. PlotService prunes its saved
-- seats against this: the bulldoze tool and demolishUnderPavement (a road laid over a
-- house) both destroy buildings without telling the plot that owns them, so the plot's
-- own record of what it built goes stale the moment either one runs.
function BuildingService.exists(bpId: string): boolean
	return _buildings[bpId] ~= nil or _activeConstruction[bpId] ~= nil
end

function BuildingService.getBuildingZone(bpId: string): string?
	local rec = _buildings[bpId]
	return if rec then rec.zone else nil
end

function BuildingService.getBuildingPosition(bpId: string): Vector3?
	local rec = _buildings[bpId]
	if not rec then return nil end
	local pivot = recordPivot(rec)
	return if pivot then pivot.Position else nil
end

-- The placed building Model for `bpId`, or nil if it has no live model (mid-construction
-- or already demolished). FireService tags this with "OnFire" so the client renders flames.
function BuildingService.getModel(bpId: string): Model?
	local rec = _buildings[bpId]
	local model = rec and rec.model
	return if model and model.Parent then model else nil
end

function BuildingService.getBuildingCounts(): { [string]: { number } }
	local counts = {
		Residential = { 0, 0, 0 },
		Commercial  = { 0, 0, 0 },
		Industrial  = { 0, 0, 0 },
	}

	for _, rec in _buildings do
		local byLevel = counts[rec.zone]

		if byLevel then
			local lvl = math.clamp(rec.level, 1, MAX_LEVEL)
			byLevel[lvl] += 1
		end
	end

	return counts
end

function BuildingService.getFilledByLevel(): { [string]: { number } }
	local filled = {
		Residential = { 0, 0, 0 },
		Commercial  = { 0, 0, 0 },
		Industrial  = { 0, 0, 0 },
	}

	for _, rec in _buildings do
		if rec.abandoned then continue end

		local byLevel = filled[rec.zone]

		if byLevel then
			local lvl = math.clamp(rec.level, 1, MAX_LEVEL)
			byLevel[lvl] += (rec.groupFill or 0)
		end
	end

	return filled
end

local SIDEWALK_WIDTH = 2.5

function BuildingService.getEmptyHomes(): { { groupId: string, zone: string, carStop: Vector3, doorPos: Vector3 } }
	local homes = {}

	for bpId, rec in _buildings do
		-- Nobody moves into a house with the lights off or the taps dry.
		if rec.zone == "Residential" and not rec.abandoned
			and rec.powered ~= false and rec.watered ~= false and rec.drained ~= false then
			local hasRoom = (rec.households or 0) < householdCapFor(rec)
			if hasRoom then
				local pivot = recordPivot(rec)

				if pivot then
					-- Match the road-facing flip applied to scripted templates so the
					-- kerb stop lands in front of the door, not in the backyard.
					local isScripted = rec.model and (rec.model:GetAttribute("HouseHalfWidth") ~= nil or rec.model:GetAttribute("BuildingHalfWidth") ~= nil)
					local frame = if isScripted then pivot * CFrame.Angles(0, math.pi, 0) else pivot
					local frontHalf = rec.depth * LOT_SIZE * 0.5

					homes[#homes + 1] = {
						groupId = bpId,
						zone = rec.zone,
						level = rec.level,
						carStop = (frame * CFrame.new(0, 1, frontHalf + SIDEWALK_WIDTH + 1)).Position,
						doorPos = (frame * CFrame.new(0, 1, 0)).Position,
					}
				end
			end
		end
	end

	return homes
end

-- Road-side kerb point in front of any building (commute/trip endpoint), using
-- the same road-facing flip scripted templates get.
function BuildingService.getKerb(bpId: string): Vector3?
	local rec = _buildings[bpId]
	if not rec then return nil end
	local pivot = recordPivot(rec)
	if not pivot then return nil end
	local isScripted = rec.model ~= nil and (rec.model:GetAttribute("HouseHalfWidth") ~= nil or rec.model:GetAttribute("BuildingHalfWidth") ~= nil)
	local frame = if isScripted then pivot * CFrame.Angles(0, math.pi, 0) else pivot
	local frontHalf = rec.depth * LOT_SIZE * 0.5
	return (frame * CFrame.new(0, 1, frontHalf + SIDEWALK_WIDTH + 1)).Position
end

-- Road-facing front-door point of a building (commute walk endpoint where a citizen
-- pedestrian enters/leaves). Same road-facing flip as getKerb; sits at the front face
-- so the walk leg runs door -> sidewalk -> car/destination.
function BuildingService.getDoor(bpId: string): Vector3?
	local rec = _buildings[bpId]
	if not rec then return nil end
	local pivot = recordPivot(rec)
	if not pivot then return nil end
	local isScripted = rec.model ~= nil and (rec.model:GetAttribute("HouseHalfWidth") ~= nil or rec.model:GetAttribute("BuildingHalfWidth") ~= nil)
	local frame = if isScripted then pivot * CFrame.Angles(0, math.pi, 0) else pivot
	local frontHalf = rec.depth * LOT_SIZE * 0.5
	return (frame * CFrame.new(0, 1, frontHalf)).Position
end

function BuildingService.getOutdoorPlaySpot(bpId: string): Vector3?
	local rec = _buildings[bpId]
	if not rec or rec.zone ~= "Residential" then return nil end
	local pivot = recordPivot(rec)
	if not pivot then return nil end
	local isScripted = rec.model ~= nil and (rec.model:GetAttribute("HouseHalfWidth") ~= nil or rec.model:GetAttribute("BuildingHalfWidth") ~= nil)
	local frame = if isScripted then pivot * CFrame.Angles(0, math.pi, 0) else pivot
	local halfW = rec.width * LOT_SIZE * 0.5
	local halfD = rec.depth * LOT_SIZE * 0.5
	local hash = 0
	for i = 1, #bpId do hash = (hash * 31 + string.byte(bpId, i)) % 9973 end
	local sideSign = if hash % 2 == 0 then -1 else 1
	local side = math.max(0, math.min(halfW - 3, halfW * 0.35))
	local back = -math.max(3, halfD - 4)
	return (frame * CFrame.new(sideSign * side, 1, back)).Position
end

-- Parking spots placed by LotDressingService: a home driveway spot and/or a list
-- of commercial lot stalls (Attachment WorldCFrames). Used by CitizenService so
-- cars park instead of vanishing.
-- Park spots placed by LotDressingService. Each lot stall carries an in-lot ROUTE
-- (lotEntry -> lotFront -> aisle -> stall) the car drives to reach it, and lotEntry
-- is the road-graph hand-off point. CitizenService stitches these onto the road
-- path so cars drive all the way into the lot and reverse the route back out.
-- `garage` is a mid-rise's garage door (GaragePark, facing out) with `garageRoute`, the
-- drive in from LotEntry. Every flat has a bay behind that door, so it is never "taken".
function BuildingService.getParkSpots(bpId: string): { home: CFrame?, lotEntry: Vector3?, stalls: { { cf: CFrame, route: { Vector3 } } }, garage: CFrame?, garageRoute: { Vector3 }? }?
	local rec = _buildings[bpId]
	if not rec or not rec.model then return nil end
	local home: CFrame? = nil
	local byName: { [string]: Attachment } = {}
	for _, d in rec.model:GetDescendants() do
		if d:IsA("Attachment") then
			if d.Name == "HomePark" then
				home = d.WorldCFrame
			else
				byName[d.Name] = d
			end
		end
	end

	local lotEntry = byName["LotEntry"]
	local lotFront = byName["LotFront"]
	local aisleHub = byName["AisleHub"]
	local stalls: { { cf: CFrame, route: { Vector3 } } } = {}
	local i = 1
	while byName["S" .. i] do
		local s = byName["S" .. i]
		local a = byName["S" .. i .. "_a"]
		local route: { Vector3 } = {}
		if lotEntry then table.insert(route, lotEntry.WorldPosition) end
		if lotFront then table.insert(route, lotFront.WorldPosition) end
		if aisleHub then table.insert(route, aisleHub.WorldPosition) end
		if a then table.insert(route, a.WorldPosition) end
		table.insert(stalls, { cf = s.WorldCFrame, route = route })
		i += 1
	end

	local garagePark = byName["GaragePark"]
	local garageRoute: { Vector3 }? = nil
	if garagePark and lotEntry and lotFront then
		garageRoute = { lotEntry.WorldPosition, lotFront.WorldPosition }
	end
	return { home = home, lotEntry = if lotEntry then lotEntry.WorldPosition else nil, stalls = stalls,
		garage = if garageRoute and garagePark then garagePark.WorldCFrame else nil, garageRoute = garageRoute }
end

-- World CFrame of the TruckOut marker baked at an industrial template's garage
-- door: where a delivery truck spawns before driving the yard leg out to the kerb.
-- Nil for templates without one (SupplyService then falls back to a kerb spawn).
function BuildingService.getTruckOut(bpId: string): CFrame?
	local rec = _buildings[bpId]
	local model = rec and rec.model
	if not model or not model.Parent then return nil end
	for _, d in model:GetDescendants() do
		if d:IsA("Attachment") and d.Name == "TruckOut" then
			return d.WorldCFrame
		end
	end
	return nil
end

-- Optional mid-corridor waypoint for side-garage templates: the truck drives
-- garage -> TruckMid -> lot entry -> kerb so it follows the carved lane instead
-- of clipping across the building. Nil for front garages (they exit straight out).
function BuildingService.getTruckMid(bpId: string): Vector3?
	local rec = _buildings[bpId]
	local model = rec and rec.model
	if not model or not model.Parent then return nil end
	for _, d in model:GetDescendants() do
		if d:IsA("Attachment") and d.Name == "TruckMid" then
			return d.WorldPosition
		end
	end
	return nil
end

-- Households. A home holds householdCapFor(rec) families; CitizenService claims a slot
-- before it commits a move-in and frees it when the family leaves, so this count is the
-- one gate on "is there room" -- getEmptyHomes and the info panel both read it.
function BuildingService.getHouseholdCap(bpId: string): number
	local rec = _buildings[bpId]
	if not rec or not ZoneTypes.isResidential(rec.zone) then return 0 end
	return householdCapFor(rec)
end

function BuildingService.getResidentCap(bpId: string): number
	local rec = _buildings[bpId]
	if not rec or not ZoneTypes.isResidential(rec.zone) then return 0 end
	return residentCapFor(rec)
end

function BuildingService.addHousehold(bpId: string): boolean
	local rec = _buildings[bpId]
	if not rec or rec.abandoned or not ZoneTypes.isResidential(rec.zone) then return false end
	if (rec.households or 0) >= householdCapFor(rec) then return false end
	rec.households = (rec.households or 0) + 1
	if rec.model then rec.model:SetAttribute("Households", rec.households) end
	return true
end

function BuildingService.removeHousehold(bpId: string)
	local rec = _buildings[bpId]
	if not rec then return end
	rec.households = math.max(0, (rec.households or 0) - 1)
	if rec.model then rec.model:SetAttribute("Households", rec.households) end
end

-- CitizenService's reconcile forgets every household it knows about and re-adds them.
function BuildingService.clearHouseholds()
	for _, rec in _buildings do
		rec.households = 0
		if rec.model then rec.model:SetAttribute("Households", 0) end
	end
end

function BuildingService.removeResident(bpId: string): boolean
	local rec = _buildings[bpId]
	if not rec or not ZoneTypes.isResidential(rec.zone) then return false end
	if rec.residents <= 0 then return false end
	rec.residents -= 1
	if rec.model then rec.model:SetAttribute("Residents", rec.residents) end
	return true
end

function BuildingService.addResident(bpId: string): boolean
	local rec = _buildings[bpId]
	if not rec or not ZoneTypes.isResidential(rec.zone) then return false end

	if rec.residents >= residentCapFor(rec) then return false end

	rec.residents += 1

	if rec.model then
		rec.model:SetAttribute("Residents", rec.residents)
	end

	return true
end

function BuildingService.canAcceptResident(bpId: string): boolean
	local rec = _buildings[bpId]
	if not rec or not ZoneTypes.isResidential(rec.zone) then return false end

	return rec.residents < residentCapFor(rec)
end

local function canEditBuildings(player: Player): boolean
	if Workspace:GetAttribute("RoadEditOpen") == true then return true end
	return NetMiddleware.GetCachedAttribute(player, "CanEditRoads") == true
end

-- Remove a building by id WITHOUT touching its lot zoning (the bulldoze tool's
-- building delete): the tile stays zoned so the sim may redevelop it later. Frees
-- the lots and cancels an in-progress construction too.
function BuildingService.demolish(bpId: string): boolean
	if _activeConstruction[bpId] then
		cancelConstruction(bpId)
		return true
	end
	if _buildings[bpId] then
		destroyBuilding(bpId)
		return true
	end
	return false
end

-- Demolish every building whose footprint CENTRE lies within `radius` studs (XZ) of any
-- point in `points`. Road/roundabout placement calls this to clear buildings the new
-- pavement is laid over. Centre-only on purpose: a building on an adjacent lot has its
-- centre a full lot + gap beyond the kerb, so it is never caught -- only buildings
-- genuinely sitting under the road. Returns how many were demolished.
--
-- `rectRadius` adds the corner case the centre test cannot see: a building whose CENTRE
-- is outside the new pavement but whose WALL is inside it -- how a roundabout dropped on a
-- zoned street left houses glitching through its kerb. It is measured to the building's own
-- footprint rectangle, so pass the bare paved reach (no sidewalk, no margin): a neighbour
-- that merely fronts the new road is untouched, real overlap is cleared.
function BuildingService.demolishUnderPavement(points: { Vector3 }, radius: number, rectRadius: number?): number
	if typeof(points) ~= "table" or #points == 0 or typeof(radius) ~= "number" then
		return 0
	end
	local rectR = if typeof(rectRadius) == "number" and rectRadius > 0 then rectRadius else nil
	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge
	for _, p in points do
		minX = math.min(minX, p.X)
		maxX = math.max(maxX, p.X)
		minZ = math.min(minZ, p.Z)
		maxZ = math.max(maxZ, p.Z)
	end

	local doomed: { string } = {}
	for bpId, rec in _buildings do
		-- Cheap broad phase: reject anything outside the corridor bounds plus the
		-- building's own footprint diagonal, before the point-by-point test.
		local pivot = recordPivot(rec)
		if pivot then
			local halfDiagonal = math.sqrt((rec.width * LOT_SIZE) ^ 2 + (rec.depth * LOT_SIZE) ^ 2) * 0.5
			local margin = radius + halfDiagonal + LOT_SIZE
			local p = pivot.Position
			if p.X < minX - margin or p.X > maxX + margin or p.Z < minZ - margin or p.Z > maxZ + margin then
				continue
			end

			-- The test itself is PlacementFit's, so the white highlight the road ghost puts
			-- on a house is the same house this demolishes.
			if PlacementFit.seatUnderPavement(pivot,
				rec.width * LOT_SIZE * 0.5, rec.depth * LOT_SIZE * 0.5,
				points, radius, rectR) then
				table.insert(doomed, bpId)
			end
		end
	end
	-- Collect first, then demolish: demolish() mutates _buildings.
	_removeReason = "road"
	for _, bpId in doomed do
		BuildingService.demolish(bpId)
	end
	_removeReason = nil
	return #doomed
end

-- Slide ONE standing building to a new plot pivot, record and all -- what a road nudged
-- sideways does to the houses on it. The model moves RIGIDLY (its dressing, driveway and
-- parking attachments are parented under it, so they ride along and nothing is re-rolled);
-- only the pad, the reserved footprint and the save key are re-derived. `plotPivot` is the
-- pre-lift pivot PlotService seats with -- the footway lift below matches developPlot, or
-- a relocated house would climb a kerb height every time a road moved.
function BuildingService.relocate(bpId: string, plotPivot: CFrame): boolean
	local rec = _buildings[bpId]
	if not rec or not rec.model or not rec.model.Parent then return false end

	local frontY = plotPivot.Position.Y + RoadConstants.ROAD_THICKNESS * 0.5 + RoadConstants.SIDEWALK_HEIGHT
	local pivot = plotPivot.Rotation + Vector3.new(plotPivot.Position.X, frontY, plotPivot.Position.Z)

	rec.model:PivotTo(Quant.snapCF(pivot * rec.plotPivot:Inverse() * rec.model:GetPivot()))

	pcall(TerrainPadService.unpadFootprint, bpId)
	local padPivot = pivot * CFrame.new(0, 0, (rec.padDepth - rec.depth * LOT_SIZE) * 0.5)
	pcall(TerrainPadService.padFootprint, bpId, padPivot, rec.padWidth, rec.padDepth, pivot.Position.Y)

	rec.plotPivot = pivot
	rec.model:SetAttribute("LotPivot", pivot) -- the seat moved; see placeBuilding
	-- The save key is position-derived, so it has to move with the building: leave it and the
	-- next load would hand this family's level, occupancy and residents to nobody.
	rec.saveKey = saveKeyForPivot(rec.zone, rec.width, rec.depth, pivot)
	_plotFootprints[bpId] = makeFootprint(pivot, rec.width * LOT_SIZE, rec.depth * LOT_SIZE, rec.segmentId)
	refreshIndustrialSource(bpId)
	return true
end

-- Re-pad + re-place every building at its stored plot pivot. Use after a change to how
-- buildings are seated so an existing city updates in place. Returns a diagnostic string.
function BuildingService.reseatAllBuildings(): string
	local total, moved = 0, 0
	local samples: { string } = {}
	for bpId, rec in _buildings do
		total += 1
		local pivot = recordPivot(rec)
		if not pivot then continue end

		pcall(TerrainPadService.unpadFootprint, bpId)
		pcall(TerrainPadService.padFootprint, bpId, pivot, rec.padWidth, rec.padDepth, pivot.Position.Y)

		local folder = getTemplateFolder(rec.zone, rec.width, rec.depth, rec.level, rec.density)
		if folder then
			local tn = if rec.model then rec.model:GetAttribute("TemplateName") else nil
			local tmpl = findTemplateByName(folder, tn) or pickTemplate(folder)
			if rec.model and rec.model.Parent then rec.model:Destroy() end
			local model = placeBuilding(bpId, tmpl, pivot, rec.zone, rec.width, rec.depth, rec.segmentId, rec.plotWidth)
			if rec.abandoned then setAbandonedTint(model) end
			model:SetAttribute("Residents", rec.residents)
			model:SetAttribute("Abandoned", rec.abandoned)
			rec.model = model
			moved += 1
		end

		if #samples < 8 then
			table.insert(samples, string.format("%s base=%.2f", bpId, pivot.Position.Y))
		end
	end
	local msg = string.format("[BuildingService] reseat %d/%d buildings\n%s", moved, total, table.concat(samples, "\n"))
	print(msg)
	return msg
end

function BuildingService.SetCityStats(cityStatsService: any)
	_cityStats = cityStatsService
end

function BuildingService.Init(coverageService: any, dressingService: any)
	_coverageService = coverageService
	_dressingService = dressingService
	_bldgFolder  = ensureFolder(ensureFolder(Workspace, "_City"), "ZonedBuildings")
	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	_constructionRemote = Net.SyncConstructionSites
	_demolishRemote = Net.RequestDemolishBuilding
end

function BuildingService.Bind()
	if _demolishRemote then
		_demolishRemote.OnServerEvent:Connect(function(player: Player, bpId: any)
			if not canEditBuildings(player) then return end
			if typeof(bpId) ~= "string" or #bpId == 0 or #bpId > 32 then return end
			local now = os.clock()
			if now - (_lastDemolishAt[player] or 0) < DEMOLISH_COOLDOWN then return end
			_lastDemolishAt[player] = now
			BuildingService.demolish(bpId)
		end)
		Players.PlayerRemoving:Connect(function(player: Player)
			_lastDemolishAt[player] = nil
		end)
	end
end

function BuildingService.Start()
	-- Re-check the construction sites' utilities: a pole or a pipe laid while a street is
	-- going up clears its badges without waiting for the houses to finish.
	task.spawn(function()
		while true do
			task.wait(SITE_UTILITY_POLL)
			for bpId in _siteMarkers do
				refreshSiteUtilities(bpId)
			end
		end
	end)
end

return BuildingService