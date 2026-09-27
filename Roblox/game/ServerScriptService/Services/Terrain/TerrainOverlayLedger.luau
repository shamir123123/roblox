--!strict
-- TerrainOverlayLedger
-- Shared bookkeeping for systems that reshape terrain under things they own:
-- roads grade (TerrainGradeService), buildings pad (TerrainPadService). One
-- corner can be claimed by many owners at once; the ledger merges their claims
-- deterministically and restores the original ground when the last owner
-- releases.
--
-- Merge rules (order-independent):
--   height = min(locked owners of the highest priority), else min(soft owners of the
--            highest priority)
--   flags  = origFlags | OR(owner contributions) -- locked while ANY owner locks
-- A locked slab is a hard surface. It must not be pulled down by another
-- system's soft shoulder in the same corner.
-- Priority is optional per claim. Roads never pass one, so they merge exactly as before:
-- a locked claim without one ranks above every locked claim that has one, and a soft
-- claim without one ranks 0. A pad's locked ground passes how deep the corner lies
-- inside its own plot (negative outside it), so between two buildings each corner
-- belongs to the lot it is in: the next lot's edge can no longer cut a trench into this
-- one. A pad's soft gap fill passes a positive priority, so it beats the plain slopes
-- (road banks, pad shoulders) there without locking the ground against a later road.
-- Original height/flags are snapshotted when the first owner claims a corner;
-- releases with surviving owners recompute the merge from the survivors.
--
-- Owner keys are strings namespaced by kind: "seg:<id>", "conn:<nodeId>",
-- "pad:<lotId>". Pure data structure: no lifecycle, no side effects on
-- require. The single authoritative instance is owned by TerrainDataService.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Terrain.TerrainConstants)

local CORNERS_PER_AXIS = Constants.CORNERS_PER_AXIS
local FLAG_LOCKED = Constants.Flag.LOCKED

local TerrainOverlayLedger = {}
TerrainOverlayLedger.__index = TerrainOverlayLedger

type CornerEntry = {
	origRaw: number,
	origFlags: number,
	targets: { [string]: number }, -- per-owner target raw height
	flags: { [string]: number }, -- per-owner flag contribution
	prio: { [string]: number }, -- per-owner merge priority (absent: top if locked, 0 if soft)
	count: number,
}

export type TerrainOverlayLedger = typeof(setmetatable(
	{} :: {
		_hm: any,
		_owners: { [string]: { number } }, -- corner keys touched, per owner
		_corners: { [number]: CornerEntry },
	},
	TerrainOverlayLedger
))

local function cornerKey(gx: number, gz: number): number
	return gz * CORNERS_PER_AXIS + gx
end

local function decodeKey(key: number): (number, number)
	local gz = math.floor(key / CORNERS_PER_AXIS)
	return key - gz * CORNERS_PER_AXIS, gz
end

function TerrainOverlayLedger.new(hm: any): TerrainOverlayLedger
	return setmetatable({
		_hm = hm,
		_owners = {},
		_corners = {},
	}, TerrainOverlayLedger)
end

-- Recompute and write one corner's effective height/flags from all its owners.
function TerrainOverlayLedger._apply(self: TerrainOverlayLedger, key: number, e: CornerEntry, markDirty: boolean?)
	local effRaw = math.huge
	local effPrio = -math.huge
	for owner, raw in e.targets do
		local flags = e.flags[owner] or 0
		if bit32.band(flags, FLAG_LOCKED) ~= 0 then
			local p = e.prio[owner] or math.huge
			if p > effPrio or (p == effPrio and raw < effRaw) then
				effPrio, effRaw = p, raw
			end
		end
	end
	if effRaw == math.huge then
		for owner, raw in e.targets do
			local p = e.prio[owner] or 0
			if p > effPrio or (p == effPrio and raw < effRaw) then
				effPrio, effRaw = p, raw
			end
		end
	end
	local effFlags = e.origFlags
	for _, f in e.flags do
		effFlags = bit32.bor(effFlags, f)
	end
	local gx, gz = decodeKey(key)
	if markDirty == false then
		self._hm:setCornerNoDirty(gx, gz, effRaw)
	else
		self._hm:setCorner(gx, gz, effRaw)
	end
	self._hm:setFlags(gx, gz, effFlags)
end

function TerrainOverlayLedger.isOwned(self: TerrainOverlayLedger, owner: string): boolean
	return self._owners[owner] ~= nil
end

-- Claim an owner slot. Returns false (and does nothing) if the owner already
-- holds a claim -- callers use this for idempotence.
function TerrainOverlayLedger.beginOwner(self: TerrainOverlayLedger, owner: string): boolean
	if self._owners[owner] then
		return false
	end
	self._owners[owner] = {}
	return true
end

-- Original (pre-overlay) raw height of a corner. Shoulder blends use this so
-- they blend toward true natural ground, never toward another owner's bed.
function TerrainOverlayLedger.naturalRaw(self: TerrainOverlayLedger, gx: number, gz: number): number
	local e = self._corners[cornerKey(gx, gz)]
	return if e then e.origRaw else self._hm:getCorner(gx, gz)
