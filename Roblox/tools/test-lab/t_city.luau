-- City lab: the REAL server (ServerScriptService.Bootstrap, with the lobby/teleport/terrain-
-- render pieces stubbed) running a small sandbox town -- streets of homes, a shopping strip,
-- an industrial street, schools, and an avenue out to the map edge where families arrive --
-- for a few game days. Every game hour it checks where each person is against where their
-- day says they should be:
--   work   -- employed adults, from 1.5 h into their shift to its end: at work / on the way /
--             at home (the bug: "people sit at home while they are supposed to be working")
--   home   -- employed adults, from 1.5 h after their shift ends to the next one: still at work?
--   school -- school-age children with a school, 1 h into school hours to the end
--   study  -- students (18-22) enrolled at the university, during class hours
-- plus households, cars on the road and trips by purpose, hour by hour.
-- usage: lune run t_city.luau <game days> [seed] [hourly]
-- env: THROUGH=1 through traffic on | ENTRANCE=1 hourly look at the map-edge entrances and
--      what any stopped car there waits on | WHY=1 each worker at home in their shift, and
--      why | LONGLF=1 warn on any off-road line-follow over 800 studs, and the directed routes
local process = require("@lune/process")
local DAYS = tonumber(process.args[1]) or 2
local SEED = tonumber(process.args[2]) or 1
local HOURLY = process.args[3] == "hourly"
local Studio = require("./shim/setup")("cur")
Studio.echo = process.env.ECHO == "1"
local V = Studio.Vector3

local noop = setmetatable({}, { __index = function() return function() end end })
Studio.stub("ServerScriptService.Services.Access.CityTeleport", noop)
Studio.stub("ServerScriptService.Services.Debug.DeveloperService", noop)
Studio.stub("ServerScriptService.Services.Terrain.TerrainRenderer", noop)
-- Lab only: this town has no power or water -- families would leave over it and no
-- workplace would hire -- so every building counts as served.
Studio.expose("ServerScriptService.Services.City.Simulation.CitizenService",
	"Utility.step = function() end\n" ..
	"do local __views = CitizenService._svcViews; CitizenService._svcViews = function(...) local v = __views(...); " ..
	"for _, b in v do b.powered = true; b.watered = true; b.drained = true end; return v end end\n" ..
	"CitizenService.__trips = {}\n" ..
	"if " .. (if process.env.LONGLF == "1" then "true" else "false") .. " then local lf = lineFollow; lineFollow = function(car, wps, ...) local cum = PathFollower.cumOf(wps); " ..
	"if (cum[#cum] or 0) > 800 then warn('LONGLF ' .. #wps .. ' pts ' .. math.floor(cum[#cum]) .. ' from ' .. tostring(wps[1]) .. ' to ' .. tostring(wps[#wps]) .. ' ' .. debug.traceback()) end; return lf(car, wps, ...) end end\n" ..
	"do local se = startErrand; startErrand = function(h, a, kind, ...) CitizenService.__trips[kind] = (CitizenService.__trips[kind] or 0) + 1; return se(h, a, kind, ...) end end\n" ..
	"do local sw = startWork; startWork = function(...) CitizenService.__trips.work = (CitizenService.__trips.work or 0) + 1; return sw(...) end end\n" ..
	"do local ss = startSchool; startSchool = function(...) local ok = ss(...); if ok then CitizenService.__trips.school = (CitizenService.__trips.school or 0) + 1 end; return ok end end\n" ..
	"do local tc = Trips.toClass; Trips.toClass = function(...) CitizenService.__trips.class = (CitizenService.__trips.class or 0) + 1; return tc(...) end end\n" ..
	"CitizenService.__test = { trips = _trips, tokens = _carDriveTokens, households = _households, shiftHours = shiftHours, offset = householdShiftOffsetHours, " ..
	"schoolOffset = schoolShiftOffsetHours }")
