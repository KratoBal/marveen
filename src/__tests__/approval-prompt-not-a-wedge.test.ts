// An agent parked on a permission prompt is NOT wedged -- and the alert must
// say so.
//
// Measured 2026-08-21, one unattended night: three [session-stuck] alerts fired
// on agents that were sitting on read-only permission prompts, every one of
// them carrying the default advice "restart the agent if it is wedged". The two
// states are indistinguishable from the queue side, because a session awaiting
// approval never drains its inbox either. Anyone following the alert from a
// template restarts a healthy agent and throws away its turn; the prompt then
// comes straight back.
//
// Two units are locked down here: the pane detector (does this capture show a
// permission prompt?) and the alert text (does it tell the reader not to
// restart?).

import { describe, it, expect } from 'vitest'
import { detectsApprovalPrompt } from '../pane-state.js'
import { formatStuckSessionAlert } from '../web/message-router.js'

// A permission prompt as Claude Code renders it: the question, numbered
// options, and the selection caret on one of them.
const APPROVAL_PANE = [
  '● I need to read the catalogue dump to count the fields.',
  '',
  '╭──────────────────────────────────────────────────────────────╮',
  '│ Do you want to proceed?                                      │',
  '│                                                              │',
  '│ ❯ 1. Yes                                                     │',
  '│   2. Yes, and don\'t ask again for grep commands              │',
  '│   3. No, and tell Claude what to do differently (esc)        │',
  '╰──────────────────────────────────────────────────────────────╯',
].join('\n')

// The same words, but quoted inside a report the agent is writing. This is the
// false positive that matters: an agent that merely TALKS about permission
// prompts must not be labelled as sitting on one.
const QUOTING_PANE = [
  '● A tegnapi kor tanulsaga: az agens megallt egy "Do you want to proceed?"',
  '  kerdesen, es addig nem kapott uzenetet.',
  '',
  '────────────────────────────────────────────────────────────────',
  '❯ ',
  '────────────────────────────────────────────────────────────────',
  '  ⏵⏵ accept edits on (shift+tab to cycle) · ← for agents',
].join('\n')

// A REAL capture, taken from barracuda at 2026-08-21 08:52 while it sat on a
// read permission for scripts/fb-insights.sh. Kept verbatim because it differs
// from the box-drawn shape above in exactly the way that would have broken a
// regex tuned to one of them: there is NO box frame, just leading spaces, and
// the dismiss hint is `Esc to cancel · Tab to amend`.
const REAL_APPROVAL_PANE = [
  '  Reading measurement/2026-08-18-hirdetestar-baseline.md',
  '  ⎿  measurement/2026-08-18-hirdetestar-baseline.md',
  '',
  '────────────────────────────────────────────────────────────────',
  ' Read file',
  '',
  '  Read(/home/marveen/marveen/scripts/fb-insights.sh · lines 1-45)',
  '',
  ' Do you want to proceed?',
  ' ❯ 1. Yes',
  '   2. Yes, allow reading from /home/marveen/marveen/scripts during this session',
  '   3. No',
  '',
  ' Esc to cancel · Tab to amend',
].join('\n')

const BUSY_PANE = [
  '│ Do you want to proceed?                                      │',
  '│ ❯ 1. Yes                                                     │',
  '',
  '✻ Cooking… (12s · esc to interrupt)',
].join('\n')

describe('detectsApprovalPrompt', () => {
  it('recognises a real permission prompt', () => {
    expect(detectsApprovalPrompt(APPROVAL_PANE)).toBe(true)
  })

  it('recognises the real capture taken off a live agent', () => {
    // Not a hand-written fixture: this shape came off barracuda's pane while it
    // was actually blocked. It has no box frame at all, which the first version
    // of the option regex would have missed.
    expect(detectsApprovalPrompt(REAL_APPROVAL_PANE)).toBe(true)
  })

  it('does not fire on a pane that merely quotes the question', () => {
    // No numbered options in the live region -> prose, not a prompt.
    expect(detectsApprovalPrompt(QUOTING_PANE)).toBe(false)
  })

  it('does not fire while a turn is actively running', () => {
    // A live turn is never a parked prompt, even if the box is still on screen.
    expect(detectsApprovalPrompt(BUSY_PANE)).toBe(false)
  })

  it('does not fire on an empty or whitespace pane', () => {
    expect(detectsApprovalPrompt('')).toBe(false)
    expect(detectsApprovalPrompt('   \n  \n')).toBe(false)
  })
})

describe('formatStuckSessionAlert with a pending approval', () => {
  it('says do NOT restart, and names what is actually needed', () => {
    const alert = formatStuckSessionAlert('polip', 'acrobot', 'agent-polip', 15 * 60_000, 2, null, true)
    expect(alert).not.toBeNull()
    expect(alert).toContain('PERMISSION PROMPT')
    expect(alert).toContain('Do NOT restart')
    expect(alert).toContain('approve or deny')
    // The old advice must be gone from this branch -- that is the whole fix.
    expect(alert).not.toContain('restart the agent if it is wedged')
  })

  it('leaves the ordinary not-ready alert untouched when no approval is pending', () => {
    // The known-good half: the fix must not swallow real wedge alerts.
    const alert = formatStuckSessionAlert('polip', 'acrobot', 'agent-polip', 15 * 60_000, 2, null, false)
    expect(alert).toContain('restart the agent if it is wedged')
    expect(alert).not.toContain('PERMISSION PROMPT')
  })

  it('the approval branch wins over a busy pane state', () => {
    // Both can be true in one capture; only one of them has an action attached.
    const alert = formatStuckSessionAlert('polip', 'acrobot', 'agent-polip', 15 * 60_000, 1, 'busy', true)
    expect(alert).toContain('PERMISSION PROMPT')
  })

  it('still refuses to let the main agent alert itself about itself', () => {
    expect(formatStuckSessionAlert('acrobot', 'acrobot', 's', 60_000, 1, null, true)).toBeNull()
  })
})
