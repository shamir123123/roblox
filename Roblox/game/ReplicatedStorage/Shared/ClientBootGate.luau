--!strict
-- ClientBootGate: the client half of the join gate (server half: PlayerLoadService).
--
-- The server can say a player's record has LOADED, but only the client knows when it has
-- been APPLIED -- saved settings pushed into the store, the first slot index in hand. The
-- loading screen waits on both, so the menu never appears in the wrong language or with an
-- empty Continue button and then snaps a moment later.
--
-- Steps LATCH. A plain BindableEvent would not do: the loading screen lives in
-- ReplicatedFirst and the steps are marked from StarterPlayerScripts, so either order is
-- possible and a step marked first would be missed entirely. Marking is idempotent.
--
-- Steps in use:
--   "settings" -- Core.SettingsClient has applied the saved profile (or failed to fetch it)
--   "menu"     -- MainMenuController has its first slot index (or the menu failed to start)

local RunService = game:GetService("RunService")

if RunService:IsServer() then
	error("[ClientBootGate] Client-only module")
end

local POLL_INTERVAL = 0.1

local _done: { [string]: boolean } = {}

local ClientBootGate = {}

-- Call on BOTH the success and the failure path of whatever the step covers: a step that
-- can never be marked holds the loading screen until its timeout for no gain.
function ClientBootGate.markDone(step: string)
	_done[step] = true
end

function ClientBootGate.isDone(step: string): boolean
	return _done[step] == true
end

-- Yields until every step is marked or `timeout` seconds pass. Returns nil when they all
-- arrived, otherwise the first step still missing -- so the caller can log what stalled
-- rather than reporting a bare timeout.
function ClientBootGate.await(steps: { string }, timeout: number): string?
	local deadline = os.clock() + timeout

	while true do
		local missing: string? = nil
		for _, step in steps do
			if not _done[step] then
				missing = step
				break
			end
		end

		if not missing then return nil end
		if os.clock() >= deadline then return missing end

		task.wait(POLL_INTERVAL)
	end
end

return ClientBootGate
