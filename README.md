<p align="center">
  <img src="assets/header-image.png" alt="UsageScout — Helping you keep an eye on your Claude usage" width="100%">
</p>

> <sub>**Compliance Note (Dashboard Auth Only):**</sub>
> <sub>`Dashboard Auth` mode, which reads `/api/organizations/{orgUuid}/usage` using your authenticated session, is a potential terms violation risk. We still have not received a written response from Anthropic, but other more visible tools appear to use the same mechanism. Our current assumption is Anthropic likely does not object to this approach. You should still treat `Dashboard Auth` as use at your own risk and a potential violation of Anthropic's Terms of Service. The default Claude Desktop plan-history source does **not** use Anthropic dashboard endpoints or require cookies.</sub>

<div align="center">

[![Latest Release](https://img.shields.io/github/v/release/HopIT-Hub/UsageScout?style=for-the-badge&color=FF6B2B&label=Latest+Release)](https://github.com/HopIT-Hub/UsageScout/releases/latest)
![macOS](https://img.shields.io/badge/macOS-13%2B%20(Apple%20Silicon)-lightgrey?style=for-the-badge&logo=apple)
[![License](https://img.shields.io/badge/License-HopIT%20Noncommercial%20(Capped)-FF6B2B?style=for-the-badge)](LICENSE)
[![Ko-Fi](https://img.shields.io/badge/Ko--Fi-Support_the_Project-FF5E5B?style=for-the-badge&logo=ko-fi&logoColor=white)](https://ko-fi.com/hopit)

</div>

## What It Shows

UsageScout is a lightweight macOS menu bar app that shows:
- current session usage
- next session reset time
- current weekly usage
- next weekly reset time
- temporary model-specific weekly limits (for example Fable) when Dashboard Auth is enabled

## Install

1. Download the latest release zip from GitHub Releases.
2. Unzip it.
3. Move `UsageScout.app` to `Applications` (or another trusted folder).
4. Launch `UsageScout.app`.

Current release binaries are built for Apple Silicon (`arm64`).

## Signed Release Notes

Current release builds are signed and notarized.

If macOS still warns on first launch, verify:
- app was downloaded from official GitHub release assets
- you are running the latest release build
- the downloaded zip was not modified after release

## First Run

When running, a `UsageScout` item appears in the macOS menu bar.

Setup flow (`Usage Source & Auth > Setup Wizard...`):
1. Choose usage type:
- `API (Pay As You Go)`, or
- `Plan (Free/Pro/Max)`
2. API path:
- open Claude usage settings (`Open Claude Usage Page`)
- copy org UUID from request URL (`/organizations/{orgUuid}/usage`)
- optionally auto-extract desktop cookies for dashboard mode
3. Plan path:
- use Claude Desktop's local plan history by default (about five-minute updates), or
- optionally enable Dashboard Auth as an advanced fallback

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
./scripts/build_release_app.sh
```

Without arguments, local packages use the latest Git tag as their version. Pass an explicit version and build number when needed.

Outputs:
- `../non-GitHub/dist/UsageScout.app` (local builds)
- `../non-GitHub/dist/UsageScout-macOS.zip` (local builds)

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
2. Open `Usage Source & Auth`.
3. Run `Setup Wizard...` (recommended), or enable dashboard mode directly.
4. For desktop-based auth, use `Re-auth from Claude Desktop`.
5. Use `Refresh Now`.

Manual auth options:
- `Enter Session Key...` (cookie value only)
- `Enter Cookie Header...` (for example `sessionKey=...; lastActiveOrg=...`)
- `Set Org UUID (Optional)...` if org discovery is wrong

Automatic refresh behavior:
- if dashboard auth fails (missing/expired key, 401/403/404, org mismatch), UsageScout attempts one auto re-extract from Claude Desktop
- auto re-extract is rate-limited (default every 15 minutes)
- the last valid dashboard result is retained for up to 15 minutes during transient failures

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

UsageScout uses three sources in priority order for Plan accounts:

1. Claude Desktop plan history (default):

- `~/Library/Application Support/Claude/plan-usage-history.json`
- utilization values recorded by Claude Desktop about every five minutes
- no cookies, Keychain access, or dashboard endpoint calls required

2. Optional Dashboard mode:

- endpoint: `/api/organizations/{orgUuid}/usage`
- auth from environment variables or saved app settings
- when plan history is current, supplies reset times and model-specific limits without replacing the stable five-hour or seven-day percentages
- when plan history is unavailable or stale, supplies the full live utilization response
- model-specific limits are discovered dynamically from `limits[]`, with legacy Sonnet/Opus/Cowork fields retained as a compatibility fallback

3. Local JSONL mode (final fallback, approximate):

- `~/.claude/projects/**/*.jsonl`
- `~/Library/Application Support/Claude/local-agent-mode-sessions/**/.claude/projects/**/*.jsonl`
- `~/Library/Application Support/Claude/local-agent-mode-sessions/**/audit.jsonl`

## Accuracy Notes

Claude Desktop plan history is authoritative plan utilization, but it can lag the live dashboard by about five minutes and stops refreshing when Claude Desktop is not running.

If neither current plan history nor a recent dashboard value is available, UsageScout falls back to local JSONL logs. Those approximate values can differ from Claude dashboard values because dashboard values include:
- usage from other clients/devices
- server-side accounting not exposed in local files

The menu always shows the active source and its update timestamp. A stale plan-history or last-known-good dashboard label means UsageScout is deliberately holding the last reliable value instead of jumping to an unrelated estimate.

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
