--!strict
-- THE TILE VIEW: the 16x16 land grid the map is bought with. Cities: Skylines 2's map tile
-- purchase screen.
--
-- Opening it flies the camera up to see the whole map and remembers where it was; closing
-- flies it back. In between the camera is the player's: fly, pan and zoom anywhere, at
-- speeds scaled to the altitude (FreeCamController overview mode). Unowned land is frosted white, owned land is clear. Left-drag paints a box of
-- tiles into the selection, right-drag takes a box back out, a click toggles one tile. Once
-- something is selected a one-row strip above the tool rail totals it -- permits, price,
-- monthly upkeep -- and buys it in one request; with nothing selected there is no panel.
--
-- The server is authoritative (TerritoryService): this draws the snapshot it pushes,
-- quotes prices with the same TerritoryGrid maths the server charges with, and forwards
-- the purchase. Every gate is re-checked there.
--
-- ONE PLANE. Every plate sits at the same height, just above the highest ground sampled
-- anywhere on the map, so none cuts into a hill and the grid reads as one sheet. Picking is
-- a ray-plane intersection with that height -- no colliders, and it cannot miss.
--
-- INPUT goes through a full-screen transparent button under the HUD, so while the view is
-- open a click on the world lands here and nowhere else (every other click handler sees it
-- as processed), and the tool rail above it still works.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local Net = require(ReplicatedStorage:WaitForChild("Networker"))
local TerritoryGrid = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("TerritoryGrid"))

local scripts = script.Parent.Parent
local core = scripts:WaitForChild("Core")
local CursorRay = require(core:WaitForChild("CursorRay"))
local FreeCamController = require(core:WaitForChild("FreeCamController"))
local SoundFX = require(core:WaitForChild("SoundFX"))
local uiFolder = scripts:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local Format = require(uiFolder:WaitForChild("Format"))
local Glass = require(uiFolder:WaitForChild("Kit"):WaitForChild("Glass"))
local Icons = require(uiFolder:WaitForChild("Icons"))
local Button = require(uiFolder:WaitForChild("Kit"):WaitForChild("Button"))
local ToolRail = require(script.Parent:WaitForChild("ToolRail"))

local TerritoryController = {}

local N = TerritoryGrid.TILES_PER_AXIS
local TILE = TerritoryGrid.TILE_STUDS
local HALF = N * TILE / 2

local FOLDER_NAME = "_TerritoryView"
local INSET = 5          -- gap between plates: the gap IS the grid line
local LIFT = 6           -- plane height above the map's highest ground
local PLATE_THICKNESS = 0.4
local SAMPLES = 6        -- per axis, per tile, for the height envelope and land/water split
local SEA_Y = 0

-- Overview framing: the player's own heading, tipped down, far enough back that the whole
-- map fits a 70-degree view.
local OVERVIEW_PITCH = -62
local OVERVIEW_DIST = 7600
local GLIDE_SECONDS = 0.7

-- All white; only the transparency says what a tile is. Owned is nearly clear so the city
-- shows through, land for sale is frosted, and the selection is close to solid.
local COL_TILE = Color3.fromRGB(255, 255, 255)
local COL_UNSELECT = Color3.fromRGB(235, 120, 110)
local OWNED_T, LOCKED_T, HOVER_T, SELECTED_T = 0.93, 0.62, 0.42, 0.18

type TileInfo = { top: number, land: number } -- land = 0..1 share of samples above the sea

local _enabled = false
local _owned: { [number]: boolean } = {}
local _ownedCount = 0
local _allowance = TerritoryGrid.START_TILES
local _sandbox = false
local _treasury = 0
local _selected: { [number]: boolean } = {}
local _selCount = 0
local _hoverId: number? = nil
local _drag: { from: number, to: number, add: boolean }? = nil
local _info: { [number]: TileInfo } = {}
local _plates: { [number]: BasePart } = {}
local _folder: Folder? = nil
local _planeY = SEA_Y
local _savedCam: any = nil
-- The warm haze that dresses the city up close turns the whole map to sky from the overview
-- height, so it is thinned while the view is open and put back exactly as it was on close.
local _savedAir: { atmo: Atmosphere?, density: number, haze: number, fogEnd: number }? = nil
local AIR_DENSITY, AIR_HAZE, AIR_FOG_END = 0.05, 0, 100000

