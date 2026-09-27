--!strict
-- The snap model and the gizmo's ownership handoff. Both are pure state, and both are the
-- kind of thing that breaks silently: a preset that quietly divides the wrong default, or
-- a tool that releases a gizmo it no longer holds and blanks the handles under the tool
-- that just took it.
return function()
	local EditorGizmos = require(script.Parent)

	describe("snap presets", function()
		it("defaults to TWO METRES, not one stud and not one metre", function()
			-- The world is two studs to the metre, and every other length the player is shown
			-- is in metres. A default of one STUD moved things half a metre at a time, which
			-- is what "the grid isn't working" actually was; one METRE then took two presses to
			-- clear a block, so a builder's unit here is two.
			EditorGizmos.setSnapPreset("size", "Default")
			expect(EditorGizmos.toMetres(EditorGizmos.getStep("size"))).to.equal(2)
			expect(EditorGizmos.stepLabel("size")).to.equal("2 m")
			-- Round trip, so metres-in/studs-out cannot drift.
			expect(EditorGizmos.toMetres(EditorGizmos.toStuds(2.5))).to.equal(2.5)
		end)

		it("moves on THE placement grid, not a grid of its own", function()
			-- One lattice for the whole game: the handles and every placement tool share it,
			-- so setting it here IS setting it for services, nature and roads.
			local PlacementGrid = require(game:GetService("ReplicatedStorage").Shared.PlacementGrid)
			EditorGizmos.setSnapPreset("move", "5")
			expect(PlacementGrid.isEnabled()).to.equal(true)
			expect(PlacementGrid.getSize()).to.equal(5)
			expect(EditorGizmos.toMetres(EditorGizmos.getStep("move"))).to.equal(5)
			PlacementGrid.setSize(10)
			expect(EditorGizmos.getSnapPreset("move")).to.equal("10")
			expect(EditorGizmos.stepLabel("move")).to.equal("10 m")
			EditorGizmos.setSnapPreset("move", "None")
			expect(PlacementGrid.isEnabled()).to.equal(false)
			expect(EditorGizmos.getStep("move")).to.equal(0)
			local keys = {}
			for _, p in EditorGizmos.presetsFor("move") do table.insert(keys, p.key) end
			expect(table.concat(keys, ",")).to.equal("1,5,10,None")
		end)

		it("divides each channel's OWN default", function()
			-- The point of sharing preset names across channels: 1/2 is a metre for size and
			-- half of 15 degrees for rotate, from one list.
			EditorGizmos.setSnapPreset("size", "Default")
			EditorGizmos.setSnapPreset("rotate", "Default")
			expect(EditorGizmos.toMetres(EditorGizmos.getStep("size"))).to.equal(2)
			expect(EditorGizmos.getStep("rotate")).to.equal(15)
			EditorGizmos.setSnapPreset("size", "Half")
			EditorGizmos.setSnapPreset("rotate", "Half")
			expect(EditorGizmos.toMetres(EditorGizmos.getStep("size"))).to.equal(1)
			expect(EditorGizmos.getStep("rotate")).to.equal(7.5)
			EditorGizmos.setSnapPreset("rotate", "Quarter")
			expect(EditorGizmos.getStep("rotate")).to.equal(3.75)
			EditorGizmos.setSnapPreset("size", "Eighth")
			expect(EditorGizmos.toMetres(EditorGizmos.getStep("size"))).to.equal(0.25)
		end)

		it("keeps the three channels independent", function()
			EditorGizmos.setSnapPreset("move", "1")
			EditorGizmos.setSnapPreset("size", "None")
			expect(EditorGizmos.getStep("size")).to.equal(0)
			expect(EditorGizmos.toMetres(EditorGizmos.getStep("move"))).to.equal(1)
		end)

		it("rounds when snapped and passes through when free", function()
			EditorGizmos.setSnapPreset("move", "1")
			EditorGizmos.setSnapPreset("size", "None")
			EditorGizmos.setSnapPreset("rotate", "Default")
			-- Studs in, studs out: the 1 m grid is 2 studs, so 2.4 lands on 2 and 3.1 on 4.
			expect(EditorGizmos.snapLen(2.4)).to.equal(2)
			expect(EditorGizmos.snapLen(3.1)).to.equal(4)
			expect(EditorGizmos.snapLen(0.9)).to.equal(0)
			expect(EditorGizmos.snapSize(1.237)).to.equal(1.237)
			expect(EditorGizmos.snapDeg(50)).to.equal(45)
			expect(EditorGizmos.snapDeg(70)).to.equal(75)
		end)

		it("offers exactly the five divisions, and refuses anything else", function()
			-- There is no CUSTOM step any more: a free-text box beside a preset dropdown read
			-- as if the number in it was the live step. Five divisions, no typing.
			local keys = {}
			for _, p in EditorGizmos.PRESETS do table.insert(keys, p.key) end
			expect(table.concat(keys, ",")).to.equal("Default,Half,Quarter,Eighth,None")
			EditorGizmos.setSnapPreset("size", "Quarter")
			EditorGizmos.setSnapPreset("size", "NotAPreset")
			expect(EditorGizmos.getSnapPreset("size")).to.equal("Quarter")
			-- The old setter is a no-op rather than a hole: an older caller must not be able to
			-- put a channel into a state nothing on screen can display.
			EditorGizmos.setCustomStep("size", 0.3)
			expect(EditorGizmos.getSnapPreset("size")).to.equal("Quarter")
			-- Move refuses a grid size it does not offer, the same way.
			EditorGizmos.setSnapPreset("move", "5")
			EditorGizmos.setSnapPreset("move", "3")
			expect(EditorGizmos.getSnapPreset("move")).to.equal("5")
		end)

		it("is inert for a channel it does not have", function()
			expect(EditorGizmos.getStep("wobble")).to.equal(0)
		end)
	end)

	describe("space", function()
		it("toggles and rejects anything else", function()
			EditorGizmos.setSpace("Relative")
			expect(EditorGizmos.getSpace()).to.equal("Relative")
			EditorGizmos.setSpace("Global")
			expect(EditorGizmos.getSpace()).to.equal("Global")
			EditorGizmos.setSpace("sideways")
			expect(EditorGizmos.getSpace()).to.equal("Global")
			EditorGizmos.setSpace("Relative")
		end)
	end)

	describe("layout", function()
		it("nests every hit band, so no two grips share a click", function()
			-- Five grips on the same three axes. Sized by eye they WILL collide, and the
			-- collision is invisible in the constants and obvious the moment a click on a
			-- resize cube starts a plane drag instead. Each band starts past the last one.
			local prev = nil
			for _, band in EditorGizmos.HIT_BANDS do
				expect(band.to > band.from).to.equal(true)
				if prev then
					expect(band.from >= prev.to).to.equal(true)
				end
				prev = band
			end
			-- Rotation rings outside the plane quads, move arrows outside the rings: the
			-- reading order the gizmo is meant to have.
			expect(EditorGizmos.HIT_BANDS[#EditorGizmos.HIT_BANDS].name).to.equal("move")
			expect(EditorGizmos.HIT_BANDS[1].name).to.equal("centre")
			-- Four bands, not five: the plane quads are gone. They sat between the resize
			-- cubes and the rings and were most of what made the middle unreadable.
			expect(#EditorGizmos.HIT_BANDS).to.equal(4)
		end)
	end)

	describe("pivot", function()
		it("is a fraction of the box, so Base is the bottom face whatever the size", function()
			-- Stored as a fraction and not studs on purpose: resize the selection and the
			-- pivot has to stay ON the base, not hang under it or climb inside.
			EditorGizmos.resetPivot()
			expect(EditorGizmos.getPivotLocal()).to.equal(Vector3.zero)
			expect(EditorGizmos.hasPivotOffset()).to.equal(false)
			EditorGizmos.alignPivot()
			expect(EditorGizmos.getPivotLocal().Y).to.equal(-0.5)
			expect(EditorGizmos.hasPivotOffset()).to.equal(true)
			EditorGizmos.resetPivot()
		end)

		it("only drags the pivot while pivot mode is on", function()
			expect(EditorGizmos.isPivotMode()).to.equal(false)
			EditorGizmos.setPivotMode(true)
			expect(EditorGizmos.isPivotMode()).to.equal(true)
			EditorGizmos.setPivotMode(false)
		end)
	end)

	describe("vertical snapping", function()
		it("is a toggle of its own, not part of the move step", function()
			-- Height is the axis a builder most often wants free (a prop seated on a kerb is
			-- at the kerb's Y, not a whole stud), so it must not be tangled with move snapping.
			EditorGizmos.setSnapPreset("move", "1")
			EditorGizmos.setVerticalSnap(false)
			expect(EditorGizmos.isVerticalSnap()).to.equal(false)
			expect(EditorGizmos.toMetres(EditorGizmos.getStep("move"))).to.equal(1)
			EditorGizmos.setVerticalSnap(true)
			expect(EditorGizmos.isVerticalSnap()).to.equal(true)
		end)
	end)

	describe("ownership", function()
		local deps = {
			getSelected = function(): Instance? return nil end,
			getSelectedId = function(): number? return 1 end,
			sendCmd = function() end,
			fitsPivot = function() return true end,
		}

		it("hands a fresh claim a centred pivot", function()
			-- A pivot dragged onto one prop must not still be waiting on the next one.
			EditorGizmos.claim("A", deps)
			EditorGizmos.alignPivot()
			EditorGizmos.claim("B", deps)
			expect(EditorGizmos.getPivotLocal()).to.equal(Vector3.zero)
			EditorGizmos.release("B")
		end)

		it("only lets the holder hand it back", function()
			-- The editor and the city's Move tool share one gizmo. A tool shutting down
			-- late must not blank the handles under the one that just took them.
			EditorGizmos.claim("A", deps)
			expect(EditorGizmos.getOwner()).to.equal("A")
			EditorGizmos.release("B")
			expect(EditorGizmos.getOwner()).to.equal("A")
			EditorGizmos.claim("B", deps)
			expect(EditorGizmos.getOwner()).to.equal("B")
			EditorGizmos.release("B")
			expect(EditorGizmos.getOwner() == nil).to.equal(true)
		end)
	end)

	-- A 4-stud cube seated on the ground: centre at y=2, base at y=0, base-pivoted, unrotated.
	local START_PART = CFrame.new(0, 2, 0)
	local START_SIZE = Vector3.new(4, 4, 4)
	local NO_ROT = CFrame.new()
	local function near(a: number, b: number): boolean
		return math.abs(a - b) < 1e-4
	end

	describe("one-sided resize", function()
		it("plants the face you are NOT holding, growing and shrinking", function()
			-- Blender's rule, and the whole point of a one-sided resize: pull the top up and
			-- the bottom stays on the ground.
			local pc, ns = EditorGizmos.resizeFrames(START_PART, START_SIZE, NO_ROT, 2, 1, 10)
			expect(near(pc.Position.Y - ns.Y / 2, 0)).to.equal(true)
			local sc, ss = EditorGizmos.resizeFrames(START_PART, START_SIZE, NO_ROT, 2, 1, 2)
			expect(near(sc.Position.Y - ss.Y / 2, 0)).to.equal(true)
			-- And the mirror: pulling the NEGATIVE face leaves the positive one alone.
			local xc, xs = EditorGizmos.resizeFrames(START_PART, START_SIZE, NO_ROT, 1, -1, 10)
			expect(near(xc.Position.X + xs.X / 2, 2)).to.equal(true)
		end)

		it("seats the pivot on the part's new BASE", function()
			-- NaturePlaceService.applyStretch re-bases the pivot the same way on the round trip,
			-- and then plants that pivot where the client said. Report anything else and a
			-- stretched block jumps the moment you let go.
			local _, _, pivot = EditorGizmos.resizeFrames(START_PART, START_SIZE, NO_ROT, 2, 1, 10)
			expect(near(pivot.Position.Y, 0)).to.equal(true)
		end)

		it("leans the leading edge UP and the trailing edge down", function()
			-- Weight, as a lean rather than a lag. The old sway eased the POSITION, which read
			-- as the tool failing to keep up rather than as mass.
			local state, lean = Vector3.zero, CFrame.identity
			for _ = 1, 40 do lean, state = EditorGizmos.leanStep(state, Vector3.new(40, 0, 0), 1 / 60) end
			expect(lean:VectorToWorldSpace(Vector3.new(1, 0, 0)).Y > 0).to.equal(true)
			expect(lean:VectorToWorldSpace(Vector3.new(-1, 0, 0)).Y < 0).to.equal(true)
			-- Any heading, not just the one the cross product happened to be written for.
			local s2, l2 = Vector3.zero, CFrame.identity
			for _ = 1, 40 do l2, s2 = EditorGizmos.leanStep(s2, Vector3.new(0, 0, -40), 1 / 60) end
			expect(l2:VectorToWorldSpace(Vector3.new(0, 0, -1)).Y > 0).to.equal(true)
		end)

		it("settles level when it stops, and never leans past the clamp", function()
			local state, lean = Vector3.zero, CFrame.identity
			-- Absurd speed: a lean that scales without limit reads as a stunt, not as weight.
			for _ = 1, 300 do lean, state = EditorGizmos.leanStep(state, Vector3.new(4000, 0, 0), 1 / 60) end
			local _, big = lean:ToAxisAngle()
			expect(math.deg(big) <= 11.001).to.equal(true)
			for _ = 1, 300 do lean, state = EditorGizmos.leanStep(state, Vector3.zero, 1 / 60) end
			local _, rest = lean:ToAxisAngle()
			expect(math.deg(rest) < 0.01).to.equal(true)
		end)

		it("does not depend on where the last frame left the part", function()
			-- THE regression. This used to re-read the part's live CFrame to find the pivot
			-- inside it -- but the drag moves that part, so every frame corrected for a shift it
			-- had already applied. The preview flickered and the prop walked off.
			local a = EditorGizmos.resizeFrames(START_PART, START_SIZE, NO_ROT, 2, 1, 10)
			local b = EditorGizmos.resizeFrames(START_PART, START_SIZE, NO_ROT, 2, 1, 10)
			expect(a.Position).to.equal(b.Position)
			-- And the state a frame produced is a FIXED POINT: hand back the moved part at its
			-- new size and nothing moves again. That is what "no feedback loop" means here.
			local c = EditorGizmos.resizeFrames(a, Vector3.new(4, 10, 4), NO_ROT, 2, 1, 10)
			expect(c.Position).to.equal(a.Position)
		end)
	end)

	describe("picking", function()
		-- The picker's depth test. A ray down -Z from z=10 meets the near box first; a box
		-- off to the side is a miss, and a box BEHIND the origin is never hit.
		it("reports the entry distance, misses to the side and behind", function()
			local o, d, half = Vector3.new(0, 0, 10), Vector3.new(0, 0, -1), Vector3.one
			expect(EditorGizmos.rayBox(o, d, CFrame.new(0, 0, 2), half)).to.equal(7)
			expect(EditorGizmos.rayBox(o, d, CFrame.new(0, 0, -4), half)).to.equal(13)
			expect(EditorGizmos.rayBox(o, d, CFrame.new(3, 0, 0), half)).to.equal(nil)
			expect(EditorGizmos.rayBox(o, d, CFrame.new(0, 0, 20), half)).to.equal(nil)
			-- Rotated boxes are tested in their own frame.
			local turned = CFrame.new(0, 0, 0) * CFrame.Angles(0, math.rad(45), 0)
			expect(EditorGizmos.rayBox(o, d, turned, half) ~= nil).to.equal(true)
		end)
	end)
end
