--!strict
-- Applies Core.Settings to the engine (lighting, terrain water, HUD scale)
-- and persists the store per player: seed from the live place, pull the
-- player's saved settings once at boot, push a debounced full payload to the
-- server after any change. Runs from Bootstrap before any UI exists, so
-- persisted settings apply even if the settings page is never opened.

local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Settings = require(script.Parent:WaitForChild("Settings"))
local DeviceProfile = require(script.Parent:WaitForChild("DeviceProfile"))
local RenderPressure = require(script.Parent:WaitForChild("RenderPressure"))
local uiFolder = script.Parent.Parent:WaitForChild("UI")
local HudScale = require(uiFolder:WaitForChild("HudScale"))
local Glass = require(uiFolder:WaitForChild("Kit"):WaitForChild("Glass"))
local Locale = require(uiFolder:WaitForChild("Locale"))
local PerfOverlay = require(uiFolder:WaitForChild("PerfOverlay"))
local BootGate = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ClientBootGate"))

local SettingsClient = {}

local PUSH_DELAY = 2
-- Keys that ARE the shipped look. Dropped from a save older than the current
-- lookVersion: every save carries all keys, so a player who never touched a
-- slider would otherwise pin the previous look forever.
local LOOK_KEYS: { [string]: boolean } = table.freeze({
	ccSaturation = true, ccContrast = true, ccBrightness = true,
	tintR = true, tintG = true, tintB = true,
	exposure = true, hazeDensity = true, waterTransparency = true,
})

local _started = false
local _applyingRemote = false
local _pushToken = 0
-- The settings page stages changes: they apply live but must not reach the
-- profile until the player presses APPLY, or its "changes pending" footer
-- would be lying two seconds after every slider drag.
local _held = false

local function push()
	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	local values: { [string]: any } = {}
	for key in Settings.defaults() do
		values[key] = Settings.get(key)
	end
	local binds: { [string]: { string } } = {}
	for action in Settings.bindDefaults() do
		local names: { string } = {}
		for i, input in Settings.getBind(action :: any) do
			names[i] = input.Name
		end
		binds[action] = names
	end
	Net.RequestSaveSettings:FireServer({ values = values, binds = binds })
end

local function scheduleSave()
	if _applyingRemote then
		return
	end
	if _held then
		return
	end
	_pushToken += 1
	local token = _pushToken
	task.delay(PUSH_DELAY, function()
		if token ~= _pushToken then
			return
		end
		push()
	end)
end

-- While held, changes still apply live but never persist. Releasing does NOT
-- save on its own -- the caller decides, via flush().
function SettingsClient.setHold(hold: boolean)
	_held = hold
	if hold then
		-- Cancel any debounced push already in flight, so a change made just
		-- before the page opened cannot land mid-session.
		_pushToken += 1
	end
end

-- Write the store to the profile now. Safe to call while held.
function SettingsClient.flush()
	_pushToken += 1
	push()
end

-- Saved payload -> store, type-checked against the defaults. Bad entries are
-- dropped, not fatal: the default stays.
--
-- Returns whether the save carried a graphics preset the player had chosen for
-- themselves. That is the one setting this client may pick on their behalf (see
-- the auto-detect below), and it may only do so for a player who has never
-- chosen -- so "was it in the save" has to be answered here, where the payload
-- is, rather than inferred afterwards from a value that now always exists.
local function applySaved(saved: any): boolean
	if typeof(saved) ~= "table" then
		return false
	end
	local hadPreset = typeof(saved.values) == "table"
		and typeof((saved.values :: any).graphicsPreset) == "string"
	_applyingRemote = true
	if typeof(saved.values) == "table" then
		local staleLook = (saved.values :: any).lookVersion ~= Settings.get("lookVersion")
		for key, def in Settings.defaults() do
			local v = (saved.values :: any)[key]
			if typeof(v) ~= typeof(def) then
				continue
			end
			if staleLook and (LOOK_KEYS[key] or key == "lookVersion") then
				continue
			end
			if typeof(v) == "number" then
				if v == v and v >= -3 and v <= 120 then
					Settings.set(key, v)
				end
			else
				Settings.set(key, v)
			end
		end
	end
	if typeof(saved.binds) == "table" then
		local parsed: { [string]: Settings.Bind } = {}
		for action in Settings.bindDefaults() do
			local entry = (saved.binds :: any)[action]
			-- Saves written before chords existed hold one key name, not a list.
			if typeof(entry) == "string" then
				entry = { entry }
			end
			if typeof(entry) == "table" then
				local bind: Settings.Bind = {}
				for _, name in entry do
					local input = if typeof(name) == "string" then Settings.inputFromName(name) else nil
					if input and #bind < 3 then
						table.insert(bind, input)
					end
				end
				-- An empty list is a bind the player cleared, so it applies. A list that
				-- had entries but none valid is junk, so the default stays.
				if #bind > 0 or #entry == 0 then
					parsed[action] = bind
				end
			end
		end
		Settings.loadBinds(parsed)
	end
	_applyingRemote = false
	return hadPreset
