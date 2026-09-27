--!strict
-- Custom water overlay painter (one EditableImage per tile): transparent over land,
-- depth-graded colour over water (turquoise shallows -> navy deeps), broken white foam
-- in a THIN band right at the shoreline. Foam MOVES by scrolling a pre-baked noise field
-- -- no per-frame terrain sampling and no per-frame math.noise (that combo cost ~300ms
-- a frame). bake() reads the terrain once into a per-pixel depth buffer; compose() turns
-- that buffer into pixels for a given scroll offset. The engine terrain water supplies
-- the real waves; this is just the colour + foam on top.

local AssetService = game:GetService("AssetService")

local WaterImage = {}

local SHALLOW = { 124, 222, 214 } -- bright aqua over the sandy seabed
local MID = { 30, 122, 168 }      -- teal-blue
local DEEP = { 14, 52, 96 }       -- deep navy-blue offshore
local FOAM = { 240, 248, 250 }

local WAVE_ZONE = 14   -- studs from the waterline that surf foam reaches
local WAVE_FREQ = 0.7  -- swell wavelength (rad per stud of depth)
local WAVE_SPEED = 2.5 -- how fast crests roll toward the beach (rad/s)
local SHORE_LIP = 0.30 -- faint permanent foam right at the waterline

local function lerp3(a: { number }, b: { number }, t: number): (number, number, number)
	return a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t
end

function WaterImage.create(res: number): EditableImage
	return AssetService:CreateEditableImage({ Size = Vector2.new(res, res) })
end

-- Pre-baked tiling foam-noise field (0..255), built once and scrolled at runtime so foam
-- churns with zero per-frame math.noise. ponytail: a 1px seam at the wrap edge, hidden
-- under the motion + thin foam band; bump NR or torus-sample if it ever shows.
local NR = 256
local _noise: buffer? = nil
local function noiseField(): buffer
	if _noise then return _noise end
	local nb = buffer.create(NR * NR)
	for y = 0, NR - 1 do
		for x = 0, NR - 1 do
			local n = math.noise(x * 0.05, y * 0.05, 4) * 0.6 + math.noise(x * 0.15, y * 0.15, 9) * 0.4
			buffer.writeu8(nb, y * NR + x, math.clamp((n + 1) * 0.5 * 255, 0, 255))
		end
	end
	_noise = nb
	return nb
end

-- Reused scratch RGBA buffer (one tile at a time, fully overwritten each compose).
local _scratch: buffer? = nil
local function scratch(res: number): buffer
	local need = res * res * 4
	if not _scratch or buffer.len(_scratch) ~= need then _scratch = buffer.create(need) end
	return _scratch
end

-- Write one pixel's base (foam-free) colour: depth-graded water, or transparent on land.
local function writeBaseColor(base: buffer, o: number, d: number)
	if d <= 0 then
		buffer.writeu32(base, o, 0) -- land: fully transparent (clears any old water colour)
		return
	end
	local r, g, b, a
	if d < 35 then
		local t = d / 35
		r, g, b = lerp3(SHALLOW, MID, t)
		a = 0.22 + 0.34 * t -- shallows translucent so the sand reads turquoise through them
	else
		local t = math.clamp((d - 35) / 55, 0, 1)
		r, g, b = lerp3(MID, DEEP, t)
		a = 0.56 + 0.30 * t -- deep water near-opaque so it reads as solid navy
	end
	buffer.writeu8(base, o, r)
	buffer.writeu8(base, o + 1, g)
	buffer.writeu8(base, o + 2, b)
	buffer.writeu8(base, o + 3, a * 255)
end

-- Pack a band pixel list (parallel offset/depth arrays) into a stride-8 buffer.
local function packBand(fo: { number }, fe: { number }): (buffer, number)
	local cnt = #fo
	local foam = buffer.create(cnt * 8)
	for k = 1, cnt do
		buffer.writeu32(foam, (k - 1) * 8, fo[k])
		buffer.writef32(foam, (k - 1) * 8 + 4, fe[k])
	end
	return foam, cnt
end

-- Bake one tile from the real (edited) terrain. Flipped on both axes so the Top-face
-- decal lands the right way round. Produces the per-pixel depth buffer (kept for cheap
-- partial re-bakes), the STATIC base image (depth colour; land transparent) and a packed
-- list of just the shoreline-band pixels (the only pixels the foam scroll touches).
-- isOcean(wx, wz) gates foam so it appears only on ocean-connected water, not inland
-- lakes/ponds. Returns (depth, base, foamPixels, foamCount, hasShore).
function WaterImage.bake(sampleY: (number, number) -> number, isOcean: (number, number) -> boolean, isDry: (number, number) -> boolean, res: number, tileX0: number, tileZ0: number, tileSpan: number): (buffer, buffer, buffer, number, boolean)
	local depth = buffer.create(res * res * 4)
	local base = buffer.create(res * res * 4)
	local fo, fe = {}, {}
	local hasWater, hasLand = false, false
	for py = 0, res - 1 do
		local wz = tileZ0 + (res - 1 - py) / (res - 1) * tileSpan
		for px = 0, res - 1 do
			local wx = tileX0 + (res - 1 - px) / (res - 1) * tileSpan
			local d = -sampleY(wx, wz)
			local o = (py * res + px) * 4
			buffer.writef32(depth, o, d)
			if d > 0 and not isDry(wx, wz) then
				hasWater = true
				writeBaseColor(base, o, d)
				if d < WAVE_ZONE and isOcean(wx, wz) then
					local n = #fo + 1
					fo[n] = o
					fe[n] = d
				end
			else
				hasLand = true
				buffer.writeu32(base, o, 0) -- land or dry pit: transparent
			end
		end
	end
	local foam, cnt = packBand(fo, fe)
	return depth, base, foam, cnt, (hasWater and hasLand)
