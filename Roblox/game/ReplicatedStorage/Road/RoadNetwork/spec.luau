--!strict
return function()
	local RoadNetwork = require(script.Parent)
	local RoadMoveGeometry = require(script.Parent.Parent.RoadMoveGeometry)
	local RoadConstants = require(script.Parent.Parent.RoadConstants)
	local RoadTypeCatalog = require(script.Parent.Parent.RoadTypeCatalog)

	local function addStraight(net, from: Vector3, to: Vector3)
		local p1 = from + (to - from) / 3
		local p2 = from + (to - from) * 2 / 3
		return net:addSegment(from, p1, p2, to, "TwoLane")
	end

	describe("addSegment", function()
		it("creates two nodes for an isolated segment", function()
			local net = RoadNetwork.new()
			addStraight(net, Vector3.zero, Vector3.new(0, 0, 100))
			local count = 0
			for _ in net:getNodes() do
				count += 1
			end
			expect(count).to.equal(2)
		end)

		it("fuses endpoints within snap radius into a shared node", function()
			local net = RoadNetwork.new()
			local a = addStraight(net, Vector3.zero, Vector3.new(0, 0, 100))
			-- start near the end of the first segment -> should reuse that node
			local b = addStraight(net, Vector3.new(0, 0, 100), Vector3.new(100, 0, 100))
			expect(a.endNode).to.equal(b.startNode)
		end)

		-- A road drawn square into an existing junction but a few studs off its centre
		-- welds onto the node, and must keep the heading the player aimed with (the angle
		-- readout). Pivoting it about the loose far end instead skewed the arm -- a
		-- lopsided X, and worse the shorter the road.
		it("slides a road onto the junction it welds into instead of skewing it", function()
			local net = RoadNetwork.new()
			addStraight(net, Vector3.new(-240, 0, 0), Vector3.new(240, 0, 0))
			local south = addStraight(net, Vector3.zero, Vector3.new(0, 0, 240))
			local juncId = south.startNode
			-- due north, 14 studs east of centre, over 80 studs: a pivot lands 10 deg off
			local arm = addStraight(net, Vector3.new(14, 0, 0), Vector3.new(14, 0, -80))
			expect(arm.startNode).to.equal(juncId)
			local junc = net:getNodes()[juncId]
			expect(#junc.segments).to.equal(4)
			expect(junc.position.Magnitude < 0.01).to.equal(true)
			local placed = net:getSegment(arm.id)
			expect((placed :: any).p0.Magnitude < 0.01).to.equal(true)
			expect(math.abs((placed :: any).p3.X) < 0.01).to.equal(true)
		end)
	end)

	describe("removeSegment", function()
		it("drops orphaned nodes but keeps shared ones", function()
			local net = RoadNetwork.new()
			local a = addStraight(net, Vector3.zero, Vector3.new(0, 0, 100))
			addStraight(net, Vector3.new(0, 0, 100), Vector3.new(100, 0, 100))
			net:removeSegment(a.id)
			expect(net:getSegment(a.id)).to.equal(nil)
			-- shared node (id from a.endNode) still referenced by segment b
			expect(net:getNodes()[a.endNode]).to.be.ok()
			-- a's start node had only segment a -> removed
			expect(net:getNodes()[a.startNode]).to.equal(nil)
		end)
	end)

	-- Regression cases for the shipped crossing/deletion bugs (2026-07). Each of these
	-- was a live failure: unresolved double crossings, near-endpoint crossings skipped,
	-- buried dead-end stubs surviving, and inconsistent node lists after deletes.
	describe("resolveCrossings", function()
		local function nodeCountByDegree(net, deg: number): number
			local n = 0
			for _, node in net:getNodes() do
				if #node.segments == deg then n += 1 end
			end
			return n
		end
		local function expectConsistent(net)
			for id, seg in net:getSegments() do
				for _, nid in { seg.startNode, seg.endNode } do
					local node = net:getNodes()[nid]
					expect(node).to.be.ok()
					expect(table.find((node :: any).segments, id)).to.be.ok()
				end
			end
			for _, node in net:getNodes() do
				for _, sid in node.segments do
					expect(net:getSegments()[sid]).to.be.ok()
				end
			end
		end

		it("resolves BOTH crossings when one stroke crosses two roads", function()
			local net = RoadNetwork.new()
			addStraight(net, Vector3.new(100, 0, -100), Vector3.new(100, 0, 100))
			addStraight(net, Vector3.new(150, 0, -100), Vector3.new(150, 0, 100))
			addStraight(net, Vector3.new(0, 0, 0), Vector3.new(250, 0, 0))
			expectConsistent(net)
			expect(nodeCountByDegree(net, 4)).to.equal(2)
		end)

		it("welds a crossing that lands in the param edge band at an existing road's tip", function()
			local net = RoadNetwork.new()
			-- tip 3 studs past the crossing line -> crossing param ~0.99 on this road; the
			-- old interior guard skipped it, leaving the roads overlapping unconnected
			addStraight(net, Vector3.new(100, 0, -300), Vector3.new(100, 0, 3))
			addStraight(net, Vector3.new(0, 0, 0), Vector3.new(200, 0, 0))
			expectConsistent(net)
			expect(nodeCountByDegree(net, 3) >= 1).to.equal(true)
			for _, node in net:getNodes() do
				if #node.segments == 1 then
					expect((node.position - Vector3.new(100, 0, 0)).Magnitude > 10).to.equal(true)
				end
			end
		end)

		it("absorbs a dead-end stub buried in the junction's rendered footprint", function()
			local net = RoadNetwork.new()
			-- Stub ending just inside the rendered footprint (fill + stop line + crosswalk
			-- + dead-end bulb), derived from the live constants: a hard-coded length went
			-- stale when the road width changed. Well past the plain end-weld radius, so it
			-- exercises the absorb rule, not endpoint welding.
			local stubSpec = RoadTypeCatalog.getOrDefault("TwoLane")
			local bulb = stubSpec.width * 0.5 + (if stubSpec.noSidewalk then 0 else RoadConstants.SIDEWALK_WIDTH)
			local reach = stubSpec.width * 0.5 + RoadConstants.JUNCTION_FURNITURE_DEPTH + bulb + RoadConstants.JUNCTION_MARGIN
			local stubLen = reach - 2
			addStraight(net, Vector3.new(100, 0, -300), Vector3.new(100, 0, stubLen))
			addStraight(net, Vector3.new(0, 0, 0), Vector3.new(200, 0, 0))
			expectConsistent(net)
			expect(nodeCountByDegree(net, 3)).to.equal(1)
			for _, node in net:getNodes() do
				if #node.segments == 1 then
					expect((node.position - Vector3.new(100, 0, stubLen)).Magnitude > 5).to.equal(true)
				end
			end
		end)

		it("merges a crossing landing inside an existing junction's weld disc into it", function()
			local net = RoadNetwork.new()
			addStraight(net, Vector3.new(100, 0, -100), Vector3.new(100, 0, 100))
			addStraight(net, Vector3.new(0, 0, 0), Vector3.new(200, 0, 0)) -- X at (100, 0)
			-- crosses the vertical road 10 studs from the X: must merge into the X, never
			-- spawn a second junction beside it (overlapping fills)
			addStraight(net, Vector3.new(0, 0, 10), Vector3.new(200, 0, 10))
			expectConsistent(net)
			local junctionNodes = {}
			for _, node in net:getNodes() do
				if #node.segments >= 3 then
					table.insert(junctionNodes, node)
				end
			end
			expect(#junctionNodes).to.equal(1)
			-- FOUR arms, not six: both ends of the second road weld into the first road's
			-- end nodes as well, so it is the SAME road drawn 10 studs off -- it used to
			-- survive as two segments stacked on the first one's (dedupeParallel).
			expect(#junctionNodes[1].segments).to.equal(4)
		end)

		it("keeps node/segment lists consistent after deleting one road of a crossing", function()
			local net = RoadNetwork.new()
			addStraight(net, Vector3.new(100, 0, -100), Vector3.new(100, 0, 100))
			addStraight(net, Vector3.new(0, 0, 0), Vector3.new(200, 0, 0))
			expectConsistent(net)
			local removed = {}
			for id, seg in net:getSegments() do
				if math.abs(seg.p0.X - 100) < 1 and math.abs(seg.p3.X - 100) < 1 then
					removed[#removed + 1] = id
				end
			end
			expect(#removed > 0).to.equal(true)
			for _, id in removed do
				net:removeSegment(id)
			end
			expectConsistent(net)
		end)

		-- Worst heading break where a road CONTINUES through a node: for each arm arriving,
		-- take the best-aligned arm leaving. Within 45 deg they are one road carrying on, so
		-- the break must be ~0; a 90 deg cross arm is a different road, not a kink.
		local function worstContinuationBreakDeg(net): number
			local worst = 0
			for _, node in net:getNodes() do
				local ins, outs = {}, {}
				for _, sid in node.segments do
					local seg = net:getSegments()[sid]
					if not seg then continue end
					if seg.endNode == node.id then ins[#ins + 1] = (seg.p3 - seg.p2).Unit end
					if seg.startNode == node.id then outs[#outs + 1] = (seg.p1 - seg.p0).Unit end
				end
				for _, i in ins do
					local best = math.huge
					for _, o in outs do
						best = math.min(best, math.deg(math.acos(math.clamp(i:Dot(o), -1, 1))))
					end
					if best <= 45 and best > worst then worst = best end
				end
			end
			return worst
		end

		it("keeps a straight road straight when its crossing welds into a nearby joint", function()
			local net = RoadNetwork.new()
			-- existing road drawn in two strokes: interior joint at (0,0,0)
			addStraight(net, Vector3.new(0, 0, -100), Vector3.zero)
			addStraight(net, Vector3.zero, Vector3.new(0, 0, 100))
			-- straight stroke crossing 7 studs from the joint: inside the weld disc, so the
			-- junction merges into the joint. mergeNodes moves the halves' endpoints off the
			-- drawn line; without the handle rebuild both halves render bowed.
			addStraight(net, Vector3.new(-120, 0, 7), Vector3.new(120, 0, 7))
			for _, seg in net:getSegments() do
				expect(RoadMoveGeometry.isStraight(seg.p0, seg.p1, seg.p2, seg.p3)).to.equal(true)
			end
			-- Per-half straightness alone passed while the drawn road came out V-kinked AT the
			-- joint (each half straight, the pair not collinear -- the shipped bug). The stroke
			-- has to slide onto the joint, not fold around it.
			expect(worstContinuationBreakDeg(net) < 0.05).to.equal(true)
		end)

	end)

	describe("dissolveSwallowedArms", function()
		-- 4-way junction with a bend node `sliverLen` studs up one arm.
		local function buildCity(sliverLen: number)
			local net = RoadNetwork.new()
			local J = Vector3.new(0, 0, 60)
			local bendPos = J + Vector3.new(2, 0, 18).Unit * sliverLen
			addStraight(net, Vector3.zero, J)
			local sliver = addStraight(net, J, bendPos)
			addStraight(net, bendPos, bendPos + Vector3.new(18, 0, 82))
			addStraight(net, Vector3.new(-60, 0, 60), J)
			addStraight(net, J, Vector3.new(60, 0, 60))
			return net, sliver
		end
		-- Stand-in for RoadSceneRenderer.endSurfaceTrim: junction mouths eat 12, corners 8.
		local function trimStub(net)
			return function(nodeId, segId)
				return if #net:getNodes()[nodeId].segments >= 3 then 12 else 8
			end
		end

		it("dissolves a bend the junction mouth + corner trim would swallow", function()
			local net, sliver = buildCity(18) -- 18 <= 12 + 8 + SEGMENT_SWALLOW_MARGIN
			sliver.name = "Kept Name"
			local juncId, bendId = sliver.startNode, sliver.endNode
			expect(net:dissolveSwallowedArms({ sliver.id }, trimStub(net))).to.equal(true)
			expect(net:getSegment(sliver.id)).to.equal(nil)
			expect(net:getNodes()[bendId]).to.equal(nil)
			expect(#net:getNodes()[juncId].segments).to.equal(4)
			-- the player rename must survive on the continuation
			local survives = false
			for _, s in net:getSegments() do
				if s.name == "Kept Name" then
					survives = true
				end
			end
			expect(survives).to.equal(true)
		end)

		it("leaves an arm with room to render untouched", function()
			local net, link = buildCity(30) -- 30 > 12 + 8 + margin
			expect(net:dissolveSwallowedArms({ link.id }, trimStub(net))).to.equal(false)
			expect(net:getSegment(link.id)).to.be.ok()
		end)

		it("dissolves a corner-to-corner sliver", function()
			local net = RoadNetwork.new()
			local B = Vector3.new(0, 0, 60)
			local C = B + Vector3.new(4, 0, 13) -- ~13.6 studs, bend at each end
			addStraight(net, Vector3.zero, B)
			local sliver = addStraight(net, B, C)
			addStraight(net, C, C + Vector3.new(60, 0, 20))
			expect(net:dissolveSwallowedArms({ sliver.id }, trimStub(net))).to.equal(true)
			expect(net:getSegment(sliver.id)).to.equal(nil)
		end)

		-- Two junctions are never merged here, however much of their link the mouths cover:
		-- the renderer meets them at the midpoint, and a merge drags every arm of the dropped
		-- one. A road crossing the host just outside a junction's merge radius came out folded
		-- into a V at that junction (the "placing an alley dragged my road" report).
		it("never merges two junctions, so a road crossing beside one stays straight", function()
			local net = RoadNetwork.new()
			addStraight(net, Vector3.new(-200, 0, 0), Vector3.new(200, 0, 0))
			local cross = addStraight(net, Vector3.new(0, 0, 120), Vector3.zero)
			local gap = net:junctionMergeRadius(cross.endNode) + 3
			addStraight(net, Vector3.new(gap, 0, -100), Vector3.new(gap, 0, 100))
			-- the link has to be one the trims swallow, or this asserts nothing
			expect(gap <= 12 + 12 + RoadConstants.SEGMENT_SWALLOW_MARGIN).to.equal(true)
			local ids = {}
			for id in net:getSegments() do ids[#ids + 1] = id end
			net:dissolveSwallowedArms(ids, trimStub(net))
			local straightHalves = 0
			for _, seg in net:getSegments() do
				if math.abs(seg.p0.X - gap) < 0.01 and math.abs(seg.p3.X - gap) < 0.01 then
					straightHalves += 1
				end
			end
			expect(straightHalves).to.equal(2)
		end)

		-- HARD RULE: a road drawn beside an existing intersection joins it -- the
		-- intersection never moves, because moving it drags every arm hanging off it
		-- (the cross street came out bent). The old tie-break kept the link's START
		-- node, so which junction survived flipped with the direction the host road
		-- happened to be drawn in.
		it("never moves an existing intersection when a road connects beside it", function()
			for _, westToEast in { true, false } do
				local net = RoadNetwork.new()
				if westToEast then
					addStraight(net, Vector3.new(-200, 0, 0), Vector3.new(200, 0, 0))
				else
					addStraight(net, Vector3.new(200, 0, 0), Vector3.new(-200, 0, 0))
				end
				local cross = addStraight(net, Vector3.new(0, 0, 120), Vector3.zero)
				local juncId = cross.endNode
				addStraight(net, Vector3.new(22, 0, 0), Vector3.new(22, 0, -77))
				local ids = {}
				for id in net:getSegments() do ids[#ids + 1] = id end
				net:dissolveSwallowedArms(ids, trimStub(net))
				local junc = net:getNodes()[juncId]
				expect(junc).to.be.ok()
				expect((junc :: any).position.Magnitude < 0.01).to.equal(true)
				expect(net:getSegment(cross.id).p3.Magnitude < 0.01).to.equal(true)
			end
		end)
	end)

	describe("checkNodeFootprintOverlap", function()
		it("rejects a body sweeping over a dead-end cap without connecting", function()
			local net = RoadNetwork.new()
			addStraight(net, Vector3.zero, Vector3.new(100, 0, 0))
			-- vertical stroke 10 studs past the cap: pavements overlap, centerlines never meet
			local p0, p3 = Vector3.new(110, 0, -60), Vector3.new(110, 0, 60)
			local err = net:checkPlacement(p0, p0:Lerp(p3, 1 / 3), p0:Lerp(p3, 2 / 3), p3, "TwoLane")
			expect(err).to.be.ok()
		end)

		it("allows a genuine mid-body crossing", function()
			local net = RoadNetwork.new()
			addStraight(net, Vector3.zero, Vector3.new(100, 0, 0))
			local p0, p3 = Vector3.new(50, 0, -60), Vector3.new(50, 0, 60)
			local err = net:checkPlacement(p0, p0:Lerp(p3, 1 / 3), p0:Lerp(p3, 2 / 3), p3, "TwoLane")
			expect(err).to.equal(nil)
		end)

		it("allows a crossing that welds into the dead end", function()
			local net = RoadNetwork.new()
			addStraight(net, Vector3.zero, Vector3.new(100, 0, 0))
			local p0, p3 = Vector3.new(95, 0, -60), Vector3.new(95, 0, 60)
			local err = net:checkPlacement(p0, p0:Lerp(p3, 1 / 3), p0:Lerp(p3, 2 / 3), p3, "TwoLane")
			expect(err).to.equal(nil)
		end)
	end)

	-- The gate has to look the dead end up over the disc addSegment will WELD over, not
	-- findNodeNear's flat SNAP_RADIUS. On a highway the weld disc is ~20-41 studs, so every
	-- endpoint in between used to skip this gate entirely: the bend was welded (and the whole
	-- piece slid onto the node) with no corner check, and rendered as two overlapping
	-- carriageways. Both tests place the endpoint INSIDE that gap, so they fail on the
	-- narrow lookup.
	describe("checkCornerRadius", function()
		-- The widest highway: NODE_WELD_RADIUS is a raw stud constant while road widths are
		-- scaled, so only the wide types have a weld disc bigger than it -- Highway5W's is
		-- 20.5 against a 12-stud lookup, an 8.5-stud band. The narrow ones have no gap at all.
		local HWY = "Highway5W"
		local hostHw = RoadTypeCatalog.getOrDefault(HWY).width * 0.5
		local weld = math.max(RoadConstants.NODE_WELD_RADIUS, hostHw + RoadConstants.JUNCTION_MARGIN)
		-- Halfway into the gap. If the constants ever close it these tests assert nothing,
		-- so pin it: they must straddle the two radii to mean anything.
		local gap = (RoadConstants.SNAP_RADIUS + weld) * 0.5

		local function bendOffDeadEnd(net, degOffArm: number)
			-- Existing highway runs in from the west and dead-ends at the origin, so its arm
			-- direction there points WEST. Weld a new one `gap` studs east of that node and
			-- send it back west at `degOffArm` to the arm: a shallow bend.
			local a = math.rad(degOffArm)
			local dir = Vector3.new(-math.cos(a), 0, math.sin(a))
			local p0 = Vector3.new(gap, 0, 0)
			local p3 = p0 + dir * 300
			return p0, p0:Lerp(p3, 1 / 3), p0:Lerp(p3, 2 / 3), p3
		end

		it("has a gap between the weld disc and the node lookup to test at all", function()
			expect(weld > RoadConstants.SNAP_RADIUS).to.equal(true)
			expect(gap > RoadConstants.SNAP_RADIUS).to.equal(true)
			expect(gap <= weld).to.equal(true)
		end)

		it("rejects a shallow highway bend welded from outside the node lookup radius", function()
			local net = RoadNetwork.new()
			local from, to = Vector3.new(-300, 0, 0), Vector3.zero
			net:addSegment(from, from:Lerp(to, 1 / 3), from:Lerp(to, 2 / 3), to, HWY)
			expect(net:checkCornerRadius(bendOffDeadEnd(net, 25)) ~= nil).to.equal(true)
		end)

		it("still allows a square turn off the same dead end", function()
			local net = RoadNetwork.new()
			local from, to = Vector3.new(-300, 0, 0), Vector3.zero
			net:addSegment(from, from:Lerp(to, 1 / 3), from:Lerp(to, 2 / 3), to, HWY)
			local p0 = Vector3.new(gap, 0, 0)
			local p3 = p0 + Vector3.new(0, 0, 300)
			expect(net:checkCornerRadius(p0, p0:Lerp(p3, 1 / 3), p0:Lerp(p3, 2 / 3), p3, HWY)).to.equal(nil)
		end)
	end)

	-- A long drag is placed as a chain of pieces. A start inside a junction's merge radius
	-- slides the first piece onto the junction, and that slide used to ride all the way to
	-- the far end -- pulling it off the road it was drawn to and leaving a dead end short of
	-- it ("the road just stopped").
	describe("addChain", function()
		local function chainCurves(from: Vector3, to: Vector3, pieces: number)
			local curves = {}
			for i = 1, pieces do
				local a, b = from:Lerp(to, (i - 1) / pieces), from:Lerp(to, i / pieces)
				curves[i] = { p0 = a, p1 = a:Lerp(b, 1 / 3), p2 = a:Lerp(b, 2 / 3), p3 = b }
			end
			return curves
		end
		-- T junction at the origin; returns a start offset along the host that welds into it
		-- from outside the plain weld radius, so the first piece really slides.
		local function tJunction(net): (number, number)
			addStraight(net, Vector3.new(-400, 0, 0), Vector3.new(400, 0, 0))
			addStraight(net, Vector3.new(0, 0, -200), Vector3.zero)
			local junc = net:findNodeNear(Vector3.zero) :: any
			return junc.id, net:junctionMergeRadius(junc.id) - 0.5
		end

		it("still reaches the road its far end was drawn to when the start slides", function()
			local net = RoadNetwork.new()
			local juncId, offset = tJunction(net)
			expect(offset > RoadConstants.NODE_WELD_RADIUS).to.equal(true)
			addStraight(net, Vector3.new(300, 0, 100), Vector3.new(300, 0, 700))
			local added = net:addChain(chainCurves(Vector3.new(offset, 0, 0), Vector3.new(300, 0, 300), 3), "TwoLane")
			expect(added[1].startNode).to.equal(juncId)
			expect(added[3].startNode).to.equal(added[2].endNode)
			local tip = net:getNodes()[added[3].endNode] :: any
			expect(#tip.segments).to.equal(3)
			expect(math.abs(tip.position.X - 300) < 0.01).to.equal(true)
		end)

		it("slides a free-ended chain whole, keeping its drawn heading", function()
			local net = RoadNetwork.new()
			local _, offset = tJunction(net)
			local added = net:addChain(chainCurves(Vector3.new(offset, 0, 0), Vector3.new(offset, 0, 450), 3), "TwoLane")
			for _, seg in added do
				local placed = net:getSegment(seg.id) :: any
				expect(math.abs(placed.p0.X) < 0.01 and math.abs(placed.p3.X) < 0.01).to.equal(true)
			end
		end)
	end)

	-- Two roads linking the same two nodes side by side render fused at both ends. Only a
	-- dry run knows which nodes a road ends up linking, and it must not touch the real network.
	describe("checkParallelTwin", function()
		-- Host road with T junctions at x=0 and x=100; a road drawn node to node over that
		-- link, bowed `bow` studs out at its middle.
		local function twinCheck(bow: number): string?
			local net = RoadNetwork.new()
			addStraight(net, Vector3.new(-200, 0, 0), Vector3.new(200, 0, 0))
			addStraight(net, Vector3.new(0, 0, -120), Vector3.zero)
			addStraight(net, Vector3.new(100, 0, -120), Vector3.new(100, 0, 0))
			local function counts(): (number, number)
				local s, n = 0, 0
				for _ in net:getSegments() do s += 1 end
				for _ in net:getNodes() do n += 1 end
				return s, n
			end
			local segs, nodes = counts()
			local h = Vector3.new(0, 0, bow / 0.75)
			local err = net:checkParallelTwin(Vector3.zero, Vector3.new(100 / 3, 0, 0) + h, Vector3.new(200 / 3, 0, 0) + h, Vector3.new(100, 0, 0), "TwoLane")
			local segsAfter, nodesAfter = counts()
			expect(segsAfter).to.equal(segs)
			expect(nodesAfter).to.equal(nodes)
			return err
		end

		it("refuses a road linking two junctions right beside the road already linking them", function()
			expect(twinCheck(10) ~= nil).to.equal(true)
		end)

		it("allows a bypass that swings well clear between the same junctions", function()
			expect(twinCheck(70)).to.equal(nil)
		end)
	end)

	-- A merge can re-point an arm onto a node that already had the same arm: two segments,
	-- same pair of nodes, same path. They stack -- only one bakes geometry, but both dress
	-- their own name blades, so one crossing sprouts a second set of signs at the junction
	-- (the "I drew the road once and it placed many" report).
	describe("dedupeParallel", function()
		-- An identical road drawn well clear, then dragged onto the host end for end --
		-- exactly what mergeNodes does to a crossing's arms. `bow` swings its middle out.
		local function twinOntoRoad(bow: number)
			local net = RoadNetwork.new()
			local host = addStraight(net, Vector3.zero, Vector3.new(0, 0, 200))
			local a, b = Vector3.new(600, 0, 0), Vector3.new(600, 0, 200)
			local h = Vector3.new(bow, 0, 0)
			local twin = net:addSegment(a, a:Lerp(b, 1 / 3) + h, a:Lerp(b, 2 / 3) + h, b, "TwoLane")
			net:mergeNodes(host.startNode, twin.startNode)
			net:mergeNodes(host.endNode, twin.endNode)
			return net, host, twin
		end

		it("drops the second of two segments stacked between the same nodes", function()
			local net, host, twin = twinOntoRoad(0)
			expect(net:getSegment(host.id)).to.be.ok()
			expect(net:getSegment(twin.id)).to.equal(nil)
			expect(#net:getNodes()[host.startNode].segments).to.equal(1)
			expect(#net:getNodes()[host.endNode].segments).to.equal(1)
		end)

		it("keeps a bypass between the same nodes that swings clear of the road", function()
			local net, host, twin = twinOntoRoad(160)
			expect(net:getSegment(host.id)).to.be.ok()
			expect(net:getSegment(twin.id)).to.be.ok()
		end)
	end)

end
