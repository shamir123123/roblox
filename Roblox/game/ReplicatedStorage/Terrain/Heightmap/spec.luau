--!strict
return function()
	local Heightmap = require(script.Parent)
	local Constants = require(script.Parent.Parent.TerrainConstants)

	local SEA_RAW = Constants.SEA_RAW
	local STEP = Constants.HEIGHT_STEP
	local CHUNK_CORNERS = Constants.CHUNK_CORNERS

	-- raw delta for a worldY rise of `studs`
	local function rise(studs: number): number
		return math.round(studs / STEP)
	end

	describe("corner storage", function()
		it("defaults unset corners to sea level", function()
			local hm = Heightmap.new()
			expect(hm:getCorner(10, 10)).to.equal(SEA_RAW)
			expect(Constants.rawToWorldY(hm:getCorner(10, 10))).to.equal(Constants.SEA_Y)
		end)

		it("round-trips a written corner", function()
			local hm = Heightmap.new()
			hm:setCorner(5, 7, SEA_RAW + rise(12))
			expect(hm:getCorner(5, 7)).to.equal(SEA_RAW + rise(12))
		end)

		it("clamps out-of-bounds corners instead of erroring", function()
			local hm = Heightmap.new()
			hm:setCorner(-50, -50, SEA_RAW + rise(4))
			-- clamps to corner (0,0)
			expect(hm:getCorner(0, 0)).to.equal(SEA_RAW + rise(4))
			expect(hm:getCorner(99999, 0)).to.equal(hm:getCorner(Constants.CORNERS_PER_AXIS - 1, 0))
		end)

		it("clamps written raw into uint16 range", function()
			local hm = Heightmap.new()
			hm:setCorner(1, 1, -100)
			expect(hm:getCorner(1, 1)).to.equal(0)
			hm:setCorner(2, 2, 1e9)
			expect(hm:getCorner(2, 2)).to.equal(Constants.RAW_MAX)
		end)
	end)

	describe("shared-edge write-through", function()
		it("writes a boundary corner into both neighbouring chunks", function()
			local hm = Heightmap.new()
			-- global corner X=64 is the shared edge between chunk 0 and chunk 1.
			local value = SEA_RAW + rise(20)
			hm:setCorner(64, 10, value)

			local c0 = hm:getChunk(0, 0)
			local c1 = hm:getChunk(1, 0)
			expect(c0).to.be.ok()
			expect(c1).to.be.ok()
			-- chunk0 holds it at local x=64; chunk1 holds it at local x=0.
			local idxC0 = 10 * CHUNK_CORNERS + 64
			local idxC1 = 10 * CHUNK_CORNERS + 0
			expect(buffer.readu16((c0 :: any).heights, idxC0 * 2)).to.equal(value)
			expect(buffer.readu16((c1 :: any).heights, idxC1 * 2)).to.equal(value)
		end)
	end)

	describe("slope", function()
		it("reports zero slope on flat ground", function()
			local hm = Heightmap.new()
			expect(hm:getTileSlope(3, 3)).to.equal(0)
		end)

		it("reports 45 degrees for a one-to-one X ramp", function()
			local hm = Heightmap.new()
			-- raise the +X corners of tile (0,0) by exactly SAMPLE_SPACING studs.
			hm:setCorner(1, 0, SEA_RAW + rise(Constants.SAMPLE_SPACING))
			hm:setCorner(1, 1, SEA_RAW + rise(Constants.SAMPLE_SPACING))
			expect(hm:getTileSlope(0, 0)).to.be.near(math.pi / 4, 1e-4)
		end)
	end)

	describe("getHeightAt", function()
		it("bilinearly interpolates between corners", function()
			local hm = Heightmap.new()
			hm:setCorner(1, 0, SEA_RAW + rise(4))
			hm:setCorner(1, 1, SEA_RAW + rise(4))
			-- halfway across tile (0,0) in X -> half the rise = 2 studs above sea.
			local midX = Constants.cornerToWorld(0.5)
			local z0 = Constants.cornerToWorld(0)
			expect(hm:getHeightAt(midX, z0)).to.be.near(2, 1e-4)
		end)
	end)

	describe("materials and flags", function()
		it("defaults material to AUTO and round-trips overrides", function()
			local hm = Heightmap.new()
			expect(hm:getMaterial(4, 4)).to.equal(Constants.Material.AUTO)
			hm:setMaterial(4, 4, Constants.Material.ROCK)
			expect(hm:getMaterial(4, 4)).to.equal(Constants.Material.ROCK)
		end)

		it("tracks locked flag", function()
			local hm = Heightmap.new()
			expect(hm:isLocked(8, 8)).to.equal(false)
			hm:setFlags(8, 8, Constants.Flag.LOCKED)
			expect(hm:isLocked(8, 8)).to.equal(true)
		end)
	end)

	describe("dirty tracking", function()
		it("marks edited chunks dirty and drains them once", function()
			local hm = Heightmap.new()
			expect(hm:hasDirty()).to.equal(false)
			hm:setCorner(5, 5, SEA_RAW + rise(1))
			expect(hm:hasDirty()).to.equal(true)
			local drained = hm:drainDirty()
			expect(#drained).to.equal(1)
			expect(hm:hasDirty()).to.equal(false)
			expect(#hm:drainDirty()).to.equal(0)
		end)

		it("marks both chunks dirty for a shared-edge write", function()
			local hm = Heightmap.new()
			hm:setCorner(64, 64, SEA_RAW + rise(1)) -- corner shared by 4 chunks
			expect(#hm:drainDirty()).to.equal(4)
		end)
	end)
end
