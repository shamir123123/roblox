--!strict
-- PlacesConfig
-- TWO places in ONE experience. The start place is the LOBBY: a main menu and nothing
-- else. A city is a RESERVED server of the CITY place, one per owner, reached only by
-- teleport. Same experience both ways, so every DataStore is shared and nothing migrates.
--
-- Which place this is decides which half of the game boots (see both Bootstraps). It is
-- read off game.PlaceId, never off a stored flag: the SAME file is published to BOTH
-- places, so a flag would be wrong in one of them every time.
--
-- Reserved-vs-VIP is a SEPARATE question from which place this is, and folding them
-- together locks players out. A VIP server of the city place carries a PrivateServerId
-- but is somebody's paid server: it has no access-store entry, so the owner lookup
-- fails closed and the gate kicks everyone in it. isReservedCity() is what the join
-- gate wants; isCity() only answers which place.

local RunService = game:GetService("RunService")

-- The start place. An experience's start place cannot be changed after creation, so
-- this is the lobby by necessity rather than by choice.
local LOBBY_PLACE_ID = 115322407625724

-- The city place. Set 0 to turn the split OFF: every live server then classifies as
-- "city", which IS the single-place game exactly as it ran before the split. That is the
-- revert if anything here goes wrong -- one number, no other edits.
local CITY_PLACE_ID = 119965010688194

local PlacesConfig = {
	-- Server topology only: which player owns a reserved server. Cannot live on a
	-- player record -- this IS the lookup that tells you whose record to open. The
	-- invite list is the owner's own data and lives on their record ("visitors").
	AccessStore = "CityDistrict_Access_v2",
	LOBBY_PLACE_ID = LOBBY_PLACE_ID,
	CITY_PLACE_ID = CITY_PLACE_ID,
}

export type Role = "studio" | "lobby" | "city"

-- Studio is its own role rather than folded into "lobby": it cannot teleport, so a
-- playtest routed down the lobby path would dead-end with nowhere to go. As "studio"
-- it loads the city in place and F5 still runs the whole menu -> city -> menu loop.
--
-- Pure so the spec can drive every role without a live server.
local function placeRole(placeId: number, cityPlaceId: number, isStudio: boolean): Role
	if isStudio then return "studio" end
	if cityPlaceId == 0 then return "city" end -- split not wired yet: one place, as before
	if placeId == LOBBY_PLACE_ID then return "lobby" end
	return "city"
end
PlacesConfig._placeRole = placeRole -- exposed for the spec

-- A reserved server WE made. VIP/private servers set PrivateServerOwnerId ~= 0; they
-- are not ours and must never be gated as somebody's city.
local function isReserved(privateServerId: string, privateServerOwnerId: number): boolean
	return privateServerId ~= "" and privateServerOwnerId == 0
end
PlacesConfig._isReserved = isReserved -- exposed for the spec

local function role(): Role
	return placeRole(game.PlaceId, CITY_PLACE_ID, RunService:IsStudio())
end

-- This server is the lobby: main menu only, no city, no gameplay services.
function PlacesConfig.isLobby(): boolean
	return role() == "lobby"
end

-- This server is in the CITY place. Says nothing about whether it is reserved.
function PlacesConfig.isCity(): boolean
	return role() == "city"
end

-- This server is somebody's city: the city place AND a reserved instance of ours.
-- The join gate keys off this -- see the VIP note in the header.
function PlacesConfig.isReservedCity(): boolean
	if not PlacesConfig.isCity() then return false end
	return isReserved(game.PrivateServerId, game.PrivateServerOwnerId)
end

-- The main menu lives in ANOTHER place and has to be teleported to rather than restored
-- locally. False in Studio, false in the lobby, and false while the split is unwired --
-- in all three the local menu IS the menu, which is what the game did before the split.
function PlacesConfig.menuIsElsewhere(): boolean
	if CITY_PLACE_ID == 0 then return false end
	return role() == "city"
end

-- privateServerId -> ownerUserId. Written when a city server is reserved; read by the
-- city gate to learn who owns the server it booted into.
function PlacesConfig.ownerKey(privateServerId: string): string
	return "owner_" .. privateServerId
end

-- ownerId -> reservedServerAccessCode. Cache so every lobby server routes visitors of
-- one owner to the SAME city instance. Cannot move to a player record either: the
-- server that reserves a city is usually a VISITOR's, and it does not hold the
-- owner's session lock.
function PlacesConfig.serverKey(ownerId: number | string): string
	return "server_" .. tostring(ownerId)
end

-- guestUserId -> { ownerUserId, ... }: every owner who has given this player a role.
-- The REVERSE of the owner's "visitors" list, and it cannot be derived from it: the invite
-- lives on the OWNER's record, so a guest has no way to know whose records to open. It
-- cannot live on a player record either -- the write lands on the TARGET, who is usually
-- offline, and the writing server holds no lock on them. So it is server topology like the
-- two keys above, and it lives in the same store.
function PlacesConfig.guestKey(userId: number | string): string
	return "guest_" .. tostring(userId)
end

return table.freeze(PlacesConfig)
