--!strict
-- Client-only: builds workspace.Terrain LOCALLY from the seed + edited chunks the server
-- streams, instead of receiving tens of millions of replicated voxels. Regenerates base
-- chunks on demand from the seed and overwrites the chunks the city actually changed
-- (roads/pads/brush). Shares TerrainPainter with the server, so the voxels are identical
-- to a server paint.
--
-- build() DOES NOT RETURN UNTIL THE WHOLE MAP IS STANDING. The far chunks used to finish
-- in the background after the player was already in the city, which meant entering onto a
-- horizon that filled itself in underneath them. Nearest-to-the-city is still the order --
-- what the player will be looking at is built first, and meshed inline -- but the far edges
-- and the mesh queue behind them are now part of the loading screen, not part of the game.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Constants = require(ReplicatedStorage.Terrain.TerrainConstants)
local Heightmap = require(ReplicatedStorage.Terrain.Heightmap)
local TerrainGenerator = require(ReplicatedStorage.Terrain.TerrainGenerator)
local TerrainPainter = require(ReplicatedStorage.Terrain.TerrainPainter)
local TerrainMeshView = require(ReplicatedStorage.Terrain.TerrainMeshView)
local WaterField = require(ReplicatedStorage.Terrain.WaterField)

local TerrainBuildController = {}

-- Retained after build() so client-side renderers (roads) can sample the same surface
-- heights the server uses, without a server round-trip. Mirrors TerrainDataService.
local _liveHm: Heightmap.Heightmap? = nil
local _liveParams: TerrainGenerator.GenParams? = nil

-- Bumped on each build() so a still-running Phase-2 background painter from an earlier
-- city load cancels itself instead of painting stale terrain over the newly loaded map.
local _buildGen = 0

-- Live after build(): the server pushes every chunk it re-grades (road, pad, brush) here,
-- so the client heightmap -- and therefore getSurfaceY and the ground mesh -- tracks edits
-- instead of going stale the moment anything is built.
local _patchConn: RBXScriptConnection? = nil

-- Copy a streamed chunk record into the live heightmap. FLAGS come across too, which they
-- did not before: the client now predicts brush strokes locally (TerrainEditController)
-- through the same TerrainBrush the server runs, and TerrainBrush skips LOCKED corners.
-- Without the flags the client would cheerfully predict edits to a road bed that the server
-- then refuses, and the ground would snap back under the cursor.
local function adoptChunk(hm: Heightmap.Heightmap, key: number, h: buffer, m: buffer, f: buffer?)
	local cx, cz = Heightmap.decodeKey(key)
	local chunk = hm:ensureChunk(cx, cz)
	buffer.copy(chunk.heights, 0, h)
	buffer.copy(chunk.materials, 0, m)
	if f then buffer.copy(chunk.flags, 0, f) end
end

local CHUNKS_PER_AXIS = Constants.CHUNKS_PER_AXIS
local CHUNK_TILES = Constants.CHUNK_TILES
local CHUNK_CORNERS = Constants.CHUNK_CORNERS
local MESH_GROUND = Constants.MESH_GROUND
local CHUNK_STUDS = Constants.CHUNK_STUDS
local HALF = Constants.MAP_HALF_EXTENT
-- Chunks within this distance of the city are painted AND meshed inline, because they are
-- what the player opens their eyes on. Everything past it is painted in the same blocking
-- pass but hands its geometry to TerrainMeshView's queue, so one frame budget governs.
local PRIORITY_RADIUS = 2200
-- Seconds of work per frame in both passes.
--
-- MEASURED, because this is not the obvious knob it looks like. At 1/60 the passes took
-- 24.4 s to do 14.8 s of work: the other 9.6 s was this loop doing its 16 ms and then
-- waiting on a Heartbeat that took ~43 ms to come round, because during a load the client is
-- rendering and swallowing the city's replication at about 9 fps. The budget was not limiting
-- the work, it was limiting how often we were allowed to ASK to do it.
--
-- Bounded rather than unrolled because the replication arriving from the server is real work
-- that still needs frames of its own -- run this flat out and the city takes longer to reach
-- the client than the ground does. A quarter of a second is four frames a second behind a
-- screen that is a logo and a progress bar, which is a stutter nobody is looking at.
local FRAME_BUDGET = 1 / 4
local STREAM_TIMEOUT = 30
-- Never-stuck backstop on the mesh queue. A pump that cannot keep up costs the player a
-- rougher horizon for a few seconds; it must never cost them a loading screen that sits
-- there forever.
local DRAW_TIMEOUT = 45
-- What the loading bar reads when the near chunks are done, and when the far ones are.
-- The rest of the bar is the mesh queue draining.
local NEAR_FRAC = 0.55
local FAR_FRAC = 0.9

