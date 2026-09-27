--!strict
-- ReviewQueue
-- THE gate between "a player built something" and "everyone can see it". A creation is
-- private to its author until they SUBMIT it; a curator or admin then approves or rejects
-- it, and only approved work is publishable. Nothing reaches another player without a
-- human having looked at it.
--
-- Two records in one DataStore, each a single key so a listing is one read (the same
-- shape as StaffRoster, for the same reason):
--   pending   [bpId] = { bpId, ownerId, ownerName, name, cat, at }
--   published [bpId] = { ...the same, plus by = <reviewer>, at = <decision time> }
-- Rejections are kept too, so an author can be told why instead of watching their work
-- vanish. None of these hold the geometry -- a queue row is metadata, and the blob stays
-- in BlueprintStore where it already lives.
--
-- THE NAME IS FILTERED ON SUBMIT, NOT ON DISPLAY. A queue row is shown to a curator --
-- another player -- so by the time it is stored it must already be safe to render. If
-- FilterStringAsync fails, the submission is REFUSED: there is no path here that stores a
-- string nobody has filtered. The raw name stays on the author's own blueprint record,
-- which only they can read.
--
-- Authority is StaffRoster.canApprove and nothing else -- this module never compares tier
-- strings of its own.

local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")
local TextService      = game:GetService("TextService")
local RunService       = game:GetService("RunService")
local Players          = game:GetService("Players")

-- The pure half lives in a child module so it can be tested: this guard makes ReviewQueue
-- itself unrequirable in Studio's Edit mode, where IsServer() is false.
local Shape = require(script:WaitForChild("Shape"))

if not RunService:IsServer() then
	error("[ReviewQueue] Must only be required on the server")
end

local ReviewQueue = {}

local STORE_NAME  = "CityDistrict_Review_v1"
local PENDING_KEY = "pending"
local PUBLISHED_KEY = "published"
local REJECTED_KEY  = "rejected"
local LOG_KEY       = "log"
local TOPIC       = "CityDistrict_ReviewQueue"
local REFRESH_INTERVAL = 90
local MAX_PENDING   = 200
local MAX_PUBLISHED = 2000
local MAX_REJECTED  = 500
-- The audit trail of who decided what. Deliberately longer-lived than `rejected`: that
-- record is cleared when an item is re-approved, this one never forgets.
local MAX_LOG       = 400
local MAX_RETRIES   = 3
local RETRY_DELAY   = 1.5
-- Per-player throttles, the same idea as StaffRoster's ACTION_COOLDOWN. Split because the
-- two halves cost wildly different things and one number would be wrong for both.
--
-- READS matter more than they look: `blob` is an UNCACHED GetAsync per call, so without a
-- throttle one player spamming it turns remote invokes into DataStore reads one-for-one and
-- burns the whole EXPERIENCE's read budget, not just their own. Kept short enough that
-- clicking through the shelf still feels immediate.
local READ_COOLDOWN  = 0.2
local WRITE_COOLDOWN = 0.5

export type Row = Shape.Row
export type Record = Shape.Record

local _store: DataStore? = nil
local _pending: Record = {}
local _published: Record = {}
local _rejected: Record = {}
local _log: { Shape.LogEntry } = {}
local _ready = false
local _degraded = false
local _inited, _bound, _started = false, false, false
local _net: any = nil
local _bp: any = nil
local _roster: any = nil
-- Injected by Bootstrap: destroys any placed copy of a revoked creation. Injected rather
-- than required so this module keeps knowing nothing about the city.
local _sweeper: (() -> ())? = nil
local _lastReadAt: { [number]: number } = {}
local _lastWriteAt: { [number]: number } = {}

local function sweepRevoked()
	local fn = _sweeper
	if not fn then return end
	local ok, err = pcall(fn)
	if not ok then warn("[ReviewQueue] revocation sweep failed: " .. tostring(err)) end
end

