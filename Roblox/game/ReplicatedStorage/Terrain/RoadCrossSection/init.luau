--!strict
-- THE road cross-section: where the ground sits, at every lateral distance from a road's
-- centreline. The single place that shape is decided, and a pure library -- no state, no
-- lifecycle, no side effects on require.
--
-- It lives in ReplicatedStorage rather than beside TerrainGradeService because the CLIENT
-- needs it too: it predicts the grade the instant a road is placed, so the ground drops on
-- the frame you click instead of a patch-flush later, and the road MODES have to ask what
-- the ground would do before deciding whether a span should bridge, bore or sit down. Two
-- copies of this shape would drift, and the drift would look like the bugs it took a dozen
-- passes to remove.
--
-- THE RULE: the ground is never higher than the FOOTWAY TOP, and never far below it either.
-- Above it and the terrain buries the kerb; level with it and the two surfaces are coplanar,
-- which makes them trade places per triangle and puts wedges of grass on the pavement; far
-- below it and a band of bare kerb shows along the road. Every branch below is one of those
-- three constraints being satisfied at a different distance.
--
-- Historical note worth keeping, because it reads as a contradiction otherwise: until
-- 2026-09-16 the rule was the opposite -- ground never higher than the ASPHALT, verge left
-- at natural grade a full stud below the pavement. That was not a style choice. The ground
-- was Roblox voxels, and Roblox renders far terrain from a coarser grid; a carriageway is
-- finer than that grid can hold, so a verge raised above the asphalt merged the notch away
-- and the grass plane ran straight over the road. The ground is our own mesh now and has no
-- such grid: TerrainMesh.blockStrides only ever accepts a stride whose error stays within
-- MESH_FLAT_TOLERANCE, a quarter stud, and the carriageway sits over a stud down. The error
-- is BOUNDED, so the burial cannot recur -- measured, road-adjacent blocks do still coarsen
-- to stride 2-8 and survive it. TerrainGradeService.spec check E pins that relationship.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local TerrainConstants = require(ReplicatedStorage.Terrain.TerrainConstants)

local RoadCrossSection = {}

local ROAD_EDGE_HEIGHT = RoadConstants.GROUND_ROAD_EDGE_HEIGHT
local WALK_HEIGHT      = RoadConstants.SIDEWALK_HEIGHT
local WALK_WIDTH       = RoadConstants.SIDEWALK_WIDTH

-- Half a corner spacing past the asphalt edge: where the hidden bed under the carriageway
-- gives way to the ground under the footway. Heights exist only every SAMPLE_SPACING studs,
-- so this keeps the changeover inside the slab rather than out where it would be seen.
local KERB_STEP_INSET  = TerrainConstants.SAMPLE_SPACING * 0.5
local FOOTPRINT_MARGIN = TerrainConstants.SAMPLE_SPACING

-- How far under the FOOTWAY TOP the hidden ground sits while still beneath the slab.
--
-- Small on purpose. A pavement edge almost never lands on the corner lattice, so the mesh
-- RAMPS from the last corner under the slab to the first corner out on the verge, and
-- whatever that ramp has not climbed where it crosses the slab edge is bare kerb on show.
-- With the hidden ground a whole stud down that sliver was a scalloped band running the
-- length of every road, waving as the lattice phase drifted. It only has to clear the slab
-- TOP by enough not to z-fight -- not its underside, because the slab is opaque and hides
-- whatever is inside it.
local SLAB_CLEARANCE   = 0.15

-- How far under the footway top the VERGE sits. Dead level would be coplanar, and coplanar
-- surfaces trade places per triangle: that is grass wedges appearing on the pavement in the
-- shape of the terrain's own triangles. It also covers any corner this function calls verge
-- while it is physically still under the slab, which junction fillets and curves produce.
--
-- GROUND_ROAD_TOP_LIFT is tied to this: the footway stands exactly VERGE_SINK proud of
-- untouched ground, so the graded verge lands on natural grade EXACTLY (no seam at the edge
-- of the locked footprint, no plinth) while ungraded ground -- outside the footprint, at
-- fillets, at dead-end caps -- stays just below the pavement instead of fighting it.
local VERGE_SINK       = 0.08

-- A road with no footway has nothing standing proud to hide a raised verge behind, so its
-- shoulder stays a kerb's height below its own asphalt.
local SHOULDER_DROP    = RoadConstants.SIDEWALK_HEIGHT

