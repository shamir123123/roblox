--!strict
-- The half of ReviewQueue that runs without a server. The submit / approve / reject paths
-- need a DataStore and a live server and are not reachable from Edit mode.
return function()
	local Shape = require(script.Parent)

	local function goodRow(over: any?): any
		local row = { ownerId = 123, ownerName = "Ada", name = "Fountain", cat = "Landmark", at = 1000 }
		if over then
			for k, v in over do row[k] = v end
		end
		return row
	end

	describe("sanitize", function()
		it("returns an empty record for anything that is not a table", function()
			expect(Shape.count(Shape.sanitize(nil, 10))).to.equal(0)
			expect(Shape.count(Shape.sanitize("junk", 10))).to.equal(0)
			expect(Shape.count(Shape.sanitize(7, 10))).to.equal(0)
		end)

		it("keeps a well-formed row and stamps its own id onto it", function()
			local out = Shape.sanitize({ bp_1 = goodRow() }, 10)
			expect(Shape.count(out)).to.equal(1)
			expect(out.bp_1.bpId).to.equal("bp_1")
			expect(out.bp_1.name).to.equal("Fountain")
			expect(out.bp_1.ownerId).to.equal(123)
			expect(out.bp_1.cat).to.equal("Landmark")
		end)

		it("drops a row with no usable name", function()
			-- The name is the only thing a curator reads to judge a submission, so a
			-- nameless row is unreviewable and must never reach the queue.
			-- Built inline, NOT via goodRow: `{ name = nil }` is an empty table in Lua, so
			-- an override cannot remove a key -- it would silently leave the name in place
			-- and the test would pass against code that never dropped anything.
			expect(Shape.count(Shape.sanitize({ bp_1 = { ownerId = 123, at = 1000 } }, 10))).to.equal(0)
			expect(Shape.count(Shape.sanitize({ bp_1 = goodRow({ name = 42 }) }, 10))).to.equal(0)
			expect(Shape.count(Shape.sanitize({ bp_1 = {} }, 10))).to.equal(0)
		end)

		it("drops rows that are not tables, and ids that are not strings", function()
			expect(Shape.count(Shape.sanitize({ bp_1 = "nope" }, 10))).to.equal(0)
			expect(Shape.count(Shape.sanitize({ [""] = goodRow() }, 10))).to.equal(0)
			expect(Shape.count(Shape.sanitize({ [5] = goodRow() }, 10))).to.equal(0)
		end)

		it("repairs missing fields rather than dropping the row", function()
			local out = Shape.sanitize({ bp_1 = { name = "Thing" } }, 10)
			expect(Shape.count(out)).to.equal(1)
			expect(out.bp_1.ownerId).to.equal(0)
			expect(out.bp_1.ownerName).to.equal("")
			expect(out.bp_1.cat).to.equal("Prop")
			expect(out.bp_1.at).to.equal(0)
		end)

		it("honours the cap so a runaway record cannot be loaded whole", function()
			local raw = {}
			for i = 1, 50 do raw["bp_" .. i] = goodRow() end
			expect(Shape.count(Shape.sanitize(raw, 10))).to.equal(10)
			expect(Shape.count(Shape.sanitize(raw, 0))).to.equal(0)
		end)

		it("carries a reviewer and a reason through when present", function()
			local out = Shape.sanitize({ bp_1 = goodRow({ by = 99, reason = "Not allowed" }) }, 10)
			expect(out.bp_1.by).to.equal(99)
			expect(out.bp_1.reason).to.equal("Not allowed")
		end)
	end)

	describe("clampReason", function()
		it("trims surrounding whitespace", function()
			expect(Shape.clampReason("   too rude   ")).to.equal("too rude")
		end)

		it("treats blank and non-string input as no reason given", function()
			expect(Shape.clampReason("") == nil).to.equal(true)
			expect(Shape.clampReason("    ") == nil).to.equal(true)
			expect(Shape.clampReason(nil) == nil).to.equal(true)
			expect(Shape.clampReason(42) == nil).to.equal(true)
		end)

		it("caps a very long reason instead of storing it whole", function()
			local clamped = Shape.clampReason(string.rep("x", 500))
			expect(clamped).to.be.ok()
			expect(#clamped <= Shape.MAX_REASON).to.equal(true)
		end)
	end)

	describe("sortedRows", function()
		it("puts the newest submission first", function()
			local record = Shape.sanitize({
				old = goodRow({ at = 100 }),
				newest = goodRow({ at = 300 }),
				middle = goodRow({ at = 200 }),
			}, 10)
			local rows = Shape.sortedRows(record)
			expect(rows[1].bpId).to.equal("newest")
			expect(rows[2].bpId).to.equal("middle")
			expect(rows[3].bpId).to.equal("old")
		end)

		it("breaks a timestamp tie by id so the order never flickers", function()
			-- Two submissions in the same second would otherwise sort arbitrarily, and the
			-- list would reshuffle under a curator's cursor between refreshes.
			local record = Shape.sanitize({
				bp_b = goodRow({ at = 500 }),
				bp_a = goodRow({ at = 500 }),
			}, 10)
			local rows = Shape.sortedRows(record)
			expect(rows[1].bpId).to.equal("bp_a")
			expect(rows[2].bpId).to.equal("bp_b")
		end)

		it("handles an empty record", function()
			expect(#Shape.sortedRows({})).to.equal(0)
		end)
	end)

	describe("oldestId", function()
		it("finds the row to evict when a capped record is full", function()
			local record = Shape.sanitize({
				keep = goodRow({ at = 900 }),
				evict = goodRow({ at = 5 }),
			}, 10)
			expect(Shape.oldestId(record)).to.equal("evict")
		end)

		it("returns nil for an empty record", function()
			expect(Shape.oldestId({}) == nil).to.equal(true)
		end)
	end)
end
