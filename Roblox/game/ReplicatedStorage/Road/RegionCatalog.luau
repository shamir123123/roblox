--!strict
-- RegionCatalog
-- The regional rule packs a city is built under. One frozen ruleset per US region:
-- speed limits, turn permissions, enforcement style and the signature manoeuvre that
-- gives the region its character. Pure data + lookup -- no state, no lifecycle, no
-- side effects on require. RoadRules queries these; nothing here reads the network.
--
-- Picker contract matches MapPresets: id / name / description, a List the client
-- renders and the server validates the client's choice against.
--
-- Legal snapshot: 2026-08-12. Traffic law moves constantly -- re-verify before each
-- content release. Fields tagged VERIFY are researched but NOT confirmed against
-- statute; do not build a region's identity on one without checking it first.

local RegionCatalog = {}

-- Legal speed limits are authored in MPH -- that is the unit the statutes are written
-- in, and rounding them to km/h first then back loses the round numbers (a 65 zone
-- becomes 105 becomes 65.2). The world runs on km/h (RoadRules.getSpeedLimitKmh), so
-- convert ONCE here at the boundary and never inline the factor anywhere else.
RegionCatalog.MPH_TO_KMH = 1.609344

function RegionCatalog.mphToKmh(mph: number): number
	return mph * RegionCatalog.MPH_TO_KMH
end

export type PedestrianDuty      = "stop" | "yield" | "halfRoadway"
export type SpeedDoctrine       = "absolute" | "primaFacie" | "mixed"
export type HelmetRule          = "all" | "under18" | "under19" | "under21" | "under26" | "none"
export type SchoolBusException  = "barrier" | "barrierOr5ftUnpaved" | "fiveLaneMinimum" | "always"
export type CameraLevel         = "none" | "banned" | "limited" | "common" | "pervasive"
export type ChainSystem         = "none" | "advisory" | "codedTraction" | "rSystem" | "tractionTire"
export type RoundaboutDensity   = "rare" | "some" | "common" | "dominant"
export type SchoolZoneTrigger   = "beacon" | "postedHours" | "childrenPresent"

-- The full shape. Sub-regions (NYC, DC) are authored as PARTIAL overlays merged over
-- their base region below, so the stored tables are typed loosely and this type serves
-- as the documented shape the ten base regions are authored against.
-- ponytail: no runtime shape validation. A typo'd field is a silent nil at the call
-- site rather than a load error. Add a checked assert pass here if regions ever come
-- from data instead of source.
export type RegionRuleset = {
	id: string,
	name: string,
	description: string,

	-- == Side of the road ====================================================
	-- Every US region drives on the right. This is the region's NATIVE side; the
	-- player setting overrides it (see RoadRules.getDrivingSide), so a player who
	-- prefers the left-hand world the city was built in keeps it.
	drivingSide: "left" | "right",

	-- The unit the region's limits are AUTHORED and SHOWN in. The simulation always
	-- runs in km/h (RoadRules.getSpeedLimitKmh); this only decides what the sign and
	-- the HUD read out, so a US city posts 65 where a European one posts 100.
	speedUnit: "mph" | "kmh",

	-- == Speed (MPH -- see MPH_TO_KMH above) =================================
	speedLimitHighway: number,       -- max rural interstate
	speedLimitUrbanHighway: number,  -- urban interstate
	speedLimitCity: number,          -- arterial ceiling
	speedLimitResidential: number,   -- unposted residential default
	speedLimitSchoolZone: number,
	schoolZoneTrigger: SchoolZoneTrigger,
	speedDoctrine: SpeedDoctrine,

	-- == Turns ===============================================================
	rightOnRed: boolean,             -- DEFAULT only; a per-junction sign still overrides
	leftOnRedOneWayToOneWay: boolean,
	leftOnRedTwoWayToOneWay: boolean,
	uTurnAllowed: boolean,
	signatureManeuver: string,

	-- == Intersections =======================================================
	roundaboutEntryYields: boolean,
	roundaboutDensity: RoundaboutDensity,

	-- == Bicycles ============================================================
	bicycleStopAsYield: boolean,     -- stop sign treated as yield
	bicycleRedAsStop: boolean,       -- red light treated as stop sign (full "Idaho stop")

	-- == Motorcycles =========================================================
	helmetRequired: HelmetRule,
	laneSplitting: boolean,          -- between MOVING traffic
	laneFiltering: boolean,          -- past STOPPED traffic
	laneFilterMaxSpeed: number,      -- mph; 0 when not permitted

	-- == Distraction / restraint =============================================
	handheldPhoneBanned: boolean,
	handheldEnforcementPrimary: boolean,
	textingBanned: boolean,
	seatbeltPrimary: boolean,        -- false = secondary: only ticketed alongside another offence
	seatbeltRearRequired: boolean,

	-- == Impairment ==========================================================
	bacLimit: number,
	openContainerAllowed: boolean,

	-- == Other road users ====================================================
	schoolBusDividedException: SchoolBusException,
	moveOverCoversDisabled: boolean,
	moveOverSlowdownMph: number,     -- mph below posted when you cannot move over
	jaywalkingEnforced: boolean,
	pedestrianDuty: PedestrianDuty,

	-- == Lanes / highway =====================================================
	keepRightEnforced: boolean,
	leftLanePassingOnly: boolean,    -- strict tier: illegal to cruise there even at the limit
	hovMinimum: number,              -- 0 = no HOV network in the region

	-- == Environment =========================================================
	chainLaws: boolean,
	chainLawSystem: ChainSystem,
	studdedTiresAllowed: boolean,
	studdedTireStartMonth: number,   -- 0 = year-round or not applicable
	studdedTireEndMonth: number,
	wipersOnLightsOn: boolean,

	-- == Vehicle / admin =====================================================
	frontPlateRequired: boolean,
	inspectionRequired: boolean,
	emissionsRequired: boolean,      -- somewhere in the region; often metro-only
	tollSystem: string,

	-- == Enforcement feel ====================================================
	cameraEnforcement: CameraLevel,
	radarDetectorLegal: boolean,
	penaltySeverity: number,         -- 1..5 GAME BALANCE dial, not a legal measure

	-- Per-state / per-city deltas merged over the base with applyOverlay.
	exceptions: { [string]: { [string]: any } },
}