RoadCrossSection.kerbStepInset = KERB_STEP_INSET
RoadCrossSection.vergeSink = VERGE_SINK
RoadCrossSection.slabClearance = SLAB_CLEARANCE

-- VISIBLE ground height (what the player sees) at lateral distance `d` from the centreline
-- of a road whose slab top is `roadTopY`. Callers writing into the heightmap subtract
-- RENDER_BULGE to get the raw value.
function RoadCrossSection.bedSurfaceY(roadTopY: number, d: number, width: number, walkWidth: number): number
	local kerbLine = width * 0.5
	if d < kerbLine + KERB_STEP_INSET then
		-- Hidden bed under the asphalt. GROUND_SKIRT bridges it; nothing here is ever seen.
		return roadTopY - ROAD_EDGE_HEIGHT
	end
	if walkWidth > 0 and d >= kerbLine + walkWidth then
		return roadTopY + WALK_HEIGHT - VERGE_SINK -- the verge: natural grade, exactly
	end
	if walkWidth > 0 then
		return roadTopY + WALK_HEIGHT - SLAB_CLEARANCE -- under the slab, only just hidden
	end
	return roadTopY - SHOULDER_DROP
end

-- How far out the flat, locked footprint reaches. The band between the kerb step and this is
-- the ground that has to READ as flush with the pavement, so it must stay at least a couple
-- of corner spacings wide or the lattice has nothing to hold the verge height with.
function RoadCrossSection.footprintHalf(width: number): number
	return width * 0.5 + WALK_WIDTH + FOOTPRINT_MARGIN
end

-- == Vertical mode ===========================================================
-- Which of Ground / Elevated / Tunnel a span should be built as, from the road's own height
-- against the ground it passes over. This is how Cities: Skylines decides it too -- there is
-- no separate "bridge tool"; a road that rises above the land gets supports, one drawn below
-- the surface gets a tunnel portal, and everything else sits on the ground.
--
-- EVERY mode is this same decision with a different `allow` set, which is why there is one
-- function here and not four:
--   Auto    -- both allowed: pick whatever the ground calls for.
--   Bridge  -- Elevated only: span real gaps, sit down everywhere else.
--   Tunnel  -- Tunnel only: bore through what is in the way, sit down everywhere else.
--   Ground  -- neither: never leave the ground, and let the grade fill underneath.
--
-- Both thresholds already existed and both already mean "big enough to need structure", so
-- they are reused rather than invented: a rise the road cannot simply be graded into, and a
-- drop deep enough that TerrainGradeService would cut walls rather than blend a dip.
local ELEVATED_MIN_HEIGHT = RoadConstants.ELEVATED_PILLAR_MIN_HEIGHT
local TUNNEL_MIN_DEPTH = 6 -- 3 m at STUD_TO_METER; TerrainGradeService cuts walls from here

RoadCrossSection.GROUND = "Ground"
RoadCrossSection.ELEVATED = "Elevated"
RoadCrossSection.TUNNEL = "Tunnel"
RoadCrossSection.tunnelMinDepth = TUNNEL_MIN_DEPTH
RoadCrossSection.elevatedMinHeight = ELEVATED_MIN_HEIGHT

export type ModeAllowance = { elevated: boolean, tunnel: boolean }

