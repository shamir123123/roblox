--!strict
-- Single source of every terrain magic number. Shared client+server, immutable.
-- Geometry note: world is MAP_EXTENT square centered on origin. Heights are stored
-- at tile CORNERS (shared between adjacent tiles). Height is a uint16 raw value
-- encoding worldY = FLOOR_Y + raw * HEIGHT_STEP, so the floor sits below sea level
-- to allow generated ocean depth while the player brush is still clamped at sea.

export type BrushOp = "Raise" | "Lower" | "Flatten" | "Smooth" | "Level" | "SetMaterial"

local TerrainConstants = {
	-- World extent (MUST match RoadConstants.MAP_HALF_EXTENT; asserted at boot).
	MAP_HALF_EXTENT = 4096,
	MAP_EXTENT = 8192,

	-- Sampling: one height corner every SAMPLE_SPACING studs.
	SAMPLE_SPACING = 4,
	TILES_PER_AXIS = 2048, -- MAP_EXTENT / SAMPLE_SPACING
	CORNERS_PER_AXIS = 2049, -- TILES_PER_AXIS + 1 (shared corners)

	-- Chunking: persistence + dirty-tracking + future streaming unit.
	CHUNK_TILES = 64, -- tiles per chunk axis
	CHUNK_STUDS = 256, -- CHUNK_TILES * SAMPLE_SPACING
	CHUNKS_PER_AXIS = 32, -- MAP_EXTENT / CHUNK_STUDS (2x map: 1024 chunks)
	CHUNK_CORNERS = 65, -- CHUNK_TILES + 1 (edges shared with neighbour chunk)
	CHUNK_CORNER_COUNT = 4225, -- 65 * 65

	-- Height encoding (uint16 raw -> worldY).
	HEIGHT_STEP = 0.25, -- studs per raw unit
	FLOOR_Y = -64, -- worldY at raw 0 (deepest ocean floor)
	SEA_Y = 0, -- worldY of sea surface
	SEA_RAW = 256, -- (SEA_Y - FLOOR_Y) / HEIGHT_STEP
	RAW_MAX = 65535,

	-- Brush limits (server-enforced; see TerrainEditService validation).
	BRUSH_MAX_RADIUS = 100, -- studs
	-- Sculpting is RATE based. A stroke carries the time since the previous one and the
	-- brush moves the ground this many studs per SECOND at full strength. It used to be a
	-- flat 6 studs per tick at 15 ticks/s -- 90 studs a second, arriving in six-stud jumps,
	-- which is what made the tool feel like it was chopping rather than sculpting. Rate
	-- based also means how fast the ground moves no longer depends on how often ticks land.
	BRUSH_STUDS_PER_SECOND = 14,
	-- How fast a proportional op (Flatten, Level, Smooth) closes the gap to its target, as a
	-- fraction per second. Proportional ops ease in rather than snapping.
	BRUSH_APPROACH_PER_SECOND = 3.5,
	-- A little smoothing rides along with Raise/Lower, so a stroke leaves rolling ground
	-- instead of the lumpy record of wherever the cursor happened to linger. Deliberately
	-- SMALL: turn it up and the brush stops digging what you aimed at and starts averaging
	-- your work away, which is worse than no smoothing at all. Fraction of the gap to the
	-- neighbourhood average closed per second, before the brush falloff scales it down again.
	BRUSH_AUTO_SMOOTH_PER_SECOND = 1.1,
	BRUSH_MAX_DT = 0.2, -- longest tick the server honours, so a client cannot bank up time
	BRUSH_MAX_DELTA_PER_TICK = 4, -- hard per-tick safety clamp (>= STUDS_PER_SECOND * MAX_DT)
	BRUSH_RATE_INTERVAL = 1 / 30, -- min seconds between accepted stroke ticks (~30/s)
	SLOPE_CLAMP_DEG = 60, -- max corner-to-corner grade (render-safety, not buildable policy)
	MAX_DIG_BELOW_SEA = 40, -- studs; deepest a brush may carve below sea level (10 m at 0.25 stud/m)

	-- Render.
	VOXEL_RESOLUTION = 4, -- Roblox Terrain voxel size (studs); equals SAMPLE_SPACING
	-- Roblox draws the smooth-terrain surface at the TOP of the partially-filled surface
	-- voxel, so the VISIBLE ground sits a constant +2 studs (half a voxel) above the
	-- heightmap value it was painted from (measured flat-region: heightmap H renders at
	-- H + 2 for every H). Anything that rests on the visible ground (roads, lots,
	-- buildings) must place against the surface = heightmap + RENDER_BULGE, not the raw
	-- heightmap, or it ends up buried and the grade/pad services dig a pit to expose it.
	RENDER_BULGE = 2, -- studs; visible surface minus heightmap (= VOXEL_RESOLUTION / 2)
	RENDER_CHUNKS_PER_FRAME = 2, -- dirty chunks repainted per Heartbeat batch

	-- Custom ground mesh (TerrainMesh / TerrainMeshView). The ground is a hollow MeshPart
	-- shell built from this same heightmap and workspace.Terrain keeps ONLY water, so:
	-- underground is empty space you can build in and see into, the surface INTERPOLATES
	-- instead of snapping to voxel corners (no stair edges), and the ground carries no
	-- collision geometry at all -- picking is analytic, see CursorRay. Mesh vertices sit at
	-- heightmap + RENDER_BULGE, the same visible surface the voxels rendered, so every road,
	-- pad and building keeps placing exactly where it already did.
	MESH_GROUND = true,
	-- Every corner stride the ground can be drawn at above full resolution. Which one a block
	-- gets is decided by SCREEN-SPACE ERROR in TerrainMeshView (half a pixel), not by distance
	-- rings. A chunk the CITY has touched is PINNED, meaning distance never coarsens it:
	-- coarsening the ground under a road is exactly what let distant terrain swallow roads
	-- (see TerrainGradeService).
	-- Strides up to MESH_BLOCK_TILES are per block. BEYOND it the blocks stop being a useful
	-- unit and the whole chunk merges into ONE grid, which is the only way the far map gets
	-- genuinely cheap. 64 is the whole chunk as one quad.
	MESH_LOD_STEPS = table.freeze({ 2, 4, 8, 16, 32, 64 }),
	-- Studs per repeat of the surface material's texture. The mesh carries real UVs derived
	-- from WORLD x/z, so the texture is nailed to the world and stays continuous across chunk
	-- and LOD boundaries. Every vertex used to sample UV (0,0), which left the material with
	-- no mapping at all -- that is what made the ground crawl as the geometry under it changed.
	MESH_TEXTURE_STUDS = 128,
	-- Stride is decided per BLOCK, not per chunk. A chunk is 256 studs and a road clipping
	-- one corner of it used to drag the whole thing to full detail -- an ocean of tiny quads
	-- with one road in it. At 8 tiles (32 studs) a block is small enough that the road keeps
	-- its detail while the levelled field beside it collapses to one quad per block. It also
	-- caps the coarsest stride at 8: the trade for that is a featureless chunk costing 128
	-- triangles instead of 32, which is nothing next to what the cities save.
	MESH_BLOCK_TILES = 8,
	-- ...but distance is only half of it. A chunk is also never drawn finer than its own
	-- SHAPE justifies: TerrainMesh.losslessStep finds the coarsest stride that stays within
	-- this many studs of the real surface, and levelled-flat ground comes back at the
	-- coarsest stride there is however close the camera gets. The tolerance is one height
	-- quantum, so "lossless" means losing less than the heightmap can even express. Even a
	-- PINNED chunk coarsens this way -- it cannot hurt a road to drop detail the ground does
	-- not have -- and the moment anything is sculpted or graded there, the shape stops
	-- fitting and the detail comes straight back.
	MESH_FLAT_TOLERANCE = 0.25, -- = HEIGHT_STEP
	MESH_LOD_REFRESH = 0.35, -- seconds between LOD re-evaluations
	-- Seconds of mesh building per frame. One chunk always gets built whatever this says, so
	-- it is a ceiling on CHAINING chunks in a frame, not on the cost of one: small enough
	-- that the background fill never owns a frame, large enough that it still drains.
	MESH_BUILD_BUDGET = 1 / 240,
	MESH_UNDERGROUND_ALPHA = 0.75, -- ground transparency in underground view

	-- Persistence.
	SCHEMA_VERSION = 3, -- bumped: map doubled to 8192 studs / 32 chunks per axis; older 4096/16-chunk terrain saves are rejected (deserialize) and regenerated at the new size
	GEN_VERSION = 2, -- bump when the generator noise formula changes (affects unedited base only)
	AUTOSAVE_INTERVAL = 60, -- seconds between dirty-chunk flushes during play
	BINDTOCLOSE_TIMEOUT = 25, -- seconds BindToClose may yield for final flush
}

