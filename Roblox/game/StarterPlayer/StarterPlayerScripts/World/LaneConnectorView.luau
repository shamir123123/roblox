--!strict

local LaneConnectorView = {}
local _started = false

function LaneConnectorView.Start()
	if _started then return end
	_started = true
	local Players = game:GetService("Players")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local UserInputService = game:GetService("UserInputService")
	local Workspace = game:GetService("Workspace")
	local RunService = game:GetService("RunService")

	local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
	local uiFolder = script.Parent.Parent:WaitForChild("UI")
	-- Rides the same UIScale as CityUI, so this gui's banner and side panel shrink in step
	-- with the scaled HUD instead of drifting across it on smaller viewports.
	local HudScale = require(uiFolder:WaitForChild("HudScale"))
	local UITheme = require(uiFolder:WaitForChild("Theme"))
	local PanelSlots = require(uiFolder:WaitForChild("PanelSlots"))
	-- Panel chrome from the shared Kit, so this panel is the same glass as every other one.
	local Glass = require(uiFolder:WaitForChild("Kit"):WaitForChild("Glass"))
	local LOD = require(ReplicatedStorage.Shared.LOD)

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))
	local syncTurnRemote = Net:WaitForRemote("SyncIntersectionTurnSettings") :: RemoteEvent
	local syncLaneRemote = Net:WaitForRemote("SyncIntersectionLanePaths") :: RemoteEvent
	local syncNodesRemote = Net:WaitForRemote("SyncNodes") :: RemoteEvent
	local setTurnRemote = Net:WaitForRemote("RequestSetIntersectionTurn") :: RemoteEvent
	local setLaneTurnRemote = Net:WaitForRemote("RequestSetIntersectionLaneTurn") :: RemoteEvent
	local setConnRemote = Net:WaitForRemote("RequestSetIntersectionConnection") :: RemoteEvent
	local resetConnRemote = Net:WaitForRemote("RequestResetIntersectionConnections") :: RemoteEvent
	local syncLaneChangeRemote = Net:WaitForRemote("SyncLaneChangeGates") :: RemoteEvent
	local setLaneChangeConnRemote = Net:WaitForRemote("RequestSetLaneChangeConnection") :: RemoteEvent

	if not (syncTurnRemote and syncLaneRemote and syncNodesRemote and setTurnRemote and setLaneTurnRemote and setConnRemote and resetConnRemote and syncLaneChangeRemote and setLaneChangeConnRemote) then
		warn("[LaneConnectorView] required remotes missing -- aborting")
		_started = false
		do return end
	end

	-- Panel chrome is the shared Theme's, so this tool is restyled by whatever restyles the
	-- HUD. The lane colours below it are CONTENT (which movement, allowed or not) and keep
	-- their own hues, exactly as Theme's own header describes.
	local COL_TEXT = UITheme.Color.TextPrimary
	local COL_MUTED = UITheme.Color.TextSecondary
	local COL_BTN = UITheme.Color.BgRaised
	local COL_ON = Color3.fromRGB(31, 54, 35)
	local COL_GREEN = Color3.fromRGB(80, 230, 122)
	local COL_ORANGE = Color3.fromRGB(255, 148, 51)
	local COL_OUT = Color3.fromRGB(244, 244, 248)
	local COL_NODE = Color3.fromRGB(150, 150, 158)
	-- Selection halo. The HUD's own accent, not a cyan of this tool's invention: cyan chrome
	-- is banned project-wide (see the SnapConstants indicator palette). Shares this with
	-- NodeToolView so the two junction tools still read as siblings.
	local COL_PICK = UITheme.Color.Accent
	local COL_RUBBER = Color3.fromRGB(255, 255, 255)
	-- Tool-is-on. The HUD accent, like every other active control -- it used to be a red
	-- that nothing else in the game uses.
	local COL_ACTIVE = UITheme.Color.Accent

	local LANE_PALETTE = {
		Color3.fromRGB(235, 70, 70),   Color3.fromRGB(70, 150, 255),  Color3.fromRGB(80, 210, 110),
		Color3.fromRGB(240, 195, 60),  Color3.fromRGB(185, 110, 245), Color3.fromRGB(245, 130, 55),
		Color3.fromRGB(60, 215, 215),  Color3.fromRGB(240, 110, 190), Color3.fromRGB(120, 235, 60),
		Color3.fromRGB(255, 90, 140),  Color3.fromRGB(60, 120, 235),  Color3.fromRGB(250, 235, 95),
		Color3.fromRGB(150, 230, 255), Color3.fromRGB(255, 160, 90),  Color3.fromRGB(170, 170, 255),
		Color3.fromRGB(110, 245, 180),
	}

	local _laneColors: { [string]: Color3 } = {}
	local _laneOrder: { [string]: number } = {}

	local function laneColor(edgeId: string): Color3
		local mapped = _laneColors[edgeId]
		if mapped then return mapped end

		local h = 0
		for i = 1, #edgeId do
			h = (h * 31 + edgeId:byte(i)) % 2147483647
		end

		return LANE_PALETTE[(h % #LANE_PALETTE) + 1]
	end

	local MOVE_ORDER = { "left", "right", "straight", "uturn" }
	local MOVE_LABELS: { [string]: string } = {
		left = "Left",
		right = "Right",
		straight = "Straight",
		uturn = "U-turn",
	}

	local _viewActive = false
	local _intersections: { [number]: any } = {}
	local _lanePaths: { [number]: any } = {}
	local _laneChangeGates: { any } = {}
	local _nodePositions: { Vector3 } = {}
	local _nodePositionsById: { [number]: Vector3 } = {}
	local _selectedNodeId: number? = nil
	local _pickInEdge: string? = nil
	local _selectedGateId: string? = nil
	local _pickGateEdge: string? = nil
	local _drag: { fromEdgeId: string, fromPos: Vector3, line: BasePart }? = nil
	local _iconButton: GuiButton? = nil
	local _iconBaseColor: Color3? = nil

	local _nodeDotPool: { BasePart } = {}
	local _laneDotPool: { BasePart } = {}
	local _hitDotPool: { BasePart } = {}
	local _haloPool: { BasePart } = {}
	local _linkPool: { BasePart } = {}
	local _gateDotPool: { BasePart } = {}
	local _gateHitPool: { BasePart } = {}
	local _gateLinkPool: { BasePart } = {}
	local _nodeDotCount = 0
	local _laneDotCount = 0
	local _hitDotCount = 0
	local _haloCount = 0
	local _linkCount = 0
	local _gateDotCount = 0
	local _gateHitCount = 0
	local _gateLinkCount = 0

	local function evictPool(pool: { BasePart }, keepCount: number)
		for i = keepCount + 1, #pool do
			pool[i]:Destroy()
			pool[i] = nil :: any
		end

		if keepCount < #pool then
			for i = keepCount + 1, #pool do
				pool[i] = nil :: any
			end
		end
	end

	local _dots: Folder
	local _links: Folder
	local _dragFolder: Folder
	local _gui: ScreenGui
	local _panel: Frame
	local _banner: Frame
	local _title: TextLabel
	local _modeLabel: TextLabel
	local _resetBtn: TextButton
	local _moveButtons: { [string]: TextButton } = {}

	local function corner(parent: Instance, radius: number)
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, radius)
		c.Parent = parent
	end

	local function padding(parent: Instance, px: number)
		local p = Instance.new("UIPadding")
		p.PaddingTop = UDim.new(0, px)
		p.PaddingBottom = UDim.new(0, px)
		p.PaddingLeft = UDim.new(0, px)
		p.PaddingRight = UDim.new(0, px)
		p.Parent = parent
	end

	local function makeLabel(parent: Instance, text: string, size: number, color: Color3): TextLabel
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.FontFace = UITheme.Font.Label
		l.Text = text
		l.TextSize = size
		l.TextColor3 = color
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.Parent = parent
		return l
	end

	-- Hand-built rather than a Kit capsule: a movement row's fill states are SEMANTIC
	-- (green = the turn is allowed, red = it is not), and Kit's selected state is the
	-- accent. Everything else about it -- type, fill, radius, hairline -- is Theme's.
	local function makeButton(parent: Instance, text: string): TextButton
		local b = Instance.new("TextButton")
		b.AutoButtonColor = false
		b.BackgroundColor3 = COL_BTN
		b.FontFace = UITheme.Font.Label
		b.Text = text
		b.TextColor3 = COL_TEXT
		b.TextSize = UITheme.TextSize.XS
		b.Size = UDim2.new(1, 0, 0, 28)
		b.Parent = parent
		corner(b, UITheme.Radius.SM)
		local edge = Instance.new("UIStroke")
		edge.Color = UITheme.Color.StrokeSoft
		edge.Thickness = UITheme.StrokeWidth.Thin
		edge.Parent = b
		return b
	end

	local function elevated(p: Vector3, off: number): Vector3
		return Vector3.new(p.X, p.Y + off, p.Z)
	end

	-- Read once per render pass and handed down, so one pass costs one camera read
	-- rather than one per junction.
	local function cameraEye(): Vector3?
		local camera = Workspace.CurrentCamera
		return camera and camera.CFrame.Position
	end

	local BEAM_TEXTURE = RoadConstants.TRANSIT_ROUTE_ARROW_TEXTURE

	-- A link part is only the click target now; the ribbon you see is a Beam riding on it.
	-- FaceCamera keeps it readable at any camera angle, so there is no attachment-roll maths,
	-- and the scrolling arrow texture states which way the connection runs.
	local function beamOn(part: BasePart, len: number, width: number, color: Color3, alpha: number)
		local beam = part:FindFirstChildOfClass("Beam")

		if not beam then
			local at0 = Instance.new("Attachment")
			at0.Parent = part
			local at1 = Instance.new("Attachment")
			at1.Parent = part

			local made = Instance.new("Beam")
			made.Attachment0 = at0
			made.Attachment1 = at1
			made.FaceCamera = true
			made.LightInfluence = 0
			made.Segments = 1
			made.Texture = BEAM_TEXTURE
			made.TextureMode = Enum.TextureMode.Wrap
			made.TextureLength = 5
			made.TextureSpeed = 1.1
			made.Parent = part
			beam = made
		end

		local live = beam :: Beam
		local half = math.max(len, 0.05) * 0.5
		local a0 = live.Attachment0 :: Attachment
		local a1 = live.Attachment1 :: Attachment
		-- The part is lookAt(mid, b), so its -Z faces b: A0 sits at the from-end, A1 at the
		-- to-end, and the texture scrolls the way traffic goes.
		a0.Position = Vector3.new(0, 0, half)
		a1.Position = Vector3.new(0, 0, -half)
		live.Width0 = width
		live.Width1 = width
		live.Color = ColorSequence.new(color)
		live.Transparency = NumberSequence.new(alpha)
		live.Enabled = true
	end

	local function isConnected(nodeId: number, fromEdgeId: string, toEdgeId: string): boolean
		local lane = _lanePaths[nodeId]
		if not lane then return false end

		for _, c in lane.connections do
			if c.fromEdgeId == fromEdgeId and c.toEdgeId == toEdgeId then
				return c.allowed == true
			end
		end

		return false
	end

	local function isGateConnected(gateId: string, fromEdgeId: string, toEdgeId: string): boolean
		for _, gate in _laneChangeGates do
			if gate.id == gateId then
				for _, conn in gate.connections do
					if conn.fromEdgeId == fromEdgeId and conn.toEdgeId == toEdgeId then
						return conn.allowed == true
					end
				end
			end
		end

		return false
	end

	local refreshPanel: () -> ()
	local renderDots: () -> ()
	local renderLinks: () -> ()
	local handleDotClick: (nodeId: number, edgeId: string, kind: string) -> ()
	local handleLineClick: (nodeId: number, fromEdgeId: string, toEdgeId: string) -> ()
	local handleGateDotClick: (gateId: string, edgeId: string, kind: string) -> ()
	local handleGateLineClick: (gateId: string, fromEdgeId: string, toEdgeId: string) -> ()
	local _renderScheduled = false
	local _renderQueued = false
	local _lastRenderAt = 0
	local MIN_RENDER_INTERVAL = 1 / 30

	local function requestRender()
		if _renderScheduled then
			_renderQueued = true
			return
		end

		local now = os.clock()
		local delaySec = math.max(0, MIN_RENDER_INTERVAL - (now - _lastRenderAt))
		_renderScheduled = true

		task.delay(delaySec, function()
			_renderScheduled = false
			_lastRenderAt = os.clock()

			if _viewActive then
				renderDots()
				renderLinks()
				refreshPanel()

				-- Parking culled parts at Parent = nil frees draw calls, not memory, and memory
				-- is the point of the ladder. Renders are throttled to 1/30, so destroying the
				-- overshoot here is cheap.
				evictPool(_nodeDotPool, _nodeDotCount)
				evictPool(_laneDotPool, _laneDotCount)
				evictPool(_hitDotPool, _hitDotCount)
				evictPool(_haloPool, _haloCount)
				evictPool(_linkPool, _linkCount)
				evictPool(_gateDotPool, _gateDotCount)
				evictPool(_gateHitPool, _gateHitCount)
				evictPool(_gateLinkPool, _gateLinkCount)
			end

			if _renderQueued then
				_renderQueued = false
				requestRender()
			end
		end)
	end

	local DISC_THICK = 0.15
	local DISC_LIFT = 0.5

	local function discCFrame(pos: Vector3): CFrame
		return CFrame.new(elevated(pos, DISC_LIFT)) * CFrame.Angles(0, 0, math.rad(90))
	end

	local function pooledCylinder(pool: { BasePart }, idx: number, parent: Instance, queryable: boolean): BasePart
		local part = pool[idx]

		if part then
			part.Parent = parent
			part.Transparency = 0
			part.CanQuery = queryable
			part.CanTouch = false
			part.CanCollide = false
			part.CastShadow = false
			return part
		end

		part = Instance.new("Part")
		part.Shape = Enum.PartType.Cylinder
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CastShadow = false
		part.CanQuery = queryable
		part.Parent = parent
		pool[idx] = part

		return part
	end

	local function ensureClickDetector(part: BasePart, cb: (n: number, a: string, b: string) -> ())
		local cd = part:FindFirstChildOfClass("ClickDetector")

		if not cd then
			cd = Instance.new("ClickDetector")
			cd.MaxActivationDistance = 1000
			cd.CursorIcon = ""
			cd.Parent = part

			cd.MouseClick:Connect(function()
				local nodeId = part:GetAttribute("NodeId")
				local a = part:GetAttribute("A")
				local b = part:GetAttribute("B")

				if typeof(nodeId) == "number" and typeof(a) == "string" and typeof(b) == "string" then
					cb(nodeId, a, b)
				end
			end)
		end
	end

	local function ensureGateDotClickDetector(part: BasePart)
		local cd = part:FindFirstChildOfClass("ClickDetector")

		if not cd then
			cd = Instance.new("ClickDetector")
			cd.MaxActivationDistance = 1000
			cd.CursorIcon = ""
			cd.Parent = part

			cd.MouseClick:Connect(function()
				local gateId = part:GetAttribute("GateId")
				local edgeId = part:GetAttribute("EdgeId")
				local kind = part:GetAttribute("Kind")

				if typeof(gateId) == "string" and typeof(edgeId) == "string" and typeof(kind) == "string" then
					handleGateDotClick(gateId, edgeId, kind)
				end
			end)
		end
	end

	local function ensureGateLineClickDetector(part: BasePart)
		local cd = part:FindFirstChildOfClass("ClickDetector")

		if not cd then
			cd = Instance.new("ClickDetector")
			cd.MaxActivationDistance = 1000
			cd.CursorIcon = ""
			cd.Parent = part

			cd.MouseClick:Connect(function()
				local gateId = part:GetAttribute("GateId")
				local fromEdgeId = part:GetAttribute("FromEdgeId")
				local toEdgeId = part:GetAttribute("ToEdgeId")

				if typeof(gateId) == "string" and typeof(fromEdgeId) == "string" and typeof(toEdgeId) == "string" then
					handleGateLineClick(gateId, fromEdgeId, toEdgeId)
				end
			end)
		end
	end

	local function drawNodeDot(pos: Vector3)
		_nodeDotCount += 1

		local part = pooledCylinder(_nodeDotPool, _nodeDotCount, _dots, false)
		part.Name = "NodeDot"
		part.Material = Enum.Material.SmoothPlastic
		part.Color = COL_NODE
		part.Size = Vector3.new(DISC_THICK, 1.0, 1.0)
		part.CFrame = discCFrame(pos)
	end

	local function drawLaneDot(dot: any, nodeId: number, picked: boolean)
		local isIn = dot.kind == "in"
		local diameter = if isIn then 2.6 else 2.1

		if picked then
			diameter *= 1.4
		end

		if picked then
			_haloCount += 1

			local halo = pooledCylinder(_haloPool, _haloCount, _dots, false)
			halo.Name = "PickHalo"
			halo.Material = Enum.Material.Neon
			halo.Color = COL_PICK
			halo.Transparency = 0.4

			local hd = diameter * 1.55

			halo.Size = Vector3.new(DISC_THICK * 0.6, hd, hd)
			halo.CFrame = CFrame.new(elevated(dot.position, DISC_LIFT - 0.03)) * CFrame.Angles(0, 0, math.rad(90))
		end

		_laneDotCount += 1

		local part = pooledCylinder(_laneDotPool, _laneDotCount, _dots, false)
		part.Name = `LaneDot_{dot.edgeId}`
		part.Material = Enum.Material.SmoothPlastic
		part.Color = if isIn then laneColor(dot.edgeId) else COL_OUT
		part.Size = Vector3.new(DISC_THICK, diameter, diameter)
		part.CFrame = discCFrame(dot.position)

		_hitDotCount += 1

		local hit = pooledCylinder(_hitDotPool, _hitDotCount, _dots, true)
		hit.Name = "LaneDotHit"
		hit.Material = Enum.Material.SmoothPlastic
		hit.Transparency = 1

		local hitD = diameter + 4

		hit.Size = Vector3.new(2, hitD, hitD)
		hit.CFrame = CFrame.new(elevated(dot.position, DISC_LIFT + 0.5)) * CFrame.Angles(0, 0, math.rad(90))
		hit:SetAttribute("NodeId", nodeId)
		hit:SetAttribute("A", dot.edgeId)
		hit:SetAttribute("B", dot.kind)

		ensureClickDetector(hit, function(n, edge, kind)
			handleDotClick(n, edge, kind)
		end)
	end

	local function drawGateDot(gate: any, dot: any, picked: boolean)
		local isIn = dot.kind == "in"
		local diameter = if isIn then 1.7 else 1.45

		if picked then
			diameter *= 1.35
		end

		if picked then
			_haloCount += 1

			local halo = pooledCylinder(_haloPool, _haloCount, _dots, false)
			halo.Name = "LaneChangePickHalo"
			halo.Material = Enum.Material.Neon
			halo.Color = COL_PICK
			halo.Transparency = 0.4

			local hd = diameter * 1.55

			halo.Size = Vector3.new(DISC_THICK * 0.6, hd, hd)
			halo.CFrame = CFrame.new(elevated(dot.position, DISC_LIFT - 0.03)) * CFrame.Angles(0, 0, math.rad(90))
		end

		_gateDotCount += 1

		local part = pooledCylinder(_gateDotPool, _gateDotCount, _dots, false)
		part.Name = "LaneChangeDot"
		part.Material = Enum.Material.SmoothPlastic
		part.Color = if isIn then laneColor(dot.edgeId) else COL_OUT
		part.Size = Vector3.new(DISC_THICK, diameter, diameter)
		part.CFrame = discCFrame(dot.position)

		_gateHitCount += 1

		local hit = pooledCylinder(_gateHitPool, _gateHitCount, _dots, true)
		hit.Name = "LaneChangeDotHit"
		hit.Material = Enum.Material.SmoothPlastic
		hit.Transparency = 1
		hit.Size = Vector3.new(2, diameter + 3.2, diameter + 3.2)
		hit.CFrame = CFrame.new(elevated(dot.position, DISC_LIFT + 0.5)) * CFrame.Angles(0, 0, math.rad(90))
		hit:SetAttribute("GateId", gate.id)
		hit:SetAttribute("EdgeId", dot.edgeId)
		hit:SetAttribute("Kind", dot.kind)

		ensureGateDotClickDetector(hit)
	end

	local function drawGateLink(gate: any, conn: any)
		if conn.allowed ~= true then return end

		local pts: { Vector3 } = {}

		if typeof(conn.points) == "table" and #conn.points >= 2 then
			pts = conn.points
		else
			local startPos, endPos

			for _, dot in gate.dots do
				if dot.edgeId == conn.fromEdgeId and dot.kind == "in" then
					startPos = dot.position
				elseif dot.edgeId == conn.toEdgeId and dot.kind == "out" then
					endPos = dot.position
				end
			end

			if startPos and endPos then
				pts = { startPos, endPos }
			else
				return
			end
		end

		for i = 1, #pts - 1 do
			_gateLinkCount += 1

			local part = _gateLinkPool[_gateLinkCount]

			if not part then
				part = Instance.new("Part")
				part.Anchored = true
				part.CanCollide = false
				part.CanTouch = false
				part.CastShadow = false
				part.CanQuery = true
				part.Material = Enum.Material.SmoothPlastic
				_gateLinkPool[_gateLinkCount] = part
				ensureGateLineClickDetector(part)
			end

			part.Parent = _links
			part.Name = "LaneChangeRibbon"
			part.Transparency = 1

			local a = elevated(pts[i], 0.34)
			local b = elevated(pts[i + 1], 0.34)
			local delta = b - a
			local len = delta.Magnitude

			part.Size = Vector3.new(1.6, 0.14, math.max(len, 0.05))
			part.CFrame = if len > 1e-3 then CFrame.lookAt(a + delta * 0.5, b) else CFrame.new(a)
			beamOn(part, len, 0.72, laneColor(conn.fromEdgeId), 0.25)

			part:SetAttribute("GateId", gate.id)
			part:SetAttribute("FromEdgeId", conn.fromEdgeId)
			part:SetAttribute("ToEdgeId", conn.toEdgeId)
		end
	end

	local function drawLink(conn: any, color: Color3, picked: boolean, dimmed: boolean, tier: number, lod: number, tol: number)
		local pts: { Vector3 } = {}

		if typeof(conn.points) == "table" and #conn.points >= 2 then
			pts = conn.points
		else
			local lane = _lanePaths[conn.nodeId]

			if lane then
				local startPos, endPos

				for _, dot in lane.dots do
					if dot.edgeId == conn.fromEdgeId and dot.kind == "in" then
						startPos = dot.position
					elseif dot.edgeId == conn.toEdgeId and dot.kind == "out" then
						endPos = dot.position
					end
				end

				if startPos and endPos then
					pts = { startPos, endPos }
				else
					return
				end
			else
				return
			end
		end

		local width = if picked then 1.1 elseif dimmed then 0.5 else 0.8
		local lift = (if picked then 0.5 else 0.3) + tier * 0.03
		local beamed = lod <= LOD.MID
		-- Thin the path to what the screen can resolve, rather than keeping every Nth point:
		-- on a turn, every-Nth is as likely to cut the apex off as to drop a redundant station.
		if tol > 0 and #pts > 2 then
			pts = LOD.simplify(pts, tol)
		end

		for i = 1, #pts - 1 do
			_linkCount += 1

			local p = _linkPool[_linkCount]

			if not p then
				p = Instance.new("Part")
				p.Anchored = true
				p.CanCollide = false
				p.CanTouch = false
				p.CastShadow = false
				p.CanQuery = true
				p.Material = Enum.Material.SmoothPlastic
				_linkPool[_linkCount] = p

				ensureClickDetector(p, function(nodeId, fromId, toId)
					handleLineClick(nodeId, fromId, toId)
				end)
			end

			p.Parent = _links
			p.Name = "LaneLink"

			local a = elevated(pts[i], lift)
			local b = elevated(pts[i + 1], lift)
			local delta = b - a
			local len = delta.Magnitude

			p.Size = Vector3.new(if beamed then math.max(width, 1.6) else width, 0.14, math.max(len, 0.05))

			if len > 1e-3 then
				p.CFrame = CFrame.lookAt(a + delta * 0.5, b)
			else
				p.CFrame = CFrame.new(a)
			end

			if beamed then
				p.Transparency = 1
				beamOn(p, len, width, color, if dimmed then 0.6 else 0.1)
			else
				-- Far out, a beam plus two attachments per piece costs more than the ribbon is
				-- worth. The part is the ribbon.
				p.Color = color
				p.Transparency = if dimmed then 0.45 else 0

				local spent = p:FindFirstChildOfClass("Beam")
				if spent then
					spent.Enabled = false
				end
			end

			p:SetAttribute("NodeId", conn.nodeId)
			p:SetAttribute("A", conn.fromEdgeId)
			p:SetAttribute("B", conn.toEdgeId)
		end
	end

	renderDots = function()
		if not _viewActive then return end

		_nodeDotCount = 0
		_laneDotCount = 0
		_hitDotCount = 0
		_haloCount = 0
		_gateDotCount = 0
		_gateHitCount = 0

		local eye = cameraEye()

		for _, pos in _nodePositions do
			if LOD.tierAt(pos, eye) < LOD.CULL then
				drawNodeDot(pos)
			end
		end

		for nodeId, lane in _lanePaths do
			-- One level for the whole junction: its lanes are studs apart, and a junction that
			-- half-populates reads as a bug rather than as distance. No anchor means draw --
			-- unplaceable geometry must never be silently culled.
			local anchor = lane.position or _nodePositionsById[nodeId]

			-- The discs are the click targets. Past MID they are a few pixels across and
			-- cannot be hit, so neither they nor their hit cylinders get built.
			if not anchor or LOD.tierAt(anchor, eye) <= LOD.MID then
				for _, dot in lane.dots do
					drawLaneDot(dot, nodeId, dot.edgeId == _pickInEdge)
				end
			end
		end

		for _, gate in _laneChangeGates do
			local anchor = gate.dots[1] and gate.dots[1].position

			if anchor and LOD.tierAt(anchor, eye) <= LOD.MID then
				for _, dot in gate.dots do
					local picked = gate.id == _selectedGateId and dot.kind == "in" and dot.edgeId == _pickGateEdge
					drawGateDot(gate, dot, picked)
				end
			end
		end

		for i = _nodeDotCount + 1, #_nodeDotPool do
			_nodeDotPool[i].Parent = nil
		end

		for i = _laneDotCount + 1, #_laneDotPool do
			_laneDotPool[i].Parent = nil
		end

		for i = _hitDotCount + 1, #_hitDotPool do
			_hitDotPool[i].Parent = nil
		end

		for i = _haloCount + 1, #_haloPool do
			_haloPool[i].Parent = nil
		end

		for i = _gateDotCount + 1, #_gateDotPool do
			_gateDotPool[i].Parent = nil
		end

		for i = _gateHitCount + 1, #_gateHitPool do
			_gateHitPool[i].Parent = nil
		end
	end

	renderLinks = function()
		if not _viewActive then return end

		_linkCount = 0
		_gateLinkCount = 0

		local pick = _pickInEdge

		local eye = cameraEye()

		for nodeId, lane in _lanePaths do
			local anchor = lane.position or _nodePositionsById[nodeId]
			local lod = if anchor then LOD.tierAt(anchor, eye) else LOD.NEAR
			-- One tolerance per junction: every link inside it is within a few studs of the rest.
			local tol = if anchor then LOD.toleranceStuds((( eye or anchor) - anchor).Magnitude) else 0

			if lod < LOD.CULL then
				for _, conn in lane.connections do
					if conn.allowed == true then
						local isPicked = pick ~= nil and conn.fromEdgeId == pick and _selectedNodeId == nodeId
						local dimmed = pick ~= nil and not isPicked
						local tier = _laneOrder[conn.fromEdgeId] or 0

						drawLink(conn, laneColor(conn.fromEdgeId), isPicked, dimmed, tier, lod, tol)
					end
				end
			end
		end

		for _, gate in _laneChangeGates do
			local anchor = gate.dots[1] and gate.dots[1].position

			-- A lane-change gate is a fine-grained hint; past MID it is noise.
			if anchor and LOD.tierAt(anchor, eye) <= LOD.MID then
				for _, conn in gate.connections do
					drawGateLink(gate, conn)
				end
			end
		end

		for i = _linkCount + 1, #_linkPool do
			_linkPool[i].Parent = nil
		end

		for i = _gateLinkCount + 1, #_gateLinkPool do
			_gateLinkPool[i].Parent = nil
		end
	end

	refreshPanel = function()
		if not _viewActive then
			_panel.Visible = false
			return
		end

		local nodeId = _selectedNodeId
		local info = nodeId and _intersections[nodeId]

		if not nodeId or not info then
			_panel.Visible = false
			return
		end

		_panel.Visible = true
		_title.Text = `INTERSECTION {nodeId}`

		if info.manual then
			_modeLabel.Text = "MANUAL — your edits"
			_modeLabel.TextColor3 = COL_ORANGE
			_resetBtn.Visible = true

			for _, b in _moveButtons do
				b.Visible = false
			end

			return
		end

		_resetBtn.Visible = false

		local pick = _pickInEdge

		if not pick then
			_modeLabel.Text = "Pick a lane — click a coloured disc"
			_modeLabel.TextColor3 = COL_MUTED

			for _, b in _moveButtons do
				b.Visible = false
			end

			return
		end

		_modeLabel.Text = "Editing this lane only"
		_modeLabel.TextColor3 = COL_GREEN

		local lane = _lanePaths[nodeId]
		local present: { [string]: boolean } = {}
		local allowed: { [string]: boolean } = {}

		if lane then
			for _, conn in lane.connections do
				if conn.fromEdgeId == pick and typeof(conn.movement) == "string" then
					present[conn.movement] = true

					if conn.allowed == true then
						allowed[conn.movement] = true
					end
				end
			end
		end

		for _, key in MOVE_ORDER do
			local b = _moveButtons[key]

			if present[key] then
				b.Visible = true

				local on = allowed[key] == true

				b.Text = `{MOVE_LABELS[key]}: {if on then "ON" else "OFF"}`
				b.BackgroundColor3 = if on then COL_ON else COL_BTN
				b.TextColor3 = if on then COL_GREEN else COL_MUTED
			else
				b.Visible = false
			end
		end
	end

	local function pickLane(nodeId: number?, edgeId: string?)
		_selectedNodeId = nodeId
		_pickInEdge = edgeId
		_selectedGateId = nil
		_pickGateEdge = nil
		requestRender()
	end

	local function toggleConn(nodeId: number, fromIn: string, toOut: string)
		local connected = isConnected(nodeId, fromIn, toOut)
		setConnRemote:FireServer(nodeId, fromIn, toOut, not connected)
	end

	handleDotClick = function(nodeId: number, edgeId: string, kind: string)
		if not _viewActive then return end

		if kind == "in" then
			if _pickInEdge == edgeId then
				pickLane(nodeId, nil)
			else
				pickLane(nodeId, edgeId)
			end
		else
			if _pickInEdge and _selectedNodeId == nodeId then
				toggleConn(nodeId, _pickInEdge, edgeId)
			else
				_selectedNodeId = nodeId
				requestRender()
			end
		end
	end

	handleLineClick = function(nodeId: number, fromEdgeId: string, toEdgeId: string)
		if not _viewActive then return end

		setConnRemote:FireServer(nodeId, fromEdgeId, toEdgeId, false)
	end

	handleGateDotClick = function(gateId: string, edgeId: string, kind: string)
		if not _viewActive then return end

		_selectedNodeId = nil
		_pickInEdge = nil

		if kind == "in" then
			if _selectedGateId == gateId and _pickGateEdge == edgeId then
				_selectedGateId = nil
				_pickGateEdge = nil
			else
				_selectedGateId = gateId
				_pickGateEdge = edgeId
			end
		elseif _selectedGateId == gateId and _pickGateEdge then
			local connected = isGateConnected(gateId, _pickGateEdge, edgeId)
			setLaneChangeConnRemote:FireServer(gateId, _pickGateEdge, edgeId, not connected)
		else
			_selectedGateId = gateId
		end

		requestRender()
	end

	handleGateLineClick = function(gateId: string, fromEdgeId: string, toEdgeId: string)
		if not _viewActive then return end

		setLaneChangeConnRemote:FireServer(gateId, fromEdgeId, toEdgeId, false)
	end

	local function updateButtonAppearance()
		local btn = _iconButton
		if not btn then return end

		local s = btn:FindFirstChildWhichIsA("UIStroke")

		if s then
			s.Color = COL_ACTIVE
			s.Thickness = 2
			s.Enabled = _viewActive
		end

		if _viewActive then
			btn.BackgroundColor3 = COL_ACTIVE
		elseif _iconBaseColor then
			btn.BackgroundColor3 = _iconBaseColor
		end
	end

	local function setView(active: boolean)
		_viewActive = active
		_banner.Visible = active

		if active then
			-- The node tool's banner and side panel sit at exactly these coordinates, so only
			-- one of the two can be readable at a time. Claiming the slot closes the other.
			PanelSlots.claim("toolPanel", "LaneConnector", function()
				setView(false)
			end)
			requestRender()
		else
			PanelSlots.release("toolPanel", "LaneConnector")
			_selectedNodeId = nil
			_pickInEdge = nil
			_selectedGateId = nil
			_pickGateEdge = nil
			_drag = nil

			for i = 1, #_nodeDotPool do
				_nodeDotPool[i].Parent = nil
			end

			for i = 1, #_laneDotPool do
				_laneDotPool[i].Parent = nil
			end

			for i = 1, #_hitDotPool do
				_hitDotPool[i].Parent = nil
			end

			for i = 1, #_haloPool do
				_haloPool[i].Parent = nil
			end

			for i = 1, #_linkPool do
				_linkPool[i].Parent = nil
			end

			for i = 1, #_gateDotPool do
				_gateDotPool[i].Parent = nil
			end

			for i = 1, #_gateHitPool do
				_gateHitPool[i].Parent = nil
			end

			for i = 1, #_gateLinkPool do
				_gateLinkPool[i].Parent = nil
			end

			evictPool(_nodeDotPool,  _nodeDotCount)
			evictPool(_laneDotPool,  _laneDotCount)
			evictPool(_hitDotPool,   _hitDotCount)
			evictPool(_haloPool,     _haloCount)
			evictPool(_linkPool,     _linkCount)
			evictPool(_gateDotPool,  _gateDotCount)
			evictPool(_gateHitPool,  _gateHitCount)
			evictPool(_gateLinkPool, _gateLinkCount)

			_dragFolder:ClearAllChildren()
			_panel.Visible = false
		end

		updateButtonAppearance()
	end

	local function toggleView()
		setView(not _viewActive)
	end

	local function buildGui()
		_gui = Instance.new("ScreenGui")
		_gui.Name = "LaneConnectorPanel"
		_gui.ResetOnSpawn = false
		_gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		-- Was left at the default 0, tied with three other guis; ties draw in undefined order.
		_gui.DisplayOrder = UITheme.Layer.Tool
		_gui.Parent = playerGui
		HudScale.attach(_gui)

		_banner = Instance.new("Frame")
		_banner.Name = "Banner"
		_banner.AnchorPoint = Vector2.new(0.5, 0)
		_banner.Position = UDim2.new(0.5, 0, 0, 14)
		_banner.Size = UDim2.new(0, 330, 0, 30)
		_banner.Visible = false
		_banner.Parent = _gui

		Glass.apply(_banner, UITheme.Radius.MD)

		local bl = makeLabel(_banner, "", UITheme.TextSize.XS, UITheme.Color.Brand)
		bl.FontFace = UITheme.Font.Header
		bl.RichText = true
		-- #A3A096 is Theme.Color.TextSecondary; RichText needs it as a literal.
		bl.Text = 'LANE VIEW <font color="#A3A096"> · pick coloured dot, then white dot · L to exit</font>'
		bl.Size = UDim2.fromScale(1, 1)
		bl.TextXAlignment = Enum.TextXAlignment.Center

		_panel = Instance.new("Frame")
		_panel.Name = "Panel"
		_panel.AnchorPoint = Vector2.new(1, 0.5)
		_panel.Position = UDim2.new(1, -16, 0.5, 0)
		_panel.Size = UDim2.new(0, 220, 0, 0)
		_panel.AutomaticSize = Enum.AutomaticSize.Y
		_panel.Visible = false
		_panel.Parent = _gui

		-- Same shell as the node tool's panel and the Move It panel: glass at radius 14.
		Glass.apply(_panel, 14)
		padding(_panel, 10)

		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Vertical
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 6)
		layout.Parent = _panel

		_title = makeLabel(_panel, "INTERSECTION", UITheme.TextSize.SM, UITheme.Color.Brand)
		_title.FontFace = UITheme.Font.Header
		_title.Size = UDim2.new(1, 0, 0, 20)
		_title.LayoutOrder = 1

		_modeLabel = makeLabel(_panel, "", UITheme.TextSize.XS, COL_GREEN)
		_modeLabel.FontFace = UITheme.Font.Header
		-- Grows to the copy: at theme type these strings wrap to two lines in this column.
		_modeLabel.Size = UDim2.new(1, 0, 0, 0)
		_modeLabel.AutomaticSize = Enum.AutomaticSize.Y
		_modeLabel.TextWrapped = true
		_modeLabel.LayoutOrder = 2

		for i, key in ipairs(MOVE_ORDER) do
			local b = makeButton(_panel, MOVE_LABELS[key])
			b.LayoutOrder = 2 + i
			_moveButtons[key] = b

			b.Activated:Connect(function()
				local nid = _selectedNodeId
				local pick = _pickInEdge
				if not nid or not pick then return end

				local lane = _lanePaths[nid]
				local on = false

				if lane then
					for _, conn in lane.connections do
						if conn.fromEdgeId == pick and conn.movement == key and conn.allowed == true then
							on = true
							break
						end
					end
				end

				setLaneTurnRemote:FireServer(nid, pick, key, not on)
			end)
		end

		_resetBtn = makeButton(_panel, "Reset to Auto")
		_resetBtn.LayoutOrder = 8
		_resetBtn.BackgroundColor3 = Color3.fromRGB(42, 35, 16)
		_resetBtn.Visible = false

		_resetBtn.Activated:Connect(function()
			local nid = _selectedNodeId
			if nid then
				resetConnRemote:FireServer(nid)
			end
		end)

		local help = makeLabel(_panel, "Disc = pick lane · white discs toggle turns · line removes", UITheme.TextSize.XS, COL_MUTED)
		help.Size = UDim2.new(1, 0, 0, 0)
		help.AutomaticSize = Enum.AutomaticSize.Y
		help.TextWrapped = true
		help.LayoutOrder = 9

		local close = makeButton(_panel, "Close")
		close.LayoutOrder = 10
		close.TextColor3 = COL_MUTED

		close.Activated:Connect(function()
			pickLane(nil, nil)
		end)
	end

	local function makeFolder(name: string): Folder
		local f = Instance.new("Folder")
		f.Name = name
		f.Parent = Workspace
		return f
	end

	_dots = makeFolder("LaneConnectorDots")
	_links = makeFolder("LaneConnectorLinks")
	_dragFolder = makeFolder("LaneConnectorDrag")

	buildGui()

	local _inputBeganConn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed and Settings.pressed("LaneConnector", input) then return end

		if Settings.pressed("LaneConnector", input) then
			toggleView()
		end
	end)

	-- The ladder is read at render time and renders are event-driven, so without this you
	-- keep whatever detail the camera happened to deserve at the last road edit.
	local LOD_REFRESH_STUDS = 60
	local _lastEye: Vector3? = nil

	local _lodConn = RunService.Heartbeat:Connect(function()
		if not _viewActive then return end

		local eye = cameraEye()
		if not eye then return end

		local last = _lastEye
		if last and (eye - last).Magnitude < LOD_REFRESH_STUDS then return end

		_lastEye = eye
		requestRender()
	end)

	local function unpackSyncPayload(payload: any): ({ any }, boolean)
		if typeof(payload) ~= "table" then
			return {}, false
		end

		if payload.patch == true and typeof(payload.entries) == "table" then
			return payload.entries, true
		end

		return payload, false
	end

	local _syncTurnConn = syncTurnRemote.OnClientEvent:Connect(function(payload: any)
		local entries, isPatch = unpackSyncPayload(payload)

		if not isPatch then
			_intersections = {}
		end

		for _, e in entries do
			if typeof(e.nodeId) == "number" and typeof(e.position) == "Vector3" then
				_intersections[e.nodeId] = e
			end
		end

		if _selectedNodeId and not _intersections[_selectedNodeId] then
			_selectedNodeId = nil
			_pickInEdge = nil
		end

		if _viewActive then
			requestRender()
		end
	end)

	local function rebuildLaneColors()
		table.clear(_laneColors)
		table.clear(_laneOrder)

		for _, lane in _lanePaths do
			local incoming: { string } = {}

			for _, dot in lane.dots do
				if dot.kind == "in" then
					table.insert(incoming, dot.edgeId)
				end
			end

			table.sort(incoming)

			for i, edgeId in ipairs(incoming) do
				_laneColors[edgeId] = LANE_PALETTE[((i - 1) % #LANE_PALETTE) + 1]
				_laneOrder[edgeId] = i - 1
			end
		end
	end

	local _syncLaneConn = syncLaneRemote.OnClientEvent:Connect(function(payload: any)
		local entries, isPatch = unpackSyncPayload(payload)

		if not isPatch then
			_lanePaths = {}
		end

		for _, e in entries do
			if typeof(e.nodeId) == "number" and typeof(e.dots) == "table" and typeof(e.connections) == "table" then
				_lanePaths[e.nodeId] = e
			end
		end

		rebuildLaneColors()

		if _viewActive then
			requestRender()
		end
	end)

	local _syncLaneChangeConn = syncLaneChangeRemote.OnClientEvent:Connect(function(entries: any)
		if typeof(entries) == "table" then
			if typeof(entries.full) == "boolean" then
				if entries.full then
					_laneChangeGates = {}

					if typeof(entries.gates) == "table" then
						for _, gate in entries.gates do
							if typeof(gate) == "table" and typeof(gate.id) == "string" and typeof(gate.dots) == "table" and typeof(gate.connections) == "table" then
								table.insert(_laneChangeGates, gate)
							end
						end
					end
				else
					if typeof(entries.removed) == "table" then
						local removedSet: { [string]: boolean } = {}

						for _, id in entries.removed do
							if typeof(id) == "string" then
								removedSet[id] = true
							end
						end

						local kept: { any } = {}

						for _, gate in _laneChangeGates do
							if not removedSet[gate.id] then
								table.insert(kept, gate)
							end
						end

						_laneChangeGates = kept
					end

					if typeof(entries.changed) == "table" then
						local byId: { [string]: any } = {}

						for _, gate in _laneChangeGates do
							byId[gate.id] = gate
						end

						for _, gate in entries.changed do
							if typeof(gate) == "table" and typeof(gate.id) == "string" and typeof(gate.dots) == "table" and typeof(gate.connections) == "table" then
								byId[gate.id] = gate
							end
						end

						_laneChangeGates = {}

						for _, gate in byId do
							table.insert(_laneChangeGates, gate)
						end
					end
				end
			else
				_laneChangeGates = {}

				for _, gate in entries do
					if typeof(gate) == "table" and typeof(gate.id) == "string" and typeof(gate.dots) == "table" and typeof(gate.connections) == "table" then
						table.insert(_laneChangeGates, gate)
					end
				end
			end
		end

		if _selectedGateId then
			local found = false

			for _, gate in _laneChangeGates do
				if gate.id == _selectedGateId then
					found = true
					break
				end
			end

			if not found then
				_selectedGateId = nil
				_pickGateEdge = nil
			end
		end

		if _viewActive then
			requestRender()
		end
	end)

	local function rebuildNodePositionsArray()
		local out: { Vector3 } = {}

		for _, pos in _nodePositionsById do
			table.insert(out, pos)
		end

		_nodePositions = out
	end

	local _syncNodesConn = syncNodesRemote.OnClientEvent:Connect(function(rows: any)
		if typeof(rows) == "table" then
			table.clear(_nodePositionsById)

			for _, row in rows do
				if typeof(row) == "table" and typeof(row.id) == "number" and typeof(row.position) == "Vector3" then
					_nodePositionsById[row.id] = row.position
				end
			end

			rebuildNodePositionsArray()
		end

		if _viewActive then
			requestRender()
		end
	end)

	local syncNodesDeltaRemote = Net:WaitForRemote("SyncNodesDelta") :: RemoteEvent

	local _syncNodesDeltaConn = syncNodesDeltaRemote.OnClientEvent:Connect(function(delta: any)
		if typeof(delta) ~= "table" then return end

		local changed = delta.changed

		if typeof(changed) == "table" then
			for _, row in changed do
				if typeof(row) == "table" and typeof(row.id) == "number" and typeof(row.position) == "Vector3" then
					_nodePositionsById[row.id] = row.position
				end
			end
		end

		local removed = delta.removed

		if typeof(removed) == "table" then
			for _, id in removed do
				if typeof(id) == "number" then
					_nodePositionsById[id] = nil
				end
			end
		end

		rebuildNodePositionsArray()

		if _viewActive then
			requestRender()
		end
	end)

	local _iconBtnConn: RBXScriptConnection? = nil

	task.spawn(function()
		local laneGui = playerGui:WaitForChild("LaneTools", 30)
		if not laneGui then return end

		local btn = laneGui:WaitForChild("LaneViewButton", 30)

		if btn and btn:IsA("GuiButton") then
			_iconButton = btn
			_iconBaseColor = btn.BackgroundColor3

			if _iconBtnConn then
				_iconBtnConn:Disconnect()
			end

			_iconBtnConn = btn.Activated:Connect(toggleView)
			updateButtonAppearance()
		end
	end)

	-- No CharacterRemoving teardown: this view is a session singleton, and tearing it down
	-- on respawn killed the tool for good -- nothing ever calls Start() a second time.
end

return LaneConnectorView