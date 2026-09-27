--!strict
-- NumberPack
-- Packs integer rows (a flat array, `stride` numbers per row) into a buffer COLUMN by
-- column, every value a zigzag LEB128 varint. Column `deltaCol` stores the gap from the
-- previous row instead -- sort the rows on it first and the gaps are tiny. Column-major puts
-- like values side by side, which is what Zstd (BlobCodec) feeds on: a 1,906-tree map went
-- 17.5 KB as JSON text -> 11.8 KB (2026-09-26). Pure library: no state, no lifecycle.

local MAX_INT = 2 ^ 52

local NumberPack = {}

-- nil when a value is not an integer (or too big to round-trip): the caller keeps its plain
-- table rather than lose a digit.
function NumberPack.pack(ints: { number }, stride: number, deltaCol: number?): buffer?
	local rows = #ints // stride
	local b = buffer.create(8 + rows * stride * 8)
	local o = 0
	local function put(v: number)
		while v >= 128 do
			buffer.writeu8(b, o, v % 128 + 128)
			o += 1
			v //= 128
		end
		buffer.writeu8(b, o, v)
		o += 1
	end
	put(rows)
	for c = 1, stride do
		local prev = 0
		for r = 0, rows - 1 do
			local v = ints[r * stride + c]
			if typeof(v) ~= "number" or v ~= math.floor(v) or math.abs(v) > MAX_INT then return nil end
			local d = if c == deltaCol then v - prev else v
			put(if d >= 0 then d * 2 else -d * 2 - 1)
			prev = v
		end
	end
	local out = buffer.create(o)
	buffer.copy(out, 0, b, 0, o)
	return out
end

-- nil for a truncated or corrupt buffer.
function NumberPack.unpack(b: buffer, stride: number, deltaCol: number?): { number }?
	local n, o = buffer.len(b), 0
	local function get(): number?
		local v, mul = 0, 1
		while o < n do
			local byte = buffer.readu8(b, o)
			o += 1
			v += (byte % 128) * mul
			if byte < 128 then return v end
			mul *= 128
		end
		return nil
	end
	local rows = get()
	-- Every value takes at least a byte, so a row count the buffer cannot hold is corruption.
	if not rows or rows * stride > n then return nil end
	local ints = table.create(rows * stride, 0)
	for c = 1, stride do
		local prev = 0
		for r = 0, rows - 1 do
			local z = get()
			if not z then return nil end
			local v = if z % 2 == 0 then z // 2 else -(z + 1) // 2
			if c == deltaCol then v += prev end
			ints[r * stride + c] = v
			prev = v
		end
	end
	return ints
end

return NumberPack
