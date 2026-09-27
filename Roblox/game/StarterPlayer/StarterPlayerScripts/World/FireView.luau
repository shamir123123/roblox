--!strict
-- FireView
-- Client-only flame renderer. The server tags burning building models with "OnFire" and an
-- "FireIntensity" attribute (both replicate); this turns that into Fire + smoke + flicker on
-- each burning model and clears it when the tag goes (fire put out) or the model is destroyed
-- (burned down). No server dependency beyond the replicated tag.

local CollectionService = game:GetService("CollectionService")

local FireView = {}

local TAG = "OnFire"
local _started = false
local _fx: { [Instance]: BasePart } = {}
local _attrConns: { [Instance]: RBXScriptConnection } = {}

local function attachFX(model: Model)
	if _fx[model] then return end
	if not model:IsA("Model") then return end

	local ok, cf, size = pcall(function()
		local c, s = model:GetBoundingBox()
		return c, s
	end)
	if not ok then return end
	local _ = size

	local anchor = Instance.new("Part")
	anchor.Name = "_FireFX"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.CFrame = (cf :: CFrame)

	local fire = Instance.new("Fire")
	fire.Heat = 12
	fire.Size = math.clamp((size :: Vector3).Y * 0.5, 6, 28)
	fire.Color = Color3.fromRGB(255, 150, 40)
	fire.SecondaryColor = Color3.fromRGB(120, 40, 10)
	fire.Parent = anchor

	local smoke = Instance.new("Smoke")
	smoke.Color = Color3.fromRGB(40, 40, 40)
	smoke.Opacity = 0.45
	smoke.RiseVelocity = 8
	smoke.Size = 8
	smoke.Parent = anchor

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 140, 50)
	light.Range = 24
	light.Brightness = 3
	light.Parent = anchor

	anchor.Parent = model
	_fx[model] = anchor

	-- Grow the flame with the replicated intensity.
	local function applyIntensity()
		local i = tonumber(model:GetAttribute("FireIntensity")) or 1
		fire.Size = math.clamp((size :: Vector3).Y * 0.5 * (0.5 + i * 0.25), 6, 36)
		light.Brightness = math.clamp(2 + i, 2, 6)
	end
	applyIntensity()
	_attrConns[model] = model:GetAttributeChangedSignal("FireIntensity"):Connect(applyIntensity)
end

local function clearFX(model: Instance)
	local conn = _attrConns[model]
	if conn then conn:Disconnect(); _attrConns[model] = nil end
	local anchor = _fx[model]
	if anchor then
		if anchor.Parent then anchor:Destroy() end
		_fx[model] = nil
	end
end

function FireView.Start()
	if _started then return end
	_started = true

	for _, model in CollectionService:GetTagged(TAG) do
		attachFX(model)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(attachFX)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(clearFX)
end

return FireView
