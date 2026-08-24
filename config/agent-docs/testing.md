# Tests, screenshots, recordings

Unit/integration tests: use the project's own scripts (`pnpm test`, or the
`TEST_HINT` printed by `devstack up`). Run `devstack up` first — test suites
assume a migrated, seeded database.

E2E / browser work runs HEADLESS ONLY:

- Chromium's headless shell (Playwright 1.58.2) is baked at
  `~/.cache/ms-playwright`. `headless: false` has no binary and will fail —
  do not "fix" this with `playwright install`: browser CDNs are blocked in
  the sandbox. If a project pins a different Playwright version and its
  browser download fails, report the version mismatch to the user instead.
- Screenshots: `page.screenshot({path})` in tests, or
  `npx playwright screenshot <url> <file>` for one-offs. Headless rendering
  is fully capable — screenshots do not need a display.
- Recordings: Playwright's `recordVideo` / `video: 'on'` works headless
  (bundled ffmpeg). There is no apt ffmpeg in the image.
- Save screenshots/videos under the workspace (e.g. `.local/artifacts/`) —
  the workspace is host-mounted, so the user can open them directly.
- `xvfb-run <cmd>` exists for non-browser GUI apps that hard-require a
  display (e.g. Electron).
