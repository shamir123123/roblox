--!strict
-- ColorPanel
-- The colour menu: a HEXAGON HONEYCOMB you pick from (white at the centre, pastels, then
-- full colour, then deep shades at the rim -- hue runs round it), a row of greys, a Custom
-- mode for mixing your own, an opacity slider, and five slots to keep favourites.
--
-- Rebuilt 2026-09-22. The first cut used round cells on an overlapping lattice because
-- Montserrat has no hexagon glyph; they overlapped each other and read as a smear. A hexagon
-- here is THREE rectangles of (side*sqrt3 x side) rotated 0/60/120 about one centre -- their
-- union is exactly a regular hexagon -- so it needs no font and no uploaded art.
--
-- It opens ABOVE whatever button opened it (`opts.anchor`) instead of at a fixed spot, which
-- used to drop it straight over the toolbar and the cards.

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local uiFolder = script.Parent.Parent:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local kit = uiFolder:WaitForChild("Kit")
local Button = require(kit:WaitForChild("Button"))

local ColorPanel = {}

export type Options = {
	anchor: GuiObject?,
	transparency: number?,
	onTransparency: ((t: number) -> ())?,
}

local SQRT3 = math.sqrt(3)
local WIDTH = 318
local SIDE = 11.5            -- hexagon side, px
local GAP = 1.6              -- px between neighbouring cells
local RINGS = 6              -- 1 + 3*6*7 = 127 cells
local GREYS = 13
local SAVED_SLOTS = 6
local SV_SIZE = 190
local HUE_H = 16
local MAX_FADE = 0.9

local _gui: ScreenGui? = nil
local _root: Frame? = nil
local _built = false
local _mode = "Palette" -- "Palette" | "Custom"
local _open = false
local _color = Color3.fromRGB(232, 236, 240)
local _h, _s, _v = _color:ToHSV()
local _fade = 0
local _onPick: ((c: Color3) -> ())? = nil
local _opts: Options = {}

local _saved: { Color3 } = {}
local _savedCells: { { rim: Frame, face: Frame } } = {}
local _modeBtns: { [string]: Button.Button } = {}
local _paletteFrame: Frame? = nil
local _customFrame: Frame? = nil
local _fadeRow: Frame? = nil
local _fadeFill: Frame? = nil
local _fadeKnob: Frame? = nil
local _fadeLabel: TextLabel? = nil
-- Every palette cell with the colour it stands for, so the picked one can be ringed.
local _cells: { { color: Color3, rim: Frame } } = {}
local _svFill: Frame? = nil
local _svCursor: Frame? = nil
local _hueCursor: Frame? = nil
local _hexBox: TextBox? = nil
local _preview: Frame? = nil

