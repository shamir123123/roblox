--!strict
-- The road CROSS-SECTION: what the ground does across a road's footprint. No framework:
-- call run() and it asserts. Runs against the real TerrainGradeService.bedSurfaceY /
-- footprintHalf, not a copy of the formula, so it fails when that logic changes.
--
-- Contract: THE LAND IS NEVER HIGHER THAN THE ASPHALT. The road stands on the ground and the
-- kerb reveal is the footway SLAB, because terrain above the carriageway is exactly what
-- Roblox's distant-terrain LOD smears over the road -- a 12-stud carriageway is 3 voxels, far
-- finer than the coarse grid used past ~1 km, so the notch merges away and the verge plane
-- runs straight across it. Check A is that bug, and it is the reason the previous contract
-- (land flush with the PAVEMENT top) had to go: flush at 100 studs, buried at 1500.
--
-- Everything here is asserted through the PAINTER's resolution, not the formula's. Heights
-- exist only every SAMPLE_SPACING studs and TerrainPainter surfaces each voxel column at the
-- MEAN of its tile's four corners, while a kerb is a few TENTHS of a stud -- so "the function
-- returns the verge at the pavement edge" proves nothing on its own. The first version of
-- this spec asserted exactly that and passed while every kerb in the city stood in a trench:
-- the flat verge was 1.5 studs wide, narrower than the corner spacing, so no corner ever
-- landed in it. Check C is that bug.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local TerrainConstants = require(ReplicatedStorage.Terrain.TerrainConstants)
local TerrainGradeService = require(script.Parent.TerrainGradeService)

local bedSurfaceY = TerrainGradeService.bedSurfaceY
local footprintHalf = TerrainGradeService.footprintHalf
local INSET = TerrainGradeService.kerbStepInset
local STEP = TerrainConstants.SAMPLE_SPACING
local WALK = RoadConstants.SIDEWALK_WIDTH
local ROAD_TOP = 100 -- arbitrary; every assertion is relative to it
local EPS = 1e-6
local PHASES = 16

-- The ground is a MESH now, not voxels: its surface is the heightmap's CORNERS with the
-- mesh interpolating between them. So everything below asserts on corner heights. The
-- previous version of this spec averaged four corners per voxel column, because that is
-- what TerrainPainter did -- and TerrainPainter no longer draws the ground at all.
local function cornerY(centreX: number, x: number, width: number, walk: number): number
	return bedSurfaceY(ROAD_TOP, math.abs(x - centreX), width, walk)
end

