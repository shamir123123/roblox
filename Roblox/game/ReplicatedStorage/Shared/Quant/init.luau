--!strict
-- Quant
-- The shared placement codec: the single place that decides how much precision a
-- persisted placement keeps, so live state and the DataStore blob stay on one grid
-- and saves stay small.
--   * Positions round to ONE decimal (0.1-stud grid) -- n() / vec() / deep().
--   * Rotations store a whole-degree yaw, never a 12-float CFrame matrix --
--     packPivot() / unpackPivot(). Every placeable here is yaw-only (flat on the
--     ground), so {x, y, z, yawDeg} replaces 12 components with no visible loss.
-- Placement entries snap incoming positions with vec()/n(); CitySerializer rounds
-- whole save sections with deep(); the service serializers pack pivots with
-- packPivot(). Pure library: no state, no lifecycle, no side effects.

local Quant = {}

-- One decimal. Positions live on a 0.1-stud grid: imperceptible in a city builder,
-- and every trimmed digit is bytes off every saved coordinate.
function Quant.n(x: number): number
	return math.round(x * 10) / 10
end

function Quant.vec(v: Vector3): Vector3
	return Vector3.new(Quant.n(v.X), Quant.n(v.Y), Quant.n(v.Z))
end

-- Whole-degree yaw (0..359) of a yaw-only CFrame.
function Quant.yaw(cf: CFrame): number
	local _, ry = cf:ToOrientation()
	return math.round(math.deg(ry)) % 360
end

-- Compact pivot -> {x, y, z, yawDeg}: position at 1 decimal, rotation at 0. Replaces
-- the 12-float CFrame:GetComponents() the service serializers used to store.
function Quant.packPivot(cf: CFrame): { number }
	local p = cf.Position
	return { Quant.n(p.X), Quant.n(p.Y), Quant.n(p.Z), Quant.yaw(cf) }
end

-- Rebuild a pivot from packPivot's {x,y,z,yawDeg}, OR from an old 12-float
-- CFrame:GetComponents() array (pre-codec saves). nil for anything malformed.
function Quant.unpackPivot(t: any): CFrame?
	if typeof(t) ~= "table" then return nil end
	if #t >= 12 then
		local nums: { number } = table.create(12)
		for i = 1, 12 do
			local n = tonumber(t[i])
			if not n then return nil end
			nums[i] = n
		end
		return CFrame.new(table.unpack(nums))
	end
	if #t == 4 then
		local x, y, z, yaw = tonumber(t[1]), tonumber(t[2]), tonumber(t[3]), tonumber(t[4])
		if not (x and y and z and yaw) then return nil end
		return CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yaw), 0)
	end
	return nil
end

-- Snap a yaw-only pivot to the grid and return the CFrame: 1-decimal position,
-- whole-degree yaw. The live-CFrame twin of packPivot -> unpackPivot, so what a
-- placement puts down is exactly what a reload rebuilds. Falls back to the input if
-- it somehow can't round-trip.
function Quant.snapCF(cf: CFrame): CFrame
	return Quant.unpackPivot(Quant.packPivot(cf)) or cf
end

-- Rounds every number in a (nested) table to ONE decimal, in place, and returns it.
-- Serialize blobs are freshly built tables, so mutating them is safe.
function Quant.deep(t: any): any
	if typeof(t) ~= "table" then
		return t
	end
	for k, v in t do
		if typeof(v) == "number" then
			t[k] = Quant.n(v)
		elseif typeof(v) == "table" then
			Quant.deep(v)
		end
	end
	return t
end

return Quant
