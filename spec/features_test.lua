local format = require("format")
local config = require("config")
local normalize = require("normalize")
local notify = require("notify")

local function st(five, seven, extra)
	local s = { scoped = {}, fetched_at = 1000, source = "api" }
	if five then
		s.five_hour = { percent = five }
	end
	if seven then
		s.seven_day = { percent = seven }
	end
	for k, v in pairs(extra or {}) do
		s[k] = v
	end
	return s
end

describe("format.window / color_window", function()
	local s = st(10, 80, { scoped = { { name = "Fable", percent = 95 } } })
	it("finds windows by key", function()
		assert_eq(format.window(s, "five_hour").percent, 10)
		assert_eq(format.window(s, "scoped:Fable").percent, 95)
		assert_nil(format.window(s, "scoped:Opus"))
	end)
	it("colours by the chosen window", function()
		assert_eq(format.max_percent(s, config.resolve({})), 95)
		assert_eq(format.max_percent(s, config.resolve({ color_window = "seven_day" })), 80)
		assert_eq(format.chip_color(s, config.resolve({ color_window = "five_hour" })), "#D97757")
		assert_eq(format.chip_color(s, config.resolve({ color_window = "seven_day" })), "#E39B3A")
		assert_eq(format.chip_color(s, config.resolve({})), "#C8442E")
	end)
end)

describe("format.bar_text (windows, compact, flags)", function()
	local s = st(10, 80, { scoped = { { name = "Fable", percent = 95 } } })
	it("honours bar_windows", function()
		local o = config.resolve({ show_glyph = false, icon = "glyph", bar_windows = { "seven_day", "scoped:Fable" } })
		assert_eq(format.bar_text(s, o), "7d 80% · F 95%")
		local d = config.resolve({ show_glyph = false, icon = "glyph" })
		assert_eq(format.bar_text(s, d), "5h 10% · 7d 80% · F 95%")
	end)
	it("is empty in compact mode except for flags", function()
		local o = config.resolve({ show_glyph = false, icon = "glyph", compact = true })
		assert_eq(format.bar_text(s, o), "")
		local s2 = st(1, 2, { sessions = { total = 1, attention = 1, working = 0, idle = 0 } })
		assert_eq(format.bar_text(s2, o), "\226\154\145")
	end)
	it("adds the spend marker while extra usage is consumed", function()
		local o = config.resolve({ show_glyph = false, icon = "glyph" })
		local s2 = st(1, 2, { spend = { enabled = true, percent = 12, used = 12.3 } })
		assert_eq(format.bar_text(s2, o), "5h 1% · 7d 2% +$12.30")
		s2.spend.used = nil
		assert_eq(format.bar_text(s2, o), "5h 1% · 7d 2% +12%")
		local flag = config.resolve({ show_glyph = false, icon = "glyph", spend_flag = " $" })
		assert_eq(format.bar_text(s2, flag), "5h 1% · 7d 2% $")
		s2.spend.percent, s2.spend.used = 0, 0
		assert_eq(format.bar_text(s2, o), "5h 1% · 7d 2%")
		s2.spend.percent = 5
		local quiet = config.resolve({ show_glyph = false, icon = "glyph", spend_in_bar = false })
		assert_eq(format.bar_text(s2, quiet), "5h 1% · 7d 2%")
	end)
end)

describe("context window", function()
	it("normalises the statusline cache context", function()
		local raw = { ts = 1000, rate_limits = { five_hour = { used_percentage = 1 } },
			context = { used_percentage = 41.2, size = 1000000, input_tokens = 412000 }, model = "Fable", session_id = "abc" }
		local s = normalize.from_statusline(raw, 1000)
		assert_eq(s.context.percent, 41.2)
		assert_eq(s.context.size, 1000000)
		assert_eq(s.context.at, 1000)
		assert_eq(format.context_text(s.context), "Context 41% of 1M · Fable")
		assert_eq(format.context_text({ percent = 8, size = 200000 }), "Context 8% of 200k")
		assert_eq(format.context_text({ percent = 9.4, size = 1000000, model = "Opus 5.5 (1M context)" }),
			"Context 9% of 1M · Opus 5.5", "the model's context hint is not repeated")
		assert_nil(format.context_text(nil))
		assert_nil(normalize.context_from({ ts = 1, rate_limits = {} }))
	end)
	it("shows the context line in the popup", function()
		local s = st(1, 2, { context = { percent = 41, size = 1000000, model = "Fable" } })
		local rows = format.popup_rows(s, 1000, config.resolve({}))
		assert_eq(rows.context, "Context 41% of 1M · Fable")
		local lines = format.popup_lines(s, 1000, config.resolve({}))
		local found = false
		for _, l in ipairs(lines) do
			if l == rows.context then
				found = true
			end
		end
		assert_true(found)
	end)
end)

describe("notify.attention", function()
	it("drops repeats within a minute per session", function()
		local sent = {}
		local n = notify.new(config.resolve({}), {
			notify = function(a)
				sent[#sent + 1] = a
			end,
		})
		assert_true(n:attention({ name = "repo", session_id = "s1" }, 1000))
		assert_eq(n:attention({ name = "repo", session_id = "s1" }, 1030), false)
		assert_true(n:attention({ name = "other", session_id = "s2" }, 1030))
		assert_true(n:attention({ name = "repo", session_id = "s1" }, 1061))
		assert_eq(#sent, 3)
		assert_eq(sent[1].message, "repo needs your attention")
		n:sessions({ { kind = "attention", session = { name = "repo", session_id = "s1" } } }, 1070)
		assert_eq(#sent, 3, "sessions() shares the dedupe window")
	end)
end)

describe("format.sessions_text and model_name", function()
	it("joins the session counts with the popup separator", function()
		assert_eq(format.sessions_text({ total = 1, working = 1, idle = 0, attention = 0 }), "1 session · 1 working")
		assert_eq(format.sessions_text({ total = 3, working = 1, idle = 1, attention = 1 }),
			"3 sessions · 1 needs your attention · 1 working · 1 idle")
		assert_eq(format.sessions_text({ total = 0, working = 0, idle = 0, attention = 0 }), "no Claude Code session running")
	end)
	it("strips only a trailing context hint from the model name", function()
		assert_eq(format.model_name("Opus 5.5 (1M context)"), "Opus 5.5")
		assert_eq(format.model_name("Opus 5.5 (preview)"), "Opus 5.5 (preview)")
		assert_eq(format.model_name("Fable"), "Fable")
		assert_nil(format.model_name(nil))
		assert_nil(format.model_name(" (1M context)"))
	end)
	it("puts the session cost behind a configurable separator", function()
		local s = { scoped = {}, five_hour = { percent = 1 }, seven_day = { percent = 99 },
			session_cost = { usd = 4.567 }, api_key_mode = true }
		assert_eq(format.bar_text(s, config.resolve({ show_glyph = false })), "5h 1% · 7d 99% │ $4.57")
		assert_eq(format.bar_text(s, config.resolve({ show_glyph = false, cost_separator = " | " })),
			"5h 1% · 7d 99% | $4.57")
		assert_eq(format.bar_text(s, config.resolve({ show_glyph = false, compact = true })), "$4.57",
			"no dangling separator in compact mode")
	end)
end)
