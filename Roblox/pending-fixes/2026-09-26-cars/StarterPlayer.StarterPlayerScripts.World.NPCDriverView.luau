--!strict

-- Client-side movement for server-simulated NPC cars. The server simulates the
-- traffic (authoritative: signals, queues, arrivals) but no longer writes near
-- cars' instance CFrames -- it streams batched poses over Net.SyncNpcPoses
-- (unreliable buffer packets at ~12 Hz, see PathFollower). This view maps each
-- packet entry to its car via the NpcId attribute and renders the car
-- interpolated between the last two stream poses, one interval behind real time,
-- so the client does ALL model movement. Far cars still arrive as slow property
-- keepalive writes; when the stream goes quiet for a car we fall back to
-- adopting those replicated CFrames. A streamed car that is NOT currently
-- interpolated still gets its pose applied raw -- the server writes no CFrame for
-- it, so anything we drop here is motion the car simply never makes.
-- Purely visual and client-only: there is no client->server path, so nothing here
-- can be exploited. The car's welded body parts ride the root, so moving the root
-- locally moves the whole car.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Lighting          = game:GetService("Lighting")

local OCConstants = require(ReplicatedStorage.City.OutsideConnectionConstants)
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local Settings = require(script.Parent.Parent.Core.Settings)

local NPCDriverView = {}

local TAG = "NPCDriver"

