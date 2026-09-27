import { describe, it, expect, beforeEach, afterAll } from 'vitest'
import Database from 'better-sqlite3'
import { mkdirSync, writeFileSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import {
  deriveRuns, ensureMeasurementSchema, ingestQuotaSamples, listRuns, listTasks,
  parseQuotaSampleLine, setRunOutcome, apiEquivalentCost, providerOf, FIELD_PROVENANCE,
} from '../web/measurements.js'

// A real statusline sample line, as scripts/measure-statusline.py wrote it on
// 2026-09-27 from a live Claude Code 2.1.283 session (numbers only).
const REAL_LINE = '{"sampled_at":1790519995,"source":"claude-code-statusline","agent":"acrobot","model":"claude-opus-5-5","five_hour_pct":0,"five_hour_resets_at":1790534400,"seven_day_pct":88,"seven_day_resets_at":1790578800}'

const TMP = join(tmpdir(), `measurements-test-${process.pid}`)

function freshDb(): Database.Database {
  const db = new Database(':memory:')
  db.exec(`
    CREATE TABLE kanban_cards (id TEXT PRIMARY KEY, title TEXT, status TEXT, assignee TEXT, project TEXT);
    CREATE TABLE kanban_card_events (id INTEGER PRIMARY KEY AUTOINCREMENT, card_id TEXT, from_status TEXT, to_status TEXT, actor TEXT, created_at INTEGER);
    CREATE TABLE token_usage (id INTEGER PRIMARY KEY AUTOINCREMENT, agent TEXT, session_id TEXT, timestamp INTEGER,
      input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0, cache_read_tokens INTEGER DEFAULT 0,
      cache_creation_tokens INTEGER DEFAULT 0, thinking_tokens INTEGER DEFAULT 0, model TEXT, tool_name TEXT);
  `)
  ensureMeasurementSchema(db)
  return db
}

// token_usage.timestamp is epoch SECONDS, same unit as kanban_card_events.created_at
// (verified against the live DB, not assumed).
function call(db: Database.Database, agent: string, tsSec: number, o: Partial<Record<string, unknown>> = {}) {
  db.prepare(`INSERT INTO token_usage (agent, session_id, timestamp, input_tokens, output_tokens, cache_read_tokens,
    cache_creation_tokens, model, tool_name) VALUES (?, 's', ?, ?, ?, ?, ?, ?, ?)`).run(
    agent, tsSec, o.input ?? 10, o.output ?? 100, o.cacheRead ?? 1000, o.cacheWrite ?? 50,
    o.model ?? 'claude-opus-5-5', o.tool ?? null)
}

describe('quota sample parsing', () => {
  it('accepts the real statusline line (known good)', () => {
    const s = parseQuotaSampleLine(REAL_LINE)!
    expect(s.seven_day_pct).toBe(88)
    expect(s.five_hour_pct).toBe(0)       // 0 is a value, not a missing one
    expect(s.seven_day_resets_at).toBe(1790578800)
  })
  it('rejects a torn line and a line without percentages', () => {
    expect(parseQuotaSampleLine(REAL_LINE.slice(0, 40))).toBeNull()
    expect(parseQuotaSampleLine('{"sampled_at":1}')).toBeNull()
  })
})

describe('quota ingest is idempotent and crash-tolerant', () => {
  beforeEach(() => mkdirSync(TMP, { recursive: true }))
  afterAll(() => rmSync(TMP, { recursive: true, force: true }))
  it('ingests once, skips a torn trailing line, and picks it up after repair', () => {
    const db = freshDb()
    const p = join(TMP, 'q.jsonl')
    const second = REAL_LINE.replace('1790519995', '1790520300').replace('"seven_day_pct":88', '"seven_day_pct":89')
    writeFileSync(p, REAL_LINE + '\n' + second.slice(0, 30))
    expect(ingestQuotaSamples(db, p)).toBe(1)
    expect(ingestQuotaSamples(db, p)).toBe(0)
    writeFileSync(p, REAL_LINE + '\n' + second + '\n')
    expect(ingestQuotaSamples(db, p)).toBe(1)
    expect(ingestQuotaSamples(db, join(TMP, 'missing.jsonl'))).toBe(0)
  })
})

describe('deriveRuns', () => {
  it('turns one in_progress window into one run with the window\'s calls only', () => {
    const db = freshDb()
    db.prepare("INSERT INTO kanban_cards VALUES ('c1','Fix it','done','nautilus','acropora-os')").run()
    db.prepare("INSERT INTO kanban_card_events (card_id, from_status, to_status, created_at) VALUES ('c1','planned','in_progress',1000),('c1','in_progress','done',4600)").run()
    call(db, 'nautilus', 999)                       // before: excluded
    call(db, 'nautilus', 1000, { tool: 'Bash' })
    call(db, 'nautilus', 2000)
    call(db, 'murena', 2000)                        // other agent: excluded
    call(db, 'nautilus', 4600)                      // at end: excluded (half-open)
    db.prepare("INSERT INTO quota_samples (sampled_at, source, seven_day_pct) VALUES (900,'t',40),(4500,'t',42.5)").run()

    expect(deriveRuns(db, { now: 10_000 })).toBe(1)
    const [r] = listRuns(db) as any[]
    expect(r.run_id).toBe('c1:1000')
    expect(r.task_id).toBe('c1')
    expect(r.agent).toBe('nautilus')
    expect(r.model).toBe('claude-opus-5-5')
    expect(r.provider).toBe('anthropic')
    expect(r.runtime).toBe('claude-code')
    expect(r.auth_mode).toBe('subscription')
    expect(r.actual_incremental_cost_usd).toBe(0)
    expect(r.duration_seconds).toBe(3600)
    expect(r.status).toBe('done')
    expect(r.api_calls).toBe(2)
    expect(r.tool_calls).toBe(1)
    expect(r.output_tokens).toBe(200)
    expect(r.cache_read_tokens).toBe(2000)
    expect(r.quota_before).toBe(40)
    expect(r.quota_after).toBe(42.5)
    expect(r.quota_delta).toBe(2.5)
    expect(r.success).toBeNull()                   // done is NOT success
    expect(r.api_equivalent_cost_usd).toBeNull()   // no price file -> no guess
  })

  it('stores null, not zero, when the collector saw no calls (blind agent)', () => {
    const db = freshDb()
    db.prepare("INSERT INTO kanban_cards VALUES ('c2','x','done','murena',NULL)").run()
    db.prepare("INSERT INTO kanban_card_events (card_id, from_status, to_status, created_at) VALUES ('c2','planned','in_progress',100),('c2','in_progress','waiting',200)").run()
    deriveRuns(db, { now: 1000 })
    const [r] = listRuns(db) as any[]
    expect(r.api_calls).toBeNull()
    expect(r.output_tokens).toBeNull()
  })

  it('keeps an open run open, splits re-opened cards, and nulls a delta across a quota reset', () => {
    const db = freshDb()
    db.prepare("INSERT INTO kanban_cards VALUES ('c3','x','in_progress','acrobot',NULL)").run()
    db.prepare(`INSERT INTO kanban_card_events (card_id, from_status, to_status, created_at) VALUES
      ('c3','planned','in_progress',100),('c3','in_progress','waiting',200),('c3','waiting','in_progress',300)`).run()
    db.prepare("INSERT INTO quota_samples (sampled_at, source, seven_day_pct) VALUES (50,'t',95),(150,'t',2)").run()
    deriveRuns(db, { now: 1000 })
    const runs = listRuns(db, { task: 'c3' }) as any[]
    expect(runs.map((r) => r.run_id).sort()).toEqual(['c3:100', 'c3:300'])
    const closed = runs.find((r) => r.run_id === 'c3:100')
    expect(closed.quota_delta).toBeNull()          // 95 -> 2 is a reset, not negative use
    const open = runs.find((r) => r.run_id === 'c3:300')
    expect(open.finished_at).toBeNull()
    expect(open.status).toBe('in_progress')
  })

  it('re-deriving keeps the human outcome and does not duplicate', () => {
    const db = freshDb()
    db.prepare("INSERT INTO kanban_cards VALUES ('c4','x','done','nautilus',NULL)").run()
    db.prepare("INSERT INTO kanban_card_events (card_id, from_status, to_status, created_at) VALUES ('c4','planned','in_progress',10),('c4','in_progress','done',20)").run()
    deriveRuns(db, { now: 100 })
    expect(setRunOutcome(db, 'c4:10', 'SUCCESS', 'balazs', 'CI green, reviewed')).toBe(true)
    expect(setRunOutcome(db, 'nope', 'SUCCESS', 'balazs', null)).toBe(false)
    expect(setRunOutcome(db, 'c4:10', 'GREAT' as any, 'balazs', null)).toBe(false)
    deriveRuns(db, { now: 200 })
    const runs = listRuns(db) as any[]
    expect(runs).toHaveLength(1)
    expect(runs[0].success).toBe('SUCCESS')
    const [t] = listTasks(db) as any[]
    expect(t.task_id).toBe('c4')
    expect(t.success).toBe('SUCCESS')
  })

  it('marks an api-mode agent as api billing, with unknown incremental cost', () => {
    const db = freshDb()
    db.prepare("INSERT INTO kanban_cards VALUES ('c5','x','done','x',NULL)").run()
    db.prepare("INSERT INTO kanban_card_events (card_id, from_status, to_status, created_at) VALUES ('c5','planned','in_progress',10),('c5','in_progress','done',20)").run()
    deriveRuns(db, { now: 100, authModes: { x: 'api' } })
    const [r] = listRuns(db) as any[]
    expect(r.auth_mode).toBe('api')
    expect(r.actual_incremental_cost_usd).toBeNull()
  })
})

describe('cost and provenance', () => {
  it('computes list-price cost only from an explicit price', () => {
    const t = { input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite: 1_000_000 }
    expect(apiEquivalentCost(undefined, t)).toBeNull()
    expect(apiEquivalentCost({ input: 1, output: 2, cache_read: 0.1, cache_write: 1.25 }, t)).toBe(4.35)
  })
  it('names a provider only for known prefixes', () => {
    expect(providerOf('claude-sonnet-5')).toBe('anthropic')
    expect(providerOf('gpt-6')).toBe('openai')
    expect(providerOf('qwen3:27b')).toBeNull()
  })
  it('never labels the unmeasurable fields as exact', () => {
    for (const f of ['turns', 'retries', 'subagent_runs', 'ci_status', 'tests_passed']) {
      expect(FIELD_PROVENANCE[f]).toBe('unavailable')
    }
    expect(FIELD_PROVENANCE.input_tokens).toBe('derived')
  })
})
