--!strict
-- The bind lock. No framework -- `run(Settings)` asserts.
--
-- Settings.pressed is the single door every keybind and mouse-bind in the game walks
-- through, and that is the whole reason the asset gate can hold the entire keyboard with
-- one flag while a freshly loaded city finishes arriving. Both directions of that flag fail
-- silently and expensively: stuck open and the player builds in a city that is not there
-- yet, stuck shut and they are locked out of their own city with no key that answers.
--
-- Run it through the loadstring+setfenv shim. `run(Settings)` takes the module because this
-- lives in PlayerScripts and the harness decides which copy is under test. It reads the live
-- binds and never writes one: a spec that rebound a key would quietly rewrite the player's
-- own settings on the way past.

local M = {}

-- A stand-in for the InputObject an InputBegan handler is handed -- only the two fields
-- Settings reads. Built for a SINGLE-key bind only: a multi-input bind sends Settings off to
-- UserInputService to ask what else is held, and no fake can answer that.
local function keyEvent(key: Enum.KeyCode): any
	return { UserInputType = Enum.UserInputType.Keyboard, KeyCode = key }
end

-- The first action bound to exactly one keyboard key, whatever this player has rebound to.
local function soloKeyAction(Settings: any): (string, Enum.KeyCode)
	for _, def in Settings.actions() do
		local bind = Settings.getBind(def.id)
		if #bind == 1 and typeof(bind[1]) == "EnumItem" and bind[1].EnumType == Enum.KeyCode then
			return def.id, bind[1]
		end
	end
	error("[Settings.spec] nothing is bound to a single key -- no way to test the lock")
end

function M.run(Settings: any): boolean
	local wasLocked = Settings.bindsLocked()
	local action, key = soloKeyAction(Settings)
	local event = keyEvent(key)

	Settings.setBindsLocked(false)
	assert(Settings.pressed(action, event),
		`unlocked: {action} did not fire on its own key -- hold no modifier while running this, ` ..
		`pressed() is modifier-exclusive`)

	-- The lock. This is the assertion the asset gate rests on.
	Settings.setBindsLocked(true)
	assert(Settings.bindsLocked(), "setBindsLocked(true) did not take")
	assert(not Settings.pressed(action, event),
		`locked: {action} still fired -- the asset gate does not hold the keyboard, and the ` ..
		`player can build in a city that is still arriving`)

	-- And back. A lock with no release strands the player in their own city.
	Settings.setBindsLocked(false)
	assert(not Settings.bindsLocked(), "setBindsLocked(false) did not take")
	assert(Settings.pressed(action, event),
		`unlock: {action} stayed dead -- every keybind in the game is gone for the session`)

	Settings.setBindsLocked(wasLocked)
	return true
end

return M
