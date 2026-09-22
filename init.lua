-- awesome-claude-usage - AwesomeWM wibar widget showing Claude Code rate-limit usage.
--
--   local claude_usage = require("claude_usage")
--   local w = claude_usage.new({ thresholds = { warn = 70, crit = 90 } })
--
-- Public surface:
--   claude_usage.new(opts)        -> wibox widget (also claude_usage(opts))
--   claude_usage.setup(opts)      -> start polling without a widget
--   claude_usage.state            -> current state table or nil
--   claude_usage.subscribe(fn)    -> fn(state) now and on every update; returns an unsubscribe function
--   claude_usage.refresh({force}) -> fetch now (the 429 backoff is still honoured)
--   claude_usage.stop()
--   claude_usage.format           -> text helpers (popup_lines, bar_text, relative, ...)

local prefix = (...) .. "."
local config = require(prefix .. "config")
local model = require(prefix .. "model")
local format = require(prefix .. "format")
local widget = require(prefix .. "widget")

local M = {
	version = config.version,
	format = format,
	model = model,
	opts = nil,
}

local function warn(msg)
	local ok, gears = pcall(require, "gears")
	if ok then
		gears.debug.print_warning("claude_usage: " .. msg)
	else
		io.stderr:write("claude_usage: " .. msg .. "\n")
	end
end

local function real_deps()
	local awful = require("awful")
	local gears = require("gears")
	local naughty = require("naughty")
	return {
		now = os.time,
		spawn = function(argv, cb)
			awful.spawn.easy_async(argv, cb)
		end,
		timer = function(args)
			return gears.timer(args)
		end,
		notify = function(args)
			naughty.notification(args)
		end,
		warn = warn,
	}
end

--- Resolve options and start the model. Idempotent; later calls return the first resolved options.
---@param opts table|nil
---@return table resolved options
function M.setup(opts)
	if M.opts then
		if opts and next(opts) ~= nil then
			warn("setup() called again with options; the first options stay in effect")
		end
		return M.opts
	end
	M.opts = config.resolve(opts, warn)
	model.setup(M.opts, real_deps())
	return M.opts
end

--- Create the wibar widget (starts polling on first use).
---@param opts table|nil
---@return table widget
function M.new(opts)
	local resolved = M.setup(opts)
	return widget.new(model, resolved)
end

function M.subscribe(a, b)
	return model.subscribe(b or a)
end

function M.refresh(args)
	return model.refresh(args)
end

function M.stop()
	model.stop()
	M.opts = nil
end

--- Diagnostic text for bug reports. Contains versions, effective options and the
--- current state, but never the token or account identifiers.
---@return string
function M.debug()
	local lines = { "awesome-claude-usage " .. M.version }
	local ok, awesome_ver = pcall(function()
		return awesome.version
	end)
	lines[#lines + 1] = "awesome " .. (ok and tostring(awesome_ver) or "?") .. ", " .. _VERSION
	local o = M.opts
	if o then
		lines[#lines + 1] = string.format(
			"options: style=%s icon=%s interval=%d sources=%s thresholds=%d/%d popup=%s",
			tostring(o.style),
			tostring(o.icon),
			o.interval,
			table.concat(o.sources, ","),
			o.thresholds.warn,
			o.thresholds.crit,
			tostring(o.popup)
		)
	else
		lines[#lines + 1] = "options: not set up"
	end
	local st = model.state
	if st then
		local b = model.backoff()
		lines[#lines + 1] = string.format(
			"state: source=%s fetched=%s stale=%s error=%s backoff_attempt=%s",
			tostring(st.source),
			st.fetched_at and os.date("%Y-%m-%d %H:%M:%S", st.fetched_at) or "nil",
			tostring(st.stale),
			st.error and (tostring(st.error.code) .. " (" .. tostring(st.error.message) .. ")") or "nil",
			b and tostring(b.attempt) or "?"
		)
		for _, line in ipairs(format.popup_lines(st, os.time(), o or {})) do
			lines[#lines + 1] = "  " .. line
		end
	else
		lines[#lines + 1] = "state: nil"
	end
	return table.concat(lines, "\n")
end

setmetatable(M, {
	__call = function(_, opts)
		return M.new(opts)
	end,
	__index = function(_, key)
		if key == "state" then
			return model.state
		end
		return nil
	end,
})

return M
