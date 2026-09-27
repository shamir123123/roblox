--!strict
-- AddressBook
-- Street identity for the whole city, derived from road geometry alone: which
-- segments form one street, what that street is called, and what number a point
-- beside it gets. Pure library -- no state, no lifecycle, no side effects on require.
--
-- Client and server build the SAME index from the same segment list, so an
-- auto-generated name never crosses the wire. Only a player's rename is stored,
-- as Segment.name, which rides the normal segment replication + save format.
-- Iteration is id-sorted for that reason: both sides must agree exactly.
--
-- A chain follows the straightest continuation of the same road class through a
-- junction. That is deliberate: Cities: Skylines 2's standing complaint is that a
-- street name "turns" onto whatever corridor the game picked, and the straightest
-- arm is what a person means by "the same street".

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RoadConstants   = require(ReplicatedStorage.Road.RoadConstants)
local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)

local AddressBook = {}

export type Seg = {
	id: number,
	startNode: number,
	endNode: number,
	roadType: string,
	p0: Vector3,
	p1: Vector3,
	p2: Vector3,
	p3: Vector3,
	name: string?,
}

export type Index = {
	segs: { [number]: Seg },
	-- segment id -> street key (the lowest segment id in its chain)
	keyOf: { [number]: number },
	-- street key -> segment ids in order along the street
	chains: { [number]: { number } },
	-- street key -> display name
	names: { [number]: string },
	-- segment id -> true when p0->p3 runs WITH the street direction
	dirs: { [number]: boolean },
}

-- Addressing ordinances carry ONE name along a continuous roadway: "if the road is
-- continuous, do not change names at an intersection, a curve" (Steuben County NY
-- roadway naming standards). A name changes where the road stops being continuous -- an
-- obvious change of direction, or an interruption -- and the change lands at an
-- intersection, never mid-block. Two thresholds fall out of that:

-- At a JUNCTION, where there is a choice of arms, ~60 degrees. Past that the arm is
-- a turn, not the same street, and the name ends here.
local CONTINUE_DOT = 0.5
-- At a BEND, where there is only one arm to take, ~120 degrees. A road that turns a
-- corner is still one road with one name; only a fold back on itself is not.
local BEND_DOT = -0.5
-- Studs of frontage per address number pair. Two numbers (one per side) per step,
-- so a block of ~15 houses spans about 30 numbers -- the usual city convention.
local NUMBER_SPACING = 12 * RoadConstants.WORLD_SCALE

local ROOTS = {
	"Bluejay", "Robin", "Sparrow", "Finch", "Heron", "Falcon", "Wren", "Lark", "Raven", "Swift",
	"Magpie", "Oriole", "Kestrel", "Plover", "Tanager", "Warbler", "Crane", "Egret", "Osprey", "Quail",
	"Linnet", "Martin", "Teal", "Curlew", "Dove", "Hawk", "Ibis", "Junco", "Kite", "Maple",
	"Cedar", "Birch", "Willow", "Aspen", "Alder", "Rowan", "Linden", "Hazel", "Elm", "Ash",
	"Harbour", "Mill", "Foundry", "Kiln", "Quarry", "Orchard", "Meadow", "Bridgeway", "Chapel", "Market",
}

local SUFFIX: { [string]: { string } } = {
	arterial = { "Avenue", "Boulevard", "Parkway" },
	local_   = { "Street", "Road", "Drive", "Way", "Lane", "Court", "Terrace", "Crescent" },
	alley    = { "Alley", "Mews", "Row" },
	rail     = { "Line" },
}

local function flatUnit(v: Vector3): Vector3
	local x, z = v.X, v.Z
	local m = math.sqrt(x * x + z * z)
	if m < 1e-4 then return Vector3.xAxis end
	return Vector3.new(x / m, 0, z / m)
end

local function hash32(n: number): number
	n = math.floor(n) % 2147483647
	return (n * 2654435761) % 2147483647
end

