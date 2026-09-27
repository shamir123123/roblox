--!strict
-- Client game settings: one store for option values and keybinds. Settings
-- UI writes here; consumers (audio, camera, lighting, HUD scale) read and
-- subscribe. Persisted per player by Core.SettingsClient.

local UserInputService = game:GetService("UserInputService")

-- An action id from the ACTIONS registry below.
export type BindAction = string

-- A bind is up to three inputs held TOGETHER: { W }, { A, S }, { CONTROL, Z }.
-- An input is a keyboard KeyCode or a mouse button. An empty bind is "not set".
export type BindInput = Enum.KeyCode | Enum.UserInputType
export type Bind = { BindInput }
export type ActionDef = {
	id: string,
	label: string,
	tab: string, -- Keyboard | Mouse | Misc (settings page sub-tab)
	section: string, -- heading inside the tab
	default: Bind,
	-- Required actions can be rebound but never cleared: the game is unplayable
	-- without them, so their row shows no clear button at all.
	required: boolean?,
}

local MAX_BIND_INPUTS = 3
local EMPTY_BIND: Bind = table.freeze({})

-- The mouse buttons a bind may use, with their display names. Roblox only
-- reports left/right/middle to scripts: the thumb buttons (X1/X2) never arrive
-- as input at all, so they cannot be bound.
local MOUSE_INPUTS: { [Enum.UserInputType]: string } = table.freeze({
	[Enum.UserInputType.MouseButton1] = "LEFT MOUSE",
	[Enum.UserInputType.MouseButton2] = "RIGHT MOUSE",
	[Enum.UserInputType.MouseButton3] = "MIDDLE MOUSE",
})

-- Left/right modifier pairs are ONE logical key: a bind holding CONTROL is
-- satisfied by either Control key, which is what "CONTROL + Z" means to a player.
local MODIFIER_PAIR: { [Enum.KeyCode]: Enum.KeyCode } = table.freeze({
	[Enum.KeyCode.RightControl] = Enum.KeyCode.LeftControl,
	[Enum.KeyCode.RightShift] = Enum.KeyCode.LeftShift,
	[Enum.KeyCode.RightAlt] = Enum.KeyCode.LeftAlt,
})
local MODIFIERS: { [Enum.KeyCode]: boolean } = table.freeze({
	[Enum.KeyCode.LeftControl] = true,
	[Enum.KeyCode.LeftShift] = true,
	[Enum.KeyCode.LeftAlt] = true,
})

-- Keycap text. Anything absent falls back to the upper-cased enum name.
local KEY_LABEL: { [Enum.KeyCode]: string } = table.freeze({
	[Enum.KeyCode.LeftControl] = "CONTROL",
	[Enum.KeyCode.LeftShift] = "SHIFT",
	[Enum.KeyCode.LeftAlt] = "ALT",
	[Enum.KeyCode.Escape] = "ESC",
	[Enum.KeyCode.Return] = "ENTER",
	[Enum.KeyCode.KeypadEnter] = "NUM ENTER",
	[Enum.KeyCode.Space] = "SPACE",
	[Enum.KeyCode.Backspace] = "BACKSPACE",
	[Enum.KeyCode.Delete] = "DELETE",
	[Enum.KeyCode.PageUp] = "PAGE UP",
	[Enum.KeyCode.PageDown] = "PAGE DOWN",
	[Enum.KeyCode.LeftBracket] = "[",
	[Enum.KeyCode.RightBracket] = "]",
	[Enum.KeyCode.One] = "1",
	[Enum.KeyCode.Two] = "2",
	[Enum.KeyCode.Three] = "3",
	[Enum.KeyCode.Four] = "4",
	[Enum.KeyCode.Five] = "5",
	[Enum.KeyCode.Six] = "6",
})

