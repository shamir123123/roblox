--!strict
-- BadAppleShow -- takes you to an empty grass field and plays Bad Apple by PLACING ROADS.
--
-- Not a screen and not the player's city: the show builds its own stage well above the map
-- (a plain grass field, guaranteed empty airspace) and draws each frame on it the way the
-- city itself is drawn -- ROADS ON THE OUTSIDE, PAINT WITHIN.
--
-- Each frame is drawn ENTIRELY IN ROAD -- no buildings, nothing else. Three layers of the
-- same baked road piece over the grass field:
--   OUTLINE  the silhouette's rim, traced and laid as continuous runs
--   MAJOR    wide roads on a coarse grid, clipped to the shape
--   MINOR    narrow roads on a fine grid, clipped to the shape
-- so the shape fills with a road network of two widths rather than a painted area.
--
-- Nothing is per-cell. An earlier version gave every one of the 3072 cells its own part and
-- toggled visibility; with only roads to draw, the interior is better expressed as RUNS --
-- for each grid line, the maximal stretches of it that fall inside the shape, laid as one
-- stretched road each. That is a couple of hundred parts a frame instead of three thousand,
-- and every road is continuous with real kerbs rather than a chain of tiles.
--
-- The runs are recomputed whole each time the shape moves, like the outline: a run's extent
-- depends on cells far from any that changed, so there is no partial form of it.
--
-- The road is not a block wearing a road texture. BadAppleRoadTile bakes one genuine road
-- through RoadRenderer -- the same call the game makes for a road the player places, so it
-- has a real carriageway and real kerbs at the game's own widths and colours.
--
-- The outline is TRACED rather than tiled: BadAppleOutline walks the rim into ordered runs
-- and merges collinear steps, so a long straight edge becomes ONE stretched road instead of
-- thirty pieces butted together. The merge is exact, so the road stays ON the block boundary
-- and matches the blocky silhouette it outlines.
--
-- Slabs never change material: they are built black and only toggle Transparency, so the
-- whole per-frame cost is visibility plus a small number of stub clones.
--
-- Edges are recomputed INCREMENTALLY. A pixel flip can only change the classification of
-- itself and its four neighbours, and the stream hands over ~91 flips per frame, so a
-- frame costs a few hundred cell re-tests rather than a full 3072-cell edge pass.
--
-- Deliberately no Neon and no emissive anything -- the slabs are lit by the scene like real
-- road, which is the whole point of using the actual road material. The show does pin
-- ClockTime to early afternoon while it runs (and puts it back afterwards) so the picture
-- is not being played at midnight.
--
-- Placing REAL road pieces is not an option at this frame rate: each one is a server
-- round trip plus an EditableMesh bake (see RoadMeshView). These are plain slabs wearing
-- the same material, pre-built once and toggled -- visually the same thing, ~0.01 ms/frame.
--
-- Nothing in the city is touched. Stopping destroys one folder and hands the camera back.

local Lighting         = game:GetService("Lighting")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace        = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RoadConstants = require(ReplicatedStorage:WaitForChild("Road"):WaitForChild("RoadConstants"))
local BadAppleRoadTile = require(script.Parent:WaitForChild("BadAppleRoadTile"))
local BadAppleOutline = require(script.Parent:WaitForChild("BadAppleOutline"))
local Frames = require(ReplicatedStorage:WaitForChild("BadApple"):WaitForChild("BadAppleFrames"))
-- Resolved by NAME, not by position -- see the same note in AdminController: this bundle
-- is delivered into PlayerGui at runtime, so script.Parent.Parent is not PlayerScripts.
local PlayerScripts = game:GetService("Players").LocalPlayer:WaitForChild("PlayerScripts")
local FreeCamController = require(PlayerScripts:WaitForChild("Core"):WaitForChild("FreeCamController"))
local Settings = require(PlayerScripts:WaitForChild("Core"):WaitForChild("Settings"))

local W = Frames.WIDTH
local H = Frames.HEIGHT
local FRAME_DT = 1 / Frames.FPS