end

-- Choose a starting preset for a player who has never chosen one.
--
-- The shipped default is "High", and until this existed that is what a phone got: every
-- low-end behaviour in the render path hangs off graphicsPreset == "Low", so the five levers
-- tuned for weak devices were switched off on exactly the hardware they were written for.
--
-- Applied ONLY when the save had no preset of its own. A returning player's choice always
-- wins, including a returning player who deliberately chose Ultra on a handset -- being
-- overruled by the game every session is worse than a few dropped frames they opted into.
local function autoPreset()
	local profile = DeviceProfile.get()
	script:SetAttribute("DetectedProfile", profile.why)
	if profile.preset == "High" then
		return -- what the store already holds; applying it would only churn a save
	end
	Settings.applyPreset(profile.preset)
end

function SettingsClient.Start()
	if _started then
		return
	end
	_started = true

	-- Seed the store from the live place so the settings page shows reality
	-- and "default" means "what the place shipped with".
	local bloom = Lighting:FindFirstChild("CityBuild_SoftBloom")
	local sunRays = Lighting:FindFirstChild("CityBuild_GoldenRays")
	local dof = Lighting:FindFirstChild("CityBuild_DistantDepth")
	local grade = Lighting:FindFirstChild("CityBuild_ColorGrade")
	local haze = Lighting:FindFirstChild("CityBuild_WarmHaze")
	local hazeDensity = if haze then (haze :: Atmosphere).Density else 0.18
	Settings.set("shadowQuality", if not Lighting.GlobalShadows then "Off" elseif Lighting.ShadowSoftness > 0.4 then "Soft" else "Hard")
	if bloom then
		Settings.set("bloom", (bloom :: any).Enabled)
		Settings.set("bloomIntensity", (bloom :: BloomEffect).Intensity)
	end
	if sunRays then
		Settings.set("sunRays", (sunRays :: any).Enabled)
		Settings.set("sunRayIntensity", (sunRays :: SunRaysEffect).Intensity)
	end
	if dof then Settings.set("depthOfField", (dof :: any).Enabled) end
	if grade then
		local g = grade :: ColorCorrectionEffect
		Settings.set("colorGrade", g.Enabled)
		Settings.set("ccSaturation", g.Saturation)
		Settings.set("ccContrast", g.Contrast)
		Settings.set("ccBrightness", g.Brightness)
		Settings.set("tintR", g.TintColor.R)
		Settings.set("tintG", g.TintColor.G)
		Settings.set("tintB", g.TintColor.B)
	end
	Settings.set("exposure", Lighting.ExposureCompensation)
	if haze then Settings.set("haze", (haze :: Atmosphere).Density > 0.005) end
	Settings.set("waterReflections", Workspace.Terrain.WaterReflectance)
	Settings.set("waterTransparency", Workspace.Terrain.WaterTransparency)
	if haze then Settings.set("hazeDensity", hazeDensity) end
	local baseFogEnd = Lighting.FogEnd
	local baseWaveSize = math.max(Workspace.Terrain.WaterWaveSize, 0.05)
	Settings.set("waterWaves", Workspace.Terrain.WaterWaveSize > 0)

	-- Appliers: engine state follows the store.
	Settings.onChanged("shadowQuality", function(v)
		Lighting.GlobalShadows = v ~= "Off"
		Lighting.ShadowSoftness = if v == "Soft" then 1 else 0.2
	end)
	Settings.onChanged("bloom", function(v)
		if bloom then (bloom :: any).Enabled = v == true end
	end)
	Settings.onChanged("sunRays", function(v)
		if sunRays then (sunRays :: any).Enabled = v == true end
	end)
	Settings.onChanged("depthOfField", function(v)
		if dof then (dof :: any).Enabled = v == true end
	end)
	Settings.onChanged("colorGrade", function(v)
		if grade then (grade :: any).Enabled = v == true end
	end)
	Settings.onChanged("ccSaturation", function(v)
		if grade then (grade :: ColorCorrectionEffect).Saturation = math.clamp(tonumber(v) or 0, -1, 1) end
	end)
	Settings.onChanged("ccContrast", function(v)
		if grade then (grade :: ColorCorrectionEffect).Contrast = math.clamp(tonumber(v) or 0, -1, 1) end
	end)
	Settings.onChanged("ccBrightness", function(v)
		if grade then (grade :: ColorCorrectionEffect).Brightness = math.clamp(tonumber(v) or 0, -1, 1) end
	end)
	local function applyTint()
		if grade then
			local function ch(key: string): number
				return math.clamp(tonumber(Settings.get(key)) or 1, 0, 1)
			end
			(grade :: ColorCorrectionEffect).TintColor = Color3.new(ch("tintR"), ch("tintG"), ch("tintB"))
		end
	end
	Settings.onChanged("tintR", applyTint)
	Settings.onChanged("tintG", applyTint)
	Settings.onChanged("tintB", applyTint)
	Settings.onChanged("exposure", function(v)
		Lighting.ExposureCompensation = math.clamp(tonumber(v) or 0, -2, 2)
	end)
	Settings.onChanged("haze", function(v)
		if haze then
			(haze :: Atmosphere).Density = if v == true then hazeDensity else 0
		end
	end)
	Settings.onChanged("waterReflections", function(v)
		Workspace.Terrain.WaterReflectance = math.clamp(tonumber(v) or 0, 0, 1)
	end)
	Settings.onChanged("waterTransparency", function(v)
		Workspace.Terrain.WaterTransparency = math.clamp(tonumber(v) or 0, 0, 1)
	end)
	Settings.onChanged("bloomIntensity", function(v)
		if bloom then (bloom :: BloomEffect).Intensity = math.clamp(tonumber(v) or 0, 0, 4) end
	end)
	Settings.onChanged("sunRayIntensity", function(v)
		if sunRays then (sunRays :: SunRaysEffect).Intensity = math.clamp(tonumber(v) or 0, 0, 1) end
	end)
	Settings.onChanged("hazeDensity", function(v)
		-- Only meaningful while haze is on; the haze toggle re-reads this value.
		hazeDensity = math.clamp(tonumber(v) or 0, 0, 1)
		if haze and Settings.get("haze") == true then
			(haze :: Atmosphere).Density = hazeDensity
		end
	end)
	Settings.onChanged("uiScale", function(v)
		HudScale.setUserScale(tonumber(v) or 1)
	end)
	Settings.onChanged("uiTransparency", function(v)
		Glass.setUserTransparency(tonumber(v) or 0)
	end)
	Settings.onChanged("language", function(v)
		Locale.setLanguage(tostring(v))
	end)
	Locale.Start()
	PerfOverlay.Start()
	-- The preset is evidence about the device, not merely a look: someone on Low has told us
	-- their machine is struggling, so it sets a FLOOR under the adaptive pressure level that
	-- frame time may deepen but never ease back out of. Wired before the saved profile lands,
	-- so a loaded preset arrives through the same path as one chosen mid-session.
	RenderPressure.Start()
	Settings.onChanged("graphicsPreset", function(v)
		RenderPressure.setPreset(tostring(v))
	end)
	RenderPressure.setPreset(tostring(Settings.get("graphicsPreset")))
	Settings.onChanged("waterWaves", function(v)
		Workspace.Terrain.WaterWaveSize = if v == true then baseWaveSize else 0
	end)
	-- Draw distance: scales the shipped fog wall. Roblox has no script-settable
	-- render distance, so fog is the honest lever.
	Settings.onChanged("renderDistance", function(v)
		Lighting.FogEnd = baseFogEnd * math.clamp(tonumber(v) or 1, 0.4, 2)
	end)

	-- Day/night off: pin the local clock to noon. The server (TimeService) keeps
	-- writing the replicated ClockTime every heartbeat, so we re-pin on every
	-- change; turning the cycle back on recovers on the server's next write.
	local function applyDayNight()
		if Settings.get("dayNight") == false and Lighting.ClockTime ~= 12 then
			Lighting.ClockTime = 12
		end
	end
	Settings.onChanged("dayNight", applyDayNight)
	Lighting:GetPropertyChangedSignal("ClockTime"):Connect(applyDayNight)
	applyDayNight()

	-- Start paused: ask the server to pause the sim the moment a city is entered.
	task.spawn(function()
		local UIEvents = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("UIEvents"))
		UIEvents.GameEntered.Event:Connect(function()
			if Settings.get("startPaused") == true then
				local Net = require(ReplicatedStorage:WaitForChild("Networker"))
				Net.RequestGameSpeed:FireServer(0)
			end
		end)
	end)

	-- Persistence: any change (value or bind) schedules one debounced push.
	for key in Settings.defaults() do
		Settings.onChanged(key, scheduleSave)
	end
	Settings.onBindChanged(scheduleSave)

	task.spawn(function()
		local Net = require(ReplicatedStorage:WaitForChild("Networker"))
		local ok, saved = pcall(function()
			return Net.RequestPlayerSettings:InvokeServer()
		end)
		local hadPreset = false
		if ok then
			hadPreset = applySaved(saved)
		else
			warn("[SettingsClient] settings load failed: " .. tostring(saved))
		end
		-- Best-effort: a fault in detection must cost the player a tuned preset, never the
		-- boot gate below -- which is what holds the loading screen open.
		if not hadPreset then
			local okAuto, autoErr = pcall(autoPreset)
			if not okAuto then
				warn("[SettingsClient] preset auto-detect failed: " .. tostring(autoErr))
			end
		end
		-- Join gate: the loading screen holds until the saved profile has been APPLIED, not
		-- merely loaded server-side, so the menu never opens in the wrong language or UI
		-- scale and snaps a moment later. Marked on the failure path too -- a fetch that
		-- failed is never going to arrive, and holding the screen for it buys nothing.
		BootGate.markDone("settings")
	end)
end

return SettingsClient