--!strict

local BezierUtil = {}

function BezierUtil.point(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: number): Vector3
	local u = 1 - t
	local uu = u * u
	local tt = t * t
	return p0 * (uu * u) + p1 * (3 * uu * t) + p2 * (3 * u * tt) + p3 * (tt * t)
end

function BezierUtil.tangent(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: number): Vector3
	local u = 1 - t
	return (p1 - p0) * (3 * u * u) + (p2 - p1) * (6 * u * t) + (p3 - p2) * (3 * t * t)
end

function BezierUtil.secondDerivative(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: number): Vector3
	local u = 1 - t
	return (p2 - p1 - p1 + p0) * (6 * u) + (p3 - p2 - p2 + p1) * (6 * t)
end

function BezierUtil.minRadius(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, samples: number): number
	local minR = math.huge
	for i = 0, samples do
		local t = i / samples
		local d1 = BezierUtil.tangent(p0, p1, p2, p3, t)
		local d2 = BezierUtil.secondDerivative(p0, p1, p2, p3, t)
		local cross = math.abs(d1.X * d2.Z - d1.Z * d2.X)
		local speedSq = d1.X * d1.X + d1.Z * d1.Z
		if speedSq > 1e-8 then

			local kappa = cross / (speedSq * math.sqrt(speedSq))
			if kappa > 1e-6 then
				minR = math.min(minR, 1 / kappa)
			end
		end
	end
	return minR
end

function BezierUtil.splitAt(
	p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, s: number
): (Vector3, Vector3, Vector3, Vector3, Vector3, Vector3, Vector3, Vector3)
	local p01  = p0:Lerp(p1,  s)
	local p12  = p1:Lerp(p2,  s)
	local p23  = p2:Lerp(p3,  s)
	local p012 = p01:Lerp(p12, s)
	local p123 = p12:Lerp(p23, s)
	local p0123 = p012:Lerp(p123, s)
	return p0, p01, p012, p0123,
	p0123, p123, p23, p3
end

-- Control points of the cubic restricted to the parameter range [ta, tb] (0 <= ta < tb <= 1).
-- Subdivision is exact, so the sub-curve traces the same path over that range -- used to split
-- a long road into capped-length sub-segments without changing its shape.
function BezierUtil.subCurve(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, ta: number, tb: number): (Vector3, Vector3, Vector3, Vector3)
	local a0, a1, a2, a3 = p0, p1, p2, p3
	if ta > 1e-6 then
		local _, _, _, _, r0, r1, r2, r3 = BezierUtil.splitAt(p0, p1, p2, p3, ta)
		a0, a1, a2, a3 = r0, r1, r2, r3
		tb = (tb - ta) / (1 - ta)
	end
	if tb < 1 - 1e-6 then
		local l0, l1, l2, l3 = BezierUtil.splitAt(a0, a1, a2, a3, tb)
		return l0, l1, l2, l3
	end
	return a0, a1, a2, a3
end

function BezierUtil.length(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, samples: number): number
	local total = 0
	local prev = p0
	for i = 1, samples do
		local pt = BezierUtil.point(p0, p1, p2, p3, i / samples)
		total += (pt - prev).Magnitude
		prev = pt
	end
	return total
end

-- Conservative broad-phase for "can this curve come within `radius` of `pos`?". A cubic
-- always lies inside the convex hull of its control points, so the hull's bounding circle can
-- rule a segment OUT but never wrongly rule one IN -- callers keep their exact test and use
-- this only to skip work. `yTol`, when given, also rejects on the vertical gap (the layered
-- road checks). No allocation and ~30 flops, against the ~35 curve evaluations closestParam
-- would otherwise spend on a segment that cannot possibly match.
function BezierUtil.hullNear(
	p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
	pos: Vector3, radius: number, yTol: number?
): boolean
	if yTol then
		local minY = math.min(p0.Y, p1.Y, p2.Y, p3.Y)
		local maxY = math.max(p0.Y, p1.Y, p2.Y, p3.Y)
		if pos.Y < minY - yTol or pos.Y > maxY + yTol then
			return false
		end
	end
	local cx = (p0.X + p1.X + p2.X + p3.X) * 0.25
	local cz = (p0.Z + p1.Z + p2.Z + p3.Z) * 0.25
	local a0x, a0z = p0.X - cx, p0.Z - cz
	local a1x, a1z = p1.X - cx, p1.Z - cz
	local a2x, a2z = p2.X - cx, p2.Z - cz
	local a3x, a3z = p3.X - cx, p3.Z - cz
	local r2 = math.max(
		a0x * a0x + a0z * a0z,
		a1x * a1x + a1z * a1z,
		a2x * a2x + a2z * a2z,
		a3x * a3x + a3z * a3z
	)
	local dx, dz = pos.X - cx, pos.Z - cz
	local reach = math.sqrt(r2) + radius
	return dx * dx + dz * dz <= reach * reach
