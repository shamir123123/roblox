--!strict
-- WindTurbineView -- spins the "Rotor" sub-model of every wind turbine (tag:
-- WindTurbineRotor, added by ServiceBuildingModel). Pure cosmetic client view --
-- the server never animates. Ghost previews spin too (tags survive Clone). Each
-- rotor re-anchors to its turbine's Root every frame, so the Move tool and the
-- placement drag never desync the blades from the tower.

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local TAG = "WindTurbineRotor"
local SPEED = 0.9 -- rad/s

local WindTurbineView = {}

type Entry = { root: BasePart, offset: CFrame, phase: number }
local _entries: { [Model]: Entry } = {}
local _conn: RBXScriptConnection? = nil
local _angle = 0

local function track(inst: Instance)
	if not inst:IsA("Model") then return end
	-- Replication may deliver the tag before the turbine's Root / PrimaryPart:
	-- wait briefly (bounded) instead of dropping the rotor.
	task.spawn(function()
		local deadline = os.clock() + 5
		local root: BasePart? = nil
		while os.clock() < deadline do
			local turbine = inst.Parent
			root = if turbine and turbine:IsA("Model") then turbine.PrimaryPart else nil
			if root or not inst.Parent then break end
			task.wait(0.1)
		end
		if not root then return end
		_entries[inst] = {
			root = root,
			offset = root.CFrame:ToObjectSpace(inst:GetPivot()),
			phase = math.random() * math.pi * 2,
		}
	end)
end

local function untrack(inst: Instance)
	if inst:IsA("Model") then _entries[inst] = nil end
end

function WindTurbineView.Start()
	for _, inst in CollectionService:GetTagged(TAG) do
		track(inst)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(track)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(untrack)

	_conn = RunService.Heartbeat:Connect(function(dt: number)
		_angle += dt * SPEED
		for model, e in _entries do
			if not model.Parent or not e.root.Parent then
				_entries[model] = nil
				continue
			end
			model:PivotTo(e.root.CFrame * e.offset * CFrame.Angles(0, 0, _angle + e.phase))
		end
	end)
end

function WindTurbineView.Stop()
	if _conn then
		_conn:Disconnect()
		_conn = nil
	end
	table.clear(_entries)
end

return WindTurbineView
