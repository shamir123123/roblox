--!strict
-- Shared terrain types. No runtime values beyond the empty table export.

local TerrainConstants = require(script.Parent.TerrainConstants)

export type BrushOp = TerrainConstants.BrushOp

-- One persisted/rendered tile block. Buffers hold CHUNK_CORNER_COUNT entries in
-- row-major order (localZ * CHUNK_CORNERS + localX):
--   heights   : uint16 raw height per corner
--   materials : uint8 material id (0 = AUTO)
--   flags     : uint8 bitfield (see TerrainConstants.Flag)
export type Chunk = {
	cx: number, -- chunk index X [0, CHUNKS_PER_AXIS)
	cz: number, -- chunk index Z [0, CHUNKS_PER_AXIS)
	heights: buffer,
	materials: buffer,
	flags: buffer,
}

-- A single brush stroke tick from the client. centerX/centerZ are world studs.
export type BrushStroke = {
	op: BrushOp,
	centerX: number,
	centerZ: number,
	radius: number, -- studs
	strength: number, -- 0..1 scalar
	material: number?, -- required for SetMaterial; target height (worldY) for Level
	target: number?, -- target worldY for Level/Flatten lock
	dt: number?, -- seconds since the previous tick; the brush moves ground per SECOND, not
	             -- per tick, so how fast it digs does not depend on how often ticks land.
	             -- Absent means "one nominal tick"; the server clamps it either way.
}

-- Inclusive global corner-index rectangle marked changed by an edit. Consumers
-- (renderer, persistence) translate this into affected chunks.
export type DirtyRect = {
	minX: number,
	minZ: number,
	maxX: number,
	maxZ: number,
}

return {}
