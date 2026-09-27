--!strict
-- PlaceAccessService
-- Join-time access gate for per-player CITY servers. Each player's city runs in
-- its own RESERVED server (see CityTeleport on the hub side). The reserved
-- server's owner is resolved from the access store, keyed by game.PrivateServerId
-- and written by the hub at reserve time -- NOT from client teleport data, which
-- an exploiter can forge. On join, anyone who is not the owner, an invited
-- visitor, or staff (admin/dev) is kicked.
--
-- The invite list is the OWNER's own data and lives on their player record, in the
-- "visitors" field. Only their own server writes it (they are standing in their
-- city when they invite someone); this server reads it at boot with PeekField,
-- which takes no session lock -- the owner may not have joined yet, and may be
-- sitting on a hub server holding the lock.
--
-- Access is PER CITY, not per account (see VisitorList): the reserved server is per OWNER,
-- so at join time there is no city yet to check against. The gate admits on a role in ANY
-- of the owner's cities and `setCityContext` narrows to the one that actually loads, which
-- is the same shape the solo-city eviction already had.
--
-- Fail-closed: on a reserved city server whose owner cannot be resolved, only
-- staff get in. No-op in Studio (dev always in) and on non-reserved / public
-- servers -- those are not anyone's private city, so gating them would break the
-- ordinary single-server / menu flow.
--
-- Access control only. Build/admin rights live elsewhere (CanEditRoads / AdminTier).

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlacesConfig = require(ReplicatedStorage.Access.PlacesConfig)
local CityRoles = require(ReplicatedStorage.Access.CityRoles)
local NetMiddleware = require(ReplicatedStorage.NetMiddleware)
local VisitorList = require(script.Parent.VisitorList)

local PlaceAccessService = {}

local KICK_UNAUTHORIZED = "You don't have access to this city."
local KICK_UNVERIFIED = "Couldn't verify this city \u{2014} please rejoin."
local KICK_FULL = "This city is full."
local SOLO_REFUSAL = "This city is set to Solo. Set Who can join to Shared first."
local NO_CITY_REFUSAL = "Open a city first -- access is given per city."

-- How many players one city server actually holds. NOT the place's MaxPlayers, which is
-- read-only at runtime and deliberately left far higher: the headroom is what lets staff
-- in over the cap, and a reserved server nobody can matchmake into cannot fill itself.
local SOFT_CAP = 10

-- PlacesConfig owns the "what kind of server is this" question; asking it here rather
-- than recomputing the PrivateServerId test keeps one definition of a city server.
-- False in Studio, which is what the isStudio branch in decide() already assumed.
-- The city place AND a reserved instance of ours. NOT isCity(): a VIP server of the
-- city place has no access-store entry, so gating it fails the owner lookup closed and
-- kicks everyone its buyer invited.
local RESERVED = PlacesConfig.isReservedCity()

local MAX_RETRIES = 5
local RETRY_DELAY = 1.5 -- seconds, multiplied by attempt for backoff

local VISITOR_FIELD = "visitors"
-- "Friends can visit while I'm offline" is an ordinary client setting, so it rides the
-- settings blob PlayerSettingsService already validates and persists. No new field, no
-- new remote -- the toggle in the Gameplay page IS the whole owner-side control.
local SETTINGS_FIELD = "settings"
local FRIENDS_OFFLINE_KEY = "friendsOffline"

local _admin: any = nil -- injected AdminService (TierOf = staff authority)
local _teleport: any = nil -- injected CityTeleport (reroute target for the uninvited)
local _pds: any = nil   -- injected PlayerDataStore (owns the invite list)
local _ownerId = 0
local _resolved = false
local _allowed: { [number]: CityRoles.Role } = {} -- guest UserId -> role, for the city standing here
-- The owner's whole per-city record, as read at boot and kept in step by every write here.
-- Held so narrowing to a city on load costs no store read on the load path.
local _visitors: any = nil
-- Which of the owner's cities is standing. nil until one loads -- and until then `_allowed`
-- is the UNION over all of them, which is what the join gate has to work with.
local _slotKey: string? = nil
-- Whether the city STANDING here is a multiplayer one. The reserved server is per-owner
-- but this flag is per-CITY, so it cannot be known at join time -- it arrives from
-- CitySlotService when a city loads. Defaults open: before anything is loaded there is no
-- city to be private about, and the load itself evicts anyone a solo city excludes.
local _multiplayer = true
local _friendsOffline = false -- owner left the door open for friends while away
local _bound = false

