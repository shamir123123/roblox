--!strict
-- Finds HUD surfaces that collide or run off the screen -- at every screen size, from a
-- single run, without needing the devices.
--
-- Roblox ships a Device Emulator (Test > Device) for LOOKING at one resolution at a time;
-- there is no built-in overlap check. So this reads each top-level surface's DECLARED
-- geometry (AnchorPoint/Position/Size) and recomputes its rect at a whole matrix of
-- viewports. Reading AbsolutePosition instead would only ever tell you about the one
-- resolution you happen to be running, which is precisely the resolution that already
-- looks fine.
--
-- Usage -- client console (F9) in a running game:
--   local A = require(game.Players.LocalPlayer.PlayerGui.StaffTools.UIOverlapAudit)
--   A.run()      -- only what is on screen right now: few false positives
--   A.run(true)  -- every surface including hidden ones: catches latent clashes

local Players = game:GetService("Players")

local UIOverlapAudit = {}

-- Mirrors HudScale's formula on purpose: the audit has to model the same scale the HUD
-- will actually be given at each hypothetical viewport.
local DESIGN_W, DESIGN_H = 1366, 768
local function hudScaleFor(vx: number, vy: number): number
	return math.min(1, vx / DESIGN_W, vy / DESIGN_H)
end

local VIEWPORTS = {
	{ 2560, 1440, "desktop 1440p" },
	{ 2560, 1080, "ultrawide" },
	{ 1920, 1080, "desktop 1080p" },
	{ 1366, 768, "design canvas" },
	{ 1280, 720, "small desktop" },
	{ 1024, 768, "tablet 4:3" },
	{ 960, 540, "small window" },
	{ 854, 480, "phone landscape" },
	{ 667, 375, "phone small" },
}

type Surface = {
	label: string,
	gui: string,
	scaled: boolean,
	anchor: Vector2,
	pos: UDim2,
	size: UDim2,
	autoX: boolean,
	autoY: boolean,
	measured: Vector2,
	onScreen: boolean,
}

local function collect(includeHidden: boolean): { Surface }
	local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
	local list: { Surface } = {}
	for _, screen in pg:GetChildren() do
		if not screen:IsA("ScreenGui") then
			continue
		end
		if not includeHidden and not screen.Enabled then
			continue
		end
		-- Only direct children are audited. Anything inside a UIListLayout capsule is
		-- positioned by that layout, not by its own Position, so treating it as a free
		-- rect would invent collisions that cannot happen.
		local scale = screen:FindFirstChild("HudScale")
		local isScaled = scale ~= nil and scale:IsA("UIScale")
		for _, child in screen:GetChildren() do
			if not child:IsA("GuiObject") then
				continue
			end
			if not includeHidden and not child.Visible then
				continue
			end
			local auto = child.AutomaticSize
			table.insert(list, {
				label = child.Name,
				gui = screen.Name,
				scaled = isScaled,
				anchor = child.AnchorPoint,
				pos = child.Position,
				size = child.Size,
				autoX = auto == Enum.AutomaticSize.X or auto == Enum.AutomaticSize.XY,
				autoY = auto == Enum.AutomaticSize.Y or auto == Enum.AutomaticSize.XY,
				measured = child.AbsoluteSize,
				onScreen = child.Visible and screen.Enabled,
			})
		end
	end
	return list
end

-- Verified against the engine: a UIScale parented to a ScreenGui multiplies the OFFSET
-- components only -- scale components still resolve against the full viewport. That is
-- what lets the full-width bottom bar keep spanning the screen while its padding shrinks.
local function rectAt(s: Surface, vx: number, vy: number): (number, number, number, number)
	local k = if s.scaled then hudScaleFor(vx, vy) else 1
	local w = s.size.X.Scale * vx + s.size.X.Offset * k
	local h = s.size.Y.Scale * vy + s.size.Y.Offset * k
	-- AutomaticSize axes have no declared extent; the measured one is the best estimate
	-- available and does not itself depend on the viewport for these surfaces.
	if s.autoX or w <= 0 then
		w = s.measured.X
	end
	if s.autoY or h <= 0 then
		h = s.measured.Y
	end
	local x = s.pos.X.Scale * vx + s.pos.X.Offset * k - s.anchor.X * w
	local y = s.pos.Y.Scale * vy + s.pos.Y.Offset * k - s.anchor.Y * h
	return x, y, w, h