-- Two rules hold in all fifty states, so they are recorded once here rather than
-- repeated (and mistyped) in twelve tables: every state has a Move Over law, and
-- every state has implied consent for chemical testing.
RegionCatalog.MOVE_OVER_LAW_UNIVERSAL = true
RegionCatalog.IMPLIED_CONSENT_UNIVERSAL = true

-- The basic speed rule ("never faster than is reasonable for conditions") also holds
-- everywhere. It is what makes a posted-limit-obeying driver still liable in fog or
-- snow, so weather-driven enforcement reads this, not a per-region flag.
RegionCatalog.BASIC_SPEED_RULE_UNIVERSAL = true

local Regions: { [string]: any } = {}

--------------------------------------------------------------------------------
Regions.newengland = {
	id = "newengland",
	name = "New England",
	description = "Rotaries instead of roundabouts, hard winters and almost no traffic cameras.",
	drivingSide = "right", speedUnit = "mph",

	speedLimitHighway = 65, speedLimitUrbanHighway = 55,
	speedLimitCity = 55, speedLimitResidential = 25,
	speedLimitSchoolZone = 20, schoolZoneTrigger = "postedHours",
	speedDoctrine = "absolute",

	rightOnRed = true,
	leftOnRedOneWayToOneWay = false,  -- CT, ME, NH, RI prohibit; MA and VT allow
	leftOnRedTwoWayToOneWay = false,
	uTurnAllowed = true,
	signatureManeuver = "Rotary",

	-- MA G.L. ch.89 s.8. REVERSED from the pre-2010 rule, when entering traffic held
	-- priority -- the reason older drivers still treat rotaries as a game of chicken.
	roundaboutEntryYields = true, roundaboutDensity = "common",
	bicycleStopAsYield = false, bicycleRedAsStop = false,

	helmetRequired = "all",  -- MA and VT universal; CT/RI under21, ME under18, NH none
	laneSplitting = false, laneFiltering = false, laneFilterMaxSpeed = 0,

	handheldPhoneBanned = true, handheldEnforcementPrimary = true, textingBanned = true,
	seatbeltPrimary = true, seatbeltRearRequired = true,

	bacLimit = 0.08, openContainerAllowed = false,

	schoolBusDividedException = "barrier",
	moveOverCoversDisabled = true, moveOverSlowdownMph = 20,
	jaywalkingEnforced = true, pedestrianDuty = "yield",

	keepRightEnforced = true, leftLanePassingOnly = true,
	hovMinimum = 2,

	chainLaws = false, chainLawSystem = "advisory",
	studdedTiresAllowed = true, studdedTireStartMonth = 10, studdedTireEndMonth = 5,  -- VERIFY per state
	wipersOnLightsOn = true,

	frontPlateRequired = true, inspectionRequired = true, emissionsRequired = true,
	tollSystem = "E-ZPass",

	cameraEnforcement = "banned",  -- ME and NH ban outright; MA/VT unsettled
	radarDetectorLegal = true, penaltySeverity = 3.5,

	exceptions = {
		-- The libertarian anomaly: no adult belt law at all, no helmet law, no cameras.
		-- Worth its own sub-zone -- it is the loosest enforcement in the country.
		NewHampshire = {
			seatbeltPrimary = false, seatbeltRearRequired = false,
			helmetRequired = "none", cameraEnforcement = "banned",
			speedLimitHighway = 70, penaltySeverity = 2,
		},
		Maine         = { speedLimitHighway = 75, speedLimitUrbanHighway = 75 },
		Vermont       = { speedLimitCity = 50, seatbeltPrimary = false },
		Massachusetts = { leftOnRedOneWayToOneWay = true, seatbeltPrimary = false },
	},
}

--------------------------------------------------------------------------------
Regions.midatlantic = {
	id = "midatlantic",
	name = "Mid-Atlantic",
	description = "Jughandles, dense tolling and the heaviest camera enforcement in the country.",
	drivingSide = "right", speedUnit = "mph",

	speedLimitHighway = 70, speedLimitUrbanHighway = 65,
	speedLimitCity = 55, speedLimitResidential = 25,
	speedLimitSchoolZone = 20, schoolZoneTrigger = "postedHours",
	speedDoctrine = "absolute",

	rightOnRed = true,  -- NYC and DC invert this -- see the sub-regions below
	leftOnRedOneWayToOneWay = true,  -- NY, PA, MD, DE allow; NJ and DC prohibit
	leftOnRedTwoWayToOneWay = false,
	uTurnAllowed = true,
	signatureManeuver = "Jersey jughandle",

	roundaboutEntryYields = true, roundaboutDensity = "some",
	bicycleStopAsYield = false, bicycleRedAsStop = false,

	helmetRequired = "all",  -- NY, NJ, MD, DC universal; PA under21, DE under19
	laneSplitting = false, laneFiltering = false, laneFilterMaxSpeed = 0,

	handheldPhoneBanned = true, handheldEnforcementPrimary = true, textingBanned = true,
	seatbeltPrimary = true, seatbeltRearRequired = true,

	bacLimit = 0.08, openContainerAllowed = false,

	schoolBusDividedException = "barrier",
	moveOverCoversDisabled = true, moveOverSlowdownMph = 20,
	jaywalkingEnforced = true, pedestrianDuty = "stop",

	keepRightEnforced = true, leftLanePassingOnly = true,
	hovMinimum = 3,  -- I-95/I-395 run HOV-3+, the strictest occupancy in the US

	chainLaws = false, chainLawSystem = "advisory",
	studdedTiresAllowed = true, studdedTireStartMonth = 11, studdedTireEndMonth = 4,  -- VERIFY
	wipersOnLightsOn = true,  -- NY is explicit that DRLs alone are NOT sufficient

	frontPlateRequired = true, inspectionRequired = true, emissionsRequired = true,
	tollSystem = "E-ZPass",

	cameraEnforcement = "pervasive",
	radarDetectorLegal = true, penaltySeverity = 5,

	exceptions = {
		-- Permissive on belts and plates, strictest in the region on school buses.
		Pennsylvania = {
			seatbeltPrimary = false, seatbeltRearRequired = false,
			frontPlateRequired = false, helmetRequired = "under21",
			schoolBusDividedException = "fiveLaneMinimum",
			cameraEnforcement = "limited",
		},
		NewJersey = {
			leftOnRedOneWayToOneWay = false,
			signatureManeuver = "Jughandle", cameraEnforcement = "none",
		},
		Delaware = {
			frontPlateRequired = false, openContainerAllowed = true,  -- VERIFY
			bicycleStopAsYield = true,  -- LIMITED: two-lane stop-sign junctions only
			helmetRequired = "under19",
		},
	},
}

