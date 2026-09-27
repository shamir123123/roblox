--!strict
-- TextureAverages -- the average colour of every image the world draws, precomputed.
--
-- A building's colour mostly does NOT live in Part.Color. The walls are off-white parts
-- wearing a tiling Texture, so a sage clapboard house and a red brick house differ only in
-- which image is stapled to the same cream box. Anything that has to represent a building
-- WITHOUT its textures -- the LOD proxy mesh, the impostor billboard -- has to fold the
-- image back into a single colour or every house in the city goes cream.
--
-- Sampling an image at runtime means AssetService:CreateEditableImageAsync, which measured
-- 1.7-2.8 SECONDS per asset. There are only 33 distinct images in the whole library, so they
-- are sampled once here instead and the runtime just does a table lookup.
--
-- Each entry is { r, g, b, coverage }:
--   r,g,b     alpha-WEIGHTED mean colour -- transparent pixels contribute nothing, so a
--             window decal reports the colour of its frame and glass, not of the void
--             around them.
--   coverage  mean alpha, i.e. how much of the face the image actually paints. A tiling
--             wall skin is 1.0; a window decal with a transparent margin is ~0.76; a door
--             that is mostly cut-out is 0.04. This is the mix weight against the part's
--             own colour -- see `TextureAverages.over`.
--
-- REGENERATING: this table is generated, not hand-written. Re-run the sampler when the
-- texture set changes -- see textures/TextureMaker.java and BuildingTextures for where the
-- ids come from. An id that is missing here is not an error: `over` leaves the part's own
-- colour alone, which is the correct fallback.

local TextureAverages = {}

export type Entry = { number }

