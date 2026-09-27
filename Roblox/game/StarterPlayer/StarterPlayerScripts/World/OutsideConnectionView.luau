--!strict
-- OutsideConnectionView (client)
-- A floating arrow at every outside connection -- a road a player dragged to the map
-- edge. Two-way roads show a DOUBLE-headed arrow; one-way roads a SINGLE arrow pointing
-- the traffic direction (inbound toward the city, or outbound off the map). Reads the
-- replicated marker parts under workspace._OutsideConnections (Side / Dir / NX / NZ,
-- written by the server OutsideConnectionService). Pure view, no label -- and the arrows
-- are shown ONLY while the road tool is active (LocalPlayer "RoadToolActive" attribute,
-- set by RoadPlacementController), Cities-Skylines style.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.City.OutsideConnectionConstants)

local OutsideConnectionView = {}

local ARROW_HEIGHT = 8   -- studs above the edge point the arrow floats
local ARROW_LEN    = 20
local HEAD_LEN     = 9
local SHAFT_W      = 2.4
local BARB_W       = 1.9

local LocalPlayer = Players.LocalPlayer
local ROAD_MODE_ATTR = "RoadToolActive"

-- marker -> { visual: Folder, conns: { RBXScriptConnection } }
local _rendered: { [Instance]: { visual: Folder, conns: { RBXScriptConnection } } } = {}
local _folderConns: { RBXScriptConnection } = {}
local _started = false
local _roadMode = false

local function dirColor(dir: string): Color3
	return Constants.DirColor[dir] or Constants.DirColor.both
end

local function part(name: string, size: Vector3, cf: CFrame, color: Color3, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true; p.CanCollide = false; p.CanQuery = false; p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.Color = color
	p.Size = size
	p.CFrame = cf
	p.Parent = parent
	return p
end

-- A flat 2-barb chevron arrowhead at `tip`, opening back along -pointDir.
local function head(folder: Instance, tip: Vector3, pointDir: Vector3, color: Color3)
	local fwd = CFrame.lookAt(Vector3.zero, pointDir)
	for _, ang in { 148, -148 } do
		local d = (fwd * CFrame.Angles(0, math.rad(ang), 0)).LookVector
		local c = tip + d * (HEAD_LEN * 0.5)
		part("Barb", Vector3.new(BARB_W, 0.4, HEAD_LEN), CFrame.lookAt(c, c + d), color, folder)
	end
end

local function buildVisual(marker: BasePart): Folder
	local dir = tostring(marker:GetAttribute("Dir") or "both")
	local nx = tonumber(marker:GetAttribute("NX")) or 0
	local nz = tonumber(marker:GetAttribute("NZ")) or 1
	local normal = Vector3.new(nx, 0, nz)
	if normal.Magnitude < 1e-3 then normal = Vector3.new(0, 0, 1) end
	normal = normal.Unit
	local color = dirColor(dir)
	local twoWay = dir == "both"
	-- One-way flow: "in" points toward the city (-normal); "out"/"both" point off-map.
	local flow = if dir == "in" then -normal else normal

	local folder = Instance.new("Folder")
	folder.Name = "OCVisual"

	local base = marker.Position + Vector3.new(0, ARROW_HEIGHT, 0)
	-- Shaft centred on the edge point, lying flat along the road axis.
	part("Shaft", Vector3.new(SHAFT_W, 0.4, ARROW_LEN), CFrame.lookAt(base, base + flow), color, folder)

	head(folder, base + flow * (ARROW_LEN * 0.5), flow, color)
	if twoWay then
		head(folder, base - flow * (ARROW_LEN * 0.5), -flow, color)
	end

	return folder
end

local function unrender(marker: Instance)
	local entry = _rendered[marker]
	if not entry then return end
	for _, c in entry.conns do c:Disconnect() end
	if entry.visual then entry.visual:Destroy() end
	_rendered[marker] = nil
end

local function render(marker: Instance)
	if not _roadMode then return end
	if not marker:IsA("BasePart") then return end
	unrender(marker)
	local visual = buildVisual(marker)
	visual.Parent = marker -- child of the marker: auto-cleaned if the marker is destroyed
	local conns: { RBXScriptConnection } = {}
	-- Rebuild on any edit (direction flip from a road-type change, or a move).
	table.insert(conns, marker.AttributeChanged:Connect(function() render(marker) end))
	table.insert(conns, marker:GetPropertyChangedSignal("CFrame"):Connect(function() render(marker) end))
	_rendered[marker] = { visual = visual, conns = conns }
end

local function connectionFolder(): Instance?
	return Workspace:FindFirstChild(Constants.FOLDER_NAME)
end

local function renderAll()
	local f = connectionFolder()
	if f then for _, mk in f:GetChildren() do render(mk) end end
end

local function unrenderAll()
	for marker in _rendered do unrender(marker) end
end

-- Arrows exist only while the road tool is open.
local function setRoadMode(on: boolean)
	on = on and true or false
	if on == _roadMode then return end
	_roadMode = on
	if on then renderAll() else unrenderAll() end
end

local function watchFolder(f: Instance)
	for _, mk in f:GetChildren() do render(mk) end
	table.insert(_folderConns, f.ChildAdded:Connect(render))
	table.insert(_folderConns, f.ChildRemoved:Connect(unrender))
end

function OutsideConnectionView.Start()
	if _started then return end
	_started = true

	_roadMode = LocalPlayer:GetAttribute(ROAD_MODE_ATTR) == true
	table.insert(_folderConns, LocalPlayer:GetAttributeChangedSignal(ROAD_MODE_ATTR):Connect(function()
		setRoadMode(LocalPlayer:GetAttribute(ROAD_MODE_ATTR) == true)
	end))

	local existing = connectionFolder()
	if existing then watchFolder(existing) end

	-- The folder is created server-side only once a connection exists, so wait for it.
	table.insert(_folderConns, Workspace.ChildAdded:Connect(function(child)
		if child.Name == Constants.FOLDER_NAME then watchFolder(child) end
	end))
end

return OutsideConnectionView
