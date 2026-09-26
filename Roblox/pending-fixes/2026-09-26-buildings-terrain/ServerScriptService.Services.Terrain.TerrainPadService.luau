--!strict
-- TerrainPadService
-- "Terrain follows buildings": when a building is placed, flattens the terrain
-- under its footprint to the building's base height, keeps a small flat verge
-- around it, then blends a shoulder out to natural ground. Reversible per-building
-- (refcounted) so removing a building restores the terrain it flattened within the
-- session. Pure server; writes through the authoritative Heightmap owned by
-- TerrainDataService. Mirrors TerrainGradeService, which does the same for roads.
--
-- Persistence saves the natural heightmap underneath these overlays, so buildings
-- can be deleted after a reload and still release terrain back to its pre-building shape.

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local TerrainConstants   = require(ReplicatedStorage.Terrain.TerrainConstants)
local TerrainDataService = require(ServerScriptService.Services.Terrain.TerrainDataService)

local TerrainPadService = {}

local FOOTPRINT_MARGIN = 0.75 -- enough overlap to avoid a voxel seam, not a broad platform
local FLAT_VERGE       = 1.5  -- keeps the building edge clean without widening the lot
-- A compact shoulder keeps a placed building grounded but does not turn every slope
-- into a large, circular terrace. The special case below joins any pad to an
-- already-near road bed, so every building category gets the same small-gap fill.
local SHOULDER_MIN     = 4.0
local SHOULDER_MAX     = 14.0
local MAX_GRADE        = 0.75 -- max rise/run of the ordinary lot edge (~37 deg)
local ROAD_JOIN_MAX    = 10.0 -- only bridge genuinely small road-to-lot gaps
-- Gap fill (see fillPair): lots whose plots come this close get the ground between them
-- graded from one lot's level to the other's.
local FILL_GAP_MAX     = 32.0
local FILL_PRIORITY    = 1    -- soft-claim rank of a fill; road banks and pad shoulders rank 0
local FACING_DOT       = -0.7 -- lots facing each other this squarely are across a street
-- TerrainDataService.getSurfaceY is the visible terrain height: raw height plus this
-- renderer offset. Writing the pad at baseY - RENDER_BULGE makes its visible surface
-- exactly meet the building base instead of leaving the former 0.5-stud air gap.
local PAVE_CLEARANCE   = TerrainConstants.RENDER_BULGE

local FLAG_LOCKED      = TerrainConstants.Flag.LOCKED
local FLAG_PAD_GRADED  = TerrainConstants.Flag.PAD_GRADED
local CORNERS_PER_AXIS = TerrainConstants.CORNERS_PER_AXIS
local MAX_CORNER       = CORNERS_PER_AXIS - 1
local cornerToWorld    = TerrainConstants.cornerToWorld
local worldToCorner    = TerrainConstants.worldToCorner
local rawToWorldY      = TerrainConstants.rawToWorldY
local worldYToRaw      = TerrainConstants.worldYToRaw

-- All corner bookkeeping (refcounts, original height/flags, overlap merging)
-- lives in the shared overlay ledger, so pads and road grades can claim the
-- same corners without clobbering each other.
local function ledger()
	return TerrainDataService.getOverlayLedger()
end

-- Finds an already-graded road beside a pad. Road corners remain owned by the road;
-- this only shapes the short unowned strip between the building and sidewalk.
local function nearestRoadY(led: any, gx: number, gz: number, wx: number, wz: number): (number?, number?)
	local cornerStep = math.abs(cornerToWorld(1) - cornerToWorld(0))
	local searchCells = math.max(1, math.ceil(ROAD_JOIN_MAX / math.max(cornerStep, 0.01)) + 1)
	local nearestDist = math.huge
	local nearestY: number? = nil

	for dz = -searchCells, searchCells do
		local rz = math.clamp(gz + dz, 0, MAX_CORNER)
		local roadZ = cornerToWorld(rz)
		for dx = -searchCells, searchCells do
			local rx = math.clamp(gx + dx, 0, MAX_CORNER)
			-- One prefix: segments and corner connectors both claim under "road:" now (see
			-- TerrainGradeService.ROAD_KIND -- splitting them was burying carriageways).
			-- Only the road's LOCKED bed is the road. Its soft bank runs 16 studs out at
			-- natural-ground height; joining to that on a hillside copied the bank's height
			-- into a locked strip that cut a trench through the next lot along.
			local raw = led:targetForOwnerKind(rx, rz, "road:", FLAG_LOCKED)
			if raw then
				local roadX = cornerToWorld(rx)
				local deltaX = roadX - wx
				local deltaZ = roadZ - wz
				local distance = math.sqrt(deltaX * deltaX + deltaZ * deltaZ)
				if distance < nearestDist then
					nearestDist = distance
					nearestY = rawToWorldY(raw)
				end
			end
		end
	end

	return nearestY, nearestDist