-- Render-behind interpolation. The server sends a new pose ~every REPLICATE interval
-- (12 Hz). We render each car at (clock - INTERP_DELAY), LERPing between the last two
-- received poses, so motion is CONSTANT velocity between updates instead of easing in
-- toward each keyframe and jolting forward at the next (the old exp-ease pulsed: it
-- decelerated approaching every keyframe, then snapped ahead). Because we interpolate
-- between two REAL server poses we never overshoot, turns stay correct (no "car turns
-- from its back"), and it's stable at any FPS -- low FPS just samples the same curve
-- coarsely. Forward extrapolation is deliberately NOT used (it cut corners and went
-- wild at low FPS). Cost: a fixed ~one-interval visual lag, invisible on ambient
-- traffic and the same latency budget the old ease already had.
local INTERP_DELAY = 0.085
local _clock = 0
-- A target farther than this from the rendered pose is a teleport (spawn, re-anchor
-- after a road edit, or pop-in when a car re-enters replication range), not driving --
-- snap to it instead of gliding the car across the map.
local SNAP_DIST = 24
-- ...but a car on the slow far keepalive legitimately covers ground between poses, so the
-- snap threshold scales with the gap since the last pose. A flat 24 made every far update
-- read as a teleport, which is half of why distant traffic moved in chunks.
local SNAP_SPEED = 120 -- studs/s ceiling for "could have driven that"
-- Longest gap we'll ever interpolate across (server far keepalive is 0.5 s). Without the
-- cap, a car that sat still for seconds -- no updates, so a stale prevTime -- would crawl
-- its next small delta out over that whole idle span in slow motion.
local MAX_SPAN = 0.6
local function snapDistFor(gap: number): number
	return math.max(SNAP_DIST, gap * SNAP_SPEED)
end
-- Which cars get render-frame interpolation. Previously a 220-stud horizontal radius, which
-- left everything past it taking the server's 2 Hz far keepalive raw -- visible 0.5 s steps.
-- Now no distance cutoff: EVERY car in front of the camera interpolates. The fleet is capped
-- at 12000 (CitizenService.MAX_CARS_TOTAL); cars behind the camera, and past 500 m all but a
-- sample (sampledOut), are hidden and skipped,
-- so the worst case is a few hundred CFrame writes per frame -- cheaper than the chunking
-- was ugly. Set a finite number here if a bigger fleet ever makes this measurable.
-- ...and now there IS a cutoff, but it hides the car rather than just dropping it to the raw
-- keepalive: past this a car is a couple of pixels of moving colour nobody reads as traffic.
-- Matches where RoadMeshView drops lane paint (~1200 studs), so the road and what is driving
-- on it stop being drawn together instead of leaving cars sliding over blank tarmac.
-- Flat studs, not RoadMeshView's screen-space ladder: the two only line up at 1080p/70 fov,
-- and a fixed traffic radius is the more predictable half of that trade.
-- ...raised to 4000 on 2026-09-23. At 1200 a car was still ~5 px tall and blinked out as the
-- camera moved -- visible flicker. At 4000 it is about a pixel. The fleet is capped at 400,
-- so this is at most a few hundred CFrame writes a frame for cars in front of the camera.
local CULL_DIST = 4000
local RENDER_DIST_SQ = CULL_DIST * CULL_DIST
-- Hysteresis, same idea as the +/-8 forward band below: come back 50 studs inside before
-- showing again, so a camera parked on the boundary cannot flicker the fleet.
local UNCULL_DIST_SQ = (CULL_DIST - 50) * (CULL_DIST - 50)
local CULL_SCAN_FRAMES = 240 -- distant ambience can refresh over several seconds
-- Every vehicle is drawn within FULL_DETAIL_DIST (500 m); past it only a sample, thinning with
-- distance -- the same ids the server streams (PathFollower.poseInterval), so a car the
-- server stopped sending is never left frozen on screen.
local FULL_DETAIL_DIST = 1000
local MID_SAMPLE_DIST = 2000
-- Where the camera looks at the ground, reconstructed the way the server does from the
-- camera report (NPCDriverService.Bind). The server streams by the nearer of the camera and
-- this point; measuring from the camera alone hid half the cars on the very street being
-- looked at whenever a high city camera put it past FULL_DETAIL_DIST.
local function groundFocus(cf: CFrame): Vector3?
	local look = cf.LookVector
	if look.Y >= -0.05 then return nil end
	local pos = cf.Position
	local hit = pos + look * ((RoadConstants.getGroundY() - pos.Y) / look.Y)
	local h = RoadConstants.MAP_HALF_EXTENT
	return Vector3.new(math.clamp(hit.X, -h, h), hit.Y, math.clamp(hit.Z, -h, h))
end
local function sampledOut(model: Model, flatSq: number, margin: number): boolean
	if flatSq <= (FULL_DETAIL_DIST - margin) ^ 2 then return false end
	local id = model:GetAttribute("NpcId")
	if typeof(id) ~= "number" then return true end
	local every = if flatSq <= (MID_SAMPLE_DIST - margin) ^ 2 then 2 else 4
	return id % every ~= 0
end
-- CFrame readback carries tiny float error, so a delta below these counts as our own
-- write, not a fresh server update.
local POS_EPS = 1e-3
local ROT_DOT_EPS = 0.9999

-- Cars fade in/out near outside connections instead of popping: arrivals spawn ~24 studs
-- in (half-faded, and materialise as they drive into the city) and leavers dissolve fully
-- by the server's 12-stud despawn point. Purely distance-based, so it needs no server
-- signal and covers every tagged car (citizen, ambient, truck) uniformly.
local FADE_NEAR = 12  -- fully invisible this close to a connection (server despawn radius)
local FADE_FAR  = 36  -- fade begins here
local CONN_REFRESH_FRAMES = 120 -- connections change rarely; rescan every couple seconds

local _connPts: { Vector3 } = {}
local _connRefresh = 0

local function refreshConnPts()
	table.clear(_connPts)
	local folder = workspace:FindFirstChild(OCConstants.FOLDER_NAME)
	if not folder then return end
	for _, mk in folder:GetChildren() do
		if mk:IsA("BasePart") then table.insert(_connPts, mk.Position) end
	end
end

-- 0 = untouched, 1 = invisible, from the XZ distance to the nearest outside connection.
local function connFadeAt(pos: Vector3): number
	local best = math.huge
	for _, c in _connPts do
		local dx, dz = pos.X - c.X, pos.Z - c.Z
		local d2 = dx * dx + dz * dz
		if d2 < best then best = d2 end
	end
	if best >= FADE_FAR * FADE_FAR then return 0 end
	return 1 - math.clamp((math.sqrt(best) - FADE_NEAR) / (FADE_FAR - FADE_NEAR), 0, 1)
end

type Active = {
	root: BasePart,
	display: CFrame,
	lastWritten: CFrame?,
	prevPose: CFrame,
	prevTime: number,
	targetPose: CFrame,
	targetTime: number,
	streamAt: number?,    -- local clock when the newest stream pose was applied
	delay: number,        -- how far behind real time this car renders (see step)
}

-- Stream packet layout (must match PathFollower): f64 timestamp header, then
-- entries of (id u32, x f32, y f32, z f32, yaw u16, pitch i8).
local STREAM_HEADER = 8
local STREAM_ENTRY = 19
-- Stream quiet for this long -> adopt replicated property CFrames again (car
-- went out of server range and is on the slow keepalive, or packets dropped).
local STREAM_STALE = 0.6

-- MESH-KIT VEHICLES (blender/vehicle_kit.py: Body / BodyLOD / Brake / Wheel* parts). A car
-- without the MeshKit attribute is a legacy part-built model and gets none of this.
-- LOD: the full mesh gives way to the 120-tri LOD only once their difference (LodError, world
-- studs) is under half a pixel on screen, so the swap is invisible by construction -- the same
-- zero-flicker rule as the terrain; never a distance ring.
local LOD_ENTER_PX, LOD_EXIT_PX = 0.5, 0.65
-- Wheels spin on High/Ultra/Custom graphics, and only this close: past it a wheel is a few
-- pixels and turning it is per-frame work for nothing.
local SPIN_DIST = 260
local SPIN_PRESETS = { High = true, Ultra = true, Custom = true }
-- Lamps: same wrapped-clock convention as WindowLightsView (18:00 -> 18, 05:30 -> 29.5).
local LAMPS_ON, LAMPS_OFF = 17.75, 30.5
local NIGHT_GLOW, BRAKE_GLOW = 3, 6
local LAMP_SWEEP_SECONDS = 2
-- Brake lamps light while the car slows harder than this (studs/s^2), and while it waits
-- stopped after driving -- a car still for longer than BRAKE_HOLD is parked, not queued.
local BRAKE_DECEL = 6
local STOPPED_SPEED = 1
local BRAKE_HOLD = 25

type Wheel = { weld: Weld, base: CFrame, r: number, side: number }
type Rig = {
	full: { BasePart },            -- everything hidden while the LOD shows
	lods: { BasePart },            -- BodyLOD, plus TrailerLOD on an articulated rig
	wheels: { Wheel },
	lamps: { SurfaceAppearance },  -- night lamps, on Body and BodyLOD
	brake: SurfaceAppearance?,
	err: number,
	isLod: boolean,
	dist: number,                  -- rolled distance, drives the wheel angle
	speed: number,
	still: number,
	moved: boolean,
	braking: boolean,
	-- articulated rigs (semi + trailer, bendy bus): the rear unit's hinge, see articulate()
	hitch: Weld?,
	hitchAt: Vector3,              -- hinge position in root space
	axleLen: number,               -- hinge -> rear unit's axle, studs
	axle: Vector3?,                -- the rear axle's world position last frame
	bend: number,                  -- hinge yaw currently written
}
local _rigs: { [Model]: Rig } = {}
local _night = false
local _spin = true
local _running = false
local _pxPerStud = 0     -- screen pixels per stud at 1 stud distance, refreshed every frame
local _camPos = Vector3.zero
local _focus: Vector3? = nil -- camera's ground look-at point, refreshed every frame

local function setLamps(rig: Rig)
	for _, sa in rig.lamps do
		sa.EmissiveStrength = if _night then NIGHT_GLOW else 0
	end
end

local function makeRig(model: Model): Rig?
	local body = model:FindFirstChild("Body")
	if not (body and body:IsA("BasePart")) then
		return nil -- streamed in without its parts yet; the next visibility sweep retries
	end
	local rig: Rig = {
		full = {}, lods = {}, wheels = {}, lamps = {}, brake = nil,
		err = model:GetAttribute("LodError") or 0, isLod = false,
		dist = 0, speed = 0, still = 0, moved = false, braking = false,
		hitch = nil, hitchAt = Vector3.zero, axleLen = 1, axle = nil, bend = 0,
	}
	for _, p in model:GetChildren() do
		if not p:IsA("BasePart") then continue end
		local sa = p:FindFirstChildOfClass("SurfaceAppearance")
		if p.Name == "BodyLOD" or p.Name == "TrailerLOD" then
			table.insert(rig.lods, p)
			if sa then table.insert(rig.lamps, sa) end
		elseif p.Name == "Body" or p.Name == "Trailer" then
			table.insert(rig.full, p)
			if sa then table.insert(rig.lamps, sa) end
		elseif p.Name == "Brake" then
			table.insert(rig.full, p)
			rig.brake = sa
		elseif p:GetAttribute("Wheel") then
			table.insert(rig.full, p)
			local weld = p:FindFirstChild("WheelWeld")
			if weld and weld:IsA("Weld") then
				table.insert(rig.wheels, {
					weld = weld, base = weld.C0, r = math.max(p.Size.Y * 0.5, 0.05),
					-- left wheels are the right wheel turned 180: same roll, opposite local sign
					side = if weld.C0.RightVector.X >= 0 then 1 else -1,
				})
			end
		end
	end
	local tr = model:FindFirstChild("TrailerRoot")
	local hinge = tr and tr:FindFirstChild("HitchWeld")
	if hinge and hinge:IsA("Weld") then
		rig.hitch = hinge
		rig.hitchAt = hinge.C0.Position
		rig.axleLen = math.max((model:GetAttribute("TrailerAxle") :: number?) or 0, 1)
	end
	setLamps(rig)
	_rigs[model] = rig
	return rig
end

local function setLod(rig: Rig, on: boolean)
	if rig.isLod == on or #rig.lods == 0 then return end
	rig.isLod = on
	for _, p in rig.full do
		p.Transparency = if on then 1 else 0
	end
	for _, p in rig.lods do
		p.Transparency = if on then 0 else 1
	end
end

-- Articulated rigs: the rear unit is dragged, not steered. Each frame its axle moves straight
-- toward the hitch's new position (a tractrix), which is exactly how a trailer cuts inside a
-- corner behind its tractor. Only the hinge weld's C0 changes -- local, like the wheel spin --
-- so the server keeps one rigid rig and nothing extra crosses the network.
local MAX_BEND = math.rad(75)
local function articulate(rig: Rig, cf: CFrame)
	local hinge = rig.hitch
	if not hinge then return end
	local h = cf * rig.hitchAt
	local len = rig.axleLen
	local d = if rig.axle then h - (rig.axle :: Vector3) else Vector3.zero
	local m = d.Magnitude
	if m < len * 0.5 or m > len * 1.5 then
		d = cf.LookVector -- first frame, teleport or pop-in: lay the rear unit out straight
	end
	local dl = cf:VectorToObjectSpace(d)
	local yaw = math.clamp(math.atan2(-dl.X, -dl.Z), -MAX_BEND, MAX_BEND)
	rig.axle = h - cf:VectorToWorldSpace(Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))) * len
	if math.abs(yaw - rig.bend) > 1e-4 then
		rig.bend = yaw
		hinge.C0 = CFrame.new(rig.hitchAt) * CFrame.Angles(0, yaw, 0)
	end