-- Whatever removes taken-down creations from the live city.
function ReviewQueue.setRevocationSweeper(fn: (() -> ())?)
	_sweeper = fn
end

-- The pure shape helpers live on Shape; these are the local names this module uses.
local sanitize = Shape.sanitize
local countOf = Shape.count
local sortedRows = Shape.sortedRows

-- ----------------------------------------------------------------- store --

local function readKey(key: string, cap: number): Record?
	local store = _store
	if not store then return nil end
	for attempt = 1, MAX_RETRIES do
		local ok, loaded = pcall(function() return store:GetAsync(key) end)
		if ok then return sanitize(loaded, cap) end
		warn(string.format("[ReviewQueue] read %q attempt %d/%d failed: %s", key, attempt, MAX_RETRIES, tostring(loaded)))
		if attempt < MAX_RETRIES then task.wait(RETRY_DELAY * attempt) end
	end
	return nil
end

local function readLog(): { Shape.LogEntry }?
	local store = _store
	if not store then return nil end
	local ok, loaded = pcall(function() return store:GetAsync(LOG_KEY) end)
	if ok then return Shape.sanitizeLog(loaded, MAX_LOG) end
	warn("[ReviewQueue] audit log read failed: " .. tostring(loaded))
	return nil
end

-- Records one reviewer decision. Written SEPARATELY from the decision itself and never
-- allowed to fail it: a takedown that cannot be logged is still a takedown worth having,
-- and blocking moderation on a log write would be the worse bug. A failure warns loudly.
local function appendLog(action: string, row: Row, actorUserId: number, actorName: string?, reason: string?)
	local store = _store
	if not store then return end
	local entry: Shape.LogEntry = {
		at = os.time(), action = action, bpId = row.bpId, name = row.name,
		ownerId = row.ownerId, ownerName = row.ownerName,
		by = actorUserId, byName = actorName or "", reason = reason,
	}
	local ok, err = pcall(function()
		store:UpdateAsync(LOG_KEY, function(raw)
			local current = Shape.sanitizeLog(raw, MAX_LOG)
			table.insert(current, 1, entry) -- newest first; position is the chronology
			while #current > MAX_LOG do table.remove(current) end
			_log = current
			return current
		end)
	end)
	if not ok then
		warn(string.format("[ReviewQueue] AUDIT LOG WRITE FAILED for %s on %q: %s",
			action, tostring(row.bpId), tostring(err)))
	end
end

local function refresh()
	local p = readKey(PENDING_KEY, MAX_PENDING)
	local pub = readKey(PUBLISHED_KEY, MAX_PUBLISHED)
	local rej = readKey(REJECTED_KEY, MAX_REJECTED)
	if p then _pending = p end
	if pub then _published = pub end
	if rej then _rejected = rej end
	local lg = readLog()
	if lg then _log = lg end
	_degraded = (p == nil or pub == nil)
	_ready = true
	-- A takedown on ANOTHER server arrives here, as a ping or on the slow poll. Sweeping
	-- after every refresh is what makes a moderation verdict reach copies standing in a
	-- city this server is hosting.
	sweepRevoked()
end

local function publishChange()
	pcall(function()
		MessagingService:PublishAsync(TOPIC, if game.JobId ~= "" then game.JobId else "studio")
	end)
end

-- All writes go through UpdateAsync so two servers reviewing at once merge rather than
-- overwrite. The transform reports whether anything actually changed, so a no-op decision
-- is not written and not broadcast.
local function mutate(key: string, cap: number, transform: (Record) -> (boolean, string)): (boolean, string)
	local store = _store
	if not store then return false, "Review storage is unavailable right now." end

	local changed, message = false, ""
	local result: Record? = nil
	local ok, err = pcall(function()
		store:UpdateAsync(key, function(raw)
			local current = sanitize(raw, cap)
			changed, message = transform(current)
			result = current
			if not changed then return nil end
			return current
		end)
	end)

	if not ok then
		warn("[ReviewQueue] write failed: " .. tostring(err))
		return false, "Couldn't save that -- try again in a moment."
	end

	if result then
		if key == PENDING_KEY then _pending = result
		elseif key == PUBLISHED_KEY then _published = result
		else _rejected = result end
	end
	if not changed then return false, message end
	publishChange()
	return true, message
