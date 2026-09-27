--!strict
-- Trees do not stand on the road -- not even an ELEVATED one whose ground has been sculpted
-- up underneath it. The test used to compare the prop's BASE with the deck, so a tree rooted
-- a layer below cleared it and then grew straight up through the carriageway. Pinned here
-- because nothing breaks loudly when a placement veto quietly stops firing.
return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local RoadProximity   = require(script.Parent.RoadProximity)
	local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)
	local NatureCatalog   = require(ReplicatedStorage.Nature.NatureCatalog)

	local DECK   = 40   -- an elevated road
	local GROUND = 25   -- terrain sculpted up under it: 15 studs of clearance
	local WIDTH  = RoadTypeCatalog.getOrDefault("NarrowRoad").width
	local RADIUS = 3

	-- One straight elevated road along +X, passing over the origin.
	local function deck(): { any }
		local a, b = Vector3.new(-100, DECK, 0), Vector3.new(100, DECK, 0)
		return { { id = 1, roadType = "NarrowRoad",
			p0 = a, p1 = a:Lerp(b, 1 / 3), p2 = a:Lerp(b, 2 / 3), p3 = b } }
	end

	describe("isPointNearRoad", function()
		it("refuses a prop standing on the carriageway", function()
			expect(RoadProximity.isPointNearRoad(deck(), Vector3.new(0, DECK, 0), RADIUS, 30)).to.equal(true)
		end)

		it("allows a shrub on the ground under the deck", function()
			expect(RoadProximity.isPointNearRoad(deck(), Vector3.new(0, GROUND, 0), RADIUS, 6)).to.equal(false)
		end)

		it("refuses a tree tall enough to grow up through the deck", function()
			expect(RoadProximity.isPointNearRoad(deck(), Vector3.new(0, GROUND, 0), RADIUS, 30)).to.equal(true)
		end)

		it("allows a tall tree clear of the carriageway in plan", function()
			local z = WIDTH * 0.5 + RADIUS + 8
			expect(RoadProximity.isPointNearRoad(deck(), Vector3.new(0, GROUND, z), RADIUS, 30)).to.equal(false)
		end)

		it("with no height given, judges the base alone as it always did", function()
			expect(RoadProximity.isPointNearRoad(deck(), Vector3.new(0, GROUND, 0), RADIUS)).to.equal(false)
		end)
	end)

	-- The same rule from the road's side: a road laid over a tree takes the tree with it,
	-- and the road ghost highlights exactly that set in white before the click. If these
	-- two ever stop agreeing with isPointNearRoad above, the tool highlights one set of
	-- trees and deletes another -- which is worse than doing neither.
	local KEY = "OakTree"              -- a real catalog entry, radius 4
	local TREE_RADIUS = NatureCatalog.get(KEY).radius
	local TREE_HEIGHT = 30

	-- A model shaped like something standing in the world: pivoted on its BASE, `height`
	-- studs tall. `tagged` adds the two attributes NaturePlaceService stamps on every
	-- placement -- without them it is scenery the road must leave alone.
	local function model(pos: Vector3, height: number?, tagged: boolean?): Model
		local part = Instance.new("Part")
		part.Size = Vector3.new(2, height or TREE_HEIGHT, 2)
		local mdl = Instance.new("Model")
		part.Parent = mdl
		part.CFrame = CFrame.new(pos + Vector3.new(0, part.Size.Y * 0.5, 0))
		mdl.WorldPivot = CFrame.new(pos)
		if tagged ~= false then
			mdl:SetAttribute("NatureKey", KEY)
			mdl:SetAttribute("NatureScale", 1)
		end
		return mdl
	end

	local function prop(pos: Vector3, height: number?): Model
		return model(pos, height, true)
	end

	local function folderOf(models: { Model }): Folder
		local f = Instance.new("Folder")
		for _, mdl in models do mdl.Parent = f end
		return f
	end

	describe("propsOnRoads", function()
		it("takes a tree standing on the carriageway", function()
			local f = folderOf({ prop(Vector3.new(0, DECK, 0)) })
			expect(#RoadProximity.propsOnRoads(f, deck())).to.equal(1)
		end)

		it("leaves one set back clear of the kerb", function()
			local z = WIDTH * 0.5 + TREE_RADIUS + 8
			local f = folderOf({ prop(Vector3.new(0, DECK, z)) })
			expect(#RoadProximity.propsOnRoads(f, deck())).to.equal(0)
		end)

		it("leaves a shrub under the deck but takes a tree that reaches it", function()
			local shrub = folderOf({ prop(Vector3.new(0, GROUND, 0), 6) })
			expect(#RoadProximity.propsOnRoads(shrub, deck())).to.equal(0)
			local tree = folderOf({ prop(Vector3.new(0, GROUND, 0), 30) })
			expect(#RoadProximity.propsOnRoads(tree, deck())).to.equal(1)
		end)

		it("ignores anything in the folder that is not a placed prop", function()
			local f = folderOf({ model(Vector3.new(0, DECK, 0), nil, false) })
			expect(#RoadProximity.propsOnRoads(f, deck())).to.equal(0)
		end)
	end)

	describe("propsInDisc", function()
		local RING = 40

		it("takes a tree inside the ring's pavement", function()
			local f = folderOf({ prop(Vector3.new(RING - 2, DECK, 0)) })
			expect(#RoadProximity.propsInDisc(f, Vector3.new(0, DECK, 0), RING)).to.equal(1)
		end)

		it("leaves one outside it", function()
			local f = folderOf({ prop(Vector3.new(RING + TREE_RADIUS + 5, DECK, 0)) })
			expect(#RoadProximity.propsInDisc(f, Vector3.new(0, DECK, 0), RING)).to.equal(0)
		end)
	end)
end
