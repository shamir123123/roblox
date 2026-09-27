--!strict
-- FootprintGen
-- Pure generator for a building's FLAT footprint blueprint within a plot, plus a parking
-- patch in the leftover space. Returns axis-aligned rectangles in the plot's LOCAL frame
-- (x along the road in [-W/2, W/2]; z from the road back in [0, D]) so the client draws each
-- as one flat part -- no triangulation. The varied L / T / U / notch silhouettes are just
-- unions of axis-aligned rects. Shape varies with category + land value + a seed; coverage
-- scales the footprint; parking takes a slice at the rear.
--
-- Pure + deterministic from (..., seed): PlotService (authoritative) and the client renderer
-- both run it, so a plot's blueprint round-trips to the same shape.

local FootprintGen = {}

export type Rect = { cx: number, cz: number, sx: number, sz: number }
export type Footprint = { rects: { Rect }, driveway: Rect? }

local SIDE  = 2 -- side setback from plot edges (studs)
local FRONT = 3 -- setback from the road
local BACK  = 2 -- setback at the rear

-- Normalised shapes: rects in x in [-0.5,0.5], z in [0,1] (road side at z=0).
local SHAPES: { [string]: { Rect } } = {
	rect  = { { cx = 0,     cz = 0.5,  sx = 1.0,  sz = 1.0 } },
	L     = { { cx = -0.2,  cz = 0.5,  sx = 0.6,  sz = 1.0 }, { cx = 0.3,  cz = 0.25, sx = 0.4,  sz = 0.5 } },
	T     = { { cx = 0,     cz = 0.22, sx = 1.0,  sz = 0.44 }, { cx = 0,    cz = 0.66, sx = 0.4,  sz = 0.68 } },
	notch = { { cx = -0.15, cz = 0.5,  sx = 0.7,  sz = 1.0 }, { cx = 0.35, cz = 0.62, sx = 0.3,  sz = 0.76 } },
	U     = { { cx = -0.34, cz = 0.5,  sx = 0.32, sz = 1.0 }, { cx = 0.34, cz = 0.5,  sx = 0.32, sz = 1.0 }, { cx = 0, cz = 0.18, sx = 1.0, sz = 0.36 } },
}

-- Per-category shape pools; higher land value biases toward the later (fancier) entries.
local POOLS: { [string]: { string } } = {
	Residential = { "rect", "L", "notch", "T" },
	Commercial  = { "rect", "rect", "L", "U" },
	Office      = { "rect", "T", "U", "notch" },
	Industrial  = { "rect", "rect", "L", "notch" },
}

local function pickShape(category: string, landValue: number, rng: Random): { Rect }
	local pool = POOLS[category] or POOLS.Residential
	local lo = 1 + math.floor(landValue * (#pool - 1) * 0.5)
	local idx = rng:NextInteger(math.clamp(lo, 1, #pool), #pool)
	return SHAPES[pool[idx]] or SHAPES.rect
end

-- Footprint (+ parking) for a plot W (frontage) x D (depth) studs.
function FootprintGen.generate(category: string, W: number, D: number, coverage: number, parking: number, landValue: number, seed: number): Footprint
	local rng = Random.new(seed)
	coverage = math.clamp(coverage, 0.2, 1)
	parking = math.clamp(parking, 0, 1)
	landValue = math.clamp(landValue, 0, 1)

	local usableW = math.max(4, W - 2 * SIDE)
	local usableD = math.max(4, D - FRONT - BACK)

	-- House: a shape CENTRED in the lot, sized by coverage; a driveway runs from the road to it.
	local houseW = usableW * (0.4 + coverage * 0.4)
	local houseD = usableD * (0.3 + coverage * 0.4)
	local houseCz = FRONT + usableD * 0.5 -- centred in depth

	local shape = pickShape(category, landValue, rng)
	local rects: { Rect } = {}
	for _, r in shape do
		table.insert(rects, {
			cx = r.cx * houseW,
			cz = houseCz + (r.cz - 0.5) * houseD,
			sx = r.sx * houseW,
			sz = r.sz * houseD,
		})
	end

	-- Driveway: a narrow strip from the road edge (z=0) to the front of the house, set to one side.
	local houseFrontZ = houseCz - houseD * 0.5
	local driveway: Rect? = nil
	if houseFrontZ > 2 then
		driveway = { cx = houseW * 0.28, cz = houseFrontZ * 0.5, sx = 5, sz = houseFrontZ }
	end

	return { rects = rects, driveway = driveway }
end

return FootprintGen