local function run(): string
	local TOL = TerrainConstants.MESH_FLAT_TOLERANCE

	for _, width in { 9, 18, 38 } do
		local kerbLine = width * 0.5
		local pavementEdge = kerbLine + WALK
		local walkTopY = ROAD_TOP + RoadConstants.SIDEWALK_HEIGHT
		local outerHalf = footprintHalf(width)

		-- B: the locked footprint has to reach past the pavement, or there is no verge for
		-- the land to meet the pavement ON and the grass is left to the shoulder blend.
		assert(outerHalf >= pavementEdge + STEP - EPS,
			("w%d: footprint reaches %.1f, not past the pavement edge at %.1f"):format(width, outerHalf, pavementEdge))
		-- B2: and a HARD CUT's footprint must clear it by a whole corner too. This is the one
		-- that kept coming back. TUNNEL_WALL_THICKNESS is 1 stud, sized for a wall; corners
		-- are STEP apart. A lock ending 1 stud past the pavement leaves the next corner
		-- outward belonging to the rising shoulder, so the mesh ramps from under the slab
		-- straight up over the kerb -- grass laterally on the pavement, in STEP-sized steps.
		--
		-- No height clearance can fix that, which is why three attempts at one did not: it is
		-- not two surfaces fighting over a depth, it is the flat band being narrower than the
		-- lattice can represent.
		local cutHalf = TerrainGradeService.cutFootprintHalf(width)
		assert(cutHalf >= pavementEdge + STEP - EPS,
			("w%d: a cut's locked band reaches %.1f, only %.1f past the pavement edge -- the next corner out is already climbing, so the bank rides over the kerb")
				:format(width, cutHalf, cutHalf - pavementEdge))

		for phaseStep = 0, PHASES - 1 do
			local centreX = (phaseStep / PHASES) * STEP -- centreline against the corner lattice
			local vergeCorners = 0

			for x = centreX - outerHalf, centreX + outerHalf, STEP do
				local d = math.abs(x - centreX)
				local y = cornerY(centreX, x, width, WALK)

				-- A: the road is never covered. A corner over the CARRIAGEWAY must sit below
				-- the asphalt top -- level with it reads as a road in a puddle of grass, above
				-- it hides the road outright.
				--
				-- This used to be unconditional across the whole footprint, because the ground
				-- was Roblox voxels and the coarse distant grid spread ANY raised verge back
				-- over the road (that is the 2026-09-11 burial). The ground is our own mesh
				-- now, so the rule narrowed to what it was always really protecting. See E.
				if d <= kerbLine + EPS then
					assert(y < ROAD_TOP - EPS,
						("w%d phase %.2f: ground %+.3f at/over the asphalt top at d=%.1f")
							:format(width, centreX, y - ROAD_TOP, d))
				end

				-- C: every corner PAST the pavement edge sits exactly on the pavement top.
				-- Not near it -- exactly. Under it is the trench beside the kerb this change
				-- exists to remove; over it is a lip. Counted, because an assertion over an
				-- empty set is how this spec passed once before while every kerb stood in a
				-- ditch.
				-- C: every corner PAST the pavement edge sits just UNDER the footway top --
				-- close enough that there is no gap to see, but never level with it. Level is
				-- coplanar, and coplanar surfaces trade places per triangle: that is grass
				-- appearing ON the pavement in triangular wedges. Too far under and the kerb's
				-- side starts showing as a band. Counted, because an assertion over an empty
				-- set is how this spec passed once before while every kerb stood in a ditch.
				if d >= pavementEdge - EPS then
					vergeCorners += 1
					local under = walkTopY - y
					assert(under > EPS,
						("w%d phase %.2f: verge is level with (or over) the pavement top at d=%.1f -- they will trade places per triangle")
							:format(width, centreX, d))
					assert(under <= 0.25,
						("w%d phase %.2f: verge sits %.2f under the pavement top at d=%.1f -- that reads as a gap along the kerb")
							:format(width, centreX, under, d))
				end
			end

			assert(vergeCorners >= 2, ("w%d phase %.2f: only %d corners past the pavement -- nothing holds the grass at kerb level")
				:format(width, centreX, vergeCorners))
		end

		-- D: a road with NO footway (highway, alley) keeps its shoulder BELOW its own asphalt.
		-- It has nothing standing proud to hide a raised verge behind, so raising one would
		-- put grass over the carriageway edge.
		assert(bedSurfaceY(ROAD_TOP, pavementEdge, width, 0) < ROAD_TOP - EPS,
			("w%d: a no-kerb road's shoulder is not below its own asphalt"):format(width))
		assert(bedSurfaceY(ROAD_TOP, kerbLine, width, 0) < ROAD_TOP - EPS,
			("w%d: a no-kerb road's bed is not below its own asphalt"):format(width))

		-- E: the reason A could be narrowed at all. The mesh renderer only ever draws a stride
		-- whose error stays inside MESH_FLAT_TOLERANCE, so a verge above the asphalt is safe
		-- exactly while the drop to the carriageway dwarfs that bound. Road-adjacent blocks DO
		-- coarsen (measured: stride 2-8); the bound is what protects them, not the resolution.
		-- If the tolerance ever grows toward the drop, the 2026-09-11 burial is back.
		local drop = walkTopY - bedSurfaceY(ROAD_TOP, 0, width, WALK)
		assert(drop > TOL * 4,
			("w%d: verge sits %.2f above the carriageway bed but LOD may err by %.2f -- too close to average the road away")
				:format(width, drop, TOL))
	end

	-- The kerb is a real step, not a hairline: a pavement level with the road reads as one
	-- flat plinth, which is the look this cross-section exists to kill.
	assert(RoadConstants.SIDEWALK_HEIGHT * RoadConstants.STUD_TO_METER >= 0.10,
		"SIDEWALK_HEIGHT is under a 10 cm kerb reveal -- the kerb stops reading")

	-- Stated outright so nobody has to infer it from the sweep: the land beside a kerbed road
	-- is LEVEL with the pavement. That is the whole point of the change.
	local vergeUnder = (ROAD_TOP + RoadConstants.SIDEWALK_HEIGHT) - bedSurfaceY(ROAD_TOP, 18 * 0.5 + WALK, 18, WALK)
	assert(vergeUnder > EPS and vergeUnder <= 0.25,
		("the verge sits %.3f under the pavement top; it must be just under -- level trades places per triangle, far under is a gap")
			:format(vergeUnder))
	-- F: and the road must not DISTURB the land it is laid through. The assembly is sunk by
	-- exactly SIDEWALK_HEIGHT, so the footway top -- its highest part -- lands on natural
	-- grade and the verge beside it needs no raising at all.
	--
	-- Get this wrong the other way and every road stands on a PLINTH with a shoulder ramping
	-- down to the surrounding grass. That is what a positive lift produced: a cross-section
	-- that was right in cross-section and wrong in the world.
	-- The footway must stand exactly VERGE_SINK proud of untouched ground. Two things fall
	-- out of that one number and both matter:
	--   * the graded verge lands on NATURAL grade, so the edge of the locked footprint is
	--     seamless and no road sits on a plinth;
	--   * ungraded ground -- outside the footprint, at corner fillets, at dead-end caps --
	--     is just BELOW the pavement rather than level with it. Level is coplanar, and
	--     coplanar surfaces trade places per triangle, which is grass wedges on the kerb.
	-- Getting this wrong by the width of the sink is enough to bring those wedges back, so
	-- the two constants are pinned to each other rather than both being "about right".
	local proud = RoadConstants.GROUND_ROAD_TOP_LIFT + RoadConstants.SIDEWALK_HEIGHT
	assert(math.abs(proud - TerrainGradeService.vergeSink) < EPS,
		("the footway stands %.3f proud of natural ground but the verge sinks %.3f -- they must match, or ungraded ground is coplanar with the pavement (wedges) or above it (buried kerb)")
			:format(proud, TerrainGradeService.vergeSink))
	assert(proud > EPS,
		("the footway stands %.3f proud of natural ground -- at or below it, every patch of ungraded ground fights the pavement"):format(proud))
	-- G: the ground under the slab is hidden, but only JUST hidden.
	--
	-- Heights exist every SAMPLE_SPACING studs and a pavement edge does not land on that
	-- lattice, so the mesh ramps from the last corner under the slab to the first corner on
	-- the verge. Whatever that ramp has not climbed by the time it crosses the slab edge is
	-- bare kerb, on show. Drop the hidden ground a long way and that sliver becomes a visible
	-- scalloped band running the length of every road -- the lattice phase drifts, so it
	-- waves. Both bounds matter: below the top so they do not fight for the same pixel, and
	-- not far below it so there is nothing to expose.
	for _, width in { 9, 18, 38 } do
		local walkTopY = ROAD_TOP + RoadConstants.SIDEWALK_HEIGHT
		local underSlab = bedSurfaceY(ROAD_TOP, width * 0.5 + WALK * 0.5, width, WALK)
		assert(underSlab < walkTopY - EPS,
			("w%d: ground under the footway is level with the slab top -- they will fight for the same pixel"):format(width))
		local exposed = walkTopY - underSlab
		assert(exposed <= 0.25,
			("w%d: ground under the footway sits %.2f under the slab top; the pavement edge can expose that much kerb as a scalloped band")
				:format(width, exposed))
	end

	return "TerrainGradeService.spec: ok"
end

return { run = run }