local AVG: { [string]: Entry } = {
	["rbxassetid://100372063385258"] = { 0.7057, 0.6979, 0.6744, 1.0000 }, -- cinderblock
	["rbxassetid://105733054917849"] = { 0.8157, 0.7992, 0.7706, 1.0000 }, -- white painted brick
	["rbxassetid://108157351474268"] = { 0.2073, 0.2166, 0.2333, 0.8734 },
	["rbxassetid://110975596306825"] = { 0.4799, 0.5818, 0.6838, 1.0000 }, -- corrugated metal, blue
	["rbxassetid://111729270731613"] = { 0.6274, 0.6823, 0.6195, 1.0000 }, -- corrugated metal, sage
	["rbxassetid://113202535718271"] = { 0.5638, 0.5887, 0.6143, 0.1321 }, -- craftsman door
	["rbxassetid://117407076760406"] = { 0.6087, 0.5088, 0.4316, 1.0000 }, -- brown brick
	["rbxassetid://120744987669991"] = { 0.6544, 0.4358, 0.3816, 1.0000 }, -- red brick
	["rbxassetid://122372047589447"] = { 0.7243, 0.7906, 0.8283, 0.7588 }, -- casement window
	["rbxassetid://123056540220884"] = { 0.2218, 0.1543, 0.1486, 0.0490 }, -- 6-panel door
	["rbxassetid://124262132655132"] = { 0.5755, 0.7501, 0.7911, 0.5779 },
	["rbxassetid://125373874279768"] = { 0.2412, 0.2784, 0.2608, 1.0000 }, -- standing-seam metal roof
	["rbxassetid://127832960785598"] = { 0.7458, 0.8044, 0.8361, 0.7588 }, -- colonial multi-light window
	["rbxassetid://130226293370153"] = { 0.6943, 0.7751, 0.8235, 0.7433 }, -- arched window
	["rbxassetid://133240680157954"] = { 0.2766, 0.2911, 0.3225, 1.0000 }, -- grey slate roof
	["rbxassetid://133444871536832"] = { 0.6566, 0.7225, 0.7654, 0.3285 }, -- half-glazed door
	["rbxassetid://135144302293588"] = { 0.9009, 0.8695, 0.7988, 1.0000 }, -- cream stucco
	["rbxassetid://137700066331586"] = { 0.5253, 0.5217, 0.5281, 1.0000 }, -- grey painted brick
	["rbxassetid://139497445378734"] = { 0.2081, 0.2149, 0.2267, 1.0000 }, -- charcoal asphalt shingle
	["rbxassetid://139634994997459"] = { 0.3116, 0.2550, 0.1904, 1.0000 }, -- brown asphalt shingle
	["rbxassetid://139755538118847"] = { 0.7525, 0.7446, 0.7290, 1.0000 }, -- concrete tilt-up panel
	["rbxassetid://71799249722464"]  = { 0.7939, 0.8057, 0.8213, 1.0000 }, -- corrugated metal, galvanised
	["rbxassetid://73246728181625"]  = { 0.1992, 0.1182, 0.1114, 0.0411 }, -- 2-panel door
	["rbxassetid://74892875066015"]  = { 1.0000, 1.0000, 1.0000, 0.0312 },
	["rbxassetid://75491684931289"]  = { 0.4752, 0.5456, 0.5925, 1.0000 }, -- blue-grey clapboard
	["rbxassetid://78855953898356"]  = { 0.6210, 0.6705, 0.7062, 0.2209 }, -- 4-panel glazed door
	["rbxassetid://80763573992883"]  = { 0.1646, 0.1251, 0.1128, 0.1737 }, -- plank door
	["rbxassetid://83368324469561"]  = { 0.5847, 0.6316, 0.5378, 1.0000 }, -- sage clapboard
	["rbxassetid://88615730471592"]  = { 0.1510, 0.1599, 0.1759, 0.8060 },
	["rbxassetid://89066648566749"]  = { 0.6358, 0.6145, 0.5719, 1.0000 }, -- ashlar stone
	["rbxassetid://90490066288632"]  = { 0.7289, 0.7936, 0.8300, 0.7588 }, -- 4-pane window
	["rbxassetid://91150421105278"]  = { 0.1638, 0.1247, 0.1128, 0.1755 }, -- cottage plank door
	["rbxassetid://93832687503532"]  = { 0.9323, 0.9245, 0.9009, 1.0000 }, -- white stucco

	-- SurfaceAppearance ColorMaps (nature meshes: trees, rocks, bushes). Note the leaf maps
	-- come out as exact greys -- they are masks, not colour. The green lives in
	-- SurfaceAppearance.Color, which SeasonTintClient drives per season; see
	-- TextureAverages.surface for how the two combine.
	["rbxassetid://101169942208953"] = { 0.5379, 0.3384, 0.2054, 1.0000 }, -- pine bark
	["rbxassetid://102392273916223"] = { 0.3435, 0.3307, 0.3031, 1.0000 },
	["rbxassetid://104396911810597"] = { 0.4809, 0.3487, 0.2186, 1.0000 },
	["rbxassetid://115814338359894"] = { 0.4076, 0.3541, 0.2996, 1.0000 }, -- oak bark
	["rbxassetid://119234610970067"] = { 0.2828, 0.2296, 0.1916, 1.0000 }, -- broadleaf bark
	["rbxassetid://120158949071993"] = { 0.5859, 0.5779, 0.5466, 1.0000 },
	["rbxassetid://120731189345410"] = { 0.9557, 0.8174, 0.2939, 0.1862 },
	["rbxassetid://122446773059292"] = { 0.4622, 0.4543, 0.4363, 1.0000 },
	["rbxassetid://124979466011972"] = { 0.3971, 0.3926, 0.3744, 1.0000 }, -- rock
	["rbxassetid://128721077097915"] = { 0.7511, 0.7511, 0.7511, 0.2694 }, -- leaf mask
	["rbxassetid://133879004985378"] = { 0.6396, 0.5836, 0.5062, 1.0000 },
	["rbxassetid://136407068381803"] = { 0.6420, 0.4622, 0.2526, 1.0000 },
	["rbxassetid://137255772638470"] = { 0.2868, 0.2776, 0.2516, 1.0000 }, -- rock
	["rbxassetid://139287610131830"] = { 0.8134, 0.8134, 0.8134, 0.2752 }, -- pine needle mask
	["rbxassetid://73726596385371"]  = { 0.8010, 0.1889, 0.1964, 0.0970 }, -- berries
	["rbxassetid://77234380606669"]  = { 0.6481, 0.6481, 0.6481, 0.3624 }, -- broadleaf mask
	["rbxassetid://80287273560334"]  = { 0.8052, 0.7934, 0.7673, 1.0000 },
	["rbxassetid://81876417259573"]  = { 0.2335, 0.2149, 0.1785, 1.0000 }, -- rock
	["rbxassetid://86130464685911"]  = { 0.9557, 0.5569, 0.7007, 0.1862 }, -- pink blossom
	["rbxassetid://86931008523119"]  = { 0.3740, 0.2807, 0.2087, 1.0000 },
	["rbxassetid://92478702305553"]  = { 0.9557, 0.9499, 0.9423, 0.1862 }, -- white blossom
	["rbxassetid://99559100574647"]  = { 0.7340, 0.7129, 0.6752, 1.0000 },

	-- MaterialVariant ColorMaps (street props: waste containers). Procedurally generated,
	-- regenerate with texture-tools/gen_bins.py. These read far darker than the material
	-- they depict, and that is correct rather than a sampling mistake: a slat drum is mostly
	-- the gap between its bars, so the honest average of the image is near-black even though
	-- the bars themselves are RAL 8019.
	["rbxassetid://71502897726410"]  = { 0.0995, 0.0907, 0.0902, 1.0000 }, -- bin_slats
	["rbxassetid://93713027558469"]  = { 0.1817, 0.1817, 0.1841, 1.0000 }, -- bin_lidribs
	["rbxassetid://110202954666586"] = { 0.2032, 0.2142, 0.2087, 1.0000 }, -- bin_hdpe
	["rbxassetid://102508816740768"] = { 0.1909, 0.2157, 0.2937, 1.0000 }, -- bin_solar
	["rbxassetid://92731039942367"]  = { 0.1258, 0.2371, 0.1525, 1.0000 }, -- bin_steel
}

