// A sub-agent that runs under its own OS user writes its transcripts into
// agents/<name>/.claude-config/projects/, NOT into ~/.claude/projects/. Before
// 2026-08-21 the collector only read the shared root, so a migrated agent's
// usage silently stopped being counted while the stale directory kept parsing --
// it read as an idle agent, not as a gap.
//
// WHY THE FIXTURE LIVES ENTIRELY IN A TEMP DIRECTORY, AND WHY THE MOCK RETURNS
// null WITHOUT A ROOT: an earlier version of this file built the isolated path
// as join(root ?? '', ...), which without a root yields a RELATIVE path -- and
// relative to the process working directory that resolves to the real agents/
// folder. The test then walked live agent directories and failed differently on
// different machines (an assertion error where ~/.claude/projects is absent, an
// EACCES where it exists and one agent's directory is group-restricted). Both
// symptoms came from one defect, found by murena on 2026-08-28: the early
// `if (!existsSync(PROJECTS_DIR)) return sources` left the isolated branch
// unreachable. That guard now wraps the shared loop instead of returning, so
// this file measures the isolated branch on its own fixture, on any machine.

import { describe, it, expect, vi, beforeAll, afterAll } from 'vitest'
import { mkdirSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

// Sajat, eldobhato gyoker. A mkdtemp azert kell a fix /tmp/<nev> helyett, mert
// ket parhuzamos futas kulonben ugyanabba a mappaba irna.
const FIXTURE_ROOT = mkdtempSync(join(tmpdir(), 'token-usage-isolated-'))

const AGENT_COMPLETE = 'tesztagens-teljes'
const AGENT_HALF = 'tesztagens-felig'
const AGENT_FILE = 'tesztagens-fajl'

// A FIXTURA MAPPANEVE SZANDEKOSAN NEM ILLESZKEDIK SEMMILYEN KODOLT UTVONALRA,
// ES EZT NE "JAVITSA" SENKI a -home-...-agents-<nev> alakra.
//
// A Claude Code a megosztott gyokerben (~/.claude/projects) az abszolut utat
// kodolja a mappanevbe, es OTT ez a nev valoban szamit. Az IZOLALT agban
// viszont a hozzarendeles a config-mappa GAZDAJABOL jon, nem a nevbol -- a
// mert kod kommentje ezt ki is mondja.
//
// Ezert ha a fixtura neve pont a "helyes" kodolt alak lenne, a teszt NEM tudna
// megkulonboztetni a helyes megvalositast attol, amelyik nev szerint szur: egy
// kesobb bevezetett nev-szures mellett is ZOLD MARADNA. Egy nem illeszkedo nev
// egyszerre teszi a tesztet hordozhatova ES erosebbe.
const PROJECT_DIR_NAME = 'barmi-ami-nem-kodolt-utvonal'

vi.mock('../logger.js', () => ({
  logger: { info: vi.fn(), warn: vi.fn(), debug: vi.fn(), error: vi.fn() },
}))

vi.mock('../web/agent-config.js', async () => {
  const actual = await vi.importActual<typeof import('../web/agent-config.js')>('../web/agent-config.js')
  return { ...actual, listAgentNames: () => [AGENT_COMPLETE, AGENT_HALF, AGENT_FILE] }
})

vi.mock('../web/claude-plans.js', async () => {
  const actual = await vi.importActual<typeof import('../web/claude-plans.js')>('../web/claude-plans.js')
  return {
    ...actual,
    // ROOT NELKUL NULL, NEM RELATIV UT. A hivo ezt kihagyasnak veszi, tehat a
    // teszt semmilyen korulmenyek kozott nem er el a valodi agents mappahoz.
    resolveAgentConfigDirForRead: (name: string, root?: string) =>
      root ? join(root, 'agents', name, '.claude-config') : null,
  }
})

beforeAll(() => {
  // 1. TELJES: van projects almappa, benne egy projekt-mappa egy atirattal.
  const complete = join(
    FIXTURE_ROOT, 'agents', AGENT_COMPLETE, '.claude-config', 'projects', PROJECT_DIR_NAME,
  )
  mkdirSync(complete, { recursive: true })
  writeFileSync(join(complete, 'sess.jsonl'), '')

  // 2. FELIG LETREHOZOTT: a config-mappa megvan, a projects almappa NINCS.
  //    Ez nem elmeleti eset: a letrehozo pontosan ilyen allapotot hagy maga
  //    utan, ha a masodik lepese elhal.
  mkdirSync(join(FIXTURE_ROOT, 'agents', AGENT_HALF, '.claude-config'), { recursive: true })

  // 3. FAJL A MAPPA HELYEN: a projects alatt egy FAJL all, nem konyvtar.
  //    A mert kodban van ra ag (statSync plusz isDirectory), es ma egyetlen
  //    teszt sem megy rajta vegig.
  const fileCase = join(FIXTURE_ROOT, 'agents', AGENT_FILE, '.claude-config', 'projects')
  mkdirSync(fileCase, { recursive: true })
  writeFileSync(join(fileCase, 'ez-egy-fajl.txt'), '')
})

afterAll(() => {
  rmSync(FIXTURE_ROOT, { recursive: true, force: true })
})

describe('discoverAgentSources az izolalt config-mappaval', () => {
  it('megtalalja az atiratot, amit egy atkoltoztetett sub-agens tenylegesen ir', async () => {
    const { discoverAgentSources } = await import('../web/token-usage.js')
    const sources = discoverAgentSources(FIXTURE_ROOT)

    const mine = sources.filter((s) => s.agent === AGENT_COMPLETE)
    expect(mine).toHaveLength(1)
    expect(mine[0].projectDir).toBe(
      join(FIXTURE_ROOT, 'agents', AGENT_COMPLETE, '.claude-config', 'projects', PROJECT_DIR_NAME),
    )
  })

  it('a hozzarendeles a config-mappa gazdajabol jon, NEM a mappa nevebol', async () => {
    // EZ AZ ALLITAS, AMIT A REGI FIXTURA NEV NEM TUDOTT MERNI. A projekt-mappa
    // neve semmilyen kodolt utvonalra nem illeszkedik, tehat ha a kod valaha
    // nev szerint szurne, ez a sor pirosodna -- a regi nevvel nem pirosodott
    // volna.
    const { discoverAgentSources } = await import('../web/token-usage.js')
    const sources = discoverAgentSources(FIXTURE_ROOT)

    const mine = sources.filter((s) => s.agent === AGENT_COMPLETE)
    expect(mine).toHaveLength(1)
    expect(mine[0].projectDir.endsWith(PROJECT_DIR_NAME)).toBe(true)
  })

  it('kihagyja a felig letrehozott config-mappat, aminek nincs projects almappaja', async () => {
    const { discoverAgentSources } = await import('../web/token-usage.js')
    const sources = discoverAgentSources(FIXTURE_ROOT)

    expect(sources.filter((s) => s.agent === AGENT_HALF)).toHaveLength(0)
  })

  it('a projects alatt allo FAJLT nem veszi forrasnak', async () => {
    const { discoverAgentSources } = await import('../web/token-usage.js')
    const sources = discoverAgentSources(FIXTURE_ROOT)

    expect(sources.filter((s) => s.agent === AGENT_FILE)).toHaveLength(0)
  })

  it('root nelkul egyetlen izolalt forrast sem ad', async () => {
    // A HORDOZHATOSAG ORZOJE. Ha valaki visszaallitja a mockot a join(root ?? '')
    // alakra, ez a sor pirosodik: root nelkul relativ ut keletkezne, ami a
    // folyamat munkakonyvtarahoz kepest a VALODI agents mappara mutat.
    const { discoverAgentSources } = await import('../web/token-usage.js')
    const sources = discoverAgentSources(undefined)

    for (const name of [AGENT_COMPLETE, AGENT_HALF, AGENT_FILE]) {
      expect(sources.filter((s) => s.agent === name)).toHaveLength(0)
    }
  })
})
