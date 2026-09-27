--!strict
-- UiScratch -- Workspace._UI, the client's world-space scratch root.
--
-- Everything a tool draws into the world that is NOT part of the city lives under here:
-- placement ghosts, brush outlines, drag handles, coverage discs, preview rows, marquee
-- boxes. Thirteen files each rolled their own get-or-create for it.
--
-- This is load-bearing, not tidiness. Core.CursorRay excludes the WHOLE _UI root from
-- ground picks, so anything a tool parents OUTSIDE _UI becomes an invisible obstruction
-- that the cursor raycast hits instead of the ground -- the tool's own preview blocking
-- the tool. Parent scratch geometry through here and that cannot happen.

local Workspace = game:GetService("Workspace")

local UiScratch = {}

local ROOT_NAME = "_UI"

-- The root as it currently stands, WITHOUT creating it. For readers -- notably the raycast
-- filter -- that must not have a side effect just because they looked.
function UiScratch.peek(): Folder?
	local root = Workspace:FindFirstChild(ROOT_NAME)
	return if root and root:IsA("Folder") then root else nil
end

function UiScratch.root(): Folder
	local root = Workspace:FindFirstChild(ROOT_NAME)
	if not root or not root:IsA("Folder") then
		if root then root:Destroy() end
		root = Instance.new("Folder")
		root.Name = ROOT_NAME
		root.Parent = Workspace
	end
	return root :: Folder
end

-- A named subfolder for one tool. Rebuilt if a non-Folder is squatting the name, so a
-- caller can always treat the result as a Folder it owns.
function UiScratch.folder(name: string): Folder
	local root = UiScratch.root()
	local f = root:FindFirstChild(name)
	if not f or not f:IsA("Folder") then
		if f then f:Destroy() end
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = root
	end
	return f :: Folder
end

-- Drop a tool's whole subfolder. Never creates the root just to delete from it.
function UiScratch.clear(name: string)
	local root = UiScratch.peek()
	local f = root and root:FindFirstChild(name)
	if f then f:Destroy() end
end

return UiScratch