end

-- ------------------------------------------------------------------ read --

function ReviewQueue.isReady(): boolean return _ready end
function ReviewQueue.isDegraded(): boolean return _degraded end

-- Has this creation been PULLED by a moderator? That is different from an author
-- withdrawing their own work: a withdrawal unlists it, so nobody new can take a copy, but
-- the copies already standing in people's cities stay. A takedown is a moderation verdict
-- and has to reach every copy that exists -- see CreationPlaceService.sweepRevoked.
function ReviewQueue.isRevoked(bpId: string): boolean
	if typeof(bpId) ~= "string" then return false end
	local row = _rejected[bpId]
	return row ~= nil and row.action == "takedown"
end

function ReviewQueue.listPending(): { Row } return sortedRows(_pending) end
function ReviewQueue.listPublished(): { Row } return sortedRows(_published) end

function ReviewQueue.pendingCount(): number return countOf(_pending) end

-- The audit trail, newest first. Who approved what, when, and why it was refused.
-- REVIEWER-ONLY: gated behind canApprove at the remote, and never folded into a reply
-- that an ordinary player can ask for.
function ReviewQueue.listLog(): { Shape.LogEntry } return _log end

-- The PUBLIC view of the approved catalogue, for the Creations shelf.
--
-- Deliberately NOT listPublished(): that row carries `by`, the UserId of the staff member
-- who approved it. Broadcasting which curator cleared which item to every player in the
-- game is not something a shelf needs, and it paints a target on whoever moderates. Author
-- attribution stays -- it is the point of the shelf -- reviewer identity does not leave
-- the Review tab.
function ReviewQueue.listStore(): { any }
	local out: { any } = {}
	for _, row in sortedRows(_published) do
		table.insert(out, {
			bpId = row.bpId,
			name = row.name, -- already filtered on submit
			cat = row.cat,
			ownerId = row.ownerId,
			ownerName = row.ownerName,
			at = row.at,
		})
	end
	return out
end

