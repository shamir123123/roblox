--!strict
-- EditorService
-- Server authority for the in-world Creation Editor. Owns each player's isolated edit
-- session (workspace._Editor/Session_<uid> at EditorConfig.Origin), the spawnable-asset
-- catalog (walked from ServerStorage.Templates), and every mutation the client requests
-- (spawn / primitive / transform / scale / size / appearance / duplicate / delete / clear /
-- grabPart / customize / load). A saved creation is a blueprint: the design blob goes to
-- BlueprintStore's own DataStore (one key each, 4 MB to itself) and only a small index row
-- lands on the player record. Serialized as plain number arrays -- DataStore cannot hold
-- CFrame/Vector3/Color3.
--
-- REBUILT 2026-07-04 from design notes after the original module was deleted from the
-- place. Same client contract (RequestEditorCommand / RequestEditorData / Enter / Exit).

local RS  = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")
local SS  = game:GetService("ServerStorage")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")

local Net           = require(RS:WaitForChild("Networker"))
local NetMiddleware  = require(RS:WaitForChild("NetMiddleware"))
local EditorConfig   = require(RS:WaitForChild("Editor"):WaitForChild("EditorConfig"))
local CreationCategories = require(RS:WaitForChild("Editor"):WaitForChild("CreationCategories"))
local CreationBuilder = require(RS:WaitForChild("Editor"):WaitForChild("CreationBuilder"))

local EditorService = {}

local CONFIG = table.freeze({
	EnterCooldown   = 0.4,
	ExitCooldown    = 0.4,
	SpawnCooldown   = 0.05,
	MaxNameLen      = 40,
	MaxCreations    = 60,
	MaxElements     = 500,
	-- Ceiling on what a creator may charge for a creation. Player-authored, and it spends
	-- from a city treasury, so it is clamped on the way IN rather than at display time.
	MaxPrice        = 1000000,
	-- A creation has to fit somewhere in a city; a lot is 16 studs, so this is already
	-- generous for a landmark. The plate is 2048 wide, and pieces flung to opposite ends of
	-- it make a design that is technically valid and permanently unplaceable.
	MaxSpan         = 256,
	-- Total across one player's blueprints. No longer a DataStore limit (each blueprint is
	-- its own 4 MB key) -- just a fairness cap so one player cannot hoard the store.
	CreationsBudget = 20000000,
})

local MATERIALS: { [string]: Enum.Material } = {
	Plastic = Enum.Material.Plastic, Wood = Enum.Material.Wood, Metal = Enum.Material.Metal,
	Concrete = Enum.Material.Concrete, Brick = Enum.Material.Brick, Glass = Enum.Material.Glass,
	Neon = Enum.Material.Neon, Grass = Enum.Material.Grass,
}

local TILE = 16 -- must match ZoneGrid.LOT_SIZE (authoritative lot spacing)

type Session = {
	root: Folder,
	content: Folder,
	nextId: number,
	objects: { [number]: Instance },
	baseKey: string?,
	bounds: { hx: number, hz: number }?, -- allowed half-footprint (customize mode), centred on EditorConfig.Origin
	undoStack: { any },
	redoStack: { any },
	_lastUndo: { at: number, action: string, id: any }?,
}

type CatEntry = { key: string, name: string, cat: string }

local _sessions: { [number]: Session } = {}
local _catalog: { CatEntry } = {}
local _modelByKey: { [string]: Model } = {}
local _catByKey: { [string]: string } = {}
local _lastSpawnAt: { [number]: number } = {}
local _pds: any = nil
local _bp: any = nil

-- == DataStore-safe converters (CFrame/Vector3/Color3 -> number arrays) =========
local function cfToArr(cf: CFrame): { number } return { cf:GetComponents() } end
local function arrToCf(a: any): CFrame
	if typeof(a) == "table" and #a >= 12 then return CFrame.new(table.unpack(a)) end
	return CFrame.identity
end
local function v3ToArr(v: Vector3): { number } return { v.X, v.Y, v.Z } end
local function arrToV3(a: any): Vector3
	if typeof(a) == "table" then return Vector3.new(tonumber(a[1]) or 0, tonumber(a[2]) or 0, tonumber(a[3]) or 0) end
	return Vector3.zero
end
local function colToArr(c: Color3): { number } return { math.round(c.R * 255), math.round(c.G * 255), math.round(c.B * 255) } end
local function arrToCol(a: any): Color3
	if typeof(a) == "table" then return Color3.fromRGB(tonumber(a[1]) or 200, tonumber(a[2]) or 200, tonumber(a[3]) or 200) end
	return Color3.fromRGB(200, 200, 200)
end

-- == Element helpers ===========================================================
-- One implementation of "what is shape X", shared with the client's ghost and with
-- CreationPlaceService. This used to be a second copy of a four-shape if-chain; with sixty
-- shapes, half of them baked geometry, two copies would have been a standing bug.
local makePrimitive = CreationBuilder.makePrimitive

