import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    globals: true,
    // Run test files sequentially. The live-DDB and Mailpit tests
    // share global state (Mailpit's inbox, DDB tables) and the
    // deleteAllMail() helpers race across parallel files. Sequential
    // execution keeps everything deterministic at the cost of ~few
    // seconds of wall time — acceptable for a service-tier test suite.
    fileParallelism: false,
    // e2e/ holds Playwright specs; they have their own runner (see
    // e2e/playwright.config.ts) and would crash here ("test() not
    // expected"). Vitest's default `exclude` already covers
    // node_modules/.git; we extend it.
    exclude: ['**/node_modules/**', '**/.git/**', 'e2e/**'],
  },
});