local function clearAir(on: boolean)
	local Lighting = game:GetService("Lighting")
	if on and not _savedAir then
		local atmo = Lighting:FindFirstChildOfClass("Atmosphere")
		_savedAir = { atmo = atmo, density = if atmo then atmo.Density else 0, haze = if atmo then atmo.Haze else 0, fogEnd = Lighting.FogEnd }
		if atmo then
			atmo.Density = math.min(atmo.Density, AIR_DENSITY)
			atmo.Haze = AIR_HAZE
		end
		Lighting.FogEnd = AIR_FOG_END
	elseif not on and _savedAir then
		local saved = _savedAir
		_savedAir = nil
		if saved.atmo and saved.atmo.Parent then
			saved.atmo.Density = saved.density
			saved.atmo.Haze = saved.haze
		end
		Lighting.FogEnd = saved.fogEnd
	end
end
local _busy = false
local _conns: { RBXScriptConnection } = {}

local ui = {} :: { catcher: TextButton?, panel: Frame?, facts: TextLabel?, status: TextLabel?, buy: Button.Button? }

-- == Terrain envelope ===========================================================

local function sampleTile(id: number): TileInfo
	local minX, minZ = TerritoryGrid.boundsOf(id)
	local top, landHits = SEA_Y, 0
	for i = 0, SAMPLES - 1 do
		for j = 0, SAMPLES - 1 do
			local x = minX + (i + 0.5) / SAMPLES * TILE
			local z = minZ + (j + 0.5) / SAMPLES * TILE
			local y = CursorRay.terrainY(x, z) or SEA_Y
			top = math.max(top, y)
			if y > SEA_Y then landHits += 1 end
		end
	end
	-- The edges too: a ridge running along the border is inside the plate's footprint.
	for _, c in { { minX, minZ }, { minX + TILE, minZ }, { minX, minZ + TILE }, { minX + TILE, minZ + TILE } } do
		top = math.max(top, CursorRay.terrainY(c[1], c[2]) or SEA_Y)
	end
	return { top = top, land = landHits / (SAMPLES * SAMPLES) }
end

-- == Plates =====================================================================

local function newFolder(name: string): Folder
	local old = Workspace:FindFirstChild(name)
	if old then old:Destroy() end
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = Workspace
	return f
end

local function buildPlates()
	local folder = newFolder(FOLDER_NAME)
	_folder = folder

	local top = SEA_Y
	for id = 1, TerritoryGrid.TOTAL do
		local info = _info[id]
		if not info then
			info = sampleTile(id)
			_info[id] = info
		end
		top = math.max(top, info.top)
	end
	_planeY = top + LIFT

	for id = 1, TerritoryGrid.TOTAL do
		local cx, cz = TerritoryGrid.centerOf(id)

		local p = Instance.new("Part")
		p.Name = "Tile" .. id
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.SmoothPlastic
		p.Size = Vector3.new(TILE - INSET, PLATE_THICKNESS, TILE - INSET)
		p.Color = COL_TILE
		p.CFrame = CFrame.new(cx, _planeY, cz)
		p.Parent = folder
		_plates[id] = p
	end
end

local function clearPlates()
	table.clear(_plates)
	if _folder then
		_folder:Destroy()
		_folder = nil
	end
end

-- The live box drag, as a set, or nil.
local function dragSet(): ({ [number]: boolean }?, boolean)
	local d = _drag
	if not d then return nil, false end
	local set: { [number]: boolean } = {}
	for _, id in TerritoryGrid.idsInRect(d.from, d.to) do
		if not _owned[id] then set[id] = true end
	end
	return set, d.add
end

local function paint()
	if not _enabled then return end
	local box, adding = dragSet()
	for id, p in _plates do
		local color, t = COL_TILE, LOCKED_T
		if _owned[id] then
			t = OWNED_T
		elseif box and box[id] then
			color, t = if adding then COL_TILE else COL_UNSELECT, SELECTED_T
		elseif _selected[id] then
			t = SELECTED_T
		elseif id == _hoverId then
			t = HOVER_T
		end
		p.Color = color
		p.Transparency = t
	end
end

-- == Picking ====================================================================

local function pick(input: InputObject?): number?
	local r = CursorRay.ray(input)
	if not r or r.Direction.Y >= 0 then return nil end
	local t = (_planeY - r.Origin.Y) / r.Direction.Y
	if t < 0 then return nil end
	local p = r.Origin + r.Direction * t
	if math.abs(p.X) > HALF or math.abs(p.Z) > HALF then return nil end
	return TerritoryGrid.idAt(p.X, p.Z)
end

