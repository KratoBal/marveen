import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { mkdtempSync, writeFileSync, chmodSync, rmSync, statSync, existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'

// CONFIGMODE901. The two stamps write through atomicWriteFileSync, which is
// tmp + rename: the file the agent ends up with is a NEW inode, owned by
// whoever ran the router, carrying exactly the mode the call passed in. Both
// call sites passed a hard-coded 0600, so a per-user agent -- a DIFFERENT OS
// user, reaching its config through the shared `fleet` group -- was locked out
// of its own profile the moment the router stamped it. Claude Code then wrote a
// fresh ~423-byte profile over it and the agent came up on the login picker
// with a valid token in its environment.
//
// Measured on polip 2026-09-01 21:17, four states inside three seconds:
//   t+0  43840 B  0660 marveen:fleet   <- restored config
//   t+3  43925 B  0600 marveen:fleet   <- the stamp, group bit dropped
//   t+3    343 B  0600 agent-polip     <- Claude Code, brand-new profile
//   t+3    423 B  0600 agent-polip
//
// The mode is the whole finding, so that is what these assertions pin. They are
// deliberately about the FILE, not about the stamp's JSON: the flags were
// always written correctly -- they just landed somewhere the agent could not
// read.
const { stampProjectTrustForDir } = await import('../web/agent-process.js')

let dir = ''
const dot = (): string => join(dir, '.claude.json')
const project = (): string => join(dir, 'project')

beforeEach(() => { dir = mkdtempSync(join(tmpdir(), 'stampmode-')) })
afterEach(() => { rmSync(dir, { recursive: true, force: true }) })

function mode(path: string): string {
  return (statSync(path).mode & 0o777).toString(8)
}

describe('stampProjectTrustForDir keeps the file readable by whoever could read it before', () => {
  it('preserves a group-shared 0660 config (the per-user agent case)', () => {
    // writeFileSync's mode is reduced by the process umask, so set it explicitly
    // -- the same reason atomicWriteFileSync chmods its temp file.
    writeFileSync(dot(), JSON.stringify({ hasCompletedOnboarding: false }))
    chmodSync(dot(), 0o660)
    expect(mode(dot())).toBe('660')

    expect(stampProjectTrustForDir(dot(), project())).toBe(true)

    // The stamp must have happened...
    expect(JSON.parse(readFileSync(dot(), 'utf-8')).hasCompletedOnboarding).toBe(true)
    // ...without taking the group's access away with it.
    expect(mode(dot())).toBe('660')
  })

  it('does not WIDEN a 0600 config', () => {
    writeFileSync(dot(), JSON.stringify({ hasCompletedOnboarding: false }))
    chmodSync(dot(), 0o600)

    expect(stampProjectTrustForDir(dot(), project())).toBe(true)

    expect(mode(dot())).toBe('600')
  })

  it('creates a config that does not exist yet at 0600', () => {
    expect(existsSync(dot())).toBe(false)

    expect(stampProjectTrustForDir(dot(), project())).toBe(true)

    expect(mode(dot())).toBe('600')
  })
})
