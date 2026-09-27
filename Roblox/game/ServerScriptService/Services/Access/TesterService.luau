--!strict
-- TesterService
-- Closed-test access gate. In a PUBLISHED server, any player who is not on the staff
-- roster (and is not the place owner) is kicked on join. ALWAYS bypassed in Studio so
-- the developer can test freely. Flip ENABLED to false (or drop the service from the
-- boot list) to open the game to everyone.
--
-- The allowlist is NOT here any more. It lives in StaffRoster, backed by a DataStore
-- the owner edits from the staff panel's Access tab, so letting a tester in no longer
-- means editing this script and publishing.
--
-- Access control only -- it does not grant build/admin rights (see CanEditRoads /
-- AdminTier for those).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local StaffRoster = require(script.Parent:WaitForChild("StaffRoster"))

local TesterService = {}

-- Master switch for the closed test. Set false to let everyone in.
local ENABLED = false

-- How long a joiner is held while the roster's first read lands. They have no character
-- yet, so this is invisible to them -- far better than kicking a real tester because the
-- DataStore answered a second too late.
local ROSTER_WAIT = 15

local KICK_MESSAGE = "City Districts is in closed testing \u{2014} you don't have access yet. Thanks for your patience!"
local KICK_UNVERIFIED = "Couldn't check your access just now \u{2014} please rejoin in a minute."

local _bound = false

-- Staff of any tier (tester or admin) may be in the closed test; StaffRoster.tierOf
-- already answers "admin" for the owner, so there is no separate owner branch here.
local function isAllowed(player: Player): boolean
	if not ENABLED then return true end
	if RunService:IsStudio() then return true end -- dev always tests in Studio
	return StaffRoster.tierOf(player.UserId) ~= nil
end

local function gate(player: Player)
	if not ENABLED or RunService:IsStudio() then return end
	-- The owner is decided off the place itself, with no DataStore read in the way.
	if StaffRoster.isOwner(player.UserId) then return end

	task.spawn(function()
		if not StaffRoster.isReady() then
			StaffRoster.await(ROSTER_WAIT)
		end
		-- They may have left while we waited; Kick on a gone player is a harmless no-op,
		-- but there is no reason to walk the roster for someone who is not here.
		if player.Parent == nil then return end
		if isAllowed(player) then return end
		-- A roster we could not read is an outage, not a decision -- say so, so a real
		-- tester knows to rejoin rather than thinking they were dropped from the test.
		player:Kick(if StaffRoster.isDegraded() then KICK_UNVERIFIED else KICK_MESSAGE)
	end)
end

-- Public: other systems can ask without re-implementing the rule.
function TesterService.isTester(player: Player): boolean
	return isAllowed(player)
end

-- Owner resolution moved to StaffRoster, which every gate now shares. Kept as a no-op
-- so the boot script's Init/Bind/Start shape is the same for every service.
function TesterService.Init()
end

function TesterService.Bind()
	if _bound then return end
	_bound = true
	-- Connect FIRST (Bootstrap binds this before everything) so a rejected player is
	-- kicked before their data loads or GUI clones.
	Players.PlayerAdded:Connect(gate)
	-- Late-join: gate anyone already connected when the service starts.
	for _, player in Players:GetPlayers() do
		gate(player)
	end
	-- The roster can change mid-session (the owner removing someone, or another server's
	-- edit arriving). Re-gate everyone so a revoked tester actually leaves a closed test
	-- instead of keeping the access they had at join time.
	StaffRoster.onChanged(function()
		for _, player in Players:GetPlayers() do
			gate(player)
		end
	end)
end

function TesterService.Start() end

return TesterService