--------------------------------------------------------------------------------
Regions.southeast = {
	id = "southeast",
	name = "Southeast",
	description = "Superstreets, beacon-timed school zones and criminal-tier speeding in Virginia.",
	drivingSide = "right", speedUnit = "mph",

	speedLimitHighway = 70, speedLimitUrbanHighway = 70,
	speedLimitCity = 60, speedLimitResidential = 25,
	speedLimitSchoolZone = 20, schoolZoneTrigger = "beacon",
	speedDoctrine = "absolute",

	rightOnRed = true, leftOnRedOneWayToOneWay = true, leftOnRedTwoWayToOneWay = false,
	uTurnAllowed = true,
	signatureManeuver = "Superstreet / RCUT",

	roundaboutEntryYields = true, roundaboutDensity = "some",
	bicycleStopAsYield = false, bicycleRedAsStop = false,

	helmetRequired = "all",  -- NC, GA, TN, VA universal; FL/KY/SC under21
	laneSplitting = false, laneFiltering = false, laneFilterMaxSpeed = 0,

	handheldPhoneBanned = true, handheldEnforcementPrimary = true, textingBanned = true,
	seatbeltPrimary = true, seatbeltRearRequired = true,

	bacLimit = 0.08, openContainerAllowed = false,

	schoolBusDividedException = "barrierOr5ftUnpaved",  -- the Florida model
	moveOverCoversDisabled = true, moveOverSlowdownMph = 20,
	jaywalkingEnforced = true, pedestrianDuty = "yield",

	keepRightEnforced = true, leftLanePassingOnly = true,
	hovMinimum = 2,

	chainLaws = false, chainLawSystem = "none",
	studdedTiresAllowed = false, studdedTireStartMonth = 0, studdedTireEndMonth = 0,
	wipersOnLightsOn = true,

	frontPlateRequired = false,  -- Virginia is the regional exception
	inspectionRequired = false, emissionsRequired = true,
	tollSystem = "Mixed (E-ZPass / SunPass / Peach Pass / NC Quick Pass)",

	cameraEnforcement = "limited",
	radarDetectorLegal = true,  -- VA repealed its ban 2022-07-01; DC is now the only ban
	penaltySeverity = 4,

	exceptions = {
		-- Reckless driving is a CRIMINAL misdemeanour at 20+ over or 85+ mph outright.
		-- The sharpest speeding cliff in the country and a strong region hook.
		Virginia = {
			frontPlateRequired = true, inspectionRequired = true,
			seatbeltPrimary = false, jaywalkingEnforced = false,
			recklessDrivingCriminal = true, recklessThresholdOver = 20, recklessAbsoluteMph = 85,
		},
		NorthCarolina = {
			leftOnRedOneWayToOneWay = false, signatureManeuver = "Superstreet",
			truckLeftLaneBanned = true, inspectionRequired = true,
		},
		Florida = {
			helmetRequired = "under21", helmetInsuranceExemption = true,
			tollSystem = "SunPass", inspectionRequired = false,
		},
		SouthCarolina = { cameraEnforcement = "banned", bicycleStopAsYield = true },  -- VERIFY
		Atlanta       = { rightOnRed = false },  -- downtown / midtown / Castleberry Hill
	},
}