local function chunkCentreX(cx: number): number return -HALF + (cx + 0.5) * CHUNK_STUDS end
local function chunkCentreZ(cz: number): number return -HALF + (cz + 0.5) * CHUNK_STUDS end

-- worldY at one global terrain corner: the loaded heightmap value where that corner's
-- chunk is present, else the procedural base (same per-corner resolution as WaterView,
-- so heights blend across the edge of the not-yet-streamed region).
local function cornerY(hm: Heightmap.Heightmap, params: TerrainGenerator.GenParams, gx: number, gz: number): number
	local cx = math.floor(gx / CHUNK_TILES)
	local cz = math.floor(gz / CHUNK_TILES)
	if cx >= 0 and cx < CHUNKS_PER_AXIS and cz >= 0 and cz < CHUNKS_PER_AXIS and hm:getChunk(cx, cz) then
		return Constants.rawToWorldY(hm:getCorner(gx, gz))
	end
	return TerrainGenerator.surfaceYAt(gx, gz, params)
end

-- Explicit material override at one global corner (0 = AUTO, i.e. derive from height and
-- slope). Unstreamed ground has no overrides, so it answers AUTO.
local function cornerMat(hm: Heightmap.Heightmap, gx: number, gz: number): number
	local cx = math.floor(gx / CHUNK_TILES)
	local cz = math.floor(gz / CHUNK_TILES)
	if cx < 0 or cx >= CHUNKS_PER_AXIS or cz < 0 or cz >= CHUNKS_PER_AXIS then return 0 end
	local chunk = hm:getChunk(cx, cz)
	if not chunk then return 0 end
	return buffer.readu8(chunk.materials, (gz - cz * CHUNK_TILES) * CHUNK_CORNERS + (gx - cx * CHUNK_TILES))
end

