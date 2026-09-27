--!strict
-- Reserved-server cache reuse. A wrong "yes" here hands out an access code minted for
-- another place and the teleport dies on a bare "unexpected error" (769) -- and because
-- the cache keeps serving that same code, the player can never reach their city again.
-- A wrong "no" only costs one extra ReserveServer, so this errs toward re-reserving.

return function()
	local CityTeleport = require(script.Parent["CityTeleport"])
	local cachedCode = CityTeleport._cachedCode

	local HERE, ELSEWHERE = 111, 222

	describe("_cachedCode", function()
		it("reuses a code reserved against this place", function()
			expect(cachedCode({ code = "abc", placeId = HERE }, HERE)).to.equal("abc")
		end)

		it("refuses a code reserved against another place", function()
			-- The 769 that started all this: a code minted for the old sub-place.
			expect(cachedCode({ code = "abc", placeId = ELSEWHERE }, HERE)).to.equal(nil)
		end)

		it("refuses a legacy bare string, which carries no place to check", function()
			expect(cachedCode("abc", HERE)).to.equal(nil)
		end)

		it("refuses an empty store entry", function()
			expect(cachedCode(nil, HERE)).to.equal(nil)
		end)

		it("refuses a malformed entry", function()
			expect(cachedCode({ placeId = HERE }, HERE)).to.equal(nil)
			expect(cachedCode({ code = "", placeId = HERE }, HERE)).to.equal(nil)
			expect(cachedCode({ code = 42, placeId = HERE }, HERE)).to.equal(nil)
		end)
	end)
end