local function accessStore(): DataStore
	return DataStoreService:GetDataStore(PlacesConfig.AccessStore)
end

-- Flushed immediately rather than left to the 60s save loop: a grant has to be visible
-- to the next server that boots this city, and "let my friend in" cannot wait a minute.
-- PlayerDataStore owns the retry/backoff, so there is none here.
--
-- Returns the record it wrote so the caller can keep the reverse index in step with what
-- is left -- a revoke from ONE city is not a revoke from the owner's other cities.
local function persistVisitor(owner: Player, slotKey: string, targetId: number, role: CityRoles.Role?): any?
	local list = VisitorList.set(_pds.GetField(owner.UserId, VISITOR_FIELD), slotKey, targetId, role)
	if not list then return nil end
	_pds.SetField(owner.UserId, VISITOR_FIELD, list)
	_pds.Flush(owner)
	if owner.UserId == _ownerId then _visitors = list end
	return list
end

-- Keep the guest's reverse index in step with the owner's list. UpdateAsync, not SetAsync:
-- two owners inviting the same player at the same moment would otherwise lose one of the
-- edges, and a lost edge is a city that never appears in that player's menu.
--
-- A failure here is logged and swallowed. The invite itself has already landed on the
-- OWNER's record, which is the copy the join gate actually reads -- a missing edge hides a
-- city from the guest's list, it can never let the wrong person in.
local function noteInvite(targetId: number, ownerId: number, invited: boolean)
	if targetId <= 0 or ownerId <= 0 or targetId == ownerId then return end
	local ok, err = pcall(function()
		accessStore():UpdateAsync(PlacesConfig.guestKey(targetId), function(old)
			local out = {}
			if typeof(old) == "table" then
				for _, id in old do
					if typeof(id) == "number" and id > 0 and id ~= ownerId then
						table.insert(out, id)
					end
				end
			end
			if invited then table.insert(out, ownerId) end
			return out
		end)
	end)
	if not ok then
		warn("[PlaceAccessService] invite index write failed for", targetId, err)
	end
end

-- Invites granted before this index existed have no edge, and without one the guest's menu
-- never shows the city. Opening the access page repairs every row it lists -- which is the
-- whole migration, and it costs nothing anyone is waiting on.
local function backfillEdges(ownerId: number, rows: { { userId: number } })
	task.spawn(function()
		for _, row in rows do
			noteInvite(row.userId, ownerId, true)
		end
	end)
end

-- The owners who have given this player a role, for the menu's "cities I can open" list.
-- Reading this instead of walking the caller's Roblox FRIENDS list is what makes an invite
-- to someone who is not a Roblox friend visible at all -- and it is one read rather than
-- one per friend, with no scan cap to quietly drop people past the end of it.
function PlaceAccessService.invitedOwners(userId: number): { number }
	local ok, raw = pcall(function()
		return accessStore():GetAsync(PlacesConfig.guestKey(userId))
	end)
	if not ok or typeof(raw) ~= "table" then return {} end
	local out = {}
	for _, id in raw do
		if typeof(id) == "number" and id > 0 and id ~= userId then
			table.insert(out, id)
		end
	end
	return out
end