-- Build the whole map locally. onProgress(frac) reports overall progress (0..1). Blocks
-- until every chunk is painted and the ground geometry for all of it exists.
-- Returns true if a city was built, false if the server reported no city.
-- beforeDraw runs after every chunk is painted and before any ground is DRAWN. It exists
-- for the overlap: this build now runs while the server is still restoring the city, so
-- the camera the player will actually be at has not arrived yet when the build starts.
-- Every block picks its LOD tier against that camera, so drawing before it lands would
-- re-tier the whole map the moment the player appears. The caller waits for it here.
function TerrainBuildController.build(net: any, onProgress: ((number) -> ())?, beforeDraw: (() -> ())?): boolean
	_buildGen += 1
	local myGen = _buildGen
	local terrain = workspace:FindFirstChildOfClass("Terrain")
	if not terrain then return false end

	local hm = Heightmap.new()
	local edited: { [number]: { h: buffer, m: buffer } } = {}
	local params: TerrainGenerator.GenParams = { seed = 0 }
	local done, noCity = false, false

	local function num(v: any, fallback: number): number
		return if type(v) == "number" then v else fallback
	end

	local conn
	conn = net.TerrainBuildData.OnClientEvent:Connect(function(msg: any)
		if type(msg) ~= "table" then return end
		if msg.kind == "begin" then
			params = {
				seed = num(msg.seed, 0),
				heightRange = num(msg.relief, 1),
				oceanLevel = num(msg.oceanLevel, 0),
				baseHeight = num(msg.baseHeight, 0),
				ruggedness = num(msg.ruggedness, 0),
				shape = if type(msg.shape) == "string" then msg.shape else nil,
				persistence = num(msg.persistence, 0.5),
				lacunarity = num(msg.lacunarity, 2.0),
				algo = if type(msg.algo) == "number" then msg.algo else nil,
			}
		elseif msg.kind == "chunks" then
			if type(msg.items) == "table" then
				for _, item in msg.items do
					if type(item) == "table" and type(item.key) == "number"
						and typeof(item.h) == "buffer" and typeof(item.m) == "buffer" then
						edited[item.key] = { h = item.h, m = item.m, f = item.f }
					end
				end
			end
		elseif msg.kind == "dry" then
			if type(msg.keys) == "table" then WaterField.setDryKeys(msg.keys) end
		elseif msg.kind == "done" then
			done = true
		elseif msg.kind == "none" then
			noCity = true
			done = true
		end
	end)

	local tStart = os.clock()
	net.RequestTerrainBuild:FireServer()

	local deadline = os.clock() + STREAM_TIMEOUT
	while not done and os.clock() < deadline do
		RunService.Heartbeat:Wait()
	end
	conn:Disconnect()
	local tStream = os.clock()

	if noCity then
		return false
	end

	_liveHm = hm
	_liveParams = params

	-- Put a chunk's heights in place if they are not already: the server's data where the
	-- city changed the terrain, else regenerated from the seed. Idempotent, so the mesh view
	-- can pull a chunk forward when it needs a neighbour's real shape, and the fill can ask
	-- again later without redoing it.
	local function ensureChunkData(key: number): boolean
		local kcx, kcz = Heightmap.decodeKey(key)
		if hm:getChunk(kcx, kcz) then return true end
		local ed = edited[key]
		if ed then
			adoptChunk(hm, key, ed.h, ed.m, ed.f)
		else
			TerrainGenerator.generateChunk(hm, kcx, kcz, params)
		end
		return true
	end

	if MESH_GROUND then
		-- A previous city's ground must come down before this one goes up, and any voxels
		-- baked into the place (or replicated before the mesh existed) would z-fight it.
		TerrainMeshView.reset()
		terrain:Clear()
		TerrainMeshView.setSource(function(gx: number, gz: number): number
			return cornerY(hm, params, gx, gz)
		end, function(gx: number, gz: number): number
			return cornerMat(hm, gx, gz)
		end, ensureChunkData, function(key: number): buffer?
			ensureChunkData(key)
			local chunk = hm:getChunk(Heightmap.decodeKey(key))
			return if chunk then chunk.heights else nil
		end)
		-- The server only streams a chunk it CHANGED, so the edited set is exactly "chunks the
		-- city built on" -- the ones LOD must never touch.
		for key in edited do TerrainMeshView.pin(key) end
	end

	-- Centroid of the edited chunks = the built city; paint outward from there.
	local sumX, sumZ, nEx = 0, 0, 0
	for key in edited do
		local cx, cz = Heightmap.decodeKey(key)
		sumX += chunkCentreX(cx); sumZ += chunkCentreZ(cz); nEx += 1
	end
	local centreX = if nEx > 0 then sumX / nEx else 0
	local centreZ = if nEx > 0 then sumZ / nEx else 0

	-- LOD reference for the FIRST build of each chunk. The real camera is not where the
	-- player will be yet (this runs behind the loading screen), so aim it at the city; the
	-- Heartbeat refresh corrects whatever this got wrong 0.35 s after entry.
	local lodEye = Vector3.new(centreX, 800, centreZ)

	-- Order every chunk by distance from the city centre.
	local order: { number } = {}
	local distSq: { [number]: number } = {}
	for cz = 0, CHUNKS_PER_AXIS - 1 do
		for cx = 0, CHUNKS_PER_AXIS - 1 do
			local key = cz * CHUNKS_PER_AXIS + cx
			order[#order + 1] = key
			local dx, dz = chunkCentreX(cx) - centreX, chunkCentreZ(cz) - centreZ
			distSq[key] = dx * dx + dz * dz
		end
	end
	table.sort(order, function(a, b) return distSq[a] < distSq[b] end)

	-- Ready a chunk's heightmap (server's edited data where the city changed terrain, else
	-- regenerated from the seed) and paint it. `defer` hands the mesh to TerrainMeshView's
	-- queue instead of building it here: the background fill has no reason to stall on a
	-- mesh, and running two build loops meant two frame budgets spent on terrain every frame.
	-- Phase accounting. near/far alone cannot tell generating a chunk from painting it from
	-- meshing it, and guessing which of the three it was has already cost a day.
	local genSecs, paintSecs, meshSecs = 0, 0, 0
	local function buildAndPaint(key: number, defer: boolean?)
		local cx, cz = Heightmap.decodeKey(key)
		local tA = os.clock()
		ensureChunkData(key)
		genSecs += os.clock() - tA
		if not MESH_GROUND then
			TerrainPainter.paintChunk(terrain, hm, cx, cz, WaterField.isDryAt)
			return
		end
		-- Terrain keeps the water body only; the ground is the mesh. `fresh` because
		-- terrain:Clear() ran above: there is nothing here to overwrite, so a chunk with no
		-- ground below sea level writes NOTHING instead of a 64x12x64 array of air.
		local tB = os.clock()
		TerrainPainter.paintChunk(terrain, hm, cx, cz, WaterField.isDryAt, true, true)
		paintSecs += os.clock() - tB
		-- A build that reports false ran out of Editable budget rather than failing; hand it
		-- to the queue so the pump retries it instead of leaving a hole in the ground.
		local tC = os.clock()
		if defer or not TerrainMeshView.buildChunk(key, lodEye) then
			TerrainMeshView.request(key)
		end
		meshSecs += os.clock() - tC
	end

	-- Priority chunks: within the radius (or at least a screenful) of the city.
	local prioritySq = PRIORITY_RADIUS * PRIORITY_RADIUS
	local priorityCount = 0
	for _, key in order do
		if distSq[key] <= prioritySq then priorityCount += 1 else break end
	end
	if priorityCount < 64 then priorityCount = math.min(#order, 64) end

	local function report(frac: number)
		if onProgress then onProgress(math.clamp(frac, 0, 1)) end
	end

	-- Near pass: painted and meshed inline (time-sliced).
	local i = 1
	while i <= priorityCount do
		local frameStart = os.clock()
		repeat
			local ok, err = pcall(buildAndPaint, order[i])
			if not ok then warn("[TerrainBuildController] paint failed:", err) end
			i += 1
		until i > priorityCount or (os.clock() - frameStart) >= FRAME_BUDGET
		report(NEAR_FRAC * (i - 1) / priorityCount)
		RunService.Heartbeat:Wait()
	end
	local tNear = os.clock()
	if MESH_GROUND then TerrainMeshView.start() end

	-- Far pass: heights and water here, geometry to the queue the pump above now drains.
	local farCount = math.max(#order - priorityCount, 1)
	local j = priorityCount + 1
	while j <= #order do
		if myGen ~= _buildGen then break end -- a newer build started; stop painting stale terrain
		local frameStart = os.clock()
		repeat
			local ok, err = pcall(buildAndPaint, order[j], MESH_GROUND)
			if not ok then warn("[TerrainBuildController] far paint failed:", err) end
			j += 1
		until j > #order or (os.clock() - frameStart) >= FRAME_BUDGET
		report(NEAR_FRAC + (FAR_FRAC - NEAR_FRAC) * (j - 1 - priorityCount) / farCount)
		RunService.Heartbeat:Wait()
	end
	local tFar = os.clock()
	if beforeDraw then
		local okWait, waitErr = pcall(beforeDraw)
		if not okWait then warn("[TerrainBuildController] beforeDraw failed:", waitErr) end
	end
	local queuedAtDrain = if MESH_GROUND then TerrainMeshView.pending() else 0

	-- The far pass queued geometry rather than building it, and the pump re-tiers the near
	-- chunks against the real camera on its first sweep (they were built against lodEye).
	-- Both have to land before the screen comes down, or the player enters onto a map that
	-- is still drawing itself.
	if MESH_GROUND then
		local queued = math.max(TerrainMeshView.pending(), 1)
		local drawDeadline = os.clock() + DRAW_TIMEOUT
		while myGen == _buildGen and TerrainMeshView.pending() > 0 do
			if os.clock() >= drawDeadline then
				warn("[TerrainBuildController] ground still drawing after", DRAW_TIMEOUT, "s -- entering anyway")
				break
			end
			report(FAR_FRAC + (1 - FAR_FRAC) * (1 - TerrainMeshView.pending() / queued))
			RunService.Heartbeat:Wait()
		end
		if myGen == _buildGen then TerrainMeshView.setLoading(false) end
	end
	report(1)

	-- ONE line saying where a cold load actually went. Written as a warn because that is what
	-- shows up in a player's log without anyone asking for it, and because "the loading screen
	-- took 37 seconds" is otherwise unanswerable after the fact: the phases below are the only
	-- way to tell a slow server build from a slow paint from a slow bake.
	local ground = workspace:FindFirstChild("_Ground")
	local tEnd = os.clock()
	warn(string.format(
		"[TerrainBuild] %.1fs = stream %.1f + near %.1f (%d chunks) + far %.1f (%d) + draw %.1f (%d queued -> %d parts)"
			.. " | inside the passes: generate %.1f + paint %.1f + mesh-handoff %.1f",
		tEnd - tStart, tStream - tStart, tNear - tStream, priorityCount, tFar - tNear,
		#order - priorityCount, tEnd - tFar, queuedAtDrain,
		if ground then #ground:GetChildren() else 0,
		genSecs, paintSecs, meshSecs))

	if _patchConn then _patchConn:Disconnect() end
	_patchConn = net.TerrainBuildData.OnClientEvent:Connect(function(msg: any)
		if type(msg) ~= "table" or msg.kind ~= "patch" or type(msg.items) ~= "table" then return end
		if myGen ~= _buildGen then return end
		for _, item in msg.items do
			if type(item) == "table" and type(item.key) == "number"
				and typeof(item.h) == "buffer" and typeof(item.m) == "buffer" then
				adoptChunk(hm, item.key, item.h, item.m, item.f)
				if MESH_GROUND then
					TerrainMeshView.pin(item.key)
					-- A chunk under an active stroke is ALREADY showing this, because the client
					-- predicted it. Rebuilding on arrival would re-tessellate the plate mid-drag
					-- for no visible change; editEnd rebuilds it once when the stroke finishes.
					if not TerrainMeshView.isEditing(item.key) then
						TerrainMeshView.markDirty(item.key)
					end
				end
			end
		end
	end)

	return true
end

-- The VISIBLE ground surface at a world point -- the client twin of
-- TerrainDataService.getSurfaceY (heightmap + RENDER_BULGE). Returns nil until a
-- build() has streamed a city, so callers can fall back explicitly.
function TerrainBuildController.getSurfaceY(worldX: number, worldZ: number): number?
	local hm, params = _liveHm, _liveParams
	if not hm or not params then return nil end
	local fx = Constants.worldToCorner(worldX)
	local fz = Constants.worldToCorner(worldZ)
	local gx0 = math.floor(fx)
	local gz0 = math.floor(fz)
	local sx = fx - gx0
	local sz = fz - gz0
	local h00 = cornerY(hm, params, gx0, gz0)
	local h10 = cornerY(hm, params, gx0 + 1, gz0)
	local h01 = cornerY(hm, params, gx0, gz0 + 1)
	local h11 = cornerY(hm, params, gx0 + 1, gz0 + 1)
	local top = h00 + (h10 - h00) * sx
	local bot = h01 + (h11 - h01) * sx
	return top + (bot - top) * sz + Constants.RENDER_BULGE
end

-- The client's copy of the authoritative heightmap, or nil before a city has loaded. The
-- sculpt tool applies strokes straight to this so the ground responds on the frame you
-- clicked, instead of after a round trip and the server's patch flush.
function TerrainBuildController.getHeightmap(): Heightmap.Heightmap?
	return _liveHm
end

return TerrainBuildController