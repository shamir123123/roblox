--!strict
-- CursorRay -- THE picking system. Every "what is under the cursor?" question in the game
-- is answered here, and nowhere else.
--
-- Before this module each tool rolled its own: eleven copies of the same ground raycast
-- with four different ray lengths (4000 / 4096 / 5000 / 8192), each rebuilding the same
-- ignore list its own way, each with its own hand-picked stud tolerance. They disagreed
-- with each other, so the same click meant different things depending on which tool was
-- open. Do not add another one -- add a query here.
--
-- Rules a caller never has to think about again:
--
-- 1. VIEWPORT SPACE IS THE FULL RENDER SURFACE, topbar band included. Measured, not
--    assumed: ViewportPointToRay over [0, ViewportSize] spans exactly FieldOfView, and
--    WorldToViewportPoint -> ViewportPointToRay round-trips to 0.000000 deg.
--    UserInputService:GetMouseLocation() is ALREADY in that space, so do NOT add or
--    subtract GuiService:GetGuiInset() from it -- EditorController did, and picked ~36 px
--    above the cursor. Kit.Frost, PlacementCostHud and TransitClient.stopIdAtScreen all
--    depend on this convention and all work.
--    InputObject.Position is NOT in that space for MOUSE input (it is inset-relative, the
--    Mouse.X/Y space), which is why mouse handlers must take their cursor from here and
--    ignore input.Position. Touch is the one exception -- GetMouseLocation cannot track a
--    finger -- so `position` reads Touch input straight off the InputObject.
--
-- 2. TOLERANCES BELONG IN PIXELS, NOT STUDS. A fixed stud radius is two different tools at
--    two zoom levels: NATURE_PICK_R = 7 studs was a 58-pixel grab radius with the camera
--    close in (grabbing props nowhere near the cursor) and a 1.2-pixel target at 2500 studs
--    out (unclickable). pickRadius converts a screen tolerance to world units at the depth
--    actually being picked, so the tool feels the same at every zoom.
--
-- 3. ONE RAY LENGTH, long enough to cross the map from any camera. See REACH.
--
-- The shared RaycastParams below are set immediately before their own raycast and never
-- handed out, so two tools querying in the same frame cannot tread on each other. A tool
-- that genuinely needs something exotic builds its own RaycastParams and calls `raycast`,
-- which still gives it the right cursor and the right reach.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RoadConstants = require(ReplicatedStorage:WaitForChild("Road"):WaitForChild("RoadConstants"))
local TerrainConstants = require(ReplicatedStorage:WaitForChild("Terrain"):WaitForChild("TerrainConstants"))
local TerrainBuildController = require(ReplicatedStorage.Terrain:WaitForChild("TerrainBuildController"))
local UiScratch = require(script.Parent:WaitForChild("UiScratch"))

local CursorRay = {}

-- What a ground query answers with. The fields are named exactly as RaycastResult's, so a
-- caller reads .Position / .Normal / .Instance without caring which of the two it got. It
-- cannot BE a RaycastResult: the ground is a MeshPart shell with no collision geometry, so
-- its hits are computed, not raycast, and RaycastResult is not constructible.
export type GroundHit = {
	Position: Vector3,
	Normal: Vector3,
	Instance: Instance?, -- nil when the bare ground was hit
	Material: Enum.Material,
	Distance: number,
}

-- Ray length for every cursor pick. Must clear the map DIAGONAL (MAP_HALF_EXTENT * 2 *
-- sqrt(2) ~= 11,585) plus camera altitude headroom, because FreeCamController clamps X/Z
-- but not Y and PITCH_MIN allows a near-horizontal view. The old per-call-site lengths
-- (4000 / 4096 / 5000 / 8192) could not cross the map -- 4096 was MAP_HALF_EXTENT used as
-- a ray length, short by 2x before altitude is even considered -- which is why picking
-- died once the camera pulled back.
CursorRay.REACH = RoadConstants.MAP_HALF_EXTENT * 6

-- Cursor position in viewport space. Pass the InputObject when handling an input event so
-- touch works; omit it for per-frame hover.
function CursorRay.position(input: InputObject?): Vector2
	if input and input.UserInputType == Enum.UserInputType.Touch then
		return Vector2.new(input.Position.X, input.Position.Y)
	end
	return UserInputService:GetMouseLocation()
