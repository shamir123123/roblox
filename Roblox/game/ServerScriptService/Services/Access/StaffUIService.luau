--!strict
-- StaffUIService
-- Delivers the staff UI bundle. The F4 admin/tester panel and the F6 developer panel no
-- longer ship in StarterPlayerScripts: they sit in ServerStorage.StaffUI.StaffTools, and
-- this service hands a copy to a player only once StaffRoster confirms they are staff.
--
-- Why it moved: everything under StarterPlayer replicates to EVERY client on join. The
-- panels were one attribute away from being usable by anyone willing to look, and the
-- code itself named every admin remote and the exact shape each one accepts. A non-staff
-- client is now never sent any of it.
--
-- PlayerGui, not PlayerScripts: the server cannot reach a player's PlayerScripts at all
-- (it is client-only). A LocalScript runs anywhere under PlayerGui, and the bundle's
-- modules look PlayerScripts up by name, so nothing is lost by landing here. A plain
-- Folder is used rather than a ScreenGui so respawn resets never apply to it.
--
-- This is DELIVERY, not authorization. Taking the bundle away does not make the admin
-- remotes safe -- they re-check tier server-side on every call, and always did. The two
-- together are the point: the server refuses the request, and the client never had the
-- code to make it.

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

local StaffUIService = {}

local BUNDLE_NAME = "StaffTools"
-- A revoked player's own StaffBoot tears the panels down when AdminTier clears. Give it a
-- moment to do that before the folder goes, purely so the teardown is tidy -- the access
-- itself is already gone the instant the roster changed.
local WITHDRAW_DELAY = 2
local PLAYERGUI_TIMEOUT = 30

local _bundle: Instance? = nil
local _roster: any = nil
local _bound = false

local function tierFor(player: Player): string?
	-- Studio is always staff, matching AdminService -- otherwise an F5 playtest would come
	-- up with no panels at all.
	if RunService:IsStudio() then return "admin" end
	if not _roster then return nil end
	return _roster.tierOf(player.UserId)
end

local function bundleIn(player: Player): Instance?
	local playerGui = player:FindFirstChild("PlayerGui")
	return playerGui and playerGui:FindFirstChild(BUNDLE_NAME)
end

local function deliver(player: Player)
	local bundle = _bundle
	if not bundle then return end

	local playerGui = player:WaitForChild("PlayerGui", PLAYERGUI_TIMEOUT)
	if not playerGui then
		warn("[StaffUIService] PlayerGui never arrived for", player.Name, "-- no staff panel")
		return
	end
	-- Re-check after the yield: they may have been revoked, or have left, while we waited.
	if not player.Parent or not tierFor(player) then return end
	if playerGui:FindFirstChild(BUNDLE_NAME) then return end

	local clone = bundle:Clone()
	clone.Name = BUNDLE_NAME
	clone.Parent = playerGui
end

local function withdraw(player: Player)
	local existing = bundleIn(player)
	if not existing then return end

	task.delay(WITHDRAW_DELAY, function()
		-- The owner may have re-granted inside the grace window, in which case this folder
		-- is the one they are meant to keep.
		if not player.Parent then return end
		if tierFor(player) then return end
		if existing.Parent then existing:Destroy() end
	end)
end

-- One decision point, used by both the join path and every roster change.
local function sync(player: Player)
	if not player.Parent then return end
	if tierFor(player) then
		task.spawn(deliver, player)
	else
		withdraw(player)
	end
end

StaffUIService.Sync = sync

-- Init may not yield (CLAUDE rule): just resolve the bundle and keep the roster ref.
function StaffUIService.Init(staffRoster: any)
	if not staffRoster then
		error("[StaffUIService] Init requires StaffRoster -- it decides who gets the panels")
	end
	_roster = staffRoster

	local ServerStorage = game:GetService("ServerStorage")
	local staffUI = ServerStorage:FindFirstChild("StaffUI")
	_bundle = staffUI and staffUI:FindFirstChild(BUNDLE_NAME)
	if not _bundle then
		warn("[StaffUIService] ServerStorage.StaffUI." .. BUNDLE_NAME
			.. " is missing -- nobody will get the staff panels")
	end
end

function StaffUIService.Bind()
	if _bound then return end
	_bound = true

	Players.PlayerAdded:Connect(sync)
	for _, player in Players:GetPlayers() do
		sync(player)
	end

	-- The roster resolving for the first time is itself a change, so a staff member who
	-- joined before the first DataStore read landed is picked up here rather than being
	-- left without a panel for the session.
	if _roster then
		_roster.onChanged(function()
			for _, player in Players:GetPlayers() do
				sync(player)
			end
		end)
	end
end

function StaffUIService.Start() end

return StaffUIService
