--!strict
-- The electricity grid contract. The rule that matters most, and the one easiest to break
-- by accident, is that poles carry power to each other ONLY along a wire the player drew --
-- proximity is not a connection. Everything else hangs off that: a building takes power
-- from a pole standing in its supply area, and a generator's area is only its own yard.
--
-- Two rules changed and are worth stating plainly, because both used to be the opposite:
-- every building asks for power from the day it is built, whether or not the player has
-- laid a single pole; and a grid that is SHORT does not black out -- the supply is rationed
-- and only the buildings it did not stretch to go dark.
return function()
	local Workspace = game:GetService("Workspace")
	local ServerStorage = game:GetService("ServerStorage")
	local PowerService = require(script.Parent.PowerService)
	local ServiceTypes = require(game:GetService("ReplicatedStorage").City.ServiceTypes)

	local MAP_HALF = require(game:GetService("ReplicatedStorage").Road.RoadConstants).MAP_HALF_EXTENT
	local REACH = ServiceTypes.PowerBuildingReach

	-- placeRun grounds each pole through ServicePlacement, which reads the terrain field.
	-- Booting the data service gives it a flat one to read; without this the run tests are
	-- exercising an uninitialised height lookup rather than the placement logic.
	local TerrainDataService = require(game:GetService("ServerScriptService")
		.Services.Terrain.TerrainDataService)
	pcall(TerrainDataService.Init)

	-- gatherNodes only counts a generator whose model is still parented.
	local liveModel = Instance.new("Folder")
	liveModel.Name = "_PowerSpecModel"
	liveModel.Parent = ServerStorage

	local turbines: { any } = {}
	local buildings: { any } = {}

	-- Records what PowerService pushes back onto the buildings domain.
	local powered: { [string]: boolean } = {}
	local abandoned: { [string]: boolean } = {}
	local fakeBuildings = {
		listBuildings = function() return buildings end,
		setPowered = function(bp: string, on: boolean) powered[bp] = on end,
	}
	-- Streets, as RoadService's network hands them over. Empty unless a test lays one.
	local streets: { any } = {}
	local fakeRoads = {
		getNetwork = function() return { getSegments = function() return streets end } end,
	}
	PowerService.Init({}, fakeBuildings, { list = function() return turbines end }, nil, nil, fakeRoads)

	-- A straight street from (x0, z) to (x1, z), joined to others through its node ids.
	local function street(x0: number, x1: number, z: number, fromNode: number, toNode: number)
		local a, b = Vector3.new(x0, 0, z), Vector3.new(x1, 0, z)
		streets[#streets + 1] = {
			p0 = a, p1 = a:Lerp(b, 1 / 3), p2 = a:Lerp(b, 2 / 3), p3 = b,
			startNode = fromNode, endNode = toNode,
		}
		PowerService.markRoadsDirty()
	end

	-- A service building that DRAWS power (a pump) rather than making it.
	local function pump(x: number, z: number): number
		local id = 100 + #turbines
		turbines[#turbines + 1] = {
			id = id, key = "WaterTower", kind = "Water", cf = CFrame.new(x, 0, z),
			radius = 24, model = liveModel,
		}
		return id
	end

	local function turbine(x: number, z: number, key: string?)
		local k = key or "WindTurbine"
		turbines[#turbines + 1] = {
			id = #turbines + 1, key = k, kind = "Power", cf = CFrame.new(x, 0, z),
			radius = (ServiceTypes.get(k) :: any).coverageRadius, model = liveModel,
		}
	end

	local function home(id: string, x: number, z: number, residents: number)
		buildings[#buildings + 1] = {
			bpId = id, zone = "Residential", level = 1, fill = 0,
			abandoned = false, residents = residents, position = Vector3.new(x, 0, z),
		}
	end

	-- A home already given up on: still standing, drawing nothing.
	local function ruin(id: string, x: number, z: number)
		buildings[#buildings + 1] = {
			bpId = id, zone = "Residential", level = 1, fill = 0,
			abandoned = true, residents = 0, position = Vector3.new(x, 0, z),
		}
	end

	-- Poles go in through restore() so a test can state its links exactly. `links` lists
	-- the ids each pole is wired to.
	local function poles(rows: { { x: number, z: number, links: { number }? } })
		local out = {}
		for i, r in rows do
			out[i] = { id = i, pivot = { r.x, 0, r.z, 0 }, links = r.links or {} }
		end
		PowerService.restore({ version = 2, nextId = #rows, poles = out })
	end

	local function poleCount(): number
		local f = Workspace:FindFirstChild("_City")
		f = f and f:FindFirstChild("PowerLines")
		if not f then return 0 end
		local n = 0
		for _, c in f:GetChildren() do if c:IsA("Model") then n += 1 end end
		return n
	end

	local function wireCount(): number
		local f = Workspace:FindFirstChild("_City")
		f = f and f:FindFirstChild("PowerLines")
		f = f and f:FindFirstChild("Wires")
		return if f then #f:GetChildren() else 0
	end

	local function lit(x: number, z: number): boolean
		return PowerService.isSuppliedAt(Vector3.new(x, 0, z))
	end

	local function reset()
		table.clear(turbines)
		table.clear(buildings)
		table.clear(powered)
		table.clear(abandoned)
		table.clear(streets)
		PowerService.markRoadsDirty()
		PowerService.clear()
	end

	describe("a city with no electricity at all", function()
		it("still asks for it, and reads dark until the player supplies it", function()
			reset()
			home("h1", 0, 0, 4)
			PowerService.rebuildNow()
			expect(PowerService.hasPower()).to.equal(false)
			expect(lit(0, 0)).to.equal(false)
			expect(lit(2000, 2000)).to.equal(false)
			-- The bill is real from the first house, not from the first turbine.
			expect(PowerService.getStats().consumption).to.equal(4 * 60)
			expect(PowerService.getStats().covered).to.equal(0)
		end)
	end)

	describe("a generator", function()
		it("only reaches its own yard, not the houses around it", function()
			reset()
			turbine(0, 0)
			-- The turbine's area is 20 studs. A house 200 studs away is nowhere near it,
			-- and with no line run to it there is nothing to carry power there.
			home("far", 200, 0, 4)
			PowerService.rebuildNow()
			expect(PowerService.hasPower()).to.equal(true)
			expect(lit(200, 0)).to.equal(false)
		end)

		it("hands power to a pole standing inside that yard", function()
			reset()
			turbine(0, 0)
			home("near", 40, 0, 4)          -- supply area reaches out to 26
			poles({ { x = 15, z = 0 } })    -- inside the turbine's 20, and inside the house's 26
			PowerService.rebuildNow()
			expect(lit(40, 0)).to.equal(true)
		end)
	end)

	describe("poles", function()
		it("do NOT connect just because they stand close together", function()
			reset()
			turbine(0, 0)
			-- Placed so the house's supply area holds pole B and NOT pole A: if the house
			-- reaches both, it joins them itself and the test proves nothing.
			home("h", 90, 0, 4)
			-- A is fed by the turbine, B feeds the house, and they are 20 studs apart --
			-- but no wire was ever drawn between them.
			poles({ { x = 15, z = 0 }, { x = 35, z = 0 } })
			PowerService.rebuildNow()
			expect(lit(90, 0)).to.equal(false)
			expect(wireCount()).to.equal(0)
		end)

		it("connect once a line is actually run between them", function()
			reset()
			turbine(0, 0)
			home("h", 90, 0, 4)
			poles({ { x = 15, z = 0, links = { 2 } }, { x = 35, z = 0 } })
			PowerService.rebuildNow()
			expect(lit(90, 0)).to.equal(true)
			expect(wireCount() > 0).to.equal(true)
		end)

		it("carry power across ground no building could bridge", function()
			reset()
			turbine(0, 0)
			home("h", 300, 0, 4)
			poles({
				{ x = 15,  z = 0, links = { 2 } },
				{ x = 95,  z = 0, links = { 3 } },
				{ x = 175, z = 0, links = { 4 } },
				{ x = 275, z = 0 },
			})
			PowerService.rebuildNow()
			expect(lit(300, 0)).to.equal(true)
		end)

		it("stay split when one link in the chain is missing", function()
			reset()
			turbine(0, 0)
			home("h", 300, 0, 4)
			poles({
				{ x = 15,  z = 0, links = { 2 } },
				{ x = 95,  z = 0 },              -- chain stops here
				{ x = 175, z = 0, links = { 4 } },
				{ x = 275, z = 0 },
			})
			PowerService.rebuildNow()
			expect(lit(300, 0)).to.equal(false)
			expect(PowerService.getStats().grids > 1).to.equal(true)
		end)
	end)

	describe("neighbouring buildings", function()
		it("share power when their supply areas overlap", function()
			reset()
			turbine(0, 0)
			poles({ { x = 15, z = 0 } })
			home("lit", 40, 0, 2)                     -- fed by the pole
			home("next", 40 + REACH * 2 - 4, 0, 2)    -- areas just overlap
			PowerService.rebuildNow()
			expect(lit(40, 0)).to.equal(true)
			expect(lit(40 + REACH * 2 - 4, 0)).to.equal(true)
		end)

		it("do not, once they are too far apart", function()
			reset()
			turbine(0, 0)
			poles({ { x = 15, z = 0 } })
			home("lit", 40, 0, 2)
			home("away", 40 + REACH * 2 + 20, 0, 2)
			PowerService.rebuildNow()
			expect(lit(40, 0)).to.equal(true)
			expect(lit(40 + REACH * 2 + 20, 0)).to.equal(false)
		end)
	end)

	describe("drawing a run", function()
		it("drops poles along it and wires them together", function()
			reset()
			turbine(0, 0)
			home("h", 300, 0, 4)
			local ok = PowerService.placeRun(Vector3.new(15, 0, 0), Vector3.new(280, 0, 0))
			expect(ok).to.equal(true)
			expect(poleCount() > 2).to.equal(true)
			PowerService.rebuildNow()
			expect(lit(300, 0)).to.equal(true)
		end)

		it("joins an existing pole instead of stacking a second one on it", function()
			reset()
			PowerService.placeRun(Vector3.new(0, 0, 0), Vector3.new(60, 0, 0))
			local first = poleCount()
			-- Start the next run on the end of the last one.
			PowerService.placeRun(Vector3.new(60, 0, 0), Vector3.new(120, 0, 0))
			expect(poleCount()).to.equal(first + 1)
		end)

		it("offers a snap target on a pole and nothing in open ground", function()
			reset()
			PowerService.placeRun(Vector3.new(0, 0, 0), Vector3.new(60, 0, 0))
			expect(PowerService.snapTarget(Vector3.new(62, 0, 3)) ~= nil).to.equal(true)
			expect(PowerService.snapTarget(Vector3.new(600, 0, 600))).to.equal(nil)
		end)
	end)

	describe("a grid that cannot meet its demand", function()
		it("bills 60 kW per inhabitant", function()
			reset()
			turbine(0, 0)
			poles({ { x = 15, z = 0 } })
			home("a", 40, 0, 4)
			home("b", -30, 0, 3)
			PowerService.rebuildNow()
			expect(PowerService.getStats().consumption).to.equal(7 * 60)
			expect(PowerService.getStats().production).to.equal(8000)
		end)

		it("darkens only what the supply did not stretch to, not the whole grid", function()
			reset()
			turbine(0, 0)                          -- 8000 kW
			poles({ { x = 15, z = 0 } })
			-- Two homes on ONE grid, 6000 kW each against 8000 available. The old model
			-- blacked the pair out; the supply covers one of them, so one of them stays lit.
			home("a", 40, 0, 100)
			home("b", 40 + REACH * 2 - 4, 0, 100)  -- areas overlap, so same grid
			PowerService.rebuildNow()
			local litHomes = 0
			if powered["a"] then litHomes += 1 end
			if powered["b"] then litHomes += 1 end
			expect(litHomes).to.equal(1)
			expect(PowerService.getStats().covered).to.equal(0.5)
		end)

		it("feeds the cheapest demand first, so a shortfall costs the fewest homes", function()
			reset()
			turbine(0, 0)                -- 8000 kW
			poles({ { x = 15, z = 0 } })
			home("big", 40, 0, 130)      -- 7800 kW on its own
			home("small", -30, 0, 4)     -- 240 kW
			PowerService.rebuildNow()
			expect(powered["small"]).to.equal(true)
			expect(powered["big"]).to.equal(false)
		end)

		it("goes dark when it has nowhere to buy from", function()
			reset()
			turbine(0, 0)
			poles({ { x = 15, z = 0 } })
			home("block", 40, 0, 200) -- 12000 kW against 8000
			PowerService.rebuildNow()
			expect(PowerService.getStats().consumption).to.equal(12000)
			expect(lit(40, 0)).to.equal(false)
			expect(PowerService.getStats().imported).to.equal(0)
		end)

		it("buys the shortfall through a pole at the map edge", function()
			reset()
			local edge = MAP_HALF - 96
			turbine(edge - 60, 0)
			home("block", edge - 30, 0, 200)
			-- One line from the turbine's yard out to the edge.
			poles({ { x = edge - 45, z = 0, links = { 2 } }, { x = edge, z = 0 } })
			PowerService.rebuildNow()
			expect(lit(edge - 30, 0)).to.equal(true)
			expect(PowerService.getStats().imported).to.equal(12000 - 8000)
			local cost, income = PowerService.getTradeMonthly()
			expect(cost > 0).to.equal(true)
			expect(income).to.equal(0)
		end)

		it("sells its surplus back through the same pole", function()
			reset()
			local edge = MAP_HALF - 96
			turbine(edge - 60, 0)
			home("small", edge - 30, 0, 4)
			poles({ { x = edge - 45, z = 0, links = { 2 } }, { x = edge, z = 0 } })
			PowerService.rebuildNow()
			expect(PowerService.getStats().exported).to.equal(8000 - 240)
		end)

		it("runs a city with no generator at all off the outside connection", function()
			reset()
			local edge = MAP_HALF - 96
			home("h", edge - 30, 0, 4)
			poles({ { x = edge - 45, z = 0, links = { 2 } }, { x = edge, z = 0 } })
			PowerService.rebuildNow()
			expect(PowerService.getStats().imported).to.equal(240)
			expect(PowerService.getStats().exported).to.equal(0)
			expect(powered["h"]).to.equal(true)
		end)

		it("does not trade through a pole that is inland", function()
			reset()
			turbine(0, 0)
			home("block", 40, 0, 200)
			poles({ { x = 15, z = 0 } })
			PowerService.rebuildNow()
			expect(PowerService.getStats().imported).to.equal(0)
			expect(lit(40, 0)).to.equal(false)
		end)
	end)

	describe("the advanced turbine", function()
		it("makes more than the standard one", function()
			reset()
			turbine(0, 0, "AdvancedWindTurbine")
			poles({ { x = 20, z = 0 } })
			PowerService.rebuildNow()
			expect(PowerService.getStats().production).to.equal(20000)
		end)
	end)

	describe("hooking a line onto a generator", function()
		it("pulls the end of the drag into the turbine's yard", function()
			reset()
			turbine(0, 0)
			local yard = (ServiceTypes.get("WindTurbine") :: any).coverageRadius
			-- Aimed well outside the yard, but a yard is ~20 studs across: without this the
			-- player has to drop a pole almost exactly on the tower.
			local snap = PowerService.snapTarget(Vector3.new(yard + 15, 0, 0))
			expect(snap ~= nil).to.equal(true)
			expect(snap.Magnitude < yard).to.equal(true)
		end)

		it("offers nothing out in open ground", function()
			reset()
			turbine(0, 0)
			expect(PowerService.snapTarget(Vector3.new(500, 0, 500))).to.equal(nil)
		end)

		it("means a run drawn at a turbine actually reaches it", function()
			reset()
			turbine(0, 0)
			home("h", 200, 0, 4)
			-- Aimed 30 studs short of the tower -- outside the yard.
			PowerService.placeRun(Vector3.new(30, 0, 0), Vector3.new(175, 0, 0))
			PowerService.rebuildNow()
			expect(lit(200, 0)).to.equal(true)
		end)
	end)

	describe("a building off the grid", function()
		it("is marked, and cleared again once it is fed", function()
			reset()
			turbine(0, 0)
			home("dark", 400, 0, 4)
			PowerService.rebuildNow()
			expect(powered["dark"]).to.equal(false)

			-- Chain out from the turbine's yard, ending inside the house's supply area
			-- (26 studs) -- a pole 65 studs short would leave it dark, correctly.
			poles({ { x = 15, z = 0, links = { 2 } }, { x = 95, z = 0, links = { 3 } },
				{ x = 175, z = 0, links = { 4 } }, { x = 255, z = 0, links = { 5 } },
				{ x = 335, z = 0, links = { 6 } }, { x = 390, z = 0 } })
			PowerService.rebuildNow()
			expect(powered["dark"]).to.equal(true)
		end)

		it("is dark from the day it is built, before a single pole is laid", function()
			reset()
			home("h", 0, 0, 4)
			PowerService.rebuildNow()
			expect(powered["h"]).to.equal(false)
		end)

		it("is never given up on wholesale -- its families move out one at a time instead", function()
			reset()
			turbine(0, 0)
			home("dark", 400, 0, 4)
			for _ = 1, 130 do PowerService.rebuildNow() end
			expect(powered["dark"]).to.equal(false)
			expect(abandoned["dark"]).to.equal(nil)
		end)

		it("does not relight a derelict on a grid with no generation in it", function()
			reset()
			ruin("ruin", 0, 0)
			poles({ { x = 15, z = 0 } }) -- wired, but nothing feeds it
			PowerService.rebuildNow()
			-- A ruin draws nothing, so it fits any grid at all. Without the spare-capacity
			-- test it would read as powered here and be rebuilt for free.
			expect(powered["ruin"]).to.equal(false)
		end)

		it("relights one once the grid has room to run a house there again", function()
			reset()
			turbine(0, 0)
			ruin("ruin", 40, 0)
			poles({ { x = 15, z = 0 } })
			PowerService.rebuildNow()
			expect(powered["ruin"]).to.equal(true)
		end)

	end)

	describe("roads", function()
		it("carry power: a turbine beside a street lights a house down the far end of it", function()
			reset()
			street(0, 400, 10, 1, 2)       -- runs through the turbine's 20-stud yard
			turbine(0, 0)
			home("far", 400, 40, 4)        -- nowhere near the turbine, 30 studs off the street
			PowerService.rebuildNow()
			expect(powered["far"]).to.equal(true)
			expect(wireCount()).to.equal(0) -- not a pole in sight
		end)

		it("join at a junction, and only there", function()
			reset()
			turbine(0, 0)
			street(0, 200, 10, 1, 2)
			street(200, 400, 10, 2, 3)     -- shares node 2: one conductor
			street(500, 700, 10, 4, 5)     -- its own nodes: a separate street
			home("joined", 400, 40, 4)
			home("apart", 700, 40, 4)
			PowerService.rebuildNow()
			expect(powered["joined"]).to.equal(true)
			expect(powered["apart"]).to.equal(false)
		end)

		it("take a drawn line in from a pole standing beside them", function()
			reset()
			turbine(0, 0)
			street(300, 600, 0, 1, 2)
			home("h", 600, 40, 4)
			-- A line from the turbine's yard to the kerb of a street it does not touch.
			poles({ { x = 15, z = 0, links = { 2 } }, { x = 95, z = 0, links = { 3 } },
				{ x = 175, z = 0, links = { 4 } }, { x = 280, z = 0 } })
			PowerService.rebuildNow()
			expect(powered["h"]).to.equal(true)
		end)
	end)

	describe("a water pump", function()
		it("draws power like a house, and reads unpowered until it gets some", function()
			reset()
			local id = pump(400, 0)
			PowerService.rebuildNow()
			expect(PowerService.isServicePowered(id)).to.equal(false)
			street(0, 400, 10, 1, 2)
			turbine(0, 0)
			PowerService.rebuildNow()
			expect(PowerService.isServicePowered(id)).to.equal(true)
			expect(PowerService.getStats().consumption).to.equal((ServiceTypes.get("WaterTower") :: any).powerUse)
		end)
	end)

	describe("batteries", function()
		local Lighting = game:GetService("Lighting")
		it("charge from a surplus and carry the grid through a shortfall", function()
			reset()
			local saved = Lighting.ClockTime
			street(0, 400, 10, 1, 2)
			turbine(0, 0)                                   -- 8000 kW
			turbines[#turbines + 1] = {
				id = 50, key = "BatteryStorage", kind = "Power", cf = CFrame.new(200, 0, 0),
				radius = 24, model = liveModel,
			}
			home("h", 300, 40, 50)                          -- 3000 kW
			Lighting.ClockTime = 10; PowerService.rebuildNow()
			Lighting.ClockTime = 11; PowerService.rebuildNow() -- an hour of surplus
			expect(PowerService.getStats().stored > 0).to.equal(true)
			-- The turbine goes: the battery alone keeps the house lit.
			table.remove(turbines, 1)
			Lighting.ClockTime = 11.1; PowerService.rebuildNow()
			expect(powered["h"]).to.equal(true)
			Lighting.ClockTime = saved
		end)
	end)

	describe("generator spacing", function()
		it("keeps another generator off its YARD -- blue on blue", function()
			reset()
			turbine(0, 0) -- yard 20, so a pair needs 40 between hubs
			expect(PowerService.spacingBlockedAt("WindTurbine", Vector3.new(30, 0, 0))).to.equal(true)
			expect(PowerService.spacingBlockedAt("WindTurbine", Vector3.new(45, 0, 0))).to.equal(false)
		end)

		it("adds the two yards and ignores the wider amber advice ring", function()
			reset()
			turbine(0, 0) -- yard 20, amber ring 64
			-- The advanced tower's yard is 28, so the pair need 48 studs of daylight. 80 is
			-- clear even though the amber ring drawn around it is 96 -- amber is advice
			-- about blade clearance, not a veto, and refusing on it turned away towers that
			-- plainly fitted.
			expect(PowerService.spacingBlockedAt("AdvancedWindTurbine", Vector3.new(40, 0, 0))).to.equal(true)
			expect(PowerService.spacingBlockedAt("AdvancedWindTurbine", Vector3.new(80, 0, 0))).to.equal(false)
		end)

		it("lets a generator be moved without tripping on itself", function()
			reset()
			turbine(0, 0)
			expect(PowerService.spacingBlockedAt("WindTurbine", Vector3.new(10, 0, 0), 1)).to.equal(false)
		end)

		it("does not fence off a pole, which has no ring", function()
			reset()
			expect(PowerService.spacingBlockedAt("PowerPole", Vector3.new(0, 0, 0))).to.equal(false)
		end)
	end)

	describe("what a workplace draws", function()
		local function works(id: string, x: number, zone: string, level: number, fill: number)
			buildings[#buildings + 1] = {
				bpId = id, zone = zone, level = level, fill = fill,
				abandoned = false, residents = 0, position = Vector3.new(x, 0, 0),
			}
		end

		it("bills a factory by the head, not once for the building", function()
			reset()
			turbine(0, 0)
			poles({ { x = 15, z = 0 } })
			works("plant", 40, "Industrial", 1, 1) -- 5 slots, all filled, 150 kW each
			PowerService.rebuildNow()
			expect(PowerService.getStats().consumption).to.equal(5 * 150)
		end)

		it("still bills an empty unit at a quarter rate -- the machines idle", function()
			reset()
			turbine(0, 0)
			poles({ { x = 15, z = 0 } })
			works("shut", 40, "Industrial", 1, 0)
			PowerService.rebuildNow()
			expect(PowerService.getStats().consumption).to.equal(5 * 150 * 0.25)
		end)

		it("costs far more for industry than for the shops beside it", function()
			reset()
			turbine(0, 0)
			poles({ { x = 15, z = 0 } })
			works("shop", 40, "Commercial", 1, 1) -- 3 slots at 50
			PowerService.rebuildNow()
			expect(PowerService.getStats().consumption * 4 < 5 * 150).to.equal(true)
		end)
	end)

	describe("a pole with no generator behind it", function()
		it("puts electricity in play, so the houses read as dark", function()
			reset()
			home("h", 40, 0, 4)
			poles({ { x = 15, z = 0 } })
			PowerService.rebuildNow()
			expect(PowerService.hasPower()).to.equal(true)
			expect(powered["h"]).to.equal(false)
		end)
	end)

	describe("where a pole may stand", function()
		it("refuses a road under the run's end, and slides clear of one it crosses", function()
			reset()
			local city = Workspace:FindFirstChild("_City") :: Folder
			local roads = Instance.new("Folder")
			roads.Name = "Roads"
			roads.Parent = city
			local slab = Instance.new("Part")
			slab.Anchored = true
			slab.CanCollide = false
			-- Tall on purpose: the pole is re-grounded onto the terrain before it is tested,
			-- and a 1-stud slab at Y=0 sat below the ground the pole ends up standing on. The
			-- height is not what is under test -- "there is road here" is.
			slab.Size = Vector3.new(16, 60, 200)
			slab.CFrame = CFrame.new(300, 0, 0)
			slab.Parent = roads

			local ok, reason = PowerService.placeRun(Vector3.new(200, 0, 0), Vector3.new(300, 0, 0))
			expect(ok).to.equal(false)
			expect(string.find(reason or "", "road") ~= nil).to.equal(true)

			-- The same road CROSSED mid-run is fine: the wire goes over it, and the pole
			-- that would have landed on the tarmac slides along the line until it is clear.
			reset()
			expect(PowerService.placeRun(Vector3.new(200, 0, 0), Vector3.new(400, 0, 0))).to.equal(true)
			for _, m in Workspace._City.PowerLines:GetChildren() do
				if m:IsA("Model") then
					expect(math.abs(m:GetPivot().Position.X - 300) > 8).to.equal(true)
				end
			end
			roads:Destroy()
		end)

		it("refuses a run whose end is off the map, and leaves no pole behind", function()
			reset()
			-- A clicked end that could not stand used to be skipped: the run reported success
			-- with nothing built there, and the client chained its next run from thin air.
			local ok, reason = PowerService.placeRun(Vector3.new(MAP_HALF - 100, 0, 0), Vector3.new(MAP_HALF + 50, 0, 0))
			expect(ok).to.equal(false)
			expect(string.find(reason or "", "edge") ~= nil).to.equal(true)
			expect(poleCount()).to.equal(0)
		end)
	end)

	describe("two lines meeting at one pole", function()
		local function highestWire(): number
			local top = -math.huge
			for _, p in Workspace._City.PowerLines.Wires:GetChildren() do
				top = math.max(top, (p :: BasePart).Position.Y)
			end
			return top
		end

		it("hang off different crossarms, while one straight run keeps a single arm", function()
			reset()
			poles({ { x = -40, z = 0, links = { 2 } }, { x = 0, z = 0, links = { 3 } }, { x = 40, z = 0 } })
			local straight = highestWire()

			reset()
			poles({
				{ x = 0, z = 0, links = { 2, 3, 4, 5 } },
				{ x = -40, z = 0 }, { x = 40, z = 0 },
				{ x = 0, z = -40 }, { x = 0, z = 40 },
			})
			-- East-west keeps the lower arm it started on; north-south is lifted onto the
			-- upper one, so the crossroads reaches visibly higher than the straight run.
			expect(highestWire() > straight + 1).to.equal(true)
		end)
	end)

	-- Solar is the one generator whose output moves. Its spec rates the NOON PEAK, and
	-- PowerService scales that by the sun's altitude off Lighting.ClockTime -- the same clock
	-- TimeService drives, so what the meter says matches what the sky looks like.
	describe("a solar farm", function()
		local Lighting = game:GetService("Lighting")

		local function atHour(h: number)
			Lighting.ClockTime = h
			PowerService.rebuildNow()
			return math.floor(PowerService.getStats().production + 0.5)
		end

		it("makes its full rating at noon, half of it at mid-morning, and nothing at night", function()
			reset()
			local saved = Lighting.ClockTime
			turbine(0, 0, "SolarFarm")
			local peak = (ServiceTypes.get("SolarFarm") :: any).powerOutput
			expect(atHour(12)).to.equal(peak)
			expect(atHour(8)).to.equal(peak // 2) -- sun 30 degrees up: sin(30) = 0.5
			expect(atHour(18)).to.equal(0)        -- dusk, to the minute
			expect(atHour(2)).to.equal(0)
			Lighting.ClockTime = saved
		end)

		it("lights a house at noon and lets it go dark at midnight", function()
			reset()
			local saved = Lighting.ClockTime
			turbine(0, 0, "SolarFarm")
			home("h1", 0, 40, 2) -- inside the farm's yard reach, so no pole is needed
			atHour(12)
			expect(powered.h1).to.equal(true)
			atHour(0)
			expect(powered.h1).to.equal(false)
			Lighting.ClockTime = saved
		end)

		it("keeps its yard on the grid after dark, so the lines drawn to it stay one grid", function()
			reset()
			local saved = Lighting.ClockTime
			turbine(0, 0, "SolarFarm")
			-- Two runs leaving the same farm, joined only through its yard.
			poles({ { x = -30, z = 0, links = { 2 } }, { x = -90, z = 0 }, { x = 30, z = 0, links = { 4 } }, { x = 90, z = 0 } })
			atHour(12)
			expect(PowerService.getStats().grids).to.equal(1)
			atHour(0)
			expect(PowerService.getStats().grids).to.equal(1)
			Lighting.ClockTime = saved
		end)
	end)

	reset()
	liveModel:Destroy()
end
