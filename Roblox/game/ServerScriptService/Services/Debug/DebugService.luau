--!strict

local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local Workspace         = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetMiddleware = require(ReplicatedStorage:WaitForChild("NetMiddleware"))

local DebugService = {}

local BROADCAST_RATE      = 0.5
local TOGGLE_MIN_INTERVAL = 1.0
local NPC_TAG             = "NPCDriver"
local WALKER_TAG          = "NPCWalker"

local _roadService: any   = nil
local _debugRemote: RemoteEvent?  = nil
local _toggleRemote: RemoteEvent? = nil
local _heartbeat: RBXScriptConnection? = nil
local _lastBroadcast = 0
local _enabled = false
local _subscribedPlayers: { [Player]: boolean } = {}

local _cachedSnapshot: any = nil
local _snapshotBuiltAt = -math.huge

local _toggleLastAt: { [Player]: number } = {}

local function canDebug(player: Player): boolean
	return NetMiddleware.GetCachedAttribute(player, "CanDebug") == true
end

local function getNavGraph(): any?
	return _roadService and _roadService.getNavigationGraph()
end

local function collectNPCInfo(): { any }
	local out: { any } = {}
	local seen: { [Instance]: boolean } = {}

	local function addModel(model: Model, kind: string, fallbackStatus: string)
		if seen[model] or not model.Parent then return end
		seen[model] = true

		local pivot = model:GetPivot()
		local status = model:GetAttribute("NPCStatus")
		local destX = model:GetAttribute("NPCDestX")
		local destZ = model:GetAttribute("NPCDestZ")
		local speed = model:GetAttribute("NPCSpeed")
		local debugId = model:GetAttribute("NPCDebugId")

		table.insert(out, {
			id     = if typeof(debugId) == "string" then debugId else model.Name,
			name   = model.Name,
			kind   = kind,
			pos    = {
				x = math.round(pivot.Position.X),
				y = math.round(pivot.Position.Y),
				z = math.round(pivot.Position.Z),
			},
			status = if typeof(status) == "string" then status else fallbackStatus,
			dest   = if destX and destZ then { x = destX, z = destZ } else nil,
			speed  = if typeof(speed) == "number" then speed else 0,
		})
	end

	for _, inst in CollectionService:GetTagged(NPC_TAG) do
		if inst:IsA("Model") then
			addModel(inst, "car", "Driving")
		end
	end

	for _, inst in CollectionService:GetTagged(WALKER_TAG) do
		if inst:IsA("Model") then
			addModel(inst, "walker", "Walking")
		end
	end

	-- Fallback for models that predate the debug tag or are parked between trip legs.
	local city = Workspace:FindFirstChild("_City")
	if city then
		for _, folderName in { "NPCDrivers", "NPCWalkers", "Citizens", "Supply" } do
			local folder = city:FindFirstChild(folderName)
			if folder then
				for _, child in folder:GetChildren() do
					if child:IsA("Model") then
						local isWalker = CollectionService:HasTag(child, WALKER_TAG) or folderName == "NPCWalkers"
						addModel(child, if isWalker then "walker" else "car", if isWalker then "Walking" else "Parked/Driving")
					end
				end
			end
		end
	end

	return out
end

local function collectRoadInfo(): { any }
	local out = {
		nodeCount = 0,
		segCount = 0,
		edgeCount = 0,
		intersections = 0,
		deadEnds = 0,
	}

	if not _roadService then return out end

	local network = _roadService.getNetwork and _roadService.getNetwork()
	if not network then return out end

	local nodes = network:getNodes()
	local segs  = network:getSegments()

	for nodeId, node in nodes do
		out.nodeCount += 1

		local kind = network:getNodeKind(nodeId)

		if kind == "intersection" then
			out.intersections += 1
		end

		if #node.segments == 1 then
			out.deadEnds += 1
		end
	end

	for _ in segs do
		out.segCount += 1
	end

	local nav = getNavGraph()

	if nav and nav.GetEdges then
		local edges = nav:GetEdges()

		if edges then
			for _ in edges do
				out.edgeCount += 1
			end
		end
	end

	return out
end

local function buildSnapshot(): any
	local now = os.clock()

	if _cachedSnapshot and now - _snapshotBuiltAt < BROADCAST_RATE then
		return _cachedSnapshot
	end

	local npcs        = collectNPCInfo()
	local roads       = collectRoadInfo()
	local playerCount = #Players:GetPlayers()

	_cachedSnapshot = {
		t           = now,
		playerCount = playerCount,
		roads       = roads,
		npcs        = npcs,
		npcCount    = #npcs,
	}

	_snapshotBuiltAt = now

	return _cachedSnapshot
end

local function broadcast()
	if not _enabled or not _debugRemote then return end

	local snap = buildSnapshot()

	for player in _subscribedPlayers do
		_debugRemote:FireClient(player, snap)
	end
end

function DebugService.Init(roadService: any, debugRemote: RemoteEvent, toggleRemote: RemoteEvent)
	_roadService  = roadService
	_debugRemote  = debugRemote
	_toggleRemote = toggleRemote
end

function DebugService.Bind()
	if not _toggleRemote then return end

	NetMiddleware.RegisterServerRateLimit(_toggleRemote :: RemoteEvent, TOGGLE_MIN_INTERVAL)

	_toggleRemote.OnServerEvent:Connect(function(player: Player, wantsEnabled: any)
		if not NetMiddleware.CheckServerRate(_toggleRemote :: RemoteEvent, player) then
			return
		end

		local now = os.clock()
		local last = _toggleLastAt[player]

		if last and now - last < TOGGLE_MIN_INTERVAL then
			return
		end

		_toggleLastAt[player] = now

		if not canDebug(player) then
			warn("[DebugService] Unauthorised toggle attempt from", player.Name)
			return
		end

		if wantsEnabled == true then
			_subscribedPlayers[player] = true
			_enabled = true
		else
			_subscribedPlayers[player] = nil

			if next(_subscribedPlayers) == nil then
				_enabled = false
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		if _subscribedPlayers[player] then
			_subscribedPlayers[player] = nil

			if next(_subscribedPlayers) == nil then
				_enabled = false
			end
		end

		_toggleLastAt[player] = nil

		NetMiddleware.OnPlayerRemoving(player)
	end)
end

function DebugService.Start()
	if _heartbeat then
		_heartbeat:Disconnect()
	end

	_lastBroadcast = 0

	_heartbeat = RunService.Heartbeat:Connect(function()
		local t = os.clock()

		if t - _lastBroadcast >= BROADCAST_RATE then
			_lastBroadcast = t
			broadcast()
		end
	end)
end

return DebugService