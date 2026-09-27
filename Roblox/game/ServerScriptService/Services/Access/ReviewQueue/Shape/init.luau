--!strict
-- ReviewQueue.Shape
-- The shape guard every review record passes through on its way out of the DataStore,
-- and the reason clamp. Split out of ReviewQueue for one reason: ReviewQueue must refuse
-- to load off the server, and `RunService:IsServer()` is FALSE in Studio's Edit mode --
-- so anything behind that guard cannot be tested without starting a server. This half is
-- pure, so it can be.
--
-- No side effects on require, no DataStore, no services. Keep it that way.

local Shape = {}

Shape.MAX_REASON = 140

export type Row = {
	bpId: string,
	ownerId: number,
	ownerName: string,
	name: string,
	cat: string,
	at: number,
	by: number?,
	reason: string?,
	-- Why this row is in the rejected record: "rejected" (never published), "takedown"
	-- (a moderator pulled it after approval) or "withdrawn" (its author stopped sharing).
	-- Only a takedown REVOKES it -- see ReviewQueue.isRevoked.
	action: string?,
}
export type Record = { [string]: Row }

-- One reviewer decision, kept forever (up to the cap) even after the item it describes is
-- taken down and re-approved. Unlike the records above this is an ARRAY, newest first: the
-- same creation can appear many times, so a map keyed by id would overwrite its own history.
export type LogEntry = {
	at: number,
	action: string,
	bpId: string,
	name: string,
	ownerId: number,
	ownerName: string,
	by: number,
	byName: string,
	reason: string?,
}

-- Everything out of the store is untrusted shape: a half-written row, a record from an
-- older layout, or one whose fields have gone missing. Rebuild a known-good table rather
-- than handing the raw one to a curator's screen.
--
-- A row with no NAME is dropped outright -- the name is the only thing a curator reads to
-- judge a submission, so a nameless row is unreviewable. Every other missing field is
-- repaired, because losing someone's build over an absent timestamp would be absurd.
function Shape.sanitize(raw: any, cap: number): Record
	local out: Record = {}
	if typeof(raw) ~= "table" then return out end

	local kept = 0
	for key, value in raw do
		if kept >= cap then break end
		if typeof(key) == "string" and key ~= "" and typeof(value) == "table"
			and typeof(value.name) == "string" then
			out[key] = {
				bpId      = key,
				ownerId   = tonumber(value.ownerId) or 0,
				ownerName = if typeof(value.ownerName) == "string" then value.ownerName else "",
				name      = value.name,
				cat       = if typeof(value.cat) == "string" then value.cat else "Prop",
				at        = tonumber(value.at) or 0,
				by        = tonumber(value.by),
				reason    = if typeof(value.reason) == "string" then value.reason else nil,
				action    = if typeof(value.action) == "string" then value.action else nil,
			}
			kept += 1
		end
	end

	return out
end

-- An entry with no action or no subject is not a decision anyone can read, so it is
-- dropped; everything else is repaired. Order is preserved -- the caller writes newest
-- first and trims the tail, so position IS the chronology.
function Shape.sanitizeLog(raw: any, cap: number): { LogEntry }
	local out: { LogEntry } = {}
	if typeof(raw) ~= "table" then return out end
	for _, e in raw do
		if #out >= cap then break end
		if typeof(e) == "table" and typeof(e.action) == "string" and typeof(e.bpId) == "string" then
			table.insert(out, {
				at        = tonumber(e.at) or 0,
				action    = e.action,
				bpId      = e.bpId,
				name      = if typeof(e.name) == "string" then e.name else "",
				ownerId   = tonumber(e.ownerId) or 0,
				ownerName = if typeof(e.ownerName) == "string" then e.ownerName else "",
				by        = tonumber(e.by) or 0,
				byName    = if typeof(e.byName) == "string" then e.byName else "",
				reason    = if typeof(e.reason) == "string" then e.reason else nil,
			})
		end
	end
	return out
end

function Shape.clampReason(raw: any): string?
	if typeof(raw) ~= "string" then return nil end
	local trimmed = (string.gsub(string.gsub(raw, "^%s+", ""), "%s+$", ""))
	if trimmed == "" then return nil end
	return string.sub(trimmed, 1, Shape.MAX_REASON)
end

function Shape.count(record: Record): number
	local n = 0
	for _ in record do n += 1 end
	return n
end

-- Newest first: a curator works the top of the list, so the oldest submission must not be
-- the one that scrolls off the bottom.
function Shape.sortedRows(record: Record): { Row }
	local out: { Row } = {}
	for _, row in record do table.insert(out, row) end
	table.sort(out, function(a, b)
		if a.at ~= b.at then return a.at > b.at end
		return a.bpId < b.bpId
	end)
	return out
end

-- The id of the oldest row, for capped records that evict rather than refuse.
function Shape.oldestId(record: Record): string?
	local oldestId: string? = nil
	local oldestAt = math.huge
	for id, row in record do
		if row.at < oldestAt then oldestId, oldestAt = id, row.at end
	end
	return oldestId
end

return Shape
