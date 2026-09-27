// Measurement Layer v1 -- task-level resource measurement for the fleet.
//
// Goal: answer "how much of the scarce resource did ONE piece of work cost,
// and did it succeed?" instead of "how many tokens did agent X burn today".
// Design notes (full write-up: docs/measurement-layer-v1.md):
//
//   * The unit of work is the kanban card. Its id is the task_id; a "run" is
//     one in_progress interval of that card, reconstructed from
//     kanban_card_events. No new id system is introduced.
//   * Token numbers come from the existing token_usage table (one row per API
//     call, parsed from Claude Code transcripts). Summing them over a run's
//     time window is DERIVED, not exact: an agent that works on two things in
//     the same window has its calls attributed to both. Every derived field is
//     listed in FIELD_PROVENANCE so a reader never mistakes it for exact.
//   * Quota comes from Claude Code's own statusline input (rate_limits), not
//     from the /api/oauth/usage endpoint: that endpoint answers 403 to the
//     fleet's setup-token (measured 2026-09-27), the statusline does not.
//   * Null over guesses. api_equivalent_cost_usd stays null unless a price
//     file names its source; success stays null until a human or an explicit
//     outcome call sets it. A merge is never a success by itself.
//   * No secret ever enters a record: auth is recorded only as the MODE
//     ('subscription' | 'api'), never as a token or key.

import type Database from 'better-sqlite3'
import { existsSync, readFileSync, statSync } from 'node:fs'

export type FieldProvenance = 'exact' | 'derived' | 'unavailable'

// Which v1 field comes from where. Served by the API next to the data so the
// consumer cannot drop the caveat by accident.
export const FIELD_PROVENANCE: Record<string, FieldProvenance> = {
  task_id: 'exact',              // kanban card id
  run_id: 'exact',               // card id + in_progress start
  parent_run_id: 'unavailable',  // no parent/child signal yet (see docs)
  agent: 'derived',              // card assignee at derivation time
  model: 'derived',              // most frequent model among the window's calls
  provider: 'derived',           // from model prefix
  runtime: 'exact',              // every fleet agent is claude-code today
  auth_mode: 'exact',            // agent-config authMode; fleet default subscription
  started_at: 'exact',
  finished_at: 'exact',
  duration_seconds: 'exact',
  status: 'exact',               // card status that closed the window
  success: 'exact',              // only ever set explicitly; null otherwise
  input_tokens: 'derived',
  output_tokens: 'derived',
  cache_read_tokens: 'derived',
  cache_write_tokens: 'derived',
  api_calls: 'derived',          // assistant messages in the window
  tool_calls: 'derived',         // calls that carried a tool_use block
  turns: 'unavailable',          // a "turn" is not delimited in the transcript we parse
  retries: 'unavailable',        // no reliable detector; no heuristic in v1 by design
  subagent_runs: 'unavailable',
  quota_before: 'derived',       // nearest 7-day sample at/before start
  quota_after: 'derived',        // nearest 7-day sample at/before end
  quota_delta: 'derived',        // shared account: includes every other agent's use
  api_equivalent_cost_usd: 'derived',
  git_repo: 'unavailable',
  git_branch: 'unavailable',
  git_commit_start: 'unavailable',
  git_commit_end: 'unavailable',
  pull_request: 'unavailable',
  tests_passed: 'unavailable',
  ci_status: 'unavailable',
}

export const SUCCESS_VALUES = ['SUCCESS', 'PARTIAL', 'FAILED', 'CANCELLED'] as const
export type SuccessValue = typeof SUCCESS_VALUES[number]

