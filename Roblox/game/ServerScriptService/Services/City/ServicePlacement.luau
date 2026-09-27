--!strict
-- ServicePlacement
-- THE placement pipeline for every service building (schools, hospitals, police,
-- fire, utilities, bus depots): sanitise the client pivot (finite, in bounds, dry),
-- keep X/Z + yaw, re-ground Y, snap to the 0.1 grid, reject overlaps. Charging stays
-- with the caller. Pure library: no state.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
local TerrainConstants = require(ReplicatedStorage.Terrain.TerrainConstants)
local Quant = require(ReplicatedStorage.Shared.Quant)
local PlacementFit = require(ReplicatedStorage.Shared.PlacementFit)
local TerrainDataService = require(ServerScriptService.Services.Terrain.TerrainDataService)

-- Visible water surface, same formula as RoadPlacementController.
local WATERLINE_Y = TerrainConstants.SEA_Y + TerrainConstants.RENDER_BULGE

local ServicePlacement = {}

-- Free placement: sanitised, grounded, quantised pivot -- or a reject reason.
-- `ignoreModel` exempts the building being moved from the overlap test. Does NOT
-- charge; free-placement callers charge only after this passes.
-- `skipOverlap` is for DECORATION: a creation or prop does not reserve ground the way a
-- building does, so refusing it for standing near something is wrong. Everything else --
-- bounds, water, the re-grounded Y, the save-grid snap -- still applies, which is the
-- whole reason to come through here rather than rolling a separate path.
function ServicePlacement.prepareFree(footprint: Vector3, pivotIn: CFrame, ignoreModel: Model?, skipOverlap: boolean?): (CFrame?, string?)
	local p = pivotIn.Position
	if p.X ~= p.X or p.Z ~= p.Z then return nil, "invalid position" end

	local look = pivotIn.LookVector
	local yaw = math.atan2(-look.X, -look.Z)
	if yaw ~= yaw then yaw = 0 end

	-- Bounds are tested against the FOOTPRINT, not the pivot alone. Testing the centre
	-- lets anything wide hang over the map edge, and the bigger it is the further it
	-- overhangs -- fine when everything through here was a building a few lots across,
	-- wrong now that a creation can be hundreds of studs wide. Rotated half-extent,
	-- because the footprint turns with the yaw resolved above.
	local half = RoadConstants.MAP_HALF_EXTENT
	local cosY, sinY = math.abs(math.cos(yaw)), math.abs(math.sin(yaw))
	local hx = cosY * footprint.X * 0.5 + sinY * footprint.Z * 0.5
	local hz = sinY * footprint.X * 0.5 + cosY * footprint.Z * 0.5
	if math.abs(p.X) + hx > half or math.abs(p.Z) + hz > half then
		return nil, "too close to the edge"
	end

	-- Wet means BELOW the waterline and not a player-dug dry pit -- the same idiom
	-- as every other water check (WaterField.isDryAt alone only answers the pit
	-- half; bare, it reads as "everything above sea is water" and blocks the map).
	local groundY = TerrainDataService.getSurfaceY(p.X, p.Z)
	if groundY < WATERLINE_Y and not TerrainDataService.isDryAt(p.X, p.Z) then
		return nil, "can't build in water"
	end

	-- Snap to the 0.1-stud grid: the placed building sits exactly where the
	-- 1-decimal save will put it after a reload.
	local pivot = CFrame.new(Quant.n(p.X), Quant.n(groundY), Quant.n(p.Z)) * CFrame.Angles(0, yaw, 0)

	-- The overlap veto is PlacementFit's, the same test the client ghost turns red on, so a
	-- green ghost is never refused here.
	if not skipOverlap and not PlacementFit.boxFree(pivot, footprint, ignoreModel) then
		return nil, "blocked"
	end

	-- Roads are not in that box query (they bake no queryable geometry), so they get the
	-- analytic test. Same skipOverlap exemption: decoration does not reserve ground.
	if not skipOverlap and PlacementFit.onRoad(pivot, footprint) then
		return nil, "can't build on a road"
	end

	return pivot, nil
end

-- Open water within `margin` studs of the footprint's edge: what a pumping station draws
-- from and an outlet empties into. Sixteen probes round the rim; the footprint itself is
-- already dry (prepareFree refused anything else), so this is "standing on the shore".
function ServicePlacement.touchesWater(pivot: CFrame, footprint: Vector3, margin: number): boolean
	local r = math.max(footprint.X, footprint.Z) * 0.5 + margin
	for i = 0, 15 do
		local a = i * math.pi / 8
		local p = pivot.Position + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)
		if TerrainDataService.getSurfaceY(p.X, p.Z) < WATERLINE_Y and not TerrainDataService.isDryAt(p.X, p.Z) then
			return true
		end
	end
	return false
end

return ServicePlacement
