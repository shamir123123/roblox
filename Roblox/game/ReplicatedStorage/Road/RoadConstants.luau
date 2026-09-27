--!strict

-- The world's continent/country theme decides the side of the road, the marking colours
-- and the broken-line cycle. WorldThemeCatalog has no dependencies of its own, so reading
-- it from the lowest-level constants module creates no cycle. WaitForChild because this
-- module loads on the client too, before replication has necessarily finished.
-- Anchored to ReplicatedStorage, NOT to script.Parent.Parent: this folder gets cloned
-- elsewhere to test edited modules without the require cache, and a relative path would
-- then wait forever on a parent that has no World folder.
local ThemeFolder = game:GetService("ReplicatedStorage"):WaitForChild("World")
local WorldThemeCatalog = require(ThemeFolder:WaitForChild("WorldThemeCatalog"))
local THEME = WorldThemeCatalog.active()

-- Dimensions in this file are authored in FULL-SIZE studs of 0.25 m, then multiplied by
-- WORLD_SCALE at the bottom. A theme states its real-world figures in feet, so this is the
-- one conversion between the two: studs = feet * 0.3048 / 0.25.
local BASE_STUD_TO_METER = 0.25
local FEET_TO_STUDS = 0.3048 / BASE_STUD_TO_METER

local RoadConstants = {

	ROAD_WIDTH = 24,
	ROAD_THICKNESS = 2.0,
	-- How far the asphalt top sits ABOVE natural ground. Not cosmetic -- it is what keeps
	-- the road visible from more than a few hundred studs away.
	--
	-- Roblox renders distant terrain from a coarser voxel grid, and a carriageway is 12 world
	-- studs = 3 voxels: finer than that grid can hold. Grade the land beside a road ABOVE the
	-- asphalt (which is what a terrain-side kerb step means) and past ~1 km the notch merges
	-- away, the grass plane runs straight across at verge height, and the road is buried --
	-- measured in an empty place: every strip under the verge disappears, every strip over it
	-- survives. So the rule is absolute: THE LAND IS NEVER HIGHER THAN THE ASPHALT. The kerb
	-- reveal comes from the footway slab standing proud (SIDEWALK_HEIGHT), never from terrain.
	--
	-- Equal to the verge drop in TerrainGradeService.bedSurfaceY, so on flat land the graded
	-- verge lands back on natural ground and the terrain is left alone.
	-- 1.0 authored = 0.5 world studs = 25 cm.
	-- Where the asphalt top sits relative to natural ground. NEGATIVE: the whole assembly is
	-- SUNK INTO the land by exactly SIDEWALK_HEIGHT, so the footway top -- the highest part of
	-- it -- comes out level with untouched ground, and the carriageway a kerb below that.
	-- The land beside a road is then left exactly where it was: no plinth to ramp down off,
	-- nothing standing proud, and no trench either.
	--
	-- It was +1.0 (road lifted OUT of the ground) for as long as the ground was Roblox voxels,
	-- because the coarse distant-terrain grid buried anything sitting below its surroundings.
	-- The ground is our own mesh now and that failure mode is gone, so the road can sit in a
	-- cut the way a real one does. Must stay exactly -SIDEWALK_HEIGHT or the footway stops
	-- being flush -- TerrainGradeService.spec pins the relationship.
	-- = -(SIDEWALK_HEIGHT - 2 * TerrainGradeService VERGE_SINK). Kept in sync by that spec.
	--
	-- Not quite -SIDEWALK_HEIGHT, and the difference is the whole point: at exactly that value
	-- the footway top lands on natural grade, which makes it COPLANAR with every piece of
	-- ground the grade does not reach -- outside the locked footprint, at corner fillets, at
	-- dead-end caps. Coplanar surfaces trade places per triangle, so wedges of grass appeared
	-- on the pavement there however carefully the graded part was handled.
	--
	-- Standing the footway a hair PROUD of untouched ground fixes it everywhere at once:
	-- ungraded ground is now just below the pavement instead of level with it, and the graded
	-- verge comes out at exactly natural grade, so the edge of the footprint is seamless too.
	GROUND_ROAD_TOP_LIFT = -0.84,
	-- How deep the hidden bed sits under the asphalt slab. Never visible: GROUND_SKIRT bridges it.
	GROUND_ROAD_EDGE_HEIGHT = 1.6,
	ROAD_WIDTH_TRANSITION_LENGTH = 50,

	STUD_TO_METER = BASE_STUD_TO_METER, -- full-size base; rescaled by WORLD_SCALE below (0.5 -> 2 studs = 1 m)

	-- NOTE: the driving side is deliberately NOT here, and not on the world theme either.
	-- It is a player setting, owned start to finish by RoadRules -- read it through
	-- RoadRules.getDrivingSide() / getLaneSideSign() / getNearsideTurn() / getCrossingTurn().
	-- A constant in this table could never express it: this table is frozen at load, and the
	-- player can change the side afterwards.

	SAMPLES_PER_SEGMENT = 35,

	-- Surface render only. The adaptive sampler spends facets where the road bends
	-- (in plan OR profile), so flat straights still render as 1 facet and only
	-- curved/graded runs pay for these. Kept well above SAMPLES_PER_SEGMENT (a
	-- nav/length-probe count, not a render count) so grades and crests get enough
	-- chords that the flat-shaded facet seams stop reading as bumps.
	MAX_SURFACE_SAMPLES = 96,
	-- Target facet length (studs) on graded / width-transition runs. Lower = smoother
	-- but more parts. The width-taper branch always honours it; flat-profile straights
	-- ignore it (they don't crease).
	-- ponytail: 6.0 (was 3.0) -- halves graded-run facet count; with QUAD_EPS boxing most
	-- facets the crease seams stay invisible from the city camera. Drop back if grades shimmer.
	SURFACE_FACET_LENGTH = 6.0,
	-- Control-point vertical spread (studs) above which a segment counts as graded and
	-- gets the facet-length floor. Small, so any real grade triggers it; above float noise.
	SURFACE_GRADE_RELIEF = 1.5,

	SNAP_RADIUS = 12,
	VERTICAL_CONNECT_TOLERANCE = 10,
	-- CS2-style fine elevation steps (2 m at 2 studs/m): one step down is a sunken
	-- road, two a walled cut, four a covered tunnel.
	ELEVATION_STEP = 4,
	MIN_ELEVATION = 0,
	-- Ceiling on the elevation slider only, so the number stays finite and the pillar
	-- builder has a bound. Not a placement rule: nothing rejects a road for its height.
	MAX_ELEVATION = 1024,
	ELEVATED_DEFAULT_HEIGHT = 16, -- one-click Elevated mode seeds this offset
	-- Tunnel (below-grade) placement: depth dropped below the cursor's ground point.
	TUNNEL_DEPTH = 16,
	TUNNEL_MAX_DEPTH = 96,
	TUNNEL_WALL_THICKNESS = 2,
	TUNNEL_WALL_COLOR = Color3.fromRGB(96, 96, 100),
	ELEVATED_PILLAR_MIN_HEIGHT = 12,
	-- CS2 spec: one support roughly every 80 m of elevated deck; a span shorter
	-- than one interval carries no internal pillar. 320 * WORLD_SCALE(0.5) = 160
	-- studs = 80 m at 2 studs/m.
	ELEVATED_PILLAR_SPACING = 320,
	ELEVATED_PILLAR_WIDTH = 4.8,
	ELEVATED_PILLAR_COLOR = Color3.fromRGB(128, 128, 132),

	-- Metal W-beam guardrail on elevated decks: a galvanized beam on posts at the deck edge
	-- once the deck is GUARDRAIL_MIN_HEIGHT above the ground.
	GUARDRAIL_MIN_HEIGHT = 6,
	GUARDRAIL_HEIGHT = 2.2,        -- beam top height above the deck
	GUARDRAIL_BEAM_HEIGHT = 0.9,   -- beam vertical thickness
	GUARDRAIL_BEAM_WIDTH = 0.5,    -- beam depth (lateral)
	GUARDRAIL_POST_WIDTH = 0.4,    -- square post cross-section
	GUARDRAIL_POST_SPACING = 12,   -- studs between posts
	GUARDRAIL_COLOR = Color3.fromRGB(172, 175, 182),  -- galvanized metal
	MIN_SEGMENT_LENGTH = 12,
	-- A junction mouth plus the far corner's trim can consume a short arm segment
	-- entirely; the renderer then draws NOTHING for a live segment. Below
	-- (trims + this margin) of length, the graph dissolves the corner node instead
	-- of keeping an invisible segment (RoadNetwork.dissolveSwallowedArms).
	SEGMENT_SWALLOW_MARGIN = 2,
	-- Auto-split: a drawn road longer than this many studs is placed as multiple welded
	-- segments (a node inserted ~every this distance), like CS:S node spacing. 400 here is
	-- 200 studs after WORLD_SCALE = 100 m at the world's 2 studs/m -- keeps segments editable,
	-- builds curves from pieces, and puts a NODE every 100 m, which is both what the guideline
	-- system hangs its rays off and where its rings land (SnapConstants.GUIDE_MARK_SPACING).
	MAX_PLACE_SEGMENT_LENGTH = 400,
	MAP_HALF_EXTENT = 4096,

	-- ONE LANE of footway either side (a lane is ROAD_WIDTH/2 = 12 authored studs,
	-- so this is 12 authored = 6 world studs = 3 m). Wide on purpose: the kerb
	-- carries lamps, street trees, utility cabinets and name blades, and at the old
	-- 6 (1.5 m) they stood on top of each other. Every consumer derives its own
	-- offsets from this one number -- plot frontage, junction corner radius and the
	-- minimum curve radius all widen with it.
	SIDEWALK_WIDTH = 12,
	-- How far PAST the pavement edge a standing building's CENTRE may be and still count as
	-- "under the new road", so a road placed over a zoned street clears it. Well under the
	-- lot gap (~8.5), so a neighbour that merely fronts the new road is never caught.
	-- Shared because the road ghost highlights the doomed buildings in white BEFORE the
	-- click: a different number on the client highlights one house and demolishes another.
	BUILDING_CLEAR_MARGIN = 4,
	-- THE kerb reveal: how far the footway slab stands above the asphalt. The whole step is
	-- SLAB, not terrain -- the land beside a road is graded to natural ground, below the
	-- asphalt, and the pavement rises out of it (see GROUND_ROAD_TOP_LIFT for why terrain may
	-- never be the high side). 1.00 authored = 0.50 world studs = 25 cm. Deeper than a real
	-- 15 cm kerb on purpose -- at the zoomed-out city camera a true-scale kerb barely reads.
	SIDEWALK_HEIGHT = 1.00,
	-- Ground roads now embed their slab in the terrain, so the skirt only needs to
	-- bridge the voxel edge instead of hiding a deep air gap.
	GROUND_SKIRT = 2.4,
	SIDEWALK_COLOR = Color3.fromRGB(208, 202, 189), -- #D0CABD warm light concrete (tints the slab map)

	CORNER_RADIUS = 10,
	STRAIGHT_JOIN_TOLERANCE_DEG = 2,

	PLACE_COOLDOWN = 0.1,

	-- Money charged per METRE of road placed (length * STUD_TO_METER). Interactive
	-- placement only -- loading a saved city never charges. Placement is rejected if the
	-- treasury can't cover it.
	ROAD_COST_PER_METER = 14,

	SNAP_COARSE_SAMPLES = 12,
	SNAP_REBUILD_THRESHOLD = 3,
	SNAP_SEGMENT_RADIUS = 20,
	SNAP_SIDE_MARGIN = 8,
	SNAP_GUIDE_RADIUS = 26,
	SNAP_GUIDE_CROSS_RADIUS = 16,
	SNAP_GUIDE_SOURCE_RADIUS = 400,
	SNAP_GUIDE_45_ENABLED = true,
	GUIDE_DOT_SIZE = 1.7,
	GUIDE_DOT_SPACING = 7,
	GUIDE_HALF_LENGTH = 340,
	SNAP_ZONE_NEAR_MARGIN = 12,
	SNAP_SEGMENT_SAMPLES = 32,
	ZONE_GRID_SIZE = 12,
	SNAP_TILE_STEP = 12,
	CORNER_SNAP_TILE_THRESHOLD = 1,
	SNAP_INTERSECTION_RADIUS = 60,
	SNAP_ANGLE_GUIDE_RADIUS = 28,
	SNAP_ANGLE_GUIDE_POINT_RADIUS = 7,
	SNAP_ANGLE_GUIDE_STEPS = 4,
	SNAP_ANGLE_GUIDE_STEP_DISTANCE = 20,
	SNAP_ANGLE_GUIDE_BLOCK_RADIUS = 11,

	ROAD_COLOR = Color3.fromRGB(74, 77, 82), -- #4A4D52 cool dark asphalt gray
	-- Dedicated on-street parking lane (the apron outside the carriageway edge lines).
	-- Nearly the road colour, just a touch darker/cooler so the parking strip reads as a
	-- subtly different surface without a painted bay line.
	PARKING_APRON_COLOR = Color3.fromRGB(62, 65, 70), -- kept proportionally darker than the new ROAD_COLOR
	-- MUTCD paint (11th Ed. §3A.03). The two colours answer one question: is the traffic
	-- on the other side of this line going the SAME way as me?
	--   WHITE  separates traffic travelling the same direction, and marks the RIGHT edge.
	--   YELLOW separates OPPOSING directions, and marks the LEFT edge of a divided
	--          carriageway, a one-way street or a ramp.
	-- "Yellow on your left, white on your right." They are never interchangeable -- do not
	-- substitute one for the other to match a palette.
	MARKING_WHITE = THEME.markingWhite or Color3.fromRGB(245, 245, 245),
	-- The colour that separates OPPOSING directions. A Vienna-Convention theme leaves this
	-- unset (white does that job there too) and falls back to the US yellow, so a caller
	-- always has a colour to reach for even under a theme that would not paint one.
	MARKING_YELLOW = THEME.markingOpposing or Color3.fromRGB(235, 200, 90),
	-- Bus-lane surface. Coloured-surfacing datasheets quote "traffic red" (RAL 3020), but a
	-- laid bus lane is asphalt pigmented with iron oxide, so what you actually see on the
	-- street is the duller, browner oxide red -- RAL 3009 (#6D342D). That's what this is.
	-- Nudge lighter if it reads black against the asphalt at dusk.
	BUS_LANE_COLOR = Color3.fromRGB(109, 52, 45),
	-- Broken-line cycle, MUTCD §3A.04 ¶06: a 10 ft line then a 30 ft gap. The 1:3
	-- line-to-gap RATIO is the invariant and is most of what makes a lane line read as
	-- American -- the old 1:1 here was a continental pattern. Authored in full-size studs
	-- (0.25 m each, so 12 = 10 ft and 36 = 30 ft); both ride WORLD_SCALE below.
	-- Drawn geometrically by RoadMeshView, so these are real lengths, not a texture tile.
	DASH_LENGTH = (THEME.dashLineFeet or 10) * FEET_TO_STUDS,
	DASH_GAP = (THEME.dashGapFeet or 30) * FEET_TO_STUDS,
	-- Shared, lightly worn alpha masks. Surface masks render directly on the road slab,
	-- eliminating separate marking BaseParts on rectangular facets. The dash tile is
	-- retained for localized carrier plates such as zebra crossings and warped fallbacks.
	DASH_TEXTURE = "rbxassetid://113936603000968",
	SURFACE_LINE_SOLID_TEXTURE = "rbxassetid://114560628458283",
	SURFACE_LINE_DASH_TEXTURE = "rbxassetid://102686669488552",
	-- New painted-line textures on dedicated curve-following strips (the old slab-mask
	-- above silently dropped lines on straight/flat facets). Tinted white/yellow at runtime.
	LINE_TEXTURE = "rbxassetid://107844006651215",
	LINE_DASH_TEXTURE = "rbxassetid://120954204545805",
	-- Fraction of the line texture's width occupied by paint (rest transparent margin); the
	-- strip part is widened by 1/this so the visible line equals the requested width.
	SURFACE_LINE_FILL = 0.56,
	SPEED_NUMBER_TEXTURES = {
		[10] = "rbxassetid://76843868687943",
		[20] = "rbxassetid://87738522882401",
		[30] = "rbxassetid://98890857161634",
		[40] = "rbxassetid://87199754636989",
		[50] = "rbxassetid://129060988186956",
		[60] = "rbxassetid://78859328582236",
		[70] = "rbxassetid://83505393900719",
		[80] = "rbxassetid://98456007799957",
		[90] = "rbxassetid://101512989721339",
		[100] = "rbxassetid://134313039074887",
		[110] = "rbxassetid://131274247775148",
		[120] = "rbxassetid://90256155015881",
	},
	SURFACE_LINE_MASK_CORE_FRACTION = 2 / 512,
	SURFACE_LINE_WEAR_REPEAT = 64,
	-- Transparent road-marking masks. Renderers tint these at runtime, replacing
	-- multi-part painted geometry with one visual-only plate per symbol.
	ARROW_TEXTURE_LEFT = "rbxassetid://73061078033110",
	ARROW_TEXTURE_THROUGH = "rbxassetid://124395754074017",
	ARROW_TEXTURE_RIGHT = "rbxassetid://92836908822643",
	ARROW_TEXTURE_LEFT_THROUGH = "rbxassetid://139942758683997",
	ARROW_TEXTURE_THROUGH_RIGHT = "rbxassetid://133629234824869",
	ARROW_TEXTURE_LEFT_RIGHT = "rbxassetid://106703801543138",
	ARROW_TEXTURE_ALL = "rbxassetid://107330513057979",
	ARROW_TEXTURE_UTURN_LEFT = "rbxassetid://128154549686996",
	ARROW_TEXTURE_UTURN_RIGHT = "rbxassetid://117829199053452",
	ARROW_TEXTURE_MERGE_LEFT = "rbxassetid://110290233912280",
	ARROW_TEXTURE_MERGE_RIGHT = "rbxassetid://122055327284663",
	ARROW_TEXTURE_WIDTH = 10,
	ARROW_TEXTURE_LENGTH = 10,
	DEADEND_EDGE_TEXTURE = "rbxassetid://108553987243976",
	PARKING_STALL_TEXTURE = "rbxassetid://74892875066015",
	TRANSIT_ROUTE_ARROW_TEXTURE = "rbxassetid://121194033324366",
	TRAFFIC_SIGNAL_FACE_TEXTURE = "rbxassetid://100394179805952",
	VEHICLE_HUBCAP_TEXTURE = "rbxassetid://102175148638651",
	GHOST_COLOR_VALID = Color3.fromRGB(80, 200, 120),
	GHOST_COLOR_INVALID = Color3.fromRGB(220, 80, 80),
	GHOST_COLOR_SNAP = Color3.fromRGB(245, 195, 90),
	GHOST_TRANSPARENCY = 0.5,

	INDICATOR_RING_RADIUS = 12,
	INDICATOR_DOT_RADIUS = 8,
	INDICATOR_COLOR = Color3.fromRGB(232, 205, 130),
	INDICATOR_SNAP_COLOR = Color3.fromRGB(255, 200, 70),
	INDICATOR_SNAP_SEG_COLOR = Color3.fromRGB(120, 255, 160),
	INDICATOR_SNAP_INTER_COLOR = Color3.fromRGB(255, 140, 60),
	INDICATOR_SNAP_GUIDE_COLOR = Color3.fromRGB(255, 160, 90),
	INDICATOR_SNAP_CROSS_COLOR = Color3.fromRGB(255, 235, 140),
	INDICATOR_SNAP_GRID_COLOR  = Color3.fromRGB(192, 200, 140),
	INDICATOR_RING_TRANSPARENCY = 0.7,
	INDICATOR_SNAP_HEIGHT = 0.9,
	INDICATOR_SNAP_DOT_SCALE = 1.3,

	GRID_SIZE = 12,
	ANGLE_SNAP_STEP = math.rad(45),
	ANGLE_SNAP_TOLERANCE = math.rad(3),
	ANGLE_SNAP_CARDINAL_TOL = math.rad(7),
	ANGLE_SNAP_DIAGONAL_TOL = math.rad(4),

	MIN_INTERSECTION_ANGLE_DEG = 18,
	MIN_INTERSECTION_ANGLE_RAD = math.rad(18),

	-- CS2 approach shaping. A road drawn into or out of a junction shallower than this is
	-- BENT, not refused: ApproachBend rotates that end's handle until the arm leaves the node
	-- at this angle and the curve swings back toward where the player aimed. The two MIN_*
	-- angle gates above and below are now floors the bend guarantees, not the player's limit --
	-- they only catch a forged request that never went through the bend.
	APPROACH_BEND_MIN_ANGLE_RAD = math.rad(45),

	-- Two arms leaving one node with cos(angle) above this form a SHALLOW FORK: the
	-- renderer must push both mouths back ~(hw1+hw2+nose)/(2 sin(angle/2)) so the gore
	-- between them opens enough for a corner curb. Shared by the renderer's fork logic
	-- and placement validation (which rejects forks whose arms are too short for that
	-- pushback -- otherwise the approaches pile up in the gore).
	FORK_COS_MIN = 0.7,
	FORK_NOSE_MARGIN = 3,

	-- Give-way "shark teeth" painted across a highway ramp's merge mouth: a row of
	-- small triangles pointing at the approaching driver, set back from the join.
	-- MUTCD §3B.19 ¶12 yield line: solid white isosceles triangles pointing at the driver,
	-- base 12-24 in, height 1.5x the base, 3-12 in between them. Authored at 0.25 m/stud,
	-- so 2.2 = 22 in base, 3.3 = 33 in height, 0.8 = 8 in gap.
	GIVEWAY_SETBACK = 6,
	GIVEWAY_TOOTH_LENGTH = 3.3,
	GIVEWAY_TOOTH_WIDTH = 2.2,
	GIVEWAY_TOOTH_GAP = 0.8,

	-- The inner edge of a curved road sits at radius (centerlineRadius - halfWidth -
	-- sidewalk). Below that the inner curb/sidewalk pinches to a cusp and folds through
	-- itself (the mangled inside of a hairpin). The tightest radius a road may be drawn at
	-- is derived PER ROAD TYPE from its own width plus this clearance, so the inner edge
	-- always keeps a clean arc -- see RoadTypeCatalog.minCurveRadius. A single global value
	-- can't serve both a 9-wide alley and a 60-wide avenue, so this replaces the old
	-- MIN_CURVE_RADIUS=16 (which was below the default road's own collapse point).
	CURVE_INNER_EDGE_CLEARANCE = 6,

	-- Grade a road is EXPECTED to stay under. NOT a placement limit any more -- height is
	-- unrestricted, a road may be drawn as steep as the player likes. What still reads this is
	-- rendering (RoadSceneRenderer's parking-apron drop and pillar spacing), where it is a
	-- "this arm is steep" threshold rather than a veto.
	MAX_ROAD_GRADE = 0.20,

	-- Two junctions closer than (widest arm half-width + corner radius + this) are ONE
	-- junction: their paved fills would overlap, so the graph welds them into a single node
	-- instead of drawing two on top of each other. Beyond it they stay separate and the link
	-- between them keeps its own crosswalks -- which is what tells the player they are two.
	-- There is deliberately no MINIMUM SPACING: junctions are never refused for being close.
	JUNCTION_MERGE_MARGIN = 4,
	-- A connector whose clear length (after both ends' junction setbacks) is under this has no
	-- room for junction furniture: crosswalk/stop line/sidewalk/lane arrows are dropped and the
	-- through lane lines just flow across it.
	CRAMPED_LINK_USABLE = 14,
	PLACEMENT_OVERLAP_DIST = 12,
	PLACEMENT_OVERLAP_FRACTION = 0.34,
	-- Studs of sustained overlap with a SINGLE existing road that flags a placement, regardless of
	-- the drawn road's total length. The whole-candidate fraction above misses a long road that
	-- runs over another for only a short stretch; this length-based check catches it.
	PLACEMENT_OVERLAP_MIN_LENGTH = 18,
	-- Two roads' SURFACES overlap where their centerlines sit closer than the sum of their
	-- half-widths. The old fixed PLACEMENT_OVERLAP_DIST (12) ignored width, so a 36-wide road
	-- could run half over another and never trip it. A sample counts as overlapping when the
	-- gap is under this fraction of (newHalf + existHalf)...
	PLACEMENT_OVERLAP_WIDTH_FACTOR = 0.7,
	-- ...AND the two roads run nearly parallel there (|cos angle| above this, ~30deg). The
	-- parallel gate lets a clean crossing or a junction approach pass close at an angle, and
	-- only flags a road dragged ALONG another at a shallow angle (the overlap the player sees).
	PLACEMENT_OVERLAP_PARALLEL_COS = 0.87,
	-- Minimum angle between the two centerlines for a body-to-body crossing. This is a RENDERER
	-- FLOOR, not a design rule: a crossing is not bent (the hit is mid-curve, with no handle to
	-- rotate), and below this the junction is not geometry any more -- the two roads are running
	-- along each other. Was 25deg and refused ordinary diagonal crossings; the reach cap
	-- (JUNCTION_MAX_REACH_FACTOR) already keeps a shallow one from paving a giant delta, so
	-- everything between here and 25 now builds, with approach surfaces that simply overlap.
	MIN_CROSSING_ANGLE_RAD = math.rad(10),
	-- Max tangent rotation a road may have within the junction's reach of a crossing or
	-- T-join point. Arm mouths anchor to the real curve, but past this much bend inside
	-- the junction the corner fillets/curbs fold through the fill (the mangled junction
	-- on a sharp curve). Also a renderer floor rather than a design rule -- raised from 45deg,
	-- which was refusing crossings on ordinary sweeping bends.
	JUNCTION_APPROACH_MAX_BEND = math.rad(75),
	INTERSECTION_DISC_RADIUS = 22,

	ZFIGHT_OFFSET = 0.01,

	SEGMENT_SPLIT_TOLERANCE = 3,
	NODE_WELD_RADIUS = 12,
	JUNCTION_MARGIN = 3,
	MARKING_GAP = 0.8,
	STOP_LINE_DEPTH = 1.6,
	CROSSWALK_GAP_FROM_STOP = 1.0,
	JUNCTION_EDGE_WIDTH = 0.8,
	-- Corner rounding at junction mouths. Effective radius is max(this, SIDEWALK_WIDTH/2
	-- + JUNCTION_MIN_INNER_CURB_RADIUS). DO NOT lower to shrink junctions: tighter mouths
	-- close the gore at shallow forks and the corner-curb ribbon shortcuts straight
	-- through the fill (the diagonal slab bug).
	JUNCTION_CORNER_RADIUS = 12,
	-- Cap on how far an intersection arm boundary may extend from the node, as a
	-- multiple of the widest arm's half-width. The corner-fillet geometry (the meet of
	-- two inner road edges) grows like 1/tan(theta/2), so a shallow-angle fork or merge
	-- would otherwise push a single junction out to hundreds of studs (18deg -> ~7.8x,
	-- 5deg -> ~24x half-width). Real multi-way stars top out near a 6-way at ~2.8x, so
	-- this leaves every legitimate junction untouched and only clamps the pathological
	-- shallow cases: there the two approach surfaces simply overlap instead of paving a
	-- giant delta. Keep above the worst real star (~2.8x) with headroom.
	JUNCTION_MAX_REACH_FACTOR = 3.0,
	JUNCTION_MIN_INNER_CURB_RADIUS = 4,

	-- == Node tool (CS "Node Controller") ======================================
	-- Per-arm junction shaping stored on the segment END that meets the node:
	-- corner = that corner's fillet radius (default JUNCTION_CORNER_RADIUS),
	-- offset = extra studs the arm's mouth is pushed OUT of the junction.
	-- Bounds are shared by the client sliders and the server validator, so a
	-- forged request can only ask for something the UI could also ask for.
	NODE_CORNER_MIN = 4,
	NODE_CORNER_MAX = 48,
	NODE_OFFSET_MIN = -12,
	NODE_OFFSET_MAX = 60,
	-- Arm ANGLE is not stored: it rotates the segment's own tangent handle at that
	-- end (real geometry), so this only caps how far one edit may swing it.
	NODE_ANGLE_MAX_DEG = 40,
	JUNCTION_CURB_JOIN_OVERLAP = 2,
	CROSSWALK_SETBACK = 2,
	-- Longitudinal-bar ("continental") crosswalk, MUTCD §3B.18: bars 12-24 in wide with
	-- 12-60 in gaps, and the crossing 6-10 ft deep. 8 studs = 2 m = 6.6 ft.
	CROSSWALK_DEPTH = 8,
	CROSSWALK_STRIPE_WIDTH = 1.8,
	CROSSWALK_GAP = 1.4,
	CROSSWALK_EDGE_MARGIN = 1.2,

	ARROW_LENGTH = 9.2,
	ARROW_SHAFT_HALF = 0.84,
	ARROW_HEAD_HALF = 2.3,
	ARROW_HEAD_LENGTH = 2.7,
	ARROW_TURN_REACH = 2.1,
	ARROW_BRANCH_SCALE = 0.85,
	ARROW_GAP = 6,
	ARROW_THROUGH_CONE_DEG = 35,

	NAV_WAYPOINT_SPACING = 56,
	-- Max distance a lane chord may stray from the true offset curve. Cars follow
	-- lane points with straight lerps, so this IS the worst-case lane error on
	-- bends and grades.
	NAV_CHORD_TOLERANCE = 0.2,
	-- Max subdivisions per base span when refining (2^depth shorter spans).
	NAV_REFINE_DEPTH = 4,
	NAV_LANE_CHANGE_SPACING = 200,
	NAV_LANE_CHANGE_LENGTH = 36,
	NAV_SPATIAL_CELL_SIZE = 256,
	NAV_TURN_SETBACK = 32,
	NAV_TURN_HANDLE = 48,

	-- Live traffic routing. Congestion is a smoothed 0..1 pressure published by
	-- NPCDriverService; it changes path cost only, so no road rebuild is required.
	NAV_CONGESTION_WEIGHT = 3.0,
	NAV_CONGESTION_UPDATE_INTERVAL = 0.75,
	NAV_CONGESTION_SMOOTHING = 0.2,
	NAV_CONGESTION_JAM_SPEED_RATIO = 0.35,
	NAV_CONGESTION_MIN_QUEUE = 3,
	-- Cars commit to their choice. Traffic must stay bad, and the replacement route
	-- must be decisively better, before a directed trip changes course.
	NAV_REROUTE_JAM_TIME = 7.0,
	NAV_REROUTE_COOLDOWN = 30.0,
	NAV_REROUTE_MIN_IMPROVEMENT = 0.3,
	NAV_REROUTE_MAX_PER_TRIP = 2,
	NAV_REROUTE_REVERSAL_LOCK = 60.0,

	-- == Anticipated load (the nav-app effect) ================================
	-- Congestion above is REACTIVE: a road only looks bad once cars are already
	-- crawling on it, so a burst of drivers planning at the same moment all pick the
	-- same empty-looking corridor and then create the jam together. Route BOOKINGS
	-- fix that: committing to a route reserves capacity on its edges, so the next
	-- driver to plan already sees the corridor filling and takes the longer way
	-- round BEFORE anyone is stuck. Bookings are intent, not observation -- weighted
	-- below real congestion so a measured jam always outranks a predicted one.
	NAV_BOOKING_WEIGHT = 1.6,
	-- Studs of lane per booked vehicle before an edge reads as fully spoken for.
	-- Lower = traffic spreads onto alternatives sooner.
	NAV_BOOKING_CAPACITY_GAP = 90,
	-- Seconds a booking survives if it is never explicitly released (car destroyed
	-- mid-trip, trip handed off). Comfortably longer than a normal cross-city drive;
	-- purely a leak guard, since arrivals release their own booking.
	NAV_BOOKING_TTL = 150.0,
	-- The edge the driver is already ON is not a choice, so booking it would only buy
	-- pointless detours right outside its own driveway -- skip it. Do NOT raise this:
	-- on a short trip the branch point IS the second edge, and skipping that is
	-- skipping the only decision the booking exists to influence.
	NAV_BOOKING_SKIP_EDGES = 1,

	-- == Running cost (fuel) ==================================================
	-- Drivers do not route on time alone -- they route on what the trip COSTS them,
	-- which is the standard "generalized cost" of transport economics:
	--     cost = value_of_time * time  +  fuel_price * fuel_burned
	-- Without the second term a motorway is simply always better, because it is
	-- always faster. With it, the motorway has to EARN its detour: it burns more per
	-- km than an avenue does, so a driver only swings out onto it when the time it
	-- saves is worth the extra fuel.
	--
	-- Money per litre. Deliberately a fixed constant, not a market that drifts: a
	-- gas price that moved on its own would make identical trips route differently
	-- from one minute to the next for no reason the player can see. Change it here
	-- and every driver in the city re-prices its options together.
	NAV_FUEL_PRICE = 1.8,
	-- Money per HOUR of a driver's time. This is the exchange rate between the two
	-- terms above -- raise it and drivers buy speed with fuel (motorways, direct
	-- routes); lower it and they get thrifty (slower, shorter, steadier roads).
	NAV_VALUE_OF_TIME_PER_HOUR = 60,

	-- == Roundabouts ==========================================================
	-- The radius is to the circulating lane CENTERLINE. The carriageway spans
	-- radius +/- width/2; the raised island fills the disc inside the inner curb.
	-- Size presets (small/medium/large, CS2-style): pick per expected volume.
	-- Small suits quiet 2-lane streets; Large gives entry gaps room on busy arterials.
	ROUNDABOUT_RADIUS_SMALL = 44,
	ROUNDABOUT_RADIUS_MEDIUM = 60,
	ROUNDABOUT_RADIUS_LARGE = 100,
	ROUNDABOUT_MIN_RADIUS = 44,
	ROUNDABOUT_MAX_RADIUS = 280,
	-- Arcs forming the ring. 8 octant cubic-bezier arcs approximate a circle to
	-- well under a stud of radial error and give plenty of weldable nodes for arms.
	ROUNDABOUT_ARC_COUNT = 8,
	-- Studs the raised island sits inside the inner curb line (a small planted gap).
	ROUNDABOUT_ISLAND_INSET = 3,
	-- FLUSH with the carriageway (= ROAD_THICKNESS * 0.5 above the slab underside): the centre
	-- of a roundabout is left as plain ground for the player to decorate. It used to be a 4.4-stud
	-- planted mound, and anything dropped on it sank -- props are grounded on the HEIGHTMAP, which
	-- knows nothing about the mound.
	ROUNDABOUT_ISLAND_HEIGHT = 1.0,
	ROUNDABOUT_ISLAND_COLOR = Color3.fromRGB(126, 162, 96),
	ROUNDABOUT_ISLAND_CURB_COLOR = Color3.fromRGB(170, 170, 175),
	-- Brick truck apron between the circulating lanes and the island kerb (it takes the place of
	-- the ring's inner sidewalk). Mountable: barely above the carriageway, so a long vehicle's
	-- rear wheels can ride over it. The client bakes this colour as pavers (RoadMeshView).
	ROUNDABOUT_APRON_WIDTH = 12, -- at most; a fifth of the carriageway's inner radius on small rings
	ROUNDABOUT_APRON_RISE = 0.24,
	ROUNDABOUT_APRON_COLOR = Color3.fromRGB(178, 96, 72),
	-- Light kerb band between the apron and the carriageway, and the island's own kerb.
	ROUNDABOUT_APRON_EDGE_WIDTH = 1.6,
	ROUNDABOUT_KERB_WIDTH = 2.4,
	-- The circulating lane dividers: short dashes, close together (a street's 10/30 ft pattern
	-- left a small ring with a handful of dashes).
	ROUNDABOUT_DASH_LENGTH = 8,
	ROUNDABOUT_DASH_GAP = 8,
	-- Splitter islands: kerbed brick islands between each arm's entry and exit, shaped by the
	-- paths cars actually take through the mouth (the lane graph's connectors) so no vehicle
	-- ever clips one. Clearance is from a path's centreline to the kerb face.
	ROUNDABOUT_SPLITTER_CLEARANCE = 6,
	ROUNDABOUT_SPLITTER_MIN_WIDTH = 3,
	ROUNDABOUT_SPLITTER_MAX_LENGTH = 80,
	-- What the middle of a roundabout shows. "Empty" is plain grass, left for the player's own
	-- design; the rest are planted from the Nature models (RoadSceneRenderer).
	ROUNDABOUT_CENTRE_PRESETS = { "Empty", "Tree", "Garden", "Palms", "Fountain" },
	-- A circulating car within this many studs of an entry node blocks entry: the
	-- entering car must give way to it.
	ROUNDABOUT_YIELD_DIST = 60,
	-- Yield sign prop at each ring entry (RoadSceneRenderer): red inverted-triangle
	-- plate on a pole at the approach's right kerb.
	YIELD_SIGN_POLE_HEIGHT = 11,
	YIELD_SIGN_PLATE_SIZE = 4.4,
	YIELD_SIGN_COLOR = Color3.fromRGB(196, 40, 40),
}

-- == Master world scale =====================================================
-- Single knob for the whole map (ZoneGrid + RoadTypeCatalog read RoadConstants.WORLD_SCALE).
-- 0.5 = half-size world. Applied ONLY to the cross-section stud dimensions listed below, so
-- roads, sidewalks, curbs, crosswalks, markings, arrows, guardrails, pillars and junction
-- furniture all shrink together. Topology/snapping/nav/segment-length tolerances are
-- deliberately NOT scaled (scaling them risks placement/nav bugs). Flip to 1 to revert.
RoadConstants.WORLD_SCALE = 0.5
do
	local WS = RoadConstants.WORLD_SCALE
	if WS ~= 1 then
		local SCALED = {
			"ROAD_WIDTH", "ROAD_THICKNESS", "GROUND_ROAD_TOP_LIFT", "GROUND_ROAD_EDGE_HEIGHT", "SIDEWALK_WIDTH", "SIDEWALK_HEIGHT", "GROUND_SKIRT",
			"CURVE_INNER_EDGE_CLEARANCE", "CORNER_RADIUS",
			"ELEVATED_PILLAR_WIDTH", "ELEVATED_PILLAR_MIN_HEIGHT", "ELEVATED_PILLAR_SPACING", "ELEVATED_DEFAULT_HEIGHT",
			"TUNNEL_DEPTH", "TUNNEL_MAX_DEPTH", "TUNNEL_WALL_THICKNESS",
			"GUARDRAIL_MIN_HEIGHT", "GUARDRAIL_HEIGHT", "GUARDRAIL_BEAM_HEIGHT", "GUARDRAIL_BEAM_WIDTH", "GUARDRAIL_POST_WIDTH", "GUARDRAIL_POST_SPACING",
			"DASH_LENGTH", "DASH_GAP", "ARROW_TEXTURE_WIDTH", "ARROW_TEXTURE_LENGTH",
			"FORK_NOSE_MARGIN", "GIVEWAY_SETBACK", "GIVEWAY_TOOTH_LENGTH", "GIVEWAY_TOOTH_WIDTH", "GIVEWAY_TOOTH_GAP",
			"STOP_LINE_DEPTH", "MARKING_GAP", "JUNCTION_EDGE_WIDTH", "JUNCTION_CORNER_RADIUS", "JUNCTION_MIN_INNER_CURB_RADIUS", "JUNCTION_CURB_JOIN_OVERLAP", "JUNCTION_MARGIN",
			"NODE_CORNER_MIN", "NODE_CORNER_MAX", "NODE_OFFSET_MIN", "NODE_OFFSET_MAX",
			"CROSSWALK_SETBACK", "CROSSWALK_DEPTH", "CROSSWALK_STRIPE_WIDTH", "CROSSWALK_GAP", "CROSSWALK_EDGE_MARGIN",
			"INTERSECTION_DISC_RADIUS",
			"ARROW_LENGTH", "ARROW_SHAFT_HALF", "ARROW_HEAD_HALF", "ARROW_HEAD_LENGTH", "ARROW_TURN_REACH", "ARROW_GAP",
			"ROUNDABOUT_RADIUS_SMALL", "ROUNDABOUT_RADIUS_MEDIUM", "ROUNDABOUT_RADIUS_LARGE", "ROUNDABOUT_MIN_RADIUS", "ROUNDABOUT_MAX_RADIUS", "ROUNDABOUT_ISLAND_INSET", "ROUNDABOUT_ISLAND_HEIGHT", "ROUNDABOUT_YIELD_DIST",
			"ROUNDABOUT_APRON_WIDTH", "ROUNDABOUT_APRON_RISE", "ROUNDABOUT_APRON_EDGE_WIDTH", "ROUNDABOUT_KERB_WIDTH",
			"ROUNDABOUT_DASH_LENGTH", "ROUNDABOUT_DASH_GAP",
			"ROUNDABOUT_SPLITTER_CLEARANCE", "ROUNDABOUT_SPLITTER_MIN_WIDTH", "ROUNDABOUT_SPLITTER_MAX_LENGTH",
			"YIELD_SIGN_POLE_HEIGHT", "YIELD_SIGN_PLATE_SIZE",
			"MAX_PLACE_SEGMENT_LENGTH",
		}
		for _, k in SCALED do
			if type(RoadConstants[k]) == "number" then RoadConstants[k] = RoadConstants[k] * WS end
		end
		-- The metric ratio rides the same knob: at WS 0.5 it becomes 0.5 (2 studs = 1 m),
		-- so every shown measurement, per-metre cost and upkeep reads the same numbers as
		-- the full-size world. Player-facing meters never change with the scale.
		RoadConstants.STUD_TO_METER = RoadConstants.STUD_TO_METER / WS
	end
end

-- Depth of a junction's painted furniture band past the fill: stop line + gap +
-- crosswalk + marking gap. Topology (dead-end stub absorption in RoadNetwork) and the
-- renderer's cap suppression both measure "too close to the junction" with this one
-- number, so a renderer layout change updates both in one place.
RoadConstants.JUNCTION_FURNITURE_DEPTH = RoadConstants.STOP_LINE_DEPTH
	+ RoadConstants.CROSSWALK_GAP_FROM_STOP
	+ RoadConstants.CROSSWALK_DEPTH
	+ RoadConstants.MARKING_GAP

-- == Driving side ===========================================================
-- Nothing here. The side traffic drives on, the lane-offset sign, and which turn crosses
-- oncoming traffic all live in RoadRules, because they follow a PLAYER setting and this
-- table is frozen. Deriving a copy here would only create a second source of truth that
-- silently went stale the moment the player changed the setting.

local _cachedGroundY: number? = nil

function RoadConstants.getGroundY(): number
	if _cachedGroundY then return _cachedGroundY end

	local baseplate = workspace:FindFirstChild("Baseplate")
	if baseplate and baseplate:IsA("BasePart") then
		_cachedGroundY = baseplate.Position.Y + baseplate.Size.Y * 0.5
	else
		_cachedGroundY = 0
	end

	return _cachedGroundY
end

function RoadConstants.getSurfaceY(): number
	return RoadConstants.getGroundY()
end

function RoadConstants.getRoadTopY(): number
	return RoadConstants.getGroundY() + RoadConstants.GROUND_ROAD_TOP_LIFT
end

-- STUD_TO_METER is the ONE metre conversion in the game -- labels, costs, speeds, nav and
-- prop authoring all go through it. Anything that wants studs-per-metre reads
-- 1 / STUD_TO_METER (SnapConstants does exactly that); nothing gets its own number.
function RoadConstants.formatMeters(studs: number): string
	return string.format("%d m", math.round(studs * RoadConstants.STUD_TO_METER))
end

-- Frozen per project rule 12. Every field above is an immutable constant; the
-- only runtime-derived value (ground Y) is memoised in the _cachedGroundY
-- upvalue, not stored on this table, so the shallow freeze is safe.
return table.freeze(RoadConstants)
