--!strict
-- NatureGizmo
-- Turns "this planted prop is selected" into a live transform gizmo on it. Two tools want
-- exactly that -- the Move tool, and the Nature tab's Precise mode, which drops the gizmo
-- on whatever you just placed -- and both drive the same RequestMoveNature payload. One
-- copy, because the payload is a contract with the server and a second copy of it would
-- drift the first time a field is added.
--
-- It used to DIM every other prop while one was selected. That is gone (2026-09-16): the
-- handles already say which prop is live, and fading the city around it made the thing you
-- were placing NEXT to impossible to judge. `focus()` survives as a no-op selection setter
-- so the Move tool -- which drags the prop itself and wants no handles -- still has a way to
-- say what it is holding.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EditorGizmos = require(script.Parent:WaitForChild("EditorGizmos"))
local MaterialCatalog = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MaterialCatalog"))

local NatureGizmo = {}

-- One owner string for both callers: there is only ever one prop gizmo on screen, so
-- whichever tool attached last holds it and either can hand it back.
local OWNER = "NatureProp"

local _model: Model? = nil
local _remote: RemoteEvent? = nil
local _onChanged: (() -> ())? = nil
-- While a prop is UNDER the handles it is still being edited, and it says so by going half
-- see-through. Solid means committed. Client-only (LocalTransparencyModifier), so nobody
-- else in the city watches a prop fade while you nudge it.
local EDIT_TRANSPARENCY = 0.5
local _faded: { [BasePart]: number } = {}

local function unfade()
	for p, orig in _faded do
		if p.Parent then p.LocalTransparencyModifier = orig end
	end
	table.clear(_faded)
end

local function fade(model: Model)
	unfade()
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			local part = d :: BasePart
			_faded[part] = part.LocalTransparencyModifier
			part.LocalTransparencyModifier = EDIT_TRANSPARENCY
		end
	end
end

local function live(): Model?
	local m = _model
	if m and m.Parent then return m end
	return nil
end

-- Every gizmo action becomes one RequestMoveNature item. The server re-validates bounds,
-- road/building clearance and the surface pick exactly as it does for a drag, so nothing
-- here needs to be trusted.
--
-- The transform goes across WHOLE: all three angles, and the absolute height. A gizmo with
-- three rings and a Y arrow that only ever persisted yaw and a ground-snapped Y is a gizmo
-- that lies -- you turn a prop on its side, let go, and the server stands it back up.
-- One RequestMoveNature item for `m` at its current transform, plus any look fields.
-- Public so a tool that edits many props at once (the Painter) can batch them into one call.
function NatureGizmo.itemFor(m: Model, extra: { [string]: any }?): { [string]: any }
	local cf = m:GetPivot()
	local rx, ry, rz = cf:ToOrientation()
	local item: { [string]: any } = {
		inst = m,
		pos = cf.Position,
		y = cf.Position.Y, -- absolute; the server owns the terrain and derives the offset
		yaw = ry,
		pitch = rx,
		roll = rz,
	}
	if extra then
		for k, v in extra do item[k] = v end
	end
	return item
end

local function sendFor(m: Model, remote: RemoteEvent, extra: { [string]: any }?)
	remote:FireServer({ NatureGizmo.itemFor(m, extra) })
end

local function send(extra: { [string]: any }?)
	local m = live()
	local remote = _remote
	if not (m and remote) then return end
	sendFor(m, remote, extra)
end

-- == Look (colour / material / collision) =====================================
-- Applied locally first so the swatch reads instantly, then sent; the server repeats it
-- authoritatively on the round trip and that is what persists.
local function paintLocal(m: Model, extra: { [string]: any })
	local col = extra.color
	local mat = if typeof(extra.material) == "number" then MaterialCatalog.get(extra.material) else nil
	local fade = if typeof(extra.transparency) == "number" then extra.transparency :: number else nil
	if not (col or mat or fade) then return end
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			if col then (d :: BasePart).Color = col :: Color3 end
			if mat then (d :: BasePart).Material = mat :: Enum.Material end
			if fade then
				-- The server keeps the template's own transparency as a floor; so does this.
				local base = d:GetAttribute("BaseTransparency")
				;(d :: BasePart).Transparency = math.max(if typeof(base) == "number" then base else 0, fade)
			end
		end
	end
end

local function apply(extra: { [string]: any })
	local m = live()
	if not m then return end
	paintLocal(m, extra)
	send(extra)
	if _onChanged then _onChanged() end
end

-- Repaint or re-surface a prop WITHOUT taking it under the handles. The selection tool edits
-- one prop straight from its action bar, and the payload has to be the same item the gizmo
-- sends or there would be two contracts with the server for the same thing.
NatureGizmo.paintLocal = paintLocal

