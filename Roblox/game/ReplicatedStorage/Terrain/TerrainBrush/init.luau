--!strict
-- Pure brush application. Deterministic: same heightmap + stroke -> same result on
-- client and server, so prediction reconciles cheaply. Owns the magnitude clamps
-- (radius/strength/per-tick delta), lock-skip, sea-floor clamp and slope clamp so
-- both sides apply identically. The network boundary (TerrainEditService) handles
-- rejection of malformed input and rate limiting; this module only clamps.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Terrain.TerrainConstants)
local Types = require(ReplicatedStorage.Terrain.TerrainTypes)
local Heightmap = require(ReplicatedStorage.Terrain.Heightmap)

local TerrainBrush = {}

local SPACING = Constants.SAMPLE_SPACING
local MAX_RADIUS = Constants.BRUSH_MAX_RADIUS
local MAX_DELTA = Constants.BRUSH_MAX_DELTA_PER_TICK
local STUDS_PER_SECOND = Constants.BRUSH_STUDS_PER_SECOND
local APPROACH_PER_SECOND = Constants.BRUSH_APPROACH_PER_SECOND
local AUTO_SMOOTH_PER_SECOND = Constants.BRUSH_AUTO_SMOOTH_PER_SECOND
local MAX_DT = Constants.BRUSH_MAX_DT
local NOMINAL_DT = Constants.BRUSH_RATE_INTERVAL
local DIG_FLOOR = Constants.SEA_Y - Constants.MAX_DIG_BELOW_SEA -- deepest a dig may reach
local AUTO = Constants.Material.AUTO
local FLAG_ROAD_GRADED = Constants.Flag.ROAD_GRADED
local MAX_CORNER = Constants.CORNERS_PER_AXIS - 1
local MAX_RISE = math.tan(math.rad(Constants.SLOPE_CLAMP_DEG)) * SPACING
local MATERIAL_WEIGHT_GATE = 0.15

local cornerToWorld = Constants.cornerToWorld
local worldToCorner = Constants.worldToCorner
local rawToWorldY = Constants.rawToWorldY
local worldYToRaw = Constants.worldYToRaw

local function clampNum(v: number, lo: number, hi: number): number
	if v < lo then return lo elseif v > hi then return hi end
	return v
end

type Affected = { { number } } -- list of {gx, gz, weight}