local function applyMaterial(part: BasePart, matName: any)
	if typeof(matName) == "string" then
		local mat = MATERIALS[matName]
		if mat then part.Material = mat; part:SetAttribute("Mat", matName) end
	end
end

-- == Sound =====================================================================
-- A placed shape can carry one looped Sound so a creation can hum / chime / play
-- ambience. Stored as attributes (SoundId string, SoundVol number) so the
-- existing serializers persist it as plain data.
-- ponytail: numeric asset ids only; add rbxasset:// library sounds if anyone needs them.
local SOUND_NAME = "EditorSound"

local function normalizeSoundId(raw: any): string?
	if typeof(raw) ~= "string" then return nil end
	local digits = string.match(raw, "%d+")
	if not digits then return nil end
	return "rbxassetid://" .. digits
end

local function applySound(part: BasePart, soundId: string?, volume: any)
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

local function readSound(part: BasePart): (string?, number?)
	local sid = part:GetAttribute("SoundId")
	if typeof(sid) ~= "string" then return nil, nil end
	local vol = part:GetAttribute("SoundVol")
	return sid :: string, if typeof(vol) == "number" then vol :: number else nil
end

-- Anchor every part + make it raycast-hittable (catalog parts often ship CanQuery=false
-- for the live game; here the click-to-select ray must reach them). Fully invisible
-- helper parts stay unhittable so they can't steal selection clicks from what's visible.
local function anchorAll(inst: Instance)
	local function prep(p: BasePart)
		p.Anchored = true
		p.CanQuery = p.Transparency < 1
	end
	if inst:IsA("BasePart") then prep(inst) end
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") then prep(d :: BasePart) end
	end
end

-- == Session ===================================================================
local function editorRoot(): Folder
	local r = workspace:FindFirstChild("_Editor")
	if not (r and r:IsA("Folder")) then
		if r then r:Destroy() end
		r = Instance.new("Folder"); r.Name = "_Editor"; r.Parent = workspace
	end
	return r :: Folder
end

local function ensureSession(player: Player): Session
	local uid = player.UserId
	local existing = _sessions[uid]
	if existing and existing.root.Parent then return existing end

	local root = Instance.new("Folder")
	root.Name = "Session_" .. uid
	root.Parent = editorRoot()

	-- Build surface = a copy of the game's Workspace baseplate (Salt/black + grid TopTexture).
	-- Top face aligned to Origin.Y so client drag-placement (plane at GROUND_TOP=Origin.Y) sits flush.
	local template = workspace:FindFirstChild("BasePlate")
	local tplPart = template and template:FindFirstChild("Baseplate")
	local slab: BasePart
	if tplPart and tplPart:IsA("BasePart") then
		slab = tplPart:Clone()
	else
		-- ponytail: fallback slab if the baseplate template is missing, so a session never fails to open.
		slab = Instance.new("Part")
		slab.Color = Color3.fromRGB(205, 208, 212)
		slab.Material = Enum.Material.SmoothPlastic
	end
	slab.Name = "Ground"
	slab.Anchored = true
	slab.CanCollide = true
	slab.CanQuery = false -- ground never selectable; click-select ray passes through it
	slab.Size = EditorConfig.GroundSize
	slab.Position = EditorConfig.Origin - Vector3.new(0, EditorConfig.GroundSize.Y / 2, 0)
	slab.TopSurface = Enum.SurfaceType.Smooth
	slab.BottomSurface = Enum.SurfaceType.Smooth
	slab.Parent = root

	local content = Instance.new("Folder")
	content.Name = "Content"
	content.Parent = root

	local session: Session = { root = root, content = content, nextId = 1, objects = {}, baseKey = nil, undoStack = {}, redoStack = {}, _lastUndo = nil }
	_sessions[uid] = session
	return session
end

local function destroySession(uid: number)
	local s = _sessions[uid]
	if s then
		if s.root then s.root:Destroy() end
		_sessions[uid] = nil
	end
	_lastSpawnAt[uid] = nil
end

local function tag(session: Session, inst: Instance): number
	local id = session.nextId
	session.nextId += 1
	inst:SetAttribute("EditorId", id)
	CollectionService:AddTag(inst, "EditorObject")
	session.objects[id] = inst
	return id
end

local function objById(session: Session, id: any): Instance?
	if typeof(id) ~= "number" then return nil end
	local inst = session.objects[id]
	if inst and inst.Parent then return inst end
	return nil
end

local function countObjects(session: Session): number
	local n = 0
	for id, inst in session.objects do
		if inst and inst.Parent then n += 1 else session.objects[id] = nil end
	end
	return n
end

local function spawnCFrame(): CFrame
	local o = EditorConfig.Origin
	return CFrame.new(o.X, o.Y, o.Z) -- plate top sits at Origin.Y; rest objects on it
end

