# devstack — workspace lifecycle details

`devstack up` is idempotent and non-destructive. It starts PostgreSQL 18
(pg_cron preloaded via a baked drop-in), sets the postgres/postgres password,
creates the workspace database (name from the config file, else inferred from
`.env`/`.env.example`) and points `cron.database_name` at it, bootstraps a
missing `.env` (in a linked git worktree: copied from the main worktree's
`.env`, so the worktree reuses the already-built stack; otherwise from
`.env.example`), runs `pnpm install` when `node_modules` is absent, and
migrates + seeds ONLY when the database is still empty. Seed output is kept
at `.local/devstack-seed.log` — grep it for the URLs/logins/ids the seed
script created instead of re-deriving them. `devstack reset` is the explicit rebuild — it wipes and
re-migrates/re-seeds. `devstack status` shows what is up; heed its warning if
no devstack config was found (the database exists but was never migrated or
seeded).

## Per-workspace config

Resolution order: `$DEVSTACK_CONF` (explicit path), `.local/.devstack.conf`
(preferred — `.local/` is gitignored; never commit it), legacy root
`.devstack.conf`. Keys: `DB_NAME`, `INIT_SQL`, `MIGRATE_CMD`, `SEED_CMD`,
`TEST_HINT`, `TOLERATE_MIGRATE_FAIL_IF` — read the header of
`/usr/local/bin/devstack` for the full, current list.

## Rules

- Do not hand-edit `/etc/postgresql` or hand-roll the database/schema — go
  through `devstack` and the project's own migrate/seed commands.
- If a migrate wrapper's trailing step needs Docker (unavailable here), let
  `TOLERATE_MIGRATE_FAIL_IF` absorb the failure instead of working around the
  project CLI.

## Environment facts

- The baked Postgres cluster serves TLS with a trusted localhost cert, so
  connection strings with `sslmode=require` work as-is.
- If date/Intl code throws `Invalid string: undefined`, the inherited `TZ` is
  not an IANA zone (e.g. macOS "PDT7"). The launcher normally fixes this; if
  it leaks through, prefix commands with `TZ=UTC`.
