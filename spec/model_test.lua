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
		assert_eq(deps.spawned[1].argv[6], "Authorization: Bearer REDACTED-TOKEN")
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
