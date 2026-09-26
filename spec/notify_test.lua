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
