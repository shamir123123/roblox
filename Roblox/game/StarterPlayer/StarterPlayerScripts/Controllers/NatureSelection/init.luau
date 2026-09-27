--!strict
-- NatureSelection
-- Click a placed prop when nothing owns the cursor and it becomes a SELECTION: outlined,
-- with a small action bar over the HUD. Delete, cut, copy, paste and group live there. Until
-- now the Nature tab could only ever PLACE -- the only way to touch a prop again was the
-- bulldozer, which is a one-way door.
--
-- Three gestures, one modifier set, every one of them rebindable (Settings section
-- "Selection"):
--   click             pick one; a click on nothing clears
--   SelectAdd + click toggle one in or out (CONTROL)
--   SelectBox + drag  a CAPTURE BOX drawn on the SCREEN (CONTROL + SHIFT)
--
-- The capture box is a screen rectangle, not a volume: a prop is caught when its pivot
-- PROJECTS inside the rectangle, so what the box covers on screen is what it takes. Props are
-- CanQuery=false (ModelBaker bakes them that way), so none of this can be a raycast -- picking
-- goes through CursorRay.modelUnderRay (nearestPivot as fallback), and the box test
-- is Camera:WorldToViewportPoint. Those two, UserInputService's mouse location and an
-- IgnoreGuiInset ScreenGui all share ONE space (see the note at the top of Core.CursorRay),
-- which is the only reason the rectangle the player drags and the props it catches agree.
--
-- CUT and COPY are NOT a clipboard. Both mean "put this exact prop back on the cursor, in
-- the menu it came from" -- card ticked, colour, material, size and stretch and all -- and
-- cut also takes the original down, which the server refunds. So there is no paste: the
-- placement tool already is the paste, and a better one. Hold SHIFT with either and the copy
-- comes back in precise mode, with the handles on what you place.
--
-- GROUPS are client-side and session-only: a group id is a number in a table here, never an
-- attribute and never in the save blob. ponytail: groups would need a fourteenth stride slot
-- (FORMAT_V4) in NaturePlaceService to survive a reload -- add it when someone misses them.
--
-- Owns no prop state. The server owns every prop; this module holds a list of references and
-- the group map.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage:WaitForChild("Networker"))
local NatureCatalog = require(ReplicatedStorage:WaitForChild("Nature"):WaitForChild("NatureCatalog"))

local uiFolder = script.Parent.Parent:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local kit = uiFolder:WaitForChild("Kit")
local Button = require(kit:WaitForChild("Button"))
local Dropdown = require(kit:WaitForChild("Dropdown"))
local Modal = require(kit:WaitForChild("Modal"))
local MaterialCatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MaterialCatalog"))

local coreFolder = script.Parent.Parent:WaitForChild("Core")
local Settings = require(coreFolder:WaitForChild("Settings"))
local SoundFX = require(coreFolder:WaitForChild("SoundFX"))
local CursorRay = require(coreFolder:WaitForChild("CursorRay"))
local UiScratch = require(coreFolder:WaitForChild("UiScratch"))

local DeleteHover = require(script.Parent:WaitForChild("DeleteHoverController"))
local NatureGizmo = require(script.Parent:WaitForChild("NatureGizmo"))
-- CUT and COPY hand a prop's look straight back to the placement tool, and ask its shelf to
-- come up with that card ticked. Those two calls are the whole of what they do.
local Nature = require(script.Parent:WaitForChild("NaturePlacementController"))
-- The colour menu, shared with the precise panel: one picker in the game, not three.
local ColorPanel = require(script.Parent:WaitForChild("ColorPanel"))

local NatureSelection = {}

-- Most props one selection may hold. Well past what a capture box over a screenful of city
-- catches, and it keeps the outline pool and the remote chunking bounded.
local CAP = 256
-- Must not exceed NaturePlaceService.MAX_PER_CALL, and the pause between chunks must clear
-- its per-player CALL_COOLDOWN (0.08s) or the server drops every second batch on the floor.
local CHUNK = 64
local CHUNK_PAUSE = 0.1
-- The bulldozer's click allowance, in SCREEN pixels, for the same reason it is not studs
-- there: a fixed stud radius is two different tools at two zoom levels.
local PICK_PX = 22
local PICK_MIN, PICK_MAX = 2, 25
local PICK_MAX_DY = 16
-- Under this, a modified drag was a modified CLICK. Without it every ctrl+shift click that
-- wobbled a pixel selected nothing at all.
local BOX_MIN_PX = 6
-- A stamp is placed in ONE RequestPlaceNature call, so it cannot be larger than the server
-- takes in one. Cut more than this and the rest still come DOWN -- only the arrangement you
-- get back on the cursor is trimmed.
local STAMP_MAX = CHUNK
local BAR_W = 430
local SELECT_COLOR = "Bulldoze" -- DeleteHover's white outline + faint fill

-- == Pure helpers =============================================================
-- Exported so the spec can hold them without a game running.

