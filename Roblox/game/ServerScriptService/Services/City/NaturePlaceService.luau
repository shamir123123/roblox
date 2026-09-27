--!strict
-- NaturePlaceService
-- Server authority for the Nature tab: plants decorative props (trees / bushes / rocks)
-- the client draws in a line or scatters with a brush. Every placement is validated
-- (asset in catalog, position finite + in map bounds), ground-snapped to the authoritative
-- terrain height, rate-limited and capped. The client sends per-placement yaw + scale so
-- its preview matches the result; the server clamps scale to the catalog range.
--
-- Persistence: serialize()/restore() are driven by CitySerializer (nature is part of the
-- saved city blob). The wire format is a flat number array, 5 per prop
-- (keyIndex, x, z, yawDegrees, scalePercent), so it stays compact in DataStore.
--
-- STACKING rides in the SIGN of scalePercent: negative means "this one sat on top of
-- whatever was under it", and restore re-runs the same stack lookup. Widening the stride
-- to 6 would have mis-parsed every city already saved, and a scale is never negative.
-- Restore replays in save order, which is placement order, so a tower rebuilds bottom-up.
-- A stacked prop whose support was bulldozed lands on the terrain on the next load.

local RS  = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")

local Net           = require(RS:WaitForChild("Networker"))
local NatureCatalog  = require(RS:WaitForChild("Nature"):WaitForChild("NatureCatalog"))
local RoadConstants  = require(RS:WaitForChild("Road"):WaitForChild("RoadConstants"))
-- The carriageway rule, shared with the client ghost and with the road tool: it answers
-- both "may this prop stand here" and "which props does this new road cover".
local RoadProximity  = require(RS:WaitForChild("Road"):WaitForChild("RoadProximity"))
local Quant          = require(RS:WaitForChild("Shared"):WaitForChild("Quant"))
local PlacementFit   = require(RS:WaitForChild("Shared"):WaitForChild("PlacementFit"))
local MaterialCatalog = require(RS:WaitForChild("Shared"):WaitForChild("MaterialCatalog"))
-- TerrainDataService is an infra singleton (owns the authoritative heightmap): required
-- directly per the project's dependency rules, never injected.
local TerrainDataService = require(SSS:WaitForChild("Services"):WaitForChild("Terrain"):WaitForChild("TerrainDataService"))
local TerrainPadService = require(SSS:WaitForChild("Services"):WaitForChild("Terrain"):WaitForChild("TerrainPadService"))
local NumberPack = require(SSS:WaitForChild("Services"):WaitForChild("Data"):WaitForChild("NumberPack"))

local NaturePlaceService = {}

local MAX_PER_CALL = 64      -- one line row or one brush burst
local GLOBAL_CAP   = 10000   -- total live nature props (perf guard)
local CALL_COOLDOWN = 0.08   -- seconds between accepted calls, per player
-- What taking a prop back down hands you: nearly all of it, so rearranging what you built
-- costs almost nothing and second-guessing a placement is not punished. Never 100% -- a
-- round trip has to cost something or place/remove is a free way to launder nothing.
-- Deliberately below cost, so no amount of placing and removing can make money.
local REMOVE_REFUND = 0.99

local _templates: Folder = RS.Nature
local _lastCallAt: { [Player]: number } = {}
local _lastRemoveAt: { [Player]: number } = {}
local _roadService: any = nil
local _economyService: any = nil
-- Territory gate (TerritoryService.isPointAllowed), injected by Bootstrap: a player may
-- only plant on land the city owns. No check injected (tests, tooling) means nothing is
-- gated. See plantOne for the two things it deliberately does NOT cover.
local _territoryCheck: ((Vector3) -> boolean)? = nil

-- key -> its index in NatureCatalog.order, so serialize can store a small int per prop.
local _keyIndex: { [string]: number } = {}
for i, k in NatureCatalog.order do _keyIndex[k] = i end

local function natureFolder(): Folder?
	local city = workspace:FindFirstChild("_City")
	if not city then
		-- Matches EducationService/EmergencyService: create the city root if a restore or a
		-- place lands before another service has made it.
		city = Instance.new("Folder")
		city.Name = "_City"
		city.Parent = workspace
	end
	local f = city:FindFirstChild("Nature")
	if not f then
		f = Instance.new("Folder")
		f.Name = "Nature"
		f.Parent = city
	end
	return f :: Folder
end

local function groundY(x: number, z: number): number
	local ok, y = pcall(TerrainDataService.getSurfaceY, x, z)
	if ok and typeof(y) == "number" and y == y then return y end
	return RoadConstants.getGroundY()
end

-- The one place a nature prop's transform is built: the placement codec (1-decimal
-- position, whole-degree yaw) + ground-snapped Y. The live prop is then exactly what
-- serialize() stores and restore() rebuilds -- no messy decimals in the property panel.
--
-- PITCH / ROLL / HEIGHT come from the precise-build gizmo. They are OPTIONAL and default
-- to the flat, ground-seated prop every other path produces, so nothing that places a tree
-- has to know they exist. `yOff` is a delta ABOVE the seat (terrain or the stack below),
-- not an absolute Y -- keeping the seat derived is what lets a saved city re-terrain
-- without every prop ending up buried or floating.
local MAX_Y_OFFSET = 512
local function propPivot(x: number, z: number, yaw: number, y: number?,
	pitch: number?, roll: number?, yOff: number?): CFrame
	local qx, qz = Quant.n(x), Quant.n(z)
	local seatY = (y or groundY(qx, qz)) + math.clamp(yOff or 0, -MAX_Y_OFFSET, MAX_Y_OFFSET)
	local p, r = pitch or 0, roll or 0
	-- snapCF rounds the whole pivot -- including the ground Y -- to the codec grid, so
	-- no axis shows more than one decimal in the property panel. It round-trips through a
	-- YAW-ONLY pack, so a tilted prop has to skip it or the tilt is quietly thrown away.
	if p == 0 and r == 0 then
		return Quant.snapCF(CFrame.new(qx, seatY, qz) * CFrame.Angles(0, yaw, 0))
	end
	return CFrame.new(qx, Quant.n(seatY), qz) * CFrame.fromOrientation(p, yaw, r)