end

-- Re-bake only the pixels under a world-space rectangle (a brush footprint), updating
-- the depth + base buffers in place and rebuilding the band list incrementally: keep the
-- band pixels outside the rect, re-collect the ones inside. Cost scales with the brush
-- size, not the whole tile -- this is what keeps live terrain editing cheap.
-- Returns the new (foamPixels, foamCount).
function WaterImage.rebakeRect(depth: buffer, base: buffer, oldFoam: buffer, oldFoamN: number, sampleY: (number, number) -> number, isOcean: (number, number) -> boolean, isDry: (number, number) -> boolean, res: number, tileX0: number, tileZ0: number, tileSpan: number, minX: number, maxX: number, minZ: number, maxZ: number): (buffer, number)
	-- world -> pixel (both axes flipped); maxWorld maps to the smaller pixel index
	local function pxAt(wx: number) return (res - 1) - (wx - tileX0) / tileSpan * (res - 1) end
	local function pyAt(wz: number) return (res - 1) - (wz - tileZ0) / tileSpan * (res - 1) end
	local pxLo = math.clamp(math.floor(pxAt(maxX)), 0, res - 1)
	local pxHi = math.clamp(math.ceil(pxAt(minX)), 0, res - 1)
	local pyLo = math.clamp(math.floor(pyAt(maxZ)), 0, res - 1)
	local pyHi = math.clamp(math.ceil(pyAt(minZ)), 0, res - 1)

	local fo, fe = {}, {}
	-- keep band pixels outside the rect
	for k = 0, oldFoamN - 1 do
		local o = buffer.readu32(oldFoam, k * 8)
		local i = o // 4
		local px, py = i % res, i // res
		if px < pxLo or px > pxHi or py < pyLo or py > pyHi then
			local n = #fo + 1
			fo[n] = o
			fe[n] = buffer.readf32(oldFoam, k * 8 + 4)
		end
	end
	-- re-sample the rect; refresh depth + base; collect its band pixels
	for py = pyLo, pyHi do
		local wz = tileZ0 + (res - 1 - py) / (res - 1) * tileSpan
		for px = pxLo, pxHi do
			local wx = tileX0 + (res - 1 - px) / (res - 1) * tileSpan
			local d = -sampleY(wx, wz)
			local o = (py * res + px) * 4
			buffer.writef32(depth, o, d)
			if d > 0 and not isDry(wx, wz) then
				writeBaseColor(base, o, d)
				if d < WAVE_ZONE and isOcean(wx, wz) then
					local n = #fo + 1
					fo[n] = o
					fe[n] = d
				end
			else
				buffer.writeu32(base, o, 0) -- land or dry pit: transparent
			end
		end
	end
	return packBand(fo, fe)
end

-- Compose a tile: copy the static base, then scroll the foam noise over just the band
-- pixels by (offX, offZ). Cost is ~the band size (a thin shoreline strip), not the whole
-- tile, so this is cheap enough to run every animation frame.
function WaterImage.compose(img: EditableImage, base: buffer, foam: buffer, foamN: number, res: number, time: number)
	local nb = noiseField()
	local buf = scratch(res)
	buffer.copy(buf, 0, base)
	local drift = math.floor(time * 5) -- slow lateral drift so fronts aren't identical along the coast
	for k = 0, foamN - 1 do
		local o = buffer.readu32(foam, k * 8)
		local d = buffer.readf32(foam, k * 8 + 4) -- depth (studs) at this pixel
		local i = o // 4
		local n = buffer.readu8(nb, ((i // res + drift) % NR) * NR + (i % res + drift) % NR) / 255
		-- Swell: crests roll shoreward (toward smaller depth) as time advances; the troughs
		-- between them are clear water, so the shore reads as waves washing in and receding.
		local wave = math.sin(d * WAVE_FREQ + time * WAVE_SPEED + n * 1.6)
		local crest = if wave > 0 then wave else 0
		local near = 1 - d / WAVE_ZONE
		near = near * near -- concentrate foam at the beach, fade out to sea
		local f = crest * near
		if d < 1 and f < SHORE_LIP * near then f = SHORE_LIP * near end -- faint waterline lip
		if f > 0.16 then
			local a = math.min(0.92, 0.35 + 0.7 * f)
			buffer.writeu8(buf, o, FOAM[1])
			buffer.writeu8(buf, o + 1, FOAM[2])
			buffer.writeu8(buf, o + 2, FOAM[3])
			buffer.writeu8(buf, o + 3, a * 255)
		end
	end
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(res, res), buf)
end

return WaterImage
