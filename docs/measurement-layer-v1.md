# Measurement Layer v1

Purpose: task-level, objective resource data from our own workload, so model and
runtime choices (Opus 5.5, Sonnet 5, later Codex) rest on measurement instead of
list prices. v1 measures; it does not route, switch models or enable any API.

Status: built on branch `feat/measurement-layer-v1`, not merged, not deployed.

## 1. Audit of what existed (2026-09-27)

| Source | What it measures | Gap |
|---|---|---|
| `token_usage` table (`src/web/token-usage.ts`, hourly) | one row per API call: agent, session, timestamp (epoch **seconds**), input, output, cache read, cache write, thinking, model, tool name | the API only exposes daily/agent aggregates; no task link |
| `/api/token-usage/timeline` | calls, input, output per bucket and agent | no model, no cache split |
| `scripts/usage-collect.py` | quota: tries `api.anthropic.com/api/oauth/usage` | **never scheduled**, so `store/usage-latest.json` never existed; and the endpoint answers **403** to the fleet's setup-token, so it could only have produced an estimate |
| `kanban_card_events` | every card status change with timestamp and actor (1396 rows) | not joined to anything |
| `otel_spans`, `tool_call_log`, `task_runs` | spans, a tool log, scheduled-task runs | not used by v1 |

**Why sub-agents disappeared from the collector after 2026-09-22.** Since the
agents run under their own OS users, Claude Code writes each NEW transcript
as mode `0600` owned by `agent-<name>`. The dashboard runs as `marveen` and
gets `EACCES`; the collector skips unreadable files silently. Older transcripts
stay readable, so the agent looks idle instead of broken. Last rows:
nautilus 09-22 23:11, barracuda 09-22 23:36, murena 09-23 00:27.

**The worker is not collected at all.** `acrobot-worker` runs with
`CLAUDE_CONFIG_DIR=~/.acrobot-worker/.claude-config`, which the collector does
not scan.

**Quota IS available, from Claude Code itself.** Claude Code passes
`rate_limits.five_hour` / `rate_limits.seven_day` (`used_percentage`,
`resets_at`) to the statusLine command once the session has made one API call.
Verified 2026-09-27 with a throwaway session on the fleet's setup-token:
`five_hour 0%, seven_day 88%, resets 2026-09-28 09:00`. The same session's
TUI printed "You've used 88% of your weekly limit".

## 2. Architecture

```
agent session (claude-code)
  ├─ transcript .jsonl ──(hourly)──> token_usage          [exists]
  └─ statusLine stdin ─> scripts/measure-statusline.py
                           └─> store/measurements/quota-samples.jsonl  (append-only log)

dashboard, every 5 min: refreshMeasurements()
  ├─ ingestQuotaSamples: JSONL -> quota_samples            (idempotent, PK sampled_at)
  └─ deriveRuns: kanban_card_events x token_usage x quota_samples -> measurement_runs

GET /api/measurements/{tasks,runs,usage}                  (read-only JSON)
POST /api/measurements/runs/outcome                       (human outcome only)
scripts/api-guard.py                                      (read-only billing guard)
```

## 3. Data model

**Task** = a kanban card. `task_id` is the card id. No new id scheme: every
piece of work is already on a card, and the card carries title, assignee and
project. (A readable alias such as `ACP-2026-000123` can be added later as a
column; it should map to the card id, not replace it.)

**Run** = one `in_progress` interval of a card. `run_id = <card_id>:<start epoch>`,
stable across re-derivation. A card re-opened after `waiting` gets a second run.

`measurement_runs` columns: `run_id, task_id, parent_run_id, project, agent, model,
provider, runtime, auth_mode, billing_mode, started_at, finished_at,
duration_seconds, status, success, reviewer, review_note, input_tokens,
output_tokens, cache_read_tokens, cache_write_tokens, api_calls, tool_calls,
quota_before, quota_after, quota_delta, actual_incremental_cost_usd,
api_equivalent_cost_usd, derived_at`.

`quota_samples`: `sampled_at, source, agent, model, five_hour_pct,
five_hour_resets_at, seven_day_pct, seven_day_resets_at`.

## 4. Exact, derived, unavailable

Served with every read response as `provenance`.

