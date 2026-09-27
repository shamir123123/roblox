--!strict
-- PedestrianView
-- Client-side movement for server-simulated walkers, the pedestrian twin of
-- NPCDriverView. The server simulates walkers (authoritative) but no longer
-- writes near walkers' instance CFrames -- poses arrive batched over
-- Net.SyncNpcPoses (unreliable buffer packets, see PathFollower); this view maps
-- entries to walkers via the NpcId attribute and renders each one interpolated
-- between the last two stream poses. Far walkers still arrive as slow property
-- keepalive writes; when a walker's stream goes quiet we adopt those replicated
-- CFrames again. Client-only, no client->server path. The figure's body parts
-- are welded to the root, so moving the root locally moves the whole person.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local PedestrianView = {}

local TAG = "NPCWalker"

-- Render-behind interpolation between the two most recent server poses (see NPCDriverView
-- for the full rationale). Renders the walker one ~12 Hz interval back, lerping prev->target
-- for smooth constant-velocity motion that never overshoots and stays stable at any FPS.
local INTERP_DELAY = 0.085
local _clock = 0
-- A target farther than this from the rendered pose is a teleport (spawn, re-path,
-- pop-in), not walking -- snap instead of gliding across the map.
local SNAP_DIST = 12
-- Which walkers this view actually moves. Measured HORIZONTALLY (XZ), to match the
-- server's PathFollower.REPLICATE_RANGE (200, also XZ) that decides which walkers are
-- stream-driven, and set ABOVE it so the two bands overlap. A 3D radius equal to the
-- server's left sqrt(200^2 - camY^2) of horizontal reach on this unclamped fly camera:
-- the server had stopped writing their CFrames while this view skipped the write, so
-- walkers in the difference stood still (the NPCDriverView freeze, same seam).
-- No distance cutoff, matching NPCDriverView. The server writes no property CFrames any
-- more (every walker rides the pose stream), so skipping the write out here would leave
-- distant walkers frozen at their spawn pose. 80 walkers max, behind-camera ones skipped.
-- View-direction cull: walkers IN FRONT stay drawn at ANY distance; walkers BEHIND the
-- camera are hidden + their ease skipped (still simulated on the server). Cosines of the
-- angle off the camera look vector; hysteresis between show/hide so turning never flickers.
local FRONT_COS = 0.05
local BEHIND_COS = -0.19
local POS_EPS = 1e-3
local ROT_DOT_EPS = 0.9999
-- Up to 3000 people can be walking within 500 m. Past NEAR_DIST each one is redrawn every
-- FAR_EVERY-th frame (staggered, so the cost is spread), and the server sends them at 4 Hz;
-- each walker renders one update interval behind (adaptive, up to MAX_DELAY) so the coarser
-- stream still moves smoothly.
local NEAR_DIST = 300
local FAR_EVERY = 3
local MAX_DELAY = 0.4
local _frame = 0
local _slotSeq = 0

type Tracked = {
	root: BasePart, display: CFrame, lastWritten: CFrame?,
	prevPose: CFrame, prevTime: number, targetPose: CFrame, targetTime: number,
	hidden: boolean?,
	streamStamp: number?, streamAt: number?,
	slot: number,
}

-- Stream packet layout (must match PathFollower): f64 timestamp header, then
-- entries of (id u32, x f32, y f32, z f32, yaw u16, pitch i8).
local STREAM_HEADER = 8
local STREAM_ENTRY = 19
local STREAM_STALE = 0.6

-- Hide/show a whole walker model client-side via LocalTransparencyModifier (the server's
-- authoritative Transparency is untouched). Only called on a hide<->show transition.
local function setModelHidden(model: Model, hidden: boolean)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then d.LocalTransparencyModifier = if hidden then 1 else 0 end
	end
end

local _tracked: { [Model]: Tracked } = {}
local _pending: { [Model]: RBXScriptConnection } = {}
local _conns: { RBXScriptConnection } = {}
local _byId: { [number]: Model } = {}
local _idConns: { [Model]: RBXScriptConnection } = {}

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
	_slotSeq += 1
	_tracked[model] = {
		root = root, display = root.CFrame, lastWritten = nil,
		prevPose = root.CFrame, prevTime = _clock, targetPose = root.CFrame, targetTime = _clock,
		slot = _slotSeq,
	}
	local id = model:GetAttribute("NpcId")
	if typeof(id) == "number" then
		_byId[id] = model
	end
	-- Keep listening so a re-assigned id can never orphan the map.
	_idConns[model] = model:GetAttributeChangedSignal("NpcId"):Connect(function()
		local v = model:GetAttribute("NpcId")
		if typeof(v) == "number" then _byId[v] = model end
	end)
end

local function untrack(model: Model)
	_tracked[model] = nil
	local id = model:GetAttribute("NpcId")
	if typeof(id) == "number" and _byId[id] == model then _byId[id] = nil end
	local ic = _idConns[model]
	if ic then ic:Disconnect(); _idConns[model] = nil end
	local p = _pending[model]
	if p then p:Disconnect(); _pending[model] = nil end
end