end

-- ---- neighbours: the pads that are standing, for the gap fill --------------------------
-- Every pad is registered with the footprint it was given, so a lot can find the lots beside
-- it and fill the ground between them (see fillPair). A 64-stud spatial hash keeps that
-- lookup local on a city of thousands of buildings.
-- fillWith: the pads this one wrote a gap fill toward. Those fills belong to THIS pad (its
-- "pad:<id>#fill" owner), so when one of those neighbours goes or moves, this pad redoes them.
-- px..fz: the pivot's position and flat axes as plain numbers, for the per-corner maths.
type PadRec = {
	pivot: CFrame, w: number, d: number, baseY: number, stage: number, fillWith: { [string]: boolean },
	px: number, pz: number, rx: number, rz: number, fx: number, fz: number,
}
local _pads: { [string]: PadRec } = {}
local _cells: { [number]: { [string]: boolean } } = {}
local CELL = 64

local function padBounds(rec: PadRec, grow: number): (number, number, number, number)
	local r = math.sqrt(rec.w * rec.w + rec.d * rec.d) * 0.5 + grow
	return rec.px - r, rec.px + r, rec.pz - r, rec.pz + r
end

local function forCells(x0: number, x1: number, z0: number, z1: number, fn: (number) -> ())
	for cz = math.floor(z0 / CELL), math.floor(z1 / CELL) do
		for cx = math.floor(x0 / CELL), math.floor(x1 / CELL) do
			fn(cz * 65536 + cx)
		end
	end
end

local function register(id: string, rec: PadRec)
	_pads[id] = rec
	local x0, x1, z0, z1 = padBounds(rec, 0)
	forCells(x0, x1, z0, z1, function(k)
		local c = _cells[k]
		if not c then
			c = {}
			_cells[k] = c
		end
		c[id] = true
	end)
end

local function unregister(id: string)
	local rec = _pads[id]
	if not rec then return end
	_pads[id] = nil
	local x0, x1, z0, z1 = padBounds(rec, 0)
	forCells(x0, x1, z0, z1, function(k)
		local c = _cells[k]
		if c then
			c[id] = nil
			if next(c) == nil then _cells[k] = nil end
		end
	end)
end

-- Ids of the pads whose plots come within `grow` studs of this one's bounds.
local function nearbyPads(id: string, rec: PadRec, grow: number): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	local x0, x1, z0, z1 = padBounds(rec, grow)
	forCells(x0, x1, z0, z1, function(k)
		local c = _cells[k]
		if not c then return end
		for other in c do
			if other ~= id and not seen[other] then
				seen[other] = true
				table.insert(out, other)
			end
		end
	end)
	table.sort(out) -- deterministic order: the same city pads the same way every time
	return out
end

-- Distance on XZ from a point to a pad's plot rectangle (0 inside it).
local function rectDist(rec: PadRec, x: number, z: number): number
	local dx, dz = x - rec.px, z - rec.pz
	local du = math.max(0, math.abs(dx * rec.rx + dz * rec.rz) - rec.w * 0.5)
	local dv = math.max(0, math.abs(dx * rec.fx + dz * rec.fz) - rec.d * 0.5)
	return math.sqrt(du * du + dv * dv)
end

local function rectCorners(rec: PadRec): { Vector3 }
	local out: { Vector3 } = {}
	local hw, hd = rec.w * 0.5, rec.d * 0.5
	for _, c in { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } } do
		local u, v = c[1] * hw, c[2] * hd
		table.insert(out, Vector3.new(rec.px + rec.rx * u + rec.fx * v, 0, rec.pz + rec.rz * u + rec.fz * v))
	end
	return out
end

-- Counter-clockwise convex hull on XZ (monotone chain).
local function hull(pts: { Vector3 }): { Vector3 }
	table.sort(pts, function(a, b) return a.X < b.X or (a.X == b.X and a.Z < b.Z) end)
	local function cross(o: Vector3, a: Vector3, b: Vector3): number
		return (a.X - o.X) * (b.Z - o.Z) - (a.Z - o.Z) * (b.X - o.X)
	end
	local lower: { Vector3 }, upper: { Vector3 } = {}, {}
	for _, p in pts do
		while #lower >= 2 and cross(lower[#lower - 1], lower[#lower], p) <= 0 do table.remove(lower) end
		table.insert(lower, p)
	end
	for i = #pts, 1, -1 do
		local p = pts[i]
		while #upper >= 2 and cross(upper[#upper - 1], upper[#upper], p) <= 0 do table.remove(upper) end
		table.insert(upper, p)
	end
	table.remove(lower)
	table.remove(upper)
	for _, p in upper do table.insert(lower, p) end
	return lower
