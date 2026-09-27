--!strict
-- WorldThemeCatalog
-- The CONTINENT tier: which country's road and building conventions the whole city is
-- built to. Pure data + lookup -- no state, no lifecycle, no side effects on require, and
-- deliberately NO dependencies, so the lowest-level modules (RoadConstants) can read it
-- without creating a cycle.
--
-- == The three tiers ========================================================
--
--   1. WorldTheme -- this module.        usa / europe / africa / asia
--        The PHYSICAL and VISUAL layer. Unit system, marking colours and patterns, sign
--        family, signal placement and sequence, lane widths, and which building
--        architecture pack the templates come from.
--
--        NOT the side of the road. That is a player setting and belongs to no theme --
--        RoadRules owns it outright. A player may build an American city that drives on
--        the left, and nothing here may override that.
--
--   2. Region -- RegionCatalog.          newengland / midwest / pacificwest / nyc / dc ...
--        The LEGAL layer INSIDE one theme. Speed limits, right on red, helmet law, chain
--        law, enforcement style. A theme names its region pack in `regionPack` below.
--
--   3. District style -- not built yet.  a per-zone architecture override
--        Paint one district with another theme's buildings while the roads stay the
--        city's own. `architectureStyle` is the field such an override would replace.
--
-- == How this differs from Cities: Skylines =================================
-- CS2 ships a North American and a European theme, plus regional building packs (Japan,
-- UK, East/West-coast USA, China, France, East Europe, Germany), and CS1 had District
-- Styles. In both, the theme is chosen at city creation, cannot be changed afterwards,
-- and is PURELY COSMETIC -- it moves street markings, signal models, service vehicles and
-- architecture, and changes no rule.
--
-- Ours goes further on purpose: a theme also decides what a broken line means, whether a
-- signal sits near-side or far-side, and which legal region pack applies. That is the
-- whole point of tier 2 -- CS has nothing like it.
--
-- The one thing we copy exactly is immutability. A theme is fixed for a city's lifetime
-- because lane offsets are baked into the nav graph and building footprints into their
-- plots; swapping live would mean rebuilding both.
--
-- == Status =================================================================
-- ONLY "usa" is authored. The other three are declared with `implemented = false` so the
-- picker can show them disabled and so the shape of a second theme is on record. Their
-- unknown fields are left nil rather than guessed -- a wrong value that looks authored is
-- worse than an obvious hole. Do not let a caller select one until its fields are filled
-- in AND its building templates exist.

local WorldThemeCatalog = {}

-- "mutcd"  US: yellow separates opposing directions and marks the left edge; white
--          separates same-direction traffic and marks the right edge.
-- "vienna" Vienna Convention (most of Europe, and most of the world): white does BOTH
--          jobs, and yellow means a restriction or temporary works.
export type MarkingSystem = "mutcd" | "vienna"
export type SignSystem   = "mutcd" | "vienna"

-- Far-side is the US pattern (MUTCD 4D.05: primary faces beyond the intersection).
-- Near-side, at the stop line, is the UK/Ireland pattern.
export type SignalPlacement = "farSide" | "nearSide"

-- "greenYellowRed"      US: no red+amber before green.
-- "greenYellowRedAmber" UK/DE/PL and others: a red+amber "about to go" phase.
export type SignalSequence = "greenYellowRed" | "greenYellowRedAmber"

export type WorldTheme = {
	id: string,
	name: string,
	description: string,
	-- false = declared, not authored. The picker must refuse it.
	implemented: boolean,

	-- == Road physical layer ==================================================
	-- No drivingSide field, by design -- see the header. RoadRules owns it.
	speedUnit: ("mph" | "kmh")?,

	markingSystem: MarkingSystem?,
	-- Authored as raw Color3 rather than pulled from RoadConstants: the dependency runs
	-- the other way (RoadConstants reads the active theme), so this module must not
	-- require it.
	markingWhite: Color3?,
	-- The colour that separates OPPOSING directions. nil under "vienna", where white does
	-- that job and there is no second line colour.
	markingOpposing: Color3?,
	-- Broken-line cycle in FEET. The ratio matters more than the absolute length: 1:3 reads
	-- American, 1:1 reads continental.
	dashLineFeet: number?,
	dashGapFeet: number?,

	signSystem: SignSystem?,
	signalPlacement: SignalPlacement?,
	signalSequence: SignalSequence?,
	-- Whether a nearside turn on red is allowed by default. A per-junction sign, and a
	-- region's own rule, still override it.
	turnOnRedDefault: boolean?,

	-- Typical lane width in FEET by functional class. Road widths are authored in the
	-- catalog in studs; these are the real-world targets those widths represent.
	laneWidthFeet: { freeway: number, arterial: number, collector: number, localStreet: number }?,

	-- == Buildings ============================================================
	-- Sub-folder under ServerStorage.Templates.Buildings holding this theme's architecture.
	-- BuildingService falls back to the un-styled layout when the folder is absent, so a
	-- theme may name a pack that has not been built yet without breaking the game.
	architectureStyle: string?,

	-- == Rules ================================================================
	-- Name of the ModuleScript under ReplicatedStorage.Road holding this theme's legal
	-- sub-regions (tier 2). nil = the theme has no sub-region pack yet.
	regionPack: string?,
}

