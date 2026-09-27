--!strict
-- One runnable check per branch that can actually be wrong: the thousands loop,
-- where the minus sign lands, the duration ladder and the compact cutoff.
-- Plain asserts, no framework.

local Format = require(script.Parent)

return function()
	-- int: the grouping loop
	assert(Format.int(0) == "0", "int 0")
	assert(Format.int(999) == "999", "int 999 must not group")
	assert(Format.int(1000) == "1,000", "int 1000 is the first group boundary")
	assert(Format.int(1234567) == "1,234,567", "int two groups")
	assert(Format.int(-4271) == "-4,271", "int negative: sign outside the groups")
	assert(Format.int(1234.6) == "1,235", "int rounds to nearest")

	-- money: the minus goes before the dollar, not after
	assert(Format.money(1200) == "$1,200", "money positive")
	assert(Format.money(-1200) == "-$1,200", "money negative: -$ not $-")
	assert(Format.money(0) == "$0", "money zero")

	-- signed: zero reads "+0", never a bare "0"
	assert(Format.signed(0) == "+0", "signed zero is explicit")
	assert(Format.signed(38) == "+38", "signed positive")
	assert(Format.signed(-38) == "-38", "signed negative")
	assert(Format.signedMoney(-412) == "-$412", "signedMoney negative")

	-- duration: the h/m/s ladder and its boundaries
	assert(Format.duration(0) == "0s", "duration zero")
	assert(Format.duration(-5) == "0s", "duration clamps negative to zero")
	assert(Format.duration(59) == "59s", "duration seconds")
	assert(Format.duration(60) == "1m", "duration minute boundary")
	assert(Format.duration(3600) == "1h 0m", "duration hour boundary")
	assert(Format.duration(3661) == "1h 1m", "duration hour plus minute")

	-- compact: the 1000 cutoff, because "0.9K" reads worse than "900"
	assert(Format.compact(900) == "900", "compact under 1k falls through to int")
	assert(Format.compact(12400) == "12.4K", "compact thousands")
	assert(Format.compact(1500000) == "1.50M", "compact millions")
	assert(Format.compact(-12400) == "-12.4K", "compact negative")

	return true
end
