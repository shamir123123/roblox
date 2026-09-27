--!strict
-- StreetNameView
-- Street names painted on the carriageway, bending with the road and repeating
-- along its length -- the Cities: Skylines read.
--
-- The name is laid out one CHARACTER at a time along the street's arc, each glyph
-- on its own thin plate turned to the local tangent, so the text curves through
-- bends instead of sitting as a straight bar across them. Glyphs step forward by
-- their own measured width, so a name reads as a word rather than s p a c e d out.
--
-- SIZE: names hold a roughly constant on-screen size -- they grow in world units
-- as the camera pulls back and shrink as it comes in, driven through TweenService
-- so the change glides instead of stepping. Each street is LAID OUT ONCE at the
-- largest size its own carriageway can carry, and every smaller size is that same
-- layout scaled down. Two things fall out of that for free: the letters keep their
-- spacing at every size (they never bunch into a blob), and repeats of the name
-- can never grow into each other, because shrinking only ever opens the gap.
--
-- Rebuilds happen only when a street's name or geometry changes -- never for zoom.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local AddressBook     = require(ReplicatedStorage.City.AddressBook)
local BezierUtil      = require(ReplicatedStorage.Road.BezierUtil)
local DataCache       = require(ReplicatedStorage.DataCache)
local RoadConstants   = require(ReplicatedStorage.Road.RoadConstants)
local RoadTypeCatalog = require(ReplicatedStorage.Road.RoadTypeCatalog)
local RenderPressure  = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("RenderPressure"))

local StreetNameView = {}

local WS = RoadConstants.WORLD_SCALE
local UP = Vector3.yAxis

-- One rebuild per burst of segment deltas: dragging a long road fires many.
local REBUILD_DEBOUNCE = 0.35
-- Names stop drawing past this (SurfaceGui.MaxDistance -- the engine culls them,
-- costing us nothing). Beyond it you are in the regional view, where a map full of
-- street names is noise.
local MAX_VIEW_DISTANCE = 1700 * WS

-- Cap height as a share of the distance the camera is from the ground it is looking
-- at. This is what keeps the on-screen size steady while the world size changes.
local SCREEN_HEIGHT_FRACTION = 0.022
local MIN_TEXT_HEIGHT = 3 * WS   -- floor on the driver itself; the real floor is per street
-- Absolute ceiling. Sized so the ceiling is not what stops growth before you hit
-- MAX_VIEW_DISTANCE: below MAX_VIEW_DISTANCE * SCREEN_HEIGHT_FRACTION the names
-- would start shrinking on screen partway through the zoom-out.
local MAX_TEXT_HEIGHT = 40 * WS
-- A name must fit its own carriageway: this is the share of the road width it may
-- reach. Growth stops here -- the name never climbs over the kerb. TEXT_FILL takes
-- another cut out of it, so the painted glyph is ~0.72 of the road width here.
local MAX_HEIGHT_OF_WIDTH = 0.85
-- The size never drops below this share of the street's OWN full size. Close in the
-- name is smaller, pulled back it grows to fill the carriageway, and past
-- MAX_VIEW_DISTANCE it culls entirely. 1/0.55 is under two-to-one across the whole
-- zoom range -- present, but nothing like the 4x swing the flat floor used to give.
local MIN_HEIGHT_FRACTION = 0.55

local SCALE_POLL = 0.15
-- Ignore target changes under this fraction, so a drifting camera does not retween
-- constantly.
local SCALE_EPSILON = 0.02
local SCALE_TWEEN = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- Streets whose nearest point is further than this are left alone by a resize: they
-- are past MAX_VIEW_DISTANCE and not being drawn anyway.
local UPDATE_RADIUS = MAX_VIEW_DISTANCE * 1.15

