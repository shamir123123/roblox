--!strict

local ReplicatedFirst   = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local Players           = game:GetService("Players")
local StarterGui        = game:GetService("StarterGui")

ReplicatedFirst:RemoveDefaultLoadingScreen()

local MAIN_MENU_NAME = "MainMenu"
local LOADING_SCREEN_NAME = "LoadingScreen"
local STAFF_PANEL_NAME = "StaffPanel" -- unified tester/admin/developer overlay

-- Is the main menu this place's screen at all? In the CITY place it is not: the player was
-- sent there to be IN a city, and MainMenuController has already decided which one before
-- this screen comes down. Handing over by force-enabling the menu is what put a main menu
-- on top of a running city -- the fix at the other end could not hold, because this ran
-- after it. Waited for rather than required at the top: ReplicatedFirst runs before
-- ReplicatedStorage has finished replicating.
local function menuBelongsHere(): boolean
	local ok, elsewhere = pcall(function()
		local access = ReplicatedStorage:WaitForChild("Access", 10)
		return require(access:WaitForChild("PlacesConfig", 10)).menuIsElsewhere()
	end)
	if not ok then
		-- Unreadable: behave as the lobby, which is the only place that can recover.
		warn("[LoadingController] PlacesConfig unreadable, assuming the menu belongs here: " .. tostring(elsewhere))
		return true
	end
	return not elsewhere
end

-- THE JOIN GATE. The screen stays up until this player's data is actually here:
--   1. the place itself (game:IsLoaded)
--   2. the server side of their data -- profile record + city slot index -- reported by
--      PlayerLoadService through the DataLoad* attributes on the Player
--   3. the client side -- saved settings applied, first slot index fetched -- latched by
--      the steps in ReplicatedStorage.Shared.ClientBootGate
-- Before this, the menu opened on a timer: Continue could be empty for a player who has
-- three cities, and the language / UI scale snapped a second after it appeared.
--
-- DATA_TIMEOUT is the never-stuck backstop. Every wait below is bounded by it: a service
-- that fails to answer drops the player into the menu on defaults (which is what they got
-- before this gate existed), it never leaves them staring at a logo.
local DATA_TIMEOUT     = 45
local MIN_SCREEN_TIME  = 1.6 -- a fast join must not flash the card past
local CLIENT_STEPS     = { "settings", "menu" }
local POLL_INTERVAL    = 0.1

local FADE_IN  = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FADE_OUT = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local player    = Players.LocalPlayer :: Player
local playerGui = player:WaitForChild("PlayerGui")

local menuIsOpen = true

local function setCoreGuiEnabled(enabled: boolean)
    for _ = 1, 5 do
        local ok = pcall(function()
            StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, enabled)
        end)
        if ok then
            return
        end
        task.wait()
    end
end

local function shouldKeepEnabled(guiName: string): boolean
    if guiName == LOADING_SCREEN_NAME or guiName == STAFF_PANEL_NAME then
        return true
    end

    return menuIsOpen and guiName == MAIN_MENU_NAME
end

-- Tag every gui we switch off, so the menu can switch back on exactly the ones we took
-- and nothing else. The menu used to restore from a hardcoded name list that had drifted
-- out of sync with the guis the controllers actually create, which left tooltips, modals,
-- hover cards and the radio bar dark for the whole session on any client that happened to
-- build them while this screen was still up.
--
-- Panels that mean to start closed (SettingsUI, EditorUI, PlacementCostHud) set
-- Enabled = false BEFORE parenting, so they reach us already disabled and are never
-- tagged -- handing over must not force them open.
local HIDDEN_BY_LOADER_ATTR = "HiddenByLoadingScreen"

local function hideGui(child: ScreenGui)
    if child.Enabled then
        child:SetAttribute(HIDDEN_BY_LOADER_ATTR, true)
        child.Enabled = false
    end
end

local function hideOtherScreenGuis()
    for _, child in ipairs(playerGui:GetChildren()) do
        if child:IsA("ScreenGui") and not shouldKeepEnabled(child.Name) then
            hideGui(child)
        end
    end
end

local childAddedConnection = playerGui.ChildAdded:Connect(function(child)
    if child:IsA("ScreenGui") and not shouldKeepEnabled(child.Name) then
        hideGui(child)
    end
end)

setCoreGuiEnabled(false)
hideOtherScreenGuis()

-- Clone and show the loading screen (black bg + logo)
local template  = ReplicatedFirst:WaitForChild(LOADING_SCREEN_NAME)
local screenGui = template:Clone()
screenGui.Name = LOADING_SCREEN_NAME
screenGui.Enabled = true
screenGui.Parent  = playerGui

local bg   = screenGui:WaitForChild("Background")
local logo = bg:FindFirstChild("Logo") :: ImageLabel?

-- Status line + progress bar, built here rather than baked into the ScreenGui: the
-- template stays the plain logo card that the main menu also clones for its own
-- city-load transition.
local status = Instance.new("TextLabel")
status.Name = "StatusText"
status.AnchorPoint = Vector2.new(0.5, 0.5)
status.BackgroundTransparency = 1
status.Font = Enum.Font.GothamMedium
status.Position = UDim2.fromScale(0.5, 0.72)
status.Size = UDim2.fromScale(0.35, 0.035)
status.Text = "LOADING GAME"
status.TextColor3 = Color3.fromRGB(225, 225, 225)
status.TextScaled = true
status.TextTransparency = 1
status.ZIndex = 3
status.Parent = bg

