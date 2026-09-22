# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.1.0] - 2026-09-22

### Added
- Wibar widget showing the 5-hour session and 7-day weekly Claude Code usage windows.
- Data sources: Claude Code OAuth usage endpoint, statusLine cache file, `~/.claude.json` cache.
- Exponential backoff on HTTP 429 and network errors; token is read-only, never refreshed.
- Hover popup with reset times, model-scoped weekly limits, extra usage and data age.
- Desktop notifications when a window crosses the warn/crit thresholds.
- `contrib/statusline-cache.sh` helper for the Claude Code statusLine.
