--!nonstrict
-- Per-client icon report. Press F8 in game to show it, F8 again to hide.
--
-- Exists because "some players see the icons, some don't" cannot be diagnosed from the
-- developer's own machine -- the owner's cache is always warm. This runs on the affected
-- player's device and prints what THEIR client actually resolved.
--
-- Deliberately dependency-free (no Theme, no Kit): a diagnostic that can fail to build
-- because the UI is broken is worthless.

local Players = game:GetService("Players")
local ContentProvider = game:GetService("ContentProvider")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Peak queue depth over the whole session: a big number means the client was still
-- fetching long after the UI had drawn, which is the slow-connection signature.
local peakQueue = 0
RunService.Heartbeat:Connect(function()
	local q = ContentProvider.RequestQueueSize
	if q > peakQueue then
		peakQueue = q
	end
end)

-- Forward-declared on purpose: scan() parents its probe host into this gui. Declaring it
-- further down (where it is built) put it out of scope inside scan, so `gui` read as a nil
-- global and every probe was parented to nil -- unrendered, and reported as unreachable.
local gui

local function scan()
	local lines = {}
	local function p(s)
		table.insert(lines, s)
	end

	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(0, 0)
	local platform = if GuiService:IsTenFootInterface() then "Console"
		elseif UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then "Mobile"
		else "Desktop"

	p(("player   %s"):format(player.Name))
	p(("platform %s   viewport %dx%d   peakQueue %d"):format(platform, vp.X, vp.Y, peakQueue))

	-- disabled ScreenGuis: the other way the UI goes missing
	local off = {}
	for _, c in ipairs(playerGui:GetChildren()) do
		if c:IsA("ScreenGui") and not c.Enabled then
			table.insert(off, c.Name)
		end
	end
	p(("disabled guis: %s"):format(#off > 0 and table.concat(off, ",") or "none"))

	-- Every image in the tree, deduped by asset id.
	-- IsLoaded only means anything for an instance that is actually RENDERING: inside a
	-- disabled ScreenGui it stays false forever however healthy the asset is. So track
	-- whether each one was live, and never draw a conclusion from a dead one.
	local function isLive(inst)
		local node = inst
		while node and node ~= playerGui do
			if node:IsA("ScreenGui") then
				return node.Enabled
			end
			if node:IsA("GuiObject") and not node.Visible then
				return false
			end
			node = node.Parent
		end
		return true
	end

	local byId, blanks = {}, 0
	for _, d in ipairs(playerGui:GetDescendants()) do
		if d:IsA("ImageLabel") or d:IsA("ImageButton") then
			local id = d.Image
			if id == "" then
				blanks += 1
			else
				local r = byId[id]
				if not r then
					r = { total = 0, loaded = 0, live = 0, where = d:GetFullName() }
					byId[id] = r
				end
				r.total += 1
				if isLive(d) then
					r.live += 1
				end
				if d.IsLoaded then
					r.loaded += 1
				end
			end
		end
	end

	local ids = {}
	for id in pairs(byId) do
		table.insert(ids, id)
		end
	table.sort(ids)

	local liveOk, liveBlank, hiddenCount = 0, {}, 0
	for _, id in ipairs(ids) do
		local r = byId[id]
		if r.live == 0 then
			hiddenCount += 1
		elseif r.loaded > 0 then
			liveOk += 1
		else
			table.insert(liveBlank, id)
		end
	end
	p(("onscreen %d ids | %d drawn ok | %d BLANK | %d in hidden UI (unmeasurable) | %d empty slots")
		:format(#ids, liveOk, #liveBlank, hiddenCount, blanks))

	-- An ImageLabel named like an icon but carrying no Image at all never had art assigned;
	-- that is a different bug from art that failed to load, and looks identical on screen.
	local namedEmpty = {}
	for _, d in ipairs(playerGui:GetDescendants()) do
		if (d:IsA("ImageLabel") or d:IsA("ImageButton")) and d.Image == "" and isLive(d) then
			local n = d.Name:lower()
			if n:find("icon") or n:find("preview") or n:find("image") then
				table.insert(namedEmpty, (d:GetFullName():gsub("^Players%.[^.]+%.PlayerGui%.", "")))
			end
		end
	end
	if #namedEmpty > 0 then
		p(("NO ART ASSIGNED (%d visible icon slots with Image == \"\"):"):format(#namedEmpty))
		for i = 1, math.min(#namedEmpty, 5) do
			p("  " .. namedEmpty[i])
		end
	end

	-- Ground truth about the ASSETS, independent of what happens to be on screen: mount a
	-- fresh probe per id inside this gui (which is enabled) and see if it resolves.
	-- INSTANCES, never id strings -- PreloadAsync reports Failure for raw rbxassetid
	-- strings even for perfectly good assets, so string results tell you nothing.
	local host = Instance.new("Frame")
	host.Size = UDim2.fromOffset(2, 2)
	host.BackgroundTransparency = 1
	host.Parent = gui

	local probes, probed = {}, {}
	for i = 1, math.min(#ids, 90) do
		local il = Instance.new("ImageLabel")
		il.Image = ids[i]
		il.Size = UDim2.fromOffset(1, 1)
		-- NOT ImageTransparency = 1: a fully transparent image never rasterises, so IsLoaded
		-- would stay false for every probe and report healthy assets as dead.
		il.ImageTransparency = 0
		il.BackgroundTransparency = 1
		il.Parent = host
		probes[i] = il
		probed[ids[i]] = true
	end

	-- The AssetFetchStatus callback is the authoritative answer -- IsLoaded is a property
	-- of the INSTANCE's rendering, not of the asset, and lies whenever the instance is not
	-- being drawn. Verdict comes from status; IsLoaded is only reported alongside it.
	local status = {}
	pcall(function()
		ContentProvider:PreloadAsync(probes, function(cid, st)
			status[cid] = tostring(st):gsub("Enum%.AssetFetchStatus%.", "")
		end)
	end)
	task.wait(1)

	local reachable, unreachable = 0, {}
	for _, id in ipairs(ids) do
		if probed[id] then
			if status[id] == "Success" then
				reachable += 1
			else
				table.insert(unreachable, id)
			end
		end
	end
	host:Destroy()

	p(("assets   %d probed | %d reachable | %d UNREACHABLE"):format(#probes, reachable, #unreachable))
	-- Sanity check against reality: anything currently drawing on screen is provably
	-- reachable, so if the probe disagrees it is the probe that is wrong, not the asset.
	if #unreachable > 0 and liveOk > 0 and reachable == 0 then
		p(("!! probe is unreliable: %d icons are drawn on screen right now, so the assets"):format(liveOk))
		p("!! cannot all be unreachable. Trust the on-screen line, not the asset line.")
	elseif #unreachable > 0 then
		p("UNREACHABLE -- the asset itself will not serve to this client:")
		for i = 1, math.min(#unreachable, 6) do
			p(("  %s  %s"):format(unreachable[i], (byId[unreachable[i]].where:gsub("^Players%.[^.]+%.PlayerGui%.", ""))))
		end
	elseif #liveBlank > 0 then
		p("all assets reachable -- on-screen blanks are a TIMING/STATE bug, not an asset bug:")
		for i = 1, math.min(#liveBlank, 5) do
			local id = liveBlank[i]
			p(("  %s  %s"):format(id, (byId[id].where:gsub("^Players%.[^.]+%.PlayerGui%.", ""))))
		end
	else
		p("every visible icon resolved")
	end

	return table.concat(lines, "\n")
end

-- On-screen so it can simply be screenshotted; asking someone to open F9 and copy text
-- out of the developer console loses most people.
gui = Instance.new("ScreenGui")
gui.Name = "IconDiag"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 2000 -- above everything, including the dev overlays
gui.Enabled = false
gui.Parent = playerGui

local box = Instance.new("TextLabel")
box.AnchorPoint = Vector2.new(0.5, 0)
box.Position = UDim2.new(0.5, 0, 0, 20)
box.Size = UDim2.new(0, 780, 0, 300)
box.BackgroundColor3 = Color3.fromRGB(12, 14, 16)
box.BackgroundTransparency = 0.06
box.TextColor3 = Color3.fromRGB(225, 232, 225)
box.Font = Enum.Font.Code
box.TextSize = 14
box.TextXAlignment = Enum.TextXAlignment.Left
box.TextYAlignment = Enum.TextYAlignment.Top
box.Text = ""
box.Parent = gui

local pad = Instance.new("UIPadding")
pad.PaddingLeft = UDim.new(0, 12)
pad.PaddingTop = UDim.new(0, 10)
pad.Parent = box

local function refresh()
	local ok, text = pcall(scan)
	box.Text = if ok then text else ("IconDiag failed: " .. tostring(text))
	print("[IconDiag]\n" .. box.Text)
end

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or input.KeyCode ~= Enum.KeyCode.F8 then
		return
	end
	gui.Enabled = not gui.Enabled
	if gui.Enabled then
		refresh()
	end
end)

-- One automatic pass once the UI has had time to build, so a broken client reports itself
-- even if nobody thinks to press F8.
--
-- SILENT WHEN HEALTHY. This used to dump the whole report every session on every client,
-- which is what the log mostly consisted of. A clean pass ends on "every visible icon
-- resolved" and lists no unassigned art; every other outcome -- unreachable assets, on-screen
-- blanks, an unreliable probe, art never assigned, or the scan itself throwing -- is a real
-- finding and still speaks up. Press F8 for the report on demand.
task.delay(25, function()
	local ok, text = pcall(scan)
	local clean = ok and type(text) == "string"
		and string.find(text, "every visible icon resolved", 1, true) ~= nil
		and string.find(text, "NO ART ASSIGNED", 1, true) == nil
	if not clean then
		warn("[IconDiag auto]\n" .. (ok and tostring(text) or tostring(text)))
	end
end)