--------------------------------------------------------------------------------
Regions.deepsouth = {
	id = "deepsouth",
	name = "Deep South",
	description = "Frontage-road turnarounds, minimal tolling and the loosest open-container laws in America.",
	drivingSide = "right", speedUnit = "mph",

	speedLimitHighway = 72, speedLimitUrbanHighway = 70,
	speedLimitCity = 65, speedLimitResidential = 25,
	speedLimitSchoolZone = 20, schoolZoneTrigger = "beacon",
	speedDoctrine = "absolute",

	rightOnRed = true, leftOnRedOneWayToOneWay = true, leftOnRedTwoWayToOneWay = false,
	uTurnAllowed = true,
	signatureManeuver = "Neutral-ground U-turn",

	roundaboutEntryYields = true, roundaboutDensity = "rare",
	bicycleStopAsYield = false, bicycleRedAsStop = false,

	helmetRequired = "all",  -- AL, MS, LA universal; AR under21
	laneSplitting = false, laneFiltering = false, laneFilterMaxSpeed = 0,

	handheldPhoneBanned = true,
	handheldEnforcementPrimary = false,  -- Alabama is secondary, 1 of only 2 states
	textingBanned = true,
	seatbeltPrimary = true, seatbeltRearRequired = false,

	bacLimit = 0.08,
	openContainerAllowed = true,  -- Mississippi lets even the DRIVER drink

	schoolBusDividedException = "barrier",
	moveOverCoversDisabled = true, moveOverSlowdownMph = 20,
	jaywalkingEnforced = true, pedestrianDuty = "halfRoadway",  -- the Louisiana model

	keepRightEnforced = true, leftLanePassingOnly = true,
	hovMinimum = 0,

	chainLaws = false, chainLawSystem = "none",
	studdedTiresAllowed = false, studdedTireStartMonth = 0, studdedTireEndMonth = 0,
	wipersOnLightsOn = true,

	frontPlateRequired = false, inspectionRequired = false, emissionsRequired = false,
	tollSystem = "None / minimal",

	cameraEnforcement = "limited",  -- MS bans outright while New Orleans is camera-heavy
	radarDetectorLegal = true, penaltySeverity = 2.5,

	exceptions = {
		Mississippi = { openContainerAllowed = true, driverMayDrink = true, cameraEnforcement = "banned" },
		-- A lidded frozen daiquiri with no straw in it is not an "open container".
		Louisiana   = { frozenDrinkExemption = true, inspectionRequired = true },
		Arkansas = {
			handheldPhoneBanned = false, handheldZoneOnly = true,  -- school and work zones only
			bicycleStopAsYield = true, bicycleRedAsStop = true,    -- the full Idaho stop
			helmetRequired = "under21", openContainerAllowed = true,  -- VERIFY
		},
		Alabama    = { handheldEnforcementPrimary = false },
		NewOrleans = { cameraEnforcement = "pervasive" },
	},
}

--------------------------------------------------------------------------------
Regions.midwest = {
	id = "midwest",
	name = "Midwest",
	description = "Michigan lefts, heavy roundabout adoption and not one universal helmet law.",
	drivingSide = "right", speedUnit = "mph",

	speedLimitHighway = 70, speedLimitUrbanHighway = 60,
	speedLimitCity = 55, speedLimitResidential = 25,
	speedLimitSchoolZone = 20, schoolZoneTrigger = "postedHours",
	speedDoctrine = "absolute",

	rightOnRed = true,
	leftOnRedOneWayToOneWay = true,
	leftOnRedTwoWayToOneWay = false,  -- Michigan allows it
	uTurnAllowed = true,
	signatureManeuver = "Michigan left (median U-turn)",

	roundaboutEntryYields = true, roundaboutDensity = "common",
	bicycleStopAsYield = false, bicycleRedAsStop = false,

	helmetRequired = "under18",  -- NO universal-helmet state anywhere in the Midwest
	laneSplitting = false, laneFiltering = false, laneFilterMaxSpeed = 0,

	handheldPhoneBanned = true,
	handheldEnforcementPrimary = true,  -- Missouri is secondary
	textingBanned = true,
	seatbeltPrimary = true, seatbeltRearRequired = true,

	bacLimit = 0.08, openContainerAllowed = false,

	schoolBusDividedException = "barrier",
	moveOverCoversDisabled = true, moveOverSlowdownMph = 20,
	jaywalkingEnforced = true, pedestrianDuty = "yield",

	keepRightEnforced = true, leftLanePassingOnly = true,
	hovMinimum = 2,

	chainLaws = false, chainLawSystem = "advisory",  -- ploughs and salt, not chains
	studdedTiresAllowed = false, studdedTireStartMonth = 0, studdedTireEndMonth = 0,  -- VERIFY: MI/MN/WI/IL restrict
	wipersOnLightsOn = true,

	frontPlateRequired = true,  -- IN, MI, OH do not require one
	inspectionRequired = false, emissionsRequired = true,
	tollSystem = "E-ZPass (I-PASS / Uni)",

	cameraEnforcement = "limited",  -- Chicago is the pervasive outlier
	radarDetectorLegal = true, penaltySeverity = 3,

	exceptions = {
		Michigan = {
			signatureManeuver = "Michigan left", leftOnRedTwoWayToOneWay = true,
			frontPlateRequired = false, seatbeltRearRequired = false,
			speedLimitHighway = 75, helmetRequired = "under21",
		},
		Illinois = { helmetRequired = "none", speedLimitUrbanHighway = 55, cameraEnforcement = "common" },
		Iowa     = { helmetRequired = "none", seatbeltRearRequired = false },
		Missouri = {
			handheldEnforcementPrimary = false, seatbeltPrimary = false,
			seatbeltRearRequired = false, helmetRequired = "under26",
			openContainerAllowed = true, inspectionRequired = true,
			signatureManeuver = "J-turn / diverging diamond",
		},
		-- The only Midwest state permitting either manoeuvre, and unusually detailed
		-- about where it does not apply.
		Minnesota = {
			laneSplitting = true, laneFiltering = true, laneFilterMaxSpeed = 15,
			laneSplitMaxSpeed = 25, laneSplitMaxDifferential = 15,
			pedestrianDuty = "stop", bicycleStopAsYield = true,  -- VERIFY
		},
		CarmelIndiana = { roundaboutDensity = "dominant", frontPlateRequired = false },
	},
}

