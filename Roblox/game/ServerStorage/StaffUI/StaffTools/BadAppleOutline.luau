--!strict
-- BadAppleOutline -- turns a frame's silhouette into the road runs a player would draw.
--
-- Tiling the rim cell by cell can never look hand-placed: it is grid-snapped by
-- construction, so it always reads as a staircase. A person laying this out draws a few
-- LONG roads that meet at corners. So each frame is traced instead:
--
--   1. rim cells   -- shape cells with at least one non-shape 4-neighbour
--   2. walk        -- chain them into ordered runs
--   3. simplify    -- Ramer-Douglas-Peucker, within `tol` cells of the true rim
--
-- The caller then lays ONE stretched road piece per run, so a long straight edge is a single
-- road rather than thirty tiles butted together.
--
-- On tolerance, which has now been both ways round. Merging only EXACTLY collinear steps
-- welds the outline to the block boundary, but on a curved silhouette it yields runs of
-- about two cells -- and every piece is drawn with an overshoot so its corners close, which
-- on a two-cell piece is a third of its own length. Pieces visibly doubled over their
-- neighbours the whole way round.
--
-- A tolerance buys longer runs, so the overshoot becomes proportionally small and the
-- doubling goes away. It costs exactness: the road may sit up to `tol` cells off the block
-- boundary. That is the deliberate trade -- fewer, longer, cleaner roads over a perfectly
-- blocky outline.
--
-- Steps are 8-way. They were orthogonal-only for one revision and that was a bad mistake:
-- along a 45-degree boundary the rim cells are DIAGONALLY adjacent and never orthogonally
-- adjacent, so the walk could not chain a single one of them and every cell collapsed into
-- its own one-cell run -- the whole outline came out as scattered fragments. Orthogonals are
-- still tried first, so a run only turns diagonal where the boundary genuinely does.

local BadAppleOutline = {}

local DX = { 0, 1, 0, -1, 1, 1, -1, -1 }
local DZ = { 1, 0, -1, 0, 1, -1, -1, 1 }

export type Run = { ax: number, az: number, bx: number, bz: number }

-- Squared perpendicular distance from p to the line a->b, in cell units.
local function distSq(px: number, pz: number, ax: number, az: number, bx: number, bz: number): number
	local dx, dz = bx - ax, bz - az
	local len = dx * dx + dz * dz
	if len < 1e-12 then
		local ex, ez = px - ax, pz - az
		return ex * ex + ez * ez
	end
	local cross = (px - ax) * dz - (pz - az) * dx
	return cross * cross / len
end

-- Iterative RDP -- an explicit stack, not recursion, since a walk can run to hundreds of
-- cells. Marks the survivors of pts[first..last] in `keep`.
local function simplify(pts: { number }, first: number, last: number, tol: number, keep: { boolean })
	local stack = { first, last }
	keep[first] = true
	keep[last] = true
	while #stack > 0 do
		local hi = table.remove(stack) :: number
		local lo = table.remove(stack) :: number
		if hi - lo < 2 then
			continue
		end
		local ax, az = pts[lo * 2 - 1], pts[lo * 2]
		local bx, bz = pts[hi * 2 - 1], pts[hi * 2]
		local worst, worstAt = -1, -1
		for i = lo + 1, hi - 1 do
			local d = distSq(pts[i * 2 - 1], pts[i * 2], ax, az, bx, bz)
			if d > worst then
				worst, worstAt = d, i
			end
		end
		if worst > tol * tol then
			keep[worstAt] = true
			table.insert(stack, lo)
			table.insert(stack, worstAt)
			table.insert(stack, worstAt)
			table.insert(stack, hi)
		end
	end
end

-- `rim` holds 1 for a rim cell, 0 otherwise. Returns how many runs were written into `out`,
-- in CELL coordinates -- the caller scales them into the world. `out` and the scratch
-- buffers are reused across frames: this runs 30 times a second and must not allocate.
function BadAppleOutline.trace(
	rim: buffer,
	W: number,
	H: number,
	tol: number,
	visited: buffer,
	out: { Run }
): number
	buffer.fill(visited, 0, 0)
	local runCount = 0
	local pts: { number } = {}
	local keep: { boolean } = {}

	for seed = 0, W * H - 1 do
		if buffer.readu8(rim, seed) == 0 or buffer.readu8(visited, seed) ~= 0 then
			continue
		end

		local n = 0
		local cur = seed
		while true do
			buffer.writeu8(visited, cur, 1)
			n += 1
			pts[n * 2 - 1] = cur % W
			pts[n * 2] = cur // W
			local row, col = cur // W, cur % W
			local nextIdx = -1
			for d = 1, 8 do
				local nc, nr = col + DX[d], row + DZ[d]
				if nc < 0 or nc >= W or nr < 0 or nr >= H then
					continue
				end
				local ni = nr * W + nc
				if buffer.readu8(rim, ni) ~= 0 and buffer.readu8(visited, ni) == 0 then
					nextIdx = ni
					break
				end
			end
			if nextIdx < 0 then
				break
			end
			cur = nextIdx
		end

		if n == 1 then
			-- A rim cell with no rim neighbour at all. It still needs a road, or the
			-- outline would simply have a hole there, so emit a degenerate run and let the
			-- caller give it one cell's worth of length.
			runCount += 1
			local r = out[runCount]
			if r then
				r.ax, r.az, r.bx, r.bz = pts[1], pts[2], pts[1], pts[2]
			else
				out[runCount] = { ax = pts[1], az = pts[2], bx = pts[1], bz = pts[2] }
			end
		elseif n >= 2 then
			table.clear(keep)
			simplify(pts, 1, n, tol, keep)
			local prev = -1
			for i = 1, n do
				if not keep[i] then
					continue
				end
				if prev > 0 then
					runCount += 1
					local r = out[runCount]
					if r then
						r.ax, r.az = pts[prev * 2 - 1], pts[prev * 2]
						r.bx, r.bz = pts[i * 2 - 1], pts[i * 2]
					else
						out[runCount] = {
							ax = pts[prev * 2 - 1], az = pts[prev * 2],
							bx = pts[i * 2 - 1], bz = pts[i * 2],
						}
					end
				end
				prev = i
			end
		end
	end
	return runCount
end

return BadAppleOutline
