--!strict
-- DrawCallProbe -- answers the one question the whole proxy design is built on and that
-- nothing had ever measured: does the engine actually collapse identical baked meshes into a
-- single draw call, and does tinting them per instance break that?
--
-- WHY IT MATTERS
-- LODProxyCache keys per KIND specifically so "every instance sharing a mesh collapses into
-- one draw call", and ModelBaker bakes colour into VERTICES rather than using MeshPart.Color
-- because whether a differing Color still batches is undocumented -- its header calls the
-- vertex route "a guarantee rather than a hope". Both are reasonable. Neither is measured.
--
-- If instancing holds, a fully-proxied 500-building city is a few dozen draw calls and the
-- merged-cell rung in LODCellCache is a nicety. If it does not, it is 500, and that rung is
-- the whole game. If MeshPart.Color ALSO batches, the cache key could drop colour entirely --
-- which would collapse the number of distinct kinds sharply and make the pressed 140-entry cap
-- far less likely to bind.
--
-- THE STAT
-- `Stats.FrameRateManager.Batches` is a real, scriptable draw-call counter. (`RenderBreakdown`
-- is NOT -- its Opaque figure counts triangles, which is the wrong metric for this game.)
--
-- HOW TO RUN IT -- and the trap
--   require(game.ServerScriptService.Tests.DrawCallProbe).run()
--
-- Studio's viewport MUST BE FOCUSED AND DRAWING. Every render stat freezes when Studio is in
-- the background: Batches, Indices and AverageFPS then hold their last values to the decimal
-- through any scene change, while Workspace.World.Primitives keeps updating and makes the
-- readings look live. Run this from the command bar with the viewport visible, not through an
-- automation bridge. `run()` checks for the frozen case and says so rather than reporting
-- a confident zero.

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Stats = game:GetService("Stats")

local DrawCallProbe = {}

local N = 200
local SETTLE_FRAMES = 15
local SAMPLES = 9

local function frm()
	return Stats.FrameRateManager
end

-- Median of several readings after letting the renderer settle. One sample is noisy and the
-- first few frames after a scene change still describe the old scene.
local function measure(): (number, number)
	for _ = 1, SETTLE_FRAMES do
		task.wait()
	end
	local b, i = {}, {}
	for _ = 1, SAMPLES do
		task.wait()
		table.insert(b, frm().Batches:GetValue())
		table.insert(i, frm().Indices:GetValue())
	end
	table.sort(b)
	table.sort(i)
	return b[math.ceil(SAMPLES / 2)], i[math.ceil(SAMPLES / 2)]
end

-- `source` is any part-built Model to bake. Defaults to a prop with enough parts to be worth
-- proxying; pass a real placed building for a truer answer.
function DrawCallProbe.run(source: Model?)
	local ModelBaker = require(ReplicatedStorage.Shared.ModelBaker)

	local src = source
		or ServerStorage.Templates.Asset.Props.Industrial.Power.IndustrialGenerator
	local bake = ModelBaker.collect(src, {})
	if not bake then
		warn("[DrawCallProbe] collect found nothing visible on " .. src:GetFullName())
		return
	end
	local template = ModelBaker.bakeMesh(bake, "DrawCallProbe")
	if not template then
		warn("[DrawCallProbe] bakeMesh declined (mesh-backed model?) -- pass a part-built one")
		return
	end

	local old = workspace:FindFirstChild("_DrawCallProbe")
	if old then
		old:Destroy()
	end
	local scene = Instance.new("Folder")
	scene.Name = "_DrawCallProbe"
	scene.Parent = workspace

	local cam = workspace.CurrentCamera
	if cam then
		cam.CFrame = CFrame.new(Vector3.new(0, 260, 460), Vector3.zero)
	end

	local function populate(count: number, varyColour: boolean)
		scene:ClearAllChildren()
		local rng = Random.new(3)
		for k = 1, count do
			local m = template:Clone()
			m.Anchored = true
			m.CanCollide, m.CanQuery, m.CanTouch = false, false, false
			m.CastShadow = false
			m.CFrame = CFrame.new(((k - 1) % 20 - 9.5) * 34, 0, ((k - 1) // 20 - 4.5) * 34)
			if varyColour then
				m.Color = Color3.fromHSV(rng:NextNumber(), 0.6, 0.9)
			end
			m.Parent = scene
		end
	end

	local b0, i0 = measure()
	populate(N, false)
	local b1, i1 = measure()
	populate(N, true)
	local b2 = measure()
	populate(N // 2, false)
	local b3 = measure()

	scene:Destroy()
	template:Destroy()

	-- The frozen-viewport check. If the index count did not move for 200 added meshes, nothing
	-- was re-rendered and every number below is the previous scene's.
	if i1 == i0 then
		warn("[DrawCallProbe] render stats did not move -- Studio's viewport was not drawing. "
			.. "Focus the viewport and run again from the command bar; results would be stale.")
		return
	end

	local perInstance = (b1 - b0) / N
	print(("[DrawCallProbe] baseline %d batches, %d indices"):format(b0, i0))
	print(("  A  %d identical clones      -> %+d batches  (%.3f per instance)")
		:format(N, b1 - b0, perInstance))
	print(("  B  %d clones, Color varied  -> %+d batches  (%.3f per instance)")
		:format(N, b2 - b0, (b2 - b0) / N))
	print(("  C  %d identical clones      -> %+d batches  (%.3f per instance)")
		:format(N // 2, b3 - b0, (b3 - b0) / (N // 2)))

	-- A flat batch count across A and C proves instancing; a halving disproves it.
	if perInstance < 0.25 then
		print("  => INSTANCING HOLDS: identical baked meshes share a draw call.")
	else
		print("  => NO INSTANCING: cost tracks instance count. The merged-cell rung in "
			.. "LODCellCache is the only thing that scales.")
	end
	if math.abs((b2 - b0) - (b1 - b0)) <= math.max(2, N * 0.02) then
		print("  => MeshPart.Color does NOT break batching. ModelBaker could drop vertex "
			.. "colours and key the cache on geometry alone, collapsing the kind count.")
	else
		print("  => MeshPart.Color DOES break batching. The vertex-colour bake is load-bearing; "
			.. "leave ModelBaker as it is.")
	end
end

return DrawCallProbe
