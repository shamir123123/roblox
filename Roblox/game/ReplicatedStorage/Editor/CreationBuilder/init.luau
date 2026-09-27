--!strict
-- CreationBuilder
-- Turns a saved creation blob back into geometry. ONE implementation, shared by the
-- Creation Editor (rebuilding a session), CreationPlaceService (standing a creation up
-- in the city) and the client (the placement ghost). Three copies of a restore walk is
-- exactly how the placement tools drifted before GhostPlacement -- see its header.
--
-- Model resolution is INJECTED because the callers live in different realms: the server
-- walks ServerStorage.Templates, the client can only see ReplicatedStorage. A resolver
-- that returns nil yields a grey placeholder box rather than a hole, so a ghost still
-- shows the right silhouette for a prop the client cannot see.
--
-- Pure: no session, no EditorId tagging, no parenting. build() hands back a DETACHED
-- Model whose WorldPivot is its own base centre, so one PivotTo() from a grounded
-- placement pivot seats it on the terrain. The caller decides what it is.

local CreationBuilder = {}

-- The primitive palette, shared with the Nature tab. Five shapes are native part types
-- built here; the rest were baked once into ReplicatedStorage.Nature (see
-- ServerStorage.Authoring.ShapeBuilder) and are cloned from there. Every one of them is a
-- SINGLE BasePart either way, which is what lets a shape ride the existing t="p" element
-- format -- its own size, colour, material and sound, no new blob fields.
local ShapeCatalog = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("ShapeCatalog"))

CreationBuilder.SHAPES = ShapeCatalog.all

-- Must match EditorService.MATERIALS: the blob stores the NAME, and an unknown name
-- leaves the part's default material rather than erroring on a bad Enum lookup.
local MATERIALS: { [string]: Enum.Material } = table.freeze({
	Plastic = Enum.Material.Plastic, Wood = Enum.Material.Wood, Metal = Enum.Material.Metal,
	Concrete = Enum.Material.Concrete, Brick = Enum.Material.Brick, Glass = Enum.Material.Glass,
	Neon = Enum.Material.Neon, Grass = Enum.Material.Grass,
})

-- Same ceiling as EditorService.CONFIG.MaxElements. A blob only ever comes from our own
-- store, but the builder is the last thing standing between a corrupt row and a hang.
local MAX_ELEMENTS = 500
local SOUND_NAME = "EditorSound"

export type Resolver = (key: string) -> Model?

-- == DataStore-safe converters (CFrame/Vector3/Color3 <-> number arrays) ========
-- DataStore cannot hold CFrame/Vector3/Color3, so the blob is plain number arrays.
-- Both directions live here so the writer and the reader can never disagree.
function CreationBuilder.cfToArr(cf: CFrame): { number } return { cf:GetComponents() } end

function CreationBuilder.arrToCf(a: any): CFrame
	if typeof(a) == "table" and #a >= 12 then return CFrame.new(table.unpack(a)) end
	return CFrame.identity
end

function CreationBuilder.v3ToArr(v: Vector3): { number } return { v.X, v.Y, v.Z } end

function CreationBuilder.arrToV3(a: any): Vector3
	if typeof(a) == "table" then return Vector3.new(tonumber(a[1]) or 0, tonumber(a[2]) or 0, tonumber(a[3]) or 0) end
	return Vector3.zero
end

function CreationBuilder.colToArr(c: Color3): { number }
	return { math.round(c.R * 255), math.round(c.G * 255), math.round(c.B * 255) }
end

function CreationBuilder.arrToCol(a: any): Color3
	if typeof(a) == "table" then return Color3.fromRGB(tonumber(a[1]) or 200, tonumber(a[2]) or 200, tonumber(a[3]) or 200) end
	return Color3.fromRGB(200, 200, 200)
end

local arrToCf = CreationBuilder.arrToCf
local arrToV3 = CreationBuilder.arrToV3
local arrToCol = CreationBuilder.arrToCol

-- == Element helpers ===========================================================
-- Returns the part at its OWN natural size -- a baked shape is not a cube, and forcing one
-- to 4x4x4 would squash every ring and beam in the palette. restorePrimitive overwrites
-- the size from the blob straight after, so this only shapes a fresh spawn.
function CreationBuilder.makePrimitive(shape: string): BasePart?
	local def = ShapeCatalog.get(shape)
	if not def then return nil end

	local n = def.native
	if n then
		local p = Instance.new(n.class) :: BasePart
		if n.partType and p:IsA("Part") then (p :: Part).Shape = n.partType end
		p.Size = n.size
		return p
	end

	-- Baked: the world template's single BasePart, without the Model wrapper or any Sound
	-- the editor may have hung on a previous copy.
	local folder = game:GetService("ReplicatedStorage"):FindFirstChild("Nature")
	local model = folder and folder:FindFirstChild(shape)
	if not model then return nil end
	for _, d in model:GetChildren() do
		if d:IsA("BasePart") then
			local c = d:Clone()
			c:ClearAllChildren()
			c.CanQuery = true
			c.CFrame = CFrame.identity
			return c
		end
	end
	return nil
