--!nonstrict
-- PropCatalog.spec -- every street prop, checked against the LOD ladder it will actually
-- ride rather than against how it looks in the viewport.
--
-- The interesting assertions are the two that are easy to get wrong and impossible to see:
--   * meshBacked must be FALSE. ModelBaker.bakeMesh refuses mesh-backed non-foliage models,
--     so a prop that drifts over half its volume into MeshParts silently loses BOTH mesh
--     rungs and becomes a flat quad at 1000 studs. Nothing about the prop looks wrong up
--     close when that happens.
--   * coarsen must at least halve keptParts, because that halving is exactly the test
--     LODProxyCache.bakeFor applies before it will spend a bake on the DISTANT rung. A prop
--     that fails it still renders -- it just quietly has one fewer rung than intended.
--
-- Runs in Edit mode: the whole bake path (CreateEditableMesh / collect / bakeMesh) works
-- from the command bar, so this needs no play session.
--   print(require(game.ServerScriptService.Tests.SpecRunner)())

return function()
	local RS = game:GetService("ReplicatedStorage")
	local ModelBaker = require(RS.Shared.ModelBaker)
	local PropCatalog = require(script.Parent)
	local props = script.Parent.Parent

	-- ModelBaker.MIN_FEATURE_STUDS and AssetLODView.DETAIL_STUDS, mirrored. Both are private
	-- to their modules; if either moves, this spec is where the mismatch should surface.
	local MIN_FEATURE = 0.6
	local STUD_MM = 500 -- WORLD_SCALE 0.5 => 1 m = 2 studs

	local function template(key)
		local m = props:FindFirstChild(key)
		if not (m and m:IsA("Model")) then
			error(("no template Model named %q in ReplicatedStorage.Props"):format(key))
		end
		return m
	end

	describe("catalog data", function()
		it("every ordered key resolves to an entry that agrees with its own key", function()
			for _, key in PropCatalog.order do
				local e = PropCatalog.get(key)
				if not e then error(("order lists %q but byKey has no entry"):format(key)) end
				expect(e.key).to.equal(key)
				expect(e.name).to.be.a("string")
				if e.minScale > e.maxScale then
					error(("%s: minScale %.2f above maxScale %.2f"):format(key, e.minScale, e.maxScale))
				end
			end
		end)

		it("byKey holds nothing that order forgot to list", function()
			local listed = {}
			for _, key in PropCatalog.order do listed[key] = true end
			for key in PropCatalog.byKey do
				if not listed[key] then error(("byKey has %q but order does not list it"):format(key)) end
			end
		end)

		it("tables are frozen per project rule 12", function()
			expect(table.isfrozen(PropCatalog.byKey)).to.equal(true)
			expect(table.isfrozen(PropCatalog.stream)).to.equal(true)
		end)
	end)

	describe("templates", function()
		it("every catalog key has a Model beside the catalog", function()
			for _, key in PropCatalog.order do template(key) end
		end)

		it("every part is anchored, non-query and non-touch", function()
			for _, key in PropCatalog.order do
				for _, d in template(key):GetDescendants() do
					if d:IsA("BasePart") then
						if not d.Anchored then error(("%s.%s is not anchored"):format(key, d.Name)) end
						if d.CanQuery then error(("%s.%s has CanQuery on"):format(key, d.Name)) end
						if d.CanTouch then error(("%s.%s has CanTouch on"):format(key, d.Name)) end
					end
				end
			end
		end)

		it("pivots sit on the ground plane so PivotTo(groundY) lands them flush", function()
			for _, key in PropCatalog.order do
				local m = template(key)
				if not m.PrimaryPart then error(("%s has no PrimaryPart"):format(key)) end
				local y = m:GetPivot().Position.Y
				if math.abs(y) > 1e-3 then
					error(("%s pivot is %.3f studs off the ground plane"):format(key, y))
				end
			end
		end)

		it("matches the real-world envelope the entry was measured from", function()
			-- 12% tolerance: the templates step their taper across stacked boxes and carry
			-- proud collars, so they legitimately run a little over the bare product envelope.
			for _, key in PropCatalog.order do
				local e = PropCatalog.get(key)
				local ext = template(key):GetExtentsSize()
				local got = { ext.Y * STUD_MM, ext.X * STUD_MM, ext.Z * STUD_MM }
				local axis = { "height", "width", "depth" }
				for i = 1, 3 do
					local want = e.mm[i]
					if math.abs(got[i] - want) > want * 0.12 then
						error(("%s %s is %.0f mm, catalog says %.0f mm")
							:format(key, axis[i], got[i], want))
					end
				end
			end
		end)
	end)

	describe("LOD ladder", function()
		it("no prop is mesh-backed, so bakeMesh will not refuse it", function()
			for _, key in PropCatalog.order do
				local bake = ModelBaker.collect(template(key), {})
				expect(bake).to.be.ok()
				if bake.meshBacked then
					error(("%s is mesh-backed: it would get NO mesh rungs, only an impostor"):format(key))
				end
			end
		end)

		it("every prop bakes a FAR mesh", function()
			for _, key in PropCatalog.order do
				local bake = ModelBaker.collect(template(key), {})
				local mesh = ModelBaker.bakeMesh(bake, "spec_" .. key)
				if not mesh then error(("%s baked no FAR mesh"):format(key)) end
				mesh:Destroy()
			end
		end)

		-- Props measured to sit at coarsen's FLOOR: every surviving coarse part is a structural
		-- member with nothing in its colour bucket it could legally merge with. They are exempt
		-- from the halving requirement below, and the exemption is a LIST rather than a rule on
		-- purpose -- a new prop that cannot halve should fail and force a decision, not quietly
		-- inherit someone else's excuse.
		--
		-- WHY A CHAIR HITS A FLOOR A BENCH DOES NOT. A bench is 1830 mm wide, so its slats are
		-- both most of its volume AND co-planar, and they merge at ~8% waste -- that single run
		-- is what earns nearly every bench its rung. A chair is a third as wide, so its mass sits
		-- in four frame members 400-660 mm apart and 40-70 mm thick. Any union of two of them is
		-- over 80% air, far past coarsen's 0.55 ceiling, so they can never merge however the
		-- chair is authored. Four legs plus a solid seat is therefore an irreducible five, and no
		-- amount of re-authoring moves it.
		--
		-- Measured 2026-08-26 (parts -> coarse, of which merged away, colour buckets):
		--   StadiumTipUpSeat   8 -> 5   merged 0 of 5 non-DETAIL   2 buckets
		--   WaitingRoomChair  10 -> 6   merged 0 of 6              2 buckets
		--   BarStoolOutdoor   11 -> 7   merged 1 of 8              1 bucket
		--   RockingPorchChair 17 -> 10  merged 3 of 13             1 bucket
		--
		-- The two zeroes are the proof: coarsen tried every pair and merged NOTHING, so there was
		-- nothing on the table to leave. All four fall back to their FAR mesh at DISTANT, which
		-- LODProxyCache.meshFor does by returning `coarse or mesh` -- a rung fewer, not a defect.
		-- The alternatives were considered and are both worse than the fallback: padding the part
		-- count with members the real products do not have, or shrinking silhouette parts under
		-- MIN_FEATURE_STUDS so roles() deletes them. Do not do either to make this test go green.
		local COARSEN_FLOOR = {
			StadiumTipUpSeat = true,
			WaitingRoomChair = true,
			BarStoolOutdoor = true,
			RockingPorchChair = true,
		}

		-- An exemption that asserts nothing is just a hole, so the exempted props are still held
		-- to the two things that WOULD make a prop fail to merge for a fixable reason. Colour is
		-- the one that is invisible in the viewport: coarsen buckets boxes by quantised colour and
		-- merges only within a bucket, so a tastefully five-tinted model coarsens barely at all
		-- and looks perfect at every distance. Every chair in the library sits at 1-2 buckets; the
		-- bins legitimately run to 4, because a recycling stream colour is a functional
		-- requirement, so this is asserted for the exempted props rather than library-wide.
		it("props exempted from halving are at a real floor, not a fixable one", function()
			for key in COARSEN_FLOOR do
				local bake = ModelBaker.collect(template(key), {})
				local coarse = ModelBaker.coarsen(bake)
				if coarse.keptParts * 2 <= bake.keptParts then
					error(("%s now halves (%d -> %d) -- take it out of COARSEN_FLOOR")
						:format(key, bake.keptParts, coarse.keptParts))
				end
				-- coarsen tags each output box with its GROUP colour, so counting distinct colours
				-- in the coarse output IS the bucket count as coarsen itself computed it -- no need
				-- to mirror its private quantiser and no way for the two to drift apart.
				local seen, buckets = {}, 0
				for _, s in coarse.specs do
					if not seen[tostring(s.color)] then
						seen[tostring(s.color)] = true
						buckets += 1
					end
				end
				if buckets > 2 then
					error(("%s coarsens to %d parts across %d colour buckets -- it may be failing to "
						.. "merge because its palette is fragmented, which IS fixable: give the frame "
						.. "one Color3 and take near-field variation from Material instead")
						:format(coarse.keptParts, buckets, key))
				end
			end
		end)

		it("box-built props earn the DISTANT rung by at least halving keptParts", function()
			-- Only box-built props are held to this. ModelBaker.coarsen merges BOXES and keeps
			-- every non-box spec exactly as it is, on purpose -- a pitched roof or a drum is
			-- most of what makes an outline recognisable and flattening it to an AABB is the
			-- one simplification that reads as the shape changing. So a cylinder-built prop
			-- (StreetLitterBin) cannot halve however it is authored, and correctly falls back
			-- to its FAR mesh at DISTANT -- LODProxyCache.meshFor returns `coarse or mesh`.
			-- Failing it here would be a false alarm about intended engine behaviour.
			for _, key in PropCatalog.order do
				local m = template(key)
				local boxes, total = 0, 0
				for _, d in m:GetDescendants() do
					if d:IsA("BasePart") then
						total += 1
						if d:IsA("Part") and d.Shape == Enum.PartType.Block then boxes += 1 end
					end
				end
				if total == 0 or boxes / total < 0.7 then continue end
				local bake = ModelBaker.collect(m, {})
				-- A prop this simple has nothing to coarsen -- halving 4 parts means getting to
				-- 2, and there is no version of a concrete bin that is two boxes and still a
				-- concrete bin. LODProxyCache declines to spend a bake here for the same reason
				-- (coarsening saves nothing), so requiring it would fail a prop that is behaving
				-- exactly as intended. The rung matters on the models heavy enough to pay for it.
				if bake.keptParts < 8 then continue end
				if COARSEN_FLOOR[key] then continue end
				local coarse = ModelBaker.coarsen(bake)
				-- The exact test LODProxyCache.bakeFor applies before spending a coarse bake.
				if coarse.keptParts * 2 > bake.keptParts then
					error(("%s is %.0f%% boxes and coarsens only %d -> %d, so LODProxyCache will not bake it a coarse rung")
						:format(key, boxes / total * 100, bake.keptParts, coarse.keptParts))
				end
			end
		end)

		it("the parts that carry the silhouette survive MIN_FEATURE_STUDS", function()
			-- Small fittings are SUPPOSED to fall through the gate -- wheels, hinges, handles.
			-- What must not is the mass: check the model still reads at proxy range by
			-- requiring most of its volume to sit in parts the bake will actually keep.
			for _, key in PropCatalog.order do
				local kept, dropped = 0, 0
				for _, d in template(key):GetDescendants() do
					if d:IsA("BasePart") then
						local v = d.Size.X * d.Size.Y * d.Size.Z
						if math.max(d.Size.X, d.Size.Y, d.Size.Z) < MIN_FEATURE then
							dropped += v
						else
							kept += v
						end
					end
				end
				local share = kept / math.max(kept + dropped, 1e-6)
				if share < 0.9 then
					error(("%s keeps only %.0f%% of its volume above the 300 mm bake gate")
						:format(key, share * 100))
				end
			end
		end)
	end)
end
