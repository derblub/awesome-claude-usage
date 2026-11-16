local notify = require("notify")
local config = require("config")

local function make()
	local sent = {}
	local n = notify.new(config.resolve({ notify_reset = true, notify_error = true }), {
		notify = function(args)
			sent[#sent + 1] = args
		end,
	})
	return n, sent
end

local function st(pct, resets_at)
	return { scoped = {}, seven_day = { percent = pct, resets_at = resets_at } }
end

describe("notify", function()
	it("notifies once per upward crossing", function()
		local n, sent = make()
		n:update(st(50, 5000), 1000)
		assert_eq(#sent, 0)
		n:update(st(80, 5000), 1100)
		assert_eq(#sent, 1)
		assert_eq(sent[1].message, "Weekly (7d) at 80% (resets in 1h 5m)")
		assert_eq(sent[1].urgency, "normal")
		n:update(st(85, 5000), 1200)
		assert_eq(#sent, 1)
		n:update(st(95, 5000), 1300)
		assert_eq(#sent, 2)
		assert_eq(sent[2].urgency, "critical")
	end)
	it("re-arms after a reset and reports it", function()
		local n, sent = make()
		n:update(st(95, 5000), 1000)
		assert_eq(#sent, 1)
		n:update(st(2, 9000), 6000)
		assert_eq(#sent, 2)
		assert_eq(sent[2].message, "Weekly (7d) window reset, now at 2%")
		n:update(st(80, 9000), 6100)
		assert_eq(#sent, 3)
	end)
	it("re-arms on a large percentage drop without reset info", function()
		local n, sent = make()
		n:update({ scoped = {}, five_hour = { percent = 90 } }, 1000)
		n:update({ scoped = {}, five_hour = { percent = 10 } }, 1100)
		n:update({ scoped = {}, five_hour = { percent = 76 } }, 1200)
		assert_eq(#sent, 3)
		assert_eq(sent[2].message, "Session (5h) window reset, now at 10%")
		assert_eq(sent[3].message, "Session (5h) at 76%")
	end)
	it("notifies persistent errors once", function()
		local n, sent = make()
		local function err(t)
			return { scoped = {}, error = { code = "network", at = t } }
		end
		n:update(err(1), 1)
		n:update(err(2), 2)
		assert_eq(#sent, 0)
		n:update(err(3), 3)
		n:update(err(4), 4)
		assert_eq(#sent, 1)
		n:update(st(1, 100), 5)
		n:update(err(6), 6)
		n:update(err(7), 7)
		n:update(err(8), 8)
		assert_eq(#sent, 2)
	end)
	it("counts a re-emitted failed state only once", function()
		local n, sent = make()
		local failed = { scoped = {}, error = { code = "network", at = 100 } }
		n:update(failed, 100)
		for i = 1, 5 do
			-- redraw: shallow copy sharing the same error table
			local copy = {}
			for k, v in pairs(failed) do
				copy[k] = v
			end
			n:update(copy, 100 + 60 * i)
		end
		assert_eq(#sent, 0)
	end)
	it("notifies three distinct failures once", function()
		local n, sent = make()
		for i = 1, 3 do
			local failed = { scoped = {}, error = { code = "network", at = i * 100 } }
			n:update(failed, i * 100)
			n:update(failed, i * 100 + 60)
		end
		assert_eq(#sent, 1)
		assert_eq(sent[1].message, "Network error")
	end)
	it("does not repeat a threshold notification once resets_at has passed", function()
		local n, sent = make()
		n:update(st(95, 5000), 1000)
		assert_eq(#sent, 1)
		for i = 0, 4 do
			n:update(st(95, 5000), 5000 + 60 * i)
		end
		assert_eq(#sent, 1)
	end)
	it("stays quiet for stale windows and never says 'expired'", function()
		local n, sent = make()
		n:update(st(95, 5000), 6000)
		n:update(st(95, 5000), 6060)
		assert_eq(#sent, 0)
		-- a fresh cycle at the same level re-arms
		n:update(st(95, 9000), 6120)
		assert_eq(#sent, 1)
		assert_eq(sent[1].message, "Weekly (7d) at 95% (resets in 48m)")
	end)
	it("re-arms for a new cycle at the same level", function()
		local n, sent = make()
		n:update(st(95, 5000), 1000)
		n:update(st(95, 5000), 1060)
		assert_eq(#sent, 1)
		n:update(st(95, 23000), 5100)
		assert_eq(#sent, 2)
		assert_eq(sent[2].message, "Weekly (7d) at 95% (resets in 4h 58m)")
	end)
	it("never says 'in now' in the last minute", function()
		local n, sent = make()
		n:update(st(95, 1030), 1000)
		assert_eq(#sent, 1)
		assert_eq(sent[1].message:find("in now", 1, true), nil)
		assert_eq(sent[1].message:find("expired", 1, true), nil)
	end)
	it("tracks scoped windows separately", function()
		local n, sent = make()
		n:update({ scoped = { { name = "Fable", percent = 91 } }, seven_day = { percent = 10 } }, 1)
		assert_eq(#sent, 1)
		assert_eq(sent[1].message, "Weekly (Fable) at 91%")
	end)
end)

describe("notify (no 5h limit)", function()
	it("stays quiet when the 5h window goes away and starts fresh when one comes back", function()
		local n, sent = make()
		n:update({ scoped = {}, five_hour = { percent = 80 }, seven_day = { percent = 10 } }, 1000)
		assert_eq(#sent, 1)
		n:update({ scoped = {}, seven_day = { percent = 10 }, no_session_limit = true }, 1100)
		assert_eq(#sent, 1)
		n:update({ scoped = {}, five_hour = { percent = 5 }, seven_day = { percent = 10 } }, 1200)
		assert_eq(#sent, 1, "no reset notice for a window that was gone")
	end)
	it("ignores a resets_at that wobbles by a second", function()
		local n, sent = make()
		n:update(st(80, 500000), 1000)
		assert_eq(#sent, 1)
		n:update(st(80, 499999), 1300)
		n:update(st(80, 500000), 1600)
		n:update(st(81, 500001), 1900)
		assert_eq(#sent, 1)
		-- a real new cycle still re-arms
		n:update(st(2, 1104800), 500100)
		n:update(st(80, 1104800), 500200)
		assert_eq(#sent, 3)
	end)
	it("sends one notification for several windows crossing at once", function()
		local n, sent = make()
		n:update({
			seven_day = { percent = 80, resets_at = 5000 },
			scoped = { { name = "Fable", percent = 95, resets_at = 5000 } },
		}, 1000)
		assert_eq(#sent, 1)
		assert_eq(sent[1].message, "Weekly (7d) at 80% (resets in 1h 6m)\nWeekly (Fable) at 95% (resets in 1h 6m)")
		assert_eq(sent[1].urgency, "critical")
	end)
end)

describe("notify (sessions)", function()
	local function make_s(opts, deps)
		local sent, gone = {}, {}
		deps = deps or {}
		deps.notify = function(args)
			sent[#sent + 1] = args
			return args
		end
		deps.dismiss = function(handle)
			gone[#gone + 1] = handle
		end
		return notify.new(config.resolve(opts or {}), deps), sent, gone
	end
	local function scan(status, since)
		return { list = { { pid = 7, session_id = "s7", name = "work", status = status, since = since } } }
	end

	it("stays quiet for an idle prompt unless asked", function()
		local n, sent = make_s()
		assert_eq(n:attention({ session_id = "s7" }, 1000, "idle_prompt"), false)
		assert_eq(#sent, 0)
		assert_eq(n:attention({ session_id = "s7" }, 1000, "permission_prompt"), true)
		local loud, sent2 = make_s({ notify_idle = true })
		assert_eq(loud:attention({ session_id = "s7" }, 1000, "idle_prompt"), true)
		assert_eq(#sent2, 1)
	end)
	it("withdraws the note when the session leaves the attention state", function()
		local n, sent, gone = make_s()
		n:attention(scan("attention").list[1], 1000)
		n:sync_sessions(scan("attention", 0), 1005)
		assert_eq(#gone, 0)
		n:sync_sessions(scan("working", 0), 1010)
		assert_eq(#gone, 1)
		assert_eq(gone[1], sent[1])
		-- the next prompt of the same session notifies at once, inside the repeat window
		assert_eq(n:attention(scan("attention").list[1], 1020), true)
		assert_eq(#sent, 2)
	end)
	it("keeps the note of a session that stays busy while it asks", function()
		local n, _, gone = make_s()
		n:attention({ pid = 7, session_id = "s7", status = "working" }, 1000, "permission_prompt")
		n:sync_sessions(scan("working", 500), 1010) -- status unchanged since before the note
		assert_eq(#gone, 0)
		n:sync_sessions(scan("working", 2), 1030) -- status rewritten after the note
		assert_eq(#gone, 1)
	end)
	it("withdraws on resolve and when the session is gone", function()
		local n, _, gone = make_s()
		n:attention({ pid = 7, session_id = "s7" }, 1000)
		n:resolve("s7")
		assert_eq(#gone, 1)
		n:attention({ pid = 7, session_id = "s7" }, 1001)
		n:sync_sessions({ list = {} }, 1002)
		assert_eq(#gone, 2)
		-- a hook note for a session the scan never listed is left alone
		n:attention({ session_id = "other" }, 1003)
		n:sync_sessions({ list = {} }, 1004)
		assert_eq(#gone, 2)
	end)
	it("replaces the note of a session instead of stacking", function()
		local n, sent, gone = make_s()
		n:attention({ pid = 7, session_id = "s7" }, 1000)
		assert_eq(n:attention({ pid = 7, session_id = "s7" }, 1030), false)
		assert_eq(n:attention({ pid = 7, session_id = "s7" }, 1070), true)
		assert_eq(#sent, 2)
		assert_eq(#gone, 1)
		assert_eq(gone[1], sent[1])
	end)
	it("stays quiet while the session's window has the focus", function()
		local parents = { [7] = 6, [6] = 5, [5] = 1 }
		local focused = 5
		local deps = {
			focused_pid = function()
				return focused
			end,
			parent_pid = function(pid)
				return parents[pid]
			end,
		}
		local n, sent = make_s(nil, deps)
		assert_eq(n:attention({ pid = 7, session_id = "s7" }, 1000), false)
		focused = 99
		assert_eq(n:attention({ pid = 7, session_id = "s7" }, 1001), true)
		assert_eq(#sent, 1)
		local loud, sent2 = make_s({ notify_focused = true }, deps)
		focused = 5
		assert_eq(loud:attention({ pid = 7, session_id = "s7" }, 1000), true)
		assert_eq(#sent2, 1)
	end)
end)
