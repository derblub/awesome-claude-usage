-- Claude Desktop source, reset time borrowing, API-key mode and session cost.
local H = require("spec.helpers")
local model = require("model")
local config = require("config")
local normalize = require("normalize")
local format = require("format")
local desktop = require("source.desktop")

local T0 = 1758560000 -- H.deps() default time
local DESKTOP = "spec/fixtures/desktop_history.json"
local API_KEY_CACHE = "spec/fixtures/statusline_api_key.json"

local function write(path, body)
	local f = assert(io.open(path, "w"))
	f:write(body)
	f:close()
end

local function setup(overrides)
	model.stop()
	local deps = H.deps()
	local o = {
		credentials_path = "spec/fixtures/nope.json",
		cache_path = API_KEY_CACHE,
		claude_json_path = "spec/fixtures/nope.json",
		desktop_path = DESKTOP,
		jitter = 0,
		initial_delay = 5,
		history = false,
		sessions = false,
		fresh_cache_max_age = 0,
	}
	for k, v in pairs(overrides or {}) do
		o[k] = v
	end
	local opts = config.resolve(o)
	model.setup(opts, deps)
	return deps, opts
end

describe("source.desktop", function()
	it("returns the newest valid sample of any organisation", function()
		local s = desktop.read(DESKTOP)
		assert_eq(s.t, 1758559400000)
		assert_eq(s.org, "org-b")
		assert_eq(s.u.fh, 12)
	end)
	it("filters by organisation", function()
		local s = desktop.read(DESKTOP, "org-a")
		assert_eq(s.t, 1758558500000)
		assert_eq(s.u.sd, 80)
		assert_nil(desktop.read(DESKTOP, "org-x"))
	end)
	it("survives missing and malformed files", function()
		assert_nil(desktop.read("spec/fixtures/nope.json"))
		write("spec/tmp/desktop_bad.json", '{"version":2,"samples":{"a":1}}')
		assert_nil(desktop.read("spec/tmp/desktop_bad.json"))
		write("spec/tmp/desktop_bad.json", "not json")
		assert_nil(desktop.read("spec/tmp/desktop_bad.json"))
		write("spec/tmp/desktop_bad.json", "")
		assert_nil(desktop.read("spec/tmp/desktop_bad.json"))
	end)
end)

