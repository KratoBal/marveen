import { defineConfig, configDefaults } from 'vitest/config'

// The Playwright smoke suite (tests/smoke/**) is driven by `npm run smoke`
// (playwright.config.ts), not by `vitest run`. Playwright's test() API throws
// when collected under vitest, which fails the unit gate. Keep all vitest
// defaults; only carve out the e2e directory.
export default defineConfig({
  test: {
    // agents/** is excluded from COLLECTION, not from testing: those are the
    // sub-agents' own working directories, and under separate OS users some of
    // them are group-restricted. Without this, vitest's file walk dies with an
    // EACCES before anything runs -- and the live-install gate below never gets
    // to print its own message, so the operator sees a permission error instead
    // of "you are about to test inside a live install". Measured 2026-08-28.
    exclude: [...configDefaults.exclude, 'tests/smoke/**', 'agents/**'],
    // Hard gates, run in every worker before any test module is imported:
    //  - assert-not-live-install: refuse to run inside a live install (see that
    //    setup file's header for the 2026-07-27 incident it prevents).
    //  - assert-supported-node: refuse to run on a Node whose ABI the installed
    //    native modules were not built for, which otherwise reds out 40 files
    //    with errors that look like bugs in those files (2026-08-17).
    setupFiles: [
      './src/__tests__/setup/assert-not-live-install.ts',
      './src/__tests__/setup/assert-supported-node.ts',
    ],
  },
})
