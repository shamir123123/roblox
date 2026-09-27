--!strict
-- The pacing contract: no city reaches Megalopolis in under three hours of real time, and
-- the ladder, permits and grants agree with each other. No framework -- `require(...).run()`
-- asserts.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

return {
	run = function()
		local M = require(script.Parent)
		local TerritoryGrid = require(ReplicatedStorage.City.TerritoryGrid)
		local ladder = M.Ladder

		local minutes = ladder[#ladder].xp / M.XP_RATE_CAP_PER_MIN
		assert(minutes >= 180, ("max-rate run finishes in %.0f min, under 3 h"):format(minutes))

		assert(#ladder == #TerritoryGrid.PERMITS, "one permit count per milestone")
		assert(TerritoryGrid.allowanceFor(#ladder) == TerritoryGrid.TOTAL, "last milestone opens the whole map")
		assert(TerritoryGrid.allowanceFor(1) == TerritoryGrid.START_TILES, "Founding holds exactly the starting block")
		for i = 2, #ladder do
			assert(ladder[i].xp > ladder[i - 1].xp, "xp thresholds ascend at " .. i)
			assert(ladder[i].money > 0 and ladder[i].dp > 0, "milestone " .. i .. " pays out")
			assert(TerritoryGrid.PERMITS[i] > TerritoryGrid.PERMITS[i - 1], "milestone " .. i .. " grants land")
		end

		assert(M.tierFor(0) == 1 and M.tierFor(99) == 1 and M.tierFor(100) == 2, "tierFor edges")
		assert(M.tierFor(1e9) == #ladder, "tierFor top")
		assert(M.zoneMilestone("Low") == nil, "low density is never gated")
		assert(M.zoneMilestone("Medium") and M.zoneMilestone("High") and M.zoneMilestone("Mixed"), "denser housing is gated")

		-- The tile maths the panel quotes and the server charges.
		assert(TerritoryGrid.priceForBatch(9, 3) == 1000 + 1025 + 1050, "batch = each tile priced as the next")
		assert(#TerritoryGrid.startIds(-99999, -99999) == 9, "corner start still gets nine tiles")
		assert(#TerritoryGrid.fromLegacy({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
			19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36 }) == TerritoryGrid.TOTAL,
			"a fully-owned legacy map migrates to the full new map")
		assert(#TerritoryGrid.idsInRect(TerritoryGrid.idOf(3, 3), TerritoryGrid.idOf(0, 1)) == 12, "drag box 4x3")
		return true
	end,
}
