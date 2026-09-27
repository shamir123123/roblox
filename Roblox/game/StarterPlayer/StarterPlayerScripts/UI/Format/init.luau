--!strict
-- Number, money and duration strings for the whole client UI.
--
-- Library module: pure, stateless, no lifecycle, no side effects on require, so
-- it is required directly rather than injected (CLAUDE.md §3).
--
-- Before this existed, BottomBarController, HUDController, DashboardController,
-- BankruptcyController and PlayerHubController each carried their own private
-- copy of formatInt -- five chances for the thousands separator to disagree.

local Format = {}

-- 1234567 -> "1,234,567". Rounds to nearest; negatives keep the sign.
function Format.int(n: number): string
	local neg = n < 0
	local s = tostring(math.abs(math.floor(n + 0.5)))
	local groups = ""
	while #s > 3 do
		groups = "," .. s:sub(#s - 2) .. groups
		s = s:sub(1, #s - 3)
	end
	return (if neg then "-" else "") .. s .. groups
end

-- The minus goes BEFORE the dollar sign: -$1,200, never $-1,200.
function Format.money(n: number): string
	return (if n < 0 then "-$" else "$") .. Format.int(math.abs(n))
end

-- Always carries an explicit sign. For deltas and net-income readouts, where a
-- bare "0" and a "+0" mean different things to a player watching a trend.
function Format.signed(n: number): string
	local r = math.floor(n + 0.5)
	return (if r >= 0 then "+" else "-") .. Format.int(math.abs(r))
end

function Format.signedMoney(n: number): string
	local r = math.floor(n + 0.5)
	return (if r >= 0 then "+" else "-") .. Format.money(math.abs(r))
end

function Format.duration(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	local h = s // 3600
	local m = (s % 3600) // 60
	if h >= 1 then
		return string.format("%dh %dm", h, m)
	end
	if m >= 1 then
		return string.format("%dm", m)
	end
	return string.format("%ds", s)
end

-- Compact form for tight chrome (the collapsed vitals strip): 12400 -> "12.4K".
-- Under 1000 it falls through to int, because "0.9K" reads worse than "900".
function Format.compact(n: number): string
	local a = math.abs(n)
	if a < 1000 then
		return Format.int(n)
	end
	local sign = if n < 0 then "-" else ""
	if a < 1e6 then
		return string.format("%s%.1fK", sign, a / 1e3)
	end
	return string.format("%s%.2fM", sign, a / 1e6)
end

return table.freeze(Format)
