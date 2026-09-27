--!strict
-- Free-fly RTS camera. Owns the scriptable camera, and exposes a small API the rest
-- of the UI drives it with:
--   focusOn(pos)            -- glide to frame a world point ("go to this home")
--   followPart(part)        -- chase a moving target ("follow this NPC")
--   stopFollow() / isFollowing()
-- Any manual input (WASD / middle-drag / scroll) cancels an active focus or follow and
-- hands control straight back to the player.
-- The mouse camera is MIDDLE ONLY: hold it and look around. Right mouse belongs to the
-- tools (rotate what you are placing, un-zone, cancel) and never moves the view.

local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players          = game:GetService("Players")
local Workspace        = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local MAP_HALF = RoadConstants.MAP_HALF_EXTENT

local CursorRay = require(script.Parent:WaitForChild("CursorRay"))
local Settings = require(script.Parent:WaitForChild("Settings"))
local SettingsPanel = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("SettingsPanel"))

-- Rebindable camera binds (Settings > Input), cached: these are read every frame.
-- A bind is 1-2 inputs held together, so Settings.isDown does the checking.
local _bindForward = Settings.getBind("CamForward")
local _bindBack = Settings.getBind("CamBack")
local _bindLeft = Settings.getBind("CamLeft")
local _bindRight = Settings.getBind("CamRight")
local _bindRotL = Settings.getBind("CamRotateLeft")
local _bindRotR = Settings.getBind("CamRotateRight")
local _bindRise = Settings.getBind("CamRise")
local _bindSink = Settings.getBind("CamSink")
-- Camera-feel multipliers (Settings > Input), cached for the same reason.
local _camSpeedMult = 1
local _rotSpeedMult = 1
local _zoomSpeedMult = 1
local _sensMult = 1
local _edgeScroll = false
local _windowFocused = true
local EDGE_SCROLL_BAND = 16 -- px from a screen edge that trigger edge scrolling
local _bindsHooked = false

-- Panels that block freecam input when open
local function isAnyPanelOpen(): boolean
	local hud = script.Parent
	local function check(name: string): boolean
		local ok, mod = pcall(require, hud:FindFirstChild(name))
		return ok and mod and (mod :: any).IsOpen() == true
	end
	return check("EconomyPanelController")
		or check("DashboardController")
		or check("TransportOverviewController")
		or check("TerrainPanelController")
		or SettingsPanel.IsOpen()
end

local FreeCamController = {}
local _started = false

local BASE_SPEED   = 100
local BOOST_MULT   = 4
local SCROLL_SPEED = 24
local MOUSE_SENS   = 0.25
local PITCH_MIN    = -89
local PITCH_MAX    = 89
local START_POS    = Vector3.new(0, 120, 80)
local START_YAW    = 180
local START_PITCH  = -45
local KEY_ROT_SPEED   = 90   -- degrees per second for Q/E rotation (max)
local KEY_ROT_ACCEL   = 8    -- how fast it ramps up/down (higher = snappier)
local MOVE_ACCEL      = 12   -- WASD ease-in/out (higher = snappier)
local SCROLL_ACCEL    = 14   -- zoom ease-in/out
local HEIGHT_SPEED    = 80   -- studs/sec for R/F vertical movement
local HEIGHT_ACCEL    = 12   -- ease-in/out for R/F

-- Chase framing for follow: behind + above the target, easing toward the pose.
local FOLLOW_BACK = 26
local FOLLOW_UP   = 13
local FOLLOW_LERP = 6
-- Focus glide: ease to a vantage that frames the goal, then release control.
local FOCUS_BACK  = 40
local FOCUS_UP    = 30
local FOCUS_LERP  = 4
local FOCUS_DONE  = 3

local _camera: Camera? = nil
local _yaw   = START_YAW
local _pitch = START_PITCH
local _pos   = START_POS

local _middleDown = false
local _lastMouse  = Vector2.zero
local _yawVel     = 0             -- current Q/E rotation velocity (degrees/sec), eased
local _moveVel    = Vector3.zero  -- current WASD velocity, eased
local _scrollVel  = 0             -- current zoom velocity (studs/sec), eased
local _heightVel  = 0             -- current R/F vertical velocity (studs/sec), eased

