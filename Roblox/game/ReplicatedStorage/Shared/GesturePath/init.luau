--!strict
-- GesturePath
-- WHERE a row of things goes. Pure geometry: points in, points out. No catalog, no ghosts,
-- no network, no idea what is being placed or what it costs.
--
-- Extracted from NaturePlacementController when the Creations tool needed the same three
-- gestures. A second copy of arc-length sampling would have drifted exactly the way the
-- placement tools did before GhostPlacement existed -- and the failure would have been
-- quiet: a line of creations and a line of trees disagreeing about spacing, with nobody
-- able to say which was right.
--
-- Every point comes back flattened to the ground plane (Y = 0). Grounding is the caller's
-- job, because only the caller knows whether it wants the terrain surface, a heightmap
-- lookup, or an editor plate.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- The same cubic-bezier maths the road tool's Curved mode uses. Pure geometry: four
-- control points in, point/length out, no road-network dependency.
local BezierUtil = require(ReplicatedStorage:WaitForChild("Road"):WaitForChild("BezierUtil"))

local GesturePath = {}

-- Below this, a "row" is thousands of overlapping objects and one dragged gesture can
-- exhaust any server cap instantly.
local MIN_SPACING = 2
-- Resolution for measuring the curve's length and mapping distance back to t. Small and
-- fixed: the walk below is O(ARC_SAMPLES) per point and this is plenty for a placement row.
local ARC_SAMPLES = 24
-- Nudge before flooring the point count.
--
-- A straight length comes from ONE Magnitude and is exact; a curve length is 24 chord
-- lengths added up and lands a hair short. So a 100-stud drag at spacing 20 gives
-- floor(5.0)+1 = 6 points one way and floor(4.99999)+1 = 5 the other -- the two disagree
-- by one whenever the length is an exact multiple of the spacing, which for round numbers
-- dragged along an axis is often. The epsilon makes both land on the same count.
local COUNT_EPSILON = 1e-6

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- Evenly spaced points from `a` to `b` along the ground plane. `maxCount` is the caller's
-- cap -- it must not exceed whatever its server accepts per call, or the tail is silently
-- dropped after the player has already seen it previewed.
function GesturePath.row(a: Vector3, b: Vector3, spacing: number, maxCount: number): { Vector3 }
	local fa, fb = flat(a), flat(b)
	local delta = fb - fa
	local len = delta.Magnitude
	local pts: { Vector3 } = {}
	if len < 1e-3 then
		pts[1] = fa
		return pts
	end
	local dir = delta / len
	local step = math.max(spacing, MIN_SPACING)
	local count = math.min(math.floor(len / step + COUNT_EPSILON) + 1, maxCount)
	for i = 0, count - 1 do
		local p = fa + dir * (i * step)
		pts[#pts + 1] = flat(p)
	end
	return pts
end

-- The 3 clicked points (start, bend, end) as a cubic bezier's 4 control points. Identical
-- formula to RoadPlacementSnapper's "Curved" mode: both handles sit 2/3 of the way from
-- each endpoint toward the bend, so the curve passes close to where you dragged without
-- needing two separate handles.
function GesturePath.controlPoints(s: Vector3, q: Vector3, e: Vector3): (Vector3, Vector3, Vector3, Vector3)
	local firstHandle = s + (q - s) * (2 / 3)
	local secondHandle = e + (q - e) * (2 / 3)
	return s, firstHandle, secondHandle, e
end

-- Evenly spaced points along the bezier's ARC LENGTH -- not its parameter t, which would
-- bunch points up on the tight part of the bend. Same contract and cap as row().
function GesturePath.curve(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, spacing: number, maxCount: number): { Vector3 }
	local totalLen = BezierUtil.length(p0, p1, p2, p3, ARC_SAMPLES)
	local pts: { Vector3 } = {}
	if totalLen < 1e-3 then
		pts[1] = flat(p0)
		return pts
	end
	local step = math.max(spacing, MIN_SPACING)
	local count = math.min(math.floor(totalLen / step + COUNT_EPSILON) + 1, maxCount)

	-- Cumulative chord length at each arc sample, so "distance along the curve" -> t is a
	-- walk of a small fixed table rather than a search.
	local cum: { number } = table.create(ARC_SAMPLES + 1)
	cum[1] = 0
	local prev = p0
	for i = 1, ARC_SAMPLES do
		local pt = BezierUtil.point(p0, p1, p2, p3, i / ARC_SAMPLES)
		cum[i + 1] = cum[i] + (pt - prev).Magnitude
		prev = pt
	end

	local function tAtDistance(d: number): number
		if d <= 0 then return 0 end
		if d >= totalLen then return 1 end
		for i = 1, ARC_SAMPLES do
			if cum[i + 1] >= d then
				local segLen = cum[i + 1] - cum[i]
				local frac = if segLen > 1e-6 then (d - cum[i]) / segLen else 0
				return ((i - 1) + frac) / ARC_SAMPLES
			end
		end
		return 1
	end

	for i = 0, count - 1 do
		local t = tAtDistance(i * step)
		pts[#pts + 1] = flat(BezierUtil.point(p0, p1, p2, p3, t))
	end
	return pts
end

return GesturePath
