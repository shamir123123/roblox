--!strict
-- Buffer-backed heightmap. Pure data structure: no lifecycle, no side effects on
-- require. The authoritative instance lives in TerrainDataService; the client
-- prediction layer instantiates its own. Heights are stored at tile corners in
-- per-chunk uint16 buffers; chunk-boundary corners are duplicated across the
-- chunks that share them and kept in sync by setCorner's write-through.

local Constants = require(script.Parent.TerrainConstants)
local Types = require(script.Parent.TerrainTypes)

local CHUNK_CORNERS = Constants.CHUNK_CORNERS -- 65
local CHUNK_TILES = Constants.CHUNK_TILES -- 64
local CHUNKS_PER_AXIS = Constants.CHUNKS_PER_AXIS -- 16
local CORNER_COUNT = Constants.CHUNK_CORNER_COUNT -- 4225
local SEA_RAW = Constants.SEA_RAW
local SPACING = Constants.SAMPLE_SPACING
local MAX_CORNER = Constants.CORNERS_PER_AXIS - 1 -- 1024
local MAX_CHUNK = CHUNKS_PER_AXIS - 1 -- 15
local FLAG_LOCKED = Constants.Flag.LOCKED
local rawToWorldY = Constants.rawToWorldY
local worldToCorner = Constants.worldToCorner

local Heightmap = {}
Heightmap.__index = Heightmap

export type Heightmap = typeof(setmetatable(
	{} :: {
		_chunks: { [number]: Types.Chunk },
		_dirty: { [number]: boolean }, -- save-dirty: drained by persistence
		_renderDirty: { [number]: boolean }, -- drained by the renderer each frame
	},
	Heightmap
))

local function chunkKey(cx: number, cz: number): number
	return cz * CHUNKS_PER_AXIS + cx
end

local function localIndex(lx: number, lz: number): number
	return lz * CHUNK_CORNERS + lx
end

local function clampCorner(g: number): number
	if g < 0 then return 0 end
	if g > MAX_CORNER then return MAX_CORNER end
	return g
end

-- Owners of a global corner index on one axis: returns the primary (chunk, local)
-- and, when the corner sits on a shared chunk edge, the neighbouring chunk too.
local function axisOwners(g: number): (number, number, number?, number?)
	local cHigh = math.floor(g / CHUNK_TILES)
	if cHigh > MAX_CHUNK then cHigh = MAX_CHUNK end
	local primaryLocal = g - cHigh * CHUNK_TILES
	if primaryLocal == 0 and cHigh > 0 then
		return cHigh, 0, cHigh - 1, CHUNK_TILES
	end
	return cHigh, primaryLocal, nil, nil
end

function Heightmap.new(): Heightmap
	return setmetatable({
		_chunks = {},
		_dirty = {},
		_renderDirty = {},
	}, Heightmap)
end

function Heightmap.getChunk(self: Heightmap, cx: number, cz: number): Types.Chunk?
	return self._chunks[chunkKey(cx, cz)]
end

-- Allocate a chunk if absent. Heights default to sea level, material AUTO, no flags.
function Heightmap.ensureChunk(self: Heightmap, cx: number, cz: number): Types.Chunk
	local key = chunkKey(cx, cz)
	local existing = self._chunks[key]
	if existing then return existing end

	local heights = buffer.create(CORNER_COUNT * 2)
	for i = 0, CORNER_COUNT - 1 do
		buffer.writeu16(heights, i * 2, SEA_RAW)
	end
	local chunk: Types.Chunk = {
		cx = cx,
		cz = cz,
		heights = heights,
		materials = buffer.create(CORNER_COUNT), -- zero = AUTO
		flags = buffer.create(CORNER_COUNT), -- zero = no flags
	}
	self._chunks[key] = chunk
	return chunk
end

function Heightmap.markChunkDirty(self: Heightmap, cx: number, cz: number)
	local key = chunkKey(cx, cz)
	self._dirty[key] = true
	self._renderDirty[key] = true
end

-- Mark a chunk needing repaint but NOT a save. Used by generation, whose result is
-- reproducible from the seed and must never be persisted as an "edit".
function Heightmap.markRenderDirty(self: Heightmap, cx: number, cz: number)
	self._renderDirty[chunkKey(cx, cz)] = true
end