local function corner(inst: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = inst
end

-- == Colour space ===============================================================
-- Honeycomb colour at axial (q, r): hue from the angle round the centre (red at the top),
-- then rings outward go white -> pastel -> full -> deep.
function ColorPanel.cellColor(q: number, r: number): Color3
	local ring = math.max(math.abs(q), math.abs(r), math.abs(q + r))
	if ring == 0 then return Color3.new(1, 1, 1) end
	local x = SQRT3 * (q + r * 0.5)
	local y = 1.5 * r
	local hue = (math.atan2(x, -y) / (2 * math.pi)) % 1
	local t = ring / RINGS
	local sat = math.min(1, t * 1.35)
	local val = if t <= 0.72 then 1 else 1 - (t - 0.72) * 1.4
	return Color3.fromHSV(hue, sat, val)
end

-- == Picking ==================================================================
local function setColor(c: Color3, fromPicker: boolean)
	_color = c
	if not fromPicker then _h, _s, _v = c:ToHSV() end
	if _onPick then _onPick(c) end
	ColorPanel.sync()
end

function ColorPanel.current(): Color3 return _color end

local function setFade(t: number)
	_fade = math.clamp(math.round(t * 20) / 20, 0, MAX_FADE)
	if _opts.onTransparency then _opts.onTransparency(_fade) end
	ColorPanel.sync()
end

-- == Hexagon ==================================================================
local function hexagon(parent: Instance, side: number, color: Color3, z: number): Frame
	local holder = Instance.new("Frame")
	holder.Name = "Hex"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Size = UDim2.fromOffset(side * SQRT3, side * 2)
	holder.ZIndex = z
	for i = 0, 2 do
		local r = Instance.new("Frame")
		r.AnchorPoint = Vector2.new(0.5, 0.5)
		r.Position = UDim2.fromScale(0.5, 0.5)
		r.Size = UDim2.fromOffset(side * SQRT3, side)
		r.Rotation = i * 60
		r.BackgroundColor3 = color
		r.BorderSizePixel = 0
		r.ZIndex = z
		r.Parent = holder
	end
	holder.Parent = parent
	return holder
end

local function tint(hex: Frame, c: Color3, transparency: number?)
	for _, r in hex:GetChildren() do
		if r:IsA("Frame") then
			r.BackgroundColor3 = c
			if transparency then r.BackgroundTransparency = transparency end
		end
	end
end

-- One cell: a white rim hexagon (shown when picked/hovered), the colour face, and a plain
-- rectangular button over the middle. Rotated frames do not hit-test as hexagons, so the
-- button is the cell's inner box -- neighbours never overlap it.
local function cell(parent: Instance, at: Vector2, c: Color3, onClick: () -> ()): (Frame, Frame)
	local rim = hexagon(parent, SIDE + 2.2, Color3.new(1, 1, 1), 2)
	rim.Position = UDim2.fromOffset(at.X, at.Y)
	rim.Visible = false
	local face = hexagon(parent, SIDE, c, 3)
	face.Position = UDim2.fromOffset(at.X, at.Y)
	local btn = Instance.new("TextButton")
	btn.Text = ""
	btn.BackgroundTransparency = 1
	btn.AnchorPoint = Vector2.new(0.5, 0.5)
	btn.Position = UDim2.fromOffset(at.X, at.Y)
	btn.Size = UDim2.fromOffset(SIDE * SQRT3, SIDE * 1.5)
	btn.ZIndex = 4
	btn.Parent = parent
	btn.MouseEnter:Connect(function()
		if not rim.Visible then rim.Visible = true; tint(rim, Color3.new(1, 1, 1), 0.5) end
	end)
	btn.MouseLeave:Connect(function() ColorPanel.sync() end)
	btn.Activated:Connect(onClick)
	return rim, face
end

local function sameColor(a: Color3, b: Color3): boolean
	-- Packed 8-bit, not floats: a swatch built from HSV and a colour round-tripped through
	-- the hex box are never bit-identical.
	return math.round(a.R * 255) == math.round(b.R * 255)
		and math.round(a.G * 255) == math.round(b.G * 255)
		and math.round(a.B * 255) == math.round(b.B * 255)
end

-- == Custom mode ==============================================================
local HUE_STOPS = {}
for i = 0, 6 do
	table.insert(HUE_STOPS, ColorSequenceKeypoint.new(i / 6, Color3.fromHSV(i / 6 % 1, 1, 1)))
end

local function draggable(target: GuiObject, onMove: (x: number, y: number) -> ())
	local dragging = false
	local function report(input: InputObject)
		local abs, size = target.AbsolutePosition, target.AbsoluteSize
		-- This gui ignores the topbar inset; a mouse InputObject.Position does not, so it
		-- would land ~58 px low on the colour square. GetMouseLocation is in our space.
		local p = if input.UserInputType == Enum.UserInputType.Touch
			then Vector2.new(input.Position.X, input.Position.Y)
			else UserInputService:GetMouseLocation()
		onMove(
			math.clamp((p.X - abs.X) / math.max(size.X, 1), 0, 1),
			math.clamp((p.Y - abs.Y) / math.max(size.Y, 1), 0, 1)
		)
	end
	target.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then return end
		dragging = true
		report(input)
	end)
	target.InputChanged:Connect(function(input: InputObject)
		if not dragging then return end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement
			and input.UserInputType ~= Enum.UserInputType.Touch then return end
		report(input)
	end)
	target.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then dragging = false end
	end)
	-- A drag that leaves the control still has to end, or the next hover keeps painting.
	target.MouseLeave:Connect(function() dragging = false end)
end

local function cursorDot(parent: Instance, size: number): Frame
	local d = Instance.new("Frame")
	d.AnchorPoint = Vector2.new(0.5, 0.5)
	d.Size = UDim2.fromOffset(size, size)
	d.BackgroundColor3 = Color3.new(1, 1, 1)
	d.BorderSizePixel = 0
	d.ZIndex = 5
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(1, 0); c.Parent = d
	local st = Instance.new("UIStroke")
	st.Color = Color3.new(0, 0, 0)
	st.Thickness = 1
	st.Transparency = 0.4
	st.Parent = d
	d.Parent = parent
	return d
