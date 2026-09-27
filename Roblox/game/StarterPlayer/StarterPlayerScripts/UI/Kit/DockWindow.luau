--!strict
-- DockWindow: Roblox-Studio-style dockable window system.
-- A Host owns three dock zones around the viewport -- Left column, Right
-- column, Bottom strip -- plus free-floating windows. Windows drag by their
-- title bar; while dragging, a translucent accent preview marks the slot the
-- window would land in (Studio's dock hint). Release inside a zone to dock,
-- anywhere else to float. Docked columns resize with splitter bars; floating
-- windows resize from the corner grip.
--
-- Controllers only ever toggle `win.Frame.Visible` -- the host listens and
-- re-flows, so hiding Explorer hands its space to Properties exactly like
-- closing a Studio dock widget.

local UserInputService = game:GetService("UserInputService")

local Theme = require(script.Parent.Parent.Theme)

local TITLE_H   = 26
local GAP       = 6
local SPLIT     = 6    -- splitter grab thickness
local EDGE      = 130  -- cursor distance from a screen edge that arms that dock zone
local MIN_COL_W = 190
local MAX_COL_W = 520
local MIN_BOT_H = 140
local MAX_BOT_H = 460
local DRAG_SLOP = 6    -- pixels of movement before a title grab becomes a drag

export type Zone = "Left" | "Right" | "Bottom"

export type WindowProps = {
	name: string,
	title: string,
	icon: { image: string, glyph: string }?,
	zone: Zone?,
	floatSize: Vector2?,
	minSize: Vector2?,
}

export type Window = {
	Frame: Frame,
	Content: Frame,
	Dock: (self: Window, zone: Zone, index: number?) -> (),
	Float: (self: Window, pos: Vector2?) -> (),
	IsDocked: (self: Window) -> boolean,
}

export type Host = {
	Root: Frame,
	CreateWindow: (self: Host, props: WindowProps) -> Window,
	Relayout: (self: Host) -> (),
}

type Rec = {
	frame: Frame,
	content: Frame,
	grip: TextButton,
	floatToggle: TextButton,
	zone: Zone?,
	lastZone: Zone,
	floatPos: Vector2,
	floatSize: Vector2,
	minSize: Vector2,
}

local DockWindow = {}

function DockWindow.newHost(opts: { gui: ScreenGui, topOffset: number, margin: number? }): Host
	local top = opts.topOffset
	local margin = opts.margin or 8

	local root = Instance.new("Frame")
	root.Name = "DockRoot"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = opts.gui

	local zones: { [string]: { Rec } } = { Left = {}, Right = {}, Bottom = {} }
	local allRecs: { Rec } = {}
	local leftW, rightW, bottomH = 280, 280, 240
	local floatZ = 10
	local cascade = 0
	local relayout: () -> ()

	local function mouseL(pos: Vector3): Vector2
		return Vector2.new(pos.X, pos.Y) - root.AbsolutePosition
	end

	local function visibleIn(zone: string): { Rec }
		local out: { Rec } = {}
		for _, rec in zones[zone] do
			if rec.frame.Visible then table.insert(out, rec) end
		end
		return out
	end

	-- == splitters =============================================================
	local function makeSplitter(name: string): Frame
		local s = Instance.new("Frame")
		s.Name = name
		s.BackgroundColor3 = Theme.Color.StrokeSoft
		s.BackgroundTransparency = 1 -- invisible until hovered
		s.BorderSizePixel = 0
		s.ZIndex = 5
		s.Active = true
		s.Visible = false
		s.Parent = root
		s.MouseEnter:Connect(function() s.BackgroundTransparency = 0.55 end)
		s.MouseLeave:Connect(function() s.BackgroundTransparency = 1 end)
		return s
	end
	local leftSplit = makeSplitter("SplitLeft")
	local rightSplit = makeSplitter("SplitRight")
	local botSplit = makeSplitter("SplitBottom")

	-- == drop preview ==========================================================
	local preview = Instance.new("Frame")
	preview.Name = "DropPreview"
	preview.BackgroundColor3 = Theme.Color.Accent
	preview.BackgroundTransparency = 0.82
	preview.BorderSizePixel = 0
	preview.ZIndex = 40
	preview.Visible = false
	preview.Parent = root
	local pc = Instance.new("UICorner"); pc.CornerRadius = UDim.new(0, Theme.Radius.MD); pc.Parent = preview
	local ps = Instance.new("UIStroke"); ps.Color = Theme.Color.Accent; ps.Thickness = 2; ps.Parent = preview

	-- == layout ================================================================
	local function area(): (number, number, number, number)
		local size = root.AbsoluteSize
		return margin, size.X - margin, top, size.Y - margin
	end

	-- rect (x, y, w, h) each visible window in `zone` would occupy if the column
	-- held `count` windows; slot is 1-based. Shared by relayout and the preview
	-- so the hint never lies about where the window will land.
	local function slotRect(zone: string, slot: number, count: number): (number, number, number, number)
		local x0, x1, y0, y1 = area()
		if zone == "Bottom" then
			local bx0 = x0 + (if #visibleIn("Left") > 0 then leftW + GAP else 0)
			local bx1 = x1 - (if #visibleIn("Right") > 0 then rightW + GAP else 0)
			local w = (bx1 - bx0 - GAP * (count - 1)) / count
			return bx0 + (w + GAP) * (slot - 1), y1 - bottomH, w, bottomH
		end
		local colX = if zone == "Left" then x0 else x1 - rightW
		local colW = if zone == "Left" then leftW else rightW
		local h = (y1 - y0 - GAP * (count - 1)) / count
		return colX, y0 + (h + GAP) * (slot - 1), colW, h
	end

	relayout = function()
		local x0, x1, y0, y1 = area()
		if x1 - x0 < 100 or y1 - y0 < 100 then return end -- viewport not ready yet

		for _, zone in { "Left", "Right", "Bottom" } do
			local vis = visibleIn(zone)
			for slot, rec in vis do
				local x, y, w, h = slotRect(zone, slot, #vis)
				rec.frame.Position = UDim2.fromOffset(x, y)
				rec.frame.Size = UDim2.fromOffset(w, h)
			end
		end

		-- floats: keep on screen even after a resolution change
		for _, rec in allRecs do
			if rec.zone == nil and rec.frame.Visible then
				local size = rec.floatSize
				local px = math.clamp(rec.floatPos.X, 0, math.max(0, root.AbsoluteSize.X - size.X))
				local py = math.clamp(rec.floatPos.Y, top, math.max(top, root.AbsoluteSize.Y - 40))
				rec.frame.Position = UDim2.fromOffset(px, py)
				rec.frame.Size = UDim2.fromOffset(size.X, size.Y)
			end
		end

		-- splitters hug the inner edge of each occupied zone
		local hasL, hasR, hasB = #visibleIn("Left") > 0, #visibleIn("Right") > 0, #visibleIn("Bottom") > 0
		leftSplit.Visible = hasL
		rightSplit.Visible = hasR
		botSplit.Visible = hasB
		if hasL then
			leftSplit.Position = UDim2.fromOffset(x0 + leftW, y0)
			leftSplit.Size = UDim2.fromOffset(SPLIT, y1 - y0)
		end
		if hasR then
			rightSplit.Position = UDim2.fromOffset(x1 - rightW - SPLIT, y0)
			rightSplit.Size = UDim2.fromOffset(SPLIT, y1 - y0)
		end
		if hasB then
			local bx0 = x0 + (if hasL then leftW + GAP else 0)
			local bx1 = x1 - (if hasR then rightW + GAP else 0)
			botSplit.Position = UDim2.fromOffset(bx0, y1 - bottomH - SPLIT)
			botSplit.Size = UDim2.fromOffset(bx1 - bx0, SPLIT)
		end
	end

	-- == splitter drags ========================================================
	local function hookSplitter(s: Frame, apply: (delta: Vector2) -> ())
		local dragging = false
		local last = Vector2.zero
		s.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				last = mouseL(input.Position)
			end
		end)
		UserInputService.InputChanged:Connect(function(input)
			if not dragging then return end
			if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then return end
			local now = mouseL(input.Position)
			apply(now - last)
			last = now
			relayout()
		end)
		UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = false
			end
		end)
	end
	hookSplitter(leftSplit, function(d) leftW = math.clamp(leftW + d.X, MIN_COL_W, MAX_COL_W) end)
	hookSplitter(rightSplit, function(d) rightW = math.clamp(rightW - d.X, MIN_COL_W, MAX_COL_W) end)
	hookSplitter(botSplit, function(d) bottomH = math.clamp(bottomH - d.Y, MIN_BOT_H, MAX_BOT_H) end)

	-- == zone hit test =========================================================
	-- Which slot would `pos` drop into? Compares against the CENTERS of the
	-- windows currently docked there, so insertion feels like Studio's.
	local function insertSlot(zone: string, pos: Vector2): number
		local vis = visibleIn(zone)
		local slot = 1
		for _, rec in vis do
			local f = rec.frame
			local c = f.AbsolutePosition - root.AbsolutePosition + f.AbsoluteSize / 2
			local m = if zone == "Bottom" then pos.X > c.X else pos.Y > c.Y
			if m then slot += 1 end
		end
		return slot
	end

	local function zoneCandidate(pos: Vector2): (Zone?, number)
		local x0, x1, y0, y1 = area()
		if pos.Y < y0 then return nil, 0 end
		if pos.X < x0 + EDGE then return "Left", insertSlot("Left", pos) end
		if pos.X > x1 - EDGE then return "Right", insertSlot("Right", pos) end
		if pos.Y > y1 - EDGE then return "Bottom", insertSlot("Bottom", pos) end
		return nil, 0
	end

	-- == dock / float ==========================================================
	local function removeFromZone(rec: Rec)
		local z = rec.zone
		if not z then return end
		local list = zones[z]
		local i = table.find(list, rec)
		if i then table.remove(list, i) end
		rec.lastZone = z
		rec.zone = nil
	end

	local function dockRec(rec: Rec, zone: Zone, slot: number?)
		removeFromZone(rec)
		local list = zones[zone]
		-- `slot` counts visible windows; map it to a real list index
		local idx = #list + 1
		if slot then
			local vis = visibleIn(zone)
			local beforeRec = vis[math.clamp(slot, 1, #vis + 1)]
			if beforeRec then idx = table.find(list, beforeRec) :: number end
		end
		table.insert(list, math.clamp(idx, 1, #list + 1), rec)
		rec.zone = zone
		rec.frame.ZIndex = 2
		rec.grip.Visible = false
		rec.floatToggle.Text = "\u{2197}" -- pop-out arrow: click to float
		relayout()
	end

	local function floatRec(rec: Rec, pos: Vector2?)
		removeFromZone(rec)
		if pos then
			rec.floatPos = pos
		elseif rec.floatPos == Vector2.zero then
			cascade += 1
			rec.floatPos = Vector2.new(120 + cascade * 28, top + 40 + cascade * 28)
		end
		floatZ += 1
		rec.frame.ZIndex = floatZ
		rec.grip.Visible = true
		rec.floatToggle.Text = "\u{2199}" -- dock-back arrow
		relayout()
	end

	-- == window construction ===================================================
	local function createWindow(props: WindowProps): Window
		local minSize = props.minSize or Vector2.new(220, 140)
		local floatSize = props.floatSize or Vector2.new(300, 380)

		local frame = Instance.new("Frame")
		frame.Name = props.name
		frame.BackgroundColor3 = Theme.Color.BgRaised
		frame.BackgroundTransparency = 0.05
		frame.BorderSizePixel = 0
		frame.ClipsDescendants = true
		frame.ZIndex = 2
		local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, Theme.Radius.MD); corner.Parent = frame
		local stroke = Instance.new("UIStroke"); stroke.Color = Theme.Color.Stroke; stroke.Thickness = 1; stroke.Transparency = 0.35; stroke.Parent = frame

		-- title bar: what you grab to drag the window around, Studio style
		local bar = Instance.new("TextButton")
		bar.Name = "TitleBar"
		bar.Text = ""
		bar.AutoButtonColor = false
		bar.BackgroundColor3 = Theme.Color.Bg
		bar.BackgroundTransparency = 0.15
		bar.BorderSizePixel = 0
		bar.Size = UDim2.new(1, 0, 0, TITLE_H)
		bar.ZIndex = 3
		bar.Parent = frame
		local edge = Instance.new("Frame")
		edge.Name = "Edge"
		edge.AnchorPoint = Vector2.new(0, 1)
		edge.Position = UDim2.fromScale(0, 1)
		edge.Size = UDim2.new(1, 0, 0, 1)
		edge.BackgroundColor3 = Theme.Color.Stroke
		edge.BackgroundTransparency = 0.6
		edge.BorderSizePixel = 0
		edge.ZIndex = 3
		edge.Parent = bar

		local textX = 8
		if props.icon then
			if props.icon.image ~= "" then
				local img = Instance.new("ImageLabel")
				img.Name = "Icon"
				img.BackgroundTransparency = 1
				img.Position = UDim2.fromOffset(7, (TITLE_H - 14) // 2)
				img.Size = UDim2.fromOffset(14, 14)
				img.Image = props.icon.image
				img.ImageColor3 = Theme.Color.Brand
				img.ScaleType = Enum.ScaleType.Fit
				img.ZIndex = 4
				img.Parent = bar
			else
				local g = Instance.new("TextLabel")
				g.Name = "Icon"
				g.BackgroundTransparency = 1
				g.Position = UDim2.fromOffset(7, 0)
				g.Size = UDim2.fromOffset(14, TITLE_H)
				g.Text = props.icon.glyph
				g.TextSize = 12
				g.TextColor3 = Theme.Color.Brand
				g.FontFace = Theme.Font.Bold
				g.ZIndex = 4
				g.Parent = bar
			end
			textX = 26
		end

		local title = Instance.new("TextLabel")
		title.Name = "Title"
		title.BackgroundTransparency = 1
		title.Position = UDim2.fromOffset(textX, 0)
		title.Size = UDim2.new(1, -(textX + 52), 1, 0)
		title.FontFace = Theme.Font.Bold
		title.Text = string.upper(props.title)
		title.TextSize = Theme.TextSize.XS
		title.TextColor3 = Theme.Color.TextSecondary
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.TextTruncate = Enum.TextTruncate.AtEnd
		title.ZIndex = 4
		title.Parent = bar

		local function barButton(name: string, text: string, xFromRight: number): TextButton
			local b = Instance.new("TextButton")
			b.Name = name
			b.AnchorPoint = Vector2.new(1, 0)
			b.Position = UDim2.new(1, -xFromRight, 0, 3)
			b.Size = UDim2.fromOffset(20, 20)
			b.BackgroundTransparency = 1
			b.Text = text
			b.TextSize = 12
			b.TextColor3 = Theme.Color.TextSecondary
			b.FontFace = Theme.Font.Bold
			b.ZIndex = 4
			b.Parent = bar
			b.MouseEnter:Connect(function() b.TextColor3 = Theme.Color.TextPrimary end)
			b.MouseLeave:Connect(function() b.TextColor3 = Theme.Color.TextSecondary end)
			return b
		end
		local closeBtn = barButton("Close", "\u{2715}", 4)
		local floatToggle = barButton("FloatToggle", "\u{2197}", 26)

		local content = Instance.new("Frame")
		content.Name = "Content"
		content.BackgroundTransparency = 1
		content.Position = UDim2.fromOffset(0, TITLE_H)
		content.Size = UDim2.new(1, 0, 1, -TITLE_H)
		content.ZIndex = 2
		content.Parent = frame

		-- floating-only corner resize grip
		local grip = Instance.new("TextButton")
		grip.Name = "ResizeGrip"
		grip.AnchorPoint = Vector2.new(1, 1)
		grip.Position = UDim2.new(1, -1, 1, -1)
		grip.Size = UDim2.fromOffset(16, 16)
		grip.BackgroundTransparency = 1
		grip.Text = "\u{25E2}"
		grip.TextSize = 12
		grip.TextColor3 = Theme.Color.StrokeSoft
		grip.FontFace = Theme.Font.Label
		grip.ZIndex = 6
		grip.Visible = false
		grip.Parent = frame

		frame.Parent = root

		local rec: Rec = {
			frame = frame,
			content = content,
			grip = grip,
			floatToggle = floatToggle,
			zone = nil,
			lastZone = props.zone or "Right",
			floatPos = Vector2.zero,
			floatSize = floatSize,
			minSize = minSize,
		}
		table.insert(allRecs, rec)

		closeBtn.Activated:Connect(function() frame.Visible = false end)
		floatToggle.Activated:Connect(function()
			if rec.zone then
				local p = frame.AbsolutePosition - root.AbsolutePosition
				floatRec(rec, Vector2.new(p.X + 30, p.Y + 30))
			else
				dockRec(rec, rec.lastZone)
			end
		end)

		-- hiding/showing re-flows siblings (controller toggles Visible directly)
		frame:GetPropertyChangedSignal("Visible"):Connect(function()
			if frame.Visible and rec.zone == nil and rec.floatPos == Vector2.zero then
				-- never-floated window re-shown while undocked: give it its dock back
				dockRec(rec, rec.lastZone)
			else
				relayout()
			end
		end)

		-- == title-bar drag -> dock/float =====================================
		local press: Vector2? = nil
		local grabOffset = Vector2.zero
		local draggingWin = false

		bar.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
			press = mouseL(input.Position)
			grabOffset = press :: Vector2 - (frame.AbsolutePosition - root.AbsolutePosition)
			if rec.zone == nil then -- clicking a float brings it to front
				floatZ += 1
				frame.ZIndex = floatZ
			end
		end)

		UserInputService.InputChanged:Connect(function(input)
			if not press then return end
			if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then return end
			local now = mouseL(input.Position)
			if not draggingWin then
				if (now - press :: Vector2).Magnitude < DRAG_SLOP then return end
				draggingWin = true
				if rec.zone then
					-- tear the window out of its dock: it rides the cursor at float size
					removeFromZone(rec)
					rec.grip.Visible = true
					rec.floatToggle.Text = "\u{2199}"
					grabOffset = Vector2.new(math.min(grabOffset.X, rec.floatSize.X - 40), 12)
					relayout()
				end
				frame.ZIndex = 60
			end
			local p = now - grabOffset
			rec.floatPos = p
			frame.Position = UDim2.fromOffset(p.X, p.Y)
			frame.Size = UDim2.fromOffset(rec.floatSize.X, rec.floatSize.Y)
			local zone, slot = zoneCandidate(now)
			if zone then
				local vis = visibleIn(zone)
				local x, y, w, h = slotRect(zone, slot, #vis + 1)
				preview.Position = UDim2.fromOffset(x, y)
				preview.Size = UDim2.fromOffset(w, h)
				preview.Visible = true
			else
				preview.Visible = false
			end
		end)

		UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
			if not press then return end
			local was = draggingWin
			press = nil
			draggingWin = false
			preview.Visible = false
			if not was then return end
			local now = mouseL(input.Position)
			local zone, slot = zoneCandidate(now)
			if zone then
				dockRec(rec, zone, slot)
			else
				floatRec(rec, now - grabOffset)
			end
		end)

		-- == corner resize (floating only) ====================================
		local resizing = false
		local resizeLast = Vector2.zero
		grip.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				resizing = true
				resizeLast = mouseL(input.Position)
			end
		end)
		UserInputService.InputChanged:Connect(function(input)
			if not resizing then return end
			if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then return end
			local now = mouseL(input.Position)
			local d = now - resizeLast
			resizeLast = now
			rec.floatSize = Vector2.new(
				math.clamp(rec.floatSize.X + d.X, rec.minSize.X, math.max(rec.minSize.X, root.AbsoluteSize.X - 20)),
				math.clamp(rec.floatSize.Y + d.Y, rec.minSize.Y, math.max(rec.minSize.Y, root.AbsoluteSize.Y - top - 10))
			)
			if rec.zone == nil then relayout() end
		end)
		UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				resizing = false
			end
		end)

		local win: Window = {
			Frame = frame,
			Content = content,
			Dock = function(_, zone: Zone, index: number?) dockRec(rec, zone, index) end,
			Float = function(_, pos: Vector2?) floatRec(rec, pos) end,
			IsDocked = function(_): boolean return rec.zone ~= nil end,
		}

		if props.zone then dockRec(rec, props.zone) end
		return win
	end

	root:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)
	task.defer(relayout)

	local host: Host = {
		Root = root,
		CreateWindow = function(_, props: WindowProps): Window return createWindow(props) end,
		Relayout = function(_) relayout() end,
	}
	return host
end

return DockWindow
