--!strict
-- Which kind of server am I? Everything routes off this: a wrong answer either strands
-- players in a lobby that never teleports, or boots the whole gameplay stack inside the
-- menu place. Pinned here because none of it is visible until the second place exists,
-- which Studio cannot make.

return function()
	local PlacesConfig = require(script.Parent["PlacesConfig"])
	local placeRole = PlacesConfig._placeRole
	local isReserved = PlacesConfig._isReserved

	local LOBBY = PlacesConfig.LOBBY_PLACE_ID
	local CITY = 999999999 -- any id that is not the lobby
	local UNSET, LIVE = 0, false

	describe("placeRole", function()
		it("calls the start place the lobby", function()
			expect(placeRole(LOBBY, CITY, LIVE)).to.equal("lobby")
		end)

		it("calls the second place a city", function()
			expect(placeRole(CITY, CITY, LIVE)).to.equal("city")
		end)

		it("is always studio in Studio, either place", function()
			-- Studio cannot teleport; without this an F5 playtest dead-ends in the
			-- lobby instead of loading the city in place.
			expect(placeRole(LOBBY, CITY, true)).to.equal("studio")
			expect(placeRole(CITY, CITY, true)).to.equal("studio")
		end)

		it("is a city everywhere while the city place is UNSET", function()
			-- The safety that lets this file ship to the old place before the split is
			-- wired. If this ever returns "lobby", publishing strands the live game on a
			-- menu with nowhere to teleport to.
			expect(placeRole(LOBBY, UNSET, LIVE)).to.equal("city")
			expect(placeRole(CITY, UNSET, LIVE)).to.equal("city")
		end)
	end)

	describe("isReserved", function()
		it("says no to a public server", function()
			expect(isReserved("", 0)).to.equal(false)
		end)

		it("says yes to a reserved server", function()
			expect(isReserved("abc-123", 0)).to.equal(true)
		end)

		it("does not mistake a VIP server for one of ours", function()
			-- VIP servers carry a PrivateServerId too, but they are somebody's paid
			-- server with no access-store entry -- gating them fails closed on the
			-- owner lookup and kicks everyone inside.
			expect(isReserved("abc-123", 555)).to.equal(false)
		end)
	end)
end
