--!strict
--!native
-- Serializes terrain to a DataStore-safe record and back. Does NOT touch DataStore itself
-- (CitySlotService is the writer) -- it only converts heightmap chunks <-> a plain table.
-- Stores seed + the edited chunks; unedited terrain regenerates from the seed.
--
-- Record fmt "p": `keys` lists the edited chunks, sorted; `h`, `hh`, `m`, `f` are buffers
-- holding every one of them back to back (CC bytes a chunk), each cell as its DIFFERENCE
-- from the regenerated base, so an untouched cell is 0 and Zstd (BlobCodec) gets long runs:
--   h/hh  height residual (height - base), minus a prediction from the neighbours already
--         decoded (MED, the JPEG-LS predictor), zigzagged to u16: low bytes in h, high in hh.
--         A graded pad is a constant residual step, which MED predicts exactly.
--   m, f  the chunk's material / flag bytes as they are. A generated base is all zero in
--         both layers, so they already ARE the difference -- and cost a buffer.copy.
-- Measured on a 32-chunk city (2026-09-26): 33.9 KB of chunk data -> 7.3 KB after Zstd.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Terrain.TerrainConstants)
local Heightmap = require(ReplicatedStorage.Terrain.Heightmap)
local TerrainGenerator = require(ReplicatedStorage.Terrain.TerrainGenerator)
local NumberPack = require(script.Parent.Parent.Data.NumberPack)

local TerrainPersistence = {}

local FMT = "p"
local SIDE = Constants.CHUNK_CORNERS -- 65
local CC = Constants.CHUNK_CORNER_COUNT -- 4225

local readu8, writeu8 = buffer.readu8, buffer.writeu8
local readu16, writeu16 = buffer.readu16, buffer.writeu16

