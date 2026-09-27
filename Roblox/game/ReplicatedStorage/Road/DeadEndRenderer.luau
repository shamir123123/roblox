--!strict

local RoadConstants = require(script.Parent.RoadConstants)
local RoadMeshBuilder = require(script.Parent.RoadMeshBuilder)
local RoadRules = require(script.Parent.RoadRules)

local DeadEndRenderer = {}

local UP = Vector3.yAxis
-- ponytail: 18 (was 36) -- 10-degree chords on a bulb this small read round from the city
-- camera at half the geometry. Shared by the cap half-disc, the kerb, and the edge line.
local ARC_STEPS = 18

export type Options = {
	width: number,
	carriagewayWidth: number?,
	laneCount: number?,
	oneWay: boolean?,
	surfaceColor: Color3,
	markingColor: Color3?,
	edgeLineColor: Color3?,
	edgeLineWidth: number?,
	sidewalk: boolean?,
	-- Which half of the bulb the kerb wraps. Left/right are as seen facing outwardDir
	-- (out along the road), so they line up with the segment's own left/right kerbs.
	-- Default true: a road with sidewalks both sides wraps the full turnaround.
	sidewalkRight: boolean?,
	sidewalkLeft: boolean?,
	sidewalkColor: Color3?,
	sidewalkWidth: number?,
	sidewalkHeight: number?,
	groundSkirt: number?,
	anchored: boolean?,
	canCollide: boolean?,
	approachLength: number?,
}

