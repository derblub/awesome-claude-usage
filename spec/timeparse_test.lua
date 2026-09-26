local tp = require("timeparse")

describe("timeparse.iso8601", function()
	it("parses Z", function()
		assert_eq(tp.iso8601("2026-07-26T15:50:00Z"), 1785081000)
	end)
	it("parses +00:00 with fractional seconds", function()
		assert_eq(tp.iso8601("2026-09-23T15:00:00.261688+00:00"), 1790175600)
	end)
	it("applies positive offsets", function()
		assert_eq(tp.iso8601("2026-09-23T17:00:00+02:00"), 1790175600)
	end)
	it("applies negative offsets", function()
		assert_eq(tp.iso8601("2026-09-23T09:30:00-05:30"), 1790175600)
	end)
	it("accepts missing seconds", function()
		assert_eq(tp.iso8601("2026-07-26T15:50Z"), 1785081000)
	end)
	it("rejects garbage", function()
		assert_nil(tp.iso8601("yesterday"))
		assert_nil(tp.iso8601(nil))
		assert_nil(tp.iso8601("2026-07-26T15:50:00+2"))
	end)
	it("round-trips instants next to DST transitions in any TZ", function()
		for _, s in ipairs({
			"2026-03-29T01:00:00Z",
			"2026-03-29T01:30:00Z",
			"2026-03-29T02:30:00Z",
			"2026-03-29T03:00:00Z",
			"2026-10-25T00:30:00Z",
			"2026-10-25T01:00:00Z",
			"2026-10-25T01:30:00Z",
			"2026-10-25T02:30:00Z",
			"2024-03-10T07:00:00Z",
			"2024-11-03T06:00:00Z",
		}) do
			assert_eq(os.date("!%Y-%m-%dT%H:%M:%SZ", tp.iso8601(s)), s)
		end
	end)
	it("handles leap days, the epoch and pre-1970 dates", function()
		assert_eq(tp.iso8601("1970-01-01T00:00:00Z"), 0)
		assert_eq(tp.iso8601("2024-02-29T12:00:00Z"), 1709208000)
		assert_eq(tp.iso8601("2000-03-01T00:00:00Z"), 951868800)
		assert_eq(tp.iso8601("1969-12-31T23:59:59Z"), -1)
		assert_nil(tp.iso8601("2026-13-01T00:00:00Z"))
	end)
end)

describe("timeparse.relative", function()
	it("formats minutes, hours, days", function()
		assert_eq(tp.relative(1000 + 43 * 60, 1000), "43m")
		assert_eq(tp.relative(1000 + 2 * 3600 + 14 * 60, 1000), "2h 14m")
		assert_eq(tp.relative(1000 + 3 * 86400 + 4 * 3600, 1000), "3d 4h")
	end)
	it("handles boundaries", function()
		assert_eq(tp.relative(1059, 1000), "<1m")
		assert_eq(tp.relative(1000, 1000), "<1m")
		assert_eq(tp.relative(1060, 1000), "1m")
		assert_eq(tp.relative(1000 + 3600, 1000), "1h 0m")
		assert_eq(tp.relative(999, 1000), "expired")
		assert_nil(tp.relative(nil, 1000))
	end)
end)

describe("timeparse.age", function()
	it("formats ages", function()
		assert_eq(tp.age(1000, 1030), "just now")
		assert_eq(tp.age(1000, 1000 + 3 * 60), "3 min ago")
		assert_eq(tp.age(1000, 1000 + 2 * 3600), "2 h ago")
		assert_eq(tp.age(1000, 1000 + 90000), "1 d ago")
		assert_eq(tp.age(nil, 1000), "unknown age")
	end)
end)
