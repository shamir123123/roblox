--!strict
-- RoadMeshBuilder -- collects box/wedge specs for a road piece. Opaque SERVER bakes (live
-- pieces) ship DATA + collision: every spec is packed into one binary "RoadMeshSpecs"
-- StringValue (the client's RoadMeshView decodes it and bakes the piece into ONE
-- vertex-coloured EditableMesh MeshPart -- a server-built EditableMesh is invisible on
-- clients), and only specs at least COLLISION_MIN_THK thick spawn Parts -- invisible
-- (Transparency 1), pure collision/query for the NPC/zone/vehicle systems. Thin
-- render-only trim (markings) spawns no Parts at all. Client bakes (ghost previews) and
-- transparent bakes (terrain pads) still spawn full Parts exactly as before.
-- One builder per segment / junction / dead-end; bake() returns a Model.

local AssetService = game:GetService("AssetService")
local RunService = game:GetService("RunService")

local RoadConstants = require(script.Parent.RoadConstants)

local UP = Vector3.yAxis

-- == Map-edge cut ==============================================================
-- A road dragged to the map boundary ends at a node sitting exactly ON it, and the slab's
-- end face is square to the ROAD -- so an approach that meets the edge at an angle hangs
-- one kerb out over the void past the boundary and leaves the other kerb short of it, with
-- a wedge of bare terrain beside it. Cut every surface run at the boundary instead: both
-- kerbs then stop exactly on the edge line and the end face lies ALONG it.
local MAP_HALF = RoadConstants.MAP_HALF_EXTENT
-- Matches the outside-connection tolerance in OutsideConnectionService / RoadSceneRenderer:
-- a run ending this near a boundary is one that terminates there.
local MAP_EDGE_TOL = 24

-- The boundary plane a point terminates on, as (axis, coordinate), or nil when it is not
-- near one. Distances go negative outside the map, so an overhanging point still resolves.
local function edgePlaneFor(p: Vector3): (string?, number?)
	local dx = MAP_HALF - math.abs(p.X)
	local dz = MAP_HALF - math.abs(p.Z)
	if dx > MAP_EDGE_TOL and dz > MAP_EDGE_TOL then return nil, nil end
	if dx <= dz then return "X", (if p.X >= 0 then MAP_HALF else -MAP_HALF) end
	return "Z", (if p.Z >= 0 then MAP_HALF else -MAP_HALF)
end

-- Trim one polyline so it terminates exactly on `plane`, in place. Stations past the
-- boundary collapse onto the crossing point; a run that stops SHORT is carried forward
-- along its own end tangent to reach it (that is the kerb on the inside of the angle),
-- which `allowExtend` disables for painted markings. Returns true if it cut.
local function cutRunToPlane(pts: { Vector3 }, axis: string, plane: number, atEnd: boolean, allowExtend: boolean): boolean
	local n = #pts
	if n < 2 then return false end
	local function comp(p: Vector3): number
		return if axis == "X" then p.X else p.Z
	end
	local outward = if plane > 0 then 1 else -1
	local function outside(p: Vector3): boolean
		return (comp(p) - plane) * outward > 0
	end

	local first = if atEnd then n else 1
	local stop = if atEnd then 1 else n
	local step = if atEnd then -1 else 1

	-- Walk inward to the last station still on the map.
	local k = first
	while k ~= stop and outside(pts[k]) do k += step end
	if outside(pts[k]) then return false end -- the whole run is off-map: not ours to judge

	if k == first then
		if not allowExtend then return false end
		-- Nothing crossed, so this end stops short: carry it onto the boundary along the
		-- tangent it already has. A run that is parallel to the edge, or that would have to
		-- travel further than the edge tolerance to reach it, is left exactly as it was --
		-- it is a road running ALONGSIDE the boundary, not one terminating on it.
		local dir = pts[first] - pts[first + step]
		local d = comp(dir)
		if math.abs(d) < 1e-3 then return false end
		local t = (plane - comp(pts[first])) / d
		if t < 0 or t * dir.Magnitude > MAP_EDGE_TOL then return false end
		pts[first] = pts[first] + dir * t
		return true
	end

	-- k is the last station inside; everything past it becomes the exact crossing point.
	local a, b = pts[k], pts[k - step]
	local d = comp(b) - comp(a)
	if math.abs(d) < 1e-3 then return false end
	local cut = a:Lerp(b, (plane - comp(a)) / d)
	if atEnd then
		for m = k + 1, n do pts[m] = cut end
	else
		for m = 1, k - 1 do pts[m] = cut end
	end
	return true
end

