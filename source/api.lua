-- source/api.lua - fetch the OAuth usage endpoint with curl (via awful.spawn, injected as deps.spawn).

local root = (...):gsub("source%.[^%.]+$", "")
local json = require(root .. "json")

local M = {}

M.BETA_HEADER = "oauth-2025-04-20"

local function shell_quote(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

--- Build the curl argv. Exposed for tests.
---@param opts table resolved options
---@param token string
---@param header_file string|nil file holding the Authorization header (keeps the token off argv)
---@return string[]
function M.argv(opts, token, header_file)
	return {
		opts.curl_cmd or "curl",
		"-sS",
		"--max-time",
		tostring(opts.timeout or 15),
		"-H",
		header_file and ("@" .. header_file) or ("Authorization: Bearer " .. token),
		"-H",
		"anthropic-beta: " .. M.BETA_HEADER,
		"-H",
		"Accept: application/json",
		"-A",
		opts.user_agent or "awesome-claude-usage",
		"-w",
		"\n%{http_code}",
		opts.api_url,
	}
end

--- Interpret a finished curl run. Exposed for tests.
---@return boolean ok
---@return table   raw decoded JSON on success, or { code, message, http } on failure
function M.interpret(stdout, stderr, reason, code, now)
	stdout = stdout or ""
	stderr = stderr or ""
	if reason ~= "exit" or code ~= 0 then
		local msg = stderr:gsub("^%s*curl:%s*%(%d+%)%s*", ""):gsub("%s+$", "")
		if msg == "" then
			msg = "curl failed (" .. tostring(reason) .. " " .. tostring(code) .. ")"
		end
		return false, { code = "network", message = msg, at = now }
	end
	local body, http = stdout:match("^(.*)\n(%d%d%d)%s*$")
	if not http then
		return false, { code = "parse", message = "no HTTP status in curl output", at = now }
	end
	http = tonumber(http)
	if http == 200 then
		local ok, data = pcall(json.decode, body)
		if not ok or type(data) ~= "table" then
			return false, { code = "parse", message = "response is not valid JSON", http = http, at = now }
		end
		return true, data
	elseif http == 401 or http == 403 then
		return false, { code = "unauthorized", message = "HTTP " .. http, http = http, at = now }
	elseif http == 429 then
		return false, { code = "rate_limited", message = "HTTP 429", http = http, at = now }
	elseif http >= 500 then
		return false, { code = "network", message = "HTTP " .. http, http = http, at = now }
	end
	return false, { code = "parse", message = "HTTP " .. http, http = http, at = now }
end

--- Directory for the short-lived header file: $XDG_RUNTIME_DIR/claude-usage, else the cache dir.
---@param opts table
---@param getenv function|nil defaults to os.getenv (injectable for tests)
---@return string
function M.header_dir(opts, getenv)
	local runtime = (getenv or os.getenv)("XDG_RUNTIME_DIR")
	if runtime and runtime ~= "" then
		return runtime .. "/claude-usage"
	end
	return (opts.cache_path or ""):match("^(.*)/[^/]+$") or "."
end

local counter = 0

--- Write "Authorization: Bearer <token>" to a new mode 600 file in a mode 700 directory,
--- for curl's `-H @file`. The caller removes the file after the request.
---@param dir string
---@param token string
---@return string|nil path
---@return string|nil err
function M.write_header(dir, token)
	local qdir = shell_quote(dir)
	os.execute("umask 077; mkdir -p -m 700 " .. qdir .. " 2>/dev/null; chmod 700 " .. qdir .. " 2>/dev/null")
	counter = counter + 1
	local id = tostring({}):match("0x(%x+)") or tostring({}):match("(%x+)$") or ""
	local path = string.format("%s/auth-%d-%d-%s.hdr", dir, os.time(), counter, id)
	os.execute("umask 077; : > " .. shell_quote(path) .. " 2>/dev/null")
	local f, err = io.open(path, "w")
	if not f then
		os.remove(path)
		return nil, err or "cannot create header file"
	end
	local ok, werr = f:write("Authorization: Bearer " .. token .. "\n")
	local cok, cerr = f:close()
	if not ok or not cok then
		os.remove(path)
		return nil, tostring(werr or cerr or "cannot write header file")
	end
	return path
end

--- Fetch usage. `deps.spawn(argv, cb)` must call cb(stdout, stderr, reason, code) like awful.spawn.easy_async;
--- a string return value means the program could not be started. `deps.write_header(dir, token)` and
--- `deps.remove(path)` are optional overrides (default: M.write_header, os.remove).
---@param opts table
---@param deps table
---@param token string
---@param cb fun(ok: boolean, result: table)
function M.fetch(opts, deps, token, cb)
	local remove = deps.remove or os.remove
	local okw, header_file = pcall(deps.write_header or M.write_header, M.header_dir(opts), token)
	if not okw or type(header_file) ~= "string" then
		header_file = nil -- fall back to the token on argv rather than not fetching at all
	end
	local function cleanup()
		if header_file then
			pcall(remove, header_file)
			header_file = nil
		end
	end
	local argv = M.argv(opts, token, header_file)
	local ok_spawn, err = pcall(deps.spawn, argv, function(stdout, stderr, reason, code)
		cleanup()
		local ok, res = M.interpret(stdout, stderr, reason, code, deps.now())
		cb(ok, res)
	end)
	if not ok_spawn or type(err) == "string" then
		cleanup()
		cb(false, { code = "network", message = "cannot run curl: " .. tostring(err), at = deps.now() })
	end
end

return M