-- The colour an image presents on its own, plus how much of its face it covers.
-- Coverage 0 means "unknown image": callers must treat that as "leave the part alone".
function TextureAverages.get(assetId: string): (Color3?, number)
	local e = AVG[assetId]
	if not e then
		return nil, 0
	end
	return Color3.new(e[1], e[2], e[3]), e[4]
end

-- The colour a part reads as once its decals are painted over it: each image is mixed in
-- by its own coverage, in application order. A wall skin (coverage 1) replaces the part
-- colour outright; a mostly-cut-out door (coverage 0.04) barely tints it. Unknown ids are
-- skipped rather than guessed, so an un-sampled image degrades to the part's own colour
-- instead of to black.
--
-- `decals` is anything with .Texture and .Color3 -- Decal and its subclass Texture both fit.
function TextureAverages.over(base: Color3, decals: { Decal }): Color3
	local c = base
	for _, d in decals do
		-- Read through a pcall for the same reason `surface` does: an asset-shaped property
		-- that needs a capability the client lacks throws, and a throw here would take the
		-- whole bake down rather than costing one decal its tint.
		local okId, id = pcall(function()
			return d.Texture
		end)
		local avg, coverage = nil, 0
		if okId and type(id) == "string" then
			avg, coverage = TextureAverages.get(id)
		end
		if avg then
			-- Decal.Color3 multiplies the image the same way it does when rendered.
			local tint = d.Color3
			local w = coverage * (1 - d.Transparency)
			c = c:Lerp(Color3.new(avg.R * tint.R, avg.G * tint.G, avg.B * tint.B), w)
		end
	end
	return c