-- Which suffix family a road type belongs to. Drives the generated name and, more
-- importantly, where one street ends and the next begins: an avenue never becomes
-- an alley halfway along.
function AddressBook.classOf(roadType: string): string
	local spec = RoadTypeCatalog.getOrDefault(roadType)
	if spec.isRail then return "rail" end
	if spec.isHighway then return "highway" end
	if string.find(spec.name, "Alley") then return "alley" end
	if (spec.laneCount or 2) >= 4 then return "arterial" end
	return "local_"
end

-- The name a street gets when nobody has renamed it. Deterministic in the street
-- key, so it survives a rejoin, a reload and the client/server split unchanged.
function AddressBook.autoName(key: number, roadType: string): string
	local class = AddressBook.classOf(roadType)
	local h = hash32(key + 7)
	if class == "highway" then
		-- Highways are numbered, not named -- "Highway 27", the way real ones are.
		return "Highway " .. tostring(10 + h % 90)
	end
	local suffixes = SUFFIX[class] or SUFFIX.local_
	local root = ROOTS[(h % #ROOTS) + 1]
	return root .. " " .. suffixes[(math.floor(h / 97) % #suffixes) + 1]
end

-- Group every segment into streets. `segments` is any list or id-keyed map of
-- segment records (DataCache's client copies and RoadNetwork's live ones both fit).
function AddressBook.buildIndex(segments: any): Index
	local segs: { [number]: Seg } = {}
	local byNode: { [number]: { number } } = {}
	local ids: { number } = {}

	for _, s in segments do
		if typeof(s) ~= "table" or typeof(s.id) ~= "number" then continue end
		if typeof(s.startNode) ~= "number" or typeof(s.endNode) ~= "number" then continue end
		segs[s.id] = s
		table.insert(ids, s.id)
		for _, n in { s.startNode, s.endNode } do
			local bucket = byNode[n]
			if not bucket then
				bucket = {}
				byNode[n] = bucket
			end
			table.insert(bucket, s.id)
		end
	end
	table.sort(ids)

	-- Direction the segment heads when you leave `node` along it.
	local function outDir(s: Seg, node: number): Vector3
		if node == s.startNode then return flatUnit(s.p1 - s.p0) end
		return flatUnit(s.p2 - s.p3)
	end

	local function otherNode(s: Seg, node: number): number
		return if node == s.startNode then s.endNode else s.startNode
	end

	local function continuation(s: Seg, node: number, class: string, taken: { [number]: boolean }): Seg?
		local arriving = -outDir(s, node)
		local best: Seg? = nil
		local bestDot = -math.huge
		-- Counted over every same-class arm, taken or not: what makes this a junction
		-- rather than a bend is the road layout, not how far the walk has got.
		local arms = 0
		for _, cid in byNode[node] or {} do
			if cid == s.id then continue end
			local c = segs[cid]
			if not c or AddressBook.classOf(c.roadType) ~= class then continue end
			arms += 1
			if taken[cid] then continue end
			local d = outDir(c, node):Dot(arriving)
			if d > bestDot then
				best, bestDot = c, d
			end
		end
		if not best then return nil end
		local floor = if arms == 1 then BEND_DOT else CONTINUE_DOT
		return if bestDot > floor then best else nil
	end

	local index: Index = { segs = segs, keyOf = {}, chains = {}, names = {}, dirs = {} }
	local taken: { [number]: boolean } = {}

	for _, id in ids do
		if taken[id] then continue end
		local seed = segs[id]
		local class = AddressBook.classOf(seed.roadType)
		local chain = { id }
		taken[id] = true
		index.dirs[id] = true

		local cur, node = seed, seed.endNode
		while true do
			local nxt = continuation(cur, node, class, taken)
			if not nxt then break end
			taken[nxt.id] = true
			index.dirs[nxt.id] = node == nxt.startNode
			table.insert(chain, nxt.id)
			node = otherNode(nxt, node)
			cur = nxt
		end

		cur, node = seed, seed.startNode
		while true do
			local nxt = continuation(cur, node, class, taken)
			if not nxt then break end
			taken[nxt.id] = true
			-- Prepended: this piece ENDS where the street continues, so p0->p3 runs
			-- with the street when `node` is its end node.
			index.dirs[nxt.id] = node == nxt.endNode
			table.insert(chain, 1, nxt.id)
			node = otherNode(nxt, node)
			cur = nxt
		end

		local key = chain[1]
		for _, cid in chain do
			if cid < key then key = cid end
		end

		-- A rename is stored on every segment of the chain, but a road drawn onto a
		-- renamed street joins it unnamed -- so one named piece names the whole street.
		local override: string? = nil
		local overrideId = math.huge
		for _, cid in chain do
			local s = segs[cid]
			if typeof(s.name) == "string" and s.name ~= "" and cid < overrideId then
				override, overrideId = s.name, cid
			end
		end

		index.chains[key] = chain
		index.names[key] = override or AddressBook.autoName(key, seed.roadType)
		for _, cid in chain do
			index.keyOf[cid] = key
		end
	end

	return index
end

function AddressBook.keyOf(index: Index, segId: number): number?
	return index.keyOf[segId]
end

function AddressBook.nameOf(index: Index, segId: number): string?
	local key = index.keyOf[segId]
	return if key then index.names[key] else nil
end

function AddressBook.chainOf(index: Index, segId: number): { number }
	local key = index.keyOf[segId]
	return if key then index.chains[key] else {}
end

-- Endpoints of a segment in street order (p0->p3 flipped when the piece was laid
-- against the direction the street runs).
local function orientedEnds(index: Index, segId: number): (Vector3, Vector3)
	local s = index.segs[segId]
	if index.dirs[segId] == false then
		return s.p3, s.p0
	end
	return s.p0, s.p3
end

-- House number for a point beside the road: distance along the street sets the
-- magnitude, the side sets odd vs even. Chord distance, not arc length -- a curve
-- shortens the count by a few percent and nobody measures their own street.
function AddressBook.numberAt(index: Index, segId: number, pos: Vector3): number
	local chain = AddressBook.chainOf(index, segId)
	local dist = 0
	local side = 1
	for _, cid in chain do
		local a, b = orientedEnds(index, cid)
		local dx, dz = b.X - a.X, b.Z - a.Z
		local len = math.sqrt(dx * dx + dz * dz)
		if cid == segId then
			local rx, rz = pos.X - a.X, pos.Z - a.Z
			local ux, uz = 1, 0
			if len > 1e-4 then
				ux, uz = dx / len, dz / len
			end
			dist += math.clamp(rx * ux + rz * uz, 0, len)
			side = if (ux * rz - uz * rx) >= 0 then 1 else 0
			break
		end
		dist += len
	end
	return 2 * math.floor(dist / NUMBER_SPACING) + side + 1
end

-- "42 Bluejay Street". nil when the segment is not in the index.
function AddressBook.addressAt(index: Index, segId: number, pos: Vector3): string?
	local name = AddressBook.nameOf(index, segId)
	if not name then return nil end
	return tostring(AddressBook.numberAt(index, segId, pos)) .. " " .. name
end

-- Nearest road to a world point, by distance to the segment chord. Linear scan:
-- it answers one click or one placement, never a per-frame query.
function AddressBook.nearestSegmentId(index: Index, pos: Vector3, maxDist: number?): number?
	local best: number? = nil
	local bestD = maxDist or math.huge
	for id, s in index.segs do
		local dx, dz = s.p3.X - s.p0.X, s.p3.Z - s.p0.Z
		local len2 = dx * dx + dz * dz
		local rx, rz = pos.X - s.p0.X, pos.Z - s.p0.Z
		local t = if len2 > 1e-6 then math.clamp((rx * dx + rz * dz) / len2, 0, 1) else 0
		local ox, oz = rx - dx * t, rz - dz * t
		local d = math.sqrt(ox * ox + oz * oz)
		if d < bestD then
			best, bestD = id, d
		end
	end
	return best
end

-- The address of any world point: finds its road first. `maxDist` rejects points
-- with no road near them rather than inventing a street for them.
function AddressBook.addressOfPoint(index: Index, pos: Vector3, maxDist: number?): string?
	local segId = AddressBook.nearestSegmentId(index, pos, maxDist)
	return if segId then AddressBook.addressAt(index, segId, pos) else nil
end

return AddressBook