local FOLDER_NAME = "_BadApple"
-- The stage sits in clear airspace above the map rather than hunting for an empty patch of
-- ground: the city can be anywhere, and nothing is ever built this high.
local STAGE_Y     = 2500
-- One video pixel, in studs. This is NOT a free choice: a cell holds one full-width road
-- (carriageway + both sidewalks), and shrinking it below that squeezes the lane paint to
-- sub-stud widths. BadAppleRoadTile owns the number; at stock road dimensions it is 18,
-- making the 64x48 field 1152 x 864 studs.
local CELL        = BadAppleRoadTile.CELL
local SLAB_THICK  = 0.5
local GRASS_THICK = 2
local GRASS_PAD   = 1.5   -- grass field this many times the paved area, so you see field
local FIT_MARGIN  = 1.04  -- a little air around the picture in frame
local SHOW_CLOCK  = 14    -- early afternoon: long enough shadows to read, bright enough to see
-- Draw distance while the show runs. Both RoadMeshView and AssetLODView scale their LOD
-- ladder by Settings "renderDistance", and the camera sits hundreds of studs up, which is
-- deep enough into the ladder to drop lane paint. Pinning it high holds everything at full
-- detail for the duration; the player's own value is restored on Stop.
local SHOW_DRAW_DISTANCE = 40
-- A render tick that swallowed more than this many video frames is a hitch, not a slow
-- machine; skipping the catch-up stops a stall from snowballing into a fast-forward.
local MAX_CATCHUP = 4
local BUILD_BATCH = 400   -- slabs built between yields
local STUB_LIFT   = 0.02  -- road sits on the slab, not in it
-- Consecutive runs overlap at the corner they share. At equal height those overlaps are
-- coplanar, so the renderer picks a winner per pixel and the loser's KERB vanishes -- which
-- looks like some roads having sidewalks and others not, changing frame to frame. Giving
-- each piece its own tiny height step makes the winner deterministic. Eight steps is enough
-- to separate any overlapping pair, and 0.01 studs is invisible from hundreds of studs up.
local RUN_STAGGER = 0.01
local RUN_STAGGER_CYCLE = 8
-- Corner overshoot, as a fraction of the run's own length (capped at one road width). Raise
-- it if corners open into notches, lower it if short pieces visibly stack on each other.
local RUN_OVERSHOOT = 0.25

-- The paved area is centred on the stage, so these are fixed and rebuildStubs can map a
-- cell index straight to world position without carrying the layout around.
local ORIGIN_X = -W * CELL * 0.5
local ORIGIN_Z = -H * CELL * 0.5

-- The field is DARKENED grass, not the stock island green. The city that sits on it is pale
-- concrete, and measured against the stock green the two land at luminance 0.65 and 0.59 --
-- 0.07 apart, so the silhouette barely separates from its background and the whole video
-- turns to mush. Scaling the same hue down keeps it reading as grass while opening the gap
-- to roughly 0.4, which is what makes the shape legible from overhead.
local FIELD_DARKEN = 0.45
local GRASS_TINT = Color3.new(
	RoadConstants.ROUNDABOUT_ISLAND_COLOR.R * FIELD_DARKEN,
	RoadConstants.ROUNDABOUT_ISLAND_COLOR.G * FIELD_DARKEN,
	RoadConstants.ROUNDABOUT_ISLAND_COLOR.B * FIELD_DARKEN
)

-- Grid spacing, in cells. MINOR is the fine mesh of small streets; MAJOR is the coarse mesh
-- of wide ones. MAJOR must be a multiple of MINOR, or the big roads would sit off the grid
-- the small ones form and every crossing would be a near-miss.
local MINOR_EVERY = 2
local MAJOR_EVERY = 6
-- Small roads are the same baked piece narrowed on its own X, so their kerbs narrow with
-- them and they still read as road rather than as stripes.
local MINOR_WIDTH = 0.58

-- Which half of the picture becomes the drawn shape. false = the video's DARK pixels are
-- the shape. Bad Apple inverts itself constantly, so neither reading is "correct" -- flip
-- this if the negative reads better on the field.
local INVERT = false

-- _lit stores 1 for a BRIGHT pixel, so this is the value that counts as "inside the shape".
local SHAPE = if INVERT then 1 else 0

-- Per-cell band. EDGE is a FILL cell too -- it just also carries road on top.
local OUTSIDE, FILL, EDGE = 0, 1, 2

