--!strict
-- RoadProximity -- "is this world point too close to a road?", answered once for both sides.
--
-- The server is authoritative: NaturePlaceService rejects a prop whose footprint overlaps a
-- carriageway. The client previews that same rule to tint a ghost red BEFORE the click.
-- Those were two separate implementations, and the client's carried the comment "mirrors
-- RoadService.isPointNearRoad exactly" -- an instruction to a future editor to keep two
-- copies in step by hand. When they drift the ghost goes green and the server silently
-- refuses the placement, which reads as the game ignoring your click.
--
-- The only real difference between the two was where the segments came from (the server's
-- live RoadNetwork vs the client's replicated DataCache mirror), so that is the parameter.
-- `segments` may be an array or an id-keyed map -- both sides pass their own shape.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RoadConstants   = require(ReplicatedStorage.Road.RoadConstants)
local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)
local BezierUtil      = require(ReplicatedStorage.Road.BezierUtil)
-- Pure frozen data (key -> footprint radius). Needed to answer the question below from
-- the ROAD's side, in the same numbers the prop-side rule is already written in.
local NatureCatalog   = require(ReplicatedStorage.Nature.NatureCatalog)

local RoadProximity = {}

export type SegmentLike = {
	p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
	roadType: string,
}

-- Two points are on the same road layer when their heights are within the tolerance the
-- whole road system connects by. This is the gate that stops a bridge deck and the ground
-- beneath it counting as the same place; it must be the SAME number everywhere or the
-- client and server disagree about what is under a point.
-- A PROP IS NOT A POINT, though. A tree seated on terrain fifteen studs under an
-- elevated deck passed the old base-vs-base test (its base genuinely IS a layer down)
-- and then grew straight up through the carriageway -- which is how trees came to stand
-- on an elevated road whose ground had been sculpted up towards it. `height` is how far
-- the thing reaches ABOVE its base, so the gate answers "does this reach the road",
-- not "is its base level with the road". Height 0 is the old point-vs-point test exactly.
function RoadProximity.reachesLayer(base: Vector3, foot: Vector3, height: number): boolean
	local tol = RoadConstants.VERTICAL_CONNECT_TOLERANCE
	return foot.Y >= base.Y - tol and foot.Y <= base.Y + math.max(height, tol)
end

function RoadProximity.flatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- Road specs are immutable, and this runs per segment per frame on the client preview, so
-- the catalog lookup is memoised.
local _specCache: { [string]: RoadTypeCatalog.RoadTypeSpec } = {}
function RoadProximity.roadSpec(roadType: string): RoadTypeCatalog.RoadTypeSpec
	local cached = _specCache[roadType]
	if cached then return cached end
	local spec = RoadTypeCatalog.getOrDefault(roadType)
	_specCache[roadType] = spec
	return spec
end

-- True when a prop based at `pos` -- footprint `footprintRadius`, reaching `height` studs
-- up from that base -- overlaps any road's carriageway on a layer it actually touches.
function RoadProximity.isPointNearRoad(segments: any, pos: Vector3, footprintRadius: number, height: number?): boolean
	local h = height or 0
	for _, seg in segments do
		local t = BezierUtil.closestParam(seg.p0, seg.p1, seg.p2, seg.p3, pos, RoadConstants.SNAP_SEGMENT_SAMPLES)
		local foot = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
		if not RoadProximity.reachesLayer(pos, foot, h) then continue end
		local hostHalfWidth = RoadProximity.roadSpec(seg.roadType).width * 0.5
		if RoadProximity.flatDistance(foot, pos) <= hostHalfWidth + footprintRadius then
			return true
		end
	end
	return false
end

-- The points a road's pavement is swept along when something standing under it has to be
-- cleared: roughly one every PAVEMENT_SAMPLE_STEP studs, between 8 and 256 of them.
-- Shared so the client's preview sweeps the SAME corridor the server clears -- a different
-- cadence here highlights one set of houses and demolishes another.
RoadProximity.PAVEMENT_SAMPLE_STEP = 8
function RoadProximity.samplePavement(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3): { Vector3 }
	local segLen = BezierUtil.length(p0, p1, p2, p3, 24)
	local n = math.clamp(math.ceil(segLen / RoadProximity.PAVEMENT_SAMPLE_STEP), 8, 256)
	local pts = table.create(n + 1)
	for i = 0, n do
		pts[i + 1] = BezierUtil.point(p0, p1, p2, p3, i / n)
	end
	return pts
end

-- ------------------------------------------------------------- the other way --
-- The same overlap, asked from the road's side: which planted props does this pavement
-- cover? The road tool highlights that list in white while the ghost is up and clears it
-- when the road goes down, so what lights up is exactly what disappears -- and it is the
-- same rule that refuses planting a tree on a road in the first place.

-- A placed prop's base, footprint radius and height -- the three numbers every rule here
-- is written in. nil for anything in the folder that is not a placed prop.
local function propShape(m: Instance): (Vector3?, number, number)
	if not m:IsA("Model") then return nil, 0, 0 end
	local key = m:GetAttribute("NatureKey")
	local entry = if typeof(key) == "string" then NatureCatalog.get(key) else nil
	if not entry then return nil, 0, 0 end
	local scale = tonumber(m:GetAttribute("NatureScale")) or 1
	local _, size = (m :: Model):GetBoundingBox()
	-- Props pivot on their BASE, which is what isPointNearRoad measures a height up from.
	return m:GetPivot().Position, entry.radius * scale, size.Y
end

-- ponytail: O(props x segments), run on a throttled ghost rebuild and once per placement,
-- never per frame. Index the props by map cell if a large city starts to hitch here.
function RoadProximity.propsOnRoads(folder: Instance, segments: any): { Model }
	local out: { Model } = {}
	for _, m in folder:GetChildren() do
		local base, radius, height = propShape(m)
		if base and RoadProximity.isPointNearRoad(segments, base, radius, height) then
			out[#out + 1] = m :: Model
		end
	end
	return out
end

-- The same question for a roundabout, whose footprint is a disc rather than a curve.
-- `radius` is the outer pavement edge; `center.Y` is the ring's own layer, so a prop
-- under an elevated ring is left alone exactly as it is under an elevated deck.
function RoadProximity.propsInDisc(folder: Instance, center: Vector3, radius: number): { Model }
	local out: { Model } = {}
	for _, m in folder:GetChildren() do
		local base, r, height = propShape(m)
		if base and RoadProximity.reachesLayer(base, center, height)
			and RoadProximity.flatDistance(center, base) <= radius + r then
			out[#out + 1] = m :: Model
		end
	end
	return out
end

return RoadProximity
