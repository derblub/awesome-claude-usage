# Security

## What this widget touches

- **Reads** `~/.claude/.credentials.json` to obtain the OAuth access token that
  Claude Code stores there. The file is expected to be mode 600.
- **Sends** that token as a `Bearer` header to `https://api.anthropic.com/api/oauth/usage`
  through a local `curl` process. The token appears in that process's argument list,
  which is visible to your own user only.
- **Reads** `~/.claude.json` (only the `cachedUsageUtilization` key) and the cache
  file written by `contrib/statusline-cache.sh`.
- **Writes** nothing except that cache file (`~/.cache/claude-usage/`, mode 600),
  and only when you enable the statusLine helper.

It never refreshes, rotates or stores the token, never logs it, and talks to no
service other than Anthropic's.

## Reporting a vulnerability

Please open a [private security advisory](https://github.com/derblub/awesome-claude-usage/security/advisories/new)
rather than a public issue. You can expect a response within a week.
