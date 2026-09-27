--!strict
-- StaffRoster
-- THE staff permission database. What tier someone holds is a record in a global
-- DataStore, not a list in a script: the place owner adds people by UserId from the staff
-- panel's Access tab and it takes effect immediately, with no publish.
--
-- THREE TIERS, and they are NOT a ladder -- a curator is not "half an admin":
--   tester   may join the closed test. Nothing else.
--   curator  may review player-made creations before they are published to other
--            players, so nothing that breaks Roblox's rules reaches the game. Carries no
--            admin power whatsoever: every admin gate asks for tier == "admin" exactly,
--            so adding this tier cannot widen any of them.
--   admin    the F4/F6 panels, city tooling, the lot.
--
-- Record shape -- one key, one flat map so the whole roster is a single read:
--   { ["3245659521"] = { tier = "admin", by = <ownerId>, at = <os.time>, name = "Someone" } }
--
-- The OWNER is never in the record. Being the owner is resolved from the place itself
-- and cannot be granted or revoked by anyone, including themselves -- that is what makes
-- it impossible to lock yourself out of your own game.
--
-- Reads are served from an in-memory copy, refreshed three ways: after this server's own
-- write, on a MessagingService ping from any other server, and on a slow poll as the
-- backstop for a dropped message. Everything that gates on staff (the join gate, the
-- admin remotes, the staff UI delivery) asks HERE -- one definition of "staff", one place
-- to change it.
--
-- Fail-closed: if the roster cannot be read, only the owner is staff for that session
-- (isDegraded() reports it so callers can say so rather than pretending someone was
-- removed). Studio never depends on any of this -- see AdminService.

local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")
local GroupService     = game:GetService("GroupService")
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")

if not RunService:IsServer() then
	error("[StaffRoster] Must only be required on the server")
end

local StaffRoster = {}

local STORE_NAME       = "CityDistrict_Staff_v1"
local ROSTER_KEY       = "roster"
local TOPIC            = "CityDistrict_StaffRoster"
local REFRESH_INTERVAL = 120  -- backstop poll; MessagingService is the fast path
local MAX_ENTRIES      = 200
local MAX_RETRIES      = 4
local RETRY_DELAY      = 1.5
local ACTION_COOLDOWN  = 0.5

export type Tier = "tester" | "curator" | "admin"
export type Entry = { tier: string, by: number?, at: number?, name: string? }
export type Roster = { [string]: Entry }

local VALID_TIER: { [string]: boolean } = { tester = true, curator = true, admin = true }
-- Display order for the Access tab. A plain "is it admin" comparison sorted correctly
-- with two tiers and goes unstable with three.
local TIER_RANK: { [string]: number } = { admin = 1, curator = 2, tester = 3 }

-- ONE-TIME MIGRATION of the lists that used to be hardcoded in TesterService and
-- AdminService. Written only if the store key does not exist yet, so it seeds the very
-- first server that boots after this change and is inert forever after -- removing
-- someone from the Access tab is permanent, it does not come back on the next boot.
-- Delete this table once the roster is live; it is history, not configuration.
local SEED: Roster = {
	["3245659521"] = { tier = "admin",  at = 0 },
	["1423963407"] = { tier = "tester", at = 0 },
	["3318778317"] = { tier = "tester", at = 0 },
}

local _store: DataStore? = nil
local _roster: Roster = {}
local _ownerId  = 0
local _ready    = false
local _degraded = false
local _inited   = false
local _started  = false
local _bound    = false
local _net: any = nil
local _listeners: { () -> () } = {}
local _nameCache: { [number]: string } = {}
local _lastActionAt: { [number]: number } = {}

-- ------------------------------------------------------------------ state --

-- Everything that comes back from the DataStore is untrusted shape: an old record, a
-- half-written one, or a tier string that no longer exists. Rebuild a known-good table
-- rather than handing the raw one to the gates.
local function sanitize(raw: any): Roster
	local out: Roster = {}
	if typeof(raw) ~= "table" then return out end

	local kept = 0
	for key, value in raw do
		if kept >= MAX_ENTRIES then break end
		local id = if typeof(key) == "string" then tonumber(key) else nil
		if id and id > 0 and id == math.floor(id) and typeof(value) == "table" and VALID_TIER[value.tier] then
			out[key] = {
				tier = value.tier,
				by   = tonumber(value.by),
				at   = tonumber(value.at),
				name = if typeof(value.name) == "string" then value.name else nil,
			}
			kept += 1
		end
	end

	return out