-- Cut both kerbs of a surface run against the SAME boundary, chosen from the run's own
-- centre so the two sides can never disagree about which edge they are ending on.
local function cutStripToMapEdge(left: { Vector3 }, right: { Vector3 }, n: number)
	for _, atEnd in { true, false } do
		local i = if atEnd then n else 1
		local axis, plane = edgePlaneFor((left[i] + right[i]) * 0.5)
		if axis and plane then
			cutRunToPlane(left, axis, plane, atEnd, true)
			cutRunToPlane(right, axis, plane, atEnd, true)
		end
	end
end

export type BakeOptions = {
	name: string?,
	anchored: boolean?,
	canCollide: boolean?,
	canQuery: boolean?,
	transparency: number?,
	material: Enum.Material?,
	collisionFidelity: Enum.CollisionFidelity?, -- used by the piece's collision MeshPart
	castShadow: boolean?,
}

-- A pending box or wedge, with colour and an optional per-part material override
-- (median = Grass, guardrail = Metal) that beats the bake's blanket material.
export type Spec = {
	wedge: boolean,
	cframe: CFrame,
	size: Vector3,
	color: Color3,
	material: Enum.Material?,
	-- kind "strip": interleaved top-surface stations (l1, r1, l2, r2, ...); cframe/size unused
	strip: { Vector3 }?,
	thickness: number?,
	-- kind "marking": painted line centreline points; client bakes a thin UV ribbon
	-- (solid = opaque atlas region, dashed = dash region tiling by DASH pitch). Render only.
	mark: { Vector3 }?,
	width: number?,
	dashed: boolean?,
	-- kind "fan": a solid polygon slab -- `center` + ordered `fan` rim loop + `thickness`.
	-- Baked directly as top fan + bottom fan + rim skirt (4 tris/slice), no wedge prisms.
	fan: { Vector3 }?,
	center: Vector3?,
}

local RoadMeshBuilder = {}
RoadMeshBuilder.__index = RoadMeshBuilder

export type Builder = typeof(setmetatable(
	{} :: { _specs: { Spec }, _count: number },
	RoadMeshBuilder
))

function RoadMeshBuilder.new(): Builder
	return setmetatable({ _specs = {}, _count = 0 }, RoadMeshBuilder)
end

-- A solid box from a CFrame + Size. Optional per-part material; omit to inherit the bake's.
function RoadMeshBuilder.addBox(self: Builder, cf: CFrame, size: Vector3, color: Color3, material: Enum.Material?)
	self._count += 1
	self._specs[self._count] = { wedge = false, cframe = cf, size = size, color = color, material = material }
end

-- A triangle a,b,c with thickness `thk`, emitted as TWO WedgeParts -- exactly the old
-- drawTriangleThick: corners on the triangle plane, the prism hanging below so swept strips
-- stay watertight on twisted (turning-while-climbing) runs.
local function prismWedgeSpecs(a: Vector3, b: Vector3, c: Vector3, color: Color3, thk: number, material: Enum.Material?): (Spec?, Spec?)
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b
	local normal = ac:Cross(ab)
	if normal.Magnitude < 1e-6 then
		return nil, nil
	end
	local right = normal.Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit
	local height = math.abs(ab:Dot(up))
	local drop = right * (if right:Dot(UP) >= 0 then thk * 0.5 else -thk * 0.5)
	return {
		wedge = true,
		cframe = CFrame.fromMatrix((a + b) * 0.5 - drop, right, up, back),
		size = Vector3.new(thk, height, math.abs(ab:Dot(back))),
		color = color,
		material = material,
	}, {
		wedge = true,
		cframe = CFrame.fromMatrix((a + c) * 0.5 - drop, -right, up, -back),
		size = Vector3.new(thk, height, math.abs(ac:Dot(back))),
		color = color,
		material = material,
	}
end

function RoadMeshBuilder.addPrismTri(self: Builder, a: Vector3, b: Vector3, c: Vector3, color: Color3, thk: number, material: Enum.Material?)
	local s1, s2 = prismWedgeSpecs(a, b, c, color, thk, material)
	if s1 then
		self._count += 1
		self._specs[self._count] = s1
	end
	if s2 then
		self._count += 1
		self._specs[self._count] = s2
	end
end

