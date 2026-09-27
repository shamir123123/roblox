--!strict
return function()
	local CreationCategories = require(script.Parent)

	describe("get", function()
		it("answers every key in the display order", function()
			for _, key in CreationCategories.order do
				expect(CreationCategories.get(key)).to.be.ok()
				expect(CreationCategories.get(key).key).to.equal(key)
			end
		end)

		it("returns nil for anything it does not define", function()
			expect(CreationCategories.get("Nope") == nil).to.equal(true)
			expect(CreationCategories.get("") == nil).to.equal(true)
			expect(CreationCategories.get(nil) == nil).to.equal(true)
			expect(CreationCategories.get(7) == nil).to.equal(true)
		end)
	end)

	describe("getOrDefault", function()
		it("never returns nil, whatever it is handed", function()
			-- A creation must never become unplaceable because its category went away.
			expect(CreationCategories.getOrDefault("Misc")).to.be.ok()
			expect(CreationCategories.getOrDefault(nil)).to.be.ok()
			expect(CreationCategories.getOrDefault(42)).to.be.ok()
			expect(CreationCategories.getOrDefault({})).to.be.ok()
		end)

		it("falls back to the declared default", function()
			-- "Misc" is what every creation saved before this list existed carries.
			expect(CreationCategories.getOrDefault("Misc").key).to.equal(CreationCategories.DEFAULT)
		end)

		it("passes a valid key straight through", function()
			expect(CreationCategories.getOrDefault("Landmark").key).to.equal("Landmark")
		end)
	end)

	describe("normalize", function()
		it("gives back a key that is always storable and always valid", function()
			expect(CreationCategories.normalize("Tree")).to.equal("Tree")
			expect(CreationCategories.isValid(CreationCategories.normalize("Misc"))).to.equal(true)
			expect(CreationCategories.isValid(CreationCategories.normalize(nil))).to.equal(true)
		end)
	end)

	describe("the catalog itself", function()
		it("declares a default that is one of its own entries", function()
			expect(CreationCategories.isValid(CreationCategories.DEFAULT)).to.equal(true)
		end)

		it("is frozen, so nothing can bolt a category on at runtime", function()
			expect(function() CreationCategories.byKey.Hacked = {} end).to.throw()
			expect(function() CreationCategories.order[1] = "Hacked" end).to.throw()
		end)

		it("gives every entry a label, a panel and a hint", function()
			for _, entry in CreationCategories.all() do
				expect(entry.label).to.be.a("string")
				expect(entry.panel).to.be.a("string")
				expect(entry.hint).to.be.a("string")
				expect(#entry.label > 0).to.equal(true)
				expect(#entry.hint > 0).to.equal(true)
			end
		end)

		it("lists exactly as many entries as it orders", function()
			local counted = 0
			for _ in CreationCategories.byKey do counted += 1 end
			expect(#CreationCategories.all()).to.equal(counted)
			expect(#CreationCategories.order).to.equal(counted)
		end)

		it("keeps Tree/Bush/Rock spelled the same as NatureCatalog's kinds", function()
			-- These share a chip row with the built-in props; if the strings drift, a
			-- player's custom oak silently stops filing next to the oaks.
			local NatureCatalog = require(game:GetService("ReplicatedStorage").Nature.NatureCatalog)
			local kinds: { [string]: boolean } = {}
			for _, entry in NatureCatalog.byKey do kinds[entry.kind] = true end
			expect(kinds.Tree).to.equal(true)
			expect(kinds.Bush).to.equal(true)
			expect(kinds.Rock).to.equal(true)
		end)
	end)
end