function DeadEndRenderer.build(center: Vector3, outwardDir: Vector3, parent: Instance, options: Options): Model
	local model = Instance.new("Model")
	model.Name = "DeadEnd"
	-- ponytail: ONE dead-end mesh -- cap, curb AND edge line in a single builder/MeshPart.
	local surfaceBuilder = RoadMeshBuilder.new()

	local anchored = if options.anchored == nil then true else options.anchored
	local canCollide = if options.canCollide == nil then true else options.canCollide
	local thickness = RoadConstants.ROAD_THICKNESS
	local radius = options.width * 0.5
	local dir = if outwardDir.Magnitude > 1e-6 then outwardDir.Unit else Vector3.zAxis
	local side = dir:Cross(UP)
	side = if side.Magnitude > 1e-6 then side.Unit else Vector3.xAxis
	local roadUp = side:Cross(dir)
	roadUp = if roadUp.Magnitude > 1e-6 then roadUp.Unit else UP
	if roadUp:Dot(UP) < 0 then
		roadUp = -roadUp
		side = -side
	end
	-- Sink the cap surface a hair BELOW the segment slab top so the segment wins the
	-- overlap. The cap is a full disc that overlaps the segment in a lens shape; if it
	-- sits above, its curved front edge shows as a lip/seam across the open roadway.
	local surfaceDrop = roadUp * 0.012
	local markY = thickness * 0.5 + 0.015 -- ponytail: flush -- paint sits in the surface, not a raised tile
	local markH = 0.05

	-- ponytail: HALF-disc cap baked into the dead-end mesh. The +dir hemisphere always sat
	-- buried under the incoming segment (sunk by surfaceDrop so the segment won the lens
	-- overlap) -- never drawn. Only the -dir bulb shows, so emit just that semicircle as a fan,
	-- plus a small angular lip (capLip) whose flat edge tucks under the segment mouth so there
	-- is no seam. Half the cap geometry, and no separate live Cylinder Part.
	local capTop = center - surfaceDrop + roadUp * (thickness * 0.5)
	local capLip = math.rad(8)
	local capRim = table.create(ARC_STEPS + 1)
	for i = 0, ARC_STEPS do
		local theta = (-math.pi * 0.5 - capLip) + (math.pi + capLip * 2) * (i / ARC_STEPS)
		local radial = -dir * math.cos(theta) + side * math.sin(theta)
		capRim[i + 1] = capTop + radial * radius
	end
	surfaceBuilder:addFan(capTop, capRim, thickness, options.surfaceColor)

	-- Edge line tracing the rim of the turnaround, just inside the curb. ponytail: baked into
	-- the dead-end mesh as a marking ribbon (was two quarter-arc Beams anchored to the cap
	-- Part) -- one polyline along the same semicircle, so it lives and dies with the mesh.
	local edgeColor = options.edgeLineColor
	if edgeColor then
		local edgeWidth = options.edgeLineWidth or 0.4
		-- Match the straight road's edge-line offset (carriageway edge minus half the line width)
		-- so the cap's edge line meets the road's outer line without a step or gap.
		local edgeR = radius - edgeWidth * 0.5 - 0.05
		local edgePts = table.create(ARC_STEPS + 1)
		for i = 0, ARC_STEPS do
			local theta = -math.pi * 0.5 + math.pi * (i / ARC_STEPS)
			local radial = -dir * math.cos(theta) + side * math.sin(theta)
			edgePts[i + 1] = center + radial * edgeR + roadUp * markY
		end
		surfaceBuilder:addMarkingLine(edgePts, edgeWidth, edgeColor, false)
	end

	local sidewalkOn = options.sidewalk ~= false
	-- +side half of the arc (theta > 0) is the right kerb, -side half the left.
	local wrapRight = sidewalkOn and options.sidewalkRight ~= false
	local wrapLeft = sidewalkOn and options.sidewalkLeft ~= false
	local sidewalkColor = options.sidewalkColor or RoadConstants.SIDEWALK_COLOR
	local sidewalkWidth = options.sidewalkWidth or RoadConstants.SIDEWALK_WIDTH
	local sidewalkHeight = options.sidewalkHeight or RoadConstants.SIDEWALK_HEIGHT
	local skirt = options.groundSkirt or 0 -- kerb top unchanged; extends down into the grass
	local prevCurb: Vector3? = nil
	local prevTheta = 0
	for i = 0, ARC_STEPS do
		local theta = -math.pi * 0.5 + math.pi * (i / ARC_STEPS)
		local radial = -dir * math.cos(theta) + side * math.sin(theta)
		local curbPoint = center + radial * (radius + sidewalkWidth * 0.5)
		local spanOn = if (theta + prevTheta) * 0.5 >= 0 then wrapRight else wrapLeft
		prevTheta = theta
		if spanOn and prevCurb then
			local delta = curbPoint - prevCurb
			local len = delta.Magnitude
			if len > 1e-3 then

				local overlap = sidewalkWidth * math.tan((math.pi / ARC_STEPS) * 0.5) + 0.08
				-- Curb sits on the slab top (roadUp * thickness/2), matching the segment
				-- sidewalk. Basing it on capLift alone sank the rim ~thickness/2 below the
				-- segment curb and read as the dead-end being lower than the road.
				local curbCenterUp = roadUp * (thickness * 0.5 + (sidewalkHeight - skirt) * 0.5)
				surfaceBuilder:addBox(CFrame.lookAt((prevCurb + curbPoint) * 0.5 + curbCenterUp, curbPoint + curbCenterUp, roadUp), Vector3.new(sidewalkWidth, sidewalkHeight + skirt, len + overlap + 0.12), sidewalkColor)
			end
		end
		prevCurb = curbPoint
	end

	if not options.oneWay then
		local markingColor = options.markingColor or RoadConstants.MARKING_WHITE
		local laneCount = math.max(2, options.laneCount or 2)
		local markingWidth = options.carriagewayWidth or options.width
		local markingRadius = markingWidth * 0.5
		local laneWidth = markingWidth / laneCount
		local markingBack = math.max(1.4, radius * 0.5) + laneWidth * 0.7
		local driveOnLeft = RoadRules.getDrivingSide() == "left"
		-- max must stay >= min or math.clamp errors. On a thin lane (laneWidth < 10, e.g. an
		-- Alley) laneWidth-1 drops below 9; floor the max at 9 so the clamp is valid. The symbol
		-- is never actually drawn there -- symbolFits below requires laneWidth >= 10 -- so this
		-- only stops the crash that was aborting the whole dead-end node render.
		local symbolWidth = math.clamp(laneWidth * 0.72, 9, math.max(9, laneWidth - 1))
		local symbolLength = math.clamp(laneWidth * 0.85, 12, 16)
		-- Keep the corrected return direction, but center the complete marking
		-- inside its incoming lane instead of spanning the centerline.
		local textureId = if driveOnLeft
			then RoadConstants.ARROW_TEXTURE_UTURN_RIGHT
			else RoadConstants.ARROW_TEXTURE_UTURN_LEFT
		local inboundLaneCount = math.max(1, math.floor(laneCount * 0.5))
		-- DYNAMIC placement: pull the arrow back so it fits between the bulb and whatever the road
		-- runs into (e.g. an intersection), and drop it when there's no room. markingBack is its
		-- distance from the node along the approach; approachLength is the clear room available.
		-- junctionClear holds the arrow's far edge (markingBack + symbolLength*0.65) back from the
		-- approach end so it never floats in the junction the road runs into; if that leaves no room
		-- ahead of the bulb, symbolFits fails and we draw nothing rather than jam it against the junction.
		local approachLen = options.approachLength or math.huge
		local junctionClear = math.max(6, laneWidth * 0.5)  -- TUNABLE: gap kept from the far junction
		markingBack = math.min(markingBack, approachLen - symbolLength * 0.65 - junctionClear)
		-- Fits when the lane is wide enough for the glyph and the pulled-back arrow still clears
		-- the bulb (markingBack shrinks toward the far junction via the clamp above).
		local symbolFits = laneWidth >= 10 and markingBack >= math.max(1.4, radius * 0.5)
		for laneIndex = 1, inboundLaneCount do
			if not symbolFits then break end
			local laneCenter = if driveOnLeft
				then markingRadius - laneWidth * (laneIndex - 0.5)
				else -markingRadius + laneWidth * (laneIndex - 0.5)
			local base = center
				+ dir * (markingBack + symbolLength * 0.15)
				+ side * laneCenter
			local plateCenter = base + roadUp * (markY - markH * 0.5)

			local plate = Instance.new("Part")
			plate.Name = "UTurnArrowTexture"
			plate.Anchored = anchored
			plate.CanCollide = false
			plate.CanTouch = false
			plate.CanQuery = false
			plate.CastShadow = false
			plate.Transparency = 1
			plate.Size = Vector3.new(symbolWidth, markH, symbolLength)
			plate.CFrame = CFrame.lookAt(plateCenter, plateCenter + dir, roadUp)
			plate.Parent = model

			local decal = Instance.new("Decal")
			decal.Name = "UTurnTexture"
			decal.Texture = textureId
			decal.Face = Enum.NormalId.Top
			decal.Color3 = markingColor
			decal.Parent = plate
		end
	end

	-- ponytail: ONE bake -> ONE MeshPart for the whole dead-end (cap, curb, edge line).
	local deadEndMesh = surfaceBuilder:bake({
		name = "DeadEnd",
		anchored = anchored,
		canCollide = canCollide,
		canQuery = false,
	})
	if deadEndMesh then deadEndMesh.Parent = model end

	model.Parent = parent
	return model
end

return DeadEndRenderer
