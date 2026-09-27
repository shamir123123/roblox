--!strict
-- RoadPlacementPrediction -- client-side prediction for road placement, the way movement is
-- predicted: the road you just placed is drawn on YOUR screen the moment you click, as a plain
-- asphalt band along the curve, so building never waits on the round trip to the server.
--
-- When the server answers, the band is taken away at once if the road was refused, or kept
-- until the real road has been built and baked on this client if it was accepted -- so there
-- is no gap between the two. Nothing here is authoritative: the server still validates and
-- builds every road, and other players only ever see the real one.
--
-- Cheap: a handful of plain parts per pending road (at most MAX_PIECES), and the watcher
-- only runs while a band is on screen.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BezierUtil = require(ReplicatedStorage.Road.BezierUtil)
local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)
local RoadMeshView = require(script.Parent.Parent:WaitForChild("World"):WaitForChild("RoadMeshView"))

local RoadPlacementPrediction = {}

local STEP = 12          -- studs per band piece
local MAX_PIECES = 64
local LIFT = 0.2         -- studs above the curve, clear of the real slab once it lands
local COLOR = Color3.fromRGB(72, 74, 80)
local TRANSPARENCY = 0.15
-- After an accept: gone once this client's road bakes have caught up (a bake finished after
-- the accept and nothing is queued), and never later than MAX_KEEP. The replicated road and
-- the accept arrive together, so the bake that draws it always starts around the accept;
-- SETTLE covers a bake that happened to finish just before it.
local SETTLE = 1.0
local MAX_KEEP = 4

type Handle = { parts: { BasePart }, acceptedAt: number? }

local _live: { Handle } = {}
local _folder: Folder? = nil
local _conn: RBXScriptConnection? = nil

local function folder(): Folder
	local f = _folder
	if f and f.Parent then return f end
	local nf = Instance.new("Folder")
	nf.Name = "_RoadPrediction"
	nf.Parent = Workspace
	_folder = nf
	return nf
end

local function drop(h: Handle)
	for _, p in h.parts do p:Destroy() end
	table.clear(h.parts)
	local i = table.find(_live, h)
	if i then table.remove(_live, i) end
	if #_live == 0 and _conn then
		_conn:Disconnect()
		_conn = nil
	end
end

local function watch()
	if _conn then return end
	_conn = RunService.Heartbeat:Connect(function()
		local now = os.clock()
		local idle = RoadMeshView.isIdle()
		local bakedAt = RoadMeshView.lastBakeAt()
		for i = #_live, 1, -1 do
			local h = _live[i]
			local at = h.acceptedAt
			if at and (now - at > MAX_KEEP or (idle and (bakedAt > at or now - at > SETTLE))) then
				drop(h)
			end
		end
	end)
end

local function band(h: Handle, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, width: number)
	local len = BezierUtil.length(p0, p1, p2, p3, 8)
	local n = math.clamp(math.ceil(len / STEP), 1, MAX_PIECES)
	local parent = folder()
	local prev = p0
	for k = 1, n do
		local pt = BezierUtil.point(p0, p1, p2, p3, k / n)
		local chord = pt - prev
		if chord.Magnitude > 1e-3 then
			local mid = (prev + pt) * 0.5 + Vector3.new(0, LIFT, 0)
			local part = Instance.new("Part")
			part.Name = "PredictedRoad"
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false -- the cursor ray must keep reading the ground under it
			part.CanTouch = false
			part.CastShadow = false
			part.Material = Enum.Material.SmoothPlastic
			part.Color = COLOR
			part.Transparency = TRANSPARENCY
			part.TopSurface = Enum.SurfaceType.Smooth
			part.BottomSurface = Enum.SurfaceType.Smooth
			part.Size = Vector3.new(width, 0.3, chord.Magnitude + 0.5) -- overlap hides the seams
			part.CFrame = CFrame.lookAt(mid, mid + chord)
			part.Parent = parent
			table.insert(h.parts, part)
		end
		prev = pt
	end
end

-- Draws the road a placement request asks for (and its parallel twin, if any). Returns the
-- handle to resolve when the server answers; nil if the request has no curve to draw.
function RoadPlacementPrediction.show(req: any): Handle?
	if typeof(req) ~= "table" then return nil end
	local p0, p1, p2, p3 = req.p0, req.p1, req.p2, req.p3
	if typeof(p0) ~= "Vector3" or typeof(p1) ~= "Vector3" or typeof(p2) ~= "Vector3" or typeof(p3) ~= "Vector3" then
		return nil
	end
	local width = RoadTypeCatalog.getOrDefault(req.roadType).width
	local h: Handle = { parts = {} }
	band(h, p0, p1, p2, p3, width)
	local twin = req.twin
	if typeof(twin) == "table" and typeof(twin.p0) == "Vector3" then
		band(h, twin.p0, twin.p1, twin.p2, twin.p3, width)
	end
	table.insert(_live, h)
	return h
end

-- The server's answer: refused -> gone now; accepted -> gone once the real road is drawn.
function RoadPlacementPrediction.resolve(h: Handle?, ok: boolean)
	if not h then return end
	if not ok then
		drop(h)
		return
	end
	h.acceptedAt = os.clock()
	watch()
end

return RoadPlacementPrediction
