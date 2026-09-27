--!strict
-- RoadMoveGeometry -- pure curve math for the Move tool (CS2 "Move It" style).
-- Recomputes a segment's cubic control points when one endpoint moves (node drag)
-- or bends the curve through a grabbed point (segment drag). Shared so the client
-- preview and the server commit run the SAME math; the client only ever sends the
-- grab id + drag target, never geometry.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BezierUtil = require(ReplicatedStorage.Road.BezierUtil)
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)

local RoadMoveGeometry = {}

-- Handles this far (studs, flat) off the p0-p3 chord mean a deliberate curve;
-- anything closer rebuilds as a straight run after the move.
local STRAIGHT_EPS = 0.75
local RADIUS_SAMPLES = 24

local function flatOffChord(p0: Vector3, p3: Vector3, h: Vector3): number
	local chord = Vector3.new(p3.X - p0.X, 0, p3.Z - p0.Z)
	local len = chord.Magnitude
	if len < 1e-4 then return 0 end
	local d = chord / len
	local v = Vector3.new(h.X - p0.X, 0, h.Z - p0.Z)
	return (v - d * v:Dot(d)).Magnitude
end

function RoadMoveGeometry.isStraight(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3): boolean
	return flatOffChord(p0, p3, p1) <= STRAIGHT_EPS and flatOffChord(p0, p3, p2) <= STRAIGHT_EPS
end

-- Control points after dragging one endpoint to `target`. A straight segment
-- rebuilds as a straight run to the new endpoint; a curved one carries its
-- moved-end tangent handle along with the endpoint and keeps the far end fixed,
-- so the bend survives the move.
function RoadMoveGeometry.movedEndpoint(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, movedStart: boolean, target: Vector3): (Vector3, Vector3, Vector3, Vector3)
	if RoadMoveGeometry.isStraight(p0, p1, p2, p3) then
		local a = if movedStart then target else p0
		local b = if movedStart then p3 else target
		return a, a:Lerp(b, 1 / 3), a:Lerp(b, 2 / 3), b
	end
	if movedStart then
		return target, p1 + (target - p0), p2, p3
	end
	return p0, p1, p2 + (target - p3), target
end

-- Bend a segment so the curve passes through `mid` at t=0.5 with both endpoints
-- pinned: solve the quadratic through-point control, then elevate to cubic.
function RoadMoveGeometry.bendThrough(p0: Vector3, p3: Vector3, mid: Vector3): (Vector3, Vector3, Vector3, Vector3)
	local c = mid * 2 - (p0 + p3) * 0.5
	return p0, p0 + (c - p0) * (2 / 3), p3 + (c - p3) * (2 / 3), p3
end

-- Rotate a point about a vertical axis through `pivot` (Y preserved). Client
-- marquee rotation and the server's handle rebuild must share this exactly.
function RoadMoveGeometry.rotateY(p: Vector3, pivot: Vector3, angleRad: number): Vector3
	local c, s = math.cos(angleRad), math.sin(angleRad)
	local dx, dz = p.X - pivot.X, p.Z - pivot.Z
	return Vector3.new(pivot.X + dx * c - dz * s, p.Y, pivot.Z + dx * s + dz * c)
end

-- nil when the rebuilt curve is placeable; otherwise a short reason.
function RoadMoveGeometry.validate(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, roadType: string): string?
	if BezierUtil.length(p0, p1, p2, p3, 12) < RoadConstants.MIN_SEGMENT_LENGTH then
		return "too short"
	end
	if not RoadMoveGeometry.isStraight(p0, p1, p2, p3) then
		local spec = RoadTypeCatalog.getOrDefault(roadType)
		if BezierUtil.minRadius(p0, p1, p2, p3, RADIUS_SAMPLES) < RoadTypeCatalog.minCurveRadius(spec) then
			return "curve too tight"
		end
	end
	return nil
end

return RoadMoveGeometry
