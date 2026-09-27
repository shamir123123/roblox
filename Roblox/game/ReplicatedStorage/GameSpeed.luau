--!strict
-- Single source of truth for the player-controlled simulation speed.
-- GameSpeed is a workspace attribute (0 = paused, 1/2/3 = time multiplier) set by
-- Bootstrap and driven by the RequestGameSpeed remote. Every per-frame system reads
-- it THROUGH here so the whole game -- and anything added later -- pauses and
-- fast-forwards together. Shared: safe to require on client and server.

local Workspace = game:GetService("Workspace")

local GameSpeed = {}

-- Current speed clamped to the valid 0..3 range. Fractional values pass through for
-- callers that scale a continuous accumulator; use steps() for fixed-timestep AI.
function GameSpeed.get(): number
	return math.clamp(tonumber(Workspace:GetAttribute("GameSpeed")) or 1, 0, 3)
end

-- Integer number of fixed substeps to run this frame: 0 paused, else 1/2/3. Use for
-- tuned fixed-timestep AI (cars, walkers) -- run the step this many times at real dt
-- so each step keeps the size it was tuned for instead of overshooting at 2x/3x.
function GameSpeed.steps(): number
	return math.clamp(math.floor(tonumber(Workspace:GetAttribute("GameSpeed")) or 1), 0, 3)
end

-- dt scaled by the current speed: 0 while paused, dt*2 / dt*3 on fast-forward. Use
-- for continuous accumulators (phase timers, the day clock, animation progress)
-- that have no per-step overshoot concern.
function GameSpeed.scaled(dt: number): number
	return dt * GameSpeed.get()
end

function GameSpeed.isPaused(): boolean
	return GameSpeed.get() <= 0
end

return GameSpeed