describe("normalize (desktop, cost, API key)", function()
	it("turns a Desktop sample into windows without reset times", function()
		local st = normalize.from_desktop({ t = 1758559400000, u = { fh = 12, sd = 40 } }, T0)
		assert_eq(st.fetched_at, 1758559400)
		assert_eq(st.five_hour.percent, 12)
		assert_nil(st.five_hour.resets_at)
		assert_eq(st.seven_day.percent, 40)
		assert_eq(#st.scoped, 0)
		local partial = normalize.from_desktop({ t = 1758559400000, u = { sd = 5 } }, T0)
		assert_nil(partial.five_hour)
		assert_eq(partial.seven_day.percent, 5)
		assert_eq(normalize.from_desktop(nil, T0).fetched_at, T0)
	end)

	it("reads the session cost", function()
		local raw = H.json(API_KEY_CACHE)
		local c = normalize.session_cost(raw)
		assert_eq(c.usd, 1.234)
		assert_eq(c.at, 1758559940)
		assert_eq(c.session_id, "sess-1")
		assert_nil(normalize.session_cost({ cost = { total_usd = "x" } }))
		assert_nil(normalize.session_cost({ cost = { total_usd = -1 } }))
		assert_nil(normalize.session_cost(nil))
	end)

	it("detects API-key mode only with a fresh cache, no rate limits and no login", function()
		local raw = H.json(API_KEY_CACHE)
		assert_true(normalize.api_key_mode(raw, false, T0, 900))
		assert_eq(normalize.api_key_mode(raw, true, T0, 900), false, "valid OAuth login")
		assert_eq(normalize.api_key_mode(raw, false, T0 + 3600, 900), false, "old cache")
		local sub = H.json("spec/fixtures/statusline.json")
		assert_eq(normalize.api_key_mode(sub, false, T0, 900), false, "subscription session")
		assert_true(normalize.api_key_mode({ ts = T0, cost = { total_usd = 0.5 } }, false, T0, 900), "cost alone")
	end)

	it("marks windows expired by normalize.expire", function()
		local out = normalize.expire({ five_hour = { percent = 40, resets_at = 10 }, scoped = {} }, 20)
		assert_true(out.five_hour.expired)
		local rows = format.popup_rows(out, 20, {})
		assert_eq(rows.windows[1].reset, "reset passed, no new data yet")
	end)
end)

describe("normalize.borrow_resets", function()
	local function desk(fh, sd, at)
		return normalize.from_desktop({ t = (at or T0 - 600) * 1000, u = { fh = fh, sd = sd } }, T0)
	end
	local refs = normalize.reset_refs({
		{ fetched_at = T0 - 1800, five_hour = { percent = 10, resets_at = T0 + 3600 },
			seven_day = { percent = 38, resets_at = T0 + 86400 } },
	}, {
		{ t = T0 - 7200, key = "five_hour", percent = 2, resets_at = T0 + 3600 },
	})

	it("takes the reset time of the newest reference in the same cycle", function()
		local st = normalize.borrow_resets(desk(12, 40), refs, T0)
		assert_eq(st.five_hour.resets_at, T0 + 3600)
		assert_eq(st.seven_day.resets_at, T0 + 86400)
	end)
	it("accepts a small drop within the tolerance", function()
		local st = normalize.borrow_resets(desk(9, 37), refs, T0)
		assert_eq(st.five_hour.resets_at, T0 + 3600)
	end)
	it("leaves the reset unknown after a drop (new cycle)", function()
		local st = normalize.borrow_resets(desk(1, 40), refs, T0)
		assert_nil(st.five_hour.resets_at)
		assert_eq(st.seven_day.resets_at, T0 + 86400)
	end)
	it("leaves the reset unknown once the reference reset has passed", function()
		local st = normalize.borrow_resets(desk(12, 40), refs, T0 + 3600)
		assert_nil(st.five_hour.resets_at)
		assert_eq(st.seven_day.resets_at, T0 + 86400)
	end)
	it("leaves the reset unknown for a sample from before the cycle", function()
		local st = normalize.borrow_resets(desk(12, 40, T0 - 5 * 3600), refs, T0)
		assert_nil(st.five_hour.resets_at)
	end)
	it("uses history samples and does not modify its input", function()
		local only_history = normalize.reset_refs({}, {
			{ t = T0 - 900, key = "seven_day", percent = 39, resets_at = T0 + 7200 },
			{ t = T0 - 800, key = "seven_day", percent = 39 },
		})
		local input = desk(12, 40)
		local st = normalize.borrow_resets(input, only_history, T0)
		assert_eq(st.seven_day.resets_at, T0 + 7200)
		assert_nil(st.five_hour.resets_at)
		assert_nil(input.seven_day.resets_at, "input untouched")
	end)
end)

describe("format (cost, API key)", function()
	local opts = config.resolve({ glyph = "G", error_glyph = "E", show_glyph = false })
	local cost = { usd = 1.234, at = T0 }
	local function st(extra)
		local s = { scoped = {}, fetched_at = T0 - 600, source = "desktop",
			five_hour = { percent = 12 }, seven_day = { percent = 40 } }
		for k, v in pairs(extra or {}) do
			s[k] = v
		end
		return s
	end

	it("appends the cost in API-key mode only by default", function()
		assert_eq(format.bar_text(st({ session_cost = cost, api_key_mode = true }), opts), "5h 12% · 7d 40% │ $1.23")
		assert_eq(format.bar_text(st({ session_cost = cost }), opts), "5h 12% · 7d 40%")
		local always = config.resolve({ show_glyph = false, cost_in_bar = true })
		assert_eq(format.bar_text(st({ session_cost = cost }), always), "5h 12% · 7d 40% │ $1.23")
		local never = config.resolve({ show_glyph = false, cost_in_bar = false })
		assert_eq(format.bar_text(st({ session_cost = cost, api_key_mode = true }), never), "5h 12% · 7d 40%")
	end)
	it("keeps extra usage and cost apart and works in compact mode", function()
		local s = st({ session_cost = cost, api_key_mode = true,
			spend = { enabled = true, percent = 10, used = 3.5, currency = "USD" } })
		assert_eq(format.bar_text(s, opts), "5h 12% · 7d 40% +$3.50 │ $1.23")
		local compact = config.resolve({ show_glyph = false, compact = true })
		assert_eq(format.bar_text(st({ session_cost = cost, api_key_mode = true }), compact), "$1.23")
	end)
	it("shows API instead of a credentials error without subscription data", function()
		local s = { scoped = {}, error = { code = "no_credentials" }, api_key_mode = true, session_cost = cost }
		assert_eq(format.bar_text(s, opts), "API │ $1.23")
		assert_eq(format.color_for(s, opts), opts.colors.normal)
		assert_eq(format.chip_color(s, opts), opts.chip.normal)
		assert_eq(format.bar_text({ scoped = {}, error = { code = "no_credentials" } }, opts), "!cred")
		local rows = format.popup_rows(s, T0, opts)
		assert_eq(rows.empty, "No subscription data")
		assert_eq(rows.api_key.value, "$1.23")
		assert_nil(rows.error)
	end)
	it("shows the cost in an API-key section, without duplicate notes", function()
		local s = st({ session_cost = cost, api_key_mode = true, error = { code = "no_credentials" },
			context = { percent = 9, size = 1000000, model = "Opus 5.5 (1M context)" } })
		local rows = format.popup_rows(s, T0, opts)
		assert_eq(rows.subtitle, "via Claude Desktop · 10 min ago")
		assert_eq(#rows.notes, 0, "source/age only in the header, no plain API-key note")
		assert_eq(rows.api_key.label, "API key")
		assert_eq(rows.api_key.value, "$1.23")
		assert_eq(rows.api_key.text, "spent in this session")
		assert_eq(rows.context, "Context 9% of 1M · Opus 5.5")
		assert_nil(rows.error, "no credentials error in API-key mode")
		local lines = table.concat(format.popup_lines(s, T0, opts), "\n")
		assert_true(lines:find("API key: $1.23 spent in this session\n", 1, true) ~= nil, lines)
		assert_true(lines:find("via Claude Desktop, 10 min ago", 1, true) ~= nil, lines)
		assert_true(lines:find("subscription data from", 1, true) == nil)
		assert_true(lines:find("Last check failed", 1, true) == nil)
		-- outside API-key mode the cost is a plain note and there is no API-key section
		local sub = format.popup_rows(st({ session_cost = cost }), T0, opts)
		assert_nil(sub.api_key)
		assert_eq(sub.notes[1], "Session cost $1.23")
		-- Desktop-only user (no Claude Code at all): a calm note, no "log in with claude"
		local d = format.popup_rows(st({ error = { code = "unauthorized" } }), T0, opts)
		assert_nil(d.error)
		assert_eq(d.notes[1], "Claude Code login expired – using Claude Desktop's data")
		-- other errors stay errors
		local n = format.popup_rows(st({ error = { code = "network" } }), T0, opts)
		assert_eq(n.error, "Network error")
	end)
end)

describe("model (desktop source, API-key mode)", function()
	it("falls back from api (no login) over a statusline without limits to Claude Desktop", function()
		local deps = setup()
		assert_eq(model.state.source, "desktop", "primed")
		deps.timers[1]:fire()
		assert_eq(#deps.spawned, 0)
		local st = model.state
		assert_eq(st.source, "desktop")
		assert_eq(st.error.code, "no_credentials")
		assert_eq(st.fetched_at, 1758559400)
		assert_eq(st.five_hour.percent, 12)
		assert_nil(st.five_hour.resets_at)
		assert_true(st.api_key_mode)
		assert_eq(st.session_cost.usd, 1.234)
		assert_eq(st.context.percent, 7)
		assert_eq(format.bar_text(st, config.resolve({ show_glyph = false })), "5h 12% · 7d 40% │ $1.23")
	end)

	it("keeps explicit source lists without the Desktop file", function()
		local deps = setup({ sources = { "api", "statusline", "claude_json" } })
		assert_nil(model.state)
		deps.timers[1]:fire()
		assert_eq(model.state.error.code, "no_credentials")
		assert_true(model.state.fallback)
		assert_true(model.state.api_key_mode)
		assert_eq(format.bar_text(model.state, config.resolve({ show_glyph = false })), "API │ $1.23")
	end)

	it("is not in API-key mode with a valid login", function()
		local deps = setup({ credentials_path = "spec/fixtures/credentials_ok.json" })
		deps.timers[1]:fire()
		H.respond(deps, "", 401)
		assert_eq(model.state.source, "desktop")
		assert_nil(model.state.api_key_mode)
		assert_eq(model.state.session_cost.usd, 1.234, "the cost is shown regardless of the mode")
	end)

	it("borrows reset times from history and records each Desktop sample once", function()
		local path = "spec/tmp/desktop_history.csv"
		write(path, string.format("%d,five_hour,10,%d\n%d,seven_day,38,%d\n",
			T0 - 1800, T0 + 3600, T0 - 1800, T0 + 86400))
		local deps = setup({ history = true, history_path = path })
		assert_eq(model.state.five_hour.resets_at, T0 + 3600)
		assert_eq(model.state.seven_day.resets_at, T0 + 86400)
		deps.timers[1]:fire()
		assert_eq(#model.samples(), 4)
		assert_eq(model.samples()[4].t, 1758559400, "recorded at the sample's own time")
		assert_eq(model.samples()[3].resets_at, T0 + 3600)
		deps.t = T0 + 300
		deps.timers[1]:fire()
		assert_eq(#model.samples(), 4, "same sample, not recorded again")
		assert_eq(model.state.five_hour.resets_at, T0 + 3600, "still borrowed (from its own last state)")
		os.remove(path)
	end)

	it("leaves the reset unknown after a drop", function()
		local path = "spec/tmp/desktop_history_drop.csv"
		write(path, string.format("%d,five_hour,50,%d\n", T0 - 1800, T0 + 3600))
		setup({ history = true, history_path = path })
		assert_nil(model.state.five_hour.resets_at)
		assert_nil(model.state.forecast.five_hour, "a single sample gives no rate")
		os.remove(path)
	end)

	it("prefers the newest file source over the configured order", function()
		local path = "spec/tmp/statusline_old.json"
		local body = H.read("spec/fixtures/statusline.json")
		write(path, (body:gsub('"ts"%s*:%s*%d+', '"ts":' .. (T0 - 7200))))
		local deps = setup({ cache_path = path })
		assert_eq(model.state.source, "desktop", "an old statusLine cache must not hide Claude Desktop")
		deps.timers[1]:fire()
		assert_eq(model.state.source, "desktop")
		os.remove(path)
		deps = setup({ cache_path = "spec/fixtures/statusline.json" })
		deps.timers[1]:fire()
		assert_eq(model.state.source, "statusline", "a newer statusLine cache still wins")
	end)

	it("prefers newer data it already has over an older Desktop sample", function()
		local deps = setup({ credentials_path = "spec/fixtures/credentials_ok.json" })
		deps.timers[1]:fire()
		H.respond(deps, H.read("spec/fixtures/api_limits.json"), 200)
		assert_eq(model.state.source, "api")
		deps.timers[1]:fire()
		H.respond(deps, "", 503)
		assert_eq(model.state.source, "api")
		assert_true(model.state.fallback)
	end)
end)

describe("config (desktop)", function()
	it("tries Claude Desktop after the statusLine and before ~/.claude.json", function()
		local s = config.defaults.sources
		assert_eq(table.concat(s, ","), "api,statusline,desktop,claude_json")
		assert_eq(config.defaults.cost_in_bar, "auto")
	end)
end)
