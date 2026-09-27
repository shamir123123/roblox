-- Function-level wall-time profiler for lab scripts. Call BEFORE the modules are required:
--   local FP = require("./shim/fnprof")(Studio, { "ServerScriptService.Services.Road.RoadService", ... })
-- Every top-level `local function` of those modules is wrapped in place (so every caller
-- is timed) and, after FP.attach(), every function field of the module table too.
-- FP.report(n) prints the top n by inclusive time; FP.reset() zeroes it.
return function(Studio, modules: { string })
	local FP = { data = {} }
	local data = FP.data
	local clock = os.clock
	_G.__FP = function(key, t) local e = data[key]; if not e then e = { 0, 0 }; data[key] = e end; e[1] += t; e[2] += 1 end
	for _, full in modules do
		local node = Studio.find(full)
		assert(node, "fnprof: no " .. full)
		local name = node._name
		local code = node._props.__code
		local seen, lines = {}, {}
		for fn in code:gmatch("\nlocal function ([%w_]+)") do
			if not seen[fn] then
				seen[fn] = true
				table.insert(lines, ("%s.__o_%s = %s; %s = function(...) local t0 = %s.__clk(); local r = table.pack(%s.__o_%s(...)); %s.__fp(%q, %s.__clk() - t0); return table.unpack(r, 1, r.n) end")
					:format(name, fn, fn, fn, name, name, fn, name, name .. "." .. fn, name))
			end
		end
		Studio.expose(full, name .. ".__clk = function() return 0 end; " .. name .. ".__fp = function() end\n" .. table.concat(lines, "\n"))
	end
	function FP.attach()
		for _, full in modules do
			local M = Studio.require(Studio.find(full))
			local name = Studio.find(full)._name
			M.__clk = clock
			M.__fp = _G.__FP
			for k, v in M do
				if type(v) == "function" and type(k) == "string" and not k:find("^__") then
					M[k] = function(...) local t0 = clock(); local r = table.pack(v(...)); _G.__FP(name .. ":" .. k, clock() - t0); return table.unpack(r, 1, r.n) end
				end
			end
		end
	end
	function FP.reset() table.clear(data) end
	function FP.report(n)
		local rows = {}
		for k, e in data do table.insert(rows, { k = k, t = e[1], c = e[2] }) end
		table.sort(rows, function(a, b) return a.t > b.t end)
		for i = 1, math.min(n or 30, #rows) do
			local r = rows[i]
			print(("FP %8.1f ms %7d calls  %s"):format(r.t * 1000, r.c, r.k))
		end
	end
	return FP
end
