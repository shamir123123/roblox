--!strict
-- CreationPlaceService
-- Stands player-authored creations up in the city. A creation is a blueprint the player
-- built in the Creation Editor; this is the path OUT of that editor and into the world.
--
-- Mirrors EmergencyService: validate -> ServicePlacement.prepareFree -> charge -> spawn
-- -> refund on build failure. Same trust boundary as every other placement pipeline --
-- the client's pivot contributes X/Z and yaw and nothing else.
--
-- Decorative only. A creation has no coverage, no upkeep and no sim role; it stands
-- there and looks like something. Customised SERVICE buildings are a different problem
-- (a modified hospital has to work as a hospital) and are deliberately not handled here.
--
-- SAVE SHAPE -- prototype/instance, not one blob per placement:
--   library = { [bpId] = { name, ownerId, ownerName, price, blob } }
--   items   = { { id, bp, pivot } }
-- Placing the same fountain fifty times stores the geometry once. The blob is INLINED
-- rather than re-read from BlueprintStore on load, so a city never depends on a
-- blueprint that its author has since deleted, and a restore costs zero DataStore reads.

local Workspace           = game:GetService("Workspace")
local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Quant           = require(ReplicatedStorage.Shared.Quant)
local NetMiddleware   = require(ReplicatedStorage:WaitForChild("NetMiddleware"))
local CreationBuilder = require(ReplicatedStorage:WaitForChild("Editor"):WaitForChild("CreationBuilder"))
local ServicePlacement = require(ServerScriptService.Services.City.ServicePlacement)

local CreationPlaceService = {}

local PLACE_COOLDOWN = 0.15
-- Bounds the city save: each library entry carries a whole creation blob (up to 500
-- elements), and MAX_SLOT_BYTES is 16 MB. Instances are three numbers each and cheap.
local MAX_LIBRARY = 60
local MAX_PLACED  = 400
local MAX_PRICE   = 1000000

type Placed = {
	id: number,
	bp: string,
	cf: CFrame,
	model: Model,
}

type LibEntry = {
	name: string,
	ownerId: number,
	ownerName: string,
	price: number,
	blob: any,
}

local _net: any
local _economyService: any
local _blueprintStore: any
local _resolveAsset: ((string) -> Model?)? = nil
local _review: any = nil
local _folder: Folder
local _placed: { [number]: Placed } = {}
local _library: { [string]: LibEntry } = {}
local _nextId = 0
local _lastPlaceAt: { [Player]: number } = {}

local function ensureFolder(): Folder
	local city = Workspace:FindFirstChild("_City")
	if not city then city = Instance.new("Folder"); city.Name = "_City"; city.Parent = Workspace end
	local f = city:FindFirstChild("Creations")
	if not f or not f:IsA("Folder") then
		if f then f:Destroy() end
		f = Instance.new("Folder"); f.Name = "Creations"; f.Parent = city
	end
	return f :: Folder
end

-- The editor's spawnable catalog, injected by Bootstrap (EditorService owns the walk of
-- ServerStorage.Templates). Injected rather than required so this module does not depend
-- on the editor booting first, and so a test can hand it a stub.
function CreationPlaceService.setAssetResolver(fn: ((string) -> Model?)?)
	_resolveAsset = fn
end

-- The approved-content store, injected because it boots after this service. Unset (tests,
-- tooling) means only your own creations are placeable -- the safe direction to fail.
function CreationPlaceService.setReviewQueue(reviewQueue: any)
	_review = reviewQueue
end

local function resolver(key: string): Model?
	local fn = _resolveAsset
	return if fn then fn(key) else nil
end

local function clampPrice(v: any): number
	local n = tonumber(v) or 0
	if n ~= n then return 0 end -- NaN
	return math.clamp(math.floor(n), 0, MAX_PRICE)
end