local DEFAULT_VALUES: { [string]: any } = table.freeze({
	masterVolume = 1,
	musicVolume = 0.8,
	sfxVolume = 1,
	ambienceVolume = 1,
	uiScale = 1,
	-- Size the player dragged the build dock to, via its top-left corner grip.
	dockScale = 1,
	shadowQuality = "Soft", -- Off | Hard | Soft
	bloom = true,
	bloomIntensity = 0.6,
	sunRays = false,
	sunRayIntensity = 0.15,
	depthOfField = false,
	colorGrade = true,
	-- Color grading (shipped place look; seeded from the live effect at boot).
	ccSaturation = 0.15,
	ccContrast = 0.1,
	ccBrightness = 0.01,
	-- Tint is per-channel now: 1,1,1 is neutral, pulling a channel down colours
	-- the whole grade. Maps straight onto ColorCorrectionEffect.TintColor.
	tintR = 1,
	tintG = 0.98,
	tintB = 0.94,
	-- Bumped whenever the shipped look changes. A save stamped with an older
	-- version drops its look keys, so the new place look is not overwritten by
	-- numbers the player never chose (see SettingsClient.applySaved).
	lookVersion = 2,
	exposure = 0,
	haze = true,
	hazeDensity = 0.2,
	waterReflections = 0.45,
	waterTransparency = 0.75, -- high: the seabed IS the water's colour (TerrainMesh.surfaceColor)
	renderDistance = 1, -- fog/draw distance multiplier
	waterWaves = true, -- animated terrain water surface
	graphicsPreset = "High", -- Low | Medium | High | Ultra | Custom
	tooltips = true,
	notifications = true,
	uiTransparency = 0, -- extra see-through on every glass panel
	units = "Metric", -- Metric | Imperial | Studs, for distances shown in the HUD
	language = "en", -- UI.Locale code: en | zh | hi | es | fr | ar | bn
	showFps = "Off", -- Off | Simple | Advanced
	-- Kit.Frost blur panes behind glass panels. Needs graphics quality high
	-- enough for glass refraction, so the presets below leave it off on Low/Med.
	frostedGlass = true,
	autosave = true,
	autosaveInterval = 10, -- minutes
	-- Read SERVER-side by PlaceAccessService off the saved record, not by any client.
	-- Defaults closed: your city is yours when you are not in it.
	friendsOffline = false,
	dayNight = true,
	startPaused = false,
	edgeScroll = false,
	timeFormat = 24, -- 12 or 24

	camSpeed = 1,
	camRotSpeed = 1,
	camZoomSpeed = 1,
	mouseSensitivity = 1,
})