end

-- Which ColorMap each nature mesh wears, and whether that map IS the surface.
--
-- THIS TABLE EXISTS BECAUSE `SurfaceAppearance.ColorMap` CANNOT BE READ AT RUNTIME. Reading
-- it needs the Plugin capability, so a live client asking an appearance which image it wears
-- throws "lacking capability Plugin" -- and because Studio's command bar DOES hold that
-- capability, the call works perfectly in Edit and fails only in the real game. `MeshId` is
-- readable, and every SurfaceAppearance in this place sits on a MeshPart (checked: 63 of 63),
-- so the runtime keys off the mesh instead and this maps it back to the image.
--
-- Second value is true for AlphaMode.Transparency, false for Overlay -- see `surface`.
local MESH_SURFACE: { [string]: { any } } = {
	["rbxassetid://101402275721713"] = { "rbxassetid://77234380606669", true },
	["rbxassetid://101630593448027"] = { "rbxassetid://122446773059292", false },
	["rbxassetid://101947500695035"] = { "rbxassetid://137255772638470", false },
	["rbxassetid://103422008712690"] = { "rbxassetid://81876417259573", false },
	["rbxassetid://104132604696109"] = { "rbxassetid://115814338359894", false },
	["rbxassetid://104413878300534"] = { "rbxassetid://86130464685911", true },
	["rbxassetid://105183530927351"] = { "rbxassetid://119234610970067", false },
	["rbxassetid://106465752421293"] = { "rbxassetid://77234380606669", true },
	["rbxassetid://106572009378562"] = { "rbxassetid://77234380606669", true },
	["rbxassetid://110004006372930"] = { "rbxassetid://139287610131830", true },
	["rbxassetid://110147501706544"] = { "rbxassetid://92478702305553", true },
	["rbxassetid://110301068483321"] = { "rbxassetid://77234380606669", true },
	["rbxassetid://110458400737069"] = { "rbxassetid://137255772638470", false },
	["rbxassetid://110861033961292"] = { "rbxassetid://77234380606669", true },
	["rbxassetid://111034971784028"] = { "rbxassetid://77234380606669", true },
	["rbxassetid://111637919252591"] = { "rbxassetid://119234610970067", false },
	["rbxassetid://113214983031982"] = { "rbxassetid://77234380606669", true },
	["rbxassetid://114510252171864"] = { "rbxassetid://81876417259573", false },
	["rbxassetid://118385821320464"] = { "rbxassetid://77234380606669", true },
	["rbxassetid://119679248256646"] = { "rbxassetid://137255772638470", false },
	["rbxassetid://120150000217163"] = { "rbxassetid://139287610131830", true },
	["rbxassetid://120999551934495"] = { "rbxassetid://139287610131830", true },
	["rbxassetid://121675348067327"] = { "rbxassetid://77234380606669", true },
	["rbxassetid://121980953197279"] = { "rbxassetid://81876417259573", false },
	["rbxassetid://124000289176146"] = { "rbxassetid://139287610131830", true },
	["rbxassetid://124163580482716"] = { "rbxassetid://137255772638470", false },
	["rbxassetid://125925937668892"] = { "rbxassetid://120731189345410", true },
	["rbxassetid://126242282159448"] = { "rbxassetid://81876417259573", false },
	["rbxassetid://127449620114946"] = { "rbxassetid://77234380606669", true },
	["rbxassetid://129886804537843"] = { "rbxassetid://137255772638470", false },
	["rbxassetid://136618705013748"] = { "rbxassetid://80287273560334", false },
	["rbxassetid://138064767230472"] = { "rbxassetid://73726596385371", true },
	["rbxassetid://138148214601782"] = { "rbxassetid://133879004985378", false },
	["rbxassetid://138434684091947"] = { "rbxassetid://77234380606669", true },
	["rbxassetid://139793385809943"] = { "rbxassetid://120158949071993", false },
	["rbxassetid://71208526072827"]  = { "rbxassetid://137255772638470", false },
	["rbxassetid://72949215784116"]  = { "rbxassetid://101169942208953", false },
	["rbxassetid://74479111271165"]  = { "rbxassetid://81876417259573", false },
	["rbxassetid://76985078853983"]  = { "rbxassetid://137255772638470", false },
	["rbxassetid://77065669707740"]  = { "rbxassetid://133879004985378", false },
	["rbxassetid://77441959391966"]  = { "rbxassetid://99559100574647", false },
	["rbxassetid://77686352077538"]  = { "rbxassetid://137255772638470", false },
	["rbxassetid://78359304213726"]  = { "rbxassetid://115814338359894", false },
	["rbxassetid://78596660756952"]  = { "rbxassetid://137255772638470", false },
	["rbxassetid://78873235784897"]  = { "rbxassetid://104396911810597", false },
	["rbxassetid://79617218662981"]  = { "rbxassetid://128721077097915", true },
	["rbxassetid://79678584421931"]  = { "rbxassetid://77234380606669", true },
	["rbxassetid://80190838598782"]  = { "rbxassetid://137255772638470", false },
	["rbxassetid://80356737665017"]  = { "rbxassetid://137255772638470", false },
	["rbxassetid://81208624862234"]  = { "rbxassetid://77234380606669", true },
	["rbxassetid://83705071189673"]  = { "rbxassetid://77234380606669", true },
	["rbxassetid://84013395366035"]  = { "rbxassetid://136407068381803", false },
	["rbxassetid://87160989057829"]  = { "rbxassetid://139287610131830", true },
	["rbxassetid://87201765896725"]  = { "rbxassetid://139287610131830", true },
	["rbxassetid://88543110519111"]  = { "rbxassetid://86931008523119", false },
	["rbxassetid://90856109499170"]  = { "rbxassetid://92478702305553", true },
	["rbxassetid://91176020385106"]  = { "rbxassetid://77234380606669", true },
	["rbxassetid://92006553746194"]  = { "rbxassetid://139287610131830", true },
	["rbxassetid://92602506744201"]  = { "rbxassetid://77234380606669", true },
	["rbxassetid://97275103617822"]  = { "rbxassetid://77234380606669", true },
	["rbxassetid://97406565474398"]  = { "rbxassetid://137255772638470", false },
	["rbxassetid://98120915452447"]  = { "rbxassetid://81876417259573", false },
	["rbxassetid://99995576925799"]  = { "rbxassetid://81876417259573", false },
}

