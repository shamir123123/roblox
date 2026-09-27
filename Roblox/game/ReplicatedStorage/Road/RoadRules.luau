--!strict
-- RoadRules
-- Single query layer for the rules that hang off a road/lane: speed limit, which
-- vehicle classes may use it, its functional class (for intersection priority +
-- truck route preference) and whether it carries on-street parking. Pure library
-- -- no state, no lifecycle, no side effects on require. Per-segment overrides
-- always win over the road type's defaults.

local RunService      = game:GetService("RunService")

local RoadConstants   = require(script.Parent.RoadConstants)
local RoadTypeCatalog = require(script.Parent.RoadTypeCatalog)
local RoadTypes       = require(script.Parent.RoadTypes)
local VehicleTypes    = require(script.Parent.VehicleTypes)

type RoadTypeSpec = RoadTypeCatalog.RoadTypeSpec
type Segment      = RoadTypes.Segment

local RoadRules = {}

export type RoadClass = "local" | "arterial"
export type DrivingSide = "left" | "right"

-- == Driving side ===========================================================
-- The side traffic drives on is PURELY A PLAYER CHOICE. No world theme owns it and no
-- region implies it -- a US city with left-hand traffic is a perfectly legitimate thing
-- for a player to build, so nothing in the theme or region catalogs may set it. This
-- module is its one and only owner. CitySlotService persists the choice per city; the
-- server applies it on load.
--
-- DEFAULT_DRIVING_SIDE below is only what an unconfigured world starts on. It is not a
-- "correct" side, and no theme feeds it.
--
-- It lives here and not in RoadConstants because RoadConstants is frozen and evaluated
-- once at load, while this changes at runtime. Everything that cares must call these
-- getters ON EVERY USE -- never copy one into a module-level local, or it will hold
-- whatever the value was when that module happened to load.
--
-- Replication rides a Workspace attribute rather than a remote: the server sets it,
-- Roblox replicates it, and every client's copy of this module adopts it through the
-- listener at the bottom. A player joining a city mid-session reads the current value
-- straight off the attribute.
local DRIVING_SIDE_ATTRIBUTE = "DrivingSide"

local DEFAULT_DRIVING_SIDE: DrivingSide = "right"

-- Seeded from the default and immediately re-derived from it at the bottom of this
-- section, so these four can never drift out of step with each other.
local _drivingSide: DrivingSide = DEFAULT_DRIVING_SIDE
local _laneSideSign: number = 1
local _nearsideTurn: string = "right"
local _crossingTurn: string = "left"
local _sideListeners: { (DrivingSide) -> () } = {}

-- Accepts "Left"/"left"/"Right"/"right" -- the save format is capitalised, the road code
-- is not. Anything else is nil, so a forged or corrupt value can never set a side.
local function normalizeSide(value: any): DrivingSide?
	if type(value) ~= "string" then return nil end
	local lower = string.lower(value)
	if lower == "left" or lower == "right" then
		return lower :: DrivingSide
	end
	return nil
end

local function applySide(side: DrivingSide)
	_drivingSide = side
	local right = side == "right"
	_laneSideSign = if right then 1 else -1
	_nearsideTurn = if right then "right" else "left"
	_crossingTurn = if right then "left" else "right"
end

RoadRules.DEFAULT_DRIVING_SIDE = DEFAULT_DRIVING_SIDE

function RoadRules.getDrivingSide(): DrivingSide
	return _drivingSide
end

-- Which side of the centreline a direction's own lanes sit on: +1 = right of travel.
-- The single sign that puts the whole map on one side of the road.
function RoadRules.getLaneSideSign(): number
	return _laneSideSign
end

-- Turns named by what they do, not by compass direction.
-- A crossing turn cuts the oncoming carriageway (US left, UK right), so it yields unless
-- it holds a protected phase, and it is made from the lane next to the centreline.
-- A nearside turn hugs the kerb, conflicts with nothing, and is the one allowed on red.
function RoadRules.getNearsideTurn(): string
	return _nearsideTurn
end

function RoadRules.getCrossingTurn(): string
	return _crossingTurn
end

function RoadRules.isCrossingTurn(movement: string): boolean
	return movement == _crossingTurn
end

function RoadRules.isNearsideTurn(movement: string): boolean
	return movement == _nearsideTurn
end

-- Set the side. Returns true only when the value actually CHANGED, because that is the
-- signal the caller needs: flipping the side moves every lane to the other side of the
-- centreline, so the nav graph must be rebuilt and the roads re-rendered. Nothing baked
-- from the old value is still correct. A no-op change must not trigger that work.
function RoadRules.setDrivingSide(value: any): boolean
	local side = normalizeSide(value)
	if not side or side == _drivingSide then
		return false
	end
	applySide(side)
	-- Server writes the attribute so clients follow. On the server this also fires the
	-- listener below, which then sees no change and does nothing -- no double dispatch.
	if RunService:IsServer() then
		workspace:SetAttribute(DRIVING_SIDE_ATTRIBUTE, if side == "right" then "Right" else "Left")
	end
	for _, fn in _sideListeners do
		task.spawn(fn, side)
	end
	return true
end

-- Notified after the side changes. The road renderer and the nav graph hang off this.
function RoadRules.onDrivingSideChanged(fn: (DrivingSide) -> ()): () -> ()
	table.insert(_sideListeners, fn)
	return function()
		local i = table.find(_sideListeners, fn)
		if i then table.remove(_sideListeners, i) end
	end
end

