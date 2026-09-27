--!strict
return function()
	local AddressBook = require(script.Parent)

	-- Three pieces of one straight west-east road, plus a side road crossing it at
	-- the middle junction. Handles sit at chord thirds, as placement builds them.
	local function seg(id: number, a: Vector3, b: Vector3, startNode: number, endNode: number, roadType: string?, name: string?)
		return {
			id = id, startNode = startNode, endNode = endNode,
			roadType = roadType or "NarrowRoad",
			p0 = a, p1 = a + (b - a) / 3, p2 = a + (b - a) * 2 / 3, p3 = b,
			name = name,
		}
	end

	local function street(): { any }
		return {
			seg(1, Vector3.new(0, 0, 0),   Vector3.new(100, 0, 0), 1, 2),
			seg(2, Vector3.new(100, 0, 0), Vector3.new(200, 0, 0), 2, 3),
			seg(3, Vector3.new(200, 0, 0), Vector3.new(300, 0, 0), 3, 4),
			-- Side road meeting the through road at node 3, at a right angle.
			seg(4, Vector3.new(200, 0, 0), Vector3.new(200, 0, 120), 3, 5),
		}
	end

	describe("buildIndex", function()
		it("joins the straight continuation into one street", function()
			local index = AddressBook.buildIndex(street())
			expect(index.keyOf[1]).to.equal(index.keyOf[2])
			expect(index.keyOf[2]).to.equal(index.keyOf[3])
		end)

		it("does not turn the name onto a side road", function()
			local index = AddressBook.buildIndex(street())
			expect(index.keyOf[4]).never.to.equal(index.keyOf[1])
		end)

		it("gives every piece of one street the same name", function()
			local index = AddressBook.buildIndex(street())
			local name = AddressBook.nameOf(index, 1)
			expect(name).to.be.ok()
			expect(AddressBook.nameOf(index, 3)).to.equal(name)
		end)

		it("is deterministic, so client and server agree", function()
			local a = AddressBook.buildIndex(street())
			local b = AddressBook.buildIndex(street())
			expect(AddressBook.nameOf(a, 2)).to.equal(AddressBook.nameOf(b, 2))
		end)
	end)

	describe("renames", function()
		it("one named piece names the whole street", function()
			local segs = street()
			segs[3].name = "Kingsway"
			local index = AddressBook.buildIndex(segs)
			expect(AddressBook.nameOf(index, 1)).to.equal("Kingsway")
			expect(AddressBook.nameOf(index, 2)).to.equal("Kingsway")
		end)

		it("leaves the side road alone", function()
			local segs = street()
			segs[1].name = "Kingsway"
			local index = AddressBook.buildIndex(segs)
			expect(AddressBook.nameOf(index, 4)).never.to.equal("Kingsway")
		end)
	end)

	describe("numberAt", function()
		it("grows with distance along the street", function()
			local index = AddressBook.buildIndex(street())
			local near = AddressBook.numberAt(index, 1, Vector3.new(10, 0, 5))
			local far = AddressBook.numberAt(index, 3, Vector3.new(290, 0, 5))
			expect(far > near).to.equal(true)
		end)

		it("puts opposite sides of the road on opposite parities", function()
			local index = AddressBook.buildIndex(street())
			local left = AddressBook.numberAt(index, 2, Vector3.new(150, 0, 20))
			local right = AddressBook.numberAt(index, 2, Vector3.new(150, 0, -20))
			expect(left % 2).never.to.equal(right % 2)
		end)

		it("never returns a number below one", function()
			local index = AddressBook.buildIndex(street())
			expect(AddressBook.numberAt(index, 1, Vector3.new(0, 0, -1)) >= 1).to.equal(true)
		end)
	end)

	describe("addressOfPoint", function()
		it("addresses a point beside the road", function()
			local index = AddressBook.buildIndex(street())
			local address = AddressBook.addressOfPoint(index, Vector3.new(150, 0, 18), 60)
			expect(address).to.be.ok()
			expect(string.match(address :: string, "^%d+ ")).to.be.ok()
		end)

		it("refuses a point with no road near it", function()
			local index = AddressBook.buildIndex(street())
			expect(AddressBook.addressOfPoint(index, Vector3.new(9000, 0, 9000), 60)).to.equal(nil)
		end)
	end)

	describe("classOf", function()
		it("separates alleys, arterials and ordinary streets", function()
			expect(AddressBook.classOf("NarrowRoad")).to.equal("local_")
			expect(AddressBook.classOf("CollectorRoad")).to.equal("arterial")
			expect(AddressBook.classOf("Alley")).to.equal("alley")
		end)
	end)
end