-- == Footprint bounds (customize mode) =========================================
-- A modified asset may never outgrow its base asset's tile footprint. The
-- footprint comes from the template name ("Ind_2x3_Warehouse_v04" -> 2x3 tiles);
-- unnamed templates fall back to their bounding box rounded up to whole tiles.
local function footprintHalf(model: Model): (number, number)
	local _, size = model:GetBoundingBox()
	local a, b = string.match(model.Name, "_(%d+)x(%d+)_")
	if not a then a, b = string.match(model.Name, "^(%d+)x(%d+)_") end
	if a and b then
		local wa = (tonumber(a) :: number) * TILE
		local wb = (tonumber(b) :: number) * TILE
		-- the name doesn't say which tile axis is X; give the larger span to the
		-- larger bbox axis so orientation never falsely shrinks the box
		if (size.X >= size.Z) == (wa >= wb) then return wa / 2, wb / 2 end
		return wb / 2, wa / 2
	end
	return math.ceil(size.X / TILE) * TILE / 2, math.ceil(size.Z / TILE) * TILE / 2
end

local function setBounds(session: Session, model: Model?)
	if model then
		local hx, hz = footprintHalf(model)
		session.bounds = { hx = hx, hz = hz }
		session.root:SetAttribute("BoundsHX", hx)
		session.root:SetAttribute("BoundsHZ", hz)
	else
		session.bounds = nil
		session.root:SetAttribute("BoundsHX", nil)
		session.root:SetAttribute("BoundsHZ", nil)
	end
end

local function elementBox(inst: Instance, atPivot: CFrame?): (CFrame?, Vector3?)
	if inst:IsA("BasePart") then
		return atPivot or (inst :: BasePart).CFrame, (inst :: BasePart).Size
	elseif inst:IsA("Model") then
		local m = inst :: Model
		local bcf, bsize = m:GetBoundingBox()
		if atPivot then return (atPivot :: CFrame) * m:GetPivot():ToObjectSpace(bcf), bsize end
		return bcf, bsize
	end
	return nil, nil
end

-- world-axis AABB of an oriented box vs the session's allowed footprint
local function fitsBounds(session: Session, cf: CFrame?, size: Vector3?): boolean
	local b = session.bounds
	if not b then return true end
	if not cf or not size then return true end
	local r = cf.Rotation
	local hx = math.abs(r.XVector.X) * size.X / 2 + math.abs(r.YVector.X) * size.Y / 2 + math.abs(r.ZVector.X) * size.Z / 2
	local hz = math.abs(r.XVector.Z) * size.X / 2 + math.abs(r.YVector.Z) * size.Y / 2 + math.abs(r.ZVector.Z) * size.Z / 2
	local o = EditorConfig.Origin
	return math.abs(cf.Position.X - o.X) <= b.hx - hx + 1e-3
		and math.abs(cf.Position.Z - o.Z) <= b.hz - hz + 1e-3
end

-- == Mutators ==================================================================
local function doSpawn(session: Session, key: any)
	if typeof(key) ~= "string" then return end
	local model = _modelByKey[key]
	if not (model and model:IsA("Model")) then return end
	-- only props are composable into a creation; buildings/vehicles enter via customize
	if _catByKey[key] ~= "Props" then return end
	if countObjects(session) >= CONFIG.MaxElements then return end
	local clone = model:Clone()
	anchorAll(clone)
	clone:SetAttribute("AssetKey", key)
	local _, size = clone:GetBoundingBox()
	clone:PivotTo(spawnCFrame() * CFrame.new(0, size.Y / 2, 0))
	local bcf, bsize = elementBox(clone, nil)
	if not fitsBounds(session, bcf, bsize) then clone:Destroy(); return end
	clone.Parent = session.content
	tag(session, clone)
end

local function doPrimitive(session: Session, shape: any)
	if typeof(shape) ~= "string" then return end
	if countObjects(session) >= CONFIG.MaxElements then return end
	local part = makePrimitive(shape)
	if not part then return end
	part.Anchored = true
	part.Color = Color3.fromRGB(150, 160, 170)
	part:SetAttribute("Shape", shape)
	part:SetAttribute("BaseSize", part.Size)
	part.CFrame = spawnCFrame() * CFrame.new(0, part.Size.Y / 2, 0)
	if not fitsBounds(session, part.CFrame, part.Size) then part:Destroy(); return end
	part.Parent = session.content
	tag(session, part)
end

local function doTransform(session: Session, id: any, cf: any)
	local inst = objById(session, id)
	if inst and inst:IsA("PVInstance") and typeof(cf) == "CFrame" then
		if session.bounds then
			local bcf, bsize = elementBox(inst, cf :: CFrame)
			if not fitsBounds(session, bcf, bsize) then return end
		end
		(inst :: PVInstance):PivotTo(cf)
	end
end