end

local function applyRoster(raw: any)
	_roster = sanitize(raw)
	_ready = true
	for _, fn in _listeners do
		task.spawn(fn)
	end
end

-- seedIfMissing uses UpdateAsync so the seed write and the first read are one call;
-- returning nil from the transform cancels the write when a record already exists.
local function readRoster(seedIfMissing: boolean): Roster?
	local store = _store
	if not store then return nil end

	for attempt = 1, MAX_RETRIES do
		local loaded: any = nil

		local ok, err = pcall(function()
			if seedIfMissing then
				store:UpdateAsync(ROSTER_KEY, function(raw)
					if typeof(raw) == "table" then
						loaded = raw
						return nil
					end
					local seeded: Roster = {}
					for key, entry in SEED do
						seeded[key] = { tier = entry.tier, at = entry.at }
					end
					loaded = seeded
					return seeded
				end)
			else
				loaded = store:GetAsync(ROSTER_KEY)
			end
		end)

		if ok then
			return sanitize(loaded)
		end

		warn(string.format("[StaffRoster] read attempt %d/%d failed: %s", attempt, MAX_RETRIES, tostring(err)))
		if attempt < MAX_RETRIES then
			task.wait(RETRY_DELAY * attempt)
		end
	end

	return nil
end

local function publishChange()
	local ok, err = pcall(function()
		MessagingService:PublishAsync(TOPIC, if game.JobId ~= "" then game.JobId else "studio")
	end)
	if not ok then
		warn("[StaffRoster] could not notify other servers: " .. tostring(err))
	end
end

-- All writes funnel through UpdateAsync: two servers editing the roster at the same
-- moment must merge, not overwrite each other. The transform reports whether it actually
-- changed anything so "already an admin" is not written (and not published) as an edit.
local function mutateRoster(transform: (Roster) -> (boolean, string)): (boolean, string)
	local store = _store
	if not store then
		return false, "Permission storage is unavailable right now."
	end

	local changed = false
	local message = ""
	local result: Roster? = nil

	local ok, err = pcall(function()
		store:UpdateAsync(ROSTER_KEY, function(raw)
			local current = sanitize(raw)
			changed, message = transform(current)
			result = current
			if not changed then return nil end
			return current
		end)
	end)

	if not ok then
		warn("[StaffRoster] write failed: " .. tostring(err))
		return false, "Couldn't save that -- try again in a moment."
	end

	if result then
		_degraded = false
		applyRoster(result)
	end
	if not changed then
		return false, message
	end

	publishChange()
	return true, message
end

-- ------------------------------------------------------------------ reads --

function StaffRoster.isReady(): boolean
	return _ready
end

-- True when the roster could not be loaded: the owner is still staff, nobody else is,
-- and that is an outage rather than a decision somebody made.
function StaffRoster.isDegraded(): boolean
	return _degraded
end

function StaffRoster.getOwnerId(): number
	return _ownerId
end

function StaffRoster.isOwner(userId: number): boolean
	return _ownerId > 0 and userId == _ownerId
end

-- The one answer to "what is this player allowed to do". nil = not staff.
-- The owner is always admin and is never in the record.
function StaffRoster.tierOf(userId: number): string?
	if typeof(userId) ~= "number" or userId <= 0 then return nil end
	if StaffRoster.isOwner(userId) then return "admin" end
	local entry = _roster[tostring(userId)]
	if entry and VALID_TIER[entry.tier] then return entry.tier end
	return nil
end

-- May this player approve player-made creations for publication? Curators and admins,
-- plus the owner (who always resolves to admin). THE one definition of review authority:
-- the review queue asks here rather than testing tier strings of its own.
function StaffRoster.canApprove(userId: number): boolean
	local tier = StaffRoster.tierOf(userId)
	return tier == "curator" or tier == "admin"
end

-- Yields until the first roster read lands, so a join gate can decide on real data
-- instead of kicking someone in the second before it arrives. Returns false on timeout.
function StaffRoster.await(timeout: number?): boolean
	local deadline = os.clock() + (timeout or 15)
	while not _ready and os.clock() < deadline do
		task.wait(0.1)
	end
	return _ready