-- Being uninvited is not a punishment: send them to their OWN city instead of kicking.
-- The case that actually happens is joining a friend from the Roblox friends list,
-- which drops you into their reserved server. Kick only if the reroute itself fails --
-- they cannot be left standing in someone else's city.
local function evict(player: Player, reason: string)
	-- Reroute ONLY when this is provably someone else's city. If the owner never
	-- resolved we cannot tell whose server this is, and "send them to their own city"
	-- may be the server they are already standing in -- a teleport loop with no exit.
	-- A kick is the worse experience, but it terminates.
	local somebodyElses = _resolved and _ownerId > 0 and _ownerId ~= player.UserId
	if somebodyElses and _teleport and _teleport.enterCity(player, player.UserId) then return end
	player:Kick(reason)
end

-- Pull the flag out of the settings blob. Defaults CLOSED on anything unexpected: a
-- missing or malformed record must never read as "let my friends in while I'm away".
local function readFriendsOffline(settings: any): boolean
	if typeof(settings) ~= "table" then return false end
	if typeof(settings.values) ~= "table" then return false end
	return settings.values[FRIENDS_OFFLINE_KEY] == true
end
PlaceAccessService._readFriendsOffline = readFriendsOffline -- exposed for the spec

-- How a staff member chose to arrive: "visitor" (look, do not touch) or the default,
-- builder. It rides the teleport data, which the arriving client controls -- and that is
-- fine, because it can only ever REMOVE rights from someone the roster has already
-- confirmed is staff. No value here grants anybody anything.
--
-- Cached per player: GetJoinData is a call per invocation and applyEditRights runs on every
-- role change for everyone in the server.
local _staffVisitor: { [number]: boolean } = {}

local function staffJoinedAsVisitor(player: Player): boolean
	local cached = _staffVisitor[player.UserId]
	if cached ~= nil then return cached end

	local visitor = false
	local ok, data = pcall(function()
		return player:GetJoinData()
		end)
	if ok and typeof(data) == "table" and typeof(data.TeleportData) == "table" then
		visitor = data.TeleportData.staffMode == "visitor"
	end
	_staffVisitor[player.UserId] = visitor
	return visitor
end

local function isStaff(player: Player): boolean
	if RunService:IsStudio() then return true end
	if _admin and _admin.TierOf then return _admin.TierOf(player) ~= nil end
	return false
end

-- Pure access decision -- no game state, so the truth table is unit-testable.
type Ctx = {
	isStudio: boolean,
	reserved: boolean,
	isStaff: boolean,
	resolved: boolean,
	ownerId: number,
	allowed: { [number]: boolean },
	userId: number,
	seatsFull: boolean,
	isFriend: boolean,
	ownerPresent: boolean,
	friendsOffline: boolean,
	multiplayer: boolean,
}
local function decide(ctx: Ctx): boolean
	if ctx.isStudio then return true end
	if not ctx.reserved then return true end -- public / legacy server, not a private city
	if ctx.isStaff then return true end       -- staff ignore the cap: that is what it is for
	if not ctx.resolved then return false end -- fail-closed until owner is known
	-- Owner before the cap. A city that fills up must never lock out the person whose
	-- city it is -- they would have nowhere to go and nothing to come back to.
	if ctx.userId == ctx.ownerId then return true end
	-- A solo city is solo: no guest list, no friends, no exceptions but staff (checked
	-- above). This is the switch the owner chose when they created the city.
	if not ctx.multiplayer then return false end
	if ctx.seatsFull then return false end
	-- ponytail: the owner's Roblox friends ARE the multiplayer invite list. Roblox's own
	-- join-friend button already drops them into this reserved server, so friends-only
	-- multiplayer costs one line and no UI. grantVisitor/allowed stays for named invites
	-- to non-friends; add a city-level "open to anyone" flag here if public cities matter.
	--
	-- A friend walks in while the owner is here. Once the owner has gone, only if they
	-- left the door open -- that toggle is the whole feature, and defaulting it CLOSED is
	-- what keeps "my city" meaning something when nobody is home.
	if ctx.isFriend and (ctx.ownerPresent or ctx.friendsOffline) then return true end
	-- Any role at all is permission to be here; which role decides what they may DO,
	-- not whether they may enter (see CityRoles.canEdit).
	return ctx.allowed[ctx.userId] ~= nil
