--!strict
-- Roles come off a stored record and, on the grant path, straight off a remote. The
-- failure that matters is an unreadable one reading as a CAPABILITY -- a junk value that
-- normalizes to "admin" hands a stranger the bulldozer.

return function()
	local CityRoles = require(script.Parent)

	describe("normalize", function()
		it("passes the three real roles through", function()
			expect(CityRoles.normalize("visitor")).to.equal("visitor")
			expect(CityRoles.normalize("builder")).to.equal("builder")
			expect(CityRoles.normalize("admin")).to.equal("admin")
		end)
		it("migrates a legacy `true` grant to visitor", function()
			-- Those grants predate roles, when editing was owner-only. Migrating them to
			-- builder would hand every old invite the bulldozer on first load.
			expect(CityRoles.normalize(true)).to.equal("visitor")
		end)
		it("refuses nil", function()
			expect(CityRoles.normalize(nil)).to.equal(nil)
		end)
		it("refuses an unknown string", function()
			expect(CityRoles.normalize("owner")).to.equal(nil)
			expect(CityRoles.normalize("Admin")).to.equal(nil)
		end)
		it("refuses a non-string, non-true value", function()
			expect(CityRoles.normalize(1)).to.equal(nil)
			expect(CityRoles.normalize(false)).to.equal(nil)
			expect(CityRoles.normalize({})).to.equal(nil)
		end)
	end)

	describe("canEdit", function()
		it("is true for builder and admin", function()
			expect(CityRoles.canEdit("builder")).to.equal(true)
			expect(CityRoles.canEdit("admin")).to.equal(true)
		end)
		it("is FALSE for a visitor", function()
			expect(CityRoles.canEdit("visitor")).to.equal(false)
		end)
		it("is false for no role and for junk", function()
			expect(CityRoles.canEdit(nil)).to.equal(false)
			expect(CityRoles.canEdit("admin ")).to.equal(false)
		end)
		it("is false for a legacy grant", function()
			expect(CityRoles.canEdit(true)).to.equal(false)
		end)
	end)

	describe("canManage", function()
		it("is admin only", function()
			expect(CityRoles.canManage("admin")).to.equal(true)
			expect(CityRoles.canManage("builder")).to.equal(false)
			expect(CityRoles.canManage("visitor")).to.equal(false)
			expect(CityRoles.canManage(nil)).to.equal(false)
		end)
	end)
end
