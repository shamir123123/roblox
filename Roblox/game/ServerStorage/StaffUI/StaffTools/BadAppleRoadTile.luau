--!strict
-- BadAppleRoadTile -- bakes ONE real road stub that BadAppleShow clones to draw with.
--
-- The stub is genuine road geometry: RoadRenderer.build is the same call the game makes for
-- a road the player places, so the piece comes back with a real carriageway, real kerbs and
-- real sidewalks at the game's own widths and colours. It runs from a cell's CENTRE to one
-- cell EDGE, which is the only shape needed -- a cell that connects north and east gets two
-- clones rotated 0 and 90 degrees, a crossroads gets four, and the stubs meet in the middle.
-- One shape, four rotations, every connectivity case.
--
-- Why bake at all: on the client RoadMeshBuilder takes its PARTS path (the mesh-blob path is
-- server-only), so RoadRenderer hands back a Model of dozens of boxes and wedges. Cloning
-- that per cell would be tens of thousands of parts. Baking it into a single MeshPart once
-- means a clone is ONE part, and the clones share the baked asset.
--
-- Lane paint: RoadMeshBuilder's client parts path deliberately drops marking specs ("ghost/
-- preview parts path draws no painted lines"), so the Model that comes back has kerbs and
-- sidewalks but no paint. Since this module bakes the mesh itself, the markings are emitted
-- straight into the same EditableMesh as thin ribbons -- the same way RoadMeshView bakes
-- paint for live road, and using the same RoadConstants dimensions, dash length and colours.
--
-- The stub is one cell wide by half a cell long, so the CELL the caller picks has to be a
-- real road's full width (carriageway + both sidewalks) or the paint comes out sub-stud.

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RoadRenderer = require(ReplicatedStorage:WaitForChild("Road"):WaitForChild("RoadRenderer"))
local RoadConstants = require(ReplicatedStorage:WaitForChild("Road"):WaitForChild("RoadConstants"))

local BadAppleRoadTile = {}

local UP = Vector3.yAxis

-- A stub is a full-width road, so the cell has to fit carriageway + both sidewalks.
BadAppleRoadTile.CELL = RoadConstants.ROAD_WIDTH + RoadConstants.SIDEWALK_WIDTH * 2

local MARK_WIDTH = 0.55  -- widened slightly so markings survive the overhead camera
local MARK_LIFT  = 0.03  -- paint sits on the asphalt, under the 0.05 kerb top
local EDGE_INSET = 0.4   -- edge line sits just inside the carriageway boundary

