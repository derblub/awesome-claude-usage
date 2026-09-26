#!/bin/sh
# claude-usage-hook.sh - Claude Code hook that pokes the AwesomeWM widget immediately.
#
# Register it for the Notification and Stop events (async, so Claude Code never waits):
#   "hooks": {
#     "Notification": [{ "hooks": [{ "type": "command", "async": true, "timeout": 5,
#                        "command": "~/.config/awesome/claude_usage/contrib/claude-usage-hook.sh" }] }],
#     "Stop":         [{ "hooks": [{ "type": "command", "async": true, "timeout": 5,
#                        "command": "~/.config/awesome/claude_usage/contrib/claude-usage-hook.sh" }] }]
#   }
#
# The widget then rescans ~/.claude/sessions right away and, for a Notification that
# needs you (permission prompt, question, idle prompt), shows the desktop notification
# without waiting for the next scan. Only the event name, the notification type and the
# session id are passed on; the message text stays in Claude Code.

command -v awesome-client >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Byte-wise character classes for tr, whatever the user's locale.
LC_ALL=C
export LC_ALL

input=$(cat) || exit 0
field() {
	printf '%s' "$input" | jq -r "$1"' // "" | tostring' 2>/dev/null | head -n 1 | tr -cd "$2"
}
# Only these characters reach the Lua string below, so no quoting can break out of it.
event=$(field '.hook_event_name' 'A-Za-z0-9_')
kind=$(field '.notification_type' 'A-Za-z0-9_')
session=$(field '.session_id' 'A-Za-z0-9_-')

[ -n "$event" ] || exit 0

# Use the already loaded widget (init.lua registers itself as "claude_usage"); fall back to any
# loaded module with a hook() whose name ends in claude_usage. Never load a second copy.
lua="pcall(function()
	local m = package.loaded['claude_usage']
	if type(m) ~= 'table' or type(m.hook) ~= 'function' then
		m = nil
		for name, mod in pairs(package.loaded) do
			if type(name) == 'string' and name:match('claude_usage\$') and type(mod) == 'table'
				and type(mod.hook) == 'function' then
				m = mod
				break
			end
		end
	end
	if m then m.hook('$event', '$kind', '$session') end
end)"

if command -v timeout >/dev/null 2>&1; then
	timeout 5 awesome-client "$lua" >/dev/null 2>&1 || true
else
	awesome-client "$lua" >/dev/null 2>&1 || true
fi
exit 0