end
PlaceAccessService._decide = decide -- exposed for the spec

-- Counted at call time, not cached: players leave while a joiner is still held waiting
-- for owner resolution, and refusing them over a seat that freed up in the meantime is
-- the annoying kind of wrong.
local function seatsFull(): boolean
	return #Players:GetPlayers() > SOFT_CAP
end

-- Yields (web call) and can throw, so it is resolved once in gate's thread and passed in
-- rather than called from inside the pure decision. A failed lookup is NOT a friend --
-- fail-closed, same as an unresolved owner.
local function isFriendOfOwner(player: Player): boolean
	if _ownerId <= 0 or player.UserId == _ownerId then return false end
	local ok, result = pcall(function()
		return player:IsFriendsWith(_ownerId)
	end)
	if not ok then
		warn("[PlaceAccessService] friend check failed for", player.Name, result)
		return false
	end
	return result == true
end

local function ownerPresent(): boolean
	return _ownerId > 0 and Players:GetPlayerByUserId(_ownerId) ~= nil
end

local function ctxFor(player: Player, full: boolean, friend: boolean): Ctx
	return {
		isStudio = RunService:IsStudio(),
		reserved = RESERVED,
		isStaff = isStaff(player),
		resolved = _resolved,
		ownerId = _ownerId,
		allowed = _allowed,
		userId = player.UserId,
		seatsFull = full,
		isFriend = friend,
		ownerPresent = ownerPresent(),
		friendsOffline = _friendsOffline,
		multiplayer = _multiplayer,
	}
end

local function isAllowed(player: Player, friend: boolean): boolean
	return decide(ctxFor(player, seatsFull(), friend))
end

-- Refused ONLY because the server is full: the same decision with a free seat lets them
-- in. Asked this way so there is one copy of the rules -- a hand-written "was it the cap?"
-- test would drift from decide() the first time the order of those checks changes.
local function refusedOnlyForSpace(player: Player, friend: boolean): boolean
	return decide(ctxFor(player, false, friend))
end

local function gate(player: Player)
	-- Cheap allows first (Studio / public server / staff): let them in immediately.
	if RunService:IsStudio() or not RESERVED or isStaff(player) then return end
	-- Reserved city server: the player may have joined before owner resolution
	-- finished. Hold (they have no character yet) until resolved, then decide.
	task.spawn(function()
		local deadline = os.clock() + (MAX_RETRIES * RETRY_DELAY + 5)
		while not _resolved and os.clock() < deadline and player.Parent do
			task.wait(0.2)
		end
		if player.Parent == nil then return end
		-- Resolved after the owner is known (it is the owner we compare against) and once
		-- only -- this is a web call on the join path.
		local friend = isFriendOfOwner(player)
		if player.Parent == nil then return end
		if isAllowed(player, friend) then
			-- Let in: stamp what they may DO. A friend with no explicit role gets none,
			-- so they can look but not build until the owner promotes them.
			PlaceAccessService.applyEditRights(player)
			return
		end
		-- Welcome but out of room: back to the menu, not into their own city. They came
		-- for THIS city, and being dropped in a different one is not the same thing.
		if refusedOnlyForSpace(player, friend) then
			if not (_teleport and _teleport.returnToLobby(player)) then
				player:Kick(KICK_FULL)
			end
			return
		end
		evict(player, if _resolved then KICK_UNAUTHORIZED else KICK_UNVERIFIED)
	end)
end

