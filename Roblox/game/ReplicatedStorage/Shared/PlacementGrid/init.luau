--!strict
-- PlacementGrid
-- THE placement grid: one lattice for everything a player puts on the map. Service
-- buildings, nature, build shapes, the move handles and road drawing all snap through
-- here, so no two tools can ever disagree about where the grid lines are.
-- Client-local preference, like FreePlacement: the server only re-checks the result.
--
-- Road snap outranks it: a building next to a road lines up with the road whatever this
-- says. Zoning never reads it -- plots are cut along the road.
--
-- Off still lands on the save's own lattice (Quant: 0.1 stud = 5 cm, so never more than
-- two decimals of a metre), which keeps the ghost exactly where a reload will put it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Quant = require(ReplicatedStorage.Shared.Quant)
local RoadConstants = require(ReplicatedStorage.Road.RoadConstants)

local PlacementGrid = {}

-- The sizes a player can pick, in metres.
PlacementGrid.SIZES = table.freeze({ 1, 5, 10 })

local STUDS_PER_METRE = 1 / RoadConstants.STUD_TO_METER

local _on = false
local _metres = 1
local _listeners: { () -> () } = {}

local function changed()
	for _, fn in _listeners do fn() end
end

function PlacementGrid.setEnabled(on: boolean)
	if _on == on then return end
	_on = on
	changed()
end

function PlacementGrid.isEnabled(): boolean
	return _on
end

-- Picking a size turns the grid on: nobody picks "5 m" meaning "and leave it off".
function PlacementGrid.setSize(metres: number)
	if not table.find(PlacementGrid.SIZES, metres) then return end
	_metres = metres
	_on = true
	changed()
end

function PlacementGrid.getSize(): number
	return _metres
end

-- Studs between grid lines; 0 while the grid is off.
function PlacementGrid.step(): number
	return if _on then _metres * STUDS_PER_METRE else 0
end

-- X/Z onto the grid LINES (Y is the ground's business).
function PlacementGrid.snap(p: Vector3): Vector3
	local g = PlacementGrid.step()
	if g <= 0 then return Vector3.new(Quant.n(p.X), p.Y, Quant.n(p.Z)) end
	return Vector3.new(math.round(p.X / g) * g, p.Y, math.round(p.Z / g) * g)
end

-- Calls fn after every change; returns the disconnect.
function PlacementGrid.onChanged(fn: () -> ()): () -> ()
	table.insert(_listeners, fn)
	return function()
		local i = table.find(_listeners, fn)
		if i then table.remove(_listeners, i) end
	end
end

return PlacementGrid
