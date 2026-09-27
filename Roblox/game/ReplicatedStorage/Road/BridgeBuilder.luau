--!strict

-- Parametric bridge geometry.
--
-- Nothing here is authored for one bridge. The cross-section comes from a
-- RoadTypeCatalog spec, so a bridge carrying an Avenue is exactly as wide as the
-- Avenue it joins; the span layout comes from the requested length; the structural
-- depths come from the spans and from the room actually available under the deck.
--
-- Human-scale items -- barrier heights, railing heights -- are authored in METRES and
-- converted through RoadConstants.STUD_TO_METER, so they ride WORLD_SCALE with the
-- rest of the world. A railing is 1.07 m whether it guards a 40-stud footbridge or a
-- 900-stud viaduct; only the structure scales with span.
--
-- Two entry points:
--   build()                -- a standalone bridge model
--   addElevatedStructure() -- pillars under an already-rendered elevated road
-- Both share the same solvers, so a hand-placed bridge and an elevated road the player
-- draws are the same object built two ways.

local RC = require(script.Parent.RoadConstants)
local Catalog = require(script.Parent.RoadTypeCatalog)

local BridgeBuilder = {}

local SPM = 1 / RC.STUD_TO_METER

local function m(metres: number): number
	return metres * SPM
end

-- Authored in metres. AASHTO LRFD 13.8.1 (pedestrian rail 42 in) and 13.7.3
-- (traffic barrier 32 in, TL-3/TL-4).
local DIM = {
	trafficBarrierH = 0.81,
	trafficBarrierT = 0.40,
	medianBarrierH  = 1.05,
	pedRailH        = 1.07,
	screenH         = 1.40,
	deckSlabT       = 0.60,
	surfaceT        = 0.06,
	shoulderStrip   = 0.60,
	lampH           = 4.50,
	lampSpacing     = 20.0,
	railPostSpacing = 4.00,
	scupperSpacing  = 12.0,
	screenMinDrop   = 4.00,
	girderRatio     = 20.0, -- steel plate girder depth = span / this
}

local STEEL = Color3.fromRGB(112, 122, 132)

-- == helpers ==============================================================

-- round = a cylinder instead of a box. A cylinder Part's axis runs along its own X, so
-- callers stand one upright with a quarter turn about Z.
local function part(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material?, query: boolean?, round: boolean?): Part
	local p = Instance.new("Part")
	if round then p.Shape = Enum.PartType.Cylinder end
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Anchored = true
	p.Color = color
	p.Material = mat or Enum.Material.Concrete
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanTouch = false
	-- Structure below the deck must stay invisible to the placement/nav rays, which
	-- expect to hit the road surface. Only load-bearing piers answer queries.
	p.CanQuery = query == true
	p.CanCollide = query == true
	p.Parent = parent
	return p
end

-- == pier =================================================================

-- Pillars across one pier. ONE under a normal deck -- a single round column is what an
-- urban viaduct actually stands on, and its small footprint is what lets a support thread
-- between the lanes of a road it flies over. More only once the deck grows too wide for
-- one to carry it.
local function stemOffsets(deckHalf: number): { number }
	local n = math.max(1, math.round(deckHalf * 2 / m(11)))
	if n < 2 then return { 0 } end
	local span = deckHalf * 2 - m(5.5)
	local out = {}
	for i = 1, n do
		table.insert(out, -span / 2 + (i - 1) * span / (n - 1))
	end
	return out
end