local function doSetScale(session: Session, id: any, scale: any)
	local inst = objById(session, id)
	local s = tonumber(scale)
	if not inst or not s then return end
	s = math.clamp(s, 0.1, 10)
	if inst:IsA("Model") then
		local m = inst :: Model
		if session.bounds then
			local bcf, bsize = m:GetBoundingBox()
			if not fitsBounds(session, bcf, bsize * (s / m:GetScale())) then return end
		end
		m:ScaleTo(s)
	elseif inst:IsA("BasePart") then
		local base = inst:GetAttribute("BaseSize")
		if typeof(base) == "Vector3" then
			local newSize = (base :: Vector3) * s
			if not fitsBounds(session, (inst :: BasePart).CFrame, newSize) then return end
			(inst :: BasePart).Size = newSize
		end
	end
end

local function doSetSize(session: Session, id: any, size: any, cf: any)
	local inst = objById(session, id)
	if inst and inst:IsA("BasePart") and typeof(size) == "Vector3" then
		local part = inst :: BasePart
		local v = size :: Vector3
		local newSize = Vector3.new(math.clamp(v.X, 0.2, 2048), math.clamp(v.Y, 0.2, 2048), math.clamp(v.Z, 0.2, 2048))
		local newCf = if typeof(cf) == "CFrame" then cf :: CFrame else part.CFrame
		if not fitsBounds(session, newCf, newSize) then return end
		part.Size = newSize
		if typeof(cf) == "CFrame" then part:PivotTo(cf) end
	end
end

local function doAppearance(session: Session, id: any, color: any, material: any)
	local inst = objById(session, id)
	if not inst then return end
	local function paint(p: BasePart)
		if typeof(color) == "Color3" then p.Color = color end
		applyMaterial(p, material)
	end
	if inst:IsA("BasePart") then
		paint(inst :: BasePart)
	elseif inst:IsA("Model") then
		for _, d in inst:GetDescendants() do if d:IsA("BasePart") then paint(d :: BasePart) end end
	end
end

local function doSound(session: Session, id: any, rawId: any, volume: any)
	local inst = objById(session, id)
	if not inst or not inst:IsA("BasePart") then return end
	applySound(inst :: BasePart, normalizeSoundId(rawId), volume)
end

local function doDuplicate(session: Session, id: any)
	local inst = objById(session, id)
	if not inst or not inst:IsA("PVInstance") then return end
	if countObjects(session) >= CONFIG.MaxElements then return end
	local clone = inst:Clone()
	clone:SetAttribute("EditorId", nil)
	CollectionService:RemoveTag(clone, "EditorObject")
	anchorAll(clone)
	local target = (inst :: PVInstance):GetPivot() * CFrame.new(6, 0, 6)
	if session.bounds then
		local bcf, bsize = elementBox(clone, target)
		if not fitsBounds(session, bcf, bsize) then target = (inst :: PVInstance):GetPivot() end -- overlap in place rather than poke out
	end
	clone:PivotTo(target)
	clone.Parent = session.content
	tag(session, clone)
end

local function doDelete(session: Session, id: any)
	local inst = objById(session, id)
	if inst then
		if typeof(id) == "number" then session.objects[id] = nil end
		inst:Destroy()
	end
end

local function doClear(session: Session)
	for _, inst in session.content:GetChildren() do inst:Destroy() end
	table.clear(session.objects)
	session.nextId = 1
	session.baseKey = nil
	setBounds(session, nil)
end

local function doGrabPart(session: Session, part: any)
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") then return end
	if not part:IsDescendantOf(session.content) then return end
	if part:GetAttribute("EditorId") ~= nil then return end
	part:SetAttribute("BaseSize", part.Size)
	tag(session, part)
end

-- Customize: clone a whole building into the session as a grouped model, keep it grouped
-- (CustomRoot), and tag every descendant part so each is selectable/editable in place.
local function doCustomize(session: Session, key: any)
	if typeof(key) ~= "string" then return end
	local model = _modelByKey[key]
	if not (model and model:IsA("Model")) then return end
	doClear(session)
	local clone = model:Clone()
	anchorAll(clone)
	clone:SetAttribute("AssetKey", key)
	clone:SetAttribute("CustomRoot", true)
	local _, size = clone:GetBoundingBox()
	clone:PivotTo(spawnCFrame() * CFrame.new(0, size.Y / 2, 0))
	clone.Parent = session.content
	tag(session, clone) -- whole-model selection: a normal click grabs the asset as one unit
	local idx = 0
	for _, d in clone:GetDescendants() do
		if d:IsA("BasePart") then
			idx += 1
			d:SetAttribute("PartIdx", idx)
			d:SetAttribute("BaseSize", d.Size)
			tag(session, d)
		end
	end
	session.baseKey = key
	setBounds(session, model)
end

-- The XZ extent of everything in the session, measured across part centres -- exactness
-- does not matter for a sanity cap. Guards against a creation whose pieces sit hundreds of
-- studs apart: the placement tool would refuse it at every spot in the city and say
-- nothing, which reads as a broken tool rather than a broken design.
local function contentSpan(session: Session): (number, number)
	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge
	local found = false
	for _, inst in session.content:GetDescendants() do
		if inst:IsA("BasePart") then
			local p = (inst :: BasePart).Position
			found = true
			minX = math.min(minX, p.X); maxX = math.max(maxX, p.X)
			minZ = math.min(minZ, p.Z); maxZ = math.max(maxZ, p.Z)
		end
	end
	if not found then return 0, 0 end
	return maxX - minX, maxZ - minZ