-- Every rebindable action in the game, in display order. This table is the only
-- place a default key lives -- consumers ask for the bind by id, never for a key.
-- Two actions may share a key across sections on purpose (RIGHT MOUSE both
-- cancels a tool and orbits the camera); a clash inside one section is warned.
local K = Enum.KeyCode
local M = Enum.UserInputType
local ACTIONS: { ActionDef } = table.freeze({
	{ id = "Back", label = "Back / cancel", tab = "Keyboard", section = "Navigation", default = { K.Escape }, required = true },
	-- Deliberately a chord. A bare key would take the whole HUD away on a mistype, and the
	-- way back is this same shortcut -- which is hard to find once nothing is on screen.
	{ id = "ToggleUI", label = "Hide all UI", tab = "Keyboard", section = "Navigation", default = { K.LeftAlt, K.H } },

	{ id = "CamForward", label = "Move camera forward", tab = "Keyboard", section = "Camera", default = { K.W }, required = true },
	{ id = "CamBack", label = "Move camera backward", tab = "Keyboard", section = "Camera", default = { K.S }, required = true },
	{ id = "CamLeft", label = "Move camera left", tab = "Keyboard", section = "Camera", default = { K.A }, required = true },
	{ id = "CamRight", label = "Move camera right", tab = "Keyboard", section = "Camera", default = { K.D }, required = true },
	{ id = "CamRotateLeft", label = "Rotate camera left", tab = "Keyboard", section = "Camera", default = { K.Q } },
	{ id = "CamRotateRight", label = "Rotate camera right", tab = "Keyboard", section = "Camera", default = { K.E } },
	{ id = "CamRise", label = "Raise camera", tab = "Keyboard", section = "Camera", default = { K.R } },
	{ id = "CamSink", label = "Lower camera", tab = "Keyboard", section = "Camera", default = { K.F } },
	{ id = "CamFastMove", label = "Fast move (hold)", tab = "Keyboard", section = "Camera", default = { K.LeftShift } },
	{ id = "FocusCity", label = "Go to city centre", tab = "Keyboard", section = "Camera", default = { K.Home } },

	{ id = "Undo", label = "Undo", tab = "Keyboard", section = "Editing", default = { K.LeftControl, K.Z } },
	{ id = "Redo", label = "Redo", tab = "Keyboard", section = "Editing", default = { K.LeftControl, K.Y } },
	{ id = "Delete", label = "Delete selection", tab = "Keyboard", section = "Editing", default = { K.Delete } },
	{ id = "RotateObject", label = "Rotate object", tab = "Keyboard", section = "Editing", default = { K.R } },
	{ id = "PreciseModifier", label = "Precise / symmetric (hold)", tab = "Keyboard", section = "Editing", default = { K.LeftControl } },
	-- Stamps a copy of whatever is under the transform handles. NOT Return: pressing Enter
	-- focuses Roblox's chat bar, which marks the input game-processed, and every tool that
	-- respects gameProcessed (all of them) then never sees the key at all.
	{ id = "PlaceObject", label = "Place object", tab = "Keyboard", section = "Editing", default = { K.B } },

	-- Placed props are SELECTABLE (Controllers.NatureSelection): a click picks, SelectAdd
	-- adds, SelectAdd + SelectBox drags a capture box across the screen. Every one of these is
	-- a chord on purpose -- a bare key would fire in the middle of a tool's gesture, and the
	-- two holds double as "this click is a selection, not a placement" while a tool is up.
	{ id = "SelectAdd", label = "Add to selection (hold)", tab = "Keyboard", section = "Selection", default = { K.LeftControl } },
	{ id = "SelectBox", label = "Capture box (hold + drag)", tab = "Keyboard", section = "Selection", default = { K.LeftControl, K.LeftShift } },
	-- Copy and Cut both put the prop back on the cursor in the menu it came from; cut also
	-- takes the original down (refunded). No Paste action: the placement tool IS the paste.
	{ id = "Copy", label = "Copy - place it again", tab = "Keyboard", section = "Selection", default = { K.LeftControl, K.C } },
	{ id = "Cut", label = "Cut - pick it back up", tab = "Keyboard", section = "Selection", default = { K.LeftControl, K.X } },
	{ id = "CopyPrecise", label = "Copy into precise build", tab = "Keyboard", section = "Selection", default = { K.LeftControl, K.LeftShift, K.C } },
	{ id = "CutPrecise", label = "Cut into precise build", tab = "Keyboard", section = "Selection", default = { K.LeftControl, K.LeftShift, K.X } },
	{ id = "Group", label = "Group selection", tab = "Keyboard", section = "Selection", default = { K.LeftControl, K.G } },
	{ id = "Ungroup", label = "Ungroup selection", tab = "Keyboard", section = "Selection", default = { K.LeftControl, K.LeftShift, K.G } },

	{ id = "RoadRaise", label = "Raise elevation", tab = "Keyboard", section = "Roads", default = { K.PageUp } },
	{ id = "RoadLower", label = "Lower elevation", tab = "Keyboard", section = "Roads", default = { K.PageDown } },
	{ id = "RoadDeleteMode", label = "Toggle delete mode", tab = "Keyboard", section = "Roads", default = { K.Delete } },
	{ id = "FreeAngle", label = "Free angle (hold)", tab = "Keyboard", section = "Roads", default = { K.LeftAlt } },
	{ id = "LaneConnector", label = "Toggle lane connectors", tab = "Keyboard", section = "Roads", default = { K.L } },
	{ id = "NodeTool", label = "Toggle node tool", tab = "Keyboard", section = "Roads", default = { K.N } },
	{ id = "SignalTool", label = "Toggle signal controller", tab = "Keyboard", section = "Roads", default = { K.G } },

	-- The move tool is its own context: ALT means "free angle" while drawing a road
	-- and "manipulation mode" while moving one, which is only a clash if they share
	-- a section heading.
	{ id = "MoveRotateLeft", label = "Rotate left while dragging", tab = "Keyboard", section = "Move tool", default = { K.Q } },
	{ id = "MoveRotateRight", label = "Rotate right while dragging", tab = "Keyboard", section = "Move tool", default = { K.E } },
	{ id = "MoveManipulation", label = "Toggle manipulation mode", tab = "Keyboard", section = "Move tool", default = { K.LeftAlt } },

	{ id = "TerrainToggle", label = "Toggle terrain tool", tab = "Keyboard", section = "Terrain", default = { K.T } },
	{ id = "TerrainRaise", label = "Raise ground", tab = "Keyboard", section = "Terrain", default = { K.One } },
	{ id = "TerrainLower", label = "Lower ground", tab = "Keyboard", section = "Terrain", default = { K.Two } },
	{ id = "TerrainFlatten", label = "Flatten", tab = "Keyboard", section = "Terrain", default = { K.Three } },
	{ id = "TerrainSmooth", label = "Smooth", tab = "Keyboard", section = "Terrain", default = { K.Four } },
	{ id = "TerrainLevel", label = "Level", tab = "Keyboard", section = "Terrain", default = { K.Five } },
	{ id = "TerrainPaint", label = "Paint material", tab = "Keyboard", section = "Terrain", default = { K.Six } },
	{ id = "TerrainMaterial", label = "Cycle material", tab = "Keyboard", section = "Terrain", default = { K.M } },
	{ id = "BrushSmaller", label = "Smaller brush", tab = "Keyboard", section = "Terrain", default = { K.LeftBracket } },
	{ id = "BrushLarger", label = "Larger brush", tab = "Keyboard", section = "Terrain", default = { K.RightBracket } },

	{ id = "ToggleZoning", label = "Toggle zoning", tab = "Keyboard", section = "Zoning", default = { K.E } },
	{ id = "ConfirmArea", label = "Confirm area", tab = "Keyboard", section = "Zoning", default = { K.Return } },
	{ id = "RemoveLastPoint", label = "Remove last point", tab = "Keyboard", section = "Zoning", default = { K.Backspace } },

	{ id = "RemoveLastStop", label = "Remove last stop", tab = "Keyboard", section = "Transit", default = { K.U } },

	{ id = "Place", label = "Place / select", tab = "Mouse", section = "Tools", default = { M.MouseButton1 }, required = true },
	{ id = "Cancel", label = "Cancel", tab = "Mouse", section = "Tools", default = { M.MouseButton2 }, required = true },
	-- One mouse camera button, and it is the middle one. Right mouse is the tools' --
	-- rotate what you are placing, un-zone, cancel -- so it never moves the view.
	{ id = "PanCamera", label = "Look around (drag)", tab = "Mouse", section = "Camera", default = { M.MouseButton3 } },

	{ id = "AdminPanel", label = "Staff panel", tab = "Misc", section = "Debug", default = { K.F4 } },
	{ id = "DeveloperPanel", label = "Developer panel", tab = "Misc", section = "Debug", default = { K.F6 } },
})

