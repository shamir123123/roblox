--!strict
-- CityRoles
-- What a guest may do in somebody else's city. Three roles, two capabilities -- the
-- owner is not one of them (they are not on their own guest list and cannot be demoted).
--
-- Shared because the client needs the names for the role picker and the server needs the
-- capabilities for the gate. The CAPABILITIES are the server's answer, never the client's:
-- a client claiming "admin" proves nothing, the stored role on the owner's record does.

export type Role = "visitor" | "builder" | "admin"

local CityRoles = {
	-- Display order, least to most. A role picker reads this; nothing else should
	-- depend on the ordering.
	Order = table.freeze({ "visitor", "builder", "admin" } :: { Role }),

	Label = table.freeze({
		visitor = "Visitor",
		builder = "Builder",
		admin = "Admin",
	}),

	Blurb = table.freeze({
		visitor = "Can look around. Cannot change anything.",
		builder = "Can build, bulldoze and edit terrain.",
		admin = "Can build, and invite or remove other players.",
	}),

	-- Drives the CanEditRoads attribute, which is the SOLE server-side edit gate for
	-- roads, zoning and terrain on a published server.
	CanEdit = table.freeze({ builder = true, admin = true }),

	-- May change other players' roles. Never their own, and never the owner's.
	CanManage = table.freeze({ admin = true }),
}

-- Every stored role passes through here. `true` is the legacy shape from before roles
-- existed -- those grants were "may enter", with editing owner-only, so they migrate to
-- visitor. Anything unrecognised is nil: an unreadable role must not grant a capability.
function CityRoles.normalize(stored: any): Role?
	if stored == true then return "visitor" end
	if stored == "visitor" or stored == "builder" or stored == "admin" then
		return stored :: Role
	end
	return nil
end

function CityRoles.canEdit(role: any): boolean
	local r = CityRoles.normalize(role)
	return r ~= nil and CityRoles.CanEdit[r] == true
end

function CityRoles.canManage(role: any): boolean
	local r = CityRoles.normalize(role)
	return r ~= nil and CityRoles.CanManage[r] == true
end

return table.freeze(CityRoles)
