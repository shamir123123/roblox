local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local failed = 0
for _, path in process.args do
	local ok, err = pcall(luau.compile, fs.readFile(path))
	if ok then
		print("OK   " .. path)
	else
		failed += 1
		print("FAIL " .. path .. "\n  " .. tostring(err))
	end
end
process.exit(if failed > 0 then 1 else 0)
