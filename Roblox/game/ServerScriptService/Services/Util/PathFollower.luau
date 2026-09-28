--!strict

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local RoadConstants = require(game:GetService("ReplicatedStorage").Road.RoadConstants)
local Networker = require(game:GetService("ReplicatedStorage").Networker)
-- Half-size world: spacing/gap distances scale with the roads and vehicles.
local WS = RoadConstants.WORLD_SCALE

local PathFollower = {}

local REPLICATE_HZ       = 12   -- ~halves car bandwidth vs 20. The anchored root SNAPS (no engine interpolation); the client smooths between these updates -- see Core.NPCDriverView.
local REPLICATE_DT       = 1 / REPLICATE_HZ
local MOVE_THRESHOLD     = 0.1
local ROT_THRESHOLD      = 0.002
local ROT_SMOOTH         = 12
local REPLICATE_RANGE    = 200
local REPLICATE_RANGE_SQ = REPLICATE_RANGE * REPLICATE_RANGE
local PROXIMITY_CHECK_DT = 0.2
local PLAYER_POS_CACHE_DT = 0.1
-- No distance tiering: EVERY car replicates at REPLICATE_HZ and rides the pose
-- stream. The old 2 Hz far keepalive was cheap but the 0.5 s steps were visible
-- well past the 200-stud range, and no amount of client interpolation hides a
-- pose that far behind. REPLICATE_HZ is the one knob if bandwidth ever bites.

-- Spacing is BUMPER-to-bumper: getClearAhead subtracts each vehicle's half-length
-- (cached from its bounding box) from the centre-to-centre distance, so a long
-- truck and a short hatchback both keep a real gap behind whatever is ahead. A
-- single centre-to-centre constant can't do that -- 16 studs centre-to-centre is
-- two 16-stud vans touching. MIN_GAP / BRAKE_GAP are desired BUMPER gaps; SCAN_DIST
-- is the centre-distance window we bother scanning.
local SCAN_DIST       = 46 * WS
local SPATIAL_CELL_SIZE = SCAN_DIST
local BRAKE_GAP       = 20 * WS   -- bumper gap (studs) at which a car eases off the throttle
local MIN_GAP         = 4 * WS    -- bumper gap (studs) a car holds behind the one ahead
local LANE_HALF_WIDTH = 2.5 * WS
local HEADING_DOT     = 0.3   -- beyond CLOSE_DIST, only cars heading roughly the same way count as 'ahead' (cos ~72 deg)
local CLOSE_DIST      = 16 * WS   -- within this range, avoid ANY car ahead regardless of heading (imminent-collision guard)
local DEFAULT_HALF    = 5 * WS    -- fallback half-length until a car's bbox is measured

PathFollower.PROXIMITY_CHECK_DT = PROXIMITY_CHECK_DT

export type FollowerState = {
	model:          Model,
	heightOffset:   number,
	smoothCFrame:   CFrame?,
	lastSentCFrame: CFrame?,
	replicateAccum: number,
}

type CarEntry = {
	pos: Vector3,
	dir: Vector3,
	half: number,
	cellX: number,
	cellZ: number,
}
type Bucket = { [Model]: boolean }
type Column = { [number]: Bucket }

