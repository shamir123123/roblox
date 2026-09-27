--!strict
-- The road grid: a drawn road snaps its LENGTH along its own heading, so swinging it round
-- keeps one length instead of hopping between world grid points (36 m, 38 m, 41 m...).
return function()
	local SnapUtil = require(script.Parent)
	local PlacementGrid = require(game:GetService("ReplicatedStorage").Shared.PlacementGrid)

	describe("grid", function()
		it("holds on an empty map and puts the start on a grid point", function()
			PlacementGrid.setSize(10)
			SnapUtil.setSegments({})
			SnapUtil.setGuideExclusion(nil)
			local r = SnapUtil.resolve(Vector3.new(13, 0, 27))
			expect(r.snapType).to.equal("grid")
			expect(r.position.X).to.equal(20)
			expect(r.position.Z).to.equal(20)
		end)

		it("keeps one length while the road swings round its start", function()
			PlacementGrid.setSize(10)
			SnapUtil.setSegments({})
			local start = Vector3.new(20, 0, 20)
			SnapUtil.setGuideExclusion(start)
			-- 37 m out (74 studs) on a 10 m grid is 40 m at EVERY heading.
			for deg = 0, 359, 15 do
				local a = math.rad(deg)
				local p = SnapUtil.resolve(start + Vector3.new(math.cos(a), 0, math.sin(a)) * 74).position
				expect((Vector3.new(p.X, 0, p.Z) - start).Magnitude).to.be.near(80, 1e-3)
			end
			SnapUtil.setGuideExclusion(nil)
			PlacementGrid.setEnabled(false)
		end)
	end)

	describe("angle magnet", function()
		it("squares up a road extended off another road, never one started on open ground", function()
			-- A road exists elsewhere on the map, so this is NOT the empty-map case.
			local RoadTypeCatalog = require(game:GetService("ReplicatedStorage").Road.RoadTypeCatalog)
			SnapUtil.setSegments({ [1] = { id = 1, p0 = Vector3.new(5000, 0, 0), p1 = Vector3.new(5010, 0, 0),
				p2 = Vector3.new(5020, 0, 0), p3 = Vector3.new(5030, 0, 0), roadType = RoadTypeCatalog.DEFAULT_ID } })
			SnapUtil.setAngleSnapEnabled(true)
			SnapUtil.setAngleFreeOverride(false)
			local start = Vector3.new(0, 0, 0)
			local nearlySquare = Vector3.new(3, 0, 100) -- ~88 degrees off +X
			-- Open ground: no road at the start, so no reference and no pull.
			expect(SnapUtil.angleSnap(start, nil, nearlySquare)).to.equal(nil)
			-- Extending a road running along +X: the same drag locks to a square T.
			local r = SnapUtil.angleSnap(start, Vector3.xAxis, nearlySquare)
			expect(r).to.be.ok()
			expect(math.abs((r :: any).angleDeg)).to.be.near(90, 1e-3)
		end)
	end)
end
