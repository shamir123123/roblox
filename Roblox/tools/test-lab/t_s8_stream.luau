-- Scenario 8: the pose stream a far viewer receives. A busy street grid with the camera
-- ~1500 studs away (the 2 Hz, 1-in-2 sample band). Decodes every packet sent to that viewer
-- and rebuilds what their screen holds (each car at the last pose it was sent), then measures:
--   stop lag   -- after a car comes to rest, seconds until the viewer has its resting pose
--   overlaps   -- pairs of cars the viewer draws one inside the other (bumper overlap)
--   farewells  -- poses marked as the car's last before it leaves the viewer's stream
-- usage: lune run t_s8_stream.luau <mode> <seconds> <seed> [focus distance]
local World = require("./shim/traffic")
local process = require("@lune/process")
local mode = process.args[1] or "cur"
local T = tonumber(process.args[2]) or 240
local seed = tonumber(process.args[3]) or 1
local FAR = tonumber(process.args[4]) or 1500

local w = World.new(mode)
local V = w.V
local Studio = w.Studio
local N, S = 4, 200
for i = 0, N - 1 do
	for j = 0, N - 1 do
		local p = V.new(i * S, 0, j * S)
		if i < N - 1 then w:road(p, V.new((i + 1) * S, 0, j * S), "CollectorRoad") end
		if j < N - 1 then w:road(p, V.new(i * S, 0, (j + 1) * S), "CollectorRoad") end
	end
end
w:build(true)
w:camera(V.new(300 + FAR, 0, 300))
-- the stream only carries tagged vehicles
local CollectionService = Studio.game:GetService("CollectionService")

-- == the viewer's screen ==
local seen: { [number]: { pos: Vector3, at: number, dropped: boolean } } = {}
local farewells, packets = 0, 0
Studio.onRemote = function(remote, kind, player, buf)
	if remote.Name ~= "SyncNpcPoses" or kind ~= "client" then return end
	packets += 1
	local now = Studio.clock.now
	local n = (buffer.len(buf) - 8) // 19
	for k = 0, n - 1 do
		local off = 8 + k * 19
		local id = buffer.readu32(buf, off)
		local pos = V.new(buffer.readf32(buf, off + 4), buffer.readf32(buf, off + 8), buffer.readf32(buf, off + 12))
		local farewell = buffer.readi8(buf, off + 18) == -128
		if farewell then farewells += 1 end
		local old = seen[id]
		seen[id] = { pos = pos, at = now, dropped = farewell,
			firstAt = if old and not old.dropped then old.firstAt else now }
	end
end

local rng = Studio.Random.new(seed)
local function randomRoadPoint()
	local i, j = rng:NextInteger(0, N - 1), rng:NextInteger(0, N - 2)
	local along = rng:NextNumber(0.25, 0.75) * S
	if rng:NextNumber() < 0.5 then return V.new(i * S, 0, j * S + along) end
	return V.new(j * S + along, 0, i * S)
end

local DT = 1 / 30
local t, spawned = 0, 0
local restAt: { [any]: number } = {}   -- model -> clock when it came to rest (server)
local lastPos: { [any]: Vector3 } = {}
local lags: { number } = {}
local overlapSamples, samples, stuckLag = 0, 0, 0
while t < T do
	if spawned < 260 and math.floor(t * 30) % 3 == 0 then
		local a, b = randomRoadPoint(), randomRoadPoint()
		if (a - b).Magnitude > 300 and w.Drivers.IsPointClear(a, 14) then
			local rec = w:drive(a, b)
			if rec then
				CollectionService:AddTag(rec.model, "NPCDriver")
				spawned += 1
			end
		end
	end
	w:step(DT)
	t += DT
	-- swing the camera in and out across the 1000-stud band edge halfway through
	if math.abs(t - T * 0.5) < DT / 2 then w:camera(V.new(300 + 900, 0, 300)) end
	if math.abs(t - T * 0.75) < DT / 2 then w:camera(V.new(300 + FAR, 0, 300)) end
	local now = Studio.clock.now
	for _, rec in w.cars do
		local st = w:state(rec.model)
		local id = rec.model:GetAttribute("NpcId")
		if not st or not st.smoothCFrame or not id then continue end
		local p = st.smoothCFrame.Position
		local prev = lastPos[rec.model]
		lastPos[rec.model] = p
		if prev and (p - prev).Magnitude < 1e-3 then
			restAt[rec.model] = restAt[rec.model] or now
		else
			restAt[rec.model] = nil
		end
		-- A real stop (still for a second or more): when did the viewer first hold its resting pose?
		local since = restAt[rec.model]
		local v = seen[id]
		-- only cars the viewer was already receiving when they stopped
		if since and v and not v.dropped and v.firstAt <= since then
			if not rec._matchAt and (v.pos - p).Magnitude < 0.6 then rec._matchAt = now end
			if not rec._lagDone and now - since >= 1 then
				rec._lagDone = true
				if rec._matchAt then
					table.insert(lags, math.max(0, rec._matchAt - since))
				elseif now - since > 3 then
					stuckLag += 1
				else
					rec._lagDone = nil
				end
			end
		end
		if not since then rec._lagDone = nil; rec._matchAt = nil end
	end
	-- what the viewer draws, one inside the other?
	if math.floor(t / DT) % 10 == 0 then
		samples += 1
		local drawn = {}
		for _, rec in w.cars do
			local st = w:state(rec.model)
			local id = rec.model:GetAttribute("NpcId")
			local v = id and seen[id]
			if st and v and not v.dropped then table.insert(drawn, { pos = v.pos, half = st.halfLength or 4.5 }) end
		end
		local any = false
		for i = 1, #drawn do
			for j = i + 1, #drawn do
				local a, b = drawn[i], drawn[j]
				local d = a.pos - b.pos
				if math.abs(d.X) < 20 and math.abs(d.Z) < 20 and V.new(d.X, 0, d.Z).Magnitude < (a.half + b.half) * 0.6 then
					any = true
				end
			end
		end
		if any then overlapSamples += 1 end
	end
end
table.sort(lags)
local function pct(q) return if #lags > 0 then lags[math.max(1, math.floor(#lags * q))] else 0 end
print(("S8 stream [%s, %ds, seed %d, viewer %d studs] packets %d | stop lag p50 %.2fs p90 %.2fs max %.2fs (n=%d, never told within 3s: %d) | drawn overlapping: %d/%d samples | farewells %d | errors %d")
	:format(mode, T, seed, FAR, packets, pct(0.5), pct(0.9), if #lags > 0 then lags[#lags] else 0, #lags, stuckLag,
		overlapSamples, samples, farewells, #Studio.errors))
if #Studio.errors > 0 then print(Studio.errors[1]:sub(1, 600)) end
