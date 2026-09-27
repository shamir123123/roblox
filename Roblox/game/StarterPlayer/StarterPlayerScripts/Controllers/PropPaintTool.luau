--!strict
-- PropPaintTool
-- The bottom bar's PAINTER and PICKER, for props already standing in the city.
--
--   Painter  click (or click-and-sweep) a prop to paint it with the colour and opacity in
--            the colour menu, which opens beside the button. Right-click a prop to SAMPLE
--            its colour instead -- an eyedropper, so matching an existing wall is one click.
--   Picker   click a prop to pick it UP: its exact twin (look, stretch, tilt) goes on the
--            cursor with its shelf open, ready to place again. The tool then steps aside,
--            because the next click belongs to placement.
--
-- Painting goes through RequestMoveNature like every other look change, so the server
-- validates it exactly as it does the selection bar's colour dropdown. A sweep is batched:
-- one call per FLUSH, never one per prop, or the server's per-player cooldown drops most of
-- a stroke on the floor.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage:WaitForChild("Networker"))
local uiFolder = script.Parent.Parent:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local coreFolder = script.Parent.Parent:WaitForChild("Core")
local CursorRay = require(coreFolder:WaitForChild("CursorRay"))
local SoundFX = require(coreFolder:WaitForChild("SoundFX"))

local NatureGizmo = require(script.Parent:WaitForChild("NatureGizmo"))
local NatureSelection = require(script.Parent:WaitForChild("NatureSelection"))
local ColorPanel = require(script.Parent:WaitForChild("ColorPanel"))

local PropPaintTool = {}

export type Mode = "Painter" | "Picker"

local HOVER_HZ = 12        -- the ray test is O(props); a tenth of a second is plenty for hover
local FLUSH_EVERY = 0.12   -- clears NaturePlaceService's 0.08 s per-player cooldown
local MAX_PER_CALL = 64    -- NaturePlaceService.MAX_PER_CALL

local _mode: Mode? = nil
local _anchor: GuiObject? = nil
local _listener: ((mode: Mode?) -> ())? = nil
local _color = Color3.fromRGB(232, 236, 240)
local _fade = 0
local _hover: Model? = nil
local _highlight: Highlight? = nil
local _painting = false
local _stroke: { [Model]: boolean } = {}
local _queue: { { [string]: any } } = {}
local _lastHover = 0
local _lastFlush = 0
local _conns: { RBXScriptConnection } = {}

local function natureFolder(): Instance?
	return CursorRay.cityFolder("Nature")
end

local function propUnderCursor(): Model?
	local f = natureFolder()
	return if f then CursorRay.modelUnderRay(f) else nil
end

local function showHover(m: Model?)
	_hover = m
	local h = _highlight
	if not m then
		if h then h.Adornee = nil end
		return
	end
	if not h then
		local nh = Instance.new("Highlight")
		nh.Name = "PropPaintHover"
		nh.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		nh.FillTransparency = 0.8
		nh.OutlineTransparency = 0
		nh.Parent = Workspace
		_highlight = nh
		h = nh
	end
	local hl = h :: Highlight
	hl.OutlineColor = if _mode == "Painter" then Theme.Color.Accent else Color3.new(1, 1, 1)
	hl.FillColor = if _mode == "Painter" then _color else Color3.new(1, 1, 1)
	hl.Adornee = m
end

local function flush()
	if #_queue == 0 then return end
	local batch = table.move(_queue, 1, math.min(#_queue, MAX_PER_CALL), 1, {})
	table.clear(_queue)
	Net.RequestMoveNature:FireServer(batch)
	_lastFlush = os.clock()
end

local function paint(m: Model)
	if _stroke[m] then return end
	_stroke[m] = true
	local look = { color = _color, transparency = _fade }
	-- Painted locally at once so the sweep reads live; the server repeats it and persists it.
	NatureGizmo.paintLocal(m, look)
	table.insert(_queue, NatureGizmo.itemFor(m, look))
	SoundFX.play("Click")
end

local function sample(m: Model)
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			_color = (d :: BasePart).Color
			local fade = m:GetAttribute("NatureTransparency")
			_fade = if typeof(fade) == "number" then fade else 0
			break
		end
	end
	-- Re-open so the menu shows what was just sampled.
	PropPaintTool.openColour()
	SoundFX.play("Click")
end

function PropPaintTool.openColour()
	ColorPanel.open(function(c: Color3) _color = c end, {
		anchor = _anchor,
		transparency = _fade,
		onTransparency = function(t: number) _fade = t end,
	})
end

local function stop()
	for _, c in _conns do c:Disconnect() end
	table.clear(_conns)
	_painting = false
	table.clear(_stroke)
	flush()
	showHover(nil)
end

local function start()
	table.insert(_conns, RunService.RenderStepped:Connect(function()
		local now = os.clock()
		if now - _lastHover >= 1 / HOVER_HZ then
			_lastHover = now
			local m = propUnderCursor()
			if m ~= _hover then showHover(m) end
			if _painting and m then paint(m) end
		end
		if #_queue > 0 and now - _lastFlush >= FLUSH_EVERY then flush() end
	end))
	table.insert(_conns, UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then return end
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 then
			local m = propUnderCursor()
			if _mode == "Picker" then
				if m and NatureSelection.pickUp(m) then PropPaintTool.setMode(nil) end
				return
			end
			_painting = true
			table.clear(_stroke)
			if m then paint(m) end
		elseif t == Enum.UserInputType.MouseButton2 and _mode == "Painter" then
			local m = propUnderCursor()
			if m then sample(m) end
		end
	end))
	table.insert(_conns, UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			_painting = false
			table.clear(_stroke)
		end
	end))
end

-- nil turns the tool off. `anchor` is the button that opened it; the colour menu hangs off it.
function PropPaintTool.setMode(mode: Mode?, anchor: GuiObject?)
	if mode == _mode then return end
	local was = _mode
	_mode = mode
	_anchor = anchor or _anchor
	stop()
	if was == "Painter" then ColorPanel.close() end
	if mode then
		start()
		if mode == "Painter" then PropPaintTool.openColour() end
	end
	if _listener then _listener(mode) end
end

function PropPaintTool.getMode(): Mode? return _mode end

function PropPaintTool.setStateListener(fn: ((mode: Mode?) -> ())?)
	_listener = fn
end

function PropPaintTool.Cleanup()
	PropPaintTool.setMode(nil)
	if _highlight then _highlight:Destroy(); _highlight = nil end
end

return PropPaintTool
