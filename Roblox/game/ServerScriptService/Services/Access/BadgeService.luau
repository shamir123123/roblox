--!strict
-- BadgeService
-- Awards Roblox badges. One place that knows every badge id and the rule that earns it.
--
-- SET THE IDS BELOW. Badges are created on the Creator Dashboard
-- (create.roblox.com -> your experience -> Badges -> Create Badge), not from code --
-- there is no API to make one. An id left at 0 is skipped silently, so the game runs
-- fine before the badges exist.
--
-- Badges never award in Studio (AwardBadgeAsync only works in a published server), so a
-- Studio session logs the attempt and moves on.

local BadgeServiceApi = game:GetService("BadgeService")
local Players         = game:GetService("Players")
local RunService      = game:GetService("RunService")

local StaffRoster = require(script.Parent:WaitForChild("StaffRoster"))

-- Fill these in from the dashboard.
local BADGES = table.freeze({
	Welcome = 2000898960818340, -- "OG Citizen" -- awarded to everyone on join
	Tester  = 4486403279456408, -- "Closed Tester" -- awarded to anyone on the staff roster
})

-- How long to wait for the roster's first read before deciding someone is not a tester.
local ROSTER_WAIT = 15

local BadgeService = {}

local _tester: any = nil
local _bound = false

-- Returns true if the player now holds the badge (already had it, or we just gave it).
function BadgeService.award(player: Player, key: string): boolean
	local id = BADGES[key]
	if not id or id == 0 then return false end
	if RunService:IsStudio() then
		print(("[BadgeService] Studio: would award %s to %s"):format(key, player.Name))
		return false
	end

	local ok, has = pcall(BadgeServiceApi.UserHasBadgeAsync, BadgeServiceApi, player.UserId, id)
	if not ok then
		warn(("[BadgeService] UserHasBadgeAsync failed for %s/%s: %s"):format(player.Name, key, tostring(has)))
		return false
	end
	if has then return true end

	local awarded, err = pcall(BadgeServiceApi.AwardBadgeAsync, BadgeServiceApi, player.UserId, id)
	if not awarded then
		warn(("[BadgeService] AwardBadgeAsync failed for %s/%s: %s"):format(player.Name, key, tostring(err)))
		return false
	end
	return true
end

local function onJoin(player: Player)
	task.spawn(function()
		BadgeService.award(player, "Welcome")

		-- The roster is a DataStore read; a joiner can beat it. Waiting beats calling a
		-- real tester a non-tester and never giving them the badge this session.
		if not StaffRoster.isReady() then
			StaffRoster.await(ROSTER_WAIT)
		end
		if player.Parent == nil then return end
		if _tester and _tester.isTester(player) then
			BadgeService.award(player, "Tester")
		end
	end)
end

function BadgeService.Init(testerService: any)
	assert(testerService, "BadgeService requires TesterService")
	_tester = testerService
end

function BadgeService.Bind()
	if _bound then return end
	_bound = true
	Players.PlayerAdded:Connect(onJoin)
	for _, player in Players:GetPlayers() do
		onJoin(player)
	end
end

function BadgeService.Start() end

return BadgeService