-- One pier: round pillars from grade straight up to the deck soffit, and nothing else --
-- no cap beam, no capital, no footing, no bearings. Drawn the same way whether it carries
-- a hand-placed bridge or a road the player elevated.
--
-- f      -- pier frame: origin on the deck SOFFIT at the pier's point on the centreline,
--           +X ACROSS the deck, +Y up, LookVector along the road.
-- height -- soffit height above grade, so grade sits at local Y = -height.
-- legs   -- lateral offsets that actually get a pillar. Short of the full set when the
--           ground under one is a road, so a pier may straddle what it crosses.
local function drawPier(parent: Instance, f: CFrame, height: number, legs: { number })
	if height < m(0.5) or #legs == 0 then return end
	-- A lone pillar carries the whole deck where a pair shares it, so it is drawn heavier.
	local colD = math.clamp(height / 9, m(0.8), m(2.0)) * (if #legs < 2 then 1.5 else 1.0)
	local upright = CFrame.Angles(0, 0, math.rad(90))
	for _, off in legs do
		local col = part(parent, "ElevationPillar", Vector3.new(height, colD, colD),
			f * CFrame.new(off, -height / 2, 0) * upright, RC.ELEVATED_PILLAR_COLOR, nil, true, true)
		col.CastShadow = true
	end
end

-- == solvers ==============================================================

-- Girder depth wants span/20, but can never exceed the room between the deck soffit
-- and the ground -- that is what makes a low crossing use more, shorter spans instead
-- of beams that punch through the terrain.
local function girderDepthFor(span: number, avail: number): number
	local want = math.clamp(span / DIM.girderRatio, m(0.5), m(3.0))
	return math.clamp(want, m(0.3), math.max(avail - m(0.3), m(0.3)))
end

-- Lateral girder offsets about the deck centre. Count follows deck width so a wide
-- deck never cantilevers its edges off two beams.
local function girderOffsets(deckHalf: number, maxN: number?): { number }
	local n = math.clamp(math.floor(deckHalf * 2 / m(4) + 0.5), 2, maxN or 7)
	local inset = math.min(m(1), deckHalf * 0.15)
	local out = {}
	local span = (deckHalf - inset) * 2
	for i = 0, n - 1 do
		table.insert(out, -(deckHalf - inset) + i * (span / (n - 1)))
	end
	return out
end

-- Spans are capped by ELEVATED_PILLAR_SPACING, so a bridge's pier rhythm matches the
-- pillar rhythm of the game's own elevated roads, and by the structural depth
-- available: a low deck gets more, shorter spans.
local function planSpans(length: number, opts, availDepth: number)
	local depthSpan = math.max(availDepth, 0) * DIM.girderRatio
	local maxSpan = math.max(math.min(RC.ELEVATED_PILLAR_SPACING, depthSpan), m(8))
	local n = math.max(1, math.ceil(length / maxSpan))
	local span = length / n
	local piers = {}
	for i = 1, n - 1 do
		table.insert(piers, -length / 2 + i * span)
	end
	return { piers = piers, span = span, maxSpan = span, spanCount = n }
end

-- A sidewalk-less spec (highway, alley, busway, rail) gets the game's own W-beam
-- guardrail at the deck edge, exactly as an elevated road of that type renders.
-- Everything else gets sidewalks behind a concrete traffic barrier plus a pedestrian rail.
local function planSection(spec, opts)
	local cw = spec.width
	local half = cw / 2
	local hasWalk = not spec.noSidewalk and not spec.isRail
	local walkW = hasWalk and RC.SIDEWALK_WIDTH or 0
	local barrierT = hasWalk and m(DIM.trafficBarrierT) or 0
	local edge = hasWalk and 0 or m(DIM.shoulderStrip)

	local medianW = 0
	if spec.median and spec.medianWidth then
		medianW = spec.medianWidth
	elseif opts and opts.median and not spec.oneWay and spec.laneCount >= 4 then
		medianW = m(1.8)
	end

	local sec = {
		carriageHalf = half,
		deckHalf = half + barrierT + walkW + edge,
		hasWalk = hasWalk,
		walkW = walkW,
		barrierT = barrierT,
		medianW = medianW,
		barrierZ = half + barrierT / 2,
		walkZ = half + barrierT + walkW / 2,
		laneCount = spec.laneCount,
		laneW = (cw - medianW) / math.max(spec.laneCount, 1),
	}
	sec.railZ = sec.deckHalf - m(0.15)
	return sec
end

BridgeBuilder.deckHalfFor = function(spec): number
	return planSection(spec, nil).deckHalf
end

local function laneBoundaries(spec, sec)
	local out = {}
	local lanes = sec.laneCount
	if sec.medianW > 0 then
		local per = math.floor(lanes / 2)
		for _, side in { -1, 1 } do
			for i = 1, per - 1 do
				table.insert(out, { z = side * (sec.medianW / 2 + i * sec.laneW), centre = false })
			end
		end
	else
		for i = 1, lanes - 1 do
			table.insert(out, {
				z = -sec.carriageHalf + i * sec.laneW,
				centre = (not spec.oneWay) and (i * 2 == lanes),
			})
		end
	end
	return out
end

-- == standalone bridge builders ===========================================

local function buildDeck(model, spec, sec, plan, g)
	local L, deckTop = plan.length, plan.deckY
	local slabT = m(DIM.deckSlabT)
	local slabTop = deckTop - m(DIM.surfaceT)
	local sub = Instance.new("Model"); sub.Name = "Deck"; sub.Parent = model

	part(sub, "DeckSlab", Vector3.new(L, slabT, sec.deckHalf * 2),
		g * CFrame.new(0, slabTop - slabT / 2, 0), RC.SIDEWALK_COLOR, nil, true)

	local surf = part(sub, "Carriageway", Vector3.new(L, m(DIM.surfaceT), sec.carriageHalf * 2),
		g * CFrame.new(0, deckTop - m(DIM.surfaceT) / 2, 0), spec.surfaceColor,
		spec.isRail and Enum.Material.Slate or Enum.Material.Asphalt, true)
	if not spec.isRail then
		pcall(function() surf.MaterialVariant = "RoadAsphalt" end)
	end

	if sec.hasWalk then
		for _, s in { -1, 1 } do
			part(sub, "Sidewalk", Vector3.new(L, m(DIM.surfaceT), sec.walkW),
				g * CFrame.new(0, deckTop - m(DIM.surfaceT) / 2, s * sec.walkZ), RC.SIDEWALK_COLOR, nil, true)
		end
	end
	return slabTop - slabT
end

local function buildGirders(model, sec, plan, g, soffitTop)
	local depth = girderDepthFor(plan.span, soffitTop - plan.groundY)
	local zs = girderOffsets(sec.deckHalf)
	local sub = Instance.new("Model"); sub.Name = "Girders"; sub.Parent = model
	local midY = soffitTop - depth / 2
	for _, z in zs do
		part(sub, "GirderWeb", Vector3.new(plan.length, depth, m(0.25)), g * CFrame.new(0, midY, z), STEEL, Enum.Material.Metal)
		part(sub, "GirderFlange", Vector3.new(plan.length, m(0.2), m(0.9)),
			g * CFrame.new(0, soffitTop - depth - m(0.1), z), STEEL, Enum.Material.Metal)
	end
	local step = math.max(m(5), plan.span / 8)
	local x = -plan.length / 2 + step
	while x < plan.length / 2 - step * 0.5 do
		part(sub, "Diaphragm", Vector3.new(m(0.2), depth * 0.7, sec.deckHalf * 2 - m(2)),
			g * CFrame.new(x, midY, 0), STEEL, Enum.Material.Metal)
		x += step
	end
	plan.girderDepth = depth
	return soffitTop - depth - m(0.2), zs
end

local function buildPiers(model, sec, plan, g, soffitY)
	local sub = Instance.new("Model"); sub.Name = "Substructure"; sub.Parent = model
	local clear = soffitY - plan.groundY
	if clear < m(1) then return sub end

	local legs = stemOffsets(sec.deckHalf)
	for _, x in plan.piers do
		local p = Instance.new("Model"); p.Name = "Pier"; p.Parent = sub
		-- drawPier works in a frame with +X ACROSS the deck; a standalone bridge runs along
		-- its own X, so the pier frame is given the quarter turn into it.
		drawPier(p, g * CFrame.new(x, soffitY, 0) * CFrame.Angles(0, math.rad(-90), 0), clear, legs)
	end
	return sub
end

-- The abutment is the deck seat AND the retaining wall, and the approach slab in front
-- of it is what stops the settlement bump at the end of the bridge.
local function buildEnds(sub, sec, plan, g, soffitY)
	local h = soffitY - plan.groundY
	local seatT = math.clamp(plan.span / 40, m(1.5), m(4))
	for _, s in { -1, 1 } do
		local x = s * plan.length / 2
		local a = Instance.new("Model"); a.Name = "Abutment"; a.Parent = sub
		part(a, "Seat", Vector3.new(seatT * 2, h + m(0.6), sec.deckHalf * 2 + m(1)),
			g * CFrame.new(x + s * seatT, plan.groundY + (h + m(0.6)) / 2, 0), RC.ELEVATED_PILLAR_COLOR, nil, true)
		for _, sz in { -1, 1 } do
			part(a, "Wingwall", Vector3.new(math.max(h * 1.4, m(4)), h * 0.9, m(0.8)),
				g * CFrame.new(x + s * (seatT + math.max(h * 0.7, m(2))), plan.groundY + h * 0.45,
					sz * (sec.deckHalf + m(0.5))), RC.ELEVATED_PILLAR_COLOR, nil, true)
		end
		part(a, "ApproachSlab", Vector3.new(m(10), m(DIM.deckSlabT), sec.deckHalf * 2),
			g * CFrame.new(x + s * (m(5) + seatT * 0.2), plan.deckY - m(DIM.deckSlabT) / 2 - m(DIM.surfaceT), 0),
			RC.SIDEWALK_COLOR, nil, true)
		part(a, "ExpansionJoint", Vector3.new(m(0.3), m(0.7), sec.deckHalf * 2),
			g * CFrame.new(x, plan.deckY - m(0.35), 0), Color3.fromRGB(38, 38, 40), Enum.Material.Metal, true)
	end
end

local function buildSafety(model, spec, sec, plan, g)
	local sub = Instance.new("Model"); sub.Name = "Safety"; sub.Parent = model
	local L, deckY = plan.length, plan.deckY
	local drop = plan.deckY - plan.groundY

	if sec.hasWalk then
		local bh = m(DIM.trafficBarrierH)
		for _, s in { -1, 1 } do
			part(sub, "TrafficBarrier", Vector3.new(L, bh, sec.barrierT),
				g * CFrame.new(0, deckY + bh / 2 - m(DIM.surfaceT), s * sec.barrierZ), RC.ELEVATED_PILLAR_COLOR, nil, true)
		end
		local rh = m(DIM.pedRailH)
		for _, s in { -1, 1 } do
			local z = s * sec.railZ
			for _, f in { 1.0, 0.62, 0.28 } do
				part(sub, "Rail", Vector3.new(L, m(0.09), m(0.11)), g * CFrame.new(0, deckY + rh * f, z), RC.GUARDRAIL_COLOR, Enum.Material.Metal)
			end
			for x = -L / 2, L / 2, m(DIM.railPostSpacing) do
				part(sub, "RailPost", Vector3.new(m(0.11), rh, m(0.11)), g * CFrame.new(x, deckY + rh / 2, z), RC.GUARDRAIL_COLOR, Enum.Material.Metal)
			end
			-- Anti-throw screens answer the fall, so a low deck gets none.
			if drop >= m(DIM.screenMinDrop) then
				local sh = m(DIM.screenH)
				local sc = part(sub, "AntiThrowScreen", Vector3.new(L, sh, m(0.06)), g * CFrame.new(0, deckY + rh + sh / 2, z), RC.GUARDRAIL_COLOR, Enum.Material.DiamondPlate)
				sc.Transparency = 0.55
				for x = -L / 2, L / 2, m(DIM.railPostSpacing) do
					part(sub, "ScreenPost", Vector3.new(m(0.1), sh, m(0.1)), g * CFrame.new(x, deckY + rh + sh / 2, z), RC.GUARDRAIL_COLOR, Enum.Material.Metal)
				end
			end
		end
		for x = -L / 2 + m(6), L / 2 - m(6), m(DIM.scupperSpacing) do
			for _, s in { -1, 1 } do
				part(sub, "Scupper", Vector3.new(m(0.8), m(0.15), m(0.25)),
					g * CFrame.new(x, deckY - m(0.05), s * (sec.carriageHalf - m(0.4))), Color3.fromRGB(40, 40, 42), Enum.Material.Metal)
			end
		end
	else
		for _, s in { -1, 1 } do
			local z = s * (sec.deckHalf - RC.GUARDRAIL_BEAM_WIDTH)
			part(sub, "GuardrailBeam", Vector3.new(L, RC.GUARDRAIL_BEAM_HEIGHT, RC.GUARDRAIL_BEAM_WIDTH),
				g * CFrame.new(0, deckY + RC.GUARDRAIL_HEIGHT - RC.GUARDRAIL_BEAM_HEIGHT / 2, z), RC.GUARDRAIL_COLOR, Enum.Material.Metal, true)
			for x = -L / 2, L / 2, RC.GUARDRAIL_POST_SPACING do
				part(sub, "GuardrailPost", Vector3.new(RC.GUARDRAIL_POST_WIDTH, RC.GUARDRAIL_HEIGHT, RC.GUARDRAIL_POST_WIDTH),
					g * CFrame.new(x, deckY + RC.GUARDRAIL_HEIGHT / 2, z), RC.GUARDRAIL_COLOR, Enum.Material.Metal)
			end
		end
	end

	if sec.medianW > 0 then
		local mh = m(DIM.medianBarrierH)
		part(sub, "MedianSlab", Vector3.new(L, m(0.2), sec.medianW), g * CFrame.new(0, deckY + m(0.1), 0), RC.ELEVATED_PILLAR_COLOR, nil, true)
		part(sub, "MedianBarrier", Vector3.new(L, mh, sec.medianW * 0.5),
			g * CFrame.new(0, deckY + m(0.2) + mh / 2, 0), RC.ELEVATED_PILLAR_COLOR, nil, true)
	end
end

local function buildMarkings(model, spec, sec, plan, g)
	if spec.isRail then
		local sub = Instance.new("Model"); sub.Name = "Track"; sub.Parent = model
		local gauge = m(1.435)
		for i = 1, sec.laneCount do
			local c = -sec.carriageHalf + (i - 0.5) * sec.laneW
			for _, s in { -1, 1 } do
				part(sub, "Rail", Vector3.new(plan.length, m(0.16), m(0.08)),
					g * CFrame.new(0, plan.deckY + m(0.08), c + s * gauge / 2), Color3.fromRGB(122, 116, 108), Enum.Material.Metal)
			end
		end
		return
	end
	local sub = Instance.new("Model"); sub.Name = "Markings"; sub.Parent = model
	local y = plan.deckY + m(0.01)
	local white = spec.edgeLineColor or RC.MARKING_WHITE

	if spec.edgeLineWidth and spec.edgeLineWidth > 0 then
		for _, s in { -1, 1 } do
			part(sub, "EdgeLine", Vector3.new(plan.length, m(0.03), spec.edgeLineWidth),
				g * CFrame.new(0, y, s * (sec.carriageHalf - spec.edgeLineWidth)), white, Enum.Material.SmoothPlastic)
		end
	end
	if sec.medianW > 0 then
		for _, s in { -1, 1 } do
			part(sub, "MedianEdgeLine", Vector3.new(plan.length, m(0.03), m(0.12)),
				g * CFrame.new(0, y, s * (sec.medianW / 2 + m(0.15))), white, Enum.Material.SmoothPlastic)
		end
	end

	-- Dash period comes from RoadConstants so bridge dashes line up with road dashes.
	-- A very long deck steps the period up rather than emit thousands of parts.
	local period = RC.DASH_LENGTH + RC.DASH_GAP
	while plan.length / period > 300 do period *= 2 end
	local dashLen = RC.DASH_LENGTH * (period / (RC.DASH_LENGTH + RC.DASH_GAP))

	for _, b in laneBoundaries(spec, sec) do
		local col = b.centre and (spec.centerLineColor or white) or (spec.laneLineColor or white)
		local w = b.centre and ((spec.centerLineWidth or 0) > 0 and spec.centerLineWidth or m(0.12)) or (spec.laneLineWidth or m(0.1))
		local dashed = if b.centre then spec.centerLineDashed else spec.laneLineDashed
		local offs = if b.centre and spec.centerLineDouble then { -w, w } else { 0 }
		for _, o in offs do
			if dashed then
				for x = -plan.length / 2 + dashLen, plan.length / 2 - dashLen, period do
					part(sub, "LaneDash", Vector3.new(dashLen, m(0.03), w), g * CFrame.new(x, y, b.z + o), col, Enum.Material.SmoothPlastic)
				end
			else
				part(sub, "LaneLine", Vector3.new(plan.length, m(0.03), w), g * CFrame.new(0, y, b.z + o), col, Enum.Material.SmoothPlastic)
			end
		end
	end
end

local function buildLighting(model, sec, plan, g)
	local sub = Instance.new("Model"); sub.Name = "Lighting"; sub.Parent = model
	local ph = m(DIM.lampH)
	local onMedian = sec.medianW > m(1.2)
	local baseY = plan.deckY + (onMedian and m(0.2) or 0)
	local n = math.max(2, math.floor(plan.length / m(DIM.lampSpacing)))
	local step = plan.length / n

	for i = 0, n do
		local x = -plan.length / 2 + i * step
		local pole = Instance.new("Model"); pole.Name = "LightPole"; pole.Parent = sub
		local zs = if onMedian then { 0 }
			elseif i % 2 == 1 then { sec.deckHalf - m(0.8) }
			else { -(sec.deckHalf - m(0.8)) }
		for _, pz in zs do
			part(pole, "Pole", Vector3.new(m(0.25), ph, m(0.25)), g * CFrame.new(x, baseY + ph / 2, pz), RC.GUARDRAIL_COLOR, Enum.Material.Metal)
			local dirs = if onMedian then { -1, 1 } else { (if pz > 0 then -1 else 1) }
			for _, d in dirs do
				local reach = m(1.5)
				part(pole, "Arm", Vector3.new(m(0.15), m(0.15), reach * 2), g * CFrame.new(x, baseY + ph - m(0.15), pz + d * reach), RC.GUARDRAIL_COLOR, Enum.Material.Metal)
				local lamp = part(pole, "Lamp", Vector3.new(m(0.8), m(0.2), m(0.5)), g * CFrame.new(x, baseY + ph - m(0.25), pz + d * reach * 2), Color3.fromRGB(196, 199, 204), Enum.Material.SmoothPlastic)
				local lens = part(pole, "LampLens", Vector3.new(m(0.65), m(0.04), m(0.4)), g * CFrame.new(x, baseY + ph - m(0.36), pz + d * reach * 2), Color3.fromRGB(255, 246, 220), Enum.Material.Neon)
				lens.CastShadow = false
				local sl = Instance.new("SpotLight")
				sl.Face = Enum.NormalId.Bottom; sl.Angle = 110; sl.Range = m(11); sl.Brightness = 0.9
				sl.Color = Color3.fromRGB(255, 240, 205); sl.Shadows = false; sl.Parent = lamp
			end
		end
	end
end

-- == public API ===========================================================

function BridgeBuilder.plan(opts)
	opts = opts or {}
	local spec = Catalog.getOrDefault(opts.roadType)
	local length = opts.length or m(120)
	local groundY = opts.groundY or RC.getGroundY()
	local deckY = opts.height or (groundY + RC.ELEVATED_DEFAULT_HEIGHT)
	local availDepth = deckY - groundY - m(DIM.deckSlabT) - m(0.4)
	local p = planSpans(length, opts, availDepth)
	p.length, p.groundY, p.deckY, p.availDepth = length, groundY, deckY, availDepth
	p.spec = spec
	p.section = planSection(spec, opts)
	return p
end

function BridgeBuilder.build(opts): Model
	opts = opts or {}
	local plan = BridgeBuilder.plan(opts)
	local spec, sec = plan.spec, plan.section
	local g = opts.cframe or CFrame.new()

	local model = Instance.new("Model")
	model.Name = opts.name or ("Bridge_" .. spec.id)

	local soffitTop = buildDeck(model, spec, sec, plan, g)
	local soffitY = buildGirders(model, sec, plan, g, soffitTop)
	local sub = buildPiers(model, sec, plan, g, soffitY)
	buildEnds(sub, sec, plan, g, soffitY)
	buildSafety(model, spec, sec, plan, g)
	if opts.markings ~= false then buildMarkings(model, spec, sec, plan, g) end
	if opts.lighting ~= false then buildLighting(model, sec, plan, g) end

	model.PrimaryPart = model.Deck.DeckSlab
	model:SetAttribute("RoadType", spec.id)
	model:SetAttribute("Length", plan.length)
	model:SetAttribute("DeckWidth", sec.deckHalf * 2)
	model:SetAttribute("Span", plan.span)
	model:SetAttribute("SpanCount", plan.spanCount)
	model:SetAttribute("GirderDepth", plan.girderDepth)
	model:SetAttribute("Clearance", soffitY - plan.groundY)
	model.Parent = opts.parent or workspace
	return model
end

-- == elevated-road structure ==============================================
--
-- Called by RoadSceneRenderer for every elevated segment. The renderer owns the
-- curve and hands over sampled DECK SOFFIT points plus the ground under each; this
-- stands the same pillars under it that BridgeBuilder.build() puts under a deck, so a
-- road the player elevates and a bridge placed by hand rest on the same supports.
--
-- pts[i]      -- deck soffit centre, world space
-- groundYs[i] -- ground height directly under pts[i]

export type ElevatedOpts = {
	-- Arc-length 0 and `total` ARE this segment's two nodes. The caller sets one to false
	-- for a node another segment has already claimed, so a node where two elevated roads
	-- meet carries ONE pier instead of two stacked in the same spot.
	pierAtStart: boolean?,
	pierAtEnd: boolean?,
	-- Deck height above ground below which a support is not worth building. nodeMinHeight
	-- applies to the node piers only: a Bridge segment owning a node it shares with a low
	-- Elevated one still has to plant that node's support, but that must not drag the
	-- threshold down for the interval piers along its own span.
	minHeight: number?,
	nodeMinHeight: number?,
	-- "May a pillar stand here?" -- pos is the pillar base in world space, topY the deck
	-- soffit above it, radius the pillar's own radius. False = it would land on a road.
	columnClear: ((pos: Vector3, topY: number, radius: number) -> boolean)?,
}

function BridgeBuilder.addElevatedStructure(model: Model, pts: { Vector3 }, groundYs: { number }, spec, vMode: string?, opts: ElevatedOpts?)
	local n = #pts
	if n < 2 then return end

	local sec = planSection(spec, nil)
	local deckHalf = sec.deckHalf

	local cum = { 0 }
	for i = 2, n do
		cum[i] = cum[i - 1] + (pts[i] - pts[i - 1]).Magnitude
	end
	local total = cum[n]
	if total < 1 then return end

	local folder = Instance.new("Folder")
	folder.Name = "Pillars"
	folder.Parent = model

	local function tangentAt(i: number): Vector3
		local a = pts[math.max(i - 1, 1)]
		local b = pts[math.min(i + 1, n)]
		local d = b - a
		d = Vector3.new(d.X, 0, d.Z)
		return if d.Magnitude > 1e-4 then d.Unit else Vector3.xAxis
	end

	-- Supports land on NODES, not on an even division of the segment. A node is where the
	-- player actually put a point and where two decks meet, so a pier there carries both
	-- spans and stands on the one place the eye already reads as structural -- where the
	-- old even division dropped them at arbitrary points mid-span and never twice in the
	-- same place on two roads that joined. Interval piers only FILL IN: a run longer than
	-- one ELEVATED_PILLAR_SPACING gets evenly spaced extras, a shorter one gets none
	-- (a drawn road is auto-split at MAX_PLACE_SEGMENT_LENGTH, so its own nodes already
	-- land close to the intended rhythm). Which of the two nodes THIS segment owns is the
	-- caller's call -- both segments meeting at one would otherwise stack a pier there.
	local o: ElevatedOpts = opts or {}
	local spacing = RC.ELEVATED_PILLAR_SPACING
	local minH = o.minHeight or (if vMode == "Elevated" then 2 else RC.ELEVATED_PILLAR_MIN_HEIGHT)
	local nodeMinH = o.nodeMinHeight or minH

	local targets: { { d: number, node: boolean } } = {}
	if o.pierAtStart ~= false then table.insert(targets, { d = 0, node = true }) end
	local inner = math.max(math.ceil(total / spacing) - 1, 0)
	for k = 1, inner do
		table.insert(targets, { d = total * k / (inner + 1), node = false })
	end
	if o.pierAtEnd ~= false then table.insert(targets, { d = total, node = true }) end
	if #targets == 0 then return end

	local stems = stemOffsets(deckHalf)
	-- Half the pillars, rounded up, is the least that still holds the deck: a single-pillar
	-- pier needs its one leg, and a wide pair may lose one to a road below and stand on the
	-- other, but a four-pillar bent may not come down to one corner alone.
	local minLegs = math.max(1, math.ceil(#stems / 2))

	-- Deck soffit point, the ground under it, and the plan tangent, at arc-length d.
	local function at(d: number): (Vector3, number, Vector3)
		local i = 1
		while i < n - 1 and cum[i + 1] < d do i += 1 end
		local len = math.max(cum[i + 1] - cum[i], 1e-4)
		local f = math.clamp((d - cum[i]) / len, 0, 1)
		return pts[i]:Lerp(pts[i + 1], f),
			groundYs[i] + (groundYs[i + 1] - groundYs[i]) * f,
			tangentAt(i)
	end

	-- A support may never come down ON a road. Pillars are tested one at a time, so a pier
	-- straddling a street below keeps the legs that land on open ground and drops the ones
	-- that don't.
	local function legsAt(pos: Vector3, dir: Vector3, stemR: number): { number }
		if not o.columnClear then return stems end
		local right = Vector3.new(-dir.Z, 0, dir.X)
		local out: { number } = {}
		for _, off in stems do
			if o.columnClear(pos + right * off, pos.Y, stemR) then
				table.insert(out, off)
			end
		end
		return out
	end

	for _, tgt in targets do
		-- An INTERVAL pier is free to slide along the deck to find ground -- that is exactly
		-- what a viaduct does where it crosses a road. A NODE pier is not: being AT the node
		-- is the whole point of it, so a blocked one is dropped and its load goes to the
		-- piers either side.
		local want = if tgt.node then nodeMinH else minH
		local slides = if tgt.node then { 0 } else { 0, 0.18, -0.18, 0.34, -0.34 }
		for _, slide in slides do
			local pos, gy, dir = at(math.clamp(tgt.d + slide * spacing, 0, total))
			local height = pos.Y - gy
			if height < want then continue end

			-- The widest pillar this pier could grow, so the clearance test never approves a
			-- spot the finished column would overhang.
			local stemR = math.clamp(height / 9, m(0.8), m(2.0)) * 0.75
			local legs = legsAt(pos, dir, stemR)
			if #legs < minLegs then continue end

			drawPier(folder, CFrame.lookAt(pos, pos + dir, Vector3.yAxis), height, legs)
			break
		end
	end
end

return BridgeBuilder
