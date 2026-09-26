-- Dump everything visible under `root` for the top-down renderer (render/top.py): BaseParts,
-- plus the road pieces' encoded mesh specs (RoadMeshSpecs blobs the client bakes into meshes).
-- Every item becomes a polygon list with a top height: { poly = {x,z,...}, y, c, t }.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
return function(Studio, root, file: string)
	local R = function(p) return Studio.require(Studio.find(p)) end
	local RMB = R("ReplicatedStorage.Road.RoadMeshBuilder")
	local RoadConstants = R("ReplicatedStorage.Road.RoadConstants")
	local DASH, PITCH = RoadConstants.DASH_LENGTH, RoadConstants.DASH_LENGTH + RoadConstants.DASH_GAP
	local out = {}
	local function col(c) if not c then return { 255, 140, 0 } end return { math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5) } end
	local function part(name, shape, cf, size, c, t, parentName)
		table.insert(out, { k = "part", n = name, shape = shape, cf = { cf:GetComponents() }, s = { size.X, size.Y, size.Z }, c = c, t = t, p = parentName })
	end
	local function poly(name, pts, y, c, parentName)
		local flat = {}
		for _, v in pts do table.insert(flat, v.X); table.insert(flat, v.Z) end
		table.insert(out, { k = "poly", n = name, pts = flat, y = y, c = c, t = 0, p = parentName })
	end
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			if (d.Transparency or 0) >= 0.95 then continue end
			local shape = "Block"
			if d.ClassName == "WedgePart" then shape = "Wedge"
			elseif d.ClassName == "CornerWedgePart" then shape = "CornerWedge"
			elseif d.ClassName == "Part" and d.Shape then shape = tostring(d.Shape):match("%.(%w+)$") or tostring(d.Shape) end
			part(d.Name, shape, d.CFrame, d.Size, col(d.Color), d.Transparency or 0, d.Parent and d.Parent.Name or "")
		elseif d.ClassName == "StringValue" and d.Name == "RoadMeshSpecs" then
			local pn = d.Parent and d.Parent.Parent and d.Parent.Parent.Name or ""
			for _, s in RMB.decodeSpecs(d.Value) do
				local c = col(s.color)
				if s.mark then
					local pts, w = s.mark, s.width or 0.5
					local cum = { 0 }
					for k = 2, #pts do cum[k] = cum[k - 1] + (pts[k] - pts[k - 1]).Magnitude end
					for k = 1, #pts - 1 do
						local a, b = pts[k], pts[k + 1]
						if s.dashed and ((cum[k] + cum[k + 1]) * 0.5) % PITCH >= DASH then continue end
						local dir = b - a
						if dir.Magnitude < 1e-4 then continue end
						local side = Studio.Vector3.new(-dir.Z, 0, dir.X).Unit * (w * 0.5)
						poly("mark", { a + side, b + side, b - side, a - side }, math.max(a.Y, b.Y) + 0.02, c, pn)
					end
				elseif s.fan then
					local n = #s.fan
					for k = 1, n do
						local k2 = (k % n) + 1
						poly("fan", { s.center, s.fan[k], s.fan[k2] }, math.max(s.center.Y, s.fan[k].Y, s.fan[k2].Y), c, pn)
					end
				elseif s.strip then
					local st = s.strip
					for k = 1, #st // 2 - 1 do
						local l0, r0, l1, r1 = st[k * 2 - 1], st[k * 2], st[k * 2 + 1], st[k * 2 + 2]
						poly("strip", { l0, r0, r1, l1 }, math.max(l0.Y, r0.Y, l1.Y, r1.Y), c, pn)
					end
				else
					part("spec", if s.wedge then "Wedge" else "Block", s.cframe, s.size, c, 0, pn)
				end
			end
		end
	end
	local bytes = 0
	for _, d in root:GetDescendants() do
		if d.ClassName == "StringValue" and d.Name == "RoadMeshSpecs" then bytes += #d.Value end
	end
	print("BLOBBYTES", bytes)
	fs.writeFile(file, serde.encode("json", out))
	return #out
end