-- Adopt whatever the world already says, then follow later changes. This is what makes a
-- client correct without any handshake, and what makes a server module that loads late
-- still see the side the city was restored with.
do
	-- Derive the four values from the default rather than trusting the literals above to
	-- stay in step with it, then let the world override.
	applySide(DEFAULT_DRIVING_SIDE)
	local existing = normalizeSide(workspace:GetAttribute(DRIVING_SIDE_ATTRIBUTE))
	if existing then
		applySide(existing)
	end
	workspace:GetAttributeChangedSignal(DRIVING_SIDE_ATTRIBUTE):Connect(function()
		local side = normalizeSide(workspace:GetAttribute(DRIVING_SIDE_ATTRIBUTE))
		if side and side ~= _drivingSide then
			applySide(side)
			for _, fn in _sideListeners do
				task.spawn(fn, side)
			end
		end
	end)
end

-- studs/s = (km/h / 3.6 m/s) / STUD_TO_METER. Rides the WORLD_SCALE knob: shown
-- km/h limits never change, cars cover the same city blocks per second at any scale.
local STUDS_PER_KMH = (1 / 3.6) / RoadConstants.STUD_TO_METER

function RoadRules.getSpeedLimitKmh(seg: Segment?, spec: RoadTypeSpec): number
	if seg and seg.speedLimitOverride then
		return seg.speedLimitOverride
	end
	return spec.speedLimit
end

function RoadRules.getSpeedLimitStuds(seg: Segment?, spec: RoadTypeSpec): number
	return RoadRules.getSpeedLimitKmh(seg, spec) * STUDS_PER_KMH
end

function RoadRules.allowedVehicleSet(seg: Segment?, spec: RoadTypeSpec): { [string]: boolean }?
	if seg and seg.allowedVehiclesOverride then
		return seg.allowedVehiclesOverride
	end
	return spec.allowedVehicles
end

RoadRules.BUS_LANE_CLASSES = VehicleTypes.BusLaneClasses

-- Allowed set for ONE lane of a segment. Same as allowedVehicleSet, except the kerbside
-- lane (highest ordinal, DRIVING_SIDE-agnostic by construction) of a bus-lane road.
-- A direction with only one lane keeps it open: restricting it would block all traffic.
function RoadRules.laneAllowedVehicleSet(seg: Segment?, spec: RoadTypeSpec, laneOrdinal: number, laneCountInDirection: number): { [string]: boolean }?
	if spec.busLane and laneCountInDirection >= 2 and laneOrdinal == laneCountInDirection then
		return RoadRules.BUS_LANE_CLASSES
	end
	return RoadRules.allowedVehicleSet(seg, spec)
end

-- A nil allowed-set means "no restriction": every vehicle class may use the lane.
function RoadRules.allowsVehicle(seg: Segment?, spec: RoadTypeSpec, class: string): boolean
	local set = RoadRules.allowedVehicleSet(seg, spec)
	if not set then return true end
	return set[class] == true
end

-- Functional class. Drives which intersections get signals vs priority rules,
-- and how strongly trucks prefer a road. Avenues/boulevards and wider are
-- arterial; ordinary streets and alleys are local.
function RoadRules.roadClass(spec: RoadTypeSpec): RoadClass
	if spec.laneCount >= 3 or spec.width >= 36 * RoadConstants.WORLD_SCALE then
		return "arterial"
	end
	return "local"
end

function RoadRules.hasParking(seg: Segment?, spec: RoadTypeSpec): boolean
	return spec.parkingLane == true
end

export type NodeControl = "none" | "priority" | "signal"

-- How an intersection node is controlled. Not every junction gets lights:
--   * < 3 arms      -> "none"     (a continuation / dead end, no conflict)
--   * 4+ arms       -> "signal"   (busy, and uncontrolled 4-ways deadlock NPCs)
--   * 3 arms (a T)  -> "priority" (through road has right-of-way, the stem yields)
--                      unless every arm is arterial (a major Y), which signals.
-- `network` is the live RoadNetwork (typed loosely since it crosses the module
-- boundary as an injected runtime object).
function RoadRules.nodeControl(network: any, nodeId: number): NodeControl
	local node = network:getNodes()[nodeId]
	local arms = if node and node.segments then #node.segments else 0
	if arms < 3 then
		return "none"
	end
	-- A roundabout entry/exit is yield-controlled, never signalised: circulating
	-- traffic has priority and entering traffic gives way (handled by the driver).
	if network.isRoundaboutNode ~= nil and network:isRoundaboutNode(nodeId) then
		return "none"
	end
	-- Signals only where a MAJOR road meets: any arm of 4+ lanes. Smaller junctions (2-lane
	-- crossings, ordinary Ts) use a give-way priority rule so quiet streets aren't cluttered
	-- with lights. Per-intersection manual overrides still apply on top of this default.
	local segs = if node then node.segments else nil
	if segs then
		-- A junction where ONLY highways meet never signals: ramps merge and highways
		-- cross under give-way priority (the through carriageway has right-of-way),
		-- like a motorway interchange. Any non-highway arm falls through to the
		-- normal signal rules below.
		local allHighway = #segs > 0
		for _, sid in segs :: { number } do
			local s = network:getSegments()[sid]
			if not (s and RoadTypeCatalog.getOrDefault(s.roadType).isHighway) then
				allHighway = false
				break
			end
		end
		if allHighway then
			return "priority"
		end
		for _, sid in segs :: { number } do
			local s = network:getSegments()[sid]
			if s and (RoadTypeCatalog.getOrDefault(s.roadType).laneCount or 2) >= 4 then
				return "signal"
			end
		end
	end
	return "priority"
end

-- Roundabout right-of-way. No roundabout geometry exists yet -- this records the
-- rule so the driver is ready when they're added: vehicles already circulating
-- on the ring have priority; entering vehicles yield to circulating traffic.
RoadRules.ROUNDABOUT_CIRCULATING_HAS_PRIORITY = true

return RoadRules