Studio.expose("ServerScriptService.Services.City.PlotService", "PlotService.__place = place")
Studio.expose("ServerScriptService.Services.City.BuildingService", "BuildingService.__records = _buildings")
Studio.expose("ServerScriptService.Services.NPC.NPCDriverService", "NPCDriverService.__test = { drivers = _drivers }" ..
	(if process.env.LONGLF == "1" then "\ndo local dd = NPCDriverService.DriveDirected; NPCDriverService.DriveDirected = function(model, s, gpos, route, ...) " ..
	"if model.Name == 'CitizenCar' then warn(('DRIVE %s from (%.0f,%.0f) to (%.0f,%.0f) route %d edges first %s last %s'):format(model.Name, s.X, s.Z, gpos.X, gpos.Z, #route, tostring(route[1]), tostring(route[#route]))) end " ..
	"return dd(model, s, gpos, route, ...) end end" else ""))
-- Through traffic off unless asked for (THROUGH=1): this measures the town's own trips.
if process.env.THROUGH ~= "1" then
	Studio.expose("ServerScriptService.Services.City.Simulation.ThroughTrafficService", "ThroughTrafficService.Start = function() end")
end

-- PROFFN="NPC.NPCDriverService:updateDriver,stallWatchdog;City.PowerService:rebuild": inclusive
-- wall time of those module-local functions (reassigned in place, so every caller is timed).
local profFns = {}
for spec in (process.env.PROFFN or ""):gmatch("[^;]+") do
	local mod, fns = spec:match("^([^:]+):(.+)$")
	local full = "ServerScriptService.Services." .. mod
	local name = mod:match("([^%.]+)$")
	local code = {}
	for fn in fns:gmatch("[^,]+") do
		table.insert(code, ("%s.__o_%s = %s\n%s = function(...) local c = %s.__clock; if not c then return %s.__o_%s(...) end " ..
			"local t0 = c(); local r = table.pack(%s.__o_%s(...)); local e = %s.__pf[%q]; if not e then e = { 0, 0 }; %s.__pf[%q] = e end; e[1] += c() - t0; e[2] += 1; return table.unpack(r, 1, r.n) end")
			:format(name, fn, fn, fn, name, name, fn, name, fn, name, name .. "." .. fn, name, name .. "." .. fn))
	end
	Studio.expose(full, name .. ".__pf = {}\n" .. table.concat(code, "\n"))
	table.insert(profFns, full)
end

local boot = Studio.find("ServerScriptService.Bootstrap.Bootstrap")
Studio.task.spawn(function()
	local ok, err = pcall(Studio.loadWith, boot, {})
	if not ok then print("BOOT ERROR", err) end
end)
for _ = 1, 20 do Studio.step(0.1) end
for _, full in profFns do Studio.require(Studio.find(full)).__clock = os.clock end
local W = Studio.game.Workspace
W:SetAttribute("Sandbox", true)
W:SetAttribute("RoadEditOpen", true)

local R = function(p) return Studio.require(Studio.find(p)) end
local Terrain = R("ServerScriptService.Services.Terrain.TerrainDataService")
local RoadService = R("ServerScriptService.Services.Road.RoadService")
local PlotService = R("ServerScriptService.Services.City.PlotService")
local Education = R("ServerScriptService.Services.City.Civic.EducationService")
local Citizens = R("ServerScriptService.Services.City.Simulation.CitizenService")
local TimeService = R("ServerScriptService.Services.City.TimeService")
local Economy = R("ServerScriptService.Services.City.Economy.CityEconomyService")
local Transit = R("ServerScriptService.Services.Transit.TransitService")
RoadService.setUnlockCheck(function() return true end)
if Education.setUnlockCheck then Education.setUnlockCheck(function() return true end) end
if Education.setTerritoryCheck then Education.setTerritoryCheck(function() return true end) end

-- Flat dry land 10 studs up: the town, and a corridor out to the east edge of the map.
local hm = Terrain.getHeightmap()
local function flat(x0, x1, z0, z1)
	for gx = math.floor(x0 / 4 + 1024), math.ceil(x1 / 4 + 1024) do
		for gz = math.floor(z0 / 4 + 1024), math.ceil(z1 / 4 + 1024) do
			if gx >= 0 and gx <= 2048 and gz >= 0 and gz <= 2048 then hm:setCorner(gx, gz, 256 + 40) end
		end
	end
