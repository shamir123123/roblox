--!strict
-- SeasonController
-- Client-side seasonal recolour of tree foliage. The season is a pure function of the city
-- day, which TimeService writes to workspace.CityDay (a replicated attribute) -- so no
-- server service is needed, the client just derives the season locally.
--
-- Broadleaf foliage carries the CollectionService tag "TreeFoliage"; each season has a
-- copy of the leaf texture pre-tinted (R/G/B multiply) and baked ONCE from an
-- EditableImage into a STATIC content via CreateDataModelContentAsync. The live
-- EditableImages are destroyed straight after baking, so nothing sits on the shared
-- EditableImage/EditableMesh device budget that RoadMeshView needs (see the WaterView
-- note in Bootstrap). Recolouring at runtime is then just swapping MeshPart.TextureContent
-- to the season's baked content -- no live EM, no per-frame work.
--
-- Evergreens (Pine) carry "Evergreen" instead of "TreeFoliage" and are left green all year.

local AssetService      = game:GetService("AssetService")
local CollectionService = game:GetService("CollectionService")
local Workspace         = game:GetService("Workspace")

local SeasonController = {}

local FOLIAGE_TAG    = "TreeFoliage"
local BASE_LEAF_TEX  = "rbxassetid://5130731849" -- the one leaf texture all broadleaf species share
local DAYS_PER_SEASON = 3

-- season index 0..3 -> (r,g,b) multipliers applied to the base (green) leaf texture.
local SEASON_TINTS: { [number]: Vector3 } = {
	[0] = Vector3.new(1.20, 1.35, 0.75), -- Spring  (fresh yellow-green)
	[1] = Vector3.new(0.80, 1.00, 0.65), -- Summer  (deep green)
	[2] = Vector3.new(2.30, 1.15, 0.35), -- Autumn  (golden orange)
	[3] = Vector3.new(1.55, 0.60, 1.00), -- Winter  (bare brown)
}
local SEASON_NAMES: { [number]: string } = { [0] = "Spring", [1] = "Summer", [2] = "Autumn", [3] = "Winter" }

local _content: { [number]: Content } = {} -- season -> baked static texture content
local _season = -1
local _started = false
local _conns: { RBXScriptConnection } = {}

local function seasonForDay(day: number): number
	return math.floor((math.max(day, 1) - 1) / DAYS_PER_SEASON) % 4
end

local function currentDay(): number
	local d = tonumber(Workspace:GetAttribute("CityDay"))
	return d and math.max(math.floor(d), 1) or 1
end

-- Bake the four seasonal contents. Sequential: each variant's live EditableImage is
-- destroyed right after it is baked to static content, so at most two EMs (the base read
-- source + one variant) exist at once, only during this startup pass.
local function bakeContents(): boolean
	local ok, base = pcall(function()
		return AssetService:CreateEditableImageAsync(Content.fromUri(BASE_LEAF_TEX))
	end)
	if not ok or not base then
		warn("[SeasonController] leaf texture load failed: " .. tostring(base))
		return false
	end
	local size = base.Size
	local src = base:ReadPixelsBuffer(Vector2.zero, size)
	for season = 0, 3 do
		local m = SEASON_TINTS[season]
		local ei = AssetService:CreateEditableImage({ Size = size })
		local buf = buffer.create(buffer.len(src))
		buffer.copy(buf, 0, src)
		for i = 0, buffer.len(buf) - 1, 4 do
			buffer.writeu8(buf, i,     math.clamp(math.floor(buffer.readu8(buf, i)     * m.X), 0, 255))
			buffer.writeu8(buf, i + 1, math.clamp(math.floor(buffer.readu8(buf, i + 1) * m.Y), 0, 255))
			buffer.writeu8(buf, i + 2, math.clamp(math.floor(buffer.readu8(buf, i + 2) * m.Z), 0, 255))
		end
		ei:WritePixelsBuffer(Vector2.zero, size, buf)
		local result, content = AssetService:CreateDataModelContentAsync(Content.fromObject(ei), {})
		ei:Destroy()
		if result == Enum.CreateContentResult.Success then
			_content[season] = content
		end
		task.wait()
	end
	base:Destroy()
	return next(_content) ~= nil
end

local function applyToPart(part: Instance)
	local content = _content[_season]
	if content and part:IsA("MeshPart") then
		part.TextureContent = content
	end
end

local function applyAll()
	local content = _content[_season]
	if not content then return end
	for _, part in CollectionService:GetTagged(FOLIAGE_TAG) do
		if part:IsA("MeshPart") then
			part.TextureContent = content
		end
	end
end

local function setSeason(season: number)
	if season == _season then return end
	_season = season
	applyAll()
end

function SeasonController.getSeason(): string
	return SEASON_NAMES[_season] or "?"
end

function SeasonController.Start()
	if _started then return end
	_started = true
	task.spawn(function()
		if not bakeContents() then return end
		_season = seasonForDay(currentDay())
		-- Connect the added-signal BEFORE the initial snapshot so a prop that replicates in
		-- mid-pass is still caught (applyToPart is idempotent, so the overlap is harmless).
		_conns[#_conns + 1] = CollectionService:GetInstanceAddedSignal(FOLIAGE_TAG):Connect(applyToPart)
		applyAll()
		_conns[#_conns + 1] = Workspace:GetAttributeChangedSignal("CityDay"):Connect(function()
			setSeason(seasonForDay(currentDay()))
		end)
	end)
end

return SeasonController
