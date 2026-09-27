--!strict
-- Access is per CITY now. The two failures that matter: a legacy account-wide grant
-- silently vanishing (a friend locked out of a city they were invited to), and a REVOKE
-- that does not stick because the legacy entry underneath it survived the write.

return function()
	local VisitorList = require(script.Parent)

	local LEGACY = { ["7"] = "builder" }
	local NESTED = { ["1"] = { ["7"] = "visitor" }, ["3"] = { ["9"] = "admin" } }

	describe("forSlot", function()
		it("reads one city's list", function()
			expect(VisitorList.forSlot(NESTED, 3)["9"]).to.equal("admin")
			expect(VisitorList.forSlot(NESTED, 1)["9"]).to.equal(nil)
		end)
		it("takes a slot id as a number or a string", function()
			expect(VisitorList.forSlot(NESTED, "3")["9"]).to.equal("admin")
		end)
		it("gives a legacy grant access to every city", function()
			expect(VisitorList.forSlot(LEGACY, 1)["7"]).to.equal("builder")
			expect(VisitorList.forSlot(LEGACY, 5)["7"]).to.equal("builder")
		end)
		it("lets the city's own entry win over the legacy one", function()
			local mixed = { ["7"] = "builder", ["2"] = { ["7"] = "visitor" } }
			expect(VisitorList.forSlot(mixed, 2)["7"]).to.equal("visitor")
			expect(VisitorList.forSlot(mixed, 1)["7"]).to.equal("builder")
		end)
		it("is empty for junk and for an out-of-range slot", function()
			expect(next(VisitorList.forSlot(nil, 1))).to.equal(nil)
			expect(next(VisitorList.forSlot("nope", 1))).to.equal(nil)
			expect(next(VisitorList.forSlot(NESTED, 99))).to.equal(nil)
		end)
		it("drops an unreadable role rather than defaulting it", function()
			expect(VisitorList.forSlot({ ["1"] = { ["7"] = "owner" } }, 1)["7"]).to.equal(nil)
		end)
	end)

	describe("anySlot", function()
		it("merges every city", function()
			local all = VisitorList.anySlot(NESTED)
			expect(all["7"]).to.equal("visitor")
			expect(all["9"]).to.equal("admin")
		end)
		it("includes legacy grants", function()
			expect(VisitorList.anySlot(LEGACY)["7"]).to.equal("builder")
		end)
	end)

	describe("set", function()
		it("writes a role into one city only", function()
			local out = VisitorList.set(nil, 2, 7, "builder") :: any
			expect(out["2"]["7"]).to.equal("builder")
			expect(out["1"]).to.equal(nil)
		end)
		it("leaves the other cities alone", function()
			local out = VisitorList.set(NESTED, 1, 9, "builder") :: any
			expect(out["1"]["9"]).to.equal("builder")
			expect(out["3"]["9"]).to.equal("admin")
		end)
		it("expands a legacy grant into every city before writing", function()
			-- Otherwise editing city 2 would strip the account-wide grant off cities 1 and 3.
			local out = VisitorList.set(LEGACY, 2, 8, "visitor") :: any
			expect(out["1"]["7"]).to.equal("builder")
			expect(out["5"]["7"]).to.equal("builder")
			expect(out["2"]["8"]).to.equal("visitor")
		end)
		it("makes a revoke stick over a legacy grant", function()
			local out = VisitorList.set(LEGACY, 2, 7, nil) :: any
			expect(VisitorList.forSlot(out, 2)["7"]).to.equal(nil)
			expect(VisitorList.forSlot(out, 1)["7"]).to.equal("builder")
		end)
		it("drops a city whose list is now empty", function()
			local out = VisitorList.set({ ["2"] = { ["7"] = "admin" } }, 2, 7, nil) :: any
			expect(out["2"]).to.equal(nil)
		end)
		it("refuses a slot id that is not one", function()
			expect(VisitorList.set(NESTED, 0, 7, "admin")).to.equal(nil)
			expect(VisitorList.set(NESTED, 6, 7, "admin")).to.equal(nil)
			expect(VisitorList.set(NESTED, "x", 7, "admin")).to.equal(nil)
		end)
	end)

	describe("invited", function()
		it("is true while a role survives in any city", function()
			local out = VisitorList.set(NESTED, 1, 7, nil)
			expect(VisitorList.invited(out, 7)).to.equal(false)
			expect(VisitorList.invited(NESTED, 9)).to.equal(true)
		end)
	end)
end