end

local function applyHex(text: string)
	local hex = string.match(text, "^%s*#?(%x%x%x%x%x%x)%s*$")
	if not hex then ColorPanel.sync(); return end
	local n = tonumber(hex, 16) :: number
	setColor(Color3.fromRGB(n // 65536, (n // 256) % 256, n % 256), false)
end

local function buildCustom(parent: Instance)
	local holder = Instance.new("Frame")
	holder.Name = "Custom"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(1, 0, 0, SV_SIZE + HUE_H + 40)
	holder.Visible = false
	holder.Parent = parent
	_customFrame = holder

	local sv = Instance.new("Frame")
	sv.Size = UDim2.new(1, 0, 0, SV_SIZE)
	sv.BackgroundColor3 = Color3.fromHSV(_h, 1, 1)
	sv.BorderSizePixel = 0
	sv.Parent = holder
	corner(sv, Theme.Radius.SM)
	_svFill = sv

	-- White across, black down. Two children, because one gradient cannot fade to white on
	-- one axis and to black on the other.
	local white = Instance.new("Frame")
	white.Size = UDim2.fromScale(1, 1)
	white.BackgroundColor3 = Color3.new(1, 1, 1)
	white.BorderSizePixel = 0
	white.Parent = sv
	corner(white, Theme.Radius.SM)
	local wg = Instance.new("UIGradient")
	wg.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	wg.Parent = white

	local black = Instance.new("Frame")
	black.Size = UDim2.fromScale(1, 1)
	black.BackgroundColor3 = Color3.new(0, 0, 0)
	black.BorderSizePixel = 0
	black.ZIndex = 2
	black.Parent = sv
	corner(black, Theme.Radius.SM)
	local bg = Instance.new("UIGradient")
	bg.Rotation = 90
	bg.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0) })
	bg.Parent = black

	_svCursor = cursorDot(sv, 11)
	draggable(sv, function(x, y)
		_s, _v = x, 1 - y
		setColor(Color3.fromHSV(_h, _s, _v), true)
	end)

	local hue = Instance.new("Frame")
	hue.Size = UDim2.new(1, 0, 0, HUE_H)
	hue.Position = UDim2.new(0, 0, 0, SV_SIZE + 8)
	hue.BackgroundColor3 = Color3.new(1, 1, 1)
	hue.BorderSizePixel = 0
	hue.Parent = holder
	corner(hue, Theme.Radius.SM)
	local hg = Instance.new("UIGradient")
	hg.Color = ColorSequence.new(HUE_STOPS)
	hg.Parent = hue
	_hueCursor = cursorDot(hue, HUE_H - 3)
	draggable(hue, function(x, _)
		_h = x
		setColor(Color3.fromHSV(_h, _s, _v), true)
	end)

	local box = Instance.new("TextBox")
	box.Size = UDim2.fromOffset(96, 26)
	box.Position = UDim2.new(0, 0, 0, SV_SIZE + HUE_H + 14)
	box.BackgroundColor3 = Theme.Color.BgRaised
	box.TextColor3 = Theme.Color.TextPrimary
	box.TextSize = Theme.TextSize.SM
	box.FontFace = Theme.Font.Label
	box.BorderSizePixel = 0
	box.ClearTextOnFocus = false
	box.Parent = holder
	corner(box, Theme.Radius.SM)
	_hexBox = box
	box.FocusLost:Connect(function() applyHex(box.Text) end)
end

-- == Palette ==================================================================
local PITCH = SIDE + GAP / SQRT3 -- side of the lattice the cells sit on
local COMB_W = (2 * RINGS + 1) * PITCH * SQRT3
local COMB_H = (2 * RINGS) * PITCH * 1.5 + SIDE * 2
local GREY_H = SIDE * 2 + 6