end

-- One render frame of motion for a mesh-kit car: roll the wheels by the distance it moved,
-- and light the brakes from how its speed is changing.
local function updateRig(rig: Rig, from: CFrame, to: CFrame, dt: number, near: boolean)
	if dt <= 0 then return end
	local stepped = (to.Position - from.Position):Dot(to.LookVector)
	local before = rig.speed
	rig.speed += (stepped / dt - rig.speed) * math.min(dt * 6, 1)
	local decel = (before - rig.speed) / dt
	if math.abs(rig.speed) > STOPPED_SPEED then
		rig.moved = true
		rig.still = 0
	else
		rig.still += dt
	end
	local braking = decel > BRAKE_DECEL
		or (rig.moved and math.abs(rig.speed) <= STOPPED_SPEED and rig.still < BRAKE_HOLD)
	if braking ~= rig.braking then
		rig.braking = braking
		if rig.brake then
			rig.brake.EmissiveStrength = if braking then BRAKE_GLOW else 0
		end
	end
	if stepped ~= 0 and near and _spin and not rig.isLod then
		rig.dist += stepped
		for _, w in rig.wheels do
			w.weld.C0 = w.base * CFrame.Angles((-rig.dist / w.r) * w.side, 0, 0)
		end
	end
end

local function isNight(): boolean
	local h = Lighting.ClockTime
	if h < 12 then h += 24 end
	return h >= LAMPS_ON and h < LAMPS_OFF