end

-- Display name for a UserId. Cached: the Access tab lists the same people repeatedly,
-- and a failed lookup is also the "no such account" answer grant() needs. Yields.
function StaffRoster.nameOf(userId: number): string?
	local cached = _nameCache[userId]
	if cached then return cached end

	local live = Players:GetPlayerByUserId(userId)
	if live then
		_nameCache[userId] = live.Name
		return live.Name
	end

	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	if ok and typeof(name) == "string" and name ~= "" then
		_nameCache[userId] = name
		return name
	end
	return nil
end

-- Sorted for display: admins first, then by name. The owner is prepended by the caller
-- (they are not a record) so the Access tab can show who is looking at it.
function StaffRoster.list(): { { userId: number, tier: string, name: string?, at: number?, by: number? } }
	local out = {}
	for key, entry in _roster do
		local id = tonumber(key)
		if id then
			table.insert(out, {
				userId = id,
				tier   = entry.tier,
				name   = entry.name,
				at     = entry.at,
				by     = entry.by,
			})
		end
	end

	table.sort(out, function(a, b)
		if a.tier ~= b.tier then
			return (TIER_RANK[a.tier] or 99) < (TIER_RANK[b.tier] or 99)
		end
		local an = string.lower(a.name or tostring(a.userId))
		local bn = string.lower(b.name or tostring(b.userId))
		if an ~= bn then return an < bn end
		return a.userId < b.userId
	end)

	return out
end

