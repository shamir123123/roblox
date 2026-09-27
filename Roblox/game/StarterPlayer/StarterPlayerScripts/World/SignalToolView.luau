--!strict
-- SignalToolView -- the in-game traffic signal controller.
--
-- Pick a signalised junction and retime it: how long its greens run, how its crossing
-- turns are served ARM BY ARM, whether pedestrians get the parallel green or a phase
-- of their own. Then link several junctions into a CORRIDOR so they share one cycle
-- and progress a platoon through on a green wave.
--
-- Third pill in the junction-tool stack, under LANES and NODES, and deliberately the
-- same anatomy as both: the three tools do three parts of one job (what a lane may do,
-- what shape the junction is, when each movement gets its turn) and they claim the
-- same panel slot, so only one is ever open.
--
-- The client sends whole plans and ids; it decides nothing. SignalSpec clamps every
-- field on both sides of the wire, SignalReplicationService refuses a plan that fails
-- validation, and SignalPlanStore owns all writes. The warnings shown here are the
-- server's own -- the panel greys its apply on exactly the answer the server will give.

local SignalToolView = {}
local _started = false

function SignalToolView.Start()
	if _started then return end
	_started = true

	local Players = game:GetService("Players")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local UserInputService = game:GetService("UserInputService")
	local Workspace = game:GetService("Workspace")

	local uiFolder = script.Parent.Parent:WaitForChild("UI")
	-- Rides the same UIScale as CityUI: this gui's pill sits in a stack with two others
	-- and its panel flanks the HUD, so it has to shrink with them or they cross over.
	local HudScale = require(uiFolder:WaitForChild("HudScale"))
	local UITheme = require(uiFolder:WaitForChild("Theme"))
	local PanelSlots = require(uiFolder:WaitForChild("PanelSlots"))
	local Icons = require(uiFolder:WaitForChild("Icons"))
	local kitFolder = uiFolder:WaitForChild("Kit")
	local Glass = require(kitFolder:WaitForChild("Glass"))
	local KitButton = require(kitFolder:WaitForChild("Button"))
	local KitDropdown = require(kitFolder:WaitForChild("Dropdown"))

	local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)
	local SignalSpec = require(ReplicatedStorage.Road.SignalSpec)
	local LOD = require(ReplicatedStorage.Shared.LOD)

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local coreFolder = script.Parent.Parent:WaitForChild("Core")
	local Settings = require(coreFolder:WaitForChild("Settings"))
	local CursorRay = require(coreFolder:WaitForChild("CursorRay"))

	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	local setPlanRemote = Net:WaitForRemote("RequestSetSignalPlan") :: RemoteEvent
	local groupEditRemote = Net:WaitForRemote("RequestSignalGroupEdit") :: RemoteEvent
	local dataRemote = Net:WaitForRemote("RequestSignalData") :: RemoteFunction
	if not (setPlanRemote and groupEditRemote and dataRemote) then
		warn("[SignalToolView] required remotes missing -- aborting")
		_started = false
		do return end
	end

	-- Chrome is the shared Theme's, so whatever restyles the HUD restyles this tool.
	-- Selection is the HUD accent, like every other active control in the game.
	local COL_TEXT = UITheme.Color.TextPrimary
	local COL_MUTED = UITheme.Color.TextSecondary
	local COL_FIELD = UITheme.Color.BgRaised
	local COL_ACCENT = UITheme.Color.Accent
	local COL_DANGER = UITheme.Color.Danger
	-- World-space marks painted on asphalt, not chrome: the panel palette has no say
	-- over these. A plain junction, one the player has customised, and the corridor
	-- ribbon that ties a group together.
	local COL_NODE = Color3.fromRGB(150, 150, 158)
	local COL_CUSTOM = Color3.fromRGB(120, 205, 255)
	local COL_RIBBON = Color3.fromRGB(96, 220, 140)

	local POLL_INTERVAL = 0.35 -- seconds between snapshot refreshes while the panel is open

	-- Panel geometry. Wider than the node tool's 236 because this panel carries chip
	-- rows and a corridor listing rather than four numeric fields. CONTENT_W is what is
	-- left after the 10px padding either side and the scrollbar -- every control below
	-- is sized against it, so the width is stated once.
	local PANEL_W = 260
	local CONTENT_W = PANEL_W - 20 - 3

	-- ------------------------------------------------------------------ state --

	local _active = false
	local _nodeId: number? = nil
	local _armIndex: number? = nil
	-- While on, clicking another junction adds it to this one's corridor instead of
	-- selecting it. A mode rather than a modifier key: linking a corridor is several
	-- clicks in a row, and holding shift for all of them is worse than pressing once.
	local _linkMode = false
	local _nodes: { any } = {}
	local _snapshot: any = nil
	local _pollAccum = 0
	-- The plan being edited. Applied to the server on every change; the snapshot that
	-- comes back is authoritative and replaces it.
	local _draft: SignalSpec.SignalPlan = SignalSpec.defaultPlan()

	local refreshPanel: () -> ()
	local render: () -> ()
	local requestData: (wantNodes: boolean) -> ()

	-- ------------------------------------------------------------------ world --

	local _dots = Instance.new("Folder")
	_dots.Name = "SignalToolDots"
	_dots.Parent = Workspace

	local _dotPool: { BasePart } = {}
	local _linkPool: { BasePart } = {}
	local _dotCount = 0
	local _linkCount = 0

	local DISC_THICK = 0.15
	local DISC_LIFT = 0.6

	local function discCFrame(pos: Vector3): CFrame
		return CFrame.new(pos.X, pos.Y + DISC_LIFT, pos.Z) * CFrame.Angles(0, 0, math.rad(90))
	end

	-- Picking is a raycast against this folder, matching the node tool: a ClickDetector
	-- reports only a completed click, which cannot express the press-then-drag the other
	-- junction tools need and fires at the wrong end of a gesture.
	local function pooledPart(pool: { BasePart }, idx: number, shape: Enum.PartType): BasePart
		local part = pool[idx]
		if part then
			part.Parent = _dots
			return part
		end
		part = Instance.new("Part")
		part.Shape = shape
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CastShadow = false
		part.CanQuery = true
		part.Material = Enum.Material.Neon
		part.Parent = _dots
		pool[idx] = part
		return part
	end

	-- The corridor drawn on the ground: a ribbon from each junction to the next, in
	-- TRAVEL order. Seeing the chain is what makes a green wave legible -- a list of
	-- node numbers in a panel does not tell a player which way the wave runs.
	local function drawCorridor()
		local corridor = _snapshot and _snapshot.corridor
		if not corridor or #corridor.members < 2 then return end
		for i = 2, #corridor.members do
			local a = corridor.members[i - 1]
			local b = corridor.members[i]
			local p0 = Vector3.new(a.x, a.y + DISC_LIFT, a.z)
			local p1 = Vector3.new(b.x, b.y + DISC_LIFT, b.z)
			local delta = p1 - p0
			if delta.Magnitude < 0.5 then continue end
			_linkCount += 1
			local part = pooledPart(_linkPool, _linkCount, Enum.PartType.Block)
			part.Name = "CorridorLink"
			part.CanQuery = false -- never steal a click from the junction dots
			part.Color = COL_RIBBON
			part.Transparency = 0.35
			part.Size = Vector3.new(1.2 * RoadConstants.WORLD_SCALE, 0.1, delta.Magnitude)
			part.CFrame = CFrame.lookAt(p0 + delta * 0.5, p1)
		end
	end

	render = function()
		_dotCount = 0
		_linkCount = 0

		if _active then
			local camera = Workspace.CurrentCamera
			local eye = camera and camera.CFrame.Position

			for _, node in _nodes do
				local pos = Vector3.new(node.x, node.y, node.z)
				if LOD.tierAt(pos, eye) >= LOD.CULL then continue end
				_dotCount += 1
				local part = pooledPart(_dotPool, _dotCount, Enum.PartType.Cylinder)
				part.Name = "SignalDot"
				part.CanQuery = true
				local picked = _nodeId == node.nodeId
				local d = if picked then 5.5 else 3.2
				-- Three states worth distinguishing at a glance: selected, customised,
				-- untouched. Group membership reads from the ribbon, not from the dot.
				part.Color = if picked then COL_ACCENT elseif node.custom then COL_CUSTOM else COL_NODE
				part.Transparency = if picked then 0.1 else 0.35
				part.Size = Vector3.new(DISC_THICK, d, d)
				part.CFrame = discCFrame(pos)
				part:SetAttribute("NodeId", node.nodeId)
			end

			drawCorridor()
		end

		for i = _dotCount + 1, #_dotPool do _dotPool[i].Parent = nil end
		for i = _linkCount + 1, #_linkPool do _linkPool[i].Parent = nil end
		refreshPanel()
	end

	-- --------------------------------------------------------------- ui parts --

	local function corner(inst: Instance, radius: number)
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, radius)
		c.Parent = inst
	end

	local function makeLabel(parent: Instance, text: string, size: number, colour: Color3): TextLabel
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.FontFace = UITheme.Font.Label
		l.Text = text
		l.TextSize = size
		l.TextColor3 = colour
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.Size = UDim2.new(1, 0, 0, size + 4)
		l.Parent = parent
		return l
	end

	local function sectionHeading(parent: Instance, text: string, order: number): TextLabel
		local l = makeLabel(parent, text, UITheme.TextSize.XS, UITheme.Color.Brand)
		l.FontFace = UITheme.Font.Header
		l.LayoutOrder = order
		return l
	end

	type NumberRow = { frame: Frame, set: (number) -> () }
	type ChipRow = { frame: Frame, set: (string) -> (), setEnabled: (boolean) -> () }

	type NumberSpec = {
		label: string,
		order: number,
		bounds: string, -- key into SignalSpec.Bounds, so the panel and the server agree
		unit: string,
		fmt: string,
		onCommit: (number) -> (),
	}

	-- A typed value with steppers, not a slider -- the same call the node tool makes,
	-- and for the same reason: a signal should be settable to a round number, and on a
	-- narrow panel one pixel column is most of a second.
	local function numberRow(parent: Instance, spec: NumberSpec): NumberRow
		local b = SignalSpec.Bounds[spec.bounds]

		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, 38)
		row.LayoutOrder = spec.order
		row.Parent = parent

		local caption = makeLabel(row, spec.label, UITheme.TextSize.XS, COL_MUTED)
		caption.Size = UDim2.new(1, 0, 0, 14)

		local box = Instance.new("TextBox")
		box.AnchorPoint = Vector2.new(0.5, 0)
		box.Position = UDim2.new(0.5, 0, 0, 16)
		box.Size = UDim2.new(1, -64, 0, 22)
		box.BackgroundColor3 = COL_FIELD
		box.BorderSizePixel = 0
		box.ClearTextOnFocus = false
		box.FontFace = UITheme.Font.Label
		box.Text = ""
		box.TextSize = UITheme.TextSize.XS
		box.TextColor3 = COL_TEXT
		box.Parent = row
		corner(box, UITheme.Radius.SM)
		local boxEdge = Instance.new("UIStroke")
		boxEdge.Color = UITheme.Color.StrokeSoft
		boxEdge.Thickness = UITheme.StrokeWidth.Thin
		boxEdge.Parent = box

		local value = b.default
		local function show()
			box.Text = string.format(`{spec.fmt} %s`, value, spec.unit)
		end

		local function commit(v: number)
			local clamped = math.clamp(v, b.min, b.max)
			local changed = math.abs(clamped - value) > 1e-4
			value = clamped
			show()
			if changed then spec.onCommit(value) end
		end

		local function stepper(text: string, rightEdge: boolean, delta: number)
			local btn = KitButton.new({
				text = text,
				parent = row,
				compact = true,
				size = UDim2.fromOffset(26, 22),
				textSize = UITheme.TextSize.SM,
				onClick = function() commit(value + delta) end,
			})
			btn.Instance.AnchorPoint = Vector2.new(if rightEdge then 1 else 0, 0)
			btn.Instance.Position = UDim2.new(if rightEdge then 1 else 0, 0, 0, 16)
		end
		stepper("\u{2212}", false, -b.step)
		stepper("+", true, b.step)

		box.FocusLost:Connect(function()
			-- First number out of whatever was typed, so "12", "12 s" and "3.5s" all work;
			-- text with no number in it snaps back to the live value.
			local typed = tonumber(string.match(box.Text, "%-?%d+%.?%d*"))
			if typed then commit(typed) else show() end
		end)

		show()
		return { frame = row, set = function(v: number)
			value = math.clamp(v, b.min, b.max)
			show()
		end }
	end

	-- A row of mutually exclusive chips. Every state is a real, nameable choice, so
	-- each one gets a label rather than leaving the off state unnamed.
	local function chipRow(parent: Instance, label: string, order: number,
		values: { string }, labels: { [string]: string }, onPick: (string) -> ()): ChipRow

		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, if label ~= "" then 40 else 24)
		row.LayoutOrder = order
		row.Parent = parent

		local top = 0
		if label ~= "" then
			local caption = makeLabel(row, label, UITheme.TextSize.XS, COL_MUTED)
			caption.Size = UDim2.new(1, 0, 0, 14)
			top = 16
		end

		local chips: { [string]: any } = {}
		local current = values[1]
		local enabled = true

		local function paint()
			for value, btn in chips do
				btn:SetSelected(value == current)
				btn:SetEnabled(enabled)
			end
		end

		local count = #values
		for i, value in values do
			local frac = 1 / count
			local btn = KitButton.new({
				text = labels[value] or value,
				parent = row,
				compact = true,
				-- Each chip is its share of the width less a 3px gutter, placed at its
				-- share of the width. A UIListLayout cannot express "equal widths with a
				-- fixed gap", so they are placed rather than laid out.
				size = UDim2.new(frac, -3, 0, 22),
				textSize = UITheme.TextSize.XS,
				onClick = function()
					if not enabled or current == value then return end
					current = value
					paint()
					onPick(value)
				end,
			})
			btn.Instance.Position = UDim2.new(frac * (i - 1), 0, 0, top)
			chips[value] = btn
		end
		paint()

		return {
			frame = row,
			set = function(v: string)
				current = v
				paint()
			end,
			setEnabled = function(on: boolean)
				enabled = on
				paint()
			end,
		}
	end

	-- Three or more named options do not fit a chip row. Five chips across this column
	-- leaves 28px of text room and every label here is a real word, so anything past
	-- two options gets a dropdown. The Kit's own, which parents its list to the host
	-- ScreenGui and places it absolutely -- a menu parented to the row would be clipped
	-- by the panel's ScrollingFrame.
	local function dropdownRow(parent: Instance, label: string, order: number,
		values: { string }, labels: { [string]: string }, onPick: (string) -> ()): ChipRow

		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, 48)
		row.LayoutOrder = order
		row.Parent = parent

		local caption = makeLabel(row, label, UITheme.TextSize.XS, COL_MUTED)
		caption.Size = UDim2.new(1, 0, 0, 14)

		local options = {}
		for _, value in values do
			table.insert(options, { label = labels[value] or value, value = value })
		end

		local dd = KitDropdown.new({
			parent = row,
			options = options,
			value = values[1],
			width = CONTENT_W,
			onChange = function(value: any) onPick(value) end,
		})
		dd.Instance.Position = UDim2.fromOffset(0, 16)

		return {
			frame = row,
			set = function(v: string) dd:Set(v) end,
			-- The Kit dropdown has no disabled state; the two rows that use one are never
			-- conditionally locked, so this is a no-op rather than a missing feature.
			setEnabled = function(_on: boolean) end,
		}
	end

	local function makeButton(parent: Instance, text: string, order: number, onClick: () -> ()): any
		return KitButton.new({
			text = text,
			parent = parent,
			compact = true,
			size = UDim2.new(1, 0, 0, 26),
			layoutOrder = order,
			onClick = onClick,
		})
	end

	-- ------------------------------------------------------------- networking --

	local function sendPlan()
		local nodeId = _nodeId
		if not nodeId then return end
		setPlanRemote:FireServer(nodeId, _draft)
		-- Ask for the authoritative result rather than trusting the draft: the server
		-- may clamp a value or refuse the whole plan, and the panel must show what the
		-- junction is actually running, not what was asked for.
		task.delay(0.05, function()
			if _active then requestData(false) end
		end)
	end

	local function sendGroup(req: { [string]: any })
		groupEditRemote:FireServer(req)
		task.delay(0.05, function()
			if _active then requestData(true) end
		end)
	end

	requestData = function(wantNodes: boolean)
		task.spawn(function()
			local ok, reply = pcall(function()
				return dataRemote:InvokeServer({
					nodes = wantNodes,
					nodeId = _nodeId,
				})
			end)
			if not ok or typeof(reply) ~= "table" then return end
			if not _active then return end

			if reply.nodes then
				_nodes = reply.nodes
			end
			if reply.node then
				_snapshot = reply.node
				_draft = SignalSpec.sanitizePlan(reply.node.plan)
			elseif _nodeId then
				-- The junction stopped being signalised under us (a road was removed, or
				-- its arm count dropped below the signal threshold).
				_snapshot = nil
				_nodeId = nil
				_armIndex = nil
			end
			render()
		end)
	end

	-- ------------------------------------------------------------------ panel --

	local _gui: ScreenGui
	local _panel: Frame
	local _scroll: ScrollingFrame
	local _banner: Frame
	local _title: TextLabel
	local _pill: TextButton
	local _pillEdge: UIStroke
	local _pillIcon: ImageLabel
	local _pillCaption: TextLabel

	local _modeRow: ChipRow
	local _customBox: Frame
	local _cycleModeRow: ChipRow
	local _cycleRow: NumberRow
	local _minGreen: NumberRow
	local _maxGreen: NumberRow
	local _yellow: NumberRow
	local _allRed: NumberRow
	local _leadRow: ChipRow
	local _pedRow: ChipRow
	local _pedWalk: NumberRow
	local _armsHeading: TextLabel
	local _corridorHeading: TextLabel
	local _armList: Frame
	local _armButtons: { any } = {}
	local _armSection: Frame
	local _armLeftRow: ChipRow
	local _armHint: TextLabel
	local _corridorBox: Frame
	local _corridorTitle: TextLabel
	local _corridorInfo: TextLabel
	local _linkButton: any
	local _leaveButton: any
	local _createButton: any
	local _groupCycle: NumberRow
	local _groupSpeed: NumberRow
	local _offsetModeRow: ChipRow
	local _offsetRow: NumberRow
	local _autoCycleButton: any
	local _issues: TextLabel
	local _live: TextLabel

	local function buildGui()
		_gui = Instance.new("ScreenGui")
		_gui.Name = "SignalTool"
		_gui.ResetOnSpawn = false
		_gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		-- Its own number in the Tool band: LANES is +1, NODES is +2, and guis that share
		-- a DisplayOrder draw in undefined order.
		_gui.DisplayOrder = UITheme.Layer.Tool + 3
		_gui.Parent = playerGui
		HudScale.attach(_gui)

		-- Third pill in the stack, same 110x30 footprint and right margin as the two
		-- above it, so the three read as one column of tool controls.
		_pill = Instance.new("TextButton")
		_pill.Name = "SignalToolButton"
		_pill.AutoButtonColor = false
		_pill.AnchorPoint = Vector2.new(1, 0)
		_pill.Position = UDim2.new(1, -10, 0, 120)
		_pill.Size = UDim2.fromOffset(110, 30)
		_pill.BackgroundColor3 = UITheme.Color.BgRaised
		_pill.BorderSizePixel = 0
		_pill.Text = ""
		_pill.Parent = _gui
		corner(_pill, 15)
		_pillEdge = Instance.new("UIStroke")
		_pillEdge.Color = UITheme.Color.StrokeSoft
		_pillEdge.Thickness = UITheme.StrokeWidth.Thin
		_pillEdge.Parent = _pill

		_pillIcon = Instance.new("ImageLabel")
		_pillIcon.Name = "Icon"
		_pillIcon.BackgroundTransparency = 1
		_pillIcon.AnchorPoint = Vector2.new(0, 0.5)
		_pillIcon.Position = UDim2.new(0, 10, 0.5, 0)
		_pillIcon.Size = UDim2.fromOffset(16, 16)
		_pillIcon.ScaleType = Enum.ScaleType.Fit
		_pillIcon.Image = Icons.Signals.image
		_pillIcon.ImageColor3 = UITheme.Color.TextSecondary
		_pillIcon.Parent = _pill
		-- Glyph fallback: Icons.Signals has no uploaded art yet, and an ImageLabel with
		-- an empty Image is an empty box.
		if Icons.Signals.image == "" then
			local glyph = makeLabel(_pill, Icons.Signals.glyph, UITheme.TextSize.MD, UITheme.Color.TextSecondary)
			glyph.Name = "IconGlyph"
			glyph.AnchorPoint = Vector2.new(0, 0.5)
			glyph.Position = UDim2.new(0, 10, 0.5, 0)
			glyph.Size = UDim2.fromOffset(16, 16)
			glyph.TextXAlignment = Enum.TextXAlignment.Center
			_pillIcon.Visible = false
			_pillIcon = glyph :: any
		end

		_pillCaption = makeLabel(_pill, "SIGNALS", UITheme.TextSize.XS, UITheme.Color.TextPrimary)
		_pillCaption.Name = "Caption"
		_pillCaption.FontFace = UITheme.Font.Bold
		_pillCaption.AnchorPoint = Vector2.new(0.5, 0.5)
		_pillCaption.Position = UDim2.new(0.5, -2, 0.5, 0)
		_pillCaption.Size = UDim2.new(1, -58, 1, 0)
		_pillCaption.TextXAlignment = Enum.TextXAlignment.Center

		local key = Instance.new("Frame")
		key.Name = "Key"
		key.AnchorPoint = Vector2.new(1, 0.5)
		key.Position = UDim2.new(1, -6, 0.5, 0)
		key.Size = UDim2.fromOffset(18, 18)
		key.BackgroundColor3 = UITheme.Color.BgHover
		key.BorderSizePixel = 0
		key.Parent = _pill
		corner(key, 9)
		local keyLabel = makeLabel(key, "G", UITheme.TextSize.XS, COL_MUTED)
		keyLabel.Size = UDim2.fromScale(1, 1)
		keyLabel.FontFace = UITheme.Font.Bold
		keyLabel.TextXAlignment = Enum.TextXAlignment.Center

		_banner = Instance.new("Frame")
		_banner.AnchorPoint = Vector2.new(0.5, 0)
		_banner.Position = UDim2.new(0.5, 0, 0, 14)
		_banner.Size = UDim2.fromOffset(430, 30)
		_banner.Visible = false
		_banner.Parent = _gui
		Glass.apply(_banner, UITheme.Radius.MD)
		local bl = makeLabel(_banner, "", UITheme.TextSize.XS, UITheme.Color.Brand)
		bl.Name = "BannerLabel"
		bl.FontFace = UITheme.Font.Header
		bl.RichText = true
		-- #A3A096 is Theme.Color.TextSecondary; RichText needs it as a literal.
		bl.Text = 'SIGNAL CONTROLLER <font color="#A3A096"> \u{00B7} click a junction to retime it \u{00B7} G to exit</font>'
		bl.Size = UDim2.fromScale(1, 1)
		bl.TextXAlignment = Enum.TextXAlignment.Center

		-- Same shell as the node tool's panel: glass at radius 14, 8/10 padding, 6px
		-- stack. Wider by 24px because the chip rows carry four and five options.
		_panel = Instance.new("Frame")
		_panel.AnchorPoint = Vector2.new(1, 0.5)
		_panel.Position = UDim2.new(1, -16, 0.5, 0)
		_panel.Size = UDim2.new(0, PANEL_W, 0, 0)
		_panel.AutomaticSize = Enum.AutomaticSize.Y
		_panel.Visible = false
		_panel.Parent = _gui
		Glass.apply(_panel, 14)
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0, 8)
		pad.PaddingBottom = UDim.new(0, 10)
		pad.PaddingLeft = UDim.new(0, 10)
		pad.PaddingRight = UDim.new(0, 10)
		pad.Parent = _panel

		-- This panel carries far more than the node tool's four fields, and on a short
		-- viewport an auto-sized column would run off both ends of the screen. It grows
		-- to its content and starts scrolling past 560px instead.
		_scroll = Instance.new("ScrollingFrame")
		_scroll.BackgroundTransparency = 1
		_scroll.BorderSizePixel = 0
		_scroll.Size = UDim2.new(1, 0, 0, 0)
		_scroll.AutomaticSize = Enum.AutomaticSize.Y
		_scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
		_scroll.CanvasSize = UDim2.new()
		_scroll.ScrollBarThickness = 3
		_scroll.ScrollBarImageColor3 = UITheme.Color.StrokeSoft
		_scroll.Parent = _panel
		local cap = Instance.new("UISizeConstraint")
		cap.MaxSize = Vector2.new(math.huge, 560)
		cap.Parent = _scroll
		local layout = Instance.new("UIListLayout")
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 6)
		layout.Parent = _scroll

		-- Masthead: accent chip + tool name, the header every panel in this HUD wears.
		local header = Instance.new("Frame")
		header.BackgroundTransparency = 1
		header.Size = UDim2.new(1, 0, 0, 30)
		header.LayoutOrder = 0
		header.Parent = _scroll

		local chip = Instance.new("Frame")
		chip.Size = UDim2.fromOffset(26, 26)
		chip.Position = UDim2.fromOffset(0, 2)
		chip.BackgroundColor3 = COL_ACCENT
		chip.BorderSizePixel = 0
		chip.Parent = header
		corner(chip, 13)
		local chipGlyph = makeLabel(chip, Icons.Signals.glyph, UITheme.TextSize.MD, UITheme.Color.OnAccent)
		chipGlyph.Size = UDim2.fromScale(1, 1)
		chipGlyph.TextXAlignment = Enum.TextXAlignment.Center

		local headLabel = makeLabel(header, "SIGNAL CONTROLLER", UITheme.TextSize.MD, UITheme.Color.Brand)
		headLabel.FontFace = UITheme.Font.Header
		headLabel.Position = UDim2.fromOffset(34, 0)
		headLabel.Size = UDim2.new(1, -34, 1, 0)

		local rule = Instance.new("Frame")
		rule.BackgroundColor3 = UITheme.Color.StrokeSoft
		rule.BackgroundTransparency = 0.5
		rule.BorderSizePixel = 0
		rule.Size = UDim2.new(1, 0, 0, 1)
		rule.LayoutOrder = 1
		rule.Parent = _scroll

		_title = makeLabel(_scroll, "JUNCTION", UITheme.TextSize.SM, UITheme.Color.Brand)
		_title.FontFace = UITheme.Font.Header
		_title.LayoutOrder = 2

		_live = makeLabel(_scroll, "", UITheme.TextSize.XS, COL_MUTED)
		_live.LayoutOrder = 3

		-- Auto vs Custom is the master switch: on Auto the junction runs the global
		-- defaults exactly as it always has, and every control below is hidden rather
		-- than greyed -- a panel of dead fields is worse than a short panel.
		_modeRow = chipRow(_scroll, "TIMING", 4, { "auto", "custom" },
			{ auto = "Auto", custom = "Custom" }, function(v)
				_draft.custom = v == "custom"
				sendPlan()
			end)

		_customBox = Instance.new("Frame")
		_customBox.BackgroundTransparency = 1
		_customBox.Size = UDim2.new(1, 0, 0, 0)
		_customBox.AutomaticSize = Enum.AutomaticSize.Y
		_customBox.LayoutOrder = 5
		_customBox.Visible = false
		_customBox.Parent = _scroll
		local customLayout = Instance.new("UIListLayout")
		customLayout.SortOrder = Enum.SortOrder.LayoutOrder
		customLayout.Padding = UDim.new(0, 6)
		customLayout.Parent = _customBox

		_cycleModeRow = chipRow(_customBox, "CYCLE", 1, { "adaptive", "fixed" },
			{ adaptive = "Adaptive", fixed = "Fixed" }, function(v)
				_draft.cycleMode = v :: any
				sendPlan()
			end)

		_cycleRow = numberRow(_customBox, {
			label = "CYCLE LENGTH", order = 2, bounds = "cycle", unit = "s", fmt = "%.0f",
			onCommit = function(v) _draft.cycle = v; sendPlan() end,
		})

		_minGreen = numberRow(_customBox, {
			label = "MIN GREEN", order = 3, bounds = "minGreen", unit = "s", fmt = "%.0f",
			onCommit = function(v) _draft.minGreen = v; sendPlan() end,
		})
		_maxGreen = numberRow(_customBox, {
			label = "MAX GREEN", order = 4, bounds = "maxGreen", unit = "s", fmt = "%.0f",
			onCommit = function(v) _draft.maxGreen = v; sendPlan() end,
		})
		_yellow = numberRow(_customBox, {
			label = "YELLOW", order = 5, bounds = "yellow", unit = "s", fmt = "%.1f",
			onCommit = function(v) _draft.yellow = v; sendPlan() end,
		})
		_allRed = numberRow(_customBox, {
			label = "ALL-RED CLEARANCE", order = 6, bounds = "allRed", unit = "s", fmt = "%.1f",
			onCommit = function(v) _draft.allRed = v; sendPlan() end,
		})

		_leadRow = chipRow(_customBox, "LEFT TURNS RUN", 7, { "lead", "lag" },
			{ lead = "Leading", lag = "Lagging" }, function(v)
				_draft.leadingLefts = v == "lead"
				sendPlan()
			end)

		_pedRow = dropdownRow(_customBox, "PEDESTRIANS", 8, SignalSpec.PED_MODES,
			SignalSpec.PED_MODE_LABELS, function(v)
				_draft.pedMode = v :: any
				sendPlan()
			end)

		_pedWalk = numberRow(_customBox, {
			label = "WALK TIME", order = 9, bounds = "pedWalk", unit = "s", fmt = "%.0f",
			onCommit = function(v) _draft.pedWalk = v; sendPlan() end,
		})

		-- Arms -----------------------------------------------------------------
		_armsHeading = sectionHeading(_scroll, "APPROACHES", 6)

		_armList = Instance.new("Frame")
		_armList.BackgroundTransparency = 1
		_armList.Size = UDim2.new(1, 0, 0, 0)
		_armList.AutomaticSize = Enum.AutomaticSize.Y
		_armList.LayoutOrder = 7
		_armList.Parent = _scroll
		local armLayout = Instance.new("UIListLayout")
		armLayout.SortOrder = Enum.SortOrder.LayoutOrder
		armLayout.Padding = UDim.new(0, 4)
		armLayout.Parent = _armList

		_armSection = Instance.new("Frame")
		_armSection.BackgroundTransparency = 1
		_armSection.Size = UDim2.new(1, 0, 0, 0)
		_armSection.AutomaticSize = Enum.AutomaticSize.Y
		_armSection.LayoutOrder = 8
		_armSection.Visible = false
		_armSection.Parent = _scroll
		local armSecLayout = Instance.new("UIListLayout")
		armSecLayout.SortOrder = Enum.SortOrder.LayoutOrder
		armSecLayout.Padding = UDim.new(0, 4)
		armSecLayout.Parent = _armSection

		_armLeftRow = dropdownRow(_armSection, "CROSSING TURN", 1, SignalSpec.LEFT_MODES,
			SignalSpec.LEFT_MODE_NAMES, function(v)
				local armIndex = _armIndex
				if not armIndex then return end
				_draft.arms[armIndex] = { leftMode = v :: any }
				sendPlan()
			end)

		_armHint = makeLabel(_armSection, "", UITheme.TextSize.XS, COL_MUTED)
		_armHint.TextWrapped = true
		_armHint.Size = UDim2.new(1, 0, 0, 0)
		_armHint.AutomaticSize = Enum.AutomaticSize.Y
		_armHint.LayoutOrder = 2

		-- Corridor -------------------------------------------------------------
		_corridorHeading = sectionHeading(_scroll, "CORRIDOR", 9)

		_corridorBox = Instance.new("Frame")
		_corridorBox.BackgroundTransparency = 1
		_corridorBox.Size = UDim2.new(1, 0, 0, 0)
		_corridorBox.AutomaticSize = Enum.AutomaticSize.Y
		_corridorBox.LayoutOrder = 10
		_corridorBox.Parent = _scroll
		local corrLayout = Instance.new("UIListLayout")
		corrLayout.SortOrder = Enum.SortOrder.LayoutOrder
		corrLayout.Padding = UDim.new(0, 4)
		corrLayout.Parent = _corridorBox

		_corridorTitle = makeLabel(_corridorBox, "", UITheme.TextSize.XS, COL_TEXT)
		_corridorTitle.LayoutOrder = 0
		_corridorTitle.TextWrapped = true
		_corridorTitle.Size = UDim2.new(1, 0, 0, 0)
		_corridorTitle.AutomaticSize = Enum.AutomaticSize.Y

		_createButton = makeButton(_corridorBox, "Start a corridor here", 1, function()
			if not _nodeId then return end
			sendGroup({ action = "create", nodeId = _nodeId })
			-- Straight into link mode: a corridor of one is not a corridor, and adding
			-- the next junction is always what happens next.
			_linkMode = true
		end)

		_linkButton = makeButton(_corridorBox, "Link more junctions", 2, function()
			_linkMode = not _linkMode
			render()
		end)

		_groupCycle = numberRow(_corridorBox, {
			label = "COMMON CYCLE", order = 3, bounds = "cycle", unit = "s", fmt = "%.0f",
			onCommit = function(v)
				local groupId = _snapshot and _snapshot.groupId
				if groupId then sendGroup({ action = "settings", groupId = groupId, settings = { cycle = v } }) end
			end,
		})

		_autoCycleButton = makeButton(_corridorBox, "Work out the cycle", 4, function()
			local groupId = _snapshot and _snapshot.groupId
			if groupId then sendGroup({ action = "autoCycle", groupId = groupId }) end
		end)

		_groupSpeed = numberRow(_corridorBox, {
			label = "PROGRESSION SPEED", order = 5, bounds = "progressionKmh", unit = "km/h", fmt = "%.0f",
			onCommit = function(v)
				local groupId = _snapshot and _snapshot.groupId
				if groupId then sendGroup({ action = "settings", groupId = groupId, settings = { progressionKmh = v } }) end
			end,
		})

		_offsetModeRow = chipRow(_corridorBox, "OFFSETS", 6, { "auto", "manual" },
			{ auto = "Green wave", manual = "Manual" }, function(v)
				local groupId = _snapshot and _snapshot.groupId
				if groupId then
					sendGroup({ action = "settings", groupId = groupId, settings = { autoOffsets = v == "auto" } })
				end
			end)

		_offsetRow = numberRow(_corridorBox, {
			label = "THIS JUNCTION'S OFFSET", order = 7, bounds = "offset", unit = "s", fmt = "%.1f",
			onCommit = function(v) _draft.offset = v; sendPlan() end,
		})

		_corridorInfo = makeLabel(_corridorBox, "", UITheme.TextSize.XS, COL_MUTED)
		_corridorInfo.TextWrapped = true
		_corridorInfo.Size = UDim2.new(1, 0, 0, 0)
		_corridorInfo.AutomaticSize = Enum.AutomaticSize.Y
		_corridorInfo.LayoutOrder = 8

		_leaveButton = makeButton(_corridorBox, "Leave corridor", 9, function()
			if not _nodeId then return end
			sendGroup({ action = "leave", nodeId = _nodeId })
		end)

		-- Warnings -------------------------------------------------------------
		_issues = makeLabel(_scroll, "", UITheme.TextSize.XS, COL_DANGER)
		_issues.TextWrapped = true
		_issues.RichText = true
		_issues.Size = UDim2.new(1, 0, 0, 0)
		_issues.AutomaticSize = Enum.AutomaticSize.Y
		_issues.LayoutOrder = 11
	end

	-- ---------------------------------------------------------------- refresh --

	local function metresLabel(studs: number): string
		return RoadConstants.formatMeters(studs)
	end

	refreshPanel = function()
		if not _active then
			_panel.Visible = false
			return
		end
		_panel.Visible = true

		local snapshot = _snapshot
		if not snapshot then
			_title.Text = if #_nodes == 0 then "NO SIGNALS YET" else "PICK A JUNCTION"
			_live.Text = if #_nodes == 0
				then "Signals appear where a road of four lanes or more meets another. Widen a road, or add an arm to a junction."
				else string.format("%d signalised junctions. Click one to retime it.", #_nodes)
			_live.TextColor3 = COL_MUTED
			_modeRow.frame.Visible = false
			_customBox.Visible = false
			_armList.Visible = false
			_armSection.Visible = false
			_corridorBox.Visible = false
			-- Headings follow their sections: a lone "APPROACHES" over empty space reads
			-- as a panel that failed to load.
			_armsHeading.Visible = false
			_corridorHeading.Visible = false
			_issues.Text = ""
			return
		end

		_modeRow.frame.Visible = true
		_armList.Visible = true
		_corridorBox.Visible = true
		_armsHeading.Visible = true
		_corridorHeading.Visible = true

		_title.Text = string.format("INTERSECTION %d \u{00B7} %d ARMS", snapshot.nodeId, #snapshot.arms)

		-- Live readout: which phase is lit and for how much longer. The one thing that
		-- makes a timing change legible -- a number in a field says nothing until the
		-- junction is seen running it.
		local livePhase = snapshot.phases[snapshot.livePhase]
		if livePhase then
			local stateWord = if snapshot.liveState == "allred" then "all red" else snapshot.liveState
			_live.Text = string.format("Now: %s \u{00B7} %s \u{00B7} %.1fs left \u{00B7} %d phases%s",
				livePhase.label, stateWord, snapshot.liveTimer, #snapshot.phases,
				if snapshot.coordinated then string.format(" \u{00B7} %ds cycle", snapshot.cycle or 0) else "")
			_live.TextColor3 = COL_MUTED
		end

		_modeRow.set(if _draft.custom then "custom" else "auto")
		_customBox.Visible = _draft.custom

		if _draft.custom then
			_cycleModeRow.set(_draft.cycleMode)
			-- A junction in a corridor takes the corridor's cycle, so its own cycle mode
			-- and length are not its to set -- showing them editable would be a lie.
			local inCorridor = snapshot.groupId ~= nil
			_cycleModeRow.setEnabled(not inCorridor)
			_cycleRow.frame.Visible = _draft.cycleMode == "fixed" and not inCorridor
			_cycleRow.set(_draft.cycle)
			-- Adaptive stretch is what MAX GREEN bounds; a fixed cycle has no stretch.
			_maxGreen.frame.Visible = _draft.cycleMode == "adaptive" and not inCorridor
			_minGreen.set(_draft.minGreen)
			_maxGreen.set(_draft.maxGreen)
			_yellow.set(_draft.yellow)
			_allRed.set(_draft.allRed)
			_leadRow.set(if _draft.leadingLefts then "lead" else "lag")
			_pedRow.set(_draft.pedMode)
			_pedWalk.frame.Visible = _draft.pedMode == "scramble"
			_pedWalk.set(_draft.pedWalk)
		end

		-- Arm buttons ----------------------------------------------------------
		for i = #snapshot.arms + 1, #_armButtons do
			_armButtons[i].Instance.Visible = false
		end
		for i, arm in snapshot.arms do
			local btn = _armButtons[i]
			if not btn then
				local idx = i
				btn = makeButton(_armList, "", i, function()
					_armIndex = if _armIndex == idx then nil else idx
					render()
				end)
				_armButtons[i] = btn
			end
			btn.Instance.Visible = true
			local mode = SignalSpec.armPlan(_draft, i).leftMode
			-- Kit buttons render caps, so set the text already upper -- otherwise the
			-- label the factory uppercased and the one written here disagree.
			-- Short mode tag here: the arm rows are a list to pick from, and the full
			-- treatment name is spelled out in the section that opens below.
			btn.Instance.Text = string.upper(string.format("Arm %d \u{00B7} %d\u{00B0} \u{00B7} %s",
				i, arm.bearing, SignalSpec.LEFT_MODE_LABELS[mode] or mode))
			btn:SetSelected(_armIndex == i)
		end

		local arm = if _armIndex then snapshot.arms[_armIndex] else nil
		_armSection.Visible = arm ~= nil and _draft.custom
		if arm and _draft.custom then
			local mode = SignalSpec.armPlan(_draft, _armIndex :: number).leftMode
			_armLeftRow.set(mode)
			_armHint.Text = string.format(
				"%s\n%d through lane(s), crosses %d oncoming lane(s) at %d km/h. %s",
				SignalSpec.LEFT_MODE_HINTS[mode] or "",
				arm.throughLanes, arm.opposingLanes, arm.speedKmh,
				if arm.hasDedicatedLeft
					then "Has a dedicated turn lane, so a protected phase is available."
					else "No dedicated turn lane -- protected phases need one; set it in the lane connector.")
		end

		-- Corridor -------------------------------------------------------------
		local corridor = snapshot.corridor
		local inCorridor = corridor ~= nil
		_createButton.Instance.Visible = not inCorridor
		_linkButton.Instance.Visible = inCorridor
		_leaveButton.Instance.Visible = inCorridor
		_groupCycle.frame.Visible = inCorridor
		_groupSpeed.frame.Visible = inCorridor
		_offsetModeRow.frame.Visible = inCorridor
		_autoCycleButton.Instance.Visible = inCorridor
		_offsetRow.frame.Visible = inCorridor and not (corridor and corridor.autoOffsets)

		if inCorridor then
			_corridorTitle.Text = string.format("%s \u{00B7} %d junctions", corridor.name, #corridor.members)
			_groupCycle.set(corridor.cycle)
			_groupSpeed.set(corridor.progressionKmh)
			_offsetModeRow.set(if corridor.autoOffsets then "auto" else "manual")
			_offsetRow.set(_draft.offset)
			_linkButton.Instance.Text = string.upper(if _linkMode then "Stop linking" else "Link more junctions")
			_linkButton:SetSelected(_linkMode)

			-- Where this junction sits in the wave, and how the real spacing compares to
			-- the spacing that would make two-way progression free. Perfect two-way
			-- progression exists only at half a cycle of travel apart, so quoting the
			-- ideal is what stops an unavoidable compromise reading as a broken tool.
			local lines = {}
			for i, member in corridor.members do
				local marker = if member.nodeId == snapshot.nodeId then "\u{25B8}" else "\u{00B7}"
				local suffix = if i == 1 then " (master)" else string.format(" \u{00B7} %s", metresLabel(member.spacing))
				table.insert(lines, string.format("%s %ds%s", marker, math.round(member.offset), suffix))
			end
			table.insert(lines, string.format("Ideal spacing for two-way: %s", metresLabel(corridor.idealSpacing)))
			if corridor.advice then
				table.insert(lines, corridor.advice)
			end
			_corridorInfo.Text = table.concat(lines, "\n")
			_corridorInfo.TextColor3 = if corridor.tooFar then UITheme.Color.Danger else COL_MUTED
		else
			_corridorTitle.Text = "Free-running. Link junctions into a corridor to share one cycle and run a green wave along them."
			_corridorInfo.Text = ""
		end

		-- Warnings -------------------------------------------------------------
		local issues = snapshot.issues
		if issues and #issues > 0 then
			local parts = {}
			for _, issue in issues do
				-- #A3A096 is Theme.Color.TextSecondary, #EC6264 is Theme.Color.Danger;
				-- RichText needs both as literals.
				local colour = if issue.severity == "error" then "#EC6264" else "#A3A096"
				local mark = if issue.severity == "error" then "\u{2715}" else "\u{26A0}"
				table.insert(parts, string.format('<font color="%s">%s %s</font>', colour, mark, issue.text))
			end
			_issues.Text = table.concat(parts, "\n")
		else
			_issues.Text = ""
		end
	end

	-- --------------------------------------------------------------- picking --

	local _dotFilter: { Instance } = { _dots }

	local function dotUnder(input: InputObject?): BasePart?
		local hit = CursorRay.hitIn(_dotFilter, input)
		local part = hit and hit.Instance
		return if part and part:IsA("BasePart") then part else nil
	end

	local function pickNode(nodeId: number)
		-- In link mode a click ADDS to the corridor instead of moving the selection:
		-- building a corridor is several clicks and re-selecting between each one would
		-- lose the corridor being built.
		if _linkMode and _snapshot and _snapshot.groupId and nodeId ~= _nodeId then
			sendGroup({ action = "join", nodeId = nodeId, groupId = _snapshot.groupId })
			return
		end
		if _nodeId == nodeId then
			_nodeId = nil
			_snapshot = nil
			_armIndex = nil
		else
			_nodeId = nodeId
			_armIndex = nil
			_snapshot = nil
			requestData(false)
		end
		render()
	end

	-- ---------------------------------------------------------------- toggle --

	local function setActive(on: boolean)
		_active = on
		_banner.Visible = on
		if on then
			-- The lane connector and the node tool occupy exactly these coordinates, so
			-- claiming the slot closes them rather than letting all three overdraw.
			PanelSlots.claim("toolPanel", "SignalTool", function()
				setActive(false)
			end)
			requestData(true)
		else
			PanelSlots.release("toolPanel", "SignalTool")
			_nodeId = nil
			_armIndex = nil
			_snapshot = nil
			_linkMode = false
		end
		-- Active tool = the HUD's accent fill with the lighter accent ring, exactly what
		-- a selected Kit button wears.
		_pill.BackgroundColor3 = if on then UITheme.Color.Accent else UITheme.Color.BgRaised
		_pillEdge.Color = if on then UITheme.Color.AccentHover else UITheme.Color.StrokeSoft
		_pillEdge.Thickness = if on then UITheme.StrokeWidth.Thick else UITheme.StrokeWidth.Thin
		_pillCaption.TextColor3 = if on then UITheme.Color.OnAccent else UITheme.Color.TextPrimary
		if _pillIcon:IsA("ImageLabel") then
			_pillIcon.ImageColor3 = if on then UITheme.Color.OnAccent else UITheme.Color.TextSecondary
		else
			(_pillIcon :: any).TextColor3 = if on then UITheme.Color.OnAccent else UITheme.Color.TextSecondary
		end
		render()
	end

	buildGui()

	_pill.Activated:Connect(function()
		setActive(not _active)
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if Settings.pressed("SignalTool", input) then
			setActive(not _active)
			return
		end
		if not _active then return end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		local part = dotUnder(input)
		if not part then return end
		local id = part:GetAttribute("NodeId")
		if typeof(id) == "number" then
			pickNode(id)
		end
	end)

	-- The panel shows LIVE phase state, so it polls while open. Read-only and rate
	-- limited server-side, and it stops the moment the tool closes.
	game:GetService("RunService").Heartbeat:Connect(function(dt: number)
		if not _active then return end
		_pollAccum += dt
		if _pollAccum < POLL_INTERVAL then return end
		_pollAccum = 0
		requestData(true)
	end)
end

return SignalToolView
