# Usage Meter

<img src="docs/panel.png" width="320" align="right" alt="Usage Meter panel: plan limits and Claude Code token history">

**macOS only** (12 Monterey or later, Apple silicon and Intel). A menu-bar gauge for your Claude plan limits and your Claude Code token use.

It uses only what Claude Code itself provides on your Mac: no claude.ai cookies, no private web endpoints, no API calls of its own.

## What it shows

| Section | Source | Notes |
|---|---|---|
| **Plan limits**: 5-hour and weekly % used, reset times | 1. **Refresh** and the automatic checks: Claude Code's own `/usage` command, run headless (`claude -p "/usage" --output-format json`). It is a local command: no message to a model, 0 tokens. 2. Claude Code's documented status line field `rate_limits` ([docs](https://code.claude.com/docs/en/statusline)) after each reply in a terminal session, so the numbers also move while you work | Pro, Max and Ultra plans. Numbers are dated by when they were reported and greyed out after 20 minutes. |
| **Weekly, Fable only** (or another model the plan limits separately): % used, reset time | The same `/usage` report | The row is hidden on plans without a model-specific limit. The status line does not carry this figure, so it only changes at a check. |
| **Weekly limit used per day** (7-day chart, whole account) | Each limit reading is saved to `~/Library/Application Support/Usage Meter/history.json`; a day's bar is how much the weekly % rose that day | 1% steps. Days of the current week before the first reading are estimated (≈): the week's % at that point, split by Claude Code activity on this Mac (API price ratios). Earlier weeks show –. Use while the Mac is off lands on the next day it checks. |
| **Pace** (under each limit, and in History) | The window's average rate so far, carried to the reset: "on pace for 55%" or "full by Sat 14:20 at this pace" | No figure in the first tenth of a window or when the numbers are out of date. |
| **History…** window: the limits over time (24 hours / 7 days / 30 days), an hour-of-day grid for the last 14 days with a few plain facts, Claude Code use per project folder, and the "What's contributing" part of Claude Code's `/usage` report | The saved readings (`history.json`, 60 days; 5-hour and model figures since 0.9.0), the session logs, and `contributing.txt` saved at each check | Everything stays on this Mac. Project shares are a rough cost weight from the logs, not the plan %. |
| **Claude Code tokens**: last 5 h, today, 7 days, per model | Claude Code's session logs in `~/.claude/projects` | Includes cached input, so totals are large. Anthropic calls the log format internal, so this part can break after a Claude Code update. |

The gauge needle in the menu bar follows the 5-hour figure, with the % beside it while it is fresh.

## Install

Needs Xcode or the Command Line Tools (`xcode-select --install`). No other dependencies. `zsh build.sh test` runs the tests.

```bash
zsh build.sh install
```

This builds a universal app, copies it to `/Applications` and opens it. Then, in the panel, click **Connect to Claude Code**: it adds a `statusLine` entry to `~/.claude/settings.json` (a backup is kept as `settings.json.bak-usage-meter`). It will not replace a status line you already have.

## Open

- Click the gauge in the menu bar, or
- open **Usage Meter** from Spotlight (⌘ Space), Finder or Launchpad: the panel opens even if the app is already running.
- **Open at login** starts it quietly in the menu bar (macOS 13+).

## How it works

- **Refresh** and each automatic check run `claude -p "/usage" --output-format json --strict-mcp-config --setting-sources "" --no-session-persistence` (no MCP servers, no settings, nothing saved; about 1.5 s) and read these lines from its `result` text: `Current session: 11% used · resets Nov 20 at 10:49am (Europe/Rome)`, `Current week (all models): 31% used · …`, `Current week (Fable): 29% used · …`. The text is not a documented format, so it may change. `/usage` prints resets to the minute and sometimes a minute early (6:59am one time, 7am the next), so when an exact reset time is already known (from the status line) and is within two minutes, that one is kept.

- `UsageMeter --statusline` is the status line command Claude Code runs. It reads Claude Code's JSON from stdin, saves the limits to `~/Library/Application Support/Usage Meter/limits.json` and prints a short line (`Opus · 5h 42% · 7d 71%`). The time of the session's last reply, from its transcript, dates the numbers, so an idle session cannot overwrite fresher ones.
- The app reads that file and the session logs every 30 seconds (only changed log files are re-read).

Other options: `--fetch-limits` (the Refresh check from Terminal), `--background` (start without opening the panel), `--screenshot out.png [dark]`, `--screenshot-history out.png [dark]`, `--set-hook on|off`, `--version`; `UM_HOME=<dir>` redirects the settings and snapshot paths for testing.

## Limits of this approach

- Without a Refresh, the plan figures are only as fresh as your last terminal Claude Code reply.
- Checks use no tokens (up to 0.7.0 each one sent a tiny Haiku message, about 1,070 tokens). Automatic checks (Off / 2 / 5 / 15 / 30 min, default 5) pause after 10 minutes without keyboard or mouse use.
- `/usage` reports whole percents as text. If Claude Code changes that text, checks fail with "reported no plan limits" until the parser is updated; the status line path keeps working.
- Needs Claude Code installed and signed in with a Claude plan; with an API key there are no plan limits to show.

## Uninstall

Click **Disconnect** in the panel, quit the app, and delete `/Applications/Usage Meter.app` and `~/Library/Application Support/Usage Meter`.

## Licence

MIT — see [LICENSE](LICENSE).