export function ensureMeasurementSchema(db: Database.Database): void {
  db.exec(`
    CREATE TABLE IF NOT EXISTS quota_samples (
      sampled_at INTEGER PRIMARY KEY,       -- epoch seconds
      source TEXT NOT NULL,
      agent TEXT,
      model TEXT,
      five_hour_pct REAL,
      five_hour_resets_at INTEGER,
      seven_day_pct REAL,
      seven_day_resets_at INTEGER
    )
  `)
  db.exec(`
    CREATE TABLE IF NOT EXISTS measurement_runs (
      run_id TEXT PRIMARY KEY,
      task_id TEXT NOT NULL,
      parent_run_id TEXT,
      project TEXT,
      agent TEXT,
      model TEXT,
      provider TEXT,
      runtime TEXT,
      auth_mode TEXT,
      billing_mode TEXT,
      started_at INTEGER NOT NULL,          -- epoch seconds
      finished_at INTEGER,
      duration_seconds INTEGER,
      status TEXT,
      success TEXT CHECK(success IS NULL OR success IN ('SUCCESS','PARTIAL','FAILED','CANCELLED')),
      reviewer TEXT,
      review_note TEXT,
      input_tokens INTEGER,
      output_tokens INTEGER,
      cache_read_tokens INTEGER,
      cache_write_tokens INTEGER,
      api_calls INTEGER,
      tool_calls INTEGER,
      quota_before REAL,
      quota_after REAL,
      quota_delta REAL,
      actual_incremental_cost_usd REAL,
      api_equivalent_cost_usd REAL,
      derived_at INTEGER NOT NULL
    )
  `)
  db.exec('CREATE INDEX IF NOT EXISTS idx_measurement_runs_task ON measurement_runs(task_id)')
  db.exec('CREATE INDEX IF NOT EXISTS idx_measurement_runs_agent ON measurement_runs(agent, started_at)')
}

// ---------- quota samples ----------

export interface QuotaSample {
  sampled_at: number
  source: string
  agent: string | null
  model: string | null
  five_hour_pct: number | null
  five_hour_resets_at: number | null
  seven_day_pct: number | null
  seven_day_resets_at: number | null
}

function num(v: unknown): number | null {
  return typeof v === 'number' && Number.isFinite(v) ? v : null
}

/**
 * Parse one line written by scripts/measure-statusline.sh. Returns null for
 * anything that does not carry at least one quota percentage -- a sample with
 * no numbers is not a sample.
 */
export function parseQuotaSampleLine(line: string): QuotaSample | null {
  let o: Record<string, unknown>
  try { o = JSON.parse(line) } catch { return null }
  if (!o || typeof o !== 'object') return null
  const sampledAt = num(o.sampled_at)
  if (sampledAt === null) return null
  const five = num(o.five_hour_pct)
  const seven = num(o.seven_day_pct)
  if (five === null && seven === null) return null
  return {
    sampled_at: Math.trunc(sampledAt),
    source: typeof o.source === 'string' ? o.source : 'claude-code-statusline',
    agent: typeof o.agent === 'string' ? o.agent : null,
    model: typeof o.model === 'string' ? o.model : null,
    five_hour_pct: five,
    five_hour_resets_at: num(o.five_hour_resets_at),
    seven_day_pct: seven,
    seven_day_resets_at: num(o.seven_day_resets_at),
  }
}

/**
 * Append-safe, idempotent ingest: the JSONL file is the durable log, the table
 * is a rebuildable index of it (primary key = sampled_at, INSERT OR IGNORE).
 * A torn last line (crash mid-write) is skipped and picked up next time.
 */
export function ingestQuotaSamples(db: Database.Database, jsonlPath: string): number {
  ensureMeasurementSchema(db)
  if (!existsSync(jsonlPath)) return 0
  const ins = db.prepare(`INSERT OR IGNORE INTO quota_samples
    (sampled_at, source, agent, model, five_hour_pct, five_hour_resets_at, seven_day_pct, seven_day_resets_at)
    VALUES (@sampled_at, @source, @agent, @model, @five_hour_pct, @five_hour_resets_at, @seven_day_pct, @seven_day_resets_at)`)
  let inserted = 0
  const tx = db.transaction((lines: string[]) => {
    for (const line of lines) {
      const s = parseQuotaSampleLine(line)
      if (s) inserted += ins.run(s).changes
    }
  })
  tx(readFileSync(jsonlPath, 'utf-8').split('\n').filter((l) => l.trim()))
  return inserted
}

