--!strict
-- What a CUT or a COPY hands back to the placement tool, and the capture box's rectangle.
-- Both pure, and both the kind of thing that breaks silently: a copy that quietly drops the
-- material off a prop, a colour forced onto a tree that never had one, or a rectangle that
-- only works when you drag top-left to bottom-right.
return function()
	local NatureSelection = require(script.Parent)

	-- A planted prop is a Model carrying the attributes NaturePlaceService stamps on it,
	-- wrapping the part that holds its colour. Nothing here needs a template or a live game.
	local function prop(key: string, attrs: { [string]: any }?, color: Color3?): Model
		local m = Instance.new("Model")
		m:SetAttribute("NatureKey", key)
		local p = Instance.new("Part")
		p.Color = color or Color3.fromRGB(163, 162, 165)
		p.Parent = m
		for name, value in attrs or {} do
			m:SetAttribute(name, value)
		end
		return m
	end

	local function at(key: string, x: number, z: number, attrs: { [string]: any }?): Model
		local m = prop(key, attrs)
		m.WorldPivot = CFrame.new(x, 0, z)
		return m
	end

	local function near(a: number, b: number): boolean
		return math.abs(a - b) < 1e-4
	end

	describe("capture box", function()
		it("normalises either drag direction", function()
			-- Dragging up-left is the same rectangle as dragging down-right. Without this the
			-- box only ever caught anything on one of the four drags.
			local x0, y0, x1, y1 = NatureSelection.rectOf(Vector2.new(120, 80), Vector2.new(40, 200))
			expect(x0).to.equal(40)
			expect(y0).to.equal(80)
			expect(x1).to.equal(120)
			expect(y1).to.equal(200)
		end)
	end)

	describe("cut / copy", function()
		it("carries the whole look, so placing it again is placing the same thing", function()
			local blue = Color3.fromRGB(0, 120, 200)
			local m = prop("CubeBlock", {
				NatureScale = 2.5,
				NatureColor = 123456,
				NatureMaterial = 4,
				NatureNoCollide = true,
				NatureStretch = Vector3.new(1, 3, 1),
			}, blue)
			local look = NatureSelection.lookOf(m)
			expect(look.key).to.equal("CubeBlock")
			expect(look.scale).to.equal(2.5)
			expect(look.material).to.equal(4)
			-- The COLOUR comes off the part, not from unpacking the attribute: the part already
			-- holds a Color3 and the placement tool wants one.
			expect(look.color).to.equal(blue)
			-- FALSE, not nil: nil means "leave the template's own collision alone", so a copy of
			-- a prop the player switched off has to arrive switched off.
			expect(look.collide).to.equal(false)
			-- Without this a copied twelve-stud beam comes back a cube.
			expect(look.stretch.Y).to.equal(3)
		end)

		it("leaves an unpainted prop's own colours alone", function()
			-- A tree that was never repainted has no NatureColor. Handing back the first part's
			-- colour anyway would repaint the WHOLE tree that one shade -- trunk included.
			local look = NatureSelection.lookOf(prop("OakTree"))
			expect(look.color).to.equal(nil)
			expect(look.material).to.equal(nil)
			expect(look.collide).to.equal(nil)
			expect(look.stretch).to.equal(nil)
			expect(look.scale).to.equal(1)
		end)

		it("refuses anything that is not a planted prop", function()
			-- The selection can only hold Nature props, but stampOf walks the list -- so "no"
			-- has to be nil rather than a half-filled look.
			expect(NatureSelection.lookOf(Instance.new("Model"))).to.equal(nil)
		end)
	end)

	describe("stamp", function()
		it("offsets every prop from the set's CENTRE, so the arrangement survives", function()
			-- THE multi-select bug: cutting four blocks gave back one. A stamp is the whole set
			-- as one placeable, and this is what keeps it in the shape it was cut from.
			local stamp = NatureSelection.stampOf({
				at("CubeBlock", 100, 0), at("CubeBlock", 140, 0),
				at("CubeBlock", 100, 40), at("CubeBlock", 140, 40),
			})
			expect(#stamp).to.equal(4)
			expect(near(stamp[1].dx, -20)).to.equal(true)
			expect(near(stamp[1].dz, -20)).to.equal(true)
			expect(near(stamp[4].dx, 20)).to.equal(true)
			expect(near(stamp[4].dz, 20)).to.equal(true)
			-- Diagonal of the square, wherever it is put down: 40 apart on both axes.
			expect(near(stamp[4].dx - stamp[1].dx, 40)).to.equal(true)
		end)

		it("keeps each prop's own angle, height and look", function()
			-- The single-prop path used to re-roll the yaw and drop the height, so a block
			-- turned 45 degrees and lifted onto a wall came back flat on the ground at zero.
			local m = at("CubeBlock", 0, 0, { NatureYOffset = 7.5, NatureStretch = Vector3.new(1, 3, 1) })
			m.WorldPivot = CFrame.new(0, 0, 0) * CFrame.Angles(0, math.rad(45), 0)
			local s = NatureSelection.stampOf({ m })[1]
			expect(near(math.deg(s.yaw), 45)).to.equal(true)
			-- An OFFSET above the ground, never an absolute Y: the server seats every prop on
			-- the terrain, so a stamp put on a hill climbs it.
			expect(s.yOffset).to.equal(7.5)
			expect(s.stretch.Y).to.equal(3)
		end)

		it("cannot drag the centre off with something that is not a prop", function()
			local stray = Instance.new("Model")
			stray.WorldPivot = CFrame.new(1000, 0, 0)
			local stamp = NatureSelection.stampOf({ at("OakTree", 10, 0), stray })
			expect(#stamp).to.equal(1)
			expect(near(stamp[1].dx, 0)).to.equal(true)
		end)

		it("hands back nothing for an empty selection", function()
			expect(#NatureSelection.stampOf({})).to.equal(0)
		end)
	end)
end