end

function CreationBuilder.applyMaterial(part: BasePart, matName: any)
	if typeof(matName) == "string" then
		local mat = MATERIALS[matName]
		if mat then part.Material = mat; part:SetAttribute("Mat", matName) end
	end
end

-- Numeric asset ids only, same as the editor: whatever the player typed is reduced to
-- its digits so a pasted URL and a bare id land on the same SoundId.
function CreationBuilder.normalizeSoundId(raw: any): string?
	if typeof(raw) ~= "string" then return nil end
	local digits = string.match(raw, "%d+")
	if not digits then return nil end
	return "rbxassetid://" .. digits
end

function CreationBuilder.applySound(part: BasePart, soundId: string?, volume: any)
	local existing = part:FindFirstChild(SOUND_NAME)
	if not soundId then
		if existing then existing:Destroy() end
		part:SetAttribute("SoundId", nil)
		part:SetAttribute("SoundVol", nil)
		return
	end
	local vol = math.clamp(tonumber(volume) or 0.5, 0, 10)
	local snd = if existing and existing:IsA("Sound") then existing :: Sound else Instance.new("Sound")
	snd.Name = SOUND_NAME
	snd.SoundId = soundId
	snd.Looped = true
	snd.Volume = vol
	snd.RollOffMode = Enum.RollOffMode.InverseTapered
	snd.Parent = part
	snd.Playing = true
	part:SetAttribute("SoundId", soundId)
	part:SetAttribute("SoundVol", vol)
end

function CreationBuilder.readSound(part: BasePart): (string?, number?)
	local sid = part:GetAttribute("SoundId")
	if typeof(sid) ~= "string" then return nil, nil end
	local vol = part:GetAttribute("SoundVol")
	return sid :: string, if typeof(vol) == "number" then vol :: number else nil
end

-- Anchor everything and make it raycast-hittable. Catalog props ship CanQuery=false for
-- the live game, but a placed creation must be clickable -- the bulldozer picks it with a
-- ray. Fully invisible helper parts stay unhittable so they cannot steal the click.
function CreationBuilder.anchorAll(inst: Instance)
	local function prep(p: BasePart)
		p.Anchored = true
		p.CanQuery = p.Transparency < 1
	end
	if inst:IsA("BasePart") then prep(inst :: BasePart) end
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") then prep(d :: BasePart) end
	end
end

-- A prop the resolver could not supply. Sized from the blob's own scale so the ghost's
-- silhouette stays honest instead of collapsing to nothing.
local function placeholder(scale: number): Model
	local m = Instance.new("Model")
	local p = Instance.new("Part")
	p.Name = "Unresolved"
	p.Size = Vector3.new(4, 4, 4) * math.clamp(scale, 0.1, 10)
	p.Color = Color3.fromRGB(150, 150, 155)
	p.Material = Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.Parent = m
	m.PrimaryPart = p
	return m
end

-- == Restore ===================================================================
local function restorePrimitive(parent: Instance, e: any, atCf: CFrame?): boolean
	if typeof(e.shape) ~= "string" then return false end
	local part = CreationBuilder.makePrimitive(e.shape)
	if not part then return false end
	part.Anchored = true
	part.Size = arrToV3(e.sz)
	part.CFrame = atCf or arrToCf(e.cf)
	part.Color = arrToCol(e.c)
	part.Transparency = tonumber(e.tr) or 0
	CreationBuilder.applyMaterial(part, e.m)
	if typeof(e.sid) == "string" then CreationBuilder.applySound(part, e.sid, e.vol) end
	part:SetAttribute("Shape", e.shape)
	part:SetAttribute("BaseSize", part.Size)
	part.Parent = parent
	return true
end

