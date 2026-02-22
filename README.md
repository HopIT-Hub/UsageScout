# UsageScout (macOS Menu Bar)

Official product name: `UsageScout`  
Copyright/credit: `HopIT`

`UsageScout` is an independent tool and is not affiliated with or endorsed by Anthropic.

## Licensing

This repository uses:
- `LICENSE` (PolyForm Noncommercial 1.0.0)
- `LICENSE-ADDITIONAL-TERMS.md` (HopIT additional permissions and conditions)

Summary:
- Qualified Organizations can use UsageScout internally without a separate paid license if they are below both:
- fewer than 150 workers
- less than USD 100,000,000 annual gross revenue
- Organizations at or above either threshold must obtain a commercial license from HopIT.
- Commercial licensing can be handled through an approved GitHub Sponsors commercial tier.

Fork/variant requirements include:
- README attribution to HopIT
- user-facing attribution in About/Settings (not required on the main/home UI)
- no use of HopIT/UsageScout trademarks as primary branding without permission

Lightweight macOS menu bar app that shows:
- current session usage
- next session reset time
- current weekly usage
- next weekly reset time

## What It Reads

The app now supports two sources (in priority order):

1. Claude dashboard API (exact values):
- endpoint: `/api/organizations/{orgUuid}/usage`
- auth from env vars or saved app settings

2. Local JSONL fallback (approximate):

`~/.claude/projects/**/*.jsonl`

It auto-discovers your `orgUuid` from Claude local storage when possible.

## Exact Dashboard Mode

Recommended (no CLI):

1. Open the menu bar app.
2. Open `Dashboard Auth`.
3. Choose `Auto Extract from Claude Desktop` (or manually enter values).
4. Hit `Refresh Now`.

Manual options in the app:
- `Enter Session Key...` (just the cookie value)
- `Enter Cookie Header...` (full header, e.g. `sessionKey=...; lastActiveOrg=...`)
- `Set Org UUID (Optional)...` if org discovery is wrong

Automatic refresh:
- if dashboard API auth fails (missing/expired key, auth 401/403/404, org mismatch), the app attempts auto re-extract from Claude Desktop and retries once
- auto re-extract is rate-limited (default every 15 minutes) to avoid constant keychain prompts

CLI env overrides (optional; these take precedence over saved settings):

```bash
export CLAUDE_SESSION_KEY='...'
```

or

```bash
export CLAUDE_COOKIE_HEADER='sessionKey=...; otherCookie=...'
```

Optional override:

```bash
export CLAUDE_ORG_UUID='xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
```

## Reset Assumptions

Defaults are in `Sources/main.swift` (`MonitorConfig`):

- `sessionWindowHours = 5`
- weekly reset = Friday at `20:00` local time
- `sessionBillableTokenLimit = 200000`
- `weeklyAllBillableTokenLimit = 2000000`
- `weeklySonnetBillableTokenLimit = 1500000`

These apply to local-log fallback only.

## Build

```bash
swift build
```

## Run

```bash
swift run
```

When running, a `UsageScout ...` item appears in the macOS menu bar.
The menu bar icon is a fill circle showing current session usage percentage.

## Auto Start at Login

In the menu, toggle `Auto Start at Login`.

Notes:
- this works when running the packaged `UsageScout.app`
- if macOS requires approval, enable it in `System Settings > General > Login Items`

## Menu Details

Dropdown shows:
- session fill bar + % used
- session reset countdown + exact date/time
- weekly fill bars + % used
- weekly reset countdown + exact date/time
- source label (dashboard API vs local fallback)
- `Auto Start at Login` toggle
- refresh button, open data folder, quit

## Release Packaging

Build a distributable app and zip:

```bash
./scripts/build_release_app.sh 1.0.0 1
```

Outputs:
- `dist/UsageScout.app`
- `dist/UsageScout-macOS.zip`

## Why It Can Differ From Claude Dashboard

If dashboard auth is not configured or fails, the app falls back to local CLI logs. In that mode the Claude dashboard can differ because it includes:
- usage from other clients/devices
- server-side usage accounting that is not exposed in local files

When API auth is set and source shows `Dashboard API (/usage)`, values should match the dashboard.
