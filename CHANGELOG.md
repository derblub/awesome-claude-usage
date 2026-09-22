# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.4.0] - 2026-09-22

### Added
- Forecast: samples are recorded to `~/.cache/claude-usage/history.csv`; the popup shows the burn rate
  outcome per window ("at this pace ~38% at reset" or "empty in 1h 20m"), a pacing marker on the weekly
  bar and a 24-hour sparkline.
- Running Claude Code sessions from `~/.claude/sessions`: count and states in the popup, a flag in the
  bar when a session waits for you, notifications on "needs attention" (default on) and "finished" (off).
- Adaptive polling: `interval` while a session works, `interval_idle` (15 min) otherwise, plus an early
  refresh when work starts or stops.
- A statusLine cache younger than `fresh_cache_max_age` (2 min) replaces the API call entirely.
- `cli.lua` for waybar, polybar, tmux and shell prompts (`--text`, `--json`, `--waybar`, `--lines`),
  with its own result cache and backoff so it can be called every few seconds.
- "reset due" instead of "resets in expired" for windows whose reset time has passed.

## [0.3.0] - 2026-09-22

### Added
- `claude_usage.debug()` prints versions, effective options and the current state for bug reports (no secrets).
- `example/rc.lua`, CONTRIBUTING.md, SECURITY.md, issue and pull request templates, Dependabot for the CI actions.

### Changed
- README with badges, hero image and a table of contents.

## [0.2.0] - 2026-09-22

### Added
- Claude-styled look: cairo-drawn starburst icon, chip style with terracotta/amber/red background,
  cream text; `style = "bare"` for themed bars plus `format.chip_color()`.
- Graphical popup: logo header with plan and data source, one progress bar per usage window,
  reset times, scoped model limits, extra usage, weekly breakdown and footer.
- New options `style`, `icon`, `icon_size`, `chip`, `popup_width`, `popup_colors`, `popup_radius`;
  `format.popup_rows()` and `format.plan_name()`.

### Changed
- Default warn/crit text colours now use the Claude palette (`#E39B3A`, `#C8442E`).

## [0.1.0] - 2026-09-22

### Added
- Wibar widget showing the 5-hour session and 7-day weekly Claude Code usage windows.
- Data sources: Claude Code OAuth usage endpoint, statusLine cache file, `~/.claude.json` cache.
- Exponential backoff on HTTP 429 and network errors; token is read-only, never refreshed.
- Hover popup with reset times, model-scoped weekly limits, extra usage and data age.
- Desktop notifications when a window crosses the warn/crit thresholds.
- `contrib/statusline-cache.sh` helper for the Claude Code statusLine.

[0.4.0]: https://github.com/derblub/awesome-claude-usage/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/derblub/awesome-claude-usage/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/derblub/awesome-claude-usage/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/derblub/awesome-claude-usage/releases/tag/v0.1.0
