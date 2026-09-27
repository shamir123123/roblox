--!strict
-- Pulls every script out of a place file into the Rojo tree under game/.
-- Usage (from the Roblox folder): lune run tools/extract-scripts.luau <place.rbxl> [outDir]
--
-- Only scripts and the folders that lead to them are written. Every directory gets an
-- init.meta.json with ignoreUnknownInstances, so a Rojo sync updates script sources and
-- never deletes the models, UI and parts that live beside them in Studio.
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local placePath = process.args[1]
local outDir = process.args[2] or "game"
assert(placePath, "usage: lune run tools/extract-scripts.luau <place.rbxl> [outDir]")

-- Services (and StarterPlayer children) that hold game scripts.
local ROOTS = {
	"ReplicatedFirst",
	"ReplicatedStorage",
	"ServerScriptService",
	"ServerStorage",
	"StarterPlayer/StarterPlayerScripts",
	"StarterPlayer/StarterCharacterScripts",
	"StarterGui",
	"Workspace",
}

-- Scripts that ship inside imported assets, not game code.
local SKIP_PREFIXES = {
	"ServerStorage/Templates/",
}

local SCRIPT_CLASSES = { Script = true, LocalScript = true, ModuleScript = true }

local game = roblox.deserializePlace(fs.readFile(placePath))

local function skipped(rel: string): boolean
	for _, prefix in SKIP_PREFIXES do
		if string.sub(rel, 1, #prefix) == prefix then
			return true
		end
	end
	return false
end

local function holdsScripts(inst: roblox.Instance, rel: string): boolean
	if skipped(rel .. "/") then
		return false
	end
	if SCRIPT_CLASSES[inst.ClassName] then
		return true
	end
	for _, d in inst:GetDescendants() do
		if SCRIPT_CLASSES[d.ClassName] then
			return true
		end
	end
	return false
end

local function suffixFor(inst: roblox.Instance): string
	if inst.ClassName == "Script" then
		return ".server.luau"
	elseif inst.ClassName == "LocalScript" then
		return ".client.luau"
	end
	return ".luau"
end

local function writeMeta(file: string, meta: { [string]: any })
	fs.writeFile(file, serde.encode("json", meta, true) .. "\n")
end

local function scriptMeta(inst: roblox.Instance): { [string]: any }?
	if inst.ClassName ~= "ModuleScript" and (inst :: any).Disabled then
		return { properties = { Disabled = true } }
	end
	return nil
end

local written = 0

local function writeNode(inst: roblox.Instance, dir: string, rel: string)
	local children = {}
	for _, c in inst:GetChildren() do
		local childRel = rel .. "/" .. c.Name
		if holdsScripts(c, childRel) then
			table.insert(children, c)
		end
	end

	if SCRIPT_CLASSES[inst.ClassName] then
		local meta = scriptMeta(inst)
		if #children == 0 then
			local base = dir .. "/" .. inst.Name
			fs.writeFile(base .. suffixFor(inst), (inst :: any).Source)
			if meta then
				writeMeta(base .. ".meta.json", meta)
			end
			written += 1
			return
		end
		local sub = dir .. "/" .. inst.Name
		fs.writeDir(sub)
		fs.writeFile(sub .. "/init" .. suffixFor(inst), (inst :: any).Source)
		local dirMeta = meta or {}
		dirMeta.ignoreUnknownInstances = true
		writeMeta(sub .. "/init.meta.json", dirMeta)
		written += 1
		for _, c in children do
			writeNode(c, sub, rel .. "/" .. c.Name)
		end
		return
	end

	local sub = dir .. "/" .. inst.Name
	fs.writeDir(sub)
	local meta: { [string]: any } = { ignoreUnknownInstances = true }
	if inst.ClassName ~= "Folder" then
		meta.className = inst.ClassName
	end
	writeMeta(sub .. "/init.meta.json", meta)
	for _, c in children do
		writeNode(c, sub, rel .. "/" .. c.Name)
	end
end

if fs.isDir(outDir) then
	fs.removeDir(outDir)
end
fs.writeDir(outDir)

for _, root in ROOTS do
	local inst: roblox.Instance? = game
	for _, name in string.split(root, "/") do
		inst = inst and (inst :: roblox.Instance):FindFirstChild(name)
	end
	if inst and holdsScripts(inst, root) then
		local parentDir = outDir
		local parts = string.split(root, "/")
		for i = 1, #parts - 1 do
			parentDir ..= "/" .. parts[i]
			fs.writeDir(parentDir)
		end
		writeNode(inst, parentDir, root)
	end
end

print(`wrote {written} scripts to {outDir}/`)
