--!strict
-- ============================================================================
--  THE UPDATE LOG. This is the file you edit.
-- ============================================================================
--
--  TO ADD A RELEASE: copy the block below to the TOP of `versions`. The top one
--  is automatically the newest and gets the LATEST badge -- nothing else to
--  change, and no flag to remember to clear on the old one.
--
--      Log.version("0.4.1", "2 Aug 2026", "Bridges")
--          :added("Suspension bridges over any water body.", "ROADS")
--          :changed("Elevation steps are 4 m instead of 5 m.")
--          :fixed("Ramps could detach from the highway they joined."),
--
--  version(number, date, title)
--      The number is stored without a "v". The date is a display string, so
--      write it how you want it read. The title is the heading on the page.
--
--  :added(text)  :changed(text)  :fixed(text)
--      One line of notes. Call any of them as many times as you like -- repeats
--      join the same heading, and the three always render in ADDED, CHANGED,
--      FIXED order however you wrote them.
--
--  :added(text, "ROADS")
--      The optional second argument is a chip on the right of the line. Use it
--      to say which part of the game a line belongs to (ROADS, HUD, INPUT...).
--
--  :group("PERFORMANCE", { "line", "line" })
--      A heading of your own, for when the three standard ones do not fit.
--      Renders after ADDED / CHANGED / FIXED, in the order you declare them.
--
--  :latest(false)
--      Only if you need the badge somewhere other than the top entry.
--
--  Mistakes -- an empty line, two releases with the same number, a release with
--  no notes -- throw the moment the game loads, naming the release, rather than
--  showing a broken page.
--
--  The menu's build stamp reads Versions[1].version, so shipping a release here
--  is what updates the version shown on the main menu.
-- ============================================================================

local Log = require(script.Parent:WaitForChild("UpdateLogBuilder"))

export type Item = Log.Item
export type Group = Log.Group
export type Version = Log.Version
export type Credit = Log.Credit

return Log.compile({

	-- ==================== RELEASES -- newest first ====================
	versions = {
		Log.version("0.4.3", "14 Sep 2026", "Roads, parking and wind turbines")
			:added("Wind turbines now have a texture.", "POWER")
			:changed("Maximum active cars increased from 500 to 5,000.", "TRAFFIC")
			:fixed("Road meshes could fail to fill correctly around corners.", "ROADS")
			:fixed("Wind turbines could be placed on intersections.", "POWER")
			:fixed("Parking lots could appear in the Nature tab.", "PARKING")
			:fixed("Some meshes would occasionally fail to render.", "RENDERING")
			:fixed("Alleys with sidewalks could not be placed.", "ROADS")
			:fixed("Roads could have visible gaps after placement.", "ROADS")
			:fixed("Terrain under roads could rise after rejoining the game.", "TERRAIN"),
		
		Log.version("0.4.22", "11 Sep 2026", "Roads and street details")
			:added("Road decorations: manhole covers, fire hydrants, electrical boxes and street signs.", "ROADS")
			:changed("Road geometry and road meshes have been improved.", "ROADS")
			:fixed("Parked cars could appear in front of houses instead of in their parking lots.", "PARKING"),
		
		Log.version("0.4.21", "10 Sep 2026", "Power, parking and zoning fixes")
			:added("Houses are abandoned when they lose what they need to stay lived in.", "BUILDINGS")
			:added("An icon appears above a traffic jam so you can spot one from anywhere.", "TRAFFIC")
			:changed("Electricity system improvements.", "POWER")
			:changed("Parking system improvements.", "PARKING")
			:fixed("Adding a road, or nudging one, could dezone everything around it.", "ZONING")
			:fixed("Connecting a new road to an existing one rebuilt the building models on that road's zones.", "ZONING"),

		Log.version("0.4.2", "10 Sep 2026", "Electricity")
			:added("Electrical system \u{2014} wind turbines, power poles and drawn power lines. A building needs a pole in range or it goes dark and is abandoned.", "POWER")
			:changed("Houses hold more households as they level up.", "BUILDINGS")
			:changed("Cars can change lanes.", "TRAFFIC")
			:fixed("Cars sometimes failed to spawn or bugged out mid-route.", "TRAFFIC"),

		Log.version("0.4.1", "6 Sep 2026", "Closed beta begins")
			:added("Closed beta testing starts today \u{2014} the game is open to invited testers.", "BETA"),
			

		-- Notes not written yet. A release with no notes throws at load, so these
		-- stay commented out until each has at least one :added()/:changed()/:fixed().
		-- Log.version("0.3.2", "12 Jul 2026", "Stability pass"),
		-- Log.version("0.3.0", "28 Jun 2026", "Transit lines"),
		-- Log.version("0.2.5", "09 Jun 2026", "Terrain tools"),
		-- Log.version("0.1.0", "17 May 2026", "First sandbox build"),
	},

	-- ==================== CREDITS ====================
	-- section(index name, line under it, heading on the page), then a :group()
	-- per block of names.
	-- Blank on purpose: the page renders an empty CREDITS tab until the real names go in.
	credits = {},
})