// ---------- prices (optional, never guessed) ----------

export interface ModelPrice {
  input: number        // USD per 1M tokens
  output: number
  cache_read: number
  cache_write: number
}
export interface PriceFile { source: string; as_of: string; models: Record<string, ModelPrice> }

export function loadPriceFile(path: string): PriceFile | null {
  try {
    if (!existsSync(path) || statSync(path).size === 0) return null
    const p = JSON.parse(readFileSync(path, 'utf-8')) as PriceFile
    if (!p || typeof p.source !== 'string' || !p.models) return null
    return p
  } catch { return null }
}

export function apiEquivalentCost(
  price: ModelPrice | undefined,
  t: { input: number; output: number; cacheRead: number; cacheWrite: number },
): number | null {
  if (!price) return null
  const usd = (t.input * price.input + t.output * price.output
    + t.cacheRead * price.cache_read + t.cacheWrite * price.cache_write) / 1_000_000
  return Math.round(usd * 10000) / 10000
}

// ---------- runs, derived from kanban events ----------

export function providerOf(model: string | null): string | null {
  if (!model) return null
  if (model.startsWith('claude-')) return 'anthropic'
  if (/^(gpt-|o\d|codex)/.test(model)) return 'openai'
  return null
}

export interface DeriveOptions {
  prices?: PriceFile | null
  /** agent -> authMode from agent-config.json; missing means the fleet default. */
  authModes?: Record<string, string | undefined>
  now?: number   // epoch seconds, for tests
}

interface CardEvent { card_id: string; from_status: string | null; to_status: string; created_at: number }

/**
 * Rebuild measurement_runs from kanban_card_events + token_usage + quota_samples.
 * Idempotent: a run keeps its id (card + start), numeric fields are
 * recomputed, the human-set fields (success, reviewer, review_note) are kept.
 * An open run (still in_progress) gets finished_at null and tokens up to now.
 */