end

-- Whole degrees in, radians out: the gizmo sends radians, the save stores degrees, and
-- both go through here so a malformed number can never reach a CFrame.
local function tilt(v: any): number
	local n = tonumber(v)
	if not n or n ~= n or math.abs(n) >= math.huge then return 0 end
	return math.rad(math.round(math.deg(n)) % 360)
end

local function heightOffset(v: any): number
	local n = tonumber(v)
	if not n or n ~= n then return 0 end
	return Quant.n(math.clamp(n, -MAX_Y_OFFSET, MAX_Y_OFFSET))
end

-- What the cursor is pointing AT: the top of the tallest prop whose footprint contains the
-- point, or nil for open ground. A SURFACE PICK, not a push -- a placement that would end
-- up inside something is refused (see overlapsProp), never shoved out of the way. Props are
-- non-queryable, so this is a scan rather than a raycast.
-- ponytail: O(props) per placement, same accepted cost as BulldozeController's pick.
local function surfaceTopY(folder: Folder, x: number, z: number, skip: Instance?): number?
	local best: number? = nil
	for _, m in folder:GetChildren() do
		if m:IsA("Model") and m ~= skip then
			local cf, size = m:GetBoundingBox()
			-- Strict: the exact edge belongs to the ground, not to the prop. That way you are
			-- either pointing AT something (and land on it) or you are not (and an overlapping
			-- placement is refused) -- never half on, half hanging off.
			if math.abs(cf.Position.X - x) < size.X * 0.5 and math.abs(cf.Position.Z - z) < size.Z * 0.5 then
				local top = cf.Position.Y + size.Y * 0.5
				if not best or top > best then best = top end
			end
		end
	end
	return best
end

-- True if a box of (2*hx, h, 2*hz) standing with its base at y would end up inside a prop
-- that is already there. Touching is not overlapping -- the strict test is what lets a row
-- sit flush and a block sit exactly on the one below it.
local OVERLAP_EPS = 0.05
local function overlapsProp(folder: Folder, x: number, y: number, z: number,
	hx: number, h: number, hz: number, skip: Instance?): boolean
	local cy = y + h * 0.5
	for _, m in folder:GetChildren() do
		if m:IsA("Model") and m ~= skip then
			local cf, size = m:GetBoundingBox()
			if math.abs(cf.Position.X - x) < hx + size.X * 0.5 - OVERLAP_EPS
				and math.abs(cf.Position.Z - z) < hz + size.Z * 0.5 - OVERLAP_EPS
				and math.abs(cf.Position.Y - cy) < h * 0.5 + size.Y * 0.5 - OVERLAP_EPS then
				return true
			end
		end
	end
	return false
end

-- The highest surface any part of a FOOTPRINT is over -- not just its centre point. The
-- probe above answers "what am I pointing AT", which is what the Stack toggle means; this
-- answers "what would this LAND on", which is the difference between a block seating on top
-- of its neighbour and sinking half into it with the other half on the grass.
local function surfaceTopForBox(folder: Folder, x: number, z: number,
	hx: number, hz: number, skip: Instance?): number?
	local best: number? = nil
	for _, m in folder:GetChildren() do
		if m:IsA("Model") and m ~= skip then
			local cf, size = m:GetBoundingBox()
			if math.abs(cf.Position.X - x) < hx + size.X * 0.5 - OVERLAP_EPS
				and math.abs(cf.Position.Z - z) < hz + size.Z * 0.5 - OVERLAP_EPS then
				local top = cf.Position.Y + size.Y * 0.5
				if not best or top > best then best = top end
			end
		end
	end
	return best
end

-- The prop's own X/Z half-extents at a given scale, from its template.
local function halfExtents(template: Model, scale: number): (number, number)
	local _, size = template:GetBoundingBox()
	return size.X * 0.5 * scale, size.Z * 0.5 * scale
end

-- Colour travels as one packed integer so it costs a single slot in the save array.
local function packColor(c: Color3): number
	return math.round(c.R * 255) * 65536 + math.round(c.G * 255) * 256 + math.round(c.B * 255)
end

