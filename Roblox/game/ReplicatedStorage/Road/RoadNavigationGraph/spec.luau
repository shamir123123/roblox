--!strict
return function()
	local RoadNetwork = require(script.Parent.Parent.RoadNetwork)
	local RoadNavigationGraph = require(script.Parent)

	local function addStraight(network: any, from: Vector3, to: Vector3, roadType: string)
		local delta = to - from
		return network:addSegment(from, from + delta / 3, from + delta * 2 / 3, to, roadType)
	end

	local function sortedOutgoing(graph: any, edgeId: string): { string }
		local edge = graph:GetEdge(edgeId)
		local outgoing = table.clone(edge.out)
		table.sort(outgoing)
		return outgoing
	end

	local function expectOutgoing(graph: any, edgeId: string, expected: { string })
		expect(table.concat(sortedOutgoing(graph, edgeId), ",")).to.equal(table.concat(expected, ","))
	end

	-- These expectations are for RIGHT-HAND traffic (RoadConstants.DRIVING_SIDE == "right").
	-- A direction's lanes sit to the RIGHT of the centreline, so a forward lane's offset is
	-- positive; lane ordinal 1 is the lane against the centreline and takes the LEFT turn,
	-- and the kerbside lane takes the RIGHT. Flipping the driving side inverts every offset
	-- sign and swaps every left/right expectation below.
	describe("automatic lane connections", function()
		it("preserves straight lanes and restricts turns to the correct edge lanes", function()
			local net = RoadNetwork.new()
			local center = Vector3.new(0, 0, 0)
			local south = addStraight(net, center, Vector3.new(0, 0, 100), "CollectorRoad")
			addStraight(net, center, Vector3.new(0, 0, -100), "CollectorRoad")
			addStraight(net, center, Vector3.new(-100, 0, 0), "CollectorRoad")
			addStraight(net, center, Vector3.new(100, 0, 0), "CollectorRoad")

			local graph = RoadNavigationGraph.new()
			graph:Rebuild(net, {})
			-- Approaching northbound: the centre lane goes straight or turns left (west, S3),
			-- the kerb lane goes straight or turns right (east, S4). Moving over inside the
			-- junction exists only as a last resort, priced well above keeping the lane.
			expectOutgoing(graph, `S{south.id}:L3:R`, { "S2:L1:F", "S2:L2:F", "S3:L1:F" })
			expectOutgoing(graph, `S{south.id}:L4:R`, { "S2:L1:F", "S2:L2:F", "S4:L2:F" })
			local centre = graph:GetEdge(`S{south.id}:L3:R`)
			expect(centre.turnCost["S2:L2:F"] - centre.turnCost["S2:L1:F"] >= 15).to.equal(true)
		end)

		it("does not merge an extra curb lane straight through a narrowing junction", function()
			local net = RoadNetwork.new()
			local center = Vector3.new(0, 0, 0)
			local south = addStraight(net, center, Vector3.new(0, 0, 100), "CollectorRoad")
			addStraight(net, center, Vector3.new(0, 0, -100), "NarrowRoad")
			addStraight(net, center, Vector3.new(-100, 0, 0), "NarrowRoad")
			addStraight(net, center, Vector3.new(100, 0, 0), "NarrowRoad")

			local graph = RoadNavigationGraph.new()
			graph:Rebuild(net, {})
			expectOutgoing(graph, `S{south.id}:L3:R`, { "S2:L1:F", "S3:L1:F" })
			expectOutgoing(graph, `S{south.id}:L4:R`, { "S4:L1:F" })
		end)

		it("preserves lane order through a curved two-arm continuation", function()
			local net = RoadNetwork.new()
			local west = addStraight(net, Vector3.new(-100, 0, 0), Vector3.new(0, 0, 0), "CollectorRoad")
			addStraight(net, Vector3.new(0, 0, 0), Vector3.new(0, 0, -100), "CollectorRoad")

			local graph = RoadNavigationGraph.new()
			graph:Rebuild(net, {})
			expectOutgoing(graph, `S{west.id}:L1:F`, { "S2:L1:F", "S2:L2:F" })
			expectOutgoing(graph, `S{west.id}:L2:F`, { "S2:L1:F", "S2:L2:F" })
			-- Lane order survives as COST, not as connectivity: staying in lane is free and
			-- moving over is charged, so a driver only shifts when the route needs it.
			local inner = graph:GetEdge(`S{west.id}:L1:F`)
			expect(inner.turnCost["S2:L1:F"] < inner.turnCost["S2:L2:F"]).to.equal(true)
		end)

		it("changes lane at a node, one lane at a time", function()
			local net = RoadNetwork.new()
			local first = addStraight(net, Vector3.new(0, 0, 0), Vector3.new(0, 0, 140), "OneWay3Lane")
			addStraight(net, Vector3.new(0, 0, 140), Vector3.new(0, 0, 280), "OneWay3Lane")

			local graph = RoadNavigationGraph.new()
			graph:Rebuild(net, {})
			-- Ordinal 1 is the lane against the centreline and 3 the kerb: the middle lane
			-- reaches both neighbours, and neither outside lane crosses two lanes in one go.
			expectOutgoing(graph, `S{first.id}:L1:F`, { "S2:L1:F", "S2:L2:F" })
			expectOutgoing(graph, `S{first.id}:L2:F`, { "S2:L1:F", "S2:L2:F", "S2:L3:F" })
			expectOutgoing(graph, `S{first.id}:L3:F`, { "S2:L2:F", "S2:L3:F" })
		end)

		it("widens a two-arm continuation centre-side first", function()
			local net = RoadNetwork.new()
			local narrow = addStraight(net, Vector3.new(0, 0, 100), Vector3.new(0, 0, 0), "NarrowRoad")
			addStraight(net, Vector3.new(0, 0, 0), Vector3.new(0, 0, -100), "CollectorRoad")

			local graph = RoadNavigationGraph.new()
			graph:Rebuild(net, {})
			expectOutgoing(graph, `S{narrow.id}:L1:F`, { "S2:L1:F" })
		end)

		it("distributes a dense junction's ranked branches across its approach lanes", function()
			local net = RoadNetwork.new()
			local center = Vector3.new(0, 0, 0)
			local radius = 200
			for i = 0, 19 do
				local angle = math.pi * 2 * i / 20
				addStraight(net, center, Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius), "CollectorRoad")
			end

			local graph = RoadNavigationGraph.new()
			graph:Rebuild(net, {})
			local seen: { [number]: number } = {}
			local branchCounts = { 0, 0 }
			for ordinal, edgeId in { "S1:L3:R", "S1:L4:R" } do
				local edge = graph:GetEdge(edgeId)
				for _, outId in edge.out do
					local outEdge = graph:GetEdge(outId)
					seen[outEdge.segmentId] = (seen[outEdge.segmentId] or 0) + 1
					if outEdge.segmentId ~= 11 then
						local movement = edge.outMovement[outId]
						-- The crossing turn (left, on the right-hand-drive map) lands in the lane
						-- against the centreline; every other exit lands in the kerbside lane.
						local expectedOrdinal = if movement == "left" then 1 else outEdge.laneCountInDirection
						expect(outEdge.laneOrdinal).to.equal(expectedOrdinal)
						branchCounts[ordinal] += 1
					end
				end
			end
			expect(seen[1]).to.equal(nil)
			-- Both approach lanes go straight on, each into its own lane or (last resort) its neighbour.
			expect(seen[11]).to.equal(4)
			-- Arms 2 and 20 sit 162 deg off the approach -- doubling back, so they are
			-- U-turns and get no connection, same as the car's own segment.
			expect(seen[2]).to.equal(nil)
			expect(seen[20]).to.equal(nil)
			for segmentId = 3, 19 do
				if segmentId ~= 11 then expect(seen[segmentId]).to.equal(1) end
			end
			expect(branchCounts[1]).to.equal(8)
			expect(branchCounts[2]).to.equal(8)
		end)

		it("keeps only the best-aligned fork arm straight in its arrows", function()
			local net = RoadNetwork.new()
			local center = Vector3.new(0, 0, 0)
			local south = addStraight(net, center, Vector3.new(0, 0, 100), "CollectorRoad")
			addStraight(net, center, Vector3.new(-17, 0, -100), "CollectorRoad")
			addStraight(net, center, Vector3.new(34, 0, -94), "CollectorRoad")

			local graph = RoadNavigationGraph.new()
			graph:Rebuild(net, {})
			local movements = graph:GetIncomingEdgeArrowDirs(`S{south.id}:L3:R`)
			expect(movements.straight).to.equal(true)
			expect(movements.right).to.equal(true)
		end)

		it("keeps angled T-junction arrows on their physical approach lanes", function()
			local net = RoadNetwork.new()
			local center = Vector3.new(0, 0, 0)
			local south = addStraight(net, Vector3.new(0, 0, 120), center, "CollectorRoad")
			addStraight(net, center, Vector3.new(-120, 0, -48), "CollectorRoad")
			addStraight(net, center, Vector3.new(120, 0, 48), "CollectorRoad")

			local graph = RoadNavigationGraph.new()
			graph:Rebuild(net, {})
			local stem = graph:GetIncomingEdgesForSegment(south.endNode, south.id)
			expectOutgoing(graph, stem[1].id, { "S2:L1:F" })
			expectOutgoing(graph, stem[2].id, { "S3:L2:F" })
			expect(stem[1].offset).to.equal(3.75)
			expect(stem[2].offset).to.equal(11.25)
			local inner = graph:GetIncomingEdgeArrowDirs(stem[1].id)
			local curb = graph:GetIncomingEdgeArrowDirs(stem[2].id)
			expect(inner.left).to.equal(true)
			expect(inner.right).to.equal(false)
			expect(curb.right).to.equal(true)
			expect(curb.left).to.equal(false)
		end)

		it("exposes physical arrow offsets without swapping forward approach lanes", function()
			local net = RoadNetwork.new()
			local center = Vector3.new(0, 0, 0)
			local south = addStraight(net, Vector3.new(0, 0, 100), center, "CollectorRoad")
			local north = addStraight(net, center, Vector3.new(0, 0, -100), "CollectorRoad")
			addStraight(net, center, Vector3.new(-100, 0, 0), "CollectorRoad")
			addStraight(net, center, Vector3.new(100, 0, 0), "CollectorRoad")

			local graph = RoadNavigationGraph.new()
			graph:Rebuild(net, {})
			local forward = graph:GetIncomingEdgesForSegment(south.endNode, south.id)
			local reverse = graph:GetIncomingEdgesForSegment(north.startNode, north.id)
			expect(forward[1].id).to.equal("S1:L1:F")
			expect(forward[1].offset).to.equal(3.75)
			expect(forward[2].id).to.equal("S1:L2:F")
			expect(forward[2].offset).to.equal(11.25)
			expect(reverse[1].id).to.equal("S2:L3:R")
			expect(reverse[1].offset).to.equal(-3.75)
			expect(reverse[2].id).to.equal("S2:L4:R")
			expect(reverse[2].offset).to.equal(-11.25)
		end)

		it("maps a one-way approach to every ranked exit and arrow", function()
			local net = RoadNetwork.new()
			local center = Vector3.new(0, 0, 0)
			local south = addStraight(net, Vector3.new(0, 0, 100), center, "OneWay")
			addStraight(net, center, Vector3.new(0, 0, -100), "NarrowRoad")
			addStraight(net, center, Vector3.new(-100, 0, 0), "NarrowRoad")
			addStraight(net, center, Vector3.new(100, 0, 0), "NarrowRoad")

			local graph = RoadNavigationGraph.new()
			graph:Rebuild(net, {})
			expectOutgoing(graph, `S{south.id}:L1:F`, { "S2:L1:F", "S3:L1:F", "S4:L1:F" })
			local movements = graph:GetIncomingEdgeArrowDirs(`S{south.id}:L1:F`)
			expect(movements.left).to.equal(true)
			expect(movements.straight).to.equal(true)
			expect(movements.right).to.equal(true)
		end)

		it("uses only player-defined connections after a junction becomes manual", function()
			local net = RoadNetwork.new()
			local center = Vector3.new(0, 0, 0)
			local south = addStraight(net, center, Vector3.new(0, 0, 100), "CollectorRoad")
			addStraight(net, center, Vector3.new(0, 0, -100), "CollectorRoad")
			addStraight(net, center, Vector3.new(-100, 0, 0), "CollectorRoad")
			addStraight(net, center, Vector3.new(100, 0, 0), "CollectorRoad")
			local incoming = `S{south.id}:L3:R`

			local graph = RoadNavigationGraph.new()
			graph:Rebuild(net, {
				[south.startNode] = {
					left = true,
					right = true,
					straight = true,
					uturn = false,
					manual = true,
					connectionRules = {
						[`{incoming}>S4:L2:F`] = true,
					},
				},
			})
			expectOutgoing(graph, incoming, { "S4:L2:F" })
		end)
	end)

	it("refuses a doubling-back exit onto another segment at a junction", function()
		local net = RoadNetwork.new()
		local center = Vector3.new(0, 0, 0)
		local west = addStraight(net, Vector3.new(-300, 0, 0), center, "Highway")
		addStraight(net, center, Vector3.new(300, 0, 0), "Highway")
		addStraight(net, center, Vector3.new(-260, 0, 80), "Highway") -- 163 deg back-turn

		local graph = RoadNavigationGraph.new()
		graph:Rebuild(net, {})
		-- Eastbound may only carry straight on; swinging back west is a U-turn whatever
		-- segment it lands on, and perms.uturn is false by default.
		expectOutgoing(graph, `S{west.id}:L1:F`, { "S2:L1:F" })

		local permitted = RoadNavigationGraph.new()
		permitted:Rebuild(net, {
			[west.endNode] = { left = true, right = true, straight = true, uturn = true },
		})
		expectOutgoing(permitted, `S{west.id}:L1:F`, { "S1:L2:R", "S2:L1:F", "S3:L1:F" })
	end)

	describe("traffic-aware routing", function()
		it("chooses a clear parallel branch when the original route is congested", function()
			local net = RoadNetwork.new()
			addStraight(net, Vector3.new(-120, 0, 0), Vector3.new(0, 0, 0), "OneWay")
			addStraight(net, Vector3.new(0, 0, 0), Vector3.new(100, 0, 55), "OneWay")
			addStraight(net, Vector3.new(100, 0, 55), Vector3.new(200, 0, 0), "OneWay")
			addStraight(net, Vector3.new(0, 0, 0), Vector3.new(100, 0, -55), "OneWay")
			addStraight(net, Vector3.new(100, 0, -55), Vector3.new(200, 0, 0), "OneWay")
			addStraight(net, Vector3.new(200, 0, 0), Vector3.new(320, 0, 0), "OneWay")

			local graph = RoadNavigationGraph.new()
			graph:Rebuild(net, {})
			local startPos = Vector3.new(-90, 0, 0)
			local goalPos = Vector3.new(290, 0, 0)
			local _, original = graph:FindPath(startPos, goalPos)
			expect(original ~= nil).to.equal(true)
			assert(original)

			local pressure: { [string]: number } = { [original[2]] = 1 }
			graph:SetCongestionSnapshot(pressure)

			local _, diverted = graph:FindPath(startPos, goalPos)
			expect(diverted ~= nil).to.equal(true)
			assert(diverted)
			expect(table.concat(diverted, ",") ~= table.concat(original, ",")).to.equal(true)
			expect(graph:EstimatePathCost(diverted) < graph:EstimatePathCost(original)).to.equal(true)
		end)
	end)
	-- An arrival from outside the map has to start on a lane that DRIVES IN. The lanes
	-- leaving the map-edge node are exactly those; the outbound lanes arrive at it and
	-- dead-end there (an outside connection is never a U-turn point).
	describe("GetOutgoingEdgesFromNode", function()
		it("returns a map-edge node's inbound lanes, innermost first, and no dead-end lane", function()
			local net = RoadNetwork.new()
			local half = require(script.Parent.Parent.RoadConstants).MAP_HALF_EXTENT
			local edgePos = Vector3.new(half - 16, 0, 0)
			addStraight(net, Vector3.new(half - 600, 0, 0), Vector3.new(half - 200, 0, 0), "CollectorRoad")
			local last = addStraight(net, Vector3.new(half - 200, 0, 0), edgePos, "CollectorRoad")

			local graph = RoadNavigationGraph.new()
			graph:Rebuild(net, {})
			local edgeNodeId = if last.endNode and net:getNodes()[last.endNode]
				and (net:getNodes()[last.endNode].position - edgePos).Magnitude < 1
				then last.endNode else last.startNode

			local lanes = graph:GetOutgoingEdgesFromNode(edgeNodeId)
			expect(#lanes).to.equal(2)
			expect(lanes[1].laneOrdinal < lanes[2].laneOrdinal).to.equal(true)
			for _, lane in lanes do
				expect(lane.fromNode).to.equal(edgeNodeId)
				expect(#lane.out > 0).to.equal(true)
			end
		end)
	end)
	-- An incremental rebuild must not strand a lane two nodes out. RebuildSegments used to
	-- clear the out-links of every edge LEAVING an affected node -- links owned by the node
	-- one hop further along, which the relink pass never visits -- so cars reaching that
	-- lane found no exit and U-turned in the middle of the road.
	describe("RebuildSegments", function()
		it("keeps exits on lanes two nodes away from the dirty segment", function()
			local net = RoadNetwork.new()
			local a = addStraight(net, Vector3.new(0, 0, 0), Vector3.new(0, 0, 200), "CollectorRoad")
			addStraight(net, Vector3.new(0, 0, 200), Vector3.new(0, 0, 400), "CollectorRoad")
			addStraight(net, Vector3.new(0, 0, 400), Vector3.new(0, 0, 600), "CollectorRoad")
			addStraight(net, Vector3.new(0, 0, 600), Vector3.new(0, 0, 800), "CollectorRoad")

			local graph = RoadNavigationGraph.new()
			graph:Rebuild(net, {})
			local before: { [string]: number } = {}
			for _, edge in graph:GetEdges() do
				before[edge.id] = #edge.out
			end

			graph:RebuildSegments(net, { [a.id] = true }, nil, {})

			local stranded = 0
			for _, edge in graph:GetEdges() do
				if (before[edge.id] or 0) > 0 and #edge.out == 0 then
					stranded += 1
				end
			end
			expect(stranded).to.equal(0)
		end)
	end)
end
