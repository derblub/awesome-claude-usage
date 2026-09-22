-- model.lua - singleton holding the usage state: scheduling, fallback chain, backoff, subscribers.
--
-- Dependencies are injected through `deps` so the module runs without awesome in tests:
--   deps.now()               -> epoch seconds
--   deps.spawn(argv, cb)     -> like awful.spawn.easy_async
--   deps.timer(args)         -> like gears.timer (fields timeout/single_shot/autostart/callback, :start/:stop/:again)
--   deps.notify(args)        -> like naughty.notification
--   deps.warn(msg)           -> log a warning

local prefix = (...):match("^(.*%.)") or ""
local normalize = require(prefix .. "normalize")
local backoff_mod = require(prefix .. "backoff")
local notify_mod = require(prefix .. "notify")
local credentials = require(prefix .. "source.credentials")
local api = require(prefix .. "source.api")
local statusline_cache = require(prefix .. "source.statusline_cache")
local claude_json = require(prefix .. "source.claude_json")

local M = {}

M.state = nil

local _opts, _deps, _timer, _redraw_timer, _backoff, _notifier
local _subs = {}
local _inflight = false
local _setup = false
local _last_good = nil
local _creds = nil

local REDRAW_INTERVAL = 60

local function now()
	return _deps.now()
end

local function warn(msg)
	if _deps and _deps.warn then
		pcall(_deps.warn, msg)
	end
end

local function shallow_copy(t)
	local out = {}
	for k, v in pairs(t or {}) do
		out[k] = v
	end
	return out
end

local function is_stale(st, t)
	return st.fetched_at ~= nil and (t - st.fetched_at) > _opts.stale_after
end

local function set_state(st)
	M.state = st
	if _notifier then
		local ok, err = pcall(_notifier.update, _notifier, st, now())
		if not ok then
			warn("notifier error: " .. tostring(err))
		end
	end
	local subs = shallow_copy(_subs)
	for _, fn in ipairs(subs) do
		local ok, err = pcall(fn, st)
		if not ok then
			warn("subscriber error: " .. tostring(err))
		end
	end
end

--- Re-arm the fetch timer. Returns the effective delay.
local function schedule_next(delay)
	local jitter = _opts.jitter or 0
	local d = delay
	if jitter > 0 then
		d = d + math.random(-jitter, jitter)
	end
	if d < 30 then
		d = 30
	end
	if _timer then
		_timer:stop()
		_timer.timeout = d
		_timer:again()
	end
	return d
end

local function finalize(st, delay, err)
	_inflight = false
	local t = now()
	st.scoped = st.scoped or {}
	st.error = err
	st.stale = is_stale(st, t)
	st.subscription = (_creds and _creds.subscription) or (M.state and M.state.subscription) or nil
	local d = schedule_next(delay or _opts.interval)
	st.next_fetch_at = t + d
	if normalize.has_data(st) then
		_last_good = st
	end
	set_state(st)
end

local function fallback_state()
	local st = shallow_copy(_last_good or {})
	st.scoped = st.scoped or {}
	return st
end

local function read_file_source(name, t)
	if name == "statusline" then
		local raw = statusline_cache.read(_opts.cache_path)
		if raw then
			return normalize.from_statusline(raw, t)
		end
	elseif name == "claude_json" then
		local raw = claude_json.read(_opts.claude_json_path)
		if raw then
			return normalize.from_claude_json(raw, t)
		end
	end
	return nil
end

local try_source

local function fetch_api(i, err, delay)
	local t = now()
	if _backoff:blocked(t) then
		err = err or { code = "rate_limited", message = "backing off", retry_at = _backoff.until_at, at = t }
		return try_source(i + 1, err, math.max(_backoff:remaining(t), 30))
	end
	local creds, cerr = credentials.read(_opts.credentials_path, t)
	if not creds then
		return try_source(i + 1, cerr, delay)
	end
	_creds = creds
	api.fetch(_opts, _deps, creds.token, function(ok, res)
		local t2 = now()
		if ok then
			_backoff:reset()
			local st = normalize.from_api(res, t2)
			st.source = "api"
			return finalize(st, _opts.interval, nil)
		end
		local d = delay
		if res.code == "rate_limited" or res.code == "network" then
			d = _backoff:fail(t2)
			res.retry_at = _backoff.until_at
		end
		return try_source(i + 1, res, d)
	end)
