-- notify.lua - desktop notifications on threshold crossings (pure logic; deps.notify does the display).

local prefix = (...):match("^(.*%.)") or ""
local format = require(prefix .. "format")
local normalize = require(prefix .. "normalize")

local Notifier = {}
Notifier.__index = Notifier

local M = {}

---@param opts table resolved options
---@param deps table { notify = fun(args) }
function M.new(opts, deps)
	return setmetatable({
		opts = opts,
		deps = deps,
		windows = {}, -- key -> { level, percent, resets_at }
		fail_count = 0,
		error_notified = false,
		last_error = nil, -- error table of the last counted failure (re-emits of a state share it)
		last_error_at = nil,
		last_attention = {}, -- session key -> epoch of the last attention notification
		notes = {}, -- session key -> { handle, at, seen, pid, session_id } of the visible attention note
	}, Notifier)
end

local ATTENTION_WINDOW = 60
-- The API reports the same reset a second earlier or later from one answer to the next. A real new
-- cycle moves resets_at by hours, so anything within this slack is the same cycle.
local RESET_SLACK = 300
local URGENCY_RANK = { low = 1, normal = 2, critical = 3 }

local function session_key(session)
	return session and (session.session_id or session.pid or session.name) or "unknown"
end

--- True when the focused window belongs to the session: its process is the session's process or
--- one of its ancestors (terminal -> shell -> claude, or the desktop app -> claude).
function Notifier:focused(session)
	local deps = self.deps
	if not session or not session.pid or type(deps.focused_pid) ~= "function" or type(deps.parent_pid) ~= "function" then
		return false
	end
	local ok, focused = pcall(deps.focused_pid)
	if not ok or not focused then
		return false
	end
	local pid = session.pid
	for _ = 1, 16 do
		if pid == focused then
			return true
		end
		local ok_parent, parent = pcall(deps.parent_pid, pid)
		if not ok_parent or type(parent) ~= "number" or parent <= 1 then
			return false
		end
		pid = parent
	end
	return false
end

--- Take the session's attention note off the screen (and out of notification histories).
---@param key any session key
---@param rearm boolean|nil true: the session moved on, so its next prompt may notify at once
function Notifier:withdraw(key, rearm)
	local note = self.notes[key]
	if note then
		self.notes[key] = nil
		if note.handle ~= nil and type(self.deps.dismiss) == "function" then
			pcall(self.deps.dismiss, note.handle)
		end
	end
	if rearm then
		self.last_attention[key] = nil
	end
end

--- The session answered or ended its turn (hook events): its note is obsolete.
function Notifier:resolve(session_id)
	if session_id ~= nil and session_id ~= "" then
		self:withdraw(session_id, true)
	end
end