-- Raw height at a global corner. Returns sea level for unallocated chunks.
function Heightmap.getCorner(self: Heightmap, gx: number, gz: number): number
	gx = clampCorner(gx)
	gz = clampCorner(gz)
	local cx, lx = axisOwners(gx)
	local cz, lz = axisOwners(gz)
	local chunk = self._chunks[chunkKey(cx, cz)]
	if not chunk then return SEA_RAW end
	return buffer.readu16(chunk.heights, localIndex(lx, lz) * 2)
end

local function writeCorner(self: Heightmap, gx: number, gz: number, raw: number, markDirty: boolean)
	gx = clampCorner(gx)
	gz = clampCorner(gz)
	if raw < 0 then raw = 0 elseif raw > Constants.RAW_MAX then raw = Constants.RAW_MAX end

	local cxA, lxA, cxB, lxB = axisOwners(gx)
	local czA, lzA, czB, lzB = axisOwners(gz)
	local xs = { { cxA, lxA }, if cxB then { cxB, lxB } else nil }
	local zs = { { czA, lzA }, if czB then { czB, lzB } else nil }

	for _, xo in xs do
		for _, zo in zs do
			local chunk = self:ensureChunk(xo[1], zo[1])
			buffer.writeu16(chunk.heights, localIndex(xo[2], zo[2]) * 2, raw)
			if markDirty then
				local key = chunkKey(xo[1], zo[1])
				self._dirty[key] = true
				self._renderDirty[key] = true
			end
		end
	end
end

-- Write a raw height to every chunk that shares this global corner; marks them dirty.
function Heightmap.setCorner(self: Heightmap, gx: number, gz: number, raw: number)
	writeCorner(self, gx, gz, raw, true)
end

-- Write-through helper for temporary serialization views. It updates duplicated chunk
-- corners but does not mark the map dirty or request a repaint.
function Heightmap.setCornerNoDirty(self: Heightmap, gx: number, gz: number, raw: number)
	writeCorner(self, gx, gz, raw, false)
end

function Heightmap.getMaterial(self: Heightmap, gx: number, gz: number): number
	gx = clampCorner(gx)
	gz = clampCorner(gz)
	local cx, lx = axisOwners(gx)
	local cz, lz = axisOwners(gz)
	local chunk = self._chunks[chunkKey(cx, cz)]
	if not chunk then return Constants.Material.AUTO end
	return buffer.readu8(chunk.materials, localIndex(lx, lz))
end

function Heightmap.setMaterial(self: Heightmap, gx: number, gz: number, id: number)
	gx = clampCorner(gx)
	gz = clampCorner(gz)
	local cxA, lxA, cxB, lxB = axisOwners(gx)
	local czA, lzA, czB, lzB = axisOwners(gz)
	local xs = { { cxA, lxA }, if cxB then { cxB, lxB } else nil }
	local zs = { { czA, lzA }, if czB then { czB, lzB } else nil }
	for _, xo in xs do
		for _, zo in zs do
			local chunk = self:ensureChunk(xo[1], zo[1])
			buffer.writeu8(chunk.materials, localIndex(xo[2], zo[2]), id)
			local key = chunkKey(xo[1], zo[1])
			self._dirty[key] = true
			self._renderDirty[key] = true
		end
	end
end

function Heightmap.getFlags(self: Heightmap, gx: number, gz: number): number
	gx = clampCorner(gx)
	gz = clampCorner(gz)
	local cx, lx = axisOwners(gx)
	local cz, lz = axisOwners(gz)
	local chunk = self._chunks[chunkKey(cx, cz)]
	if not chunk then return 0 end
	return buffer.readu8(chunk.flags, localIndex(lx, lz))
end

function Heightmap.isLocked(self: Heightmap, gx: number, gz: number): boolean
	return bit32.band(self:getFlags(gx, gz), FLAG_LOCKED) ~= 0
end

function Heightmap.setFlags(self: Heightmap, gx: number, gz: number, flags: number)
	gx = clampCorner(gx)
	gz = clampCorner(gz)
	local cxA, lxA, cxB, lxB = axisOwners(gx)
	local czA, lzA, czB, lzB = axisOwners(gz)
	local xs = { { cxA, lxA }, if cxB then { cxB, lxB } else nil }
	local zs = { { czA, lzA }, if czB then { czB, lzB } else nil }
	for _, xo in xs do
		for _, zo in zs do
			local chunk = self:ensureChunk(xo[1], zo[1])
			buffer.writeu8(chunk.flags, localIndex(xo[2], zo[2]), flags)
		end
	end
end

