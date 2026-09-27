--!strict
return function()
	local IntersectionRenderer = require(script.Parent)
	local RoadMeshBuilder = require(script.Parent.Parent.RoadMeshBuilder)

	-- Corner kerbs are the only thing in a box junction built from surface strips, and a
	-- run emits exactly three (top + two walls), so counting the calls counts the corners.
	local function cornerKerbs(bare: { [string]: boolean }): number
		local dirs = {
			N = Vector3.new(0, 0, -1), E = Vector3.new(1, 0, 0),
			S = Vector3.new(0, 0, 1),  W = Vector3.new(-1, 0, 0),
		}
		local arms, any = {}, false
		for key, dir in dirs do
			local sw = not bare[key]
			any = any or sw
			table.insert(arms, { dir = dir, width = 24, swLeft = sw, swRight = sw })
		end

		local strips = 0
		local real = RoadMeshBuilder.addSurfaceStrip;
		(RoadMeshBuilder :: any).addSurfaceStrip = function(...)
			strips += 1
			return real(...)
		end
		local scratch = Instance.new("Folder")
		local ok, err = pcall(function()
			IntersectionRenderer.build(Vector3.new(0, 10, 0), arms, scratch, {
				surfaceColor = Color3.new(0.2, 0.2, 0.2),
				shape = "box",
				anchored = true,
				canCollide = false,
				sidewalk = any,
			})
		end);
		(RoadMeshBuilder :: any).addSurfaceStrip = real
		scratch:Destroy()
		if not ok then error(err) end
		return strips // 3
	end

	describe("junction sidewalk", function()
		it("kerbs every corner when all four arms carry a sidewalk", function()
			expect(cornerKerbs({})).to.equal(4)
		end)

		it("keeps all four corners when ONE arm has no sidewalk", function()
			-- The bare arm's own two corners run round and stop flush at its mouth; the
			-- corners it isn't part of are untouched. Whole-node gating stripped all four.
			expect(cornerKerbs({ N = true })).to.equal(4)
		end)

		it("drops only the corner both of whose sides are bare", function()
			expect(cornerKerbs({ N = true, E = true })).to.equal(3)
		end)

		it("kerbs nothing when no arm carries a sidewalk", function()
			expect(cornerKerbs({ N = true, E = true, S = true, W = true })).to.equal(0)
		end)
	end)
end
