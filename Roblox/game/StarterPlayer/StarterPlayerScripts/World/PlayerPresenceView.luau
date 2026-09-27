--!strict
-- PlayerPresenceView
-- The other players, drawn on the map: a coloured line from each one's camera down to the
-- ground point under their cursor, a disc where that lands, and their name at the top of
-- the line. The line's length IS their camera height, so a player zoomed out reads as a
-- long line and one down at street level as a short one -- which is most of what you want
-- to know about where somebody else is working.
--
-- Everything here is built on the CLIENT: none of it replicates, none of it collides, and
-- none of it can be saved into the place. The local player is never drawn -- you are
-- already looking through their camera.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage:WaitForChild("Networker"))
local UIEvents = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("UIEvents"))
local CursorRay = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("CursorRay"))

local PlayerPresenceView = {}

local FOLDER_NAME = "_Presence"
local REPORT_INTERVAL = 1 / 10
-- Reports go up only when the camera or cursor moved, or once a second to stay listed
-- (the server forgets a player after 3 s of silence).
local REPORT_KEEPALIVE = 1
local REPORT_MOVE_EPS = 0.25 -- studs
local _lastReport: { pos: Vector3, aim: Vector3, at: number }? = nil
local LINE_THICKNESS = 0.7
local DISC_DIAMETER = 16
local DISC_HEIGHT = 0.2
-- Markers ease toward the last reported point instead of snapping to it: reports arrive at
-- 10 Hz over an unreliable channel, and a snapping marker reads as a broken one.
local SMOOTH_RATE = 12
-- A marker whose player stopped reporting (left, alt-tabbed, back at the menu) is taken
-- down rather than left standing over the map.
local DROP_AFTER = 4

-- One colour per player, derived from their userId so the same person is the same colour on
-- every screen -- no colour assignment to agree on, and no state to keep in step.
local PALETTE = table.freeze({
	Color3.fromRGB(88, 170, 255),
	Color3.fromRGB(255, 96, 96),
	Color3.fromRGB(255, 176, 64),
	Color3.fromRGB(120, 230, 130),
	Color3.fromRGB(198, 130, 255),
	Color3.fromRGB(255, 130, 200),
	Color3.fromRGB(96, 226, 226),
	Color3.fromRGB(226, 226, 120),
})

