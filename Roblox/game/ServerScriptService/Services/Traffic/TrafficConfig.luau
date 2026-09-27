--!strict
-- TrafficConfig
-- Every tunable for the traffic signal system in one frozen table.
-- Timing follows the standard controller pattern: green -> yellow -> all-red
-- clearance -> next phase. Greens stretch with queue demand between MIN/MAX.

local RoadConstants = require(game:GetService("ReplicatedStorage").Road.RoadConstants)
-- Half-size world: stud distances/speeds and the pole model scale ride the knob.
local WS = RoadConstants.WORLD_SCALE

local TrafficConfig = {
	-- == Phase timing (seconds) ==============================================
	MIN_GREEN          = 6,    -- floor for a through green, even with no demand
	MAX_GREEN          = 16,   -- cap for a through green under heavy demand
	SEC_PER_QUEUED_CAR = 1.2,  -- adaptive: extra green per car waiting at the line
	-- Yellow change interval. MUTCD 11th Ed. §4F.17 ¶13 makes 3.0 s the FLOOR and 6.0 s the
	-- ceiling -- the old 2 s here was below anything legal on a real approach. MUTCD sets no
	-- formula, but universal US practice is the ITE kinematic equation, which on level grade
	-- reduces to Y = 1.0 + V/20 (V in mph): 3.0 s at 25 mph, 3.6 at 35, 4.3 at 45, 5.0 at 55.
	-- A flat value is used until signal timing is made per-approach; 3.2 s sits at the 30 mph
	-- city default. See YELLOW_BY_SPEED_MPH below for the table to switch to.
	YELLOW_TIME        = 3.2,
	YELLOW_MIN         = 3.0,  -- §4F.17 ¶13, Standard
	YELLOW_MAX         = 6.0,  -- §4F.17 ¶13, Standard
	-- Red clearance R = (W + L) / V with L = 20 ft. Practically 1.0-2.0 s on a local or
	-- collector, 2.0-3.0 s on an arterial box, hard capped at 6 s. 0.7 s was shorter than
	-- any real intersection clears in.
	ALL_RED_TIME       = 1.5,  -- every arm red while the box clears
	GAP_OUT_POLL       = 1,    -- after MIN_GREEN, re-check demand this often

	-- Yellow by approach speed, from Y = 1.0 + V/20 clamped to the §4F.17 range. Not read
	-- yet -- TrafficSignalService currently times every approach alike. Wire this in when
	-- signal phases learn their approach's speed limit, and a 55 mph arterial will stop
	-- getting the same 3.2 s yellow as a 25 mph residential street.
	YELLOW_BY_SPEED_MPH = {
		[25] = 3.0, [30] = 3.2, [35] = 3.6, [40] = 4.0,
		[45] = 4.3, [55] = 5.0, [65] = 5.6, [70] = 6.0,
	},

	-- == Protected left turns =================================================
	-- Lane-aware: a road pair gets ONE leading left phase only when an approach
	-- has a dedicated left-turn lane (every connection from that lane is a
	-- left/U-turn). Only those lanes are green during it -- opposing left lanes
	-- run together like a real dual-left. Shared single lanes never get a turn
	-- phase; their lefts stay permissive (gap acceptance). The phase is skipped
	-- when no car is queued on the left lanes.
	LEFT_MIN_GREEN = 4,
	LEFT_MAX_GREEN = 9,

	-- == Pedestrian scramble phase ============================================
	PED_ENABLED        = true,
	PED_EVERY_N_CYCLES = 2,  -- run the walk phase every Nth full cycle
	PED_WALK_TIME      = 7,  -- all arms red, IsPedWalk(nodeId) == true

	-- == Emergency preemption =================================================
	PREEMPT_APPROACH_DIST = 90 * WS,  -- studs from the stop line that an Emergency vehicle grabs the signal
	PREEMPT_TTL           = 1.5, -- request must be refreshed within this window or it lapses
	PREEMPT_MAX_HOLD      = 20,  -- absolute cap so a parked ambulance cannot hold a green forever

	-- == Queue measurement =====================================================
	QUEUE_ZONE      = 45 * WS, -- studs back from the stop line that count as "queued"
	QUEUE_MAX_SPEED = 6 * WS,  -- studs/s; faster cars are flowing, not queued

	-- == Pole placement ========================================================
	-- All placement is derived from the intersection's own geometry (junction
	-- boundary, road width, bezier tangent) -- these are local-frame margins only.
	POLE_SCALE            = 1.0 * WS,        -- ScaleTo applied to the template model (authored full size)
	POLE_JUNCTION_SETBACK = 1.0 * WS,        -- studs beyond the junction mouth, along the arm
	POLE_CURB_MARGIN      = 2.0 * WS,        -- studs outside the road edge (onto the curb)
	SIGNAL_HEAD_YAW       = math.rad(270),   -- template head's local yaw so lenses face traffic
	MIN_ARMS_FOR_LIGHT    = 3,

	-- == Lens colours ==========================================================
	COLOR_RED_ON    = Color3.fromRGB(255, 40, 40),
	COLOR_YELLOW_ON = Color3.fromRGB(255, 200, 0),
	COLOR_GREEN_ON  = Color3.fromRGB(40, 220, 60),
	COLOR_OFF       = Color3.fromRGB(28, 28, 28),
}

return table.freeze(TrafficConfig)
