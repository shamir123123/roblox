--!strict
-- FloatingCostEffect
-- One-shot red price tag that rises off a world point and fades out, shown when the
-- player places something that costs money. Pure client cosmetic, no game state.
-- spawn(worldPos, amount).

local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FloatingCostEffect = {}

local RED = Color3.fromRGB(230, 80, 80)
local RISE = 6         -- studs the tag climbs
local DURATION = 1.3   -- total life
local FADE = 0.7       -- fade length at the tail end

local function commaInt(n: number): string
	local s = tostring(math.floor(n + 0.5))
	local out = ""
	while #s > 3 do
		out = "," .. s:sub(#s - 2) .. out
		s = s:sub(1, #s - 3)
	end
	return s .. out
end

local function fxFolder(): Folder
	local f = Workspace:FindFirstChild("_CostFx")
	if not f then
		f = Instance.new("Folder")
		f.Name = "_CostFx"
		f.Parent = Workspace
	end
	return f :: Folder
end

-- Show "-$amount" in red rising off worldPos, then fade and clean up.
function FloatingCostEffect.spawn(worldPos: Vector3, amount: number)
	if amount <= 0 then return end

	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.CFrame = CFrame.new(worldPos)
	part.Parent = fxFolder()

	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(80, 20)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 2, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = 500
	bb.Adornee = part
	bb.Parent = part

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = RED
	label.Text = "-$" .. commaInt(amount)
	label.Parent = bb

	TweenService:Create(part, TweenInfo.new(DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CFrame = CFrame.new(worldPos + Vector3.new(0, RISE, 0)),
	}):Play()

	local fadeInfo = TweenInfo.new(FADE, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, 0, false, DURATION - FADE)
	TweenService:Create(label, fadeInfo, { TextTransparency = 1 }):Play()

	task.delay(DURATION + 0.1, function()
		part:Destroy()
	end)
end

-- Listen for server-confirmed charged placements (roads, services, transit, ...).
function FloatingCostEffect.Start()
	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	local SoundFX = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("SoundFX"))
	Net.PlacementCharged.OnClientEvent:Connect(function(pos: any, amount: any, kind: any)
		if typeof(pos) == "Vector3" and typeof(amount) == "number" then
			FloatingCostEffect.spawn(pos, amount)
			SoundFX.play(if typeof(kind) == "string" then kind else "Building")
		end
	end)
end

return FloatingCostEffect
