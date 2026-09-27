--!strict
return function()
	local CitizenSaveColumns = require(script.Parent)
	local HttpService = game:GetService("HttpService")

	-- Rows shaped exactly like CitizenService.serialize writes them.
	local function sampleRows(n: number): { any }
		local rng = Random.new(7)
		local rows = {}
		for i = 1, n do
			local row: any = {
				h = i, a = 2, k = rng:NextInteger(0, 2), f = rng:NextInteger(1, 90),
				e = { rng:NextInteger(0, 2), rng:NextInteger(0, 1), 0, 0 },
				j = { { rng:NextInteger(1, 200), 1 } },
			}
			if rng:NextNumber() < 0.9 then row.o = { 1, 2 } end
			if rng:NextNumber() < 0.4 then row.w = { 1 } end
			-- Parked near the home, on a street: headings mostly along the grid.
			local hx, hz = rng:NextNumber(-2000, 2000), rng:NextNumber(-2000, 2000)
			local function r1(x: number): number return math.floor(x * 10 + 0.5) / 10 end
			local function pose()
				local heading = ({ 0, 90, -90, 180 })[rng:NextInteger(1, 4)] + rng:NextNumber(-0.5, 0.5)
				return { r1(hx + rng:NextNumber(-20, 20)), r1(10.6 + rng:NextNumber(0, 3)), r1(hz + rng:NextNumber(-20, 20)), r1(heading) }
			end
			if row.o then
				row.cp = { { 1, pose(), if row.w then true else nil } }
				if rng:NextNumber() < 0.1 then
					row.cv = { { c = pose(), a = 2, d = rng:NextInteger(1, 200), hm = true, k = "shop" } }
				else
					table.insert(row.cp, { 2, pose() })
				end
			end
			rows[i] = row
		end
		return rows
	end

	-- Key order in a JSON object follows the hash, so compare structure, not strings.
	local function same(x: any, y: any): boolean
		if typeof(x) ~= "table" or typeof(y) ~= "table" then return x == y end
		for key, v in x do
			if not same(v, y[key]) then return false end
		end
		for key in y do
			if x[key] == nil then return false end
		end
		return true
	end

	describe("citizen save columns", function()
		it("round-trips every row exactly", function()
			local rows = sampleRows(300)
			local back = CitizenSaveColumns.fromColumns(CitizenSaveColumns.toColumns(rows))
			expect(same(back, rows)).to.equal(true)
		end)

		it("survives the JSON the save codec writes", function()
			local rows = sampleRows(50)
			local cols = HttpService:JSONDecode(HttpService:JSONEncode(CitizenSaveColumns.toColumns(rows)))
			expect(same(CitizenSaveColumns.fromColumns(cols), rows)).to.equal(true)
		end)

		it("turns junk into no rows instead of an error", function()
			expect(#CitizenSaveColumns.fromColumns(nil)).to.equal(0)
			expect(#CitizenSaveColumns.fromColumns({ h = { 1 }, ph = { 99 }, vh = { "x" }, jn = { 5 } })).to.equal(1)
		end)

		it("is smaller than rows once compressed", function()
			local rows = sampleRows(1000)
			local zstd = Enum.CompressionAlgorithm.Zstd
			local EncodingService = game:GetService("EncodingService")
			local function packed(v: any): number
				return buffer.len(EncodingService:CompressBuffer(buffer.fromstring(HttpService:JSONEncode(v)), zstd, 19))
			end
			local before, after = packed(rows), packed(CitizenSaveColumns.toColumns(rows))
			print(("[CitizenSaveColumns.spec] 1000 homes: rows %d B -> columns %d B (%.1f%%)"):format(before, after, (after / before - 1) * 100))
			expect(after < before * 0.9).to.equal(true)
		end)
	end)
end
