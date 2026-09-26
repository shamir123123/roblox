-- Per-tick observers for the traffic lab: lane changes, speed kept through them, overlaps.
local M = {}

function M.new(w)
	return { w = w, overlapSamples = 0, overlapPairs = {}, maxOverlapDepth = 0, samples = 0 }
end

local function laneOf(w, edgeId)
	local e = edgeId and w.graph:GetEdge(edgeId)
	return e
end

-- Call every tick: follows each car's lane-change state machine.
function M.tick(m)
	local w = m.w
	for _, rec in w.cars do
		local st = w:state(rec.model)
		if not st then continue end
		local lc = st.laneChange
		local inLc = lc ~= nil and st.connector == lc.pts
		if inLc then
			local cruise = math.max(st.speed or 1, 1)
			local ratio = (st.currentSpeed or 0) / cruise
			if not rec._inLc then rec._inLc = true; rec._lcStartRatio = ratio; rec._lcMin = ratio end
			rec._lcMin = math.min(rec._lcMin, ratio)
		elseif rec._inLc then
			rec._inLc = false
			rec.laneChanges += 1
			rec.lcMinRatio = math.min(rec.lcMinRatio, rec._lcMin)
			-- a move started at cruise that dropped below 70% of it is the "slows down" bug
			if rec._lcStartRatio >= 0.8 and rec._lcMin < 0.7 then rec.lcBraked = (rec.lcBraked or 0) + 1 end
		end
		-- lane shifts through a join (not a mid-block change): lane ordinal jumps across segments
		if st.edgeId ~= rec._lastEdge then
			local a, b = laneOf(w, rec._lastEdge), laneOf(w, st.edgeId)
			if a and b and a.segmentId ~= b.segmentId and a.laneOrdinal ~= b.laneOrdinal and not rec._inLc then
				rec.joinShifts = (rec.joinShifts or 0) + 1
			end
			rec._lastEdge = st.edgeId
		end
	end
end

-- Call every few ticks: bumper overlap between any two cars (in car A's own frame).
function M.overlaps(m)
	local w = m.w
	m.samples += 1
	local live = {}
	for _, rec in w.cars do
		local st = w:state(rec.model)
		if st and st.smoothCFrame then
			table.insert(live, { rec = rec, cf = st.smoothCFrame, half = st.halfLength or 4.5, rescue = st.rescueFrom ~= nil })
		end
	end
	local any = false
	for i = 1, #live do
		local a = live[i]
		local pa, fa, ra = a.cf.Position, a.cf.LookVector, a.cf.RightVector
		for j = i + 1, #live do
			local b = live[j]
			local d = b.cf.Position - pa
			if math.abs(d.X) > 20 or math.abs(d.Z) > 20 then continue end
			local f, l = math.abs(d:Dot(fa)), math.abs(d:Dot(ra))
			local needF, needL = (a.half + b.half) * 0.85, 3.8 * 0.85
			if f < needF and l < needL then
				any = true
				local key = a.rec.model.Name .. "|" .. b.rec.model.Name
				m.overlapPairs[key] = (m.overlapPairs[key] or 0) + 1
				m.maxOverlapDepth = math.max(m.maxOverlapDepth, needF - f)
				if a.rescue or b.rescue then m.rescueOverlaps = (m.rescueOverlaps or 0) + 1 end
				if m.log and m.overlapPairs[key] == 1 then
					local function desc(x)
						local st = w:state(x.rec.model)
						local lc = st.laneChange and st.connector == st.laneChange.pts
						return ("%s[%s %s edge=%s next=%s spd=%.0f blk=%s]"):format(x.rec.model.Name, tostring(st.stopReason),
							if lc then "LANECHG" elseif st.connector then "BOX" else "lane", st.edgeId, tostring(st.nextEdgeId),
							st.currentSpeed or 0, st.blockedBy and st.blockedBy.Name or "-")
					end
					print(("   overlap t=%.1f at %d,%d  f=%.1f l=%.1f  %s  %s"):format(w.Studio.clock.now - 1000, pa.X, pa.Z, f, l, desc(a), desc(b)))
				end
			end
		end
	end
	if any then m.overlapSamples += 1 end
end

function M.summary(m)
	local w = m.w
	local n, arrived, lc, unneeded, braked, joinShifts, stuck, minRatio = 0, 0, 0, 0, 0, 0, 0, math.huge
	for _, rec in w.cars do
		n += 1
		if rec.arrived then arrived += 1 end
		lc += rec.laneChanges
		joinShifts += rec.joinShifts or 0
		braked += rec.lcBraked or 0
		minRatio = math.min(minRatio, rec.lcMinRatio)
		local first, last = w.graph:GetEdge(rec.route[1]), w.graph:GetEdge(rec.route[#rec.route])
		local need = if first and last then math.abs(first.laneOrdinal - last.laneOrdinal) else 0
		if rec.arrived then unneeded += math.max(0, rec.laneChanges + (rec.joinShifts or 0) - need) end
	end
	local pairs = 0
	for _ in m.overlapPairs do pairs += 1 end
	local stalls = 0
	for _, wn in w.Studio.warnings do if wn:find("stalled") then stalls += 1 end end
	return {
		cars = n, arrived = arrived, laneChanges = lc, joinShifts = joinShifts, unneeded = unneeded,
		brakedLaneChanges = braked, minLcSpeedRatio = if minRatio == math.huge then 1 else minRatio,
		overlapSamples = m.overlapSamples, overlapPairs = pairs, samples = m.samples,
		rescueOverlaps = m.rescueOverlaps or 0, stallRescues = stalls, errors = #w.Studio.errors,
	}
end

function M.print(title: string, s: any)
	print(("%-34s cars %3d  arrived %3d  laneChg %3d (+%d join)  unneeded %3d  braked %2d  minLcSpd %3.0f%%  overlapPairs %3d (%d/%d samples, %d rescue)  stalls %d  errors %d")
		:format(title, s.cars, s.arrived, s.laneChanges, s.joinShifts, s.unneeded, s.brakedLaneChanges, s.minLcSpeedRatio * 100,
			s.overlapPairs, s.overlapSamples, s.samples, s.rescueOverlaps, s.stallRescues, s.errors))
end

return M
