-- 3D dump for render/shade3d.py: the visible terrain as a height grid over a square region,
-- plus every face the road code builds -- Parts (boxes / wedges) and the road pieces' baked
-- mesh specs (boxes, wedges, strips, fans). Markings are left out; this is for shapes.
-- usage (from a lab script): require("./render/dump3d")(Studio, root, file, cx, cz, half, step)
local fs = require("@lune/fs")
local serde = require("@lune/serde")
return function(Studio, root, file: string, cx: number, cz: number, half: number, step: number?)
	local R = function(p) return Studio.require(Studio.find(p)) end
	local RMB = R("ReplicatedStorage.Road.RoadMeshBuilder")
	local Terrain = R("ServerScriptService.Services.Terrain.TerrainDataService")
	local V = Studio.Vector3
	local faces = {}
	local function col(c)
		if not c then return { 200, 200, 200 } end
		return { math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5) }
	end
	local function face(pts, c)
		local flat = {}
		for _, p in pts do
			table.insert(flat, math.floor(p.X * 100 + 0.5) / 100)
			table.insert(flat, math.floor(p.Y * 100 + 0.5) / 100)
			table.insert(flat, math.floor(p.Z * 100 + 0.5) / 100)
		end
		table.insert(faces, { p = flat, c = c })
	end
	local function box(cf, size, c, wedge: boolean)
		local sx, sy, sz = size.X / 2, size.Y / 2, size.Z / 2
		local function w(x, y, z) return cf:PointToWorldSpace(V.new(x, y, z)) end
		if wedge then
			local a, b = w(-sx, -sy, -sz), w(sx, -sy, -sz)
			local d, e = w(-sx, -sy, sz), w(sx, -sy, sz)
			local f, g = w(-sx, sy, sz), w(sx, sy, sz)
			face({ a, b, e, d }, c)          -- bottom
			face({ d, e, g, f }, c)          -- back
			face({ a, b, g, f }, c)          -- slope
			face({ a, d, f }, c)
			face({ b, e, g }, c)
			return
		end
		local q = {}
		for _, x in { -sx, sx } do for _, y in { -sy, sy } do for _, z in { -sz, sz } do table.insert(q, w(x, y, z)) end end end
		-- q index: x(1/2) y(1/2) z(1/2) -> ((xi-1)*4 + (yi-1)*2 + zi)
		local function k(xi, yi, zi) return q[(xi - 1) * 4 + (yi - 1) * 2 + zi] end
		face({ k(1, 1, 1), k(2, 1, 1), k(2, 1, 2), k(1, 1, 2) }, c)
		face({ k(1, 2, 1), k(2, 2, 1), k(2, 2, 2), k(1, 2, 2) }, c)
		face({ k(1, 1, 1), k(2, 1, 1), k(2, 2, 1), k(1, 2, 1) }, c)
		face({ k(1, 1, 2), k(2, 1, 2), k(2, 2, 2), k(1, 2, 2) }, c)
		face({ k(1, 1, 1), k(1, 1, 2), k(1, 2, 2), k(1, 2, 1) }, c)
		face({ k(2, 1, 1), k(2, 1, 2), k(2, 2, 2), k(2, 2, 1) }, c)
	end
	local function near(p): boolean
		return math.abs(p.X - cx) <= half + 40 and math.abs(p.Z - cz) <= half + 40
	end
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			if (d.Transparency or 0) >= 0.95 or not near(d.Position) then continue end
			box(d.CFrame, d.Size, col(d.Color), d.ClassName == "WedgePart")
		elseif d.ClassName == "StringValue" and d.Name == "RoadMeshSpecs" then
			for _, s in RMB.decodeSpecs(d.Value) do
				local c = col(s.color)
				if s.mark then
					continue
				elseif s.strip then
					local st = s.strip
					if not near(st[1]) then continue end
					for i = 1, #st // 2 - 1 do
						face({ st[i * 2 - 1], st[i * 2], st[i * 2 + 2], st[i * 2 + 1] }, c)
					end
				elseif s.fan then
					if not near(s.center) then continue end
					for i = 1, #s.fan do
						face({ s.center, s.fan[i], s.fan[i % #s.fan + 1] }, c)
					end
				elseif s.cframe and s.size then
					if not near(s.cframe.Position) then continue end
					box(s.cframe, s.size, c, s.wedge == true)
				end
			end
		end
	end
	local st = step or 4
	local n = math.floor(2 * half / st)
	local heights = {}
	for j = 0, n do
		for i = 0, n do
			table.insert(heights, math.floor(Terrain.getSurfaceY(cx - half + i * st, cz - half + j * st) * 100 + 0.5) / 100)
		end
	end
	fs.writeFile(file, serde.encode("json", { faces = faces, terrain = { x0 = cx - half, z0 = cz - half, step = st, n = n, h = heights } }))
	return #faces
end