-- One MED pass over a chunk's height residuals (height - base). Encoding reads heights and
-- writes the zigzagged prediction errors to the lo/hi planes at offset o; decoding reads the
-- planes and writes heights (pass the chunk's own heights as `base` -- each cell's base is
-- read before it is overwritten). One loop for both is what keeps the predictor identical.
-- Inlined on purpose: this runs ~1M times for a fully sculpted map.
local function heightPass(encode: boolean, heights: buffer, base: buffer, lo: buffer, hi: buffer, o: number)
	local r = table.create(CC, 0) -- r[i + 1] = residual of cell i
	for y = 0, SIDE - 1 do
		for x = 0, SIDE - 1 do
			local i = y * SIDE + x
			local pred = 0
			if y == 0 then
				if x > 0 then pred = r[i] end
			elseif x == 0 then
				pred = r[i - SIDE + 1]
			else
				local l, u, ul = r[i], r[i - SIDE + 1], r[i - SIDE]
				if ul >= l and ul >= u then
					pred = if l < u then l else u
				elseif ul <= l and ul <= u then
					pred = if l > u then l else u
				else
					pred = l + u - ul
				end
			end
			local b = readu16(base, i * 2)
			if encode then
				local res = readu16(heights, i * 2) - b
				r[i + 1] = res
				-- Wrapped to i16: decoding works mod 65536, so this is exact for any u16 heights.
				local e = (res - pred + 32768) % 65536 - 32768
				local z = if e >= 0 then e * 2 else -e * 2 - 1
				writeu8(lo, o + i, z % 256)
				writeu8(hi, o + i, z // 256)
			else
				local z = readu8(lo, o + i) + readu8(hi, o + i) * 256
				local e = if z % 2 == 0 then z // 2 else -(z + 1) // 2
				local h = (b + pred + e) % 65536
				r[i + 1] = h - b
				writeu16(heights, i * 2, h)
			end
		end
	end
end

local function sameChunk(a: any, b: any): boolean
	return buffer.tostring(a.heights) == buffer.tostring(b.heights)
		and buffer.tostring(a.materials) == buffer.tostring(b.materials)
		and buffer.tostring(a.flags) == buffer.tostring(b.flags)
end

-- Writes chunk slot j (0-based) of rec's layer buffers.
local function encodeChunk(chunk: any, base: any, j: number, rec: any)
	heightPass(true, chunk.heights, base.heights, rec.h, rec.hh, j * CC)
	buffer.copy(rec.m, j * CC, chunk.materials, 0, CC)
	buffer.copy(rec.f, j * CC, chunk.flags, 0, CC)
end

-- Applies chunk slot j (0-based) of rec onto `chunk`, which must already hold the base.
local function decodeChunk(chunk: any, j: number, rec: any)
	heightPass(false, chunk.heights, chunk.heights, rec.h, rec.hh, j * CC)
	buffer.copy(chunk.materials, 0, rec.m, j * CC, CC)
	buffer.copy(chunk.flags, 0, rec.f, j * CC, CC)
end

-- Shape check before any byte is read: a bad record must fail whole, never half-apply.
local function wellFormed(rec: any): boolean
	if rec.fmt ~= FMT or type(rec.keys) ~= "table" then return false end
	for _, key in rec.keys do
		if type(key) ~= "number" then return false end
	end
	local size = #rec.keys * CC
	for _, layer in { rec.h, rec.hh, rec.m, rec.f } do
		if typeof(layer) ~= "buffer" or buffer.len(layer) ~= size then return false end
	end
	return true
end

-- Can `template` (a map's authored terrain record) serve as the diff base for a city
-- generated from `params`? Needs the same schema/generator/format AND the exact same base
-- shape (seed + every gen knob) -- a delta applied onto different ground is silent terrain
-- corruption, so any mismatch means "no".
function TerrainPersistence.usableTemplate(template: any, params: TerrainGenerator.GenParams): boolean
	if type(template) ~= "table" then return false end
	if template.v ~= Constants.SCHEMA_VERSION or template.gen ~= Constants.GEN_VERSION then return false end
	if not wellFormed(template) then return false end
	if template.seed ~= params.seed then return false end
	local tp = if type(template.params) == "table" then template.params else {}
	return (tp.heightRange or 1) == (params.heightRange or 1)
		and (tp.oceanLevel or 0) == (params.oceanLevel or 0)
		and (tp.baseHeight or 0) == (params.baseHeight or 0)
		and (tp.ruggedness or 0) == (params.ruggedness or 0)
		and tp.shape == params.shape
		and (tp.persistence or 0.5) == (params.persistence or 0.5)
		and (tp.lacunarity or 2.0) == (params.lacunarity or 2.0)
		and tp.algo == params.algo
end

-- Build a save record from the edited chunks of a heightmap, each chunk stored against its
-- freshly-regenerated base. params drives that regeneration and MUST match what the city
-- was generated from. With `template` (a usable map template record, see usableTemplate)
-- the base is seed + template, so terrain that matches the authored map stores NOTHING and
-- the record is marked tpl -- restore must lay the template down first. Chunks identical
-- to their base are skipped entirely.
function TerrainPersistence.serialize(
	hm: Heightmap.Heightmap,
	params: TerrainGenerator.GenParams,
	editedChunks: { [number]: boolean },
	template: any?
): { [string]: any }
	local tpl = if TerrainPersistence.usableTemplate(template, params) then template else nil
	local tplSlot: { [number]: number } = {}
	if tpl then
		for j, key in tpl.keys do tplSlot[key] = j - 1 end
	end
	local candidates: { number } = {}
	for key in editedChunks do table.insert(candidates, key) end
	table.sort(candidates)

	local base = Heightmap.new()
	local keys: { number } = {}
	local chunks: { any }, bases: { any } = {}, {}
	for _, key in candidates do
		local cx, cz = Heightmap.decodeKey(key)
		local chunk = hm:getChunk(cx, cz)
		if chunk then
			TerrainGenerator.generateChunk(base, cx, cz, params)
			local baseChunk = base:getChunk(cx, cz)
			local slot = tplSlot[key]
			if slot then decodeChunk(baseChunk, slot, tpl) end
			if not sameChunk(chunk, baseChunk) then
				table.insert(keys, key)
				table.insert(chunks, chunk)
				table.insert(bases, baseChunk)
			end
		end
	end

	local size = #keys * CC
	local rec = {
		v = Constants.SCHEMA_VERSION,
		gen = Constants.GEN_VERSION,
		seed = params.seed,
		fmt = FMT,
		tpl = if tpl then true else nil,
		keys = keys,
		h = buffer.create(size),
		hh = buffer.create(size),
		m = buffer.create(size),
		f = buffer.create(size),
	}
	for j = 1, #keys do
		encodeChunk(chunks[j], bases[j], j - 1, rec)
	end
	return rec
end

-- Restore edited chunks from a record into an already-base-generated heightmap.
-- Calls onRestored(cx, cz) for each chunk written. Returns ok, summary.
function TerrainPersistence.deserialize(
	hm: Heightmap.Heightmap,
	record: any,
	onRestored: (number, number) -> ()
): (boolean, string)
	if type(record) ~= "table" then return false, "record not a table" end
	if record.v ~= Constants.SCHEMA_VERSION then
		return false, "schema version " .. tostring(record.v)
	end
	if not wellFormed(record) then return false, "not a well-formed fmt-" .. FMT .. " record" end
	-- The record is relative to the regenerated base, so it restores correctly only when
	-- the generator that produced that base is unchanged.
	if record.gen ~= Constants.GEN_VERSION then
		return false, "gen version " .. tostring(record.gen) .. " (needs current generator)"
	end
	for j, key in record.keys do
		local cx, cz = Heightmap.decodeKey(key)
		decodeChunk(hm:ensureChunk(cx, cz), j - 1, record)
		onRestored(cx, cz)
	end
	return true, string.format("restored %d chunk(s)", #record.keys)
end

-- The water field's dry-corner keys (dug pits), sorted and stored as the gaps between them:
-- 8,539 keys went 24.5 KB -> 0.8 KB. The live client stream sends the raw key array instead.
function TerrainPersistence.packDryKeys(keys: { number }): buffer
	local sorted = table.clone(keys)
	table.sort(sorted)
	-- Keys are u32 corner ids; a non-integer would be a bug upstream -- fail the save loudly
	-- (the last good save stays) rather than write a lossy one.
	return assert(NumberPack.pack(sorted, 1, 1), "[TerrainPersistence] dry keys must be integers")
end

function TerrainPersistence.unpackDryKeys(b: any): { number }
	return if typeof(b) == "buffer" then NumberPack.unpack(b, 1, 1) or {} else {}
end

return TerrainPersistence
