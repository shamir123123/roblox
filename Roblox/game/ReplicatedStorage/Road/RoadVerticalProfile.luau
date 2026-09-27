--!strict

-- Vertical profile policy for placed road segments, shared by the server
-- (authoritative conditioning + validation in RoadService) and the client
-- (ghost preview + pre-check in RoadPlacementSnapper), so the preview matches
-- what the server will actually build.

local BezierUtil = require(script.Parent.BezierUtil)

local RoadVerticalProfile = {}

local function cubicCoeffs(t: number): (number, number, number, number)
	local u = 1 - t
	return u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t
end

-- Replace the handle heights so the curve's vertical profile is a smoothstep
-- between the endpoint heights: zero vertical slope at both ends, monotone in
-- between. Roads land level at junctions (keeping intersections near-planar)
-- and can never overshoot into a hump, regardless of how the endpoints snapped.
function RoadVerticalProfile.condition(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3): (Vector3, Vector3)
	return Vector3.new(p1.X, p0.Y, p1.Z), Vector3.new(p2.X, p3.Y, p2.Z)
end

-- Constant-grade variant: space the handle heights evenly (1/3, 2/3) between the
-- endpoint heights so the curve's Y is LINEAR in t -- a straight ramp from A to B
-- instead of the smoothstep's flat landings. Used when a segment is constSlope.
function RoadVerticalProfile.conditionLinear(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3): (Vector3, Vector3)
	local dy = p3.Y - p0.Y
	return Vector3.new(p1.X, p0.Y + dy / 3, p1.Z), Vector3.new(p2.X, p0.Y + dy * 2 / 3, p2.Z)
end

-- Terrain-following ground profile. The caller provides road-center Y at a sampled XZ
-- point (terrain surface plus road half-thickness). We solve p1.Y/p2.Y so the cubic
-- passes through terrain samples at 1/3 and 2/3 of the curve instead of only ramping
-- between endpoints; this avoids carving a hill just because both endpoints are low.
function RoadVerticalProfile.conditionToSurface(
	p0: Vector3,
	p1: Vector3,
	p2: Vector3,
	p3: Vector3,
	surfaceYAt: (number, number) -> number?
): (Vector3, Vector3)
	local tA, tB = 1 / 3, 2 / 3
	local aPt = BezierUtil.point(p0, p1, p2, p3, tA)
	local bPt = BezierUtil.point(p0, p1, p2, p3, tB)
	local targetA = surfaceYAt(aPt.X, aPt.Z)
	local targetB = surfaceYAt(bPt.X, bPt.Z)
	if targetA == nil or targetB == nil then
		return RoadVerticalProfile.condition(p0, p1, p2, p3)
	end

	local a0, a1, a2, a3 = cubicCoeffs(tA)
	local b0, b1, b2, b3 = cubicCoeffs(tB)
	local rhsA = targetA - a0 * p0.Y - a3 * p3.Y
	local rhsB = targetB - b0 * p0.Y - b3 * p3.Y
	local det = a1 * b2 - b1 * a2
	if math.abs(det) < 1e-6 then
		return RoadVerticalProfile.condition(p0, p1, p2, p3)
	end

	local y1 = (rhsA * b2 - rhsB * a2) / det
	local y2 = (a1 * rhsB - b1 * rhsA) / det
	return Vector3.new(p1.X, y1, p1.Z), Vector3.new(p2.X, y2, p2.Z)
end

-- Steepest local grade |dY| / horizontal run along the curve. Vertical climbs
-- with no horizontal travel report as infinite.
function RoadVerticalProfile.maxAbsGrade(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, samples: number?): number
	local n = samples or 24
	local maxGrade = 0
	local prev = p0
	for i = 1, n do
		local pt = BezierUtil.point(p0, p1, p2, p3, i / n)
		local dy = math.abs(pt.Y - prev.Y)
		local dx, dz = pt.X - prev.X, pt.Z - prev.Z
		local run = math.sqrt(dx * dx + dz * dz)
		if run > 1e-4 then
			maxGrade = math.max(maxGrade, dy / run)
		elseif dy > 0.01 then
			return math.huge
		end
		prev = pt
	end
	return maxGrade
end

return RoadVerticalProfile
