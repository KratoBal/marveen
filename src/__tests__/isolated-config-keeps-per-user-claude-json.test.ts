import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import {
  mkdtempSync, mkdirSync, writeFileSync, rmSync, lstatSync, readFileSync,
} from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'

// A per-user agent's own .claude.json must survive provisioning.
//
// THE CHAIN, measured on 2026-09-01 (two agents, hours apart): a 44 kB
// .claude.json shrank to 423 bytes and the agent came up on the first-run
// gate. Nothing errored and nothing was logged, so it had to be read back out
// of the source:
//
//   provisionIsolatedConfigDir symlinks every ~/.claude entry into the agent's
//   isolated dir. It skips .claude.json for a per-user agent, because that
//   agent cannot follow a symlink into the router's 0600 home -- it would read
//   nothing and Claude Code would write a brand-new profile. That skip hung on
//   readAgentRunAsUser(), which resolved through readFileOr(path, '{}'): an
//   unreadable agent-config.json returned '{}' SILENTLY, runAsUser came back
//   null, the skip did not happen, and the real file was deleted and replaced
//   by a link.
//
// So the bug was never "we decided wrong" -- it was "we could not tell, and the
// uncertainty fell the harmful way". These tests pin the direction it falls now.
//
// WHY A DIRECTORY AND NOT chmod 000 FOR THE UNREADABLE CASE: a test that leans
// on POSIX permissions passes as root (root reads a 000 file) and then measures
// nothing at all. A directory where a file is expected makes readFileSync throw
// EISDIR for every user, CI included.
let SANDBOX = ''
vi.mock('node:os', async (orig) => {
  const actual = await orig<typeof import('node:os')>()
  return { ...actual, homedir: () => join(SANDBOX, 'home') }
})
//
// WHY THE MOCK ALSO REPLACES readAgentRunAsUser, AND NOT JUST agentDir.
//
// Measured 2026-09-01, and it is the reason the first calibration came out
// wrong: a spread mock replaces what the TEST imports, not what a module calls
// INSIDE itself. readAgentRunAsUser lives in agent-config.js and calls that
// module's own agentDir -- the real one -- so with only agentDir replaced it
// looked outside the sandbox, found no agent-config.json anywhere, and reported
// "not per-user" for EVERY case. Both of the first two assertions then measured
// the same path, while their names promised two different ones.
//
// The fixed code calls agentDir directly from agent-process.ts, so it does see
// the mock -- which is exactly why the tests went green on the fix and hid the
// problem. Only the calibration on the OLD code exposed it.
vi.mock('../web/agent-config.js', async (orig) => {
  const actual = await orig<typeof import('../web/agent-config.js')>()
  const agentDir = (name: string) => join(SANDBOX, 'agents', name)
  return {
    ...actual,
    agentDir,
    readAgentRunAsUser: (name: string) =>
      actual.resolveRunAsUser(
        actual.readFileOr(join(agentDir(name), 'agent-config.json'), '{}'),
      ),
  }
})

const { ensureIsolatedChannelConfigDir } = await import('../web/agent-process.js')

const OWN_PROFILE = JSON.stringify({ note: 'the agent own profile', projects: {} })

function seedSharedClaude(home: string) {
  const claude = join(home, '.claude')
  mkdirSync(claude, { recursive: true })
  // The router's own file. In production it is 0600 and owned by another user;
  // here its CONTENT is what tells the two outcomes apart.
  writeFileSync(join(claude, '.claude.json'), JSON.stringify({ note: 'the router file' }))
  writeFileSync(join(claude, 'settings.json'), '{}')
}

/** The agent's isolated dir, already holding a real profile of its own. */
function seedAgentProfile(name: string) {
  const cfg = join(SANDBOX, 'agents', name, '.claude-config')
  mkdirSync(cfg, { recursive: true })
  writeFileSync(join(cfg, '.claude.json'), OWN_PROFILE)
  return join(cfg, '.claude.json')
}