local _focusGoal: Vector3? = nil
local _focusVantage: Vector3? = nil
local _followPart: BasePart? = nil
-- Hard hand-off: while set, this controller writes nothing to the camera at all, so
-- another system can own the CFrame outright (the admin Bad Apple show does this).
local _suspended = false
-- Move, zoom and rise speed follow the camera's height above the ground: slow and precise
-- down among the houses, fast high up, so a camera 7,000 studs over the tile view still
-- crosses the map in seconds. ALT_UNIT is the height that moves at the base speed (the
-- opening pose sits about there).
local ALT_UNIT = 120
local ALT_MIN_MULT = 0.25
local ALT_MAX_MULT = 60

local function altitudeMult(): number
	local groundY = CursorRay.terrainY(_pos.X, _pos.Z) or 0
	return math.clamp((_pos.Y - groundY) / ALT_UNIT, ALT_MIN_MULT, ALT_MAX_MULT)
end

-- Overview mode (the tile view): the wheel zooms even though the tile view's full-screen
-- click catcher sits under the cursor.
local _overview = false

-- A timed flight to a pose (glideTo). Input is ignored until it lands.
local _glide: { from: CFrame, to: any, toCf: CFrame, t: number, dur: number }? = nil

local function clampN(v: number, lo: number, hi: number): number
	return math.max(lo, math.min(hi, v))
end

-- Keep the camera eye inside the map; the world ends at +/-MAP_HALF.
-- Y has a floor too: nothing else writes the camera, so once the eye was under the
-- surface the player was stuck under the map. Two ways in -- driving down through it
-- (zoom / sink), and standing still while a re-grade (road place, upgrade, terrain
-- brush) raises the ground over the eye. This lifts it back out either way. Uses the
-- bare terrain probe, so a road or roof beneath the camera never shoves it up.
local GROUND_CLEARANCE = 6

local function clampPos()
	_pos = Vector3.new(clampN(_pos.X, -MAP_HALF, MAP_HALF), _pos.Y, clampN(_pos.Z, -MAP_HALF, MAP_HALF))
	local groundY = CursorRay.terrainY(_pos.X, _pos.Z)
	if groundY and _pos.Y < groundY + GROUND_CLEARANCE then
		_pos = Vector3.new(_pos.X, groundY + GROUND_CLEARANCE, _pos.Z)
	end
end

local function savedVector3(value: any): Vector3?
	if typeof(value) == "Vector3" then
		return value
	end
	if typeof(value) ~= "table" then
		return nil
	end
	local x = tonumber(value.x or value.X or value[1])
	local y = tonumber(value.y or value.Y or value[2])
	local z = tonumber(value.z or value.Z or value[3])
	if not x or not y or not z then
		return nil
	end
	return Vector3.new(x, y, z)
end

local function buildCFrame(): CFrame
	return CFrame.new(_pos)
		* CFrame.Angles(0, math.rad(_yaw), 0)
		* CFrame.Angles(math.rad(_pitch), 0, 0)
end

-- Movement basis for WASD/edge-scroll: flattened to the ground plane so W/S never
-- climb or dive with the pitch. Height is R/F only. Zoom uses the real look vector.
local function lookAndRight(): (Vector3, Vector3)
	local cf = buildCFrame()
	local look = -cf.ZVector
	local flat = Vector3.new(look.X, 0, look.Z)
	flat = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(-cf.XVector.Z, 0, cf.XVector.X)
	return flat, cf.XVector
end

-- Point the camera (yaw/pitch) from _pos toward a world target.
local function aimAt(target: Vector3)
	local dir = target - _pos
	if dir.Magnitude < 1e-3 then return end
	dir = dir.Unit
	_yaw   = math.deg(math.atan2(-dir.X, -dir.Z))
	_pitch = clampN(math.deg(math.asin(clampN(dir.Y, -1, 1))), PITCH_MIN, PITCH_MAX)
end

local function anyMoveKey(): boolean
	return Settings.isDown(_bindForward) or Settings.isDown(_bindBack)
		or Settings.isDown(_bindLeft) or Settings.isDown(_bindRight)
end

local function cancelAuto()
	_focusGoal = nil
	_focusVantage = nil
	_followPart = nil
end

-- == Public API ===============================================================
-- Glide to frame `pos` (keeps the current heading, sits back + above), then release.
function FreeCamController.focusOn(pos: Vector3)
	if typeof(pos) ~= "Vector3" then return end
	_followPart = nil
	local back = Vector3.new(math.sin(math.rad(_yaw)), 0, math.cos(math.rad(_yaw)))
	_focusGoal = pos
	_focusVantage = pos + Vector3.new(0, FOCUS_UP, 0) + back * FOCUS_BACK
end

