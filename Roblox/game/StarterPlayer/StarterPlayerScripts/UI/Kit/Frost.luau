--!strict
-- Kit.Frost
-- Frosted glass behind UI panels, built the way the Roblox community solved it
-- (devforum "Gaussian blur filter for UI", and every acrylic/glassmorphism
-- module since): a nearly-invisible Glass plane glued to the camera behind the
-- panel's screen rect, plus a near-field DepthOfFieldEffect. Glass composites
-- what is behind it at the PANE's depth, so DoF -- which blurs by depth --
-- blurs that rect and leaves the rest of the world sharp. Roblox has no UI
-- blur; this is the standard stand-in.
--
-- Unlike the usual community version (one rect pane for everything), each pane
-- is an exact rounded-rect mesh matching its panel's outline: the rect's
-- aspect and its RENDERED corner radius (read from the panel's UICorner, with
-- any ancestor UIScale -- HudScale -- applied). A capsule gets a true stadium,
-- a circular chip a true circle, a panel its precise corner radius. Meshes are
-- built per distinct shape, baked to static content with
-- CreateDataModelContentAsync, and the EditableMesh destroyed immediately --
-- live EMs are capped at ~8 on the client and a HUD has more shapes than that.
--
-- Two things that are easy to get wrong, both learned the hard way here:
--
--  * The pane must be nearly INVISIBLE (TRANSPARENCY ~0.95). It is a spacer
--    that gives DoF a depth to work with, not a tint. A visibly dark pane
--    reads as a murky slab and makes the inset below show up as a seam.
--  * The surface must be FLAT. Jittering vertices so glass refraction scatters
--    is the other well-known frosted trick, but refraction is a lens: it warps
--    into ripples rather than blurring. DoF does the blurring.
--
-- Known limits of the technique, per the same sources:
--  * Needs graphics quality high enough for glass refraction. Lower settings
--    just see nothing -- hence the player toggle.
--  * DoF bleeds past the pane by a fixed screen-space radius, so the pane is
--    trimmed by that radius (EDGE_FRAC) and elements thinner than it get no
--    pane at all -- there is no pane size that frosts a 20px pill cleanly.
--  * One DepthOfFieldEffect is active at a time, so this and the scene's own
--    depth-of-field (CityBuild_DistantDepth, Ultra preset) are exclusive.
--
-- Panes are repositioned from the camera's own CFrame-changed signal -- it
-- fires synchronously the moment FreeCamController writes the camera, same
-- frame, so panes can never trail a fast camera (a render-step binding races
-- the camera controller's plain RenderStepped connection). A Last-priority
-- render step also runs for gui-rect changes (panel tweens, layout).
-- Effective visibility walks the ancestor chain (every GuiObject.Visible +
-- the ScreenGui.Enabled). The "frostedGlass" setting turns the system off.

local RunService = game:GetService("RunService")
local AssetService = game:GetService("AssetService")
local GuiService = game:GetService("GuiService")
local Lighting = game:GetService("Lighting")

local Settings = require(script.Parent.Parent.Parent.Core.Settings)

local Frost = {}

-- Panes ride as close to the camera as they can get. BLUR_NEAR has to clear the
-- deepest one, and every stud of THAT is world geometry that blurs when the
-- camera comes near it -- which is the whole cost of this technique. A near
-- pane is free: it is screen-projected, so it just gets smaller in world units,
-- and MeshPart has no minimum size (measured: 0.005 studs holds exactly).
-- FROST STRENGTH LIVES HERE. The blur a pane gets is how deep it sits below
-- BLUR_NEAR: roughly 1 - DIST/BLUR_NEAR. At 0.21 of 0.55 that is ~60%, a clear
-- frost. Raise DIST toward BLUR_NEAR for a subtler one, lower it for a heavier
-- one (0.15 is about the floor -- the camera's near plane is 0.1). Whatever you
-- pick, EDGE_FRAC has to follow it: the blur's feather widens with strength.
local DIST = 0.21       -- studs in front of the camera
-- Per-pane depth stagger so overlapping panes never z-fight.
local DEPTH_STEP = 0.008
local DEPTH_SPREAD = 0.08 -- stagger wraps here: 10 distinct depths, 0.08 studs total
local THICKNESS = 0.02  -- pane depth in studs
-- A perfectly flat mesh has zero extent on Z and MeshPart.Size cannot scale a
-- zero extent, so a pane is two parallel faces this far apart. Both faces stay
-- FLAT. Size.Z stretches this 0.001 extent up to THICKNESS (~20x) while the
-- rect scales DOWN (~0.03x), so any per-vertex Z wobble comes back ~700x
-- exaggerated -- a washboard of glass in front of the lens, which is what used
-- to smear the panes. Never alternate vertex Z to fake the extent.
local NEAR_FLAT = 0.0005
local CORNER_SEGS = 8   -- arc segments per corner; a full circle is a 32-gon
local TRANSPARENCY = 0.95
local TINT = Color3.fromRGB(255, 255, 255)
-- The near-field DoF kernel bleeds PAST the pane, so a pane cut to the panel's
-- rect halos well outside it. The pane is trimmed by the bleed radius instead,
-- which puts the blur's own edge on the panel's edge. Measured against a ruler
-- rect at BLUR = 1: ~14px on a 767px-tall viewport. The kernel is screen-space,
-- so this is a fraction of viewport height, not a pixel count -- re-measure it
-- if BLUR or BLUR_NEAR move, because the bleed tracks both.
local EDGE_FRAC = 0.012
-- Pane left per axis after the trim. Under this the element is smaller than its
-- own halo and cannot be frosted cleanly at any size, so it gets no pane and
-- keeps Glass's flat fill on its own -- which is what pills, chips and tab
-- rules were doing wrong: too thin to trim, so they bled on every side.
local MIN_SPAN = 2
-- Frost strength. Maxed because the panes now sit shallower into the near
-- field than they used to, and the near blur ramps up with depth into it.
local BLUR = 1          -- DepthOfFieldEffect.NearIntensity
-- Studs: nearer than this blurs. Clears the deepest pane (DIST + DEPTH_SPREAD
-- = 0.43) and nothing more. World geometry inside this radius blurs too -- DoF
-- cannot tell it from a pane -- so this is the knob that decides how close the
-- camera may get to a road before the road goes soft.
local BLUR_NEAR = 0.55
-- A rect must hold this long before its mesh is (re)built, so a size tween
-- costs one bake at its settled shape, not one per frame along the way.
local SETTLE = 0.12
local STEP_NAME = "FrostPanes"

type Entry = {
	gui: GuiObject,
	corner: UICorner?,
	pane: MeshPart?,
	depth: number,
	radius: number,
	scale: number,
	lastSize: Vector2,
	key: string?,     -- shape of the current pane's mesh
	wantKey: string?, -- shape the rect currently calls for
	wantAspect: number,
	wantRf: number,
	wantAt: number,   -- os.clock() when wantKey is old enough to build
}

local _entries: { Entry } = {}
local _bound = false
local _inited = false
local _enabled = true
local _nextDepth = 0
local _lastEdge = -1
local _camConn: RBXScriptConnection? = nil
local _folder: Folder? = nil
local _dof: DepthOfFieldEffect? = nil

-- Baked pane templates by shape key ("aspect_radiusFraction", quantized).
-- ponytail: cached forever -- a resize mints new keys and orphans old
-- templates. They are tiny unparented MeshParts; evict by refcount if a
-- session ever accumulates hundreds.
local _shapes: { [string]: MeshPart } = {}
local _pending: { [string]: boolean } = {}
local _queue: { { key: string, aspect: number, rf: number } } = {}
local _working = false

-- The blur itself. Near field only: FarIntensity 0 keeps the city sharp, and
-- the in-focus band starts past BLUR_NEAR so nothing but the panes is close
-- enough to soften.
-- Adopt whatever UIFrostDepth is already in Lighting instead of stacking
-- another, and destroy the spares. Only ONE DepthOfFieldEffect renders and the
-- engine's pick between duplicates is arbitrary, so a leaked one -- from an
-- earlier session, or one saved into the place -- silently decides the frost,
-- carrying its own BLUR_NEAR with it. Three had accumulated in the place file,
-- one of them focused 3 studs out, which blurred world geometry metres from the
-- camera and made the frost look different every run.
local function depthEffect(): DepthOfFieldEffect
	if _dof and (_dof :: DepthOfFieldEffect).Parent then return _dof :: DepthOfFieldEffect end
	local found: DepthOfFieldEffect? = nil
	for _, e in Lighting:GetChildren() do
		if e:IsA("DepthOfFieldEffect") and e.Name == "UIFrostDepth" then
			if found then e:Destroy() else found = e end
		end
	end
	local d = found or Instance.new("DepthOfFieldEffect")
	d.Name = "UIFrostDepth"
	d.FarIntensity = 0
	d.NearIntensity = BLUR
	d.FocusDistance = 100
	d.InFocusRadius = 100 - BLUR_NEAR
	d.Enabled = false
	d.Parent = Lighting
	_dof = d
	return d
end

-- Panes live in a workspace folder (not under the camera) so a camera swap
-- never destroys them.
local function paneFolder(): Folder
	local f = _folder
	if f and f.Parent then return f end
	f = Instance.new("Folder")
	f.Name = "UIFrostPanes"
	f.Parent = workspace
	_folder = f
	return f
end

-- Unit quad, one flat face at depth z: square-cornered rects skip the arcs.
local function addQuad(em: EditableMesh, z: number)
	local a = em:AddVertex(Vector3.new(-0.5, -0.5, z))
	local b = em:AddVertex(Vector3.new(0.5, -0.5, z))
	local c = em:AddVertex(Vector3.new(0.5, 0.5, z))
	local d = em:AddVertex(Vector3.new(-0.5, 0.5, z))
	em:AddTriangle(a, b, c)
	em:AddTriangle(a, c, d)
end

-- Rounded rect, one flat face at depth z, height 1, width `aspect`, corner
-- radius `rf` (fraction of height, pre-clamped to a half-side). rf = min side
-- / 2 degenerates the straight runs and yields an exact capsule or circle --
-- the coincident arc endpoints are distinct vertex ids, so the zero-area fan
-- triangles between them are legal and render nothing.
local function addRoundedRect(em: EditableMesh, aspect: number, rf: number, z: number)
	local hw, hh = aspect / 2, 0.5
	local r = math.min(rf, hw, hh)
	local centre = em:AddVertex(Vector3.new(0, 0, z))
	local ring: { number } = {}
	local corners = {
		{ hw - r, hh - r, 0 },
		{ -(hw - r), hh - r, math.pi * 0.5 },
		{ -(hw - r), -(hh - r), math.pi },
		{ hw - r, -(hh - r), math.pi * 1.5 },
	}
	for _, c in corners do
		for s = 0, CORNER_SEGS do
			local t = c[3] + (s / CORNER_SEGS) * math.pi * 0.5
			table.insert(ring, em:AddVertex(Vector3.new(
				c[1] + math.cos(t) * r,
				c[2] + math.sin(t) * r,
				z)))
		end
	end
	for i = 1, #ring do
		local n = if i == #ring then 1 else i + 1
		em:AddTriangle(centre, ring[i], ring[n])
	end
end

-- Build one shape: EditableMesh -> bake to static Content -> MeshPart, then
-- destroy the EM so it never counts against the client Editable* budget. If
-- the bake path fails the EM stays alive backing the part -- degraded but
-- visible. Yields; only the worker below calls it.
local function buildShape(aspect: number, rf: number): MeshPart?
	local ok, part = pcall(function()
		local em = AssetService:CreateEditableMesh()
		if rf < 0.005 then
			addQuad(em, NEAR_FLAT)
			addQuad(em, -NEAR_FLAT)
		else
			addRoundedRect(em, aspect, rf, NEAR_FLAT)
			addRoundedRect(em, aspect, rf, -NEAR_FLAT)
		end
		local live = Content.fromObject(em)
		local res, baked = AssetService:CreateDataModelContentAsync(live)
		local p: MeshPart
		if res == Enum.CreateContentResult.Success and baked then
			p = AssetService:CreateMeshPartAsync(baked)
			em:Destroy()
		else
			p = AssetService:CreateMeshPartAsync(live)
		end
		p.Name = "FrostPane"
		p.Material = Enum.Material.Glass
		p.DoubleSided = true
		p.Transparency = TRANSPARENCY
		p.Color = TINT
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		return p
	end)
	if ok then return part end
	warn("[Frost] shape build failed: " .. tostring(part))
	return nil
end

-- One serial worker drains the queue so at most one EM is alive at a time.
-- On failure the key stays pending through a backoff, then clears so the
-- update loop's next request retries it.
local function requestShape(key: string, aspect: number, rf: number)
	if _shapes[key] or _pending[key] then return end
	_pending[key] = true
	table.insert(_queue, { key = key, aspect = aspect, rf = rf })
	if _working then return end
	_working = true
	task.spawn(function()
		while #_queue > 0 do
			local job = table.remove(_queue, 1)
			local part = buildShape(job.aspect, job.rf)
			if part then
				_shapes[job.key] = part
			else
				task.wait(2)
			end
			_pending[job.key] = nil
		end
		_working = false
	end)
end

-- gui visible on screen: every ancestor GuiObject visible + ScreenGui enabled.
local function isShown(gui: GuiObject): boolean
	if gui.AbsoluteSize.X < 4 or gui.AbsoluteSize.Y < 4 then return false end
	local node: Instance? = gui
	while node do
		if node:IsA("GuiObject") then
			if not node.Visible then return false end
		elseif node:IsA("ScreenGui") then
			return node.Enabled
		end
		node = node.Parent
	end
	return false
end

-- Accumulated UIScale over the ancestor chain (HudScale lives on the
-- ScreenGui itself, so the walk includes it). UICorner offsets are design px;
-- AbsoluteSize is real px; this converts the former to the latter. Only runs
-- when a rect changes size, never per frame.
local function accumScale(gui: GuiObject): number
	local scale = 1
	local node: Instance? = gui
	while node do
		local s = node:FindFirstChildOfClass("UIScale")
		if s then scale *= s.Scale end
		if node:IsA("LayerCollector") then break end
		node = node.Parent
	end
	return scale
end

local function update()
	local cam = workspace.CurrentCamera
	if not cam then return end
	local vp = cam.ViewportSize
	if vp.X < 1 or vp.Y < 1 then return end
	local inset = GuiService:GetGuiInset()
	local tanHalf = math.tan(math.rad(cam.FieldOfView) / 2)
	local now = os.clock()
	-- Viewport-relative, so a window resize re-shapes every pane once.
	local edge = vp.Y * EDGE_FRAC
	local edgeChanged = edge ~= _lastEdge
	_lastEdge = edge
	for i = #_entries, 1, -1 do
		local e = _entries[i]
		if not e.gui:IsDescendantOf(game) then
			if e.pane then (e.pane :: MeshPart):Destroy() end
			table.remove(_entries, i)
			continue
		end
		if not isShown(e.gui) then
			if e.pane then (e.pane :: MeshPart).Parent = nil end
			continue
		end
		local size = e.gui.AbsoluteSize
		-- Trim by the bleed so the blur stops at the panel's edge.
		local w = size.X - edge * 2
		local h = size.Y - edge * 2
		if w < MIN_SPAN or h < MIN_SPAN then
			if e.pane then (e.pane :: MeshPart).Parent = nil end
			continue
		end
		-- Shape bookkeeping only when the rect changes: this loop also runs on
		-- every camera move, and the key is a string.
		if size ~= e.lastSize or edgeChanged then
			e.lastSize = size
			e.scale = accumScale(e.gui)
			local minSide = math.min(size.X, size.Y)
			-- The radius the player actually sees: the gui's UICorner (scale
			-- resolves against the short side, offset is design px scaled by
			-- HudScale), clamped the way the renderer clamps it. Falls back to
			-- the radius passed to attach for corner-less guis.
			local cr = e.corner
			local rpx = if cr and cr.Parent
				then cr.CornerRadius.Scale * minSide + cr.CornerRadius.Offset * e.scale
				else e.radius * e.scale
			rpx = math.min(rpx, minSide / 2)
			local aspect = w / h
			local rf = math.min(math.max(rpx - edge, 0) / h, 0.5, aspect / 2)
			local key = string.format("%.2f_%.3f", aspect, rf)
			if key ~= e.wantKey then
				e.wantKey = key
				e.wantAspect = aspect
				e.wantRf = rf
				e.wantAt = now + SETTLE
			end
		end
		-- Swap in the exact-shape pane once the rect has settled and its mesh
		-- is baked. Until then the previous pane keeps covering the rect --
		-- stretched, corners briefly off-round, which beats a blur gap.
		local wantKey = e.wantKey
		if wantKey and wantKey ~= e.key and now >= e.wantAt then
			local tpl = _shapes[wantKey]
			if tpl then
				if e.pane then (e.pane :: MeshPart):Destroy() end
				e.pane = tpl:Clone()
				e.key = wantKey
			else
				requestShape(wantKey, e.wantAspect, e.wantRf)
			end
		end
		local pane = e.pane
		if not pane then continue end
		local sg = e.gui:FindFirstAncestorOfClass("ScreenGui")
		local guiInset = if sg and sg.IgnoreGuiInset then Vector2.zero else inset
		local pos = e.gui.AbsolutePosition + guiInset
		local d = DIST + e.depth
		local worldH = 2 * d * tanHalf
		local worldW = worldH * vp.X / vp.Y
		local cx = (pos.X + size.X / 2) / vp.X - 0.5
		local cy = (pos.Y + size.Y / 2) / vp.Y - 0.5
		pane.Size = Vector3.new(w / vp.X * worldW, h / vp.Y * worldH, THICKNESS)
		pane.CFrame = cam.CFrame * CFrame.new(cx * worldW, -cy * worldH, -d)
		if not pane.Parent then pane.Parent = paneFolder() end
	end
end

-- Reposition the instant the camera moves (synchronous, same frame).
local function bindCamera()
	if _camConn then
		_camConn:Disconnect()
		_camConn = nil
	end
	local cam = workspace.CurrentCamera
	if cam then
		_camConn = cam:GetPropertyChangedSignal("CFrame"):Connect(update)
	end
end

local function setBound(on: boolean)
	if on == _bound then return end
	_bound = on
	if on then
		depthEffect().Enabled = true
		RunService:BindToRenderStep(STEP_NAME, Enum.RenderPriority.Last.Value, update)
		bindCamera()
	else
		if _dof then (_dof :: DepthOfFieldEffect).Enabled = false end
		RunService:UnbindFromRenderStep(STEP_NAME)
		if _camConn then
			_camConn:Disconnect()
			_camConn = nil
		end
		for _, e in _entries do
			if e.pane then (e.pane :: MeshPart).Parent = nil end
		end
	end
end

local function ensureInit()
	if _inited then return end
	_inited = true
	_enabled = Settings.get("frostedGlass") ~= false
	Settings.onChanged("frostedGlass", function(v)
		_enabled = v ~= false
		setBound(_enabled and #_entries > 0)
	end)
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		if _bound then bindCamera() end
	end)
end

-- Glues a frost pane behind `gui`'s screen rect whenever it is effectively
-- visible. The pane's mesh is an exact match for the rect's outline: aspect
-- and corner radius, read from the gui's UICorner (present by the time
-- Glass.apply calls this); `radius` is the fallback for guis without one.
-- Never yields (meshes bake in a background worker; panes appear a beat after
-- the rect settles). Returns a detach function (optional -- destroyed guis
-- self-clean).
function Frost.attach(gui: GuiObject, radius: number?): () -> ()
	ensureInit()
	local entry: Entry = {
		gui = gui,
		corner = gui:FindFirstChildOfClass("UICorner"),
		pane = nil,
		depth = _nextDepth,
		radius = radius or 0,
		scale = 1,
		lastSize = Vector2.new(-1, -1),
		key = nil,
		wantKey = nil,
		wantAspect = 0,
		wantRf = 0,
		wantAt = 0,
	}
	_nextDepth = (_nextDepth + DEPTH_STEP) % DEPTH_SPREAD
	table.insert(_entries, entry)
	setBound(_enabled)
	return function()
		local idx = table.find(_entries, entry)
		if idx then table.remove(_entries, idx) end
		if entry.pane then (entry.pane :: MeshPart):Destroy() end
	end
end

return Frost