--------------------------------------------------------------------------------
Regions.greatplains = {
	id = "greatplains",
	name = "Great Plains",
	description = "Fast, empty, barely enforced -- and they close the road rather than chain up.",
	drivingSide = "right", speedUnit = "mph",

	speedLimitHighway = 78, speedLimitUrbanHighway = 73,
	speedLimitCity = 67, speedLimitResidential = 25,
	speedLimitSchoolZone = 20, schoolZoneTrigger = "postedHours",
	speedDoctrine = "absolute",

	rightOnRed = true, leftOnRedOneWayToOneWay = true, leftOnRedTwoWayToOneWay = false,
	uTurnAllowed = true,
	signatureManeuver = "Uncontrolled rural section-line crossing",

	roundaboutEntryYields = true, roundaboutDensity = "rare",
	bicycleStopAsYield = true, bicycleRedAsStop = false,  -- ND and OK both have it

	helmetRequired = "under18",  -- none universal; Nebraska repealed its universal law
	laneSplitting = false, laneFiltering = false, laneFilterMaxSpeed = 0,

	handheldPhoneBanned = true, handheldEnforcementPrimary = true, textingBanned = true,
	seatbeltPrimary = false, seatbeltRearRequired = false,

	bacLimit = 0.08, openContainerAllowed = false,

	schoolBusDividedException = "barrier",
	moveOverCoversDisabled = true, moveOverSlowdownMph = 20,
	jaywalkingEnforced = true, pedestrianDuty = "yield",

	keepRightEnforced = true, leftLanePassingOnly = false,
	hovMinimum = 0,

	-- No chain law worth the name: in a blizzard the DOT closes the interstate outright
	-- rather than asking for traction devices. Model it as a closure event, not a check.
	chainLaws = false, chainLawSystem = "advisory",
	roadClosureInBlizzard = true,
	studdedTiresAllowed = true, studdedTireStartMonth = 10, studdedTireEndMonth = 4,  -- VERIFY
	wipersOnLightsOn = true,

	frontPlateRequired = true,  -- KS and OK do not require one
	inspectionRequired = false, emissionsRequired = false,
	tollSystem = "K-TAG / PikePass (interoperable with Texas, NOT E-ZPass)",

	cameraEnforcement = "none",
	radarDetectorLegal = true, penaltySeverity = 2,

	exceptions = {
		-- The only state posting 80 on URBAN interstate as well as rural.
		SouthDakota = {
			speedLimitHighway = 80, speedLimitUrbanHighway = 80,
			leftOnRedOneWayToOneWay = false, cameraEnforcement = "banned",
		},
		NorthDakota = { speedLimitHighway = 80, seatbeltPrimary = true, bicycleStopAsYield = true },
		Nebraska    = { helmetRequired = "under21" },
		Oklahoma    = { frontPlateRequired = false, bicycleStopAsYield = true, speedLimitCity = 70 },
		Kansas      = { frontPlateRequired = false, seatbeltPrimary = true, speedLimitUrbanHighway = 75 },
	},
}

--------------------------------------------------------------------------------
Regions.southwest = {
	id = "southwest",
	name = "Southwest",
	description = "Texas turnarounds, 85 mph tollways, no traffic cameras and dust-storm protocol.",
	drivingSide = "right", speedUnit = "mph",

	speedLimitHighway = 78, speedLimitUrbanHighway = 70,
	speedLimitCity = 70, speedLimitResidential = 25,
	speedLimitSchoolZone = 20, schoolZoneTrigger = "beacon",
	-- Texas posts PRIMA FACIE limits: exceeding one is evidence of unlawful speed, not
	-- the offence itself, so a driver may argue the speed was reasonable. Absolute
	-- regions have no such defence -- worth different ticket copy.
	speedDoctrine = "primaFacie",

	rightOnRed = true, leftOnRedOneWayToOneWay = true, leftOnRedTwoWayToOneWay = false,
	uTurnAllowed = true,
	signatureManeuver = "Texas turnaround (frontage-road U-turn)",

	roundaboutEntryYields = true, roundaboutDensity = "rare",
	bicycleStopAsYield = false, bicycleRedAsStop = false,

	helmetRequired = "under21",  -- Nevada is universal; AZ and NM are under18
	laneSplitting = false, laneFiltering = false, laneFilterMaxSpeed = 0,

	handheldPhoneBanned = true, handheldEnforcementPrimary = true, textingBanned = true,
	seatbeltPrimary = true, seatbeltRearRequired = true,

	bacLimit = 0.08, openContainerAllowed = false,

	schoolBusDividedException = "barrier",
	moveOverCoversDisabled = true, moveOverSlowdownMph = 20,
	jaywalkingEnforced = true, pedestrianDuty = "yield",

	keepRightEnforced = true, leftLanePassingOnly = false,
	hovMinimum = 2,

	chainLaws = false, chainLawSystem = "none",
	studdedTiresAllowed = true, studdedTireStartMonth = 0, studdedTireEndMonth = 0,  -- VERIFY
	wipersOnLightsOn = false,
	-- "Pull Aside, Stay Alive": pull fully off, lights OFF, foot off the brake, so
	-- following drivers cannot mistake your tail lights for the lane ahead.
	dustStormProtocol = true,

	frontPlateRequired = true,  -- AZ and NM do not require one
	inspectionRequired = false, -- TX ended non-commercial safety inspection 2025-01-01
	emissionsRequired = true,
	tollSystem = "TxTag / TollTag / EZ TAG (interoperable with OK and KS; not E-ZPass)",

	cameraEnforcement = "banned",  -- Texas bans BOTH speed and red-light cameras
	radarDetectorLegal = true, penaltySeverity = 2.5,

	exceptions = {
		Texas = {
			speedLimitHighway = 85,  -- SH-130 only; the highest posted limit in America
			speedLimitCity = 75, cameraEnforcement = "banned",
			helmetRequired = "under21", helmetInsuranceExemption = true,
			signatureManeuver = "Texas turnaround", laserJammerLegal = false,
		},
		Arizona = {
			laneFiltering = true, laneFilterMaxSpeed = 15, laneFilterMaxRoadLimit = 45,
			laneFilterRequiresStopped = true,
			frontPlateRequired = false, seatbeltPrimary = false, dustStormProtocol = true,
		},
		Nevada    = { speedLimitHighway = 80, helmetRequired = "all", jaywalkingEnforced = false, seatbeltPrimary = false },
		NewMexico = { speedLimitUrbanHighway = 75, speedLimitCity = 55, frontPlateRequired = false, helmetRequired = "under18" },
	},
}

