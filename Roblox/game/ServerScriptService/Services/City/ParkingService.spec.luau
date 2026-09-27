--!strict
-- The one rule a car park has to keep: a stall holds ONE car, and a driver whose own street
-- is full still ends up in a real bay instead of being spirited out of the world. That is
-- the whole point of reserveNearest's lot fallback -- the radius bounds KERBSIDE bays only,
-- because a bay two districts away is not somewhere anyone parks, but a car park is exactly
-- the place you drive to when the street outside your house is taken.
return function()
	local CollectionService = game:GetService("CollectionService")
	local ServerStorage = game:GetService("ServerStorage")
	local ParkingService = require(script.Parent.ParkingService)

	local STALLS = 3
	local FAR = 600      -- well outside any sane kerbside radius, well inside the lot fallback
	local TOO_FAR = 4000 -- outside the fallback too: nobody drives across the map to park

	-- No road network: the kerbside index stays empty, so every spot in play is a lot stall
	-- and a hit can only have come through the fallback.
	ParkingService.Init({
		getNetwork = function() return nil end,
		onTopologyChanged = function() return function() end end,
	})
	ParkingService.Bind()

	local lot = Instance.new("Model")
	lot.Name = "_ParkingSpecLot"
	lot:SetAttribute("NatureKey", "ParkingLotRow")
	local slab = Instance.new("Part")
	slab.Name = "Slab"
	slab.Anchored = true
	slab.CFrame = CFrame.new(0, 0, 0)
	slab.Parent = lot
	lot.PrimaryPart = slab
	for i = 1, STALLS do
		local att = Instance.new("Attachment")
		att.Name = "Stall"
		att.WorldCFrame = CFrame.new(i * 6, 0, 0)
		att.Parent = slab
	end
	lot.Parent = ServerStorage
	CollectionService:AddTag(lot, "NatureProp")
	ParkingService.Start()

	local function reserveAll(): { string }
		local ids: { string } = {}
		while true do
			local id = ParkingService.reserveNearest(Vector3.new(FAR, 0, 0), 10)
			if not id then break end
			table.insert(ids, id)
		end
		return ids
	end

	describe("a car park is the overflow when the street outside is full", function()
		it("hands out a stall far outside the kerbside search radius", function()
			local id, cf = ParkingService.reserveNearest(Vector3.new(FAR, 0, 0), 10)
			expect(id ~= nil).to.equal(true)
			expect(cf ~= nil).to.equal(true)
			ParkingService.release(id)
		end)

		it("does not send a driver clear across the map for a bay", function()
			local id = ParkingService.reserveNearest(Vector3.new(TOO_FAR, 0, 0), 10)
			expect(id).to.equal(nil)
		end)
	end)

	describe("a stall holds one car", function()
		it("never issues the same stall twice, and runs out at capacity", function()
			local ids = reserveAll()
			expect(#ids).to.equal(STALLS)
			local seen: { [string]: boolean } = {}
			for _, id in ids do
				expect(seen[id]).to.equal(nil)
				seen[id] = true
			end
			expect(ParkingService.GetParkingStats().free).to.equal(0)
			-- A full lot must report empty-handed, not double-park.
			expect((ParkingService.reserveNearest(Vector3.new(FAR, 0, 0), 10))).to.equal(nil)

			ParkingService.release(ids[2])
			expect(ParkingService.GetParkingStats().free).to.equal(1)
			expect((ParkingService.reserveNearest(Vector3.new(FAR, 0, 0), 10))).to.equal(ids[2])
			for _, id in ids do ParkingService.release(id) end
		end)
	end)

	CollectionService:RemoveTag(lot, "NatureProp")
	lot:Destroy()

	local RoadConstants = require(game:GetService("ReplicatedStorage").Road.RoadConstants)
	local RoadTypeCatalog = require(game:GetService("ReplicatedStorage").Road.RoadTypeCatalog)
	local JOIN_X = 200
	local TAPER_FROM = JOIN_X - RoadConstants.ROAD_WIDTH_TRANSITION_LENGTH

	-- A street along +X from 0 to JOIN_X, joining `nextType` there. Returns its kerbside bays
	-- (lot stalls sit on the axis, so |Z| > 1 is kerbside).
	local function kerbBays(streetType: string, nextType: string): { Vector3 }
		local function straight(id: number, a: Vector3, b: Vector3, roadType: string, s: number, e: number)
			return { id = id, p0 = a, p1 = a:Lerp(b, 1 / 3), p2 = a:Lerp(b, 2 / 3), p3 = b, roadType = roadType, startNode = s, endNode = e }
		end
		local segs = {
			[1] = straight(1, Vector3.zero, Vector3.new(JOIN_X, 0, 0), streetType, 1, 2),
			[2] = straight(2, Vector3.new(JOIN_X, 0, 0), Vector3.new(JOIN_X + 60, 0, 0), nextType, 2, 3),
		}
		local nodes = { [1] = { segments = { 1 } }, [2] = { segments = { 1, 2 } }, [3] = { segments = { 2 } } }
		local net = {
			getNodes = function() return nodes end,
			getSegment = function(_, id) return segs[id] end,
			getSegments = function() return segs end,
		}
		ParkingService.Init({ getNetwork = function() return net end, onTopologyChanged = function() return function() end end })
		ParkingService.Start()
		local bays: { Vector3 } = {}
		for _, s in ParkingService.GetParkingDebug() do
			if math.abs(s.pos.Z) > 1 then table.insert(bays, s.pos) end
		end
		return bays
	end

	describe("kerb bays at a join onto a narrower road", function()
		it("stop before the taper when that road does not park (street -> alley)", function()
			local bays = kerbBays("NarrowRoad|pk=b", "Alley")
			-- The street has to park at all, or the bound below asserts nothing.
			expect(#bays > 0).to.equal(true)
			for _, p in bays do
				expect(p.X < TAPER_FROM).to.equal(true)
			end
		end)

		it("run on into the taper, pulled in with the kerb, when that road parks too", function()
			local last: Vector3? = nil
			for _, p in kerbBays("CollectorRoad|pk=b", "NarrowRoad|pk=b") do
				-- The narrow road parks too; only the street's own bays count.
				if p.X < JOIN_X and (not last or p.X > last.X) then last = p end
			end
			expect(last ~= nil).to.equal(true)
			local p = last :: Vector3
			expect(p.X > TAPER_FROM).to.equal(true)
			-- Off the wide street's kerb line and onto the road it merges into.
			expect(math.abs(p.Z) < RoadTypeCatalog.get("NarrowRoad|pk=b").width * 0.5).to.equal(true)
		end)
	end)
end