-- Corners within the brush radius, with a smooth falloff weight (1 at centre, 0 at edge).
-- The weight is (1 - t^2)^2, not the plain 1 - t^2 it used to be: both reach zero at the
-- rim, but the plain one still has slope there, so every stroke left a faint crease at the
-- exact radius of the brush and repeated strokes stacked those creases into rings. Squaring
-- takes the slope to zero as well, so the stroke blends into the ground it did not touch.
local function gather(centerX: number, centerZ: number, radius: number): (Affected, number)
	local R = clampNum(radius, SPACING, MAX_RADIUS)
	local gxMin = math.floor(worldToCorner(centerX - R))
	local gxMax = math.ceil(worldToCorner(centerX + R))
	local gzMin = math.floor(worldToCorner(centerZ - R))
	local gzMax = math.ceil(worldToCorner(centerZ + R))
	local out: Affected = {}
	for gz = gzMin, gzMax do
		if gz >= 0 and gz <= MAX_CORNER then
			local wz = cornerToWorld(gz)
			for gx = gxMin, gxMax do
				if gx >= 0 and gx <= MAX_CORNER then
					local wx = cornerToWorld(gx)
					local dx = wx - centerX
					local dz = wz - centerZ
					local d = math.sqrt(dx * dx + dz * dz)
					if d <= R then
						local t = d / R
						local k = 1 - t * t
						out[#out + 1] = { gx, gz, k * k }
					end
				end
			end
		end
	end
	return out, R
end

-- Apply one stroke tick to the heightmap. Returns the number of corners changed.
-- setCorner/setMaterial mark chunks dirty, so the renderer repaints automatically.
function TerrainBrush.apply(hm: Heightmap.Heightmap, stroke: Types.BrushStroke): number
	local corners = gather(stroke.centerX, stroke.centerZ, stroke.radius)
	if #corners == 0 then return 0 end
	local strength = clampNum(stroke.strength, 0, 1)

	if stroke.op == "SetMaterial" then
		local mat = stroke.material or AUTO
		local n = 0
		for _, c in corners do
			if c[3] >= MATERIAL_WEIGHT_GATE then
				hm:setMaterial(c[1], c[2], mat)
				n += 1
			end
		end
		return n
	end

	local function curY(gx: number, gz: number): number
		return rawToWorldY(hm:getCorner(gx, gz))
	end

	-- Per-second, scaled by this tick's own duration. A missing dt means a caller that has
	-- not been updated; one nominal tick keeps it working rather than freezing the brush.
	local dt = clampNum(stroke.dt or NOMINAL_DT, 0, MAX_DT)
	local maxStep = strength * STUDS_PER_SECOND * dt
	-- Proportional ops ease toward their target instead of snapping a fixed fraction each
	-- tick: 1 - e^(-rate*dt) is the frame-rate independent form of "close the remaining gap".
	local approach = 1 - math.exp(-APPROACH_PER_SECOND * strength * dt)

	-- Flatten target: the height picked at gesture start (stroke.target) if given,
	-- else the mean height of the brush area. With a target, holding+dragging levels
	-- everything under the brush to that one height.
	local flattenTarget = stroke.target
	if stroke.op == "Flatten" and flattenTarget == nil then
		local sum = 0
		for _, c in corners do sum += curY(c[1], c[2]) end
		flattenTarget = sum / #corners
	end

	local count = 0
	for _, c in corners do
		local gx, gz, w = c[1], c[2], c[3]
		if not hm:isLocked(gx, gz) then
			local old = curY(gx, gz)
			local delta: number
			if stroke.op == "Raise" then
				delta = maxStep * w
			elseif stroke.op == "Lower" then
				delta = -maxStep * w
			elseif stroke.op == "Flatten" then
				delta = ((flattenTarget or old) - old) * approach * w
			elseif stroke.op == "Level" then
				-- Hard pad: ignore falloff so every corner reaches the same target (crisp
				-- flat area), clamped per tick. Edges are bounded by the slope clamp pass.
				delta = ((stroke.target or old) - old) * approach
			elseif stroke.op == "Smooth" then
				-- Average of the eight neighbours, not the four axis ones. A four-tap average
				-- smooths along the axes and leaves the diagonals alone, so heavy smoothing used
				-- to pull the ground into a faint plus-shaped lattice.
				local axis = curY(gx + 1, gz) + curY(gx - 1, gz) + curY(gx, gz + 1) + curY(gx, gz - 1)
				local diag = curY(gx + 1, gz + 1) + curY(gx - 1, gz - 1) + curY(gx + 1, gz - 1) + curY(gx - 1, gz + 1)
				local avg = (axis * 2 + diag) / 12
				delta = (avg - old) * approach * w
			else
				delta = 0
			end
			-- hard per-tick clamp
			delta = clampNum(delta, -MAX_DELTA, MAX_DELTA)
			local newY = old + delta
			-- Graded road shoulder (unlocked by design): may be lowered or smoothed,
			-- never raised -- a raised shoulder's voxel-smoothing bulge can creep
			-- over the sidewalk and bury the road edge.
			if newY > old and bit32.band(hm:getFlags(gx, gz), FLAG_ROAD_GRADED) ~= 0 then
				newY = old
			end
			-- digging below sea is allowed (carve basins/channels), down to DIG_FLOOR (10 m
			-- under sea). Can't push a corner below its current depth either, so naturally
			-- deep seabed isn't frozen-raised. Which dug pits hold water is decided downstream
			-- by the water-field connectivity, not by clamping the terrain here.
			local floorY = math.min(old, DIG_FLOOR)
			if newY < floorY then newY = floorY end
			hm:setCorner(gx, gz, worldYToRaw(newY))
			count += 1
		end
	end

	-- Auto-smooth, for Raise/Lower only. Digging deposits height wherever the cursor happened
	-- to dwell, and without this a stroke leaves that record behind as lumps. Scaled by the
	-- brush falloff as well as by time, so the rim -- where the brush is barely acting -- is
	-- barely smoothed either, and the stroke still blends into untouched ground.
	--
	-- Flatten and Level are left alone: they exist to produce a crisp result and averaging it
	-- is the opposite of the job. Smooth is already this, only harder.
	--
	-- In place rather than against a snapshot: the corner list is built in a fixed order from
	-- a fixed rect, so both sides walk it identically and the client's prediction still lands
	-- on the server's answer. That determinism is the only reason this is safe to do in place.
	if AUTO_SMOOTH_PER_SECOND > 0 and (stroke.op == "Raise" or stroke.op == "Lower") then
		local blend = 1 - math.exp(-AUTO_SMOOTH_PER_SECOND * dt)
		for _, c in corners do
			local gx, gz, w = c[1], c[2], c[3]
			if not hm:isLocked(gx, gz) then
				local old = curY(gx, gz)
				local axis = curY(gx + 1, gz) + curY(gx - 1, gz) + curY(gx, gz + 1) + curY(gx, gz - 1)
				local diag = curY(gx + 1, gz + 1) + curY(gx - 1, gz - 1) + curY(gx + 1, gz - 1) + curY(gx - 1, gz + 1)
				local target = (axis * 2 + diag) / 12
				local newY = old + (target - old) * blend * w
				if newY < math.min(old, DIG_FLOOR) then newY = math.min(old, DIG_FLOOR) end
				hm:setCorner(gx, gz, worldYToRaw(newY))
			end
		end
	end

	-- Slope clamp (render-safety): one pass clamping each touched, unlocked corner to
	-- within MAX_RISE of its axis neighbours. Best-effort, not exact, but kills cliffs.
	for _, c in corners do
		local gx, gz = c[1], c[2]
		if not hm:isLocked(gx, gz) then
			local y = curY(gx, gz)
			local floorY = math.min(y, DIG_FLOOR)
			for _, n in { curY(gx + 1, gz), curY(gx - 1, gz), curY(gx, gz + 1), curY(gx, gz - 1) } do
				if y - n > MAX_RISE then y = n + MAX_RISE end
			end
			if y < floorY then y = floorY end
			hm:setCorner(gx, gz, worldYToRaw(y))
		end
	end

	return count
end

return TerrainBrush
