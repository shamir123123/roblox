--!strict
-- CitizenSaveColumns
-- The citizens section of a city save in COLUMN form. CitizenService builds one row per home
-- ({h, a, k, e, j, f, o, cv, cp, w}); as rows, every home repeats every key name and every
-- field sits between unlike neighbours. Here each field is its own list, so Zstd sees runs of
-- like values (poses with poses, adult numbers with adult numbers): measured -20% packed on a
-- 1,000-home test city, -32% together with the 0.1-stud car poses. Pure library; toColumns /
-- fromColumns are exact inverses on the row shape, so CitizenService's save and load logic
-- is unchanged either side of it.
--
-- JSON (BlobCodec) cannot hold a sparse array, so facts only some homes have are their own
-- parallel lists, each entry tagged with its home's position (1-based index into `h`):
--   owners  oh/oa           adults owning a car
--   at work wh/wa           adults at work
--   parked  ph/pa/px/py/pz/pr/pw   pose (x, y, z, yaw) + pw 1 = left away from home
--   driving vh/va/vx/vy/vz/vr/vd/vm/vk   pose, destination key, vm 1 = heading home, vk kind
--   jobs    jn per home, then jk/jc (job key, count) pairs in home order

local CitizenSaveColumns = {}

local FIELDS = table.freeze({
	"h", "a", "k", "f", "e1", "e2", "e3", "e4", "jn", "jk", "jc", "oh", "oa", "wh", "wa",
	"ph", "pa", "px", "py", "pz", "pr", "pw", "vh", "va", "vx", "vy", "vz", "vr", "vd", "vm", "vk",
})

function CitizenSaveColumns.toColumns(rows: { any }): { [string]: { any } }
	local c: { [string]: { any } } = {}
	for _, name in FIELDS do c[name] = {} end
	local function put(name: string, v: any) table.insert(c[name], v) end
	for i, row in rows do
		put("h", row.h); put("a", row.a); put("k", row.k); put("f", row.f or 0)
		local e = row.e or {}
		put("e1", e[1] or 0); put("e2", e[2] or 0); put("e3", e[3] or 0); put("e4", e[4] or 0)
		local jobs = row.j or {}
		put("jn", #jobs)
		for _, pair in jobs do put("jk", pair[1]); put("jc", pair[2]) end
		for _, adult in row.o or {} do put("oh", i); put("oa", adult) end
		for _, adult in row.w or {} do put("wh", i); put("wa", adult) end
		for _, p in row.cp or {} do
			local pose = p[2]
			put("ph", i); put("pa", p[1])
			put("px", pose[1]); put("py", pose[2]); put("pz", pose[3]); put("pr", pose[4])
			put("pw", if p[3] then 1 else 0)
		end
		for _, v in row.cv or {} do
			put("vh", i); put("va", v.a)
			put("vx", v.c[1]); put("vy", v.c[2]); put("vz", v.c[3]); put("vr", v.c[4])
			put("vd", v.d or 0); put("vm", if v.hm then 1 else 0); put("vk", v.k or "")
		end
	end
	return c
end

-- Untrusted input (it comes off a DataStore): anything malformed yields fewer or partial rows,
-- never an error -- CitizenService validates each row's values the way it always has.
function CitizenSaveColumns.fromColumns(c: any): { any }
	local rows: { any } = {}
	if typeof(c) ~= "table" or typeof(c.h) ~= "table" then return rows end
	local function col(name: string): { any }
		local v = c[name]
		return if typeof(v) == "table" then v else {}
	end
	local a, k, f = col("a"), col("k"), col("f")
	local e1, e2, e3, e4 = col("e1"), col("e2"), col("e3"), col("e4")
	local jn, jk, jc = col("jn"), col("jk"), col("jc")
	local jAt = 1
	for i, h in c.h do
		local jobs = {}
		for _ = 1, math.max(0, math.floor(tonumber(jn[i]) or 0)) do
			if jk[jAt] == nil then break end
			table.insert(jobs, { jk[jAt], jc[jAt] })
			jAt += 1
		end
		rows[i] = {
			h = h, a = a[i], k = k[i], f = f[i],
			e = { e1[i] or 0, e2[i] or 0, e3[i] or 0, e4[i] or 0 },
			j = jobs,
		}
	end
	local function rowAt(v: any): any
		return rows[tonumber(v) or 0]
	end
	local function listInto(homes: { any }, values: { any }, field: string)
		for n, home in homes do
			local row = rowAt(home)
			if row and values[n] ~= nil then
				row[field] = row[field] or {}
				table.insert(row[field], values[n])
			end
		end
	end
	listInto(col("oh"), col("oa"), "o")
	listInto(col("wh"), col("wa"), "w")
	local pa, px, py, pz, pr, pw = col("pa"), col("px"), col("py"), col("pz"), col("pr"), col("pw")
	for n, home in col("ph") do
		local row = rowAt(home)
		if row then
			row.cp = row.cp or {}
			table.insert(row.cp, { pa[n], { px[n], py[n], pz[n], pr[n] }, if pw[n] == 1 then true else nil })
		end
	end
	local va, vx, vy, vz, vr, vd, vm, vk = col("va"), col("vx"), col("vy"), col("vz"), col("vr"), col("vd"), col("vm"), col("vk")
	for n, home in col("vh") do
		local row = rowAt(home)
		if row then
			row.cv = row.cv or {}
			table.insert(row.cv, {
				a = va[n], c = { vx[n], vy[n], vz[n], vr[n] }, d = vd[n],
				hm = if vm[n] == 1 then true else nil,
				k = if typeof(vk[n]) == "string" and vk[n] ~= "" then vk[n] else nil,
			})
		end
	end
	return rows
end

return CitizenSaveColumns
