--!strict
-- Shared shapes for Outside Connections.

export type Direction = "in" | "out" | "both"

-- Live, in-memory connection (server-owned, OutsideConnectionService).
export type Connection = {
	id: string,           -- STABLE; assigned once, never regenerated across loads
	side: string,         -- OutsideConnectionConstants.Side value
	outer: Vector3,       -- map-edge endpoint (Y seated on terrain)
	inner: Vector3,       -- city-side mouth players connect their roads onto
	normal: Vector3,      -- unit outward direction (away from city centre, flat)
	dir: Direction,
	roadType: string,
	-- Live engine ids of the underlying stub road. These REGENERATE every load; the
	-- service re-links them from stored geometry. Never persist or expose these.
	segmentId: number?,
	nodeId: number?,      -- inner-mouth node (the city-side graph entry)
	outerNodeId: number?, -- edge node (the off-map terminal)
}

-- Persisted form (save slot + baked map defaults). Only the stable id + geometry on
-- the edge is stored; Y is recomputed on load so terrain edits move it with the
-- ground, and the stub's engine ids are re-derived, never saved.
export type Serialized = {
	id: string,
	side: string,
	x: number,  -- outer endpoint world X
	z: number,  -- outer endpoint world Z
	dir: string,
	rt: string, -- road type id
}

return {}
