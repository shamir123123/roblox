--!strict
-- Client-side UI signals shared between the main menu (cloned into PlayerGui)
-- and PlayerScripts controllers. Both require the same module instance per
-- client, so these BindableEvents are a private in-client bus -- the menu
-- announces lifecycle moments instead of reaching into other controllers' GUIs.

local RunService = game:GetService("RunService")

if RunService:IsServer() then
	error("[UIEvents] Client-only module")
end

local function signal(name: string): BindableEvent
	local event = Instance.new("BindableEvent")
	event.Name = name
	return event
end

return {
	-- Fired once after CityLoadResult ok: the city is rebuilt and the HUD may appear.
	GameEntered = signal("GameEntered"),
	-- AdminController announces a foreign-save load before the blocking server call,
	-- allowing MainMenu to hide immediately and show the normal loading experience.
	AdminCityLoadStarted = signal("AdminCityLoadStarted"),
	AdminCityLoadFailed = signal("AdminCityLoadFailed"),
	-- Fired by HUDController when the player presses "Main Menu" in the in-game menu.
	ReturnToMainMenu = signal("ReturnToMainMenu"),
	-- Fired by TopLeftCluster's menu chip. HUDController owns the menu and its open
	-- state; the chip only announces the press, so the top-left zone does not depend
	-- on the menu's interface and the two cannot require each other.
	MenuRequested = signal("MenuRequested"),
	-- Fired by the main menu's Content Hub -> Creation tab to launch the in-world editor.
	-- EditorController listens and takes over the camera + shows the editor UI.
	OpenEditor = signal("OpenEditor"),
	-- Fired by SettingsPanel.Open/Close: every other open overlay hides itself
	-- while the settings page owns the screen, and restores after.
	SettingsOpened = signal("SettingsOpened"),
	SettingsClosed = signal("SettingsClosed"),
}
