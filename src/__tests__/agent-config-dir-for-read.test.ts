// Contract tests for resolveAgentConfigDirForRead.
//
// The bug this locks down, measured 2026-08-21 07:03: the dashboard's per-agent
// contextTokens was byte-identical at 04:09 and at 07:00 for all four sub-agents,
// across three hours in which one of them ran a 12 MB catalogue audit.
//
// Cause: the WRITE path and the READ path resolved different directories. The
// launcher, finding no configured config dir, auto-provisions
// agents/<name>/.claude-config and points the agent at it. The reader called
// resolveAgentConfigDir(), which only answers what was CONFIGURED, got null,
// and fell back to ~/.claude -- where three-day-old transcripts still sat.
//
// Why a stale read is worse than no read: context-restart-gate-runner treats a
// null contextTokens as a fail-closed BLOCK. A stale number is not null, so the
// gate cannot tell that it is blind.

import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { resolveAgentConfigDirForRead } from '../web/claude-plans.js'

let root: string

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'cfgdir-read-'))
})

afterEach(() => {
  rmSync(root, { recursive: true, force: true })
})

function makeAgent(name: string, opts: { isolated?: boolean; projects?: boolean } = {}): string {
  const dir = join(root, 'agents', name)
  mkdirSync(dir, { recursive: true })
  writeFileSync(join(dir, 'agent-config.json'), JSON.stringify({ model: 'claude-sonnet-5' }))
  if (opts.isolated) {
    const cfg = join(dir, '.claude-config')
    mkdirSync(cfg, { recursive: true })
    if (opts.projects !== false) mkdirSync(join(cfg, 'projects'), { recursive: true })
  }
  return dir
}

describe('resolveAgentConfigDirForRead', () => {
  it('finds the auto-provisioned isolated config dir the launcher created', () => {
    makeAgent('polip', { isolated: true })
    expect(resolveAgentConfigDirForRead('polip', root)).toBe(
      join(root, 'agents', 'polip', '.claude-config'),
    )
  })

  it('returns null when no isolated dir exists, so the reader falls back to the host default', () => {
    // The known-good half: an agent that genuinely uses the shared ~/.claude
    // must NOT be redirected. A check that always finds something is not a check.
    makeAgent('shared-agent')
    expect(resolveAgentConfigDirForRead('shared-agent', root)).toBeNull()
  })

  it('ignores a half-provisioned dir that has no projects subdirectory', () => {
    // A .claude-config that exists but carries no transcripts must not shadow
    // the shared root the agent may still be writing to.
    makeAgent('halfway', { isolated: true, projects: false })
    expect(resolveAgentConfigDirForRead('halfway', root)).toBeNull()
  })

  it('returns null for an agent that does not exist at all', () => {
    expect(resolveAgentConfigDirForRead('nobody', root)).toBeNull()
  })
})
