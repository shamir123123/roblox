--!strict

local LaneArrow = {}

export type Dirs = {
	left: boolean,
	through: boolean,
	right: boolean,
}

export type Dims = {
	len: number,
	shaftHalf: number,
	headHalf: number,
	headLen: number,
	reach: number,
	branchScale: number,
}

export type Tri = { Vector2 }

function LaneArrow.triangles(dirs: Dirs, d: Dims): { Tri }
	local tris: { Tri } = {}

	local function tri(a: Vector2, b: Vector2, c: Vector2)
		table.insert(tris, { a, b, c })
	end
	local function rect(a0: number, a1: number, z0: number, z1: number)
		tri(Vector2.new(a0, z0), Vector2.new(a1, z0), Vector2.new(a1, z1))
		tri(Vector2.new(a0, z0), Vector2.new(a1, z1), Vector2.new(a0, z1))
	end

	local top = d.len * 0.5
	local bottom = -d.len * 0.5
	local sh = d.shaftHalf

	local sides: { number } = {}
	if dirs.left then table.insert(sides, -1) end
	if dirs.right then table.insert(sides, 1) end

	local function branch(s: number, zc: number, scale: number)
		local reach = d.reach
		local hh = d.headHalf * scale
		local hl = d.headLen * scale
		rect(math.min(0, s * reach), math.max(0, s * reach), zc - sh, zc + sh)
		tri(
			Vector2.new(s * reach, zc - hh),
			Vector2.new(s * reach, zc + hh),
			Vector2.new(s * reach + s * hl, zc)
		)
	end

	if dirs.through then
		rect(-sh, sh, bottom, top - d.headLen)
		tri(
			Vector2.new(-d.headHalf, top - d.headLen),
			Vector2.new(d.headHalf, top - d.headLen),
			Vector2.new(0, top)
		)

		local zc = bottom + d.len * 0.42
		for _, s in sides do
			branch(s, zc, d.branchScale)
		end
	else

		if #sides == 0 then

			rect(-sh, sh, bottom, top - d.headLen)
			tri(
				Vector2.new(-d.headHalf, top - d.headLen),
				Vector2.new(d.headHalf, top - d.headLen),
				Vector2.new(0, top)
			)
		elseif #sides == 2 then

			rect(-sh, sh, bottom, top - d.headLen)
			tri(
				Vector2.new(0, top - d.headLen),
				Vector2.new(-d.headHalf, top - d.headLen),
				Vector2.new(-d.reach, top)
			)
			tri(
				Vector2.new(0, top - d.headLen),
				Vector2.new(d.headHalf, top - d.headLen),
				Vector2.new(d.reach, top)
			)
		else

			local s = sides[1]
			local bend = bottom + d.len * 0.5
			local hl = d.headLen
			local hh = d.headHalf
			local tipA = s * d.reach
			local tipZ = top
			local baseA = tipA - s * hl
			local baseZ = tipZ - hh

			rect(-sh, sh, bottom, bend)

			tri(
				Vector2.new(-sh, bend),
				Vector2.new( sh, bend),
				Vector2.new(baseA + s * hh, baseZ)
			)
			tri(
				Vector2.new(-sh, bend),
				Vector2.new(baseA + s * hh, baseZ),
				Vector2.new(baseA - s * hh, baseZ)
			)

			tri(
				Vector2.new(baseA - hh, baseZ),
				Vector2.new(baseA + hh, baseZ),
				Vector2.new(tipA, tipZ)
			)
		end
	end

	return tris
end

return LaneArrow
