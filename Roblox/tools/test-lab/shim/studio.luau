-- A headless Roblox stand-in for running City District's server modules under Lune.
-- Fake Instances (Lua tables), fake services, a virtual clock with a task scheduler, and
-- require() over the syncback'd source tree. Only what the code under test touches.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local CFrame = require("./cframe")

local Vector3 = roblox.Vector3
local Studio = {}

-- == typeof ===================================================================
local rawTypeof = typeof
local function typeof_(v: any): string
	if type(v) == "table" then
		local m = getmetatable(v)
		if m and type(m) == "table" and m.__type then return m.__type end
	end
	return rawTypeof(v)
end

-- == Signals ==================================================================
local Signal = {}
Signal.__index = Signal
local signalMt = { __index = Signal, __type = "RBXScriptSignal" }
function Signal.new() return setmetatable({ _conns = {} }, signalMt) end
function Signal:Connect(fn)
	local conn = { Connected = true, _fn = fn }
	local sig = self
	function conn:Disconnect()
		conn.Connected = false
		local i = table.find(sig._conns, conn)
		if i then table.remove(sig._conns, i) end
	end
	setmetatable(conn, { __type = "RBXScriptConnection" })
	table.insert(self._conns, conn)
	return conn
end
function Signal:Once(fn)
	local c
	c = self:Connect(function(...) c:Disconnect(); fn(...) end)
	return c
