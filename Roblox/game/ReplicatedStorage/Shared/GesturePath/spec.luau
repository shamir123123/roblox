--!strict
return function()
	local GesturePath = require(script.Parent)

	local function v(x: number, z: number): Vector3
		return Vector3.new(x, 0, z)
	end

	describe("row", function()
		it("spaces points evenly along the line", function()
			local pts = GesturePath.row(v(0, 0), v(100, 0), 20, 64)
			expect(#pts).to.equal(6) -- 0, 20, 40, 60, 80, 100
			expect(pts[1].X).to.be.near(0)
			expect(pts[2].X).to.be.near(20)
			expect(pts[6].X).to.be.near(100)
		end)

		it("flattens everything to the ground plane", function()
			-- The caller grounds the points; a stray Y here would place a row in mid-air.
			for _, p in GesturePath.row(Vector3.new(0, 500, 0), Vector3.new(60, -200, 0), 20, 64) do
				expect(p.Y).to.equal(0)
			end
		end)

		it("returns a single point when the ends coincide", function()
			local pts = GesturePath.row(v(10, 10), v(10, 10), 20, 64)
			expect(#pts).to.equal(1)
			expect(pts[1].X).to.be.near(10)
		end)

		it("honours the caller's cap", function()
			-- The cap exists because the row must not outgrow what the server accepts in one
			-- call; overrunning it drops the tail AFTER the player watched it previewed.
			expect(#GesturePath.row(v(0, 0), v(10000, 0), 1, 12)).to.equal(12)
			expect(#GesturePath.row(v(0, 0), v(10000, 0), 1, 64)).to.equal(64)
		end)

		it("clamps a spacing that would produce overlapping spam", function()
			-- spacing 0 would divide by nothing and ask for infinite points.
			local pts = GesturePath.row(v(0, 0), v(20, 0), 0, 64)
			expect(#pts <= 11).to.equal(true)
			expect(#pts > 1).to.equal(true)
		end)

		it("works diagonally, not just on an axis", function()
			local pts = GesturePath.row(v(0, 0), v(30, 40), 10, 64) -- 3-4-5, length 50
			expect(#pts).to.equal(6)
			expect((pts[2] - pts[1]).Magnitude).to.be.near(10, 1e-4)
		end)
	end)

	describe("controlPoints", function()
		it("keeps the endpoints and puts both handles 2/3 toward the bend", function()
			local s, q, e = v(0, 0), v(30, 0), v(60, 0)
			local p0, p1, p2, p3 = GesturePath.controlPoints(s, q, e)
			expect((p0 - s).Magnitude).to.be.near(0)
			expect((p3 - e).Magnitude).to.be.near(0)
			expect(p1.X).to.be.near(20) -- 0 + (30-0) * 2/3
			expect(p2.X).to.be.near(40) -- 60 + (30-60) * 2/3
		end)

		it("degenerates to a straight line when the bend is on the chord", function()
			local p0, p1, p2, p3 = GesturePath.controlPoints(v(0, 0), v(50, 0), v(100, 0))
			for _, p in { p0, p1, p2, p3 } do expect(p.Z).to.be.near(0) end
		end)
	end)

	describe("curve", function()
		it("spaces by ARC LENGTH, not by the bezier parameter", function()
			-- The whole reason this is not a plain t-sweep: t bunches points up on the tight
			-- part of a bend, so a row of trees would visibly clump there.
			local p0, p1, p2, p3 = GesturePath.controlPoints(v(0, 0), v(60, 60), v(120, 0))
			local pts = GesturePath.curve(p0, p1, p2, p3, 15, 64)
			expect(#pts > 3).to.equal(true)
			local shortest, longest = math.huge, 0
			for i = 2, #pts do
				local d = (pts[i] - pts[i - 1]).Magnitude
				shortest = math.min(shortest, d)
				longest = math.max(longest, d)
			end
			-- Even sampling keeps every gap close to the requested spacing.
			expect(longest - shortest < 4).to.equal(true)
			expect(shortest > 10).to.equal(true)
			expect(longest < 20).to.equal(true)
		end)

		it("starts at the first control point", function()
			local p0, p1, p2, p3 = GesturePath.controlPoints(v(5, 7), v(60, 60), v(120, 0))
			local pts = GesturePath.curve(p0, p1, p2, p3, 15, 64)
			expect(pts[1].X).to.be.near(5)
			expect(pts[1].Z).to.be.near(7)
		end)

		it("flattens to the ground plane", function()
			local p0, p1, p2, p3 = GesturePath.controlPoints(
				Vector3.new(0, 90, 0), Vector3.new(60, 90, 60), Vector3.new(120, 90, 0))
			for _, p in GesturePath.curve(p0, p1, p2, p3, 15, 64) do
				expect(p.Y).to.equal(0)
			end
		end)

		it("returns a single point for a zero-length curve", function()
			local pts = GesturePath.curve(v(3, 3), v(3, 3), v(3, 3), v(3, 3), 15, 64)
			expect(#pts).to.equal(1)
			expect(pts[1].X).to.be.near(3)
		end)

		it("honours the caller's cap", function()
			local p0, p1, p2, p3 = GesturePath.controlPoints(v(0, 0), v(500, 500), v(1000, 0))
			expect(#GesturePath.curve(p0, p1, p2, p3, 1, 12)).to.equal(12)
		end)

		it("matches row() on a straight degenerate curve", function()
			-- Line previews reuse the curve renderer with degenerate control points, so the
			-- two must agree or the preview and the commit would place differently.
			local a, b = v(0, 0), v(100, 0)
			local straight = GesturePath.row(a, b, 20, 64)
			local degenerate = GesturePath.curve(a, a, b, b, 20, 64)
			expect(#degenerate).to.equal(#straight)
			for i = 1, #straight do
				expect((degenerate[i] - straight[i]).Magnitude).to.be.near(0, 0.5)
			end
		end)
	end)
end