--- Withdraw attention notes whose session has moved on. Call with every sessions scan.
---@param summary table sessions.read() result
function Notifier:sync_sessions(summary, now)
	if next(self.notes) == nil then
		return
	end
	local by_id, by_pid = {}, {}
	for _, s in ipairs((summary and summary.list) or {}) do
		if s.session_id then
			by_id[s.session_id] = s
		end
		if s.pid then
			by_pid[s.pid] = s
		end
	end
	local moved = {}
	for key, note in pairs(self.notes) do
		local s = (note.session_id and by_id[note.session_id]) or (note.pid and by_pid[note.pid])
		if not s then
			-- Not in the scan: with a pid it was a listed session that has ended. A note from a hook
			-- for a session the scan never saw stays as it is.
			if note.pid then
				moved[#moved + 1] = key
			end
		elseif s.status == "attention" then
			note.seen = true
		else
			-- Left the attention state, or changed its status after the note went up. A session
			-- that asks for a permission can stay "busy" throughout; that note is kept.
			local updated = s.since and (now - s.since) or nil
			if note.seen or (updated and updated > note.at) then
				moved[#moved + 1] = key
			end
		end
	end
	for _, key in ipairs(moved) do
		self:withdraw(key, true)
	end
end

--- Announce that a session needs the user; repeats within a minute are dropped.
---@param session table|nil { name, pid, session_id }
--- A session keeps one note: a new one replaces it, and it is withdrawn when the session moves on.
---@param now integer
---@param kind string|nil notification type from the hook ("permission_prompt", "idle_prompt", ...)
---@return boolean sent
function Notifier:attention(session, now, kind)
	if not self.opts.notify_attention then
		return false
	end
	-- "Idle prompt" only says the session is done and waiting for the next prompt.
	if kind == "idle_prompt" and not self.opts.notify_idle then
		return false
	end
	local key = session_key(session)
	local last = self.last_attention[key]
	if last and now - last < ATTENTION_WINDOW then
		return false
	end
	-- The user is looking at the session: the prompt is on screen already.
	if not self.opts.notify_focused and self:focused(session) then
		return false
	end
	self.last_attention[key] = now
	self:withdraw(key)
	local name = session and (session.name or (session.pid and ("pid " .. tostring(session.pid)))) or "A session"
	local handle = self:emit({ title = "Claude Code", message = name .. " needs your attention", urgency = "normal" })
	self.notes[key] = {
		handle = handle,
		at = now,
		seen = session ~= nil and session.status == "attention",
		pid = session and session.pid,
		session_id = session and session.session_id,
	}
	return true
end

function Notifier:emit(args)
	if type(self.deps.notify) ~= "function" then
		return
	end
	args.title = args.title or "Claude usage"
	args.timeout = self.opts.notify_timeout
	args.icon = self.opts.notify_icon
	args.app_name = "claude_usage"
	local ok, handle = pcall(self.deps.notify, args)
	if ok then
		return handle
	end
end

--- Queue a usage message; update() sends everything it queued as one notification.
function Notifier:queue(message, urgency)
	local batch = self.batch
	if not batch then
		self:emit({ message = message, urgency = urgency })
		return
	end
	batch[#batch + 1] = message
	if (URGENCY_RANK[urgency] or 0) > (URGENCY_RANK[batch.urgency] or 0) then
		batch.urgency = urgency
	end
end

function Notifier:flush()
	local batch = self.batch
	self.batch = nil
	if batch and #batch > 0 then
		self:emit({ message = table.concat(batch, "\n"), urgency = batch.urgency })
	end
end

function Notifier:check_window(key, label, w, now)
	local rank = format.LEVEL_RANK
	local level = format.level_for(w.percent, self.opts.thresholds)
	local stored = self.windows[key]

	if stored then
		-- A new cycle shows up as a later resets_at (or a big drop); the clock alone is not a reset,
		-- otherwise a stale past resets_at would re-trigger the notification on every redraw.
		-- resets_at wobbles by a second between answers, so "later" needs a real distance.
		local reset = (
			w.resets_at ~= nil
			and stored.resets_at ~= nil
			and w.resets_at - stored.resets_at > RESET_SLACK
		)
			or (stored.percent - w.percent > 20)
		if reset then
			if self.opts.notify_reset and stored.level ~= "normal" and level == "normal" then
				self:queue(label .. " window reset, now at " .. format.percent(w.percent) .. "%")
			end
			stored = nil
		end
	end
	stored = stored or { level = "normal", percent = w.percent, resets_at = w.resets_at }

	-- A window whose resets_at already passed is stale data: record it, but stay quiet.
	local expired = w.resets_at ~= nil and w.resets_at <= now
	if rank[level] > rank[stored.level] and self.opts.notify_threshold and not expired then
		local msg = string.format("%s at %d%%", label, format.percent(w.percent))
		local rel = w.resets_at and format.relative(w.resets_at, now)
		if rel and rel ~= "expired" then
			msg = msg .. " (resets in " .. rel .. ")"
		end
		self:queue(msg, level == "crit" and "critical" or "normal")
	end

	stored.level = level
	stored.percent = w.percent
	stored.resets_at = w.resets_at or stored.resets_at
	self.windows[key] = stored
end

--- Announce session transitions (see sessions.diff).
---@param events table
function Notifier:sessions(events, now)
	now = now or os.time()
	for _, ev in ipairs(events or {}) do
		local name = ev.session and (ev.session.name or ("pid " .. tostring(ev.session.pid))) or "a session"
		if ev.kind == "attention" then
			self:attention(ev.session, now)
		elseif ev.kind == "finished" and self.opts.notify_finished then
			self:emit({ title = "Claude Code", message = name .. " finished", urgency = "low" })
		end
	end
end

--- Feed a new state. Safe to call repeatedly with the same data.
---@param st table|nil
---@param now integer
function Notifier:update(st, now)
	if type(st) ~= "table" then
		return
	end
	local has = normalize.has_data(st)
	if has then
		self.fail_count = 0
		self.error_notified = false
		self.last_error = nil
		self.last_error_at = nil
	elseif st.error and not st.api_key_mode then -- an API key has no subscription login to fail
		-- redraw/poll_sessions re-emit the same state (same error table) every minute; count each
		-- failed check once.
		local at = type(st.error) == "table" and st.error.at or nil
		if st.error ~= self.last_error or at ~= self.last_error_at then
			self.fail_count = self.fail_count + 1
		end
		self.last_error = st.error
		self.last_error_at = at
		if self.opts.notify_error and self.fail_count >= 3 and not self.error_notified then
			self:emit({ message = format.error_text(st.error, now) or "usage fetch failed", urgency = "normal" })
			self.error_notified = true
		end
		return
	else
		return
	end

	-- Several windows crossing a threshold in the same answer make one notification, not one each.
	self.batch = {}
	if st.five_hour then
		self:check_window("five_hour", "Session (5h)", st.five_hour, now)
	elseif st.no_session_limit then
		-- The plan has no 5h limit: nothing to announce, and a provisional window that shows up
		-- again later starts fresh instead of reading as a reset of the old one.
		self.windows.five_hour = nil
	end
	if st.seven_day then
		self:check_window("seven_day", "Weekly (7d)", st.seven_day, now)
	end
	for _, s in ipairs(st.scoped or {}) do
		local name = s.name or "model"
		self:check_window("scoped:" .. name, "Weekly (" .. name .. ")", s, now)
	end
	if st.spend and st.spend.enabled and self.opts.thresholds.spend then
		local pseudo = { percent = st.spend.percent or 0 }
		local saved = self.opts.thresholds
		self.opts.thresholds = { warn = saved.spend, crit = math.huge }
		self:check_window("spend", "Extra usage", pseudo, now)
		self.opts.thresholds = saved
	end
	self:flush()
end

return M
