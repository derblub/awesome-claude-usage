# Security

## What this widget touches

- **Reads** `~/.claude/.credentials.json` to obtain the OAuth access token that
  Claude Code stores there. The file is expected to be mode 600.
- **Sends** that token as a `Bearer` header to `https://api.anthropic.com/api/oauth/usage`
  through a local `curl` process. The token is not put on curl's command line (which
  any local user can read through `/proc/<pid>/cmdline`): it is written to a mode 600
  header file in a mode 700 directory (`$XDG_RUNTIME_DIR/claude-usage/`, or `auth/`
  inside the cache directory when that is unavailable), passed as `curl -H @file`, and
  removed after each request; files left behind by an interrupted request are deleted
  after ten minutes. Only if no such file can be written does the widget fall back to
  passing the header as an argument; the CLI then reports an error instead.
- **Reads** `~/.claude.json` (only the `cachedUsageUtilization` key), the cache
  file written by `contrib/statusline-cache.sh`, and `~/.claude/sessions/*.json`
  (session name, state, working directory, process id) to show running sessions.
- **Receives** from the optional Claude Code hook only the event name, the notification
  type and the session id, over `awesome-client`.
- **Writes** only under `~/.cache/claude-usage/` (created mode 700) and the short-lived
  header file above: `rate_limits.json` (statusLine helper, mode 600), `history.csv`
  (timestamps and percentages, nothing else) and `last.json` (the CLI's cached state,
  which contains the same numbers plus the plan name and, with sessions enabled, the
  names and working directories of running Claude Code sessions).

It never refreshes, rotates or stores the token, never logs it, and talks to no
service other than Anthropic's.

## Reporting a vulnerability

Please open a [private security advisory](https://github.com/derblub/awesome-claude-usage/security/advisories/new)
rather than a public issue. You can expect a response within a week.