-- Material ids stored in the material layer. 0 = AUTO: renderer derives material
-- from height/slope. Non-zero = explicit player override.
TerrainConstants.Material = table.freeze({
	AUTO = 0,
	GRASS = 1,
	SAND = 2,
	ROCK = 3,
	SNOW = 4,
	GROUND = 5,
	MUD = 6,
	-- The base map's own surface (no animated grass-blade decoration, unlike GRASS).
	-- Road cuts stamp this so the trench matches the untouched ground around it.
	LEAFY = 7,
})

-- Render mapping: material id -> Roblox Enum.Material.
TerrainConstants.MaterialEnum = table.freeze({
	[1] = Enum.Material.Grass,
	[2] = Enum.Material.Sand,
	[3] = Enum.Material.Rock,
	[4] = Enum.Material.Snow,
	[5] = Enum.Material.Ground,
	[6] = Enum.Material.Mud,
	[7] = Enum.Material.LeafyGrass,
})

-- Corner flag bits (flags layer, uint8 bitfield).
TerrainConstants.Flag = table.freeze({
	LOCKED = 1, -- read-only to brushes (owned by another system, e.g. road grade)
	ROAD_GRADED = 2, -- vertical owned by the road network
	PAD_GRADED = 4, -- vertical owned by a building pad
})

-- worldY for a raw height value.
function TerrainConstants.rawToWorldY(raw: number): number
	return TerrainConstants.FLOOR_Y + raw * TerrainConstants.HEIGHT_STEP
end

-- raw height for a worldY (rounded, clamped to uint16 range).
function TerrainConstants.worldYToRaw(worldY: number): number
	local raw = math.round((worldY - TerrainConstants.FLOOR_Y) / TerrainConstants.HEIGHT_STEP)
	if raw < 0 then return 0 end
	if raw > TerrainConstants.RAW_MAX then return TerrainConstants.RAW_MAX end
	return raw
end

-- world X/Z (stud) for a global corner index on one axis.
function TerrainConstants.cornerToWorld(cornerIndex: number): number
	return -TerrainConstants.MAP_HALF_EXTENT + cornerIndex * TerrainConstants.SAMPLE_SPACING
end

-- nearest global corner index for a world stud coordinate on one axis (unclamped).
function TerrainConstants.worldToCorner(world: number): number
	return (world + TerrainConstants.MAP_HALF_EXTENT) / TerrainConstants.SAMPLE_SPACING
end

return table.freeze(TerrainConstants)
