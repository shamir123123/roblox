--!strict
-- UndergroundView -- the x-ray view, shared by every tool that works below the ground.
--
-- It is the water view's look, lifted out so roads can use it too: the city drained of
-- colour, the ground and the road surfaces turned see-through, and what runs underneath
-- drawn so it reads through them. The water tool shows its mains; the road tool, while it
-- is building a tunnel, shows every road that runs below the ground as a bright band along
-- its carriageway (a tunnel's own surface sits under the ground and is see-through here like
-- every other road, so on its own it would barely show).
--
-- Reference-counted by key: the water tool and the road tool each ask for it under their own
-- key, and it only comes off when nobody wants it any more -- so two tools can never leave
-- the city half-washed by turning it off under each other.
--
-- Cheap on low-end: nothing runs while it is off; while it is on, the tunnel bands are a
-- pooled set of plain parts for the nearest TUNNEL_CAP tunnel roads, refreshed once a second.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local DataCache = require(ReplicatedStorage:WaitForChild("DataCache"))
local BezierUtil = require(ReplicatedStorage.Road.BezierUtil)
local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)
local CoverageOverlay = require(script.Parent:WaitForChild("CoverageOverlay"))

local UndergroundView = {}

local SEE_THROUGH = 0.5
local SEE_FOLDERS = { "_Ground", "_RoadMeshes" }
local TUNNEL_COLOR = Color3.fromRGB(255, 176, 64)
local TUNNEL_CAP = 80        -- nearest tunnel roads drawn
local TUNNEL_STEP = 20       -- studs between band pieces along a road
local TUNNEL_LIFT = 0.35     -- studs above the tunnel's road surface
local REFRESH = 1.0          -- s between band refreshes while the view is open

local _wanted: { [string]: boolean } = {}
local _tunnelsWanted: { [string]: boolean } = {}
local _on = false
local _tunnelsOn = false
local _seeConns: { RBXScriptConnection } = {}
local _folder: Folder? = nil
local _pool: { BasePart } = {}
local _used = 0
local _refreshConn: RBXScriptConnection? = nil
local _nextRefresh = 0

local function seeThrough(d: Instance)
	if d:IsA("BasePart") then d.LocalTransparencyModifier = if _on then SEE_THROUGH else 0 end
end

local function applySeeThrough()
	for _, c in _seeConns do c:Disconnect() end
	table.clear(_seeConns)
	for _, name in SEE_FOLDERS do
		local root = Workspace:FindFirstChild(name)
		if not root then continue end
		for _, d in root:GetDescendants() do seeThrough(d) end
		-- Ground chunks and road cells that stream in while the view is open get it too.
		if _on then _seeConns[#_seeConns + 1] = root.DescendantAdded:Connect(seeThrough) end
	end
end

-- == Tunnel bands ==============================================================
local function band(): BasePart
	_used += 1
	local p = _pool[_used]
	if p then return p end
	local part = Instance.new("Part")
	part.Name = "TunnelBand"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.Color = TUNNEL_COLOR
	part.Transparency = 0.2
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = _folder
	_pool[_used] = part
	return part
end

local function refreshTunnels()
	_used = 0
	local camera = Workspace.CurrentCamera
	local focus = if camera then camera.CFrame.Position else Vector3.zero
	local list: { { seg: any, d: number } } = {}
	for _, seg in DataCache.GetSegments() do
		if seg.vMode ~= "Tunnel" then continue end
		local mid = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, 0.5)
		local dx, dz = mid.X - focus.X, mid.Z - focus.Z
		table.insert(list, { seg = seg, d = dx * dx + dz * dz })
	end
	table.sort(list, function(a, b) return a.d < b.d end)
	for i = 1, math.min(#list, TUNNEL_CAP) do
		local seg = list[i].seg
		local width = RoadTypeCatalog.getOrDefault(seg.roadType).width * 0.8
		local length = BezierUtil.length(seg.p0, seg.p1, seg.p2, seg.p3, 8)
		local steps = math.clamp(math.ceil(length / TUNNEL_STEP), 1, 48)
		local prev = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, 0)
		for k = 1, steps do
			local pt = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, k / steps)
			local chord = pt - prev
			if chord.Magnitude > 1e-3 then
				local mid = (prev + pt) * 0.5 + Vector3.new(0, TUNNEL_LIFT, 0)
				local p = band()
				p.Size = Vector3.new(width, 0.3, chord.Magnitude + 0.4)
				p.CFrame = CFrame.lookAt(mid, mid + chord)
			end
			prev = pt
		end
	end
	for k = _used + 1, #_pool do
		_pool[k]:Destroy()
		_pool[k] = nil
	end
end

local function setTunnels(on: boolean)
	if on == _tunnelsOn then return end
	_tunnelsOn = on
	if on then
		local folder = Instance.new("Folder")
		folder.Name = "UndergroundTunnels"
		folder.Parent = Workspace
		_folder = folder
		_nextRefresh = 0
		_refreshConn = RunService.Heartbeat:Connect(function()
			local now = os.clock()
			if now < _nextRefresh then return end
			_nextRefresh = now + REFRESH
			refreshTunnels()
		end)
	else
		if _refreshConn then _refreshConn:Disconnect() end
		_refreshConn = nil
		table.clear(_pool)
		_used = 0
		if _folder then _folder:Destroy() end
		_folder = nil
	end
end

-- == Public ====================================================================
-- Ask for the view (or let it go) under `key`. `showTunnels` also draws the roads that run
-- below the ground.
function UndergroundView.setActive(key: string, on: boolean, showTunnels: boolean?)
	_wanted[key] = if on then true else nil
	_tunnelsWanted[key] = if on and showTunnels then true else nil
	local want = next(_wanted) ~= nil
	if want ~= _on then
		_on = want
		applySeeThrough()
		CoverageOverlay.washCity(want)
	end
	setTunnels(next(_tunnelsWanted) ~= nil)
end

function UndergroundView.isActive(): boolean
	return _on
end

return UndergroundView