local function buildPalette(parent: Instance)
	local holder = Instance.new("Frame")
	holder.Name = "Palette"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(1, 0, 0, COMB_H + GREY_H + 6)
	holder.Parent = parent
	_paletteFrame = holder

	local cx = WIDTH * 0.5 - Theme.Pad.LG
	local cy = COMB_H * 0.5
	for q = -RINGS, RINGS do
		for r = -RINGS, RINGS do
			if math.abs(q + r) > RINGS then continue end
			local c = ColorPanel.cellColor(q, r)
			local at = Vector2.new(cx + PITCH * SQRT3 * (q + r * 0.5), cy + PITCH * 1.5 * r)
			local rim = cell(holder, at, c, function() setColor(c, false) end)
			table.insert(_cells, { color = c, rim = rim })
		end
	end

	-- Greys: one straight row of hexes under the comb, white to black.
	local step = PITCH * SQRT3
	local x0 = cx - step * (GREYS - 1) * 0.5
	for i = 0, GREYS - 1 do
		local g = 1 - i / (GREYS - 1)
		local c = Color3.new(g, g, g)
		local rim = cell(holder, Vector2.new(x0 + step * i, COMB_H + 6 + SIDE), c, function() setColor(c, false) end)
		table.insert(_cells, { color = c, rim = rim })
	end
end

local function buildFade(parent: Instance, order: number)
	local row = Instance.new("Frame")
	row.Name = "Opacity"
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 26)
	row.LayoutOrder = order
	row.Parent = parent
	_fadeRow = row

	local cap = Instance.new("TextLabel")
	cap.BackgroundTransparency = 1
	cap.Size = UDim2.fromOffset(96, 26)
	cap.TextXAlignment = Enum.TextXAlignment.Left
	cap.TextColor3 = Theme.Color.TextSecondary
	cap.TextSize = Theme.TextSize.XS
	cap.FontFace = Theme.Font.Bold
	cap.Parent = row
	_fadeLabel = cap

	-- Checkerboard-free "see-through" track: light at the solid end, fading out.
	local track = Instance.new("Frame")
	track.AnchorPoint = Vector2.new(1, 0.5)
	track.Position = UDim2.new(1, -6, 0.5, 0)
	track.Size = UDim2.new(1, -110, 0, 8)
	track.BackgroundColor3 = Theme.Color.BgRaised
	track.BorderSizePixel = 0
	track.Parent = row
	corner(track, 4)
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Theme.Color.Accent
	fill.BorderSizePixel = 0
	fill.Parent = track
	corner(fill, 4)
	_fadeFill = fill
	local knob = cursorDot(track, 14)
	knob.Position = UDim2.fromScale(0, 0.5)
	_fadeKnob = knob
	-- A taller invisible grip, so the 8 px track is not an 8 px target.
	local grip = Instance.new("Frame")
	grip.BackgroundTransparency = 1
	grip.AnchorPoint = Vector2.new(0, 0.5)
	grip.Position = UDim2.fromScale(0, 0.5)
	grip.Size = UDim2.new(1, 0, 0, 24)
	grip.ZIndex = 6
	grip.Active = true
	grip.Parent = track
	draggable(grip, function(x, _) setFade(x * MAX_FADE) end)
end

local function buildSaved(parent: Instance, order: number)
	local row = Instance.new("Frame")
	row.Name = "Saved"
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, SIDE * 2 + 4)
	row.LayoutOrder = order
	row.Parent = parent

	local cap = Instance.new("TextLabel")
	cap.BackgroundTransparency = 1
	cap.Size = UDim2.new(0, 60, 1, 0)
	cap.Text = "SAVED"
	cap.TextXAlignment = Enum.TextXAlignment.Left
	cap.TextColor3 = Theme.Color.TextSecondary
	cap.TextSize = Theme.TextSize.XS
	cap.FontFace = Theme.Font.Bold
	cap.Parent = row

	local step = PITCH * SQRT3 + 4
	for i = 1, SAVED_SLOTS do
		local at = Vector2.new(64 + (i - 1) * step, SIDE + 2)
		local rim, face = cell(row, at, Theme.Color.BgRaised, function()
			-- An empty slot TAKES the current colour; a full one GIVES it back. One control and
			-- no mode to be in -- which is the only way six little hexagons stay obvious.
			if _saved[i] then setColor(_saved[i], false) else _saved[i] = _color end
			ColorPanel.sync()
		end)
		_savedCells[i] = { rim = rim, face = face }
	end

	local clear = Button.new({
		text = "Clear",
		parent = row,
		compact = true,
		size = UDim2.fromOffset(52, 24),
		onClick = function()
			for i = SAVED_SLOTS, 1, -1 do
				if _saved[i] then _saved[i] = nil; break end
			end
			ColorPanel.sync()
		end,
	})
	clear.Instance.AnchorPoint = Vector2.new(1, 0.5)
	clear.Instance.Position = UDim2.new(1, 0, 0.5, 0)
