--!strict
-- TrafficSignPlanner -- where every traffic sign in the city stands, worked out from the road
-- network alone. Pure library: no state, no instances. The client view (TrafficSignView) draws
-- the result; anything that wants to know "is there a stop sign here" can ask the same.
--
-- The rules, in the order a driver meets them:
--   stop / give way  -- on each MINOR approach of a junction without lights. Minor is the same
--                       judgement the drivers make (NPCDriverService.getNodeMeta): with a
--                       major road present, the smaller roads; otherwise the stem of a T. A
--                       junction of equals is all-way stop in the US and needs no sign under
--                       the Vienna Convention (priority to the right).
--   one way          -- where a one-way street leaves a junction, a pair on its two corners
--                       facing the cross street both ways, arrow along the flow.
--   do not enter     -- where a one-way street (an off-ramp too) ends at a junction, facing
--                       anyone who would turn into it against the flow.
--   highway entrance -- at the start of an on-ramp, or of a highway leaving a street.
--   speed limit      -- wherever the limit changes (junction or plain join), at the start of a
--                       road, and out of a junction onto a long road; one per direction.
-- Nothing is signed on a roundabout ring or its entries (the ring markings do that job), and
-- no stop or give-way sign stands at a signalised junction.

local WorldThemeCatalog = require(script.Parent.Parent:WaitForChild("World"):WaitForChild("WorldThemeCatalog"))
local RoadTypeCatalog = require(script.Parent.RoadTypeCatalog)
local RoadRules = require(script.Parent.RoadRules)
local BezierUtil = require(script.Parent.BezierUtil)

local TrafficSignPlanner = {}

export type SignKind = "stop" | "yield" | "allway" | "oneway" | "noentry" | "highway" | "speed"
export type Sign = {
	key: string,        -- stable identity (node / segment / kind), for pooling and diffing
	kind: SignKind,
	pos: Vector3,       -- foot of the post
	face: Vector3,      -- flat unit vector the sign face points toward (at its viewers)
	text: string?,      -- the speed on a speed sign
	arrowRight: boolean?, -- one way: the arrow points to the viewer's right
	nodeId: number,
}

export type Segment = {
	id: number, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
	roadType: string, startNode: number, endNode: number,
	isRoundabout: boolean?, isArc: boolean?, vMode: string?, speedLimitOverride: number?,
}

export type Options = {
	signSystem: string,             -- "mutcd" (USA) or "vienna" (Europe)
	speedUnit: string,              -- "mph" or "kmh"
	laneSideSign: number,           -- RoadRules.getLaneSideSign()
	isSignalised: (nodeId: number) -> boolean,
}

local SIGN_SETBACK = 6          -- studs past the junction mouth a sign stands
local KERB_CLEARANCE = 1.2      -- studs outside the carriageway edge
local SPEED_MIN_ROAD = 80       -- studs: shorter pieces carry no speed sign
local SPEED_LONG_ROAD = 400     -- studs: a road this long is signed out of every junction
local MOUTH_GUESS = 1.1         -- x half the widest crossing road: where a junction mouth sits
local THROUGH_DOT = -0.866
local UP = Vector3.yAxis

local function flat(v: Vector3): Vector3?
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-4 then f.Unit else nil
end

-- Direction a segment leaves `nodeId` in.
local function armDir(seg: Segment, nodeId: number): Vector3?
	if seg.startNode == nodeId then
		return flat(seg.p1 - seg.p0) or flat(seg.p3 - seg.p0)
	end
	return flat(seg.p2 - seg.p3) or flat(seg.p0 - seg.p3)
end

-- Point and flat travel direction `dist` studs along `seg` from its `nodeId` end.
local function alongFrom(seg: Segment, nodeId: number, dist: number): (Vector3, Vector3)
	local len = BezierUtil.length(seg.p0, seg.p1, seg.p2, seg.p3, 8)
	local t = math.clamp(dist / math.max(len, 1e-3), 0, 1)
	if seg.endNode == nodeId then t = 1 - t end
	local p = BezierUtil.point(seg.p0, seg.p1, seg.p2, seg.p3, t)
	local tan = BezierUtil.tangent(seg.p0, seg.p1, seg.p2, seg.p3, t)
	if seg.endNode == nodeId then tan = -tan end
	return p, flat(tan) or Vector3.zAxis
