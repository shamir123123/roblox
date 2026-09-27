--!strict
-- EditorController
-- Client entry for the in-world Creation Editor. The heavy lifting is split:
--   UICreation.EditorView    -- docked full-screen UI (pure construction)
--   Controllers.EditorGizmos -- transform handles + snap settings
-- This module owns the flow (start chooser -> new asset / modify-existing
-- picker -> editor), selection, world input (click-select, body drags,
-- drag-to-place), the dynamic panel content (asset browser, explorer tree,
-- properties), saving / loading creations, and the editor environment
-- (camera, forced day lighting, ground grid). The server (EditorService)
-- owns all state; this only sends validated, throttled requests.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local Workspace         = game:GetService("Workspace")
local Lighting          = game:GetService("Lighting")

local Net          = require(ReplicatedStorage:WaitForChild("Networker"))
local UIEvents     = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("UIEvents"))
local EditorConfig = require(ReplicatedStorage:WaitForChild("Editor"):WaitForChild("EditorConfig"))
local CreationCategories = require(ReplicatedStorage:WaitForChild("Editor"):WaitForChild("CreationCategories"))

local player        = Players.LocalPlayer
local playerScripts = player:WaitForChild("PlayerScripts")
local FreeCamController = require(playerScripts:WaitForChild("Core"):WaitForChild("FreeCamController"))
local CursorRay = require(playerScripts:WaitForChild("Core"):WaitForChild("CursorRay"))
local uiFolder = playerScripts:WaitForChild("UI")
local Theme  = require(uiFolder:WaitForChild("Theme"))
local Icons  = require(uiFolder:WaitForChild("Icons"))
local Button = require(uiFolder:WaitForChild("Kit"):WaitForChild("Button"))
local Modal  = require(uiFolder:WaitForChild("Kit"):WaitForChild("Modal"))
local EditorView   = require(playerScripts:WaitForChild("UICreation"):WaitForChild("EditorView"))
local EditorGizmos = require(script.Parent:WaitForChild("EditorGizmos"))
local ShapeCatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ShapeCatalog"))
local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))

local EditorController = {}

local GROUND_TOP = EditorConfig.Origin.Y
local CAM_POS    = EditorConfig.Origin + Vector3.new(0, 340, 320)
local CAM_YAW    = 0
local CAM_PITCH  = -46
local EDITOR_CLOCK = 14 -- the editor is always daytime; the city's clock is restored on exit

local MATERIALS  = { "Plastic", "Wood", "Metal", "Concrete", "Brick", "Glass", "Neon", "Grass" }
-- Sixty of them now, so the browser's search box is how you find one -- taken from the
-- shared catalog rather than listed again here, and displayed by the catalog's own name
-- ("Half Pipe", not "HalfPipe") while the SHAPE KEY is what gets sent.
-- The SHELF, not every key: retired shapes still load but are no longer offered.
local PRIMITIVES = ShapeCatalog.shelf
-- The shelf a finished creation files itself under, straight from the shared catalog so
-- the editor, the placement UI and the server can never disagree about what a category
-- is. The server validates against this same list and normalizes anything it does not
-- recognise, so a stale client cannot invent a shelf that has no chip.
local SAVE_CATS  = CreationCategories.order

local GREEN = Color3.fromRGB(126, 196, 96)
local AMBER = Color3.fromRGB(232, 152, 56)
local RED   = Color3.fromRGB(220, 74, 74)

local ROT_SENS   = 0.5   -- body-drag rotate: degrees of yaw per pixel
local SCALE_SENS = 0.008 -- body-drag scale: scale units per pixel
local GRID_STEP  = 20

-- == State =====================================================================
local _open = false
local _refs: any = nil -- EditorView refs table
local _catalog: { any }? = nil
local _cats: { string } = {}
local _activeCat = "Primitives"
local _search = ""

local _selected: Instance? = nil
local _highlight: Highlight? = nil
local _dragging = false
local _dragOffset = Vector3.zero
local _lastSendAt = 0
local _manipStartPivot = CFrame.identity
local _manipStartMouse = Vector2.zero
local _manipStartScale = 1

local _used = 0
local _budget = 150000
local _creations: { any } = {}
local _saveCatIdx = table.find(SAVE_CATS, CreationCategories.DEFAULT) or 1
local _saveCatHint: TextLabel? = nil
local _savePrice: TextBox? = nil
-- bpId -> { status = "pending"|"approved"|"rejected", reason }. Filled alongside the
-- creation list so My Creations can show where each one stands without a second panel.
local _reviewStatus: { [string]: any } = {}
local _toastToken = 0

local _placeAwait = false
local _placing = false
local _placingInst: PVInstance? = nil
local _explorerHooked = false
local _expanded: { [Instance]: boolean } = {}
local _gridBoard: BasePart? = nil
local _boundsPart: BasePart? = nil
local _prevClockTime: number? = nil

local _saveModal: any = nil
local _saveName: TextBox? = nil
local _saveCatBtn: any = nil
local _saveHint: TextLabel? = nil
local _loadModal: any = nil
local _loadList: ScrollingFrame? = nil

-- forward refs
local refreshPalette: () -> ()
local updateToolbar: () -> ()
local refreshLibrary: () -> ()
local refreshLoadList: () -> ()
local refreshExplorer: () -> ()
local refreshProps: () -> ()
local exit: () -> ()

-- == Small helpers =============================================================
local function sendCmd(payload: { [string]: any })
	Net.RequestEditorCommand:FireServer(payload)
end

local function selectedId(): number?
	if _selected and _selected.Parent then
		local id = _selected:GetAttribute("EditorId")
		if typeof(id) == "number" then return id end
	end
	return nil
end

local function toast(msg: string)
	local r = _refs
	if not r then return end
	local lbl = r.toast :: TextLabel
	_toastToken += 1
	local mine = _toastToken
	lbl.Text = msg
	lbl.Visible = true
	task.delay(2.2, function()
		if _toastToken == mine then lbl.Visible = false end
	end)
end

local function label(parent: Instance, text: string, size: UDim2, pos: UDim2, font: Font, ts: number, col: Color3): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = size
	l.Position = pos
	l.FontFace = font
	l.Text = text
	l.TextSize = ts
	l.TextColor3 = col
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = parent
	return l
end

local function dialogTextBox(parent: Instance, name: string, placeholder: string): TextBox
	local tb = Instance.new("TextBox")
	tb.Name = name
	tb.BackgroundColor3 = Theme.Color.Bg
	tb.BorderSizePixel = 0
	tb.FontFace = Theme.Font.Label
	tb.PlaceholderText = placeholder
	tb.Text = ""
	tb.TextSize = Theme.TextSize.SM
	tb.TextColor3 = Theme.Color.TextPrimary
	tb.PlaceholderColor3 = Theme.Color.TextDisabled
	tb.ClearTextOnFocus = false
	tb.Parent = parent
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, Theme.Radius.SM); c.Parent = tb
	return tb
end

-- == Camera / ray ==============================================================
-- Was subtracting GuiService:GetGuiInset().Y here, which aimed the ray ~36 px ABOVE the
-- cursor in a live game (the inset reads 0 in Studio Edit, which is why it looked fine).
-- GetMouseLocation is already in viewport space -- see Core.CursorRay.
local function mouseRay(): Ray
	local r = CursorRay.ray()
	assert(r, "[EditorController] no CurrentCamera")
	return r
end

-- Where the cursor meets the build plate.
--
-- The 1e-5 guard below only rejects a PERFECTLY horizontal ray, which is not the dangerous
-- case. At a merely shallow angle `t` explodes: from a camera 50 studs above the plate, a
-- direction of d.Y = -0.1 puts the hit 500 studs out. A part dropped there is off-screen,
-- hundreds of studs from the rest of the creation, and invisibly inflates its bounding box
-- until the finished thing cannot be placed in a city at all -- which reads as a broken
-- placement tool rather than a broken creation. So the hit is clamped to the plate it is
-- supposed to be on.
local function mouseToGround(): Vector3?
	local r = mouseRay()
	local d = r.Direction
	if math.abs(d.Y) < 1e-5 then return nil end
	local t = (GROUND_TOP - r.Origin.Y) / d.Y
	if t < 0 then return nil end
	local p = r.Origin + d * t
	local o = EditorConfig.Origin
	local hx = EditorConfig.GroundSize.X * 0.5
	local hz = EditorConfig.GroundSize.Z * 0.5
	return Vector3.new(
		math.clamp(p.X, o.X - hx, o.X + hx),
		p.Y,
		math.clamp(p.Z, o.Z - hz, o.Z + hz)
	)
