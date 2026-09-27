--!strict
-- The one grid: metres in, studs out, lines not cell centres, and Off still on the save's
-- 5 cm lattice. If any of these drift, a ghost stops landing where it is placed.
return function()
	local PlacementGrid = require(script.Parent)

	describe("PlacementGrid", function()
		it("offers 1, 5 and 10 metres", function()
			expect(table.concat(PlacementGrid.SIZES, ",")).to.equal("1,5,10")
		end)

		it("is off by default and snaps to 0.1 stud (two decimals of a metre) while off", function()
			PlacementGrid.setEnabled(false)
			expect(PlacementGrid.step()).to.equal(0)
			-- near, not equal: a Vector3 holds float32, so 12.3 comes back as 12.3000002.
			local p = PlacementGrid.snap(Vector3.new(12.3456, 7.777, -3.21))
			expect(p.X).to.be.near(12.3, 1e-4)
			expect(p.Y).to.be.near(7.777, 1e-4)
			expect(p.Z).to.be.near(-3.2, 1e-4)
		end)

		it("picking a size turns it on, in metres (two studs each)", function()
			PlacementGrid.setSize(5)
			expect(PlacementGrid.isEnabled()).to.equal(true)
			expect(PlacementGrid.step()).to.equal(10)
			local p = PlacementGrid.snap(Vector3.new(14.9, 3, -5.1))
			expect(p.X).to.equal(10)
			expect(p.Z).to.equal(-10)
			PlacementGrid.setSize(1)
			expect(PlacementGrid.snap(Vector3.new(3.1, 0, 0)).X).to.equal(4)
		end)

		it("refuses a size it does not offer", function()
			PlacementGrid.setSize(10)
			PlacementGrid.setSize(3)
			expect(PlacementGrid.getSize()).to.equal(10)
		end)

		it("tells listeners, and stops after disconnect", function()
			local calls = 0
			local off = PlacementGrid.onChanged(function() calls += 1 end)
			PlacementGrid.setEnabled(false)
			PlacementGrid.setSize(1)
			off()
			PlacementGrid.setEnabled(false)
			expect(calls).to.equal(2)
		end)
	end)
end
