--!strict
-- Shared constants for the Creation Editor. Client and server read the SAME values so
-- the isolated edit space and the camera vantage can never drift apart.

return table.freeze({
	-- Session platform centre. Parked high above the world so it can never overlap a
	-- loaded _City at ground level. FreeCamController clamps camera X/Z to the map but
	-- leaves Y free, so the client simply flies up to frame it.
	Origin = Vector3.new(0, 1000, 0),
	-- Big plate so the editor camera frames only the platform -- never the world
	-- 1000 studs below, nor the horizon around a small slab.
	GroundSize = Vector3.new(2048, 16, 2048),
})
