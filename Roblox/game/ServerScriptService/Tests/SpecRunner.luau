--!nonstrict
-- SpecRunner -- runs every *.spec ModuleScript in the place.
--
-- The specs are written against TestEZ's surface (describe / it / expect), but TestEZ is not
-- in this place and never has been, so nothing could run them. This provides just enough of
-- that surface to execute them: the chainable connectors (to / be / been / have / was / at),
-- `never` for negation, and the matchers the specs actually use.
--
-- USAGE, from the Studio command bar:
--   print(require(game.ServerScriptService.Tests.SpecRunner)())
--
-- TWO THINGS THAT WILL BITE YOU IF THIS IS EVER CHANGED
--
-- 1. `script` must be rebound. A spec body calls require(script.Parent...) to reach the module
--    under test, and swapping the function environment throws that away -- every spec then
--    dies on "attempt to index nil with 'Parent'". The env below rebinds it, exactly as TestEZ
--    does. Note the specs use BOTH layouts: some are a child of the module (script.Parent IS
--    the module), some a sibling inside its folder. Neither the runner nor a spec should
--    assume one.
--
-- 2. Each spec gets a CLONE of its whole container, so the module under test starts with fresh
--    state. This is not tidiness -- PlotService.spec is only correct on a virgin copy, because
--    PlotService.Bind() registers its removal listener exactly once. Run it twice against the
--    same module and five demolition tests fail with results that look exactly like real
--    regressions but are not. Requiring the spec alone is not enough: the require cache holds
--    the MODULE, not just the spec.
local SpecRunner = {}

local function makeExpect(value)
	local negated = false
	local chain
	local function check(pass, msg)
		local ok = pass
		if negated then ok = not ok end
		if not ok then error((negated and "expected NOT: " or "") .. msg, 3) end
		return chain
	end
	local m = {}
	m.equal = function(o) return check(value == o, ("expected %s to equal %s"):format(tostring(value), tostring(o))) end
	m.ok = function() return check(value ~= nil, "expected value to be non-nil, got nil") end
	m.near = function(o, lim)
		lim = lim or 1e-7
		return check(type(value) == "number" and type(o) == "number" and math.abs(value - o) <= lim,
			("expected %s to be near %s (+/- %s)"):format(tostring(value), tostring(o), tostring(lim)))
	end
	m.a = function(t) return check(typeof(value) == t, ("expected a %s, got %s"):format(tostring(t), typeof(value))) end
	m.an = m.a
	m.throw = function() return check(not (pcall(value)), "expected function to throw") end
	m.match = function(p) return check(type(value) == "string" and string.match(value, p) ~= nil, "expected string to match pattern") end
	local connect = { to = true, be = true, been = true, have = true, was = true, at = true, ["and"] = true }
	chain = setmetatable({}, { __index = function(_, k)
		if k == "never" then negated = not negated return chain end
		if connect[k] then return chain end
		if m[k] then return m[k] end
		error("unknown matcher: " .. tostring(k), 2)
	end })
	return chain
end

local function runSpec(specModule)
	local passed, failed = 0, {}
	local stack, befores = {}, {}
	local function it(name, fn)
		local full = (#stack > 0 and (table.concat(stack, " > ") .. " > ") or "") .. name
		for _, b in befores do pcall(b) end
		local ok, err = pcall(fn)
		if ok then passed += 1 else table.insert(failed, { full, tostring(err) }) end
	end
	local function describe(name, fn)
		table.insert(stack, name)
		local n = #befores
		local ok, err = pcall(fn)
		if not ok then table.insert(failed, { table.concat(stack, " > "), "describe body threw: " .. tostring(err) }) end
		for i = #befores, n + 1, -1 do befores[i] = nil end
		table.remove(stack)
	end
	local env = setmetatable({
		script = specModule,
		describe = describe, describeFOCUS = describe, describeSKIP = function() end,
		it = it, itFOCUS = it, itSKIP = function() end, itFIXME = function() end,
		expect = makeExpect,
		beforeEach = function(f) table.insert(befores, f) end,
		afterEach = function() end, beforeAll = function(f) pcall(f) end, afterAll = function() end,
		FOCUS = function() end, SKIP = function() end,
	}, { __index = getfenv(0) })
	local ok, fn = pcall(require, specModule)
	if not ok then return nil, "REQUIRE FAILED: " .. tostring(fn) end
	if type(fn) ~= "function" then return nil, "spec did not return a function" end
	setfenv(fn, env)
	local ok2, err = pcall(fn)
	if not ok2 then table.insert(failed, { "<spec body>", tostring(err) }) end
	return { passed = passed, failed = failed }, nil
end

-- `timeout` guards Edit mode: a spec reaching anything that requires Networker yields forever
-- there, because Networker takes its client branch and waits on a Remotes folder the server
-- only creates at boot. Without this the whole run dies with it.
function SpecRunner.run(timeout)
	timeout = timeout or 6
	local out, totalP, totalF, hung = {}, 0, 0, 0
	local function log(s) table.insert(out, s) end

	local specs = {}
	for _, d in game:GetDescendants() do
		if d:IsA("ModuleScript") and (d.Name == "spec" or d.Name:sub(-5) == ".spec")
			and not d.Name:match("__run") then
			table.insert(specs, d)
		end
	end
	table.sort(specs, function(a, b) return a:GetFullName() < b:GetFullName() end)

	for _, original in specs do
		local path = original:GetFullName()
		local container = original.Parent
		local cloneContainer = container:Clone()
		cloneContainer.Name = container.Name .. "__run"
		cloneContainer.Parent = container.Parent

		local specClone
		for _, d in cloneContainer:GetDescendants() do
			if d.Name == original.Name and d:IsA("ModuleScript") then specClone = d break end
		end

		if not specClone then
			log(("SKIP  %s  (could not isolate)"):format(path))
		else
			local res, err, done = nil, nil, false
			task.spawn(function() res, err = runSpec(specClone) done = true end)
			local t0 = os.clock()
			while not done and os.clock() - t0 < timeout do task.wait() end
			if not done then
				hung += 1
				log(("HANG  %s  (yielded >%ds -- Networker / server-only dependency)"):format(path, timeout))
			elseif err then
				totalF += 1
				log(("ERROR %s\n        %s"):format(path, err))
			else
				totalP += res.passed
				totalF += #res.failed
				if #res.failed == 0 then
					log(("ok    %s  (%d passed)"):format(path, res.passed))
				else
					log(("FAIL  %s  (%d passed, %d FAILED)"):format(path, res.passed, #res.failed))
					for _, f in res.failed do log(("        - %s\n          %s"):format(f[1], f[2])) end
				end
			end
		end
		cloneContainer:Destroy()
	end

	log(("\n=== %d spec files | %d passed | %d failed | %d hung ==="):format(#specs, totalP, totalF, hung))
	return table.concat(out, "\n"), totalF + hung
end

return setmetatable(SpecRunner, { __call = function(self, timeout) return self.run(timeout) end })
