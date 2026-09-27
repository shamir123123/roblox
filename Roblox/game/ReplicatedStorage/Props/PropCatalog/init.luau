--!strict
-- Shared street-prop catalog: placeable waste containers and seating. Templates live beside
-- this module in ReplicatedStorage.Props (one Model per key). Pure data.
--
-- WHY THESE ARE PART-BUILT AND NOT IMPORTED MESHES
-- ModelBaker.bakeMesh refuses mesh-backed models that are not foliage, and collect() calls
-- a model mesh-backed once MeshParts hold over half its volume. A bin imported as a mesh
-- would therefore get no FAR mesh and no DISTANT coarse mesh -- LODProxyCache would fall
-- through to an impostor and AssetLODView would flip it to a flat quad at 1000 studs. Built
-- from Parts instead, every kind bakes a real proxy and every instance of that kind
-- collapses into ONE draw call, which is the whole point of the ladder.
--
-- AUTHORING RULES THESE TEMPLATES ALREADY FOLLOW -- keep them if you add a bin
--   * 1 m = 2 studs (RoadConstants.WORLD_SCALE 0.5 => STUD_TO_METER 0.5).
--   * Base on Y=0, centred on X/Z, PrimaryPart.PivotOffset pulling the pivot to the
--     ground plane, so a placement service can PivotTo(groundY) with no fudge.
--   * A part whose LONGEST side is under 0.6 studs (300 mm) is dropped from the bake by
--     ModelBaker.MIN_FEATURE_STUDS, so it exists at NEAR/MID and in no proxy. That is
--     fine for wheels and hinges; it is fatal for anything carrying the silhouette.
--   * Keep the part count lean. The ladder does not collapse a prop to one draw call
--     until FAR (500 studs), and a city camera commonly sits at 100-300, so the NEAR
--     part count is what a dense street actually pays.

export type Entry = {
	key: string,
	name: string,
	kind: "Cart" | "Litter" | "Dumpster" | "Station" | "Compactor" | "Bench" | "Perch" | "Chair",
	minScale: number,
	maxScale: number,
	radius: number, -- placement footprint, studs
	tint: Color3,   -- swatch shown in the picker
	cost: number,
	-- Real-world envelope in mm (H, W, D), kept so a template can be checked against the
	-- product it was measured from rather than against whatever it drifted into.
	mm: { number },
}

local PropCatalog = {}

PropCatalog.order = {
	-- street furniture
	"CigaretteUrn",
	"WireMeshBasket",
	"StreetLitterBin",
	"ConcretePlazaBin",
	"DogWasteStation",
	-- residential / civic
	"WheelieCart96",
	"RecyclingStation",
	"SolarCompactor",
	"ClothingDonationBin",
	"BearResistantBin",
	-- commercial / industrial
	"GreaseCaddy",
	"RearLoadDumpster",
	"FrontLoadDumpster",
	"RollOffContainer",
	"SelfContainedCompactor",
	-- seating
	"BacklessSlattedBench",
	"VictorianParkBench",
	"MemorialBench",
	"PerforatedSteelBench",
	"TransitBenchCenterArmrest",
	"BoardwalkBench",
	"PrecastConcreteBench",
	"ArcPlazaBench",
	"RusticTimberBench",
	"PerchBar",
	-- single seats: plaza and park
	"BistroFoldingChair",
	"BryantParkChair",
	"WireCafeChair",
	"PlazaArmchairSteel",
	"AdirondackChair",
	-- single seats: transit and civic
	"TransitBucketSeat",
	"StadiumTipUpSeat",
	"AirportBeamChair",
	"WaitingRoomChair",
	"AccessibleArmchair",
	-- single seats: terrace and residential
	"PatioStackChair",
	"BarStoolOutdoor",
	"DirectorsChair",
	"RockingPorchChair",
	"DeckLoungeChair",
} :: { string }

