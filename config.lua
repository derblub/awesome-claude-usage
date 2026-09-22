-- config.lua - option defaults and merging (pure Lua).

local M = {}

M.version = "0.1.0"

local home = os.getenv("HOME") or ""
local xdg_cache = os.getenv("XDG_CACHE_HOME") or (home .. "/.cache")

M.defaults = {
	-- Polling
	interval = 300, -- seconds between successful API fetches (minimum 120)
	initial_delay = 5, -- seconds after startup before the first fetch
	jitter = 30, -- random +/- seconds added to every interval
	timeout = 15, -- curl --max-time
	backoff = { 300, 600, 1200, 1800 }, -- delays after consecutive 429/5xx/network errors
	user_agent = "awesome-claude-usage/" .. M.version .. " (+https://github.com/derblub/awesome-claude-usage)",
	sources = { "api", "statusline", "claude_json" }, -- priority order; drop entries to disable
	api_url = "https://api.anthropic.com/api/oauth/usage",
	credentials_path = home .. "/.claude/.credentials.json",
	claude_json_path = home .. "/.claude.json",
	cache_path = xdg_cache .. "/claude-usage/rate_limits.json",
	stale_after = 3600, -- data older than this is flagged as stale
	curl_cmd = "curl",

	-- Appearance
	font = nil, -- nil -> beautiful.font
	glyph = "\u{f0e7}", -- Nerd Font bolt; alternatives: "\u{f06a9}" (robot), "\u{f0a3a}" (head)
	error_glyph = "\u{f071}", -- Nerd Font warning triangle
	show_glyph = true,
	format = nil, -- fun(state, fmt) -> plain text; nil for the default "5h 3% · 7d 67%"
	separator = " · ",
	forced_width = nil,
	align = "center",
	thresholds = { warn = 75, crit = 90, spend = nil },
	colors = { normal = nil, warn = "#e5c07b", crit = "#e06c75", error = "#5c6370", stale = nil },
	color_target = "text", -- "text" wraps the text in a pango span; "none" leaves colors to the theme

	-- Popup
	popup = true,
	popup_placement = nil, -- fun(popup, geometry) override
	popup_bg = nil,
	popup_fg = nil,
	popup_border_color = nil,
	popup_border_width = 1,
	popup_show_scoped = true,
	popup_show_spend = true,
	popup_show_breakdown = true,

	-- Notifications
	notify_threshold = true,
	notify_reset = false,
	notify_error = false,
	notify_timeout = 8,
	notify_icon = nil,

	-- Mouse buttons
	on_click = "xterm -e claude", -- string -> spawned with a shell; function -> called with state
	on_right_click = nil, -- default: forced refresh
	on_middle_click = nil, -- default: pin/unpin the popup
}

-- Keys whose table values are merged key by key instead of replaced.
local deep_keys = { thresholds = true, colors = true }

local function copy(t)
	local out = {}
	for k, v in pairs(t) do
		if type(v) == "table" then
			out[k] = copy(v)
		else
			out[k] = v
		end
	end
	return out
end

--- Merge user options over the defaults.
---@param opts table|nil
---@param warn fun(msg: string)|nil
---@return table
function M.resolve(opts, warn)
	local out = copy(M.defaults)
	for k, v in pairs(opts or {}) do
		if deep_keys[k] and type(v) == "table" then
			for kk, vv in pairs(v) do
				out[k][kk] = vv
			end
		else
			out[k] = v
		end
	end
	if type(out.interval) ~= "number" or out.interval < 120 then
		if warn then
			warn("interval below 120 s hits the usage endpoint's rate limit; using 120")
		end
		out.interval = 120
	end
	if type(out.backoff) ~= "table" or #out.backoff == 0 then
		out.backoff = copy(M.defaults.backoff)
	end
	return out
end

return M