end

function CursorRay.ray(input: InputObject?): Ray?
	local cam = Workspace.CurrentCamera
	if not cam then return nil end
	local p = CursorRay.position(input)
	return cam:ViewportPointToRay(p.X, p.Y)
end

function CursorRay.raycast(params: RaycastParams, input: InputObject?): RaycastResult?
	local r = CursorRay.ray(input)
	if not r then return nil end
	return Workspace:Raycast(r.Origin, r.Direction * CursorRay.REACH, params)
end

-- == The ground, analytically ================================================
-- The ground is a MeshPart shell built from the heightmap (TerrainMeshView) and carries NO
-- collision geometry: a heightfield cannot be given any that is worth having -- measured,
-- PreciseConvexDecomposition on one 64x64 chunk takes 5.8 SECONDS, and Box fidelity hits
-- the chunk's bounding box instead of its surface. So the ground is not raycast at all; it
-- is solved against the heightmap, which is exact, costs no physics memory on low-end
-- devices, and is the same surface the server graded roads against.

local MAX_SLOPE_TAN = math.tan(math.rad(TerrainConstants.SLOPE_CLAMP_DEG))
local NORMAL_EPS = TerrainConstants.SAMPLE_SPACING
local MARCH_MIN_STEP = 2
local MARCH_MAX_ITER = 160
local BISECT_ITER = 16

-- nil until a city has been built -- callers fall back to a raycast for that window.
local function surfaceY(x: number, z: number): number?
	return TerrainBuildController.getSurfaceY(x, z)
end

local function terrainNormal(x: number, z: number): Vector3
	local xl, xr = surfaceY(x - NORMAL_EPS, z), surfaceY(x + NORMAL_EPS, z)
	local zb, zf = surfaceY(x, z - NORMAL_EPS), surfaceY(x, z + NORMAL_EPS)
	if not (xl and xr and zb and zf) then return Vector3.yAxis end
	return Vector3.new(-((xr :: number) - (xl :: number)), 2 * NORMAL_EPS, -((zf :: number) - (zb :: number))).Unit
end

-- First point along the ray at or below the ground. The step is the largest one that
-- cannot step OVER the surface -- the current height above ground divided by the fastest
-- that gap can close, which is the ray's own descent plus the steepest grade the terrain
-- is allowed to have (SLOPE_CLAMP_DEG). So it converges in tens of samples instead of the
-- thousands a fixed 4-stud march would need, and still cannot tunnel through a ridge.
-- ponytail: the MIN_STEP floor below is the one unsafe part -- it exists so a ray running
-- parallel to a slope terminates. It only applies when the ray is already near the surface
-- (where the very next sample lands below it), so it has no ridge left to skip.
local function marchTerrain(origin: Vector3, dir: Vector3, maxDist: number): Vector3?
	local y0 = surfaceY(origin.X, origin.Z)
	if not y0 then return nil end
	local gap = origin.Y - y0
	if gap <= 0 then return nil end -- started underground: nothing to hit on the way down
	local horiz = math.sqrt(dir.X * dir.X + dir.Z * dir.Z)
	local closeRate = math.max(-dir.Y, 0) + horiz * MAX_SLOPE_TAN
	if closeRate <= 0 then return nil end -- pointing straight up

	local t, prevT = 0, 0
	for _ = 1, MARCH_MAX_ITER do
		prevT = t
		t += math.max(gap / closeRate, MARCH_MIN_STEP + t * 0.02)
		if t > maxDist then return nil end
		local p = origin + dir * t
		local ys = surfaceY(p.X, p.Z)
		if not ys then return nil end
		gap = p.Y - (ys :: number)
		if gap <= 0 then
			local lo, hi = prevT, t
			for _ = 1, BISECT_ITER do
				local mid = (lo + hi) * 0.5
				local pm = origin + dir * mid
				local ym = surfaceY(pm.X, pm.Z)
				if not ym then return nil end
				if pm.Y - (ym :: number) > 0 then lo = mid else hi = mid end
			end
			return origin + dir * hi
		end
	end
	return nil