function NatureGizmo.applyTo(model: Model, remote: RemoteEvent, extra: { [string]: any })
	if not model.Parent then return end
	paintLocal(model, extra)
	sendFor(model, remote, extra)
end

function NatureGizmo.setColor(c: Color3) apply({ color = c }) end
function NatureGizmo.setMaterial(idx: number) apply({ material = idx }) end
function NatureGizmo.setTransparency(t: number) apply({ transparency = t }) end
-- Collision is server-side physics: a client CanCollide write does not replicate, so this
-- one has no optimistic half at all.
function NatureGizmo.setCollide(on: boolean) apply({ collide = on == true }) end

function NatureGizmo.getMaterial(): number
	local m = live()
	local v = m and m:GetAttribute("NatureMaterial")
	return if typeof(v) == "number" then v else 0
end

function NatureGizmo.collides(): boolean
	local m = live()
	return not (m and m:GetAttribute("NatureNoCollide") == true)
end

-- == Selection ================================================================
-- Hold a prop without putting handles on it. The Move tool drags the prop itself, Cities:
-- Skylines style, so a cage of arrows over it is just in the way.
function NatureGizmo.focus(model: Model)
	_model = model
	_remote = nil
end

-- Re-send the master's transform after something outside the gizmo moved it (a drag, a
-- right-drag turn, a height key). Same one payload, same server validation.
function NatureGizmo.pushTransform()
	send()
end

function NatureGizmo.attach(model: Model, remote: RemoteEvent)
	_model = model
	_remote = remote
	fade(model)
	EditorGizmos.claim(OWNER, {
		getSelected = live,
		-- The gizmo only needs a non-nil id to know something is selected; out here the
		-- instance reference IS the identity, and the server checks it is one of ours.
		getSelectedId = function(): number? return 1 end,
		-- Open gate: NaturePlaceService rejects anything out of bounds or over a road.
		fitsPivot = function() return true end,
		sendCmd = function(payload: { [string]: any })
			if payload.action == "transform" then
				send()
			elseif payload.action == "setScale" then
				send({ scale = payload.scale })
			elseif payload.action == "setSize" then
				-- One-sided resize: per-axis factors relative to the size before the drag.
				send({ stretch = payload.stretch })
			end
		end,
	})
	-- All-in-one: move arrows, rotate rings and resize cubes together.
	EditorGizmos.setMode("Transform")
	if _onChanged then _onChanged() end
end

function NatureGizmo.detach()
	_model = nil
	_remote = nil
	unfade()
	EditorGizmos.release(OWNER)
	if _onChanged then _onChanged() end
end

-- The panel redraws its swatches off this, so it never has to poll for a selection change.
function NatureGizmo.setChangedListener(fn: (() -> ())?)
	_onChanged = fn
end

function NatureGizmo.current(): Model?
	return live()
end

-- "The handles want this click."
function NatureGizmo.isBusy(): boolean
	return live() ~= nil and EditorGizmos.getOwner() == OWNER and EditorGizmos.isHovering()
end

-- The prop under the handles, as a RequestPlaceNature item. This is what PLACE stamps:
-- the prop being edited is the MASTER, and every press drops a solid copy of it while the
-- master itself stays translucent under the handles, ready to be moved and stamped again.
function NatureGizmo.editState(): { [string]: any }?
	local m = live()
	if not m then return nil end
	local key = m:GetAttribute("NatureKey")
	if typeof(key) ~= "string" then return nil end
	local pv = m:GetPivot()
	local rx, ry, rz = pv:ToOrientation()
	local col = m:GetAttribute("NatureColor")
	local mat = m:GetAttribute("NatureMaterial")
	local stretch = m:GetAttribute("NatureStretch")
	local fade = m:GetAttribute("NatureTransparency")
	return {
		key = key,
		pos = pv.Position,
		y = pv.Position.Y,
		yaw = ry,
		pitch = rx,
		roll = rz,
		scale = tonumber(m:GetAttribute("NatureScale")) or 1,
		color = if typeof(col) == "number" then col else nil,
		material = if typeof(mat) == "number" then mat else nil,
		collide = if m:GetAttribute("NatureNoCollide") == true then false else nil,
		stretch = if typeof(stretch) == "Vector3" then stretch else nil,
		transparency = if typeof(fade) == "number" then fade else nil,
	}
end

-- The master is a real server prop (that is how it got here), so discarding it is a remove
-- request like any other. Exiting precise mode must not leave the half-transparent thing
-- you were still deciding about standing in the city.
function NatureGizmo.discard(remove: RemoteEvent)
	local m = live()
	NatureGizmo.detach()
	if m then remove:FireServer({ m }) end
end

return NatureGizmo
