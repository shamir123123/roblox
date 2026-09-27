--!strict

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local TerrainBuildController = require(ReplicatedStorage:WaitForChild("Terrain"):WaitForChild("TerrainBuildController"))
local SoundFX = require(script.Parent.Parent.Parent:WaitForChild("Core"):WaitForChild("SoundFX"))

local MAIN_MENU_NAME = "MainMenu"
local HUD_NAME = "CityUI"
local GAME_LOADING_SCREEN_NAME = "GameLoadingScreen"
local ASSET_GATE_NAME = "AssetLoadGate"
-- Backstop on the gate, above WorldRevealController's own 120s budget. The reveal releases
-- itself long before this; what this exists for is the case where play() never returns at
-- all, because a player locked out of their own city with no way back is the one failure
-- here that cannot be recovered from in-game.
local ASSET_GATE_TIMEOUT = 150
local MAIN_MENU_BACKGROUND_NAME = "BG"
local MAIN_MENU_PARALLAX_BACKGROUND_NAME = "MainMenuParallaxBackground"

-- Guis that follow the menu/gameplay toggle. "Modals" and "Debug" used to sit in this
-- list and matched nothing the controllers actually create (the real names are
-- UIModalOverlay and _AdminFPS). Restoring guis by name is what made this drift silently
-- fatal, so anything the loading screen hid is now handed back by attribute instead --
-- see setGameplayGuisEnabled. They are deliberately NOT listed here: the menu uses its
-- own tooltips and dialogs, so the overlays must stay up while the menu is open.
local GAMEPLAY_GUIS = {
	"CityUI",
	"Notifications",
	"LaneTools",
}

local HIDDEN_BY_LOADER_ATTR = "HiddenByLoadingScreen"

local MENU_OUT_TIME = 0.36
local MENU_IN_TIME = 0.55
local GAME_LOADING_FADE_TIME = 0.32
local MENU_SLIDE_OFFSET = 28
local PARALLAX_OFFSET_X = 22
local PARALLAX_OFFSET_Y = 14
local PARALLAX_SMOOTHNESS = 5.5
local PARALLAX_IDLE_DELAY = 10
local PARALLAX_IDLE_OFFSET_X = 4
local PARALLAX_IDLE_OFFSET_Y = 3
local PARALLAX_IDLE_STEP_TIME = 4.2
local PARALLAX_IDLE_BLEND_IN_TIME = 1.45
local PARALLAX_IDLE_BLEND_OUT_TIME = 0.28

local UICreation = script.Parent.Parent.Parent:WaitForChild("UICreation")
local MainMenuView = require(UICreation:WaitForChild("MainMenuView"))
local BootGate = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ClientBootGate"))
local PlacesConfig = require(ReplicatedStorage:WaitForChild("Access"):WaitForChild("PlacesConfig"))
local MainMenuController = {}

function MainMenuController.Start()
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local mainMenu = MainMenuView.build()
mainMenu.Parent = playerGui

local container = mainMenu:WaitForChild("Container") :: Frame
local main = container:WaitForChild("Main") :: Frame

local Net = require(ReplicatedStorage:WaitForChild("Networker"))
local MapPresets = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("MapPresets"))
local WorldThemeCatalog = require(ReplicatedStorage:WaitForChild("World"):WaitForChild("WorldThemeCatalog"))
local MapPreview = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("MapPreview"))
local MapResources = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("MapResources"))
local UIEvents = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("UIEvents"))

-- Menu dialogs use the same UIKit as the in-game HUD: one widget system.
local playerScripts = player:WaitForChild("PlayerScripts")
local coreFolder = playerScripts:WaitForChild("Core")
local FreeCamController = require(coreFolder:WaitForChild("FreeCamController"))
-- The create screen writes one player setting (friendsOffline) straight to the store;
-- SettingsClient persists it from there, same as the Control Room does.
local Settings = require(coreFolder:WaitForChild("Settings"))
-- The staged entrance the city makes once the loading screen is down: roads drop in, then
-- buildings, then props. Armed before the terrain build so the world is already hidden by
-- the time the screen fades.
local WorldReveal = require(playerScripts:WaitForChild("World"):WaitForChild("WorldRevealController"))
local uiFolder = playerScripts:WaitForChild("UI")
local Theme = require(uiFolder:WaitForChild("Theme"))
local kitFolder = uiFolder:WaitForChild("Kit")
local Modal = require(kitFolder:WaitForChild("Modal"))
local Button = require(kitFolder:WaitForChild("Button"))
local Toggle = require(kitFolder:WaitForChild("Toggle"))
local Dropdown = require(kitFolder:WaitForChild("Dropdown"))
local CityRoles = require(ReplicatedStorage:WaitForChild("Access"):WaitForChild("CityRoles"))

-- Matches CitySlotService.MAX_CREATE_INVITES: how many players the create screen will
-- carry into the new city. More than a handful is a job for the access editor in Load
-- City, where each name is checked one at a time instead of on the founding request.
local MAX_CREATE_INVITES = 4

-- Continue / Load Game / New Game are top-level menu items (the GAME parent is gone).
local continueButton = main:WaitForChild("ContinueButton") :: ImageButton
local loadGameButton = main:WaitForChild("LoadGameButton") :: ImageButton
local newGameButton = main:WaitForChild("NewGameButton") :: ImageButton

local function setGameplayGuisEnabled(enabled: boolean)
	for _, name in GAMEPLAY_GUIS do
		local gui = playerGui:FindFirstChild(name)
		if gui and gui:IsA("ScreenGui") then
			gui.Enabled = enabled
		end
	end

	if not enabled then
		return
	end

	-- Hand back every gui the loading screen switched off. LoadingController tags exactly
	-- what it took, so this restores tooltips, modals, hover cards and the radio bar
	-- whatever order the controllers happened to build them in on this client.
	for _, gui in playerGui:GetChildren() do
		if gui:IsA("ScreenGui") and gui:GetAttribute(HIDDEN_BY_LOADER_ATTR) then
			gui.Enabled = true
			gui:SetAttribute(HIDDEN_BY_LOADER_ATTR, nil)
		end
	end
end

-- Arriving from the lobby with a city already chosen. Read here, at the very top,
-- because the answer decides whether the main menu is ever shown at all: this place has
-- no menu of its own, and flashing one up only to animate it straight back out is the
-- bug that reads as "it drops me in the main menu".
--
-- nil on an ordinary join and in Studio -- both of which still get the menu, and need it:
-- a builder who lands here without teleport data has to pick which of the owner's cities
-- to open, and F5 runs the whole menu -> city -> menu loop in place.
local _bootSlotId: number? = nil
do
	local joinData = TeleportService:GetLocalPlayerTeleportData()
	local slotId = if typeof(joinData) == "table" then joinData.slotId else nil
	if typeof(slotId) == "number" then
		_bootSlotId = slotId
	end
end

setGameplayGuisEnabled(false)
-- Never in the CITY place, slot or no slot. The menu there offers NEW CITY and LOAD CITY
-- inside somebody's city, and one frame of it over a loading world is the bug this reads
-- as. What happens instead when the teleport data is missing is at the foot of this file.
mainMenu.Enabled = _bootSlotId == nil and not PlacesConfig.menuIsElsewhere()

-- MainMenuView draws row hover itself (a glass capsule glides to the lit row), so the
-- controller only voices it. Rows used to scale up here; a scaled row pulls its text
-- off the capsule that is hugging it.
local function setupMenuButtonHovers()
	for _, descendant in ipairs(mainMenu:GetDescendants()) do
		if descendant:IsA("ImageButton") and descendant.Name:match("Button$") then
			descendant.MouseEnter:Connect(function()
				SoundFX.play("Hover")
			end)
		end
	end
end