-- Middle of the road network -- what "my city" means before anything else is built.
-- Node-weighted on purpose: the densest part of the map is where you were working.
local _snapper: any = nil
local function cityCenter(): Vector3
	if not _snapper then
		_snapper = require(script.Parent.Parent:WaitForChild("Controllers"):WaitForChild("RoadPlacementSnapper"))
	end
	local sum, count = Vector3.zero, 0
	for _, p in _snapper.getNodes() do
		sum += p
		count += 1
	end
	return if count > 0 then sum / count else Vector3.zero
end

-- The "I'm lost on this map" key (Settings > Keyboard > Camera). Jumps rather than
-- glides: a lerp across 8,000 studs is slower than flying it by hand, which defeats
-- the point. Lands in the opening pose, re-based on the ground under the centre.
function FreeCamController.goToCityCentre()
	local c = cityCenter()
	local groundY = CursorRay.terrainY(c.X, c.Z) or 0
	FreeCamController.setCameraState({
		pos = Vector3.new(c.X, groundY + START_POS.Y, c.Z + START_POS.Z),
		yaw = START_YAW,
		pitch = START_PITCH,
	})
end

function FreeCamController.followPart(part: BasePart?)
	if not part then return end
	_focusGoal = nil
	_focusVantage = nil
	_followPart = part
end

function FreeCamController.stopFollow()
	_followPart = nil
end

function FreeCamController.isFollowing(): boolean
	return _followPart ~= nil
end

-- Give the camera away / take it back. The caller owns Camera.CFrame while suspended and
-- is responsible for restoring a sensible pose before releasing.
function FreeCamController.setSuspended(suspended: boolean)
	_suspended = suspended == true
end

function FreeCamController.isSuspended(): boolean
	return _suspended
end

function FreeCamController.setOverviewMode(on: boolean)
	_overview = on == true
end

-- Mid-glide, the pose being flown TO: that is where the camera is about to be.
function FreeCamController.getCameraState(): { pos: Vector3, yaw: number, pitch: number }
	local glide = _glide
	if glide then return table.clone(glide.to) end
	return { pos = _pos, yaw = _yaw, pitch = _pitch }
end

-- Fly to a pose over `seconds` (eased), then hand control back exactly there. The tile
-- view uses it to rise over the whole map and to return to where the player was.
function FreeCamController.glideTo(state: any, seconds: number)
	local pos = savedVector3(typeof(state) == "table" and state.pos or nil)
	local camera = _camera or Workspace.CurrentCamera
	if not pos or not camera then return end
	local yaw = tonumber(state.yaw) or _yaw
	local pitch = clampN(tonumber(state.pitch) or _pitch, PITCH_MIN, PITCH_MAX)
	cancelAuto()
	_glide = {
		from = camera.CFrame,
		to = { pos = pos, yaw = yaw, pitch = pitch },
		toCf = CFrame.new(pos) * CFrame.Angles(0, math.rad(yaw), 0) * CFrame.Angles(math.rad(pitch), 0, 0),
		t = 0,
		dur = math.max(seconds, 1e-3),
	}
end

function FreeCamController.setCameraState(state: any)
	if typeof(state) ~= "table" then return end
	local pos = savedVector3(state.pos or state.p)
	if not pos then return end

	local yaw = tonumber(state.yaw or state.y)
	local pitch = tonumber(state.pitch or state.pi)
	_pos = pos
	if yaw then _yaw = yaw end
	if pitch then _pitch = clampN(pitch, PITCH_MIN, PITCH_MAX) end
	cancelAuto()

	local camera = _camera or Workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = buildCFrame()
	end
end