-- == Build =====================================================================
-- Internal: trusts its inputs. Validation lives in place(). Returns nil if the blob
-- produced no geometry, which the caller treats as a build failure and refunds.
local function spawn(id: number, bp: string, entry: LibEntry, pivot: CFrame): Placed?
	local model = CreationBuilder.build(entry.blob, resolver)
	if not model then return nil end

	model.Name = "Creation_" .. id
	model:PivotTo(pivot)
	-- CreationId is what BulldozeController.demolishBuilding dispatches on. It must NOT be
	-- called BlueprintId: zoned buildings already use that attribute for the plot's own id,
	-- and the bulldozer checks it first.
	model:SetAttribute("CreationId", id)
	model:SetAttribute("CreationBp", bp)
	model:SetAttribute("CreationName", entry.name)
	model:SetAttribute("CreatorId", entry.ownerId)
	model:SetAttribute("CreatorName", entry.ownerName)
	model.Parent = _folder

	-- No TerrainPadService call on purpose: a statue on a hillside should follow the
	-- ground, not carve a plateau out of it the way a service building does.

	local placed: Placed = { id = id, bp = bp, cf = pivot, model = model }
	_placed[id] = placed
	return placed
end

local function countPlaced(): number
	local n = 0
	for _ in _placed do n += 1 end
	return n
end

local function countLibrary(): number
	local n = 0
	for _ in _library do n += 1 end
	return n
end

-- Drop any library entry no placed instance still references, so deleting the last copy
-- of a creation reclaims its blob from the save instead of leaking it forever.
local function sweepLibrary()
	local live: { [string]: boolean } = {}
	for _, p in _placed do live[p.bp] = true end
	for bp in _library do
		if not live[bp] then _library[bp] = nil end
	end
end

-- == Public ====================================================================
-- Place one of the player's own creations. Yields on the blueprint read the first time
-- a given creation is placed in this city; afterwards the library answers it.
function CreationPlaceService.place(player: Player, bp: string, pivotIn: CFrame): (boolean, string?)
	if typeof(bp) ~= "string" or bp == "" then return false, "unknown creation" end
	if countPlaced() >= MAX_PLACED then return false, "too many creations in this city" end

	-- Availability is re-checked on EVERY placement, not just the first one.
	--
	-- These guards used to sit inside the cache-miss branch below, which meant that once a
	-- creation was in THIS city's library they were never evaluated again: place one while it
	-- was approved, wait for its author to withdraw it, and you could keep spawning fresh
	-- copies of unlisted work indefinitely. The library persists through serialize/restore,
	-- so it survived rejoining too. Both reads are in-memory (the player record is already
	-- loaded, the review status is a cached table), so this costs nothing per placement.
	--
	-- Placeable means YOURS, or anything a curator has approved into the store. An
	-- unsubmitted creation belongs to its author alone, and never trusts the client.
	local mine = _blueprintStore.owns(player.UserId, bp)
	local approved = _review ~= nil and _review.statusOf(bp) == "approved"
	if not (mine or approved) then return false, "that creation isn't available" end
	-- Even the author cannot re-place something a moderator pulled.
	if _review and _review.isRevoked and _review.isRevoked(bp) then
		return false, "that creation was taken down"
	end

	local entry = _library[bp]
	if not entry then
		if countLibrary() >= MAX_LIBRARY then return false, "too many different creations in this city" end
		-- BlueprintStore.get takes any id by design (policy lives in callers), which is why
		-- the gate above runs before we ever reach it.
		local record = _blueprintStore.get(bp) -- yields
		if not record or typeof(record.blob) ~= "table" then return false, "could not load that creation" end
		-- Customised real buildings carry service semantics this module deliberately does
		-- not implement; only free compositions can be placed as decoration.
		if record.kind ~= "creation" then return false, "only creations can be placed for now" end

		entry = {
			name = if typeof(record.name) == "string" then record.name else "Creation",
			ownerId = tonumber(record.ownerId) or 0,
			ownerName = if typeof(record.ownerName) == "string" then record.ownerName else "",
			-- Price rides inside the blob so it travels with the creation to another
			-- player's city, where their index row is not readable.
			price = clampPrice((record.blob :: any).price),
			blob = record.blob,
		}
	end

	-- Footprint comes from the geometry itself: a creation has no declared size. Built
	-- once here and thrown away, then rebuilt in spawn() -- the alternative is holding a
	-- half-placed model across the yield above, which leaks on every rejected placement.
	local probe = CreationBuilder.build(entry.blob, resolver)
	if not probe then return false, "that creation is empty" end
	local _, size = probe:GetBoundingBox()
	probe:Destroy()

	-- skipOverlap: a creation is decoration, not a building. It does not reserve ground, so
	-- refusing it for standing near something already there is the wrong rule -- a statue
	-- beside a shop is the point. Bounds, water and the re-grounded Y all still apply.
	local pivot, reason = ServicePlacement.prepareFree(size, pivotIn, nil, true)
	if not pivot then return false, reason end

	local price = entry.price
	if price > 0 and _economyService and _economyService.trySpend then
		if not _economyService.trySpend(price) then return false, "can't afford" end
	end

	_nextId += 1
	if not spawn(_nextId, bp, entry, pivot) then
		if price > 0 and _economyService and _economyService.credit then _economyService.credit(price) end
		return false, "build failed"
	end

	_library[bp] = entry
	if _net and price > 0 then
		-- To the placer only -- the cost tag and sound are theirs; the creation replicates.
		_net.PlacementCharged:FireClient(player, pivot.Position, price, "Creation")
	end
	return true