-- `samples` are points ALONG THE ROAD (their Y is the road's own height there), `groundYAt`
-- gives the visible ground height at a world x/z. Returns one of the three mode strings.
--
-- Decided over the WHOLE span, not per point, because a segment carries a single vMode --
-- half a bridge is not a thing the renderer or the network can express.
function RoadCrossSection.verticalModeFor(
	samples: { Vector3 },
	groundYAt: (number, number) -> number,
	allow: ModeAllowance?
): string
	local allowElevated = if allow then allow.elevated else true
	local allowTunnel = if allow then allow.tunnel else true

	local deepest = 0 -- most the ground rises ABOVE the road: wants boring through
	local highest = 0 -- most the road stands ABOVE the ground: wants holding up
	for _, p in samples do
		local gy = groundYAt(p.X, p.Z)
		local above = gy - p.Y
		if above > deepest then deepest = above end
		local below = p.Y - gy
		if below > highest then highest = below end
	end

	local wantTunnel = allowTunnel and deepest >= TUNNEL_MIN_DEPTH
	local wantElevated = allowElevated and highest >= ELEVATED_MIN_HEIGHT
	if wantTunnel and wantElevated then
		-- A span that both cuts through a rise and crosses a dip can only be one thing, so
		-- take whichever need is more extreme RELATIVE TO ITS OWN threshold -- comparing the
		-- raw studs would just favour whichever threshold happens to be smaller.
		return if deepest / TUNNEL_MIN_DEPTH >= highest / ELEVATED_MIN_HEIGHT
			then RoadCrossSection.TUNNEL
			else RoadCrossSection.ELEVATED
	end
	if wantTunnel then return RoadCrossSection.TUNNEL end
	if wantElevated then return RoadCrossSection.ELEVATED end
	return RoadCrossSection.GROUND
end

-- == Retaining walls (Cities: Skylines 2) ====================================
-- Where the top of the footway and the natural ground beside the road differ by
-- WALL_MIN_HEIGHT or more, the ground does not bank down (or up) to meet the road. A
-- retaining wall stands at the back of the footway and the land outside it keeps its natural
-- height: a road raised less than a bridge sits on walled fill, one lowered less than a
-- tunnel runs in a walled cut, and a tunnel's approach ramp is walled from here down.
-- TerrainGradeService shapes the ground and RoadSceneRenderer builds the walls, both from
-- these functions -- so a wall never stands without its step, or a step without its wall.
local WALL_MIN_HEIGHT = 3      -- studs (1.5 m); smaller steps bank into the ground as before
local SPAN_MIN_HEIGHT = 6      -- an Elevated span higher than this is a bridge (no fill, no walls)
local COVER_DEPTH = 16         -- a Tunnel this far below the ground is covered: no cut, no walls
-- Walls keep this far (plus half the widest road) from a junction or a dead end: nothing
-- wraps a junction's corners or a turnaround bulb, so the ground banks there as it always did.
local WALL_NODE_CLEAR = RoadConstants.SIDEWALK_WIDTH + 12

RoadCrossSection.wallMinHeight = WALL_MIN_HEIGHT
RoadCrossSection.spanMinHeight = SPAN_MIN_HEIGHT
RoadCrossSection.coverDepth = COVER_DEPTH
RoadCrossSection.wallThickness = RoadConstants.TUNNEL_WALL_THICKNESS

-- Top of the footway -- or of the carriageway, on a road without one -- for a slab whose top
-- is roadTopY. The wall is measured from here.
function RoadCrossSection.edgeTopY(roadTopY: number, walkWidth: number): number
	return if walkWidth > 0 then roadTopY + WALK_HEIGHT else roadTopY
end

-- Lateral distance of the wall's road-side face: the back of the footway.
function RoadCrossSection.wallInnerOffset(width: number, walkWidth: number): number
	return width * 0.5 + walkWidth
end

-- The signed step a wall has to hold, beside a road whose slab centre is at centreY:
-- natural visible ground minus the edge top. > 0 is a cut (the wall holds the hillside
-- back), < 0 a fill (it holds the road up), 0 means no wall -- the step is small, the road is
-- a bridge there, or a covered tunnel. `vMode` is the segment's ("Ground" when nil).
function RoadCrossSection.wallStep(centreY: number, halfThick: number, walkWidth: number, naturalY: number, vMode: string?): number
	local roadTopY = centreY + halfThick
	if vMode == "Elevated" and roadTopY - naturalY > SPAN_MIN_HEIGHT then return 0 end
	if vMode == "Tunnel" and naturalY - roadTopY >= COVER_DEPTH then return 0 end
	local step = naturalY - RoadCrossSection.edgeTopY(roadTopY, walkWidth)
	return if math.abs(step) >= WALL_MIN_HEIGHT then step else 0
end

-- How far along a road from a node its walls start: 0 at a plain continuation (2 arms, the
-- wall runs on round the bend), clear of the corners at a junction or a dead end.
function RoadCrossSection.wallNodeClear(armCount: number, widestWidth: number): number
	if armCount == 2 then return 0 end
	return widestWidth * 0.5 + WALL_NODE_CLEAR
end

-- Which roads get walls: ones the player set at a height or a depth -- Elevated, Tunnel, or
-- held at a constant grade (which is also what a road raised or lowered by less than a
-- bridge / tunnel becomes). A ground road that follows the terrain banks into it with slopes
-- as it always did. Never terrain paths (they lie ON the land) or roundabout rings.
function RoadCrossSection.takesWalls(spec: any, seg: any): boolean
	if spec.terrainPath or seg.isArc or seg.isRoundabout then return false end
	return seg.vMode == "Elevated" or seg.vMode == "Tunnel" or seg.constSlope == true
end

return RoadCrossSection