function FreeCamController.Start()
	if _started then return end
	_started = true

	if not _bindsHooked then
		_bindsHooked = true
		local function refreshFeel()
			_camSpeedMult = tonumber(Settings.get("camSpeed")) or 1
			_rotSpeedMult = tonumber(Settings.get("camRotSpeed")) or 1
			_zoomSpeedMult = tonumber(Settings.get("camZoomSpeed")) or 1
			_sensMult = tonumber(Settings.get("mouseSensitivity")) or 1
			_edgeScroll = Settings.get("edgeScroll") == true
		end
		refreshFeel()
		Settings.onChanged("camSpeed", refreshFeel)
		Settings.onChanged("camRotSpeed", refreshFeel)
		Settings.onChanged("camZoomSpeed", refreshFeel)
		Settings.onChanged("mouseSensitivity", refreshFeel)
		Settings.onChanged("edgeScroll", refreshFeel)
		-- Edge scrolling must stop when the game window loses focus, or an
		-- alt-tabbed cursor parked at an edge pans the camera forever.
		UserInputService.WindowFocused:Connect(function()
			_windowFocused = true
		end)
		UserInputService.WindowFocusReleased:Connect(function()
			_windowFocused = false
		end)
		Settings.onBindChanged(function()
			_bindForward = Settings.getBind("CamForward")
			_bindBack = Settings.getBind("CamBack")
			_bindLeft = Settings.getBind("CamLeft")
			_bindRight = Settings.getBind("CamRight")
			_bindRotL = Settings.getBind("CamRotateLeft")
			_bindRotR = Settings.getBind("CamRotateRight")
			_bindRise = Settings.getBind("CamRise")
			_bindSink = Settings.getBind("CamSink")
		end)
	end

	local player = Players.LocalPlayer

	local camera = Workspace.CurrentCamera
	while not camera do
		Workspace:GetPropertyChangedSignal("CurrentCamera"):Wait()
		camera = Workspace.CurrentCamera
	end
	camera.CameraType = Enum.CameraType.Scriptable
	_camera = camera

	local _cameraChangedConn: RBXScriptConnection = Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		local nextCamera = Workspace.CurrentCamera
		if not nextCamera then return end
		_camera = nextCamera
		nextCamera.CameraType = Enum.CameraType.Scriptable
	end)

	task.defer(function()
		local camMod = player.PlayerScripts:FindFirstChild("CameraModule")
		if camMod then camMod.Enabled = false end
	end)

	local _inputBeganConn: RBXScriptConnection = UserInputService.InputBegan:Connect(function(input: InputObject, _processed: boolean)
		if isAnyPanelOpen() then return end
		if not _processed and Settings.pressed("FocusCity", input) then
			FreeCamController.goToCityCentre()
		elseif Settings.pressed("PanCamera", input) then
			_middleDown = true
			_lastMouse = UserInputService:GetMouseLocation()
			UserInputService.MouseIconEnabled = false
			cancelAuto()
		end
	end)

	-- MouseWheel fires on InputChanged, not InputBegan. A wheel the UI already ate
	-- (scrolling a card list / any scroller) must NOT also zoom the world.
	local _inputChangedConn: RBXScriptConnection = UserInputService.InputChanged:Connect(function(input: InputObject, processed: boolean)
		if (processed and not _overview) or isAnyPanelOpen() then return end
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			_scrollVel = _scrollVel + input.Position.Z * SCROLL_SPEED * _zoomSpeedMult * altitudeMult()
			cancelAuto()
		end
	end)

	local _inputEndedConn: RBXScriptConnection = UserInputService.InputEnded:Connect(function(input: InputObject)
		if Settings.pressed("PanCamera", input) then
			_middleDown = false
			UserInputService.MouseIconEnabled = true
		end
	end)

	local _renderConn: RBXScriptConnection = RunService.RenderStepped:Connect(function(dt: number)
		local camera = _camera
		if not camera then return end

		-- Suspended: someone else is driving. Park the eased velocities so handing control
		-- back does not resume a drift the player stopped asking for a minute ago.
		if _suspended then
			_moveVel   = Vector3.zero
			_yawVel    = 0
			_scrollVel = 0
			_heightVel = 0
			_lastMouse = UserInputService:GetMouseLocation()
			return
		end

		local glide = _glide
		if glide then
			glide.t += dt
			local a = math.clamp(glide.t / glide.dur, 0, 1)
			camera.CFrame = glide.from:Lerp(glide.toCf, 1 - (1 - a) ^ 3)
			_lastMouse = UserInputService:GetMouseLocation()
			if a >= 1 then
				_glide = nil
				FreeCamController.setCameraState(glide.to)
			end
			return
		end

		local mouse = UserInputService:GetMouseLocation()
		local delta = mouse - _lastMouse
		_lastMouse = mouse

		-- FOLLOW: chase a moving part until the player presses a move key.
		-- Block all camera input while a UI panel is open
		if isAnyPanelOpen() then
			_moveVel   = Vector3.zero
			_yawVel    = 0
			_scrollVel = 0
			_heightVel = 0
			_lastMouse = mouse
			return
		end

		local followPart = _followPart
		if followPart then
			if not followPart.Parent then
				_followPart = nil
			elseif anyMoveKey() then
				_followPart = nil
			else
				local tp = followPart.Position
				local face = followPart.CFrame.LookVector
				local flat = Vector3.new(face.X, 0, face.Z)
				flat = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, 1)
				local want = tp - flat * FOLLOW_BACK + Vector3.new(0, FOLLOW_UP, 0)
				_pos = _pos:Lerp(want, clampN(FOLLOW_LERP * dt, 0, 1))
				aimAt(tp)
				clampPos()
				camera.CFrame = buildCFrame()
				return
			end
		end

		if _middleDown then
			-- Middle drag: look around. Full 360° yaw + pitch, and the only mouse-look there is.
			local sens = MOUSE_SENS * _sensMult
			_yaw   = _yaw   - delta.X * sens
			_pitch = clampN(_pitch - delta.Y * sens, PITCH_MIN, PITCH_MAX)
		end

		-- Scroll zoom: ease out from accumulated velocity
		if math.abs(_scrollVel) > 0.1 then
			local look = -buildCFrame().ZVector
			_pos = _pos + look * (_scrollVel * dt * SCROLL_ACCEL)
			_scrollVel = _scrollVel * math.max(0, 1 - SCROLL_ACCEL * dt)
		end

		-- R/F: smooth vertical movement
		local heightTarget = 0
		if Settings.isDown(_bindRise) then heightTarget =  HEIGHT_SPEED * _camSpeedMult * altitudeMult() end
		if Settings.isDown(_bindSink) then heightTarget = -HEIGHT_SPEED * _camSpeedMult * altitudeMult() end
		_heightVel = _heightVel + (heightTarget - _heightVel) * math.min(HEIGHT_ACCEL * dt, 1)
		if math.abs(_heightVel) > 0.1 then
			_pos = _pos + Vector3.yAxis * (_heightVel * dt)
			cancelAuto()
		end

		-- Q/E: smooth yaw rotation with ease-in/out
		local rotTarget = 0
		if Settings.isDown(_bindRotL) then rotTarget =  KEY_ROT_SPEED * _rotSpeedMult end
		if Settings.isDown(_bindRotR) then rotTarget = -KEY_ROT_SPEED * _rotSpeedMult end
		_yawVel = _yawVel + (rotTarget - _yawVel) * math.min(KEY_ROT_ACCEL * dt, 1)
		if math.abs(_yawVel) > 0.01 then
			_yaw = _yaw + _yawVel * dt
			cancelAuto()
		end

		local look, right = lookAndRight()
		local moveDir = Vector3.zero
		if Settings.isDown(_bindForward) then moveDir = moveDir + look end
		if Settings.isDown(_bindBack) then moveDir = moveDir - look end
		if Settings.isDown(_bindLeft) then moveDir = moveDir - right end
		if Settings.isDown(_bindRight) then moveDir = moveDir + right end

		-- Edge scrolling (Settings > Input): cursor resting at a screen edge pans
		-- the camera. Skipped while orbiting so drag-to-edge doesn't also pan.
		if _edgeScroll and _windowFocused and not _middleDown then
			local vp = camera.ViewportSize
			if mouse.X <= EDGE_SCROLL_BAND then
				moveDir = moveDir - right
			elseif mouse.X >= vp.X - EDGE_SCROLL_BAND then
				moveDir = moveDir + right
			end
			if mouse.Y <= EDGE_SCROLL_BAND then
				moveDir = moveDir + look
			elseif mouse.Y >= vp.Y - EDGE_SCROLL_BAND then
				moveDir = moveDir - look
			end
		end

		local speed = BASE_SPEED * _camSpeedMult * altitudeMult()
			* (if Settings.isActionDown("CamFastMove") then BOOST_MULT else 1)
		local moveTarget = if moveDir.Magnitude > 0 then moveDir.Unit * speed else Vector3.zero
		_moveVel = _moveVel + (moveTarget - _moveVel) * math.min(MOVE_ACCEL * dt, 1)
		if _moveVel.Magnitude > 0.1 then
			cancelAuto()
			_pos = _pos + _moveVel * dt
		end

		-- FOCUS: glide toward the framing vantage, then release once we arrive.
		local vantage = _focusVantage
		local goal = _focusGoal
		if vantage and goal then
			_pos = _pos:Lerp(vantage, clampN(FOCUS_LERP * dt, 0, 1))
			aimAt(goal)
			if (_pos - vantage).Magnitude < FOCUS_DONE then
				_focusGoal = nil
				_focusVantage = nil
			end
		end

		clampPos()
		camera.CFrame = buildCFrame()
	end)

	local _charRemovingConn: RBXScriptConnection
	_charRemovingConn = player.CharacterRemoving:Connect(function()
		_renderConn:Disconnect()
		_inputBeganConn:Disconnect()
		_inputChangedConn:Disconnect()
		_inputEndedConn:Disconnect()
		_cameraChangedConn:Disconnect()
		_charRemovingConn:Disconnect()
		_started = false
	end)
end

return FreeCamController