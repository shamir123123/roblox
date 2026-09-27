-- Build a Studio stand-in over the Rojo tree (Roblox/game). Run the lab from tools/test-lab.
-- mode "orig" mounts $CITY_LAB_ORIG instead: another game/ tree to compare against, e.g.
--   git worktree add /tmp/before <commit> && CITY_LAB_ORIG=/tmp/before/Roblox/game
-- Any other mode mounts this checkout's game/ (override with $CITY_LAB_GAME).
-- Models, templates and other non-script assets come from the place file at
-- $CITY_LAB_PLACE (scripts inside it are ignored; the source tree wins).
local process = require("@lune/process")

return function(mode: string)
	local root = if mode == "orig"
		then assert(process.env.CITY_LAB_ORIG, "mode orig needs CITY_LAB_ORIG = path to a game/ tree")
		else (process.env.CITY_LAB_GAME or "../../game")
	local Studio = require("./studio")
	local g = Studio.game
	Studio.mount(root .. "/ReplicatedStorage", g.ReplicatedStorage)
	Studio.mount(root .. "/ReplicatedFirst", g.ReplicatedFirst)
	Studio.mount(root .. "/ServerScriptService", g.ServerScriptService)
	Studio.mount(root .. "/ServerStorage", g.ServerStorage)
	local sps = Studio.newInstance("StarterPlayerScripts", "StarterPlayerScripts")
	sps.Parent = g.StarterPlayer
	Studio.mount(root .. "/StarterPlayer/StarterPlayerScripts", sps)
	local place = assert(process.env.CITY_LAB_PLACE, "set CITY_LAB_PLACE to the place file (.rbxl) for its models")
	require("./models")(Studio).mountPlace(place)
	return Studio
end
