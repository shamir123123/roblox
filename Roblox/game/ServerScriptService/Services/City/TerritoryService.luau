--!strict
-- WHICH GROUND THE CITY OWNS, and the buying of more of it.
--
-- Cities: Skylines' tile system on a 16x16 grid (TerritoryGrid). A new city owns the 3x3
-- block round its starting interchange; every other tile is bought, anywhere on the map,
-- one at a time or a whole dragged box at once. Three levers:
--   * milestones grant PERMITS -- how many tiles the city may hold at all
--   * each tile costs MONEY up front (rising with how many you hold)
--   * each BOUGHT tile costs UPKEEP every month (injected into CityEconomyService)
--
-- Ownership is the POSITIONAL placement gate for the whole game: every service that puts
-- something on the ground asks this first. Those services do not require this one --
-- Bootstrap injects the check, exactly as it injects ProgressionService's unlock check --
-- so the dependency arrow points one way and nothing here knows who its consumers are.
--
-- SANDBOX owns the whole map from the first minute: a city with unlimited money has nothing
-- to spend on land, so a locked tile there would be an obstacle with no decision behind it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local Net = require(ReplicatedStorage:WaitForChild("Networker"))
local NetMiddleware = require(ReplicatedStorage:WaitForChild("NetMiddleware"))
local TerritoryGrid = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("TerritoryGrid"))

local TerritoryService = {}

local _economy: any = nil
local _progression: any = nil

local _owned: { [number]: boolean } = {}
local _ownedCount = 0
-- Tiles that came free (the starting block, or land a pre-tile save was grandfathered
-- into). Upkeep is charged on everything above this.
local _free = 0
local _lastBuyAt: { [Player]: number } = {}

local BUY_COOLDOWN = 0.35

local function isSandbox(): boolean
	return Workspace:GetAttribute("Sandbox") == true
end

-- Shares the city-edit gate with roads and terrain: open to everyone only when
-- RoadEditOpen is set (Studio), otherwise per-player via CanEditRoads.
local function canEdit(player: Player): boolean
	if Workspace:GetAttribute("RoadEditOpen") == true then return true end
	return NetMiddleware.GetCachedAttribute(player, "CanEditRoads") == true
end

local function tier(): number
	if not _progression or not _progression.getTier then return 1 end
	local ok, t = pcall(_progression.getTier)
	return if ok and typeof(t) == "number" then t else 1
end

local function allowance(): number
	return TerritoryGrid.allowanceFor(tier())
end

local function ownedIds(): { number }
	local out: { number } = {}
	for id in _owned do table.insert(out, id) end
	table.sort(out)
	return out
end

-- == Broadcast =================================================================

local function snapshot(): { [string]: any }
	return {
		owned = ownedIds(),
		allowance = allowance(),
		free = _free,
		tier = tier(),
		sandbox = isSandbox(),
		total = TerritoryGrid.TOTAL,
	}
end

local function broadcast()
	if Net.SyncTerritory then
		Net.SyncTerritory:FireAllClients(snapshot())
	end
end

TerritoryService.snapshot = snapshot

-- == The placement gate ========================================================
-- Everything below is asked by other services before they put something on the ground.
-- All of it reads as TRUE in sandbox and true everywhere on a grandfathered city, so a
-- caller never needs to know about either case.

function TerritoryService.isPointAllowed(pos: any): boolean
	if isSandbox() then return true end
	if typeof(pos) ~= "Vector3" then return false end
	return _owned[TerritoryGrid.idAt(pos.X, pos.Z)] == true
end

-- A footprint with real size has to lie ENTIRELY inside owned land: half a hospital over
-- the border is not a hospital you are allowed to build.
function TerritoryService.isBoxAllowed(pos: any, hx: number, hz: number): boolean
	if isSandbox() then return true end
	if typeof(pos) ~= "Vector3" then return false end
	return TerritoryGrid.boxOwned(_owned, pos.X, pos.Z, math.abs(hx), math.abs(hz))
end

-- A road is a curve, not a point: every sample along it must be on owned ground, or a
-- player could anchor inside their land and drag the far end across the whole map.
function TerritoryService.isSpanAllowed(points: any): boolean
	if isSandbox() then return true end
	if typeof(points) ~= "table" then return false end
	for _, p in points do
		if typeof(p) ~= "Vector3" then return false end
		if not _owned[TerritoryGrid.idAt(p.X, p.Z)] then return false end
	end
	return true
end

function TerritoryService.isOwnedTile(id: any): boolean
	if isSandbox() then return true end
	return TerritoryGrid.isValidId(id) and _owned[tonumber(id) :: number] == true
end

function TerritoryService.ownedCount(): number
	return _ownedCount
end

-- Injected into CityEconomyService.setLandUpkeep by Bootstrap: the land line of the budget.
function TerritoryService.getMonthlyUpkeep(): number
	if isSandbox() then return 0 end
	return math.max(0, _ownedCount - _free) * TerritoryGrid.UPKEEP_PER_TILE
end

-- == Ownership changes =========================================================