end

-- Destroy every placed copy of a creation a moderator has pulled, and drop it from this
-- city's library so the next save does not carry it either.
--
-- This is the one thing that overrides the inlining decision above. Blobs are inlined so a
-- city never breaks when a blueprint is deleted -- durability. A moderation takedown needs
-- exactly the opposite, and moderation wins: something judged unfit must not survive in
-- somebody's city because they happened to place it before the verdict.
--
-- An AUTHOR withdrawing their own work is NOT a takedown (see ReviewQueue.isRevoked): that
-- unlists it so nobody new can take a copy, and leaves standing copies alone.
function CreationPlaceService.sweepRevoked(): number
	if not _review or not _review.isRevoked then return 0 end
	local removed = 0
	for id, p in _placed do
		if _review.isRevoked(p.bp) then
			if p.model and p.model.Parent then p.model:Destroy() end
			_placed[id] = nil
			removed += 1
		end
	end
	for bp in _library do
		if _review.isRevoked(bp) then _library[bp] = nil end
	end
	if removed > 0 then
		warn(string.format("[CreationPlaceService] removed %d placed creation(s) taken down by a moderator", removed))
	end
	sweepLibrary()
	return removed
end

function CreationPlaceService.remove(id: number)
	local p = _placed[id]
	if not p then return end
	if p.model and p.model.Parent then p.model:Destroy() end
	_placed[id] = nil
	sweepLibrary()
end

-- Relocate a placed creation. Same rules as place() and free of charge, keeping its id.
function CreationPlaceService.move(id: number, pivotIn: CFrame): (boolean, string?)
	local p = _placed[id]
	if not p then return false, "no such creation" end
	local _, size = p.model:GetBoundingBox()
	local pivot, reason = ServicePlacement.prepareFree(size, pivotIn, p.model, true)
	if not pivot then return false, reason end
	p.model:PivotTo(pivot)
	p.cf = pivot
	return true
end

function CreationPlaceService.clear()
	for id, p in _placed do
		if p.model and p.model.Parent then p.model:Destroy() end
		_placed[id] = nil
	end
	table.clear(_library)
	_nextId = 0
end

function CreationPlaceService.list(): { Placed }
	local out: { Placed } = {}
	for _, p in _placed do table.insert(out, p) end
	return out
end

-- == Persistence ===============================================================
function CreationPlaceService.serialize(): { [string]: any }
	local lib: { [string]: any } = {}
	for bp, e in _library do
		lib[bp] = { name = e.name, ownerId = e.ownerId, ownerName = e.ownerName, price = e.price, blob = e.blob }
	end
	local items: { any } = {}
	for _, p in _placed do
		table.insert(items, { id = p.id, bp = p.bp, pivot = Quant.packPivot(p.cf) })
	end
	return { version = 1, nextId = _nextId, library = lib, items = items }
end

