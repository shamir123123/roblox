--!strict
-- FreePlacement
-- A shared, purely client-local UI preference -- NOT server-authoritative state (contrast
-- with GameSpeed, which syncs via a Workspace attribute because the server genuinely needs
-- to agree on it). This is a plain module-level boolean singleton, same shape and same
-- reason for existing as Road.SnapUtil's _angleFreeOverride / setAngleFreeOverride /
-- isAngleFreeOverride: one flag, no dependency on which specific tool or gesture mode is
-- currently active, read directly by whichever system cares.
--
-- Independent of any one tool's gesture selector. A tool can be in Single mode with this
-- off, Single mode with this on, Curve mode with this on, etc. -- this toggle and a tool's
-- own mode selector are two separate, orthogonal axes, not one 5-way exclusive choice.
--
-- Lives in ReplicatedStorage.Shared (not nested under Road, Nature, etc.) because it is
-- not owned by any single placement system -- Nature is the first consumer, but Roads /
-- Zoning / Buildings can require this exact same module later, the same way multiple road
-- tools already require Road.SnapUtil today.

local FreePlacement = {}

local _enabled = false

function FreePlacement.setEnabled(on: boolean)
	_enabled = on
end

function FreePlacement.isEnabled(): boolean
	return _enabled
end

return FreePlacement
