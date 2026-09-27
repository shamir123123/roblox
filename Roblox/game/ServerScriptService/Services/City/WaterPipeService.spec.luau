--!strict
-- The pipe contract, sharpest rule first: the PIPE is the delivery. A tower with nothing
-- plugged into it serves nobody, and a main that taps no source is stranded however long
-- it is. Plus end-to-end joining, per-span cost, and a network that survives a save.
return function()
	local ServiceTypes = require(game:GetService("ReplicatedStorage").City.ServiceTypes)
	local WaterPipeService = require(script.Parent.WaterPipeService)

	local REACH = ServiceTypes.PipeReach
	local SPAN = ServiceTypes.PipeSpan
	local PIPE_COST = (ServiceTypes.get("WaterPipe") :: any).cost

	local utilities: { any } = {}
	local wallet = math.huge
	local spent = 0

	-- Init only stores the net and wires Bind's handlers, so a stub with the right shape is
	-- enough: nothing here goes near a remote.
	WaterPipeService.Init(
		{ RequestPlaceService = {}, RequestRemoveService = {}, Notify = {} },
		{ list = function() return utilities end },
		{ trySpend = function(n: number): boolean
			if n > wallet then return false end
			wallet -= n; spent += n; return true
		end }
	)

	local function tower(key: string, x: number, z: number)
		utilities[#utilities + 1] = { key = key, cf = CFrame.new(x, 0, z), model = { Parent = true } }
	end
	-- A straight run is a curve whose handles sit on the line, which is exactly what the
	-- tool sends for Straight mode.
	local function lay(key: string, ax: number, az: number, bx: number, bz: number): (boolean, string?)
		local a, b = Vector3.new(ax, 0, az), Vector3.new(bx, 0, bz)
		return WaterPipeService.placeRun(key, { a, a:Lerp(b, 1 / 3), a:Lerp(b, 2 / 3), b })
	end
	local function servedAt(x: number, z: number, kind: string): boolean
		return WaterPipeService.servedAt(Vector3.new(x, 0, z), kind)
	end
	local function reset()
		table.clear(utilities)
		WaterPipeService.clear()
		wallet = math.huge
		spent = 0
	end

	describe("WaterPipeService", function()
		it("serves nobody from a tower with no main plugged into it", function()
			reset()
			tower("WaterTower", 0, 0)
			WaterPipeService.rebuildNow()
			expect(servedAt(20, 0, "Water")).to.equal(false)
		end)

		it("serves the ground either side of a main that taps a tower, and no further", function()
			reset()
			tower("WaterTower", 0, 0)
			expect(lay("WaterPipe", 30, 0, 300, 0)).to.equal(true)
			expect(servedAt(200, 0, "Water")).to.equal(true)
			expect(servedAt(200, REACH * 0.6, "Water")).to.equal(true)
			expect(servedAt(200, REACH * 3, "Water")).to.equal(false)
			expect(servedAt(900, 0, "Water")).to.equal(false)
		end)

		it("serves nobody from a main that taps nothing, however long it is", function()
			reset()
			tower("WaterTower", 0, 0)
			expect(lay("WaterPipe", 2000, 2000, 2400, 2000)).to.equal(true)
			expect(servedAt(2200, 2000, "Water")).to.equal(false)
		end)

		it("feeds a second run through the first when their ends meet", function()
			reset()
			tower("WaterTower", 0, 0)
			lay("WaterPipe", 30, 0, 300, 0)
			lay("WaterPipe", 300, 0, 700, 0)
			expect(servedAt(650, 0, "Water")).to.equal(true)
		end)

		it("tees a branch off the MIDDLE of a main, not only off its ends", function()
			reset()
			tower("WaterTower", 0, 0)
			lay("WaterPipe", 30, 0, 600, 0)
			-- Starts on the main halfway along it, nowhere near either end.
			lay("WaterPipe", 300, 0, 300, 400)
			expect(servedAt(300, 380, "Water")).to.equal(true)
		end)

		it("leaves a run that stops short of the first one dry", function()
			reset()
			tower("WaterTower", 0, 0)
			lay("WaterPipe", 30, 0, 300, 0)
			lay("WaterPipe", 500, 0, 700, 0) -- 200 studs shy: a separate network
			expect(servedAt(650, 0, "Water")).to.equal(false)
		end)

		it("carries only what the card lays", function()
			reset()
			tower("WaterTower", 0, 0)
			lay("SewagePipe", 30, 0, 300, 0)
			expect(servedAt(200, 0, "Water")).to.equal(false)
			lay("WaterPipe", 30, 20, 300, 20)
			expect(servedAt(200, 20, "Water")).to.equal(true)
		end)

		it("charges by the span and digs nothing it cannot pay for", function()
			reset()
			wallet = PIPE_COST * 2
			expect(lay("WaterPipe", 0, 0, SPAN * 2, 0)).to.equal(true)
			expect(spent).to.equal(PIPE_COST * 2)
			local ok, reason = lay("WaterPipe", 0, 100, SPAN * 2, 100)
			expect(ok).to.equal(false)
			expect(reason).to.equal("can't afford")
			expect(#WaterPipeService.serialize().segments).to.equal(1)
		end)

		it("comes back from a save still fed", function()
			reset()
			tower("WaterTower", 0, 0)
			lay("UtilityPipe", 30, 0, 300, 0)
			local blob = WaterPipeService.serialize()
			WaterPipeService.clear()
			expect(servedAt(200, 0, "Water")).to.equal(false)
			WaterPipeService.restore(blob)
			expect(servedAt(200, 0, "Water")).to.equal(true)
		end)
	end)

	reset()
end