--------------------------------------------------------------------------------
Regions.mountainwest = {
	id = "mountainwest",
	name = "Mountain West",
	description = "Coded traction laws, the original Idaho stop, and the only 0.05 BAC in America.",
	drivingSide = "right", speedUnit = "mph",

	speedLimitHighway = 77, speedLimitUrbanHighway = 68,
	speedLimitCity = 68, speedLimitResidential = 25,
	speedLimitSchoolZone = 20, schoolZoneTrigger = "beacon",
	speedDoctrine = "absolute",

	rightOnRed = true, leftOnRedOneWayToOneWay = true,
	leftOnRedTwoWayToOneWay = false,  -- Idaho allows it
	uTurnAllowed = true,
	signatureManeuver = "Continuous flow intersection",

	roundaboutEntryYields = true, roundaboutDensity = "some",
	bicycleStopAsYield = true, bicycleRedAsStop = true,  -- ID 1982 original; CO statewide 2022
	bicycleSafetyStopMinAge = 15, bicycleSafetyStopMaxSpeed = 10,

	helmetRequired = "under18",  -- none universal in the region; UT is under21
	laneSplitting = false,
	laneFiltering = true, laneFilterMaxSpeed = 15,  -- CO, UT, MT allow; WY and ID do not
	laneFilterRequiresStopped = true,

	handheldPhoneBanned = true,  -- Montana has NO statewide ban at all
	handheldEnforcementPrimary = true, textingBanned = true,
	seatbeltPrimary = false,  -- CO, MT, WY, ID all secondary; only UT is primary
	seatbeltRearRequired = true,

	bacLimit = 0.08,  -- Utah is 0.05
	openContainerAllowed = false,

	schoolBusDividedException = "barrier",
	moveOverCoversDisabled = true, moveOverSlowdownMph = 20,
	jaywalkingEnforced = true, pedestrianDuty = "yield",

	keepRightEnforced = true, leftLanePassingOnly = false,
	hovMinimum = 2,

	-- Colorado's Code 15 / Code 16 is the strongest region-identity lever found: a
	-- posted, coded, escalating requirement, and the fine multiplies if an unequipped
	-- vehicle actually blocks the highway.
	chainLaws = true, chainLawSystem = "codedTraction",
	tractionLawCode15Fine = 133,        -- $100 + $33 surcharge
	chainLawCode16BlockingFine = 657,   -- $500 + $157 surcharge
	tractionSeasonStartMonth = 9, tractionSeasonEndMonth = 5,
	minTreadDepthInches = 0.1875,       -- 3/16"
	studdedTiresAllowed = true, studdedTireStartMonth = 0, studdedTireEndMonth = 0,  -- CO: year-round
	wipersOnLightsOn = false,

	frontPlateRequired = true,  -- Utah dropped it 2025-01-01
	inspectionRequired = false, emissionsRequired = true,
	tollSystem = "ExpressToll (CO) / Utah Express Lanes; mostly untolled",

	cameraEnforcement = "limited",
	radarDetectorLegal = true, penaltySeverity = 3,

	exceptions = {
		Utah = {
			bacLimit = 0.05,  -- the ONLY state below 0.08
			seatbeltPrimary = true, frontPlateRequired = false, helmetRequired = "under21",
			laneFiltering = true, laneFilterMaxSpeed = 15, laneFilterMaxRoadLimit = 45,
			signatureManeuver = "Continuous flow intersection", laserJammerLegal = false,
		},
		-- The only state in the union with no texting ban; the big towns fill the gap
		-- with local ordinances, so enforcement is a city-limits check, not a state one.
		Montana = {
			speedLimitHighway = 80, truckSpeedLimitHighway = 70,
			handheldPhoneBanned = false, textingBanned = false,
			cameraEnforcement = "banned", laneFiltering = true, laneFilterMaxSpeed = 20,
		},
		Colorado = {
			chainLawSystem = "codedTraction",
			laneFiltering = true, laneFilterMaxSpeed = 15,
			laneFilteringSunsetDate = "2027-09-01",  -- SB24-079 auto-repeals unless renewed
			bicycleStopAsYield = true, bicycleRedAsStop = true,
			studdedTiresAllowed = true, studdedTireStartMonth = 0,
		},
		Idaho = {
			bicycleStopAsYield = true, bicycleRedAsStop = true,  -- the 1982 original
			leftOnRedTwoWayToOneWay = true, speedLimitHighway = 80,
			cameraEnforcement = "banned", laneFiltering = false,
		},
		Wyoming = { speedLimitHighway = 80, speedLimitUrbanHighway = 80, laneFiltering = false },
	},
}