-- The four corner raw heights of tile (tx, tz): (00, 10, 01, 11).
function Heightmap.getTileCornersRaw(self: Heightmap, tx: number, tz: number): (number, number, number, number)
	return
		self:getCorner(tx, tz),
		self:getCorner(tx + 1, tz),
		self:getCorner(tx, tz + 1),
		self:getCorner(tx + 1, tz + 1)
end

-- Surface slope (radians) of tile (tx, tz) from its four corners.
function Heightmap.getTileSlope(self: Heightmap, tx: number, tz: number): number
	local r00, r10, r01, r11 = self:getTileCornersRaw(tx, tz)
	local h00, h10 = rawToWorldY(r00), rawToWorldY(r10)
	local h01, h11 = rawToWorldY(r01), rawToWorldY(r11)
	local gradX = ((h10 - h00) + (h11 - h01)) / (2 * SPACING)
	local gradZ = ((h01 - h00) + (h11 - h10)) / (2 * SPACING)
	return math.atan(math.sqrt(gradX * gradX + gradZ * gradZ))
end

-- Bilinear-interpolated worldY at an arbitrary world point. This is the getter
-- zoning/roads use, since their 6-stud grid does not align to terrain corners.
function Heightmap.getHeightAt(self: Heightmap, worldX: number, worldZ: number): number
	local fx = worldToCorner(worldX)
	local fz = worldToCorner(worldZ)
	if fx < 0 then fx = 0 elseif fx > MAX_CORNER then fx = MAX_CORNER end
	if fz < 0 then fz = 0 elseif fz > MAX_CORNER then fz = MAX_CORNER end
	local gx = math.floor(fx)
	local gz = math.floor(fz)
	local tx = if gx >= MAX_CORNER then MAX_CORNER - 1 else gx
	local tz = if gz >= MAX_CORNER then MAX_CORNER - 1 else gz
	local sx = fx - tx
	local sz = fz - tz
	local h00 = rawToWorldY(self:getCorner(tx, tz))
	local h10 = rawToWorldY(self:getCorner(tx + 1, tz))
	local h01 = rawToWorldY(self:getCorner(tx, tz + 1))
	local h11 = rawToWorldY(self:getCorner(tx + 1, tz + 1))
	local top = h00 + (h10 - h00) * sx
	local bot = h01 + (h11 - h01) * sx
	return top + (bot - top) * sz
end

-- Surface slope (radians) at an arbitrary world point.
function Heightmap.getSlopeAt(self: Heightmap, worldX: number, worldZ: number): number
	local fx = worldToCorner(worldX)
	local fz = worldToCorner(worldZ)
	local tx = math.clamp(math.floor(fx), 0, MAX_CORNER - 1)
	local tz = math.clamp(math.floor(fz), 0, MAX_CORNER - 1)
	return self:getTileSlope(tx, tz)
end

-- Drain the save-dirty chunk-key set: returns the changed keys and clears them.
-- Consumed by persistence.
function Heightmap.drainDirty(self: Heightmap): { number }
	local out = {}
	for key in self._dirty do
		table.insert(out, key)
	end
	table.clear(self._dirty)
	return out
end

-- Non-draining peek at the save-dirty chunk-key set. Used to enumerate edited chunks
-- for the client terrain build without disturbing persistence's drain.
function Heightmap.dirtyKeys(self: Heightmap): { number }
	local out = {}
	for key in self._dirty do
		table.insert(out, key)
	end
	return out
end

function Heightmap.hasDirty(self: Heightmap): boolean
	return next(self._dirty) ~= nil
end

-- Drain the render-dirty chunk-key set: returns chunks needing a repaint and
-- clears them. Independent of the save-dirty set so persistence is unaffected.
function Heightmap.drainRenderDirty(self: Heightmap): { number }
	local out = {}
	for key in self._renderDirty do
		table.insert(out, key)
	end
	table.clear(self._renderDirty)
	return out
end

function Heightmap.forEachChunk(self: Heightmap, fn: (Types.Chunk) -> ())
	for _, chunk in self._chunks do
		fn(chunk)
	end
end

-- Decode a chunk key back into (cx, cz). Exposed for renderer/persistence.
function Heightmap.decodeKey(key: number): (number, number)
	local cz = math.floor(key / CHUNKS_PER_AXIS)
	return key - cz * CHUNKS_PER_AXIS, cz
end

Heightmap.chunkKey = chunkKey

return Heightmap
