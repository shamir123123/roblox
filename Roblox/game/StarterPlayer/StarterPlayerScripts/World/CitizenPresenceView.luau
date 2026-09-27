--!strict
-- CitizenPresenceView (client)
-- Renders server-authoritative outdoor background presence, currently children playing
-- near their homes during daytime. Adults at home/work and pupils at school are indoors
-- and intentionally absent from this feed. Models are pooled and updated by diff so churn
-- stays low, capped for performance, and live in a LOCAL workspace folder (nothing here
-- is replicated). People in transit are NOT rendered here -- they're already shown as
-- walkers / cars.

local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local CitizenModel = require(ReplicatedStorage.City.CitizenModel)

local CitizenPresenceView = {}

local POLL_INTERVAL   = 1.2
local WANDER_INTERVAL = 1 / 30
local MAX_PEOPLE      = 120
local GOLDEN        = 2.39996  -- golden angle: spreads people evenly around a building
-- Ambient wander: idle people stroll to a random spot near their building, pause, repeat,
-- so they go for walks / play in the yard instead of standing frozen. Kids roam a touch
-- faster (playing). Purely cosmetic + client-side.
local WANDER_ADULT_RADIUS = 8
local WANDER_KID_RADIUS   = 7
local WANDER_ADULT_SPEED  = 3
local WANDER_KID_SPEED    = 4.5

type Person = {
	model: Model, g: string, k: string,
	anchor: Vector3, pos: Vector3, target: Vector3, pauseUntil: number,
	radius: number, speed: number,
}

local _net: any = nil
local _folder: Folder? = nil
local _models: { [string]: Person } = {}
local _started = false
local _accum = POLL_INTERVAL
local _wanderAccum = 0
local _busy = false
local _conn: RBXScriptConnection? = nil

local function ensureFolder(): Folder
	local existing = _folder
	if existing and existing.Parent then return existing end
	local f = Instance.new("Folder")
	f.Name = "CitizenPresence"
	f.Parent = Workspace
	_folder = f
	return f
end

-- Deterministic starting spot for person `i` around a play anchor, so each person keeps
-- the same spot between polls (no teleport jitter) before the wander stepper takes over.
local function standCF(base: Vector3, i: number): CFrame
	local ang = i * GOLDEN
	local r = 3 + (i % 3) * 1.6
	local off = Vector3.new(math.cos(ang) * r, 0, math.sin(ang) * r)
	return CFrame.new(base + off) * CFrame.Angles(0, ang + math.pi, 0)
end

local function clearAll()
	for _, e in _models do e.model:Destroy() end
	table.clear(_models)
end

local function rebuild(entries: { any })
	type Want = { pos: Vector3, g: string, k: string, idx: number, seed: number }
	local desired: { [string]: Want } = {}
	local count = 0
	for _, e in entries do
		if typeof(e) ~= "table" or typeof(e.pos) ~= "Vector3" or typeof(e.people) ~= "table" then continue end
		local bid = tostring(e.id)
		for i, p in e.people do
			if count >= MAX_PEOPLE then break end
			local g = if p.g == "F" then "F" else "M"
			local k = if p.k == "kid" then "kid" else "adult"
			desired[bid .. "#" .. i] = {
				pos = e.pos,
				g = g,
				k = k,
				idx = i,
				seed = math.max(1, math.floor(tonumber(p.p) or i)),
			}
			count += 1
		end
		if count >= MAX_PEOPLE then break end
	end

	-- Drop models no longer wanted, or whose appearance changed.
	for key, m in _models do
		local d = desired[key]
		if not d or d.g ~= m.g or d.k ~= m.k then
			m.model:Destroy()
			_models[key] = nil
		end
	end

	-- Add the new ones, seeded at a spread-out play spot; the wander stepper takes them from there.
	local folder = ensureFolder()
	for key, d in desired do
		if not _models[key] then
			local model = CitizenModel.build({ gender = d.g, kind = d.k, seed = d.seed })
			local cf = standCF(d.pos, d.idx)
			model:PivotTo(cf)
			model:SetAttribute("CitizenPid", d.seed)
			model.Parent = folder
			CollectionService:AddTag(model, "AdminCitizen")
			local kid = d.k == "kid"
			_models[key] = {
				model = model, g = d.g, k = d.k,
				anchor = d.pos, pos = cf.Position, target = cf.Position, pauseUntil = 0,
				radius = if kid then WANDER_KID_RADIUS else WANDER_ADULT_RADIUS,
				speed = if kid then WANDER_KID_SPEED else WANDER_ADULT_SPEED,
			}
		end
	end
end

local function gameSpeed(): number
	return math.clamp(tonumber(Workspace:GetAttribute("GameSpeed")) or 1, 0, 3)
end

-- Move each visible background person a little: stroll toward a nearby target, pause on
-- arrival, then pick a new one within their wander radius of the play anchor. Stays on the ground plane
-- (anchor Y). Scaled by GameSpeed so it freezes/fast-forwards with the rest of the sim.
local function stepWander(dt: number)
	if dt <= 0 then return end
	local now = os.clock()
	for key, e in _models do
		if not e.model.Parent then _models[key] = nil; continue end
		if now < e.pauseUntil then continue end
		local to = e.target - e.pos
		local d = to.Magnitude
		if d < 0.4 then
			e.pauseUntil = now + 1.5 + math.random() * 4
			local ang = math.random() * math.pi * 2
			local rad = math.random() * e.radius
			e.target = e.anchor + Vector3.new(math.cos(ang) * rad, 0, math.sin(ang) * rad)
		else
			local dir = to / d
			local stepLen = math.min(e.speed * dt, d)
			e.pos = e.pos + dir * stepLen
			e.model:PivotTo(CFrame.lookAt(e.pos, e.pos + dir))
		end
	end
end

local function poll()
	if _busy or not _net then return end
	local camera = Workspace.CurrentCamera
	local camCF = if camera then camera.CFrame else nil
	if not camCF then return end
	_busy = true
	task.spawn(function()
		local ok, entries = pcall(function() return _net.RequestPresenceNear:InvokeServer(camCF) end)
		if ok and typeof(entries) == "table" then
			local ok2, err = pcall(rebuild, entries)
			if not ok2 then warn("[CitizenPresenceView] rebuild failed: " .. tostring(err)) end
		end
		_busy = false
	end)
end

function CitizenPresenceView.Start()
	if _started then return end
	_started = true
	local okNet, net = pcall(function() return require(ReplicatedStorage:WaitForChild("Networker")) end)
	_net = if okNet then net else nil
	_conn = RunService.Heartbeat:Connect(function(dt: number)
		local frameDt = math.min(dt, 0.1)
		_wanderAccum += frameDt
		if _wanderAccum >= WANDER_INTERVAL then
			local stepDt = _wanderAccum
			_wanderAccum = 0
			stepWander(stepDt * gameSpeed())
		end
		_accum += dt
		if _accum >= POLL_INTERVAL then _accum = 0; poll() end
	end)
end

function CitizenPresenceView.Stop()
	if _conn then _conn:Disconnect(); _conn = nil end
	clearAll()
	_wanderAccum = 0
	_started = false
end

return CitizenPresenceView