end

-- Set a whole NPC model's client-side transparency via LocalTransparencyModifier (never
-- touches the server's authoritative Transparency, so tinted glass keeps its own value).
local function setModelFade(model: Model, fade: number)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then d.LocalTransparencyModifier = fade end
	end
end

local function setModelHidden(model: Model, hidden: boolean)
	setModelFade(model, if hidden then 1 else 0)
end

-- Distant cars keep only one root reference. Interpolation buffers are allocated
-- lazily for the small nearby bubble, which keeps 100k ambient entries cheap to hold.
local _tracked: { [Model]: BasePart } = {}
local _active: { [Model]: Active } = {}
local _hidden: { [Model]: boolean } = {}
local _fadeApplied: { [Model]: number } = {}
local _pending: { [Model]: RBXScriptConnection } = {}
local _conns: { RBXScriptConnection } = {}
local _byId: { [number]: Model } = {}
local _idConns: { [Model]: RBXScriptConnection } = {}
-- Newest server stamp applied per car, for the unordered-packet drop. Lives outside
-- Active (weak-keyed) because a car keeps receiving stream poses while it is tracked but
-- NOT active, and the ordering guarantee has to survive that.
local _streamStamp: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any
local _trackedCount = 0
local _cullCursor: Model? = nil

local function evaluateVisibility(model: Model, root: BasePart, camera: Camera)
	local current = root.CFrame
	local off = current.Position - camera.CFrame.Position
	local forward = off:Dot(camera.CFrame.LookVector)
	local flatSq = off.X * off.X + off.Z * off.Z
	local focus = _focus
	if focus then
		local fx, fz = current.Position.X - focus.X, current.Position.Z - focus.Z
		flatSq = math.min(flatSq, fx * fx + fz * fz)
	end
	local hidden = _hidden[model] == true
	-- No stream pose yet: the replicated CFrame is where the vehicle was CREATED (the server
	-- writes none after that), so drawing it would park a ghost at its spawn point.
	local unseen = _streamStamp[model] == nil

	if hidden then
		if not unseen and forward > 8 and flatSq < UNCULL_DIST_SQ and not sampledOut(model, flatSq, 50) then
			_hidden[model] = nil
			hidden = false
			setModelHidden(model, false)
		end
	elseif unseen or forward < -8 or flatSq > RENDER_DIST_SQ or sampledOut(model, flatSq, 0) then
		_hidden[model] = true
		hidden = true
		setModelHidden(model, true)
	end

	-- Out-of-range now implies hidden, so this is the one test: a hidden car pays no
	-- interpolation, and setModelHidden already wrote LTM=1 over any connection fade.
	if hidden then
		_active[model] = nil
		_fadeApplied[model] = nil
	elseif not _active[model] then
		_active[model] = {
			root = root,
			display = current,
			lastWritten = nil,
			prevPose = current,
			prevTime = _clock,
			targetPose = current,
			targetTime = _clock,
			delay = INTERP_DELAY,
		}
	end

	if hidden or not model:GetAttribute("MeshKit") then return end
	local rig = _rigs[model] or makeRig(model)
	if rig and _pxPerStud > 0 then
		local px = rig.err * _pxPerStud / math.max(off.Magnitude, 1)
		if rig.isLod then
			if px > LOD_EXIT_PX then setLod(rig, false) end
		elseif px < LOD_ENTER_PX then
			setLod(rig, true)
		end
	end
