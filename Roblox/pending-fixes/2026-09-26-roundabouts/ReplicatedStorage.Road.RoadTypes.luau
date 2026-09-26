--!strict

export type NodeId = number
export type SegmentId = number

export type Node = {
	id: NodeId,
	position: Vector3,
	segments: { SegmentId },
}

export type Segment = {
	id: SegmentId,
	startNode: NodeId,
	endNode: NodeId,
	roadType: string,
	p0: Vector3,
	p1: Vector3,
	p2: Vector3,
	p3: Vector3,
	isArc: boolean?,

	speedLimitOverride: number?,
	allowedVehiclesOverride: { [string]: boolean }?,

	-- Player-set street name. nil = the auto name AddressBook derives from the
	-- street's geometry; a rename writes the same string onto every segment of
	-- the chain so the name survives splits, deletions and reloads.
	name: string?,

	-- Node-tool shaping, per END (start = at startNode, end = at endNode). Stored on
	-- the segment rather than the node because nodes are derived: they are rebuilt by
	-- position on every load and carry no persisted identity (see RoadSerializer).
	-- corner = that node corner's fillet radius; offset = studs the arm's mouth is
	-- pushed out of the junction. nil = the shared default.
	startCorner: number?,
	endCorner: number?,
	startOffset: number?,
	endOffset: number?,
	-- Flat junction: the node's paved plate is levelled at the node's own height instead
	-- of riding the arms' grades across it. This one describes the NODE, not the arm, so
	-- shapeJunction writes the same value onto every arm meeting that node and the
	-- renderer treats any arm carrying it as speaking for the whole junction.
	startFlat: boolean?,
	endFlat: boolean?,

	-- Vertical placement: "Ground" | "Elevated" | "Tunnel" (nil = Ground).
	-- constSlope = ramp at a constant grade A->B instead of following terrain.
	vMode: string?,
	constSlope: boolean?,

	-- Roundabout ring metadata. Set on the one-way arcs that form a roundabout's
	-- circulating carriageway (and propagated when such an arc is split by a
	-- connecting road). A node is a "roundabout node" when any of its segments
	-- carries this flag.
	isRoundabout: boolean?,
	roundaboutId: number?,
	roundaboutCenter: Vector3?,
	roundaboutRadius: number?,
	roundaboutPreset: string?, -- centre preset (RoadConstants.ROUNDABOUT_CENTRE_PRESETS); nil = "Empty"
}

export type PlacementRequest = {
	roadType: string,
	p0: Vector3,
	p1: Vector3,
	p2: Vector3,
	p3: Vector3,
	vMode: string?,
	constSlope: boolean?,
}

return {}