local function unpackColor(n: number): Color3
	local v = math.clamp(math.floor(n), 0, 16777215)
	return Color3.fromRGB(v // 65536, (v // 256) % 256, v % 256)
end

-- Material override. Index 0 means "the template's own", and there is no way back to it
-- inside a session -- a restore rebuilds from the template, which is the only place the
-- original materials exist.
-- ponytail: no per-part original stashed; the picker only ever sets a real material.
local function surface(model: Model, matIdx: number)
	local mat = MaterialCatalog.get(matIdx)
	if not mat then return end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then (d :: BasePart).Material = mat end
	end
	model:SetAttribute("NatureMaterial", matIdx)
end

-- Collisions are exactly reversible, because they have to be: these templates are mixed
-- (a palm's trunk collides and its crown does not), so "put it back" cannot mean "true".
-- The original rides on the part until it is restored.
local function setCollide(model: Model, collide: boolean)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			local part = d :: BasePart
			if not collide then
				if part:GetAttribute("BaseCollide") == nil then part:SetAttribute("BaseCollide", part.CanCollide) end
				part.CanCollide = false
			else
				local base = part:GetAttribute("BaseCollide")
				if typeof(base) == "boolean" then
					part.CanCollide = base :: boolean
					part:SetAttribute("BaseCollide", nil)
				end
			end
		end
	end
	model:SetAttribute("NatureNoCollide", if not collide then true else nil)
end

-- A shape primitive is a Model wrapping exactly ONE BasePart. That is what makes a
-- ONE-SIDED resize possible at all: the part is stretched per axis, where a Model can only
-- ever be scaled as a whole. Anything with two parts in it scales uniformly and that is the
-- end of it.
local MIN_STRETCH, MAX_STRETCH = 0.05, 20
local function solePart(model: Model): BasePart?
	local found: BasePart? = nil
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			if found then return nil end
			found = d :: BasePart
		end
	end
	return found
end

local function validStretch(v: any): Vector3?
	if typeof(v) ~= "Vector3" then return nil end
	local s = v :: Vector3
	if s ~= s then return nil end
	local c = Vector3.new(
		math.clamp(s.X, MIN_STRETCH, MAX_STRETCH),
		math.clamp(s.Y, MIN_STRETCH, MAX_STRETCH),
		math.clamp(s.Z, MIN_STRETCH, MAX_STRETCH)
	)
	return if (c - Vector3.one).Magnitude < 1e-4 then nil else c
end

-- Set the prop's TOTAL stretch (not a delta): the part goes back to the size its scale
-- alone would give, then out again by `total`. Idempotent, so replaying a save lands on
-- exactly the live prop.
local function applyStretch(model: Model, total: Vector3)
	local part = solePart(model)
	if not part then return end
	local p = part :: BasePart
	local prev = p:GetAttribute("NatureStretchApplied")
	local base = if typeof(prev) == "Vector3" then p.Size / (prev :: Vector3) else p.Size
	p.Size = base * total
	p:SetAttribute("NatureStretchApplied", total)
	-- Resizing a part does not move the model's pivot, and these templates pivot on the BASE
	-- centre so a prop sits ON the ground. Re-seat it, or a stretched prop floats or sinks by
	-- half of whatever it grew.
	model.WorldPivot = CFrame.new(p.CFrame.Position - p.CFrame.UpVector * (p.Size.Y * 0.5))
		* model:GetPivot().Rotation
	model:SetAttribute("NatureStretch", total)
end

local function materialIndex(v: any): number
	local n = tonumber(v)
	if not n or n ~= n then return 0 end
	n = math.floor(n)
	return if MaterialCatalog.order[n] then n else 0
end

-- See-through, 0..0.9 in twentieths (never fully invisible: a prop you cannot see is a prop
-- you cannot click to get back). Each part keeps its baked transparency as a FLOOR, so glass
-- in a template never turns solid, and that floor is stashed like BaseCollide above.
local MAX_TRANSPARENCY = 0.9
local function validTransparency(v: any): number?
	local n = tonumber(v)
	if not n or n ~= n then return nil end
	return math.round(math.clamp(n, 0, MAX_TRANSPARENCY) * 20) / 20
end

local function fade(model: Model, t: number)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			local part = d :: BasePart
			local base = part:GetAttribute("BaseTransparency")
			if typeof(base) ~= "number" then
				base = part.Transparency
				part:SetAttribute("BaseTransparency", base)
			end
			part.Transparency = math.max(base :: number, t)
		end
	end
	model:SetAttribute("NatureTransparency", if t > 0 then t else nil)
end

local function paint(model: Model, packed: number)
	local c = unpackColor(packed)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then d.Color = c end
	end
	model:SetAttribute("NatureColor", packed)
end

-- A car park is a slab, not a shrub: flatten the ground under it the way a building does,
-- or a corner of it hangs in the air on any slope. The pad id comes from the placed
-- position, which the codec has already quantised -- so a reload re-pads exactly the same
-- ground, and a bulldoze can release it without persisting anything extra.
local function isLot(model: Model): boolean
	local key = model:GetAttribute("NatureKey")
	local entry = if typeof(key) == "string" then NatureCatalog.get(key) else nil
	return entry ~= nil and entry.kind == "Lot"
end

local function lotPadId(pos: Vector3): string
	return string.format("natlot:%.1f_%.1f", pos.X, pos.Z)
end

local function padLot(model: Model)
	local pv = model:GetPivot()
	local _, size = model:GetBoundingBox()
	TerrainPadService.padFootprint(lotPadId(pv.Position), pv, size.X, size.Z, pv.Position.Y)
end

local function unpadLot(model: Model)
	TerrainPadService.unpadFootprint(lotPadId(model:GetPivot().Position))
end

local function validPos(pos: any): boolean
	if typeof(pos) ~= "Vector3" or pos ~= pos or pos.Magnitude >= math.huge then return false end
	local h = RoadConstants.MAP_HALF_EXTENT
	return math.abs(pos.X) <= h and math.abs(pos.Z) <= h
end

local function plantOne(folder: Folder, item: any)
	if typeof(item) ~= "table" then return false end
	local entry = typeof(item.key) == "string" and NatureCatalog.get(item.key) or nil
	if not entry then return false end
	if not validPos(item.pos) then return false end
	local yaw = tonumber(item.yaw)
	if not yaw or yaw ~= yaw then return false end
	local scale = tonumber(item.scale) or 1
	scale = Quant.n(math.clamp(scale, entry.minScale, entry.maxScale))

	local pos = item.pos :: Vector3
	local template = _templates:FindFirstChild(entry.key)
	if not (template and template:IsA("Model")) then return false end

	-- You may only plant on land the city owns. TWO deliberate exemptions: `wild` is the
	-- map's OWN vegetation (MapSeedService), which grows across the whole map including
	-- ground nobody has bought -- a forest is not a thing the player placed -- and `free`
	-- covers restore, where a saved prop was legal when it was planted.
	-- A third: build SHAPES go anywhere on the map. The ghost never knew about land, so a
	-- block over unbought ground previewed green and the click vanished -- "I can only place
	-- in some areas". A building block is decoration, not a claim on the land.
	if item.free ~= true and item.wild ~= true and entry.kind ~= "Shape" and _territoryCheck
		and not _territoryCheck(pos) then
		return false
	end

	-- Roads, buildings and other props are exclusion zones UNLESS the item is flagged free.
	-- Free Placement (ReplicatedStorage.Shared.FreePlacement) is a sandbox build toggle the
	-- player drives, so the client says which placements it covers -- there is no server
	-- state to consult. Everything else guarding this remote still applies: catalog, map
	-- bounds, scale clamp, rate limit, global cap.
	-- The road test lives here because it is judged on the CURSOR point; buildings and props
	-- are judged further down, on the seat the placement actually lands on.
	if item.free ~= true then
		local footprint = entry.radius * scale
		-- The prop's HEIGHT goes with it: seated on ground under an elevated deck, a tree
		-- cleared the road test on the base alone and grew up through the carriageway.
		local _, bbox = template:GetBoundingBox()
		if _roadService and _roadService.isPointNearRoad(pos, footprint, bbox.Y * scale) then return false end
	end

	-- Stack ON means "sit on the surface under the cursor and never end up inside anything":
	-- the Y comes from whatever the point is over, and a placement that would still overlap
	-- is REFUSED rather than pushed clear. Open ground falls through to the terrain, so a
	-- stack click on empty land behaves exactly like a normal one.
	-- A car park is a footprint the size of a building, so it obeys the overlap rule whether
	-- or not the placement is a stack -- props may sit inside each other, lots may not. The
	-- client tints the ghost red on the same test, so a refusal here is never a surprise.
	-- `free` covers restore as well as the sandbox toggle, so a reload never drops a lot for
	-- overlapping a tree that was planted inside it after the fact.
	if entry.kind == "Lot" and item.free ~= true then
		local qx, qz = Quant.n(pos.X), Quant.n(pos.Z)
		local hx, hz = halfExtents(template, scale)
		local _, tsize = template:GetBoundingBox()
		local gy = groundY(qx, qz)
		-- The SAME ground test every other placeable goes through, on the lot's real
		-- footprint: the point probe above is 3 studs and a large car park covers sixty, so
		-- one could be dropped straight onto a hospital. Roads are exempt -- the road probe
		-- above owns that, loosely on purpose, so a lot may sit against its own kerb.
		if not PlacementFit.boxFree(
			CFrame.new(qx, gy, qz) * CFrame.Angles(0, yaw, 0),
			Vector3.new(hx * 2, tsize.Y * scale, hz * 2),
			PlacementFit.roadsFolder()
		) then
			return false
		end
		if overlapsProp(folder, qx, gy, qz, hx, tsize.Y * scale, hz) then return false end
	end

	local stacked = item.stack == true
	-- A SHAPE with collisions ON rides ON TOP of whatever is under it rather than sinking
	-- into it. It is NOT a refusal: being told "no" when you aimed at the top of a block is
	-- worse than useless, and going on top is what you meant. Collisions OFF passes through.
	local autoStack = entry.kind == "Shape" and item.collide ~= false and item.free ~= true
	local atY: number? = nil
	if stacked or autoStack then
		local qx, qz = Quant.n(pos.X), Quant.n(pos.Z)
		if autoStack then
			-- The WHOLE footprint, at the size it will actually be. A centre-point probe seated
			-- a block on the grass whenever the cursor was a stud outside its neighbour's
			-- edge -- half in, half out, with collisions supposedly on.
			local _, tsize = template:GetBoundingBox()
			local st = validStretch(item.stretch) or Vector3.one
			atY = surfaceTopForBox(folder, qx, qz,
				tsize.X * 0.5 * scale * st.X, tsize.Z * 0.5 * scale * st.Z)
		else
			-- The Stack TOGGLE means "sit on what I am pointing at", so it stays a point probe
			-- -- and it still REFUSES a placement that would end up inside something even after
			-- seating. Auto-stack never refuses: it is the default, and a default that says no
			-- is a wall.
			atY = surfaceTopY(folder, qx, qz)
			local hx, hz = halfExtents(template, scale)
			local _, tsize = template:GetBoundingBox()
			if overlapsProp(folder, qx, atY or groundY(qx, qz), qz, hx, tsize.Y * scale, hz) then
				return false
			end
		end
	end

	-- Nothing goes inside a building, and nothing goes inside another prop. Both are asked
	-- of the world through PlacementFit, which is the same module (and the same answer) the
	-- client tints its ghost red from -- so a refusal here is never a surprise. Judged on the
	-- SEAT rather than the cursor point: a stacked or auto-stacked placement lands somewhere
	-- the raw click Y never described, which is also what keeps a block stacked on a block
	-- legal. A car park has its own stricter box test above and is not asked twice.
	if item.free ~= true and entry.kind ~= "Lot" then
		local qx, qz = Quant.n(pos.X), Quant.n(pos.Z)
		local seat = Vector3.new(qx, atY or groundY(qx, qz), qz)
		local _, tsize = template:GetBoundingBox()
		local r, h = entry.radius * scale, tsize.Y * scale
		local box = Vector3.new(r * 2, h, r * 2)
		if PlacementFit.buildingAt(CFrame.new(seat) * CFrame.Angles(0, yaw, 0), box) then return false end
		if PlacementFit.propAt(seat, r, h) then return false end
	end

	local pitch, roll = tilt(item.pitch), tilt(item.roll)
	-- Height arrives ABSOLUTE (`y`) and is stored as an offset above the seat, exactly as the
	-- move handler does it. Without this a placement ignored the height it was given and fell
	-- to the terrain -- so stamping a copy of a prop you had lifted dropped it on the ground.
	-- The server owns the seat, so the server does the subtraction.
	local yOff = heightOffset(item.yOffset)
	if item.y ~= nil then
		local want = tonumber(item.y)
		local seat = atY or groundY(Quant.n(pos.X), Quant.n(pos.Z))
		yOff = if want and want == want then heightOffset(want - seat) else yOff
	end

	local clone = template:Clone()
	-- Template scale bakes the base-height normalisation; multiply in the jitter.
	clone:ScaleTo(Quant.n(clone:GetScale() * scale))
	clone:PivotTo(propPivot(pos.X, pos.Z, yaw, atY, pitch, roll, yOff))
	clone:SetAttribute("NatureKey", entry.key)
	clone:SetAttribute("NatureScale", scale) -- stored so serialize round-trips the exact size
	-- Auto-stacked props are marked stacked too, or a reload would seat them on the TERRAIN
	-- plus an offset that was measured from the top of the block they were standing on.
	clone:SetAttribute("NatureStacked", (stacked or autoStack) or nil)
	-- nil rather than 0 for the flat case: every prop placed by every other tool then
	-- carries no new attributes at all.
	clone:SetAttribute("NaturePitch", if pitch ~= 0 then pitch else nil)
	clone:SetAttribute("NatureRoll", if roll ~= 0 then roll else nil)
	clone:SetAttribute("NatureYOffset", if yOff ~= 0 then yOff else nil)
	local matIdx = materialIndex(item.material)
	if matIdx > 0 then surface(clone, matIdx) end
	if item.collide == false then setCollide(clone, false) end
	local stretch = validStretch(item.stretch)
	if stretch then
		-- After the first PivotTo, because stretching moves the pivot; the second seats the
		-- re-based pivot on the ground again.
		applyStretch(clone, stretch)
		clone:PivotTo(propPivot(pos.X, pos.Z, yaw, atY, pitch, roll, yOff))
	end
	-- Recolour is opt-in: an item with no colour keeps the template's own, so trees stay
	-- green and a shape stays the grey it was baked at.
	if typeof(item.color) == "Color3" then
		paint(clone, packColor(item.color :: Color3))
	elseif typeof(item.color) == "number" then
		paint(clone, item.color :: number)
	end
	local seeThrough = validTransparency(item.transparency)
	if seeThrough and seeThrough > 0 then fade(clone, seeThrough) end
	CollectionService:AddTag(clone, "NatureProp")
	clone.Parent = folder
	if entry.kind == "Lot" then padLot(clone) end
	return true
end

-- Flatten every live prop to (keyIndex, x, z, yawDeg, scalePct, packedColor). Positions are
-- the codec's 1 decimal, yaw a whole degree, and Y re-ground-snaps on restore so it's never
-- stored -- matches propPivot, so the saved prop is exactly the live one.
--
-- The array opens with FORMAT_V2, which a keyIndex can never be (they start at 1), so a
-- city saved under the original 5-number stride is still read correctly -- see restore.
local FORMAT_V2 = -2
local STRIDE_V2 = 6
local FORMAT_V3 = -3
-- V2's six, then pitchDeg, rollDeg, yOffset, material, stretchX/Y/Z. The material slot's
-- SIGN carries "collisions off" -- the same trick the scale slot uses for stacking, and a
-- prop never needs more than one bit of collision state. Stretch is three per-axis PERCENTS
-- on top of the uniform scale: one number could never describe a box pulled out on one side.
local STRIDE_V3 = 13
-- V3's thirteen, then transparency as a whole percent.
local FORMAT_V4 = -4
local STRIDE_V4 = 14
local NO_COLOR = -1 -- keep the template's own colours

-- The V4 array packs to a NumberPack buffer: every value x10 (positions carry one decimal,
-- the rest are whole) and column by column. Free-standing props sort by X so that column
-- packs as small gaps; STACKED props follow in placement order, because restore replays in
-- order and a stack has to rebuild bottom-up on whatever it stood on.
local function packProps(flat: { number }): any
	local free: { { number } }, stacked: { { number } } = {}, {}
	for i = 2, #flat, STRIDE_V4 do
		local row = table.move(flat, i, i + STRIDE_V4 - 1, 1, {})
		if row[5] < 0 then table.insert(stacked, row) else table.insert(free, row) end
	end
	table.sort(free, function(a, b) return a[2] < b[2] end)
	local ints: { number } = {}
	for _, list in { free, stacked } do
		for _, row in list do
			for _, v in row do
				local t = math.round(v * 10)
				-- Off the 0.1 grid, x10 would drop a digit: keep the plain array instead.
				if math.abs(t - v * 10) > 1e-6 then return flat end
				table.insert(ints, t)
			end
		end
	end
	return NumberPack.pack(ints, STRIDE_V4, 2) or flat
end

local function unpackProps(b: buffer): { number }?
	local ints = NumberPack.unpack(b, STRIDE_V4, 2)
	if not ints then return nil end
	local flat = table.create(#ints + 1)
	flat[1] = FORMAT_V4
	for i, t in ints do flat[i + 1] = t / 10 end
	return flat
end

function NaturePlaceService.serialize(): any
	local city = workspace:FindFirstChild("_City")
	local f = city and city:FindFirstChild("Nature")
	if not (f and f:IsA("Folder")) then return {} end
	local out: { number } = { FORMAT_V4 }
	for _, m in f:GetChildren() do
		if m:IsA("Model") then
			local key = m:GetAttribute("NatureKey")
			local kIdx = typeof(key) == "string" and _keyIndex[key] or nil
			if kIdx then
				local pv = m:GetPivot()
				local pos = pv.Position
				local _, ry = pv:ToOrientation()
				local scale = m:GetAttribute("NatureScale")
				local s = if typeof(scale) == "number" then scale else 1
				local col = m:GetAttribute("NatureColor")
				table.insert(out, kIdx)
				table.insert(out, Quant.n(pos.X))
				table.insert(out, Quant.n(pos.Z))
				table.insert(out, math.round(math.deg(ry)) % 360)
				local pct = math.round(s * 100)
				table.insert(out, if m:GetAttribute("NatureStacked") == true then -pct else pct)
				table.insert(out, if typeof(col) == "number" then col else NO_COLOR)
				-- Read back off the ATTRIBUTES, not off the live pivot: the pivot's Y is the
				-- terrain seat plus the offset, and only the offset is ours to store.
				local pit = m:GetAttribute("NaturePitch")
				local rol = m:GetAttribute("NatureRoll")
				local yo = m:GetAttribute("NatureYOffset")
				table.insert(out, if typeof(pit) == "number" then math.round(math.deg(pit)) % 360 else 0)
				table.insert(out, if typeof(rol) == "number" then math.round(math.deg(rol)) % 360 else 0)
				table.insert(out, if typeof(yo) == "number" then Quant.n(yo) else 0)
				local mi = m:GetAttribute("NatureMaterial")
				local mv = if typeof(mi) == "number" then mi else 0
				table.insert(out, if m:GetAttribute("NatureNoCollide") == true then -(mv + 1) else mv)
				local st = m:GetAttribute("NatureStretch")
				local sv = if typeof(st) == "Vector3" then st :: Vector3 else Vector3.one
				table.insert(out, math.round(sv.X * 100))
				table.insert(out, math.round(sv.Y * 100))
				table.insert(out, math.round(sv.Z * 100))
				local tr = m:GetAttribute("NatureTransparency")
				table.insert(out, if typeof(tr) == "number" then math.round(tr * 100) else 0)
			end
		end
	end
	-- An empty city serializes as nothing at all, not a lone version marker.
	return if #out == 1 then {} else packProps(out)
end

-- Rebuild from a serialize() array. Reuses plantOne (validate + ground-snap + cap), so a
-- corrupt/oversized blob can't spawn anything the live tool couldn't. Time-sliced: yields
-- every RESTORE_SLICE props so a big forest doesn't hitch the load frame.
local RESTORE_SLICE = 200
function NaturePlaceService.restore(data: any)
	local folder = natureFolder()
	if not folder then return end
	for _, m in folder:GetChildren() do
		if m:IsA("Model") then
			-- Release the old city's car-park pads before the new one lays its own, or the
			-- flattened ground outlives the lot that asked for it.
			if isLot(m) then unpadLot(m) end
			m:Destroy()
		end
	end
	if typeof(data) == "buffer" then
		data = unpackProps(data)
		if not data then
			warn("[NaturePlaceService] saved nature section is corrupt; no props restored")
			return
		end
	end
	if typeof(data) ~= "table" then return end
	local n = #data
	local v4 = data[1] == FORMAT_V4
	-- v3 means "has V3's fields", which V4 does too.
	local v3 = v4 or data[1] == FORMAT_V3
	local v2 = data[1] == FORMAT_V2
	-- Four generations read here, one written. A keyIndex starts at 1, so a negative first
	-- element can only ever be a version marker -- which is what lets the stride grow without
	-- mis-parsing a single already-saved city.
	local stride = if v4 then STRIDE_V4 elseif v3 then STRIDE_V3 elseif v2 then STRIDE_V2 else 5
	local placed = 0
	local i = if (v3 or v2) then 2 else 1
	while i + stride - 1 <= n and placed < GLOBAL_CAP do
		local kIdx = data[i]
		local key = typeof(kIdx) == "number" and NatureCatalog.order[kIdx] or nil
		if key then
			local pct = tonumber(data[i + 4]) or 100
			local col = if (v3 or v2) then tonumber(data[i + 5]) or NO_COLOR else NO_COLOR
			-- Slot 10: material index, negative when collisions are off. The negative form is
			-- one PAST the index so -1 can mean "no material AND no collisions".
			local packedMat = if v3 then tonumber(data[i + 9]) or 0 else 0
			local matIdx = if packedMat < 0 then -packedMat - 1 else packedMat
			local collides: boolean? = if packedMat < 0 then false else nil
			local stretch: Vector3? = nil
			if v3 then
				stretch = validStretch(Vector3.new(
					(tonumber(data[i + 10]) or 100) / 100,
					(tonumber(data[i + 11]) or 100) / 100,
					(tonumber(data[i + 12]) or 100) / 100
				))
			end
			local ok, planted = pcall(plantOne, folder, {
				key = key,
				pos = Vector3.new(tonumber(data[i + 1]) or 0, 0, tonumber(data[i + 2]) or 0),
				yaw = math.rad(tonumber(data[i + 3]) or 0),
				scale = math.abs(pct) / 100,
				stack = pct < 0,
				-- Free: a saved prop was legal when it was placed, so a load never silently
				-- drops it because a road went in over it afterwards.
				free = true,
				color = if col >= 0 then col else nil,
				pitch = if v3 then math.rad(tonumber(data[i + 6]) or 0) else 0,
				roll = if v3 then math.rad(tonumber(data[i + 7]) or 0) else 0,
				yOffset = if v3 then tonumber(data[i + 8]) or 0 else 0,
				material = matIdx,
				collide = collides,
				stretch = stretch,
				transparency = if v4 then (tonumber(data[i + 13]) or 0) / 100 else nil,
			})
			if ok and planted then
				placed += 1
				if placed % RESTORE_SLICE == 0 then task.wait() end
			end
		end
		i += stride
	end
end

-- Bulk planting with no player behind it: the map's own trees and rocks, laid down once
-- when a city is created (MapSeedService). Nothing is charged -- the land came with them --
-- and every item still goes through plantOne, so a prop the highway already covers, or one
-- standing inside another prop, is refused here exactly as the tool's would be.
function NaturePlaceService.scatter(items: { any }, slice: number?): number
	local folder = natureFolder()
	if not folder or typeof(items) ~= "table" then return 0 end
	local every = math.max(1, math.floor(tonumber(slice) or RESTORE_SLICE))
	local budget = GLOBAL_CAP - #folder:GetChildren()
	local placed = 0
	for _, item in items do
		if budget <= 0 then break end
		local ok, planted = pcall(plantOne, folder, item)
		if ok and planted then
			placed += 1
			budget -= 1
			if placed % every == 0 then task.wait() end
		end
	end
	return placed
end

-- A ROAD WINS. Planting a tree on a carriageway is refused; laying a carriageway over one
-- removes it -- both off the same RoadProximity rule, so the white highlight the road ghost
-- puts on a doomed prop is exactly the set that disappears when the road goes down.
-- No refund: the ground a new road takes is part of the road's own price, the same deal a
-- building demolished under new pavement gets.
-- Injected into RoadService by Bootstrap alongside the building clearance; interactive
-- placement only, so loading a city never clears its own trees.
function NaturePlaceService.clearUnderPavement(segments: any?, disc: { center: Vector3, radius: number }?): number
	local folder = natureFolder()
	if not folder then return 0 end
	local doomed = if disc
		then RoadProximity.propsInDisc(folder, disc.center, disc.radius)
		else RoadProximity.propsOnRoads(folder, segments or {})
	for _, m in doomed do
		if isLot(m) then unpadLot(m) end
		m:Destroy()
	end
	return #doomed
end

function NaturePlaceService.setTerritoryCheck(fn: ((Vector3) -> boolean)?)
	_territoryCheck = fn
end

function NaturePlaceService.Init(roadService: any, economyService: any)
	assert(roadService, "[NaturePlaceService] requires RoadService")
	assert(economyService, "[NaturePlaceService] requires CityEconomyService")
	_roadService = roadService
	_economyService = economyService
end

function NaturePlaceService.Bind()
	Net.RequestPlaceNature.OnServerEvent:Connect(function(player: Player, items: any)
		local now = os.clock()
		local last = _lastCallAt[player]
		if last and now - last < CALL_COOLDOWN then return end
		_lastCallAt[player] = now

		if typeof(items) ~= "table" then return end
		local n = #items
		if n == 0 or n > MAX_PER_CALL then return end

		local folder = natureFolder()
		if not folder then return end
		local budget = GLOBAL_CAP - #folder:GetChildren()
		if budget <= 0 then return end

		-- Each prop is paid for up front (trySpend is atomic against the treasury) and
		-- refunded if the placement itself is rejected. One aggregate "-$X" tag per call.
		local charged = 0
		local chargePos: Vector3? = nil
		for _, item in items do
			if budget <= 0 then break end
			local entry = if typeof(item) == "table" and typeof(item.key) == "string" then NatureCatalog.get(item.key) else nil
			if not entry then continue end
			if not _economyService.trySpend(entry.cost) then break end
			local ok, planted = pcall(plantOne, folder, item)
			if ok and planted then
				budget -= 1
				charged += entry.cost
				chargePos = item.pos :: Vector3
			else
				_economyService.credit(entry.cost)
			end
		end
		if charged > 0 and chargePos then
			local pos = chargePos :: Vector3
			-- To the placer only: the cost tag and the planting sound are their feedback, not
			-- an event every player in the city should see and hear. The tree replicates.
			Net.PlacementCharged:FireClient(player, Vector3.new(pos.X, groundY(pos.X, pos.Z), pos.Z), charged, "Nature")
		end
	end)

	-- Bulldozer removal: client sends the planted models to destroy. Only instances that
	-- are still children of this city's Nature folder AND carry the NatureProp tag are
	-- touched -- a spoofed instance ref outside the folder is ignored.
	Net.RequestRemoveNature.OnServerEvent:Connect(function(player: Player, list: any)
		local now = os.clock()
		local last = _lastRemoveAt[player]
		if last and now - last < CALL_COOLDOWN then return end
		_lastRemoveAt[player] = now

		if typeof(list) ~= "table" then return end
		local n = #list
		if n == 0 or n > MAX_PER_CALL then return end

		local folder = natureFolder()
		if not folder then return end
		-- Removing REFUNDS. The catalog cost is the only price a prop ever had, and the key
		-- rides on the instance the server is about to destroy, so nothing here is taken from
		-- the client. One credit for the whole call rather than one per prop: a box selection
		-- is one action to the player.
		local refund = 0
		for _, inst in list do
			if typeof(inst) == "Instance" and inst.Parent == folder
				and CollectionService:HasTag(inst, "NatureProp") then
				local key = inst:GetAttribute("NatureKey")
				local entry = if typeof(key) == "string" then NatureCatalog.get(key) else nil
				if entry then refund += entry.cost * REMOVE_REFUND end
				if inst:IsA("Model") and isLot(inst) then unpadLot(inst) end
				inst:Destroy()
			end
		end
		if refund >= 1 and _economyService then _economyService.credit(math.floor(refund)) end
	end)

	-- Move tool: re-pivot planted props. Same rules as planting -- the prop must still
	-- be a tagged child of this city's Nature folder, the new spot must be in bounds and
	-- clear of roads/buildings, and Y re-snaps to the authoritative terrain.
	Net.RequestMoveNature.OnServerEvent:Connect(function(player: Player, list: any)
		local now = os.clock()
		local last = _lastCallAt[player]
		if last and now - last < CALL_COOLDOWN then return end
		_lastCallAt[player] = now

		if typeof(list) ~= "table" then return end
		local n = #list
		if n == 0 or n > MAX_PER_CALL then return end

		local folder = natureFolder()
		if not folder then return end
		for _, item in list do
			if typeof(item) ~= "table" then continue end
			local inst = item.inst
			if typeof(inst) ~= "Instance" or inst.Parent ~= folder or not inst:IsA("Model")
				or not CollectionService:HasTag(inst, "NatureProp") then continue end
			if not validPos(item.pos) then continue end
			local yaw = tonumber(item.yaw)
			if not yaw or yaw ~= yaw then continue end
			local key = inst:GetAttribute("NatureKey")
			local entry = if typeof(key) == "string" then NatureCatalog.get(key) else nil
			if not entry then continue end
			local scale = tonumber(inst:GetAttribute("NatureScale")) or 1
			-- Optional resize / repaint. The Move tool's gizmo sends these alongside the new
			-- pivot, so moving, turning, sizing and painting a placed prop are one round trip
			-- and one validation path rather than four remotes.
			local wantScale = tonumber(item.scale)
			if wantScale and wantScale == wantScale then
				local s = Quant.n(math.clamp(wantScale, entry.minScale, entry.maxScale))
				if s ~= scale and scale > 0 then
					inst:ScaleTo(Quant.n(inst:GetScale() * (s / scale)))
					inst:SetAttribute("NatureScale", s)
					scale = s
				end
			end
			if typeof(item.color) == "Color3" then
				paint(inst, packColor(item.color :: Color3))
			end
			-- Both optional and both sticky, same as the tilt below: a tool that does not send
			-- them leaves the prop's own material and collision state alone.
			if item.material ~= nil then
				local m = materialIndex(item.material)
				if m > 0 then surface(inst, m) end
			end
			if typeof(item.collide) == "boolean" then setCollide(inst, item.collide :: boolean) end
			if item.transparency ~= nil then
				local t = validTransparency(item.transparency)
				if t then fade(inst, t) end
			end
			-- The gizmo sends a stretch RELATIVE to the size it grabbed, so it multiplies into
			-- whatever the prop already carries. Stored as the running total.
			local delta = validStretch(item.stretch)
			if delta then
				local held = inst:GetAttribute("NatureStretch")
				local base = if typeof(held) == "Vector3" then held :: Vector3 else Vector3.one
				applyStretch(inst, validStretch(base * delta) or Vector3.one)
			end
			local pos = item.pos :: Vector3
			local footprint = entry.radius * scale
			-- Post-resize bounds: the scale knob above has already been applied to `inst`.
			local _, mbox = inst:GetBoundingBox()
			if _roadService and _roadService.isPointNearRoad(pos, footprint, mbox.Y) then continue end
			-- The same building question a fresh placement answers, asked of the world rather
			-- than of one service's record -- so dragging a prop onto a school is refused the
			-- way planting one there is. Prop-on-prop is deliberately NOT asked: see below,
			-- a drag you cannot finish leaves the prop stuck where it was.
			if PlacementFit.buildingAt(CFrame.new(pos) * CFrame.Angles(0, yaw, 0),
				Vector3.new(footprint * 2, mbox.Y, footprint * 2)) then continue end
			-- A stacked prop keeps stacking: it re-seats on whatever is under the NEW spot
			-- (itself excluded), so dragging one off its tower drops it to the ground. Landing
			-- inside another prop is refused here too, the same as a fresh placement.
			local atY: number? = nil
			if inst:GetAttribute("NatureStacked") == true then
				-- Re-seats on whatever is under the NEW spot, itself excluded, so dragging one
				-- off its tower drops it to the ground. It no longer REFUSES a drag that would
				-- clip something: a move you cannot finish is a prop stuck where it was, and the
				-- player is looking straight at where they want it.
				atY = surfaceTopY(folder, Quant.n(pos.X), Quant.n(pos.Z), inst)
			end
			-- Tilt and height are OPTIONAL on the wire and STICKY on the prop: the city Move
			-- tool sends a pivot and a yaw and nothing else, and a prop it drags must keep the
			-- tilt the precise gizmo gave it rather than being quietly flattened.
			local pitch = if item.pitch ~= nil then tilt(item.pitch) else (tonumber(inst:GetAttribute("NaturePitch")) or 0)
			local roll = if item.roll ~= nil then tilt(item.roll) else (tonumber(inst:GetAttribute("NatureRoll")) or 0)
			-- Height arrives ABSOLUTE (`y`) and is stored as an offset above the seat. The
			-- client has no authoritative heightmap, so making it subtract the terrain itself
			-- would put a client guess into a persisted number; the server owns the seat and
			-- does the subtraction here, where it is exact by construction.
			local yOff: number
			if item.y ~= nil then
				local want = tonumber(item.y)
				local seat = atY or groundY(Quant.n(pos.X), Quant.n(pos.Z))
				yOff = if want and want == want then heightOffset(want - seat) else 0
			elseif item.yOffset ~= nil then
				yOff = heightOffset(item.yOffset)
			else
				yOff = tonumber(inst:GetAttribute("NatureYOffset")) or 0
			end
			inst:SetAttribute("NaturePitch", if pitch ~= 0 then pitch else nil)
			inst:SetAttribute("NatureRoll", if roll ~= 0 then roll else nil)
			inst:SetAttribute("NatureYOffset", if yOff ~= 0 then yOff else nil)

			local lot = isLot(inst)
			if lot then unpadLot(inst) end
			inst:PivotTo(propPivot(pos.X, pos.Z, yaw, atY, pitch, roll, yOff))
			if lot then padLot(inst) end
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		_lastCallAt[player] = nil
		_lastRemoveAt[player] = nil
	end)
end

function NaturePlaceService.Start() end

return NaturePlaceService
