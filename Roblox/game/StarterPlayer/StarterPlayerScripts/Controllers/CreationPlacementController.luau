--!strict
-- CreationPlacementController
-- Places a saved Creation Editor design into the live city. The ghost rides the cursor
-- and places free wherever it fits (R rotates 45 degrees); the server re-validates with
-- the same box check and re-grounds Y itself.
--
-- Unlike its siblings, this tool's geometry is not in a catalog the client can read: a
-- creation lives in a DataStore blob. So the blob is fetched ONCE per creation and
-- cached, and GhostPlacement.build -- which runs on RenderStepped and must never yield --
-- simply returns nil until it arrives. GhostPlacement already parks the ghost on nil, so
-- the tool is silently inert for the frame or two the round trip takes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Net = require(ReplicatedStorage:WaitForChild("Networker"))
local CreationBuilder = require(ReplicatedStorage:WaitForChild("Editor"):WaitForChild("CreationBuilder"))
local Settings = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("Settings"))
local GhostPlacement = require(script.Parent:WaitForChild("GhostPlacement"))

local CreationPlacementController = {}

type Cached = {
	blob: any,
	name: string,
	price: number,
	footprint: Vector3,
}

local _inited = false
local _bound = false
local _renderConn: RBXScriptConnection? = nil
local _inputConn: RBXScriptConnection? = nil
local _cache: { [string]: Cached } = {}
-- Told whenever the tool arms or disarms ITSELF -- pressing Back is the case that matters.
-- Without this the owning panel never learns, so its chip stays lit and its caption still
-- says "pick one below, then click to place" while nothing is listening to the cursor.
-- Mirrors NaturePlacementController.setStateListener.
local _listener: ((enabled: boolean) -> ())? = nil
local _fetching: { [string]: boolean } = {}
-- Which creations came from the player's own library rather than the approved store.
-- Only decides which remote serves the blob first; the SERVER decides what is placeable.
local _isOwn: { [string]: boolean } = {}

-- The server keys assets by GetFullName under ServerStorage, which the client cannot see.
-- Match on the leaf name against ReplicatedStorage.Props instead; anything that misses
-- falls through to CreationBuilder's placeholder, so the silhouette is still honest.
local function clientResolve(key: string): Model?
	local leaf = string.match(key, "([^%.]+)$")
	if not leaf then return nil end
	local props = ReplicatedStorage:FindFirstChild("Props")
	local model = props and props:FindFirstChild(leaf)
	return if model and model:IsA("Model") then model :: Model else nil
end

-- Pull one creation's geometry and remember it. Yields, so it is never called from the
-- render loop -- only from setCreation, when the player picks something.
-- Two remotes can serve a blob and each refuses what the other allows: RequestEditorData
-- serves only the caller's OWN creations, RequestReviewQueue only APPROVED ones. A
-- creation can be either or both, so try the likely one and fall back rather than track a
-- state the server is the authority on anyway.
local function fetchBlob(id: string): any
	local order = if _isOwn[id]
		then { Net.RequestEditorData, Net.RequestReviewQueue }
		else { Net.RequestReviewQueue, Net.RequestEditorData }
	for _, remote in order do
		local ok, res = pcall(function()
			return remote:InvokeServer({ action = "blob", id = id })
		end)
		if ok and typeof(res) == "table" and res.ok and typeof(res.blob) == "table" then
			return res
		end
	end
	return nil
end

local function fetch(id: string)
	if _cache[id] or _fetching[id] then return end
	_fetching[id] = true
	task.spawn(function()
		local res = fetchBlob(id)
		_fetching[id] = nil
		if not res then return end

		-- Build once here to measure it; the footprint is not declared anywhere, it IS the
		-- geometry. Cheaper than rebuilding to measure on every frame of the fit test.
		local probe = CreationBuilder.build(res.blob, clientResolve)
		if not probe then return end
		local _, size = probe:GetBoundingBox()
		probe:Destroy()

		_cache[id] = {
			blob = res.blob,
			name = if typeof(res.name) == "string" then res.name else "Creation",
			price = tonumber((res.blob :: any).price) or 0,
			footprint = size,
		}
	end)
end

