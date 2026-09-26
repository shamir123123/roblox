-- Port of the project's SpecRunner: run every *.spec ModuleScript. Usage: lune run specrun <orig|patched>
local process = require("@lune/process")
local mode = process.args[1] or "orig"
local Studio = require("./shim/setup")(mode)

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
	m.a = function(t) return check(Studio.typeof(value) == t, ("expected a %s, got %s"):format(tostring(t), Studio.typeof(value))) end
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
	local extra = {
		describe = describe, describeFOCUS = describe, describeSKIP = function() end,
		it = it, itFOCUS = it, itSKIP = function() end, itFIXME = function() end,
		expect = makeExpect,
		beforeEach = function(f) table.insert(befores, f) end,
		afterEach = function() end, beforeAll = function(f) pcall(f) end, afterAll = function() end,
		FOCUS = function() end, SKIP = function() end,
	}
	local ok, fn = pcall(Studio.loadWith, specModule, extra)
	if not ok then return nil, "REQUIRE FAILED: " .. tostring(fn) end
	if type(fn) == "table" and type(fn.run) == "function" then
		-- "No framework" specs: require(spec).run() asserts and returns true.
		local okRun, errRun = pcall(fn.run)
		if okRun then return { passed = 1, failed = {} }, nil end
		return { passed = 0, failed = { { "run()", tostring(errRun) } } }, nil
	end
	if type(fn) ~= "function" then return nil, "spec did not return a function" end
	local ok2, err = pcall(fn)
	if not ok2 then table.insert(failed, { "<spec body>", tostring(err) }) end
	return { passed = passed, failed = failed }, nil
end

local specs = {}
for _, d in Studio.allDescendants() do
	if d.ClassName == "ModuleScript" and (d.Name == "spec" or d.Name:sub(-5) == ".spec") then table.insert(specs, d) end
end
table.sort(specs, function(a, b) return a:GetFullName() < b:GetFullName() end)
local totalP, totalF = 0, 0
for _, spec in specs do
	Studio.resetRequireCache()
	table.clear(Studio.errors)
	local res, err, done = nil, nil, false
	Studio.task.spawn(function() res, err = runSpec(spec); done = true end)
	local guard = 0
	while not done and guard < 600 do Studio.step(0.1); guard += 1 end
	local path = spec:GetFullName()
	if not done then
		print(("HANG  %s  %s"):format(path, (Studio.errors[1] or ""):sub(1, 300))); totalF += 1
	elseif err then
		print(("ERROR %s  %s"):format(path, err:sub(1, 200))); totalF += 1
	else
		totalP += res.passed
		totalF += #res.failed
		print(("%s %s  (%d passed, %d failed)"):format(#res.failed == 0 and "PASS " or "FAIL ", path, res.passed, #res.failed))
		for _, f in res.failed do print("        - " .. f[1] .. "\n          " .. f[2]:gsub("\n", " "):sub(1, 220)) end
	end
end
print(("TOTAL %s: %d passed, %d failed, %d spec modules"):format(mode, totalP, totalF, #specs))