-- Drag corners in, screen rectangle out. Either drag direction, always min/max.
function NatureSelection.rectOf(a: Vector2, b: Vector2): (number, number, number, number)
	return math.min(a.X, b.X), math.min(a.Y, b.Y), math.max(a.X, b.X), math.max(a.Y, b.Y)
end

-- Everything about a placed prop that the placement tool can be told to wear again. Reading
-- the COLOUR off a part rather than unpacking the NatureColor attribute is deliberate: the
-- attribute is the packed number the save format wants, the part already holds the Color3,
-- and an unpainted prop must hand back nil so its template's own colours survive (a tree is
-- not one colour, and forcing one would turn it brown).
function NatureSelection.lookOf(m: Model): Nature.Look?
	local key = m:GetAttribute("NatureKey")
	if typeof(key) ~= "string" then return nil end
	local color: Color3? = nil
	if typeof(m:GetAttribute("NatureColor")) == "number" then
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") then color = (d :: BasePart).Color; break end
		end
	end
	local mat = m:GetAttribute("NatureMaterial")
	local stretch = m:GetAttribute("NatureStretch")
	local fade = m:GetAttribute("NatureTransparency")
	return {
		key = key :: string,
		scale = tonumber(m:GetAttribute("NatureScale")) or 1,
		color = color,
		material = if typeof(mat) == "number" then mat :: number else nil,
		-- false, not nil: nil means "leave the template's own collision alone", and a copy of
		-- a prop the player switched off has to arrive switched off.
		collide = if m:GetAttribute("NatureNoCollide") == true then false else nil,
		stretch = if typeof(stretch) == "Vector3" then stretch :: Vector3 else nil,
		transparency = if typeof(fade) == "number" then fade :: number else nil,
	}
end

-- The selection as ONE placeable: every prop offset from the set's CENTRE, so putting it
-- back down keeps the arrangement. Four blocks built into a wall come back as the wall.
--
-- Height rides as each prop's own NatureYOffset -- its height above the ground it sits on --
-- and never as an absolute Y. Put the stamp on a hill and it climbs the hill; hand over an
-- absolute Y and half of it is underground.
-- Also hands back the CENTRE it measured from, because "put it back exactly where it was"
-- is a real request (cut into precise) and re-deriving that centre elsewhere would be a
-- second copy of this averaging.
function NatureSelection.stampOf(models: { Model }): ({ Nature.StampItem }, Vector3)
	local out: { Nature.StampItem } = {}
	local n, sx, sz = 0, 0, 0
	for _, m in models do
		if typeof(m:GetAttribute("NatureKey")) == "string" then
			local p = m:GetPivot().Position
			sx += p.X
			sz += p.Z
			n += 1
		end
	end
	if n == 0 then return out, Vector3.zero end
	-- Averaged over the props BEFORE any item is built: a model with no key in the list would
	-- otherwise drag the centre off and shift the whole arrangement.
	local cx, cz = sx / n, sz / n
	for _, m in models do
		if #out >= STAMP_MAX then break end
		local look = NatureSelection.lookOf(m)
		if not look then continue end
		local pv = m:GetPivot()
		local rx, ry, rz = pv:ToOrientation()
		local yOff = m:GetAttribute("NatureYOffset")
		table.insert(out, {
			key = look.key,
			scale = look.scale,
			color = look.color,
			material = look.material,
			collide = look.collide,
			stretch = look.stretch,
			transparency = look.transparency,
			dx = pv.Position.X - cx,
			dz = pv.Position.Z - cz,
			yaw = ry,
			pitch = rx,
			roll = rz,
			yOffset = if typeof(yOff) == "number" then yOff :: number else 0,
		})
	end
	return out, Vector3.new(cx, 0, cz)
end

-- == State ====================================================================
local _sel: { Model } = {}
local _selSet: { [Model]: boolean } = {}
local _groupOf: { [Model]: number } = {}
local _nextGroup = 0
local _boxFrom: Vector2? = nil
local _bottomBar: any = nil
local _started = false
local _beganConn: RBXScriptConnection? = nil
local _changedConn: RBXScriptConnection? = nil
local _endedConn: RBXScriptConnection? = nil

local _gui: ScreenGui? = nil
local _bar: Frame? = nil
local _title: TextLabel? = nil
local _count: TextLabel? = nil
local _hint: TextLabel? = nil
local _groupBtn: Button.Button? = nil
local _marquee: Frame? = nil
-- Look controls, shown ONLY for a selection of one. Editing the colour of a whole box
-- selection would be one dropdown quietly repainting sixty props, and there is no undo.
local _lookRow: Frame? = nil
local _matDrop: Dropdown.Dropdown? = nil
local _swatch: Frame? = nil
local _built = false

local build: () -> ()
local refresh: () -> ()

local function natureFolder(): Instance?
	return CursorRay.cityFolder("Nature")
end

-- == Selection ================================================================
local function addModel(m: Model)
	if _selSet[m] or #_sel >= CAP then return end
	_selSet[m] = true
	table.insert(_sel, m)
end

