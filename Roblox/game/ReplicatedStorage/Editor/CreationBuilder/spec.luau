--!strict
return function()
	local CreationBuilder = require(script.Parent)

	-- CFrame.new(x,y,z, R00..R22) with identity rotation.
	local function cf(x: number, y: number, z: number): { number }
		return { x, y, z, 1,0,0, 0,1,0, 0,0,1 }
	end

	-- A 4-stud block centred at Y=1002, so its base sits exactly on the editor plate (Y=1000).
	local function oneBlock(): any
		return { el = { { t = "p", shape = "Block", sz = {4,4,4}, cf = cf(0, 1002, 0), c = {200,50,50}, m = "Concrete", tr = 0 } } }
	end

	describe("build", function()
		it("returns nil for anything that is not a blob", function()
			expect(CreationBuilder.build(nil, nil) == nil).to.equal(true)
			expect(CreationBuilder.build("not a table", nil) == nil).to.equal(true)
			expect(CreationBuilder.build(42, nil) == nil).to.equal(true)
		end)

		it("returns nil rather than an empty Model when nothing was built", function()
			-- An empty Model parented into the city would be an invisible, unclickable
			-- ghost the bulldozer could never remove.
			expect(CreationBuilder.build({ el = {} }, nil) == nil).to.equal(true)
			expect(CreationBuilder.build({ el = "junk" }, nil) == nil).to.equal(true)
		end)

		it("builds one element per row and reports the count", function()
			local model, n = CreationBuilder.build(oneBlock(), nil)
			expect(model).to.be.ok()
			expect(n).to.equal(1)
			model:Destroy()
		end)

		it("skips malformed rows instead of aborting the whole creation", function()
			local blob = { el = {
				{ t = "p", shape = "Block", sz = {4,4,4}, cf = cf(0, 1002, 0) },
				{ t = "p", shape = "NotAShape", sz = {4,4,4}, cf = cf(6, 1002, 0) },
				"garbage",
				{ t = "p", shape = "Sphere", sz = {2,2,2}, cf = cf(12, 1002, 0) },
			} }
			local model, n = CreationBuilder.build(blob, nil)
			expect(n).to.equal(2)
			model:Destroy()
		end)
	end)

	describe("pivot", function()
		-- This is the contract the whole placement path leans on: the caller has a pivot
		-- already grounded on the terrain, and seats the creation with a single PivotTo.
		it("seats the model's pivot on its own base centre", function()
			local model = CreationBuilder.build(oneBlock(), nil)
			local p = model:GetPivot().Position
			expect(p.X).to.be.near(0)
			expect(p.Y).to.be.near(1000)
			expect(p.Z).to.be.near(0)
			model:Destroy()
		end)

		it("lands the base exactly on the placement Y", function()
			local model = CreationBuilder.build(oneBlock(), nil)
			model:PivotTo(CFrame.new(50, 12, 30))
			local bcf, bsize = model:GetBoundingBox()
			expect(bcf.Position.Y - bsize.Y * 0.5).to.be.near(12)
			expect(bcf.Position.X).to.be.near(50)
			expect(bcf.Position.Z).to.be.near(30)
			model:Destroy()
		end)

		it("rotates about the base centre without drifting or sinking", function()
			local model = CreationBuilder.build(oneBlock(), nil)
			model:PivotTo(CFrame.new(50, 12, 30) * CFrame.Angles(0, math.rad(90), 0))
			local bcf, bsize = model:GetBoundingBox()
			expect(bcf.Position.Y - bsize.Y * 0.5).to.be.near(12)
			expect(bcf.Position.X).to.be.near(50)
			expect(bcf.Position.Z).to.be.near(30)
			model:Destroy()
		end)
	end)

	describe("prop references", function()
		it("substitutes a scaled placeholder when the resolver cannot supply the model", function()
			-- The client cannot see ServerStorage, so its ghost MUST still show a silhouette.
			local blob = { el = { { t = "r", key = "Nope.Missing", cf = cf(0, 1001, 0), sc = 2 } } }
			local model, n = CreationBuilder.build(blob, nil)
			expect(model).to.be.ok()
			expect(n).to.equal(1)
			local _, size = model:GetBoundingBox()
			expect(size.X).to.be.near(8) -- 4-stud placeholder x scale 2
			model:Destroy()
		end)

		it("clones the resolved model and never the original", function()
			local source = Instance.new("Model")
			local part = Instance.new("Part")
			part.Size = Vector3.new(3, 3, 3)
			part.Parent = source
			source.PrimaryPart = part

			local blob = { el = { { t = "r", key = "Any.Key", cf = cf(0, 1001, 0), sc = 1 } } }
			local model = CreationBuilder.build(blob, function() return source end)
			expect(model).to.be.ok()
			expect(source.Parent == nil).to.equal(true) -- the template was not consumed
			local _, size = model:GetBoundingBox()
			expect(size.X).to.be.near(3)
			model:Destroy()
			source:Destroy()
		end)
	end)

	describe("parts", function()
		it("anchors everything and leaves visible parts clickable", function()
			-- Unanchored geometry would fall through the city; CanQuery=false would make it
			-- impossible for the bulldozer's ray to pick.
			local model = CreationBuilder.build(oneBlock(), nil)
			local part = model:FindFirstChildWhichIsA("BasePart")
			expect(part.Anchored).to.equal(true)
			expect(part.CanQuery).to.equal(true)
			model:Destroy()
		end)

		it("applies a known material and ignores an unknown one", function()
			local known = CreationBuilder.build(oneBlock(), nil)
			expect(known:FindFirstChildWhichIsA("BasePart").Material).to.equal(Enum.Material.Concrete)
			known:Destroy()

			local blob = oneBlock()
			blob.el[1].m = "Unobtainium"
			local model = CreationBuilder.build(blob, nil)
			expect(model).to.be.ok() -- did not throw on a bad Enum lookup
			model:Destroy()
		end)
	end)

	describe("count", function()
		it("counts a free composition without building it", function()
			expect(CreationBuilder.count(oneBlock())).to.equal(1)
			expect(CreationBuilder.count({ el = {} })).to.equal(0)
			expect(CreationBuilder.count("junk")).to.equal(0)
			expect(CreationBuilder.count(nil)).to.equal(0)
		end)

		it("counts a customised building as its overrides plus its loose primitives", function()
			local custom = {
				kind = "custom", base = "Some.Building", root = cf(0, 1000, 0),
				parts = { ["1"] = {}, ["2"] = {}, ["3"] = {} },
				prims = { {}, {} },
			}
			expect(CreationBuilder.count(custom)).to.equal(5)
		end)
	end)

	describe("converters", function()
		it("round-trips a CFrame through the number array", function()
			local original = CFrame.new(12.5, -3, 40) * CFrame.Angles(0, math.rad(35), 0)
			local back = CreationBuilder.arrToCf(CreationBuilder.cfToArr(original))
			expect((back.Position - original.Position).Magnitude).to.be.near(0)
			expect((back.LookVector - original.LookVector).Magnitude).to.be.near(0)
		end)

		it("round-trips a Vector3 and a Color3", function()
			local v = CreationBuilder.arrToV3(CreationBuilder.v3ToArr(Vector3.new(1, 2, 3)))
			expect(v.X).to.be.near(1)
			expect(v.Z).to.be.near(3)

			local c = CreationBuilder.arrToCol(CreationBuilder.colToArr(Color3.fromRGB(10, 20, 30)))
			expect(math.round(c.R * 255)).to.equal(10)
			expect(math.round(c.B * 255)).to.equal(30)
		end)

		it("falls back instead of erroring on malformed arrays", function()
			expect(CreationBuilder.arrToCf(nil)).to.equal(CFrame.identity)
			expect(CreationBuilder.arrToCf({ 1, 2 })).to.equal(CFrame.identity)
			expect(CreationBuilder.arrToV3(nil)).to.equal(Vector3.zero)
		end)
	end)

	describe("normalizeSoundId", function()
		it("reduces whatever the player pasted to a bare asset id", function()
			expect(CreationBuilder.normalizeSoundId("1234")).to.equal("rbxassetid://1234")
			expect(CreationBuilder.normalizeSoundId("rbxassetid://1234")).to.equal("rbxassetid://1234")
		end)

		it("rejects input with no digits at all", function()
			expect(CreationBuilder.normalizeSoundId("no digits here") == nil).to.equal(true)
			expect(CreationBuilder.normalizeSoundId(nil) == nil).to.equal(true)
			expect(CreationBuilder.normalizeSoundId(99) == nil).to.equal(true)
		end)
	end)
end