end

try_source = function(i, err, delay)
	local name = _opts.sources[i]
	if name == nil then
		return finalize(fallback_state(), delay, err or { code = "no_source", at = now() })
	end
	if name == "api" then
		return fetch_api(i, err, delay)
	elseif name == "statusline" or name == "claude_json" then
		local st = read_file_source(name, now())
		if st and normalize.has_data(st) then
			st.source = name
			return finalize(st, delay, err)
		end
		return try_source(i + 1, err, delay)
	end
	warn("unknown source '" .. tostring(name) .. "'")
	return try_source(i + 1, err, delay)
end

local function tick()
	if _inflight then
		return
	end
	_inflight = true
	try_source(1, nil, nil)
end

--- Paint something immediately from the file sources, before the first API fetch.
local function prime_from_cache()
	local t = now()
	for _, name in ipairs(_opts.sources) do
		if name ~= "api" then
			local st = read_file_source(name, t)
			if st and normalize.has_data(st) then
				st.source = name
				st.stale = is_stale(st, t)
				st.next_fetch_at = t + (_opts.initial_delay or 0)
				_last_good = st
				set_state(st)
				return
			end
		end
	end
end

local function redraw()
	if not M.state or _inflight then
		return
	end
	local st = shallow_copy(M.state)
	st.stale = is_stale(st, now())
	set_state(st)
end

--- Start monitoring. Idempotent.
---@param opts table resolved options (see config.lua)
---@param deps table injected dependencies
function M.setup(opts, deps)
	if _setup then
		return
	end
	_setup = true
	_opts = opts
	_deps = deps
	_backoff = backoff_mod.new(opts.backoff)
	_notifier = notify_mod.new(opts, deps)
	math.randomseed(os.time() + math.floor((os.clock() * 1000) % 1000))

	prime_from_cache()

	_timer = deps.timer({
		timeout = opts.initial_delay or 5,
		single_shot = true,
		autostart = true,
		callback = tick,
	})
	_redraw_timer = deps.timer({
		timeout = REDRAW_INTERVAL,
		single_shot = false,
		autostart = true,
		callback = redraw,
	})
end

--- Subscribe to state updates. Calls fn immediately when a state exists.
--- Works as model:subscribe(fn) and model.subscribe(fn).
---@return fun() unsubscribe
function M.subscribe(a, b)
	local fn = b or a
	_subs[#_subs + 1] = fn
	if M.state ~= nil then
		local ok, err = pcall(fn, M.state)
		if not ok then
			warn("subscriber error: " .. tostring(err))
		end
	end
	return function()
		for i, sub in ipairs(_subs) do
			if sub == fn then
				table.remove(_subs, i)
				return
			end
		end
	end
end

--- Fetch now. With { force = true } the timer is ignored, the 429 backoff is not.
---@return boolean started
function M.refresh(_args)
	if not _setup or _inflight then
		return false
	end
	local t = now()
	if _backoff:blocked(t) then
		local st = shallow_copy(M.state or { scoped = {} })
		st.error = { code = "rate_limited", message = "backing off", retry_at = _backoff.until_at, at = t }
		set_state(st)
		return false
	end
	if _timer then
		_timer:stop()
	end
	tick()
	return true
end

--- Stop timers and forget subscribers.
function M.stop()
	if _timer then
		_timer:stop()
		_timer = nil
	end
	if _redraw_timer then
		_redraw_timer:stop()
		_redraw_timer = nil
	end
	_subs = {}
	_inflight = false
	_setup = false
	_last_good = nil
	_creds = nil
	_notifier = nil
	M.state = nil
end

--- Internal: expose the backoff for the popup ("retry in …").
function M.backoff()
	return _backoff
end

return M
