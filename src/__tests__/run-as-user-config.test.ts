import { describe, it, expect } from 'vitest'
import { resolveRunAsUser } from '../web/agent-config.js'

// The value this resolver returns is handed to `sudo -u`. Nothing downstream
// quotes or escapes it, so anything questionable has to die here.
describe('resolveRunAsUser', () => {
  it('returns null when the agent has no runAsUser (today: every agent)', () => {
    expect(resolveRunAsUser('{}')).toBeNull()
    expect(resolveRunAsUser('{"remoteHost":"devbox","remoteWorkdir":"/srv/p"}')).toBeNull()
  })

  it('returns null for unparseable or non-object JSON', () => {
    expect(resolveRunAsUser('not json')).toBeNull()
    expect(resolveRunAsUser('')).toBeNull()
    expect(resolveRunAsUser('"agent-korall"')).toBeNull()
    expect(resolveRunAsUser('null')).toBeNull()
  })

  it('accepts a plain account name and trims it', () => {
    expect(resolveRunAsUser('{"runAsUser":"agent-korall"}')).toBe('agent-korall')
    expect(resolveRunAsUser('{"runAsUser":"  agent-korall  "}')).toBe('agent-korall')
    expect(resolveRunAsUser('{"runAsUser":"_svc"}')).toBe('_svc')
  })

  it('rejects anything that is not a POSIX account name', () => {
    // A leading dash would be read by sudo as an option, not a user.
    expect(resolveRunAsUser('{"runAsUser":"-rf"}')).toBeNull()
    // Shell metacharacters and whitespace never belong in an account name.
    expect(resolveRunAsUser('{"runAsUser":"agent korall"}')).toBeNull()
    expect(resolveRunAsUser('{"runAsUser":"korall;id"}')).toBeNull()
    expect(resolveRunAsUser('{"runAsUser":"korall$(id)"}')).toBeNull()
    expect(resolveRunAsUser('{"runAsUser":"../root"}')).toBeNull()
    // Uppercase is legal in some systems but not in ours: keep one spelling.
    expect(resolveRunAsUser('{"runAsUser":"Agent-Korall"}')).toBeNull()
    // Longer than useradd allows.
    expect(resolveRunAsUser(`{"runAsUser":"${'a'.repeat(33)}"}`)).toBeNull()
    expect(resolveRunAsUser('{"runAsUser":""}')).toBeNull()
    expect(resolveRunAsUser('{"runAsUser":42}')).toBeNull()
  })

  it('accepts exactly 32 characters (the useradd limit), rejects 33', () => {
    expect(resolveRunAsUser(`{"runAsUser":"${'a'.repeat(32)}"}`)).toBe('a'.repeat(32))
    expect(resolveRunAsUser(`{"runAsUser":"${'a'.repeat(33)}"}`)).toBeNull()
  })
})

// The fallback that lets a caller holding only a session name still reach an
// agent that owns its OS user. The session name comes from tmux's own -t/-s
// flag; the ANSWER comes from the config map, never from the name.
import { runAsUserForTmuxArgs } from '../web/agent-process.js'

describe('runAsUserForTmuxArgs', () => {
  const map = new Map([['agent-korall', 'agent-korall']])

  it('finds the user behind a -t session', () => {
    expect(runAsUserForTmuxArgs(['send-keys', '-t', 'agent-korall', 'hi'], map)).toBe('agent-korall')
  })

  it('finds it behind -s too (new-session)', () => {
    expect(runAsUserForTmuxArgs(['new-session', '-d', '-s', 'agent-korall', 'cmd'], map)).toBe('agent-korall')
  })

  it('strips a window/pane suffix', () => {
    expect(runAsUserForTmuxArgs(['capture-pane', '-t', 'agent-korall:0.1', '-p'], map)).toBe('agent-korall')
  })

  it('returns null for a session with no per-user agent (today: all of them)', () => {
    expect(runAsUserForTmuxArgs(['send-keys', '-t', 'agent-murena', 'hi'], map)).toBeNull()
    expect(runAsUserForTmuxArgs(['list-sessions'], map)).toBeNull()
  })

  it('never treats a bare value as a session: only what follows -t or -s counts', () => {
    expect(runAsUserForTmuxArgs(['kill-session', 'agent-korall'], map)).toBeNull()
    // a trailing -t with nothing after it must not read past the end
    expect(runAsUserForTmuxArgs(['send-keys', '-t'], map)).toBeNull()
  })
})