end

-- == Serialize (source data only, as number arrays) ============================
local function serializeSession(session: Session): { any }
	local el: { any } = {}
	for _, inst in session.content:GetChildren() do
		if inst:IsA("BasePart") and inst:GetAttribute("Shape") ~= nil then
			local sid, vol = readSound(inst :: BasePart)
			table.insert(el, {
				t = "p", shape = inst:GetAttribute("Shape"),
				sz = v3ToArr(inst.Size), cf = cfToArr(inst.CFrame),
				c = colToArr(inst.Color), m = inst:GetAttribute("Mat") or inst.Material.Name,
				tr = inst.Transparency, sid = sid, vol = vol,
			})
		elseif inst:IsA("Model") and inst:GetAttribute("AssetKey") ~= nil then
			table.insert(el, { t = "r", key = inst:GetAttribute("AssetKey"), cf = cfToArr(inst:GetPivot()), sc = inst:GetScale() })
		end
	end
	return el
end

local function serializeCustom(session: Session): any
	local root: Model? = nil
	local prims: { any } = {}
	for _, inst in session.content:GetChildren() do
		if inst:IsA("Model") and inst:GetAttribute("CustomRoot") then
			root = inst :: Model
		elseif inst:IsA("BasePart") and inst:GetAttribute("Shape") ~= nil then
			local sid, vol = readSound(inst :: BasePart)
			table.insert(prims, {
				shape = inst:GetAttribute("Shape"), sz = v3ToArr(inst.Size), cf = cfToArr(inst.CFrame),
				c = colToArr(inst.Color), m = inst:GetAttribute("Mat") or inst.Material.Name, tr = inst.Transparency,
				sid = sid, vol = vol,
			})
		end
	end
	if not root then return nil end
	local rootCf = root:GetPivot()
	local parts: { [string]: any } = {}
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			local pidx = d:GetAttribute("PartIdx")
			if typeof(pidx) == "number" then
				local sid, vol = readSound(d :: BasePart)
				parts[tostring(pidx)] = {
					cf = cfToArr(rootCf:ToObjectSpace(d.CFrame)), sz = v3ToArr(d.Size),
					c = colToArr(d.Color), m = d:GetAttribute("Mat") or d.Material.Name, tr = d.Transparency,
					sid = sid, vol = vol,
				}
			end
		end
	end
	return { kind = "custom", base = session.baseKey, root = cfToArr(rootCf), parts = parts, prims = prims }
end

-- == Restore ===================================================================
local function restorePrimitive(session: Session, e: any, atCf: CFrame?)
	if typeof(e.shape) ~= "string" then return end
	local part = makePrimitive(e.shape)
	if not part then return end
	part.Anchored = true
	part.Size = arrToV3(e.sz)
	part.CFrame = atCf or arrToCf(e.cf)
	part.Color = arrToCol(e.c)
	part.Transparency = tonumber(e.tr) or 0
	applyMaterial(part, e.m)
	if typeof(e.sid) == "string" then applySound(part, e.sid, e.vol) end
	part:SetAttribute("Shape", e.shape)
	part:SetAttribute("BaseSize", part.Size)
	part.Parent = session.content
	tag(session, part)
end

local function restoreSession(session: Session, el: any)
	if typeof(el) ~= "table" then return end
	for _, e in el do
		if typeof(e) == "table" then
			if e.t == "p" then
				restorePrimitive(session, e, nil)
			elseif e.t == "r" and typeof(e.key) == "string" then
				local model = _modelByKey[e.key]
				if model and model:IsA("Model") then
					local clone = model:Clone()
					anchorAll(clone)
					clone:SetAttribute("AssetKey", e.key)
					if tonumber(e.sc) then clone:ScaleTo(tonumber(e.sc) :: number) end
					clone:PivotTo(arrToCf(e.cf))
					clone.Parent = session.content
					tag(session, clone)
				end
			end
		end
	end
end