-- Owner-side invite management. Only the resolved owner of THIS city may edit its
-- list, and only while a city is standing -- the role is given to a CITY, so there is
-- nothing to give it to before one loads. targetId is a raw UserId (validate before
-- calling from a remote handler).
function PlaceAccessService.grantVisitor(owner: Player, targetId: number, role: any): boolean
	if not RESERVED or not _resolved then return false end
	local slotKey = _slotKey
	if not slotKey then return false end
	if owner.UserId ~= _ownerId then return false end
	if typeof(targetId) ~= "number" or targetId <= 0 or targetId == _ownerId then return false end
	-- Roles arrive from a remote, so the string is untrusted: normalize or refuse. An
	-- unrecognised role must not fall back to a generous default.
	local clean = CityRoles.normalize(role)
	if not clean then return false end
	if not persistVisitor(owner, slotKey, targetId, clean) then return false end
	_allowed[targetId] = clean
	noteInvite(targetId, owner.UserId, true)
	-- A demotion has to reach a player already standing in the city, or they keep the
	-- rights they were granted until they happen to leave.
	local target = Players:GetPlayerByUserId(targetId)
	if target then PlaceAccessService.applyEditRights(target) end
	return true
end

-- The city's SOLE edit gate on a published server. Owner always; a guest by their role;
-- staff by their tier. Called on join, on load, and whenever a role changes.
--
-- Also stamps CityRole, which is a LABEL and nothing else -- the badge in the corner reads
-- it so a guest can see what they are. Every actual permission is answered here or by
-- CanEditRoads; nothing server-side ever reads the attribute back.
function PlaceAccessService.applyEditRights(player: Player)
	local may: boolean
	local label: string
	if RunService:IsStudio() or not RESERVED then
		-- single-server / Studio: CitySlotService owns CanEditRoads as before
		player:SetAttribute("CityRole", "owner")
		return
	elseif player.UserId == _ownerId then
		may = true
		label = "owner"
	elseif isStaff(player) then
		-- Staff default to building; one who came in as a visitor gets what a visitor gets.
		may = not staffJoinedAsVisitor(player)
		label = if may then "staff" else "visitor"
	else
		local role = _allowed[player.UserId]
		may = CityRoles.canEdit(role)
		-- A friend with no role is here on friendship alone: "visitor" is what they can do.
		label = role or "visitor"
	end
	player:SetAttribute("CanEditRoads", may)
	player:SetAttribute("CityRole", label)
	NetMiddleware.InvalidateCachedAttribute(player, "CanEditRoads")
end

function PlaceAccessService.roleOf(userId: number): CityRoles.Role?
	return _allowed[userId]
end

-- CitySlotService calls this when a city loads. Both facts it carries belong to the CITY,
-- not to the server: which guest list applies, and whether anyone but the owner may be here
-- at all. Until one is standing there is nothing to enforce and `_allowed` is the union over
-- every city the owner has -- see the header.
--
-- Narrowing can take access AWAY from someone already standing here (they were admitted
-- against an unknown city), so everybody is re-gated afterwards. Re-running `gate` rather
-- than a hand-written test keeps ONE copy of the rules: friends, staff and the seat cap are
-- all still answered the way they were at join.
function PlaceAccessService.setCityContext(slotId: any, isMultiplayer: boolean)
	_slotKey = VisitorList.key(slotId)
	_multiplayer = isMultiplayer ~= false
	if not RESERVED then return end

	if not _slotKey then
		-- A city loaded with a slot id VisitorList will not take -- the two MAX_SLOTS have
		-- drifted, or the caller passed something else. Falling back to the union is the
		-- permissive answer, so say so loudly rather than quietly widening access.
		warn("[PlaceAccessService] city loaded with an unusable slot id", slotId, "-- guest list stays the union over every city")
	end

	_allowed = {}
	local roles = if _slotKey then VisitorList.forSlot(_visitors, _slotKey) else VisitorList.anySlot(_visitors)
	for uid, role in roles do
		local id = tonumber(uid)
		if id then _allowed[id] = role end
	end

	for _, player in Players:GetPlayers() do
		gate(player)
	end
end

