--!strict
-- The one thing that must hold: a shallow approach comes out at the minimum angle, and a
-- clear one is left alone. If this fails, roads either stop bending (back to "angle too
-- shallow") or bend roads that were already fine.
return function()
	local ApproachBend = require(script.Parent)

	local MIN = math.rad(45)
	local EAST = Vector3.new(1, 0, 0)

	local function angleBetween(a: Vector3, b: Vector3): number
		return math.deg(math.acos(math.clamp(a.Unit:Dot(b.Unit), -1, 1)))
	end

	describe("clearDir", function()
		it("leaves a direction that already clears every arm alone", function()
			local d = ApproachBend.clearDir(Vector3.new(0, 0, 1), { EAST }, MIN)
			expect(angleBetween(d, Vector3.new(0, 0, 1))).to.be.near(0, 0.01)
		end)

		it("opens a shallow approach out to the minimum", function()
			-- 10 deg off an existing arm: must come back at 45.
			local shallow = Vector3.new(math.cos(math.rad(10)), 0, math.sin(math.rad(10)))
			local d = ApproachBend.clearDir(shallow, { EAST }, MIN)
			expect(angleBetween(d, EAST)).to.be.near(45, 0.01)
		end)

		it("turns away from the arm, keeping the side the player was heading", function()
			local shallow = Vector3.new(math.cos(math.rad(10)), 0, math.sin(math.rad(10)))
			local d = ApproachBend.clearDir(shallow, { EAST }, MIN)
			expect(d.Z > 0).to.equal(true)
			local other = Vector3.new(math.cos(math.rad(10)), 0, -math.sin(math.rad(10)))
			expect(ApproachBend.clearDir(other, { EAST }, MIN).Z < 0).to.equal(true)
		end)

		it("clears BOTH arms of a two-way host it is joining flat", function()
			local arms = { EAST, -EAST }
			local d = ApproachBend.clearDir(Vector3.new(1, 0, 0.05), arms, MIN)
			expect(angleBetween(d, EAST) >= 44.9).to.equal(true)
			expect(angleBetween(d, -EAST) >= 44.9).to.equal(true)
		end)
	end)

	describe("apply", function()
		local p0 = Vector3.new(0, 0, 0)
		local p3 = Vector3.new(300, 0, 30)

		it("rotates the start handle off a shallow arm", function()
			local p1 = p0 + (p3 - p0) / 3
			local p2 = p0 + (p3 - p0) * (2 / 3)
			local n1 = ApproachBend.apply(p0, p1, p2, p3, { EAST }, {}, 40, MIN)
			expect(angleBetween(n1 - p0, EAST) >= 40).to.equal(true)
		end)

		it("changes nothing when there are no arms", function()
			local p1 = p0 + (p3 - p0) / 3
			local p2 = p0 + (p3 - p0) * (2 / 3)
			local n1, n2 = ApproachBend.apply(p0, p1, p2, p3, {}, {}, 40, MIN)
			expect((n1 - p1).Magnitude).to.be.near(0)
			expect((n2 - p2).Magnitude).to.be.near(0)
		end)

		it("backs the bend off rather than returning a curve tighter than the road allows", function()
			-- A 30-stud stub cannot swing 45 deg and still hold a 200-stud radius, so the
			-- ladder must fall through to the handles it came in with.
			local s, e = Vector3.new(0, 0, 0), Vector3.new(30, 0, 1)
			local h1 = s + (e - s) / 3
			local h2 = s + (e - s) * (2 / 3)
			local n1, n2 = ApproachBend.apply(s, h1, h2, e, { EAST }, {}, 200, MIN)
			expect((n1 - h1).Magnitude).to.be.near(0)
			expect((n2 - h2).Magnitude).to.be.near(0)
		end)
	end)
end