local function setupMainMenuBackgroundParallax()
	local sourceBackground = mainMenu:FindFirstChild(MAIN_MENU_BACKGROUND_NAME, true)
	if not sourceBackground or not sourceBackground:IsA("ImageLabel") then
		warn("MainMenu BG was not found for mouse parallax.")
		return
	end

	sourceBackground.Visible = false

	local existingBackground = mainMenu:FindFirstChild(MAIN_MENU_PARALLAX_BACKGROUND_NAME)
	local background: ImageLabel
	if existingBackground and existingBackground:IsA("ImageLabel") then
		background = existingBackground
	else
		background = Instance.new("ImageLabel")
		background.Name = MAIN_MENU_PARALLAX_BACKGROUND_NAME
		background.Parent = mainMenu
	end

	background.Active = false
	background.AnchorPoint = Vector2.new(0.5, 0.5)
	background.BackgroundTransparency = 1
	background.BorderSizePixel = 0
	background.Image = sourceBackground.Image
	background.ImageColor3 = sourceBackground.ImageColor3
	background.ImageTransparency = sourceBackground.ImageTransparency
	background.Position = UDim2.fromScale(0.5, 0.5)
	background.ScaleType = sourceBackground.ScaleType
	background.Size = UDim2.new(
		1,
		((PARALLAX_OFFSET_X + PARALLAX_IDLE_OFFSET_X) * 2) + 12,
		1,
		((PARALLAX_OFFSET_Y + PARALLAX_IDLE_OFFSET_Y) * 2) + 12
	)
	background.Visible = true
	background.ZIndex = 0

	local idlePath = {
		Vector2.new(PARALLAX_IDLE_OFFSET_X, -PARALLAX_IDLE_OFFSET_Y * 0.25),
		Vector2.new(PARALLAX_IDLE_OFFSET_X * 0.25, -PARALLAX_IDLE_OFFSET_Y),
		Vector2.new(-PARALLAX_IDLE_OFFSET_X, -PARALLAX_IDLE_OFFSET_Y * 0.2),
		Vector2.new(-PARALLAX_IDLE_OFFSET_X * 0.15, PARALLAX_IDLE_OFFSET_Y),
	}
	local idleOffsetX = Instance.new("NumberValue")
	local idleOffsetY = Instance.new("NumberValue")
	local idleBlend = Instance.new("NumberValue")
	local currentOffset = Vector2.zero
	local targetOffset = Vector2.zero
	local lastMouseMoveTime = os.clock()
	local idlePathIndex = 1
	local idleLoopRunning = false
	local idleActive = false
	local isDestroyed = false
	local inputConnection: RBXScriptConnection? = nil
	local renderConnection: RBXScriptConnection? = nil
	local idleTweenX: Tween? = nil
	local idleTweenY: Tween? = nil
	local idleBlendTween: Tween? = nil

	idleOffsetX.Name = "MainMenuIdleOffsetX"
	idleOffsetY.Name = "MainMenuIdleOffsetY"
	idleBlend.Name = "MainMenuIdleBlend"

	local function cancelIdlePathTweens()
		if idleTweenX then
			idleTweenX:Cancel()
			idleTweenX = nil
		end

		if idleTweenY then
			idleTweenY:Cancel()
			idleTweenY = nil
		end
	end

	local function tweenIdleBlend(targetBlend: number, duration: number)
		if idleBlendTween then
			idleBlendTween:Cancel()
			idleBlendTween = nil
		end

		idleBlendTween = TweenService:Create(
			idleBlend,
			TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
			{ Value = targetBlend }
		)
		idleBlendTween:Play()
	end

	local function stopIdleTweenLoop()
		if not idleActive and idleBlend.Value <= 0 then
			return
		end

		idleActive = false
		cancelIdlePathTweens()
		tweenIdleBlend(0, PARALLAX_IDLE_BLEND_OUT_TIME)

		task.delay(PARALLAX_IDLE_BLEND_OUT_TIME, function()
			if isDestroyed then
				return
			end

			if not idleActive and idleBlend.Value < 0.01 then
				idleOffsetX.Value = 0
				idleOffsetY.Value = 0
			end
		end)
	end

	local function startIdleTweenLoop()
		if idleLoopRunning or idleActive then
			return
		end

		idleActive = true
		idleLoopRunning = true
		tweenIdleBlend(1, PARALLAX_IDLE_BLEND_IN_TIME)

		task.spawn(function()
			while idleActive and background.Parent and mainMenu.Enabled do
				local nextOffset = idlePath[idlePathIndex]
				idlePathIndex = (idlePathIndex % #idlePath) + 1

				local tweenInfo = TweenInfo.new(PARALLAX_IDLE_STEP_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
				local xTween = TweenService:Create(idleOffsetX, tweenInfo, { Value = nextOffset.X })
				local yTween = TweenService:Create(idleOffsetY, tweenInfo, { Value = nextOffset.Y })
				idleTweenX = xTween
				idleTweenY = yTween

				xTween:Play()
				yTween:Play()

				local state = xTween.Completed:Wait()
				if idleTweenX == xTween then
					idleTweenX = nil
				end
				if idleTweenY == yTween then
					idleTweenY = nil
				end

				if not idleActive or state ~= Enum.PlaybackState.Completed then
					break
				end
			end

			idleLoopRunning = false
		end)
	end

	inputConnection = UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			lastMouseMoveTime = os.clock()
			stopIdleTweenLoop()
		end
	end)

	renderConnection = RunService.RenderStepped:Connect(function(dt)
		if not background.Parent then
			stopIdleTweenLoop()
			if inputConnection then
				inputConnection:Disconnect()
				inputConnection = nil
			end
			if renderConnection then
				renderConnection:Disconnect()
				renderConnection = nil
			end
			return
		end

		if not mainMenu.Enabled then
			stopIdleTweenLoop()
			return
		end

		if (os.clock() - lastMouseMoveTime) >= PARALLAX_IDLE_DELAY then
			startIdleTweenLoop()
		end

		local camera = workspace.CurrentCamera
		local viewportSize = if camera then camera.ViewportSize else Vector2.new(1920, 1080)
		local mousePosition = UserInputService:GetMouseLocation()
		local normalizedX = math.clamp(((mousePosition.X / math.max(viewportSize.X, 1)) - 0.5) * 2, -1, 1)
		local normalizedY = math.clamp(((mousePosition.Y / math.max(viewportSize.Y, 1)) - 0.5) * 2, -1, 1)
		local mouseOffset = Vector2.new(-normalizedX * PARALLAX_OFFSET_X, -normalizedY * PARALLAX_OFFSET_Y)
		local idleOffset = Vector2.new(idleOffsetX.Value, idleOffsetY.Value) * idleBlend.Value

		targetOffset = mouseOffset + idleOffset
		currentOffset = currentOffset:Lerp(targetOffset, 1 - math.exp(-dt * PARALLAX_SMOOTHNESS))

		background.Position = UDim2.fromScale(
			0.5 + (currentOffset.X / math.max(viewportSize.X, 1)),
			0.5 + (currentOffset.Y / math.max(viewportSize.Y, 1))
		)
	end)

	script.Destroying:Connect(function()
		isDestroyed = true
		stopIdleTweenLoop()

		if idleBlendTween then
			idleBlendTween:Cancel()
			idleBlendTween = nil
		end

		if inputConnection then
			inputConnection:Disconnect()
			inputConnection = nil
		end

		if renderConnection then
			renderConnection:Disconnect()
			renderConnection = nil
		end

		idleOffsetX:Destroy()
		idleOffsetY:Destroy()
		idleBlend:Destroy()
	end)
end

local function getTransitionScale(cont: GuiObject): UIScale
	local existing = cont:FindFirstChild("MenuTransitionScale")
	if existing and existing:IsA("UIScale") then
		return existing
	end

	local scale = Instance.new("UIScale")
	scale.Name = "MenuTransitionScale"
	scale.Scale = 1
	scale.Parent = cont

	return scale
end

local function getMenuFadeOverlay(): Frame
	local existing = mainMenu:FindFirstChild("MenuFadeOverlay")
	if existing and existing:IsA("Frame") then
		return existing
	end

	local overlay = Instance.new("Frame")
	overlay.Name = "MenuFadeOverlay"
	overlay.Active = true
	overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	overlay.BackgroundTransparency = 1
	overlay.BorderSizePixel = 0
	overlay.Position = UDim2.fromScale(0, 0)
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.Visible = false
	overlay.ZIndex = 10000
	overlay.Parent = mainMenu

	return overlay
end

local hasPlayedMenuIntroFade = false

local function playMenuIntroFade()
	if hasPlayedMenuIntroFade then
		return
	end

	hasPlayedMenuIntroFade = true

	local overlay = getMenuFadeOverlay()
	overlay.BackgroundTransparency = 0
	overlay.Visible = true

	local fadeTween = TweenService:Create(
		overlay,
		TweenInfo.new(MENU_IN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 }
	)

	fadeTween.Completed:Connect(function()
		if overlay.BackgroundTransparency >= 0.99 then
			overlay.Visible = false
		end
	end)

	fadeTween:Play()
end

local function setupMenuIntroFade()
	local overlay = getMenuFadeOverlay()

	if mainMenu.Enabled then
		task.defer(playMenuIntroFade)
	else
		overlay.BackgroundTransparency = 0
		overlay.Visible = true
	end

	mainMenu:GetPropertyChangedSignal("Enabled"):Connect(function()
		if mainMenu.Enabled then
			playMenuIntroFade()
		end
	end)
end

local function animateMenuOut()
	local overlay = getMenuFadeOverlay()
	overlay.BackgroundTransparency = 1
	overlay.Visible = true

	local fadeTween = TweenService:Create(
		overlay,
		TweenInfo.new(MENU_OUT_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
		{ BackgroundTransparency = 0 }
	)

	local originalPosition = container.Position
	local transitionScale = getTransitionScale(container)
	transitionScale.Scale = 1

	local targetPosition = UDim2.new(
		originalPosition.X.Scale,
		originalPosition.X.Offset,
		originalPosition.Y.Scale,
		originalPosition.Y.Offset + MENU_SLIDE_OFFSET
	)

	local slideTween = TweenService:Create(
		container,
		TweenInfo.new(MENU_OUT_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Position = targetPosition }
	)
	local scaleTween = TweenService:Create(
		transitionScale,
		TweenInfo.new(MENU_OUT_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Scale = 0.96 }
	)

	fadeTween:Play()
	slideTween:Play()
	scaleTween:Play()
	fadeTween.Completed:Wait()

	container.Position = originalPosition
	transitionScale.Scale = 1
end

local function addLoadingLogo(parent: Instance)
	local template = ReplicatedFirst:FindFirstChild("LoadingScreen")
	local templateLogo = template and template:FindFirstChild("Logo", true)

	if templateLogo and templateLogo:IsA("ImageLabel") then
		local logo = templateLogo:Clone()
		logo.AnchorPoint = Vector2.new(0.5, 0.5)
		logo.BackgroundTransparency = 1
		logo.Position = UDim2.fromScale(0.5, 0.43)
		logo.Size = UDim2.fromScale(0.34, 0.18)
		logo.ZIndex = 2
		logo.Parent = parent
		return
	end

	local logoText = Instance.new("TextLabel")
	logoText.Name = "LogoText"
	logoText.AnchorPoint = Vector2.new(0.5, 0.5)
	logoText.BackgroundTransparency = 1
	logoText.Font = Enum.Font.GothamBlack
	logoText.Position = UDim2.fromScale(0.5, 0.42)
	logoText.Size = UDim2.fromScale(0.7, 0.13)
	logoText.Text = "TRANSPOT"
	logoText.TextColor3 = Color3.fromRGB(245, 245, 245)
	logoText.TextScaled = true
	logoText.ZIndex = 2
	logoText.Parent = parent
end

local function createGameLoadingScreen()
	local oldLoadingScreen = playerGui:FindFirstChild(GAME_LOADING_SCREEN_NAME)
	if oldLoadingScreen then
		oldLoadingScreen:Destroy()
	end

	local loadingGui = Instance.new("ScreenGui")
	loadingGui.Name = GAME_LOADING_SCREEN_NAME
	loadingGui.DisplayOrder = Theme.Layer.Fade
	loadingGui.IgnoreGuiInset = true
	loadingGui.ResetOnSpawn = false
	loadingGui.Parent = playerGui

	local group = Instance.new("CanvasGroup")
	group.Name = "FadeGroup"
	group.BackgroundColor3 = Color3.fromRGB(4, 4, 6)
	group.BackgroundTransparency = 0
	group.BorderSizePixel = 0
	group.GroupTransparency = 1
	group.Position = UDim2.fromScale(0, 0)
	group.Size = UDim2.fromScale(1, 1)
	group.Parent = loadingGui

	addLoadingLogo(group)

	local loadingText = Instance.new("TextLabel")
	loadingText.Name = "LoadingText"
	loadingText.AnchorPoint = Vector2.new(0.5, 0.5)
	loadingText.BackgroundTransparency = 1
	loadingText.Font = Enum.Font.GothamMedium
	loadingText.Position = UDim2.fromScale(0.5, 0.6)
	loadingText.Size = UDim2.fromScale(0.35, 0.04)
	loadingText.Text = "LOADING GAME"
	loadingText.TextColor3 = Color3.fromRGB(225, 225, 225)
	loadingText.TextScaled = true
	loadingText.ZIndex = 2
	loadingText.Parent = group

	local barTrack = Instance.new("Frame")
	barTrack.Name = "ProgressTrack"
	barTrack.AnchorPoint = Vector2.new(0.5, 0.5)
	barTrack.BackgroundColor3 = Color3.fromRGB(45, 45, 48)
	barTrack.BorderSizePixel = 0
	barTrack.Position = UDim2.fromScale(0.5, 0.66)
	barTrack.Size = UDim2.fromScale(0.22, 0.009)
	barTrack.ZIndex = 2
	barTrack.Parent = group

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = barTrack

	local barFill = Instance.new("Frame")
	barFill.Name = "ProgressFill"
	barFill.BackgroundColor3 = Color3.fromRGB(235, 235, 235)
	barFill.BorderSizePixel = 0
	barFill.Size = UDim2.fromScale(0, 1)
	barFill.ZIndex = 3
	barFill.Parent = barTrack

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = barFill

	return loadingGui, group, barFill
end

-- THE ASSET GATE -- the second half of the loading screen, played with the world visible.
--
-- The screen comes down when the TERRAIN is standing. The built city -- roads, buildings,
-- and everything dressing them -- is still dropping in behind WorldRevealController for
-- seconds after that, and until it has finished the player is in a city that is not all
-- there yet. They used to be free to build in it. Now they watch it arrive.
--
-- Two halves, because there are two input surfaces:
--   * a full-screen Active frame swallows every click, so no HUD button, no tool and no
--     world pick gets through;
--   * Settings.setBindsLocked makes every keybind inert. Every hotkey in the game asks
--     Settings.pressed whether its bind fired, so that one flag is the whole keyboard.
-- The camera is deliberately NOT taken. It reads Settings.isDown, which this leaves alone,
-- so the player can look around the city that is landing in front of them.
--
-- Returns its own closer, which is idempotent: the backstop and the reveal both call it.
--
-- Bumped per gate, because the keyboard lock is one flag shared by all of them: a staff
-- member can open a second city from the F4 panel (it draws above this) while the first is
-- still revealing, and the stale gate's backstop must not hand the keyboard back underneath
-- the live one.
local _gateToken = 0

local function createAssetGate(): () -> ()
	local old = playerGui:FindFirstChild(ASSET_GATE_NAME)
	if old then old:Destroy() end
	_gateToken += 1
	local myToken = _gateToken

	local gui = Instance.new("ScreenGui")
	gui.Name = ASSET_GATE_NAME
	-- BELOW Theme.Layer.Fade: the loading screen is still fading out over the top of this,
	-- and the chip must not read through the black while it does.
	gui.DisplayOrder = Theme.Layer.Fade - 1
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.Parent = playerGui

	local sink = Instance.new("Frame")
	sink.Name = "InputSink"
	sink.Active = true -- the whole point: an Active frame eats the click
	sink.BackgroundTransparency = 1
	sink.BorderSizePixel = 0
	sink.Size = UDim2.fromScale(1, 1)
	sink.Parent = gui

	local chip = Instance.new("Frame")
	chip.Name = "Chip"
	chip.AnchorPoint = Vector2.new(0.5, 0.5)
	chip.BackgroundColor3 = Theme.Color.BgRaised
	chip.BackgroundTransparency = 0.12
	chip.BorderSizePixel = 0
	-- Top centre, on the line the clock and the sim-speed chips already sit on, rather than
	-- over the middle of the map: the player is meant to WATCH the city arrive, and a banner
	-- parked across the view is the one place it cannot go. Offset, not scale, so it stays on
	-- that line whatever the screen height.
	chip.Position = UDim2.new(0.5, 0, 0, 52)
	chip.Size = UDim2.fromOffset(250, 46)
	chip.Parent = sink

	local chipCorner = Instance.new("UICorner")
	chipCorner.CornerRadius = UDim.new(1, 0)
	chipCorner.Parent = chip

	local chipStroke = Instance.new("UIStroke")
	chipStroke.Color = Theme.Color.StrokeSoft
	chipStroke.Thickness = Theme.StrokeWidth.Thin
	chipStroke.Transparency = 0.4
	chipStroke.Parent = chip

	local label = Instance.new("TextLabel")
	label.Name = "Status"
	label.BackgroundTransparency = 1
	label.FontFace = Theme.Font.Bold
	label.Size = UDim2.fromScale(1, 1)
	label.Text = "LOADING ASSETS"
	label.TextColor3 = Theme.Color.TextPrimary
	label.TextSize = Theme.TextSize.SM
	label.Parent = chip

	Settings.setBindsLocked(true)

	-- A label that never changes reads as a hung game. Three dots is the cheapest proof
	-- that something is still happening behind it.
	local closed = false
	task.spawn(function()
		local dots = 0
		while not closed and gui.Parent do
			label.Text = "LOADING ASSETS" .. string.rep(".", dots)
			dots = (dots + 1) % 4
			task.wait(0.4)
		end
	end)

	local function close()
		if closed then return end
		closed = true
		if _gateToken == myToken then
			Settings.setBindsLocked(false)
		end
		gui:Destroy()
	end

	task.delay(ASSET_GATE_TIMEOUT, function()
		if not closed then
			warn("[MainMenuController] the reveal never finished -- releasing the player anyway")
			close()
		end
	end)

	return close
end

-- ---------------------------------------------------------------------------
-- Slot state + city load flow. The server builds nothing until RequestLoadSlot;
-- the loading screen ends on CityLoadResult, never on a timer.
-- ---------------------------------------------------------------------------

-- The server pre-renders the whole map (renderAllAndWait) before firing CityLoadResult,
-- so the reply is the real bound, not a fixed wall. 30s was too tight for big cities on a
-- slow link and tripped a spurious "took too long" (the server kept the city, the client
-- gave up). CitySlotService now also re-admits the owner idempotently, so a timeout here
-- self-heals on retry; this just makes it rare.
local LOAD_TIMEOUT = 180
local ADMIN_LOAD_TIMEOUT = 240

local _slotData: any = nil
local _loadBusy = false
local hasOpenedHub = false
local _adminLoadActive = false
local _adminLoadToken = 0
local _adminLoadWasInGame = false
local _adminLoadingGui: ScreenGui? = nil
local _adminLoadingGroup: CanvasGroup? = nil
local _adminLoadingFill: Frame? = nil

local updateGameButtonsState: () -> () = function() end
local showErrorModal: (string) -> () = function(_message: string) end

local function refreshSlotIndex(onDone: (() -> ())?)
	task.spawn(function()
		local ok, result = pcall(Net.RequestSlotIndex.InvokeServer, Net.RequestSlotIndex)
		if ok and typeof(result) == "table" then
			_slotData = result
		else
			warn("[MainMenuController] slot index request failed")
		end
		updateGameButtonsState()
		if onDone then
			onDone()
		end
	end)
end

local function getSlots(): { any }
	return if _slotData and typeof(_slotData.slots) == "table" then _slotData.slots else {}
end

local function getMaxSlots(): number
	return if _slotData and typeof(_slotData.maxSlots) == "number" then _slotData.maxSlots else 5
end

local function slotExists(slotId: number?): boolean
	if not slotId then return false end
	for _, meta in getSlots() do
		if tonumber(meta.slotId) == slotId then return true end
	end
	return false
end

local function getContinueSlotId(): number?
	if not _slotData then
		return nil
	end
	-- Checked against the list rather than trusted: a lastPlayedSlot left pointing at a
	-- slot that is no longer there would send CONTINUE off to load nothing, where falling
	-- through to the most-recent scan below still resumes something sensible.
	if typeof(_slotData.lastPlayedSlot) == "number" and slotExists(_slotData.lastPlayedSlot) then
		return _slotData.lastPlayedSlot
	end
	local bestId: number? = nil
	local bestTs = -1
	for _, meta in getSlots() do
		local ts = tonumber(meta.lastPlayedTimestamp) or 0
		if ts > bestTs then
			bestTs = ts
			bestId = tonumber(meta.slotId)
		end
	end
	return bestId
end

-- LOAD re-fetches the index before showing its list; CONTINUE only ever saw the one
-- fetch at startup. That fetch races the server session coming up -- right after a join
-- the session lock is still moving between servers, and RequestSlotIndex answers with an
-- empty index -- so CONTINUE is left pointing at nothing while LOAD works fine on the
-- same save. Re-fetch before giving up, so both buttons decide from the same truth.
local function resolveContinueSlot(): number?
	local id = getContinueSlotId()
	if slotExists(id) then return id end

	local done = false
	refreshSlotIndex(function() done = true end)
	local deadline = os.clock() + 5
	while not done and os.clock() < deadline do
		task.wait(0.05)
	end

	id = getContinueSlotId()
	return if slotExists(id) then id else nil
end

local function enterGame(slotMeta: any)
	hasOpenedHub = true
	setGameplayGuisEnabled(true)

	local hud = playerGui:FindFirstChild(HUD_NAME)
	if hud and hud:IsA("ScreenGui") then
		hud.Enabled = true
	else
		warn("CityUI ScreenGui was not found when closing MainMenu.")
	end

	-- HUD controllers own their own entrances; the menu only announces the moment.
	UIEvents.GameEntered:Fire(slotMeta)
end

-- Build the client's terrain locally, from the seed, and stop there. StreamingEnabled is off,
-- so the built city -- roads, buildings, everything dressing them -- replicates over the
-- network; terrain does NOT (each client paints its own).
--
-- THIS IS THE WHOLE LOADING SCREEN, AND IT IS THE WHOLE MAP.
-- It returns only once every chunk is painted and its ground geometry exists, edge to edge.
-- The far edges used to finish in the background after entry, which put the player in a city
-- whose horizon was still drawing itself.
--
-- What the screen does NOT wait for is the built city on top of that terrain: roads,
-- buildings and props arrive behind WorldRevealController, which is armed before this runs,
-- so the world is already invisible when the screen fades and each layer waits for its own
-- instances to replicate and preload before dropping in. The player spends that wait looking
-- at a landscape rather than a progress bar -- behind the asset gate, which is what stops
-- them building in a city that is only half there.
--
-- setBar(frac) drives the loading bar, which the terrain build now owns end to end.
-- beforeDraw is handed straight to the build: it runs once every chunk is painted and
-- before any ground is drawn, which is where the overlap waits for the camera. The admin
-- path passes nothing, because there the server is already finished before this starts.
local function buildTerrain(setBar: (number) -> (), fromFrac: number, beforeDraw: (() -> ())?)
	local BUILD_FROM = math.clamp(fromFrac, 0, 1)
	setBar(BUILD_FROM)

	local builtOk = pcall(function()
		TerrainBuildController.build(Net, function(frac: number)
			setBar(BUILD_FROM + (1 - BUILD_FROM) * math.clamp(frac, 0, 1))
		end, beforeDraw)
	end)
	if not builtOk then
		warn("[MainMenuController] terrain build failed; entering anyway")
	end
end

-- Forward-declared: startCityLoad's CityLoadResult handler calls this, but the
-- definition is further down, so without this the closure would bind a nil global
-- (crashed on the load-failure path).
local setMenuPanelVisible: (boolean) -> ()

local function clearAdminLoadingScreen()
	if _adminLoadingGui then _adminLoadingGui:Destroy() end
	_adminLoadingGui = nil
	_adminLoadingGroup = nil
	_adminLoadingFill = nil
end

local function cancelAdminCityLoad(message: string?)
	if not _adminLoadActive then return end
	_adminLoadActive = false
	_adminLoadToken += 1
	-- The reveal may already be holding the city invisible. Give it back before putting the
	-- player anywhere, or they land in a world that never comes on.
	WorldReveal.release()
	clearAdminLoadingScreen()
	if _adminLoadWasInGame then
		setGameplayGuisEnabled(true)
	else
		mainMenu.Enabled = true
		setMenuPanelVisible(true)
		showErrorModal(message or "The city copy could not be loaded.")
	end
end

local function beginAdminCityLoad()
	if _adminLoadActive then return end
	_adminLoadActive = true
	_adminLoadToken += 1
	_adminLoadWasInGame = hasOpenedHub
	local token = _adminLoadToken

	local loadingGui, group, barFill = createGameLoadingScreen()
	_adminLoadingGui = loadingGui
	_adminLoadingGroup = group
	_adminLoadingFill = barFill
	barFill.Size = UDim2.fromScale(0.05, 1)
	mainMenu.Enabled = false
	setGameplayGuisEnabled(false)

	TweenService:Create(
		group,
		TweenInfo.new(GAME_LOADING_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ GroupTransparency = 0 }
	):Play()

	task.delay(ADMIN_LOAD_TIMEOUT, function()
		if _adminLoadActive and _adminLoadToken == token then
			cancelAdminCityLoad("The city copy is still loading. Try again; large saves can take several minutes.")
		end
	end)
end

local function finishAdminCityLoad(payload: any)
	if not _adminLoadActive then beginAdminCityLoad() end
	local token = _adminLoadToken
	task.spawn(function()
		local group = _adminLoadingGroup
		local barFill = _adminLoadingFill
		if not group or not barFill then return end
		local function setBar(frac: number)
			if barFill.Parent then
				barFill.Size = UDim2.fromScale(math.clamp(frac, 0, 1), 1)
			end
		end

		setBar(0.18)
		WorldReveal.arm()
		-- Camera before the terrain, for the reason startCityLoad spells out.
		FreeCamController.setCameraState(payload.camera)
		buildTerrain(setBar, 0.18)
		if not _adminLoadActive or _adminLoadToken ~= token then
			WorldReveal.release()
			return
		end
		setBar(1)
		task.wait(0.2)
		local closeGate = createAssetGate()
		enterGame(payload.slot)

		local fadeOut = TweenService:Create(
			group,
			TweenInfo.new(GAME_LOADING_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
			{ GroupTransparency = 1 }
		)
		fadeOut:Play()
		task.spawn(function()
			local ok, err = pcall(WorldReveal.play)
			if not ok then warn("[MainMenuController] world reveal failed: " .. tostring(err)) end
			closeGate()
		end)
		fadeOut.Completed:Wait()
		if _adminLoadToken ~= token then return end
		_adminLoadActive = false
		clearAdminLoadingScreen()
	end)
end

-- ownerId is set only when opening a FRIEND's city from the lobby. The server proves
-- the role against that owner's own record before it teleports anyone.
local function startCityLoad(slotId: number, ownerId: number?)
	if _loadBusy or hasOpenedHub then
		-- Silently refusing is how "CONTINUE stopped doing anything" happens: both of these
		-- are latches, and a latch that is never explained is indistinguishable from a dead
		-- button. Say so in the log at least.
		warn(string.format("[MainMenuController] load refused (loadBusy=%s hub=%s)", tostring(_loadBusy), tostring(hasOpenedHub)))
		return
	end
	_loadBusy = true

	local function runLoad()
		-- Straight from a teleport there is no menu on screen to animate away, and both
		-- the slide and the fade below would just be dead time in front of a black frame.
		local fromMenu = mainMenu.Enabled
		if fromMenu then animateMenuOut() end

		local loadingGui, group, barFill = createGameLoadingScreen()
		if fromMenu then
			local fadeIn = TweenService:Create(
				group,
				TweenInfo.new(GAME_LOADING_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ GroupTransparency = 0 }
			)
			fadeIn:Play()
			fadeIn.Completed:Wait()
		else
			group.GroupTransparency = 0
		end
		mainMenu.Enabled = false

		local function setBar(frac: number)
			barFill.Size = UDim2.fromScale(math.clamp(frac, 0, 1), 1)
		end
		setBar(0)

		local resultOk: boolean? = nil
		local resultErr: string? = nil
		local resultSlot: any = nil
		local resultCamera: any = nil

		local conn = Net.CityLoadResult.OnClientEvent:Connect(function(payload: any)
			if typeof(payload) == "table" then
				resultOk = payload.ok == true
				resultErr = if typeof(payload.error) == "string" then payload.error else nil
				resultSlot = payload.slot
				resultCamera = payload.camera
			else
				resultOk = false
			end
		end)

		local tRequest = os.clock()
		Net.RequestLoadSlot:FireServer(slotId, ownerId)

		-- SERIAL, and measured to be right. Building terrain alongside the server's restore
		-- was tried and made it WORSE -- 34.4 s to 36.7 s -- because the server was never the
		-- constraint (3.8 s of it) and this client is: terrain then competed with the city
		-- replicating into the same single thread, and the far pass went from 16.5 ms a chunk
		-- to 33.7. There is no second thread to overlap ONTO. The only thing that shortens this
		-- screen is doing less work, not doing it earlier.
		local deadline = os.clock() + LOAD_TIMEOUT
		local buildStart = os.clock()
		while resultOk == nil and os.clock() < deadline do
			setBar(0.18 * (1 - math.exp(-(os.clock() - buildStart) / 3)))
			task.wait(0.05)
		end

		conn:Disconnect()

		if resultOk then
			-- Hide the city BEFORE the screen comes down -- everything from here until the
			-- reveal finishes is terrain only.
			WorldReveal.arm()
			-- The camera goes FIRST, ahead of the terrain it is going to look at: every block
			-- picks its LOD tier against where the player will be, so placing it afterwards
			-- re-tiers the whole near map on the frame they arrive.
			FreeCamController.setCameraState(resultCamera)
			local tServer = os.clock()
			buildTerrain(setBar, 0.18)
			local tTerrain = os.clock()
			warn(string.format("[CityLoad] %.1fs to the screen coming down = server %.1f + terrain %.1f",
				tTerrain - tRequest, tServer - tRequest, tTerrain - tServer))
			setBar(1)
			task.wait(0.2)

			-- Up BEFORE the HUD is handed back, so there is no frame in which a live HUD is
			-- sitting there unguarded.
			local closeGate = createAssetGate()
			enterGame(resultSlot)

			local fadeOut = TweenService:Create(
				group,
				TweenInfo.new(GAME_LOADING_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
				{ GroupTransparency = 1 }
			)
			fadeOut:Play()
			-- Started with the fade, not after it: the reveal's first act is waiting for the
			-- road meshes to finish baking, and there is no reason to spend the fade not doing
			-- that. Spawned because play() yields for the whole animation -- and its return is
			-- what "the city is all here" means, so it is what takes the gate down.
			task.spawn(function()
				local ok, err = pcall(WorldReveal.play)
				if not ok then warn("[MainMenuController] world reveal failed: " .. tostring(err)) end
				closeGate()
			end)
			fadeOut.Completed:Wait()
			loadingGui:Destroy()
			_loadBusy = false
		else
			-- Armed before the result arrived, so a failed load has a world to hand back.
			WorldReveal.release()
			loadingGui:Destroy()
			-- animateMenuOut() left the fade overlay fully black, and the intro fade that
			-- normally clears it runs ONCE per session and only on Enabled false -> true --
			-- which never happens here, because the menu is put back up by the same handler.
			-- Without this the player is left staring at a black screen with the error modal
			-- somewhere behind it, which is exactly what a rejected load looked like.
			local overlay = getMenuFadeOverlay()
			overlay.BackgroundTransparency = 1
			overlay.Visible = false
			_loadBusy = false
			showErrorModal(resultErr or "The city took too long to load. Try again.")

			-- In the CITY place there is no menu to fall back to -- putting one up is the
			-- bug. Say why, give them long enough to read it, then hand them back to the
			-- lobby, which is the only screen that can actually do anything about it.
			if PlacesConfig.menuIsElsewhere() then
				task.delay(6, function()
					TeleportService:Teleport(PlacesConfig.LOBBY_PLACE_ID)
				end)
				return
			end

			mainMenu.Enabled = true
			setMenuPanelVisible(true)
			refreshSlotIndex()
		end
	end

	-- A load that THREW used to leave _loadBusy latched true, and from then on every
	-- CONTINUE and every slot click did nothing at all -- no error, no screen, no clue.
	-- Whatever happened in there, the flag comes back and the player gets told.
	task.spawn(function()
		local ok, err = pcall(runLoad)
		if ok then
			return
		end
		warn("[MainMenuController] city load errored: " .. tostring(err))
		_loadBusy = false

		local stuckScreen = playerGui:FindFirstChild(GAME_LOADING_SCREEN_NAME)
		if stuckScreen then stuckScreen:Destroy() end
		local overlay = getMenuFadeOverlay()
		overlay.BackgroundTransparency = 1
		overlay.Visible = false

		showErrorModal("Something went wrong opening that city.")
		if PlacesConfig.menuIsElsewhere() then
			task.delay(6, function()
				TeleportService:Teleport(PlacesConfig.LOBBY_PLACE_ID)
			end)
			return
		end
		mainMenu.Enabled = true
		setMenuPanelVisible(true)
	end)
end

-- ---------------------------------------------------------------------------
-- Menu dialogs (UIKit). Lazy-built; shared widget system with the HUD.
-- ---------------------------------------------------------------------------

local makeLabel = MainMenuView.makeLabel

local makeTextBox = MainMenuView.makeTextBox

local makeRow = MainMenuView.makeRow

local setupContent = MainMenuView.setupContent

-- The create/load dialogs replace the menu screen instead of floating over
-- it: the menu panel (logo + buttons) hides while a dialog is open and the
-- parallax background stays. Cancel/X brings the panel back.
function setMenuPanelVisible(visible: boolean)
	main.Visible = visible
end

local glassifyModal = MainMenuView.glassifyModal

-- Error modal --------------------------------------------------------------

local _errorModal: any = nil
local _errorLabel: TextLabel? = nil

showErrorModal = function(message: string)
	if not _errorModal then
		_errorModal = Modal.new({
			size = UDim2.fromOffset(360, 180),
			title = "SOMETHING WENT WRONG",
			name = "MenuErrorModal",
			onClose = function()
				_errorModal:Hide()
			end,
		})
		glassifyModal(_errorModal)
		setupContent(_errorModal.Content)

		local label = makeLabel(_errorModal.Content, "", 1, true)
		label.TextWrapped = true
		label.Size = UDim2.new(1, 0, 0, 56)
		_errorLabel = label

		local footer, footerList = makeRow(_errorModal.Content, 2, 36)
		footerList.HorizontalAlignment = Enum.HorizontalAlignment.Right
		Button.new({ text = "OK", parent = footer, onClick = function()
			_errorModal:Hide()
		end })
	end

	local label = _errorLabel :: TextLabel
	label.Text = message
	_errorModal:Show()
end

-- New City / Load Game screens ---------------------------------------------------------
-- Two full-screen pages built on MenuScreenView, each in two stages that share the right
-- panel: SELECT MAP -> NEW CITY (the map stays on the right, the left becomes the city's
-- settings) and LOAD GAME -> MAP OPTIONS (the save stays on the right, the left becomes
-- that save's options). Multiplayer gets its own tab on the second stage of both.

local MenuScreenView = require(UICreation:WaitForChild("MenuScreenView"))

-- Create-city palette, kept for the Kit widgets (Button, Dropdown) inside the access editor.
type CreatePalette = Button.ButtonPalette & { AccentHover: Color3, TextSecondary: Color3 }
local LP: CreatePalette = {
	Bg            = Color3.fromRGB(20, 26, 21),
	BgRaised      = Color3.fromRGB(30, 37, 31),
	BgHover       = Color3.fromRGB(44, 52, 45),
	BgPress       = Color3.fromRGB(14, 18, 15),
	Stroke        = Color3.fromRGB(86, 92, 84),
	StrokeSoft    = Color3.fromRGB(56, 62, 56),
	Accent        = Theme.Color.Accent,
	AccentHover   = Theme.Color.AccentHover,
	OnAccent      = Theme.Color.OnAccent,
	TextPrimary   = Color3.fromRGB(245, 242, 238),
	TextSecondary = Color3.fromRGB(168, 166, 158),
	TextDisabled  = Color3.fromRGB(120, 120, 114),
	Danger        = Color3.fromRGB(240, 98, 90),
}

local DIFFICULTIES = { "Easy", "Normal", "Hard" }
local HIGHWAY_CHOICES = { "None", "1", "2", "3", "4" }

local function reliefWord(relief: number): string
	if relief < 0.2 then return "Flat" end
	if relief < 0.45 then return "Gentle" end
	if relief < 0.7 then return "Hilly" end
	return "Mountainous"
end

local function themeName(id: any): string
	return WorldThemeCatalog.getOrDefault(id).name
end

local function indexOf(list: { string }, value: any): number
	return table.find(list, value) or 1
end

-- ACCESS EDITOR -------------------------------------------------------------------------
-- Access is per CITY, so every one of these is bound to exactly one city. Used twice: on
-- the New City multiplayer tab, where the city does not exist yet and the rows ride the
-- create request, and on Map Options, where each edit is a remote against that slot. The
-- two differ only in what add / remove / setRole DO, so those are handed in:
--
--   ops.list()              -> { { name: string, role: string } }   (never yields)
--   ops.add(name, role)     -> an error string, or nil              (may yield)
--   ops.remove(name)        -> an error string, or nil              (may yield)
--   ops.setRole(name, role) -> an error string, or nil              (may yield)
--
-- Returns a refresh function, for when the list changed underneath it.
local ROLE_OPTIONS: { { label: string, value: any } } = {}
for i, role in CityRoles.Order do
	ROLE_OPTIONS[i] = { label = CityRoles.Label[role], value = role }
end
local ROLE_PICKER_W = 150

local function buildAccessEditor(parent: Instance, order: number, ops: any): () -> ()
	local holder = Instance.new("Frame")
	holder.Name = "AccessEditor"
	holder.BackgroundTransparency = 1
	holder.AutomaticSize = Enum.AutomaticSize.Y
	holder.Size = UDim2.new(1, 0, 0, 0)
	holder.LayoutOrder = order
	holder.Parent = parent
	local stack = Instance.new("UIListLayout")
	stack.Padding = UDim.new(0, 6)
	stack.SortOrder = Enum.SortOrder.LayoutOrder
	stack.Parent = holder

	local addRow = Instance.new("Frame")
	addRow.BackgroundTransparency = 1
	addRow.Size = UDim2.new(1, 0, 0, 32)
	addRow.LayoutOrder = 1
	addRow.Parent = holder

	local box = Instance.new("TextBox")
	box.BackgroundColor3 = LP.Bg
	box.BorderSizePixel = 0
	box.ClearTextOnFocus = false
	box.PlaceholderText = "Roblox username"
	box.PlaceholderColor3 = LP.TextDisabled
	box.Text = ""
	box.FontFace = Theme.Font.Label
	box.TextSize = Theme.TextSize.SM
	box.TextColor3 = LP.TextPrimary
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.Size = UDim2.new(1, -(ROLE_PICKER_W + 112), 1, 0)
	box.Parent = addRow
	local boxCorner = Instance.new("UICorner"); boxCorner.CornerRadius = UDim.new(0, 4); boxCorner.Parent = box
	local boxStroke = Instance.new("UIStroke"); boxStroke.Color = LP.StrokeSoft; boxStroke.Thickness = 1; boxStroke.Parent = box
	local boxPad = Instance.new("UIPadding")
	boxPad.PaddingLeft = UDim.new(0, 10); boxPad.PaddingRight = UDim.new(0, 10)
	boxPad.Parent = box

	local pickRole = "builder"
	local picker = Dropdown.new({
		parent = addRow,
		options = ROLE_OPTIONS,
		value = pickRole,
		width = ROLE_PICKER_W,
		onChange = function(value)
			pickRole = tostring(value)
		end,
	})
	picker.Instance.AnchorPoint = Vector2.new(1, 0.5)
	picker.Instance.Position = UDim2.new(1, -100, 0.5, 0)

	local err = Instance.new("TextLabel")
	err.BackgroundTransparency = 1
	err.FontFace = Theme.Font.Label
	err.TextSize = Theme.TextSize.XS
	err.TextColor3 = LP.Danger
	err.TextXAlignment = Enum.TextXAlignment.Left
	err.TextWrapped = true
	err.Text = ""
	err.Size = UDim2.new(1, 0, 0, 14)
	err.LayoutOrder = 2
	err.Parent = holder

	local rows = Instance.new("Frame")
	rows.BackgroundTransparency = 1
	rows.AutomaticSize = Enum.AutomaticSize.Y
	rows.Size = UDim2.new(1, 0, 0, 0)
	rows.LayoutOrder = 3
	rows.Parent = holder
	local rowList = Instance.new("UIListLayout")
	rowList.Padding = UDim.new(0, 4)
	rowList.SortOrder = Enum.SortOrder.LayoutOrder
	rowList.Parent = rows

	local busy = false
	local refresh: () -> ()

	-- Every edit is the same shape: run it off the click thread (a remote yields), put
	-- whatever came back on the error line, and redraw from ops.list() rather than from
	-- what we hoped happened.
	local function run(fn: () -> string?)
		if busy then return end
		busy = true
		err.Text = ""
		task.spawn(function()
			local ok, res = pcall(fn)
			busy = false
			err.Text = if ok then tostring(res or "") else "Could not reach the server."
			refresh()
		end)
	end

	refresh = function()
		for _, child in rows:GetChildren() do
			if child:IsA("GuiObject") then child:Destroy() end
		end
		local entries = ops.list()
		if #entries == 0 then
			local none = Instance.new("TextLabel")
			none.BackgroundTransparency = 1
			none.FontFace = Theme.Font.Label
			none.TextSize = Theme.TextSize.XS
			none.TextColor3 = LP.TextDisabled
			none.TextXAlignment = Enum.TextXAlignment.Left
			none.Text = "Nobody else can join this city yet."
			none.Size = UDim2.new(1, 0, 0, 22)
			none.Parent = rows
			return
		end
		for i, entry in entries do
			local row = Instance.new("Frame")
			row.BackgroundColor3 = LP.Bg
			row.BackgroundTransparency = 0.35
			row.BorderSizePixel = 0
			row.Size = UDim2.new(1, 0, 0, 34)
			row.LayoutOrder = i
			row.Parent = rows
			local rc = Instance.new("UICorner"); rc.CornerRadius = UDim.new(0, 4); rc.Parent = row
			local rp = Instance.new("UIPadding")
			rp.PaddingLeft = UDim.new(0, 10); rp.PaddingRight = UDim.new(0, 8)
			rp.Parent = row

			local who = Instance.new("TextLabel")
			who.BackgroundTransparency = 1
			who.FontFace = Theme.Font.Label
			who.TextSize = Theme.TextSize.SM
			who.TextColor3 = LP.TextPrimary
			who.TextXAlignment = Enum.TextXAlignment.Left
			who.TextTruncate = Enum.TextTruncate.AtEnd
			who.Text = tostring(entry.name)
			who.Size = UDim2.new(1, -(ROLE_PICKER_W + 58), 1, 0)
			who.Parent = row

			-- The role IS the control, not a caption beside one: picking from the list
			-- re-grants. Changing somebody's role was otherwise remove-then-retype.
			local chip = Dropdown.new({
				parent = row,
				options = ROLE_OPTIONS,
				value = entry.role,
				width = ROLE_PICKER_W,
				onChange = function(value)
					run(function()
						return ops.setRole(entry.name, tostring(value))
					end)
				end,
			})
			chip.Instance.AnchorPoint = Vector2.new(1, 0.5)
			chip.Instance.Position = UDim2.new(1, -34, 0.5, 0)

			local kill = Instance.new("TextButton")
			kill.AutoButtonColor = false
			kill.BackgroundTransparency = 1
			kill.Text = "\u{2715}"
			kill.FontFace = MenuScreenView.GLYPH_FONT
			kill.TextSize = Theme.TextSize.SM
			kill.TextColor3 = LP.TextSecondary
			kill.AnchorPoint = Vector2.new(1, 0.5)
			kill.Position = UDim2.new(1, 0, 0.5, 0)
			kill.Size = UDim2.fromOffset(26, 26)
			kill.Parent = row
			kill.MouseEnter:Connect(function() kill.TextColor3 = LP.Danger end)
			kill.MouseLeave:Connect(function() kill.TextColor3 = LP.TextSecondary end)
			kill.Activated:Connect(function()
				SoundFX.play("Click")
				run(function()
					return ops.remove(entry.name)
				end)
			end)
		end
	end

	local invite = Button.new({
		text = "INVITE",
		compact = true,
		parent = addRow,
		palette = LP,
		onClick = function()
			local name = (string.gsub(box.Text, "%s", ""))
			if #name == 0 then
				err.Text = "Type a Roblox username first."
				return
			end
			run(function()
				local failed = ops.add(name, pickRole)
				if not failed then box.Text = "" end
				return failed
			end)
		end,
	})
	invite.Instance.AnchorPoint = Vector2.new(1, 0.5)
	invite.Instance.Position = UDim2.new(1, 0, 0.5, 0)

	refresh()
	return refresh
end

local TILE_GAP = 12
local TILE_COLUMNS = 5
local TILE_NAME_H = 46
local HERO_H = 220
-- Every row minimap is its own EditableImage; past this many rows a plain swatch stands in.
-- ponytail: flat cap, page the list if friend cities ever run into the dozens.
local ROW_THUMBS = 12

local function spacer(parent: Instance, order: number, h: number)
	local f = Instance.new("Frame")
	f.BackgroundTransparency = 1
	f.Size = UDim2.new(1, 0, 0, h)
	f.LayoutOrder = order
	f.Parent = parent
end

-- "3 days ago", falling back to the date once it is old enough that the date says more.
local function ago(stamp: any): string
	local t = tonumber(stamp)
	if not t or t <= 0 then return "never played" end
	local d = os.time() - t
	if d < 60 then return "just now" end
	if d < 3600 then return string.format("%d min ago", d // 60) end
	if d < 86400 then return string.format("%d h ago", d // 3600) end
	if d < 2 * 86400 then return "yesterday" end
	if d < 30 * 86400 then return string.format("%d days ago", d // 86400) end
	return os.date("%d %b %Y", t)
end

-- ===== NEW GAME: choose a map, then found the city =====

local _mapScreen: MenuScreenView.Screen? = nil
local _mapStage = 1
local setMapStage: (number) -> () = function() end
local selectMap: (string) -> () = function() end
local _selectedMapId = MapPresets.DEFAULT_ID
local _gen: { [string]: any } = MapPresets.genOf(MapPresets.getOrDefault(MapPresets.DEFAULT_ID))
local _selectedDifficulty = "Normal"
local _selectedTheme = WorldThemeCatalog.DEFAULT_ID
local _drivingSide = "Right"
local _sandbox = false
-- Solo or multiplayer, fixed at creation. Defaults solo: a city nobody asked to share
-- stays private.
local _multiplayer = false
-- Preset motorways, 0 for none. Not in `_gen`: it shapes no terrain.
local _highways = 1
local _createBusy = false
-- Players named on the multiplayer tab, granted their role the moment the city exists.
local _createInvites: { { name: string, role: string } } = {}
local _resetCreateForm: () -> () = function() end

local function submitCreate(nameBox: TextBox, errLabel: TextLabel)
	if _createBusy then
		return
	end
	_createBusy = true
	errLabel.Text = ""

	task.spawn(function()
		local req: { [string]: any } = {
			name = nameBox.Text,
			mapId = _selectedMapId,
			difficulty = _selectedDifficulty,
			theme = _selectedTheme,
			drivingSide = _drivingSide,
			sandbox = _sandbox,
			multiplayer = _multiplayer,
			highways = _highways,
			-- Only ever sent for a shared city: a solo one admits nobody, so a role would
			-- be a promise the join gate will not keep.
			invites = if _multiplayer then _createInvites else nil,
			gen = _gen,
		}
		local ok, success, payload = pcall(Net.RequestCreateSlot.InvokeServer, Net.RequestCreateSlot, req)
		_createBusy = false

		if ok and success == true and typeof(payload) == "table" and typeof(payload.slotId) == "number" then
			if _mapScreen then _mapScreen.hide() end
			refreshSlotIndex()
			startCityLoad(payload.slotId)
		else
			errLabel.Text = if ok and typeof(payload) == "string" then payload else "Could not create the city. Try again."
		end
	end)
end

local function buildMapScreen(): MenuScreenView.Screen
	local screen = MenuScreenView.screen(playerGui, "NewCityScreen", "Select Map", function()
		if _mapStage == 2 then
			setMapStage(1)
		else
			if _mapScreen then _mapScreen.hide() end
			setMenuPanelVisible(true)
		end
	end)
	local C = Theme.Color
	local tracked = MenuScreenView.tracked

	local grid: ScrollingFrame, customEmpty: Frame, cityForm: ScrollingFrame, mpForm: ScrollingFrame
	local action: MenuScreenView.ActionButton
	local mapCount = 0
	local mapTabs = MenuScreenView.pills(screen.tabs, { "Default Maps", "Custom Maps" }, true, function(i)
		grid.Visible = i == 1
		customEmpty.Visible = i == 2
		screen.barLabel.Text = if i == 1 then tracked(mapCount .. " maps") else tracked("Creator Shop")
		action.setEnabled(i == 1)
	end)
	local cityTabs = MenuScreenView.pills(screen.tabs, { "City", "Multiplayer" }, true, function(i)
		cityForm.Visible = i == 1
		mpForm.Visible = i == 2
	end)

	-- LEFT, stage 1: the premade maps as minimap tiles, the name set over each one.
	grid = MenuScreenView.scroller(screen.left, 20, 22, 0)
	grid.Name = "Grid"
	;(grid:FindFirstChildOfClass("UIListLayout") :: UIListLayout):Destroy()
	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellPadding = UDim2.fromOffset(TILE_GAP, TILE_GAP)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.Parent = grid
	local function fitTiles()
		local w = math.floor((grid.AbsoluteSize.X - 44 - 6 - TILE_GAP * (TILE_COLUMNS - 1)) / TILE_COLUMNS)
		if w > 0 then
			gridLayout.CellSize = UDim2.fromOffset(w, w)
		end
	end
	grid:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitTiles)
	fitTiles()

	local tiles: { [string]: (boolean) -> () } = {}
	for _, preset in MapPresets.List do
		-- Player-made maps are off for now; see MapPresets.PLAYER_MAPS_ENABLED.
		if preset.generated and not MapPresets.PLAYER_MAPS_ENABLED then continue end
		mapCount += 1
		local tile = Instance.new("TextButton")
		tile.Name = preset.id
		tile.AutoButtonColor = false
		tile.Text = ""
		tile.BackgroundColor3 = C.Bg
		tile.BorderSizePixel = 0
		tile.LayoutOrder = mapCount
		tile.Parent = grid
		MenuScreenView.corner(tile, 10)

		local thumb, thumbImg = MapPreview.create(96)
		thumb.Size = UDim2.fromScale(1, 1)
		thumb.ScaleType = Enum.ScaleType.Crop
		thumb.Parent = tile
		MenuScreenView.corner(thumb, 10)
		MapPreview.paint(thumbImg, MapPresets.genOf(preset) :: any, 96)

		local shade = Instance.new("Frame")
		shade.BackgroundColor3 = Color3.new(0, 0, 0)
		shade.BorderSizePixel = 0
		shade.AnchorPoint = Vector2.new(0, 1)
		shade.Position = UDim2.fromScale(0, 1)
		shade.Size = UDim2.new(1, 0, 0, TILE_NAME_H)
		shade.Parent = thumb
		MenuScreenView.corner(shade, 10)
		local sg = Instance.new("UIGradient")
		sg.Rotation = 90
		sg.Transparency = NumberSequence.new(1, 0.15)
		sg.Parent = shade

		local name = MenuScreenView.label(thumb, preset.name, Theme.Font.Bold, 14, C.TextPrimary)
		name.AnchorPoint = Vector2.new(0, 1)
		name.Position = UDim2.new(0, 10, 1, -8)
		name.Size = UDim2.new(1, -20, 0, 18)
		name.ZIndex = 2

		local ring = MenuScreenView.stroke(tile, C.Accent, 1, 2.5)
		local badge = MenuScreenView.label(tile, "\u{2713}", MenuScreenView.GLYPH_FONT, 13, C.OnAccent)
		badge.TextXAlignment = Enum.TextXAlignment.Center
		badge.BackgroundColor3 = C.Accent
		badge.BackgroundTransparency = 0
		badge.AnchorPoint = Vector2.new(1, 0)
		badge.Position = UDim2.new(1, -8, 0, 8)
		badge.Size = UDim2.fromOffset(22, 22)
		badge.ZIndex = 3
		MenuScreenView.corner(badge, 11)

		local selected = false
		local function paint(hover: boolean)
			ring.Color = if selected then C.Accent else C.TextPrimary
			ring.Transparency = if selected then 0 elseif hover then 0.45 else 1
			badge.Visible = selected
			thumb.ImageTransparency = if selected or hover then 0 else 0.15
		end
		tile.MouseEnter:Connect(function() paint(true) end)
		tile.MouseLeave:Connect(function() paint(false) end)
		tile.Activated:Connect(function()
			SoundFX.play("Click")
			selectMap(preset.id)
		end)
		-- Double-click goes straight on, like picking and pressing SELECT MAP.
		local lastClick = 0
		tile.MouseButton1Up:Connect(function()
			local now = os.clock()
			if now - lastClick < 0.35 then setMapStage(2) end
			lastClick = now
		end)
		tiles[preset.id] = function(on: boolean)
			selected = on
			paint(false)
		end
		paint(false)
	end

	-- LEFT, stage 1, custom tab: maps from the Creator Shop. None can be had yet.
	customEmpty = MenuScreenView.emptyState(screen.left, "No custom maps yet",
		"Maps you get from the Creator Shop will show up here.")
	customEmpty.Visible = false

	-- LEFT, stage 2, CITY tab: the choices in cards, one card per kind of choice.
	cityForm = MenuScreenView.scroller(screen.left, 20, 22, 12)
	cityForm.Name = "CityForm"
	local nameCard = MenuScreenView.card(cityForm, 1)
	MenuScreenView.caption(nameCard, "City name", 1)
	local nameBox = MenuScreenView.textField(nameCard, "New City", 2)

	local placeCard = MenuScreenView.card(cityForm, 2)
	MenuScreenView.caption(placeCard, "Region", 1)
	local themeIds: { string } = {}
	local themeNames: { string } = {}
	for _, theme in WorldThemeCatalog.List do
		if theme.implemented then
			table.insert(themeIds, theme.id)
			table.insert(themeNames, theme.name)
		end
	end
	local themePills = MenuScreenView.pills(placeCard, themeNames, false, function(i)
		_selectedTheme = themeIds[i]
	end)
	themePills.Instance.LayoutOrder = 2
	spacer(placeCard, 3, 2)
	MenuScreenView.caption(placeCard, "Driving side", 4)
	local sidePills = MenuScreenView.pills(placeCard, { "Right-hand", "Left-hand" }, false, function(i)
		_drivingSide = if i == 2 then "Left" else "Right"
	end)
	sidePills.Instance.LayoutOrder = 5

	local rulesCard = MenuScreenView.card(cityForm, 3)
	MenuScreenView.caption(rulesCard, "Rules", 1)
	local diffHolder = Instance.new("Frame")
	local sandboxRow = MenuScreenView.toggleRow(rulesCard, "Sandbox",
		"Unlimited money and everything unlocked from the start. Nothing can go bankrupt.", 2,
		function(on)
			_sandbox = on
			diffHolder.Visible = not on
		end)
	diffHolder.Name = "Difficulty"
	diffHolder.BackgroundTransparency = 1
	diffHolder.AutomaticSize = Enum.AutomaticSize.Y
	diffHolder.Size = UDim2.new(1, 0, 0, 0)
	diffHolder.LayoutOrder = 3
	diffHolder.Parent = rulesCard
	MenuScreenView.list(diffHolder, 10)
	spacer(diffHolder, 1, 2)
	MenuScreenView.caption(diffHolder, "Difficulty", 2)
	local diffPills = MenuScreenView.pills(diffHolder, DIFFICULTIES, false, function(i)
		_selectedDifficulty = DIFFICULTIES[i]
	end)
	diffPills.Instance.LayoutOrder = 3

	local roadCard = MenuScreenView.card(cityForm, 4)
	MenuScreenView.caption(roadCard, "Starting highways", 1)
	local highwayPills = MenuScreenView.pills(roadCard, HIGHWAY_CHOICES, false, function(i)
		_highways = i - 1
	end)
	highwayPills.Instance.LayoutOrder = 2
	MenuScreenView.note(roadCard, "Motorways laid across the map when it is founded, so the city starts connected.", 3)

	local errLabel = MenuScreenView.note(cityForm, "", 5)
	errLabel.TextColor3 = LP.Danger

	-- LEFT, stage 2, MULTIPLAYER tab.
	mpForm = MenuScreenView.scroller(screen.left, 20, 22, 12)
	mpForm.Name = "MultiplayerForm"
	local joinCard = MenuScreenView.card(mpForm, 1)
	local invitesCard: Frame
	local mpRow = MenuScreenView.toggleRow(joinCard, "Multiplayer City",
		"Let other players in, up to 10 at a time. You choose who, and whether they can build. Fixed once the city is founded.", 1,
		function(on)
			_multiplayer = on
			invitesCard.Visible = on
		end)
	spacer(joinCard, 2, 4)
	local openHouse = MenuScreenView.toggleRow(joinCard, "Open House",
		"The players you invite can open your city while you are away. Applies to every city you own.", 3,
		function(on)
			Settings.set("friendsOffline", on)
		end)
	invitesCard = MenuScreenView.card(mpForm, 2)
	MenuScreenView.caption(invitesCard, "Who can join", 1)
	-- Local ops: there is no city yet, so the rows are held until the create request
	-- carries them. The server resolves each name against Roblox then.
	local inviteRefresh = buildAccessEditor(invitesCard, 2, {
		list = function()
			return _createInvites
		end,
		add = function(name: string, role: string): string?
			if #_createInvites >= MAX_CREATE_INVITES then
				return "You can name " .. MAX_CREATE_INVITES .. " players here \u{2014} invite the rest from City Options."
			end
			for _, entry in _createInvites do
				if entry.name:lower() == name:lower() then return "They are already on the list." end
			end
			table.insert(_createInvites, { name = name, role = role })
			return nil
		end,
		remove = function(name: string): string?
			for i, entry in _createInvites do
				if entry.name == name then
					table.remove(_createInvites, i)
					break
				end
			end
			return nil
		end,
		setRole = function(name: string, role: string): string?
			for _, entry in _createInvites do
				if entry.name == name then entry.role = role end
			end
			return nil
		end,
	})

	-- RIGHT: the chosen map, in both stages.
	local detail = MenuScreenView.scroller(screen.right, 18, 18, 10)
	local heroLabel, heroImg = MapPreview.create()
	local hero = MenuScreenView.hero(detail, heroLabel, 1, HERO_H)
	local desc = MenuScreenView.note(detail, "", 2)
	desc.TextSize = 15
	local landmass = MenuScreenView.statRow(detail, "Landmass", 3)
	local relief = MenuScreenView.statRow(detail, "Relief", 4)
	spacer(detail, 5, 4)
	MenuScreenView.caption(detail, "Natural resources", 6)
	local setResources = MainMenuView.makeResourceMeters(detail, 7, nil)

	action = MenuScreenView.actionButton(screen.footer, "Select Map", true, 1, function()
		if _mapStage == 1 then
			setMapStage(2)
		else
			submitCreate(nameBox, errLabel)
		end
	end)

	selectMap = function(mapId: string)
		local preset = MapPresets.get(mapId)
		if not preset then return end
		_selectedMapId = preset.id
		_gen = MapPresets.genOf(preset)
		for id, setSelected in tiles do
			setSelected(id == preset.id)
		end
		local shape = MapPresets.getShape(_gen.shape)
		hero.name.Text = preset.name
		hero.sub.Text = tracked(if shape then shape.name else "Continent")
		desc.Text = preset.description
		landmass.Text = if shape then shape.name else "Continent"
		relief.Text = reliefWord(tonumber(_gen.heightRange) or 0)
		setResources(MapResources.of(_gen :: any, preset.resources))
		MapPreview.paint(heroImg, _gen :: any)
	end

	setMapStage = function(n: number)
		_mapStage = n
		screen.title.Text = if n == 1 then "SELECT MAP" else "NEW CITY"
		screen.barLabel.Text = if n == 1 then tracked(mapCount .. " maps") else tracked("City setup")
		mapTabs.Instance.Visible = n == 1
		cityTabs.Instance.Visible = n == 2
		mapTabs.select(1)
		cityTabs.select(1)
		grid.Visible = n == 1
		customEmpty.Visible = false
		cityForm.Visible = n == 2
		mpForm.Visible = false
		action.setText(if n == 1 then "Select Map" else "Found City")
		action.setEnabled(true)
	end

	_resetCreateForm = function()
		nameBox.Text = ""
		errLabel.Text = ""
		_selectedDifficulty = "Normal"
		diffPills.select(indexOf(DIFFICULTIES, "Normal"))
		_selectedTheme = WorldThemeCatalog.DEFAULT_ID
		themePills.select(table.find(themeIds, _selectedTheme) or 1)
		_drivingSide = "Right"
		sidePills.select(1)
		_sandbox = false
		sandboxRow.set(false)
		diffHolder.Visible = true
		_highways = 1
		highwayPills.select(2)
		_multiplayer = false
		mpRow.set(false)
		invitesCard.Visible = false
		openHouse.set(Settings.get("friendsOffline") == true)
		table.clear(_createInvites)
		inviteRefresh()
		selectMap(MapPresets.DEFAULT_ID)
		setMapStage(1)
	end

	return screen
end

local function openCreateModal()
	if #getSlots() >= getMaxSlots() then
		showErrorModal("All city slots are full. Delete a city first.")
		return
	end
	if not _mapScreen then _mapScreen = buildMapScreen() end
	_resetCreateForm()
	setMenuPanelVisible(false)
	;(_mapScreen :: MenuScreenView.Screen).show()
end

-- ===== LOAD GAME: your cities, then one city's options =====

local _loadScreen: MenuScreenView.Screen? = nil
local _loadStage = 1
local setLoadStage: (number) -> () = function() end
local rebuildLoadList: () -> () = function() end
local selectLoadSlot: (any) -> () = function() end
local _loadSelectedMeta: any = nil
local _loadSelectedKey: string? = nil
local SORTS = { "Recent", "Name", "Population" }
local _loadSort = 1

-- Row keys have to carry the owner: slot ids are per-player, so my slot 2 and a friend's
-- slot 2 would otherwise be the same row.
local function rowKey(ownerId: number?, slotId: any): string
	return tostring(ownerId or 0) .. ":" .. tostring(slotId)
end

-- Friends' cities, as the server reported them. Read-only here; every permission
-- question is re-answered server-side when LOAD actually fires.
local _friendCities: { any } = {}

local function refreshFriendCities(onDone: (() -> ())?)
	task.spawn(function()
		local ok, res = pcall(function()
			return Net.RequestFriendCities:InvokeServer()
		end)
		if ok and typeof(res) == "table" and res.ok and typeof(res.friends) == "table" then
			_friendCities = res.friends
		else
			_friendCities = {}
		end
		if onDone then onDone() end
	end)
end

local function formatPlaytime(meta: any): string
	local secs = tonumber(meta.playtimeSeconds) or 0
	return string.format("%dh %dm", math.floor(secs / 3600), math.floor((secs % 3600) / 60))
end

local function formatPopulation(meta: any): string
	local digits = tostring(math.floor(tonumber(meta.population) or 0))
	return (digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

local function gameModeOf(meta: any): string
	return if meta.sandbox == true then "Sandbox" else tostring(meta.difficulty or "Normal")
end

local function isFriendRow(meta: any): boolean
	return meta ~= nil and meta.__ownerId ~= nil
end

local function mapNameOf(meta: any): string
	local preset = MapPresets.get(tostring(meta.mapId))
	return if preset then preset.name else "Unknown map"
end

local function invokeRename(slotId: number, newName: string)
	task.spawn(function()
		local ok, success, payload = pcall(Net.RequestRenameSlot.InvokeServer, Net.RequestRenameSlot, slotId, newName)
		if ok and success == true then
			refreshSlotIndex(rebuildLoadList)
		else
			showErrorModal(if ok and typeof(payload) == "string" then payload else "Rename failed. Try again.")
			rebuildLoadList()
		end
	end)
end

local function invokeDelete(slotId: number)
	task.spawn(function()
		local ok, success, payload = pcall(Net.RequestDeleteSlot.InvokeServer, Net.RequestDeleteSlot, slotId)
		if ok and success == true then
			setLoadStage(1)
			refreshSlotIndex(rebuildLoadList)
		else
			showErrorModal(if ok and typeof(payload) == "string" then payload else "Delete failed. Try again.")
		end
	end)
end

local _confirmModal: any = nil
local _confirmLabel: TextLabel? = nil
local _confirmSlotId: number? = nil

local function openDeleteConfirm(meta: any)
	if not _confirmModal then
		_confirmModal = Modal.new({
			size = UDim2.fromOffset(380, 230),
			title = "DELETE CITY",
			name = "DeleteCityModal",
			onClose = function()
				_confirmModal:Hide()
			end,
		})
		glassifyModal(_confirmModal)
		setupContent(_confirmModal.Content)

		local label = makeLabel(_confirmModal.Content, "", 1, true)
		label.TextWrapped = true
		label.Size = UDim2.new(1, 0, 0, 100)
		_confirmLabel = label

		local footer, footerList = makeRow(_confirmModal.Content, 2, 36)
		footerList.HorizontalAlignment = Enum.HorizontalAlignment.Right
		Button.new({ text = "CANCEL", parent = footer, layoutOrder = 1, onClick = function()
			_confirmModal:Hide()
		end })
		Button.new({ text = "DELETE", variant = "Danger", parent = footer, layoutOrder = 2, onClick = function()
			local slotId = _confirmSlotId
			_confirmModal:Hide()
			if slotId then
				invokeDelete(slotId)
			end
		end })
	end

	_confirmSlotId = tonumber(meta.slotId)
	local label = _confirmLabel :: TextLabel
	label.Text = string.format(
		"Delete \"%s\"?\n\nPopulation: %s\nPlaytime: %s\n\nThis cannot be undone.",
		tostring(meta.cityName or "City"),
		formatPopulation(meta),
		formatPlaytime(meta)
	)
	_confirmModal:Show()
end

-- Per-city access calls, against the city open on City Options. The server answers with
-- the whole list, and a refusal comes back as a message rather than a silently unchanged
-- screen.
local _accessSlotId: number? = nil
local _accessEntries: { any } = {}

local function accessInvoke(payload: any): string?
	payload.slotId = _accessSlotId
	local ok, res = pcall(function()
		return Net.RequestCityAccess:InvokeServer(payload)
	end)
	if not ok or typeof(res) ~= "table" then return "Could not reach the server." end
	if typeof(res.entries) == "table" then _accessEntries = res.entries end
	if res.ok ~= true then return tostring(res.error or "Could not change that.") end
	return nil
end

local function sharingInvoke(on: boolean?): any
	local ok, res = pcall(function()
		return Net.RequestCitySharing:InvokeServer(on, _accessSlotId)
	end)
	if not ok or typeof(res) ~= "table" then
		return { ok = false, error = "Could not reach the server." }
	end
	return res
end

local function buildLoadScreen(): MenuScreenView.Screen
	local screen = MenuScreenView.screen(playerGui, "LoadGameScreen", "Load Game", function()
		if _loadStage == 2 then
			setLoadStage(1)
		else
			if _loadScreen then _loadScreen.hide() end
			setMenuPanelVisible(true)
		end
	end)
	local C = Theme.Color
	local tracked = MenuScreenView.tracked

	local cityForm: ScrollingFrame, mpForm: ScrollingFrame
	local sortPills = MenuScreenView.pills(screen.tabs, SORTS, true, function(i)
		_loadSort = i
		rebuildLoadList()
	end)
	sortPills.select(_loadSort)
	local optionTabs = MenuScreenView.pills(screen.tabs, { "City", "Multiplayer" }, true, function(i)
		cityForm.Visible = i == 1
		mpForm.Visible = i == 2
	end)

	-- LEFT, stage 1: the cities, each with its own minimap.
	local listFrame = MenuScreenView.scroller(screen.left, 12, 12, 4)
	listFrame.Name = "Cities"
	local emptyState = MenuScreenView.emptyState(screen.left, "No saved cities", "Found one from NEW GAME on the main menu.")
	emptyState.Visible = false

	-- LEFT, stage 2, CITY tab: the name can still change; what the city was founded with
	-- cannot, so it is shown, not offered.
	cityForm = MenuScreenView.scroller(screen.left, 20, 22, 12)
	cityForm.Name = "CityOptions"
	local nameCard = MenuScreenView.card(cityForm, 1)
	MenuScreenView.caption(nameCard, "City name", 1)
	local nameBox = MenuScreenView.textField(nameCard, "City name", 2)
	nameBox.FocusLost:Connect(function()
		local meta = _loadSelectedMeta
		if not meta or isFriendRow(meta) then return end
		local newName = nameBox.Text
		if newName ~= "" and newName ~= tostring(meta.cityName or "") then
			invokeRename(tonumber(meta.slotId) :: number, newName)
		end
	end)
	MenuScreenView.note(nameCard, "Renames the save as soon as you click away.", 3)

	local foundedCard = MenuScreenView.card(cityForm, 2)
	MenuScreenView.caption(foundedCard, "Founded with", 1)
	MenuScreenView.note(foundedCard, "Locked in when the city was founded.", 2)
	local fixed = {
		region = MenuScreenView.statRow(foundedCard, "Region", 3),
		side = MenuScreenView.statRow(foundedCard, "Driving side", 4),
		rules = MenuScreenView.statRow(foundedCard, "Rules", 5),
		money = MenuScreenView.statRow(foundedCard, "Money", 6),
		unlocks = MenuScreenView.statRow(foundedCard, "Unlocks", 7),
		highways = MenuScreenView.statRow(foundedCard, "Starting highways", 8),
	}

	local deleteRow = Instance.new("Frame")
	deleteRow.BackgroundTransparency = 1
	deleteRow.Size = UDim2.new(1, 0, 0, 40)
	deleteRow.LayoutOrder = 3
	deleteRow.Parent = cityForm
	local deleteBtn = Instance.new("TextButton")
	deleteBtn.Name = "Delete"
	deleteBtn.AutoButtonColor = false
	deleteBtn.BackgroundColor3 = LP.Danger
	deleteBtn.BackgroundTransparency = 1
	deleteBtn.FontFace = Theme.Font.Bold
	deleteBtn.TextSize = 14
	deleteBtn.TextColor3 = LP.Danger
	deleteBtn.Text = "DELETE CITY"
	deleteBtn.AnchorPoint = Vector2.new(1, 0)
	deleteBtn.Position = UDim2.fromScale(1, 0)
	deleteBtn.Size = UDim2.fromOffset(160, 40)
	deleteBtn.Parent = deleteRow
	MenuScreenView.corner(deleteBtn, 999)
	MenuScreenView.stroke(deleteBtn, LP.Danger, 0.3)
	deleteBtn.MouseEnter:Connect(function() deleteBtn.BackgroundTransparency = 0.82 end)
	deleteBtn.MouseLeave:Connect(function() deleteBtn.BackgroundTransparency = 1 end)
	deleteBtn.Activated:Connect(function()
		if _loadSelectedMeta and not isFriendRow(_loadSelectedMeta) then
			SoundFX.play("Click")
			openDeleteConfirm(_loadSelectedMeta)
		end
	end)

	-- LEFT, stage 2, MULTIPLAYER tab: the switches that decide whether roles mean anything,
	-- then the roles themselves.
	mpForm = MenuScreenView.scroller(screen.left, 20, 22, 12)
	mpForm.Name = "MultiplayerOptions"
	local joinCard = MenuScreenView.card(mpForm, 1)
	local mpRow: MenuScreenView.ToggleRow
	local mpError = MenuScreenView.note(joinCard, "", 2)
	mpError.TextColor3 = LP.Danger
	mpRow = MenuScreenView.toggleRow(joinCard, "Multiplayer",
		"Off, this city is yours alone \u{2014} nobody else can open it or join it, whatever role they hold.", 1,
		function(on)
			-- The switch shows what the SERVER has, so a refusal puts it back.
			task.spawn(function()
				local res = sharingInvoke(on)
				mpError.Text = if res.ok then "" else tostring(res.error or "")
				if not res.ok then mpRow.set(not on) end
			end)
		end)
	spacer(joinCard, 3, 4)
	local openHouse = MenuScreenView.toggleRow(joinCard, "Open House",
		"The people below can open your city while you are away. Applies to every city you own.", 4,
		function(on)
			Settings.set("friendsOffline", on)
		end)
	local accessCard = MenuScreenView.card(mpForm, 2)
	MenuScreenView.caption(accessCard, "Who can join", 1)
	local accessRefresh = buildAccessEditor(accessCard, 2, {
		list = function()
			return _accessEntries
		end,
		add = function(name: string, role: string): string?
			return accessInvoke({ action = "grant", name = name, role = role })
		end,
		remove = function(name: string): string?
			return accessInvoke({ action = "revoke", name = name })
		end,
		-- A role change IS a re-grant: same remote, same checks as handing it out first time.
		setRole = function(name: string, role: string): string?
			return accessInvoke({ action = "grant", name = name, role = role })
		end,
	})

	-- RIGHT: the selected city, in both stages.
	local detail = MenuScreenView.scroller(screen.right, 18, 18, 8)
	local heroLabel, previewImg = MapPreview.create()
	local hero = MenuScreenView.hero(detail, heroLabel, 1, HERO_H)
	local ownerNote = MenuScreenView.note(detail, "", 2)
	ownerNote.TextColor3 = C.Accent
	local rows = {
		mode = MenuScreenView.statRow(detail, "Game mode", 3),
		population = MenuScreenView.statRow(detail, "Population", 4),
		playtime = MenuScreenView.statRow(detail, "Playtime", 5),
		played = MenuScreenView.statRow(detail, "Last played", 6),
		map = MenuScreenView.statRow(detail, "Map", 7),
		region = MenuScreenView.statRow(detail, "Region", 8),
		multiplayer = MenuScreenView.statRow(detail, "Multiplayer", 9),
	}

	local loadBtn = MenuScreenView.actionButton(screen.footer, "Load City", true, 1, function()
		local meta = _loadSelectedMeta
		if not meta then return end
		if _loadScreen then _loadScreen.hide() end
		startCityLoad(tonumber(meta.slotId) :: number, tonumber(meta.__ownerId))
	end)
	local optionsBtn = MenuScreenView.actionButton(screen.footer, "City Options", false, 2, function()
		setLoadStage(if _loadStage == 1 then 2 else 1)
	end)

	local function refreshOptions()
		local meta = _loadSelectedMeta
		if not meta or isFriendRow(meta) then return end
		nameBox.Text = tostring(meta.cityName or "")
		fixed.region.Text = themeName(meta.theme)
		fixed.side.Text = if meta.drivingSide == "Left" then "Left-hand" else "Right-hand"
		fixed.rules.Text = gameModeOf(meta)
		fixed.money.Text = if meta.sandbox == true then "Unlimited" else "Earned"
		fixed.unlocks.Text = if meta.sandbox == true then "Everything" else "By milestone"
		local hw = tonumber(meta.highways) or 0
		fixed.highways.Text = if hw == 0 then "None" else tostring(hw)
	end

	local function openMultiplayerOptions(meta: any)
		_accessSlotId = tonumber(meta.slotId)
		_accessEntries = {}
		mpError.Text = ""
		openHouse.set(Settings.get("friendsOffline") == true)
		mpRow.set(meta.multiplayer == true)
		accessRefresh()
		task.spawn(function()
			local sharing = sharingInvoke(nil)
			if sharing.ok == true then mpRow.set(sharing.multiplayer == true) end
			local failed = accessInvoke({ action = "list" })
			mpError.Text = failed or (if sharing.ok then "" else tostring(sharing.error or ""))
			accessRefresh()
		end)
	end

	local slotCount = 0
	setLoadStage = function(n: number)
		local meta = _loadSelectedMeta
		if n == 2 and (not meta or isFriendRow(meta)) then return end
		_loadStage = n
		screen.title.Text = if n == 1 then "LOAD GAME" else "CITY OPTIONS"
		screen.barLabel.Text = if n == 1 then tracked(slotCount .. (if slotCount == 1 then " city" else " cities"))
			else tracked(tostring(meta.cityName or "City"))
		sortPills.Instance.Visible = n == 1
		optionTabs.Instance.Visible = n == 2
		optionTabs.select(1)
		listFrame.Visible = n == 1 and meta ~= nil
		emptyState.Visible = n == 1 and meta == nil
		cityForm.Visible = n == 2
		mpForm.Visible = false
		optionsBtn.setText(if n == 1 then "City Options" else "All Cities")
		if n == 2 then
			refreshOptions()
			openMultiplayerOptions(meta)
		end
	end

	local rowPainters: { [string]: (boolean) -> () } = {}

	selectLoadSlot = function(meta: any)
		_loadSelectedMeta = meta
		loadBtn.setEnabled(meta ~= nil)
		optionsBtn.setEnabled(meta ~= nil and not isFriendRow(meta))
		detail.Visible = meta ~= nil
		if not meta then
			_loadSelectedKey = nil
			return
		end
		_loadSelectedKey = rowKey(tonumber(meta.__ownerId), tonumber(meta.slotId))
		for key, paint in rowPainters do
			paint(key == _loadSelectedKey)
		end

		hero.name.Text = tostring(meta.cityName or "City")
		hero.sub.Text = tracked(mapNameOf(meta))
		ownerNote.Text = if isFriendRow(meta)
			then string.format("%s's city  \u{00B7}  you are %s%s", tostring(meta.__ownerName),
				string.lower(CityRoles.Label[meta.__role] or tostring(meta.__role)),
				if meta.__canOpen then "" else "  \u{00B7}  the owner must be online")
			else ""
		ownerNote.Visible = ownerNote.Text ~= ""
		rows.mode.Text = gameModeOf(meta)
		rows.population.Text = formatPopulation(meta)
		rows.playtime.Text = formatPlaytime(meta)
		rows.played.Text = ago(meta.lastPlayedTimestamp)
		rows.map.Text = mapNameOf(meta)
		rows.region.Text = themeName(meta.theme)
		rows.multiplayer.Text = if meta.multiplayer == true then "Shared" else "Solo"
		local preset = MapPresets.get(tostring(meta.mapId))
		if preset then
			-- The slot's own knobs when it has them: a city made on the current generator looks
			-- nothing like its preset's legacy formula.
			local gen = if typeof(meta.gen) == "table" then meta.gen
				else { seed = preset.seed, heightRange = preset.relief, oceanLevel = 0, baseHeight = 0, ruggedness = 0, shape = "continent", persistence = 0.5, lacunarity = 2.0 }
			MapPreview.paint(previewImg, gen :: any)
		end
		if _loadStage == 2 then
			screen.barLabel.Text = tracked(tostring(meta.cityName or "City"))
			refreshOptions()
		end
	end

	rebuildLoadList = function()
		for _, child in listFrame:GetChildren() do
			if child:IsA("GuiObject") then child:Destroy() end
		end
		table.clear(rowPainters)

		-- Mine, then any city a friend has given me a role in. A friend's row carries
		-- __ownerId, which is what turns LOAD into "open their city" and what keeps
		-- CITY OPTIONS for the owner alone.
		local slots = {}
		for _, meta in getSlots() do
			table.insert(slots, meta)
		end
		for _, friend in _friendCities do
			if typeof(friend.slots) == "table" then
				for _, meta in friend.slots do
					local copy = table.clone(meta)
					copy.__ownerId = friend.userId
					copy.__ownerName = friend.name
					copy.__role = meta.role
					copy.__canOpen = meta.canOpen == true
					table.insert(slots, copy)
				end
			end
		end
		slotCount = #slots

		table.sort(slots, function(a, b)
			if _loadSort == 2 then
				return string.lower(tostring(a.cityName)) < string.lower(tostring(b.cityName))
			elseif _loadSort == 3 then
				return (tonumber(a.population) or 0) > (tonumber(b.population) or 0)
			end
			return (tonumber(a.lastPlayedTimestamp) or 0) > (tonumber(b.lastPlayedTimestamp) or 0)
		end)

		for order, meta in slots do
			local key = rowKey(tonumber(meta.__ownerId), tonumber(meta.slotId))
			local row = Instance.new("TextButton")
			row.Name = key
			row.AutoButtonColor = false
			row.Text = ""
			row.BackgroundColor3 = C.BgHover
			row.BackgroundTransparency = 1
			row.BorderSizePixel = 0
			row.Size = UDim2.new(1, 0, 0, 68)
			row.LayoutOrder = order
			row.Parent = listFrame
			MenuScreenView.corner(row, 12)

			local bar = Instance.new("Frame")
			bar.BackgroundColor3 = C.Accent
			bar.BorderSizePixel = 0
			bar.AnchorPoint = Vector2.new(0, 0.5)
			bar.Position = UDim2.new(0, 0, 0.5, 0)
			bar.Size = UDim2.new(0, 3, 0.56, 0)
			bar.Parent = row
			MenuScreenView.corner(bar, 2)

			local preset = MapPresets.get(tostring(meta.mapId))
			local thumb: GuiObject
			if order <= ROW_THUMBS and preset then
				local img, editable = MapPreview.create(64)
				img.ScaleType = Enum.ScaleType.Crop
				local gen = if typeof(meta.gen) == "table" then meta.gen else MapPresets.genOf(preset)
				MapPreview.paint(editable, gen :: any, 64)
				thumb = img
			else
				thumb = Instance.new("Frame")
				thumb.BackgroundColor3 = C.BgRaised
			end
			thumb.BorderSizePixel = 0
			thumb.AnchorPoint = Vector2.new(0, 0.5)
			thumb.Position = UDim2.new(0, 14, 0.5, 0)
			thumb.Size = UDim2.fromOffset(48, 48)
			thumb.Parent = row
			MenuScreenView.corner(thumb, 8)

			local name = MenuScreenView.label(row, tostring(meta.cityName or "City"), Theme.Font.Header, 18, C.TextPrimary)
			name.Position = UDim2.fromOffset(78, 13)
			name.Size = UDim2.new(1, -250, 0, 22)
			local bits = { mapNameOf(meta), gameModeOf(meta) }
			if isFriendRow(meta) then table.insert(bits, 1, tostring(meta.__ownerName) .. "'s city") end
			local sub = MenuScreenView.label(row, table.concat(bits, "  \u{00B7}  "), Theme.Font.Label, 13, C.TextSecondary)
			sub.Position = UDim2.fromOffset(78, 37)
			sub.Size = UDim2.new(1, -250, 0, 18)

			local pop = MenuScreenView.label(row, formatPopulation(meta) .. " people", Theme.Font.Header, 15, C.TextPrimary)
			pop.TextXAlignment = Enum.TextXAlignment.Right
			pop.AnchorPoint = Vector2.new(1, 0)
			pop.Position = UDim2.new(1, -18, 0, 13)
			pop.Size = UDim2.fromOffset(160, 22)
			local when = MenuScreenView.label(row, ago(meta.lastPlayedTimestamp), Theme.Font.Label, 13, C.TextSecondary)
			when.TextXAlignment = Enum.TextXAlignment.Right
			when.AnchorPoint = Vector2.new(1, 0)
			when.Position = UDim2.new(1, -18, 0, 37)
			when.Size = UDim2.fromOffset(160, 18)

			local selected = false
			local function paint(hover: boolean)
				row.BackgroundColor3 = if selected then C.Accent else C.BgHover
				row.BackgroundTransparency = if selected then 0.8 elseif hover then 0.55 else 1
				bar.Visible = selected
			end
			rowPainters[key] = function(on: boolean)
				selected = on
				paint(false)
			end
			row.MouseEnter:Connect(function() paint(true) end)
			row.MouseLeave:Connect(function() paint(false) end)
			row.Activated:Connect(function()
				SoundFX.play("Click")
				selectLoadSlot(meta)
			end)
			paint(false)
		end

		-- Keep the current selection if it still exists, else the top row.
		local target: any = nil
		for _, meta in slots do
			if rowKey(tonumber(meta.__ownerId), tonumber(meta.slotId)) == _loadSelectedKey then target = meta end
		end
		selectLoadSlot(target or slots[1])
		if _loadStage == 1 then
			listFrame.Visible = #slots > 0
			emptyState.Visible = #slots == 0
			screen.barLabel.Text = tracked(#slots .. (if #slots == 1 then " city" else " cities"))
		elseif not target then
			setLoadStage(1)
		end
	end

	setLoadStage(1)
	return screen
end

local function openLoadModal()
	if not _loadScreen then _loadScreen = buildLoadScreen() end
	setLoadStage(1)
	rebuildLoadList()
	refreshSlotIndex(rebuildLoadList)
	refreshFriendCities(rebuildLoadList)
	setMenuPanelVisible(false)
	;(_loadScreen :: MenuScreenView.Screen).show()
end

-- The dim line under CONTINUE. The load list has its own columns;
-- this one has ~230px on the rail, so city + pop + day only.
local function formatContinueMeta(meta: any): string
	local played = tonumber(meta.lastPlayedTimestamp)
	return string.format(
		"%s  \u{00B7}  Pop %d%s",
		tostring(meta.cityName or "City"),
		tonumber(meta.population) or 0,
		if played and played > 0 then "  \u{00B7}  " .. os.date("%d %b", played) else ""
	)
end

updateGameButtonsState = function()
	local continueId = getContinueSlotId()
	local canContinue = continueId ~= nil
	local hasSlots = #getSlots() > 0
	-- Labels are text now: dim the Label (keep the baked image hidden) when unavailable.
	local function setEnabled(btn: ImageButton, enabled: boolean)
		btn.ImageTransparency = 1
		local lbl = btn:FindFirstChild("Label")
		if lbl and lbl:IsA("TextLabel") then
			lbl.TextTransparency = if enabled then 0 else 0.55
		end
		local ico = btn:FindFirstChild("Icon")
		if ico and ico:IsA("ImageLabel") then
			ico.ImageTransparency = if enabled then 0 else 0.55
		end
	end
	-- CONTINUE is the menu's big pill, so it is never shown dimmed: with no city to
	-- resume it becomes the way to found one (its click already falls through to the
	-- create screen), which keeps a first-time player's path the obvious one.
	setEnabled(continueButton, true)
	local continueLabel = continueButton:FindFirstChild("Label")
	if continueLabel and continueLabel:IsA("TextLabel") then
		continueLabel.Text = if canContinue then "CONTINUE" else "START A CITY"
	end
	setEnabled(loadGameButton, hasSlots)
	local loadMeta = loadGameButton:FindFirstChild("Meta")
	if loadMeta and loadMeta:IsA("TextLabel") then
		local count = #getSlots()
		loadMeta.Text = if hasSlots then string.format("%d saved %s", count, if count == 1 then "city" else "cities") else ""
	end

	-- Name the city CONTINUE would resume, or say what START A CITY does.
	local metaLabel = continueButton:FindFirstChild("Meta")
	if not (metaLabel and metaLabel:IsA("TextLabel")) then
		return
	end

	local continueMeta: any = nil
	for _, slot in getSlots() do
		if tonumber(slot.slotId) == continueId then
			continueMeta = slot
		end
	end
	metaLabel.Text = if continueMeta then formatContinueMeta(continueMeta) else "Pick a map and found your first city"
end

local function setupLogoHoverEffect()
	local logo = main:FindFirstChild("LogoImage")
	if not logo or not logo:IsA("ImageLabel") then
		return
	end

	logo.Active = false

	local hitBox = Instance.new("TextButton")
	hitBox.Name = "LogoHitBox"
	hitBox.AnchorPoint = logo.AnchorPoint
	hitBox.AutoButtonColor = false
	hitBox.BackgroundTransparency = 1
	hitBox.BorderSizePixel = 0
	hitBox.Font = Enum.Font.Legacy
	hitBox.Modal = false
	hitBox.Position = logo.Position
	hitBox.Size = UDim2.new(logo.Size.X.Scale * 0.6, 0, logo.Size.Y.Scale * 0.85, 0)
	hitBox.Text = ""
	hitBox.TextTransparency = 1
	hitBox.ZIndex = logo.ZIndex + 5
	hitBox.Parent = logo.Parent

	local logoScale = Instance.new("UIScale")
	logoScale.Name = "LogoHoverScale"
	logoScale.Scale = 1
	logoScale.Parent = logo

	local shadow = Instance.new("ImageLabel")
	shadow.Name = "LogoShadow"
	shadow.Active = false
	shadow.AnchorPoint = logo.AnchorPoint
	shadow.BackgroundTransparency = 1
	shadow.BorderSizePixel = 0
	shadow.Image = logo.Image
	shadow.ImageColor3 = Color3.fromRGB(0, 0, 0)
	shadow.ImageTransparency = 0.75
	shadow.Position = logo.Position
	shadow.ScaleType = logo.ScaleType
	shadow.Size = logo.Size
	shadow.ZIndex = logo.ZIndex - 1
	shadow.Parent = logo.Parent

	local originalShadowPosition = shadow.Position

	local function tweenScale(targetScale: number, duration: number, easing: Enum.EasingStyle)
		TweenService:Create(
			logoScale,
			TweenInfo.new(duration, easing, Enum.EasingDirection.Out),
			{ Scale = targetScale }
		):Play()
	end

	local function tweenShadowTransparency(targetTransparency: number, duration: number)
		TweenService:Create(
			shadow,
			TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ ImageTransparency = targetTransparency }
		):Play()
	end

	local MAX_TILT = 10
	local TILT_SMOOTH = 9
	local PARALLAX_PUSH = 6
	local SHADOW_LIFT = 14

	local originalLogoPosition = logo.Position
	local currentTilt = 0
	local currentPushX = 0
	local currentPushY = 0
	local currentLift = 0
	local targetTilt = 0
	local targetPushX = 0
	local targetPushY = 0
	local targetLift = 0
	local isHovering = false

	local tiltConnection: RBXScriptConnection? = nil

	local function stopTilt()
		if tiltConnection then
			tiltConnection:Disconnect()
			tiltConnection = nil
		end
	end

	local function startTilt()
		stopTilt()
		tiltConnection = RunService.RenderStepped:Connect(function(dt)
			if isHovering then
				local absPos = logo.AbsolutePosition
				local absSize = logo.AbsoluteSize
				local centerX = absPos.X + absSize.X * 0.5
				local centerY = absPos.Y + absSize.Y * 0.5
				local mouse = UserInputService:GetMouseLocation()
				local nx = math.clamp((mouse.X - centerX) / math.max(absSize.X * 0.5, 1), -1, 1)
				local ny = math.clamp((mouse.Y - centerY) / math.max(absSize.Y * 0.5, 1), -1, 1)

				targetTilt = nx * MAX_TILT
				targetPushX = nx * PARALLAX_PUSH
				targetPushY = ny * PARALLAX_PUSH
				targetLift = SHADOW_LIFT
			else
				targetTilt = 0
				targetPushX = 0
				targetPushY = 0
				targetLift = 0
			end

			local alpha = 1 - math.exp(-dt * TILT_SMOOTH)
			currentTilt = currentTilt + (targetTilt - currentTilt) * alpha
			currentPushX = currentPushX + (targetPushX - currentPushX) * alpha
			currentPushY = currentPushY + (targetPushY - currentPushY) * alpha
			currentLift = currentLift + (targetLift - currentLift) * alpha

			logo.Rotation = currentTilt
			logo.Position = UDim2.new(
				originalLogoPosition.X.Scale,
				originalLogoPosition.X.Offset + math.round(currentPushX),
				originalLogoPosition.Y.Scale,
				originalLogoPosition.Y.Offset + math.round(currentPushY)
			)

			shadow.Rotation = currentTilt * 0.7
			shadow.Position = UDim2.new(
				originalShadowPosition.X.Scale,
				originalShadowPosition.X.Offset + math.round(currentPushX * 0.4),
				originalShadowPosition.Y.Scale,
				originalShadowPosition.Y.Offset + math.round(currentPushY * 0.4) + math.round(currentLift)
			)

			if not isHovering
				and math.abs(currentTilt) < 0.05
				and math.abs(currentPushX) < 0.5
				and math.abs(currentPushY) < 0.5
				and math.abs(currentLift) < 0.5
			then
				logo.Rotation = 0
				logo.Position = originalLogoPosition
				shadow.Rotation = 0
				shadow.Position = originalShadowPosition
				stopTilt()
			end
		end)
	end

	hitBox.MouseEnter:Connect(function()
		isHovering = true
		tweenScale(1.035, 0.32, Enum.EasingStyle.Quad)
		tweenShadowTransparency(0.45, 0.32)
		startTilt()
	end)

	hitBox.MouseLeave:Connect(function()
		isHovering = false
		tweenScale(1, 0.4, Enum.EasingStyle.Quad)
		tweenShadowTransparency(0.75, 0.4)
	end)
end

setupMenuIntroFade()
setupMainMenuBackgroundParallax()
setupMenuButtonHovers()
setupLogoHoverEffect()

-- GAME parent removed: Continue / Load Game / New Game are top-level buttons now.

newGameButton.Activated:Connect(function()
	openCreateModal()
end)

continueButton.Activated:Connect(function()
	-- Spawned because resolveContinueSlot may wait on a re-fetch. startCityLoad's own
	-- _loadBusy guard already absorbs a double click.
	task.spawn(function()
		local slotId = resolveContinueSlot()
		if slotId then
			startCityLoad(slotId)
		else
			openCreateModal()
		end
	end)
end)

loadGameButton.Activated:Connect(function()
	if #getSlots() > 0 then
		openLoadModal()
	else
		openCreateModal()
	end
end)

-- First slot fetch. The join loading screen waits on this step, so the menu is only ever
-- revealed with Continue / Load already showing the player's real cities. Marked whether
-- the fetch succeeded or not: a failed index is reported by the buttons themselves.
refreshSlotIndex(function()
	BootGate.markDone("menu")
end)

-- Admin-panel city loads use the same full-screen transition as normal slots.
-- AdminController fires Started before its blocking RemoteFunction call, so the
-- main menu disappears immediately instead of sitting on screen during restoration.
UIEvents.AdminCityLoadStarted.Event:Connect(function()
	beginAdminCityLoad()
end)
UIEvents.AdminCityLoadFailed.Event:Connect(function(message: any)
	cancelAdminCityLoad(if typeof(message) == "string" then message else nil)
end)
Net.CityLoadResult.OnClientEvent:Connect(function(payload: any)
	if typeof(payload) ~= "table" or payload.adminCopy ~= true then return end
	if payload.ok == true then
		finishAdminCityLoad(payload)
	else
		cancelAdminCityLoad(if typeof(payload.error) == "string" then payload.error else "The city copy could not be loaded.")
	end
end)

main:WaitForChild("SettingsButton").Activated:Connect(function()
	require(uiFolder:WaitForChild("SettingsPanel")).Open()
end)


-- Update logs page: content comes from UpdateLogData.Versions (edit that module to add
-- entries). Lazy-built like the error modal; floats over the menu.
local _updateLogModal: any = nil

-- UPDATE LOGS / CREDITS: one full-screen page, two tabs (UI.MainMenu.UpdateLogsPanel).
local function openInfoPage(tab: string)
	require(uiFolder:WaitForChild("MainMenu"):WaitForChild("UpdateLogsPanel")).Open(tab)
end

main:WaitForChild("UpdateLogsButton").Activated:Connect(function()
	openInfoPage("UPDATE LOGS")
end)

main:WaitForChild("CreditsButton").Activated:Connect(function()
	openInfoPage("CREDITS")
end)

-- Editor entry point: launch the in-world Creation Editor. EditorController listens for
-- OpenEditor and takes over the camera + UI before the menu hides. No hub to close here.
main:WaitForChild("EditorButton").Activated:Connect(function()
	UIEvents.OpenEditor:Fire()
	mainMenu.Enabled = false
end)

-- ===== Content Hub =====
-- Full-screen overlay opened from the menu's Content Hub button: a browse /
-- playlist / creation surface for shared assets. This first pass is the shell
-- plus tab switching; each tab shows an empty-state until a backend exists.
local contentHubButton = main:WaitForChild("ContentHubButton") :: ImageButton

local contentHubOverlay: Frame? = nil
local contentHubOpen = false
local closeContentHub: () -> ()

-- Leave the menu and hand off to the in-world Creation Editor (EditorController listens
-- for OpenEditor, takes the camera and shows the editor UI before the menu hides).
local function launchEditor()
	closeContentHub()
	UIEvents.OpenEditor:Fire()
	mainMenu.Enabled = false
end

local function buildContentHub(): Frame
	if contentHubOverlay then
		return contentHubOverlay
	end
	-- The two round trips the Browsing tab needs. They live here, not in the view: the
	-- view is construction only. Both yield, and both are called from a task.spawn there.
	local function browseStore(): { any }
		local ok, res = pcall(function()
			return Net.RequestReviewQueue:InvokeServer({ action = "store" })
		end)
		if not ok or typeof(res) ~= "table" or not res.ok then return {} end
		return if typeof(res.published) == "table" then res.published else {}
	end

	local function loadCreationPreview(bpId: string): any
		local ok, res = pcall(function()
			return Net.RequestReviewQueue:InvokeServer({ action = "blob", id = bpId })
		end)
		if not ok or typeof(res) ~= "table" or not res.ok then return nil end
		return res
	end

	-- Removing something from the catalogue. The server decides who may: the author of
	-- that creation, or a curator/admin. This just carries the request.
	local function takeDownCreation(bpId: string): (boolean, string?)
		local ok, res = pcall(function()
			return Net.RequestReviewQueue:InvokeServer({ action = "unpublish", id = bpId })
		end)
		if not ok or typeof(res) ~= "table" then return false, "The server didn't answer." end
		return res.ok == true, tostring(res.message or res.error or "")
	end

	-- UI hint only, and stamped by the server (AdminService). ReviewQueue re-checks the
	-- real authority on every call, so forging this attribute buys nothing.
	local function canModerate(): boolean
		local tier = player:GetAttribute("AdminTier")
		return tier == "curator" or tier == "admin"
	end

	contentHubOverlay = MainMenuView.buildContentHub({
		onBrowse = browseStore,
		onLoadPreview = loadCreationPreview,
		onTakeDown = takeDownCreation,
		canModerate = canModerate,
		parent = mainMenu,
		onBack = function()
			closeContentHub()
		end,
		onOpenEditor = launchEditor,
	})
	return contentHubOverlay
end

closeContentHub = function()
	if not contentHubOpen then
		return
	end
	contentHubOpen = false
	local overlay = buildContentHub()
	local tween = TweenService:Create(
		overlay,
		TweenInfo.new(0.24, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 }
	)
	tween.Completed:Connect(function()
		if not contentHubOpen then
			overlay.Visible = false
		end
	end)
	tween:Play()
	setMenuPanelVisible(true)
end

local function openContentHub()
	if contentHubOpen then
		return
	end
	contentHubOpen = true
	setMenuPanelVisible(false)
	local overlay = buildContentHub()
	overlay.BackgroundTransparency = 1
	overlay.Visible = true
	TweenService:Create(
		overlay,
		TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 0 }
	):Play()
end

contentHubButton.Activated:Connect(openContentHub)

-- Return to Main Menu: fired by HUDController when the player presses the button
-- in the in-game gear menu. Fades out the gameplay GUIs and restores the main menu
-- so the player can start a new game or load a different city.
UIEvents.ReturnToMainMenu.Event:Connect(function()
	-- In a city server the menu is in the OTHER place, so going back to it is a teleport.
	-- Restoring the local menu here would let the player load a second city into a server
	-- that is somebody's city. The save is already covered: leaving fires PlayerRemoving,
	-- which is the path that banks the standing city.
	if PlacesConfig.menuIsElsewhere() then
		TeleportService:Teleport(PlacesConfig.LOBBY_PLACE_ID)
		return
	end

	local overlay = getMenuFadeOverlay()
	overlay.BackgroundTransparency = 1
	overlay.Visible = true

	local fadeTween = TweenService:Create(
		overlay,
		TweenInfo.new(MENU_OUT_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
		{ BackgroundTransparency = 0 }
	)
	fadeTween:Play()
	fadeTween.Completed:Wait()

	setGameplayGuisEnabled(false)
	hasOpenedHub = false
	_loadBusy = false

	hasPlayedMenuIntroFade = false
	mainMenu.Enabled = true
	setMenuPanelVisible(true)
	refreshSlotIndex()
end)

-- Arriving from the lobby: the slot the player picked over there rides along as teleport
-- data, so enter it straight away rather than making them choose the same city twice.
-- The value is client-readable and spoofable, and harmless -- the server validates the
-- slot against that player's own index, so the worst a forged one opens is their own city.
-- Nil on an ordinary join and in Studio, which is the no-op case.
if _bootSlotId then
	task.spawn(startCityLoad, _bootSlotId)
elseif PlacesConfig.menuIsElsewhere() then
	-- CITY place, and nothing in the teleport data to say which city. Getting here means
	-- the player did not come through the lobby's slot pick: a Roblox rejoin, a server
	-- hop, or a friend walking in off the join button. The main menu is the wrong answer
	-- to all three -- it is the other place's menu, and it offers to start a SECOND city
	-- in a server that is somebody's.
	--
	-- So put them where they meant to be: into the city standing in this server, or back
	-- to the lobby if there is none to join. The boot slot-index fetch already asks the
	-- server what is standing here, so this waits on that answer rather than firing a
	-- second request.
	task.spawn(function()
		local deadline = os.clock() + 20
		while _slotData == nil and os.clock() < deadline do
			task.wait(0.2)
		end
		local standing = if _slotData then tonumber(_slotData.standingSlot) else nil
		if standing then
			startCityLoad(standing)
		else
			TeleportService:Teleport(PlacesConfig.LOBBY_PLACE_ID)
		end
	end)
end

end

return MainMenuController
