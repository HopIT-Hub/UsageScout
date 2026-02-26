<p align="center">
  <img src="assets/header-image.png" alt="UsageScout — Helping you keep an eye on your Claude usage" width="100%">
</p>

> [!WARNING]
> **Compliance Notice (Pre-1.0 release, scoped):**
> Core UsageScout behavior (local/cache mode) does **not** use Anthropic dashboard endpoints.
> Potential terms risk is limited to the optional `Dashboard Auth` mode, which reads `/api/organizations/{orgUuid}/usage` using your authenticated session.
> This risk is most likely relevant to Free/Pro/Max account usage contexts. API-billed org contexts may differ, but written approval for this app workflow is still pending.
> Keep `Dashboard Auth` disabled unless you understand and accept that risk.

<div align="center">

[![Latest Release](https://img.shields.io/github/v/release/HopIT-Hub/UsageScout?style=for-the-badge&color=FF6B2B&label=Latest+Release)](https://github.com/HopIT-Hub/UsageScout/releases/latest)
![macOS](https://img.shields.io/badge/macOS-13%2B-lightgrey?style=for-the-badge&logo=apple)
[![License](https://img.shields.io/badge/License-HopIT%20Noncommercial%20(Capped)-FF6B2B?style=for-the-badge)](LICENSE)
[![Ko-Fi](https://img.shields.io/badge/Ko--Fi-Support_the_Project-FF5E5B?style=for-the-badge&logo=ko-fi&logoColor=white)](https://ko-fi.com/hopit)

</div>

## What It Shows

UsageScout is a lightweight macOS menu bar app that shows:
- current session usage
- next session reset time
- current weekly usage
- next weekly reset time

## Install

1. Download the latest release zip from GitHub Releases.
2. Unzip it.
3. Move `UsageScout.app` to `Applications` (or another trusted folder).
4. Launch `UsageScout.app`.

## Unsigned Install Warning (Temporary)

Current releases are unsigned/unnotarized while Apple Developer enrollment is in progress.

On first launch from a downloaded zip, macOS may block the app. To open:
- right-click `UsageScout.app` and choose `Open`
- click `Open` in the warning dialog
- if needed, go to `System Settings > Privacy & Security` and click `Open Anyway`

Future releases are planned to be signed and notarized.

## First Run

When running, a `UsageScout` item appears in the macOS menu bar.

In the menu:
- use `Refresh Now` for an immediate data refresh
- use `Auto Start at Login` if desired
- use `Check for Updates...` to manually query new releases

## Build From Source

```bash
swift build
swift run
```

Optional packaging command (for local release testing):

```bash
./scripts/build_release_app.sh 0.9.0 1
```

Outputs:
- `dist/UsageScout.app`
- `dist/UsageScout-macOS.zip`

## Operational Notes

### Auto Start at Login

Toggle `Auto Start at Login` in the menu.

If macOS requires approval, enable it in:
`System Settings > General > Login Items`

### Automatic Update Checks

The app checks GitHub Releases at launch and every 6 hours.

Menu behavior:
- `Check for Updates...` checks immediately
- if a newer release exists, it changes to `Update Available: vX.Y.Z...`
- selecting it opens the release page

### Reset Assumptions

Defaults are in `Sources/main.swift` (`MonitorConfig`):
- `sessionWindowHours = 5`
- weekly reset = Friday at `20:00` local time
- `sessionBillableTokenLimit = 200000`
- `weeklyAllBillableTokenLimit = 2000000`
- `weeklySonnetBillableTokenLimit = 1500000`

These assumptions apply to local-log mode only.

## Optional Dashboard Auth (Use At Your Own Risk)

Dashboard mode may violate Anthropic terms depending on account context and policy enforcement.
Do not enable this mode unless you understand and accept that risk.

Enable flow:
1. Open the menu bar app.
2. Open `Dashboard Auth`.
3. Enable `Use Dashboard Auth Mode`.
4. Choose `Auto Extract from Claude Desktop` (or manually enter values).
5. Hit `Refresh Now`.

Manual auth options:
- `Enter Session Key...` (cookie value only)
- `Enter Cookie Header...` (for example `sessionKey=...; lastActiveOrg=...`)
- `Set Org UUID (Optional)...` if org discovery is wrong

Automatic refresh behavior:
- if dashboard auth fails (missing/expired key, 401/403/404, org mismatch), UsageScout attempts one auto re-extract from Claude Desktop
- auto re-extract is rate-limited (default every 15 minutes)

Environment overrides (take precedence over saved settings):

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

## Data Sources

UsageScout supports two modes:

1. Local JSONL mode (default, approximate):

`~/.claude/projects/**/*.jsonl`

2. Optional Dashboard mode (exact values):
- endpoint: `/api/organizations/{orgUuid}/usage`
- auth from env vars or saved app settings
- requires explicitly enabling `Dashboard Auth` mode

If dashboard mode is off, UsageScout stays in local/cache mode.

## Accuracy Notes

If dashboard auth is not configured or fails, UsageScout falls back to local CLI logs.
In that mode, values can differ from Claude dashboard values because dashboard values include:
- usage from other clients/devices
- server-side accounting not exposed in local files

When source shows `Dashboard API (/usage)`, values should match dashboard values more closely.

## Support the Project

If UsageScout is useful to you, support is appreciated:

<a href="https://ko-fi.com/hopit">
  <img src="https://img.shields.io/badge/Support_on_Ko--Fi-000000?style=for-the-badge&logo=ko-fi&logoColor=FF5E5B" alt="Support on Ko-Fi">
</a>

## License

This project is licensed under:
- `LICENSE` (`HopIT Noncommercial License v1.0 (Qualified Organization Cap)`)

Quick summary:
- **Free** for personal/noncommercial use
- **Free** for internal company use only when both are true:
  fewer than 150 workers and less than USD 100,000,000 annual gross revenue
- **Commercial license required** for above-threshold internal use
- **Commercial license required** for commercial distribution or closed-source distribution

Commercial licensing: `licensing@hopit.co`

UsageScout is an independent project and is not affiliated with or endorsed by Anthropic.
