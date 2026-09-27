--!strict
-- ApproachBend -- CS2 approach shaping.
--
-- A road drawn into or out of a junction at a shallow angle used to be REFUSED ("angle too
-- shallow", "crosses the junction too sharply"). It is now BENT instead: the handle at that end
-- rotates until the arm leaves the node at APPROACH_BEND_MIN_ANGLE_RAD, and the cubic swings
-- back to the point the player actually aimed at. The junction gets a clean gore, the two roads
-- stop overlapping, and nothing is rejected.
--
-- Pure math, no graph access: the caller passes the arm directions it can see, so the client
-- ghost and the server validator run the identical function over their own copies of the
-- network and land on the same curve.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BezierUtil = require(ReplicatedStorage.Road.BezierUtil)
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)

local ApproachBend = {}

local function flatUnit(v: Vector3): Vector3?
	local f = Vector3.new(v.X, 0, v.Z)
	if f.Magnitude < 1e-4 then
		return nil
	end
	return f.Unit
end

local function rotY(v: Vector3, a: number): Vector3
	local c, s = math.cos(a), math.sin(a)
	return Vector3.new(v.X * c - v.Z * s, v.Y, v.X * s + v.Z * c)
end

-- Turn `dir` (leaving a node) the short way out of every arm's cone until it clears
-- `minAngle` from all of them. Three passes, because turning out of one arm can turn into
-- the next; a node whose arms are packed tighter than the minimum the whole way round has
-- no answer at all, and keeps the last attempt rather than spinning.
function ApproachBend.clearDir(dir: Vector3, arms: { Vector3 }, minAngle: number): Vector3
	local d = flatUnit(dir)
	if not d or #arms == 0 or minAngle <= 1e-6 then
		return dir
	end
	for _ = 1, 3 do
		local worstArm: Vector3? = nil
		local worst = minAngle
		for _, a in arms do
			local u = flatUnit(a)
			if u then
				local ang = math.acos(math.clamp(d:Dot(u), -1, 1))
				if ang < worst then
					worst = ang
					worstArm = u
				end
			end
		end
		if not worstArm then
			break
		end
		-- Which side of the arm `d` already sits on decides which way to keep turning, so the
		-- road bends the way the player was heading. Dead-on (cross ~ 0) picks one side --
		-- arbitrary, but deterministic, so client and server agree.
		local cross = worstArm.X * d.Z - worstArm.Z * d.X
		local sign = if cross >= 0 then 1 else -1
		d = flatUnit(rotY(d, sign * (minAngle - worst))) or d
	end
	return d
end

local function bentHandles(
	p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
	armsStart: { Vector3 }, armsEnd: { Vector3 },
	minAngle: number
): (Vector3, Vector3)
	local n1, n2 = p1, p2
	if #armsStart > 0 then
		local h = Vector3.new(p1.X - p0.X, 0, p1.Z - p0.Z)
		local len = h.Magnitude
		if len > 1e-3 then
			local d = ApproachBend.clearDir(h, armsStart, minAngle)
			n1 = Vector3.new(p0.X + d.X * len, p1.Y, p0.Z + d.Z * len)
		end
	end
	if #armsEnd > 0 then
		local h = Vector3.new(p2.X - p3.X, 0, p2.Z - p3.Z)
		local len = h.Magnitude
		if len > 1e-3 then
			local d = ApproachBend.clearDir(h, armsEnd, minAngle)
			n2 = Vector3.new(p3.X + d.X * len, p2.Y, p3.Z + d.Z * len)
		end
	end
	return n1, n2
end

-- New p1/p2 for a candidate whose ends meet `armsStart` / `armsEnd` (each direction pointing
-- AWAY from the node, the same convention RoadNetwork.validateAngles measures against).
--
-- `minRadius` is the road type's own curve limit. A bend the cubic cannot physically take is
-- worse than the shallow join it fixes -- it just trips the curvature gate instead -- so the
-- rotation is backed off until the curve is drivable, and a road with no room for any bend
-- keeps the handles it came in with.
function ApproachBend.apply(
	p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
	armsStart: { Vector3 }, armsEnd: { Vector3 },
	minRadius: number?,
	minAngle: number?
): (Vector3, Vector3)
	local want = minAngle or RoadConstants.APPROACH_BEND_MIN_ANGLE_RAD
	if want <= 1e-6 or (#armsStart == 0 and #armsEnd == 0) then
		return p1, p2
	end
	for _, frac in { 1, 0.66, 0.33 } do
		local n1, n2 = bentHandles(p0, p1, p2, p3, armsStart, armsEnd, want * frac)
		if not minRadius then
			return n1, n2
		end
		if BezierUtil.minRadius(p0, n1, n2, p3, 20) >= minRadius
			and not BezierUtil.selfIntersects(p0, n1, n2, p3, 20, RoadConstants.VERTICAL_CONNECT_TOLERANCE) then
			return n1, n2
		end
	end
	return p1, p2
end

return ApproachBend
