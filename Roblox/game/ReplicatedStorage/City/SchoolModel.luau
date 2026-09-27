--!strict
-- SchoolModel
-- Procedural builder for the education buildings (schools + library). Each tier gets a
-- distinct massing -- Elementary playful, High School modern-civic, University collegiate,
-- Library small civic -- on shared grounds (lawn pad, paved forecourt, flagpole, hedges).
-- The PrimaryPart is an invisible Root at the building BASE centre; every part welds to it,
-- so PivotTo(groundCFrame) sits the whole campus on the ground. +Z faces the road. `ghost`
-- makes it translucent + non-queryable for the placement preview. No lifecycle, no state.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SchoolTypes = require(ReplicatedStorage.City.SchoolTypes)
local ZoneGrid = require(ReplicatedStorage.City.ZoneGrid)

local SchoolModel = {}

local GRASS = Color3.fromRGB(126, 172, 96)
local PAVE  = Color3.fromRGB(190, 190, 186)
local HEDGE = Color3.fromRGB(96, 140, 80)
local GLASS = Color3.fromRGB(150, 196, 214)
local METAL = Color3.fromRGB(205, 205, 210)

local function weld(child: BasePart, root: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = root
	w.Part1 = child
	w.Parent = root
end

type Adder = (name: string, size: Vector3, color: Color3, material: Enum.Material, offset: Vector3) -> Part

local function makeAdder(model: Model, root: Part, ghost: boolean): Adder
	local t = if ghost then 0.55 else 0
	return function(name, size, color, material, offset)
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.Color = color
		p.Material = material
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = not ghost
		p.CastShadow = not ghost
		p.Transparency = t
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.CFrame = root.CFrame * CFrame.new(offset)
		p.Parent = model
		weld(p, root)
		return p
	end
end

-- A horizontal band of n glass panes across the front face at height y.
local function windowBand(add: Adder, n: number, spanX: number, y: number, frontZ: number, paneH: number)
	for i = 1, n do
		local x = -spanX * 0.5 + (i - 0.5) * (spanX / n)
		add("Window", Vector3.new(spanX / n * 0.72, paneH, 0.4), GLASS, Enum.Material.Glass, Vector3.new(x, y, frontZ + 0.25))
	end
end

local function block(add: Adder, w: number, h: number, d: number, color: Color3, material: Enum.Material, cx: number, cz: number): number
	add("Wall", Vector3.new(w, h, d), color, material, Vector3.new(cx, h * 0.5, cz))
	return cz + d * 0.5 -- returns the front (+Z) face Z
end

local function parapet(add: Adder, w: number, d: number, color: Color3, topY: number, cz: number)
	add("Roof", Vector3.new(w + 1, 1.2, d + 1), color, Enum.Material.Concrete, Vector3.new(0, topY + 0.6, cz))
end

local function grounds(add: Adder, fp: Vector3, accent: Color3, frontZ: number)
	add("Lawn", Vector3.new(fp.X, 0.2, fp.Z), GRASS, Enum.Material.Grass, Vector3.new(0, 0.1, 0))
	add("Forecourt", Vector3.new(fp.X * 0.52, 0.26, fp.Z * 0.3), PAVE, Enum.Material.Concrete, Vector3.new(0, 0.13, frontZ - fp.Z * 0.15))
	add("Walkway", Vector3.new(7, 0.3, fp.Z * 0.34), PAVE, Enum.Material.Concrete, Vector3.new(0, 0.16, frontZ - fp.Z * 0.17))
	for _, sx in { -1, 1 } do
		add("Hedge", Vector3.new(fp.X * 0.34, 2, 1.4), HEDGE, Enum.Material.Grass, Vector3.new(sx * fp.X * 0.33, 1, frontZ - 0.8))
	end
	add("Flagpole", Vector3.new(0.4, 15, 0.4), METAL, Enum.Material.Metal, Vector3.new(-fp.X * 0.42, 7.5, frontZ - 2.5))
	add("Flag", Vector3.new(0.2, 2.4, 4), accent, Enum.Material.Fabric, Vector3.new(-fp.X * 0.42 + 2.2, 13.5, frontZ - 2.5))
end

local function columns(add: Adder, count: number, spanX: number, h: number, z: number, color: Color3)
	for i = 1, count do
		local x = -spanX * 0.5 + (i - 0.5) * (spanX / count)
		add("Column", Vector3.new(2, h, 2), color, Enum.Material.Concrete, Vector3.new(x, h * 0.5, z))
	end
end

local function buildElementary(add: Adder, spec: any, fp: Vector3)
	local h = spec.height
	local bw, bd = fp.X * 0.8, fp.Z * 0.52
	local cz = -fp.Z * 0.5 + bd * 0.5 + 1
	local frontZ = block(add, bw, h, bd, spec.wall, Enum.Material.Brick, 0, cz)
	add("Plinth", Vector3.new(bw + 0.8, 2, bd + 0.8), spec.accent, Enum.Material.SmoothPlastic, Vector3.new(0, 1, cz))
	parapet(add, bw, bd, spec.roof, h, cz)
	add("Door", Vector3.new(6, 6, 0.6), spec.accent, Enum.Material.SmoothPlastic, Vector3.new(0, 3, frontZ))
	add("Canopy", Vector3.new(10, 0.8, 4), spec.accent, Enum.Material.SmoothPlastic, Vector3.new(0, 6.2, frontZ + 2))
	windowBand(add, 4, bw * 0.86, h * 0.66, frontZ, 3)
	windowBand(add, 4, bw * 0.86, h * 0.3, frontZ, 3)
	add("Playground", Vector3.new(fp.X * 0.3, 0.32, fp.Z * 0.26), Color3.fromRGB(196, 150, 90), Enum.Material.Sand, Vector3.new(fp.X * 0.3, 0.18, -fp.Z * 0.28))
end

local function buildHighSchool(add: Adder, spec: any, fp: Vector3)
	local h = spec.height
	local bw, bd = fp.X * 0.82, fp.Z * 0.5
	local cz = -fp.Z * 0.5 + bd * 0.5 + 1
	local frontZ = block(add, bw, h, bd, spec.wall, Enum.Material.Concrete, 0, cz)
	parapet(add, bw, bd, spec.roof, h, cz)
	-- horizontal glass bands per floor
	for f = 1, 3 do
		windowBand(add, 6, bw * 0.9, h * (f / 4), frontZ, 2.6)
	end
	-- entrance canopy on two columns
	add("Canopy", Vector3.new(14, 1, 6), spec.accent, Enum.Material.Concrete, Vector3.new(0, 7, frontZ + 3))
	columns(add, 2, 12, 7, frontZ + 5, PAVE)
	add("Door", Vector3.new(10, 7, 0.6), GLASS, Enum.Material.Glass, Vector3.new(0, 3.5, frontZ))
	-- sports field to one side
	add("Field", Vector3.new(fp.X * 0.32, 0.32, fp.Z * 0.34), Color3.fromRGB(96, 156, 92), Enum.Material.Grass, Vector3.new(fp.X * 0.32, 0.18, -fp.Z * 0.24))
	add("Track", Vector3.new(fp.X * 0.36, 0.3, fp.Z * 0.38), Color3.fromRGB(176, 92, 72), Enum.Material.Concrete, Vector3.new(fp.X * 0.32, 0.15, -fp.Z * 0.24))
end

local function buildUniversity(add: Adder, spec: any, fp: Vector3)
	local h = spec.height
	local bw, bd = fp.X * 0.5, fp.Z * 0.5
	local cz = -fp.Z * 0.5 + bd * 0.5 + 1
	local frontZ = block(add, bw, h, bd, spec.wall, Enum.Material.Concrete, 0, cz)
	parapet(add, bw, bd, spec.roof, h, cz)
	-- two lower side wings
	for _, sx in { -1, 1 } do
		local ww = fp.X * 0.24
		add("Wing", Vector3.new(ww, h * 0.7, bd * 0.86), spec.wall, Enum.Material.Concrete, Vector3.new(sx * (bw * 0.5 + ww * 0.5), h * 0.35, cz))
	end
	-- portico: 4 columns + entablature + pediment band
	columns(add, 4, bw * 0.8, h * 0.7, frontZ + 4, PAVE)
	add("Entablature", Vector3.new(bw * 0.92, 2.4, 6), PAVE, Enum.Material.Concrete, Vector3.new(0, h * 0.7 + 1.2, frontZ + 4))
	add("Pediment", Vector3.new(bw * 0.92, 4, 1), spec.accent, Enum.Material.Concrete, Vector3.new(0, h * 0.7 + 4, frontZ + 4))
	-- clock disc + steps + glass entrance
	add("Clock", Vector3.new(5, 5, 0.5), Color3.fromRGB(238, 236, 226), Enum.Material.SmoothPlastic, Vector3.new(0, h * 0.78, frontZ))
	add("Steps", Vector3.new(bw * 0.9, 1.4, 6), PAVE, Enum.Material.Concrete, Vector3.new(0, 0.7, frontZ + 4))
	for f = 1, 3 do
		windowBand(add, 8, bw * 0.9, h * (f / 4), frontZ, 2.6)
	end
end

local function buildLibrary(add: Adder, spec: any, fp: Vector3)
	local h = spec.height
	local bw, bd = fp.X * 0.74, fp.Z * 0.5
	local cz = -fp.Z * 0.5 + bd * 0.5 + 1
	add("Plinth", Vector3.new(bw + 4, 1.6, bd + 6), PAVE, Enum.Material.Concrete, Vector3.new(0, 0.8, cz + 1))
	local frontZ = block(add, bw, h, bd, spec.wall, Enum.Material.Brick, 0, cz)
	parapet(add, bw, bd, spec.roof, h, cz)
	columns(add, 4, bw * 0.82, h * 0.82, frontZ + 2.4, PAVE)
	add("Entablature", Vector3.new(bw * 0.92, 2, 4), PAVE, Enum.Material.Concrete, Vector3.new(0, h * 0.82 + 1, frontZ + 2.4))
	add("Sign", Vector3.new(bw * 0.6, 1.6, 0.4), spec.accent, Enum.Material.SmoothPlastic, Vector3.new(0, h * 0.7, frontZ))
	add("Door", Vector3.new(7, 7, 0.6), GLASS, Enum.Material.Glass, Vector3.new(0, 3.5, frontZ))
end

-- Build the education building of `key`. `ghost` makes it translucent + non-queryable.
function SchoolModel.build(key: string, ghost: boolean?): Model?
	local spec = SchoolTypes.get(key)
	if not spec then return nil end
	local fp = SchoolTypes.footprintStuds(spec)

	local model = Instance.new("Model")
	model.Name = "School_" .. key

	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(2, 1, 2)
	root.Transparency = 1
	root.Anchored = true
	root.CanCollide = false
	root.CanQuery = false
	root.Parent = model
	model.PrimaryPart = root

	local add = makeAdder(model, root, ghost or false)
	local frontZ = fp.Z * 0.5
	grounds(add, fp, spec.accent, frontZ)

	if spec.category == "Library" then
		buildLibrary(add, spec, fp)
	elseif key == "HighSchool" then
		buildHighSchool(add, spec, fp)
	elseif key == "University" then
		buildUniversity(add, spec, fp)
	else
		buildElementary(add, spec, fp)
	end

	-- Half-size city (ZoneGrid.WORLD_SCALE): the campus is authored full size with absolute
	-- detail dims (doors, flagpole), so scale the finished model uniformly. Covers server
	-- placement AND the client ghost (both call build).
	if ZoneGrid.BUILDING_SCALE ~= 1 then
		model:ScaleTo(ZoneGrid.BUILDING_SCALE)
	end

	return model
end

-- Where pupils gather/enter: a few studs out from the front door at ground level.
function SchoolModel.entrance(key: string, cf: CFrame): Vector3
	local spec = SchoolTypes.get(key)
	local depth = if spec then SchoolTypes.footprintStuds(spec).Z else 20
	return (cf * CFrame.new(0, 0, depth * 0.5 + 5)).Position
end

return SchoolModel