local function restoreCustom(session: Session, record: any)
	local model = _modelByKey[record.base]
	if not (model and model:IsA("Model")) then return end
	local clone = model:Clone()
	anchorAll(clone)
	clone:SetAttribute("AssetKey", record.base)
	clone:SetAttribute("CustomRoot", true)
	local rootCf = arrToCf(record.root)
	clone:PivotTo(rootCf)
	clone.Parent = session.content
	tag(session, clone) -- whole-model selection, same as doCustomize
	local partsList: { BasePart } = {}
	for _, d in clone:GetDescendants() do if d:IsA("BasePart") then table.insert(partsList, d :: BasePart) end end
	for i, d in partsList do
		local ov = record.parts and record.parts[tostring(i)]
		if ov and d.Parent then
			d.Size = arrToV3(ov.sz)
			d.CFrame = rootCf * arrToCf(ov.cf)
			d.Color = arrToCol(ov.c)
			d.Transparency = tonumber(ov.tr) or 0
			applyMaterial(d, ov.m)
			if typeof(ov.sid) == "string" then applySound(d, ov.sid, ov.vol) end
			d:SetAttribute("PartIdx", i)
			d:SetAttribute("BaseSize", d.Size)
			tag(session, d)
		elseif d.Parent then
			d:Destroy()
		end
	end
	if typeof(record.prims) == "table" then
		for _, e in record.prims do
			if typeof(e) == "table" then restorePrimitive(session, e, rootCf * arrToCf(e.cf)) end
		end
	end
	session.baseKey = record.base
	setBounds(session, model)
end

local function restoreCreation(session: Session, record: any)
	doClear(session)
	if typeof(record) ~= "table" then return end
	if record.kind == "custom" or record.parts then
		restoreCustom(session, record)
	elseif record.el then
		restoreSession(session, record.el)
	end
end

-- == Undo / redo (server-authoritative snapshot stack) =========================
-- Each mutating command snapshots the whole scene (reusing the save serializers) BEFORE it
-- runs. Continuous drags coalesce so one drag = one undo step. ponytail: whole-scene rebuild
-- on undo, fine for <=500 parts; go per-action inverse only if it ever hitches.
local MAX_UNDO = 25
local UNDO_COALESCE = 0.35
local CONTINUOUS: { [string]: boolean } = { transform = true, transformOnly = true, setSize = true, setScale = true }

local function snapshotSession(session: Session): any
	if session.baseKey then
		local rec = serializeCustom(session)
		if rec then return rec end
	end
	return { el = serializeSession(session) }
end

local function pushUndo(session: Session, action: string, id: any)
	local now = os.clock()
	local last = session._lastUndo
	if CONTINUOUS[action] and last and CONTINUOUS[last.action] and last.id == id and now - last.at < UNDO_COALESCE then
		last.at = now -- same drag in flight; fold into the snapshot already taken
		return
	end
	table.insert(session.undoStack, snapshotSession(session))
	if #session.undoStack > MAX_UNDO then table.remove(session.undoStack, 1) end
	table.clear(session.redoStack)
	session._lastUndo = { at = now, action = action, id = id }
end

local function doUndo(session: Session)
	if #session.undoStack == 0 then return end
	table.insert(session.redoStack, snapshotSession(session))
	if #session.redoStack > MAX_UNDO then table.remove(session.redoStack, 1) end
	restoreCreation(session, table.remove(session.undoStack))
	session._lastUndo = nil
end

local function doRedo(session: Session)
	if #session.redoStack == 0 then return end
	table.insert(session.undoStack, snapshotSession(session))
	if #session.undoStack > MAX_UNDO then table.remove(session.undoStack, 1) end
	restoreCreation(session, table.remove(session.redoStack))
	session._lastUndo = nil
end

-- == Persistence / usage =======================================================
-- A blueprint blob is durable the moment BlueprintStore.save returns; this flushes the
-- index row on the player record so a crash cannot orphan it. Flush, not SaveNow --
-- SaveNow is the leave path and would drop the player's loaded record mid-session.
local function persist(player: Player)
	_pds.Flush(player)
end

-- The player's blueprint index: id / name / bytes / ts / meta per creation. No DataStore
-- traffic -- it rides the already-loaded player record.
local function index(uid: number): { any }
	return _bp.list(uid)
end

local function usedBytes(uid: number): number
	local total = 0
	for _, entry in index(uid) do
		total += tonumber(entry.bytes) or 0
	end
	return total
end

local function librarySummary(uid: number): { any }
	local out: { any } = {}
	for _, entry in index(uid) do
		local meta = if typeof(entry.meta) == "table" then entry.meta else {}
		table.insert(out, { id = entry.id, name = entry.name, cat = meta.cat, count = meta.count, ts = entry.ts, price = tonumber(meta.price) or 0 })
	end
	table.sort(out, function(a, b) return (a.ts or 0) > (b.ts or 0) end)
	return out
end

local function usage(uid: number, ok: boolean, extra: any?): any
	local res: any = extra or {}
	res.ok = ok
	res.usedBytes = usedBytes(uid)
	res.budget = CONFIG.CreationsBudget
	res.creations = librarySummary(uid)
	return res
end

-- Yields on the blueprint read, so the session is re-checked afterwards: the player can
-- leave or exit the editor while the store is answering.
-- THE line between using someone's work and taking it. Since creations became shareable,
-- an approved blob is fetchable by anybody (ReviewQueue.blobFor) so they can PLACE it --
-- and this ownership check is the only thing that stops the same player loading it into
-- their editor, changing it and saving it as their own. It is not a convenience: do not
-- relax it to "owns or approved" to match the placement path. Placing is using; loading
-- is editing, and you may only edit what you built.
local function doLoad(player: Player, session: Session, id: any)
	if typeof(id) ~= "string" then return end
	if not _bp.owns(player.UserId, id) then return end

	local bp = _bp.get(id)
	if not bp or typeof(bp.blob) ~= "table" then return end
	if _sessions[player.UserId] ~= session or not session.root.Parent then return end

	restoreCreation(session, bp.blob)