-- == Panel ======================================================================

local function selectedIds(): { number }
	local out: { number } = {}
	for id in _selected do table.insert(out, id) end
	table.sort(out)
	return out
end

local function refreshPanel()
	local panel, facts, status, buy = ui.panel, ui.facts, ui.status, ui.buy
	if not (panel and facts and status and buy) then return end
	panel.Visible = _enabled and not _sandbox and _selCount > 0
	if not panel.Visible then return end

	local landSum = 0
	for id in _selected do landSum += (_info[id] and _info[id].land or 1) end
	local price = TerritoryGrid.priceForBatch(_ownedCount, _selCount)
	local room = _allowance - _ownedCount
	facts.Text = ("<b>%d</b> tile%s  \u{00B7}  %d%% land  \u{00B7}  +%s/mo  \u{00B7}  permits %d/%d"):format(
		_selCount, if _selCount == 1 then "" else "s", math.floor(landSum / _selCount * 100 + 0.5),
		Format.money(_selCount * TerritoryGrid.UPKEEP_PER_TILE), _ownedCount + _selCount, _allowance)

	local reason: string? = nil
	if room <= 0 then
		reason = "No permits left. Reach the next milestone."
	elseif _selCount > room then
		reason = ("Only %d permit%s left"):format(room, if room == 1 then "" else "s")
	elseif price > _treasury then
		reason = "Not enough money"
	end
	status.Text = reason or ""
	status.Visible = reason ~= nil
	buy:SetEnabled(reason == nil and not _busy)
	buy.Instance.Text = if _busy then "BUYING" else "BUY  " .. Format.money(price)
end

local function setSelection(ids: { number }, on: boolean)
	for _, id in ids do
		if _owned[id] then continue end
		if on and not _selected[id] then
			_selected[id] = true
			_selCount += 1
		elseif not on and _selected[id] then
			_selected[id] = nil
			_selCount -= 1
		end
	end
end

local function clearSelection()
	table.clear(_selected)
	_selCount = 0
end

local function purchase()
	if _busy or _selCount == 0 or _sandbox then return end
	_busy = true
	refreshPanel()
	local ids = selectedIds()
	task.spawn(function()
		local ok, success, payload = pcall(function()
			return Net.RequestBuyTile:InvokeServer(ids)
		end)
		_busy = false
		local bought = ok and success == true
		if bought then clearSelection() end
		SoundFX.play(if bought then "Success" else "Error")
		paint()
		refreshPanel()
		local status = ui.status
		if not bought and status then
			status.Text = if ok and typeof(payload) == "string" then payload else "Could not buy that land."
			status.Visible = true
		end
	end)
end

-- One row above the tool rail, the same slot the bulldoze options use: what the selection
-- is, why it can't be bought (only when it can't), the price on the button, and an X that
-- drops the selection.
local function buildPanel(gui: ScreenGui)
	local panel = Instance.new("Frame")
	panel.Name = "TilePurchasePanel"
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.Position = UDim2.new(0.5, 0, 1, -ToolRail.bottomInset())
	panel.Size = UDim2.fromOffset(0, 44)
	panel.AutomaticSize = Enum.AutomaticSize.X
	panel.Visible = false
	panel.Active = true
	panel.ZIndex = Theme.Z.Flyout
	Glass.apply(panel, Theme.Radius.LG)
	panel.Parent = gui
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 16)
	pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = panel
	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.VerticalAlignment = Enum.VerticalAlignment.Center
	row.SortOrder = Enum.SortOrder.LayoutOrder
	row.Padding = UDim.new(0, 12)
	row.Parent = panel

	local function label(order: number, color: Color3): TextLabel
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.AutomaticSize = Enum.AutomaticSize.X
		l.Size = UDim2.fromOffset(0, 22)
		l.FontFace = Theme.Font.Label
		l.TextSize = Theme.TextSize.SM
		l.TextColor3 = color
		l.RichText = true
		l.LayoutOrder = order
		l.Parent = panel
		return l
	end
	ui.facts = label(1, Theme.Color.TextPrimary)
	ui.status = label(2, Theme.Color.Danger)

	local buy = Button.new({ text = "BUY", parent = panel, layoutOrder = 3, onClick = purchase })
	buy:SetSelected(true)
	ui.buy = buy

	local close = Instance.new("ImageButton")
	close.Size = UDim2.fromOffset(28, 28)
	close.BackgroundTransparency = 1
	close.Image = Icons.Close.image
	close.ImageColor3 = Theme.Color.TextSecondary
	close.ScaleType = Enum.ScaleType.Fit
	close.LayoutOrder = 4
	close.Parent = panel
	local closePad = Instance.new("UIPadding")
	closePad.PaddingTop, closePad.PaddingBottom = UDim.new(0, 7), UDim.new(0, 7)
	closePad.PaddingLeft, closePad.PaddingRight = UDim.new(0, 7), UDim.new(0, 7)
	closePad.Parent = close
	close.MouseEnter:Connect(function() close.ImageColor3 = Theme.Color.TextPrimary end)
	close.MouseLeave:Connect(function() close.ImageColor3 = Theme.Color.TextSecondary end)
	close.Activated:Connect(function()
		clearSelection()
		paint()
		refreshPanel()
	end)
	ui.panel = panel
