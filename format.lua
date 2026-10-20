-- format.lua - text and colour helpers for the bar and the popup (pure Lua).

local prefix = (...):match("^(.*%.)") or ""
local timeparse = require(prefix .. "timeparse")
local normalize = require(prefix .. "normalize")
local brand = require(prefix .. "brand")

local M = {}

M.relative = timeparse.relative
M.age = timeparse.age
M.absolute = timeparse.absolute
M.has_data = normalize.has_data

local LEVEL_RANK = { normal = 0, warn = 1, crit = 2 }
M.LEVEL_RANK = LEVEL_RANK

--- Round half up to an integer.
function M.round(x)
	return math.floor(x + 0.5)
end

--- Integer percentage for display. Rounds down, so a shown value never crosses a threshold
--- the raw value has not reached (89.5 stays "89%" below crit = 90, 99.5 is not "100%").
function M.percent(x)
	return math.floor(x + 1e-9)
end

--- Duration until `target` for texts like "resets in ...", nil when it is due or past
--- (timeparse.relative says "expired" there; callers word that case themselves).
local function time_until(target, now)
	if type(target) ~= "number" or target < now then
		return nil
	end
	return timeparse.relative(target, now)
end

--- Threshold level for a percentage.
---@param pct number|nil
---@param thresholds { warn: number, crit: number }
---@return "normal"|"warn"|"crit"
function M.level_for(pct, thresholds)
	if type(pct) ~= "number" then
		return "normal"
	end
	if pct >= (thresholds.crit or 90) then
		return "crit"
	elseif pct >= (thresholds.warn or 75) then
		return "warn"
	end
	return "normal"
end

--- Look up a window by key: "five_hour", "seven_day" or "scoped:<name>".
---@param st table|nil
---@param key string
---@return table|nil
function M.window(st, key)
	if type(st) ~= "table" or type(key) ~= "string" then
		return nil
	end
	if key == "five_hour" or key == "seven_day" then
		return st[key]
	end
	local name = key:match("^scoped:(.+)$")
	if name then
		for _, w in ipairs(st.scoped or {}) do
			if w.name == name then
				return w
			end
		end
	end
	return nil
end

--- Percentage that drives colours: the highest window, or the one named by opts.color_window.
---@param st table|nil
---@param opts table|nil
---@return number|nil
function M.max_percent(st, opts)
	if type(st) ~= "table" then
		return nil
	end
	local which = opts and opts.color_window or "max"
	if which ~= "max" then
		local w = M.window(st, which)
		return w and w.percent or nil
	end
	local best = nil
	local function consider(w)
		if type(w) == "table" and type(w.percent) == "number" and (best == nil or w.percent > best) then
			best = w.percent
		end
	end
	consider(st.five_hour)
	consider(st.seven_day)
	for _, w in ipairs(st.scoped or {}) do
		consider(w)
	end
	return best
end

--- Overall level of a state.
function M.state_level(st, thresholds, opts)
	return M.level_for(M.max_percent(st, opts), thresholds)
end

--- Colour for the bar text, or nil to inherit the container's foreground.
--- Precedence: error without data > crit > warn > stale > normal.
---@param st table|nil
---@param opts table resolved options
---@return string|nil
function M.color_for(st, opts)
	local colors = opts.colors or {}
	if not M.has_data(st) then
		if st and st.error and not st.api_key_mode then
			return colors.error
		end
		return colors.normal
	end
	local level = M.state_level(st, opts.thresholds or {}, opts)
	if level == "crit" then
		return colors.crit
	elseif level == "warn" then
		return colors.warn
	elseif st.stale and colors.stale then
		return colors.stale
	end
	return colors.normal
end

local SHORT_ERROR = {
	unauthorized = "!auth",
	no_credentials = "!cred",
	rate_limited = "!429",
	network = "!net",
	parse = "!parse",
	no_source = "!none",
}

--- Short bar label for an error code.
function M.short_error(code)
	return SHORT_ERROR[code] or "!err"
end

local function pct_text(w)
	if type(w) == "table" and type(w.percent) == "number" then
		return string.format("%d%%", M.percent(w.percent))
	end
	return "--"
end