local function own(id: number): boolean
	if not TerritoryGrid.isValidId(id) or _owned[id] then return false end
	_owned[id] = true
	_ownedCount += 1
	return true
end

local function reset()
	_owned = {}
	_ownedCount = 0
	_free = 0
end

-- The city's starting block, centred on its starting interchange. Clears whatever was
-- held before, so loading a new city over a standing one never inherits its land.
function TerritoryService.startAt(pos: any)
	reset()
	local p = if typeof(pos) == "Vector3" then pos else Vector3.zero
	for _, id in TerritoryGrid.startIds(p.X, p.Z) do own(id) end
	_free = _ownedCount
	broadcast()
end

function TerritoryService.clearAll()
	reset()
	broadcast()
end

-- == Persistence ===============================================================

function TerritoryService.serialize(): { [string]: any }
	return { grid = TerritoryGrid.TILES_PER_AXIS, tiles = ownedIds(), free = _free }
end

-- Three shapes of save:
--   * no territory section -- predates tiles; its city is already built across ground it was
--     never asked to buy. Grandfather it: own the whole map, upkeep-free.
--   * tiles with no `grid` -- the 6x6 era. Migrate to the new grid, upkeep-free.
--   * the current shape.
function TerritoryService.restore(blob: any)
	reset()
	if typeof(blob) ~= "table" or typeof(blob.tiles) ~= "table" then
		for id = 1, TerritoryGrid.TOTAL do own(id) end
		_free = _ownedCount
	elseif blob.grid ~= TerritoryGrid.TILES_PER_AXIS then
		for _, id in TerritoryGrid.fromLegacy(blob.tiles) do own(id) end
		_free = _ownedCount
	else
		for _, id in blob.tiles do
			if TerritoryGrid.isValidId(id) then own(tonumber(id) :: number) end
		end
		_free = math.clamp(math.floor(tonumber(blob.free) or TerritoryGrid.START_TILES), 0, _ownedCount)
	end
	broadcast()
end

-- == Buying ====================================================================

-- One tile id or an array of them (the tile view's drag box). All-or-nothing: either every
-- new tile in the request is bought, or none is.
local function buy(player: Player, payload: any): (boolean, any)
	if not canEdit(player) then return false, "You cannot build in this city." end
	local now = os.clock()
	local last = _lastBuyAt[player]
	if last and now - last < BUY_COOLDOWN then return false, "Too fast. Try again." end
	_lastBuyAt[player] = now

	if isSandbox() then return false, "Sandbox cities already own the whole map." end
	local ids = if typeof(payload) == "table" then payload else { payload }

	local wanted: { number } = {}
	local seen: { [number]: boolean } = {}
	local count = 0
	for _, raw in ids do
		count += 1
		if count > TerritoryGrid.TOTAL then return false, "That is more land than the map has." end
		if not TerritoryGrid.isValidId(raw) then return false, "That is not a tile." end
		local id = tonumber(raw) :: number
		if not _owned[id] and not seen[id] then
			seen[id] = true
			table.insert(wanted, id)
		end
	end
	if #wanted == 0 then return false, "Select land you do not own yet." end

	local room = allowance() - _ownedCount
	if #wanted > room then
		return false, ("Not enough permits: %d selected, %d left. Reach the next milestone for more."):format(#wanted, math.max(0, room))
	end
	if not _economy or not _economy.trySpend then return false, "The treasury is unavailable." end

	-- Priced and charged in one step: between a look at the treasury and the spend, another
	-- player in the same city could have emptied it.
	local price = TerritoryGrid.priceForBatch(_ownedCount, #wanted)
	if not _economy.trySpend(price) then return false, "Not enough money." end

	for _, id in wanted do own(id) end
	broadcast()
	return true, { bought = #wanted, paid = price, owned = _ownedCount }
end

-- == Lifecycle =================================================================

function TerritoryService.Init(economyService: any, progressionService: any)
	assert(economyService, "[TerritoryService] requires CityEconomyService")
	_economy = economyService
	_progression = progressionService
end

function TerritoryService.Bind()
	Net.RequestBuyTile.OnServerInvoke = buy

	Players.PlayerRemoving:Connect(function(player: Player)
		_lastBuyAt[player] = nil
	end)

	-- A player arriving after the city is up needs the current picture; the milestone
	-- that raises the allowance happens on the server, so the snapshot is pushed, never
	-- polled.
	Players.PlayerAdded:Connect(function(player: Player)
		task.defer(function()
			if player.Parent and Net.SyncTerritory then
				Net.SyncTerritory:FireClient(player, snapshot())
			end
		end)
	end)
end

function TerritoryService.Start()
	broadcast()
end

-- Called by ProgressionService when a milestone lands, so the allowance the client shows
-- rises the moment it is earned rather than on the next unrelated change. Progression
-- broadcasts every few seconds for the XP bar; only a tier change is news here.
local _announcedTier = 0
function TerritoryService.onProgressionChanged()
	local t = tier()
	if t == _announcedTier then return end
	_announcedTier = t
	broadcast()
end

return TerritoryService