end

-- What the creator charges anyone who places this creation. 0 means free.
local function clampPrice(v: any): number
	local n = tonumber(v) or 0
	if n ~= n then return 0 end -- NaN
	return math.clamp(math.floor(n), 0, CONFIG.MaxPrice)
end

local function doSave(player: Player, name: any, category: any, price: any): any
	local uid = player.UserId
	local session = _sessions[uid]
	if not session then return usage(uid, false, { err = "No open session" }) end
	if typeof(name) ~= "string" then return usage(uid, false, { err = "Bad name" }) end
	name = (string.gsub(name, "^%s+", ""))
	name = (string.gsub(name, "%s+$", ""))
	name = string.sub(name, 1, CONFIG.MaxNameLen)
	if #name == 0 then return usage(uid, false, { err = "Name required" }) end
	-- Which shelf the creator filed this under. Validated against the shared catalog so a
	-- client cannot invent a category the placement UI has no chip for; an unknown key
	-- falls back rather than failing the save, so an older creation never becomes unsavable.
	local cat = CreationCategories.normalize(category)

	local spanX, spanZ = contentSpan(session)
	if spanX > CONFIG.MaxSpan or spanZ > CONFIG.MaxSpan then
		return usage(uid, false, { err = string.format(
			"Too spread out (%d x %d studs, max %d) -- move the far pieces in.",
			math.round(spanX), math.round(spanZ), CONFIG.MaxSpan) })
	end

	if #index(uid) >= CONFIG.MaxCreations then return usage(uid, false, { err = "Creation limit reached (" .. CONFIG.MaxCreations .. ")" }) end
	if usedBytes(uid) >= CONFIG.CreationsBudget then return usage(uid, false, { err = "Not enough storage space" }) end

	local record: any
	local count = 0
	if session.baseKey then
		record = serializeCustom(session)
		if not record then return usage(uid, false, { err = "Nothing to save" }) end
		for _ in record.parts do count += 1 end
		count += #record.prims
		if count == 0 then return usage(uid, false, { err = "Nothing to save" }) end
	else
		local el = serializeSession(session)
		if #el == 0 then return usage(uid, false, { err = "Nothing to save" }) end
		if #el > CONFIG.MaxElements then return usage(uid, false, { err = "Too many parts (max " .. CONFIG.MaxElements .. ")" }) end
		record = { el = el }
		count = #el
	end

	-- A customized real building is a "building"; a free composition of props is a
	-- "creation". Yields: one DataStore write, which is what can fail here.
	-- The price is written into the BLOB as well as onto the index row. The row is only
	-- readable from its owner's own player record, so a creation placed in someone else's
	-- city has to carry its price with it.
	local p = clampPrice(price)
	record.price = p
	-- The shelf goes in the BLOB as well as the index row. The row is only readable from
	-- its owner's own player record, so publishing a creation to the store would otherwise
	-- lose the category the creator picked and relabel everything as the default.
	record.cat = cat

	local kind = if session.baseKey then "building" else "creation"
	local id, err = _bp.save(player, kind, name, record, { cat = cat, count = count, price = p })
	if not id then return usage(uid, false, { err = err or "Could not save that design." }) end

	persist(player)
	table.clear(session.undoStack); table.clear(session.redoStack); session._lastUndo = nil -- fresh history after a save
	return usage(uid, true, { id = id })
end

local function doDeleteCreation(player: Player, id: any): any
	local uid = player.UserId
	if typeof(id) ~= "string" or not _bp.remove(player, id) then
		return usage(uid, false, { err = "Not found" })
	end
	persist(player)
	return usage(uid, true)
end

-- == Catalog ===================================================================
-- ServerStorage.Templates / <topFolder> / <categoryFolder> / .../ <Model>. Category =
-- the second-level folder (Residential, Commercial, CivilianVehicles, Props, ...). Every
-- Model not nested inside another Model is spawnable; keyed by GetFullName.
local function buildCatalog()
	table.clear(_catalog)
	table.clear(_modelByKey)
	table.clear(_catByKey)
	local root = SS:FindFirstChild("Templates")
	if not root then warn("[EditorService] ServerStorage.Templates missing -- catalog empty"); return end
	for _, top in root:GetChildren() do
		if top:IsA("Folder") then
			for _, catFolder in top:GetChildren() do
				if catFolder:IsA("Folder") then
					for _, m in catFolder:GetDescendants() do
						if m:IsA("Model") and not m:FindFirstAncestorWhichIsA("Model") then
							local key = m:GetFullName()
							_modelByKey[key] = m
							_catByKey[key] = catFolder.Name
							table.insert(_catalog, { key = key, name = m.Name, cat = catFolder.Name })
						end
					end
				end
			end
		end
	end