end
flat(-700, 700, -400, 500)
flat(600, 4096, -80, 80)
flat(-4096, -600, -80, 80)

local function road(a, b, t)
	local d = b - a
	local ok, err = RoadService.placeFromRequest({ p0 = a, p1 = a + d / 3, p2 = a + d * 2 / 3, p3 = b, roadType = t or "NarrowRoad" })
	if not ok then print("road failed", err) end
	for _ = 1, 3 do Studio.step(0.1) end
end
-- avenue east to the map edge (the outside connection families arrive by)
road(V.new(-4090, 0, 0), V.new(4090, 0, 0), "CollectorRoad")
-- homes: two streets north of the avenue, three cross streets
for _, z in { 120, 240 } do road(V.new(-400, 0, z), V.new(0, 0, z)) end
for _, x in { -400, -200, 0 } do road(V.new(x, 0, 0), V.new(x, 0, 240)) end
-- industry: a street south of the avenue
road(V.new(0, 0, -140), V.new(400, 0, -140))
for _, x in { 0, 400 } do road(V.new(x, 0, 0), V.new(x, 0, -140)) end
for _ = 1, 20 do Studio.step(0.1) end

local player = Studio.addPlayer("Mayor", 1)
for _ = 1, 10 do Studio.step(0.1) end
local zoned = { Residential = 0, Commercial = 0, Industrial = 0 }
for id, seg in RoadService.getNetwork():getSegments() do
	local mid = (seg.p0 + seg.p3) * 0.5
	local zone: string? = nil
	if mid.X < 0 and mid.Z > 20 then zone = "Residential"
	elseif mid.X > 0 and mid.X < 400 and math.abs(mid.Z) < 5 then zone = "Commercial"
	elseif mid.X > 0 and mid.X < 400 and mid.Z < -20 then zone = "Industrial"
	elseif mid.X < 0 and mid.X > -400 and math.abs(mid.Z) < 5 then zone = "Residential" end
	if zone then
		for _, side in { 1, -1 } do
			PlotService.__place(player, { zone = zone, cells = { { seg = id, side = side, t0 = 0, t1 = 1 } }, immediate = true })
			zoned[zone] += 1
			for _ = 1, 2 do Studio.step(0.2) end
		end
	end
end
print(("zoned sides: R %d  C %d  I %d"):format(zoned.Residential, zoned.Commercial, zoned.Industrial))
-- schools: an elementary and a high school among the homes, a university by the avenue
local ground = Terrain.getSurfaceY(0, 0)
for _, s in { { "Elementary", -300, 180 }, { "HighSchool", -100, 180 }, { "University", -520, 120 } } do
	local ok, err = Education.placeFree(s[1], Studio.CFrame.new(s[2], ground, s[3]), nil)
	print("school", s[1], ok, err)
end

-- A city that has finished loading starts these (CitySlotService does it in the game).
TimeService.Start(); Economy.Start(); Transit.Start()
for _ = 1, 10 do Studio.step(0.2) end

-- == Run ======================================================================
local T = Citizens.__test
local function inWindow(h: number, a: number, b: number): boolean
	a, b = a % 24, b % 24
	if a <= b then return h >= a and h < b end
	return h >= a or h < b
end
local tally = { work = {}, home = {}, school = {}, study = {} }
local function add(kind, stage)
	local t = tally[kind]
	t[stage] = (t[stage] or 0) + 1
	t._n = (t._n or 0) + 1
end
local buildings = R("ServerScriptService.Services.City.BuildingService")
local function jobView(id)
	for _, b in buildings.listBuildings() do if b.bpId == id then return b end end
	return nil
end

