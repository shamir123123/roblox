--!strict
-- The one thing that silently rots here: adding a shape to ShapeCatalog and forgetting to
-- re-run ServerStorage.Authoring.ShapeBuilder. The catalog still lists it, the Nature tab
-- still draws a card for it, and clicking that card does nothing at all.
return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local ShapeCatalog = require(script.Parent)
	local NatureCatalog = require(ReplicatedStorage.Nature.NatureCatalog)
	local CreationBuilder = require(ReplicatedStorage.Editor.CreationBuilder)

	describe("catalog", function()
		it("answers every key in the order", function()
			for _, key in ShapeCatalog.order do
				expect(ShapeCatalog.get(key)).to.be.ok()
				expect(ShapeCatalog.get(key).key).to.equal(key)
				expect(#ShapeCatalog.get(key).name > 0).to.equal(true)
			end
		end)

		it("returns nil for anything it does not define", function()
			expect(ShapeCatalog.get("Nope") == nil).to.equal(true)
			expect(ShapeCatalog.get(nil) == nil).to.equal(true)
			expect(ShapeCatalog.get(7) == nil).to.equal(true)
		end)
	end)

	describe("baked templates", function()
		it("has a Nature model for every shape", function()
			for _, key in ShapeCatalog.all do
				local model = ReplicatedStorage.Nature:FindFirstChild(key)
				expect(model).to.be.ok()
				expect(model:IsA("Model")).to.equal(true)
			end
		end)

		it("builds every shape as exactly one BasePart", function()
			-- One part is the whole contract: it is what lets a shape ride the editor's
			-- per-primitive element format (own size, colour, material, sound).
			for _, key in ShapeCatalog.all do
				local part = CreationBuilder.makePrimitive(key)
				expect(part).to.be.ok()
				expect(part:IsA("BasePart")).to.equal(true)
				expect(part.Size.X > 0.1 and part.Size.Y > 0.1 and part.Size.Z > 0.1).to.equal(true)
				part:Destroy()
			end
		end)

		it("refuses a shape it does not know", function()
			expect(CreationBuilder.makePrimitive("NotAShape") == nil).to.equal(true)
		end)
	end)

	describe("nature integration", function()
		it("shelves every shape under the Shape kind", function()
			for _, key in ShapeCatalog.order do
				local entry = NatureCatalog.get(key)
				expect(entry).to.be.ok()
				expect(entry.kind).to.equal("Shape")
			end
		end)

		it("keeps the shape block whole, in order, and where it has always been", function()
			-- A saved city stores each prop's INDEX in that array, so no shape's index may
			-- ever move. The shapes were appended after the trees; later additions (the car
			-- parks) go after the shapes, which is why this no longer asserts "at the end".
			local order = NatureCatalog.order
			local firstShape: number? = nil
			for i, key in order do
				if NatureCatalog.get(key).kind == "Shape" then firstShape = i; break end
			end
			expect(firstShape).to.be.ok()
			local start = firstShape :: number
			for i = 1, #ShapeCatalog.order do
				expect(order[start + i - 1]).to.equal(ShapeCatalog.order[i])
			end
			expect(NatureCatalog.get(order[start - 1]).kind ~= "Shape").to.equal(true)
			-- Then the car parks, then the shapes ADDED later -- and those last, in their order.
			local added = ShapeCatalog.added
			for i = start + #ShapeCatalog.order, #order - #added do
				expect(NatureCatalog.get(order[i]).kind ~= "Shape").to.equal(true)
			end
			for i = 1, #added do
				expect(order[#order - #added + i]).to.equal(added[i])
			end
		end)

		it("only offers shapes it knows, each once", function()
			local seen = {}
			for _, key in ShapeCatalog.shelf do
				expect(ShapeCatalog.get(key) ~= nil).to.equal(true)
				expect(seen[key] == nil).to.equal(true)
				seen[key] = true
				expect(ShapeCatalog.isHidden(key)).to.equal(false)
			end
			-- A retired shape stays loadable: it is still a Shape entry, just not shelved.
			expect(ShapeCatalog.isHidden("Gear")).to.equal(true)
			expect(NatureCatalog.get("Gear").kind).to.equal("Shape")
		end)
	end)
end