end

local function track(model: Model)
	if _tracked[model] then return end
	local root = model.PrimaryPart
	if not root then
		if _pending[model] then return end
		_pending[model] = model:GetPropertyChangedSignal("PrimaryPart"):Connect(function()
			local p = _pending[model]
			if p then p:Disconnect() end
			_pending[model] = nil
			track(model)
		end)
		return
	end

	_tracked[model] = root
	_trackedCount += 1
	-- Map the stream id -> model. The NpcId attribute replicates with (or shortly
	-- after) the model; keep listening so a re-assigned id can never orphan the map.
	local id = model:GetAttribute("NpcId")
	if typeof(id) == "number" then
		_byId[id] = model
	end
	_idConns[model] = model:GetAttributeChangedSignal("NpcId"):Connect(function()
		local v = model:GetAttribute("NpcId")
		if typeof(v) == "number" then _byId[v] = model end
	end)
	local camera = workspace.CurrentCamera
	if camera then
		evaluateVisibility(model, root, camera)
	else
		local current = root.CFrame
		_active[model] = {
			root = root, display = current, lastWritten = nil,
			prevPose = current, prevTime = _clock, targetPose = current, targetTime = _clock,
			delay = INTERP_DELAY,
		}
	end
end

local function untrack(model: Model)
	local id = model:GetAttribute("NpcId")
	if typeof(id) == "number" and _byId[id] == model then _byId[id] = nil end
	local ic = _idConns[model]
	if ic then
		ic:Disconnect()
		_idConns[model] = nil
	end
	_streamStamp[model] = nil
	_rigs[model] = nil
	if _tracked[model] then
		_tracked[model] = nil
		_active[model] = nil
		_hidden[model] = nil
		_fadeApplied[model] = nil
		_trackedCount = math.max(0, _trackedCount - 1)
	end
	if _cullCursor == model then _cullCursor = nil end
	local p = _pending[model]
	if p then
		p:Disconnect()
		_pending[model] = nil
	end
