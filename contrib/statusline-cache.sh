#!/bin/sh
# statusline-cache.sh - Claude Code statusLine helper for awesome-claude-usage.
#
# Claude Code pipes a JSON document to the statusLine command on every turn.
# For Pro/Max subscribers it contains a "rate_limits" object. This script
# stores that object (plus a timestamp) in
#   $XDG_CACHE_HOME/claude-usage/rate_limits.json   (default ~/.cache/...)
# so the widget can read fresh data without touching the network, then hands
# the unchanged JSON to an optional downstream statusLine command.
#
# settings.json example (no existing statusline):
#   "statusLine": { "type": "command",
#                   "command": "~/.config/awesome/claude_usage/contrib/statusline-cache.sh" }
# With an existing statusline script:
#   "command": "~/.config/awesome/claude_usage/contrib/statusline-cache.sh ~/.claude/statusline.sh"
#
# Requires jq. Never fails the statusline: every error is swallowed.

input=$(cat)
cache_dir="${CLAUDE_USAGE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-usage}"

if command -v jq >/dev/null 2>&1; then
	(
		umask 077
		mkdir -p "$cache_dir" 2>/dev/null || exit 0
		out=$(printf '%s' "$input" \
			| jq -c '{ts: (now | floor), rate_limits: .rate_limits} | select(.rate_limits != null)' 2>/dev/null) \
			|| exit 0
		[ -n "$out" ] || exit 0
		tmp=$(mktemp "$cache_dir/.rate_limits.XXXXXX" 2>/dev/null) || exit 0
		if printf '%s\n' "$out" >"$tmp" 2>/dev/null; then
			mv -f "$tmp" "$cache_dir/rate_limits.json" 2>/dev/null || rm -f "$tmp"
		else
			rm -f "$tmp"
		fi
	) || true
fi

if [ "$#" -gt 0 ]; then
	printf '%s' "$input" | "$@"
else
	# Minimal standalone statusline: model name only.
	printf '%s' "$input" | jq -r '.model.display_name // "Claude"' 2>/dev/null || printf 'Claude\n'
fi