end

-- The terrain equivalent of `raycast`: first point at or below the ground along the ray,
-- or nil if it never meets it. Exposed because it IS the ground query -- every terrain
-- answer below is this, and its spec is the only place the march gets pinned.
function CursorRay.terrainRay(origin: Vector3, dir: Vector3, maxDist: number): Vector3?
	return marchTerrain(origin, dir.Unit, maxDist)
end

-- Studs one screen pixel covers at `depth` studs in front of the camera.
function CursorRay.studsPerPixel(depth: number): number
	local cam = Workspace.CurrentCamera
	if not cam or cam.ViewportSize.Y < 1 then return 1 end
	return (2 * depth * math.tan(math.rad(cam.FieldOfView) / 2)) / cam.ViewportSize.Y
end

-- World-space pick radius equivalent to `pixels` on screen at `worldPoint`, clamped so it
-- stays usable at both ends of the zoom range. This is what replaces a fixed stud
-- tolerance in every nearest-wins fallback.
function CursorRay.pickRadius(worldPoint: Vector3, pixels: number, minStuds: number, maxStuds: number): number
	local cam = Workspace.CurrentCamera
	if not cam then return minStuds end
	local depth = (worldPoint - cam.CFrame.Position).Magnitude
	return math.clamp(pixels * CursorRay.studsPerPixel(depth), minStuds, maxStuds)
end

-- == Shared filters ==========================================================
-- Assigning FilterDescendantsInstances re-marshals the array, and these run every frame,
-- so the list is only written when its contents actually changed.
local function setFilter(params: RaycastParams, list: { Instance })
	local cur = params.FilterDescendantsInstances
	if #cur == #list then
		local same = true
		for i, inst in list do
			if cur[i] ~= inst then same = false; break end
		end
		if same then return end
	end
	params.FilterDescendantsInstances = list
end

local _groundParams = RaycastParams.new()
_groundParams.FilterType = Enum.RaycastFilterType.Exclude
-- Ghosts, previews and outline hosts are non-collidable by design, so a collision-respecting
-- ground ray would tunnel straight through the terrain they are drawn on.
_groundParams.RespectCanCollide = false

local _includeParams = RaycastParams.new()
_includeParams.FilterType = Enum.RaycastFilterType.Include
_includeParams.RespectCanCollide = false
-- Only matters when Terrain is in the Include list (the ground+roads pick); for folder
-- filters water is unreachable anyway, so this is safe to leave on for everyone.
_includeParams.IgnoreWater = true

local _terrainParams = RaycastParams.new()
_terrainParams.FilterType = Enum.RaycastFilterType.Include
_terrainParams.FilterDescendantsInstances = { Workspace.Terrain }
_terrainParams.IgnoreWater = true

-- Reused so the per-frame path allocates nothing.
local _ignoreScratch: { Instance } = {}

-- What a ground ray must never hit, whoever is asking: the local character and the whole
-- _UI scratch root (ghosts, previews, brush outlines, drag handles). Every tool was
-- assembling some subset of this by hand.
local function groundIgnore(extra: { Instance }?): { Instance }
	table.clear(_ignoreScratch)
	local char = Players.LocalPlayer.Character
	if char then table.insert(_ignoreScratch, char) end
	-- peek, not root: a raycast must not create the folder as a side effect of looking.
	local uiRoot = UiScratch.peek()
	if uiRoot then table.insert(_ignoreScratch, uiRoot) end
	-- Pipes are buried: the ground is the surface above them, even while they are drawn.
	local pipes = CursorRay.cityFolder("WaterPipes")
	if pipes then table.insert(_ignoreScratch, pipes) end
	if extra then
		for _, inst in extra do
			if inst then table.insert(_ignoreScratch, inst) end
		end
	end
	return _ignoreScratch
end

-- == The queries =============================================================

-- A folder under Workspace._City, or nil before the city exists.
function CursorRay.cityFolder(name: string): Instance?
	local city = Workspace:FindFirstChild("_City")
	return city and city:FindFirstChild(name)
end