end

function BezierUtil.closestParam(
	p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
	pos: Vector3,
	samples: number
): number
	local bestT = 0
	local bestDistSq = math.huge
	local px, py, pz = pos.X, pos.Y, pos.Z
	for i = 0, samples do
		local t = i / samples
		local u = 1 - t
		local uu, tt = u*u, t*t
		local b0, b1, b2, b3 = uu*u, 3*uu*t, 3*u*tt, tt*t
		local qx = p0.X*b0 + p1.X*b1 + p2.X*b2 + p3.X*b3
		local qy = p0.Y*b0 + p1.Y*b1 + p2.Y*b2 + p3.Y*b3
		local qz = p0.Z*b0 + p1.Z*b1 + p2.Z*b2 + p3.Z*b3
		local dx, dy, dz = qx - px, qy - py, qz - pz
		local dSq = dx*dx + dy*dy + dz*dz
		if dSq < bestDistSq then
			bestDistSq = dSq
			bestT = t
		end
	end
	local t = bestT
	for _ = 1, 2 do
		local pt  = BezierUtil.point(p0, p1, p2, p3, t)
		local tan = BezierUtil.tangent(p0, p1, p2, p3, t)
		local tanLen2 = tan:Dot(tan)
		if tanLen2 < 1e-10 then break end
		local dt = (pt - pos):Dot(tan) / tanLen2
		t = math.clamp(t - dt, 0, 1)
	end
	return t
end

-- True when every component is a real, finite number (no NaN/inf). Cheap shared guard so
-- both the client pre-check and the server validate can reject bad control points before
-- feeding them into curve math (which would otherwise read past buffers / divide by zero).
function BezierUtil.isFiniteVector(v: Vector3): boolean
	return v.X == v.X and v.Y == v.Y and v.Z == v.Z
		and v.X ~= math.huge and v.X ~= -math.huge
		and v.Y ~= math.huge and v.Y ~= -math.huge
		and v.Z ~= math.huge and v.Z ~= -math.huge
end

-- True when the curve crosses itself in plan view (a knotted "crazy" road / loop). Samples
-- the curve into a polyline and tests every pair of NON-adjacent chords for a real XZ
-- segment intersection -- so a straight or gently bending road (whose chords never cross) is
-- never flagged, regardless of length, while a genuine fold is always caught. When yTol is
-- given, two chords at very different heights (e.g. a deck over a tunnel) are not counted.
-- Pure; O(samples^2) with small samples.
local function ccw(ax: number, az: number, bx: number, bz: number, cx: number, cz: number): number
	return (bx - ax) * (cz - az) - (bz - az) * (cx - ax)
end
function BezierUtil.selfIntersects(
	p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
	samples: number, yTol: number?
): boolean
	local n = math.max(4, samples)
	local pts = table.create(n + 1)
	for i = 0, n do
		pts[i + 1] = BezierUtil.point(p0, p1, p2, p3, i / n)
	end
	for i = 1, n - 1 do
		local a, b = pts[i], pts[i + 1]
		-- j starts at i+2 so adjacent chords (which share an endpoint) are skipped.
		for j = i + 2, n do
			local c, d = pts[j], pts[j + 1]
			if yTol ~= nil then
				local yA = (a.Y + b.Y) * 0.5
				local yB = (c.Y + d.Y) * 0.5
				if math.abs(yA - yB) > yTol then continue end
			end
			local d1 = ccw(c.X, c.Z, d.X, d.Z, a.X, a.Z)
			local d2 = ccw(c.X, c.Z, d.X, d.Z, b.X, b.Z)
			local d3 = ccw(a.X, a.Z, b.X, b.Z, c.X, c.Z)
			local d4 = ccw(a.X, a.Z, b.X, b.Z, d.X, d.Z)
			if ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0))
				and ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0)) then
				return true
			end
		end
	end
	return false
end

function BezierUtil.closestPoint(
	p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
	pos: Vector3,
	samples: number
): Vector3
	local t = BezierUtil.closestParam(p0, p1, p2, p3, pos, samples)
	return BezierUtil.point(p0, p1, p2, p3, t)
end

return BezierUtil