end

local function speedText(kmh: number, unit: string): string
	if unit == "mph" then
		return tostring(math.max(5, math.floor(kmh / 1.609344 / 5 + 0.5) * 5))
	end
	return tostring(math.max(10, math.floor(kmh / 10 + 0.5) * 10))
end

local function signable(spec: any, seg: Segment): boolean
	return not seg.isRoundabout and not seg.isArc and not spec.terrainPath and spec.id ~= "Rail"
		and seg.vMode ~= "Tunnel"
end

-- The kerb on the driving side of traffic travelling `travel`, just outside the carriageway.
-- (A one-way's lanes fill the road, so the same kerb serves it.)
local function kerbPoint(centre: Vector3, travel: Vector3, spec: any, laneSideSign: number): Vector3
	return centre + travel:Cross(UP) * laneSideSign * (spec.width * 0.5 + KERB_CLEARANCE)
end

function TrafficSignPlanner.plan(segments: { Segment }, nodePos: (number) -> Vector3?, opts: Options): { Sign }
	local out: { Sign } = {}
	local byNode: { [number]: { Segment } } = {}
	for _, seg in segments do
		for _, nid in { seg.startNode, seg.endNode } do
			local list = byNode[nid]
			if not list then
				list = {}
				byNode[nid] = list
			end
			table.insert(list, seg)
		end
	end
	local us = opts.signSystem ~= "vienna"
	local side = opts.laneSideSign

	for nodeId, segs in byNode do
		local npos = nodePos(nodeId)
		if not npos then continue end
		local roundabout = false
		for _, s in segs do if s.isRoundabout then roundabout = true end end
		if roundabout then continue end

		-- Arms and the widest road here (for where the mouth sits).
		local arms: { { seg: Segment, spec: any, dir: Vector3 } } = {}
		local widest = 0
		for _, s in segs do
			local dir = armDir(s, nodeId)
			local spec = RoadTypeCatalog.getOrDefault(s.roadType)
			if dir then
				table.insert(arms, { seg = s, spec = spec, dir = dir })
				widest = math.max(widest, spec.width)
			end
		end
		local junction = #arms >= 3
		local mouth = if junction then widest * 0.5 * MOUTH_GUESS else 0
		local signalised = junction and opts.isSignalised(nodeId)

		-- == stop / give way ================================================
		if junction and not signalised then
			local anyArterial = false
			for _, a in arms do
				if RoadRules.roadClass(a.spec) == "arterial" then anyArterial = true end
			end
			local minor: { [number]: boolean } = {}
			local anyMajor = false
			for i, a in arms do
				local isMajor: boolean
				if anyArterial then
					isMajor = RoadRules.roadClass(a.spec) == "arterial"
				else
					isMajor = false
					for j, b in arms do
						if i ~= j and a.dir:Dot(b.dir) < THROUGH_DOT then isMajor = true end
					end
				end
				if isMajor then anyMajor = true else minor[i] = true end
			end
			-- Every arm major (a plain crossroads of equal streets, or big roads whose lights
			-- the player took down): nobody has priority, so it is a junction of equals.
			if next(minor) == nil then anyMajor = false end
			for i, a in arms do
				-- Highway ramps merge, and only traffic heading INTO the node is controlled.
				if a.spec.isHighway or not signable(a.spec, a.seg) then continue end
				local inbound = not a.spec.oneWay or a.seg.endNode == nodeId
				if not inbound then continue end
				local kind: SignKind? = nil
				if minor[i] and anyMajor then
					kind = if us then "stop" else "yield"
				elseif not anyMajor and us then
					kind = "allway"
				end
				if kind then
					local centre, travelOut = alongFrom(a.seg, nodeId, mouth + SIGN_SETBACK)
					local travelIn = -travelOut
					table.insert(out, {
						key = `{kind}:{nodeId}:{a.seg.id}`, kind = kind,
						pos = kerbPoint(centre, travelIn, a.spec, side), face = travelOut,
						nodeId = nodeId,
					})
				end
			end
		end

		for _, a in arms do
			local spec, seg = a.spec, a.seg
			if not signable(spec, seg) then continue end
			local leaves = seg.startNode == nodeId -- the road's own direction runs away from here
			local others = #arms - 1

			-- == one way / do not enter ======================================
			if spec.oneWay and others >= 2 then
				if leaves and not spec.isHighway then
					-- One on each corner, mounted along the street so the cross street reads the
					-- arrow whichever way it comes from.
					local centre, flow = alongFrom(seg, nodeId, mouth + SIGN_SETBACK * 0.5)
					for i, sgn in { 1, -1 } do
						local outward = flow:Cross(UP) * side * sgn
						local viewerRight = (-outward):Cross(UP)
						table.insert(out, {
							key = `oneway:{nodeId}:{seg.id}:{i}`, kind = "oneway",
							pos = centre + outward * (spec.width * 0.5 + KERB_CLEARANCE), face = outward,
							arrowRight = flow:Dot(viewerRight) > 0, nodeId = nodeId,
						})
					end
				elseif not leaves then
					-- Its exit end: facing whoever would turn in against the flow.
					local centre, awayFromNode = alongFrom(seg, nodeId, mouth + SIGN_SETBACK)
					table.insert(out, {
						key = `noentry:{nodeId}:{seg.id}`, kind = "noentry",
						pos = kerbPoint(centre, awayFromNode, spec, side), face = -awayFromNode,
						nodeId = nodeId,
					})
				end
			end

			-- == highway entrance ============================================
			-- An on-ramp (or any one-way carriageway) leaving a street, or a highway that
			-- begins where a street ends. Not a two-way highway passing a side street: that
			-- sign would face the highway's own through traffic.
			if spec.isHighway and leaves and others >= 1 then
				local fromStreet, otherHighway = false, false
				for _, b in arms do
					if b.seg ~= seg then
						if b.spec.isHighway then otherHighway = true else fromStreet = true end
					end
				end
				if fromStreet and (spec.oneWay or not otherHighway) then
					local centre, flow = alongFrom(seg, nodeId, mouth + SIGN_SETBACK)
					table.insert(out, {
						key = `highway:{nodeId}:{seg.id}`, kind = "highway",
						pos = kerbPoint(centre, flow, spec, side), face = -flow, nodeId = nodeId,
					})
				end
			end

			-- == speed limit =================================================
			-- For the traffic leaving this node along this road.
			if not leaves and spec.oneWay then continue end
			local len = BezierUtil.length(seg.p0, seg.p1, seg.p2, seg.p3, 8)
			if len < SPEED_MIN_ROAD or spec.speedLimit <= 20 then continue end
			local kmh = RoadRules.getSpeedLimitKmh(seg :: any, spec)
			-- Where a driver arrives from a road with another limit (every join and junction
			-- where the limits differ), at the start of a road, and on the way out of a
			-- junction onto a long road. Not on every block of a uniform grid.
			local wanted = #arms == 1 or (junction and len >= SPEED_LONG_ROAD)
			if not wanted then
				for _, b in arms do
					if b.seg ~= seg and math.abs(RoadRules.getSpeedLimitKmh(b.seg :: any, b.spec) - kmh) > 0.5 then
						wanted = true
						break
					end
				end
			end
			if wanted then
				local centre, flow = alongFrom(seg, nodeId, mouth + SIGN_SETBACK * 3)
				table.insert(out, {
					key = `speed:{nodeId}:{seg.id}`, kind = "speed",
					pos = kerbPoint(centre, flow, spec, side), face = -flow,
					text = speedText(kmh, opts.speedUnit), nodeId = nodeId,
				})
			end
		end
	end
	return out
end

-- The same options the live world uses, for callers that have no reason to differ.
function TrafficSignPlanner.defaultOptions(isSignalised: (number) -> boolean): Options
	local theme = WorldThemeCatalog.active()
	return {
		signSystem = theme.signSystem or "mutcd",
		speedUnit = theme.speedUnit or "mph",
		laneSideSign = RoadRules.getLaneSideSign(),
		isSignalised = isSignalised,
	}
end

return TrafficSignPlanner
