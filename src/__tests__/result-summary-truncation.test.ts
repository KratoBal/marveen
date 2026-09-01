import { describe, it, expect } from 'vitest'
import { summarizeResult, RESULT_SUMMARY_LIMIT } from '../web/routes/messages.js'

// Why this file exists: the receipt sent back to a message's sender used to carry a bare
// `result.slice(0, 500)`. A result longer than that arrived ending mid-word, with nothing
// to say it had been cut, so the reader could not distinguish a truncation from a sender
// who stopped typing. Two real losses were measured on 2026-08-26 before the marker existed.
describe('summarizeResult', () => {
  it('leaves a result that fits completely untouched', () => {
    const short = 'a'.repeat(RESULT_SUMMARY_LIMIT)
    expect(summarizeResult(short)).toBe(short)
  })

  it('keeps the first RESULT_SUMMARY_LIMIT characters when it does not fit', () => {
    const long = 'a'.repeat(RESULT_SUMMARY_LIMIT) + 'ELVESZETT'
    expect(summarizeResult(long).startsWith('a'.repeat(RESULT_SUMMARY_LIMIT))).toBe(true)
  })

  it('marks the cut and names both lengths, so the gap is visible', () => {
    const long = 'a'.repeat(RESULT_SUMMARY_LIMIT + 677)
    const summary = summarizeResult(long)
    expect(summary).toContain('LEVÁGVA')
    expect(summary).toContain(String(long.length))
    expect(summary).toContain(String(RESULT_SUMMARY_LIMIT))
  })

  // The bug this whole file guards against: silence. A summary of an over-long result must
  // never be indistinguishable from a complete one.
  it('never returns a bare slice for an over-long result', () => {
    const long = 'a'.repeat(RESULT_SUMMARY_LIMIT + 1)
    expect(summarizeResult(long)).not.toBe(long.slice(0, RESULT_SUMMARY_LIMIT))
  })

  it('does not fire one character below the limit', () => {
    const edge = 'a'.repeat(RESULT_SUMMARY_LIMIT - 1)
    expect(summarizeResult(edge)).not.toContain('LEVÁGVA')
  })
})