function PlaceAccessService.revokeVisitor(owner: Player, targetId: number): boolean
	if not RESERVED or not _resolved then return false end
	local slotKey = _slotKey
	if not slotKey then return false end
	if owner.UserId ~= _ownerId then return false end
	if typeof(targetId) ~= "number" then return false end
	local written = persistVisitor(owner, slotKey, targetId, nil)
	if not written then return false end
	_allowed[targetId] = nil
	local target = Players:GetPlayerByUserId(targetId)
	if target and not isStaff(target) then evict(target, KICK_UNAUTHORIZED) end
	-- The reverse index is per OWNER, not per city: the edge only drops once this player
	-- has no role left in ANY of the owner's cities, or losing one city would hide the
	-- others from their menu.
	noteInvite(targetId, owner.UserId, VisitorList.invited(written, targetId))
	return true
end

function PlaceAccessService.getOwnerId(): number
	return _ownerId
end

-- ---------- role management (RequestCityAccess) ----------

local ACCESS_COOLDOWN = 1.5
local _lastAccessAt: { [number]: number } = {}

local function accessCooldownOk(userId: number): boolean
	local now = os.clock()
	local last = _lastAccessAt[userId]
	if last and now - last < ACCESS_COOLDOWN then return false end
	_lastAccessAt[userId] = now
	return true
end

-- May this player change roles here, and may they touch THIS target?
--
-- Owner always. An admin may manage, but never another admin -- otherwise two admins can
-- demote each other in a loop, and an admin could strip everyone the owner trusted while
-- the owner watches. Only the owner outranks an admin.
local function mayManage(actor: Player, targetId: number): (boolean, string?)
	if not RESERVED or not _resolved then return false, "This city is not ready." end
	if targetId == _ownerId then return false, "You cannot change the owner's access." end
	if actor.UserId == _ownerId then return true, nil end
	if not CityRoles.canManage(_allowed[actor.UserId]) then
		return false, "Only the owner or an admin can change who may build here."
	end
	if _allowed[targetId] == "admin" then
		return false, "Only the owner can change another admin."
	end
	return true, nil
end

-- Every write lands on the OWNER's record, so the owner has to be in this server to hold
-- the session lock for it. Nothing here writes to an absent player's data -- which is
-- also why an admin cannot quietly rewrite the guest list while the owner is away.
local function ownerPlayer(): Player?
	if _ownerId <= 0 then return nil end
	return Players:GetPlayerByUserId(_ownerId)
end

-- A userId is what is stored; a name is what the owner recognises. Online first (free),
-- then the web call, then the id itself -- a lookup that fails must still leave a row the
-- owner can revoke, or an unreachable account becomes permanent.
local function nameOf(userId: number): string
	local online = Players:GetPlayerByUserId(userId)
	if online then return online.Name end
	local ok, resolved = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	return if ok and typeof(resolved) == "string" then resolved else tostring(userId)
end

local function accessList(): { { userId: number, name: string, role: string } }
	local rows = {}
	for userId, role in _allowed do
		table.insert(rows, { userId = userId, name = nameOf(userId), role = role })
	end
	table.sort(rows, function(a, b) return a.name:lower() < b.name:lower() end)
	return rows
end

-- targetId is never taken as a raw number from the client on the grant path: the client
-- sends a NAME and the server resolves it. A raw id would let someone paste an id they
-- should not know anything about; a name is the same thing the player typed in.
local function resolveTargetId(name: any): (number?, string?)
	if typeof(name) ~= "string" or #name == 0 or #name > 20 or not name:match("^[%w_]+$") then
		return nil, "That is not a username."
	end
	local ok, id = pcall(function()
		return Players:GetUserIdFromNameAsync(name)
	end)
	if not ok or typeof(id) ~= "number" then return nil, "No player by that name." end
	return id, nil
end