-- How far, in cells, the traced outline may sit off the true block boundary.
--
-- ZERO on purpose: only exactly collinear steps merge, so every road stays welded to the
-- block boundary and the outline is blocky, matching the fill. Measured against the real
-- video that costs run length -- 79 pieces a frame averaging 61 studs, versus 23 pieces
-- averaging 199 at tolerance 1.6 -- and short pieces overlap their neighbours more, because
-- the corner overshoot is a bigger fraction of a short piece. That overlap is the accepted
-- price of a blocky outline; RUN_OVERSHOOT is the dial for it.
local OUTLINE_TOL = 0
-- Bake a real half-cell section before stretching it to a traced run. This preserves the
-- full carriageway, kerb and sidewalk geometry instead of using a degenerate one-stud source.
local UNIT_REACH = CELL * 0.5

local BadAppleShow = {}

local _playing = false
local _building = false
local _folder: Folder? = nil
-- Current bright/dark state per pixel. Tracked here rather than read back off the slab:
-- the stream only says "this flipped", so we need to know what it flipped FROM, and a byte
-- read beats a property read a few thousand times a frame.
local _lit: buffer? = nil
-- Derived look per cell (EXTERIOR / OUTLINE / INTERIOR). Separate from _lit because the
-- look depends on the NEIGHBOURS, so it changes in places the video never flipped.
local _state: buffer? = nil
-- Cells whose classification might have moved this frame, plus a per-cell flag so a cell
-- touched from several sides is only re-tested once. Both reused across frames.
local _dirty: { number } = {}
local _dirtyCount = 0
local _dirtySeen: buffer? = nil
-- Cells whose band actually moved this frame, feeding the second (stub) pass.
local _changed: { number } = {}
-- Rim mask handed to the tracer, plus its scratch, plus the runs it returns. All reused.
local _rim: buffer? = nil
local _traceVisited: buffer? = nil
local _runs: { BadAppleOutline.Run } = {}
-- The road pieces currently laid, and the one bake they are all stretched clones of.
local _laid: { MeshPart } = {}
local _roadTemplate: MeshPart? = nil
-- The grid roads laid this frame, pooled exactly like the outline's.
local _gridLaid: { MeshPart } = {}
-- No junction patches. Squares of plain asphalt at every corner of the traced path landed
-- roughly every three cells, and being narrower than the road they never covered the kerbs
-- they existed to hide -- so they read as grey dots studded along the road instead of as
-- junctions. Runs overlapping at their shared corner carries the joint on its own.

local _player: Frames.Player? = nil
local _accum = 0
local _renderConn: RBXScriptConnection? = nil
local _escConn: RBXScriptConnection? = nil
local _camCF: CFrame? = nil
local _drawDistance: any = nil
-- Every lighting property the show overrode, with its previous value, restored in reverse.
local _lightSaved: { { inst: Instance, prop: string, value: any } } = {}
local _onStatus: ((string, boolean?) -> ())? = nil

local function report(text: string, danger: boolean?)
	local cb = _onStatus
	if cb then
		cb(text, danger)
	end
	if danger then
		warn("[BadApple] " .. text)
	else
		print("[BadApple] " .. text)
	end
end

-- ------------------------------------------------------------------- stage --

-- ------------------------------------------------------------ classification --

-- Off-grid reads as "not shape", so a silhouette running off the side of frame is still
-- given a road edge instead of letting bare paint touch the border.
local function isShape(lit: buffer, col: number, row: number): boolean
	if col < 0 or col >= W or row < 0 or row >= H then
		return false
	end
	return buffer.readu8(lit, row * W + col) == SHAPE
end

-- Decided by the cell and its four neighbours and nothing further out -- which is what
-- lets advance() re-test only a flipped cell's own neighbourhood.
local function stateAt(lit: buffer, idx: number): number
	local row = idx // W
	local col = idx % W
	if not isShape(lit, col, row) then
		return OUTSIDE
	end
	if isShape(lit, col - 1, row) and isShape(lit, col + 1, row)
		and isShape(lit, col, row - 1) and isShape(lit, col, row + 1)
	then
		return FILL
	end
	return EDGE
end