end

local function intersect(ax, ay, aw, ah, bx, by, bw, bh): number
	local ox = math.min(ax + aw, bx + bw) - math.max(ax, bx)
	local oy = math.min(ay + ah, by + bh) - math.max(ay, by)
	if ox <= 0 or oy <= 0 then
		return 0
	end
	return ox * oy
end

-- A panel parked entirely outside the viewport is a closed slide-out, not a bug.
local function fullyOffscreen(x, y, w, h, vx, vy): boolean
	return x + w <= 0 or y + h <= 0 or x >= vx or y >= vy
end

function UIOverlapAudit.run(includeHidden: boolean?): string
	local surfaces = collect(includeHidden == true)
	local report = {}
	local function p(s: string)
		table.insert(report, s)
	end

	p(("UI OVERLAP AUDIT -- %d surfaces, %d viewports%s"):format(
		#surfaces, #VIEWPORTS, includeHidden and " (including hidden)" or ""))

	-- Overlaps are reported once, at the widest viewport range they occur in, rather than
	-- nine times over -- otherwise one bad pair drowns the report.
	local overlapWhere: { [string]: { string } } = {}
	local clipWhere: { [string]: { string } } = {}

	for _, vp in VIEWPORTS do
		local vx, vy, vname = vp[1], vp[2], vp[3]
		local rects = {}
		for i, s in surfaces do
			local x, y, w, h = rectAt(s, vx, vy)
			rects[i] = { x, y, w, h, off = fullyOffscreen(x, y, w, h, vx, vy) }
		end

		for i, s in surfaces do
			local r = rects[i]
			if r.off then
				continue
			end
			-- partly past an edge = clipped
			local over = {}
			if r[1] < -0.5 then table.insert(over, ("left by %d"):format(math.floor(-r[1]))) end
			if r[2] < -0.5 then table.insert(over, ("top by %d"):format(math.floor(-r[2]))) end
			if r[1] + r[3] > vx + 0.5 then table.insert(over, ("right by %d"):format(math.floor(r[1] + r[3] - vx))) end
			if r[2] + r[4] > vy + 0.5 then table.insert(over, ("bottom by %d"):format(math.floor(r[2] + r[4] - vy))) end
			if #over > 0 then
				local key = ("%s/%s  off-screen %s"):format(s.gui, s.label, table.concat(over, ", "))
				clipWhere[key] = clipWhere[key] or {}
				table.insert(clipWhere[key], vname)
			end

			for j = i + 1, #surfaces do
				local t, r2 = surfaces[j], rects[j]
				if r2.off then
					continue
				end
				local area = intersect(r[1], r[2], r[3], r[4], r2[1], r2[2], r2[3], r2[4])
				if area > 4 then
					local key = ("%s/%s  X  %s/%s"):format(s.gui, s.label, t.gui, t.label)
					overlapWhere[key] = overlapWhere[key] or {}
					table.insert(overlapWhere[key], ("%s(%dpx²)"):format(vname, math.floor(area)))
				end
			end
		end
	end

	local function dump(title: string, map)
		local keys = {}
		for k in pairs(map) do
			table.insert(keys, k)
		end
		table.sort(keys)
		p(("\n== %s (%d) =="):format(title, #keys))
		if #keys == 0 then
			p("  none")
		end
		for _, k in keys do
			p("  " .. k)
			p("      at: " .. table.concat(map[k], ", "))
		end
	end

	dump("OVERLAPPING", overlapWhere)
	dump("CLIPPED OFF-SCREEN", clipWhere)

	local text = table.concat(report, "\n")
	print(text)
	return text
end

return UIOverlapAudit