end

-- True when this corner is held LOCKED by an owner of a different kind (kind =
-- owner-key prefix, e.g. "pad:"), or by something outside the ledger entirely.
function TerrainOverlayLedger.lockedByOtherKind(self: TerrainOverlayLedger, gx: number, gz: number, ownKindPrefix: string): boolean
	local e = self._corners[cornerKey(gx, gz)]
	if not e then
		return self._hm:isLocked(gx, gz)
	end
	for owner, f in e.flags do
		if bit32.band(f, FLAG_LOCKED) ~= 0 and string.sub(owner, 1, #ownKindPrefix) ~= ownKindPrefix then
			return true
		end
	end
	return bit32.band(e.origFlags, FLAG_LOCKED) ~= 0
end

-- Target height claimed by an owner kind at this corner. Pads use this to make a
-- short, road-facing join without changing the road's locked terrain. With
-- `requireFlags`, only a claim carrying all of those flag bits counts (a road's
-- LOCKED bed, not the soft bank that blends it back to natural ground).
function TerrainOverlayLedger.targetForOwnerKind(self: TerrainOverlayLedger, gx: number, gz: number, kindPrefix: string, requireFlags: number?): number?
	local e = self._corners[cornerKey(gx, gz)]
	if not e then return nil end
	for owner, raw in e.targets do
		if string.sub(owner, 1, #kindPrefix) == kindPrefix
			and (requireFlags == nil or bit32.band(e.flags[owner] or 0, requireFlags) == requireFlags) then
			return raw
		end
	end
	return nil
end

-- Record `owner`'s claim on a corner and apply the merged result. Requires a
-- prior beginOwner. Writing the same corner twice for one owner just updates
-- that owner's target. `priority` ranks this claim against others of the same kind
-- (locked or soft; see the merge rules at the top). Leave it out to rank with the roads.
function TerrainOverlayLedger.write(self: TerrainOverlayLedger, owner: string, gx: number, gz: number, targetRaw: number, flagBits: number, priority: number?)
	local touched = self._owners[owner]
	if not touched then
		error(`[TerrainOverlayLedger] write before beginOwner for {owner}`)
	end
	local key = cornerKey(gx, gz)
	local e = self._corners[key]
	if not e then
		e = {
			origRaw = self._hm:getCorner(gx, gz),
			origFlags = self._hm:getFlags(gx, gz),
			targets = {},
			flags = {},
			prio = {},
			count = 0,
		}
		self._corners[key] = e
	end
	if e.targets[owner] == nil then
		e.count += 1
		table.insert(touched, key)
	end
	e.targets[owner] = targetRaw
	e.flags[owner] = flagBits
	e.prio[owner] = priority
	self:_apply(key, e)
end

-- Release every corner `owner` claimed. Corners with surviving owners are
-- re-merged from the survivors; corners with none restore original ground.
function TerrainOverlayLedger.release(self: TerrainOverlayLedger, owner: string)
	local touched = self._owners[owner]
	if not touched then
		return
	end
	self._owners[owner] = nil
	for _, key in touched do
		local e = self._corners[key]
		if e and e.targets[owner] ~= nil then
			e.targets[owner] = nil
			e.flags[owner] = nil
			e.prio[owner] = nil
			e.count -= 1
			if e.count <= 0 then
				self._corners[key] = nil
				local gx, gz = decodeKey(key)
				self._hm:setFlags(gx, gz, e.origFlags)
				self._hm:setCorner(gx, gz, e.origRaw)
			else
				self:_apply(key, e)
			end
		end
	end
end

-- Runs a callback while the heightmap buffers expose the original terrain under
-- every active overlay. Used by persistence so roads/buildings reapply from their
-- saved objects after load instead of baking their flattened terrain into the save.
function TerrainOverlayLedger.withNaturalHeightmap(self: TerrainOverlayLedger, fn: () -> any): any
	local keys = {}
	for key in self._corners do
		table.insert(keys, key)
	end
	if #keys == 0 then
		return fn()
	end

	for _, key in keys do
		local e = self._corners[key]
		if e then
			local gx, gz = decodeKey(key)
			self._hm:setFlags(gx, gz, e.origFlags)
			self._hm:setCornerNoDirty(gx, gz, e.origRaw)
		end
	end

	local ok, result = pcall(fn)

	for _, key in keys do
		local e = self._corners[key]
		if e then
			self:_apply(key, e, false)
		end
	end

	if not ok then
		error(result, 0)
	end
	return result
end

-- Drop all claims without restoring ground. Used when the heightmap itself is
-- regenerated (new city / load): the snapshot heights are no longer valid.
function TerrainOverlayLedger.clear(self: TerrainOverlayLedger)
	table.clear(self._owners)
	table.clear(self._corners)
end

return TerrainOverlayLedger