| Field | Kind | Why |
|---|---|---|
| task_id, run_id, started_at, finished_at, duration, status | exact | from card events |
| runtime | exact | every fleet agent is claude-code today |
| auth_mode, billing_mode | exact | agent-config `authMode`; default subscription |
| success, reviewer | exact | only set explicitly via the outcome endpoint |
| agent | derived | card assignee at derivation time |
| model, provider | derived | most frequent model among the window's calls |
| input/output/cache tokens, api_calls, tool_calls | **derived** | sum of the agent's calls inside the window. If the agent worked on two things at once, both runs count the same calls. Acrobot multitasks constantly: treat its runs as an upper bound |
| quota_before/after/delta | derived | nearest 7-day sample; **one shared account**, so the delta includes every other agent's use. Only meaningful when one agent works alone |
| api_equivalent_cost_usd | derived | only if `store/measurements/prices.json` exists with a named source; otherwise null |
| turns, retries, subagent_runs, parent_run_id | unavailable | no reliable signal; no heuristic in v1 by design |
| git_*, pull_request, tests_passed, ci_status | unavailable | not linked in v1 (see 9.) |

Rules: zero calls in a window is stored as **null**, not 0 (the collector may
be blind to that agent). A quota difference across a reset is **null**, not
negative. `done` is not `SUCCESS`, and a merge is not `SUCCESS`.

## 5. Collector behaviour

- `measure-statusline.py`: at most one sample per 300 s (file mtime), one
  `write()` per line with `O_APPEND`, never raises into the statusline.
  Records only numbers, model id and agent name: no session id, no path, no cwd.
- `ingestQuotaSamples`: re-reads the JSONL, `INSERT OR IGNORE` on `sampled_at`;
  a torn last line is skipped and picked up after it is complete. The table is
  a rebuildable index; the JSONL is the durable log.
- Rotation: the JSONL grows ~100 bytes per 5 min (~10 MB/year). Rotate by
  renaming the file; the table keeps the history.
- `deriveRuns`: full recompute of numeric fields (321 runs in ~190 ms on a copy
  of the live DB); human fields are preserved.

## 6. Endpoints

```
GET  /api/measurements/runs?agent=&task=&limit=
GET  /api/measurements/tasks?agent=&limit=
GET  /api/measurements/usage?from=<epoch s>&limit=
POST /api/measurements/refresh
POST /api/measurements/runs/outcome   {"runId","success":"SUCCESS|PARTIAL|FAILED|CANCELLED","reviewer","note"}
```

All behind the existing dashboard Bearer auth.

## 7. API guard

`scripts/api-guard.py` (`--warn-only` for a heartbeat) reports, by NAME only,
`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`,
`CLAUDE_CODE_USE_BEDROCK/VERTEX`, `OPENAI_API_KEY`, `GEMINI_API_KEY`,
`OPENROUTER_API_KEY`, `DEEPSEEK_API_KEY` in readable process environments and
`.env`; `authMode=api` or a non-Claude model in any agent-config; API-key-shaped
vault ids. It never stops anything. Processes of other OS users are unreadable
to it and reported as a count, not as clean.

## 8. Security

No record holds a key, token, setup-token, GitHub token or MCP credential.
Auth is stored only as the mode (`subscription` | `api`). The statusline
sampler writes no path, session id or prompt text.

## 9. Known gaps (v1)

1. **Sub-agent tokens after 09-22** need the transcripts to be readable or
   exported. Proposed: the same statusline command in each agent's profile,
   running as the agent's own user, exporting per-call numbers from its own
   transcript into a fleet-group directory. Profile edits are a locked
   permission category: needs the owner's yes.
2. **Worker**: add `~/.acrobot-worker/.claude-config/projects` as a collector
   source under the name `acrobot-worker`.
3. **Activation**: the statusline must be set in the main agent's settings to
   start sampling; not done on this branch (no deploy).
4. Token attribution is per time window, not per task. Exact per-task numbers
   need the agent to mark task start/end in its own session (a v2 item).
5. Git/PR/CI linkage: parse `#<PR>` and branch names from card comments, then
   read CI from GitHub. v2.
6. Prices: no price file ships; `api_equivalent_cost_usd` stays null until one
   with a named source is added.

## 10. Adding Codex later

A Codex worker writes the same run shape with `provider=openai`,
`runtime=codex-cli`, `auth_mode=subscription|api`. Tokens: Codex CLI writes
`~/.codex/sessions/**/rollout-*.jsonl` with per-turn usage and `rate_limits`
events (the parser in `scripts/usage-collect.py` already reads the latter);
a second source in the collector maps them onto `token_usage` rows with the
Codex model name, and quota samples get `source=codex-rollout`.

## 11. Storage and the Studio path

v1: two tables in the existing SQLite (`store/claudeclaw.db`) plus one JSONL
log. No new service. Studio later: the same tables move to Postgres as
`runs` and `usage_samples`, with `tasks` becoming a first-class table that
the kanban card references; `task_id` values stay valid because they are
the card ids.
