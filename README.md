# Claude Usage Bar

A native macOS menu bar widget that shows your [Claude Code](https://claude.com/claude-code) usage: the rolling 5-hour block, the last 7 days, and spend broken down per skill.

Everything is read locally from `~/.claude/projects`. Nothing leaves your machine. Dollar figures are API list-price **equivalents**, not charges.

Swift (AppKit, custom-drawn panel) · Python 3 (stdlib only)

## How it works

- `usage.py` aggregates token usage from the Claude Code transcripts. Parsing is incremental: transcripts are append-only JSONL, so it remembers how many bytes of each file it already folded into time buckets and only reads the tail.
- `menubar.swift` is a menu-bar-only app (no Dock icon). It runs `usage.py`, and draws the popover — dial, meters, per-skill rows — with AppKit.
- `pricing.json` holds per-model prices per million tokens, including cache write/read rates.
- `claude-usage.60s.py` is an alternative front end: the same data as a [SwiftBar](https://github.com/swiftbar/SwiftBar) plugin.

## Build

```bash
./build.sh    # compiles menubar.swift into ClaudeUsageBar.app (ad-hoc signed) and relaunches it
./dist.sh     # packages a universal (arm64 + x86_64) zip with install notes
```

Requires the Xcode Command Line Tools (`swiftc`, `/usr/bin/python3`) and macOS 13+.

## Install a packaged build

1. Move `ClaudeUsageBar.app` to `/Applications`.
2. The app is not notarized, so clear the download quarantine once:
   ```bash
   xattr -dr com.apple.quarantine /Applications/ClaudeUsageBar.app
   ```
3. Open it. To start at login: System Settings → General → Login Items.