-- Derived indexes: pure lookups over the registry above, built once at load.
local DEFAULT_BINDS: { [string]: Bind } = {}
local SECTION_OF: { [string]: string } = {}
local TAB_OF: { [string]: string } = {}
local REQUIRED_OF: { [string]: boolean } = {}
for _, def in ACTIONS do
	DEFAULT_BINDS[def.id] = table.freeze(def.default)
	SECTION_OF[def.id] = def.section
	TAB_OF[def.id] = def.tab
	REQUIRED_OF[def.id] = def.required == true
end
table.freeze(DEFAULT_BINDS)
table.freeze(SECTION_OF)
table.freeze(TAB_OF)
table.freeze(REQUIRED_OF)

-- Quality presets. Roblox's own SavedQualityLevel is read-only to scripts, so a
-- preset drives the effects this game owns, nothing more.
local PRESETS: { [string]: { [string]: any } } = table.freeze({
	Low = table.freeze({ shadowQuality = "Off", bloom = false, sunRays = false, depthOfField = false, haze = false, waterReflections = 0, frostedGlass = false, waterWaves = false, renderDistance = 0.6 }),
	Medium = table.freeze({ shadowQuality = "Hard", bloom = true, sunRays = false, depthOfField = false, haze = true, waterReflections = 0.25, frostedGlass = false, waterWaves = true, renderDistance = 0.85 }),
	High = table.freeze({ shadowQuality = "Soft", bloom = true, sunRays = true, depthOfField = false, haze = true, waterReflections = 0.45, frostedGlass = true, waterWaves = true, renderDistance = 1 }),
	Ultra = table.freeze({ shadowQuality = "Soft", bloom = true, sunRays = true, depthOfField = true, haze = true, waterReflections = 1, frostedGlass = true, waterWaves = true, renderDistance = 1.5 }),
})

