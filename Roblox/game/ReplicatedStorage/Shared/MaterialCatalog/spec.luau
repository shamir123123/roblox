--!strict
-- A saved prop stores its material as an INDEX into MaterialCatalog.order, so the list is
-- append-only. Inserting or reordering an entry silently repaints every prop in every city
-- ever saved -- the kind of break that ships, because nothing errors and the game looks
-- fine until someone loads an old city.
return function()
	local MaterialCatalog = require(script.Parent)

	-- The opening run, frozen. Anything inserted above these fails here rather than in a
	-- player's city.
	local PREFIX = {
		"Plastic", "SmoothPlastic", "Neon", "Glass", "ForceField",
		"Wood", "WoodPlanks", "Concrete",
	}

	describe("order", function()
		it("keeps its opening entries at their indices", function()
			for i, name in PREFIX do
				expect(MaterialCatalog.order[i]).to.equal(name)
			end
		end)

		it("is frozen and free of duplicates", function()
			expect(table.isfrozen(MaterialCatalog.order)).to.equal(true)
			local seen: { [string]: boolean } = {}
			for _, name in MaterialCatalog.order do
				-- A duplicate would give one material two indices, and indexOf would answer
				-- with the later one while the picker showed the earlier.
				expect(seen[name]).to.equal(nil)
				seen[name] = true
			end
		end)

		it("names only materials that exist", function()
			for i, name in MaterialCatalog.order do
				local mat = MaterialCatalog.get(i)
				expect(mat ~= nil).to.equal(true)
				expect(tostring(mat)).to.equal("Enum.Material." .. name)
			end
		end)
	end)

	describe("lookup", function()
		it("round-trips name and index", function()
			for i, name in MaterialCatalog.order do
				expect(MaterialCatalog.indexOf(name)).to.equal(i)
			end
		end)

		it("answers nil for 'no override' and for anything out of range", function()
			-- 0 is what every prop placed before the picker existed carries.
			expect(MaterialCatalog.get(0)).to.equal(nil)
			expect(MaterialCatalog.get(nil)).to.equal(nil)
			expect(MaterialCatalog.get(-3)).to.equal(nil)
			expect(MaterialCatalog.get(#MaterialCatalog.order + 1)).to.equal(nil)
			expect(MaterialCatalog.indexOf("NotAMaterial")).to.equal(0)
		end)
	end)
end
