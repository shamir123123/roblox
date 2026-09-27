--!strict
-- StaffBoot
-- Entry point for the staff UI bundle (the F4 admin/tester panel and the F6 developer
-- panel). This whole folder lives in ServerStorage and is cloned into PlayerGui ONLY for
-- a player the server has already confirmed is staff -- see StaffUIService. An ordinary
-- player never receives this code, so there is nothing in their client to find, unpack or
-- re-require: the delivery IS the permission check.
--
-- PlayerGui, not PlayerScripts, because the server cannot reach PlayerScripts at all. A
-- LocalScript runs anywhere under PlayerGui, and the modules here resolve PlayerScripts
-- by name rather than by walking up from script.Parent, so the move costs nothing.
--
-- The panels still read the AdminTier attribute to decide which tabs to draw, and every
-- remote they call re-checks tier server-side. Nothing here is trusted for authority.
--
-- The client Bootstrap used to start both controllers. It cannot any more -- for most
-- players the modules are not there to require -- so the bundle starts itself.

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local tools = script.Parent
local AdminController = require(tools:WaitForChild("AdminController"))
local DeveloperController = require(tools:WaitForChild("DeveloperController"))

-- Isolated exactly like the client Bootstrap does it: a fault in one panel must never
-- stop the other from coming up.
local function startPanels()
	local okAdmin, errAdmin = pcall(function() AdminController.Start() end)
	if not okAdmin then
		warn("[StaffBoot] AdminController failed to start: " .. tostring(errAdmin))
	end
	-- Admin tier only; DeveloperController checks the tier itself and no-ops for a tester.
	local okDev, errDev = pcall(function() DeveloperController.Start() end)
	if not okDev then
		warn("[StaffBoot] DeveloperController failed to start: " .. tostring(errDev))
	end
end

local function stopPanels()
	pcall(function() AdminController.Cleanup() end)
	pcall(function() DeveloperController.Cleanup() end)
end

startPanels()

-- The owner can remove someone mid-session. The server clears AdminTier and then deletes
-- this folder a moment later; tear the panels down on that first signal so the GUI, the
-- world overlays and the polling connections actually go away. Destroying the folder
-- alone would not do it -- the modules are already loaded in this client.
--
-- Only the teardown direction is handled here. A re-grant arrives as a FRESH clone of
-- this folder, which is a fresh set of modules with clean state, so there is nothing to
-- restart from the old one.
LocalPlayer:GetAttributeChangedSignal("AdminTier"):Connect(function()
	if LocalPlayer:GetAttribute("AdminTier") == nil then
		stopPanels()
	end
end)