-- A MaterialVariant only binds to its own base material, so Material is always set BEFORE
-- the variant name -- assigning the variant first would leave it bound to the wrong base.
-- Only the INTERIOR is painted. A rim cell's slab is an axis-aligned square, but the road
-- laid over it is a band rotated to the run's direction, so on any diagonal stretch the
-- square's corners stick out past the road and the black visibly leaks over the edge. The
-- road is one cell wide and centred on those same rim cells, so it covers them itself --
-- leaving the rim unpainted removes the leak without opening a gap.
--
-- Lay the frame's outline: trace the rim into simplified runs, then put ONE stretched road
-- piece along each. The piece count moves slowly frame to frame, so the laid roads are kept
-- and rewritten in place; only the surplus is hidden, and only a shortfall clones.
local function layOutline()
	local state, rim, visited, folder, template = _state, _rim, _traceVisited, _folder, _roadTemplate
	if not (state and rim and visited and folder and template) then
		return
	end

	for idx = 0, W * H - 1 do
		buffer.writeu8(rim, idx, if buffer.readu8(state, idx) == EDGE then 1 else 0)
	end

	local count = BadAppleOutline.trace(rim, W, H, OUTLINE_TOL, visited, _runs)
	local y = STAGE_Y + SLAB_THICK + STUB_LIFT

	for i = 1, count do
		local r = _runs[i]
		local ax = ORIGIN_X + (r.ax + 0.5) * CELL
		local az = ORIGIN_Z + (r.az + 0.5) * CELL
		local bx = ORIGIN_X + (r.bx + 0.5) * CELL
		local bz = ORIGIN_Z + (r.bz + 0.5) * CELL
		local dx, dz = bx - ax, bz - az
		local len = math.sqrt(dx * dx + dz * dz)
		if len < 1e-3 then
			-- Degenerate run: a lone rim cell with no orthogonal rim neighbour, which is about
			-- a third of all pieces. It still needs a road or the outline has a hole, but a
			-- fixed orientation would leave a third of the outline pointing at nothing. Lay it
			-- along whichever axis the shape actually continues on, so it reads as part of the
			-- boundary rather than a stray stub.
			local col = math.floor(r.ax + 0.5)
			local row = math.floor(r.az + 0.5)
			local function solid(c: number, rw: number): number
				if c < 0 or c >= W or rw < 0 or rw >= H then
					return 0
				end
				return if buffer.readu8(state, rw * W + c) ~= OUTSIDE then 1 else 0
			end
			local horiz = solid(col - 1, row) + solid(col + 1, row)
			local vert = solid(col, row - 1) + solid(col, row + 1)
			len = CELL
			if horiz >= vert then
				dx, dz = CELL, 0
			else
				dx, dz = 0, CELL
			end
		end

		local road = _laid[i]
		if not road then
			road = template:Clone()
			_laid[i] = road
		end
		-- Overshoot so consecutive runs bury their join inside the corner instead of leaving
		-- a notch on the outside of every turn, capped as a FRACTION of the run so a short
		-- piece cannot be extended into its neighbour.
		local overshoot = math.min(RoadConstants.ROAD_WIDTH, len * RUN_OVERSHOOT)
		road.Size = Vector3.new(road.Size.X, road.Size.Y, len + overshoot)
		road.CFrame = CFrame.new(
			(ax + bx) * 0.5,
			y + (i % RUN_STAGGER_CYCLE) * RUN_STAGGER,
			(az + bz) * 0.5
		) * CFrame.Angles(0, math.atan2(dx, dz), 0)
		road.Parent = folder
	end

	-- Surplus from a busier frame: park it rather than destroy it, so the next busy frame
	-- costs a reparent instead of a clone.
	for i = count + 1, #_laid do
		local road = _laid[i]
		if road.Parent then
			road.Parent = nil
		end
	end
end