end

local function editorObjectAt(): Instance?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {}
	local hit = CursorRay.raycast(params)
	if not hit then return nil end
	-- a normal click selects the OUTERMOST tagged thing (the whole model);
	-- Ctrl+click (the grabPart path) is how you reach individual parts inside
	local inst: Instance? = hit.Instance
	local top: Instance? = nil
	while inst and inst ~= Workspace do
		if inst:GetAttribute("EditorId") ~= nil then top = inst end
		inst = inst.Parent
	end
	return top
end

local function rawHitPart(): BasePart?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {}
	local hit = CursorRay.raycast(params)
	if hit and hit.Instance:IsA("BasePart") then return hit.Instance :: BasePart end
	return nil
end

local function hasEditorAncestor(inst: Instance): boolean
	local n: Instance? = inst
	while n and n ~= Workspace do
		if n:GetAttribute("EditorId") ~= nil then return true end
		n = n.Parent
	end
	return false
end

-- == Footprint bounds (customize mode) =========================================
-- The server owns the rule (EditorService.fitsBounds); this mirror makes drags
-- stop at the edge instead of visually drifting past what the server accepts.
-- Bounds arrive as attributes on the session folder when a customize starts.
local function sessionRoot(): Instance?
	local root = Workspace:FindFirstChild("_Editor")
	return root and root:FindFirstChild("Session_" .. player.UserId)
end

local function sessionBoundsHalf(): (number?, number?)
	local s = sessionRoot()
	if not s then return nil, nil end
	local hx = s:GetAttribute("BoundsHX")
	local hz = s:GetAttribute("BoundsHZ")
	if typeof(hx) == "number" and typeof(hz) == "number" then return hx, hz end
	return nil, nil
end

local function inModifyMode(): boolean
	local hx = sessionBoundsHalf()
	return hx ~= nil
end

local function fitsBounds(cf: CFrame, size: Vector3): boolean
	local bhx, bhz = sessionBoundsHalf()
	if not bhx or not bhz then return true end
	local r = cf.Rotation
	local hx = math.abs(r.XVector.X) * size.X / 2 + math.abs(r.YVector.X) * size.Y / 2 + math.abs(r.ZVector.X) * size.Z / 2
	local hz = math.abs(r.XVector.Z) * size.X / 2 + math.abs(r.YVector.Z) * size.Y / 2 + math.abs(r.ZVector.Z) * size.Z / 2
	local o = EditorConfig.Origin
	return math.abs(cf.Position.X - o.X) <= bhx - hx + 1e-3
		and math.abs(cf.Position.Z - o.Z) <= bhz - hz + 1e-3
end

local function fitsPivot(inst: Instance, newPivot: CFrame, newSize: Vector3?): boolean
	if inst:IsA("BasePart") then
		return fitsBounds(newPivot, newSize or (inst :: BasePart).Size)
	elseif inst:IsA("Model") then
		local m = inst :: Model
		local bcf, bsize = m:GetBoundingBox()
		return fitsBounds(newPivot * m:GetPivot():ToObjectSpace(bcf), newSize or bsize)
	end
	return true
end

-- outlined region on the plate showing how big the modified asset may get
local function updateBoundsVisual()
	local hx, hz = sessionBoundsHalf()
	if not hx or not hz then
		if _boundsPart then _boundsPart:Destroy(); _boundsPart = nil end
		return
	end
	local p = _boundsPart
	if not p or not p.Parent then
		p = Instance.new("Part")
		p.Name = "EditorBounds"
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Transparency = 1
		local box = Instance.new("SelectionBox")
		box.LineThickness = 0.06
		box.Color3 = AMBER
		box.SurfaceColor3 = AMBER
		box.SurfaceTransparency = 0.92
		box.Adornee = p
		box.Parent = p
		p.Parent = Workspace
		_boundsPart = p
	end
	local o = EditorConfig.Origin
	p.Size = Vector3.new(hx * 2, 0.4, hz * 2)
	p.CFrame = CFrame.new(o.X, GROUND_TOP + 0.2, o.Z)
end

-- == Selection =================================================================
local function highlight(): Highlight
	if _highlight then return _highlight end
	local h = Instance.new("Highlight")
	h.Name = "EditorSelection"
	h.FillColor = Theme.Color.Accent
	h.FillTransparency = 0.7
	h.OutlineColor = Theme.Color.AccentHover
	h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	h.Enabled = false -- off until a real object is selected (nil Adornee would light up all of Workspace)
	h.Parent = Workspace
	_highlight = h
	return h
end

local function deselect()
	_selected = nil
	if _highlight then _highlight.Enabled = false; _highlight.Adornee = nil end
	updateToolbar()
end

local function select(inst: Instance)
	_selected = inst
	local h = highlight()
	h.Adornee = inst
	h.Enabled = true
	updateToolbar()
end

local function setMode(mode: string)
	EditorGizmos.setMode(mode)
	local r = _refs
	if r then
		for m, b in r.modeButtons do b:SetSelected(m == mode) end
	end
	_dragging = false
end

-- == Storage meter =============================================================
local function updateStorage()
	local r = _refs
	if not r then return end
	local frac = if _budget > 0 then math.clamp(_used / _budget, 0, 1) else 0
	r.meterFill.Size = UDim2.new(frac, 0, 1, 0)
	r.meterFill.BackgroundColor3 = if frac >= 0.999 then RED elseif frac > 0.75 then AMBER else GREEN
	r.meterText.Text = string.format("%d KB free", math.max(0, math.floor((_budget - _used) / 1000)))
end

local function applyUsage(res: any)
	if typeof(res) ~= "table" then return end
	if typeof(res.usedBytes) == "number" then _used = res.usedBytes end
	if typeof(res.budget) == "number" then _budget = res.budget end
	if typeof(res.creations) == "table" then _creations = res.creations end
	updateStorage()
	if _loadModal and _loadModal:IsOpen() then refreshLoadList() end
end

local function updateSnapLabels()
	local r = _refs
	if not r then return end
	for _, channel in EditorGizmos.CHANNELS do
		local row = r.snap.rows[channel]
		if row then
			local presetLabel: { [string]: string } = {}
			for _, p in EditorGizmos.presetsFor(channel) do presetLabel[p.key] = p.label end
			local preset = EditorGizmos.getSnapPreset(channel)
			-- The list says which preset; the suffix says what it actually costs, because
			-- "1/4 snapping" alone does not tell you whether that is a stud or a degree.
			row.btn.Instance.Text = presetLabel[preset] .. "  \u{00B7}  " .. EditorGizmos.stepLabel(channel)
			row.box.Visible = preset == "Custom"
			if preset == "Custom" then row.box.Text = tostring(EditorGizmos.getCustomStep(channel)) end
		end
	end
	r.snap.spaceBtn.Instance.Text = EditorGizmos.getSpace()
	-- The ribbon button is the at-a-glance version: the move step and the space.
	r.snapBtn.Instance.Text = "Snap: " .. EditorGizmos.stepLabel("move") .. " \u{00B7} " .. EditorGizmos.getSpace()
end

-- The gizmo is shared with the city's Move tool now, so the editor takes it when it opens
-- and hands it back when it closes rather than owning it from startup. Defined here,
-- above startEditor, because that is where it is first called.
local GIZMO_OWNER = "Editor"

local function claimGizmo()
	EditorGizmos.claim(GIZMO_OWNER, {
		getSelected = function() return _selected end,
		getSelectedId = selectedId,
		sendCmd = sendCmd,
		fitsPivot = fitsPivot,
	})
end