-- Gap between repeats of the name, in multiples of the name's own length at full
-- size. Generous on purpose: a name repeated too often reads as clutter. Repeats
-- live inside ONE block -- a name never runs through a junction to reach the next.
local REPEAT_GAP = 9
-- How far a name keeps clear of a junction, as a multiple of the widest road
-- meeting there. Names sit in the blocks between junctions, never in the box.
local JUNCTION_CLEARANCE = 0.75
-- A block has to be this much longer than the name to carry it.
local BLOCK_MARGIN = 1.1
-- Reading direction must lean this far into the camera's right before the name
-- turns round, so a street running straight up the screen does not flicker.
local FLIP_DEADBAND = 0.12
-- A street shorter than this gets no name: a junction stub or a fillet arc.
local MIN_STREET_LENGTH = 70 * WS
-- Roblox clamps TextLabel.TextSize to 100, so a glyph's WORLD size comes from the
-- SurfaceGui's PixelsPerStud, never from a bigger TextSize. (TextScaled does not
-- track the plate either -- both verified in-engine.)
local TEXT_PX = 100
local TEXT_FILL = 0.85  -- share of the plate depth the glyph occupies
-- Measured per character, widths sum to ~1.5% more than the same string measured
-- whole (side bearings counted twice at every join); tracking takes that back out.
local TRACKING = 0.985
local PLATE_THICKNESS = 0.08
local SURFACE_LIFT = 0.06  -- clears the road surface without z-fighting
local SAMPLES_PER_SEGMENT = 10
-- Hard ceiling on glyph plates. ponytail: a flat budget, not a camera-radius
-- streamer. A city big enough to hit it loses the names on its newest streets,
-- which is a far better failure than a frame-rate cliff.
--
-- Each plate is a Part carrying a SurfaceGui and a stroked TextLabel, which is a
-- far heavier object than its size suggests, and this view sits OUTSIDE _City so
-- AssetLODView's ladder never reaches it. On a struggling client the ceiling comes
-- down: the names that go are the ones on the streets furthest down the rebuild,
-- and losing some beats a client that cannot hold a frame.
local MAX_PLATES_FULL = 3000
local MAX_PLATES_PRESSED = 900

local function maxPlates(): number
	return RenderPressure.lerpInt(MAX_PLATES_FULL, MAX_PLATES_PRESSED)
end

-- Streets re-laid per apply pass.
--
-- A turn used to re-lay EVERY glyph in the city, and deliberately so: the distance
-- skip was bypassed because a far street keeping its old facing reads upside down
-- the moment you arrive at it. At the plate cap that is 9,000 property writes,
-- polled up to 6.7 times a second, for as long as the camera is rotating -- a
-- guaranteed hitch on a weak device during the most common thing a player does.
--
-- The correctness argument was right and the remedy was too strong. A far street is
-- marked DIRTY instead and re-laid on the pass that brings it back inside
-- UPDATE_RADIUS. It is never seen wearing the stale facing, because past
-- MAX_VIEW_DISTANCE the engine is not drawing it at all.
local RELAY_BUDGET_FULL = 48
local RELAY_BUDGET_PRESSED = 16
-- Bold, not SemiBold: at road-paint size on grey asphalt the lighter weight goes
-- thin and washes out. The same face MEASURES and renders, so the per-glyph
-- advances always match what is actually drawn.
local FONT = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.Bold, Enum.FontStyle.Italic)

-- A glyph, stored in units of cap height so any size is one multiplication away.
type Glyph = {
	part: BasePart,
	gui: SurfaceGui,
	centre: number,      -- arc distance of this label's midpoint along the street
	offsetUnit: number,  -- arc offset from that midpoint in reading order, per unit cap height
	widthUnit: number,   -- plate length along the road, per unit cap height
	-- Which way the name currently reads: +1 along the street, -1 against it. Taken
	-- from the camera on every apply so the text is never upside down, and kept per
	-- glyph so FLIP_DEADBAND has a previous state to hold against.
	sign: number,
}

type Street = {
	parts: { BasePart },
	glyphs: { Glyph },
	pts: { Vector3 },
	cum: { number },
	sig: string,
	maxHeight: number,
	height: number,
	-- Studs off the road's centre line the name is painted at: 0 on a normal road, half a
	-- carriageway on one with a median. See paintLane.
	offset: number,
	anchor: Vector3,
	halfLength: number,
	-- The camera turned while this street was out of drawing range, or the last pass ran out
	-- of budget before reaching it. Either way its glyphs are laid for a facing that is no
	-- longer current, and the next pass that can see it must re-lay it even if nothing else
	-- about it moved.
	dirty: boolean,
}