-- Weak keys keep destroyed cars collectible. The 2D buckets make clearance checks
-- inspect nearby cells instead of every car in the city.
local _proximityAccum: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any
local _inRange: { [Model]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local _carRegistry: { [Model]: CarEntry } = setmetatable({}, { __mode = "k" }) :: any
local _carHalf: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any
local _spatial: { [number]: Column } = {}
-- Keepalive: a model only streams when it moves, so one that stopped while a viewer was out of
-- range never told them where it stopped -- they kept drawing it at the last pose they got,
-- often on top of the queue it had since joined, until it moved again and jumped. The latest
-- pose of every streamed model is kept here and re-offered every KEEPALIVE_DT once it stops;
-- flushStream sends it only to viewers who have had nothing from it since it last moved.
local KEEPALIVE_DT = 0.5
-- ...and re-sent to every viewer in range this often regardless: with StreamingEnabled a
-- viewer's copy of the model can arrive AFTER its pose did, and the pose is dropped with it.
local KEEPALIVE_REFRESH = 5
-- stream id -> model, so the per-viewer send stamps of vehicles that are gone can be pruned
-- while a live one's stamp stays (its farewell pose keys on it).
local _modelOfId: { [number]: Model } = {}
local _poseOf: { [Model]: CFrame } = setmetatable({}, { __mode = "k" }) :: any
local _movedAt: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any
local _streamKeep: { boolean } = {}
local _nextKeepalive = 0
-- A car that stops between two of a far viewer's poses was drawn where that viewer last saw
-- it -- up to a braking distance short of where it stopped -- until the keepalive came round,
-- while the car queuing behind it arrived on its next pose: the pair drew one inside the
-- other. Its resting pose now goes out as soon as it has been still for a step or so.
-- model -> os.clock after which, still unmoved, it counts as at rest.
local _restDue: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any
local REST_STEPS = 1.5 -- sim steps of no movement that mean "stopped" (one step can be a hold at a line)

local _cameraPos: { [Player]: Vector3 } = {}
-- Where each player's camera looks at the ground. A city camera hangs high and tilted, so the
-- street on screen can be hundreds of studs from the camera itself: "near a player" has to
-- mean near either point.
local _cameraFocus: { [Player]: Vector3 } = {}
-- player -> vehicle stream id -> when it was last sent to them (see flushStream)
local _lastSentTo: { [Player]: { [number]: number } } = {}
local _playerPositions: { Vector3 } = {}
local _playerPositionsAt = -math.huge

local function bucketAt(cellX: number, cellZ: number): Bucket
	local column = _spatial[cellX]
	if not column then
		column = {}
		_spatial[cellX] = column
	end
	local bucket = column[cellZ]
	if not bucket then
		bucket = setmetatable({}, { __mode = "k" }) :: any
		column[cellZ] = bucket
	end
	return bucket
end

local function removeFromSpatial(model: Model, entry: CarEntry)
	local column = _spatial[entry.cellX]
	if not column then return end
	local bucket = column[entry.cellZ]
	if not bucket then return end
	bucket[model] = nil
	if next(bucket) == nil then
		column[entry.cellZ] = nil
		if next(column) == nil then _spatial[entry.cellX] = nil end
	end
end

function PathFollower.setCameraPos(player: Player, pos: Vector3, focus: Vector3?)
	_cameraPos[player] = pos
	_cameraFocus[player] = focus
end

function PathFollower.clearPlayer(player: Player)
	_cameraPos[player] = nil
	_cameraFocus[player] = nil
	_lastSentTo[player] = nil
	_playerPositionsAt = -math.huge
end

function PathFollower.forget(model: Model)
	_proximityAccum[model] = nil
	_inRange[model] = nil
	local entry = _carRegistry[model]
	if entry then removeFromSpatial(model, entry) end
	_carRegistry[model] = nil
	_carHalf[model] = nil
	_poseOf[model] = nil
	_movedAt[model] = nil
	_restDue[model] = nil
end

-- True when at least one player/camera is close enough that this car is being
-- replicated. Lets callers skip attribute writes for off-screen cars.
function PathFollower.isInRange(model: Model): boolean
	return _inRange[model] == true
end

function PathFollower.seedProximity(model: Model, accum: number)
	_proximityAccum[model] = accum
	-- Start as true so the car is visible and moving immediately.
	-- The proximity check will downgrade to false after the first tick
	-- if no player is actually nearby, keeping the culling correct.
	_inRange[model] = true
end

-- Half the longer horizontal extent of a vehicle, cached per model (weak-keyed).
-- Lets spacing be bumper-to-bumper regardless of how long the model is.
local function halfLengthOf(model: Model): number
	local cached = _carHalf[model]
	if cached then return cached end
	local half = DEFAULT_HALF
	local ok, _, size = pcall(model.GetBoundingBox, model)
	if ok and typeof(size) == "Vector3" then
		half = math.max(size.X, size.Z) * 0.5
	end
	_carHalf[model] = half
	return half
end

-- Straight-line distance to the nearest car ahead of `model`, within a narrow
-- lateral band (so we ignore the next lane over) and in front along `dir`.
-- Returns math.huge when nothing is ahead. Unlike the per-edge queue logic in
-- NPCDriverService, this sees EVERY registered car -- cars on other edges, cars
-- mid-turn on a connector, and cross traffic inside an intersection box -- which
-- is exactly the set the queue logic is blind to.
-- Second return: heading dot of the nearest blocker vs our direction (nil when
-- nothing is ahead). Callers use it to tell a genuine queue (same direction,
-- will move) from a crossing/head-on standoff that can never clear by itself.
-- Third return: the blocker itself, so a caller can tell two cars blocking EACH OTHER
-- (a standoff no traffic can clear) from a car held by one that is stuck in the jam.
function PathFollower.getClearAhead(model: Model, pos: Vector3, dir: Vector3): (number, number?, Model?)
	local flatDir = Vector3.new(dir.X, 0, dir.Z)
	if flatDir.Magnitude < 1e-6 then return math.huge, nil, nil end
	flatDir = flatDir.Unit
	local rightX, rightZ = -flatDir.Z, flatDir.X
	local myHalf = halfLengthOf(model)
	local nearestAhead = math.huge          -- centre distance of the closest car ahead
	local nearestGap = math.huge            -- bumper gap to it (centre dist minus both half-lengths)
	local nearestDot: number? = nil
	local nearestCar: Model? = nil
	-- Only the cells the strip ahead can touch (SCAN_DIST long, a lane wide): the whole 3x3
	-- block around the car was scanned before, over twice the candidates for the same answer.
	local sideX, sideZ = math.abs(rightX) * LANE_HALF_WIDTH, math.abs(rightZ) * LANE_HALF_WIDTH
	local tipX, tipZ = pos.X + flatDir.X * SCAN_DIST, pos.Z + flatDir.Z * SCAN_DIST
	local minCellX = math.floor((math.min(pos.X, tipX) - sideX) / SPATIAL_CELL_SIZE)
	local maxCellX = math.floor((math.max(pos.X, tipX) + sideX) / SPATIAL_CELL_SIZE)
	local minCellZ = math.floor((math.min(pos.Z, tipZ) - sideZ) / SPATIAL_CELL_SIZE)
	local maxCellZ = math.floor((math.max(pos.Z, tipZ) + sideZ) / SPATIAL_CELL_SIZE)
	for cellX = minCellX, maxCellX do
		local column = _spatial[cellX]
		if not column then continue end
		for cellZ = minCellZ, maxCellZ do
			local bucket = column[cellZ]
			if not bucket then continue end
			for other in bucket do
				local entry = _carRegistry[other]
				if not entry or other == model then continue end
				local dx = entry.pos.X - pos.X
				local dz = entry.pos.Z - pos.Z
				local ahead = dx * flatDir.X + dz * flatDir.Z
				if ahead < 0.5 or ahead >= nearestAhead or ahead > SCAN_DIST then continue end
				if math.abs(dx * rightX + dz * rightZ) > LANE_HALF_WIDTH then continue end
				-- Beyond the imminent-collision radius, only same-direction cars count.
				local sameDir = entry.dir.X * flatDir.X + entry.dir.Z * flatDir.Z
				if ahead > CLOSE_DIST and sameDir < HEADING_DOT then continue end
				-- Last, the engine read: only for a car that would otherwise count.
				if not other.Parent then continue end
				nearestAhead = ahead
				nearestGap = ahead - myHalf - entry.half
				nearestDot = sameDir
				nearestCar = other
			end
		end
	end
	return nearestGap, nearestDot, nearestCar
end

-- 0..1 throttle factor based on the gap to the car ahead. Kept for callers that
-- only want to feather speed (CitizenService); NPCDriverService additionally uses
-- getForwardClearance as a hard travel clamp so cars can never overlap.
-- Second return: the car ahead, when it is close enough to slow us.
function PathFollower.getSpeedFactor(model: Model, pos: Vector3, dir: Vector3): (number, Model?)
	local gap, _, blocker = PathFollower.getClearAhead(model, pos, dir)
	if gap >= BRAKE_GAP then return 1, nil end
	if gap <= MIN_GAP then return 0, blocker end
	return (gap - MIN_GAP) / (BRAKE_GAP - MIN_GAP), blocker
end

-- How far `model` may advance this frame before it would close to MIN_GAP behind
-- the next car ahead. math.huge means unobstructed. Use as a hard clamp on
-- frame travel to guarantee no clipping, on edges AND connectors alike.
function PathFollower.getForwardClearance(model: Model, pos: Vector3, dir: Vector3): (number, number?)
	local gap, blockerDot = PathFollower.getClearAhead(model, pos, dir)
	if gap == math.huge then return math.huge, nil end
	return math.max(0, gap - MIN_GAP), blockerDot
end

-- NPCDriverService needs both values every tick. Compute the neighbor search once
-- instead of scanning the same nearby buckets twice.
function PathFollower.getMotionLimits(model: Model, pos: Vector3, dir: Vector3): (number, number, number?, Model?)
	local gap, blockerDot, blocker = PathFollower.getClearAhead(model, pos, dir)
	if gap == math.huge then return 1, math.huge, nil, nil end
	local speedFactor = if gap >= BRAKE_GAP then 1
		elseif gap <= MIN_GAP then 0
		else (gap - MIN_GAP) / (BRAKE_GAP - MIN_GAP)
	return speedFactor, math.max(0, gap - MIN_GAP), blockerDot, blocker
end

local function getPlayerPositions(): { Vector3 }
	local now = os.clock()
	if now - _playerPositionsAt < PLAYER_POS_CACHE_DT then return _playerPositions end
	_playerPositionsAt = now
	table.clear(_playerPositions)
	for _, player in Players:GetPlayers() do
		local char = player.Character
		local root = if char then char:FindFirstChild("HumanoidRootPart") :: BasePart? else nil
		if root then table.insert(_playerPositions, root.Position) end
		local camPos = _cameraPos[player]
		if camPos then table.insert(_playerPositions, camPos) end
		local focus = _cameraFocus[player]
		if focus then table.insert(_playerPositions, focus) end
	end
	return _playerPositions
end

local function anyPlayerInRange(pos: Vector3): boolean
	for _, playerPos in getPlayerPositions() do
		local dx = playerPos.X - pos.X
		local dz = playerPos.Z - pos.Z
		if dx * dx + dz * dz <= REPLICATE_RANGE_SQ then return true end
	end
	return false
end

-- Exposed for systems that follow the same culling rules but don't own a
-- FollowerState (e.g. NPC walkers).
function PathFollower.anyPlayerNear(pos: Vector3): boolean
	return anyPlayerInRange(pos)
end

-- Squared XZ distance to the nearest player character or reported camera, or math.huge if
-- nobody is in the world. anyPlayerNear answers only the fixed REPLICATE_RANGE question;
-- simulation-LOD callers need their own promote/demote bands, and this lets them reuse the
-- same cached position list instead of gathering players themselves.
function PathFollower.nearestPlayerDistSq(pos: Vector3): number
	local best = math.huge
	for _, playerPos in getPlayerPositions() do
		local dx = playerPos.X - pos.X
		local dz = playerPos.Z - pos.Z
		local d = dx * dx + dz * dz
		if d < best then best = d end
	end
	return best
end

-- True when a registered car is within `radius` of `pos` and is on top of it
-- or moving toward it. Walkers use this as a kerb check before zebra crossings.
function PathFollower.anyCarApproaching(pos: Vector3, radius: number): boolean
	local rSq = radius * radius
	local minCellX = math.floor((pos.X - radius) / SPATIAL_CELL_SIZE)
	local maxCellX = math.floor((pos.X + radius) / SPATIAL_CELL_SIZE)
	local minCellZ = math.floor((pos.Z - radius) / SPATIAL_CELL_SIZE)
	local maxCellZ = math.floor((pos.Z + radius) / SPATIAL_CELL_SIZE)
	for cellX = minCellX, maxCellX do
		local column = _spatial[cellX]
		if not column then continue end
		for cellZ = minCellZ, maxCellZ do
			local bucket = column[cellZ]
			if not bucket then continue end
			for model in bucket do
				local entry = _carRegistry[model]
				if not entry or not model.Parent then continue end
				local dx = pos.X - entry.pos.X
				local dz = pos.Z - entry.pos.Z
				local dSq = dx * dx + dz * dz
				if dSq <= rSq then
					if dSq < 25 then return true end
					if (dx * entry.dir.X + dz * entry.dir.Z) / math.sqrt(dSq) > 0.4 then
						return true
					end
				end
			end
		end
	end
	return false
end

function PathFollower.isRegistered(model: Model): boolean
	return _carRegistry[model] ~= nil
end

-- True when a registered vehicle that `accept` agrees to stands within `radius` of `pos`.
function PathFollower.anyVehicleWithin(pos: Vector3, radius: number, accept: (Model) -> boolean): boolean
	local rSq = radius * radius
	local minCellX = math.floor((pos.X - radius) / SPATIAL_CELL_SIZE)
	local maxCellX = math.floor((pos.X + radius) / SPATIAL_CELL_SIZE)
	local minCellZ = math.floor((pos.Z - radius) / SPATIAL_CELL_SIZE)
	local maxCellZ = math.floor((pos.Z + radius) / SPATIAL_CELL_SIZE)
	for cellX = minCellX, maxCellX do
		local column = _spatial[cellX]
		if not column then continue end
		for cellZ = minCellZ, maxCellZ do
			local bucket = column[cellZ]
			if not bucket then continue end
			for model in bucket do
				local entry = _carRegistry[model]
				if not entry or not model.Parent then continue end
				local dx, dz = entry.pos.X - pos.X, entry.pos.Z - pos.Z
				if dx * dx + dz * dz < rSq and accept(model) then return true end
			end
		end
	end
	return false
end

-- ── NPC pose stream ───────────────────────────────────────────────────────────
-- NPC motion leaves the server as ONE batched unreliable packet per frame instead
-- of per-model CFrame property writes: no replication-engine bookkeeping per part,
-- ~19 bytes per pose on the wire, and nothing for an exploiter to abuse (the stream
-- is server->client only). Property CFrames still carry each model's spawn pose, so
-- late joiners see a sane layout until the stream catches up (views snap on the
-- first packet).
-- A pose only helps if a client view is listening for that model, so streaming is
-- gated on the tags the two views watch. Anything else (emergency vehicles, whose
-- factory adds only a vehicle-class tag) keeps direct CFrame writes -- otherwise its
-- motion would go to a stream nobody decodes and the model would sit frozen.
-- Packet layout must match NPCDriverView / PedestrianView: f64 timestamp, then
-- entries of (id u32, x f32, y f32, z f32, yaw u16, pitch i8).
local STREAM_HEADER = 8
local STREAM_ENTRY = 19
local MAX_PER_PACKET = 45 -- unreliable remotes cap near 900 bytes per fire

local STREAMED_TAGS = { "NPCDriver", "NPCWalker" }
local _streamable: { [Model]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- Only the positive is cached: a car is placed once before its spawn code tags it, and
-- caching that miss would pin it to property writes for its whole life.
local function isStreamed(model: Model): boolean
	if _streamable[model] then return true end
	for _, tag in STREAMED_TAGS do
		if CollectionService:HasTag(model, tag) then
			_streamable[model] = true
			return true
		end
	end
	return false
end

local _npcIds: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any
local _nextNpcId = 0
local _streamModels: { Model } = {}
local _streamPoses: { CFrame } = {}
local _flushScheduled = false

-- == Per-player pose budget ====================================================
-- Every vehicle and walker used to go to every player 12 times a second -- about 1 MB/s at a
-- few thousand vehicles. Each player now gets what their own view needs, by distance to
-- their camera or its ground look-at point:
--   <= FULL_RATE_DIST     every pose (12 Hz)            the street you are looking at
--   <= FULL_DETAIL_DIST   4 Hz, every vehicle (500 m)   the neighbourhood around it
--   <= FAR_DIST           2 Hz, 1 in 2, then 1 in 4     the skyline: a sample, never all
-- NPCDriverView draws the same sample (the same id modulus), so what is not sent is not drawn.
local FULL_RATE_DIST   = 300
PathFollower.FULL_RATE_DIST = FULL_RATE_DIST -- viewers get every pose only this close
local FULL_DETAIL_DIST = 1000
local MID_SAMPLE_DIST  = 2000
local FAR_DIST         = 4000
local PRUNE_EVERY      = 30 -- s between sweeps of the send stamps of vehicles that are gone

local _nextPrune = 0

local function playerRefs(player: Player, out: { Vector3 })
	table.clear(out)
	local char = player.Character
	local root = if char then char:FindFirstChild("HumanoidRootPart") :: BasePart? else nil
	if root then table.insert(out, root.Position) end
	if _cameraPos[player] then table.insert(out, _cameraPos[player]) end
	if _cameraFocus[player] then table.insert(out, _cameraFocus[player]) end
end

-- A vehicle further than every viewer's stream reach (FAR_DIST, plus slack for cameras on
-- the move) is not queued for the stream at all: flushStream used to walk every moving car
-- in the city for every player, 12 times a second, only to send most of them nothing. One
-- still owed a farewell by a viewer who has it keeps being queued until that goes out. The
-- verdict is re-taken every STREAM_SKIP_RECHECK per car.
local STREAM_REACH = FAR_DIST + 300
PathFollower.STREAM_REACH = STREAM_REACH -- past this from every viewer, a vehicle is seen by nobody
local STREAM_SKIP_DIST_SQ = STREAM_REACH ^ 2
local STREAM_SKIP_RECHECK = 0.3
local _streamSkipUntil: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any
local function streamRelevant(model: Model, pos: Vector3): boolean
	local now = os.clock()
	local skipUntil = _streamSkipUntil[model]
	if skipUntil and now < skipUntil then return false end
	if PathFollower.nearestPlayerDistSq(pos) <= STREAM_SKIP_DIST_SQ then
		_streamSkipUntil[model] = nil
		return true
	end
	local id = _npcIds[model]
	if id then
		for _, sent in _lastSentTo do
			if sent[id] then return true end
		end
	end
	_streamSkipUntil[model] = now + STREAM_SKIP_RECHECK
	return false
end

-- Seconds between poses of vehicle `id` for a viewer `d2` (squared studs) away; nil = none.
local function poseInterval(id: number, d2: number): number?
	if d2 <= FULL_RATE_DIST * FULL_RATE_DIST then return 0 end
	if d2 <= FULL_DETAIL_DIST * FULL_DETAIL_DIST then return 1 / 4 end
	if d2 > FAR_DIST * FAR_DIST then return nil end
	local every = if d2 <= MID_SAMPLE_DIST * MID_SAMPLE_DIST then 2 else 4
	if id % every ~= 0 then return nil end
	return 1 / 2
end

local _refs: { Vector3 } = {}
local _picks: { number } = {}
-- Parallel to _picks: true for a vehicle's LAST pose to this viewer before it leaves their
-- stream. Sent as pitch FAREWELL_PITCH (real pitches are clamped to +/-89), so the client
-- hides exactly the vehicles the server stopped sending instead of guessing from its own
-- camera -- whose idea of "past 1000 studs" drifted from the server's (the camera report is
-- coarse), and a car the client still drew but the server no longer sent sat frozen while
-- the traffic behind it drove straight through it.
local _pickFarewell: { boolean } = {}
local FAREWELL_PITCH = -128
PathFollower.FAREWELL_PITCH = FAREWELL_PITCH

