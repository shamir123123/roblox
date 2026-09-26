--!strict
-- RoadSerializer
-- The DataStore-safe road persistence FORMAT: converts between the network's segment
-- list (the RoadHistoryService.capture() / applySnapshot shape) and a flat, numeric
-- table. Straight segments (the common case) store 8 numbers -- the two placement
-- click points plus the two handle heights; handle XZ rebuilds as exact chord thirds,
-- which is precisely what placement constructs for a straight road. Curves store all
-- 12. Pure data transform -- no state, no lifecycle, no RoadService dependency; the
-- owning service wires serialize() to its history capture and deserialize() to its
-- snapshot replay. Stores SOURCE only (geometry + type + flags, defaults omitted);
-- ids and anything derived (turn permissions, zones) regenerate and re-anchor by
-- position on load.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)

local RoadSerializer = {}

-- Same straightness test as RoadService.placeFromRequest (0.05-stud perp offset),
-- but XZ-only: handle Y follows the terrain fit, so it never matches the chord and
-- is stored explicitly. Quantised thirds sit well inside the epsilon.
local STRAIGHT_EPS = 0.05
local function isStraightXZ(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3): boolean
	local chx, chz = p3.X - p0.X, p3.Z - p0.Z
	local len = math.sqrt(chx * chx + chz * chz)
	if len < 1e-3 then return false end
	local ux, uz = chx / len, chz / len
	local function off(p: Vector3): number
		local wx, wz = p.X - p0.X, p.Z - p0.Z
		local d = wx * ux + wz * uz
		local px, pz = wx - ux * d, wz - uz * d
		return math.sqrt(px * px + pz * pz)
	end
	return off(p1) <= STRAIGHT_EPS and off(p2) <= STRAIGHT_EPS
end

-- segments: full segment records (the RoadHistoryService.capture() shape).
function RoadSerializer.serialize(segments: { any }): { any }
	local out: { any } = {}
	for _, s in segments do
		local p: { number }
		if isStraightXZ(s.p0, s.p1, s.p2, s.p3) then
			p = {
				s.p0.X, s.p0.Y, s.p0.Z,
				s.p3.X, s.p3.Y, s.p3.Z,
				s.p1.Y, s.p2.Y,
			}
		else
			p = {
				s.p0.X, s.p0.Y, s.p0.Z,
				s.p1.X, s.p1.Y, s.p1.Z,
				s.p2.X, s.p2.Y, s.p2.Z,
				s.p3.X, s.p3.Y, s.p3.Z,
			}
		end
		table.insert(out, {
			p = p,
			t = s.roadType,
			-- Segment id: NOT derived. Plot groups persist the id of the road they front,
			-- so ids must survive the round trip or every plot rebinds to a different road.
			i = s.id,
			-- Street name, stored only when a player renamed it: auto names regenerate
			-- from geometry, so saving them would just pin a derived value.
			n = s.name,
			vm = s.vMode,
			cs = if s.constSlope then true else nil,
			rb = if s.isRoundabout then true else nil,
			ri = s.roundaboutId,
			rc = if s.isRoundabout and s.roundaboutCenter
				then { s.roundaboutCenter.X, s.roundaboutCenter.Y, s.roundaboutCenter.Z }
				else nil,
			rr = s.roundaboutRadius,
			rp = s.roundaboutPreset,
			-- Node-tool junction shaping, per end. Source data (the player set it), and
			-- not derivable: nodes are rebuilt from geometry on load and carry no identity.
			sc = s.startCorner,
			ec = s.endCorner,
			so = s.startOffset,
			eo = s.endOffset,
			sf = if s.startFlat then true else nil,
			ef = if s.endFlat then true else nil,
		})
	end
	return out
end