-- A few 19-year-old high-school graduates, to exercise the university (none of the arriving
-- families' children is old enough in a short run). Added once families have moved in.
local studentsAdded = false
local function addStudents()
	local n = 0
	for _, h in T.households do
		if h.arriving or n >= 4 then continue end
		n += 1
		table.insert(h.adults, {
			name = "Student" .. n, gender = "F", age = 19, pid = 900000 + n, eduLevel = 2, wantsStudy = true,
			jobId = nil, joblessDays = 0, stage = "atHome", tripId = 0, walkerId = nil, outKind = nil, outDestId = nil,
			usingCar = false, ownsCar = false, tripTargetId = nil, tripTargetHome = false,
			commutedWorkDay = 0, commutedHomeDay = 0, nextErrandAt = 0,
		})
	end
	return n > 0
end
local DT = 0.25
local dayLen = 1440
local lastHour = -1
local t = 0
local startDay = TimeService.getDay()
local peakCars, hourlyRows = 0, {}
local endDay = startDay + DAYS
local served = R("ServerScriptService.Services.City.BuildingService").__records
-- PROF=1: wall time per connected callback / spawned thread over the run, per sim second.
if process.env.PROF == "1" then Studio.prof = {} end
local wall0 = os.clock()
while TimeService.getDay() + TimeService.getDayFraction() < endDay + 0.5 and t < DAYS * dayLen * 4 do
	-- (lab: every building counts as powered and watered -- see the CitizenService override)
	for _, rec in served do rec.powered = true; rec.watered = true; rec.drained = true end
	Studio.step(DT)
	t += DT
	local hour = TimeService.getDayFraction() * 24
	local hi = math.floor(hour)
	if not studentsAdded and t > 120 then studentsAdded = addStudents() end
	if hi ~= lastHour then
		lastHour = hi
		local snap = Citizens.debugSnapshot()
		peakCars = math.max(peakCars, snap.driving or 0)
		local views = {}
		for _, b in buildings.listBuildings() do views[b.bpId] = b end
		local row = { day = TimeService.getDay() - startDay, hour = hi, hh = snap.households, driving = snap.driving or 0, atWork = 0, atHome = 0, transit = 0, school = 0 }
		for hid, h in T.households do
			if h.arriving then continue end
			for _, a in h.adults do
				row[a.stage] = (row[a.stage] or 0) + 1
				if a.jobId and views[a.jobId] then
					local s, e = T.shiftHours(views[a.jobId])
					local off = T.offset(hid)
					if inWindow(hour, s + off + 1.5, e + off) then
						add("work", a.stage)
						if a.stage == "atHome" and process.env.WHY == "1" then
							print(("  WHY d%d %.1fh %s shift %g-%g+%.2f commutedWorkDay %s day %d commutedHomeDay %s nextErrand %.0f job %s zone %s")
								:format(TimeService.getDay() - startDay, hour, a.name, s, e, off, tostring(a.commutedWorkDay), TimeService.getDay(),
									tostring(a.commutedHomeDay), (a.nextErrandAt or 0) - os.clock(), tostring(a.jobId), tostring(views[a.jobId].zone)))
						end
					elseif inWindow(hour, e + off + 1.5, s + off) then add("home", a.stage) end
				end
				if a.studyId then
					if inWindow(hour, 10.5, 16) then add("study", a.stage) end
				end
			end
			for _, k in h.kids do
				if k.age >= 5 and k.age <= 17 and k.schoolId then
					if inWindow(hour, 9.25, 15) then add("school", k.stage) end
					if k.stage == "atSchool" then row.school += 1 end
				end
			end
		end
		table.insert(hourlyRows, row)
		if process.env.ENTRANCE == "1" then
			local D = R("ServerScriptService.Services.NPC.NPCDriverService").__test.drivers
			for _, x in { -4090, 4090 } do
				local n, stopped, names = 0, 0, {}
				for m, st in D do
					local p = st.smoothCFrame and st.smoothCFrame.Position
					if p and math.abs(p.X - x) < 80 and math.abs(p.Z) < 30 then
						n += 1
						if (st.currentSpeed or 0) < 0.5 then stopped += 1 end
						if #names < 3 then table.insert(names, ("%s@%.0f,%.0f v%.1f %s"):format(m.Name, p.X, p.Z, st.currentSpeed or 0, tostring(st.stopReason))) end
					end
				end
				print(("  d%d %02dh entrance x=%d: %d cars (%d stopped) %s"):format(row.day, hi, x, n, stopped, table.concat(names, " | ")))
			end
		end
		if HOURLY then
			local bz = { Residential = 0, Commercial = 0, Industrial = 0 }
			local sites = W:FindFirstChild("_City") and W._City:FindFirstChild("ConstructionSites")
			for _, b in buildings.listBuildings() do bz[b.zone] = (bz[b.zone] or 0) + 1 end
			print(("d%d %02dh  households %3d  driving %3d  adults: home %3d work %3d transit %3d  kids at school %3d | buildings R%d C%d I%d sites %d")
				:format(row.day, hi, row.hh or 0, row.driving, row.atHome or 0, row.atWork or 0, row.transit or 0, row.school,
					bz.Residential, bz.Commercial, bz.Industrial, sites and #sites:GetChildren() or 0))
		end
	end
end

local function pct(t, k) return if (t._n or 0) > 0 then 100 * (t[k] or 0) / t._n else 0 end
local snap = Citizens.debugSnapshot()
print(("CITY [%d days seed %d] households %d employed %d | peak cars driving %d"):format(DAYS, SEED, snap.households or 0, snap.employed or 0, peakCars))
print(("  during shift  (n=%d): at work %.0f%%  on the way %.0f%%  AT HOME %.0f%%"):format(tally.work._n or 0, pct(tally.work, "atWork"), pct(tally.work, "transit"), pct(tally.work, "atHome")))
print(("  after shift   (n=%d): at home %.0f%%  on the way %.0f%%  STILL AT WORK %.0f%%"):format(tally.home._n or 0, pct(tally.home, "atHome"), pct(tally.home, "transit"), pct(tally.home, "atWork")))
print(("  school hours  (n=%d): at school %.0f%%  on the way %.0f%%  AT HOME %.0f%%"):format(tally.school._n or 0, pct(tally.school, "atSchool"), pct(tally.school, "transit"), pct(tally.school, "atHome")))
print(("  class hours   (n=%d): at uni %.0f%%  on the way %.0f%%  at home %.0f%%"):format(tally.study._n or 0, pct(tally.study, "atStudy"), pct(tally.study, "transit"), pct(tally.study, "atHome")))
do
	local kids, schoolAge, assigned, students, wants = 0, 0, 0, 0, 0
	local ages = {}
	for _, h in T.households do
		for _, k in h.kids do
			kids += 1
			table.insert(ages, k.age)
			if k.age >= 5 and k.age <= 17 then schoolAge += 1 end
			if k.schoolId then assigned += 1 end
		end
		for _, a in h.adults do
			if a.wantsStudy then wants += 1 end
			if a.studyId then students += 1 end
		end
	end
	table.sort(ages)
	print(("kids %d (ages %s), school age %d, with a school %d | adults wanting university %d, enrolled %d")
		:format(kids, table.concat(ages, ","), schoolAge, assigned, wants, students))
end
if process.env.ENTRANCE == "1" then
	-- The head of any stopped queue near the east entrance, and what it is waiting on.
	local D = R("ServerScriptService.Services.NPC.NPCDriverService").__test.drivers
	for m, st in D do
		local p = st.smoothCFrame and st.smoothCFrame.Position
		if p and p.X > 3600 and math.abs(p.Z) < 30 and (st.currentSpeed or 0) < 0.5 then
			local b = st.blockedBy
			local bst = b and D[b]
			local bp = b and b:GetPivot().Position
			print(("  STOPPED %s @(%.0f,%.0f) edge %s@%.0f conn %s next %s reason %s blockedBy %s%s")
				:format(m.Name, p.X, p.Z, tostring(st.edgeId), st.edgeDist or 0, tostring(st.connector ~= nil), tostring(st.nextEdgeId or st.pendingNextEdgeId),
					tostring(st.stopReason), b and b.Name or "-",
					if b then (" @(%.0f,%.0f) registered %s state %s"):format(bp.X, bp.Z, tostring(bst ~= nil), bst and (tostring(bst.edgeId) .. " v" .. tostring(bst.currentSpeed) .. " " .. tostring(bst.stopReason)) or "-") else ""))
		end
	end
end
if process.env.ENTRANCE == "1" then
	local folder = W._City:FindFirstChild("Citizens")
	for _, m in (folder and folder:GetChildren() or {}) do
		if m:IsA("Model") then
			local p = m:GetPivot().Position
			if p.X > 3600 and math.abs(p.Z) < 30 then
				local owner = "none"
				for hid, h in T.households do
					for _, a in h.adults do
						if a.car == m then owner = ("household %d adult %s stage %s arriving %s"):format(hid, a.name, a.stage, tostring(h.arriving)) end
					end
				end
				local tr = T.trips[m]
				print(("  CITIZENCAR %s @(%.0f,%.0f) pid %s purpose %s owner %s trip %s gate %s dist %.1f/%.1f stall %.1f directed %s")
					:format(m.Name, p.X, p.Z, tostring(m:GetAttribute("CitizenPid")), tostring(m:GetAttribute("TripPurpose")), owner,
						tostring(tr ~= nil), tostring(tr and tr.gate ~= nil), tr and tr.dist or -1, tr and tr.cum[#tr.cum] or -1, tr and tr.stallTime or -1,
						tostring(R("ServerScriptService.Services.NPC.NPCDriverService").IsDirected(m))))
			end
		end
	end
end
-- What stands at the map-edge entrances (move-ins wait for them to clear).
do
	local D = R("ServerScriptService.Services.NPC.NPCDriverService").__test.drivers
	for _, x in { -4090, 4090 } do
		local n = 0
		for m, st in D do
			local p = st.smoothCFrame and st.smoothCFrame.Position
			if p and math.abs(p.X - x) < 120 and math.abs(p.Z) < 30 then
				n += 1
				if n <= 6 then
					print(("  entrance x=%d: %s speed %.1f edge %s@%.0f reason %s stuck %.0f directed %s"):format(x, m.Name, st.currentSpeed or 0,
						tostring(st.edgeId), st.edgeDist or 0, tostring(st.stopReason), st.stuckTime or 0, tostring(st.route ~= nil)))
				end
			end
		end
		print(("entrance x=%d: %d vehicles within 120 studs"):format(x, n))
	end
end
do
	local parts = {}
	for k, v in Citizens.__trips do table.insert(parts, k .. " " .. v) end
	table.sort(parts)
	print("trips started by purpose: " .. table.concat(parts, ", "))
end
if Studio.prof then
	local rows, total = {}, 0
	for k, e in Studio.prof do table.insert(rows, { k = k, t = e.t, n = e.n }); total += e.t end
	table.sort(rows, function(a, b) return a.t > b.t end)
	print(("PROF %.1f s wall for %.0f sim s (%.1f ms per sim s); callbacks %.1f s"):format(os.clock() - wall0, t, (os.clock() - wall0) * 1000 / t, total))
	for _, full in profFns do
		for k, v in R(full).__pf do table.insert(rows, { k = "FN " .. k, t = v[1], n = v[2] }) end
	end
	table.sort(rows, function(a, b) return a.t > b.t end)
	for i = 1, math.min(30, #rows) do
		local r = rows[i]
		print(("PROF %6.2f ms/sim-s  %5.1f%%  %7d calls  %s"):format(r.t * 1000 / t, r.t * 100 / total, r.n, r.k:gsub("^.*ServerScriptService%.", ""):gsub("^.*ReplicatedStorage%.", "RS.")))
	end
end
print("errors", #Studio.errors)
for i = 1, math.min(5, #Studio.errors) do print("ERR", Studio.errors[i]:sub(1, 300)) end
local seen = {}
for _, w in Studio.warnings do
	local k = w:sub(1, 60)
	if not seen[k] and not w:find("DataStore") and not w:find("MemoryStore") and not w:find("PlayerGui") and not w:find("WaitForChild miss") then
		seen[k] = true
		print("WARN", if w:find("LONGLF") then w else w:sub(1, 200))
	end
end
