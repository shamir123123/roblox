--!strict
-- Terrain saves must restore bit for bit: every height, material and flag. The encoder
-- predicts each cell from its neighbours, so one wrong byte would smear across the chunk.
return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local TerrainPersistence = require(script.Parent)
	local Heightmap = require(ReplicatedStorage.Terrain.Heightmap)
	local TerrainGenerator = require(ReplicatedStorage.Terrain.TerrainGenerator)
	local CC = require(ReplicatedStorage.Terrain.TerrainConstants).CHUNK_CORNER_COUNT

	local params: any = { seed = 5.5, heightRange = 0.075, oceanLevel = 0, baseHeight = 0, ruggedness = 0,
		shape = "continent", persistence = 0.5, lacunarity = 2 }

	local function baseMap(keys: { number }): any
		local hm = Heightmap.new()
		for _, key in keys do
			local cx, cz = Heightmap.decodeKey(key)
			TerrainGenerator.generateChunk(hm, cx, cz, params)
		end
		return hm
	end

	it("restores sculpted, graded and wrap-around chunks exactly, and skips untouched ones", function()
		local rough, pad, untouched = Heightmap.chunkKey(0, 0), Heightmap.chunkKey(1, 0), Heightmap.chunkKey(0, 1)
		local live = baseMap({ rough, pad, untouched })
		local rng = Random.new(7)
		local c = live:getChunk(Heightmap.decodeKey(rough))
		for i = 0, CC - 1 do
			-- The whole u16 range, extremes included: exercises the mod-65536 wrap both ways.
			buffer.writeu16(c.heights, i * 2, if i % 7 == 0 then 65535 elseif i % 11 == 0 then 0 else rng:NextInteger(0, 65535))
			buffer.writeu8(c.materials, i, rng:NextInteger(0, 255))
			buffer.writeu8(c.flags, i, rng:NextInteger(0, 255))
		end
		local p = live:getChunk(Heightmap.decodeKey(pad))
		for i = 1000, 3000 do buffer.writeu16(p.heights, i * 2, 4321) end

		local rec = TerrainPersistence.serialize(live, params, { [rough] = true, [pad] = true, [untouched] = true }, nil)
		expect(#rec.keys).to.equal(2)

		local restored = baseMap({ rough, pad, untouched })
		expect(TerrainPersistence.deserialize(restored, rec, function() end)).to.equal(true)
		for _, key in { rough, pad, untouched } do
			local a, b = live:getChunk(Heightmap.decodeKey(key)), restored:getChunk(Heightmap.decodeKey(key))
			for _, layer in { "heights", "materials", "flags" } do
				expect(buffer.tostring(a[layer]) == buffer.tostring(b[layer])).to.equal(true)
			end
		end
	end)

	it("refuses a truncated record whole instead of half-applying it", function()
		local key = Heightmap.chunkKey(0, 0)
		local live = baseMap({ key })
		buffer.writeu16(live:getChunk(Heightmap.decodeKey(key)).heights, 0, 9999)
		local rec = TerrainPersistence.serialize(live, params, { [key] = true }, nil)
		rec.hh = buffer.create(10)
		local target = baseMap({ key })
		local before = buffer.tostring(target:getChunk(Heightmap.decodeKey(key)).heights)
		expect(TerrainPersistence.deserialize(target, rec, function() end)).to.equal(false)
		expect(buffer.tostring(target:getChunk(Heightmap.decodeKey(key)).heights) == before).to.equal(true)
	end)

	it("round-trips the dry-pit keys as a set", function()
		local keys = { 4294967295, 0, 2520008, 2520007, 1350862 }
		local back = TerrainPersistence.unpackDryKeys(TerrainPersistence.packDryKeys(keys))
		table.sort(keys)
		table.sort(back)
		expect(table.concat(back, ",")).to.equal(table.concat(keys, ","))
	end)
end