local function step(dt: number)
	_clock += dt
	_frame += 1
	local renderTime = _clock - INTERP_DELAY
	local camera = workspace.CurrentCamera
	local camPos = if camera then camera.CFrame.Position else nil
	local camLook = if camera then camera.CFrame.LookVector else nil

	for model, t in _tracked do
		local root = t.root
		if not root.Parent then
			_tracked[model] = nil
			continue
		end

		local current = root.CFrame

		if camPos and camLook then
			local off = current.Position - camPos
			local mag = off.Magnitude
			local dot = if mag > 1e-3 then off:Dot(camLook) / mag else 1
			if dot < BEHIND_COS then
				if not t.hidden then t.hidden = true; setModelHidden(model, true) end
			elseif dot > FRONT_COS then
				if t.hidden then t.hidden = false; setModelHidden(model, false) end
			end
			if t.hidden then
				t.lastWritten = nil
				continue
			end
			if mag > NEAR_DIST and (t.slot + _frame) % FAR_EVERY ~= 0 then continue end
		end

		-- Adopt property-replicated CFrames only while the stream is quiet for this
		-- walker (far keepalive / packet loss); stream poses are the live source.
		if _clock - (t.streamAt or -math.huge) > STREAM_STALE then
			local lw = t.lastWritten
			if (not lw)
				or (current.Position - lw.Position).Magnitude > POS_EPS
				or current.LookVector:Dot(lw.LookVector) < ROT_DOT_EPS
			then
				if (not lw) or (current.Position - t.targetPose.Position).Magnitude > SNAP_DIST then
					t.prevPose, t.targetPose = current, current
					t.prevTime, t.targetTime = renderTime, _clock
					t.display = current
				else
					t.prevPose, t.prevTime = t.targetPose, t.targetTime
					t.targetPose, t.targetTime = current, _clock
				end
			end
		end

		local span = t.targetTime - t.prevTime
		local pose: CFrame
		if span <= 1e-4 then
			pose = t.targetPose
		else
			local delay = math.clamp(span, INTERP_DELAY, MAX_DELAY)
			local alpha = math.clamp((_clock - delay - t.prevTime) / span, 0, 1)
			pose = t.prevPose:Lerp(t.targetPose, alpha)
		end

		if (t.targetPose.Position - t.prevPose.Position).Magnitude < POS_EPS
			and (pose.Position - t.display.Position).Magnitude < POS_EPS
		then
			t.lastWritten = root.CFrame
			continue
		end

		t.display = pose
		t.lastWritten = pose
		root.CFrame = pose
	end
end

-- Decode one stream packet; feed each known walker's pose into its buffer.
local function onStreamPacket(buf: buffer)
	if typeof(buf) ~= "buffer" or buffer.len(buf) < STREAM_HEADER + STREAM_ENTRY then return end
	local stamp = buffer.readf64(buf, 0)
	local n = (buffer.len(buf) - STREAM_HEADER) // STREAM_ENTRY
	for k = 0, n - 1 do
		local off = STREAM_HEADER + k * STREAM_ENTRY
		local model = _byId[buffer.readu32(buf, off)]
		if not model then continue end
		local t = _tracked[model]
		if not t then continue end
		if stamp <= (t.streamStamp or 0) then continue end
		t.streamStamp = stamp
		t.streamAt = _clock
		local pos = Vector3.new(buffer.readf32(buf, off + 4), buffer.readf32(buf, off + 8), buffer.readf32(buf, off + 12))
		local yaw = buffer.readu16(buf, off + 16) / 65535 * (2 * math.pi) - math.pi
		-- -128 marks a walker's last pose before it leaves our stream (PathFollower); walkers
		-- stand upright, so it simply reads as level.
		local pitchRaw = buffer.readi8(buf, off + 18)
		local pitch = if pitchRaw == -128 then 0 else math.rad(pitchRaw)
		local cosP = math.cos(pitch)
		local look = Vector3.new(-math.sin(yaw) * cosP, math.sin(pitch), -math.cos(yaw) * cosP)
		local pose = CFrame.lookAt(pos, pos + look, Vector3.yAxis)
		if (pose.Position - t.targetPose.Position).Magnitude > SNAP_DIST then
			t.prevPose, t.targetPose = pose, pose
			t.prevTime, t.targetTime = _clock - INTERP_DELAY, _clock
			t.display = pose
		else
			t.prevPose, t.prevTime = t.targetPose, t.targetTime
			t.targetPose, t.targetTime = pose, _clock
		end
	end
end

function PedestrianView.Start()
	local Net = require(ReplicatedStorage:WaitForChild("Networker")) :: any
	table.insert(_conns, Net.SyncNpcPoses.OnClientEvent:Connect(onStreamPacket))

	for _, m in CollectionService:GetTagged(TAG) do
		if m:IsA("Model") then track(m) end
	end
	table.insert(_conns, CollectionService:GetInstanceAddedSignal(TAG):Connect(function(inst)
		if inst:IsA("Model") then track(inst :: Model) end
	end))
	table.insert(_conns, CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(inst)
		untrack(inst :: Model)
	end))
	table.insert(_conns, RunService.RenderStepped:Connect(step))
end

function PedestrianView.Stop()
	for _, c in _conns do c:Disconnect() end
	table.clear(_conns)
	for _, c in _pending do c:Disconnect() end
	table.clear(_pending)
	for _, c in _idConns do c:Disconnect() end
	table.clear(_idConns)
	table.clear(_byId)
	table.clear(_tracked)
end

return PedestrianView