end

-- == Build ====================================================================
local function build()
	if _built then return end
	local player = Players.LocalPlayer
	local gui = player and player:FindFirstChild("PlayerGui")
	if not gui then return end -- never a bare WaitForChild; sync runs again
	_built = true

	local screen = Instance.new("ScreenGui")
	screen.Name = "ColorPanel"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	-- Above the HUD: at Tool+1 the dock drew OVER the menu (the chips showed through it).
	screen.DisplayOrder = Theme.Layer.HUD + 10
	screen.Enabled = false
	screen.Parent = gui
	_gui = screen

	local rootFrame = Instance.new("Frame")
	rootFrame.AnchorPoint = Vector2.new(0.5, 1)
	rootFrame.Position = UDim2.new(0.5, 0, 1, -200)
	rootFrame.Size = UDim2.fromOffset(WIDTH, 0)
	rootFrame.AutomaticSize = Enum.AutomaticSize.Y
	rootFrame.BackgroundColor3 = Theme.Color.Bg
	rootFrame.BackgroundTransparency = 0.04
	rootFrame.BorderSizePixel = 0
	rootFrame.Active = true -- clicks on the panel never reach the world under it
	rootFrame.Parent = screen
	corner(rootFrame, Theme.Radius.LG)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Color.StrokeSoft
	stroke.Transparency = 0.4
	stroke.Parent = rootFrame
	_root = rootFrame

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, Theme.Pad.MD)
	pad.PaddingBottom = UDim.new(0, Theme.Pad.MD)
	pad.PaddingLeft = UDim.new(0, Theme.Pad.LG)
	pad.PaddingRight = UDim.new(0, Theme.Pad.LG)
	pad.Parent = rootFrame

	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, Theme.Pad.SM)
	list.Parent = rootFrame

	-- header: live swatch, title, the two mode chips, close
	local head = Instance.new("Frame")
	head.BackgroundTransparency = 1
	head.Size = UDim2.new(1, 0, 0, 30)
	head.LayoutOrder = 1
	head.Parent = rootFrame

	local prev = Instance.new("Frame")
	prev.Size = UDim2.fromOffset(24, 24)
	prev.Position = UDim2.fromOffset(0, 3)
	prev.BackgroundColor3 = _color
	prev.BorderSizePixel = 0
	prev.Parent = head
	corner(prev, 12)
	local ps = Instance.new("UIStroke")
	ps.Color = Theme.Color.Stroke
	ps.Thickness = Theme.StrokeWidth.Thin
	ps.Parent = prev
	_preview = prev

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.fromOffset(80, 30)
	title.Position = UDim2.fromOffset(32, 0)
	title.Text = "Colour"
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Theme.Color.TextPrimary
	title.TextSize = Theme.TextSize.MD
	title.FontFace = Theme.Font.Header
	title.Parent = head

	local x = 0
	for _, key in { "Custom", "Palette" } do
		local b = Button.new({
			text = key,
			parent = head,
			compact = true,
			size = UDim2.fromOffset(62, 24),
			onClick = function() _mode = key; ColorPanel.sync() end,
		})
		b.Instance.AnchorPoint = Vector2.new(1, 0.5)
		b.Instance.Position = UDim2.new(1, -(30 + x), 0.5, 0)
		_modeBtns[key] = b
		x += 66
	end

	local close = Button.new({
		-- A plain X, not U+2715: Montserrat has no such glyph and Roblox does not fall back.
		text = "X",
		parent = head,
		compact = true,
		size = UDim2.fromOffset(26, 24),
		onClick = function() ColorPanel.close() end,
	})
	close.Instance.AnchorPoint = Vector2.new(1, 0.5)
	close.Instance.Position = UDim2.new(1, 0, 0.5, 0)

	local body = Instance.new("Frame")
	body.BackgroundTransparency = 1
	body.Size = UDim2.new(1, 0, 0, COMB_H + GREY_H + 6)
	body.LayoutOrder = 2
	body.Parent = rootFrame
	buildPalette(body)
	buildCustom(body)

	buildFade(rootFrame, 3)
	buildSaved(rootFrame, 4)
end