-- == Properties commits ========================================================
local function commitSize()
	local r = _refs
	local inst = _selected
	local id = selectedId()
	if not r or not id or not inst or not inst:IsA("BasePart") then return end
	local part = inst :: BasePart
	local s = part.Size
	local comp = { s.X, s.Y, s.Z }
	for i, tb in r.props.sizeBoxes :: { TextBox } do
		local v = tonumber(tb.Text)
		if v and v > 0 then comp[i] = math.clamp(v, 0.2, 2048) end
	end
	local newSize = Vector3.new(comp[1], comp[2], comp[3])
	if not fitsBounds(part.CFrame, newSize) then toast("Too big for this asset's footprint"); refreshProps(); return end
	part.Size = newSize
	sendCmd({ action = "setSize", id = id, size = part.Size, cf = part:GetPivot() })
	refreshProps()
end

local function commitScale()
	local r = _refs
	local inst = _selected
	local id = selectedId()
	if not r or not id or not inst or not inst:IsA("Model") then return end
	local v = tonumber((r.props.scaleBox :: TextBox).Text)
	if not v then refreshProps(); return end
	local m = inst :: Model
	local target = math.clamp(v, 0.2, 5)
	local bcf, bsize = m:GetBoundingBox()
	if not fitsBounds(bcf, bsize * (target / m:GetScale())) then toast("Too big for this asset's footprint"); refreshProps(); return end
	m:ScaleTo(target)
	sendCmd({ action = "setScale", id = id, scale = m:GetScale() })
	refreshProps()
end

local function commitRot()
	local r = _refs
	local inst = _selected
	local id = selectedId()
	if not r or not id or not inst or not inst:IsA("PVInstance") then return end
	local v = tonumber((r.props.rotBox :: TextBox).Text)
	if not v then refreshProps(); return end
	local pv = inst :: PVInstance
	local pos = pv:GetPivot().Position
	local newCf = CFrame.new(pos) * CFrame.fromOrientation(0, math.rad(v), 0)
	if not fitsPivot(pv, newCf) then toast("Too big for this asset's footprint"); refreshProps(); return end
	pv:PivotTo(newCf)
	sendCmd({ action = "transform", id = id, cf = newCf })
	EditorGizmos.sync()
	refreshProps()
end

