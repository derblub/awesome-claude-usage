local api = require("source.api")
local config = require("config")
local credentials = require("source.credentials")

describe("source.api.argv", function()
	it("builds a curl command without a shell", function()
		local argv = api.argv(config.resolve({ timeout = 7, api_url = "http://x/usage" }), "TOK")
		assert_eq(argv[1], "curl")
		assert_eq(argv[4], "7")
		assert_eq(argv[6], "Authorization: Bearer TOK")
		assert_eq(argv[8], "anthropic-beta: oauth-2025-04-20")
		assert_eq(argv[#argv], "http://x/usage")
	end)
	it("reads the Authorization header from a file when given one", function()
		local argv = api.argv(config.resolve({ api_url = "http://x/usage" }), "TOK", "/run/h")
		assert_eq(argv[6], "@/run/h")
		for _, a in ipairs(argv) do
			assert_nil(a:find("TOK", 1, true), "token on argv")
		end
	end)
end)

describe("source.api header file", function()
	it("prefers XDG_RUNTIME_DIR and falls back to the cache dir", function()
		local opts = { cache_path = "/c/claude-usage/rate_limits.json" }
		assert_eq(api.header_dir(opts, function()
			return "/run/user/1"
		end), "/run/user/1/claude-usage")
		assert_eq(api.header_dir(opts, function()
			return nil
		end), "/c/claude-usage/auth")
	end)
	it("tries the next directory when the first cannot be written", function()
		local opts = { cache_path = "/c/claude-usage/rate_limits.json" }
		local tried = {}
		local path = api.write_header_any(opts, "TOK", function(dir)
			tried[#tried + 1] = dir
			if #tried == 1 and dir:find("/run/", 1, true) then
				return nil, "read-only"
			end
			return dir .. "/auth-1.hdr"
		end)
		assert_eq(path, tried[#tried] .. "/auth-1.hdr")
		assert_eq(tried[#tried], "/c/claude-usage/auth")
		assert_nil(api.write_header_any(opts, "TOK", function()
			error("boom")
		end))
	end)
	it("writes a private header file", function()
		local dir = "spec/tmp/hdr dir'x"
		local path = assert(api.write_header(dir, "TOK"))
		local f = io.open(path, "r")
		assert_eq(f:read("*a"), "Authorization: Bearer TOK\n")
		f:close()
		local p = io.popen("stat -c %a " .. "'spec/tmp/hdr dir'\\''x' '" .. path:gsub("'", "'\\''") .. "'")
		local modes = p:read("*a")
		p:close()
		assert_eq(modes, "700\n600\n")
		local second = assert(api.write_header(dir, "TOK"))
		assert_true(second ~= path, "unique names")
		os.remove(path)
		os.remove(second)
		os.remove(dir)
	end)
end)

describe("source.api.fetch", function()
	local opts = config.resolve({ api_url = "http://x/usage", cache_path = "spec/tmp/api/rate_limits.json" })
	local function deps(spawn)
		local d = { removed = {} }
		d.now = function()
			return 5
		end
		d.write_header = function(dir, token)
			d.header_dir = dir
			return "/fake/hdr-" .. token
		end
		d.remove = function(path)
			d.removed[#d.removed + 1] = path
		end
		d.spawn = spawn
		return d
	end
	it("passes the header file and removes it after the run", function()
		local seen
		local d = deps(function(argv, cb)
			seen = argv
			cb('{"a":1}\n200', "", "exit", 0)
			return 42
		end)
		local got
		api.fetch(opts, d, "TOK", function(ok, res)
			got = { ok = ok, res = res }
		end)
		assert_eq(seen[6], "@/fake/hdr-TOK")
		assert_true(got.ok)
		assert_eq(got.res.a, 1)
		assert_eq(#d.removed, 1)
		assert_eq(d.removed[1], "/fake/hdr-TOK")
	end)
	it("treats a string from spawn as a failure and cleans up", function()
		local calls = 0
		local got
		local d = deps(function()
			return "No such file or directory"
		end)
		api.fetch(opts, d, "TOK", function(ok, res)
			calls = calls + 1
			got = { ok = ok, res = res }
		end)
		assert_eq(calls, 1)
		assert_eq(got.ok, false)
		assert_eq(got.res.code, "network")
		assert_eq(got.res.message, "cannot run curl: No such file or directory")
		assert_eq(d.removed[1], "/fake/hdr-TOK")
	end)
	it("cleans up when spawn throws", function()
		local got
		local d = deps(function()
			error("boom")
		end)
		api.fetch(opts, d, "TOK", function(ok, res)
			got = { ok = ok, res = res }
		end)
		assert_eq(got.ok, false)
		assert_eq(got.res.code, "network")
		assert_eq(#d.removed, 1)
	end)
	it("falls back to the argv header when the file cannot be written", function()
		local seen
		local d = deps(function(argv)
			seen = argv
		end)
		d.write_header = function()
			return nil, "read-only"
		end
		api.fetch(opts, d, "TOK", function() end)
		assert_eq(seen[6], "Authorization: Bearer TOK")
		assert_eq(#d.removed, 0)
	end)
end)

describe("source.api.interpret", function()
	it("decodes a 200 body", function()
		local ok, data = api.interpret('{"five_hour":{"utilization":5}}\n200', "", "exit", 0, 1)
		assert_true(ok)
		assert_eq(data.five_hour.utilization, 5)
	end)
	it("classifies status codes", function()
		local _, e = api.interpret("\n401", "", "exit", 0, 1)
		assert_eq(e.code, "unauthorized")
		_, e = api.interpret("\n403", "", "exit", 0, 1)
		assert_eq(e.code, "unauthorized")
		_, e = api.interpret("rate\n429", "", "exit", 0, 1)
		assert_eq(e.code, "rate_limited")
		_, e = api.interpret("\n503", "", "exit", 0, 1)
		assert_eq(e.code, "network")
		_, e = api.interpret("\n418", "", "exit", 0, 1)
		assert_eq(e.code, "parse")
	end)
	it("treats curl failures as network errors", function()
		local _, e = api.interpret("", "curl: (6) Could not resolve host: api.anthropic.com", "exit", 6, 1)
		assert_eq(e.code, "network")
		assert_eq(e.message, "Could not resolve host: api.anthropic.com")
	end)
	it("rejects invalid JSON and missing status", function()
		local _, e = api.interpret("not json\n200", "", "exit", 0, 1)
		assert_eq(e.code, "parse")
		_, e = api.interpret("{}", "", "exit", 0, 1)
		assert_eq(e.code, "parse")
	end)
end)

describe("source.credentials", function()
	it("reads a valid file", function()
		local c, err = credentials.read("spec/fixtures/credentials_ok.json", 1758560000)
		assert_nil(err)
		assert_eq(c.token, "REDACTED-TOKEN")
		assert_eq(c.subscription, "max")
		assert_eq(c.expires_at, 4102444800)
	end)
	it("reports an expired token without exposing it", function()
		local c, err = credentials.read("spec/fixtures/credentials_expired.json", 1758560000)
		assert_nil(c)
		assert_eq(err.code, "unauthorized")
	end)
	it("reports a missing file", function()
		local c, err = credentials.read("spec/fixtures/does-not-exist.json", 1)
		assert_nil(c)
		assert_eq(err.code, "no_credentials")
	end)
end)
