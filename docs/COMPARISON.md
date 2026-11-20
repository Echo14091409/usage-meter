# How Usage Meter compares

Read from each tool's own README, docs or store page on 20 November 2026. These are the makers' claims, not tested behaviour; "n/s" means not stated. Corrections are welcome.

**Where the plan limits come from**

- **cookie**: you sign in to claude.ai inside the tool (or paste a session cookie) and it calls claude.ai's internal web API
- **token**: it reads Claude Code's saved login token and calls an Anthropic usage endpoint itself
- **logs**: only Claude Code's local session logs, so plan % is an estimate
- **status line**: Claude Code's documented `rate_limits` field
- **CLI**: it runs the `claude` command and reads what Claude Code prints

| Tool | Platform | Price / licence | Limits from | Per-model weekly | Several accounts | History | Pace | Alerts | Project stats | Leaves the machine (besides Anthropic) |
|---|---|---|---|---|---|---|---|---|---|---|
| **Usage Meter** (this) | macOS menu bar; Windows tray (experimental) | Free, source available (CC BY-ND 4.0: no modified versions) | CLI (`/usage`, 0 tokens) + status line | Yes | Yes: Add account, own Claude Code login | Chart 24 h / 7 d / 30 d, hour grid, 60 days kept | Yes | Yes: level, 100%, pace, reset | Yes | Nothing |
| [Claude-Usage-Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker) | macOS bar, widgets, status line | Free, MIT | token, cookie | Yes | Yes: profiles | Yes | Yes | Yes | n/s | Daily anonymous ping |
| [ClaudeBar](https://github.com/tddworks/ClaudeBar) | macOS bar, notch, Touch Bar | Free, Apache-2.0 | CLI, token fallback | Yes | Yes: browser or config folder | 30-day cost chart | Yes | Yes, webhooks | Daily cost; project n/s | Opt-in leaderboard, webhooks |
| [CodexBar](https://github.com/steipete/CodexBar) | macOS bar, Linux, CLI | Free, MIT | token, CLI, cookie | Sonnet stated | Yes | Yes | Even-use guide | Session only | Yes | n/s |
| [ccusage](https://github.com/ccusage/ccusage) | Terminal | Free, MIT | logs | No | n/s | Tables | n/s | n/s | Yes | Price list fetch |
| [Claude-Code-Usage-Monitor](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor) | Terminal | Free, MIT | logs; status line; token opt-in | n/s | Several data folders | Opt-in | Yes | Terminal warnings | Yes | n/s |
| [Usage4Claude](https://github.com/f-is-h/Usage4Claude) | macOS bar | Free, MIT | cookie | Yes | Yes: browser login | No | Yes | Yes | No | Update check |
| [claude-usage-widget](https://github.com/SlavomirDurej/claude-usage-widget) | Windows, macOS, Linux widget | Free, MIT | cookie | Yes | Yes: `--profile` | 7-day chart | Credits only | Yes | No | None claimed |
| [ClaudeUsageBar](https://github.com/Artzainnn/ClaudeUsageBar) | macOS bar | Free, MIT | cookie (pasted) | Sonnet | n/s | n/s | n/s | Yes | n/s | None claimed |
| [claude-usage-bar](https://github.com/mnapoli/claude-usage-bar) | macOS, Windows, Linux tray | Free, MIT | cookie (hidden web view) | Sonnet | n/s | n/s | n/s | Yes | n/s | n/s |
| [claude-meter](https://github.com/m13v/claude-meter) | macOS bar, CLI | Free, MIT | token | n/s | n/s | n/s | n/s | n/s | n/s | Crash reports and daily ping by default |
| [clawd-usage-winwidget](https://github.com/Enhed/clawd-usage-winwidget) | Windows widget | Free, MIT | CLI (`/usage`) | Yes | n/s | 7-day chart | n/s | Unclear | Yes | Weather and location lookup |
| [Claude-God](https://github.com/Lcharvol/Claude-God) | macOS bar, widget | Free, MIT | token | Yes | Yes: config-folder picker | 7/14/30 d, heatmap | Yes | Yes | Yes | n/s |
| [Usage for Claude](https://apps.apple.com/us/app/id6755173244?mt=12) | Mac, iPhone, iPad, Watch | Free; Pro for full history, Claude Code stats, several accounts | cookie (in-app sign-in) | Yes | Pro | 90-day dashboard | Alert rule | Yes | By model | iCloud sync, analytics, crash reports |
| [ClaUse Bar](https://apps.apple.com/app/id6759294136) | macOS 14+ | Free, closed | cookie (in-app sign-in) | n/s | Several organizations | n/s | n/s | Yes | n/s | "Data not collected" |
| [TokenWatch](https://apps.apple.com/app/id6760140276) | macOS 14+ | 7-day trial, then $1.99 once | claude.ai account, method n/s | Yes | n/s | 30-day chart, heatmap, CSV | Yes | Yes | By model | "Data not collected" |

## What Usage Meter does differently

- It never holds a login: no claude.ai cookie, no reading of Claude Code's saved token, no web request of its own. It only runs `claude` and reads the answer.
- A check costs no tokens.
- Nothing is sent anywhere: no analytics, no crash reports, no update ping, no sync.
- One small Swift app, built with `swiftc`; no dependencies.

## What it does not have (yet)

- Desktop widgets, iPhone or Watch views
- Extra-usage, credit or API billing figures
- Other providers (ChatGPT / Codex is planned), Windows or Linux
- A way to work without Claude Code installed