end

local function inHull(h: { Vector3 }, x: number, z: number): boolean
	local n = #h
	if n < 3 then return false end
	for i = 1, n do
		local a, b = h[i], h[i % n + 1]
		if (b.X - a.X) * (z - a.Z) - (b.Z - a.Z) * (x - a.X) < -1e-6 then return false end
	end
	return true
end

-- The fill between two lots: the ground inside the convex hull of both plots that neither
-- plot covers -- the square left at the outside of a bend, the corner beside a junction, the
-- wedge behind lots on a curve, the strip between two backyards. It runs smoothly from one
-- lot's level to the other's instead of dipping to natural ground and back, so the space
-- between buildings reads as one piece of graded land (Cities: Skylines' "no floating, no
-- pits"). Two lots facing each other across a street are not neighbours: the street is
-- between them, not a gap -- caught by their facing, and for pads whose facing says nothing
-- (a school, a bus stop) by a road bed on the line between their centres. Writes the best
-- claim per corner into `out`.
type FillClaim = { gx: number, gz: number, raw: number, prio: number }
local function fillPair(led: any, a: PadRec, b: PadRec, out: { [number]: FillClaim }): boolean
	local sx, sz = b.px - a.px, b.pz - a.pz
	local ahead = sx * a.fx + sz * a.fz
	if a.fx * b.fx + a.fz * b.fz < FACING_DOT and ahead > 0 then return false end

	local ca, cb = rectCorners(a), rectCorners(b)
	local gap = math.huge
	for _, c in ca do gap = math.min(gap, rectDist(b, c.X, c.Z)) end
	for _, c in cb do gap = math.min(gap, rectDist(a, c.X, c.Z)) end
	if gap > FILL_GAP_MAX then return false end

	local steps = math.ceil(math.sqrt(sx * sx + sz * sz) / 2)
	for i = 1, steps - 1 do
		local f = i / steps
		local gx = math.clamp(math.floor(worldToCorner(a.px + sx * f) + 0.5), 0, MAX_CORNER)
		local gz = math.clamp(math.floor(worldToCorner(a.pz + sz * f) + 0.5), 0, MAX_CORNER)
		if led:lockedByOtherKind(gx, gz, "pad:") then return false end -- a road runs between them
	end

	local pts = table.clone(ca)
	for _, c in cb do table.insert(pts, c) end
	local h = hull(pts)
	local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
	for _, p in h do
		x0, x1 = math.min(x0, p.X), math.max(x1, p.X)
		z0, z1 = math.min(z0, p.Z), math.max(z1, p.Z)
	end
	local ya, yb = a.baseY - PAVE_CLEARANCE, b.baseY - PAVE_CLEARANCE
	local wrote = false
	for gz = math.clamp(math.floor(worldToCorner(z0)), 0, MAX_CORNER), math.clamp(math.ceil(worldToCorner(z1)), 0, MAX_CORNER) do
		local wz = cornerToWorld(gz)
		for gx = math.clamp(math.floor(worldToCorner(x0)), 0, MAX_CORNER), math.clamp(math.ceil(worldToCorner(x1)), 0, MAX_CORNER) do
			local wx = cornerToWorld(gx)
			if not inHull(h, wx, wz) then continue end
			local da, db = rectDist(a, wx, wz), rectDist(b, wx, wz)
			if da <= 0 or db <= 0 then continue end -- a plot's own pad covers it
			if led:lockedByOtherKind(gx, gz, "pad:") then continue end -- a road bed
			local t = da / (da + db)
			local y = ya + (yb - ya) * (t * t * (3 - 2 * t))
			-- The tighter pair wins a corner two fills both reach.
			local prio = FILL_PRIORITY + 1 / (1 + da + db)
			local key = gz * CORNERS_PER_AXIS + gx
			local cur = out[key]
			if not cur or cur.prio < prio then
				out[key] = { gx = gx, gz = gz, raw = worldYToRaw(y), prio = prio }
			end
			wrote = true
		end
	end
	return wrote
end

-- (Re)write one pad's gap fills, under its own owner so they can be redone without touching
-- the pad. They are soft claims that outrank the plain slopes; the lots' own locked ground
-- outranks them, so they only ever shape the land between lots. A site still under
-- construction joins in once its earthworks finish.
local function applyFills(led: any, id: string, rec: PadRec)
	local owner = "pad:" .. id .. "#fill"
	led:release(owner)
	rec.fillWith = {}
	if rec.stage < 1 then return end
	local fills: { [number]: FillClaim } = {}
	for _, other in nearbyPads(id, rec, FILL_GAP_MAX) do
		local o = _pads[other]
		if o and o.stage >= 1 and fillPair(led, rec, o, fills) then
			rec.fillWith[other] = true
		end
	end
	if next(fills) == nil then return end
	led:beginOwner(owner)
	for _, f in fills do
		led:write(owner, f.gx, f.gz, f.raw, FLAG_PAD_GRADED, f.prio)
	end
end

-- Write one pad (release first if it is already down), then its gap fills. `rec.stage` in
-- 0..1 is how far the earthworks have got: every corner sits that fraction of the way from
-- the ground it found to its finished height, so a construction site settles in a few steps
-- instead of snapping.
local function applyPad(led: any, id: string, rec: PadRec)
	local owner = "pad:" .. id
	led:release(owner)
	led:release(owner .. "#fill")
	led:beginOwner(owner)

	local pivot, worldWidth, worldDepth, baseY, stage = rec.pivot, rec.w, rec.d, rec.baseY, rec.stage
	local center = pivot.Position
	local right  = pivot.RightVector
	local fwd    = pivot.LookVector
	local halfW  = worldWidth * 0.5 + FOOTPRINT_MARGIN
	local halfD  = worldDepth * 0.5 + FOOTPRINT_MARGIN
	local plotHalfW, plotHalfD = worldWidth * 0.5, worldDepth * 0.5
	local reach  = FLAT_VERGE + SHOULDER_MAX -- widest a grade-limited shoulder can run
	local rad    = math.max(halfW, halfD) + reach

	local gxMin = math.clamp(math.floor(worldToCorner(center.X - rad)), 0, MAX_CORNER)
	local gxMax = math.clamp(math.ceil(worldToCorner(center.X + rad)), 0, MAX_CORNER)
	local gzMin = math.clamp(math.floor(worldToCorner(center.Z - rad)), 0, MAX_CORNER)
	local gzMax = math.clamp(math.ceil(worldToCorner(center.Z + rad)), 0, MAX_CORNER)

	for gz = gzMin, gzMax do
		local wz = cornerToWorld(gz)
		for gx = gxMin, gxMax do
			local wx = cornerToWorld(gx)
			local dx = wx - center.X
			local dz = wz - center.Z
			local u = dx * right.X + dz * right.Z -- signed distance along width
			local v = dx * fwd.X + dz * fwd.Z     -- signed distance along depth
			local du = math.max(0, math.abs(u) - halfW)
			local dv = math.max(0, math.abs(v) - halfD)
			local d = math.sqrt(du * du + dv * dv) -- 0 inside the footprint
			-- How deep this corner lies inside the plot (negative outside it). Where two lots'
			-- locked claims meet, the ledger gives the corner to the lot it is deeper in, so a
			-- lot's own ground always wins over the next lot's verge.
			local pu, pv = math.abs(u) - plotHalfW, math.abs(v) - plotHalfD
			local depthIn = if pu <= 0 and pv <= 0 then math.min(-pu, -pv)
				else -math.sqrt(math.max(pu, 0) ^ 2 + math.max(pv, 0) ^ 2)

			if d <= reach then
				-- Never fight terrain another system owns (e.g. a road's flat bed):
				-- skip corners locked by anything that is not a pad.
				if led:lockedByOtherKind(gx, gz, "pad:") then
					continue
				end

				-- Blend toward the CLOSER of original ground and the current heightmap (which
				-- already carries road beds and neighbouring pads). Blending only toward natural
				-- dug pits beside graded roads (the hanging-sidewalk gap) and tore steps between
				-- neighbouring lots padded at different heights.
				local naturalY = rawToWorldY(led:naturalRaw(gx, gz))
				local currentY = TerrainDataService.getHeightAt(wx, wz)
				local padY = baseY - PAVE_CLEARANCE
				local refY = if math.abs(currentY - padY) < math.abs(naturalY - padY) then currentY else naturalY
				local newY: number
				local flags: number
				local prio: number? = depthIn
				local joinedRoad = false

				if d > 0 and d <= ROAD_JOIN_MAX then
					local roadY, roadDistance = nearestRoadY(led, gx, gz, wx, wz)
					if roadY and roadDistance then
						local totalGap = d + roadDistance
						if totalGap <= ROAD_JOIN_MAX then
							-- A shallow, local join only for the small strip between a building
							-- and road. The road's locked corners are never overwritten.
							local t = d / math.max(totalGap, 0.01)
							local s = t * t * (3 - 2 * t)
							newY = padY + (roadY - padY) * s
							-- The infill owns its final shape so a later road regrade cannot
							-- pull this building-to-sidewalk transition back into a ditch.
							flags = FLAG_LOCKED + FLAG_PAD_GRADED
							joinedRoad = true
						end
					end
				end

				if not joinedRoad then
					if d <= FLAT_VERGE then
						-- Under the building + a narrow verge: dead flat just below the base, LOCKED.
						newY = padY
						flags = FLAG_LOCKED + FLAG_PAD_GRADED
					else
						-- Keep non-road edges compact. A building on a steep slope still blends,
						-- but it no longer creates the wide all-around terrace of the old pad.
						local shoulder = math.clamp(math.abs(refY - padY) / MAX_GRADE, SHOULDER_MIN, SHOULDER_MAX)
						if d > FLAT_VERGE + shoulder then continue end
						local t = (d - FLAT_VERGE) / shoulder
						local s = t * t * (3 - 2 * t)
						newY = padY + (refY - padY) * s
						flags = FLAG_PAD_GRADED
						prio = nil -- a plain slope: merges by min with the road banks, as before
					end
				end
				if stage < 1 then newY = currentY + (newY - currentY) * stage end
				led:write(owner, gx, gz, worldYToRaw(newY), flags, prio)
			end
		end
	end

	applyFills(led, id, rec)
end

-- Flatten the terrain under one building footprint. pivot is the horizontal footprint
-- frame: RightVector spans worldWidth and LookVector spans worldDepth (LookVector faces
-- the road). baseY is the height the pad is flattened to. `stage` (default 1) is how far
-- the earthworks have got; calling again with a later stage moves the ground on. Calling
-- again with the same arguments does nothing.
function TerrainPadService.padFootprint(id: string, pivot: CFrame, worldWidth: number, worldDepth: number, baseY: number, stage: number?)
	local led = ledger()
	if not led then return end
	local st = math.clamp(stage or 1, 0, 1)
	local cur = _pads[id]
	if cur and led:isOwned("pad:" .. id) and cur.stage == st and cur.baseY == baseY
		and cur.w == worldWidth and cur.d == worldDepth
		and (cur.pivot.Position - pivot.Position).Magnitude < 1e-3
		and cur.pivot.LookVector:Dot(pivot.LookVector) > 0.99999 then
		return -- already padded exactly like this
	end
	if cur then unregister(id) end
	local p, r, f = pivot.Position, pivot.RightVector, pivot.LookVector
	local rec: PadRec = {
		pivot = pivot, w = worldWidth, d = worldDepth, baseY = baseY, stage = st, fillWith = {},
		px = p.X, pz = p.Z, rx = r.X, rz = r.Z, fx = f.X, fz = f.Z,
	}
	register(id, rec)
	applyPad(led, id, rec)
	-- A pad that was already down and has changed: the fills its neighbours wrote toward it
	-- were shaped to the old one.
	if cur then
		for _, other in nearbyPads(id, rec, FILL_GAP_MAX + math.sqrt(cur.w * cur.w + cur.d * cur.d)) do
			local o = _pads[other]
			if o and o.fillWith[id] and led:isOwned("pad:" .. other) then applyFills(led, other, o) end
		end
	end
end

-- Release one building's pad. Corners drop back to their pre-pad height + flags once no
-- pad owns them, and the finished lots beside it redo their gap fills without it (a fill a
-- neighbour wrote toward this lot would otherwise outlive it).
function TerrainPadService.unpadFootprint(id: string)
	local led = ledger()
	if not led then return end
	led:release("pad:" .. id)
	led:release("pad:" .. id .. "#fill")
	local rec = _pads[id]
	if not rec then return end
	local near = nearbyPads(id, rec, FILL_GAP_MAX)
	unregister(id)
	for _, other in near do
		local o = _pads[other]
		if not o then continue end
		if not led:isOwned("pad:" .. other) then
			unregister(other) -- the ledger was cleared under it (a new map): nothing to redo
		elseif o.fillWith[id] then
			applyFills(led, other, o) -- only the ones that wrote a fill toward this pad
		end
	end
end

-- The earthworks stage a pad was last written at (nil = no pad).
function TerrainPadService.getStage(id: string): number?
	local rec = _pads[id]
	return rec and rec.stage
end

return TerrainPadService