--------------------------------------------------------------------------------
Regions.pacificwest = {
	id = "pacificwest",
	name = "Pacific West",
	description = "Lane splitting, coloured curbs, chain controls and no jaywalking offence.",
	drivingSide = "right", speedUnit = "mph",

	speedLimitHighway = 70, speedLimitUrbanHighway = 62,
	speedLimitCity = 63, speedLimitResidential = 25,
	speedLimitSchoolZone = 25, schoolZoneTrigger = "childrenPresent",
	-- California is presumed (prima facie) on surface streets but absolute on freeways.
	speedDoctrine = "mixed",

	rightOnRed = true,  -- Seattle bans it by default at rebuilt junctions
	leftOnRedOneWayToOneWay = true,
	leftOnRedTwoWayToOneWay = false,  -- Oregon and Washington both allow it
	uTurnAllowed = true,
	signatureManeuver = "Lane splitting",

	roundaboutEntryYields = true, roundaboutDensity = "common",
	bicycleStopAsYield = true, bicycleRedAsStop = false,  -- OR and WA yes; California NO

	helmetRequired = "all",  -- CA, OR, WA are all universal
	laneSplitting = false, laneFiltering = false, laneFilterMaxSpeed = 0,  -- California overrides

	handheldPhoneBanned = true, handheldEnforcementPrimary = true, textingBanned = true,
	seatbeltPrimary = true, seatbeltRearRequired = true,

	bacLimit = 0.08, openContainerAllowed = false,

	schoolBusDividedException = "barrier",
	moveOverCoversDisabled = true, moveOverSlowdownMph = 20,
	jaywalkingEnforced = false,  -- CA Freedom to Walk Act, effective 2023-01-01
	pedestrianDuty = "stop",

	keepRightEnforced = true, leftLanePassingOnly = false,
	-- Solo EV/clean-air HOV access is DEAD nationally: the federal authority behind it
	-- (23 U.S.C. s.166) expired 2025-09-30. Do not reinstate this as a perk.
	hovMinimum = 2,

	chainLaws = true, chainLawSystem = "rSystem",  -- California R-1 / R-2 / R-3
	studdedTiresAllowed = true, studdedTireStartMonth = 11, studdedTireEndMonth = 3,
	wipersOnLightsOn = true,  -- California yes; OR and WA are not on the list

	frontPlateRequired = true, inspectionRequired = false, emissionsRequired = true,
	tollSystem = "FasTrak (CA) / Good To Go! (WA) -- a separate island, no E-ZPass",

	cameraEnforcement = "common",
	radarDetectorLegal = true, penaltySeverity = 4,

	-- California's curb colour system. The only place in the US where kerb paint alone
	-- carries the full parking rule, so it is worth rendering rather than signing.
	curbColors = {
		red = "noStopping", yellow = "loadingCommercial", white = "passengerLoadingOnly",
		green = "timeLimitedPerSign", blue = "disabledOnly",
	},
	hillParkingGradePercent = 3,  -- CVC 22509: kerb the wheels above this grade

	exceptions = {
		California = {
			laneSplitting = true, laneFiltering = true, laneFilterMaxSpeed = 0,  -- no statutory cap
			-- CHP guidance, explicitly NOT law: split at most 10 mph faster than traffic,
			-- and not at all once traffic is over 30. Good NPC behaviour, bad ticket basis.
			laneSplitGuidanceDifferential = 10, laneSplitGuidanceMaxTraffic = 30,
			speedDoctrine = "primaFacie", jaywalkingEnforced = false,
			bicycleStopAsYield = false, tollSystem = "FasTrak", chainLawSystem = "rSystem",
		},
		Washington = {
			leftOnRedTwoWayToOneWay = true, bicycleStopAsYield = true,
			chainLawSystem = "tractionTire", spareChainsRequired = 2,
			emissionsRequired = false, tollSystem = "Good To Go!",
		},
		Oregon        = { leftOnRedTwoWayToOneWay = true, bicycleStopAsYield = true, tollSystem = "None" },
		SanFrancisco  = { hillParkingEnforced = true, hillParkingGradePercent = 3 },
		Seattle       = { rightOnRed = false },
	},
}

--------------------------------------------------------------------------------
Regions.alaska = {
	id = "alaska",
	name = "Alaska",
	description = "Gravel, moose and darkness. No tolls, no cameras, no front plate.",
	drivingSide = "right", speedUnit = "mph",

	speedLimitHighway = 65, speedLimitUrbanHighway = 55,
	speedLimitCity = 55, speedLimitResidential = 25,
	speedLimitSchoolZone = 20, schoolZoneTrigger = "postedHours",
	speedDoctrine = "absolute",

	rightOnRed = true, leftOnRedOneWayToOneWay = true,
	leftOnRedTwoWayToOneWay = true,  -- 1 of only 5 states permitting it
	uTurnAllowed = true,
	signatureManeuver = "Wilderness highway",

	roundaboutEntryYields = true, roundaboutDensity = "rare",
	bicycleStopAsYield = false, bicycleRedAsStop = false,

	helmetRequired = "under18",
	laneSplitting = false, laneFiltering = false, laneFilterMaxSpeed = 0,

	handheldPhoneBanned = true, handheldEnforcementPrimary = true, textingBanned = true,
	seatbeltPrimary = true, seatbeltRearRequired = true,

	bacLimit = 0.08, openContainerAllowed = false,

	schoolBusDividedException = "barrier",
	moveOverCoversDisabled = true, moveOverSlowdownMph = 20,
	jaywalkingEnforced = true, pedestrianDuty = "yield",

	keepRightEnforced = true, leftLanePassingOnly = false,
	hovMinimum = 0,

	chainLaws = true, chainLawSystem = "tractionTire",
	studdedTiresAllowed = true, studdedTireStartMonth = 9, studdedTireEndMonth = 4,  -- VERIFY
	wipersOnLightsOn = false,

	frontPlateRequired = false,  -- dropped 2022
	inspectionRequired = false, emissionsRequired = false,
	tollSystem = "None",

	cameraEnforcement = "none", radarDetectorLegal = true, penaltySeverity = 2,

	wildlifeHazard = "moose", gravelSurfaces = true, extremeDarkness = true,
	exceptions = {},
}