local function sendPicks(player: Player, stamp: number)
	local total = #_picks
	local i = 1
	while i <= total do
		local count = math.min(MAX_PER_PACKET, total - i + 1)
		local buf = buffer.create(STREAM_HEADER + count * STREAM_ENTRY)
		buffer.writef64(buf, 0, stamp)
		local off = STREAM_HEADER
		for k = i, i + count - 1 do
			local j = _picks[k]
			local cf = _streamPoses[j]
			local pos = cf.Position
			local lv = cf.LookVector
			buffer.writeu32(buf, off, _npcIds[_streamModels[j]] or 0)
			buffer.writef32(buf, off + 4, pos.X)
			buffer.writef32(buf, off + 8, pos.Y)
			buffer.writef32(buf, off + 12, pos.Z)
			local yaw = math.atan2(-lv.X, -lv.Z)
			buffer.writeu16(buf, off + 16, math.floor((yaw + math.pi) / (2 * math.pi) * 65535 + 0.5) % 65536)
			buffer.writei8(buf, off + 18, if _pickFarewell[k] then FAREWELL_PITCH
				else math.clamp(math.floor(math.deg(math.asin(math.clamp(lv.Y, -1, 1))) + 0.5), -89, 89))
			off += STREAM_ENTRY
		end
		Networker.SyncNpcPoses:FireClient(player, buf)
		i += count
	end
