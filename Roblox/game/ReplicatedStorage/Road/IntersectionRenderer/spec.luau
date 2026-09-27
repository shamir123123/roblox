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

	-- Furthest a corner kerb's own path strays off the junction's paved rim. Both are built
	-- from the SAME fillet, so this is 0 -- and it is the gap between the road and its
	-- sidewalk when it is not: the rim used to be a separate fillet at the pavement edge,
	-- and the two parted mid-corner by half a sidewalk over sin(half-angle).
	local function kerbOffRim(width: number, dirs: { Vector3 }): number
		local arms = {}
		for _, dir in dirs do
			table.insert(arms, { dir = dir, width = width, swLeft = true, swRight = true })
		end

		local rim: { Vector3 } = {}
		local kerbTops: { { Vector3 } } = {}
		local realFan = RoadMeshBuilder.addFan
		local realStrip = RoadMeshBuilder.addSurfaceStrip;
		(RoadMeshBuilder :: any).addFan = function(self, center, loop, ...)
			rim = loop
			return realFan(self, center, loop, ...)
		end

		-- curbRun emits top, then two walls: every third strip is a kerb top, whose two
		-- edges straddle the path curbRun was handed.
		local strips = 0;
		(RoadMeshBuilder :: any).addSurfaceStrip = function(self, a, b, ...)
			strips += 1
			if strips % 3 == 1 then
				local mid = table.create(#a)
				for k = 1, #a do mid[k] = (a[k] + b[k]) * 0.5 end
				table.insert(kerbTops, mid)
			end
			return realStrip(self, a, b, ...)
		end

		local scratch = Instance.new("Folder")
		local ok, err = pcall(function()
			IntersectionRenderer.build(Vector3.new(0, 10, 0), arms, scratch, {
				surfaceColor = Color3.new(0.2, 0.2, 0.2),
				shape = "box",
				anchored = true,
				canCollide = false,
				sidewalk = true,
			})
		end);
		(RoadMeshBuilder :: any).addFan = realFan;
		(RoadMeshBuilder :: any).addSurfaceStrip = realStrip
		scratch:Destroy()
		if not ok then error(err) end
		if #rim < 3 then error("no junction fan was built") end
		if #kerbTops == 0 then error("no corner kerbs were built") end

		local worst = 0
		for _, pts in kerbTops do
			-- Skip the two mouth ends: the rim drops each corner's endpoints in favour of the
			-- arm's own mouth chord, so only the interior is a shared path.
			for k = 2, #pts - 1 do
				local p = Vector3.new(pts[k].X, 0, pts[k].Z)
				local best = math.huge
				for i = 1, #rim do
					local a = Vector3.new(rim[i].X, 0, rim[i].Z)
					local bRim = rim[(i % #rim) + 1]
					local b = Vector3.new(bRim.X, 0, bRim.Z)
					local ab = b - a
					local d2 = ab:Dot(ab)
					local t = if d2 > 1e-9 then math.clamp((p - a):Dot(ab) / d2, 0, 1) else 0
					best = math.min(best, (p - (a + ab * t)).Magnitude)
				end
				worst = math.max(worst, best)
			end
		end
		return worst
	end

	describe("junction paving reaches the kerb", function()
		local N, E, S, W = Vector3.new(0, 0, -1), Vector3.new(1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(-1, 0, 0)

		it("paves right out to the kerb on a square crossroads", function()
			expect(kerbOffRim(24, { N, E, S, W })).to.be.near(0, 0.02)
		end)

		it("paves right out to the kerb on an acute fork, where the gap was widest", function()
			-- A 35-degree corner: the old pavement-edge rim fell studs short of the kerb here.
			local acute = Vector3.new(math.cos(math.rad(35)), 0, math.sin(math.rad(35)))
			expect(kerbOffRim(24, { E, acute, W })).to.be.near(0, 0.02)
		end)
	end)

	-- The corner fans and the arm mouths are built off these two per-side distances, so they
	-- have to disagree exactly where the junction is skewed and agree where it is not. (The
	-- zebra is NOT: it seats on the square mouth -- see RoadSceneRenderer.crosswalkSeat.)
	describe("per-arm corner distances", function()
		local N, E, S, W = Vector3.new(0, 0, -1), Vector3.new(1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(-1, 0, 0)
		local function armsOf(dirs: { Vector3 })
			local arms = {}
			for _, dir in dirs do table.insert(arms, { dir = dir, width = 24, swLeft = true, swRight = true }) end
			return arms
		end

		it("gives both sides of an arm the same reach on a square crossroads", function()
			local c = IntersectionRenderer.armCornerDistances(Vector3.zero, armsOf({ N, E, S, W }))
			for i = 1, 4 do
				expect(c[i].ccw - c[i].cw).to.be.near(0, 1e-3)
			end
		end)

		it("splits them on a skewed junction, the acute corner reaching furthest", function()
			local skew = Vector3.new(math.cos(math.rad(55)), 0, -math.sin(math.rad(55)))
			local arms = armsOf({ E, W, skew })
			local c = IntersectionRenderer.armCornerDistances(Vector3.zero, arms)
			-- E's two corners: one against the 55-degree arm, one against nothing nearer than W.
			expect(math.abs(c[1].ccw - c[1].cw) > 2).to.equal(true)
			-- ...and the mouth is still the wider of the two, unchanged for everything else.
			local d = IntersectionRenderer.armBoundaryDistances(Vector3.zero, arms)
			for i = 1, 3 do
				expect(d[i]).to.be.near(math.max(c[i].cw, c[i].ccw), 1e-6)
			end
		end)
	end)

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