local barTrack = Instance.new("Frame")
barTrack.Name = "ProgressTrack"
barTrack.AnchorPoint = Vector2.new(0.5, 0.5)
barTrack.BackgroundColor3 = Color3.fromRGB(45, 45, 48)
barTrack.BackgroundTransparency = 1
barTrack.BorderSizePixel = 0
barTrack.Position = UDim2.fromScale(0.5, 0.78)
barTrack.Size = UDim2.fromScale(0.22, 0.009)
barTrack.ZIndex = 3
barTrack.Parent = bg

local trackCorner = Instance.new("UICorner")
trackCorner.CornerRadius = UDim.new(1, 0)
trackCorner.Parent = barTrack

local barFill = Instance.new("Frame")
barFill.Name = "ProgressFill"
barFill.BackgroundColor3 = Color3.fromRGB(235, 235, 235)
barFill.BackgroundTransparency = 1
barFill.BorderSizePixel = 0
barFill.Size = UDim2.fromScale(0, 1)
barFill.ZIndex = 4
barFill.Parent = barTrack

local fillCorner = Instance.new("UICorner")
fillCorner.CornerRadius = UDim.new(1, 0)
fillCorner.Parent = barFill

local _shownProgress = 0

-- Monotonic on purpose: the gates report their own fractions and a bar that slid
-- backwards would read as something having gone wrong.
local function setProgress(alpha: number)
    alpha = math.clamp(alpha, 0, 1)
    if alpha <= _shownProgress then return end
    _shownProgress = alpha
    TweenService:Create(barFill,
        TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { Size = UDim2.fromScale(alpha, 1) }
    ):Play()
end

local function setStatus(text: string)
    if status.Text ~= text then
        status.Text = text
    end
end

-- Fade the card in
if logo then
    logo.ImageTransparency = 1
    TweenService:Create(logo, FADE_IN, { ImageTransparency = 0 }):Play()
end
TweenService:Create(status, FADE_IN, { TextTransparency = 0.15 }):Play()
TweenService:Create(barTrack, FADE_IN, { BackgroundTransparency = 0.35 }):Play()
TweenService:Create(barFill, FADE_IN, { BackgroundTransparency = 0 }):Play()

local shownAt  = os.clock()
local deadline = shownAt + DATA_TIMEOUT

-- 1. The place itself: assets and the initial replication.
if not game:IsLoaded() then
    game.Loaded:Wait()
end
setProgress(0.25)

-- 2. The player's data, server side. PlayerLoadService moves these attributes along as
-- each DataStore read lands and flips DataLoaded once every one of them has.
while player:GetAttribute("DataLoaded") ~= true do
    if os.clock() >= deadline then
        warn("[LoadingController] player data did not arrive in time -- entering on defaults")
        break
    end

    local step = player:GetAttribute("DataLoadStep")
    setStatus(if typeof(step) == "string" then string.upper(step) else "LOADING YOUR DATA")

    local serverAlpha = tonumber(player:GetAttribute("DataLoadProgress")) or 0
    setProgress(0.25 + 0.45 * math.clamp(serverAlpha, 0, 1))

    task.wait(POLL_INTERVAL)
end
setProgress(0.7)

-- 3. The client half: the loaded profile APPLIED (settings) and the menu holding the
-- player's real slot list. Waited on through a latched gate, not an event, because these
-- steps can complete before this script ever gets to look at them.
setStatus("APPLYING YOUR SETTINGS")
local sharedFolder = ReplicatedStorage:WaitForChild("Shared", math.max(1, deadline - os.clock()))
local gateModule = if sharedFolder then sharedFolder:WaitForChild("ClientBootGate", math.max(1, deadline - os.clock())) else nil

if gateModule and gateModule:IsA("ModuleScript") then
    local BootGate = require(gateModule) :: any
    local missing = BootGate.await(CLIENT_STEPS, math.max(0, deadline - os.clock()))
    if missing then
        warn("[LoadingController] boot step '" .. missing .. "' never completed -- entering anyway")
    end
else
    warn("[LoadingController] ClientBootGate is missing -- skipping the client-side wait")
end

setProgress(1)
setStatus(if player:GetAttribute("DataLoadTimedOut") == true then "SOME DATA IS UNAVAILABLE" else "READY")

-- A fast join must not flash the card past; a slow one has already paid the time.
local held = os.clock() - shownAt
if held < MIN_SCREEN_TIME then
    task.wait(MIN_SCREEN_TIME - held)
end

-- Fade the card out
if logo then
    TweenService:Create(logo, FADE_OUT, { ImageTransparency = 1 }):Play()
end
TweenService:Create(status, FADE_OUT, { TextTransparency = 1 }):Play()
TweenService:Create(barTrack, FADE_OUT, { BackgroundTransparency = 1 }):Play()
TweenService:Create(barFill, FADE_OUT, { BackgroundTransparency = 1 }):Play()
task.wait(FADE_OUT.Time)

-- Destroy loading screen
screenGui:Destroy()

-- Open the Main Menu and keep every other UI hidden -- in the LOBBY. In the city place the
-- menu is not what comes next, so hand the screen over exactly as MainMenuController left
-- it and take nothing else down on the way out.
local mainMenu = playerGui:WaitForChild(MAIN_MENU_NAME, 10)
menuIsOpen = menuBelongsHere()
setCoreGuiEnabled(false)

if menuIsOpen then
    hideOtherScreenGuis()
    if mainMenu and mainMenu:IsA("ScreenGui") then
        mainMenu.Enabled = true
    else
        warn("MainMenu ScreenGui was not found after loading completed.")
    end
end

childAddedConnection:Disconnect()
