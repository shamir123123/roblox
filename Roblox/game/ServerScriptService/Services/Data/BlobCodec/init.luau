--!strict
-- BlobCodec
-- Packs a DataStore-safe table into one Zstd-compressed buffer and back. Pure library: no
-- state, no lifecycle.
--
-- Layout before compression: u8 MAGIC, u32 JSON length, the JSON, then every `buffer` the
-- blob held, back to back. In the JSON each buffer is a {[BUF_TAG] = {offset, length}}
-- stand-in, so binary sections (terrain, nature) skip base64 and its 33%.
--
-- Zstd level 19, measured on a 2,940-pop city (2026-09-26): 120 KB vs 147 KB at L9, ~110 ms
-- to pack; unpacking costs ~1.5 ms at any level. Saves run every 10 min.

local HttpService = game:GetService("HttpService")
local EncodingService = game:GetService("EncodingService")

local ZSTD = Enum.CompressionAlgorithm.Zstd
local ZSTD_LEVEL = 19
local MAGIC = 0xB1 -- never the first byte of JSON, which is how a pre-container blob is told apart
local HEADER = 5
local BUF_TAG = "__buf"

local BlobCodec = {}

function BlobCodec.pack(blob: any): buffer
	local bufs: { buffer } = {}
	local tailLen = 0
	-- Builds a stand-in COPY rather than editing the blob: callers keep what they packed
	-- (MapTemplateService caches it) and it must still hold the real buffers.
	local function strip(v: any): any
		if typeof(v) == "buffer" then
			table.insert(bufs, v)
			local ref = { [BUF_TAG] = { tailLen, buffer.len(v) } }
			tailLen += buffer.len(v)
			return ref
		elseif typeof(v) == "table" then
			local t = {}
			for k, x in v do t[k] = strip(x) end
			return t
		end
		return v
	end
	local json = HttpService:JSONEncode(strip(blob))
	local raw = buffer.create(HEADER + #json + tailLen)
	buffer.writeu8(raw, 0, MAGIC)
	buffer.writeu32(raw, 1, #json)
	buffer.writestring(raw, HEADER, json)
	local at = HEADER + #json
	for _, b in bufs do
		buffer.copy(raw, at, b)
		at += buffer.len(b)
	end
	return EncodingService:CompressBuffer(raw, ZSTD, ZSTD_LEVEL)
end

-- Takes whatever a DataStore read returns: a packed buffer, or a plain table (passes
-- through). Returns the blob table, or nil for a corrupt/unreadable buffer.
function BlobCodec.unpack(stored: any): any
	if typeof(stored) ~= "buffer" then
		return stored
	end
	local ok, blob = pcall(function()
		local raw = EncodingService:DecompressBuffer(stored, ZSTD)
		if buffer.len(raw) == 0 or buffer.readu8(raw, 0) ~= MAGIC then
			-- Pre-container blob: the whole thing is JSON (blueprints saved before 2026-09-26).
			return HttpService:JSONDecode(buffer.tostring(raw))
		end
		local jsonLen = buffer.readu32(raw, 1)
		local tail = HEADER + jsonLen
		local function restore(v: any): any
			if typeof(v) ~= "table" then return v end
			local ref = v[BUF_TAG]
			if typeof(ref) == "table" then
				local b = buffer.create(ref[2])
				buffer.copy(b, 0, raw, tail + ref[1], ref[2]) -- out of range = corrupt, pcall catches it
				return b
			end
			for k, x in v do v[k] = restore(x) end
			return v
		end
		return restore(HttpService:JSONDecode(buffer.readstring(raw, HEADER, jsonLen)))
	end)
	if not ok then
		warn("[BlobCodec] failed to unpack stored blob: " .. tostring(blob))
		return nil
	end
	return blob
end

return BlobCodec
