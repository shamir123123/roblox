--!strict
return function()
	local TravelModeChoice = require(script.Parent)

	local function share(trip: any, mode: string): number
		local hits = 0
		for pid = 1, 400 do
			trip.pid = pid
			if (TravelModeChoice.choose(trip)) == mode then
				hits += 1
			end
		end
		return hits / 400
	end

	local goodBus = { timeSeconds = 0, fare = 2, walkSeconds = 80, waitSeconds = 80, rideSeconds = 260 }

	describe("mode choice", function()
		it("walks a short hop even with the car on the drive", function()
			expect(share({ age = 40, distance = 150, canDrive = true, parkWalk = 10 }, "walk") > 0.95).to.equal(true)
		end)

		it("mostly drives a long trip when parking is easy and there is no bus", function()
			expect(share({ age = 40, distance = 3000, canDrive = true, parkWalk = 10 }, "drive") > 0.95).to.equal(true)
		end)

		it("leaves the car at home when there is nowhere to park and a bus goes there", function()
			expect(share({ age = 40, distance = 3000, canDrive = true, parkWalk = nil, transit = goodBus }, "transit") > 0.95).to.equal(true)
		end)

		it("a good bus line wins a real share even against easy parking", function()
			local s = share({ age = 40, distance = 3000, canDrive = true, parkWalk = 10, transit = goodBus }, "transit")
			expect(s > 0.1 and s < 0.6).to.equal(true)
		end)

		it("an adult without a car never drives", function()
			expect(share({ age = 40, distance = 3000, canDrive = false, parkWalk = 10 }, "drive")).to.equal(0)
		end)

		it("seniors walk less far than younger adults", function()
			local young = share({ age = 30, distance = 450, canDrive = true, parkWalk = 10 }, "walk")
			local old = share({ age = 80, distance = 450, canDrive = true, parkWalk = 10 }, "walk")
			expect(old < young).to.equal(true)
		end)

		it("about nine adults in ten own a car", function()
			local owners = 0
			for pid = 1, 2000 do
				if TravelModeChoice.ownsCar(pid) then owners += 1 end
			end
			expect(owners > 1700 and owners < 1900).to.equal(true)
		end)

		it("a person's choice for the same trip is stable (a habit)", function()
			local trip = { pid = 77, age = 40, distance = 600, canDrive = true, parkWalk = 30, transit = goodBus }
			local first = TravelModeChoice.choose(trip)
			for _ = 1, 10 do
				expect((TravelModeChoice.choose(trip))).to.equal(first)
			end
		end)
	end)
end
