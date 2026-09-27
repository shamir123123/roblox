--!strict
-- PlacementFit -- THE "is this ground free?" test.
--
-- One question, asked the same way by everything that puts an object on the map: the free
-- placer's ghost (GhostPlacement), the server's service-building pipeline (ServicePlacement),
-- the zoning planner's seats (PlotGeometry, through the predicate its road index carries) and
-- car parks (NaturePlaceService). Each used to roll its own box query with its own inset, and
-- they had drifted -- a car park covering 60 studs of asphalt was tested as a 3-stud radius.
--
-- Pure library: no state, no lifecycle, nothing on require. Client and server both see
-- Workspace._City, so a ghost and the server that validates it get the same answer.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlotGeometry = require(ReplicatedStorage.City.PlotGeometry)
local NatureCatalog = require(ReplicatedStorage.Nature.NatureCatalog)
local LOT_SIZE = require(ReplicatedStorage.City.ZoneGrid).LOT_SIZE

local PlacementFit = {}

-- The box is inset on X/Z so two things may sit kerb-to-kerb without reading as a collision.
PlacementFit.INSET = 2
-- How far BELOW the pivot the box starts. It must reach under the ground plane, not sit on
-- top of it: a car park is a slab barely a stud tall, and a box lifted clear of the ground
-- sails straight over one -- which is how houses got zoned on top of a car park. The terrain
-- itself can never be a false hit here, because the query only ever looks inside _City.
PlacementFit.GROUND_REACH = 1

-- Reused: this runs every frame under a live ghost.
local _params = OverlapParams.new()
_params.FilterType = Enum.RaycastFilterType.Include

-- Everything already built. No city yet means nothing can be in the way.
function PlacementFit.cityRoot(): Instance?
	return Workspace:FindFirstChild("_City")
end

