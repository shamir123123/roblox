--!strict
-- The ground march. No framework -- `require(...).run()` asserts.
--
-- This is the load-bearing half of moving the ground off workspace.Terrain: the ground
-- mesh carries NO collision geometry, so every "what is under the cursor?" answer in the
-- game now comes from this march instead of a raycast. If it is wrong, every tool is wrong
-- and nothing else in the codebase would notice.
--
-- Run it through the loadstring+setfenv shim with TerrainBuildController stubbed, so the
-- surface under test is a known analytic field rather than whatever city happens to be
-- loaded. `run(CursorRay, surfaceY)` takes both, because the module reads its heights
-- through that stub.
--
-- The one it exists for is TUNNELLING: the march takes steps far longer than a heightmap
-- corner, and a step that is one stud too long walks THROUGH a ridge and lands the cursor
-- on the valley behind it. Check C is that case, and the step bound (SLOPE_CLAMP_DEG) is
-- the only reason it cannot happen.

local M = {}

-- A ridge across X with a trough behind it: steep enough to be a real test, still inside
-- SLOPE_CLAMP_DEG so the march's step bound is honest about it.
function M.field(x: number, _z: number): number
	return 120 * math.exp(-((x - 200) / 90) ^ 2)
end

function M.run(CursorRay: any, surfaceY: (number, number) -> number): boolean
	local function assertOnSurface(p: Vector3?, label: string): Vector3
		assert(p, `{label}: expected a hit, got nil`)
		local hit = p :: Vector3
		local gap = hit.Y - surfaceY(hit.X, hit.Z)
		assert(math.abs(gap) < 0.5, `{label}: landed {gap} studs off the surface`)
		return hit
	end

	-- A: straight down lands on the surface, at the column it started in.
	for _, x in { -400, 0, 150, 200, 260, 900 } do
		local p = assertOnSurface(
			CursorRay.terrainRay(Vector3.new(x, 900, 30), Vector3.new(0, -1, 0), 4000),
			`down at x={x}`
		)
		assert(math.abs(p.X - x) < 0.01 and math.abs(p.Z - 30) < 0.01, `down at x={x} drifted sideways`)
	end

	-- B: an ordinary angled cursor ray, the everyday case.
	local angled = assertOnSurface(
		CursorRay.terrainRay(Vector3.new(-600, 700, -600), Vector3.new(1, -0.55, 1), 6000),
		"angled"
	)
	assert(angled.Y > -1, "angled ray landed below the whole field")

	-- C: TUNNELLING. A shallow ray flying in from -X at ridge height must stop ON the near
	-- face of the ridge. Land past its crest (x > 200) and the march stepped through it --
	-- which is exactly what a cursor picking the far valley through a hill looks like.
	local graze = assertOnSurface(
		CursorRay.terrainRay(Vector3.new(-900, 95, 0), Vector3.new(1, -0.02, 0), 6000),
		"grazing"
	)
	assert(graze.X < 200, `grazing ray passed through the ridge: landed at x={graze.X}, crest is x=200`)

	-- D: no hit where there is none.
	assert(CursorRay.terrainRay(Vector3.new(0, -50, 0), Vector3.new(0, -1, 0), 4000) == nil,
		"a ray starting UNDER the ground reported a downward hit")
	assert(CursorRay.terrainRay(Vector3.new(0, 900, 0), Vector3.new(0, 1, 0), 4000) == nil,
		"a ray pointing straight up reported a hit")
	assert(CursorRay.terrainRay(Vector3.new(0, 900, 0), Vector3.new(0, -1, 0), 50) == nil,
		"a ray shorter than the drop to the ground reported a hit")

	print("[CursorRay.spec] OK")
	return true
end

return M