-- Fill the shape with a road network: for every grid line, the maximal stretches of it that
-- fall inside the shape, each laid as ONE stretched road. Wide on the coarse grid, narrow on
-- the fine one, so the interior reads as big roads and small roads rather than a lattice of
-- one gauge.
local function layGrid()
	local state, folder, template = _state, _folder, _roadTemplate
	if not (state and folder and template) then
		return
	end
	local baseW, baseH = template.Size.X, template.Size.Y
	local y = STAGE_Y + SLAB_THICK + STUB_LIFT
	local n = 0

	-- `yaw` is passed rather than derived from the endpoints: a run of a single cell has no
	-- direction to derive, and atan2(0, 0) would silently lay it along +Z regardless of which
	-- way its line actually runs.
	local function emit(ax: number, az: number, bx: number, bz: number, major: boolean, yaw: number)
		n += 1
		local road = _gridLaid[n]
		if not road then
			road = template:Clone()
			_gridLaid[n] = road
		end
		local dx, dz = bx - ax, bz - az
		-- A run from cell a to cell b covers b-a+1 WHOLE cells, so its length is the
		-- centre-to-centre distance plus one cell.
		local len = math.sqrt(dx * dx + dz * dz) + CELL
		road.Size = Vector3.new(baseW * (if major then 1 else MINOR_WIDTH), baseH, len)
		road.CFrame = CFrame.new(
			(ax + bx) * 0.5,
			-- Same staggering the outline uses: grid roads cross each other constantly, and
			-- coplanar crossings would fight over which kerb is drawn.
			y + (n % RUN_STAGGER_CYCLE) * RUN_STAGGER,
			(az + bz) * 0.5
		) * CFrame.Angles(0, yaw, 0)
		road.Parent = folder
	end

	local function inside(col: number, row: number): boolean
		return buffer.readu8(state, row * W + col) ~= OUTSIDE
	end

	-- The scan runs one past the end on purpose, so a run still open at the last cell is
	-- closed by the same branch that closes every other one.
	for row = 0, H - 1, MINOR_EVERY do
		local major = row % MAJOR_EVERY == 0
		local z = ORIGIN_Z + (row + 0.5) * CELL
		local start = -1
		for col = 0, W do
			local hit = col < W and inside(col, row)
			if hit and start < 0 then
				start = col
			elseif not hit and start >= 0 then
				emit(ORIGIN_X + (start + 0.5) * CELL, z, ORIGIN_X + (col - 0.5) * CELL, z,
					major, math.pi * 0.5)
				start = -1
			end
		end
	end

	for col = 0, W - 1, MINOR_EVERY do
		local major = col % MAJOR_EVERY == 0
		local x = ORIGIN_X + (col + 0.5) * CELL
		local start = -1
		for row = 0, H do
			local hit = row < H and inside(col, row)
			if hit and start < 0 then
				start = row
			elseif not hit and start >= 0 then
				emit(x, ORIGIN_Z + (start + 0.5) * CELL, x, ORIGIN_Z + (row - 0.5) * CELL,
					major, 0)
				start = -1
			end
		end
	end

	for i = n + 1, #_gridLaid do
		local road = _gridLaid[i]
		if road.Parent then
			road.Parent = nil
		end
	end
end

local function markDirty(idx: number)
	local seen = _dirtySeen
	if not seen or buffer.readu8(seen, idx) ~= 0 then
		return
	end
	buffer.writeu8(seen, idx, 1)
	_dirtyCount += 1
	_dirty[_dirtyCount] = idx
end

-- Two passes. Bands first, then roads: a cell's stub set reads its NEIGHBOURS' bands, so a
-- band change at c can move the road at c AND at each of c's four neighbours -- one ring
-- wider than the bands themselves propagate.
local function resolveDirty()
	local lit, state, seen = _lit, _state, _dirtySeen
	if not (lit and state and seen) then
		return
	end

	local changedCount = 0
	for i = 1, _dirtyCount do
		local idx = _dirty[i]
		buffer.writeu8(seen, idx, 0)
		local want = stateAt(lit, idx)
		if buffer.readu8(state, idx) ~= want then
			buffer.writeu8(state, idx, want)
			changedCount += 1
			_changed[changedCount] = idx
		end
	end
	_dirtyCount = 0

	-- The outline is retraced WHOLE whenever anything moved. Unlike the bands it is a global
	-- walk with no partial form -- a run's length depends on cells far from any that changed.
	-- A frame where no band moved (a still shot) skips it entirely.
	if changedCount > 0 then
		layOutline()
		-- Keep the silhouette as continuous, real road runs; no interior lattice.
	end
end

-- --------------------------------------------------------------------- stage --

