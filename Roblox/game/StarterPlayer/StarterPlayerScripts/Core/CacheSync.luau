--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NetMiddleware = require(ReplicatedStorage:WaitForChild("NetMiddleware"))
local DataCache     = require(ReplicatedStorage:WaitForChild("DataCache"))
local Networker     = require(ReplicatedStorage:WaitForChild("Networker"))
local PlacementFit  = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlacementFit"))

local CacheSync = {}
local _started = false

function CacheSync.Start()
	if _started then return end
	_started = true

	NetMiddleware.WrapClientReceive(Networker.SyncNodes, function(list)
		DataCache.SetNodes(list)
	end)

	NetMiddleware.WrapClientReceive(Networker.SyncNodesDelta, function(delta)
		DataCache.ApplyNodesDelta(delta)
	end)

	NetMiddleware.WrapClientReceive(Networker.SyncSegments, function(list)
		DataCache.SetSegments(list)
	end)

	NetMiddleware.WrapClientReceive(Networker.SyncSegmentsDelta, function(delta)
		DataCache.ApplySegmentsDelta(delta)
	end)

	NetMiddleware.WrapClientReceive(Networker.SyncIntersections, function(payload)
		DataCache.ApplyIntersections(payload)
	end)

	NetMiddleware.WrapClientReceive(Networker.SyncIntersectionTurnSettings, function(payload)
		DataCache.ApplyTurnPermissions(payload)
	end)

	NetMiddleware.WrapClientReceive(Networker.SyncIntersectionLanePaths, function(payload)
		DataCache.ApplyLanePaths(payload)
	end)

	NetMiddleware.WrapClientReceive(Networker.SyncLaneChangeGates, function(payload)
		DataCache.ApplyLaneGates(payload)
	end)

	-- Placement needs the roads too: a road carries no queryable geometry, so "is this on a
	-- road" is answered off the segment list rather than by a box query (PlacementFit.onRoad).
	DataCache.On("segments", function()
		PlacementFit.setRoadSegments(DataCache.GetSegments())
	end)
end

return CacheSync