local _folder: Folder? = nil
local _streets: { [number]: Street } = {}
local _queued = false
local _started = false
local _pollAccum = 0
-- Held for the session: this view lives as long as the client does. Tracked rather
-- than left anonymous so it is disconnectable if that ever stops being true.
local _pollConn: RBXScriptConnection? = nil
local _focusParams = RaycastParams.new()
-- Glyph widths in pixels at TEXT_PX, measured once per character and kept. The
-- measurement yields, so a rebuild can too -- hence _rebuilding below.
local _advancePx: { [string]: number } = {}
local _rebuilding = false
local _rerun = false
-- The live cap height. TweenService drives this one number; everything else is
-- recomputed from it, so the whole city resizes together and in step.
local _driver = Instance.new("NumberValue")
local _tween: Tween? = nil
-- Camera right, flattened. Names turn to face it; a change re-lays every glyph.
local _lastRight = Vector3.xAxis

local function ensureFolder(): Folder
	local existing = _folder
	if existing and existing.Parent then return existing end
	local found = Workspace:FindFirstChild("_StreetNames")
	if found and found:IsA("Folder") then
		_folder = found
		return found
	end
	if found then found:Destroy() end
	local folder = Instance.new("Folder")
	folder.Name = "_StreetNames"
	folder.Parent = Workspace
	_folder = folder
	return folder
end

-- Width of one character at TEXT_PX. Yields on the first sighting of a character,
-- then answers from the table forever.
local function advancePx(char: string): number
	local cached = _advancePx[char]
	if cached then return cached end
	local params = Instance.new("GetTextBoundsParams")
	params.Text = char
	params.Font = FONT
	params.Size = TEXT_PX
	params.Width = 100000
	local ok, bounds = pcall(function()
		return TextService:GetTextBoundsAsync(params)
	end)
	-- A failed measurement must not stall the label: fall back to a plausible width
	-- rather than dropping the glyph.
	local width = if ok and bounds then bounds.X else TEXT_PX * 0.55
	_advancePx[char] = width
	return width
end

local function pxToStuds(px: number, height: number): number
	return px * height * TEXT_FILL / TEXT_PX * TRACKING
end

local function nameWidth(name: string, height: number): number
	local total = 0
	for k = 1, #name do
		total += advancePx(string.sub(name, k, k))
	end
	return pxToStuds(total, height)
end

local function makeGlyph(folder: Folder, char: string): (BasePart, SurfaceGui)
	local part = Instance.new("Part")
	part.Name = "Glyph"
	part.Anchored = true
	part.CanCollide = false
	-- Invisible to the road-click raycast and to the zoom probe: clicking a name
	-- must open the road under it, not stop on the letter.
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth

	local gui = Instance.new("SurfaceGui")
	gui.Name = "G"
	gui.Face = Enum.NormalId.Top
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.MaxDistance = MAX_VIEW_DISTANCE
	gui.LightInfluence = 0
	gui.Brightness = 1.5
	gui.Parent = part

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.FontFace = FONT
	label.TextScaled = false
	label.TextSize = TEXT_PX
	label.Text = char
	label.TextColor3 = Color3.fromRGB(248, 246, 240)
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.TextStrokeTransparency = 0.3
	label.Parent = gui

	part.Parent = folder
	return part, gui
end

type Joint = { d: number, pos: Vector3 }

