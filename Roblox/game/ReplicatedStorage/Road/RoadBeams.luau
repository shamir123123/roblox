--!strict
-- RoadBeams -- painted road lines as Beams: ONE Beam per marking line instead of one Part
-- per facet/dash. A Beam's curve is a cubic bezier (control point = attachment position +
-- attachment X axis * CurveSize), the same curve type roads use, so a line follows the
-- carriageway exactly with zero BaseParts. Beams are render-only: no collision, no queries.
-- Library module: pure construction, no state.

local RoadConstants = require(script.Parent.RoadConstants)

local UP = Vector3.yAxis

local RoadBeams = {}

export type LineOpts = {
	width: number,
	color: Color3,
	dashed: boolean?,
	dashPitch: number?, -- dash tile length override (studs); default DASH_LENGTH + DASH_GAP
	transparency: number?,
	segments: number?,
	up: Vector3?, -- ribbon plane normal; defaults to world up (graded pieces pass their roadUp)
}

-- One flat painted line along the cubic bezier p0..p3, attached to `anchor`.
-- Attachment X axis carries the curve handle; Y up keeps the ribbon flat on the road.
function RoadBeams.line(anchor: BasePart, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, opts: LineOpts)
	local h0 = p1 - p0
	local h1 = p3 - p2
	if h0.Magnitude < 1e-4 then h0 = p3 - p0 end
	if h1.Magnitude < 1e-4 then h1 = p3 - p0 end
	if h0.Magnitude < 1e-4 then return end
	local up = opts.up or UP
	-- The ribbon renders FLAT only when the attachment Y axis is the IN-PLANE side vector
	-- (X = curve direction, Y = X x surfaceNormal). Passing the surface normal itself as Y
	-- makes the ribbon a vertical blade on some headings.
	-- Parent BEFORE setting WorldCFrame: on an unparented attachment WorldCFrame writes the
	-- local Position, so the whole beam ended up offset by the anchor part's own CFrame.
	-- up x dir (NOT dir x up): with X = dir and Y = up x dir the ribbon normal (X x Y)
	-- points along +up. The flipped order lit the ribbon from BELOW on half the headings,
	-- rendering those lines near-black.
	local function sideAxis(h: Vector3): Vector3
		local s = up:Cross(h.Unit)
		return if s.Magnitude > 1e-6 then s.Unit else Vector3.xAxis
	end
	local a0 = Instance.new("Attachment")
	a0.Parent = anchor
	a0.WorldCFrame = CFrame.fromMatrix(p0, h0.Unit, sideAxis(h0))
	local a1 = Instance.new("Attachment")
	a1.Parent = anchor
	a1.WorldCFrame = CFrame.fromMatrix(p3, h1.Unit, sideAxis(h1))
	local beam = Instance.new("Beam")
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.CurveSize0 = h0.Magnitude
	beam.CurveSize1 = h1.Magnitude
	beam.FaceCamera = false
	beam.TextureSpeed = 0 -- static paint; the default (1) scrolls any texture
	beam.LightEmission = 0
	beam.LightInfluence = 1
	-- Beams receive no shadows/AO, so at this game's Brightness (2.6) sun-lit paint crosses
	-- the bloom threshold and reads as glowing. Tone the paint down toward how the old
	-- shaded part-markings rendered; tweak the factor if markings look dull at noon.
	local c = opts.color
	beam.Color = ColorSequence.new(Color3.new(c.R * 0.82, c.G * 0.82, c.B * 0.82))
	beam.Transparency = NumberSequence.new(opts.transparency or 0)
	beam.Segments = opts.segments or 20
	if opts.dashed then
		-- Dash tile repeats every TextureLength studs; paint fills SURFACE_LINE_FILL of the
		-- texture width, so widen the ribbon to keep the painted line at the asked width.
		beam.Texture = RoadConstants.LINE_DASH_TEXTURE
		beam.TextureMode = Enum.TextureMode.Wrap
		beam.TextureLength = opts.dashPitch or (RoadConstants.DASH_LENGTH + RoadConstants.DASH_GAP)
		beam.Width0 = opts.width / RoadConstants.SURFACE_LINE_FILL
		beam.Width1 = beam.Width0
	else
		beam.Width0 = opts.width
		beam.Width1 = opts.width
	end
	beam.Parent = anchor
end

return RoadBeams
