--!strict
-- BadAppleFrames -- decodes the generated Bad Apple frame data into per-frame pixel flips.
--
-- The data holders (Data1, Data2, ... StringValue siblings of this one) each carry one
-- base64 chunk of a single byte stream, produced by encode_badapple.py. StringValue rather
-- than ModuleScript on purpose: Script.Source is capped at 200k characters and this payload
-- is ~877k, and the data is pure base64 ASCII so it survives StringValue replication (which
-- truncates at NUL and sanitises non-UTF8 -- the same reason RoadMeshSpecs blobs are b64).
-- Layout of the stream:
--
--   For every frame, the XOR against the PREVIOUS frame is run-length encoded as
--   alternating runs -- no-change first -- with LEB128 varint lengths. The runs always
--   sum to exactly WIDTH*HEIGHT, so a frame needs no length prefix and no terminator.
--   A completely static frame is therefore one run of 3072: two bytes.
--
-- XOR-delta is the whole trick: consecutive silhouette frames are ~95% identical, so the
-- delta is almost all zeros and the runs get very long. Raw packed bits would be 2.4 MB.
--
-- Because the stream IS the change set, stepping a frame hands back exactly the pixels
-- that flipped -- the caller only ever touches tiles whose colour actually changed, which
-- is what makes 30 fps affordable with a few thousand parts.
--
-- The stream is not seekable: playback always starts at frame 0 from an all-black buffer.

local BadAppleFrames = {}

BadAppleFrames.WIDTH = 64
BadAppleFrames.HEIGHT = 48
BadAppleFrames.PIXELS = 64 * 48
BadAppleFrames.FPS = 30

local PIXELS = BadAppleFrames.PIXELS

-- ------------------------------------------------------------------ base64 --
-- Same alphabet as RoadMeshBuilder's blob codec. Data lands here as source text, so it
-- must stay printable ASCII: Roblox stores script source as UTF-8 and bytes >= 0x80 do
-- not survive a save/load round trip.

local B64 = buffer.fromstring("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
local B64REV = buffer.create(256)
do
	for i = 0, 63 do
		buffer.writeu8(B64REV, buffer.readu8(B64, i), i)
	end
end

local function b64decode(s: string): buffer
	local src = buffer.fromstring(s)
	local slen = buffer.len(src)
	assert(slen % 4 == 0, "[BadApple] corrupt frame data (bad base64 length)")
	local pad = 0
	if slen >= 1 and buffer.readu8(src, slen - 1) == 61 then pad += 1 end
	if slen >= 2 and buffer.readu8(src, slen - 2) == 61 then pad += 1 end
	local outLen = slen / 4 * 3 - pad
	local out = buffer.create(outLen)
	local i, oi = 0, 0
	while i < slen do
		local n = buffer.readu8(B64REV, buffer.readu8(src, i)) * 262144
			+ buffer.readu8(B64REV, buffer.readu8(src, i + 1)) * 4096
			+ buffer.readu8(B64REV, buffer.readu8(src, i + 2)) * 64
			+ buffer.readu8(B64REV, buffer.readu8(src, i + 3))
		if oi < outLen then buffer.writeu8(out, oi, math.floor(n / 65536) % 256) end
		if oi + 1 < outLen then buffer.writeu8(out, oi + 1, math.floor(n / 256) % 256) end
		if oi + 2 < outLen then buffer.writeu8(out, oi + 2, n % 256) end
		i += 4
		oi += 3
	end
	return out
end

-- -------------------------------------------------------------------- data --
-- Decoded once on first use, not at require time: the modules are a few hundred KB and
-- there is no reason to pay for them unless somebody actually opens the show.

local _stream: buffer? = nil

local function dataParts(): { StringValue }
	local parts: { StringValue } = {}
	for _, child in script.Parent:GetChildren() do
		if child:IsA("StringValue") and string.match(child.Name, "^Data%d+$") then
			table.insert(parts, child)
		end
	end
	table.sort(parts, function(a, b)
		return (tonumber(string.match(a.Name, "%d+")) or 0) < (tonumber(string.match(b.Name, "%d+")) or 0)
	end)
	return parts
end

-- Returns nil (rather than erroring) when the data holders have not been generated yet,
-- so the admin button can report a clean "no data" instead of throwing.
function BadAppleFrames.load(): buffer?
	if _stream then
		return _stream
	end
	local parts = dataParts()
	if #parts == 0 then
		return nil
	end
	local chunks = table.create(#parts)
	for i, holder in parts do
		chunks[i] = holder.Value
	end
	local ok, decoded = pcall(b64decode, table.concat(chunks))
	if not ok then
		warn(`[BadApple] {decoded}`)
		return nil
	end
	_stream = decoded
	return decoded
end

-- ------------------------------------------------------------------ player --

export type Player = {
	stream: buffer,
	pos: number,      -- byte cursor into the stream
	frame: number,    -- frames emitted so far
	flips: { number },-- REUSED scratch: 0-based pixel indices that changed this step
}

function BadAppleFrames.newPlayer(): Player?
	local stream = BadAppleFrames.load()
	if not stream then
		return nil
	end
	return { stream = stream, pos = 0, frame = 0, flips = {} }
end

function BadAppleFrames.rewind(p: Player)
	p.pos = 0
	p.frame = 0
	table.clear(p.flips)
end

-- Advance one frame. Returns the list of pixel indices that flipped (owned by the player
-- and overwritten on the next call -- do not keep it), or nil once the stream runs out.
function BadAppleFrames.step(p: Player): { number }?
	local stream = p.stream
	local total = buffer.len(stream)
	local pos = p.pos
	if pos >= total then
		return nil
	end

	local flips = p.flips
	table.clear(flips)
	local nFlips = 0

	local i = 0           -- pixel cursor within the frame
	local changed = false -- runs alternate, no-change first
	while i < PIXELS do
		if pos >= total then
			-- Truncated stream: treat as end of video rather than erroring mid-show.
			return nil
		end
		local n, shift = 0, 0
		while true do
			local b = buffer.readu8(stream, pos)
			pos += 1
			n += bit32.lshift(bit32.band(b, 0x7F), shift)
			if b < 0x80 then
				break
			end
			shift += 7
			if pos >= total then
				return nil
			end
		end
		if changed then
			for k = i, i + n - 1 do
				nFlips += 1
				flips[nFlips] = k
			end
		end
		i += n
		changed = not changed
		if n == 0 and i > 0 then
			-- Only the very first run is allowed to be empty; anything else means the
			-- cursor cannot advance and we would spin forever on corrupt data.
			warn("[BadApple] corrupt frame data (zero-length run)")
			return nil
		end
	end
	if i ~= PIXELS then
		warn(`[BadApple] corrupt frame data (frame covered {i} of {PIXELS} pixels)`)
		return nil
	end

	p.pos = pos
	p.frame += 1
	return flips
end

return BadAppleFrames
