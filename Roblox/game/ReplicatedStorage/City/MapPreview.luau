--!strict
-- Top-down terrain minimap built from a seed, for the map picker. Pure client UI
-- helper: samples the generator height formula at low res and paints an
-- EditableImage. No voxels, no asset upload -- works for any seed.

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Terrain.TerrainConstants)
local TerrainGenerator = require(ReplicatedStorage.Terrain.TerrainGenerator)

local RES = 128 -- preview is RES x RES px; ~32k height samples, sub-100ms to repaint
local TILES = Constants.TILES_PER_AXIS

local MapPreview = {}

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- (worldY, slope in studs per stud) -> (r,g,b) 0..255, in the muted satellite palette of a
-- city-builder map screen: teal water that darkens with depth, olive lowland, and ground that
-- dries to sandy tan as it climbs or steepens -- which is what makes mountains read at a glance.
local function colorBiome(y: number, slope: number): (number, number, number)
	if y < 0 then
		local t = math.clamp(-y / 30, 0, 1)
		return lerp(58, 20, t), lerp(122, 60, t), lerp(122, 72, t)
	end
	if y < 1.6 and slope < 0.25 then
		return 196, 180, 128 -- beach
	end
	local dry = math.clamp((y - 24) / 70, 0, 1) + math.clamp((slope - 0.3) * 1.6, 0, 1)
	dry = math.clamp(dry, 0, 1)
	local lush = math.clamp(1 - y / 30, 0, 1) * 0.25
	return lerp(104, 188, dry) - lush * 20, lerp(122, 158, dry) + lush * 6, lerp(52, 110, dry) - lush * 8
end

-- Make the ImageLabel + its EditableImage. Caller parents/sizes the label. res sets
-- the pixel resolution (default RES); small shape tiles pass a lower res.
function MapPreview.create(res: number?): (ImageLabel, EditableImage)
	local n = res or RES
	local img = AssetService:CreateEditableImage({ Size = Vector2.new(n, n) })
	local label = Instance.new("ImageLabel")
	label.BackgroundColor3 = Color3.fromRGB(20, 26, 34)
	label.BorderSizePixel = 0
	label.ImageContent = Content.fromObject(img)
	return label, img
end

-- Repaint the whole minimap for a parameter set. Cheap west-neighbour hillshade
-- makes relief readable. Safe to call repeatedly (reroll / slider drag / map switch).
function MapPreview.paint(img: EditableImage, params: TerrainGenerator.GenParams, res: number?)
	local n = res or RES
	local buf = buffer.create(n * n * 4)
	for py = 0, n - 1 do
		local gz = py / (n - 1) * TILES
		for px = 0, n - 1 do
			local gx = px / (n - 1) * TILES
			local y = TerrainGenerator.surfaceYAt(gx, gz, params)
			local yw = TerrainGenerator.surfaceYAt(gx - 1, gz, params)
			local yn = TerrainGenerator.surfaceYAt(gx, gz - 1, params)
			-- NW-lit hillshade off two neighbours one corner (4 studs) away. Flat water takes no
			-- shade, so the sea stays one clean colour band per depth.
			local dx, dz = (y - yw) / 4, (y - yn) / 4
			local shade = if y < 0 then 1 else math.clamp(1 + (dx + dz) * 0.9, 0.6, 1.3)
			local cr, cg, cb = colorBiome(y, math.sqrt(dx * dx + dz * dz))
			local o = (py * n + px) * 4
			buffer.writeu8(buf, o, math.clamp(cr * shade, 0, 255))
			buffer.writeu8(buf, o + 1, math.clamp(cg * shade, 0, 255))
			buffer.writeu8(buf, o + 2, math.clamp(cb * shade, 0, 255))
			buffer.writeu8(buf, o + 3, 255)
		end
	end
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(n, n), buf)
end

return MapPreview