local _placer = GhostPlacement.new({
	folderName = "CreationPlacement",
	-- A creation is decoration and does not reserve ground: a statue beside a shop is the
	-- point of it. Without this the whole-bounding-box overlap veto refuses every spot
	-- inside the city, and the tool fails silently -- the click never reaches the server,
	-- so nothing can even tell the player why.
	noOverlapCheck = true,
	build = function(key: string): Model?
		local entry = _cache[key]
		if not entry then return nil end -- blob still in flight; GhostPlacement parks the ghost
		local model = CreationBuilder.build(entry.blob, clientResolve)
		if not model then return nil end
		model.Name = "GhostCreation"
		return model
	end,
	footprint = function(key: string): Vector3?
		local entry = _cache[key]
		return if entry then entry.footprint else nil
	end,
	cost = function(key: string): number?
		local entry = _cache[key]
		-- A free creation returns nil rather than 0 so the cost HUD stays hidden.
		if not entry or entry.price <= 0 then return nil end
		return entry.price
	end,
	place = function(key: string, pivot: CFrame)
		Net.RequestPlaceService:FireServer("Creation", key, pivot)
	end,
})

-- == Public ====================================================================
-- Everything this player can place: their OWN creations, plus every creation a curator has
-- approved into the store. Yields (two round trips). Own work leads, because it is what
-- they came looking for; the store follows, newest first as the server sorted it.
--
-- Rows are normalised to one shape -- { id, name, cat, price, ownerName, own } -- because
-- the two sources do not agree: a library row carries a price and a part count, a store
-- row carries an author. A store row's price lives inside its blob and is not known until
-- the ghost loads it, which is exactly when the cost readout needs it anyway.
function CreationPlacementController.fetchList(): { any }
	local out: { any } = {}
	local seen: { [string]: boolean } = {}

	local okMine, mine = pcall(function()
		return Net.RequestEditorData:InvokeServer({ action = "list" })
	end)
	if okMine and typeof(mine) == "table" and mine.ok and typeof(mine.creations) == "table" then
		for _, e in mine.creations do
			local id = tostring(e.id)
			if not seen[id] then
				seen[id] = true
				_isOwn[id] = true
				table.insert(out, {
					id = id, name = tostring(e.name), cat = e.cat,
					price = tonumber(e.price) or 0, ownerName = nil, own = true,
				})
			end
		end
	end

	local okStore, store = pcall(function()
		return Net.RequestReviewQueue:InvokeServer({ action = "store" })
	end)
	if okStore and typeof(store) == "table" and store.ok and typeof(store.published) == "table" then
		for _, e in store.published do
			local id = tostring(e.bpId)
			-- Your own approved work is already listed; do not shelve it twice.
			if not seen[id] then
				seen[id] = true
				table.insert(out, {
					id = id, name = tostring(e.name), cat = e.cat,
					price = 0, ownerName = e.ownerName, own = false,
				})
			end
		end
	end

	return out
end

function CreationPlacementController.setCreation(id: string)
	if typeof(id) ~= "string" or id == "" then return end
	_placer:setKey(id)
	fetch(id)
end

function CreationPlacementController.getCreation(): string
	return _placer:getKey()
end

-- A creation the player has deleted or re-saved must not keep serving a stale ghost.
function CreationPlacementController.forget(id: string)
	_cache[id] = nil
	_isOwn[id] = nil
end

function CreationPlacementController.setStateListener(fn: ((enabled: boolean) -> ())?)
	_listener = fn
end

function CreationPlacementController.setEnabled(enabled: boolean)
	if enabled == _placer:isEnabled() then return end
	_placer:setEnabled(enabled)
	local fn = _listener
	if fn then fn(enabled) end
end

function CreationPlacementController.isEnabled(): boolean
	return _placer:isEnabled()
end

-- == Lifecycle =================================================================
function CreationPlacementController.Init()
	if _inited then return end
	_inited = true
end

function CreationPlacementController.Bind()
	if _bound then return end
	_bound = true
	_renderConn = RunService.RenderStepped:Connect(function()
		if not _placer:isEnabled() then return end
		_placer:update()
	end)
	_inputConn = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if not _placer:isEnabled() or gameProcessed then return end
		if Settings.pressed("Back", input) then
			CreationPlacementController.setEnabled(false)
			return
		end
		if Settings.pressed("RotateObject", input) then
			_placer:rotate(45)
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		_placer:tryPlace()
	end)
end

function CreationPlacementController.Start() end

function CreationPlacementController.Cleanup()
	if _renderConn then _renderConn:Disconnect(); _renderConn = nil end
	if _inputConn then _inputConn:Disconnect(); _inputConn = nil end
	_placer:destroy()
	table.clear(_cache)
	table.clear(_fetching)
	table.clear(_isOwn)
	_bound = false
	_inited = false
end

return CreationPlacementController