local function removeModel(m: Model)
	if not _selSet[m] then return end
	_selSet[m] = nil
	local i = table.find(_sel, m)
	if i then table.remove(_sel, i) end
end

-- A group is only ever as big as its LIVE members. Props are destroyed by the server, and a
-- table of dead instance references would keep selecting things that are not there.
local function groupMembers(id: number): { Model }
	local out: { Model } = {}
	for m, g in _groupOf do
		if g == id then
			if m.Parent then table.insert(out, m) else _groupOf[m] = nil end
		end
	end
	return out
end

-- Clicking ONE member of a group takes the whole group, whichever member was clicked --
-- which is the entire point of grouping.
local function expand(m: Model): { Model }
	local id = _groupOf[m]
	if not id then return { m } end
	local members = groupMembers(id)
	return if #members > 0 then members else { m }
end

local function toggleModel(m: Model)
	local members = expand(m)
	if _selSet[m] then
		for _, g in members do removeModel(g) end
	else
		for _, g in members do addModel(g) end
	end
end

-- Let go of the handles if they are sitting on something in this selection. DETACH, never
-- discard: a pasted copy is already part of the city, and discard is how precise mode
-- bulldozes a master it never committed.
local function releaseGizmo()
	local held = NatureGizmo.current()
	if held and _selSet[held] then NatureGizmo.detach() end
end

local function clearSelection()
	if #_sel == 0 then return end
	releaseGizmo()
	table.clear(_sel)
	table.clear(_selSet)
	refresh()
end

-- Every selected prop shares one group: the button says UNGROUP rather than GROUP.
local function selectionGrouped(): boolean
	local id: number? = nil
	for _, m in _sel do
		local g = _groupOf[m]
		if not g then return false end
		if id and g ~= id then return false end
		id = g
	end
	return id ~= nil
end

local function groupSelection()
	if #_sel < 2 then return end
	_nextGroup += 1
	-- Flattens whatever was grouped before: grouping a selection means THIS selection is the
	-- group, not that it nests inside the old ones.
	for _, m in _sel do _groupOf[m] = _nextGroup end
	SoundFX.play("Click")
	refresh()
end

local function ungroupSelection()
	local any = false
	for _, m in _sel do
		if _groupOf[m] then
			_groupOf[m] = nil
			any = true
		end
	end
	if any then
		SoundFX.play("Click")
		refresh()
	end
end