local _values: { [string]: any } = table.clone(DEFAULT_VALUES)
local _binds: { [string]: Bind } = table.clone(DEFAULT_BINDS)
local _valueSubs: { [string]: { (any) -> () } } = {}
local _bindSubs: { (string, Bind) -> () } = {}
-- One step of undo per action, for the row's revert button. Session-only on
-- purpose: it is never saved, so a rejoin starts with clean rows.
local _previous: { [string]: Bind } = {}

local function fireBind(action: string)
	for _, fn in _bindSubs do
		fn(action, _binds[action])
	end
end

local Settings = {}

function Settings.get(key: string): any
	return _values[key]
end

function Settings.defaults(): { [string]: any }
	return table.clone(DEFAULT_VALUES)
end

function Settings.bindDefaults(): { [string]: Bind }
	return table.clone(DEFAULT_BINDS)
end

function Settings.set(key: string, value: any)
	-- Numbers are kept at 2 decimals. Sliders and the values seeded from the live
	-- float32 effects both produce noise far past anything a player can perceive,
	-- and it ends up in the saved record verbatim.
	if type(value) == "number" then
		value = math.round(value * 100) / 100
	end
	if _values[key] == value then
		return
	end
	_values[key] = value
	local subs = _valueSubs[key]
	if subs then
		for _, fn in subs do
			fn(value)
		end
	end
end

-- The keys a preset owns. The settings page flips graphicsPreset to "Custom"
-- when the player edits one of these by hand.
function Settings.presetKeys(): { [string]: boolean }
	local keys: { [string]: boolean } = {}
	for key in PRESETS.High do
		keys[key] = true
	end
	return keys
end

function Settings.presetNames(): { string }
	return { "Low", "Medium", "High", "Ultra" }
end

function Settings.applyPreset(name: string)
	local preset = PRESETS[name]
	if not preset then
		return
	end
	for key, value in preset do
		Settings.set(key, value)
	end
	Settings.set("graphicsPreset", name)
end

function Settings.onChanged(key: string, fn: (any) -> ())
	local subs = _valueSubs[key]
	if not subs then
		subs = {}
		_valueSubs[key] = subs
	end
	table.insert(subs, fn)
end

function Settings.actions(): { ActionDef }
	return ACTIONS
end

function Settings.getBind(action: BindAction): Bind
	return _binds[action] or EMPTY_BIND
end

-- Order-insensitive: A + S and S + A are the same chord.
function Settings.bindsEqual(a: Bind?, b: Bind?): boolean
	if not a or not b or #a ~= #b then
		return false
	end
	for _, input in a do
		local found = false
		for _, other in b do
			if other == input then
				found = true
				break
			end
		end
		if not found then
			return false
		end
	end
	return true
end

local function bindHas(bind: Bind, input: BindInput): boolean
	for _, other in bind do
		if other == input then
			return true
		end
	end
	return false
end

local function isHeld(input: BindInput): boolean
	if MOUSE_INPUTS[input] then
		return UserInputService:IsMouseButtonPressed(input :: Enum.UserInputType)
	end
	local key = input :: Enum.KeyCode
	if UserInputService:IsKeyDown(key) then
		return true
	end
	for right, left in MODIFIER_PAIR do
		if left == key and UserInputService:IsKeyDown(right) then
			return true
		end
	end
	return false
end

-- The bind input an event carries, with right-hand modifiers folded onto their
-- left twin. nil for input this game never binds (touch, gamepad, wheel, moves).
local function eventInput(input: InputObject): BindInput?
	if input.UserInputType == Enum.UserInputType.Keyboard then
		local key = input.KeyCode
		if key == Enum.KeyCode.Unknown then
			return nil
		end
		return MODIFIER_PAIR[key] or key
	end
	if MOUSE_INPUTS[input.UserInputType] then
		return input.UserInputType
	end
	return nil
