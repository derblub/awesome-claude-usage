-- fixtures.lua - write invented usage data for one screenshot scenario.
--
--   lua5.4 fixtures.lua <scenario> <dir>
--
-- Scenarios: ultra, max, warning, apikey. Every value is made up; times are relative to now so the
-- popup shows "resets in 2d 5h". Writes into <dir>: credentials.json, api.json (not for apikey),
-- rate_limits.json (the statusLine cache), history.csv. Nothing outside <dir> is read or written.

local scenario, dir = arg[1], arg[2]
if not scenario or not dir then
	io.stderr:write("usage: fixtures.lua <ultra|max|warning|apikey> <dir>\n")
	os.exit(2)
end

local now = os.time()
local HOUR, DAY = 3600, 86400

local function iso(t)
	return os.date("!%Y-%m-%dT%H:%M:%S.000000+00:00", t)
end

local function write(name, content)
	local f = assert(io.open(dir .. "/" .. name, "w"))
	f:write(content)
	f:close()
end

--- Samples of one window every 15 minutes, rising from `from` to `to` in bursts (usage comes in
--- work sessions, with idle stretches in between). The shape is deterministic.
local function ramp(lines, key, from, to, hours, resets_at)
	local n = hours * 4
	local weights, total = { 0 }, 0
	for i = 1, n do
		local burst = ((i * 37 + 11) % 23) / 22
		local w = (i % 9 < 3) and 0.05 or burst * burst
		total = total + w
		weights[i + 1] = total
	end
	for i = 0, n do
		local t = now - (n - i) * 900
		local v = from + (to - from) * (weights[i + 1] / total)
		lines[#lines + 1] = string.format("%d,%s,%.1f,%d", t, key, v, resets_at)
	end
end

local plans = {
	ultra = { tier = "default_claude_max_20x" },
	max = { tier = "default_claude_max_5x" },
	warning = { tier = "default_claude_max_20x" },
}

if plans[scenario] then
	write(
		"credentials.json",
		string.format(
			'{"claudeAiOauth": {"accessToken": "fake-token-for-screenshots", "refreshToken": "fake", '
				.. '"expiresAt": %d000, "scopes": ["user:inference"], "subscriptionType": "max", '
				.. '"rateLimitTier": "%s"}}\n',
			now + 30 * DAY,
			plans[scenario].tier
		)
	)
end

local function breakdown(code, chat, cowork, other)
	return string.format(
		'"seven_day_breakdown": {"as_of": "%s", "window_started_at": "%s", "rows": ['
			.. '{"key": "claude_code", "display_name": "Claude Code", "percent": %d}, '
			.. '{"key": "chat", "display_name": "Chats", "percent": %d}, '
			.. '{"key": "cowork", "display_name": "Cowork", "percent": %d}, '
			.. '{"key": "other", "display_name": "Other", "percent": %d}]}',
		iso(now),
		iso(now - 4 * DAY),
		code,
		chat,
		cowork,
		other
	)
end

local function spend(enabled, used_minor, limit_minor)
	local percent = limit_minor and (used_minor / limit_minor * 100) or 0
	return string.format(
		'"spend": {"used": {"amount_minor": %d, "currency": "USD", "exponent": 2}, "limit": %s, '
			.. '"percent": %.2f, "severity": "normal", "enabled": %s}',
		used_minor,
		limit_minor and string.format('{"amount_minor": %d, "currency": "USD", "exponent": 2}', limit_minor)
			or "null",
		percent,
		tostring(enabled)
	)
end

local function limit(kind, group, percent, resets_at, model, active)
	return string.format(
		'{"kind": "%s", "group": "%s", "percent": %d, "severity": "normal", "resets_at": "%s", '
			.. '"scope": %s, "is_active": %s}',
		kind,
		group,
		percent,
		iso(resets_at),
		model and string.format('{"model": {"id": null, "display_name": "%s"}, "surface": null}', model) or "null",
		tostring(active)
	)
end

local history = {}

if scenario == "ultra" or scenario == "warning" then
	-- Ultra: no 5-hour window at all, the weekly limits only.
	local week, fable, week_resets, extra, spend_json
	if scenario == "ultra" then
		week, fable = 42, 18
		week_resets = now + 2 * DAY + 5 * HOUR + 20 * 60
		spend_json = spend(false, 0, nil)
		extra = '"extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null}'
		ramp(history, "seven_day", 8, week, 72, week_resets)
		ramp(history, "scoped:Fable", 3, fable, 72, week_resets)
	else
		week, fable = 91, 64
		week_resets = now + 1 * DAY + 3 * HOUR + 40 * 60
		spend_json = spend(true, 1840, 5000)
		extra = '"extra_usage": {"is_enabled": true, "monthly_limit": 50, "used_credits": 18.4, "utilization": 36.8}'
		ramp(history, "seven_day", 52, week, 72, week_resets)
		ramp(history, "scoped:Fable", 30, fable, 72, week_resets)
	end
	write(
		"api.json",
		string.format(
			'{"five_hour": null, "seven_day": {"utilization": %d, "resets_at": "%s"}, "seven_day_opus": null, '
				.. '"seven_day_sonnet": null, %s, "limits": [%s, %s], %s, %s, '
				.. '"weekly_scoped_shares": [{"limit_index": 1, "used_percent_of_weekly": %d, '
				.. '"allowance_percent_of_weekly": 50}]}\n',
			week,
			iso(week_resets),
			extra,
			limit("weekly_all", "weekly", week, week_resets, nil, true),
			limit("weekly_scoped", "weekly", fable, week_resets, "Fable", false),
			spend_json,
			scenario == "ultra" and breakdown(71, 19, 8, 2) or breakdown(64, 21, 12, 3),
			fable // 2
		)
	)
elseif scenario == "max" then
	local five_resets = now + 2 * HOUR + 10 * 60
	local week_resets = now + 1 * DAY + 3 * HOUR + 15 * 60
	write(
		"api.json",
		string.format(
			'{"five_hour": {"utilization": 35, "resets_at": "%s"}, "seven_day": {"utilization": 61, "resets_at": "%s"}, '
				.. '"seven_day_opus": null, "seven_day_sonnet": null, '
				.. '"extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null}, '
				.. '"limits": [%s, %s, %s], %s, %s}\n',
			iso(five_resets),
			iso(week_resets),
			limit("session", "session", 35, five_resets, nil, false),
			limit("weekly_all", "weekly", 61, week_resets, nil, true),
			limit("weekly_scoped", "weekly", 44, week_resets, "Fable", false),
			spend(false, 0, nil),
			breakdown(83, 12, 4, 1)
		)
	)
	ramp(history, "five_hour", 8, 35, 2, five_resets)
	ramp(history, "seven_day", 30, 61, 72, week_resets)
	ramp(history, "scoped:Fable", 20, 44, 72, week_resets)
elseif scenario == "apikey" then
	-- API-key mode: no OAuth login, so no credentials file; the statusLine cache has context and cost only.
	write(
		"rate_limits.json",
		string.format(
			'{"ts": %d, "rate_limits": null, "context": {"used_percentage": 7, "size": 1000000, "input_tokens": 69674}, '
				.. '"cost": {"total_usd": 1.234}, "model": "Opus", "session_id": "fake-session-1"}\n',
			now
		)
	)
else
	io.stderr:write("unknown scenario: " .. scenario .. "\n")
	os.exit(2)
end

write("history.csv", table.concat(history, "\n") .. (#history > 0 and "\n" or ""))