--------------------------------------------------------------------------------
Regions.hawaii = {
	id = "hawaii",
	name = "Hawaii",
	description = "The lowest speed limits in the United States and one-lane-bridge etiquette.",
	drivingSide = "right", speedUnit = "mph",

	speedLimitHighway = 60,  -- the LOWEST maximum in the country
	speedLimitUrbanHighway = 60,
	speedLimitCity = 45, speedLimitResidential = 25,
	speedLimitSchoolZone = 25, schoolZoneTrigger = "postedHours",
	speedDoctrine = "absolute",

	rightOnRed = true, leftOnRedOneWayToOneWay = true, leftOnRedTwoWayToOneWay = false,
	uTurnAllowed = true,
	signatureManeuver = "One-lane bridge yielding",

	roundaboutEntryYields = true, roundaboutDensity = "rare",
	bicycleStopAsYield = false, bicycleRedAsStop = false,

	helmetRequired = "under18",
	laneSplitting = false, laneFiltering = false, laneFilterMaxSpeed = 0,

	handheldPhoneBanned = true, handheldEnforcementPrimary = true, textingBanned = true,
	seatbeltPrimary = true, seatbeltRearRequired = true,

	bacLimit = 0.08, openContainerAllowed = false,

	schoolBusDividedException = "barrier",
	moveOverCoversDisabled = true, moveOverSlowdownMph = 20,  -- last state to adopt one, 2012
	jaywalkingEnforced = true, pedestrianDuty = "stop",

	keepRightEnforced = true, leftLanePassingOnly = false,
	hovMinimum = 2,

	chainLaws = false, chainLawSystem = "none",
	studdedTiresAllowed = false, studdedTireStartMonth = 0, studdedTireEndMonth = 0,
	wipersOnLightsOn = false,

	frontPlateRequired = true, inspectionRequired = true, emissionsRequired = false,
	tollSystem = "None",

	cameraEnforcement = "limited", radarDetectorLegal = true, penaltySeverity = 3,

	hornUseTaboo = true,  -- VERIFY: social rule, and reportedly codified
	exceptions = {},
}

--------------------------------------------------------------------------------
-- == Sub-regions ============================================================
-- NYC and DC are authored as PARTIAL overlays: they are Mid-Atlantic in every
-- respect except the handful of rules below, and both invert the national
-- right-on-red default -- the single most disorienting rule change in the game.

local SUBREGION_OVERLAYS: { [string]: { [string]: any } } = {
	nyc = {
		id = "nyc",
		name = "New York City",
		description = "No right on red anywhere, 25 mph streets, cameras on every block.",
		rightOnRed = false,  -- banned citywide since 1977 unless a sign says otherwise
		speedLimitCity = 25, speedLimitResidential = 25, speedLimitSchoolZone = 20,
		cameraEnforcement = "pervasive",  -- 750+ school-zone cameras, running 24/7
		jaywalkingEnforced = false,       -- Local Law 98 of 2024, effective 2025-06-26
		congestionPricing = true,
		congestionZoneName = "Congestion Relief Zone (at or below 60th St)",
		congestionTollPeak = 9.00, congestionTollOvernight = 2.25,
		alternateSideParking = true,
		penaltySeverity = 5,
	},
	dc = {
		id = "dc",
		name = "Washington, D.C.",
		description = "A full right-on-red ban, circles instead of junctions, and no radar detectors.",
		rightOnRed = false,  -- FULL ban effective 2025-01-01, with no signed exceptions
		leftOnRedOneWayToOneWay = false, leftOnRedTwoWayToOneWay = false,
		speedLimitCity = 25, speedLimitUrbanHighway = 55, speedLimitResidential = 25,
		signatureManeuver = "L'Enfant traffic circle",
		radarDetectorLegal = false,  -- the ONLY US jurisdiction banning them in cars
		cameraEnforcement = "pervasive",
		penaltySeverity = 5,
	},
}

-- Shallow merge, overlay wins. Used both to resolve the sub-regions at load and by
-- callers applying a per-state exception over a base region at runtime.
function RegionCatalog.applyOverlay(base: { [string]: any }, overlay: { [string]: any }): { [string]: any }
	local out = table.clone(base)
	for key, value in overlay do
		out[key] = value
	end
	return out
end

for id, overlay in SUBREGION_OVERLAYS do
	Regions[id] = RegionCatalog.applyOverlay(Regions.midatlantic, overlay)
end

-- Rule 12: every table here is immutable. table.freeze is SHALLOW, so the nested
-- exception tables and the odd inline map (curbColors) need freezing too, otherwise
-- a caller could mutate a region's exceptions through the frozen parent.
local function freezeRegion(region: { [string]: any })
	for _, value in region do
		if type(value) == "table" and not table.isfrozen(value) then
			freezeRegion(value)
		end
	end
	table.freeze(region)
end

for _, region in Regions do
	freezeRegion(region)
end

RegionCatalog.DEFAULT_ID = "midwest"

-- Picker order. Deliberately not alphabetical: it runs roughly east to west so the
-- map reads like a map, with the two sub-regions after their parent and the
-- non-contiguous pair last.
RegionCatalog.List = table.freeze({
	Regions.newengland,
	Regions.midatlantic,
	Regions.nyc,
	Regions.dc,
	Regions.southeast,
	Regions.deepsouth,
	Regions.midwest,
	Regions.greatplains,
	Regions.southwest,
	Regions.mountainwest,
	Regions.pacificwest,
	Regions.alaska,
	Regions.hawaii,
}) :: { RegionRuleset }

function RegionCatalog.get(id: string): RegionRuleset?
	return Regions[id]
end

-- Never nil, and takes `any`: this is what server code calls on a player-supplied id.
function RegionCatalog.getOrDefault(id: any): RegionRuleset
	local region = if type(id) == "string" then Regions[id] else nil
	return region or (Regions[RegionCatalog.DEFAULT_ID] :: RegionRuleset)
end

-- A region with one of its per-state/per-city exceptions merged over it. Unknown
-- exception names return the base region unchanged rather than erroring, so a save
-- naming a sub-zone that has since been removed still loads.
function RegionCatalog.withException(id: any, exceptionName: string?): RegionRuleset
	local region = RegionCatalog.getOrDefault(id)
	if not exceptionName then
		return region
	end
	local overlay = (region :: any).exceptions[exceptionName]
	if not overlay then
		return region
	end
	return RegionCatalog.applyOverlay(region :: any, overlay) :: RegionRuleset
end

return table.freeze(RegionCatalog)