-- OFF a city server -- the lobby, Studio, a public server. Nothing is standing here to
-- gate, but the guest list is the caller's OWN record either way, and the menu is exactly
-- where a city gets set up: before anyone is in it. So the same three actions work here,
-- minus everything that only means something with a live room -- no rights to stamp,
-- nobody to evict, and no admin acting on an absent owner's behalf. The next city server
-- to boot reads this record and does all of that then.
--
-- The city is named by `payload.slotId` and is REQUIRED: access is per city, and there is
-- no standing one here to infer it from. Load City sends the row the player picked; the
-- Control Room in the menu sends nothing and is told to open a city.
--
-- ponytail: no solo check here -- whether that slot is shared lives on the SLOT index,
-- which CitySlotService owns. Load City puts its Multiplayer switch beside this list, so
-- the refusal would be telling the player something already on screen.
function PlaceAccessService.ownAccess(player: Player, payload: any): any
	local slotKey = VisitorList.key(payload.slotId)
	if not slotKey then return { ok = false, error = NO_CITY_REFUSAL } end

	local stored = _pds.GetField(player.UserId, VISITOR_FIELD)

	local function rows(from: any): { { userId: number, name: string, role: string } }
		local out = {}
		for key, role in VisitorList.forSlot(from, slotKey) do
			local id = tonumber(key)
			if id then
				table.insert(out, { userId = id, name = nameOf(id), role = role })
			end
		end
		table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
		return out
	end

	local action = payload.action
	if action == "list" then
		local entries = rows(stored)
		backfillEdges(player.UserId, entries)
		return { ok = true, entries = entries, isOwner = true }
	end

	local targetId, nameErr = resolveTargetId(payload.name)
	if not targetId then return { ok = false, error = nameErr } end
	if targetId == player.UserId then return { ok = false, error = "That is you." } end

	local role: CityRoles.Role? = nil
	if action == "grant" then
		-- Normalized or refused, never defaulted: this string came off a client.
		role = CityRoles.normalize(payload.role)
		if not role then return { ok = false, error = "Unknown role." } end
	elseif action ~= "revoke" then
		return { ok = false, error = "Bad request." }
	end

	local written = VisitorList.set(stored, slotKey, targetId, role)
	if not written then return { ok = false, error = NO_CITY_REFUSAL } end

	-- Flushed rather than left to the save loop, for the same reason a grant in a city is:
	-- the city server that reads this may boot seconds from now.
	_pds.SetField(player.UserId, VISITOR_FIELD, written)
	_pds.Flush(player)
	noteInvite(targetId, player.UserId, VisitorList.invited(written, targetId))
	return { ok = true, entries = rows(written) }
end

local function onRequestCityAccess(player: Player, payload: any): any
	if typeof(payload) ~= "table" then return { ok = false, error = "Bad request." } end
	if not accessCooldownOk(player.UserId) then return { ok = false, error = "Too fast. Try again." } end
	if not RESERVED then return PlaceAccessService.ownAccess(player, payload) end

	local action = payload.action
	local canSee = player.UserId == _ownerId or CityRoles.canManage(_allowed[player.UserId])

	-- A role belongs to a CITY. On a city server with none standing yet there is nothing
	-- to attach one to, and `_allowed` is still the union over the owner's cities -- listing
	-- or editing it here would be editing all of them at once.
	if not _slotKey then return { ok = false, error = NO_CITY_REFUSAL } end

	if action == "list" then
		if not canSee then return { ok = false, error = "Only the owner or an admin can see this." } end
		local entries = accessList()
		backfillEdges(_ownerId, entries)
		return { ok = true, entries = entries, isOwner = player.UserId == _ownerId }
	end

	if action == "grant" then
		-- A solo city admits nobody but its owner, whatever the list says, so handing out a
		-- role there is a promise the gate will not keep. Refused here, where the player can
		-- still see why -- rather than silently, when their guest bounces off the door.
		if not _multiplayer then return { ok = false, error = SOLO_REFUSAL } end
		local targetId, nameErr = resolveTargetId(payload.name)
		if not targetId then return { ok = false, error = nameErr } end
		local may, mayErr = mayManage(player, targetId)
		if not may then return { ok = false, error = mayErr } end
		-- Only the owner may hand out admin: an admin promoting an admin is how one
		-- careless grant becomes a room full of them.
		if payload.role == "admin" and player.UserId ~= _ownerId then
			return { ok = false, error = "Only the owner can make someone an admin." }
		end
		local owner = ownerPlayer()
		if not owner then
			return { ok = false, error = "The owner has to be here to change who may build." }
		end
		if not PlaceAccessService.grantVisitor(owner, targetId, payload.role) then
			return { ok = false, error = "Could not set that role." }
		end
		return { ok = true, entries = accessList() }
	end

	if action == "revoke" then
		local targetId, nameErr = resolveTargetId(payload.name)
		if not targetId then return { ok = false, error = nameErr } end
		local may, mayErr = mayManage(player, targetId)
		if not may then return { ok = false, error = mayErr } end
		local owner = ownerPlayer()
		if not owner then
			return { ok = false, error = "The owner has to be here to change who may build." }
		end
		if not PlaceAccessService.revokeVisitor(owner, targetId) then
			return { ok = false, error = "Could not remove that player." }
		end
		return { ok = true, entries = accessList() }
	end

	return { ok = false, error = "Bad request." }