-- == Server round trips =======================================================
-- Chunked at the server cap with a pause past its cooldown, exactly as the bulldozer batches
-- its own removals. pcall'd because a spawned task that errors takes nothing else with it
-- only if somebody is holding the boundary.
local function sendChunks(remote: RemoteEvent, list: { any }, label: string)
	if #list == 0 then return end
	local copy = table.clone(list)
	task.spawn(function()
		local ok, err = pcall(function()
			local chunk: { any } = {}
			for _, item in copy do
				chunk[#chunk + 1] = item
				if #chunk >= CHUNK then
					remote:FireServer(chunk)
					chunk = {}
					task.wait(CHUNK_PAUSE)
				end
			end
			if #chunk > 0 then remote:FireServer(chunk) end
		end)
		if not ok then warn("[NatureSelection] " .. label .. " failed: " .. tostring(err)) end
	end)
end

local function deleteSelection()
	if #_sel == 0 then return end
	local live: { Model } = {}
	for _, m in _sel do
		if m.Parent then table.insert(live, m) end
	end
	releaseGizmo()
	sendChunks(Net.RequestRemoveNature, live, "remove")
	SoundFX.play("Bulldoze")
	table.clear(_sel)
	table.clear(_selSet)
	refresh()
end

-- COPY and CUT both mean ONE thing: put this exact prop back on the cursor, in the menu it
-- came from, ready to place again. Copy leaves the original standing; cut takes it down --
-- and the server refunds it, so cutting a thing and putting it somewhere else costs a
-- rounding error rather than the price of a new one.
--
-- There is no clipboard and no paste. "Let me place that again" was the only thing anybody
-- ever wanted from one, and the placement tool already does that better than a paste could.
--
-- ponytail: ONE asset can be armed, so a multi-selection copies the FIRST prop's look. Cut
-- still takes the whole selection down -- the part a player would notice either way.
-- Cut REMOVES, and the only way back is to build it again -- so anything past a single prop
-- asks first. COPY never asks: it takes nothing away. Built lazily and reused; the callback
-- is replaced each time, because whoever opened it last is whose answer this is.
local _confirm: Modal.Modal? = nil
local _confirmBody: TextLabel? = nil
local _confirmGo: Button.Button? = nil
local _confirmYes: (() -> ())? = nil

local function buildConfirm()
	if _confirm then return end
	local m = Modal.new({
		size = UDim2.fromOffset(360, 172),
		title = "Remove multiple items",
		name = "NatureCutConfirm",
		onClose = function() _confirmYes = nil end,
	})
	_confirm = m

	local body = Instance.new("TextLabel")
	body.BackgroundTransparency = 1
	body.Position = UDim2.fromOffset(0, 6)
	body.Size = UDim2.new(1, 0, 0, 44)
	body.TextWrapped = true
	body.TextXAlignment = Enum.TextXAlignment.Left
	body.TextYAlignment = Enum.TextYAlignment.Top
	body.TextColor3 = Theme.Color.TextSecondary
	body.TextSize = Theme.TextSize.SM
	body.FontFace = Theme.Font.Label
	body.Text = ""
	body.Parent = m.Content
	_confirmBody = body

	local cancel = Button.new({
		text = "Cancel",
		parent = m.Content,
		size = UDim2.fromOffset(110, 32),
		onClick = function()
			_confirmYes = nil
			m:Hide()
		end,
	})
	cancel.Instance.AnchorPoint = Vector2.new(1, 1)
	cancel.Instance.Position = UDim2.new(1, -120, 1, 0)

	_confirmGo = Button.new({
		text = "Remove",
		parent = m.Content,
		variant = "Danger",
		size = UDim2.fromOffset(112, 32),
		onClick = function()
			local yes = _confirmYes
			_confirmYes = nil
			m:Hide()
			if yes then yes() end
		end,
	})
	;(_confirmGo :: Button.Button).Instance.AnchorPoint = Vector2.new(1, 1)
	;(_confirmGo :: Button.Button).Instance.Position = UDim2.new(1, 0, 1, 0)
end

local function confirmRemove(n: number, onYes: () -> ())
	-- One prop is not worth a dialog: it is one click to put back and asking every time is
	-- how a confirmation becomes something people learn to dismiss without reading.
	if n <= 1 then onYes(); return end
	buildConfirm()
	local m = _confirm
	if not m then onYes(); return end
	_confirmYes = onYes
	if _confirmBody then
		(_confirmBody :: TextLabel).Text =
			string.format("Are you sure you want to remove %d items? They are refunded, and you keep them on the cursor to place again.", n)
	end
	if _confirmGo then
		(_confirmGo :: Button.Button).Instance.Text = string.upper(string.format("Remove %d items", n))
	end
	m:Show()
end

local function armFrom(models: { Model }): ({ Nature.StampItem }, Vector3)
	local stamp, centre = NatureSelection.stampOf(models)
	if #stamp == 0 then return stamp, centre end
	-- The DOCK first, then the stamp. Opening the dock runs a tab change, and a tab change
	-- onto a non-shelf tab switches the placement tool off -- which would clear what we had
	-- just armed. Lazily required: that panel pulls in half the UI and this module starts
	-- before it. The first prop decides which shelf comes up; a stamp mixing shelves has to
	-- pick one, and the one you cut first is the honest guess.
	local ok, panel = pcall(function()
		return require(script.Parent:WaitForChild("TerrainPanelController"))
	end)
	if ok and panel then panel.ShowNatureAsset(stamp[1].key) end
	Nature.armStamp(stamp)
	return stamp, centre
end

local function armFromSelection(): ({ Nature.StampItem }, Vector3)
	return armFrom(_sel)
end

-- The Picker's whole job: one placed prop's exact twin -- look, stretch, tilt and all -- on
-- the cursor, with its shelf open. The same path as a copy of a selection of one.
function NatureSelection.pickUp(m: Model): boolean
	local stamp = armFrom({ m })
	if #stamp == 0 then return false end
	SoundFX.play("Click")
	return true
end

-- The remove has to land before the put-back, or the server judges the new props against the
-- old ones still standing there and refuses every one of them for overlapping itself. Past
-- NaturePlaceService's per-player call cooldown, with room to spare.
local REPLACE_DELAY = 0.2

-- The SHIFT variants add precise mode on top. On a CUT that also means putting the set
-- straight back where it was taken from, with the handles on it -- "pick this up and keep
-- working on it", not "carry it somewhere else first". On a COPY there is nothing to put
-- back, so you simply hold it and the first click gives you the handles.
local function takeCopy(alsoCut: boolean, precise: boolean)
	local n = #_sel
	local function go()
		local stamp, centre = armFromSelection()
		if #stamp == 0 then return end
		if alsoCut then deleteSelection() else clearSelection() end
		if precise then Nature.setPrecise(true) end
		if precise and alsoCut then
			task.delay(REPLACE_DELAY, function()
				local okPlace, err = pcall(function() Nature.placeStamp(centre) end)
				if not okPlace then warn("[NatureSelection] put-back failed: " .. tostring(err)) end
			end)
		end
		SoundFX.play("Click")
	end
	if alsoCut then confirmRemove(n, go) else go() end
end

-- == UI =======================================================================
local function makeBtn(parent: Instance, label: string, width: number, order: number, fn: () -> ()): Button.Button
	return Button.new({
		text = label,
		parent = parent,
		compact = true,
		layoutOrder = order,
		size = UDim2.fromOffset(width, 26),
		onClick = fn,
	})
end

build = function()
	if _built then return end
	-- Never a bare WaitForChild on PlayerGui: one of those hung the gizmo's claim() forever.
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui", 10)
	if not playerGui then
		warn("[NatureSelection] no PlayerGui")
		return
	end
	_built = true

	local gui = Instance.new("ScreenGui")
	gui.Name = "NatureSelection"
	gui.ResetOnSpawn = false
	-- IgnoreGuiInset so the capture box is drawn in the SAME space the mouse location and
	-- WorldToViewportPoint speak; an inset-relative frame sits ~36 px off the drag.
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = Theme.Layer.Overlay
	gui.Parent = playerGui
	_gui = gui

	local marquee = Instance.new("Frame")
	marquee.Name = "CaptureBox"
	marquee.BackgroundColor3 = Theme.Color.Accent
	marquee.BackgroundTransparency = 0.82
	marquee.BorderSizePixel = 0
	marquee.Visible = false
	marquee.Parent = gui
	local mStroke = Instance.new("UIStroke")
	mStroke.Color = Theme.Color.Accent
	mStroke.Thickness = Theme.StrokeWidth.Thin
	mStroke.Parent = marquee
	_marquee = marquee

	local bar = Instance.new("Frame")
	bar.Name = "ActionBar"
	bar.AnchorPoint = Vector2.new(0.5, 1)
	-- Clear of the build dock: this bar is about what is SELECTED, and it must not sit on top
	-- of the tools that are how you put more of it down.
	bar.Position = UDim2.new(0.5, 0, 1, -110)
	bar.Size = UDim2.fromOffset(BAR_W, 112)
	bar.AutomaticSize = Enum.AutomaticSize.Y
	bar.BackgroundColor3 = Theme.Color.Bg
	bar.BackgroundTransparency = 0.08
	bar.BorderSizePixel = 0
	bar.Visible = false
	bar.Parent = gui
	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(0, Theme.Radius.Panel)
	barCorner.Parent = bar
	local barPad = Instance.new("UIPadding")
	barPad.PaddingTop = UDim.new(0, Theme.Pad.LG)
	barPad.PaddingBottom = UDim.new(0, Theme.Pad.LG)
	barPad.PaddingLeft = UDim.new(0, Theme.Pad.LG)
	barPad.PaddingRight = UDim.new(0, Theme.Pad.LG)
	barPad.Parent = bar
	_bar = bar

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0, 20)
	title.Text = ""
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Theme.Color.TextPrimary
	title.TextSize = Theme.TextSize.MD
	title.FontFace = Theme.Font.Header
	title.Parent = bar
	_title = title

	local count = Instance.new("TextLabel")
	count.BackgroundTransparency = 1
	count.Position = UDim2.fromOffset(0, 22)
	count.Size = UDim2.new(1, 0, 0, 16)
	count.Text = ""
	count.TextXAlignment = Enum.TextXAlignment.Left
	count.TextColor3 = Theme.Color.TextSecondary
	count.TextSize = Theme.TextSize.XS
	count.FontFace = Theme.Font.Label
	count.Parent = bar
	_count = count

	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Position = UDim2.fromOffset(0, 44)
	row.Size = UDim2.new(1, 0, 0, 26)
	row.Parent = bar
	local rowList = Instance.new("UIListLayout")
	rowList.FillDirection = Enum.FillDirection.Horizontal
	rowList.SortOrder = Enum.SortOrder.LayoutOrder
	rowList.Padding = UDim.new(0, Theme.Pad.SM)
	rowList.Parent = row

	makeBtn(row, "Delete", 62, 1, deleteSelection)
	makeBtn(row, "Cut", 52, 2, function() takeCopy(true, false) end)
	makeBtn(row, "Copy", 56, 3, function() takeCopy(false, false) end)
	_groupBtn = makeBtn(row, "Group", 72, 4, function()
		if selectionGrouped() then ungroupSelection() else groupSelection() end
	end)
	makeBtn(row, "Close", 62, 5, clearSelection)

	-- ONE prop selected: its colour and material, edited in place. NatureGizmo.applyTo sends
	-- the same item the handles would, so the server sees one contract either way.
	local look = Instance.new("Frame")
	look.Name = "Look"
	look.BackgroundTransparency = 1
	look.Position = UDim2.fromOffset(0, 74)
	look.Size = UDim2.new(1, 0, 0, 26)
	look.Visible = false
	look.Parent = bar
	_lookRow = look

	local swBtn = Instance.new("TextButton")
	swBtn.Size = UDim2.fromOffset(28, 26)
	swBtn.BackgroundTransparency = 1
	swBtn.Text = ""
	swBtn.Parent = look
	local sw = Instance.new("Frame")
	sw.Size = UDim2.fromOffset(24, 24)
	sw.Position = UDim2.fromOffset(2, 1)
	sw.BackgroundColor3 = Theme.Color.TextPrimary
	sw.BorderSizePixel = 0
	sw.Parent = swBtn
	local swc = Instance.new("UICorner")
	swc.CornerRadius = UDim.new(1, 0)
	swc.Parent = sw
	local sws = Instance.new("UIStroke")
	sws.Color = Theme.Color.StrokeSoft
	sws.Thickness = Theme.StrokeWidth.Thin
	sws.Parent = sw
	_swatch = sw
	swBtn.Activated:Connect(function()
		local m = _sel[1]
		if not (m and #_sel == 1) then return end
		ColorPanel.open(function(c: Color3)
			-- Re-read the selection inside the callback: the menu stays open across clicks, and
			-- the prop it was opened for may be gone or swapped by the time a colour is picked.
			local live = _sel[1]
			if live and #_sel == 1 and live.Parent then
				NatureGizmo.applyTo(live, Net.RequestMoveNature, { color = c })
				refresh()
			end
		end)
	end)

	local matOptions: { Dropdown.Option } = { { label = "Default", value = 0 } }
	for i, name in MaterialCatalog.order do
		table.insert(matOptions, { label = name, value = i })
	end
	_matDrop = Dropdown.new({
		parent = look,
		options = matOptions,
		value = 0,
		width = 150,
		onChange = function(value: any)
			local m = _sel[1]
			if not (m and #_sel == 1 and m.Parent) then return end
			-- 0 is "the template's own", which the server has no way back to inside a session.
			if typeof(value) == "number" and value > 0 then
				NatureGizmo.applyTo(m, Net.RequestMoveNature, { material = value })
			end
			refresh()
		end,
	})
	;(_matDrop :: Dropdown.Dropdown).Instance.AnchorPoint = Vector2.new(0, 0.5)
	;(_matDrop :: Dropdown.Dropdown).Instance.Position = UDim2.new(0, 36, 0.5, 0)

	-- The shortcuts, read back off the binds rather than written out, so a rebind is visible
	-- here instead of quietly making this line a lie.
	local hint = Instance.new("TextLabel")
	hint.BackgroundTransparency = 1
	hint.Position = UDim2.fromOffset(0, 76)
	hint.Size = UDim2.new(1, 0, 0, 14)
	hint.Text = ""
	hint.TextXAlignment = Enum.TextXAlignment.Left
	hint.TextColor3 = Theme.Color.TextDisabled
	hint.TextSize = Theme.TextSize.XS
	hint.FontFace = Theme.Font.Label
	hint.TextTruncate = Enum.TextTruncate.AtEnd
	hint.Parent = bar
	_hint = hint
end

local function showMarquee(a: Vector2, b: Vector2)
	build()
	local f = _marquee
	if not f then return end
	local x0, y0, x1, y1 = NatureSelection.rectOf(a, b)
	f.Position = UDim2.fromOffset(x0, y0)
	f.Size = UDim2.fromOffset(x1 - x0, y1 - y0)
	f.Visible = true
end

local function hideMarquee()
	if _marquee then (_marquee :: Frame).Visible = false end
end

local function updateBar()
	if #_sel == 0 then
		if _bar then (_bar :: Frame).Visible = false end
		return
	end
	build()
	local bar = _bar
	if not bar then return end
	bar.Visible = true
	local title = _title
	if title then
		local key = _sel[1]:GetAttribute("NatureKey")
		local entry = if typeof(key) == "string" then NatureCatalog.get(key :: string) else nil
		title.Text = if #_sel > 1
			then "Multiple items"
			elseif entry then entry.name
			else "Item"
	end
	local count = _count
	if count then
		local grouped = if selectionGrouped() then "  \u{00B7}  grouped" else ""
		count.Text = string.format("Selected %d item%s.%s",
			#_sel, if #_sel == 1 then "" else "s", grouped)
	end
	local groupBtn = _groupBtn
	if groupBtn then
		groupBtn.Instance.Text = if selectionGrouped() then "UNGROUP" else "GROUP"
	end
	-- One prop: its look is editable. Several: it is not -- one dropdown quietly repainting
	-- sixty props, with no undo, is not a feature.
	local single = #_sel == 1
	local lookRow = _lookRow
	if lookRow then lookRow.Visible = single end
	local hint = _hint
	if hint then hint.Position = UDim2.fromOffset(0, if single then 104 else 76) end
	if single then
		local m = _sel[1]
		local look = NatureSelection.lookOf(m)
		if _swatch then
			local c = if look then look.color else nil
			;(_swatch :: Frame).BackgroundColor3 = c or Theme.Color.TextPrimary
			-- Dimmed when the prop still wears its template's own colours: the swatch still
			-- says what a click would paint, it just is not what is on the prop.
			;(_swatch :: Frame).BackgroundTransparency = if c then 0 else 0.55
		end
		if _matDrop then
			(_matDrop :: Dropdown.Dropdown):Set(if look and look.material then look.material else 0)
		end
	end
	if hint then
		hint.Text = table.concat({
			"Copy " .. Settings.bindLabel(Settings.getBind("Copy")),
			"Cut " .. Settings.bindLabel(Settings.getBind("Cut")),
			"Group " .. Settings.bindLabel(Settings.getBind("Group")),
		}, "   \u{00B7}   ") .. "   \u{00B7}   +SHIFT for precise"
	end
end

-- ONE outline around the whole selection, not one per prop. Several props side by side each
-- carrying their own silhouette draw a seam everywhere they touch, which reads as "these are
-- separate things" exactly when you have just said they are not.
--
-- Roblox cannot union Highlights across models without a shared parent, and reparenting a
-- planted prop is out of the question -- the save and the delete both key off it being a
-- child of the Nature folder, so it would quietly stop being saveable and deletable. The
-- union is drawn as a BOX instead: one invisible part covering everything, with the one
-- Highlight on that.
local _boxPart: BasePart? = nil
local _boxHl: Highlight? = nil

local function hideUnionBox()
	if _boxHl then (_boxHl :: Highlight).Enabled = false end
end

local function showUnionBox()
	if #_sel == 0 then hideUnionBox(); return end
	local lo: Vector3? = nil
	local hi: Vector3? = nil
	for _, m in _sel do
		local cf, size = m:GetBoundingBox()
		-- Axis-aligned off each prop's own box centre. A turned prop's box is itself turned,
		-- so this is an approximation -- and the right one: the union of several props has no
		-- single orientation to be exact about.
		local half = size * 0.5
		local a, b = cf.Position - half, cf.Position + half
		lo = if lo then Vector3.new(math.min(lo.X, a.X), math.min(lo.Y, a.Y), math.min(lo.Z, a.Z)) else a
		hi = if hi then Vector3.new(math.max(hi.X, b.X), math.max(hi.Y, b.Y), math.max(hi.Z, b.Z)) else b
	end
	if not (lo and hi) then hideUnionBox(); return end
	local part = _boxPart
	if not (part and part.Parent) then
		local p = Instance.new("Part")
		p.Name = "SelectionUnion"
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Transparency = 1
		-- The UI scratch root, which CursorRay ignores wholesale -- so the box a selection
		-- draws can never be the thing the next click picks.
		p.Parent = UiScratch.folder("NatureSelection")
		_boxPart = p
		part = p
	end
	local p = part :: BasePart
	p.Size = (hi :: Vector3) - (lo :: Vector3) + Vector3.one * 0.05
	p.CFrame = CFrame.new(((lo :: Vector3) + (hi :: Vector3)) * 0.5)
	local hl = _boxHl
	if not (hl and hl.Parent) then
		local h = Instance.new("Highlight")
		h.Name = "SelectionUnion"
		h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		h.FillTransparency = 0.88
		h.OutlineTransparency = 0
		h.OutlineColor = Color3.fromRGB(255, 255, 255)
		h.FillColor = Color3.fromRGB(255, 255, 255)
		h.Parent = p
		_boxHl = h
		hl = h
	end
	;(hl :: Highlight).Adornee = p
	;(hl :: Highlight).Enabled = true
end

refresh = function()
	-- Props die under the player -- a bulldoze elsewhere, a city reload -- so the list is
	-- swept every time it is drawn rather than hooked per model.
	for i = #_sel, 1, -1 do
		local m = _sel[i]
		if not m.Parent then
			_selSet[m] = nil
			table.remove(_sel, i)
		end
	end
	-- ONE prop gets a true silhouette; SEVERAL get one box around the lot. The per-model
	-- pool is what draws a seam between every pair of touching props.
	if #_sel == 1 then
		DeleteHover.ShowBuildingSelection(_sel, SELECT_COLOR)
		hideUnionBox()
	else
		DeleteHover.ClearBuildingSelection()
		showUnionBox()
	end
	updateBar()
end

-- == Input ====================================================================
-- Every Kit.Modal parks a full-screen scrim under PlayerGui.UIModalOverlay, so one visible
-- child there means a window owns the screen and the city behind it is not clickable.
local function modalOpen(): boolean
	local pgui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local overlay = if pgui then pgui:FindFirstChild("UIModalOverlay") else nil
	if not overlay then return false end
	for _, child in overlay:GetChildren() do
		if child:IsA("GuiObject") and (child :: GuiObject).Visible then return true end
	end
	return false
end

local function modifierHeld(): boolean
	return Settings.isActionDown("SelectBox") or Settings.isActionDown("SelectAdd")
end

-- Idle means no tool owns the cursor: no build section open, no bulldozer, no modal. That is
-- when a plain click is a selection. While a tool IS up the modifier is what says "this click
-- is mine" -- otherwise the Nature tab could never plant anything again.
local function pickable(): boolean
	if modalOpen() then return false end
	-- The handles want this click.
	if NatureGizmo.isBusy() then return false end
	-- A PLACEMENT TOOL owns the cursor. Its dock is not a bottom-bar "section" -- Build and
	-- Terrain open their page directly -- so the check below never saw it, and a click that
	-- planted a block also selected whatever it landed near: a card lit in the shelf and an
	-- action bar open over it at the same time.
	if Nature.isEnabled() then return modifierHeld() end
	local bb = _bottomBar
	if bb then
		if bb.IsBulldozeActive and bb.IsBulldozeActive() then return false end
		if bb.IsPaintActive and bb.IsPaintActive() then return false end
		if bb.GetActiveSection and bb.GetActiveSection() ~= nil then return modifierHeld() end
	end
	return true
end

local function propAt(input: InputObject?): Model?
	local folder = natureFolder()
	if not folder then return nil end
	-- What the ray actually enters first; the flat nearest-pivot test only as a fallback for
	-- props too small to hit (a pebble).
	local hit = CursorRay.modelUnderRay(folder, input)
	if hit then return hit end
	local p = CursorRay.ground({ input = input })
	if not p then return nil end
	return CursorRay.nearestPivot(folder, p, PICK_PX, PICK_MIN, PICK_MAX, PICK_MAX_DY)
end

local function finishBox()
	local from = _boxFrom
	_boxFrom = nil
	hideMarquee()
	if not from then return end
	local x0, y0, x1, y1 = NatureSelection.rectOf(from, CursorRay.position())
	if (x1 - x0) < BOX_MIN_PX and (y1 - y0) < BOX_MIN_PX then
		-- Barely moved: that was a modified CLICK, not a box.
		local m = propAt(nil)
		if m then toggleModel(m) end
		refresh()
		return
	end
	local folder = natureFolder()
	local cam = Workspace.CurrentCamera
	if not (folder and cam) then return end
	local camera = cam :: Camera
	for _, child in (folder :: Instance):GetChildren() do
		if #_sel >= CAP then break end
		if child:IsA("Model") and not _selSet[child] then
			local sp, onScreen = camera:WorldToViewportPoint((child :: Model):GetPivot().Position)
			-- onScreen already rejects anything behind the camera; the rectangle does the rest.
			if onScreen and sp.X >= x0 and sp.X <= x1 and sp.Y >= y0 and sp.Y <= y1 then
				addModel(child :: Model)
			end
		end
	end
	SoundFX.play("Click")
	refresh()
end

local function onBegan(input: InputObject, gameProcessed: boolean)
	if gameProcessed or modalOpen() then return end

	-- The bulldozer paints ITS selection through the same outline pool, so a selection that
	-- survives into it goes invisible -- and an invisible selection is one Delete away from a
	-- surprise. Drop it at the door.
	local bb = _bottomBar
	if bb and bb.IsBulldozeActive and bb.IsBulldozeActive() then
		clearSelection()
		return
	end

	if #_sel > 0 then
		if Settings.pressed("Back", input) then clearSelection(); return end
		if Settings.pressed("Delete", input) then deleteSelection(); return end
		-- pressed() is modifier-EXCLUSIVE, so CONTROL + C never also fires the CONTROL + SHIFT
		-- pair. The shifted ones are read first anyway, so the code reads in the order a player
		-- would describe it.
		if Settings.pressed("CutPrecise", input) then takeCopy(true, true); return end
		if Settings.pressed("CopyPrecise", input) then takeCopy(false, true); return end
		if Settings.pressed("Cut", input) then takeCopy(true, false); return end
		if Settings.pressed("Copy", input) then takeCopy(false, false); return end
		if Settings.pressed("Ungroup", input) then ungroupSelection(); return end
		if Settings.pressed("Group", input) then groupSelection(); return end
	end

	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
	if not pickable() then return end

	if Settings.isActionDown("SelectBox") then
		local at = CursorRay.position(input)
		_boxFrom = at
		showMarquee(at, at)
		return
	end

	local m = propAt(input)
	if Settings.isActionDown("SelectAdd") then
		if m then
			toggleModel(m)
			refresh()
		end
		return
	end

	-- A plain click REPLACES the selection, and a plain click on nothing clears it.
	table.clear(_sel)
	table.clear(_selSet)
	if m then
		for _, g in expand(m) do addModel(g) end
		SoundFX.play("Click")
	end
	refresh()
end

-- == Public ===================================================================
function NatureSelection.current(): { Model }
	return table.clone(_sel)
end

function NatureSelection.clear()
	clearSelection()
end

function NatureSelection.Start()
	if _started then return end
	_started = true

	-- Lazy and isolated, exactly as BuildingInfoController takes it: this module is started
	-- after the bar, and a bar that failed to build must not take selection down with it.
	local ok, bb = pcall(function()
		return require(script.Parent:WaitForChild("BottomBarController"))
	end)
	_bottomBar = if ok then bb else nil

	_beganConn = UserInputService.InputBegan:Connect(onBegan)

	_changedConn = UserInputService.InputChanged:Connect(function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
		local from = _boxFrom
		if from then showMarquee(from, CursorRay.position(input)) end
	end)

	_endedConn = UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 and _boxFrom then finishBox() end
	end)
end

function NatureSelection.Cleanup()
	if _beganConn then _beganConn:Disconnect(); _beganConn = nil end
	if _changedConn then _changedConn:Disconnect(); _changedConn = nil end
	if _endedConn then _endedConn:Disconnect(); _endedConn = nil end
	_started = false
	clearSelection()
	hideMarquee()
end

return NatureSelection