-- A free composition: loose primitives (t="p") and whole prop models (t="r").
local function restoreElements(parent: Instance, el: any, resolve: Resolver?): number
	if typeof(el) ~= "table" then return 0 end
	local n = 0
	for _, e in el do
		if n >= MAX_ELEMENTS then break end
		if typeof(e) ~= "table" then continue end
		if e.t == "p" then
			if restorePrimitive(parent, e) then n += 1 end
		elseif e.t == "r" and typeof(e.key) == "string" then
			local scale = tonumber(e.sc) or 1
			local src = if resolve then resolve(e.key) else nil
			local clone = if src and src:IsA("Model") then src:Clone() else placeholder(scale)
			CreationBuilder.anchorAll(clone)
			clone:SetAttribute("AssetKey", e.key)
			if src and scale ~= 1 then clone:ScaleTo(scale) end
			clone:PivotTo(arrToCf(e.cf))
			clone.Parent = parent
			n += 1
		end
	end
	return n
end

-- A customised real building: the base model with per-part overrides, plus any loose
-- primitives the player added. Overrides are matched by descendant ORDER (PartIdx),
-- which is stable only because the base model is cloned from the same template.
local function restoreCustom(parent: Instance, record: any, resolve: Resolver?): number
	if typeof(record.base) ~= "string" then return 0 end
	local src = if resolve then resolve(record.base) else nil
	if not (src and src:IsA("Model")) then return 0 end

	local clone = src:Clone()
	CreationBuilder.anchorAll(clone)
	clone:SetAttribute("AssetKey", record.base)
	clone:SetAttribute("CustomRoot", true)
	local rootCf = arrToCf(record.root)
	clone:PivotTo(rootCf)
	clone.Parent = parent

	local n = 1
	local parts: { BasePart } = {}
	for _, d in clone:GetDescendants() do
		if d:IsA("BasePart") then table.insert(parts, d :: BasePart) end
	end
	-- A part with no saved override was deleted in the editor; drop it here too.
	for i, d in parts do
		local ov = if typeof(record.parts) == "table" then record.parts[tostring(i)] else nil
		if ov and d.Parent then
			d.Size = arrToV3(ov.sz)
			d.CFrame = rootCf * arrToCf(ov.cf)
			d.Color = arrToCol(ov.c)
			d.Transparency = tonumber(ov.tr) or 0
			CreationBuilder.applyMaterial(d, ov.m)
			if typeof(ov.sid) == "string" then CreationBuilder.applySound(d, ov.sid, ov.vol) end
			d:SetAttribute("PartIdx", i)
			d:SetAttribute("BaseSize", d.Size)
		elseif d.Parent then
			d:Destroy()
		end
	end

	if typeof(record.prims) == "table" then
		for _, e in record.prims do
			if n >= MAX_ELEMENTS then break end
			-- Custom prims are stored RELATIVE to the root so the whole thing moves as one.
			if typeof(e) == "table" and restorePrimitive(parent, e, rootCf * arrToCf(e.cf)) then n += 1 end
		end
	end
	return n
end

-- Re-seat the model's pivot on its own base centre. The blob's CFrames are absolute
-- coordinates around EditorConfig.Origin (0, 1000, 0); a caller placing this in the city
-- has a grounded pivot on the terrain and must be able to PivotTo() it directly.
local function reseat(model: Model)
	local bcf, bsize = model:GetBoundingBox()
	model.WorldPivot = CFrame.new(bcf.Position.X, bcf.Position.Y - bsize.Y * 0.5, bcf.Position.Z)
end

-- Build `blob` into a detached Model, or nil if it produced nothing. `resolve` maps an
-- asset key to a source Model; pass nil to get placeholders for every prop.
-- Returns the model and the element count actually built.
function CreationBuilder.build(blob: any, resolve: Resolver?): (Model?, number)
	if typeof(blob) ~= "table" then return nil, 0 end

	local model = Instance.new("Model")
	model.Name = "Creation"

	local n: number
	-- Same discrimination as EditorService.restoreCreation: `kind` is authoritative, but
	-- `parts` identifies a custom record written before the field existed.
	if blob.kind == "custom" or blob.parts then
		n = restoreCustom(model, blob, resolve)
	else
		n = restoreElements(model, blob.el, resolve)
	end

	if n == 0 then
		model:Destroy()
		return nil, 0
	end

	reseat(model)
	return model, n
end

-- Element count without building anything -- for cost, listings and size guards.
function CreationBuilder.count(blob: any): number
	if typeof(blob) ~= "table" then return 0 end
	if blob.kind == "custom" or blob.parts then
		local n = 0
		if typeof(blob.parts) == "table" then
			for _ in blob.parts do n += 1 end
		end
		if typeof(blob.prims) == "table" then n += #blob.prims end
		return n
	end
	return if typeof(blob.el) == "table" then #blob.el else 0
end

return CreationBuilder