end

local function flushStream()
	_flushScheduled = false
	local n = #_streamModels
	if n == 0 then return end
	local stamp = os.clock()
	for _, player in Players:GetPlayers() do
		playerRefs(player, _refs)
		if #_refs == 0 then continue end
		local sent = _lastSentTo[player]
		if not sent then
			sent = {}
			_lastSentTo[player] = sent
		end
		table.clear(_picks)
		table.clear(_pickFarewell)
		for j = 1, n do
			local model = _streamModels[j]
			local id = _npcIds[model] or 0
			local pos = _streamPoses[j].Position
			local d2 = math.huge
			for _, r in _refs do
				local dx, dz = r.X - pos.X, r.Z - pos.Z
				local d = dx * dx + dz * dz
				if d < d2 then d2 = d end
			end
			local interval = poseInterval(id, d2)
			if interval then
				local last = sent[id] or -math.huge
				local due = if _streamKeep[j]
					then last < (_movedAt[model] or 0) or stamp - last >= KEEPALIVE_REFRESH
					else stamp - last >= interval - 1e-3
				if due then
					sent[id] = stamp
					table.insert(_picks, j)
					_pickFarewell[#_picks] = false
				end
			elseif sent[id] then
				-- Leaving this viewer's stream: one last pose, so their copy moves to where the
				-- vehicle really is and their view hides it there. Without it the car froze
				-- where they last saw it, drawn on top of whatever queued there later.
				sent[id] = nil
				table.insert(_picks, j)
				_pickFarewell[#_picks] = true
			end
		end
		if #_picks > 0 then sendPicks(player, stamp) end
	end
	if stamp >= _nextPrune then
		_nextPrune = stamp + PRUNE_EVERY
		for id, model in _modelOfId do
			if not model.Parent then _modelOfId[id] = nil end
		end
		for _, sent in _lastSentTo do
			for id in sent do
				if not _modelOfId[id] then sent[id] = nil end
			end
		end
	end
	table.clear(_streamModels)
	table.clear(_streamPoses)
	table.clear(_streamKeep)
end

-- Queue one pose for the next batched packet. Assigns the model its stream id on
-- first use (replicated once as the NpcId attribute so clients can map id->model).
function PathFollower.streamPose(model: Model, cf: CFrame)
	local id = _npcIds[model]
	if not id then
		-- The attribute is the durable id; the weak map is only a cache. (A weak-keyed
		-- Instance entry can be evicted whenever no script holds the model, so reading
		-- the attribute back prevents ever re-assigning a model a second id.)
		local existing = model:GetAttribute("NpcId")
		if typeof(existing) == "number" then
			id = existing
		else
			_nextNpcId += 1
			id = _nextNpcId
			model:SetAttribute("NpcId", id)
		end
		_npcIds[model] = id
		_modelOfId[id] = model
	end
	table.insert(_streamModels, model)
	table.insert(_streamPoses, cf)
	table.insert(_streamKeep, false)
	_poseOf[model] = cf
	_movedAt[model] = os.clock()
	if not _flushScheduled then
		_flushScheduled = true
		task.defer(flushStream)
	end
end

local function queueKeep(model: Model, cf: CFrame)
	table.insert(_streamModels, model)
	table.insert(_streamPoses, cf)
	table.insert(_streamKeep, true)
	if not _flushScheduled then
		_flushScheduled = true
		task.defer(flushStream)
	end
end

-- Offer the resting pose of every vehicle that has just stopped (see _restDue), and re-offer
-- every stopped streamed model's pose (see KEEPALIVE_DT). Call every server tick; the
-- rest sweep only walks vehicles that moved lately, the full sweep paces itself.
function PathFollower.keepalive()
	local now = os.clock()
	for model, due in _restDue do
		if now < due then continue end
		_restDue[model] = nil
		local cf = _poseOf[model]
		if cf and model.Parent and _npcIds[model] then queueKeep(model, cf) end
	end
	if now < _nextKeepalive then return end
	_nextKeepalive = now + KEEPALIVE_DT
	-- Cheap tests first, the engine read (Parent) last; and nothing for a vehicle no viewer
	-- can see (streamRelevant) -- with thousands of parked and queued cars this sweep was a
	-- burst of its own every KEEPALIVE_DT.
	for model, cf in _poseOf do
		if now - (_movedAt[model] or 0) >= KEEPALIVE_DT and _npcIds[model]
			and streamRelevant(model, cf.Position) and model.Parent then
			queueKeep(model, cf)
		end
	end
end

local _cumCache: { [string]: { number } } = {}

function PathFollower.flushCache()
	table.clear(_cumCache)
end

function PathFollower.getCum(edge: any): { number }
	local c = _cumCache[edge.id]
	if c then return c end

	local pts = edge.points
	local cum: { number } = table.create(#pts, 0)
	cum[1] = 0

	for i = 2, #pts do
		cum[i] = cum[i - 1] + (pts[i] - pts[i - 1]).Magnitude
	end

	_cumCache[edge.id] = cum

	return cum
end

function PathFollower.cumOf(pts: { Vector3 }): { number }
	local cum: { number } = table.create(#pts, 0)
	cum[1] = 0

	for i = 2, #pts do
		cum[i] = cum[i - 1] + (pts[i] - pts[i - 1]).Magnitude
	end

	return cum
end

function PathFollower.pathLen(pts: { Vector3 }): number
	local t = 0

	for i = 2, #pts do
		t += (pts[i] - pts[i - 1]).Magnitude
	end

	return t
end

function PathFollower.pointAtDist(pts: { Vector3 }, cum: { number }, d: number): (Vector3, Vector3)
	if #pts < 2 then
		return (pts[1] or Vector3.zero), Vector3.zAxis
	end

	local total = cum[#cum]
	d = math.clamp(d, 0, total)

	-- Binary search: lane edges carry curvature-refined point lists, so a linear
	-- scan would pay per-frame cost proportional to point count.
	local lo, hi = 1, #pts
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if cum[mid] >= d then hi = mid else lo = mid end
	end

	local span  = cum[hi] - cum[lo]
	local alpha = if span > 1e-6 then (d - cum[lo]) / span else 0
	local pos   = pts[lo]:Lerp(pts[hi], alpha)
	local dir   = pts[hi] - pts[lo]

	return pos, if dir.Magnitude > 1e-6 then dir.Unit else Vector3.zAxis
end

function PathFollower.place(state: FollowerState, pos: Vector3, dir: Vector3, dt: number?)
	local model = state.model
	if not model.Parent then return end

	-- Keep the full 3D direction so cars pitch with the road slope. World Y stays
	-- as the Up reference so banked turns don't introduce roll.
	local travel = dir
	if travel.Magnitude < 1e-6 then
		travel = Vector3.zAxis
	else
		travel = travel.Unit
	end

	local lifted = pos + Vector3.new(0, state.heightOffset, 0)
	local targetCF = CFrame.lookAt(lifted, lifted + travel, Vector3.yAxis)
	local prev = state.smoothCFrame
	if prev and (prev.Position - lifted).Magnitude > 1e-3 and isStreamed(model) then
		_restDue[model] = os.clock() + REST_STEPS * math.max(dt or 0, 1 / 20)
	end

	local finalCF: CFrame

	-- A near-reversal in one frame is always a teleport (re-anchor after a road
	-- edit, connector hand-off), never smooth driving -- snap instead of lerp.
	-- Slerping through ~180 deg picks an arbitrary rotation axis and could pitch
	-- the car nose-up through the flip, leaving it visibly tipped.
	if state.smoothCFrame and dt and dt > 0
		and state.smoothCFrame.LookVector:Dot(targetCF.LookVector) > -0.1 then
		local alpha = math.min(1, ROT_SMOOTH * dt)
		local newRot = state.smoothCFrame:Lerp(targetCF, alpha)

		finalCF = CFrame.new(lifted) * CFrame.new(Vector3.zero, newRot.LookVector)
		state.smoothCFrame = finalCF
	else
		finalCF = targetCF
		state.smoothCFrame = finalCF
	end

	local position = finalCF.Position
	local cellX = math.floor(position.X / SPATIAL_CELL_SIZE)
	local cellZ = math.floor(position.Z / SPATIAL_CELL_SIZE)
	local entry = _carRegistry[model]
	if entry then
		if entry.cellX ~= cellX or entry.cellZ ~= cellZ then
			removeFromSpatial(model, entry)
			bucketAt(cellX, cellZ)[model] = true
			entry.cellX, entry.cellZ = cellX, cellZ
		end
		entry.pos, entry.dir = position, finalCF.LookVector
	else
		entry = {
			pos = position,
			dir = finalCF.LookVector,
			half = halfLengthOf(model),
			cellX = cellX,
			cellZ = cellZ,
		}
		_carRegistry[model] = entry
		bucketAt(cellX, cellZ)[model] = true
	end
	if isStreamed(model) then _poseOf[model] = finalCF end

	state.replicateAccum = (state.replicateAccum or 0) + (dt or 0)

	local proxAccum = _proximityAccum[model] or 0
	proxAccum += (dt or 0)

	if proxAccum >= PROXIMITY_CHECK_DT then
		proxAccum -= PROXIMITY_CHECK_DT
		_inRange[model] = anyPlayerInRange(finalCF.Position)
	end

	_proximityAccum[model] = proxAccum

	if state.replicateAccum < REPLICATE_DT then return end

	state.replicateAccum -= REPLICATE_DT

	local last = state.lastSentCFrame

	if last then
		local posDiff = (finalCF.Position - last.Position).Magnitude
		local dotDiff = 1 - math.abs(finalCF.LookVector:Dot(last.LookVector))

		if posDiff < MOVE_THRESHOLD and dotDiff < ROT_THRESHOLD then
			return
		end
	end

	state.lastSentCFrame = finalCF
	-- Every car rides the batched pose stream (~19 bytes/pose) -- the server writes no
	-- instance CFrames, the client views move the models. A late joiner sees the model's
	-- replicated spawn pose for the one stream interval before the first packet lands.
	local root = model.PrimaryPart
	if root and isStreamed(model) then
		if streamRelevant(model, finalCF.Position) then
			PathFollower.streamPose(model, finalCF)
		else
			_movedAt[model] = os.clock() -- _poseOf is already current (above)
		end
	elseif root then
		root.CFrame = finalCF
	else
		model:PivotTo(finalCF)
	end
end

return PathFollower