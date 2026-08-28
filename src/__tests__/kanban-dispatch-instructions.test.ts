import { describe, expect, it } from 'vitest'
import { kanbanMoveInstructions } from '../web/routes/kanban.js'

// A card dispatched to an agent used to just say "drag it to done" -- but a
// headless agent cannot drag, and the run left no record on the card. The
// instructions now hand the agent the exact fleet-api.sh calls to post a result
// summary and to mark the card done, so the dispatched task's RESULT lands on
// its own card (visible in the dashboard UI) -- the lightweight alternative to
// per-session cards.
//
// UPDATED 2026-08-21: the template moved off raw curl and onto the helper. Two
// independent reasons, both measured: (1) the strict security profiles withhold
// raw curl, so a curl-shaped instruction stops the receiving agent on a
// permission prompt -- and a blocked agent cannot even be messaged, so it goes
// silent instead of failing loudly (polip, 2026-08-15); (2) the old template
// embedded `$(cat <token>)`, and that substitution runs in ANY double-quoted
// context, so merely quoting the instruction back inside a report executed it.
// These tests now assert the helper shape and the ABSENCE of the substitution.
describe('kanbanMoveInstructions', () => {
  it('gives the agent the helper calls to post a result comment AND to mark done', () => {
    const out = kanbanMoveInstructions('abc123', 'cody')
    // Step 1: a human-readable result comment lands on the card.
    expect(out).toContain('kanban-comment abc123 cody')
    // Step 2: mark the card done.
    expect(out).toContain('kanban-move abc123 done cody')
    // It must NOT rely on the agent "dragging" the card (a headless agent can't).
    expect(out).not.toContain('húzd "done"-ra')
  })

  // Without an actor the board cannot tell a self-pickup from an assignment, so
  // every move the agent is handed names the agent as the mover -- including
  // the in_progress self-pickup, which is the one the dispatcher used to echo back.
  it('names the agent as the actor on every move it is told to make', () => {
    const out = kanbanMoveInstructions('abc123', 'cody')
    expect(out).toContain('kanban-move abc123 done cody')
    expect(out).toContain('kanban-move abc123 in_progress cody')
    expect(out).toContain('kanban-move abc123 waiting cody')
  })

  it('carries no command substitution and no token path at all', () => {
    const out = kanbanMoveInstructions('abc123', 'cody')
    // The whole point of the helper: the token is read at run time, inside the
    // script, so it never appears in a message that gets quoted, logged and
    // pasted onward.
    expect(out).not.toContain('$(cat ')
    expect(out).not.toContain('.dashboard-token')
    // And no raw curl, which the strict profiles refuse.
    expect(out).not.toContain('curl ')
    // The helper path is what replaced it.
    expect(out).toContain('scripts/fleet-api.sh')
  })
})