export type GroundOpts = {
	ignore: { Instance }?,      -- extra instances to skip (a tool's own ghost, say)
	input: InputObject?,        -- pass the InputObject inside an input handler so touch works
	ignoreWater: boolean?,      -- default false: the water SURFACE counts as ground
}

-- The world point under the cursor. This is the query nearly every tool actually wants.
-- Two sources, nearest wins: a raycast for everything BUILT, and the heightmap march for
-- the bare ground. Capping the march at the raycast's distance is what makes "nearest
-- wins" one comparison instead of two -- and is also why the water SURFACE still counts as
-- ground when ignoreWater is off: the water voxel is hit first, so the march never reaches
-- the seabed under it.
function CursorRay.groundHit(opts: GroundOpts?): GroundHit?
	local o = opts or {}
	_groundParams.IgnoreWater = o.ignoreWater == true
	setFilter(_groundParams, groundIgnore(o.ignore))
	local r = CursorRay.ray(o.input)
	if not r then return nil end
	local dir = r.Direction.Unit
	local built = Workspace:Raycast(r.Origin, dir * CursorRay.REACH, _groundParams)
	local builtDist = if built then built.Distance else CursorRay.REACH
	local ground = marchTerrain(r.Origin, dir, builtDist)
	if ground then
		local p = ground :: Vector3
		return {
			Position = p,
			Normal = terrainNormal(p.X, p.Z),
			Instance = nil,
			Material = Enum.Material.Grass,
			Distance = (p - r.Origin).Magnitude,
		}
	end
	if not built then return nil end
	return {
		Position = built.Position,
		Normal = built.Normal,
		Instance = built.Instance,
		Material = built.Material,
		Distance = built.Distance,
	}
end

function CursorRay.ground(opts: GroundOpts?): Vector3?
	local hit = CursorRay.groundHit(opts)
	return if hit then hit.Position else nil
end

-- Terrain height at an XZ column, ignoring everything built on top of it. Used by the
-- brush/box outlines to lie on the ground. Origin is above MAX_ELEVATION, not the map
-- half-extent, so it is unaffected by how high the camera happens to be.
local TERRAIN_PROBE_TOP = 8192
function CursorRay.terrainY(x: number, z: number): number?
	local y = surfaceY(x, z)
	if y then return y end
	local hit = Workspace:Raycast(
		Vector3.new(x, TERRAIN_PROBE_TOP, z),
		Vector3.new(0, -TERRAIN_PROBE_TOP * 2, 0),
		_terrainParams
	)
	return if hit then hit.Position.Y else nil
end

-- The bare terrain surface under the cursor, ignoring everything built on top of it and
-- ignoring water. What a sculpt/paint brush wants.
function CursorRay.terrainPoint(input: InputObject?): Vector3?
	local r = CursorRay.ray(input)
	if not r then return nil end
	local p = marchTerrain(r.Origin, r.Direction.Unit, CursorRay.REACH)
	if p then return p end
	local hit = CursorRay.raycast(_terrainParams, input)
	return if hit then hit.Position else nil
end

-- Surface height at an XZ column under the SAME exclusions as the ground pick, so a tool
-- that ignores (say) roads and rooftops for picking also ignores them when it asks how
-- high the ground is. Straight down, so it does not depend on where the camera is.
function CursorRay.surfaceYAt(x: number, z: number, ignore: { Instance }?): number?
	_groundParams.IgnoreWater = false
	setFilter(_groundParams, groundIgnore(ignore))
	local hit = Workspace:Raycast(
		Vector3.new(x, TERRAIN_PROBE_TOP, z),
		Vector3.new(0, -TERRAIN_PROBE_TOP * 2, 0),
		_groundParams
	)
	local ground = surfaceY(x, z)
	if hit and ground then return math.max(hit.Position.Y, ground :: number) end
	if hit then return hit.Position.Y end
	return ground
end

-- First hit inside `folders` (an Include filter). The caller resolves the instance to
-- whatever it considers a target -- resolvers differ (a building, a transit stop, an
-- editor object), the ray does not.
function CursorRay.hitIn(folders: { Instance }, input: InputObject?): RaycastResult?
	if #folders == 0 then return nil end
	setFilter(_includeParams, folders)
	return CursorRay.raycast(_includeParams, input)
end

-- Same, resolving the hit up to the Model sitting directly under one of the folders --
-- the common case, since city objects are one Model per folder entry.
function CursorRay.modelIn(folders: { Instance }, input: InputObject?): Model?
	local hit = CursorRay.hitIn(folders, input)
	if not hit then return nil end
	local inFolder: { [Instance]: boolean } = {}
	for _, f in folders do inFolder[f] = true end
	local inst: Instance? = hit.Instance
	while inst and inst ~= Workspace do
		local parent = inst.Parent
		if parent and inFolder[parent] and inst:IsA("Model") then return inst end
		inst = parent
	end
	return nil
end

-- Nearest Model in `folder` whose pivot is within a SCREEN-space radius of `point`, gated
-- on elevation. This is how anything non-queryable gets picked -- props are CanQuery=false
-- so a ray passes straight through them. Pivot distance rather than GetBoundingBox: the
-- bounding box of every prop every frame stutters at high prop counts.
-- Ray entry distance into an oriented box, or nil. Slab test in the box's own frame.
local function rayBox(o: Vector3, d: Vector3, cf: CFrame, size: Vector3): number?
	local lo, ld = cf:PointToObjectSpace(o), cf:VectorToObjectSpace(d)
	local tmin, tmax = 0, math.huge
	for _, ax in { "X", "Y", "Z" } do
		local oi, di, hi = (lo :: any)[ax], (ld :: any)[ax], (size :: any)[ax] * 0.5
		if math.abs(di) < 1e-9 then
			if math.abs(oi) > hi then return nil end
		else
			local t1, t2 = (-hi - oi) / di, (hi - oi) / di
			if t1 > t2 then t1, t2 = t2, t1 end
			tmin, tmax = math.max(tmin, t1), math.min(tmax, t2)
			if tmin > tmax then return nil end
		end
	end
	return tmin
end
CursorRay.rayBox = rayBox

-- The model whose PARTS the cursor ray actually enters first. Props are CanQuery=false, so
-- no engine raycast sees them; this tests each part's box instead, behind a per-model
-- bounding-box broadphase. nearestPivot picked by flat distance from the TERRAIN hit, so a
-- click on the top of a stacked block or the face of a wall landed on the ground behind it
-- and grabbed whatever pivot was nearest there.
-- ponytail: O(props) per call; fine for clicks, keep it out of per-frame hover.
function CursorRay.modelUnderRay(folder: Instance, input: InputObject?): Model?
	local r = CursorRay.ray(input)
	if not r then return nil end
	local o, d = r.Origin, r.Direction.Unit
	local best: Model? = nil
	local bestT = math.huge
	for _, m in folder:GetChildren() do
		if not m:IsA("Model") then continue end
		local bcf, bsize = (m :: Model):GetBoundingBox()
		local tb = rayBox(o, d, bcf, bsize)
		if not tb or tb >= bestT then continue end
		for _, p in m:GetDescendants() do
			if p:IsA("BasePart") and (p :: BasePart).Transparency < 1 then
				local t = rayBox(o, d, (p :: BasePart).CFrame, (p :: BasePart).Size)
				if t and t < bestT then best, bestT = m :: Model, t end
			end
		end
	end
	return best
end

function CursorRay.nearestPivot(
	folder: Instance,
	point: Vector3,
	pixels: number,
	minStuds: number,
	maxStuds: number,
	maxDy: number
): Model?
	local r = CursorRay.pickRadius(point, pixels, minStuds, maxStuds)
	local best: Model? = nil
	local bestD = math.huge
	for _, m in folder:GetChildren() do
		if m:IsA("Model") then
			local pv = m:GetPivot().Position
			-- The distance test is XZ-only, so without the vertical gate a click on a bridge
			-- deck picks the props on the ground beneath it.
			if math.abs(point.Y - pv.Y) <= maxDy then
				local d = Vector2.new(point.X - pv.X, point.Z - pv.Z).Magnitude
				if d <= r and d < bestD then best = m; bestD = d end
			end
		end
	end
	return best
end

return CursorRay