end

-- Init may not yield (CLAUDE rule). Just capture the injected dependencies.
function PlaceAccessService.Init(adminService: any?, playerDataStore: any, cityTeleport: any)
	if not playerDataStore then
		error("[PlaceAccessService] Init requires PlayerDataStore (the invite list lives on the player record)")
	end
	if not cityTeleport then
		error("[PlaceAccessService] Init requires CityTeleport (the uninvited are rerouted, not kicked)")
	end
	_admin = adminService
	_pds = playerDataStore
	_teleport = cityTeleport
end

function PlaceAccessService.Bind()
	if _bound then return end
	_bound = true
	Players.PlayerAdded:Connect(gate)
	for _, player in Players:GetPlayers() do
		gate(player)
	end

	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	Net.RequestCityAccess.OnServerInvoke = onRequestCityAccess

	-- The flag only starts mattering the moment the owner walks out, so re-read it then.
	-- GetField, not PeekField: the owner is still in this server, so this is their LIVE
	-- record and cannot be behind SettingsClient's debounced push the way the store can.
	Players.PlayerRemoving:Connect(function(player)
		_lastAccessAt[player.UserId] = nil
		_staffVisitor[player.UserId] = nil
		if not RESERVED or player.UserId ~= _ownerId then return end
		_friendsOffline = readFriendsOffline(_pds.GetField(_ownerId, SETTINGS_FIELD))
	end)
end

-- Start may yield: resolve the city owner + invite list off the DataStore. The
-- hub writes the owner mapping just before teleporting, so a fresh city server
-- may read before the write lands -- retry with backoff.
function PlaceAccessService.Start()
	if not RESERVED then
		_resolved = true
		return
	end
	task.spawn(function()
		for attempt = 1, MAX_RETRIES do
			local ok, val = pcall(function()
				return accessStore():GetAsync(PlacesConfig.ownerKey(game.PrivateServerId))
			end)
			if ok and typeof(val) == "number" and val > 0 then
				_ownerId = val
				break
			end
			task.wait(RETRY_DELAY * attempt)
		end

		if _ownerId > 0 then
			-- No lock: the owner may be on a lobby server right now, holding theirs.
			_visitors = _pds.PeekField(_ownerId, VISITOR_FIELD)
			-- The UNION over every city, because no city has loaded yet and the gate has to
			-- answer now. setCityContext narrows it the moment one does.
			for uid, role in VisitorList.anySlot(_visitors) do
				local id = tonumber(uid)
				if id then _allowed[id] = role end
			end
			_friendsOffline = readFriendsOffline(_pds.PeekField(_ownerId, SETTINGS_FIELD))
		else
			warn("[PlaceAccess] could not resolve city owner for", game.PrivateServerId, "-- gating to staff only")
		end

		_resolved = true
		-- Re-gate anyone still waiting (their hold loops also wake on their own).
		for _, player in Players:GetPlayers() do
			if not isAllowed(player) then
				evict(player, if _ownerId > 0 then KICK_UNAUTHORIZED else KICK_UNVERIFIED)
			end
		end
	end)
end

return PlaceAccessService