-- The colour a part wearing a SurfaceAppearance reads as, or nil when there is nothing
-- useful to say -- in which case the caller should fall back to `over`.
--
-- Nature meshes are the reason this exists. Their leaf ColorMaps are greyscale MASKS -- the
-- green is `SurfaceAppearance.Color`, which SeasonTintClient rewrites as the seasons turn.
-- Reading Part.Color for a tree returns the same lifeless grey for every species.
--
-- The two alpha modes composite differently, and it matters:
--   Transparency  the map (times the tint) IS the surface; Part.Color plays no part
--   Overlay       the map is composited OVER Part.Color, so coverage is the mix weight
--
-- Total by construction: never throws, and returns nil rather than guessing. A colour this
-- cannot resolve costs one asset its exact tint; a THROW here kills the whole bake, which is
-- precisely what the ColorMap capability error did.
function TextureAverages.surface(part: BasePart, base: Color3): Color3?
	local sa = part:FindFirstChildWhichIsA("SurfaceAppearance")
	if not sa then
		return nil
	end
	local okId, meshId = pcall(function()
		return (part :: any).MeshId
	end)
	if not okId or type(meshId) ~= "string" then
		return nil
	end
	local link = MESH_SURFACE[meshId]
	if not link then
		return nil
	end
	local e = AVG[link[1]]
	if not e then
		return nil
	end
	local okTint, tint = pcall(function()
		return sa.Color
	end)
	if not okTint or typeof(tint) ~= "Color3" then
		tint = Color3.new(1, 1, 1)
	end
	local c = Color3.new(e[1] * tint.R, e[2] * tint.G, e[3] * tint.B)
	if link[2] then
		return c
	end
	return base:Lerp(c, e[4])
