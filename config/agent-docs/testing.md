# Tests, screenshots, recordings

Use `pnpm manifest test [unit|api|e2e]` — it handles env setup, isolated test
schemas/servers, and cleanup itself (see docs/database.md). Postgres is
already running and migrated by the time the agent starts; `pnpm manifest db
status` if a test suite complains otherwise.

E2E / browser work runs HEADLESS ONLY:

- Chromium's headless shell (Playwright 1.58.2) is baked at
  `~/.cache/ms-playwright`. `headless: false` has no binary and will fail —
  do not "fix" this with `playwright install`: browser CDNs are blocked in
  the sandbox. If a project pins a different Playwright version and its
  browser download fails, report the version mismatch to the user instead.
- A `playwright` CLI pinned to the baked browsers is on PATH. For one-offs
  always use it, NEVER bare `npx playwright` — npx resolves an arbitrary
  newer version (nondeterministically, per cache entry) whose browsers are
  not baked, failing with "Executable doesn't exist". Inside a workspace,
  the project's own node_modules copy still wins for its test suite.
- Screenshots: `page.screenshot({path})` in tests, or
  `playwright screenshot <url> <file>` for one-offs. Headless rendering
  is fully capable — screenshots do not need a display.
- Crop/resize/inspect an existing screenshot with Python + Pillow (baked:
  `python3 -c 'from PIL import Image; …'`) — no need to reload the page
  with a hand-computed clip box. There is no ImageMagick in the image.
- Recordings: Playwright's `recordVideo` / `video: 'on'` works headless
  (bundled ffmpeg). There is no apt ffmpeg in the image.
- Save screenshots/videos under the workspace (e.g. `.local/artifacts/`) —
  the workspace is host-mounted, so the user can open them directly.
- `xvfb-run <cmd>` exists for non-browser GUI apps that hard-require a
  display (e.g. Electron).
