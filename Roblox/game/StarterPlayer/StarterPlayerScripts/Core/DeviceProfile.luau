--!strict
-- DeviceProfile -- one guess at what this machine can draw, made once at boot from signals
-- that cost nothing to read.
--
-- WHY THIS EXISTS
-- Every low-end behaviour in the render path used to hang off one predicate:
-- Settings.get("graphicsPreset") == "Low". The shipped default is "High". So a phone joined
-- on High and stayed there unless the player went looking for the settings page, which most
-- players never do -- and the five levers tuned for weak devices (cull threshold, proxy cache
-- size, impostor resolution, the coarse bake, draw distance) were all switched off on exactly
-- the hardware they were written for.
--
-- This does not decide anything by itself. It produces a PRESET NAME, and SettingsClient
-- applies it only when the player has no saved preference of their own -- see
-- SettingsClient.Start. A returning player's choice always wins, including a returning player
-- who deliberately chose Ultra on a phone.
--
-- WHAT IT IS NOT
-- Not a benchmark. Frame time is the honest measure of what a device can actually sustain,
-- but it is not available at boot and it changes with what is on screen, so it belongs to
-- Core.RenderPressure, which keeps measuring for the whole session and degrades further if
-- this guess was too generous. This file only has to get the STARTING point roughly right.

local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local DeviceProfile = {}

export type Profile = {
	preset: string, -- "Low" | "Medium" | "High"
	handheld: boolean,
	viewportY: number, -- 0 when no camera existed yet
	-- The player's OWN Roblox-level graphics choice, 1 (lowest) to 10 (highest), or nil when
	-- they are on Automatic -- which is the common case and tells us nothing either way.
	quality: number?,
	why: string, -- readable trail, published as an attribute so a bad guess can be read back
}

-- Viewport height below which a device is treated as small. Roblox reports ViewportSize in
-- points, not physical pixels, so a phone lands near 390-430 and a tablet near 750-830; this
-- separates handset from everything else without depending on pixel density.
local SMALL_VIEWPORT_Y = 520

-- Quality bands. Roblox's SavedQualitySetting runs QualityLevel1..QualityLevel10, plus
-- Automatic. A player who has deliberately pinned themselves to 1-3 has told us more about
-- their device than any inference could.
local QUALITY_WEAK = 3
local QUALITY_MID = 6
local QUALITY_STRONG = 9

local _cached: Profile? = nil

-- nil when the player is on Automatic, or when the property is unreadable. Never assume a
-- failed read means "weak": a pcall that throws would otherwise quietly demote every player
-- on a Roblox build where this property moved.
local function savedQuality(): number?
	local ok, level = pcall(function()
		return UserSettings():GetService("UserGameSettings").SavedQualityLevel
	end)
	if not ok or typeof(level) ~= "EnumItem" then
		return nil
	end
	local n = tonumber(string.match(level.Name, "^QualityLevel(%d+)$"))
	return n
end

local function viewportHeight(): number
	local cam = Workspace.CurrentCamera
	if not cam then
		return 0
	end
	local ok, size = pcall(function()
		return cam.ViewportSize
	end)
	return if ok and typeof(size) == "Vector2" then size.Y else 0
end

-- Touch WITHOUT a keyboard is the handheld test. Touch alone is not: a Surface or a touch
-- laptop reports TouchEnabled and is an ordinary desktop by every measure that matters here.
local function isHandheld(): boolean
	local ok, touch = pcall(function()
		return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	end)
	return ok and touch == true
end

-- Scored rather than branched, so no single signal can decide alone and the reasoning stays
-- readable when a guess turns out wrong. 3 = High, 2 = Medium, 1 = Low.
function DeviceProfile.detect(): Profile
	local handheld = isHandheld()
	local viewportY = viewportHeight()
	local quality = savedQuality()

	local score = 3
	local reasons: { string } = {}

	if handheld then
		score -= 1
		table.insert(reasons, "handheld")
	end
	if viewportY > 0 and viewportY < SMALL_VIEWPORT_Y then
		score -= 1
		table.insert(reasons, string.format("viewport %dpt", math.round(viewportY)))
	end
	if quality then
		if quality <= QUALITY_WEAK then
			score -= 2
			table.insert(reasons, string.format("quality %d", quality))
		elseif quality <= QUALITY_MID then
			score -= 1
			table.insert(reasons, string.format("quality %d", quality))
		elseif quality >= QUALITY_STRONG then
			-- The one signal that can push BACK up: a player who pinned themselves to 9 or 10
			-- has told us the device copes, which should survive one soft negative above.
			score += 1
			table.insert(reasons, string.format("quality %d", quality))
		end
	else
		table.insert(reasons, "quality auto")
	end

	score = math.clamp(score, 1, 3)
	local preset = if score >= 3 then "High" elseif score == 2 then "Medium" else "Low"

	return {
		preset = preset,
		handheld = handheld,
		viewportY = viewportY,
		quality = quality,
		why = preset .. " (" .. table.concat(reasons, ", ") .. ")",
	}
end

-- Memoised: the signals cannot change mid-session in any way worth re-reading, and several
-- callers want the same answer.
function DeviceProfile.get(): Profile
	local cached = _cached
	if cached then
		return cached
	end
	local ok, profile = pcall(DeviceProfile.detect)
	if not ok or type(profile) ~= "table" then
		-- Never guess DOWN on a fault. A detection bug that silently put every player on Low
		-- would look like a deliberate quality decision and take a long time to find.
		profile = {
			preset = "High",
			handheld = false,
			viewportY = 0,
			quality = nil,
			why = "High (detection failed)",
		}
	end
	_cached = profile
	return profile
end

return DeviceProfile
