// Measurement Layer v1: the statusLine that samples the subscription quota and,
// for sub-agents, exports their own token numbers (scripts/measure-statusline.py).
// Shared by the sub-agent settings writer (agent-scaffold.ts) and the worker
// provisioning (agent-worker.ts ensureWorkerCwd), so both install it the same way.
//
// Never overwrites a statusLine someone set on purpose: only a missing one, or
// one that already points at the measurement script (so the command can be
// upgraded in place). Fail-open wrapper: a missing script prints nothing
// instead of an error in the status bar, and never fails the session.

import { join } from 'node:path'
import { PROJECT_ROOT } from '../config.js'

const _measureScript = join(PROJECT_ROOT, 'scripts', 'measure-statusline.py')

export function measureStatusLineCommand(agent: string, exportUsage: boolean): string {
  const flag = exportUsage ? ' --export-usage' : ''
  return `bash -c '[ -f ${_measureScript} ] && MEASURE_AGENT=${agent} exec python3 ${_measureScript}${flag}; exit 0'`
}

export function injectMeasureStatusLine(settings: Record<string, unknown>, agent: string, exportUsage: boolean): boolean {
  const cur = settings.statusLine as { command?: unknown } | undefined
  if (cur && !(typeof cur.command === 'string' && cur.command.includes('measure-statusline.py'))) return false
  const want = { type: 'command', command: measureStatusLineCommand(agent, exportUsage), padding: 0 }
  if (cur && JSON.stringify(cur) === JSON.stringify(want)) return false
  settings.statusLine = want
  return true
}