end

-- The spawnable catalog, for services that rebuild a saved creation outside an editor
-- session (CreationPlaceService stands them up in the city). One walk of
-- ServerStorage.Templates, one catalog -- callers get a resolver, never the table.
function EditorService.resolveAsset(key: string): Model?
	if typeof(key) ~= "string" then return nil end
	return _modelByKey[key]
end

-- == Lifecycle =================================================================
function EditorService.Init(playerDataStore: any, blueprintStore: any)
	if not playerDataStore then error("[EditorService] Init requires PlayerDataStore") end
	if not blueprintStore then error("[EditorService] Init requires BlueprintStore") end
	_pds = playerDataStore
	_bp = blueprintStore
	buildCatalog()
end

function EditorService.Bind()
	NetMiddleware.RegisterServerRateLimit(Net.RequestEnterEditor, CONFIG.EnterCooldown)
	NetMiddleware.RegisterServerRateLimit(Net.RequestExitEditor, CONFIG.ExitCooldown)

	Net.RequestEnterEditor.OnServerEvent:Connect(function(player: Player)
		if not NetMiddleware.CheckServerRate(Net.RequestEnterEditor, player) then return end
		ensureSession(player)
	end)

	Net.RequestExitEditor.OnServerEvent:Connect(function(player: Player)
		if not NetMiddleware.CheckServerRate(Net.RequestExitEditor, player) then return end
		destroySession(player.UserId)
	end)

	Net.RequestEditorCommand.OnServerEvent:Connect(function(player: Player, payload: any)
		if typeof(payload) ~= "table" then return end
		local session = _sessions[player.UserId]
		if not session then return end
		local action = payload.action
		if action == "undo" then doUndo(session); return end
		if action == "redo" then doRedo(session); return end
		if action == "transform" then pushUndo(session, "transform", payload.id); doTransform(session, payload.id, payload.cf)
		elseif action == "appearance" then pushUndo(session, "appearance", payload.id); doAppearance(session, payload.id, payload.color, payload.material)
		elseif action == "sound" then pushUndo(session, "sound", payload.id); doSound(session, payload.id, payload.soundId, payload.volume)
		elseif action == "setScale" then pushUndo(session, "setScale", payload.id); doSetScale(session, payload.id, payload.scale)
		elseif action == "setSize" then pushUndo(session, "setSize", payload.id); doSetSize(session, payload.id, payload.size, payload.cf)
		elseif action == "delete" then pushUndo(session, "delete", payload.id); doDelete(session, payload.id)
		elseif action == "clear" then pushUndo(session, "clear", nil); doClear(session)
		elseif action == "grabPart" then doGrabPart(session, payload.part)
		elseif action == "transformOnly" then pushUndo(session, "transformOnly", payload.id); doTransform(session, payload.id, payload.cf)
		else
			-- rate-limited (expensive) actions
			local now = os.clock()
			local last = _lastSpawnAt[player.UserId]
			if last and now - last < CONFIG.SpawnCooldown then return end
			_lastSpawnAt[player.UserId] = now
			if action == "spawn" then pushUndo(session, "spawn", nil); doSpawn(session, payload.key)
			elseif action == "primitive" then pushUndo(session, "primitive", nil); doPrimitive(session, payload.shape)
			elseif action == "duplicate" then pushUndo(session, "duplicate", payload.id); doDuplicate(session, payload.id)
			elseif action == "customize" then pushUndo(session, "customize", nil); doCustomize(session, payload.key)
			elseif action == "load" then pushUndo(session, "load", nil); doLoad(player, session, payload.id)
			end
		end
	end)

	Net.RequestEditorData.OnServerInvoke = function(player: Player, payload: any): any
		if typeof(payload) ~= "table" then return { ok = false } end
		local action = payload.action
		local uid = player.UserId
		if action == "catalog" then
			return { ok = true, entries = _catalog }
		elseif action == "list" then
			return usage(uid, true)
		elseif action == "save" then
			return doSave(player, payload.name, payload.category, payload.price)
		elseif action == "deleteCreation" then
			return doDeleteCreation(player, payload.id)
		elseif action == "blob" then
			-- The client needs the geometry to build a placement ghost. Own creations only:
			-- BlueprintStore.get takes any id by design, so the gate lives at the call site.
			if typeof(payload.id) ~= "string" then return { ok = false } end
			if not _bp.owns(uid, payload.id) then return { ok = false } end
			local record = _bp.get(payload.id) -- yields
			if not record or typeof(record.blob) ~= "table" then return { ok = false } end
			return { ok = true, blob = record.blob, name = record.name, kind = record.kind }
		end
		return { ok = false }
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		destroySession(player.UserId)
	end)
end

function EditorService.Start() end

return EditorService