end
function Signal:Fire(...)
	for _, c in table.clone(self._conns) do
		if c.Connected then
			local ok, err = pcall(c._fn, ...)
			if not ok then Studio.errors[#Studio.errors + 1] = tostring(err) end
		end
	end
end
function Signal:Wait() return coroutine.yield("signal", self) end
Studio.Signal = Signal
Studio.errors = {}
Studio.warnings = {}

-- == Virtual clock + task scheduler ===========================================
local clock = { now = 1000 }
local timers: { { at: number, seq: number, fn: any, args: any } } = {}
local deferred: { { fn: any, args: any } } = {}
local seq = 0

local function resume(co, ...)
	local ok, a, b = coroutine.resume(co, ...)
	if not ok then
		Studio.errors[#Studio.errors + 1] = tostring(a) .. "\n" .. debug.traceback(co)
		return
	end
	if coroutine.status(co) == "suspended" then
		if a == "wait" then
			seq += 1
			table.insert(timers, { at = clock.now + (b or 0), seq = seq, fn = co, args = {} })
		elseif a == "signal" then
			local c
			c = b:Connect(function(...) c:Disconnect(); resume(co, ...) end)
		end
	end
end

local function run(fn, ...)
	if type(fn) == "thread" then resume(fn, ...) return fn end
	local co = coroutine.create(fn)
	resume(co, ...)
	return co
end

local task = {}
function task.spawn(fn, ...) return run(fn, ...) end
function task.defer(fn, ...)
	table.insert(deferred, { fn = fn, args = table.pack(...) })
	return fn
end
function task.delay(t, fn, ...)
	seq += 1
	table.insert(timers, { at = clock.now + (t or 0), seq = seq, fn = fn, args = table.pack(...) })
	return fn
end
function task.wait(t)
	local start = clock.now
	if not coroutine.isyieldable() then
		error("task.wait outside a coroutine in the shim")
	end
	coroutine.yield("wait", t or 0)
	return clock.now - start
end
function task.cancel(thing)
	for i = #timers, 1, -1 do if timers[i].fn == thing then table.remove(timers, i) end end
end
function task.synchronize() end
function task.desynchronize() end

local function flushDeferred()
	local guard = 0
	while #deferred > 0 and guard < 10000 do
		guard += 1
		local d = table.remove(deferred, 1)
		run(d.fn, table.unpack(d.args, 1, d.args.n))
	end
end

local function runTimers()
	table.sort(timers, function(a, b) if a.at == b.at then return a.seq < b.seq end return a.at < b.at end)
	while #timers > 0 and timers[1].at <= clock.now do
		local t = table.remove(timers, 1)
		run(t.fn, table.unpack(t.args, 1, t.args.n or 0))
		flushDeferred()
		table.sort(timers, function(a, b) if a.at == b.at then return a.seq < b.seq end return a.at < b.at end)
	end
end

-- == Instances ================================================================
local Instance = {}
local instMt = {}
local ISA: { [string]: { string } } = {
	Part = { "BasePart", "PVInstance" }, MeshPart = { "BasePart", "PVInstance" }, WedgePart = { "BasePart", "PVInstance" },
	UnionOperation = { "BasePart", "PVInstance" }, TrussPart = { "BasePart", "PVInstance" }, Seat = { "BasePart", "PVInstance" },
	Model = { "PVInstance" }, Workspace = { "Model", "PVInstance" },
	ModuleScript = { "LuaSourceContainer" }, Script = { "BaseScript", "LuaSourceContainer" }, LocalScript = { "Script", "BaseScript", "LuaSourceContainer" },
	RemoteEvent = {}, UnreliableRemoteEvent = { "BaseRemoteEvent" }, RemoteFunction = {}, BindableEvent = {}, BindableFunction = {},
	Weld = { "JointInstance" }, WeldConstraint = {}, Motor6D = { "JointInstance" }, Attachment = {},
	SurfaceAppearance = {}, Decal = { "FaceInstance" }, Texture = { "Decal", "FaceInstance" },
	Folder = {}, Configuration = {}, Humanoid = {}, BillboardGui = { "LayerCollector" },
}

local function newInstance(className: string, name: string?)
	local self = setmetatable({
		_class = className, _name = name or className, _parent = nil, _children = {},
		_attrs = {}, _tags = {}, _props = {}, _signals = {}, _attrSignals = {}, _propSignals = {},
		_destroyed = false,
	}, instMt)
	if className == "Part" or className == "MeshPart" or ISA[className] and table.find(ISA[className], "BasePart") then
		self._props.CFrame = CFrame.new()
		self._props.Size = Vector3.new(4, 1, 2)
		self._props.Anchored = false
		self._props.Transparency = 0
		self._props.LocalTransparencyModifier = 0
		self._props.CanCollide = true
		self._props.CanQuery = true
	end
	return self
end

local function sig(self, key)
	local s = self._signals[key]
	if not s then s = Signal.new(); self._signals[key] = s end
	return s
end

local methods: { [string]: any } = {}

function methods.IsA(self, class)
	if self._class == class or class == "Instance" then return true end
	local list = ISA[self._class]
	return list ~= nil and table.find(list, class) ~= nil
end
function methods.GetChildren(self) return table.clone(self._children) end
function methods.GetDescendants(self)
	local out = {}
	local function walk(i) for _, c in i._children do table.insert(out, c); walk(c) end end
	walk(self)
	return out
end
function methods.FindFirstChild(self, name, recursive)
	for _, c in self._children do if c._name == name then return c end end
	if recursive then
		for _, c in self._children do
			local f = methods.FindFirstChild(c, name, true)
			if f then return f end
		end
	end
	return nil
end
function methods.WaitForChild(self, name, _timeout)
	local c = methods.FindFirstChild(self, name)
	if not c then Studio.warnings[#Studio.warnings + 1] = "WaitForChild miss: " .. self._name .. "." .. tostring(name) end
	return c
end
function methods.FindFirstChildOfClass(self, class)
	for _, c in self._children do if c._class == class then return c end end
	return nil
end
function methods.FindFirstChildWhichIsA(self, class, recursive)
	for _, c in self._children do if methods.IsA(c, class) then return c end end
	if recursive then
		for _, c in self._children do
			local f = methods.FindFirstChildWhichIsA(c, class, true)
			if f then return f end
		end
	end
	return nil
end
function methods.FindFirstAncestorOfClass(self, class)
	local p = self._parent
	while p do if p._class == class then return p end p = p._parent end
	return nil
end
function methods.FindFirstAncestorWhichIsA(self, class)
	local p = self._parent
	while p do if methods.IsA(p, class) then return p end p = p._parent end
	return nil
end
function methods.FindFirstAncestor(self, name)
	local p = self._parent
	while p do if p._name == name then return p end p = p._parent end
	return nil
end
function methods.IsDescendantOf(self, other)
	local p = self._parent
	while p do if p == other then return true end p = p._parent end
	return false
end
function methods.IsAncestorOf(self, other) return methods.IsDescendantOf(other, self) end
function methods.GetFullName(self)
	local parts = {}
	local i = self
	while i and i._class ~= "DataModel" do table.insert(parts, 1, i._name) i = i._parent end
	return table.concat(parts, ".")
end
function methods.Destroy(self)
	if self._destroyed then return end
	self._destroyed = true
	sig(self, "Destroying"):Fire()
	for _, c in table.clone(self._children) do methods.Destroy(c) end
	self.Parent = nil
end
function methods.ClearAllChildren(self)
	for _, c in table.clone(self._children) do methods.Destroy(c) end
end
function methods.Clone(self)
	local copy = newInstance(self._class, self._name)
	for k, v in self._props do copy._props[k] = v end
	for k, v in self._attrs do copy._attrs[k] = v end
	for k in self._tags do copy._tags[k] = true end
	local map = { [self] = copy }
	for _, c in self._children do
		local cc = methods.Clone(c)
		map[c] = cc
		cc.Parent = copy
	end
	if self._props.PrimaryPart and map[self._props.PrimaryPart] then copy._props.PrimaryPart = map[self._props.PrimaryPart] end
	return copy
end
function methods.GetAttribute(self, k) return self._attrs[k] end
function methods.GetAttributes(self) return table.clone(self._attrs) end
function methods.SetAttribute(self, k, v)
	if self._attrs[k] == v then return end
	self._attrs[k] = v
	local s = self._attrSignals[k]
	if s then s:Fire() end
	sig(self, "AttributeChanged"):Fire(k)
end
function methods.GetAttributeChangedSignal(self, k)
	local s = self._attrSignals[k]
	if not s then s = Signal.new(); self._attrSignals[k] = s end
	return s
end
function methods.GetPropertyChangedSignal(self, k)
	local s = self._propSignals[k]
	if not s then s = Signal.new(); self._propSignals[k] = s end
	return s
end
function methods.AddTag(self, tag) Studio.CollectionService:AddTag(self, tag) end
function methods.RemoveTag(self, tag) Studio.CollectionService:RemoveTag(self, tag) end
function methods.HasTag(self, tag) return self._tags[tag] == true end
function methods.GetTags(self) local t = {} for k in self._tags do table.insert(t, k) end return t end

-- PVInstance
local function partsOf(self)
	local out = {}
	if methods.IsA(self, "BasePart") then table.insert(out, self) end
	for _, d in methods.GetDescendants(self) do if methods.IsA(d, "BasePart") then table.insert(out, d) end end
	return out
end
function methods.GetPivot(self)
	if methods.IsA(self, "BasePart") then return self._props.CFrame end
	-- Roblox: a model with a PrimaryPart pivots on it (WorldPivot only counts without one),
	-- so moving the PrimaryPart moves the pivot.
	local pp = self._props.PrimaryPart
	if pp then return pp._props.CFrame end
	if self._props.WorldPivot then return self._props.WorldPivot end
	local parts = partsOf(self)
	if #parts > 0 then return parts[1]._props.CFrame end
	return CFrame.new()
end
function methods.PivotTo(self, cf)
	if methods.IsA(self, "BasePart") then self.CFrame = cf return end
	local old = methods.GetPivot(self)
	local delta = cf * old:Inverse()
	for _, p in partsOf(self) do p.CFrame = delta * p._props.CFrame end
	if self._props.WorldPivot then self._props.WorldPivot = cf end
end
methods.SetPrimaryPartCFrame = methods.PivotTo
function methods.GetBoundingBox(self)
	local parts = partsOf(self)
	if #parts == 0 then return methods.GetPivot(self), Vector3.zero end
	local minX, minY, minZ, maxX, maxY, maxZ = math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge
	for _, p in parts do
		local c, s = p._props.CFrame.Position, p._props.Size / 2
		minX, minY, minZ = math.min(minX, c.X - s.X), math.min(minY, c.Y - s.Y), math.min(minZ, c.Z - s.Z)
		maxX, maxY, maxZ = math.max(maxX, c.X + s.X), math.max(maxY, c.Y + s.Y), math.max(maxZ, c.Z + s.Z)
	end
	local pivot = methods.GetPivot(self)
	return CFrame.new((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2) * pivot.Rotation,
		Vector3.new(maxX - minX, maxY - minY, maxZ - minZ)
end
function methods.GetExtentsSize(self) local _, s = methods.GetBoundingBox(self) return s end
function methods.GetScale(self) return self._props.__scale or 1 end
function methods.ScaleTo(self, scale)
	local cur = self._props.__scale or 1
	local k = scale / cur
	local pivot = methods.GetPivot(self)
	for _, p in partsOf(self) do
		local rel = pivot:Inverse() * p._props.CFrame
		p.CFrame = pivot * (rel.Rotation + rel.Position * k)
		p.Size = p._props.Size * k
	end
	self._props.__scale = scale
end
function methods.GetMass() return 1 end

-- Remotes / bindables
function methods.FireClient(self, player, ...) Studio.onRemote(self, "client", player, ...) end
function methods.FireAllClients(self, ...) Studio.onRemote(self, "all", nil, ...) end
function methods.FireServer(self, ...) sig(self, "OnServerEvent"):Fire(Studio.localPlayer, ...) end
function methods.Fire(self, ...) sig(self, "Event"):Fire(...) end
function methods.Invoke(self, ...) local f = self._props.OnInvoke return f and f(...) end
function methods.InvokeServer(self, ...) local f = self._props.OnServerInvoke return f and f(Studio.localPlayer, ...) end

local SIGNAL_NAMES = {
	ChildAdded = true, ChildRemoved = true, DescendantAdded = true, DescendantRemoving = true,
	AncestryChanged = true, Destroying = true, AttributeChanged = true, Changed = true,
	OnServerEvent = true, OnClientEvent = true, Event = true, Touched = true, TouchEnded = true,
}

instMt.__type = "Instance"
instMt.__index = function(self, k)
	if k == "Name" then return self._name end
	if k == "Parent" then return self._parent end
	if k == "ClassName" then return self._class end
	if k == "Position" and self._props.CFrame then return self._props.CFrame.Position end
	if k == "Orientation" and self._props.CFrame then return Vector3.zero end
	local m = methods[k]
	if m then return m end
	if SIGNAL_NAMES[k] then return sig(self, k) end
	local v = self._props[k]
	if v ~= nil then return v end
	return methods.FindFirstChild(self, k)
end
instMt.__newindex = function(self, k, v)
	if k == "Parent" then
		local old = self._parent
		if old == v then return end
		if old then
			local i = table.find(old._children, self)
			if i then table.remove(old._children, i) end
			sig(old, "ChildRemoved"):Fire(self)
		end
		self._parent = v
		if v then
			table.insert(v._children, self)
			sig(v, "ChildAdded"):Fire(self)
			local a = v
			while a do
				if a._signals.DescendantAdded then a._signals.DescendantAdded:Fire(self) end
				a = a._parent
			end
		end
		sig(self, "AncestryChanged"):Fire(self, v)
		return
	end
	if k == "Name" then self._name = v return end
	if k == "Position" and self._props.CFrame then
		self._props.CFrame = CFrame.new(v) * self._props.CFrame.Rotation
		return
	end
	self._props[k] = v
	local s = self._propSignals[k]
	if s then s:Fire() end
end
instMt.__tostring = function(self) return self._name end

Instance.new = function(className: string, parent: any?)
	local i = newInstance(className)
	if parent then i.Parent = parent end
	return i
end
Studio.Instance = Instance
Studio.newInstance = newInstance

-- == Services =================================================================
local game = newInstance("DataModel", "Game")
Studio.game = game
local services: { [string]: any } = {}
local function service(name: string, class: string?)
	local s = newInstance(class or name, name)
	s.Parent = game
	services[name] = s
	return s
end
for _, n in { "ReplicatedStorage", "ServerScriptService", "ServerStorage", "ReplicatedFirst", "StarterPlayer",
	"StarterGui", "StarterPack", "Lighting", "SoundService", "Teams", "Chat", "TestService" } do
	service(n)
end
local workspace = service("Workspace")
workspace._props.Gravity = 196.2
workspace._props.StreamingEnabled = false
workspace._props.CurrentCamera = nil
function methods.Raycast() return nil end
function methods.GetPartBoundsInRadius() return {} end
function methods.GetPartBoundsInBox() return {} end
function methods.GetPartsInPart() return {} end
function methods.GetServerTimeNow() return clock.now end
services.Lighting._props.ClockTime = 12

local RunService = service("RunService")
RunService._props.Heartbeat = Signal.new()
RunService._props.Stepped = Signal.new()
RunService._props.RenderStepped = Signal.new()
RunService._props.PostSimulation = RunService._props.Heartbeat
RunService._props.PreSimulation = RunService._props.Stepped
function methods.IsServer() return true end
function methods.IsClient() return false end
function methods.IsStudio() return true end
function methods.IsRunning() return true end
function methods.IsRunMode() return false end
function methods.BindToRenderStep() end
function methods.UnbindFromRenderStep() end

local Players = service("Players")
Players._props.PlayerAdded = Signal.new()
Players._props.PlayerRemoving = Signal.new()
local playerList = {}
function methods.GetPlayers(self) if self == Players then return table.clone(playerList) end return {} end
function methods.GetPlayerByUserId(_, id) for _, p in playerList do if p.UserId == id then return p end end return nil end
function Studio.addPlayer(name: string, userId: number)
	local p = newInstance("Player", name)
	p._props.UserId = userId
	p._props.DisplayName = name
	p._props.Character = nil
	p.Parent = Players
	table.insert(playerList, p)
	Players._props.PlayerAdded:Fire(p)
	return p
end
function Studio.removePlayer(p)
	local i = table.find(playerList, p)
	if i then table.remove(playerList, i) end
	Players._props.PlayerRemoving:Fire(p)
	p.Parent = nil
end

local CollectionService = service("CollectionService")
Studio.CollectionService = CollectionService
local tagged: { [string]: { [any]: boolean } } = {}
local tagSignals: { [string]: { added: any, removed: any } } = {}
local function tagSig(tag)
	local s = tagSignals[tag]
	if not s then s = { added = Signal.new(), removed = Signal.new() }; tagSignals[tag] = s end
	return s
end
function methods.AddTag(self, inst, tag)
	if self ~= CollectionService then tag = inst; inst = self end
	if inst._tags[tag] then return end
	inst._tags[tag] = true
	tagged[tag] = tagged[tag] or setmetatable({}, { __mode = "k" })
	tagged[tag][inst] = true
	tagSig(tag).added:Fire(inst)
end
function methods.RemoveTag(self, inst, tag)
	if self ~= CollectionService then tag = inst; inst = self end
	if not inst._tags[tag] then return end
	inst._tags[tag] = nil
	if tagged[tag] then tagged[tag][inst] = nil end
	tagSig(tag).removed:Fire(inst)
end
function methods.HasTag(self, inst, tag)
	if self ~= CollectionService then return self._tags[inst] == true end
	return inst._tags[tag] == true
end
function methods.GetTagged(_, tag)
	local out = {}
	for inst in tagged[tag] or {} do if not inst._destroyed then table.insert(out, inst) end end
	return out
end
function methods.GetInstanceAddedSignal(_, tag) return tagSig(tag).added end
function methods.GetInstanceRemovedSignal(_, tag) return tagSig(tag).removed end

local HttpService = service("HttpService")
local serde = require("@lune/serde")
function methods.JSONEncode(_, v) return serde.encode("json", v) end
function methods.JSONDecode(_, s) return serde.decode("json", s) end
function methods.GenerateGUID() seq += 1 return ("GUID-%08d"):format(seq) end
service("DataStoreService")
service("MessagingService")
service("TeleportService")
service("BadgeService")
service("MarketplaceService")
service("AnalyticsService")
service("PhysicsService")
service("TweenService")
service("PathfindingService")
service("Debris")
service("TextService")
service("LocalizationService")
service("UserInputService")
service("GuiService")
service("ContextActionService")
service("SocialService")
service("MemoryStoreService")
service("ServerStorageService")
function methods.AddItem() end
function methods.GetService(_, name)
	local s = services[name]
	if not s then s = service(name) end
	return s
end
-- TweenService stand-in: a tween lands on its goal the moment it is played (no animation).
function methods.Create(self, target, _info, goal)
	if self._class ~= "TweenService" and self._name ~= "TweenService" then error("Create is TweenService-only") end
	local completed = Signal.new()
	local tw = { Completed = completed, PlaybackState = "Begin" }
	function tw.Play()
		for k, v in goal or {} do target[k] = v end
		tw.PlaybackState = "Completed"
		task.defer(function() completed:Fire("Completed") end)
	end
	function tw.Cancel() end
	function tw.Pause() end
	function tw.Destroy() end
	tw.play = tw.Play
	return setmetatable(tw, { __index = function(_, k) error("tween: no member " .. tostring(k)) end })
end
methods.FindService = methods.GetService
game._props.PlaceId = 0
game._props.GameId = 0
game._props.JobId = "shim"
function methods.BindToClose() end

-- == Globals ==================================================================
local RandomMt = {}
RandomMt.__index = RandomMt
RandomMt.__type = "Random"
local function imul(a: number, b: number): number
	local ah, al = bit32.rshift(a, 16), bit32.band(a, 0xFFFF)
	local bh, bl = bit32.rshift(b, 16), bit32.band(b, 0xFFFF)
	return bit32.band(al * bl + bit32.lshift(bit32.band(ah * bl + al * bh, 0xFFFF), 16), 0xFFFFFFFF)
end
-- Mulberry32: decorrelates neighbouring seeds the way Roblox's PCG-based Random does, which
-- code seeding Random.new(pid * 16 + salt) relies on.
local function lcg(self)
	self._s = (self._s + 0x6D2B79F5) % 4294967296
	local t = self._s
	t = imul(bit32.bxor(t, bit32.rshift(t, 15)), bit32.bor(t, 1))
	t = bit32.bxor(t, (t + imul(bit32.bxor(t, bit32.rshift(t, 7)), bit32.bor(t, 61))) % 4294967296)
	return bit32.bxor(t, bit32.rshift(t, 14)) / 4294967296
end
function RandomMt:NextNumber(a, b)
	local r = lcg(self)
	if a == nil then return r end
	return a + (b - a) * r
end
function RandomMt:NextInteger(a, b) return a + math.floor(lcg(self) * (b - a + 1)) end
function RandomMt:NextUnitVector()
	local z = self:NextNumber(-1, 1); local t = self:NextNumber(0, 2 * math.pi); local r = math.sqrt(1 - z * z)
	return Vector3.new(r * math.cos(t), r * math.sin(t), z)
end
function RandomMt:Shuffle(t)
	for i = #t, 2, -1 do local j = self:NextInteger(1, i); t[i], t[j] = t[j], t[i] end
end
function RandomMt:Clone() return setmetatable({ _s = self._s }, RandomMt) end
local Random = { new = function(seed) return setmetatable({ _s = math.abs(math.floor(seed or 12345)) % 4294967296 }, RandomMt) end }

local RaycastParams = { new = function() return { FilterDescendantsInstances = {}, FilterType = nil, IgnoreWater = false, CollisionGroup = "Default" } end }
local OverlapParams = RaycastParams

local fakeOs = setmetatable({
	clock = function() return clock.now end,
	time = function() return math.floor(clock.now) end,
}, { __index = os })

Studio.clock = clock
local envBase = {
	game = game, workspace = workspace, Workspace = workspace, script = nil,
	Vector3 = Vector3, CFrame = CFrame, Color3 = roblox.Color3, Vector2 = roblox.Vector2, UDim = roblox.UDim,
	UDim2 = roblox.UDim2, BrickColor = roblox.BrickColor, NumberRange = roblox.NumberRange,
	NumberSequence = roblox.NumberSequence, ColorSequence = roblox.ColorSequence, Enum = roblox.Enum,
	Ray = roblox.Ray, Rect = roblox.Rect, Region3 = roblox.Region3, Font = roblox.Font,
	NumberSequenceKeypoint = roblox.NumberSequenceKeypoint, ColorSequenceKeypoint = roblox.ColorSequenceKeypoint,
	Vector3int16 = roblox.Vector3int16, PhysicalProperties = roblox.PhysicalProperties,
	Instance = Instance, Random = Random, RaycastParams = RaycastParams, OverlapParams = OverlapParams,
	TweenInfo = { new = function(time, style, dir, repeats, reverses, delayTime)
		return { Time = time or 1, EasingStyle = style, EasingDirection = dir, RepeatCount = repeats or 0,
			Reverses = reverses or false, DelayTime = delayTime or 0 }
	end },
	task = task, os = fakeOs, typeof = typeof_,
	tick = function() return clock.now end, time = function() return clock.now end,
	wait = task.wait, delay = task.delay, spawn = task.spawn,
	warn = function(...)
		local parts = table.pack(...)
		for i = 1, parts.n do parts[i] = tostring(parts[i]) end
		Studio.warnings[#Studio.warnings + 1] = table.concat(parts, " ", 1, parts.n)
	end,
	print = function(...) if Studio.echo then print(...) end end,
	shared = {}, _G = {},
	DateTime = { now = function() return { UnixTimestamp = math.floor(clock.now), UnixTimestampMillis = math.floor(clock.now * 1000) } end },
	debug = debug, buffer = buffer, bit32 = bit32, utf8 = utf8, coroutine = coroutine, string = string,
	table = table, math = math, vector = vector,
	pairs = pairs, ipairs = ipairs, next = next, select = select, type = type, tostring = tostring,
	tonumber = tonumber, pcall = pcall, xpcall = xpcall, error = error, assert = assert,
	setmetatable = setmetatable, getmetatable = getmetatable, rawget = rawget, rawset = rawset,
	rawequal = rawequal, rawlen = rawlen, unpack = table.unpack, newproxy = newproxy, gcinfo = gcinfo,
	collectgarbage = function() return 0 end,
}
Studio.echo = false
Studio.onRemote = function() end

-- == Source tree + require ====================================================
-- Mount a syncback'd directory under `parent`. X.luau -> ModuleScript X, X.server.luau ->
-- Script, X.client.luau -> LocalScript; a directory with init*.luau is that script itself.
local function scriptClassFor(file: string): (string?, string)
	if file:match("%.server%.luau$") then return "Script", (file:gsub("%.server%.luau$", "")) end
	if file:match("%.client%.luau$") then return "LocalScript", (file:gsub("%.client%.luau$", "")) end
	if file:match("%.luau$") then return "ModuleScript", (file:gsub("%.luau$", "")) end
	return nil, file
end

function Studio.mount(dir: string, parent: any)
	for _, entry in fs.readDir(dir) do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			local initFile, initClass
			for _, f in { "init.luau", "init.server.luau", "init.client.luau" } do
				if fs.isFile(path .. "/" .. f) then initFile = f; initClass = scriptClassFor(f) end
			end
			local node = newInstance(initClass or "Folder", entry)
			if initFile then node._props.__source = path .. "/" .. initFile; node._props.__code = fs.readFile(path .. "/" .. initFile) end
			node.Parent = parent
			Studio.mount(path, node)
		elseif not entry:match("^init") then
			local class, name = scriptClassFor(entry)
			if class then
				local existing = methods.FindFirstChild(parent, name)
				local node = existing or newInstance(class, name)
				node._props.__source = path
				node._props.__code = fs.readFile(path)
				if not existing then node.Parent = parent end
			end
		end
	end
end

-- Test-only: append `extra` to a module's source just before its final `return <Name>`, so a
-- test can reach internal tables (never shipped; the source file on disk is untouched).
function Studio.expose(fullName: string, extra: string)
	local node = Studio.find(fullName)
	assert(node, "expose: no " .. fullName)
	local code = node._props.__code
	local name = node._name
	local tail = "return " .. name
	local at = code:find("\n" .. tail .. "%s*$")
	assert(at, "expose: no trailing `return " .. name .. "` in " .. fullName)
	node._props.__code = code:sub(1, at) .. extra .. "\n" .. code:sub(at + 1)
end

-- Replace one script's source with another file (the patched version).
function Studio.overlay(fullName: string, file: string)
	local node = game
	for part in fullName:gmatch("[^%.]+") do
		node = methods.FindFirstChild(node, part)
		assert(node, "overlay: no " .. part .. " in " .. fullName)
	end
	node._props.__source = file
	node._props.__code = fs.readFile(file)
end

local cache: { [any]: any } = {}
local loading: { [any]: boolean } = {}
local requireFn
local function envFor(scriptInst)
	local env = setmetatable({ script = scriptInst, require = requireFn }, { __index = envBase })
	return env
end
requireFn = function(target)
	if type(target) == "string" then return require(target) end
	assert(target and target._props, "require: not a module instance")
	if cache[target] ~= nil then return cache[target] end
	assert(not loading[target], "require cycle at " .. methods.GetFullName(target))
	local src = target._props.__source
	assert(src, "require: no source for " .. methods.GetFullName(target))
	loading[target] = true
	local fn = luau.load(target._props.__code, { debugName = methods.GetFullName(target), environment = envFor(target), injectGlobals = false, codegenEnabled = true })
	local result = fn()
	loading[target] = nil
	cache[target] = result
	return result
end
Studio.require = requireFn
function Studio.resetRequireCache() table.clear(cache) end
function Studio.find(fullName: string)
	local node = game
	for part in fullName:gmatch("[^%.]+") do
		node = methods.FindFirstChild(node, part)
		if not node then return nil end
	end
	return node
end
function Studio.stub(fullName: string, value: any)
	local node = Studio.find(fullName)
	assert(node, "stub: no " .. fullName)
	cache[node] = value
end
function Studio.env(scriptInst) return envFor(scriptInst) end
-- Load a module fresh (uncached) with extra globals -- specs see describe/it/expect this way.
function Studio.loadWith(target, extra: { [string]: any })
	local env = envFor(target)
	for k, v in extra do rawset(env, k, v) end
	local fn = luau.load(target._props.__code, { debugName = methods.GetFullName(target), environment = env, injectGlobals = false })
	return fn()
end
function Studio.allDescendants() return methods.GetDescendants(game) end

-- == Stepping =================================================================
function Studio.step(dt: number)
	clock.now += dt
	runTimers()
	RunService._props.Stepped:Fire(clock.now, dt)
	RunService._props.Heartbeat:Fire(dt)
	flushDeferred()
end
function Studio.run(seconds: number, dt: number?)
	local step = dt or (1 / 30)
	local n = math.floor(seconds / step + 0.5)
	for _ = 1, n do Studio.step(step) end
end
Studio.task = task
Studio.flush = function() flushDeferred() runTimers() end
Studio.Vector3 = Vector3
Studio.CFrame = CFrame
Studio.typeof = typeof_
Studio.Random = Random

return Studio