end

local function scanVisibility(camera: Camera)
	if _trackedCount <= 0 then return end
	local budget = math.min(_trackedCount, math.max(32, math.ceil(_trackedCount / CULL_SCAN_FRAMES)))
	for _ = 1, budget do
		local model, root = next(_tracked, _cullCursor)
		if not model then
			_cullCursor = nil
			model, root = next(_tracked)
		end
		if not model or not root then return end
		_cullCursor = model
		if root.Parent then evaluateVisibility(model, root, camera) else untrack(model) end
	end
end

local function step(dt: number)
	_clock += dt
	local camera = workspace.CurrentCamera
	if camera then
		_camPos = camera.CFrame.Position
		_focus = groundFocus(camera.CFrame)
		_pxPerStud = camera.ViewportSize.Y / (2 * math.tan(math.rad(camera.FieldOfView) * 0.5))
		scanVisibility(camera)
	end

	_connRefresh -= 1
	if _connRefresh <= 0 then
		_connRefresh = CONN_REFRESH_FRAMES
		refreshConnPts()
	end

	-- Only cars inside the active bubble pay interpolation cost every render frame.
	for model, t in _active do
		local root = t.root
		if not root.Parent then
			untrack(model)
			continue
		end
		local current = root.CFrame

		if #_connPts > 0 then
			local fade = connFadeAt(current.Position)
			local prev = _fadeApplied[model]
			if fade > 0 then
				if not prev or math.abs(fade - prev) > 0.02 then
					setModelFade(model, fade)
					_fadeApplied[model] = fade
				end
			elseif prev then
				setModelFade(model, 0)
				_fadeApplied[model] = nil
			end
		end

		-- Property-replicated CFrames are only adopted while the stream is quiet
		-- for this car (far keepalive / packet loss). While streaming, replicated
		-- writes are stale ground-truth and would yank the car backward.
		if _clock - (t.streamAt or -math.huge) > STREAM_STALE then
			local lw = t.lastWritten
			if (not lw)
				or (current.Position - lw.Position).Magnitude > POS_EPS
				or current.LookVector:Dot(lw.LookVector) < ROT_DOT_EPS
			then
				if (not lw) or (current.Position - t.targetPose.Position).Magnitude > snapDistFor(_clock - t.targetTime) then
					t.prevPose, t.targetPose = current, current
					t.prevTime, t.targetTime = _clock - t.delay, _clock
					t.display = current
				else
					t.prevPose, t.prevTime = t.targetPose, math.max(t.targetTime, _clock - MAX_SPAN)
					t.targetPose, t.targetTime = current, _clock
				end
			end
		end

		local span = t.targetTime - t.prevTime
		-- Render one UPDATE interval behind, not a fixed 85 ms. Far cars arrive on the 2 Hz
		-- property keepalive; a delay shorter than their interval finishes the lerp early and
		-- parks the car until the next pose lands -- that stutter IS the visible chunking.
		-- Growing instantly and shrinking slowly means re-entering the 12 Hz stream catches up
		-- at a barely-perceptible 25% speed-up instead of popping forward half a second.
		if span > t.delay then
			t.delay = math.min(span, MAX_SPAN)
		elseif t.delay > INTERP_DELAY then
			t.delay = math.max(INTERP_DELAY, t.delay - dt * 0.25)
		end
		local pose = if span <= 1e-4 then t.targetPose
			else t.prevPose:Lerp(t.targetPose, math.clamp((_clock - t.delay - t.prevTime) / span, 0, 1))

		local rig = _rigs[model]
		if rig then
			updateRig(rig, t.display, pose, dt, (pose.Position - _camPos).Magnitude < SPIN_DIST)
		end

		-- Nothing left to interpolate: the car already sits on the pose we last wrote.
		-- Skip the write, but NEVER stamp `current` onto lastWritten -- that field is the
		-- record of OUR OWN last write, and forging it makes the next SERVER pose look
		-- like ours. That is what left a parking car frozen mid-turn: the final PivotTo
		-- into the stall lands during the STREAM_STALE window, the finished interpolation
		-- overwrites it every frame, and by the time adoption is allowed `current` and
		-- lastWritten match, so the square pose is never adopted.
		local written = t.lastWritten
		if written
			and (pose.Position - written.Position).Magnitude < POS_EPS
			and pose.LookVector:Dot(written.LookVector) > ROT_DOT_EPS
		then
			continue
		end

		t.display = pose
		t.lastWritten = pose
		root.CFrame = pose
		if rig then articulate(rig, pose) end
	end