-- Serves the geometry behind a creation. Approved work is PUBLIC -- anyone placing it from
-- the Creations shelf needs it. A PENDING one is served only to a reviewer, which is what
-- lets them look at the thing before deciding on it. Everything else is refused, so an
-- unsubmitted private creation can never leak through here.
--
-- The name returned is the row's FILTERED name, never record.name, which is the raw string
-- the author typed and is only safe to show to the author.
function ReviewQueue.blobFor(player: Player, bpId: any): { [string]: any }
	if typeof(bpId) ~= "string" or bpId == "" then return { ok = false, error = "Unknown creation." } end
	local status, row = ReviewQueue.statusOf(bpId)
	local allowed = status == "approved"
		or (status == "pending" and _roster.canApprove(player.UserId))
	if not allowed or not row then return { ok = false, error = "That creation isn't available." } end

	local record = _bp.get(bpId) -- yields
	if not record or typeof(record.blob) ~= "table" then
		return { ok = false, error = "Couldn't load that creation." }
	end
	-- Hand back the GEOMETRY and nothing else identifying. Note what is absent: the raw
	-- record (which carries the author's unfiltered name), and the reviewer who cleared it.
	-- Handing over the blob lets a player PLACE this creation; it must never be enough to
	-- claim it, and EditorService.doLoad is what enforces that -- see the note there.
	return {
		ok = true,
		blob = record.blob,
		name = row.name, -- the filtered name, never record.name
		ownerName = row.ownerName,
		cat = row.cat,
		status = status,
	}
end

-- "pending" | "approved" | "rejected" | nil (never submitted).
function ReviewQueue.statusOf(bpId: string): (string?, Row?)
	if typeof(bpId) ~= "string" then return nil, nil end
	if _pending[bpId] then return "pending", _pending[bpId] end
	if _published[bpId] then return "approved", _published[bpId] end
	if _rejected[bpId] then return "rejected", _rejected[bpId] end
	return nil, nil
end

-- Every submission this player has in flight or decided, so their own library can show a
-- badge per creation without a curator's view of everyone else's work.
function ReviewQueue.statusesFor(userId: number): { [string]: any }
	local out: { [string]: any } = {}
	for _, record in { { "pending", _pending }, { "approved", _published }, { "rejected", _rejected } } do
		local state = record[1] :: string
		for bpId, row in (record[2] :: Record) do
			if row.ownerId == userId then
				out[bpId] = { status = state, at = row.at, reason = row.reason }
			end
		end
	end
	return out
end

-- ----------------------------------------------------------------- write --

-- Yields (text filter + DataStore). The author submits their OWN creation; ownership is
-- re-checked against BlueprintStore here rather than trusted from the client.
function ReviewQueue.submit(player: Player, bpId: any): (boolean, string)
	if typeof(bpId) ~= "string" or bpId == "" then return false, "Unknown creation." end
	if not _bp.owns(player.UserId, bpId) then return false, "That isn't your creation." end

	local existing = ReviewQueue.statusOf(bpId)
	if existing == "pending" then return false, "That's already waiting for review." end
	if existing == "approved" then return false, "That's already approved." end

	local record = _bp.get(bpId) -- yields
	if not record then return false, "Couldn't load that creation." end

	-- Filter BEFORE storing: a queue row is rendered to a curator, who is another player.
	-- A filter failure refuses the submission rather than storing an unchecked string.
	local rawName = if typeof(record.name) == "string" then record.name else ""
	if rawName == "" then return false, "Give it a name first." end
	local safeName: string? = nil
	local okFilter = pcall(function()
		local result = TextService:FilterStringAsync(rawName, player.UserId)
		safeName = result:GetNonChatStringForBroadcastAsync()
	end)
	if not okFilter or typeof(safeName) ~= "string" or safeName == "" then
		return false, "Couldn't check that name right now -- try again in a moment."
	end

	-- Where the creator filed it. New saves carry the shelf inside the blob; anything saved
	-- before that fix has it only on the owner's index row -- readable here because submit
	-- is always the owner acting on their own work. Going straight to the default silently
	-- relabelled every older submission as a Prop.
	local blob = record.blob
	local cat: string? = if typeof(blob) == "table" and typeof((blob :: any).cat) == "string"
		then (blob :: any).cat
		else nil
	if not cat then
		for _, indexRow in _bp.list(player.UserId) do
			if typeof(indexRow) == "table" and indexRow.id == bpId
				and typeof(indexRow.meta) == "table" and typeof(indexRow.meta.cat) == "string" then
				cat = indexRow.meta.cat
				break
			end
		end
	end
	local catKey = cat or "Prop"

	return mutate(PENDING_KEY, MAX_PENDING, function(pending)
		if pending[bpId] then return false, "That's already waiting for review." end
		if countOf(pending) >= MAX_PENDING then
			return false, "The review queue is full -- try again later."
		end
		pending[bpId] = {
			bpId = bpId, ownerId = player.UserId, ownerName = player.Name,
			name = safeName :: string, cat = catKey, at = os.time(),
		}
		return true, "Sent for review."
	end)
end

-- Yields. Curator or admin only -- StaffRoster is the authority, re-asked here so this
-- never trusts the remote that called it.
function ReviewQueue.approve(actorUserId: number, bpId: any, actorName: string?): (boolean, string)
	if not _roster.canApprove(actorUserId) then return false, "You can't review creations." end
	if typeof(bpId) ~= "string" then return false, "Unknown creation." end

	local row = _pending[bpId]
	if not row then return false, "That isn't waiting for review." end

	-- RECOVERY for a half-finished earlier approval: `published` took and `pending` did not.
	-- Left alone that wedges -- statusOf checks pending first, so the item reads "pending"
	-- while sitting on the public shelf, and nobody can place what the shelf advertises. The
	-- old code bailed here on "Already approved" without ever retrying the clear, so the only
	-- way out was to REJECT it, which writes a false audit entry. Finish the job instead.
	if _published[bpId] then
		local okFix = mutate(PENDING_KEY, MAX_PENDING, function(pending)
			if not pending[bpId] then return false, "" end
			pending[bpId] = nil
			return true, ""
		end)
		if not okFix then return false, "Couldn't finish that -- try again in a moment." end
		return true, row.name .. " approved."
	end

	-- Published first: if the second write fails the item is live AND still queued. That is
	-- the recoverable order -- the branch above finishes it on the next attempt. The other
	-- order would drop it from both and lose the work outright.
	local okPub, msgPub = mutate(PUBLISHED_KEY, MAX_PUBLISHED, function(published)
		if published[bpId] then return false, "Already approved." end
		if countOf(published) >= MAX_PUBLISHED then
			return false, "The published catalogue is full."
		end
		published[bpId] = {
			bpId = bpId, ownerId = row.ownerId, ownerName = row.ownerName,
			name = row.name, cat = row.cat, at = os.time(), by = actorUserId,
		}
		return true, "Approved."
	end)
	if not okPub then return false, msgPub end

	local okClear = mutate(PENDING_KEY, MAX_PENDING, function(pending)
		if not pending[bpId] then return false, "" end
		pending[bpId] = nil
		return true, ""
	end)
	if not okClear then
		-- Half-written. It IS approved and live; it just still shows in the queue. Say so
		-- rather than reporting clean success, and approving again will finish it.
		appendLog("approved", row, actorUserId, actorName)
		return true, row.name .. " approved, but it is still showing in the queue -- approve it again to clear it."
	end

	-- An approved item leaves `rejected` behind: a past refusal must not keep showing as
	-- the item's status once it has been let through. The audit log remembers it instead.
	if _rejected[bpId] then
		mutate(REJECTED_KEY, MAX_REJECTED, function(rejected)
			if not rejected[bpId] then return false, "" end
			rejected[bpId] = nil
			return true, ""
		end)
	end

	appendLog("approved", row, actorUserId, actorName)
	return true, row.name .. " approved."
end

-- Yields. The reason is kept so the author is told why rather than watching it vanish.
function ReviewQueue.reject(actorUserId: number, bpId: any, reason: any, actorName: string?): (boolean, string)
	if not _roster.canApprove(actorUserId) then return false, "You can't review creations." end
	if typeof(bpId) ~= "string" then return false, "Unknown creation." end

	local row = _pending[bpId]
	if not row then return false, "That isn't waiting for review." end
	local why = Shape.clampReason(reason) or "Doesn't meet the rules."

	mutate(REJECTED_KEY, MAX_REJECTED, function(rejected)
		if countOf(rejected) >= MAX_REJECTED then
			-- Oldest decision is the least useful to keep; drop it rather than refuse.
			local oldestId = Shape.oldestId(rejected)
			if oldestId then rejected[oldestId] = nil end
		end
		rejected[bpId] = {
			bpId = bpId, ownerId = row.ownerId, ownerName = row.ownerName,
			name = row.name, cat = row.cat, at = os.time(), by = actorUserId, reason = why,
			action = "rejected",
		}
		return true, ""
	end)

	mutate(PENDING_KEY, MAX_PENDING, function(pending)
		if not pending[bpId] then return false, "" end
		pending[bpId] = nil
		return true, ""
	end)

	appendLog("rejected", row, actorUserId, actorName, why)
	return true, row.name .. " rejected."
end

-- Pull an approved creation back out of circulation.
--
-- TWO people may do this, for different reasons, and the log distinguishes them:
--   a curator or admin  -- they got it wrong, or a report arrived after the fact, and
--                          that must never require the author's cooperation;
--   the AUTHOR          -- withdrawing their own work. Someone who shared a thing is
--                          entitled to stop sharing it without asking a moderator.
-- Anyone else is refused. Note this is the one review action that is NOT gated at the
-- remote, because "is this yours" cannot be answered up there -- it authorizes itself.
function ReviewQueue.unpublish(actorUserId: number, bpId: any, reason: any, actorName: string?): (boolean, string)
	if typeof(bpId) ~= "string" then return false, "Unknown creation." end
	local row = _published[bpId]
	if not row then return false, "That isn't published." end

	local isStaff = _roster.canApprove(actorUserId)
	local isAuthor = row.ownerId == actorUserId
	if not (isStaff or isAuthor) then return false, "You can't take that down." end

	-- An AUTHOR's reason is unfiltered player text, and it would land in the audit log, which
	-- renders on a curator's screen -- exactly what this module's header forbids for names.
	-- Withdrawing your own work needs no explanation, so no reason is accepted for it. A
	-- staff reason is staff-authored and is kept.
	local why = (if isStaff then Shape.clampReason(reason) else nil)
		or (if isAuthor and not isStaff then "Withdrawn by its creator." else "Taken down after review.")

	local verdict = if isAuthor and not isStaff then "withdrawn" else "takedown"
	mutate(REJECTED_KEY, MAX_REJECTED, function(rejected)
		rejected[bpId] = {
			bpId = bpId, ownerId = row.ownerId, ownerName = row.ownerName,
			name = row.name, cat = row.cat, at = os.time(), by = actorUserId, reason = why,
			action = verdict,
		}
		return true, ""
	end)
	local done, message = mutate(PUBLISHED_KEY, MAX_PUBLISHED, function(published)
		if not published[bpId] then return false, "That isn't published." end
		published[bpId] = nil
		return true, row.name .. " taken down."
	end)
	if done then
		appendLog(verdict, row, actorUserId, actorName, why)
		-- A moderator takedown must reach every copy already standing in someone's city,
		-- not just the catalogue. Swept here for this server; other servers pick it up off
		-- the MessagingService ping, which lands in refresh().
		if verdict == "takedown" then sweepRevoked() end
	end
	return done, message
end

-- ------------------------------------------------------------------- boot --

-- Init may not yield: open the store handle and take the injected dependencies.
function ReviewQueue.Init(net: any, blueprintStore: any, staffRoster: any)
	if _inited then return end
	_inited = true
	assert(blueprintStore, "[ReviewQueue] Init requires BlueprintStore")
	assert(staffRoster and staffRoster.canApprove, "[ReviewQueue] Init requires StaffRoster")
	_net = net
	_bp = blueprintStore
	_roster = staffRoster

	local ok, err = pcall(function()
		_store = DataStoreService:GetDataStore(STORE_NAME)
	end)
	if not ok then
		warn("[ReviewQueue] DataStore unavailable: " .. tostring(err))
	end
end

function ReviewQueue.Bind()
	if _bound then return end
	_bound = true

	local remote = _net and _net.RequestReviewQueue
	if not remote then
		warn("[ReviewQueue] RequestReviewQueue remote missing -- the Review tab cannot work")
		return
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		_lastReadAt[player.UserId] = nil
		_lastWriteAt[player.UserId] = nil
	end)

	local WRITES: { [string]: boolean } = {
		submit = true, approve = true, reject = true, unpublish = true,
	}

	remote.OnServerInvoke = function(player: Player, payload: any): { [string]: any }
		if typeof(payload) ~= "table" then return { ok = false, error = "Bad request." } end
		local action = payload.action

		-- Throttled before ANY work, so a refused call costs a table lookup rather than a
		-- DataStore read or a full catalogue serialisation.
		local uid = player.UserId
		local now = os.clock()
		local isWrite = WRITES[action] == true
		local bucket = if isWrite then _lastWriteAt else _lastReadAt
		local gap = if isWrite then WRITE_COOLDOWN else READ_COOLDOWN
		local last = bucket[uid]
		if last and now - last < gap then
			return { ok = false, error = "Slow down." }
		end
		bucket[uid] = now

		-- An author submitting their own work, and reading the verdict on it, needs no tier.
		if action == "submit" then
			local done, message = ReviewQueue.submit(player, payload.id)
			return { ok = done, error = if done then nil else message, message = message }
		elseif action == "mine" then
			return { ok = true, statuses = ReviewQueue.statusesFor(player.UserId) }
		elseif action == "store" then
			-- The approved catalogue is public by definition: a human already cleared every
			-- row in it, and any player browsing the Creations shelf needs to see it. Served
			-- through listStore, which strips the reviewer's identity -- see the note there.
			return { ok = true, published = ReviewQueue.listStore() }
		elseif action == "blob" then
			-- Gates itself: approved to anyone, pending to reviewers only.
			return ReviewQueue.blobFor(player, payload.id)
		elseif action == "unpublish" then
			-- Above the reviewer gate because an AUTHOR may withdraw their own work, and
			-- that question cannot be answered here. unpublish authorizes itself.
			local done, message = ReviewQueue.unpublish(player.UserId, payload.id, payload.reason, player.Name)
			local reply: { [string]: any } = {
				ok = done,
				error = if done then nil else message,
				message = message,
				published = ReviewQueue.listStore(),
			}
			-- A reviewer taking something down from the Review tab still needs the tab's
			-- own lists back; an author withdrawing gets only the public catalogue.
			if _roster.canApprove(player.UserId) then
				reply.pending = ReviewQueue.listPending()
				reply.published = ReviewQueue.listPublished()
				reply.log = ReviewQueue.listLog()
			end
			return reply
		end

		-- Everything below is a review action. Re-checked HERE on every call: the client's
		-- AdminTier attribute only decides whether the tab is drawn.
		if not _roster.canApprove(player.UserId) then
			return { ok = false, error = "You can't review creations." }
		end

		if action == "list" then
			return {
				ok = true,
				pending = ReviewQueue.listPending(),
				published = ReviewQueue.listPublished(),
				log = ReviewQueue.listLog(),
				degraded = _degraded,
			}
		elseif action == "log" then
			return { ok = true, log = ReviewQueue.listLog() }
		elseif action == "approve" or action == "reject" then
			local done: boolean, message: string
			-- The reviewer's NAME is passed alongside their id so the audit trail stays
			-- readable years later, when a bare UserId means nothing to anyone reading it.
			if action == "approve" then
				done, message = ReviewQueue.approve(player.UserId, payload.id, player.Name)
			else
				done, message = ReviewQueue.reject(player.UserId, payload.id, payload.reason, player.Name)
			end
			return {
				ok = done,
				error = if done then nil else message,
				message = message,
				pending = ReviewQueue.listPending(),
				published = ReviewQueue.listPublished(),
				log = ReviewQueue.listLog(),
			}
		end

		return { ok = false, error = "Unknown action." }
	end
end

-- Start may yield. Same three-way freshness as StaffRoster: own write, cross-server ping,
-- slow poll as the backstop for a dropped message.
function ReviewQueue.Start()
	if _started then return end
	_started = true

	task.spawn(refresh)

	task.spawn(function()
		local ok, err = pcall(function()
			MessagingService:SubscribeAsync(TOPIC, function()
				task.spawn(refresh)
			end)
		end)
		if not ok then
			warn(string.format(
				"[ReviewQueue] cross-server sync unavailable (%s) -- decisions land within %ds instead",
				tostring(err), REFRESH_INTERVAL))
		end
	end)

	task.spawn(function()
		while true do
			task.wait(REFRESH_INTERVAL)
			refresh()
		end
	end)
end

return ReviewQueue
