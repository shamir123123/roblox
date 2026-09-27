--!strict
-- A save blob must come back exactly: buffers anywhere in it (terrain, nature) as the same
-- bytes, everything else as the same values -- and blobs packed before the buffer container
-- existed (blueprints) must still open.
return function()
	local HttpService = game:GetService("HttpService")
	local EncodingService = game:GetService("EncodingService")
	local BlobCodec = require(script.Parent)

	it("round-trips buffers nested anywhere, empty ones included", function()
		local blob = { name = "x", list = { 1, 2.5, buffer.fromstring("abc") },
			deep = { t = { b = buffer.create(0), c = buffer.fromstring("\0\255") } } }
		local back = BlobCodec.unpack(BlobCodec.pack(blob))
		expect(back.name).to.equal("x")
		expect(back.list[2]).to.equal(2.5)
		expect(buffer.tostring(back.list[3])).to.equal("abc")
		expect(buffer.len(back.deep.t.b)).to.equal(0)
		expect(buffer.tostring(back.deep.t.c)).to.equal("\0\255")
		-- pack must leave the caller's blob alone: MapTemplateService caches what it packed
		expect(typeof(blob.list[3])).to.equal("buffer")
	end)

	it("still opens a blob packed as plain JSON", function()
		local old = EncodingService:CompressBuffer(buffer.fromstring(HttpService:JSONEncode({ a = 1 })), Enum.CompressionAlgorithm.Zstd, 9)
		expect(BlobCodec.unpack(old).a).to.equal(1)
	end)

	it("returns nil for a corrupt buffer", function()
		expect(BlobCodec.unpack(buffer.fromstring("not zstd"))).to.equal(nil)
	end)
end