-- Fired after any roster change (own write, another server's ping, or the poll). No
-- arguments on purpose: listeners re-ask tierOf rather than being handed the live table.
function StaffRoster.onChanged(fn: () -> ())
	table.insert(_listeners, fn)
end

-- ----------------------------------------------------------------- writes --

local function validTargetId(userId: any): boolean
	return typeof(userId) == "number"
		and userId == userId
		and userId > 0
		and userId < math.huge
		and userId == math.floor(userId)
end

-- Yields (name lookup + DataStore). actorUserId is re-checked against the owner here,
-- not just at the remote: this is the authority, so it never trusts its caller.
function StaffRoster.grant(actorUserId: number, targetUserId: number, tier: string): (boolean, string)
	if not StaffRoster.isOwner(actorUserId) then
		return false, "Only the game owner can change staff."
	end
	if not VALID_TIER[tier] then
		return false, "Choose tester, curator or admin."
	end
	if not validTargetId(targetUserId) then
		return false, "Enter a numeric UserId."
	end
	if targetUserId == _ownerId then
		return false, "That's you -- the owner already has every permission."
	end

	local name = StaffRoster.nameOf(targetUserId)
	if not name then
		return false, "No Roblox account has UserId " .. tostring(targetUserId) .. "."
	end

	local key = tostring(targetUserId)
	return mutateRoster(function(roster)
		local existing = roster[key]
		if existing and existing.tier == tier then
			return false, name .. " is already " .. tier .. "."
		end

		if not existing then
			local count = 0
			for _ in roster do count += 1 end
			if count >= MAX_ENTRIES then
				return false, "Staff list is full (" .. MAX_ENTRIES .. " people)."
			end
		end

		roster[key] = { tier = tier, by = actorUserId, at = os.time(), name = name }
		local verb = if existing then "is now" else "added as"
		return true, name .. " " .. verb .. " " .. tier .. "."
	end)
end

-- Yields (DataStore). Removing someone who is not on the list is reported, not silently
-- treated as success -- the owner asked for a change and should be told none happened.
function StaffRoster.revoke(actorUserId: number, targetUserId: number): (boolean, string)
	if not StaffRoster.isOwner(actorUserId) then
		return false, "Only the game owner can change staff."
	end
	if not validTargetId(targetUserId) then
		return false, "Enter a numeric UserId."
	end
	if targetUserId == _ownerId then
		return false, "The owner can't be removed."
	end

	local key = tostring(targetUserId)
	return mutateRoster(function(roster)
		local existing = roster[key]
		if not existing then
			return false, "That UserId isn't on the staff list."
		end
		local label = existing.name or tostring(targetUserId)
		roster[key] = nil
		return true, label .. " removed."
	end)
end

-- ------------------------------------------------------------------- boot --

-- Init may not yield (CLAUDE rule): open the store handle and take the owner id off the
-- DataModel. A group-owned place needs a web call for its owner, so that one resolves in
-- the background -- until it lands, only the roster grants staff.
function StaffRoster.Init(net: any?)
	if _inited then return end
	_inited = true
	_net = net

	local ok, err = pcall(function()
		_store = DataStoreService:GetDataStore(STORE_NAME)
	end)
	if not ok then
		warn("[StaffRoster] DataStore unavailable: " .. tostring(err))
	end

	if game.CreatorType == Enum.CreatorType.User then
		_ownerId = game.CreatorId
	elseif game.CreatorType == Enum.CreatorType.Group then
		task.spawn(function()
			local okGroup, info = pcall(function()
				return GroupService:GetGroupInfoAsync(game.CreatorId)
			end)
			if okGroup and typeof(info) == "table" and info.Owner and typeof(info.Owner.Id) == "number" then
				_ownerId = info.Owner.Id
				for _, fn in _listeners do task.spawn(fn) end
			else
				warn("[StaffRoster] could not resolve the group owner -- the Access tab will be unavailable")
			end
		end)
	end
end

function StaffRoster.Bind()
	if _bound then return end
	_bound = true

	local remote = _net and _net.RequestStaffRoster
	if not remote then
		warn("[StaffRoster] RequestStaffRoster remote missing -- the owner's Access tab cannot work")
		return
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		_lastActionAt[player.UserId] = nil
	end)

	-- Owner-only, re-checked here on every call. The client's IsPlaceOwner attribute only
	-- decides whether a tab is drawn; this is what actually decides who may edit staff.
	remote.OnServerInvoke = function(player: Player, payload: any): { [string]: any }
		if not StaffRoster.isOwner(player.UserId) then
			warn("[StaffRoster] non-owner", player.Name, "tried to reach the staff roster")
			return { ok = false, error = "Owner only." }
		end
		if typeof(payload) ~= "table" then
			return { ok = false, error = "Bad request." }
		end

		local now = os.clock()
		local last = _lastActionAt[player.UserId]
		if last and now - last < ACTION_COOLDOWN then
			return { ok = false, error = "Slow down." }
		end
		_lastActionAt[player.UserId] = now

		local action = payload.action
		if action == "list" then
			return { ok = true, entries = StaffRoster.list(), ownerId = _ownerId, degraded = _degraded }
		elseif action == "grant" or action == "revoke" then
			local targetId = tonumber(payload.userId) or 0
			local done: boolean, message: string
			if action == "grant" then
				done, message = StaffRoster.grant(player.UserId, targetId, tostring(payload.tier))
			else
				done, message = StaffRoster.revoke(player.UserId, targetId)
			end
			return {
				ok      = done,
				error   = if done then nil else message,
				message = message,
				entries = StaffRoster.list(),
				ownerId = _ownerId,
			}
		end

		return { ok = false, error = "Unknown action." }
	end
end

-- Start may yield. The first read seeds the store if it has never been written, then the
-- roster stays current through MessagingService with a slow poll behind it.
function StaffRoster.Start()
	if _started then return end
	_started = true

	task.spawn(function()
		local loaded = readRoster(true)
		if loaded then
			_degraded = false
			applyRoster(loaded)
		else
			-- Fail closed, but READY: the join gate must stop holding people and give them
			-- an answer. Only the owner is staff until a later refresh succeeds.
			_degraded = true
			warn("[StaffRoster] roster could not be read -- owner-only access until it recovers")
			applyRoster({})
		end
	end)

	task.spawn(function()
		local ok, err = pcall(function()
			MessagingService:SubscribeAsync(TOPIC, function()
				task.spawn(function()
					local loaded = readRoster(false)
					if loaded then
						_degraded = false
						applyRoster(loaded)
					end
				end)
			end)
		end)
		if not ok then
			warn(string.format(
				"[StaffRoster] cross-server sync unavailable (%s) -- changes land within %ds instead",
				tostring(err), REFRESH_INTERVAL))
		end
	end)

	task.spawn(function()
		while true do
			task.wait(REFRESH_INTERVAL)
			local loaded = readRoster(false)
			if loaded then
				_degraded = false
				applyRoster(loaded)
			end
		end
	end)
end

return StaffRoster
