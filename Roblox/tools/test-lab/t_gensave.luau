-- Crash-safe save layout (CitySlotService generations) against an in-memory DataStore:
-- small and multi-chunk saves, a write cut off before the pointer switch, a corrupt newest
-- generation, the loaded generation never overwritten, legacy migration, and delete.
-- usage: lune run t_gensave.luau
local serde = require("@lune/serde")
local Studio = require("./shim/setup")("cur")
local task = Studio.task

-- Stand-in codec: JSON in a buffer (the shim has no Zstd). Unpack errors on garbage.
Studio.stub("ServerScriptService.Services.Data.BlobCodec", {
	pack = function(blob) return buffer.fromstring(serde.encode("json", blob)) end,
	unpack = function(stored)
		if typeof(stored) ~= "buffer" then return stored end
		return serde.decode("json", buffer.tostring(stored))
	end,
})
Studio.expose("ServerScriptService.Services.Data.CitySlotService", [[
CitySlotService.__t = {
	setStore = function(s) _store = s end,
	write = writeSlotBlob, read = readSlotBlob, remove = removeSlotBlob,
	gen = _slotGen, payload = CHUNK_PAYLOAD_BYTES,
}]])
local CSS = Studio.require(Studio.find("ServerScriptService.Services.Data.CitySlotService"))
local T = CSS.__t

local data: { [string]: any } = {}
local failKey: ((string) -> boolean)? = nil
local writes = 0
local function copy(v) if typeof(v) == "buffer" then local b = buffer.create(buffer.len(v)); buffer.copy(b, 0, v); return b end return v end
local store = {}
function store:GetAsync(k) return copy(data[k]) end
function store:UpdateAsync(k, fn)
	if failKey and failKey(k) then error("mock: write refused for " .. k) end
	writes += 1
	data[k] = copy(fn(data[k]))
end
function store:RemoveAsync(k) data[k] = nil end
T.setStore(store)

local failures = 0
local function check(what, ok, detail)
	if not ok then failures += 1 end
	print((if ok then "PASS " else "FAIL ") .. what .. (if detail then ": " .. tostring(detail) else ""))
end
-- Everything that may task.wait runs in a shim thread; the virtual clock carries it through.
local function run(fn)
	local out = table.pack()
	local done = false
	task.spawn(function() out = table.pack(fn()); done = true end)
	for _ = 1, 400 do if done then break end Studio.step(0.5) end
	assert(done, "scenario never finished")
	return table.unpack(out, 1, out.n)
end
local function pack(t) return buffer.fromstring(serde.encode("json", t)) end
local function keys()
	local n = 0
	for _ in data do n += 1 end
	return n
end
local U, S = 42, 1
local k = tostring(U) .. ":" .. tostring(S)

-- 1. Fresh slot: save, load back.
check("first save", run(function() return T.write(U, S, pack({ v = 1 })) end))
local b, ok = run(function() return T.read(U, S) end)
check("first load", ok and b and b.v == 1, b and b.v)
local loaded = T.gen[k].loaded

-- 2. Several saves in one session: the loaded generation is never written over.
for v = 2, 6 do run(function() return T.write(U, S, pack({ v = v })) end) end
check("loaded gen kept", T.gen[k].current ~= loaded, "current " .. T.gen[k].current .. " loaded " .. loaded)
b = run(function() return T.read(U, S) end)
check("newest loads", b and b.v == 6, b and b.v)
-- read() made gen current the loaded one again; the loaded one from before still has v=1? No:
-- a new session loaded v=6. Check the session-start copy from here on.

-- 3. A save cut off before the pointer switch: the last complete save still loads.
loaded = T.gen[k].loaded
failKey = function(key) return not key:find("_g") end -- chunks land, the pointer write fails
check("interrupted save reports failure", run(function() return T.write(U, S, pack({ v = 7 })) end) == false)
failKey = nil
b = run(function() return T.read(U, S) end)
check("interrupted save: last complete save loads", b and b.v == 6, b and b.v)

-- 4. Newest generation corrupt: falls back to the newest readable earlier one.
run(function() return T.write(U, S, pack({ v = 8 })) end) -- gen A (after v=6's gen)
run(function() return T.write(U, S, pack({ v = 9 })) end) -- gen B
local cur = T.gen[k].current
local headKey = "slot_" .. U .. "_" .. S
for key in data do if key:find("_g" .. cur .. "c1$") then headKey = key end end
local head = data[headKey]
buffer.writestring(head, 6, "!!!") -- keeps the header, wrecks the payload
b, ok = run(function() return T.read(U, S) end)
check("corrupt newest: recovered", ok and b and b.v == 8, b and b.v)
check("corrupt newest: next save goes over the broken one", T.gen[k].current == cur and T.gen[k].loaded ~= cur)
run(function() return T.write(U, S, pack({ v = 10 })) end)
b = run(function() return T.read(U, S) end)
check("after recovery the next save loads", b and b.v == 10, b and b.v)

-- 5. Multi-chunk city (payload > one key).
local big = string.rep("x", T.payload + 5000)
run(function() return T.write(U, S, pack({ v = 11, big = big })) end)
b = run(function() return T.read(U, S) end)
check("multi-chunk round trip", b and b.v == 11 and #b.big == #big, b and b.v)

-- 6. Legacy layout (a plain head at the slot key, chunks at _cN) migrates on its first save.
local U2 = 7
local legacyKey
for key in data do if key:find("^.*" .. U .. "_" .. S .. "$") then legacyKey = key end end
local slotKey2 = legacyKey and legacyKey:gsub(tostring(U), tostring(U2), 1) or ("slot_" .. U2 .. "_1")
local payload = pack({ v = 100 })
local lh = buffer.create(buffer.len(payload) + 2)
buffer.writeu8(lh, 0, 0xFF); buffer.writeu8(lh, 1, 1); buffer.copy(lh, 2, payload)
data[slotKey2] = lh
data[slotKey2 .. "_c2"] = buffer.fromstring("stale")
b, ok = run(function() return T.read(U2, S) end)
check("legacy loads", ok and b and b.v == 100, b and b.v)
run(function() return T.write(U2, S, pack({ v = 101 })) end)
Studio.run(1)
check("legacy tail chunks cleared", data[slotKey2 .. "_c2"] == nil)
b = run(function() return T.read(U2, S) end)
check("legacy -> generations round trip", b and b.v == 101, b and b.v)

-- 7. Delete leaves nothing behind.
local before = keys()
run(function() T.remove(U, S); T.remove(U2, S) end)
check("delete clears every key", keys() == 0, before .. " -> " .. keys())

print(string.format("key = %s; %d writes; %d failure(s)", tostring(legacyKey), writes, failures))
