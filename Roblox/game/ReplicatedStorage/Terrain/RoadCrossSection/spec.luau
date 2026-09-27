--!strict
-- The vertical-mode decision. No framework -- `require(...).run()` asserts.
--
-- This is the whole of the road modes: Auto, Bridge, Tunnel and Ground are one function with
-- a different `allow` set, so these checks cover all four. What makes it worth pinning is
-- that the failure is silent and expensive -- a threshold slightly too low turns ordinary
-- streets into viaducts across the whole map, slightly too high and a road drives straight
-- through a hill with no tunnel.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local X = require(ReplicatedStorage.Terrain.RoadCrossSection)

local M = {}

-- A straight run of road at a constant height, 10 points over 200 studs.
local function span(roadY: number): { Vector3 }
	local pts = {}
	for i = 0, 9 do
		pts[i + 1] = Vector3.new(i * 20, roadY, 0)
	end
	return pts
end

local function flat(h: number)
	return function(_x: number, _z: number): number return h end
end

function M.run(): boolean
	local DEEP = X.tunnelMinDepth
	local HIGH = X.elevatedMinHeight

	-- Ordinary ground: the road sits on the land, nothing to build.
	assert(X.verticalModeFor(span(0), flat(0)) == X.GROUND, "flat ground did not stay a ground road")

	-- Small deviations must NOT trigger structure. This is the expensive direction to get
	-- wrong: a threshold a little too eager puts viaducts and portals all over an ordinary
	-- city, and every one of them is a visual and a cost the player never asked for.
	assert(X.verticalModeFor(span(0), flat(DEEP - 0.5)) == X.GROUND,
		"a rise just under the tunnel threshold bored a tunnel")
	assert(X.verticalModeFor(span(HIGH - 0.5), flat(0)) == X.GROUND,
		"a road just under the elevated threshold went up on pillars")

	-- Past the thresholds it commits.
	assert(X.verticalModeFor(span(0), flat(DEEP + 4)) == X.TUNNEL,
		"ground well above the road did not bore a tunnel")
	assert(X.verticalModeFor(span(HIGH + 4), flat(0)) == X.ELEVATED,
		"a road well above the ground did not go up on pillars")

	-- The deviation only has to happen SOMEWHERE along the span: a segment carries one mode,
	-- so one hill in the middle is enough to make the whole thing a tunnel.
	local oneHill = function(x: number, _z: number): number
		return if x > 80 and x < 120 then DEEP + 6 else 0
	end
	assert(X.verticalModeFor(span(0), oneHill) == X.TUNNEL,
		"a hill partway along the span did not make it a tunnel")

	-- `allow` is what separates the four modes, and a restricted mode FALLS BACK to ground
	-- rather than doing nothing -- "it will always try to, but if it can't, it won't".
	assert(X.verticalModeFor(span(0), flat(DEEP + 4), { elevated = true, tunnel = false }) == X.GROUND,
		"bridge-only mode bored a tunnel")
	assert(X.verticalModeFor(span(HIGH + 4), flat(0), { elevated = false, tunnel = true }) == X.GROUND,
		"tunnel-only mode went up on pillars")
	assert(X.verticalModeFor(span(HIGH + 4), flat(0), { elevated = false, tunnel = false }) == X.GROUND,
		"ground-only mode left the ground")
	-- ...and still builds the one it IS allowed
	assert(X.verticalModeFor(span(0), flat(DEEP + 4), { elevated = false, tunnel = true }) == X.TUNNEL,
		"tunnel-only mode refused a tunnel it was allowed")

	-- A span that both cuts a rise AND crosses a dip can only be one thing. Whichever need is
	-- more extreme RELATIVE TO ITS OWN threshold wins -- comparing raw studs would just
	-- favour whichever threshold happens to be the smaller number.
	local bigHillSmallDip = function(x: number, _z: number): number
		if x < 60 then return DEEP * 4 end   -- ground far above the road
		if x > 140 then return -(HIGH + 1) end -- ground just below it
		return 0
	end
	assert(X.verticalModeFor(span(0), bigHillSmallDip) == X.TUNNEL,
		"the far more extreme rise lost to a marginal dip")
	local smallRiseBigGap = function(x: number, _z: number): number
		if x < 60 then return DEEP + 1 end
		if x > 140 then return -(HIGH * 4) end
		return 0
	end
	assert(X.verticalModeFor(span(0), smallRiseBigGap) == X.ELEVATED,
		"the far more extreme gap lost to a marginal rise")

	print("[RoadCrossSection.spec] OK")
	return true
end

return M
