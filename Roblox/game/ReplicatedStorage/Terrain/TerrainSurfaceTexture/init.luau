--!strict
-- The ground's surface grain: one tiling image, generated once at runtime.
--
-- Why this exists. A part MATERIAL is projected onto a MeshPart from the part's own
-- geometry and IGNORES the mesh's UVs -- measured, two identical plates whose UVs differed
-- 8x rendered identically. So a material's texture is anchored to the SHAPE, and the moment
-- sculpting rebuilds a chunk with a new shape and bounding box, the texture shifts with it.
-- That is the surface appearing to crawl while you sculpt, and no amount of UV work could
-- have fixed it.
--
-- MeshPart.TextureContent DOES sample the mesh's UVs -- same two plates, and the pattern
-- scaled with the UVs. TerrainMesh writes UVs straight from world x/z, so a texture applied
-- this way is nailed to the WORLD: heights can change under it all day and it cannot move.
-- SurfaceAppearance would also sample UVs, but its ColorMap only accepts an uploaded asset
-- id, and this project has no terrain texture.
--
-- The image is near-neutral, not green: vertex colours multiply it, and those are what make
-- grass green, sand sandy and rock grey. One image serves every material zone.

local AssetService = game:GetService("AssetService")

local TerrainSurfaceTexture = {}

-- 512 px over MESH_TEXTURE_STUDS (128 studs): a quarter-stud per pixel. The tile has to be
-- big enough to hold PATCHES, not just grain. At 8 studs a repeat it could only ever be
-- fine speckle, and every field read as one flat sheet of green. ~1 MB, built once.
local SIZE = 512

local function hash(ix: number, iy: number, seed: number): number
	local s = math.sin(ix * 127.1 + iy * 311.7 + seed * 74.7) * 43758.5453
	return s - math.floor(s)
end

local function smoothstep(t: number): number
	return t * t * (3 - 2 * t)
end

-- Value noise on a `cells` x `cells` lattice that WRAPS. The tiling is the whole point: the
-- UVs repeat every MESH_TEXTURE_STUDS studs, so an image that does not tile draws a hard
-- grid across the entire map. Lattice indices are taken modulo `cells`, which puts u = 1 on
-- exactly the same lattice line as u = 0.
function TerrainSurfaceTexture.noise(u: number, v: number, cells: number, seed: number): number
	local x, y = u * cells, v * cells
	local x0, y0 = math.floor(x), math.floor(y)
	local fx, fy = smoothstep(x - x0), smoothstep(y - y0)
	local function h(ix: number, iy: number): number
		return hash(ix % cells, iy % cells, seed)
	end
	local top = h(x0, y0) + (h(x0 + 1, y0) - h(x0, y0)) * fx
	local bot = h(x0, y0 + 1) + (h(x0 + 1, y0 + 1) - h(x0, y0 + 1)) * fx
	return top + (bot - top) * fy
end

-- Brightness in [0, 1] at a point on the tile. Several wrapping octaves so it reads as grain
-- rather than blobs; every octave tiles, so their sum does too.
function TerrainSurfaceTexture.brightness(u: number, v: number): number
	-- Patches (16-32 studs), then clumps (4 studs), then grain (half a stud).
	local n = TerrainSurfaceTexture.noise(u, v, 4, 1) * 0.22
		+ TerrainSurfaceTexture.noise(u, v, 8, 2) * 0.2
		+ TerrainSurfaceTexture.noise(u, v, 32, 3) * 0.23
		+ TerrainSurfaceTexture.noise(u, v, 128, 4) * 0.2
		+ TerrainSurfaceTexture.noise(u, v, 256, 5) * 0.15
	-- High and narrow on purpose: this MULTIPLIES the vertex colour, so a dark texture would
	-- drag every material zone down with it. It is grain and mottling, not shading.
	return 0.74 + 0.3 * n
end

-- Warm/cool drift between patches, as per-channel multipliers around 1: grass goes a little
-- yellower in one patch and a little bluer-green in the next, which is most of what makes a
-- real field read as a field. Kept small so sand still reads as sand and rock as rock.
function TerrainSurfaceTexture.tint(u: number, v: number): (number, number, number)
	local t = TerrainSurfaceTexture.noise(u, v, 6, 7) - 0.5
	return 1 + t * 0.12, 1, 1 - t * 0.16
end

local _image: EditableImage? = nil

-- One shared image for the whole map, built on first use and kept for the session: a
-- MeshPart stops showing its TextureContent the moment the image behind it is destroyed.
function TerrainSurfaceTexture.image(): EditableImage?
	if _image then return _image end
	local ok, img = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(SIZE, SIZE) })
	end)
	if not ok or not img then
		warn("[TerrainSurfaceTexture] could not create the surface image:", img)
		return nil
	end
	local buf = buffer.create(SIZE * SIZE * 4)
	for y = 0, SIZE - 1 do
		for x = 0, SIZE - 1 do
			local u, v = x / SIZE, y / SIZE
			local b = TerrainSurfaceTexture.brightness(u, v)
			local tr, tg, tb = TerrainSurfaceTexture.tint(u, v)
			local i = (y * SIZE + x) * 4
			buffer.writeu8(buf, i, math.clamp(math.floor(b * tr * 255 + 0.5), 0, 255))
			buffer.writeu8(buf, i + 1, math.clamp(math.floor(b * tg * 255 + 0.5), 0, 255))
			buffer.writeu8(buf, i + 2, math.clamp(math.floor(b * tb * 255 + 0.5), 0, 255))
			buffer.writeu8(buf, i + 3, 255)
		end
	end
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(SIZE, SIZE), buf)
	_image = img
	return img
end

TerrainSurfaceTexture.SIZE = SIZE

return TerrainSurfaceTexture