PropCatalog.byKey = table.freeze({
	-- Victor Stanley Ironsites / Global Industrial bonnet bin. The vertical bars are
	-- TEXTURE, not geometry: a bar's longest side is its ~900 mm height, so modelled bars
	-- clear both LOD gates and would never cull.
	StreetLitterBin = table.freeze({
		key = "StreetLitterBin", name = "Litter Bin", kind = "Litter",
		minScale = 1, maxScale = 1, radius = 1,
		tint = Color3.fromRGB(61, 54, 53), cost = 90, mm = table.freeze({ 1029, 660, 660 }),
	}),
	WheelieCart96 = table.freeze({
		key = "WheelieCart96", name = "Roll-Out Cart", kind = "Cart",
		minScale = 0.95, maxScale = 1.05, radius = 1,
		tint = Color3.fromRGB(74, 78, 76), cost = 40, mm = table.freeze({ 1100, 755, 900 }),
	}),
	-- Depth is the 773 published WITH the handle, not the 681 cabinet: the handle is real
	-- geometry projecting 92 forward, so the bare cabinet figure would fail the envelope check.
	-- Composite: Busch Pavilion proportions (1124 x 479 x 962 body, 1054 x 203 header,
	-- 375 bay pitch) on a BearSaver CE340-style solid outdoor carcass. The envelope below
	-- is the as-built target, which is what the spec guards against drifting.
	RecyclingStation = table.freeze({
		key = "RecyclingStation", name = "Recycling Station", kind = "Station",
		minScale = 1, maxScale = 1, radius = 2,
		tint = Color3.fromRGB(0, 110, 185), cost = 320, mm = table.freeze({ 1293, 1150, 511 }),
	}),
	SolarCompactor = table.freeze({
		key = "SolarCompactor", name = "Solar Compactor", kind = "Compactor",
		minScale = 1, maxScale = 1, radius = 1,
		tint = Color3.fromRGB(61, 68, 71), cost = 900, mm = table.freeze({ 1264, 635, 773 }),
	}),
	-- Wastequip 6 yd flat-top: 1892 x 1740 body, 1581 overall. Width/depth below include
	-- the rim rail's 30 mm overhang, which is real geometry, not the bare body figure.
	FrontLoadDumpster = table.freeze({
		key = "FrontLoadDumpster", name = "Front-Load Dumpster", kind = "Dumpster",
		minScale = 1, maxScale = 1, radius = 3,
		tint = Color3.fromRGB(34, 74, 48), cost = 180, mm = table.freeze({ 1581, 1952, 1770 }),
	}),

	-- ---------------------------------------------------------------------------------
	-- SECOND SET. Unlike the five above, these envelopes are NOT taken from manufacturer
	-- spec sheets -- they are modelled from general knowledge of each object and are
	-- accurate to roughly the nearest 50-100 mm. Good enough to read correctly in a city;
	-- re-measure against a real datasheet before treating any figure here as authoritative.
	-- ---------------------------------------------------------------------------------
	CigaretteUrn = table.freeze({
		key = "CigaretteUrn", name = "Ash Urn", kind = "Litter",
		minScale = 1, maxScale = 1, radius = 1,
		tint = Color3.fromRGB(42, 42, 46), cost = 45, mm = table.freeze({ 970, 320, 320 }),
	}),
	WireMeshBasket = table.freeze({
		key = "WireMeshBasket", name = "Wire Basket", kind = "Litter",
		minScale = 1, maxScale = 1, radius = 1,
		tint = Color3.fromRGB(40, 66, 48), cost = 60, mm = table.freeze({ 790, 660, 660 }),
	}),
	ConcretePlazaBin = table.freeze({
		key = "ConcretePlazaBin", name = "Concrete Bin", kind = "Litter",
		minScale = 1, maxScale = 1, radius = 1,
		tint = Color3.fromRGB(176, 172, 164), cost = 140, mm = table.freeze({ 860, 680, 680 }),
	}),
	DogWasteStation = table.freeze({
		key = "DogWasteStation", name = "Dog Waste Station", kind = "Litter",
		minScale = 1, maxScale = 1, radius = 1,
		tint = Color3.fromRGB(46, 92, 52), cost = 110, mm = table.freeze({ 1720, 790, 410 }),
	}),
	ClothingDonationBin = table.freeze({
		key = "ClothingDonationBin", name = "Donation Bin", kind = "Station",
		minScale = 1, maxScale = 1, radius = 2,
		tint = Color3.fromRGB(206, 168, 48), cost = 260, mm = table.freeze({ 1830, 1220, 1300 }),
	}),
	BearResistantBin = table.freeze({
		key = "BearResistantBin", name = "Bear-Resistant Bin", kind = "Station",
		minScale = 1, maxScale = 1, radius = 2,
		tint = Color3.fromRGB(92, 68, 48), cost = 300, mm = table.freeze({ 1220, 985, 923 }),
	}),
	GreaseCaddy = table.freeze({
		key = "GreaseCaddy", name = "Grease Caddy", kind = "Cart",
		minScale = 1, maxScale = 1, radius = 1,
		tint = Color3.fromRGB(214, 176, 40), cost = 130, mm = table.freeze({ 1170, 1170, 798 }),
	}),
	RearLoadDumpster = table.freeze({
		key = "RearLoadDumpster", name = "Rear-Load Dumpster", kind = "Dumpster",
		minScale = 1, maxScale = 1, radius = 2,
		tint = Color3.fromRGB(34, 74, 48), cost = 150, mm = table.freeze({ 1340, 1900, 1335 }),
	}),
	RollOffContainer = table.freeze({
		key = "RollOffContainer", name = "Roll-Off Container", kind = "Dumpster",
		minScale = 1, maxScale = 1, radius = 7,
		tint = Color3.fromRGB(52, 74, 58), cost = 420, mm = table.freeze({ 1370, 6930, 2510 }),
	}),
	SelfContainedCompactor = table.freeze({
		key = "SelfContainedCompactor", name = "Self-Contained Compactor", kind = "Compactor",
		minScale = 1, maxScale = 1, radius = 6,
		tint = Color3.fromRGB(70, 74, 70), cost = 1400, mm = table.freeze({ 2350, 5925, 1890 }),
	}),

	-- ---------------------------------------------------------------------------------
	-- SEATING. Envelopes are manufacturer figures where a datasheet was reachable (Iron
	-- Valley 72in, Wabash Valley Signature Perforated with Victor Stanley RB-28 member
	-- sizes, Belson backless 6ft, Smith Steelworks bus stop bench, OCC Outdoors 6ft steel
	-- frame, Gaze Burvill Broadwalk BB1460, Streetlife Rough & Ready 5 and Solid 6, Larkin
	-- perch bench) and ergonomic estimates otherwise -- seat 400-460, back 750-900, a 6 ft
	-- bench 1830 long. Every template is within 12% of its source figure as built.
	--
	-- FOUR SHAPES HERE WERE DECIDED BY THE LOD LADDER, NOT BY THE PRODUCT
	--   * BoardwalkBench side frames are ONE 800 mm plate each, not a leg plus a back post.
	--     Split, both halves fall under AssetLODView.DETAIL_STUDS (750 mm), the frame blinks
	--     out at MID, and the slats are left floating in the air.
	--   * ArcPlazaBench is 3 chords per 60 deg module, not 4. A 4th chord smooths the curve
	--     but drops the inner ring slat to exactly 300 mm, where MIN_FEATURE_STUDS starts
	--     culling it out of the bake. 3 chords holds it at 332 mm for 17.5 mm of facet error,
	--     about 1.5% of the radius, which still reads as a curve.
	--   * PerchBar side plates are 760 mm -- deliberately 10 mm over the hide gate. Rounding
	--     them to a tidy 750 makes the perch plate float.
	--
	-- Armrests are the one feature that cannot be rescued, on any of these. Every real
	-- armrest measures 530-600 mm: clear of the 300 mm bake cut, under the 750 mm hide gate.
	-- So arms draw up close, vanish through MID, and come back inside the FAR proxy mesh.
	-- That is the ladder working as designed -- at 250 studs an armrest is about one pixel --
	-- and not something to fix by inflating geometry past its real size.
	-- ---------------------------------------------------------------------------------
	BacklessSlattedBench = table.freeze({
		key = "BacklessSlattedBench", name = "Backless Bench", kind = "Bench",
		minScale = 1, maxScale = 1, radius = 2,
		tint = Color3.fromRGB(150, 110, 75), cost = 120, mm = table.freeze({ 450, 1830, 560 }),
	}),
	-- The end frame carries the whole silhouette -- an S-curve from the scrolled arm down over
	-- a splayed front leg -- so it is one 815 mm part per side rather than a leg/stile pair
	-- that would both fall under the hide gate. The filigree is texture: at 12 mm of relief it
	-- survives nothing past close range.
	VictorianParkBench = table.freeze({
		key = "VictorianParkBench", name = "Victorian Park Bench", kind = "Bench",
		minScale = 1, maxScale = 1, radius = 2,
		tint = Color3.fromRGB(26, 54, 38), cost = 340, mm = table.freeze({ 815, 1830, 620 }),
	}),
	-- The plaque is 250 mm, so it drops out of the bake by design: it reads as a bright glint
	-- rather than a shape, and no part of the outline depends on it.
	--
	-- The side frame is ONE part per side, not the leg / apron / rear-post trio it was first
	-- built as. That trio could never earn a coarse rung, and not for the reason it looks like:
	-- the 76 mm leg is the smallest frame member, so ModelBaker.roles classifies it DETAIL and
	-- DROPS it before any merge is attempted, which leaves the apron and post to wrap the empty
	-- space between them at 0.585 waste against coarsen's 0.55 ceiling. An inverted-J side
	-- frame is a single bent piece in the real product anyway. Note the frame and the post share
	-- a 76 mm thickness on purpose: give them different thicknesses and their union grows along
	-- X, waste climbs back over the ceiling, and the merge is refused again.
	MemorialBench = table.freeze({
		key = "MemorialBench", name = "Memorial Bench", kind = "Bench",
		minScale = 1, maxScale = 1, radius = 2,
		tint = Color3.fromRGB(30, 30, 32), cost = 380, mm = table.freeze({ 820, 1829, 533 }),
	}),
	-- Perforation is TEXTURE, never geometry: real hole pitch is ~5 mm. Same reasoning as the
	-- vertical bars on StreetLitterBin, one gate further down.
	PerforatedSteelBench = table.freeze({
		key = "PerforatedSteelBench", name = "Perforated Steel Bench", kind = "Bench",
		minScale = 1, maxScale = 1, radius = 2,
		tint = Color3.fromRGB(28, 28, 28), cost = 260, mm = table.freeze({ 815, 1830, 530 }),
	}),
	-- Three armrests splitting the span into two ~760 mm seats is the entire reason this type
	-- exists, so the centre one is a single arm-plus-stem plate: at 560 mm it clears the bake
	-- cut and survives into the proxy, where two smaller members would not.
	TransitBenchCenterArmrest = table.freeze({
		key = "TransitBenchCenterArmrest", name = "Transit Bench", kind = "Bench",
		minScale = 1, maxScale = 1, radius = 2,
		tint = Color3.fromRGB(61, 50, 42), cost = 300, mm = table.freeze({ 965, 1830, 686 }),
	}),
	BoardwalkBench = table.freeze({
		key = "BoardwalkBench", name = "Boardwalk Bench", kind = "Bench",
		minScale = 1, maxScale = 1, radius = 3,
		tint = Color3.fromRGB(139, 87, 56), cost = 420, mm = table.freeze({ 800, 2340, 500 }),
	}),
	-- Three parts, on purpose: the design IS slab thickness, chamfer and plinth inset. The
	-- 110 mm shadow gap under the slab is what stops it reading as a curb, and the aggregate
	-- speckle belongs in the texture.
	PrecastConcreteBench = table.freeze({
		key = "PrecastConcreteBench", name = "Concrete Bench", kind = "Bench",
		minScale = 1, maxScale = 1, radius = 2,
		tint = Color3.fromRGB(168, 166, 160), cost = 220, mm = table.freeze({ 430, 1830, 480 }),
	}),
	-- One 60 deg module; six close a full circle around a tree. Width is the chord bounding
	-- box, not the arc length.
	ArcPlazaBench = table.freeze({
		key = "ArcPlazaBench", name = "Arc Plaza Bench", kind = "Bench",
		minScale = 1, maxScale = 1, radius = 2,
		tint = Color3.fromRGB(166, 152, 130), cost = 460, mm = table.freeze({ 450, 1500, 640 }),
	}),
	-- The beams stand ON EDGE. That 150 mm visible edge is the whole read; flattened to 40 mm
	-- slats this becomes a different, modern bench. The 34 mm gaps are what make it rustic.
	RusticTimberBench = table.freeze({
		key = "RusticTimberBench", name = "Timber Beam Bench", kind = "Bench",
		minScale = 1, maxScale = 1, radius = 3,
		tint = Color3.fromRGB(139, 87, 56), cost = 150, mm = table.freeze({ 450, 2340, 485 }),
	}),
	-- Not a seat, and it must not read as one: the 250 mm depth and the ~15 deg forward lean
	-- are what make it a lean rail. Flat reads as a shelf. Note the regional split -- European
	-- perches sit at 700-800, US ADA transit leaning rails at 813-914 and usually round tube.
	PerchBar = table.freeze({
		key = "PerchBar", name = "Perch Bar", kind = "Perch",
		minScale = 1, maxScale = 1, radius = 1,
		tint = Color3.fromRGB(77, 79, 81), cost = 130, mm = table.freeze({ 750, 1200, 250 }),
	}),

	-- ---------------------------------------------------------------------------------
	-- CHAIRS -- single seats, built by ServerStorage.Authoring.ChairBuilder rather than by
	-- hand. Envelopes are manufacturer figures wherever a datasheet was reachable (Fermob
	-- Luxembourg 4101 and Bistro 0101, POLYWOOD Classic Adirondack AD4030, EMU Round 465,
	-- Landscape Forms 21 Chair, American Seating InSight, Seatorium TOGAN 101, UFL AS202 with
	-- Rosehill Terminal, Hille E-Series, Bristol Maid Alderbury, Grosfillex Miami, ARB Teak
	-- Colorado LOU392, Cortina 29.5in barstool, Casual Home 18in director's, Serwall arch-top
	-- rocker) and ergonomic estimates otherwise. Each builder function names which of its
	-- figures are measured and which are estimated -- do not treat a number here as a product
	-- spec without checking there first.
	--
	-- WHY A CHAIR IS A HARDER LOD SUBJECT THAN A BENCH, which shaped all fifteen: a chair is
	-- the same HEIGHT as a bench but a THIRD of the WIDTH. A bench hides its legs at MID and
	-- still reads from its 1830 mm slats; a chair's slats are 400-630 mm and hide too. So on
	-- every chair here the rear leg and the back post are ONE part running floor to back-top,
	-- which is how the real products are made anyway, and which is usually the ONLY member
	-- over AssetLODView.DETAIL_STUDS. That member is therefore the entire mid-range
	-- silhouette, and because it reaches the ground, nothing is ever left floating.
	--
	-- Unlike the bins and benches, nothing in this set falls under MIN_FEATURE_STUDS at all:
	-- all fifteen keep 100% of their volume above the 300 mm bake gate, against the spec's 90%
	-- floor. Perforation, expanded-metal mesh, canvas weave and moulding ribs run 5-15 mm in
	-- reality, so they are texture -- as geometry each would be a part the bake silently drops.
	-- ---------------------------------------------------------------------------------
	BistroFoldingChair = table.freeze({
		key = "BistroFoldingChair", name = "Bistro Chair", kind = "Chair",
		minScale = 1, maxScale = 1, radius = 1,
		tint = Color3.fromRGB(168, 58, 48), cost = 120, mm = table.freeze({ 820, 420, 500 }),
	}),
	-- Seat height is the one figure no source settles: retail listings show both 490 and 455
	-- for model 4101 and no Fermob datasheet resolves it, so the seat is built at 460.
	BryantParkChair = table.freeze({
		key = "BryantParkChair", name = "Luxembourg Chair", kind = "Chair",
		minScale = 1, maxScale = 1, radius = 1,
		tint = Color3.fromRGB(98, 116, 84), cost = 260, mm = table.freeze({ 880, 520, 570 }),
	}),
	-- The stretched-steel mesh is TEXTURE on two flat panels. Real hole pitch is 10-15 mm; as
	-- geometry the lattice would be hundreds of sub-300 mm members, every one dropped by the
	-- bake -- an invisible chair past 500 studs that paid hundreds of draw calls to get there.
	WireCafeChair = table.freeze({
		key = "WireCafeChair", name = "Mesh Cafe Chair", kind = "Chair",
		minScale = 1, maxScale = 1, radius = 1,
		tint = Color3.fromRGB(226, 222, 212), cost = 90, mm = table.freeze({ 790, 630, 580 }),
	}),
	-- Slats are built at the frame's 50 mm rather than their real 35-40, because merge
	-- candidates must SHARE THEIR THICKNESS or the union grows and waste climbs back over
	-- coarsen's ceiling. 10 mm here is a fiftieth of a stud. The 21 Chair also ships in a
	-- single colour as standard, so one bucket is the authentic choice and not just the cheap one.
	PlazaArmchairSteel = table.freeze({
		key = "PlazaArmchairSteel", name = "Plaza Armchair", kind = "Chair",
		minScale = 1, maxScale = 1, radius = 1,
		tint = Color3.fromRGB(68, 70, 66), cost = 460, mm = table.freeze({ 832, 711, 648 }),
	}),
	-- Best LOD behaviour of all fifteen, and by construction: the seat runner and rear leg are
	-- one 808 mm board and the five back slats run DOWN PAST the seat to the lower rail at 758
	-- each -- both true to the real joinery, and between them SEVEN members clear DETAIL_STUDS
	-- where most chairs here clear two. Seat 390 front / 268 rear and back top 927 are outside
	-- the usual chair bands on purpose: an Adirondack is a low, steeply raked lounge chair and
	-- POLYWOOD's own measured seat height is 353.
	AdirondackChair = table.freeze({
		key = "AdirondackChair", name = "Adirondack Chair", kind = "Chair",
		minScale = 1, maxScale = 1, radius = 1,
		tint = Color3.fromRGB(152, 112, 74), cost = 180, mm = table.freeze({ 922, 732, 909 }),
	}),
	-- The pedestal is ONE 850 mm part running the floor up behind the pan as the back spine. A
	-- column stopping under the seat is ~430 mm, so at MID it would hide and leave the pan
	-- hanging over the platform.
	TransitBucketSeat = table.freeze({
		key = "TransitBucketSeat", name = "Platform Seat", kind = "Chair",
		minScale = 1, maxScale = 1, radius = 1,
		tint = Color3.fromRGB(46, 86, 108), cost = 85, mm = table.freeze({ 880, 470, 540 }),
	}),
	-- Y=0 IS THE TOP OF THE RISER TREAD, not the arena floor -- place this one on the step.
	-- Its foot bracket is thickened from the real 6 mm plate to the frame's 50 mm section: at
	-- 6 mm it would be a fiftieth of the bake gate and simply would not exist in the proxy.
	StadiumTipUpSeat = table.freeze({
		key = "StadiumTipUpSeat", name = "Tip-Up Seat", kind = "Chair",
		minScale = 1, maxScale = 1, radius = 1,
		tint = Color3.fromRGB(168, 46, 44), cost = 70, mm = table.freeze({ 815, 520, 600 }),
	}),
	-- ONE STATION of a beam run. The beam overhangs 90 mm past each seat edge on a 600 pitch,
	-- as a real end-of-run beam does; to butt two stations into a row, overlap by 180 mm.
	AirportBeamChair = table.freeze({
		key = "AirportBeamChair", name = "Terminal Beam Seat", kind = "Chair",
		minScale = 1, maxScale = 1, radius = 1,
		tint = Color3.fromRGB(44, 52, 66), cost = 180, mm = table.freeze({ 810, 780, 650 }),
	}),
	-- Weakest mid read in the set: only 8.5% of its volume sits in the two members over
	-- DETAIL_STUDS, so past 250 studs it is two thin uprights on the ground. Nothing floats.
	-- The lever, if a waiting room full of them reads badly, is widening the uprights in X --
	-- they stay one bucket and one thickness in Z, so the merge is unaffected.
	WaitingRoomChair = table.freeze({
		key = "WaitingRoomChair", name = "Stacking Chair", kind = "Chair",
		minScale = 1, maxScale = 1, radius = 1,
		tint = Color3.fromRGB(92, 104, 118), cost = 60, mm = table.freeze({ 800, 470, 500 }),
	}),
	-- HEIGHT IS A DELIBERATE TRIM, NOT A MEASUREMENT. Real high-back accessible armchairs are
	-- 1195-1220 -- that height IS the type, head support for someone who cannot rise unaided --
	-- but at 1195 it reads as a throne beside every other chair in the library, so it is built
	-- at 1010 and the figure below is as-built. Do not cite it as a product spec.
	AccessibleArmchair = table.freeze({
		key = "AccessibleArmchair", name = "Accessible Armchair", kind = "Chair",
		minScale = 1, maxScale = 1, radius = 1,
		tint = Color3.fromRGB(78, 98, 96), cost = 240, mm = table.freeze({ 1010, 660, 670 }),
	}),
	PatioStackChair = table.freeze({
		key = "PatioStackChair", name = "Stacking Patio Chair", kind = "Chair",
		minScale = 1, maxScale = 1, radius = 1,
		tint = Color3.fromRGB(236, 233, 224), cost = 55, mm = table.freeze({ 810, 536, 560 }),
	}),
	-- KNOWN LOSS WITH NO GEOMETRIC FIX: the seat slab is 440 mm, so the seat -- the entire
	-- point of a stool -- hides at MID. A 440 mm seat cannot be made 750. The stiles run
	-- floor-to-top so nothing floats, but a parklet of these reads as skeletons in the mid
	-- band; the lever is the LOD threshold for this prop, not the model.
	BarStoolOutdoor = table.freeze({
		key = "BarStoolOutdoor", name = "Parklet Stool", kind = "Chair",
		minScale = 1, maxScale = 1, radius = 1,
		tint = Color3.fromRGB(74, 78, 80), cost = 180, mm = table.freeze({ 1150, 440, 510 }),
	}),
	-- The one place in the set where silhouette fidelity was traded for LOD survival. A true
	-- see-through X needs the front leg's top at the seat REAR and the rear leg's top at the
	-- seat FRONT, so neither leg can also be the back stile -- every honest split leaves the
	-- tallest member at ~650 mm, and the whole chair would pop out of existence at MID. The
	-- side is therefore one 36 mm plate: a blade from every angle but dead-side, with the X
	-- restored in near field by four proud ribs and the void belonging in the side texture.
	DirectorsChair = table.freeze({
		key = "DirectorsChair", name = "Director's Chair", kind = "Chair",
		minScale = 1, maxScale = 1, radius = 1,
		tint = Color3.fromRGB(198, 158, 108), cost = 95, mm = table.freeze({ 855, 540, 545 }),
	}),
	-- Rockers are three straight segments per runner, not a curve -- 340/341/341 puts every
	-- one 40 mm clear of the bake gate, the same reasoning that made ArcPlazaBench 3 chords
	-- rather than 4. Consequence worth knowing: the middle facet gives 340 mm of FLAT ground
	-- contact instead of a point, so the chair sits dead still. Right for a static prop.
	RockingPorchChair = table.freeze({
		key = "RockingPorchChair", name = "Porch Rocker", kind = "Chair",
		minScale = 1, maxScale = 1, radius = 1,
		tint = Color3.fromRGB(156, 96, 66), cost = 140, mm = table.freeze({ 1050, 640, 890 }),
	}),
	-- Coarsens better than anything else in the library: nine parallel same-colour slats
	-- sharing a thickness merge at roughly 8% waste, and the side frames clear DETAIL_STUDS
	-- outright at 1205, so this is the one chair that never loses its silhouette at any range.
	-- The trade is the open splayed-leg look of a classic steamer, taken knowingly. The
	-- head-end wheel is omitted rather than modelled badly -- a real one is 150-200 mm, under
	-- the bake gate, so it would be deleted anyway.
	DeckLoungeChair = table.freeze({
		key = "DeckLoungeChair", name = "Steamer Lounger", kind = "Chair",
		minScale = 1, maxScale = 1, radius = 2,
		tint = Color3.fromRGB(166, 130, 92), cost = 320, mm = table.freeze({ 900, 620, 1550 }),
	}),
}) :: { [string]: Entry }

-- Municipal cart colours. Source: California SB 1383 / 14 CCR 18984.7 and CalRecycle's
-- standardized container colour guidance -- the only binding US cart colour standard, and
-- the one other programs have converged on. The rule is satisfied either by a body in the
-- stream colour or by a stream-coloured LID on a grey or black body, which is why each
-- stream carries both.
PropCatalog.stream = table.freeze({
	Refuse    = table.freeze({ body = Color3.fromRGB(74, 78, 76),  lid = Color3.fromRGB(48, 50, 49) }),
	Recycling = table.freeze({ body = Color3.fromRGB(30, 68, 128), lid = Color3.fromRGB(42, 92, 160) }),
	Organics  = table.freeze({ body = Color3.fromRGB(46, 92, 52),  lid = Color3.fromRGB(40, 80, 46) }),
	YardWaste = table.freeze({ body = Color3.fromRGB(74, 54, 40),  lid = Color3.fromRGB(74, 54, 40) }),
})

function PropCatalog.get(key: string): Entry?
	return PropCatalog.byKey[key]
end

return PropCatalog