-- Parts of the city the box at `pivot` touches (footprint X/Z in plan, Y its height), minus
-- anything under `ignore` -- the object being moved is never in its own way, and a caller with
-- a better test for one subtree (the zoning planner has exact road bands) passes that folder.
function PlacementFit.hits(pivot: CFrame, footprint: Vector3, ignore: Instance?): { BasePart }
	local city = PlacementFit.cityRoot()
	if not city then
		return {}
	end
	_params.FilterDescendantsInstances = { city }
	-- Spans pivot.Y - GROUND_REACH up to pivot.Y + footprint.Y.
	local reach = PlacementFit.GROUND_REACH
	local found = Workspace:GetPartBoundsInBox(
		pivot * CFrame.new(0, (footprint.Y - reach) * 0.5, 0),
		Vector3.new(
			math.max(footprint.X - PlacementFit.INSET, 0.1),
			math.max(footprint.Y + reach, 0.1),
			math.max(footprint.Z - PlacementFit.INSET, 0.1)
		),
		_params
	)
	if not ignore then
		return found
	end
	local out: { BasePart } = {}
	for _, p in found do
		if not p:IsDescendantOf(ignore) then
			out[#out + 1] = p
		end
	end
	return out
end

function PlacementFit.boxFree(pivot: CFrame, footprint: Vector3, ignore: Instance?): boolean
	return #PlacementFit.hits(pivot, footprint, ignore) == 0
end

-- The same test for a plan rectangle given as four ordered ground corners -- the shape the
-- zoning planner works in. `height` is how tall to treat the seat; the corners give the plan.
function PlacementFit.cornersFree(corners: { Vector3 }, height: number, ignore: Instance?): boolean
	local c1, c2, c3, c4 = corners[1], corners[2], corners[3], corners[4]
	if not (c1 and c2 and c3 and c4) then
		return true
	end
	local ex, ez = c2 - c1, c4 - c1
	local w, d = ex.Magnitude, ez.Magnitude
	if w < 0.1 or d < 0.1 then
		return true
	end
	local right = Vector3.new(ex.X, 0, ex.Z)
	if right.Magnitude < 1e-4 then
		return true
	end
	local centre = (c1 + c3) * 0.5
	local pivot = CFrame.fromMatrix(centre, right.Unit, Vector3.yAxis)
	return PlacementFit.boxFree(pivot, Vector3.new(w, height, d), ignore)
end

-- The road models. For callers that already test roads precisely and must not double-count
-- them: the zoning planner (segment bands + cap discs) and a car park, which is meant to sit
-- right against the kerb it is served from.
function PlacementFit.roadsFolder(): Instance?
	local city = PlacementFit.cityRoot()
	return if city then city:FindFirstChild("Roads") else nil
end

-- A road is NOT in the box query at all. RoadMeshBuilder bakes no collision body
-- (BUILD_COLLISION = false) and the client's merged road mesh is CanQuery = false, so the
-- carriageway is invisible to hits() -- which is how a wind turbine came to stand in a
-- junction. What still caught a box was the street furniture parented into a segment model
-- (lamps, signs, cabinets), which is why a straight road usually refused and the open plate
-- of an interchange, where no lamp stands, took anything.
--
-- So roads are tested the way the zoning planner tests them: analytically, off the segment
-- list. Each side hands over its own (client: DataCache; server: RoadService), and the
-- index is rebuilt on the next question after that.
local _segments: { [any]: any } = {}
local _roadIndex: PlotGeometry.RoadIndex? = nil

function PlacementFit.setRoadSegments(segments: { [any]: any })
	_segments = segments
	_roadIndex = nil
end

-- ponytail: no `occupied` predicate on this index -- boxFree already answers "is something
-- standing here"; this one only has to answer "is that a road".
local function roadIndex(): PlotGeometry.RoadIndex
	local idx = _roadIndex
	if not idx then
		idx = PlotGeometry.buildRoadIndex(_segments)
		_roadIndex = idx
	end
	return idx
end

-- Does this footprint reach onto a road? The same test a zoned seat is judged by, so a
-- free-placed building and a zoned house read the kerb identically. Sidewalks are NOT road
-- here (rectOnRoad's `block` reach): a building backing onto the footway it fronts is fine,
-- asphalt is not.
function PlacementFit.onRoad(pivot: CFrame, footprint: Vector3): boolean
	if next(_segments) == nil then return false end
	local hx, hz = footprint.X * 0.5, footprint.Z * 0.5
	return PlotGeometry.rectOnRoad(roadIndex(), {
		pivot * Vector3.new(-hx, 0, -hz),
		pivot * Vector3.new( hx, 0, -hz),
		pivot * Vector3.new( hx, 0,  hz),
		pivot * Vector3.new(-hx, 0,  hz),
	})
end

-- A POWER POLE is not a building and is not decoration: it is a slim relay that has to
-- stand in the verge between a house and the kerb. Only two things refuse it -- a road and
-- a building -- and the wire it carries is free to cross both, because only the FOOTING is
-- tested. Shared so the drag preview reddens on exactly what the server will refuse.
PlacementFit.POLE_BOX = Vector3.new(6, 6, 6)
local POLE_REFUSED_BY: { [string]: string } = {
	Roads = "a road",
	ZonedBuildings = "a building",
	EmergencyServices = "a building",
	Schools = "a building",
	Transit = "a building",
}

-- A commercial or industrial parcel is PAVED kerb to kerb, and that paving is part of the
-- building's own model -- so a pole anywhere near a shop or a plant landed on "a building"
-- and was refused, and only residential (which leaves grass either side) could be wired.
-- The lot is ground, not structure: the building itself still blocks, its yard does not.
local LOT_DRESSING: { [string]: boolean } = { Yard = true, Lot = true, ParkMarkers = true }

function PlacementFit.poleBlockedBy(pos: Vector3): string?
	-- The Roads entry below can never fire on its own: road models hold no queryable part.
	if PlacementFit.onRoad(CFrame.new(pos), PlacementFit.POLE_BOX) then
		return "a road"
	end
	local city = PlacementFit.cityRoot()
	if not city then
		return nil
	end
	for _, part in PlacementFit.hits(CFrame.new(pos), PlacementFit.POLE_BOX) do
		-- Walk up to the direct child of _City: that folder IS the answer to "what is this".
		local node: Instance? = part
		local dressing = false
		while node and node.Parent ~= city do
			if LOT_DRESSING[node.Name] then dressing = true end
			node = node.Parent
		end
		if dressing then continue end
		local label = node and POLE_REFUSED_BY[node.Name]
		if label then
			return label
		end
	end
	return nil
end

-- Height a zoned seat is probed at: tall enough to catch a house, a shop or a service
-- building, low enough to pass under an elevated deck.
PlacementFit.SEAT_PROBE_HEIGHT = 12

-- Ready-made predicate for PlotGeometry's road index, so the client preview and the server
-- placer inject the identical test. Roads are EXEMPT here: the planner already tests them
-- exactly (segment bands + cap discs), and a seat legitimately backs onto the sidewalk it
-- fronts -- which a box query would call a collision.
function PlacementFit.seatOccupied(corners: { Vector3 }): boolean
	return not PlacementFit.cornersFree(corners, PlacementFit.SEAT_PROBE_HEIGHT, PlacementFit.roadsFolder())
end

-- ----------------------------------------------------- roads over buildings --
-- A road laid over a standing building takes it with it, and the road ghost says so in
-- white before the click. The server demolishes off its own records and the ghost
-- highlights off the models it can see, so the GEOMETRY lives here once and each side
-- hands it its own seats -- the same split RoadProximity makes for road segments.

-- The seat a placed building was actually zoned on: BuildingService stamps its plot pivot
-- on the model, because the MODEL's own pivot carries the template's internal offset and
-- the dressing parented under it, and neither belongs to the lot. Anything unstamped falls
-- back to the model pivot, which is close enough to judge but is not the seat.
function PlacementFit.lotPivot(m: Model): CFrame
	local p = m:GetAttribute("LotPivot")
	return if typeof(p) == "CFrame" then p :: CFrame else m:GetPivot()
end

-- Is a building of this footprint, seated at `pivot`, under a road swept along `points`?
-- `radius` is measured to the seat's CENTRE and is the full paved corridor plus a margin:
-- a neighbour on the next lot has its centre a lot and a gap beyond the kerb, so only a
-- building genuinely sitting under the road is caught.
-- `rectRadius` is measured to the building's own footprint RECTANGLE and wants the BARE
-- paved reach. It is the corner case the centre test cannot see -- a building whose centre
-- is clear of the new pavement but whose wall is inside it, which is how a roundabout
-- dropped on a zoned street left houses glitching through its kerb.
function PlacementFit.seatUnderPavement(pivot: CFrame, halfW: number, halfD: number,
	points: { Vector3 }, radius: number, rectRadius: number?): boolean
	local r2 = radius * radius
	local rect2 = if rectRadius and rectRadius > 0 then rectRadius * rectRadius else nil
	local c = pivot.Position
	for _, p in points do
		local dx, dz = p.X - c.X, p.Z - c.Z
		if dx * dx + dz * dz <= r2 then return true end
		if rect2 then
			local lp = pivot:PointToObjectSpace(Vector3.new(p.X, c.Y, p.Z))
			local ox = math.max(0, math.abs(lp.X) - halfW)
			local oz = math.max(0, math.abs(lp.Z) - halfD)
			if ox * ox + oz * oz <= rect2 then return true end
		end
	end
	return false
end

-- Every standing zoned building a road along `points` would take: the road ghost's white
-- highlight list. Abandoned buildings are INCLUDED -- a derelict in the carriageway comes
-- down like any other, which is the opposite of buildingAt below, where a derelict lot is
-- ground a tree may stand on.
function PlacementFit.zonedBuildingsUnderPavement(points: { Vector3 }, radius: number, rectRadius: number?): { Model }
	local out: { Model } = {}
	local city = PlacementFit.cityRoot()
	local zoned = city and city:FindFirstChild("ZonedBuildings")
	if not zoned or #points == 0 then return out end
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for _, p in points do
		minX = math.min(minX, p.X); maxX = math.max(maxX, p.X)
		minZ = math.min(minZ, p.Z); maxZ = math.max(maxZ, p.Z)
	end
	for _, m in zoned:GetChildren() do
		if m:IsA("Model") then
			local w = tonumber(m:GetAttribute("FootprintWidth"))
			local d = tonumber(m:GetAttribute("FootprintDepth"))
			if w and d then
				local pivot = PlacementFit.lotPivot(m :: Model)
				local halfW, halfD = w * LOT_SIZE * 0.5, d * LOT_SIZE * 0.5
				-- Cheap broad phase, the same one the server runs: reject anything outside the
				-- corridor bounds plus the seat's own diagonal before the point sweep.
				local margin = radius + math.sqrt(halfW * halfW + halfD * halfD) + LOT_SIZE
				local c = pivot.Position
				if c.X >= minX - margin and c.X <= maxX + margin
					and c.Z >= minZ - margin and c.Z <= maxZ + margin
					and PlacementFit.seatUnderPavement(pivot, halfW, halfD, points, radius, rectRadius) then
					out[#out + 1] = m :: Model
				end
			end
		end
	end
	return out
end

-- ------------------------------------------------------------- nature props --
-- What stops a tree / rock / shape going here. Two questions, asked the SAME way by the
-- client's ghost tint and by NaturePlaceService, off Workspace._City which both sides see
-- -- so the ghost can never go green on a placement the server then silently drops.
-- Roads are not asked here: RoadProximity owns the carriageway rule, also on both sides.

-- Is a building standing here? Asks the WORLD rather than one service's record, so every
-- kind answers at once -- zoned houses and shops, emergency services, schools, transit.
-- The zoned LOT is tested on top of the box query, because a garden holds no part of its
-- own: a box query alone plants a tree in the middle of an occupied plot.
function PlacementFit.buildingAt(pivot: CFrame, footprint: Vector3): boolean
	-- Roads are excluded, not because they are free ground, but because RoadProximity has
	-- already judged them -- counting them twice would refuse a verge planting on the
	-- street furniture standing in it.
	if not PlacementFit.boxFree(pivot, footprint, PlacementFit.roadsFolder()) then
		return true
	end
	local city = PlacementFit.cityRoot()
	local zoned = city and city:FindFirstChild("ZonedBuildings")
	if not zoned then return false end
	local pos = pivot.Position
	local clearance = math.max(footprint.X, footprint.Z) * 0.5
	for _, m in zoned:GetChildren() do
		if m:IsA("Model") and m:GetAttribute("Abandoned") ~= true then
			local w = tonumber(m:GetAttribute("FootprintWidth"))
			local d = tonumber(m:GetAttribute("FootprintDepth"))
			if w and d then
				-- Into the building's own space, so a rotated plot is judged on its corners
				-- rather than as a circle -- a house is large next to a tree's footprint.
				local lp = PlacementFit.lotPivot(m :: Model):PointToObjectSpace(pos)
				if math.abs(lp.X) <= w * LOT_SIZE * 0.5 + clearance
					and math.abs(lp.Z) <= d * LOT_SIZE * 0.5 + clearance then
					return true
				end
			end
		end
	end
	return false
end

-- Is another planted prop already standing here? Footprint CIRCLES -- the catalog radius
-- the road and building rules are written in -- not bounding boxes: a tree's box is its
-- crown, and judging by crowns would refuse a wood. The Y span is part of the test, so a
-- shape seated on top of another one still passes.
-- ponytail: O(props) scan, the same accepted cost as the seat probe the ghost already runs
-- every frame. Index by map cell if it ever shows up in a profile.
local OVERLAP_EPS = 0.05
function PlacementFit.propAt(base: Vector3, radius: number, height: number, skip: Instance?): boolean
	local city = PlacementFit.cityRoot()
	local nature = city and city:FindFirstChild("Nature")
	if not nature then return false end
	local cy = base.Y + height * 0.5
	for _, m in nature:GetChildren() do
		if m:IsA("Model") and m ~= skip then
			local key = m:GetAttribute("NatureKey")
			local entry = if typeof(key) == "string" then NatureCatalog.get(key) else nil
			if entry then
				local r = entry.radius * (tonumber(m:GetAttribute("NatureScale")) or 1)
				local cf, size = m:GetBoundingBox()
				local dx, dz = cf.Position.X - base.X, cf.Position.Z - base.Z
				if math.sqrt(dx * dx + dz * dz) < radius + r - OVERLAP_EPS
					and math.abs(cf.Position.Y - cy) < (height + size.Y) * 0.5 - OVERLAP_EPS then
					return true
				end
			end
		end
	end
	return false
end

return PlacementFit
