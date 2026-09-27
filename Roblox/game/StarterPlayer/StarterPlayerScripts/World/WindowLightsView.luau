--!strict
-- WindowLightsView -- cosmetic night lights in building windows.
-- Watches the _City building folders for window parts: "Window" glass panes
-- (offices), "WinPlate" decal windows (houses/shops -- lit = decal hidden, plate
-- goes Neon) and "Storefront" glass. Each window rolls
-- its own schedule once: ~30% never light, the rest switch ON at a random time
-- around dusk (17:30-20:30) and OFF at a random time in the night (21:30-05:30),
-- so blocks light up window by window instead of all at once.
-- Client-only and purely visual: the material/colour swap never replicates.

local Lighting = game:GetService("Lighting")

local WindowLightsView = {}

local FOLDERS = { "ZonedBuildings", "Schools", "EmergencyServices", "Transit" }
-- Deliberately dim: Neon bloom scales with colour brightness, and full-bright warm
-- neon reads like a floodlight wall at night.
local LIT_COLOR = Color3.fromRGB(168, 168, 162)
local DARK_SHARE = 0.65 -- share of windows that never light up
local SWEEP_SECONDS = 1 -- cosmetic; 1 Hz is plenty
local FOLDER_WAIT = 30

type Entry = {
	material: Enum.Material,
	color: Color3,
	onHour: number, -- math.huge = stays dark
	offHour: number, -- on a 12..36 wrapped clock (see sweep)
	lit: boolean,
}

local _entries: { [BasePart]: Entry } = {}

local function track(inst: Instance)
	if not inst:IsA("BasePart") or _entries[inst] then return end
	local n = inst.Name
	if not (n:find("Window") or n == "WinPlate" or n == "Storefront") then return end
	local dark = math.random() < DARK_SHARE
	_entries[inst] = {
		material = inst.Material,
		color = inst.Color,
		onHour = if dark then math.huge else 17.5 + math.random() * 3,
		offHour = 21.5 + math.random() * 8,
		lit = false,
	}
end

local function apply(part: BasePart, e: Entry, lit: boolean)
	if e.lit == lit then return end
	e.lit = lit
	if lit then
		part.Material = Enum.Material.Neon
		part.Color = LIT_COLOR
	else
		part.Material = e.material
		part.Color = e.color
	end
	-- Decal windows (WinPlate/Storefront): the painted frame hides the glow, so the
	-- decal steps aside while the window is lit. Authored decals are always opaque.
	for _, d in part:GetChildren() do
		if d:IsA("Decal") then
			d.Transparency = if lit then 1 else 0
		end
	end
end

local function sweep()
	-- Wrap the clock so an evening-to-morning window is one contiguous range:
	-- 17:30 -> 17.5, midnight -> 24, 05:30 -> 29.5.
	local h = Lighting.ClockTime
	if h < 12 then h += 24 end
	for part, e in _entries do
		if not part:IsDescendantOf(workspace) then
			_entries[part] = nil
		else
			apply(part, e, h >= e.onHour and h < e.offHour)
		end
	end
end

function WindowLightsView.Start()
	local city = workspace:WaitForChild("_City", FOLDER_WAIT)
	if not city then
		warn("[WindowLightsView] workspace._City never appeared -- windows stay dark")
		return
	end
	for _, name in FOLDERS do
		task.spawn(function()
			local folder = city:WaitForChild(name, FOLDER_WAIT)
			if not folder then return end
			folder.DescendantAdded:Connect(track)
			for _, d in folder:GetDescendants() do
				track(d)
			end
		end)
	end
	task.spawn(function()
		while true do
			task.wait(SWEEP_SECONDS)
			local ok, err = pcall(sweep)
			if not ok then
				warn("[WindowLightsView] sweep failed: " .. tostring(err))
			end
		end
	end)
end

return WindowLightsView
