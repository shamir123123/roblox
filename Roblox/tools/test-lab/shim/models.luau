-- Load the place's saved models into the Studio stand-in: folders become Folders, each model
-- becomes its instances with the properties the city code reads (geometry, colour,
-- attributes, PrimaryPart). Scripts inside are skipped. Call the result as
-- mount(dir, parent) for a folder of .rbxm files, or use .mountPlace(file) to merge every
-- non-script instance of a place file into the tree the scripts were mounted from.
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
return function(Studio)
	local CF = Studio.CFrame
	local function cf(c)
		return CF.new(c:GetComponents())
	end
	local function attrValue(v)
		if typeof(v) == "CFrame" then return cf(v) end
		return v
	end
	local function convert(src, parent)
		local class = src.ClassName
		if class == "Script" or class == "LocalScript" or class == "ModuleScript" then return nil end
		local node = Studio.Instance.new(class)
		node.Name = src.Name
		if src:IsA("BasePart") then
			node.Size = src.Size
			node.CFrame = cf(src.CFrame)
			node.Color = src.Color
			node.Transparency = src.Transparency
			node.Material = src.Material
			node.Anchored = src.Anchored
			node.CanCollide = src.CanCollide
			if class == "Part" then node.Shape = src.Shape end
		end
		for k, v in src:GetAttributes() do
			node:SetAttribute(k, attrValue(v))
		end
		local map = { [src] = node }
		for _, child in src:GetChildren() do
			local c, sub = convert(child, node)
			if c then for a, b in sub do map[a] = b end end
		end
		if class == "Model" then
			local ok, pivot = pcall(function() return src.WorldPivot end)
			if ok and pivot then node.WorldPivot = cf(pivot) end
			local ok2, pp = pcall(function() return src.PrimaryPart end)
			if ok2 and pp and map[pp] then node.PrimaryPart = map[pp] end
		end
		node.Parent = parent
		return node, map
	end
	local count = 0
	local function mount(dir: string, parent)
		for _, entry in fs.readDir(dir) do
			local path = dir .. "/" .. entry
			if fs.isDir(path) then
				local node = parent:FindFirstChild(entry)
				if not node then
					node = Studio.Instance.new("Folder")
					node.Name = entry
					node.Parent = parent
				end
				mount(path, node)
			elseif entry:match("%.rbxm$") then
				local ok, list = pcall(roblox.deserializeModel, fs.readFile(path))
				if ok then
					for _, inst in list do
						if convert(inst, parent) then count += 1 end
					end
				end
			end
		end
	end
	local SCRIPT = { Script = true, LocalScript = true, ModuleScript = true }
	local function merge(src, parent)
		for _, child in src:GetChildren() do
			if SCRIPT[child.ClassName] then
				local node = parent:FindFirstChild(child.Name)
				if node then merge(child, node) end
				continue
			end
			local node = parent:FindFirstChild(child.Name)
			if node and child.ClassName == "Folder" then
				merge(child, node)
			elseif convert(child, parent) then
				count += 1
			end
		end
	end
	local SERVICES = { "ReplicatedStorage", "ReplicatedFirst", "ServerStorage", "ServerScriptService" }
	return setmetatable({
		mountPlace = function(file: string)
			count = 0
			local place = roblox.deserializePlace(fs.readFile(file))
			for _, name in SERVICES do
				merge(place:GetService(name), Studio.game[name])
			end
			return count
		end,
	}, {
		__call = function(_, dir: string, parent)
			count = 0
			mount(dir, parent)
			return count
		end,
	})
end
