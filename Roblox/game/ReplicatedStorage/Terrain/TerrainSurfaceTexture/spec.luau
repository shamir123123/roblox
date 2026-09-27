--!strict
-- The surface grain has to TILE. No framework -- `require(...).run()` asserts.
--
-- The UVs repeat every MESH_TEXTURE_STUDS studs, so this one image is laid end to end over
-- the entire 8192-stud map. If its edges do not match, the mismatch is not a subtle seam --
-- it is a hard grid drawn across the whole world, every few studs, forever. Nothing else in
-- the codebase would catch that, and it is invisible in a close-up screenshot.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Tex = require(ReplicatedStorage.Terrain.TerrainSurfaceTexture)

local M = {}

function M.run(): boolean
	local EPS = 1e-9

	-- Each octave wraps on both axes: u = 1 is the same lattice line as u = 0.
	for _, cells in { 8, 16, 48 } do
		for _, t in { 0, 0.137, 0.5, 0.913 } do
			local du = math.abs(Tex.noise(0, t, cells, 1) - Tex.noise(1, t, cells, 1))
			assert(du < EPS, `octave {cells} does not wrap in u at v={t} (edges differ by {du})`)
			local dv = math.abs(Tex.noise(t, 0, cells, 1) - Tex.noise(t, 1, cells, 1))
			assert(dv < EPS, `octave {cells} does not wrap in v at u={t} (edges differ by {dv})`)
		end
	end

	-- ...and so does their sum, which is what actually gets drawn.
	for _, t in { 0, 0.211, 0.5, 0.77 } do
		assert(math.abs(Tex.brightness(0, t) - Tex.brightness(1, t)) < EPS,
			`the image does not tile in u at v={t} -- a hard grid would be drawn across the whole map`)
		assert(math.abs(Tex.brightness(t, 0) - Tex.brightness(t, 1)) < EPS,
			`the image does not tile in v at u={t} -- a hard grid would be drawn across the whole map`)
	end

	-- It MULTIPLIES the vertex colour, so it must stay near white: a dark texture would drag
	-- every material zone down with it, and grass would stop being the colour it is set to.
	local lo, hi = math.huge, -math.huge
	for i = 0, 40 do
		for j = 0, 40 do
			local b = Tex.brightness(i / 41, j / 41)
			lo = math.min(lo, b)
			hi = math.max(hi, b)
		end
	end
	assert(lo > 0.6, `the grain darkens to {lo}, which would drag the ground colours down with it`)
	assert(hi <= 1, `the grain brightens past white ({hi})`)
	-- and it has to actually vary, or the checks above would pass on a blank image
	assert(hi - lo > 0.05, `the grain is nearly flat (range {hi - lo}); there would be no detail to see`)

	print("[TerrainSurfaceTexture.spec] OK")
	return true
end

return M