local function cycleMaterial()
	local r = _refs
	local id = selectedId()
	if not r or not id or not _selected then return end
	local cur = _selected:GetAttribute("Mat") or "Plastic"
	local idx = table.find(MATERIALS, cur) or 1
	local nextMat = MATERIALS[(idx % #MATERIALS) + 1]
	_selected:SetAttribute("Mat", nextMat)
	r.props.matBtn.Instance.Text = "Material: " .. nextMat
	sendCmd({ action = "appearance", id = id, material = nextMat })
end

local function commitSound()
	local r = _refs
	local inst = _selected
	local id = selectedId()
	if not r or not id or not inst or not inst:IsA("BasePart") then return end
	sendCmd({ action = "sound", id = id, soundId = (r.props.soundBox :: TextBox).Text })
end

-- Keeps the shelf button and its one-line explanation in step with _saveCatIdx. Both the
-- cycle button and the start-up kind picker drive this, so neither can drift.
local function refreshSaveCategory()
	local entry = CreationCategories.getOrDefault(SAVE_CATS[_saveCatIdx])
	if _saveCatBtn then _saveCatBtn.Instance.Text = "Shelf: " .. entry.label end
	if _saveCatHint then (_saveCatHint :: TextLabel).Text = entry.hint end
end

-- == Save / My Creations dialogs ==============================================
local function buildDialogs()
	if _saveModal then return end

	local save = Modal.new({
		size = UDim2.fromOffset(380, 340),
		title = "SAVE CREATION",
		name = "EditorSaveDialog",
		onClose = function() _saveModal:Hide() end,
	})
	_saveModal = save
	local sc = save.Content
	local name = dialogTextBox(sc, "CreationName", "Creation name")
	name.Size = UDim2.new(1, 0, 0, 32)
	_saveName = name
	_saveCatBtn = Button.new({
		text = "Shelf: " .. CreationCategories.getOrDefault(SAVE_CATS[_saveCatIdx]).label,
		name = "CatBtn", parent = sc, size = UDim2.fromOffset(200, 30),
		onClick = function()
			_saveCatIdx = (_saveCatIdx % #SAVE_CATS) + 1
			refreshSaveCategory()
		end,
	})
	_saveCatBtn.Instance.Position = UDim2.fromOffset(0, 42)

	-- Each shelf says what belongs on it, so picking one is a decision rather than a guess.
	_saveCatHint = label(sc, "", UDim2.new(1, 0, 0, 30), UDim2.fromOffset(0, 78), Theme.Font.Label, Theme.TextSize.XS, Theme.Color.TextSecondary)
	;(_saveCatHint :: TextLabel).TextWrapped = true

	local price = dialogTextBox(sc, "CreationPrice", "0")
	price.Size = UDim2.fromOffset(200, 30)
	price.Position = UDim2.fromOffset(0, 114)
	_savePrice = price
	label(sc, "price to place \u{00B7} 0 = free", UDim2.new(1, -210, 0, 30), UDim2.fromOffset(210, 114), Theme.Font.Label, Theme.TextSize.XS, Theme.Color.TextSecondary)

	_saveHint = label(sc, "", UDim2.new(1, 0, 0, 32), UDim2.fromOffset(0, 152), Theme.Font.Label, Theme.TextSize.XS, Theme.Color.Danger)
	;(_saveHint :: TextLabel).TextWrapped = true
	Button.new({
		text = "Cancel", name = "Cancel", parent = sc, size = UDim2.fromOffset(90, 32),
		onClick = function() _saveModal:Hide() end,
	}).Instance.Position = UDim2.fromOffset(0, 196)
	Button.new({
		text = "Save", name = "Confirm", parent = sc, size = UDim2.fromOffset(120, 32),
		onClick = function()
			local nm = if _saveName then _saveName.Text else ""
			local cat = SAVE_CATS[_saveCatIdx]
			-- The server clamps this too; parsing here only decides what to send, so a
			-- typed "free" or an empty box means free rather than an error.
			local priceText = if _savePrice then _savePrice.Text else ""
			local priceNum = math.max(0, math.floor(tonumber(priceText) or 0))
			local ok, res = pcall(function()
				return Net.RequestEditorData:InvokeServer({ action = "save", name = nm, category = cat, price = priceNum })
			end)
			if ok then
				applyUsage(res)
				if typeof(res) == "table" and res.ok then
					_saveModal:Hide()
					toast("Saved '" .. nm .. "'")
				elseif typeof(res) == "table" and _saveHint then
					_saveHint.Text = tostring(res.err or "Save failed")
				end
			elseif _saveHint then
				_saveHint.Text = "Save failed"
			end
		end,
	}).Instance.Position = UDim2.new(1, -120, 0, 196)

	local load = Modal.new({
		size = UDim2.fromOffset(440, 500),
		title = "MY CREATIONS",
		name = "EditorLoadDialog",
		onClose = function() _loadModal:Hide() end,
	})
	_loadModal = load
	local list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.Size = UDim2.fromScale(1, 1)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.CanvasSize = UDim2.new(0, 0, 0, 0)
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollBarThickness = 5
	list.Parent = load.Content
	local ll = Instance.new("UIListLayout")
	ll.Padding = UDim.new(0, 6)
	ll.SortOrder = Enum.SortOrder.LayoutOrder
	ll.Parent = list
	_loadList = list
end

local function openSaveDialog()
	if not _saveModal then return end
	-- keep the kind chosen at start (or the last pick) as the default shelf
	refreshSaveCategory()
	if _saveHint then _saveHint.Text = "" end
	if _saveName then _saveName.Text = "" end
	if _savePrice then _savePrice.Text = "" end
	_saveModal:Show()
end

local function openMyCreations()
	if not _loadModal then return end
	_loadModal:Show()
	refreshLibrary()
end

-- == View ======================================================================
local function buildView(): any
	if _refs then return _refs end
	local refs = EditorView.build(player:WaitForChild("PlayerGui") :: PlayerGui, {
		onSave = openSaveDialog,
		onMyCreations = openMyCreations,
		onClearAll = function() deselect(); sendCmd({ action = "clear" }) end,
		onExit = function() exit() end,
		onMode = setMode,
		onDuplicate = function()
			local id = selectedId()
			if id then sendCmd({ action = "duplicate", id = id }) end
		end,
		onDelete = function()
			local id = selectedId()
			if id then sendCmd({ action = "delete", id = id }) end
			deselect()
		end,
		onUndo = function() deselect(); sendCmd({ action = "undo" }) end,
		onRedo = function() deselect(); sendCmd({ action = "redo" }) end,
		onSnap = function()
			local r = _refs
			if r then r.snap.pop.Visible = not r.snap.pop.Visible end
		end,
		onExplorer = function()
			local r = _refs
			if not r then return end
			r.explorer.panel.Visible = not r.explorer.panel.Visible
			if r.explorer.panel.Visible then refreshExplorer() end
		end,
		onCustomize = function()
			local inst = _selected
			if not inst or not inst.Parent then return end
			local key = inst:GetAttribute("AssetKey")
			if typeof(key) == "string" then
				deselect()
				sendCmd({ action = "customize", key = key })
			end
		end,
		onSearch = function(text: string)
			_search = string.lower(text)
			refreshPalette()
		end,
		snapPresetsFor = EditorGizmos.presetsFor :: any,
		onSnapPreset = function(channel: string, preset: string)
			EditorGizmos.setSnapPreset(channel, preset)
			updateSnapLabels()
		end,
		onSnapCustom = function(channel: string, value: number)
			EditorGizmos.setCustomStep(channel, value)
			updateSnapLabels()
		end,
		onSpaceToggle = function()
			EditorGizmos.setSpace(if EditorGizmos.getSpace() == "Global" then "Relative" else "Global")
			updateSnapLabels()
		end,
		onMaterialCycle = cycleMaterial,
		onCommitSound = commitSound,
		onSwatch = function(col: Color3)
			local id = selectedId()
			if id then sendCmd({ action = "appearance", id = id, color = col }) end
		end,
		onCommitSize = commitSize,
		onCommitScale = commitScale,
		onCommitRot = commitRot,
	})
	_refs = refs
	buildDialogs()
	updateSnapLabels()
	setMode("Select")
	return refs
end

-- == Asset browser content =====================================================
local function buildCats()
	local r = _refs
	if not r then return end
	local catTree = r.browser.cats :: ScrollingFrame
	for _, c in catTree:GetChildren() do
		if c:IsA("GuiButton") then c:Destroy() end
	end
	-- what the player may spawn depends on the session: a new asset is composed
	-- from basic shapes + game props; modifying an existing asset allows shapes
	-- only (the server enforces both).
	local ordered: { string }
	if inModifyMode() then
		ordered = { "Primitives" }
	else
		ordered = { "Primitives", "Props" }
	end
	if not table.find(ordered, _activeCat) then _activeCat = "Primitives" end
	for i, cat in ordered do
		local c = cat
		local rowBtn = Button.new({
			text = "  " .. c, name = c, parent = catTree, compact = true, size = UDim2.new(1, 0, 0, 26),
			onClick = function() _activeCat = c; refreshPalette(); buildCats() end,
		})
		rowBtn.Instance.LayoutOrder = i
		rowBtn.Instance.TextXAlignment = Enum.TextXAlignment.Left
		rowBtn:SetSelected(c == _activeCat)
	end
end

-- one asset card: placeholder thumbnail + name. Catalog models are server-only
-- (ServerStorage), so the client can't render a real 3D preview -- deferred.
local function makeCard(parent: Instance, e: any, order: number)
	local card = Instance.new("TextButton")
	card.Name = "Card_" .. order
	card.BackgroundColor3 = Theme.Color.Bg
	card.BackgroundTransparency = 0.3
	card.BorderSizePixel = 0
	card.Text = ""
	card.AutoButtonColor = true
	card.LayoutOrder = order
	card.Parent = parent
	local cc = Instance.new("UICorner"); cc.CornerRadius = UDim.new(0, Theme.Radius.SM); cc.Parent = card
	local thumb = Instance.new("Frame")
	thumb.Size = UDim2.new(1, -12, 0, 64)
	thumb.Position = UDim2.fromOffset(6, 6)
	thumb.BackgroundColor3 = if e.prim then Theme.Color.Accent else Theme.Color.BgHover
	thumb.BackgroundTransparency = if e.prim then 0.35 else 0
	thumb.BorderSizePixel = 0
	thumb.Parent = card
	local tc = Instance.new("UICorner"); tc.CornerRadius = UDim.new(0, 4); tc.Parent = thumb
	local glyph = Instance.new("TextLabel")
	glyph.BackgroundTransparency = 1
	glyph.Size = UDim2.fromScale(1, 1)
	glyph.Text = "\u{25A6}"
	glyph.TextSize = 28
	glyph.TextColor3 = Theme.Color.TextSecondary
	glyph.FontFace = Theme.Font.Bold
	glyph.Parent = thumb
	local nm = Instance.new("TextLabel")
	nm.BackgroundTransparency = 1
	nm.Position = UDim2.fromOffset(4, 74)
	nm.Size = UDim2.new(1, -8, 0, 30)
	nm.Text = e.name
	nm.TextSize = Theme.TextSize.XS
	nm.TextColor3 = Theme.Color.TextPrimary
	nm.FontFace = Theme.Font.Label
	nm.TextWrapped = true
	nm.TextXAlignment = Enum.TextXAlignment.Center
	nm.TextYAlignment = Enum.TextYAlignment.Top
	nm.Parent = card
	card.Activated:Connect(function()
		_placeAwait = true -- next spawned object enters drag-to-place mode
		if e.prim then sendCmd({ action = "primitive", shape = e.key })
		else sendCmd({ action = "spawn", key = e.key }) end
	end)
end

refreshPalette = function()
	local r = _refs
	if not r then return end
	local grid = r.browser.grid :: ScrollingFrame
	for _, c in grid:GetChildren() do
		if c:IsA("GuiButton") then c:Destroy() end
	end
	local function matches(name: string): boolean
		return _search == "" or string.find(string.lower(name), _search, 1, true) ~= nil
	end
	local entries: { any } = {}
	if _activeCat == "Primitives" then
		for _, shape in PRIMITIVES do
			local def = ShapeCatalog.byKey[shape]
			-- Search hits either spelling: "halfpipe" and "half pipe" both find the same card.
			if matches(def.name) or matches(shape) then
				table.insert(entries, { name = def.name, key = shape, prim = true })
			end
		end
	elseif _activeCat == "Props" and _catalog and not inModifyMode() then
		for _, e in _catalog :: { any } do
			if e.cat == "Props" and matches(e.name) then
				table.insert(entries, e)
			end
		end
	end
	local shown = math.min(#entries, 400) -- ponytail: no virtualization; cap render, refine search for more
	for i = 1, shown do makeCard(grid, entries[i], i) end
	r.browser.count.Text = string.format("%d element%s", #entries, if #entries == 1 then "" else "s")
end

local function rebuildBrowser()
	local ok1, err1 = pcall(buildCats)
	if not ok1 then warn("[Editor] buildCats failed: " .. tostring(err1)) end
	local ok2, err2 = pcall(refreshPalette)
	if not ok2 then warn("[Editor] refreshPalette failed: " .. tostring(err2)) end
end

local function ensureCatalog(): boolean
	if _catalog and #_catalog > 0 then return true end
	local ok, res = pcall(function() return Net.RequestEditorData:InvokeServer({ action = "catalog" }) end)
	if ok and typeof(res) == "table" and res.ok and typeof(res.entries) == "table" and #res.entries > 0 then
		_catalog = res.entries
		table.clear(_cats)
		local seen: { [string]: boolean } = {}
		for _, e in res.entries do
			if not seen[e.cat] then seen[e.cat] = true; table.insert(_cats, e.cat) end
		end
		table.sort(_cats)
		return true
	end
	return false
end

local function fetchCatalog()
	rebuildBrowser() -- show All/Primitives instantly, before the catalog round-trip
	for _ = 1, 6 do
		if ensureCatalog() then break end
		task.wait(0.5)
	end
	rebuildBrowser()
end

refreshLibrary = function()
	local ok, res = pcall(function() return Net.RequestEditorData:InvokeServer({ action = "list" }) end)
	-- Review state is a second round trip on purpose: it lives in its own store, and
	-- failing to reach it must not cost the player sight of their own creations. Read
	-- BEFORE applyUsage, which is what re-renders the rows that show it.
	local okReview, resReview = pcall(function()
		return Net.RequestReviewQueue:InvokeServer({ action = "mine" })
	end)
	if okReview and typeof(resReview) == "table" and resReview.ok and typeof(resReview.statuses) == "table" then
		_reviewStatus = resReview.statuses
	end
	if ok and typeof(res) == "table" and res.ok then applyUsage(res) end
end

-- == Properties / toolbar ======================================================
refreshProps = function()
	local r = _refs
	if not r then return end
	local inst = _selected
	local editable = inst ~= nil and inst.Parent ~= nil and (inst:IsA("BasePart") or inst:IsA("Model"))
	r.props.empty.Visible = not editable
	if not editable or not inst then return end
	r.props.nameLabel.Text = inst.Name
	local isPart = inst:IsA("BasePart")
	r.props.sizeRow.Visible = isPart
	r.props.scaleBox.Visible = not isPart
	r.props.dimLabel.Text = if isPart then "Size (studs)" else "Scale"
	if isPart then
		local s = (inst :: BasePart).Size
		local comp = { s.X, s.Y, s.Z }
		for i, tb in r.props.sizeBoxes :: { TextBox } do
			if not tb:IsFocused() then tb.Text = string.format("%.2f", comp[i]) end
		end
	elseif not (r.props.scaleBox :: TextBox):IsFocused() then
		r.props.scaleBox.Text = string.format("%.2f", (inst :: Model):GetScale())
	end
	if not (r.props.rotBox :: TextBox):IsFocused() then
		local _, yaw = (inst :: PVInstance):GetPivot():ToOrientation()
		r.props.rotBox.Text = string.format("%.0f", math.deg(yaw))
	end
	local mat = if isPart then tostring(inst:GetAttribute("Mat") or (inst :: BasePart).Material.Name) else "-"
	r.props.matBtn.Instance.Text = "Material: " .. mat
	r.props.soundRow.Visible = isPart
	if isPart and not (r.props.soundBox :: TextBox):IsFocused() then
		local sid = inst:GetAttribute("SoundId")
		r.props.soundBox.Text = if typeof(sid) == "string" then (string.match(sid, "%d+") or "") else ""
	end
end

updateToolbar = function()
	local r = _refs
	local inst = _selected
	local hasSel = inst ~= nil and inst.Parent ~= nil
	if r then
		r.dupBtn:SetEnabled(hasSel)
		r.delBtn:SetEnabled(hasSel)
		-- no re-customize while already customizing: it would wipe the session
		r.customizeBtn:SetEnabled(hasSel and inst ~= nil and inst:GetAttribute("AssetKey") ~= nil and not inModifyMode())
	end
	refreshProps()
	EditorGizmos.sync()
	if r and r.explorer.panel.Visible then refreshExplorer() end
end

-- == My Creations list =========================================================
refreshLoadList = function()
	local list = _loadList
	if not list then return end
	for _, c in list:GetChildren() do
		if c:IsA("GuiObject") then c:Destroy() end
	end
	if #_creations == 0 then
		local empty = label(list, "No saved creations yet. Build something, then Save.", UDim2.new(1, 0, 0, 40), UDim2.new(), Theme.Font.Label, Theme.TextSize.SM, Theme.Color.TextSecondary)
		empty.Name = "Empty"
		empty.TextWrapped = true
		return
	end
	for i, c in _creations do
		local rowF = Instance.new("Frame")
		rowF.Name = "Row_" .. i
		rowF.Size = UDim2.new(1, 0, 0, 44)
		rowF.BackgroundColor3 = Theme.Color.Bg
		rowF.BorderSizePixel = 0
		rowF.LayoutOrder = i
		rowF.Parent = list
		local rc = Instance.new("UICorner"); rc.CornerRadius = UDim.new(0, Theme.Radius.SM); rc.Parent = rowF
		local nameLbl = label(rowF, tostring(c.name), UDim2.fromOffset(190, 20), UDim2.fromOffset(10, 4), Theme.Font.Header, Theme.TextSize.SM, Theme.Color.TextPrimary)
		nameLbl.TextTruncate = Enum.TextTruncate.AtEnd

		local id = c.id
		local cName = tostring(c.name)
		local shelf = CreationCategories.getOrDefault(c.cat)
		local price = tonumber(c.price) or 0
		local review = _reviewStatus[tostring(id)]
		local state = if typeof(review) == "table" then tostring(review.status) else nil

		local subLbl = label(rowF, string.format("%s  \u{00B7}  %d parts  \u{00B7}  %s%s",
			shelf.label,
			tonumber(c.count) or 0,
			if price > 0 then tostring(price) else "free",
			if state then "  \u{00B7}  " .. string.upper(state) else ""),
			UDim2.fromOffset(190, 16), UDim2.fromOffset(10, 22), Theme.Font.Label, Theme.TextSize.XS, Theme.Color.TextSecondary)
		subLbl.TextTruncate = Enum.TextTruncate.AtEnd
		if state == "rejected" then subLbl.TextColor3 = Theme.Color.Danger end

		-- Only offer to send what can actually be sent. Something already waiting is not
		-- resubmittable, and something approved is already live; a rejected creation CAN go
		-- back, which is the whole point of telling the author why it bounced.
		if state == nil or state == "rejected" then
			Button.new({
				text = if state == "rejected" then "Resend" else "Send",
				name = "Submit", parent = rowF, compact = true, size = UDim2.fromOffset(64, 28),
				onClick = function()
					local okSend, resSend = pcall(function()
						return Net.RequestReviewQueue:InvokeServer({ action = "submit", id = id })
					end)
					if okSend and typeof(resSend) == "table" then
						toast(tostring(resSend.message or (if resSend.ok then "Sent for review" else "Couldn't send that")))
					else
						toast("Couldn't send that")
					end
					refreshLibrary()
				end,
			}).Instance.Position = UDim2.new(1, -202, 0.5, -14)
		end
		Button.new({
			text = "Load", name = "Load", parent = rowF, compact = true, size = UDim2.fromOffset(60, 28),
			onClick = function()
				deselect()
				sendCmd({ action = "load", id = id })
				if _loadModal then _loadModal:Hide() end
				toast("Loaded '" .. cName .. "'")
			end,
		}).Instance.Position = UDim2.new(1, -134, 0.5, -14)
		Button.new({
			text = "Delete", name = "Delete", parent = rowF, compact = true, variant = "Danger", size = UDim2.fromOffset(64, 28),
			onClick = function()
				local ok, res = pcall(function()
					return Net.RequestEditorData:InvokeServer({ action = "deleteCreation", id = id })
				end)
				if ok then applyUsage(res) end
			end,
		}).Instance.Position = UDim2.new(1, -68, 0.5, -14)
	end
end

-- == Explorer ==================================================================
local function sessionContent(): Folder?
	local s = sessionRoot()
	local c = s and s:FindFirstChild("Content")
	if c and c:IsA("Folder") then return c end
	return nil
end

-- Studio-style tree: each node is a row (indented by depth) with an expand arrow
-- for containers + a label that selects the part (if tagged) or toggles expand.
refreshExplorer = function()
	local r = _refs
	if not r then return end
	local list = r.explorer.list :: ScrollingFrame
	for _, c in list:GetChildren() do
		if c:IsA("GuiObject") then c:Destroy() end
	end
	local content = sessionContent()
	if not content then return end

	local order = 0
	local function kidsOf(inst: Instance): { Instance }
		local out: { Instance } = {}
		for _, c in inst:GetChildren() do
			if c:IsA("BasePart") or c:IsA("Model") or c:IsA("Folder") then table.insert(out, c) end
		end
		return out
	end

	local function renderNode(inst: Instance, depth: number)
		if not (inst:IsA("BasePart") or inst:IsA("Model") or inst:IsA("Folder")) then return end
		order += 1
		local kids = kidsOf(inst)
		local expandable = #kids > 0
		local expanded = _expanded[inst] == true
		local selectable = inst:GetAttribute("EditorId") ~= nil

		local rowF = Instance.new("Frame")
		rowF.Name = "Node"
		rowF.Size = UDim2.new(1, 0, 0, 24)
		rowF.BackgroundColor3 = Theme.Color.BgHover
		rowF.BackgroundTransparency = if _selected == inst then 0.15 else 1
		rowF.BorderSizePixel = 0
		rowF.LayoutOrder = order
		rowF.Parent = list
		local rc = Instance.new("UICorner"); rc.CornerRadius = UDim.new(0, 4); rc.Parent = rowF

		local x = 2 + depth * 12
		if expandable then
			local arrow = Instance.new("TextButton")
			arrow.Size = UDim2.fromOffset(16, 24)
			arrow.Position = UDim2.fromOffset(x, 0)
			arrow.BackgroundTransparency = 1
			arrow.Text = if expanded then "\u{25BC}" else "\u{25B6}"
			arrow.TextColor3 = Theme.Color.TextSecondary
			arrow.TextSize = 10
			arrow.FontFace = Theme.Font.Label
			arrow.Parent = rowF
			arrow.Activated:Connect(function()
				_expanded[inst] = not expanded
				refreshExplorer()
			end)
		end

		-- Studio-style class icon: PNG from the Icons registry once uploaded,
		-- glyph text fallback until then
		local entry = if inst:IsA("Model") then Icons.get("ClassModel")
			elseif inst:IsA("Folder") then Icons.get("ClassFolder")
			else Icons.get("ClassPart")
		local textX = x + 16
		local prefix = ""
		if entry and entry.image ~= "" then
			local ic = Instance.new("ImageLabel")
			ic.Name = "ClassIcon"
			ic.BackgroundTransparency = 1
			ic.Position = UDim2.fromOffset(x + 16, 4)
			ic.Size = UDim2.fromOffset(16, 16)
			ic.Image = entry.image
			ic.ImageColor3 = if selectable then Theme.Color.TextPrimary else Theme.Color.TextSecondary
			ic.ScaleType = Enum.ScaleType.Fit
			ic.Parent = rowF
			textX = x + 36
		else
			prefix = (if entry then entry.glyph else "\u{25AA}") .. " "
		end
		local lbl = Instance.new("TextButton")
		lbl.Size = UDim2.new(1, -(textX + 2), 1, 0)
		lbl.Position = UDim2.fromOffset(textX, 0)
		lbl.BackgroundTransparency = 1
		lbl.Text = prefix .. inst.Name
		lbl.TextColor3 = if selectable then Theme.Color.TextPrimary else Theme.Color.TextSecondary
		lbl.TextSize = Theme.TextSize.XS
		lbl.FontFace = Theme.Font.Label
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.TextTruncate = Enum.TextTruncate.AtEnd
		lbl.Parent = rowF
		lbl.Activated:Connect(function()
			if selectable then
				if inst.Parent then select(inst) end
			elseif expandable then
				_expanded[inst] = not expanded
				refreshExplorer()
			end
		end)

		if expandable and expanded then
			for _, c in kids do renderNode(c, depth + 1) end
		end
	end

	for _, inst in content:GetChildren() do
		renderNode(inst, 0)
	end
end

local function hookExplorer()
	if _explorerHooked then return end
	task.spawn(function()
		local root = Workspace:WaitForChild("_Editor", 10)
		local s = root and root:WaitForChild("Session_" .. player.UserId, 10)
		local content = s and s:WaitForChild("Content", 10)
		if not content or not content:IsA("Folder") then return end
		_explorerHooked = true
		local queued = false
		local function maybe(d: Instance)
			local r = _refs
			if not r or not r.explorer.panel.Visible then return end
			if not (d:IsA("BasePart") or d:IsA("Model") or d:IsA("Folder")) then return end
			if queued then return end
			queued = true
			task.defer(function() queued = false; refreshExplorer() end)
		end
		content.DescendantAdded:Connect(maybe)
		content.DescendantRemoving:Connect(maybe)
		-- customize (modify mode) announces itself via bounds attributes on the
		-- session folder: restrict the palette + show the footprint region
		local sessionFolder = content.Parent :: Instance
		sessionFolder:GetAttributeChangedSignal("BoundsHX"):Connect(function()
			rebuildBrowser()
			updateBoundsVisual()
		end)
		task.defer(function()
			rebuildBrowser()
			updateBoundsVisual()
		end)
		-- drag-to-place: grab the freshly spawned object and let it follow the cursor
		content.ChildAdded:Connect(function(child: Instance)
			if not _placeAwait then return end
			task.defer(function()
				if not _placeAwait or not child.Parent then return end
				if not child:IsA("PVInstance") or child:GetAttribute("EditorId") == nil then return end
				_placeAwait = false
				select(child)
				_placing = true
				_placingInst = child :: PVInstance
			end)
		end)
		task.defer(refreshExplorer)
	end)
end

-- == Build grid + bounds =======================================================
-- Client-only decoration: a grid + build-area border on the plate top so the
-- viewport reads as a build surface, not empty space.
local function buildGrid()
	if _gridBoard and _gridBoard.Parent then return end
	local origin = EditorConfig.Origin
	local gs = EditorConfig.GroundSize
	local board = Instance.new("Part")
	board.Name = "EditorGrid"
	board.Anchored = true
	board.CanCollide = false
	board.CanQuery = false -- must not intercept selection/placement raycasts
	board.CanTouch = false
	board.Transparency = 1
	board.Size = Vector3.new(gs.X, 0.2, gs.Z)
	board.CFrame = CFrame.new(origin.X, origin.Y + gs.Y / 2 + 0.05, origin.Z)
	board.Parent = Workspace
	_gridBoard = board

	local sg = Instance.new("SurfaceGui")
	sg.Name = "Grid"
	sg.Face = Enum.NormalId.Top
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.PixelsPerStud = 1
	sg.Adornee = board
	sg.Parent = board

	local nx = math.max(1, math.floor(gs.X / GRID_STEP))
	local nz = math.max(1, math.floor(gs.Z / GRID_STEP))
	for i = 0, nx do
		local v = Instance.new("Frame")
		v.BackgroundColor3 = Theme.Color.Stroke
		v.BackgroundTransparency = 0.4
		v.BorderSizePixel = 0
		v.Size = UDim2.new(0, 1, 1, 0)
		v.Position = UDim2.new(i / nx, 0, 0, 0)
		v.Parent = sg
	end
	for i = 0, nz do
		local h = Instance.new("Frame")
		h.BackgroundColor3 = Theme.Color.Stroke
		h.BackgroundTransparency = 0.4
		h.BorderSizePixel = 0
		h.Size = UDim2.new(1, 0, 0, 1)
		h.Position = UDim2.new(0, 0, i / nz, 0)
		h.Parent = sg
	end
	local border = Instance.new("Frame")
	border.BackgroundTransparency = 1
	border.Size = UDim2.fromScale(1, 1)
	border.Parent = sg
	local bs = Instance.new("UIStroke")
	bs.Color = Theme.Color.Accent
	bs.Thickness = 3
	bs.Transparency = 0.2
	bs.Parent = border
end

local function destroyGrid()
	if _gridBoard then _gridBoard:Destroy(); _gridBoard = nil end
end

-- == Day lighting (local only) =================================================
local function applyDayLighting()
	if _prevClockTime == nil then _prevClockTime = Lighting.ClockTime end
	Lighting.ClockTime = EDITOR_CLOCK
end

local function restoreLighting()
	if _prevClockTime ~= nil then
		Lighting.ClockTime = _prevClockTime
		_prevClockTime = nil
	end
end

-- == Start flow: New vs Modify =================================================
-- Pressing Editor opens a chooser: "create new asset or modify an existing
-- one?". Modify pulls the game-asset catalog into a searchable picker;
-- choosing an entry opens the editor with that asset loaded (customize).
local _start: { chooser: any, kind: any, picker: any, rows: ScrollingFrame?, searchBox: TextBox?, search: string } =
	{ chooser = nil, kind = nil, picker = nil, rows = nil, searchBox = nil, search = "" }
local startEditor: (customizeKey: string?) -> ()
local openPicker: () -> ()
local refreshPicker: () -> ()

local function buildStartDialogs()
	if _start.chooser then return end

	local chooser = Modal.new({
		size = UDim2.fromOffset(440, 270),
		title = "CREATION EDITOR",
		name = "EditorStartChooser",
		onClose = function()
			_start.chooser:Hide()
			UIEvents.ReturnToMainMenu:Fire()
		end,
	})
	_start.chooser = chooser
	local cc = chooser.Content
	Button.new({
		text = "Create New Asset", name = "NewAsset", parent = cc, size = UDim2.new(1, 0, 0, 48),
		onClick = function()
			chooser:Hide()
			_start.kind:Show()
		end,
	}).Instance.Position = UDim2.fromOffset(0, 8)
	local newHint = label(cc, "Start on an empty platform and build from basic shapes and game props.",
		UDim2.new(1, 0, 0, 16), UDim2.fromOffset(0, 60), Theme.Font.Label, Theme.TextSize.XS, Theme.Color.TextSecondary)
	newHint.TextWrapped = true
	Button.new({
		text = "Modify Existing Asset", name = "ModifyAsset", parent = cc, size = UDim2.new(1, 0, 0, 48),
		onClick = function()
			chooser:Hide()
			openPicker()
		end,
	}).Instance.Position = UDim2.fromOffset(0, 96)
	local modHint = label(cc, "Pick any game asset and edit a copy of it: add shapes, remove or restyle parts.",
		UDim2.new(1, 0, 0, 16), UDim2.fromOffset(0, 148), Theme.Font.Label, Theme.TextSize.XS, Theme.Color.TextSecondary)
	modHint.TextWrapped = true

	-- "what kind of asset?" -- the game's own creation categories; the pick
	-- presets the save category so the creation lands in the right shelf
	local kindModal = Modal.new({
		size = UDim2.fromOffset(440, 340),
		title = "WHAT KIND OF ASSET?",
		name = "EditorKindPicker",
		onClose = function()
			_start.kind:Hide()
			_start.chooser:Show()
		end,
	})
	_start.kind = kindModal
	local kc = kindModal.Content
	for i, cat in SAVE_CATS do
		local idx = i
		local entry = CreationCategories.getOrDefault(cat)
		Button.new({
			text = entry.label, name = cat, parent = kc, size = UDim2.new(1, 0, 0, 40),
			onClick = function()
				_saveCatIdx = idx
				refreshSaveCategory()
				_start.kind:Hide()
				startEditor(nil)
			end,
		}).Instance.Position = UDim2.fromOffset(0, (i - 1) * 48 + 4)
	end

	local picker = Modal.new({
		size = UDim2.fromOffset(480, 540),
		title = "CHOOSE AN ASSET",
		name = "EditorAssetPicker",
		onClose = function() -- back to the chooser, not the menu
			_start.picker:Hide()
			_start.chooser:Show()
		end,
	})
	_start.picker = picker
	local pc = picker.Content
	local search = dialogTextBox(pc, "Search", "Search assets...")
	search.Size = UDim2.new(1, 0, 0, 30)
	search:GetPropertyChangedSignal("Text"):Connect(function()
		_start.search = string.lower(search.Text)
		refreshPicker()
	end)
	_start.searchBox = search

	local list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.Position = UDim2.fromOffset(0, 40)
	list.Size = UDim2.new(1, 0, 1, -40)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.CanvasSize = UDim2.new(0, 0, 0, 0)
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollBarThickness = 5
	list.Parent = pc
	local ll = Instance.new("UIListLayout")
	ll.Padding = UDim.new(0, 4)
	ll.SortOrder = Enum.SortOrder.LayoutOrder
	ll.Parent = list
	_start.rows = list
end

refreshPicker = function()
	local list = _start.rows
	if not list then return end
	for _, c in list:GetChildren() do
		if c:IsA("GuiObject") then c:Destroy() end
	end
	local cat = _catalog
	if not cat or #cat == 0 then
		local l = label(list, "Loading assets...", UDim2.new(1, 0, 0, 30), UDim2.new(),
			Theme.Font.Label, Theme.TextSize.SM, Theme.Color.TextSecondary)
		l.TextXAlignment = Enum.TextXAlignment.Center
		return
	end
	local q = _start.search
	local shown = 0
	for _, e in cat do
		if q == "" or string.find(string.lower(e.name), q, 1, true) or string.find(string.lower(e.cat), q, 1, true) then
			shown += 1
			if shown > 150 then break end -- ponytail: no virtualization; search narrows the rest
			local row = Instance.new("TextButton")
			row.Name = "Asset_" .. shown
			row.Size = UDim2.new(1, 0, 0, 40)
			row.BackgroundColor3 = Theme.Color.Bg
			row.BorderSizePixel = 0
			row.Text = ""
			row.AutoButtonColor = true
			row.LayoutOrder = shown
			row.Parent = list
			local rc = Instance.new("UICorner"); rc.CornerRadius = UDim.new(0, Theme.Radius.SM); rc.Parent = row
			local nm = label(row, e.name, UDim2.new(1, -20, 0, 18), UDim2.fromOffset(10, 3),
				Theme.Font.Header, Theme.TextSize.SM, Theme.Color.TextPrimary)
			nm.TextTruncate = Enum.TextTruncate.AtEnd
			label(row, e.cat, UDim2.new(1, -20, 0, 14), UDim2.fromOffset(10, 22),
				Theme.Font.Label, Theme.TextSize.XS, Theme.Color.TextSecondary)
			local key = e.key
			row.Activated:Connect(function()
				_start.picker:Hide()
				startEditor(key)
			end)
		end
	end
end

openPicker = function()
	_start.search = ""
	local sb = _start.searchBox
	if sb then sb.Text = "" end
	_start.picker:Show()
	refreshPicker()
	if not (_catalog and #_catalog > 0) then
		task.spawn(function()
			for _ = 1, 6 do
				if ensureCatalog() then break end
				task.wait(0.5)
			end
			if _start.picker:IsOpen() then refreshPicker() end
		end)
	end
end

startEditor = function(customizeKey: string?)
	if _open then return end
	_open = true
	-- Ctrl+Z is global in the city; this tells it to stand down while the editor owns the keys.
	player:SetAttribute("CreationEditorOpen", true)
	claimGizmo()
	local refs = buildView()
	refs.gui.Enabled = true
	buildGrid()
	applyDayLighting()
	FreeCamController.setCameraState({ pos = CAM_POS, yaw = CAM_YAW, pitch = CAM_PITCH })
	Net.RequestEnterEditor:FireServer()
	hookExplorer()
	task.spawn(fetchCatalog)
	task.spawn(refreshLibrary)
	if customizeKey then
		-- customize needs the server session; its folder replicating in means it exists
		task.spawn(function()
			local root = Workspace:WaitForChild("_Editor", 10)
			local s = root and root:WaitForChild("Session_" .. player.UserId, 10)
			if s and _open then sendCmd({ action = "customize", key = customizeKey }) end
		end)
	end
end

local function enter()
	if _open then return end
	buildStartDialogs()
	_start.chooser:Show()
end

exit = function()
	if not _open then return end
	_open = false
	player:SetAttribute("CreationEditorOpen", nil)
	EditorGizmos.release(GIZMO_OWNER)
	_dragging = false
	_placing = false
	_placingInst = nil
	_placeAwait = false
	deselect()
	_explorerHooked = false
	destroyGrid()
	if _boundsPart then _boundsPart:Destroy(); _boundsPart = nil end
	_activeCat = "Primitives"
	restoreLighting()
	if _saveModal then _saveModal:Hide() end
	if _loadModal then _loadModal:Hide() end
	local r = _refs
	if r then
		r.snap.pop.Visible = false
		r.gui.Enabled = false
	end
	Net.RequestExitEditor:FireServer()
	UIEvents.ReturnToMainMenu:Fire()
end

-- == World input (select + drag) ===============================================
local function sendTransform(cf: CFrame)
	local now = os.clock()
	if now - _lastSendAt < 0.03 then return end
	_lastSendAt = now
	local id = selectedId()
	if id then sendCmd({ action = "transform", id = id, cf = cf }) end
end

local function onInputBegan(input: InputObject, processed: boolean)
	if not _open then return end
	-- processed = typing in a box / clicking UI. Ignore world shortcuts + selection then
	-- (also keeps us off FreeCam's WASD/QE/RF fly keys).
	if processed then return end
	-- drag-to-place: click drops the object, R rotates it, Esc cancels the spawn
	if _placing then
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			local inst = _placingInst
			_placing = false
			_placingInst = nil
			if inst and inst.Parent then
				local id = selectedId()
				if id then sendCmd({ action = "transform", id = id, cf = inst:GetPivot() }) end
			end
			return
		elseif Settings.pressed("RotateObject", input) then
			local inst = _placingInst
			if inst and inst.Parent then
				local newCf = inst:GetPivot() * CFrame.Angles(0, math.rad(45), 0)
				if fitsPivot(inst, newCf) then
					inst:PivotTo(newCf)
					local id = selectedId()
					if id then sendCmd({ action = "transform", id = id, cf = inst:GetPivot() }) end
				end
			end
			return
		elseif Settings.pressed("Back", input) then
			local inst = _placingInst
			_placing = false
			_placingInst = nil
			local id = selectedId()
			if id then sendCmd({ action = "delete", id = id }) end
			deselect()
			return
		end
	end
	if Settings.pressed("Back", input) then deselect(); return end
	if Settings.pressed("Delete", input) then
		local id = selectedId()
		if id then sendCmd({ action = "delete", id = id }); deselect() end
		return
	end
	if Settings.pressed("Undo", input) then
		deselect() -- scene rebuilds server-side; EditorIds change, so drop local selection
		sendCmd({ action = "undo" })
		return
	end
	if Settings.pressed("Redo", input) then
		deselect(); sendCmd({ action = "redo" }); return
	end
	if not Settings.pressed("Place", input) then return end

	-- Ctrl+click drills into a model: grab the exact part under the cursor and
	-- select it (Studio Alt-click style), then drag to move it. The server tags
	-- that part with its own EditorId so transforms address it.
	if Settings.isActionDown("PreciseModifier") then
		local part = rawHitPart()
		if part and hasEditorAncestor(part) then
			if part:GetAttribute("EditorId") == nil then
				sendCmd({ action = "grabPart", part = part })
			end
			if part ~= _selected then select(part) end
			_dragging = true
			_manipStartPivot = part:GetPivot()
			_manipStartMouse = UserInputService:GetMouseLocation()
			_manipStartScale = EditorGizmos.selectionScale(part)
			local ground = mouseToGround()
			if ground then
				local pivot = _manipStartPivot.Position
				_dragOffset = pivot - Vector3.new(ground.X, pivot.Y, ground.Z)
			end
			return
		end
	end

	local obj = editorObjectAt()
	if not obj then
		-- Clicking empty air clears the selection. Defer one step so a gizmo-handle
		-- grab (its own MouseButton1Down fires this same click) can cancel the clear
		-- -- otherwise clicking a Move/Rotate/Scale arrow would deselect the thing
		-- you're trying to manipulate.
		task.defer(function()
			if not EditorGizmos.isDragging() and not _dragging then deselect() end
		end)
		return
	end
	if obj ~= _selected then select(obj) end -- don't re-adorn when grabbing its arrow
	if not obj:IsA("PVInstance") then return end
	-- Start a manipulation drag; the active tool decides what it does.
	_dragging = true
	_manipStartPivot = obj:GetPivot()
	_manipStartMouse = UserInputService:GetMouseLocation()
	_manipStartScale = EditorGizmos.selectionScale(obj)
	local ground = mouseToGround()
	if ground then
		local pivot = _manipStartPivot.Position
		_dragOffset = pivot - Vector3.new(ground.X, pivot.Y, ground.Z)
	end
end

local function onInputEnded(input: InputObject)
	if not Settings.pressed("Place", input) then return end
	if not _dragging then return end
	_dragging = false
	local inst = _selected
	if not inst or not inst.Parent or not inst:IsA("PVInstance") then return end
	local id = selectedId()
	if not id then return end
	-- Final authoritative value so a dropped mid-drag packet can't leave drift.
	if EditorGizmos.getMode() == "Scale" then
		sendCmd({ action = "setScale", id = id, scale = EditorGizmos.selectionScale(inst) })
	else
		sendCmd({ action = "transform", id = id, cf = (inst :: PVInstance):GetPivot() })
	end
end

local function onInputChanged(input: InputObject)
	if not _open then return end
	if _placing and _placingInst then
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			local inst = _placingInst
			if inst and inst.Parent then
				local ground = mouseToGround()
				if ground then
					local cur = inst:GetPivot()
					local newCf = CFrame.new(EditorGizmos.snapLen(ground.X), cur.Position.Y, EditorGizmos.snapLen(ground.Z)) * cur.Rotation
					if fitsPivot(inst, newCf) then
						inst:PivotTo(newCf)
						sendTransform(newCf)
					end
				end
			end
		end
		return
	end
	if EditorGizmos.isDragging() then return end -- the gizmo handles are driving the drag
	if not _dragging then return end
	if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
	local inst = _selected
	if not inst or not inst.Parent or not inst:IsA("PVInstance") then _dragging = false; return end
	local pv = inst :: PVInstance
	local mode = EditorGizmos.getMode()

	if mode == "Rotate" then
		local mouse = UserInputService:GetMouseLocation()
		local yaw = math.rad(EditorGizmos.snapDeg((mouse.X - _manipStartMouse.X) * ROT_SENS))
		local newCf = _manipStartPivot * CFrame.Angles(0, yaw, 0)
		if not fitsPivot(pv, newCf) then return end
		pv:PivotTo(newCf)
		sendTransform(newCf)
	elseif mode == "Scale" then
		local mouse = UserInputService:GetMouseLocation()
		local target = math.clamp(_manipStartScale + (_manipStartMouse.Y - mouse.Y) * SCALE_SENS, 0.2, 5)
		if inst:IsA("Model") then
			local m = inst :: Model
			local bcf, bsize = m:GetBoundingBox()
			if not fitsBounds(bcf, bsize * (target / m:GetScale())) then return end
			m:ScaleTo(target)
		else
			local base = inst:GetAttribute("BaseSize")
			if typeof(base) == "Vector3" then
				local newSize = (base :: Vector3) * target
				if not fitsBounds((inst :: BasePart).CFrame, newSize) then return end
				(inst :: BasePart).Size = newSize
			end
		end
		local now = os.clock()
		if now - _lastSendAt >= 0.04 then
			_lastSendAt = now
			local id = selectedId()
			if id then sendCmd({ action = "setScale", id = id, scale = target }) end
		end
	else
		-- Move / Select / Transform: slide on the ground plane (grid-snapped delta)
		local ground = mouseToGround()
		if not ground then return end
		local sp = _manipStartPivot.Position
		local dx = EditorGizmos.snapLen(ground.X + _dragOffset.X - sp.X)
		local dz = EditorGizmos.snapLen(ground.Z + _dragOffset.Z - sp.Z)
		local newCf = CFrame.new(sp.X + dx, sp.Y, sp.Z + dz) * (_manipStartPivot - sp)
		if not fitsPivot(pv, newCf) then return end
		pv:PivotTo(newCf)
		sendTransform(newCf)
	end
	EditorGizmos.sync() -- keep the visual gizmo on the object as it moves
end

function EditorController.Start()
	UIEvents.OpenEditor.Event:Connect(enter)
	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)
	UserInputService.InputChanged:Connect(onInputChanged)
end

return EditorController
