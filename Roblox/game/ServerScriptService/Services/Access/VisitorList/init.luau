--!strict
-- VisitorList
-- The shape of an owner's guest list, now that access is PER CITY rather than per account.
--
--   visitors = { ["1"] = { ["1234"] = "builder" }, ["3"] = { ["9"] = "visitor" } }
--
-- Slot ids outside, UserIds inside, both as STRINGS -- a DataStore round-trips a sparse
-- number-keyed table as an array and loses the holes.
--
-- LEGACY: `visitors` used to be one flat { [userId] = role } map covering every city the
-- owner had. Those grants still read as access to every slot, and the first per-city write
-- expands them into all MAX_SLOTS lists, so nothing is silently dropped and a revoke can
-- never be undone by a leftover account-wide grant.
--
-- Pure library: no state, no lifecycle, nothing happens on require.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CityRoles = require(ReplicatedStorage.Access.CityRoles)

-- Mirrors CitySlotService.MAX_SLOTS. Only used to expand a legacy flat list across every
-- slot that could exist; a wrong value here costs correctness of that migration alone.
local MAX_SLOTS = 5

export type Roles = { [string]: CityRoles.Role }
export type Stored = { [string]: Roles }

local VisitorList = {}

VisitorList.MAX_SLOTS = MAX_SLOTS

-- A slot id in any shape the callers have it (number from a remote, string from the store)
-- to the canonical string key -- or nil, which is the only refusal this module makes.
function VisitorList.key(slotId: any): string?
	local n = tonumber(slotId)
	if not n or n ~= math.floor(n) or n < 1 or n > MAX_SLOTS then return nil end
	return tostring(n)
end

-- The flat account-wide grants left over from the old shape. Empty for any record that has
-- been written since.
local function legacyRoles(stored: any): Roles
	local out: Roles = {}
	if typeof(stored) ~= "table" then return out end
	for k, v in pairs(stored) do
		if typeof(v) ~= "table" and tonumber(k) then
			local role = CityRoles.normalize(v)
			if role then out[tostring(k)] = role end
		end
	end
	return out
end

local function mergeSlot(into: Roles, slot: any)
	if typeof(slot) ~= "table" then return end
	for uid, raw in pairs(slot) do
		if tonumber(uid) then
			local role = CityRoles.normalize(raw)
			if role then into[tostring(uid)] = role end
		end
	end
end

-- Who may be in ONE city. A legacy grant sits underneath the city's own list until the
-- owner next edits it.
function VisitorList.forSlot(stored: any, slotId: any): Roles
	local out = legacyRoles(stored)
	local k = VisitorList.key(slotId)
	if k and typeof(stored) == "table" then
		mergeSlot(out, stored[k])
	end
	return out
end

-- Every role in every city of this owner, merged. The JOIN gate wants this: a reserved
-- server is per OWNER, so at join time there is no city yet to check against. The load
-- narrows it to the city that actually stood up -- see PlaceAccessService.setCityContext.
function VisitorList.anySlot(stored: any): Roles
	local out = legacyRoles(stored)
	if typeof(stored) == "table" then
		for k, v in pairs(stored) do
			if VisitorList.key(k) then mergeSlot(out, v) end
		end
	end
	return out
end

-- One grant (role) or revoke (nil), returning the WHOLE record to persist. Legacy entries
-- are expanded into every slot on the way through, so the record that comes out is purely
-- per-city. nil means the slot id was not one.
function VisitorList.set(stored: any, slotId: any, userId: number, role: CityRoles.Role?): Stored?
	local target = VisitorList.key(slotId)
	if not target then return nil end

	local carry = legacyRoles(stored)
	local out: Stored = {}
	for i = 1, MAX_SLOTS do
		local k = tostring(i)
		local roles: Roles = {}
		for uid, r in pairs(carry) do roles[uid] = r end
		if typeof(stored) == "table" then mergeSlot(roles, stored[k]) end
		if k == target then roles[tostring(userId)] = role end
		-- Empty slots are dropped rather than stored as {}: this record is read on every
		-- city boot and there is no reason to carry five empty tables around.
		if next(roles) then out[k] = roles end
	end
	return out
end

-- Still invited to ANY of this owner's cities? The reverse invite index (guest_<userId>) is
-- per owner, not per city, so an edge only drops when the last role is gone.
function VisitorList.invited(stored: any, userId: number): boolean
	return VisitorList.anySlot(stored)[tostring(userId)] ~= nil
end

return VisitorList
