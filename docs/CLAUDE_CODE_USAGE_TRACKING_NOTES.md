# Claude Code Usage Tracking Notes

Date: 2026-02-22

## Purpose

Capture what Claude Code exposes for usage tracking so we can revisit a more compliant/data-stable integration path later.

## What Is Documented (Official)

1. Interactive commands include:
- `/stats` for usage and average context size.
- `/usage` for usage stats and limits.
- `/cost` for token usage/cost and session details.

Source: https://code.claude.com/docs/en/interactive-mode

2. Headless CLI can return structured JSON:
- `claude -p --output-format json`
- Example output includes fields like `session_id`, `duration_ms`, and `total_cost_usd`.

Source: https://code.claude.com/docs/en/cli-reference

3. OpenTelemetry (OTel) for Claude Code is documented:
- Claude Code can export metrics/traces.
- Metrics include `claude_code.token.usage` and `claude_code.cost.usage`.
- Event attributes include fields like `input_tokens`, `output_tokens`, `cache_read_input_tokens`, and `cost_usd`.

Source: https://docs.anthropic.com/en/docs/claude-code/monitoring-usage

4. Hooks include stable session context fields:
- Hook payload examples include `session_id`.
- Hook payload examples include `transcript_path`.

Source: https://docs.anthropic.com/en/docs/claude-code/hooks

## Local Observations

1. On this machine during research, `claude` CLI was not on PATH (`claude not found`), so no live CLI output validation was performed yet.
2. In UsageScout cache-only mode today, local data source is:
- `~/.claude/projects` (JSONL transcripts)

## Implications For UsageScout

1. Claude Code telemetry is a strong option for a future `Claude Code mode` (hooks/OTel/JSON output).
2. It does not automatically solve Claude Desktop web/dashboard reset-time accuracy for non-CLI activity.
3. Best low-risk future experiment:
- Build an optional provider that ingests Claude Code hook payloads (or OTel) and compare accuracy against current local transcript parsing.

## Revisit Checklist

1. Install Claude Code CLI locally and capture real outputs for:
- `/usage`
- `/stats`
- `claude -p --output-format json`

2. Validate behavior specifically for personal Pro/Max usage windows and reset times.
3. Decide whether to implement:
- hooks-first integration (simpler), or
- OTel collector integration (more robust at scale).