end

-- Continuous check: every input in the bind is held right now. Used by the camera
-- every frame, and by hold-modifiers. Extra modifiers are ignored on purpose --
-- SHIFT + W must still move the camera forward.
function Settings.isDown(bind: Bind): boolean
	if #bind == 0 then
		return false
	end
	for _, input in bind do
		if not isHeld(input) then
			return false
		end
	end
	return true
end

function Settings.isActionDown(action: BindAction): boolean
	return Settings.isDown(Settings.getBind(action))
end

-- Every keybind and mouse-bind in the game answers through Settings.pressed, so ONE flag
-- here is the whole keyboard surface. The asset gate holds it while a freshly loaded city
-- is still dropping in: the player may look around (the camera reads isDown, not pressed)
-- but cannot open, place, delete or undo anything until the city is really there.
local _bindsLocked = false

function Settings.setBindsLocked(locked: boolean)
	_bindsLocked = locked == true
end

function Settings.bindsLocked(): boolean
	return _bindsLocked
end

-- Discrete check for an InputBegan event: this event completes the action's bind.
-- Keyboard binds are modifier-EXCLUSIVE, so CONTROL + Z does not also fire on
-- CONTROL + SHIFT + Z. Mouse binds ignore extra modifiers (CONTROL + click is
-- still a click, and tools read the modifier themselves).
function Settings.pressed(action: BindAction, input: InputObject): boolean
	if _bindsLocked then
		return false
	end
	local bind = _binds[action]
	if not bind or #bind == 0 then
		return false
	end
	local hit = eventInput(input)
	if not hit or not bindHas(bind, hit) then
		return false
	end
	for _, other in bind do
		if other ~= hit and not isHeld(other) then
			return false
		end
	end
	if not MOUSE_INPUTS[hit] then
		for modifier in MODIFIERS do
			if not bindHas(bind, modifier) and isHeld(modifier) then
				return false
			end
		end
	end
	return true
end

