-- Build a Studio stand-in over the extracted place. mode "orig" = the scripts as sent;
-- "patched" = with fix batches 1-3 overlaid.
local D = (require("@lune/process").env.CITY_LAB_DATA or "/tmp/claude-0/-home-user-unity-project/18389c77-9136-5827-8847-96d9472304f9/scratchpad")
local PATCHES = {
	["ReplicatedStorage.Road.NavRouter"] = D .. "/fix/new/NavRouter.luau",
	["ReplicatedStorage.Road.RoadNavigationGraph"] = D .. "/fix/new/RoadNavigationGraph.luau",
	["ServerScriptService.Services.Util.PathFollower"] = D .. "/fix/new/PathFollower.luau",
	["ServerScriptService.Services.NPC.NPCDriverService"] = D .. "/fix3/new/NPCDriverService.luau",
	["ServerScriptService.Services.City.Simulation.CitizenService"] = D .. "/fix3/new/CitizenService.luau",
	["StarterPlayer.StarterPlayerScripts.World.NPCDriverView"] = D .. "/fix/new/NPCDriverView.luau",
	["ServerScriptService.Services.City.CitySimConstants"] = D .. "/fix2/new/CitySimConstants.luau",
	["ServerScriptService.Services.City.TimeService"] = D .. "/fix2/new/TimeService.luau",
	["ServerScriptService.Services.City.Economy.CityEconomyService"] = D .. "/fix2/new/CityEconomyService.luau",
	["ServerScriptService.Services.City.Economy.SupplyService"] = D .. "/fix2/new/SupplyService.luau",
	["StarterPlayer.StarterPlayerScripts.HUD.BuildingInfoController"] = D .. "/fix2/new/BuildingInfoController.luau",
	["ServerScriptService.Bootstrap.Bootstrap"] = D .. "/fix3/new/Bootstrap.server.luau",
}
return function(mode: string)
	local PATCHES = table.clone(PATCHES)
	if mode:sub(1, 4) == "var:" then
		-- rule experiments: var:<file in fix4/var> replaces NPCDriverService on top of fix4
		PATCHES["ServerScriptService.Services.NPC.NPCDriverService"] = D .. "/fix4/var/" .. mode:sub(5)
		PATCHES["ServerScriptService.Services.Util.PathFollower"] = D .. "/fix4/new/PathFollower.luau"
		mode = "fix4"
	elseif mode == "fix6" or mode == "fix7" then
		if mode == "fix7" then
			-- batch 7 (buildings + terrain): every file in fix7/new, named by its Studio path
			local fs = require("@lune/fs")
			for _, f in fs.readDir(D .. "/fix7/new") do
				if f:sub(-5) == ".luau" then PATCHES[f:sub(1, -6)] = D .. "/fix7/new/" .. f end
			end
		end
		PATCHES["ServerScriptService.Services.NPC.NPCDriverService"] = D .. "/fix5/new/ServerScriptService.Services.NPC.NPCDriverService.luau"
		for _, f in { "ReplicatedStorage.Road.RoadConstants", "ReplicatedStorage.Road.RoadSceneRenderer",
			"ReplicatedStorage.Road.RoadNetwork", "ReplicatedStorage.Road.RoadTypes", "ReplicatedStorage.Networker",
			"ServerScriptService.Services.Road.RoadSerializer", "ServerScriptService.Services.Road.RoadHistoryService",
			"ServerScriptService.Services.Road.RoadService", "ServerScriptService.Services.Road.RoadReplicationService",
			"ReplicatedStorage.Road.RoadNavigationGraph", "ReplicatedStorage.Road.IntersectionRenderer" } do
			PATCHES[f] = D .. "/fix5/new/" .. f .. ".luau"
		end
		PATCHES["ReplicatedStorage.Road.RoadRenderer"] = D .. "/fix6/new/ReplicatedStorage.Road.RoadRenderer.luau"
		mode = "fix4"
	elseif mode == "fix5" or mode == "fix5dbg" or mode == "fix5noflare" then
		local sub = if mode == "fix5dbg" then "dbg" elseif mode == "fix5noflare" then "noflare" else "new"
		-- batch 5 (roundabouts) on top of batch 4
		PATCHES["ServerScriptService.Services.NPC.NPCDriverService"] = D .. "/fix5/" .. sub .. "/ServerScriptService.Services.NPC.NPCDriverService.luau"
		for _, f in { "ReplicatedStorage.Road.RoadConstants", "ReplicatedStorage.Road.RoadRenderer", "ReplicatedStorage.Road.RoadSceneRenderer",
			"ReplicatedStorage.Road.RoadNetwork", "ReplicatedStorage.Road.RoadTypes", "ReplicatedStorage.Networker",
			"ServerScriptService.Services.Road.RoadSerializer", "ServerScriptService.Services.Road.RoadHistoryService",
			"ServerScriptService.Services.Road.RoadService", "ServerScriptService.Services.Road.RoadReplicationService",
			"StarterPlayer.StarterPlayerScripts.Controllers.RoadPlacementController", "StarterPlayer.StarterPlayerScripts.Controllers.RoadDockPanel",
			"ReplicatedStorage.Road.RoadNavigationGraph", "ReplicatedStorage.Road.IntersectionRenderer" } do
			PATCHES[f] = D .. "/fix5/" .. sub .. "/" .. f .. ".luau"
		end
		mode = "fix4"
	elseif mode == "fix4" then
		PATCHES["ServerScriptService.Services.NPC.NPCDriverService"] = D .. "/fix4/new/NPCDriverService.luau"
		PATCHES["ServerScriptService.Services.Util.PathFollower"] = D .. "/fix4/new/PathFollower.luau"
	end
	local Studio = require("./studio")
	local g = Studio.game
	Studio.mount(D .. "/dump/ReplicatedStorage", g.ReplicatedStorage)
	Studio.mount(D .. "/dump/ReplicatedFirst", g.ReplicatedFirst)
	Studio.mount(D .. "/dump/ServerScriptService", g.ServerScriptService)
	Studio.mount(D .. "/dump/ServerStorage", g.ServerStorage)
	local sps = Studio.newInstance("StarterPlayerScripts", "StarterPlayerScripts")
	sps.Parent = g.StarterPlayer
	Studio.mount(D .. "/dump2/SPS", sps)
	if mode == "patched" or mode == "fix4" then
		for path, file in PATCHES do Studio.overlay(path, file) end
	end
	return Studio
end