--- UTF-8 characters of a model name for its bar label, without a "claude-" prefix and with the
--- first letter uppercased ("claude-opus-5" -> O, p, u, s, -, 5).
local function label_chars(name)
	local s = tostring(name)
	local family = s:match("^[Cc]laude%-(.+)$")
	s = family or s
	local chars = {}
	for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		chars[#chars + 1] = ch
	end
	if chars[1] then
		chars[1] = chars[1]:upper()
	end
	return chars
end

--- Short bar labels for model names: the first letter ("Fable" -> "F", "claude-opus-5" -> "O"),
--- extended for names that would otherwise share a label ("Opus", "Omni" -> "Op", "Om").
---@param names string[]
---@return table labels  name -> label
function M.short_names(names)
	local chars, len, labels = {}, {}, {}
	for i, name in ipairs(names) do
		chars[i], len[i] = label_chars(name), 1
	end
	while true do
		for i = 1, #names do
			labels[i] = table.concat(chars[i], "", 1, math.min(len[i], #chars[i])):gsub("%s+$", "")
		end
		local grew = false
		for i = 1, #names do
			for j = 1, #names do
				if i ~= j and labels[i] == labels[j] and names[i] ~= names[j] and len[i] < #chars[i] then
					len[i] = len[i] + 1
					grew = true
					break
				end
			end
		end
		if not grew then
			break
		end
	end
	local out = {}
	for i, name in ipairs(names) do
		out[name] = labels[i]
	end
	return out
end

--- Whether the bar shows the session cost: opts.cost_in_bar = "auto" (API-key mode only), true, false.
---@param st table
---@param opts table
---@return boolean
function M.shows_cost(st, opts)
	local cost = st.session_cost
	if type(cost) ~= "table" or type(cost.usd) ~= "number" then
		return false
	end
	local mode = opts.cost_in_bar
	if mode == nil or mode == "auto" then
		return st.api_key_mode == true
	end
	return mode == true
end

--- Append the session cost and the attention flag. The cost sits behind a separator (" │ $1.23"),
--- so it reads neither as extra usage ("+$3.53") nor as part of the usage numbers; with nothing in
--- front of it (compact mode) it stands alone.
local function flags(text, st, opts)
	if M.shows_cost(st, opts) then
		local amount = M.money(st.session_cost.usd, "USD")
		if text:match("%S") then
			text = text .. (opts.cost_separator or " \226\148\130 ") .. amount
		else
			text = amount
		end
	end
	if opts.sessions_in_bar and st.sessions and (st.sessions.attention or 0) > 0 then
		text = text .. (opts.attention_flag or " !")
	end
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Plain text for the bar (no markup; the widget escapes it).
---@param st table|nil
---@param opts table resolved options
---@return string
function M.bar_text(st, opts)
	if type(opts.format) == "function" then
		local ok, text = pcall(opts.format, st, M)
		if ok and type(text) == "string" then
			return text
		end
	end
	local glyph = opts.show_glyph and (opts.glyph .. " ") or ""
	if st == nil then
		return glyph .. "…"
	end
	if not M.has_data(st) then
		-- An API key has no subscription limits: say so instead of a credentials error.
		if st.api_key_mode then
			return flags(glyph .. "API", st, opts)
		end
		local eg = opts.show_glyph and (opts.error_glyph .. " ") or ""
		if st.error then
			return eg .. M.short_error(st.error.code)
		end
		return glyph .. "--"
	end
	local parts = {}
	if not opts.compact then
		local keys = opts.bar_windows or { "five_hour", "seven_day", "scoped" }
		-- labels are only made unique among the models actually shown
		local names, seen = {}, {}
		local function add_name(name)
			name = tostring(name)
			if not seen[name] then
				seen[name] = true
				names[#names + 1] = name
			end
		end
		for _, key in ipairs(keys) do
			if key == "scoped" then
				for _, w in ipairs(st.scoped or {}) do
					add_name(w.name)
				end
			elseif key:match("^scoped:(.+)$") then
				add_name(key:match("^scoped:(.+)$"))
			end
		end
		local short = M.short_names(names)
		for _, key in ipairs(keys) do
			if key == "scoped" then
				for _, w in ipairs(st.scoped or {}) do
					parts[#parts + 1] = short[tostring(w.name)] .. " " .. pct_text(w)
				end
			else
				local name = key:match("^scoped:(.+)$")
				local label = key == "five_hour" and "5h" or key == "seven_day" and "7d" or name and short[name] or key
				parts[#parts + 1] = label .. " " .. pct_text(M.window(st, key))
			end
		end
	end
	local text = glyph .. table.concat(parts, opts.separator or " · ")
	local spending = st.spend and st.spend.enabled and ((st.spend.percent or 0) > 0 or (st.spend.used or 0) > 0)
	if opts.spend_in_bar and spending then
		local amount = (st.spend.used or 0) > 0 and M.money(st.spend.used, st.spend.currency):gsub(" ", "")
			or string.format("%d%%", M.percent(st.spend.percent or 0))
		text = text .. (opts.spend_flag or (" +" .. amount))
	end
	return flags(text, st, opts)
end

--- Model name for display, without a trailing context hint the context line already gives
--- ("Opus 5.5 (1M context)" -> "Opus 5.5"). nil for a missing or empty name.
---@param name any
---@return string|nil
function M.model_name(name)
	if name == nil then
		return nil
	end
	local s = tostring(name)
	local inner = s:match("%((.-)%)%s*$")
	if inner and inner:lower():find("context", 1, true) then
		s = s:gsub("%s*%b()%s*$", "")
	end
	s = s:gsub("^%s+", ""):gsub("%s+$", "")
	return s ~= "" and s or nil
end

--- One line for the active session's context window, nil when unknown:
--- "Context 9% of 1M · Opus 5.5".
---@param ctx table|nil
---@return string|nil
function M.context_text(ctx)
	if type(ctx) ~= "table" or type(ctx.percent) ~= "number" then
		return nil
	end
	local size = ""
	if ctx.size and ctx.size >= 1000 then
		size = ctx.size >= 1000000 and string.format(" of %.0fM", ctx.size / 1000000)
			or string.format(" of %dk", math.floor(ctx.size / 1000))
	end
	local model = M.model_name(ctx.model)
	return string.format("Context %d%%%s", M.round(ctx.percent), size) .. (model and (" · " .. model) or "")
end

--- Text and level for a forecast (see history.forecast).
---@param fc table|nil
---@param now integer
---@return string|nil text
---@return string level "normal"|"warn"|"crit"
function M.forecast_text(fc, now)
	if type(fc) ~= "table" then
		return nil, "normal"
	end
	if fc.exhaust_at and fc.exhaust_at <= now then
		return "limit reached", "crit"
	end
	if fc.exhaust_at then
		local left = fc.exhaust_at - now
		local level = left < 3600 and "crit" or "warn"
		return "at this pace empty in " .. (time_until(fc.exhaust_at, now) or "?"), level
	end
	if fc.at_reset then
		if fc.rate == 0 then
			return "no usage lately", "normal"
		end
		return string.format("at this pace ~%d%% at reset", M.round(fc.at_reset)), "normal"
	end
	if fc.rate and fc.rate > 0 then
		return string.format("+%.1f%%/h", fc.rate * 3600), "normal"
	end
	return nil, "normal"
end

--- One line describing the running Claude Code sessions: "2 sessions · 1 working · 1 idle".
---@param sessions table|nil summary from sessions.read
---@return string|nil
function M.sessions_text(sessions)
	if type(sessions) ~= "table" then
		return nil
	end
	if sessions.total == 0 then
		return "no Claude Code session running"
	end
	local parts = {}
	if sessions.attention > 0 then
		parts[#parts + 1] = sessions.attention .. " need" .. (sessions.attention == 1 and "s" or "") .. " your attention"
	end
	if sessions.working > 0 then
		parts[#parts + 1] = sessions.working .. " working"
	end
	if sessions.idle > 0 then
		parts[#parts + 1] = sessions.idle .. " idle"
	end
	local count = string.format("%d session%s", sessions.total, sessions.total == 1 and "" or "s")
	return count .. " · " .. table.concat(parts, " · ")
end

--- Human readable money amount.
function M.money(amount, currency)
	if type(amount) ~= "number" then
		return nil
	end
	currency = currency or "USD"
	if currency == "USD" then
		return string.format("$%.2f", amount)
	elseif currency == "EUR" then
		return string.format("%.2f €", amount)
	end
	return string.format("%.2f %s", amount, currency)
end

local SOURCE_NAME = {
	api = "API",
	statusline = "statusLine",
	desktop = "Claude Desktop",
	claude_json = "claude.json cache",
}

--- Human readable name of a data source.
function M.source_name(source)
	return SOURCE_NAME[source] or tostring(source or "unknown")
end

--- "Session cost $1.23", nil without a cost. Used outside API-key mode (cost_in_bar = true), where
--- the amount is what the session would cost on the API, not money spent.
---@param cost table|nil { usd }
---@return string|nil
function M.session_cost_text(cost)
	if type(cost) ~= "table" or type(cost.usd) ~= "number" then
		return nil
	end
	return "Session cost " .. M.money(cost.usd, "USD")
end

--- The API-key section of the popup: the active session's cost, nil outside API-key mode or
--- without a cost. The model is left to the context line.
---@param st table
---@return table|nil { label, value, text }
function M.api_key_row(st)
	local cost = st.session_cost
	if not st.api_key_mode or type(cost) ~= "table" or type(cost.usd) ~= "number" then
		return nil
	end
	return { label = "API key", value = M.money(cost.usd, "USD"), text = "spent in this session" }
end

--- Credential errors are expected without a Claude Code login (API key, Claude Desktop only).
--- Returns whether the error is such a case, and a calm note where it adds information (the
--- API-key section already says why there is no login).
---@return boolean expected
---@return string|nil note
local function credential_note(st)
	local code = type(st.error) == "table" and st.error.code or nil
	if code ~= "no_credentials" and code ~= "unauthorized" then
		return false, nil
	end
	if st.api_key_mode then
		return true, nil
	elseif st.source == "desktop" then
		return true, (code == "unauthorized" and "Claude Code login expired" or "No Claude Code login")
			.. " – using Claude Desktop's data"
	end
	return false, nil
end

--- Muted info lines for the popup: the session cost outside API-key mode (in API-key mode the
--- API-key section shows it) and a credentials note. The second value is the error text still
--- to show.
---@return string[] notes
---@return string|nil error
local function notes_and_error(st, now)
	local notes = {}
	if not st.api_key_mode then
		notes[#notes + 1] = M.session_cost_text(st.session_cost)
	end
	local expected, note = credential_note(st)
	notes[#notes + 1] = note
	if expected then
		return notes, nil
	end
	return notes, st.error and M.error_text(st.error, now) or nil
end

--- Human readable error message for the popup.
function M.error_text(err, now)
	if type(err) ~= "table" then
		return nil
	end
	local code = err.code
	if code == "unauthorized" then
		return "Token expired or rejected – run any `claude` command to refresh"
	elseif code == "no_credentials" then
		return "No Claude Code credentials found – log in with `claude`"
	elseif code == "rate_limited" then
		local rem = time_until(err.retry_at, now)
		if err.retry_at and not rem then
			return "Rate limited (429), retry due"
		end
		return "Rate limited (429)" .. (rem and (", retry in " .. rem) or "")
	elseif code == "network" then
		return "Network error" .. (err.message and (": " .. err.message) or "")
	elseif code == "parse" then
		return "Unexpected response" .. (err.message and (": " .. err.message) or "")
	elseif code == "no_source" then
		return "No data source available"
	end
	return err.message or tostring(code)
end

--- "resets in 2h 14m", "reset due" (in the past), "resets at <date>" (implausibly far away),
--- "no usage yet" (window not started), "reset passed, no new data yet" (normalize.expire) or nil
--- (reset time unknown, e.g. Claude Desktop data).
local function reset_text(w, now)
	if w and w.assumed then
		return w.expired and "reset passed, no new data yet" or "no usage yet"
	end
	if not w or not w.resets_at then
		return nil
	end
	local d = w.resets_at - now
	if d < 0 then
		return "reset due"
	elseif d > 8 * 86400 then
		return "resets at " .. timeparse.absolute(w.resets_at)
	end
	return "resets in " .. time_until(w.resets_at, now)
end

local function window_line(label, w, now)
	if not w then
		return nil
	end
	local parts = { string.format("%s: %d%%", label, M.percent(w.percent)) }
	parts[#parts + 1] = reset_text(w, now)
	local line = table.concat(parts, " – ")
	if w.is_active then
		line = line .. " *"
	end
	return line
end

--- Lines for the details popup. The first line is the title.
---@param st table|nil
---@param now integer
---@param opts table|nil resolved options
---@return string[]
function M.popup_lines(st, now, opts)
	opts = opts or {}
	local lines = {}
	local title = "Claude usage"
	if st and st.subscription then
		title = title .. " (" .. tostring(st.subscription) .. ")"
	end
	lines[#lines + 1] = title

	if st == nil then
		lines[#lines + 1] = "Loading…"
		return lines
	end

	if M.has_data(st) then
		local fcs = st.forecast or {}
		local function add_forecast(fc)
			local text = M.forecast_text(fc, now)
			if text then
				lines[#lines + 1] = "    " .. text
			end
		end
		lines[#lines + 1] = window_line("Session (5h)", st.five_hour, now) or "Session (5h): --"
		add_forecast(fcs.five_hour)
		lines[#lines + 1] = window_line("Weekly (7d)", st.seven_day, now) or "Weekly (7d): --"
		add_forecast(fcs.seven_day)
		if opts.popup_show_scoped ~= false then
			for _, w in ipairs(st.scoped or {}) do
				lines[#lines + 1] = "  " .. window_line(w.name or "Model", w, now)
			end
		end
		if opts.popup_show_breakdown ~= false and st.breakdown then
			local parts = {}
			for _, r in ipairs(st.breakdown) do
				if r.percent > 0 then
					parts[#parts + 1] = string.format("%s %d%%", r.name, M.round(r.percent))
				end
			end
			if #parts > 0 then
				lines[#lines + 1] = "Weekly by surface: " .. table.concat(parts, ", ")
			end
		end
		if opts.popup_show_spend ~= false and st.spend and st.spend.enabled then
			local used = M.money(st.spend.used, st.spend.currency)
			local limit = M.money(st.spend.limit, st.spend.currency)
			local text = "Extra usage: "
			if used and limit then
				text = text .. used .. " / " .. limit
			elseif used then
				text = text .. used
			end
			text = text .. string.format(" (%d%%)", M.percent(st.spend.percent or 0))
			lines[#lines + 1] = text
		end
	else
		lines[#lines + 1] = st.api_key_mode and "No subscription data" or "No usage data"
	end
	local key_row = M.api_key_row(st)
	if key_row then
		lines[#lines + 1] = key_row.label .. ": " .. key_row.value .. " " .. key_row.text
	end

	local context_line = M.context_text(st.context)
	if context_line then
		lines[#lines + 1] = context_line
	end
	local sessions_line = M.sessions_text(st.sessions)
	if sessions_line then
		lines[#lines + 1] = sessions_line
	end
	local notes, err_text = notes_and_error(st, now)
	for _, note in ipairs(notes) do
		lines[#lines + 1] = note
	end
	lines[#lines + 1] = ""
	if st.fetched_at then
		local line = "via " .. M.source_name(st.source) .. ", " .. timeparse.age(st.fetched_at, now)
		if st.stale then
			line = line .. " (stale)"
		end
		lines[#lines + 1] = line
	end
	if err_text then
		local prefix_text = M.has_data(st) and "Last check failed: " or ""
		lines[#lines + 1] = prefix_text .. err_text
	end
	if st.next_fetch_at then
		local rel = time_until(st.next_fetch_at, now)
		lines[#lines + 1] = rel and ("Next check in " .. rel) or "Checking…"
	end
	return lines
end

--- Background colour of the chip (style = "chip").
---@param st table|nil
---@param opts table resolved options
---@return string
function M.chip_color(st, opts)
	local chip = opts.chip or {}
	if not M.has_data(st) then
		if st and st.error and not st.api_key_mode then
			return chip.error or brand.palette.error
		end
		return chip.normal or brand.palette.orange
	end
	return brand.level_color(M.state_level(st, opts.thresholds or {}, opts), chip)
end

local SUBSCRIPTION_NAME = { max = "Max", pro = "Pro", team = "Team", enterprise = "Enterprise", free = "Free" }

--- Human readable plan name.
function M.plan_name(subscription)
	if type(subscription) ~= "string" or subscription == "" then
		return nil
	end
	return (SUBSCRIPTION_NAME[subscription:lower()] or subscription) .. " plan"
end

--- Structured content for the graphical popup.
---@param st table|nil
---@param now integer
---@param opts table resolved options
---@return table rows  { title, subtitle, windows = { {label, sub, percent, level, reset, active} }, spend, breakdown,
---  api_key = { label, value, text }, context, notes, sessions, footer, error, stale }
function M.popup_rows(st, now, opts)
	opts = opts or {}
	local thresholds = opts.thresholds or {}
	local rows = { title = "Claude usage", windows = {}, footer = {} }

	if st == nil then
		rows.subtitle = "Loading…"
		return rows
	end

	local sub = {}
	local plan = M.plan_name(st.subscription)
	if plan then
		sub[#sub + 1] = plan
	end
	if st.fetched_at then
		sub[#sub + 1] = "via " .. M.source_name(st.source)
		sub[#sub + 1] = timeparse.age(st.fetched_at, now)
	end
	if st.stale then
		sub[#sub + 1] = "stale"
	end
	rows.subtitle = table.concat(sub, " · ")
	rows.stale = st.stale or false

	if M.has_data(st) then
		local fcs = st.forecast or {}
		local paces = st.pace or {}
		local function add(key, label, subtext, w, fc, pace)
			local ftext, flevel = M.forecast_text(fc, now)
			rows.windows[#rows.windows + 1] = {
				key = key,
				label = label,
				sub = subtext,
				percent = w and w.percent or nil,
				level = w and M.level_for(w.percent, thresholds) or "normal",
				reset = reset_text(w, now),
				active = w and w.is_active or false,
				forecast = ftext,
				forecast_level = flevel,
				pace = pace,
			}
		end
		add("five_hour", "Session", "5-hour window", st.five_hour, fcs.five_hour, paces.five_hour)
		add("seven_day", "Weekly", "7-day window", st.seven_day, fcs.seven_day, paces.seven_day)
		if opts.popup_show_scoped ~= false then
			for _, w in ipairs(st.scoped or {}) do
				local name = w.name or "Model"
				add("scoped:" .. name, name, "weekly, this model", w, (fcs.scoped or {})[name], nil)
			end
		end
		if opts.popup_show_spend ~= false and st.spend and st.spend.enabled then
			local used = M.money(st.spend.used, st.spend.currency)
			local limit = M.money(st.spend.limit, st.spend.currency)
			local text = used and limit and (used .. " of " .. limit) or used or nil
			local level = "normal"
			if thresholds.spend and (st.spend.percent or 0) >= thresholds.spend then
				level = "warn"
			end
			rows.spend = { label = "Extra usage", text = text, percent = st.spend.percent or 0, level = level }
		end
		if opts.popup_show_breakdown ~= false and st.breakdown then
			local parts = {}
			for _, r in ipairs(st.breakdown) do
				if r.percent > 0 then
					parts[#parts + 1] = string.format("%s %d%%", r.name, M.round(r.percent))
				end
			end
			if #parts > 0 then
				rows.breakdown = table.concat(parts, " · ")
			end
		end
	else
		rows.empty = st.api_key_mode and "No subscription data" or "No usage data"
	end

	rows.api_key = M.api_key_row(st)

	rows.context = M.context_text(st.context)
	local notes, err_text = notes_and_error(st, now)
	rows.notes = notes
	if st.sessions then
		rows.sessions = {
			text = M.sessions_text(st.sessions),
			attention = st.sessions.attention or 0,
			list = st.sessions.list,
		}
	end
	rows.error = err_text
	if st.next_fetch_at then
		local rel = time_until(st.next_fetch_at, now)
		rows.footer[#rows.footer + 1] = rel and ("next check in " .. rel) or "checking…"
	end
	return rows
end

return M
