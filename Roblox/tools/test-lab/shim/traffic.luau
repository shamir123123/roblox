-- Headless traffic lab: the real RoadNetwork / RoadNavigationGraph / NPCDriverService /
-- PathFollower under the Studio stand-in, with test-only access to driver state.
local World = {}
World.__index = World

function World.new(mode: string, opts: any?)
	opts = opts or {}
	local Studio = require("./setup")(mode)
	Studio.expose("ServerScriptService.Services.NPC.NPCDriverService",
		"NPCDriverService.__test = { queueLeader = getNearestQueueLeader, drivers = _drivers, edgeIndex = _edgeDriverIndex, laneChangeIndex = _laneChangeIndex, connIndex = _connectorByNextEdgeIndex, connFromIndex = _connectorByFromEdgeIndex, landIndex = _connByLandingNode, leaveIndex = _connByLeavingNode, owesCourtesy = owesCourtesy, claimant = junctionClaimant, canEnter = canEnterIntersection, exitLaneHasRoom = exitLaneHasRoom, distToStopLine = distToStopLine, boxHasConflict = boxHasConflict, ringOf = ringOf, ringHasRoom = ringHasRoom }")
	Studio.expose("ServerScriptService.Services.Util.PathFollower",
		"PathFollower.__test = { registry = _carRegistry, spatial = _spatial, poseOf = _poseOf, movedAt = _movedAt, npcIds = _npcIds, modelOfId = _modelOfId, lastSentTo = _lastSentTo, inRange = _inRange, prox = _proximityAccum, carHalf = _carHalf }")
	local self = setmetatable({}, World)
	-- opts.fnprof = { module paths }: per-function timing (shim/fnprof), attached by build().
	if opts.fnprof then self.FP = require("./fnprof")(Studio, opts.fnprof) end
	self.Studio = Studio
	self.V = Studio.Vector3
	self.CF = Studio.CFrame
	local R = function(p) return Studio.require(Studio.find(p)) end
	self.RoadNetwork = R("ReplicatedStorage.Road.RoadNetwork")
	self.RoadNavigationGraph = R("ReplicatedStorage.Road.RoadNavigationGraph")
	self.RoadConstants = R("ReplicatedStorage.Road.RoadConstants")
	self.PathFollower = R("ServerScriptService.Services.Util.PathFollower")
	self.Drivers = R("ServerScriptService.Services.NPC.NPCDriverService")
	self.Signals = R("ServerScriptService.Services.Traffic.TrafficSignalService")
	self.net = self.RoadNetwork.new()
	self.graph = self.RoadNavigationGraph.new()
	self.cars = {}
	self.folder = Studio.Instance.new("Folder", Studio.game.Workspace)
	self.folder.Name = "Cars"
	Studio.game.Workspace:SetAttribute("RandomTrafficEnabled", false)
	Studio.game.Workspace:SetAttribute("GameSpeed", 1)
	local topo = {}
	self.roadService = {
		getNavigationGraph = function() return self.graph end,
		getNetwork = function() return self.net end,
		onTopologyChanged = function(fn) table.insert(topo, fn) return function() end end,
	}
	self._topo = topo
	return self
end

function World:road(a: Vector3, b: Vector3, roadType: string)
	local d = b - a
	return self.net:addSegment(a, a + d / 3, a + d * 2 / 3, b, roadType)
end

function World:build(signals: boolean?)
	self.graph:Rebuild(self.net, {})
	self.Drivers.Init(self.roadService)
	self.Drivers.Bind()
	if signals then
		self.Signals.Init(self.roadService)
		self.Signals.Bind()
		self.Signals.Start()
		if self.Signals.SetQueueProvider then self.Signals.SetQueueProvider(self.Drivers.GetSignalQueue) end
		for _, fn in self._topo do fn() end
	end
	self.Drivers.Start()
	self.Studio.step(0.05)
	if self.FP then self.FP.attach() end
end

-- A player whose camera hovers over `pos` (keeps nearby cars on the full-rate AI tier).
function World:camera(pos: Vector3?)
	if not self.player then self.player = self.Studio.addPlayer("Tester", 1) end
	if pos then self.PathFollower.setCameraPos(self.player, pos + self.V.new(0, 150, 0), pos) end
end

local carSeq = 0
function World:makeCar(length: number?, width: number?)
	carSeq += 1
	local Studio = self.Studio
	local m = Studio.Instance.new("Model")
	m.Name = "Car" .. carSeq
	local root = Studio.Instance.new("Part")
	root.Name = "Hitbox"
	root.Size = self.V.new(width or 3.8, 3, length or 9)
	root.Parent = m
	m.PrimaryPart = root
	m:SetAttribute("NPCHeightOffset", 1.5)
	m.Parent = self.folder
	return m
end

-- Route a car from `from` to `to` on the lane graph and hand it to the traffic AI.
function World:drive(from: Vector3, to: Vector3, opts: any?)
	opts = opts or {}
	local m = self:makeCar(opts.length, opts.width)
	local ok, path, edgeIds = pcall(function() return self.graph:FindPath(from, to, nil, "Car", nil) end)
	if not ok or not path or not edgeIds or #edgeIds == 0 then m:Destroy() return nil end
	local rec = { model = m, from = from, to = to, route = edgeIds, spawnedAt = self.Studio.clock.now,
		arrived = false, aborted = false, laneChanges = 0, lcMinRatio = math.huge, lcCount = 0 }
	m:PivotTo(self.CF.new(from))
	local started = self.Drivers.DriveDirected(m, from, to, edgeIds,
		function() rec.arrived = true; rec.arrivedAt = self.Studio.clock.now end,
		function() rec.aborted = true end)
	if not started then m:Destroy() return nil end
	table.insert(self.cars, rec)
	return rec
end

function World:state(m) return self.Drivers.__test.drivers[m] end

function World:step(dt: number) self.Studio.step(dt) end

return World