local Themes: { [string]: WorldTheme } = {}

--------------------------------------------------------------------------------
Themes.usa = {
	id = "usa",
	name = "United States",
	description = "Right-hand traffic, yellow centre lines, far-side signals and turn on red.",
	implemented = true,

	speedUnit = "mph",

	markingSystem = "mutcd",
	markingWhite = Color3.fromRGB(245, 245, 245),
	markingOpposing = Color3.fromRGB(235, 200, 90),
	dashLineFeet = 10,  -- MUTCD 11th Ed. 3A.04: 10 ft line, 30 ft gap, 40 ft cycle
	dashGapFeet = 30,

	signSystem = "mutcd",
	signalPlacement = "farSide",
	signalSequence = "greenYellowRed",
	turnOnRedDefault = true,

	laneWidthFeet = { freeway = 12, arterial = 11, collector = 11, localStreet = 10 },

	architectureStyle = "NorthAmerican",
	regionPack = "RegionCatalog",
}

--------------------------------------------------------------------------------
-- The three below are PLACEHOLDERS. Fields are nil where the honest answer is "it
-- varies and nobody has decided yet" -- fill them in when the theme is actually built,
-- and add a region pack (tier 2) at the same time.

Themes.europe = {
	id = "europe",
	name = "Europe",
	description = "White centre lines, metric signs, near-side signals in the British Isles.",
	implemented = false,

	speedUnit = "kmh",  -- except the UK and Ireland, which post mph

	markingSystem = "vienna",
	markingWhite = Color3.fromRGB(245, 245, 245),
	markingOpposing = nil,  -- Vienna: white separates opposing traffic too
	dashLineFeet = nil,     -- varies by country and by road class
	dashGapFeet = nil,

	signSystem = "vienna",
	signalPlacement = nil,  -- near-side in the British Isles, far-side in much of the rest
	signalSequence = nil,   -- red+amber in the UK, Germany and Poland; not in France
	turnOnRedDefault = false,  -- broadly true across Europe; Germany's green-arrow plate is the exception

	laneWidthFeet = nil,
	architectureStyle = "European",
	regionPack = nil,
}

Themes.africa = {
	id = "africa",
	name = "Africa",
	description = "Not yet authored.",
	implemented = false,
	speedUnit = nil,
	markingSystem = nil, markingWhite = nil, markingOpposing = nil,
	dashLineFeet = nil, dashGapFeet = nil,
	signSystem = nil, signalPlacement = nil, signalSequence = nil, turnOnRedDefault = nil,
	laneWidthFeet = nil, architectureStyle = "African", regionPack = nil,
}

Themes.asia = {
	id = "asia",
	name = "Asia",
	description = "Not yet authored.",
	implemented = false,
	speedUnit = nil,
	markingSystem = nil, markingWhite = nil, markingOpposing = nil,
	dashLineFeet = nil, dashGapFeet = nil,
	signSystem = nil, signalPlacement = nil, signalSequence = nil, turnOnRedDefault = nil,
	laneWidthFeet = nil, architectureStyle = "Asian", regionPack = nil,
}

--------------------------------------------------------------------------------
-- Rule 12: every table here is immutable, and table.freeze is shallow, so the nested
-- laneWidthFeet map needs freezing too.
local function freezeTheme(theme: any)
	for _, value in theme do
		if type(value) == "table" and not table.isfrozen(value) then
			table.freeze(value)
		end
	end
	table.freeze(theme)
end

for _, theme in Themes do
	freezeTheme(theme)
end

WorldThemeCatalog.DEFAULT_ID = "usa"

-- The theme this world is built to. A load-time constant, exactly like the driving side it
-- feeds: RoadConstants reads it while the road modules are still loading, and the nav graph
-- and every building footprint are baked from it afterwards.
--
-- ponytail: per-city THEMES. The driving side that used to be stuck here with them is
-- now live -- CitySlotService applies the city's saved side on load and RoadRules
-- rebuilds the nav graph and repaints off it. The theme has not followed because it also
-- re-seats every plot, which the side never touches.
WorldThemeCatalog.ACTIVE_ID = "usa"

-- Picker order. Authored themes first so the one playable option leads.
WorldThemeCatalog.List = table.freeze({
	Themes.usa,
	Themes.europe,
	Themes.africa,
	Themes.asia,
}) :: { WorldTheme }

function WorldThemeCatalog.get(id: string): WorldTheme?
	return Themes[id]
end

-- Never nil, and takes `any`: safe on a player-supplied id.
function WorldThemeCatalog.getOrDefault(id: any): WorldTheme
	local theme = if type(id) == "string" then Themes[id] else nil
	return theme or (Themes[WorldThemeCatalog.DEFAULT_ID] :: WorldTheme)
end

-- The theme the world is currently built to.
function WorldThemeCatalog.active(): WorldTheme
	return WorldThemeCatalog.getOrDefault(WorldThemeCatalog.ACTIVE_ID)
end

-- Guard for anything that lets a player choose: an unauthored theme must never be applied.
function WorldThemeCatalog.isSelectable(id: any): boolean
	local theme = if type(id) == "string" then Themes[id] else nil
	return theme ~= nil and theme.implemented == true
end

return table.freeze(WorldThemeCatalog)
