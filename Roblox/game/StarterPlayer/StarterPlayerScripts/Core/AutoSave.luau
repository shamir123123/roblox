--!strict
-- Client-driven city autosave. While a city is loaded (UIEvents.GameEntered ..
-- ReturnToMainMenu), invokes RequestSaveCity every N minutes, both read live
-- from Settings ("autosave" on/off, "autosaveInterval" minutes) so changes in
-- the options page take effect immediately. The server side of RequestSaveCity
-- (CitySlotService) already validates and owns the actual write.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Settings = require(script.Parent:WaitForChild("Settings"))

local AutoSave = {}

local _started = false
local _inGame = false
local _cycle = 0 -- bumping this kills the previous loop

local function notify(opts: { [string]: any })
	local ok, err = pcall(function()
		local Notification = require(script.Parent.Parent:WaitForChild("HUD"):WaitForChild("NotificationController")) :: any
		Notification.Notify(opts)
	end)
	if not ok then
		warn("[AutoSave] notify failed: " .. tostring(err))
	end
end

local function save()
	local Net = require(ReplicatedStorage:WaitForChild("Networker"))
	local ok, success, info = pcall(function()
		return Net.RequestSaveCity:InvokeServer()
	end)
	if ok and success then
		notify({ text = "City autosaved", kind = "info" })
	else
		notify({ text = (typeof(info) == "string" and info) or "Autosave failed", kind = "warning" })
	end
end

local function runLoop()
	_cycle += 1
	local cycle = _cycle
	task.spawn(function()
		local acc = 0
		while cycle == _cycle and _inGame do
			task.wait(1)
			if Settings.get("autosave") ~= true then
				acc = 0
				continue
			end
			acc += 1
			local minutes = math.clamp(tonumber(Settings.get("autosaveInterval")) or 10, 1, 120)
			if acc >= minutes * 60 then
				acc = 0
				save()
			end
		end
	end)
end

function AutoSave.Start()
	if _started then
		return
	end
	_started = true

	local UIEvents = require(ReplicatedStorage:WaitForChild("City"):WaitForChild("UIEvents"))
	UIEvents.GameEntered.Event:Connect(function()
		_inGame = true
		runLoop()
	end)
	UIEvents.ReturnToMainMenu.Event:Connect(function()
		_inGame = false
		_cycle += 1
	end)
end

return AutoSave