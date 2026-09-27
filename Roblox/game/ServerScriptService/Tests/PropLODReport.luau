--!nonstrict
-- PropLODReport -- shows the LOD ladder every street prop will ACTUALLY ride.
--
-- PropCatalog.spec asserts the ladder is correct; this prints what it is, rung by rung, so a
-- new template can be judged before it ships rather than after someone notices a bench turning
-- into a grey card across the river. Run it from the Studio command bar, Edit mode is fine:
--
--   print(require(game.ServerScriptService.Tests.PropLODReport)())
--   print(require(game.ServerScriptService.Tests.PropLODReport)("Bench"))  -- one kind only
--   print(require(game.ServerScriptService.Tests.PropLODReport)(nil, "ACUnits")) -- another set
--
-- SETS below lists every catalog-plus-templates pair this can report on. Adding a prop family
-- is one line there and nothing else: the ladder logic is identical because the ladder does
-- not care what the model is OF, only how many parts it keeps and whether it can be merged.
--
-- The rungs, and the distance AssetLODView swaps each one in:
--   NEAR      <250    the real Parts, everything drawn
--   MID       250-500 the real Parts, sub-1.5-stud parts hidden (DETAIL_STUDS)
--   FAR       500-1000  one baked MeshPart  -- ModelBaker.bakeMesh
--   DISTANT   1000-2000 a coarser baked MeshPart -- ModelBaker.coarsen, only if it earns it
--   IMPOSTOR  >2000   a flat camera-facing quad
--
-- "earns it" is the exact test LODProxyCache.bakeFor applies: coarsening must at least HALVE
-- keptParts, or the bake is not worth spending and DISTANT falls back to the FAR mesh. That
-- fallback is not a bug -- see the note in PropCatalog.spec -- but it should be a decision,
-- not a surprise, which is why this prints it either way.

local MIN_FEATURE = 0.6 -- ModelBaker.MIN_FEATURE_STUDS: under this, a part is not in the bake
local DETAIL_STUDS = 1.5 -- AssetLODView.DETAIL_STUDS: under this, a part is hidden from MID out
local STUD_MM = 500 -- RoadConstants.WORLD_SCALE 0.5 => 1 m = 2 studs

-- Each entry is a catalog module sitting beside its template Models, exposing `order` and
-- `get` -- the layout both sets already use.
local SETS = {
	Props = { path = { "ReplicatedStorage", "Props" }, catalog = "PropCatalog" },
	ACUnits = {
		path = { "ServerStorage", "Templates", "Asset", "Props", "BuildingProps", "ACUnits" },
		catalog = "ACUnitCatalog",
	},
}

local function resolve(path: { string }): Instance
	local node: Instance = game:GetService(path[1])
	for i = 2, #path do
		node = node:FindFirstChild(path[i])
			or error(("PropLODReport: no %q under the path"):format(path[i]))
	end
	return node
end

return function(filterKind: string?, setName: string?): string
	local RS = game:GetService("ReplicatedStorage")
	local set = SETS[setName or "Props"]
	if not set then
		local names = {}
		for k in SETS do table.insert(names, k) end
		table.sort(names)
		return ("PropLODReport: no set named %q (have: %s)")
			:format(tostring(setName), table.concat(names, ", "))
	end

	-- Report against a CLONE. require() caches a ModuleScript per instance for the whole
	-- Studio session, so a catalog edited this session would otherwise be read stale and the
	-- report would describe the previous set of props with total confidence.
	local fresh = resolve(set.path):Clone()
	fresh.Name = "_PropsLODReport"
	fresh.Parent = RS

	local out = {}
	local ok, err = pcall(function()
		local PropCatalog = require(fresh[set.catalog])
		local ModelBaker = require(RS.Shared.ModelBaker)

		local nFar, nDistant, nImpostor, nChecked = 0, 0, 0, 0

		table.insert(out, "prop                  parts  bake  FAR   coarse  DISTANT  worst rung")
		table.insert(out, "--------------------- -----  ----  ----  ------  -------  ----------")

		for _, key in PropCatalog.order do
			local entry = PropCatalog.get(key)
			if filterKind and entry.kind ~= filterKind then continue end

			local model = fresh:FindFirstChild(key)
			if not (model and model:IsA("Model")) then
				table.insert(out, ("%-21s  NO TEMPLATE MODEL"):format(key))
				continue
			end
			nChecked += 1

			-- Which parts the two size gates take out, by name, so a silhouette part that is
			-- accidentally too small is identifiable rather than merely counted.
			local dropped, hidden = {}, {}
			local total = 0
			for _, d in model:GetDescendants() do
				if d:IsA("BasePart") then
					total += 1
					local longest = math.max(d.Size.X, d.Size.Y, d.Size.Z)
					if longest < MIN_FEATURE then
						table.insert(dropped, ("%s(%.0fmm)"):format(d.Name, longest * STUD_MM))
					elseif longest < DETAIL_STUDS then
						table.insert(hidden, ("%s(%.0fmm)"):format(d.Name, longest * STUD_MM))
					end
				end
			end

			local bake = ModelBaker.collect(model, {})
			if not bake then
				table.insert(out, ("%-21s  COLLECT RETURNED NIL (nothing visible to draw)"):format(key))
				continue
			end

			local mesh = ModelBaker.bakeMesh(bake, "report_" .. key)
			local farOk = mesh ~= nil
			if mesh then mesh:Destroy() end

			local coarse = ModelBaker.coarsen(bake)
			-- LODProxyCache.bakeFor's `worthIt`, mirrored exactly.
			local earned = coarse.keptParts * 2 <= bake.keptParts
			local coarseMesh = nil
			if earned then
				coarseMesh = ModelBaker.bakeMesh(coarse, "reportc_" .. key)
				if coarseMesh then coarseMesh:Destroy() end
			end

			local worst
			if bake.meshBacked and not bake.foliage then
				worst = "IMPOSTOR@1000 -- MESH-BACKED, no mesh rungs at all"
				nImpostor += 1
			elseif not farOk then
				worst = "IMPOSTOR@1000 -- bakeMesh refused"
				nImpostor += 1
			elseif earned and coarseMesh ~= nil then
				worst = "coarse mesh, full ladder"
				nDistant += 1
				nFar += 1
			else
				worst = "FAR mesh reused at DISTANT"
				nFar += 1
			end

			table.insert(out, ("%-21s %5d  %4d  %-4s  %6d  %-7s  %s"):format(
				key, total, bake.keptParts, farOk and "yes" or "NO",
				coarse.keptParts, earned and "earned" or "reuse", worst))

			if #dropped > 0 then
				table.insert(out, ("      dropped from bake (<%dmm): %s"):format(
					MIN_FEATURE * STUD_MM, table.concat(dropped, ", ")))
			end
			if #hidden > 0 then
				table.insert(out, ("      hidden from MID out (<%dmm): %s"):format(
					DETAIL_STUDS * STUD_MM, table.concat(hidden, ", ")))
			end
		end

		table.insert(out, ("\n=== %d props | %d reach a FAR mesh | %d earn the DISTANT coarse rung | %d fall to an impostor ===")
			:format(nChecked, nFar, nDistant, nImpostor))
	end)

	fresh:Destroy()
	if not ok then return "PropLODReport failed: " .. tostring(err) end
	return table.concat(out, "\n")
end