end

-- Which ColorMap each MaterialVariant wears.
--
-- Same trick as MESH_SURFACE above, for the same capability reason -- but keyed off
-- `BasePart.MaterialVariant`, which is a plain STRING and needs no capability at all, so
-- this one is safe to read anywhere.
--
-- This exists because a part-built prop cannot use SurfaceAppearance (that binds to
-- MeshParts only), so street props get their PBR through a MaterialVariant instead -- and
-- nothing downstream knew how to fold one back into a colour. Without this a textured bin
-- bakes its proxy from Part.Color alone, which for these props is WHITE, so every bin in
-- the city turned into a white block the moment it crossed 500 studs.
local VARIANT_SURFACE: { [string]: string } = {
	BinSlats   = "rbxassetid://71502897726410",
	BinLidRibs = "rbxassetid://93713027558469",
	BinHDPE    = "rbxassetid://110202954666586",
	BinSolar   = "rbxassetid://102508816740768",
	BinSteel   = "rbxassetid://92731039942367",
}

-- The colour a part wearing a MaterialVariant reads as, or nil when there is nothing useful
-- to say -- in which case the caller falls back to `over`.
--
-- A MaterialVariant's ColorMap MULTIPLIES Part.Color rather than replacing it (the same
-- product RoadMeshView relies on, which is why RoadConstants.ROAD_COLOR is an input to the
-- render and not the result -- see BadAppleRoadTile's DISPLAY table). So the composite is
-- the image average times the part's own colour, and a part left white simply reports the
-- image.
--
-- Total by construction: never throws, returns nil rather than guessing.
function TextureAverages.variant(part: BasePart, base: Color3): Color3?
	local okName, name = pcall(function()
		return part.MaterialVariant
	end)
	if not okName or type(name) ~= "string" or name == "" then
		return nil
	end
	local id = VARIANT_SURFACE[name]
	if not id then
		return nil
	end
	local e = AVG[id]
	if not e then
		return nil
	end
	return Color3.new(e[1] * base.R, e[2] * base.G, e[3] * base.B)
end

-- How much of its cards a CUTOUT surface actually paints, or nil for anything else.
--
-- Leaves are not geometry the way a wall is. A canopy is a few hundred big quads wearing a
-- greyscale mask that is mostly holes -- the leaf shapes are punched out by alpha, not
-- modelled. So anything that has to draw a tree WITHOUT its alpha (the LOD mesh, the
-- impostor) has to know two things: that this surface is leaves rather than solid geometry,
-- and how much of each card the mask leaves standing. Baking the cards opaque instead paints
-- ~3x the area the real tree does, which is exactly why an untreated tree proxy reads as a
-- pile of flat plates rather than as foliage.
--
-- Keyed off MeshId for the same reason `surface` is: ColorMap cannot be read at runtime.
function TextureAverages.cutout(part: BasePart): number?
	local sa = part:FindFirstChildWhichIsA("SurfaceAppearance")
	if not sa then
		return nil
	end
	local okId, meshId = pcall(function()
		return (part :: any).MeshId
	end)
	if not okId or type(meshId) ~= "string" then
		return nil
	end
	local link = MESH_SURFACE[meshId]
	-- link[2] is AlphaMode.Transparency: the map IS the surface, holes included.
	if not link or not link[2] then
		return nil
	end
	local e = AVG[link[1]]
	if not e then
		return nil
	end
	return e[4]
end

return TextureAverages
