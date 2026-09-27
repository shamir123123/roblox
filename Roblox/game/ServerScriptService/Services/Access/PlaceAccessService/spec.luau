--!strict
return function()
	local decide = require(script.Parent)._decide

	local function ctx(over: any): any
		local base = {
			isStudio = false, reserved = true, isStaff = false,
			resolved = true, ownerId = 100, allowed = {}, userId = 999,
			seatsFull = false, isFriend = false,
			ownerPresent = true, friendsOffline = false, multiplayer = true,
		}
		for k, v in pairs(over) do base[k] = v end
		return base
	end

	describe("access decision", function()
		it("lets the owner in", function()
			expect(decide(ctx({ userId = 100 }))).to.equal(true)
		end)
		it("lets an invited visitor in", function()
			expect(decide(ctx({ userId = 7, allowed = { [7] = true } }))).to.equal(true)
		end)
		it("kicks an uninvited stranger", function()
			expect(decide(ctx({}))).to.equal(false)
		end)
		it("always lets staff in", function()
			expect(decide(ctx({ isStaff = true }))).to.equal(true)
		end)
		it("bypasses in Studio", function()
			expect(decide(ctx({ isStudio = true }))).to.equal(true)
		end)
		it("does not gate a non-reserved (public/legacy) server", function()
			expect(decide(ctx({ reserved = false }))).to.equal(true)
		end)
		it("fails closed for a stranger before the owner resolves", function()
			expect(decide(ctx({ resolved = false }))).to.equal(false)
		end)
		it("still lets staff in before resolution", function()
			expect(decide(ctx({ resolved = false, isStaff = true }))).to.equal(true)
		end)
	end)

	-- The seat cap. It sits BELOW the place's MaxPlayers on purpose: the headroom is
	-- what keeps the two doors below open, and a wrong edit here closes them quietly.
	describe("seat cap", function()
		it("turns an invited visitor away once the server is full", function()
			expect(decide(ctx({ userId = 7, allowed = { [7] = true }, seatsFull = true }))).to.equal(false)
		end)
		it("lets the OWNER in even when it is full", function()
			-- A full city that locks out the person whose city it is leaves them with
			-- nowhere to go and nothing to come back to.
			expect(decide(ctx({ userId = 100, seatsFull = true }))).to.equal(true)
		end)
		it("lets STAFF in even when it is full", function()
			expect(decide(ctx({ isStaff = true, seatsFull = true }))).to.equal(true)
		end)
		it("does not apply the cap to a public server", function()
			expect(decide(ctx({ reserved = false, seatsFull = true }))).to.equal(true)
		end)
	end)
	-- Multiplayer. A city's guest list IS the owner's Roblox friend list, so these rows
	-- are the whole feature -- close them by accident and every city is solo again.
	describe("friends", function()
		it("lets a friend of the owner in", function()
			expect(decide(ctx({ isFriend = true }))).to.equal(true)
		end)
		it("still keeps a non-friend stranger out", function()
			expect(decide(ctx({ isFriend = false }))).to.equal(false)
		end)
		it("turns a friend away once the server is full", function()
			expect(decide(ctx({ isFriend = true, seatsFull = true }))).to.equal(false)
		end)
		it("keeps a friend out once the owner has left and the door is shut", function()
			expect(decide(ctx({ isFriend = true, ownerPresent = false }))).to.equal(false)
		end)
		it("lets a friend in with the owner away IF the owner left the door open", function()
			expect(decide(ctx({ isFriend = true, ownerPresent = false, friendsOffline = true }))).to.equal(true)
		end)
		it("does not let the open door past the seat cap", function()
			expect(decide(ctx({ isFriend = true, ownerPresent = false, friendsOffline = true, seatsFull = true }))).to.equal(false)
		end)
		it("does not let the open door admit a NON-friend", function()
			expect(decide(ctx({ isFriend = false, ownerPresent = false, friendsOffline = true }))).to.equal(false)
		end)
		it("does not let a friend past an unresolved owner", function()
			-- A failed owner lookup means we do not know whose city this is, so
			-- "friend of the owner" is not a question that has an answer yet.
			expect(decide(ctx({ isFriend = true, resolved = false }))).to.equal(false)
		end)
	end)
	-- Anything unexpected in the record must read as SHUT. This parses a stored blob, so
	-- the failure that matters is a malformed one reading as "open".
	describe("readFriendsOffline", function()
		local read = require(script.Parent)._readFriendsOffline
		it("reads the flag when set", function()
			expect(read({ values = { friendsOffline = true } })).to.equal(true)
		end)
		it("is shut when the flag is absent", function()
			expect(read({ values = { autosave = true } })).to.equal(false)
		end)
		it("is shut on a record with no values table", function()
			expect(read({ binds = {} })).to.equal(false)
		end)
		it("is shut on nil, the never-saved-settings case", function()
			expect(read(nil)).to.equal(false)
		end)
		it("is shut on a truthy non-true value", function()
			expect(read({ values = { friendsOffline = "yes" } })).to.equal(false)
		end)
	end)
	-- Solo vs multiplayer, chosen at creation. Solo must beat every other door except
	-- staff -- if any of these open, "solo city" is a lie.
	describe("solo city", function()
		it("lets the owner into their own solo city", function()
			expect(decide(ctx({ userId = 100, multiplayer = false }))).to.equal(true)
		end)
		it("lets staff into a solo city", function()
			expect(decide(ctx({ isStaff = true, multiplayer = false }))).to.equal(true)
		end)
		it("keeps a FRIEND out of a solo city", function()
			expect(decide(ctx({ isFriend = true, multiplayer = false }))).to.equal(false)
		end)
		it("keeps a friend out even with the offline door open", function()
			expect(decide(ctx({ isFriend = true, ownerPresent = false,
				friendsOffline = true, multiplayer = false }))).to.equal(false)
		end)
		it("keeps a ROLED guest out of a solo city", function()
			expect(decide(ctx({ userId = 7, allowed = { [7] = "admin" }, multiplayer = false }))).to.equal(false)
		end)
	end)

	-- Any role is permission to enter; the role decides what they may DO.
	describe("roles admit", function()
		it("lets a visitor in", function()
			expect(decide(ctx({ userId = 7, allowed = { [7] = "visitor" } }))).to.equal(true)
		end)
		it("lets a builder in", function()
			expect(decide(ctx({ userId = 7, allowed = { [7] = "builder" } }))).to.equal(true)
		end)
		it("lets an admin in", function()
			expect(decide(ctx({ userId = 7, allowed = { [7] = "admin" } }))).to.equal(true)
		end)
		it("keeps out someone with no role at all", function()
			expect(decide(ctx({ userId = 7, allowed = {} }))).to.equal(false)
		end)
	end)
end