function Settings.bindLabel(bind: Bind): string
	if #bind == 0 then
		return "(not set)"
	end
	local parts = table.create(#bind)
	for i, input in bind do
		parts[i] = MOUSE_INPUTS[input] or KEY_LABEL[input] or string.upper(input.Name)
	end
	return table.concat(parts, " + ")
end

-- The same parts as bindLabel, one per keycap, for the settings page chips.
function Settings.bindCaps(bind: Bind): { string }
	local caps = table.create(#bind)
	for i, input in bind do
		caps[i] = MOUSE_INPUTS[input] or KEY_LABEL[input] or string.upper(input.Name)
	end
	return caps
end

function Settings.isBindableMouse(inputType: Enum.UserInputType): boolean
	return MOUSE_INPUTS[inputType] ~= nil
end

function Settings.actionTab(action: BindAction): string?
	return TAB_OF[action]
end

-- A Mouse action takes mouse buttons; every other action takes keys. The settings
-- page only offers the matching device, and this keeps a hand-edited save from
-- smuggling the wrong one onto a row that cannot show it.
function Settings.bindFitsAction(action: BindAction, bind: Bind): boolean
	local wantsMouse = TAB_OF[action] == "Mouse"
	for _, input in bind do
		if (MOUSE_INPUTS[input] ~= nil) ~= wantsMouse then
			return false
		end
	end
	return true
end

-- Binds persist as enum names ("W", "MouseButton1").
function Settings.inputFromName(name: string): BindInput?
	for inputType in MOUSE_INPUTS do
		if inputType.Name == name then
			return inputType
		end
	end
	local ok, key = pcall(function()
		return (Enum.KeyCode :: any)[name]
	end)
	if ok and typeof(key) == "EnumItem" then
		return key :: Enum.KeyCode
	end
	return nil
end

-- Other actions in the SAME section sharing this bind. Across sections a shared
-- key is deliberate (RIGHT MOUSE cancels a tool and orbits the camera), so only
-- a clash the player can actually feel in one context is reported.
function Settings.conflictsFor(action: BindAction, bind: Bind): { string }
	local hits: { string } = {}
	if #bind == 0 then
		return hits
	end
	local section = SECTION_OF[action]
	for other, otherBind in _binds do
		if other ~= action and SECTION_OF[other] == section and Settings.bindsEqual(otherBind, bind) then
			table.insert(hits, other)
		end
	end
	return hits
end

function Settings.bindConflicts(action: BindAction): { string }
	return Settings.conflictsFor(action, _binds[action] or EMPTY_BIND)
end

function Settings.isRequired(action: BindAction): boolean
	return REQUIRED_OF[action] == true
end

function Settings.actionSection(action: BindAction): string?
	return SECTION_OF[action]
end

-- Whether the conflict dialog may offer SWAP: the displaced action inherits this
-- row's current bind, which is no good if this row has none and that action must
-- always have one.
function Settings.canSwap(action: BindAction, bind: Bind): boolean
	if #(_binds[action] or EMPTY_BIND) > 0 then
		return true
	end
	for _, other in Settings.conflictsFor(action, bind) do
		if REQUIRED_OF[other] then
			return false
		end
	end
	return true
end

-- Player chose SWAP in the conflict dialog: `bind` moves to `action`, and whatever
-- held it inherits the bind this row used to have.
function Settings.swapBind(action: BindAction, bind: Bind)
	if not Settings.canSwap(action, bind) then
		return
	end
	local displaced = Settings.conflictsFor(action, bind)
	local old = _binds[action] or EMPTY_BIND
	Settings.setBind(action, bind)
	if not Settings.bindsEqual(_binds[action], bind) then
		return -- assignment was rejected; leave the other rows alone
	end
	for _, other in displaced do
		_previous[other] = _binds[other]
		_binds[other] = old
		fireBind(other)
	end
end

function Settings.hasPrevious(action: BindAction): boolean
	return _previous[action] ~= nil
end

-- Undo this row's last change, one step. Consumes the snapshot, so the revert
-- button goes away after use.
function Settings.revertBind(action: BindAction)
	local prev = _previous[action]
	if not prev then
		return
	end
	_previous[action] = nil
	if Settings.bindsEqual(_binds[action], prev) then
		return
	end
	_binds[action] = prev
	fireBind(action)
end

-- Takes over the action's bind and nothing else: no collision swap, so rebinding
-- one action can never move another action's keys.
function Settings.setBind(action: BindAction, bind: Bind)
	if #bind == 0 or #bind > MAX_BIND_INPUTS then
		return
	end
	if not DEFAULT_BINDS[action] or not Settings.bindFitsAction(action, bind) then
		return
	end
	if Settings.bindsEqual(_binds[action], bind) then
		return
	end
	_previous[action] = _binds[action]
	_binds[action] = table.freeze(table.clone(bind))
	fireBind(action)
end

-- Cleared to "(not set)": the action keeps its row but fires on nothing. Refused
-- for required actions -- those can be rebound, never left unbound.
function Settings.clearBind(action: BindAction)
	local bind = _binds[action]
	if not bind or #bind == 0 or REQUIRED_OF[action] then
		return
	end
	_previous[action] = bind
	_binds[action] = EMPTY_BIND
	fireBind(action)
end

-- Bulk load from persisted settings: per action, a valid bind applies and
-- anything malformed keeps the default. An explicitly empty list is a cleared
-- bind, so it applies too.
function Settings.loadBinds(saved: { [string]: Bind })
	for action in DEFAULT_BINDS do
		local bind = saved[action]
		-- A required action is never left unbound, whatever the save says.
		if bind and #bind <= MAX_BIND_INPUTS and not (#bind == 0 and REQUIRED_OF[action])
			and Settings.bindFitsAction(action, bind)
			and not Settings.bindsEqual(_binds[action], bind) then
			_binds[action] = table.freeze(table.clone(bind))
			fireBind(action)
		end
	end
end

function Settings.onBindChanged(fn: (string, Bind) -> ())
	table.insert(_bindSubs, fn)
end

function Settings.resetBinds()
	table.clear(_previous)
	for action, bind in DEFAULT_BINDS do
		if not Settings.bindsEqual(_binds[action], bind) then
			_binds[action] = bind
			fireBind(action)
		end
	end
end

return Settings