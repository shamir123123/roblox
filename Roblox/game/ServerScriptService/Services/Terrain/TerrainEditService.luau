--!strict
-- Network boundary for terrain editing. Validates and rate-limits incoming brush
-- strokes, then hands off to TerrainBrush (no business logic in the handler).
-- Server-authoritative: the renderer repaints from the dirty set and
-- workspace.Terrain replicates the result, so no edit reply is sent in v1.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Constants = require(ReplicatedStorage.Terrain.TerrainConstants)
local Types = require(ReplicatedStorage.Terrain.TerrainTypes)
local TerrainBrush = require(ReplicatedStorage.Terrain.TerrainBrush)
local Networker = require(ReplicatedStorage.Networker)
local NetMiddleware = require(ReplicatedStorage.NetMiddleware)

local TerrainEditService = {}

local _data: any
local _remote: RemoteEvent
local _conn: RBXScriptConnection?

local HALF = Constants.MAP_HALF_EXTENT

local VALID_OPS: { [string]: boolean } = {
	Raise = true, Lower = true, Flatten = true, Smooth = true, Level = true, SetMaterial = true,
}

-- Storable material ids (0..6). A SetMaterial stroke is rejected unless its id is
-- one of these: an out-of-range value would be written into the heightmap buffer
-- and saved, and NaN would throw inside buffer.writeu8 during TerrainBrush.apply.
local VALID_MATERIAL: { [number]: boolean } = {}
for _, id in Constants.Material do
	VALID_MATERIAL[id] = true
end

local function isFinite(n: any): boolean
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- Reject malformed/out-of-range strokes. Magnitudes (radius/strength) are clamped
-- by TerrainBrush, not rejected here. Exposed for tests.
local function validateStroke(stroke: any): (boolean, string?)
	if type(stroke) ~= "table" then return false, "not a table" end
	if not VALID_OPS[stroke.op] then return false, "bad op" end
	if not (isFinite(stroke.centerX) and isFinite(stroke.centerZ)) then return false, "bad center" end
	if not isFinite(stroke.radius) then return false, "bad radius" end
	if not isFinite(stroke.strength) then return false, "bad strength" end
	if math.abs(stroke.centerX) > HALF or math.abs(stroke.centerZ) > HALF then
		return false, "out of bounds"
	end
	if stroke.op == "SetMaterial" and not VALID_MATERIAL[stroke.material] then
		return false, "bad material"
	end
	if stroke.op == "Level" and not isFinite(stroke.target) then
		return false, "bad target"
	end
	if stroke.target ~= nil and not isFinite(stroke.target) then
		return false, "bad target"
	end
	-- dt scales how far the brush moves the ground, so it is an attack surface: a client
	-- sending dt = 1000 would carve the map in one message. Reject anything non-finite or
	-- negative here; TerrainBrush clamps the magnitude to BRUSH_MAX_DT on top.
	if stroke.dt ~= nil and not (isFinite(stroke.dt) and stroke.dt >= 0) then
		return false, "bad dt"
	end
	return true
end

-- Terrain editing shares the city-edit gate with roads/zones: open to everyone
-- only when RoadEditOpen is set (Studio), otherwise per-player via CanEditRoads.
-- Without this any client could reshape terrain in a live server.
local function canEdit(player: Player): boolean
	if Workspace:GetAttribute("RoadEditOpen") == true then
		return true
	end
	return NetMiddleware.GetCachedAttribute(player, "CanEditRoads") == true
end

local function onEdit(player: Player, stroke: any)
	-- 1. permission (same gate as road/zone editing)
	if not canEdit(player) then return end
	-- 2. rate
	if not NetMiddleware.CheckServerRate(_remote, player) then return end
	-- 3-5. type / op / range
	local ok, why = validateStroke(stroke)
	if not ok then
		warn(("[TerrainEditService] rejected edit from %s: %s"):format(player.Name, tostring(why)))
		return
	end
	-- 5-6. magnitude clamp, lock-skip, ownership handled inside the brush (single-player map).
	TerrainBrush.apply(_data.getHeightmap(), stroke :: Types.BrushStroke)
	-- re-classify which dug cells hold water (isolated pits stay dry) before the repaint
	if stroke.op ~= "SetMaterial" then
		_data.classifyWaterEdit(stroke.centerX, stroke.centerZ, stroke.radius)
	end
end

function TerrainEditService.Init(dataService: any)
	assert(dataService, "[TerrainEditService] requires TerrainDataService")
	_data = dataService
	_remote = Networker.RequestTerrainEdit
	NetMiddleware.RegisterServerRateLimit(_remote, Constants.BRUSH_RATE_INTERVAL)
end

function TerrainEditService.Bind()
	_conn = _remote.OnServerEvent:Connect(onEdit)
end

function TerrainEditService.Start() end

-- Exposed for tests.
TerrainEditService._validateStroke = validateStroke

return TerrainEditService