export function deriveRuns(db: Database.Database, opts: DeriveOptions = {}): number {
  ensureMeasurementSchema(db)
  const now = opts.now ?? Math.floor(Date.now() / 1000)
  const events = db.prepare(
    'SELECT card_id, from_status, to_status, created_at FROM kanban_card_events ORDER BY card_id, created_at, id',
  ).all() as CardEvent[]
  const cardInfo = db.prepare('SELECT assignee, project FROM kanban_cards WHERE id = ?')
  // token_usage.timestamp is epoch SECONDS (measured on the live DB 2026-09-27:
  // 1790517404). A first draft assumed ms and matched nothing on real data
  // while its own unit test, written with the same assumption, stayed green.
  const tokenAgg = db.prepare(`
    SELECT COALESCE(SUM(input_tokens),0) AS input, COALESCE(SUM(output_tokens),0) AS output,
           COALESCE(SUM(cache_read_tokens),0) AS cacheRead, COALESCE(SUM(cache_creation_tokens),0) AS cacheWrite,
           COUNT(*) AS calls, SUM(CASE WHEN tool_name IS NOT NULL AND tool_name != '' THEN 1 ELSE 0 END) AS tools
    FROM token_usage WHERE agent = ? AND timestamp >= ? AND timestamp < ?`)
  const topModel = db.prepare(`
    SELECT model FROM token_usage WHERE agent = ? AND timestamp >= ? AND timestamp < ?
      AND model IS NOT NULL AND model != '' AND model != '<synthetic>'
    GROUP BY model ORDER BY COUNT(*) DESC LIMIT 1`)
  const quotaAt = db.prepare(
    'SELECT seven_day_pct FROM quota_samples WHERE sampled_at <= ? AND seven_day_pct IS NOT NULL ORDER BY sampled_at DESC LIMIT 1')
  const upsert = db.prepare(`
    INSERT INTO measurement_runs (run_id, task_id, parent_run_id, project, agent, model, provider, runtime,
      auth_mode, billing_mode, started_at, finished_at, duration_seconds, status,
      input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, api_calls, tool_calls,
      quota_before, quota_after, quota_delta, actual_incremental_cost_usd, api_equivalent_cost_usd, derived_at)
    VALUES (@run_id, @task_id, NULL, @project, @agent, @model, @provider, @runtime,
      @auth_mode, @billing_mode, @started_at, @finished_at, @duration_seconds, @status,
      @input_tokens, @output_tokens, @cache_read_tokens, @cache_write_tokens, @api_calls, @tool_calls,
      @quota_before, @quota_after, @quota_delta, @actual_incremental_cost_usd, @api_equivalent_cost_usd, @derived_at)
    ON CONFLICT(run_id) DO UPDATE SET
      project=excluded.project, agent=excluded.agent, model=excluded.model, provider=excluded.provider,
      runtime=excluded.runtime, auth_mode=excluded.auth_mode, billing_mode=excluded.billing_mode,
      finished_at=excluded.finished_at, duration_seconds=excluded.duration_seconds, status=excluded.status,
      input_tokens=excluded.input_tokens, output_tokens=excluded.output_tokens,
      cache_read_tokens=excluded.cache_read_tokens, cache_write_tokens=excluded.cache_write_tokens,
      api_calls=excluded.api_calls, tool_calls=excluded.tool_calls,
      quota_before=excluded.quota_before, quota_after=excluded.quota_after, quota_delta=excluded.quota_delta,
      actual_incremental_cost_usd=excluded.actual_incremental_cost_usd,
      api_equivalent_cost_usd=excluded.api_equivalent_cost_usd, derived_at=excluded.derived_at`)

  // Collect in_progress windows per card.
  const windows: Array<{ card: string; start: number; end: number | null; closedBy: string | null }> = []
  let open: { card: string; start: number } | null = null
  let lastCard = ''
  for (const ev of events) {
    if (ev.card_id !== lastCard) {
      if (open) windows.push({ card: open.card, start: open.start, end: null, closedBy: null })
      open = null
      lastCard = ev.card_id
    }
    if (ev.to_status === 'in_progress') {
      if (!open) open = { card: ev.card_id, start: ev.created_at }
    } else if (open) {
      windows.push({ card: open.card, start: open.start, end: ev.created_at, closedBy: ev.to_status })
      open = null
    }
  }
  if (open) windows.push({ card: open.card, start: open.start, end: null, closedBy: null })

  let written = 0
  const tx = db.transaction(() => {
    for (const w of windows) {
      const info = cardInfo.get(w.card) as { assignee: string | null; project: string | null } | undefined
      const agent = info?.assignee ?? null
      const endS = w.end ?? now
      let t = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, calls: 0, tools: 0 }
      let model: string | null = null
      if (agent) {
        t = tokenAgg.get(agent, w.start, endS) as typeof t
        model = (topModel.get(agent, w.start, endS) as { model: string } | undefined)?.model ?? null
      }
      const hasCalls = t.calls > 0
      const qb = (quotaAt.get(w.start) as { seven_day_pct: number } | undefined)?.seven_day_pct ?? null
      const qa = w.end === null ? null
        : (quotaAt.get(w.end) as { seven_day_pct: number } | undefined)?.seven_day_pct ?? null
      const authMode = agent ? (opts.authModes?.[agent] === 'api' ? 'api' : 'subscription') : null
      upsert.run({
        run_id: `${w.card}:${w.start}`,
        task_id: w.card,
        project: info?.project ?? null,
        agent,
        model,
        provider: providerOf(model),
        runtime: 'claude-code',
        auth_mode: authMode,
        billing_mode: authMode,
        started_at: w.start,
        finished_at: w.end,
        duration_seconds: w.end === null ? null : w.end - w.start,
        status: w.closedBy ?? 'in_progress',
        // Zero calls in a window is "we saw nothing", not "it cost nothing":
        // the agent may be one the collector cannot read. Store null then.
        input_tokens: hasCalls ? t.input : null,
        output_tokens: hasCalls ? t.output : null,
        cache_read_tokens: hasCalls ? t.cacheRead : null,
        cache_write_tokens: hasCalls ? t.cacheWrite : null,
        api_calls: hasCalls ? t.calls : null,
        tool_calls: hasCalls ? t.tools : null,
        quota_before: qb,
        quota_after: qa,
        // A reset between the samples makes the difference meaningless.
        quota_delta: qb !== null && qa !== null && qa >= qb ? Math.round((qa - qb) * 100) / 100 : null,
        actual_incremental_cost_usd: authMode === 'subscription' ? 0 : null,
        api_equivalent_cost_usd: hasCalls ? apiEquivalentCost(model ? opts.prices?.models[model] : undefined, t) : null,
        derived_at: now,
      })
      written++
    }
  })
  tx()
  return written
}

