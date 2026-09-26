-- Badge clustering: 40 dark houses on a street + 6 thirsty ones; a fake camera at street
-- level (no clusters), then high up (clusters), then back down (all single again).
local process = require("@lune/process")
local Studio = require("./shim/setup")(process.args[1] or "fix7")
local V, CF = Studio.Vector3, Studio.CFrame
local ws = Studio.game.Workspace
local city = Studio.Instance.new("Folder"); city.Name = "_City"; city.Parent = ws
local zb = Studio.Instance.new("Folder"); zb.Name = "ZonedBuildings"; zb.Parent = city
local cam = Studio.Instance.new("Folder"); cam.Name = "Camera"; cam.Parent = ws
ws._props.CurrentCamera = cam
local W, H, FOV = 1280, 720, math.rad(70)
cam._props.CFrame = CF.new(0, 60, 120) -- set below
cam._props.WorldToViewportPoint = function(self, p)
	local c = self._props.CFrame
	local rel = c:PointToObjectSpace(p)
	if rel.Z >= -0.1 then return V.new(0, 0, rel.Z), false end
	local f = (H / 2) / math.tan(FOV / 2)
	local x = W / 2 + rel.X / -rel.Z * f
	local y = H / 2 - rel.Y / -rel.Z * f
	return V.new(x, y, -rel.Z), x >= 0 and x <= W and y >= 0 and y <= H
end
for i = 1, 46 do
	local m = Studio.Instance.new("Model"); m.Name = "House" .. i
	local p = Studio.Instance.new("Part"); p.Size = V.new(20, 10, 20)
	local row = if i <= 23 then 1 else -1
	local k = (i - 1) % 23
	p.CFrame = CF.new(-380 + k * 33, 5, row * 31)
	p.Parent = m; m._props.PrimaryPart = p
	m.Parent = zb
	if i % 8 == 0 then m:SetAttribute("NoWater", true) else m:SetAttribute("NoPower", true) end
end
local NPV = Studio.require(Studio.find("StarterPlayer.StarterPlayerScripts.World.NoPowerView"))
NPV.Start()
Studio.step(0.1)
local function count(label)
	local singles, clusters, members = 0, 0, {}
	for _, m in zb:GetChildren() do
		local g = m:FindFirstChild("NoPowerBadge")
		if g and g.Enabled then singles += 1 end
	end
	local cf = cam:FindFirstChild("UtilityBadgeClusters")
	if cf then
		for _, part in cf:GetChildren() do
			local g = part:FindFirstChild("UtilityCluster")
			if g and g.Enabled then
				clusters += 1
				table.insert(members, g:FindFirstChildWhichIsA("Frame", true):FindFirstChildWhichIsA("TextLabel").Text .. "x" .. g:FindFirstChildWhichIsA("Frame", true):GetChildren()[4].Text)
			end
		end
	end
	print(("%-22s singles %2d  clusters %2d  %s"):format(label, singles, clusters, table.concat(members, " ")))
end
local function camAt(pos, look)
	cam._props.CFrame = CF.lookAt(pos, look)
	for _ = 1, 3 do Studio.step(0.2) end
end
camAt(V.new(0, 40, 90), V.new(0, 0, 0)); count("street level")
camAt(V.new(0, 300, 260), V.new(0, 0, 0)); count("zoomed out")
camAt(V.new(0, 900, 700), V.new(0, 0, 0)); count("far out")
camAt(V.new(0, 40, 90), V.new(0, 0, 0)); count("back to street")
for _, e in Studio.errors do print("ERR", e) end
