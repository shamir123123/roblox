--!strict
-- Mutual exclusion for panels that occupy the same screen real estate.
--
-- The right-hand panels (Dashboard, Transport Overview) are both anchored to the right
-- edge at the same top and are near enough the same size, so when both were open one sat
-- entirely on top of the other -- and nothing arbitrated, because neither controller knew
-- the other existed. A slot is just a named region: claiming it closes whoever held it.
--
-- Usage, in a controller's Open():
--   PanelSlots.claim("rightPanel", "Dashboard", DashboardController.Close)
-- and in its Close():
--   PanelSlots.release("rightPanel", "Dashboard")

local PanelSlots = {}

type Occupants = { [string]: () -> () }
local _slots: { [string]: Occupants } = {}

-- Take over `slot`, closing whoever else holds it. Safe to call when already the holder:
-- re-claiming does not close you.
function PanelSlots.claim(slot: string, name: string, close: () -> ())
	local occupants = _slots[slot]
	if not occupants then
		occupants = {}
		_slots[slot] = occupants
	end

	local evicted: { () -> () } = {}
	for other, closeOther in occupants do
		if other ~= name then
			-- Cleared BEFORE closing: the close handler calls release() for itself, and
			-- mutating the table underneath that call would be a re-entrancy hazard.
			occupants[other] = nil
			table.insert(evicted, closeOther)
		end
	end
	occupants[name] = close

	for _, closeOther in evicted do
		-- Isolated: one panel failing to close must never stop the incoming panel opening.
		local ok, err = pcall(closeOther)
		if not ok then
			warn("[PanelSlots] close handler for slot '" .. slot .. "' errored: " .. tostring(err))
		end
	end
end

function PanelSlots.release(slot: string, name: string)
	local occupants = _slots[slot]
	if occupants then
		occupants[name] = nil
	end
end

-- Who currently holds the slot, if anyone. Handy for debugging layout clashes.
function PanelSlots.holders(slot: string): { string }
	local names = {}
	for name in pairs(_slots[slot] or {}) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

return PanelSlots