/** Set the human outcome of a run. The only write path for `success`. */
export function setRunOutcome(
  db: Database.Database, runId: string, success: SuccessValue, reviewer: string, note: string | null,
): boolean {
  ensureMeasurementSchema(db)
  if (!SUCCESS_VALUES.includes(success)) return false
  const r = db.prepare('UPDATE measurement_runs SET success = ?, reviewer = ?, review_note = ? WHERE run_id = ?')
    .run(success, reviewer, note, runId)
  return r.changes > 0
}

// ---------- read side ----------

export function listRuns(db: Database.Database, f: { agent?: string; task?: string; limit?: number } = {}) {
  ensureMeasurementSchema(db)
  const where: string[] = []
  const args: unknown[] = []
  if (f.agent) { where.push('agent = ?'); args.push(f.agent) }
  if (f.task) { where.push('task_id = ?'); args.push(f.task) }
  const sql = `SELECT * FROM measurement_runs ${where.length ? 'WHERE ' + where.join(' AND ') : ''}
    ORDER BY started_at DESC LIMIT ?`
  args.push(Math.min(Math.max(f.limit ?? 200, 1), 2000))
  return db.prepare(sql).all(...args)
}

export function listTasks(db: Database.Database, f: { agent?: string; limit?: number } = {}) {
  ensureMeasurementSchema(db)
  const args: unknown[] = []
  let where = ''
  if (f.agent) { where = 'WHERE r.agent = ?'; args.push(f.agent) }
  args.push(Math.min(Math.max(f.limit ?? 200, 1), 2000))
  return db.prepare(`
    SELECT r.task_id AS task_id, c.title AS title, c.status AS card_status, r.agent AS agent,
      COUNT(*) AS runs, MIN(r.started_at) AS first_started_at, MAX(r.finished_at) AS last_finished_at,
      SUM(r.duration_seconds) AS duration_seconds,
      SUM(r.input_tokens) AS input_tokens, SUM(r.output_tokens) AS output_tokens,
      SUM(r.cache_read_tokens) AS cache_read_tokens, SUM(r.cache_write_tokens) AS cache_write_tokens,
      SUM(r.api_calls) AS api_calls, SUM(r.tool_calls) AS tool_calls,
      SUM(r.quota_delta) AS quota_delta, SUM(r.api_equivalent_cost_usd) AS api_equivalent_cost_usd,
      (SELECT success FROM measurement_runs r2 WHERE r2.task_id = r.task_id AND r2.success IS NOT NULL
        ORDER BY r2.started_at DESC LIMIT 1) AS success
    FROM measurement_runs r LEFT JOIN kanban_cards c ON c.id = r.task_id
    ${where}
    GROUP BY r.task_id ORDER BY first_started_at DESC LIMIT ?`).all(...args)
}

export function listQuotaSamples(db: Database.Database, f: { from?: number; limit?: number } = {}) {
  ensureMeasurementSchema(db)
  return db.prepare(`SELECT * FROM quota_samples WHERE sampled_at >= ? ORDER BY sampled_at DESC LIMIT ?`)
    .all(f.from ?? 0, Math.min(Math.max(f.limit ?? 288, 1), 5000))
}
