--!strict
-- TerrainBrush contract. No framework -- `require(...).run()` asserts, against the real
-- brush rather than a copy of its formula.
--
-- The brush is the one piece of terrain code that runs on BOTH sides: the client predicts
-- a stroke locally so the ground moves on the frame you click, and the server applies the
-- same stroke a moment later. That only reconciles silently because it is pure and
-- deterministic, so the properties worth pinning are the ones that would make the two
-- sides disagree, or that a client could abuse:
--
--   A  dt SCALES, and only scales. One long tick and several short ones covering the same
--      time must land on the same ground, or the same drag digs different holes depending
--      on the frame rate it happened to be sent at.
--   B  dt is CLAMPED. It is a number from the client that multiplies how far the ground
--      moves, so an unclamped one carves the map in a single message.
--   C  The falloff dies flat at the rim. A weight that reaches zero with slope still on it
--      leaves a crease at exactly the brush radius, and repeated strokes stack those into
--      visible rings.
--   D  LOCKED corners never move. This is what the streamed flags buy: without it the
--      client predicts edits to a road bed the server refuses, and the ground snaps back.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage.Terrain.TerrainConstants)
local Heightmap = require(ReplicatedStorage.Terrain.Heightmap)
local TerrainBrush = require(ReplicatedStorage.Terrain.TerrainBrush)

local M = {}

local CENTRE_X, CENTRE_Z = 0, 0
local RADIUS = 40

local function heightAt(hm: any, worldX: number, worldZ: number): number
	return Constants.rawToWorldY(hm:getCorner(Constants.worldToCorner(worldX), Constants.worldToCorner(worldZ)))
end

local function raise(hm: any, dt: number)
	TerrainBrush.apply(hm, {
		op = "Raise", centerX = CENTRE_X, centerZ = CENTRE_Z,
		radius = RADIUS, strength = 1, dt = dt,
	})
end

local function fresh(): any
	local hm = Heightmap.new()
	-- the brush only writes corners whose chunk exists
	for cz = 15, 17 do
		for cx = 15, 17 do hm:ensureChunk(cx, cz) end
	end
	return hm
end

