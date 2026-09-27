--!strict
-- PlayerPresenceService
-- Where everybody else is. Each client reports its camera position and the ground point
-- under its cursor about ten times a second; this pools them and pushes the whole set back
-- out, so every client can draw the others as a line from their camera down to whatever
-- they are aiming at -- see the client's PlayerPresenceView.
--
-- Nothing here is game state. It is never saved, never read back, and never trusted for
-- anything: the worst a forged report can do is put somebody's marker in the wrong place
-- on other people's screens. That is why the validation below is a shape-and-range check
-- and stops there.
--
-- Silent in a solo server. With nobody else to draw, the whole exchange is skipped rather
-- than run into an empty room.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerPresenceService = {}

-- Accept a report at most this often per player. The client aims for 10 Hz; the slack
-- absorbs frame jitter without letting a modified client flood the server.
local REPORT_MIN_INTERVAL = 1 / 15
local BROADCAST_INTERVAL = 1 / 10
-- Far outside any playable coordinate. A point past this is not a place in this world, so
-- it is a malformed or hostile report rather than a marker.
local MAX_COORD = 100000
-- A player whose reports stopped (alt-tabbed, loading, a dropped unreliable packet run)
-- keeps their last marker this long, then drops out of the broadcast rather than hanging
-- over the map forever.
local STALE_AFTER = 3
-- A row goes out again only when its player's camera or cursor has moved, or once per
-- KEEPALIVE so the other clients' markers (dropped after 4 s unseen) stay up. A player
-- sitting still costs nobody anything past that; the old every-row-every-tick broadcast
-- grew with the square of the player count.
local KEEPALIVE = 1
local MOVE_EPS = 0.25 -- studs

type Presence = { pos: Vector3, aim: Vector3, name: string, at: number }

local _state: { [number]: Presence } = {}
local _sent: { [number]: { pos: Vector3, aim: Vector3, at: number } } = {}
local _lastReportAt: { [number]: number } = {}
local _net: any = nil
local _bound = false
local _accum = 0

local function isPlacePoint(v: any): boolean
	if typeof(v) ~= "Vector3" then return false end
	-- NaN fails every comparison, including with itself, so this catches it before the
	-- range test (which NaN would otherwise pass by failing quietly).
	if v.X ~= v.X or v.Y ~= v.Y or v.Z ~= v.Z then return false end
	return math.abs(v.X) < MAX_COORD and math.abs(v.Y) < MAX_COORD and math.abs(v.Z) < MAX_COORD
end
PlayerPresenceService._isPlacePoint = isPlacePoint -- exposed for the spec

local function onReport(player: Player, payload: any)
	local now = os.clock()
	local last = _lastReportAt[player.UserId]
	if last and now - last < REPORT_MIN_INTERVAL then return end
	_lastReportAt[player.UserId] = now

	if typeof(payload) ~= "table" then return end
	if not isPlacePoint(payload.pos) or not isPlacePoint(payload.aim) then return end

	-- DisplayName, not Name: this is a label for a human to read on a map, and it is
	-- re-read every report so a change lands without a rejoin.
	_state[player.UserId] = {
		pos = payload.pos,
		aim = payload.aim,
		name = player.DisplayName,
		at = now,
	}
end

local function broadcast()
	-- One player in the server is the common case, and drawing nobody costs nothing.
	if #Players:GetPlayers() < 2 then return end

	local now = os.clock()
	local rows = {}
	for userId, p in _state do
		if now - p.at > STALE_AFTER then
			_state[userId] = nil
			_sent[userId] = nil
			continue
		end
		local last = _sent[userId]
		if last and now - last.at < KEEPALIVE
			and (p.pos - last.pos).Magnitude < MOVE_EPS and (p.aim - last.aim).Magnitude < MOVE_EPS then
			continue
		end
		_sent[userId] = { pos = p.pos, aim = p.aim, at = now }
		table.insert(rows, { id = userId, name = p.name, pos = p.pos, aim = p.aim })
	end
	if #rows == 0 then return end

	-- To everyone, including the players in the list: the client drops its own row, which
	-- is one comparison there against a per-player packet here.
	_net.SyncPresence:FireAllClients(rows)
end

function PlayerPresenceService.Init()
	_net = require(ReplicatedStorage:WaitForChild("Networker"))
end

function PlayerPresenceService.Bind()
	if _bound then return end
	_bound = true
	if not _net then
		error("[PlayerPresenceService] Bind before Init -- the Networker is not captured yet")
	end

	_net.ReportPresence.OnServerEvent:Connect(onReport)

	Players.PlayerRemoving:Connect(function(player)
		_state[player.UserId] = nil
		_sent[player.UserId] = nil
		_lastReportAt[player.UserId] = nil
	end)

	-- One broadcast for the whole server rather than a task per player: the payload is the
	-- same for everybody, so it is built once and sent once.
	RunService.Heartbeat:Connect(function(dt: number)
		_accum += dt
		if _accum < BROADCAST_INTERVAL then return end
		_accum = 0
		local ok, err = pcall(broadcast)
		if not ok then
			warn("[PlayerPresenceService] broadcast failed: " .. tostring(err))
		end
	end)
end

return PlayerPresenceService