-- The street as one flat polyline in street order, with cumulative arc length, plus
-- the seam between every pair of segments -- the only places a junction can sit.
local function chainPolyline(index: AddressBook.Index, chain: { number }): ({ Vector3 }, { number }, { Joint })
	local pts: { Vector3 } = {}
	local cum: { number } = {}
	local joints: { Joint } = {}
	local total = 0
	for _, id in chain do
		local s = index.segs[id]
		if not s then continue end
		local forward = index.dirs[id] ~= false
		table.insert(joints, { d = total, pos = if forward then s.p0 else s.p3 })
		for i = 0, SAMPLES_PER_SEGMENT do
			-- Skip the shared endpoint where this piece meets the previous one.
			if i == 0 and #pts > 0 then continue end
			local t = i / SAMPLES_PER_SEGMENT
			if not forward then t = 1 - t end
			local p = BezierUtil.point(s.p0, s.p1, s.p2, s.p3, t)
			local prev = pts[#pts]
			if prev then
				local dx, dz = p.X - prev.X, p.Z - prev.Z
				total += math.sqrt(dx * dx + dz * dz)
			end
			table.insert(pts, p)
			table.insert(cum, total)
		end
	end
	local last = pts[#pts]
	if last then table.insert(joints, { d = total, pos = last }) end
	return pts, cum, joints
end

-- Position + flat tangent at a distance along the polyline.
local function sampleAt(pts: { Vector3 }, cum: { number }, d: number): (Vector3, Vector3)
	local n = #pts
	if n < 2 then return pts[1] or Vector3.zero, Vector3.xAxis end
	d = math.clamp(d, 0, cum[n])
	local i = 2
	while i < n and cum[i] < d do
		i += 1
	end
	local a, b = pts[i - 1], pts[i]
	local ca, cb = cum[i - 1], cum[i]
	local f = if cb > ca then (d - ca) / (cb - ca) else 0
	local dir = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	dir = if dir.Magnitude > 1e-4 then dir.Unit else Vector3.xAxis
	return a:Lerp(b, f), dir
end

-- The strip of carriageway a name is painted on: how wide it is, and how far off the
-- road's centre line it sits. A road with a CENTRE MEDIAN has no carriageway on its centre
-- line at all -- the name laid there was buried under the planted strip -- so it moves onto
-- one carriageway and is sized to that, not to the pair.
local function paintLane(spec: any): (number, number)
	local full = RoadTypeCatalog.carriagewayWidth(spec)
	local median = if spec.median then (tonumber(spec.medianWidth) or 0) else 0
	if median <= 0 then return full, 0 end
	return (full - median) * 0.5, (full + median) * 0.25
end

-- Place every glyph of a street at cap height `h`, read in whichever direction sits
-- upright for `right` (the camera's right, flattened). Positions come from the arc,
-- so the text stays on the road at any size rather than drifting off a bend.
local function applyStreet(street: Street, h: number, right: Vector3, force: boolean)
	if not force and math.abs(h - street.height) < 1e-3 then return end
	street.height = h
	local pts, cum = street.pts, street.cum
	local pixels = TEXT_PX / (h * TEXT_FILL)
	-- Glyphs are stored in label order, so one flip decision per label, taken from
	-- the tangent at its midpoint -- the direction the eye reads the whole word.
	local lastCentre: number? = nil
	local sign = 1
	for _, g in street.glyphs do
		if g.centre ~= lastCentre then
			lastCentre = g.centre
			local _, t = sampleAt(pts, cum, g.centre)
			local lean = t:Dot(right)
			sign = g.sign
			if lean > FLIP_DEADBAND then
				sign = 1
			elseif lean < -FLIP_DEADBAND then
				sign = -1
			end
		end
		g.sign = sign
		local pos, tangent = sampleAt(pts, cum, g.centre + g.offsetUnit * h * sign)
		-- Off the centre line onto one carriageway when the road has a median. Taken from the
		-- TANGENT, not the reading direction, so the name keeps to the same side of the road
		-- however the camera turns it round.
		if street.offset ~= 0 then pos += UP:Cross(tangent) * street.offset end
		-- A Top-face SurfaceGui maps its X (the reading direction) to the part's -Z
		-- and its Y to the part's X. Verified in-engine, not assumed: building the
		-- plate the obvious way turns every letter a quarter turn.
		local vZ = -tangent * sign
		local y = pos.Y + RoadConstants.ROAD_THICKNESS * 0.5 + SURFACE_LIFT
		g.part.Size = Vector3.new(h, PLATE_THICKNESS, g.widthUnit * h)
		g.part.CFrame = CFrame.fromMatrix(Vector3.new(pos.X, y, pos.Z), UP:Cross(vZ), UP, vZ)
		g.gui.PixelsPerStud = pixels
	end
end

local function applyHeight(target: number)
	local cam = Workspace.CurrentCamera
	local camPos = if cam then cam.CFrame.Position else nil
	local right = if cam then cam.CFrame.RightVector else Vector3.xAxis
	right = Vector3.new(right.X, 0, right.Z)
	right = if right.Magnitude > 1e-4 then right.Unit else Vector3.xAxis
	-- A turn re-lays every VISIBLE glyph; a pure zoom only touches streets whose size moved.
	local turned = right:Dot(_lastRight) < 0.9999
	_lastRight = right

	local budget = RenderPressure.lerpInt(RELAY_BUDGET_FULL, RELAY_BUDGET_PRESSED)

	for _, street in _streets do
		-- Out of drawing range, so nothing here is on screen to be caught looking wrong.
		-- Record that its facing is stale and move on -- this is what replaced re-laying the
		-- whole city on every turn.
		if camPos and (street.anchor - camPos).Magnitude - street.halfLength > UPDATE_RADIUS then
			if turned then
				street.dirty = true
			end
			continue
		end
		if budget <= 0 then
			-- Stragglers keep what they have and are picked up by the next poll 0.15 s later,
			-- marked so that pass re-lays them even if nothing else has moved since.
			street.dirty = true
			continue
		end
		local force = turned or street.dirty
		local h = math.clamp(target, street.maxHeight * MIN_HEIGHT_FRACTION, street.maxHeight)
		local before = street.height
		applyStreet(street, h, right, force)
		street.dirty = false
		-- applyStreet no-ops on an unforced street whose size did not move, so only passes
		-- that actually wrote glyphs are charged against the budget.
		if force or before ~= street.height then
			budget -= 1
		end
	end
end

-- One instance of the name, centred at `centre` studs along the street, laid out at
-- the street's full size. Returns how many plates it used.
local function layoutLabel(
	folder: Folder,
	street: Street,
	centre: number,
	name: string,
	budget: number
): number
	local h = street.maxHeight
	local advances = table.create(#name)
	local width = 0
	for k = 1, #name do
		local a = pxToStuds(advancePx(string.sub(name, k, k)), h)
		advances[k] = a
		width += a
	end
	-- Offsets are stored in reading order out from the label's midpoint. Which way
	-- that order runs along the street is decided from the camera, at apply time.
	local used = 0
	local cursor = 0
	for k = 1, #name do
		local advance = advances[k]
		local offset = cursor + advance * 0.5 - width * 0.5
		cursor += advance
		if used >= budget then break end
		local char = string.sub(name, k, k)
		if char == " " then continue end

		local part, gui = makeGlyph(folder, char)
		table.insert(street.parts, part)
		table.insert(street.glyphs, {
			part = part,
			gui = gui,
			centre = centre,
			-- Stored per unit of cap height: every smaller size is this layout scaled.
			offsetUnit = offset / h,
			widthUnit = advance / h,
			sign = 1,
		})
		used += 1
	end
	return used
end

-- Segment ends quantised to half a stud: the network shares node positions exactly,
-- so this only guards against float drift.
local function nodeKey(p: Vector3): string
	return string.format("%d,%d", math.round(p.X * 2), math.round(p.Z * 2))
end

-- Degree and widest road at every node in the city. Three segment ends or more
-- meeting is a junction; two is just the street carrying on.
local function nodeCensus(index: AddressBook.Index): ({ [string]: number }, { [string]: number })
	local degree: { [string]: number } = {}
	local widest: { [string]: number } = {}
	for _, s in index.segs do
		local w = RoadTypeCatalog.getOrDefault(s.roadType).width
		for _, p in { s.p0, s.p3 } do
			local k = nodeKey(p)
			degree[k] = (degree[k] or 0) + 1
			widest[k] = math.max(widest[k] or 0, w)
		end
	end
	return degree, widest
end

-- The stretches of a street that are not junction box, in order -- its blocks. A
-- name lives centred in one of these; it never crosses a junction.
local function blocksOf(
	joints: { Joint },
	length: number,
	degree: { [string]: number },
	widest: { [string]: number }
): { { number } }
	local blocked: { { number } } = {}
	for _, j in joints do
		local k = nodeKey(j.pos)
		if (degree[k] or 0) < 3 then continue end
		local clear = (widest[k] or 0) * JUNCTION_CLEARANCE
		table.insert(blocked, { j.d - clear, j.d + clear })
	end
	table.sort(blocked, function(a, b)
		return a[1] < b[1]
	end)
	local blocks: { { number } } = {}
	local cursor = 0
	for _, b in blocked do
		local stop = math.min(b[1], length)
		if stop > cursor then table.insert(blocks, { cursor, stop }) end
		cursor = math.max(cursor, b[2])
	end
	if cursor < length then table.insert(blocks, { cursor, length }) end
	return blocks
end

-- Points sampled along the street to fingerprint its SHAPE.
local SIG_SAMPLES = 12

local function signature(name: string, pts: { Vector3 }, cum: { number }, blocks: { { number } }): string
	-- The blocks are in the signature, not just the geometry: a new road landing
	-- mid-street moves nothing on this chain but does change where names may sit.
	local spans = table.create(#blocks)
	for i, b in blocks do
		spans[i] = string.format("%d-%d", math.round(b[1]), math.round(b[2]))
	end
	-- The SHAPE, not just the two ends. A road reshaped in the middle -- a curve
	-- handle dragged, a node moved, the ground regraded under it -- keeps its
	-- endpoints and very nearly its length; on a CLOSED LOOP the two ends are the
	-- same point, so ends fingerprint nothing at all. Matching on ends alone left the
	-- street unrebuilt and its glyphs lying along the road's OLD line -- straight
	-- across a bend the road now takes, out over the grass.
	local n = #pts
	local shape = table.create(SIG_SAMPLES)
	for i = 1, SIG_SAMPLES do
		local at = if n > 1 then math.round((i - 1) / (SIG_SAMPLES - 1) * (n - 1)) + 1 else 1
		local p = pts[at] or Vector3.zero
		shape[i] = string.format("%d,%d,%d", math.round(p.X), math.round(p.Y), math.round(p.Z))
	end
	return string.format(
		"%s|%d|%d|%s|%s",
		name, math.round(cum[n] or 0), n,
		table.concat(shape, ";"),
		table.concat(spans, ",")
	)
end

local function clearStreet(key: number)
	local street = _streets[key]
	if not street then return end
	for _, part in street.parts do
		part:Destroy()
	end
	_streets[key] = nil
end

local function rebuild()
	_queued = false

	local index = AddressBook.buildIndex(DataCache.GetSegments())
	local degree, widest = nodeCensus(index)
	local budget = maxPlates()
	local folder = ensureFolder()
	local live: { [number]: boolean } = {}

	for key, chain in index.chains do
		local seed = index.segs[chain[1]]
		if not seed then continue end
		-- A railway has no address, so it gets no name on the ground.
		if RoadTypeCatalog.getOrDefault(seed.roadType).isRail then continue end

		local name = index.names[key]
		if not name or name == "" then continue end

		local pts, cum, joints = chainPolyline(index, chain)
		local length = cum[#cum] or 0
		if length < MIN_STREET_LENGTH then continue end

		local blocks = blocksOf(joints, length, degree, widest)
		local sig = signature(name, pts, cum, blocks)
		local existing = _streets[key]
		if existing and existing.sig == sig then
			live[key] = true
			budget -= #existing.parts
			continue
		end
		clearStreet(key)

		-- Full size for THIS road: as tall as its own carriageway can carry. Growth
		-- stops here, so the name can never spill over the kerb.
		-- The CARRIAGEWAY, not the whole right of way: a parking apron or a planted
		-- verge counts in spec.width and is not road to paint a name across.
		local width, offset = paintLane(RoadTypeCatalog.getOrDefault(seed.roadType))
		local maxHeight = math.min(MAX_TEXT_HEIGHT, width * MAX_HEIGHT_OF_WIDTH)
		if maxHeight < MIN_TEXT_HEIGHT then continue end

		local labelWidth = nameWidth(name, maxHeight)

		local mid = sampleAt(pts, cum, length * 0.5)
		local street: Street = {
			parts = {}, glyphs = {}, pts = pts, cum = cum, sig = sig,
			maxHeight = maxHeight, height = 0, offset = offset,
			anchor = mid, halfLength = length * 0.5,
			dirty = false,
		}

		-- One name per block, centred in it. A block long enough for several gets them
		-- spread evenly, which is still centred taken as a set.
		for _, block in blocks do
			if budget <= 0 then break end
			local span = block[2] - block[1]
			if span < labelWidth * BLOCK_MARGIN then continue end
			local repeats = math.max(1, math.floor(span / (labelWidth * REPEAT_GAP)))
			for i = 1, repeats do
				if budget <= 0 then break end
				budget -= layoutLabel(folder, street, block[1] + span * (i - 0.5) / repeats, name, budget)
			end
		end
		if #street.parts > 0 then
			live[key] = true
			_streets[key] = street
		end
	end

	for key in _streets do
		if not live[key] then
			clearStreet(key)
		end
	end

	-- New plates are created unsized; place them at the current height.
	applyHeight(_driver.Value)
end

-- Measuring a character yields, so a rebuild can be interrupted by the next one.
-- Two running at once would both write _streets[key] and orphan a street's plates,
-- so the second request is folded into a re-run instead.
local function runRebuild()
	if _rebuilding then
		_rerun = true
		return
	end
	_rebuilding = true
	repeat
		_rerun = false
		local ok, err = pcall(rebuild)
		if not ok then
			warn("[StreetNameView] rebuild failed: " .. tostring(err))
			_rerun = false
		end
	until not _rerun
	_rebuilding = false
end

local function queueRebuild()
	if _queued then return end
	_queued = true
	task.delay(REBUILD_DEBOUNCE, function()
		_queued = false
		runRebuild()
	end)
end

-- How far the camera is from the ground it is looking at. The city-builder camera
-- always points at the map, so this tracks zoom directly and needs no camera API.
local function targetHeight(): number
	local cam = Workspace.CurrentCamera
	if not cam then return MIN_TEXT_HEIGHT end
	local origin = cam.CFrame.Position
	local hit = Workspace:Raycast(origin, cam.CFrame.LookVector * 6000, _focusParams)
	local distance = if hit then (hit.Position - origin).Magnitude else math.max(origin.Y, 1)
	return math.clamp(distance * SCREEN_HEIGHT_FRACTION, MIN_TEXT_HEIGHT, MAX_TEXT_HEIGHT)
end

function StreetNameView.Start()
	if _started then return end
	_started = true

	_driver.Name = "StreetNameHeight"
	_driver.Value = targetHeight()
	_driver:GetPropertyChangedSignal("Value"):Connect(function()
		applyHeight(_driver.Value)
	end)

	DataCache.On("segments", queueRebuild)

	-- Name plates are invisible to the focus ray (CanQuery is false on every one),
	-- so the zoom probe reads the ground, not the labels.
	_pollConn = RunService.Heartbeat:Connect(function(dt: number)
		_pollAccum += dt
		if _pollAccum < SCALE_POLL then return end
		_pollAccum = 0
		local target = targetHeight()
		local current = _driver.Value
		if math.abs(target - current) <= math.max(current, MIN_TEXT_HEIGHT) * SCALE_EPSILON then
			-- Size has settled, but the camera may have turned. applyHeight no-ops per
			-- street unless it did, so this is a cheap comparison, not a re-lay.
			applyHeight(current)
			return
		end
		if _tween then _tween:Cancel() end
		local tween = TweenService:Create(_driver, SCALE_TWEEN, { Value = target })
		_tween = tween
		tween:Play()
	end)

	if DataCache.IsReady() then
		queueRebuild()
	end
end

return StreetNameView