-- Display colours, keyed by the source colour RoadRenderer emits.
--
-- RoadConstants colours are NOT what a road looks like. RoadMeshView multiplies them by a
-- MaterialVariant colour map after pre-boosting them by a gain, so ROAD_COLOR (#4a4d52) is
-- an input to that product, not the result. Baking it as a flat vertex colour instead --
-- which is what this mesh does, having no texture -- renders roads as dark navy blue.
--
-- Going through the variant is not an option here: one mesh takes one material, and the
-- gains that make asphalt right (3.5) clamp the sidewalk to white, so both families would
-- come out identical. The camera is far enough up that texture grain is invisible anyway,
-- so these are flat colours picked to match what a placed road actually looks like on screen.
local DISPLAY: { [string]: Color3 } = {
	["4a4d52"] = Color3.fromRGB(138, 139, 141), -- carriageway: neutral mid grey, not blue
	["d0cabd"] = Color3.fromRGB(241, 239, 234), -- footway: near white
}
-- Anything not named above (trim, verge) still needs lifting out of the same darkness.
local FALLBACK_GAIN = 2.6

-- Exposed so a junction patch can be paved in exactly the carriageway's colour -- a patch
-- even slightly off would outline every junction instead of hiding it.
BadAppleRoadTile.ROAD_DISPLAY = DISPLAY["4a4d52"]

type Ribbon = {
	a: Vector3,
	b: Vector3,
	color: Color3,
	dashed: boolean,
}

-- Same corner/face tables RoadMeshView bakes with -- a Part is a box and a WedgePart is a
-- wedge, and these are those two solids in the engine's corner order.
local BOX_CORNERS = {
	Vector3.new(-1, -1, -1), Vector3.new(1, -1, -1), Vector3.new(1, -1, 1), Vector3.new(-1, -1, 1),
	Vector3.new(-1, 1, -1), Vector3.new(1, 1, -1), Vector3.new(1, 1, 1), Vector3.new(-1, 1, 1),
}
local BOX_FACES = {
	{ n = Vector3.new(0, -1, 0), tris = { { 1, 2, 3 }, { 1, 3, 4 } } },
	{ n = Vector3.new(0, 1, 0), tris = { { 5, 6, 7 }, { 5, 7, 8 } } },
	{ n = Vector3.new(0, 0, -1), tris = { { 1, 2, 6 }, { 1, 6, 5 } } },
	{ n = Vector3.new(0, 0, 1), tris = { { 4, 3, 7 }, { 4, 7, 8 } } },
	{ n = Vector3.new(-1, 0, 0), tris = { { 1, 5, 8 }, { 1, 8, 4 } } },
	{ n = Vector3.new(1, 0, 0), tris = { { 2, 3, 7 }, { 2, 7, 6 } } },
}
local WEDGE_CORNERS = {
	Vector3.new(-1, -1, -1), Vector3.new(1, -1, -1), Vector3.new(1, -1, 1), Vector3.new(-1, -1, 1),
	Vector3.new(-1, 1, 1), Vector3.new(1, 1, 1),
}
local WEDGE_FACES = {
	{ n = Vector3.new(0, -1, 0), tris = { { 1, 2, 3 }, { 1, 3, 4 } } },
	{ n = Vector3.new(0, 0, 1), tris = { { 4, 3, 6 }, { 4, 6, 5 } } },
	{ n = Vector3.new(-1, 0, 0), tris = { { 1, 4, 5 } } },
	{ n = Vector3.new(1, 0, 0), tris = { { 2, 3, 6 } } },
}

-- Collapse a Model of road Parts into one MeshPart, keeping each part's colour as vertex
-- colour. `origin` is subtracted from every vertex so the mesh sits about its own centre.
local function bakeModel(model: Model, origin: Vector3, ribbons: { Ribbon }): MeshPart
	local em = AssetService:CreateEditableMesh()
	assert(em, "[BadAppleRoadTile] EditableMesh budget exhausted")

	local colorIds: { [string]: number } = {}
	local function colorId(c: Color3): number
		local key = c:ToHex()
		local id = colorIds[key]
		if not id then
			local shown = DISPLAY[string.lower(key)]
			if not shown then
				shown = Color3.new(
					math.min(c.R * FALLBACK_GAIN, 1),
					math.min(c.G * FALLBACK_GAIN, 1),
					math.min(c.B * FALLBACK_GAIN, 1)
				)
			end
			id = em:AddColor(shown, 1)
			colorIds[key] = id
		end
		return id
	end

	local ok, meshOrErr = pcall(function(): MeshPart
		for _, d in model:GetDescendants() do
			if not d:IsA("BasePart") then
				continue
			end
			local isWedge = d:IsA("WedgePart")
			local corners = if isWedge then WEDGE_CORNERS else BOX_CORNERS
			local faces = if isWedge then WEDGE_FACES else BOX_FACES
			local cf, half = d.CFrame, d.Size * 0.5
			local cid = colorId(d.Color)

			local ids = table.create(#corners)
			for i, c in corners do
				ids[i] = em:AddVertex(cf:PointToWorldSpace(half * c) - origin)
			end
			for _, face in faces do
				local worldN = cf:VectorToWorldSpace(face.n)
				local nid = em:AddNormal(worldN)
				for _, t in face.tris do
					local fid = em:AddTriangle(ids[t[1]], ids[t[2]], ids[t[3]])
					em:SetFaceColors(fid, { cid, cid, cid })
					em:SetFaceNormals(fid, { nid, nid, nid })
				end
			end
		end

		-- Paint, laid over the asphalt as flat ribbons. Dashed lines emit one quad per dash
		-- with bare gaps between, exactly as RoadMeshView does -- Roblox will not honour
		-- alpha on a MeshPart texture, so a gap has to be absent geometry, not a clear pixel.
		local upId = em:AddNormal(UP)
		local function quad(a: Vector3, b: Vector3, side: Vector3, cid: number)
			local v1 = em:AddVertex(a - side - origin)
			local v2 = em:AddVertex(a + side - origin)
			local v3 = em:AddVertex(b + side - origin)
			local v4 = em:AddVertex(b - side - origin)
			for _, tri in { { v1, v2, v3 }, { v1, v3, v4 } } do
				local fid = em:AddTriangle(tri[1], tri[2], tri[3])
				em:SetFaceColors(fid, { cid, cid, cid })
				em:SetFaceNormals(fid, { upId, upId, upId })
			end
		end

		local pitch = RoadConstants.DASH_LENGTH + RoadConstants.DASH_GAP
		for _, r in ribbons do
			local delta = r.b - r.a
			local len = delta.Magnitude
			if len < 1e-6 then
				continue
			end
			local dir = delta.Unit
			local side = dir:Cross(UP)
			if side.Magnitude < 1e-6 then
				continue
			end
			side = side.Unit * (MARK_WIDTH * 0.5)
			local cid = colorId(r.color)
			if not r.dashed then
				quad(r.a, r.b, side, cid)
				continue
			end
			-- Phase starts at the stub's own origin (the cell centre), so two opposite stubs
			-- put a single unbroken dash through the middle of the cell rather than meeting
			-- mid-gap and looking broken.
			local at = 0
			while at < len do
				local stop = math.min(at + RoadConstants.DASH_LENGTH, len)
				quad(r.a + dir * at, r.a + dir * stop, side, cid)
				at += pitch
			end
		end

		-- STATIC content, exactly as RoadMeshView does: the MeshPart owns a static copy, so
		-- the EditableMesh can die immediately instead of sitting on the client's tiny
		-- Editable* memory budget.
		local result, content = AssetService:CreateDataModelContentAsync(Content.fromObject(em))
		if result ~= Enum.CreateContentResult.Success then
			error(`CreateDataModelContentAsync failed: {tostring(result)}`)
		end
		return AssetService:CreateMeshPartAsync(content, {
			CollisionFidelity = Enum.CollisionFidelity.Box,
		})
	end)
	em:Destroy()
	if not ok then
		error(meshOrErr)
	end

	local mesh = meshOrErr :: MeshPart
	mesh.Anchored = true
	mesh.CanCollide = false
	mesh.CanQuery = false
	mesh.CanTouch = false
	mesh.CastShadow = false
	mesh.DoubleSided = true -- the source parts are not wound consistently for culling
	mesh.Material = Enum.Material.SmoothPlastic
	mesh.Color = Color3.new(1, 1, 1) -- let the baked vertex colours through untinted
	return mesh
end

-- Build the stub: a straight road from the cell centre out to the +Z cell edge, sized so its
-- full width fits the cell. Callers rotate it about the cell centre to reach the other three
-- directions, so +Z is simply "the reference direction".
--
-- Returns an UNPARENTED template. Clone it; do not reparent the original.
-- `reach` is how far the stub runs from the cell centre: half the centre-to-centre distance
-- to whichever neighbour it connects to, so an orthogonal link and a diagonal one need
-- different lengths and therefore separate bakes.
function BadAppleRoadTile.build(reach: number): MeshPart
	-- Real road dimensions, not fractions of the cell: this is what makes the stub read as
	-- the game's own road and keeps the paint at a sane width.
	local width = RoadConstants.ROAD_WIDTH
	local sidewalkWidth = RoadConstants.SIDEWALK_WIDTH

	local holder = Instance.new("Model")
	local a = Vector3.new(0, 0, 0)
	local b = Vector3.new(0, 0, reach)
	-- Straight run: the two inner Bezier handles sit on the line, so no curvature.
	RoadRenderer.build(
		a,
		a:Lerp(b, 1 / 3),
		a:Lerp(b, 2 / 3),
		b,
		holder,
		{
			color = RoadConstants.ROAD_COLOR,
			width = width,
			anchored = true,
			canCollide = false,
			sidewalk = true,
			sidewalkColor = RoadConstants.SIDEWALK_COLOR,
			sidewalkWidth = sidewalkWidth,
		}
	)

	-- Use solid markings: their width is stable when a template is stretched to a traced run,
	-- and they stay legible from the fixed overhead camera.
	local centre = MARK_WIDTH * 1.2
	local edge = width * 0.5 - EDGE_INSET
	local marking = Color3.fromRGB(255, 210, 60)
	local white = Color3.new(1, 1, 1)
	local ribbons: { Ribbon } = {
		{ a = Vector3.new(-centre, MARK_LIFT, 0), b = Vector3.new(-centre, MARK_LIFT, reach), color = marking, dashed = false },
		{ a = Vector3.new(centre, MARK_LIFT, 0), b = Vector3.new(centre, MARK_LIFT, reach), color = marking, dashed = false },
		{ a = Vector3.new(-edge, MARK_LIFT, 0), b = Vector3.new(-edge, MARK_LIFT, reach), color = white, dashed = false },
		{ a = Vector3.new(edge, MARK_LIFT, 0), b = Vector3.new(edge, MARK_LIFT, reach), color = white, dashed = false },
	}

	-- Bake about the stub's MIDPOINT, not its start. A MeshPart always draws its geometry
	-- centred on its own CFrame, so baking from the start pushes the road half a stub
	-- outward from wherever it is placed -- which leaves a hole at every cell centre and
	-- makes a continuous run read as disconnected dashes.
	local mesh = bakeModel(holder, Vector3.new(0, 0, reach * 0.5), ribbons)
	holder:Destroy()
	mesh.Name = "BadAppleRoadStub"
	return mesh
end

return BadAppleRoadTile
