--!strict
-- LOD: one detail ladder for every distance-scaled view in the game. Pure library --
-- require it directly, no lifecycle, no state.
--
-- Levels are picked by SCREEN-SPACE ERROR, not by raw stud distance. The standard metric is
-- how many pixels a world-space feature actually covers:
--
--     pixels = studs * viewportHeight / (2 * distance * tan(fovY / 2))
--
-- and detail is worth drawing while that stays above a small pixel budget (0.5-1.0px is the
-- usual accept threshold). Stud bands cannot express this: they bake in one resolution and
-- one field of view, and go wrong the moment either changes. Deriving the bands from the
-- metric means "far" means the same thing on a phone and on a 4K monitor.
--
--   1 NEAR -- full detail
--   2 MID  -- full shape, trimmed extras
--   3 FAR  -- coarse shape only
--   4 CULL -- build nothing
--
-- What each level MEANS is the caller's business; the ladder is shared so two systems never
-- disagree about where "far" starts.

local Workspace = game:GetService("Workspace")

local LOD = {}

LOD.NEAR = 1
LOD.MID = 2
LOD.FAR = 3
LOD.CULL = 4

-- Acceptable screen-space error in pixels. 0.5-1.0 is the standard band; 0.5 is its quality
-- end. Raise it for more aggressive LODing and more popping.
LOD.PIXEL_BUDGET = 0.5

-- The finest thing the city draws: a lane-marking ribbon. The ladder is tuned against it, so
-- the boundaries mean something concrete instead of being three round numbers.
local PAINT_WIDTH = 0.3

-- Level boundaries in pixels-per-stud:
--   NEAR while paint covers a whole pixel or more -- every detail is legible
--   MID  while paint is still above the budget    -- fine textures have stopped paying
--   FAR  while paint is under budget but a stud is not -- paint goes, shape stays
--   CULL when even a 1-stud feature is sub-budget -- nothing is resolvable
local BOUNDS = table.freeze({
	(LOD.PIXEL_BUDGET * 2) / PAINT_WIDTH,
	LOD.PIXEL_BUDGET / PAINT_WIDTH,
	LOD.PIXEL_BUDGET,
})

-- Geometry finer than this is below the pixel budget even with the camera on the tarmac, so
-- simplifying it away is free at every distance. Use it for bake-time thinning, where the
-- viewing distance is not yet known and must not be assumed.
LOD.LOSSLESS_STUDS = 0.01

-- Camera.FieldOfView is the VERTICAL fov in degrees, which is exactly what the formula wants.
function LOD.pixelsPerStud(distance: number, camera: Camera?): number
	local cam = camera or Workspace.CurrentCamera
	if not cam or distance <= 1e-3 then
		return math.huge
	end
	return (cam.ViewportSize.Y * 0.5) / (distance * math.tan(math.rad(cam.FieldOfView) * 0.5))
end

-- `from` is the eye position. Pass it explicitly when tiering many things in one pass. With
-- no camera at all (server, early boot) nothing can be judged distant, so everything is NEAR.
-- That direction of failure is deliberate: a missing camera must never silently cull the world.
-- `scale` stretches the ladder -- the player's Draw distance multiplier: 2 holds
-- full detail out to twice the distance, 0.4 degrades sooner.
function LOD.tierAt(position: Vector3, from: Vector3?, camera: Camera?, scale: number?): number
	local cam = camera or Workspace.CurrentCamera
	if not cam then
		return LOD.NEAR
	end

	local eye = from or cam.CFrame.Position
	local dist = (eye - position).Magnitude / math.max(scale or 1, 0.05)
	local pps = LOD.pixelsPerStud(dist, cam)

	if pps >= BOUNDS[1] then return LOD.NEAR end
	if pps >= BOUNDS[2] then return LOD.MID end
	if pps >= BOUNDS[3] then return LOD.FAR end
	return LOD.CULL
end

-- The world size of one pixel budget at this distance: geometry detail finer than this cannot
-- be seen from there, so it is safe to simplify away. This is the tolerance to hand `simplify`.
function LOD.toleranceStuds(distance: number, camera: Camera?): number
	local pps = LOD.pixelsPerStud(distance, camera)
	if pps == math.huge or pps <= 0 then
		return 0
	end
	return LOD.PIXEL_BUDGET / pps
end

-- Ramer-Douglas-Peucker: keep the points that carry the shape, drop the ones already within
-- `tolerance` of the line their neighbours describe. Returns the kept INDICES, ascending --
-- callers with parallel data (a road's two rails, per-station normals) need to know which
-- stations survived, not just the points.
--
-- Iterative, not recursive: a long road polyline would otherwise nest one frame per bend.
function LOD.simplifyIndices(points: { Vector3 }, tolerance: number): { number }
	local n = #points
	local out: { number } = {}

	if n == 0 then
		return out
	end
	if n < 3 or tolerance <= 0 then
		for i = 1, n do
			out[i] = i
		end
		return out
	end

	local keep = table.create(n, false)
	keep[1] = true
	keep[n] = true

	local stack: { { number } } = { { 1, n } }

	while #stack > 0 do
		local span = table.remove(stack) :: { number }
		local first, last = span[1], span[2]
		local a = points[first]
		local ab = points[last] - a
		local abLen = ab.Magnitude

		local worst = 0
		local worstAt = -1

		for i = first + 1, last - 1 do
			-- Perpendicular distance to the chord: |(P-A) x AB| / |AB|. A degenerate chord
			-- (the ends coincide) has no direction, so fall back to plain range from A.
			local d = if abLen < 1e-6
				then (points[i] - a).Magnitude
				else (points[i] - a):Cross(ab).Magnitude / abLen

			if d > worst then
				worst = d
				worstAt = i
			end
		end

		if worstAt > 0 and worst > tolerance then
			keep[worstAt] = true
			table.insert(stack, { first, worstAt })
			table.insert(stack, { worstAt, last })
		end
	end

	for i = 1, n do
		if keep[i] then
			table.insert(out, i)
		end
	end

	return out
end

function LOD.simplify(points: { Vector3 }, tolerance: number): { Vector3 }
	local kept = LOD.simplifyIndices(points, tolerance)
	if #kept == #points then
		return points
	end

	local out = table.create(#kept)
	for i, index in kept do
		out[i] = points[index]
	end
	return out
end

return LOD
