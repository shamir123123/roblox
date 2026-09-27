--!strict
-- Telemetry
-- Thin pcall wrapper over Roblox AnalyticsService for the beta: onboarding funnel
-- (city loaded, then on), milestone progression, and a few custom events.
-- Library module: stateless; every call is fire-and-forget and never throws.
-- Studio sessions log nothing so playtests never pollute the live charts.

local AnalyticsService = game:GetService("AnalyticsService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Telemetry = {}

local ENABLED = not RunService:IsStudio()

-- ponytail: beta city servers hold one player, so "the city owner" = the only
-- player. Pass the real owner from call sites if city servers go multiplayer.
local function resolve(player: Player?): Player?
	return player or Players:GetPlayers()[1]
end

-- Onboarding funnel (once per player lifetime; steps only count upward).
function Telemetry.funnelStep(step: number, stepName: string, player: Player?)
	if not ENABLED then return end
	local p = resolve(player)
	if not p then return end
	pcall(function()
		AnalyticsService:LogOnboardingFunnelStepEvent(p, step, stepName)
	end)
end

function Telemetry.milestone(tier: number, name: string, player: Player?)
	if not ENABLED then return end
	local p = resolve(player)
	if not p then return end
	pcall(function()
		AnalyticsService:LogProgressionCompleteEvent(p, "CityMilestones", tier, name)
	end)
end

function Telemetry.custom(eventName: string, value: number?, player: Player?)
	if not ENABLED then return end
	local p = resolve(player)
	if not p then return end
	pcall(function()
		AnalyticsService:LogCustomEvent(p, eventName, value or 1)
	end)
end

return Telemetry