function CreationPlaceService.restore(data: any)
	CreationPlaceService.clear()
	if typeof(data) ~= "table" then return end

	local lib = data.library
	if typeof(lib) == "table" then
		for bp, e in lib do
			-- A creation pulled by a moderator never comes back, even out of a save written
			-- before the verdict. Skipping it here also drops it from the next save.
			if typeof(bp) == "string" and _review and _review.isRevoked and _review.isRevoked(bp) then
				continue
			end
			if typeof(bp) == "string" and typeof(e) == "table" and typeof(e.blob) == "table" then
				_library[bp] = {
					name = if typeof(e.name) == "string" then e.name else "Creation",
					ownerId = tonumber(e.ownerId) or 0,
					ownerName = if typeof(e.ownerName) == "string" then e.ownerName else "",
					price = clampPrice(e.price),
					blob = e.blob,
				}
			end
		end
	end

	_nextId = math.max(0, math.floor(tonumber(data.nextId) or 0))
	local rows = if typeof(data.items) == "table" then data.items else {}
	local usedIds: { [number]: boolean } = {}

	for _, row in rows do
		if typeof(row) ~= "table" or typeof(row.bp) ~= "string" then continue end
		-- An item whose library entry did not survive is dropped, the same way every other
		-- restore path skips a row it can no longer resolve.
		local entry = _library[row.bp]
		if not entry then continue end

		local pivot = Quant.unpackPivot(row.pivot)
		if not pivot then continue end

		local id = math.floor(tonumber(row.id) or 0)
		if id <= 0 or usedIds[id] then _nextId += 1; id = _nextId end
		usedIds[id] = true
		_nextId = math.max(_nextId, id)
		spawn(id, row.bp, entry, pivot)
	end

	sweepLibrary()
end

-- == Lifecycle =================================================================
local function canEdit(player: Player): boolean
	if Workspace:GetAttribute("RoadEditOpen") == true then return true end
	return NetMiddleware.GetCachedAttribute(player, "CanEditRoads") == true
end

function CreationPlaceService.Init(net: any, economyService: any, blueprintStore: any)
	assert(net, "[CreationPlaceService] missing net")
	assert(blueprintStore, "[CreationPlaceService] missing blueprintStore")
	_net = net
	_economyService = economyService
	_blueprintStore = blueprintStore
	_folder = ensureFolder()
end

function CreationPlaceService.Bind()
	-- Rides the existing RequestPlaceService remote, which already dispatches on a `kind`
	-- string across three independent listeners. A fourth needs no new remote.
	_net.RequestPlaceService.OnServerEvent:Connect(function(player: Player, kind: any, key: any, payload: any)
		if kind ~= "Creation" then return end
		if not canEdit(player) then return end
		local now = os.clock()
		if now - (_lastPlaceAt[player] or 0) < PLACE_COOLDOWN then return end
		_lastPlaceAt[player] = now
		if typeof(key) ~= "string" then return end
		if typeof(payload) ~= "CFrame" then return end
		local ok, reason = CreationPlaceService.place(player, key, payload)
		if not ok and reason then
			_net.Notify:FireClient(player, { text = "Can't place: " .. reason, kind = "danger", duration = 3 })
		end
	end)

	_net.RequestRemoveService.OnServerEvent:Connect(function(player: Player, kind: any, id: any)
		if kind ~= "Creation" then return end
		if not canEdit(player) then return end
		if typeof(id) ~= "number" then return end
		CreationPlaceService.remove(id)
	end)

	_net.RequestMoveService.OnServerEvent:Connect(function(player: Player, kind: any, id: any, pivot: any)
		if kind ~= "Creation" then return end
		if not canEdit(player) then return end
		local now = os.clock()
		if now - (_lastPlaceAt[player] or 0) < PLACE_COOLDOWN then return end
		_lastPlaceAt[player] = now
		if typeof(id) ~= "number" or typeof(pivot) ~= "CFrame" then return end
		CreationPlaceService.move(id, pivot)
	end)

	Players.PlayerRemoving:Connect(function(p) _lastPlaceAt[p] = nil end)
end

function CreationPlaceService.Start() end

return CreationPlaceService