beforeEach(() => {
  SANDBOX = mkdtempSync(join(tmpdir(), 'peruser-'))
  seedSharedClaude(join(SANDBOX, 'home'))
  mkdirSync(join(SANDBOX, 'agents', 'testagent'), { recursive: true })
})
afterEach(() => {
  rmSync(SANDBOX, { recursive: true, force: true })
})

describe('a per-user agent keeps its own .claude.json through provisioning', () => {
  /**
   * WHAT THESE ASSERT, AND WHAT THEY DELIBERATELY DO NOT.
   *
   * Not byte-equality: provisioning WRITES to this file on purpose
   * (stampProjectTrustForDir, stampFableOverageConsent), so demanding the exact
   * bytes back would fail on a working system and say nothing about the bug.
   * What matters is WHOSE profile the file grew out of -- the agent's own, or
   * the router's. The seeded marker tells the two apart.
   */
  it('keeps it when the config says runAsUser', () => {
    const profile = seedAgentProfile('testagent')
    writeFileSync(
      join(SANDBOX, 'agents', 'testagent', 'agent-config.json'),
      JSON.stringify({ runAsUser: 'agent-testagent' }),
    )

    ensureIsolatedChannelConfigDir('testagent', 'telegram')

    expect(lstatSync(profile).isSymbolicLink()).toBe(false)
    // The agent's OWN profile is still the base it grew from.
    expect(readFileSync(profile, 'utf-8')).toContain('the agent own profile')
  })

  /**
   * THE FIX ITSELF: an unreadable agent-config.json used to mean "not per-user",
   * and the file was deleted. It now means "we cannot tell", and the file stays.
   *
   * A needless skip omits a symlink nobody was using. A needless delete costs an
   * agent its session. The two mistakes are not the same size, so the doubt has
   * to fall on the side of keeping.
   */
  it('keeps it when the config cannot be read at all', () => {
    const profile = seedAgentProfile('testagent')
    // A directory where agent-config.json is expected: readFileSync throws
    // EISDIR for every user, so this case does not quietly pass as root.
    mkdirSync(join(SANDBOX, 'agents', 'testagent', 'agent-config.json'), { recursive: true })

    ensureIsolatedChannelConfigDir('testagent', 'telegram')

    expect(lstatSync(profile).isSymbolicLink()).toBe(false)
    expect(readFileSync(profile, 'utf-8')).toContain('the agent own profile')
  })

  /**
   * THE POSITIVE CONTROL, AND WITHOUT IT THE TWO ABOVE PROVE NOTHING.
   *
   * If provisioning simply never touched .claude.json, both assertions would be
   * green while measuring nothing. A shared-home agent -- readable config, no
   * runAsUser -- must end up on the ROUTER's profile instead of its own.
   *
   * WHY NOT "must be a symlink", WHICH IS THE OBVIOUS FORM AND IS WRONG:
   * measured 2026-09-01, the symlink IS created and then stops being one. The
   * stamps that run right after write through atomicWriteFileSync, and a
   * temp-file rename replaces the LINK rather than following it to its target
   * (measured separately: after the rename the link is a real file and the
   * target is untouched). So a per-user check phrased as "is a symlink" asserts
   * a state that never survives to the end of provisioning -- it would be red on
   * correct code, for a reason that has nothing to do with this fix.
   *
   * The content is what actually separates the two paths, and it does survive.
   */
  it('starts from the router profile for an agent that is NOT per-user', () => {
    const profile = seedAgentProfile('testagent')
    writeFileSync(
      join(SANDBOX, 'agents', 'testagent', 'agent-config.json'),
      JSON.stringify({ model: 'claude-fable-5' }),
    )

    ensureIsolatedChannelConfigDir('testagent', 'telegram')

    // The router's file is what this agent now reads -- exactly the outcome the
    // per-user skip exists to prevent, and here it is expected.
    expect(readFileSync(profile, 'utf-8')).toContain('the router file')
    expect(readFileSync(profile, 'utf-8')).not.toContain('the agent own profile')
  })
})
