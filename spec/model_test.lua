local H = require("spec.helpers")
local model = require("model")
local config = require("config")

local function merge(a, b)
	for k, v in pairs(b or {}) do
		a[k] = v
	end
	return a
end

local function setup(overrides)
	model.stop()
	local deps = H.deps()
	local opts = config.resolve(merge({
		credentials_path = "spec/fixtures/credentials_ok.json",
		cache_path = "spec/fixtures/statusline.json",
		claude_json_path = "spec/fixtures/claude_json.json",
		jitter = 0,
		backoff = { 100, 200 },
		initial_delay = 5,
		history = false,
		sessions = false,
		fresh_cache_max_age = 0,
	}, overrides))
	model.setup(opts, deps)
	return deps, opts
end

local API_BODY = H.read("spec/fixtures/api_limits.json")

describe("model", function()
	it("primes the state from the statusline cache before the first fetch", function()
		local deps = setup()
		assert_eq(model.state.source, "statusline")
		assert_eq(model.state.five_hour.percent, 23.5)
		assert_eq(model.state.stale, false)
		assert_eq(#deps.spawned, 0)
		assert_eq(deps.timers[1].timeout, 5)
	end)

	it("replaces cached data with the API response and schedules the interval", function()
		local deps, opts = setup()
		deps.timers[1]:fire()
		assert_eq(#deps.spawned, 1)
		assert_eq(H.auth_header(deps, deps.spawned[1].argv), "Authorization: Bearer REDACTED-TOKEN")
		H.respond(deps, API_BODY, 200)
		assert_eq(model.state.source, "api")
		assert_eq(model.state.seven_day.percent, 67)
		assert_eq(model.state.subscription, "max")
		assert_nil(model.state.error)
		assert_eq(deps.timers[1].timeout, opts.interval)
		assert_eq(model.state.next_fetch_at, deps.t + opts.interval)
	end)

	it("falls back to the statusline cache on 429 and backs off", function()
		local deps = setup()
		deps.timers[1]:fire()
		H.respond(deps, "", 429)
		assert_eq(model.state.source, "statusline")
		assert_eq(model.state.error.code, "rate_limited")
		assert_eq(deps.timers[1].timeout, 100)
		deps.t = deps.t + 100
		deps.timers[1]:fire()
		H.respond(deps, "", 429)
		assert_eq(deps.timers[1].timeout, 200)
		deps.t = deps.t + 200
		deps.timers[1]:fire()
		H.respond(deps, API_BODY, 200)
		assert_eq(model.state.source, "api")
		assert_eq(deps.timers[1].timeout, 300)
	end)

	it("keeps the normal interval on 401 and does not back off", function()
		local deps = setup()
		deps.timers[1]:fire()
		H.respond(deps, "", 401)
		assert_eq(model.state.error.code, "unauthorized")
		assert_eq(model.state.source, "statusline")
		assert_eq(deps.timers[1].timeout, 300)
	end)

	it("skips curl entirely when the token is expired", function()
		local deps = setup({ credentials_path = "spec/fixtures/credentials_expired.json" })
		deps.timers[1]:fire()
		assert_eq(#deps.spawned, 0)
		assert_eq(model.state.error.code, "unauthorized")
		assert_eq(model.state.five_hour.percent, 23.5)
		assert_eq(model.state.subscription, "pro", "plan name from the expired credentials")
	end)

	it("uses ~/.claude.json when the statusline cache is missing and flags it stale", function()
		local deps = setup({ cache_path = "spec/fixtures/nope.json", sources = { "claude_json" } })
		assert_eq(model.state.source, "claude_json")
		assert_eq(model.state.fetched_at, 1758490000)
		assert_eq(model.state.stale, true)
		deps.timers[1]:fire()
		assert_eq(#deps.spawned, 0)
		assert_eq(model.state.source, "claude_json")
	end)

	it("reports no_source but keeps the last good data", function()
		local deps = setup({ cache_path = "spec/fixtures/nope.json", claude_json_path = "spec/fixtures/nope.json" })
		assert_nil(model.state)
		deps.timers[1]:fire()
		H.respond(deps, API_BODY, 200)
		assert_eq(model.state.source, "api")
		deps.timers[1]:fire()
		H.respond(deps, "", 503)
		assert_eq(model.state.error.code, "network")
		assert_eq(model.state.seven_day.percent, 67)
		assert_eq(model.state.source, "api")
	end)

	it("honours the backoff on forced refresh", function()
		local deps = setup()
		deps.timers[1]:fire()
		H.respond(deps, "", 429)
		assert_eq(model.refresh({ force = true }), false)
		assert_eq(#deps.spawned, 1)
		assert_eq(model.state.error.code, "rate_limited")
		deps.t = deps.t + 101
		assert_eq(model.refresh({ force = true }), true)
		assert_eq(#deps.spawned, 2)
	end)

	it("ignores overlapping refreshes while a fetch is in flight", function()
		local deps = setup()
		deps.timers[1]:fire()
		assert_eq(model.refresh({ force = true }), false)
		assert_eq(#deps.spawned, 1)
	end)

	it("survives throwing subscribers", function()
		local deps = setup()
		local calls = 0
		model.subscribe(function()
			calls = calls + 1
			error("boom")
		end)
		deps.timers[1]:fire()
		H.respond(deps, API_BODY, 200)
		assert_eq(calls, 2)
		assert_true(#deps.warnings >= 1)
		assert_eq(model.state.source, "api")
	end)

	it("notifies once when a window crosses a threshold", function()
		local deps = setup({ thresholds = { warn = 60, crit = 95 } })
		deps.timers[1]:fire()
		H.respond(deps, API_BODY, 200)
		assert_eq(#deps.notifications, 1)
		assert_true(deps.notifications[1].message:find("Weekly %(7d%) at 67%%") ~= nil)
		deps.timers[1]:fire()
		H.respond(deps, API_BODY, 200)
		assert_eq(#deps.notifications, 1)
	end)

	it("supports unsubscribe and stop", function()
		local deps = setup()
		local calls = 0
		local unsub = model.subscribe(function()
			calls = calls + 1
		end)
		assert_eq(calls, 1)
		unsub()
		deps.timers[1]:fire()
		H.respond(deps, API_BODY, 200)
		assert_eq(calls, 1)
		model.stop()
		assert_nil(model.state)
	end)
end)

describe("model (cache preference, sessions, history)", function()
	it("uses a fresh statusline cache between API polls and keeps the API-only details", function()
		-- cache with the same weekly reset as the API fixture (2026-09-23T15:00Z = 1790175600)
		local cache = io.open("spec/tmp/same_cycle.json", "w")
		cache:write('{"ts":1758560000,"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1758570000},'
			.. '"seven_day":{"used_percentage":41.2,"resets_at":1790175600}}}')
		cache:close()
		local deps = setup({ fresh_cache_max_age = 120, interval_idle = 900, cache_path = "spec/tmp/same_cycle.json" })
		deps.t = 1758560000 - 100
		-- first poll always asks the API
		deps.timers[1]:fire()
		assert_eq(#deps.spawned, 1)
		H.respond(deps, API_BODY, 200)
		assert_eq(model.state.source, "api")
		assert_eq(#model.state.scoped, 2)
		-- cache ts is 1758560000: fresh, API answer recent -> no network
		deps.t = 1758560000 + 60
		deps.timers[1]:fire()
		assert_eq(#deps.spawned, 1)
		assert_eq(model.state.source, "statusline")
		assert_eq(model.state.five_hour.percent, 23.5)
		assert_eq(#model.state.scoped, 2, "scoped limits carried over from the API")
		assert_eq(model.state.scoped[1].name, "Fable")
		assert_eq(model.state.scoped_from, 1758560000 - 100)
		assert_true(model.state.breakdown ~= nil)
		-- after interval_idle the API is asked again even though the cache is fresh
		deps.t = 1758560000 - 100 + 901
		local later = io.open("spec/tmp/same_cycle.json", "w")
		later:write('{"ts":' .. deps.t .. ',"rate_limits":{"five_hour":{"used_percentage":1,"resets_at":1758570000},'
			.. '"seven_day":{"used_percentage":2,"resets_at":1790175600}}}')
		later:close()
		deps.timers[1]:fire()
		assert_eq(#deps.spawned, 2, "no recent API answer -> API is called")
	end)

	it("polls slowly while no session works and fast while one does", function()
		local sdeps = {
			list = function()
				return { "1.json" }
			end,
			alive = function()
				return true
			end,
		}
		local dir = "spec/tmp/sessions"
		os.execute("mkdir -p " .. dir)
		local function write(status)
			local f = assert(io.open(dir .. "/1.json", "w"))
			f:write('{"pid":1,"status":"' .. status .. '","name":"s","statusUpdatedAt":1}')
			f:close()
		end
		write("idle")
		local deps = H.deps()
		deps.sessions = sdeps
		model.stop()
		local opts = config.resolve({
			credentials_path = "spec/fixtures/credentials_ok.json",
			cache_path = "spec/fixtures/nope.json",
			claude_json_path = "spec/fixtures/nope.json",
			jitter = 0,
			history = false,
			sessions = true,
			sessions_dir = dir,
			interval = 200,
			interval_idle = 900,
		})
		model.setup(opts, deps)
		assert_eq(model.state, nil)
		deps.timers[1]:fire()
		H.respond(deps, API_BODY, 200)
		assert_eq(deps.timers[1].timeout, 900, "idle interval")
		assert_eq(model.state.sessions.total, 1)
		-- a session starts working: refresh soon, then fast interval
		write("busy")
		deps.timers[3]:fire()
		assert_eq(deps.timers[1].timeout, 60)
		deps.timers[1]:fire()
		H.respond(deps, API_BODY, 200)
		assert_eq(deps.timers[1].timeout, 200, "active interval")
		-- needs attention: notification and flag
		write("waiting")
		deps.timers[3]:fire()
		assert_eq(#deps.notifications, 1)
		assert_true(deps.notifications[1].message:find("needs your attention") ~= nil)
		assert_eq(model.state.sessions.attention, 1)
		os.remove(dir .. "/1.json")
	end)

	it("records history and attaches a forecast", function()
		local path = "spec/tmp/model_history.csv"
		os.remove(path)
		local deps = setup({ history = true, history_path = path, cache_path = "spec/fixtures/nope.json" })
		deps.timers[1]:fire()
		H.respond(deps, API_BODY, 200)
		assert_eq(#model.samples(), 4)
		assert_true(model.state.forecast ~= nil)
		assert_nil(model.state.forecast.five_hour, "no rate from a single sample")
		deps.t = deps.t + 900
		deps.timers[1]:fire()
		local body = API_BODY:gsub('"percent": 3,', '"percent": 8,', 1)
		H.respond(deps, body, 200)
		assert_eq(#model.samples(), 8)
		local fc = model.state.forecast.five_hour
		assert_true(fc ~= nil and fc.rate > 0)
		assert_true(model.state.pace.seven_day == nil or model.state.pace.seven_day >= 0)
		os.remove(path)
	end)

	it("gives no forecast for a window whose reset passed without new data", function()
		local path = "spec/tmp/model_history_reset.csv"
		os.remove(path)
		local reset = 1790023800 -- five_hour.resets_at of the API fixture
		local deps = setup({ history = true, history_path = path, cache_path = "spec/fixtures/nope.json" })
		deps.t = reset - 1800
		deps.timers[1]:fire()
		H.respond(deps, API_BODY, 200)
		deps.t = reset - 900
		deps.timers[1]:fire()
		H.respond(deps, (API_BODY:gsub('"percent": 3,', '"percent": 40,', 1)), 200)
		assert_true(model.state.forecast.five_hour ~= nil, "a forecast before the reset")
		-- Past the reset with the API down: the window shows 0% (assumed), and the old cycle's
		-- samples must not give it a forecast.
		deps.t = reset + 60
		deps.timers[1]:fire()
		H.respond(deps, "oops", 500)
		assert_true(model.state.five_hour.assumed)
		assert_nil(model.state.forecast.five_hour)
		os.remove(path)
	end)
end)

describe("model (hook, cache watch)", function()
	it("reacts to a cache rewrite by reading the fresh cache", function()
		local watched = nil
		local deps = H.deps()
		deps.watch = function(path, cb)
			watched = { path = path, cb = cb }
		end
		model.stop()
		local opts = config.resolve({
			credentials_path = "spec/fixtures/credentials_ok.json",
			cache_path = "spec/fixtures/statusline.json",
			claude_json_path = "spec/fixtures/nope.json",
			jitter = 0,
			history = false,
			sessions = false,
			fresh_cache_max_age = 120,
			watch_cache = true,
		})
		local unwatched = 0
		deps.watch = function(path, cb)
			watched = { path = path, cb = cb }
			return function()
				unwatched = unwatched + 1
			end
		end
		model.setup(opts, deps)
		assert_true(watched ~= nil and watched.path == "spec/fixtures/statusline.json")
		deps.t = 1758560000 - 60
		deps.timers[1]:fire()
		H.respond(deps, API_BODY, 200)
		assert_eq(model.state.source, "api")
		deps.t = 1758560000 + 30
		watched.cb()
		assert_eq(#deps.spawned, 1, "fresh cache, recent API answer: no network")
		assert_eq(model.state.source, "statusline")
		assert_eq(model.state.next_fetch_at, deps.t + 300)
		-- debounced
		local before = deps.timers[1].again_calls
		watched.cb()
		assert_eq(deps.timers[1].again_calls, before)
		model.stop()
		assert_eq(unwatched, 1, "stop() ends the cache watch")
	end)

	it("notifies once from a hook and rescans sessions", function()
		local dir = "spec/tmp/sessions_hook"
		os.execute("mkdir -p " .. dir)
		local f = assert(io.open(dir .. "/7.json", "w"))
		f:write('{"pid":7,"sessionId":"sess-7","status":"busy","name":"hooked","statusUpdatedAt":1}')
		f:close()
		local deps = H.deps()
		deps.sessions = {
			list = function()
				return { "7.json" }
			end,
			alive = function()
				return true
			end,
		}
		model.stop()
		model.setup(config.resolve({
			credentials_path = "spec/fixtures/credentials_ok.json",
			cache_path = "spec/fixtures/nope.json",
			claude_json_path = "spec/fixtures/nope.json",
			jitter = 0,
			history = false,
			sessions = true,
			sessions_dir = dir,
		}), deps)
		model.hook("Notification", "permission_prompt", "sess-7")
		assert_eq(#deps.notifications, 1)
		assert_eq(deps.notifications[1].message, "hooked needs your attention")
		model.hook("Notification", "permission_prompt", "sess-7")
		assert_eq(#deps.notifications, 1, "deduplicated")
		model.hook("Notification", "auth_success", "sess-7")
		model.hook("Stop", "", "sess-7")
		assert_eq(#deps.notifications, 1)
		os.remove(dir .. "/7.json")
	end)
end)

local WEEK_RESET = 1790175600 -- seven_day.resets_at of the API fixture (2026-09-23T15:00Z)

local function write_cache(path, body)
	local f = assert(io.open(path, "w"))
	f:write(body)
	f:close()
end

describe("normalize.expire", function()
	local normalize = require("normalize")
	it("zeroes past windows on a copy", function()
		local st = {
			five_hour = { percent = 40, resets_at = 100 },
			seven_day = { percent = 70, resets_at = 500 },
			scoped = { { name = "Fable", percent = 50, resets_at = 100, kind = "weekly_scoped" }, { name = "O", percent = 1 } },
			source = "api",
		}
		local out = normalize.expire(st, 100)
		assert_eq(out.five_hour.percent, 0)
		assert_true(out.five_hour.assumed)
		assert_nil(out.five_hour.resets_at)
		assert_eq(out.seven_day, st.seven_day)
		assert_eq(out.scoped[1].name, "Fable")
		assert_eq(out.scoped[1].percent, 0)
		assert_true(out.scoped[1].assumed)
		assert_eq(out.scoped[2], st.scoped[2])
		assert_eq(out.source, "api")
		assert_eq(st.five_hour.percent, 40, "input untouched")
		assert_eq(st.scoped[1].percent, 50, "input untouched")
		assert_nil(normalize.expire(nil, 1))
	end)
end)

describe("model (robustness)", function()
	it("shows 0 % for windows whose reset has passed", function()
		local path = "spec/tmp/expiring.json"
		write_cache(path, '{"ts":1758560000,"rate_limits":{"five_hour":{"used_percentage":40,"resets_at":1758560100},'
			.. '"seven_day":{"used_percentage":70,"resets_at":1758900000}}}')
		local deps = setup({ cache_path = path, sources = { "statusline" }, stale_after = 100000 })
		assert_eq(model.state.five_hour.percent, 40)
		local shown = model.state.five_hour
		deps.t = 1758560101
		deps.timers[2]:fire() -- redraw
		assert_eq(model.state.five_hour.percent, 0)
		assert_true(model.state.five_hour.assumed)
		assert_nil(model.state.five_hour.resets_at)
		assert_eq(model.state.seven_day.percent, 70)
		assert_eq(shown.percent, 40, "the primed window itself is not mutated")
		deps.timers[1]:fire() -- finalize
		assert_eq(model.state.source, "statusline")
		assert_eq(model.state.five_hour.percent, 0)
		-- already expired while priming
		model.stop()
		local d2 = H.deps(1758560200)
		model.setup(config.resolve({ cache_path = path, sources = { "statusline" }, jitter = 0, history = false,
			sessions = false, credentials_path = "spec/fixtures/nope.json" }), d2)
		assert_eq(model.state.five_hour.percent, 0)
	end)

	it("keeps no per-model limits from before a weekly reset", function()
		local path = "spec/tmp/after_reset.json"
		local deps = setup({ fresh_cache_max_age = 120, cache_path = path })
		os.remove(path)
		deps.t = WEEK_RESET - 60
		deps.timers[1]:fire()
		H.respond(deps, API_BODY, 200)
		assert_eq(#model.state.scoped, 2)
		-- the cache after the reset carries no weekly window yet
		deps.t = WEEK_RESET + 30
		write_cache(path, '{"ts":' .. deps.t .. ',"rate_limits":{"five_hour":{"used_percentage":1,"resets_at":'
			.. (deps.t + 3600) .. "}}}")
		deps.timers[1]:fire()
		assert_eq(#deps.spawned, 1)
		assert_eq(model.state.source, "statusline")
		assert_true(model.state.seven_day.assumed)
		assert_eq(#model.state.scoped, 0)
		assert_nil(model.state.breakdown)
		assert_nil(model.state.spend)
		-- a weekly window without resets_at after the API reset passed
		write_cache(path, '{"ts":' .. deps.t .. ',"rate_limits":{"five_hour":{"used_percentage":1},'
			.. '"seven_day":{"used_percentage":2}}}')
		model.cache_changed()
		assert_eq(model.state.source, "statusline")
		assert_eq(model.state.seven_day.percent, 2)
		assert_eq(#model.state.scoped, 0)
	end)

	it("does not copy per-model limits whose own reset has passed", function()
		local path = "spec/tmp/scoped_reset.json"
		local body = API_BODY:gsub("2026%-09%-23T15:00:00%.261865", "2026-09-22T15:00:00", 1)
		local deps = setup({ fresh_cache_max_age = 120, cache_path = path })
		os.remove(path)
		deps.t = WEEK_RESET - 86400 - 60
		deps.timers[1]:fire()
		H.respond(deps, body, 200)
		assert_eq(#model.state.scoped, 2)
		deps.t = WEEK_RESET - 86400 + 30
		write_cache(path, '{"ts":' .. deps.t .. ',"rate_limits":{"five_hour":{"used_percentage":1},'
			.. '"seven_day":{"used_percentage":2,"resets_at":' .. WEEK_RESET .. "}}}")
		deps.timers[1]:fire()
		assert_eq(model.state.source, "statusline")
		assert_eq(#model.state.scoped, 1)
		assert_eq(model.state.scoped[1].name, "claude-opus-5")
	end)

	it("marks fallback states and neither records them nor counts them as API answers", function()
		local hist = "spec/tmp/fallback_history.csv"
		local path = "spec/tmp/fallback_cache.json"
		os.remove(hist)
		os.remove(path)
		local deps = setup({ history = true, history_path = hist, cache_path = path, fresh_cache_max_age = 120,
			sources = { "api", "statusline" } })
		deps.timers[1]:fire()
		H.respond(deps, API_BODY, 200)
		assert_nil(model.state.fallback)
		assert_eq(#model.samples(), 4)
		local t0 = deps.t
		deps.t = t0 + 800
		deps.timers[1]:fire()
		H.respond(deps, "", 503)
		assert_true(model.state.fallback)
		assert_eq(model.state.source, "api")
		assert_eq(model.state.seven_day.percent, 67)
		assert_eq(#model.samples(), 4, "fallback not recorded")
		-- the API answer is 1000 s old: a fresh cache must not replace the API call
		deps.t = t0 + 1000
		write_cache(path, '{"ts":' .. deps.t .. ',"rate_limits":{"five_hour":{"used_percentage":1},'
			.. '"seven_day":{"used_percentage":2}}}')
		deps.timers[1]:fire()
		assert_eq(#deps.spawned, 3)
		os.remove(hist)
	end)

	it("floors a fractional jitter and survives errors in the fetch path", function()
		local deps, opts = setup()
		opts.jitter = 7.5
		deps.timers[1]:fire()
		H.respond(deps, API_BODY, 200)
		assert_eq(model.state.source, "api")
		local d = deps.timers[1].timeout
		assert_true(d >= 293 and d <= 307, "delay " .. tostring(d))
		assert_true(deps.timers[1].started)
		-- an error inside the fetch path must not stop polling
		opts.jitter = 0
		local cache = require("source.statusline_cache")
		local read = cache.read
		cache.read = function()
			error("boom")
		end
		local ok = pcall(function()
			model.refresh()
		end)
		H.respond(deps, "", 401) -- falls through to the statusline source, which throws
		cache.read = read
		assert_true(ok)
		assert_true(deps.timers[1].started, "timer re-armed")
		assert_eq(deps.timers[1].timeout, opts.interval)
		assert_true(deps.warnings[#deps.warnings]:find("boom", 1, true) ~= nil)
		assert_eq(model.refresh(), true, "no longer in flight")
	end)

	it("treats a curl that cannot be started as a failed fetch", function()
		local deps = setup()
		deps.spawn_result = "execvp: no such file"
		deps.timers[1]:fire()
		assert_eq(#deps.spawned, 1)
		assert_eq(model.state.error.code, "network")
		assert_true(deps.timers[1].started)
		deps.spawn_result = nil
		deps.t = deps.t + 101 -- past the network backoff
		assert_eq(model.refresh(), true)
		assert_eq(#deps.spawned, 2)
	end)

	it("gives up on a fetch whose callback never comes", function()
		local deps, opts = setup()
		deps.timers[1]:fire()
		assert_eq(model.refresh(), false)
		deps.t = deps.t + opts.timeout + 31
		deps.timers[2]:fire() -- redraw notices it and re-arms the fetch timer
		assert_true(deps.timers[1].started)
		assert_eq(model.refresh(), true)
		assert_eq(#deps.spawned, 2)
		-- the late answer of the abandoned fetch is ignored
		deps.spawned[1].cb(API_BODY .. "\n200", "", "exit", 0)
		assert_eq(model.state.source, "statusline")
		assert_eq(model.refresh(), false, "second fetch still in flight")
		H.respond(deps, API_BODY, 200)
		assert_eq(model.state.source, "api")
		-- tick() and refresh() run the watchdog as well
		deps.timers[1]:fire()
		deps.t = deps.t + opts.timeout + 31
		deps.timers[1]:start()
		deps.timers[1]:fire()
		assert_eq(#deps.spawned, 4)
	end)

	it("ignores callbacks of fetches started before stop() or setup()", function()
		local deps = setup()
		deps.timers[1]:fire()
		local late = deps.spawned[1].cb
		model.stop()
		late(API_BODY .. "\n200", "", "exit", 0)
		assert_nil(model.state)
		local deps2 = setup()
		deps2.timers[1]:fire()
		late(API_BODY .. "\n200", "", "exit", 0)
		assert_eq(model.state.source, "statusline")
		assert_eq(model.refresh(), false, "the new fetch is still in flight")
		H.respond(deps2, API_BODY, 200)
		assert_eq(model.state.source, "api")
	end)
end)