end

-- == Border ====================================================================
-- Outside the tile view the city's edge is a dashed white line on the ground, drawn
-- wherever an owned tile meets one that is not -- so a player building knows where the
-- land stops. Dashes are laid on the terrain (or the sea) end to end, so they drape over
-- hills instead of cutting through them.

local BORDER_FOLDER = "_TerritoryBorder"
local DASH_LEN, DASH_GAP, DASH_W, DASH_LIFT = 20, 14, 2.5, 1.5
local _border: Folder? = nil

local function borderY(x: number, z: number): number
	return math.max(CursorRay.terrainY(x, z) or SEA_Y, SEA_Y) + DASH_LIFT
end

local function dashLine(folder: Folder, x0: number, z0: number, x1: number, z1: number)
	local len = math.sqrt((x1 - x0) ^ 2 + (z1 - z0) ^ 2)
	local dx, dz = (x1 - x0) / len, (z1 - z0) / len
	local t = DASH_GAP / 2
	while t < len do
		local t1 = math.min(t + DASH_LEN, len)
		local ax, az = x0 + dx * t, z0 + dz * t
		local bx, bz = x0 + dx * t1, z0 + dz * t1
		local a = Vector3.new(ax, borderY(ax, az), az)
		local b = Vector3.new(bx, borderY(bx, bz), bz)
		local p = Instance.new("Part")
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.SmoothPlastic
		p.Color = Color3.new(1, 1, 1)
		p.Transparency = 0.15
		p.Size = Vector3.new(DASH_W, 0.4, (b - a).Magnitude)
		p.CFrame = CFrame.lookAt((a + b) / 2, b)
		p.Parent = folder
		t = t1 + DASH_GAP
	end
end

local function drawBorder()
	if _border then
		_border:Destroy()
		_border = nil
	end
	if _sandbox or _enabled or _ownedCount == 0 or _ownedCount >= TerritoryGrid.TOTAL then return end
	-- The ground is solved from the heightmap, which exists only once a city has loaded.
	if not CursorRay.terrainY(0, 0) then
		task.delay(2, drawBorder)
		return
	end
	local folder = newFolder(BORDER_FOLDER)
	_border = folder
	local function unowned(ix: number, iz: number): boolean
		return ix >= 0 and ix < N and iz >= 0 and iz < N and not _owned[TerritoryGrid.idOf(ix, iz)]
	end
	for id in _owned do
		local ix, iz = TerritoryGrid.fromId(id)
		local minX, minZ, maxX, maxZ = TerritoryGrid.boundsOf(id)
		if unowned(ix - 1, iz) then dashLine(folder, minX, minZ, minX, maxZ) end
		if unowned(ix + 1, iz) then dashLine(folder, maxX, minZ, maxX, maxZ) end
		if unowned(ix, iz - 1) then dashLine(folder, minX, minZ, maxX, minZ) end
		if unowned(ix, iz + 1) then dashLine(folder, minX, maxZ, maxX, maxZ) end
	end
end

-- Full-screen click sink. Its own ScreenGui BELOW the HUD, so the rail and this panel stay
-- on top of it and everything else in the world stays underneath.
local function buildCatcher()
	local sg = Instance.new("ScreenGui")
	sg.Name = "TileViewInput"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = Theme.Layer.Tool
	sg.Enabled = false
	sg.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	local b = Instance.new("TextButton")
	b.Name = "Catcher"
	b.Size = UDim2.fromScale(1, 1)
	b.BackgroundTransparency = 1
	b.AutoButtonColor = false
	b.Text = ""
	b.Parent = sg
	b.InputBegan:Connect(function(input: InputObject)
		if not _enabled or _sandbox then return end
		local t = input.UserInputType
		local add = t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch
		if not add and t ~= Enum.UserInputType.MouseButton2 then return end
		local id = pick(input)
		if not id then return end
		_drag = { from = id, to = id, add = add }
		paint()
	end)
	ui.catcher = b
