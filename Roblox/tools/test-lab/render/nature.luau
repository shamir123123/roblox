-- Load the place's Nature models (ReplicatedStorage.Nature, from the .rbxm files) into the
-- Studio stand-in, as plain Parts with the real sizes. Leaves/flowers get a readable tint
-- for the top-down render (the real ones are textured MeshParts).
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local D = (require("@lune/process").env.CITY_LAB_DATA or "/tmp/claude-0/-home-user-unity-project/18389c77-9136-5827-8847-96d9472304f9/scratchpad") .. "/dump/ReplicatedStorage/Nature/"
return function(Studio, keys: { string })
	local folder = Studio.game.ReplicatedStorage:FindFirstChild("Nature")
	for _, key in keys do
		local ok, list = pcall(roblox.deserializeModel, fs.readFile(D .. key .. ".rbxm"))
		if not ok then continue end
		local src = list[1]
		local m = Studio.Instance.new("Model")
		m.Name = key
		for _, d in src:GetDescendants() do
			if d:IsA("BasePart") then
				local p = Studio.Instance.new("Part")
				p.Name = d.Name
				p.Shape = roblox.Enum.PartType.Ball
				p.Size = Studio.Vector3.new(d.Size.X, d.Size.Y, d.Size.Z)
				local c = d.CFrame
				p.CFrame = Studio.CFrame.new(c.Position.X, c.Position.Y, c.Position.Z)
				local n = d.Name:lower()
				p.Color = if n:find("leaf") or n:find("leaves") or n:find("frond") or n:find("canopy") or n:find("foliage") or n:find("bush") or n:find("hedge")
					then roblox.Color3.fromRGB(88, 140, 60)
					elseif n:find("flower") or n:find("bloom") or n:find("petal") then roblox.Color3.fromRGB(230, 120, 170)
					else roblox.Color3.fromRGB(110, 80, 55)
				p.Parent = m
			end
		end
		m.Parent = folder
	end
end