function M.run(): boolean
	local QUANTUM = Constants.HEIGHT_STEP

	-- A: one tick of 0.2 s == four ticks of 0.05 s. Raise is additive, so the only way these
	-- differ is if the brush is counting ticks rather than time.
	local oneTick = fresh()
	raise(oneTick, 0.2)
	local manyTicks = fresh()
	for _ = 1, 4 do raise(manyTicks, 0.05) end
	local a = heightAt(oneTick, CENTRE_X, CENTRE_Z)
	local b = heightAt(manyTicks, CENTRE_X, CENTRE_Z)
	assert(a > 0, "a raise stroke did not raise the ground at all")
	assert(math.abs(a - b) <= QUANTUM * 4,
		`one 0.2 s tick raised {a} but four 0.05 s ticks raised {b} -- the brush is counting ticks, not time`)

	-- ...and it really is proportional: half the time, about half the ground.
	local half = fresh()
	raise(half, 0.1)
	local h = heightAt(half, CENTRE_X, CENTRE_Z)
	assert(math.abs(h - a * 0.5) <= QUANTUM * 4, `0.1 s raised {h}, which is not half of 0.2 s raising {a}`)

	-- B: a client cannot bank time. An absurd dt must move no more than the cap allows.
	local cheat = fresh()
	raise(cheat, 1e6)
	local capped = heightAt(cheat, CENTRE_X, CENTRE_Z)
	local ceiling = Constants.BRUSH_STUDS_PER_SECOND * Constants.BRUSH_MAX_DT + QUANTUM
	assert(capped <= ceiling,
		`dt = 1e6 raised the ground {capped} studs in one stroke; the cap allows {ceiling}`)
	assert(capped <= Constants.BRUSH_MAX_DELTA_PER_TICK + QUANTUM,
		`one stroke exceeded BRUSH_MAX_DELTA_PER_TICK ({capped})`)

	-- C: the rim. The weight is (1 - t^2)^2, so near t = 1 the ground barely moves and the
	-- stroke blends out instead of ending on an edge. Sampled at 95% of the radius, where a
	-- plain 1 - t^2 falloff would still be lifting ~10% of full strength.
	local shaped = fresh()
	raise(shaped, 0.2)
	local centre = heightAt(shaped, CENTRE_X, CENTRE_Z)
	local rim = heightAt(shaped, CENTRE_X + RADIUS * 0.95, CENTRE_Z)
	assert(rim < centre * 0.02 + QUANTUM,
		`at 95% of the radius the brush still lifted {rim} against {centre} at the centre -- that edge is a crease`)
	-- and it is genuinely a smooth ramp in between, not a plateau with a cliff
	local mid = heightAt(shaped, CENTRE_X + RADIUS * 0.5, CENTRE_Z)
	assert(mid > rim and mid < centre, `the falloff is not monotonic: centre {centre}, mid {mid}, rim {rim}`)

	-- D: LOCKED corners are untouchable. Lock the centre corner by hand and check the brush
	-- leaves it exactly where it was while its neighbours rise around it.
	local locked = fresh()
	local gx, gz = Constants.worldToCorner(CENTRE_X), Constants.worldToCorner(CENTRE_Z)
	local cx, cz = gx // Constants.CHUNK_TILES, gz // Constants.CHUNK_TILES
	local chunk = locked:getChunk(cx, cz)
	assert(chunk, "test heightmap is missing the centre chunk")
	local lx, lz = gx - cx * Constants.CHUNK_TILES, gz - cz * Constants.CHUNK_TILES
	buffer.writeu8(chunk.flags, lz * Constants.CHUNK_CORNERS + lx, Constants.Flag.LOCKED)
	local before = heightAt(locked, CENTRE_X, CENTRE_Z)
	raise(locked, 0.2)
	assert(heightAt(locked, CENTRE_X, CENTRE_Z) == before,
		"the brush moved a LOCKED corner -- the client would predict edits the server refuses")
	assert(heightAt(locked, CENTRE_X + Constants.SAMPLE_SPACING * 2, CENTRE_Z) > before,
		"nothing moved at all, so the LOCKED check above proves nothing")

	-- E: Raise/Lower smooth as they go -- but only a little. Both halves matter: with no
	-- smoothing a stroke leaves lumps wherever the cursor dwelt, and with too much the brush
	-- stops digging what you aimed at and averages your work away instead.
	local SPACING = Constants.SAMPLE_SPACING
	local function roughness(hm: any): number
		-- mean gap between a corner and its four neighbours, over the brush footprint
		local total, n = 0, 0
		local g0 = Constants.worldToCorner(CENTRE_X)
		local k0 = Constants.worldToCorner(CENTRE_Z)
		local reach = math.floor(RADIUS / SPACING) - 2
		for gz = k0 - reach, k0 + reach do
			for gx = g0 - reach, g0 + reach do
				local y = Constants.rawToWorldY(hm:getCorner(gx, gz))
				local avg = (
					Constants.rawToWorldY(hm:getCorner(gx + 1, gz)) + Constants.rawToWorldY(hm:getCorner(gx - 1, gz))
					+ Constants.rawToWorldY(hm:getCorner(gx, gz + 1)) + Constants.rawToWorldY(hm:getCorner(gx, gz - 1))
				) / 4
				total += math.abs(y - avg)
				n += 1
			end
		end
		return total / math.max(n, 1)
	end

	local jagged = fresh()
	local g0 = Constants.worldToCorner(CENTRE_X)
	local k0 = Constants.worldToCorner(CENTRE_Z)
	local reach = math.floor(RADIUS / SPACING) + 2
	for gz = k0 - reach, k0 + reach do
		for gx = g0 - reach, g0 + reach do
			local bump = if (gx + gz) % 2 == 0 then 2 else -2
			jagged:setCorner(gx, gz, Constants.worldYToRaw(20 + bump))
		end
	end
	local before = roughness(jagged)
	local centreBefore = heightAt(jagged, CENTRE_X, CENTRE_Z)
	assert(before > 1, `the test ground is not actually jagged (roughness {before})`)
	raise(jagged, 0.2)
	local after = roughness(jagged)
	-- One tick takes ~8% off deliberately extreme ground; with the smoothing switched off the
	-- same stroke leaves it slightly ROUGHER, so this margin is the real signal and not noise.
	-- It compounds over a drag, which is why one tick must stay gentle.
	assert(after < before * 0.95,
		`a raise stroke left the ground as rough as it found it ({before} -> {after}); Raise/Lower are meant to smooth as they go`)
	-- ...and it still dug what was aimed at, rather than averaging it away
	local gained = heightAt(jagged, CENTRE_X, CENTRE_Z) - centreBefore
	local full = Constants.BRUSH_STUDS_PER_SECOND * 0.2
	assert(gained > full * 0.5,
		`the stroke only raised {gained} of an intended {full} studs -- the auto-smooth is eating the brush`)

	print("[TerrainBrush.spec] OK")
	return true
end

return M