end

-- Decode one stream packet and feed each known car's pose into its interpolation
-- buffer (same snap/advance rules as property adoption).
local function onStreamPacket(buf: buffer)
	if typeof(buf) ~= "buffer" or buffer.len(buf) < STREAM_HEADER + STREAM_ENTRY then return end
	local stamp = buffer.readf64(buf, 0)
	local n = (buffer.len(buf) - STREAM_HEADER) // STREAM_ENTRY
	for k = 0, n - 1 do
		local off = STREAM_HEADER + k * STREAM_ENTRY
		local model = _byId[buffer.readu32(buf, off)]
		if not model then continue end
		local root = _tracked[model]
		if not root or not root.Parent then continue end
		if stamp <= (_streamStamp[model] or 0) then continue end -- unordered: drop stale packets
		local firstPose = _streamStamp[model] == nil
		_streamStamp[model] = stamp
		local pos = Vector3.new(buffer.readf32(buf, off + 4), buffer.readf32(buf, off + 8), buffer.readf32(buf, off + 12))
		local yaw = buffer.readu16(buf, off + 16) / 65535 * (2 * math.pi) - math.pi
		local pitch = math.rad(buffer.readi8(buf, off + 18))
		local cosP = math.cos(pitch)
		local look = Vector3.new(-math.sin(yaw) * cosP, math.sin(pitch), -math.cos(yaw) * cosP)
		local pose = CFrame.lookAt(pos, pos + look, Vector3.yAxis)

		local t = _active[model]
		if not t then
			-- Tracked but not interpolated: behind the camera, or awaiting the budgeted
			-- visibility sweep, while already inside the server's stream bubble. The server
			-- has STOPPED writing this model's CFrame -- the stream IS its motion now -- so
			-- apply the pose raw (a snap at stream rate, no per-frame cost). Dropping it here
			-- is what left near cars parked while distant ones on the slow property keepalive
			-- kept driving. Also leaves the root fresh for evaluateVisibility to seed from.
			root.CFrame = pose
			local rig = _rigs[model]
			if rig then rig.axle = nil end -- raw snap: re-lay the rear unit when it next draws
			-- Its first pose is what lets it be drawn at all; don't wait for the budgeted sweep.
			local camera = workspace.CurrentCamera
			if firstPose and camera then evaluateVisibility(model, root, camera) end
			continue
		end
		t.streamAt = _clock
		if (pose.Position - t.targetPose.Position).Magnitude > snapDistFor(_clock - t.targetTime) then
			t.prevPose, t.targetPose = pose, pose
			t.prevTime, t.targetTime = _clock - t.delay, _clock
			t.display = pose
		else
			t.prevPose, t.prevTime = t.targetPose, math.max(t.targetTime, _clock - MAX_SPAN)
			t.targetPose, t.targetTime = pose, _clock
		end
	end