local function colourFor(userId: number): Color3
	return PALETTE[(userId % #PALETTE) + 1]
end
PlayerPresenceView._colourFor = colourFor -- exposed for the spec

type Marker = {
	line: BasePart,
	disc: BasePart,
	head: BasePart,
	name: TextLabel,
	pos: Vector3,
	aim: Vector3,
	targetPos: Vector3,
	targetAim: Vector3,
	seenAt: number,
}

local _markers: { [number]: Marker } = {}
local _folder: Folder? = nil
local _started = false
local _inCity = false
local _reportAccum = 0

local function folder(): Folder
	local f = _folder
	if f and f.Parent then return f end
	f = Instance.new("Folder")
	f.Name = FOLDER_NAME
	f.Parent = Workspace
	_folder = f
	return f
end

local function decorate(part: BasePart, colour: Color3)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = colour
	part.Parent = folder()
end

local function buildMarker(userId: number, name: string, pos: Vector3, aim: Vector3): Marker
	local colour = colourFor(userId)

	local line = Instance.new("Part")
	line.Name = "Line_" .. tostring(userId)
	line.Size = Vector3.new(LINE_THICKNESS, LINE_THICKNESS, 1)
	line.Transparency = 0.25
	decorate(line, colour)

	-- ponytail: a filled translucent disc, not the outlined ring the reference shot has --
	-- a ring needs a texture asset uploaded. Swap the Cylinder for a Part + ring decal if
	-- the outline matters.
	local disc = Instance.new("Part")
	disc.Name = "Aim_" .. tostring(userId)
	disc.Shape = Enum.PartType.Cylinder
	disc.Size = Vector3.new(DISC_HEIGHT, DISC_DIAMETER, DISC_DIAMETER)
	disc.Transparency = 0.55
	decorate(disc, colour)

	-- The name rides an invisible anchor at the camera end of the line. A BillboardGui
	-- keeps it facing the reader and the same size at any zoom, which is the one thing a
	-- label on a map has to do.
	local head = Instance.new("Part")
	head.Name = "Head_" .. tostring(userId)
	head.Size = Vector3.new(0.2, 0.2, 0.2)
	head.Transparency = 1
	decorate(head, colour)

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Name"
	billboard.AlwaysOnTop = true
	billboard.Size = UDim2.fromOffset(180, 22)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
	billboard.MaxDistance = math.huge
	billboard.Parent = head

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamMedium
	label.TextSize = 14
	label.TextColor3 = colour
	label.TextStrokeTransparency = 0.4
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.Text = name
	label.Parent = billboard

	return {
		line = line,
		disc = disc,
		head = head,
		name = label,
		pos = pos,
		aim = aim,
		targetPos = pos,
		targetAim = aim,
		seenAt = os.clock(),
	}
end

local function destroyMarker(userId: number)
	local m = _markers[userId]
	if not m then return end
	_markers[userId] = nil
	m.line:Destroy()
	m.disc:Destroy()
	m.head:Destroy() -- takes the BillboardGui with it
end

local function clearAll()
	for userId in _markers do
		destroyMarker(userId)
	end
	local f = _folder
	if f then
		f:Destroy()
		_folder = nil
	end
end

local function onSync(rows: any)
	if not _inCity or typeof(rows) ~= "table" then return end
	local localId = Players.LocalPlayer.UserId
	local now = os.clock()

	for _, row in rows do
		if typeof(row) ~= "table" then continue end
		local id = row.id
		-- You are already looking through your own camera; drawing your own marker would
		-- just be a line out of the middle of the screen.
		if typeof(id) ~= "number" or id == localId then continue end
		if typeof(row.pos) ~= "Vector3" or typeof(row.aim) ~= "Vector3" then continue end

		local m = _markers[id]
		if not m then
			m = buildMarker(id, tostring(row.name), row.pos, row.aim)
			_markers[id] = m
		else
			m.name.Text = tostring(row.name)
		end
		m.targetPos = row.pos
		m.targetAim = row.aim
		m.seenAt = now
	end
end

local function render(dt: number)
	local now = os.clock()
	-- Frame-rate independent easing: the same follow speed at 30 fps and at 240.
	local alpha = 1 - math.exp(-SMOOTH_RATE * dt)

	for userId, m in _markers do
		if now - m.seenAt > DROP_AFTER then
			destroyMarker(userId)
			continue
		end

		m.pos = m.pos:Lerp(m.targetPos, alpha)
		m.aim = m.aim:Lerp(m.targetAim, alpha)

		local delta = m.aim - m.pos
		local length = delta.Magnitude
		if length < 0.05 then continue end

		m.line.Size = Vector3.new(LINE_THICKNESS, LINE_THICKNESS, length)
		m.line.CFrame = CFrame.lookAt(m.pos + delta * 0.5, m.aim)
		-- Cylinder parts stand along their X axis, so the disc is laid flat by turning X up.
		m.disc.CFrame = CFrame.new(m.aim + Vector3.new(0, DISC_HEIGHT, 0)) * CFrame.Angles(0, 0, math.rad(90))
		m.head.CFrame = CFrame.new(m.pos)
	end
end

local function report(dt: number)
	if not _inCity then return end
	_reportAccum += dt
	if _reportAccum < REPORT_INTERVAL then return end
	_reportAccum = 0

	local camera = Workspace.CurrentCamera
	if not camera then return end
	-- Where the cursor lands, through the one picking system the rest of the game uses. No
	-- ground under the cursor (pointing at the sky) means nothing worth reporting.
	local aim = CursorRay.ground()
	if not aim then return end

	local pos = camera.CFrame.Position
	local now = os.clock()
	local last = _lastReport
	if last and now - last.at < REPORT_KEEPALIVE
		and (pos - last.pos).Magnitude < REPORT_MOVE_EPS and (aim - last.aim).Magnitude < REPORT_MOVE_EPS then
		return
	end
	_lastReport = { pos = pos, aim = aim, at = now }
	Net.ReportPresence:FireServer({ pos = pos, aim = aim })
end

function PlayerPresenceView.Start()
	if _started then return end
	_started = true

	Net.SyncPresence.OnClientEvent:Connect(onSync)

	-- Armed only while a city is actually up. Behind the menu there is no map to draw on
	-- and nobody to draw, so neither leg of this runs.
	UIEvents.GameEntered.Event:Connect(function()
		_inCity = true
	end)
	UIEvents.ReturnToMainMenu.Event:Connect(function()
		_inCity = false
		clearAll()
	end)

	Players.PlayerRemoving:Connect(function(player)
		destroyMarker(player.UserId)
	end)

	RunService.RenderStepped:Connect(function(dt: number)
		if not _inCity then return end
		local ok, err = pcall(function()
			render(dt)
			report(dt)
		end)
		if not ok then
			warn("[PlayerPresenceView] " .. tostring(err))
		end
	end)
end

return PlayerPresenceView