-- Above the anchor, centred on it, clamped on screen. The anchor lives in another ScreenGui
-- that may or may not ignore the topbar inset, so its position is converted into ours.
local function place()
	local root, gui = _root, _gui
	local anchor = _opts.anchor
	if not (root and gui) then return end
	if not (anchor and anchor.Parent) then
		root.AnchorPoint = Vector2.new(0.5, 1)
		root.Position = UDim2.new(0.5, 0, 1, -200)
		return
	end
	local a = anchor :: GuiObject
	local sg = a:FindFirstAncestorWhichIsA("ScreenGui")
	local inset = if sg and not sg.IgnoreGuiInset then GuiService:GetGuiInset().Y else 0
	local view = gui.AbsoluteSize
	local x = a.AbsolutePosition.X + a.AbsoluteSize.X * 0.5
	local y = a.AbsolutePosition.Y + inset - 10
	local half = WIDTH * 0.5 + 8
	root.AnchorPoint = Vector2.new(0.5, 1)
	root.Position = UDim2.fromOffset(math.clamp(x, half, math.max(half, view.X - half)), y)
end

-- == Public ===================================================================
function ColorPanel.sync()
	if not _open and not _built then return end
	build()
	local gui = _gui
	if not gui then return end
	gui.Enabled = _open
	if not _open then return end

	for key, btn in _modeBtns do btn:SetSelected(key == _mode) end
	if _paletteFrame then (_paletteFrame :: Frame).Visible = _mode == "Palette" end
	if _customFrame then (_customFrame :: Frame).Visible = _mode == "Custom" end
	-- The two modes are different heights, and the body is what the list layout measures.
	local container = _paletteFrame and (_paletteFrame :: Frame).Parent
	if container and container:IsA("GuiObject") then
		container.Size = UDim2.new(1, 0, 0,
			if _mode == "Palette" then COMB_H + GREY_H + 6 else SV_SIZE + HUE_H + 46)
	end

	if _preview then (_preview :: Frame).BackgroundColor3 = _color end
	for _, c in _cells do
		local on = sameColor(c.color, _color)
		c.rim.Visible = on
		if on then tint(c.rim, Color3.new(1, 1, 1), 0) end
	end
	for i, sc in _savedCells do
		local c = _saved[i]
		-- An empty slot reads as an empty slot: flat panel colour, half see-through.
		tint(sc.face, c or Theme.Color.BgRaised, if c then 0 else 0.45)
		sc.rim.Visible = c ~= nil and sameColor(c, _color)
		if sc.rim.Visible then tint(sc.rim, Color3.new(1, 1, 1), 0) end
	end

	if _fadeRow then (_fadeRow :: Frame).Visible = _opts.onTransparency ~= nil end
	if _fadeLabel then (_fadeLabel :: TextLabel).Text = ("OPACITY  %d%%"):format(math.round((1 - _fade) * 100)) end
	local frac = _fade / MAX_FADE
	if _fadeFill then (_fadeFill :: Frame).Size = UDim2.fromScale(frac, 1) end
	if _fadeKnob then (_fadeKnob :: Frame).Position = UDim2.fromScale(frac, 0.5) end

	if _svFill then (_svFill :: Frame).BackgroundColor3 = Color3.fromHSV(_h, 1, 1) end
	if _svCursor then (_svCursor :: Frame).Position = UDim2.fromScale(_s, 1 - _v) end
	if _hueCursor then (_hueCursor :: Frame).Position = UDim2.new(_h, 0, 0.5, 0) end
	if _hexBox and not (_hexBox :: TextBox):IsFocused() then
		(_hexBox :: TextBox).Text = string.format("#%02X%02X%02X",
			math.round(_color.R * 255), math.round(_color.G * 255), math.round(_color.B * 255))
	end
end

-- `onPick` is replaced, never stacked: one panel, one consumer at a time -- whoever opened
-- it last is who the colour belongs to.
function ColorPanel.open(onPick: (c: Color3) -> (), opts: Options?)
	_onPick = onPick
	_opts = opts or {}
	_fade = math.clamp(_opts.transparency or 0, 0, MAX_FADE)
	_open = true
	ColorPanel.sync()
	place()
end

function ColorPanel.close()
	_open = false
	_onPick = nil
	_opts = {}
	ColorPanel.sync()
end

function ColorPanel.isOpen(): boolean return _open end

function ColorPanel.toggle(onPick: (c: Color3) -> (), opts: Options?)
	if _open then ColorPanel.close() else ColorPanel.open(onPick, opts) end
end

return ColorPanel