end

function NPCDriverView.Start()
	local Net = require(ReplicatedStorage:WaitForChild("Networker")) :: any
	table.insert(_conns, Net.SyncNpcPoses.OnClientEvent:Connect(onStreamPacket))

	for _, m in CollectionService:GetTagged(TAG) do
		if m:IsA("Model") then
			track(m)
		end
	end

	table.insert(_conns, CollectionService:GetInstanceAddedSignal(TAG):Connect(function(inst)
		if inst:IsA("Model") then
			track(inst :: Model)
		end
	end))
	table.insert(_conns, CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(inst)
		untrack(inst :: Model)
	end))

	table.insert(_conns, RunService.RenderStepped:Connect(step))

	_spin = SPIN_PRESETS[Settings.get("graphicsPreset")] == true
	_running = true
	-- Settings has no unsubscribe; _running keeps a stopped view from reacting.
	Settings.onChanged("graphicsPreset", function(v)
		if _running then _spin = SPIN_PRESETS[v] == true end
	end)
	-- Lamps follow the clock on a slow sweep, touching SurfaceAppearances only when night
	-- actually flips (and makeRig lights new cars itself).
	task.spawn(function()
		while _running do
			local night = isNight()
			if night ~= _night then
				_night = night
				for _, rig in _rigs do setLamps(rig) end
			end
			task.wait(LAMP_SWEEP_SECONDS)
		end
	end)
end

function NPCDriverView.Stop()
	for _, c in _conns do c:Disconnect() end
	table.clear(_conns)
	for _, c in _pending do c:Disconnect() end
	table.clear(_pending)
	for _, c in _idConns do c:Disconnect() end
	table.clear(_idConns)
	table.clear(_byId)
	table.clear(_streamStamp)
	table.clear(_hidden)
	table.clear(_fadeApplied)
	table.clear(_active)
	table.clear(_tracked)
	table.clear(_rigs)
	_running = false
	_trackedCount = 0
	_cullCursor = nil
end

return NPCDriverView
