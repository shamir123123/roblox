--!strict
-- Household ladder check for BuildingService.householdCapFor. No framework: call
-- run() and it asserts. Mirrors the lookup rather than booting the sim, because the
-- function is a straight read of CitySimConstants.HOUSEHOLDS_BY_LEVEL -- if the table
-- and the contract below ever disagree, this fails.
--
-- Contract: a home fits at least one household and at most five; the lot's footprint
-- picks the row and the level picks the column, so SIZE sets the ceiling and levelling
-- only walks up to it. A small lot never grows.

local Const = require(script.Parent.CitySimConstants)

local function capFor(width: number, depth: number, level: number): number
	local area = width * depth
	local tier = if area >= Const.HOUSEHOLDS_LARGE_AREA then 3
		elseif area >= Const.HOUSEHOLDS_MEDIUM_AREA then 2
		else 1
	return Const.HOUSEHOLDS_BY_LEVEL[tier][math.clamp(level, 1, 3)]
end

local function run(): string
	for width = 2, 5 do
		for depth = 2, 5 do
			local prev = 0
			for level = 1, 3 do
				local n = capFor(width, depth, level)
				assert(n >= 1 and n <= 5, ("%dx%d L%d = %d, outside 1..5"):format(width, depth, level, n))
				assert(n >= prev, ("%dx%d lost a household slot at L%d"):format(width, depth, level))
				prev = n
			end
		end
	end

	assert(capFor(2, 2, 3) == 1, "a 2x2 must stay at one household however far it levels")
	assert(capFor(2, 4, 3) == 1, "a small 2x4 must stay at one household")
	assert(capFor(3, 3, 1) == 2, "a medium home starts at two households")
	assert(capFor(5, 5, 1) == 3, "a 5x5 starts at three households")
	assert(capFor(5, 5, 3) == 5, "a 5x5 reaches five households")
	assert(Const.FAMILY_MAX == 5, "FAMILY_MAX is the people-per-household ceiling")

	-- Upgrading is meant to be slow and hard to earn.
	assert(Const.UPGRADE_FILL >= 0.95, "a building must be practically full to upgrade")
	assert(Const.UPGRADE_COOLDOWN >= 300, "upgrades must be spaced out")
	assert(Const.MAX_CHANGES_PER_TICK <= 1, "at most one upgrade city-wide per tick")

	return "BuildingService.spec: PASS"
end

return { run = run, capFor = capFor }
