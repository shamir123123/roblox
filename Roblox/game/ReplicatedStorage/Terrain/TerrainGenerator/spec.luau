--!strict
-- The base map is bare ground. The server reuses ONE heightmap for every city it loads,
-- so a regenerate that leaves the previous city's flags behind makes the next road grade
-- skip its own bed (a locked corner reads as owned by something else) and the ground
-- stands up through the road on the second load in a server.
return function()
	local TerrainGenerator = require(script.Parent)
	local Heightmap = require(script.Parent.Parent.Heightmap)
	local Constants = require(script.Parent.Parent.TerrainConstants)

	local PARAMS = { seed = 5.5, heightRange = 1 }
	local GX = 3 * Constants.CHUNK_TILES + 5
	local GZ = 3 * Constants.CHUNK_TILES + 5

	local function usedChunk(): Heightmap.Heightmap
		local hm = Heightmap.new()
		TerrainGenerator.generateChunk(hm, 3, 3, PARAMS)
		hm:setMaterial(GX, GZ, Constants.Material.LEAFY)
		hm:setFlags(GX, GZ, Constants.Flag.LOCKED)
		return hm
	end

	describe("regenerating a chunk that already held a city", function()
		it("clears the old flags", function()
			local hm = usedChunk()
			TerrainGenerator.generateChunk(hm, 3, 3, PARAMS)
			expect(hm:getFlags(GX, GZ)).to.equal(0)
		end)

		it("clears the old materials", function()
			local hm = usedChunk()
			TerrainGenerator.generateChunk(hm, 3, 3, PARAMS)
			expect(hm:getMaterial(GX, GZ)).to.equal(0)
		end)

		it("reproduces the same heights", function()
			local hm = usedChunk()
			local before = hm:getCorner(GX, GZ)
			TerrainGenerator.generateChunk(hm, 3, 3, PARAMS)
			expect(hm:getCorner(GX, GZ)).to.equal(before)
		end)
	end)
end