-- Every stored coordinate must be a real, finite, on-map number: a NaN/inf smuggled
-- into a save (or produced by a corrupted blob) would otherwise flow straight into the
-- restore path, which -- unlike interactive placement -- runs no validate() gate.
local MAX_COORD = 1e6
-- Same cap the rename remote enforces; a blob claiming more is corrupt or forged.
local MAX_NAME_LEN = 40
-- Node-tool shaping is clamped to the SAME bounds the live edit path enforces, so a
-- hand-edited blob can only ask for a junction the tool could also have produced.
local CORNER_MIN, CORNER_MAX = RoadConstants.NODE_CORNER_MIN, RoadConstants.NODE_CORNER_MAX
local OFFSET_MIN, OFFSET_MAX = RoadConstants.NODE_OFFSET_MIN, RoadConstants.NODE_OFFSET_MAX
local function shapingValue(v: any, lo: number, hi: number): number?
	if typeof(v) ~= "number" or v ~= v then return nil end
	return math.clamp(v, lo, hi)
end
local function finiteNums(p: { any }, n: number): boolean
	for i = 1, n do
		local v = p[i]
		if typeof(v) ~= "number" or v ~= v or math.abs(v) > MAX_COORD then
			return false
		end
	end
	return true
end

-- entries: a serialize() payload. Returns a snapshot (the applySnapshot shape),
-- skipping any malformed entry.
function RoadSerializer.deserialize(entries: { any }): { any }
	local snap: { any } = {}
	for _, e in entries do
		local p = if typeof(e) == "table" then e.p else nil
		if typeof(p) == "table" and (#p == 12 or #p == 8) and typeof(e.t) == "string" and finiteNums(p, #p) then
			local p0, p1, p2, p3
			if #p == 8 then
				-- Straight format: {x0,y0,z0, x3,y3,z3, y1,y2}; handle XZ = chord thirds.
				p0 = Vector3.new(p[1], p[2], p[3])
				p3 = Vector3.new(p[4], p[5], p[6])
				p1 = Vector3.new(p0.X + (p3.X - p0.X) / 3, p[7], p0.Z + (p3.Z - p0.Z) / 3)
				p2 = Vector3.new(p0.X + (p3.X - p0.X) * 2 / 3, p[8], p0.Z + (p3.Z - p0.Z) * 2 / 3)
			else
				p0 = Vector3.new(p[1], p[2], p[3])
				p1 = Vector3.new(p[4], p[5], p[6])
				p2 = Vector3.new(p[7], p[8], p[9])
				p3 = Vector3.new(p[10], p[11], p[12])
			end
			table.insert(snap, {
				-- Ids are load-bearing (plot groups reference them). A blob is untrusted, so
				-- only a sane positive integer passes; anything else falls back to auto-assign.
				id = if typeof(e.i) == "number" and e.i == e.i and e.i >= 1 and e.i < 1e7 and e.i % 1 == 0 then e.i else nil,
				p0 = p0,
				p1 = p1,
				p2 = p2,
				p3 = p3,
				roadType = e.t,
				name = if typeof(e.n) == "string" and #e.n > 0 and #e.n <= MAX_NAME_LEN then e.n else nil,
				vMode = e.vm,
				constSlope = if e.cs then true else nil,
				isRoundabout = if e.rb then true else nil,
				roundaboutId = e.ri,
				roundaboutCenter = if typeof(e.rc) == "table" and #e.rc == 3 and finiteNums(e.rc, 3)
					then Vector3.new(e.rc[1], e.rc[2], e.rc[3])
					else nil,
				roundaboutRadius = if typeof(e.rr) == "number" and e.rr == e.rr then e.rr else nil,
				roundaboutPreset = if typeof(e.rp) == "string" and #e.rp <= 24 then e.rp else nil,
				startCorner = shapingValue(e.sc, CORNER_MIN, CORNER_MAX),
				endCorner   = shapingValue(e.ec, CORNER_MIN, CORNER_MAX),
				startOffset = shapingValue(e.so, OFFSET_MIN, OFFSET_MAX),
				endOffset   = shapingValue(e.eo, OFFSET_MIN, OFFSET_MAX),
				-- Flat is a plain flag: anything truthy in the blob means flat, absent means
				-- the default (the plate follows the arms' grades).
				startFlat   = if e.sf then true else nil,
				endFlat     = if e.ef then true else nil,
			})
		end
	end
	return snap
end

return RoadSerializer
