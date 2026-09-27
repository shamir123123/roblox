--!strict
-- Central icon registry. ONE place to define every button icon in the UI.
--
-- Each icon is an image asset id + a glyph fallback. Leave `image` empty ("")
-- and the glyph shows; paste an uploaded asset id into `image` and every button
-- that references this icon swaps to the art at once -- no hunting through
-- controllers. Glyphs are deliberately monochrome (no emoji): IconButton tints
-- them via ImageColor3 / TextColor3 so one set covers every state.
--
-- To add art: upload the PNG (white on transparent), then set
--   Roads = icon("\u{2550}", "rbxassetid://123456789"),
--
-- Usage:
--   local Icons = require(UI.Icons)
--   IconButton.new({ icon = Icons.Bulldoze, tooltip = "Bulldoze" })
-- or read the fields directly:
--   imageLabel.Image = Icons.Bulldoze.image
--   fallback.Text    = Icons.Bulldoze.glyph

export type Icon = { image: string, glyph: string }

local function icon(glyph: string, image: string?): Icon
	return { image = image or "", glyph = glyph }
end

local Icons = {
	-- Build categories (bottom bar) ---------------------------------------
	Roads          = icon("\u{2550}", "rbxassetid://126531094532679"),
	Zoning         = icon("\u{25A6}", "rbxassetid://83452350133769"),
	Buildings      = icon("\u{2302}", "rbxassetid://107196792219700"), -- house
	Infrastructure = icon("\u{2699}", "rbxassetid://139497881692582"), -- bolt (power/water)
	Services       = icon("\u{271A}", "rbxassetid://131715203908547"),
	Transport      = icon("\u{27A4}", "rbxassetid://84556241739674"), -- front-view bus
	Landscaping    = icon("\u{2663}", "rbxassetid://119445998341012"), -- foliage
	Terrain        = icon("\u{25B0}", "rbxassetid://121737141736727"),
	Population     = icon("\u{1F464}", "rbxassetid://102020284112870"), -- person / citizens
	Monument       = icon("\u{1F3DB}", "rbxassetid://112281352213667"), -- civic building / city emblem

	-- Global tools --------------------------------------------------------
	Bulldoze = icon("\u{2716}", "rbxassetid://117811273694023"),
	Move     = icon("\u{271B}", "rbxassetid://131559988084174"), -- open-centre cross: drag roads & intersections
	Undo     = icon("\u{27F2}", "rbxassetid://124506960895006"), -- counter-clockwise arrow
	Redo     = icon("\u{27F3}", "rbxassetid://90719299540401"), -- clockwise arrow

	-- Top HUD controls ----------------------------------------------------
	Dashboard = icon("\u{25A4}", "rbxassetid://115881808517916"), -- panel/chart
	Budget    = icon("$"),        -- treasury
	Menu      = icon("\u{2630}", "rbxassetid://76590088929870"), -- hamburger
	Save      = icon("\u{2913}", "rbxassetid://110402114266225"), -- arrow into bar
	-- Development Points. The ONE deliberately COLOURED icon in the registry: DP is a
	-- currency and has to be tellable apart from the white $ treasury glyph at a glance.
	-- Art: icons/out/dev_points.png (cyan gem). Consumers must leave ImageColor3 WHITE --
	-- tinting it the way IconButton tints the monochrome set would flatten the gem.
	DevPoints = icon("\u{2B21}"), -- hexagon; swap in the uploaded asset id here

	-- Generic / shared ----------------------------------------------------
	Close       = icon("\u{2715}", "rbxassetid://77440389864622"), -- X (dismiss panels)
	Lock        = icon("\u{1F512}", "rbxassetid://110613365809964"), -- padlock: locked/undeveloped build cards
	Settings    = icon("\u{2699}", "rbxassetid://139256453703868"), -- gear
	Plus        = icon("+"),
	Minus       = icon("\u{2212}"), -- true minus, not hyphen
	ChevronDown = icon("\u{25BE}"), -- dropdown caret
	Pause       = icon("\u{23F8}", "rbxassetid://108389522873507"),

	-- Sim speed: play / fast-forward chevrons (1x / 2x / 3x) ---------------
	Speed1      = icon("\u{25B6}", "rbxassetid://135870766760678"),
	Speed2      = icon("\u{25B6}", "rbxassetid://109922747079457"),
	Speed3      = icon("\u{25B6}", "rbxassetid://89915344090064"),

	-- Road draw modes (slab-tile set, CS2-style) ---------------------------
	RoadStraight   = icon("\u{2571}", "rbxassetid://109496466799637"),
	RoadCurved     = icon("\u{2935}", "rbxassetid://109558165041471"),
	RoadFreeform   = icon("\u{301C}", "rbxassetid://126197486789549"),
	RoadBezier     = icon("\u{223F}", "rbxassetid://98440073118469"),
	RoadRoundabout = icon("\u{27F3}", "rbxassetid://76807107480588"), -- circular direction
	RoadUpgrade    = icon("\u{21E7}", "rbxassetid://72361799526649"),
	RoadParallel   = icon("\u{2225}", "rbxassetid://121300509087106"), -- parallel lines
	Height         = icon("\u{2195}", "rbxassetid://78563678290084"), -- vertical elevation
	Snap           = icon("\u{2316}", "rbxassetid://111794092554177"), -- snap target

	-- Build rail: the shape builder's own settings, one button each ----------
	-- Art: icons/build/*.png, drawn by icons/IconMaker.py in the same ink rules as
	-- the rest of this registry (white plane, one muted accent, detail punched).
	BuildColour   = icon("\u{25D0}", "rbxassetid://93985396529057"), -- brush + the live colour
	SnapMove      = icon("\u{2194}", "rbxassetid://76659887221047"), -- lattice + horizontal arrow
	SnapSize      = icon("\u{2195}", "rbxassetid://102592699139017"), -- lattice + vertical arrow
	SnapRotate    = icon("\u{21BB}", "rbxassetid://138214667643294"), -- turn arrow + detents
	BuildPrecise  = icon("\u{2316}", "rbxassetid://128218559805219"), -- corner brackets on a point
	BuildRaise    = icon("\u{2191}", "rbxassetid://137315652341515"),
	BuildLower    = icon("\u{2193}", "rbxassetid://72951491657482"),
	BuildCollide  = icon("\u{25A3}", "rbxassetid://78896326303882"), -- two blocks passing through
	BuildMaterial = icon("\u{25A8}", "rbxassetid://78128466906046"), -- half-checkered swatch

	-- Zone paint tools ------------------------------------------------------
	ZoneBox   = icon("\u{25A1}", "rbxassetid://115952633024703"),
	ZoneFill  = icon("\u{25A7}", "rbxassetid://84547746525055"),
	ZonePaint = icon("\u{270E}", "rbxassetid://106317664133687"),
	ZoneErase = icon("\u{2715}", "rbxassetid://125775234028779"),

	-- Plot tool modes (glyph-only) ------------------------------------------
	PlotLine   = icon("\u{2015}", "rbxassetid://112092599935873"), -- paint along a road
	PlotArea   = icon("\u{2B21}", "rbxassetid://137768247225902"), -- node polygon outline
	PlotSingle = icon("\u{25CF}", "rbxassetid://108892278802317"), -- one building per click

	-- Terrain sculpt tools ---------------------------------------------------
	TerrainRaise   = icon("\u{25B2}", "rbxassetid://137705668963731"),
	TerrainLower   = icon("\u{25BD}", "rbxassetid://78489887488500"),
	TerrainFlatten = icon("\u{25AC}", "rbxassetid://109223040659076"),
	TerrainSmooth  = icon("\u{301C}", "rbxassetid://117651942176442"),
	TerrainLevel   = icon("\u{2500}", "rbxassetid://140326838784574"),
	TerrainPaint   = icon("\u{270E}", "rbxassetid://130312067626353"),

	-- Nature placement tools (rail icons on the Terrain dock's Nature tab) -----
	-- No uploaded art yet, so these are glyph-only (empty image string falls through
	-- to the glyph, same as RoadRoundabout/RoadParallel above).
	NatureSingle    = icon("\u{25CF}", "rbxassetid://110217805442495"), -- solid dot: one click, one plant
	NatureCurve     = icon("\u{2312}", "rbxassetid://140019137913995"), -- arc: the curved middle segment of the 3-click bend gesture
	NatureFreePlace = icon("\u{2726}", "rbxassetid://88405499880021"), -- 4-point sparkle: unconstrained single-click plant, skips the road/building proximity tint

	-- Zoning density / land use --------------------------------------------
	DensityLow    = icon("\u{2302}", "rbxassetid://76809288361676"),
	DensityMedium = icon("\u{2302}", "rbxassetid://125998542930657"),
	DensityHigh   = icon("\u{2302}", "rbxassetid://106188777686326"),
	DensityMixed  = icon("\u{2302}", "rbxassetid://72712738826825"),
	Park          = icon("\u{2663}", "rbxassetid://74216525889308"),
	Field         = icon("\u{2630}", "rbxassetid://120900929562079"),

	-- Centre banner stat chips (bottom bar) --------------------------------
	Citizens = icon("\u{1F464}", "rbxassetid://109971690373716"), -- population stat
	Treasury = icon("$", "rbxassetid://112630800385250"), -- treasury stat

	-- Info hub / dashboards -----------------------------------------------
	Info        = icon("\u{2139}", "rbxassetid://113491374237664"),
	Stats       = icon("\u{25A4}", "rbxassetid://106830722368187"),
	Economy     = icon("$", "rbxassetid://98251951289691"),
	LaneView    = icon("\u{2630}", "rbxassetid://116846918143218"),
	-- Signal controller. Glyph-only for now (no art uploaded): three stacked dots,
	-- the one shape that still reads as a signal head at 16px. Paste an asset id in
	-- when the art exists and every surface using it swaps at once.
	Signals     = icon("\u{22EE}"),
	InfoViews   = icon("\u{1F441}", "rbxassetid://87172980460317"),

	-- Info-view / heatmap modes -------------------------------------------
	-- Rendered by HeatmapController with colored=true, so these want FULL-COLOUR
	-- isometric PNGs (not white-on-transparent). Paste the asset id in and the
	-- tile swaps from the glyph to the art.
	ViewPolice    = icon("\u{1F6E1}"),  -- shield
	ViewFire      = icon("\u{1F525}"),  -- flame
	ViewHealth    = icon("\u{271A}"),   -- medical cross
	ViewEducation = icon("\u{1F393}"),  -- graduation cap
	ViewPower     = icon("\u{26A1}"),   -- bolt
	ViewWater     = icon("\u{1F4A7}"),  -- droplet
	ViewSewage    = icon("\u{223F}"),   -- flow / waves
	ViewDeathcare = icon("\u{271D}"),   -- latin cross

	-- Creation Editor (Studio-style dock UI) --------------------------------
	-- White-on-transparent PNGs generated by tools/generate_editor_icons.py;
	-- empty image falls back to the glyph until the upload id is pasted in.
	EditorSelect    = icon("\u{2196}", "rbxassetid://128981666826603"),  -- cursor arrow
	EditorMove      = icon("\u{271B}", "rbxassetid://86534725589866"),  -- four-way arrows
	EditorScale     = icon("\u{2922}", "rbxassetid://121416757960922"),  -- diagonal resize
	EditorRotate    = icon("\u{27F3}", "rbxassetid://121719013651092"),  -- circular arrow
	EditorTransform = icon("\u{2725}", "rbxassetid://102879554356775"),  -- combined handles
	EditorDuplicate = icon("\u{29C9}", "rbxassetid://140239245398826"),  -- two squares
	EditorDelete    = icon("\u{2716}", "rbxassetid://131064373922225"),  -- trash can
	EditorExplorer  = icon("\u{2261}", "rbxassetid://129060115769812"),  -- hierarchy tree
	EditorProps     = icon("\u{2632}", "rbxassetid://120564972245587"),  -- sliders
	EditorToolbox   = icon("\u{25A6}", "rbxassetid://125161785039908"),  -- toolbox
	ClassPart       = icon("\u{25AA}", "rbxassetid://75557756951924"),  -- Explorer tree: BasePart
	ClassModel      = icon("\u{25A3}", "rbxassetid://137803815050407"),  -- Explorer tree: Model
	ClassFolder     = icon("\u{25A2}", "rbxassetid://115896441089317"),  -- Explorer tree: Folder
}

-- Safe lookup by name. Returns nil for unknown keys instead of erroring, so a
-- typo in a controller degrades to "no icon" rather than a crash.
function Icons.get(name: string): Icon?
	local value = (Icons :: any)[name]
	if typeof(value) == "table" and typeof(value.glyph) == "string" then
		return value
	end
	return nil
end

-- Every distinct image id in the registry, for ContentProvider:PreloadAsync. Icons are
-- otherwise fetched lazily the first time a button mounts, and on a cold cache that
-- burst loses the race -- which is what leaves blank chips on slow clients.
function Icons.allImageIds(): { string }
	local ids, seen = {}, {}
	for _, v in pairs(Icons) do
		if typeof(v) == "table" and typeof(v.image) == "string" and v.image ~= "" and not seen[v.image] then
			seen[v.image] = true
			table.insert(ids, v.image)
		end
	end
	return ids
end

local function deepFreeze(t: { [any]: any })
	for _, v in t do
		if typeof(v) == "table" and not table.isfrozen(v) then
			deepFreeze(v)
		end
	end
	table.freeze(t)
end

deepFreeze(Icons)

return Icons
