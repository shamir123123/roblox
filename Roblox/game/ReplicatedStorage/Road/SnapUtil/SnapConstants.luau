--!strict

-- Anchored to ReplicatedStorage, NOT to script.Parent.Parent: this module gets cloned
-- elsewhere to test edits without the require cache, and a relative path then resolves
-- into the clone's parent, which has no RoadConstants.
local RoadConstants = require(game:GetService("ReplicatedStorage").Road.RoadConstants)

-- Studs per metre, THE one conversion, taken from RoadConstants so the snap model, the
-- length labels, costs, speeds and prop authoring can never disagree. 2 at WORLD_SCALE 0.5,
-- and that is the scale the world is really built at: a traffic lane measures 4.5 m and a
-- sidewalk 1.5 m through it. Every distance below is authored in METRES and converted here.
local M = 1 / RoadConstants.STUD_TO_METER

local SnapConstants = {
	METER = M,

	SNAP_SEGMENT_SAMPLES   = 32,
	SNAP_SEGMENT_RADIUS    = 20,
	SNAP_SIDE_MARGIN       = 8,
	SNAP_REBUILD_THRESHOLD = 0.05,

	-- ONE hold radius for every snap POINT -- node, intersection, guideline, guide mark.
	-- Road BODIES are not points: they capture across their own footprint (half width +
	-- sidewalk + SNAP_SIDE_MARGIN) instead.
	-- 10 m: 5 m let go too easily, 16 m grabbed from across the street.
	SNAP_HOLD = 10 * M,

	-- == Guidelines ===========================================================
	-- A guide is a ray off a road node: along the road, and square to it. Rings sit every
	-- GUIDE_MARK_SPACING down the ray, and a ring starts its own pair of rays at right
	-- angles -- that chain is how the grid walks out over open ground. Exactly ONE guide
	-- is live at a time; drawing the whole fan at once was the mess this replaces.
	-- Rings every 100 m -- the same spacing the auto-split puts nodes at, so a ring always
	-- lands where a node would. Windowed around the cursor, and never past GUIDE_LENGTH:
	-- a ring beyond the end of the drawn line is a pull with nothing on screen to explain it.
	GUIDE_MARK_SPACING  = 100 * M,
	GUIDE_MARK_COUNT    = 4,
	-- Rings fade out with distance from the cursor: the one you are about to land on reads
	-- solid, one 250 m up the guide is barely there.
	GUIDE_MARK_FADE     = 250 * M,
	-- Rings drawn ON the road at the points the guides leave from, so the grid is visible
	-- before any guide is in use. Same speed signal as the pull: they tween in as the cursor
	-- slows and are gone while panning. Reach is GUIDE_SOURCE_RADIUS -- deliberately shared.
	ROAD_RING_MAX       = 16,
	-- Rings survive a MUCH faster cursor than the pull does. Seeing where the snap points are
	-- is how you find one; being dragged onto one is a separate decision you make by slowing
	-- down. Keep this well ABOVE GUIDE_MAX_CURSOR_SPEED -- that ordering is what guarantees a
	-- pull always has a visible ring behind it, never the other way round.
	ROAD_RING_MAX_CURSOR_SPEED = 400 * M,
	GUIDE_MARK_ALPHA_NEAR = 0.45,
	-- Fully invisible by the time it reaches GUIDE_MARK_FADE, which is the same distance the
	-- rings are culled at. A ring that is still faintly visible when it gets culled POPS; one
	-- that has already faded to nothing does not.
	GUIDE_MARK_ALPHA_FAR  = 1,
	-- How far a snap point on a road can be and still matter. ONE radius for both the rings
	-- and the rays they throw, so a ring is drawn for every point that can pull and no point
	-- can pull without a ring. Comfortably wider than GUIDE_MARK_SPACING or you only ever
	-- see the single nearest ring.
	GUIDE_SOURCE_RADIUS = 250 * M,
	GUIDE_LENGTH        = 200 * M,
	-- Guides hold at HALF the distance real geometry does. A node or a kerb is a thing that
	-- is there; a guideline is a suggestion, and it should only catch the cursor when the
	-- player was already hunting for it.
	GUIDE_HOLD          = 5 * M,
	-- Guides are for placing, not for panning across the map. The pull scales DOWN with
	-- cursor speed and reaches zero here, so a guide can never grab a cursor being flung
	-- past it, and it weakens smoothly instead of cutting out at a threshold.
	GUIDE_MAX_CURSOR_SPEED = 50 * M,
	-- Hysteresis: once a guide HAS the cursor it holds on harder than it grabbed. It tolerates
	-- a faster cursor and pulls further, so sliding along a guide at speed does not keep
	-- dropping it, while acquiring one still takes deliberate slow aiming.
	GUIDE_HELD_SPEED_MULT = 2.5,
	GUIDE_HELD_PULL_MULT  = 1.8,
	GUIDE_DOT_SIZE      = 1.6,
	-- A dot every 5 m between the rings, so the guide is a ruler and not just a line.
	GUIDE_DOT_SPACING   = 5 * M,
	GUIDE_MARK_RADIUS   = 2.5 * M,
	-- Height a ring floats at. A road node stores the CENTRELINE height, which is half a slab
	-- BELOW the asphalt surface, so anything under ROAD_THICKNESS/2 is drawn inside the road
	-- and never seen. On open ground this just floats it clear of the terrain.
	GUIDE_MARK_LIFT     = RoadConstants.ROAD_THICKNESS * 0.5 + 0.5,

	-- == Angle ================================================================
	-- Free heading, with a magnet on the right angles ONLY: inside ANGLE_SNAP_TOL of a
	-- multiple of 90deg the heading locks to it (81deg -> 90deg), and anywhere else the
	-- cursor is obeyed exactly. Measured off the host road when the draw starts on one,
	-- so 0deg is a straight continuation and 90deg is a square T. No snap inside DEADZONE
	-- studs of the start (first-pixel jitter). Hold Alt for a fully free angle.
	ANGLE_SNAP_STEP     = math.rad(90),
	ANGLE_SNAP_TOL      = math.rad(10),
	ANGLE_SNAP_DEADZONE = 4,

	-- == Buildings ============================================================
	-- A building with this much clear ground or less between its road-access side and a
	-- road's edge is pulled square onto that road. Further out it stays where it is put:
	-- a building never NEEDS a road, it just lines up with one when it is close.
	BUILDING_SNAP_DIST = 10 * M,
	BUILDING_SETBACK   = 1 * M,

	-- Perpendicular T-junction snap: when a drawn endpoint lands on a road body and the
	-- approach comes in within PERP_SNAP_TOL of a right angle, the join slides along the
	-- host to a true 90deg. Never slides more than PERP_SNAP_MAX_SLIDE studs from the
	-- cursor, and never off a node weld. Angle snap off (or Alt) disables it.
	PERP_SNAP_TOL       = math.rad(10),
	PERP_SNAP_MAX_SLIDE = 24,

	-- Highway ramp join: a one-way highway drawn INTO another highway's body bends its
	-- end tangent to blend with the host's travel direction, whatever the approach angle.
	-- ponytail: 32deg is the shallowest join every existing placement gate accepts (25deg
	-- MIN_CROSSING_ANGLE floor + the ~30deg parallel-overlap gate); relax those per-highway
	-- before shrinking this if a CS-style shallower gore is ever wanted.
	MERGE_JOIN_ANGLE_RAD = math.rad(32),
	MERGE_HANDLE_MAX     = 64,

	GHOST_COLOR_VALID   = Color3.fromRGB(110, 200, 140),
	GHOST_COLOR_INVALID = Color3.fromRGB(225, 95,  95),
	GHOST_COLOR_SNAP    = Color3.fromRGB(240, 190, 110),
	GHOST_TRANSPARENCY  = 0.5,

	INDICATOR_RING_RADIUS       = 12,
	INDICATOR_DOT_RADIUS        = 8,
	-- Reticle dot as a fraction of the road's FOOTPRINT width, not a fixed radius: an
	-- alley and a motorway used to get the same 16-stud blob. Floored so the smallest
	-- road still has something to aim with.
	INDICATOR_DOT_WIDTH_FRAC    = 0.22,
	INDICATOR_DOT_MIN           = 1.6,
	INDICATOR_RING_TRANSPARENCY = 0.7,
	INDICATOR_SNAP_HEIGHT       = 0.9,
	INDICATOR_SNAP_DOT_SCALE    = 1.3,

	-- Calmer, less-neon palette. Neutral idle = soft sage-grey (honors the no gold/blue/cyan
	-- chrome rule); state colors stay distinct but lower-saturation so the preview reads as
	-- "designed" rather than a row of glow tubes.
	INDICATOR_COLOR            = Color3.fromRGB(210, 214, 200),
	INDICATOR_SNAP_COLOR       = Color3.fromRGB(240, 190, 110),
	INDICATOR_SNAP_SEG_COLOR   = Color3.fromRGB(120, 210, 150),
	INDICATOR_SNAP_INTER_COLOR = Color3.fromRGB(250, 165, 90),
	INDICATOR_SNAP_GUIDE_COLOR = Color3.fromRGB(238, 188, 120),
	INDICATOR_SNAP_GRID_COLOR  = Color3.fromRGB(175, 196, 165),
	INDICATOR_NODE_COLOR       = Color3.fromRGB(245, 248, 250),

	-- Cursor reticle pulse (cheap size/transparency wobble on RenderStepped).
	-- The reticle is drawn in SmoothPlastic, NOT Neon: the neon discs bloomed over the
	-- exact patch of ground the player was aiming at.
	RETICLE_MATERIAL          = Enum.Material.SmoothPlastic,
	RETICLE_PULSE_SPEED       = 2.2,
	RETICLE_PULSE_AMOUNT      = 0.06,
	RETICLE_ZONE_TRANSPARENCY = 0.86,

	-- Angle protractor drawn at the gesture start while angle snap is active.
	PROTRACTOR_RADIUS      = 24,
	PROTRACTOR_TICK_LENGTH = 6,
	PROTRACTOR_TICK_WIDTH  = 0.4,
	PROTRACTOR_TICK_COLOR  = Color3.fromRGB(150, 158, 150),
	PROTRACTOR_LOCK_COLOR  = Color3.fromRGB(240, 195, 110),
}

return SnapConstants