-- A whole swept surface run as ONE welded strip: stations are the exact top-surface edge
-- pairs. The client bakes shared-vertex quads with per-station normals (watertight and
-- smooth on curves -- per-facet boxes overlapped and z-fought as coplanar mesh triangles)
-- and the collision mesh extrudes the same strip down by `thickness`.
function RoadMeshBuilder.addSurfaceStrip(self: Builder, left: { Vector3 }, right: { Vector3 }, color: Color3, thickness: number)
	local n = math.min(#left, #right)
	if n < 2 then
		return
	end
	-- Copies: the caller's arrays are its own, and a run that ends at the map boundary is
	-- cut to it here so no road surface is ever built out over the void.
	local L, R = table.clone(left), table.clone(right)
	cutStripToMapEdge(L, R, n)
	local pts = table.create(n * 2)
	for i = 1, n do
		pts[i * 2 - 1] = L[i]
		pts[i * 2] = R[i]
	end
	self._count += 1
	self._specs[self._count] = {
		wedge = false,
		cframe = CFrame.identity,
		size = Vector3.zero,
		color = color,
		material = nil,
		strip = pts,
		thickness = thickness,
	}
end

-- A painted line as its centreline polyline + width. Baked into the piece's ONE mesh as a
-- thin vertex-coloured UV ribbon: no beams, no separate mesh, dashes tile via the atlas.
function RoadMeshBuilder.addMarkingLine(self: Builder, pts: { Vector3 }, width: number, color: Color3, dashed: boolean)
	if #pts < 2 then
		return
	end
	-- Paint stops at the edge too, but is never carried forward to reach it: a lane line
	-- that ends a little short of the boundary is correct, one running off the map is not.
	pts = table.clone(pts)
	for _, atEnd in { true, false } do
		local axis, plane = edgePlaneFor(pts[if atEnd then #pts else 1])
		if axis and plane then
			cutRunToPlane(pts, axis, plane, atEnd, false)
		end
	end
	self._count += 1
	self._specs[self._count] = {
		wedge = false,
		cframe = CFrame.identity,
		size = Vector3.zero,
		color = color,
		material = nil,
		mark = pts,
		width = width,
		dashed = dashed,
	}
end

-- A solid polygon slab from a centre point + an ordered rim loop, extruded down by `thickness`.
-- Baked into the mesh as a centre->rim triangle fan (top + bottom + skirt) with no wedge prisms:
-- the junction surface, at a quarter of the per-slice geometry of the old addPrismTri fan.
function RoadMeshBuilder.addFan(self: Builder, center: Vector3, rim: { Vector3 }, thickness: number, color: Color3, material: Enum.Material?)
	if #rim < 3 then
		return
	end
	local pts = table.create(#rim)
	table.move(rim, 1, #rim, 1, pts)
	self._count += 1
	self._specs[self._count] = {
		wedge = false,
		cframe = CFrame.identity,
		size = Vector3.zero,
		color = color,
		material = material,
		fan = pts,
		center = center,
		thickness = thickness,
	}
end

-- Compatibility shims: the renderers now only call addBox / addPrismTri, but keep these so any
-- caller that still funnels a raw triangle / quad through the builder produces Parts too.
function RoadMeshBuilder.addTri(self: Builder, a: Vector3, b: Vector3, c: Vector3, color: Color3, _na: Vector3?, _nb: Vector3?, _nc: Vector3?)
	self:addPrismTri(a, b, c, color, 0.05)
end

function RoadMeshBuilder.addQuad(self: Builder, a: Vector3, b: Vector3, c: Vector3, d: Vector3, color: Color3, _normal: Vector3?)
	self:addPrismTri(a, b, c, color, 0.05)
	self:addPrismTri(a, c, d, color, 0.05)
end

function RoadMeshBuilder.addStripQuad(self: Builder, l0: Vector3, r0: Vector3, l1: Vector3, r1: Vector3, color: Color3, _n0: Vector3?, _n1: Vector3?)
	self:addPrismTri(l0, r0, r1, color, 0.05)
	self:addPrismTri(l0, r1, l1, color, 0.05)
end

function RoadMeshBuilder.isEmpty(self: Builder): boolean
	return self._count == 0
end

-- Anything thinner is render-only trim (markings are 0.05; slab/kerb/rail >= 0.35): it
-- ships in the spec blob but never spawns a Part.
local COLLISION_MIN_THK = 0.15

-- ponytail: no physics collision anywhere in the city. Players never walk the roads and
-- vehicles are CFrame-driven along nav lane paths (surface Y from TerrainDataService.getSurfaceY,
-- not raycasts). Every road piece baked its RoadCollision MeshPart with CanQuery=false, so it
-- caught no spatial query either -- it was pure cost: one CreateMeshPartAsync + EditableMesh per
-- piece. Flip to true only if a real physics body ever needs to rest on the roadway.
local BUILD_COLLISION = false

-- Specs travel to the client as ONE StringValue, base64-wrapped (StringValue.Value
-- truncates at the first NUL and replication sanitizes non-UTF8, so raw binary does not
-- survive the trip). Layout: u32 count, then per spec a kind byte -- 0 box / 1 wedge
-- (f32x3 pos / right / up / size, u8x3 RGB = 52 bytes with the kind), or 2 strip
-- (u16 stations, f32 thickness, u8x3 RGB, then stations x interleaved left/right f32x3).
local SPEC_BYTES = 52

local B64 = buffer.fromstring("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
local B64REV = buffer.create(256)
do
	for i = 0, 63 do
		buffer.writeu8(B64REV, buffer.readu8(B64, i), i)
	end
end

local function b64encode(src: buffer): string
	local len = buffer.len(src)
	local out = buffer.create(math.ceil(len / 3) * 4)
	local i, oi = 0, 0
	while i < len do
		local a = buffer.readu8(src, i)
		local b = if i + 1 < len then buffer.readu8(src, i + 1) else 0
		local c = if i + 2 < len then buffer.readu8(src, i + 2) else 0
		local n = a * 65536 + b * 256 + c
		buffer.writeu8(out, oi, buffer.readu8(B64, math.floor(n / 262144) % 64))
		buffer.writeu8(out, oi + 1, buffer.readu8(B64, math.floor(n / 4096) % 64))
		buffer.writeu8(out, oi + 2, if i + 1 < len then buffer.readu8(B64, math.floor(n / 64) % 64) else 61)
		buffer.writeu8(out, oi + 3, if i + 2 < len then buffer.readu8(B64, n % 64) else 61)
		i += 3
		oi += 4
	end
	return buffer.tostring(out)
end

local function b64decode(s: string): buffer
	local src = buffer.fromstring(s)
	local slen = buffer.len(src)
	assert(slen % 4 == 0, "corrupt spec blob (bad base64 length)")
	local pad = 0
	if slen >= 1 and buffer.readu8(src, slen - 1) == 61 then pad += 1 end
	if slen >= 2 and buffer.readu8(src, slen - 2) == 61 then pad += 1 end
	local outLen = slen / 4 * 3 - pad
	local out = buffer.create(outLen)
	local i, oi = 0, 0
	while i < slen do
		local n = buffer.readu8(B64REV, buffer.readu8(src, i)) * 262144
			+ buffer.readu8(B64REV, buffer.readu8(src, i + 1)) * 4096
			+ buffer.readu8(B64REV, buffer.readu8(src, i + 2)) * 64
			+ buffer.readu8(B64REV, buffer.readu8(src, i + 3))
		if oi < outLen then buffer.writeu8(out, oi, math.floor(n / 65536) % 256) end
		if oi + 1 < outLen then buffer.writeu8(out, oi + 1, math.floor(n / 256) % 256) end
		if oi + 2 < outLen then buffer.writeu8(out, oi + 2, n % 256) end
		i += 4
		oi += 3
	end
	return out
end

local function encodeSpecs(specs: { Spec }, count: number): string
	local bytes = 4
	for i = 1, count do
		local s = specs[i]
		if s.strip then
			bytes += 10 + #s.strip * 12
		elseif s.mark then
			bytes += 11 + #s.mark * 12
		elseif s.fan then
			bytes += 22 + #s.fan * 12
		else
			bytes += SPEC_BYTES
		end
	end
	local buf = buffer.create(bytes)
	buffer.writeu32(buf, 0, count)
	local off = 4
	for i = 1, count do
		local s = specs[i]
		local mark = s.mark
		if mark then
			buffer.writeu8(buf, off, 3)
			buffer.writeu16(buf, off + 1, #mark)
			buffer.writeu8(buf, off + 3, if s.dashed then 1 else 0)
			buffer.writeu8(buf, off + 4, math.floor(s.color.R * 255 + 0.5))
			buffer.writeu8(buf, off + 5, math.floor(s.color.G * 255 + 0.5))
			buffer.writeu8(buf, off + 6, math.floor(s.color.B * 255 + 0.5))
			buffer.writef32(buf, off + 7, s.width or 0.3)
			off += 11
			for _, v in mark do
				buffer.writef32(buf, off, v.X)
				buffer.writef32(buf, off + 4, v.Y)
				buffer.writef32(buf, off + 8, v.Z)
				off += 12
			end
			continue
		end
		local fan = s.fan
		if fan then
			buffer.writeu8(buf, off, 4)
			buffer.writeu16(buf, off + 1, #fan)
			buffer.writef32(buf, off + 3, s.thickness or 0.5)
			buffer.writeu8(buf, off + 7, math.floor(s.color.R * 255 + 0.5))
			buffer.writeu8(buf, off + 8, math.floor(s.color.G * 255 + 0.5))
			buffer.writeu8(buf, off + 9, math.floor(s.color.B * 255 + 0.5))
			off += 10
			local c = s.center :: Vector3
			buffer.writef32(buf, off, c.X)
			buffer.writef32(buf, off + 4, c.Y)
			buffer.writef32(buf, off + 8, c.Z)
			off += 12
			for _, v in fan do
				buffer.writef32(buf, off, v.X)
				buffer.writef32(buf, off + 4, v.Y)
				buffer.writef32(buf, off + 8, v.Z)
				off += 12
			end
			continue
		end
		local strip = s.strip
		if strip then
			buffer.writeu8(buf, off, 2)
			buffer.writeu16(buf, off + 1, #strip // 2)
			buffer.writef32(buf, off + 3, s.thickness or 0.8)
			buffer.writeu8(buf, off + 7, math.floor(s.color.R * 255 + 0.5))
			buffer.writeu8(buf, off + 8, math.floor(s.color.G * 255 + 0.5))
			buffer.writeu8(buf, off + 9, math.floor(s.color.B * 255 + 0.5))
			off += 10
			for _, v in strip do
				buffer.writef32(buf, off, v.X)
				buffer.writef32(buf, off + 4, v.Y)
				buffer.writef32(buf, off + 8, v.Z)
				off += 12
			end
			continue
		end
		local p = s.cframe.Position
		local x = s.cframe.XVector
		local y = s.cframe.YVector
		buffer.writeu8(buf, off, if s.wedge then 1 else 0)
		buffer.writef32(buf, off + 1, p.X)
		buffer.writef32(buf, off + 5, p.Y)
		buffer.writef32(buf, off + 9, p.Z)
		buffer.writef32(buf, off + 13, x.X)
		buffer.writef32(buf, off + 17, x.Y)
		buffer.writef32(buf, off + 21, x.Z)
		buffer.writef32(buf, off + 25, y.X)
		buffer.writef32(buf, off + 29, y.Y)
		buffer.writef32(buf, off + 33, y.Z)
		buffer.writef32(buf, off + 37, s.size.X)
		buffer.writef32(buf, off + 41, s.size.Y)
		buffer.writef32(buf, off + 45, s.size.Z)
		buffer.writeu8(buf, off + 49, math.floor(s.color.R * 255 + 0.5))
		buffer.writeu8(buf, off + 50, math.floor(s.color.G * 255 + 0.5))
		buffer.writeu8(buf, off + 51, math.floor(s.color.B * 255 + 0.5))
		off += SPEC_BYTES
	end
	return b64encode(buf)
end

-- Box/wedge triangle index tables over the canonical corner orders (no normals/colours --
-- this geometry is only ever a collision body).
local BOX_CORNERS = {
	Vector3.new(-1, -1, -1), Vector3.new(1, -1, -1), Vector3.new(1, -1, 1), Vector3.new(-1, -1, 1),
	Vector3.new(-1, 1, -1), Vector3.new(1, 1, -1), Vector3.new(1, 1, 1), Vector3.new(-1, 1, 1),
}
local BOX_TRIS = {
	{ 1, 2, 3 }, { 1, 3, 4 }, { 5, 6, 7 }, { 5, 7, 8 }, { 1, 2, 6 }, { 1, 6, 5 },
	{ 4, 3, 7 }, { 4, 7, 8 }, { 1, 5, 8 }, { 1, 8, 4 }, { 2, 3, 7 }, { 2, 7, 6 },
}
local WEDGE_CORNERS = {
	Vector3.new(-1, -1, -1), Vector3.new(1, -1, -1), Vector3.new(1, -1, 1), Vector3.new(-1, -1, 1),
	Vector3.new(-1, 1, 1), Vector3.new(1, 1, 1),
}
local WEDGE_TRIS = {
	{ 1, 2, 3 }, { 1, 3, 4 }, { 4, 3, 6 }, { 4, 6, 5 }, { 1, 2, 6 }, { 1, 6, 5 }, { 1, 4, 5 }, { 2, 3, 6 },
}

-- ONE invisible collision MeshPart per piece instead of dozens of Parts: every spec at
-- least COLLISION_MIN_THK thick is merged into a server-side EditableMesh and baked with
-- real collision fidelity. Rendering is the client's job (spec blob); this body is never
-- visible anywhere. CreateMeshPartAsync yields, so the build runs detached; on failure the
-- piece stays render-only and server raycasts fall back to terrain height.
local function buildCollisionMesh(model: Model, specs: { Spec }, count: number, o: BakeOptions)
	local thick: { Spec } = {}
	for i = 1, count do
		local s = specs[i]
		local thk = if s.fan then (s.thickness or 0.5) elseif s.strip then (s.thickness or 0.8) else (if s.wedge then s.size.X else s.size.Y)
		if thk >= COLLISION_MIN_THK then
			table.insert(thick, s)
		end
	end
	if #thick == 0 then
		return
	end
	task.spawn(function()
		local ok, err = pcall(function()
			local first = thick[1]
			local firstStrip = first.strip
			-- keeps vertex coords small; exactness irrelevant
			local center = if firstStrip then firstStrip[1] elseif first.fan then (first.center :: Vector3) else first.cframe.Position
			local em = AssetService:CreateEditableMesh()
			assert(em, "EditableMesh budget exhausted (server)")
			for _, s in thick do
				local strip = s.strip
				if s.fan then
					local rim = s.fan
					local nfan = #rim
					if nfan >= 3 then
						local fc = s.center :: Vector3
						local drop = UP * (s.thickness or 0.5)
						local cTop = em:AddVertex(fc - center)
						local cBot = em:AddVertex(fc - drop - center)
						local ti = table.create(nfan)
						local bi = table.create(nfan)
						for k = 1, nfan do
							ti[k] = em:AddVertex(rim[k] - center)
							bi[k] = em:AddVertex(rim[k] - drop - center)
						end
						for k = 1, nfan do
							local k2 = (k % nfan) + 1
							em:AddTriangle(cTop, ti[k], ti[k2])
							em:AddTriangle(cBot, bi[k2], bi[k])
							em:AddTriangle(ti[k], bi[k], bi[k2])
							em:AddTriangle(ti[k], bi[k2], ti[k2])
						end
					end
				elseif strip then
					-- welded extrusion of the strip: top/bottom quads + side skirts + end caps
					local thk = s.thickness or 0.8
					local n = #strip // 2
					local topIds = table.create(n * 2)
					local botIds = table.create(n * 2)
					for k = 1, n do
						local l, r = strip[k * 2 - 1], strip[k * 2]
						local tangent = strip[math.min(k + 1, n) * 2 - 1] - strip[math.max(k - 1, 1) * 2 - 1]
						local up = (r - l):Cross(tangent)
						up = if up.Magnitude > 1e-6 then up.Unit else UP
						if up:Dot(UP) < 0 then up = -up end
						local drop = up * thk
						topIds[k * 2 - 1] = em:AddVertex(l - center)
						topIds[k * 2] = em:AddVertex(r - center)
						botIds[k * 2 - 1] = em:AddVertex(l - drop - center)
						botIds[k * 2] = em:AddVertex(r - drop - center)
					end
					for k = 1, n - 1 do
						local a, b = topIds[k * 2 - 1], topIds[k * 2]
						local c, d = topIds[k * 2 + 1], topIds[k * 2 + 2]
						local e, f = botIds[k * 2 - 1], botIds[k * 2]
						local g, h = botIds[k * 2 + 1], botIds[k * 2 + 2]
						em:AddTriangle(a, b, d); em:AddTriangle(a, d, c)
						em:AddTriangle(e, f, h); em:AddTriangle(e, h, g)
						em:AddTriangle(a, c, g); em:AddTriangle(a, g, e)
						em:AddTriangle(b, d, h); em:AddTriangle(b, h, f)
					end
					em:AddTriangle(topIds[1], topIds[2], botIds[2])
					em:AddTriangle(topIds[1], botIds[2], botIds[1])
					em:AddTriangle(topIds[n * 2 - 1], topIds[n * 2], botIds[n * 2])
					em:AddTriangle(topIds[n * 2 - 1], botIds[n * 2], botIds[n * 2 - 1])
				else
					local cf, half = s.cframe, s.size * 0.5
					local corners = if s.wedge then WEDGE_CORNERS else BOX_CORNERS
					local tris = if s.wedge then WEDGE_TRIS else BOX_TRIS
					local ids = table.create(#corners)
					for i, c in corners do
						ids[i] = em:AddVertex(cf:PointToWorldSpace(half * c) - center)
					end
					for _, t in tris do
						em:AddTriangle(ids[t[1]], ids[t[2]], ids[t[3]])
					end
				end
			end
			local okMp, mp = pcall(function(): MeshPart
				return AssetService:CreateMeshPartAsync(Content.fromObject(em), {
					CollisionFidelity = o.collisionFidelity or Enum.CollisionFidelity.Default,
				})
			end)
			em:Destroy() -- collision data survives the EM; only RENDERING needs it alive
			if not okMp then
				error(mp)
			end
			local mesh = mp :: MeshPart
			mesh.Name = "RoadCollision"
			mesh.Anchored = if o.anchored == nil then true else o.anchored
			mesh.CanCollide = if o.canCollide == nil then true else o.canCollide
			mesh.CanQuery = o.canQuery or false
			mesh.CanTouch = false
			mesh.CastShadow = false
			mesh.Transparency = 1
			mesh.CFrame = CFrame.new(center)
			mesh.Parent = model
		end)
		if not ok then
			warn(`[RoadMeshBuilder] collision mesh failed for {model.Name}: {err}`)
		end
	end)
end

function RoadMeshBuilder.decodeSpecs(blob: string): { Spec }
	local buf = b64decode(blob)
	local total = buffer.len(buf)
	local count = buffer.readu32(buf, 0)
	local out = table.create(count)
	local off = 4
	for i = 1, count do
		assert(off + 1 <= total, "corrupt spec blob (truncated)")
		local kind = buffer.readu8(buf, off)
		if kind == 3 then
			local n = buffer.readu16(buf, off + 1)
			local dashed = buffer.readu8(buf, off + 3) == 1
			local r, g, b = buffer.readu8(buf, off + 4), buffer.readu8(buf, off + 5), buffer.readu8(buf, off + 6)
			local width = buffer.readf32(buf, off + 7)
			off += 11
			assert(off + n * 12 <= total, "corrupt spec blob (mark length)")
			local pts = table.create(n)
			for k = 1, n do
				pts[k] = Vector3.new(buffer.readf32(buf, off), buffer.readf32(buf, off + 4), buffer.readf32(buf, off + 8))
				off += 12
			end
			out[i] = {
				wedge = false,
				cframe = CFrame.identity,
				size = Vector3.zero,
				color = Color3.fromRGB(r, g, b),
				material = nil,
				mark = pts,
				width = width,
				dashed = dashed,
			} :: Spec
		elseif kind == 4 then
			local n = buffer.readu16(buf, off + 1)
			local thickness = buffer.readf32(buf, off + 3)
			local r, g, b = buffer.readu8(buf, off + 7), buffer.readu8(buf, off + 8), buffer.readu8(buf, off + 9)
			off += 10
			assert(off + (n + 1) * 12 <= total, "corrupt spec blob (fan length)")
			local c = Vector3.new(buffer.readf32(buf, off), buffer.readf32(buf, off + 4), buffer.readf32(buf, off + 8))
			off += 12
			local rim = table.create(n)
			for k = 1, n do
				rim[k] = Vector3.new(buffer.readf32(buf, off), buffer.readf32(buf, off + 4), buffer.readf32(buf, off + 8))
				off += 12
			end
			out[i] = {
				wedge = false,
				cframe = CFrame.identity,
				size = Vector3.zero,
				color = Color3.fromRGB(r, g, b),
				material = nil,
				fan = rim,
				center = c,
				thickness = thickness,
			} :: Spec
		elseif kind == 2 then
			local n = buffer.readu16(buf, off + 1)
			local thickness = buffer.readf32(buf, off + 3)
			local r, g, b = buffer.readu8(buf, off + 7), buffer.readu8(buf, off + 8), buffer.readu8(buf, off + 9)
			off += 10
			assert(off + n * 24 <= total, "corrupt spec blob (strip length)")
			local pts = table.create(n * 2)
			for k = 1, n * 2 do
				pts[k] = Vector3.new(buffer.readf32(buf, off), buffer.readf32(buf, off + 4), buffer.readf32(buf, off + 8))
				off += 12
			end
			out[i] = {
				wedge = false,
				cframe = CFrame.identity,
				size = Vector3.zero,
				color = Color3.fromRGB(r, g, b),
				material = nil,
				strip = pts,
				thickness = thickness,
			} :: Spec
		else
			assert(off + SPEC_BYTES <= total, "corrupt spec blob (length mismatch)")
			out[i] = {
				wedge = kind == 1,
				cframe = CFrame.fromMatrix(
					Vector3.new(buffer.readf32(buf, off + 1), buffer.readf32(buf, off + 5), buffer.readf32(buf, off + 9)),
					Vector3.new(buffer.readf32(buf, off + 13), buffer.readf32(buf, off + 17), buffer.readf32(buf, off + 21)),
					Vector3.new(buffer.readf32(buf, off + 25), buffer.readf32(buf, off + 29), buffer.readf32(buf, off + 33))
				),
				size = Vector3.new(buffer.readf32(buf, off + 37), buffer.readf32(buf, off + 41), buffer.readf32(buf, off + 45)),
				color = Color3.fromRGB(buffer.readu8(buf, off + 49), buffer.readu8(buf, off + 50), buffer.readu8(buf, off + 51)),
				material = nil,
			} :: Spec
			off += SPEC_BYTES
		end
	end
	return out
end

-- Peek the FIRST spec's anchor position without decoding the whole blob. RoadMeshView
-- buckets pieces into map cells by geometry: live pieces are part-less Models (blob +
-- decal plates at most), so GetPivot() is (0,0,0) and useless as a spatial key.
function RoadMeshBuilder.peekFirstPosition(blob: string): Vector3?
	if #blob < 40 then
		return nil
	end
	-- 40 b64 chars = 30 bytes: count u32 + kind u8 + first position for every kind
	local buf = b64decode(blob:sub(1, 40))
	if buffer.readu32(buf, 0) == 0 then
		return nil
	end
	local kind = buffer.readu8(buf, 4)
	local off = if kind == 0 or kind == 1 then 5 elseif kind == 3 then 15 else 14
	return Vector3.new(buffer.readf32(buf, off), buffer.readf32(buf, off + 4), buffer.readf32(buf, off + 8))
end

-- Build every collected Part inside a Model and return it. Per-part material beats opts.material.
function RoadMeshBuilder.bake(self: Builder, opts: BakeOptions?): Model?
	if self._count == 0 then
		return nil
	end
	local o = opts or {}
	local model = Instance.new("Model")
	model.Name = o.name or "RoadParts"
	local anchored = if o.anchored == nil then true else o.anchored
	local canCollide = if o.canCollide == nil then true else o.canCollide
	local canQuery = o.canQuery or false
	local castShadow = o.castShadow or false
	local material = o.material or Enum.Material.SmoothPlastic
	local transparency = o.transparency or 0
	-- Opaque server bake = a live road piece: geometry ships as the spec blob (the client
	-- bakes it into ONE visible mesh) and physics is ONE invisible collision MeshPart --
	-- no per-spec Parts at all. IsServer keeps client callers (ghosts) on the parts path.
	local dataMode = transparency == 0 and RunService:IsServer()
	if dataMode then
		local blob = Instance.new("StringValue")
		blob.Name = "RoadMeshSpecs"
		blob.Value = encodeSpecs(self._specs, self._count)
		blob.Parent = model
		if BUILD_COLLISION then
			buildCollisionMesh(model, self._specs, self._count, o)
		end
		return model
	end
	local function makePart(s: Spec)
		local p: BasePart = if s.wedge then Instance.new("WedgePart") else Instance.new("Part")
		p.Anchored = anchored
		p.CanCollide = canCollide
		p.CanQuery = canQuery
		p.CanTouch = false
		p.CastShadow = castShadow
		p.Material = s.material or material
		p.Color = s.color
		p.Transparency = transparency
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Size = s.size
		p.CFrame = s.cframe
		p.Parent = model
	end
	for i = 1, self._count do
		local s = self._specs[i]
		if s.mark then
			continue -- ghost/preview parts path draws no painted lines
		end
		if s.fan then
			local fc = s.center :: Vector3
			local thk = s.thickness or 0.5
			local nfan = #s.fan
			for k = 1, nfan do
				local k2 = (k % nfan) + 1
				local fw1, fw2 = prismWedgeSpecs(fc, s.fan[k], s.fan[k2], s.color, thk, s.material)
				if fw1 then makePart(fw1) end
				if fw2 then makePart(fw2) end
			end
			continue
		end
		local strip = s.strip
		if strip then
			-- Parts path (ghost previews): flatten the strip back into per-facet prism wedges.
			local thk = s.thickness or 0.8
			for k = 1, #strip // 2 - 1 do
				local l0, r0 = strip[k * 2 - 1], strip[k * 2]
				local l1, r1 = strip[k * 2 + 1], strip[k * 2 + 2]
				local w1, w2 = prismWedgeSpecs(l0, r0, r1, s.color, thk, s.material)
				local w3, w4 = prismWedgeSpecs(l0, r1, l1, s.color, thk, s.material)
				if w1 then makePart(w1) end
				if w2 then makePart(w2) end
				if w3 then makePart(w3) end
				if w4 then makePart(w4) end
			end
		else
			makePart(s)
		end
	end
	return model
end

return RoadMeshBuilder
