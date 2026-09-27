--!strict
-- Packed rows must come back exactly, and anything the packer cannot hold exactly must be
-- refused, never rounded -- the caller keeps its plain table then.
return function()
	local NumberPack = require(script.Parent)

	it("round-trips rows with negatives, big values and a delta column", function()
		local ints = { 3, -12345, 0, 16777215, 1, 20, -7, -1, 2, 20, 99999999, 0 }
		local back = NumberPack.unpack(assert(NumberPack.pack(ints, 4, 2)), 4, 2)
		expect(table.concat(back :: any, ",")).to.equal(table.concat(ints, ","))
	end)

	it("refuses a non-integer instead of rounding it", function()
		expect(NumberPack.pack({ 1, 2.5 }, 1)).to.equal(nil)
	end)

	it("returns nil for a truncated buffer", function()
		local b = assert(NumberPack.pack({ 1000, 2000, 3000 }, 1))
		local cut = buffer.create(buffer.len(b) - 1)
		buffer.copy(cut, 0, b, 0, buffer.len(cut))
		expect(NumberPack.unpack(cut, 1)).to.equal(nil)
	end)
end
