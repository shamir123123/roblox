--!strict
-- Segment ids are load-bearing: plot groups persist the id of the road they front, so an
-- id that does not survive the round trip rebinds every plot to a different road. They also
-- arrive from a DataStore blob, so the decode side is a trust boundary.
return function()
	local RoadSerializer = require(script.Parent.RoadSerializer)

	local function seg(over: any): any
		local base: any = {
			id = 42,
			p0 = Vector3.new(0, 10, 0), p1 = Vector3.new(10, 10, 0),
			p2 = Vector3.new(20, 10, 0), p3 = Vector3.new(30, 10, 0),
			roadType = "Street",
		}
		for k, v in pairs(over) do base[k] = v end
		return base
	end

	local function roundTrip(over: any): any
		return RoadSerializer.deserialize(RoadSerializer.serialize({ seg(over) }))[1]
	end

	describe("road serializer", function()
		it("carries the segment id through a save", function()
			expect(roundTrip({}).id).to.equal(42)
		end)

		it("keeps ids distinct across a whole network", function()
			local out = RoadSerializer.deserialize(RoadSerializer.serialize({
				seg({ id = 7 }), seg({ id = 900 }), seg({ id = 3 }),
			}))
			expect(out[1].id).to.equal(7)
			expect(out[2].id).to.equal(900)
			expect(out[3].id).to.equal(3)
		end)

		it("drops a junk id rather than trusting the blob", function()
			for _, junk in { "42", 0, -1, 4.5, 0 / 0, math.huge, 1e9 } do
				local entries = RoadSerializer.serialize({ seg({}) })
				entries[1].i = junk
				-- nil id = auto-assign on restore, which is the safe fallback.
				expect(RoadSerializer.deserialize(entries)[1].id).to.equal(nil)
			end
		end)

		it("still round-trips the geometry it always did", function()
			local out = roundTrip({})
			expect(out.p0.X).to.equal(0)
			expect(out.p3.X).to.equal(30)
			expect(out.roadType).to.equal("Street")
		end)
	end)
end
