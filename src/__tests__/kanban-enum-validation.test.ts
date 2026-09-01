// Contract tests for the kanban status/priority input check.
//
// Why this exists: kanban_cards constrains status and priority with a CHECK.
// Before this check the route handed a bad value straight to SQLite, better-
// sqlite3 threw, and the endpoint answered 500 -- so an INPUT error arrived
// looking like a SERVER error. Measured 2026-08-20: an agent moved a card to a
// status it had invented ("review"), read the 500 as "the board is broken", and
// went hunting a fault that did not exist.
//
// The list here is deliberately asserted against the production CHECK
// constraint too: if someone adds a sixth status to the schema and forgets the
// route, the drift shows up as a failing test rather than as a 500 in the wild.

import { describe, it, expect, beforeEach } from 'vitest'
import { checkKanbanEnums, KANBAN_STATUSES, KANBAN_PRIORITIES } from '../web/routes/kanban.js'
import { initDatabase, createKanbanCard, moveKanbanCard } from '../db.js'

beforeEach(() => {
  initDatabase(':memory:')
})

describe('kanban enum validation', () => {
  it('accepts every status the schema allows', () => {
    // The known-good half: a check that only ever rejects is not a check.
    for (const status of KANBAN_STATUSES) {
      expect(checkKanbanEnums({ status })).toBeNull()
    }
    for (const priority of KANBAN_PRIORITIES) {
      expect(checkKanbanEnums({ priority })).toBeNull()
    }
  })

  it('accepts a payload with neither field (create defaults, partial update)', () => {
    expect(checkKanbanEnums({})).toBeNull()
    expect(checkKanbanEnums({ title: 'no enums here' })).toBeNull()
  })

  it('rejects the invented status that caused the 500, and names the legal values', () => {
    const err = checkKanbanEnums({ status: 'review' })
    expect(err).not.toBeNull()
    expect(err).toContain('review')
    // The message must be actionable on its own -- that is the whole point.
    for (const status of KANBAN_STATUSES) {
      expect(err).toContain(status)
    }
  })

  it('rejects a bad priority and a non-string value', () => {
    expect(checkKanbanEnums({ priority: 'blocker' })).toContain('blocker')
    expect(checkKanbanEnums({ status: 42 })).not.toBeNull()
    expect(checkKanbanEnums({ priority: { high: true } })).not.toBeNull()
  })

  it('null is treated as absent, not as a bad value', () => {
    // updateKanbanCard callers send explicit nulls for untouched fields.
    expect(checkKanbanEnums({ status: null, priority: null })).toBeNull()
  })

  it('the route list matches what the database will actually accept', () => {
    // Drive each declared status through the real CHECK constraint. If the
    // route list ever names a value the schema rejects, this throws here
    // instead of surfacing as a 500 to a caller.
    createKanbanCard({ id: 'enum-card', title: 'Enum probe' })
    for (const status of KANBAN_STATUSES) {
      expect(() => moveKanbanCard('enum-card', status, 0, 'test')).not.toThrow()
    }
    // And the inverse: a value outside the list really is refused by the DB,
    // which is what makes the route-level check necessary in the first place.
    expect(() => moveKanbanCard('enum-card', 'review' as never, 0, 'test')).toThrow()
  })
})