-- Build the field and lay every slab. Slabs are created EXTERIOR and the true opening
-- frame is then established by one full resolve pass, so the starting look comes from the
-- same classifier as every later frame instead of a second copy of the rules.
local function buildStage(): Folder
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME

	local paveW, paveH = W * CELL, H * CELL

	local field = Instance.new("Part")
	field.Name = "Field"
	field.Anchored = true
	field.CanCollide = false
	field.CanQuery = false
	field.CanTouch = false
	field.CastShadow = false
	field.Material = Enum.Material.Grass
	field.Color = GRASS_TINT
	field.TopSurface = Enum.SurfaceType.Smooth
	field.BottomSurface = Enum.SurfaceType.Smooth
	field.Size = Vector3.new(paveW * GRASS_PAD, GRASS_THICK, paveH * GRASS_PAD)
	field.CFrame = CFrame.new(0, STAGE_Y - GRASS_THICK * 0.5, 0)
	field.Parent = folder

	-- ONE bake for the whole show, at unit length. Every traced run is a clone of it with
	-- Size.Z stretched to that run's length -- which is why the centre line is solid: a
	-- dashed one would show a different dash rhythm at every run length.
	_roadTemplate = BadAppleRoadTile.build(UNIT_REACH)

	_lit = buffer.create(W * H)
	_state = buffer.create(W * H)    -- all OUTSIDE, matching how the slabs are created
	_rim = buffer.create(W * H)
	_traceVisited = buffer.create(W * H)
	_dirtySeen = buffer.create(W * H)
	_dirtyCount = 0

	folder.Parent = Workspace

	-- Opening frame: the decoder starts from an all-zero bitmap, so classify the whole grid
	-- once against it.
	for idx = 0, W * H - 1 do
		markDirty(idx)
	end
	resolveDirty()

	return folder
end

-- ------------------------------------------------------------------ camera --

-- Straight down, north up: right = +X, up = -Z, so back = right x up = +Y and the look
-- vector is -Y. Row 0 is at low Z and column 0 at low X, which is exactly what this pose
-- puts at the top-left of the screen -- so the video is neither flipped nor mirrored.
local function parkCamera()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	_camCF = cam.CFrame

	local paveW, paveH = W * CELL, H * CELL
	local vp = cam.ViewportSize
	local aspect = if vp.Y > 0 then vp.X / vp.Y else 1
	local halfFov = math.tan(math.rad(cam.FieldOfView) * 0.5)
	local dist = math.max(paveH * 0.5 / halfFov, paveW * 0.5 / (halfFov * aspect)) * FIT_MARGIN

	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = CFrame.fromMatrix(Vector3.new(0, STAGE_Y + dist, 0), Vector3.xAxis, -Vector3.zAxis)
end

-- The city's grade is tuned for standing in a street, and none of it suits a flat field seen
-- from hundreds of studs up: the distant depth-of-field blurs the whole picture, the warm
-- haze washes the black out to grey and tints the road blue, and bloom puts a glow on
-- exactly the thing that is meant to have none. All of it goes back on Stop.
local function pushSaved(inst: Instance, prop: string)
	table.insert(_lightSaved, { inst = inst, prop = prop, value = (inst :: any)[prop] })
end

-- LOD is a separate system from the grade, but the same problem: it is distance-driven and
-- this camera is a long way up.
local function suspendLOD()
	_drawDistance = Settings.get("renderDistance")
	Settings.set("renderDistance", SHOW_DRAW_DISTANCE)
end

local function restoreLOD()
	if _drawDistance ~= nil then
		Settings.set("renderDistance", _drawDistance)
		_drawDistance = nil
	end
end

local function neutraliseLighting()
	table.clear(_lightSaved)
	pushSaved(Lighting, "ClockTime")
	Lighting.ClockTime = SHOW_CLOCK
	pushSaved(Lighting, "FogStart")
	pushSaved(Lighting, "FogEnd")
	Lighting.FogStart = 1e6
	Lighting.FogEnd = 1e6

	for _, e in Lighting:GetDescendants() do
		if e:IsA("Atmosphere") then
			pushSaved(e, "Density")
			pushSaved(e, "Haze")
			pushSaved(e, "Glare")
			e.Density = 0
			e.Haze = 0
			e.Glare = 0
		elseif e:IsA("DepthOfFieldEffect") or e:IsA("BloomEffect")
			or e:IsA("SunRaysEffect") or e:IsA("ColorCorrectionEffect")
		then
			pushSaved(e, "Enabled");
			(e :: any).Enabled = false
		end
	end
end

local function restoreLighting()
	-- Reverse order, so a property saved twice ends on its original value.
	for i = #_lightSaved, 1, -1 do
		local s = _lightSaved[i]
		-- An effect destroyed mid-show (a weather script swapping its grade) must not break
		-- the rest of the teardown.
		pcall(function()
			(s.inst :: any)[s.prop] = s.value
		end)
	end
	table.clear(_lightSaved)
end