end

local function endDrag()
	local d = _drag
	if not d then return end
	_drag = nil
	if d.from == d.to then
		-- A click, not a box: left toggles the one tile, right drops it.
		setSelection({ d.from }, d.add and not _selected[d.from])
	else
		setSelection(TerritoryGrid.idsInRect(d.from, d.to), d.add)
	end
	SoundFX.play("Click")
	paint()
	refreshPanel()
end

-- == Camera =====================================================================

local function overviewState(): any
	local cur = FreeCamController.getCameraState()
	local yaw = math.rad(cur.yaw)
	local pitch = math.rad(OVERVIEW_PITCH)
	local look = Vector3.new(-math.cos(pitch) * math.sin(yaw), math.sin(pitch), -math.cos(pitch) * math.cos(yaw))
	return { pos = -look * OVERVIEW_DIST, yaw = cur.yaw, pitch = OVERVIEW_PITCH }
end

-- == Public =====================================================================

function TerritoryController.isEnabled(): boolean
	return _enabled
end

function TerritoryController.setEnabled(on: boolean)
	if _enabled == on then return end
	_enabled = on
	local catcher = ui.catcher
	if on then
		-- Saved on EVERY open, so closing always lands where this opening started, however
		-- far the player flew or zoomed while the view was up.
		_savedCam = FreeCamController.getCameraState()
		FreeCamController.glideTo(overviewState(), GLIDE_SECONDS)
		FreeCamController.setOverviewMode(true)
		clearAir(true)
		buildPlates()
		paint()
		SoundFX.play("Open")
	else
		_hoverId = nil
		_drag = nil
		clearSelection()
		clearPlates()
		FreeCamController.setOverviewMode(false)
		clearAir(false)
		if _savedCam then
			FreeCamController.glideTo(_savedCam, GLIDE_SECONDS)
			_savedCam = nil
		end
		SoundFX.play("Close")
	end
	if catcher then (catcher.Parent :: ScreenGui).Enabled = on end
	drawBorder()
	refreshPanel()
end

function TerritoryController.Toggle()
	TerritoryController.setEnabled(not _enabled)
end

function TerritoryController.Init(gui: ScreenGui)
	buildPanel(gui)
	buildCatcher()
end

function TerritoryController.Bind()
	table.insert(_conns, Net.SyncTerritory.OnClientEvent:Connect(function(snap: any)
		if typeof(snap) ~= "table" then return end
		local owned: { [number]: boolean } = {}
		local n = 0
		if typeof(snap.owned) == "table" then
			for _, id in snap.owned do
				if TerritoryGrid.isValidId(id) then
					owned[tonumber(id) :: number] = true
					n += 1
				end
			end
		end
		_owned = owned
		_ownedCount = n
		_allowance = tonumber(snap.allowance) or TerritoryGrid.START_TILES
		_sandbox = snap.sandbox == true
		-- Land bought (here or by a co-builder) drops out of the selection.
		for id in _selected do
			if owned[id] then
				_selected[id] = nil
				_selCount -= 1
			end
		end
		paint()
		refreshPanel()
		drawBorder()
	end))

	table.insert(_conns, Net.SyncEconomy.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) ~= "table" then return end
		_treasury = tonumber(payload.money) or _treasury
		if _enabled then refreshPanel() end
	end))

	table.insert(_conns, UserInputService.InputEnded:Connect(function(input: InputObject)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.MouseButton2 or t == Enum.UserInputType.Touch then
			endDrag()
		end
	end))

	-- Hover and the live drag box are the only per-frame work: one raycast against the
	-- pick boxes, and a repaint only when the tile under the cursor actually changes.
	table.insert(_conns, RunService.RenderStepped:Connect(function()
		if not _enabled then return end
		local id = pick()
		local d = _drag
		if d and id and id ~= d.to then
			d.to = id
			paint()
		elseif id ~= _hoverId then
			_hoverId = id
			paint()
		end
	end))
end

function TerritoryController.Cleanup()
	for _, c in _conns do c:Disconnect() end
	table.clear(_conns)
	TerritoryController.setEnabled(false)
	if _border then
		_border:Destroy()
		_border = nil
	end
end

return TerritoryController