local function restoreCamera()
	local cam = Workspace.CurrentCamera
	local cf = _camCF
	_camCF = nil
	if cam and cf then
		cam.CFrame = cf
	end
end

-- ---------------------------------------------------------------- playback --

local function advance(): boolean
	local p = _player
	if not p then
		return false
	end
	local flips = Frames.step(p)
	if not flips then
		return false
	end
	local lit = _lit
	if not lit then
		return false
	end
	-- The stream IS the change set. Flipping a pixel can only re-classify itself and its
	-- four neighbours, so those are all that get queued -- everything else is untouched.
	for _, idx in flips do
		buffer.writeu8(lit, idx, if buffer.readu8(lit, idx) == 0 then 1 else 0)
		markDirty(idx)
		local col = idx % W
		if col > 0 then markDirty(idx - 1) end
		if col < W - 1 then markDirty(idx + 1) end
		if idx >= W then markDirty(idx - W) end
		if idx < (H - 1) * W then markDirty(idx + W) end
	end
	resolveDirty()
	return true
end

function BadAppleShow.IsPlaying(): boolean
	return _playing
end

-- Unconditional teardown: a build that failed PART way through (tiles up, camera not yet
-- parked) never set _playing, and an early return here would strand the tile folder in
-- Workspace with no way to remove it short of a rejoin.
function BadAppleShow.Stop()
	local was = _playing
	_playing = false

	if _renderConn then
		_renderConn:Disconnect()
		_renderConn = nil
	end
	if _escConn then
		_escConn:Disconnect()
		_escConn = nil
	end

	FreeCamController.setSuspended(false)
	restoreCamera()
	restoreLighting()
	restoreLOD()

	if _folder then
		_folder:Destroy()
		_folder = nil
	end
	-- Roads parented into the folder died with it, but surplus pieces are parked unparented
	-- and would leak.
	for _, m in _laid do
		m:Destroy()
	end
	table.clear(_laid)
	for _, m in _gridLaid do
		m:Destroy()
	end
	table.clear(_gridLaid)
	table.clear(_runs)
	if _roadTemplate then
		_roadTemplate:Destroy()
		_roadTemplate = nil
	end

	_lit = nil
	_state = nil
	_rim = nil
	_traceVisited = nil
	_dirtySeen = nil
	table.clear(_dirty)
	table.clear(_changed)
	_dirtyCount = 0
	_player = nil
	_accum = 0
	if was then
		report("Stopped.")
	end
end

function BadAppleShow.Start(onStatus: ((string, boolean?) -> ())?)
	if _playing or _building then
		return
	end
	_onStatus = onStatus
	_building = true

	task.spawn(function()
		local ok, err = pcall(function()
			local p = Frames.newPlayer()
			if not p then
				report("No frame data -- ReplicatedStorage.BadApple has no Data holders.", true)
				return
			end

			report("Baking building proxies and laying out the city...")
			_player = p
			_folder = buildStage()
			parkCamera()
			neutraliseLighting()
			suspendLOD()
			FreeCamController.setSuspended(true)

			_accum = 0
			_playing = true
			report(string.format("Playing -- a %dx%d city on a %d x %d stud field. Esc to stop.",
				W, H, W * CELL, H * CELL))

			-- Deliberately ignores `processed`: Escape is normally eaten by the Roblox menu,
			-- and this is the one key the player needs to get their camera back.
			_escConn = UserInputService.InputBegan:Connect(function(input: InputObject)
				if input.KeyCode == Enum.KeyCode.Escape then
					BadAppleShow.Stop()
				end
			end)

			_renderConn = RunService.RenderStepped:Connect(function(dt: number)
				if not _playing then
					return
				end
				_accum += dt
				local steps = 0
				while _accum >= FRAME_DT do
					_accum -= FRAME_DT
					steps += 1
					if steps > MAX_CATCHUP then
						_accum = 0
						break
					end
					if not advance() then
						task.defer(BadAppleShow.Stop)
						return
					end
				end
			end)
		end)
		_building = false
		if not ok then
			report(`Failed: {err}`, true)
			BadAppleShow.Stop()
		end
	end)
end

function BadAppleShow.Toggle(onStatus: ((string, boolean?) -> ())?)
	if _playing then
		_onStatus = onStatus
		BadAppleShow.Stop()
	else
		BadAppleShow.Start(onStatus)
	end
end

return BadAppleShow
